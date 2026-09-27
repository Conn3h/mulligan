import AVFoundation
import FluidAudio
import Foundation
import Synchronization
import Testing
@testable import Mulligan

/// End-to-end through the real engine with speech synthesised by `say`. Runs only when the
/// Parakeet models are already in FluidAudio's cache; it never downloads them, so on a
/// machine without the models it records nothing and passes.
@Suite(.serialized)
struct ParakeetSpeechEngineTests {
    private static let phrase = "the quick brown fox jumps over the lazy dog"
    private static let expectedFragment = "quick brown fox"
    private static let modelWait: Duration = .seconds(180)
    private static let pollInterval: Duration = .milliseconds(250)
    private static let feedFrames: AVAudioFrameCount = 2048

    @Test func transcribesSynthesisedSpeech() async throws {
        let cache = AsrModels.defaultCacheDirectory(for: ParakeetModels.version)
        guard AsrModels.modelsExist(at: cache) else {
            return
        }
        try await Self.waitForModels()

        let audioURL = try Self.synthesise(Self.phrase)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let engine = ParakeetSpeechEngine()
        let snapshots = try await engine.start()
        let format = try #require(await engine.preferredInputFormat())
        for chunk in try Self.chunks(of: audioURL, in: format) {
            await engine.feed(chunk)
        }
        await engine.finish()

        var finalText: String?
        var sawNonFinal = false
        for try await snapshot in snapshots {
            if snapshot.isFinal {
                finalText = snapshot.text
            } else {
                sawNonFinal = true
            }
        }
        let text = try #require(finalText)
        #expect(text.lowercased().contains(Self.expectedFragment), "got: \(text)")
        _ = sawNonFinal
    }

    /// Vocabulary boosting needs the CTC model as well; exercised only when both are cached.
    @Test func transcribesWithBiasPhrasesConfigured() async throws {
        let cache = AsrModels.defaultCacheDirectory(for: ParakeetModels.version)
        guard AsrModels.modelsExist(at: cache),
              CtcModels.modelsExist(at: CtcModels.defaultCacheDirectory()) else {
            return
        }
        try await Self.waitForModels()

        let audioURL = try Self.synthesise(Self.phrase)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        // None of these are spoken; boosting must leave the sentence alone.
        let phrases = ["Claude Code", "Mulligan", "Kubernetes"]
        let engine = ParakeetSpeechEngine(biasPhrases: phrases)
        let snapshots = try await engine.start()
        let format = try #require(await engine.preferredInputFormat())
        for chunk in try Self.chunks(of: audioURL, in: format) {
            await engine.feed(chunk)
        }
        await engine.finish()

        var finalText: String?
        for try await snapshot in snapshots where snapshot.isFinal {
            finalText = snapshot.text
        }
        let text = try #require(finalText)
        #expect(text.lowercased().contains(Self.expectedFragment), "got: \(text)")
        for phrase in phrases {
            #expect(!text.lowercased().contains(phrase.lowercased()), "unspoken phrase injected: \(text)")
        }
    }

    /// Ordinary English near a real personal dictionary must survive boosting: "alright"
    /// is not Playwright, "make sure" is not Maestro, and "latest transcripts" is not
    /// "Vitest TypeScript". The vocabulary mirrors a live dictionary so the library's
    /// size-based threshold applies. Exercised only when both model sets are cached.
    @Test func boostingLeavesOrdinaryWordsAlone() async throws {
        let cache = AsrModels.defaultCacheDirectory(for: ParakeetModels.version)
        guard AsrModels.modelsExist(at: cache),
              CtcModels.modelsExist(at: CtcModels.defaultCacheDirectory()) else {
            return
        }
        try await Self.waitForModels()

        let audioURL = try Self.synthesise("alright, make sure the latest transcripts are pushed")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let engine = ParakeetSpeechEngine(biasPhrases: Self.developerVocabulary)
        let snapshots = try await engine.start()
        let format = try #require(await engine.preferredInputFormat())
        for chunk in try Self.chunks(of: audioURL, in: format) {
            await engine.feed(chunk)
        }
        await engine.finish()

        var finalText: String?
        for try await snapshot in snapshots where snapshot.isFinal {
            finalText = snapshot.text
        }
        let text = try #require(finalText).lowercased()
        for expected in ["make sure", "latest", "transcripts"] {
            #expect(text.contains(expected), "lost \(expected): \(text)")
        }
        for phrase in ["playwright", "maestro", "vitest", "typescript"] {
            #expect(!text.contains(phrase), "unspoken phrase injected: \(text)")
        }
    }

