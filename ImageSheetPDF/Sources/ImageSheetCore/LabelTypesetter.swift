import CoreGraphics
import CoreText
import Foundation

/// ファイル名の表示に使うフォント。
/// 日本語・英数字・記号をまとめて表示できるヒラギノ角ゴシック W3 を優先し、ない場合はシステムフォントを使う。
public final class LabelFont: @unchecked Sendable {
    public static let preferredPostScriptName = "HiraginoSans-W3"

    public let ctFont: CTFont
    public let size: CGFloat
    public let ascent: CGFloat
    public let descent: CGFloat
    public let lineHeight: CGFloat

    public init(size: CGFloat) {
        var font = CTFontCreateWithName(Self.preferredPostScriptName as CFString, size, nil)
        if CTFontCopyPostScriptName(font) as String != Self.preferredPostScriptName,
           let system = CTFontCreateUIFontForLanguage(.system, size, "ja" as CFString) {
            font = system
        }
        ctFont = font
        self.size = size
        ascent = CTFontGetAscent(font)
        descent = CTFontGetDescent(font)
        lineHeight = ascent + descent + max(CTFontGetLeading(font), size * 0.1)
    }
}

/// 1件分のファイル名を組んだ結果
public struct LabelText: @unchecked Sendable {
    public let lines: [CTLine]
    /// 各行の幅（行末の空白を除く）
    public let lineWidths: [CGFloat]
    /// 実際に表示する文字列（省略した場合は「…」を含む）
    public let text: String
    public let isTruncated: Bool
}

/// ファイル名を指定の幅・行数に収める。
/// 収まらない場合は折り返し、それでも収まらない場合は拡張子を残して中間を「…」で省略する。
public final class LabelTypesetter: @unchecked Sendable {
    public static let ellipsis = "…"

    public let font: LabelFont
    public let maxWidth: CGFloat
    public let maxLines: Int
    private let attributes: [NSAttributedString.Key: Any]

    public init(font: LabelFont, maxWidth: CGFloat, maxLines: Int) {
        self.font = font
        self.maxWidth = max(maxWidth, 1)
        self.maxLines = max(maxLines, 1)
        attributes = [
            NSAttributedString.Key(kCTFontAttributeName as String): font.ctFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1),
            // 合字（ff → ﬀ など）を使うとPDFで「tiff」などを検索できなくなるため使わない
            NSAttributedString.Key(kCTLigatureAttributeName as String): 0,
        ]
    }

    public func layout(_ name: String) -> LabelText {
        if let lines = wrap(name) {
            return makeResult(lines, text: name, truncated: false)
        }
        let (stem, ext) = Self.splitExtension(name)
        let characters = Array(stem)
        func candidate(keeping count: Int) -> String {
            let head = (count + 1) / 2
            let tail = count / 2
            return String(characters.prefix(head)) + Self.ellipsis + String(characters.suffix(tail)) + ext
        }
        guard !characters.isEmpty, let shortest = wrap(candidate(keeping: 0)) else {
            return fallback(name)
        }
        // 収まる範囲で、名前の前後をできるだけ多く残す
        var best = (text: candidate(keeping: 0), lines: shortest)
        var low = 1
        var high = characters.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let text = candidate(keeping: mid)
            if let lines = wrap(text) {
                best = (text, lines)
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return makeResult(best.lines, text: best.text, truncated: true)
    }

    /// 「name.jpg」→（"name", ".jpg"）。拡張子がない名前は拡張子を空にする。
    public static func splitExtension(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        let ext = name[name.index(after: dot)...]
        guard !ext.isEmpty, ext.count <= 8, !ext.contains(" ") else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }

    /// 指定の幅で折り返す。行数を超える場合は nil。
    /// 拡張子の途中（「.j」と「pg」など）で行が分かれないよう、収まる限り拡張子の前で折り返す。
    private func wrap(_ string: String) -> [CTLine]? {
        let ext = Self.splitExtension(string).ext
        if !ext.isEmpty {
            let extensionStart = (string as NSString).length - (ext as NSString).length
            if let lines = wrap(string, keepTogetherFrom: extensionStart) { return lines }
        }
        return wrap(string, keepTogetherFrom: nil)
    }

    private func wrap(_ string: String, keepTogetherFrom keepStart: Int?) -> [CTLine]? {
        let attributed = NSAttributedString(string: string, attributes: attributes)
        let length = attributed.length
        guard length > 0 else { return [] }
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let width = Double(maxWidth)
        var lines: [CTLine] = []
        var start = 0
        while start < length {
            guard lines.count < maxLines else { return nil }
            // 単語の切れ目で折り返すと行が短くなりすぎる場合は、文字単位で折り返す
            let clusterCount = CTTypesetterSuggestClusterBreak(typesetter, start, width)
            var count = CTTypesetterSuggestLineBreak(typesetter, start, width)
            if count < clusterCount && Double(count) < Double(clusterCount) * 0.6 {
                count = clusterCount
            }
            if count <= 0 {
                count = (string as NSString).rangeOfComposedCharacterSequence(at: start).length
            }
            if let keepStart, start < keepStart, start + count > keepStart, start + count < length {
                count = keepStart - start
            }
            lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
            start += count
        }
        return lines
    }

    /// 拡張子と「…」だけでも収まらない極端に狭い場合の予備処理
    private func fallback(_ name: String) -> LabelText {
        let full = CTLineCreateWithAttributedString(NSAttributedString(string: name, attributes: attributes))
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: Self.ellipsis, attributes: attributes))
        let line = CTLineCreateTruncatedLine(full, Double(maxWidth), .end, token) ?? token
        return makeResult([line], text: name, truncated: true)
    }

    private func makeResult(_ lines: [CTLine], text: String, truncated: Bool) -> LabelText {
        let widths = lines.map { line -> CGFloat in
            let width = CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)
            return max(0, CGFloat(width))
        }
        return LabelText(lines: lines, lineWidths: widths, text: text, isTruncated: truncated)
    }
}
