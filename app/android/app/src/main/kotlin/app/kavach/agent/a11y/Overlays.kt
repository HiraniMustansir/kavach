package app.kavach.agent.a11y

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.GridLayout
import android.widget.LinearLayout
import android.widget.TextView
import app.kavach.agent.Agent
import org.json.JSONObject
import java.util.Locale

/**
 * Full-screen accessibility overlays (design §10.8/10.9): blocked / limit / schedule / locked,
 * the CTL-5 intervention screen, and the parent-PIN gate. Copy is kind and non-shaming (KID-5).
 */
class Overlays(private val ctx: Context, private val agent: Agent) {
    enum class Kind { BLOCKED, LIMIT, SCHEDULE, LOCKED }

    private val wm = ctx.getSystemService(WindowManager::class.java)
    private var block: View? = null
    private var blockKind: Kind? = null
    private var top: View? = null
    private val hi get() = Locale.getDefault().language == "hi"
    private fun t(en: String, hiText: String) = if (hi) hiText else en

    private val params get() = WindowManager.LayoutParams(
        WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT,
        WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
        WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
        PixelFormat.TRANSLUCENT,
    )

    fun showBlock(kind: Kind, detail: String?) {
        if (blockKind == kind && block != null) return
        hideBlock()
        val (title, body) = when (kind) {
            Kind.BLOCKED -> t("This isn’t available right now", "यह अभी उपलब्ध नहीं है") to
                t("${detail ?: "This app"} is turned off by your parent.", "${detail ?: "यह ऐप"} आपके माता-पिता ने बंद किया है।")
            Kind.LIMIT -> t("Time’s up for today", "आज का समय पूरा हुआ") to
                t("You’ve used your time for ${detail ?: "this"}. You can ask for more.", "${detail ?: "इस"} का समय पूरा हो गया। आप और समय माँग सकते हैं।")
            Kind.SCHEDULE -> t("${detail ?: "Downtime"} is on", "${detail ?: "डाउनटाइम"} चल रहा है") to
                t("Only allowed apps work right now.", "अभी केवल अनुमति वाले ऐप चलेंगे।")
            Kind.LOCKED -> t("Your parent locked the phone", "माता-पिता ने फ़ोन लॉक किया है") to
                t("You can still call or ask for help.", "आप अब भी कॉल कर सकते हैं या मदद माँग सकते हैं।")
        }
        val v = screen(title, body, Color.parseColor("#F21F5EFF"))
        if (kind == Kind.LIMIT) v.addView(button(t("Ask for 15 more minutes", "15 मिनट और माँगें")) {
            agent.io.execute { runCatching { agent.api.post("request", JSONObject().put("kind", "more_time").put("minutes", 15)) } }
            (it as Button).text = t("Asked ✓", "माँगा ✓"); it.isEnabled = false
        })
        if (kind == Kind.LOCKED || kind == Kind.SCHEDULE) {
            v.addView(button(t("Phone", "फ़ोन")) { ctx.startActivity(Intent(Intent.ACTION_DIAL).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) })
            v.addView(button(t("Parent PIN", "पैरेंट PIN")) {
                showPinGate(onOk = { agent.store.lockedByParent = false; agent.store.pausedUntil = System.currentTimeMillis() + 30 * 60_000; hideBlock() }) {}
            })
        }
        v.addView(button(t("🆘 I need help", "🆘 मुझे मदद चाहिए")) { agent.io.execute { agent.risk.sos(); agent.sync() } })
        if (kind == Kind.BLOCKED || kind == Kind.LIMIT) {
            // A notice, not a wall: we've already sent the phone home, so let the child read it, then it goes.
            v.addView(button(t("OK", "ठीक है")) { hideBlock() })
            v.postDelayed({ if (block === v) hideBlock() }, 10_000)
        }
        block = v; blockKind = kind
        wm.addView(v, params)
    }

    /** keepNotice: an allowed app (e.g. the home screen) doesn't clear a blocked/limit notice; OK or the timeout does. */
    fun hideBlock(keepNotice: Boolean = false) {
        if (keepNotice && (blockKind == Kind.BLOCKED || blockKind == Kind.LIMIT)) return
        block?.let { runCatching { wm.removeView(it) } }; block = null; blockKind = null
    }

