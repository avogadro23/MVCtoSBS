import Foundation

// MARK: - Tools

enum Tools {
    static let folderKey = "toolsFolder"
    static let decoderKey = "decoderPath"
    static var supportDir: String { NSHomeDirectory() + "/Library/Application Support/MVCtoSBS" }

    /// Before the rename the app used bundle ID com.example.sbsconverter; carry its saved tool locations over.
    static func migrateLegacyPrefs() {
        guard let old = UserDefaults(suiteName: "com.example.sbsconverter") else { return }
        let new = UserDefaults.standard
        for key in [folderKey, decoderKey] where new.string(forKey: key) == nil {
            if let v = old.string(forKey: key) { new.set(v, forKey: key) }
        }
    }

    static let searchSummary = "saved location, the app bundle, /opt/homebrew/bin, /usr/local/bin, ~/ffmpeg-bin, ~/bin, ~/.local/bin and your shell PATH"

    private static func isExec(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    /// Order: user-chosen folder, app bundle, common install dirs, then whatever the login shell's PATH says.
    static func find(_ name: String) -> URL? {
        var candidates: [String] = []
        if let f = UserDefaults.standard.string(forKey: folderKey) { candidates.append(f + "/" + name) }
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent(name).path) }
        candidates.append(supportDir + "/" + name)
        candidates.append(NSHomeDirectory() + "/Library/Application Support/SBSConverter/" + name)   // pre-rename location
        candidates += ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/opt/local/bin/\(name)",
                       "/usr/bin/\(name)", NSHomeDirectory() + "/bin/\(name)",
                       NSHomeDirectory() + "/ffmpeg-bin/\(name)", NSHomeDirectory() + "/.local/bin/\(name)"]
        if let hit = candidates.first(where: isExec) { return URL(fileURLWithPath: hit) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", "command -v \(name)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").last.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (!path.isEmpty && isExec(path)) ? URL(fileURLWithPath: path) : nil
    }
}

extension Tools {
    /// The edge264-mvc command-line decoder (needed for Blu-ray 3D / MVC sources).
    static func findDecoder() -> URL? {
        if let saved = UserDefaults.standard.string(forKey: decoderKey),
           FileManager.default.isExecutableFile(atPath: saved) {
            return URL(fileURLWithPath: saved)
        }
        return find("edge264mvc_test") ?? find("edge264_test")
    }
}

enum ConverterError: LocalizedError {
    case ffmpeg(String)
    case probe(String)
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let s): return s
        case .ffmpeg(let s): return "ffmpeg failed:\n" + s
        case .probe(let s): return s
        }
    }
}

// MARK: - Probing

struct VideoStreamInfo {
    var index: Int
    var codec: String
    var width: Int
    var height: Int
    var isAttachedPic: Bool
    var frameRate: String = "24000/1001"
    var isUndecodable: Bool { codec == "unknown" || codec == "none" || codec == "mvc" || width == 0 || height == 0 }
}

struct MediaInfo {
    var videos: [VideoStreamInfo]
    var audioCodecs: [String]     // in audio-stream order
    var duration: Double
    var mvc: MVCTracks? = nil     // set when the MKV carries Blu-ray 3D (MVC)
}

enum StereoLayout {
    case framePacked(streamIndex: Int, width: Int, eyeHeight: Int, gap: Int)
    case dualStream(left: Int, right: Int, width: Int, height: Int)
    case overUnderHalf(streamIndex: Int, width: Int, height: Int)   // user-assumed half-height top/bottom
    case mvc                                                          // MVC we can't read (e.g. a 3D disc folder)
    case mvcMKV(baseTrack: Int, dependentTrack: Int?, width: Int, height: Int, fps: String)
    case alreadySBS
    case unsupported(String)

    var isConvertible: Bool {
        switch self {
        case .framePacked, .dualStream, .overUnderHalf, .mvcMKV: return true
        default: return false
        }
    }

    var allowsTopBottomOverride: Bool {
        switch self {
        case .unsupported, .overUnderHalf: return true
        default: return false
        }
    }

    var summary: String {
        switch self {
        case .framePacked(_, let w, let h, let gap):
            return "Frame-packed 3D (top/bottom), \(w)×\(h) per eye" + (gap > 0 ? ", \(gap)px gap" : "")
        case .dualStream(_, _, let w, let h): return "Two separate video streams, \(w)×\(h) each"
        case .overUnderHalf(_, let w, let h): return "Half top-and-bottom 3D (assumed), \(w)×\(h)"
        case .mvc: return "Blu-ray 3D (MVC base + dependent view)"
        case .mvcMKV(_, let dep, let w, let h, _):
            return "Blu-ray 3D MVC, \(w)×\(h) per eye, " + (dep == nil ? "views interleaved in one track" : "views in separate tracks") + " · software MVC decode"
        case .alreadySBS: return "Already side-by-side"
        case .unsupported: return "Layout not recognised"
        }
    }

