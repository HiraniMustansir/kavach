package app.kavach.agent.ml

import android.content.Context
import android.graphics.Bitmap
import org.json.JSONObject
import org.tensorflow.lite.Interpreter
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel

/**
 * M1 vision gate slot (CLS-1). Loads `vision_gate.tflite` + `vision_gate.json` (labels, input size)
 * from the downloaded model bundle dir. No model on disk → [available] = false and the pipeline runs on
 * text/URL/app signals only (design principle 5: degrade gracefully).
 */
class VisionGate private constructor(private val interpreter: Interpreter, val labels: List<String>, private val size: Int) {
    private val input: ByteBuffer = ByteBuffer.allocateDirect(size * size * 3).order(ByteOrder.nativeOrder())
    private val pixels = IntArray(size * size)
    private val out = Array(1) { FloatArray(labels.size) }

    /** Returns label → probability. Zeroes its pixel buffers afterwards (SENSE-5). */
    @Synchronized fun run(bitmap: Bitmap): Map<String, Double> {
        val scaled = if (bitmap.width == size && bitmap.height == size) bitmap else Bitmap.createScaledBitmap(bitmap, size, size, true)
        try {
            scaled.getPixels(pixels, 0, size, 0, 0, size, size)
            input.rewind()
            for (p in pixels) { input.put((p shr 16 and 0xff).toByte()); input.put((p shr 8 and 0xff).toByte()); input.put((p and 0xff).toByte()) }
            input.rewind()
            interpreter.run(input, out)
            return labels.indices.associate { labels[it] to out[0][it].toDouble() }
        } finally {
            pixels.fill(0)
            input.rewind(); while (input.hasRemaining()) input.put(0)
            if (scaled !== bitmap) scaled.recycle()
        }
    }

    companion object {
        fun modelDir(ctx: Context) = File(ctx.filesDir, "models/current")

        fun load(ctx: Context): VisionGate? = runCatching {
            val dir = modelDir(ctx)
            val model = File(dir, "vision_gate.tflite")
            val meta = File(dir, "vision_gate.json")
            if (!model.exists() || !meta.exists()) return null
            val m = JSONObject(meta.readText())
            val labels = m.getJSONArray("labels").let { a -> (0 until a.length()).map { a.getString(it) } }
            val buf = FileInputStream(model).channel.use { it.map(FileChannel.MapMode.READ_ONLY, 0, it.size()) }
            VisionGate(Interpreter(buf, Interpreter.Options().setNumThreads(2)), labels, m.optInt("input", 224))
        }.getOrNull()
    }
}

/** 64-bit difference hash for near-duplicate frame skipping (SENSE-5). */
object DHash {
    fun of(bitmap: Bitmap): Long {
        val s = Bitmap.createScaledBitmap(bitmap, 9, 8, true)
        val px = IntArray(72).also { s.getPixels(it, 0, 9, 0, 0, 9, 8) }
        s.recycle()
        fun lum(p: Int) = (p shr 16 and 0xff) * 299 + (p shr 8 and 0xff) * 587 + (p and 0xff) * 114
        var h = 0L
        for (y in 0 until 8) for (x in 0 until 8) {
            h = h shl 1
            if (lum(px[y * 9 + x]) > lum(px[y * 9 + x + 1])) h = h or 1
        }
        px.fill(0)
        return h
    }
    fun distance(a: Long, b: Long) = java.lang.Long.bitCount(a xor b)
}
