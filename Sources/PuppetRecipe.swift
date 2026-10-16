import Foundation

/// Oct 16 2026: the pure half of the Body editor. A body recipe is plain JSON
/// the server owns (normalizeRecipe repairs anything), so the phone keeps it as
/// JSON and edits it only at the paths the catalog names; a field this build
/// does not know about rides along untouched. Everything here is Foundation
/// only, so run-puppet-tests.sh checks it on the Mac.
enum PuppetJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([PuppetJSON])
    case object([String: PuppetJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([PuppetJSON].self) { self = .array(value) }
        else { self = .object(try c.decode([String: PuppetJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }

    var string: String? { if case .string(let value) = self { return value }; return nil }
    var number: Double? { if case .number(let value) = self { return value }; return nil }
    var array: [PuppetJSON]? { if case .array(let value) = self { return value }; return nil }

    /// "hair.color" -> the value there, or nil when any step is missing.
    func value(at path: String) -> PuppetJSON? {
        var node = self
        for key in path.split(separator: ".").map(String.init) {
            guard case .object(let fields) = node, let next = fields[key] else { return nil }
            node = next
        }
        return node
    }

    /// A copy with `value` at `path`; missing or non-object steps become objects.
    func setting(_ value: PuppetJSON, at path: String) -> PuppetJSON {
        let keys = path.split(separator: ".").map(String.init)
        guard !keys.isEmpty else { return value }
        return Self.set(value, keys[...], in: self)
    }

    private static func set(_ value: PuppetJSON, _ keys: ArraySlice<String>, in node: PuppetJSON) -> PuppetJSON {
        guard let key = keys.first else { return value }
        var fields: [String: PuppetJSON] = [:]
        if case .object(let existing) = node { fields = existing }
        fields[key] = set(value, keys.dropFirst(), in: fields[key] ?? .null)
        return .object(fields)
    }
}

/// GET /api/kade/agent-body/catalog: every part and colour with spoken names.
/// A control kind this build does not know is kept as `.other` and not shown.
struct PuppetCatalog: Decodable {
    struct Option: Decodable, Identifiable, Hashable {
        let id: String
        let name: String
        let note: String
        let hex: String?
        let fantasy: Bool

        enum CodingKeys: String, CodingKey { case id, name, note, hex, fantasy }
        init(id: String, name: String, note: String = "", hex: String? = nil, fantasy: Bool = false) {
            self.id = id; self.name = name; self.note = note; self.hex = hex; self.fantasy = fantasy
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? c.decode(String.self, forKey: .id)) ?? ""
            let named = try? c.decodeIfPresent(String.self, forKey: .name)
            name = named.flatMap { $0.isEmpty ? nil : $0 } ?? (id.isEmpty ? "None" : id)
            note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? ""
            hex = try? c.decodeIfPresent(String.self, forKey: .hex)
            fantasy = (try? c.decodeIfPresent(Bool.self, forKey: .fantasy)) ?? false
        }

        /// The note only when it says more than the name ("slim" under "Slim" does not).
        var extraNote: String {
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.lowercased() == name.lowercased() ? "" : trimmed
        }
    }

    struct Control: Decodable, Identifiable {
        enum Kind: String { case choice, color, slider, accessory, other }
        let path: String
        let kind: Kind
        let name: String
        let options: [Option]
        let ends: [String]
        let slot: String?

        /// Accessories share one path, so their slot keeps each one distinct.
        var id: String { slot.map { path + "." + $0 } ?? path }
        var low: String { ends.first ?? "Less" }
        var high: String { ends.count > 1 ? ends[1] : "More" }

        enum CodingKeys: String, CodingKey { case path, kind, name, options, ends, slot }
        init(path: String, kind: Kind, name: String, options: [Option] = [], ends: [String] = [], slot: String? = nil) {
            self.path = path; self.kind = kind; self.name = name; self.options = options; self.ends = ends; self.slot = slot
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            kind = Kind(rawValue: (try? c.decode(String.self, forKey: .kind)) ?? "") ?? .other
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? path
            options = (try? c.decodeIfPresent([Option].self, forKey: .options)) ?? []
            ends = (try? c.decodeIfPresent([String].self, forKey: .ends)) ?? []
            slot = try? c.decodeIfPresent(String.self, forKey: .slot)
        }

        /// Shown in the editor: sliders always; lists only with a real choice.
        var isEditable: Bool {
            switch kind {
            case .slider: return true
            case .choice, .color, .accessory: return options.count > 1
            case .other: return false
            }
        }
    }

    struct Section: Decodable, Identifiable {
        let id: String
        let name: String
        let controls: [Control]
    }

    let sections: [Section]
}

/// The whole catalog reply: the catalog plus the kit's starting recipe.
struct PuppetCatalogReply: Decodable {
    let kit: String?
    let catalog: PuppetCatalog
    let defaults: PuppetJSON
}

/// Reading and changing one control's value in a recipe.
enum PuppetRecipeEdit {
    /// The chosen option id (choice, colour) or the accessory worn in this slot
    /// ("" for none). Sliders have no option id.
    static func selectedID(_ control: PuppetCatalog.Control, in recipe: PuppetJSON) -> String {
        if control.kind == .accessory {
            let ids = Set(control.options.map(\.id).filter { !$0.isEmpty })
            let worn = recipe.value(at: control.path)?.array?.compactMap(\.string) ?? []
            return worn.first { ids.contains($0) } ?? ""
        }
        return recipe.value(at: control.path)?.string ?? ""
    }

    static func selectedOption(_ control: PuppetCatalog.Control, in recipe: PuppetJSON) -> PuppetCatalog.Option? {
        let id = selectedID(control, in: recipe)
        return control.options.first { $0.id == id }
    }

    /// A copy wearing `optionID` in this control. An accessory replaces only
    /// what this slot wore, so glasses never take the hat off.
    static func choosing(_ optionID: String, for control: PuppetCatalog.Control, in recipe: PuppetJSON) -> PuppetJSON {
        guard control.kind == .accessory else { return recipe.setting(.string(optionID), at: control.path) }
        let ids = Set(control.options.map(\.id).filter { !$0.isEmpty })
        var worn = (recipe.value(at: control.path)?.array ?? []).filter { item in
            guard let id = item.string else { return true }
            return !ids.contains(id)
        }
        if !optionID.isEmpty { worn.append(.string(optionID)) }
        return recipe.setting(.array(worn), at: control.path)
    }

    /// 0...1; a missing or odd value reads as the middle, as the server repairs it.
    static func sliderValue(_ control: PuppetCatalog.Control, in recipe: PuppetJSON) -> Double {
        guard let value = recipe.value(at: control.path)?.number, value.isFinite else { return 0.5 }
        return min(1, max(0, value))
    }

    static func setting(slider value: Double, for control: PuppetCatalog.Control, in recipe: PuppetJSON) -> PuppetJSON {
        let clamped = value.isFinite ? min(1, max(0, value)) : 0.5
        // Two decimals: the server's own steps, and no float noise in the recipe.
        return recipe.setting(.number((clamped * 100).rounded() / 100), at: control.path)
    }

    /// What VoiceOver says for a slider: the nearer end in the catalog's own
    /// words, then the percent ("Narrow, 20 percent", "In between, 50 percent").
    static func sliderWords(_ value: Double, low: String, high: String) -> String {
        let clamped = value.isFinite ? min(1, max(0, value)) : 0.5
        let percent = Int((clamped * 100).rounded())
        let word = percent < 34 ? low : percent > 66 ? high : "In between"
        return "\(word), \(percent) percent"
    }
}

/// The local Undo list. A run of changes to one control (a slider dragged, a
/// VoiceOver swipe after swipe) is one step, so Undo goes back to before the run.
struct PuppetEditHistory {
    struct Entry {
        let recipe: PuppetJSON
        let label: String
        let key: String
        var at: Date
    }
    static let limit = 40
    static let runSeconds: TimeInterval = 2

    private(set) var entries: [Entry] = []
    var canUndo: Bool { !entries.isEmpty }
    var lastLabel: String? { entries.last?.label }

    /// `before` is the recipe as it was just before this change.
    mutating func record(before: PuppetJSON, label: String, key: String, at: Date = Date()) {
        if var last = entries.last, last.key == key, at.timeIntervalSince(last.at) < Self.runSeconds {
            last.at = at
            entries[entries.count - 1] = last
            return
        }
        entries.append(Entry(recipe: before, label: label, key: key, at: at))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    mutating func undo() -> Entry? { entries.popLast() }
    mutating func clear() { entries = [] }
}

enum PuppetDescriptionText {
    /// The sentences of `after` that `before` did not have: what a change did
    /// to the words. The same rule as the web editor's live region.
    static func changedSentences(before: String, after: String) -> String {
        let old = Set(sentences(before))
        return sentences(after).filter { !old.contains($0) }.joined(separator: " ")
    }

    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            current.append(character)
            let ends = character == "." || character == "!" || character == "?"
            let next = index + 1 < characters.count ? characters[index + 1] : " "
            if ends && next.isWhitespace {
                let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { out.append(sentence) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    /// "$0.0012" under a cent, "$0.03" from a cent up (the Admin screen's rule).
    static func dollars(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "$0.00" }
        return value < 0.01 ? String(format: "$%.4f", value) : String(format: "$%.2f", value)
    }
}
