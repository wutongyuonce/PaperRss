import Foundation

/// 阅读器真正拿去翻译的正文。段落 ID 与 `ArticleReaderView` 的双语请求一致：
/// 空 HTML 先包成段落，重复的文首标题先去掉，再按阅读块编号。
public struct ReaderTranslationSource: Equatable, Sendable {
    public var text: String
    public var html: String
    public var paragraphs: [ReaderParagraph]

    public init(text: String, html: String, paragraphs: [ReaderParagraph]) {
        self.text = text
        self.html = html
        self.paragraphs = paragraphs
    }

    public static func make(
        articleText: String,
        articleHTML: String,
        title: String,
        fallbackText: String
    ) -> ReaderTranslationSource {
        let loadedText = articleText.isEmpty ? fallbackText : articleText
        let html: String
        if articleHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !loadedText.isEmpty {
            let escaped = ArticleMarkupNormalizer.escapeHTML(loadedText)
                .replacingOccurrences(of: "\n", with: "<br>")
            html = "<p>\(escaped)</p>"
        } else {
            html = articleHTML
        }
        let loadedHTML = ArticleExtractor.removingDuplicateLeadingHeading(from: html, articleTitle: title) ?? ""
        let paragraphs = loadedHTML.isEmpty
            ? []
            : ArticleExtractor.readerParagraphs(in: loadedHTML, title: title)
        return ReaderTranslationSource(text: loadedText, html: loadedHTML, paragraphs: paragraphs)
    }
}

public enum ArticleMarkdownExportKind: String, Sendable, Equatable, CaseIterable {
    case original
    case translation
    case comparison
}

public struct ArticleMarkdownExportInput: Sendable, Equatable {
    public var title: String
    public var author: String?
    public var feedTitle: String?
    public var publishedAt: Date?
    public var canonicalURL: URL?
    public var timeZone: TimeZone
    /// 阅读器当前文档。译文覆盖检查只用这一份段落，不能改用另一份 HTML 重切。
    public var readerSource: ReaderTranslationSource?
    public var feedHTML: String?
    public var fallbackText: String
    public var segments: [BilingualSegment]
    /// 这篇的双语请求还没结束，包括下一批已经排队的情况。
    public var translationInFlight: Bool

    public init(
        title: String,
        author: String? = nil,
        feedTitle: String? = nil,
        publishedAt: Date? = nil,
        canonicalURL: URL? = nil,
        timeZone: TimeZone = .current,
        readerSource: ReaderTranslationSource? = nil,
        feedHTML: String? = nil,
        fallbackText: String = "",
        segments: [BilingualSegment] = [],
        translationInFlight: Bool = false
    ) {
        self.title = title
        self.author = author
        self.feedTitle = feedTitle
        self.publishedAt = publishedAt
        self.canonicalURL = canonicalURL
        self.timeZone = timeZone
        self.readerSource = readerSource
        self.feedHTML = feedHTML
        self.fallbackText = fallbackText
        self.segments = segments
        self.translationInFlight = translationInFlight
    }
}

public struct ArticleMarkdownExportAvailability: Sendable, Equatable {
    public var canExportOriginal: Bool
    public var canExportTranslated: Bool

    public init(canExportOriginal: Bool, canExportTranslated: Bool) {
        self.canExportOriginal = canExportOriginal
        self.canExportTranslated = canExportTranslated
    }
}

public struct ArticleMarkdownDocument: Sendable, Equatable {
    public var filenameStem: String
    public var markdown: String

    public init(filenameStem: String, markdown: String) {
        self.filenameStem = filenameStem
        self.markdown = markdown
    }
}

