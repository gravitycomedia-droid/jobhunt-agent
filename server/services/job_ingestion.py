import asyncio
import ipaddress
import logging
import socket
import uuid
from datetime import datetime, timedelta, timezone
from urllib.parse import urlparse

import httpx
from bs4 import BeautifulSoup

from config import settings
from db.supabase_client import supabase
from models.job import JobExtraction, JobIn
from services.dedup import is_duplicate, make_dedup_key
from services.embeddings import embed_text, embed_texts, job_embedding_text
from services.job_category import classify_category
from services.job_filter import classify_work_type, gates_for_source, is_relevant
from services.job_sources import (
    _locations,
    _roles,
    fetch_adzuna,
    fetch_greenhouse,
    fetch_indeed_apify,
    fetch_instahyre,
    fetch_internshala,
    fetch_jsearch,
    fetch_lever,
    fetch_linkedin_apify,
    fetch_naukri_apify,
    fetch_unstop,
)
from services.job_tech_category import classify_tech_categories_batch

logger = logging.getLogger(__name__)


def is_fresh(job: JobIn, now: datetime | None = None) -> bool:
    """Phase 1D freshness gate: False for postings older than
    settings.max_job_age_days (job boards occasionally return years-old
    rows — the "2591d ago" bug). Unknown posted_at passes: the app renders
    it as "date unknown" rather than us dropping possibly-fresh jobs.
    """
    if job.posted_at is None:
        return True
    now = now or datetime.now(timezone.utc)
    posted = job.posted_at if job.posted_at.tzinfo else job.posted_at.replace(tzinfo=timezone.utc)
    return now - posted <= timedelta(days=settings.max_job_age_days)


class ManualJobFetchError(Exception):
    """The pasted URL couldn't be fetched or didn't look like a web page —
    distinct from JobExtractError (fetch succeeded, LLM extraction failed)
    so routers/jobs.py can give the user a more specific message."""


# Phase 14 / ADR-024 (SSRF): this server fetches a URL the USER chose, which
# means the user can aim our outbound requests at anything our network can
# reach — including things the public internet can't. On Cloud Run that's the
# metadata service at 169.254.169.254, which hands out service-account access
# tokens to anyone who asks from inside the box. "Fetch this job posting:
# http://169.254.169.254/computeMetadata/v1/..." would otherwise return the
# page text straight back to the caller via the extraction preview.
#
# So: only http(s), and only hosts that resolve to PUBLIC addresses.
_ALLOWED_SCHEMES = ("http", "https")
# Redirects are followed by hand (below) rather than by httpx, because a
# check-then-follow-redirects client validates only the FIRST url — a public
# host is free to 302 you to 169.254.169.254, and httpx would follow it.
_MAX_REDIRECTS = 5


def _assert_public_url(url: str) -> None:
    """Raises ManualJobFetchError unless `url` is http(s) and every address its
    hostname resolves to is publicly routable.

    `ip.is_global` is the whole check: it's False for RFC1918 private ranges
    (10/8, 172.16/12, 192.168/16), loopback (127/8, ::1), link-local
    (169.254/16 — the cloud metadata range — and fe80::/10), CGNAT (100.64/10),
    multicast, and the reserved blocks. Every address is checked, not just the
    first: a hostname with both a public A record and a private one must not
    slip through on the strength of the public one.

    Residual risk (documented, not solved): DNS rebinding. We resolve here and
    httpx resolves again when it connects, so a hostile resolver could return a
    public IP to this check and a private one microseconds later. Closing that
    needs pinning the connection to the vetted IP; it's a real gap, and out of
    proportion to a single-user portfolio app's threat model.
    """
    parsed = urlparse(url)
    if parsed.scheme not in _ALLOWED_SCHEMES:
        raise ManualJobFetchError(f"Only http and https links are supported (got '{parsed.scheme or 'no scheme'}')")

    host = parsed.hostname
    if not host:
        raise ManualJobFetchError("That doesn't look like a valid URL")

    try:
        addrinfo = socket.getaddrinfo(host, parsed.port or (443 if parsed.scheme == "https" else 80))
    except socket.gaierror as e:
        raise ManualJobFetchError(f"Could not resolve that URL's host: {host}") from e

    for info in addrinfo:
        ip = ipaddress.ip_address(info[4][0])
        if not ip.is_global:
            raise ManualJobFetchError("That URL points to a private or internal address, which isn't allowed")


