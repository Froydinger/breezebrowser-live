package com.froydinger.breeze

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibilityScope
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.expandVertically
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.ExperimentalSharedTransitionApi
import androidx.compose.animation.SharedTransitionLayout
import androidx.compose.animation.SharedTransitionScope
import androidx.compose.animation.SharedTransitionScope.OverlayClip
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.updateTransition
import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.zIndex
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import com.froydinger.breeze.core.*
import com.froydinger.breeze.ui.*
import org.mozilla.geckoview.GeckoView

class MainActivity : androidx.fragment.app.FragmentActivity() {
    private var browserCredentials: com.froydinger.breeze.browser.BrowserCredentials? = null
    private var browserPrompts: com.froydinger.breeze.browser.BrowserPrompts? = null
    private var browserPermissions: com.froydinger.breeze.browser.BrowserPermissions? = null
    private val browser get() = (application as BreezeApplication).browser
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState); enableEdgeToEdge()
        val prompts = com.froydinger.breeze.browser.BrowserPrompts(this, onNotice = { browser.notice = it }, onDownloadSaved = { uri, name -> browser.saveDownload(uri, name) })
        browserPrompts = prompts
        val credentials = com.froydinger.breeze.browser.BrowserCredentials(this) { browser.notice = it }
        browserCredentials = credentials
        browser.attachCredentials(credentials)
        val permissions = com.froydinger.breeze.browser.BrowserPermissions(
            this,
            onNotice = { browser.notice = it },
            resolveContext = { session ->
                browser.selected?.takeIf { browser.screen == "browser" && it.session === session }
                    ?.let { com.froydinger.breeze.browser.BrowserPermissions.PageContext(it.url, it.private) }
            },
        )
        browserPermissions = permissions
        browser.permissionDelegate = permissions
        browser.promptDelegate = object : org.mozilla.geckoview.GeckoSession.PromptDelegate by prompts {
            override fun onLoginSelect(session: org.mozilla.geckoview.GeckoSession, request: org.mozilla.geckoview.GeckoSession.PromptDelegate.AutocompleteRequest<org.mozilla.geckoview.Autocomplete.LoginSelectOption>) = credentials.onLoginSelect(session, request)
            override fun onLoginSave(session: org.mozilla.geckoview.GeckoSession, request: org.mozilla.geckoview.GeckoSession.PromptDelegate.AutocompleteRequest<org.mozilla.geckoview.Autocomplete.LoginSaveOption>) = credentials.onLoginSave(session, request)
        }
        browser.downloadHandler = { response, privateMode -> prompts.handleDownload(response, privateMode) }
        setContent { BreezeApp(browser) }
        if (savedInstanceState == null) BreezeSoundEffects.play(this, R.raw.app_start_up)
        handleIncomingIntent(intent)
    }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); setIntent(intent); handleIncomingIntent(intent) }
    private fun handleIncomingIntent(intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_VIEW -> intent.dataString?.let(browser::openExternalUrl)
            Intent.ACTION_SEND -> intent.getStringExtra(Intent.EXTRA_TEXT)?.let(browser::openSharedText)
        }
    }
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.S &&
            browser.selectedVideoIsPlaying &&
            packageManager.hasSystemFeature(android.content.pm.PackageManager.FEATURE_PICTURE_IN_PICTURE)
        ) {
            enterPictureInPictureMode(pictureInPictureParams(browser.selected))
        }
    }
    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: android.content.res.Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        browser.setPictureInPictureMode(isInPictureInPictureMode)
    }
    override fun onStart() { super.onStart(); browser.onAppForegrounded() }
    override fun onStop() { browser.onAppBackgrounded(); browser.persist(); super.onStop() }
    override fun onDestroy() { browserPrompts?.close(); browserCredentials?.close(); browserPermissions?.close(); browser.attachCredentials(null); browser.promptDelegate = null; browser.permissionDelegate = null; browser.downloadHandler = null; super.onDestroy() }
}

private data class BrowserPageMorph(
    val source: Rect,
    val target: Rect?,
    val progress: Float,
)

private fun pictureInPictureParams(tab: LiveTab?): android.app.PictureInPictureParams {
    val builder = android.app.PictureInPictureParams.Builder()
    val width = tab?.videoWidth ?: 0
    val height = tab?.videoHeight ?: 0
    if (width > 0 && height > 0) {
        val ratio = (width.toFloat() / height).coerceIn(.42f, 2.39f)
        val scale = 1000
        builder.setAspectRatio(android.util.Rational((ratio * scale).toInt().coerceAtLeast(1), scale))
    } else {
        builder.setAspectRatio(android.util.Rational(16, 9))
    }
    return builder.build()
}

