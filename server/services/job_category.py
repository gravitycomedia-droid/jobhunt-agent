"""Coarse category for a posting (ADR-003 v3, golden rule 2: code, not the LLM).

Why this exists: the ingestion relevance gate used to guarantee that everything in
the pool was a fullstack/frontend/cloud role, so "what kind of job is this?" never
needed answering — the answer was always "yours". The broad Unstop pool breaks
that assumption: 2,022 open postings across sales, marketing, finance, design,
operations and engineering all now land in the same table. Something has to label
them or the app's job list becomes an undifferentiated wall.

Deliberately NOT an LLM call. This runs on every ingested row (hundreds a day),
the vocabulary is stable, and golden rule 2 puts classification-by-keyword firmly
in Python's column. A regex that's right 90% of the time and costs nothing beats a
model call that's right 97% of the time and has to be logged, validated, retried
and paid for on every row.

Ordering matters: the first pattern that matches wins, so the list runs most- to
least-specific. "Data Analyst Intern" must land in `data` before the generic
`business` pattern claims "analyst", and "Sales Engineer" must reach `sales`
before `engineering` claims "engineer".
"""

import re

# The closed vocabulary. Mirrored by the CHECK constraint in migration 027 and by
# the app's filter chips — adding a value means touching all three.
CATEGORIES = (
    "engineering",
    "data",
    "design",
    "product",
    "marketing",
    "sales",
    "finance",
    "operations",
    "hr",
    "content",
    "legal",
    "other",
)

# (category, pattern) in priority order. Patterns are matched against the title
# first and only then the top of the description — same title-then-body shape as
# job_filter.py, and for the same reason: a JD mentioning "we work closely with
# the sales team" must not make an engineering role a sales role.
_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    # --- data / ML first: "data analyst" and "ML engineer" contain tokens that
    # the broader `engineering` and `business` patterns would otherwise claim.
    (
        "data",
        re.compile(
            r"""
            data\s+(scien|analy|engineer) | data[\s-]?analyst
          | machine\s+learning | artificial\s+intelligence
          # Bare "AI"/"ML" need ROLE context. Unqualified, they matched company
          # boilerplate — "4K Labs ... using cutting-edge AI agentic platforms"
          # filed a Video Creation Internship under `data` (live, 2026-07-27).
          # Two-letter tokens are far too common in marketing prose to trust on
          # their own. The optional middle group is for "AI/ML Engineering".
          | (?:\bai\b|\bml\b)[\s/&-]{0,3}(?:(?:ai|ml)[\s/&-]{0,3})?
            (?:engineer|intern|develop|scientist|analyst|research|model)
          | deep\s+learning | \bnlp\b | computer\s+vision | \bllm\b
          | business\s+intelligence | \bbi\b\s+(analyst|developer) | power\s?bi
          | tableau | data\s+visuali[sz]ation | big\s+data | \betl\b
          | \bpandas\b | \bnumpy\b | dataset | statistical\s+model
            """,
            re.I | re.X,
        ),
    ),
    # --- design before product: "product designer" is design, not product.
    (
        "design",
        re.compile(
            r"""
            \bui\s*/?\s*ux\b | \bux\b | \bui\s+design | user\s+experience
          | graphic\s+design | visual\s+design | product\s+design
          | motion\s+design | \bfigma\b | illustrat(or|ion) | \bbranding\b
          | video\s+(edit|creation|production|content) | animation | \b3d\s+(artist|design)
          | interior\s+design | design\s+intern(ship)?\b
            """,
            re.I | re.X,
        ),
    ),
    # --- engineering: the widest tech net, well beyond the three target roles.
    (
        "engineering",
        re.compile(
            r"""
            full[\s.-]?stack | front[\s.-]?end | back[\s.-]?end | \bmern\b | \bmean\b
          | software\s+(engineer|develop) | \bsde\b | \bswe\b | web\s+develop
          | react | angular | vue | next\.?js | node\.?js | django | flask | spring
          | javascript | typescript | \bpython\b | \bjava\b | golang | \brust\b
          | \bc\+\+ | \bkotlin\b | \bswift\b | \bphp\b | laravel | \.net | \bruby\b
          | android | \bios\s+develop | flutter | react\s*native | mobile\s+app
          | cloud\s+(architect|engineer) | \baws\b | \bazure\b | \bgcp\b | devops
          | \bsre\b | kubernetes | docker | site\s+reliability
          | cyber\s*security | security\s+(engineer|analyst) | penetration\s+test
          | blockchain | \bweb3\b | embedded | \biot\b | firmware | \bvlsi\b
          | \bqa\b | quality\s+assurance | test(ing)?\s+engineer | automation\s+engineer
          # Bare "Software Testing" — an Internshala category name in its own
          # right (ADR-003 v4 crawls that slug), and matched by NEITHER
          # `software (engineer|develop)` nor `test(ing) engineer` above. It was
          # falling through to the description and landing in `sales` when a JD
          # mentioned the sales team (observed live 2026-07-27).
          | software\s+test(ing)?
          | database\s+(admin|develop) | \bsql\s+develop | system\s+admin
          | technical\s+support\s+engineer | solutions?\s+architect
            """,
            re.I | re.X,
        ),
    ),
    (
        "product",
        re.compile(r"product\s+manage | product\s+owner | \bapm\b | product\s+analyst | program\s+manage", re.I | re.X),
    ),
    (
        "marketing",
        re.compile(
            r"""
            marketing | \bseo\b | \bsem\b | social\s+media | brand\s+(manage|strateg)
          | growth\s+(hack|manage|market) | campus\s+ambassador | influencer
          | digital\s+market | performance\s+market | \bpr\b\s+(intern|execut)
          | public\s+relations | community\s+manage | advertis
            """,
            re.I | re.X,
        ),
    ),
    (
        "sales",
        re.compile(
            r"""
            \bsales\b | business\s+develop | \bbd\b\s+(intern|execut|manage)
          | account\s+(manage|execut) | inside\s+sales | field\s+sales
          # "Channel development/partner" is partner sales, not engineering —
          # spelled out because bare "development" is far too broad to add here.
          | channel\s+(develop|partner|manage)
          | telecall | lead\s+generation | client\s+acquisition | \bcrm\b
          | customer\s+success | relationship\s+manage
            """,
            re.I | re.X,
        ),
    ),
    (
        "finance",
        re.compile(
            r"""
            financ | account(ing|ant)\b | audit | taxation | \bgst\b | book\s*keep
          # "Accounts Payable/Receivable" — plural, and neither "accounting" nor
          # "accountant", so the pattern above misses it entirely.
          | accounts?\s+(payable|receivable|associate|assistant|executive)
          | investment\s+bank | equity\s+research | \bca\b\s+(intern|article)
          | wealth\s+manage | credit\s+analy | \bfp&a\b | treasury | actuar
            """,
            re.I | re.X,
        ),
    ),
    (
        "hr",
        re.compile(
            r"""
            human\s+resource | \bhr\b | recruit | talent\s+acquisition
          | people\s+operations | campus\s+hiring | \bl&d\b | training\s+coordinat
            """,
            re.I | re.X,
        ),
    ),
    (
        "content",
        re.compile(
            r"""
            content\s+(writ|creat|strateg|market) | copywrit | \bwriter\b
          | technical\s+writ | editor(ial)? | journalis | blog(ging|ger)
          | script\s+writ | translat
            """,
            re.I | re.X,
        ),
    ),
    (
        "legal",
        re.compile(r"\blegal\b | \bllb\b | advocate | paralegal | compliance\s+(intern|officer) | contract\s+draft", re.I | re.X),
    ),
    (
        "operations",
        re.compile(
            r"""
            operations? | supply\s+chain | logistics | procurement | warehouse
          | \bbusiness\s+analy | process\s+(improve|excellence) | project\s+coordinat
          | customer\s+(support|service) | \bbpo\b | administrat
            """,
            re.I | re.X,
        ),
    ),
    # --- LAST, and last on purpose: a bare "Engineer"/"Developer" title.
    # Measured 2026-07-26, this alone rescues ~40 postings that were landing in
    # 'other' — "Platform Engineer", "EDI Developer", "FPGA SW Developer",
    # "ASIC Verification Engineer" — real engineering roles whose specialism
    # simply isn't in the vocabulary above and never will be exhaustively.
    #
    # It MUST stay below `sales`, `operations` and the rest: "Sales Engineer"
    # and "Business Development Manager" are claimed by their own categories
    # first, and only what nothing else wanted falls through to here.
    (
        "engineering",
        re.compile(r"\bengineer(ing)?\b | \bdeveloper\b | \bprogrammer\b | \btechnical\b | \btech\s+intern", re.I | re.X),
    ),
]


