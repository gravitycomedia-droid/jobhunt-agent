from services.resume_pdf import compile_ats_pdf, compile_final_bullets, _replace_experience_bullets

PROFILE = {
    "name": "Ada Lovelace",
    "headline": "Software Engineer",
    "skills": ["Python", "Flutter"],
    "experience": [
        {"role": "Engineer", "company": "Acme", "duration": "2020-2024", "bullets": ["built x", "shipped y"]},
        {"role": "Intern", "company": "Beta", "duration": "2019", "bullets": ["helped z"]},
    ],
    "projects": [{"name": "JobHunt", "tech": ["FastAPI"], "description": "an agent"}],
    "education": [{"degree": "BSc", "institution": "MIT", "year": "2019"}],
}

BULLETS = [
    {"original": "built x", "tailored": "built X with Flutter", "guardrail_pass": True, "accepted": True},
    {"original": "shipped y", "tailored": "INVENTED CLAIM", "guardrail_pass": False, "accepted": False},
    {"original": "helped z", "tailored": "helped Z at scale", "guardrail_pass": True, "accepted": True},
]


def test_final_bullets_respect_human_choice():
    assert compile_final_bullets(BULLETS) == ["built X with Flutter", "shipped y", "helped Z at scale"]


def test_missing_accepted_falls_back_to_guardrail():
    bullets = [{"original": "o", "tailored": "t", "guardrail_pass": True}]
    assert compile_final_bullets(bullets) == ["t"]
    bullets[0]["guardrail_pass"] = False
    assert compile_final_bullets(bullets) == ["o"]


def test_bullets_reslot_into_experiences_in_order():
    replaced = _replace_experience_bullets(PROFILE["experience"], ["a", "b", "c"])
    assert replaced[0]["bullets"] == ["a", "b"]
    assert replaced[1]["bullets"] == ["c"]
    # original profile untouched (pure function)
    assert PROFILE["experience"][0]["bullets"] == ["built x", "shipped y"]


def test_pdf_bytes_are_valid_pdf_with_text_layer():
    pdf = compile_ats_pdf(PROFILE, BULLETS)
    assert pdf.startswith(b"%PDF")
    # Machine-readable text layer: pypdf (already a server dep) must be able
    # to read the accepted bullet text back out.
    import io

    from pypdf import PdfReader

    text = "".join(page.extract_text() for page in PdfReader(io.BytesIO(pdf)).pages)
    assert "Ada Lovelace" in text
    assert "built X with Flutter" in text  # accepted tailored text
    assert "shipped y" in text  # rejected → original kept
    assert "INVENTED CLAIM" not in text  # rejected tailored text never leaks
    for heading in ("SUMMARY", "SKILLS", "EXPERIENCE", "PROJECTS", "EDUCATION"):
        assert heading in text