@OptIn(ExperimentalSharedTransitionApi::class)
@Composable fun BreezeApp(state: BrowserState) {
    val dark = when (state.theme) { ThemeMode.SYSTEM -> isSystemInDarkTheme(); ThemeMode.DARK -> true; ThemeMode.LIGHT -> false }
    val palette = if (dark) darkColorScheme(primary=BreezeTeal, onPrimary=Color.White, onSecondary=Color.White, background=Color.Black, surface=Color.Black, onSurface=Color(0xFFF4F4F4), onSurfaceVariant=Color(0xFFB6B6B6), surfaceVariant=Color.Black, outline=Color(0xFF292929), outlineVariant=Color(0xFF191919), secondary=BreezeTeal, surfaceContainer=Color.Black, surfaceContainerHigh=Color.Black) else lightColorScheme(primary=Color(0xFF087C89), onPrimary=Color.White, onSecondary=Color.White, background=Color(0xFFF2F0ED), surface=Color(0xFFFAF9F7), onSurface=Color(0xFF23282B), onSurfaceVariant=Color(0xFF6A7075), surfaceVariant=Color(0xFFE5E6E5), outline=Color(0xFFC5C9CA), secondary=Color(0xFF087C89), surfaceContainer=Color(0xFFF9F8F6), surfaceContainerHigh=Color(0xFFE8E9E7))
    val activity = LocalContext.current as? android.app.Activity
    val context = LocalContext.current
    val onboardingPreferences = remember(context) { context.getSharedPreferences("breeze_onboarding", android.content.Context.MODE_PRIVATE) }
    var showOnboarding by remember(onboardingPreferences) { mutableStateOf(!onboardingPreferences.getBoolean("complete", false)) }
    LaunchedEffect(activity, dark) { activity?.let { AppIconManager.applyTheme(it, dark) } }
    val selectedForPip = state.selected
    LaunchedEffect(activity, state.selectedId, selectedForPip?.videoPlaying, selectedForPip?.videoWidth, selectedForPip?.videoHeight) {
        val host = activity ?: return@LaunchedEffect
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O &&
            host.packageManager.hasSystemFeature(android.content.pm.PackageManager.FEATURE_PICTURE_IN_PICTURE)
        ) {
            val builder = android.app.PictureInPictureParams.Builder()
            val width = selectedForPip?.videoWidth ?: 0
            val height = selectedForPip?.videoHeight ?: 0
            if (width > 0 && height > 0) {
                val ratio = (width.toFloat() / height).coerceIn(.42f, 2.39f)
                builder.setAspectRatio(android.util.Rational((ratio * 1000).toInt().coerceAtLeast(1), 1000))
            } else builder.setAspectRatio(android.util.Rational(16, 9))
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
                builder.setAutoEnterEnabled(state.selectedVideoIsPlaying && !state.isPictureInPicture)
                builder.setSeamlessResizeEnabled(true)
            }
            host.setPictureInPictureParams(builder.build())
        }
    }
    SideEffect {
        activity?.let {
            androidx.core.view.WindowCompat.getInsetsController(it.window, it.window.decorView).apply {
                isAppearanceLightStatusBars = !dark
                isAppearanceLightNavigationBars = !dark
            }
        }
        state.updateCredentialContext()
        if (state.selected?.private == true || state.screen == "passwords") activity?.window?.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
        else activity?.window?.clearFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
    }
    MaterialTheme(colorScheme = palette, typography = BreezeTypography, shapes = Shapes(extraSmall=RoundedCornerShape(12.dp), small=RoundedCornerShape(16.dp), medium=RoundedCornerShape(20.dp), large=RoundedCornerShape(28.dp), extraLarge=RoundedCornerShape(32.dp))) {
        CompositionLocalProvider(LocalGlassEnabled provides state.glass) {
            val snackbar = remember { SnackbarHostState() }
            LaunchedEffect(state.notice) { state.notice?.let { val text = it; state.notice = null; snackbar.showSnackbar(text) } }
            BackHandler(enabled=state.screen != "browser" || state.selected?.canBack == true) {
                if (state.screen == "chat") state.collapseChatOrReturn()
                else if (state.screen != "browser") state.screen = "browser"
                else state.selected?.session?.goBack()
            }
            SharedTransitionLayout(Modifier.fillMaxSize()) {
            val sharedTransitionScope = this
            Box(Modifier.fillMaxSize()) {
            val density = androidx.compose.ui.platform.LocalDensity.current
            val keyboardVisible = WindowInsets.ime.getBottom(density) > 0
            val tabUiEntrance = remember { Animatable(0f) }
            val tabMorphProgress = remember { Animatable(0f) }
            var selectedTabTileBounds by remember { mutableStateOf<Rect?>(null) }
            var tabMorphTargetBounds by remember { mutableStateOf<Rect?>(null) }
            var webSurfaceBounds by remember { mutableStateOf<Rect?>(null) }
            var tabMorphActive by remember { mutableStateOf(false) }
            var tabWallOpenPending by remember { mutableStateOf(false) }
            var previousScreen by remember { mutableStateOf(state.screen) }
            var previousTabId by remember { mutableStateOf(state.selectedId) }
            var tabSurfaceTransitionActive by remember { mutableStateOf(false) }
            val tabSurfaceTransition = tabSurfaceTransitionActive || ((previousScreen == "tabs") != (state.screen == "tabs"))
            val morphingTabWall = tabMorphActive ||
                (state.screen == "tabs" && previousScreen == "browser") ||
                (state.screen == "browser" && previousScreen == "tabs")
            val openTabWall = {
                if (state.screen != "tabs" && !tabWallOpenPending) {
                    tabWallOpenPending = true
                    val currentTab = state.selected
                    val showWall = {
                        selectedTabTileBounds = null
                        tabMorphTargetBounds = null
                        tabWallOpenPending = false
                        state.screen = "tabs"
                    }
                    val capture = currentTab?.capture
                    if (capture != null) runCatching { capture(showWall) }.onFailure { showWall() }
                    else showWall()
                }
            }
            LaunchedEffect(state.screen, state.selectedId) {
                val oldScreen = previousScreen
                val openingTabWall = state.screen == "tabs" && oldScreen == "browser"
                val returnedFromTabs = state.screen == "browser" && previousScreen == "tabs"
                val closingTabWall = returnedFromTabs
                val changedTab = state.screen == "browser" && previousTabId != state.selectedId
                val changingTabWall = (oldScreen == "tabs") != (state.screen == "tabs")
                if (changingTabWall) tabSurfaceTransitionActive = true
                if (state.screen == "tabs") {
                    tabUiEntrance.snapTo(0f)
                } else if (returnedFromTabs || changedTab) {
                    tabUiEntrance.snapTo(1f)
                } else if (tabUiEntrance.value < 1f) {
                    tabUiEntrance.snapTo(1f)
                }
                when {
                    openingTabWall -> {
                        tabMorphTargetBounds = null
                        tabMorphActive = true
                        tabMorphProgress.snapTo(0f)
                        val target = kotlinx.coroutines.withTimeoutOrNull(450L) {
                            snapshotFlow { selectedTabTileBounds }
                                .first { it != null }
                        }
                        if (target != null) {
                            tabMorphTargetBounds = target
                            tabMorphProgress.animateTo(1f, tween(340, easing = FastOutSlowInEasing))
                        }
                        tabMorphActive = false
                    }
                    closingTabWall -> {
                        tabMorphActive = true
                        tabMorphTargetBounds = selectedTabTileBounds
                        tabMorphProgress.snapTo(1f)
                        tabMorphProgress.animateTo(0f, tween(340, easing = FastOutSlowInEasing))
                        tabMorphActive = false
                        selectedTabTileBounds = null
                        tabMorphTargetBounds = null
                    }
                    changingTabWall -> delay(260)
                }
                previousScreen = state.screen
                previousTabId = state.selectedId
                if (changingTabWall) tabSurfaceTransitionActive = false
            }
            val chatHeightFraction by animateFloatAsState(
                targetValue = if (state.chatExpanded || keyboardVisible) 1f else .78f,
                animationSpec = tween(300, easing = androidx.compose.animation.core.FastOutSlowInEasing),
                label = "Nav tray height",
            )
            val selectedPage = state.selected
            LaunchedEffect(
                state.overlayBackdropRequested,
                state.selectedId,
                selectedPage?.url,
                selectedPage?.zoomPercent,
                selectedPage?.loading,
            ) {
                if (state.overlayBackdropRequested) {
                    // Avoid snapshotting the old document at navigation start. When loading
                    // flips back to false this effect runs again and captures the finished page.
                    if (selectedPage?.loading == true) return@LaunchedEffect
                    selectedPage?.captureOverlay?.invoke()
                    delay(140)
                    if (state.overlayBackdropRequested && selectedPage != null && state.selectedId == selectedPage.id) {
                        selectedPage.captureOverlay?.invoke()
                    }
                } else {
                    delay(240)
                    if (!state.overlayBackdropRequested) state.clearOverlayBackdrop()
                }
            }
            val pageChromeCollapsed = !state.isHomePage &&
                state.selected?.chromeCollapsed == true &&
                (state.screen == "browser" || state.screen == "tabs" || state.screen == "chat" && state.chatReturnScreen == "browser") &&
                !keyboardVisible
            val chromeTransition = updateTransition(pageChromeCollapsed, label = "Browser chrome collapse")
            val collapseProgress by chromeTransition.animateFloat(
                transitionSpec = { tween(320, easing = androidx.compose.animation.core.FastOutSlowInEasing) },
                label = "Browser chrome collapse progress",
            ) { if (it) 1f else 0f }
            Scaffold(
                containerColor = if (state.isPictureInPicture) Color.Black else palette.background,
                snackbarHost = { if (!state.isPictureInPicture) SnackbarHost(snackbar) },
                contentWindowInsets = if (state.isPictureInPicture) WindowInsets(0, 0, 0, 0) else WindowInsets.safeDrawing.only(WindowInsetsSides.Top),
            ) { insets ->
                Box(Modifier.fillMaxSize().padding(insets).consumeWindowInsets(insets).imePadding()) {
                    if (!state.ready) CircularProgressIndicator(Modifier.align(Alignment.Center))
                    else {
                        val backgroundScreen = if (state.screen == "chat") state.chatReturnScreen else state.screen
                        if (backgroundScreen in setOf("browser", "tabs")) {
                            val showingHome = state.isHomePage
                            val source = webSurfaceBounds
                            val target = tabMorphTargetBounds ?: selectedTabTileBounds
                            val progress = if (morphingTabWall) tabMorphProgress.value.coerceIn(0f, 1f) else 0f
                            if (showingHome) {
                                val morphHome = morphingTabWall && source != null && target != null
                                val homeWidth = source?.width?.coerceAtLeast(1f) ?: 1f
                                val homeHeight = source?.height?.coerceAtLeast(1f) ?: 1f
                                val homeFrameWidth = if (morphHome) homeWidth + (target!!.width - homeWidth) * progress else homeWidth
                                val homeFrameHeight = if (morphHome) homeHeight + (target!!.height - homeHeight) * progress else homeHeight
                                val homeModifier = if (morphHome) {
                                    Modifier.offset {
                                        IntOffset(((target!!.left - source!!.left) * progress).toInt(), ((target.top - source.top) * progress).toInt())
                                    }.size((homeFrameWidth / density.density).dp, (homeFrameHeight / density.density).dp)
                                        .clip(RoundedCornerShape(11.dp * progress)).zIndex(2f)
                                } else {
                                    Modifier.fillMaxSize().onGloballyPositioned { coordinates ->
                                        if (!morphingTabWall) webSurfaceBounds = coordinates.boundsInRoot()
                                    }
                                }
                                Layout(
                                    content = {
                                        ReferenceHomeScreen(
                                            state,
                                            dark,
                                            tabUiEntrance.value,
                                            modifier = Modifier.fillMaxSize(),
                                            preserveSurfaceViewport = morphingTabWall,
                                        )
                                    },
                                    modifier = homeModifier,
                                ) { measurables, constraints ->
                                    val sourceWidthPx = if (source != null) homeWidth.toInt().coerceAtLeast(1) else constraints.maxWidth
                                    val sourceHeightPx = if (source != null) homeHeight.toInt().coerceAtLeast(1) else constraints.maxHeight
                                    val page = measurables.single().measure(Constraints.fixed(sourceWidthPx, sourceHeightPx))
                                    layout(constraints.maxWidth, constraints.maxHeight) {
                                        val scale = if (morphHome) maxOf(constraints.maxWidth.toFloat() / sourceWidthPx, constraints.maxHeight.toFloat() / sourceHeightPx) else 1f
                                        val childLeft = ((constraints.maxWidth - sourceWidthPx * scale) / 2f).toInt()
                                        val childTop = ((constraints.maxHeight - sourceHeightPx * scale) / 2f).toInt()
                                        page.placeWithLayer(childLeft, childTop) {
                                            scaleX = scale
                                            scaleY = scale
                                            transformOrigin = androidx.compose.ui.graphics.TransformOrigin(0f, 0f)
                                        }
                                    }
                                }
                            } else {
                                val pageMorph = if (morphingTabWall && source != null) {
                                    BrowserPageMorph(source, target, progress)
                                } else null
                                WebScreen(
                                    state,
                                    collapseProgress,
                                    tabUiEntrance.value,
                                    preserveSurfaceViewport = true,
                                    pageMorph = pageMorph,
                                    onPageViewportBoundsChanged = { bounds ->
                                        if (!morphingTabWall) webSurfaceBounds = bounds
                                    },
                                    modifier = Modifier.fillMaxSize().zIndex(if (pageMorph != null) 2f else 0f),
                                )
                            }
                        }
                        AnimatedContent(
                            targetState = if (state.isPictureInPicture) "browser" else backgroundScreen,
                            modifier = Modifier.fillMaxSize(),
                            transitionSpec = {
                                if (state.isPictureInPicture || targetState == "tabs") {
                                    EnterTransition.None togetherWith ExitTransition.None
                                } else if (initialState == "tabs") {
                                    EnterTransition.None togetherWith fadeOut(tween(340, easing = FastOutSlowInEasing))
                                } else {
                                    val enteringBrowser = targetState == "browser"
                                    val leavingBrowser = initialState == "browser"
                                    (slideInHorizontally(
                                        animationSpec = tween(260, easing = FastOutSlowInEasing),
                                        initialOffsetX = { fullWidth -> if (enteringBrowser) fullWidth / 10 else -fullWidth / 10 },
                                    )) togetherWith
                                        (slideOutHorizontally(
                                            animationSpec = tween(230, easing = FastOutSlowInEasing),
                                            targetOffsetX = { fullWidth -> if (leavingBrowser) -fullWidth / 10 else fullWidth / 10 },
                                        ))
                                }
                            },
                            label = "Browser surfaces",
                        ) { visibleScreen ->
                            val animatedVisibilityScope = this
                            when (visibleScreen) {
                                "blank" -> Box(Modifier.fillMaxSize().background(palette.background))
                                "tabs" -> TabWallScreen(state, tabSurfaceTransition) { bounds -> selectedTabTileBounds = bounds }
                                "history" -> LibraryScreen(state)
                                "library" -> LibraryScreen(state, "Bookmarks")
                                "chats" -> LibraryScreen(state, "Chats")
                                "settings" -> SettingsScreen(state)
                                "reminders" -> ReminderManagerScreen(state)
                                "passwords" -> PasswordVaultScreen()
                                "downloads" -> DownloadsScreen(state)
                                else -> Box(Modifier.fillMaxSize())
                            }
                        }
                        AnimatedVisibility(
                            visible = state.screen == "chat" && !state.isPictureInPicture,
                            modifier = Modifier.align(Alignment.BottomCenter).fillMaxWidth()
                                .fillMaxHeight(chatHeightFraction),
                            enter = slideInVertically(initialOffsetY = { it }, animationSpec = tween(280)) + fadeIn(tween(180)),
                            exit = slideOutVertically(targetOffsetY = { it }, animationSpec = tween(220)) + fadeOut(tween(150)),
                        ) {
                            NavChatScreen(state, Modifier.fillMaxSize())
                        }
                    }
                }
            }
            if (!keyboardVisible && !state.isPictureInPicture) {
                val shelfCollapse = if (state.screen == "browser" && !state.isHomePage) collapseProgress else 0f
                if (state.screen != "tabs") BottomShelf(state, shelfCollapse, Modifier.align(Alignment.BottomCenter))
                AnimatedVisibility(
                    visible = state.screen != "tabs",
                    modifier = Modifier.align(Alignment.BottomCenter).fillMaxWidth(),
                    enter = slideInVertically(initialOffsetY = { it }, animationSpec = tween(320, easing = FastOutSlowInEasing)) + fadeIn(tween(220)),
                    exit = slideOutVertically(targetOffsetY = { it }, animationSpec = tween(260, easing = FastOutSlowInEasing)) + fadeOut(tween(180)),
                ) {
                    BottomBar(state, shelfCollapse, Modifier.fillMaxWidth(), onOpenTabs = openTabWall)
                }
            }
            if (state.showCloudDisclosure && !state.isPictureInPicture) AlertDialog(
                onDismissRequest = state::declineCloudDisclosure,
                title = { Text("Before Nav connects") },
                text = {
                    Column(verticalArrangement = Arrangement.spacedBy(9.dp)) {
                        Text("When you send a Nav request, Breeze Cloud and OpenAI receive your prompt and recent chat context. If you attach a page, its title, URL, and readable text can be included. For a YouTube Creator Breakdown, Breeze Cloud may retrieve public captions for that video and send up to 14,000 characters with your request. A photo stays on this device until you tap Send, then it is uploaded with the request.")
                        Text("Voice recordings are sent for transcription; the transcript is then sent to Nav. OpenAI may retain API request data for up to 30 days for abuse prevention.")
                        Text("Browsing history, bookmarks, and chats are stored locally on this device. Cloud sync is coming soon.")
                    }
                },
                confirmButton = { TextButton(onClick = state::acceptCloudDisclosure) { Text("Agree and continue") } },
                dismissButton = { TextButton(onClick = state::declineCloudDisclosure) { Text("Not now") } },
            )
            if (state.ready && showOnboarding && !state.isPictureInPicture) FirstRunOnboarding {
                onboardingPreferences.edit().putBoolean("complete", true).apply()
                showOnboarding = false
            }
            }
            }
        }
    }
}

