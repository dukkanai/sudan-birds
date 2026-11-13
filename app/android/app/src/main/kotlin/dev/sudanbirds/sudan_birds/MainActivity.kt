package dev.sudanbirds.sudan_birds

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "sudan_birds/auth_restore_fence").setMethodCallHandler { call, result ->
            val project = call.argument<String>("project")
            if (project == null || !project.matches(Regex("[a-zA-Z0-9.-]{1,253}"))) {
                result.error("invalid_project", "Invalid auth scope", null)
                return@setMethodCallHandler
            }
            try {
                // Only a nonsecret restore permission. No token/verifier is stored here.
                // Both cloud and device-transfer backups exclude these preferences.
                val prefs = getSharedPreferences("sudan_birds_auth_fences", MODE_PRIVATE)
                when (call.method) {
                    "read" -> result.success(prefs.all[project] == true)
                    "write" -> {
                        val allowed = call.argument<Boolean>("allowed")
                        if (allowed == null) result.error("invalid_value", "Invalid fence", null)
                        else result.success(prefs.edit().putBoolean(project, allowed).commit())
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                result.error("fence_unavailable", "Auth restore fence unavailable", null)
            }
        }
    }
}
