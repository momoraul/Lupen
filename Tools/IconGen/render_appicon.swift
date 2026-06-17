// swift-tools-version:5.9
//
// render_appicon.swift — Lupen app icon generator.
//
// Renders the macOS app icon: twin gold-ring lenses (Lupen — the lens
// pair from the brand banner) on the dark-navy night plate. The plate
// is clean (no starfield) and each lens carries a single soft gloss
// crescent in the upper-left, matching the banner's lens grammar:
// gold gradient rings, near-black glass, one curved-glass reflection —
// no irises, no pupils, no beak (docs/branding/lupen-final/README.md).
//
// Deterministic: same input → byte-identical PNGs. Each size renders
// at its native pixel size (vector redraw, not downscaling).
//
// Run:
//     swift Tools/IconGen/render_appicon.swift [appiconset-dir]
// Default output dir: Lupen/App/Resources/Assets.xcassets/AppIcon.appiconset
//
// Author: jaden

import Foundation
import AppKit
import CoreGraphics

// MARK: - Palette
//
// Same midnight plate as the previous icon (continuity in the Dock);
// ring golds sampled against the banner lockup — bright crest up top
// falling to deep amber at the bottom of the ring.

enum P {
    static let bgTop     = NSColor(srgbRed: 0.043, green: 0.086, blue: 0.188, alpha: 1.0)  // #0B1630
    static let bgBottom  = NSColor(srgbRed: 0.129, green: 0.188, blue: 0.290, alpha: 1.0)  // #21304A
    static let goldHi    = NSColor(srgbRed: 0.992, green: 0.871, blue: 0.557, alpha: 1.0)  // #FDDE8E
    static let goldMid   = NSColor(srgbRed: 0.984, green: 0.745, blue: 0.322, alpha: 1.0)  // #FBBE52
    static let goldDeep  = NSColor(srgbRed: 0.851, green: 0.639, blue: 0.255, alpha: 1.0)  // #D9A341
    static let glassEdge = NSColor(srgbRed: 0.020, green: 0.039, blue: 0.090, alpha: 1.0)  // #050A17
    static let glassCore = NSColor(srgbRed: 0.051, green: 0.078, blue: 0.137, alpha: 1.0)  // #0D1423
}

// MARK: - Image scaffolding

enum Renderer {
    static func render(width w: Int, height h: Int, draw: (CGContext, CGFloat, CGFloat) -> Void) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0, bitsPerPixel: 32
        )!
        NSGraphicsContext.saveGraphicsState()
        let g = NSGraphicsContext(bitmapImageRep: rep)!
        g.imageInterpolation = .high
        NSGraphicsContext.current = g
        let ctx = g.cgContext
        draw(ctx, CGFloat(w), CGFloat(h))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    static func write(_ data: Data, to path: String) {
        let url = URL(fileURLWithPath: path)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! data.write(to: url)
        print("✓ \(url.lastPathComponent)")
    }

    /// Standard squircle clip (Apple-icon corner ratio ≈ 22.37%).
    static func clipSquircle(_ ctx: CGContext, _ rect: CGRect) {
        let r = min(rect.width, rect.height) * 0.2237
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.clip()
    }

    static func diagonalGradient(_ ctx: CGContext, rect: CGRect, top: NSColor, bottom: NSColor) {
        let cs = CGColorSpaceCreateDeviceRGB()
        let g = CGGradient(colorsSpace: cs, colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    }

    static func radialGlow(_ ctx: CGContext, center: CGPoint, radius: CGFloat, color: NSColor, innerAlpha: CGFloat = 0.4) {
        let cs = CGColorSpaceCreateDeviceRGB()
        let g = CGGradient(
            colorsSpace: cs,
            colors: [color.withAlphaComponent(innerAlpha).cgColor, color.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1]
        )!
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }
}

// MARK: - Lens drawing

enum LupenIcon {

