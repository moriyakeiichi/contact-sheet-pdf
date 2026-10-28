// 動作確認ツール：テスト画像を作り、アプリと同じ処理でPDFを作って中身を検証する。
//   使い方: sheetcheck 作業フォルダ [--perf 枚数]
import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ImageIO
import ImageSheetCore
import PDFKit
import UniformTypeIdentifiers

// MARK: - 結果の記録

var passCount = 0
var failCount = 0
var reportLines: [String] = []

func log(_ text: String) {
    print(text)
    reportLines.append(text)
}

func check(_ condition: Bool, _ title: String, _ detail: @autoclosure () -> String = "") {
    if condition {
        passCount += 1
        log("  [OK] \(title)")
    } else {
        failCount += 1
        let extra = detail()
        log("  [NG] \(title)\(extra.isEmpty ? "" : " … \(extra)")")
    }
}

func section(_ title: String) {
    log("")
    log("■ \(title)")
}

// MARK: - テスト画像の作成

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [r, g, b, a])!
}

func makeImage(width: Int, height: Int, alpha: Bool = false, draw: (CGContext, CGRect) -> Void) -> CGImage {
    let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: srgb, bitmapInfo: info)!
    draw(context, CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

/// 全面を塗った画像（上1/4が赤、下1/4が青、中央は指定色）。向きと欠けの確認に使う。
func bandedImage(width: Int, height: Int, middle: CGColor) -> CGImage {
    makeImage(width: width, height: height) { context, rect in
        context.setFillColor(middle)
        context.fill(rect)
        context.setFillColor(rgb(0.9, 0.1, 0.1))
        context.fill(CGRect(x: 0, y: rect.height * 0.75, width: rect.width, height: rect.height * 0.25))
        context.setFillColor(rgb(0.1, 0.2, 0.9))
        context.fill(CGRect(x: 0, y: 0, width: rect.width, height: rect.height * 0.25))
    }
}

func write(_ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any] = [:]) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    precondition(CGImageDestinationFinalize(destination), "画像を書き出せません: \(url.path)")
}

struct TestImage {
    let name: String
    let expectedSize: CGSize
    /// 全面が塗られている（白い部分がない）画像
    let fullyPainted: Bool
}

func createTestImages(in folder: URL) -> (valid: [TestImage], invalid: [String]) {
    try? FileManager.default.removeItem(at: folder)
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var valid: [TestImage] = []
    func add(_ name: String, _ image: CGImage, _ type: UTType, size: CGSize? = nil,
             painted: Bool = true, properties: [CFString: Any] = [:]) {
        write(image, to: folder.appendingPathComponent(name), type: type, properties: properties)
        valid.append(TestImage(name: name, expectedSize: size ?? CGSize(width: image.width, height: image.height),
                               fullyPainted: painted))
    }
    let gray = rgb(0.55, 0.55, 0.55)
    // 自然な順序の確認用
    add("1.jpg", bandedImage(width: 1600, height: 1200, middle: gray), .jpeg)
    add("2.jpg", bandedImage(width: 1600, height: 1200, middle: gray), .jpeg)
    add("10.jpg", bandedImage(width: 1600, height: 1200, middle: gray), .jpeg)
    // 縦長・横長
    add("縦長_portrait.jpg", bandedImage(width: 1200, height: 1800, middle: rgb(0.3, 0.7, 0.3)), .jpeg)
    add("横長_wide_panorama.png", bandedImage(width: 3000, height: 1000, middle: rgb(0.8, 0.6, 0.2)), .png)
    // 向き情報（Exif Orientation 6）：保存されている画素は横長で、正しく表示すると縦長・上が赤
    let rotated = makeImage(width: 1800, height: 1200) { context, rect in
        context.setFillColor(rgb(0.4, 0.4, 0.7))
        context.fill(rect)
        context.setFillColor(rgb(0.9, 0.1, 0.1))   // 保存上の左端 → 表示上の上端
        context.fill(CGRect(x: 0, y: 0, width: rect.width * 0.25, height: rect.height))
        context.setFillColor(rgb(0.1, 0.2, 0.9))   // 保存上の右端 → 表示上の下端
        context.fill(CGRect(x: rect.width * 0.75, y: 0, width: rect.width * 0.25, height: rect.height))
    }
    add("向き情報あり_orientation6.jpg", rotated, .jpeg, size: CGSize(width: 1200, height: 1800),
        properties: [kCGImagePropertyOrientation: 6])
    // 透過PNG：周囲が透明、中央に緑の円
    let transparent = makeImage(width: 1000, height: 1000, alpha: true) { context, rect in
        context.clear(rect)
        context.setFillColor(rgb(0.1, 0.7, 0.3))
        context.fillEllipse(in: rect.insetBy(dx: 250, dy: 250))
    }
    add("透過_transparent.png", transparent, .png, painted: false)
    add("写真_HEIC形式.heic", bandedImage(width: 1600, height: 1200, middle: rgb(0.6, 0.3, 0.6)), .heic)
    add("スキャン_TIFF形式.tiff", bandedImage(width: 1000, height: 1400, middle: rgb(0.3, 0.6, 0.7)), .tiff)
    // 日本語・記号・長い名前
    add("日本語のファイル名　全角スペースと記号（テスト）①.png",
        bandedImage(width: 1200, height: 900, middle: rgb(0.7, 0.5, 0.4)), .png)
    let decomposed = "がぎぐげご_濁点の名前.jpg".decomposedStringWithCanonicalMapping
    add(decomposed, bandedImage(width: 900, height: 1200, middle: rgb(0.5, 0.5, 0.8)), .jpeg)
    add("very_long_file_name_for_testing_wrap_and_middle_truncation_of_labels_in_the_contact_sheet_0123456789.jpeg",
        bandedImage(width: 1400, height: 1000, middle: rgb(0.6, 0.6, 0.3)), .jpeg)
    add("とても長い日本語のファイル名を持つ画像で折り返しと中間省略が正しく動作するかを確認するためのテスト用画像ファイルです.png",
        bandedImage(width: 1000, height: 1000, middle: rgb(0.4, 0.6, 0.5)), .png)
    add("Symbols #&%@!+=~^[]{}(),;' & more.jpg", bandedImage(width: 1200, height: 800, middle: gray), .jpeg)
    add("絵文字😀入り_emoji.png", bandedImage(width: 800, height: 800, middle: rgb(0.8, 0.4, 0.4)), .png)
    for n in 16...21 {
        add(String(format: "IMG_%04d.jpg", n), bandedImage(width: 1200, height: 900, middle: gray), .jpeg)
    }

    // 読み込めない・対応していないファイル
    var invalid: [String] = []
    let broken = folder.appendingPathComponent("壊れた画像.jpg")
    var bytes = [UInt8](repeating: 0, count: 4096)
    for i in bytes.indices { bytes[i] = UInt8((i * 7919) % 251) }
    try! Data(bytes).write(to: broken)
    invalid.append(broken.lastPathComponent)

    let gif = folder.appendingPathComponent("アニメ.gif")
    write(bandedImage(width: 200, height: 200, middle: gray), to: gif, type: .gif)
    invalid.append(gif.lastPathComponent)

    let text = folder.appendingPathComponent("メモ.txt")
    try! "テキスト".write(to: text, atomically: true, encoding: .utf8)
    invalid.append(text.lastPathComponent)

    // 途中で切れたJPEG
    let full = try! Data(contentsOf: folder.appendingPathComponent("1.jpg"))
    let truncated = folder.appendingPathComponent("途中で切れた画像.jpg")
    try! full.prefix(full.count / 3).write(to: truncated)
    invalid.append(truncated.lastPathComponent)

    // 途中で切れたPNG
    let fullPNG = try! Data(contentsOf: folder.appendingPathComponent("横長_wide_panorama.png"))
    let truncatedPNG = folder.appendingPathComponent("途中で切れた画像.png")
    try! fullPNG.prefix(fullPNG.count / 2).write(to: truncatedPNG)
    invalid.append(truncatedPNG.lastPathComponent)
    return (valid, invalid)
}

