"use client";
import { useCallback, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/utils/supabase/client";

type Metrics = {
  families: number; children: number; openReports: number;
  devices: Record<string, number> | null; devicesByOem: Record<string, number> | null;
  alertsByDay: { day: string; severity: string; n: number }[];
  alertsByCategory: Record<string, number> | null;
  feedback: { category: string; useful: number; not_a_problem: number }[];
  bundleVersions: Record<string, number> | null;
};
type Bundle = { version: string; files: { name: string; size: number }[]; rollout_pct: number; status: string; created_at: string };
type Report = {
  id: number; family_id: string | null; reporter: string; message: string | null; status: string; admin_note: string | null;
  created_at: string; family_suspended: boolean; children: number; devices: number;
};

const supabase = createClient();

/** Internal console (ADM-1..3). Every call is an admin-only RPC; the server refuses non-admins. */
export default function Admin() {
  const router = useRouter();
  const [tab, setTab] = useState<"metrics" | "bundles" | "reports">("metrics");
  const [error, setError] = useState("");
  const [ready, setReady] = useState(false);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => (data.session ? setReady(true) : router.replace("/login")));
  }, [router]);

  if (!ready) return <main className="muted">Loading…</main>;
  return (
    <main>
      <nav>
        <strong style={{ marginRight: 12 }}>Kavach Admin</strong>
        {(["metrics", "bundles", "reports"] as const).map((t) => (
          <button key={t} className={tab === t ? "on" : ""} onClick={() => { setError(""); setTab(t); }}>{t[0].toUpperCase() + t.slice(1)}</button>
        ))}
        <span style={{ flex: 1 }} />
        <button onClick={() => supabase.auth.signOut().then(() => router.replace("/login"))}>Sign out</button>
      </nav>
      {error && <p className="err card">{error}</p>}
      {tab === "metrics" && <MetricsTab onError={setError} />}
      {tab === "bundles" && <BundlesTab onError={setError} />}
      {tab === "reports" && <ReportsTab onError={setError} />}
    </main>
  );
}

function useRpc<T>(fn: string, onError: (e: string) => void, args?: Record<string, unknown>) {
  const [data, setData] = useState<T | null>(null);
  const [tick, setTick] = useState(0);
  const key = JSON.stringify(args ?? {});
  useEffect(() => {
    supabase.rpc(fn, JSON.parse(key)).then(({ data, error }) => {
      if (error) onError(error.code === "42501" ? "This account is not an admin." : error.message);
      else setData(data as T);
    });
  }, [fn, key, onError, tick]);
  const reload = useCallback(() => setTick((t) => t + 1), []);
  return [data, reload] as const;
}

function Table({ rows }: { rows: Record<string, number> | null }) {
  const entries = Object.entries(rows ?? {}).sort((a, b) => b[1] - a[1]);
  if (!entries.length) return <p className="muted">No data.</p>;
  return <table><tbody>{entries.map(([k, v]) => <tr key={k}><td>{k}</td><td>{v}</td></tr>)}</tbody></table>;
}

function MetricsTab({ onError }: { onError: (e: string) => void }) {
  const [days, setDays] = useState(14);
  const [m] = useRpc<Metrics>("admin_metrics", onError, { p_days: days });
  if (!m) return <p className="muted">Loading…</p>;
  const byDay = new Map<string, Record<string, number>>();
  for (const r of m.alertsByDay) byDay.set(r.day, { ...(byDay.get(r.day) ?? {}), [r.severity]: r.n });
  return (
    <>
      <div className="card">
        Period:{" "}
        <select value={days} onChange={(e) => setDays(Number(e.target.value))}>
          {[7, 14, 30, 90].map((d) => <option key={d} value={d}>{d} days</option>)}
        </select>
      </div>
      <div className="grid">
        <div className="card stat"><span className="muted">Families</span><b>{m.families}</b></div>
        <div className="card stat"><span className="muted">Children</span><b>{m.children}</b></div>
        <div className="card stat"><span className="muted">Paired devices</span><b>{Object.values(m.devices ?? {}).reduce((a, b) => a + b, 0)}</b></div>
        <div className="card stat"><span className="muted">Open misuse reports</span><b>{m.openReports}</b></div>
      </div>
      <div className="grid">
        <div className="card"><h3>Device health</h3><Table rows={m.devices} /></div>
        <div className="card"><h3>Devices by brand</h3><Table rows={m.devicesByOem} /></div>
        <div className="card"><h3>Rule/model versions</h3><Table rows={m.bundleVersions} /></div>
      </div>
      <div className="card">
        <h3>Alerts per day</h3>
        <table>
          <thead><tr><th>Day</th><th>Critical</th><th>High</th><th>Medium</th><th>Low</th></tr></thead>
          <tbody>{[...byDay.entries()].map(([d, s]) => (
            <tr key={d}><td>{d}</td><td>{s.critical ?? 0}</td><td>{s.high ?? 0}</td><td>{s.medium ?? 0}</td><td>{s.low ?? 0}</td></tr>
          ))}</tbody>
        </table>
      </div>
      <div className="grid">
        <div className="card"><h3>Alerts by category</h3><Table rows={m.alertsByCategory} /></div>
        <div className="card">
          <h3>Parent feedback (precision)</h3>
          <table>
            <thead><tr><th>Category</th><th>Useful</th><th>Not a problem</th><th>Precision</th></tr></thead>
            <tbody>{m.feedback.map((f) => (
              <tr key={f.category}><td>{f.category}</td><td>{f.useful}</td><td>{f.not_a_problem}</td>
                <td>{Math.round((100 * f.useful) / Math.max(1, f.useful + f.not_a_problem))}%</td></tr>
            ))}</tbody>
          </table>
        </div>
      </div>
    </>
  );
}

