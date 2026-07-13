"""Apify fetcher tests (ADR-003, amended).

The fixtures below are REAL rows captured from live actor runs on 2026-07-13,
trimmed but not reshaped. That matters: the whole risk in this feature is that
an actor's field names aren't what we think they are, and a fixture invented to
match the mapping would test nothing.

Two contracts under test:
  1. Mapping — each actor's idiosyncratic field names land in the right JobIn
     slots, with salary parsed to numbers and currency inferred (never USD by
     omission).
  2. Isolation — every failure mode returns [] and never raises, so one dead
     actor can't sink a shared pipeline run.
"""

import asyncio
from unittest.mock import AsyncMock, patch

import httpx
import pytest

from config import settings
from services.job_sources import (
    _primary_city,
    fetch_indeed_apify,
    fetch_linkedin_apify,
    fetch_naukri_apify,
)


# --- location canonicalization ----------------------------------------------
# All left-hand values below were returned by live actor runs on 2026-07-13.
# Without this, the same posting on two boards produces two dedup keys.
@pytest.mark.parametrize(
    "raw,expected",
    [
        ("Hyderabad, Telangana", "Hyderabad"),  # Indeed
        ("Hyderabad, Telangana, India", "Hyderabad"),  # LinkedIn
        ("Greater Hyderabad Area", "Hyderabad"),  # LinkedIn
        ("Hybrid - Hyderabad, Chennai, Delhi / NCR", "Hyderabad"),  # Naukri
        # The Bangalore/Bengaluru split is the one that actually costs us
        # duplicate rows — Adzuna says one, LinkedIn says the other.
        ("Bengaluru", "Bangalore"),
        ("Bengaluru East", "Bangalore"),
        ("Bangalore Urban", "Bangalore"),
        ("Bangalore City", "Bangalore"),
        ("Greater Bengaluru Area", "Bangalore"),
        ("Mumbai Metropolitan Region", "Mumbai"),
        ("Navi Mumbai", "Mumbai"),
        ("Pune Division", "Pune"),
        ("Gurgaon", "Delhi NCR"),
        ("Noida", "Delhi NCR"),
        ("Remote", "Remote"),
        # Unknown cities pass through rather than being dropped — a job in
        # Kozhikode is still a real job, it just won't cross-source dedup.
        ("Kozhikode", "Kozhikode"),
        (None, None),
        ("", None),
    ],
)
def test_primary_city_canonicalizes(raw, expected):
    assert _primary_city(raw) == expected

# --- real captured rows ------------------------------------------------------

INDEED_ROW = {
    "id": "7b1b4e44a4c28f72",
    "positionName": "Specialist - Software Engineering",
    "company": "LTM",
    "location": "Hyderabad, Telangana",
    "description": "Role description\n\nAI Software Developer\n\nExp - 5 to 7 years",
    "salary": None,
    "url": "https://in.indeed.com/viewjob?jk=7b1b4e44a4c28f72",
    "postedAt": "2 days ago",
    "postingDateParsed": "2026-07-10T23:01:56.167Z",
    "isExpired": False,
    "jobType": ["Internship"],
}

LINKEDIN_ROW = {
    "id": "4432860087",
    "title": "React Developer",
    "companyName": "Sonata Software",
    "location": "Hyderabad, Telangana, India",
    "descriptionText": "About Sonata Software\n\nSonata Software, with over $1.2 Billion Revenue",
    "salary": "",
    "link": "https://in.linkedin.com/jobs/view/react-developer-at-sonata-software-4432860087",
    "postedAt": "2026-06-24",
}

NAUKRI_ROW = {
    "jobId": "110326015629",
    "title": "Fullstack Developer",
    "companyName": "Capgemini",
    "locationText": "Hybrid - Hyderabad, Chennai, Delhi / NCR",
    "locations": ["Hyderabad", "Chennai", "Delhi", "NCR"],
    "jobDescriptionPreview": "Bachelors degree in Computer Science, Engineering...",
    "jobDescription": "Full JD text " * 50,
    "jobUrl": "https://www.naukri.com/job-listings-fullstack-developer-capgemini-hyderabad",
    "postedDate": "2026-07-11T04:04:15.061704+00:00",
    "salaryMin": None,
    "salaryMax": None,
    "salaryCurrency": None,
    "salaryText": None,
}


@pytest.fixture(autouse=True)
def _configured(monkeypatch):
    monkeypatch.setattr(settings, "apify_api_token", "test-token")
    monkeypatch.setattr(settings, "apify_linkedin_actor_id", "curious_coder~linkedin-jobs-scraper")
    monkeypatch.setattr(settings, "apify_indeed_actor_id", "misceres~indeed-scraper")
    monkeypatch.setattr(settings, "apify_naukri_actor_id", "makework36~naukri-scraper")
    monkeypatch.setattr(settings, "apify_naukri_fetch_details", True)


def _rows(payload: list):
    return AsyncMock(return_value=payload)


# --- mapping -----------------------------------------------------------------