/// 文章 Markdown 导出的唯一判定：原文随时可下；译文和对照必须覆盖阅读器的
/// 每一个可翻译段落，且当前没有进行中的双语请求。代码块不参与翻译，
/// 因此只出现在原文里。
public enum ArticleMarkdownExport {
    public static func availability(for input: ArticleMarkdownExportInput) -> ArticleMarkdownExportAvailability {
        let hasTitle = !input.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasBody = !originalBodySource(for: input).plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canExportOriginal = hasTitle || hasBody
        return ArticleMarkdownExportAvailability(
            canExportOriginal: canExportOriginal,
            canExportTranslated: matchedTranslations(in: input) != nil
        )
    }

    public static func document(
        for input: ArticleMarkdownExportInput,
        kind: ArticleMarkdownExportKind
    ) -> ArticleMarkdownDocument? {
        let availability = availability(for: input)
        switch kind {
        case .original:
            guard availability.canExportOriginal else { return nil }
            let body = ReaderHTMLMarkdown.render(originalBodySource(for: input))
            return ArticleMarkdownDocument(
                filenameStem: filenameStem(for: input.title, kind: kind),
                markdown: renderDocument(input, heading: displayTitle(input.title), subtitle: nil, body: body)
            )
        case .translation, .comparison:
            guard let matched = matchedTranslations(in: input) else { return nil }
            let translatedTitle = matched.title
            if kind == .translation {
                return ArticleMarkdownDocument(
                    filenameStem: filenameStem(for: input.title, kind: kind),
                    markdown: renderDocument(input, heading: translatedTitle, subtitle: nil, body: body(matched.blocks, comparison: false))
                )
            }
            return ArticleMarkdownDocument(
                filenameStem: filenameStem(for: input.title, kind: kind),
                markdown: renderDocument(
                    input,
                    heading: displayTitle(input.title),
                    subtitle: translatedTitle,
                    body: body(matched.blocks, comparison: true)
                )
            )
        }
    }

