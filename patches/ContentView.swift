import SwiftUI
import Foundation
import AVFoundation
import UniformTypeIdentifiers

struct LVChatMessage: Identifiable, Equatable {
    enum Role {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var text: String

    init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

@MainActor
final class LocalVoiceViewModel: ObservableObject {
    @Published var messages: [LVChatMessage] = []
    @Published var inputText: String = ""
    @Published var availableModels: [URL] = []
    @Published var loadedModelName: String?
    @Published var statusText: String = "Model seç"
    @Published var isLoadingModel = false
    @Published var isGenerating = false
    @Published var autoSpeak = true
    @Published var thinkingEnabled = false
    @Published var lastGenerationTPS: Double?
    @Published var thinkingStatus: String?

    // Whisper / voice input state
    @Published var whisperEnabled = false
    @Published var autoSendVoice = true
    @Published var lowMemoryVoiceMode = true
    @Published var availableWhisperModels: [URL] = []
    @Published var selectedWhisperModelURL: URL?
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var whisperStatusText = "Kapalı"
    @Published var lastTranscript: String?

    private var llamaContext: LlamaContext?
    private var loadedModelURL: URL?
    private let synthesizer = AVSpeechSynthesizer()
    private var cancelRequested = false
    private var audioRecorder: AVAudioRecorder?

    // iPhone 13'te kısa/orta cevaplar için kontrollü tutuyoruz.
    // Thinking açıkken reasoning de aynı bütçeyi kullandığı için biraz daha yüksek.
    private var maxNewTokens: Int { thinkingEnabled ? 640 : 384 }

    // Küçük modellerde "ben bir asistanım" tekrarını azaltmak için kimlik dayatmayan,
    // görev odaklı ve nötr bir sistem prompt'u kullanıyoruz.
    private let systemPrompt = """
    Kullanıcıyla doğal ve akıcı biçimde konuş. Sorularını doğrudan yanıtla ve istenen görevleri elinden geldiğince yerine getir. Gereksiz yere kim olduğunu veya rolünü açıklama. Kullanıcının dilinde cevap ver. Yanıtları konuşmaya uygun, açık ve gereksiz uzunluktan kaçınarak oluştur. Kullanıcı istemedikçe sohbet rollerini taklit etme veya kendi kendine yeni kullanıcı mesajları üretme.
    """

    init() {
        refreshModels()
        refreshWhisperModels()
    }

    var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var loadedModelIsQwen3: Bool {
        guard let name = loadedModelName?.lowercased() else { return false }
        return name.contains("qwen3") || name.contains("qwen-3")
    }

