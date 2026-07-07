package com.raspicat.vla_logger

import android.app.Activity
import android.content.Context
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.media.Image
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.util.Log
import android.view.View
import com.google.ar.core.ArCoreApk
import com.google.ar.core.Config
import com.google.ar.core.Coordinates2d
import com.google.ar.core.Frame
import com.google.ar.core.Session
import com.google.ar.core.exceptions.NotYetAvailableException
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

/** ネイティブ ARCore プレビュー PlatformView を生成するファクトリ。 */
class ArPreviewFactory(
    private val activity: Activity,
    private val controller: ArCoreController,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        ArCoreView(activity, controller)
}

/**
 * GLSurfaceView 上で ARCore セッションを回し、カメラ映像を背景描画(プレビュー)しつつ、
 * 毎フレーム姿勢と(間引いた)カメラ画像を [ArCoreController] の sink へ流す PlatformView。
 *
 * ARCore は GL コンテキスト + 毎フレーム `session.update()` を前提とするため、CPU 画像
 * 取得(`acquireCameraImage`)を使う場合でも GL スレッド自体は必須。JPEG エンコードは
 * ここ(端末側)で行う。座標規約の正規化はせず、world 位置(m)+クォータニオンを生で流す。
 */
class ArCoreView(
    private val activity: Activity,
    private val controller: ArCoreController,
) : PlatformView, GLSurfaceView.Renderer {

    private val glView = GLSurfaceView(activity)
    private val bg = BackgroundRenderer()

    private var session: Session? = null
    private var installRequested = false
    private var lastPoseNs = 0L
    private var lastFrameNs = 0L

    init {
        glView.preserveEGLContextOnPause = true
        glView.setEGLContextClientVersion(2)
        glView.setEGLConfigChooser(8, 8, 8, 8, 16, 0)
        glView.setRenderer(this)
        glView.renderMode = GLSurfaceView.RENDERMODE_CONTINUOUSLY
        tryCreateSession()
    }

    override fun getView(): View = glView

    override fun dispose() {
        session?.close()
        session = null
    }

    /** UI スレッドで ARCore の可用性確認・(必要なら)インストール要求・セッション生成を行う。 */
    private fun tryCreateSession() {
        try {
            when (ArCoreApk.getInstance().requestInstall(activity, !installRequested)) {
                ArCoreApk.InstallStatus.INSTALL_REQUESTED -> {
                    installRequested = true
                    return // インストール後にアクティビティ再開で再試行される。
                }
                ArCoreApk.InstallStatus.INSTALLED -> {}
            }
            val s = Session(activity)
            val cfg = Config(s)
            cfg.focusMode = Config.FocusMode.AUTO
            cfg.updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE
            s.configure(cfg)
            s.resume()
            session = s
        } catch (e: Exception) {
            Log.e(TAG, "ARCore セッション生成に失敗: $e")
        }
    }

    // MARK: - GLSurfaceView.Renderer

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        bg.createOnGlThread()
    }

    override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
        GLES20.glViewport(0, 0, width, height)
        @Suppress("DEPRECATION")
        val rotation = activity.windowManager.defaultDisplay.rotation
        session?.setDisplayGeometry(rotation, width, height)
    }

    override fun onDrawFrame(gl: GL10?) {
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT or GLES20.GL_DEPTH_BUFFER_BIT)
        val s = session ?: return
        try {
            s.setCameraTextureName(bg.textureId)
            val frame = s.update()
            bg.draw(frame) // カメラ映像を全画面に描画 (プレビュー)。
            val nowNs = frame.timestamp

            if (controller.poseSink != null && nowNs - lastPoseNs >= 1e9 / controller.poseHz) {
                lastPoseNs = nowNs
                emitPose(frame)
            }
            if (controller.frameSink != null && nowNs - lastFrameNs >= 1e9 / controller.cameraHz) {
                lastFrameNs = nowNs
                emitFrame(frame)
            }
        } catch (e: Exception) {
            Log.e(TAG, "onDrawFrame: $e")
        }
    }

    private fun emitPose(frame: Frame) {
        val cam = frame.camera
        val p = cam.pose
        val state = cam.trackingState.name // TRACKING / PAUSED / STOPPED
        val map = hashMapOf<String, Any>(
            "tx" to p.tx().toDouble(), "ty" to p.ty().toDouble(), "tz" to p.tz().toDouble(),
            "qx" to p.qx().toDouble(), "qy" to p.qy().toDouble(),
            "qz" to p.qz().toDouble(), "qw" to p.qw().toDouble(),
            "tracking_state" to state,
        )
        controller.mainHandler.post { controller.poseSink?.success(map) }
    }

    private fun emitFrame(frame: Frame) {
        val image = try {
            frame.acquireCameraImage()
        } catch (e: NotYetAvailableException) {
            return
        }
        try {
            val w = image.width
            val h = image.height
            val jpeg = yuv420ToJpeg(image, controller.jpegQuality)
            val map = hashMapOf<String, Any>("jpeg" to jpeg, "width" to w, "height" to h)
            controller.mainHandler.post { controller.frameSink?.success(map) }
        } finally {
            image.close()
        }
    }

    companion object {
        private const val TAG = "ArCoreView"

        /** YUV_420_888 の [Image] を NV21 経由で JPEG バイト列にする。 */
        private fun yuv420ToJpeg(image: Image, quality: Int): ByteArray {
            val w = image.width
            val h = image.height
            val ySize = w * h
            val nv21 = ByteArray(ySize + ySize / 2)

            val yPlane = image.planes[0]
            val uPlane = image.planes[1]
            val vPlane = image.planes[2]

            val yBuf = yPlane.buffer
            val yRow = yPlane.rowStride
            val yPix = yPlane.pixelStride
            var pos = 0
            if (yPix == 1 && yRow == w) {
                yBuf.get(nv21, 0, ySize)
                pos = ySize
            } else {
                for (row in 0 until h) {
                    val base = row * yRow
                    for (col in 0 until w) nv21[pos++] = yBuf.get(base + col * yPix)
                }
            }

            // NV21 は Y の後に VU インターリーブ。クロマは半解像度。
            val uBuf = uPlane.buffer
            val vBuf = vPlane.buffer
            val uRow = uPlane.rowStride
            val uPix = uPlane.pixelStride
            val vRow = vPlane.rowStride
            val vPix = vPlane.pixelStride
            val cw = w / 2
            val ch = h / 2
            for (row in 0 until ch) {
                val uBase = row * uRow
                val vBase = row * vRow
                for (col in 0 until cw) {
                    nv21[pos++] = vBuf.get(vBase + col * vPix)
                    nv21[pos++] = uBuf.get(uBase + col * uPix)
                }
            }

            val out = ByteArrayOutputStream()
            YuvImage(nv21, ImageFormat.NV21, w, h, null)
                .compressToJpeg(Rect(0, 0, w, h), quality, out)
            return out.toByteArray()
        }
    }
}

