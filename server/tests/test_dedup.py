from models.job import JobIn
from services.dedup import is_duplicate, make_dedup_key


def _job(title: str, company: str | None = "Acme", location: str | None = "Bengaluru") -> JobIn:
    return JobIn(source="test", external_id="x", title=title, company=company, location=location)


def test_make_dedup_key_normalizes_case_and_punctuation():
    key_a = make_dedup_key("Python Developer!", "Acme Corp.", "Bengaluru, India")
    key_b = make_dedup_key("python developer", "acme corp", "bengaluru india")
    assert key_a == key_b


def test_make_dedup_key_handles_missing_fields():
    # A job with no company/location shouldn't crash — slugify(None) isn't
    # valid, so make_dedup_key must guard against it.
    key = make_dedup_key("Python Developer", None, None)
    assert key == "python-developer||"


def test_is_duplicate_true_for_exact_match():
    existing = [{"title": "Python Developer", "company": "Acme", "location": "Bengaluru"}]
    candidate = _job("Python Developer")
    assert is_duplicate(candidate, existing) is True


def test_is_duplicate_true_for_whitespace_and_casing_near_duplicate():
    existing = [{"title": "python  developer ", "company": "ACME", "location": "bengaluru"}]
    candidate = _job("Python Developer")
    assert is_duplicate(candidate, existing) is True


def test_is_duplicate_false_for_same_company_different_role():
    existing = [{"title": "Backend Engineer", "company": "Acme", "location": "Bengaluru"}]
    candidate = _job("Python Developer")
    assert is_duplicate(candidate, existing) is False


def test_is_duplicate_false_for_same_title_different_company():
    existing = [{"title": "Python Developer", "company": "Globex", "location": "Bengaluru"}]
    candidate = _job("Python Developer", company="Acme")
    assert is_duplicate(candidate, existing) is False


def test_is_duplicate_false_against_empty_existing_list():
    assert is_duplicate(_job("Python Developer"), []) is False


def test_is_duplicate_respects_custom_threshold():
    # Same title, different (but similarly-spelled) company — high ratio but
    # not identical. A stricter threshold should reject it, a looser one accept it.
    existing = [{"title": "Python Developer", "company": "Acme Inc", "location": "Bengaluru"}]
    candidate = _job("Python Developer", company="Acme Incorporated")
    assert is_duplicate(candidate, existing, threshold=99) is False
    assert is_duplicate(candidate, existing, threshold=70) is True