def _head(description: str | None, chars: int = 600) -> str:
    """Only the top of a JD — same rationale as job_filter._head: the footer is
    boilerplate ("follow us on social media", "our sales team is growing") and
    reliably misclassifies otherwise-obvious postings."""
    return (description or "")[:chars]


class UnknownCategoryError(ValueError):
    """Raised by parse_category_filter for a filter naming no valid category.
    routers/jobs.py turns this into a 422 — see there for why it isn't a silent
    empty result."""


def parse_category_filter(raw: str | None) -> list[str] | None:
    """Normalize a `?category=` query value into a validated allow-list.

    Returns None for "no filter" (absent or blank), so the caller can tell that
    apart from a filter that matched nothing. Extracted from the route handler
    to stay pure and unit-testable — the codebase has no HTTP-client tests, and
    this is the part with actual logic in it.

    Unknown names raise rather than being silently dropped: a filter that
    survives with zero valid entries would return an empty list, which reads to
    the user as "the pool is empty" instead of "your filter is wrong".
    """
    if not raw or not raw.strip():
        return None
    wanted = [c.strip().lower() for c in raw.split(",") if c.strip()]
    # Separators but no names (",", ", ,") — nothing was actually asked for, so
    # this is "no filter", not "an unknown filter". Raising here would produce
    # the nonsense message "Unknown category filter []".
    if not wanted:
        return None
    valid = [c for c in wanted if c in CATEGORIES]
    if not valid:
        raise UnknownCategoryError(f"Unknown category filter {wanted!r}. Valid values: {', '.join(CATEGORIES)}")
    # Deduplicated, and ordered as CATEGORIES declares — so the same selection
    # always produces the same query regardless of how the client ordered it.
    return [c for c in CATEGORIES if c in set(valid)]


def classify_category(title: str | None, description: str | None = None) -> str:
    """Best-effort coarse category. Never raises, never returns None — an
    unmatched posting is 'other', which the app renders as a real, filterable
    bucket rather than hiding.

    Title wins over description outright: EVERY pattern is tried against the
    title before any is tried against the body. Otherwise a high-priority
    pattern matching some incidental phrase deep in a JD would beat the plain
    statement of what the job is in its own title.
    """
    title = title or ""
    for category, pattern in _PATTERNS:
        if pattern.search(title):
            return category
    body = _head(description)
    for category, pattern in _PATTERNS:
        if pattern.search(body):
            return category
    return "other"