/// 正常なのに「途中で切れた」と誤判定しやすい画像
func createEdgeCases(in folder: URL) -> [String] {
    try? FileManager.default.removeItem(at: folder)
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let image = bandedImage(width: 1600, height: 1200, middle: rgb(0.5, 0.6, 0.4))
    let progressive = folder.appendingPathComponent("プログレッシブJPEG.jpg")
    write(image, to: progressive, type: .jpeg,
          properties: [kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: true]])
    // 動画付き写真のように、JPEGの終端の後ろに別のデータが付いたもの
    let trailing = folder.appendingPathComponent("末尾に追加データ.jpg")
    var data = try! Data(contentsOf: progressive)
    data.append(Data((0..<50_000).map { UInt8($0 % 253) }))
    try! data.write(to: trailing)
    let sixteenBit = folder.appendingPathComponent("16bit_透過.png")
    let context = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 16, bytesPerRow: 0, space: srgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
    context.setFillColor(rgb(0.2, 0.4, 0.8, 0.5))
    context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
    write(context.makeImage()!, to: sixteenBit, type: .png)
    return [progressive.lastPathComponent, trailing.lastPathComponent, sixteenBit.lastPathComponent]
}

// MARK: - ファイルの指紋（元画像が変わっていないことの確認）

struct Fingerprint: Equatable {
    let hash: String
    let size: Int
    let modified: Date
}

func fingerprints(of folder: URL) -> [String: Fingerprint] {
    var result: [String: Fingerprint] = [:]
    let files = try! FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    for file in files {
        let data = try! Data(contentsOf: file)
        let attributes = try! FileManager.default.attributesOfItem(atPath: file.path)
        result[file.lastPathComponent] = Fingerprint(
            hash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            size: data.count, modified: attributes[.modificationDate] as! Date)
    }
    return result
}

// MARK: - PDFの画素を調べる

struct Raster {
    let width: Int
    let height: Int
    let scale: CGFloat
    let pixels: [UInt8]

    /// 用紙の左上原点・ポイント単位の位置の色
    func color(atPoint point: CGPoint) -> (r: Int, g: Int, b: Int) {
        let x = min(max(Int(point.x * scale), 0), width - 1)
        let y = min(max(Int(point.y * scale), 0), height - 1)
        let offset = (y * width + x) * 4
        return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
    }

    func isWhite(x: Int, y: Int) -> Bool {
        let offset = (y * width + x) * 4
        return pixels[offset] > 240 && pixels[offset + 1] > 240 && pixels[offset + 2] > 240
    }

