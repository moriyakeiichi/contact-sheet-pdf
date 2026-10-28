import CoreGraphics
import CoreText
import Foundation

/// PDFに並べる1枚分の情報
public struct SheetEntry: Sendable, Identifiable {
    public let id: UUID
    public let url: URL
    public let fileName: String
    public let pixelSize: CGSize

    public init(id: UUID, url: URL, fileName: String, pixelSize: CGSize) {
        self.id = id
        self.url = url
        self.fileName = fileName
        self.pixelSize = pixelSize
    }
}

/// 1マス分の配置（座標は用紙の左上が原点）
public struct CellPlacement: @unchecked Sendable {
    /// entries 内の番号
    public let index: Int
    /// ページ内のマス番号
    public let slot: Int
    public let cellRect: CGRect
    public let imageRect: CGRect
    public let textRect: CGRect
    public let label: LabelText
}

public enum SheetError: LocalizedError, Equatable {
    case invalidLayout(String)
    case cancelled
    case imagesUnavailable([String])
    case cannotCreateFile
    case verificationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidLayout(let reason):
            return "現在の設定では配置できません。\(reason)"
        case .cancelled:
            return "保存を中止しました。"
        case .imagesUnavailable(let names):
            let shown = names.prefix(10).map { "・\($0)" }.joined(separator: "\n")
            let more = names.count > 10 ? "\nほか\(names.count - 10)件" : ""
            return "次の画像を読み込めないため、保存を中止しました。移動・削除されていないか確認し、一覧から取り除くか元の場所に戻してください。\n\(shown)\(more)"
        case .cannotCreateFile:
            return "PDFファイルを作成できませんでした。保存先に書き込めるか確認してください。"
        case .verificationFailed:
            return "作成したPDFを確認できなかったため、保存を中止しました。保存先の空き容量を確認してください。"
        }
    }
}

/// プレビューと保存で共通の描画処理。両者の違いは画像の解像度だけで、配置・改ページ・文字は同じになる。
public final class SheetRenderer: @unchecked Sendable {
    /// 保存するPDFの画像解像度（印刷にも十分な300dpi相当。元画像より大きくはしない）
    public static let outputDPI: CGFloat = 300
    public static let outputJPEGQuality: CGFloat = 0.85
    public static let creatorName = "画像一覧PDF"

    public let layout: SheetLayout
    public let typesetter: LabelTypesetter

    public init(layout: SheetLayout) {
        self.layout = layout
        typesetter = LabelTypesetter(font: layout.font, maxWidth: layout.cellSize.width,
                                     maxLines: SheetLayout.labelLineCount)
    }

    public func placements(page: Int, entries: [SheetEntry]) -> [CellPlacement] {
        let base = page * layout.imagesPerPage
        return layout.indices(onPage: page, imageCount: entries.count).map { index in
            let slot = index - base
            let entry = entries[index]
            return CellPlacement(index: index, slot: slot,
                                 cellRect: layout.cellRect(slot: slot),
                                 imageRect: SheetLayout.fittedImageRect(for: entry.pixelSize,
                                                                        in: layout.imageAreaRect(slot: slot)),
                                 textRect: layout.labelRect(slot: slot),
                                 label: typesetter.layout(entry.fileName))
        }
    }

    /// 配置サイズに対して必要な長辺のピクセル数
    public static func pixelSize(for drawnRect: CGRect, dpi: CGFloat, original: CGSize) -> Int {
        let needed = Int((max(drawnRect.width, drawnRect.height) * dpi / 72).rounded(.up))
        let originalLongest = Int(max(original.width, original.height))
        return max(16, min(needed, originalLongest))
    }

    // MARK: - 描画

    /// 1ページ分を描く。context は PDF のページを開始した状態で渡す。images は entries 内の番号で引く。
    public func draw(_ placements: [CellPlacement], images: [Int: CGImage], in context: CGContext) {
        let pageHeight = layout.pageSize.height
        func pdfRect(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: pageHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        context.saveGState()
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: layout.pageSize))
        context.interpolationQuality = .high

