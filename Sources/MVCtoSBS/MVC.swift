import Foundation

// MARK: - Types

struct MVCTracks {
    var base: Int            // Matroska track number of the base (left-eye) view
    var dependent: Int?      // separate dependent-view track, or nil if both views share one track
}

struct MKVTrack {
    var number = 0
    var type = 0             // 1 = video, 2 = audio, 17 = subtitles
    var codecID = ""
    var codecPrivate: [UInt8] = []
    var lengthSize = 4
    var paramSets: [[UInt8]] = []
    var isVideo: Bool { type == 1 }
}

// MARK: - EBML helpers (in-memory)

enum EBML {
    static func vint(_ d: [UInt8], _ p: inout Int, keepMarker: Bool) -> (value: UInt64, unknown: Bool)? {
        guard p < d.count else { return nil }
        let b = d[p]
        let len = b.leadingZeroBitCount + 1
        guard len <= 8, p + len <= d.count else { return nil }
        var v = keepMarker ? UInt64(b) : UInt64(b) & (UInt64(0xFF) >> UInt64(len))
        if len > 1 { for i in 1..<len { v = v << 8 | UInt64(d[p + i]) } }
        p += len
        return (v, !keepMarker && v == (UInt64(1) << UInt64(7 * len)) - 1)
    }
}

enum MKVParse {
    static func uint(_ b: ArraySlice<UInt8>) -> Int { b.reduce(0) { $0 << 8 | Int($1) } }

    static func tracks(_ d: [UInt8]) -> [MKVTrack] {
        var p = 0
        var out: [MKVTrack] = []
        while p < d.count {
            guard let id = EBML.vint(d, &p, keepMarker: true),
                  let sz = EBML.vint(d, &p, keepMarker: false) else { break }
            let e = min(d.count, p + Int(min(sz.value, UInt64(d.count))))
            if id.value == 0xAE { out.append(entry(Array(d[p..<e]))) }
            p = e
        }
        return out
    }

    private static func entry(_ d: [UInt8]) -> MKVTrack {
        var t = MKVTrack()
        var p = 0
        while p < d.count {
            guard let id = EBML.vint(d, &p, keepMarker: true),
                  let sz = EBML.vint(d, &p, keepMarker: false) else { break }
            let e = min(d.count, p + Int(min(sz.value, UInt64(d.count))))
            switch id.value {
            case 0xD7: t.number = uint(d[p..<e])
            case 0x83: t.type = uint(d[p..<e])
            case 0x86: t.codecID = String(decoding: d[p..<e], as: UTF8.self)
            case 0x63A2: t.codecPrivate = Array(d[p..<e])
            default: break
            }
            p = e
        }
        if t.type == 1, let rec = avcc(t.codecPrivate) {
            t.lengthSize = rec.lengthSize
            t.paramSets = rec.nals
        }
        return t
    }

    /// Parses an avcC-style record (also the layout of the MVC configuration record):
    /// returns the NAL length-field size and the parameter-set NAL units (SPS / PPS / subset SPS).
    static func avcc(_ d: [UInt8]) -> (lengthSize: Int, nals: [[UInt8]])? {
        guard d.count >= 7, d[0] == 1 else { return nil }
        let ls = Int(d[4] & 3) + 1
        var p = 5
        var nals: [[UInt8]] = []
        for round in 0..<2 {                              // first the SPS list, then the PPS list
            guard p < d.count else { break }
            let count = round == 0 ? Int(d[p] & 0x1F) : Int(d[p])
            p += 1
            for _ in 0..<count {
                guard p + 2 <= d.count else { return (ls, nals) }
                let l = Int(d[p]) << 8 | Int(d[p + 1])
                p += 2
                guard p + l <= d.count else { return (ls, nals) }
                nals.append(Array(d[p..<(p + l)]))
                p += l
            }
        }
        return (ls, nals)
    }
}

// MARK: - File reader

final class ByteReader {
    private let fh: FileHandle
    private var buf: [UInt8] = []
    private var bufStart: UInt64 = 0
    private var idx = 0
    private let chunk = 4 << 20

    init(url: URL) throws { fh = try FileHandle(forReadingFrom: url) }
    deinit { try? fh.close() }

    var position: UInt64 { bufStart + UInt64(idx) }

    private func refill() -> Bool {
        bufStart += UInt64(buf.count)
        idx = 0
        guard let d = try? fh.read(upToCount: chunk), !d.isEmpty else { buf = []; return false }
        buf = [UInt8](d)
        return true
    }

    func seek(to target: UInt64) {
        if target >= bufStart && target <= bufStart + UInt64(buf.count) {
            idx = Int(target - bufStart)
            return
        }
        try? fh.seek(toOffset: target)
        bufStart = target
        buf = []
        idx = 0
    }

