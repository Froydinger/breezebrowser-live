package com.froydinger.breeze

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.FrameMetrics
import android.view.Window
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import java.util.ArrayDeque
import org.mozilla.geckoview.GeckoSession

/** Counts frames actually produced by the Activity window; debug builds only. */
internal class DevFpsTracker(private val window: Window) {
    var fps by mutableIntStateOf(0)
        private set

    private val handler = Handler(Looper.getMainLooper())
    private val frameTimes = ArrayDeque<Long>()
    private val pageFrameTimes = ArrayDeque<Long>()
    private var pageSession: GeckoSession? = null
    private var running = false
    private val listener = Window.OnFrameMetricsAvailableListener { _, metrics, _ ->
        if (running && metrics.getMetric(FrameMetrics.TOTAL_DURATION) > 0L) {
            frameTimes.addLast(SystemClock.elapsedRealtimeNanos())
        }
    }
    private val pageDraw = Runnable {
        val frameTime = SystemClock.elapsedRealtimeNanos()
        if (Looper.myLooper() == Looper.getMainLooper()) {
            if (running) pageFrameTimes.addLast(frameTime)
        } else {
            handler.post { if (running) pageFrameTimes.addLast(frameTime) }
        }
    }
    private val update = object : Runnable {
        override fun run() {
            if (!running) return
            val cutoff = SystemClock.elapsedRealtimeNanos() - 1_000_000_000L
            while (frameTimes.isNotEmpty() && frameTimes.first < cutoff) frameTimes.removeFirst()
            while (pageFrameTimes.isNotEmpty() && pageFrameTimes.first < cutoff) pageFrameTimes.removeFirst()
            fps = maxOf(frameTimes.size, pageFrameTimes.size)
            handler.postDelayed(this, 500L)
        }
    }

    fun watchPage(session: GeckoSession?) {
        if (pageSession === session) return
        pageSession?.compositorController?.removeDrawCallback(pageDraw)
        pageSession = session
        pageFrameTimes.clear()
        if (running) session?.compositorController?.addDrawCallback(pageDraw)
    }

    fun start() {
        if (running) return
        running = true
        frameTimes.clear()
        pageFrameTimes.clear()
        window.addOnFrameMetricsAvailableListener(listener, handler)
        pageSession?.compositorController?.addDrawCallback(pageDraw)
        handler.postDelayed(update, 500L)
    }

    fun stop() {
        if (!running) return
        running = false
        handler.removeCallbacks(update)
        window.removeOnFrameMetricsAvailableListener(listener)
        pageSession?.compositorController?.removeDrawCallback(pageDraw)
        frameTimes.clear()
        pageFrameTimes.clear()
        fps = 0
    }
}
