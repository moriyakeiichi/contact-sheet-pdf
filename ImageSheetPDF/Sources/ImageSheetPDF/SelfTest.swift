import AppKit
import ImageSheetCore
import PDFKit

/// 開発者向けの動作確認。起動引数「-selfTest 作業フォルダ」を付けたときだけ動き、
/// 画面と同じ処理（ドロップの受け取り・並べ替え・設定変更・保存）を実行して、
/// 結果とウインドウの画像を作業フォルダに書き出してから終了する。通常の起動では何もしない。
///   作業フォルダ/images … 追加する画像
///   -selfTestPhase 2   … 再起動後の設定の引き継ぎだけを確認する
@MainActor
enum SelfTest {
    private static var lines: [String] = []
    private static var folder = URL(fileURLWithPath: "/")

    static func runIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-selfTest"), index + 1 < arguments.count else { return }
        folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        let phase = arguments.firstIndex(of: "-selfTestPhase").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "1"
        Task {
            _ = await waitUntil { NSApp.windows.contains { $0.isVisible } }
            try? await Task.sleep(nanoseconds: 500_000_000)
            if phase == "2" { await runPhase2() } else { await runPhase1() }
            try? lines.joined(separator: "\n").write(to: folder.appendingPathComponent("selftest_phase\(phase).txt"),
                                                     atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    private static var model: AppModel { AppModel.shared }

    private static func check(_ condition: Bool, _ title: String, _ detail: String = "") {
        lines.append("\(condition ? "[OK]" : "[NG]") \(title)\(condition || detail.isEmpty ? "" : " … \(detail)")")
    }

    private static func note(_ text: String) { lines.append("     \(text)") }

    private static func waitUntil(timeout: Double = 30, _ condition: () -> Bool) async -> Bool {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }

    private static func waitForPreview() async {
        _ = await waitUntil {
            !model.isRenderingPreview && model.previewDocument != nil && model.previewPageShown == model.currentPage
        }
        try? await Task.sleep(nanoseconds: 400_000_000)   // 省略の確認と画面の更新を待つ
    }

    /// アプリ自身のウインドウの内容を画像にする
    private static func snapshot(_ name: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name))
    }

