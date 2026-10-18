// Freequay: applies the setup directives of the rules to a bottle (freequay fix).
//
// ntdll applies backend, env, dll, args and exe at every start. These directives change the bottle once:
//     verb=<winetricks verb>            installed with winetricks
//     reg=<key>|<name>|<type>|<value>   registry value; only <key> creates the key
//     winver=<version>                  Windows version for the game's programs
// Proton gives every game its own prefix, here all games share the bottle. So the DLL overrides a
// winetricks verb sets for the whole prefix move to the programs of the game that asked for it
// (HKCU\Software\Wine\AppDefaults\<program.exe>\DllOverrides), and so does the Windows version.
// Done steps are listed in <bottle>/freequay-fixes.txt, with the overrides each verb set, so a second
// game asking for an installed verb gets the same overrides.
// Until Freequay 0.2.2 this was fix.py, which needed python3 from the Command Line Tools.
//
// Usage: fix <bottle dir> <wine binary> <winetricks script> <rule files, colon-separated>
//            [--list] [steam:<id>|exe:<name.exe> ...]
// Without keys: every Steam game installed in the bottle. scripts/build-app.sh builds it.
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let fm = FileManager.default

// setup directives per key: verbs and regs in order, the first winver
struct Setup { var verb: [String] = [], reg: [String] = [], winver: String? }

func readRules(_ files: [String]) -> [String: Setup] {
    var rules: [String: Setup] = [:]
    for path in files {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        for line in text.components(separatedBy: "\n") where !line.hasPrefix("#") && line.contains("\t") {
            let fields = line.components(separatedBy: "\t")
            var r = rules[fields[0]] ?? Setup()
            for d in fields.dropFirst() {
                let name = d.components(separatedBy: "=")[0], value = String(d.dropFirst(name.count + 1))
                if name == "verb", d.contains("="), !r.verb.contains(value) { r.verb.append(value) }
                else if name == "reg", d.contains("="), !r.reg.contains(value) { r.reg.append(value) }
                else if name == "winver", d.contains("="), r.winver == nil || r.winver == "" { r.winver = value }
            }
            rules[fields[0]] = r
        }
    }
    return rules
}

func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
    try! NSRegularExpression(pattern: pattern, options: options)
}

func groups(_ rx: NSRegularExpression, _ text: String) -> [[String]] {
    rx.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { m in
        (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
}

func vdfValues(_ path: String, _ name: String) -> [String] {
    guard let data = fm.contents(atPath: path) else { return [] }
    return groups(regex("\"" + name + "\"\\s+\"([^\"]*)\""), String(decoding: data, as: UTF8.self)).map { $0[0] }
}

// app ID -> (title, game dir) of the Steam games installed in the bottle
func steamGames(_ bottle: String) -> [String: (String, String)] {
    let steam = bottle + "/drive_c/Program Files (x86)/Steam"
    var libs = [steam]
    for value in vdfValues(steam + "/steamapps/libraryfolders.vdf", "path") {
        let p = value.replacingOccurrences(of: "\\\\", with: "\\")
        guard p.range(of: #"^[A-Za-z]:\\"#, options: .regularExpression) != nil else { continue }
        let unix = ([bottle, "dosdevices", p.prefix(1).lowercased() + ":"] + p.dropFirst(3).components(separatedBy: "\\"))
            .joined(separator: "/")
        var isDir: ObjCBool = false
        let real = URL(fileURLWithPath: unix).resolvingSymlinksInPath().path
        if fm.fileExists(atPath: unix, isDirectory: &isDir), isDir.boolValue,
           !libs.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }).contains(real) {
            libs.append(unix)
        }
    }
    var games: [String: (String, String)] = [:]
    let manifest = regex(#"^appmanifest_(\d+)\.acf$"#)
    for lib in libs {
        let apps = lib + "/steamapps"
        for file in (try? fm.contentsOfDirectory(atPath: apps)) ?? [] {
            guard let id = groups(manifest, file).first?[0] else { continue }
            let path = apps + "/" + file
            let installdir = vdfValues(path, "installdir").first ?? ""
            if !installdir.isEmpty { games[id] = (vdfValues(path, "name").first ?? "", apps + "/common/" + installdir) }
        }
    }
    return games
}

let skipDirs = regex(#"(^|/)(_?commonredist|redist|redistributables|__installer|directx|vcredist|support|installers?)(/|$)"#,
                     .caseInsensitive)

// the .exe files of a game, without those of its redistributables and installers, at most 64
func gamePrograms(_ dir: String) -> [String] {
    var found = Set<String>()
    guard let walk = fm.enumerator(atPath: dir) else { return [] }
    while let rel = walk.nextObject() as? String {
        var isDir: ObjCBool = false
        fm.fileExists(atPath: dir + "/" + rel, isDirectory: &isDir)
        let folder = isDir.boolValue ? rel : (rel as NSString).deletingLastPathComponent
        if skipDirs.firstMatch(in: folder, range: NSRange(folder.startIndex..., in: folder)) != nil {
            if isDir.boolValue { walk.skipDescendants() }
            continue
        }
        let name = (rel as NSString).lastPathComponent
        if !isDir.boolValue && name.lowercased().hasSuffix(".exe") { found.insert(name) }
    }
    return Array(found.sorted { $0.lowercased() < $1.lowercased() }.prefix(64))
}

@discardableResult
func run(_ tool: String, _ args: [String], env: [String: String], capture: Bool = false) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = args
    process.environment = env
    let pipe = Pipe()
    process.standardOutput = capture ? pipe : FileHandle.nullDevice
    process.standardError = capture ? pipe : FileHandle.nullDevice
    do { try process.run() } catch { return (-1, "\(error)") }
    let output = capture ? String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) : ""
    process.waitUntilExit()
    return (process.terminationStatus, output)
}