    /// 指定範囲内で白でない画素を囲む矩形（ポイント単位）
    func paintedBounds(in rect: CGRect) -> CGRect? {
        let x0 = max(Int(rect.minX * scale), 0), x1 = min(Int(rect.maxX * scale), width - 1)
        let y0 = max(Int(rect.minY * scale), 0), y1 = min(Int(rect.maxY * scale), height - 1)
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in y0...y1 {
            for x in x0...x1 where !isWhite(x: x, y: y) {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard minX <= maxX else { return nil }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }
}

func rasterize(_ page: CGPDFPage, scale: CGFloat) -> Raster {
    let box = page.getBoxRect(.mediaBox)
    let width = Int(box.width * scale), height = Int(box.height * scale)
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: srgb,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(rgb(1, 1, 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.drawPDFPage(page)
    }
    return Raster(width: width, height: height, scale: scale, pixels: pixels)
}

func cgPage(_ url: URL, _ index: Int) -> CGPDFPage? {
    CGPDFDocument(url as CFURL)?.page(at: index + 1)
}

func cgPage(data: Data) -> CGPDFPage? {
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    return CGPDFDocument(provider)?.page(at: 1)
}

func compact(_ text: String) -> String {
    text.components(separatedBy: .whitespacesAndNewlines).joined()
}

/// PDFのファイル名の領域から文字を取り出す
func textInRect(_ page: PDFPage, _ rect: CGRect, pageHeight: CGFloat) -> String {
    let pdfRect = CGRect(x: rect.minX, y: pageHeight - rect.maxY, width: rect.width, height: rect.height)
    return compact(page.selection(for: pdfRect)?.string ?? "")
}

// MARK: - 実行

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("使い方: sheetcheck 作業フォルダ [--perf 枚数]")
    exit(2)
}
let workFolder = URL(fileURLWithPath: arguments[1], isDirectory: true)
let imageFolder = workFolder.appendingPathComponent("images", isDirectory: true)
let outputFolder = workFolder.appendingPathComponent("output", isDirectory: true)
try? FileManager.default.removeItem(at: outputFolder)
try! FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

log("画像一覧PDF 動作確認  \(Date())")
log("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

section("テスト画像の作成")
let (testImages, invalidNames) = createTestImages(in: imageFolder)
log("  有効な画像 \(testImages.count)枚、読み込めないはずのファイル \(invalidNames.count)件")
let originalFingerprints = fingerprints(of: imageFolder)

section("取り込み（対応形式・読み込めないファイル・重複）")
let allFiles = try! FileManager.default.contentsOfDirectory(at: imageFolder, includingPropertiesForKeys: nil)
var inspected: [String: ImageInfo] = [:]
var failures: [String: String] = [:]
for file in allFiles {
    switch ImageLoader.inspect(file) {
    case .success(let info): inspected[info.fileName] = info
    case .failure(let failure): failures[failure.fileName] = failure.reason
    }
}
check(inspected.count == testImages.count, "有効な画像を\(testImages.count)枚すべて取り込める", "取り込めた数 \(inspected.count)")
for name in invalidNames {
    let reason = failures[name.precomposedStringWithCanonicalMapping]
    check(reason != nil, "「\(name)」は理由付きで除外される", "除外されなかった")
    if let reason { log("       理由: \(reason)") }
}
for test in testImages {
    let name = test.name.precomposedStringWithCanonicalMapping
    guard let info = inspected[name] else {
        check(false, "「\(name)」を取り込める", failures[name] ?? "")
        continue
    }
    if test.name.contains("orientation6") || test.name.contains("縦長") || test.name.contains("横長") {
        check(info.pixelSize == test.expectedSize, "「\(name)」の大きさ（向き反映後）が \(Int(test.expectedSize.width))×\(Int(test.expectedSize.height))",
              "実際 \(info.pixelSize)")
    }
}
let formats = Set(inspected.values.map(\.formatName))
check(formats.isSuperset(of: ["JPEG", "PNG", "HEIC", "TIFF"]), "JPEG・PNG・HEIC・TIFFを読み込める", "\(formats)")
check(inspected.keys.contains("がぎぐげご_濁点の名前.jpg"), "濁点が分解された名前も合成済みの名前で表示する")

// 重複（同じファイル・シンボリックリンク）
let link = workFolder.appendingPathComponent("link_to_1.jpg")
try? FileManager.default.removeItem(at: link)
try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: imageFolder.appendingPathComponent("1.jpg"))
let firstPlan = ImportPlan.make(from: [imageFolder.appendingPathComponent("1.jpg")], excluding: [])
let secondPlan = ImportPlan.make(from: [imageFolder.appendingPathComponent("1.jpg"), link,
                                        imageFolder.appendingPathComponent("2.jpg")],
                                 excluding: Set(firstPlan.keys))
check(secondPlan.files.count == 1 && secondPlan.duplicateCount == 2,
      "同じファイル（別名を含む）を重複して追加しない", "追加 \(secondPlan.files.count)、重複 \(secondPlan.duplicateCount)")
let folderPlan = ImportPlan.make(from: [imageFolder], excluding: [])
let edgeFolder = workFolder.appendingPathComponent("edge", isDirectory: true)
for name in createEdgeCases(in: edgeFolder) {
    let result = ImageLoader.inspect(edgeFolder.appendingPathComponent(name))
    if case .failure(let failure) = result {
        check(false, "「\(name)」（正常な画像）を取り込める", failure.reason)
    } else {
        check(true, "「\(name)」（正常な画像）を取り込める")
    }
}
check(folderPlan.files.count == testImages.count + 4 && folderPlan.skippedNonImages == 1,
      "フォルダをドロップすると中の画像を対象にし、画像以外は件数を数える",
      "対象 \(folderPlan.files.count)、画像以外 \(folderPlan.skippedNonImages)")

section("並び順（ファイル名の自然な順序）")
var entries: [SheetEntry] = inspected.values
    .sorted { FileNameOrder.precedes(name: $0.fileName, path: $0.url.path, name: $1.fileName, path: $1.url.path) }
    .map { SheetEntry(id: UUID(), url: $0.url, fileName: $0.fileName, pixelSize: $0.pixelSize) }
let order = entries.map(\.fileName)
log("  並び: " + order.prefix(6).joined(separator: " / ") + " …")
if let i1 = order.firstIndex(of: "1.jpg"), let i2 = order.firstIndex(of: "2.jpg"), let i10 = order.firstIndex(of: "10.jpg") {
    check(i1 < i2 && i2 < i10, "1.jpg → 2.jpg → 10.jpg の順になる")
} else {
    check(false, "1.jpg・2.jpg・10.jpg が一覧にある")
}
check(order.firstIndex(of: "IMG_0016.jpg")! < order.firstIndex(of: "IMG_0021.jpg")!, "IMG_0016 → IMG_0021 の順になる")

section("レイアウト（横4個・縦5個・A4縦、画像21枚）")
let settings = LayoutSettings.standard
let layout = SheetLayout(settings: settings)
check(layout.isValid, "初期設定で配置できる", layout.problem ?? "")
check(entries.count == 21, "画像は21枚", "\(entries.count)枚")
check(layout.pageCount(forImageCount: 21) == 2, "21枚は2ページになる")
let renderer = SheetRenderer(layout: layout)
let page0 = renderer.placements(page: 0, entries: entries)
let page1 = renderer.placements(page: 1, entries: entries)
check(page0.count == 20 && page1.count == 1, "1ページ目20枚・2ページ目1枚", "\(page0.count)枚・\(page1.count)枚")
check(page1.first?.cellRect == layout.cellRect(slot: 0) && page1.first?.cellRect.size == page0.first?.cellRect.size,
      "最後のページの1枚も同じ大きさで左上に置く")
check(page0[1].cellRect.minX > page0[0].cellRect.minX && page0[4].cellRect.minY > page0[3].cellRect.minY,
      "左から右、上から下の順に置く")
log("  1マス: \(Units.format(Units.mm(fromPoints: layout.cellSize.width)))×\(Units.format(Units.mm(fromPoints: layout.cellSize.height)))mm、画像部分の高さ \(Units.format(Units.mm(fromPoints: layout.imageAreaHeight)))mm")

var geometryOK = true
var geometryDetail = ""
let allPlacements = page0 + page1
for placement in allPlacements {
    let entry = entries[placement.index]
    let area = layout.imageAreaRect(slot: placement.slot)
    let expected = entry.pixelSize.width / entry.pixelSize.height
    let actual = placement.imageRect.width / placement.imageRect.height
    if abs(expected - actual) / expected > 1e-6 { geometryOK = false; geometryDetail += "縦横比:\(entry.fileName) " }
    if !area.insetBy(dx: -0.001, dy: -0.001).contains(placement.imageRect) { geometryOK = false; geometryDetail += "はみ出し:\(entry.fileName) " }
    if !placement.cellRect.insetBy(dx: -0.001, dy: -0.001).contains(placement.textRect) { geometryOK = false; geometryDetail += "文字欄:\(entry.fileName) " }
    if placement.textRect.minY < placement.imageRect.maxY { geometryOK = false; geometryDetail += "文字と画像が重なる:\(entry.fileName) " }
    if placement.label.lines.count > SheetLayout.labelLineCount { geometryOK = false; geometryDetail += "行数:\(entry.fileName) " }
    if placement.label.lineWidths.contains(where: { $0 > placement.textRect.width + 0.01 }) { geometryOK = false; geometryDetail += "行幅:\(entry.fileName) " }
}
for a in page0 {
    for b in page0 where a.slot != b.slot {
        if a.textRect.intersects(b.cellRect) || a.imageRect.intersects(b.cellRect) {
            geometryOK = false; geometryDetail += "隣と重なる:\(a.slot)-\(b.slot) "
        }
    }
}
check(geometryOK, "全マスで縦横比を保ち、画像・ファイル名がマス内に収まり重ならない", geometryDetail)

section("ファイル名の折り返しと省略")
for placement in allPlacements where placement.label.isTruncated || placement.label.lines.count > 1 {
    let name = entries[placement.index].fileName
    log("  \(placement.label.isTruncated ? "省略" : "折返")（\(placement.label.lines.count)行）: \(placement.label.text)")
    if placement.label.isTruncated {
        let ext = LabelTypesetter.splitExtension(name).ext
        check(placement.label.text.hasSuffix(ext) && placement.label.text.contains("…"),
              "省略しても拡張子「\(ext)」を残す: \(name.prefix(24))…")
    }
}
check(allPlacements.contains { $0.label.isTruncated }, "長いファイル名は省略される（テストに含まれている）")
/// 拡張子が「.j」「pg」のように2行に分かれていないか（3種類のレイアウトで確認）
var splitExtensions: [String] = []
for variant in [(4, 5, PaperOrientation.portrait, 8.0), (6, 3, .landscape, 9.0), (6, 8, .portrait, 6.0)] {
    var s = LayoutSettings.standard
    (s.columns, s.rows, s.orientation, s.fontSize) = variant
    let r = SheetRenderer(layout: SheetLayout(settings: s))
    for page in 0..<2 {
        for p in r.placements(page: page, entries: entries) where p.label.lines.count == 2 {
            let range = CTLineGetStringRange(p.label.lines[1])
            let lastLine = (p.label.text as NSString).substring(with: NSRange(location: range.location, length: range.length))
            let ext = LabelTypesetter.splitExtension(p.label.text).ext
            if !ext.isEmpty && !lastLine.hasSuffix(ext) { splitExtensions.append(p.label.text) }
        }
    }
}
check(splitExtensions.isEmpty, "折り返しても拡張子は行の途中で分かれない（3種類のレイアウト）", "\(splitExtensions)")
check(allPlacements.contains { !$0.label.isTruncated && $0.label.lines.count == 2 }, "収まる名前は2行に折り返して全文を表示する")

section("PDFの保存と内容")
let pdfURL = outputFolder.appendingPathComponent("確認用_4x5_21枚.pdf")
let exportStart = Date()
var exportProgress: [Int] = []
do {
    try PDFExporter.export(entries: entries, layout: layout, to: pdfURL, progress: { done, _ in exportProgress.append(done) })
    check(true, "PDFを保存できる（\(String(format: "%.2f", Date().timeIntervalSince(exportStart)))秒）")
} catch {
    check(false, "PDFを保存できる", error.localizedDescription)
}
check(exportProgress == [1, 2], "進行状況をページごとに通知する", "\(exportProgress)")
let pdfDocument = PDFDocument(url: pdfURL)!
check(pdfDocument.pageCount == 2, "保存したPDFは2ページ", "\(pdfDocument.pageCount)ページ")
let pdfSize = (try? FileManager.default.attributesOfItem(atPath: pdfURL.path)[.size] as? Int) ?? 0
log("  ファイルサイズ: \(pdfSize / 1024)KB")
let rawPDF = try! Data(contentsOf: pdfURL)
let rawText = String(decoding: rawPDF, as: UTF8.self)
check(rawText.contains("/DCTDecode"), "画像はJPEG圧縮で埋め込まれている（PDFが大きくなりすぎない）")
let mediaBox = pdfDocument.page(at: 0)!.bounds(for: .mediaBox)
check(abs(mediaBox.width - 595.28) < 0.5 && abs(mediaBox.height - 841.89) < 0.5, "用紙はA4縦（595×842pt）",
      "\(mediaBox.size)")

// 文字として検索・選択できるか
var textOK = true
var textDetail = ""
for (pageIndex, placements) in [page0, page1].enumerated() {
    let page = pdfDocument.page(at: pageIndex)!
    for placement in placements {
        let extracted = textInRect(page, placement.textRect, pageHeight: layout.pageSize.height)
        if extracted != compact(placement.label.text) {
            textOK = false
            textDetail += "\n       期待「\(placement.label.text)」 実際「\(extracted)」"
        }
    }
}
check(textOK, "全21件のファイル名がPDF内の文字として各マスの位置から取り出せる", textDetail)
check(pdfDocument.page(at: 1)!.string.map(compact) == compact(page1[0].label.text), "2ページ目には21枚目の名前だけがある")
check(!pdfDocument.findString("日本語のファイル名", withOptions: []).isEmpty, "日本語のファイル名を検索できる")
check(!pdfDocument.findString("がぎぐげご", withOptions: []).isEmpty, "濁点を含む名前を合成済みの文字で検索できる")
check(!pdfDocument.findString("#&%@!+=~^[]{}", withOptions: []).isEmpty, "記号を含む名前を検索できる")

// 画素の確認（2倍の解像度で描いて調べる）
let raster0 = rasterize(cgPage(pdfURL, 0)!, scale: 2)
var paintOK = true
var paintDetail = ""
for placement in page0 {
    let entry = entries[placement.index]
    guard let test = testImages.first(where: { $0.name.precomposedStringWithCanonicalMapping == entry.fileName }),
          test.fullyPainted else { continue }
    guard let painted = raster0.paintedBounds(in: layout.imageAreaRect(slot: placement.slot)) else {
        paintOK = false; paintDetail += " \(entry.fileName):描かれていない"; continue
    }
    let tolerance: CGFloat = 1.0
    if abs(painted.minX - placement.imageRect.minX) > tolerance || abs(painted.maxX - placement.imageRect.maxX) > tolerance
        || abs(painted.minY - placement.imageRect.minY) > tolerance || abs(painted.maxY - placement.imageRect.maxY) > tolerance {
        paintOK = false
        paintDetail += " \(entry.fileName): 期待\(placement.imageRect.integral) 実際\(painted.integral)"
    }
}
check(paintOK, "実際に描かれた画像の範囲が計算どおり（欠け・変形なし、誤差1pt以内）", paintDetail)

func placement(named name: String) -> CellPlacement? {
    allPlacements.first { entries[$0.index].fileName == name }
}
if let p = placement(named: "向き情報あり_orientation6.jpg") {
    let top = raster0.color(atPoint: CGPoint(x: p.imageRect.midX, y: p.imageRect.minY + p.imageRect.height * 0.1))
    let bottom = raster0.color(atPoint: CGPoint(x: p.imageRect.midX, y: p.imageRect.maxY - p.imageRect.height * 0.1))
    check(p.imageRect.height > p.imageRect.width, "向き情報を反映して縦長に配置する")
    check(top.r > 180 && top.b < 80 && bottom.b > 180 && bottom.r < 80, "向き情報を反映して上が赤・下が青で表示される",
          "上\(top) 下\(bottom)")
}
for name in ["縦長_portrait.jpg", "横長_wide_panorama.png"] {
    if let p = placement(named: name) {
        let top = raster0.color(atPoint: CGPoint(x: p.imageRect.midX, y: p.imageRect.minY + p.imageRect.height * 0.1))
        check(top.r > 180 && top.b < 80, "「\(name)」が上下正しく表示される", "上\(top)")
    }
}
if let p = placement(named: "透過_transparent.png") {
    let corner = raster0.color(atPoint: CGPoint(x: p.imageRect.minX + 4, y: p.imageRect.minY + 4))
    let center = raster0.color(atPoint: CGPoint(x: p.imageRect.midX, y: p.imageRect.midY))
    check(corner.r > 245 && corner.g > 245 && corner.b > 245, "透過部分は白背景になる", "\(corner)")
    check(center.g > 120 && center.r < 100, "透過画像の中身（緑の円）は表示される", "\(center)")
}
let pageCorner = raster0.color(atPoint: CGPoint(x: 2, y: 2))
check(pageCorner == (255, 255, 255), "ページ背景は白", "\(pageCorner)")

section("並べ替えた順番の反映")
var reordered = entries
let moved = reordered.removeLast()
reordered.insert(moved, at: 0)
let reorderedURL = outputFolder.appendingPathComponent("確認用_並べ替え.pdf")
try! PDFExporter.export(entries: reordered, layout: layout, to: reorderedURL)
let reorderedDocument = PDFDocument(url: reorderedURL)!
let reorderedPlacements = renderer.placements(page: 0, entries: reordered)
let firstCellText = textInRect(reorderedDocument.page(at: 0)!, reorderedPlacements[0].textRect, pageHeight: layout.pageSize.height)
check(firstCellText == compact(reorderedPlacements[0].label.text) && reorderedPlacements[0].index == 0
      && reordered[0].fileName == moved.fileName,
      "最後の画像を先頭に移すと、PDFの1マス目がその画像になる", "1マス目「\(firstCellText)」")
let secondPageText = compact(reorderedDocument.page(at: 1)!.string ?? "")
check(secondPageText == compact(renderer.placements(page: 1, entries: reordered)[0].label.text),
      "押し出された画像が2ページ目に移る", secondPageText)

section("プレビューと保存PDFの一致")
let cache = PreviewImageCache()
var previewMatches = true
var previewDetail = ""
for pageIndex in 0..<2 {
    let preview = PreviewBuilder.renderPage(pageIndex, entries: entries, layout: layout, cache: cache)
    let previewPage = cgPage(data: preview.pdfData)!
    check(previewPage.getBoxRect(.mediaBox) == cgPage(pdfURL, pageIndex)!.getBoxRect(.mediaBox),
          "\(pageIndex + 1)ページ目：用紙の大きさが同じ")
    // 文字：各マスから取り出した名前が同じ
    let previewPDF = PDFDocument(data: preview.pdfData)!.page(at: 0)!
    let savedPDF = pdfDocument.page(at: pageIndex)!
    for p in renderer.placements(page: pageIndex, entries: entries) {
        let a = textInRect(previewPDF, p.textRect, pageHeight: layout.pageSize.height)
        let b = textInRect(savedPDF, p.textRect, pageHeight: layout.pageSize.height)
        if a != b { previewMatches = false; previewDetail += " [\(a)≠\(b)]" }
    }
    // 見た目：同じ解像度で描いて画素を比べる（違いは画像の解像度による細部のみのはず）
    let rp = rasterize(previewPage, scale: 1.5)
    let rs = rasterize(cgPage(pdfURL, pageIndex)!, scale: 1.5)
    var total = 0
    var largeDiff = 0
    for i in stride(from: 0, to: rp.pixels.count, by: 4) {
        let d = abs(Int(rp.pixels[i]) - Int(rs.pixels[i])) + abs(Int(rp.pixels[i + 1]) - Int(rs.pixels[i + 1]))
            + abs(Int(rp.pixels[i + 2]) - Int(rs.pixels[i + 2]))
        total += d
        if d > 96 { largeDiff += 1 }
    }
    let pixelCount = rp.pixels.count / 4
    let meanDiff = Double(total) / Double(pixelCount * 3)
    let largeRatio = Double(largeDiff) / Double(pixelCount)
    log("  \(pageIndex + 1)ページ目：画素の平均差 \(String(format: "%.3f", meanDiff))/255、大きく異なる画素 \(String(format: "%.3f", largeRatio * 100))%")
    check(meanDiff < 1.5 && largeRatio < 0.002, "\(pageIndex + 1)ページ目：見た目が一致する（配置・改ページ・文字）")
    // 白い部分（画像の有無・位置）が一致
    var whiteMismatch = 0
    for y in stride(from: 0, to: rp.height, by: 2) {
        for x in stride(from: 0, to: rp.width, by: 2) where rp.isWhite(x: x, y: y) != rs.isWhite(x: x, y: y) {
            whiteMismatch += 1
        }
    }
    check(Double(whiteMismatch) / Double(rp.width * rp.height / 4) < 0.002,
          "\(pageIndex + 1)ページ目：画像の位置と範囲が一致する", "不一致 \(whiteMismatch)")
}
check(previewMatches, "プレビューと保存PDFで各マスのファイル名が一致する", previewDetail)

section("保存の安全性（失敗・中止しても既存ファイルを壊さない）")
let existingURL = outputFolder.appendingPathComponent("既存のファイル.pdf")
try! PDFExporter.export(entries: Array(entries.prefix(3)), layout: layout, to: existingURL)
let existingHash = SHA256.hash(data: try! Data(contentsOf: existingURL))
// 1ページ目の途中で中止
var cancelAfterFirstPage = false
do {
    try PDFExporter.export(entries: entries, layout: layout, to: existingURL,
                           isCancelled: { cancelAfterFirstPage },
                           progress: { done, _ in if done >= 1 { cancelAfterFirstPage = true } })
    check(false, "中止すると保存しない")
} catch {
    check((error as? SheetError) == .cancelled, "途中で中止すると「中止」として扱う", "\(error)")
}
check(SHA256.hash(data: try! Data(contentsOf: existingURL)) == existingHash, "中止しても既存のPDFは元のまま")
// 画像が途中で見つからなくなった場合
let vanishing = imageFolder.appendingPathComponent("1.jpg")
let backup = workFolder.appendingPathComponent("1.jpg.backup")
try? FileManager.default.removeItem(at: backup)
try! FileManager.default.moveItem(at: vanishing, to: backup)
do {
    try PDFExporter.export(entries: entries, layout: layout, to: existingURL)
    check(false, "画像が見つからない場合は保存しない")
} catch {
    if case SheetError.imagesUnavailable(let names) = error {
        check(names == ["1.jpg"], "見つからない画像の名前を示して保存を中止する", "\(names)")
    } else {
        check(false, "見つからない画像の名前を示して保存を中止する", "\(error)")
    }
}
try! FileManager.default.moveItem(at: backup, to: vanishing)
check(SHA256.hash(data: try! Data(contentsOf: existingURL)) == existingHash, "失敗しても既存のPDFは元のまま")
// 書き込めないフォルダ
let lockedFolder = outputFolder.appendingPathComponent("書き込み禁止", isDirectory: true)
try! FileManager.default.createDirectory(at: lockedFolder, withIntermediateDirectories: true)
try! FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedFolder.path)
do {
    try PDFExporter.export(entries: entries, layout: layout, to: lockedFolder.appendingPathComponent("x.pdf"))
    check(false, "書き込めない場所ではエラーになる")
} catch {
    check(true, "書き込めない場所ではエラーになる（\(error.localizedDescription.prefix(40))…）")
}
let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: lockedFolder.path)) ?? []
check(leftovers.isEmpty, "書き込めない場所に不完全なファイルを残さない", "\(leftovers)")
try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedFolder.path)
let outputLeftovers = try! FileManager.default.contentsOfDirectory(atPath: outputFolder.path)
    .filter { !$0.hasSuffix(".pdf") && $0 != "書き込み禁止" }
