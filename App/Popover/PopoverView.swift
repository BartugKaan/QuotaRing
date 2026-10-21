import QuotaRingCore
import SwiftUI

/// Placeholder popover: remaining share, reset countdown and Quit. The full popover replaces it.
struct PopoverView: View {
    let model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 12) {
                if let session = model.session(at: context.date) {
                    Text("\(QuotaFormat.percent(session.percentRemaining)) left")
                        .font(.title2.weight(.semibold).monospacedDigit())
                    if let resetsAt = session.resetsAt {
                        Text("Resets in \(QuotaFormat.countdown(to: resetsAt, from: context.date))")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Waiting for fresh data")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No usage data yet")
                        .font(.headline)
                }
                Divider()
                Button("Quit QuotaRing") {
                    NSApp.terminate(nil)
                }
            }
            .padding(16)
            .frame(width: 340, alignment: .leading)
        }
    }
}
