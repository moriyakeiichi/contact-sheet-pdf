// アプリアイコン（1024×1024 PNG）を描く。使い方: swift make_icon.swift 出力先.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

// 背景（角丸の正方形・青のグラデーション）
let base = CGRect(x: 100, y: 100, width: 824, height: 824)
let basePath = CGPath(roundedRect: base, cornerWidth: 185, cornerHeight: 185, transform: nil)
context.saveGState()
context.addPath(basePath)
context.clip()
let gradient = CGGradient(colorsSpace: space,
                          colors: [color(0.20, 0.50, 0.95), color(0.10, 0.30, 0.75)] as CFArray,
                          locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
context.restoreGState()

// 用紙（A4の比率）
let paper = CGRect(x: 512 - 250, y: 512 - 330, width: 500, height: 660)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0, 0, 0, 0.35))
context.setFillColor(color(1, 1, 1))
context.fill(paper)
context.restoreGState()

// 3×3 の写真と、その下のファイル名の線
let tileColors: [CGColor] = [
    color(0.98, 0.62, 0.25), color(0.35, 0.75, 0.45), color(0.30, 0.60, 0.95),
    color(0.85, 0.40, 0.55), color(0.95, 0.80, 0.30), color(0.45, 0.80, 0.85),
    color(0.60, 0.50, 0.90), color(0.40, 0.70, 0.40), color(0.95, 0.50, 0.40),
]
let margin: CGFloat = 40
let gap: CGFloat = 26
let cellWidth = (paper.width - margin * 2 - gap * 2) / 3
let cellHeight = (paper.height - margin * 2 - gap * 2) / 3
for row in 0..<3 {
    for column in 0..<3 {
        let x = paper.minX + margin + CGFloat(column) * (cellWidth + gap)
        let top = paper.maxY - margin - CGFloat(row) * (cellHeight + gap)
        let photoHeight = cellHeight - 34
        let photo = CGRect(x: x, y: top - photoHeight, width: cellWidth, height: photoHeight)
        context.setFillColor(tileColors[row * 3 + column])
        context.fill(photo)
        // 山の形
        context.setFillColor(color(1, 1, 1, 0.45))
        context.move(to: CGPoint(x: photo.minX, y: photo.minY))
        context.addLine(to: CGPoint(x: photo.minX + photo.width * 0.42, y: photo.minY + photo.height * 0.62))
        context.addLine(to: CGPoint(x: photo.minX + photo.width * 0.70, y: photo.minY + photo.height * 0.30))
        context.addLine(to: CGPoint(x: photo.maxX, y: photo.minY + photo.height * 0.5))
        context.addLine(to: CGPoint(x: photo.maxX, y: photo.minY))
        context.closePath()
        context.fillPath()
        // ファイル名
        context.setFillColor(color(0.55, 0.58, 0.63))
        let lineWidth = cellWidth * 0.8
        context.fill(CGRect(x: x + (cellWidth - lineWidth) / 2, y: photo.minY - 22, width: lineWidth, height: 9))
    }
}

let image = context.makeImage()!
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
