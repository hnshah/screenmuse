#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore
import Foundation

/// Tests for the narration pipeline: provider factory, prompt parsing,
/// URL resolution, and the Narrator orchestrator with a mock provider.
///
/// No real LLMs are hit. Real-provider integration tests live behind an
/// env-var gate because CI never has an Ollama instance or API key.
final class NarrationTests: XCTestCase {

    // MARK: - Mock provider

    /// Records the last `narrate(...)` call so tests can assert on arguments.
    final class MockProvider: NarrationProvider, @unchecked Sendable {
        let name: String
        let defaultModel: String
        var scriptedResult: NarrationResult
        var scriptedError: Error?
        private(set) var lastFrames: [NarrationFrame] = []
        private(set) var lastConfig: NarrationConfig?
        private(set) var callCount = 0
        private let lock = NSLock()

        init(
            name: String = "mock",
            defaultModel: String = "mock-v1",
            result: NarrationResult = NarrationResult(
                narration: [],
                suggestedChapters: [],
                provider: "mock",
                model: "mock-v1"
            )
        ) {
            self.name = name
            self.defaultModel = defaultModel
            self.scriptedResult = result
        }

        func narrate(frames: [NarrationFrame], config: NarrationConfig) async throws -> NarrationResult {
            lock.lock()
            lastFrames = frames
            lastConfig = config
            callCount += 1
            let error = scriptedError
            let result = scriptedResult
            lock.unlock()
            if let e = error { throw e }
            return result
        }
    }

    // MARK: - Provider factory

