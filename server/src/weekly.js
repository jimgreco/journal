import { open } from "./crypto.js";

// Read-only weekly summary for the weekly-review routine.
// Private entries are counted but their content is never decrypted here.

export const WEEKLY_LIMITS = { entryChars: 6_000, totalChars: 60_000 };
const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

export function isMonday(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const date = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(date.getTime()) && date.toISOString().slice(0, 10) === value && date.getUTCDay() === 1;
}

function addDays(dateKey, days) {
  const date = new Date(`${dateKey}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + days);
  return date.toISOString().slice(0, 10);
}

function words(text) {
  return (String(text).match(/\S+/g) || []).length;
}

function tally(rows, decrypted) {
  return {
    entries: rows.length,
    privateEntries: rows.filter((r) => r.private).length,
    voiceEntries: rows.filter((r) => r.source === "voice").length,
    daysWithEntries: new Set(rows.map((r) => r.entryDate)).size,
    sharedWords: decrypted.reduce((sum, e) => sum + words(e.text), 0)
  };
}

export async function weeklySummary({ store, keys, email, monday }) {
  const user = await store.findUserByEmail(email);
  if (!user) return { status: "no-account" };

  const sunday = addDays(monday, 6);
  const prevMonday = addDays(monday, -7);
  const [rows, prevRows] = await Promise.all([
    store.liveEntriesBetween(user.id, monday, sunday),
    store.liveEntriesBetween(user.id, prevMonday, addDays(monday, -1))
  ]);

  const decrypt = (list) => list.filter((r) => !r.private).map((r) => ({ row: r, ...open(keys, r.userId, r.id, r) }));
  const shared = decrypt(rows);
  const prevShared = decrypt(prevRows);

  let budget = WEEKLY_LIMITS.totalChars;
  let truncated = false;
  const entries = shared.map(({ row, text, mood, tags }) => {
    let body = text.length > WEEKLY_LIMITS.entryChars ? text.slice(0, WEEKLY_LIMITS.entryChars) : text;
    if (body.length > budget) body = body.slice(0, Math.max(budget, 0));
    budget -= body.length;
    const cut = body.length < text.length;
    truncated ||= cut;
    return {
      date: row.entryDate,
      weekday: WEEKDAYS[new Date(`${row.entryDate}T00:00:00Z`).getUTCDay()],
      createdAt: row.createdAt,
      source: row.source,
      mood: mood ?? null,
      tags: tags ?? [],
      words: words(text),
      text: body,
      truncated: cut
    };
  });

  const moods = shared.map((e) => e.mood).filter((m) => Number.isInteger(m));
  const tagCounts = {};
  for (const e of shared) for (const t of e.tags ?? []) tagCounts[t.toLowerCase()] = (tagCounts[t.toLowerCase()] || 0) + 1;

  return {
    status: "ok",
    current: {
      ...tally(rows, shared),
      avgMood: moods.length ? Math.round((moods.reduce((a, b) => a + b, 0) / moods.length) * 10) / 10 : null,
      topTags: Object.entries(tagCounts).sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).slice(0, 8)
        .map(([tag, count]) => ({ tag, count }))
    },
    previous: tally(prevRows, prevShared),
    entries,
    truncated
  };
}
