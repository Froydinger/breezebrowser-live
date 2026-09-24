package com.froydinger.breeze.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

private data class WelcomePage(
    val icon: androidx.compose.ui.graphics.vector.ImageVector,
    val title: String,
    val body: String,
    val detail: String,
)

@Composable
fun FirstRunOnboarding(onFinish: () -> Unit) {
    var page by remember { mutableIntStateOf(0) }
    val pages = remember {
        listOf(
            WelcomePage(
                BreezeIcons.Language,
                "Browse your way",
                "Search with Spectra or type any web address. Pin favorite sites and keep several tabs open.",
                "Your tabs stay ready when you switch between them.",
            ),
            WelcomePage(
                BreezeIcons.AutoAwesome,
                "Ask Nav",
                "Chat normally, or choose Research, Summarize, Fact check, YouTube, or Reminder above the message box.",
                "Attach the page you are viewing or add a photo when it helps.",
            ),
            WelcomePage(
                BreezeIcons.Shield,
                "Your browser, your data",
                "History, bookmarks, tabs, and saved passwords stay on this device. Accounts and cloud sync are coming soon.",
                "When you send a Nav request, your prompt and any attached page or photo are sent to Breeze Cloud and OpenAI to answer.",
            ),
        )
    }
    val dark = MaterialTheme.colorScheme.background.red < .3f
    val accent = if (dark) Color(0xFF55D1D8) else Color(0xFF087C89)
    val surface = MaterialTheme.colorScheme.surface
    val ink = MaterialTheme.colorScheme.onSurface
    val muted = MaterialTheme.colorScheme.onSurfaceVariant
    val enteringFromRight = page >= 0

    Box(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .windowInsetsPadding(WindowInsets.safeDrawing),
    ) {
        Column(
            Modifier.fillMaxSize().padding(horizontal = 26.dp, vertical = 18.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                BreezeLogo(34.dp)
                Spacer(Modifier.width(10.dp))
                Text("Breeze", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Medium, color = ink)
                Spacer(Modifier.weight(1f))
                TextButton(onClick = onFinish) { Text("Skip", color = muted) }
            }
            Spacer(Modifier.weight(1f))
            AnimatedContent(
                targetState = page,
                transitionSpec = {
                    val direction = if (targetState >= initialState) 1 else -1
                    (slideInHorizontally(tween(240)) { it * direction } + fadeIn(tween(180))) togetherWith
                        (slideOutHorizontally(tween(200)) { -it * direction } + fadeOut(tween(150)))
                },
                label = "Welcome page",
            ) { index ->
                val item = pages[index]
                Column(
                    Modifier.fillMaxWidth().padding(horizontal = 2.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Surface(
                        modifier = Modifier.size(112.dp),
                        shape = RoundedCornerShape(36.dp),
                        color = accent.copy(alpha = if (dark) .16f else .10f),
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            if (item.title == "Ask Nav") {
                                NavMark(62.dp)
                            } else {
                                Icon(item.icon, contentDescription = null, tint = accent, modifier = Modifier.size(46.dp))
                            }
                        }
                    }
                    Spacer(Modifier.height(32.dp))
                    Text(item.title, style = MaterialTheme.typography.headlineMedium, color = ink, textAlign = TextAlign.Center)
                    Spacer(Modifier.height(14.dp))
                    Text(item.body, style = MaterialTheme.typography.bodyLarge, color = muted, textAlign = TextAlign.Center)
                    Spacer(Modifier.height(15.dp))
                    Surface(shape = RoundedCornerShape(18.dp), color = surface.copy(alpha = if (dark) .9f else 1f)) {
                        Text(item.detail, Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
                            style = MaterialTheme.typography.bodyMedium, color = ink.copy(alpha = .84f), textAlign = TextAlign.Center)
                    }
                }
            }
            Spacer(Modifier.weight(1f))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                pages.indices.forEach { index ->
                    Box(
                        Modifier.size(if (index == page) 22.dp else 7.dp, 7.dp)
                            .background(if (index == page) accent else muted.copy(alpha = .38f), CircleShape),
                    )
                }
            }
            Spacer(Modifier.height(24.dp))
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                if (page > 0) {
                    TextButton(onClick = { page-- }, modifier = Modifier.weight(1f)) { Text("Back", color = muted) }
                }
                Button(
                    onClick = { if (page == pages.lastIndex) onFinish() else page++ },
                    modifier = Modifier.weight(if (page > 0) 2f else 1f).height(54.dp),
                    shape = RoundedCornerShape(18.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = accent),
                ) {
                    Text(if (page == pages.lastIndex) "Start browsing" else "Continue", fontWeight = FontWeight.SemiBold)
                }
            }
            Spacer(Modifier.height(6.dp))
        }
    }
}
