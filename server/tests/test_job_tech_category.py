"""Technical sub-specialism classification (ADR-003 v4).

Two properties matter most here and both are about restraint:

  1. **Pass 1 does the work.** The LLM must only ever see rows keyword logic
     explicitly could not place, batched into ONE call. Golden rule 2.
  2. **Nothing here can fail ingestion.** Every failure path — no provider, a
     raising provider, an invented category, a skipped row — degrades to a real
     label, never an exception and never a hole.

Priority ordering carries real weight (full_stack before frontend/backend,
mobile before frontend, ai_ml before data_science), so it's asserted directly
rather than left implicit in the pattern list.
"""

from unittest.mock import MagicMock, patch

import pytest

from services.job_tech_category import (
    TECH_CATEGORIES,
    TechCategoryBatch,
    classify_tech_categories_batch,
    classify_tech_category,
    classify_tech_category_pass1,
)


# --- Pass 1: the free keyword pass -------------------------------------------


@pytest.mark.parametrize(
    "title,expected",
    [
        ("Frontend Developer", "frontend"),
        ("React.js Developer Intern", "frontend"),
        ("Backend Engineer", "backend"),
        ("Node.js Developer", "backend"),
        ("Django Developer Internship", "backend"),
        ("Full Stack Development", "full_stack"),
        ("MERN Stack Intern", "full_stack"),
        ("Android Developer", "mobile"),
        ("Flutter Development", "mobile"),
        ("Machine Learning Engineer", "ai_ml"),
        ("GenAI Developer (Internship)", "ai_ml"),
        ("Data Analyst", "data_science"),
        ("DevOps Engineer - Intern", "devops_cloud"),
        ("Cyber Security Analyst", "cybersecurity"),
        ("QA Automation Engineer", "qa_testing"),
        ("Blockchain Developer", "blockchain"),
    ],
)
def test_pass1_classifies_common_titles(title, expected):
    assert classify_tech_category_pass1(title) == expected


def test_full_stack_beats_its_own_component_words():
    # "Full Stack (React + Node)" contains the strongest token of BOTH frontend
    # and backend and is neither.
    assert classify_tech_category_pass1("Full Stack Developer (React + Node.js)") == "full_stack"


def test_react_native_is_mobile_not_frontend():
    # "react" is the frontend pattern's most common hit, so ordering is the only
    # thing keeping React Native out of it.
    assert classify_tech_category_pass1("React Native Developer") == "mobile"


def test_ml_engineer_is_ai_ml_not_data_science():
    assert classify_tech_category_pass1("ML Engineer") == "ai_ml"
    assert classify_tech_category_pass1("Data Scientist") == "data_science"


def test_bare_ai_in_marketing_prose_does_not_win():
    """Regression guard for the bug job_category.py hit live: an unqualified
    "AI" in company boilerplate filed a video-editing role under ML. Two-letter
    tokens need role context."""
    assert classify_tech_category_pass1("Video Editing Intern", description="We use cutting-edge AI platforms.") != "ai_ml"


def test_skill_tags_outrank_a_generic_title():
    """The single most valuable case for this module. "Software Engineer" is the
    commonest title in the pool and says nothing; the curated skill tags both new
    sources provide are what actually identify the role."""
    assert classify_tech_category_pass1("Software Engineer", skills=["React", "Redux", "CSS"]) == "frontend"
    assert classify_tech_category_pass1("Software Engineer", skills=["Django", "PostgreSQL"]) == "backend"


def test_title_outranks_the_description_body():
    # An incidental JD mention must never beat the plain statement of the job.
    assert classify_tech_category_pass1("Frontend Developer", description="You will work with our AWS Kubernetes cluster.") == "frontend"


def test_unplaceable_row_is_none_not_a_guess():
    assert classify_tech_category_pass1("Software Engineer") is None
    assert classify_tech_category_pass1(None) is None


# --- The category gate --------------------------------------------------------


def test_non_technical_postings_get_none():
    """"Which engineering specialism is this telecalling role?" has no answer,
    and `category` already records that it's sales. NULL is the correct value —
    there is deliberately no 'non_it' member."""
    assert classify_tech_category("Sales Executive", category="sales") is None
    assert classify_tech_category("HR Intern", category="hr") is None
    # ...even when the text WOULD match a pattern.
    assert classify_tech_category("Growth Engineer", category="marketing") is None


def test_engineering_and_data_are_the_technical_categories():
    assert classify_tech_category("Backend Developer", category="engineering") == "backend"
    assert classify_tech_category("Data Analyst", category="data") == "data_science"


