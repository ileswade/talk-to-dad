import AVFoundation
import Speech

/// Listens for Dad's answer with on-device speech recognition and records the audio.
/// Ends after he has been quiet for `silenceSeconds`, if he never starts, or when stopped.
final class Listener: ObservableObject {
    @Published var isListening = false
    @Published var partial = ""
    @Published var level: Float = 0          // 0...1 microphone level for the meter
    @Published var problem: String?

    @Published var silenceSeconds: Double = UserDefaults.standard.object(forKey: "silence") as? Double ?? 4 {
        didSet { UserDefaults.standard.set(silenceSeconds, forKey: "silence") }
    }
    var waitForStartSeconds: Double = 25     // give up if he says nothing at all
    var maxSeconds: Double = 180

    /// All AVAudioEngine work happens on this queue, never the main thread: touching the
    /// microphone right after the voice finishes can otherwise deadlock the app.
    private let audioQueue = DispatchQueue(label: "ttd.listener.audio")
    private var engine: AVAudioEngine?       // audioQueue only
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var fileURL: URL?
    private var timer: Timer?
    private var started = Date()
    private var lastChange = Date()
    private var finished = true
    private var committed = ""      // text from earlier segments (the recognizer restarts after pauses)
    private var current = ""        // text of the segment in progress
    private var peakLevel: Float = 0
    private var onFinish: ((String, URL?) -> Void)?

    static func requestPermissions(_ done: @escaping (String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                DispatchQueue.main.async { done("Speech recognition isn't allowed. Turn it on in System Settings → Privacy & Security → Speech Recognition.") }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { done(ok ? nil : "Microphone isn't allowed. Turn it on in System Settings → Privacy & Security → Microphone.") }
            }
        }
    }

    func start(recordTo url: URL, onFinish: @escaping (String, URL?) -> Void) {
        guard finished else { return }
        problem = nil
        partial = ""
        committed = ""; current = ""; peakLevel = 0
        self.onFinish = onFinish
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-CA")) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            problem = "Speech recognition isn't available right now."
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req

        fileURL = url
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, !self.finished else { return }
                if let result {
                    self.absorb(result.bestTranscription.formattedString)
                    if result.isFinal { self.finish() }
                } else if error != nil, self.request == nil {
                    self.finish()
                }
            }
        }
        finished = false
        isListening = true
        started = Date()
        lastChange = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }

        audioQueue.async { [weak self] in
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                DispatchQueue.main.async { self?.failed("No microphone found.") }
                return
            }
            let file = try? AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitRateKey: 64000,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                req.append(buffer)
                try? file?.write(from: buffer)
                if let ch = buffer.floatChannelData?[0] {
                    let n = Int(buffer.frameLength)
                    var sum: Float = 0
                    for i in 0..<n { sum += ch[i] * ch[i] }
                    let rms = n > 0 ? (sum / Float(n)).squareRoot() : 0
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.level = min(1, rms * 12)
                        self.peakLevel = max(self.peakLevel, self.level)
                    }
                }
            }
            do {
                engine.prepare()
                try engine.start()
                self?.engine = engine
            } catch {
                input.removeTap(onBus: 0)
                DispatchQueue.main.async { self?.failed("Couldn't start the microphone: \(error.localizedDescription)") }
            }
        }
    }

    private func failed(_ message: String) {
        problem = message
        timer?.invalidate(); timer = nil
        task?.cancel()
        cleanup()
    }

    /// Never lets an empty or restarted result wipe out words already heard.
    private func absorb(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            if !current.isEmpty { committed += current + " "; current = "" }
        } else if !current.isEmpty, text.count < current.count / 2, !current.hasPrefix(text) {
            committed += current + " "   // a new segment started after a pause
            current = text
        } else {
            current = text
        }
        let all = (committed + current).trimmingCharacters(in: .whitespaces)
        if all != partial { partial = all; lastChange = Date() }
    }

    private func tick() {
        let now = Date()
        let heard = !partial.trimmingCharacters(in: .whitespaces).isEmpty
        if heard && now.timeIntervalSince(lastChange) > silenceSeconds { stop() }
        else if !heard && now.timeIntervalSince(started) > waitForStartSeconds { stop() }
        else if now.timeIntervalSince(started) > maxSeconds { stop() }
    }

    /// Stop listening and send what was heard.
    func stop() {
        guard !finished, request != nil else { return }
        stopAudio()
        request?.endAudio()
        request = nil
        // Wait briefly for the final transcript, then finish with what we have.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.finish() }
    }

    /// Stop listening and throw the answer away.
    func cancel() {
        guard !finished else { return }
        onFinish = nil
        stopAudio()
        task?.cancel()
        if let fileURL { audioQueue.async { try? FileManager.default.removeItem(at: fileURL) } }
        cleanup()
    }

    private func finish() {
        guard !finished else { return }
        stopAudio()
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = fileURL
        let done = onFinish
        let heardSound = peakLevel > 0.15
        task?.cancel()
        cleanup()
        // Keep the recording if there were words or audible sound; drop pure silence.
        let keep = !text.isEmpty || heardSound
        if !keep, let url { audioQueue.async { try? FileManager.default.removeItem(at: url) } }
        done?(text, keep ? url : nil)
    }

    private func stopAudio() {
        timer?.invalidate(); timer = nil
        audioQueue.async { [weak self] in
            guard let engine = self?.engine else { return }
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)   // releases the tap, which closes the audio file
            self?.engine = nil
        }
    }

    private func cleanup() {
        task = nil; request = nil; onFinish = nil
        finished = true
        isListening = false
        level = 0
    }
}
