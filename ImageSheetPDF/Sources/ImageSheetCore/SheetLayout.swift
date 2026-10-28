import CoreGraphics
import Foundation

/// 設定から求めたページ内の配置。座標はすべて「用紙の左上が原点・下向きが正」のポイント単位。
///
/// 1マスは上から「画像の領域」「すき間」「ファイル名の領域（2行分）」で構成する。
/// 画像数に関係なくマスの大きさは一定で、プレビューと保存の両方がこの配置を使う。
public struct SheetLayout: @unchecked Sendable {
    /// A4（210 × 297 mm）
    public static let a4Size = CGSize(width: 595.2756, height: 841.8898)
    /// ファイル名に使う最大行数
    public static let labelLineCount = 2
    public static let minimumCellWidthMM = 12.0
    public static let minimumImageHeightMM = 8.0

    public let settings: LayoutSettings
    public let font: LabelFont
    public let pageSize: CGSize
    public let margin: CGFloat
    public let spacing: CGFloat
    public let cellSize: CGSize
    /// 画像とファイル名の間のすき間
    public let labelGap: CGFloat
    /// ファイル名の領域の高さ
    public let labelHeight: CGFloat
    /// 画像の領域の高さ
    public let imageAreaHeight: CGFloat
    /// 配置できない場合の理由（配置できる場合は nil）
    public let problem: String?

    public init(settings: LayoutSettings) {
        self.settings = settings
        let font = LabelFont(size: CGFloat(settings.fontSize))
        self.font = font
        let a4 = Self.a4Size
        let pageSize = settings.orientation == .portrait ? a4 : CGSize(width: a4.height, height: a4.width)
        self.pageSize = pageSize
        let margin = Units.points(fromMM: settings.marginMM)
        let spacing = Units.points(fromMM: settings.spacingMM)
        self.margin = margin
        self.spacing = spacing

        let columns = CGFloat(max(settings.columns, 1))
        let rows = CGFloat(max(settings.rows, 1))
        let contentWidth = pageSize.width - margin * 2
        let contentHeight = pageSize.height - margin * 2
        let cellSize = CGSize(width: (contentWidth - spacing * (columns - 1)) / columns,
                              height: (contentHeight - spacing * (rows - 1)) / rows)
        self.cellSize = cellSize
        let labelGap = max(2, CGFloat(settings.fontSize) * 0.35)
        let labelHeight = font.lineHeight * CGFloat(Self.labelLineCount)
        self.labelGap = labelGap
        self.labelHeight = labelHeight
        let imageAreaHeight = cellSize.height - labelGap - labelHeight
        self.imageAreaHeight = imageAreaHeight

        problem = Self.validate(settings: settings, contentSize: CGSize(width: contentWidth, height: contentHeight),
                                cellSize: cellSize, imageAreaHeight: imageAreaHeight)
    }

    public var isValid: Bool { problem == nil }
    public var imagesPerPage: Int { max(settings.columns, 1) * max(settings.rows, 1) }

    /// 1マスに必要な最小の幅（12mm、または文字5字分の大きい方）
    public static func minimumCellWidth(fontSize: Double) -> CGFloat {
        max(Units.points(fromMM: minimumCellWidthMM), CGFloat(fontSize) * 5)
    }

    private static func validate(settings: LayoutSettings, contentSize: CGSize,
                                 cellSize: CGSize, imageAreaHeight: CGFloat) -> String? {
        if settings.columns < 1 || settings.rows < 1 {
            return "横の個数と縦の個数は、1以上の整数で指定してください。"
        }
        if contentSize.width <= 0 || contentSize.height <= 0 {
            return "用紙の余白が大きすぎて、画像を置く場所がありません。用紙の余白を小さくしてください。"
        }
        let minWidth = minimumCellWidth(fontSize: settings.fontSize)
        if cellSize.width < minWidth {
            let actual = cellSize.width > 0 ? "\(Units.format(Units.mm(fromPoints: cellSize.width)))mmになり" : "確保できず"
            return "横に\(settings.columns)個並べると、1マスの幅が\(actual)、必要な\(Units.format(Units.mm(fromPoints: minWidth)))mmに足りません。横の個数・用紙の余白・画像の間隔のいずれかを小さくしてください。"
        }
        let minImageHeight = Units.points(fromMM: minimumImageHeightMM)
        if imageAreaHeight < minImageHeight {
            let actual = imageAreaHeight > 0 ? "\(Units.format(Units.mm(fromPoints: imageAreaHeight)))mmになり" : "確保できず"
            return "縦に\(settings.rows)個並べると、ファイル名の欄を除いた画像の高さが\(actual)、必要な\(Units.format(minimumImageHeightMM))mmに足りません。縦の個数・用紙の余白・画像の間隔・文字サイズのいずれかを小さくしてください。"
        }
        return nil
    }

    // MARK: - ページとマス

    public func pageCount(forImageCount count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (count + imagesPerPage - 1) / imagesPerPage
    }

    /// 指定ページに載る画像の番号（0始まり）
    public func indices(onPage page: Int, imageCount count: Int) -> Range<Int> {
        let start = min(max(page, 0) * imagesPerPage, count)
        return start..<min(start + imagesPerPage, count)
    }

    /// マス番号（ページ内で左上から右へ、行が終われば次の行へ）の外枠
    public func cellRect(slot: Int) -> CGRect {
        let columns = max(settings.columns, 1)
        let column = slot % columns
        let row = slot / columns
        return CGRect(x: margin + CGFloat(column) * (cellSize.width + spacing),
                      y: margin + CGFloat(row) * (cellSize.height + spacing),
                      width: cellSize.width, height: cellSize.height)
    }

    public func imageAreaRect(slot: Int) -> CGRect {
        let cell = cellRect(slot: slot)
        return CGRect(x: cell.minX, y: cell.minY, width: cell.width, height: imageAreaHeight)
    }

    public func labelRect(slot: Int) -> CGRect {
        let cell = cellRect(slot: slot)
        return CGRect(x: cell.minX, y: cell.minY + imageAreaHeight + labelGap,
                      width: cell.width, height: labelHeight)
    }

    /// 縦横比を保ったまま画像全体を領域に収める（左右中央・下揃えでファイル名のすぐ上に置く）
    public static func fittedImageRect(for imageSize: CGSize, in area: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, area.width > 0, area.height > 0 else { return area }
        let scale = min(area.width / imageSize.width, area.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: area.midX - width / 2, y: area.maxY - height, width: width, height: height)
    }
}