    func refreshModels() {
        do {
            availableModels = try FileManager.default
                .contentsOfDirectory(at: documentsDirectory,
                                     includingPropertiesForKeys: [.fileSizeKey],
                                     options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
                .filter { $0.pathExtension.lowercased() == "gguf" }
                .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        } catch {
            statusText = "Model listesi okunamadı: \(error.localizedDescription)"
        }
    }

    func refreshWhisperModels() {
        do {
            availableWhisperModels = try FileManager.default
                .contentsOfDirectory(at: documentsDirectory,
                                     includingPropertiesForKeys: [.fileSizeKey],
                                     options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
                .filter { $0.pathExtension.lowercased() == "bin" }
                .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

            if selectedWhisperModelURL == nil {
                selectedWhisperModelURL = availableWhisperModels.first
            } else if let selected = selectedWhisperModelURL,
                      !availableWhisperModels.contains(where: { $0.standardizedFileURL == selected.standardizedFileURL }) {
                selectedWhisperModelURL = availableWhisperModels.first
            }
            updateWhisperStatus()
        } catch {
            whisperStatusText = "Whisper listesi okunamadı"
        }
    }

    func importWhisperModel(from sourceURL: URL) {
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let destination = documentsDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        do {
            if sourceURL.standardizedFileURL != destination.standardizedFileURL {
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.copyItem(at: sourceURL, to: destination)
                }
            }
            refreshWhisperModels()
            selectedWhisperModelURL = destination
            whisperStatusText = whisperEnabled ? "Hazır" : "Kapalı"
        } catch {
            whisperStatusText = "Whisper modeli kopyalanamadı"
            statusText = "Whisper modeli kopyalanamadı: \(error.localizedDescription)"
        }
    }

    func selectWhisperModel(_ url: URL) {
        selectedWhisperModelURL = url
        updateWhisperStatus()
    }

    func whisperToggleChanged() {
        if !whisperEnabled, isRecording {
            audioRecorder?.stop()
            audioRecorder = nil
            isRecording = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        updateWhisperStatus()
    }

    private func updateWhisperStatus() {
        if !whisperEnabled {
            whisperStatusText = "Kapalı"
        } else if selectedWhisperModelURL == nil {
            whisperStatusText = "Model seç"
        } else if isRecording {
            whisperStatusText = "Dinliyor…"
        } else if isTranscribing {
            whisperStatusText = "Yazıya çeviriyor…"
        } else {
            whisperStatusText = "Hazır"
        }
    }

    func importModel(from sourceURL: URL) {
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let destination = documentsDirectory.appendingPathComponent(sourceURL.lastPathComponent)

        do {
            if sourceURL.standardizedFileURL != destination.standardizedFileURL {
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.copyItem(at: sourceURL, to: destination)
                }
            }
            refreshModels()
            statusText = "Model eklendi: \(destination.lastPathComponent)"
        } catch {
            statusText = "Model kopyalanamadı: \(error.localizedDescription)"
        }
    }

    func loadModel(_ url: URL) {
        guard !isLoadingModel, !isGenerating, !isRecording, !isTranscribing else { return }

        isLoadingModel = true
        statusText = "Model yükleniyor…"
        loadedModelName = nil
        lastGenerationTPS = nil
        thinkingStatus = nil

        let path = url.path
        Task {
            do {
                let newContext = try await Task.detached(priority: .userInitiated) {
                    try LlamaContext.create_context(path: path)
                }.value

                llamaContext = newContext
                loadedModelURL = url
                loadedModelName = url.lastPathComponent
                statusText = "Hazır"
                messages.removeAll()

                // Qwen3'te telefon için varsayılanımız non-thinking.
                if loadedModelIsQwen3 {
                    thinkingEnabled = false
                }
            } catch {
                llamaContext = nil
                loadedModelURL = nil
                statusText = "Model yüklenemedi: \(error.localizedDescription)"
            }
            isLoadingModel = false
        }
    }

    func unloadModel() {
        guard !isGenerating, !isRecording, !isTranscribing else { return }
        llamaContext = nil
        loadedModelURL = nil
        loadedModelName = nil
        messages.removeAll()
        lastGenerationTPS = nil
        thinkingStatus = nil
        statusText = "Model seç"
    }

    func clearChat() {
        guard !isGenerating, !isRecording, !isTranscribing else { return }
        messages.removeAll()
        lastGenerationTPS = nil
        thinkingStatus = nil
        Task { await llamaContext?.clear() }
    }

    func requestStop() {
        cancelRequested = true
        statusText = "Durduruluyor…"
    }

    func send() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let context = llamaContext,
              !isGenerating,
              !isRecording,
              !isTranscribing else { return }

        inputText = ""
        cancelRequested = false
        thinkingStatus = nil
        synthesizer.stopSpeaking(at: .immediate)
        messages.append(LVChatMessage(role: .user, text: trimmed))

        // 2K context + 1.7B model için geçmişi bilinçli olarak kısa tutuyoruz.
        // Son 6 mesaj, genelde son 3 tur demektir.
        let chatForPrompt = Array(messages.suffix(6))
        let prompt = buildQwenPrompt(from: chatForPrompt)
        let assistantID = UUID()
        messages.append(LVChatMessage(id: assistantID, role: .assistant, text: ""))

        isGenerating = true
        statusText = thinkingEnabled && loadedModelIsQwen3 ? "Düşünüyor…" : "Yanıt oluşturuluyor…"
        lastGenerationTPS = nil

        Task {
            await context.clear()
            await context.configureSampling(thinking: thinkingEnabled && loadedModelIsQwen3)
            await context.completion_init(text: prompt)

            let generationStart = DispatchTime.now().uptimeNanoseconds
            var generatedTokens = 0
            var shouldStop = false
            var rawOutput = ""

            while await !context.is_done && generatedTokens < maxNewTokens && !shouldStop && !cancelRequested {
                var chunk = await context.completion_loop()
                generatedTokens += 1

                // EOG çoğu Qwen GGUF'unda special token olarak yakalanır; yine de
                // metin olarak dönerse kullanıcıya göstermeden kes.
                for stop in ["<|im_end|>", "<|endoftext|>"] {
                    if let range = chunk.range(of: stop) {
                        chunk = String(chunk[..<range.lowerBound])
                        shouldStop = true
                    }
                }

                if !chunk.isEmpty {
                    rawOutput += chunk

                    let parsed = parseQwenOutput(rawOutput)
                    thinkingStatus = parsed.isThinking ? "Model düşünüyor…" : nil
                    statusText = parsed.isThinking ? "Düşünüyor…" : "Yanıt oluşturuluyor…"

                    if let index = messages.firstIndex(where: { $0.id == assistantID }) {
                        messages[index].text = parsed.answer
                    }
                }
            }

            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - generationStart) / 1_000_000_000.0
            if elapsed > 0, generatedTokens > 0 {
                lastGenerationTPS = Double(generatedTokens) / elapsed
            }

            await context.clear()
            isGenerating = false
            thinkingStatus = nil
            statusText = cancelRequested ? "Durduruldu" : "Hazır"

            if let index = messages.firstIndex(where: { $0.id == assistantID }) {
                let finalParsed = parseQwenOutput(rawOutput)
                let answer = finalParsed.answer.trimmingCharacters(in: .whitespacesAndNewlines)

                if !answer.isEmpty {
                    messages[index].text = answer
                    if autoSpeak && !cancelRequested {
                        speak(answer)
                    }
                } else if cancelRequested {
                    messages[index].text = "(Yanıt durduruldu.)"
                } else if thinkingEnabled && loadedModelIsQwen3 {
                    messages[index].text = "(Thinking bütçesi içinde nihai yanıt üretilemedi. Derin düşünmeyi kapatıp tekrar deneyebilirsin.)"
                } else {
                    messages[index].text = "(Model görünür bir yanıt üretmedi.)"
                }
            }
        }
    }

