import XCTest
import CoreVideo
import ImageIO
@testable import GameCapture

final class FrameTapTests: XCTestCase {
    private func buffer(_ format: OSType, width: Int, height: Int) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, format, attributes, &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if format == kCVPixelFormatType_32BGRA {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height { for x in 0..<width {
                let p = base + y * stride + x * 4
                p[0] = 0; p[1] = 0; p[2] = 255; p[3] = 255 // opaque red
            } }
        } else {
            // Video-range mid grey: Y 126, Cb/Cr 128.
            for plane in 0..<2 {
                let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
                memset(base, plane == 0 ? 126 : 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
            }
        }
        return buffer
    }

    private func decode(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func centerPixel(_ image: CGImage) -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        return pixel
    }

    func testBGRADownscaleKeepsAspectAndColor() throws {
        let frame = try buffer(kCVPixelFormatType_32BGRA, width: 1920, height: 1080)
        let result = try FrameTap.png(frame, maxWidth: 640)
        XCTAssertEqual(result.width, 640); XCTAssertEqual(result.height, 360)
        let image = try decode(result.data)
        XCTAssertEqual(image.width, 640); XCTAssertEqual(image.height, 360)
        let pixel = centerPixel(image)
        XCTAssertGreaterThan(pixel[0], 200); XCTAssertLessThan(pixel[1], 40); XCTAssertLessThan(pixel[2], 40)
    }

    func testBiPlanarVideoRangeDecodesAndNeverUpscales() throws {
        let frame = try buffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, width: 1280, height: 720)
        let result = try FrameTap.png(frame, maxWidth: 3840)
        XCTAssertEqual(result.width, 1280); XCTAssertEqual(result.height, 720)
        let image = try decode(result.data)
        XCTAssertEqual(image.width, 1280); XCTAssertEqual(image.height, 720)
        let pixel = centerPixel(image)
        XCTAssertLessThan(abs(Int(pixel[0]) - Int(pixel[1])), 12)
        XCTAssertLessThan(abs(Int(pixel[1]) - Int(pixel[2])), 12)
        let small = try FrameTap.png(frame, maxWidth: 320)
        XCTAssertEqual(small.width, 320); XCTAssertEqual(small.height, 180)
        XCTAssertNoThrow(try decode(small.data))
    }

    func testLatestClearAndMonotonicSequence() throws {
        let tap = FrameTap()
        XCTAssertNil(tap.latest())
        let frame = try buffer(kCVPixelFormatType_32BGRA, width: 64, height: 36)
        tap.store(frame)
        let first = try XCTUnwrap(tap.latest())
        XCTAssertTrue(first.buffer === frame)
        tap.store(frame)
        let second = try XCTUnwrap(tap.latest())
        XCTAssertGreaterThan(second.seq, first.seq)
        XCTAssertGreaterThanOrEqual(second.arrivedAt, first.arrivedAt)
        tap.clear()
        XCTAssertNil(tap.latest())
        tap.store(frame)
        XCTAssertGreaterThan(try XCTUnwrap(tap.latest()).seq, second.seq)
    }
}
