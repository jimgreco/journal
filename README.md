# Journal

A private journal for one person. Write an entry or speak it; the iPhone
transcribes speech on the device and keeps only the text. Entries feed the
Sunday weekly review unless they are marked private.

```
 iPhone app (SwiftUI)                     journal server (EC2, journal.jim-greco.com)
 ┌──────────────────────────────┐ HTTPS  ┌──────────────────────────────────────────┐
 │ Face ID lock                 │ ─────► │ Apple or Google sign-in, one account     │
 │ on-device speech-to-text     │        │ AES-256-GCM per entry ──► Postgres       │
 │ offline outbox, sync         │        │ GET /api/weekly-summary (own token)      │
 └──────────────────────────────┘        └──────────────────────────────────────────┘
                                                        ▲  Sunday, non-private entries only
                                                weekly-review routine
```

## Quick capture

- **Speak Entry** and **Write Entry** are App Shortcuts: assign one to the
  Action Button (Settings → Action Button → Shortcut → Private Notes), say
  "Speak an entry in Private Notes" to Siri, or find them in Spotlight. Each
  opens the app, asks for Face ID and lands in a new entry.
- A **daily reminder** (Account → Reminder, off by default) is a local
  notification with fixed text; tapping it starts a voice entry.
- Returning to the app asks for Face ID right away, without tapping Unlock.

## Privacy model

| Where | What is stored | Protection |
|---|---|---|
| iPhone | entries and an outbox of unsynced changes | complete file protection (unreadable while locked), excluded from backups, Face ID / passcode lock, app-switcher cover |
| iPhone | session tokens | Keychain, this device only, while unlocked |
| Microphone audio | nothing | streamed into Apple's on-device recognizer (`requiresOnDeviceRecognition`); never written or uploaded |
| Server database | ciphertext of text, mood and tags; date, source, private flag | AES-256-GCM, key only in the app's runtime env, bound to user and entry id. Backups hold ciphertext only. |
| Weekly review | non-private entries of one week, plus counts | its own token (SHA-256 stored), read-only, private entries counted but never decrypted |

Deleting an entry wipes its ciphertext immediately and keeps only a tombstone
for sync. Deleting the account removes every row.

## Layout

- `server/` Node 22 API (`src/app.js` routes, `src/store.js` memory and Postgres
  stores, `src/crypto.js` encryption, `src/weekly.js` weekly summary), `db/` SQL
  migrations, `test/`.
- `Journal/` iPhone app; `JournalTests/` unit tests. `project.yml` is the
  XcodeGen spec; `Journal.xcodeproj` is generated from it and committed.
- `deploy/` database provisioning and the activation runbook.

## Run locally

```bash
cd server && npm ci
JOURNAL_DATA_KEYS="1:$(openssl rand -base64 32)" SESSION_SECRET=$(openssl rand -hex 32) \
  JOURNAL_DEV_SIGNIN=1 npm start          # in-memory store on :8791
```

Open `Journal.xcodeproj`, run on a simulator and use **Local dev sign in**
(debug builds only). Launch with `-JournalSkipLock` to skip the Face ID lock in
the simulator (debug builds only).

## Tests

```bash
cd server && npm test                                     # memory store
JOURNAL_TEST_DATABASE_URL=postgresql://postgres@127.0.0.1:5432/journal_test npm test   # + Postgres
xcodebuild -project Journal.xcodeproj -scheme Journal -destination 'platform=iOS Simulator,name=iPhone 17' test
```

## Server configuration

| Variable | Meaning |
|---|---|
| `DATABASE_URL` | `journal_runtime` connection. Required in production. |
| `JOURNAL_DATA_KEYS` | `<id>:<base64 32 bytes>[,…]`. The first key encrypts; all decrypt (rotation). Losing it loses every entry: keep a copy offline. |
| `SESSION_SECRET` | ≥ 32 chars, signs 15-minute access tokens. |
| `APPLE_BUNDLE_ID` | `com.jimgreco.journal`, the Apple identity-token audience. |
| `GOOGLE_CLIENT_ID` | The iOS app's Google OAuth client id, the Google ID-token audience. Unset = Google sign-in off. |
| `ALLOWED_EMAILS` / `ALLOWED_APPLE_SUBS` | Who may sign in (a verified email from Apple or Google, or an Apple sub). One is required in production. Apple and Google sign-ins with the same verified email reach the same journal. |
| `WEEKLY_SUMMARY_TOKEN_SHA256`, `WEEKLY_SUMMARY_EMAIL` | Weekly review access; the route is a 404 until both are set. |
| `TRUST_PROXY_HOPS` | `1` behind nginx-proxy, for rate-limit IPs. |

## Weekly summary

`GET /api/weekly-summary?week=<Monday>` follows weekly-review's
`docs/weekly-summary-contract.md` with `"app": "journal"`. `data`:

```json
{
  "status": "ok",
  "current":  { "entries": 5, "privateEntries": 1, "voiceEntries": 3, "daysWithEntries": 4,
                "sharedWords": 812, "avgMood": 3.5, "topTags": [{ "tag": "work", "count": 3 }] },
  "previous": { "entries": 2, "privateEntries": 0, "voiceEntries": 1, "daysWithEntries": 2, "sharedWords": 240 },
  "entries": [ { "date": "2026-11-10", "weekday": "Tue", "createdAt": "…", "source": "voice",
                 "mood": 3, "tags": ["work"], "words": 140, "text": "…", "truncated": false } ],
  "truncated": false
}
```

Text is capped at 6,000 characters per entry and 60,000 per week.
`{"status":"no-account"}` when the email has no account.

## Release

Standard: `jimgreco/consolidated-deploy` `docs/APP_STANDARD.md`. First
activation is in `deploy/RUNBOOK.md`.
