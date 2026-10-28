import Foundation

/// 途中で切れた画像ファイルの検出。
/// ImageIO は途中で切れた JPEG・PNG も残りを灰色で埋めて読み込むため、ファイルの終端を直接確かめる。
enum ImageIntegrity {
    static func isTruncated(_ url: URL, typeIdentifier: String) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return false }
        return data.withUnsafeBytes { buffer -> Bool in
            let bytes = buffer.bindMemory(to: UInt8.self)
            switch typeIdentifier {
            case "public.jpeg": return isTruncatedJPEG(bytes)
            case "public.png": return isTruncatedPNG(bytes)
            default: return false
            }
        }
    }

    /// 画像データ（SOS以降）の後に終端マーカー（FFD9）があるか。
    /// Exifのサムネイルなど途中のセグメントは長さで読み飛ばす。終端の後ろに付いたデータ（動画付き写真など）は問題にしない。
    private static func isTruncatedJPEG(_ d: UnsafeBufferPointer<UInt8>) -> Bool {
        let n = d.count
        guard n >= 4, d[0] == 0xFF, d[1] == 0xD8 else { return false }
        var i = 2
        var inScan = false
        while i + 1 < n {
            if !inScan {
                guard d[i] == 0xFF else { return false }   // 想定外の構造は判定しない（ImageIOに任せる）
                let marker = d[i + 1]
                if marker == 0xFF { i += 1; continue }
                if marker == 0xD9 { return false }
                if marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
                guard i + 3 < n else { return true }
                let length = Int(d[i + 2]) << 8 | Int(d[i + 3])
                i += 2 + length
                if marker == 0xDA { inScan = true }
                continue
            }
            // 圧縮データ内：FF00（値のFF）とRSTマーカー以外のマーカーを探す
            if d[i] != 0xFF { i += 1; continue }
            let marker = d[i + 1]
            if marker == 0x00 || marker == 0xFF || (0xD0...0xD7).contains(marker) { i += 1; continue }
            if marker == 0xD9 { return false }
            // 次のセグメント（プログレッシブJPEGのDHT・SOSなど）
            guard i + 3 < n else { return true }
            let length = Int(d[i + 2]) << 8 | Int(d[i + 3])
            i += 2 + length
        }
        return true
    }

    /// 最後のチャンク（IEND）まで揃っているか
    private static func isTruncatedPNG(_ d: UnsafeBufferPointer<UInt8>) -> Bool {
        let n = d.count
        guard n >= 8 else { return false }
        var i = 8
        while i + 8 <= n {
            let length = Int(d[i]) << 24 | Int(d[i + 1]) << 16 | Int(d[i + 2]) << 8 | Int(d[i + 3])
            let isEnd = d[i + 4] == 0x49 && d[i + 5] == 0x45 && d[i + 6] == 0x4E && d[i + 7] == 0x44   // "IEND"
            let next = i + 12 + length
            if isEnd { return next > n }
            if length < 0 || next > n { return true }
            i = next
        }
        return true
    }
}
