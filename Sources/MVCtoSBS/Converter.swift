import Foundation
import SwiftUI
import AppKit

struct Job: Identifiable {
    enum Status: Equatable {
        case probing, ready, running, done
        case blocked(String)
        case failed(String)
        case cancelled
    }
    let id = UUID()
    let url: URL                    // file, disc folder, or ISO the user added
    var status: Status = .probing
    var progress: Double = 0
    var info: MediaInfo?
    var layout: StereoLayout?
    var output: URL?
    var disc: DiscInfo?
    var playlistID: String?
    var assumeTopBottom = false

    var playlist: Playlist? { disc?.playlists.first { $0.id == playlistID } }

    var baseName: String {
        let n = url.deletingPathExtension().lastPathComponent
        return n.uppercased() == "BDMV" ? url.deletingLastPathComponent().lastPathComponent : n
    }

    /// Arguments that tell ffmpeg/ffprobe what to read.
    var inputArgs: [String] {
        if let pl = playlist {
            // The concat: protocol joins m2ts clips byte-wise, which is how MPEG-TS clips are normally chained.
            let input = pl.clipPaths.count == 1 ? pl.clipPaths[0] : "concat:" + pl.clipPaths.joined(separator: "|")
            return ["-analyzeduration", "200M", "-probesize", "200M", "-i", input]
        }
        return ["-i", url.path]
    }
}

@MainActor
final class Converter: ObservableObject {
    @Published var jobs: [Job] = []
    @Published var settings = Settings()
    @Published var outputFolder: URL?
    @Published var isRunning = false
    @Published var ffmpeg: URL?
    @Published var ffprobe: URL?
    @Published var decoder: URL?
    @Published var decoderStatus = ""
    @Published var isBuildingDecoder = false

    private var cancelCurrent: (() -> Void)?
    private var runTask: Task<Void, Never>?