    /// One lens: gold gradient ring + dark glass + gloss highlights.
    /// All geometry is proportional to `R` so every icon size redraws
    /// the same construction.
    private static func drawLens(_ ctx: CGContext, center c: CGPoint, R: CGFloat) {
        let cs = CGColorSpaceCreateDeviceRGB()
        let inner = R * 0.72

        // --- Gold ring: vertical gradient clipped to the annulus.
        // Bright crest on top, deep amber underneath — the banner's
        // ring lighting.
        ctx.saveGState()
        let ringPath = CGMutablePath()
        ringPath.addArc(center: c, radius: R, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        ringPath.addArc(center: c, radius: inner, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        ctx.addPath(ringPath)
        ctx.clip(using: .evenOdd)
        let ringGrad = CGGradient(
            colorsSpace: cs,
            colors: [P.goldHi.cgColor, P.goldMid.cgColor, P.goldDeep.cgColor] as CFArray,
            locations: [0, 0.45, 1]
        )!
        ctx.drawLinearGradient(
            ringGrad,
            start: CGPoint(x: c.x, y: c.y + R),
            end: CGPoint(x: c.x, y: c.y - R),
            options: []
        )
        // Thin bright lip along the ring's very top edge — sells the
        // metallic rounding at large sizes, harmless when tiny.
        ctx.setStrokeColor(P.goldHi.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(R * 0.025)
        ctx.addArc(center: c, radius: R - R * 0.015, startAngle: .pi * 0.15, endAngle: .pi * 0.85, clockwise: false)
        ctx.strokePath()
        ctx.restoreGState()

        // --- Glass: near-black dish, slightly lighter toward the
        // center so it reads as depth, not a flat hole.
        ctx.saveGState()
        ctx.addArc(center: c, radius: inner, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        ctx.clip()
        let glassGrad = CGGradient(
            colorsSpace: cs,
            colors: [P.glassCore.cgColor, P.glassEdge.cgColor] as CFArray,
            locations: [0, 1]
        )!
        ctx.drawRadialGradient(
            glassGrad,
            startCenter: CGPoint(x: c.x, y: c.y + inner * 0.16), startRadius: 0,
            endCenter: c, endRadius: inner,
            options: []
        )

        // --- Gloss: form and brightness are separated to avoid every
        // earlier failure. FORM = a rim-hugging band between two
        // CONCENTRIC circles (concentric ⇒ never intersect ⇒ no cusp;
        // both edges are rim-parallel curves ⇒ no straight line). This
        // confines the gloss to a crescent that follows the rim, never
        // a centred blob (eye). BRIGHTNESS = an upper-left RADIAL that
        // lights only the upper-left of that band and fades to nothing
        // by the right (circular falloff ⇒ no hard diagonal edge). The
        // result is the banner's rim-following specular sickle.
        ctx.saveGState()
        let warmWhite = NSColor(srgbRed: 1.0, green: 0.99, blue: 0.94, alpha: 1.0)
        let band = CGMutablePath()
        band.addArc(center: c, radius: inner * 0.90, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        band.addArc(center: c, radius: inner * 0.70, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        ctx.addPath(band)
        ctx.clip(using: .evenOdd)
        let gc = CGPoint(x: c.x - inner * 0.38, y: c.y + inner * 0.50)
        let glossGrad = CGGradient(
            colorsSpace: cs,
            colors: [warmWhite.withAlphaComponent(0.78).cgColor,
                     warmWhite.withAlphaComponent(0.28).cgColor,
                     warmWhite.withAlphaComponent(0.0).cgColor] as CFArray,
            locations: [0, 0.42, 1]
        )!
        ctx.drawRadialGradient(
            glossGrad,
            startCenter: gc, startRadius: 0,
            endCenter: gc, endRadius: inner * 0.74,
            options: []
        )
        ctx.restoreGState()

        // Bottom bounce: a faint warm sliver where the gold barrel
        // reflects into the lower glass — sells a convex lens catching
        // light, not a flat black hole.
        ctx.saveGState()
        let bounce = CGMutablePath()
        bounce.addArc(center: c, radius: inner * 0.93,
                      startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        bounce.addArc(center: CGPoint(x: c.x, y: c.y + inner * 0.40),
                      radius: inner * 0.86,
                      startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        ctx.addPath(bounce)
        ctx.clip(using: .evenOdd)
        let bounceGrad = CGGradient(
            colorsSpace: cs,
            colors: [P.goldMid.withAlphaComponent(0.0).cgColor,
                     P.goldMid.withAlphaComponent(0.11).cgColor] as CFArray,
            locations: [0, 1]
        )!
        ctx.drawLinearGradient(
            bounceGrad,
            start: CGPoint(x: c.x, y: c.y - inner * 0.45),
            end: CGPoint(x: c.x, y: c.y - inner * 0.92),
            options: []
        )
        ctx.restoreGState()

        ctx.restoreGState()  // glass clip
    }

    static func render(side: CGFloat) -> Data {
        Renderer.render(width: Int(side), height: Int(side)) { ctx, w, h in
            // macOS icon grid: the squircle plate fills ~80.5% of the
            // canvas (Apple Notes/Maps measure the same), leaving a ~10%
            // transparent margin the system uses for the drop shadow and
            // Dock spacing. A full-bleed plate reads as an amateur icon
            // and overhangs neighbouring apps in the Dock.
            let margin = (w * 0.0975).rounded()
            let plate = CGRect(x: margin, y: margin, width: w - 2 * margin, height: h - 2 * margin)
            let pw = plate.width
            ctx.saveGState()
            Renderer.clipSquircle(ctx, plate)
            Renderer.diagonalGradient(ctx, rect: plate, top: P.bgTop, bottom: P.bgBottom)

            // Centre glow behind the lens pair.
            Renderer.radialGlow(
                ctx, center: CGPoint(x: plate.midX, y: plate.midY), radius: pw * 0.55,
                color: NSColor(srgbRed: 0.4, green: 0.5, blue: 0.7, alpha: 1), innerAlpha: 0.22
            )

            // Twin lenses — fused pair within the plate (centers 0.285/
            // 0.715, R 0.225 of the plate ⇒ rings just touch).
            let R = pw * 0.225
            drawLens(ctx, center: CGPoint(x: plate.minX + pw * 0.285, y: plate.minY + pw * 0.50), R: R)
            drawLens(ctx, center: CGPoint(x: plate.minX + pw * 0.715, y: plate.minY + pw * 0.50), R: R)

            ctx.restoreGState()
        }
    }
}

// MARK: - Entry point

let defaultOut = "Lupen/App/Resources/Assets.xcassets/AppIcon.appiconset"
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : defaultOut

// Filename → pixel size, mirroring the appiconset's Contents.json.
let sizes: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, side) in sizes {
    Renderer.write(LupenIcon.render(side: side), to: outDir + "/" + name)
}
print("Lupen app icon rendered → \(outDir)")
