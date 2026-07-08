# SETUP.md — Step zero: accounts, tools, and first run

> Do this before Brick 1. Total time: ~2–3 hours, mostly waiting on installs. Everything here is free except the Play Store fee (₹2,100, one-time, needed only at Brick 10).

---

## A. Accounts to create (in this order)

### 1. GitHub (if you don't have one) — 5 min
- github.com → create account → create a **private** repo named `jobhunt-agent` (make it public at Brick 10 launch)
- Install git locally; set your name/email

### 2. Google AI Studio (Gemini API) — 5 min · needed Brick 2
- aistudio.google.com → sign in with Google → **Get API key** → create key
- No credit card required for the free tier
- Save the key somewhere safe (you'll paste it into `server/.env`)

### 3. Supabase — 10 min · needed Brick 3
- supabase.com → sign up with GitHub → **New project**
  - Name: `jobhunt-agent` · Region: closest to you (e.g., Mumbai) · Save the database password!
- Dashboard → **Database → Extensions** → search `vector` → enable
- Dashboard → **Settings → API** → copy: Project URL, `anon` key, `service_role` key
- Dashboard → **SQL Editor** → paste and run `server/db/migrations/001_core_schema.sql`

### 4. Adzuna — 10 min · needed Brick 3
- developer.adzuna.com → **Register** → create an application
- Copy `app_id` and `app_key`
- Note: use the `in` country code in API URLs for India listings

### 5. RapidAPI (JSearch) — 10 min · needed Brick 3
- rapidapi.com → sign up → search **JSearch** → subscribe to **Basic (free)** plan
- Copy your `X-RapidAPI-Key` from the endpoint page
- Free tier is ~200 requests/month — the daily pipeline uses ~2–4/day, so you're fine

### 6. Render — 10 min · needed end of Brick 3 (deploy)
- render.com → sign up with GitHub
- You'll create: one **Web Service** (FastAPI, free tier) + one **Cron Job** (Brick 8)
- Free tier note: service sleeps after idle (~50s cold start). Upgrade to Starter (~₹450–650/mo) from Brick 5 if it annoys you — that's the only spend worth making.

### 7. Firebase — 15 min · needed Brick 8 (do it later)
- console.firebase.google.com → Add project (link to the same Google account)
- Add the Flutter app via FlutterFire CLI when Brick 8's prompt tells you to
- Project settings → Service accounts → generate private key JSON → save as `server/firebase-service-account.json` (it's gitignored)

### 8. Google Play Console — Brick 10 only
- play.google.com/console → ₹2,100 one-time → identity verification takes 1–2 days, so start it a few days before launch week

---

## B. Local tools to install

| Tool | Check with | Notes |
|---|---|---|
| Flutter SDK | `flutter doctor` | docs.flutter.dev/get-started — fix everything `flutter doctor` complains about |
| Android Studio | — | For the Android emulator + SDK; or use your physical phone with USB debugging |
| Python 3.11+ | `python --version` | You likely have this |
| VS Code | — | Extensions: Flutter, Dart, Python, and the Claude Code extension |
| Claude Code | `claude --version` | Install per Anthropic docs; run it from the repo root so it reads CLAUDE.md |
| poppler | `pdftoppm -v` | Needed by pdf2image in Brick 2 (`apt install poppler-utils` / `brew install poppler` / Windows: poppler releases + PATH) |

---

## C. First-run checklist
```
[ ] git clone your empty repo, copy these project files in, first commit + push
[ ] cp .env.example server/.env  → fill GEMINI key (others can wait for Brick 3)
[ ] cd server && python -m venv .venv && activate && pip install fastapi uvicorn
[ ] flutter create app  (then let Claude Code reorganize it per Brick 1)
[ ] flutter doctor shows no red ✗
[ ] Open repo root in terminal → run `claude` → confirm it has read CLAUDE.md
    (ask it: "what brick are we on and what are the golden rules?")
[ ] Paste the Brick 1 prompt from docs/BRICKS.md → begin
```

## D. Security hygiene (read once, follow forever)
- `.env` and `firebase-service-account.json` are in `.gitignore` — verify with `git status` before every early commit
- If a key ever leaks into a commit: revoke and regenerate it immediately (all these dashboards allow it); don't just delete the file
- The `service_role` Supabase key bypasses all row security — it exists ONLY in `server/.env`, never in Flutter, never in client-visible code
