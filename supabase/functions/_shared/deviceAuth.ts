import { admin, check, hex, HttpError, sha256, unb64, unhex } from "./util.ts";

export type Device = {
  id: string; child_id: string; tier: string; health_state: string; fcm_token: string | null;
  pubkey: string; unpaired_at: string | null;
};

/** Android's SHA256withECDSA emits DER; WebCrypto wants raw r||s (32+32 bytes). */
export function derToRaw(der: Uint8Array): Uint8Array<ArrayBuffer> {
  if (der[0] !== 0x30) throw new HttpError(401, "bad signature");
  let i = 2;
  const out = new Uint8Array(64);
  for (const off of [0, 32]) {
    if (der[i] !== 0x02) throw new HttpError(401, "bad signature");
    let len = der[i + 1]; i += 2;
    let start = i;
    while (len > 32) { start++; len--; } // strip leading 0x00 sign byte
    out.set(der.subarray(start, start + len), off + 32 - len);
    i = start + len;
  }
  return out;
}

/**
 * Verifies X-Device-Id / X-Ts / X-Nonce / X-Sig over "METHOD|route|ts|nonce|sha256hex(body)".
 * Keys are ECDSA P-256 in Android Keystore (hardware-backed, non-exportable) instead of the
 * Ed25519 in design §4.2, which Keystore only supports from API 33.
 */
export async function verifyDevice(req: Request, route: string, body: string): Promise<Device> {
  const id = req.headers.get("x-device-id"), ts = req.headers.get("x-ts"),
    nonce = req.headers.get("x-nonce"), sig = req.headers.get("x-sig");
  if (!id || !ts || !nonce || !sig || !/^[0-9a-f-]{36}$/.test(id) || nonce.length > 64) {
    throw new HttpError(401, "missing signature headers");
  }
  if (Math.abs(Date.now() - Number(ts)) > 5 * 60_000) throw new HttpError(401, "clock skew");

  const dev = check(await admin.from("device")
    .select("id, child_id, tier, health_state, fcm_token, pubkey, unpaired_at").eq("id", id).maybeSingle()) as Device | null;
  if (!dev || dev.unpaired_at) throw new HttpError(401, "unknown device");

  const key = await crypto.subtle.importKey("spki", unhex(dev.pubkey), { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  const msg = `${req.method}|${route}|${ts}|${nonce}|${hex(await sha256(body))}`;
  const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, derToRaw(unb64(sig)), new TextEncoder().encode(msg));
  if (!ok) throw new HttpError(401, "bad signature");

  // Insert fails on a reused nonce → replay.
  const { error } = await admin.from("request_nonce").insert({ device_id: id, nonce });
  if (error) throw new HttpError(401, "replayed request");
  return dev;
}
