// Runs every 5 min from pg_cron (migration app_backend). Heartbeat sweeper (TMP-7) + late-digest fallback (§4.4).
import { admin, check, HttpError, istNow, json, serve } from "../_shared/util.ts";
import { pushToFamily } from "../_shared/notify.ts";
import { summarize, type DigestStats } from "../_shared/summary.ts";

serve(async (req) => {
  const secret = Deno.env.get("CRON_SECRET");
  if (!secret || req.headers.get("x-cron-secret") !== secret) throw new HttpError(401, "bad cron secret");
  const offline = await sweepOffline();
  const partial = await partialDigests();
  const adults = await adultCheck();
  return json({ offline, partial, adults });
});

// No heartbeat for 30 min while the phone was in use → offline alert, once per incident.
async function sweepOffline() {
  const cutoff = new Date(Date.now() - 30 * 60_000).toISOString();
  const devs = check(await admin.from("device").update({ health_state: "offline" })
    .lt("last_heartbeat", cutoff).eq("screen_on_recent", true).in("health_state", ["protected", "degraded"])
    .is("unpaired_at", null).select("id, child_id, last_heartbeat")) as { id: string; child_id: string; last_heartbeat: string }[];
  for (const d of devs) {
    await admin.from("health_event").insert({ device_id: d.id, state: "offline", reason: "no heartbeat 30 min" });
    const since = new Date(new Date(d.last_heartbeat).getTime() + 330 * 60_000).toISOString().slice(11, 16);
    await pushToFamily(d.child_id, {
      category: "TAMPER", channel: "device_health", data: { kind: "health", device_id: d.id, state: "offline" },
      text: (lang, name) => ({
        title: lang === "hi" ? `${name} का फ़ोन ऑफ़लाइन है` : `${name}'s phone is offline`,
        body: lang === "hi" ? `आख़िरी बार ${since} पर देखा गया` : `Last seen ${since}`,
      }),
    });
  }
  return devs.length;
}

// After 21:15 IST, children with a paired device but no digest today get one built from synced events.
async function partialDigests() {
  const { day, minutes } = istNow();
  if (minutes < 21 * 60 + 15) return 0;
  // Bounded per run; the next 5-minute run picks up the rest.
  const missing = check(await admin.rpc("children_missing_digest", { p_day: day, p_limit: 500 })) as
    { child_id: string; nickname: string; last_heartbeat: string | null }[];
  let n = 0;
  for (const { child_id: cid, nickname, last_heartbeat: last } of missing) {
    const start = new Date(`${day}T00:00:00+05:30`).toISOString();
    const evs = check(await admin.from("risk_event").select("category, severity, occurred_at")
      .eq("child_id", cid).gte("occurred_at", start)) as { category: string; severity: string; occurred_at: string }[];
    const risks = Object.values(evs.reduce((acc, e) => {
      const k = `${e.category}|${e.severity}`;
      (acc[k] ??= { cat: e.category, sev: e.severity, count: 0, times: [] }).count++;
      acc[k].times!.push(new Date(new Date(e.occurred_at).getTime() + 330 * 60_000).toISOString().slice(11, 16));
      return acc;
    }, {} as Record<string, NonNullable<DigestStats["risks"]>[number]>));
    const stats: DigestStats = { day, screenMin: 0, risks, partial: true };
    const { text, model } = await summarize(nickname, stats, "en");
    // ignoreDuplicates: the device may upload its full digest at the same moment; that one wins.
    const ins = check(await admin.from("daily_digest").upsert(
      { child_id: cid, day, stats, summary_text: text, summary_model: model, delivered_at: new Date().toISOString() },
      { onConflict: "child_id,day", ignoreDuplicates: true }).select("child_id")) as unknown[];
    if (!ins.length) continue;
    const lastIst = last ? new Date(new Date(last).getTime() + 330 * 60_000).toISOString().slice(11, 16) : "?";
    await pushToFamily(cid, {
      category: "INFO", channel: "digest", data: { kind: "digest", day },
      text: (lang, name) => ({
        title: lang === "hi" ? `${name} का दिन (अधूरा)` : `${name}'s day (partial)`,
        body: lang === "hi" ? `फ़ोन ${lastIst} से ऑफ़लाइन` : `Device offline since ${lastIst}`,
      }),
    });
    n++;
  }
  return n;
}

// VPC-5: on 1 Jan, children whose birth year makes them 18 stop being monitored (devices told to unpair).
async function adultCheck() {
  const { day, minutes } = istNow();
  if (!day.endsWith("-01-01") || minutes >= 5) return 0; // cron runs every 5 min → exactly once
  const year = Number(day.slice(0, 4));
  const kids = check(await admin.from("child").select("id, birth_year").lte("birth_year", year - 18)) as { id: string; birth_year: number }[];
  for (const k of kids) {
    const devs = check(await admin.from("device").select("id").eq("child_id", k.id).is("unpaired_at", null)) as { id: string }[];
    if (devs.length) await admin.from("device_command").insert(devs.map((d) => ({ device_id: d.id, kind: "unpair", args: { reason: "adult" } })));
    await pushToFamily(k.id, {
      category: "TAMPER", channel: "device_health", data: { kind: "adult" },
      text: (lang, name) => ({
        title: lang === "hi" ? `${name} अब 18 के हो गए` : `${name} is now 18`,
        body: lang === "hi" ? "निगरानी अपने-आप बंद हो रही है।" : "Monitoring is stopping automatically.",
      }),
    });
  }
  return kids.length;
}
