package com.froydinger.breeze.ui

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaRecorder
import android.os.Build
import android.os.SystemClock
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.size
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Brush
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.froydinger.breeze.BuildConfig
import com.froydinger.breeze.BreezeSoundEffects
import com.froydinger.breeze.R
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.URI
import java.net.URL
import java.util.UUID
import javax.net.ssl.HttpsURLConnection

private enum class VoicePhase { IDLE, RECORDING, TRANSCRIBING }

/** Records a short private-cache audio clip and adds its transcript to the caller's draft. */
@Composable
fun VoiceTranscriptionButton(
    enabled: Boolean = true,
    cloudConsentAccepted: Boolean = true,
    onCloudConsentRequired: () -> Unit = {},
    onText: (String) -> Unit,
    onError: (String) -> Unit,
    onSubmit: ((String) -> Unit)? = null,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var phase by remember { mutableStateOf(VoicePhase.IDLE) }
    var recorder by remember { mutableStateOf<MediaRecorder?>(null) }
    var audioFile by remember { mutableStateOf<File?>(null) }
    val currentOnText = rememberUpdatedState(onText)
    val currentOnError = rememberUpdatedState(onError)
    val currentOnSubmit = rememberUpdatedState(onSubmit)
    val currentOnCloudConsentRequired = rememberUpdatedState(onCloudConsentRequired)

    fun releaseRecorder(stop: Boolean): File? {
        val active = recorder
        recorder = null
        if (active != null) {
            if (stop) runCatching { active.stop() }
            runCatching { active.reset() }
            runCatching { active.release() }
        }
        val file = audioFile
        audioFile = null
        return file
    }

    fun beginRecording() {
        if (!enabled || phase != VoicePhase.IDLE) return
        val file = runCatching { File.createTempFile("breeze-voice-", ".m4a", context.cacheDir) }
            .getOrElse { onError("Could not start voice recording."); return }
        val active = runCatching { createRecorder(context, file) }.getOrElse {
            file.delete()
            onError("Could not start voice recording.")
            return
        }
        runCatching { active.prepare(); active.start() }.onFailure {
            runCatching { active.release() }
            file.delete()
            onError("Could not access the microphone. Check Android microphone permission and try again.")
            return
        }
        audioFile = file
        recorder = active
        phase = VoicePhase.RECORDING
        BreezeSoundEffects.play(context, R.raw.microphone_start)
    }

    fun finishRecording() {
        if (phase != VoicePhase.RECORDING) return
        phase = VoicePhase.TRANSCRIBING
        BreezeSoundEffects.play(context, R.raw.microphone_stop)
        val file = releaseRecorder(stop = true)
        if (file == null || !file.exists() || file.length() == 0L) {
            file?.delete()
            phase = VoicePhase.IDLE
            onError("No audio was captured. Hold the mic a little longer and try again.")
            return
        }
        scope.launch {
            try {
                val transcript = withContext(Dispatchers.IO) { transcribe(file) }
                if (transcript.isNotBlank()) {
                    currentOnText.value(transcript)
                    currentOnSubmit.value?.invoke(transcript)
                } else currentOnError.value("No speech was detected. Try again in a quieter spot.")
            } catch (error: Exception) {
                currentOnError.value(error.message ?: "Voice transcription failed. Try again.")
            } finally {
                file.delete()
                phase = VoicePhase.IDLE
            }
        }
    }

    LaunchedEffect(phase, recorder) {
        if (phase == VoicePhase.RECORDING) {
            val recordingStartedAt = SystemClock.elapsedRealtime()
            var lastSpeechAt = recordingStartedAt
            while (phase == VoicePhase.RECORDING) {
                delay(SILENCE_POLL_MS)
                val now = SystemClock.elapsedRealtime()
                val peak = runCatching { recorder?.maxAmplitude ?: 0 }.getOrDefault(0)
                if (peak >= SPEECH_AMPLITUDE_THRESHOLD) lastSpeechAt = now
                if (now - lastSpeechAt >= SILENCE_TIMEOUT_MS || now - recordingStartedAt >= MAX_RECORDING_MS) {
                    finishRecording()
                    break
                }
            }
        }
    }

    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) beginRecording()
        else onError("Microphone permission is off. Allow it in Android Settings to use voice input.")
    }

    DisposableEffect(Unit) {
        onDispose {
            val active = recorder
            recorder = null
            if (active != null) {
                runCatching { active.stop() }
                runCatching { active.release() }
            }
            audioFile?.delete()
        }
    }

    IconButton(
        enabled = enabled || phase == VoicePhase.RECORDING,
        onClick = {
            when (phase) {
                VoicePhase.RECORDING -> finishRecording()
                VoicePhase.IDLE -> {
                    if (!cloudConsentAccepted) currentOnCloudConsentRequired.value()
                    else if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                        beginRecording()
                    } else permissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
                }
                VoicePhase.TRANSCRIBING -> Unit
            }
        },
        modifier = Modifier.size(42.dp).drawBehind {
            if (phase == VoicePhase.RECORDING) {
                val glowRadius = size.maxDimension * .88f
                drawCircle(
                    brush = Brush.radialGradient(
                        colors = listOf(BreezeTeal.copy(alpha = .42f), BreezeTeal.copy(alpha = .15f), Color.Transparent),
                        radius = glowRadius,
                    ),
                    radius = glowRadius,
                )
            }
        },
    ) {
        when (phase) {
            VoicePhase.TRANSCRIBING -> CircularProgressIndicator(Modifier.size(19.dp), strokeWidth = 2.dp)
            VoicePhase.RECORDING -> Icon(VoiceMicIcon, "Listening. Tap to send now.", tint = BreezeTeal, modifier = Modifier.size(21.dp))
            VoicePhase.IDLE -> Icon(VoiceMicIcon, "Record a voice prompt", tint = MaterialTheme.colorScheme.onSurface, modifier = Modifier.size(21.dp))
        }
    }
}

