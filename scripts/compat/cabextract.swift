// Freequay: the part of cabextract that winetricks uses, on the bsdtar of macOS.
//
// winetricks unpacks Microsoft's cabinet files (.cab), and the installers that carry them, with
// cabextract, which is not part of macOS. This program stands in for it: it finds every cabinet in a
// file, also inside an .exe, cuts it out and unpacks it with /usr/bin/bsdtar. libarchive reads
// cabinets too, but in an .exe it looks for them only in the first 128 KB.
//
// Usage, as cabextract: cabextract [-q] [-L] [-d <dir> | --directory=<dir>] [-F <pattern> | --filter=<pattern>]
//                                  [-l | --list] <file>...
//   -L  file names in lower case   -F  only files whose path matches the pattern (shell wildcards, any case)
// scripts/build-app.sh builds it; scripts/freequay puts it on the PATH of winetricks.
import Foundation

struct Options {
    var quiet = false, lower = false, list = false
    var directory = "."
    var filter: String?
    var files: [String] = []
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("cabextract: \(message)\n".utf8))
    exit(1)
}

func parse(_ args: [String]) -> Options {
    var options = Options(), i = 0
    func value(_ name: String) -> String {
        i += 1
        guard i < args.count else { fail("\(name) needs a value") }
        return args[i]
    }
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "-q", "--quiet": options.quiet = true
        case "-L", "--lowercase": options.lower = true
        case "-l", "--list": options.list = true
        case "-d", "--directory": options.directory = value(arg)
        case "-F", "--filter": options.filter = value(arg)
        case _ where arg.hasPrefix("--directory="): options.directory = String(arg.dropFirst("--directory=".count))
        case _ where arg.hasPrefix("--filter="): options.filter = String(arg.dropFirst("--filter=".count))
        case "--": options.files += args[(i + 1)...]; i = args.count
        case _ where arg.hasPrefix("-") && arg.count > 1: fail("option \(arg) is not supported")
        default: options.files.append(arg)
        }
        i += 1
    }
    return options
}

// The cabinets in data: where each starts and how long it is, from a valid header (CFHEADER).
func cabinets(in data: Data) -> [(offset: Int, size: Int)] {
    var found: [(Int, Int)] = []
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.baseAddress, raw.count >= 36 else { return }
        func u32(_ at: Int) -> Int { Int(raw.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian) }
        func u16(_ at: Int) -> Int { Int(raw.loadUnaligned(fromByteOffset: at, as: UInt16.self).littleEndian) }
        var at = 0
        while at + 36 <= raw.count {
            guard let hit = memmem(base + at, raw.count - at, "MSCF", 4) else { break }
            let offset = base.distance(to: UnsafeRawPointer(hit))
            if offset + 36 <= raw.count, u32(offset + 4) == 0, raw[offset + 24] == 3, raw[offset + 25] == 1 {
                let size = u32(offset + 8), files = u32(offset + 16)
                if size >= 36, offset + size <= raw.count, files < size, u16(offset + 28) > 0 {
                    found.append((offset, size))
                    at = offset + size
                    continue
                }
            }
            at = offset + 1
        }
    }
    return found
}

func run(_ tool: String, _ args: [String]) -> (Int32, String) {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = args
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, "\(error)") }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return (process.terminationStatus, output)
}

let options = parse(Array(CommandLine.arguments.dropFirst()))
if options.files.isEmpty { fail("no file given") }
let fm = FileManager.default
let work = fm.temporaryDirectory.appendingPathComponent("freequay-cab-\(UUID().uuidString)")
defer { try? fm.removeItem(at: work) }
var errors = 0

for file in options.files {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: file), options: .alwaysMapped) else {
        FileHandle.standardError.write(Data("cabextract: cannot read \(file)\n".utf8))
        errors += 1
        continue
    }
    let found = cabinets(in: data)
    if found.isEmpty {
        FileHandle.standardError.write(Data("cabextract: \(file): no valid cabinets found\n".utf8))
        errors += 1
        continue
    }
    if !options.quiet && !options.list { print("Extracting cabinet: \(file)") }
    for (index, cab) in found.enumerated() {
        let part = work.appendingPathComponent("\(index)")
        let cabFile = work.appendingPathComponent("\(index).cab")
        try? fm.createDirectory(at: part, withIntermediateDirectories: true)
        do {
            try data.subdata(in: cab.offset..<cab.offset + cab.size).write(to: cabFile)
        } catch {
            fail("cannot write \(cabFile.path): \(error.localizedDescription)")
        }
        let (status, output) = run("/usr/bin/bsdtar", ["-x", "-f", cabFile.path, "-C", part.path])
        if status != 0 {
            FileHandle.standardError.write(Data("cabextract: \(file): \(output)".utf8))
            errors += 1
        }
        // the files of this cabinet, by their path in it
        let names = (fm.enumerator(atPath: part.path)?.allObjects as? [String] ?? []).filter { name in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: part.appendingPathComponent(name).path, isDirectory: &isDir) && !isDir.boolValue
        }.sorted()
        for name in names {
            if let filter = options.filter, fnmatch(filter, name, FNM_CASEFOLD) != 0 { continue }
            let target = options.lower ? name.lowercased() : name
            if options.list { print(target); continue }
            let destination = URL(fileURLWithPath: options.directory).appendingPathComponent(target)
            do {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: part.appendingPathComponent(name), to: destination)
                if !options.quiet { print("  extracting \(destination.path)") }
            } catch {
                FileHandle.standardError.write(Data("cabextract: \(destination.path): \(error.localizedDescription)\n".utf8))
                errors += 1
            }
        }
    }
}
if !options.quiet && !options.list { print(errors == 0 ? "\nAll done, no errors." : "\nThere were \(errors) errors.") }
exit(errors == 0 ? 0 : 1)
