import AppKit
import ImageSheetCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct ImageItem: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let fileName: String
    let pixelSize: CGSize
    let formatName: String
    let thumbnail: CGImage?
    /// 同じファイルを重複して追加しないためのキー
    let fileKey: String

    init(info: ImageInfo, fileKey: String) {
        id = UUID()
        url = info.url
        fileName = info.fileName
        pixelSize = info.pixelSize
        formatName = info.formatName
        thumbnail = info.thumbnail
        self.fileKey = fileKey
    }

    var entry: SheetEntry {
        SheetEntry(id: id, url: url, fileName: fileName, pixelSize: pixelSize)
    }

    static func == (lhs: ImageItem, rhs: ImageItem) -> Bool { lhs.id == rhs.id }

    static func nameOrder(_ a: ImageItem, _ b: ImageItem) -> Bool {
        FileNameOrder.precedes(name: a.fileName, path: a.url.path, name: b.fileName, path: b.url.path)
    }
}

struct ImportIssue: Identifiable {
    let id = UUID()
    let fileName: String
    let path: String
    let reason: String
}

struct StatusMessage: Equatable {
    enum Kind { case info, success, warning }
    var kind: Kind
    var text: String
    var revealURL: URL?
}

struct SaveProgress {
    var donePages: Int
    var totalPages: Int
    let cancelFlag: CancelFlag
    var isCancelling = false
}

struct AlertInfo: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// 設定の保存（UserDefaults）。項目ごとに保存し、次回起動時に引き継ぐ。
enum SettingsStore {
    private static let defaults = UserDefaults.standard

    static func load() -> LayoutSettings {
        let base = LayoutSettings.standard
        let settings = LayoutSettings(
            columns: defaults.object(forKey: "columns") as? Int ?? base.columns,
            rows: defaults.object(forKey: "rows") as? Int ?? base.rows,
            orientation: (defaults.string(forKey: "orientation")).flatMap(PaperOrientation.init(rawValue:)) ?? base.orientation,
            marginMM: defaults.object(forKey: "marginMM") as? Double ?? base.marginMM,
            spacingMM: defaults.object(forKey: "spacingMM") as? Double ?? base.spacingMM,
            fontSize: defaults.object(forKey: "fontSize") as? Double ?? base.fontSize)
        return settings.clamped()
    }

