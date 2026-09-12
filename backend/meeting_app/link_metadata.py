"""Best-effort page titles for context links, without cookies or local-network access."""

import asyncio
import codecs
import ipaddress
import socket
from html.parser import HTMLParser

import httpx

LOOKUP_TIMEOUT = 6
MAX_HTML_BYTES = 512 * 1024
MAX_REDIRECTS = 3


class PageTitleParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.in_title = False
        self.title_complete = False
        self.head_complete = False
        self.parts = []
        self.meta_title = ""

    def handle_starttag(self, tag, attrs):
        if tag == "title" and not self.title_complete:
            self.in_title = True
        elif tag == "meta":
            attributes = dict(attrs)
            name = (attributes.get("property") or attributes.get("name") or "").lower()
            if name in {"og:title", "twitter:title"} and not self.meta_title:
                self.meta_title = attributes.get("content") or ""
        elif tag == "body":
            self.head_complete = True

    def handle_endtag(self, tag):
        if tag == "title" and self.in_title:
            self.in_title = False
            self.title_complete = True
        elif tag == "head":
            self.head_complete = True

    def handle_data(self, data):
        if self.in_title:
            self.parts.append(data)

    @property
    def title(self):
        title = " ".join("".join(self.parts).split()) or " ".join(self.meta_title.split())
        return title[:240]


async def public_address(url):
    if url.scheme not in {"http", "https"} or not url.host or url.userinfo:
        raise ValueError("A public website URL is required.")
    addresses = await asyncio.get_running_loop().getaddrinfo(
        url.host, url.port or (443 if url.scheme == "https" else 80), type=socket.SOCK_STREAM
    )
    ips = {ipaddress.ip_address(address[4][0]) for address in addresses}
    if not ips or any(not address.is_global for address in ips):
        raise ValueError("Local and private network addresses are not fetched.")
    return str(sorted(ips, key=lambda address: (address.version, int(address)))[0])


async def page_title(value: str) -> str:
    """Return a short title or an empty string; failed lookups must not block saving."""
    try:
        async with asyncio.timeout(LOOKUP_TIMEOUT):
            url = httpx.URL(value).copy_with(fragment=None)
            for _ in range(MAX_REDIRECTS + 1):
                address = await public_address(url)
                # Pin the checked IP while preserving the website's Host and TLS identity.
                # A fresh client per hop prevents cookies or pooled TLS connections crossing hosts.
                async with httpx.AsyncClient(trust_env=False, timeout=3, follow_redirects=False) as client:
                    async with client.stream(
                        "GET",
                        url.copy_with(host=address),
                        headers={
                            "Host": url.netloc.decode("ascii"),
                            "Accept": "text/html, application/xhtml+xml",
                            "Accept-Encoding": "identity",
                            "User-Agent": "Stillnote/0.1 (link title preview)",
                        },
                        extensions={"sni_hostname": url.host},
                    ) as response:
                        if response.status_code in {301, 302, 303, 307, 308}:
                            location = response.headers.get("location")
                            if not location:
                                return ""
                            url = url.join(location).copy_with(fragment=None)
                            continue
                        response.raise_for_status()
                        content_type = response.headers.get("content-type", "").split(";", 1)[0].lower()
                        if content_type.strip() not in {"text/html", "application/xhtml+xml"}:
                            return ""
                        parser = PageTitleParser()
                        try:
                            decoder = codecs.getincrementaldecoder(response.encoding)(errors="replace")
                        except LookupError:
                            decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
                        consumed = 0
                        async for chunk in response.aiter_bytes(chunk_size=8192):
                            chunk = chunk[:MAX_HTML_BYTES - consumed]
                            consumed += len(chunk)
                            parser.feed(decoder.decode(chunk))
                            if parser.title_complete or parser.head_complete or consumed >= MAX_HTML_BYTES:
                                break
                        return parser.title
    except (httpx.HTTPError, OSError, ValueError, TimeoutError):
        pass
    return ""
