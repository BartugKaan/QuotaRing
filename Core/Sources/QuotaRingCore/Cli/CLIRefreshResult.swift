import Foundation

/// Why a refresh through Claude Code did not work. Deliberately a bare name: no output of the tool is ever kept,
/// shown or logged, only which of these happened.
public enum CLIRefreshFailure: String, Error, Equatable, Sendable, CaseIterable {
    /// No usable `claude` was found (see ``ClaudeCLILocator``).
    case notFound
    /// The file's `--version` output does not say "(Claude Code)".
    case notClaudeCode
    /// Claude Code was found, but its `--help` does not list every option of ``CLIRefreshCommand/requiredFlags``: it
    /// is too old to be run safely.
    case unsupportedVersion
    /// The tool could not be started.
    case launchFailed
    /// It ran longer than allowed and was stopped.
    case timedOut
    /// It printed more than allowed and was stopped.
    case outputTooLarge
    /// It exited with a non-zero status (or was killed by a signal).
    case exitStatus
    /// Its result says `is_error: true`.
    case reportedError
    /// Its output is not the JSON it should be.
    case unparsable
    /// The JSON is not a `result` object with the expected fields.
    case unexpectedOutput
    /// It reported success, but Claude Code's cache did not get any newer.
    case cacheNotUpdated
    /// The run was abandoned (QuotaRing stopped it because the Mac went to sleep or the feature was turned off). Never
    /// shown: the result of an abandoned run is dropped.
    case cancelled
}

/// What one refresh through Claude Code came to.
public enum CLIRefreshOutcome: Equatable, Sendable {
    /// `/usage` ran without a model request; Claude Code's cache should now be fresh.
    case success
    /// The result reports model turns, cost or tokens: this Claude Code sent `/usage` to the model, which spends usage.
    /// The feature must turn itself off.
    case modelCallDetected
    /// Claude Code is not signed in (or its login is no longer valid).
    case notLoggedIn
    case failed(CLIRefreshFailure)
}

/// Reads the output of ``CLIRefreshCommand/arguments``.
///
/// A success needs all of: exit status 0, a JSON object with `type: "result"`, `is_error: false`, `num_turns: 0` and
/// `total_cost_usd: 0`, and no token or request count above zero. Anything that shows a model was used wins over
/// everything else, even an error, because then the feature has to stop.
public enum CLIRefreshResult {
    public static func parse(stdout: Data, exitCode: Int32) -> CLIRefreshOutcome {
        let parsed = (try? JSONSerialization.jsonObject(with: stdout, options: [.fragmentsAllowed])).flatMap(
            resultObject(in:))

        guard let result = parsed else {
            if exitCode != 0 {
                // Not the expected JSON; the plain text may still be Claude Code's login message.
                let text = String(decoding: stdout.prefix(4_096), as: UTF8.self)
                return mentionsMissingLogin(text) ? .notLoggedIn : .failed(.exitStatus)
            }
            return .failed(.unparsable)
        }

        if modelWasUsed(result) {
            return .modelCallDetected
        }

        let isError = result["is_error"] as? Bool
        let message = result["result"] as? String ?? ""
        if exitCode != 0 || isError == true {
            if mentionsMissingLogin(message) {
                return .notLoggedIn
            }
            return .failed(exitCode != 0 ? .exitStatus : .reportedError)
        }

        guard
            result["type"] as? String == "result",
            isError == false,
            let turns = number(result["num_turns"]), turns == 0,
            let cost = number(result["total_cost_usd"]), cost == 0
        else {
            return .failed(.unexpectedOutput)
        }
        return .success
    }

    // MARK: - Private

    /// The result object: the top-level object, or with `--verbose`-style output (an array of messages) the last one
    /// whose `type` is `result`.
    private static func resultObject(in value: Any) -> [String: Any]? {
        if let object = value as? [String: Any] {
            return object
        }
        if let array = value as? [Any] {
            return array.reversed().lazy.compactMap { $0 as? [String: Any] }.first { $0["type"] as? String == "result" }
        }
        return nil
    }

    /// The safety net: whether the result shows any sign of a model request, so that `/usage` evidently went to the
    /// model and spent usage.
    private static func modelWasUsed(_ result: [String: Any]) -> Bool {
        if let turns = number(result["num_turns"]), turns > 0 { return true }
        if let cost = number(result["total_cost_usd"]), cost > 0 { return true }
        return containsPositiveCount(result["usage"]) || containsPositiveCount(result["modelUsage"])
    }

    /// Whether `value` holds, at any depth, a token, request or cost count above zero: keys such as `input_tokens`,
    /// `cache_read_input_tokens`, `web_search_requests`, `outputTokens` or `costUSD`. Limits such as `contextWindow`
    /// or `maxOutputTokens` do not count.
    private static func containsPositiveCount(_ value: Any?, key: String? = nil) -> Bool {
        switch value {
        case let object as [String: Any]:
            return object.contains { containsPositiveCount($0.value, key: $0.key) }
        case let array as [Any]:
            return array.contains { containsPositiveCount($0, key: key) }
        default:
            guard let key, isCountKey(key), let count = number(value) else { return false }
            return count > 0
        }
    }

    private static func isCountKey(_ key: String) -> Bool {
        let key = key.lowercased()
        if key.hasPrefix("max") || key.contains("window") || key.contains("limit") { return false }
        return key.hasSuffix("tokens") || key.hasSuffix("requests") || key.hasPrefix("cost")
    }

    /// A JSON number as a `Double`; `nil` for anything else, including booleans (which `JSONSerialization` also
    /// returns as `NSNumber`) and NaN.
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isNaN ? nil : double
    }

    /// Whether Claude Code says it has no valid login: "Not logged in", "Invalid API key · Please run /login", an
    /// expired OAuth token, or an authentication error.
    static func mentionsMissingLogin(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let phrases = [
            "not logged in", "invalid api key", "/login", "login required", "oauth token has expired",
            "authentication_error", "not authenticated",
        ]
        return phrases.contains { lowered.contains($0) }
    }
}
