import Foundation
import UniformTypeIdentifiers

/// ファイル名順（Finderと同じ、数字を含む名前は 1, 2, 10 の順）
public enum FileNameOrder {
    public static func precedes(name a: String, path pathA: String, name b: String, path pathB: String) -> Bool {
        switch a.localizedStandardCompare(b) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return pathA.localizedStandardCompare(pathB) == .orderedAscending
        }
    }
}

/// ドロップ・選択されたファイルから、取り込む対象を決める
public struct ImportPlan: Sendable {
    public var files: [URL] = []
    /// 重複判定用のキー（files と同じ順）
    public var keys: [String] = []
    /// すでに一覧にある・同じ操作で重複していたため除いた件数
    public var duplicateCount = 0
    /// フォルダ内の画像以外のファイルの件数
    public var skippedNonImages = 0
    /// フォルダ内のフォルダの件数（中は読み込まない）
    public var skippedFolders = 0

    public init() {}

    /// フォルダが含まれる場合は、その直下の画像を対象にする
    public static func make(from urls: [URL], excluding knownKeys: Set<String>) -> ImportPlan {
        var plan = ImportPlan()
        var seen = knownKeys
        func addFile(_ url: URL) {
            let key = FileIdentity.key(for: url)
            if seen.contains(key) {
                plan.duplicateCount += 1
            } else {
                seen.insert(key)
                plan.files.append(url)
                plan.keys.append(key)
            }
        }
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            guard values?.isDirectory == true, values?.isPackage != true else {
                addFile(url)
                continue
            }
            let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            for child in contents {
                let childValues = try? child.resourceValues(forKeys: Set(keys))
                if childValues?.isDirectory == true {
                    plan.skippedFolders += 1
                } else if let type = UTType(filenameExtension: child.pathExtension), type.conforms(to: .image) {
                    addFile(child)
                } else {
                    plan.skippedNonImages += 1
                }
            }
        }
        return plan
    }
}

public enum FileIdentity {
    /// 同じファイルかどうかを判定するキー。別名（シンボリックリンク）やハードリンクでも同じになる。
    public static func key(for url: URL) -> String {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        if let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
           let device = attributes[.systemNumber] as? NSNumber,
           let inode = attributes[.systemFileNumber] as? NSNumber {
            return "\(device.uint64Value):\(inode.uint64Value)"
        }
        return resolved.path
    }
}
