import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 対応する画像形式
public enum ImageFormats {
    public static let supportedTypeIdentifiers: Set<String> = [
        "public.jpeg", "public.png", "public.heic", "public.heif", "public.tiff",
    ]
    public static let supportedDescription = "JPEG、PNG、HEIC、TIFF"
    public static let openPanelTypes: [UTType] = [.jpeg, .png, .heic, .heif, .tiff]

    public static func isSupported(typeIdentifier: String) -> Bool {
        supportedTypeIdentifiers.contains(typeIdentifier)
    }

    public static func displayName(typeIdentifier: String) -> String {
        switch typeIdentifier {
        case "public.jpeg": return "JPEG"
        case "public.png": return "PNG"
        case "public.heic": return "HEIC"
        case "public.heif": return "HEIF"
        case "public.tiff": return "TIFF"
        default:
            if let type = UTType(typeIdentifier) {
                if let ext = type.preferredFilenameExtension { return ext.uppercased() }
                if let description = type.localizedDescription { return description }
            }
            return typeIdentifier
        }
    }
}

/// 取り込んだ画像の情報
public struct ImageInfo: @unchecked Sendable {
    public let url: URL
    /// 表示用のファイル名（拡張子を含む。濁点などは合成済みの形にそろえる）
    public let fileName: String
    /// 向き情報を反映した後のピクセル数
    public let pixelSize: CGSize
    public let formatName: String
    /// 一覧表示用の小さな画像
    public let thumbnail: CGImage?
}

/// 取り込めなかったファイルと理由
public struct ImportFailure: Error, Sendable {
    public let url: URL
    public let fileName: String
    public let reason: String
}

public enum ImageLoadError: LocalizedError {
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "「\(name)」を読み込めません。"
        }
    }
}

/// 画像の読み込み（ImageIO を使い、元ファイルは読み取るだけで変更しない）
public enum ImageLoader {
    private static let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary

    /// 表示用のファイル名。macOS のファイル名は濁点が分解された形のことがあるため、合成済みの形にそろえる。
    public static func displayName(for url: URL) -> String {
        let name = url.lastPathComponent.precomposedStringWithCanonicalMapping
        // 改行などの制御文字は1行で表示できないため空白に置き換える
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            scalars.append(scalar.properties.generalCategory == .control ? " " : scalar)
        }
        return String(scalars)
    }

    /// 画像として読み込めるか確認し、大きさ・向き・一覧用の小さな画像を取得する
    public static func inspect(_ url: URL, thumbnailMaxPixel: Int = 160) -> Result<ImageInfo, ImportFailure> {
        let name = displayName(for: url)
        func fail(_ reason: String) -> Result<ImageInfo, ImportFailure> {
            .failure(ImportFailure(url: url, fileName: name, reason: reason))
        }
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return fail("ファイルが見つかりません。")
        }
        if isDirectory.boolValue {
            return fail("フォルダやパッケージは画像として追加できません。")
        }
        guard fileManager.isReadableFile(atPath: url.path) else {
            return fail("ファイルを読み取る権限がありません。")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              let type = CGImageSourceGetType(source) as String? else {
            return fail(unrecognizedReason(for: url))
        }
        guard ImageFormats.isSupported(typeIdentifier: type) else {
            return fail("対応していない形式です（\(ImageFormats.displayName(typeIdentifier: type))）。\(ImageFormats.supportedDescription)の画像を追加できます。")
        }
        let brokenReason = "画像データを読み込めません。ファイルが壊れている可能性があります。"
        guard CGImageSourceGetCount(source) > 0 else { return fail(brokenReason) }
        if ImageIntegrity.isTruncated(url, typeIdentifier: type) {
            return fail("画像データが途中で終わっています。ファイルが壊れているか、コピーが完了していない可能性があります。")
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let pixelSize = orientedPixelSize(source: source, index: index) else { return fail(brokenReason) }
        guard let thumbnail = makeImage(source: source, index: index, maxPixel: thumbnailMaxPixel) else {
            return fail(brokenReason)
        }
        return .success(ImageInfo(url: url, fileName: name, pixelSize: pixelSize,
                                  formatName: ImageFormats.displayName(typeIdentifier: type),
                                  thumbnail: thumbnail))
    }

    private static func unrecognizedReason(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
            if ImageFormats.isSupported(typeIdentifier: type.identifier) {
                return "画像として読み込めません。ファイルが壊れているか、内容が拡張子と一致していない可能性があります。"
            }
            return "対応していない形式です（\(ImageFormats.displayName(typeIdentifier: type.identifier))）。\(ImageFormats.supportedDescription)の画像を追加できます。"
        }
        return "画像ファイルではありません。\(ImageFormats.supportedDescription)の画像を追加できます。"
    }

    /// 向き情報（Exif Orientation）を反映した後のピクセル数
    static func orientedPixelSize(source: CGImageSource, index: Int) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// 向き情報を反映し、長辺を maxPixel 以下に縮小した画像（元より大きくはしない）
    static func makeImage(source: CGImageSource, index: Int, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    /// PDFに配置する画像を作る。白い背景に合成し（透過部分は白になる）、JPEGで圧縮したデータを返す。
    public static func renderJPEGData(url: URL, maxPixel: Int, quality: CGFloat) throws -> Data {
        let name = displayName(for: url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              CGImageSourceGetCount(source) > 0 else { throw ImageLoadError.unreadable(name) }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let image = makeImage(source: source, index: index, maxPixel: maxPixel),
              let flattened = flattenOnWhite(image) else { throw ImageLoadError.unreadable(name) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImageLoadError.unreadable(name)
        }
        CGImageDestinationAddImage(destination, flattened,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageLoadError.unreadable(name) }
        return data as Data
    }

    /// JPEGデータから画像を作る。JPEGのまま保持されるため、PDFにもJPEG圧縮のまま埋め込まれる。
    public static func image(fromJPEG data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 白い背景の上に描いた不透明な画像にする（元画像のRGB色空間を保つ。扱えない場合は sRGB）
    static func flattenOnWhite(_ image: CGImage) -> CGImage? {
        var spaces: [CGColorSpace] = []
        if let space = image.colorSpace, space.model == .rgb { spaces.append(space) }
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB) { spaces.append(srgb) }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        for space in spaces {
            guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(rect)
            context.interpolationQuality = .high
            context.draw(image, in: rect)
            if let result = context.makeImage() { return result }
        }
        return nil
    }
}
