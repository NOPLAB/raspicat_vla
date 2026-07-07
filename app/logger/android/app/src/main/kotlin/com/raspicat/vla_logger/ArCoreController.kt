package com.raspicat.vla_logger

import android.app.Activity
import android.os.Handler
import android.os.Looper
import com.google.ar.core.ArCoreApk
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * ARCore の制御 (MethodChannel) と姿勢/フレームの EventChannel を束ねる。
 *
 * AR は背面カメラを占有するため、logger はフレームも姿勢も ARCore から取る。
 * 実際の GL レンダリング/セッション更新は [ArCoreView] が行い、ここは sink と設定を
 * 保持するだけ。EventChannel にリスナが付いている間だけ [ArCoreView] が間引いて流す。
 * 時刻打ちは Dart 側 (共有 MonoClock) が受信時に行うので、ここでは時刻を送らない。
 */
class ArCoreController(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    @Volatile var poseSink: EventChannel.EventSink? = null
    @Volatile var frameSink: EventChannel.EventSink? = null

    @Volatile var cameraHz: Double = 4.0
    @Volatile var poseHz: Double = 30.0
    @Volatile var jpegQuality: Int = 85

    val mainHandler = Handler(Looper.getMainLooper())

    init {
        MethodChannel(messenger, "$PREFIX/ar_control").setMethodCallHandler(this)
        EventChannel(messenger, "$PREFIX/ar_pose").setStreamHandler(sinkHandler { poseSink = it })
        EventChannel(messenger, "$PREFIX/ar_frame").setStreamHandler(sinkHandler { frameSink = it })
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSupported" -> {
                // 端末が ARCore に対応しているか。未インストール(要 Play Services for AR)や
                // チェック中(UNKNOWN_*)は「対応」扱いとし、実インストールは View 側で要求する。
                val avail = ArCoreApk.getInstance().checkAvailability(activity)
                result.success(avail != ArCoreApk.Availability.UNSUPPORTED_DEVICE_NOT_CAPABLE)
            }
            "start" -> {
                (call.argument<Double>("cameraHz"))?.let { cameraHz = it }
                (call.argument<Double>("poseHz"))?.let { poseHz = it }
                (call.argument<Int>("jpegQuality"))?.let { jpegQuality = it }
                result.success(null)
            }
            "stop" -> result.success(null)
            else -> result.notImplemented()
        }
    }

    private fun sinkHandler(assign: (EventChannel.EventSink?) -> Unit) =
        object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) = assign(events)
            override fun onCancel(arguments: Any?) = assign(null)
        }

    companion object {
        const val PREFIX = "com.raspicat.vla_logger/ar"
    }
}
