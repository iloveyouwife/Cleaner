import Foundation
import Darwin

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

    static func catalog(groupID: String) -> [String: String] {
        var names = offlineNames
        let root = "/var/containers/Bundle/Application"
        // This mirrors 3105's app-bundle metadata catalog. It is read-only.
        // A dedicated App Group remains mandatory because worse_query
        // temporarily replaces its Library/Caches while acquiring a token.
        let lease = worse_query(root, groupID, false, true)
        guard lease > 0 else { return names }
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
                let localized = Bundle(path: appPath)?.localizedInfoDictionary ?? [:]
                let name = (localized["CFBundleDisplayName"] as? String)
                    ?? (localized["CFBundleName"] as? String)
                    ?? (info["CFBundleDisplayName"] as? String)
                    ?? (info["CFBundleName"] as? String)
                    ?? ""
                if !name.isEmpty { names[bundleID] = name }
            }
        }
        return names
    }
}
