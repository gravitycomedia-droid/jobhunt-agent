# Play Console — FirstRole release runbook

Everything needed to get FirstRole onto Google Play, and the exact copy to paste
into each Console field. Written for the **closed testing** track, because that
is the track a personal developer account must clear first (see §1).

- **App name:** FirstRole
- **Package (permanent):** `com.jobhuntagent.jobhunt_agent`
- **Current version:** `1.0.0` (versionCode `1`)
- **Backend:** Cloud Run, `asia-south1` — the release build points at it by
  default (`app/lib/services/api_client.dart`).

---

## 1. Read this first: you cannot go straight to production

Google requires **personal** developer accounts registered after November 2023 to
run a **closed test with at least 12 testers who stay opted in for 14 continuous
days** before you may even *apply* for production access.

What that means in practice:

- Today's goal is a **closed testing release**, not a public listing.
- The 14 days is continuous and does not pause. If testers drop below 12, the
  clock can reset — so recruit ~15 to leave slack.
- "Tester" = a Google account you add to the tester list, that actually opts in
  via your test link and installs the app.
- After 14 days you apply for production access; Google reviews it (typically
  days, not hours).

So the realistic timeline to a public listing is **~3 weeks minimum**, and it
starts only once the closed test is live with 12 people in it.

## 2. Pre-upload checklist (status)

| Item | Status |
|---|---|
| Release signing with a real upload key | Done — `~/keys/firstrole-upload.jks` |
| App name / launcher label | Done — "FirstRole" |
| Launcher icon (all densities + adaptive) | Done |
| Play icon 512×512 | Done — `app/assets/store/play_store_icon_512.png` |
| Feature graphic 1024×500 | Done — `app/assets/store/feature_graphic_1024x500.png` |
| Code shrinking + obfuscation (R8) | Done — verified booting on emulator |
| targetSdk 36 (Play requires ≥35) | Done |
| Privacy policy | Written — `docs/privacy-policy.md`, **needs hosting** (§6) |
| Phone screenshots (min 2) | **TODO — you must capture these** (§5) |
| Play Console account | You have one (personal) |

## 3. Build the release AAB

```bash
cd app
flutter build appbundle --release
# -> build/app/outputs/bundle/release/app-release.aab
```

Upload that `.aab`. Verify it is signed with the upload key (not the debug key)
before uploading:

```bash
jarsigner -verify -verbose:summary -certs \
  build/app/outputs/bundle/release/app-release.aab | grep -E "CN=|jar verified"
# expect: CN=FirstRole ... / jar verified.
```

**For every subsequent upload, bump the version** in `app/pubspec.yaml` —
Play rejects a re-used versionCode:

```yaml
version: 1.0.1+2   # versionName+versionCode; versionCode must strictly increase
```

## 4. THE KEYSTORE — back this up now

```
keystore:  ~/keys/firstrole-upload.jks
password:  app/android/key.properties   (gitignored, not in the repo)
alias:     firstrole-upload
```

Both files are **outside version control on purpose**. They exist only on this
Mac right now. Put the `.jks` and the password into a password manager or private
backup today.

Losing them is not fatal *if* you enable **Play App Signing** (do — it is the
default, and it lets Google re-issue your upload key if you lose it). Losing them
*without* Play App Signing means you can never update the app again.

> **Note on Play App Signing:** Google re-signs your app with its own key, so the
> SHA-1 that end users' devices see is Google's, not the one in your keystore. It
> does not affect this app's Google sign-in, because auth goes through a browser
> redirect (Supabase OAuth), not the native Google Sign-In SDK, which is the thing
> that requires a registered SHA-1. If you ever switch to native Google Sign-In,
> you must add Play's app-signing SHA-1 to the Firebase console.

## 5. Screenshots — you have to do this part

Play requires **at least 2 phone screenshots**. I could not generate real ones:
every screen past the welcome screen requires a signed-in account with a parsed
resume, and signing in as you is not something I should do.

Capture them on the emulator once you're signed in:

```bash
cd app
flutter emulators --launch jobhunt_pixel
flutter run --release          # sign in, upload a resume, let matches load
# then, per screen you want:
adb exec-out screencap -p > ~/Desktop/firstrole-1.png
```

Best four to show, in this order (Play shows the first two most often):

1. **Matches list** — scored jobs. This is the product.
2. **Resume tailoring / diff view** — the differentiator no competitor shows.
3. **Application tracker (Kanban)** — proves it's a full pipeline.
4. **Daily agent notification / shortlist** — the "it works while you sleep" story.

Requirements: PNG or JPEG, 16:9 or 9:16, each side between 320px and 3840px. The
Pixel emulator's native 1080×2400 satisfies this.

## 6. Host the privacy policy (required)

Play will not let you submit without a **publicly reachable** privacy policy URL.
`docs/privacy-policy.md` is written and accurate to what the code actually does.

Fastest route — GitHub Pages:

1. Push this repo to GitHub (public, or a public repo just for the policy).
2. Settings → Pages → Source: `main`, folder `/docs`.
3. The URL becomes:
   `https://<your-username>.github.io/<repo>/privacy-policy`
4. Open it in a private window to confirm it loads before pasting into Play.

## 7. Store listing — copy to paste

