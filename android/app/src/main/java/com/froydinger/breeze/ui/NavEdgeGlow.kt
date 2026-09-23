package com.froydinger.breeze.ui

import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp

/** Draw-only overlay: never intercepts taps, and only animates during an active request. */
@Composable fun NavEdgeGlow() {
    val transition = rememberInfiniteTransition(label="Nav activity")
    val pulse by transition.animateFloat(.72f, 1f, infiniteRepeatable(tween(1800), RepeatMode.Reverse), label="Edge light")
    val colors = remember { listOf(Color(0xFFFF5946),Color(0xFFFFD744),Color(0xFF43E790),Color(0xFF22D7E7),Color(0xFF6473FF),Color(0xFFDE59FF),Color(0xFFFF5946)) }
    val brush = remember { Brush.sweepGradient(colors) }
    val bands = remember { listOf(36f to .026f, 27f to .035f, 18f to .055f, 10f to .09f, 4f to .4f) }
    val inset = with(LocalDensity.current) { 24.dp.toPx() }
    val corner = with(LocalDensity.current) { 40.dp.toPx() }
    Canvas(Modifier.fillMaxSize().clip(RoundedCornerShape(40.dp))) {
        val bounds = Size((size.width-inset*2).coerceAtLeast(0f),(size.height-inset*2).coerceAtLeast(0f))
        val radius = CornerRadius((corner-inset).coerceAtLeast(0f))
        bands.forEach { (width, opacity) ->
            drawRoundRect(brush,Offset(inset,inset),bounds,radius,alpha=opacity*pulse,style=Stroke(width.dp.toPx()))
        }
    }
}
