// Parent API (JWT). Reads go straight to Postgres under RLS; this function holds the writes that
// need the service role, cross-row atomicity, or a push to the child device.
import { admin, b64, check, hex, HttpError, json, must, serve, sha256 } from "../_shared/util.ts";
import { wakeDevice } from "../_shared/push.ts";

const PIN_ITER = 120_000;
const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"; // no 0/O/1/I/L
const POLICY_MAX_BYTES = 64_000;

serve(async (req, route) => {
  const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer /, "");
  const { data } = await admin.auth.getUser(jwt);
  const uid = must(data.user?.id, 401, "sign in required");
  const b = req.method === "POST" ? await req.json().catch(() => ({})) : {};
  switch (route) {
    case "pair-start": return pairStart(uid, b);
    case "save-policy": return savePolicy(uid, b);
    case "command": return command(uid, b);
    case "set-pin": return setPin(uid, b);
    case "decide-request": return decideRequest(uid, b);
    case "export": return exportData(uid);
    case "delete-account": return deleteAccount(uid);
    default: throw new HttpError(404, "no such route");
  }
});

async function roleForChild(uid: string, childId: unknown, roles = ["owner", "guardian"]) {
  must(typeof childId === "string" && /^[0-9a-f-]{36}$/.test(childId), 400, "childId required");
  const c = check(await admin.from("child").select("family_id").eq("id", childId).maybeSingle()) as { family_id: string } | null;
  const m = c && check(await admin.from("family_member").select("role")
    .eq("family_id", c.family_id).eq("guardian_id", uid).maybeSingle()) as { role: string } | null;
  must(m && roles.includes(m.role), 403, "not allowed for this child");
  return c!.family_id;
}

async function ownerFamily(uid: string) {
  const m = check(await admin.from("family_member").select("family_id, role").eq("guardian_id", uid)) as { family_id: string; role: string }[];
  return m;
}

// PAIR-1/2: one-time 10-char code, 10-minute TTL. Tier A also gets the Android provisioning JSON.
async function pairStart(uid: string, b: { childId?: string; tier?: string }) {
  await roleForChild(uid, b.childId);
  must(["A", "B", "C"].includes(b.tier ?? ""), 400, "tier must be A, B or C");
  // Consent before any child data is processed (VPC-1).
  const consent = check(await admin.from("consent_record").select("id").eq("child_id", b.childId!).is("revoked_at", null).limit(1));
  must((consent as unknown[]).length, 409, "record parental consent first");

  const rnd = crypto.getRandomValues(new Uint8Array(10));
  const code = Array.from(rnd, (x) => CODE_ALPHABET[x % CODE_ALPHABET.length]).join("");
  const expires = new Date(Date.now() + 10 * 60_000).toISOString();
  check(await admin.from("pairing_token").insert({
    token_hash: "\\x" + hex(await sha256(code)), child_id: b.childId, tier: b.tier, created_by: uid, expires_at: expires,
  }));

  let provisioning: Record<string, unknown> | null = null;
  if (b.tier === "A") {
    const apk = must(Deno.env.get("DPC_APK_URL"), 500, "DPC_APK_URL not configured");
    provisioning = {
      "android.app.extra.PROVISIONING_DEVICE_ADMIN_COMPONENT_NAME": "app.kavach/app.kavach.agent.admin.KavachAdminReceiver",
      "android.app.extra.PROVISIONING_DEVICE_ADMIN_PACKAGE_DOWNLOAD_LOCATION": apk,
      "android.app.extra.PROVISIONING_DEVICE_ADMIN_SIGNATURE_CHECKSUM": must(Deno.env.get("DPC_SIGNATURE_CHECKSUM"), 500, "DPC_SIGNATURE_CHECKSUM not configured"),
      "android.app.extra.PROVISIONING_LEAVE_ALL_SYSTEM_APPS_ENABLED": true,
      "android.app.extra.PROVISIONING_ADMIN_EXTRAS_BUNDLE": { pairing_token: code },
    };
  }
  return json({ code, qr: provisioning ? JSON.stringify(provisioning) : `KAVACH:${code}`, expiresAt: expires });
}

