# Otto iOS — Phase 0 runbook

Everything below happens on your Mac. The Firebase project is
`prototype-otto`; the app's bundle id is `com.yourname.otto` (matching the
iOS app registered in the Firebase console).

## 0. One-time: Firebase console

1. **Authentication → Sign-in method → Email/Password → Enable.**
   (Without this, sign-up fails with `CONFIGURATION_NOT_FOUND`.)
2. **Firestore Database → Create database** → production mode → region
   **northamerica-northeast1**.

## 1. One-time: Mac tools

```bash
# Xcode 26 from the App Store (includes the iOS 26 simulator), then:
brew install xcodegen node
brew install --cask google-cloud-sdk     # for running the backend locally
```

## 2. One-time: repo setup

```bash
git clone <this repo> && cd <repo>
npm install

# Deploy Firestore rules + composite indexes (project comes from .firebaserc):
npx firebase login
npm run deploy:firestore

# Let the local backend write to the real Firestore:
gcloud auth application-default login
gcloud config set project prototype-otto
```

## 3. Run the backend locally

```bash
GOOGLE_CLOUD_PROJECT=prototype-otto npm run dev
```

- Listens on `http://localhost:8080` (the app's default server URL; the
  simulator shares your Mac's localhost).
- Verifies **real** Firebase ID tokens (needs only the project id).
- Writes **real** Firestore documents via your `gcloud` ADC login.

## 4. Build and run the app

```bash
# The plist is gitignored — it lives only on your machine:
cp ~/Downloads/GoogleService-Info.plist ios/Otto/GoogleService-Info.plist

cd ios
xcodegen generate
open Otto.xcodeproj
```

In Xcode: let Swift Package resolution finish (Firebase SDK), pick an iOS 26
iPhone simulator, and Run. No signing team is needed for the simulator; once
the Apple Developer Program membership lands, set `DEVELOPMENT_TEAM` in
`project.yml` and regenerate.

## 5. Acceptance walkthrough

| # | Criterion | How to check |
|---|---|---|
| 1 | Generated Swift compiles, zero warnings | ⌘B, then ⌘5 (issue navigator) — must be empty |
| 2 | Sign up + sign in with email/password | Debug screen → email + password → Sign Up (uid appears). Sign out, Sign In again. Relaunch the app — still signed in. |
| 3 | Streamed response, visibly incremental | Type anything → Send → words appear one at a time (~40 ms apart), then `done — tier: …` |
| 4 | cost_events per /converse call | Firebase console → Firestore → `cost_events`: one new doc per Send, with `tier` recorded (plus the `cost_daily` rollup) |
| 5 | Rules reject cross-user reads | `npm run test:rules` (12 tests incl. the explicit cross-user task read) |

Utterances that exercise the router: "what time is it" → `local`,
"remind me to water the plants" → `pcc`,
"text sam that i'm running late" → `sonnet`,
"build me a 6 week training plan" → `opus`.

## 6. Later: deploy the backend to Cloud Run

```bash
gcloud auth login
npm run deploy          # builds via Cloud Build, deploys to northamerica-northeast1
```

Then paste the printed service URL into the Debug screen's Server field
(HTTPS, so it also works from a physical device once you can install on one).

## Troubleshooting

- **Crash at launch** mentioning `GoogleService-Info.plist` → the plist isn't
  in `ios/Otto/` (or was added after `xcodegen generate` — regenerate).
- **Sign-up error `CONFIGURATION_NOT_FOUND`** → Email/Password provider not
  enabled (step 0.1).
- **`Server returned 401`** → backend not running, or started without
  `GOOGLE_CLOUD_PROJECT=prototype-otto`.
- **Firestore `NOT_FOUND` / `PERMISSION_DENIED` in server logs** → database
  not created yet (step 0.2) or `gcloud auth application-default login` not
  done.
- **Models fail to compile with actor-isolation errors** → something flipped
  `SWIFT_DEFAULT_ACTOR_ISOLATION`; it must stay `nonisolated` (set in
  `project.yml`).
