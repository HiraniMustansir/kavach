# Kavach

On-device AI screen-safety monitor for kids' Android phones, with a parent app for Android and iOS.
Specs: `prd.md` (requirements, IDs like `SENSE-4`) and `design.md` (architecture). Add both to the repo root.

```
app/                         Flutter app — parent (Android + iOS) and child shell (Android)
  lib/parent/                sign-in, home, alerts, reports, controls, pairing, family, settings
  lib/child/                 setup wizard, child home, PIN-gated parent area
  android/app/src/main/kotlin/app/kavach/agent/
    a11y/                    AccessibilityService: text, URLs, screenshots, overlays, settings guard
    ml/                      text lexicon risk, domain/app catalog, LiteRT vision-model slot, dHash
    risk/                    fusion, k-of-n smoothing, rule engine → RiskEvents
    enforce/                 blocking, limits, schedules
    admin/                   Device Owner (Tier A) + Device Admin (Tier B)
    data/ sync/ usage/       SQLCipher queue, signed API client, WorkManager, FCM, UsageStats
  android/app/src/main/assets/kavach/   lexicon.json, catalog.json (remote-updatable data)
admin/                       Next.js internal console: metrics, bundle rollout, misuse reports (ADM-1..3)
tools/bundle.ts              sign + upload a rule/model bundle (CLS-8)
supabase/
  migrations/                schema, RLS, grants, triggers, cron
  functions/device           child-device API (ECDSA-signed requests)
  functions/parent           parent API (JWT): pairing, policy, commands, PIN, export/delete
  functions/cron             offline sweeper, partial digests, 18th-birthday stop
```

Privacy rule enforced in code: screenshots and screen text never leave the child's phone. Only
category, score, app, domain and a generated description are uploaded.

## 1. Configure

`.env` in the repo root (git-ignored), used by both Flutter and the Android agent:

```
SUPABASE_URL=https://<project>.supabase.co
SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
```

## 2. Deploy the backend

```bash
npx supabase login
npx supabase link --project-ref tatxdkuloyyegiddywie
npx supabase db push                                  # applies supabase/migrations/*
npx supabase functions deploy device parent cron
# ANTHROPIC_API_KEY: digest summaries (a fixed template is used without it)
npx supabase secrets set CRON_SECRET=$(openssl rand -hex 24) \
  ANTHROPIC_API_KEY=sk-ant-... \
  FCM_SERVICE_ACCOUNT="$(cat firebase-service-account.json)" \
  DPC_APK_URL=https://<cdn>/kavach.apk DPC_SIGNATURE_CHECKSUM=<base64url sha256 of signing cert>
```

Then in the SQL editor, store the two values pg_cron needs to call the `cron` function:

```sql
select vault.create_secret('https://tatxdkuloyyegiddywie.supabase.co', 'project_url');
select vault.create_secret('<same CRON_SECRET as above>', 'cron_secret');
```

In Supabase → Authentication → Providers, enable **Phone** with an Indian SMS provider (MSG91/Twilio, DLT template).

## 3. Push notifications (optional but needed for real-time alerts)

Create a Firebase project, add the Android app `app.kavach` and the iOS app, put
`google-services.json` in `app/android/app/` and `GoogleService-Info.plist` in `app/ios/Runner/`.
Without these the app still runs; alerts then appear only when the parent opens the app, and the
child phone picks up commands on its 5-minute heartbeat.

## 4. Run

```bash
cd app
flutter run --dart-define-from-file=../.env
```

Tests:

```bash
~/dev/deno test -A supabase/functions/tests          # Edge Function logic
(cd app/android && ./gradlew :app:testDebugUnitTest) # agent fusion / lexicon / schedules
supabase/tests/rls_smoke.sql                         # paste into the SQL editor; success = error 'ALL_OK'
```

## 5. Tier A (Device Owner) provisioning

1. Build a release APK signed with your real key: `flutter build apk --release --dart-define-from-file=../.env`.
2. Host it over HTTPS and set `DPC_APK_URL`.
3. `DPC_SIGNATURE_CHECKSUM` is the URL-safe base64 SHA-256 of the signing certificate:
   `keytool -printcert -jarfile app-release.apk | grep SHA256` → convert hex to base64url.
4. For development without a factory reset: `adb shell dpm set-device-owner app.kavach/.agent.admin.KavachAdminReceiver`
   on a phone with no accounts, then pair with a Tier A code.

## 6. Rule & model updates (CLS-8)

Keyword lists, domain/app catalogs and models ship as signed bundles, so they change without an app
release. The signing key is `~/.kavach-keys/bundle-signing.pem` (ECDSA P-256; its public half is pinned
in `BundleManager.kt`, so rotating it needs an app update).

```bash
mkdir /tmp/b && cp app/android/app/src/main/assets/kavach/*.json /tmp/b   # edit what you need
SUPABASE_URL=https://<project>.supabase.co SUPABASE_SERVICE_ROLE_KEY=<secret key> \
  KAVACH_BUNDLE_KEY=~/.kavach-keys/bundle-signing.pem deno run -A tools/bundle.ts /tmp/b 2026.12.01-1
```

It uploads as a draft. Roll it out from the admin console (5% → 25% → 100%). Phones verify the
signature and every file hash, swap it in at their next check-in, and roll back if it fails to load.
Revoking sends phones back to the rules built into the APK.

## 7. Admin console

```bash
cd admin && cp ../.env .env.local   # needs NEXT_PUBLIC_SUPABASE_URL / NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
npm install && npm run dev          # or deploy to Vercel
```

Create staff accounts in Supabase → Authentication → Users (email + password), then make them admins:
`insert into admin_user values ('<user id>');`. The console shows aggregates only; it never shows a
family's alerts or usage (ADM-2). Suspending a family from a misuse report releases all its phones.

## 8. Vision models

The image classifier (M1) slot loads `files/models/current/vision_gate.tflite` + `vision_gate.json`
(`{"labels": ["SEX","GORE","WEAP","DRUG","GAMB-UI","HORROR","SAFE"], "input": 224}`). No model is
shipped: they need training on licensed data (PRD §10.4). Until one is installed, screenshots are
not taken at all and detection runs on text, URLs, app categories and behaviour rules.

## Not built yet

- Trained models M1–M5 (the signed bundle pipeline that delivers them is built), OCR (SENSE-6)
- Local VPN web filter and SafeSearch (CTL-4), MediaProjection fallback for Android 8–10 (SENSE-7)
- Co-guardian invites (ACC-5), billing (SET-3), weekly report push (DIG-5), location (LOC-*), SMS fallback (ALR-8)
- iOS child mode (v2), legal-request workflow (ADM-4), Play Integrity (TMP-10), crash reporting/analytics (needs Sentry/PostHog accounts)
- Google/Apple sign-in (needs provider setup); the DigiLocker age check is pending legal advice (PRD §15)
