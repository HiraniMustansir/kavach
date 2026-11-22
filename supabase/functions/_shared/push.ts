import { admin, b64 } from "./util.ts";

// FCM HTTP v1. Needs secret FCM_SERVICE_ACCOUNT (the Firebase service-account JSON).
const SA = (() => { try { return JSON.parse(Deno.env.get("FCM_SERVICE_ACCOUNT") ?? ""); } catch { return null; } })();
let cached: { token: string; exp: number } | null = null;

const b64url = (s: string | Uint8Array) =>
  b64(typeof s === "string" ? new TextEncoder().encode(s) : s).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");

async function accessToken(): Promise<string> {
  if (cached && cached.exp > Date.now() + 60_000) return cached.token;
  const now = Math.floor(Date.now() / 1000);
  const unsigned = `${b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }))}.${b64url(JSON.stringify({
    iss: SA.client_email, scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token", iat: now, exp: now + 3600,
  }))}`;
  const pem = SA.private_key.replace(/-----[^-]+-----|\s/g, "");
  const key = await crypto.subtle.importKey("pkcs8", Uint8Array.from(atob(pem), (c) => c.charCodeAt(0)),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned)));
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${unsigned}.${b64url(sig)}`,
  });
  const j = await res.json();
  if (!res.ok) throw new Error(`fcm auth: ${JSON.stringify(j)}`);
  cached = { token: j.access_token, exp: Date.now() + j.expires_in * 1000 };
  return cached.token;
}

export type Push = {
  title?: string; body?: string; channel?: string; data: Record<string, string>;
  /** Critical → iOS time-sensitive; data-only messages wake the child agent. */
  critical?: boolean;
};

/** Returns tokens FCM reported as dead so callers can drop them. Never throws. */
export async function sendPush(tokens: string[], p: Push): Promise<string[]> {
  if (!SA || tokens.length === 0) {
    if (!SA) console.warn("FCM_SERVICE_ACCOUNT not set; push skipped", p.data);
    return [];
  }
  const dead: string[] = [];
  let auth: string;
  try { auth = await accessToken(); } catch (e) { console.error(e); return []; }
  await Promise.all(tokens.map(async (token) => {
    const message: Record<string, unknown> = { token, data: p.data, android: { priority: "HIGH" } };
    if (p.title) {
      message.notification = { title: p.title, body: p.body ?? "" };
      message.android = { priority: "HIGH", notification: { channel_id: p.channel ?? "alerts_high" } };
      message.apns = { payload: { aps: { "interruption-level": p.critical ? "time-sensitive" : "active", sound: "default" } } };
    }
    const res = await fetch(`https://fcm.googleapis.com/v1/projects/${SA.project_id}/messages:send`, {
      method: "POST",
      headers: { authorization: `Bearer ${auth}`, "content-type": "application/json" },
      body: JSON.stringify({ message }),
    }).catch((e) => { console.error(e); return null; });
    if (res && (res.status === 404 || res.status === 400)) {
      const t = await res.text();
      if (t.includes("UNREGISTERED") || t.includes("INVALID_ARGUMENT")) dead.push(token);
    }
  }));
  return dead;
}

/** Data-only push to a child device so it fetches commands/policy now (≤10 s policy sync). */
export async function wakeDevice(fcmToken: string | null, reason: string) {
  if (fcmToken) await sendPush([fcmToken], { data: { kind: reason } });
}

export async function dropDeadGuardianTokens(dead: string[]) {
  if (dead.length) await admin.from("guardian_push_token").delete().in("token", dead);
}
