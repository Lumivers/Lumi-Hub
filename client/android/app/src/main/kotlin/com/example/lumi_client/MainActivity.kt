package com.example.lumi_client

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "lumi_hub/unity_launcher"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method != "launchUnityApp") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }

                val packageName = call.argument<String>("packageName")?.trim().orEmpty()
                val activityName = call.argument<String>("activityName")?.trim().orEmpty()
                @Suppress("UNCHECKED_CAST")
                val extras = call.argument<Map<String, Any>>("extras")

                if (packageName.isEmpty()) {
                    result.error("invalid_args", "Android 包名为空。", null)
                    return@setMethodCallHandler
                }

                val intent = if (activityName.isNotEmpty()) {
                    Intent().setClassName(packageName, activityName)
                } else {
                    packageManager.getLaunchIntentForPackage(packageName)
                }

                if (intent == null) {
                    result.error("not_found", "未找到 Unity 应用: $packageName", null)
                    return@setMethodCallHandler
                }

                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                extras?.forEach { (key, value) ->
                    intent.putExtra(key, value.toString())
                }

                try {
                    startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("launch_failed", "启动 Unity 失败: ${e.message}", null)
                }
            }
    }
}
