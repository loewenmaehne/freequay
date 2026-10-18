// Freequay: makes the rules from AppleGamingWiki on the Mac where they are used.
//
// AppleGamingWiki (applegamingwiki.com) rates every game for CrossOver, Wine and Parallels on
// Apple Silicon and collects free-text reports. Its content is under CC BY-NC-SA 3.0, which allows
// no commercial use, so Freequay does not ship rules taken from it. Instead this program looks up
// the Steam games installed on the Mac, one at a time and each at most once a week, and writes the
// rules into ~/Library/Application Support/freequay/compat; scripts/freequay runs it when needed.
// A page's infobox links to steamdb.info/app/<Steam app ID>/, so AppleGamingWiki's list of pages
// with that link names the pages of a game. They give the same rules as reading all pages did up to
// Freequay 0.2.1, except for Steam IDs a page lists only as further editions, mostly DLC, with which
// no game starts.
//
// The tips are written by people, so this is careful: a graphics backend becomes a rule only when
// the reports for a game that runs recommend exactly one backend and none of them reports problems
// with it; environment variables only from sections about CrossOver or Wine. Ratings and the first
// lines of the notes go to notes.tsv for freequay info, and so do launch options found in the text,
// which turned out to be too often installer flags or tips for the native Mac version.
//
// Usage: applegamingwiki lookup [--quick] <dir> <Steam app ID>...
//            looks up these games, each at most once a week and with one request per second, and
//            writes applegamingwiki.txt, notes.tsv and titles.tsv into <dir>; <dir>/applegamingwiki
//            keeps the pages (pages/<page ID>.json) and which game has which pages (games.tsv).
//            --quick: one try with a short timeout, for a game about to start.
//        applegamingwiki rules <dir>
//            writes the three files again from the pages kept, for instance after an update
// Exit codes: 3 no network, 4 another lookup is running, 1 other errors.
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

