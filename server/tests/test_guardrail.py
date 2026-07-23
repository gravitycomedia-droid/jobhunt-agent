from models.tailor import TailoredBullet
from services.guardrail import (
    build_source_context,
    collect_untraceable_atoms,
    compute_gaps,
    verify_bullet_atoms,
    verify_bullets,
    verify_skills,
)

# A realistic stored profile: structured fields PLUS raw text, because R1
# traces atoms against both (an employer lives in a column, a metric in prose).
PROFILE = {
    "id": "p1",
    "name": "Jane Doe",
    "headline": "Backend Engineer",
    "skills": ["Python", "FastAPI", "PostgreSQL", "Docker"],
    "raw_resume_text": """
Jane Doe — Backend Engineer

Backend Engineer at Acme Corp (2021-2024)
- Led migration of monolith to microservices, cutting deploy time by 40%
- Built internal API gateway used by 12 downstream teams
- Mentored 3 junior engineers on Python best practices
""",
    "experience": [
        {
            "role": "Backend Engineer",
            "company": "Acme Corp",
            "duration": "2021-2024",
            "bullets": [
                "Led migration of monolith to microservices, cutting deploy time by 40%",
                "Built internal API gateway used by 12 downstream teams",
                "Mentored 3 junior engineers on Python best practices",
            ],
        }
    ],
}


def _ctx():
    return build_source_context(PROFILE)


# ---------- ADR-033: R1 atom-level guardrail ----------


def test_faithful_rephrase_passes():
    # Same facts (40%, microservices), reworded prose — every atom traces.
    v = verify_bullet_atoms(
        "Drove a monolith-to-microservices migration that cut deploy time by 40%", _ctx()
    )
    assert v.guardrail_pass is True
    assert v.flagged_atoms == []


def test_inflated_metric_is_flagged():
    # 40% -> 60% is the exact fabrication the old whole-bullet check missed:
    # `original` still traced, but the tailored number is invented.
    v = verify_bullet_atoms("Cut deploy time by 60% via a microservices migration", _ctx())
    assert v.guardrail_pass is False
    assert {"text": "60%", "kind": "number"} in v.flagged_atoms


def test_percent_and_word_percent_normalize_equal():
    # "40 percent" must trace to the source "40%" — same magnitude, same atom.
    v = verify_bullet_atoms("Reduced deploy time by 40 percent", _ctx())
    assert v.guardrail_pass is True


def test_invented_employer_is_flagged():
    # The canonical fabrication: a real-looking bullet relocated to "Google".
    v = verify_bullet_atoms("Architected a distributed platform at Google", _ctx())
    assert v.guardrail_pass is False
    assert any(a["text"] == "Google" and a["kind"] == "proper_noun" for a in v.flagged_atoms)


def test_real_employer_traces():
    v = verify_bullet_atoms("Delivered the API gateway at Acme Corp", _ctx())
    assert v.guardrail_pass is True


def test_invented_lowercase_tech_is_flagged():
    # Kubernetes is a real technology (in the lexicon) but not the candidate's.
    v = verify_bullet_atoms("Built a kubernetes operator for the platform", _ctx())
    assert v.guardrail_pass is False
    assert any(a["text"].lower() == "kubernetes" and a["kind"] == "tech" for a in v.flagged_atoms)


def test_owned_tech_traces():
    v = verify_bullet_atoms("Shipped FastAPI services backed by PostgreSQL", _ctx())
    assert v.guardrail_pass is True


def test_sentence_initial_capital_is_not_a_proper_noun():
    # "Reduced" opens the bullet; it must not be read as an employer/product.
    v = verify_bullet_atoms("Reduced deploy time by 40% for the team", _ctx())
    assert v.guardrail_pass is True


def test_number_present_elsewhere_in_resume_traces():
    # "12" appears in the API-gateway bullet; reusing it anywhere is fine.
    v = verify_bullet_atoms("Supported 12 downstream teams", _ctx())
    assert v.guardrail_pass is True


