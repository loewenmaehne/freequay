// Freequay: makes the rules from AppleGamingWiki on the Mac where they are used.
//
// AppleGamingWiki (applegamingwiki.com) rates every game for CrossOver, Wine and Parallels on
// Apple Silicon and collects free-text reports. Its content is under CC BY-NC-SA 3.0, which allows
// no commercial use, so Freequay does not ship rules taken from it: `freequay applegamingwiki` runs
// this program, which downloads the pages and writes the rules into
// ~/Library/Application Support/freequay/compat.
//
// The tips are written by people, so this is careful: a graphics backend becomes a rule only when
// the reports for a game that runs recommend exactly one backend and none of them reports problems
// with it; environment variables only from sections about CrossOver or Wine. Ratings and the first
// lines of the notes go to notes.tsv for freequay info, and so do launch options found in the text,
// which turned out to be too often installer flags or tips for the native Mac version.
//
// Usage: applegamingwiki fetch <cache dir>     the wikitext of all pages with a macOS compatibility
//                                               table, 50 pages per request, one request per second
//        applegamingwiki rules <cache dir> <out dir>   applegamingwiki.txt, notes.tsv, titles.tsv
//
// Until Freequay 0.2.1 this was scripts/compat/applegamingwiki.py, and the patterns below are its
// patterns. They follow Python's re: its whitespace, word characters and word boundaries, and
// positions counted in Unicode scalars, as Python counts characters. scripts/build-app.sh builds it.
import Foundation

let api = "https://www.applegamingwiki.com/w/api.php"
let agent = "Freequay (+https://github.com/loewenmaehne/freequay; non-commercial; one request per second)"

// MARK: Python's re on NSRegularExpression

// whitespace as in Python (str.isspace); ICU's \s lacks \v, \x1c to \x1f and \x85
let white = #"\t\n\x{0B}\f\r\x{1C}-\x{1F} \x{85}\x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}"#
let ws = "[\(white)]", nonWs = "[^\(white)]"
// Python's \w and \b; ICU counts marks and connector punctuation as word characters as well
let word = #"[\p{L}\p{N}_]"#
let edge = "(?:(?<=\(word))(?!\(word))|(?<!\(word))(?=\(word)))"

struct Rx {
    let rx: NSRegularExpression

    // only \n ends a line, as in Python
    init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        rx = try! NSRegularExpression(pattern: pattern, options: options.union(.useUnixLineSeparators))
    }

    func all(_ text: String) -> [Match] {
        rx.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { Match(result: $0, text: text) }
    }

    func search(_ text: String) -> Match? {
        rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)).map { Match(result: $0, text: text) }
    }

    // re.findall: the whole match, the group, or all groups joined, as ''.join() on its tuples
    func findall(_ text: String) -> [String] {
        all(text).map { m in
            m.result.numberOfRanges == 1 ? m.group(0) : (1..<m.result.numberOfRanges).map { m.group($0) }.joined()
        }
    }

    func sub(_ text: String, _ replacement: (Match) -> String) -> String {
        var out = "", last = text.startIndex
        for m in all(text) {
            let range = Range(m.result.range, in: text)!
            out += text[last..<range.lowerBound] + replacement(m)
            last = range.upperBound
        }
        return out + text[last...]
    }

    // re.split: the pieces between the matches and, if the pattern has a group, the groups
    func split(_ text: String) -> [String] {
        var out: [String] = [], last = text.startIndex
        for m in all(text) {
            let range = Range(m.result.range, in: text)!
            out.append(String(text[last..<range.lowerBound]))
            out += (1..<m.result.numberOfRanges).map { m.group($0) }
            last = range.upperBound
        }
        return out + [String(text[last...])]
    }
}

struct Match {
    let result: NSTextCheckingResult
    let text: String

    // a group that did not take part is empty, as in findall and sub
    func group(_ i: Int) -> String {
        guard let range = Range(result.range(at: i), in: text) else { return "" }
        return String(text[range])
    }

    var start: Int { scalarOffset(text, result.range.location) }
    var end: Int { scalarOffset(text, result.range.location + result.range.length) }
}

func scalarOffset(_ text: String, _ utf16: Int) -> Int {
    text.unicodeScalars.distance(from: text.startIndex, to: String.Index(utf16Offset: utf16, in: text))
}