check(outputLeftovers.isEmpty, "保存先に一時ファイルが残らない", "\(outputLeftovers)")

section("配置できない設定の検出")
var tooMany = LayoutSettings.standard
tooMany.columns = 30
let tooManyLayout = SheetLayout(settings: tooMany)
check(!tooManyLayout.isValid, "横30個は配置できないと判定する")
log("  理由: \(tooManyLayout.problem ?? "")")
var tooTall = LayoutSettings.standard
tooTall.rows = 30
tooTall.orientation = .landscape
let tooTallLayout = SheetLayout(settings: tooTall)
check(!tooTallLayout.isValid, "A4横で縦30個は配置できないと判定する")
log("  理由: \(tooTallLayout.problem ?? "")")
var hugeMargin = LayoutSettings.standard
hugeMargin.marginMM = 50
hugeMargin.columns = 8
check(!SheetLayout(settings: hugeMargin).isValid, "余白50mm・横8個は配置できないと判定する")
do {
    try PDFExporter.export(entries: entries, layout: tooManyLayout, to: outputFolder.appendingPathComponent("不可.pdf"))
    check(false, "配置できない設定では保存しない")
} catch {
    check(!FileManager.default.fileExists(atPath: outputFolder.appendingPathComponent("不可.pdf").path),
          "配置できない設定では保存しない")
}