    func skip(_ n: UInt64) { seek(to: position + n) }

    func byte() -> UInt8? {
        if idx >= buf.count { if !refill() { return nil } }
        let b = buf[idx]
        idx += 1
        return b
    }

    func read(_ n: Int) -> [UInt8]? {
        var out = [UInt8]()
        out.reserveCapacity(n)
        while out.count < n {
            if idx >= buf.count { if !refill() { return nil } }
            let take = min(n - out.count, buf.count - idx)
            out.append(contentsOf: buf[idx..<(idx + take)])
            idx += take
        }
        return out
    }

    func vint(keepMarker: Bool) -> (UInt64, Bool)? {
        guard let b = byte() else { return nil }
        let len = b.leadingZeroBitCount + 1
        guard len <= 8 else { return nil }
        var v = keepMarker ? UInt64(b) : UInt64(b) & (UInt64(0xFF) >> UInt64(len))
        if len > 1 {
            for _ in 1..<len {
                guard let n = byte() else { return nil }
                v = v << 8 | UInt64(n)
            }
        }
        return (v, !keepMarker && v == (UInt64(1) << UInt64(7 * len)) - 1)
    }

    func header() -> (id: UInt32, size: UInt64, unknown: Bool)? {
        guard let (id, _) = vint(keepMarker: true), id <= 0xFFFF_FFFF,
              let (size, unk) = vint(keepMarker: false) else { return nil }
        return (UInt32(id), size, unk)
    }
}

// MARK: - Matroska demuxer (streams the file; never loads it whole)

final class MKVDemuxer {
    private let r: ByteReader
    init(url: URL) throws { r = try ByteReader(url: url) }

    private static let topLevel: Set<UInt32> = [
        0x1F43B675, 0x1C53BB6B, 0x1254C367, 0x114D9B74, 0x1549A966, 0x1654AE6B, 0x1043A770, 0x1941A469
    ]

    /// Walks the file. `onTracks` is called once; `onBlock(trackNumber, payload)` for every un-laced block.
    /// Return false from either callback to stop early.
    func run(onTracks: ([MKVTrack]) -> Bool,
             onBlock: (Int, [UInt8]) throws -> Bool) throws {
        while let h = r.header() {
            switch h.id {
            case 0x18538067:                      // Segment: descend (children follow directly)
                continue
            case 0x1654AE6B:                      // Tracks
                guard h.size < 1 << 26, let d = r.read(Int(h.size)) else { return }
                if !onTracks(MKVParse.tracks(d)) { return }
            case 0x1F43B675:                      // Cluster
                let keepGoing = try cluster(h.size, h.unknown, onBlock)
                if !keepGoing { return }
            default:
                if h.unknown { return }
                r.skip(h.size)
            }
        }
    }

    private func cluster(_ size: UInt64, _ unknown: Bool,
                         _ onBlock: (Int, [UInt8]) throws -> Bool) throws -> Bool {
        let end = unknown ? UInt64.max : r.position + size
        while r.position < end {
            let start = r.position
            guard let h = r.header() else { return false }
            if unknown && Self.topLevel.contains(h.id) { r.seek(to: start); return true }
            switch h.id {
            case 0xA3:                            // SimpleBlock
                guard h.size < 1 << 28, let d = r.read(Int(h.size)) else { return false }
                let ok = try block(d, onBlock)
                if !ok { return false }
            case 0xA0:                            // BlockGroup
                guard h.size < 1 << 28, let d = r.read(Int(h.size)) else { return false }
                var p = 0
                while p < d.count {
                    guard let id = EBML.vint(d, &p, keepMarker: true),
                          let sz = EBML.vint(d, &p, keepMarker: false) else { break }
                    let e = min(d.count, p + Int(min(sz.value, UInt64(d.count))))
                    if id.value == 0xA1 {
                        let ok = try block(Array(d[p..<e]), onBlock)
                        if !ok { return false }
                    }
                    p = e
                }
            default:
                if h.unknown { return false }
                r.skip(h.size)
            }
        }
        return true
    }

    private func block(_ d: [UInt8], _ onBlock: (Int, [UInt8]) throws -> Bool) throws -> Bool {
        var p = 0
        guard let t = EBML.vint(d, &p, keepMarker: false), p + 3 <= d.count else { return true }
        let flags = d[p + 2]
        p += 3
        if (flags >> 1) & 3 != 0 { return true }  // laced blocks aren't used for video
        return try onBlock(Int(t.value), Array(d[p...]))
    }
}

// MARK: - MVC detection