    init() {
        refreshTools()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.detachAll() }
        }
    }

    var needsDecoder: Bool {
        jobs.contains { if case .mvcMKV? = $0.layout { return true } else { return false } }
    }
    var toolsMissing: Bool { ffmpeg == nil || ffprobe == nil }
    var hasReadyJobs: Bool { jobs.contains { $0.status == .ready } }

    // MARK: Tools

    func refreshTools() {
        Tools.migrateLegacyPrefs()
        ffmpeg = Tools.find("ffmpeg")
        ffprobe = Tools.find("ffprobe")
        decoder = Tools.findDecoder()
    }

    func locateDecoder() {
        let panel = NSOpenPanel()
        panel.message = "Select the edge264mvc_test executable"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: Tools.decoderKey)
            refreshTools()
        }
    }

    /// Clones and compiles edge264-mvc (needs git + Xcode command line tools).
    func buildDecoder() {
        guard !isBuildingDecoder else { return }
        isBuildingDecoder = true
        decoderStatus = "Downloading and building the MVC decoder… this can take a minute."
        Task {
            let result = await Task.detached { DecoderInstaller.build() }.value
            isBuildingDecoder = false
            refreshTools()
            decoderStatus = result.ok && decoder != nil
                ? "MVC decoder installed."
                : "Build failed. Make sure git and the Xcode command line tools are installed (xcode-select --install).\n" + result.log
        }
    }

    func locateTools() {
        let panel = NSOpenPanel()
        panel.message = "Select the ffmpeg executable (ffprobe must be in the same folder)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: Tools.folderKey)
            refreshTools()
        }
    }

    // MARK: Adding sources

    func add(_ urls: [URL]) {
        for u in urls { addOne(u) }
    }

    private func addOne(_ u: URL) {
        guard ffprobe != nil, !jobs.contains(where: { $0.url == u }) else { return }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
        let ext = u.pathExtension.lowercased()

        if isDir.boolValue || ext == "iso" {
            let job = Job(url: u)
            jobs.append(job)
            Task {
                do {
                    let disc = try await Task.detached { try Disc.open(u) }.value
                    update(job.id) {
                        $0.disc = disc
                        $0.playlistID = disc.defaultPlaylist?.id
                    }
                    await probe(job.id)
                } catch {
                    update(job.id) { $0.status = .failed(error.localizedDescription) }
                }
            }
        } else if ["mkv", "m2ts", "mts", "ts"].contains(ext) {
            let job = Job(url: u)
            jobs.append(job)
            Task { await probe(job.id) }
        }
    }

    private func probe(_ id: UUID) async {
        guard let ffprobe, let job = jobs.first(where: { $0.id == id }) else { return }
        update(id) { $0.status = .probing; $0.layout = nil }
        do {
            var info = try await Probe.run(inputArgs: job.inputArgs, ffprobe: ffprobe)
            if let pl = job.playlist, pl.duration > 0 { info.duration = pl.duration }
            if job.disc == nil, job.url.pathExtension.lowercased() == "mkv" {
                let u = job.url
                info.mvc = await Task.detached { MKVScan.detectMVC(u) }.value
            }
            update(id) { $0.info = info }
            applyLayout(id)
        } catch {
            update(id) { $0.status = .failed("Couldn't read source: \(error.localizedDescription)") }
        }
    }

    private func applyLayout(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), let info = job.info else { return }
        var layout = Probe.classify(info, assumeTopBottom: job.assumeTopBottom)
        if job.playlist?.is3D == true { layout = .mvc }
        update(id) {
            $0.layout = layout
            $0.status = layout.isConvertible ? .ready : .blocked(layout.explanation)
        }
    }

    func selectPlaylist(_ id: UUID, _ playlistID: String) {
        update(id) { $0.playlistID = playlistID }
        Task { await probe(id) }
    }

    func setTopBottom(_ id: UUID, _ on: Bool) {
        update(id) { $0.assumeTopBottom = on }
        applyLayout(id)
    }

    // MARK: Queue management

    func clearFinished() {
        let removed = jobs.filter {
            switch $0.status {
            case .ready, .probing, .running: return false
            default: return true
            }
        }
        jobs.removeAll { j in removed.contains { $0.id == j.id } }
        for j in removed { releaseDisc(j) }
    }

    private func releaseDisc(_ j: Job) {
        guard let mp = j.disc?.mountPoint, !jobs.contains(where: { $0.disc?.mountPoint == mp }) else { return }
        Disc.detach(mp)
    }

    func detachAll() {
        for mp in Set(jobs.compactMap { $0.disc?.mountPoint }) { Disc.detach(mp) }
    }

    // MARK: Conversion

    func start() {
        guard let ffmpeg, !isRunning else { return }
        isRunning = true
        runTask = Task {
            for id in jobs.filter({ $0.status == .ready }).map(\.id) {
                if Task.isCancelled { break }
                await run(id, ffmpeg)
            }
            isRunning = false
        }
    }

    func cancel() {
        runTask?.cancel()
        cancelCurrent?()
    }

    private func outputURL(for job: Job) -> URL {
        let folder = outputFolder ?? job.url.deletingLastPathComponent()
        var base = job.baseName
        if let d = job.disc, d.playlists.count > 1, let pid = job.playlistID { base += " [\(pid)]" }
        let suffix = settings.mode == .full ? " - SBS" : " - HSBS"
        return folder.appendingPathComponent(base + suffix + ".mkv")
    }

    private func run(_ id: UUID, _ ffmpeg: URL) async {
        guard let job = jobs.first(where: { $0.id == id }),
              let info = job.info, let layout = job.layout else { return }
        let out = outputURL(for: job)
        update(id) { $0.status = .running; $0.progress = 0 }

        let report: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor in self?.update(id) { $0.progress = p } }
        }
        do {
            if case .mvcMKV(let base, let dep, let w, let h, let fps) = layout {
                guard let decoder else {
                    throw ConverterError.message("The MVC decoder (edge264mvc_test) isn't installed. Use “Build decoder” or “Locate…” in the banner at the top of the window, then try again.")
                }
                let args = FFmpegCommand.mvcArguments(source: job.url, output: out, width: w, height: h,
                                                      fps: fps, audioCodecs: info.audioCodecs, settings: settings)
                let pipeline = MVCPipeline()
                cancelCurrent = { pipeline.cancel() }
                try await pipeline.run(decoder: decoder, ffmpeg: ffmpeg, source: job.url,
                                       base: base, dependent: dep, ffmpegArgs: args,
                                       duration: info.duration, onProgress: report)
            } else {
                let args = FFmpegCommand.arguments(inputArgs: job.inputArgs, output: out, layout: layout,
                                                   audioCodecs: info.audioCodecs, settings: settings)
                let runner = Runner()
                cancelCurrent = { runner.cancel() }
                try await runner.run(exe: ffmpeg, args: args, duration: info.duration, onProgress: report)
            }
            update(id) { $0.status = .done; $0.progress = 1; $0.output = out }
        } catch is CancellationError {
            update(id) { $0.status = .cancelled }
            try? FileManager.default.removeItem(at: out)
        } catch {
            update(id) { $0.status = .failed(error.localizedDescription) }
            try? FileManager.default.removeItem(at: out)
        }
        cancelCurrent = nil
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { change(&jobs[i]) }
    }
}
