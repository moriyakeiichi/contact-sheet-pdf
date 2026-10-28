import CoreGraphics
import Foundation

/// プレビュー用の軽量画像（JPEGデータ）を保持する。使用量が上限を超えると古いものから捨てる。
public final class PreviewImageCache: @unchecked Sendable {
    private let cache = NSCache<NSString, NSData>()

    public init(costLimit: Int = 256 * 1024 * 1024) {
        cache.totalCostLimit = costLimit
    }

    public func image(for entry: SheetEntry, maxPixel: Int) -> CGImage? {
        let limited = min(maxPixel, Int(max(entry.pixelSize.width, entry.pixelSize.height)))
        let key = "\(entry.id.uuidString)-\(limited)" as NSString
        if let data = cache.object(forKey: key) {
            return ImageLoader.image(fromJPEG: data as Data)
        }
        guard let data = try? ImageLoader.renderJPEGData(url: entry.url, maxPixel: limited, quality: 0.8) else {
            return nil
        }
        cache.setObject(data as NSData, forKey: key, cost: data.count)
        return ImageLoader.image(fromJPEG: data)
    }

    public func removeAll() {
        cache.removeAllObjects()
    }
}

public struct PreviewPageResult: Sendable {
    public let pdfData: Data
    public let pageIDs: Set<UUID>
    /// 読み込めなかった画像
    public let missingIDs: Set<UUID>
}

/// プレビュー1ページ分の作成。保存と同じ SheetRenderer を使い、画像だけ軽量版にする。
public enum PreviewBuilder {
    /// マスの大きさに応じたプレビュー画像の長辺ピクセル数（約180dpi相当を段階的に選ぶ）
    public static func pixelSize(for layout: SheetLayout) -> Int {
        let longest = max(layout.cellSize.width, layout.imageAreaHeight)
        let wanted = longest * 2.5
        for size in [256, 384, 512, 768, 1024, 1536] where CGFloat(size) >= wanted {
            return size
        }
        return 1536
    }

    public static func renderPage(_ page: Int, entries: [SheetEntry], layout: SheetLayout,
                                  cache: PreviewImageCache) -> PreviewPageResult {
        let renderer = SheetRenderer(layout: layout)
        let placements = renderer.placements(page: page, entries: entries)
        let images = loadImages(placements, entries: entries, layout: layout, cache: cache)
        let pageIDs = Set(placements.map { entries[$0.index].id })
        let missing = Set(placements.filter { images[$0.index] == nil }.map { entries[$0.index].id })
        return PreviewPageResult(pdfData: renderer.singlePagePDF(placements, images: images),
                                 pageIDs: pageIDs, missingIDs: missing)
    }

    /// 次のページの画像を先に用意しておく
    public static func prefetch(page: Int, entries: [SheetEntry], layout: SheetLayout, cache: PreviewImageCache) {
        let renderer = SheetRenderer(layout: layout)
        _ = loadImages(renderer.placements(page: page, entries: entries), entries: entries, layout: layout, cache: cache)
    }

    private static func loadImages(_ placements: [CellPlacement], entries: [SheetEntry], layout: SheetLayout,
                                   cache: PreviewImageCache) -> [Int: CGImage] {
        let maxPixel = pixelSize(for: layout)
        let loaded = LockedArray<CGImage?>(repeating: nil, count: placements.count)
        DispatchQueue.concurrentPerform(iterations: placements.count) { k in
            loaded[k] = cache.image(for: entries[placements[k].index], maxPixel: maxPixel)
        }
        var images: [Int: CGImage] = [:]
        for (placement, image) in zip(placements, loaded.values) {
            images[placement.index] = image
        }
        return images
    }
}
