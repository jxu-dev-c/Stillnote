import Foundation

/// Best-effort page titles for context links. Failures never block saving a link, and
/// the request carries no cookies, no referrer, and no stored credentials.
public enum LinkMetadata {
    static let timeout: TimeInterval = 6
    static let maxHTMLBytes = 512 * 1024

    public static func pageTitle(_ address: String) async -> String {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil, url.user == nil, url.password == nil
        else { return "" }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = timeout
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("text/html, application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("Stillnote/0.1 (link title preview)", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let contentType = http.value(forHTTPHeaderField: "Content-Type")?
                  .split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(),
              contentType == "text/html" || contentType == "application/xhtml+xml"
        else { return "" }

        let html = String(decoding: data.prefix(maxHTMLBytes), as: UTF8.self)
        return title(fromHTML: html)
    }

    static func title(fromHTML html: String) -> String {
        if let range = html.range(of: "<title[^>]*>(.*?)</title>", options: [.regularExpression, .caseInsensitive]) {
            let fragment = html[range]
            if let open = fragment.firstIndex(of: ">"),
               let close = fragment.range(of: "</title", options: .caseInsensitive) {
                return normalize(String(fragment[fragment.index(after: open)..<close.lowerBound]))
            }
        }
        for property in ["og:title", "twitter:title"] {
            if let value = metaContent(html, property: property), !value.isEmpty { return value }
        }
        return ""
    }

    private static func metaContent(_ html: String, property: String) -> String? {
        let pattern = "<meta[^>]+(?:property|name)=[\"']\(property)[\"'][^>]*content=[\"']([^\"']*)[\"']"
        guard let range = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let fragment = String(html[range])
        guard let contentRange = fragment.range(
            of: "content=[\"']([^\"']*)[\"']", options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        let value = fragment[contentRange].dropFirst("content=".count).dropFirst().dropLast()
        return normalize(String(value))
    }

    private static func normalize(_ value: String) -> String {
        let decoded = value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        let collapsed = decoded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(Validation.maxLinkTitleLength))
    }
}