    static func save(_ settings: LayoutSettings) {
        defaults.set(settings.columns, forKey: "columns")
        defaults.set(settings.rows, forKey: "rows")
        defaults.set(settings.orientation.rawValue, forKey: "orientation")
        defaults.set(settings.marginMM, forKey: "marginMM")
        defaults.set(settings.spacingMM, forKey: "spacingMM")
        defaults.set(settings.fontSize, forKey: "fontSize")
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    // 画像一覧
    @Published private(set) var items: [ImageItem] = [] { didSet { itemsDidChange() } }
    @Published var selection = Set<UUID>()
    /// ファイル名順のままか（手で並べ替えると false）
    @Published private(set) var isNameOrder = true
    @Published var issues: [ImportIssue] = []
    @Published var importStatus: StatusMessage?
    @Published private(set) var importDone = 0
    @Published private(set) var importTotal = 0
    @Published private(set) var activeImports = 0

    // レイアウト
    @Published private(set) var settings: LayoutSettings
    @Published private(set) var layout: SheetLayout

    // プレビュー
    @Published private(set) var currentPage = 0
    @Published private(set) var previewDocument: PDFDocument?
    @Published private(set) var previewPageShown: Int?
    @Published private(set) var isRenderingPreview = false
    @Published private(set) var truncatedIDs = Set<UUID>()
    @Published private(set) var missingIDs = Set<UUID>()

    // 保存
    @Published private(set) var saveProgress: SaveProgress?
    @Published var saveStatus: StatusMessage?
    @Published var alert: AlertInfo?
    @Published var isConfirmingClearAll = false

    private let previewCache = PreviewImageCache()
    private var previewTask: Task<Void, Never>?
    private var previewGeneration = 0
    private var truncationTask: Task<Void, Never>?
    private var inFlightKeys = Set<String>()

    init() {
        let settings = SettingsStore.load()
        self.settings = settings
        layout = SheetLayout(settings: settings)
    }

    // MARK: - 表示用の値

    var isImporting: Bool { activeImports > 0 }

    var pageCount: Int {
        layout.isValid ? layout.pageCount(forImageCount: items.count) : 0
    }

    var summaryText: String {
        var text = "画像\(items.count)枚／1ページ\(layout.imagesPerPage)枚"
        if !layout.isValid {
            text += "／配置できません"
        } else if pageCount > 0 {
            text += "／全\(pageCount)ページ"
        }
        return text
    }

    var canSave: Bool {
        !items.isEmpty && layout.isValid && !isImporting && saveProgress == nil
    }

    var saveDisabledReason: String? {
        if items.isEmpty { return "画像を追加すると保存できます。" }
        if !layout.isValid { return "現在の設定では配置できないため、保存できません。" }
        if isImporting { return "画像の読み込みが終わると保存できます。" }
        return nil
    }

    // MARK: - 画像の追加

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "画像を追加"
        panel.prompt = "追加"
        panel.message = "一覧に追加する画像（またはフォルダ）を選んでください。⌘キーやshiftキーを押しながらクリックすると複数選べます。"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = ImageFormats.openPanelTypes
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            self?.add(urls: panel.urls)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    /// insertAt：一覧の行の間にドロップした位置（並べ替え済みのときだけ、その位置に入れる）
    func handleDrop(_ providers: [NSItemProvider], insertAt: Int? = nil) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        let collected = URLCollector()
        let group = DispatchGroup()
        for provider in fileProviders {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { collected.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            Task { @MainActor in
                AppModel.shared.add(urls: collected.urls, insertAt: insertAt)
            }
        }
        return true
    }

    func add(urls: [URL], insertAt: Int? = nil) {
        guard !urls.isEmpty else { return }
        activeImports += 1
        let knownKeys = Set(items.map(\.fileKey)).union(inFlightKeys)
        Task {
            let plan = await Task.detached(priority: .userInitiated) {
                ImportPlan.make(from: urls, excluding: knownKeys)
            }.value
            inFlightKeys.formUnion(plan.keys)
            importTotal += plan.files.count
            let results = await inspect(plan.files)
            inFlightKeys.subtract(plan.keys)
            merge(results, plan: plan, insertAt: insertAt)
            activeImports -= 1
            if activeImports == 0 {
                importDone = 0
                importTotal = 0
            }
        }
    }

    /// 画像を並行して確認する（同時に処理する数を抑え、画面が固まらないようにする）
    private func inspect(_ files: [URL]) async -> [Result<ImageInfo, ImportFailure>] {
        guard !files.isEmpty else { return [] }
        var results = [Result<ImageInfo, ImportFailure>?](repeating: nil, count: files.count)
        let limit = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
        await withTaskGroup(of: (Int, Result<ImageInfo, ImportFailure>).self) { group in
            var next = 0
            while next < min(limit, files.count) {
                let index = next
                group.addTask { (index, ImageLoader.inspect(files[index])) }
                next += 1
            }
            while let (index, result) = await group.next() {
                results[index] = result
                importDone += 1
                if next < files.count {
                    let index = next
                    group.addTask { (index, ImageLoader.inspect(files[index])) }
                    next += 1
                }
            }
        }
        return results.compactMap { $0 }
    }

    private func merge(_ results: [Result<ImageInfo, ImportFailure>], plan: ImportPlan, insertAt: Int?) {
        var known = Set(items.map(\.fileKey))
        var added: [ImageItem] = []
        var duplicates = plan.duplicateCount
        var newIssues: [ImportIssue] = []
        for (index, result) in results.enumerated() {
            switch result {
            case .success(let info):
                let key = plan.keys[index]
                if known.contains(key) {
                    duplicates += 1
                    continue
                }
                known.insert(key)
                added.append(ImageItem(info: info, fileKey: key))
            case .failure(let failure):
                newIssues.append(ImportIssue(fileName: failure.fileName, path: failure.url.path, reason: failure.reason))
            }
        }
        added.sort(by: ImageItem.nameOrder)
        if !added.isEmpty {
            if isNameOrder {
                items = (items + added).sorted(by: ImageItem.nameOrder)
            } else if let insertAt {
                items.insert(contentsOf: added, at: min(max(insertAt, 0), items.count))
            } else {
                items += added
            }
        }
        issues.append(contentsOf: newIssues)

        var parts: [String] = []
        if !added.isEmpty { parts.append("\(added.count)枚を追加しました。") }
        if !isNameOrder && !added.isEmpty {
            parts.append(insertAt == nil ? "並べ替え済みのため、一覧の最後に追加しました。" : "並べ替え済みのため、ドロップした位置に追加しました。")
        }
        if duplicates > 0 { parts.append("\(duplicates)件はすでに一覧にあるため、追加しませんでした。") }
        if plan.skippedNonImages > 0 { parts.append("フォルダ内の画像以外のファイル\(plan.skippedNonImages)件は対象外にしました。") }
        if plan.skippedFolders > 0 { parts.append("フォルダ内のフォルダ\(plan.skippedFolders)件の中は読み込んでいません。") }
        if !newIssues.isEmpty { parts.append("\(newIssues.count)件は追加できませんでした（理由は下に表示）。") }
        if parts.isEmpty { parts.append("追加できる画像がありませんでした。") }
        importStatus = StatusMessage(kind: newIssues.isEmpty ? .info : .warning, text: parts.joined(), revealURL: nil)
    }

    // MARK: - 一覧の操作（元ファイルは削除しない）

    func removeSelected() {
        guard !selection.isEmpty else { return }
        remove(ids: selection)
    }

    func remove(ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    func removeAll() {
        items.removeAll()
        selection.removeAll()
        issues.removeAll()
        importStatus = nil
        isNameOrder = true
        previewCache.removeAll()
    }

    func move(from source: IndexSet, to destination: Int) {
        var reordered = items
        reordered.move(fromOffsets: source, toOffset: destination)
        guard reordered.map(\.id) != items.map(\.id) else { return }
        items = reordered
        isNameOrder = false
    }

    func sortByName() {
        items.sort(by: ImageItem.nameOrder)
        isNameOrder = true
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func itemsDidChange() {
        let ids = Set(items.map(\.id))
        if !selection.isSubset(of: ids) { selection.formIntersection(ids) }
        missingIDs.formIntersection(ids)
        clampPage()
        schedulePreview(debounce: true)
        scheduleTruncationCheck()
    }

    // MARK: - 設定

    func updateSettings(_ change: (inout LayoutSettings) -> Void) {
        var updated = settings
        change(&updated)
        updated = updated.clamped()
        guard updated != settings else { return }
        settings = updated
        SettingsStore.save(updated)
        layout = SheetLayout(settings: updated)
        clampPage()
        schedulePreview(debounce: true)
        scheduleTruncationCheck()
    }

    func resetSettings() {
        updateSettings { $0 = .standard }
    }

    func binding<Value>(_ keyPath: WritableKeyPath<LayoutSettings, Value>) -> Binding<Value> {
        Binding(get: { self.settings[keyPath: keyPath] },
                set: { value in self.updateSettings { $0[keyPath: keyPath] = value } })
    }

    // MARK: - プレビュー

    func goToPage(_ page: Int) {
        let clamped = min(max(page, 0), max(pageCount - 1, 0))
        guard clamped != currentPage else { return }
        currentPage = clamped
        schedulePreview(debounce: false)
    }

    private func clampPage() {
        let last = max(pageCount - 1, 0)
        if currentPage > last { currentPage = last }
    }

    private func schedulePreview(debounce: Bool) {
        previewTask?.cancel()
        previewGeneration &+= 1
        let generation = previewGeneration
        guard layout.isValid, !items.isEmpty else {
            previewDocument = nil
            previewPageShown = nil
            isRenderingPreview = false
            return
        }
        let layout = self.layout
        let entries = items.map(\.entry)
        let page = currentPage
        let cache = previewCache
        let pageCount = self.pageCount
        isRenderingPreview = true
        previewTask = Task { [weak self] in
            if debounce { try? await Task.sleep(nanoseconds: 80_000_000) }
            if Task.isCancelled { return }
            let result = await Task.detached(priority: .userInitiated) {
                PreviewBuilder.renderPage(page, entries: entries, layout: layout, cache: cache)
            }.value
            guard let self, generation == self.previewGeneration else { return }
            self.previewDocument = PDFDocument(data: result.pdfData)
            self.previewPageShown = page
            self.missingIDs.subtract(result.pageIDs)
            self.missingIDs.formUnion(result.missingIDs)
            self.isRenderingPreview = false
            if page + 1 < pageCount {
                Task.detached(priority: .utility) {
                    PreviewBuilder.prefetch(page: page + 1, entries: entries, layout: layout, cache: cache)
                }
            }
        }
    }

    /// 現在の設定でファイル名が省略される画像を調べる
    private func scheduleTruncationCheck() {
        truncationTask?.cancel()
        guard layout.isValid, !items.isEmpty else {
            truncatedIDs = []
            return
        }
        let layout = self.layout
        let names = items.map { ($0.id, $0.fileName) }
        truncationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return }
            let truncated = await Task.detached(priority: .utility) { () -> Set<UUID> in
                let typesetter = LabelTypesetter(font: layout.font, maxWidth: layout.cellSize.width,
                                                 maxLines: SheetLayout.labelLineCount)
                var result = Set<UUID>()
                var cache: [String: Bool] = [:]
                for (id, name) in names {
                    let isTruncated = cache[name] ?? typesetter.layout(name).isTruncated
                    cache[name] = isTruncated
                    if isTruncated { result.insert(id) }
                }
                return result
            }.value
            guard let self, !Task.isCancelled else { return }
            self.truncatedIDs = truncated
        }
    }

    // MARK: - 保存

    func presentSavePanel() {
        guard canSave else { return }
        let panel = NSSavePanel()
        panel.title = "PDFを保存"
        panel.prompt = "保存"
        panel.message = "保存先とファイル名を指定してください。"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedFileName()
        // 同じ名前のファイルがある場合は、置き換えてよいかをこのパネルが確認する
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.startSave(to: url)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    private func suggestedFileName() -> String {
        let folders = Set(items.map { $0.url.deletingLastPathComponent().path })
        if folders.count == 1, let folder = items.first?.url.deletingLastPathComponent().lastPathComponent,
           !folder.isEmpty, folder != "/" {
            return "\(folder.precomposedStringWithCanonicalMapping)_画像一覧.pdf"
        }
        return "画像一覧.pdf"
    }

    func startSave(to url: URL) {
        guard canSave else { return }
        let entries = items.map(\.entry)
        let layout = self.layout
        let flag = CancelFlag()
        let totalPages = layout.pageCount(forImageCount: entries.count)
        saveStatus = nil
        saveProgress = SaveProgress(donePages: 0, totalPages: totalPages, cancelFlag: flag)
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
                Result {
                    try PDFExporter.export(entries: entries, layout: layout, to: url,
                                           isCancelled: { flag.isCancelled },
                                           progress: { done, _ in
                                               Task { @MainActor in AppModel.shared.updateSaveProgress(done) }
                                           })
                }
            }.value
            finishSave(result, url: url, pages: totalPages)
        }
    }

    func cancelSave() {
        saveProgress?.cancelFlag.cancel()
        saveProgress?.isCancelling = true
    }

    fileprivate func updateSaveProgress(_ done: Int) {
        guard saveProgress != nil else { return }
        saveProgress?.donePages = done
    }

    private func finishSave(_ result: Result<Void, Error>, url: URL, pages: Int) {
        saveProgress = nil
        switch result {
        case .success:
            saveStatus = StatusMessage(kind: .success,
                                       text: "保存しました：\(url.lastPathComponent)（全\(pages)ページ）",
                                       revealURL: url)
        case .failure(let error as SheetError) where error == .cancelled:
            saveStatus = StatusMessage(kind: .info,
                                       text: "保存を中止しました。保存先のファイルは作成・変更していません。",
                                       revealURL: nil)
        case .failure(let error):
            alert = AlertInfo(title: "PDFを保存できませんでした",
                              message: "\(error.localizedDescription)\n\n保存先のファイルは作成・変更していません。")
        }
    }
}

/// ドロップされたファイルのURLを集める
private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func append(_ url: URL) {
        lock.lock(); storage.append(url); lock.unlock()
    }

    var urls: [URL] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
