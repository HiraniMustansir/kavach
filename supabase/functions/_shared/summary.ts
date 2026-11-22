import Anthropic from "npm:@anthropic-ai/sdk";

export type DigestStats = {
  day: string; screenMin: number; vsAvg7?: number; pickups?: number; firstUse?: string; lastUse?: string;
  lateNightMin?: number; topApps?: { label: string; min: number; category?: string }[];
  categories?: Record<string, number>; risks?: { cat: string; sev: string; count: number; times?: string[] }[];
  newApps?: { label: string; category?: string }[]; blockedAttempts?: number;
  health?: { degradedMin?: number; offlineMin?: number }; limitedVisibilityMin?: number; partial?: boolean;
};

const hm = (m: number) => (m >= 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m}m`);

/** Deterministic fallback (DIG-3) and the source of the push headline. */
export function templateSummary(name: string, s: DigestStats, lang: "en" | "hi"): string {
  const top = (s.topApps ?? []).slice(0, 2).map((a) => a.label).join(lang === "hi" ? " और " : " and ");
  const alerts = (s.risks ?? []).filter((r) => r.sev === "high" || r.sev === "critical").reduce((n, r) => n + r.count, 0);
  if (lang === "hi") {
    return `${name} ने आज ${hm(s.screenMin)} फ़ोन चलाया${top ? `, ज़्यादातर ${top}` : ""}। ` +
      (alerts ? `${alerts} चेतावनी आई।` : "कोई चिंता की बात नहीं मिली।") +
      (s.lateNightMin ? ` देर रात ${s.lateNightMin} मिनट इस्तेमाल हुआ।` : "");
  }
  return `${name} used the phone for ${hm(s.screenMin)} today${top ? `, mostly ${top}` : ""}. ` +
    (alerts ? `There ${alerts === 1 ? "was 1 alert" : `were ${alerts} alerts`}.` : "Nothing worrying came up.") +
    (s.lateNightMin ? ` ${s.lateNightMin} minutes of late-night use.` : "");
}

const SYSTEM = `You write a warm, factual 3–4 sentence summary of a child's phone day for a parent.
Use ONLY the numbers, app names and categories in the JSON. Never invent apps, numbers or events.
Do not speculate about the child's character, mood or intent. Mention alerts neutrally, with their times.
If there were no alerts, say so. Stay under 80 words. Plain text, no markdown, no greeting.`;

/** LLM summary from aggregates only (no screen content exists in the input). Falls back to the template. */
export async function summarize(name: string, s: DigestStats, lang: "en" | "hi"): Promise<{ text: string; model: string }> {
  const fallback = { text: templateSummary(name, s, lang), model: "template" };
  if (!Deno.env.get("ANTHROPIC_API_KEY")) return fallback;
  try {
    const client = new Anthropic({ timeout: 20_000, maxRetries: 1 });
    const res = await client.messages.create({
      model: "claude-haiku-5-5",
      max_tokens: 1024,
      output_config: { effort: "low" },
      system: SYSTEM,
      messages: [{
        role: "user",
        content: `Language: ${lang === "hi" ? "Hindi (Devanagari)" : "English (India)"}\nChild's name: ${name}\n` +
          `Stats JSON:\n${JSON.stringify(s)}`,
      }],
    } as Anthropic.MessageCreateParamsNonStreaming);
    if (res.stop_reason !== "end_turn") return fallback;
    const text = res.content.flatMap((b) => (b.type === "text" ? [b.text] : [])).join("").trim();
    return validate(text, s) ? { text, model: res.model } : fallback;
  } catch (e) {
    console.error("summary llm failed", e);
    return fallback;
  }
}

/** Reject over-long output or any number that isn't derivable from the stats (no invented figures). */
export function validate(text: string, s: DigestStats): boolean {
  if (!text || text.split(/\s+/).length > 90) return false;
  const allowed = new Set<string>();
  const add = (n: number | undefined) => {
    if (n === undefined) return;
    allowed.add(String(n));
    allowed.add(String(Math.floor(n / 60))); allowed.add(String(n % 60));
  };
  JSON.stringify(s).match(/\d+/g)?.forEach((d) => allowed.add(d));
  add(s.screenMin); add(s.lateNightMin);
  for (const r of s.risks ?? []) add(r.count);
  const nums = text.match(/\d+/g) ?? [];
  return nums.every((n) => allowed.has(n) || Number(n) <= 7); // small counts like "two"/"3 apps" are fine
}
