// deno test -A supabase/functions/tests
import { assert, assertEquals } from "jsr:@std/assert@1";

Deno.env.set("SUPABASE_URL", "http://localhost:54321");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test");
const { derToRaw } = await import("../_shared/deviceAuth.ts");
const { inWindow, istNow } = await import("../_shared/util.ts");
const { wants } = await import("../_shared/notify.ts");
const { validate, templateSummary } = await import("../_shared/summary.ts");

/** raw r||s → DER, the way Android's SHA256withECDSA emits it (with 0x00 pad on high-bit integers). */
function rawToDer(raw: Uint8Array): Uint8Array {
  const int = (b: Uint8Array) => {
    let i = 0;
    while (i < b.length - 1 && b[i] === 0) i++;
    const v = b.subarray(i);
    return v[0] & 0x80 ? [0x02, v.length + 1, 0, ...v] : [0x02, v.length, ...v];
  };
  const body = [...int(raw.subarray(0, 32)), ...int(raw.subarray(32))];
  return new Uint8Array([0x30, body.length, ...body]);
}

Deno.test("DER signatures from Android verify after conversion", async () => {
  const kp = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  for (let i = 0; i < 50; i++) { // many runs to hit short-r / high-bit cases
    const msg = new TextEncoder().encode(`POST|events|${i}`);
    const raw = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, kp.privateKey, msg));
    const back = derToRaw(rawToDer(raw));
    assertEquals(back, raw);
    assert(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, kp.publicKey, back, msg));
  }
});

Deno.test("quiet-hour windows wrap midnight", () => {
  assert(inWindow(23 * 60, "22:00", "07:00"));
  assert(inWindow(6 * 60, "22:00", "07:00"));
  assert(!inWindow(12 * 60, "22:00", "07:00"));
  assert(inWindow(9 * 60, "08:00", "14:00"));
  assert(!inWindow(14 * 60, "08:00", "14:00"));
});

Deno.test("IST conversion", () => {
  assertEquals(istNow(new Date("2026-11-22T18:45:00Z")), { day: "2026-11-23", minutes: 15, hhmm: "00:15" });
});

Deno.test("critical bypasses quiet hours and category opt-outs", () => {
  const r = { guardian_id: "g", role: "guardian", lang: "en" as const, tokens: [],
    prefs: { categories: ["SEX"], quietFrom: "22:00", quietTo: "07:00" } };
  assert(!wants(r, "GAMB", false, 12 * 60));
  assert(wants(r, "SEX", false, 12 * 60));
  assert(!wants(r, "SEX", false, 23 * 60));
  assert(wants(r, "SELF", true, 23 * 60));
  assert(wants(r, "INFO", false, 12 * 60)); // digest still arrives with a narrowed category list
  assert(!wants({ ...r, prefs: { ...r.prefs, criticalBypassQuiet: false } }, "SELF", true, 23 * 60));
});

Deno.test("summary validator rejects invented numbers", () => {
  const s = { day: "2026-11-21", screenMin: 190, topApps: [{ label: "YouTube", min: 72 }], risks: [{ cat: "GORE", sev: "high", count: 1, times: ["16:12"] }] };
  assert(validate("Aarav spent 3h 10m on the phone, mostly YouTube. One alert at 16:12.", s));
  assert(!validate("Aarav spent 5h 45m on the phone.", s));
  assert(templateSummary("Aarav", s, "en").includes("3h 10m"));
});
