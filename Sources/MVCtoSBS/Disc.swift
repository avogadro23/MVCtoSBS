import Foundation

struct Playlist: Identifiable, Hashable {
    let id: String            // e.g. "00800"
    let duration: Double      // seconds
    let clipPaths: [String]   // absolute paths to .m2ts clips, in play order
    let is3D: Bool            // clip has a matching STREAM/SSIF/xxxxx.ssif (Blu-ray 3D / MVC)

    var label: String {
        let t = Int(duration), h = t / 3600, m = (t % 3600) / 60
        let time = h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m)m"
        return "\(id).mpls · \(time) · \(clipPaths.count) clip\(clipPaths.count == 1 ? "" : "s")" + (is3D ? " · 3D disc" : "")
    }
}

struct DiscInfo {
    let playlists: [Playlist]     // longest first
    let mountPoint: String?       // set when we mounted an ISO
    var defaultPlaylist: Playlist? { playlists.first }
}

enum DiscError: LocalizedError {
    case notBluray, noPlaylists, mountFailed(String)
    var errorDescription: String? {
        switch self {
        case .notBluray:
            return "No Blu-ray structure found. Expected a folder containing BDMV/PLAYLIST and BDMV/STREAM. (Encrypted discs must be decrypted first.)"
        case .noPlaylists: return "No readable playlists (.mpls) found on this disc."
        case .mountFailed(let s): return "Couldn't mount the ISO: \(s)"
        }
    }
}

enum Disc {
    /// Case-insensitive child lookup (discs/ISOs aren't always upper-case).
    static func child(_ dir: URL, _ name: String) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return items.first { $0.caseInsensitiveCompare(name) == .orderedSame }
            .map { dir.appendingPathComponent($0) }
    }

    static func open(_ url: URL) throws -> DiscInfo {
        var root = url
        var mount: String?
        if url.pathExtension.lowercased() == "iso" {
            let mp = try mountISO(url)
            mount = mp
            root = URL(fileURLWithPath: mp)
        }
        do {
            return try scan(root: root, mount: mount)
        } catch {
            if let mount { detach(mount) }
            throw error
        }
    }

    private static func scan(root: URL, mount: String?) throws -> DiscInfo {
        let bdmv = root.lastPathComponent.uppercased() == "BDMV" ? root : (child(root, "BDMV") ?? root)
        guard let plDir = child(bdmv, "PLAYLIST"), let stream = child(bdmv, "STREAM") else {
            throw DiscError.notBluray
        }
        let ssifDir = child(stream, "SSIF")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: plDir.path)) ?? []).sorted()

        var seen = Set<String>()
        var all: [Playlist] = []
        for f in files where f.lowercased().hasSuffix(".mpls") {
            guard let data = try? Data(contentsOf: plDir.appendingPathComponent(f)),
                  let items = parseMPLS(data), !items.isEmpty else { continue }
            var paths: [String] = []
            for it in items {
                guard let u = child(stream, it.clip + ".m2ts") else { paths = []; break }
                paths.append(u.path)
            }
            guard !paths.isEmpty, seen.insert(paths.joined(separator: "|")).inserted else { continue }
            let is3D = ssifDir.flatMap { child($0, items[0].clip + ".ssif") } != nil
            all.append(Playlist(id: String(f.dropLast(5)),
                                duration: items.reduce(0) { $0 + $1.duration },
                                clipPaths: paths, is3D: is3D))
        }
        guard !all.isEmpty else { throw DiscError.noPlaylists }
        var list = all.filter { $0.duration >= 300 }      // ignore menus / trailers / logos
        if list.isEmpty { list = all }
        list.sort { $0.duration > $1.duration }
        return DiscInfo(playlists: Array(list.prefix(12)), mountPoint: mount)
    }

    /// Minimal MPLS parser: returns the clip name + duration of each play item.
    static func parseMPLS(_ data: Data) -> [(clip: String, duration: Double)]? {
        let d = [UInt8](data)
        func u16(_ o: Int) -> Int { o + 2 <= d.count ? Int(d[o]) << 8 | Int(d[o + 1]) : 0 }
        func u32(_ o: Int) -> Int { o + 4 <= d.count ? Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3]) : 0 }
        guard d.count > 30, String(decoding: d[0..<4], as: UTF8.self) == "MPLS" else { return nil }
        let start = u32(8)
        let count = u16(start + 6)
        var pos = start + 10
        var items: [(String, Double)] = []
        for _ in 0..<count {
            guard pos + 22 <= d.count else { break }
            let len = u16(pos)
            let clip = String(decoding: d[(pos + 2)..<(pos + 7)], as: UTF8.self)
            let tin = u32(pos + 14), tout = u32(pos + 18)
            items.append((clip, Double(max(tout - tin, 0)) / 45000.0))
            pos += len + 2
        }
        return items
    }

    // MARK: ISO mounting

    static func mountISO(_ iso: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["attach", "-readonly", "-nobrowse", "-plist", iso.path]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let ents = plist["system-entities"] as? [[String: Any]],
              let mp = ents.compactMap({ $0["mount-point"] as? String }).first else {
            throw DiscError.mountFailed(String(decoding: errData, as: UTF8.self))
        }
        return mp
    }

    static func detach(_ mountPoint: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["detach", "-quiet", mountPoint]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}