async def fetch_manual_job_text(url: str) -> str:
    """Add Job (frontend rebuild Phase 2): fetches one user-pasted URL and
    strips it to plain text for the LLM extraction prompt. Single
    user-supplied link, fetched on explicit request — not automated
    harvesting of a job board, which is what ADR-003's no-scraping stance
    is actually about (see DECISIONS.md ADR-009).

    ADR-024: every hop is re-validated against _assert_public_url, so neither
    the pasted URL nor anything it redirects to can reach our internal network.
    """
    headers = {"User-Agent": "Mozilla/5.0 (compatible; JobHuntAgent/1.0)"}
    current = url

    try:
        # follow_redirects=False: we follow them ourselves so each hop gets the
        # SSRF check. Timeout is per-request and unchanged at 15s.
        async with httpx.AsyncClient(timeout=15, follow_redirects=False) as client:
            for _ in range(_MAX_REDIRECTS + 1):
                _assert_public_url(current)
                response = await client.get(current, headers=headers)
                if response.is_redirect:
                    location = response.headers.get("location")
                    if not location:
                        raise ManualJobFetchError("That URL redirected without saying where")
                    # Relative Location headers are legal — resolve against the
                    # current URL before re-checking it.
                    current = str(response.url.join(location))
                    continue
                response.raise_for_status()
                break
            else:
                raise ManualJobFetchError("That URL redirected too many times")
    except httpx.HTTPError as e:
        raise ManualJobFetchError(f"Could not fetch that URL: {e}") from e

    content_type = response.headers.get("content-type", "")
    if "html" not in content_type:
        raise ManualJobFetchError(f"That URL didn't return a web page (content-type: {content_type or 'unknown'})")

    soup = BeautifulSoup(response.text, "html.parser")
    for tag in soup(["script", "style", "noscript"]):
        tag.decompose()
    text = soup.get_text(separator="\n", strip=True)
    if not text:
        raise ManualJobFetchError("That page had no readable text to extract from")
    return text


def insert_manual_job(extraction: JobExtraction, redirect_url: str | None = None, source: str = "manual") -> dict:
    """Add Job (frontend rebuild Phase 2): inserts a user-reviewed
    extraction into the shared job pool with source='manual'. Exact
    dedup_key match against a posting already in the pool (e.g. from
    Adzuna/JSearch) returns that existing row instead of creating a
    second one — see the exact-vs-fuzzy tradeoff noted below.

    `redirect_url` is optional and `source` overridable for the JD-paste
    resume builder (routers/jobs.py's `from-jd` flow, source='jd_paste') —
    a pasted/uploaded JD has no source link to redirect to.
    """
    # Exact dedup_key match only — is_duplicate()'s fuzzy check (used by
    # refresh_job_pool) only returns a bool, not which row matched, so it
    # can't tell us what to return here. A manual add is a deliberate
    # single-item user action, not a bulk-fetch flood, so skipping the
    # fuzzy pass trades a small chance of a near-duplicate row for never
    # returning the wrong job as if it were the match.
    dedup_key = make_dedup_key(extraction.title, extraction.company, extraction.location)
    existing = supabase.table("jobs").select("*").eq("dedup_key", dedup_key).limit(1).execute().data
    if existing:
        return existing[0]

    payload = {
        "source": source,
        "external_id": str(uuid.uuid4()),
        "title": extraction.title,
        "company": extraction.company,
        "location": extraction.location,
        "description": extraction.description,
        "salary_min": extraction.salary_min,
        "salary_max": extraction.salary_max,
        "redirect_url": redirect_url,
        "dedup_key": dedup_key,
        "work_type": classify_work_type(extraction.location, extraction.title, extraction.description),
        "category": classify_category(extraction.title, extraction.description),
        "embedding": embed_text(job_embedding_text(extraction.model_dump())),
    }
    return supabase.table("jobs").insert(payload).execute().data[0]


