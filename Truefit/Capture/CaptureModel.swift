import Foundation
import RealityKit
import SwiftUI

/// Runs Apple's guided Object Capture (LiDAR + camera), then reconstructs the
/// photos into a 3D model on the device.
@MainActor
final class CaptureModel: ObservableObject {
    enum Phase: Equatable {
        case capturing
        case reconstructing(Double)
        case finished(URL)
        case failed(String)
    }

    @Published var session: ObjectCaptureSession?
    @Published private(set) var phase: Phase = .capturing
    @Published private(set) var stepTitle = "Starting camera…"
    @Published private(set) var stepDetail = ""
    @Published private(set) var canContinue = false
    @Published private(set) var canFinish = false
    @Published private(set) var isDetecting = false
    /// Laps captured so far, including flips.
    @Published private(set) var lap = 1
    @Published private(set) var flipped = false

    let folder: URL
    private var imagesFolder: URL { folder.appendingPathComponent("Images", isDirectory: true) }
    private var checkpointFolder: URL { folder.appendingPathComponent("Checkpoint", isDirectory: true) }
    var modelURL: URL { folder.appendingPathComponent("Scan.usdz") }
    private var stateTask: Task<Void, Never>?
    private var reconstructTask: Task<Void, Never>?

    static var isSupported: Bool { ObjectCaptureSession.isSupported }

    init() {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("Capture-\(stamp)", isDirectory: true)
    }

    func start() {
        guard session == nil, case .capturing = phase else { return }
        do {
            try FileManager.default.createDirectory(at: imagesFolder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: checkpointFolder, withIntermediateDirectories: true)
        } catch {
            phase = .failed("Couldn't prepare storage for the scan: \(error.localizedDescription)")
            return
        }
        let session = ObjectCaptureSession()
        var config = ObjectCaptureSession.Configuration()
        config.checkpointDirectory = checkpointFolder
        config.isOverCaptureEnabled = false
        self.session = session
        // Listen before starting so the first state changes aren't missed.
        stateTask = Task { [weak self] in
            for await state in session.stateUpdates {
                self?.handle(state)
            }
        }
        session.start(imagesDirectory: imagesFolder, configuration: config)
        handle(session.state)
        // Safety net: the session can reach "ready" before the listener attaches.
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, let s = self.session else { return }
                self.handle(s.state)
            }
        }
    }

    private var lastStateKey = ""
    private var watchTask: Task<Void, Never>?

    private func handle(_ state: ObjectCaptureSession.CaptureState) {
        let key = String(describing: state)
        guard key != lastStateKey else { return }
        lastStateKey = key
        canContinue = false
        canFinish = false
        isDetecting = false
        switch state {
        case .initializing:
            stepTitle = "Starting camera…"; stepDetail = ""
        case .ready:
            stepTitle = "Aim at your object"
            stepDetail = "Center it on a plain, uncluttered surface with space to walk around it."
            canContinue = true
        case .detecting:
            stepTitle = "Fit the box"
            isDetecting = true
            stepDetail = "Drag the box edges so they hug the object, then start capturing."
            canContinue = true
        case .capturing:
            stepTitle = flipped ? "Lap \(lap): the other side" : "Lap \(lap): walk slowly around it"
            stepDetail = lap == 1
                ? "Keep the object in view and move in a full circle. Then flip it to capture the side touching the table, or finish."
                : "Circle it again. Add another lap from higher up, flip it again, or finish."
            canFinish = true
        case .finishing:
            stepTitle = "Saving photos…"; stepDetail = ""
        case .completed:
            stepTitle = "Photos captured"; stepDetail = ""
            reconstruct()
        case .failed(let error):
            phase = .failed("The capture stopped: \(error.localizedDescription)")
        @unknown default:
            break
        }
    }

    /// Advances through ready → detecting → capturing.
    func continueTapped() {
        guard let session else { return }
        switch session.state {
        case .ready: _ = session.startDetecting()
        case .detecting: session.startCapturing()
        default: break
        }
    }

    func resetBox() { session?.resetDetection() }

    /// Turn the object over and capture the side that was on the table.
    /// Object Capture merges every lap into one model.
    func flipTapped() {
        guard let session else { return }
        session.beginNewScanPassAfterFlip()
        lap += 1
        flipped = true
        lastStateKey = ""
    }

    /// Another lap without moving the object, e.g. from a higher angle.
    func anotherLapTapped() {
        guard let session else { return }
        session.beginNewScanPass()
        lap += 1
        flipped = false
        lastStateKey = ""
    }

    func finishTapped() { session?.finish() }

    func cancel() {
        session?.cancel()
        stateTask?.cancel()
        watchTask?.cancel()
        reconstructTask?.cancel()
        try? FileManager.default.removeItem(at: folder)
    }

    private func reconstruct() {
        guard reconstructTask == nil else { return }
        stateTask?.cancel()
        watchTask?.cancel()
        session = nil   // frees the camera and memory before reconstruction
        phase = .reconstructing(0)
        let images = imagesFolder, checkpoint = checkpointFolder, output = modelURL
        reconstructTask = Task { [weak self] in
            do {
                var config = PhotogrammetrySession.Configuration()
                config.checkpointDirectory = checkpoint
                let photogrammetry = try PhotogrammetrySession(input: images, configuration: config)
                try photogrammetry.process(requests: [.modelFile(url: output, detail: .reduced)])
                for try await event in photogrammetry.outputs {
                    switch event {
                    case .requestProgress(_, let fraction):
                        self?.phase = .reconstructing(fraction)
                    case .requestError(_, let error):
                        self?.phase = .failed("Building the model failed: \(error.localizedDescription)")
                    case .processingComplete:
                        if FileManager.default.fileExists(atPath: output.path) {
                            self?.phase = .finished(output)
                        } else if case .reconstructing = self?.phase {
                            self?.phase = .failed("The model couldn't be built from these photos. Try again with more light and a slower lap.")
                        }
                    default:
                        break
                    }
                }
            } catch {
                self?.phase = .failed("Building the model failed: \(error.localizedDescription)")
            }
        }
    }
}