    var explanation: String {
        switch self {
        case .mvc:
            return "This is a Blu-ray 3D disc folder/ISO. The app can convert 3D MVC from MKV files: open the disc in MakeMKV, tick the “MPEG4 MVC” video track along with the main AVC track, rip to MKV, then add that MKV here."
        case .alreadySBS: return "This video already looks like full side-by-side 3D."
        case .unsupported(let s): return s
        default: return ""
        }
    }
}

enum Probe {
    private static func rate(_ s: [String: Any]) -> String {
        for k in ["avg_frame_rate", "r_frame_rate"] {
            if let v = s[k] as? String, v.contains("/"), v != "0/0" { return v }
        }
        return "24000/1001"
    }

    static func run(inputArgs: [String], ffprobe: URL) async throws -> MediaInfo {
        let data: Data = try await Task.detached {
            let p = Process()
            p.executableURL = ffprobe
            p.arguments = ["-v", "error", "-show_streams", "-show_format", "-of", "json"] + inputArgs
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            try p.run()
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return d
        }.value

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConverterError.probe("ffprobe returned no data.")
        }
        let streams = root["streams"] as? [[String: Any]] ?? []
        var videos: [VideoStreamInfo] = []
        var audio: [String] = []
        for s in streams {
            switch s["codec_type"] as? String {
            case "video":
                let disp = s["disposition"] as? [String: Any]
                videos.append(VideoStreamInfo(
                    index: s["index"] as? Int ?? 0,
                    codec: s["codec_name"] as? String ?? "unknown",
                    width: s["width"] as? Int ?? 0,
                    height: s["height"] as? Int ?? 0,
                    isAttachedPic: (disp?["attached_pic"] as? Int ?? 0) == 1,
                    frameRate: rate(s)))
            case "audio":
                audio.append(s["codec_name"] as? String ?? "unknown")
            default: break
            }
        }
        let format = root["format"] as? [String: Any]
        let duration = Double(format?["duration"] as? String ?? "") ?? 0
        return MediaInfo(videos: videos, audioCodecs: audio, duration: duration)
    }

    static func classify(_ info: MediaInfo, assumeTopBottom: Bool = false) -> StereoLayout {
        let real = info.videos.filter { !$0.isAttachedPic }
        let good = real.filter { !$0.isUndecodable }
        let bad = real.filter { $0.isUndecodable }

        if let m = info.mvc, let v = good.first {
            return .mvcMKV(baseTrack: m.base, dependentTrack: m.dependent,
                           width: v.width, height: v.height, fps: v.frameRate)
        }
        if !bad.isEmpty { return .mvc }
        if good.isEmpty { return .unsupported("No decodable video stream found.") }

        if good.count >= 2, good[0].width == good[1].width, good[0].height == good[1].height {
            return .dualStream(left: good[0].index, right: good[1].index,
                               width: good[0].width, height: good[0].height)
        }

        let v = good[0]
        if assumeTopBottom && v.height <= v.width {
            return .overUnderHalf(streamIndex: v.index, width: v.width, height: v.height)
        }
        if v.height > v.width {
            let gap: Int
            if v.width == 1920 && v.height == 2205 { gap = 45 }
            else if v.width == 1280 && v.height == 1470 { gap = 30 }
            else { gap = 0 }
            return .framePacked(streamIndex: v.index, width: v.width, eyeHeight: (v.height - gap) / 2, gap: gap)
        }
        if Double(v.width) / Double(max(v.height, 1)) >= 3.0 { return .alreadySBS }
        return .unsupported("Single \(v.width)×\(v.height) video with no 3D layout detected. If it's half top-and-bottom 3D, tick the box below.")
    }
}

// MARK: - Settings & command

enum SBSMode: String, CaseIterable, Identifiable {
    case full = "Full SBS (double width)"
    case half = "Half SBS (squeezed)"
    var id: String { rawValue }
}

enum VideoEncoder: String, CaseIterable, Identifiable {
    case hevcVT = "HEVC – VideoToolbox (fast)"
    case h264VT = "H.264 – VideoToolbox (fast)"
    case x264 = "H.264 – x264 (best quality, slow)"
    var id: String { rawValue }
    var usesBitrate: Bool { self != .x264 }
}

struct Settings {
    var mode: SBSMode = .half
    var encoder: VideoEncoder = .hevcVT
    var bitrateMbps: Int = 30
    var crf: Int = 18
    var swapEyes = false
    var keepSubtitles = false
}

enum FFmpegCommand {
    private static func eyeFilter(w: Int, h: Int, s: Settings) -> String {
        let first = s.swapEyes ? "R" : "L"
        let second = s.swapEyes ? "L" : "R"
        if s.mode == .half {
            return "[\(first)]scale=\(w / 2):\(h)[A];[\(second)]scale=\(w / 2):\(h)[B];[A][B]hstack=inputs=2,setsar=1[v]"
        }
        return "[\(first)][\(second)]hstack=inputs=2,setsar=1[v]"
    }