def _dedup_embed_insert(fetched: list[JobIn]) -> dict:
    """The shared back half of ingestion: freshness + relevance gates → dedup →
    batch-embed → upsert. Split out of refresh_job_pool() so
    refresh_scraped_sources() runs the identical path (ADR-003's amendment says
    scraped jobs get the same treatment as everything else — same dedup, same
    freshness rule, same embeddings), and so a fix to either only has to be made
    once.
    """
    # Phase 1D: drop stale postings before dedup/embedding — one gate for
    # every source.
    fresh = [job for job in fetched if is_fresh(job)]

    # Relevance gate (services/job_filter.py): fullstack/frontend/cloud-architect
    # internships and fresher roles, in Hyderabad/Bengaluru. It lives HERE rather
    # than in each fetcher because the sources have wildly different filtering
    # powers — Naukri filters by experience server-side, LinkedIn/Indeed only via
    # keywords, and Greenhouse/Lever not at all (they return a company's entire
    # board, every role and city). One gate, applied uniformly, is the only way
    # the pool means the same thing regardless of where a job came from.
    #
    # ADR-003 v3: `job.source` is passed so the gate can apply a per-source gate
    # set. It is NOT a loosening of the default — a source with no configured
    # override still gets role+entry+location exactly as before.
    relevant = [
        job
        for job in fresh
        if is_relevant(
            job.title,
            job.location,
            job.description,
            source=job.source,
            # A fetcher that knows the posting is entry-level from WHERE it found
            # it (Internshala's /internships/ URL) says so here, instead of
            # leaving the gate to guess it from wording it doesn't contain.
            entry_level_hint=job.entry_level_hint,
        )
    ]

    if len(fetched) != len(relevant):
        logger.info(
            "Ingestion gate: %d fetched → %d fresh (≤%dd) → %d relevant (gates: %s)",
            len(fetched),
            len(fresh),
            settings.max_job_age_days,
            len(relevant),
            settings.ingestion_gate_overrides or "all sources strict",
        )

    # Per-source funnel. The aggregate line above hides the failure mode that
    # actually bit us: on 2026-07-27 Instahyre fetched 300 and stored 0, and
    # every summary reported a healthy "instahyre: 300" because by_source counts
    # FETCHED. A source can look fine forever while contributing nothing.
    #
    # This is deliberately a SECOND metric rather than a replacement — migration
    # 018's reasoning still holds, fetched==0 is the "source went dark" signal
    # and inserted==0 is a normal all-duplicates day. The signal missing until
    # now is "the gate ate everything this source returned".
    funnel: dict[str, dict[str, int]] = {}
    for job in fetched:
        funnel.setdefault(job.source, {"fetched": 0, "fresh": 0, "relevant": 0})["fetched"] += 1
    for job in fresh:
        funnel.setdefault(job.source, {"fetched": 0, "fresh": 0, "relevant": 0})["fresh"] += 1
    for job in relevant:
        funnel.setdefault(job.source, {"fetched": 0, "fresh": 0, "relevant": 0})["relevant"] += 1

    for source, counts in sorted(funnel.items()):
        if counts["fetched"] and not counts["relevant"]:
            # The Instahyre case. Loud, because it is indistinguishable from a
            # working source in every other number we report.
            logger.warning(
                "Source %s contributed NOTHING: %d fetched → %d fresh → 0 passed the gate "
                "(gates for this source: %s). The source is alive; the filter is rejecting all of it.",
                source,
                counts["fetched"],
                counts["fresh"],
                ",".join(sorted(gates_for_source(source))) or "none",
            )
        elif counts["fetched"]:
            logger.info(
                "Funnel %s: %d fetched → %d fresh → %d relevant (%.0f%% of fetched survives)",
                source,
                counts["fetched"],
                counts["fresh"],
                counts["relevant"],
                100 * counts["relevant"] / counts["fetched"],
            )

    fetched = relevant

    existing = _existing_rows_for_dedup(fetched)
    existing_keys = {row["dedup_key"] for row in existing}

    # Collect the new (non-duplicate) jobs first, embed them all in one
    # batched call, then insert — one embed_texts() call per refresh cycle
    # instead of one per job.
    new_jobs = []
    for job in fetched:
        dedup_key = make_dedup_key(job.title, job.company, job.location)
        if dedup_key in existing_keys or is_duplicate(job, existing):
            continue
        existing_keys.add(dedup_key)
        existing.append({"title": job.title, "company": job.company, "location": job.location, "dedup_key": dedup_key})
        new_jobs.append((job, dedup_key))

    embeddings = embed_texts([job_embedding_text(job.model_dump(mode="json")) for job, _ in new_jobs])

    payloads = []
    for (job, dedup_key), embedding in zip(new_jobs, embeddings):
        payload = job.model_dump(mode="json")
        payload["dedup_key"] = dedup_key
        payload["embedding"] = embedding
        # Persist the remote/hybrid classification the relevance gate above already
        # computed internally (migration 019) so the filter sheet can read it.
        payload["work_type"] = classify_work_type(job.location, job.title, job.description)
        # ADR-003 v3 (migration 027): with the role gate off for the broad pool,
        # the category is the only thing separating an SDE internship from a
        # telecalling one in the app's list.
        payload["category"] = classify_category(job.title, job.description)
        payloads.append(payload)

    # ADR-003 v4 (migration 028): the technical SUB-specialism, which `category`
    # can't express because every one of them collapses to 'engineering'.
    #
    # Batched across the whole run on purpose: Pass 1 (keywords) resolves most
    # rows for free, and whatever's left becomes ONE LLM call for the entire
    # insert rather than one per job. Called after the loop above because it
    # needs each row's `category` as its input — non-technical rows are skipped
    # outright and get NULL.
    tech_categories = classify_tech_categories_batch(
        [
            {"title": p.get("title"), "category": p.get("category"), "description": p.get("description")}
            for p in payloads
        ],
        use_llm=settings.enable_tech_category_llm,
    )
    for payload, tech_category in zip(payloads, tech_categories):
        payload["tech_category"] = tech_category

    # One batched upsert instead of one insert() round-trip per row — with
    # Greenhouse/Lever added (job source expansion, ADR-018), a single
    # refresh can find 200+ new rows, and 200+ sequential HTTP calls to
    # Supabase was enough on its own to blow past the app's 90s client
    # timeout. ignore_duplicates=True does the same job the old per-row
    # try/except did (skip a dedup_key collision from a concurrent refresh
    # race without erroring), just as one request instead of N.
    #
    # Chunked since ADR-003 v3: the broad Unstop pool's first run inserts ~800
    # rows at once, and a single upsert of 800 payloads each carrying a 768-dim
    # embedding is a multi-megabyte request body — big enough to hit PostgREST's
    # limits and slow enough to risk the cron's own timeout. Chunking is a pure
    # transport concern: on_conflict/ignore_duplicates make each chunk
    # independently idempotent, so a chunk failing mid-run leaves the earlier
    # ones committed rather than rolling everything back.
    inserted = 0
    for i in range(0, len(payloads), _UPSERT_CHUNK_SIZE):
        chunk = payloads[i : i + _UPSERT_CHUNK_SIZE]
        result = supabase.table("jobs").upsert(chunk, on_conflict="dedup_key", ignore_duplicates=True).execute()
        inserted += len(result.data)

    # `funnel` rides along so callers (and the cron's HTTP response) can see
    # WHERE a source's rows died, not just that few arrived. `fetched` here is
    # post-gate by this point, which is why the funnel carries the raw counts.
    return {"fetched": len(fetched), "inserted": inserted, "funnel": funnel}


