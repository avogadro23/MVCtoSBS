import SwiftUI
import UniformTypeIdentifiers

@main
struct MVCtoSBSApp: App {
    @StateObject private var converter = Converter()

    init() {
        // Writing to a pipe whose reader has exited must return an error, not kill the app.
        signal(SIGPIPE, SIG_IGN)
    }
    var body: some Scene {
        WindowGroup("MVCtoSBS") {
            ContentView()
                .environmentObject(converter)
                .frame(minWidth: 720, minHeight: 600)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var c: Converter
    @State private var importing = false
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 14) {
            if c.toolsMissing {
                VStack(alignment: .leading, spacing: 8) {
                    Label("ffmpeg and/or ffprobe not found.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Install with “brew install ffmpeg” in Terminal, or click Locate ffmpeg… and pick your copy once. Searched: \(Tools.searchSummary).")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Locate ffmpeg…") { c.locateTools() }
                        Button("Re-check") { c.refreshTools() }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            if c.needsDecoder && c.decoder == nil || !c.decoderStatus.isEmpty { decoderBanner }

            dropZone
            settingsBox
            controls
        }
        .padding(18)
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.folder, .data],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { c.add(urls) }
        }
    }

    // MARK: Pieces

    private var decoderBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            if c.decoder == nil {
                Label("3D MVC decoder not installed", systemImage: "cube.transparent")
                    .foregroundStyle(.orange)
                Text("Blu-ray 3D (MVC) files need the open-source edge264-mvc decoder. The app can download and build it for you (needs git and the Xcode command line tools), or you can point it at an existing build.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if c.decoder == nil {
                    Button("Build decoder") { c.buildDecoder() }.disabled(c.isBuildingDecoder)
                    Button("Locate…") { c.locateDecoder() }
                    Button("Re-check") { c.refreshTools() }
                }
                if c.isBuildingDecoder { ProgressView().controlSize(.small) }
            }
            if !c.decoderStatus.isEmpty {
                Text(c.decoderStatus).font(.caption).textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(targeted ? Color.accentColor : .secondary.opacity(0.4),
                              style: StrokeStyle(lineWidth: 2, dash: [6]))
                .background(targeted ? Color.accentColor.opacity(0.08) : .clear)

            if c.jobs.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 34))
                    Text("Drop 3D MKVs (including MVC), Blu-ray folders or ISOs here").font(.headline)
                    Text("Unencrypted discs: a folder containing BDMV, a .iso, or a .m2ts file").foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
            } else {
                List(c.jobs) { JobRow(job: $0) }
                    .listStyle(.inset)
                    .padding(4)
            }
        }
        .frame(minHeight: 220)
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            for p in providers {
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) {
                        Task { @MainActor in c.add([u]) }
                    }
                }
            }
            return true
        }
    }

    private var settingsBox: some View {
        GroupBox("Output") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Format")
                    Picker("", selection: $c.settings.mode) {
                        ForEach(SBSMode.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().pickerStyle(.segmented)
                }
                GridRow {
                    Text("Encoder")
                    Picker("", selection: $c.settings.encoder) {
                        ForEach(VideoEncoder.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden()
                }
                GridRow {
                    Text(c.settings.encoder.usesBitrate ? "Bitrate" : "Quality (CRF)")
                    if c.settings.encoder.usesBitrate {
                        HStack {
                            Slider(value: Binding(get: { Double(c.settings.bitrateMbps) },
                                                  set: { c.settings.bitrateMbps = Int($0) }),
                                   in: 8...80, step: 1)
                            Text("\(c.settings.bitrateMbps) Mbps").monospacedDigit().frame(width: 80, alignment: .trailing)
                        }
                    } else {
                        HStack {
                            Slider(value: Binding(get: { Double(c.settings.crf) },
                                                  set: { c.settings.crf = Int($0) }),
                                   in: 14...26, step: 1)
                            Text("CRF \(c.settings.crf)").monospacedDigit().frame(width: 80, alignment: .trailing)
                        }
                    }
                }
                GridRow {
                    Text("Options")
                    HStack(spacing: 18) {
                        Toggle("Swap eyes (cross-eyed)", isOn: $c.settings.swapEyes)
                        Toggle("Keep subtitles", isOn: $c.settings.keepSubtitles)
                            .help("Image subtitles (PGS) will only appear on the left half of the SBS frame.")
                    }
                }
                GridRow {
                    Text("Save to")
                    HStack {
                        Text(c.outputFolder?.path ?? "Same folder as source")
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…") { chooseFolder() }
                        if c.outputFolder != nil { Button("Reset") { c.outputFolder = nil } }
                    }
                }
            }
            .padding(6)
        }
    }

    private var controls: some View {
        HStack {
            Button("Add Files / Disc…") { importing = true }
            Button("Clear Finished") { c.clearFinished() }.disabled(c.isRunning)
            Spacer()
            if c.isRunning {
                Button("Cancel", role: .cancel) { c.cancel() }
            } else {
                Button("Convert") { c.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!c.hasReadyJobs || c.toolsMissing)
            }
        }
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        if p.runModal() == .OK { c.outputFolder = p.url }
    }
}

struct JobRow: View {
    @EnvironmentObject var c: Converter
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: job.disc != nil ? "opticaldisc" : "film")
                Text(job.url.lastPathComponent).font(.body.weight(.medium)).lineLimit(1)
                Spacer()
                statusView
            }
            if let disc = job.disc, disc.playlists.count > 1 {
                Picker("Playlist", selection: Binding(
                    get: { job.playlistID ?? "" },
                    set: { c.selectPlaylist(job.id, $0) })) {
                    ForEach(disc.playlists) { Text($0.label).tag($0.id) }
                }
                .disabled(job.status == .running)
            } else if let pl = job.playlist {
                Text(pl.label).font(.caption).foregroundStyle(.secondary)
            }
            if let l = job.layout {
                Text(l.summary).font(.caption).foregroundStyle(.secondary)
                if l.allowsTopBottomOverride {
                    Toggle("Source is half top-and-bottom 3D", isOn: Binding(
                        get: { job.assumeTopBottom },
                        set: { c.setTopBottom(job.id, $0) }))
                        .font(.caption)
                        .disabled(job.status == .running)
                }
            }
            if job.status == .running {
                ProgressView(value: job.progress)
            }
            switch job.status {
            case .blocked(let m), .failed(let m):
                Text(m).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            default: EmptyView()
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var statusView: some View {
        switch job.status {
        case .probing: ProgressView().controlSize(.small)
        case .ready: Text("Ready").foregroundStyle(.secondary)
        case .running: Text("\(Int(job.progress * 100))%").monospacedDigit()
        case .done:
            HStack {
                Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                if let o = job.output {
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([o]) }
                        .buttonStyle(.link)
                }
            }
        case .blocked: Label("Can't convert", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        case .failed: Label("Failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .cancelled: Text("Cancelled").foregroundStyle(.secondary)
        }
    }
}
