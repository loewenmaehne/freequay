// Freequay.app: one window that starts Windows programs without Terminal. Drop an .exe on the
// window or on the Dock icon, or open it from Finder, and it starts on the chosen Windows drive.
// The app only calls scripts/freequay, which sits next to it in the Freequay folder;
// scripts/build-app.sh builds it. A Windows drive is what the launcher calls a bottle. Since the
// rules per program let all games share one, the app sets up the first drive by itself and keeps
// the others in the menu at the top right.
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

@MainActor
final class Model: ObservableObject {
    @Published var bottles: [String] = []
    @Published var bottle = "" {
        didSet {
            UserDefaults.standard.set(bottle, forKey: "bottle")
            if bottle != oldValue {
                status = ""
                steamNote = nil
            }
            checkRunning()
        }
    }
    @Published var status = ""
    @Published var busy = false        // a Windows drive or Steam is being set up
    @Published var steamStep: String?  // what happens to Steam while it is set up, with a spinner
    @Published var steamNote: String?  // what came of the last start of Steam
    @Published var running = false     // programs run on the chosen drive
    @Published var naming = false      // the sheet for a new drive is open
    private var waiting: [URL] = []    // programs dropped before there was a drive
    private var steamWaits = false     // Steam was asked for before there was a drive

    let root: URL?  // the Freequay folder
    private let bottlesDir: URL  // as in scripts/freequay

    private static let firstBottle = "games"  // the drive the app sets up by itself, as in the README
    private static let steamSetup = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!

