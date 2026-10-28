import ImageSheetCore
import PDFKit
import SwiftUI

/// 中央：保存するPDFと同じ描画処理で作ったプレビュー
struct PreviewPane: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var zoom = PreviewZoom()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                content
            }
            Divider()
            pageNavigation
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.summaryText)
                    .font(.headline)
                    .monospacedDigit()
                Spacer()
                if !model.items.isEmpty && model.layout.isValid {
                    HStack(spacing: 2) {
                        Button { zoom.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                            .help("縮小")
                        Button("全体") { zoom.fit() }
                            .help("ページ全体を表示")
                        Button { zoom.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                            .help("拡大")
                    }
                    .buttonStyle(.borderless)
                }
            }
            if !model.missingIDs.isEmpty {
                Label("見つからない画像が\(model.missingIDs.count)件あります。一覧から取り除くか、元の場所に戻してください。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if model.layout.isValid && !model.truncatedIDs.isEmpty {
                Label("長いファイル名\(model.truncatedIDs.count)件は、中間を「…」で省略して表示します（画像一覧で全文を確認できます）。",
                      systemImage: "ellipsis.rectangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if model.items.isEmpty {
            DropGuideView()
        } else if let problem = model.layout.problem {
            LayoutProblemView(message: problem)
        } else {
            PDFPreviewView(document: model.previewDocument, zoom: zoom)
            if model.isRenderingPreview && (model.previewDocument == nil || model.previewPageShown != model.currentPage) {
                ProgressView()
                    .controlSize(.small)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var pageNavigation: some View {
        HStack(spacing: 12) {
            Button {
                model.goToPage(model.currentPage - 1)
            } label: {
                Label("前のページ", systemImage: "chevron.left")
            }
            .disabled(model.currentPage <= 0 || model.pageCount == 0)

            Text(model.pageCount > 0 ? "\(model.currentPage + 1) / \(model.pageCount) ページ" : "– / – ページ")
                .monospacedDigit()
                .frame(minWidth: 110)

            Button {
                model.goToPage(model.currentPage + 1)
            } label: {
                Label("次のページ", systemImage: "chevron.right")
                    .labelStyle(TrailingIconLabelStyle())
            }
            .disabled(model.currentPage >= model.pageCount - 1)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}

/// 画像がないときの案内
private struct DropGuideView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("ここに画像をドラッグ＆ドロップ")
                .font(.title2.weight(.semibold))
            Text("Finderで画像ファイル（またはフォルダ）を選び、このウインドウへドラッグしてください。\n「画像を追加…」ボタンから選ぶこともできます。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.presentOpenPanel()
            } label: {
                Label("画像を追加…", systemImage: "plus")
            }
            .controlSize(.large)
            Text("対応形式：\(ImageFormats.supportedDescription)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(36)
        .frame(maxWidth: 520)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
        )
        .padding(24)
    }
}

private struct LayoutProblemView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("この設定では配置できません")
                .font(.title3.weight(.semibold))
            Text(message)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("右側の設定を変更してください。このままでは保存できません。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: 520)
    }
}

final class PreviewZoom: ObservableObject {
    weak var view: PDFView?

    func zoomIn() { view?.zoomIn(nil) }
    func zoomOut() { view?.zoomOut(nil) }
    func fit() { view?.autoScales = true }
}

/// PDFKit でプレビューのページを表示する（拡大・縮小、文字の選択ができる）
private struct PDFPreviewView: NSViewRepresentable {
    let document: PDFDocument?
    let zoom: PreviewZoom

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePage
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.autoScales = true
        view.backgroundColor = .underPageBackgroundColor
        view.document = document
        zoom.view = view
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        zoom.view = view
        guard view.document !== document else { return }
        // 拡大していた場合はその倍率を保つ
        let keptScale: CGFloat? = view.autoScales ? nil : view.scaleFactor
        view.document = document
        if let keptScale {
            view.scaleFactor = keptScale
        } else {
            view.autoScales = true
        }
    }
}