    fun showIntervention(category: String, goBack: () -> Unit) {
        hideTop()
        val v = screen("🛡  " + t("This isn’t okay for you to see.", "यह आपके देखने लायक नहीं है।"),
            if (category == "GORE") t("It may be upsetting.", "यह परेशान कर सकता है।") else "", Color.parseColor("#FA0F1220"))
        v.addView(button(t("← Go back", "← वापस जाएँ")) { goBack(); hideTop() })
        v.addView(button(t("Saw something upsetting? Talk to my parent", "कुछ बुरा देखा? माता-पिता से बात करें")) {
            agent.io.execute { agent.risk.sos(); agent.sync() }; hideTop()
        })
        show(v)
        // Auto-dismiss once the risk has cleared for a few seconds.
        v.postDelayed(object : Runnable {
            override fun run() { if (top !== v) return; if (System.currentTimeMillis() - agent.risk.lastRiskAt > 3_000) hideTop() else v.postDelayed(this, 1_000) }
        }, 4_000)
    }

    /** ACC-8: 6-digit PIN, 5 tries then 15-minute lockout + parent alert. */
    fun showPinGate(onOk: () -> Unit, onCancel: () -> Unit) {
        hideTop()
        val pin = agent.store.policy.pin
        val v = screen("🔒 " + t("Parent only", "केवल माता-पिता"), t("Changing Kavach needs your parent’s PIN.", "Kavach बदलने के लिए माता-पिता का PIN चाहिए।"), Color.parseColor("#FA0F1220"))
        val dots = TextView(ctx).apply { textSize = 28f; setTextColor(Color.WHITE); gravity = Gravity.CENTER; text = "○○○○○○" }
        val status = TextView(ctx).apply { setTextColor(Color.parseColor("#FFD43B")); gravity = Gravity.CENTER }
        v.addView(dots); v.addView(status)
        val entered = StringBuilder()
        fun locked() = agent.store.pinLockoutUntil > System.currentTimeMillis()
        if (pin == null) status.text = t("Your parent hasn’t set a PIN yet.", "माता-पिता ने अभी PIN सेट नहीं किया।")
        if (locked()) status.text = t("Too many tries. Try again later.", "बहुत बार गलत। बाद में कोशिश करें।")
        val grid = GridLayout(ctx).apply { columnCount = 3; layoutParams = LinearLayout.LayoutParams(-2, -2).apply { gravity = Gravity.CENTER } }
        (listOf("1", "2", "3", "4", "5", "6", "7", "8", "9", "⌫", "0", "✕")).forEach { k ->
            grid.addView(Button(ctx).apply {
                text = k; textSize = 22f; minWidth = 180; minHeight = 150
                contentDescription = when (k) { "⌫" -> "Delete"; "✕" -> "Cancel"; else -> k }
                setOnClickListener {
                    when (k) {
                        "✕" -> { hideTop(); onCancel(); return@setOnClickListener }
                        "⌫" -> if (entered.isNotEmpty()) entered.setLength(entered.length - 1)
                        else -> if (entered.length < 6 && pin != null && !locked()) entered.append(k)
                    }
                    dots.text = "●".repeat(entered.length) + "○".repeat(6 - entered.length)
                    if (entered.length == 6 && pin != null) {
                        val (r, left) = agent.verifyPin(entered.toString())
                        entered.setLength(0); dots.text = "○○○○○○"
                        when (r) {
                            Agent.PinResult.OK -> { hideTop(); onOk() }
                            Agent.PinResult.WRONG -> status.text = t("$left tries left", "$left कोशिशें बाकी")
                            else -> status.text = t("Too many tries. Your parent has been told.", "बहुत बार गलत। माता-पिता को बताया गया।")
                        }
                    }
                }
            })
        }
        v.addView(grid)
        show(v, focusable = true)
    }

    fun hideTop() { top?.let { runCatching { wm.removeView(it) } }; top = null }
    fun hideAll() { hideTop(); hideBlock() }

    private fun show(v: View, focusable: Boolean = false) {
        top = v
        wm.addView(v, params.apply { if (focusable) flags = flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE.inv() })
    }

    private fun screen(title: String, body: String, bg: Int) = LinearLayout(ctx).apply {
        orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER; setPadding(64, 64, 64, 64); setBackgroundColor(bg)
        isClickable = true // swallow touches to the app underneath
        addView(TextView(ctx).apply { text = title; textSize = 24f; setTextColor(Color.WHITE); typeface = Typeface.DEFAULT_BOLD; gravity = Gravity.CENTER })
        if (body.isNotEmpty()) addView(TextView(ctx).apply { text = body; textSize = 16f; setTextColor(Color.parseColor("#E7E9F2")); gravity = Gravity.CENTER; setPadding(0, 24, 0, 32) })
    }

    private fun button(text: String, onClick: (View) -> Unit) = Button(ctx).apply {
        this.text = text; isAllCaps = false; textSize = 16f; setTextColor(Color.parseColor("#141826")); minHeight = 144
        background = GradientDrawable().apply { cornerRadius = 36f; setColor(Color.WHITE) }
        layoutParams = LinearLayout.LayoutParams(-1, -2).apply { topMargin = 24 }
        setOnClickListener(onClick)
    }
}
