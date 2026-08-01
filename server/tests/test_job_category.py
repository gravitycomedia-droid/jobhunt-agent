"""Coarse category classifier (ADR-003 v3, services/job_category.py).

This only matters because the broad Unstop pool dropped the role gate: the `jobs`
table now holds sales, marketing and finance postings next to engineering ones,
and `category` is the only thing keeping the app's list navigable.

The cases below are real titles pulled from Unstop's live catalogue on
2026-07-26, not invented ones — particularly the priority-collision cases, which
are where a keyword classifier actually goes wrong.
"""

import pytest

from routers.jobs import build_facets
from services.job_category import (
    CATEGORIES,
    UnknownCategoryError,
    classify_category,
    parse_category_filter,
)


@pytest.mark.parametrize(
    "title,expected",
    [
        # --- engineering, well beyond the three original target roles
        ("Full Stack Development Internship", "engineering"),
        ("NextJs Frontend Internship", "engineering"),
        ("Android Developer", "engineering"),
        ("Software Test Automation Engineer", "engineering"),
        ("DevOps Engineer", "engineering"),
        ("Cyber Security Analyst", "engineering"),
        # --- the low-priority catch-all: real roles whose specialism isn't (and
        # can't exhaustively be) in the vocabulary. These landed in 'other'
        # before it existed.
        ("Platform Engineer", "engineering"),
        ("EDI Developer", "engineering"),
        ("FPGA SW Developer", "engineering"),
        ("ASIC Verification Engineer", "engineering"),
        # --- data before engineering: "Data Engineer" is data, not engineering
        ("Data Science Internship", "data"),
        ("Data Engineer", "data"),
        ("Machine Learning Intern", "data"),
        ("Power BI Developer", "data"),
        # --- design before product: "Product Designer" is design
        ("Product Design Internship", "design"),
        ("UI/UX Designer", "design"),
        ("Interior Designer", "design"),
        ("Product Manager", "product"),
        # --- the non-technical bulk of the broad pool
        ("Social Media Marketing Internship", "marketing"),
        ("Campus Ambassador Internship", "marketing"),
        ("Real Estate Sales Executive", "sales"),
        ("Business Development Executive", "sales"),
        ("Accounts Payable Associate", "finance"),
        ("Talent Acquisition Intern", "hr"),
        ("Content Writing Internship", "content"),
        ("Legal Intern", "legal"),
        ("Supply Chain Analyst", "operations"),
    ],
)
def test_classifies_real_catalogue_titles(title, expected):
    assert classify_category(title) == expected


@pytest.mark.parametrize(
    "title,expected",
    [
        # The whole reason _PATTERNS is ordered rather than a dict. Each of these
        # contains a token that a HIGHER-priority category would happily claim.
        ("Sales Engineer", "sales"),  # not engineering — sales is matched first
        ("Channel Development Manager", "sales"),  # "development" must not read as engineering
        ("Marketing Analyst", "marketing"),  # not data
        ("Business Analyst", "operations"),  # not data
        ("Technical Content Writer", "content"),  # not engineering
        ("Design Internship", "design"),  # bare "design" still lands
    ],
)
def test_priority_collisions_resolve_to_the_more_specific_category(title, expected):
    assert classify_category(title) == expected


def test_title_beats_description_outright():
    """Every pattern is tried against the title before ANY is tried against the
    body — otherwise an incidental phrase deep in a JD outranks the job's own
    plain statement of what it is."""
    assert classify_category("Sales Executive", "You will work with our React and Python engineering team daily.") == "sales"


def test_description_is_the_fallback_when_the_title_says_nothing():
    assert classify_category("Intern", "Build React components and REST APIs in Django.") == "engineering"


@pytest.mark.parametrize(
    "title,description,expected",
    [
        # The live 2026-07-27 miss: bare "AI" in a company blurb pulled a video
        # role into `data`. Two-letter tokens now need role context.
        (
            "Video Creation Internship",
            "4K Labs is focused on creating engaging educational video content "
            "for K12 students using cutting-edge AI agentic platforms.",
            "design",
        ),
        ("Marketing Intern", "We are an AI-first company disrupting retail.", "marketing"),
        # …but genuine AI/ML roles must still land in `data`.
        ("AI/ML Engineering Internship", None, "data"),
        ("ML Engineer", None, "data"),
        ("AI Research Intern", None, "data"),
    ],
)
def test_bare_ai_ml_tokens_need_role_context(title, description, expected):
    assert classify_category(title, description) == expected


