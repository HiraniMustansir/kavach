// Child-device API (design §4.2). Every route except pair-complete is ECDSA-signed by the device key.
import { admin, ageBand, CATEGORIES, check, hex, HttpError, json, must, serve, sha256, SEVERITIES, unb64 } from "../_shared/util.ts";
import { verifyDevice, type Device } from "../_shared/deviceAuth.ts";
import { alertForEvents, label, pushToFamily } from "../_shared/notify.ts";
import { summarize, templateSummary, type DigestStats } from "../_shared/summary.ts";

serve(async (req, route) => {
  const body = await req.text();
  if (body.length > 256_000) throw new HttpError(413, "too large");
  if (route === "pair-complete") return pairComplete(JSON.parse(body || "{}"));

  const dev = await verifyDevice(req, route, body);
  const input = body ? JSON.parse(body) : {};
  switch (route) {
    case "events": return events(dev, input);
    case "heartbeat": return heartbeat(dev, input);
    case "signal": return signal(dev, input);
    case "digest": return digest(dev, input);
    case "policy": return json(await latestPolicy(dev.child_id));
    case "request": return childRequest(dev, input);
    default: throw new HttpError(404, "no such route");
  }
});

async function latestPolicy(childId: string) {
  return check(await admin.from("policy").select("version, body").eq("child_id", childId)
    .order("version", { ascending: false }).limit(1).maybeSingle()) ?? { version: 0, body: {} };
}

async function hasConsent(childId: string, scope: string): Promise<boolean> {
  const rows = check(await admin.from("consent_record").select("scopes")
    .eq("child_id", childId).is("revoked_at", null).order("granted_at", { ascending: false }).limit(1)) as { scopes: Record<string, boolean> }[];
  return rows[0]?.scopes?.[scope] === true;
}