    /// The tighter gates must not cost the terms that are actually spoken.
    @Test func boostingKeepsSpokenTerms() async throws {
        let cache = AsrModels.defaultCacheDirectory(for: ParakeetModels.version)
        guard AsrModels.modelsExist(at: cache),
              CtcModels.modelsExist(at: CtcModels.defaultCacheDirectory()) else {
            return
        }
        try await Self.waitForModels()

        let audioURL = try Self.synthesise("push the fix to github and run playwright and vitest")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let engine = ParakeetSpeechEngine(biasPhrases: Self.developerVocabulary)
        let snapshots = try await engine.start()
        let format = try #require(await engine.preferredInputFormat())
        for chunk in try Self.chunks(of: audioURL, in: format) {
            await engine.feed(chunk)
        }
        await engine.finish()

        var finalText: String?
        for try await snapshot in snapshots where snapshot.isFinal {
            finalText = snapshot.text
        }
        let text = try #require(finalText).lowercased()
        for expected in ["github", "playwright", "vitest"] {
            #expect(text.contains(expected), "lost \(expected): \(text)")
        }
    }

    /// A realistic 36-term developer dictionary, the shape that produced the false
    /// replacements in the field.
    private static let developerVocabulary = [
        "Daymend", "Mulligan", "Codex", "Claude Code", "Supabase", "Vercel", "PostHog",
        "RevenueCat", "Expo", "React Native", "Next.js", "TypeScript", "Vitest", "Stryker",
        "Maestro", "Sentry", "Upstash", "TestFlight", "App Store Connect", "Xcode", "GitHub",
        "Playwright", "Zod", "Hermes", "SwiftUI", "Postgres", "Anthropic", "OpenAI", "repo",
        "PR", "worktree", "rebase", "i18n", "RLS", "MCP", "herdr",
    ]

    @Test func finishBeforeAnyAudioYieldsEmptyFinal() async throws {
        let cache = AsrModels.defaultCacheDirectory(for: ParakeetModels.version)
        guard AsrModels.modelsExist(at: cache) else {
            return
        }
        try await Self.waitForModels()

        let engine = ParakeetSpeechEngine()
        let snapshots = try await engine.start()
        await engine.finish()
        var finalText: String?
        for try await snapshot in snapshots where snapshot.isFinal {
            finalText = snapshot.text
        }
        #expect(finalText == "")
    }

    // MARK: Helpers

    @MainActor
    private static func waitForModels() async throws {
        ParakeetModels.shared.prepare()
        let clock = ContinuousClock()
        let deadline = clock.now + modelWait
        while clock.now < deadline {
            switch ParakeetModels.shared.state {
            case .ready:
                return
            case .failed(let reason):
                Issue.record("Parakeet models failed to load: \(reason)")
                return
            default:
                try await Task.sleep(for: pollInterval)
            }
        }
        Issue.record("Parakeet models did not load within \(modelWait)")
    }

    private static func synthesise(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mulligan-parakeet-\(UUID().uuidString).aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, text]
        try process.run()
        // `say` can wedge at the system level; an unbounded wait hung the whole suite.
        let deadline = Date().addingTimeInterval(sayTimeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            Issue.record("/usr/bin/say did not finish within \(sayTimeout) s")
            throw CancellationError()
        }
        try #require(process.terminationStatus == 0)
        return url
    }

    private static let sayTimeout: TimeInterval = 30

    /// Reads the whole file, converts it to `format`, and slices it as capture would.
    private static func chunks(of url: URL, in format: AVAudioFormat) throws -> [AudioChunk] {
        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        let source = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        try file.read(into: source)

        let converter = try #require(AVAudioConverter(from: file.processingFormat, to: format))
        let ratio = format.sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + feedFrames
        let converted = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity))
        // Same hand-off shape as `AudioCapture.convert`: the buffer crosses into the input
        // block inside an `AudioChunk`, and a lock hands it over exactly once.
        let input = AudioChunk(buffer: source)
        let handedOver = Mutex(false)
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            let first = handedOver.withLock { taken in
                if taken {
                    return false
                }
                taken = true
                return true
            }
            if first {
                status.pointee = .haveData
                return input.buffer
            }
            status.pointee = .endOfStream
            return nil
        }
        if let conversionError {
            throw conversionError
        }

        var result: [AudioChunk] = []
        var offset: AVAudioFrameCount = 0
        while offset < converted.frameLength {
            let length = min(feedFrames, converted.frameLength - offset)
            let piece = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length))
            piece.frameLength = length
            let src = try #require(converted.floatChannelData)
            let dst = try #require(piece.floatChannelData)
            dst[0].update(from: src[0] + Int(offset), count: Int(length))
            result.append(AudioChunk(buffer: piece))
            offset += length
        }
        return result
    }
}
