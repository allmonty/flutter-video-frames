package com.allmonty.video_frames

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLExt
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * An EGL context that draws one textured quad, so the GPU does the YUV/RGB
 * conversion, rotation and scaling:
 *
 * - [forDecoding]: the decoder renders into [surface]; [readFrame] draws its
 *   latest frame upright into an offscreen framebuffer and reads it back as RGBA.
 *   The external-texture sampler converts with the stream's own color space.
 * - [forEncoding]: [writeFrame] uploads RGBA and draws it into the encoder's
 *   input surface; the encoder converts to YUV.
 *
 * A context is current on one thread at a time and Pigeon's serial queue may
 * switch threads, so every GL call goes through [use].
 */
class GlRenderer private constructor(window: Surface?, private val width: Int, private val height: Int) {
    private val decoding = window == null
    private val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
    private val context: android.opengl.EGLContext
    private val eglSurface: android.opengl.EGLSurface
    private val target = if (decoding) GLES11Ext.GL_TEXTURE_EXTERNAL_OES else GLES20.GL_TEXTURE_2D
    private var program = 0
    private var texture = 0
    private var framebuffer = 0
    private val texMatrix = FloatArray(16).also { android.opengl.Matrix.setIdentityM(it, 0) }
    private val quad = ByteBuffer.allocateDirect(16 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()

    private var surfaceTexture: SurfaceTexture? = null
    private val frameLock = Object()
    private var frameReady = false

    /** The decoder's output surface ([forDecoding] only). */
    var surface: Surface? = null
        private set

    init {
        val version = IntArray(2)
        check(EGL14.eglInitialize(display, version, 0, version, 1)) { "eglInitialize failed" }
        val attribs = intArrayOf(
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, if (decoding) EGL14.EGL_PBUFFER_BIT else EGL14.EGL_WINDOW_BIT,
            *(if (decoding) intArrayOf() else intArrayOf(EGL_RECORDABLE_ANDROID, 1)),
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<android.opengl.EGLConfig>(1)
        val count = IntArray(1)
        check(EGL14.eglChooseConfig(display, attribs, 0, configs, 0, 1, count, 0) && count[0] > 0) { "no EGL config" }
        context = EGL14.eglCreateContext(
            display, configs[0], EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0,
        )
        check(context != EGL14.EGL_NO_CONTEXT) { "eglCreateContext failed" }
        eglSurface = if (decoding) {
            // Drawing goes to a framebuffer; the pbuffer only lets the context be current.
            EGL14.eglCreatePbufferSurface(display, configs[0], intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0)
        } else {
            EGL14.eglCreateWindowSurface(display, configs[0], window, intArrayOf(EGL14.EGL_NONE), 0)
        }
        try {
            check(eglSurface != EGL14.EGL_NO_SURFACE) { "eglCreateSurface failed: 0x${Integer.toHexString(EGL14.eglGetError())}" }
            use { setUp() }
        } catch (e: Exception) {
            release()
            throw e
        }
    }

    private fun setUp() {
        program = buildProgram(VERTEX_SHADER, if (decoding) FRAGMENT_EXTERNAL else FRAGMENT_2D)
        texture = genTexture(target)
        if (decoding) {
            val st = SurfaceTexture(texture)
            st.setOnFrameAvailableListener({
                synchronized(frameLock) {
                    frameReady = true
                    frameLock.notifyAll()
                }
            }, callbackHandler)
            surfaceTexture = st
            surface = Surface(st)
            val output = genTexture(GLES20.GL_TEXTURE_2D)
            GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, width, height, 0, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null)
            val ids = IntArray(1)
            GLES20.glGenFramebuffers(1, ids, 0)
            framebuffer = ids[0]
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, framebuffer)
            GLES20.glFramebufferTexture2D(GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0, GLES20.GL_TEXTURE_2D, output, 0)
            val status = GLES20.glCheckFramebufferStatus(GLES20.GL_FRAMEBUFFER)
            check(status == GLES20.GL_FRAMEBUFFER_COMPLETE) { "framebuffer incomplete: 0x${Integer.toHexString(status)}" }
        } else {
            GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, width, height, 0, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null)
        }
        checkGl("setup")
    }

    /** Run `block` with this context current on the calling thread. */
    fun <T> use(block: GlRenderer.() -> T): T {
        check(EGL14.eglMakeCurrent(display, eglSurface, eglSurface, context)) {
            "eglMakeCurrent failed: 0x${Integer.toHexString(EGL14.eglGetError())}"
        }
        try {
            return block()
        } finally {
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
        }
    }

    /**
     * Wait for the frame the decoder just rendered, draw it rotated clockwise
     * by `rotation` and scaled to `width x height`, and read it into `out`
     * (RGBA, top row first).
     */
    fun readFrame(rotation: Int, out: ByteBuffer) {
        awaitFrame()
        val st = surfaceTexture!!
        st.updateTexImage()
        st.getTransformMatrix(texMatrix)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, framebuffer)
        draw(decodeQuad(rotation))
        out.clear()
        GLES20.glReadPixels(0, 0, width, height, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, out)
        checkGl("readPixels")
    }

    /** Draw an RGBA frame (`width x height`, top row first) to the encoder at `ptsUs`. */
    fun writeFrame(rgba: ByteArray, ptsUs: Long) {
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texture)
        GLES20.glTexSubImage2D(GLES20.GL_TEXTURE_2D, 0, 0, 0, width, height, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, ByteBuffer.wrap(rgba))
        draw(ENCODE_QUAD)
        EGLExt.eglPresentationTimeANDROID(display, eglSurface, ptsUs * 1000)
        check(EGL14.eglSwapBuffers(display, eglSurface)) { "eglSwapBuffers failed: 0x${Integer.toHexString(EGL14.eglGetError())}" }
    }

    fun release() {
        try {
            use { surfaceTexture?.release() }
        } catch (_: Exception) {
            // The context is going away anyway.
        }
        surface?.release()
        EGL14.eglDestroySurface(display, eglSurface)
        EGL14.eglDestroyContext(display, context)
    }

    private fun awaitFrame() {
        val deadline = System.nanoTime() + FRAME_TIMEOUT_MS * 1_000_000
        synchronized(frameLock) {
            while (!frameReady) {
                val left = (deadline - System.nanoTime()) / 1_000_000
                if (left <= 0) throw IllegalStateException("video decoder stalled")
                frameLock.wait(left)
            }
            frameReady = false
        }
    }

    private fun draw(vertices: FloatArray) {
        GLES20.glViewport(0, 0, width, height)
        GLES20.glUseProgram(program)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(target, texture)
        GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(program, "uTexMatrix"), 1, false, texMatrix, 0)
        quad.clear()
        quad.put(vertices)
        val pos = GLES20.glGetAttribLocation(program, "aPos")
        val uv = GLES20.glGetAttribLocation(program, "aUv")
        quad.position(0)
        GLES20.glVertexAttribPointer(pos, 2, GLES20.GL_FLOAT, false, 16, quad)
        GLES20.glEnableVertexAttribArray(pos)
        quad.position(2)
        GLES20.glVertexAttribPointer(uv, 2, GLES20.GL_FLOAT, false, 16, quad)
        GLES20.glEnableVertexAttribArray(uv)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        checkGl("draw")
    }

    private fun genTexture(target: Int): Int {
        val ids = IntArray(1)
        GLES20.glGenTextures(1, ids, 0)
        GLES20.glBindTexture(target, ids[0])
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_NEAREST)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_NEAREST)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        return ids[0]
    }

    private fun buildProgram(vertex: String, fragment: String): Int {
        val program = GLES20.glCreateProgram()
        for ((type, source) in listOf(GLES20.GL_VERTEX_SHADER to vertex, GLES20.GL_FRAGMENT_SHADER to fragment)) {
            val shader = GLES20.glCreateShader(type)
            GLES20.glShaderSource(shader, source)
            GLES20.glCompileShader(shader)
            val ok = IntArray(1)
            GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, ok, 0)
            check(ok[0] != 0) { "shader compile failed: ${GLES20.glGetShaderInfoLog(shader)}" }
            GLES20.glAttachShader(program, shader)
            GLES20.glDeleteShader(shader)
        }
        GLES20.glLinkProgram(program)
        val ok = IntArray(1)
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, ok, 0)
        check(ok[0] != 0) { "shader link failed: ${GLES20.glGetProgramInfoLog(program)}" }
        return program
    }

    private fun checkGl(op: String) {
        val error = GLES20.glGetError()
        check(error == GLES20.GL_NO_ERROR) { "$op: GL error 0x${Integer.toHexString(error)}" }
    }

    companion object {
        private const val EGL_RECORDABLE_ANDROID = 0x3142
        private const val FRAME_TIMEOUT_MS = 5_000L

        /** Frame-available callbacks need a Looper; Pigeon's queue threads have none. */
        private val callbackHandler by lazy { Handler(HandlerThread("video_frames").apply { start() }.looper) }

        fun forDecoding(width: Int, height: Int) = GlRenderer(null, width, height)

        fun forEncoding(input: Surface, width: Int, height: Int) = GlRenderer(input, width, height)

        /**
         * Triangle-strip corners (x, y in clip space; u, v in texture space,
         * v up) that draw a frame rotated clockwise by `rotation` so that
         * glReadPixels (bottom row first) returns the top row first.
         */
        fun decodeQuad(rotation: Int): FloatArray {
            val out = FloatArray(16)
            // Output corners as (x, yTop), both 0..1 from the top-left.
            val corners = arrayOf(0f to 0f, 1f to 0f, 0f to 1f, 1f to 1f)
            for ((i, corner) in corners.withIndex()) {
                val (x, y) = corner
                val (u, v) = when (rotation) {
                    90 -> y to x
                    180 -> 1 - x to y
                    270 -> 1 - y to 1 - x
                    else -> x to 1 - y
                }
                out[i * 4] = 2 * x - 1
                out[i * 4 + 1] = 2 * y - 1
                out[i * 4 + 2] = u
                out[i * 4 + 3] = v
            }
            return out
        }

        /** Texture row 0 (the top of the RGBA frame) at the top of the encoder's surface. */
        private val ENCODE_QUAD = floatArrayOf(
            -1f, 1f, 0f, 0f,
            1f, 1f, 1f, 0f,
            -1f, -1f, 0f, 1f,
            1f, -1f, 1f, 1f,
        )

        private const val VERTEX_SHADER = """
            attribute vec2 aPos;
            attribute vec2 aUv;
            uniform mat4 uTexMatrix;
            varying highp vec2 vUv;
            void main() {
                gl_Position = vec4(aPos, 0.0, 1.0);
                vUv = (uTexMatrix * vec4(aUv, 0.0, 1.0)).xy;
            }
        """

        private const val FRAGMENT_EXTERNAL = """
            #extension GL_OES_EGL_image_external : require
            precision highp float;
            varying highp vec2 vUv;
            uniform samplerExternalOES uTex;
            void main() { gl_FragColor = vec4(texture2D(uTex, vUv).rgb, 1.0); }
        """

        private const val FRAGMENT_2D = """
            precision highp float;
            varying highp vec2 vUv;
            uniform sampler2D uTex;
            void main() { gl_FragColor = texture2D(uTex, vUv); }
        """
    }
}
