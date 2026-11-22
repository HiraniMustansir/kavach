// CLS-8: sign and upload a rule/model bundle as a draft. Roll it out from the admin console.
//
//   SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... KAVACH_BUNDLE_KEY=~/.kavach-keys/bundle-signing.pem \
//     deno run -A tools/bundle.ts <dir> <version>
//
// <dir> holds any of ALLOWED below. The manifest is signed with ECDSA P-256 / SHA-256 (DER, like Android's
// SHA256withECDSA); the app verifies it against the public key pinned in BundleManager.kt.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

export const ALLOWED = ["lexicon.json", "catalog.json", "vision_gate.tflite", "vision_gate.json"];

/** WebCrypto gives raw r||s; Android verifies DER. */
export function rawToDer(raw: Uint8Array): Uint8Array {
  const int = (b: Uint8Array) => {
    let i = 0;
    while (i < b.length - 1 && b[i] === 0) i++;
    const v = b.subarray(i);
    return v[0] & 0x80 ? [0x02, v.length + 1, 0, ...v] : [0x02, v.length, ...v];
  };
  const body = [...int(raw.subarray(0, 32)), ...int(raw.subarray(32))];
  return new Uint8Array([0x30, body.length, ...body]);
}

const hex = (b: ArrayBuffer) => Array.from(new Uint8Array(b), (x) => x.toString(16).padStart(2, "0")).join("");
const b64 = (b: Uint8Array) => btoa(String.fromCharCode(...b));

export async function signManifest(manifestText: string, pkcs8Pem: string): Promise<string> {
  const der = Uint8Array.from(atob(pkcs8Pem.replace(/-----[^-]+-----|\s/g, "")), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const raw = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(manifestText)));
  return b64(rawToDer(raw));
}

if (import.meta.main) {
  const [dir, version] = Deno.args;
  if (!dir || !/^[0-9A-Za-z._-]{3,40}$/.test(version ?? "")) {
    console.error("usage: deno run -A tools/bundle.ts <dir> <version>   (version: letters, digits, . _ -)");
    Deno.exit(1);
  }
  const keyPath = (Deno.env.get("KAVACH_BUNDLE_KEY") ?? "").replace(/^~/, Deno.env.get("HOME") ?? "~");
  const pem = await Deno.readTextFile(keyPath);
  const files: { name: string; sha256: string; size: number }[] = [];
  const blobs: Record<string, Uint8Array> = {};
  for (const name of ALLOWED) {
    const data = await Deno.readFile(`${dir}/${name}`).catch(() => null);
    if (!data) continue;
    if (name.endsWith(".json")) JSON.parse(new TextDecoder().decode(data)); // refuse to ship broken JSON
    blobs[name] = data;
    files.push({ name, sha256: hex(await crypto.subtle.digest("SHA-256", data)), size: data.length });
  }
  if (!files.length) throw new Error(`no bundle files in ${dir} (expected any of ${ALLOWED.join(", ")})`);
  const manifestText = JSON.stringify({ version, created: new Date().toISOString(), files });
  const signature = await signManifest(manifestText, pem);

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  for (const [name, data] of Object.entries(blobs)) {
    const { error } = await sb.storage.from("bundles").upload(`${version}/${name}`, data, { upsert: false });
    if (error) throw new Error(`upload ${name}: ${error.message}`);
  }
  const { error } = await sb.from("rule_bundle").insert({ version, manifest: JSON.parse(manifestText), manifest_text: manifestText, signature });
  if (error) throw error;
  console.log(`bundle ${version} uploaded as draft: ${files.map((f) => f.name).join(", ")}. Roll it out in the admin console.`);
}
