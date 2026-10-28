import ImageSheetCore
import SwiftUI
import UniformTypeIdentifiers

/// メイン画面：左から「画像一覧」「PDFプレビュー」「レイアウト設定と保存」
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isDropTargeted = false

    var body: some View {
        HSplitView {
            ImageListPane()
                .frame(minWidth: 260, idealWidth: 310, maxWidth: 480)
            PreviewPane()
                .frame(minWidth: 400, maxWidth: .infinity)
            SettingsPane()
                .frame(minWidth: 260, idealWidth: 280, maxWidth: 340)
        }
        // ウインドウのどこにドロップしても追加できる
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            model.handleDrop(providers)
        }
        .overlay {
            if isDropTargeted {
                DropHighlight()
            }
        }
        .sheet(isPresented: Binding(get: { model.saveProgress != nil }, set: { _ in })) {
            SaveProgressSheet()
                .environmentObject(model)
        }
        .alert(model.alert?.title ?? "", isPresented: Binding(get: { model.alert != nil },
                                                              set: { if !$0 { model.alert = nil } }),
               presenting: model.alert) { _ in
            Button("OK") {}
        } message: { info in
            Text(info.message)
        }
        .confirmationDialog("一覧からすべての画像を取り除きますか？", isPresented: $model.isConfirmingClearAll) {
            Button("すべて消去", role: .destructive) { model.removeAll() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("元の画像ファイルは削除されません。")
        }
    }
}

private struct DropHighlight: View {
    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.08)
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                .padding(8)
            Label("ドロップして画像を追加", systemImage: "plus.circle.fill")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
        }
        .allowsHitTesting(false)
    }
}

private struct SaveProgressSheet: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let progress = model.saveProgress
        VStack(alignment: .leading, spacing: 14) {
            Text(progress?.isCancelling == true ? "中止しています…" : "PDFを作成しています…")
                .font(.headline)
            ProgressView(value: Double(progress?.donePages ?? 0),
                         total: Double(max(progress?.totalPages ?? 1, 1)))
            Text("\(progress?.donePages ?? 0) / \(progress?.totalPages ?? 0) ページ")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("キャンセル") { model.cancelSave() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(progress?.isCancelling == true)
            }
        }
        .padding(20)
        .frame(width: 380)
        .interactiveDismissDisabled()
    }
}

/// 情報・完了・注意のお知らせ
struct StatusBanner: View {
    let status: StatusMessage
    var onReveal: ((URL) -> Void)?
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(status.text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let url = status.revealURL, let onReveal {
                    Button("Finderで表示") { onReveal(url) }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("閉じる")
        }
        .padding(10)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var icon: String {
        switch status.kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch status.kind {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        }
    }
}
