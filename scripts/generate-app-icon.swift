#!/usr/bin/env swift
// Generates Assets/AppIcon.icns (and a 1024px preview PNG) from pure CoreGraphics
// drawing code — no design tool needed. Rerun after changing the artwork:
//
//   swift scripts/generate-app-icon.swift
//
// The artwork: a dark macOS squircle with the MacBook notch hanging from its top
// edge and a glowing agent-status dot beneath it — the same motif as the menu bar
// template icon in Sources/NotchApp/MenuBarIcon.swift.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Drawing (parameterized by canvas size; all coordinates are fractions of 1024)

func drawIcon(into ctx: CGContext, size: CGFloat) {
    let s = size / 1024.0
    func p(_ v: CGFloat) -> CGFloat { v * s }

    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

    // macOS icon grid: the squircle occupies 824x824 centered in a 1024 canvas.
    let squircle = CGRect(x: p(100), y: p(100), width: p(824), height: p(824))
    let squirclePath = CGPath(roundedRect: squircle, cornerWidth: p(185), cornerHeight: p(185), transform: nil)

    // Drop shadow behind the squircle (standard for macOS icons).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: p(-12)), blur: p(24),
                  color: CGColor(gray: 0, alpha: 0.30))
    ctx.addPath(squirclePath)
    ctx.setFillColor(CGColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Background: vertical dark gradient, slightly bluish like a powered-off display.
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let bg = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.20, green: 0.22, blue: 0.27, alpha: 1),
        CGColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg,
                           start: CGPoint(x: size / 2, y: squircle.maxY),
                           end: CGPoint(x: size / 2, y: squircle.minY),
                           options: [])

    // Faint top rim highlight to give the slab some depth.
    ctx.addPath(CGPath(roundedRect: squircle.insetBy(dx: p(3), dy: p(3)),
                       cornerWidth: p(182), cornerHeight: p(182), transform: nil))
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.07))
    ctx.setLineWidth(p(6))
    ctx.strokePath()

    // The notch: hangs from the squircle's top edge, bottom corners rounded.
    let notchWidth = p(440), notchHeight = p(132), notchRadius = p(44)
    let notchLeft = (size - notchWidth) / 2
    let notchTop = squircle.maxY
    let notchBottom = notchTop - notchHeight
    let notch = CGMutablePath()
    notch.move(to: CGPoint(x: notchLeft, y: notchTop))
    notch.addLine(to: CGPoint(x: notchLeft, y: notchBottom + notchRadius))
    notch.addArc(tangent1End: CGPoint(x: notchLeft, y: notchBottom),
                 tangent2End: CGPoint(x: notchLeft + notchRadius, y: notchBottom), radius: notchRadius)
    notch.addLine(to: CGPoint(x: notchLeft + notchWidth - notchRadius, y: notchBottom))
    notch.addArc(tangent1End: CGPoint(x: notchLeft + notchWidth, y: notchBottom),
                 tangent2End: CGPoint(x: notchLeft + notchWidth, y: notchBottom + notchRadius), radius: notchRadius)
    notch.addLine(to: CGPoint(x: notchLeft + notchWidth, y: notchTop))
    notch.closeSubpath()
    ctx.addPath(notch)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()

    // Hairline under the notch edge so it separates from the background at large sizes.
    ctx.addPath(notch)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
    ctx.setLineWidth(p(4))
    ctx.strokePath()

    // Status dot: radial glow, bright core, small specular highlight.
    let dotCenter = CGPoint(x: size / 2, y: p(470))
    let dotRadius = p(96)
    let glow = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.20, green: 0.83, blue: 0.60, alpha: 0.55),
        CGColor(red: 0.20, green: 0.83, blue: 0.60, alpha: 0.0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: dotCenter, startRadius: 0,
                           endCenter: dotCenter, endRadius: p(330), options: [])
    let core = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.55, green: 0.96, blue: 0.81, alpha: 1),
        CGColor(red: 0.06, green: 0.73, blue: 0.51, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(core, startCenter: CGPoint(x: dotCenter.x - p(20), y: dotCenter.y + p(24)),
                           startRadius: 0, endCenter: dotCenter, endRadius: dotRadius, options: [])
    let spec = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.75),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray, locations: [0, 1])!
    let specCenter = CGPoint(x: dotCenter.x - p(30), y: dotCenter.y + p(36))
    ctx.drawRadialGradient(spec, startCenter: specCenter, startRadius: 0,
                           endCenter: specCenter, endRadius: p(34), options: [])
    ctx.restoreGState()
}

// MARK: - Rendering + icns assembly

func render(pixels: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    drawIcon(into: ctx, size: CGFloat(pixels))
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("failed to write \(url.path)") }
}

let root = URL(fileURLWithPath: CommandLine.arguments[0])
    .resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("Assets")
let iconset = assets.appendingPathComponent("AppIcon.iconset")
let fm = FileManager.default
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

// (points, scale) pairs required by iconutil.
let variants: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                              (256, 1), (256, 2), (512, 1), (512, 2)]
for (points, scale) in variants {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    writePNG(render(pixels: points * scale), to: iconset.appendingPathComponent(name))
}
writePNG(render(pixels: 1024), to: assets.appendingPathComponent("AppIcon-preview.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try fm.removeItem(at: iconset)
print("Wrote \(assets.path)/AppIcon.icns and AppIcon-preview.png")
