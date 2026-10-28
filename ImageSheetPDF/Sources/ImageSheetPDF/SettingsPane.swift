import ImageSheetCore
import SwiftUI

/// 右側：レイアウト設定と「PDFを保存」
struct SettingsPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("レイアウト")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    paperSection
                    gridSection
                    spacingSection
                    labelSection
                    Button("初期値に戻す") { model.resetSettings() }
                        .help("A4縦・横4個×縦5個・余白10mm・間隔4mm・文字8ptに戻します")
                }
                .padding(12)
            }
            Divider()
            saveSection
        }
    }

    private var paperSection: some View {
        SettingsSection(title: "用紙") {
            Picker("用紙", selection: model.binding(\.orientation)) {
                ForEach(PaperOrientation.allCases) { orientation in
                    Text(orientation.displayName).tag(orientation)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var gridSection: some View {
        SettingsSection(title: "並べ方") {
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 8) {
                IntegerRow(title: "横の個数（列数）", value: model.binding(\.columns),
                           range: LayoutSettings.countRange, unit: "個")
                IntegerRow(title: "縦の個数（行数）", value: model.binding(\.rows),
                           range: LayoutSettings.countRange, unit: "個")
            }
            Text("1ページに最大\(model.layout.imagesPerPage)枚（左から右、上から下の順）")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.layout.isValid {
                Text("1マスの大きさ：約\(mm(model.layout.cellSize.width))×\(mm(model.layout.cellSize.height))mm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var spacingSection: some View {
        SettingsSection(title: "余白と間隔") {
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 8) {
                DecimalRow(title: "用紙の余白", value: model.binding(\.marginMM),
                           range: LayoutSettings.marginRange, step: 1, unit: "mm")
                DecimalRow(title: "画像の間隔", value: model.binding(\.spacingMM),
                           range: LayoutSettings.spacingRange, step: 1, unit: "mm")
            }
        }
    }

    private var labelSection: some View {
        SettingsSection(title: "ファイル名") {
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 8) {
                DecimalRow(title: "文字サイズ", value: model.binding(\.fontSize),
                           range: LayoutSettings.fontSizeRange, step: 0.5, unit: "pt")
            }
            Text("画像の下に最大2行で表示します。収まらない名前は拡張子を残して中間を省略します。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var saveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let problem = model.layout.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status = model.saveStatus {
                StatusBanner(status: status, onReveal: { model.revealInFinder($0) }) { model.saveStatus = nil }
            }
            Button {
                model.presentSavePanel()
            } label: {
                Label("PDFを保存…", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canSave)
            if let reason = model.saveDisabledReason, model.layout.isValid {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private func mm(_ points: CGFloat) -> String {
        Units.format(Units.mm(fromPoints: points))
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

private struct IntegerRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let unit: String

    var body: some View {
        GridRow {
            Text(title)
                .gridColumnAlignment(.leading)
            TextField(title, value: $value, format: .number.grouping(.never))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 48)
            Text(unit)
                .foregroundStyle(.secondary)
            Stepper(title, value: $value, in: range)
                .labelsHidden()
        }
    }
}

private struct DecimalRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    var body: some View {
        GridRow {
            Text(title)
                .gridColumnAlignment(.leading)
            TextField(title, value: $value, format: .number.precision(.fractionLength(0...1)).grouping(.never))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 48)
            Text(unit)
                .foregroundStyle(.secondary)
            Stepper(title, value: $value, in: range, step: step)
                .labelsHidden()
        }
    }
}
