"""Free-text salary parsing (golden rule 2: code handles logic, not the LLM).

Adzuna and Naukri hand us numeric salary fields. Indeed and LinkedIn hand us a
human string — "₹6,00,000 - ₹12,00,000 a year", "₹50,000 a month", "6-15 Lacs
PA" — and something has to turn that into numbers. That something is this
module: pure, no I/O, exhaustively unit-tested, because a silent misparse here
becomes a wrong number on a job card.

Two normalizations worth knowing about:

- **Everything is annualized.** Adzuna's salary_min/max are per-year, and the
  `jobs` table has no period column, so a monthly "₹50,000 a month" MUST become
  600000 or it would render as a catastrophically low yearly salary next to its
  Adzuna neighbours. Per-day/hour rates are deliberately NOT annualized (see
  below) — they're dropped instead.
- **Indian numbering is parsed natively.** "6,00,000" is lakh-grouped, not a
  malformed "600,000"; "Lacs"/"Lakh" means x100,000 and "Cr"/"Crore" means
  x10,000,000. Getting this wrong is a 100x error, not a rounding error.
"""

import re

# Order matters: the symbol table is scanned longest-token-first so "Rs." wins
# over a bare "R", and "INR" over "IN".
_CURRENCY_TOKENS: list[tuple[str, str]] = [
    ("₹", "INR"),
    ("inr", "INR"),
    ("rs.", "INR"),
    ("rs", "INR"),
    ("$", "USD"),
    ("usd", "USD"),
    ("£", "GBP"),
    ("gbp", "GBP"),
    ("€", "EUR"),
    ("eur", "EUR"),
]

# Multipliers on the *number* ("6 Lacs" -> 600000). Longest-first again, so
# "lakhs" doesn't get eaten by "lakh" leaving a stray "s".
_MAGNITUDES: list[tuple[str, int]] = [
    ("crore", 10_000_000),
    ("crores", 10_000_000),
    ("cr", 10_000_000),
    ("lakhs", 100_000),
    ("lakh", 100_000),
    ("lacs", 100_000),
    ("lac", 100_000),
    # "12 LPA" = Lakhs Per Annum — extremely common in Indian postings, and the
    # magnitude is fused to the period ("l" + "pa"), so a word-boundary match on
    # a bare "l" misses it entirely and silently returns 12 rupees.
    ("lpa", 100_000),
    ("l", 100_000),
    ("k", 1_000),
]

# Only per-year and per-month are convertible to an annual figure with a
# straight multiply. An hourly or daily rate depends on hours-per-week and
# working-days assumptions we don't have, and inventing one (2080 hours, 250
# days) would be the LLM-does-arithmetic mistake in Python clothing — so those
# postings get a null salary and the UI says "not stated", which is honest.
_PERIOD_MULTIPLIERS: list[tuple[str, int]] = [
    ("per annum", 1),
    ("a year", 1),
    ("per year", 1),
    ("yearly", 1),
    ("annually", 1),
    ("p.a.", 1),
    ("pa", 1),
    ("a month", 12),
    ("per month", 12),
    ("monthly", 12),
    ("p.m.", 12),
]
_UNSUPPORTED_PERIODS = ("an hour", "per hour", "hourly", "a day", "per day", "a week", "per week")

_NUMBER = re.compile(r"\d[\d,.]*")


def _to_float(raw: str) -> float | None:
    """'6,00,000' -> 600000.0 ; '12.5' -> 12.5 ; '1,234.56' -> 1234.56.

    Indian lakh-grouping ("6,00,000") and Western grouping ("600,000") both just
    mean "drop the commas". A period is only a decimal point if what follows is
    1-2 digits and it's the last separator — otherwise it's a thousands dot.
    """
    raw = raw.strip().rstrip(".,")
    if not raw:
        return None
    cleaned = raw.replace(",", "")
    # "1.234.567" (dot-grouped) -> strip all but a genuine trailing decimal.
    if cleaned.count(".") > 1:
        head, _, tail = cleaned.rpartition(".")
        cleaned = head.replace(".", "") + ("." + tail if len(tail) <= 2 else tail)
    try:
        return float(cleaned)
    except ValueError:
        return None


def parse_salary_text(text: str | None) -> tuple[float | None, float | None, str | None]:
    """Returns (salary_min, salary_max, currency) — any of which may be None.

    Never raises and never guesses: an unparseable string yields (None, None,
    None) so the caller stores nulls rather than a number nobody can defend.
    A single figure ("₹8,00,000 a year") sets min == max, matching how the
    existing sources behave when a posting states one number.
    """
    if not text or not text.strip():
        return (None, None, None)

    low = text.lower()

    # An hourly/daily/weekly rate can't be annualized honestly — bail rather
    # than fabricate a working-hours assumption.
    if any(p in low for p in _UNSUPPORTED_PERIODS):
        return (None, None, None)

    currency = next((code for token, code in _CURRENCY_TOKENS if token in low), None)

    period_mult = next((mult for token, mult in _PERIOD_MULTIPLIERS if token in low), 1)

    numbers = _NUMBER.findall(low)
    if not numbers:
        return (None, None, currency)

    values: list[float] = []
    for raw in numbers[:2]:  # "a - b"; ignore trailing noise like a review count
        value = _to_float(raw)
        if value is None:
            continue
        # The magnitude suffix can sit on the number ("15L") or trail the whole
        # range ("6-15 Lacs"), so look just after this number and, failing that,
        # at the tail of the string.
        after = low.split(raw, 1)[1] if raw in low else ""
        mult = _magnitude_in(after[:12]) or _magnitude_in(low[low.rfind(raw) + len(raw) :])
        values.append(value * (mult or 1))

    if not values:
        return (None, None, currency)

    values = [v * period_mult for v in values]
    low_v, high_v = min(values), max(values)
    return (low_v, high_v, currency)


def _magnitude_in(fragment: str) -> int | None:
    """First magnitude word in `fragment`, or None. Word-boundary matched so the
    'l' in 'salary' or the 'k' in 'work' can't multiply anything by 100,000."""
    for token, mult in _MAGNITUDES:
        if re.search(rf"(?<![a-z]){re.escape(token)}(?![a-z])", fragment):
            return mult
    return None


# India-ish location text → INR. Used when a source gives us a salary number but
# no currency (the "Indian salaries render with a $" bug): guessing USD by
# omission is exactly what caused it, so we infer from where the job is instead.
_INDIA_HINTS = (
    "india",
    "bengaluru",
    "bangalore",
    "hyderabad",
    "pune",
    "chennai",
    "mumbai",
    "delhi",
    "noida",
    "gurgaon",
    "gurugram",
    "kolkata",
    "ahmedabad",
    "telangana",
    "karnataka",
    "maharashtra",
    "tamil nadu",
)


def infer_currency(location: str | None, default: str | None = None) -> str | None:
    """Best-effort currency from location text. Returns `default` when the text
    gives us nothing — and `default` should be None unless the *source itself*
    implies a country (Naukri is India-only; LinkedIn/Indeed are not)."""
    if not location:
        return default
    low = location.lower()
    return "INR" if any(hint in low for hint in _INDIA_HINTS) else default
