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
    @Published var lastGenerationTPS: Double?

    private var llamaContext: LlamaContext?
    private let synthesizer = AVSpeechSynthesizer()
    private let maxNewTokens = 384

    private let systemPrompt = """
    Sen Türkçe konuşan yardımcı bir yapay zeka asistanısın. Kullanıcı başka bir dil kullanırsa o dilde cevap verebilirsin. Doğal, doğru ve doğrudan cevaplar ver. Kullanıcının istemediği bir görevi uydurma. Sohbet rollerini taklit etme; yalnızca assistant cevabını üret.
    """

    init() {
        refreshModels()
    }

    var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
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
        guard !isLoadingModel, !isGenerating else { return }

        isLoadingModel = true
        statusText = "Model yükleniyor…"
        loadedModelName = nil
        lastGenerationTPS = nil

        let path = url.path
        Task {
            do {
                // Model yükleme ana UI thread'ini kilitlemesin.
                let newContext = try await Task.detached(priority: .userInitiated) {
                    try LlamaContext.create_context(path: path)
                }.value

                llamaContext = newContext
                loadedModelName = url.lastPathComponent
                statusText = "Hazır"
                messages.removeAll()
            } catch {
                llamaContext = nil
                statusText = "Model yüklenemedi: \(error.localizedDescription)"
            }
            isLoadingModel = false
        }
    }

    func unloadModel() {
        guard !isGenerating else { return }
        llamaContext = nil
        loadedModelName = nil
        messages.removeAll()
        lastGenerationTPS = nil
        statusText = "Model seç"
    }

    func clearChat() {
        guard !isGenerating else { return }
        messages.removeAll()
        lastGenerationTPS = nil
        Task { await llamaContext?.clear() }
    }

    func send() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let context = llamaContext,
              !isGenerating else { return }

        inputText = ""
        messages.append(LVChatMessage(role: .user, text: trimmed))

        // iPhone 13 / 2K context için son konuşmaları tutuyoruz.
        // Sistem mesajı + son 8 sohbet mesajı, Qwen2.5 ChatML formatında modele gider.
        let prompt = buildQwen25Prompt(from: Array(messages.suffix(8)))
        let assistantID = UUID()
        messages.append(LVChatMessage(id: assistantID, role: .assistant, text: ""))

        isGenerating = true
        statusText = "Yanıt oluşturuluyor…"
        lastGenerationTPS = nil

        Task {
            await context.clear()
            await context.completion_init(text: prompt)

            let generationStart = DispatchTime.now().uptimeNanoseconds
            var generatedTokens = 0
            var shouldStop = false

            while await !context.is_done && generatedTokens < maxNewTokens && !shouldStop {
                var chunk = await context.completion_loop()
                generatedTokens += 1

                // Çoğu Qwen GGUF'unda <|im_end|> EOG'dur. Yine de metin olarak
                // dönerse kullanıcıya göstermeden burada kesiyoruz.
                for stop in ["<|im_end|>", "<|endoftext|>"] {
                    if let range = chunk.range(of: stop) {
                        chunk = String(chunk[..<range.lowerBound])
                        shouldStop = true
                    }
                }

                if !chunk.isEmpty,
                   let index = messages.firstIndex(where: { $0.id == assistantID }) {
                    messages[index].text += chunk
                }
            }

            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - generationStart) / 1_000_000_000.0
            if elapsed > 0, generatedTokens > 0 {
                lastGenerationTPS = Double(generatedTokens) / elapsed
            }

            await context.clear()
            isGenerating = false
            statusText = "Hazır"

            if let index = messages.firstIndex(where: { $0.id == assistantID }) {
                let answer = messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
                if answer.isEmpty {
                    messages[index].text = "(Model görünür bir yanıt üretmedi.)"
                } else if autoSpeak {
                    speak(answer)
                }
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

    private func buildQwen25Prompt(from chat: [LVChatMessage]) -> String {
        var prompt = "<|im_start|>system\n\(systemPrompt)<|im_end|>\n"

        for message in chat {
            switch message.role {
            case .user:
                prompt += "<|im_start|>user\n\(message.text)<|im_end|>\n"
            case .assistant:
                prompt += "<|im_start|>assistant\n\(message.text)<|im_end|>\n"
            }
        }

        prompt += "<|im_start|>assistant\n"
        return prompt
    }
}

struct ContentView: View {
    @StateObject private var viewModel = LocalVoiceViewModel()
    @State private var showImporter = false

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
                    Text(viewModel.statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
                .disabled(viewModel.isLoadingModel || viewModel.isGenerating)
            }

            if let tps = viewModel.lastGenerationTPS {
                HStack {
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
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(viewModel.loadedModelName == nil ? "Önce Qwen modelini yükle" : "Sohbete hazır")
                .font(.headline)
            Text(viewModel.loadedModelName == nil
                 ? "Model menüsünden Documents klasöründeki GGUF'u seç veya Dosyalar'dan ekle."
                 : "Örneğin “Merhaba, nasılsın?” yaz. Bu sürüm Qwen2.5-Instruct için doğru chat formatını kullanır.")
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

                            Text(message.text.isEmpty ? "…" : message.text)
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
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Mesaj yaz…", text: $viewModel.inputText, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .disabled(viewModel.loadedModelName == nil || viewModel.isGenerating)
                .onSubmit { viewModel.send() }

            Button(action: viewModel.send) {
                Image(systemName: viewModel.isGenerating ? "hourglass" : "arrow.up.circle.fill")
                    .font(.system(size: 28))
            }
            .disabled(viewModel.loadedModelName == nil ||
                      viewModel.isGenerating ||
                      viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}
