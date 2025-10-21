from scripts.generate_beads_backlog import generate_markdown, filter_closed, sort_by_id_asc


def test_filter_excludes_closed():
    issues = [
        {"id": "1", "status": "open"},
        {"id": "2", "status": "closed"},
        {"id": "3", "status": "in_progress"},
    ]
    out = filter_closed(issues)
    ids = [i["id"] for i in out]
    assert "2" not in ids
    assert "1" in ids
    assert "3" in ids


def test_sort_by_id_asc():
    issues = [{"id": "10"}, {"id": "2"}, {"id": "3"}, {"id": "a"}]
    sorted_ = sort_by_id_asc(issues)
    assert [i["id"] for i in sorted_] == ["2", "3", "10", "a"]


def test_generate_includes_bodies_section():
    issues = [
        {"id": "5", "title": "T1", "status": "open", "body": "line1\nline2"},
    ]
    md = generate_markdown(issues)
    assert "## Full bodies" in md
    assert "beads-body-5" in md
    assert "```md" in md
from scripts import generate_beads_backlog as gen


def test_generate_markdown_empty():
    md = gen.generate_markdown([])
    assert "Beads backlog" in md
    assert "No backlog items found." in md


def test_format_issue_md_minimal():
    issue = {"id": "123", "title": "Test issue", "status": "closed", "labels": ["service/gateway"]}
    s = gen.format_issue_md(issue)
    assert "Test issue" in s
    assert "Labels: service/gateway" in s
