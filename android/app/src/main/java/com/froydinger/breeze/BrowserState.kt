package com.froydinger.breeze

import android.app.Application
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.util.Log
import android.webkit.WebView
import androidx.webkit.WebViewFeature
import androidx.compose.runtime.*
import androidx.compose.runtime.snapshots.SnapshotStateList
import com.froydinger.breeze.core.*
import com.froydinger.breeze.cloud.NavSseClient
import com.froydinger.breeze.data.EncryptedStateStore
import com.froydinger.breeze.data.TabThumbnailStore
import com.froydinger.breeze.notifications.ParsedReminderRequest
import com.froydinger.breeze.notifications.ReminderRepeat
import com.froydinger.breeze.notifications.ReminderRequestParser
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject
import org.mozilla.geckoview.*
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.UUID

private const val PAGE_CONTROLS_EXTENSION_ID = "breeze-page-controls@froydinger.com"
private const val PAGE_CONTROLS_NATIVE_APP = "breeze.pageControls"
private const val MAX_HIDDEN_SELECTOR_LENGTH = 512
private const val MAX_HIDDEN_ELEMENTS_PER_SITE = 30
private const val SESSION_STATE_MAX_CHARS = 1_500_000
private const val BACKGROUND_SESSION_RETENTION_MS = 20 * 60 * 1000L
private const val PRIVATE_WEB_PROFILE = "breeze-private"
private val HIDDEN_SELECTOR_PATTERN = Regex(
    "^[a-z][a-z0-9-]{0,63}(:nth-of-type\\([1-9][0-9]{0,4}\\))?(>[a-z][a-z0-9-]{0,63}(:nth-of-type\\([1-9][0-9]{0,4}\\))?){0,32}$",
)

