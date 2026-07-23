"""Phase 4: _process_profile's write hooks — a score_snapshots row per run
(R-D) and a persisted notification mirroring the FCM push. Supabase is mocked;
both hooks are best-effort and must never raise into the pipeline."""

from unittest.mock import patch

from jobs import daily_pipeline


class _FakeQ:
    def __init__(self, name, store):
        self.name, self.store = name, store

    def select(self, *a, **k):
        return self

    def eq(self, *a, **k):
        return self

    def insert(self, payload):
        if self.store.get("raise_on_insert"):
            raise RuntimeError("supabase down")
        self.store["inserts"].setdefault(self.name, []).append(payload)
        return self

    def execute(self):
        class _R:
            pass

        r = _R()
        r.data = self.store["selects"].get(self.name, [])
        return r


class _FakeSB:
    def __init__(self, store):
        self.store = store

    def table(self, name):
        return _FakeQ(name, self.store)


def _store(selects=None, raise_on_insert=False):
    return {"selects": selects or {}, "inserts": {}, "raise_on_insert": raise_on_insert}


# --- score snapshot -------------------------------------------------------


def test_snapshot_written_from_current_fit_scores():
    store = _store(selects={"matches": [{"fit_score": 80}, {"fit_score": 60}, {"fit_score": None}]})
    with patch.object(daily_pipeline, "supabase", _FakeSB(store)):
        daily_pipeline._write_score_snapshot("p1")
    row = store["inserts"]["score_snapshots"][0]
    assert row == {"profile_id": "p1", "top_fit_score": 80, "avg_fit_score": 70.0, "match_count": 2}


def test_no_snapshot_when_no_scored_matches():
    store = _store(selects={"matches": []})
    with patch.object(daily_pipeline, "supabase", _FakeSB(store)):
        daily_pipeline._write_score_snapshot("p1")
    assert "score_snapshots" not in store["inserts"]


def test_snapshot_failure_is_swallowed():
    store = _store(selects={"matches": [{"fit_score": 90}]}, raise_on_insert=True)
    with patch.object(daily_pipeline, "supabase", _FakeSB(store)):
        daily_pipeline._write_score_snapshot("p1")  # must not raise


# --- notification record ---------------------------------------------------


def test_notification_persisted_with_agent_run_kind():
    store = _store()
    with patch.object(daily_pipeline, "supabase", _FakeSB(store)):
        daily_pipeline._record_notification("p1", "Agent ran", "3 newly scored")
    row = store["inserts"]["notifications"][0]
    assert row == {"profile_id": "p1", "kind": "agent_run", "title": "Agent ran", "body": "3 newly scored"}


def test_notification_failure_is_swallowed():
    store = _store(raise_on_insert=True)
    with patch.object(daily_pipeline, "supabase", _FakeSB(store)):
        daily_pipeline._record_notification("p1", "t", "b")  # must not raise
