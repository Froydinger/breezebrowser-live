package com.froydinger.breeze.ui

import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.froydinger.breeze.R

val LocalGlassEnabled = staticCompositionLocalOf { true }
val BreezeTeal = Color(0xFF3AA6B9)
val BreezeFont = FontFamily(Font(R.font.inter))
val BreezeTypography = Typography(
    displaySmall=TextStyle(fontFamily=BreezeFont,fontWeight=FontWeight.Normal,fontSize=36.sp,lineHeight=43.sp),
    headlineSmall=TextStyle(fontFamily=BreezeFont,fontWeight=FontWeight.Medium,fontSize=24.sp,lineHeight=31.sp),
    headlineMedium=TextStyle(fontFamily=BreezeFont,fontWeight=FontWeight.Medium,fontSize=26.sp,lineHeight=34.sp),
    headlineLarge=TextStyle(fontFamily=BreezeFont,fontWeight=FontWeight.Medium,fontSize=28.sp,lineHeight=36.sp),
    titleLarge=TextStyle(fontFamily=BreezeFont,fontWeight=FontWeight.Medium,fontSize=23.sp,lineHeight=30.sp),
    titleMedium=TextStyle(fontFamily=BreezeFont,fontWeight=FontWeight.Medium,fontSize=17.sp,lineHeight=24.sp),
    titleSmall=TextStyle(fontFamily=BreezeFont,fontWeight=FontWeight.Medium,fontSize=14.sp,lineHeight=20.sp),
    bodyLarge=TextStyle(fontFamily=BreezeFont,fontWeight=FontWeight.Normal,fontSize=16.sp,lineHeight=24.sp),
    bodyMedium=TextStyle(fontFamily=BreezeFont,fontWeight=FontWeight.Normal,fontSize=14.sp,lineHeight=21.sp),
    bodySmall=TextStyle(fontFamily=BreezeFont,fontWeight=FontWeight.Normal,fontSize=12.sp,lineHeight=18.sp),
    labelLarge=TextStyle(fontFamily=BreezeFont,fontWeight=FontWeight.Medium,fontSize=14.sp,lineHeight=20.sp),
    labelMedium=TextStyle(fontFamily=BreezeFont,fontWeight=FontWeight.Normal,fontSize=12.sp,lineHeight=17.sp),
    labelSmall=TextStyle(fontFamily=BreezeFont,fontWeight=FontWeight.Normal,fontSize=10.sp,lineHeight=14.sp),
)

/** Screenshot-derived neutral glass. Thin optical rim; no teal-tinted panel fill. */
@Composable fun Modifier.breezeGlass(radius:Dp=18.dp):Modifier {
    val dark=MaterialTheme.colorScheme.background.red<.3f
    val glass=LocalGlassEnabled.current
    val shape=RoundedCornerShape(radius)
    val fill=if(dark) Color.Black else Color(0xFFFAFAF9)
    val rim=Brush.linearGradient(if(dark) listOf(Color.White.copy(alpha=.20f),Color.White.copy(alpha=.055f),Color.White.copy(alpha=.11f)) else listOf(Color.White,Color(0xFFCBCBCD).copy(alpha=.6f),Color.White.copy(alpha=.85f)))
    val alpha = if (dark) 1f else if (glass) .87f else 1f
    return clip(shape).background(Brush.verticalGradient(listOf(fill.copy(alpha=alpha),fill.copy(alpha=alpha))))
        .border(if(glass) .65.dp else .3.dp,rim,shape)
}
@Composable fun GlassCard(modifier:Modifier=Modifier,content:@Composable ColumnScope.()->Unit) {
    Column(modifier.breezeGlass().padding(16.dp),content=content)
}
private object LogoBitmaps {
    private val bitmaps = mutableMapOf<Int, ImageBitmap>()

    @Synchronized
    fun get(context: android.content.Context, resourceId: Int): ImageBitmap =
        bitmaps.getOrPut(resourceId) {
            BitmapFactory.decodeResource(
                context.applicationContext.resources,
                resourceId,
                BitmapFactory.Options().apply { inSampleSize = 4 },
            ).asImageBitmap()
        }
}
@Composable fun NavMark(size:Dp=32.dp, glowing:Boolean=false) {
    val context = LocalContext.current
    val logo = remember(context.applicationContext) { LogoBitmaps.get(context, R.drawable.nav_logo) }
    Image(bitmap=logo, contentDescription="Nav", modifier=Modifier.size(size).drawBehind {
        if(glowing) drawCircle(Brush.radialGradient(listOf(BreezeTeal.copy(alpha=.42f), Color.Transparent), radius=this.size.maxDimension*.8f), radius=this.size.maxDimension*.8f)
    }, filterQuality=FilterQuality.High)
}
@Composable fun BreezeLogo(size:Dp=36.dp) {
    val context=LocalContext.current
    val logo=remember(context.applicationContext) { LogoBitmaps.get(context,R.drawable.breeze_logo_flat) }
    Image(bitmap=logo,contentDescription="Breeze",modifier=Modifier.size(size),filterQuality=FilterQuality.High)
}
@Composable fun SectionTitle(title:String,action:String?=null,onAction:()->Unit={}) {
    Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween,verticalAlignment=Alignment.CenterVertically) {
        Text(title,style=MaterialTheme.typography.titleMedium)
        if(action!=null) TextButton(onClick=onAction,colors=ButtonDefaults.textButtonColors(contentColor=MaterialTheme.colorScheme.onSurface)) {Text(action,style=MaterialTheme.typography.bodySmall)}
    }
}
