# Privacy Policy — FirstRole

**Effective date:** 14 July 2026
**Last updated:** 14 July 2026

FirstRole ("the app") is an AI job-search agent for entry-level and internship
roles. It finds job postings, scores them against your resume, and tailors your
resume for individual applications. This policy explains exactly what the app
collects, where that data goes, and how to get it deleted.

Contact for any privacy question or deletion request:
**gravity.co.media@gmail.com**

---

## 1. What we collect

We collect only what the app needs to do its job. There is no advertising SDK,
no analytics SDK, and no third-party tracker in the app.

| Data | Why we need it |
|---|---|
| **Email address and name** from your Google account | To create and sign you in to your account. Sign-in is handled by Google OAuth via Supabase; we never see or store your Google password. |
| **Your resume** — the file you upload, and the structured profile extracted from it (name, headline, skills, work experience, projects, education, and the full resume text) | This is the core function. Every job is scored against this profile, and resume tailoring rewrites from it. The full text is retained because our anti-fabrication check must trace every generated bullet back to a real line in your original resume. |
| **Applications you track** — which jobs you applied to, their status, and any notes you add | To power the application tracker. |
| **Push notification token** (Firebase Cloud Messaging) | To send you the daily "new matches" notification. Only if you grant notification permission. |
| **Operational logs of AI calls** — which model ran, token counts, latency, and whether the output passed validation | To monitor cost and reliability. **These logs store only a cryptographic hash of the prompt, never the prompt text itself.** |

We do **not** collect your location, contacts, photos, camera, microphone, call
logs, SMS, or device identifiers for advertising.

## 2. Where your data goes

Your resume content is sent to third-party AI providers so the app can read,
score, and rewrite it. This is unavoidable for the app to function, and it is the
most important thing to understand in this policy:

- **Google (Gemini API)** — receives your resume (as an image/PDF for parsing,
  and as text for tailoring) and the job descriptions being matched.
- **DeepSeek** — receives your profile summary and job descriptions in order to
  re-rank matches and draft follow-up messages.

Other processors that hold or handle your data on our behalf:

- **Supabase** — hosts the Postgres database and handles authentication. Your
  profile, resume text, matches, and applications are stored here.
- **Google Cloud Run** (region: `asia-south1`, Mumbai) — runs our backend server.
- **Firebase Cloud Messaging** — delivers push notifications.

Job listings are fetched from public job sources (Adzuna, JSearch/RapidAPI,
Greenhouse, Lever, and no-login public listings via Apify). **We send only search
terms to these sources — never your resume or personal data.**

We do not sell your data. We do not share it with advertisers. We do not use your
resume to train any AI model of our own.

## 3. Automated applications

FirstRole **never submits a job application on your behalf without your explicit
approval.** Every tailored resume and every application is presented to you for
review first. There is no auto-apply.

## 4. Data retention and deletion

Your data is kept for as long as your account exists.

To delete your account and all associated data — profile, resume text,
uploaded resume, matches, tailored resumes, and application history — email
**gravity.co.media@gmail.com** from the email address associated with your
account. We will delete it within 30 days and confirm when it is done.

## 5. Security

- All traffic between the app and our server uses HTTPS. The app is built with
  cleartext HTTP disabled.
- API keys for all AI and job-data providers are held server-side only and are
  never shipped inside the app.
- Database access is scoped per user, so one account cannot read another's data.

No system is perfectly secure, and we cannot guarantee absolute security.

## 6. Children

FirstRole is not directed at children under 13, and we do not knowingly collect
data from them.

## 7. Changes to this policy

If this policy changes materially, we will update the "Last updated" date above
and, where the change is significant, notify you in the app.

## 8. Contact

Questions, data access requests, or deletion requests:
**gravity.co.media@gmail.com**