section("ほかの設定での出力（目視確認用）")
var landscape = LayoutSettings.standard
landscape.orientation = .landscape
landscape.columns = 6
landscape.rows = 3
landscape.fontSize = 9
let landscapeURL = outputFolder.appendingPathComponent("確認用_A4横_6x3_9pt.pdf")
try! PDFExporter.export(entries: entries, layout: SheetLayout(settings: landscape), to: landscapeURL)
let landscapeDocument = PDFDocument(url: landscapeURL)!
check(landscapeDocument.pageCount == 2 && landscapeDocument.page(at: 0)!.bounds(for: .mediaBox).width > 800,
      "A4横・横6個×縦3個で2ページ（18枚＋3枚）")
var dense = LayoutSettings.standard
dense.columns = 6
dense.rows = 8
dense.fontSize = 6
let denseLayout = SheetLayout(settings: dense)
check(denseLayout.isValid, "横6個×縦8個・6ptでも配置できる", denseLayout.problem ?? "")
try! PDFExporter.export(entries: entries, layout: denseLayout, to: outputFolder.appendingPathComponent("確認用_A4縦_6x8_6pt.pdf"))
let previewSample = PreviewBuilder.renderPage(0, entries: entries, layout: layout, cache: cache)
try! previewSample.pdfData.write(to: outputFolder.appendingPathComponent("確認用_プレビュー1ページ目.pdf"))