// text[from:to] in Python
func slice(_ text: String, _ from: Int, _ to: Int) -> String {
    let scalars = text.unicodeScalars, count = scalars.count
    let lower = min(max(from, 0), count), upper = min(max(to, 0), count)
    guard lower < upper else { return "" }
    let start = scalars.index(scalars.startIndex, offsetBy: lower)
    return String(scalars[start..<scalars.index(start, offsetBy: upper - lower)])
}

func isWhite(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
    default: return false
    }
}

// str.strip() and str.split() without arguments
func strip(_ text: String) -> String {
    let scalars = text.unicodeScalars
    guard let first = scalars.firstIndex(where: { !isWhite($0) }),
          let last = scalars.lastIndex(where: { !isWhite($0) }) else { return "" }
    return String(scalars[first...last])
}

func words(_ text: String) -> [String] {
    var out: [String] = [], current = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
        if isWhite(scalar) {
            if !current.isEmpty { out.append(String(current)); current = String.UnicodeScalarView() }
        } else {
            current.append(scalar)
        }
    }
    if !current.isEmpty { out.append(String(current)) }
    return out
}

// int() of a string of decimal digits, also other scripts' digits as Python takes them
func number(_ text: String) -> Int? {
    guard !text.isEmpty else { return nil }
    var value = 0
    for scalar in text.unicodeScalars {
        guard scalar.properties.numericType == .decimal, let digit = scalar.properties.numericValue else { return nil }
        value = value &* 10 &+ Int(digit)
    }
    return value
}

// where needle starts in text, counted in Unicode scalars
func scalarIndex(of needle: String, in text: String) -> Int? {
    let hay = Array(text.unicodeScalars), find = Array(needle.unicodeScalars)
    guard hay.count >= find.count else { return nil }
    return (0...(hay.count - find.count)).first { hay[$0..<$0 + find.count].elementsEqual(find) }
}

// Python compares strings by their code points; Swift's == also takes canonically equivalent ones as equal
struct Exact: Hashable {
    let scalars: [Unicode.Scalar]
    init(_ text: String) { scalars = Array(text.unicodeScalars) }
}

func less(_ a: String, _ b: String) -> Bool { a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) }

func contains(_ text: String, _ part: String) -> Bool { scalarIndex(of: part, in: text) != nil }

// the text up to the first newline, as text.split('\n')[0]
func firstLine(_ text: String) -> String { String(text.unicodeScalars.prefix { $0 != "\n" }) }

// a list without repeats, in the order of first appearance (dict.fromkeys)
func unique(_ items: [String]) -> [String] {
    var seen = Set<Exact>()
    return items.filter { seen.insert(Exact($0)).inserted }
}

// MARK: rules of one source, collected per key (scripts/compat/common.py)

let spaces = Rx("\(ws)+")

func clean(_ text: String) -> String { strip(spaces.sub(text) { _ in " " }) }

final class Rules {
    private(set) var rules: [(key: String, directives: [String])] = []
    private(set) var notes: [(key: String, texts: [String])] = []
    private(set) var titles: [(id: String, title: String)] = []
    private var ruleIndex: [Exact: Int] = [:], noteIndex: [Exact: Int] = [:], titleIds = Set<Exact>()

    func add(_ key: String, _ directive: String) {
        guard !directive.unicodeScalars.contains(where: { $0 == "\t" || $0 == "\n" }) else { return }
        if ruleIndex[Exact(key)] == nil { ruleIndex[Exact(key)] = rules.count; rules.append((key, [])) }
        let i = ruleIndex[Exact(key)]!
        if !rules[i].directives.contains(where: { Exact($0) == Exact(directive) }) { rules[i].directives.append(directive) }
    }

    func note(_ key: String, _ text: String) {
        let text = clean(text)
        if noteIndex[Exact(key)] == nil { noteIndex[Exact(key)] = notes.count; notes.append((key, [])) }
        let i = noteIndex[Exact(key)]!
        if !text.isEmpty && !notes[i].texts.contains(where: { Exact($0) == Exact(text) }) { notes[i].texts.append(text) }
    }

    func title(_ id: String, _ title: String) {
        let title = clean(title)
        if !title.isEmpty && titleIds.insert(Exact(id)).inserted { titles.append((id, title)) }
    }
}