function BundlesTab({ onError }: { onError: (e: string) => void }) {
  const [bundles, reload] = useRpc<Bundle[]>("admin_bundles", onError);
  async function set(version: string, status: string, rollout: number) {
    if (status === "active" && rollout === 100 && !confirm(`Roll ${version} out to every device?`)) return;
    const { error } = await supabase.rpc("admin_set_bundle", { p_version: version, p_status: status, p_rollout: rollout });
    if (error) onError(error.message); else reload();
  }
  return (
    <div className="card">
      <h3>Rule &amp; model bundles</h3>
      <p className="muted">Upload with <code>deno run -A tools/bundle.ts &lt;dir&gt; &lt;version&gt;</code>, then stage it here. Revoking sends devices back to the rules built into the app.</p>
      {!bundles ? <p className="muted">Loading…</p> : !bundles.length ? <p className="muted">No bundles yet.</p> : (
        <table>
          <thead><tr><th>Version</th><th>Files</th><th>Status</th><th>Rollout</th><th /></tr></thead>
          <tbody>{bundles.map((b) => (
            <tr key={b.version}>
              <td>{b.version}<div className="muted">{new Date(b.created_at).toLocaleString()}</div></td>
              <td>{b.files.map((f) => f.name).join(", ")}</td>
              <td>{b.status}</td>
              <td>{b.rollout_pct}%</td>
              <td style={{ whiteSpace: "nowrap" }}>
                {[5, 25, 100].map((p) => <button key={p} onClick={() => set(b.version, "active", p)}>{p}%</button>)}{" "}
                <button onClick={() => set(b.version, "revoked", 0)}>Revoke</button>
              </td>
            </tr>
          ))}</tbody>
        </table>
      )}
    </div>
  );
}

function ReportsTab({ onError }: { onError: (e: string) => void }) {
  const [reports, reload] = useRpc<Report[]>("admin_reports", onError);
  const [notes, setNotes] = useState<Record<number, string>>({});
  async function resolve(r: Report, status: string, suspend: boolean) {
    if (suspend && !confirm("Suspend this family? All their devices will be released and they can't make changes.")) return;
    const { error } = await supabase.rpc("admin_resolve_report", { p_id: r.id, p_status: status, p_note: notes[r.id] ?? r.admin_note, p_suspend: suspend });
    if (error) onError(error.message); else reload();
  }
  return (
    <div className="card">
      <h3>Misuse reports</h3>
      <p className="muted">Only the report text and family size are shown. Alerts and usage stay private (ADM-2).</p>
      {!reports ? <p className="muted">Loading…</p> : !reports.length ? <p className="muted">No reports.</p> : (
        <table>
          <thead><tr><th>When</th><th>From</th><th>Message</th><th>Family</th><th>Status / note</th><th /></tr></thead>
          <tbody>{reports.map((r) => (
            <tr key={r.id}>
              <td>{new Date(r.created_at).toLocaleString()}</td>
              <td>{r.reporter === "child_device" ? "Child phone" : "Guardian"}</td>
              <td style={{ maxWidth: 320 }}>{r.message ?? <span className="muted">—</span>}</td>
              <td>{r.children} children, {r.devices} devices{r.family_suspended && <div className="err">suspended</div>}</td>
              <td>
                {r.status}
                <textarea rows={2} defaultValue={r.admin_note ?? ""} placeholder="Note" onChange={(e) => setNotes({ ...notes, [r.id]: e.target.value })} />
              </td>
              <td style={{ whiteSpace: "nowrap" }}>
                <button onClick={() => resolve(r, "reviewing", false)}>Reviewing</button>{" "}
                <button onClick={() => resolve(r, "dismissed", false)}>Dismiss</button>{" "}
                <button onClick={() => resolve(r, "actioned", true)} disabled={r.family_suspended || !r.family_id}>Suspend family</button>
              </td>
            </tr>
          ))}</tbody>
        </table>
      )}
    </div>
  );
}
