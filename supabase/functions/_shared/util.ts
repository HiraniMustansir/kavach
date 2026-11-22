import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";

export const admin: SupabaseClient = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

export class HttpError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

export const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...CORS },
  });

export const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, content-type, x-client-info, apikey",
};

/** Wraps a handler: CORS preflight, HttpError → status, anything else → 500 without leaking details. */
export function serve(handler: (req: Request, route: string) => Promise<Response>) {
  Deno.serve(async (req) => {
    if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
    const route = new URL(req.url).pathname.split("/").filter(Boolean).pop() ?? "";
    try {
      return await handler(req, route);
    } catch (e) {
      if (e instanceof HttpError) return json({ error: e.message }, e.status);
      console.error(e);
      return json({ error: "internal error" }, 500);
    }
  });
}

export function must<T>(v: T | null | undefined, status: number, msg: string): T {
  if (v === null || v === undefined || v === false) throw new HttpError(status, msg);
  return v;
}

export function check<T>(res: { data: T; error: unknown }): T {
  if (res.error) throw res.error;
  return res.data;
}

export const hex = (b: ArrayBuffer | Uint8Array) =>
  Array.from(b instanceof Uint8Array ? b : new Uint8Array(b), (x) => x.toString(16).padStart(2, "0")).join("");
export const unhex = (s: string) => new Uint8Array(s.replace(/^\\x/, "").match(/../g)!.map((h) => parseInt(h, 16)));
export const b64 = (b: Uint8Array) => btoa(String.fromCharCode(...b));
export const unb64 = (s: string) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
export const sha256 = async (data: string | Uint8Array<ArrayBuffer>) =>
  new Uint8Array(await crypto.subtle.digest("SHA-256", typeof data === "string" ? new TextEncoder().encode(data) : data));

export const CATEGORIES = ["SEX","CSE","GORE","SELF","WEAP","DRUG","GAMB","HATE","BULLY","STRNG","SCAM","HORROR","CUSTOM","BEH","SOS","TAMPER"] as const;
export const SEVERITIES = ["low", "medium", "high", "critical"] as const;

export function ageBand(birthYear: number, now = new Date()): "child" | "teen" {
  return now.getUTCFullYear() - birthYear <= 12 ? "child" : "teen";
}

/** Asia/Kolkata wall-clock parts; India has no DST so a fixed +5:30 offset is exact. */
export function istNow(now = new Date()) {
  const t = new Date(now.getTime() + 330 * 60_000);
  return { day: t.toISOString().slice(0, 10), minutes: t.getUTCHours() * 60 + t.getUTCMinutes(), hhmm: t.toISOString().slice(11, 16) };
}

export const hhmmToMin = (s: string) => { const [h, m] = s.split(":").map(Number); return h * 60 + m; };
/** True when `min` falls in [from, to), windows may wrap midnight. */
export const inWindow = (min: number, from: string, to: string) => {
  const f = hhmmToMin(from), t = hhmmToMin(to);
  return f <= t ? min >= f && min < t : min >= f || min < t;
};
