import Foundation
import Darwin
import UIKit

struct WCAppCatalog {
    let names: [String: String]
    let icons: [String: UIImage]
}

// The system may hide third-party LSApplicationProxy display names even when
// worse_query exposes their data-container Bundle IDs. Keep two independent
// fallbacks: exact known identifiers and an on-device read of installed .app
// Info.plist files. Never assign a guessed name to an unknown Bundle ID.
enum WCAppNames {
    private static let offlineNames: [String: String] = [
        "com.tencent.xin": "微信",
        "com.taobao.taobao4iphone": "淘宝",
        "com.ss.iphone.ugc.Aweme": "抖音",
        "com.360buy.jdmobile": "京东",
        "com.bot.doubao": "豆包",
        "com.tencent.mqq": "QQ",
        "com.lemon.lv": "剪映",
        "com.meituan.itakeaway": "美团外卖",
        "com.meituan.imeituan": "美团",
        "app.landrop.landrop-flutter": "LANDrop",
        "com.alipay.iphoneclient": "支付宝",
        "com.xingin.discover": "小红书",
        "com.sina.weibo": "微博",
        "com.xunmeng.pinduoduo": "拼多多",
        "com.tencent.wework": "企业微信",
        "com.tencent.qqmusic": "QQ音乐",
        "com.netease.cloudmusic": "网易云音乐",
        "com.tencent.qqmail": "QQ邮箱",
        "tv.danmaku.bilianime": "哔哩哔哩",
        "com.openai.chat": "ChatGPT",
        "com.google.ios.youtube": "YouTube",
        "com.spotify.client": "Spotify"
    ]

    static func displayName(for bundleID: String, names: [String: String]) -> String? {
        names[bundleID] ?? offlineNames[bundleID]
    }

    static func savedNames() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: "wc.verifiedAppStoreNames") as? [String: String] ?? [:]
    }

    static func storeVerifiedNames(_ verified: [String: String]) {
        var names = savedNames()
        names.merge(verified) { _, new in new }
        UserDefaults.standard.set(names, forKey: "wc.verifiedAppStoreNames")
    }

    /// Queries only the public App Store name (not artwork), after an explicit
    /// user action. Bundle IDs are sent to Apple's API, never to our server.
    static func appStoreName(for bundleID: String) async -> String? {
        for country in ["cn", "us"] {
            var components = URLComponents(string: "https://itunes.apple.com/lookup")!
            components.queryItems = [
                URLQueryItem(name: "bundleId", value: bundleID),
                URLQueryItem(name: "country", value: country)
            ]
            guard let url = components.url else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count < 256_000,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else { continue }
            for result in results {
                guard let returnedID = result["bundleId"] as? String,
                      returnedID.caseInsensitiveCompare(bundleID) == .orderedSame else { continue }
                let name = (result["trackName"] as? String)
                    ?? (result["trackCensoredName"] as? String)
                if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return name
                }
            }
        }
        return nil
    }

    private static func installedName(at appPath: String, info: [String: Any]) -> String? {
        let bundle = Bundle(path: appPath)
        let current = bundle?.localizedInfoDictionary ?? [:]
        let dictionaries: [[String: Any]] = [current, info]
        for dictionary in dictionaries {
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let label = dictionary[key] as? String, !label.isEmpty { return label }
            }
        }
        return nil
    }

    private static func installedIcon(at appPath: String, info: [String: Any]) -> UIImage? {
        let bundle = Bundle(path: appPath)
        var iconNames = [String]()
        for plistKey in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            if let icons = info[plistKey] as? [String: Any],
               let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] {
                iconNames += primary["CFBundleIconFiles"] as? [String] ?? []
                if let name = primary["CFBundleIconName"] as? String { iconNames.append(name) }
            }
        }
        if let name = info["CFBundleIconFile"] as? String { iconNames.append(name) }
        if let files = info["CFBundleIconFiles"] as? [String] { iconNames += files }
        for name in iconNames.reversed() {
            let base = (name as NSString).deletingPathExtension
            if let bundle, let image = UIImage(named: base, in: bundle, compatibleWith: nil) {
                return image
            }
            for file in [name, base + "@3x.png", base + "@2x.png", base + ".png"] {
                if let image = UIImage(contentsOfFile: appPath + "/" + file) { return image }
            }
        }
        return nil
    }

    static func catalog(groupID: String) -> WCAppCatalog {
        var names = offlineNames
        names.merge(savedNames()) { _, saved in saved }
        var icons: [String: UIImage] = [:]
        let root = "/var/containers/Bundle/Application"
        // This mirrors 3105's app-bundle metadata catalog. It is read-only.
        // A dedicated App Group remains mandatory because worse_query
        // temporarily replaces its Library/Caches while acquiring a token.
        let lease = worse_query(root, groupID, false, true)
        guard lease > 0 else { return WCAppCatalog(names: names, icons: icons) }
        defer { worse_query_release(lease) }

        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(atPath: root)) ?? []
        for folder in folders.prefix(2_048) {
            guard UUID(uuidString: folder) != nil else { continue }
            let path = root + "/" + folder
            let entries = (try? fm.contentsOfDirectory(atPath: path)) ?? []
            for item in entries.prefix(16) where item.hasSuffix(".app") {
                let appPath = path + "/" + item
                let infoPath = appPath + "/Info.plist"
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: infoPath)),
                      data.count <= 2_097_152,
                      let info = try? PropertyListSerialization.propertyList(
                        from: data, options: [], format: nil
                      ) as? [String: Any],
                      let bundleID = info["CFBundleIdentifier"] as? String,
                      !bundleID.isEmpty else { continue }
                if let name = installedName(at: appPath, info: info) {
                    names[bundleID] = name
                }
                if let icon = installedIcon(at: appPath, info: info) {
                    icons[bundleID] = icon
                }
            }
        }
        return WCAppCatalog(names: names, icons: icons)
    }
}
