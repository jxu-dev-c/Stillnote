"""Meeting context persists alongside existing notes and stays safe to open/export."""

import json

import pytest
from fastapi.testclient import TestClient
from meeting_app import main
from meeting_app.storage import Store


@pytest.fixture
def client(tmp_path):
    app = main.create_app(tmp_path / "data", tmp_path / "models")
    with TestClient(app, base_url="http://127.0.0.1") as session:
        yield session


def test_context_links_survive_reload_edit_and_removal(client):
    store = client.app.state.store
    meeting = store.create("Planning", "meeting.wav", "auto", None, 5)
    url = f"/api/meetings/{meeting['id']}"
    assert meeting["context_links"] == []
    links = [{"url": "https://github.com/team/project", "title": " Project brief "}]
    response = client.patch(url, json={"notes": "Existing background", "context_links": links})
    assert response.status_code == 200
    saved_links = [{"url": links[0]["url"], "title": "Project brief"}]
    assert response.json()["context_links"] == saved_links
    restarted = Store(store.directory)
    assert restarted.get(meeting["id"])["context_links"] == saved_links
    assert client.get("/api/meetings").json()[0]["context_links"] == saved_links
    updated = client.patch(url, json={"context_links": [{"url": "https://example.com", "title": ""}]}).json()
    assert updated["context_links"] == [{"url": "https://example.com/", "title": ""}]
    assert updated["notes"] == "Existing background"
    cleared = client.patch(url, json={"context_links": []}).json()
    assert cleared["context_links"] == []
    assert cleared["notes"] == "Existing background"


def test_older_meetings_keep_notes_and_gain_empty_context_links(client):
    store = client.app.state.store
    meeting = store.create("Old meeting", "meeting.wav", "auto", None, 5)
    meeting.pop("context_links")
    meeting["notes"] = "Do not lose these notes."
    with store.db() as db:
        db.execute("UPDATE meetings SET data=? WHERE id=?", (json.dumps(meeting), meeting["id"]))
    for result in [client.get(f"/api/meetings/{meeting['id']}").json(), client.get("/api/meetings").json()[0]]:
        assert result["notes"] == meeting["notes"]
        assert result["context_links"] == []
    assert Store(store.directory).get(meeting["id"])["notes"] == meeting["notes"]


@pytest.mark.parametrize("url", [
    "javascript:alert(1)", "data:text/html,hello", "file:///etc/passwd", "ftp://example.com/file",
    "not a website", "https://user:secret@example.com", "https://", "https://example.com/" + "x" * 4096,
])
def test_invalid_context_links_are_rejected_without_changing_meeting(client, url):
    meeting = client.app.state.store.create("Planning", "meeting.wav", "auto", None, 5)
    base = f"/api/meetings/{meeting['id']}"
    response = client.patch(base, json={"notes": "Should not save", "context_links": [{"url": url}]})
    assert response.status_code == 422
    assert url not in response.text
    assert client.get(base).json()["notes"] == ""
    assert client.get(base).json()["context_links"] == []


def test_duplicate_links_and_excessive_link_counts_are_rejected(client):
    meeting = client.app.state.store.create("Planning", "meeting.wav", "auto", None, 5)
    base = f"/api/meetings/{meeting['id']}"
    assert client.patch(base, json={"context_links": [
        {"url": "https://EXAMPLE.com"}, {"url": "https://example.com/"},
    ]}).status_code == 422
    assert client.patch(base, json={"context_links": [
        {"url": f"https://example.com/{index}"} for index in range(101)
    ]}).status_code == 422
    client.app.state.store.update(meeting["id"], status="transcribing")
    assert client.patch(base, json={"context_links": [{"url": "https://example.com"}]}).status_code == 409


def test_context_exports_include_links_and_escape_markdown_labels(client):
    meeting = client.app.state.store.create("Planning", "meeting.wav", "auto", None, 5)
    base = f"/api/meetings/{meeting['id']}"
    links = [{"url": "https://example.com/a(b)", "title": "Brief [draft]"}]
    client.patch(base, json={"notes": "Background", "context_links": links})
    markdown = client.get(base + "/export?format=md").text
    assert "# Context\n\nBackground" in markdown
    assert r"- [Brief \[draft\]](<https://example.com/a(b)>)" in markdown
    text = client.get(base + "/export?format=txt").text
    assert "Context\n\nBackground" in text
    assert "- Brief [draft]: https://example.com/a(b)" in text
    assert client.get(base + "/export?format=json").json()["context_links"] == links
    assert "https://example.com" not in client.get(base + "/export?format=srt").text
    client.patch(base, json={"notes": ""})
    assert "# Context" in client.get(base + "/export?format=md").text


def test_csp_allows_direct_website_favicons(client):
    response = client.get("/api/meetings")
    assert "img-src 'self' data: https: http:;" in response.headers["content-security-policy"]
    assert response.headers["referrer-policy"] == "no-referrer"