# --- Batching: the LLM sees only the residue ---------------------------------


def _rows(*specs) -> list[dict]:
    return [{"title": t, "category": c, "skills": None, "description": None} for t, c in specs]


def test_resolved_rows_never_reach_the_llm():
    rows = _rows(("Frontend Developer", "engineering"), ("Sales Executive", "sales"))
    with patch("services.llm.run_tech_category_batch") as llm:
        result = classify_tech_categories_batch(rows)

    assert result == ["frontend", None]
    assert not llm.called, "keyword-resolved rows must cost nothing"


def test_only_unresolved_technical_rows_are_sent():
    rows = _rows(
        ("Frontend Developer", "engineering"),  # resolved
        ("Software Engineer", "engineering"),  # UNRESOLVED → goes to the LLM
        ("Sales Executive", "sales"),  # non-technical, never sent
    )
    llm = MagicMock(return_value=TechCategoryBatch(verdicts=[{"index": 0, "tech_category": "backend"}]))
    with patch("services.llm.run_tech_category_batch", new=llm):
        result = classify_tech_categories_batch(rows)

    assert result == ["frontend", "backend", None]
    # ONE call, carrying ONE row — not one call per job, not the whole batch.
    assert llm.call_count == 1
    assert [r["title"] for r in llm.call_args[0][0]] == ["Software Engineer"]


def test_many_unresolved_rows_are_still_one_call():
    rows = _rows(*[(f"Software Engineer {i}", "engineering") for i in range(30)])
    verdicts = TechCategoryBatch(verdicts=[{"index": i, "tech_category": "other_it"} for i in range(30)])
    llm = MagicMock(return_value=verdicts)
    with patch("services.llm.run_tech_category_batch", new=llm):
        classify_tech_categories_batch(rows)

    assert llm.call_count == 1


def test_verdicts_are_matched_by_echoed_index_not_list_order():
    rows = _rows(("Software Engineer A", "engineering"), ("Software Engineer B", "engineering"))
    # Returned out of order on purpose.
    verdicts = TechCategoryBatch(
        verdicts=[{"index": 1, "tech_category": "mobile"}, {"index": 0, "tech_category": "backend"}]
    )
    with patch("services.llm.run_tech_category_batch", new=MagicMock(return_value=verdicts)):
        assert classify_tech_categories_batch(rows) == ["backend", "mobile"]


# --- Every failure path degrades, none raises --------------------------------


def test_llm_disabled_falls_back_to_other_it():
    rows = _rows(("Software Engineer", "engineering"))
    with patch("services.llm.run_tech_category_batch") as llm:
        assert classify_tech_categories_batch(rows, use_llm=False) == ["other_it"]
    assert not llm.called


def test_llm_failure_falls_back_to_other_it():
    rows = _rows(("Software Engineer", "engineering"))
    with patch("services.llm.run_tech_category_batch", side_effect=RuntimeError("provider down")):
        # A missing specialism label must never be able to fail an ingestion run.
        assert classify_tech_categories_batch(rows) == ["other_it"]


def test_a_row_the_model_skipped_still_gets_a_label():
    rows = _rows(("Software Engineer A", "engineering"), ("Software Engineer B", "engineering"))
    verdicts = TechCategoryBatch(verdicts=[{"index": 0, "tech_category": "backend"}])
    with patch("services.llm.run_tech_category_batch", new=MagicMock(return_value=verdicts)):
        # Index 1 was dropped by the model — 'other_it' rather than None, since
        # we already know it IS a technical posting.
        assert classify_tech_categories_batch(rows) == ["backend", "other_it"]


def test_an_invented_category_fails_validation():
    """Golden rule 3: the closed enum is enforced in the schema, so a made-up
    value triggers the standard retry-once instead of reaching the CHECK
    constraint as a 500."""
    with pytest.raises(ValueError, match="Unknown tech_category"):
        TechCategoryBatch(verdicts=[{"index": 0, "tech_category": "web_stuff"}])


def test_the_enum_matches_the_migration():
    # Mirrored by the CHECK constraint in migration 028 and the app's filter
    # chips — this is the reminder that changing one means changing all three.
    assert set(TECH_CATEGORIES) == {
        "frontend", "backend", "full_stack", "mobile", "ai_ml", "data_science",
        "devops_cloud", "cybersecurity", "qa_testing", "blockchain", "other_it",
    }
    assert "non_it" not in TECH_CATEGORIES
