// Strataris — minimal 5×7 bitmap font for HUD text.
//
// Each glyph is 7 rows; the low 5 bits of each row are columns, bit 4 (0b10000)
// leftmost. Drawn straight into the packed-RGBA framebuffer with an optional
// 1px shadow so it reads over any terrain or sky. Covers 0-9, A-Z, space, and
// a few symbols — enough for the HUD now and score/title screens later.

import Foundation

enum Font {
    static let cellW = 5
    static let cellH = 7

    static func draw(_ text: String, into fb: UnsafeMutablePointer<UInt32>, w: Int, h: Int,
                     x: Int, y: Int, scale: Int = 1, color: UInt32,
                     shadow: UInt32? = packRGBA(0, 0, 0)) {
        var penX = x
        for ch in text.uppercased() {
            let glyph = glyphs[ch] ?? glyphs[" "]!
            if let sh = shadow {
                blit(glyph, into: fb, w: w, h: h, x: penX + scale, y: y + scale, scale: scale, color: sh)
            }
            blit(glyph, into: fb, w: w, h: h, x: penX, y: y, scale: scale, color: color)
            penX += (cellW + 1) * scale
        }
    }

    /// Pixel width a string will occupy at a given scale.
    static func width(_ text: String, scale: Int = 1) -> Int {
        return text.count * (cellW + 1) * scale
    }

    private static func blit(_ glyph: [UInt8], into fb: UnsafeMutablePointer<UInt32>, w: Int, h: Int,
                             x: Int, y: Int, scale: Int, color: UInt32) {
        for row in 0..<cellH {
            let bits = glyph[row]
            for col in 0..<cellW {
                if bits & (UInt8(1) << (cellW - 1 - col)) == 0 { continue }
                for sy in 0..<scale {
                    let py = y + row * scale + sy
                    if py < 0 || py >= h { continue }
                    let base = py * w
                    for sx in 0..<scale {
                        let px = x + col * scale + sx
                        if px >= 0 && px < w { fb[base + px] = color }
                    }
                }
            }
        }
    }

    static let glyphs: [Character: [UInt8]] = [
        " ": [0,0,0,0,0,0,0],
        "0": [0b01110,0b10001,0b10011,0b10101,0b11001,0b10001,0b01110],
        "1": [0b00100,0b01100,0b00100,0b00100,0b00100,0b00100,0b01110],
        "2": [0b01110,0b10001,0b00001,0b00010,0b00100,0b01000,0b11111],
        "3": [0b11111,0b00010,0b00100,0b00010,0b00001,0b10001,0b01110],
        "4": [0b00010,0b00110,0b01010,0b10010,0b11111,0b00010,0b00010],
        "5": [0b11111,0b10000,0b11110,0b00001,0b00001,0b10001,0b01110],
        "6": [0b00110,0b01000,0b10000,0b11110,0b10001,0b10001,0b01110],
        "7": [0b11111,0b00001,0b00010,0b00100,0b01000,0b01000,0b01000],
        "8": [0b01110,0b10001,0b10001,0b01110,0b10001,0b10001,0b01110],
        "9": [0b01110,0b10001,0b10001,0b01111,0b00001,0b00010,0b01100],
        "A": [0b01110,0b10001,0b10001,0b11111,0b10001,0b10001,0b10001],
        "B": [0b11110,0b10001,0b10001,0b11110,0b10001,0b10001,0b11110],
        "C": [0b01110,0b10001,0b10000,0b10000,0b10000,0b10001,0b01110],
        "D": [0b11110,0b10001,0b10001,0b10001,0b10001,0b10001,0b11110],
        "E": [0b11111,0b10000,0b10000,0b11110,0b10000,0b10000,0b11111],
        "F": [0b11111,0b10000,0b10000,0b11110,0b10000,0b10000,0b10000],
        "G": [0b01110,0b10001,0b10000,0b10111,0b10001,0b10001,0b01111],
        "H": [0b10001,0b10001,0b10001,0b11111,0b10001,0b10001,0b10001],
        "I": [0b01110,0b00100,0b00100,0b00100,0b00100,0b00100,0b01110],
        "J": [0b00111,0b00010,0b00010,0b00010,0b00010,0b10010,0b01100],
        "K": [0b10001,0b10010,0b10100,0b11000,0b10100,0b10010,0b10001],
        "L": [0b10000,0b10000,0b10000,0b10000,0b10000,0b10000,0b11111],
        "M": [0b10001,0b11011,0b10101,0b10101,0b10001,0b10001,0b10001],
        "N": [0b10001,0b11001,0b10101,0b10011,0b10001,0b10001,0b10001],
        "O": [0b01110,0b10001,0b10001,0b10001,0b10001,0b10001,0b01110],
        "P": [0b11110,0b10001,0b10001,0b11110,0b10000,0b10000,0b10000],
        "Q": [0b01110,0b10001,0b10001,0b10001,0b10101,0b10010,0b01101],
        "R": [0b11110,0b10001,0b10001,0b11110,0b10100,0b10010,0b10001],
        "S": [0b01111,0b10000,0b10000,0b01110,0b00001,0b00001,0b11110],
        "T": [0b11111,0b00100,0b00100,0b00100,0b00100,0b00100,0b00100],
        "U": [0b10001,0b10001,0b10001,0b10001,0b10001,0b10001,0b01110],
        "V": [0b10001,0b10001,0b10001,0b10001,0b10001,0b01010,0b00100],
        "W": [0b10001,0b10001,0b10001,0b10101,0b10101,0b11011,0b10001],
        "X": [0b10001,0b10001,0b01010,0b00100,0b01010,0b10001,0b10001],
        "Y": [0b10001,0b10001,0b01010,0b00100,0b00100,0b00100,0b00100],
        "Z": [0b11111,0b00001,0b00010,0b00100,0b01000,0b10000,0b11111],
        ":": [0b00000,0b00100,0b00100,0b00000,0b00100,0b00100,0b00000],
        "/": [0b00001,0b00010,0b00010,0b00100,0b01000,0b01000,0b10000],
        "-": [0b00000,0b00000,0b00000,0b11111,0b00000,0b00000,0b00000],
        ".": [0b00000,0b00000,0b00000,0b00000,0b00000,0b00110,0b00110],
    ]
}
