/// Wraps a sensitive string so it cannot leak through printing, string interpolation, `dump` or reflection.
///
/// The value is reachable only through ``withValue(_:)``. The type is deliberately not `Codable`, `Equatable` or
/// `Hashable`.
public struct Secret: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let value: String

    public init(_ value: String) {
        self.value = value
    }

    public var isEmpty: Bool {
        value.isEmpty
    }

    /// Runs `body` with the wrapped value. Do not let the value escape the closure.
    public func withValue<R>(_ body: (String) throws -> R) rethrows -> R {
        try body(value)
    }

    public var description: String { "<redacted>" }

    public var debugDescription: String { "<redacted>" }

    public var customMirror: Mirror {
        Mirror(self, children: [], displayStyle: .struct)
    }
}