class BreezeApplication : Application() {
    private val browserState = lazy { BrowserState(this) }
    val browser by browserState
    override fun onTrimMemory(level: Int) {
        if (browserState.isInitialized()) browser.onMemoryPressure(level)
        super.onTrimMemory(level)
    }
}
class LiveTab(val id: String = UUID.randomUUID().toString(), val private: Boolean = false) {
    var url by mutableStateOf("")
    var title by mutableStateOf("New tab")
    /** Parsed by GeckoView only when the active document exposes a valid Web App Manifest. */
    var webAppManifest by mutableStateOf<JSONObject?>(null)
    var loading by mutableStateOf(false)
    var canBack by mutableStateOf(false)
    var canForward by mutableStateOf(false)
    var error by mutableStateOf<String?>(null)
    var session: GeckoSession? = null
    /** Live Chromium view retained while this tab is in the background. */
    var chromiumView: WebView? = null
    var chromiumPrivateProfileIsolated: Boolean = false
    var desktopSite: Boolean = false
    var chromiumLoadIssuedUrl: String = ""
    var chromiumPageLoadFailed: Boolean = false
    var chromiumRestoreScrollAfterLoad: Boolean = false
    var lastHistoryUrl: String = ""
    /** Encrypted at rest with the rest of the local browser snapshot; never persisted for private tabs. */
    var savedSessionState: String? = null
    /** True when the current GeckoSession was restored and the initial URL load must be skipped. */
    var restoredSessionState: Boolean = false
    var lastAccessedAt by mutableLongStateOf(System.currentTimeMillis())
    var thumbnail by mutableStateOf<android.graphics.Bitmap?>(null)
    var paintGeneration by mutableIntStateOf(0)
    var captureOverlay: (() -> Unit)? = null
    // Only the scroll delegate needs this value to detect toolbar direction changes.
    // It is not UI state, so publishing every scroll frame through Compose adds needless work.
    var scrollY: Int = 0
    var chromeCollapsed by mutableStateOf(false)
    var lastChromeTransitionAt: Long = 0L
    var zoomPercent by mutableIntStateOf(100)
    var findQuery: String = ""
    var videoPlaying by mutableStateOf(false)
    var videoWidth by mutableIntStateOf(0)
    var videoHeight by mutableIntStateOf(0)
    var videoFrameUrl by mutableStateOf("")
    var videoBoundsNormalized by mutableStateOf<android.graphics.RectF?>(null)
    var scrollDownDistance = 0
    var scrollUpDistance = 0
    var capture: ((onCaptured: () -> Unit) -> Unit)? = null
    // Rendered text stays in memory only and is scoped to the exact page URL.
    var renderedTextUrl: String = ""
    var renderedText: String = ""
    var extractionUrl: String = ""
    var extraction: GeckoResult<String>? = null
}
data class SavedPage(val id: String, val title: String, val url: String, val time: Long = System.currentTimeMillis())
data class PinnedSite(val id: String = UUID.randomUUID().toString(), val title: String, val url: String)
data class SavedDownload(val id: String, val name: String, val uri: String, val time: Long = System.currentTimeMillis())
data class LocalReminder(
    val id: String = UUID.randomUUID().toString(),
    val title: String,
    val dueAt: Long,
    val repeat: ReminderRepeat = ReminderRepeat.NONE,
    val repeatDayOfMonth: Int = 0,
    /** One-time reminders stay in the library after notification delivery. */
    val deliveredAt: Long? = null,
)
private data class VideoFrameState(val playing: Boolean, val width: Int, val height: Int, val url: String)
class LocalChat(val id: String = UUID.randomUUID().toString(), title: String, val time: Long = System.currentTimeMillis()) {
    var title by mutableStateOf(title)
    var draft by mutableStateOf("")
    val messages = mutableStateListOf<Pair<String, String>>()
    val imagePreviews = mutableStateMapOf<Int, String>()
    val sources = mutableStateListOf<Pair<String, String>>()
    val finishedReplies = mutableStateListOf<Int>()
    var running by mutableStateOf(false)
    var status by mutableStateOf("")
    var job: Job? = null
    /** One page pre-opened in the background after an explicit user request. */
    var preopenedNavUrl by mutableStateOf("")
    var preopenedNavTabId by mutableStateOf("")
}
class BrowserState(private val app: Application) {
    private val privacyPreferences = app.getSharedPreferences("breeze_privacy", Application.MODE_PRIVATE)
    val tabs = mutableStateListOf<LiveTab>()
    private var chromiumViewFactory: ((LiveTab) -> WebView)? = null
    private var privateProfileCleaner: (() -> Unit)? = null
    fun setChromiumViewFactory(factory: ((LiveTab) -> WebView)?) { chromiumViewFactory = factory }
    fun setPrivateProfileCleaner(cleaner: (() -> Unit)?) { privateProfileCleaner = cleaner }
    fun privateProfileSupported(): Boolean = WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)
    val history = mutableStateListOf<SavedPage>()
    val bookmarks = mutableStateListOf<SavedPage>()
    val pinnedSites = mutableStateListOf<PinnedSite>()
    val chats = mutableStateListOf<LocalChat>()
    val downloads = mutableStateListOf<SavedDownload>()
    val reminders = mutableStateListOf<LocalReminder>()
    var pendingReminderRequest by mutableStateOf<ParsedReminderRequest?>(null)
        private set
    var pendingReminderDraft by mutableStateOf<String?>(null)
    var pendingReminderDraftDueAt by mutableStateOf<Long?>(null)
        private set
    var httpsOnly by mutableStateOf(true)
    var selectedId by mutableStateOf("")
    var screen by mutableStateOf("browser")
    var isPictureInPicture by mutableStateOf(false)
    var preparingPictureInPicture by mutableStateOf(false)
        private set
    var pictureInPictureSourceRect by mutableStateOf<android.graphics.Rect?>(null)
    var isStandalonePwa by mutableStateOf(false)
    var pageToolsOpen by mutableStateOf(false)
    var overlayBackdrop by mutableStateOf<Bitmap?>(null)
    /** Initial filter used when the shared history page is opened from a specific shortcut. */
    var historyInitialFilter by mutableStateOf("All")
    var chatReturnScreen by mutableStateOf("browser")
        private set
    var chatReturnTabId by mutableStateOf("")
        private set
    /** Webpage conversations begin as a tray; new-tab and History conversations open full-screen. */
    var chatExpanded by mutableStateOf(true)
        private set
    var navInputFocusRequested by mutableStateOf(false)
        private set
    var cloudDisclosureAccepted by mutableStateOf(privacyPreferences.getBoolean("cloud_ai_disclosure_accepted", false))
        private set
    var showCloudDisclosure by mutableStateOf(false)
        private set
    private var pendingCloudPrompt: String? = null
    var pendingImageUri by mutableStateOf<String?>(null)
        private set
    private var pendingImageRevision = 0
    var theme by mutableStateOf(ThemeMode.SYSTEM)
    var homeMode by mutableStateOf(HomeInputMode.ASK)
    var engine by mutableStateOf(SearchEngine.SPECTRA)
    var wallpaper by mutableStateOf("teal_facets")
    var glass by mutableStateOf(true)
    var trackingProtection by mutableStateOf(true)
    var cookieProtection by mutableStateOf(privacyPreferences.getBoolean("cookie_protection", true))
    var blockAllCookies by mutableStateOf(privacyPreferences.getBoolean("block_all_cookies", false))
    val siteProtectionOverrides = mutableStateMapOf<String, Boolean>()
    private val hiddenElementRules = mutableStateMapOf<String, List<String>>()
    private val elementPickerPorts = mutableMapOf<GeckoSession, WebExtension.Port>()
    private val pageControlPorts = mutableMapOf<GeckoSession, MutableSet<WebExtension.Port>>()
    private val videoPortStates = mutableMapOf<GeckoSession, LinkedHashMap<WebExtension.Port, VideoFrameState>>()
    private val pendingElementPicks = mutableSetOf<GeckoSession>()
    private var pageControlsExtension: WebExtension? = null
    private val pageControlsReady = CompletableDeferred<WebExtension?>()
    private val pageControlsDelegate = object : WebExtension.MessageDelegate {
        override fun onConnect(port: WebExtension.Port) {
            val session = port.sender.session ?: return
            val tab = tabs.firstOrNull { it.session === session } ?: return
            pageControlPorts.getOrPut(session) { linkedSetOf() }.add(port)
            if (port.sender.isTopLevel && protectionKey(port.sender.url) == protectionKey(tab.url)) {
                elementPickerPorts[session] = port
            }
            port.setDelegate(object : WebExtension.PortDelegate {
                override fun onPortMessage(message: Any, activePort: WebExtension.Port) {
                    if (activePort.sender.session !== session || tabs.none { it === tab } || tab.session !== session) return
                    val json = message as? JSONObject ?: return
                    val host = protectionKey(tab.url) ?: return
                    if (json.optString("type") == "videoPlayback") {
                        val frameUrl = json.optString("frameUrl").takeIf {
                            it.length in 1..2048 && Uri.parse(it).scheme in listOf("http", "https")
                        } ?: activePort.sender.url
                        if (activePort.sender.isTopLevel && !isPictureInPicture && !preparingPictureInPicture) {
                            val viewportWidth = json.optDouble("viewportWidth", 0.0).toFloat()
                            val viewportHeight = json.optDouble("viewportHeight", 0.0).toFloat()
                            val left = json.optDouble("left", 0.0).toFloat()
                            val top = json.optDouble("top", 0.0).toFloat()
                            val width = json.optDouble("width", 0.0).toFloat()
                            val height = json.optDouble("height", 0.0).toFloat()
                            tab.videoBoundsNormalized = if (viewportWidth > 0 && viewportHeight > 0 && width > 0 && height > 0) {
                                android.graphics.RectF(left / viewportWidth, top / viewportHeight,
                                    (left + width) / viewportWidth, (top + height) / viewportHeight)
                            } else null
                        }
                        val states = videoPortStates.getOrPut(session) { linkedMapOf() }
                        states[activePort] = VideoFrameState(
                            playing = json.optBoolean("playing") && !tab.private,
                            width = json.optInt("videoWidth").coerceIn(0, 4096),
                            height = json.optInt("videoHeight").coerceIn(0, 4096),
                            url = frameUrl,
                        )
                        val activeVideo = states.values.lastOrNull { it.playing }
                            ?: states.values.lastOrNull { it.width > 0 && it.height > 0 }
                        tab.videoPlaying = activeVideo?.playing == true
                        tab.videoWidth = activeVideo?.width ?: 0
                        tab.videoHeight = activeVideo?.height ?: 0
                        tab.videoFrameUrl = activeVideo?.url.orEmpty()
                        return
                    }
                    if (!activePort.sender.isTopLevel || protectionKey(activePort.sender.url) != host) return
                    when (json.optString("type")) {
                        "ready" -> sendElementRules(tab, "sync", pendingElementPicks.contains(session))
                        "selected" -> {
                            val requestedHost = json.optString("host").lowercase().removePrefix("www.")
                            val selector = json.optString("selector")
                            if (tab.private || requestedHost != host || !isSafeElementSelector(selector)) {
                                pendingElementPicks.remove(session)
                                activePort.postMessage(JSONObject().put("type", "cancelPick"))
                                notice = "That page item could not be hidden safely. Try selecting it again."
                                return
                            }
                            val rules = hiddenElementRules[host].orEmpty().toMutableList()
                            if (selector !in rules && rules.size < MAX_HIDDEN_ELEMENTS_PER_SITE) rules.add(selector)
                            hiddenElementRules[host] = rules
                            pendingElementPicks.remove(session)
                            persist()
                            sendElementRules(tab)
                            notice = if (rules.size >= MAX_HIDDEN_ELEMENTS_PER_SITE) "This site has reached its limit of hidden page items." else "Page item hidden on $host."
                        }
                        "pickerError" -> {
                            pendingElementPicks.remove(session)
                            notice = "Couldn’t make a safe rule for that item. Try a larger banner or ad."
                        }
                        "pickerCancelled" -> pendingElementPicks.remove(session)
                    }
                }

                override fun onDisconnect(disconnectedPort: WebExtension.Port) {
                    if (elementPickerPorts[session] === disconnectedPort) elementPickerPorts.remove(session)
                    pageControlPorts[session]?.let { ports ->
                        ports.remove(disconnectedPort)
                        if (ports.isEmpty()) pageControlPorts.remove(session)
                    }
                    videoPortStates[session]?.let { states ->
                        states.remove(disconnectedPort)
                        val activeVideo = states.values.lastOrNull { it.playing }
                            ?: states.values.lastOrNull { it.width > 0 && it.height > 0 }
                        tab.videoPlaying = activeVideo?.playing == true && !tab.private
                        tab.videoWidth = activeVideo?.width ?: 0
                        tab.videoHeight = activeVideo?.height ?: 0
                        tab.videoFrameUrl = activeVideo?.url.orEmpty()
                        if (states.isEmpty()) videoPortStates.remove(session)
                    }
                    pendingElementPicks.remove(session)
                }
            })
            if (port.sender.isTopLevel && protectionKey(port.sender.url) == protectionKey(tab.url)) {
                sendElementRules(tab, "sync", pendingElementPicks.contains(session))
            }
        }
    }
    var activeChat by mutableStateOf<LocalChat?>(null)
    var includePageContext by mutableStateOf(true)
    var contextTabId by mutableStateOf<String?>(null)
    val contextTab: LiveTab? get() = tabs.firstOrNull { it.id == contextTabId && !it.private }
    val selectedVideoIsPlaying: Boolean get() = selected?.let { it.videoPlaying && !it.private } == true
    /** Gecko can report about:blank for a fresh tab before its home surface is shown. */
    val isHomePage: Boolean get() = selected?.url.isNullOrBlank() || selected?.url.equals("about:blank", ignoreCase = true)
    var homeInputFocusTabId by mutableStateOf<String?>(null)
        private set

    var notice by mutableStateOf<String?>(null)
    var showFind by mutableStateOf(false)
    var ready by mutableStateOf(false)
    var credentials: com.froydinger.breeze.browser.BrowserCredentials? = null
    fun attachCredentials(value: com.froydinger.breeze.browser.BrowserCredentials?) {
        credentials = value
        if (tabs.any { it.session != null }) runtime.autocompleteStorageDelegate = value
        updateCredentialContext()
    }
    fun updateCredentialContext() { credentials?.updatePageContext(selected?.session, selected?.url, selected?.private != false || screen != "browser") }
    fun unlockSitePasswords() {
        updateCredentialContext()
        credentials?.unlockForSite(selected?.url.orEmpty()) { ok ->
            notice = if (ok) "Vault unlocked for this site for 30 seconds. Tap its login field to choose a saved login." else "Saved logins are available only on a regular HTTPS page."
        }
    }
    var promptDelegate: GeckoSession.PromptDelegate? = null
        set(value) { field = value; tabs.forEach { it.session?.promptDelegate = value } }
    var permissionDelegate: GeckoSession.PermissionDelegate? = null
        set(value) { field = value; tabs.forEach { it.session?.permissionDelegate = value } }
    var downloadHandler: ((WebResponse, Boolean) -> Unit)? = null
    private var writeBlocked = false
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val store = EncryptedStateStore(app)
    private val thumbnailStore = TabThumbnailStore(app)
    private val thumbnailLock = Mutex()
    private var saveJob: Job? = null
    private var appInForeground = false
    var foregroundGeneration by mutableIntStateOf(0)
        private set
    val isAppInForeground: Boolean get() = appInForeground
    private var backgroundedAt = 0L
    private var backgroundExpiryJob: Job? = null
    private val runtime by lazy {
        val behavior = cookieBehavior()
        GeckoRuntime.create(app, GeckoRuntimeSettings.Builder()
            .loginAutofillEnabled(true)
            .webManifest(true)
            .allowInsecureConnections(if (httpsOnly) GeckoRuntimeSettings.HTTPS_ONLY else GeckoRuntimeSettings.ALLOW_ALL)
            .contentBlocking(ContentBlocking.Settings.Builder()
                .antiTracking(ContentBlocking.AntiTracking.DEFAULT)
                .cookieBehavior(behavior)
                .cookieBehaviorPrivateMode(behavior)
                .cookiePurging(cookieProtection)
                .build())
            .build()).also { it.autocompleteStorageDelegate = credentials }
    }
    val selected: LiveTab? get() = tabs.firstOrNull { it.id == selectedId }
    val overlayBackdropRequested: Boolean
        get() = pageToolsOpen || (screen == "chat" && chatReturnScreen == "browser" && selected?.url?.startsWith("http") == true)

    fun updateOverlayBackdrop(bitmap: Bitmap) {
        val previous = overlayBackdrop
        overlayBackdrop = bitmap
        if (previous != null && previous !== bitmap) {
            Handler(Looper.getMainLooper()).postDelayed({
                if (overlayBackdrop !== previous && !previous.isRecycled) previous.recycle()
            }, 500)
        }
    }

    fun clearOverlayBackdrop() {
        val previous = overlayBackdrop
        overlayBackdrop = null
        if (previous != null) {
            Handler(Looper.getMainLooper()).postDelayed({
                if (overlayBackdrop !== previous && !previous.isRecycled) previous.recycle()
            }, 500)
        }
    }

    init {
        scope.launch {
            try {
                restore(withContext(Dispatchers.IO) { store.load() })
                reminders.forEach { com.froydinger.breeze.notifications.ReminderScheduler.schedule(app, it) }
            }
            catch (e: Exception) { writeBlocked = true; notice = "Saved data could not be opened. It has been preserved. ${e.javaClass.simpleName}" }
            if (tabs.isEmpty()) newTab(focusHomeInput = false)
            ready = true
            persist()
        }
    }
    private fun defaultPinnedSites() = listOf(
        PinnedSite(title = "Google", url = "https://google.com"),
        PinnedSite(title = "YouTube", url = "https://youtube.com"),
        PinnedSite(title = "Wikipedia", url = "https://wikipedia.org"),
        PinnedSite(title = "Reddit", url = "https://reddit.com"),
    )

    fun openChatsHistory() {
        openHistory("Chats")
    }

    fun openHistory(filter: String = "All") {
        historyInitialFilter = filter.takeIf { it in setOf("All", "Web", "Chats") } ?: "All"
        screen = "history"
    }

    fun pinSite(title: String, url: String): Boolean {
        val uri = Uri.parse(url)
        if (uri.scheme !in listOf("http", "https") || uri.host.isNullOrBlank()) return false
        if (pinnedSites.any { it.url.trimEnd('/').equals(url.trimEnd('/'), ignoreCase = true) }) return true
        pinnedSites.add(PinnedSite(title = title.ifBlank { uri.host.orEmpty().removePrefix("www.") }, url = url))
        persist()
        return true
    }

    fun pinCurrentSite(): Boolean {
        val tab = selected ?: return false
        if (tab.private) return false
        return pinSite(tab.title, tab.url)
    }

    fun unpinCurrentSite(): Boolean {
        val url = selected?.url ?: return false
        val pinned = pinnedSites.firstOrNull { it.url.trimEnd('/').equals(url.trimEnd('/'), ignoreCase = true) } ?: return false
        unpinSite(pinned.id)
        return true
    }

    fun isSitePinned(url: String): Boolean = pinnedSites.any { it.url.trimEnd('/').equals(url.trimEnd('/'), ignoreCase = true) }

    fun unpinSite(id: String) {
        if (pinnedSites.removeAll { it.id == id }) persist()
    }

    fun movePinnedSite(id: String, offset: Int): Boolean {
        val index = pinnedSites.indexOfFirst { it.id == id }
        val target = index + offset
        if (index < 0 || target !in pinnedSites.indices) return false
        val item = pinnedSites.removeAt(index)
        pinnedSites.add(target, item)
        persist()
        return true
    }
    fun newTab(private: Boolean = false, focusHomeInput: Boolean = true): LiveTab {
        selected?.let(::deactivateSession)
        val tab = LiveTab(private = private)
        tab.lastAccessedAt = System.currentTimeMillis()
        tabs.add(tab)
        selectedId = tab.id
        homeInputFocusTabId = tab.id.takeIf { focusHomeInput }
        screen = "browser"
        updateSessionPriorities()
        persist()
        return tab
    }
    fun consumeHomeInputFocus(tabId: String) {
        if (homeInputFocusTabId == tabId) homeInputFocusTabId = null
    }
    fun select(tab: LiveTab) {
        if (tabs.none { it === tab }) return
        selected?.takeIf { it !== tab }?.let(::deactivateSession)
        tab.chromeCollapsed = false
        tab.lastAccessedAt = System.currentTimeMillis()
        selectedId = tab.id
        tab.chromiumView?.onResume()
        homeInputFocusTabId = null
        screen = "browser"
        updateSessionPriorities()
        persist()
    }
    private fun shouldKeepActive(tab: LiveTab): Boolean =
        (appInForeground && (screen in setOf("browser", "tabs") || screen == "chat" && chatReturnScreen == "browser") && selectedId == tab.id) ||
            ((isPictureInPicture || preparingPictureInPicture) && selectedId == tab.id && !tab.private)

    private fun deactivateSession(tab: LiveTab) {
        tab.chromiumView?.onPause()
        tab.session?.let { session ->
            session.setActive(false)
            session.setPriorityHint(GeckoSession.PRIORITY_DEFAULT)
        }
    }

    private fun updateSessionPriorities() {
        tabs.forEach { tab ->
            val session = tab.session ?: return@forEach
            val active = shouldKeepActive(tab)
            session.setPriorityHint(if (active) GeckoSession.PRIORITY_HIGH else GeckoSession.PRIORITY_DEFAULT)
            session.setActive(active)
        }
    }

    /** Called from Activity lifecycle; no foreground service or wakelock is used. */
    fun onAppForegrounded() {
        if (!appInForeground) foregroundGeneration++
        appInForeground = true
        selected?.chromiumView?.onResume()
        backgroundedAt = 0L
        backgroundExpiryJob?.cancel()
        backgroundExpiryJob = null
        updateSessionPriorities()
    }

    fun preparePictureInPicture() {
        if (!selectedVideoIsPlaying || screen != "browser") return
        preparingPictureInPicture = true
        sendPictureInPictureMessage(true)
        updateSessionPriorities()
    }

    fun setPictureInPictureMode(enabled: Boolean) {
        // A paused video still belongs to the system PiP window and must retain its surface.
        isPictureInPicture = enabled
        preparingPictureInPicture = false
        sendPictureInPictureMessage(enabled)
        updateSessionPriorities()
    }

    private fun sendPictureInPictureMessage(enabled: Boolean) {
        selected?.session?.let { session ->
            session.settings.suspendMediaWhenInactive = !enabled
            val message = JSONObject().put("type", "pipVideo").put("enabled", enabled)
                .put("frameUrl", selected?.videoFrameUrl.orEmpty())
            pageControlPorts[session]?.toList()?.forEach { port -> runCatching { port.postMessage(message) } }
        }
    }

    fun stopPictureInPicturePlayback() = sendVideoPlaybackCommand(false)

    fun controlPictureInPicturePlayback(play: Boolean) {
        if (!isPictureInPicture && !preparingPictureInPicture) return
        sendVideoPlaybackCommand(play)
    }

    private fun sendVideoPlaybackCommand(play: Boolean) {
        selected?.session?.let { session ->
            val message = JSONObject().put("type", "pipPlayback").put("play", play)
                .put("frameUrl", selected?.videoFrameUrl.orEmpty())
            pageControlPorts[session]?.toList()?.forEach { port -> runCatching { port.postMessage(message) } }
        }
    }

    /** Let Gecko keep sessions for a short background window, then serialize and release them. */
    fun onAppBackgrounded() {
        appInForeground = false
        backgroundedAt = System.currentTimeMillis()
        tabs.forEach { tab ->
            tab.chromiumView?.onPause()
            tab.session?.let { session ->
                val keepForPip = shouldKeepActive(tab)
                session.setActive(keepForPip)
                session.setPriorityHint(if (keepForPip) GeckoSession.PRIORITY_HIGH else GeckoSession.PRIORITY_DEFAULT)
                session.flushSessionState()
            }
        }
        persist()
        backgroundExpiryJob?.cancel()
        backgroundExpiryJob = scope.launch {
            delay(BACKGROUND_SESSION_RETENTION_MS)
            if (!appInForeground && System.currentTimeMillis() - backgroundedAt >= BACKGROUND_SESSION_RETENTION_MS) {
                releaseInactiveSessions()
            }
        }
    }

    /** Android memory hints let Gecko sleep hidden tabs, with full state retained for restoration. */
    fun onMemoryPressure(level: Int) {
        // UI_HIDDEN is numerically above RUNNING_CRITICAL. It is a normal app
        // background event, not permission to close every live Gecko session.
        val severe = level >= android.content.ComponentCallbacks2.TRIM_MEMORY_BACKGROUND ||
            (level >= android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL &&
                level < android.content.ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN)
        tabs.filterNot(::shouldKeepActive).forEach { tab ->
            val session = tab.session ?: return@forEach
            session.setActive(false)
            session.setPriorityHint(GeckoSession.PRIORITY_DEFAULT)
            session.flushSessionState()
            if (severe) releaseSession(tab)
        }
        if (severe) persist()
    }

    private fun releaseInactiveSessions() {
        tabs.filterNot(::shouldKeepActive).forEach(::releaseSession)
        persist()
    }

    private fun releaseSession(tab: LiveTab) {
        val session = tab.session ?: return
        session.setActive(false)
        session.setPriorityHint(GeckoSession.PRIORITY_DEFAULT)
        session.flushSessionState()
        elementPickerPorts.remove(session)
        pageControlPorts.remove(session)?.toList()?.forEach { it.disconnect() }
        videoPortStates.remove(session)
        pendingElementPicks.remove(session)
        session.close()
        tab.session = null
        tab.restoredSessionState = false
    }
    fun close(tab: LiveTab) {
        if (tabs.none { it === tab }) return
        val wasSelected = selectedId == tab.id
        val privacy = tab.private
        tab.session?.let { session ->
            elementPickerPorts.remove(session)
            pageControlPorts.remove(session)?.toList()?.forEach { it.disconnect() }
            videoPortStates.remove(session)
            pendingElementPicks.remove(session)
        }
        tab.chromiumView?.let { view ->
            tab.chromiumView = null
            runCatching { view.stopLoading(); view.loadUrl("about:blank"); view.clearHistory(); view.removeAllViews(); view.destroy() }
        }
        tab.session?.close(); tab.session = null; tab.savedSessionState = null; tabs.remove(tab); deleteThumbnail(tab)
        if (wasSelected) {
            homeInputFocusTabId = null
            isPictureInPicture = false
            val replacement = tabs.filter { it.private == privacy }.maxByOrNull { it.lastAccessedAt }
            if (replacement != null) selectedId = replacement.id else {
                selectedId = ""
                newTab(private = privacy, focusHomeInput = false)
            }
        }
        if (privacy && tabs.none { it.private && it.chromiumView != null }) runCatching { privateProfileCleaner?.invoke() }
        updateSessionPriorities()
        persist()
    }
    fun home() {
        val current = selected
        if (current?.url.isNullOrBlank() || current?.url.equals("about:blank", ignoreCase = true)) { screen = "browser"; return }
        val start = tabs.firstOrNull { it.private == current?.private && (it.url.isBlank() || it.url.equals("about:blank", ignoreCase = true)) }
        if (start != null) select(start) else newTab(current?.private == true, focusHomeInput = false)
    }
    fun isYouTubeVideo(url: String): Boolean {
        val uri = runCatching { Uri.parse(url) }.getOrNull() ?: return false
        val host = uri.host?.lowercase()?.removePrefix("www.") ?: return false
        return when {
            host == "youtu.be" -> uri.pathSegments.firstOrNull().orEmpty().isNotBlank()
            host == "youtube.com" || host.endsWith(".youtube.com") ->
                uri.path == "/watch" && !uri.getQueryParameter("v").isNullOrBlank() ||
                    uri.pathSegments.firstOrNull() in setOf("shorts", "live", "embed") && uri.pathSegments.getOrNull(1).orEmpty().isNotBlank()
            else -> false
        }
    }
    /** Handle Android's share sheet input. YouTube videos open in a tab and start Creator Breakdown. */
    fun openSharedText(sharedText: String) {
        val text = sharedText.trim()
        if (text.isBlank()) return
        scope.launch {
            snapshotFlow { ready }.first { it }
            val url = extractDirectWebUrl(text)
            if (url == null) {
                if (activeChat != null && screen == "chat") sendChat(text) else startChat(text)
                return@launch
            }
            navigate(url, new = true, privateMode = false)
            if (isYouTubeVideo(url)) startChat("/youtube $url")
        }
    }
    fun submit(text: String, explicitSearch: Boolean = false) {
        when (val result = InputRouter.route(text, if (isHomePage) InputSurface.HOME else InputSurface.WEBPAGE, homeMode, engine, explicitSearch)) {
            is InputRoute.OpenUrl -> navigate(result.url)
            is InputRoute.Search -> navigate(result.url)
            is InputRoute.StartChat -> startChat(result.prompt)
            is InputRoute.RunTask -> startChat("/${result.task.slug} ${result.prompt}".trim())
            null -> Unit
        }
    }
    fun openExternalUrl(url: String, standalonePwa: Boolean = false) {
        scope.launch {
            snapshotFlow { ready }.first { it }
            isStandalonePwa = standalonePwa
            navigate(url, new = true)
        }
    }
    fun navigate(url: String, new: Boolean = false, privateMode: Boolean? = null) {
        val requestedUri = Uri.parse(url)
        if (requestedUri.scheme !in listOf("http", "https") || requestedUri.host.isNullOrBlank()) { notice = "Only valid HTTP and HTTPS pages can open here."; return }
        val targetUrl = if (httpsOnly && requestedUri.scheme == "http") {
            notice = "Breeze upgraded this link to HTTPS."
            requestedUri.buildUpon().scheme("https").build().toString()
        } else url
        val tab = if (new) newTab(privateMode ?: (selected?.private == true), focusHomeInput = false) else selected ?: newTab(privateMode ?: false, focusHomeInput = false)
        homeInputFocusTabId = null
        tab.lastAccessedAt = System.currentTimeMillis()
        tab.savedSessionState = null
        tab.restoredSessionState = false
        tab.url = targetUrl; tab.error = null; tab.scrollY = 0; tab.chromeCollapsed = false; screen = "browser"
        tab.chromiumLoadIssuedUrl = ""
        loadTab(tab, targetUrl)
        persist()
    }
    fun loadTab(tab: LiveTab, url: String = tab.url) {
        if (tabs.none { it === tab } || tab.url != url || url.isBlank()) return
        // The WebView is created by AndroidView. Keep the requested URL on the logical tab
        // until that retained Chromium view is attached; do not create a parallel Gecko page.
        tab.loading = true
        val view = tab.chromiumView
        if (view != null) {
            if (view.url != url && tab.chromiumLoadIssuedUrl != url) {
                tab.chromiumLoadIssuedUrl = url
                view.loadUrl(url)
            }
        }
        // With no attached surface, retain only the logical destination. AndroidView creates
        // the single view when this tab becomes visible, then its update path loads the URL.
    }

    /** Attach the visible Android Chromium surface to its durable logical tab. */
    fun attachChromiumView(tab: LiveTab, view: WebView) {
        if (tabs.none { it === tab }) return
        tab.chromiumView = view
        view.setOnScrollChangeListener(android.view.View.OnScrollChangeListener { _, _, y, _, _ ->
            onChromiumScrollChanged(tab, y)
        })
        view.onResume()
        if (tab.private && !tab.chromiumPrivateProfileIsolated) {
            tab.loading = false
            tab.error = "Private tabs need an updated Android System WebView. Update Android System WebView in Play Store and try again."
            notice = "Private browsing could not be isolated on this device, so this page was not opened."
            return
        }
        // loadTab owns navigation requests so it can deduplicate the first request while
        // Compose attaches a newly-created AndroidView.
        if (BuildConfig.DEBUG) Log.d("BreezeEngine", "engine=android-webview-chromium tab=${tab.id.take(8)} url=${tab.url}")
        syncChromiumNavigation(tab)
    }

    /** AndroidView release detaches a surface, but retains its tab history and renderer state. */
    fun detachChromiumView(tab: LiveTab, view: WebView) {
        if (tab.chromiumView === view) view.onPause()
    }

    /**
     * WebViews keep their Activity context. Release them when the Activity is destroyed so
     * configuration changes and process recreation cannot retain a dead Activity. Logical
     * tabs, URLs, scroll offsets, and history remain in BrowserState and reattach lazily.
     */
    fun releaseChromiumViewsForActivityDestroy() {
        tabs.forEach { tab ->
            val view = tab.chromiumView ?: return@forEach
            tab.url = view.url?.takeIf { it.startsWith("http://") || it.startsWith("https://") } ?: tab.url
            tab.scrollY = view.scrollY.coerceAtLeast(0)
            tab.canBack = view.canGoBack()
            tab.canForward = view.canGoForward()
            tab.chromiumView = null
            tab.chromiumLoadIssuedUrl = ""
            tab.chromiumRestoreScrollAfterLoad = tab.scrollY > 0
            runCatching {
                view.stopLoading()
                view.removeAllViews()
                view.destroy()
            }
        }
    }

    fun chromiumPageStarted(tab: LiveTab, view: WebView, url: String) {
        if (!isCurrentChromiumView(tab, view)) return
        tab.chromiumPageLoadFailed = false
        if (tab.url != url) {
            tab.webAppManifest = null
            clearRenderedText(tab)
            tab.videoPlaying = false
            tab.videoWidth = 0
            tab.videoHeight = 0
            tab.videoFrameUrl = ""
        }
        tab.url = url
        tab.chromiumLoadIssuedUrl = url
        tab.loading = true
        tab.error = null
        tab.scrollY = 0
        tab.chromeCollapsed = false
        syncChromiumNavigation(tab)
        if (selectedId == tab.id) updateCredentialContext()
        persist()
    }

    fun chromiumPageFinished(tab: LiveTab, view: WebView, url: String) {
        if (!isCurrentChromiumView(tab, view) || tab.url != url) return
        tab.loading = false
        val loaded = !tab.chromiumPageLoadFailed
        tab.error = if (loaded) null else tab.error ?: "This page could not finish loading. Try reloading."
        syncChromiumNavigation(tab)
        if (loaded && isHttpPage(url)) {
            if (tab.chromiumRestoreScrollAfterLoad) {
                val restoreY = tab.scrollY
                tab.chromiumRestoreScrollAfterLoad = false
                view.post { if (isCurrentChromiumView(tab, view)) view.scrollTo(view.scrollX, restoreY) }
            }
            tab.paintGeneration++
            tab.capture?.invoke {}
            if (!tab.private) {
                beginPageTextExtraction(tab, null, url)
                if (tab.lastHistoryUrl != url) {
                    history.add(0, SavedPage(UUID.randomUUID().toString(), tab.title, url))
                    tab.lastHistoryUrl = url
                }
            }
            persist()
        }
    }

    fun chromiumTitleChanged(tab: LiveTab, view: WebView, title: String?) {
        if (!isCurrentChromiumView(tab, view)) return
        tab.title = title?.takeIf { it.isNotBlank() } ?: tab.url.ifBlank { "New tab" }
        persist()
    }

    fun chromiumProgressChanged(tab: LiveTab, view: WebView, progress: Int) {
        if (!isCurrentChromiumView(tab, view)) return
        tab.loading = progress < 100
        syncChromiumNavigation(tab)
    }

    fun chromiumMainFrameError(tab: LiveTab, view: WebView, description: String) {
        if (!isCurrentChromiumView(tab, view)) return
        tab.loading = false
        tab.chromiumPageLoadFailed = true
        tab.error = description.take(160).ifBlank { "This page could not be loaded. Try again." }
    }

    private fun isCurrentChromiumView(tab: LiveTab, view: WebView): Boolean =
        tabs.any { it === tab } && tab.chromiumView === view

    private fun syncChromiumNavigation(tab: LiveTab) {
        tab.chromiumView?.let { view ->
            tab.canBack = view.canGoBack()
            tab.canForward = view.canGoForward()
        }
    }

    fun chromiumGoBack(tab: LiveTab? = selected) {
        tab?.chromiumView?.takeIf { it.canGoBack() }?.goBack()
    }

    fun chromiumGoForward(tab: LiveTab? = selected) {
        tab?.chromiumView?.takeIf { it.canGoForward() }?.goForward()
    }

    fun chromiumReload(tab: LiveTab? = selected) {
        tab ?: return
        val view = tab.chromiumView ?: return
        tab.error = null
        tab.loading = true
        view.reload()
    }

    fun chromiumFind(tab: LiveTab, query: String) {
        val view = tab.chromiumView ?: return
        if (query != tab.findQuery) {
            tab.findQuery = query
            view.findAllAsync(query)
        }
    }

    fun chromiumFindNext(tab: LiveTab, forward: Boolean = true) { tab.chromiumView?.findNext(forward) }
    fun chromiumClearFind(tab: LiveTab) { tab.findQuery = ""; tab.chromiumView?.clearMatches() }

    private fun onChromiumScrollChanged(tab: LiveTab, scrollY: Int) {
        val delta = scrollY - tab.scrollY
        val now = android.os.SystemClock.uptimeMillis()
        val chromeSettled = now - tab.lastChromeTransitionAt >= 500L
        if (scrollY <= 4) {
            tab.scrollDownDistance = 0
            tab.scrollUpDistance = 0
            tab.chromeCollapsed = false
        } else if (delta > 2) {
            if (tab.chromeCollapsed) tab.scrollUpDistance = (tab.scrollUpDistance - delta * 2).coerceAtLeast(0)
            else tab.scrollDownDistance = (tab.scrollDownDistance + delta).coerceAtMost(500)
            if (!tab.chromeCollapsed && chromeSettled && scrollY > 96 && tab.scrollDownDistance >= 128) {
                tab.chromeCollapsed = true
                tab.lastChromeTransitionAt = now
                tab.scrollDownDistance = 0
                tab.scrollUpDistance = 0
            }
        } else if (delta < -2) {
            if (tab.chromeCollapsed) tab.scrollUpDistance = (tab.scrollUpDistance - delta).coerceAtMost(500)
            else tab.scrollDownDistance = (tab.scrollDownDistance + delta * 2).coerceAtLeast(0)
            if (tab.chromeCollapsed && chromeSettled && tab.scrollUpDistance >= 96) {
                tab.chromeCollapsed = false
                tab.lastChromeTransitionAt = now
                tab.scrollUpDistance = 0
                tab.scrollDownDistance = 0
            }
        }
        tab.scrollY = scrollY
    }

    fun session(tab: LiveTab): GeckoSession = createSession(tab, openImmediately = true)

    private fun newWindowSession(tab: LiveTab): GeckoSession = createSession(tab, openImmediately = false)

    private fun createSession(tab: LiveTab, openImmediately: Boolean): GeckoSession {
        tab.session?.let { existing ->
            pageControlsExtension?.let { attachPageControls(existing, it) }
            return existing
        }
        val settings = GeckoSessionSettings.Builder()
            .usePrivateMode(tab.private)
            .useTrackingProtection(isSiteProtectionEnabled(tab.url))
            .userAgentMode(GeckoSessionSettings.USER_AGENT_MODE_MOBILE)
            .viewportMode(GeckoSessionSettings.VIEWPORT_MODE_MOBILE)
            .build()
        val session = GeckoSession(settings)
        session.scrollDelegate = object : GeckoSession.ScrollDelegate {
            override fun onScrollChanged(session: GeckoSession, scrollX: Int, scrollY: Int) {
                val delta = scrollY - tab.scrollY
                val now = android.os.SystemClock.uptimeMillis()
                val chromeSettled = now - tab.lastChromeTransitionAt >= 500L
                if (scrollY <= 4) {
                    tab.scrollDownDistance = 0
                    tab.scrollUpDistance = 0
                    tab.chromeCollapsed = false
                } else if (delta > 2) {
                    if (tab.chromeCollapsed) {
                        // A small reverse movement should not fight the collapsed toolbar.
                        tab.scrollUpDistance = (tab.scrollUpDistance - delta * 2).coerceAtLeast(0)
                    } else {
                        tab.scrollDownDistance = (tab.scrollDownDistance + delta).coerceAtMost(500)
                    }
                    if (!tab.chromeCollapsed && chromeSettled && scrollY > 96 && tab.scrollDownDistance >= 128) {
                        tab.chromeCollapsed = true
                        tab.lastChromeTransitionAt = now
                        tab.scrollDownDistance = 0
                        tab.scrollUpDistance = 0
                    }
                } else if (delta < -2) {
                    if (tab.chromeCollapsed) {
                        tab.scrollUpDistance = (tab.scrollUpDistance - delta).coerceAtMost(500)
                    } else {
                        tab.scrollDownDistance = (tab.scrollDownDistance + delta * 2).coerceAtLeast(0)
                    }
                    if (tab.chromeCollapsed && chromeSettled && tab.scrollUpDistance >= 96) {
                        tab.chromeCollapsed = false
                        tab.lastChromeTransitionAt = now
                        tab.scrollUpDistance = 0
                        tab.scrollDownDistance = 0
                    }
                }
                tab.scrollY = scrollY
            }
        }
        session.promptDelegate = promptDelegate
        session.permissionDelegate = permissionDelegate
        session.navigationDelegate = object : GeckoSession.NavigationDelegate {
            override fun onLocationChange(session: GeckoSession, url: String?, perms: MutableList<GeckoSession.PermissionDelegate.ContentPermission>, hasUserGesture: Boolean) {
                if (url != null) {
                    if (tab.url != url) {
                        tab.webAppManifest = null
                        clearRenderedText(tab)
                        tab.videoPlaying = false
                        tab.videoWidth = 0
                        tab.videoHeight = 0
                        tab.videoFrameUrl = ""
                        videoPortStates[session]?.clear()
                    }
                    tab.url = url
                    tab.session?.settings?.useTrackingProtection = isSiteProtectionEnabled(url)
                    if (selectedId == tab.id) updateCredentialContext()
                    persist()
                }
            }
            override fun onCanGoBack(session: GeckoSession, canGoBack: Boolean) { tab.canBack = canGoBack }
            override fun onCanGoForward(session: GeckoSession, canGoForward: Boolean) { tab.canForward = canGoForward }
            override fun onLoadRequest(session: GeckoSession, request: GeckoSession.NavigationDelegate.LoadRequest): GeckoResult<AllowOrDeny> {
                val scheme = Uri.parse(request.uri).scheme
                val unsolicitedWindow = request.target == GeckoSession.NavigationDelegate.TARGET_WINDOW_NEW &&
                    !request.hasUserGesture && !request.isDirectNavigation
                if (scheme !in setOf("http", "https", "about") && request.hasUserGesture) launchExternalUri(request.uri)
                return GeckoResult.fromValue(if (scheme in listOf("http", "https", "about") && !unsolicitedWindow) AllowOrDeny.ALLOW else AllowOrDeny.DENY)
            }
            override fun onNewSession(session: GeckoSession, uri: String): GeckoResult<GeckoSession>? {
                if (screen != "browser" || selectedId != tab.id) return null
                val newTab = newTab(tab.private, focusHomeInput = false); newTab.url = uri
                // GeckoView opens the session returned here; using the normal helper
                // pre-opens it and crashes when Gecko handles the new window request.
                return GeckoResult.fromValue(newWindowSession(newTab))
            }
        }
        session.contentDelegate = object : GeckoSession.ContentDelegate {
            override fun onTitleChange(session: GeckoSession, title: String?) { tab.title = title ?: tab.url; persist() }
            override fun onFirstContentfulPaint(session: GeckoSession) {
                if (tab.session === session) tab.paintGeneration++
            }
            override fun onWebAppManifest(session: GeckoSession, manifest: JSONObject) {
                if (tab.session === session && !tab.private) tab.webAppManifest = manifest
            }
            override fun onExternalResponse(session: GeckoSession, response: WebResponse) {
                downloadHandler?.invoke(response, tab.private) ?: run { response.body?.close(); notice = "Download is unavailable while the browser is closed." }
            }
        }
        session.progressDelegate = object : GeckoSession.ProgressDelegate {
            override fun onSessionStateChange(session: GeckoSession, state: GeckoSession.SessionState) {
                if (tab.private || tab.session !== session || tabs.none { it === tab }) return
                val serialized = runCatching { state.toString() }.getOrNull()
                tab.savedSessionState = serialized?.takeIf { it.isNotBlank() && it.length <= SESSION_STATE_MAX_CHARS }
                persist()
            }
            override fun onPageStart(session: GeckoSession, url: String) { tab.loading = true; tab.error = null; clearRenderedText(tab) }
            override fun onPageStop(session: GeckoSession, success: Boolean) {
                tab.loading = false
                if (!success) tab.error = "This page could not finish loading. Try reloading."
                else {
                    tab.capture?.invoke {}
                    if (!tab.private && isHttpPage(tab.url)) {
                    // Start while the page is still the active browser surface. Chat navigation
                    // releases that surface immediately after startChat returns.
                    beginPageTextExtraction(tab, session, tab.url)
                    history.add(0, SavedPage(UUID.randomUUID().toString(), tab.title, tab.url)); persist()
                    }
                }
            }
        }
        tab.session = session
        if (openImmediately) {
            session.open(runtime)
            session.setPriorityHint(if (shouldKeepActive(tab)) GeckoSession.PRIORITY_HIGH else GeckoSession.PRIORITY_DEFAULT)
            session.setActive(shouldKeepActive(tab))
            val serializedState = tab.savedSessionState
            if (!tab.private && !serializedState.isNullOrBlank()) {
                tab.restoredSessionState = runCatching {
                    val restored = GeckoSession.SessionState.fromString(serializedState)
                        ?: throw IllegalArgumentException("Invalid Gecko session state")
                    session.restoreState(restored)
                    true
                }.getOrElse {
                    tab.savedSessionState = null
                    false
                }
            }
            pageControlsExtension?.let { attachPageControls(session, it) }
        }
        return session
    }
    fun toggleDesktop() {
        val current = selected ?: return
        val view = current.chromiumView ?: run { notice = "Open a web page before changing its layout."; return }
        current.desktopSite = !current.desktopSite
        val mobileAgent = android.webkit.WebSettings.getDefaultUserAgent(app)
        view.settings.userAgentString = if (current.desktopSite) {
            mobileAgent.replace(Regex("\\s\\(Linux; Android[^)]*\\)"), " (X11; Linux x86_64)")
                .replace(" Mobile Safari/", " Safari/").replace("; wv)", ")")
        } else null
        view.settings.useWideViewPort = current.desktopSite
        view.settings.loadWithOverviewMode = current.desktopSite
        view.reload()
    }
    fun bookmark() {
        val tab = selected ?: return
        if (tab.url.isBlank()) return
        if (tab.private) { notice = "Bookmarks from private tabs are not saved in this development build."; return }
        if (bookmarks.none { it.url == tab.url }) bookmarks.add(0, SavedPage(UUID.randomUUID().toString(), tab.title, tab.url))
        persist(); notice = "Bookmark saved"
    }
    fun removeBookmark(url: String) {
        if (bookmarks.removeAll { it.url == url }) {
            persist()
            notice = "Bookmark removed"
        }
    }
    fun startChat(prompt: String = "") {
        if (selected?.private == true) { notice = "Leave private browsing before starting a saved cloud conversation."; return }
        rememberChatReturnLocation()
        selected?.let { tab -> if (!tab.private) beginPageTextExtraction(tab, tab.session, tab.url) }
        val chat = LocalChat(title = prompt.take(70).ifEmpty { "New conversation" })
        chats.add(0, chat); activeChat = chat; contextTabId = selected?.id; includePageContext = true
        chatExpanded = selected?.url.isNullOrBlank()
        screen = "chat"
        if (prompt.isNotBlank()) sendChat(prompt)
        persist()
    }

    /** Start Nav from the home logo with a clean surface and no page context behind it. */
    fun startStandaloneNavChat() {
        if (selected?.private == true) {
            notice = "Leave private browsing before starting a saved cloud conversation."
            return
        }
        val chat = LocalChat(title = "New conversation")
        chats.add(0, chat)
        activeChat = chat
        contextTabId = null
        includePageContext = false
        chatReturnScreen = "blank"
        chatReturnTabId = ""
        chatExpanded = true
        navInputFocusRequested = true
        screen = "chat"
        persist()
    }

    /** Reopen the current Nav conversation over the selected tab without clearing its messages. */
    fun openNav() {
        if (screen == "chat") {
            chatExpanded = true
            navInputFocusRequested = true
            return
        }
        if (selected?.private == true) {
            notice = "Leave private browsing before starting a saved cloud conversation."
            return
        }
        val current = activeChat
        if (current != null && chats.any { it.id == current.id }) {
            rememberChatReturnLocation()
            contextTabId = selected?.id
            includePageContext = !selected?.url.isNullOrBlank()
            chatExpanded = selected?.url.isNullOrBlank()
            screen = "chat"
        } else startChat()
        navInputFocusRequested = true
    }

    fun consumeNavInputFocusRequest() { navInputFocusRequested = false }

    /** Open a response link while keeping the same conversation attached in the browser tray. */
    fun openSourceFromChat(url: String) {
        val safeUrl = normalizeOpenUrl(url) ?: return
        if (screen != "chat") {
            val existing = tabs.firstOrNull { !it.private && samePage(it.url, safeUrl) }
            if (existing != null) select(existing) else navigate(safeUrl, new = true)
            return
        }
        val retainedChat = activeChat
        val preopened = retainedChat?.takeIf { it.preopenedNavUrl.isNotBlank() && samePage(it.preopenedNavUrl, safeUrl) }
            ?.let { chat -> tabs.firstOrNull { !it.private && it.id == chat.preopenedNavTabId && samePage(it.url, safeUrl) } }
        val target = preopened ?: tabs.firstOrNull { !it.private && samePage(it.url, safeUrl) } ?: run {
            val tab = LiveTab(private = false).apply {
                this.url = safeUrl
                title = Uri.parse(safeUrl).host.orEmpty().removePrefix("www.").ifBlank { "New tab" }
                lastAccessedAt = System.currentTimeMillis()
            }
            tabs.add(tab)
            loadTab(tab, safeUrl)
            tab
        }

        if (retainedChat == null) {
            select(target)
            return
        }

        selected?.takeIf { it !== target }?.let(::deactivateSession)
        target.lastAccessedAt = System.currentTimeMillis()
        selectedId = target.id
        target.chromiumView?.onResume()
        target.session?.let { session ->
            session.setPriorityHint(GeckoSession.PRIORITY_HIGH)
            session.setActive(true)
        }
        homeInputFocusTabId = null
        if (retainedChat != null) activeChat = retainedChat
        chatReturnScreen = "browser"
        chatReturnTabId = target.id
        contextTabId = target.id
        includePageContext = true
        chatExpanded = false
        screen = "browser"
        persist()
    }

    /** Pre-open one destination only when the user's own turn clearly asks to visit a page. */
    private fun prepareExplicitNavOpen(chat: LocalChat, userPrompt: String, reply: String) {
        if (!hasExplicitOpenIntent(userPrompt)) return
        val url = extractDirectWebUrl(userPrompt)
            ?: chat.sources.firstOrNull()?.second?.let(::normalizeOpenUrl)
            ?: markdownWebLinks(reply).firstOrNull()?.let(::normalizeOpenUrl)
            ?: return

        val tab = tabs.firstOrNull { !it.private && samePage(it.url, url) } ?: run {
            val backgroundTab = LiveTab(private = false).apply {
                this.url = url
                title = Uri.parse(url).host.orEmpty().removePrefix("www.").ifBlank { "New tab" }
                lastAccessedAt = System.currentTimeMillis()
            }
            tabs.add(backgroundTab)
            loadTab(backgroundTab, url)
            backgroundTab
        }

        chat.preopenedNavUrl = url
        chat.preopenedNavTabId = tab.id
        selected?.takeIf { it !== tab }?.let(::deactivateSession)
        selectedId = tab.id
        tab.chromiumView?.onPause()
        tab.session?.let { session ->
            session.setPriorityHint(GeckoSession.PRIORITY_HIGH)
            session.setActive(true)
        }
        chatReturnScreen = "browser"
        chatReturnTabId = tab.id
        chatExpanded = false
        screen = "chat"
        persist()
    }

    private fun hasExplicitOpenIntent(prompt: String): Boolean {
        if (Regex("\\b(?:do\\s+not|don't|never)\\s+(?:please\\s+)?(?:open|visit|go\\s+to|navigate\\s+to|take\\s+me\\s+to)\\b", RegexOption.IGNORE_CASE)
                .containsMatchIn(prompt)) return false
        val intent = Regex("\\b(?:open|visit|go\\s+to|navigate\\s+to|take\\s+me\\s+to)\\b", RegexOption.IGNORE_CASE)
            .find(prompt) ?: return false
        val remainder = prompt.substring(intent.range.last + 1).trimStart(' ', ':', '-', '—')
        if (remainder.isBlank()) return false
        val directUrl = extractDirectWebUrl(prompt)
        if (directUrl != null) return true
        // Require an actual site/page target; pronouns and generic requests must not trigger a visit.
        if (Regex("\\b(?:[a-z0-9-]+\\.)+[a-z]{2,}\\b|\\b(?:the\\s+)?(?:site|website|page)\\s+(?:for\\s+)?[\\p{L}0-9]", RegexOption.IGNORE_CASE)
                .containsMatchIn(remainder)) return true
        val targetWords = remainder.lowercase().split(Regex("[^\\p{L}0-9]+"))
            .filter { it.isNotBlank() && it !in setOf("please", "thanks", "the", "a", "an", "in", "new", "tab") }
        return targetWords.isNotEmpty() && targetWords.first() !in setOf(
            "it", "this", "that", "there", "here", "them", "one", "first", "last", "top", "bottom",
            "page", "site", "website", "file", "document", "photo", "image", "attachment", "answer",
            "result", "search", "research", "thing", "whatever", "previous", "current", "same",
        )
    }

    private fun extractDirectWebUrl(text: String): String? {
        val match = Regex("(?:https?://|www\\.)[^\\s<>\\[\\]{}]+|\\b(?:[a-z0-9-]+\\.)+[a-z]{2,}(?:/[^\\s<>\\[\\]{}]*)?", RegexOption.IGNORE_CASE)
            .find(text)?.value?.trimEnd('.', ',', ';', ')', ']', '"', '\'') ?: return null
        return normalizeOpenUrl(match)
    }

    private fun markdownWebLinks(text: String): List<String> = Regex("\\[[^\\]]+]\\((https?://[^)\\s]+)\\)", RegexOption.IGNORE_CASE)
        .findAll(text).mapNotNull { normalizeOpenUrl(it.groupValues[1]) }.distinct().toList()

    private fun markdownWebLinkPairs(text: String): List<Pair<String, String>> = Regex("\\[([^\\]]+)]\\((https?://[^)\\s]+)\\)", RegexOption.IGNORE_CASE)
        .findAll(text)
        .mapNotNull { match -> normalizeOpenUrl(match.groupValues[2])?.let { match.groupValues[1].trim() to it } }
        .distinctBy { it.second }.toList()

    private fun normalizeOpenUrl(value: String): String? {
        val candidate = value.trim().let { if (it.startsWith("www.", true) || !it.contains("://")) "https://$it" else it }
        val uri = runCatching { Uri.parse(candidate) }.getOrNull() ?: return null
        if (uri.scheme !in listOf("http", "https") || uri.host.isNullOrBlank() || uri.userInfo != null) return null
        return candidate
    }

    private fun samePage(first: String, second: String): Boolean {
        val a = normalizeOpenUrl(first) ?: return false
        val b = normalizeOpenUrl(second) ?: return false
        val ua = Uri.parse(a); val ub = Uri.parse(b)
        fun key(uri: Uri) = uri.buildUpon().scheme(uri.scheme?.lowercase()).authority(uri.host?.lowercase() + (uri.port.takeIf { it >= 0 }?.let { ":$it" } ?: ""))
            .path(uri.path.orEmpty().trimEnd('/').ifEmpty { "/" }).build().toString().trimEnd('/')
        return key(ua).equals(key(ub), ignoreCase = true)
    }

    fun expandChat() { if (screen == "chat") chatExpanded = true }

    fun collapseChatOrReturn() {
        if (screen != "chat") return
        if (chatExpanded && selected?.url?.isNotBlank() == true) chatExpanded = false
        else returnFromChat()
    }

    fun acceptCloudDisclosure() {
        cloudDisclosureAccepted = true
        privacyPreferences.edit().putBoolean("cloud_ai_disclosure_accepted", true).apply()
        showCloudDisclosure = false
        val prompt = pendingCloudPrompt
        pendingCloudPrompt = null
        if (!prompt.isNullOrBlank()) sendChat(prompt)
        else notice = "Nav is ready. Your prompt and any attached context are sent only when you choose Send."
    }

    fun declineCloudDisclosure() {
        pendingCloudPrompt = null
        showCloudDisclosure = false
        notice = "Nothing was sent. You can review this choice in Settings."
    }

    fun revokeCloudDisclosure() {
        cloudDisclosureAccepted = false
        privacyPreferences.edit().putBoolean("cloud_ai_disclosure_accepted", false).apply()
        notice = "Nav cloud access is paused until you agree again."
    }

    fun requestCloudDisclosure() { showCloudDisclosure = true }

    fun queueImage(uri: String) {
        pendingImageUri = uri
        pendingImageRevision += 1
        if (screen != "chat") startChat()
    }
    fun removePendingImage() {
        pendingImageUri = null
        pendingImageRevision += 1
    }
    fun sendChat(prompt: String) {
        val attachedImageUri = pendingImageUri
        val attachmentRevision = pendingImageRevision
        val outgoingPrompt = prompt.trim().ifBlank { if (attachedImageUri != null) "What is in this image?" else return }
        val chat = activeChat ?: return
        if (chat.running) return
        if (attachedImageUri == null && ReminderRequestParser.isReminderRequest(outgoingPrompt)) {
            handleReminderRequest(chat, outgoingPrompt)
            return
        }
        if (attachedImageUri == null && outgoingPrompt.startsWith("open search results for ", ignoreCase = true)) {
            navigate(InputRouter.searchUrl(outgoingPrompt.substring(24), SearchEngine.SPECTRA), new = true)
            return
        }
        if (!cloudDisclosureAccepted) {
            pendingCloudPrompt = outgoingPrompt
            showCloudDisclosure = true
            return
        }
        if (chat.messages.isEmpty()) chat.title = when {
            outgoingPrompt.equals("/youtube", ignoreCase = true) || outgoingPrompt.startsWith("/youtube ", ignoreCase = true) -> "Creator breakdown"
            outgoingPrompt.equals("/summarize", ignoreCase = true) -> "Summarize ${contextTab?.title ?: "page"}"
            else -> outgoingPrompt.take(70)
        }
        val imageMessageIndex = chat.messages.size
        if (attachedImageUri != null) {
            chat.imagePreviews[imageMessageIndex] = attachedImageUri
        }
        chat.messages.add("user" to outgoingPrompt); persist()
        if (BuildConfig.CLOUD_TOKEN.isBlank() || BuildConfig.CLOUD_URL.isBlank()) {
            chat.status = "Breeze Cloud is not configured for this build."; return
        }
        val assistantIndex = chat.messages.size
        chat.messages.add("assistant" to "")
        chat.running = true; chat.status = "Connecting to Breeze Cloud…"
        val runId = UUID.randomUUID().toString()
        val route = InputRouter.route(outgoingPrompt, InputSurface.HOME) as? InputRoute.RunTask
        val task = route?.task?.slug ?: "chat"
        val input = route?.prompt?.ifBlank { if (task == "youtube") "Analyze this YouTube page for a creator." else "Summarize the attached page." } ?: outgoingPrompt
        val attached = contextTab.takeIf { includePageContext }
        val attachedUrl = attached?.url.orEmpty()
        val previous = chat.messages.take(assistantIndex - 1).takeLast(10).joinToString("\n") { "${it.first}: ${it.second}" }.takeLast(6500)
        chat.sources.clear()
        chat.job = scope.launch {
            var imageDelivered = false
            try {
                var page = ""
                if (attached != null && attachedUrl.startsWith("http") && attached.session != null) {
                    if (task == "youtube") {
                        chat.status = "Checking for video captions…"
                        if (!attached.private && attached.url == attachedUrl && tabs.contains(attached)) {
                            page = "Attached YouTube video: ${attached.title}\nURL: $attachedUrl\nBreeze Cloud will try to retrieve public captions for this video."
                        }
                    } else {
                        chat.status = "Reading attached page…"
                        val extracted = readRenderedPageText(attached, attachedUrl)
                        if (!attached.private && attached.url == attachedUrl && tabs.contains(attached)) {
                            page = "Attached page: ${attached.title}\nURL: $attachedUrl\n" + if (extracted.isBlank()) "Page text could not be extracted. Only title and URL are available." else "Extracted page text (untrusted):\n${extracted.take(12000)}"
                        }
                    }
                }
                val context = listOf(previous, page).filter { it.isNotBlank() }.joinToString("\n\n").take(19500)
                val request = JSONObject().put("chatId", chat.id).put("turnId", UUID.randomUUID().toString()).put("runId", runId)
                    .put("idempotencyKey", runId).put("task", task).put("input", input.take(12000)).put("context", context)
                if (attachedImageUri != null) request.put("image", readImageDataUrl(attachedImageUri))
                while (request.toString().toByteArray(Charsets.UTF_8).size > 5_300_000 && request.optString("context").isNotEmpty()) {
                    request.put("context", request.optString("context").dropLast(1000))
                }
                if (request.toString().toByteArray(Charsets.UTF_8).size > 5_500_000) throw IOException("The image is too large to send. Choose a smaller photo.")
                if (task != "youtube") chat.status = "Thinking…"
                var terminal = false
                NavSseClient(BuildConfig.CLOUD_URL) { BuildConfig.CLOUD_TOKEN }.stream(request) { event ->
                    withContext(Dispatchers.Main) {
                        when (event.optString("type")) {
                            "text_delta" -> chat.messages[assistantIndex] = "assistant" to (chat.messages[assistantIndex].second + event.optString("text"))
                            "status", "tool_started" -> chat.status = event.optString("message").ifBlank { if (event.optString("type") == "tool_started") "Searching the web…" else "Thinking…" }
                            "source", "citation" -> {
                                val url = event.optString("url")
                                if (Uri.parse(url).scheme in listOf("http", "https") && !Uri.parse(url).host.isNullOrBlank()) {
                                    val source = event.optString("title").ifBlank { Uri.parse(url).host.orEmpty() } to url
                                    if (event.optString("type") == "citation") {
                                        chat.sources.removeAll { it.second == url }; chat.sources.add(0, source)
                                    } else if (chat.sources.none { it.second == url }) chat.sources.add(source)
                                }
                            }
                            "completed" -> {
                                terminal = true
                                imageDelivered = true
                                val completedReply = chat.messages.getOrNull(assistantIndex)?.second.orEmpty()
                                markdownWebLinkPairs(completedReply).forEach { source ->
                                    if (chat.sources.none { it.second == source.second }) chat.sources.add(source)
                                }
                                if (task == "youtube") {
                                    completedReply.lineSequence().firstOrNull { it.isNotBlank() }?.let { line ->
                                        val candidate = line.trim().removePrefix("#").removePrefix("**").removeSuffix("**").trim().take(64)
                                        if (candidate.isNotBlank()) chat.title = uniqueChatTitle(candidate, chat)
                                    }
                                }
                                if (attachedImageUri != null && pendingImageUri == attachedImageUri && pendingImageRevision == attachmentRevision) {
                                    pendingImageUri = null
                                    pendingImageRevision += 1
                                }
                                chat.status = ""
                                chat.finishedReplies.add(assistantIndex)
                                prepareExplicitNavOpen(chat, outgoingPrompt, chat.messages.getOrNull(assistantIndex)?.second.orEmpty())
                            }
                            "failed" -> { terminal = true; chat.status = event.optString("message", "The request did not finish. Try again.") }
                        }
                    }
                }
                if (!terminal) chat.status = "The connection ended early. You can try again."
            } catch (cancelled: CancellationException) {
                chat.status = "Stopped"; throw cancelled
            } catch (error: Exception) {
                chat.status = "Could not connect to Breeze Cloud. ${error.message ?: "Try again."}"
            } finally {
                // Keep a failed or cancelled photo attached so the user can retry or remove it.
                // The URI is cleared only after the Worker finishes successfully; otherwise the
                // failed chat bubble must not strand the only reference to the selected photo.
                if (attachedImageUri != null && !imageDelivered) {
                    chat.imagePreviews.remove(imageMessageIndex)
                    if (pendingImageUri == null && pendingImageRevision == attachmentRevision) {
                        pendingImageUri = attachedImageUri
                    }
                }
                chat.running = false
                if (chat.messages.getOrNull(assistantIndex)?.second.isNullOrEmpty()) chat.messages.removeAt(assistantIndex)
                persist()
            }
        }
    }
    fun cancelChat() { activeChat?.job?.cancel() }

    private fun uniqueChatTitle(candidate: String, chat: LocalChat): String {
        val base = candidate.replace(Regex("\\s+"), " ").trim().take(64).ifBlank { "Creator breakdown" }
        val occupied = chats.asSequence().filter { it.id != chat.id }.map { it.title.trim() }.toSet()
        if (base !in occupied) return base
        var suffix = 2
        while ("$base ($suffix)" in occupied) suffix++
        return "$base ($suffix)".take(72)
    }

    private fun clearRenderedText(tab: LiveTab) {
        tab.renderedTextUrl = ""
        tab.renderedText = ""
        tab.extractionUrl = ""
        tab.extraction = null
    }

    /** Request rendered DOM text, never network-fetched page content. */
    private fun beginPageTextExtraction(tab: LiveTab, session: GeckoSession?, url: String, force: Boolean = false) {
        if (tab.private || !isHttpPage(url) || tab.url != url) return
        if (!force && tab.renderedTextUrl == url && tab.renderedText.isNotBlank()) return
        if (!force && tab.extractionUrl == url && tab.extraction != null) return

        tab.extractionUrl = url
        val chromium = tab.chromiumView
        if (chromium != null) {
            tab.extraction = null
            chromium.evaluateJavascript("(document.body?.innerText || '').slice(0, 60000)") { encoded ->
                scope.launch(Dispatchers.Main.immediate) {
                    if (!tab.private && tab.url == url && tab.extractionUrl == url) {
                        tab.renderedTextUrl = url
                        tab.renderedText = runCatching {
                            org.json.JSONTokener(encoded ?: "null").nextValue() as? String ?: ""
                        }.getOrDefault("")
                    }
                }
            }
            return
        }
        if (session == null) return
        val result = try {
            session.sessionPageExtractor.getPageContent(PageExtractionController.ContentParams(false, true))
        } catch (error: Exception) {
            tab.extraction = null
            Log.w("BreezePageContext", "Page extraction request failed (${error?.javaClass?.simpleName ?: "Unknown"})")
            return
        }
        tab.extraction = result
        result.accept({ text ->
            scope.launch(Dispatchers.Main.immediate) {
                if (!tab.private && tab.url == url && tab.extractionUrl == url) {
                    tab.renderedTextUrl = url
                    tab.renderedText = text.orEmpty()
                }
                if (tab.extractionUrl == url) tab.extraction = null
            }
        }, { error ->
            scope.launch(Dispatchers.Main.immediate) {
                if (tab.extractionUrl == url) tab.extraction = null
                Log.w("BreezePageContext", "Page extraction failed (${error?.javaClass?.simpleName ?: "Unknown"})")
            }
        })
    }

    private suspend fun awaitPageText(result: GeckoResult<String>?, timeoutMs: Long): String {
        if (result == null) return ""
        return withTimeoutOrNull(timeoutMs) {
            suspendCancellableCoroutine { continuation ->
                result.accept({ value ->
                    if (continuation.isActive) continuation.resume(value.orEmpty(), onCancellation = null)
                }, { error ->
                    if (continuation.isActive) continuation.resume("", onCancellation = null)
                    Log.w("BreezePageContext", "Page extraction failed (${error?.javaClass?.simpleName ?: "Unknown"})")
                })
            }
        }.orEmpty()
    }

    private suspend fun readRenderedPageText(tab: LiveTab, url: String): String {
        if (tab.private || !isHttpPage(url) || tab.url != url || !tabs.contains(tab)) return ""
        if (tab.renderedTextUrl == url && tab.renderedText.isNotBlank()) return tab.renderedText

        val chromiumView = tab.chromiumView
        if (chromiumView != null) {
            val text = withTimeoutOrNull(5000) {
                suspendCancellableCoroutine { continuation ->
                    chromiumView.post {
                        runCatching {
                            chromiumView.evaluateJavascript("(document.body?.innerText || '').slice(0, 60000)") { encoded ->
                                val value = runCatching {
                                    org.json.JSONTokener(encoded ?: "null").nextValue() as? String ?: ""
                                }.getOrDefault("")
                                if (continuation.isActive) continuation.resume(value, onCancellation = null)
                            }
                        }.onFailure { if (continuation.isActive) continuation.resume("", onCancellation = null) }
                    }
                }
            }.orEmpty()
            if (text.isNotBlank() && !tab.private && tab.url == url && tabs.contains(tab)) {
                tab.renderedTextUrl = url
                tab.renderedText = text
            }
            return text
        }

        val pending = tab.extraction.takeIf { tab.extractionUrl == url }
        val pendingText = awaitPageText(pending, 2500)
        if (pendingText.isNotBlank() && tab.url == url && tabs.contains(tab)) return pendingText
        if (tab.renderedTextUrl == url && tab.renderedText.isNotBlank()) return tab.renderedText

        // The AndroidView may already have released the session after Chat opened. Temporarily
        // reactivate this one session for a bounded extraction, then leave it inactive again.
        val session = tab.session ?: return ""
        if (tab.url != url || !tabs.contains(tab)) return ""
        val returnToInactiveState = screen != "browser"
        return try {
            session.setActive(true)
            beginPageTextExtraction(tab, session, url, force = true)
            awaitPageText(tab.extraction.takeIf { tab.extractionUrl == url }, 5000)
                .takeIf { tab.url == url && tabs.contains(tab) }.orEmpty()
        } finally {
            if (returnToInactiveState && screen != "browser") session.setActive(false)
        }
    }

    private fun isHttpPage(url: String): Boolean {
        val uri = Uri.parse(url)
        return uri.scheme in listOf("http", "https") && !uri.host.isNullOrBlank()
    }

    /** Encode a user-selected photo for the mobile Worker without writing its bytes to disk. */
    private suspend fun readImageDataUrl(uriText: String): String = withContext(Dispatchers.IO) {
        val uri = Uri.parse(uriText)
        val resolver = app.contentResolver
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
            ?: throw IOException("The selected photo is no longer available. Please attach it again.")
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw IOException("The selected file is not a readable image.")
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 2048) sample *= 2
        val decoded = BitmapFactory.Options().apply { inSampleSize = sample }
        val source = resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, decoded) }
            ?: throw IOException("The selected photo could not be opened. Please attach it again.")
        val bitmap: Bitmap = if (maxOf(source.width, source.height) > 2048) {
            val ratio = 2048f / maxOf(source.width, source.height)
            Bitmap.createScaledBitmap(source, (source.width * ratio).toInt().coerceAtLeast(1), (source.height * ratio).toInt().coerceAtLeast(1), true)
                .also { if (it !== source) source.recycle() }
        } else source
        try {
            var quality = 88
            var bytes: ByteArray
            do {
                val output = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.JPEG, quality, output)
                bytes = output.toByteArray()
                quality -= 6
            } while (bytes.size > 3_500_000 && quality >= 58)
            if (bytes.size > 3_500_000) throw IOException("The photo is too large to send. Choose a smaller image.")
            "data:image/jpeg;base64," + Base64.encodeToString(bytes, Base64.NO_WRAP)
        } finally {
            bitmap.recycle()
        }
    }

    private fun rememberChatReturnLocation() {
        if (screen == "chat") return
        // Nav is presented over the selected browser tab, including its blank new-tab page.
        chatReturnScreen = "browser"
        chatReturnTabId = selectedId
    }

    fun returnFromChat() {
        if (screen != "chat") return
        val returnTab = tabs.firstOrNull { it.id == chatReturnTabId }
        if (returnTab != null) {
            selectedId = returnTab.id
        } else {
            chatReturnScreen = "browser"
            chatReturnTabId = selectedId
        }
        screen = chatReturnScreen.takeUnless { it == "chat" } ?: "browser"
        persist()
    }

    fun openChat(chat: LocalChat) {
        rememberChatReturnLocation()
        activeChat = chat
        contextTabId = null
        includePageContext = false
        chatExpanded = true
        screen = "chat"
    }
    fun updateProtection(enabled: Boolean) {
        trackingProtection = enabled
        tabs.forEach { tab -> tab.session?.settings?.useTrackingProtection = siteProtectionOverrides[protectionKey(tab.url)] ?: enabled }
        persist()
    }
    fun isSiteProtectionEnabled(url: String = selected?.url.orEmpty()): Boolean = siteProtectionOverrides[protectionKey(url)] ?: trackingProtection
    fun setSiteProtectionEnabled(url: String, enabled: Boolean) {
        val key = protectionKey(url) ?: return
        siteProtectionOverrides[key] = enabled
        tabs.filter { protectionKey(it.url) == key }.forEach { tab -> tab.session?.settings?.useTrackingProtection = enabled }
        selected?.takeIf { protectionKey(it.url) == key }?.session?.reload()
        persist()
    }
    private fun protectionKey(url: String): String? = Uri.parse(url).host?.lowercase()?.removePrefix("www.")?.takeIf { it.isNotBlank() }
    fun updateCookieProtection(enabled: Boolean) {
        cookieProtection = enabled
        privacyPreferences.edit().putBoolean("cookie_protection", enabled).apply()
        applyCookieBehavior()
    }
    fun updateBlockAllCookies(enabled: Boolean) {
        blockAllCookies = enabled
        privacyPreferences.edit().putBoolean("block_all_cookies", enabled).apply()
        applyCookieBehavior()
    }
    private fun cookieBehavior(): Int = when {
        blockAllCookies -> ContentBlocking.CookieBehavior.ACCEPT_NONE
        cookieProtection -> ContentBlocking.CookieBehavior.ACCEPT_NON_TRACKERS
        else -> ContentBlocking.CookieBehavior.ACCEPT_ALL
    }
    private fun applyCookieBehavior() {
        val settings = runtime.settings.contentBlocking
        val behavior = cookieBehavior()
        settings.setCookieBehavior(behavior)
        settings.setCookieBehaviorPrivateMode(behavior)
        settings.setCookiePurging(cookieProtection || blockAllCookies)
    }
    fun clearCurrentSiteData() {
        val host = selected?.url?.let { Uri.parse(it).host }?.takeIf { it.isNotBlank() }
        if (host == null) { notice = "Open a website before clearing its data."; return }
        runtime.storageController.clearDataFromHost(host, StorageController.ClearFlags.SITE_DATA).accept({
            notice = "Cookies and site data cleared for $host. Reload the page to apply."
            selected?.session?.reload()
        }, { notice = "Could not clear data for this site. Please try again." })
    }
    fun updateHttpsOnly(enabled: Boolean) {
        httpsOnly = enabled
        persist()
    }
    fun clearBrowsingData(history: Boolean = true, cache: Boolean = true, cookiesAndSiteData: Boolean = true) {
        var flags = 0L
        if (cache) flags = flags or StorageController.ClearFlags.ALL_CACHES
        if (cookiesAndSiteData) flags = flags or StorageController.ClearFlags.SITE_DATA
        fun finish() {
            if (history) {
                this.history.clear()
                tabs.forEach { it.session?.purgeHistory() }
            }
            if (cache) clearThumbnailCache()
            persist()
            notice = when {
                history && cache && cookiesAndSiteData -> "History, cache, cookies, and site data cleared."
                history && cache -> "History and cache cleared."
                history && cookiesAndSiteData -> "History, cookies, and site data cleared."
                cache && cookiesAndSiteData -> "Cache, cookies, and site data cleared."
                history -> "Browsing history cleared."
                cache -> "Cache cleared."
                cookiesAndSiteData -> "Cookies and site data cleared."
                else -> "Nothing was selected."
            }
        }
        if (flags == 0L) finish()
        else runtime.storageController.clearData(flags).accept({ finish() }, { notice = "Could not clear the selected site data. Please try again." })
    }
    fun requestHidePageElement() {
        val tab = selected
        val session = tab?.session
        val host = protectionKey(tab?.url.orEmpty())
        if (tab == null || session == null || host == null || !isHttpPage(tab.url)) {
            notice = "Open a website and wait for it to finish loading first."
            return
        }
        if (tab.private) {
            notice = "Page-item hiding is unavailable in private tabs."
            return
        }
        if (pageControlsExtension == null) {
            notice = "Page controls are still starting. Try again in a moment."
            return
        }
        pendingElementPicks.add(session)
        val port = elementPickerPorts[session]
        if (port != null) {
            port.postMessage(JSONObject().put("type", "pick"))
        } else {
            notice = "The page picker is connecting. It will appear when the page controls are ready."
        }
    }
    fun hiddenPageElements(url: String = selected?.url.orEmpty()): List<String> =
        protectionKey(url)?.let { hiddenElementRules[it].orEmpty() }.orEmpty()

    fun removeHiddenPageElement(url: String, selector: String) {
        val host = protectionKey(url) ?: return
        val rules = hiddenElementRules[host].orEmpty().filterNot { it == selector }
        if (rules.isEmpty()) hiddenElementRules.remove(host) else hiddenElementRules[host] = rules
        tabs.filter { protectionKey(it.url) == host }.forEach(::sendElementRules)
        persist()
    }

    fun adjustPageZoom(delta: Int) {
        val tab = selected ?: return
        if (delta != -10 && delta != 10) return
        tab.zoomPercent = (tab.zoomPercent + delta).coerceIn(50, 200)
        tab.chromiumView?.settings?.textZoom = tab.zoomPercent
    }

    fun resetPageZoom() {
        val tab = selected ?: return
        if (tab.zoomPercent == 100) return
        tab.zoomPercent = 100
        tab.chromiumView?.settings?.textZoom = 100
    }

    private fun initializePageControls() {
        try {
            runtime.webExtensionController.ensureBuiltIn(
                "resource://android/assets/breeze_page_controls/",
                PAGE_CONTROLS_EXTENSION_ID,
            ).accept({ extension ->
                pageControlsExtension = extension
                extension?.setMessageDelegate(pageControlsDelegate, PAGE_CONTROLS_NATIVE_APP)
                pageControlsReady.complete(extension)
                if (extension != null) tabs.forEach { tab -> tab.session?.let { attachPageControls(it, extension) } }
            }, {
                pageControlsReady.complete(null)
                notice = "Page controls could not start. Browser protection still works."
            })
        } catch (_: Exception) {
            pageControlsReady.complete(null)
            notice = "Page controls could not start. Browser protection still works."
        }
    }

    private fun attachPageControls(session: GeckoSession, extension: WebExtension) {
        runCatching {
            session.webExtensionController.setMessageDelegate(extension, pageControlsDelegate, PAGE_CONTROLS_NATIVE_APP)
        }
    }

    private fun sendElementRules(tab: LiveTab, messageType: String = "apply", pick: Boolean = false) {
        val host = protectionKey(tab.url) ?: return
        val session = tab.session ?: return
        val port = elementPickerPorts[session] ?: return
        runCatching {
            port.postMessage(
                JSONObject()
                    .put("type", messageType)
                    .put("host", Uri.parse(tab.url).host.orEmpty().lowercase())
                    .put("selectors", JSONArray(if (tab.private) emptyList() else hiddenElementRules[host].orEmpty()))
                    .put("zoomPercent", tab.zoomPercent.coerceIn(50, 200))
                    .put("pick", pick),
            )
        }
    }

    private fun isSafeElementSelector(selector: String): Boolean =
        selector.length <= MAX_HIDDEN_SELECTOR_LENGTH && HIDDEN_SELECTOR_PATTERN.matches(selector)
    fun closeAllTabs(private: Boolean) {
        val closing = tabs.filter { it.private == private }
        if (closing.isEmpty()) return
        val selectedWasClosed = closing.any { it.id == selectedId }
        closing.forEach { tab ->
            tab.chromiumView?.let { view ->
                tab.chromiumView = null
                runCatching { view.stopLoading(); view.loadUrl("about:blank"); view.clearHistory(); view.removeAllViews(); view.destroy() }
            }
            tab.session?.let { session ->
                elementPickerPorts.remove(session)
                pageControlPorts.remove(session)?.toList()?.forEach { it.disconnect() }
                videoPortStates.remove(session)
                pendingElementPicks.remove(session)
                session.close()
            }
            tab.session = null
            deleteThumbnail(tab)
        }
        tabs.removeAll { it.private == private }
        if (private) runCatching { privateProfileCleaner?.invoke() }
        if (selectedWasClosed) {
            selectedId = ""
            homeInputFocusTabId = null
            isPictureInPicture = false
            newTab(private, focusHomeInput = false)
        } else {
            updateSessionPriorities()
            persist()
        }
    }
    fun saveThumbnail(tab: LiveTab, bitmap: android.graphics.Bitmap) {
        if (tab.private || bitmap.isRecycled) return
        tab.thumbnail = bitmap
        val tabId = tab.id
        scope.launch {
            thumbnailLock.withLock {
                withContext(Dispatchers.IO) { thumbnailStore.save(tabId, bitmap) }
            }
        }
    }
    fun loadThumbnail(tab: LiveTab) {
        if (tab.private || tab.thumbnail != null) return
        val tabId = tab.id
        scope.launch {
            val bitmap = thumbnailLock.withLock { withContext(Dispatchers.IO) { thumbnailStore.load(tabId) } }
            if (bitmap != null && tab.thumbnail == null && tabs.any { it === tab } && !tab.private) tab.thumbnail = bitmap
        }
    }
    private fun deleteThumbnail(tab: LiveTab) {
        tab.thumbnail = null
        val tabId = tab.id
        scope.launch { thumbnailLock.withLock { withContext(Dispatchers.IO) { thumbnailStore.delete(tabId) } } }
    }
    private fun clearThumbnailCache() {
        tabs.forEach { it.thumbnail = null }
        scope.launch { thumbnailLock.withLock { withContext(Dispatchers.IO) { thumbnailStore.clear() } } }
    }
    fun saveDownload(uri: String, name: String) {
        // Private downloads are saved by explicit file picker, but never retained in browser history.
        downloads.add(0, SavedDownload(UUID.randomUUID().toString(), name, uri)); persist()
    }
    fun removeDownload(id: String) { downloads.removeAll { it.id == id }; persist() }
    private fun handleReminderRequest(chat: LocalChat, prompt: String) {
        chat.messages.add("user" to prompt)
        val request = ReminderRequestParser.parse(prompt)
        if (request == null) {
            chat.messages.add("assistant" to "What day and time should I use? I opened the on-device reminder controls so you can choose it.")
            pendingReminderDraftDueAt = ReminderRequestParser.suggestedDueAt(prompt)
            pendingReminderDraft = ReminderRequestParser.taskTitle(prompt).ifBlank { prompt }
        } else {
            pendingReminderDraftDueAt = null
            pendingReminderRequest = request
        }
        if (chat.title == "New conversation") chat.title = "Reminder: ${ReminderRequestParser.taskTitle(prompt).take(42)}"
        persist()
    }

    fun consumePendingReminderRequest(): ParsedReminderRequest? = pendingReminderRequest.also { pendingReminderRequest = null }
    fun consumePendingReminderDraft(): String? = pendingReminderDraft.also { pendingReminderDraft = null }
    fun consumePendingReminderDraftDueAt(): Long? = pendingReminderDraftDueAt.also { pendingReminderDraftDueAt = null }

    fun finishChatReminder(request: ParsedReminderRequest) {
        val reminder = addReminder(request.title, request.dueAt, request.repeat)
        val scheduled = com.froydinger.breeze.notifications.ReminderScheduler.notificationsAllowed(app)
        activeChat?.let { chat ->
            val whenText = java.text.DateFormat.getDateTimeInstance(java.text.DateFormat.MEDIUM, java.text.DateFormat.SHORT).format(reminder.dueAt)
            val repeatText = if (reminder.repeat == ReminderRepeat.NONE) "" else " Repeats ${reminder.repeat.label.lowercase()}."
            val notificationText = if (scheduled) "" else " Android notifications are off, so turn them on in Settings to receive it."
            chat.messages.add("assistant" to "I’ll remind you to ${reminder.title} on this phone at $whenText.$repeatText$notificationText")
            chat.finishedReplies.add(chat.messages.lastIndex)
        }
        if (!scheduled) notice = "Reminder saved on this phone, but Android notifications are off."
        persist()
    }

    fun addReminder(title: String, dueAt: Long, repeat: ReminderRepeat = ReminderRepeat.NONE): LocalReminder {
        val repeatDay = java.time.Instant.ofEpochMilli(dueAt).atZone(java.time.ZoneId.systemDefault()).dayOfMonth
        val reminder = LocalReminder(title = title.trim(), dueAt = dueAt, repeat = repeat, repeatDayOfMonth = repeatDay)
        reminders.add(reminder)
        persist()
        com.froydinger.breeze.notifications.ReminderScheduler.schedule(app, reminder)
        return reminder
    }
    fun removeReminder(id: String) {
        reminders.removeAll { it.id == id }
        com.froydinger.breeze.notifications.ReminderScheduler.cancel(app, id)
        persist()
    }
    fun completeReminder(id: String) {
        val index = reminders.indexOfFirst { it.id == id }
        if (index < 0) return
        val reminder = reminders[index]
        if (reminder.repeat != ReminderRepeat.NONE) return
        reminders[index] = reminder.copy(deliveredAt = System.currentTimeMillis())
        com.froydinger.breeze.notifications.ReminderScheduler.cancel(app, id)
        persist()
    }

    fun advanceReminderOccurrence(id: String, dueAt: Long) {
        val index = reminders.indexOfFirst { it.id == id }
        if (index < 0) return
        val updated = reminders[index].copy(dueAt = dueAt)
        reminders[index] = updated
        persist()
        com.froydinger.breeze.notifications.ReminderScheduler.schedule(app, updated)
    }
    fun openDownload(entry: SavedDownload) {
        try {
            val uri = Uri.parse(entry.uri)
            app.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, app.contentResolver.getType(uri) ?: "*/*").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION))
        } catch (_: Exception) { notice = "This file cannot be opened. It may have moved, or need another app." }
    }
    fun share(): Intent? = selected?.url?.takeIf { it.isNotBlank() }?.let { Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, it), "Share page") }
    private fun launchExternalUri(uriText: String) {
        val uri = Uri.parse(uriText)
        if (uri.scheme.equals("intent", ignoreCase = true)) {
            val parsed = runCatching { Intent.parseUri(uriText, Intent.URI_INTENT_SCHEME) }.getOrNull()
                ?: return
            val fallback = parsed.getStringExtra("browser_fallback_url")
                ?.let { runCatching { Uri.parse(it) }.getOrNull() }
                ?.takeIf { it.scheme in setOf("http", "https") && !it.host.isNullOrBlank() }
            parsed.removeExtra("browser_fallback_url")
            parsed.component = null
            parsed.selector = null
            parsed.action = Intent.ACTION_VIEW
            if (parsed.data?.scheme?.lowercase() in setOf("javascript", "data", "file", "content", "about", "blob")) return
            parsed.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REQUIRE_NON_BROWSER
            parsed.addCategory(Intent.CATEGORY_BROWSABLE)
            if (runCatching { app.startActivity(parsed) }.isSuccess) return
            if (fallback != null) navigate(fallback.toString()) else notice = "No installed app can open this link."
            return
        }
        val action = when (uri.scheme?.lowercase()) {
            "mailto", "sms" -> Intent.ACTION_SENDTO
            "tel" -> Intent.ACTION_DIAL
            "geo", "market" -> Intent.ACTION_VIEW
            "javascript", "data", "file", "content", "about", "blob" -> return
            else -> Intent.ACTION_VIEW
        }
        val intent = Intent(action, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .addCategory(Intent.CATEGORY_BROWSABLE)
        runCatching { app.startActivity(intent) }.onFailure { notice = "No installed app can open this link." }
    }
    fun persist() {
        if (!ready || writeBlocked) return
        saveJob?.cancel()
        saveJob = scope.launch {
            delay(250)
            val state = snapshot()
            try { withContext(Dispatchers.IO) { store.save(state) } }
            catch (e: Exception) { notice = "Changes could not be saved. ${e.javaClass.simpleName}" }
        }
    }
    suspend fun persistImmediately(): Boolean {
        if (!ready || writeBlocked) return false
        saveJob?.cancel()
        saveJob = null
        val current = snapshot()
        return try {
            withContext(Dispatchers.IO) { store.save(current) }
            true
        } catch (e: Exception) {
            notice = "Changes could not be saved. ${e.javaClass.simpleName}"
            false
        }
    }
    private fun snapshot(): JSONObject = JSONObject().apply {
        put("httpsOnly", httpsOnly)
        put("reminders", JSONArray().apply { reminders.forEach { put(JSONObject().put("id", it.id).put("title", it.title).put("dueAt", it.dueAt).put("repeat", it.repeat.name).put("repeatDayOfMonth", it.repeatDayOfMonth).put("deliveredAt", it.deliveredAt ?: JSONObject.NULL)) } })
        put("downloads", JSONArray().apply { downloads.forEach { put(JSONObject().put("id",it.id).put("name",it.name).put("uri",it.uri).put("time",it.time)) } })
        put("schema", 1); put("selectedId", selected?.takeUnless { it.private }?.id ?: "")
        put("theme", theme.name); put("homeMode", homeMode.name); put("engine", engine.id); put("wallpaper", wallpaper); put("glass", glass); put("protection", trackingProtection)
        put("tabs", JSONArray().apply {
            tabs.filterNot { it.private }.forEach { tab ->
                put(JSONObject()
                    .put("id", tab.id)
                    .put("url", tab.url)
                    .put("title", tab.title)
                    .put("lastAccessedAt", tab.lastAccessedAt)
                    .put("sessionState", tab.savedSessionState?.takeIf { it.length <= SESSION_STATE_MAX_CHARS } ?: JSONObject.NULL))
            }
        })
        fun pages(pages: List<SavedPage>) = JSONArray().apply { pages.forEach { put(JSONObject().put("id", it.id).put("title", it.title).put("url", it.url).put("time", it.time)) } }
        put("history", pages(history)); put("bookmarks", pages(bookmarks))
        put("pinnedSites", JSONArray().apply { pinnedSites.forEach { put(JSONObject().put("id", it.id).put("title", it.title).put("url", it.url)) } })
        put("siteProtectionOverrides", JSONObject().apply { siteProtectionOverrides.forEach { (site, enabled) -> put(site, enabled) } })
        put("hiddenElementRules", JSONObject().apply {
            hiddenElementRules.forEach { (site, selectors) -> put(site, JSONArray(selectors.filter(::isSafeElementSelector).take(MAX_HIDDEN_ELEMENTS_PER_SITE))) }
        })
        put("chats", JSONArray().apply { chats.forEach { chat -> put(JSONObject().put("id", chat.id).put("title", chat.title).put("time", chat.time).put("finishedReplies", JSONArray(chat.finishedReplies.toList())).put("messages", JSONArray().apply { chat.messages.forEach { put(JSONObject().put("role", it.first).put("text", it.second)) } }).put("images", JSONArray().apply { chat.imagePreviews.forEach { (index, uri) -> put(JSONObject().put("index", index).put("uri", uri)) } }).put("sources", JSONArray().apply { chat.sources.forEach { put(JSONObject().put("title",it.first).put("url",it.second)) } })) } })
    }
    private fun restore(state: JSONObject) {
        httpsOnly = state.optBoolean("httpsOnly", true)
        theme = runCatching { ThemeMode.valueOf(state.optString("theme")) }.getOrDefault(ThemeMode.SYSTEM)
        homeMode = runCatching { HomeInputMode.valueOf(state.optString("homeMode")) }.getOrDefault(HomeInputMode.ASK)
        engine = SearchEngine.fromId(state.optString("engine")); wallpaper = state.optString("wallpaper", "teal_facets"); glass = state.optBoolean("glass", true); trackingProtection = state.optBoolean("protection", true)
        state.optJSONObject("siteProtectionOverrides")?.let { overrides ->
            val keys = overrides.keys()
            while (keys.hasNext()) {
                val site = keys.next()
                if (site.matches(Regex("[a-z0-9.-]{1,253}"))) siteProtectionOverrides[site] = overrides.optBoolean(site, true)
            }
        }
        state.optJSONObject("hiddenElementRules")?.let { sites ->
            val keys = sites.keys()
            while (keys.hasNext()) {
                val site = keys.next()
                if (!site.matches(Regex("[a-z0-9.-]{1,253}"))) continue
                val selectors = sites.optJSONArray(site) ?: continue
                val valid = buildList {
                    for (index in 0 until selectors.length()) {
                        val selector = selectors.optString(index)
                        if (isSafeElementSelector(selector) && selector !in this && size < MAX_HIDDEN_ELEMENTS_PER_SITE) add(selector)
                    }
                }
                if (valid.isNotEmpty()) hiddenElementRules[site] = valid
            }
        }
        fun JSONArray?.each(action: (JSONObject) -> Unit) { if (this != null) for (i in 0 until length()) optJSONObject(i)?.let(action) }
        state.optJSONArray("tabs").each { obj ->
            tabs.add(LiveTab(obj.getString("id")).apply {
                url = obj.optString("url")
                title = obj.optString("title", "New tab")
                lastAccessedAt = obj.optLong("lastAccessedAt", 0L).takeIf { it > 0L } ?: System.currentTimeMillis()
                savedSessionState = obj.optString("sessionState").takeIf { it.isNotBlank() && it != "null" && it.length <= SESSION_STATE_MAX_CHARS }
            })
        }
        tabs.sortByDescending { it.lastAccessedAt }
        selectedId = state.optString("selectedId").takeIf { id -> tabs.any { it.id == id } } ?: tabs.firstOrNull()?.id.orEmpty()
        val nonPrivateTabs = tabs.filterNot { it.private }
        val selectedThumbnail = nonPrivateTabs.firstOrNull { it.id == selectedId }?.let(::listOf).orEmpty()
        val restoreThumbnails = (nonPrivateTabs.takeLast(5) + selectedThumbnail).distinctBy { it.id }
        scope.launch {
            val restored = thumbnailLock.withLock {
                withContext(Dispatchers.IO) {
                    thumbnailStore.retain(nonPrivateTabs.mapTo(mutableSetOf()) { it.id })
                    restoreThumbnails.mapNotNull { tab -> thumbnailStore.load(tab.id)?.let { tab to it } }
                }
            }
            restored.forEach { (tab, bitmap) ->
                if (tabs.any { it === tab } && tab.thumbnail == null && !tab.private) tab.thumbnail = bitmap
            }
        }
        fun pages(name: String, target: SnapshotStateList<SavedPage>) { state.optJSONArray(name).each { target.add(SavedPage(it.getString("id"), it.getString("title"), it.getString("url"), it.optLong("time"))) } }
        state.optJSONArray("downloads").each { downloads.add(SavedDownload(it.getString("id"),it.getString("name"),it.getString("uri"),it.optLong("time"))) }
        state.optJSONArray("reminders").each {
            val repeat = runCatching { ReminderRepeat.valueOf(it.optString("repeat", "NONE")) }.getOrDefault(ReminderRepeat.NONE)
            val dueAt = it.optLong("dueAt")
            val fallbackDay = runCatching { java.time.Instant.ofEpochMilli(dueAt).atZone(java.time.ZoneId.systemDefault()).dayOfMonth }.getOrDefault(1)
            val deliveredAt = it.optLong("deliveredAt").takeIf { value -> value > 0L }
            reminders.add(LocalReminder(it.getString("id"), it.getString("title"), dueAt, repeat, it.optInt("repeatDayOfMonth", fallbackDay), deliveredAt))
        }
        pages("history", history); pages("bookmarks", bookmarks)
        if (state.has("pinnedSites")) {
            state.optJSONArray("pinnedSites").each { obj ->
                val url = obj.optString("url")
                val uri = Uri.parse(url)
                if (uri.scheme in listOf("http", "https") && !uri.host.isNullOrBlank()) {
                    pinnedSites.add(PinnedSite(obj.optString("id", UUID.randomUUID().toString()), obj.optString("title", uri.host.orEmpty()), url))
                }
            }
        } else {
            pinnedSites.addAll(defaultPinnedSites())
        }
        state.optJSONArray("chats").each { obj -> chats.add(LocalChat(obj.getString("id"), obj.getString("title"), obj.optLong("time", System.currentTimeMillis())).apply { obj.optJSONArray("finishedReplies")?.let { indices -> for (i in 0 until indices.length()) finishedReplies.add(indices.optInt(i)) }; obj.optJSONArray("messages").each { messages.add(it.getString("role") to it.getString("text")) }; obj.optJSONArray("images").each { image -> imagePreviews[image.optInt("index")] = image.optString("uri") }; obj.optJSONArray("sources").each { sources.add(it.getString("title") to it.getString("url")) } }) }
    }
}