// Rule keys in a stable order: kind, the number of a Steam app ID, the rest in lower case
// (key.partition(':') in common.py). notes.tsv sorts on kind, number and the whole key.
func ruleOrder(_ a: String, _ b: String) -> Bool {
    func parts(_ key: String) -> (String, Int, String) {
        guard let colon = key.unicodeScalars.firstIndex(of: ":") else { return (key, 0, "") }
        let ident = String(key.unicodeScalars[key.unicodeScalars.index(after: colon)...])
        return (String(key.unicodeScalars[..<colon]), number(ident) ?? 0, ident.lowercased())
    }
    let x = parts(a), y = parts(b)
    if Exact(x.0) != Exact(y.0) { return less(x.0, y.0) }
    if x.1 != y.1 { return x.1 < y.1 }
    return less(x.2, y.2)
}

func noteOrder(_ a: String, _ b: String) -> Bool {
    func parts(_ key: String) -> (String, Int) {
        let fields = key.unicodeScalars.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        return (fields[0], fields.count > 1 ? number(fields[1]) ?? 0 : 0)
    }
    let x = parts(a), y = parts(b)
    if Exact(x.0) != Exact(y.0) { return less(x.0, y.0) }
    if x.1 != y.1 { return x.1 < y.1 }
    return less(a, b)
}

// a sort that keeps the order of equal elements, as Python's
func stableSorted<T>(_ items: [T], by less: (T, T) -> Bool) -> [T] {
    items.enumerated().sorted { less($0.element, $1.element) || (!less($1.element, $0.element) && $0.offset < $1.offset) }
        .map(\.element)
}

// MARK: AppleGamingWiki's pages