def test_indeed_maps_real_row():
    with patch("services.job_sources.run_actor", new=_rows([INDEED_ROW])):
        jobs = asyncio.run(fetch_indeed_apify("fullstack developer", "Hyderabad", 10))

    assert len(jobs) == 1
    job = jobs[0]
    assert job.source == "indeed"
    assert job.external_id == "7b1b4e44a4c28f72"
    assert job.title == "Specialist - Software Engineering"  # NOT `title` — actor says positionName
    assert job.company == "LTM"
    assert job.location == "Hyderabad"  # normalized from "Hyderabad, Telangana" for cross-source dedup
    assert job.redirect_url.startswith("https://in.indeed.com/viewjob")
    # postingDateParsed (ISO), not postedAt ("2 days ago") — the freshness gate
    # needs something comparable.
    assert job.posted_at.year == 2026 and job.posted_at.month == 7
    # No salary stated → nulls, and crucially NOT a "$" default.
    assert (job.salary_min, job.salary_max) == (None, None)


def test_indeed_skips_expired_postings():
    expired = {**INDEED_ROW, "isExpired": True}
    with patch("services.job_sources.run_actor", new=_rows([expired, INDEED_ROW])):
        jobs = asyncio.run(fetch_indeed_apify("fullstack developer", "Hyderabad", 10))
    # Indeed keeps serving dead postings; ingesting one sends the user to a 404.
    assert len(jobs) == 1


def test_indeed_parses_inr_salary_string_and_currency():
    row = {**INDEED_ROW, "salary": "₹6,00,000 - ₹12,00,000 a year"}
    with patch("services.job_sources.run_actor", new=_rows([row])):
        job = asyncio.run(fetch_indeed_apify("dev", "Hyderabad", 10))[0]

    assert job.salary_min == 600_000
    assert job.salary_max == 1_200_000
    assert job.salary_currency == "INR"


def test_linkedin_maps_real_row():
    with patch("services.job_sources.run_actor", new=_rows([LINKEDIN_ROW])):
        job = asyncio.run(fetch_linkedin_apify("fullstack developer", "Hyderabad", 10))[0]

    assert job.source == "linkedin"
    assert job.external_id == "4432860087"
    assert job.title == "React Developer"
    assert job.company == "Sonata Software"  # companyName
    assert job.location == "Hyderabad"  # from "Hyderabad, Telangana, India"
    assert job.description.startswith("About Sonata Software")  # descriptionText
    assert job.redirect_url.startswith("https://in.linkedin.com/jobs/view/")  # `link`, not `applyUrl`
    assert job.posted_at.year == 2026
    # Empty salary string must not become 0 or "$".
    assert (job.salary_min, job.salary_max) == (None, None)
    # Currency still inferable from the location, even with no salary figure.
    assert job.salary_currency == "INR"


def test_linkedin_enforces_min_count_of_10():
    # The actor 400s on count < 10 (verified live). Asking for 5 must send 10,
    # not fail the whole source.
    spy = AsyncMock(return_value=[])
    with patch("services.job_sources.run_actor", new=spy):
        asyncio.run(fetch_linkedin_apify("dev", "Hyderabad", 5))

    run_input = spy.call_args[0][1]
    assert run_input["count"] == 10


def test_linkedin_builds_a_search_url_not_role_fields():
    spy = AsyncMock(return_value=[])
    with patch("services.job_sources.run_actor", new=spy):
        asyncio.run(fetch_linkedin_apify("fullstack developer", "Hyderabad", 10))

    urls = spy.call_args[0][1]["urls"]
    assert len(urls) == 1
    assert "linkedin.com/jobs/search" in urls[0]
    assert "keywords=fullstack+developer" in urls[0]
    assert "location=Hyderabad" in urls[0]


# --- internship / fresher targeting ------------------------------------------
# The point of these three: surface internships WITHOUT a second query per role.
# A separate "<role> intern" call (what fetch_adzuna does) would double the Apify
# call count and push the bill over the free plan's $5/mo cap.


def test_linkedin_biases_keywords_toward_interns_not_f_E():
    spy = AsyncMock(return_value=[])
    with patch("services.job_sources.run_actor", new=spy):
        asyncio.run(fetch_linkedin_apify("fullstack developer", "Hyderabad", 10))

    url = spy.call_args[0][1]["urls"][0]
    assert "keywords=fullstack+developer+intern" in url
    # f_E (LinkedIn's experience-level filter) is deliberately NOT used: the
    # actor ignores it. Verified live — f_E=1 ("internships only") still returned
    # a Mid-Senior "Senior Full-Stack Software Engineer". Asserting its absence
    # so nobody "helpfully" re-adds a param that silently does nothing.
    assert "f_E" not in url
    # And it stays ONE call — a second "<role> intern" query would double the bill.
    assert len(spy.call_args_list) == 1


