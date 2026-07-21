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

## Minimum required query params

```
?opportunity=internships&page=1&per_page=100&oppstatus=open
```

- `opportunity=internships` — fixed value for this source.
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

## Not yet verified

- Rate-limiting behavior at sustained volume — only a handful of requests during
  recon, not a full 800-page crawl. Mitigated in code: we only ever pull
  `UNSTOP_MAX_RESULTS` (default 20), i.e. one small page per cron day, so this
  stays a light caller (ADR-003's "no high-volume polling").
- Whether `oppstatus=open` has siblings (e.g. `closed`) worth excluding
  explicitly — assumed default is fine for cron use.
