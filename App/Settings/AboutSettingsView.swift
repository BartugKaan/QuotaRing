import AppKit
import SwiftUI

/// Where to find the source and how to report a security problem.
enum ProjectLinks {
    // Compile-time constants: the force unwraps cannot fail.
    static let repository = URL(string: "https://github.com/BartugKaan/QuotaRing")!
    static let securityPolicy = URL(string: "https://github.com/BartugKaan/QuotaRing/security/policy")!
}

/// Version, license, links and the non-affiliation notice.
struct AboutSettingsView: View {
    private static let info = Bundle.main.infoDictionary

    private var versionText: String {
        let version = Self.info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Self.info?["CFBundleVersion"] as? String ?? "?"
        return String(
            localized: "Version \(version) (\(build))",
            comment: "About tab; the arguments are a version such as 0.1.0 and a build number")
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)

            VStack(spacing: 2) {
                Text("QuotaRing")
                    .font(.title.weight(.semibold))
                Text(versionText)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("MIT License")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            VStack(spacing: 6) {
                Link(destination: ProjectLinks.repository) {
                    Label {
                        Text(verbatim: "github.com/BartugKaan/QuotaRing")
                    } icon: {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                    }
                }
                Link(destination: ProjectLinks.securityPolicy) {
                    Label("Report a security issue", systemImage: "exclamationmark.shield")
                }
            }

            Text(
                """
                QuotaRing is an independent project and is not affiliated with, endorsed or sponsored by \
                Anthropic. Claude is a trademark of Anthropic.
                """
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
    }
}