/**
 * ARCore のカメラ映像 (OES テクスチャ) を全画面クアッドに描画する最小レンダラ。
 * HelloAR サンプルの BackgroundRenderer 相当を Kotlin で自己完結させたもの。
 */
class BackgroundRenderer {
    var textureId = -1
        private set

    private var program = 0
    private var aPosition = 0
    private var aTexCoord = 0

    private val quadCoords: FloatBuffer = allocFloat(
        // TRIANGLE_STRIP 用の全画面 NDC クアッド。
        floatArrayOf(-1f, -1f, +1f, -1f, -1f, +1f, +1f, +1f),
    )
    private val quadTexCoords: FloatBuffer = allocFloat(FloatArray(8))

    fun createOnGlThread() {
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        textureId = textures[0]
        val target = GLES11Ext.GL_TEXTURE_EXTERNAL_OES
        GLES20.glBindTexture(target, textureId)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)

        val vs = compile(GLES20.GL_VERTEX_SHADER, VERTEX_SHADER)
        val fs = compile(GLES20.GL_FRAGMENT_SHADER, FRAGMENT_SHADER)
        program = GLES20.glCreateProgram()
        GLES20.glAttachShader(program, vs)
        GLES20.glAttachShader(program, fs)
        GLES20.glLinkProgram(program)
        aPosition = GLES20.glGetAttribLocation(program, "a_Position")
        aTexCoord = GLES20.glGetAttribLocation(program, "a_TexCoord")
    }

    fun draw(frame: Frame) {
        if (frame.hasDisplayGeometryChanged()) {
            frame.transformCoordinates2d(
                Coordinates2d.OPENGL_NORMALIZED_DEVICE_COORDINATES, quadCoords,
                Coordinates2d.TEXTURE_NORMALIZED, quadTexCoords,
            )
        }
        if (textureId == -1) return

        GLES20.glDisable(GLES20.GL_DEPTH_TEST)
        GLES20.glDepthMask(false)
        GLES20.glUseProgram(program)

        quadCoords.position(0)
        GLES20.glVertexAttribPointer(aPosition, 2, GLES20.GL_FLOAT, false, 0, quadCoords)
        GLES20.glEnableVertexAttribArray(aPosition)
        quadTexCoords.position(0)
        GLES20.glVertexAttribPointer(aTexCoord, 2, GLES20.GL_FLOAT, false, 0, quadTexCoords)
        GLES20.glEnableVertexAttribArray(aTexCoord)

        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        GLES20.glDisableVertexAttribArray(aPosition)
        GLES20.glDisableVertexAttribArray(aTexCoord)
        GLES20.glDepthMask(true)
        GLES20.glEnable(GLES20.GL_DEPTH_TEST)
    }

    private fun compile(type: Int, src: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, src)
        GLES20.glCompileShader(shader)
        return shader
    }

    companion object {
        private fun allocFloat(values: FloatArray): FloatBuffer {
            val buf = ByteBuffer.allocateDirect(values.size * 4)
                .order(ByteOrder.nativeOrder()).asFloatBuffer()
            buf.put(values).position(0)
            return buf
        }

        private const val VERTEX_SHADER = """
            attribute vec4 a_Position;
            attribute vec2 a_TexCoord;
            varying vec2 v_TexCoord;
            void main() {
              gl_Position = a_Position;
              v_TexCoord = a_TexCoord;
            }
        """

        private const val FRAGMENT_SHADER = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 v_TexCoord;
            uniform samplerExternalOES sTexture;
            void main() {
              gl_FragColor = texture2D(sTexture, v_TexCoord);
            }
        """
    }
}
