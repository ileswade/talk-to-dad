import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Is Dad at his computer? Idle time needs no permission; screenshots need Screen Recording.
enum Presence {
    /// Seconds since the last keyboard, mouse or trackpad input.
    static var idleSeconds: Double {
        let types: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .scrollWheel]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }

    static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// A JPEG of the main display, scaled down to about 1280 px wide.
    static func screenshot() async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw NSError(domain: "TTD", code: 1) }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let scale = min(1, 1280 / Double(display.width))
        config.width = Int(Double(display.width) * scale)
        config.height = Int(Double(display.height) * scale)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else {
            throw NSError(domain: "TTD", code: 2)
        }
        return jpeg
    }
}

import AVFoundation

/// One photo from the built-in camera (the green light shows while it's taken). Needs Camera permission.
final class CameraSnapshot: NSObject, AVCapturePhotoCaptureDelegate {
    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var done: ((Data?) -> Void)?
    private static var current: CameraSnapshot?

    static func take(_ done: @escaping (Data?) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else { done(nil); return }
            let snap = CameraSnapshot()
            current = snap
            snap.capture { data in current = nil; done(data) }
        }
    }

    private func capture(_ done: @escaping (Data?) -> Void) {
        self.done = done
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input), session.canAddOutput(output) else { done(nil); return }
        session.sessionPreset = .high
        session.addInput(input)
        session.addOutput(output)
        session.startRunning()
        // Give the camera a moment to adjust exposure before the photo.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) {
            self.output.capturePhoto(with: AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg]), delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        session.stopRunning()
        var jpeg = photo.fileDataRepresentation()
        if let data = jpeg, let image = NSImage(data: data), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            jpeg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.6])
        }
        done?(jpeg)
        done = nil
    }
}
