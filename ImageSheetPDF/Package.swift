// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ImageSheetPDF",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ImageSheetPDF", targets: ["ImageSheetPDF"]),
        .executable(name: "sheetcheck", targets: ["sheetcheck"]),
    ],
    targets: [
        // レイアウト計算・ファイル名の組版・画像読み込み・PDF作成（画面に依存しない部分）
        .target(name: "ImageSheetCore"),
        // macOSアプリ本体（SwiftUI）
        .executableTarget(name: "ImageSheetPDF", dependencies: ["ImageSheetCore"]),
        // 動作確認用のコマンドラインツール
        .executableTarget(name: "sheetcheck", dependencies: ["ImageSheetCore"]),
    ]
)