**App name** (30 max) — 26 chars:
```
FirstRole: AI Fresher Jobs
```

**Short description** (80 max) — 80 chars. This is the single most keyword-weighted
field in Play search:
```
Your AI agent hunts fresher & intern roles daily and tailors your resume.
```

**Full description** (4000 max):
```
FirstRole is an AI job-search agent built for one job: landing your first one.

Most job apps hand you a search box and a firehose of postings written for people
with five years of experience. FirstRole works the other way around. It reads your
resume, then goes hunting — every day, on its own — for fresher and internship
roles that actually fit you, and rewrites your resume for the ones worth applying to.

HOW IT WORKS

1. Upload your resume once.
   FirstRole reads it and builds a structured profile of your skills, projects,
   and education.

2. The agent hunts daily.
   It pulls new fresher and intern postings from multiple job sources every day —
   you don't run a search, you just get results.

3. Every job gets scored against YOUR resume.
   Two-stage matching: a fast semantic filter narrows the pool, then a language
   model re-ranks what's left and tells you, in plain words, why a role fits and
   what you're missing.

4. Your resume gets tailored per job.
   FirstRole rewrites your resume to speak to a specific posting — and an
   anti-fabrication check traces every single generated bullet back to something
   real in your original resume. It cannot invent a skill you don't have.

5. Track every application.
   A simple pipeline board from applied through to offer, with AI-drafted
   follow-up messages when a company goes quiet.

BUILT FOR FRESHERS AND INTERNS
Entry-level, internship, and new-grad roles — not senior listings you can't apply
to. Strong coverage of software roles (full-stack, frontend, cloud) in Hyderabad
and Bangalore.

YOU ARE ALWAYS IN CONTROL
FirstRole never submits an application for you. It finds, scores, and drafts —
you review and approve everything. No auto-apply, ever.

HONEST ABOUT AI
Your resume is processed by AI models to parse, score, and tailor it. We don't
sell your data, we don't show you ads, and we don't train models on your resume.
Full detail in the privacy policy.
```

**Category:** Business (alternative: Productivity)
**Tags:** job search, resume, career
**Contact email:** gravity.co.media@gmail.com

## 8. Data safety form — answers

These must match `docs/privacy-policy.md` and the code, or you risk a policy
strike. Declare:

**Does your app collect or share user data?** → **Yes**

| Data type | Collected | Shared | Purpose | Required? |
|---|---|---|---|---|
| Name | Yes | No | App functionality, Account management | Required |
| Email address | Yes | No | App functionality, Account management | Required |
| User IDs | Yes | No | App functionality, Account management | Required |
| Other user-generated content (resume, work history, education, application notes) | Yes | **Yes** | App functionality | Required |

Key points:

- **Resume content must be declared as SHARED**, because it is sent to Google
  (Gemini) and DeepSeek for parsing/scoring/tailoring. Under Play's definition,
  transfer to a third party is "sharing" even when they are your processors.
  Under-declaring this is the most common cause of a rejection here.
- **Is data encrypted in transit?** → Yes (HTTPS; cleartext is disabled).
- **Can users request deletion?** → Yes, via email (stated in the policy).
- **Location, contacts, photos, financial info** → **No** to all. The app requests
  only INTERNET, ACCESS_NETWORK_STATE, POST_NOTIFICATIONS, and WAKE_LOCK.

**Content rating questionnaire:** answer honestly; a utility app with no user
content sharing, no ads, no violence → rates **Everyone / PEGI 3**.

**Ads:** No. **In-app purchases:** No.

## 9. The actual Console flow

1. **Create app** — name "FirstRole: AI Fresher Jobs", app (not game), free.
2. **Set up your app** — complete every task in the "Set up your app" panel:
   app access (see below), ads (no), content rating, target audience (18+ is the
   simplest; 13+ pulls in extra Families policy requirements), data safety (§8),
   privacy policy URL (§6).
3. **App access** — ⚠️ the app is behind Google sign-in, so reviewers cannot see
   anything without an account. Choose **"All or some functionality is
   restricted"** and give them working demo credentials. If you skip this, review
   *will* bounce with "we could not access the app."
4. **Testing → Closed testing → Create track.**
5. Upload the AAB. Enable **Play App Signing** when prompted.
6. Add your 12+ testers by Google account email (or a Google Group — easier to
   manage; you can add people without a new release).
7. Write release notes, roll out.
8. Share the opt-in link. Confirm each tester actually installs — an invited
   tester who never opts in does not count toward the 12.
9. Wait 14 continuous days, then apply for production access.

## 10. Known gaps before submitting

- [ ] **Screenshots not captured** (§5) — blocks submission.
- [ ] **Privacy policy not hosted** (§6) — blocks submission.
- [ ] **Keystore not backed up** (§4) — do this before anything else.
- [ ] **Demo account for reviewers** (§9.3) — the app is sign-in gated; without
      credentials, review fails.
- [ ] Push notifications remain unverified on a physical device (see DECISIONS.md
      ADR-007). The closed test is the first real chance to confirm FCM delivery
      on real hardware — ask testers explicitly whether the daily notification
      arrives.
- [ ] In-app splash still uses the old "target" glyph rather than the new
      staircase mark. Cosmetic only; not a blocker.
