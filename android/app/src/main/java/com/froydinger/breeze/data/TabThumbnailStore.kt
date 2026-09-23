package com.froydinger.breeze.data

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

/** Small, app-private disk cache for non-private tab previews. */
class TabThumbnailStore(context: Context) {
    private val directory = File(context.noBackupFilesDir, "tab-thumbnails-v1")

    fun save(tabId: String, bitmap: Bitmap): Boolean {
        if (!isSafeId(tabId) || bitmap.isRecycled || bitmap.width !in 1..MAX_WIDTH ||
            bitmap.height !in 1..MAX_HEIGHT || bitmap.width.toLong() * bitmap.height > MAX_PIXELS
        ) return false
        val target = File(directory, "$tabId.jpg")
        val temporary = File(directory, "$tabId-${UUID.randomUUID()}.tmp")
        return try {
            if (!directory.exists() && !directory.mkdirs()) return false
            FileOutputStream(temporary).use { output ->
                if (!bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, output)) return false
                output.flush()
                output.fd.sync()
            }
            if (temporary.length() <= 0L || temporary.length() > MAX_FILE_BYTES) return false
            try {
                Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            } catch (_: Exception) {
                Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }
            true
        } catch (_: Exception) {
            false
        } finally {
            temporary.delete()
        }
    }

    fun load(tabId: String): Bitmap? {
        if (!isSafeId(tabId)) return null
        val file = File(directory, "$tabId.jpg")
        if (!file.isFile || file.length() !in 1..MAX_FILE_BYTES) return null
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.absolutePath, bounds)
            if (bounds.outWidth !in 1..MAX_WIDTH || bounds.outHeight !in 1..MAX_HEIGHT ||
                bounds.outWidth.toLong() * bounds.outHeight > MAX_PIXELS
            ) return null
            BitmapFactory.decodeFile(file.absolutePath)
        } catch (_: Exception) {
            null
        }
    }

    fun delete(tabId: String) {
        if (isSafeId(tabId)) File(directory, "$tabId.jpg").delete()
    }

    fun clear() {
        directory.listFiles()?.forEach { it.delete() }
        directory.delete()
    }

    /** Drop previews for closed/private tabs and temporary files left by interruption. */
    fun retain(tabIds: Set<String>) {
        directory.listFiles()?.forEach { file ->
            val id = file.name.takeIf { it.endsWith(".jpg") }?.removeSuffix(".jpg")
            if (id == null || !isSafeId(id) || id !in tabIds) file.delete()
        }
    }

    private fun isSafeId(value: String): Boolean = UUID_PATTERN.matches(value)

    companion object {
        private const val JPEG_QUALITY = 78
        private const val MAX_FILE_BYTES = 2L * 1024L * 1024L
        private const val MAX_WIDTH = 720
        private const val MAX_HEIGHT = 4096
        private const val MAX_PIXELS = 2_000_000L
        private val UUID_PATTERN = Regex("(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
    }
}
