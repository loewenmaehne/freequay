// Freequay.app: one window that starts Windows programs without Terminal. Drop an .exe on the
// window or on the Dock icon, or open it from Finder, and it starts in the chosen bottle. The app
// only calls scripts/freequay, which sits next to it in the Freequay folder; scripts/build-app.sh
// builds it.
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
    @Published var bottle = "" { didSet { UserDefaults.standard.set(bottle, forKey: "bottle") } }
    @Published var status = ""
    @Published var busy = false    // a bottle or Steam is being set up
    @Published var naming = false  // the sheet for a new bottle is open
    private var waiting: [URL] = []  // programs dropped before there was a bottle

    let root: URL?  // the Freequay folder
    private let bottlesDir: URL  // as in scripts/freequay

    private static let steamSetup = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!

    init() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        bottlesDir = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/freequay/Bottles")
        root = Model.folder()
        guard root != nil else { return }
        liftQuarantine()
        reload()
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

    private func run(_ program: URL, in bottle: String, _ arguments: [String] = []) {
        let started = Date()
        status = "Started \(program.lastPathComponent) in \(bottle)."
        // report what kept a program from starting; one that ran for a while may end as it likes
        launch(["run", bottle, program.path] + arguments) { [weak self] code, output in
            guard code != 0 else { return }
            if let error = Model.error(in: output) {
                self?.status = error
            } else if Date().timeIntervalSince(started) < 15 {
                self?.status = "\(program.lastPathComponent) stopped right away (exit code \(code))."
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
            programs.forEach { self.run($0, in: name) }
        }
    }

    func cancelNaming() {
        naming = false
        waiting = []
    }

    var hasSteam: Bool { !bottle.isEmpty && FileManager.default.fileExists(atPath: steam(bottle).path) }

    private func steam(_ bottle: String) -> URL {
        bottlesDir.appendingPathComponent(bottle).appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
    }

    // Steam for Windows: installed silently from Valve's installer the first time, as in the README
    func startSteam() {
        let bottle = self.bottle
        if hasSteam { return run(steam(bottle), in: bottle) }
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
            guard FileManager.default.fileExists(atPath: steam(bottle).path) else {
                status = Model.error(in: output) ?? "Steam did not install."
                return
            }
            run(steam(bottle), in: bottle)
            status = "Steam starts. The first start downloads about 480 MB and takes a minute or two."
        }
    }

    func stop() {
        let bottle = self.bottle
        launch(["kill", bottle]) { [weak self] _, _ in self?.status = "Stopped all programs in \(bottle)." }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Freequay").font(.system(size: 34, weight: .heavy)).foregroundStyle(ink)
            Text("Windows programs on your Mac").font(.system(size: 14)).foregroundStyle(muted).padding(.top, 1)
            if model.root == nil {
                quay {
                    Text("Freequay.app has to stay in its folder").font(.system(size: 19, weight: .semibold)).foregroundStyle(ink)
                    Text("Put it back next to the folders scripts and dist, then open it again.")
                        .font(.system(size: 13)).foregroundStyle(muted)
                }
            } else {
                quay {
                    Text(over ? "Let go to start it" : "Drop a Windows program here")
                        .font(.system(size: 21, weight: .semibold)).foregroundStyle(ink)
                    Button("or choose one…") { model.choose() }.buttonStyle(Quiet(size: 14))
                }
                bottleRow.padding(.top, 22)
                if !model.bottle.isEmpty {
                    HStack(spacing: 12) {
                        Button(model.hasSteam ? "Start Steam" : "Install Steam") { model.startSteam() }
                            .buttonStyle(Solid()).disabled(model.busy)
                        if !model.hasSteam {
                            Text("Steam for Windows from Valve, about 1.5 GB with its first update")
                                .font(.system(size: 12.5)).foregroundStyle(muted)
                        }
                    }
                    .padding(.top, 16)
                }
            }
            HStack(spacing: 8) {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status).font(.system(size: 12.5)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 18)
            .padding(.top, 20)
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
        VStack(spacing: 10, content: content)
            .frame(maxWidth: .infinity, minHeight: 196)
            .background(over ? accent.opacity(0.09) : shore)
            .overlay(alignment: .bottom) { accent.frame(height: 5) }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.top, 24)
    }

    private var bottleRow: some View {
        HStack(spacing: 14) {
            Text("Bottle").font(.system(size: 13)).foregroundStyle(muted)
            if model.bottles.isEmpty {
                Button("Create a bottle") { model.naming = true }.buttonStyle(Solid()).disabled(model.busy)
            } else {
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
