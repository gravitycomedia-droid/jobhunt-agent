# Unstop internships endpoint (Phase B recon)

Captured 2026-07-20 via live network inspection. No auth/cookies required —
confirmed by calling it with a bare `fetch`, no session state attached.

Consumed by `fetch_unstop_internships()` in `server/services/job_sources.py`.
If Unstop changes this contract, that fetcher's field paths (and this doc) are
what need updating.

## Endpoint

```
GET https://unstop.com/api/public/opportunity/search-result
```

**Re-probed 2026-07-26 (ADR-003 v3).** Contract unchanged; two findings added —
the valid `opportunity` values, and current catalogue sizes.

## Minimum required query params

```
?opportunity=internships&page=1&per_page=100&oppstatus=open
```

- `opportunity` — **not** fixed. Probed live 2026-07-26:

  | value | total (open) | what it is |
  |---|---|---|
  | `internships` | 836 | internships — the original source |
  | `jobs` | 1,186 | non-internship postings, mostly experienced |
  | `competitions` | 285 | contests, **not** hiring listings — excluded |
  | `hiring-challenges` | 22 | contests — excluded |
  | `freshers` | 0 | **not a real type** |
  | `entry-level` | 0 | **not a real type** |

  The last two matter: they look plausible and return a valid, empty paginator
  rather than an error, so a typo'd type is indistinguishable from a dead source
  in the Phase F health log. `_unstop_opportunity_types()` drops unknown values
  with a warning for exactly this reason. Unstop's "fresher jobs" listing is a
  filter *inside* `jobs`, not a separate catalogue — which is why the
  fresher/entry-level cut lives in `services/job_filter.py`, not in this query.
- `page` — 1-indexed.
- `per_page` — tested up to 100 without issue; use `UNSTOP_MAX_RESULTS`
  divided across pages, not a single giant page.
- `oppstatus=open` — filters to currently-open internships only.

The real browser call also sends `sortBy=`, `orderBy=`, `filter_condition=`,
`undefined=true` — all confirmed **not required**. Dropped; they're frontend
form artifacts, not real filter params.

## Pagination — standard Laravel paginator

Response is `{"data": {...}}`, and the inner object is a plain Laravel
`paginate()` shape:

```json
{
  "current_page": 1,
  "data": [ /* array of internship objects, length == per_page */ ],
  "last_page": 808,
  "next_page_url": "https://unstop.com/api/...&page=2",
  "per_page": 1,
  "total": 808
}
```

Loop while `current_page < last_page` and stop early once `UNSTOP_MAX_RESULTS`
is hit — same cap pattern as the Apify sources. `total` at capture time was 808
open internships.

## Fields worth pulling into `JobIn`

| JobIn field | Source path | Notes |
|---|---|---|
| external id | `id` | int, stable |
| title | `title` | |
| company | `organisation.name` | |
| url | `seo_url` | canonical public link |
| location | `locations[].city` | array; can be empty for remote-only |
| remote/type | `jobDetail.type` | `wfh` / `hybrid` / `in_office` |
| employment | `jobDetail.timing` | `full_time` / `part_time` |
| salary_min | `jobDetail.min_salary` | **already a clean int, nullable** |
| salary_max | `jobDetail.max_salary` | **already a clean int, nullable** |
| currency | `jobDetail.currency` | literal string `"fa-rupee"` — map to `"INR"`, don't feed through `salary.py`'s text parser, there's no free text here |
| pay period | `jobDetail.pay_in` | `"monthly"` — annualize (×12) so it sits on the same axis as per-year salaries |
| paid flag | `jobDetail.paid_unpaid` | `"paid"` / `"unpaid"` — if unpaid, `min_salary`/`max_salary` are `null` |
| posted date | `approved_date` | |
| deadline | `end_date` | registration close (not currently mapped) |
| skills | `required_skills[].skill` | array (not currently mapped) |
| description | `details` | HTML, stripped via `_strip_html()` same as Greenhouse |
| status | `reg_status` | `"STARTED"` for currently-open ones |

## Implementation note

Because `min_salary`/`max_salary` arrive pre-parsed as integers, this source
does **not** need `salary.py`'s free-text parser — that's Naukri's job
(`"6-15 Lacs PA"` style strings). Unstop only needs
`currency = "INR" if raw == "fa-rupee" else infer_currency(...)` plus the
`pay_in`-based ×12 monthly annualization — see `_unstop_row_to_job()`.

## Volume + politeness (updated 2026-07-26, ADR-003 v3)

At `per_page=100` the entire open catalogue is **~21 requests** (9 pages of
internships + 12 of jobs). A full cold crawl was measured end-to-end at **77s**,
including a deliberate 0.3s pause between pages.

Steady state is much cheaper: results come back newest-first, so
`_crawl_unstop()` stops after two consecutive pages entirely older than
`MAX_JOB_AGE_DAYS` — typically **~3 requests/day**. Freshness distribution when
this was measured:

| | open | ≤10 days | ≤1 day |
|---|---|---|---|
| internships | 836 | 626 | 78 |
| jobs | 1,186 | 817 | 53 |

So the daily *new* supply is ~131 postings across both catalogues.

## Not yet verified

- Rate-limiting behavior at sustained volume. The 2026-07-26 full crawl (21
  requests, spaced) drew no 429s or challenges, but that's one cold run, not
  weeks of them. The freshness early-stop is what keeps this bounded in normal
  operation; if Unstop ever does start throttling, the symptom will be an
  `HTTPError` per page, which already logs and degrades to a partial result
  rather than raising.
- Whether `oppstatus=open` has siblings (e.g. `closed`) worth excluding
  explicitly — assumed default is fine for cron use.
