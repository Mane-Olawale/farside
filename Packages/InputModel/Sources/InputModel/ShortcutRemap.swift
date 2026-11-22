/// iPadOS keeps some shortcuts for itself (plan section 9, spike S7). The remap table sends a
/// combination that does reach the app as the Mac shortcut instead: Option-Tab as Command-Tab.
///
/// A remap turns the trigger modifier into the target modifier for as long as the trigger stays
/// held, not only for the one key. That is what makes the app switcher work: hold Option, press
/// Tab several times to cycle, release Option to choose, exactly as with Command on a Mac.
public struct ShortcutRemap: Sendable, Equatable, Codable {
    public struct Rule: Sendable, Equatable, Hashable, Codable {
        /// The modifier held on the iPad, such as Option.
        public var from: ModifierKind
        /// The key that triggers the rule, as a HID usage.
        public var key: UInt32
        /// The modifier the Mac receives instead.
        public var to: ModifierKind

        public init(from: ModifierKind, key: UInt32, to: ModifierKind) {
            self.from = from
            self.key = key
            self.to = to
        }
    }

    public enum ModifierKind: String, Sendable, Codable, CaseIterable {
        case control, shift, option, command

        var left: ModifierSet {
            switch self {
            case .control: .leftControl
            case .shift: .leftShift
            case .option: .leftOption
            case .command: .leftCommand
            }
        }

        var right: ModifierSet {
            switch self {
            case .control: .rightControl
            case .shift: .rightShift
            case .option: .rightOption
            case .command: .rightCommand
            }
        }

        var both: ModifierSet { left.union(right) }
    }

    /// The plan's defaults: Option-Tab, Option-Space and Option-` become their Command forms.
    public static let defaults: [Rule] = [
        Rule(from: .option, key: KeyMap.Usage.tab, to: .command),
        Rule(from: .option, key: KeyMap.Usage.space, to: .command),
        Rule(from: .option, key: KeyMap.Usage.graveAccent, to: .command),
    ]

    public var rules: [Rule]
    /// Translations in force: the iPad's modifier kind and what it reaches the Mac as. Each stays
    /// until that modifier is released on the iPad.
    private var active: [ModifierKind: ModifierKind] = [:]

    public init(rules: [Rule] = ShortcutRemap.defaults) {
        self.rules = rules
    }

    enum CodingKeys: String, CodingKey { case rules }

    /// Takes a key event and the modifiers held on the iPad, and returns the modifiers the Mac
    /// should see. Call for every key event, modifiers included, in order.
    public mutating func translate(usage: UInt32, down: Bool, modifiers: ModifierSet) -> ModifierSet {
        // A translation ends once its modifier is no longer held on either side.
        for kind in active.keys where modifiers.isDisjoint(with: kind.both) {
            active[kind] = nil
        }
        if down, !KeyMap.Usage.isModifier(usage) {
            for rule in rules where rule.key == usage && active[rule.from] == nil {
                let others = ModifierKind.allCases.filter { $0 != rule.from }.reduce(ModifierSet()) { $0.union($1.both) }
                // Only the exact combination: Option-Tab, not Option-Shift-Tab.
                if !modifiers.isDisjoint(with: rule.from.both), modifiers.intersection(others).isEmpty {
                    active[rule.from] = rule.to
                }
            }
        }
        var result = modifiers
        for (from, to) in active {
            if !modifiers.isDisjoint(with: from.left) {
                result.remove(from.left)
                result.insert(to.left)
            }
            if !modifiers.isDisjoint(with: from.right) {
                result.remove(from.right)
                result.insert(to.right)
            }
        }
        return result
    }

    /// Whether a translation is in force, for the toolbar to show.
    public var isActive: Bool { !active.isEmpty }

    public mutating func reset() { active = [:] }
}
