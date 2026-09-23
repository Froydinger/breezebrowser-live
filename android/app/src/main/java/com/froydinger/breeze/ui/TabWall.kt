package com.froydinger.breeze.ui

import android.net.Uri
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.AnimatedVisibilityScope
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.ExperimentalSharedTransitionApi
import androidx.compose.animation.SharedTransitionScope
import androidx.compose.animation.SharedTransitionScope.OverlayClip
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.froydinger.breeze.BrowserState
import com.froydinger.breeze.LiveTab

/** Full-screen tab switcher matching the approved dark and light tab-wall designs. */
@Composable
fun TabWallScreen(
    state: BrowserState,
    pageTransitionInProgress: Boolean = false,
    onSelectedTabBoundsChanged: (androidx.compose.ui.geometry.Rect?) -> Unit,
) {
    var showingPrivate by remember(state.selectedId) { mutableStateOf(state.selected?.private == true) }
    var menuOpen by remember { mutableStateOf(false) }
    val currentTabs = state.tabs.filter { it.private == showingPrivate }
    val tabIdSignature = currentTabs.joinToString("|") { it.id }
    var closeTargetsReady by remember { mutableStateOf(false) }
    LaunchedEffect(tabIdSignature) {
        closeTargetsReady = false
        kotlinx.coroutines.delay(300)
        closeTargetsReady = true
    }
    // Selecting a tab updates its recency before the wall's exit animation finishes.
    // Keep the visible ordering stable for that animation; the next wall entry re-sorts.
    val tabs = remember(showingPrivate, tabIdSignature) { currentTabs.sortedByDescending { it.lastAccessedAt } }
    val dark = MaterialTheme.colorScheme.background.luminance() < 0.4f
    val ink = if (dark) Color(0xFFF2F3F5) else Color(0xFF191B1F)
    val muted = if (dark) Color(0xFF9A9EA6) else Color(0xFF777C85)
    val stroke = if (dark) Color(0xFF242424) else Color(0xFFD5D8DE)
    val card = if (dark) Color.Black else Color(0xFFFFFFFF)
    val control = if (dark) Color(0xFF050505) else Color(0xFFE9EBEE)
    val teal = Color(0xFF21B9C3)

    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        Row(
            Modifier.fillMaxWidth().height(68.dp).padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = { state.screen = "browser" }) {
                Icon(BreezeIcons.ArrowBack, contentDescription = "Back", tint = ink)
            }
            Spacer(Modifier.width(8.dp))
            Text(
                if (showingPrivate) "Private tabs" else "Tabs",
                color = ink,
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Medium,
            )
            Spacer(Modifier.width(12.dp))
            Surface(shape = RoundedCornerShape(50), color = control) {
                Text("${tabs.size} open", Modifier.padding(horizontal = 12.dp, vertical = 7.dp), color = muted,
                    style = MaterialTheme.typography.labelLarge)
            }
            Spacer(Modifier.weight(1f))
            Box {
                IconButton(onClick = { menuOpen = true }) {
                    Icon(BreezeIcons.MoreVert, contentDescription = "Tab options", tint = ink)
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(
                        text = { Text(if (showingPrivate) "New private tab" else "New tab") },
                        leadingIcon = { Icon(BreezeIcons.Add, contentDescription = null) },
                        onClick = { menuOpen = false; state.newTab(private = showingPrivate) },
                    )
                    DropdownMenuItem(
                        text = { Text(if (showingPrivate) "Regular tabs" else "Private tabs") },
                        leadingIcon = { Icon(BreezeIcons.VisibilityOff, contentDescription = null) },
                        onClick = { menuOpen = false; showingPrivate = !showingPrivate },
                    )
                }
            }
        }

        LazyVerticalGrid(
            columns = GridCells.Fixed(2),
            modifier = Modifier.weight(1f).fillMaxWidth(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 18.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item(key = "new-tab") {
                NewTabTile(dark, ink, muted, stroke) { state.newTab(private = showingPrivate) }
            }
            items(tabs, key = { it.id }) { tab ->
                var previewBounds by remember(tab.id) { mutableStateOf<androidx.compose.ui.geometry.Rect?>(null) }
                Box(Modifier.animateItem(placementSpec = tween(220, easing = FastOutSlowInEasing))) {
                    TabPreviewCard(
                        tab = tab,
                        dark = dark,
                        ink = ink,
                        muted = muted,
                        stroke = stroke,
                        card = card,
                        control = control,
                        wallpaper = state.wallpaper,
                        closeControlEnabled = closeTargetsReady && !pageTransitionInProgress,
                        hideSelectedCloseControl = pageTransitionInProgress && tab.id == state.selectedId,
                        onNeedThumbnail = { state.loadThumbnail(tab) },
                        onPreviewBoundsChanged = { bounds ->
                            previewBounds = bounds
                            if (tab.id == state.selectedId) onSelectedTabBoundsChanged(bounds)
                        },
                        onOpen = { onSelectedTabBoundsChanged(previewBounds); state.select(tab) },
                        onClose = { state.close(tab) },
                    )
                }
            }
            item(key = "private-tabs", span = { GridItemSpan(maxLineSpan) }) {
                PrivateTabsTile(dark, ink, muted, stroke, card, showingPrivate) {
                    showingPrivate = !showingPrivate
                }
            }
        }

        Box(
            Modifier.fillMaxWidth().drawBehind {
                drawLine(stroke, start = androidx.compose.ui.geometry.Offset(0f, 0f),
                    end = androidx.compose.ui.geometry.Offset(size.width, 0f), strokeWidth = 1.dp.toPx())
            }.navigationBarsPadding().padding(horizontal = 16.dp, vertical = 14.dp).height(52.dp),
        ) {
            androidx.compose.animation.AnimatedVisibility(
                visible = !pageTransitionInProgress,
                modifier = Modifier.fillMaxSize(),
                enter = slideInVertically(tween(190, delayMillis = 70)) { it / 2 } + fadeIn(tween(160, delayMillis = 70)),
                exit = slideOutVertically(tween(120)) { it / 3 } + fadeOut(tween(100)),
            ) {
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Surface(
                        modifier = Modifier.weight(1f).fillMaxHeight().clickable { state.closeAllTabs(showingPrivate) },
                        shape = RoundedCornerShape(50), color = Color.Transparent,
                        border = BorderStroke(1.dp, stroke),
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            Text("Close all", color = ink, style = MaterialTheme.typography.labelLarge)
                        }
                    }
                    Surface(
                        modifier = Modifier.weight(1f).fillMaxHeight().clickable { state.screen = "browser" },
                        shape = RoundedCornerShape(50), color = teal,
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            Text("Done", color = Color.White, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun TabPreviewCard(
    tab: LiveTab,
    dark: Boolean,
    ink: Color,
    muted: Color,
    stroke: Color,
    card: Color,
    control: Color,
    wallpaper: String,
    closeControlEnabled: Boolean = true,
    hideSelectedCloseControl: Boolean = false,
    onNeedThumbnail: () -> Unit,
    onPreviewBoundsChanged: (androidx.compose.ui.geometry.Rect?) -> Unit,
    onOpen: () -> Unit,
    onClose: () -> Unit,
) {
    var menuOpen by remember { mutableStateOf(false) }
    LaunchedEffect(tab.id, tab.thumbnail) {
        if (!tab.private && tab.thumbnail == null) onNeedThumbnail()
    }
    val shape = RoundedCornerShape(16.dp)
    Surface(
        modifier = Modifier.fillMaxWidth().aspectRatio(0.84f).clickable(onClick = onOpen),
        shape = shape,
        color = card,
        border = BorderStroke(1.dp, stroke),
    ) {
        Column(Modifier.fillMaxSize().padding(8.dp)) {
            Box(Modifier.fillMaxWidth().weight(1f).clip(RoundedCornerShape(11.dp)).onGloballyPositioned { coordinates ->
                onPreviewBoundsChanged(coordinates.boundsInRoot())
            }) {
                val bitmap = tab.thumbnail
                if (bitmap != null && !bitmap.isRecycled) {
                    Box(Modifier.fillMaxSize().clip(RoundedCornerShape(11.dp))) {
                        Image(bitmap.asImageBitmap(), contentDescription = "Preview of ${tab.title}",
                            modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                    }
                } else if (tab.url.isBlank() || tab.url.equals("about:blank", ignoreCase = true)) {
                    NewTabPreviewArtwork(dark, wallpaper)
                } else if (tab.private) {
                    Box(Modifier.fillMaxSize().background(if (dark) Color(0xFF11161A) else Color(0xFFE9EFF0)),
                        contentAlignment = Alignment.Center) {
                        Icon(BreezeIcons.VisibilityOff, contentDescription = null, tint = muted, modifier = Modifier.size(34.dp))
                    }
                } else {
                    Box(Modifier.fillMaxSize().background(if (dark) Color(0xFF101719) else Color(0xFFE9EFF0)),
                        contentAlignment = Alignment.Center) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(5.dp)) {
                            Icon(BreezeIcons.Language, contentDescription = null, tint = if (dark) Color(0xFF62CBD0) else Color(0xFF087C89), modifier = Modifier.size(34.dp))
                            Text(runCatching { Uri.parse(tab.url).host.orEmpty().removePrefix("www.") }.getOrDefault(""), color = muted,
                                style = MaterialTheme.typography.labelSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                }
                if (!hideSelectedCloseControl) {
                    Surface(
                        modifier = Modifier.align(Alignment.TopEnd).padding(8.dp).size(38.dp),
                        shape = CircleShape, color = if (dark) Color(0xCC000000) else Color(0xCC42464D),
                    ) {
                        IconButton(onClick = onClose, enabled = closeControlEnabled, modifier = Modifier.size(38.dp)) {
                            Icon(BreezeIcons.Close, contentDescription = "Close ${tab.title}", tint = Color.White, modifier = Modifier.size(19.dp))
                        }
                    }
                }
            }
            Row(Modifier.fillMaxWidth().height(70.dp).padding(top = 9.dp), verticalAlignment = Alignment.Top) {
                Icon(BreezeIcons.Language, contentDescription = null, tint = muted, modifier = Modifier.padding(top = 2.dp).size(22.dp))
                Column(Modifier.weight(1f).padding(start = 8.dp)) {
                    Text(tab.title.ifBlank { "New tab" }, color = ink, maxLines = 2, overflow = TextOverflow.Ellipsis,
                        style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
                    val host = remember(tab.url) { runCatching { Uri.parse(tab.url).host.orEmpty() }.getOrDefault("") }
                    Text(host.ifBlank { if (tab.private) "Private tab" else "New tab" }, color = muted, maxLines = 1,
                        overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodySmall)
                }
                Box {
                    IconButton(onClick = { menuOpen = true }, enabled = closeControlEnabled, modifier = Modifier.size(28.dp)) {
                        Icon(BreezeIcons.MoreVert, contentDescription = "Options for ${tab.title}", tint = muted)
                    }
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        DropdownMenuItem(text = { Text("Close tab") }, enabled = closeControlEnabled, onClick = { menuOpen = false; onClose() })
                    }
                }
            }
        }
    }
}

@Composable
private fun NewTabPreviewArtwork(dark: Boolean, wallpaper: String) {
    val context = LocalContext.current
    val artwork = remember(wallpaper, dark) {
        context.resources.getIdentifier(wallpaper + if (dark) "_dark" else "_light", "drawable", context.packageName)
    }
    Box(Modifier.fillMaxSize().background(if (dark) Color.Black else Color(0xFFECEEEF))) {
        if (artwork != 0) {
            Image(painterResource(artwork), contentDescription = null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        }
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(
            if (dark) listOf(Color.Black.copy(alpha = .32f), Color.Black.copy(alpha = .76f))
            else listOf(Color.White.copy(alpha = .20f), Color.White.copy(alpha = .82f)),
        )))
        Column(Modifier.align(Alignment.Center).fillMaxWidth().padding(horizontal = 12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                BreezeLogo(18.dp)
                Text("Breeze", color = if (dark) Color.White else Color(0xFF202529), style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Medium)
            }
            Spacer(Modifier.height(10.dp))
            Surface(shape = RoundedCornerShape(50), color = if (dark) Color.Black.copy(alpha = .76f) else Color.White.copy(alpha = .92f),
                border = BorderStroke(.7.dp, if (dark) Color.White.copy(alpha = .30f) else Color.Black.copy(alpha = .14f))) {
                Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(BreezeIcons.AutoAwesome, contentDescription = null, tint = if (dark) Color(0xFF55D1D8) else Color(0xFF087C89), modifier = Modifier.size(11.dp))
                    Spacer(Modifier.width(5.dp))
                    Text("Ask or search", color = if (dark) Color.White.copy(alpha = .82f) else Color(0xFF34383A),
                        style = MaterialTheme.typography.labelSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}

@Composable
private fun NewTabTile(dark: Boolean, ink: Color, muted: Color, stroke: Color, onClick: () -> Unit) {
    val shape = RoundedCornerShape(16.dp)
    Column(
        Modifier.fillMaxWidth().aspectRatio(0.84f).clip(shape).drawBehind {
            drawRoundRect(color = stroke, style = Stroke(width = 1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(8.dp.toPx(), 6.dp.toPx()))), cornerRadius = androidx.compose.ui.geometry.CornerRadius(16.dp.toPx()))
        }.clickable(onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(BreezeIcons.Add, contentDescription = null, tint = if (dark) Color(0xFFB6BAC2) else Color(0xFF545A63), modifier = Modifier.size(38.dp))
        Spacer(Modifier.height(6.dp))
        Text("New tab", color = muted, style = MaterialTheme.typography.bodyLarge)
    }
}

@Composable
private fun PrivateTabsTile(
    dark: Boolean,
    ink: Color,
    muted: Color,
    stroke: Color,
    card: Color,
    showingPrivate: Boolean,
    onClick: () -> Unit,
) {
    val title = if (showingPrivate) "Regular tabs" else "Private tabs"
    val subtitle = if (showingPrivate) "Return to your regular browsing tabs" else "Tabs won’t be saved to your history"
    Surface(
        modifier = Modifier.fillMaxWidth().height(94.dp).clickable(onClick = onClick),
        shape = RoundedCornerShape(16.dp), color = card, border = BorderStroke(1.dp, stroke),
    ) {
        Row(Modifier.padding(horizontal = 18.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(BreezeIcons.VisibilityOff, contentDescription = null, tint = muted, modifier = Modifier.size(30.dp))
            Column(Modifier.weight(1f).padding(start = 16.dp)) {
                Text(title, color = ink, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Medium)
                Text(subtitle, color = muted, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Icon(BreezeIcons.NavigateNext, contentDescription = "Show $title", tint = ink, modifier = Modifier.size(25.dp))
        }
    }
}
