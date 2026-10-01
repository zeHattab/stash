import Foundation

/// Настройки в UserDefaults (в App Group, чтобы делить с расширением позже).
public final class UserDefaultsSettingsStore: SettingsStore {
    private let defaults: UserDefaults

    public init(suiteName: String?) {
        self.defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    public func bool(forKey key: String) -> Bool { defaults.bool(forKey: key) }
    public func set(_ value: Bool, forKey key: String) { defaults.set(value, forKey: key) }
    public func integer(forKey key: String) -> Int { defaults.integer(forKey: key) }
    public func set(_ value: Int, forKey key: String) { defaults.set(value, forKey: key) }
    public func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    public func set(_ value: String?, forKey key: String) { defaults.set(value, forKey: key) }
    public func double(forKey key: String) -> Double { defaults.double(forKey: key) }
    public func set(_ value: Double, forKey key: String) { defaults.set(value, forKey: key) }
}
