import Foundation
import QuotaRingCore

/// Fixed, made-up usage for `--demo`: screenshots and UI work without the Keychain, the network or any Claude file,
/// so nobody's real usage or project names are ever shown.
enum DemoData {
    /// Session 28 % used and resetting in 2 h 14 m; weekly 41 % (Fable 12 %); extra usage off.
    static func snapshot(now: Date) -> UsageSnapshot {
        // A few seconds of slack so the countdown reads "2h 14m" right after launch.
        let sessionReset = now.addingTimeInterval(2 * 3600 + 14 * 60 + 30)
        let weeklyReset = now.addingTimeInterval(4 * 86_400 + 7 * 3600)
        let report = UsageReport(
            limits: [
                UsageLimit(kind: .session, percentUsed: 28, resetsAt: sessionReset, isActive: true),
                UsageLimit(kind: .weeklyAll, percentUsed: 41, resetsAt: weeklyReset),
                UsageLimit(kind: .weeklyScoped, percentUsed: 12, resetsAt: weeklyReset, scopeName: "Fable"),
            ],
            extraUsage: ExtraUsage(isEnabled: false),
            weeklyBreakdown: WeeklyBreakdown(
                asOf: now.addingTimeInterval(-60),
                windowStartedAt: weeklyReset.addingTimeInterval(-7 * 86_400),
                rows: [
                    BreakdownRow(key: "claude_code", displayName: "Claude Code", percent: 52),
                    BreakdownRow(key: "chats", displayName: "Chats", percent: 18),
                    BreakdownRow(key: "cowork", displayName: "Cowork", percent: 27),
                    BreakdownRow(key: "other", displayName: "Other", percent: 3),
                ]
            )
        )
        return UsageSnapshot(report: report, fetchedAt: now.addingTimeInterval(-60), source: .demo)
    }

    static func activity(now: Date) -> [ActivityRange: UsageBreakdown] {
        [
            .session: breakdown(
                models: [
                    ("Opus 5.5", tokens(input: 31_400, output: 48_900, cacheWrite: 162_000, cacheRead: 1_310_000)),
                    ("Fable 5", tokens(input: 9_800, output: 11_200, cacheWrite: 41_000, cacheRead: 402_000)),
                    ("Haiku 4.5", tokens(input: 4_100, output: 2_300, cacheWrite: 6_500, cacheRead: 58_000)),
                ],
                projects: [
                    ("quotaring", 0.58), ("garden-planner", 0.27), ("dotfiles", 0.15),
                ]
            ),
            .today: breakdown(
                models: [
                    ("Opus 5.5", tokens(input: 52_600, output: 81_300, cacheWrite: 288_000, cacheRead: 2_240_000)),
                    ("Fable 5", tokens(input: 17_200, output: 19_900, cacheWrite: 70_000, cacheRead: 731_000)),
                    ("Haiku 4.5", tokens(input: 6_900, output: 3_800, cacheWrite: 11_000, cacheRead: 97_000)),
                ],
                projects: [
                    ("quotaring", 0.49), ("garden-planner", 0.24), ("dotfiles", 0.12), ("recipe-box", 0.09),
                    ("blog", 0.06),
                ]
            ),
            .week: breakdown(
                models: [
                    ("Opus 5.5", tokens(input: 241_000, output: 377_000, cacheWrite: 1_310_000, cacheRead: 9_870_000)),
                    ("Fable 5", tokens(input: 96_000, output: 108_000, cacheWrite: 402_000, cacheRead: 3_960_000)),
                    ("Haiku 4.5", tokens(input: 31_000, output: 17_000, cacheWrite: 52_000, cacheRead: 455_000)),
                ],
                projects: [
                    ("quotaring", 0.41), ("garden-planner", 0.22), ("recipe-box", 0.14), ("dotfiles", 0.10),
                    ("blog", 0.08), ("scratch", 0.05),
                ]
            ),
        ]
    }

    /// Seven days ending today, oldest first.
    static func daily(now: Date, calendar: Calendar) -> [DailyTokens] {
        let totalsInThousands = [1_840, 3_120, 640, 2_950, 2_410, 1_070, 3_480]
        let today = calendar.startOfDay(for: now)
        return totalsInThousands.enumerated().map { index, thousands in
            let offset = index - (totalsInThousands.count - 1)
            let day = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            let total = thousands * 1_000
            return DailyTokens(
                day: calendar.startOfDay(for: day),
                tokens: tokens(
                    input: total / 50, output: total / 30, cacheWrite: total / 8,
                    cacheRead: total - total / 50 - total / 30 - total / 8)
            )
        }
    }

    private static func tokens(input: Int, output: Int, cacheWrite: Int, cacheRead: Int) -> TokenCounts {
        TokenCounts(input: input, output: output, cacheWrite: cacheWrite, cacheRead: cacheRead)
    }

    /// Builds a breakdown whose project rows split the models' total by the given shares.
    private static func breakdown(
        models: [(String, TokenCounts)],
        projects: [(String, Double)]
    ) -> UsageBreakdown {
        let total = models.reduce(TokenCounts.zero) { $0 + $1.1 }
        let byProject = projects.map { name, share in
            NamedTokens(
                name: name,
                tokens: TokenCounts(
                    input: Int(Double(total.input) * share),
                    output: Int(Double(total.output) * share),
                    cacheWrite: Int(Double(total.cacheWrite) * share),
                    cacheRead: Int(Double(total.cacheRead) * share)
                )
            )
        }
        return UsageBreakdown(
            total: total,
            byModel: models.map { NamedTokens(name: $0.0, tokens: $0.1) },
            byProject: byProject
        )
    }
}
