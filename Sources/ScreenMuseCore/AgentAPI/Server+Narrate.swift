import Foundation
import Network

// MARK: - Narration Handler (POST /narrate)
//
// Generates timestamped narration + chapter suggestions for an existing
// recording using a vision LLM. Supports local Ollama (default) and
// Anthropic Claude. Long-running — supports async=true job dispatch.

extension ScreenMuseServer {

    func handleNarrate(body: [String: Any], connection: NWConnection, reqID: Int) async {
        if await dispatchAsync(endpoint: "/narrate", body: body, connection: connection, reqID: reqID,
                               handler: { b, c, r in await self.handleNarrate(body: b, connection: c, reqID: r) }) { return }

        // ── Resolve source video ───────────────────────────────────────
        guard let src = resolveSourceURL(from: body, fallback: currentVideoURL),
              FileManager.default.fileExists(atPath: src.path) else {
            sendResponse(connection: connection, status: 404, body: [
                "error": "no video available — record first or pass 'source': '/path/to/video.mp4'",
                "code": "NO_VIDEO"
            ])
            return
        }

        // ── Resolve provider ───────────────────────────────────────────
        let providerName = (body["provider"] as? String ?? "ollama").lowercased()
        guard let provider = Narrator.provider(named: providerName) else {
            sendResponse(connection: connection, status: 400, body: [
                "error": "unsupported provider '\(providerName)'",
                "code": "UNSUPPORTED_PROVIDER",
                "known_providers": Narrator.knownProviders
            ])
            return
        }

        // ── Build config ────────────────────────────────────────────────
        let model = body["model"] as? String ?? provider.defaultModel
        let frameCount = max(1, min(24, body["frame_count"] as? Int ?? 6))
        let maxChapters = max(0, min(12, body["max_chapters"] as? Int ?? 5))
        let style = body["style"] as? String ?? "technical"
        let language = body["language"] as? String ?? "en"
        let temperature = body["temperature"] as? Double ?? 0.3
        let apiKey = body["api_key"] as? String
        let endpointString = body["endpoint"] as? String
        let endpoint: URL? = endpointString.flatMap { URL(string: $0) }
        let save = body["save"] as? Bool ?? true

        let config = NarrationConfig(
            model: model,
            style: style,
            maxChapters: maxChapters,
            language: language,
            apiKey: apiKey,
            endpoint: endpoint,
            temperature: temperature
        )

        smLog.info("[\(reqID)] /narrate src=\(src.lastPathComponent) provider=\(providerName) model=\(model) frames=\(frameCount)", category: .server)
        smLog.usage("NARRATE", details: [
            "provider": providerName,
            "model": model,
            "frames": "\(frameCount)"
        ])

        // ── Run the pipeline ───────────────────────────────────────────
        let narrator = Narrator(provider: provider)
        do {
            let result = try await narrator.run(
                video: src,
                frameCount: frameCount,
                config: config
            )

            var responseBody: [String: Any] = [
                "narration": result.narration.map { ["time": $0.time, "text": $0.text] as [String: Any] },
                "suggested_chapters": result.suggestedChapters.map { ["time": $0.time, "name": $0.name] as [String: Any] },
                "provider": result.provider,
                "model": result.model,
                "frames_used": frameCount,
                "source": src.path
            ]

            // Write narration.json beside the video if requested
            if save {
                if let jsonPath = writeNarrationFile(result: result, beside: src) {
                    responseBody["narration_file"] = jsonPath
                }
            }

            smLog.info("[\(reqID)] ✅ /narrate done — \(result.narration.count) entries, \(result.suggestedChapters.count) chapters", category: .server)
            smLog.usage("NARRATE DONE", details: [
                "entries": "\(result.narration.count)",
                "chapters": "\(result.suggestedChapters.count)"
            ])
            sendResponse(connection: connection, status: 200, body: responseBody)
        } catch let error as NarrationError {
            smLog.error("[\(reqID)] /narrate failed: \(error.localizedDescription)", category: .server)
            let status: Int
            let code: String
            switch error {
            case .noFramesExtracted:         status = 500; code = "NO_FRAMES"
            case .providerUnreachable:       status = 503; code = "PROVIDER_UNREACHABLE"
            case .missingAPIKey:             status = 400; code = "MISSING_API_KEY"
            case .providerHTTPStatus(let s, _):
                status = (s >= 400 && s < 500) ? 400 : 502
                code = "PROVIDER_HTTP_\(s)"
            case .providerResponseMalformed: status = 502; code = "PROVIDER_MALFORMED"
            case .providerRequestFailed:     status = 500; code = "PROVIDER_REQUEST_FAILED"
            case .unsupportedProvider:       status = 400; code = "UNSUPPORTED_PROVIDER"
            }
            sendResponse(connection: connection, status: status, body: [
                "error": error.localizedDescription,
                "code": code,
                "provider": providerName
            ])
        } catch {
            smLog.error("[\(reqID)] /narrate failed (unknown): \(error.localizedDescription)", category: .server)
            sendResponse(connection: connection, status: 500, body: [
                "error": error.localizedDescription,
                "code": "NARRATE_ERROR",
                "provider": providerName
            ])
        }
    }

    // MARK: - Helpers

    /// Serialize a `NarrationResult` to `narration.json` beside the source
    /// video so the file becomes part of the recording's artifacts folder.
    /// Returns the written path, or nil on failure.
    private func writeNarrationFile(result: NarrationResult, beside src: URL) -> String? {
        let outputDir = src.deletingLastPathComponent()
        let stem = src.deletingPathExtension().lastPathComponent
        let outputFile = outputDir.appendingPathComponent("\(stem).narration.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(result)
            try data.write(to: outputFile, options: .atomic)
            return outputFile.path
        } catch {
            smLog.warning("Could not write narration file at \(outputFile.path): \(error.localizedDescription)", category: .server)
            return nil
        }
    }
}
