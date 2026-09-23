package com.froydinger.breeze

import android.content.Context
import android.media.MediaPlayer

/** Short local interface sounds, mixed quietly so they stay in the background. */
object BreezeSoundEffects {
    private const val VOLUME = 0.1f

    fun play(context: Context, resourceId: Int) {
        val player = runCatching { MediaPlayer.create(context.applicationContext, resourceId) }.getOrNull() ?: return
        player.setVolume(VOLUME, VOLUME)
        player.setOnCompletionListener { it.release() }
        player.setOnErrorListener { mediaPlayer, _, _ ->
            mediaPlayer.release()
            true
        }
        runCatching { player.start() }.onFailure { runCatching { player.release() } }
    }
}