@Suppress("DEPRECATION")
private fun createRecorder(context: Context, file: File): MediaRecorder {
    val mediaRecorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) MediaRecorder(context) else MediaRecorder()
    return mediaRecorder.apply {
        setAudioSource(MediaRecorder.AudioSource.MIC)
        setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
        setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
        setAudioEncodingBitRate(96_000)
        setAudioSamplingRate(44_100)
        setOutputFile(file.absolutePath)
    }
}

private suspend fun transcribe(file: File): String {
    if (file.length() > MAX_AUDIO_BYTES) throw IOException("Recording is over the 8 MB limit. Try a shorter clip.")
    val token = BuildConfig.CLOUD_TOKEN.trim()
    if (token.isBlank() || token.any(Char::isWhitespace)) throw IOException("Voice transcription is not configured for this build.")
    val endpoint = transcriptionEndpoint(BuildConfig.CLOUD_URL)
    val connection = (endpoint.openConnection() as HttpsURLConnection).apply {
        requestMethod = "POST"
        doOutput = true
        doInput = true
        useCaches = false
        instanceFollowRedirects = false
        connectTimeout = 15_000
        readTimeout = 90_000
        setRequestProperty("Authorization", "Bearer $token")
        setRequestProperty("Content-Type", "audio/mp4")
        setRequestProperty("Accept", "application/json")
        setRequestProperty("X-Breeze-Client-Id", "breeze-android-development")
        setRequestProperty("X-Breeze-Request-Id", UUID.randomUUID().toString())
        setFixedLengthStreamingMode(file.length())
    }
    try {
        file.inputStream().use { input -> connection.outputStream.use { output ->
            val buffer = ByteArray(16 * 1024)
            var total = 0L
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                total += count
                if (total > MAX_AUDIO_BYTES) throw IOException("Recording is over the 8 MB limit. Try a shorter clip.")
                output.write(buffer, 0, count)
            }
        } }
        val status = connection.responseCode
        if (status !in 200..299) {
            val error = when (status) {
                413 -> "Recording is too large. Try a shorter clip."
                401, 403 -> "Voice transcription is not authorized for this build."
                else -> "Voice transcription failed (HTTP $status). Try again."
            }
            throw IOException(error)
        }
        val declaredLength = connection.getHeaderFieldLong("Content-Length", -1L)
        if (declaredLength > MAX_RESPONSE_BYTES) throw IOException("Cloud returned an unexpectedly large response.")
        val bytes = connection.inputStream.use { input ->
            val out = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(4096)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                if (out.size() + count > MAX_RESPONSE_BYTES) throw IOException("Cloud returned an unexpectedly large response.")
                out.write(buffer, 0, count)
            }
            out.toByteArray()
        }
        val text = runCatching { JSONObject(String(bytes, Charsets.UTF_8)).optString("text") }
            .getOrElse { throw IOException("Cloud returned an invalid transcription response.") }
        return text.trim()
    } finally {
        connection.disconnect()
    }
}

private fun transcriptionEndpoint(chatEndpoint: String): URL {
    val uri = runCatching { URI(chatEndpoint) }.getOrElse { throw IOException("Cloud endpoint is invalid.") }
    if (!uri.scheme.equals("https", ignoreCase = true) || uri.host.isNullOrBlank() || uri.userInfo != null) {
        throw IOException("Cloud endpoint must use HTTPS.")
    }
    val path = uri.path.substringBeforeLast('/') + "/transcriptions"
    return URI("https", null, uri.host, uri.port, path, null, null).toURL()
}

private val VoiceMicIcon: ImageVector by lazy {
    ImageVector.Builder("voice-mic", 24.dp, 24.dp, 24f, 24f).apply {
        addPath(pathData = androidx.compose.ui.graphics.vector.PathParser().parsePathString("M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z").toNodes(), fill = null, stroke = androidx.compose.ui.graphics.SolidColor(Color.Black), strokeLineWidth = 1.8f, strokeLineCap = androidx.compose.ui.graphics.StrokeCap.Round, strokeLineJoin = androidx.compose.ui.graphics.StrokeJoin.Round)
        addPath(pathData = androidx.compose.ui.graphics.vector.PathParser().parsePathString("M19 10v2a7 7 0 0 1-14 0v-2").toNodes(), fill = null, stroke = androidx.compose.ui.graphics.SolidColor(Color.Black), strokeLineWidth = 1.8f, strokeLineCap = androidx.compose.ui.graphics.StrokeCap.Round, strokeLineJoin = androidx.compose.ui.graphics.StrokeJoin.Round)
        addPath(pathData = androidx.compose.ui.graphics.vector.PathParser().parsePathString("M12 19v3").toNodes(), fill = null, stroke = androidx.compose.ui.graphics.SolidColor(Color.Black), strokeLineWidth = 1.8f, strokeLineCap = androidx.compose.ui.graphics.StrokeCap.Round, strokeLineJoin = androidx.compose.ui.graphics.StrokeJoin.Round)
    }.build()
}

private const val MAX_RECORDING_MS = 60_000
private const val SILENCE_TIMEOUT_MS = 3_000L
private const val SILENCE_POLL_MS = 150L
private const val SPEECH_AMPLITUDE_THRESHOLD = 1_000
private const val MAX_AUDIO_BYTES = 8L * 1024L * 1024L
private const val MAX_RESPONSE_BYTES = 256 * 1024
