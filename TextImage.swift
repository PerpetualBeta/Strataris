// Strataris — Unicode text rasteriser.
//
// The HUD uses a fast 5×7 bitmap font (Font.swift), but high-score names must
// accept ANY text the player types — accents, CJK, emoji, the lot. Those can't
// come from a 96-glyph bitmap, so we render arbitrary Strings through Core Text
// into an RGBA bitmap and composite it over the scene. Used only on the
// (frozen) score / name-entry screens, so per-frame rasterisation is fine.

import Foundation
import CoreGraphics
import CoreText

enum TextImage {
    struct Bitmap { let pixels: [UInt32]; let w: Int; let h: Int }

    /// Rasterise `string` at `fontSize` in the given colour. Pixels are packed
    /// RGBA with PREMULTIPLIED colour (composite with: out = src + dst*(1-a)),
    /// already flipped to our top-down framebuffer orientation.
    static func rasterize(_ string: String, fontSize: CGFloat,
                          r: CGFloat, g: CGFloat, b: CGFloat) -> Bitmap? {
        if string.isEmpty { return nil }
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let color = CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
        guard let cfAttr = CFAttributedStringCreate(kCFAllocatorDefault, string as CFString, attrs as CFDictionary)
        else { return nil }
        let line = CTLineCreateWithAttributedString(cfAttr)

        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let widthD = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let w = max(1, Int(widthD.rounded(.up)) + 2)
        let h = max(1, Int((ascent + descent).rounded(.up)) + 2)

        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue   // bytes R,G,B,A → our packed format
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs, bitmapInfo: info),
              let data = ctx.data else { return nil }
        ctx.textPosition = CGPoint(x: 1, y: descent + 1)
        CTLineDraw(line, ctx)

        // This bitmap context is already top-down (verified empirically), so
        // copy straight out — no vertical flip (that flipped text upside down).
        let src = data.bindMemory(to: UInt32.self, capacity: w * h)
        let out = Array(UnsafeBufferPointer(start: src, count: w * h))
        return Bitmap(pixels: out, w: w, h: h)
    }
}
