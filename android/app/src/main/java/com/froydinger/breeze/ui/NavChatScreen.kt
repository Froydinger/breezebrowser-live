package com.froydinger.breeze.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.content.ClipData
import android.content.ClipboardManager
import android.os.Build
import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import android.animation.ValueAnimator
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.Image
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.*
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import com.froydinger.breeze.BrowserState
import com.froydinger.breeze.core.NavTask
import com.froydinger.breeze.notifications.ParsedReminderRequest
import com.froydinger.breeze.notifications.ReminderRepeat
import com.froydinger.breeze.notifications.ReminderScheduler
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

private val UserBubbleDark = Color.Black
private val UserBubbleLight = Color(0xFFE9F2F2)

private data class ChatTool(
    val label: String,
    val slug: String,
    val needsPrompt: Boolean,
    val icon: androidx.compose.ui.graphics.vector.ImageVector,
    val localReminder: Boolean = false,
)
private val chatTools = listOf(
    ChatTool("Nav chat", "", false, BreezeIcons.AutoAwesome),
    ChatTool("Research", NavTask.RESEARCH.slug, true, BreezeIcons.Search),
    ChatTool("Summarize", NavTask.SUMMARIZE.slug, false, BreezeIcons.FileText),
    ChatTool("Fact check", NavTask.FACTCHECK.slug, true, BreezeIcons.SearchCheck),
    ChatTool("YouTube", NavTask.YOUTUBE.slug, false, BreezeIcons.Youtube),
    ChatTool("Reminder", "remind", true, BreezeIcons.Notifications, localReminder = true),
)

