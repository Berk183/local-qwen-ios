import Foundation
import whisper

enum LVWhisperError: LocalizedError {
    case modelLoadFailed
    case transcriptionFailed(Int32)
    case invalidWaveFile
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed:
            return "Whisper modeli yüklenemedi."
        case .transcriptionFailed(let code):
            return "Whisper transkripsiyonu başarısız oldu (kod: \(code))."
        case .invalidWaveFile:
            return "Kaydedilen WAV dosyası okunamadı."
        case .emptyAudio:
            return "Kaydedilen ses boş görünüyor."
        }
    }
}

actor LVWhisperContext {
    private var context: OpaquePointer

    private init(context: OpaquePointer) {
        self.context = context
    }

    deinit {
        whisper_free(context)
    }

    static func create(path: String) throws -> LVWhisperContext {
        var params = whisper_context_default_params()

        // This LocalVoiceAI build intentionally keeps Whisper CPU-only.
        // Qwen already uses Metal; isolating Whisper from Metal avoids two
        // independent ggml Metal runtimes competing inside the same app and
        // keeps peak memory behavior more predictable on iPhone 13.
        params.use_gpu = false
        params.flash_attn = false

        guard let ctx = whisper_init_from_file_with_params(path, params) else {
            throw LVWhisperError.modelLoadFailed
        }
        return LVWhisperContext(context: ctx)
    }

    func transcribe(samples: [Float], language: String = "tr") throws -> String {
        guard !samples.isEmpty else { throw LVWhisperError.emptyAudio }

        let coreCount = ProcessInfo.processInfo.processorCount
        let nThreads = Int32(max(1, min(4, coreCount - 2)))
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)

        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.n_threads = nThreads
        params.offset_ms = 0
        params.no_context = true
        params.single_segment = false

        whisper_reset_timings(context)

        let result: Int32 = language.withCString { lang in
            params.language = lang
            return samples.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return -1 }
                return whisper_full(context, params, base, Int32(buffer.count))
            }
        }

        guard result == 0 else {
            throw LVWhisperError.transcriptionFailed(result)
        }

        let count = whisper_full_n_segments(context)
        var transcription = ""
        if count > 0 {
            for i in 0..<count {
                if let ptr = whisper_full_get_segment_text(context, i) {
                    transcription += String(cString: ptr)
                }
            }
        }

        return transcription.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func lvDecodePCM16WaveFile(_ url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    guard data.count >= 44 else { throw LVWhisperError.invalidWaveFile }

    // AVAudioRecorder below writes the standard 16-kHz mono PCM WAV format.
    // Locate the "data" chunk instead of assuming an exact 44-byte header so
    // the decoder also tolerates optional WAV metadata chunks.
    let bytes = [UInt8](data)
    var dataStart: Int?
    var index = 12

    while index + 8 <= bytes.count {
        let id = String(bytes: bytes[index..<(index + 4)], encoding: .ascii) ?? ""
        let chunkSize = Int(UInt32(bytes[index + 4]) |
                            (UInt32(bytes[index + 5]) << 8) |
                            (UInt32(bytes[index + 6]) << 16) |
                            (UInt32(bytes[index + 7]) << 24))
        let payloadStart = index + 8

        if id == "data" {
            dataStart = payloadStart
            break
        }

        // RIFF chunks are padded to an even byte boundary.
        index = payloadStart + chunkSize + (chunkSize % 2)
    }

    guard let start = dataStart, start < bytes.count else {
        throw LVWhisperError.invalidWaveFile
    }

    var samples: [Float] = []
    samples.reserveCapacity((bytes.count - start) / 2)

    var i = start
    while i + 1 < bytes.count {
        let raw = UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
        let sample = Int16(bitPattern: raw)
        samples.append(max(-1.0, min(Float(sample) / 32768.0, 1.0)))
        i += 2
    }

    guard !samples.isEmpty else { throw LVWhisperError.emptyAudio }
    return samples
}
