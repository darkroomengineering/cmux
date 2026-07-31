import SwiftUI

/// The companion's own version and build number, read from the bundle.
///
/// This exists because there was previously no way, from the phone, to tell
/// which build was installed. The app displayed nothing, every TestFlight build
/// carried the same version string, and the build number is a bare CI run id --
/// so "is this the current build?" was unanswerable without a Mac and Xcode.
enum AppVersion {
    /// `CFBundleShortVersionString`, e.g. "1.0".
    static var marketing: String {
        bundleString("CFBundleShortVersionString")
    }

    /// `CFBundleVersion`. Matches the GitHub Actions run id that produced the
    /// build, so it can be compared directly against the run in the repo.
    static var build: String {
        bundleString("CFBundleVersion")
    }

    /// e.g. "1.0 (3057430199401)".
    static var displayString: String {
        "\(marketing) (\(build))"
    }

    private static func bundleString(_ key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else {
            return String(localized: "about.version.unknown", defaultValue: "unknown")
        }
        return value
    }
}

/// A single row showing the installed version. Selectable, because the point of
/// it is copying the build number somewhere else to compare.
struct AppVersionRow: View {
    var body: some View {
        LabeledContent(
            String(localized: "about.version.label", defaultValue: "Version"),
            value: AppVersion.displayString
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
}