section("元画像が変更されていないこと")
let afterFingerprints = fingerprints(of: imageFolder)
check(afterFingerprints == originalFingerprints, "全\(originalFingerprints.count)ファイルの内容・大きさ・更新日時が変わっていない")

// MARK: - 大量・大きな画像

if let perfIndex = arguments.firstIndex(of: "--perf"), perfIndex + 1 < arguments.count, let count = Int(arguments[perfIndex + 1]) {
    section("大量・大きな画像（\(count)枚、各6000×4000ピクセル）")
    let bigFolder = workFolder.appendingPathComponent("big", isDirectory: true)
    try? FileManager.default.removeItem(at: bigFolder)
    try! FileManager.default.createDirectory(at: bigFolder, withIntermediateDirectories: true)
    let started = Date()
    // 写真に近い（圧縮しにくい）画像を1枚ずつ別の内容で作る（同じ画像だとPDF内で1つにまとめられるため）
    var generator = SystemRandomNumberGenerator()
    var noise = [UInt8](repeating: 0, count: 509 * 509 * 4)
    for i in noise.indices { noise[i] = UInt8.random(in: 0...255, using: &generator) }
    let noiseTile = noise.withUnsafeMutableBytes { buffer in
        CGContext(data: buffer.baseAddress, width: 509, height: 509, bitsPerComponent: 8, bytesPerRow: 509 * 4,
                  space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
    }
    DispatchQueue.concurrentPerform(iterations: count) { n in
        let image = makeImage(width: 6000, height: 4000) { context, rect in
            for i in 0..<120 {
                let hue = CGFloat((i + n * 13) % 37) / 37
                context.setFillColor(rgb(hue, 1 - hue, CGFloat((i + n) % 11) / 11))
                let x = CGFloat((i * 7919 + n * 331) % 6000), y = CGFloat((i * 104729 + n * 97) % 4000)
                context.fillEllipse(in: CGRect(x: x - 400, y: y - 300, width: 800 + CGFloat(i % 5) * 120, height: 700))
            }
            context.setAlpha(0.25)
            context.draw(noiseTile, in: CGRect(x: CGFloat(n % 509), y: CGFloat(n * 7 % 509), width: 509, height: 509),
                         byTiling: true)
        }
        write(image, to: bigFolder.appendingPathComponent(String(format: "photo_%03d.jpg", n + 1)), type: .jpeg,
              properties: [kCGImageDestinationLossyCompressionQuality: 0.9])
    }
    let sourceBytes = (try! FileManager.default.contentsOfDirectory(at: bigFolder, includingPropertiesForKeys: [.fileSizeKey]))
        .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    log("  テスト画像の作成: \(String(format: "%.1f", Date().timeIntervalSince(started)))秒、合計 \(sourceBytes / 1024 / 1024)MB")

    let files = try! FileManager.default.contentsOfDirectory(at: bigFolder, includingPropertiesForKeys: nil)
    let inspectStart = Date()
    let infos = LockedArrayPublic<ImageInfo>(count: files.count)
    DispatchQueue.concurrentPerform(iterations: files.count) { i in
        if case .success(let info) = ImageLoader.inspect(files[i]) { infos[i] = info }
    }
    let bigEntries = infos.values.compactMap { $0 }
        .sorted { FileNameOrder.precedes(name: $0.fileName, path: $0.url.path, name: $1.fileName, path: $1.url.path) }
        .map { SheetEntry(id: UUID(), url: $0.url, fileName: $0.fileName, pixelSize: $0.pixelSize) }
    log("  取り込み（大きさ確認と一覧用の小さな画像）: \(String(format: "%.1f", Date().timeIntervalSince(inspectStart)))秒")

    let previewStart = Date()
    _ = PreviewBuilder.renderPage(0, entries: bigEntries, layout: layout, cache: PreviewImageCache())
    log("  プレビュー1ページ目の作成: \(String(format: "%.2f", Date().timeIntervalSince(previewStart)))秒")

    let bigURL = outputFolder.appendingPathComponent("大量画像_\(count)枚.pdf")
    let saveStart = Date()
    try! PDFExporter.export(entries: bigEntries, layout: layout, to: bigURL)
    let bigSize = (try? FileManager.default.attributesOfItem(atPath: bigURL.path)[.size] as? Int) ?? 0
    let pages = layout.pageCount(forImageCount: bigEntries.count)
    log("  PDF保存: \(String(format: "%.1f", Date().timeIntervalSince(saveStart)))秒、\(pages)ページ、\(bigSize / 1024 / 1024)MB（1ページあたり約\(bigSize / max(pages, 1) / 1024)KB）")
    check(PDFDocument(url: bigURL)?.pageCount == pages, "\(count)枚の大きな画像から\(pages)ページのPDFを作れる")
    check(bigSize < sourceBytes / 4, "PDFは元画像の合計よりかなり小さい（\(bigSize / 1024 / 1024)MB／元\(sourceBytes / 1024 / 1024)MB）")
}

log("")
log("結果: 合格 \(passCount)件、不合格 \(failCount)件")
try? reportLines.joined(separator: "\n").write(to: workFolder.appendingPathComponent("検証結果.txt"), atomically: true, encoding: .utf8)
exit(failCount == 0 ? 0 : 1)

final class LockedArrayPublic<Element>: @unchecked Sendable {
    private var storage: [Element?]
    private let lock = NSLock()
    init(count: Int) { storage = Array(repeating: nil, count: count) }
    subscript(index: Int) -> Element? {
        get { lock.lock(); defer { lock.unlock() }; return storage[index] }
        set { lock.lock(); storage[index] = newValue; lock.unlock() }
    }
    var values: [Element?] { lock.lock(); defer { lock.unlock() }; return storage }
}
