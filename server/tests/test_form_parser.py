import json

import pytest

from models.form import FormAnswer
from services.form_parser import (
    FormAuthRequiredError,
    FormParseError,
    build_prefill_url,
    is_google_form_url,
    parse_google_form,
    verify_choice_answers,
)

# Minimal-but-faithful FB_PUBLIC_LOAD_DATA_ layout: data[3]=title,
# data[1][0]=description, data[1][1]=items, item=[id, title, help, type,
# [[entry_id, options, required]]], option=[text].
_FB_DATA = [
    None,
    [
        "We are hiring a Flutter developer.",
        [
            [1001, "Full name", None, 0, [[2001, None, True]]],
            [1002, "Tell us about yourself", None, 1, [[2002, None, False]]],
            [1003, "Years of experience", None, 2, [[2003, [["0-2"], ["3-5"], ["6+"]], True]]],
            [1004, "Preferred stack", None, 4, [[2004, [["Flutter"], ["React Native"]], False]]],
            [1005, "Resume", None, 13, [[2005, None, True]]],
            [1006, "Some image item", None, 11, None],
        ],
    ],
    None,
    "Flutter Developer Application",
]

FIXTURE_HTML = f"""<html><head></head><body>
<script type="text/javascript">var FB_PUBLIC_LOAD_DATA_ = {json.dumps(_FB_DATA)};</script>
</body></html>"""

FORM_URL = "https://docs.google.com/forms/d/e/abc123/viewform"


def _parsed():
    return parse_google_form(FIXTURE_HTML, form_url=FORM_URL)


def test_parses_title_description_and_questions():
    schema = _parsed()
    assert schema.title == "Flutter Developer Application"
    assert schema.description.startswith("We are hiring")
    assert schema.source == "google_form"
    # image item (type 11) skipped; 5 fillable questions remain
    assert [q.entry_id for q in schema.questions] == ["2001", "2002", "2003", "2004", "2005"]


def test_types_options_and_required():
    schema = _parsed()
    by_id = {q.entry_id: q for q in schema.questions}
    assert by_id["2001"].type == "short" and by_id["2001"].required
    assert by_id["2002"].type == "paragraph" and not by_id["2002"].required
    assert by_id["2003"].type == "choice" and by_id["2003"].options == ["0-2", "3-5", "6+"]
    assert by_id["2004"].type == "checkbox" and by_id["2004"].options == ["Flutter", "React Native"]
    assert by_id["2005"].type == "file_upload"


def test_missing_data_raises_parse_error():
    with pytest.raises(FormParseError):
        parse_google_form("<html>no form here</html>", form_url=FORM_URL)


def test_signin_page_raises_auth_error():
    html = '<html><a href="https://accounts.google.com/v3/signin">Sign in</a>ServiceLogin</html>'
    with pytest.raises(FormAuthRequiredError):
        parse_google_form(html, form_url=FORM_URL)


def test_is_google_form_url():
    assert is_google_form_url(FORM_URL)
    assert is_google_form_url("https://forms.gle/xyz")
    assert not is_google_form_url("https://example.com/careers/apply")


def test_choice_guardrail_flags_non_members():
    schema = _parsed()
    answers = [
        FormAnswer(entry_id="2003", question="Years of experience", answer="3-5", confidence=0.9),
        FormAnswer(entry_id="2004", question="Preferred stack", answer=["Flutter", "Django"], confidence=0.8),
        FormAnswer(entry_id="2001", question="Full name", answer="Ada Lovelace", confidence=1.0),
        FormAnswer(entry_id="2002", question="Tell us about yourself", answer=None, confidence=0.0),
    ]
    verified = verify_choice_answers(schema, answers)
    by_id = {a.entry_id: a for a in verified}
    assert by_id["2003"].guardrail_pass  # exact option member
    assert not by_id["2004"].guardrail_pass  # "Django" isn't an option
    assert by_id["2001"].guardrail_pass  # free text: guardrail doesn't apply
    assert by_id["2002"].guardrail_pass  # null answer: nothing to verify


def test_prefill_url_includes_only_clean_answers():
    schema = _parsed()
    answers = verify_choice_answers(
        schema,
        [
            FormAnswer(entry_id="2001", question="Full name", answer="Ada Lovelace", confidence=1.0),
            FormAnswer(entry_id="2003", question="Years", answer="3-5", confidence=0.9),
            FormAnswer(entry_id="2004", question="Stack", answer=["Flutter", "Django"], confidence=0.5),
            FormAnswer(entry_id="2002", question="About", answer=None, confidence=0.0),
            FormAnswer(entry_id="2005", question="Resume", answer="resume.pdf", confidence=0.9),
        ],
    )
    url = build_prefill_url(schema, answers)
    assert url.startswith(FORM_URL + "?usp=pp_url")
    assert "entry.2001=Ada+Lovelace" in url
    assert "entry.2003=3-5" in url
    assert "entry.2004" not in url  # guardrail-failed checkbox excluded entirely
    assert "entry.2002" not in url  # null answer
    assert "entry.2005" not in url  # file upload can't be prefilled


def test_checkbox_repeats_params_when_clean():
    schema = _parsed()
    answers = [FormAnswer(entry_id="2004", question="Stack", answer=["Flutter", "React Native"], confidence=0.9)]
    url = build_prefill_url(schema, verify_choice_answers(schema, answers))
    assert url.count("entry.2004=") == 2