# One upsert request per this many rows. 200 × 768-dim float embedding ≈ a few MB
# of JSON, which PostgREST handles comfortably; 800 in one request does not.
_UPSERT_CHUNK_SIZE = 200

# How many recent rows to pull as fuzzy-match context when the keyed lookup
# returns few. Not a correctness bound — exact duplicates are caught by
# dedup_key regardless — just enough recent history for is_duplicate()'s
# near-match heuristic to have something to compare against.
_DEDUP_CONTEXT_ROWS = 500


def _existing_rows_for_dedup(fetched: list[JobIn]) -> list[dict]:
    """Rows to check `fetched` against for duplicates.

    Fixed 2026-07-26 (ADR-003 v3). This used to be a blind "most recent 500 rows
    by ingested_at", which was fine at ~30 new rows/day and silently breaks at
    100-200: a 500-row window then covers under three days, so a posting we
    ingested last week is no longer in the comparison set at all.

    Exact duplicates were never actually at risk — the upsert's
    `on_conflict="dedup_key"` catches those in the database no matter what this
    returns. What broke is `is_duplicate()`'s FUZZY near-match check (same job,
    slightly different title/company punctuation), which only ever sees what this
    function hands it. So: look the incoming batch's dedup_keys up directly, and
    top up with recent rows for the fuzzy comparison. The keyed half is now exact
    and unbounded by volume; the recency half is a heuristic and stays capped.
    """
    keys = list({make_dedup_key(job.title, job.company, job.location) for job in fetched})

    rows: list[dict] = []
    seen: set[str] = set()
    # Chunked for the same reason the upsert is: a few hundred keys in one
    # `in_()` builds a very long URL, and PostgREST rejects those.
    for i in range(0, len(keys), _UPSERT_CHUNK_SIZE):
        chunk = keys[i : i + _UPSERT_CHUNK_SIZE]
        matched = supabase.table("jobs").select("title,company,location,dedup_key").in_("dedup_key", chunk).execute().data
        for row in matched:
            if row["dedup_key"] not in seen:
                seen.add(row["dedup_key"])
                rows.append(row)

    recent = (
        supabase.table("jobs")
        .select("title,company,location,dedup_key")
        .order("ingested_at", desc=True)
        .limit(_DEDUP_CONTEXT_ROWS)
        .execute()
        .data
    )
    for row in recent:
        if row["dedup_key"] not in seen:
            seen.add(row["dedup_key"])
            rows.append(row)
    return rows


# The free sources, as (name, fetcher) pairs. Named here so refresh_job_pool()
# can report a per-source raw count for the ingestion health log (plan 15,
# Phase F) instead of the opaque aggregate it used to return.
_FREE_SOURCES = [
    ("adzuna", fetch_adzuna),
    ("jsearch", fetch_jsearch),
    ("greenhouse", fetch_greenhouse),
    ("lever", fetch_lever),
]


