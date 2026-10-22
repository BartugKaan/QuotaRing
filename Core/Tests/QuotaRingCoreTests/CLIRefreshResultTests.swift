import Foundation
import Testing

@testable import QuotaRingCore

private func fixtureData(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

/// The success fixture with `edit` applied to its top-level object.
private func editedSuccess(_ edit: (inout [String: Any]) -> Void) throws -> Data {
    var object = try #require(
        try JSONSerialization.jsonObject(with: fixtureData("cli-usage-success")) as? [String: Any])
    edit(&object)
    return try JSONSerialization.data(withJSONObject: object)
}

@Suite struct CLIRefreshResultTests {
    // MARK: - Success

    @Test func verifiedSuccessOutputIsASuccess() throws {
        #expect(CLIRefreshResult.parse(stdout: try fixtureData("cli-usage-success"), exitCode: 0) == .success)
    }

    @Test func messageArrayEndingInAResultIsRead() throws {
        let result = try JSONSerialization.jsonObject(with: fixtureData("cli-usage-success"))
        let data = try JSONSerialization.data(withJSONObject: [["type": "system", "subtype": "init"], result])
        #expect(CLIRefreshResult.parse(stdout: data, exitCode: 0) == .success)
    }

    @Test func modelLimitsAreNotCounts() throws {
        // A model entry with a context window and output limit, but nothing used, is not a model request.
        let data = try editedSuccess {
            $0["modelUsage"] = [
                "claude-haiku-4-5": [
                    "inputTokens": 0, "outputTokens": 0, "costUSD": 0, "contextWindow": 200_000,
                    "maxOutputTokens": 32_000,
                ]
            ]
        }
        #expect(CLIRefreshResult.parse(stdout: data, exitCode: 0) == .success)
    }

    // MARK: - Safety net

