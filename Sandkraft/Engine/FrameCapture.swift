//
//  FrameCapture.swift
//  Sandkraft
//
//  Turning a presented frame into a PNG.
//
//  The whole subject of this game is a beautiful thing that the tide takes
//  away. Until now it took the only copy with it.
//
//  This photographs the *drawable* rather than re-rendering the scene at some
//  larger size. A separate high-resolution path would mean a second set of
//  targets, a second shadow fit, and a bloom radius that no longer matches the
//  one the look was tuned against — a picture of a slightly different game. The
//  drawable is already the composited frame, complete with grade, bloom, ink and
//  grain, and on a Retina display it is 2× the window anyway.
//
//  It works at all only because `MetalSceneView` sets `framebufferOnly = false`.
//  A drawable is write-only by default and the blit below would fail.
//

import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum FrameCapture {

    /// Encode BGRA8 sRGB bytes — the drawable's own format — as PNG.
    ///
    /// Returns nil rather than throwing: a failed photograph is a thing the
    /// interface reports and shrugs at, not an error worth propagating through
    /// the render loop.
    static func png(from buffer: MTLBuffer, width: Int, height: Int) -> Data? {
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height
        guard buffer.length >= byteCount else { return nil }

        // Copied rather than wrapped. The buffer belongs to the frame that has
        // just completed and the encode happens off the render thread; handing
        // CoreGraphics a pointer into GPU-shared memory with no ownership is how
        // you get a photograph of the frame after this one.
        let data = Data(bytes: buffer.contents(), count: byteCount)

        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        // `bgra8Unorm_srgb` in CoreGraphics terms: 32-bit little-endian with the
        // ignored byte first. Get this pair wrong and the sea comes out orange.
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)

        guard let image = CGImage(width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow,
                                  space: space,
                                  bitmapInfo: bitmapInfo,
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent) else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
                output, UTType.png.identifier as CFString, 1, nil) else { return nil }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }

        return output as Data
    }

    /// A filename with the moment in it, because a folder of `Sandkraft.png`,
    /// `Sandkraft-1.png`, `Sandkraft-2.png` tells you nothing about which castle
    /// is which.
    static func suggestedFilename(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Sandkraft \(formatter.string(from: date))"
    }
}