async def refresh_job_pool() -> dict:
    """Fetch+dedup+embed+insert today's postings into the shared job pool
    (Brick 3/4). Plain function (not a route handler) so it can be called
    both from routers/jobs.py (behind auth) and jobs/daily_pipeline.py
    (the cron/batch path, which has no per-request auth dependency to
    resolve) without duplicating the logic in each caller.

    Free sources only. The Apify-scraped sources bill per result, so they are
    deliberately NOT here — see refresh_scraped_sources().

    Returns the usual {fetched, inserted} plus `by_source` (raw count per source
    before dedup) and `errors` (source → message for any that raised), which the
    cron feeds to the ingestion health log. return_exceptions keeps one source
    crashing from sinking the others — each fetch_* already swallows its own HTTP
    errors, so a raise here is unexpected, but the pool shouldn't die for it.
    """
    results = await asyncio.gather(*(fetcher() for _, fetcher in _FREE_SOURCES), return_exceptions=True)

    fetched: list[JobIn] = []
    by_source: dict[str, int] = {}
    errors: dict[str, str] = {}
    for (name, _), result in zip(_FREE_SOURCES, results):
        if isinstance(result, Exception):
            logger.warning("Free source %s raised: %s: %s", name, type(result).__name__, result)
            by_source[name] = 0
            errors[name] = f"{type(result).__name__}: {result}"
            continue
        by_source[name] = len(result)
        fetched.extend(result)

    summary = _dedup_embed_insert(fetched)
    summary["by_source"] = by_source
    summary["errors"] = errors
    return summary


# Weekday gate for the paid sources. `datetime.weekday()` is 0=Mon..6=Sun.
_WEEKDAYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")


def _is_due(weekdays: str, now: datetime | None = None) -> bool:
    """True when today falls in a comma-separated weekday list. Empty → never."""
    allowed = {d.strip().lower() for d in weekdays.split(",") if d.strip()}
    if not allowed:
        return False
    return _WEEKDAYS[(now or datetime.now(timezone.utc)).weekday()] in allowed


def _scraped_sources_due(now: datetime | None = None) -> list[tuple[str, object, int]]:
    """The (name, fetcher, cap) triples that should run today.

    Each source carries its own cadence and its own result cap, because they
    cost 10x different amounts per job: LinkedIn is cheap enough to run three
    times a week, Naukri is priciest and runs weekly. A source is skipped when
    its actor ID is unset (off) or today isn't one of its weekdays.
    """
    configured = [
        (
            "linkedin",
            settings.apify_linkedin_actor_id,
            fetch_linkedin_apify,
            settings.apify_linkedin_weekdays,
            settings.apify_linkedin_max_results,
        ),
        (
            "indeed",
            settings.apify_indeed_actor_id,
            fetch_indeed_apify,
            settings.apify_indeed_weekdays,
            settings.apify_indeed_max_results,
        ),
        (
            "naukri",
            settings.apify_naukri_actor_id,
            fetch_naukri_apify,
            settings.apify_naukri_weekdays,
            settings.apify_naukri_max_results,
        ),
    ]

    # Internshala used to be appended here as a fourth Apify source (ADR-003 v2).
    # It moved OUT of the paid rotation entirely in ADR-003 v4 (2026-07-27):
    # its listing pages turned out to be server-rendered, so it's now a free
    # direct-HTML fetch in refresh_india_boards() alongside Instahyre. Nothing
    # weekday-gated remains here but the three original paid actors — the
    # weekday cadence exists to ration MONEY, and these two no longer cost any.

    return [
        (name, fetcher, cap)
        for name, actor_id, fetcher, weekdays, cap in configured
        if actor_id.strip() and _is_due(weekdays, now)
    ]


def should_scrape_today(now: datetime | None = None) -> bool:
    """True when ANY scraped source is due today — the cheap check the daily
    pipeline uses to skip the whole paid path without building task lists."""
    return bool(settings.apify_api_token) and bool(_scraped_sources_due(now))