    public static func filenameStem(for title: String, kind: ArticleMarkdownExportKind) -> String {
        var stem = title.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        stem = stem.components(separatedBy: forbidden).joined(separator: " ")
        stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if stem.count > 80 {
            stem = String(stem.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if stem.isEmpty { stem = "article" }
        switch kind {
        case .original: return stem
        case .translation: return stem + ".translation"
        case .comparison: return stem + ".comparison"
        }
    }

    private struct MatchedTranslation {
        var title: String
        var blocks: [(original: String, translation: String)]
    }

    /// 进行中、缺段、原文对不上、译文为空，都视为没完成。不读取 `isComplete` 标记。
    private static func matchedTranslations(in input: ArticleMarkdownExportInput) -> MatchedTranslation? {
        guard !input.translationInFlight, let source = input.readerSource else { return nil }
        let paragraphs = source.paragraphs
        guard !paragraphs.isEmpty else { return nil }
        var byID: [String: BilingualSegment] = [:]
        for segment in input.segments {
            byID[segment.id] = segment
        }
        var title = ""
        var blocks: [(original: String, translation: String)] = []
        for paragraph in paragraphs {
            guard let segment = byID[paragraph.id],
                  paragraph.original.isSameReaderParagraph(as: segment.original) else {
                return nil
            }
            let translation = segment.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translation.isEmpty else { return nil }
            if paragraph.id == "title" {
                title = translation
            } else {
                blocks.append((paragraph.original.trimmingCharacters(in: .whitespacesAndNewlines), translation))
            }
        }
        if title.isEmpty {
            title = displayTitle(input.title)
        }
        return MatchedTranslation(title: title, blocks: blocks)
    }

    private static func originalBodySource(for input: ArticleMarkdownExportInput) -> String {
        if let readerSource = input.readerSource {
            return readerSource.html
        }
        let feedHTML = input.feedHTML?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !feedHTML.isEmpty {
            let extracted = ArticleExtractor.content(from: feedHTML, baseURL: input.canonicalURL)
            return ReaderTranslationSource.make(
                articleText: extracted.text,
                articleHTML: extracted.html,
                title: input.title,
                fallbackText: input.fallbackText
            ).html
        }
        return ReaderTranslationSource.make(
            articleText: "",
            articleHTML: "",
            title: input.title,
            fallbackText: input.fallbackText
        ).html
    }

    private static func body(_ blocks: [(original: String, translation: String)], comparison: Bool) -> String {
        blocks.map { block in
            comparison ? "\(block.original)\n\n\(block.translation)" : block.translation
        }.joined(separator: "\n\n")
    }

    private static func renderDocument(
        _ input: ArticleMarkdownExportInput,
        heading: String,
        subtitle: String?,
        body: String
    ) -> String {
        var parts = ["# \(heading)"]
        if let subtitle, !subtitle.isEmpty, subtitle != heading {
            parts.append("")
            parts.append(subtitle)
        }
        let meta = metadataLine(input)
        if !meta.isEmpty {
            parts.append("")
            parts.append(meta)
        }
        if let url = input.canonicalURL?.absoluteString, !url.isEmpty {
            parts.append("")
            parts.append(url)
        }
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBody.isEmpty {
            parts.append("")
            parts.append(trimmedBody)
        }
        return parts.joined(separator: "\n") + "\n"
    }

    private static func metadataLine(_ input: ArticleMarkdownExportInput) -> String {
        var parts: [String] = []
        if let feed = input.feedTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !feed.isEmpty {
            parts.append(feed)
        }
        if let author = input.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            parts.append(author)
        }
        if let publishedAt = input.publishedAt {
            parts.append(metadataDate(publishedAt, timeZone: input.timeZone))
        }
        return parts.joined(separator: " · ")
    }

    static func metadataDate(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func displayTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名文章" : trimmed
    }
}

enum ReaderHTMLMarkdown {
    static func render(_ html: String) -> String {
        var source = html.replacingOccurrences(of: "\r\n", with: "\n")
        var fences: [String] = []
        source = HTMLMarkdownTransform.replacing(source, pattern: "(?is)<pre\\b[^>]*>(.*?)</pre>") { match, text in
            let inner = HTMLMarkdownTransform.group(1, in: match, source: text)
            let language = codeLanguage(in: inner)
            let code = HTMLTextDecoder.decoded(HTMLMarkdownTransform.stripTags(inner))
                .trimmingCharacters(in: .newlines)
            fences.append("```\(language)\n\(code)\n```")
            return "\n\n\(fenceToken(fences.count - 1))\n\n"
        }
        source = renderLists(in: source)
        source = renderBlockquotes(in: source)
        source = renderTables(in: source)
        source = HTMLMarkdownTransform.replacing(source, pattern: "(?is)<h([1-6])\\b[^>]*>(.*?)</h\\1>") { match, text in
            let level = Int(HTMLMarkdownTransform.group(1, in: match, source: text)) ?? 1
            let inner = renderInline(HTMLMarkdownTransform.group(2, in: match, source: text))
            let marks = String(repeating: "#", count: min(6, max(1, level)))
            return "\n\n\(marks) \(inner)\n\n"
        }
        source = renderInline(source)
        for index in fences.indices {
            source = source.replacingOccurrences(of: fenceToken(index), with: fences[index])
        }
        return HTMLMarkdownTransform.tidy(source)
    }

    private static func fenceToken(_ index: Int) -> String {
        "\u{E000}FENCE\(index)\u{E001}"
    }

    private static func codeLanguage(in html: String) -> String {
        guard let classValue = HTMLMarkdownTransform.attribute("class", in: html) else { return "" }
        for token in classValue.split(whereSeparator: \.isWhitespace) {
            let value = String(token)
            let language: String
            if value.hasPrefix("language-") {
                language = String(value.dropFirst("language-".count))
            } else if value.hasPrefix("lang-") {
                language = String(value.dropFirst("lang-".count))
            } else {
                continue
            }
            let allowed = language.unicodeScalars.filter { scalar in
                CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == "+"
            }
            return String(String.UnicodeScalarView(allowed))
        }
        return ""
    }

