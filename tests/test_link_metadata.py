import asyncio
import socket

import httpx
import pytest
from fastapi.testclient import TestClient
from httpx import AsyncClient
from meeting_app import link_metadata, main


@pytest.fixture
def public_dns(monkeypatch):
    monkeypatch.setattr(socket, "getaddrinfo", lambda *args, **kwargs: [
        (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("93.184.216.34", 443)),
    ])


def mock_pages(monkeypatch, handler):
    monkeypatch.setattr(link_metadata.httpx, "AsyncClient", lambda **kwargs: AsyncClient(
        transport=httpx.MockTransport(handler), **kwargs
    ))


def test_page_title_handles_entities_whitespace_and_limits_length(monkeypatch, public_dns):
    def page(request):
        assert request.url.host == "93.184.216.34"  # Connect only to the validated address.
        assert request.headers["host"] == "example.com"
        assert request.extensions["sni_hostname"] == "example.com"
        assert "cookie" not in request.headers and "referer" not in request.headers
        assert request.url.path == "/project" and request.url.query == b"page=2"
        return httpx.Response(200, headers={"Content-Type": "text/html; charset=utf-8"}, text=(
            '<meta property="og:title" content="Social title"><title>\n Project &amp; roadmap — 计划\n </title>'
        ))
    mock_pages(monkeypatch, page)
    assert asyncio.run(link_metadata.page_title("https://example.com/project?page=2#notes")) == (
        "Project & roadmap — 计划"
    )
    parser = link_metadata.PageTitleParser()
    parser.feed("<title>" + "x" * 500 + "</title>")
    assert len(parser.title) == 240


@pytest.mark.parametrize("html, expected", [
    ('<head><meta property="og:title" content="Project &amp; notes"></head>', "Project & notes"),
    ('<head><meta name="twitter:title" content="Social title"></head>', "Social title"),
    ('<head><script>const title = "<title>Wrong</title>"</script></head>', ""),
    ('<head></head><body>No title available</body>', ""),
])
def test_title_fallbacks(monkeypatch, public_dns, html, expected):
    mock_pages(monkeypatch, lambda request: httpx.Response(200, headers={"Content-Type": "text/html"}, text=html))
    assert asyncio.run(link_metadata.page_title("https://example.com")) == expected


def test_relative_redirect_uses_original_hostname_and_does_not_send_cookies(monkeypatch, public_dns):
    paths = []

    def page(request):
        paths.append(request.url.path)
        assert request.headers["host"] == "example.com"
        assert "cookie" not in request.headers
        if request.url.path == "/":
            return httpx.Response(302, headers={"Location": "/destination", "Set-Cookie": "session=private"})
        return httpx.Response(200, headers={"Content-Type": "text/html"}, text="<title>Destination</title>")
    mock_pages(monkeypatch, page)
    assert asyncio.run(link_metadata.page_title("https://example.com")) == "Destination"
    assert paths == ["/", "/destination"]


@pytest.mark.parametrize("address", ["127.0.0.1", "10.0.0.1", "169.254.169.254", "::1", "::ffff:127.0.0.1"])
def test_private_and_local_addresses_are_not_fetched(monkeypatch, address):
    monkeypatch.setattr(socket, "getaddrinfo", lambda *args, **kwargs: [
        (socket.AF_INET, socket.SOCK_STREAM, 6, "", (address, 443)),
    ])
    mock_pages(monkeypatch, lambda request: pytest.fail("Private addresses must not be contacted"))
    assert asyncio.run(link_metadata.page_title("https://example.com")) == ""


def test_redirect_to_private_address_is_not_followed(monkeypatch):
    def dns(host, *args, **kwargs):
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (
            "127.0.0.1" if host == "localhost" else "93.184.216.34", 443,
        ))]
    monkeypatch.setattr(socket, "getaddrinfo", dns)
    requests = []

    def page(request):
        requests.append(request)
        return httpx.Response(302, headers={"Location": "http://localhost:8765/api/settings"})
    mock_pages(monkeypatch, page)
    assert asyncio.run(link_metadata.page_title("https://example.com")) == ""
    assert len(requests) == 1


@pytest.mark.parametrize("status, content_type", [(403, "text/html"), (500, "text/html"), (200, "application/pdf")])
def test_errors_and_non_html_pages_fall_back_without_failing(monkeypatch, public_dns, status, content_type):
    mock_pages(monkeypatch, lambda request: httpx.Response(
        status, headers={"Content-Type": content_type}, text="<title>Must not be used</title>"
    ))
    assert asyncio.run(link_metadata.page_title("https://example.com")) == ""


def test_lookup_timeout_includes_dns(monkeypatch):
    async def slow_dns(url):
        await asyncio.sleep(1)
    monkeypatch.setattr(link_metadata, "public_address", slow_dns)
    monkeypatch.setattr(link_metadata, "LOOKUP_TIMEOUT", 0.01)
    assert asyncio.run(link_metadata.page_title("https://example.com")) == ""


def test_redirects_and_html_reads_are_bounded(monkeypatch, public_dns):
    requests = []

    def redirect(request):
        requests.append(request)
        return httpx.Response(302, headers={"Location": "/loop"})
    mock_pages(monkeypatch, redirect)
    assert asyncio.run(link_metadata.page_title("https://example.com")) == ""
    assert len(requests) == link_metadata.MAX_REDIRECTS + 1
    monkeypatch.setattr(link_metadata, "MAX_HTML_BYTES", 100)
    mock_pages(monkeypatch, lambda request: httpx.Response(
        200, headers={"Content-Type": "text/html"}, text=" " * 101 + "<title>Too late</title>"
    ))
    assert asyncio.run(link_metadata.page_title("https://example.com")) == ""


def test_title_endpoint_and_persistence(tmp_path, monkeypatch):
    async def title(url):
        assert url == "https://example.com/project"
        return "Project brief"
    monkeypatch.setattr(link_metadata, "page_title", title)
    app = main.create_app(tmp_path / "data", tmp_path / "models")
    with TestClient(app, base_url="http://127.0.0.1") as client:
        meeting = app.state.store.create("Planning", "audio.wav", "auto", None, 1)
        response = client.post("/api/context/link-title", json={"url": "https://example.com/project"})
        assert response.status_code == 200
        assert response.json() == {"title": "Project brief"}
        assert client.post("/api/context/link-title", json={"url": "javascript:alert(1)"}).status_code == 422
        assert client.post("/api/context/link-title", json={"url": "https://user:secret@example.com"}).status_code == 422
        base = f"/api/meetings/{meeting['id']}"
        link = {"url": "https://example.com/project", "title": response.json()["title"]}
        assert client.patch(base, json={"context_links": [link]}).status_code == 200
        assert client.get(base).json()["context_links"] == [link]
        assert "Project brief" in client.get(base + "/export?format=md").text