    init() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        bottlesDir = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/freequay/Bottles")
        root = Model.folder()
        guard root != nil else { return }
        liftQuarantine()
        reload()
        // also programs that end by themselves or were started with the launcher
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkRunning() }
        }
    }

    // The folder around the app, if scripts/freequay is in it. macOS runs a downloaded app that
    // nobody has moved from a read-only copy without that folder (App Translocation);
    // Security.framework knows where the original is.
    private static func folder() -> URL? {
        var app = Bundle.main.bundleURL
        if app.path.contains("/AppTranslocation/"), let original = untranslocated(app) { app = original }
        let root = app.deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("scripts/freequay").path) ? root : nil
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
        if !bottles.contains(bottle) {
            let last = UserDefaults.standard.string(forKey: "bottle") ?? ""
            bottle = bottles.contains(last) ? last : bottles.first ?? ""
        }
        checkRunning()
    }

    // Do programs run on the chosen drive? As bottle_running in scripts/freequay: Wine's server
    // keeps its socket in /tmp/.wine-<uid>/server-<device>-<inode of the bottle> while it runs.
    func checkRunning() {
        var info = stat()
        let now = !bottle.isEmpty && stat(bottlesDir.appendingPathComponent(bottle).path, &info) == 0 &&
            FileManager.default.fileExists(atPath: String(format: "/tmp/.wine-%u/server-%llx-%llx/socket", getuid(),
                                                          UInt64(UInt32(bitPattern: info.st_dev)), UInt64(info.st_ino)))
        if running != now { running = now }
    }

    func start(_ urls: [URL]) {
        guard root != nil else { return }
        let programs = urls.filter { $0.pathExtension.lowercased() == "exe" }
        guard !programs.isEmpty else {
            status = "Freequay starts Windows programs, the files that end in .exe."
            return
        }
        if bottle.isEmpty { reload() }  // perhaps created with the launcher meanwhile
        if bottle.isEmpty {
            waiting += programs
            setUp()
        } else {
            programs.forEach { run($0, in: bottle) }
        }
    }

    func choose() {
        guard root != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.exe]
        panel.message = "Choose a Windows program"
        if panel.runModal() == .OK { start(panel.urls) }
    }

    // what happens with Steam is said on its card, everything else where programs land
    private func run(_ program: URL, in bottle: String, _ arguments: [String] = [], steam: Bool = false) {
        let started = Date()
        let say: @MainActor (String) -> Void = { [weak self] in
            if steam { self?.steamNote = $0 } else { self?.status = $0 }
        }
        say(steam ? "Steam starts." : "Started \(program.lastPathComponent).")
        // report what kept a program from starting; one that ran for a while may end as it likes
        launch(["run", bottle, program.path] + arguments) { code, output in
            guard code != 0 else { return }
            if let error = Model.error(in: output) {
                say(error)
            } else if Date().timeIntervalSince(started) < 15 {
                say("\(program.lastPathComponent) stopped right away (exit code \(code)).")
            }
        }
    }

    // the first drive, without asking for a name: most people never need a second one
    private func setUp() {
        if !busy { create(Model.firstBottle) }
    }

    func create(_ name: String) {
        let first = bottles.isEmpty
        naming = false
        busy = true
        if !steamWaits {  // otherwise the Steam card says it
            status = first ? "Getting Windows ready, this takes about a minute." : "Setting up the Windows drive \(name), this takes about a minute."
        }
        launch(["new", name]) { [weak self] code, output in
            guard let self else { return }
            busy = false
            let programs = waiting, steam = steamWaits
            waiting = []
            steamWaits = false
            guard code == 0 else {
                steamStep = nil
                status = Model.error(in: output) ?? "Could not set up the Windows drive \(name)."
                return
            }
            reload()
            bottle = name
            status = first ? "Windows is ready." : "The Windows drive \(name) is ready."
            programs.forEach { self.run($0, in: name) }
            if steam { startSteam() }
        }
    }

    func cancelNaming() {
        naming = false
    }

    var hasSteam: Bool { !bottle.isEmpty && FileManager.default.fileExists(atPath: steam(bottle).path) }

    private func steam(_ bottle: String) -> URL {
        bottlesDir.appendingPathComponent(bottle).appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
    }

    // Steam for Windows: installed silently from Valve's installer the first time, as in the README
    func startSteam() {
        guard root != nil, !busy else { return }
        if bottle.isEmpty { reload() }
        if bottle.isEmpty {
            steamWaits = true
            steamStep = "Getting Windows ready…"
            return setUp()
        }
        let bottle = self.bottle
        steamNote = nil
        if hasSteam { return run(steam(bottle), in: bottle, steam: true) }
        busy = true
        steamStep = "Downloading Steam…"
        Task {
            defer {
                busy = false
                steamStep = nil
            }
            let setup = FileManager.default.temporaryDirectory.appendingPathComponent("SteamSetup.exe")
            do {
                let (download, response) = try await URLSession.shared.download(from: Model.steamSetup)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                try? FileManager.default.removeItem(at: setup)
                try FileManager.default.moveItem(at: download, to: setup)
            } catch {
                steamNote = "Could not download Steam: \(error.localizedDescription)"
                return
            }
            steamStep = "Installing Steam…"
            let (_, output) = await launch(["run", bottle, setup.path, "/S"])
            try? FileManager.default.removeItem(at: setup)
            guard FileManager.default.fileExists(atPath: steam(bottle).path) else {
                steamNote = Model.error(in: output) ?? "Steam did not install."
                return
            }
            run(steam(bottle), in: bottle, steam: true)
            steamNote = "Steam starts. The first start loads about 480 MB, a minute or two."
        }
    }

    func stop() {
        let bottle = self.bottle
        guard !bottle.isEmpty else { return }
        launch(["kill", bottle]) { [weak self] _, _ in
            self?.status = "Stopped all programs."
            self?.checkRunning()
        }
    }

    func showFiles() {
        NSWorkspace.shared.open(bottlesDir.appendingPathComponent(bottle).appendingPathComponent("drive_c"))
    }

    // scripts/freequay with these arguments
    private func launcher(_ arguments: [String]) -> Process? {
        guard let root else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [root.appendingPathComponent("scripts/freequay").path] + arguments
        process.currentDirectoryURL = root
        process.standardInput = FileHandle.nullDevice
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

    // the last thing the launcher, zsh running it or Wine's loader said before giving up; the
    // launcher's own name in front of it says nothing in its window
    private static func error(in output: String) -> String? {
        output.split(separator: "\n").last {
            $0.hasPrefix("freequay: ") || $0.hasPrefix("wine: ") || $0.contains("scripts/freequay:")
        }.map { $0.hasPrefix("freequay: ") ? String($0.dropFirst(10)) : String($0) }
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
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.root == nil {
                quay {
                    Text("Freequay.app has to stay in its folder").font(.system(size: 19, weight: .semibold)).foregroundStyle(ink)
                    Text("Put it back next to the folders scripts and dist, then open it again.")
                        .font(.system(size: 13)).foregroundStyle(muted)
                }
            } else {
                quay { landing }
                steam.padding(.top, 12)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 28)
        .frame(width: 560, alignment: .leading)
        .background(Color.white)
        .dropDestination(for: URL.self) { urls, _ in
            model.start(urls)
            return true
        } isTargeted: { over = $0 }
        .sheet(isPresented: $model.naming) { NewBottle(model: model) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.reload() }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Freequay").font(.system(size: 34, weight: .heavy)).foregroundStyle(ink)
                Text("Windows games on your Mac").font(.system(size: 14)).foregroundStyle(muted)
            }
            Spacer()
            if model.root != nil { drives }
        }
    }

    // where programs land: a calm panel with a quay edge in the accent colour
    private func quay<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 10, content: content)
            .frame(maxWidth: .infinity, minHeight: 224)
            .overlay(alignment: .bottom) { if model.root != nil { report } }
            .background(over ? accent.opacity(0.08) : shore)
            .overlay(alignment: .bottom) { accent.frame(height: over ? 8 : 5) }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.top, 22)
            .animation(still ? nil : .easeOut(duration: 0.15), value: over)
    }

    private var landing: some View {
        Group {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(accent)
                .accessibilityHidden(true)
                .offset(y: over && !still ? 5 : 0)
                .padding(.bottom, 4)
            Text(over ? "Let go to start it" : "Drop a Windows program here")
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(ink)
            Button("or choose one…") { model.choose() }.buttonStyle(Quiet(size: 14)).opacity(over ? 0 : 1)
        }
    }

    // Steam for Windows, where most games come from; the rules per game apply to games it starts
    private var steam: some View {
        HStack(spacing: 14) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(ink, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Steam").font(.system(size: 16, weight: .semibold)).foregroundStyle(ink)
                Text(model.steamStep ?? model.steamNote ??
                     (model.hasSteam ? "Your Steam games for Windows" : "Steam for Windows from Valve, about 1.5 GB"))
                    .font(.system(size: 12.5)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if model.steamStep != nil {
                ProgressView().controlSize(.small)
            } else {
                Button(model.hasSteam ? "Open" : "Install") { model.startSteam() }
                    .buttonStyle(Solid()).disabled(model.busy)
            }
        }
        .padding(12)
        .padding(.trailing, 4)
        .background(shore, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // what became of the last program, at the foot of the panel; and a way to stop them all
    private var report: some View {
        HStack(spacing: 10) {
            if model.busy && model.steamStep == nil { ProgressView().controlSize(.small) }
            Text(model.status.isEmpty && model.running ? "Windows programs are running." : model.status)
                .font(.system(size: 12.5)).foregroundStyle(muted)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if model.running {
                Button("Stop all") { model.stop() }.buttonStyle(Quiet(size: 12.5))
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 22)
    }

    // the Windows drives, in the background: one is enough, and the app sets it up by itself
    private var drives: some View {
        Menu {
            Section("Windows drive") {
                ForEach(model.bottles, id: \.self) { name in
                    Toggle(name, isOn: Binding(get: { model.bottle == name }, set: { if $0 { model.bottle = name } }))
                }
                Button("New Windows Drive…") { model.naming = true }.disabled(model.busy)
            }
            Divider()
            Button("Show Files in Finder") { model.showFiles() }.disabled(model.bottle.isEmpty)
            Button("Stop All Programs") { model.stop() }.disabled(model.bottle.isEmpty)
        } label: {
            if model.bottles.count > 1 {
                Label(model.bottle, systemImage: "internaldrive").labelStyle(.titleAndIcon)
            } else {
                Image(systemName: "ellipsis.circle")
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(model.bottles.count > 1 ? .visible : .hidden)
        .fixedSize()
        .help("Each Windows drive has its own C: with its own programs and settings.")
        .accessibilityLabel("Windows drive")
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
            Text("New Windows drive").font(.system(size: 19, weight: .bold)).foregroundStyle(ink)
            Text("A separate C: drive with its own programs and settings. One is enough for most games.")
                .font(.system(size: 13)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
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
        .frame(width: 380)
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
            .padding(.horizontal, 16)
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
