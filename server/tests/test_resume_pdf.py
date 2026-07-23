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


def _extract(pdf: bytes) -> str:
    import io

    from pypdf import PdfReader

    return "".join(page.extract_text() for page in PdfReader(io.BytesIO(pdf)).pages)


def test_analysis_row_uses_jd_title_summary_and_two_column():
    # ADR-019: a full row with a startup culture signal renders the JD title,
    # the reframed summary, and a two-column layout that still extracts as text.
    row = {
        "job_id": "job-123",
        "bullets": BULLETS,
        "analysis": {
            "role_type": "full_stack",
            "culture_signal": "startup",
            "jd_title": "Full-Stack Engineer Intern",
            "summary_line": "Full-stack engineer who ships end to end.",
            "hard_requirements": ["Python", "Flutter"],
            "skills_ordered": ["Flutter", "Python"],
        },
    }
    pdf = compile_ats_pdf(PROFILE, row)
    text = _extract(pdf)
    assert "Full-Stack Engineer Intern" in text  # exact JD title on the resume
    assert "Full-stack engineer who ships end to end." in text  # reframed summary
    assert "built X with Flutter" in text  # accepted bullet still present
    assert "INVENTED CLAIM" not in text  # rejected tailored text never leaks


def test_r2_grouped_rendering_omits_trimmed_and_honours_restore():
    # ADR-034 (R2): bullets carry experience_index + selected/accepted. A trimmed
    # bullet (selected=False, accepted=False) must NOT render; flipping accepted
    # (a one-tap restore) brings it back.
    bullets = [
        {"original": "built x", "tailored": "Built X with Flutter", "guardrail_pass": True,
         "experience_index": 0, "relevance": 0.9, "selected": True, "accepted": True},
        {"original": "shipped y", "tailored": "shipped y", "guardrail_pass": True,
         "experience_index": 0, "relevance": 0.1, "selected": False, "accepted": False,
         "trim_reason": "Below relevance floor for this job"},
        {"original": "helped z", "tailored": "Helped Z at scale", "guardrail_pass": True,
         "experience_index": 1, "relevance": 0.5, "selected": True, "accepted": True},
    ]
    row = {"job_id": "j", "bullets": bullets, "analysis": {}}

    text = _extract(compile_ats_pdf(PROFILE, row))
    assert "Built X with Flutter" in text
    assert "Helped Z at scale" in text
    assert "shipped y" not in text  # trimmed → omitted, not printed as original

    # One-tap restore: user accepts the trimmed bullet.
    bullets[1]["accepted"] = True
    text2 = _extract(compile_ats_pdf(PROFILE, row))
    assert "shipped y" in text2


def test_r2_selected_but_kept_original_still_renders():
    # 'Keep original' on a SELECTED bullet (accepted=False) means use its
    # original text — NOT drop the bullet. Only trimmed bullets drop.
    bullets = [
        {"original": "built x", "tailored": "Built X with Flutter", "guardrail_pass": True,
         "experience_index": 0, "relevance": 0.9, "selected": True, "accepted": False},
    ]
    text = _extract(compile_ats_pdf(PROFILE, {"job_id": "j", "bullets": bullets, "analysis": {}}))
    assert "built x" in text  # original kept, still on the résumé
    assert "Built X with Flutter" not in text


def test_r2_role_with_all_bullets_trimmed_drops_off():
    # A role whose every bullet is trimmed must not render as a bare header.
    bullets = [
        {"original": "built x", "tailored": "Built X", "guardrail_pass": True,
         "experience_index": 0, "relevance": 0.9, "selected": True, "accepted": True},
        {"original": "helped z", "tailored": "helped z", "guardrail_pass": True,
         "experience_index": 1, "relevance": 0.0, "selected": False, "accepted": False,
         "trim_reason": "Below relevance floor for this job"},
    ]
    text = _extract(compile_ats_pdf(PROFILE, {"job_id": "j", "bullets": bullets, "analysis": {}}))
    assert "Built X" in text
    assert "Beta" not in text  # the second role (only trimmed bullets) drops off


def test_single_page_fit_for_long_profile():
    # Framework §1 / one-page auto-fit: a profile with many bullets must still
    # compile to a single page.
    import io

    from pypdf import PdfReader

    big = {
        **PROFILE,
        "experience": [
            {
                "role": "Engineer",
                "company": f"Co {n}",
                "duration": "2020-2024",
                "bullets": [f"delivered project {n}-{m} on time" for m in range(6)],
            }
            for n in range(6)
        ],
    }
    bullets = [
        {"original": b, "tailored": b, "guardrail_pass": True, "accepted": True}
        for exp in big["experience"]
        for b in exp["bullets"]
    ]
    pdf = compile_ats_pdf(big, {"job_id": "x", "bullets": bullets, "analysis": {}})
    assert len(PdfReader(io.BytesIO(pdf)).pages) == 1
