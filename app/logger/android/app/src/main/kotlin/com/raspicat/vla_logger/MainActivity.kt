package com.raspicat.vla_logger

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // ARCore の VIO 姿勢/フレーム取得 (app/logger 独自)。チャネル契約は
        // lib/src/capture/ar_session.dart / iOS の ArPosePlugin.swift と一致させる。
        val controller = ArCoreController(this, flutterEngine.dartExecutor.binaryMessenger)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "com.raspicat.vla_logger/ar/ar_preview",
            ArPreviewFactory(this, controller),
        )
    }
}