    func testProviderFactoryResolvesOllama() {
        let p = Narrator.provider(named: "ollama")
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.name, "ollama")
    }

    func testProviderFactoryResolvesLocalAsOllama() {
        let p = Narrator.provider(named: "local")
        XCTAssertEqual(p?.name, "ollama")
    }

    func testProviderFactoryDefaultsEmptyToOllama() {
        let p = Narrator.provider(named: "")
        XCTAssertEqual(p?.name, "ollama")
    }

    func testProviderFactoryResolvesAnthropic() {
        XCTAssertEqual(Narrator.provider(named: "anthropic")?.name, "anthropic")
        XCTAssertEqual(Narrator.provider(named: "claude")?.name, "anthropic")
    }

    func testProviderFactoryRejectsUnknown() {
        XCTAssertNil(Narrator.provider(named: "gemini"))
        XCTAssertNil(Narrator.provider(named: "totally-made-up"))
    }

    func testKnownProvidersListContainsBoth() {
        XCTAssertTrue(Narrator.knownProviders.contains("ollama"))
        XCTAssertTrue(Narrator.knownProviders.contains("anthropic"))
    }

    // MARK: - Prompt parsing

    func testPromptSystemInstructionContainsSchema() {
        let text = NarrationPrompt.systemInstruction(style: "casual", maxChapters: 3, language: "fr")
        XCTAssertTrue(text.contains("narration"))
        XCTAssertTrue(text.contains("suggested_chapters"))
        XCTAssertTrue(text.contains("casual"))
        XCTAssertTrue(text.contains("3"))
        XCTAssertTrue(text.contains("fr"))
    }

    func testParseResultHandlesRawJSON() throws {
        let raw = #"""
        {"narration":[{"time":0.0,"text":"hello"}],"suggested_chapters":[{"time":1.0,"name":"Start"}]}
        """#
        let r = try NarrationPrompt.parseResult(reply: raw, provider: "mock", model: "m1")
        XCTAssertEqual(r.narration.count, 1)
        XCTAssertEqual(r.narration.first?.text, "hello")
        XCTAssertEqual(r.suggestedChapters.first?.name, "Start")
        XCTAssertEqual(r.provider, "mock")
        XCTAssertEqual(r.model, "m1")
    }

    func testParseResultStripsJSONFences() throws {
        let raw = """
        ```json
        {"narration":[{"time":0,"text":"hi"}],"suggested_chapters":[]}
        ```
        """
        let r = try NarrationPrompt.parseResult(reply: raw, provider: "mock", model: "m1")
        XCTAssertEqual(r.narration.first?.text, "hi")
    }

    func testParseResultExtractsEmbeddedJSON() throws {
        // LLMs occasionally sneak in commentary even when told not to —
        // the parser must still find the embedded JSON object.
        let raw = """
        Sure! Here's the result:
        {"narration":[{"time":0,"text":"Hello world"}],"suggested_chapters":[]}
        Let me know if you need more detail.
        """
        let r = try NarrationPrompt.parseResult(reply: raw, provider: "mock", model: "m1")
        XCTAssertEqual(r.narration.first?.text, "Hello world")
    }

    func testParseResultThrowsOnNonJSON() {
        let raw = "totally not json"
        XCTAssertThrowsError(
            try NarrationPrompt.parseResult(reply: raw, provider: "mock", model: "m1")
        )
    }

    func testExtractJSONObjectHandlesNestedBraces() {
        let src = "preamble {\"a\": 1, \"b\": {\"c\": 2}} trailer"
        let extracted = NarrationPrompt.extractJSONObject(from: src)
        XCTAssertEqual(extracted, "{\"a\": 1, \"b\": {\"c\": 2}}")
    }

    func testExtractJSONObjectReturnsNilIfNoBraces() {
        XCTAssertNil(NarrationPrompt.extractJSONObject(from: "no braces here"))
    }

    func testExtractJSONObjectIgnoresBracesInsideStrings() {
        // A { or } inside a JSON string literal must not affect depth counting.
        let src = #"{"text": "this { is } fine"}"#
        XCTAssertEqual(NarrationPrompt.extractJSONObject(from: src), src)
    }

    // MARK: - Ollama URL resolution

    func testOllamaResolveBaseURLDefaultsToLocalhost() {
        // Save + clear env so the test is hermetic regardless of host setup.
        let original = ProcessInfo.processInfo.environment["OLLAMA_HOST"]
        setenv("OLLAMA_HOST", "", 1)
        defer {
            if let v = original { setenv("OLLAMA_HOST", v, 1) } else { unsetenv("OLLAMA_HOST") }
        }
        let url = OllamaNarrationProvider.resolveBaseURL(override: nil)
        XCTAssertEqual(url.absoluteString, "http://localhost:11434")
    }

    func testOllamaResolveBaseURLRespectsOverride() {
        let custom = URL(string: "http://my-ollama:9000")!
        XCTAssertEqual(
            OllamaNarrationProvider.resolveBaseURL(override: custom).absoluteString,
            "http://my-ollama:9000"
        )
    }

    func testOllamaResolveBaseURLUsesEnvVar() {
        let original = ProcessInfo.processInfo.environment["OLLAMA_HOST"]
        setenv("OLLAMA_HOST", "192.168.1.42:11434", 1)
        defer {
            if let v = original { setenv("OLLAMA_HOST", v, 1) } else { unsetenv("OLLAMA_HOST") }
        }
        let url = OllamaNarrationProvider.resolveBaseURL(override: nil)
        XCTAssertEqual(url.absoluteString, "http://192.168.1.42:11434")
    }

    // MARK: - Narrator orchestration with mock provider

    func testNarratorInvokesProviderWithConfig() async throws {
        let mock = MockProvider(result: NarrationResult(
            narration: [NarrationEntry(time: 0, text: "frame one")],
            suggestedChapters: [ChapterSuggestion(time: 0, name: "Intro")],
            provider: "mock",
            model: "mock-v1"
        ))
        let narrator = Narrator(provider: mock)
        let fakeFrame = NarrationFrame(
            time: 0,
            imageData: Data([0xFF, 0xD8, 0xFF, 0xE0]),
            width: 10,
            height: 10
        )
        let config = NarrationConfig(model: "mock-v1", style: "technical", maxChapters: 3, language: "en")
        let result = try await mock.narrate(frames: [fakeFrame], config: config)
        XCTAssertEqual(result.narration.count, 1)
        XCTAssertEqual(mock.callCount, 1)
        XCTAssertEqual(mock.lastConfig?.style, "technical")
        _ = narrator  // keep narrator in scope
    }

    func testNarratorPropagatesProviderError() async {
        let mock = MockProvider()
        mock.scriptedError = NarrationError.providerUnreachable("http://localhost:11434")
        let fakeFrame = NarrationFrame(
            time: 0,
            imageData: Data([0xFF]),
            width: 1,
            height: 1
        )
        do {
            _ = try await mock.narrate(
                frames: [fakeFrame],
                config: NarrationConfig(model: "m")
            )
            XCTFail("expected error")
        } catch NarrationError.providerUnreachable {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - NarrationConfig defaults

    func testNarrationConfigDefaults() {
        let c = NarrationConfig(model: "test")
        XCTAssertEqual(c.model, "test")
        XCTAssertEqual(c.style, "technical")
        XCTAssertEqual(c.maxChapters, 5)
        XCTAssertEqual(c.language, "en")
        XCTAssertEqual(c.temperature, 0.3, accuracy: 0.001)
        XCTAssertNil(c.apiKey)
        XCTAssertNil(c.endpoint)
    }

    // MARK: - Codable round-trip

    func testNarrationResultCodableRoundTrip() throws {
        let original = NarrationResult(
            narration: [
                NarrationEntry(time: 0.5, text: "the page loads"),
                NarrationEntry(time: 2.0, text: "user types a query")
            ],
            suggestedChapters: [
                ChapterSuggestion(time: 0.0, name: "Load"),
                ChapterSuggestion(time: 2.0, name: "Query")
            ],
            provider: "ollama",
            model: "llava:7b"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NarrationResult.self, from: data)
        XCTAssertEqual(decoded.narration.count, 2)
        XCTAssertEqual(decoded.suggestedChapters.count, 2)
        XCTAssertEqual(decoded.provider, "ollama")
        XCTAssertEqual(decoded.model, "llava:7b")

        // Snake-case keys must survive the round-trip for API compatibility.
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("suggested_chapters"))
    }
}
#endif