@Composable private fun BottomShelf(state: BrowserState, collapseProgress: Float, modifier: Modifier = Modifier) {
    val density = androidx.compose.ui.platform.LocalDensity.current
    val page = state.selected
    val dark = MaterialTheme.colorScheme.background.red < .3f
    val collapsed = state.screen == "browser" && !state.isHomePage && page?.chromeCollapsed == true
    val navInset = with(density) { WindowInsets.navigationBars.getBottom(this).toDp() }
    val expandedBodyHeight = BottomBarHeight + BottomBarVerticalPadding * 2
    val compactBodyHeight = CollapsedBottomBarHeight + CompactBottomBarVerticalPadding * 2
    val height = navInset + expandedBodyHeight
    val travel = with(density) { (expandedBodyHeight - compactBodyHeight).toPx() * collapseProgress }
    Box(modifier.fillMaxWidth().height(height).clipToBounds()) {
        Box(
            Modifier.fillMaxSize()
                .align(Alignment.BottomCenter)
                .graphicsLayer { translationY = travel },
        ) {
            Box(Modifier.fillMaxSize().shadow(5.dp, androidx.compose.ui.graphics.RectangleShape).background(if (dark) Color.Black else Color.White))
            Box(
                Modifier.fillMaxWidth().height(8.dp).align(Alignment.TopCenter)
                    .background(Brush.verticalGradient(
                        if (dark) listOf(Color.White.copy(alpha = .055f), Color.Transparent)
                        else listOf(Color.Black.copy(alpha = .045f), Color.Transparent),
                    )).blur(6.dp),
            )
            androidx.compose.foundation.Canvas(Modifier.fillMaxSize()) {
                drawLine(
                    if (state.isHomePage) {
                        if (dark) Color.White.copy(alpha = .14f) else Color.Black.copy(alpha = .10f)
                    } else BreezeTeal.copy(alpha = if (dark) .42f else .34f),
                    androidx.compose.ui.geometry.Offset(0f, .5.dp.toPx()),
                    androidx.compose.ui.geometry.Offset(size.width, .5.dp.toPx()),
                    1.dp.toPx(),
                )
            }
        }
        if (collapsed) {
            Box(
                Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(navInset + compactBodyHeight)
                    .clickable(indication = null, interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }) { page?.chromeCollapsed = false },
            )
        }
    }
}

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable private fun BottomBar(state: BrowserState, collapseProgress: Float, modifier: Modifier = Modifier, onOpenTabs: () -> Unit) {
    val page = state.selected
    val canCollapse = state.screen == "browser" || state.screen == "chat" && state.chatReturnScreen == "browser"
    val progress = if (canCollapse) collapseProgress else 0f
    val buttonSize = 48.dp
    val iconSize = 24.dp
    val navSize = 56.dp
    val tint = MaterialTheme.colorScheme.onSurface
    val bodyHeight = BottomBarHeight * (1f - progress) + CollapsedBottomBarHeight * progress
    val verticalPadding = BottomBarVerticalPadding * (1f - progress) + CompactBottomBarVerticalPadding * progress
    var recentTabsOpen by remember { mutableStateOf(false) }
    val context = LocalContext.current
    Box(modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal=12.dp).padding(vertical=verticalPadding), contentAlignment=Alignment.Center) {
        if (progress < .82f) Row(
            Modifier.fillMaxWidth().height(bodyHeight).graphicsLayer {
                val uniformScale = 1f - .20f * progress
                scaleX = uniformScale
                scaleY = uniformScale
                alpha = 1f - progress
                transformOrigin = androidx.compose.ui.graphics.TransformOrigin.Center
            },
            horizontalArrangement=Arrangement.SpaceAround,
            verticalAlignment=Alignment.CenterVertically,
        ) {
            val backEnabled = state.screen != "browser" || page?.canBack == true
            IconButton(
                onClick={ if(state.screen == "chat") state.collapseChatOrReturn() else if(state.screen != "browser") state.screen="browser" else page?.session?.goBack() },
                enabled=backEnabled,
                modifier=Modifier.size(buttonSize),
            ) { Icon(BreezeIcons.ArrowBack,"Back",Modifier.size(iconSize), tint=if (backEnabled) tint else tint.copy(alpha = .32f)) }
            if (state.screen != "chat") {
                val forwardEnabled = state.screen == "browser" && page?.canForward == true
                IconButton(onClick={page?.session?.goForward()}, enabled=forwardEnabled, modifier=Modifier.size(buttonSize)) {
                    Icon(BreezeIcons.ArrowForward,"Forward",Modifier.size(iconSize), tint=if (forwardEnabled) tint else tint.copy(alpha = .32f))
                }
            } else Spacer(Modifier.size(buttonSize))
            Spacer(Modifier.size(buttonSize))
            if (state.screen != "chat") {
                if (state.screen == "browser" && !state.isHomePage) IconButton(onClick={state.share()?.let(context::startActivity) }, modifier=Modifier.size(buttonSize)) { Icon(BreezeIcons.Share,"Share page",Modifier.size(iconSize), tint=tint) }
                else Spacer(Modifier.size(buttonSize))
                Box {
                Box(Modifier.size(buttonSize).semantics { contentDescription = "Tabs. Long press for recent tabs" }
                    .combinedClickable(
                        onClick = {
                            val tab = state.selected
                            if (tab == null || state.selectedId == tab.id) onOpenTabs()
                        },
                        onLongClick = { recentTabsOpen = true },
                    ), contentAlignment=Alignment.Center) {
                    Box(Modifier.size(25.dp).border(1.7.dp,tint,RoundedCornerShape(6.dp)),contentAlignment=Alignment.Center) {Text("${state.tabs.size}",fontSize=12.sp,color=tint)}
                }
                    DropdownMenu(expanded = recentTabsOpen, onDismissRequest = { recentTabsOpen = false }) {
                        val recentTabs = state.tabs.filter { it.id != state.selectedId }
                            .sortedByDescending { it.lastAccessedAt }.take(5)
                        if (recentTabs.isEmpty()) {
                            DropdownMenuItem(text = { Text("No other recent tabs") }, enabled = false, onClick = {})
                        } else recentTabs.forEach { tab ->
                            val host = runCatching { android.net.Uri.parse(tab.url).host.orEmpty().removePrefix("www.") }.getOrDefault("")
                            DropdownMenuItem(
                                text = { Text(tab.title.ifBlank { host.ifBlank { "New tab" } }, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                                leadingIcon = { Icon(if (tab.private) BreezeIcons.VisibilityOff else BreezeIcons.Language, contentDescription = null) },
                                onClick = { recentTabsOpen = false; state.select(tab) },
                            )
                        }
                        HorizontalDivider()
                        DropdownMenuItem(
                            text = { Text("All tabs") },
                            leadingIcon = { Icon(BreezeIcons.Tab, contentDescription = null) },
                            onClick = {
                                recentTabsOpen = false
                                val tab = state.selected
                                if (tab == null || state.selectedId == tab.id) onOpenTabs()
                            },
                        )
                    }
                }
            } else Spacer(Modifier.size(buttonSize))
        }
        if (progress < .82f) {
            Box(
                Modifier.align(Alignment.Center).offset(y = (-5).dp).size(72.dp)
                    .graphicsLayer {
                        val uniformScale = 1f - .20f * progress
                        scaleX = uniformScale
                        scaleY = uniformScale
                        alpha = 1f - progress
                    },
                contentAlignment = Alignment.Center,
            ) {
                when {
                    state.screen == "browser" && state.isHomePage -> IconButton(
                        onClick = { state.screen = "settings" },
                        modifier = Modifier.size(56.dp),
                    ) { Icon(BreezeIcons.Settings, "Settings", Modifier.size(25.dp), tint = tint) }
                    state.screen == "browser" -> Box(
                        Modifier.size(72.dp)
                            .shadow(7.dp, CircleShape, clip = false)
                            .clip(CircleShape)
                            .background(
                                Brush.radialGradient(
                                    listOf(
                                        BreezeTeal.copy(alpha = if (MaterialTheme.colorScheme.background.red < .3f) .25f else .18f),
                                        if (MaterialTheme.colorScheme.background.red < .3f) Color(0xFF101313) else Color(0xFFF9FBFA),
                                    ),
                                ),
                            )
                            .border(1.dp, BreezeTeal.copy(alpha = .48f), CircleShape)
                            .semantics { contentDescription = "Open Nav" }
                            .clickable { state.openNav() },
                        contentAlignment = Alignment.Center,
                    ) { NavMark(navSize, glowing = state.activeChat?.running == true) }
                }
            }
        }
        if (progress > .001f) {
            Box(
                Modifier.size(34.dp)
                    .graphicsLayer { alpha = progress; scaleX = .82f + .18f * progress; scaleY = .82f + .18f * progress }
                    .offset(y = 5.dp)
                    .semantics { if (progress > .82f) contentDescription = "Show browser controls" }
                    .clickable(enabled = progress > .82f) { page?.chromeCollapsed = false },
                contentAlignment = Alignment.Center,
            ) { Icon(BreezeIcons.ChevronUp, contentDescription = null, tint = tint, modifier = Modifier.size(19.dp)) }
        }
    }
}
private val BottomBarHeight = 58.dp
private val BottomBarVerticalPadding = 8.dp
private val CollapsedBottomBarHeight = 27.dp
private val CompactBottomBarVerticalPadding = 0.dp
@Composable private fun AddressField(state: BrowserState, home: Boolean) {
    val context = LocalContext.current
    var text by remember(state.selectedId) { mutableStateOf(if(home) "" else state.selected?.url.orEmpty()) }
    var editing by remember(state.selectedId) { mutableStateOf(false) }
    var refreshAngle by remember(state.selectedId) { mutableFloatStateOf(0f) }
    var refreshPull by remember(state.selectedId) { mutableFloatStateOf(0f) }
    val refreshRotation by animateFloatAsState(refreshAngle, tween(440), label = "Refresh rotation")
    val currentEditing by rememberUpdatedState(editing)
    val currentPage by rememberUpdatedState(state.selected)
    val currentHome by rememberUpdatedState(home)
    val density = androidx.compose.ui.platform.LocalDensity.current.density
    val keyboardController = androidx.compose.ui.platform.LocalSoftwareKeyboardController.current
    val currentUrl = state.selected?.url.orEmpty()
    val compactAddress = remember(currentUrl) {
        val host = runCatching { android.net.Uri.parse(currentUrl).host.orEmpty() }.getOrDefault("").removePrefix("www.")
        (host.ifBlank { currentUrl.substringAfter("://", currentUrl).substringBefore('/') }).let { if (it.isBlank()) "" else "$it…" }
    }
    LaunchedEffect(currentUrl, editing) { if (!editing && !home) text = currentUrl }
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = if (home) Arrangement.spacedBy(0.dp) else Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (!home) IconButton(onClick = state::home, modifier = Modifier.size(40.dp)) {
            Icon(BreezeIcons.Home, "New tab", Modifier.size(20.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Box(
        Modifier.weight(1f)
            .breezeGlass(if (home) 32.dp else 100.dp)
            .pointerInput(state.selectedId, home) {
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false)
                    if (currentHome || currentEditing || currentPage?.chromeCollapsed == true) return@awaitEachGesture
                    var totalY = 0f
                    var totalX = 0f
                    var pullGesture = false
                    var ended = false
                    val touchSlop = viewConfiguration.touchSlop
                    val refreshDistance = 58.dp.value * density
                    while (!ended) {
                        val event = awaitPointerEvent(PointerEventPass.Initial)
                        val change = event.changes.firstOrNull() ?: break
                        val delta = change.position - change.previousPosition
                        totalY += delta.y
                        totalX += delta.x
                        if (!pullGesture && totalY > touchSlop && totalY > kotlin.math.abs(totalX) * 1.25f) {
                            pullGesture = true
                        }
                        if (pullGesture) {
                            if (currentEditing || currentHome || currentPage?.chromeCollapsed == true) break
                            change.consume()
                            refreshPull = (totalY / refreshDistance).coerceIn(0f, 1f)
                        }
                        ended = event.changes.none { it.pressed }
                    }
                    if (pullGesture && refreshPull >= 1f && !currentEditing && !currentHome && currentPage?.chromeCollapsed != true) {
                        refreshAngle += 360f
                        BreezeSoundEffects.play(context, R.raw.pull_to_refresh)
                        currentPage?.session?.reload()
                    }
                    refreshPull = 0f
                }
            }
            .padding(horizontal=12.dp,vertical=5.dp),
        ) {
        Row(verticalAlignment=Alignment.CenterVertically) {
            if(home) Icon(if(state.homeMode==HomeInputMode.ASK) BreezeIcons.AutoAwesome else BreezeIcons.Search,null,tint=BreezeTeal)
            else {
                Icon(if(text.startsWith("https://")) BreezeIcons.Lock else BreezeIcons.Info,"Connection",Modifier.size(16.dp))
                AddressPageTools(state, Modifier.size(42.dp))
            }
            androidx.compose.foundation.text.BasicTextField(value=text,onValueChange={text=it},modifier=Modifier.weight(1f).padding(horizontal=10.dp).onFocusChanged { editing = it.isFocused },singleLine=true,
                textStyle=MaterialTheme.typography.bodyMedium.copy(color=MaterialTheme.colorScheme.onSurface.copy(alpha=if (editing || home) 1f else 0f)),cursorBrush=androidx.compose.ui.graphics.SolidColor(BreezeTeal),keyboardOptions=KeyboardOptions(imeAction=ImeAction.Go),keyboardActions=KeyboardActions(onGo={keyboardController?.hide();state.submit(text)}),
                decorationBox={inner ->
                    Box(contentAlignment=Alignment.CenterStart) {
                        inner()
                        if (home && text.isEmpty()) Text("Ask Breeze, or type a URL",color=MaterialTheme.colorScheme.onSurfaceVariant,fontSize=15.sp)
                        androidx.compose.animation.AnimatedVisibility(
                            visible = !home && !editing && compactAddress.isNotBlank(),
                            enter = fadeIn(tween(150)), exit = fadeOut(tween(120)),
                        ) {
                            Text(compactAddress, maxLines=1, overflow=TextOverflow.Ellipsis, style=MaterialTheme.typography.bodyMedium, color=MaterialTheme.colorScheme.onSurface)
                        }
                    }
                })
            if(home) IconButton(onClick={keyboardController?.hide();state.submit(text)},modifier=Modifier.size(32.dp)) {Icon(BreezeIcons.ArrowForward,"Ask Breeze or open URL")}
            else IconButton(onClick={refreshAngle += 360f; state.selected?.session?.reload()},modifier=Modifier.size(32.dp)) {Icon(BreezeIcons.Refresh,"Reload",Modifier.rotate(refreshRotation + 180f * refreshPull))}
        }
    }
}
}
@Composable private fun WebScreen(
    state: BrowserState,
    collapseProgress: Float,
    tabUiEntrance: Float,
    modifier: Modifier = Modifier,
    preserveSurfaceViewport: Boolean = false,
    pageMorph: BrowserPageMorph? = null,
    onPageViewportBoundsChanged: (Rect) -> Unit = {},
) {
    val tab = state.selected ?: return
    val addressEntrance = remember { Animatable(0f) }
    LaunchedEffect(addressEntrance) { addressEntrance.animateTo(1f, tween(360, easing = FastOutSlowInEasing)) }
    val density = androidx.compose.ui.platform.LocalDensity.current
    val darkChrome = MaterialTheme.colorScheme.background.red < .3f
    val keyboardVisible = WindowInsets.ime.getBottom(density) > 0
    val navInset = with(density) { WindowInsets.navigationBars.getBottom(this).toDp() }
    val expandedShelfBody = BottomBarHeight + BottomBarVerticalPadding * 2
    val collapsedShelfBody = CollapsedBottomBarHeight + CompactBottomBarVerticalPadding * 2
    val shelfBody = expandedShelfBody * (1f - collapseProgress) + collapsedShelfBody * collapseProgress
    val viewportBottom = if (keyboardVisible || state.isPictureInPicture || state.screen == "tabs" && !preserveSurfaceViewport) 0.dp
        else (navInset + shelfBody - 5.dp).coerceAtLeast(0.dp)
    val viewportBottomPx = (viewportBottom.value * density.density).toInt().coerceAtLeast(0)
    val chromeHeight = if (state.isPictureInPicture) 0.dp else 24.dp + 34.dp * (1f - collapseProgress)
    val chromeAlpha = 1f - collapseProgress
    var screenBounds by remember { mutableStateOf<Rect?>(null) }
    var viewportBounds by remember(tab.id) { mutableStateOf<Rect?>(null) }
    val morphProgress = pageMorph?.progress?.coerceIn(0f, 1f) ?: 0f
    val morphSource = pageMorph?.source ?: viewportBounds
    val morphTarget = pageMorph?.target ?: morphSource
    val pageFrame = if (pageMorph != null && morphSource != null && morphTarget != null) {
        Rect(
            left = morphSource.left + (morphTarget.left - morphSource.left) * morphProgress,
            top = morphSource.top + (morphTarget.top - morphSource.top) * morphProgress,
            right = morphSource.right + (morphTarget.right - morphSource.right) * morphProgress,
            bottom = morphSource.bottom + (morphTarget.bottom - morphSource.bottom) * morphProgress,
        )
    } else morphSource
    val rootBounds = screenBounds
    val movingPageFrameModifier = if (pageFrame != null && rootBounds != null) {
        Modifier.offset {
            IntOffset((pageFrame.left - rootBounds.left).toInt(), (pageFrame.top - rootBounds.top).toInt())
        }.size((pageFrame.width / density.density).dp, (pageFrame.height / density.density).dp)
            .clip(RoundedCornerShape(11.dp * morphProgress))
    } else {
        Modifier.fillMaxSize().graphicsLayer { alpha = if (viewportBounds == null) 0f else 1f }
    }
    val stablePageBounds = if (pageMorph != null) morphSource else viewportBounds
    val stablePageFrameModifier = if (stablePageBounds != null && rootBounds != null) {
        Modifier.offset {
            IntOffset((stablePageBounds.left - rootBounds.left).toInt(), (stablePageBounds.top - rootBounds.top).toInt())
        }.size((stablePageBounds.width / density.density).dp, (stablePageBounds.height / density.density).dp)
            .clipToBounds()
    } else {
        Modifier.fillMaxSize().graphicsLayer { alpha = 0f }
    }
    val pageSnapshot = tab.thumbnail?.takeUnless { it.isRecycled }
    // Compose shared-element transitions do not support AndroidView. Animate the cached page
    // image instead of transforming GeckoView's TextureView surface on every frame.
    val snapshotMorph = pageMorph != null && (pageSnapshot != null || tab.private)
    val liveSurfaceMorph = pageMorph != null && !snapshotMorph
    val pageSurfaceModifier = if (liveSurfaceMorph) movingPageFrameModifier else stablePageFrameModifier
    Box(
        modifier.fillMaxSize()
            .onGloballyPositioned { screenBounds = it.boundsInRoot() }
            .background(if (pageMorph != null) Color.Transparent else if (darkChrome) Color.Black else Color.White),
    ) {
      Column(Modifier.fillMaxSize().graphicsLayer {
          if (pageMorph != null) alpha = 1f - morphProgress
      }) {
        if (!state.isPictureInPicture) {
        Box(Modifier.fillMaxWidth().height(chromeHeight).clipToBounds().graphicsLayer {
            if (pageMorph != null) translationY = -morphProgress * chromeHeight.toPx()
        }) {
            Box(Modifier.fillMaxSize().background(Brush.verticalGradient(
                if (darkChrome) listOf(Color(0xFF080A0B), Color(0xFF050607), Color.Black)
                else listOf(Color.White, Color(0xFFF9FAFB), Color.White),
            )))
            Box(Modifier.fillMaxWidth().height(8.dp).align(Alignment.TopCenter)
                .background(Brush.horizontalGradient(
                    if (darkChrome) listOf(Color.Transparent, Color.White.copy(alpha = .045f), Color.Transparent)
                    else listOf(Color.Transparent, Color.Black.copy(alpha = .035f), Color.Transparent),
                )).blur(6.dp))
            if (collapseProgress < .999f) {
                Row(Modifier.fillMaxSize().graphicsLayer {
                    val entrance = minOf(addressEntrance.value, tabUiEntrance.coerceIn(0f, 1f))
                    alpha = chromeAlpha * entrance
                    scaleX = .99f + .01f * chromeAlpha
                    scaleY = .94f + .06f * chromeAlpha
                    translationY = (1f - chromeAlpha) * (-5.dp.toPx()) - (1f - entrance) * 24.dp.toPx()
                    transformOrigin = androidx.compose.ui.graphics.TransformOrigin(.5f, 1f)
                }.padding(horizontal=10.dp, vertical=4.dp), verticalAlignment=Alignment.CenterVertically) {
                    Box(Modifier.weight(1f)) { AddressField(state, home=false) }
                }
            }
            androidx.compose.foundation.Canvas(Modifier.fillMaxWidth().height(3.dp).align(Alignment.BottomCenter)) {
                drawLine(
                    if (darkChrome) Color.White.copy(alpha = .10f) else Color.Black.copy(alpha = .08f),
                    androidx.compose.ui.geometry.Offset(0f, size.height - .7.dp.toPx()),
                    androidx.compose.ui.geometry.Offset(size.width, size.height - .7.dp.toPx()),
                    1.dp.toPx(),
                )
            }
        }
        if (state.showFind) {
            var query by remember { mutableStateOf("") }
            Row(Modifier.padding(horizontal=12.dp).graphicsLayer {
                if (pageMorph != null) {
                    alpha = 1f - morphProgress
                    translationY = -morphProgress * 34.dp.toPx()
                }
            },verticalAlignment=Alignment.CenterVertically) {
                OutlinedTextField(value=query,onValueChange={query=it;tab.session?.finder?.find(it,org.mozilla.geckoview.GeckoSession.FINDER_FIND_FORWARD)},label={Text("Find on page")},modifier=Modifier.weight(1f),singleLine=true)
                IconButton(onClick={tab.session?.finder?.find(null,org.mozilla.geckoview.GeckoSession.FINDER_FIND_FORWARD)}) {Icon(BreezeIcons.ArrowDownward,"Next match")}
                IconButton(onClick={state.showFind=false;tab.session?.finder?.clear()}) {Icon(BreezeIcons.Close,"Close find")}
            }
        }
        }
        Box(Modifier.weight(1f).fillMaxWidth().clipToBounds().onGloballyPositioned { coordinates ->
            val bounds = coordinates.boundsInRoot()
            viewportBounds = bounds
            onPageViewportBoundsChanged(bounds)
        })
      }
        val attachedTab = remember { mutableStateOf<LiveTab?>(null) }
        val activity = LocalContext.current as? android.app.Activity
        fun installTab(view: GeckoView, targetTab: LiveTab) {
            val previousTab = attachedTab.value
            val freshSession = targetTab.session == null
            val session = state.session(targetTab)
            if (view.session !== session) {
                previousTab?.session?.setFocused(false)
                view.releaseSession()
                view.setSession(session)
            }
            if (previousTab !== targetTab || freshSession) {
                previousTab?.let {
                    it.capture = null
                    it.captureOverlay = null
                    it.coverUntilFirstPaint = null
                }
                attachedTab.value = targetTab
                session.selectionActionDelegate = com.froydinger.breeze.browser.NavTextSelectionActionDelegate(
                    activity ?: return,
                    onShareText = { selectedText ->
                        val share = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, selectedText)
                        activity.startActivity(Intent.createChooser(share, "Share selected text"))
                    },
                    onAskNav = { selectedText ->
                        val prompt = "Explain this selected text from ${targetTab.title}:\n\n$selectedText"
                        if (state.screen == "chat" && state.activeChat != null) {
                            state.contextTabId = targetTab.id
                            state.includePageContext = true
                            state.sendChat(prompt)
                        } else state.startChat(prompt)
                    },
                )
                session.setFocused(true)
                session.setActive(true)
                if (freshSession && targetTab.url.isNotBlank() && !targetTab.restoredSessionState) {
                    state.loadTab(targetTab, targetTab.url)
                }
            }
            targetTab.coverUntilFirstPaint = {
                view.coverUntilFirstPaint(if (darkChrome) android.graphics.Color.BLACK else android.graphics.Color.WHITE)
            }
            targetTab.capture = { onCaptured ->
                if (!targetTab.private && view.isAttachedToWindow) {
                    val completed = java.util.concurrent.atomic.AtomicBoolean(false)
                    val finish = { if (completed.compareAndSet(false, true)) onCaptured() }
                    view.postDelayed({ finish() }, 220)
                    view.capturePixels().accept({ bitmap ->
                        if (bitmap != null) {
                            val thumbnail = android.graphics.Bitmap.createScaledBitmap(bitmap, 360, (bitmap.height * 360f / bitmap.width).toInt().coerceAtLeast(1), true)
                            state.saveThumbnail(targetTab, thumbnail)
                            state.tabs.filter { it.id != targetTab.id && it.thumbnail != null }.dropLast(5).forEach { it.thumbnail = null }
                            if (thumbnail !== bitmap) bitmap.recycle()
                        }
                        finish()
                    }, { _ -> finish() })
                } else onCaptured()
            }
            targetTab.captureOverlay = {
                if (!targetTab.private && view.isAttachedToWindow) view.capturePixels().accept({ bitmap ->
                    if (bitmap != null) {
                        if (state.overlayBackdropRequested && state.selectedId == targetTab.id) state.updateOverlayBackdrop(bitmap)
                        else if (!bitmap.isRecycled) bitmap.recycle()
                    }
                }, { _ -> })
            }
        }
        Layout(
          content = {
              Box(Modifier.fillMaxSize()) {
            AndroidView(
                factory = { context -> GeckoView(context).apply {
                    setViewBackend(GeckoView.BACKEND_TEXTURE_VIEW)
                    setBackgroundColor(if (darkChrome) android.graphics.Color.BLACK else android.graphics.Color.WHITE)
                    installTab(this, tab)
                } },
                modifier = Modifier.fillMaxSize(),
                update = { view ->
                    view.setBackgroundColor(if (darkChrome) android.graphics.Color.BLACK else android.graphics.Color.WHITE)
                    view.setVerticalClipping(viewportBottomPx)
                    installTab(view, tab)
                },
                onRelease = { view ->
                    attachedTab.value?.let { current ->
                        current.capture = null
                        current.captureOverlay = null
                        current.coverUntilFirstPaint = null
                        current.session?.setFocused(false)
                        current.session?.setActive(false)
                    }
                    attachedTab.value = null
                    view.releaseSession()
                },
            )
            val overlaySnapshot = state.overlayBackdrop
            val showBackdropSnapshot = state.overlayBackdropRequested && overlaySnapshot != null
            val overlaySnapshotAlpha by animateFloatAsState(
                targetValue = if (showBackdropSnapshot) 1f else 0f,
                animationSpec = tween(180, easing = androidx.compose.animation.core.FastOutSlowInEasing),
                label = "Page backdrop snapshot",
            )
            if (overlaySnapshot != null && overlaySnapshotAlpha > 0f) {
                Image(
                    bitmap = overlaySnapshot.asImageBitmap(),
                    contentDescription = null,
                    contentScale = androidx.compose.ui.layout.ContentScale.FillBounds,
                    modifier = Modifier.fillMaxSize().blur(14.dp).graphicsLayer { alpha = overlaySnapshotAlpha },
                )
            }
            if (tab.loading) LinearProgressIndicator(Modifier.fillMaxWidth().align(Alignment.TopCenter), color=BreezeTeal)
            tab.error?.let { Text(it, style=MaterialTheme.typography.bodySmall, modifier=Modifier.align(Alignment.TopCenter).padding(12.dp).breezeGlass(14.dp).padding(10.dp)) }              }
          },
          modifier = pageSurfaceModifier.graphicsLayer { if (snapshotMorph) alpha = 0f },
      ) { measurables, constraints ->
          val sourceWidthPx = (morphSource?.width?.toInt() ?: constraints.maxWidth).coerceAtLeast(1)
          val sourceHeightPx = (morphSource?.height?.toInt() ?: constraints.maxHeight).coerceAtLeast(1)
          val page = measurables.single().measure(Constraints.fixed(sourceWidthPx, sourceHeightPx))
          layout(constraints.maxWidth, constraints.maxHeight) {
              if (liveSurfaceMorph) {
                  val scale = maxOf(constraints.maxWidth.toFloat() / sourceWidthPx, constraints.maxHeight.toFloat() / sourceHeightPx)
                  val childWidth = sourceWidthPx * scale
                  val childHeight = sourceHeightPx * scale
                  page.placeWithLayer(((constraints.maxWidth - childWidth) / 2f).toInt(), ((constraints.maxHeight - childHeight) / 2f).toInt()) {
                      scaleX = scale
                      scaleY = scale
                      transformOrigin = androidx.compose.ui.graphics.TransformOrigin(0f, 0f)
                  }
              } else {
                  page.place(0, 0)
              }
          }
      }

      if (snapshotMorph) {
          Box(movingPageFrameModifier.zIndex(3f)) {
              if (tab.private) {
                  Box(Modifier.fillMaxSize().background(if (darkChrome) Color(0xFF11161A) else Color(0xFFE9EFF0)), contentAlignment = Alignment.Center) {
                      Icon(BreezeIcons.VisibilityOff, contentDescription = null,
                          tint = if (darkChrome) Color(0xFF9A9EA6) else Color(0xFF777C85), modifier = Modifier.size(34.dp))
                  }
              } else {
                  Image(
                      bitmap = pageSnapshot!!.asImageBitmap(),
                      contentDescription = null,
                      modifier = Modifier.fillMaxSize(),
                      contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                  )
              }
          }
      }

      if (collapseProgress > .001f) {
          val host = remember(tab.url) { android.net.Uri.parse(tab.url).host.orEmpty().removePrefix("www.") }
          Row(
              Modifier.align(Alignment.TopCenter).offset(y = 8.dp).zIndex(2f)
                  .graphicsLayer { alpha = collapseProgress }
                  .breezeGlass(50.dp)
                  .border(1.dp, MaterialTheme.colorScheme.outline.copy(alpha = .72f), RoundedCornerShape(50.dp))
                  .clickable(enabled = collapseProgress > .82f) { tab.chromeCollapsed = false }
                  .padding(horizontal = 14.dp, vertical = 6.dp),
              verticalAlignment = Alignment.CenterVertically,
          ) {
              Icon(if (tab.url.startsWith("https://")) BreezeIcons.Lock else BreezeIcons.Info, contentDescription = null, tint = BreezeTeal, modifier = Modifier.size(16.dp))
              Spacer(Modifier.width(8.dp))
              Text(host.ifBlank { "New tab" }, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurface)
          }
      }
    }
}
