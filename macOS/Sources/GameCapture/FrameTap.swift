import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Keeps a reference to the newest captured frame (before effects) for agent snapshots.
/// `store` runs on the capture frame queue and only swaps a reference under a lock.
final class FrameTap: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var sequence: UInt64 = 0
    private var arrived = 0.0
    private static let context = CIContext(options: [.cacheIntermediates: false])

    func store(_ buffer: CVPixelBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); self.buffer = buffer; sequence &+= 1; arrived = now; lock.unlock()
    }
    func clear() {
        lock.lock(); buffer = nil; lock.unlock()
    }
    /// `arrivedAt` is `ProcessInfo.systemUptime` seconds; `seq` never repeats within a run.
    func latest() -> (buffer: CVPixelBuffer, seq: UInt64, arrivedAt: Double)? {
        lock.lock(); defer { lock.unlock() }
        guard let buffer else { return nil }
        return (buffer, sequence, arrived)
    }

    enum EncodeError: LocalizedError {
        case invalidSize, render, encode
        var errorDescription: String? {
            switch self {
            case .invalidSize: "invalid frame size"
            case .render: "frame render failed"
            case .encode: "PNG encode failed"
            }
        }
    }

    /// sRGB PNG, aspect kept, never upscaled.
    static func png(_ buffer: CVPixelBuffer, maxWidth: Int) throws -> (data: Data, width: Int, height: Int) {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0, maxWidth > 0 else { throw EncodeError.invalidSize }
        let targetWidth = min(width, maxWidth)
        let targetHeight = max(1, Int((Double(height) * Double(targetWidth) / Double(width)).rounded()))
        var image = CIImage(cvPixelBuffer: buffer)
        if targetWidth != width || targetHeight != height {
            image = image.transformed(by: CGAffineTransform(scaleX: CGFloat(targetWidth) / CGFloat(width),
                                                            y: CGFloat(targetHeight) / CGFloat(height)))
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cgImage = context.createCGImage(image, from: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
                                                  format: .RGBA8, colorSpace: space) else { throw EncodeError.render }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw EncodeError.encode }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw EncodeError.encode }
        return (data as Data, targetWidth, targetHeight)
    }
}