@Composable
fun NavChatScreen(state: BrowserState, modifier: Modifier = Modifier) {
    val chat = state.activeChat
    val context = LocalContext.current
    var draft by remember(chat?.id) { mutableStateOf(chat?.draft.orEmpty()) }
    SideEffect { chat?.draft = draft }
    var toolMenu by remember { mutableStateOf(false) }
    var selectedTool by remember(chat?.id) { mutableStateOf(chatTools.first()) }
    var contextMenu by remember { mutableStateOf(false) }
    var showAllSources by remember(chat?.id) { mutableStateOf(false) }
    val listState = rememberLazyListState()
    val composerFocusRequester = remember(chat?.id) { FocusRequester() }
    val keyboardController = LocalSoftwareKeyboardController.current
    var messageBounds by remember { mutableStateOf(Rect.Zero) }
    var panelBounds by remember { mutableStateOf(Rect.Zero) }
    val currentMessageBounds by rememberUpdatedState(messageBounds)
    val currentPanelBounds by rememberUpdatedState(panelBounds)
    LaunchedEffect(state.navInputFocusRequested, chat?.id) {
        if (state.navInputFocusRequested && chat != null) {
            delay(100)
            composerFocusRequester.requestFocus()
            keyboardController?.show()
            state.consumeNavInputFocusRequest()
        }
    }
    var showReminderComposer by remember { mutableStateOf(false) }
    var reminderDraft by remember { mutableStateOf("") }
    var reminderDraftDueAt by remember { mutableStateOf<Long?>(null) }
    var reminderComposerCameFromChat by remember { mutableStateOf(false) }
    var reminderPermissionRequest by remember { mutableStateOf<ParsedReminderRequest?>(null) }
    val reminderPermissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { _ ->
        reminderPermissionRequest?.let(state::finishChatReminder)
        reminderPermissionRequest = null
    }
    LaunchedEffect(state.pendingReminderRequest) {
        val request = state.consumePendingReminderRequest() ?: return@LaunchedEffect
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            reminderPermissionRequest = request
            reminderPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        } else state.finishChatReminder(request)
    }
    LaunchedEffect(state.pendingReminderDraft) {
        val title = state.consumePendingReminderDraft() ?: return@LaunchedEffect
        reminderDraftDueAt = state.consumePendingReminderDraftDueAt()
        reminderDraft = title
        reminderComposerCameFromChat = true
        showReminderComposer = true
    }
    var lastChatId by remember { mutableStateOf(chat?.id) }
    val photoAction = rememberPhotoAttachmentAction(onPhoto = state::queueImage)
    val dark = MaterialTheme.colorScheme.background.red < .3f
    val navAccent = if (dark) Color(0xFF55D1D8) else Color(0xFF087C89)
    val panel = if (dark) Color.Black else Color(0xFFF8F8F7)
    val faintBorder = MaterialTheme.colorScheme.onSurface.copy(alpha = if (dark) .13f else .16f)
    val contextTab = state.contextTab
    val requestRunning = chat?.running == true
    val systemAnimationsEnabled = remember { ValueAnimator.areAnimatorsEnabled() }
    val composerGlow = remember { Animatable(0f) }
    LaunchedEffect(requestRunning, systemAnimationsEnabled) {
        if (!systemAnimationsEnabled) {
            composerGlow.snapTo(if (requestRunning) .62f else 0f)
            return@LaunchedEffect
        }
        if (!requestRunning) {
            composerGlow.animateTo(0f, tween(durationMillis = 280, easing = FastOutSlowInEasing))
            return@LaunchedEffect
        }
        composerGlow.animateTo(.62f, tween(durationMillis = 300, easing = FastOutSlowInEasing))
        while (true) {
            composerGlow.animateTo(1f, tween(durationMillis = 1250, easing = FastOutSlowInEasing))
            composerGlow.animateTo(.62f, tween(durationMillis = 1250, easing = FastOutSlowInEasing))
        }
    }

    LaunchedEffect(chat?.id, chat?.messages?.size) {
        val count = chat?.messages?.size ?: 0
        if (count == 0) return@LaunchedEffect

        // Keep the user's reading position when older content is on screen. New turns
        // follow the tail only when the list was already near it (or this chat just opened).
        val changedChat = lastChatId != chat?.id
        lastChatId = chat?.id
        val justOpened = changedChat || listState.layoutInfo.totalItemsCount == 0
        val lastVisible = listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
        val wasNearTail = justOpened || lastVisible >= listState.layoutInfo.totalItemsCount - 2
        if (wasNearTail) listState.animateScrollToItem(count - 1)
    }

    val density = LocalDensity.current
    val keyboardVisible = WindowInsets.ime.getBottom(density) > 0
    // MainActivity overlays a 58dp bottom bar with 8dp vertical padding. Keep a
    // 10dp gap above it while closed; the IME inset owns the lower edge when open.
    val composerBottomGap = if (keyboardVisible) 10.dp else with(density) {
        WindowInsets.navigationBars.getBottom(this).toDp() + 84.dp
    }
    val trayMode = !state.chatExpanded && !keyboardVisible
    val panelReveal = remember { Animatable(0f) }
    val panelTarget = if (state.screen != "chat") 0f else 1f
    LaunchedEffect(state.screen, state.chatExpanded, keyboardVisible) {
        panelReveal.animateTo(panelTarget, tween(300, easing = FastOutSlowInEasing))
    }
    val trayCornerFraction by androidx.compose.animation.core.animateFloatAsState(
        targetValue = if (trayMode) 1f else 0f,
        animationSpec = tween(300, easing = FastOutSlowInEasing),
        label = "Nav tray corners",
    )
    val trayOpacity = .92f + .08f * (1f - trayCornerFraction)
    val trayShape = RoundedCornerShape(topStart = (28f * trayCornerFraction).dp, topEnd = (28f * trayCornerFraction).dp)
    val screenModifier = modifier.fillMaxSize().clip(trayShape)
        .background(panel.copy(alpha = panelReveal.value * trayOpacity))
        .then(if (trayMode) Modifier.border(1.dp, faintBorder.copy(alpha = panelReveal.value), trayShape) else Modifier)

    Column(
        screenModifier.padding(start = 14.dp, end = 14.dp, top = 7.dp, bottom = composerBottomGap)
            .onGloballyPositioned { panelBounds = it.boundsInRoot() }
            .pointerInput(trayMode) {
                val closeThreshold = 48.dp.toPx()
                val touchSlop = viewConfiguration.touchSlop
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                    val bounds = currentPanelBounds
                    val downInRoot = Offset(bounds.left + down.position.x, bounds.top + down.position.y)
                    if (currentMessageBounds.contains(downInRoot)) {
                        // Leave all gestures that begin in the message list to LazyColumn.
                        return@awaitEachGesture
                    }

                    var totalY = 0f
                    var totalX = 0f
                    var claimed = false
                    var ended = false
                    while (!ended) {
                        val event = awaitPointerEvent(PointerEventPass.Initial)
                        val change = event.changes.firstOrNull() ?: break
                        val delta = change.position - change.previousPosition
                        totalY += delta.y
                        totalX += delta.x

                        if (!claimed && kotlin.math.abs(totalY) > touchSlop &&
                            kotlin.math.abs(totalY) > kotlin.math.abs(totalX) * 1.2f
                        ) {
                            claimed = true
                        }
                        if (claimed) change.consume()
                        ended = event.changes.none { it.pressed }
                    }

                    if (claimed && totalY > closeThreshold) {
                        state.collapseChatOrReturn()
                    } else if (claimed && trayMode && totalY < -closeThreshold) {
                        state.expandChat()
                    }
                }
            },
        verticalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        if (trayMode) {
            Box(
                Modifier.fillMaxWidth().height(22.dp).clickable { state.expandChat() },
                contentAlignment = Alignment.Center,
            ) {
                Box(Modifier.width(42.dp).height(4.dp).clip(CircleShape).background(MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = .45f)))
            }
        }
        // Nav header: fixed to the mockup's mark, wordmark, history, and compose actions.
        Row(Modifier.fillMaxWidth().height(54.dp), verticalAlignment = Alignment.CenterVertically) {
            NavMark(34.dp, glowing=chat?.running==true)
            Spacer(Modifier.width(12.dp))
            Text("Nav", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.weight(1f))
            IconButton(onClick = { state.screen = "history" }, modifier = Modifier.size(44.dp)) {
                Icon(BreezeIcons.Clock, contentDescription = "Chat history", tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            IconButton(onClick = { state.startChat() }, modifier = Modifier.size(44.dp)) {
                Icon(BreezeIcons.Edit, contentDescription = "New chat", tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }

        val shouldSuggestCreatorBreakdown = contextTab != null && state.isYouTubeVideo(contextTab.url) &&
            chat?.messages?.none { it.first == "user" && it.second.trimStart().startsWith("/youtube", ignoreCase = true) } != false
        if (shouldSuggestCreatorBreakdown) {
            Surface(
                onClick = {
                    selectedTool = chatTools.first { it.slug == NavTask.YOUTUBE.slug }
                    if (chat == null) state.startChat("/youtube ${contextTab?.url.orEmpty()}" )
                    else state.sendChat("/youtube ${contextTab?.url.orEmpty()}")
                },
                modifier = Modifier.fillMaxWidth(),
                color = navAccent.copy(alpha = if (dark) .12f else .09f),
                shape = RoundedCornerShape(18.dp),
                border = BorderStroke(1.dp, navAccent.copy(alpha = .34f)),
            ) {
                Row(Modifier.padding(horizontal = 15.dp, vertical = 11.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(BreezeIcons.Youtube, contentDescription = null, modifier = Modifier.size(20.dp), tint = navAccent)
                    Spacer(Modifier.width(11.dp))
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text("YouTube creator breakdown", style = MaterialTheme.typography.labelLarge)
                        Text("Read available captions and see why it works", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    Icon(BreezeIcons.ChevronRight, contentDescription = "Run creator breakdown", modifier = Modifier.size(20.dp), tint = navAccent)
                }
            }
        }

        LazyColumn(
            modifier = Modifier.weight(1f).fillMaxWidth().onGloballyPositioned { messageBounds = it.boundsInRoot() },
            state = listState,
            contentPadding = PaddingValues(top = 18.dp, bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            if (chat == null || chat.messages.isEmpty()) {
                item {
                    AnimatedVisibility(visible = true, enter = fadeIn(tween(durationMillis = 220))) {
                        Row(Modifier.fillMaxWidth().padding(top = 12.dp), verticalAlignment = Alignment.Top) {
                            NavMark(27.dp)
                            Spacer(Modifier.width(14.dp))
                            Text("What can I help you with?", style = MaterialTheme.typography.bodyLarge, modifier = Modifier.padding(top = 2.dp))
                        }
                    }
                }
            } else {
                itemsIndexed(chat.messages, key = { index, _ -> "${chat.id}-$index" }) { index, (role, text) ->
                    AnimatedVisibility(visible = true, enter = fadeIn(tween(durationMillis = 180))) {
                    if (role == "user") {
                        val visiblePrompt = visibleChatPrompt(text)
                        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            visiblePrompt.tool?.let { tool ->
                                Surface(
                                    color = navAccent.copy(alpha = if (dark) .14f else .12f),
                                    shape = RoundedCornerShape(50),
                                    border = BorderStroke(1.dp, navAccent.copy(alpha = .42f)),
                                ) {
                                    Row(Modifier.padding(horizontal = 10.dp, vertical = 5.dp), verticalAlignment = Alignment.CenterVertically) {
                                        Icon(tool.icon, null, Modifier.size(14.dp), tint = navAccent)
                                        Spacer(Modifier.width(6.dp))
                                        Text(tool.label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurface)
                                    }
                                }
                            }
                            if (visiblePrompt.prompt.isNotBlank()) Text(
                                visiblePrompt.prompt,
                                modifier = Modifier.widthIn(max = 560.dp)
                                    .clip(RoundedCornerShape(28.dp))
                                    .background(if (dark) UserBubbleDark else UserBubbleLight)
                                    .border(1.dp, navAccent.copy(alpha = if (dark) .24f else .17f), RoundedCornerShape(28.dp))
                                    .padding(horizontal = 18.dp, vertical = 13.dp),
                                color = MaterialTheme.colorScheme.onSurface,
                                style = MaterialTheme.typography.bodyLarge,
                            )
                            if (visiblePrompt.prompt.isNotBlank()) CopyMessageButton(visiblePrompt.prompt, state)
                            chat.imagePreviews[index]?.let { uri -> ChatImagePreview(uri, Modifier.widthIn(max = 230.dp).heightIn(max = 170.dp)) }
                        }
                    } else if (text.isNotBlank()) {
                        val command = chat.messages.getOrNull(index - 1)?.second?.substringBefore(' ')?.lowercase()
                        val taskReply = command in listOf("/research", "/youtube", "/factcheck", "/summarize")
                        if (taskReply) {
                            Column(Modifier.fillMaxWidth(), verticalArrangement=Arrangement.spacedBy(10.dp)) {
                                if (index in chat.finishedReplies) Text(when(command) { "/research" -> "Research complete"; "/youtube" -> "Creator analysis complete"; "/factcheck" -> "Fact-check complete"; else -> "Summary complete" },style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
                                Text(when(command) { "/research" -> if(index in chat.finishedReplies) "Research, wrapped." else "Research"; "/youtube" -> "Creator breakdown"; "/factcheck" -> "The fact-check"; else -> "In short" },style=MaterialTheme.typography.headlineSmall)
                                NavMessageText(text, state, numberedCards=command=="/research")
                                CopyMessageButton(text, state)
                            }
                        } else Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
                            NavMark(26.dp)
                            Spacer(Modifier.width(14.dp))
                            Column(Modifier.weight(1f)) {
                                NavMessageText(text, state, modifier = Modifier.padding(top = 2.dp))
                                CopyMessageButton(text, state)
                            }
                        }
                    }
                    }
                }

                if (chat.running && chat.status.isNotBlank()) {
                    item {
                        Surface(
                            modifier = Modifier.fillMaxWidth(),
                            color = panel,
                            shape = RoundedCornerShape(22.dp),
                            border = BorderStroke(1.dp, faintBorder),
                        ) {
                            Column(Modifier.padding(horizontal = 17.dp, vertical = 15.dp), verticalArrangement = Arrangement.spacedBy(13.dp)) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    NavMark(23.dp, glowing=true)
                                    Spacer(Modifier.width(12.dp))
                                    Text("Nav path", style = MaterialTheme.typography.titleSmall)
                                }
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Box(Modifier.padding(start = 3.dp).size(17.dp).border(2.dp, navAccent, CircleShape), contentAlignment = Alignment.Center) {
                                        Box(Modifier.size(7.dp).background(navAccent, CircleShape))
                                    }
                                    Spacer(Modifier.width(17.dp))
                                    Text(chat.status, modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    TextButton(onClick = { state.cancelChat() }) {
                                        Icon(BreezeIcons.Stop, contentDescription = null, modifier = Modifier.size(17.dp))
                                        Spacer(Modifier.width(4.dp))
                                        Text("Stop")
                                    }
                                }
                            }
                        }
                    }
                } else if (chat.status.isNotBlank()) {
                    item {
                        Row(Modifier.fillMaxWidth().padding(start = 40.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(chat.status, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }

                if (chat.sources.isNotEmpty()) {
                    item {
                        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(9.dp)) {
                            Text("Sources", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            chat.sources.take(if (showAllSources) chat.sources.size else 3).forEach { (title, url) ->
                                val host = remember(url) { runCatching { android.net.Uri.parse(url).host.orEmpty() }.getOrDefault("") }
                                Surface(
                                    onClick = { state.openSourceFromChat(url) },
                                    modifier = Modifier.fillMaxWidth(),
                                    color = panel,
                                    shape = RoundedCornerShape(17.dp),
                                    border = BorderStroke(1.dp, faintBorder),
                                ) {
                                    Row(Modifier.padding(start = 14.dp, end = 14.dp, top = 12.dp, bottom = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                                        Icon(BreezeIcons.Language, null, Modifier.size(19.dp), tint=MaterialTheme.colorScheme.onSurfaceVariant)
                                        Spacer(Modifier.width(10.dp))
                                        Column(Modifier.weight(1f)) {
                                            Text(title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                            Text(host, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                                        }
                                        Spacer(Modifier.width(14.dp))
                                        Text("Open in tab", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                        Spacer(Modifier.width(8.dp))
                                        Icon(BreezeIcons.OpenInNew, contentDescription = "Open source", tint = navAccent, modifier = Modifier.size(19.dp))
                                    }
                                }
                            }
                            if (chat.sources.size > 3) {
                                TextButton(onClick = { showAllSources = !showAllSources }, contentPadding = PaddingValues(horizontal = 6.dp, vertical = 3.dp)) {
                                    Text(if (showAllSources) "Show fewer sources" else "Show all ${chat.sources.size} sources")
                                }
                            }
                        }
                    }
                }
            }
        }

        // Put the task picker first so the selected Nav mode is easy to reach above the composer.
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(9.dp)) {
            val isTaskTool = selectedTool.slug.isNotEmpty()
            val toolChipColor by animateColorAsState(
                targetValue = if (isTaskTool) navAccent.copy(alpha = if (dark) .12f else .1f) else panel,
                animationSpec = tween(180),
                label = "selected tool background",
            )
            val toolChipBorder by animateColorAsState(
                targetValue = if (isTaskTool) navAccent.copy(alpha = .45f) else faintBorder,
                animationSpec = tween(180),
                label = "selected tool border",
            )
            Box {
                Surface(
                    onClick = { toolMenu = true },
                    color = toolChipColor,
                    shape = RoundedCornerShape(16.dp),
                    border = BorderStroke(1.dp, toolChipBorder),
                ) {
                    Row(Modifier.height(44.dp).padding(horizontal = 13.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(selectedTool.icon, contentDescription = null, modifier = Modifier.size(16.dp), tint = if (isTaskTool) navAccent else MaterialTheme.colorScheme.onSurfaceVariant)
                        Spacer(Modifier.width(7.dp))
                        Text(selectedTool.label, style = MaterialTheme.typography.bodySmall, maxLines = 1)
                        Spacer(Modifier.width(7.dp))
                        Icon(BreezeIcons.ExpandMore, contentDescription = "Choose Nav tool", modifier = Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                DropdownMenu(expanded = toolMenu, onDismissRequest = { toolMenu = false }) {
                    chatTools.forEach { tool ->
                        DropdownMenuItem(
                            text = { Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(tool.icon, null, Modifier.size(18.dp), tint = if (tool == selectedTool) navAccent else MaterialTheme.colorScheme.onSurfaceVariant)
                                Spacer(Modifier.width(12.dp))
                                Text(tool.label, modifier = Modifier.weight(1f))
                                if (tool == selectedTool) Icon(BreezeIcons.Check, null, Modifier.size(17.dp), tint = navAccent)
                            } },
                            onClick = { selectedTool = tool; toolMenu = false },
                        )
                    }
                }
            }
            if (state.includePageContext && contextTab != null) {
                Surface(
                    modifier = Modifier.weight(1f).heightIn(min = 44.dp).clickable { state.selectedId = contextTab.id; state.screen = "browser" },
                    color = panel,
                    shape = RoundedCornerShape(16.dp),
                    border = BorderStroke(1.dp, faintBorder),
                ) {
                    Row(Modifier.padding(start = 12.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(BreezeIcons.OpenInNew, contentDescription = null, modifier = Modifier.size(17.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        Spacer(Modifier.width(10.dp))
                        Text("Current tab: ${contextTab.title}", modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium)
                        IconButton(onClick = { state.includePageContext = false }, modifier = Modifier.size(36.dp)) {
                            Icon(BreezeIcons.Close, contentDescription = "Remove page context", modifier = Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
            Box {
                IconButton(
                    onClick = { contextMenu = true },
                    modifier = Modifier.size(44.dp).clip(RoundedCornerShape(15.dp)).background(panel).border(1.dp, faintBorder, RoundedCornerShape(15.dp)),
                ) { Icon(BreezeIcons.Language, contentDescription = "Choose page context", tint = MaterialTheme.colorScheme.onSurfaceVariant) }
                DropdownMenu(expanded = contextMenu, onDismissRequest = { contextMenu = false }) {
                    state.tabs.filterNot { it.private }.forEach { tab ->
                        DropdownMenuItem(
                            text = { Text(tab.title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                            onClick = {
                                state.contextTabId = tab.id
                                state.includePageContext = true
                                contextMenu = false
                            },
                        )
                    }
                    if (state.tabs.none { !it.private }) {
                        DropdownMenuItem(text = { Text("No regular tabs open") }, onClick = { contextMenu = false }, enabled = false)
                    }
                }
            }

        }

        state.pendingImageUri?.let { uri -> PendingImageAttachment(uri, onRemove = state::removePendingImage) }

        // Single outlined capsule. The send button is flush to the capsule edge like the approved mockup.
        Box(Modifier.fillMaxWidth().heightIn(min = 60.dp)) {
            Row(
                Modifier.fillMaxWidth()
                    .heightIn(min = 60.dp)
                    .clip(CircleShape)
                    .background(panel)
                    .border(1.dp, faintBorder, CircleShape)
                    .padding(start = 18.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
            IconButton(onClick = photoAction, modifier = Modifier.size(42.dp)) {
                Icon(BreezeIcons.PhotoCamera, contentDescription = "Attach a photo", modifier = Modifier.offset(x = (-5).dp), tint = MaterialTheme.colorScheme.onSurface)
            }
            Box(Modifier.weight(1f)) {
                BasicTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp).focusRequester(composerFocusRequester),
                    textStyle = MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface),
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                    keyboardActions = KeyboardActions(onSend = { keyboardController?.hide(); submitNavChat(draft, selectedTool, chat?.running == true, state, { draft = "" }) { reminderDraft = it; showReminderComposer = true } }),
                    decorationBox = { inner ->
                        if (draft.isEmpty()) Text(if (selectedTool.localReminder) "What should Breeze remind you?" else "Ask anything…", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        inner()
                    },
                )
            }
            VoiceTranscriptionButton(
                enabled = chat?.running != true,
                cloudConsentAccepted = state.cloudDisclosureAccepted,
                onCloudConsentRequired = state::requestCloudDisclosure,
                onText = { recognized -> draft = if (draft.isBlank()) recognized else "$draft\n$recognized" },
                onError = { state.notice = it },
                onSubmit = { recognized ->
                    keyboardController?.hide()
                    val spoken = recognized.trim()
                    val message = if (draft.trim().endsWith(spoken)) draft.trim() else listOf(draft.trim(), spoken).filter(String::isNotBlank).joinToString("\n")
                    submitNavChat(message, selectedTool, chat?.running == true, state, { draft = "" }) { reminderDraft = it; showReminderComposer = true }
                },
            )
                IconButton(
                    onClick = { keyboardController?.hide(); submitNavChat(draft, selectedTool, requestRunning, state, { draft = "" }) { reminderDraft = it; showReminderComposer = true } },
                    enabled = (!selectedTool.needsPrompt || draft.isNotBlank() || state.pendingImageUri != null) && (draft.isNotBlank() || state.pendingImageUri != null || selectedTool.slug.isNotEmpty()) && !requestRunning,
                    modifier = Modifier.size(60.dp).clip(CircleShape).border(1.5.dp, navAccent, CircleShape),
                ) {
                    Icon(BreezeIcons.Send, contentDescription = "Send", tint = navAccent, modifier = Modifier.size(27.dp))
                }
            }
            if (composerGlow.value > 0f) Canvas(Modifier.matchParentSize()) {
                val inset = 1.5.dp.toPx()
                val bounds = Size((size.width - inset * 2).coerceAtLeast(0f), (size.height - inset * 2).coerceAtLeast(0f))
                val radius = CornerRadius(bounds.height / 2f)
                val pulse = composerGlow.value
                drawRoundRect(
                    color = navAccent.copy(alpha = .075f * pulse),
                    topLeft = Offset(inset, inset), size = bounds, cornerRadius = radius,
                    style = Stroke(width = 8.dp.toPx()),
                )
                drawRoundRect(
                    color = navAccent.copy(alpha = .12f * pulse),
                    topLeft = Offset(inset, inset), size = bounds, cornerRadius = radius,
                    style = Stroke(width = 4.dp.toPx()),
                )
                drawRoundRect(
                    color = navAccent.copy(alpha = .35f * pulse),
                    topLeft = Offset(inset, inset), size = bounds, cornerRadius = radius,
                    style = Stroke(width = 1.25.dp.toPx()),
                )
            }
        }
    }

    if (showReminderComposer) {
        ReminderComposerDialog(
            initialText = reminderDraft,
            onDismiss = { showReminderComposer = false; reminderComposerCameFromChat = false; reminderDraftDueAt = null },
            onSave = { title, dueAt, repeat ->
                val reminder = state.addReminder(title, dueAt, repeat)
                state.activeChat?.let { active ->
                    if (!reminderComposerCameFromChat) active.messages.add("user" to "/remind $title")
                    val repeated = if (repeat == ReminderRepeat.NONE) "" else " Repeats ${repeat.label.lowercase()}."
                    val notificationText = if (ReminderScheduler.notificationsAllowed(context)) "" else " Android notifications are off, so turn them on in Settings to receive it."
                    active.messages.add("assistant" to "I’ll remind you to ${reminder.title} on this phone at ${java.text.DateFormat.getDateTimeInstance(java.text.DateFormat.MEDIUM, java.text.DateFormat.SHORT).format(dueAt)}.$repeated$notificationText")
                    active.finishedReplies.add(active.messages.lastIndex)
                }
                reminderComposerCameFromChat = false
                reminderDraftDueAt = null
                state.persist()
                showReminderComposer = false
            },
            onNotificationsDenied = { state.notice = "Reminder saved, but Android notifications are off. Turn them on in Settings." },
            initialDueAt = reminderDraftDueAt,
        )
    }
}

@Composable
private fun CopyMessageButton(text: String, state: BrowserState) {
    val context = LocalContext.current
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
        IconButton(
            onClick = {
                val clipboard = context.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as? ClipboardManager
                clipboard?.setPrimaryClip(ClipData.newPlainText("Breeze message", text))
                state.notice = "Copied to clipboard"
            },
            modifier = Modifier.size(34.dp),
        ) { Icon(BreezeIcons.ContentCopy, contentDescription = "Copy message", modifier = Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}

private fun submitNavChat(draft: String, tool: ChatTool, running: Boolean, state: BrowserState, clear: () -> Unit, onReminder: (String) -> Unit) {
    if (running || (draft.isBlank() && state.pendingImageUri == null && (tool.slug.isEmpty() || tool.needsPrompt))) return
    if (tool.localReminder) { onReminder(draft.trim()); clear(); return }
    val payload = if (tool.slug.isEmpty()) draft.trim() else "/${tool.slug} ${draft.trim()}".trim()
    if (state.activeChat == null) state.startChat(payload) else state.sendChat(payload)
    clear()
}

@Composable
private fun PendingImageAttachment(uri: String, onRemove: () -> Unit) {
    Surface(color = MaterialTheme.colorScheme.surface, shape = RoundedCornerShape(16.dp), border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline)) {
        Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            ChatImagePreview(uri, Modifier.sizeIn(maxWidth = 86.dp, maxHeight = 62.dp).clip(RoundedCornerShape(10.dp)))
            Text("Photo attached · sent when you tap Send", Modifier.weight(1f).padding(horizontal = 10.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2)
            IconButton(onClick = onRemove, modifier = Modifier.size(42.dp)) { Icon(BreezeIcons.Close, "Remove photo", tint = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
    }
}

@Composable
private fun ChatImagePreview(uriText: String, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val bitmap by produceState<Bitmap?>(initialValue = null, uriText) {
        value = withContext(Dispatchers.IO) {
            runCatching {
                val uri = Uri.parse(uriText)
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
                var sample = 1
                while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 720 && bounds.outWidth > 0 && bounds.outHeight > 0) sample *= 2
                val options = BitmapFactory.Options().apply { inSampleSize = sample }
                context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) }
            }.getOrNull()
        }
    }
    if (bitmap != null) Image(bitmap!!.asImageBitmap(), contentDescription = "Attached photo", modifier = modifier.clip(RoundedCornerShape(13.dp)), contentScale = androidx.compose.ui.layout.ContentScale.Crop)
    else Box(modifier.size(86.dp, 62.dp).clip(RoundedCornerShape(13.dp)).background(MaterialTheme.colorScheme.surfaceVariant))
}

private data class VisibleChatPrompt(val tool: ChatTool?, val prompt: String)

private fun visibleChatPrompt(raw: String): VisibleChatPrompt {
    val trimmed = raw.trim()
    val parts = trimmed.split(Regex("\\s+"), limit = 2)
    val token = parts.firstOrNull().orEmpty()
    if (!token.startsWith('/')) return VisibleChatPrompt(null, raw)
    val slug = token.drop(1).lowercase()
    val tool = chatTools.firstOrNull { it.slug == slug && it.slug.isNotEmpty() } ?: return VisibleChatPrompt(null, raw)
    return VisibleChatPrompt(tool, parts.getOrNull(1).orEmpty().trim())
}
