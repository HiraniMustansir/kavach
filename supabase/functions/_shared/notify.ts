import { admin, check, inWindow, istNow } from "./util.ts";
import { dropDeadGuardianTokens, sendPush } from "./push.ts";

type Lang = "en" | "hi";
type Prefs = { categories?: string[]; quietFrom?: string; quietTo?: string; criticalBypassQuiet?: boolean };

// Category labels for notification text (design §8.5: say what happened, never guess intent).
const LABEL: Record<string, Record<Lang, string>> = {
  SEX: { en: "Explicit content", hi: "अश्लील सामग्री" },
  CSE: { en: "Possible grooming or sextortion", hi: "संभावित ग्रूमिंग या ब्लैकमेल" },
  GORE: { en: "Violent content", hi: "हिंसक सामग्री" },
  SELF: { en: "Self-harm related", hi: "आत्म-हानि से जुड़ा" },
  WEAP: { en: "Weapons", hi: "हथियार" },
  DRUG: { en: "Drugs or alcohol", hi: "नशा या शराब" },
  GAMB: { en: "Gambling", hi: "जुआ" },
  HATE: { en: "Hate speech", hi: "नफ़रत भरी भाषा" },
  BULLY: { en: "Bullying", hi: "धमकाना" },
  STRNG: { en: "Stranger contact", hi: "अजनबी से संपर्क" },
  SCAM: { en: "Scam or phishing", hi: "धोखाधड़ी" },
  HORROR: { en: "Disturbing horror", hi: "डरावनी सामग्री" },
  CUSTOM: { en: "Your keyword", hi: "आपका कीवर्ड" },
  BEH: { en: "Unusual activity", hi: "असामान्य गतिविधि" },
  SOS: { en: "SOS — needs help", hi: "SOS — मदद चाहिए" },
  TAMPER: { en: "Protection changed", hi: "सुरक्षा में बदलाव" },
};
export const label = (cat: string, lang: Lang) => LABEL[cat]?.[lang] ?? cat;

export type Recipient = { guardian_id: string; role: string; lang: Lang; prefs: Prefs; tokens: string[] };

export async function recipients(childId: string): Promise<{ nickname: string; recipients: Recipient[] }> {
  const child = check(await admin.from("child").select("nickname, family_id").eq("id", childId).single()) as
    { nickname: string; family_id: string };
  const members = check(await admin.from("family_member")
    .select("guardian_id, role, notify_prefs, guardian(locale, guardian_push_token(token))")
    .eq("family_id", child.family_id)) as unknown as {
      guardian_id: string; role: string; notify_prefs: Prefs;
      guardian: { locale: string; guardian_push_token: { token: string }[] } | null;
    }[];
  return {
    nickname: child.nickname,
    recipients: members.map((m) => ({
      guardian_id: m.guardian_id, role: m.role, prefs: m.notify_prefs ?? {},
      lang: m.guardian?.locale?.startsWith("hi") ? "hi" : "en",
      tokens: m.guardian?.guardian_push_token.map((t) => t.token) ?? [],
    })),
  };
}

/** Per-guardian filtering (ACC-6): category opt-out and quiet hours; critical bypasses quiet hours (ALR-3). */
export function wants(r: Recipient, category: string, critical: boolean, nowMin = istNow().minutes) {
  // INFO (digests, child requests) is never opted out by category; quiet hours still apply.
  if (r.prefs.categories && !critical && category !== "INFO" && !r.prefs.categories.includes(category)) return false;
  if (r.prefs.quietFrom && r.prefs.quietTo && inWindow(nowMin, r.prefs.quietFrom, r.prefs.quietTo)) {
    return critical && r.prefs.criticalBypassQuiet !== false;
  }
  return true;
}

export async function pushToFamily(
  childId: string,
  opts: { category: string; critical?: boolean; channel: string; data: Record<string, string>;
    text: (lang: Lang, nickname: string) => { title: string; body: string } },
) {
  const { nickname, recipients: rs } = await recipients(childId);
  const dead: string[] = [];
  for (const r of rs) {
    if (!wants(r, opts.category, !!opts.critical)) continue;
    const t = opts.text(r.lang, nickname);
    dead.push(...await sendPush(r.tokens, { ...t, channel: opts.channel, critical: opts.critical, data: { ...opts.data, child_id: childId } }));
  }
  await dropDeadGuardianTokens(dead);
}

type Ev = { id: string; occurred_at: string; category: string; severity: string; app_label: string | null; app_pkg: string; child_id: string };

const fmtTime = (iso: string) =>
  new Date(new Date(iso).getTime() + 330 * 60_000).toISOString().slice(11, 16);

/**
 * Real-time alert fan-out for freshly inserted events (ALR-1..5):
 * critical always; high max 1 per child+category per 5 min; medium grouped per 10 min; low → digest only.
 * Teen band: medium never pushes (PRD §3 age bands).
 */
export async function alertForEvents(events: Ev[], band: "child" | "teen", realtimeOff: Set<string>) {
  for (const e of events) {
    if (e.severity === "low") continue;
    if (e.severity === "medium" && (band === "teen" || realtimeOff.has(e.category))) continue;
    if (e.severity === "high" && realtimeOff.has(e.category)) continue;

    const critical = e.severity === "critical";
    let count = 1;
    if (!critical) {
      const windowMin = e.severity === "high" ? 5 : 10;
      const since = new Date(new Date(e.occurred_at).getTime() - windowMin * 60_000).toISOString();
      const recent = check(await admin.from("risk_event").select("id, pushed_at")
        .eq("child_id", e.child_id).eq("category", e.category).eq("severity", e.severity)
        .gte("occurred_at", since).lte("occurred_at", e.occurred_at)) as { id: string; pushed_at: string | null }[];
      if (recent.some((r) => r.pushed_at && r.id !== e.id)) continue; // already told the parent in this window
      count = recent.length;
    }
    // Claim the push before sending so two concurrent batches don't both notify.
    const claimed = check(await admin.from("risk_event").update({ pushed_at: new Date().toISOString() })
      .eq("id", e.id).is("pushed_at", null).select("id")) as unknown[];
    if (!claimed.length) continue;

    const app = e.app_label ?? e.app_pkg;
    await pushToFamily(e.child_id, {
      category: e.category, critical,
      channel: critical ? "critical_alerts" : e.severity === "high" ? "alerts_high" : "alerts_medium",
      data: { kind: "alert", event_id: e.id },
      text: (lang, name) => critical
        ? { title: lang === "hi" ? `🔴 ${name} को आपकी ज़रूरत हो सकती है` : `🔴 ${name} may need you`,
            body: `${label(e.category, lang)} · ${app} · ${fmtTime(e.occurred_at)}` }
        : count > 1
          ? { title: `${name} · ${count} ${label(e.category, lang)}`, body: `${lang === "hi" ? "पिछले 10 मिनट" : "Last 10 min"} · ${app}` }
          : { title: `🟠 ${label(e.category, lang)} · ${name}`, body: `${app} · ${fmtTime(e.occurred_at)}` },
    });
  }
}
