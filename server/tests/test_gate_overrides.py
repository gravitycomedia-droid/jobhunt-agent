"""Per-source ingestion gate policy (ADR-003 v3, services/job_filter.py).

The gate used to be a fixed AND of role+entry+location applied identically to
every source. That's correct for the keyword APIs and wrong for a full-catalogue
crawl: measured live 2026-07-26, the role gate alone discards ~92% of Unstop's
2,022 open postings, so the source could fetch perfectly and still land ~20
rows/day.

The risk this file exists to guard is the obvious one — that making the gate
configurable quietly loosens it for sources nobody meant to touch. So the first
and most important test is that an unconfigured source is completely unchanged.
"""

import pytest

from config import settings
from services.job_filter import gates_for_source, is_relevant

# A posting that fails role+location but passes entry-level: exactly the kind of
# row the broad pool is meant to keep and the strict gate is meant to drop.
_SALES_INTERN = {"title": "Sales Executive Internship", "location": "Pune", "description": "Cold calling."}
# Passes all three — must survive under every policy.
_TARGET_ROLE = {"title": "Frontend Developer Intern", "location": "Bengaluru", "description": "React work."}
# Fails entry-level. Must be dropped wherever the entry gate is on.
_SENIOR = {"title": "Senior Frontend Engineer", "location": "Bengaluru", "description": "React work."}


def _relevant(job: dict, source: str | None) -> bool:
    return is_relevant(job["title"], job["location"], job["description"], source=source)


@pytest.fixture(autouse=True)
def _default_overrides(monkeypatch):
    monkeypatch.setattr(settings, "ingestion_gate_overrides", "unstop:entry")


# --- the blast-radius guard --------------------------------------------------


@pytest.mark.parametrize("source", ["adzuna", "jsearch", "greenhouse", "lever", "linkedin", "naukri", "manual", None])
def test_unconfigured_sources_still_get_all_three_gates(source):
    """The whole safety property of this feature: widening ONE source must not
    widen any other. If this fails, the broad pool has leaked into the API
    sources and the entire pool's meaning has changed silently."""
    assert gates_for_source(source) == frozenset({"role", "entry", "location"})
    assert _relevant(_TARGET_ROLE, source) is True
    assert _relevant(_SALES_INTERN, source) is False  # wrong role AND wrong city
    assert _relevant(_SENIOR, source) is False


def test_omitting_source_entirely_is_the_strict_path():
    """A caller that hasn't been updated to pass `source` can only ever be MORE
    selective, never accidentally less."""
    assert is_relevant(_SALES_INTERN["title"], _SALES_INTERN["location"], _SALES_INTERN["description"]) is False


# --- the configured source ---------------------------------------------------


def test_unstop_keeps_only_the_entry_level_gate():
    assert gates_for_source("unstop") == frozenset({"entry"})
    # Off-role, off-city, but entry-level → kept. This is the ~87 rows/day.
    assert _relevant(_SALES_INTERN, "unstop") is True
    assert _relevant(_TARGET_ROLE, "unstop") is True


def test_entry_level_still_bites_for_the_broad_source():
    """The one gate deliberately left ON. A senior sales role is dead weight in a
    fresher's pool no matter how well the app filters by category."""
    assert _relevant(_SENIOR, "unstop") is False
    assert _relevant({"title": "VP of Marketing", "location": "Remote", "description": "10+ years."}, "unstop") is False


def test_source_matching_is_case_insensitive():
    assert gates_for_source("UNSTOP") == frozenset({"entry"})
    assert gates_for_source("  Unstop ") == frozenset({"entry"})


# --- parsing -----------------------------------------------------------------


def test_multiple_sources_and_multi_gate_specs(monkeypatch):
    monkeypatch.setattr(settings, "ingestion_gate_overrides", "unstop:entry, internshala:entry+location")
    assert gates_for_source("unstop") == frozenset({"entry"})
    assert gates_for_source("internshala") == frozenset({"entry", "location"})
    assert gates_for_source("adzuna") == frozenset({"role", "entry", "location"})


def test_none_means_ingest_everything(monkeypatch):
    monkeypatch.setattr(settings, "ingestion_gate_overrides", "unstop:none")
    assert gates_for_source("unstop") == frozenset()
    assert _relevant(_SENIOR, "unstop") is True


def test_unknown_gate_names_are_dropped_not_honoured(monkeypatch, caplog):
    """A typo'd gate must not silently widen the pool — the failure mode most
    likely to go unnoticed, because it looks like everything is working."""
    monkeypatch.setattr(settings, "ingestion_gate_overrides", "unstop:entry+seniorty")
    assert gates_for_source("unstop") == frozenset({"entry"})
    assert "seniorty" in caplog.text


def test_empty_setting_makes_every_source_strict(monkeypatch):
    monkeypatch.setattr(settings, "ingestion_gate_overrides", "")
    assert gates_for_source("unstop") == frozenset({"role", "entry", "location"})
    assert _relevant(_SALES_INTERN, "unstop") is False


def test_malformed_entries_are_ignored_without_raising(monkeypatch):
    # A half-typed env var must degrade to "strict", never crash the cron.
    monkeypatch.setattr(settings, "ingestion_gate_overrides", "garbage, :entry, unstop:entry, ,")
    assert gates_for_source("unstop") == frozenset({"entry"})
    assert gates_for_source("garbage") == frozenset({"role", "entry", "location"})