    private static func renderLists(in html: String) -> String {
        var source = html
        let pattern = "(?is)<(ul|ol)\\b[^>]*>((?:(?!</?(?:ul|ol)\\b).)*)</\\1>"
        while true {
            let next = HTMLMarkdownTransform.replacing(source, pattern: pattern) { match, text in
                let kind = HTMLMarkdownTransform.group(1, in: match, source: text).lowercased()
                let inner = HTMLMarkdownTransform.group(2, in: match, source: text)
                return "\n\n" + renderList(inner, ordered: kind == "ol") + "\n\n"
            }
            if next == source { return source }
            source = next
        }
    }

    private static func renderList(_ html: String, ordered: Bool) -> String {
        var index = 0
        let rendered = HTMLMarkdownTransform.replacing(html, pattern: "(?is)<li\\b[^>]*>(.*?)</li>") { match, text in
            index += 1
            let marker = ordered ? "\(index). " : "- "
            let inner = renderInline(HTMLMarkdownTransform.group(1, in: match, source: text))
            return listItem(inner, marker: marker) + "\n"
        }
        return HTMLMarkdownTransform.stripTags(rendered).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func listItem(_ text: String, marker: String) -> String {
        let lines = HTMLMarkdownTransform.tidy(text).components(separatedBy: "\n")
        guard !lines.isEmpty else { return marker.trimmingCharacters(in: .whitespaces) }
        var output = [marker + lines[0]]
        for line in lines.dropFirst() {
            output.append(line.isEmpty ? "" : "  " + line)
        }
        return output.joined(separator: "\n")
    }

    private static func renderBlockquotes(in html: String) -> String {
        var source = html
        let pattern = "(?is)<blockquote\\b[^>]*>((?:(?!</?blockquote\\b).)*)</blockquote>"
        while true {
            let next = HTMLMarkdownTransform.replacing(source, pattern: pattern) { match, text in
                let inner = renderInline(HTMLMarkdownTransform.group(1, in: match, source: text))
                let quoted = HTMLMarkdownTransform.tidy(inner)
                    .components(separatedBy: "\n")
                    .map { "> \($0)" }
                    .joined(separator: "\n")
                return "\n\n\(quoted)\n\n"
            }
            if next == source { return source }
            source = next
        }
    }

    private static func renderTables(in html: String) -> String {
        HTMLMarkdownTransform.replacing(html, pattern: "(?is)<table\\b[^>]*>(.*?)</table>") { match, text in
            let inner = HTMLMarkdownTransform.group(1, in: match, source: text)
            let rows = HTMLMarkdownTransform.matches(inner, pattern: "(?is)<tr\\b[^>]*>(.*?)</tr>").map { row in
                HTMLMarkdownTransform.matches(row, pattern: "(?is)<t[dh]\\b[^>]*>(.*?)</t[dh]>").map { cell in
                    renderInline(cell).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                }.joined(separator: " | ")
            }.filter { !$0.isEmpty }
            return "\n\n" + rows.joined(separator: "\n") + "\n\n"
        }
    }

    private static func renderInline(_ html: String) -> String {
        var codeSlots: [String] = []
        var text = HTMLMarkdownTransform.replacing(html, pattern: "(?is)<code\\b[^>]*>(.*?)</code>") { match, source in
            let code = HTMLTextDecoder.decoded(HTMLMarkdownTransform.stripTags(HTMLMarkdownTransform.group(1, in: match, source: source)))
            codeSlots.append(inlineCode(code))
            return "\u{E000}CODE\(codeSlots.count - 1)\u{E001}"
        }
        text = HTMLMarkdownTransform.replacing(text, pattern: "(?is)<img\\b([^>]*)/?>") { match, source in
            imageMarkdown(HTMLMarkdownTransform.group(1, in: match, source: source))
        }
        text = HTMLMarkdownTransform.replacing(text, pattern: "(?is)<a\\b([^>]*)>(.*?)</a>") { match, source in
            let href = HTMLMarkdownTransform.attribute("href", in: HTMLMarkdownTransform.group(1, in: match, source: source))
                .map(HTMLTextDecoder.decoded)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let label = HTMLTextDecoder.decoded(HTMLMarkdownTransform.stripTags(HTMLMarkdownTransform.group(2, in: match, source: source)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !href.isEmpty else { return label }
            return "[\(label)](\(href))"
        }
        text = HTMLMarkdownTransform.replacing(text, pattern: "(?is)<(?:strong|b)\\b[^>]*>(.*?)</(?:strong|b)>") { match, source in
            let inner = HTMLTextDecoder.decoded(HTMLMarkdownTransform.stripTags(HTMLMarkdownTransform.group(1, in: match, source: source)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return inner.isEmpty ? "" : "**\(inner)**"
        }
        text = HTMLMarkdownTransform.replacing(text, pattern: "(?is)<(?:em|i)\\b[^>]*>(.*?)</(?:em|i)>") { match, source in
            let inner = HTMLTextDecoder.decoded(HTMLMarkdownTransform.stripTags(HTMLMarkdownTransform.group(1, in: match, source: source)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return inner.isEmpty ? "" : "*\(inner)*"
        }
        text = text.replacingOccurrences(of: "(?is)<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)</(?:p|div|h[1-6]|li|blockquote|tr|pre)>", with: "\n\n", options: .regularExpression)
        text = HTMLMarkdownTransform.stripTags(text)
        text = HTMLTextDecoder.decoded(text)
        for index in codeSlots.indices {
            text = text.replacingOccurrences(of: "\u{E000}CODE\(index)\u{E001}", with: codeSlots[index])
        }
        return text
    }

    private static func imageMarkdown(_ attributes: String) -> String {
        guard let src = HTMLMarkdownTransform.attribute("src", in: attributes).map(HTMLTextDecoder.decoded),
              !src.isEmpty else { return "" }
        let alt = HTMLMarkdownTransform.attribute("alt", in: attributes).map(HTMLTextDecoder.decoded) ?? ""
        return "![\(alt)](\(src))"
    }

    private static func inlineCode(_ code: String) -> String {
        if code.contains("`") {
            return "`` \(code) ``"
        }
        return "`\(code)`"
    }
}

private enum HTMLMarkdownTransform {
    static func replacing(
        _ source: String,
        pattern: String,
        _ transform: (NSTextCheckingResult, String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return source }
        let range = NSRange(source.startIndex..., in: source)
        let matches = regex.matches(in: source, range: range)
        guard !matches.isEmpty else { return source }
        var result = ""
        var cursor = source.startIndex
        for match in matches {
            guard let matchRange = Range(match.range, in: source) else { continue }
            result += source[cursor..<matchRange.lowerBound]
            result += transform(match, source)
            cursor = matchRange.upperBound
        }
        result += source[cursor...]
        return result
    }

    static func matches(_ source: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return group(1, in: match, source: source)
        }
    }

    static func group(_ index: Int, in match: NSTextCheckingResult, source: String) -> String {
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: source) else { return "" }
        return String(source[swiftRange])
    }

    static func attribute(_ name: String, in html: String) -> String? {
        let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'=<>`]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) else { return nil }
        for index in 1..<match.numberOfRanges {
            let value = group(index, in: match, source: html)
            if !value.isEmpty || match.range(at: index).location != NSNotFound {
                if match.range(at: index).location != NSNotFound { return value }
            }
        }
        return nil
    }

    static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: "(?is)<[^>]+>", with: "", options: .regularExpression)
    }

    static func tidy(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").map { line in
            line.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression)
        }
        var collapsed: [String] = []
        var blankRun = 0
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blankRun += 1
                if blankRun <= 1, !collapsed.isEmpty { collapsed.append("") }
            } else {
                blankRun = 0
                collapsed.append(line)
            }
        }
        while collapsed.last?.isEmpty == true { collapsed.removeLast() }
        return collapsed.joined(separator: "\n")
    }
}
