"""Salary parsing is arithmetic on money, so it gets the same scrutiny as
guardrail.py/matching.py (CLAUDE.md: these MUST have tests). The failure this
suite exists to prevent: a lakh misparse, which is a 100x error on a job card.
"""

import pytest

from services.salary import infer_currency, parse_salary_text


@pytest.mark.parametrize(
    "text,expected",
    [
        # --- Indian lakh-grouped digits (the "6,00,000" trap: it's 600k, not 6M)
        ("₹6,00,000 - ₹12,00,000 a year", (600_000, 1_200_000, "INR")),
        ("₹8,00,000 a year", (800_000, 800_000, "INR")),
        # --- "Lacs PA" — the exact format the plan called out
        ("6-15 Lacs PA", (600_000, 1_500_000, None)),
        ("₹6-15 Lacs PA", (600_000, 1_500_000, "INR")),
        ("Rs. 5 - 10 Lakh per annum", (500_000, 1_000_000, "INR")),
        ("12 LPA", (1_200_000, 1_200_000, None)),
        # --- crore
        ("₹1 - 2 Crore per annum", (10_000_000, 20_000_000, "INR")),
        # --- monthly must be annualized or it reads as a starvation wage next
        #     to Adzuna's per-year numbers
        ("₹50,000 a month", (600_000, 600_000, "INR")),
        ("₹40,000 - ₹60,000 per month", (480_000, 720_000, "INR")),
        # --- slash-period forms (Internshala stipends, ADR-003 v2): "/month" must
        #     annualize the same as "a month" or a stipend reads 12x too low
        ("₹10,000 /month", (120_000, 120_000, "INR")),
        ("12 K/Month", (144_000, 144_000, None)),  # the plan's named acceptance case
        ("₹15,000 - ₹25,000 /month", (180_000, 300_000, "INR")),
        ("₹8,00,000 /year", (800_000, 800_000, "INR")),
        # --- western formats still work
        ("$120,000 - $150,000 a year", (120_000, 150_000, "USD")),
        ("$90k - $110k a year", (90_000, 110_000, "USD")),
        ("£55,000 per year", (55_000, 55_000, "GBP")),
        # --- reversed range: min/max, not first/second
        ("₹12,00,000 - ₹6,00,000 a year", (600_000, 1_200_000, "INR")),
    ],
)
def test_parses_real_world_formats(text, expected):
    assert parse_salary_text(text) == expected


@pytest.mark.parametrize(
    "text",
    [
        None,
        "",
        "   ",
        "Competitive salary",
        "Salary not disclosed",
        "Best in industry",
    ],
)
def test_unparseable_yields_all_none(text):
    # Nulls, not zeros, not a guess. The UI renders "not stated".
    assert parse_salary_text(text) == (None, None, None)


@pytest.mark.parametrize(
    "text",
    ["₹500 an hour", "$50 per hour", "₹2,000 a day", "£300 per day", "₹5,000 /week", "₹800 /day"],
)
def test_hourly_and_daily_are_dropped_not_annualized(text):
    # Annualizing an hourly rate needs an hours-per-week assumption we don't
    # have. Inventing 2080 hours would be fabricating a number — the exact
    # thing golden rule 2 forbids. Null is the honest answer.
    assert parse_salary_text(text) == (None, None, None)


def test_magnitude_suffix_does_not_match_inside_words():
    # The 'l' in "salary" or 'k' in "work" must never multiply by 100,000.
    # A bare number with no magnitude word stays as-is.
    assert parse_salary_text("salary of 500000 per annum")[0] == 500_000


def test_single_number_sets_min_equals_max():
    low, high, _ = parse_salary_text("₹8,00,000 a year")
    assert low == high == 800_000


@pytest.mark.parametrize(
    "location,expected",
    [
        ("Hyderabad, Telangana", "INR"),
        ("Hyderabad, Telangana, India", "INR"),
        ("Bengaluru", "INR"),
        ("Hybrid - Hyderabad, Chennai", "INR"),
        ("San Francisco, CA", None),
        ("London, UK", None),
        (None, None),
    ],
)
def test_infer_currency_from_location(location, expected):
    assert infer_currency(location) == expected


def test_infer_currency_default_applies_only_when_unknown():
    # Naukri is India-only, so INR is a safe source-level default there.
    assert infer_currency("Somewhere Unrecognized", default="INR") == "INR"
    # But a recognized non-Indian location must not be overridden by the default.
    assert infer_currency("Hyderabad", default="USD") == "INR"


def test_never_defaults_to_usd_on_missing_currency():
    # The original bug: an Indian salary with no explicit currency rendered "$".
    # Absent evidence, currency is None and the app shows no symbol.
    _, _, currency = parse_salary_text("600000 - 1200000 per annum")
    assert currency is None