async function nextPolicy(childId: string, body: Record<string, unknown>, uid: string) {
  // Retry on a version race between two guardians saving at once.
  for (let i = 0; i < 3; i++) {
    const cur = check(await admin.from("policy").select("version, body").eq("child_id", childId)
      .order("version", { ascending: false }).limit(1).maybeSingle()) as { version: number; body: Record<string, unknown> } | null;
    const merged = { ...body, parentPin: body.parentPin ?? cur?.body?.parentPin, version: (cur?.version ?? 0) + 1 };
    const { error } = await admin.from("policy").insert({ child_id: childId, version: merged.version, body: merged, updated_by: uid });
    if (!error) return merged.version as number;
    if (error.code !== "23505") throw error;
  }
  throw new HttpError(409, "policy changed concurrently, retry");
}

async function wakeChildDevices(childId: string, reason: string) {
  const devs = check(await admin.from("device").select("id, fcm_token").eq("child_id", childId).is("unpaired_at", null)) as
    { id: string; fcm_token: string | null }[];
  await Promise.all(devs.map((d) => wakeDevice(d.fcm_token, reason)));
  return devs;
}

// Policy doc (design §4.3). The parent PIN hash is server-owned and never taken from the client.
async function savePolicy(uid: string, b: { childId?: string; body?: Record<string, unknown> }) {
  await roleForChild(uid, b.childId);
  const body = must(b.body && typeof b.body === "object" && !Array.isArray(b.body) ? { ...b.body } : null, 400, "body must be an object");
  must(JSON.stringify(body).length <= POLICY_MAX_BYTES, 413, "policy too large");
  delete body.parentPin;
  const version = await nextPolicy(b.childId!, body, uid);
  await wakeChildDevices(b.childId!, "sync_policy");
  return json({ version });
}

const KINDS = ["lock", "unlock", "pause", "resume", "add_time", "unpair"];

// CTL-6, CTL-8, PAIR-6 remote unpair. Queued for the heartbeat poll and pushed for ≤10 s delivery.
async function command(uid: string, b: { childId?: string; kind?: string; args?: Record<string, unknown> }) {
  await roleForChild(uid, b.childId);
  must(KINDS.includes(b.kind ?? ""), 400, "bad kind");
  const args: Record<string, unknown> = {};
  if (b.kind === "pause" || b.kind === "add_time") {
    const m = Number(b.args?.minutes);
    must(Number.isInteger(m) && m >= 1 && m <= 24 * 60, 400, "minutes 1-1440");
    args.minutes = m;
  }
  const devs = check(await admin.from("device").select("id, fcm_token").eq("child_id", b.childId!).is("unpaired_at", null)) as
    { id: string; fcm_token: string | null }[];
  must(devs.length, 409, "no paired device");
  check(await admin.from("device_command").insert(devs.map((d) => ({ device_id: d.id, kind: b.kind, args, created_by: uid }))));
  if (b.kind === "unpair") {
    // Online phones release themselves via the command; one silent for a day (lost/broken/reset) is removed now.
    const dayAgo = new Date(Date.now() - 86_400_000).toISOString();
    await admin.from("device").update({ unpaired_at: new Date().toISOString() })
      .in("id", devs.map((d) => d.id)).or(`last_heartbeat.is.null,last_heartbeat.lt.${dayAgo}`);
  }
  await Promise.all(devs.map((d) => wakeDevice(d.fcm_token, "command")));
  await admin.from("audit_log").insert({ actor: uid, action: `command.${b.kind}`, target: b.childId, meta: args });
  return json({ ok: true, devices: devs.length });
}

// ACC-8: 6-digit parent PIN, PBKDF2-SHA256 hashed here, verified offline on the child device.
async function setPin(uid: string, b: { pin?: string }) {
  must(typeof b.pin === "string" && /^\d{6}$/.test(b.pin), 400, "PIN must be 6 digits");
  must(!/^(\d)\1{5}$/.test(b.pin!) && !["123456", "654321"].includes(b.pin!), 400, "PIN too easy to guess");
  const fams = (await ownerFamily(uid)).filter((m) => m.role !== "viewer");
  must(fams.length, 403, "no family");
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(b.pin), "PBKDF2", false, ["deriveBits"]);
  const hash = new Uint8Array(await crypto.subtle.deriveBits({ name: "PBKDF2", salt, iterations: PIN_ITER, hash: "SHA-256" }, key, 256));
  const parentPin = { salt: b64(salt), hash: b64(hash), iter: PIN_ITER };

  const children = check(await admin.from("child").select("id").in("family_id", fams.map((f) => f.family_id))) as { id: string }[];
  for (const c of children) {
    const cur = check(await admin.from("policy").select("body").eq("child_id", c.id)
      .order("version", { ascending: false }).limit(1).maybeSingle()) as { body: Record<string, unknown> } | null;
    await nextPolicy(c.id, { ...(cur?.body ?? {}), parentPin }, uid);
    await wakeChildDevices(c.id, "sync_policy");
  }
  await admin.from("audit_log").insert({ actor: uid, action: "pin.set", target: null, meta: { children: children.length } });
  return json({ ok: true });
}

