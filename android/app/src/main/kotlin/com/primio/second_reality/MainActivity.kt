package com.primio.second_reality

import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Channel name, shared with lib/engine/tv.dart. */
private const val CHANNEL = "second_reality/platform"

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Is this a TV? Asked once at startup so the landing screen
                    // can drop its outbound link: Play's TV bar (TV-WB) says a
                    // TV app must not try to launch a browser, and most TVs do
                    // not have one to launch.
                    //
                    // UiModeManager is the same `television` signal the launcher
                    // icon's resource qualifier matches on, rather than a guess
                    // from screen size or the absence of a touchscreen.
                    "isTv" -> {
                        val ui = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
                        result.success(
                            ui.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
                        )
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