        for placement in placements {
            if let image = images[placement.index] {
                context.draw(image, in: pdfRect(placement.imageRect))
            } else {
                drawMissingPlaceholder(in: pdfRect(placement.imageRect), context: context)
            }

            // ファイル名：マスの幅・ファイル名の領域の中だけに描く（画像や隣のマスに重ならない）
            context.saveGState()
            context.clip(to: pdfRect(placement.textRect))
            context.textMatrix = .identity
            var baseline = placement.textRect.minY + layout.font.ascent
            for (line, width) in zip(placement.label.lines, placement.label.lineWidths) {
                let x = placement.textRect.minX + (placement.textRect.width - width) / 2
                context.textPosition = CGPoint(x: x, y: pageHeight - baseline)
                CTLineDraw(line, context)
                baseline += layout.font.lineHeight
            }
            context.restoreGState()
        }
        context.restoreGState()
    }

    /// プレビューで画像が読み込めない場合の目印（保存時は描かずに中止する）
    private func drawMissingPlaceholder(in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.setFillColor(CGColor(gray: 0.93, alpha: 1))
        context.fill(rect)
        context.setStrokeColor(CGColor(red: 0.85, green: 0.2, blue: 0.2, alpha: 1))
        context.setLineWidth(1)
        context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        context.move(to: CGPoint(x: rect.minX, y: rect.minY))
        context.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        context.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        context.strokePath()
        context.restoreGState()
    }

    private func auxiliaryInfo(title: String?) -> CFDictionary {
        var info: [CFString: Any] = [kCGPDFContextCreator: Self.creatorName]
        if let title, !title.isEmpty { info[kCGPDFContextTitle] = title }
        return info as CFDictionary
    }

    /// 1ページだけのPDFデータ（プレビュー用）
    public func singlePagePDF(_ placements: [CellPlacement], images: [Int: CGImage]) -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: layout.pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, auxiliaryInfo(title: nil)) else {
            return Data()
        }
        context.beginPDFPage(nil)
        draw(placements, images: images, in: context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// 全ページをPDFファイルに書き出す。画像はページごとに用意して描き、終わったら手放す。
    public func writePDF(to url: URL, entries: [SheetEntry], title: String?,
                         loadImage: (SheetEntry, CellPlacement) throws -> CGImage,
                         progress: (Int, Int) -> Void,
                         isCancelled: () -> Bool) throws {
        if let problem = layout.problem { throw SheetError.invalidLayout(problem) }
        let missing = entries.filter { !FileManager.default.isReadableFile(atPath: $0.url.path) }
        if !missing.isEmpty { throw SheetError.imagesUnavailable(missing.map(\.fileName)) }

        var mediaBox = CGRect(origin: .zero, size: layout.pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, auxiliaryInfo(title: title)) else {
            throw SheetError.cannotCreateFile
        }
        let pageCount = layout.pageCount(forImageCount: entries.count)
        for page in 0..<pageCount {
            if isCancelled() {
                context.closePDF()
                throw SheetError.cancelled
            }
            let pagePlacements = placements(page: page, entries: entries)
            let loaded = LockedArray<CGImage?>(repeating: nil, count: pagePlacements.count)
            let failed = LockedArray<String?>(repeating: nil, count: pagePlacements.count)
            DispatchQueue.concurrentPerform(iterations: pagePlacements.count) { k in
                let placement = pagePlacements[k]
                let entry = entries[placement.index]
                do {
                    loaded[k] = try loadImage(entry, placement)
                } catch {
                    failed[k] = entry.fileName
                }
            }
            let failedNames = failed.values.compactMap { $0 }
            if !failedNames.isEmpty {
                context.closePDF()
                throw SheetError.imagesUnavailable(failedNames)
            }
            if isCancelled() {
                context.closePDF()
                throw SheetError.cancelled
            }
            var images: [Int: CGImage] = [:]
            for (placement, image) in zip(pagePlacements, loaded.values) {
                images[placement.index] = image
            }
            context.beginPDFPage(nil)
            draw(pagePlacements, images: images, in: context)
            context.endPDFPage()
            progress(page + 1, pageCount)
        }
        context.closePDF()
    }
}

/// 並列処理の結果を集めるための配列
final class LockedArray<Element>: @unchecked Sendable {
    private var storage: [Element]
    private let lock = NSLock()

    init(repeating value: Element, count: Int) {
        storage = Array(repeating: value, count: count)
    }

    subscript(index: Int) -> Element {
        get { lock.lock(); defer { lock.unlock() }; return storage[index] }
        set { lock.lock(); storage[index] = newValue; lock.unlock() }
    }

    var values: [Element] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
