# 画像一覧PDF（ソースコード）

macOS 標準の技術（SwiftUI・PDFKit・Core Graphics・Core Text・ImageIO）だけで作っています。外部ライブラリへの依存はありません。

## フォルダ構成

```
ImageSheetPDF/
├── build.sh                  .app を作るスクリプト（ユニバーサル版・アドホック署名）
├── Package.swift
├── Packaging/
│   ├── Info.plist            アプリの情報（日本語・対応する画像形式）
│   └── make_icon.swift       アイコンを描くスクリプト
└── Sources/
    ├── ImageSheetCore/       画面に依存しない処理
    │   ├── LayoutSettings.swift   設定値・範囲・初期値
    │   ├── SheetLayout.swift      マスの計算、配置できない設定の判定
    │   ├── LabelTypesetter.swift  ファイル名の折り返し・中間省略（Core Text）
    │   ├── ImageLoader.swift      画像の確認・向きの反映・縮小・白背景への合成
    │   ├── ImageIntegrity.swift   途中で切れた JPEG・PNG の検出
    │   ├── FileCollector.swift    ファイル名順、フォルダの展開、重複の判定
    │   ├── SheetRenderer.swift    ページの描画（プレビューと保存で共通）
    │   ├── PDFExporter.swift      保存（一時ファイル → 確認 → 置き換え）
    │   └── PreviewBuilder.swift   プレビュー1ページ分の作成と画像キャッシュ
    ├── ImageSheetPDF/        アプリ本体（SwiftUI）
    │   ├── ImageSheetPDFApp.swift メニュー・起動処理
    │   ├── AppModel.swift         画面の状態と操作
    │   ├── ContentView.swift      3列のメイン画面、ドロップ、保存中の表示
    │   ├── ImageListPane.swift    左：画像一覧
    │   ├── PreviewPane.swift      中央：プレビュー
    │   ├── SettingsPane.swift     右：レイアウト設定と保存
    │   └── SelfTest.swift         開発者向けの動作確認（起動引数がある時だけ動く）
    └── sheetcheck/           動作確認用のコマンドラインツール
```

## ビルド

Xcode または Command Line Tools（`xcode-select --install`）が必要です。

```bash
./build.sh
```

一つ上のフォルダに `画像一覧PDF.app` ができます。出力先は `./build.sh 出力先フォルダ` で変えられます。

Command Line Tools だけの環境では、macOS 27 SDK の SwiftUI が Command Line Tools に含まれないマクロ部品を必要とするため、`build.sh` は macOS 26 SDK を自動で選びます。どちらの SDK でビルドしても、アプリは macOS 13 以降を対象にしています。

## 動作確認

PDF処理の確認（テスト画像を作り、配置・文字・画素・保存の安全性を調べる）：

```bash
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk   # Xcode がある場合は不要
swift build -c release --product sheetcheck
"$(swift build -c release --show-bin-path)/sheetcheck" /tmp/sheetcheck --perf 100
```

アプリ本体の確認（`作業フォルダ/images` の画像を使い、ドロップの受け取り・並べ替え・保存・設定の引き継ぎを実行し、結果とウインドウの画像を書き出して終了する）：

```bash
画像一覧PDF.app/Contents/MacOS/ImageSheetPDF -selfTest 作業フォルダ
画像一覧PDF.app/Contents/MacOS/ImageSheetPDF -selfTest 作業フォルダ -selfTestPhase 2
```

この確認はレイアウト設定を書き換えます。終わったら `defaults delete local.ImageSheetPDF` で初期状態に戻せます。

## 設計上の要点

- **プレビューと保存の一致**：どちらも `SheetRenderer` の同じ描画処理でPDFページを作ります。違いは画像の解像度だけです（プレビュー約180dpi、保存300dpi）。
- **ファイル名**：ヒラギノ角ゴシック W3 を使い、Core Text でPDFに文字として書き込みます（検索・選択できる）。合字は使いません（「tiff」が「ti + ﬀ」になり検索できなくなるため）。濁点などは合成済みの形にそろえて表示します。
- **画像**：ImageIO で向き情報を反映して必要な大きさに縮小し、白背景に合成して JPEG で埋め込みます。
- **保存の安全性**：保存先と同じボリュームの一時フォルダに書き出し、ページ数を確認してから `FileManager.replaceItemAt` で置き換えます。
- **設定の保存**：`UserDefaults`（ドメイン `local.ImageSheetPDF`）に項目ごとに保存します。
