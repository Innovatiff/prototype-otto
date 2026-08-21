# Otto — App Privacy label worksheet (write first, conform second)

The declarations below are what the App Store Connect privacy questionnaire
should say, and the code is built to match them. Any behavior change that
would contradict a line here must update this document in the same PR.

## Data collected, by category

| Category | Data | Linked to identity? | Tracking? |
|---|---|---|---|
| Contact info | Email address (account sign-in) | Yes | No |
| User content | Messages to Otto (text transcripts), tasks/lists/reminders, remembered facts (memories), generated plans/voyages, moderation reports | Yes | No |
| Calendar | 48-hour compressed view when calendar sync is enabled: titles, times, locations, attendee **counts** only | Yes | No |
| Health & fitness | Workout sessions written to HealthKit **on device only** | No (never leaves device) | No |
| Identifiers | Firebase user ID; RevenueCat app user ID (same value) | Yes | No |
| Purchases | Subscription state (via RevenueCat/StoreKit) | Yes | No |
| Diagnostics | Server logs: routing decisions, cost telemetry, error events keyed by user ID | Yes | No |

**Used for tracking (ATT): nothing.** No ad networks, no data brokers, no
cross-app identifiers. The app must never add an SDK that changes this
without revisiting the label.

## The strong claims (put these in the store description too)

- **Voice audio never leaves the device.** Speech-to-text and TTS are
  on-device; only the resulting text is sent.
- Calendar notes, descriptions, and attendee names/emails **never leave
  the device** — the sync sends titles, times, locations, attendee counts,
  and the server purges each view within 48 hours.
- HealthKit data is written (workouts) and read (references) **on device
  only**, never persisted server-side, never in iCloud, never used for
  advertising or shared with third parties. (HealthKit's own rules also
  forbid all of that.)

## Third-party processors

- **Anthropic (Claude)** — processes message text, enabled calendar
  context, and remembered facts to generate responses. Not used to train
  models. Gated behind explicit, revocable, versioned in-app consent; the
  server refuses model calls without stored consent.
- **Google Firebase** (Auth, Firestore, FCM) — account, storage, push.
- **RevenueCat** — subscription entitlements; receives the app user ID
  and purchase receipts, nothing else.
- **Open-Meteo** — weather by coarse coordinates (a fixed default unless
  the user sets a location); no identifiers sent.

## Deletion

In-app account deletion (Settings → Account → Delete Account, three taps)
erases every Firestore document across all collections — enforced by a
census test — then the auth user. The confirmation notes that cancelling
a subscription is separate and happens in Apple's settings.

## Age rating

Otto generates open-ended conversational content with server-side
boundary rules (no medical diagnosis, no legal/financial advice, nothing
harm-enabling, nothing age-inappropriate) and a visible report flow.
Answer the questionnaire honestly: **12+** (infrequent/mild mature
themes possible in open-ended AI output) — do not understate to 4+.
Declare the app contains AI-generated content where asked.
