import AppKit
import SwiftUI

@main
struct ImageSheetPDFApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("画像一覧PDF", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { AppCommands(model: model) }
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("画像を追加…") { model.presentOpenPanel() }
                .keyboardShortcut("o")
        }
        // 「閉じる（⌘W）」は残し、その後ろに追加する
        CommandGroup(after: .saveItem) {
            Button("PDFを保存…") { model.presentSavePanel() }
                .keyboardShortcut("s")
                .disabled(!model.canSave)
        }
        CommandMenu("画像") {
            Button("選択した画像を一覧から取り除く") { model.removeSelected() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selection.isEmpty)
            Button("ファイル名順に並べ直す") { model.sortByName() }
                .disabled(model.items.count < 2 || model.isNameOrder)
            Divider()
            Button("一覧をすべて消去…") { model.isConfirmingClearAll = true }
                .disabled(model.items.isEmpty)
        }
        CommandGroup(after: .toolbar) {
            Button("前のページ") { model.goToPage(model.currentPage - 1) }
                .keyboardShortcut("[")
                .disabled(model.currentPage <= 0)
            Button("次のページ") { model.goToPage(model.currentPage + 1) }
                .keyboardShortcut("]")
                .disabled(model.currentPage >= model.pageCount - 1)
            Divider()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            SelfTest.runIfRequested()
        }
    }

    /// Finderの「このアプリケーションで開く」やDockアイコンへのドロップで渡された画像
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            AppModel.shared.add(urls: urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