    private static func compact(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    private static func findPDFView(in view: NSView?) -> PDFView? {
        guard let view else { return nil }
        if let pdfView = view as? PDFView { return pdfView }
        for subview in view.subviews {
            if let found = findPDFView(in: subview) { return found }
        }
        return nil
    }

    /// 画面のプレビュー欄（PDFView）に、作成したページが表示されているか
    private static func checkPreviewView(_ label: String) {
        let window = NSApp.windows.first { $0.isVisible && $0.contentView != nil }
        guard let pdfView = findPDFView(in: window?.contentView) else {
            check(false, "\(label)：プレビュー欄がある")
            return
        }
        check(pdfView.document === model.previewDocument && pdfView.currentPage != nil
              && pdfView.scaleFactor > 0.2 && pdfView.bounds.width > 300,
              "\(label)：プレビュー欄にページが表示されている（倍率\(String(format: "%.2f", pdfView.scaleFactor))）")
        // 表示中のページの内容（画面の書き出しにはPDFKitの描画が写らないため別に保存する）
        if let page = pdfView.currentPage {
            let image = page.thumbnail(of: NSSize(width: 900, height: 900), for: .mediaBox)
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: folder.appendingPathComponent("プレビュー欄の内容_\(label).png"))
            }
        }
    }

    private static func dropProviders(for urls: [URL]) -> [NSItemProvider] {
        urls.map { NSItemProvider(object: $0 as NSURL) }
    }

    private static func runPhase1() async {
        lines.append("■ 1回目の起動")
        check(model.settings == .standard, "初回起動時は初期値（A4縦・横4×縦5・余白10mm・間隔4mm・8pt）",
              "\(model.settings)")
        check(!model.canSave, "画像がないときは保存できない")
        snapshot("01_起動直後.png")

        let imageFolder = folder.appendingPathComponent("images")
        let files = ((try? FileManager.default.contentsOfDirectory(at: imageFolder, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        note("ドロップするファイル: \(files.count)件")
        check(model.handleDrop(dropProviders(for: files)), "ドロップを受け付ける")
        _ = await waitUntil { model.importStatus != nil && !model.isImporting }
        note("お知らせ: \(model.importStatus?.text ?? "なし")")
        check(model.items.count == 21, "有効な画像21枚が一覧に入る", "\(model.items.count)枚")
        check(model.issues.count == 5, "追加できない5件が理由付きで表示される", "\(model.issues.count)件")
        for issue in model.issues { note("\(issue.fileName)：\(issue.reason)") }
        let names = model.items.map(\.fileName)
        check(Array(names.prefix(3)) == ["1.jpg", "2.jpg", "10.jpg"], "ファイル名の自然な順序（1, 2, 10）",
              names.prefix(3).joined(separator: ", "))
        await waitForPreview()
        check(model.summaryText == "画像21枚／1ページ20枚／全2ページ", "件数表示「\(model.summaryText)」")
        check(model.previewDocument?.pageCount == 1 && model.previewPageShown == 0, "プレビューに1ページ目を表示する")
        check(model.truncatedIDs.count == 2, "ファイル名が省略される画像を一覧で示す（2件）", "\(model.truncatedIDs.count)件")
        snapshot("02_画像追加後.png")

        // 同じファイルをもう一度ドロップ
        model.importStatus = nil
        _ = model.handleDrop(dropProviders(for: Array(files.prefix(5))))
        _ = await waitUntil { model.importStatus != nil && !model.isImporting }
        check(model.items.count == 21 && model.importStatus?.text.contains("すでに一覧にある") == true,
              "同じ画像を重複して追加しない", model.importStatus?.text ?? "")

        checkPreviewView("1ページ目")
        let twentyFirst = model.items[20].fileName
        model.goToPage(1)
        await waitForPreview()
        let secondPageText = compact(model.previewDocument?.page(at: 0)?.string ?? "")
        check(model.previewPageShown == 1 && secondPageText == compact(twentyFirst),
              "2ページ目に切り替えると21枚目（\(twentyFirst)）だけが表示される", secondPageText)
        checkPreviewView("2ページ目")
        snapshot("03_2ページ目.png")

        // 並べ替え（一覧のドラッグと同じ処理）：最後の画像を先頭へ
        let last = model.items.last!
        model.move(from: IndexSet(integer: model.items.count - 1), to: 0)
        check(model.items.first?.id == last.id && !model.isNameOrder, "最後の画像を先頭に移動できる")
        // 並べ替え済みの一覧の途中にドロップすると、その位置に入る
        if let two = model.items.first(where: { $0.fileName == "2.jpg" }) {
            model.remove(ids: [two.id])
            model.importStatus = nil
            _ = model.handleDrop(dropProviders(for: [two.url]), insertAt: 3)
            _ = await waitUntil { model.importStatus != nil && !model.isImporting }
            check(model.items.count == 21 && model.items[3].fileName == "2.jpg" && model.items.first?.id == last.id,
                  "並べ替え済みの一覧の途中にドロップすると、その位置に追加する", model.importStatus?.text ?? "")
        }
        model.goToPage(0)
        await waitForPreview()
        snapshot("04_並べ替え後.png")

        // 保存（保存パネルで場所を選んだ後と同じ処理）
        let output = folder.appendingPathComponent("out", isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let pdfURL = output.appendingPathComponent("画面からの保存.pdf")
        try? FileManager.default.removeItem(at: pdfURL)
        model.startSave(to: pdfURL)
        _ = await waitUntil { model.saveProgress == nil && (model.saveStatus != nil || model.alert != nil) }
        note("保存後の表示: \(model.saveStatus?.text ?? model.alert?.message ?? "なし")")
        snapshot("05_保存後.png")
        let saved = PDFDocument(url: pdfURL)
        check(saved?.pageCount == 2, "保存したPDFは2ページ", "\(saved?.pageCount ?? 0)")
        let firstPage = compact(saved?.page(at: 0)?.string ?? "")
        check(firstPage.hasPrefix(compact(last.fileName)), "並べ替えた順番（先頭が「\(last.fileName)」）がPDFに反映される",
              String(firstPage.prefix(40)))
        if let preview = model.previewDocument?.page(at: 0)?.string, let savedText = saved?.page(at: 0)?.string {
            check(preview == savedText, "プレビューと保存PDFの1ページ目の文字が一致する")
        }
        // 同じ場所へもう一度保存（上書き）
        let firstSize = (try? FileManager.default.attributesOfItem(atPath: pdfURL.path)[.size] as? Int) ?? 0
        model.startSave(to: pdfURL)
        _ = await waitUntil { model.saveProgress == nil && (model.saveStatus != nil || model.alert != nil) }
        check(PDFDocument(url: pdfURL)?.pageCount == 2 && firstSize > 0, "既存のPDFに上書き保存できる")

        // 配置できない設定
        model.updateSettings { $0.columns = 30 }
        try? await Task.sleep(nanoseconds: 400_000_000)
        check(model.layout.problem != nil && !model.canSave, "横30個では理由を表示し、保存できない")
        note("理由: \(model.layout.problem ?? "")")
        snapshot("06_配置できない設定.png")

        // 設定の変更（次回起動時に引き継がれるか、2回目の起動で確認）
        model.updateSettings {
            $0.columns = 5; $0.rows = 6; $0.orientation = .landscape
            $0.marginMM = 8; $0.spacingMM = 3; $0.fontSize = 7
        }
        await waitForPreview()
        check(model.summaryText == "画像21枚／1ページ30枚／全1ページ", "設定変更がプレビューと件数表示に反映される",
              model.summaryText)
        snapshot("07_設定変更後.png")

        // 一覧から取り除く（元ファイルは残る）
        model.sortByName()
        let removed = Array(model.items.prefix(2))
        model.selection = Set(removed.map(\.id))
        model.removeSelected()
        check(model.items.count == 19 && removed.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) },
              "選択した2枚を一覧から取り除いても元ファイルは残る")
        try? await Task.sleep(nanoseconds: 300_000_000)
        model.removeAll()
        check(model.items.isEmpty && removed.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) },
              "一覧をすべて消去しても元ファイルは残る")
    }

    private static func runPhase2() async {
        lines.append("■ 2回目の起動（再起動後）")
        let expected = LayoutSettings(columns: 5, rows: 6, orientation: .landscape, marginMM: 8, spacingMM: 3, fontSize: 7)
        check(model.settings == expected, "前回の設定（A4横・横5×縦6・余白8mm・間隔3mm・7pt）が引き継がれる",
              "\(model.settings)")
        snapshot("08_再起動後.png")
    }
}