def test_jd_footer_boilerplate_does_not_classify():
    """Only the head of the description is scanned. A footer routinely name-drops
    other departments ("our sales team is growing"), and letting that decide the
    category would misfile a large share of the pool."""
    body = "Analyse datasets with pandas. " + ("filler. " * 200) + "Our sales team is hiring too!"
    assert classify_category("Intern", body) == "data"


def test_unmatched_posting_is_other_never_none():
    # 'other' is a real, filterable bucket. None would be un-renderable and would
    # violate migration 027's CHECK on insert.
    assert classify_category("Front Line Manager") == "other"
    assert classify_category(None) == "other"
    assert classify_category("") == "other"


def test_every_returned_category_is_in_the_declared_vocabulary():
    """CATEGORIES is mirrored by migration 027's CHECK constraint and the app's
    filter chips. A pattern returning a name outside it would fail the DB insert
    at ingestion time, in the cron, where nobody is watching."""
    titles = ["Software Engineer", "Data Analyst", "UX Designer", "Sales Exec", "Nonsense Title", ""]
    for t in titles:
        assert classify_category(t) in CATEGORIES


def test_facets_expose_every_category_even_at_zero():
    """The client renders a stable chip row; a category vanishing on a quiet day
    would make the filter UI reshuffle under the user."""
    facets = build_facets([{"category": "engineering"}, {"category": "sales"}])
    assert set(facets["category"]) == set(CATEGORIES)
    assert facets["category"]["engineering"] == 1
    assert facets["category"]["legal"] == 0


def test_facets_bucket_null_category_as_other():
    # Rows ingested before migration 027 that the SQL backfill couldn't place.
    # They must stay reachable through a real chip, not become invisible.
    facets = build_facets([{"category": None}, {}])
    assert facets["category"]["other"] == 2


# --- the ?category= query filter ---------------------------------------------


@pytest.mark.parametrize("raw", [None, "", "   ", ","])
def test_blank_filter_is_no_filter_not_an_empty_result(raw):
    """None means "don't narrow". Returning [] here would make GET /jobs
    filter on an empty allow-list and show nothing."""
    assert parse_category_filter(raw) is None


def test_parses_and_normalises_a_filter():
    assert parse_category_filter("engineering, DATA ,design") == ["engineering", "data", "design"]


def test_result_order_is_stable_regardless_of_client_order():
    # Same selection → same query string, so caches and logs line up.
    assert parse_category_filter("sales,engineering") == parse_category_filter("engineering,sales")


def test_duplicates_collapse():
    assert parse_category_filter("data,data,data") == ["data"]


def test_unknown_names_alongside_valid_ones_are_dropped():
    assert parse_category_filter("engineering,astrology") == ["engineering"]


def test_entirely_unknown_filter_raises_rather_than_matching_nothing():
    """The 422 path. Silently returning [] would render as "the pool is empty"
    and send the user pull-to-refreshing instead of fixing their filter."""
    with pytest.raises(UnknownCategoryError) as excinfo:
        parse_category_filter("astrology,alchemy")
    # The message must name the valid values — it's the only affordance the
    # caller gets for correcting the request.
    assert "engineering" in str(excinfo.value)


def test_bare_software_testing_is_engineering_not_sales():
    """Regression, found live 2026-07-27 on real Internshala data (ADR-003 v4).

    "Software Testing" is an Internshala category name in its own right, and it
    matched NEITHER `software (engineer|develop)` nor `test(ing) engineer`. With
    no title match it fell through to the description, where a JD mentioning the
    sales team filed a QA internship under `sales`.
    """
    assert classify_category("Software Testing", "Coordinate with our sales team on release quality.") == "engineering"
    assert classify_category("Software Testing Internship") == "engineering"
