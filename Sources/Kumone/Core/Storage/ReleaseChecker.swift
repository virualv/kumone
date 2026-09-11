import Foundation

/// Looks up the latest GitHub release. iOS has no Sparkle, so Settings
/// offers a manual check that links to the release page for re-sideloading.
enum ReleaseChecker {
    struct Release {
        let version: String
        /// The release page (fallback download link).
        let url: URL
        /// Direct download URL of the plain iOS IPA asset, when present.
        /// Manual sideloading (AltStore / SideStore / Sideloadly) must use this one:
        /// the CarPlay build carries a restricted entitlement that their
        /// provisioning profiles cannot sign.
        let ipaURL: URL?
        /// Direct download URL of the CarPlay-enabled iOS IPA asset, when present.
        /// Only TrollStore can install it — it keeps the entitlements already baked
        /// into the binary — so `installViaTrollStore` hands this one over.
        /// `nil` for releases published before this asset existed.
        let carPlayIPAURL: URL?
    }

    static let releasesPage = URL(string: "https://github.com/missuo/kumone/releases/latest")!

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static func latest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/missuo/kumone/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let html = obj["html_url"] as? String, let url = URL(string: html)
        else { throw NeteaseAPIError.decoding("release") }
        let assets = obj["assets"] as? [[String: Any]] ?? []
        let ipas = assets.filter { ($0["name"] as? String)?.lowercased().hasSuffix(".ipa") == true }
        // Both IPAs live in the same release, so each lookup must say which one it
        // wants: a bare `first { hasSuffix(".ipa") }` would be a coin flip once the
        // CarPlay asset exists, and handing the CarPlay build to AltStore/SideStore
        // would produce an IPA their profiles cannot sign.
        // Matching is case-insensitive; only one asset can contain "-carplay", so the
        // result does not depend on the order GitHub returns assets in.
        let carPlay = ipas.first { ($0["name"] as? String)?.lowercased().contains("-carplay") == true }
        let plain = ipas.first { ($0["name"] as? String)?.lowercased().contains("-carplay") == false }
        func downloadURL(_ asset: [String: Any]?) -> URL? {
            (asset?["browser_download_url"] as? String).flatMap(URL.init)
        }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                       url: url,
                       ipaURL: downloadURL(plain),
                       carPlayIPAURL: downloadURL(carPlay))
    }

    /// True when `remote` is newer than `local` (numeric dotted compare).
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let a = remote.split(separator: ".").map { Int($0) ?? 0 }
        let b = local.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
