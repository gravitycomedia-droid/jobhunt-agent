"""The ingestion relevance gate.

This is the only thing standing between the pool and a company's entire
Greenhouse board, so both directions matter: it must not admit senior roles, and
it must not reject real internships on a technicality. The false-negative tests
at the bottom are the ones that actually bite in practice.
"""

import pytest

from services.job_filter import in_target_city, is_entry_level, is_relevant, matches_target_role

# Real titles observed in the live pool on 2026-07-13.
KEEP = [
    ("Full Stack Developer Intern | Paid Internship | 6 Months", "Hyderabad"),
    ("Fullstack Developer- Internship", "Bangalore"),
    ("Mern Full Stack Developer Internship", "Hyderabad"),
    ("Intern - Frontend", "Bangalore"),
    ("Frontend Developer Intern", "Hyderabad"),
    ("Web Developer – Fresher", "Bengaluru"),
    ("Full Stack Engineer (Fresher)", "Bangalore"),
    ("Junior React Developer", "Hyderabad"),
]

DROP = [
    # Right role and city, but senior — the noise we're removing.
    ("Senior Full-Stack Software Engineer", "Bangalore"),
    ("Lead Full Stack Engineer", "Hyderabad"),
    ("Staff Engineer – Observability Platform", "Bangalore"),
    ("Engineering Manager, Postman AI", "Bangalore"),
    ("Principal Site Reliability Engineer I", "Bangalore"),
    # Entry-level and in-city, but not a role we hunt.
    ("Marketing Intern", "Hyderabad"),
    ("HR Trainee", "Bangalore"),
    # Right role and entry-level, wrong city.
    ("Frontend Developer Intern", "Pune"),
    ("Full Stack Intern", "Remote"),
]


@pytest.mark.parametrize("title,location", KEEP)
def test_keeps_fresher_and_intern_roles(title, location):
    assert is_relevant(title, location) is True


@pytest.mark.parametrize("title,location", DROP)
def test_drops_senior_wrong_role_or_wrong_city(title, location):
    assert is_relevant(title, location) is False


def test_senior_veto_beats_an_entry_keyword_in_the_title():
    # "Senior ... Graduate Program Lead" — a senior title must lose, even though
    # it contains "graduate".
    assert is_entry_level("Senior Frontend Engineer (Graduate Program)") is False


def test_senior_words_in_the_DESCRIPTION_do_not_veto():
    # The false negative that would quietly gut the pool: nearly every internship
    # JD says something like "you'll work alongside senior engineers". If the
    # senior veto scanned the description, we'd reject real internships.
    title = "Frontend Developer Intern"
    desc = "You will work closely with our senior engineers and the lead architect."
    assert is_entry_level(title, desc) is True
    assert is_relevant(title, "Hyderabad", desc) is True


def test_role_can_come_from_the_description():
    # A plainly-titled "SDE Intern" whose JD is all React/Node is exactly the job
    # the user wants; a title-only role match would throw it away.
    assert matches_target_role("SDE Intern", "Build React and Node.js features across our full stack.")
    assert is_relevant("SDE Intern", "Bangalore", "You'll own our React frontend.") is True


def test_entry_level_can_come_from_years_of_experience():
    # Many fresher postings never say "fresher" — they say "0-2 years".
    assert is_entry_level("Frontend Developer", "We're looking for 0-2 years of experience.") is True
    assert is_entry_level("Frontend Developer", "Requires 5+ years of experience.") is False


def test_bengaluru_and_bangalore_are_both_the_target_city():
    assert in_target_city("Bengaluru") is True
    assert in_target_city("Bangalore") is True
    assert in_target_city("Hyderabad, Telangana") is True
    assert in_target_city("Pune") is False
    assert in_target_city(None) is False


def test_city_can_come_from_the_description():
    assert in_target_city(None, "This role is based out of our Hyderabad office.") is True


def test_missing_fields_never_raise():
    assert is_relevant(None, None, None) is False
    assert is_relevant("", "", "") is False