def test_naukri_caps_experience_years():
    spy = AsyncMock(return_value=[])
    with patch("services.job_sources.run_actor", new=spy):
        asyncio.run(fetch_naukri_apify("fullstack developer", "Hyderabad", 8))

    run_input = spy.call_args[0][1]
    assert run_input["experienceMin"] == 0
    # 0..2 years, so genuine fresher full-time roles survive alongside interns.
    assert run_input["experienceMax"] == 2


def test_indeed_appends_intern_to_the_query():
    # Indeed's actor has no experience filter, so the query text is the only lever.
    spy = AsyncMock(return_value=[])
    with patch("services.job_sources.run_actor", new=spy):
        asyncio.run(fetch_indeed_apify("fullstack developer", "Hyderabad", 5))

    assert spy.call_args[0][1]["position"] == "fullstack developer intern"


def test_indeed_suffix_is_configurable_off(monkeypatch):
    monkeypatch.setattr(settings, "apify_indeed_query_suffix", "")
    spy = AsyncMock(return_value=[])
    with patch("services.job_sources.run_actor", new=spy):
        asyncio.run(fetch_indeed_apify("fullstack developer", "Hyderabad", 5))

    assert spy.call_args[0][1]["position"] == "fullstack developer"


def test_naukri_maps_real_row_and_prefers_full_description():
    with patch("services.job_sources.run_actor", new=_rows([NAUKRI_ROW])):
        job = asyncio.run(fetch_naukri_apify("fullstack developer", "Hyderabad", 10))[0]

    assert job.source == "naukri"
    assert job.external_id == "110326015629"  # jobId
    assert job.company == "Capgemini"
    # "Hybrid - Hyderabad, Chennai, ..." must not become the dedup location.
    assert job.location == "Hyderabad"
    # The full JD, not the 90-char preview — the preview would under-embed the job.
    assert job.description == NAUKRI_ROW["jobDescription"]
    assert len(job.description) > len(NAUKRI_ROW["jobDescriptionPreview"])
    # Naukri is India-only, so a missing currency defaults to INR rather than $.
    assert job.salary_currency == "INR"


def test_naukri_uses_actor_parsed_numeric_salary_when_present():
    row = {**NAUKRI_ROW, "salaryMin": 600000, "salaryMax": 1500000, "salaryCurrency": "INR"}
    with patch("services.job_sources.run_actor", new=_rows([row])):
        job = asyncio.run(fetch_naukri_apify("dev", "Hyderabad", 10))[0]

    assert (job.salary_min, job.salary_max, job.salary_currency) == (600000, 1500000, "INR")


def test_naukri_falls_back_to_parsing_lacs_text():
    # The plan's named acceptance case: "6-15 Lacs PA" → numeric INR, not a
    # dollar-prefixed string.
    row = {**NAUKRI_ROW, "salaryText": "6-15 Lacs PA"}
    with patch("services.job_sources.run_actor", new=_rows([row])):
        job = asyncio.run(fetch_naukri_apify("dev", "Hyderabad", 10))[0]

    assert job.salary_min == 600_000
    assert job.salary_max == 1_500_000
    assert job.salary_currency == "INR"


def test_naukri_honours_fetch_details_toggle(monkeypatch):
    monkeypatch.setattr(settings, "apify_naukri_fetch_details", False)
    spy = AsyncMock(return_value=[])
    with patch("services.job_sources.run_actor", new=spy):
        asyncio.run(fetch_naukri_apify("dev", "Hyderabad", 10))

    assert spy.call_args[0][1]["fetchDetails"] is False


# --- isolation: every failure mode yields [], never raises --------------------


@pytest.mark.parametrize("fetcher", [fetch_linkedin_apify, fetch_indeed_apify, fetch_naukri_apify])
def test_actor_failure_returns_empty(fetcher):
    # run_actor already swallows HTTP errors and returns [] — assert the fetcher
    # doesn't then blow up on the empty list.
    with patch("services.job_sources.run_actor", new=AsyncMock(return_value=[])):
        assert asyncio.run(fetcher("dev", "Hyderabad", 10)) == []


@pytest.mark.parametrize("fetcher", [fetch_linkedin_apify, fetch_indeed_apify, fetch_naukri_apify])
def test_malformed_rows_are_skipped_not_fatal(fetcher):
    # Rows missing the ID/title an actor is supposed to always send. A posting we
    # can't identify or name is worthless downstream — drop it, keep the rest.
    junk = [{}, {"title": "No ID"}, {"id": "x"}, {"jobId": "y"}]
    with patch("services.job_sources.run_actor", new=_rows(junk)):
        assert asyncio.run(fetcher("dev", "Hyderabad", 10)) == []


@pytest.mark.parametrize("fetcher", [fetch_linkedin_apify, fetch_indeed_apify, fetch_naukri_apify])
def test_timeout_does_not_raise(fetcher):
    # The real client turns this into []; assert the fetcher surfaces no exception
    # to asyncio.gather() either way.
    with patch("services.apify_client.httpx.AsyncClient.post", new=AsyncMock(side_effect=httpx.ReadTimeout("t"))):
        assert asyncio.run(fetcher("dev", "Hyderabad", 10)) == []