// The rules for the games in keep, from their pages in the order of their page IDs, as AppleGamingWiki
// lists them; version names the date of the newest lookup.
func makeRules(pages: [[String: Any]], keep: Set<Exact>, version: String, out: String) throws {
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

    let kept = { (key: String) in keep.contains(Exact(String(key.unicodeScalars.drop { $0 != ":" }.dropFirst()))) }
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    var notesFile = "# Notes from AppleGamingWiki on the rules in applegamingwiki.txt next to it: key, source, text, for\n"
        + "# freequay info. License CC BY-NC-SA 3.0, as that file says. Made by freequay applegamingwiki.\n"
    let noteRows = rules.notes.filter { kept($0.key) }.flatMap { note in note.texts.map { (key: note.key, text: $0) } }
    for row in stableSorted(noteRows, by: { noteOrder($0.key, $1.key) }) {
        notesFile += row.key + "\tapplegamingwiki\t" + clean(row.text) + "\n"
    }
    var titlesFile = "# Steam app ID and title from AppleGamingWiki, for freequay info. License CC BY-NC-SA 3.0.\n"
    for title in stableSorted(rules.titles.filter { keep.contains(Exact($0.id)) }, by: { (number($0.id) ?? 0) < (number($1.id) ?? 0) }) {
        titlesFile += title.id + "\t" + title.title + "\n"
    }
    var rulesFile = [
        "Freequay: rules from AppleGamingWiki (applegamingwiki.com) for the Steam games on this Mac, from their pages",
        "with a macOS compatibility table as of \(version). License CC BY-NC-SA 3.0 (creativecommons.org/licenses/by-nc-sa/3.0/):",
        "attribution, non-commercial, share alike; notes.tsv and titles.tsv next to it are under the same license.",
        "A backend only when the reports for a game that runs recommend exactly one and none reports problems with it;",
        "variables only from sections about CrossOver and Wine. Made by freequay applegamingwiki, do not edit by hand.",
    ].map { "# " + $0 + "\n" }.joined()
    for rule in stableSorted(rules.rules, by: { ruleOrder($0.key, $1.key) }) where !rule.directives.isEmpty && kept(rule.key) {
        rulesFile += rule.key + "\t" + rule.directives.joined(separator: "\t") + "\n"
    }
    // ntdll reads the rules at every program start, so each file is replaced in one step
    try write(out + "/notes.tsv", notesFile)
    try write(out + "/titles.tsv", titlesFile)
    try write(out + "/applegamingwiki.txt", rulesFile)
    print("\(out)/applegamingwiki.txt: \(keep.count) games, \(stats.pages) pages; rules: \(stats.backend) backend, "
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

// MARK: the games looked up

typealias Game = (id: String, date: String, pages: [Int])

// games.tsv: Steam app ID, date of the lookup, page IDs or - for none
func readGames(_ cache: String) -> [Game] {
    guard let text = try? String(contentsOfFile: cache + "/games.tsv", encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line in
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 3, !f[0].hasPrefix("#") else { return nil }
        return (f[0], f[1], f[2] == "-" ? [] : f[2].split(separator: ",").compactMap { Int($0) })
    }
}

func writeGames(_ cache: String, _ games: [Game]) throws {
    var text = "# Steam app ID, date of the lookup, AppleGamingWiki page IDs (- for none). Made by freequay applegamingwiki.\n"
    for game in games.sorted(by: { (number($0.id) ?? 0) < (number($1.id) ?? 0) }) {
        text += game.id + "\t" + game.date + "\t" + (game.pages.isEmpty ? "-" : game.pages.map(String.init).joined(separator: ",")) + "\n"
    }
    try write(cache + "/games.tsv", text)
}

func days(since date: String) -> Int {
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.dateFormat = "yyyy-MM-dd"
    guard let then = format.date(from: date) else { return .max }
    return Calendar.current.dateComponents([.day], from: then, to: Date()).day ?? .max
}

// One lookup or rewrite at a time: waits up to 5 s (quick) or 20 s for the lock, which ends with the process.
func lock(_ cache: String, quick: Bool) async throws {
    try FileManager.default.createDirectory(atPath: cache + "/pages", withIntermediateDirectories: true)
    let fd = open(cache + "/.lock", O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { throw Failure("cannot open \(cache)/.lock") }
    for _ in 0..<(quick ? 10 : 40) {
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return }
        try await Task.sleep(nanoseconds: 500_000_000)
    }
    throw Failure("another lookup is running", code: 4)
}

// the rules from all pages kept, for the games looked up
func writeRules(dir: String) throws {
    let cache = dir + "/applegamingwiki"
    let games = readGames(cache)
    let pages = Set(games.flatMap(\.pages)).sorted().compactMap { id -> [String: Any]? in
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: cache + "/pages/\(id).json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    try makeRules(pages: pages, keep: Set(games.map { Exact($0.id) }), version: games.map(\.date).max() ?? today(), out: dir)
}

// MARK: download

struct Failure: LocalizedError {
    let errorDescription: String?
    let code: Int32
    init(_ description: String, code: Int32 = 1) { errorDescription = description; self.code = code }
}

// no network, or a firewall that does not let the program out: then there is no point in trying again soon
func unreachable(_ error: Error) -> Bool {
    let error = error as NSError
    let offline: [URLError.Code] = [.notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff,
                                    .dataNotAllowed]
    return error.domain == NSURLErrorDomain && offline.contains(URLError.Code(rawValue: error.code))
        || error.domain == NSPOSIXErrorDomain && [EPERM, EACCES].contains(Int32(error.code))
}

var lastRequest = Date.distantPast

// one request to the MediaWiki API, at least a second after the one before; up to four tries on errors, one when quick
func get(_ params: [(String, String)], quick: Bool) async throws -> [String: Any] {
    let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    let query = (params + [("format", "json"), ("formatversion", "2")])
        .map { $0.0 + "=" + $0.1.addingPercentEncoding(withAllowedCharacters: unreserved)! }.joined(separator: "&")
    var request = URLRequest(url: URL(string: api + "?" + query)!, timeoutInterval: quick ? 10 : 30)
    request.setValue(agent, forHTTPHeaderField: "User-Agent")
    var pause: UInt64 = 5
    let tries = quick ? 1 : 4
    for attempt in 1...tries {
        do {
            let wait = 1 - Date().timeIntervalSince(lastRequest)
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            lastRequest = Date()
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw Failure("HTTP status \(status)") }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure("no JSON object") }
            if let error = json["error"] as? [String: Any] { throw Failure("API error \(error["code"] ?? "")") }
            return json
        } catch where unreachable(error) {
            throw Failure("AppleGamingWiki is not reachable: \(error.localizedDescription)", code: 3)
        } catch {
            if attempt == tries { throw Failure("AppleGamingWiki did not answer: \(error.localizedDescription)") }
            FileHandle.standardError.write(Data("  retry \(attempt): \(error.localizedDescription)\n".utf8))
            try await Task.sleep(nanoseconds: pause * 1_000_000_000)
            pause *= 2
        }
    }
    throw Failure("unreachable")
}

// Looks up the games that are due: never looked up, or a week ago or longer. Pages found are kept, and
// the rules are written again after the lookups, also when one of them failed.
func lookup(dir: String, ids: [String], quick: Bool) async throws {
    let cache = dir + "/applegamingwiki"
    try await lock(cache, quick: quick)
    var games = readGames(cache)
    let due = unique(ids).filter { id in
        !id.isEmpty && id.unicodeScalars.allSatisfy { $0.properties.numericType == .decimal && $0.isASCII }
            && games.first(where: { $0.id == id }).map { days(since: $0.date) >= 7 } ?? true
    }
    var failure: Error?, changed = false
    for id in due {
        do {
            let links = try await get([("action", "query"), ("list", "exturlusage"), ("euprotocol", "https"),
                                       ("euquery", "steamdb.info/app/\(id)/"), ("eunamespace", "0"), ("eulimit", "50")], quick: quick)
            let found = ((links["query"] as? [String: Any])?["exturlusage"] as? [[String: Any]] ?? [])
            var pageIDs = Array(Set(found.compactMap { $0["pageid"] as? Int })).sorted()
            if !pageIDs.isEmpty {
                let data = try await get([("action", "query"), ("prop", "revisions"), ("rvprop", "content|timestamp"),
                                          ("rvslots", "main"), ("pageids", pageIDs.map(String.init).joined(separator: "|"))],
                                         quick: quick)
                let pages = (data["query"] as? [String: Any])?["pages"] as? [[String: Any]] ?? []
                pageIDs = []
                for page in pages {
                    guard let pageID = page["pageid"] as? Int, page["revisions"] != nil else { continue }
                    try JSONSerialization.data(withJSONObject: page).write(to: URL(fileURLWithPath: cache + "/pages/\(pageID).json"),
                                                                          options: .atomic)
                    pageIDs.append(pageID)
                }
                pageIDs.sort()
            }
            games.removeAll { $0.id == id }
            games.append((id, today(), pageIDs))
            changed = true
            let titles = found.compactMap { $0["title"] as? String }
            print("steam:\(id): " + (pageIDs.isEmpty ? "no page" : unique(titles).joined(separator: ", ")))
        } catch {
            failure = error
            break
        }
    }
    if changed {
        try writeGames(cache, games)
        try writeRules(dir: dir)
    }
    if let failure { throw failure }
}

@main
enum AppleGamingWiki {
    static func main() async {
        let args = CommandLine.arguments
        do {
            switch args.count > 1 ? args[1] : "" {
            case "lookup" where args.count > 3 && args[2] == "--quick":
                try await lookup(dir: args[3], ids: Array(args[4...]), quick: true)
            case "lookup" where args.count > 2 && args[2] != "--quick":
                try await lookup(dir: args[2], ids: Array(args[3...]), quick: false)
            case "rules" where args.count == 3:
                try await lock(args[2] + "/applegamingwiki", quick: false)
                try writeRules(dir: args[2])
            default:
                FileHandle.standardError.write(Data("usage: applegamingwiki lookup [--quick] <dir> <Steam app ID>... | rules <dir>\n".utf8))
                exit(2)
            }
        } catch {
            FileHandle.standardError.write(Data("applegamingwiki: \(error.localizedDescription)\n".utf8))
            exit((error as? Failure)?.code ?? 1)
        }
    }
}
