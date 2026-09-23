package com.froydinger.breeze.ui

import android.net.Uri
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.*
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.froydinger.breeze.*
import com.froydinger.breeze.R
import com.froydinger.breeze.core.HomeInputMode

@Composable fun ReferenceHomeScreen(
    state: BrowserState,
    dark: Boolean,
    tabUiEntrance: Float = 1f,
    modifier: Modifier = Modifier,
    preserveSurfaceViewport: Boolean = false,
) {
    val context=LocalContext.current
    val image=remember(state.wallpaper,dark) {context.resources.getIdentifier(state.wallpaper+if(dark) "_dark" else "_light","drawable",context.packageName)}
    val focus=LocalFocusManager.current
    val keyboardController = LocalSoftwareKeyboardController.current
    val inputFocusRequester = remember(state.selectedId) { FocusRequester() }
    var input by remember(state.selectedId) {mutableStateOf("")}
    var addShortcut by remember {mutableStateOf(false)}
    var shortcutName by remember {mutableStateOf("")}
    var shortcutUrl by remember {mutableStateOf("")}
    val density = LocalDensity.current
    val topSafeInset = if (state.screen == "browser" || preserveSurfaceViewport) with(density) { WindowInsets.safeDrawing.getTop(this).toDp() } else 0.dp
    val logoEntrance = remember(state.selectedId) { Animatable(0f) }
    LaunchedEffect(state.selectedId, state.screen, state.isHomePage, state.homeInputFocusTabId) {
        val requestedTabId = state.homeInputFocusTabId
        if (requestedTabId == state.selectedId && state.screen == "browser" && state.isHomePage) {
            inputFocusRequester.requestFocus()
            keyboardController?.show()
            state.consumeHomeInputFocus(requestedTabId)
        }
    }
    LaunchedEffect(logoEntrance) {
        logoEntrance.animateTo(1f, tween(durationMillis=520, easing=FastOutSlowInEasing))
    }
    val photo=rememberPhotoAttachmentAction(onPhoto=state::queueImage)
    val submitInput = {
        val query = input.trim()
        if (query.isNotBlank()) {
            input = ""
            focus.clearFocus()
            state.submit(query)
        }
    }
    BoxWithConstraints(modifier.fillMaxSize().then(screenEntrance())) {
        val screenHeight=maxHeight
        Crossfade(targetState=image, animationSpec=tween(260), label="Home background") { artwork ->
            if(artwork!=0) Image(painterResource(artwork),null,Modifier.fillMaxWidth().height(screenHeight+topSafeInset).offset(y=-topSafeInset),contentScale=ContentScale.Crop,alpha=if(dark).52f else .42f)
        }
        Box(Modifier.fillMaxWidth().height(screenHeight+topSafeInset).offset(y=-topSafeInset).background(Brush.verticalGradient(listOf(MaterialTheme.colorScheme.background.copy(alpha=.15f),MaterialTheme.colorScheme.background.copy(alpha=.35f),MaterialTheme.colorScheme.background))))
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal=18.dp)) {
            Spacer(Modifier.height((screenHeight*.095f).coerceIn(40.dp,82.dp) + 14.dp))
            if(state.selected?.private==true) Text("Private browsing",style=MaterialTheme.typography.labelMedium,color=BreezeTeal,modifier=Modifier.align(Alignment.CenterHorizontally))
            Row(Modifier.align(Alignment.CenterHorizontally).graphicsLayer {
                val progress = logoEntrance.value
                alpha = progress
                scaleX = .92f + .08f * progress
                scaleY = .92f + .08f * progress
                translationY = (1f - progress) * 11.dp.toPx()
            },verticalAlignment=Alignment.CenterVertically) {
                Box(
                    Modifier.size(52.dp).clip(CircleShape).clickable(onClick = state::startStandaloneNavChat),
                    contentAlignment = Alignment.Center,
                ) { BreezeLogo(46.dp) }
            }
            Spacer(Modifier.height(29.dp))
            Row(Modifier.fillMaxWidth().height(55.dp).graphicsLayer {
                val progress = tabUiEntrance.coerceIn(0f, 1f)
                alpha = progress
                translationY = -(1f - progress) * 20.dp.toPx()
            }.breezeGlass(32.dp).padding(horizontal=8.dp),verticalAlignment=Alignment.CenterVertically) {
                IconButton(onClick=photo,modifier=Modifier.size(42.dp)) {
                    Icon(BreezeIcons.PhotoCamera,"Attach a photo",Modifier.size(22.dp),tint=MaterialTheme.colorScheme.onSurface.copy(alpha=.78f))
                }
                Spacer(Modifier.width(3.dp))
                BasicTextField(value=input,onValueChange={input=it},modifier=Modifier.weight(1f).focusRequester(inputFocusRequester),singleLine=true,
                    textStyle=MaterialTheme.typography.bodyLarge.copy(color=MaterialTheme.colorScheme.onSurface),cursorBrush=SolidColor(BreezeTeal),
                    keyboardOptions=KeyboardOptions(imeAction=ImeAction.Go),keyboardActions=KeyboardActions(onGo={submitInput()}),
                    decorationBox={inner -> if(input.isEmpty()) Text(if(state.homeMode==HomeInputMode.SEARCH) "Search the web, or type a URL" else "Ask Breeze, or type a URL",fontSize=15.sp,color=MaterialTheme.colorScheme.onSurface.copy(alpha=.65f),maxLines=1);inner()})
                if(input.isNotBlank()) {
                    IconButton(onClick={submitInput()},modifier=Modifier.size(36.dp)) {Icon(BreezeIcons.ArrowForward,"Ask Breeze or open URL",Modifier.size(21.dp))}
                }
                Box(Modifier.padding(horizontal=6.dp).width(.7.dp).height(27.dp).background(MaterialTheme.colorScheme.onSurface.copy(alpha=.18f)))
                VoiceTranscriptionButton(
                    cloudConsentAccepted=state.cloudDisclosureAccepted,
                    onCloudConsentRequired=state::requestCloudDisclosure,
                    onText={recognized -> input=if(input.isBlank()) recognized else "$input $recognized"},
                    onError={state.notice=it},
                    onSubmit={recognized ->
                        val spoken = recognized.trim()
                        val query = if (input.trim().endsWith(spoken)) input.trim() else listOf(input.trim(), spoken).filter(String::isNotBlank).joinToString(" ")
                        input = ""
                        focus.clearFocus()
                        state.submit(query)
                    },
                )
            }
            Text("Powered by Spectra",fontSize=10.sp,color=MaterialTheme.colorScheme.onSurface.copy(alpha=.45f),modifier=Modifier.align(Alignment.CenterHorizontally).padding(top=8.dp))
            // Leave the scene visible, as in the approved home reference.
            Spacer(Modifier.height((screenHeight*.012f).coerceIn(8.dp,12.dp)))
            BoxWithConstraints(Modifier.fillMaxWidth()) {
                val itemCount = state.pinnedSites.size + 1
                val contentWidth = (56f * itemCount + 14f * (itemCount - 1)).dp
                val needsScroll = contentWidth > maxWidth
                Row(
                    Modifier.fillMaxWidth().then(if (needsScroll) Modifier.horizontalScroll(rememberScrollState()) else Modifier),
                    horizontalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterHorizontally),
                    verticalAlignment = Alignment.Top,
                ) {
                    state.pinnedSites.forEachIndexed { index, site ->
                        PinnedShortcut(site, index, state.pinnedSites.size,
                            onClick={state.navigate(site.url)},
                            onMoveLeft={state.movePinnedSite(site.id, -1)},
                            onMoveRight={state.movePinnedSite(site.id, 1)},
                            onDelete={state.unpinSite(site.id)})
                    }
                    Shortcut("Add",null,3) {addShortcut=true}
                }
            }
            if(state.bookmarks.isNotEmpty()) Row(Modifier.horizontalScroll(rememberScrollState()).padding(top=10.dp),horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                state.bookmarks.take(5).forEach { page -> TextButton(onClick={state.navigate(page.url)}) {Text(page.title.take(16),style=MaterialTheme.typography.labelMedium)} }
            }
            Spacer(Modifier.height(32.dp))
            Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween,verticalAlignment=Alignment.CenterVertically) {
                Text("Recent tabs",fontSize=17.sp,fontWeight=FontWeight.Medium)
                Row(Modifier.clickable {state.screen="tabs"}.padding(vertical=6.dp),verticalAlignment=Alignment.CenterVertically) {Text("See all",fontSize=12.sp);Icon(BreezeIcons.ChevronRight,null,Modifier.size(19.dp))}
            }
            Spacer(Modifier.height(12.dp))
            val tabs=state.tabs.filter{!it.private && it.url.isNotBlank()}.takeLast(3).reversed()
            LaunchedEffect(tabs.map { it.id }) { tabs.forEach { state.loadThumbnail(it) } }
            if(tabs.isEmpty()) Box(Modifier.fillMaxWidth().height(132.dp).breezeGlass(15.dp),contentAlignment=Alignment.Center) {
                Column(horizontalAlignment=Alignment.CenterHorizontally) {Icon(BreezeIcons.Tab,null,tint=MaterialTheme.colorScheme.onSurface.copy(alpha=.4f));Spacer(Modifier.height(10.dp));Text("Your recent tabs will appear here",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurface.copy(alpha=.5f))}
            } else Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(9.dp)) {
                tabs.forEach {tab -> Column(Modifier.weight(1f).height(150.dp).breezeGlass(14.dp).clickable {state.select(tab)}.padding(5.dp)) {
                    val thumb=tab.thumbnail
                    if(thumb!=null) Image(thumb.asImageBitmap(),null,Modifier.fillMaxWidth().height(76.dp).clip(RoundedCornerShape(10.dp)),contentScale=ContentScale.Crop)
                    else Box(Modifier.fillMaxWidth().height(76.dp).clip(RoundedCornerShape(10.dp)).background(Color(if(dark)0xFF292C2D else 0xFFE0E3E4)),contentAlignment=Alignment.Center) {Icon(BreezeIcons.Language,null,Modifier.size(25.dp),tint=MaterialTheme.colorScheme.onSurface.copy(alpha=.35f))}
                    Row(Modifier.padding(top=6.dp,start=2.dp,end=2.dp).height(35.dp),verticalAlignment=Alignment.Top) {
                        Icon(BreezeIcons.Language,null,Modifier.padding(top=1.dp).size(13.dp),tint=MaterialTheme.colorScheme.onSurfaceVariant)
                        Spacer(Modifier.width(5.dp))
                        Text(tab.title,fontSize=11.sp,lineHeight=15.sp,maxLines=2,overflow=TextOverflow.Ellipsis,modifier=Modifier.weight(1f))
                    }
                    Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically) {
                        Text(Uri.parse(tab.url).host.orEmpty().removePrefix("www."),fontSize=9.sp,color=MaterialTheme.colorScheme.onSurface.copy(alpha=.45f),maxLines=1,overflow=TextOverflow.Ellipsis,modifier=Modifier.weight(1f).padding(start=4.dp))
                        var menu by remember { mutableStateOf(false) }
                        Box {
                            IconButton(onClick={menu=true},modifier=Modifier.size(25.dp)) {Icon(BreezeIcons.MoreVert,"Options for ${tab.title}",Modifier.size(15.dp))}
                            DropdownMenu(expanded=menu,onDismissRequest={menu=false}) {
                                DropdownMenuItem(text={Text("Open tab")},onClick={menu=false;state.select(tab)})
                                DropdownMenuItem(text={Text("Close tab")},onClick={menu=false;state.close(tab)})
                            }
                        }
                    }
                }}
                if(tabs.size<3) Spacer(Modifier.weight((3-tabs.size).toFloat()))
            }
            Spacer(Modifier.height(18.dp))
            Row(Modifier.fillMaxWidth().height(78.dp).breezeGlass(17.dp).clickable {state.openChatsHistory()}.padding(horizontal=20.dp),verticalAlignment=Alignment.CenterVertically) {
                Icon(BreezeIcons.ChatBubbleOutline,null,Modifier.size(29.dp),tint=Color(0xFF43B9C8));Spacer(Modifier.width(20.dp));Text("Recent chats",fontSize=16.sp);Spacer(Modifier.weight(1f));Icon(BreezeIcons.ChevronRight,null,Modifier.size(23.dp),tint=MaterialTheme.colorScheme.onSurface.copy(alpha=.7f))
            }
            Spacer(Modifier.height(25.dp))
        }
    }
    if(addShortcut) AlertDialog(onDismissRequest={addShortcut=false},title={Text("Add shortcut")},text={Column {OutlinedTextField(shortcutName,{shortcutName=it},label={Text("Name")});OutlinedTextField(shortcutUrl,{shortcutUrl=it},label={Text("Website URL")})}},confirmButton={TextButton(onClick={
        val url=if(shortcutUrl.contains("://"))shortcutUrl else "https://$shortcutUrl"
        if(state.pinSite(shortcutName, url)) {addShortcut=false; shortcutName=""; shortcutUrl=""}else state.notice="Enter a valid website URL"
    }) {Text("Add")}},dismissButton={TextButton(onClick={addShortcut=false}) {Text("Cancel")}})
}
@Composable private fun PinnedShortcut(site:PinnedSite,index:Int,count:Int,onClick:()->Unit,onMoveLeft:()->Unit,onMoveRight:()->Unit,onDelete:()->Unit) {
    var menu by remember { mutableStateOf(false) }
    var dragging by remember { mutableStateOf(false) }
    var dragOffset by remember { mutableFloatStateOf(0f) }
    var dragOffsetY by remember { mutableFloatStateOf(0f) }
    val currentIndex = rememberUpdatedState(index)
    val currentCount = rememberUpdatedState(count)
    val moveLeft = rememberUpdatedState(onMoveLeft)
    val moveRight = rememberUpdatedState(onMoveRight)
    val density = LocalDensity.current
    val stepPx = with(density) { 70.dp.toPx() }
    val title=site.title
    val host = Uri.parse(site.url).host.orEmpty().removePrefix("www.")
    val known = when {
        host.contains("google.") -> "Google"
        host.contains("youtube.") -> "YouTube"
        host.contains("wikipedia.") -> "Wikipedia"
        host.contains("reddit.") -> "Reddit"
        else -> title
    }
    Box {
        Column(
            horizontalAlignment=Alignment.CenterHorizontally,
            modifier=Modifier.width(56.dp).graphicsLayer {
                translationX = dragOffset
                translationY = dragOffsetY
                scaleX = if (dragging) .96f else 1f
                scaleY = if (dragging) .96f else 1f
                alpha = if (dragging) .82f else 1f
            }.pointerInput(site.id) {
                var accumulatedX = 0f
                var accumulatedY = 0f
                var reordered = false
                detectDragGesturesAfterLongPress(
                    onDragStart = {
                        dragging = true
                        accumulatedX = 0f
                        accumulatedY = 0f
                        dragOffset = 0f
                        dragOffsetY = 0f
                        reordered = false
                    },
                    onDragEnd = {
                        dragging = false
                        dragOffset = 0f
                        dragOffsetY = 0f
                        val steps = (accumulatedX / stepPx).toInt().let { wholeSteps ->
                            val remainder = accumulatedX - wholeSteps * stepPx
                            wholeSteps + if (kotlin.math.abs(remainder) >= stepPx * .5f) {
                                if (remainder > 0f) 1 else -1
                            } else 0
                        }
                        val boundedSteps = steps.coerceIn(-currentIndex.value, currentCount.value - 1 - currentIndex.value)
                        repeat(kotlin.math.abs(boundedSteps)) {
                            if (boundedSteps > 0) moveRight.value() else moveLeft.value()
                        }
                        reordered = boundedSteps != 0
                        if (!reordered) menu = true
                    },
                    onDragCancel = { dragging = false; dragOffset = 0f; dragOffsetY = 0f },
                    onDrag = { change, delta ->
                        change.consume()
                        accumulatedX += delta.x
                        accumulatedY += delta.y
                        dragOffset = accumulatedX
                        dragOffsetY = accumulatedY
                    },
                )
            }.clickable(onClick=onClick),
        ) {
            Box(Modifier.size(54.dp).breezeGlass(17.dp),contentAlignment=Alignment.Center) {
                when (known) {
                    "Google" -> Image(painterResource(R.drawable.shortcut_google),null,Modifier.size(27.dp))
                    "Reddit" -> Image(painterResource(R.drawable.shortcut_reddit),null,Modifier.size(29.dp))
                    "YouTube" -> Canvas(Modifier.size(31.dp,23.dp)) {
                        drawRoundRect(Color(0xFFFF151D),cornerRadius=androidx.compose.ui.geometry.CornerRadius(6.dp.toPx()))
                        val p=Path().apply{moveTo(size.width*.41f,size.height*.25f);lineTo(size.width*.41f,size.height*.75f);lineTo(size.width*.7f,size.height*.5f);close()};drawPath(p,Color.White)
                    }
                    "Wikipedia" -> Text("W",fontFamily=FontFamily.Serif,fontSize=28.sp,color=MaterialTheme.colorScheme.onSurface)
                    else -> Icon(BreezeIcons.Language,null,Modifier.size(25.dp),tint=MaterialTheme.colorScheme.onSurface.copy(alpha=.8f))
                }
            }
            Spacer(Modifier.height(7.dp));Text(title,fontSize=11.sp,fontWeight=FontWeight.Normal,maxLines=1,overflow=TextOverflow.Ellipsis)
        }
        DropdownMenu(expanded=menu,onDismissRequest={menu=false}) {
            DropdownMenuItem(text={Text("Move left")},enabled=index>0,onClick={menu=false;onMoveLeft()})
            DropdownMenuItem(text={Text("Move right")},enabled=index<count-1,onClick={menu=false;onMoveRight()})
            DropdownMenuItem(text={Text("Remove favorite")},onClick={menu=false;onDelete()})
        }
    }
}
@Composable private fun Shortcut(label:String,image:Int?,kind:Int,onClick:()->Unit) {
    Column(horizontalAlignment=Alignment.CenterHorizontally,modifier=Modifier.width(56.dp).clickable(onClick=onClick)) {
        Box(Modifier.size(54.dp).breezeGlass(17.dp),contentAlignment=Alignment.Center) {
            when {
                image!=null -> Image(painterResource(image),null,Modifier.size(if(label=="Reddit")29.dp else 27.dp))
                kind==1 -> Canvas(Modifier.size(31.dp,23.dp)) {
                    drawRoundRect(Color(0xFFFF151D),cornerRadius=androidx.compose.ui.geometry.CornerRadius(6.dp.toPx()))
                    val p=Path().apply{moveTo(size.width*.41f,size.height*.25f);lineTo(size.width*.41f,size.height*.75f);lineTo(size.width*.7f,size.height*.5f);close()};drawPath(p,Color.White)
                }
                kind==2 -> Text("W",fontFamily=FontFamily.Serif,fontSize=28.sp,color=MaterialTheme.colorScheme.onSurface)
                else -> Icon(BreezeIcons.Add,null,Modifier.size(27.dp),tint=MaterialTheme.colorScheme.onSurface.copy(alpha=.8f))
            }
        }
        Spacer(Modifier.height(7.dp));Text(label,fontSize=11.sp,fontWeight=FontWeight.Normal)
    }
}