def test_verify_bullets_shape_and_flag_count():
    bullets = [
        TailoredBullet(
            original="Led migration of monolith to microservices, cutting deploy time by 40%",
            tailored="Led a microservices migration, cutting deploy time by 40%",
            job_keyword_targeted="microservices",
        ),
        TailoredBullet(
            original="Built internal API gateway used by 12 downstream teams",
            tailored="Built an API gateway used by 500 downstream teams at Netflix",
            job_keyword_targeted="api",
        ),
    ]
    results = verify_bullets(bullets, PROFILE)
    assert results[0]["guardrail_pass"] is True
    assert results[0]["flagged_atoms"] == []
    assert results[1]["guardrail_pass"] is False
    # Both the inflated scope (500) and the invented employer (Netflix) flagged.
    kinds = {a["kind"] for a in results[1]["flagged_atoms"]}
    assert {"number", "proper_noun"} <= kinds
    assert results[1]["keyword"] == "api"


def test_collect_untraceable_atoms_flattens_with_index():
    bullets = [
        TailoredBullet(original="x", tailored="Cut cost by 40%", job_keyword_targeted="k"),
        TailoredBullet(original="y", tailored="Grew revenue 300% at Stripe", job_keyword_targeted="k"),
    ]
    verified = verify_bullets(bullets, PROFILE)
    atoms = collect_untraceable_atoms(verified)
    # Bullet 0 traces (40% is real); bullet 1 contributes the 300% + Stripe.
    assert all(a["bullet_index"] == 1 for a in atoms)
    assert {a["text"] for a in atoms} >= {"300%", "Stripe"}


# ---------- R-E golden set (proxy) ----------
# A tiny hand-labelled fixture of (tailored, should_pass) cases. The real R-E
# golden set is a corpus of resumes/JDs applied before merge; this in-repo
# proxy locks the atom rules against regression here. Each case is a fact the
# guardrail MUST get right, with the reason it matters.
GOLDEN_CASES = [
    ("Led a microservices migration cutting deploy time by 40%", True, "faithful rephrase"),
    ("Cut deploy time by 65%", False, "inflated metric"),
    ("Built an API gateway used by 12 teams", True, "kept real scope"),
    ("Built an API gateway used by 900 teams", False, "inflated scope"),
    ("Mentored 3 junior engineers on Python", True, "all atoms real"),
    ("Delivered results at Amazon", False, "invented employer"),
    ("Shipped Docker-based deployments", True, "owned tech"),
    ("Introduced kafka streaming", False, "unowned tech"),
]


def test_golden_set():
    ctx = _ctx()
    for tailored, should_pass, reason in GOLDEN_CASES:
        v = verify_bullet_atoms(tailored, ctx)
        assert v.guardrail_pass is should_pass, f"{reason!r}: {tailored!r} -> {v.flagged_atoms}"


# ---------- ADR-019: skill subsetting + gap check (unchanged by R1) ----------

REAL_SKILLS = ["Python", "FastAPI", "PostgreSQL", "Docker"]
RAW_RESUME = PROFILE["raw_resume_text"]


def test_verify_skills_keeps_llm_order_and_appends_dropped():
    ordered = verify_skills(["FastAPI", "Python"], REAL_SKILLS)
    assert ordered[:2] == ["FastAPI", "Python"]
    assert set(ordered) == set(REAL_SKILLS)


def test_verify_skills_drops_invented_skills():
    ordered = verify_skills(["Kubernetes", "Python"], REAL_SKILLS)
    assert "Kubernetes" not in ordered
    assert set(ordered) == set(REAL_SKILLS)


def test_verify_skills_tolerates_light_recasing():
    ordered = verify_skills(["fastapi", "python"], REAL_SKILLS)
    assert ordered[0] == "FastAPI"
    assert ordered[1] == "Python"


def test_compute_gaps_flags_only_missing_requirements():
    gaps = compute_gaps(["Python", "React", "Kubernetes"], REAL_SKILLS, RAW_RESUME)
    assert "Python" not in gaps
    assert "React" in gaps and "Kubernetes" in gaps


def test_compute_gaps_counts_skill_named_only_in_resume_text():
    gaps = compute_gaps(["microservices"], REAL_SKILLS, RAW_RESUME)
    assert gaps == []