// PAIR-1/PAIR-6: one-time token (10-min TTL) binds a fresh device key to a child.
async function pairComplete(b: { token?: string; pubkey?: string; model?: string; oem?: string; osVersion?: string; appVersion?: string; fcmToken?: string }) {
  must(typeof b.token === "string" && b.token.length >= 8 && b.token.length <= 64, 400, "token required");
  const pub = unb64(must(b.pubkey, 400, "pubkey required"));
  await crypto.subtle.importKey("spki", pub, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"])
    .catch(() => { throw new HttpError(400, "pubkey must be P-256 SPKI"); });

  const tokenHash = "\\x" + hex(await sha256(b.token!.toUpperCase()));
  // Atomic single use: only one caller can flip used_at.
  const tok = check(await admin.from("pairing_token").update({ used_at: new Date().toISOString() })
    .eq("token_hash", tokenHash).is("used_at", null).gt("expires_at", new Date().toISOString())
    .select("child_id, tier").maybeSingle()) as { child_id: string; tier: string } | null;
  must(tok, 400, "pairing code invalid or expired");

  const s = (v: unknown, n = 80) => (typeof v === "string" ? v.slice(0, n) : null);
  const dev = check(await admin.from("device").insert({
    child_id: tok!.child_id, tier: tok!.tier, pubkey: "\\x" + hex(pub),
    model: s(b.model), oem: s(b.oem), os_version: s(b.osVersion, 20), app_version: s(b.appVersion, 20),
    fcm_token: s(b.fcmToken, 4096), last_heartbeat: new Date().toISOString(), screen_on_recent: true,
  }).select("id").single()) as { id: string };

  const child = check(await admin.from("child").select("nickname, birth_year").eq("id", tok!.child_id).single()) as
    { nickname: string; birth_year: number };
  await pushToFamily(tok!.child_id, {
    category: "TAMPER", channel: "device_health", data: { kind: "paired", device_id: dev.id },
    text: (lang, name) => ({ title: lang === "hi" ? `${name} का फ़ोन जुड़ गया` : `${name}'s phone is connected`, body: s(b.model) ?? "" }),
  });
  return json({
    deviceId: dev.id, childId: tok!.child_id, nickname: child.nickname,
    ageBand: ageBand(child.birth_year), tier: tok!.tier, policy: await latestPolicy(tok!.child_id),
  });
}

type InEvent = {
  id: string; ts: number; category: string; severity: string; score: number; pkg: string; appLabel?: string;
  domain?: string; durationS?: number; description: string; customKeyword?: string;
};

// CLS-9: payload is labels/scores/app/domain only. Validated hard because it is device-supplied.
async function events(dev: Device, b: { events?: InEvent[] }) {
  const list = must(Array.isArray(b.events) ? b.events : null, 400, "events[] required");
  must(list.length <= 100, 400, "max 100 events");
  const screenAi = await hasConsent(dev.child_id, "screen_ai");
  const now = Date.now();
  const rows = list.filter((e) =>
    typeof e.id === "string" && /^[0-9A-HJKMNP-TV-Z]{26}$/.test(e.id) &&
    (CATEGORIES as readonly string[]).includes(e.category) && (SEVERITIES as readonly string[]).includes(e.severity) &&
    typeof e.score === "number" && e.score >= 0 && e.score <= 1 &&
    typeof e.ts === "number" && e.ts > now - 30 * 86_400_000 && e.ts < now + 10 * 60_000 &&
    typeof e.pkg === "string" && typeof e.description === "string" &&
    // VPC-1/3: without screen-analysis consent only safety signals the parent set up are accepted.
    (screenAi || ["SOS", "TAMPER", "BEH", "CUSTOM"].includes(e.category))
  ).map((e) => ({
    id: e.id, device_id: dev.id, child_id: dev.child_id, occurred_at: new Date(e.ts).toISOString(),
    category: e.category, severity: e.severity, score: e.score,
    app_pkg: e.pkg.slice(0, 200), app_label: e.appLabel?.slice(0, 80) ?? null,
    domain: e.domain?.slice(0, 253) ?? null, duration_s: Number.isInteger(e.durationS) ? e.durationS : null,
    description: e.description.slice(0, 200), custom_keyword: e.customKeyword?.slice(0, 80) ?? null,
  }));
  if (rows.length) {
    // Idempotent by ULID (ALR-6 offline queue resends). Only newly inserted rows come back.
    const inserted = check(await admin.from("risk_event").upsert(rows, { onConflict: "id,occurred_at", ignoreDuplicates: true })
      .select("id, occurred_at, category, severity, app_label, app_pkg, child_id")) as Parameters<typeof alertForEvents>[0];
    const child = check(await admin.from("child").select("birth_year").eq("id", dev.child_id).single()) as { birth_year: number };
    const pol = await latestPolicy(dev.child_id);
    const cats = (pol.body as { categories?: Record<string, { realtime?: boolean }> }).categories ?? {};
    const off = new Set(Object.entries(cats).filter(([, c]) => c.realtime === false).map(([k]) => k));
    await alertForEvents(inserted, ageBand(child.birth_year), off);
  }
  return json({ accepted: list.map((e) => e.id) }); // device marks all as synced; invalid ones are dropped for good
}

const HEALTH = ["protected", "degraded", "paused"];

// TMP-7/8: liveness + health, and the command/policy poll for devices without working FCM.
async function heartbeat(dev: Device, b: {
  health?: string; reason?: string; battery?: number; screenOnRecent?: boolean; policyVersion?: number;
  modelVersion?: string; currentApp?: string; fcmToken?: string; ackCommands?: number[]; today?: unknown;
}) {
  const health = HEALTH.includes(b.health ?? "") ? b.health! : "protected";
  const reason = typeof b.reason === "string" ? b.reason.slice(0, 120) : null;
  await admin.from("device").update({
    last_heartbeat: new Date().toISOString(), health_state: health, health_reason: health === "protected" ? null : reason,
    battery: Number.isInteger(b.battery) ? b.battery : null, screen_on_recent: !!b.screenOnRecent,
    policy_version: Number.isInteger(b.policyVersion) ? b.policyVersion : null,
    model_version: b.modelVersion?.slice(0, 40) ?? null,
    current_app: b.currentApp?.slice(0, 80) ?? null,
    today: b.today && typeof b.today === "object" && JSON.stringify(b.today).length < 4000 ? b.today : null,
    ...(b.fcmToken ? { fcm_token: b.fcmToken.slice(0, 4096) } : {}),
  }).eq("id", dev.id);

  if (health !== dev.health_state) {
    await admin.from("health_event").insert({ device_id: dev.id, state: health, reason });
    if (health === "degraded" || (dev.health_state === "offline" && health === "protected")) {
      await pushToFamily(dev.child_id, {
        category: "TAMPER", channel: "device_health", data: { kind: "health", device_id: dev.id, state: health },
        text: (lang, name) => health === "degraded"
          ? { title: lang === "hi" ? `${name} के फ़ोन पर सुरक्षा बंद` : `Protection off on ${name}'s phone`, body: reason ?? "" }
          : { title: lang === "hi" ? `${name} का फ़ोन फिर ऑनलाइन` : `${name}'s phone is back online`, body: "" },
      });
    }
  }
  if (Array.isArray(b.ackCommands) && b.ackCommands.length) {
    await admin.from("device_command").update({ acked_at: new Date().toISOString() })
      .eq("device_id", dev.id).in("id", b.ackCommands.filter(Number.isInteger).slice(0, 50));
  }
  const commands = check(await admin.from("device_command").select("id, kind, args, created_at")
    .eq("device_id", dev.id).is("acked_at", null).order("id").limit(20));
  const pol = await latestPolicy(dev.child_id);
  return json({ commands, policyVersion: pol.version, tuning: await tuning(dev.child_id), serverTime: Date.now() });
}

/** CLS-11: per-family offsets from parent feedback, bounded ±1 logit (design §3.5 b_family). */
async function tuning(childId: string): Promise<Record<string, number>> {
  const since = new Date(Date.now() - 30 * 86_400_000).toISOString();
  const rows = check(await admin.from("risk_event").select("category, feedback")
    .eq("child_id", childId).gte("occurred_at", since).not("feedback", "is", null).limit(2000)) as { category: string; feedback: string }[];
  const acc: Record<string, { up: number; down: number }> = {};
  for (const r of rows) {
    const a = (acc[r.category] ??= { up: 0, down: 0 });
    r.feedback === "useful" ? a.up++ : a.down++;
  }
  // More "not a problem" → raise the bar (positive offset = less sensitive). Needs ≥3 labels to move.
  return Object.fromEntries(Object.entries(acc).filter(([, a]) => a.up + a.down >= 3)
    .map(([k, a]) => [k, Math.max(-1, Math.min(1, (a.down - a.up) / (a.up + a.down)))]));
}

// One-off safety signals that must reach parents immediately.
async function signal(dev: Device, b: { kind?: string; lat?: number; lng?: number; detail?: string }) {
  const kinds: Record<string, { cat: string; critical: boolean; en: string; hi: string }> = {
    sos: { cat: "SOS", critical: true, en: "pressed “I need help”", hi: "ने “मुझे मदद चाहिए” दबाया" },
    pin_lockout: { cat: "TAMPER", critical: false, en: "— someone tried to change Kavach settings", hi: "— किसी ने Kavach की सेटिंग बदलने की कोशिश की" },
    admin_disable_requested: { cat: "TAMPER", critical: false, en: "— someone is trying to turn off Kavach", hi: "— कोई Kavach बंद करने की कोशिश कर रहा है" },
    test: { cat: "TAMPER", critical: false, en: "— test alert from setup ✓", hi: "— सेटअप से टेस्ट अलर्ट ✓" }, // PAIR-4
    unpaired: { cat: "TAMPER", critical: false, en: "— Kavach was removed with the parent PIN", hi: "— पैरेंट PIN से Kavach हटाया गया" },
  };
  const k = must(kinds[b.kind ?? ""], 400, "unknown signal");
  const hasLoc = typeof b.lat === "number" && typeof b.lng === "number" && await hasConsent(dev.child_id, "location");
  if (b.kind === "unpaired") await admin.from("device").update({ unpaired_at: new Date().toISOString() }).eq("id", dev.id);
  await admin.from("health_event").insert({ device_id: dev.id, state: b.kind, reason: b.detail?.slice(0, 120) ?? null });
  await pushToFamily(dev.child_id, {
    category: k.cat, critical: k.critical, channel: k.critical ? "critical_alerts" : "device_health",
    data: { kind: b.kind!, device_id: dev.id, ...(hasLoc ? { lat: String(b.lat), lng: String(b.lng) } : {}) },
    text: (lang, name) => ({ title: `${k.critical ? "🔴 " : ""}${name} ${lang === "hi" ? k.hi : k.en}`, body: label(k.cat, lang) }),
  });
  return json({ ok: true });
}

// DIG-1..3: device uploads aggregates; server writes the summary and pushes it.
async function digest(dev: Device, b: { stats?: DigestStats }) {
  const s = must(b.stats, 400, "stats required");
  must(/^\d{4}-\d{2}-\d{2}$/.test(s.day) && Number.isInteger(s.screenMin), 400, "bad stats");
  const child = check(await admin.from("child").select("nickname").eq("id", dev.child_id).single()) as { nickname: string };
  // Summary language follows the owner's locale; other guardians still get the push in theirs.
  const owner = check(await admin.rpc("child_owner_locale", { cid: dev.child_id })) as string | null;
  const lang = owner?.startsWith("hi") ? "hi" : "en";
  const { text, model } = await summarize(child.nickname, s, lang);
  await admin.from("daily_digest").upsert({
    child_id: dev.child_id, day: s.day, stats: s, summary_text: text, summary_model: model, delivered_at: new Date().toISOString(),
  });
  await pushToFamily(dev.child_id, {
    category: "INFO", channel: "digest", data: { kind: "digest", day: s.day },
    text: (l, name) => ({ title: l === "hi" ? `${name} का दिन` : `${name}'s day`, body: l === lang ? text.split(/(?<=[.।])\s/)[0] : templateSummary(name, s, l) }),
  });
  return json({ ok: true });
}

// CTL-7/KID-4: child asks for more time or an app.
async function childRequest(dev: Device, b: { kind?: string; minutes?: number; appPkg?: string; reason?: string }) {
  must(b.kind === "more_time" || b.kind === "app", 400, "bad kind");
  const minutes = b.kind === "more_time" ? must(Number.isInteger(b.minutes) && b.minutes! > 0 && b.minutes! <= 240 ? b.minutes : null, 400, "minutes 1-240") : null;
  const reason = b.reason?.slice(0, 140) ?? null;
  const r = check(await admin.from("child_request").insert({
    child_id: dev.child_id, device_id: dev.id, kind: b.kind, minutes, app_pkg: b.appPkg?.slice(0, 200) ?? null, reason,
  }).select("id").single()) as { id: number };
  await pushToFamily(dev.child_id, {
    category: "INFO", channel: "requests", data: { kind: "request", request_id: String(r.id) },
    text: (lang, name) => ({
      title: b.kind === "more_time"
        ? (lang === "hi" ? `${name} ${minutes} मिनट और माँग रहा है` : `${name} asks for ${minutes} more minutes`)
        : (lang === "hi" ? `${name} एक ऐप माँग रहा है` : `${name} asks for an app`),
      body: [b.appPkg, reason].filter(Boolean).join(" · "),
    }),
  });
  return json({ id: r.id });
}