enum MKVScan {
    /// Looks at the track list and the first few blocks to decide whether this MKV carries Blu-ray 3D (MVC).
    static func detectMVC(_ url: URL) -> MVCTracks? {
        guard let dm = try? MKVDemuxer(url: url) else { return nil }
        var videos: [MKVTrack] = []
        var seen: [Int: Int] = [:]
        var hasMVC = Set<Int>()
        var total = 0

        _ = try? dm.run(onTracks: { tracks in
            videos = tracks.filter { $0.isVideo }
            for t in videos where t.codecID.uppercased().contains("MVC") { hasMVC.insert(t.number) }
            return !videos.isEmpty
        }, onBlock: { tn, payload in
            guard let t = videos.first(where: { $0.number == tn }) else { return true }
            total += 1
            seen[tn, default: 0] += 1
            if containsMVCNAL(payload, lengthSize: t.lengthSize) { hasMVC.insert(tn) }
            let enough = videos.allSatisfy { (seen[$0.number] ?? 0) >= 40 }
            return !enough && total < 800
        })

        guard let first = videos.first else { return nil }
        if let dep = videos.dropFirst().first(where: { hasMVC.contains($0.number) }) {
            let base = videos.first { $0.number != dep.number } ?? first
            return MVCTracks(base: base.number, dependent: dep.number)
        }
        if hasMVC.contains(first.number) { return MVCTracks(base: first.number, dependent: nil) }
        return nil
    }

    /// NAL unit type 20 = coded slice extension, i.e. a dependent-view slice.
    private static func containsMVCNAL(_ payload: [UInt8], lengthSize: Int) -> Bool {
        var p = 0
        while p + lengthSize < payload.count {
            var len = 0
            for i in 0..<lengthSize { len = len << 8 | Int(payload[p + i]) }
            p += lengthSize
            guard len > 0, p + len <= payload.count else { return false }
            if payload[p] & 0x1F == 20 { return true }
            p += len
        }
        return false
    }
}

// MARK: - MKV -> Annex B elementary stream (both views, in access-unit order)

enum MVCDemux {
    private static func appendAnnexB(_ payload: [UInt8], lengthSize: Int, into out: inout [UInt8]) {
        var p = 0
        while p + lengthSize < payload.count {
            var len = 0
            for i in 0..<lengthSize { len = len << 8 | Int(payload[p + i]) }
            p += lengthSize
            guard len > 0, p + len <= payload.count else { break }
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(contentsOf: payload[p..<(p + len)])
            p += len
        }
    }

    static func pump(source: URL, base: Int, dependent: Int?,
                     isCancelled: () -> Bool,
                     write: (Data) throws -> Void) throws {
        let dm = try MKVDemuxer(url: source)
        var out = [UInt8]()
        out.reserveCapacity(2 << 20)
        var lengthSizes: [Int: Int] = [:]
        var baseQ: [[UInt8]] = []
        var depQ: [[UInt8]] = []

        func flush(force: Bool) throws {
            if !out.isEmpty && (force || out.count >= 1 << 20) {
                try write(Data(out))
                out.removeAll(keepingCapacity: true)
            }
        }

        try dm.run(onTracks: { tracks in
            for tn in [base] + (dependent.map { [$0] } ?? []) {
                guard let t = tracks.first(where: { $0.number == tn }) else { continue }
                lengthSizes[tn] = t.lengthSize
                for ps in t.paramSets {                  // SPS / PPS / subset SPS from CodecPrivate
                    out.append(contentsOf: [0, 0, 0, 1])
                    out.append(contentsOf: ps)
                }
            }
            return true
        }, onBlock: { tn, payload in
            if isCancelled() { return false }
            guard let ls = lengthSizes[tn] else { return true }
            var au = [UInt8]()
            au.reserveCapacity(payload.count + 64)
            appendAnnexB(payload, lengthSize: ls, into: &au)

            if dependent == nil {
                out.append(contentsOf: au)                // both views already interleaved in this track
            } else {
                if tn == base { baseQ.append(au) } else { depQ.append(au) }
                while !baseQ.isEmpty && !depQ.isEmpty {   // base AU, then its dependent AU
                    out.append(contentsOf: baseQ.removeFirst())
                    out.append(contentsOf: depQ.removeFirst())
                }
                if baseQ.count > 48 { out.append(contentsOf: baseQ.removeFirst()) }
                if depQ.count > 48 { depQ.removeFirst() }
            }
            try flush(force: false)
            return true
        })

        for au in baseQ { out.append(contentsOf: au) }
        try flush(force: true)
    }
}

// MARK: - Pipeline: demuxer -> edge264mvc_test -> ffmpeg