async function decideRequest(uid: string, b: { requestId?: number; approve?: boolean }) {
  const r = check(await admin.from("child_request").select("id, child_id, kind, minutes, app_pkg, status")
    .eq("id", must(b.requestId, 400, "requestId required")).maybeSingle()) as
    { id: number; child_id: string; kind: string; minutes: number | null; app_pkg: string | null; status: string } | null;
  must(r, 404, "request not found");
  await roleForChild(uid, r!.child_id);
  must(r!.status === "pending", 409, "already decided");
  const status = b.approve ? "approved" : "denied";
  check(await admin.from("child_request").update({ status, decided_by: uid, decided_at: new Date().toISOString() }).eq("id", r!.id));
  if (b.approve && r!.kind === "more_time") {
    return command(uid, { childId: r!.child_id, kind: "add_time", args: { minutes: r!.minutes ?? 15 } });
  }
  if (b.approve && r!.kind === "app" && r!.app_pkg) {
    const cur = check(await admin.from("policy").select("body").eq("child_id", r!.child_id)
      .order("version", { ascending: false }).limit(1).maybeSingle()) as { body: Record<string, any> } | null;
    const body = structuredClone(cur?.body ?? {});
    body.blocked = { ...(body.blocked ?? {}), apps: (body.blocked?.apps ?? []).filter((p: string) => p !== r!.app_pkg) };
    body.allow = { ...(body.allow ?? {}), apps: [...new Set([...(body.allow?.apps ?? []), r!.app_pkg])] };
    await nextPolicy(r!.child_id, body, uid);
    await wakeChildDevices(r!.child_id, "sync_policy");
  }
  return json({ ok: true, status });
}

// ACC-9 / DPDP rights: export everything we hold about the caller's families.
async function exportData(uid: string) {
  const fams = (await ownerFamily(uid)).map((f) => f.family_id);
  const children = check(await admin.from("child").select("*").in("family_id", fams)) as { id: string }[];
  const ids = children.map((c) => c.id);
  const devices = check(await admin.from("device").select("id, child_id, platform, model, oem, os_version, tier, paired_at, unpaired_at").in("child_id", ids));
  const [guardian, family, members, consent, policies, events, digests, requests] = await Promise.all([
    admin.from("guardian").select("*").eq("id", uid),
    admin.from("family").select("*").in("id", fams),
    admin.from("family_member").select("*").in("family_id", fams),
    admin.from("consent_record").select("*").in("family_id", fams),
    admin.from("policy").select("child_id, version, body, updated_at").in("child_id", ids),
    admin.from("risk_event").select("*").in("child_id", ids).limit(50_000),
    admin.from("daily_digest").select("*").in("child_id", ids),
    admin.from("child_request").select("*").in("child_id", ids),
  ]);
  await admin.from("audit_log").insert({ actor: uid, action: "account.export", target: null, meta: {} });
  const strip = (p: { body: Record<string, unknown> }) => ({ ...p, body: { ...p.body, parentPin: undefined } });
  return json({
    exportedAt: new Date().toISOString(), guardian: guardian.data, families: family.data, members: members.data,
    children, devices, consent: consent.data, policies: (policies.data ?? []).map(strip),
    events: events.data, digests: digests.data, requests: requests.data,
  });
}

// ACC-9: owners delete their families (cascades children/devices/events); then the login itself.
async function deleteAccount(uid: string) {
  const mine = await ownerFamily(uid);
  const owned = mine.filter((m) => m.role === "owner").map((m) => m.family_id);
  if (owned.length) {
    const devs = check(await admin.from("device").select("id, fcm_token, child!inner(family_id)").in("child.family_id", owned)) as
      { id: string; fcm_token: string | null }[];
    check(await admin.from("family").delete().in("id", owned));
    // Device rows are gone now, so the agent releases itself when the server stops recognising
    // its key (see Orphan handling in SyncClient.kt); the push just makes that immediate.
    await Promise.all(devs.map((d) => wakeDevice(d.fcm_token, "account_deleted")));
  }
  await admin.from("audit_log").insert({ actor: uid, action: "account.delete", target: null, meta: { families: owned.length } });
  const { error } = await admin.auth.admin.deleteUser(uid);
  if (error) throw error;
  return json({ ok: true });
}
