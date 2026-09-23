package com.froydinger.breeze.ui
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.vector.*
import androidx.compose.ui.unit.dp

/** Official Lucide outlines. See android/design-assets/lucide/LICENSE. */
object BreezeIcons {
    val ArrowBack: ImageVector by lazy { icon("arrow-left", "m12 19-7-7 7-7", "M19 12H5") }
    val ArrowForward: ImageVector by lazy { icon("arrow-right", "M5 12h14", "m12 5 7 7-7 7") }
    val Add: ImageVector by lazy { icon("plus", "M5 12h14", "M12 5v14") }
    val ArrowDownward: ImageVector by lazy { icon("arrow-down", "M12 5v14", "m19 12-7 7-7-7") }
    val AutoAwesome: ImageVector by lazy { icon("sparkles", "M11.017 2.814a1 1 0 0 1 1.966 0l1.051 5.558a2 2 0 0 0 1.594 1.594l5.558 1.051a1 1 0 0 1 0 1.966l-5.558 1.051a2 2 0 0 0-1.594 1.594l-1.051 5.558a1 1 0 0 1-1.966 0l-1.051-5.558a2 2 0 0 0-1.594-1.594l-5.558-1.051a1 1 0 0 1 0-1.966l5.558-1.051a2 2 0 0 0 1.594-1.594z", "M20 2v4", "M22 4h-4", "M2.0,20.0 a2.0,2.0 0 1,0 4.0,0 a2.0,2.0 0 1,0 -4.0,0") }
    val ChatBubbleOutline: ImageVector by lazy { icon("message-circle", "M2.992 16.342a2 2 0 0 1 .094 1.167l-1.065 3.29a1 1 0 0 0 1.236 1.168l3.413-.998a2 2 0 0 1 1.099.092 10 10 0 1 0-4.777-4.719") }
    val Chat: ImageVector by lazy { icon("message-circle", "M2.992 16.342a2 2 0 0 1 .094 1.167l-1.065 3.29a1 1 0 0 0 1.236 1.168l3.413-.998a2 2 0 0 1 1.099.092 10 10 0 1 0-4.777-4.719") }
    val ChevronRight: ImageVector by lazy { icon("chevron-right", "m9 18 6-6-6-6") }
    val ChevronUp: ImageVector by lazy { icon("chevron-up", "m18 15-6-6-6 6") }
    val Close: ImageVector by lazy { icon("x", "M18 6 6 18", "m6 6 12 12") }
    val Edit: ImageVector by lazy { icon("square-pen", "M12 3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7", "M18.375 2.625a1 1 0 0 1 3 3l-9.013 9.014a2 2 0 0 1-.853.505l-2.873.84a.5.5 0 0 1-.62-.62l.84-2.873a2 2 0 0 1 .506-.852z") }
    val ExpandMore: ImageVector by lazy { icon("chevron-down", "m6 9 6 6 6-6") }
    val History: ImageVector by lazy { icon("rotate-ccw-clock", "M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8", "M3 3v5h5", "M12 7v5l4 2") }
    val Home: ImageVector by lazy { icon("house", "M15 21v-8a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v8", "M3 10a2 2 0 0 1 .709-1.528l7-6a2 2 0 0 1 2.582 0l7 6A2 2 0 0 1 21 10v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z") }
    val Image: ImageVector by lazy { icon("image", "M5.0,3.0 H19.0 Q21.0,3.0 21.0,5.0 V19.0 Q21.0,21.0 19.0,21.0 H5.0 Q3.0,21.0 3.0,19.0 V5.0 Q3.0,3.0 5.0,3.0 Z", "M7.0,9.0 a2.0,2.0 0 1,0 4.0,0 a2.0,2.0 0 1,0 -4.0,0", "m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21") }
    val Info: ImageVector by lazy { icon("info", "M2.0,12.0 a10.0,10.0 0 1,0 20.0,0 a10.0,10.0 0 1,0 -20.0,0", "M12 16v-4", "M12 8h.01") }
    val Language: ImageVector by lazy { icon("globe", "M2.0,12.0 a10.0,10.0 0 1,0 20.0,0 a10.0,10.0 0 1,0 -20.0,0", "M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20", "M2 12h20") }
    val Lock: ImageVector by lazy { icon("lock-keyhole", "M11.0,16.0 a1.0,1.0 0 1,0 2.0,0 a1.0,1.0 0 1,0 -2.0,0", "M5.0,10.0 H19.0 Q21.0,10.0 21.0,12.0 V20.0 Q21.0,22.0 19.0,22.0 H5.0 Q3.0,22.0 3.0,20.0 V12.0 Q3.0,10.0 5.0,10.0 Z", "M7 10V7a5 5 0 0 1 10 0v3") }
    val MoreVert: ImageVector by lazy { icon("ellipsis-vertical", "M11.0,12.0 a1.0,1.0 0 1,0 2.0,0 a1.0,1.0 0 1,0 -2.0,0", "M11.0,5.0 a1.0,1.0 0 1,0 2.0,0 a1.0,1.0 0 1,0 -2.0,0", "M11.0,19.0 a1.0,1.0 0 1,0 2.0,0 a1.0,1.0 0 1,0 -2.0,0") }
    val NavigateNext: ImageVector by lazy { icon("chevron-right", "m9 18 6-6-6-6") }
    val OpenInNew: ImageVector by lazy { icon("square-arrow-out-up-right", "M21 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h6", "m21 3-9 9", "M15 3h6v6") }
    val PhotoCamera: ImageVector by lazy { icon("camera", "M13.997 4a2 2 0 0 1 1.76 1.05l.486.9A2 2 0 0 0 18.003 7H20a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V9a2 2 0 0 1 2-2h1.997a2 2 0 0 0 1.759-1.048l.489-.904A2 2 0 0 1 10.004 4z", "M9.0,13.0 a3.0,3.0 0 1,0 6.0,0 a3.0,3.0 0 1,0 -6.0,0") }
    val Refresh: ImageVector by lazy { icon("rotate-cw", "M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8", "M21 3v5h-5") }
    val Search: ImageVector by lazy { icon("search", "m21 21-4.34-4.34", "M3.0,11.0 a8.0,8.0 0 1,0 16.0,0 a8.0,8.0 0 1,0 -16.0,0") }
    val Send: ImageVector by lazy { icon("send-horizontal", "M3.714 3.048a.498.498 0 0 0-.683.627l2.843 7.627a2 2 0 0 1 0 1.396l-2.842 7.627a.498.498 0 0 0 .682.627l18-8.5a.5.5 0 0 0 0-.904z", "M6 12h16") }
    val Settings: ImageVector by lazy { icon("settings", "M9.671 4.136a2.34 2.34 0 0 1 4.659 0 2.34 2.34 0 0 0 3.319 1.915 2.34 2.34 0 0 1 2.33 4.033 2.34 2.34 0 0 0 0 3.831 2.34 2.34 0 0 1-2.33 4.033 2.34 2.34 0 0 0-3.319 1.915 2.34 2.34 0 0 1-4.659 0 2.34 2.34 0 0 0-3.32-1.915 2.34 2.34 0 0 1-2.33-4.033 2.34 2.34 0 0 0 0-3.831A2.34 2.34 0 0 1 6.35 6.051a2.34 2.34 0 0 0 3.319-1.915", "M9.0,12.0 a3.0,3.0 0 1,0 6.0,0 a3.0,3.0 0 1,0 -6.0,0") }
    val Stop: ImageVector by lazy { icon("square", "M5.0,3.0 H19.0 Q21.0,3.0 21.0,5.0 V19.0 Q21.0,21.0 19.0,21.0 H5.0 Q3.0,21.0 3.0,19.0 V5.0 Q3.0,3.0 5.0,3.0 Z") }
    val Tab: ImageVector by lazy { icon("panels-top-left", "M5.0,3.0 H19.0 Q21.0,3.0 21.0,5.0 V19.0 Q21.0,21.0 19.0,21.0 H5.0 Q3.0,21.0 3.0,19.0 V5.0 Q3.0,3.0 5.0,3.0 Z", "M3 9h18", "M9 21V9") }
    val Tune: ImageVector by lazy { icon("sliders-horizontal", "M10 5H3", "M12 19H3", "M14 3v4", "M16 17v4", "M21 12h-9", "M21 19h-5", "M21 5h-7", "M8 10v4", "M8 12H3") }
    val VisibilityOff: ImageVector by lazy { icon("eye-off", "M10.733 5.076a10.744 10.744 0 0 1 11.205 6.575 1 1 0 0 1 0 .696 10.747 10.747 0 0 1-1.444 2.49", "M14.084 14.158a3 3 0 0 1-4.242-4.242", "M17.479 17.499a10.75 10.75 0 0 1-15.417-5.151 1 1 0 0 1 0-.696 10.75 10.75 0 0 1 4.446-5.143", "m2 2 20 20") }
    val Visibility: ImageVector by lazy { icon("eye", "M2.062 12.348a1 1 0 0 1 0-.696 10.75 10.75 0 0 1 19.876 0 1 1 0 0 1 0 .696 10.75 10.75 0 0 1-19.876 0", "M9.0,12.0 a3.0,3.0 0 1,0 6.0,0 a3.0,3.0 0 1,0 -6.0,0") }
    val Delete: ImageVector by lazy { icon("trash", "M10 11v6", "M14 11v6", "M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6", "M3 6h18", "M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2") }
    val Bookmark: ImageVector by lazy { icon("bookmark", "M17 3a2 2 0 0 1 2 2v15a1 1 0 0 1-1.496.868l-4.512-2.578a2 2 0 0 0-1.984 0l-4.512 2.578A1 1 0 0 1 5 20V5a2 2 0 0 1 2-2z") }
    val BookmarkFilled: ImageVector by lazy {
        ImageVector.Builder("bookmark-filled", 24.dp, 24.dp, 24f, 24f).apply {
            addPath(
                pathData = PathParser().parsePathString("M7 3h10a2 2 0 0 1 2 2v16.4a.5.5 0 0 1-.74.44L12 18.5l-6.26 3.34a.5.5 0 0 1-.74-.44V5a2 2 0 0 1 2-2Z").toNodes(),
                fill = SolidColor(Color.Black),
            )
        }.build()
    }
    val Download: ImageVector by lazy { icon("download", "M12 15V3", "M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4", "m7 10 5 5 5-5") }
    val Shield: ImageVector by lazy { icon("shield-check", "M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z", "m9 12 2 2 4-4") }
    val DarkMode: ImageVector by lazy { icon("moon", "M20.985 12.486a9 9 0 1 1-9.473-9.472c.405-.022.617.46.402.803a6 6 0 0 0 8.268 8.268c.344-.215.825-.004.803.401") }
    val LightMode: ImageVector by lazy { icon("sun", "M8.0,12.0 a4.0,4.0 0 1,0 8.0,0 a4.0,4.0 0 1,0 -8.0,0", "M12 2v2", "M12 20v2", "m4.93 4.93 1.41 1.41", "m17.66 17.66 1.41 1.41", "M2 12h2", "M20 12h2", "m6.34 17.66-1.41 1.41", "m19.07 4.93-1.41 1.41") }
    val Computer: ImageVector by lazy { icon("monitor", "M4.0,3.0 H20.0 Q22.0,3.0 22.0,5.0 V15.0 Q22.0,17.0 20.0,17.0 H4.0 Q2.0,17.0 2.0,15.0 V5.0 Q2.0,3.0 4.0,3.0 Z", "M8,21 L16,21", "M12,17 L12,21") }
    val Palette: ImageVector by lazy { icon("palette", "M12 22a1 1 0 0 1 0-20 10 9 0 0 1 10 9 5 5 0 0 1-5 5h-2.25a1.75 1.75 0 0 0-1.4 2.8l.3.4a1.75 1.75 0 0 1-1.4 2.8z", "M13.0,6.5 a0.5,0.5 0 1,0 1.0,0 a0.5,0.5 0 1,0 -1.0,0", "M17.0,10.5 a0.5,0.5 0 1,0 1.0,0 a0.5,0.5 0 1,0 -1.0,0", "M6.0,12.5 a0.5,0.5 0 1,0 1.0,0 a0.5,0.5 0 1,0 -1.0,0", "M8.0,7.5 a0.5,0.5 0 1,0 1.0,0 a0.5,0.5 0 1,0 -1.0,0") }
    val Key: ImageVector by lazy { icon("key-round", "M2.586 17.414A2 2 0 0 0 2 18.828V21a1 1 0 0 0 1 1h3a1 1 0 0 0 1-1v-1a1 1 0 0 1 1-1h1a1 1 0 0 0 1-1v-1a1 1 0 0 1 1-1h.172a2 2 0 0 0 1.414-.586l.814-.814a6.5 6.5 0 1 0-4-4z", "M16.0,7.5 a0.5,0.5 0 1,0 1.0,0 a0.5,0.5 0 1,0 -1.0,0") }
    val Cloud: ImageVector by lazy { icon("cloud", "M17.5 19H9a7 7 0 1 1 6.71-9h1.79a4.5 4.5 0 1 1 0 9Z") }
    val Check: ImageVector by lazy { icon("check", "M20 6 9 17l-5-5") }
    val CheckCircle: ImageVector by lazy { icon("circle-check", "M2.0,12.0 a10.0,10.0 0 1,0 20.0,0 a10.0,10.0 0 1,0 -20.0,0", "m16 9-5.5 5.5L8 12") }
    val CheckCircleOutline: ImageVector by lazy { icon("circle-check", "M2.0,12.0 a10.0,10.0 0 1,0 20.0,0 a10.0,10.0 0 1,0 -20.0,0", "m16 9-5.5 5.5L8 12") }
    val ContentCopy: ImageVector by lazy { icon("copy", "M10.0,8.0 H20.0 Q22.0,8.0 22.0,10.0 V20.0 Q22.0,22.0 20.0,22.0 H10.0 Q8.0,22.0 8.0,20.0 V10.0 Q8.0,8.0 10.0,8.0 Z", "M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2") }
    val Share: ImageVector by lazy { icon("share-2", "M15.0,5.0 a3.0,3.0 0 1,0 6.0,0 a3.0,3.0 0 1,0 -6.0,0", "M3.0,12.0 a3.0,3.0 0 1,0 6.0,0 a3.0,3.0 0 1,0 -6.0,0", "M15.0,19.0 a3.0,3.0 0 1,0 6.0,0 a3.0,3.0 0 1,0 -6.0,0", "M8.59,13.51 L15.42,17.49", "M15.41,6.51 L8.59,10.49") }
    val Menu: ImageVector by lazy { icon("menu", "M4 5h16", "M4 12h16", "M4 19h16") }
    val Logout: ImageVector by lazy { icon("log-out", "m16 17 5-5-5-5", "M21 12H9", "M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4") }
    val Folder: ImageVector by lazy { icon("folder", "M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z") }
    val Help: ImageVector by lazy { icon("circle-question-mark", "M2.0,12.0 a10.0,10.0 0 1,0 20.0,0 a10.0,10.0 0 1,0 -20.0,0", "M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3", "M12 17h.01") }
    val Security: ImageVector by lazy { icon("shield-check", "M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z", "m9 12 2 2 4-4") }
    val Smartphone: ImageVector by lazy { icon("smartphone", "M7.0,2.0 H17.0 Q19.0,2.0 19.0,4.0 V20.0 Q19.0,22.0 17.0,22.0 H7.0 Q5.0,22.0 5.0,20.0 V4.0 Q5.0,2.0 7.0,2.0 Z", "M12 18h.01") }
    val FileText: ImageVector by lazy { icon("file-text", "M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2z", "M14 2v5a1 1 0 0 0 1 1h5", "M10 9H8", "M16 13H8", "M16 17H8") }
    val Youtube: ImageVector by lazy { icon("square-play", "M5.0,3.0 H19.0 Q21.0,3.0 21.0,5.0 V19.0 Q21.0,21.0 19.0,21.0 H5.0 Q3.0,21.0 3.0,19.0 V5.0 Q3.0,3.0 5.0,3.0 Z", "M9 9.003a1 1 0 0 1 1.517-.859l4.997 2.997a1 1 0 0 1 0 1.718l-4.997 2.997A1 1 0 0 1 9 14.996z") }
    val Sailboat: ImageVector by lazy { icon("sailboat", "M10 2v15", "M7 22a4 4 0 0 1-4-4 1 1 0 0 1 1-1h16a1 1 0 0 1 1 1 4 4 0 0 1-4 4z", "M9.159 2.46a1 1 0 0 1 1.521-.193l9.977 8.98A1 1 0 0 1 20 13H4a1 1 0 0 1-.824-1.567z") }
    val Wand: ImageVector by lazy { icon("wand-sparkles", "m21.64 3.64-1.28-1.28a1.21 1.21 0 0 0-1.72 0L2.36 18.64a1.21 1.21 0 0 0 0 1.72l1.28 1.28a1.2 1.2 0 0 0 1.72 0L21.64 5.36a1.2 1.2 0 0 0 0-1.72", "m14 7 3 3", "M5 6v4", "M19 14v4", "M10 2v2", "M7 8H3", "M21 16h-4", "M11 3H9") }
    val Clock: ImageVector by lazy { icon("clock-3", "M2.0,12.0 a10.0,10.0 0 1,0 20.0,0 a10.0,10.0 0 1,0 -20.0,0", "M12 6v6h4") }
    val CreditCard: ImageVector by lazy { icon("credit-card", "M4.0,5.0 H20.0 Q22.0,5.0 22.0,7.0 V17.0 Q22.0,19.0 20.0,19.0 H4.0 Q2.0,19.0 2.0,17.0 V7.0 Q2.0,5.0 4.0,5.0 Z", "M2,10 L22,10", "M6 14h2") }
    val Notifications: ImageVector by lazy { icon("bell", "M10.268 21a2 2 0 0 0 3.464 0", "M3.262 15.326A1 1 0 0 0 4 17h16a1 1 0 0 0 .74-1.673C19.41 13.956 18 12.499 18 8A6 6 0 0 0 6 8c0 4.499-1.411 5.956-2.738 7.326") }
    val AccountCircle: ImageVector by lazy { icon("circle-user-round", "M17.925 20.056a6 6 0 0 0-11.851.001", "M8.0,11.0 a4.0,4.0 0 1,0 8.0,0 a4.0,4.0 0 1,0 -8.0,0", "M2.0,12.0 a10.0,10.0 0 1,0 20.0,0 a10.0,10.0 0 1,0 -20.0,0") }
    val Fingerprint: ImageVector by lazy { icon("fingerprint-pattern", "M12 10a2 2 0 0 0-2 2c0 1.02-.1 2.51-.26 4", "M14 13.12c0 2.38 0 6.38-1 8.88", "M17.29 21.02c.12-.6.43-2.3.5-3.02", "M2 12a10 10 0 0 1 18-6", "M2 16h.01", "M21.8 16c.2-2 .131-5.354 0-6", "M5 19.5C5.5 18 6 15 6 12a6 6 0 0 1 .34-2", "M8.65 22c.21-.66.45-1.32.57-2", "M9 6.8a6 6 0 0 1 9 5.2v2") }
    val SearchCheck: ImageVector by lazy { icon("search-check", "m8 11 2 2 4-4", "M3.0,11.0 a8.0,8.0 0 1,0 16.0,0 a8.0,8.0 0 1,0 -16.0,0", "m21 21-4.3-4.3") }
    val ArrowUpward: ImageVector by lazy { icon("arrow-up", "m5 12 7-7 7 7", "M12 19V5") }
    private fun icon(name: String, vararg paths: String): ImageVector = ImageVector.Builder(name,24.dp,24.dp,24f,24f).apply {
        paths.forEach { addPath(pathData=PathParser().parsePathString(it).toNodes(), fill=null, stroke=SolidColor(Color.Black),strokeLineWidth=1.8f,strokeLineCap=StrokeCap.Round,strokeLineJoin=StrokeJoin.Round) }
    }.build()
}
