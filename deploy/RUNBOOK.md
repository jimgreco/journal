# Turning on Journal

All steps are the owner's. Nothing here prints a secret; keep it that way.

## 1. Apple and Google

1. Developer portal: App ID `com.jimgreco.journal` with **Sign in with Apple**.
2. App Store distribution provisioning profile for it, signed by the existing
   distribution certificate.
3. App Store Connect: a new app record for the bundle ID (the name "Journal"
   is taken on the store, so pick a unique store name). Apple also rejects an
   upload whose home-screen name (`CFBundleDisplayName`) is taken
   (ITMS-90129), so the app shows as "Private Notes". Add yourself to an
   internal TestFlight group.
4. Fill `appId`, `profiles.app.uuid`, `profiles.app.name` and `groups` in
   `.github/scripts/release-policy.json` (same format as Ritual Cue's).
5. Google Cloud console (the project your other apps use): create an **iOS**
   OAuth client for bundle ID `com.jimgreco.journal`. Note its client id and
   reversed client id.
6. Repository secrets: the TestFlight set from the app standard, plus
   `IOS_API_BASE_URL=https://journal.jim-greco.com`,
   `GOOGLE_IOS_CLIENT_ID` and `GOOGLE_IOS_REVERSED_CLIENT_ID`. For local
   device builds, put the same two values in `project.yml`.

## 2. Database (shared_db on the host)

```bash
umask 077
MIGRATOR_PW=$(openssl rand -hex 24); RUNTIME_PW=$(openssl rand -hex 24)
docker exec -i shared_db psql -U admin -v ON_ERROR_STOP=1 \
  -v migrator_pw="$MIGRATOR_PW" -v runtime_pw="$RUNTIME_PW" < provision.sql
```

Migrations (now and for every later `db/NNN_*.sql`), with the migrator allowed
to log in only while they run:

```bash
docker exec shared_db psql -U admin -c "ALTER ROLE journal_migrator LOGIN"
docker run --rm --network deploy_default -e MIGRATION_ROLE=journal_owner \
  -e MIGRATION_DATABASE_URL="postgresql://journal_migrator:$MIGRATOR_PW@shared_db:5432/journal" \
  ghcr.io/jimgreco/journal:<sha> node src/migrate.js
docker exec shared_db psql -U admin -c "ALTER ROLE journal_migrator NOLOGIN"
```

Store `MIGRATOR_PW` in your password manager, not on the host.

## 3. Runtime environment (`~/deploy/journal.env`, mode 600)

```bash
KEY=$(openssl rand -base64 32)
cat > ~/deploy/journal.env <<EOF
NODE_ENV=production
DATABASE_URL=postgresql://journal_runtime:$RUNTIME_PW@shared_db:5432/journal
JOURNAL_DATA_KEYS=1:$KEY
SESSION_SECRET=$(openssl rand -hex 32)
APPLE_BUNDLE_ID=com.jimgreco.journal
GOOGLE_CLIENT_ID=<the iOS client id from step 1.5>
ALLOWED_EMAILS=<your Google and/or Apple ID email>
TRUST_PROXY_HOPS=1
EOF
chmod 600 ~/deploy/journal.env
```

**Copy `JOURNAL_DATA_KEYS` into your password manager now.** Backups contain
only ciphertext; without this key they cannot be read. If Sign in with Apple
hides your email, the app says "this journal is private" and the server logs
`sign-in refused for Apple sub <id>`; put that id in `ALLOWED_APPLE_SUBS` and
recreate the service.

## 4. Service, proxy, first start

1. Merge the consolidated-deploy PR that adds the `journal` service (profile
   `journal`, overlay `~/deploy/journal.compose.yml`).
2. nginx-proxy: `journal.jim-greco.com` → `journal:8791`, with a certificate.
   DNS: an A record for `journal.jim-greco.com` to the host.
3. Start once by hand (the release engine only replaces running services):
   `JOURNAL_IMAGE=ghcr.io/jimgreco/journal:<sha> docker-compose -f docker-compose.yml -f journal.compose.yml --profile journal up -d --no-deps journal`
4. `curl -s https://journal.jim-greco.com/health` → `{"ok":true,…,"db":true,…}`.

## 5. Weekly review

Generate a token as in weekly-review's `deploy/RUNBOOK.md` step 0 (name it
`journal`). Add to `journal.env`:

```
WEEKLY_SUMMARY_TOKEN_SHA256=<journal.sha256>
WEEKLY_SUMMARY_EMAIL=<the email your account was created with>
```

Recreate only this service with its full `-f` chain, then put the plaintext
token in the weekly-review cloud environment as the journal source's secret.
Check: no token → `404`; with token → JSON with `"app":"journal"`.

## 6. Backups

Backups follow the shared standard (consolidated-deploy `scripts/backup-pilot`).
After the first nightly run, run the restore test once by hand and confirm the
freshness workflow passes.
