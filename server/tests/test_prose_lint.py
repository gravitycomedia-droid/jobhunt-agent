from services.prose_lint import lint_bullets


def _codes(findings, i=None):
    return {f["code"] for f in findings if i is None or f["bullet_index"] == i}


def test_clean_bullet_has_no_findings():
    # Strong opener, a metric, a technology, past tense, short — nothing to flag.
    findings = lint_bullets(["Cut deploy time 40% by migrating services to Docker"])
    assert findings == []


def test_weak_opener_flagged():
    findings = lint_bullets(["Responsible for maintaining the 40% Docker pipeline"])
    assert "weak_opener" in _codes(findings, 0)


def test_too_long_flagged():
    long_bullet = "Led the migration of the monolith to microservices " * 5 + "cutting 40% at Acme"
    findings = lint_bullets([long_bullet])
    assert "too_long" in _codes(findings, 0)


def test_passive_voice_flagged():
    findings = lint_bullets(["The 40% Docker pipeline was migrated across teams"])
    assert "passive_voice" in _codes(findings, 0)


def test_pronoun_flagged():
    findings = lint_bullets(["Led my team to cut 40% off Docker deploys"])
    assert "pronoun" in _codes(findings, 0)


def test_filler_flagged():
    findings = lint_bullets(["Successfully cut 40% off Docker deploys"])
    assert "filler" in _codes(findings, 0)


def test_zero_atom_density_flagged():
    # No number, no known tech, no proper noun — advice to add something real.
    findings = lint_bullets(["Improved the overall developer experience greatly"])
    assert "zero_atom" in _codes(findings, 0)


def test_verb_repetition_flags_third_occurrence_only():
    bullets = [
        "Built the 40% Docker pipeline",
        "Built the API gateway for 12 teams",
        "Built a mentoring program for 3 engineers",
    ]
    findings = lint_bullets(bullets)
    # First two "Built" bullets are fine; only the third trips repetition.
    assert "verb_repetition" not in _codes(findings, 0)
    assert "verb_repetition" not in _codes(findings, 1)
    assert "verb_repetition" in _codes(findings, 2)


def test_two_occurrences_do_not_trigger_repetition():
    bullets = ["Built the 40% Docker pipeline", "Built the API gateway for 12 teams"]
    assert "verb_repetition" not in _codes(lint_bullets(bullets))


def test_tense_mix_flags_minority():
    bullets = [
        "Led the 40% Docker migration",  # past
        "Built the API gateway for 12 teams",  # past
        "Manage the on-call rotation for 5 engineers",  # present (minority)
    ]
    findings = lint_bullets(bullets)
    assert "tense_mixed" in _codes(findings, 2)
    assert "tense_mixed" not in _codes(findings, 0)


def test_uniform_tense_has_no_tense_finding():
    bullets = ["Led the migration", "Built the gateway", "Mentored the team"]
    assert "tense_mixed" not in _codes(lint_bullets(bullets))


def test_advice_only_shape():
    # Every finding is advisory: an index, a code, a message, a severity —
    # never a boolean gate.
    findings = lint_bullets(["Responsible for stuff"])
    for f in findings:
        assert set(f) == {"bullet_index", "code", "message", "severity"}
        assert f["severity"] in {"warn", "info"}
