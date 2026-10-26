import AVFoundation
import FluidAudio

/// Speaks messages with Kokoro on the Neural Engine, louder than normal (gain with a soft limiter).
/// Falls back to the built-in macOS voice if Kokoro isn't ready or fails.
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    /// Kokoro English voices offered in Settings (all bundled with the app).
    static let kokoroVoices: [(id: String, name: String)] = [
        ("am_adam", "Adam (man, US)"), ("am_michael", "Michael (man, US)"), ("am_eric", "Eric (man, US)"),
        ("bm_george", "George (man, UK)"), ("af_heart", "Heart (woman, US)"), ("af_sarah", "Sarah (woman, US)"),
        ("af_bella", "Bella (woman, US)"), ("af_nicole", "Nicole (woman, US)"), ("bf_emma", "Emma (woman, UK)"),
    ]

    @Published var isSpeaking = false
    @Published var kokoroReady = false
    @Published var kokoroProblem: String?

    @Published var speed: Double = UserDefaults.standard.object(forKey: "kokoroSpeed") as? Double ?? 0.9 {
        didSet { UserDefaults.standard.set(speed, forKey: "kokoroSpeed") }
    }
    /// 1 = normal loudness. Above 1 is boosted, with a soft limiter so it doesn't crackle.
    @Published var loudness: Double = UserDefaults.standard.object(forKey: "loudness") as? Double ?? 1.8 {
        didSet { UserDefaults.standard.set(loudness, forKey: "loudness") }
    }

    private var kokoro: KokoroAneManager?
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private let synth = AVSpeechSynthesizer()
    private var onDone: (() -> Void)?
    private var job: Task<Void, Never>?
    private var generation = 0

    override init() {
        super.init()
        synth.delegate = self
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    /// Where Kokoro's model files live. Copied from the app bundle on first run, so no download is needed.
    static var modelsFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Talk to Dad/Models", isDirectory: true)
    }

    func prepare() {
        let folder = Self.modelsFolder
        let fm = FileManager.default
        if !fm.fileExists(atPath: folder.path),
           let bundled = Bundle.main.resourceURL?.appendingPathComponent("Models"),
           fm.fileExists(atPath: bundled.path) {
            try? fm.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: bundled, to: folder)
        }
        // FluidAudio keeps Kokoro's English pronunciation files in ~/.cache/fluidaudio/Models/kokoro.
        let g2p = fm.homeDirectoryForCurrentUser.appendingPathComponent(".cache/fluidaudio/Models/kokoro")
        if !fm.fileExists(atPath: g2p.appendingPathComponent("G2PEncoder.mlmodelc").path),
           let bundled = Bundle.main.resourceURL?.appendingPathComponent("KokoroG2P"),
           fm.fileExists(atPath: bundled.path) {
            try? fm.createDirectory(at: g2p.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: g2p)
            try? fm.copyItem(at: bundled, to: g2p)
        }
        Task {
            do {
                let manager = KokoroAneManager(defaultVoice: "am_adam", directory: folder)
                try await manager.initialize(preloadVoices: Set(Self.kokoroVoices.map(\.id)))
                await MainActor.run { self.kokoro = manager; self.kokoroReady = true; self.kokoroProblem = nil }
                // Self-test for builds: TALKTODAD_SELFTEST=/path/out.wav writes a sample and quits.
                if let out = ProcessInfo.processInfo.environment["TALKTODAD_SELFTEST"] {
                    let wav = try await manager.synthesize(text: "Hi Dad, it's Iles. How are you feeling this morning?", voice: "am_adam", speed: 0.9)
                    try wav.write(to: URL(fileURLWithPath: out))
                    exit(0)
                }
            } catch {
                if let out = ProcessInfo.processInfo.environment["TALKTODAD_SELFTEST"] {
                    try? "FAILED: \(error)".write(toFile: out + ".error", atomically: true, encoding: .utf8)
                    exit(1)
                }
                await MainActor.run { self.kokoroProblem = "Natural voice unavailable (\(error.localizedDescription)); using the built-in voice." }
            }
        }
    }

    func speak(_ text: String, voice: String, then done: (() -> Void)? = nil) {
        stop()
        onDone = done
        isSpeaking = true
        generation += 1
        let gen = generation
        guard let kokoro else { fallback(text); return }
        let speed = Float(speed), gain = Float(loudness)
        job = Task {
            do {
                let result = try await kokoro.synthesizeDetailed(text: text, voice: voice, speed: speed)
                await MainActor.run { if gen == self.generation { self.play(result.samples, gain: gain) } }
            } catch {
                await MainActor.run {
                    guard gen == self.generation else { return }
                    self.kokoroProblem = "Natural voice failed once (\(error.localizedDescription)); used the built-in voice."
                    self.fallback(text)
                }
            }
        }
    }

    private func play(_ samples: [Float], gain: Float) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let out = buffer.floatChannelData?[0] else { finished(); return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for i in 0..<samples.count {
            let x = samples[i] * gain
            out[i] = gain > 1 ? tanh(x) : x      // soft limiter keeps the boost clean
        }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            finished(); return
        }
        let gen = generation
        node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { if gen == self?.generation { self?.finished() } }
        }
        node.play()
    }

    private func fallback(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
            .max { $0.quality.rawValue < $1.quality.rawValue }
        u.rate = 0.45
        u.volume = 1
        synth.speak(u)
    }

    func stop() {
        generation += 1
        job?.cancel()
        node.stop()
        synth.stopSpeaking(at: .immediate)
        onDone = nil
        isSpeaking = false
    }

    private func finished() {
        // Release the speakers so the microphone can start cleanly.
        let engine = self.engine
        DispatchQueue.global(qos: .userInitiated).async { if engine.isRunning { engine.stop() } }
        isSpeaking = false
        let done = onDone
        onDone = nil
        done?()
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        DispatchQueue.main.async { self.finished() }
    }
}