let backendPatterns: [(Rx, String)] = [
    (Rx("\(edge)(d3d ?metal|gptk|game porting toolkit)\(edge)", .caseInsensitive), "d3dmetal"),
    (Rx("\(edge)dxmt\(edge)", .caseInsensitive), "dxmt"),
    (Rx("\(edge)(dxvk|moltenvk)\(edge)", .caseInsensitive), "dxvk"),
    (Rx("\(edge)wine ?d3d\(edge)", .caseInsensitive), "wined3d"),
]
let negative = Rx(#"crash|black screen|n[o']t (work|run|launch|start|load)|does ?n[o']t|doesn|did ?n[o']t|"#
                  + #"won'?t|can'?t|cannot|unable|broken|issue|glitch|artifact|fail|problem|freez|missing|"#
                  + #"invisible|flicker|corrupt|bug|error|unplayable|black|white screen|hang"#, .caseInsensitive)
let better = Rx("\(edge)(better|faster|smoother|more stable|best)\(edge)", .caseInsensitive)
let goodRatings: Set<Exact> = [Exact("perfect"), Exact("playable"), Exact("runs")]
// launch options that only change looks or window mode, or that belong to the native Mac version
let preferenceArgs = Rx(#"^-(windowed|window|noborder|borderless|fullscreen|full|w|h|width|height|refresh|freq|"#
                        + #"fps|high|console|dev|novsync|vsync|popupwindow|screen-.*|monitor)$"#, .caseInsensitive)
let keepEnv = Rx(#"^(ROSETTA_ADVERTISE_AVX|D3DM_[A-Z0-9_]+|DXMT_[A-Z0-9_]+|MVK_[A-Z0-9_]+)$"#)

let markup: [(Rx, (Match) -> String)] = [
    (Rx(#"<ref[^>]*/>"#), { _ in " " }),
    (Rx(#"<ref[^>]*>.*?</ref>"#, .dotMatchesLineSeparators), { _ in " " }),
    (Rx(#"\{\{code\|([^}]*)\}\}"#), { $0.group(1) }),
    (Rx(#"\[\[(?:[^|\]]*\|)?([^\]]*)\]\]"#), { $0.group(1) }),
    (Rx(#"\[https?://"# + nonWs + "+" + ws + #"*([^\]]*)\]"#), { $0.group(1) }),
    (Rx(#"'{2,}"#), { _ in "" }),
    (Rx("<br" + ws + "*/?>"), { _ in ". " }),
    (Rx(#"<[^>]+>"#), { _ in " " }),
]

func stripMarkup(_ text: String) -> String {
    clean(markup.reduce(text) { text, step in step.0.sub(text, step.1) })
}

let refdevice = Rx(#"\{\{Refdevice(.*?)\}\}"#, .dotMatchesLineSeparators)
let refdeviceField = Rx(#"\|"# + ws + "*(?:method|settings|comment)" + ws + #"*=([^|]*)"#)

// method, settings and comment of the {{Refdevice}} reports
func refdeviceFields(_ text: String) -> [String] {
    refdevice.all(text).flatMap { m in
        refdeviceField.findall(m.group(1)).filter { !strip($0).isEmpty }.map(stripMarkup)
    }
}

let sentenceBreak = Rx("(?<=[.!?;])" + ws + #"+|\n+"#)
let clauseBreak = Rx("," + ws + "*(?=with|but|while|whereas|although|though|on|using|via)" + edge, .caseInsensitive)

func clauses(_ text: String) -> [String] {
    sentenceBreak.split(text).flatMap { clauseBreak.split($0) }.filter { !strip($0).isEmpty }
}

func scoreBackends(_ texts: [String]) -> (score: [(backend: String, score: Int)], negative: Set<String>) {
    var score: [(backend: String, score: Int)] = [], negativeSet = Set<String>()
    func bump(_ backend: String, _ by: Int) {
        if let i = score.firstIndex(where: { $0.backend == backend }) { score[i].score += by } else { score.append((backend, by)) }
    }
    for text in texts {
        for clause in clauses(text) {
            let found = backendPatterns.compactMap { rx, backend in rx.search(clause).map { ($0.start, backend) } }
            if found.isEmpty { continue }
            // a position in the lower-case clause against positions in the clause, as in the Python version
            if better.search(clause) != nil, let than = scalarIndex(of: " than ", in: clause.lowercased()) {
                for (pos, backend) in found {
                    bump(backend, pos < than ? 2 : -1)
                    if pos > than { negativeSet.insert(backend) }
                }
                continue
            }
            let bad = negative.search(clause) != nil
            for (_, backend) in found {
                if bad { negativeSet.insert(backend) }
                bump(backend, bad ? -1 : 1)
            }
        }
    }
    return (score, negativeSet)
}

// a parameter of a template: | name = value, up to the next parameter
let params = Dictionary(uniqueKeysWithValues: ["steam appid", "steam appid side", "crossover", "crossover notes",
                                               "wine notes"].map {
    ($0, Rx(#"\|"# + ws + "*" + NSRegularExpression.escapedPattern(for: $0) + ws + "*=(.*?)(?=\\n" + ws
            + #"*\|[a-z0-9 ./\-]+=|\z)"#, [.dotMatchesLineSeparators, .caseInsensitive]))
})

func param(_ block: String, _ name: String) -> String {
    params[name]!.search(block).map { strip($0.group(1)) } ?? ""
}

let heading = Rx("^(==+[^=\\n]+==+)" + ws + "*$", .anchorsMatchLines)
let otherPlatform = Rx("macos|native|parallels|rosetta|windows|linux", .caseInsensitive)
let wineHead = Rx("crossover|wine|whisky", .caseInsensitive)
let layerHead = Rx("crossover|wine|whisky|game porting|gptk|compatibility layer", .caseInsensitive)
let fixedHead = Rx("issues? (fixed|resolved)", .caseInsensitive)
let wineBody = Rx("crossover|wine\(edge)|whisky", .caseInsensitive)

// text of sections about CrossOver, Wine or the compatibility layer
func wineSections(_ text: String) -> [String] {
    let parts = heading.split(text)
    var out: [String] = []
    for i in stride(from: 1, to: parts.count - 1, by: 2) {
        let head = parts[i], body = parts[i + 1]
        if otherPlatform.search(head) != nil && wineHead.search(head) == nil { continue }
        if layerHead.search(head) != nil {
            out.append(body)
        } else if fixedHead.search(head) != nil && wineBody.search(body) != nil {
            out.append(body)
        }
    }
    return out
}

let launchFix = Rx("launch (option|argument|parameter)|command line", .caseInsensitive)
let codeBlock = Rx(#"<code>(.*?)</code>|\{\{code\|([^}]*)\}\}|<pre>(.*?)</pre>"#, .dotMatchesLineSeparators)
let envToken = Rx(#"\A[A-Z][A-Z0-9_]+="# + nonWs + #"+\z"#)
let optionUnit = Rx(#"[\-+][A-Za-z][\p{L}\p{N}_.\-]*(?:"# + ws + #"+(?![\-+])[^"# + white + #"\-]"# + nonWs + "*)?")
let fileArg = Rx(#"\.(cfg|ini|txt|lua|json)$"#, .caseInsensitive)
let envInText = Rx(edge + #"((?:ROSETTA_ADVERTISE_AVX|MVK_[A-Z0-9_]+)="# + word + "+)")

func launchOptions(_ texts: [String]) -> (args: [String], env: [String]) {
    var args: [String] = [], env: [String] = []
    for text in texts {
        for fix in launchFix.all(text) {
            let window = slice(text, fix.start - 400, fix.end + 400)
            for raw in codeBlock.findall(window) {
                let code = clean(raw), lower = code.lowercased()
                if contains(lower, "%command%") || contains(lower, ".exe") || contains(code, "\\") || contains(code, "/") { continue }
                for token in words(code) where envToken.search(token) != nil {
                    if keepEnv.search(String(token.unicodeScalars.prefix { $0 != "=" })) != nil { env.append(token) }
                }
                // a launch option string: switches with their values, nothing that only changes the looks
                let units = optionUnit.findall(code)
                if !units.isEmpty && Exact(units.joined(separator: " ")) == Exact(words(code).joined(separator: " ")) {
                    for unit in units where preferenceArgs.search(words(unit)[0]) == nil && fileArg.search(unit) == nil {
                        args.append(unit)
                    }
                }
            }
        }
        env += envInText.findall(text)
    }
    return (unique(args), unique(env))
}

let steamDigits = Rx(#"\d+"#)
let compatibilityTable = Rx(#"\{\{Compatibility/macOS(.*?)\n\}\}"#, .dotMatchesLineSeparators)

func makeRules(cache: String, out: String) throws {
    let files = try FileManager.default.contentsOfDirectory(atPath: cache)
        .filter { $0.hasPrefix("pages-") && $0.hasSuffix(".json") }
        .sorted(by: less)
    var pages: [[String: Any]] = []
    for file in files {
        let data = try Data(contentsOf: URL(fileURLWithPath: cache).appendingPathComponent(file))
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Failure("\(file) is not a list of pages")
        }
        pages += list
    }
    guard !pages.isEmpty else { throw Failure("no pages in \(cache)") }
    let stored = (try? String(contentsOfFile: cache + "/version", encoding: .utf8)).map(strip) ?? ""
    let version = stored.isEmpty ? today() : stored

    let rules = Rules()
    var backends: [(key: String, found: Set<String>)] = []  // backend names are ASCII
    var stats = (pages: 0, steam: 0, backend: 0, args: 0, env: 0)
    for page in pages {
        guard let revisions = page["revisions"] as? [[String: Any]], let revision = revisions.first,
              let text = ((revision["slots"] as? [String: Any])?["main"] as? [String: Any])?["content"] as? String
        else { continue }
        stats.pages += 1
        var ids = steamDigits.findall(firstLine(param(text, "steam appid")))
        // other editions; many pages carry a placeholder 10 there
        ids += steamDigits.findall(firstLine(param(text, "steam appid side"))).filter { (number($0) ?? 0) >= 1000 }
        ids = unique(ids)
        if ids.isEmpty { continue }
        stats.steam += 1
        let keys = ids.map { "steam:" + $0 }
        rules.title(ids[0], page["title"] as? String ?? "")
        let block = compatibilityTable.search(text)?.group(1) ?? ""
        let rating = String(String.UnicodeScalarView(
            param(block, "crossover").lowercased().unicodeScalars.map { $0 == "\u{2019}" ? "'" : $0 }))
        let notes = param(block, "crossover notes")
        let wineNotes = param(block, "wine notes")
        let sections = wineSections(text)
        let reports = [stripMarkup(notes), stripMarkup(wineNotes)] + refdeviceFields(notes) + refdeviceFields(wineNotes)
            + sections.map(stripMarkup)
        let summary = slice(stripMarkup(notes), 0, 220)
        for key in keys where !rating.isEmpty && Exact(rating) != Exact("na") && Exact(rating) != Exact("unknown") {
            rules.note(key, "AppleGamingWiki: CrossOver \(rating)" + (summary.isEmpty ? "" : " \u{2013} \(summary)"))
        }
        if goodRatings.contains(Exact(rating)) {
            let (score, negativeSet) = scoreBackends(reports)
            let ranked = stableSorted(score) { $0.score > $1.score }
            if let top = ranked.first, top.score >= 1, !negativeSet.contains(top.backend),
               ranked.count == 1 || ranked[1].score < top.score {
                stats.backend += 1
                for key in keys {
                    if let i = backends.firstIndex(where: { Exact($0.key) == Exact(key) }) { backends[i].found.insert(top.backend) }
                    else { backends.append((key, [top.backend])) }
                }
            } else if !score.isEmpty {
                let list = ranked.map { "\($0.backend) \($0.score >= 0 ? "+" : "")\($0.score)" }.joined(separator: ", ")
                for key in keys { rules.note(key, "AppleGamingWiki mentions backends without a clear recommendation: " + list) }
            }
        }
        let (args, env) = launchOptions(sections + [notes, wineNotes])
        if !args.isEmpty {
            // found near "launch option" in free text; often installer flags or old tips, so only a note
            stats.args += 1
            for key in keys { rules.note(key, "AppleGamingWiki mentions launch options: " + args.joined(separator: " ")) }
        }
        for value in env {
            stats.env += 1
            for key in keys { rules.add(key, "env=" + value) }
        }
    }
    for (key, found) in backends {
        if found.count == 1 {
            rules.add(key, "backend=" + found.first!)
        } else {
            let list = found.sorted(by: less).joined(separator: ", ")
            rules.note(key, "AppleGamingWiki: pages recommend different backends: " + list)
        }
    }

    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    var notesFile = "# Notes from AppleGamingWiki on the rules in applegamingwiki.txt next to it: key, source, text, for\n"
        + "# freequay info. License CC BY-NC-SA 3.0, as that file says. Made by freequay applegamingwiki.\n"
    let noteRows = rules.notes.flatMap { note in note.texts.map { (key: note.key, text: $0) } }
    for row in stableSorted(noteRows, by: { noteOrder($0.key, $1.key) }) {
        notesFile += row.key + "\tapplegamingwiki\t" + clean(row.text) + "\n"
    }
    var titlesFile = "# Steam app ID and title from AppleGamingWiki, for freequay info. License CC BY-NC-SA 3.0.\n"
    for title in stableSorted(rules.titles, by: { (number($0.id) ?? 0) < (number($1.id) ?? 0) }) {
        titlesFile += title.id + "\t" + title.title + "\n"
    }
    var rulesFile = [
        "Freequay: rules from AppleGamingWiki (applegamingwiki.com), pages with a macOS compatibility table,",
        "as of \(version), made on this Mac. License CC BY-NC-SA 3.0 (creativecommons.org/licenses/by-nc-sa/3.0/):",
        "attribution, non-commercial, share alike; notes.tsv and titles.tsv next to it are under the same license.",
        "A backend only when the reports for a game that runs recommend exactly one and none reports problems with it;",
        "variables only from sections about CrossOver and Wine. Made by freequay applegamingwiki, do not edit by hand.",
    ].map { "# " + $0 + "\n" }.joined()
    for rule in stableSorted(rules.rules, by: { ruleOrder($0.key, $1.key) }) where !rule.directives.isEmpty {
        rulesFile += rule.key + "\t" + rule.directives.joined(separator: "\t") + "\n"
    }
    // ntdll reads the rules at every program start, so each file is replaced in one step
    try write(out + "/notes.tsv", notesFile)
    try write(out + "/titles.tsv", titlesFile)
    try write(out + "/applegamingwiki.txt", rulesFile)
    print("\(out)/applegamingwiki.txt: \(stats.pages) pages, \(stats.steam) with a Steam ID; rules: \(stats.backend) backend, "
          + "\(stats.args) launch options, \(stats.env) variables")
}

func write(_ path: String, _ text: String) throws {
    try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
}

func today() -> String {
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.dateFormat = "yyyy-MM-dd"
    return format.string(from: Date())
}

// MARK: download

struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}

// no network, or a firewall that does not let the program out: then there is no point in trying again soon
func unreachable(_ error: Error) -> Bool {
    let error = error as NSError
    let offline: [URLError.Code] = [.notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff,
                                    .dataNotAllowed]
    return error.domain == NSURLErrorDomain && offline.contains(URLError.Code(rawValue: error.code))
        || error.domain == NSPOSIXErrorDomain && [EPERM, EACCES].contains(Int32(error.code))
}

// one request to the MediaWiki API, then a second's pause; up to four tries on other errors
func get(_ params: [(String, String)]) async throws -> [String: Any] {
    let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    let query = (params + [("format", "json"), ("formatversion", "2")])
        .map { $0.0 + "=" + $0.1.addingPercentEncoding(withAllowedCharacters: unreserved)! }.joined(separator: "&")
    var request = URLRequest(url: URL(string: api + "?" + query)!, timeoutInterval: 30)
    request.setValue(agent, forHTTPHeaderField: "User-Agent")
    var pause: UInt64 = 5
    for attempt in 1...4 {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw Failure("HTTP status \(status)") }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure("no JSON object") }
            if let error = json["error"] as? [String: Any] { throw Failure("API error \(error["code"] ?? "")") }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return json
        } catch where unreachable(error) {
            throw Failure("AppleGamingWiki is not reachable: \(error.localizedDescription)")
        } catch {
            if attempt == 4 { throw Failure("AppleGamingWiki did not answer: \(error.localizedDescription)") }
            FileHandle.standardError.write(Data("  retry \(attempt): \(error.localizedDescription)\n".utf8))
            try await Task.sleep(nanoseconds: pause * 1_000_000_000)
            pause *= 2
        }
    }
    throw Failure("unreachable")
}

func fetch(cache: String) async throws {
    let fm = FileManager.default
    try fm.createDirectory(atPath: cache, withIntermediateDirectories: true)
    for file in try fm.contentsOfDirectory(atPath: cache) where file.hasPrefix("pages-") {
        try fm.removeItem(atPath: cache + "/" + file)
    }
    var titles: [String] = [], next: (String, String)?
    repeat {
        let data = try await get([("action", "query"), ("list", "embeddedin"), ("eititle", "Template:Compatibility/macOS"),
                                  ("einamespace", "0"), ("eilimit", "500")] + (next.map { [$0] } ?? []))
        let embedded = (data["query"] as? [String: Any])?["embeddedin"] as? [[String: Any]] ?? []
        titles += embedded.compactMap { $0["title"] as? String }
        next = ((data["continue"] as? [String: Any])?["eicontinue"] as? String).map { ("eicontinue", $0) }
    } while next != nil
    guard !titles.isEmpty else { throw Failure("AppleGamingWiki lists no pages with a macOS compatibility table") }
    print("\(titles.count) pages")
    try JSONSerialization.data(withJSONObject: titles).write(to: URL(fileURLWithPath: cache + "/titles.json"))
    for start in stride(from: 0, to: titles.count, by: 50) {
        let batch = titles[start..<min(start + 50, titles.count)]
        let data = try await get([("action", "query"), ("prop", "revisions"), ("rvprop", "content|timestamp"),
                                  ("rvslots", "main"), ("titles", batch.joined(separator: "|"))])
        guard let pages = (data["query"] as? [String: Any])?["pages"] as? [Any] else { throw Failure("answer without pages") }
        try JSONSerialization.data(withJSONObject: pages)
            .write(to: URL(fileURLWithPath: cache + String(format: "/pages-%03d.json", start / 50)))
        print("\(min(start + 50, titles.count))/\(titles.count)")
    }
    try write(cache + "/version", today() + "\n")
}

@main
enum AppleGamingWiki {
    static func main() async {
        let args = CommandLine.arguments
        do {
            switch (args.count, args.count > 1 ? args[1] : "") {
            case (3, "fetch"): try await fetch(cache: args[2])
            case (4, "rules"): try makeRules(cache: args[2], out: args[3])
            default:
                FileHandle.standardError.write(Data("usage: applegamingwiki fetch <cache dir> | rules <cache dir> <out dir>\n".utf8))
                exit(2)
            }
        } catch {
            FileHandle.standardError.write(Data("applegamingwiki: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
