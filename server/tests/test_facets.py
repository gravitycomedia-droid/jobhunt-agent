"""Phase 4: GET /jobs/facets histogram. Pins that NULL work_type buckets as
'unknown' (never dropped), all three real work types are always present as keys
even at zero, and sources are ordered busiest-first."""

from routers.jobs import build_facets


def test_empty_pool_has_zeroed_work_types_and_no_sources():
    f = build_facets([])
    assert f["total"] == 0
    assert f["work_type"] == {"remote": 0, "hybrid": 0, "onsite": 0, "unknown": 0}
    assert f["source"] == {}


def test_null_work_type_buckets_as_unknown():
    jobs = [{"work_type": None, "source": "linkedin"}, {"work_type": "remote", "source": "linkedin"}]
    f = build_facets(jobs)
    assert f["work_type"]["unknown"] == 1
    assert f["work_type"]["remote"] == 1


def test_counts_per_work_type_and_source():
    jobs = [
        {"work_type": "remote", "source": "linkedin"},
        {"work_type": "remote", "source": "naukri"},
        {"work_type": "onsite", "source": "linkedin"},
        {"work_type": "hybrid", "source": "linkedin"},
    ]
    f = build_facets(jobs)
    assert f["total"] == 4
    assert f["work_type"] == {"remote": 2, "hybrid": 1, "onsite": 1, "unknown": 0}
    assert f["source"]["linkedin"] == 3
    assert f["source"]["naukri"] == 1


def test_sources_ordered_busiest_first():
    jobs = (
        [{"work_type": "remote", "source": "naukri"} for _ in range(3)]
        + [{"work_type": "remote", "source": "linkedin"} for _ in range(5)]
        + [{"work_type": "remote", "source": "unstop"}]
    )
    f = build_facets(jobs)
    assert list(f["source"].keys()) == ["linkedin", "naukri", "unstop"]


def test_missing_source_buckets_as_unknown():
    f = build_facets([{"work_type": "remote", "source": None}])
    assert f["source"] == {"unknown": 1}