    /// Mapping, encoder, audio/subtitle handling and output. `m` is the input index holding audio/subs/chapters.
    private static func common(filter f: String, mediaInput m: Int, audioCodecs: [String],
                               output: URL, s: Settings) -> [String] {
        var a = ["-filter_complex", f, "-map", "[v]", "-map", "\(m):a?"]
        if s.keepSubtitles { a += ["-map", "\(m):s?"] }
        a += ["-map_chapters", "\(m)"]

        switch s.encoder {
        case .hevcVT: a += ["-c:v", "hevc_videotoolbox", "-b:v", "\(s.bitrateMbps)M", "-tag:v", "hvc1"]
        case .h264VT: a += ["-c:v", "h264_videotoolbox", "-b:v", "\(s.bitrateMbps)M"]
        case .x264:   a += ["-c:v", "libx264", "-preset", "slow", "-crf", "\(s.crf)", "-pix_fmt", "yuv420p"]
        }
        a += ["-c:a", "copy"]
        // Blu-ray LPCM can't be stored in MKV as-is; losslessly re-encode it to FLAC.
        for (i, c) in audioCodecs.enumerated() where c == "pcm_bluray" || c == "pcm_dvd" {
            a += ["-c:a:\(i)", "flac"]
        }
        if s.keepSubtitles { a += ["-c:s", "copy"] }
        a += ["-metadata:s:v:0", "stereo_mode=" + (s.swapEyes ? "right_left" : "left_right"), output.path]
        return a
    }

    static func arguments(inputArgs: [String], output: URL, layout: StereoLayout,
                          audioCodecs: [String], settings s: Settings) -> [String] {
        var f = ""
        let w: Int, h: Int
        switch layout {
        case .framePacked(let idx, let width, let eye, let gap):
            w = width; h = eye
            f += "[0:\(idx)]split=2[s0][s1];"
            f += "[s0]crop=\(w):\(h):0:0[L];"
            f += "[s1]crop=\(w):\(h):0:\(eye + gap)[R];"
        case .dualStream(let l, let r, let width, let height):
            w = width; h = height
            f += "[0:\(l)]null[L];[0:\(r)]null[R];"
        case .overUnderHalf(let idx, let width, let height):
            w = width; h = height
            f += "[0:\(idx)]split=2[s0][s1];"
            f += "[s0]crop=\(w):\(h / 2):0:0,scale=\(w):\(h)[L];"
            f += "[s1]crop=\(w):\(h / 2):0:\(h / 2),scale=\(w):\(h)[R];"
        default:
            return []
        }
        f += eyeFilter(w: w, h: h, s: s)
        let head = ["-nostdin", "-y", "-progress", "pipe:1", "-nostats"] + inputArgs
        return head + common(filter: f, mediaInput: 0, audioCodecs: audioCodecs, output: output, s: s)
    }

    /// MVC pipeline: input 0 = side-by-side Y4M from the decoder on stdin, input 1 = the original MKV
    /// (audio, subtitles, chapters).
    static func mvcArguments(source: URL, output: URL, width w: Int, height h: Int, fps: String,
                             audioCodecs: [String], settings s: Settings) -> [String] {
        var f = "[0:v]split=2[s0][s1];"
        f += "[s0]crop=\(w):\(h):0:0[L];"          // base view = left eye
        f += "[s1]crop=\(w):\(h):\(w):0[R];"      // dependent view = right eye
        f += eyeFilter(w: w, h: h, s: s)
        let head = ["-y", "-progress", "pipe:1", "-nostats",
                    "-f", "yuv4mpegpipe", "-r", fps, "-i", "pipe:0",
                    "-i", source.path]
        return head + common(filter: f, mediaInput: 1, audioCodecs: audioCodecs, output: output, s: s)
    }
}

// MARK: - Process runner

final class Runner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var errTail = ""

    func cancel() {
        lock.lock(); cancelled = true; process?.terminate(); lock.unlock()
    }

    func run(exe: URL, args: [String], duration: Double,
             onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err

            var partial = ""
            out.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil; return }
                partial += String(decoding: d, as: UTF8.self)
                while let r = partial.range(of: "\n") {
                    let line = String(partial[..<r.lowerBound])
                    partial.removeSubrange(..<r.upperBound)
                    if line.hasPrefix("out_time_us="), let v = Double(line.dropFirst(12)), duration > 0 {
                        onProgress(min(max(v / 1_000_000 / duration, 0), 1))
                    }
                }
            }
            err.fileHandleForReading.readabilityHandler = { [weak self] h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil; return }
                guard let self else { return }
                self.lock.lock()
                self.errTail += String(decoding: d, as: UTF8.self)
                if self.errTail.count > 4000 { self.errTail = String(self.errTail.suffix(4000)) }
                self.lock.unlock()
            }
            p.terminationHandler = { [weak self] proc in
                guard let self else { return }
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                self.lock.lock()
                let wasCancelled = self.cancelled
                let tail = self.errTail
                self.lock.unlock()
                if wasCancelled { cont.resume(throwing: CancellationError()) }
                else if proc.terminationStatus == 0 { cont.resume() }
                else { cont.resume(throwing: ConverterError.ffmpeg(tail)) }
            }
            lock.lock(); process = p; lock.unlock()
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
