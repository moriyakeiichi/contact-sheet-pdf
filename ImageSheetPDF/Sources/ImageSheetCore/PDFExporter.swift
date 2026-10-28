import CoreGraphics
import Foundation

/// 中止の指示を別スレッドへ伝える
public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

/// PDFの保存。一時ファイルに書き出して内容を確認してから保存先に置き換えるため、
/// 失敗・中止しても保存先の既存ファイルは変わらず、不完全なPDFも残らない。
public enum PDFExporter {
    public static func export(entries: [SheetEntry], layout: SheetLayout, to destination: URL,
                              isCancelled: () -> Bool = { false },
                              progress: (Int, Int) -> Void = { _, _ in }) throws {
        if let problem = layout.problem { throw SheetError.invalidLayout(problem) }
        let renderer = SheetRenderer(layout: layout)
        let pageCount = layout.pageCount(forImageCount: entries.count)
        let title = destination.deletingPathExtension().lastPathComponent
        try SafeFileWriter.write(to: destination, expectedPageCount: pageCount) { temporaryURL in
            try renderer.writePDF(to: temporaryURL, entries: entries, title: title, loadImage: { entry, placement in
                let maxPixel = SheetRenderer.pixelSize(for: placement.imageRect, dpi: SheetRenderer.outputDPI,
                                                       original: entry.pixelSize)
                let data = try ImageLoader.renderJPEGData(url: entry.url, maxPixel: maxPixel,
                                                          quality: SheetRenderer.outputJPEGQuality)
                guard let image = ImageLoader.image(fromJPEG: data) else {
                    throw ImageLoadError.unreadable(entry.fileName)
                }
                return image
            }, progress: progress, isCancelled: isCancelled)
        }
    }
}

public enum SafeFileWriter {
    public static func write(to destination: URL, expectedPageCount: Int, body: (URL) throws -> Void) throws {
        let fileManager = FileManager.default
        // 保存先と同じボリュームの一時フォルダ（置き換えを一度で行うため）
        let temporaryDirectory: URL
        if let directory = try? fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                appropriateFor: destination, create: true) {
            temporaryDirectory = directory
        } else {
            temporaryDirectory = fileManager.temporaryDirectory
                .appendingPathComponent("ImageSheetPDF-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        }
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let temporaryURL = temporaryDirectory.appendingPathComponent(destination.lastPathComponent)
        try body(temporaryURL)

        guard let document = CGPDFDocument(temporaryURL as CFURL),
              document.numberOfPages == expectedPageCount else {
            throw SheetError.verificationFailed
        }
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        }
    }
}