    func toggleRecording() {
        guard whisperEnabled,
              selectedWhisperModelURL != nil,
              loadedModelName != nil,
              !isGenerating,
              !isLoadingModel,
              !isTranscribing else { return }

        if isRecording {
            stopRecordingAndTranscribe()
        } else {
            requestMicrophoneAndStart()
        }
    }

    private func requestMicrophoneAndStart() {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.whisperStatusText = "Mikrofon izni yok"
                    self.statusText = "Mikrofon izni verilmedi."
                    return
                }
                self.startRecording()
            }
        }
    }

    private func startRecording() {
        synthesizer.stopSpeaking(at: .immediate)

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)

            let outputURL = documentsDirectory.appendingPathComponent("localvoice-input.wav")
            try? FileManager.default.removeItem(at: outputURL)

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]

            let recorder = try AVAudioRecorder(url: outputURL, settings: settings)
            recorder.prepareToRecord()
            guard recorder.record() else {
                throw NSError(domain: "LocalVoiceAI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mikrofon kaydı başlatılamadı."])
            }

            audioRecorder = recorder
            isRecording = true
            lastTranscript = nil
            whisperStatusText = "Dinliyor…"
            statusText = "Konuş; bitince mikrofon düğmesine tekrar bas."
        } catch {
            isRecording = false
            whisperStatusText = "Kayıt hatası"
            statusText = "Ses kaydı başlatılamadı: \(error.localizedDescription)"
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func stopRecordingAndTranscribe() {
        guard let recorder = audioRecorder, let whisperModel = selectedWhisperModelURL else { return }
        let audioURL = recorder.url

        recorder.stop()
        audioRecorder = nil
        isRecording = false
        isTranscribing = true
        whisperStatusText = "Hazırlanıyor…"
        statusText = "Ses yazıya çevriliyor…"
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let qwenURLToRestore = (lowMemoryVoiceMode ? loadedModelURL : nil)
        if qwenURLToRestore != nil {
            // 1.7B Qwen + Whisper aynı anda RAM'de kalmasın. Model URL ve chat
            // geçmişi korunur; yalnızca llama runtime geçici olarak boşaltılır.
            llamaContext = nil
            statusText = "Qwen geçici olarak boşaltıldı; Whisper çalışıyor…"
        }

        Task {
            var transcript: String?
            var transcriptionError: Error?

            do {
                let samples = try await Task.detached(priority: .userInitiated) {
                    try lvDecodePCM16WaveFile(audioURL)
                }.value

                whisperStatusText = "Model yükleniyor…"
                let whisperContext = try await Task.detached(priority: .userInitiated) {
                    try LVWhisperContext.create(path: whisperModel.path)
                }.value

                whisperStatusText = "Yazıya çeviriyor…"
                let result = try await whisperContext.transcribe(samples: samples, language: "tr")
                transcript = result.trimmingCharacters(in: .whitespacesAndNewlines)
                // whisperContext local scope sonunda serbest bırakılır.
            } catch {
                transcriptionError = error
            }

            // Düşük bellek modunda Qwen'i Whisper tamamen bittikten sonra geri yükle.
            if let restoreURL = qwenURLToRestore {
                statusText = "Qwen yeniden yükleniyor…"
                do {
                    let restored = try await Task.detached(priority: .userInitiated) {
                        try LlamaContext.create_context(path: restoreURL.path)
                    }.value
                    llamaContext = restored
                    loadedModelURL = restoreURL
                } catch {
                    llamaContext = nil
                    loadedModelURL = nil
                    loadedModelName = nil
                    isTranscribing = false
                    whisperStatusText = "Hazır"
                    statusText = "Qwen yeniden yüklenemedi: \(error.localizedDescription)"
                    return
                }
            }

            isTranscribing = false
            updateWhisperStatus()

            if let transcriptionError {
                statusText = "Whisper hatası: \(transcriptionError.localizedDescription)"
                return
            }

            guard let transcript, !transcript.isEmpty else {
                statusText = "Whisper konuşma algılamadı."
                return
            }

            lastTranscript = transcript
            inputText = transcript
            statusText = "Duydum: \(transcript)"

            if autoSendVoice {
                send()
            }
        }
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "tr-TR")
        utterance.rate = 0.48
        synthesizer.speak(utterance)
    }

    private func buildQwenPrompt(from chat: [LVChatMessage]) -> String {
        var prompt = "<|im_start|>system\n\(systemPrompt)"

        prompt += "<|im_end|>\n"

        for message in chat {
            switch message.role {
            case .user:
                prompt += "<|im_start|>user\n\(message.text)<|im_end|>\n"
            case .assistant:
                // Geçmişte yalnızca kullanıcıya gösterdiğimiz final cevabı saklanır;
                // <think> içeriği context'e geri beslenmez.
                prompt += "<|im_start|>assistant\n\(message.text)<|im_end|>\n"
            }
        }

        prompt += "<|im_start|>assistant\n"

        // Qwen3'ün resmi chat template'inde enable_thinking=false olduğunda
        // generation prompt'a boş bir think bloğu eklenir. Bunu aynen taklit
        // ederek reasoning üretimini gerçekten atlıyoruz; /no_think'e bel bağlamıyoruz.
        if loadedModelIsQwen3 && !thinkingEnabled {
            prompt += "<think>\n\n</think>\n\n"
        }

        return prompt
    }

    // Qwen3 thinking çıktısını UI ve TTS'ten ayırır.
    // Streaming sırasında tag'ler parça parça gelebileceği için tüm raw buffer
    // üzerinden her token'da yeniden hesaplıyoruz.
    private func parseQwenOutput(_ raw: String) -> (answer: String, isThinking: Bool) {
        var text = raw

        // En yaygın Qwen3 biçimi: <think>reasoning</think>final answer
        if let closeRange = text.range(of: "</think>", options: .backwards) {
            let answerPart = String(text[closeRange.upperBound...])
            return (cleanSpecialArtifacts(answerPart), false)
        }

        if let openRange = text.range(of: "<think>") {
            let beforeThink = String(text[..<openRange.lowerBound])
            // Thinking devam ederken reasoning'i kullanıcıya göstermiyoruz.
            return (cleanSpecialArtifacts(beforeThink), true)
        }

        // Tag daha henüz tamamlanmadıysa kısa bir süre göstermemek daha temiz.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "<" || trimmed == "<t" || trimmed == "<th" || trimmed == "<thi" || trimmed == "<thin" || trimmed == "<think" {
            return ("", true)
        }

        // Non-thinking modunda Qwen3 bazen boş <think></think> bloğunu special-token
        // davranışına göre hiç göstermeden doğrudan cevaba geçebilir.
        text = cleanSpecialArtifacts(text)
        return (text, false)
    }

    private func cleanSpecialArtifacts(_ text: String) -> String {
        var result = text
        for token in ["<think>", "</think>", "<|im_end|>", "<|endoftext|>"] {
            result = result.replacingOccurrences(of: token, with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ContentView: View {
    @StateObject private var viewModel = LocalVoiceViewModel()
    @State private var showImporter = false
    @State private var showWhisperImporter = false

    private var ggufType: UTType {
        UTType(filenameExtension: "gguf") ?? .data
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                modelBar
                Divider()

                if viewModel.messages.isEmpty {
                    emptyState
                } else {
                    chatList
                }

                Divider()
                composer
            }
            .navigationTitle("LocalVoiceAI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        Toggle("Cevabı sesli oku", isOn: $viewModel.autoSpeak)

                        if viewModel.loadedModelIsQwen3 {
                            Toggle("Derin düşünme", isOn: $viewModel.thinkingEnabled)
                                .disabled(viewModel.isGenerating)
                        }

                        Divider()
                        Toggle("Whisper sesli giriş", isOn: $viewModel.whisperEnabled)
                            .disabled(viewModel.isRecording || viewModel.isTranscribing || viewModel.isGenerating)
                        if viewModel.whisperEnabled {
                            Toggle("Konuşunca otomatik gönder", isOn: $viewModel.autoSendVoice)
                            Toggle("Düşük bellek modu", isOn: $viewModel.lowMemoryVoiceMode)
                        }

                        Divider()
                        Button("Sesi durdur") { viewModel.stopSpeaking() }
                        Divider()
                        Button("Sohbeti temizle", role: .destructive) { viewModel.clearChat() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [ggufType, .data],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        viewModel.importModel(from: url)
                    }
                case .failure(let error):
                    viewModel.statusText = "Dosya seçilemedi: \(error.localizedDescription)"
                }
            }
            .fileImporter(isPresented: $showWhisperImporter,
                          allowedContentTypes: [.data],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        viewModel.importWhisperModel(from: url)
                    }
                case .failure(let error):
                    viewModel.statusText = "Whisper dosyası seçilemedi: \(error.localizedDescription)"
                }
            }
            .onChange(of: viewModel.whisperEnabled) { _ in
                viewModel.whisperToggleChanged()
            }
        }
    }

    private var modelBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(viewModel.loadedModelName == nil ? Color.secondary : Color.green)
                    .frame(width: 9, height: 9)

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.loadedModelName ?? "Model yüklü değil")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(viewModel.statusText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if viewModel.loadedModelIsQwen3 {
                            Text(viewModel.thinkingEnabled ? "THINK" : "NO THINK")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                }

                Spacer()

                Menu {
                    if viewModel.availableModels.isEmpty {
                        Text("Documents içinde GGUF yok")
                    } else {
                        ForEach(viewModel.availableModels, id: \.path) { modelURL in
                            Button(modelURL.lastPathComponent) {
                                viewModel.loadModel(modelURL)
                            }
                        }
                    }

                    Divider()
                    Button("Model listesini yenile") { viewModel.refreshModels() }
                    Button("Dosyalardan GGUF ekle…") { showImporter = true }
                    if viewModel.loadedModelName != nil {
                        Divider()
                        Button("Modeli boşalt", role: .destructive) { viewModel.unloadModel() }
                    }
                } label: {
                    Label("Model", systemImage: "cpu")
                        .font(.callout)
                }
                .disabled(viewModel.isLoadingModel || viewModel.isGenerating || viewModel.isRecording || viewModel.isTranscribing)
            }

            Divider()

            HStack(spacing: 10) {
                Image(systemName: viewModel.isRecording ? "waveform.circle.fill" : "mic.circle")
                    .foregroundStyle(viewModel.whisperEnabled ? Color.accentColor : Color.secondary)
                    .font(.system(size: 20))

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.whisperEnabled ? "Whisper açık" : "Whisper kapalı")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text(viewModel.selectedWhisperModelURL?.lastPathComponent ?? viewModel.whisperStatusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Toggle("", isOn: $viewModel.whisperEnabled)
                    .labelsHidden()
                    .disabled(viewModel.isRecording || viewModel.isTranscribing || viewModel.isGenerating)

                Menu {
                    if viewModel.availableWhisperModels.isEmpty {
                        Text("Documents içinde .bin Whisper modeli yok")
                    } else {
                        ForEach(viewModel.availableWhisperModels, id: \.path) { modelURL in
                            Button {
                                viewModel.selectWhisperModel(modelURL)
                            } label: {
                                if viewModel.selectedWhisperModelURL?.standardizedFileURL == modelURL.standardizedFileURL {
                                    Label(modelURL.lastPathComponent, systemImage: "checkmark")
                                } else {
                                    Text(modelURL.lastPathComponent)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Whisper listesini yenile") { viewModel.refreshWhisperModels() }
                    Button("Dosyalardan Whisper .bin ekle…") { showWhisperImporter = true }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .disabled(viewModel.isRecording || viewModel.isTranscribing)
            }

            if viewModel.whisperEnabled {
                HStack {
                    Text(viewModel.whisperStatusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if viewModel.lowMemoryVoiceMode {
                        Text("Düşük bellek")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
            }

            if let tps = viewModel.lastGenerationTPS {
                HStack {
                    Text(viewModel.loadedModelIsQwen3
                         ? (viewModel.thinkingEnabled ? "Qwen3 · Thinking" : "Qwen3 · Hızlı")
                         : "Chat")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "Son üretim: %.1f token/sn", tps))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "waveform.and.sparkles")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(viewModel.loadedModelName == nil ? "Önce Qwen modelini yükle" : "Sohbete hazır")
                .font(.headline)
            Text(viewModel.loadedModelName == nil
                 ? "Model menüsünden Documents klasöründeki GGUF'u seç veya Dosyalar'dan ekle."
                 : "Qwen3 kullanıyorsan Derin düşünme varsayılan olarak kapalıdır. Whisper'ı açıp bir .bin model seçersen mikrofondan da konuşabilirsin.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chatList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.messages) { message in
                        HStack {
                            if message.role == .user { Spacer(minLength: 42) }

                            Text(message.text.isEmpty
                                 ? (viewModel.thinkingStatus ?? "…")
                                 : message.text)
                                .textSelection(.enabled)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 10)
                                .background(message.role == .user
                                            ? Color.accentColor.opacity(0.16)
                                            : Color.secondary.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .frame(maxWidth: 330, alignment: message.role == .user ? .trailing : .leading)

                            if message.role == .assistant { Spacer(minLength: 42) }
                        }
                        .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.messages.last?.text) { _ in
                if let id = viewModel.messages.last?.id {
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 9) {
            if viewModel.whisperEnabled {
                Button(action: viewModel.toggleRecording) {
                    Image(systemName: viewModel.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 28))
                }
                .disabled(viewModel.loadedModelName == nil ||
                          viewModel.selectedWhisperModelURL == nil ||
                          viewModel.isGenerating ||
                          viewModel.isLoadingModel ||
                          viewModel.isTranscribing)
                .accessibilityLabel(viewModel.isRecording ? "Kaydı bitir" : "Konuş")
            }

            TextField(viewModel.isRecording ? "Dinliyorum…" : "Mesaj yaz…", text: $viewModel.inputText, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .disabled(viewModel.loadedModelName == nil ||
                          viewModel.isGenerating ||
                          viewModel.isRecording ||
                          viewModel.isTranscribing)
                .onSubmit { viewModel.send() }

            if viewModel.isGenerating {
                Button(action: viewModel.requestStop) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 28))
                }
                .accessibilityLabel("Üretimi durdur")
            } else {
                Button(action: viewModel.send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                }
                .disabled(viewModel.loadedModelName == nil ||
                          viewModel.isRecording ||
                          viewModel.isTranscribing ||
                          viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

}