async def refresh_scraped_sources(now: datetime | None = None) -> dict:
    """The paid half of ingestion: LinkedIn/Indeed/Naukri via Apify (ADR-003,
    amended). Same fetch→dedup→embed→insert shape as refresh_job_pool(), but on
    a per-source cadence and never on a user-triggered path.

    Guards on spend, because every result here costs money:
      1. No token → no-op. (The kill switch: unset APIFY_API_TOKEN.)
      2. An empty actor ID or an off-cadence weekday skips that source entirely.
      3. Results per (role × location) are capped per-source.
      4. Concurrency is bounded — see the semaphore below.
    """
    if not settings.apify_api_token:
        logger.info("Scraped sources skipped: APIFY_API_TOKEN not set")
        return {"fetched": 0, "inserted": 0, "calls": 0, "skipped": "no_token"}

    due = _scraped_sources_due(now)
    if not due:
        logger.info("Scraped sources: none due today")
        return {"fetched": 0, "inserted": 0, "calls": 0, "skipped": "not_due"}

    roles, locations = _roles(), _locations()
    per_source_calls = len(roles) * len(locations)
    calls = per_source_calls * len(due)
    max_results = sum(per_source_calls * cap for _, _, cap in due)

    # Logged up front (not tallied afterwards) so the bill is predictable from
    # the logs BEFORE the money is spent, not merely explicable after.
    logger.info(
        "Scraped sources due today: %s → %d Apify calls (%d roles × %d locations × %d sources), "
        "≤%d billable results, ≤%d concurrent",
        ", ".join(f"{name}(≤{cap})" for name, _, cap in due),
        calls,
        len(roles),
        len(locations),
        len(due),
        max_results,
        settings.apify_max_concurrent_runs,
    )

    # Each Apify run reserves ~4GB and the free plan ceiling is 16GB in flight.
    # Unbounded gather() asks for 24-48GB at once and Apify 402s the overflow —
    # which looks exactly like "out of credit" but isn't (observed live at $0.84
    # of a $5 budget). The semaphore is what makes the fan-out safe.
    semaphore = asyncio.Semaphore(settings.apify_max_concurrent_runs)

    async def _guarded(fetcher, role: str, location: str, cap: int) -> list[JobIn]:
        async with semaphore:
            return await fetcher(role, location, cap)

    # Track the source name alongside each task so per-source counts survive the
    # flattened fan-out — the ingestion health log (plan 15, Phase F) needs to
    # know WHICH source went quiet, not just the aggregate total.
    task_sources = [name for name, _, _ in due for _ in roles for _ in locations]
    tasks = [
        _guarded(fetcher, role, location, cap)
        for _, fetcher, cap in due
        for role in roles
        for location in locations
    ]
    # return_exceptions=True: run_actor() already swallows HTTP failures, but a
    # mapping bug on one actor's payload must not lose the other sources' jobs
    # — one bad source degrades to zero jobs, it doesn't sink the run.
    results = await asyncio.gather(*tasks, return_exceptions=True)

    fetched: list[JobIn] = []
    by_source: dict[str, int] = {name: 0 for name, _, _ in due}
    errors: dict[str, str] = {}
    for name, result in zip(task_sources, results):
        if isinstance(result, Exception):
            logger.warning("Scraped source %s raised: %s: %s", name, type(result).__name__, result)
            # First error per source wins — enough to alert on; the rest are the
            # same failure repeated across role×location calls.
            errors.setdefault(name, f"{type(result).__name__}: {result}")
            continue
        by_source[name] += len(result)
        fetched.extend(result)

    summary = _dedup_embed_insert(fetched)
    summary["calls"] = calls
    summary["by_source"] = by_source
    summary["errors"] = errors
    logger.info(
        "Scraped sources: %d fetched, %d inserted after dedup/freshness",
        summary["fetched"],
        summary["inserted"],
    )
    return summary


async def refresh_unstop() -> dict:
    """Unstop internships (ADR-003 v2) — free, direct-fetch, cron-only.

    Deliberately NOT part of refresh_scraped_sources(): that path is gated on the
    Apify token and shaped around per-result billing / weekday cost-cadence, none
    of which apply to a free public endpoint. Unstop is still *scraping* under
    ADR-003 v2, though, so it keeps the two constraints that matter — behind
    enable_india_sources (the sign-off gate) and callable only from the cron
    batch (never refresh_job_pool / "Run agent now"). Same fetch→dedup→embed→
    insert back-half as every other source.
    """
    if not settings.enable_india_sources:
        logger.info("Unstop skipped: ENABLE_INDIA_SOURCES is false")
        return {"fetched": 0, "inserted": 0, "by_source": {}, "errors": {}, "skipped": "disabled"}

    # fetch_unstop() is written to never raise, but wrap it anyway:
    # if it somehow does, Unstop must still land in the health log as an ERROR
    # row (by_source={"unstop":0} + an errors entry) rather than being swallowed
    # by the pipeline's outer handler and vanishing — a dead source the ops alert
    # can't see is worse than a dead source. This is the fix for the 2026-07-21
    # incident where an Unstop exception left NO row at all.
    try:
        jobs = await fetch_unstop(settings.unstop_max_results)
    except Exception as e:
        logger.exception("Unstop fetch raised")
        return {"fetched": 0, "inserted": 0, "by_source": {"unstop": 0}, "errors": {"unstop": f"{type(e).__name__}: {e}"}}

    logger.info("Unstop: fetched %d internships (cap %d)", len(jobs), settings.unstop_max_results)
    summary = _dedup_embed_insert(jobs)
    summary["by_source"] = {"unstop": len(jobs)}
    summary["errors"] = {}
    return summary