final class Bottle {
    let path, wine, winetricks, wineserver, doneFile: String
    var env: [String: String]
    var done = Set<String>()  // key TAB step
    var verbOverrides: [String: [(String, String)]] = [:]

    init(_ path: String, wine: String, winetricks: String) {
        self.path = path
        self.wine = wine
        self.winetricks = winetricks
        wineserver = (wine as NSString).deletingLastPathComponent + "/wineserver"
        // macOS drops DYLD_* when it starts a system binary (sh); the launcher passes the library path for
        // FreeType and GnuTLS as FREEQUAY_LIBRARY_PATH
        env = ProcessInfo.processInfo.environment.merging(["WINEPREFIX": path, "WINEDEBUG": "-all"]) { $1 }
        if let lib = env["FREEQUAY_LIBRARY_PATH"], !lib.isEmpty { env["DYLD_FALLBACK_LIBRARY_PATH"] = lib }
        doneFile = path + "/freequay-fixes.txt"
        for line in ((try? String(contentsOfFile: doneFile, encoding: .utf8)) ?? "").components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 2 else { continue }
            if parts[0].hasPrefix("verb:") {
                verbOverrides[String(parts[0].dropFirst(5))] = parts[1].components(separatedBy: ";").compactMap { o in
                    o.contains("=") ? (o.components(separatedBy: "=")[0], String(o.drop { $0 != "=" }.dropFirst())) : nil
                }
            } else {
                done.insert(line)
            }
        }
    }

    func record(_ fields: String...) {
        let line = fields.joined(separator: "\t") + "\n"
        if let handle = FileHandle(forWritingAtPath: doneFile) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            fm.createFile(atPath: doneFile, contents: Data(line.utf8))
        }
    }

    func reg(_ args: String...) { run(wine, ["reg"] + args, env: env) }

    // the bottle-wide DLL overrides, in the order of the export
    func overrides() -> [(String, String)] {
        let tmp = fm.temporaryDirectory.appendingPathComponent("freequay-fix-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let out = tmp.appendingPathComponent("o.reg").path
        reg("export", "HKCU\\Software\\Wine\\DllOverrides", "Z:" + out.replacingOccurrences(of: "/", with: "\\"), "/y")
        guard let raw = fm.contents(atPath: out) else { return [] }
        let text = raw.starts(with: [0xFF, 0xFE]) || raw.starts(with: [0xFE, 0xFF])
            ? String(data: raw, encoding: .utf16) ?? "" : String(decoding: raw, as: UTF8.self)
        var seen = Set<String>(), result: [(String, String)] = []
        for g in groups(regex(#"^"([^"]+)"="([^"]*)""#, .anchorsMatchLines), text) where seen.insert(g[0]).inserted {
            result.append((g[0], g[1]))
        }
        return result
    }

    func setAppOverrides(_ programs: [String], _ overrides: [(String, String)]) {
        for exe in programs {
            for (dll, value) in overrides {
                reg("add", "HKCU\\Software\\Wine\\AppDefaults\\\(exe)\\DllOverrides", "/v", dll, "/d", value, "/f")
            }
        }
    }

    func verb(_ verb: String, _ programs: [String]) -> Bool {
        if verbOverrides[verb] == nil {
            let before = overrides()
            let cache = (winetricks as NSString).deletingLastPathComponent + "/winetricks-cache"
            print("    winetricks \(verb)")
            let tmp = fm.temporaryDirectory.appendingPathComponent("freequay-fix-\(UUID().uuidString)")
            try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            // winetricks runs under /bin/sh, which loses DYLD_*; a wrapper sets it again for wine
            let wrapper = tmp.appendingPathComponent("wine").path
            let script = "#!/bin/zsh\nexport DYLD_FALLBACK_LIBRARY_PATH=\"\(env["DYLD_FALLBACK_LIBRARY_PATH"] ?? "")\"\nexec \"\(wine)\" \"$@\"\n"
            fm.createFile(atPath: wrapper, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
            // WINE64 too: winetricks cannot tell the architecture of a script and would look for a wine64,
            // which Wine 11 no longer has
            let runEnv = env.merging(["WINE": wrapper, "WINE64": wrapper, "WINESERVER": wineserver, "W_CACHE": cache,
                                      "WINETRICKS_LATEST_VERSION_CHECK": "disabled"]) { $1 }
            let (status, output) = run("/bin/sh", [winetricks, "-q", verb], env: runEnv, capture: true)
            try? fm.removeItem(at: tmp)
            run(wineserver, ["-w"], env: env)
            if status != 0 {
                print("    failed:\n" + output.components(separatedBy: "\n").filter { !$0.isEmpty }.suffix(10).joined(separator: "\n"))
                return false
            }
            let after = overrides(), old = Dictionary(before, uniquingKeysWith: { a, _ in a })
            let new = after.filter { old[$0.0] != $0.1 }
            // back to the bottle-wide state before the verb; the game's programs get the new ones
            for (dll, _) in new {
                if let value = old[dll] {
                    reg("add", "HKCU\\Software\\Wine\\DllOverrides", "/v", dll, "/d", value, "/f")
                } else {
                    reg("delete", "HKCU\\Software\\Wine\\DllOverrides", "/v", dll, "/f")
                }
            }
            verbOverrides[verb] = new
            record("verb:" + verb, new.map { "\($0.0)=\($0.1)" }.joined(separator: ";"))
        }
        setAppOverrides(programs, verbOverrides[verb] ?? [])
        return true
    }
}

let args = CommandLine.arguments
guard args.count >= 5 else {
    FileHandle.standardError.write(Data("usage: fix <bottle> <wine> <winetricks> <rule files> [--list] [key...]\n".utf8))
    exit(2)
}
let (bottlePath, wine, winetricks) = (args[1], args[2], args[3])
let rules = readRules(args[4].components(separatedBy: ":"))
let listOnly = args.dropFirst(5).contains("--list")
var keys = args.dropFirst(5).filter { $0 != "--list" }
let games = steamGames(bottlePath)
if keys.isEmpty { keys = games.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.map { "steam:" + $0 } }
let bottle = Bottle(bottlePath, wine: wine, winetricks: winetricks)

for key in keys {
    guard let r = rules[key], !r.verb.isEmpty || !r.reg.isEmpty || !(r.winver ?? "").isEmpty else { continue }
    let title: String, programs: [String]
    if key.hasPrefix("steam:") {
        let game = games[String(key.dropFirst(6))] ?? ("", "")
        title = game.0
        programs = game.1.isEmpty ? [] : gamePrograms(game.1)
    } else {
        title = String(key.dropFirst(4))
        programs = [title.components(separatedBy: "\\").last ?? title]
    }
    let steps = r.verb.map { ("verb", $0) } + r.reg.map { ("reg", $0) } + ((r.winver ?? "").isEmpty ? [] : [("winver", r.winver!)])
    let todo = steps.filter { !bottle.done.contains(key + "\t" + $0.0 + "=" + $0.1) }
    if todo.isEmpty { continue }
    print("\(key) \(title): " + todo.map { "\($0.0)=\($0.1)" }.joined(separator: ", "))
    if listOnly { continue }
    if programs.isEmpty && todo.contains(where: { $0.0 == "verb" || $0.0 == "winver" }) {
        print("    no programs of the game found, skipped")
        continue
    }
    for (kind, value) in todo {
        var ok = true
        switch kind {
        case "verb":
            ok = bottle.verb(value, programs)
        case "reg":
            let parts = value.components(separatedBy: "|")
            if parts.count == 4 {
                bottle.reg("add", parts[0], "/v", parts[1], "/t", parts[2], "/d", parts[3], "/f")
            } else {
                bottle.reg("add", parts[0], "/f")
            }
        default:
            for exe in programs { bottle.reg("add", "HKCU\\Software\\Wine\\AppDefaults\\\(exe)", "/v", "Version", "/d", value, "/f") }
        }
        if ok { bottle.record(key, "\(kind)=\(value)") }
    }
}
