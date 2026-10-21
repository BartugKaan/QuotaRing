import Foundation

/// Turns the model ids found in transcripts into the short names shown in the UI.
public enum ModelNames {
    private static let idPrefix = "claude-"

    /// `claude-opus-4-8` becomes `Opus 4.8`; `claude-3-5-sonnet-20241022` becomes `Sonnet 3.5`.
    ///
    /// The `claude-` prefix and a trailing `-YYYYMMDD` snapshot date are dropped and the rest is split on `-`. The
    /// family is the first alphabetic token, capitalized; the version is the numeric tokens joined with `.`.
    /// Ids that do not start with `claude-`, or that contain no family token, are returned unchanged.
    public static func family(_ modelID: String) -> String {
        guard modelID.hasPrefix(idPrefix) else { return modelID }

        var tokens = modelID.dropFirst(idPrefix.count).split(separator: "-", omittingEmptySubsequences: true)
        if let last = tokens.last, last.utf8.count == 8, isDigits(last) {
            tokens.removeLast()
        }

        guard let familyToken = tokens.first(where: isLetters) else { return modelID }
        let name = familyToken.prefix(1).uppercased() + familyToken.dropFirst()
        let version = tokens.filter(isDigits).joined(separator: ".")
        return version.isEmpty ? name : name + " " + version
    }

    private static func isDigits(_ token: Substring) -> Bool {
        !token.isEmpty && token.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    private static func isLetters(_ token: Substring) -> Bool {
        !token.isEmpty
            && token.utf8.allSatisfy {
                (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0)
                    || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0)
            }
    }
}
