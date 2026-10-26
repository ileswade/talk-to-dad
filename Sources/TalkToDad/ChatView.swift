import AVFoundation
import SwiftUI
import TTDShared

struct ChatView: View {
    @EnvironmentObject var model: ChatModel
    @State private var draft = ""
    @State private var showSettings = false
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let problem = model.permissionProblem ?? model.listener.problem ?? model.speaker.kokoroProblem ?? (model.texts.enabled ? model.texts.problem : nil) ?? model.replies.problem {
                Text(problem).font(.callout).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(8).background(.red)
            }
            messages
            Divider()
            dadButtons
            Divider()
            statusBar
            Divider()
            composer
        }
        .toolbar {
            ToolbarItem {
                Button { showSettings.toggle() } label: { Label("Settings", systemImage: "gearshape") }
                    .popover(isPresented: $showSettings) { SettingsView().environmentObject(model).padding().frame(width: 360) }
            }
            ToolbarItem {
                Button { NSWorkspace.shared.open(model.store.folder) } label: { Label("Show files", systemImage: "folder") }
            }
        }
        .onAppear { typing = true }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.store.visibleLines) { line in
                        Bubble(line: line) { model.play(line) }.id(line.id)
                    }
                    if model.listener.isListening && !model.listener.partial.isEmpty {
                        Bubble(line: Line(from: "Dad", text: model.listener.partial + " …"), live: true).id("live")
                    }
                }
                .padding()
            }
            .onChange(of: model.store.visibleLines.count) { proxy.scrollTo(model.store.visibleLines.last?.id, anchor: .bottom) }
            .onChange(of: model.listener.partial) { proxy.scrollTo("live", anchor: .bottom) }
        }
    }

    /// Big buttons for Dad: talk to Iles (blue), talk to Nicole (pink), clear the screen.
    private var dadButtons: some View {
        HStack(spacing: 12) {
            talkButton(to: "Iles", colour: .blue)
            talkButton(to: "Nicole", colour: .pink)
            Button { model.store.clearScreen() } label: {
                Label("Clear", systemImage: "eraser.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 130, height: 80)
                    .background(Color.gray.opacity(0.25), in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .help("Clear the screen (the conversation is still saved)")
        }
        .padding(12)
    }

    private func talkButton(to who: String, colour: Color) -> some View {
        let active = model.listener.isListening && model.listeningTo == who
        let otherActive = model.listener.isListening && !active
        return Button {
            if active { model.listener.stop() } else if !otherActive { model.dadStartsTalking(to: who) }
        } label: {
            Label(active ? "Done talking" : "Talk to \(who)",
                  systemImage: active ? "checkmark.circle.fill" : "mic.fill")
                .font(.system(size: 26, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: 80)
                .foregroundStyle(.white)
                .background(active ? Color.orange : colour, in: RoundedRectangle(cornerRadius: 18))
                .opacity(otherActive ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .disabled(otherActive)
        .help(active ? "Press when you've finished speaking" : "Press, then speak to \(who)")
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Image(systemName: model.menuIcon).foregroundStyle(model.listener.isListening ? .green : .secondary)
            Text(model.status).font(.headline)
            if model.listener.isListening {
                ProgressView(value: Double(model.listener.level)).frame(width: 90)
            }
            Spacer()
            SpeedControl(speaker: model.speaker)
            if model.listener.isListening {
                Button("Done — send his answer") { model.listener.stop() }.keyboardShortcut(.return, modifiers: [.command])
                Button("Cancel") { model.listener.cancel() }
            } else if model.speaker.isSpeaking {
                Button("Stop speaking") { model.speaker.stop() }
            } else {
                Button("Say it again") { model.repeatLast() }
                Button("Listen") { model.listen() }
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
    }

    private var composer: some View {
        HStack(alignment: .bottom) {
            Picker("From", selection: $model.sender) {
                ForEach(ChatModel.senders, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130)
            TextField("Type a message for Dad…", text: $draft, axis: .vertical)
                .font(.title3)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .focused($typing)
                .onSubmit(send)
            Button("Speak", action: send)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .controlSize(.large)
        }
        .padding()
    }

    private func send() {
        model.send(draft)
        draft = ""
    }
}

struct Bubble: View {
    let line: Line
    var live = false
    var play: (() -> Void)? = nil

    var body: some View {
        if line.from == "note" {
            Text("\(line.text)  ·  \(line.date.formatted(date: .omitted, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        } else {
            let mine = line.from != "Dad"
            let colour = line.from == "Nicole" ? Color.purple : Color.accentColor
            HStack(alignment: .bottom) {
                if mine { Spacer(minLength: 60) }
                VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                    Text(line.text)
                        .font(.title3)
                        .textSelection(.enabled)
                        .padding(10)
                        .background(mine ? colour : Color.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(mine ? .white : .primary)
                        .opacity(live ? 0.6 : 1)
                    HStack(spacing: 6) {
                        Text("\(line.from)\(line.to.map { " → \($0)" } ?? "") · \(line.date.formatted(date: .abbreviated, time: .shortened))")
                        if line.audioFile != nil, let play {
                            Button { play() } label: { Label("Play", systemImage: "play.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if !mine { Spacer(minLength: 60) }
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: ChatModel

    var body: some View {
        SettingsForm(model: model, speaker: model.speaker, listener: model.listener, texts: model.texts, replies: model.replies, relay: model.relay)
    }
}

struct SettingsForm: View {
    @ObservedObject var model: ChatModel
    @ObservedObject var speaker: Speaker
    @ObservedObject var listener: Listener
    @ObservedObject var texts: MessagesWatcher
    @ObservedObject var replies: MessagesSender
    @ObservedObject var relay: RelayClient
    @State private var newKey = ""

    var body: some View {
        Form {
            ForEach(ChatModel.senders, id: \.self) { name in
                Picker("\(name)'s voice", selection: Binding(get: { model.voice(for: name) },
                                                             set: { model.setVoice($0, for: name) })) {
                    ForEach(Speaker.kokoroVoices, id: \.id) { Text($0.name).tag($0.id) }
                }
            }
            Slider(value: $speaker.speed, in: 0.6...1.3, step: 0.05) { Text("Speed \(String(format: "%.2f", speaker.speed))×") }
            Slider(value: $speaker.loudness, in: 1...3) { Text("Loudness") }
            Text(speaker.kokoroReady ? "Natural voice ready." : "Natural voice loading… (built-in voice until then)")
                .font(.caption).foregroundStyle(.secondary)
            Stepper("Stop listening after \(Int(listener.silenceSeconds)) s of quiet",
                    value: $listener.silenceSeconds, in: 2...15)
            Toggle("Say “Message from …” when a chat starts", isOn: $model.announce)
            Stepper("A chat ends after \(Int(model.sessionMinutes)) min with no messages",
                    value: $model.sessionMinutes, in: 1...30)
            Toggle("Listen automatically after speaking", isOn: $model.autoListen)
            Toggle("Read texts from these numbers aloud", isOn: $texts.enabled)
            ForEach(ChatModel.senders, id: \.self) { name in
                TextField("\(name)'s mobile number", text: Binding(get: { texts.number(for: name) },
                                                                 set: { texts.setNumber($0, for: name) }),
                          prompt: Text("e.g. 403-555-0123"))
            }
            Toggle("Test mode: also read texts I send to myself", isOn: $texts.testMode)
            Picker("Send Dad's answers back by text", selection: $replies.mode) {
                Text("Off").tag(MessagesSender.Mode.off)
                Text("Text only").tag(MessagesSender.Mode.text)
                Text("Text + recording").tag(MessagesSender.Mode.textAndAudio)
            }
            Section("Family app connection") {
                TextField("Relay address", text: $relay.url, prompt: Text("https://ttd-relay.example.workers.dev"))
                    .onSubmit { relay.restart() }
                HStack {
                    SecureField(relay.hasKey ? "Key saved — paste to replace" : "Paste Dad's relay key", text: $newKey)
                    Button("Save") { relay.setKey(newKey); newKey = "" }.disabled(newKey.isEmpty)
                }
                Text(relay.status).font(.caption).foregroundStyle(relay.connected ? .green : .secondary)
            }
            Toggle("Start automatically when the Mac starts", isOn: $model.startAtLogin)
            Button("Test \(model.sender)'s voice") {
                speaker.speak("Hi Dad, it's \(model.sender). Can you hear me okay?", voice: model.voice(for: model.sender))
            }
        }
    }
}

/// Always-visible voice speed: slower / faster. Use "Say it again" to hear the new speed.
struct SpeedControl: View {
    @ObservedObject var speaker: Speaker
    @EnvironmentObject var model: ChatModel

    var body: some View {
        HStack(spacing: 4) {
            Button { change(-0.05) } label: { Image(systemName: "tortoise.fill") }
                .help("Speak slower")
            Text("\(Int((speaker.speed * 100).rounded()))%")
                .monospacedDigit().frame(width: 44)
                .help("Voice speed")
            Button { change(0.05) } label: { Image(systemName: "hare.fill") }
                .help("Speak faster")
        }
    }

    private func change(_ step: Double) {
        speaker.speed = min(1.3, max(0.6, ((speaker.speed + step) * 100).rounded() / 100))
    }
}
