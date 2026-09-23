package com.froydinger.breeze.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.platform.LocalContext

/** Uses Android's scoped Photo Picker; the selected image stays local until the user sends it. */
@Composable
fun rememberPhotoAttachmentAction(
    onPhoto: (String) -> Unit,
): () -> Unit {
    val context = LocalContext.current
    val currentOnPhoto = rememberUpdatedState(onPhoto)
    val picker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickVisualMedia(),
    ) { uri ->
        if (uri != null) {
            runCatching {
                context.contentResolver.takePersistableUriPermission(
                    uri,
                    android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            }
            currentOnPhoto.value(uri.toString())
        }
    }
    return {
        picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
    }
}
