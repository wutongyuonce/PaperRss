import XCTest
@testable import PaperRssCore

final class ArticleMarkdownExportTests: XCTestCase {
    private let zone = TimeZone(secondsFromGMT: 0)!
    private let published = Date(timeIntervalSince1970: 1_782_172_800) // 2026-06-23 00:00:00 UTC

    func testOriginalMarkdownKeepsLinksImagesCodeAndSkipsDuplicateTitle() {
        let input = sampleInput(segments: [], inFlight: false)
        let document = ArticleMarkdownExport.document(for: input, kind: .original)

        XCTAssertEqual(document?.filenameStem, "AI #191 The Hackening Begins")
        let markdown = document?.markdown ?? ""
        XCTAssertTrue(markdown.hasPrefix("# AI #191: The Hackening Begins\n"))
        XCTAssertTrue(markdown.contains("Don't Worry About the Vase · Zvi Mowshowitz · 2026-06-23 00:00"))
        XCTAssertTrue(markdown.contains("https://example.com/hackening"))
        XCTAssertTrue(markdown.contains("the [draft bill](https://example.com/bill)"))
        XCTAssertTrue(markdown.contains("![diagram](https://example.com/diagram.png)"))
        XCTAssertTrue(markdown.contains("```swift\nlet answer = 42\n```"))
        XCTAssertFalse(markdown.contains("全文译文"), "原文导出不能混入译文")
        XCTAssertEqual(markdown.components(separatedBy: "# AI #191").count, 2, "文首重复标题只留导出的一级标题")
    }

    func testTranslatedExportsStayClosedUntilEveryParagraphIsFinished() {
        var input = sampleInput(segments: partialSegments(), inFlight: false)
        XCTAssertTrue(ArticleMarkdownExport.availability(for: input).canExportOriginal)
        XCTAssertFalse(ArticleMarkdownExport.availability(for: input).canExportTranslated)
        XCTAssertNil(ArticleMarkdownExport.document(for: input, kind: .translation))
        XCTAssertNil(ArticleMarkdownExport.document(for: input, kind: .comparison))

        input.segments = completeSegments()
        input.translationInFlight = true
        XCTAssertFalse(ArticleMarkdownExport.availability(for: input).canExportTranslated, "最后一批还在写回时也不能下载译文")
        XCTAssertNotNil(ArticleMarkdownExport.document(for: input, kind: .original))

        input.translationInFlight = false
        input.segments[1].original = "这段原文已经被改写"
        XCTAssertNil(ArticleMarkdownExport.document(for: input, kind: .comparison))

        input.segments = completeSegments()
        input.segments[2].translation = "   "
        XCTAssertNil(ArticleMarkdownExport.document(for: input, kind: .translation))
    }

    func testTranslationAndComparisonUseReaderParagraphOrder() {
        var input = sampleInput(segments: Array(completeSegments().reversed()), inFlight: false)
        input.readerSource = nil
        XCTAssertNil(ArticleMarkdownExport.document(for: input, kind: .translation), "没有阅读器段落时不能用别的 HTML 猜测译文对齐")

        input = sampleInput(segments: Array(completeSegments().reversed()), inFlight: false)
        let translation = ArticleMarkdownExport.document(for: input, kind: .translation)
        XCTAssertEqual(translation?.filenameStem, "AI #191 The Hackening Begins.translation")
        XCTAssertEqual(
            translation?.markdown,
            """
            # 黑客开始了

            Don't Worry About the Vase · Zvi Mowshowitz · 2026-06-23 00:00

            https://example.com/hackening

            这是最糟的一天。

            另一处泄露是草案。

            """
        )
        XCTAssertFalse(translation?.markdown.contains("let answer = 42") ?? true, "未翻译的代码块不进入译文")

        let comparison = ArticleMarkdownExport.document(for: input, kind: .comparison)
        XCTAssertEqual(comparison?.filenameStem, "AI #191 The Hackening Begins.comparison")
        XCTAssertTrue(comparison?.markdown.contains("# AI #191: The Hackening Begins\n\n黑客开始了\n") ?? false)
        XCTAssertTrue(comparison?.markdown.contains("It was the worst day.\n\n这是最糟的一天。") ?? false)
        XCTAssertTrue(comparison?.markdown.contains("Another leak was the draft.\n\n另一处泄露是草案。") ?? false)
        XCTAssertFalse(comparison?.markdown.contains("let answer = 42") ?? true)
    }

    func testFeedHTMLCanExportOriginalBeforeTheReaderIsReady() {
        let input = ArticleMarkdownExportInput(
            title: "Standalone",
            feedHTML: "<p>Hello <a href=\"https://example.com\">there</a>.</p>",
            fallbackText: "",
            timeZone: zone
        )
        let document = ArticleMarkdownExport.document(for: input, kind: .original)
        XCTAssertEqual(document?.markdown.contains("Hello [there](https://example.com)."), true)
        XCTAssertNil(ArticleMarkdownExport.document(for: input, kind: .translation))
    }

    func testReaderSourceMatchesTheTranslationParagraphSplit() {
        let source = ReaderTranslationSource.make(
            articleText: "ignored when html exists",
            articleHTML: "<h1>Same Title</h1><p>Body</p><pre>code</pre>",
            title: "Same Title",
            fallbackText: ""
        )
        XCTAssertEqual(source.paragraphs.map(\.id), ["title", "p0"])
        XCTAssertEqual(source.paragraphs.map(\.original), ["Same Title", "Body"])
        XCTAssertFalse(source.html.contains("<h1>"))
    }

    private func sampleInput(segments: [BilingualSegment], inFlight: Bool) -> ArticleMarkdownExportInput {
        let html = """
        <h1>AI #191: The Hackening Begins</h1>
        <p>It was the worst day. See the <a href="https://example.com/bill">draft bill</a>.</p>
        <p>Another leak was the draft.</p>
        <p><img src="https://example.com/diagram.png" alt="diagram"></p>
        <pre><code class="language-swift">let answer = 42</code></pre>
        """
        let source = ReaderTranslationSource.make(
            articleText: "body",
            articleHTML: html,
            title: "AI #191: The Hackening Begins",
            fallbackText: ""
        )
        return ArticleMarkdownExportInput(
            title: "AI #191: The Hackening Begins",
            author: "Zvi Mowshowitz",
            feedTitle: "Don't Worry About the Vase",
            publishedAt: published,
            canonicalURL: URL(string: "https://example.com/hackening"),
            timeZone: zone,
            readerSource: source,
            segments: segments,
            translationInFlight: inFlight
        )
    }

    private func completeSegments() -> [BilingualSegment] {
        [
            BilingualSegment(id: "title", original: "AI #191: The Hackening Begins", translation: "黑客开始了"),
            BilingualSegment(id: "p0", original: "It was the worst day. See the draft bill.", translation: "这是最糟的一天。"),
            BilingualSegment(id: "p1", original: "Another leak was the draft.", translation: "另一处泄露是草案。")
        ]
    }

    private func partialSegments() -> [BilingualSegment] {
        Array(completeSegments().prefix(2))
    }
}
