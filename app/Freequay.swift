// Freequay.app: one window that shows the Windows programs of a bottle and starts them with a
// click. An installer or any other .exe dropped on the window or the Dock icon, or opened from
// Finder, starts in the same bottle. The app only calls scripts/freequay, which sits next to it in
// the Freequay folder; scripts/build-app.sh builds it.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct FreequayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Freequay", id: "main") {
            ContentView(model: delegate.model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Freequay") {
                    NSApp.orderFrontStandardAboutPanel(options: [.credits: NSAttributedString(string:
                        "Settings per game come from AppleGamingWiki (CC BY-NC-SA 3.0), umu-protonfixes, Proton, ProtonDB and DXVK. "
                        + "Freequay is not affiliated with CodeWeavers or Apple.",
                        attributes: [.font: NSFont.systemFont(ofSize: 11)])])
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Program…") { delegate.model.choose() }.keyboardShortcut("o")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)  // light, also when the Mac is in dark mode
    }

    // an .exe dropped on the Dock icon or opened from Finder
    func application(_ application: NSApplication, open urls: [URL]) {
        model.start(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// a line of `freequay programs`: a name and what `freequay run` takes for it
struct Program: Identifiable {
    let name: String
    let target: String  // a path, or steam:ID for a Steam game
    var id: String { target }
    var steamGame: Bool { target.hasPrefix("steam:") }
}

@MainActor
final class Model: ObservableObject {
    @Published var bottles: [String] = []
    @Published var bottle = "" {
        didSet {
            UserDefaults.standard.set(bottle, forKey: "bottle")
            loadPrograms()
        }
    }
    @Published var programs: [Program] = []
    @Published var status = ""
    @Published var busy = false    // a bottle or Steam is being set up
    @Published var naming = false  // the sheet for a new bottle is open
    // the note on what Freequay downloads from where; until it was read, the launcher downloads nothing by itself
    @Published var servers = !UserDefaults.standard.bool(forKey: "servers")
    @Published var starting: String?  // the program being started, until a window of it shows
    private var waiting: [URL] = []  // programs dropped before there was a bottle

    // A start waits for a new window of a Wine program, or for a Wine program to come to the front:
    // a program that runs already, like Steam, shows its window again instead of a new one. Owner and
    // size of windows come without the permission for screen recording; only titles would need it.
    private struct Start {
        let target: String
        let name: String
        let known: Set<Int>  // Wine windows on screen before the start
        let processes = Model.wineProcesses()  // and Wine processes
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let began = Date()
        var ended: Date?  // the launched process ended without an error, perhaps after starting another
        var code: Int32 = 0  // and its exit code; start.exe ends with 3 after starting a shortcut's program
    }
    private var pending: Start?
    private var watch: Task<Void, Never>?
    private var opened: [String: Set<pid_t>] = [:]  // program -> processes of the windows it opened

    let root: URL?  // the Freequay folder, inside the app or around it
    let onDiskImage: Bool  // opened right on the read-only disk image
    private let dataDir: URL  // ~/Library/Application Support/freequay, as in scripts/freequay
    private let bottlesDir: URL

    // D3DMetal is Apple's and never part of Freequay: the app leads to Apple's download and installs it
    // from the user's disk image into dataDir/backends (scripts/install-d3dmetal.sh)
    enum D3DMetal: Equatable { case waiting, found(URL), installing, done(String), failed(String) }
    @Published var d3dmetal = D3DMetal.waiting
    @Published var addingD3DMetal = false  // its sheet is open
    private var d3dmetalTask: Task<Void, Never>?
    static let appleDownload = URL(string: "https://developer.apple.com/download/all/?q=Evaluation%20environment%20for%20Windows%20games")!

    private static let steamSetup = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!

    init() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        dataDir = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/freequay")
        bottlesDir = dataDir.appendingPathComponent("Bottles")
        root = Model.folder()
        onDiskImage = root.map { (try? $0.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true } ?? false
        guard root != nil, !onDiskImage else { return }
        liftQuarantine()
        reload()
    }

    func serversRead() {
        UserDefaults.standard.set(true, forKey: "servers")
        servers = false
        reload()  // now the launcher may look up the Steam games in AppleGamingWiki
    }

    // Where scripts/freequay is: inside the app, as released, or in the folder around it, as in the
    // repository. macOS runs a downloaded app that nobody has moved from a read-only copy (App
    // Translocation); Security.framework knows where the original is.
    private static func folder() -> URL? {
        var app = Bundle.main.bundleURL
        if app.path.contains("/AppTranslocation/"), let original = untranslocated(app) { app = original }
        return [app.appendingPathComponent("Contents/SharedSupport/freequay"), app.deletingLastPathComponent()].first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("scripts/freequay").path)
        }
    }

    private static func untranslocated(_ url: URL) -> URL? {
        typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        return unsafeBitCast(symbol, to: Original.self)(url as CFURL, nil)?.takeRetainedValue() as URL?
    }

    // A browser download is quarantined, and macOS then stops the unsigned wine. Whoever gets here
    // has allowed Freequay in Privacy & Security, so the app lifts the quarantine for its folder,
    // as `xattr -dr com.apple.quarantine` from the README does.
    private func liftQuarantine() {
        guard let root, getxattr(root.appendingPathComponent("dist/wine/bin/wine").path,
                                 "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0 else { return }
        for path in [""] + (FileManager.default.subpaths(atPath: root.path) ?? []) {
            removexattr(root.appendingPathComponent(path).path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    func reload() {
        guard root != nil else { return }
        bottles = output(["list"]).split(separator: "\n").map(String.init)
        if bottles.contains(bottle) {
            loadPrograms()
        } else {
            let last = UserDefaults.standard.string(forKey: "bottle") ?? ""
            bottle = bottles.contains(last) ? last : bottles.first ?? ""
        }
    }

    private func loadPrograms() {
        programs = bottle.isEmpty ? [] : output(["programs", bottle]).split(separator: "\n").compactMap {
            let fields = $0.split(separator: "\t", maxSplits: 1).map(String.init)
            return fields.count == 2 ? Program(name: fields[0], target: fields[1]) : nil
        }
    }

    func open(_ program: Program) {
        begin(program.target, name: program.name, in: bottle)
    }

    func start(_ urls: [URL]) {
        guard root != nil else { return }
        if bottle.isEmpty { reload() }  // perhaps created with the launcher meanwhile
        let programs = urls.filter { $0.pathExtension.lowercased() == "exe" }
        if programs.isEmpty {
            status = "Freequay starts Windows programs, the files that end in .exe."
        } else if bottle.isEmpty {
            waiting = programs
            naming = true
        } else if let exe = programs.first {
            runFile(exe, in: bottle)
        }
    }

    // An .exe started from outside the list joins the list of its bottle, unless it is an
    // installer: what it installs shows up through its Start menu shortcut anyway.
    private func runFile(_ exe: URL, in bottle: String) {
        guard starting == nil else { return wait() }
        let name = exe.lastPathComponent.lowercased()
        if !["setup", "install", "unins"].contains(where: { name.contains($0) }) {
            _ = output(["programs", bottle, exe.path])
            if self.bottle == bottle { loadPrograms() }
        }
        begin(exe.path, name: exe.lastPathComponent, in: bottle)
    }

    // One start at a time: the Open buttons wait until the program shows a new window, or two minutes
    // at most. A program whose window from an earlier start is still on screen comes to the front.
    private func begin(_ target: String, name: String, in bottle: String) {
        guard starting == nil else { return wait() }
        if let pids = opened[target], let pid = Model.wineWindows().map(\.pid).first(where: pids.contains) {
            _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
            status = "\(name) is already open."
            return
        }
        pending = Start(target: target, name: name, known: Set(Model.wineWindows().map(\.number)))
        starting = target
        status = "Starting \(name)…"
        run(target, name: name, in: bottle)
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, let start = pending else { return }
                let fresh = Model.wineWindows().filter { !start.known.contains($0.number) }.map(\.pid)
                let front = NSWorkspace.shared.frontmostApplication
                if !fresh.isEmpty {
                    opened[start.target, default: []].formUnion(fresh)
                    finish("\(start.name) is open.")
                } else if let front, front.processIdentifier != start.front,
                          front.executableURL?.lastPathComponent.hasPrefix("wine") == true {
                    opened[start.target, default: []].insert(front.processIdentifier)
                    finish("\(start.name) is open.")
                } else if let ended = start.ended, Date().timeIntervalSince(ended) > 2,
                          Model.wineProcesses().subtracting(start.processes).isEmpty {
                    // it ended and left nothing new running: it failed, or it handed over to a copy that
                    // runs already, like a second Steam
                    if start.code != 0 { return finish("\(start.name) stopped right away (exit code \(start.code)).") }
                    let apps = Set(Model.wineWindows().map(\.pid))
                    if apps.count == 1, let pid = apps.first {
                        _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
                        opened[start.target, default: []].insert(pid)
                    }
                    finish("\(start.name) is already running.")
                } else if start.ended.map({ Date().timeIntervalSince($0) > 15 }) == true {
                    finish(start.code != 0 ? "\(start.name) stopped right away (exit code \(start.code))."
                                           : "\(start.name) did not open a window.")
                } else if Date().timeIntervalSince(start.began) > 120 {
                    finish("\(start.name) has not shown a window yet. It may still be starting.")
                }
            }
        }
    }

    private func finish(_ message: String) {
        pending = nil
        starting = nil
        watch?.cancel()
        status = message
    }

    private func wait() {
        status = "\(pending?.name ?? "A program") is still starting. Programs start one at a time."
    }

    // running Wine programs: processes of Wine's loader, whatever Windows program they run
    nonisolated private static func wineProcesses() -> Set<pid_t> {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var path = [CChar](repeating: 0, count: 4096)
        return Set(pids.prefix(max(count, 0)).filter { pid in
            pid > 0 && proc_pidpath(pid, &path, UInt32(path.count)) > 0
                && String(cString: path).hasSuffix("/lib/wine/x86_64-unix/wine")
        })
    }

    // on-screen windows of Wine programs, as window number and owning process
    nonisolated private static func wineWindows() -> [(number: Int, pid: pid_t)] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.compactMap { window in
            let bounds = window[kCGWindowBounds as String] as? [String: Any]
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowOwnerName as String] as? String)?.hasPrefix("wine") == true,
                  (bounds?["Width"] as? Double ?? 0) >= 40, (bounds?["Height"] as? Double ?? 0) >= 40,
                  let number = window[kCGWindowNumber as String] as? Int,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t else { return nil }
            return (number, pid)
        }
    }

    // takes a program off the list: an added one is forgotten, a found one hidden; nothing is deleted
    func remove(_ program: Program) {
        _ = output(["programs", bottle, program.target, "-"])
        loadPrograms()
        status = "Removed \(program.name) from the list."
    }

    func choose() {
        guard root != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.exe]
        panel.message = "Choose a Windows program or installer you trust"
        if panel.runModal() == .OK { start(panel.urls) }
    }

    private func run(_ target: String, name: String, in bottle: String) {
        let started = Date()
        launch(["run", bottle, target]) { [weak self] code, output in
            guard let self else { return }
            // Steam ends with 42 after an update and leaves the rest to a new copy of itself (scripts/freequay)
            let steam = target.hasPrefix("steam:") || (target as NSString).lastPathComponent.lowercased() == "steam.exe"
            let code = steam && code == 42 ? 0 : code
            if self.bottle == bottle { loadPrograms() }  // an installer may have added programs
            // report what kept a program from starting; one that ran for a while may end as it likes
            let error = code == 0 ? nil : Model.error(in: output)
            if pending?.target == target {
                // without a message, the watch decides once it sees what the process left running
                if let error { finish(error) } else { pending?.ended = Date(); pending?.code = code }
            } else if let error {
                status = error
            } else if code != 0, Date().timeIntervalSince(started) < 15 {
                status = "\(name) stopped right away (exit code \(code))."
            }
        }
    }

    func create(_ name: String) {
        naming = false
        busy = true
        status = "Creating the bottle \(name), this takes about a minute."
        launch(["new", name]) { [weak self] code, output in
            guard let self else { return }
            busy = false
            let programs = waiting
            waiting = []
            guard code == 0 else {
                status = Model.error(in: output) ?? "Could not create the bottle \(name)."
                return
            }
            reload()
            bottle = name
            status = "The bottle \(name) is ready."
            if let exe = programs.first { self.runFile(exe, in: name) }
        }
    }

    func cancelNaming() {
        naming = false
        waiting = []
    }

    // installed, whether or not it was taken off the list
    var hasSteam: Bool { !bottle.isEmpty && FileManager.default.fileExists(atPath: steam(bottle).path) }

    private func steam(_ bottle: String) -> URL {
        bottlesDir.appendingPathComponent(bottle).appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
    }

    // Steam for Windows, installed silently from Valve's installer as in the README, then started
    func installSteam() {
        let bottle = self.bottle
        let steam = steam(bottle)
        busy = true
        status = "Downloading Steam…"
        Task {
            defer { busy = false }
            let setup = FileManager.default.temporaryDirectory.appendingPathComponent("SteamSetup.exe")
            do {
                let (download, response) = try await URLSession.shared.download(from: Model.steamSetup)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                try? FileManager.default.removeItem(at: setup)
                try FileManager.default.moveItem(at: download, to: setup)
            } catch {
                status = "Could not download Steam: \(error.localizedDescription)"
                return
            }
            status = "Installing Steam in \(bottle)…"
            let (_, output) = await launch(["run", bottle, setup.path, "/S"])
            try? FileManager.default.removeItem(at: setup)
            guard FileManager.default.fileExists(atPath: steam.path) else {
                status = Model.error(in: output) ?? "Steam did not install."
                return
            }
            if self.bottle == bottle { loadPrograms() }
            begin(steam.path, name: "Steam", in: bottle)
            if starting != nil { status = "Starting Steam. The first start downloads about 575 MB, restarts Steam twice and takes two minutes or more." }
        }
    }

    func stop() {
        let bottle = self.bottle
        if pending != nil { finish("Stopping all programs in \(bottle)…") }
        launch(["kill", bottle]) { [weak self] _, _ in self?.status = "Stopped all programs in \(bottle)." }
    }

    var hasD3DMetal: Bool {
        ["d3dmetal", "d3dmetal3"].contains { FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("backends/" + $0).path) }
    }

    // Opens the sheet and looks for Apple's disk image in Downloads (FREEQUAY_DOWNLOADS for tests) until
    // it is there; the user downloads it from Apple's page, with an Apple Account.
    func addD3DMetal() {
        addingD3DMetal = true
        d3dmetal = .waiting
        let downloads = ProcessInfo.processInfo.environment["FREEQUAY_DOWNLOADS"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        d3dmetalTask?.cancel()
        d3dmetalTask = Task { [weak self] in
            while !Task.isCancelled {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? []
                let images = names.filter {
                    let name = $0.lowercased()
                    return name.hasSuffix(".dmg") && (name.hasPrefix("evaluation_environment_for_windows_games")
                                                      || name.hasPrefix("game_porting_toolkit"))
                }
                if let newest = images.sorted().last {
                    self?.d3dmetal = .found(downloads.appendingPathComponent(newest))
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    // Opens the disk image, where macOS shows Apple's license; once it is mounted, the script copies
    // D3DMetal out of it, and the image is ejected again.
    func installD3DMetal(_ image: URL) {
        d3dmetal = .installing
        NSWorkspace.shared.open(image)
        d3dmetalTask?.cancel()
        d3dmetalTask = Task { [weak self] in
            let started = Date()
            while !Task.isCancelled, Date().timeIntervalSince(started) < 600 {
                if let volume = Model.portingToolkitVolume() {
                    self?.launch(["--d3dmetal", volume.path]) { code, output in
                        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: ["detach", "-quiet", volume.path])
                        guard let self else { return }
                        let line = output.split(separator: "\n").last(where: { $0.hasPrefix("D3DMetal ") }).map(String.init)
                        self.d3dmetal = code == 0 ? .done(line ?? "D3DMetal is installed.") : .failed(Model.error(in: output) ?? output)
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if !Task.isCancelled { self?.d3dmetal = .failed("The disk image did not open. Open it in Finder and agree to Apple's license.") }
        }
    }

    func closeD3DMetal() {
        d3dmetalTask?.cancel()
        addingD3DMetal = false
    }

    // a mounted Game Porting Toolkit: a volume with redist/lib/wine at most two folders down
    nonisolated private static func portingToolkitVolume() -> URL? {
        let fm = FileManager.default
        for volume in fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [] {
            for base in [volume] + ((try? fm.contentsOfDirectory(at: volume, includingPropertiesForKeys: nil)) ?? []) {
                if fm.fileExists(atPath: base.appendingPathComponent("redist/lib/wine").path) { return volume }
            }
        }
        return nil
    }

    func showFiles() {
        NSWorkspace.shared.open(bottlesDir.appendingPathComponent(bottle).appendingPathComponent("drive_c"))
    }

    // scripts/freequay with these arguments; --d3dmetal <volume> runs scripts/install-d3dmetal.sh instead
    private func launcher(_ arguments: [String]) -> Process? {
        guard let root else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let script = arguments.first == "--d3dmetal" ? "scripts/install-d3dmetal.sh" : "scripts/freequay"
        process.arguments = [root.appendingPathComponent(script).path] + arguments.drop { $0 == "--d3dmetal" }
        process.currentDirectoryURL = root
        process.standardInput = FileHandle.nullDevice
        if servers { process.environment = ProcessInfo.processInfo.environment.merging(["FREEQUAY_OFFLINE": "1"]) { $1 } }
        return process
    }

    private func output(_ arguments: [String]) -> String {
        guard let process = launcher(arguments) else { return "" }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // Runs the launcher in the background; `done` gets its exit code and output. The output goes
    // to a file, not a pipe, so that programs keep running when the app quits.
    private func launch(_ arguments: [String], done: @escaping @MainActor (Int32, String) -> Void) {
        guard let process = launcher(arguments) else { return }
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("freequay-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let file = try? FileHandle(forWritingTo: log)
        process.standardOutput = file
        process.standardError = file
        process.terminationHandler = { process in
            let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: log)
            let code = process.terminationStatus
            Task { @MainActor in done(code, output) }
        }
        do {
            try process.run()
        } catch {
            done(-1, "freequay: \(error.localizedDescription)")
        }
        try? file?.close()
    }

    private func launch(_ arguments: [String]) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            launch(arguments) { continuation.resume(returning: ($0, $1)) }
        }
    }

    // the last thing the launcher, zsh running it or Wine's loader said before giving up
    private static func error(in output: String) -> String? {
        output.split(separator: "\n").last {
            $0.hasPrefix("freequay: ") || $0.hasPrefix("wine: ") || $0.contains("scripts/freequay:")
        }.map(String.init)
    }
}

private let accent = Color(red: 0.13, green: 0.32, blue: 0.93)
private let accentLight = Color(red: 0.22, green: 0.42, blue: 1.0)
private let ink = Color(red: 0.08, green: 0.09, blue: 0.11)
private let muted = Color(red: 0.42, green: 0.43, blue: 0.47)
private let shore = Color(red: 0.955, green: 0.96, blue: 0.97)

struct ContentView: View {
    @ObservedObject var model: Model
    @State private var over = false  // a file is being dragged over the window
    @State private var hovered: String?  // the row or strip under the pointer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Freequay").font(.system(size: 34, weight: .heavy)).foregroundStyle(ink)
                .sheet(isPresented: $model.servers) { Servers(model: model).interactiveDismissDisabled() }
            Text("Windows programs on your Mac").font(.system(size: 14)).foregroundStyle(muted).padding(.top, 1)
            if model.root == nil {
                quay {
                    note("Freequay.app is missing its parts", "Download Freequay again and drag it into Applications.")
                }
            } else if model.onDiskImage {
                quay {
                    note("Drag Freequay into Applications", "Then open it from there. On the disk image it cannot start programs.",
                         arrow: true)
                }
            } else {
                bottleRow.padding(.top, 22)
                quay { shelf }
                if !model.bottle.isEmpty && !model.hasSteam {
                    HStack(spacing: 14) {
                        Button("Install Steam") { model.installSteam() }.buttonStyle(Solid()).disabled(model.busy)
                        Text("Steam for Windows from Valve, about 1.5 GB").font(.system(size: 12.5)).foregroundStyle(muted)
                    }
                    .padding(.top, 16)
                }
                if !model.bottles.isEmpty && !model.hasD3DMetal {
                    HStack(spacing: 14) {
                        Button("Add D3DMetal…") { model.addD3DMetal() }.buttonStyle(Quiet())
                        Text("Apple's DirectX 12 for many newer games, from Apple's download").font(.system(size: 12.5)).foregroundStyle(muted)
                    }
                    .padding(.top, 12)
                    .sheet(isPresented: $model.addingD3DMetal) { AddD3DMetal(model: model).interactiveDismissDisabled() }
                }
            }
            HStack(spacing: 8) {
                if model.busy || (model.starting != nil && !model.programs.contains { $0.target == model.starting }) {
                    ProgressView().controlSize(.small)
                }
                Text(model.status).font(.system(size: 12.5)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 18)
            .padding(.top, 18)
        }
        .padding(.horizontal, 32)
        .padding(.top, 12)
        .padding(.bottom, 24)
        .frame(width: 580, alignment: .leading)
        .background(Color.white)
        .dropDestination(for: URL.self) { urls, _ in
            model.start(urls)
            return true
        } isTargeted: { over = $0 }
        .sheet(isPresented: $model.naming) { NewBottle(model: model) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.reload() }
    }

    // the place where programs land: a calm panel with a quay edge in the accent colour
    private func quay<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(height: 252)
            .background(over ? accent.opacity(0.09) : shore)
            .overlay(alignment: .bottom) { accent.frame(height: 5) }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.top, 14)
    }

    private func note(_ title: String, _ detail: String, arrow: Bool = false) -> some View {
        VStack(spacing: 8) {
            if arrow { landing(size: 28).padding(.bottom, 4) }
            Text(title).font(.system(size: 19, weight: .semibold)).foregroundStyle(ink)
            Text(detail).font(.system(size: 13)).foregroundStyle(muted).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 30)
    }

    // the sign for dropping: an arrow landing on the quay edge
    private func landing(size: CGFloat) -> some View {
        Image(systemName: "arrow.down.to.line")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(accent)
            .accessibilityHidden(true)
    }

    // the programs of the bottle, or what to do when there are none
    @ViewBuilder private var shelf: some View {
        if over {
            note("Let go to start it", "Installers and other Windows programs start in \(model.bottle.isEmpty ? "a new bottle" : model.bottle).", arrow: true)
        } else if model.bottles.isEmpty {
            VStack(spacing: 16) {
                note("No bottle yet", "A bottle is a Windows drive of its own, where your Windows programs and games are installed.")
                Button("Create a bottle") { model.naming = true }.buttonStyle(Solid()).disabled(model.busy)
            }
        } else if model.programs.isEmpty {
            VStack(spacing: 12) {
                note("Nothing installed in \(model.bottle) yet",
                     "Drop the installer of a Windows program (.exe) here, or install Steam below.", arrow: true)
                Button("Choose an installer…") { model.choose() }.buttonStyle(Quiet())
            }
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.programs) { program in
                            row(program)
                            if program.id != model.programs.last?.id { Divider().padding(.horizontal, 20) }
                        }
                    }
                    .padding(.vertical, 6)
                }
                // a landing strip on the quay edge, for installers
                Button { model.choose() } label: {
                    HStack(spacing: 8) {
                        landing(size: 15)
                        Text("Drop an installer here").font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .padding(.bottom, 5)
                    .background(accent.opacity(hovered == "strip" ? 0.11 : 0.06))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { hovered = "strip" } else if hovered == "strip" { hovered = nil }
                }
                .help("Drop the installer of a Windows program (.exe) here, or click to choose one")
            }
        }
    }

    // a program of the list; while one starts, its row shows the spinner and all rows wait
    private func row(_ program: Program) -> some View {
        let locked = model.starting != nil
        return Button { model.open(program) } label: {
            HStack(spacing: 10) {
                Text(program.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
                if program.steamGame {
                    Text("Steam game").font(.system(size: 12)).foregroundStyle(muted)
                }
                Spacer(minLength: 12)
                if model.starting == program.target {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Open").font(.system(size: 13, weight: .medium)).foregroundStyle(accent).opacity(locked ? 0.35 : 1)
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 46)
            .background(hovered == program.id && !locked ? accent.opacity(0.07) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)  // not disabled while locked: that would grey out the spinner too
        .onHover { inside in
            if inside { hovered = program.id } else if hovered == program.id { hovered = nil }
        }
        .contextMenu {
            Button("Remove from List") { model.remove(program) }
        }
    }

    private var bottleRow: some View {
        HStack(spacing: 14) {
            if !model.bottles.isEmpty {
                Text("Bottle").font(.system(size: 13)).foregroundStyle(muted)
                Picker("Bottle", selection: $model.bottle) {
                    ForEach(model.bottles, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Button("New…") { model.naming = true }.buttonStyle(Quiet()).disabled(model.busy)
                Spacer()
                Button("Show files") { model.showFiles() }.buttonStyle(Quiet())
                Button("Stop all programs") { model.stop() }.buttonStyle(Quiet())
            }
        }
        .frame(height: 24)
    }
}

// what Freequay downloads, from where and why; shown once, before anything is downloaded
struct Servers: View {
    @ObservedObject var model: Model

    private let rows = [
        ("AppleGamingWiki", "settings for your Steam games, CC\u{00A0}BY\u{2011}NC\u{2011}SA\u{00A0}3.0"),  // kept on one line
        ("WineHQ", "Wine Mono, when you create a bottle"),
        ("Valve", "Steam, when you install it"),
        ("GitHub", "winetricks, when a game needs runtime packages"),
        ("Microsoft, mirrors", "the runtime packages games ask for"),
        ("Apple", "D3DMetal, only if you add it yourself"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What Freequay downloads").font(.system(size: 19, weight: .bold)).foregroundStyle(ink)
            Text("Freequay fetches from these servers when it needs something:")
                .font(.system(size: 13)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                ForEach(rows, id: \.0) { server, what in
                    GridRow(alignment: .firstTextBaseline) {
                        Text(server).font(.system(size: 13, weight: .semibold)).foregroundStyle(ink)
                        Text(what).font(.system(size: 13)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.top, 14)
            Text("Freequay itself collects no data.").font(.system(size: 13, weight: .semibold)).foregroundStyle(ink).padding(.top, 14)
            HStack {
                Spacer()
                Button("Continue") { model.serversRead() }.buttonStyle(Solid()).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 20)
        }
        .padding(24)
        .frame(width: 440)
        .background(Color.white)
    }
}

// Apple's D3DMetal in three steps: Apple's download page, the disk image found in Downloads, and the
// installation after the note on Apple's license
struct AddD3DMetal: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("D3DMetal from Apple").font(.system(size: 19, weight: .bold)).foregroundStyle(ink)
            Text("D3DMetal runs many DirectX 11 and 12 games on Metal. Apple offers it for free to anyone with an Apple Account, "
                 + "as \u{201C}Evaluation environment for Windows games\u{201D}; Freequay is not allowed to include it.")
                .font(.system(size: 13)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            switch model.d3dmetal {
            case .waiting:
                Button("Open Apple's download page") { NSWorkspace.shared.open(Model.appleDownload) }.buttonStyle(Solid()).padding(.top, 16)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Download the newest version there. Freequay finds it in your Downloads folder.")
                        .font(.system(size: 12.5)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 14)
            case .found(let image):
                Text("Found version \(AddD3DMetal.version(image)) in your Downloads folder.")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(ink).padding(.top, 16)
                Text("D3DMetal belongs to Apple. Apple's license comes with the download and allows using D3DMetal to develop, "
                     + "test and evaluate games. By clicking Install you agree to it.")
                    .font(.system(size: 13)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            case .installing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("If macOS shows Apple's license, agree to it; Freequay then copies D3DMetal.")
                        .font(.system(size: 12.5)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 16)
            case .done(let message):
                Text(message).font(.system(size: 13, weight: .semibold)).foregroundStyle(ink).padding(.top, 16)
                Text("Programs that need it get it by themselves.").font(.system(size: 13)).foregroundStyle(muted).padding(.top, 4)
            case .failed(let message):
                Text(message).font(.system(size: 13)).foregroundStyle(ink).fixedSize(horizontal: false, vertical: true).padding(.top, 16)
            }
            HStack(spacing: 16) {
                Spacer()
                switch model.d3dmetal {
                case .found(let image):
                    Button("Cancel") { model.closeD3DMetal() }.buttonStyle(Quiet()).keyboardShortcut(.cancelAction)
                    Button("Install") { model.installD3DMetal(image) }.buttonStyle(Solid()).keyboardShortcut(.defaultAction)
                case .done, .failed:
                    Button("Done") { model.closeD3DMetal() }.buttonStyle(Solid()).keyboardShortcut(.defaultAction)
                default:
                    Button("Cancel") { model.closeD3DMetal() }.buttonStyle(Quiet()).keyboardShortcut(.cancelAction)
                }
            }
            .padding(.top, 20)
        }
        .padding(24)
        .frame(width: 420)
        .background(Color.white)
    }

    // Evaluation_environment_for_Windows_games_4.0_beta_2.dmg -> 4.0 beta 2
    static func version(_ image: URL) -> String {
        let name = image.deletingPathExtension().lastPathComponent
        let digits = name.firstIndex(where: \.isNumber) ?? name.endIndex
        return name[digits...].replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
    }
}

struct NewBottle: View {
    @ObservedObject var model: Model
    @State private var name: String

    init(model: Model) {
        self.model = model
        _name = State(initialValue: model.bottles.isEmpty ? "games" : "")
    }

    private var valid: Bool {
        name.range(of: "^[A-Za-z0-9][A-Za-z0-9 ._-]{0,39}$", options: .regularExpression) != nil && !model.bottles.contains(name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New bottle").font(.system(size: 19, weight: .bold)).foregroundStyle(ink)
            Text("A bottle is a Windows drive of its own. Programs in one bottle share their files and settings.")
                .font(.system(size: 13)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            // a bottle is no sandbox: Wine's drive Z: is the whole Mac
            (Text("Only start programs you trust. ").fontWeight(.semibold).foregroundColor(ink)
                + Text("Windows programs in a bottle can read and change all your files."))
                .font(.system(size: 13)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).padding(.top, 16)
                .onSubmit { if valid { model.create(name) } }
            HStack(spacing: 16) {
                Spacer()
                Button("Cancel") { model.cancelNaming() }.buttonStyle(Quiet()).keyboardShortcut(.cancelAction)
                Button("Create") { model.create(name) }.buttonStyle(Solid()).keyboardShortcut(.defaultAction).disabled(!valid)
            }
            .padding(.top, 20)
        }
        .padding(24)
        .frame(width: 360)
        .background(Color.white)
    }
}

// a filled button in the accent colour, with corners that keep it from looking like a pill
private struct Solid: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(LinearGradient(colors: [accentLight, accent], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(enabled ? configuration.isPressed ? 0.8 : 1 : 0.4)
    }
}

// a button that is only its words, in the accent colour
private struct Quiet: ButtonStyle {
    var size: CGFloat = 13
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(accent)
            .opacity(enabled ? configuration.isPressed ? 0.6 : 1 : 0.4)
            .contentShape(Rectangle())
    }
}
