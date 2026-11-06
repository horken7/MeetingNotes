package com.horken7.meetingnotes

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import com.horken7.meetingnotes.ui.DetailScreen
import com.horken7.meetingnotes.ui.ListScreen
import com.horken7.meetingnotes.ui.SettingsScreen

class MainActivity : ComponentActivity() {
    /** A meeting to open, from a notification. */
    private val openRequest = mutableStateOf<String?>(null)

    private val permissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { granted ->
        if (granted[Manifest.permission.RECORD_AUDIO] == true) MeetingService.record(this)
        else Work.message.value = "Meeting Notes needs the microphone to record. Allow it in the phone's Settings > Apps > Meeting Notes > Permissions."
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        openRequest.value = intent.getStringExtra(MeetingService.EXTRA_OPEN)
        MeetingService.recover(this)
        setContent {
            AppTheme {
                App(openRequest.value, onOpened = { openRequest.value = null }, startRecording = ::startRecording)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        openRequest.value = intent.getStringExtra(MeetingService.EXTRA_OPEN)
    }

    private fun startRecording() {
        val needed = buildList {
            add(Manifest.permission.RECORD_AUDIO)
            if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
        }.filter { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }
        if (needed.isEmpty()) MeetingService.record(this) else permissions.launch(needed.toTypedArray())
    }
}

@Composable
private fun App(openRequest: String?, onOpened: () -> Unit, startRecording: () -> Unit) {
    // "" = the list, "settings", or a meeting id.
    var screen by rememberSaveable { mutableStateOf("") }
    if (openRequest != null) { screen = openRequest; onOpened() }
    val context = LocalContext.current
    val settings = androidx.compose.runtime.remember { Settings(context) }

    BackHandler(enabled = screen.isNotEmpty()) { screen = "" }
    when (screen) {
        "" -> ListScreen(settings, onOpen = { screen = it }, onSettings = { screen = "settings" }, onRecord = startRecording)
        "settings" -> SettingsScreen(settings, onBack = { screen = "" })
        else -> DetailScreen(screen, onBack = { screen = "" })
    }
}

@Composable
private fun AppTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val context = LocalContext.current
    val colors = when {
        Build.VERSION.SDK_INT >= 31 -> if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        dark -> darkColorScheme()
        else -> lightColorScheme()
    }
    MaterialTheme(colorScheme = colors, content = content)
}