def retire_stale_jobs(source: str, seen_external_ids: set[str]) -> dict:
    """Soft-retire postings from `source` that did NOT appear in today's fetch.

    Neither Internshala nor Instahyre exposes a usable expiry date on its listing
    pages, so presence IS the signal: a posting that has dropped out of the live
    listing is closed. Runs per-source so one source's bad day can never retire
    another's rows.

    SOFT delete (`is_active = false`), never a DELETE — migration 028 explains
    why at length, but in short: `jobs` rows are referenced by `applications`,
    `matches` and `tailored_resumes`, and hard-deleting one would either violate
    the FK or silently destroy a user's own tracked history because a company
    took a listing down. After this runs, a retired job disappears from browsing
    and matching while every application the user already filed against it still
    resolves and renders.

    Refuses to act on an EMPTY seen-set. A source that errored out or got
    throttled returns zero ids, and "retire everything we have from this source"
    is exactly the wrong response to a failed fetch — that's the difference
    between a quiet day and wiping the source from the app. A genuinely empty
    live listing is indistinguishable from a broken fetch here, so the safe
    reading wins and the ingestion health log is what surfaces a dead source.
    """
    if not seen_external_ids:
        logger.warning("Retirement skipped for %s: empty seen-set (treated as a failed fetch, not an empty board)", source)
        return {"retired": 0, "revived": 0, "skipped": "empty_seen_set"}

    rows = supabase.table("jobs").select("id,external_id,is_active").eq("source", source).execute().data

    stale_ids = [r["id"] for r in rows if r.get("is_active") and str(r.get("external_id")) not in seen_external_ids]
    # The other direction, and it is NOT optional. The main insert upserts with
    # ignore_duplicates=True, so a row we retired yesterday that is live on the
    # board again today is skipped by the upsert and would stay is_active=false
    # forever — invisible in the app despite being an open posting. Retirement
    # is only safe to do at all because it's reversible right here.
    revived_ids = [r["id"] for r in rows if not r.get("is_active") and str(r.get("external_id")) in seen_external_ids]

    def _set_active(ids: list[str], value: bool) -> int:
        # Chunked for the same transport reason the upsert is: a few hundred ids
        # in one in_() builds a URL long enough for PostgREST to reject.
        changed = 0
        for i in range(0, len(ids), _UPSERT_CHUNK_SIZE):
            chunk = ids[i : i + _UPSERT_CHUNK_SIZE]
            result = supabase.table("jobs").update({"is_active": value}).in_("id", chunk).execute()
            changed += len(result.data)
        return changed

    retired = _set_active(stale_ids, False) if stale_ids else 0
    revived = _set_active(revived_ids, True) if revived_ids else 0

    if retired or revived:
        logger.info("Retirement %s: %d retired, %d revived, %d rows scanned", source, retired, revived, len(rows))
    return {"retired": retired, "revived": revived}


def _india_board_sources() -> list[tuple[str, object]]:
    """The free India boards as (name, fetcher) pairs. Both are direct-fetch and
    cost nothing per result, so unlike the Apify sources they carry no weekday
    cadence — they run every cron day.

    A function rather than a module-level list on purpose: a list literal binds
    the function objects at IMPORT time, which silently defeats
    patch("services.job_ingestion.fetch_instahyre") and let the containment tests
    hit the live API. Resolving globals per call keeps the seam patchable.
    """
    return [
        ("internshala", fetch_internshala),
        ("instahyre", fetch_instahyre),
    ]


