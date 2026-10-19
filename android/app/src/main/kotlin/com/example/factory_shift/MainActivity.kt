package com.example.factory_shift

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channel = "factory_shift/dnd"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                when (call.method) {
                    "hasPermission" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            result.success(nm.isNotificationPolicyAccessGranted)
                        } else result.success(false)
                    }
                    "openSettings" -> {
                        val intent = Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)
                        startActivity(intent)
                        result.success(true)
                    }
                    "setDnd" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            if (!nm.isNotificationPolicyAccessGranted) {
                                result.error("NO_PERM", "缺少勿扰权限", null)
                            } else {
                                val on = call.argument<Boolean>("on") ?: false
                                nm.setInterruptionFilter(
                                    if (on)
                                        NotificationManager.INTERRUPTION_FILTER_PRIORITY
                                    else
                                        NotificationManager.INTERRUPTION_FILTER_ALL
                                )
                                result.success(true)
                            }
                        } else result.error("UNSUPPORTED", "系统版本过低", null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
