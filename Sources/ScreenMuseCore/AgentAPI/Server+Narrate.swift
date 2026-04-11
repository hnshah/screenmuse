import AVFoundation
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

        // ── Resolve provider (request > config > default) ──────────────
        // Precedence: request body > ~/.screenmuse.json narration block > hardcoded default.
        let narrationDefaults = loadedConfig.narration
        let providerName = (
            body["provider"] as? String
            ?? narrationDefaults?.provider
            ?? "ollama"
        ).lowercased()
        guard let provider = Narrator.provider(named: providerName) else {
            sendResponse(connection: connection, status: 400, body: [
                "error": "unsupported provider '\(providerName)'",
                "code": "UNSUPPORTED_PROVIDER",
                "known_providers": Narrator.knownProviders
            ])
            return
        }

        // ── Build config ────────────────────────────────────────────────
        let model = body["model"] as? String
            ?? narrationDefaults?.model
            ?? provider.defaultModel
        let frameCount = max(1, min(24,
            body["frame_count"] as? Int
            ?? narrationDefaults?.frameCount
            ?? 6))
        let maxChapters = max(0, min(12,
            body["max_chapters"] as? Int
            ?? narrationDefaults?.maxChapters
            ?? 5))
        let style = body["style"] as? String
            ?? narrationDefaults?.style
            ?? "technical"
        let language = body["language"] as? String
            ?? narrationDefaults?.language
            ?? "en"
        let temperature = body["temperature"] as? Double ?? 0.3
        let apiKey = body["api_key"] as? String ?? narrationDefaults?.apiKey
        let endpointString = body["endpoint"] as? String ?? narrationDefaults?.endpoint
        let endpoint: URL? = endpointString.flatMap { URL(string: $0) }
        let save = body["save"] as? Bool ?? true

        // v2 subtitle + chapter options ----------------------------------
        let subtitleFormats: [String] = {
            if let arr = body["subtitles"] as? [String] {
                return arr.map { $0.lowercased() }.filter { $0 == "srt" || $0 == "vtt" }
            }
            if let single = body["subtitles"] as? String {
                let lower = single.lowercased()
                return (lower == "srt" || lower == "vtt") ? [lower] : []
            }
            return []
        }()
        let applyChapters = body["apply_chapters"] as? Bool ?? false

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

            // Write subtitle sidecars (SRT + VTT) beside the video.
            // Subtitles are always written when requested, regardless of
            // `save` — a caller who wants the JSON file suppressed may
            // still want captions for upload.
            if !subtitleFormats.isEmpty {
                let videoDuration = videoDurationSeconds(of: src)
                let formatter = SubtitleFormatter(
                    defaultLastCueDuration: 4.0,
                    videoDuration: videoDuration
                )
                var subtitleFiles: [String: String] = [:]
                for format in subtitleFormats {
                    let ext = format
                    let text = (format == "srt")
                        ? formatter.srt(from: result)
                        : formatter.vtt(from: result)
                    if let path = writeSubtitleFile(text: text, ext: ext, beside: src) {
                        subtitleFiles[format] = path
                    }
                }
                if !subtitleFiles.isEmpty {
                    responseBody["subtitle_files"] = subtitleFiles
                }
            }

            // Apply the suggested chapters into the current session's
            // chapter list if the caller opted in. Only populates when
            // recording is active OR when we have a current session —
            // otherwise the chapters would land nowhere visible to /stop.
            if applyChapters {
                let appliedCount = applyNarratedChapters(result.suggestedChapters)
                responseBody["chapters_applied"] = appliedCount
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

    /// Write `{stem}.{ext}` beside the source video. Extracted from the
    /// narration writer so subtitles can reuse the layout.
    /// Returns the written path, or nil on failure.
    private func writeSubtitleFile(text: String, ext: String, beside src: URL) -> String? {
        let outputDir = src.deletingLastPathComponent()
        let stem = src.deletingPathExtension().lastPathComponent
        let outputFile = outputDir.appendingPathComponent("\(stem).\(ext)")
        do {
            try text.write(to: outputFile, atomically: true, encoding: .utf8)
            return outputFile.path
        } catch {
            smLog.warning("Could not write \(ext.uppercased()) subtitle at \(outputFile.path): \(error.localizedDescription)", category: .server)
            return nil
        }
    }

    /// Read the source video's duration so subtitle end times can be
    /// clamped to it. Returns nil if the asset can't be probed —
    /// the formatter will then fall back to an open-ended last cue.
    private func videoDurationSeconds(of url: URL) -> Double? {
        let asset = AVURLAsset(url: url)
        let cmDuration = asset.duration
        let seconds = CMTimeGetSeconds(cmDuration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /// Apply the LLM's chapter suggestions as real chapters on the
    /// current session. Returns the number of chapters added. Skips
    /// chapters whose time is outside [0, currentElapsed] when a
    /// recording is active, because /chapter only accepts monotonic
    /// timestamps within the active session.
    private func applyNarratedChapters(_ suggestions: [ChapterSuggestion]) -> Int {
        guard !suggestions.isEmpty else { return 0 }
        var added = 0
        for suggestion in suggestions {
            // Respect the same bounds /chapter enforces — time must be
            // in the current session window.
            if isRecording {
                let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
                guard suggestion.time >= 0 && suggestion.time <= elapsed else { continue }
            }
            chapters.append((name: suggestion.name, time: suggestion.time))
            added += 1
        }
        return added
    }

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