async def refresh_india_boards() -> dict:
    """Internshala + Instahyre (ADR-003 v4) — free, direct-fetch, cron-only.

    Deliberately NOT in refresh_job_pool()'s _FREE_SOURCES, despite both being
    free. refresh_job_pool() is reachable from the app's "Run agent now" button,
    and ADR-003 permits these sources only at personal scale on a daily cron —
    putting them there would let any user trigger scraping on demand by tapping
    a button. Free is about COST; ADR-003 is about CADENCE, and they're separate
    constraints. Same containment reasoning as refresh_unstop(), whose shape this
    follows: gated on enable_india_sources, called only from the cron batch.

    Each fetcher is wrapped so its failure costs only its own jobs and still
    lands in the ingestion health log as an explicit zero — a dead source the
    ops alert can't see is worse than a dead source (the 2026-07-21 Unstop
    incident).

    Retirement runs per-source and only for a source that actually returned
    rows, so a failed fetch can never be read as "the board is empty now".
    """
    if not settings.enable_india_sources:
        logger.info("India boards skipped: ENABLE_INDIA_SOURCES is false")
        return {"fetched": 0, "inserted": 0, "by_source": {}, "errors": {}, "skipped": "disabled"}

    sources = _india_board_sources()
    results = await asyncio.gather(*(fetcher() for _, fetcher in sources), return_exceptions=True)

    fetched: list[JobIn] = []
    by_source: dict[str, int] = {}
    errors: dict[str, str] = {}
    seen_by_source: dict[str, set[str]] = {}

    for (name, _), result in zip(sources, results):
        if isinstance(result, Exception):
            logger.warning("India board %s raised: %s: %s", name, type(result).__name__, result)
            by_source[name] = 0
            errors[name] = f"{type(result).__name__}: {result}"
            continue
        # Health tracks FETCHED, not inserted: an all-duplicate day is a healthy
        # day, and alerting on inserts would page on a working source.
        by_source[name] = len(result)
        fetched.extend(result)
        # A source that returned NOTHING is not registered as "seen", so it can't
        # be retired below. Both fetchers swallow their own HTTP errors and
        # return [] rather than raising, so an empty list is far more often a
        # broken fetch than a genuinely empty board — and "retire everything"
        # is the worst possible response to a broken fetch. retire_stale_jobs()
        # refuses an empty seen-set too; this is the belt to that's braces.
        if result:
            seen_by_source[name] = {job.external_id for job in result}

    summary = _dedup_embed_insert(fetched)
    summary["by_source"] = by_source
    summary["errors"] = errors

    # After the insert, so a posting that reappeared today is already back to
    # is_active=true via the upsert before anything gets retired.
    retired: dict[str, int] = {}
    for name, seen in seen_by_source.items():
        try:
            retired[name] = retire_stale_jobs(name, seen).get("retired", 0)
        except Exception as e:
            # Retirement is housekeeping — never let it sink an otherwise good
            # ingestion run.
            logger.warning("Retirement failed for %s: %s: %s", name, type(e).__name__, e)
            retired[name] = 0
    summary["retired"] = retired

    logger.info(
        "India boards: %d fetched, %d inserted, retired %s",
        summary["fetched"],
        summary["inserted"],
        retired or "nothing",
    )
    return summary


def backfill_tech_categories(limit: int = 500) -> dict:
    """Catch-up for rows ingested before migration 028 added `tech_category`.

    Safe to call repeatedly — only touches engineering/data rows where
    tech_category is still null. Same posture as backfill_job_embeddings().

    Why this is needed at all: 028's backfill runs in SQL, so it can only do
    coarse title-only regex and deliberately leaves anything ambiguous NULL
    (a wrong specialism label is worse than an absent one). That left 112 real
    engineering rows unreachable by every specialism filter. This pass runs the
    ACTUAL classifier — title + skills + description, keyword first, batched LLM
    for the residue — which measured 96% resolution on live listings.

    Scoped to engineering/data because tech_category is meaningless elsewhere:
    asking "which engineering specialism is this sales role?" is a category
    error, and NULL is the correct answer for those rows.
    """
    rows = (
        supabase.table("jobs")
        .select("id,title,category,description")
        .in_("category", ["engineering", "data"])
        .is_("tech_category", "null")
        .limit(limit)
        .execute()
        .data
    )
    if not rows:
        return {"backfilled": 0}

    results = classify_tech_categories_batch(
        [{"title": r.get("title"), "category": r.get("category"), "description": r.get("description")} for r in rows],
        use_llm=settings.enable_tech_category_llm,
    )

    backfilled = 0
    for row, tech_category in zip(rows, results):
        if not tech_category:
            # The classifier declined to place it. Leave NULL rather than
            # inventing a specialism — same reasoning as the SQL backfill.
            continue
        supabase.table("jobs").update({"tech_category": tech_category}).eq("id", row["id"]).execute()
        backfilled += 1

    logger.info("Backfilled tech_category for %d of %d candidate rows", backfilled, len(rows))
    return {"backfilled": backfilled, "candidates": len(rows)}


def backfill_job_embeddings() -> dict:
    """One-off catch-up for jobs ingested before Brick 4 added embedding.
    Safe to call repeatedly — only touches rows where embedding is null.
    """
    rows = supabase.table("jobs").select("id,title,company,description").is_("embedding", "null").execute().data
    if not rows:
        return {"backfilled": 0}

    embeddings = embed_texts([job_embedding_text(row) for row in rows])
    for row, embedding in zip(rows, embeddings):
        supabase.table("jobs").update({"embedding": embedding}).eq("id", row["id"]).execute()

    return {"backfilled": len(rows)}
