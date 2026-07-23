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

PROFILE = {"id": "p1", "headline": "Backend intern", "skills": ["Python", "FastAPI"], "target_roles": ["Backend"]}
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


def test_context_is_honest_when_empty():
    block = build_context_block({"headline": None, "skills": [], "target_roles": []}, [], [])
    assert "(no ranked matches yet)" in block
    assert "(no applications tracked yet)" in block


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