final class MVCPipeline: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var procs: [Process] = []
    private var ffTail = ""
    private var decTail = ""
    private var demuxError: String?

    func cancel() {
        lock.lock()
        cancelled = true
        let ps = procs
        lock.unlock()
        for p in ps where p.isRunning { p.terminate() }
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    private func appendTail(_ keyPath: ReferenceWritableKeyPath<MVCPipeline, String>, _ s: String) {
        lock.lock()
        self[keyPath: keyPath] += s
        if self[keyPath: keyPath].count > 4000 { self[keyPath: keyPath] = String(self[keyPath: keyPath].suffix(4000)) }
        lock.unlock()
    }

    func run(decoder: URL, ffmpeg: URL, source: URL, base: Int, dependent: Int?,
             ffmpegArgs: [String], duration: Double,
             onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let toDecoder = Pipe(), between = Pipe(), ffOut = Pipe(), ffErr = Pipe(), decErr = Pipe()

            let dec = Process()
            dec.executableURL = decoder
            dec.arguments = ["-", "-O", "-k"]          // stdin Annex B in, side-by-side Y4M out
            dec.standardInput = toDecoder
            dec.standardOutput = between
            dec.standardError = decErr

            let ff = Process()
            ff.executableURL = ffmpeg
            ff.arguments = ffmpegArgs
            ff.standardInput = between
            ff.standardOutput = ffOut
            ff.standardError = ffErr

            var partial = ""
            ffOut.fileHandleForReading.readabilityHandler = { h in
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
            ffErr.fileHandleForReading.readabilityHandler = { [weak self] h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil; return }
                self?.appendTail(\.ffTail, String(decoding: d, as: UTF8.self))
            }
            decErr.fileHandleForReading.readabilityHandler = { [weak self] h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil; return }
                self?.appendTail(\.decTail, String(decoding: d, as: UTF8.self))
            }

            ff.terminationHandler = { [weak self] proc in
                guard let self else { return }
                ffOut.fileHandleForReading.readabilityHandler = nil
                ffErr.fileHandleForReading.readabilityHandler = nil
                if dec.isRunning { dec.terminate() }
                self.lock.lock()
                let wasCancelled = self.cancelled
                let ft = self.ffTail, dt = self.decTail, de = self.demuxError
                self.lock.unlock()
                if wasCancelled {
                    cont.resume(throwing: CancellationError())
                } else if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    var msg = ft
                    if !dt.isEmpty { msg += "\n--- MVC decoder ---\n" + dt }
                    if let de { msg += "\n--- MKV reader ---\n" + de }
                    cont.resume(throwing: ConverterError.ffmpeg(msg))
                }
            }

            lock.lock(); procs = [dec, ff]; lock.unlock()
            do {
                try dec.run()
                try ff.run()
            } catch {
                if dec.isRunning { dec.terminate() }
                cont.resume(throwing: error)
                return
            }
            // Close our copies of the pipe ends so EOF propagates down the chain.
            try? toDecoder.fileHandleForReading.close()
            try? between.fileHandleForWriting.close()
            try? between.fileHandleForReading.close()

            let writer = toDecoder.fileHandleForWriting
            Task.detached { [weak self] in
                do {
                    try MVCDemux.pump(source: source, base: base, dependent: dependent,
                                      isCancelled: { self?.isCancelled ?? true },
                                      write: { try writer.write(contentsOf: $0) })
                } catch {
                    self?.lock.lock()
                    self?.demuxError = error.localizedDescription
                    self?.lock.unlock()
                }
                try? writer.close()
            }
        }
    }
}

// MARK: - Decoder installer (clones and builds edge264-mvc)

enum DecoderInstaller {
    private static let script = """
    set -e
    D="$HOME/Library/Application Support/MVCtoSBS"
    mkdir -p "$D"
    cd "$D"
    rm -rf edge264-mvc-src
    git clone --depth 1 https://github.com/jens-duttke/edge264-mvc.git edge264-mvc-src
    cd edge264-mvc-src
    if ! make STATIC=yes V=no; then
      make clean || true
      if [ "$(uname -m)" = "arm64" ]; then A="-arch arm64"; else A="-march=x86-64-v2"; fi
      make STATIC=yes V=no _BASE_ARCH="$A"
    fi
    cp edge264mvc_test "$D/edge264mvc_test"
    chmod +x "$D/edge264mvc_test"
    cd "$D"
    rm -rf edge264-mvc-src
    echo "Installed $D/edge264mvc_test"
    """

    static func build() -> (ok: Bool, log: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (false, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return (p.terminationStatus == 0, String(text.suffix(1500)))
    }
}