    @Test func modelCallIsDetected() throws {
        #expect(
            CLIRefreshResult.parse(stdout: try fixtureData("cli-usage-model-call"), exitCode: 0) == .modelCallDetected)
        // Even when the run also failed: spending usage always turns the feature off.
        #expect(
            CLIRefreshResult.parse(stdout: try fixtureData("cli-usage-model-call"), exitCode: 1) == .modelCallDetected)
    }

    @Test func anySignOfAModelRequestIsDetected() throws {
        let edits: [(inout [String: Any]) -> Void] = [
            { $0["num_turns"] = 1 },
            { $0["total_cost_usd"] = 0.0001 },
            { $0["usage"] = ["input_tokens": 0, "output_tokens": 7] },
            { $0["usage"] = ["cache_read_input_tokens": 12] },
            { $0["usage"] = ["cache_creation": ["ephemeral_5m_input_tokens": 3]] },
            { $0["usage"] = ["server_tool_use": ["web_search_requests": 1]] },
            { $0["modelUsage"] = ["claude-haiku-4-5": ["inputTokens": 5]] },
            { $0["modelUsage"] = ["claude-haiku-4-5": ["costUSD": 0.01]] },
            {
                $0["num_turns"] = 1
                $0["is_error"] = true
            },
        ]
        for edit in edits {
            #expect(CLIRefreshResult.parse(stdout: try editedSuccess(edit), exitCode: 0) == .modelCallDetected)
        }
    }

    @Test func booleansAreNotCounts() throws {
        let data = try editedSuccess { $0["usage"] = ["input_tokens": true] }
        #expect(CLIRefreshResult.parse(stdout: data, exitCode: 0) == .success)
    }

    // MARK: - Not logged in

    @Test func notLoggedInIsRecognized() throws {
        let data = try fixtureData("cli-usage-not-logged-in")
        #expect(CLIRefreshResult.parse(stdout: data, exitCode: 1) == .notLoggedIn)
        #expect(CLIRefreshResult.parse(stdout: data, exitCode: 0) == .notLoggedIn)
    }

    @Test func notLoggedInVariantsAreRecognized() throws {
        for message in [
            "Not logged in · Please run /login",
            "OAuth token has expired. Please obtain a new token or refresh your existing token.",
            "API Error: 401 {\"type\":\"error\",\"error\":{\"type\":\"authentication_error\"}}",
        ] {
            let data = try editedSuccess {
                $0["is_error"] = true
                $0["result"] = message
            }
            #expect(CLIRefreshResult.parse(stdout: data, exitCode: 1) == .notLoggedIn)
        }
    }

    @Test func plainTextLoginMessageWithAFailedExitIsRecognized() {
        let data = Data("Invalid API key · Please run /login\n".utf8)
        #expect(CLIRefreshResult.parse(stdout: data, exitCode: 1) == .notLoggedIn)
    }

    @Test func loginWordsInASuccessDoNotCount() throws {
        let data = try editedSuccess { $0["result"] = "Current session: 4% used. Run /login to switch accounts." }
        #expect(CLIRefreshResult.parse(stdout: data, exitCode: 0) == .success)
    }

    // MARK: - Failures

    @Test func garbageIsUnparsable() {
        #expect(CLIRefreshResult.parse(stdout: Data("not json at all".utf8), exitCode: 0) == .failed(.unparsable))
        #expect(CLIRefreshResult.parse(stdout: Data(), exitCode: 0) == .failed(.unparsable))
        #expect(CLIRefreshResult.parse(stdout: Data([0xFF, 0xFE, 0x00]), exitCode: 0) == .failed(.unparsable))
        #expect(CLIRefreshResult.parse(stdout: Data("42".utf8), exitCode: 0) == .failed(.unparsable))
    }

    @Test func garbageWithAFailedExitIsAnExitFailure() {
        #expect(CLIRefreshResult.parse(stdout: Data("Segmentation fault".utf8), exitCode: 139) == .failed(.exitStatus))
        #expect(CLIRefreshResult.parse(stdout: Data(), exitCode: 1) == .failed(.exitStatus))
    }

    @Test func nonZeroExitIsAFailureEvenWithASuccessResult() throws {
        #expect(
            CLIRefreshResult.parse(stdout: try fixtureData("cli-usage-success"), exitCode: 1) == .failed(.exitStatus))
    }

    @Test func reportedErrorIsAFailure() throws {
        let data = try editedSuccess {
            $0["is_error"] = true
            $0["result"] = "Something went wrong"
        }
        #expect(CLIRefreshResult.parse(stdout: data, exitCode: 0) == .failed(.reportedError))
    }

    @Test func missingSafetyFieldsAreUnexpected() throws {
        let edits: [(inout [String: Any]) -> Void] = [
            { $0.removeValue(forKey: "num_turns") },
            { $0.removeValue(forKey: "total_cost_usd") },
            { $0.removeValue(forKey: "is_error") },
            { $0["type"] = "assistant" },
            { $0["num_turns"] = "0" },
            { $0["total_cost_usd"] = false },
        ]
        for edit in edits {
            #expect(CLIRefreshResult.parse(stdout: try editedSuccess(edit), exitCode: 0) == .failed(.unexpectedOutput))
        }
    }

    @Test func arrayWithoutAResultIsUnparsable() throws {
        let data = try JSONSerialization.data(withJSONObject: [["type": "system"], ["type": "assistant"]])
        #expect(CLIRefreshResult.parse(stdout: data, exitCode: 0) == .failed(.unparsable))
    }

    @Test func outcomesNeverCarryTheOutput() throws {
        // Only a reason name is kept: nothing the tool printed can end up in a log or on screen.
        let secretish = "sk-ant-oat01-MUST-NOT-LEAK"
        let data = try editedSuccess {
            $0["is_error"] = true
            $0["result"] = secretish
        }
        let outcome = CLIRefreshResult.parse(stdout: data, exitCode: 2)
        var dumped = ""
        dump(outcome, to: &dumped)
        #expect(!String(reflecting: outcome).contains(secretish))
        #expect(!dumped.contains(secretish))
    }
}
