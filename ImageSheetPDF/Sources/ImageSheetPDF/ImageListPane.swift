import ImageSheetCore
import SwiftUI

/// 左側：取り込んだ画像の一覧
struct ImageListPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("画像一覧")
                    .font(.headline)
                Text("\(model.items.count)枚")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button {
                    model.presentOpenPanel()
                } label: {
                    Label("画像を追加…", systemImage: "plus")
                }
                .help("画像ファイルやフォルダを選んで追加します（⌘O）")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()

            messages

            if model.items.isEmpty {
                EmptyListView()
            } else {
                list
            }

            Divider()
            footer
        }
    }

    @ViewBuilder
    private var messages: some View {
        let hasMessages = model.isImporting || model.importStatus != nil || !model.issues.isEmpty
        if hasMessages {
            VStack(spacing: 8) {
                if model.isImporting {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("画像を読み込んでいます… \(model.importDone) / \(model.importTotal)")
                            .font(.callout)
                            .monospacedDigit()
                        ProgressView(value: Double(model.importDone), total: Double(max(model.importTotal, 1)))
                    }
                }
                if let status = model.importStatus {
                    StatusBanner(status: status) { model.importStatus = nil }
                }
                if !model.issues.isEmpty {
                    IssueList(issues: model.issues) { model.issues.removeAll() }
                }
            }
            .padding(10)
            Divider()
        }
    }

    private var list: some View {
        List(selection: $model.selection) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                ImageRow(position: index + 1, item: item,
                         isTruncated: model.truncatedIDs.contains(item.id),
                         isMissing: model.missingIDs.contains(item.id))
                    .tag(item.id)
                    .contextMenu {
                        Button("Finderで表示") { model.revealInFinder(item.url) }
                        Divider()
                        Button(removeTitle(for: item)) { model.remove(ids: idsForAction(on: item)) }
                    }
            }
            .onMove { source, destination in
                model.move(from: source, to: destination)
            }
            // 一覧の上にFinderからドロップした場合も追加する
            .onInsert(of: [.fileURL]) { index, providers in
                _ = model.handleDrop(providers, insertAt: index)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .onDeleteCommand { model.removeSelected() }
    }

    private func idsForAction(on item: ImageItem) -> Set<UUID> {
        model.selection.contains(item.id) ? model.selection : [item.id]
    }

    private func removeTitle(for item: ImageItem) -> String {
        let count = idsForAction(on: item).count
        return count > 1 ? "選択した\(count)枚を一覧から取り除く" : "一覧から取り除く"
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("選択を取り除く") { model.removeSelected() }
                    .disabled(model.selection.isEmpty)
                    .help("選んだ画像を一覧から外します（元のファイルは削除しません）")
                Button("すべて消去…") { model.isConfirmingClearAll = true }
                    .disabled(model.items.isEmpty)
                Spacer()
                Button("名前順に戻す") { model.sortByName() }
                    .disabled(model.items.count < 2 || model.isNameOrder)
                    .help("ファイル名順（1, 2, 10 …）に並べ直します")
            }
            Text(model.isNameOrder ? "ファイル名順に並んでいます。行をドラッグすると順番を変えられます。"
                                   : "並べ替えた順番でPDFに配置します。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
    }
}

private struct ImageRow: View {
    let position: Int
    let item: ImageItem
    let isTruncated: Bool
    let isMissing: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(position)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .trailing)
                .padding(.top, 2)
            Thumbnail(image: item.thumbnail)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                // 一覧では元のファイル名を省略せずに表示する
                Text(item.fileName)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: "\(item.formatName)・\(Int(item.pixelSize.width))×\(Int(item.pixelSize.height))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isMissing {
                    Label("ファイルが見つかりません", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if isTruncated {
                    Label("PDFでは名前を省略して表示", systemImage: "ellipsis.rectangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .help(item.url.path)
    }
}

private struct Thumbnail: View {
    let image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.12))
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .padding(2)
            }
        }
    }
}

private struct EmptyListView: View {
    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "photo.stack")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("まだ画像がありません")
                .font(.headline)
            Text("Finderから画像をこのウインドウへドラッグ＆ドロップするか、上の「画像を追加…」から選んでください。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct IssueList: View {
    let issues: [ImportIssue]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("追加できなかったファイル（\(issues.count)件）")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("閉じる")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(issues) { issue in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(issue.fileName)
                                .font(.caption.weight(.semibold))
                            Text(issue.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .help(issue.path)
                    }
                }
            }
            .frame(height: min(150, CGFloat(issues.count) * 44))
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
