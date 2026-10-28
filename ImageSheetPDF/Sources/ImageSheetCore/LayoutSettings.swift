import CoreGraphics
import Foundation

/// 用紙の向き
public enum PaperOrientation: String, Codable, CaseIterable, Identifiable, Sendable {
    case portrait
    case landscape

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .portrait: return "A4 縦"
        case .landscape: return "A4 横"
        }
    }
}

/// 利用者が指定するレイアウト設定（次回起動時にも引き継ぐ）
public struct LayoutSettings: Codable, Equatable, Sendable {
    /// 横に並べる個数（列数）
    public var columns: Int
    /// 縦に並べる個数（行数）
    public var rows: Int
    public var orientation: PaperOrientation
    /// 用紙の余白（上下左右共通、mm）
    public var marginMM: Double
    /// 画像同士の間隔（縦横共通、mm）
    public var spacingMM: Double
    /// ファイル名の文字サイズ（pt）
    public var fontSize: Double

    public init(columns: Int, rows: Int, orientation: PaperOrientation,
                marginMM: Double, spacingMM: Double, fontSize: Double) {
        self.columns = columns
        self.rows = rows
        self.orientation = orientation
        self.marginMM = marginMM
        self.spacingMM = spacingMM
        self.fontSize = fontSize
    }

    /// 初期値：A4縦・横4個×縦5個・余白10mm・間隔4mm・文字8pt
    public static let standard = LayoutSettings(columns: 4, rows: 5, orientation: .portrait,
                                                marginMM: 10, spacingMM: 4, fontSize: 8)

    public static let countRange = 1...30
    public static let marginRange: ClosedRange<Double> = 0...50
    public static let spacingRange: ClosedRange<Double> = 0...30
    public static let fontSizeRange: ClosedRange<Double> = 5...16

    public var imagesPerPage: Int { columns * rows }

    /// 入力範囲外の値を範囲内に収める（mm は0.1単位、文字サイズは0.5単位）
    public func clamped() -> LayoutSettings {
        func clamp<T: Comparable>(_ value: T, _ range: ClosedRange<T>) -> T {
            min(max(value, range.lowerBound), range.upperBound)
        }
        func finite(_ value: Double, _ fallback: Double) -> Double { value.isFinite ? value : fallback }
        let base = LayoutSettings.standard
        var s = self
        s.columns = clamp(columns, Self.countRange)
        s.rows = clamp(rows, Self.countRange)
        s.marginMM = (clamp(finite(marginMM, base.marginMM), Self.marginRange) * 10).rounded() / 10
        s.spacingMM = (clamp(finite(spacingMM, base.spacingMM), Self.spacingRange) * 10).rounded() / 10
        s.fontSize = (clamp(finite(fontSize, base.fontSize), Self.fontSizeRange) * 2).rounded() / 2
        return s
    }
}

public enum Units {
    public static func points(fromMM mm: Double) -> CGFloat { CGFloat(mm * 72.0 / 25.4) }
    public static func mm(fromPoints points: CGFloat) -> Double { Double(points) * 25.4 / 72.0 }

    /// 「12.5」「12」のように小数点以下1桁まで表示する
    public static func format(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded)
    }
}
