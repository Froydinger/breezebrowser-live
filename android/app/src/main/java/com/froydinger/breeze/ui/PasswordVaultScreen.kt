package com.froydinger.breeze.ui

import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.os.SystemClock
import android.view.WindowManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.fragment.app.FragmentActivity
import com.froydinger.breeze.data.CredentialVault
import com.froydinger.breeze.data.CredentialVaultAuthentication
import com.froydinger.breeze.data.BrowserImport
import com.froydinger.breeze.data.VaultCredential
import java.util.UUID

@Composable
fun PasswordVaultScreen() {
    val context = LocalContext.current
    val activity = context.findFragmentActivity()
    val vault = remember(context) { CredentialVault(context) }
    val credentials = remember { mutableStateListOf<VaultCredential>() }
    val revealed = remember { mutableStateMapOf<String, Boolean>() }
    var origin by remember { mutableStateOf("") }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var unlocked by remember { mutableStateOf(false) }
    var pending by remember { mutableStateOf<(() -> Unit)?>(null) }
    var loading by remember { mutableStateOf(false) }
    var authInProgress by remember { mutableStateOf(false) }
    var lastInteraction by remember { mutableStateOf(SystemClock.elapsedRealtime()) }

    fun lockVault() {
        revealed.clear()
        credentials.clear()
        unlocked = false
        origin = ""
        username = ""
        password = ""
        pending = null
    }

    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(activity, lifecycleOwner) {
        val window = activity?.window
        val wasSecure = window?.attributes?.flags?.and(WindowManager.LayoutParams.FLAG_SECURE) != 0
        window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP && !authInProgress) lockVault()
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            lockVault()
            window?.let {
                if (wasSecure) it.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                else it.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            }
        }
    }

    val keyguardLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        loading = false
        authInProgress = false
        if (result.resultCode == android.app.Activity.RESULT_OK) {
            runCatching {
                val rows = vault.readAfterAuthentication()
                credentials.clear(); credentials.addAll(rows)
                unlocked = true
                lastInteraction = SystemClock.elapsedRealtime()
                pending?.invoke()
            }.onFailure { error = it.message ?: "Vault could not be opened." }
        } else {
            error = "Device authentication was cancelled."
        }
        pending = null
    }

    fun authenticate(onSuccess: () -> Unit) {
        val host = activity
        if (host == null) {
            error = "Password vault requires the app's secure activity."
            return
        }
        loading = true
        authInProgress = true
        CredentialVaultAuthentication.authenticate(
            activity = host,
            onAuthenticated = {
                loading = false
                authInProgress = false
                try {
                    val rows = vault.readAfterAuthentication()
                    credentials.clear(); credentials.addAll(rows)
                    unlocked = true
                    lastInteraction = SystemClock.elapsedRealtime()
                    error = null
                    onSuccess()
                } catch (e: Exception) {
                    error = e.message ?: "Vault could not be opened."
                }
            },
            onDeviceCredentialRequired = { intent: Intent ->
                pending = onSuccess
                try {
                    keyguardLauncher.launch(intent)
                } catch (_: RuntimeException) {
                    pending = null
                    loading = false
                    authInProgress = false
                    error = "Device authentication could not start."
                }
            },
            onError = { message -> loading = false; authInProgress = false; error = message },
        )
    }

    val passwordImporter = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            runCatching { readImportText(context, uri) }
                .mapCatching { BrowserImport.passwordsCsv(it) }
                .onSuccess { imported ->
                    if (imported.isEmpty()) {
                        error = "No logins found. Choose a browser password CSV export."
                    } else {
                        authenticate {
                            val next = credentials.toMutableList()
                            var added = 0
                            imported.forEach { entry ->
                                val origin = runCatching { vault.normalizeOrigin(entry.url) }.getOrNull() ?: return@forEach
                                if (next.none { it.origin == origin && it.username == entry.username }) {
                                    next.add(VaultCredential(UUID.randomUUID().toString(), origin, entry.username, entry.password))
                                    added++
                                }
                            }
                            runCatching { vault.writeAfterAuthentication(next) }
                                .onSuccess { credentials.clear(); credentials.addAll(next); lastInteraction = SystemClock.elapsedRealtime(); error = "Imported $added logins." }
                                .onFailure { error = it.message ?: "Logins could not be imported." }
                        }
                    }
                }
                .onFailure { error = it.message ?: "Password file could not be read." }
        }
    }

    androidx.compose.runtime.LaunchedEffect(unlocked, lastInteraction) {
        if (unlocked) {
            kotlinx.coroutines.delay(60_000)
            if (SystemClock.elapsedRealtime() - lastInteraction >= 60_000) lockVault()
        }
    }

    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 14.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        SectionTitle("Passwords")
        GlassCard(Modifier.fillMaxWidth()) {
            Text("Local password vault", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text("For website logins, choose Unlock saved passwords from page tools on a regular HTTPS page. Gecko receives entries for that exact origin for up to 30 seconds; website save prompts require authentication.", style = MaterialTheme.typography.bodySmall)
            if (!unlocked) {
                Button(onClick = { authenticate { } }, enabled = !loading) { Text(if (loading) "Waiting for authentication…" else "Unlock vault") }
            } else {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Vault unlocked", Modifier.weight(1f), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
                    androidx.compose.material3.TextButton(onClick = { lockVault() }) { Text("Lock") }
                }
            }
        }
        GlassCard(Modifier.fillMaxWidth()) {
            Text("Import from another browser", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text("Choose a CSV password export. Imported logins are saved only in this device’s encrypted vault after authentication. Delete the unencrypted CSV when you’re done.", style = MaterialTheme.typography.bodySmall)
            Button(onClick = { passwordImporter.launch(arrayOf("text/csv", "text/comma-separated-values", "application/octet-stream", "text/plain")) }, enabled = !loading) { Text("Import passwords") }
        }
        if (unlocked) {
            GlassCard(Modifier.fillMaxWidth()) {
                Text("Add a login", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                OutlinedTextField(value = origin, onValueChange = { if (it.length <= 2048) { origin = it; lastInteraction = SystemClock.elapsedRealtime() } }, label = { Text("Website URL") }, placeholder = { Text("https://example.com") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(value = username, onValueChange = { if (it.length <= 1024) { username = it; lastInteraction = SystemClock.elapsedRealtime() } }, label = { Text("Username") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(value = password, onValueChange = { if (it.length <= 4096) { password = it; lastInteraction = SystemClock.elapsedRealtime() } }, label = { Text("Password") }, singleLine = true, visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth())
                Button(onClick = {
                    val normalized = runCatching { vault.normalizeOrigin(origin) }.getOrElse {
                        error = it.message
                        return@Button
                    }
                    if (username.isBlank() || password.isEmpty()) {
                        error = "Enter both a username and password."
                        return@Button
                    }
                    val candidate = VaultCredential(UUID.randomUUID().toString(), normalized, username.trim(), password)
                    authenticate {
                        val next = credentials.toList() + candidate
                        runCatching { vault.writeAfterAuthentication(next) }
                            .onSuccess {
                                credentials.clear(); credentials.addAll(next)
                                origin = ""; username = ""; password = ""; error = null
                            }
                            .onFailure { error = it.message ?: "Credential could not be saved." }
                    }
                }, enabled = !loading) { Text("Save login") }
            }
            Text("Saved logins", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            if (credentials.isEmpty()) {
                GlassCard(Modifier.fillMaxWidth()) { Text("No logins saved yet.", style = MaterialTheme.typography.bodyMedium) }
            } else credentials.forEach { credential ->
                GlassCard(Modifier.fillMaxWidth()) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(credential.origin, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                            Text(credential.username, style = MaterialTheme.typography.bodySmall)
                        }
                        IconButton(onClick = {
                            lastInteraction = SystemClock.elapsedRealtime()
                            if (revealed[credential.id] == true) revealed[credential.id] = false
                            else authenticate { revealed[credential.id] = true }
                        }, enabled = !loading) {
                            Icon(if (revealed[credential.id] == true) BreezeIcons.VisibilityOff else BreezeIcons.Visibility, contentDescription = if (revealed[credential.id] == true) "Hide password" else "Reveal password after authentication")
                        }
                        IconButton(onClick = {
                            lastInteraction = SystemClock.elapsedRealtime()
                            authenticate {
                                val next = credentials.filterNot { it.id == credential.id }
                                runCatching { vault.writeAfterAuthentication(next) }
                                    .onSuccess { credentials.clear(); credentials.addAll(next); revealed.remove(credential.id); error = null }
                                    .onFailure { error = it.message ?: "Credential could not be deleted." }
                            }
                        }, enabled = !loading) {
                            Icon(BreezeIcons.Delete, contentDescription = "Delete login")
                        }
                    }
                    Text(if (revealed[credential.id] == true) credential.password else "••••••••••••", style = MaterialTheme.typography.bodyMedium)
                }
            }
        }
        if (error != null) Text(error!!, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
        Spacer(Modifier.height(8.dp))
    }
}

private fun Context.findFragmentActivity(): FragmentActivity? {
    var current: Context = this
    while (current is ContextWrapper) {
        if (current is FragmentActivity) return current
        current = current.baseContext
    }
    return current as? FragmentActivity
}

private fun readImportText(context: Context, uri: android.net.Uri): String {
    val limit = 8 * 1024 * 1024
    val input = context.contentResolver.openInputStream(uri) ?: error("File could not be opened.")
    val output = java.io.ByteArrayOutputStream()
    input.use { stream ->
        val buffer = ByteArray(8192)
        while (true) {
            val count = stream.read(buffer)
            if (count < 0) break
            require(output.size() + count <= limit) { "File is too large to import." }
            output.write(buffer, 0, count)
        }
    }
    require(output.size() > 0) { "File is empty." }
    return output.toString(Charsets.UTF_8.name())
}
