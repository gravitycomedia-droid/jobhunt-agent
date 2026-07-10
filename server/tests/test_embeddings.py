from services.embeddings import job_embedding_text, profile_embedding_text


def test_profile_embedding_text_leads_with_headline_and_skills():
    profile = {
        "headline": "Flutter engineer",
        "skills": ["flutter", "dart", "python"],
        "experience": [{"role": "Engineer", "company": "Acme", "bullets": ["Shipped 2 apps"]}],
        "projects": [{"name": "Job-Hunt Agent", "description": "AI job search assistant"}],
    }
    text = profile_embedding_text(profile)
    lines = text.split("\n")
    assert lines[0] == "Flutter engineer"
    assert lines[1] == "flutter, dart, python"
    assert "Engineer at Acme: Shipped 2 apps" in text
    assert "Job-Hunt Agent: AI job search assistant" in text


def test_profile_embedding_text_skips_empty_fields():
    # A resume can genuinely have no headline/experience — the template
    # shouldn't leave blank lines or crash on missing keys.
    text = profile_embedding_text({"skills": ["python"]})
    assert text == "python"


def test_job_embedding_text_joins_title_company_description():
    job = {"title": "Backend Engineer", "company": "Acme", "description": "Build APIs"}
    assert job_embedding_text(job) == "Backend Engineer\nAcme\nBuild APIs"


def test_job_embedding_text_skips_missing_fields():
    job = {"title": "Backend Engineer", "company": None, "description": None}
    assert job_embedding_text(job) == "Backend Engineer"
