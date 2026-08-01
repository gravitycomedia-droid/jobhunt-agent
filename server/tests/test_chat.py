"""Phase 4: the grounded chat assistant. Pins that the prompt actually carries
the user's real matches/applications, that it hard-instructs against fabrication,
that the reply is schema-validated, and that the task runner persists the reply."""

from unittest.mock import MagicMock, patch

import pytest
from pydantic import ValidationError

from models.chat import ChatReply
from routers.chat import ChatSend
from services import chat as chat_service
from services.chat import answer_chat, build_context_block

PROFILE = {
    "id": "p1",
    "name": "Harish Kumar",
    "headline": "Backend intern",
    "skills": ["Python", "FastAPI"],
    "target_roles": ["Backend"],
    "experience": [
        {"role": "SWE Intern", "company": "Electronics Co", "duration": "May–Aug 2020", "bullets": ["Built a CI report pipeline"]}
    ],
    "projects": [
        {"name": "Gym Reservation Bot", "tech": ["Python", "GCP"], "description": "Books a slot every morning"}
    ],
    "education": [{"degree": "BS Computer Science", "institution": "State University", "year": "2021"}],
    "employment_type": "student",
    "branch": "CSE",
    "grad_year": 2026,
    "target_locations": ["Hyderabad", "Bengaluru"],
}
MATCHES = [{"job": {"title": "API Intern", "company": "Acme"}, "fit_score": 88}]
APPS = [{"job": {"title": "Data Intern", "company": "Globex"}, "state": "applied"}]


# --- grounding: the model can only speak from real user data ----------------


def test_context_includes_profile_matches_and_applications():
    block = build_context_block(PROFILE, MATCHES, APPS)
    assert "Backend intern" in block          # headline
    assert "API Intern at Acme" in block       # a real match
    assert "88% fit" in block
    assert "Data Intern at Globex" in block     # a real application
    assert "status: applied" in block


def test_context_carries_the_whole_resume():
    """The failure this guards: "what's my name?" / "which project is my best?"
    used to be unanswerable because the context only held headline+skills, so an
    honest model correctly said it had no such information."""
    block = build_context_block(PROFILE, MATCHES, APPS)
    assert "Harish Kumar" in block                       # name — "what is my name?"
    assert "Gym Reservation Bot" in block                # projects — "my best project?"
    assert "Books a slot every morning" in block         # ...with enough detail to judge it
    assert "SWE Intern at Electronics Co" in block       # experience
    assert "Built a CI report pipeline" in block         # ...down to the bullets
    assert "BS Computer Science" in block                # education


def test_context_carries_onboarding_facts_and_skips_blank_ones():
    block = build_context_block(PROFILE, [], [])
    assert "Branch/major: CSE" in block
    assert "Graduation year: 2026" in block
    assert "Preferred locations: Hyderabad, Bengaluru" in block
    # Fields the user never filled are absent entirely, not printed as empty
    # claims the model could read as "no employer".
    assert "Current employer" not in block


def test_context_is_honest_when_empty():
    block = build_context_block({"headline": None, "skills": [], "target_roles": []}, [], [])
    assert "(name not on file)" in block
    assert "(no work experience on file)" in block
    assert "(no projects on file)" in block
    assert "(no education on file)" in block
    assert "(no ranked matches yet)" in block
    assert "(no applications tracked yet)" in block


def test_prompt_allows_advice_while_still_banning_invented_facts():
    """Both halves matter: the old prompt was so absolute the model refused to
    suggest anything ("what projects can I build?"), while the fabrication ban
    must survive that loosening."""
    assert "NEVER invent" in chat_service.CHAT_SYSTEM_PROMPT
    assert "ADVICE is different from facts" in chat_service.CHAT_SYSTEM_PROMPT


# --- anti-fabrication + schema validation via the LLM loop ------------------


def test_answer_chat_grounds_and_forbids_fabrication():
    captured = {}

    def fake_run(**kwargs):
        captured.update(kwargs)
        return ChatReply(reply="Your top match is API Intern at Acme.")

    with patch.object(chat_service, "_run_llm_task", fake_run):
        out = answer_chat(PROFILE, MATCHES, APPS, [], "what's my best match?")

    assert isinstance(out, ChatReply)
    assert captured["task"] == "chat"
    assert captured["response_model"] is ChatReply          # Golden Rule 3
    assert captured["profile_id"] == "p1"                    # logged per-profile
    # The refuse-to-invent instruction and the real match are both in the prompt.
    assert "NEVER invent" in captured["system"]
    assert "API Intern at Acme" in captured["system"]
    # The user's question rides in the user turn, not the system prompt.
    assert "best match" in captured["user"]


def test_prior_history_is_replayed_into_the_prompt():
    captured = {}
    history = [{"role": "user", "content": "hi"}, {"role": "assistant", "content": "hello!"}]
    with patch.object(chat_service, "_run_llm_task", lambda **kw: captured.update(kw) or ChatReply(reply="ok")):
        answer_chat(PROFILE, [], [], history, "and now?")
    assert "User: hi" in captured["user"] and "Assistant: hello!" in captured["user"]


# --- request model guards --------------------------------------------------


def test_chat_send_rejects_empty_and_overlong():
    with pytest.raises(ValidationError):
        ChatSend(message="")
    with pytest.raises(ValidationError):
        ChatSend(message="x" * 4001)


def test_chat_send_rejects_extra_fields():
    with pytest.raises(ValidationError):
        ChatSend(message="hi", sneaky="x")


def test_chat_send_accepts_optional_thread_id():
    assert ChatSend(message="hi").thread_id is None
    assert ChatSend(message="hi", thread_id="t1").thread_id == "t1"


# --- the background task persists the assistant turn ------------------------


def test_run_chat_turn_persists_reply_and_bumps_thread():
    inserted = {}

    fake_sb = MagicMock()
    fake_sb.table.return_value.insert.return_value.execute.return_value.data = [
        {"id": "m2", "role": "assistant", "content": "grounded answer"}
    ]

    with patch.object(chat_service, "supabase", fake_sb), \
         patch.object(chat_service, "_gather_grounding", return_value=(MATCHES, APPS)), \
         patch.object(chat_service, "answer_chat", return_value=ChatReply(reply="grounded answer")) as ans:
        # history fetch also goes through fake_sb; give it a benign return
        fake_sb.table.return_value.select.return_value.eq.return_value.order.return_value.execute.return_value.data = []
        out = chat_service.run_chat_turn(PROFILE, "t1", "question")

    assert out["thread_id"] == "t1"
    assert out["message"]["content"] == "grounded answer"
    ans.assert_called_once()
