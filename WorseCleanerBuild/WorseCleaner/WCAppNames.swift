import Foundation
import Darwin

struct WCAppCatalog {
    let names: [String: String]
    let diagnostics: String
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
        "com.spotify.client": "Spotify",
        "com.apple.AppStore": "App Store",
        "com.apple.weather": "天气",
        "com.autonavi.amap": "高德地图",
        "com.sf-express.waybillcn": "顺丰速运",
        "com.haier.uhome.Uplus": "海尔智家",
        "cn.gov.tax.its": "个人所得税"
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

    static func catalog(groupID: String, discoveredBundleRoots: [String] = []) -> WCAppCatalog {
        var names = offlineNames
        names.merge(savedNames()) { _, saved in saved }
        let root = "/var/containers/Bundle/Application"
        let fm = FileManager.default
        var readableApps = 0
        var readableBundleRoots = 0
        var enumeratedPaths: Set<String> = []
        func inspectBundleRoot(_ path: String) {
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
                readableApps += 1
                if let name = installedName(at: appPath, info: info) {
                    names[bundleID] = name
                }
            }
        }

        // First try one read-only sandbox extension for the bundle parent.
        // On iOS 27 this may not expose children even when data containers work.
        let rootLease = worse_query(root, groupID, false, true)
        if rootLease > 0 {
            let folders = (try? fm.contentsOfDirectory(atPath: root)) ?? []
            for folder in folders.prefix(2_048) where UUID(uuidString: folder) != nil {
                let path = root + "/" + folder
                let before = readableApps
                inspectBundleRoot(path)
                if readableApps > before {
                    enumeratedPaths.insert(path)
                    readableBundleRoots += 1
                }
            }
            worse_query_release(rootLease)
        }

        // Critical fallback: pathleak finds UUIDs through fsgetpath even when
        // readdir of Bundle/Application is denied. Acquire a scoped token for
        // each *existing* bundle directory and read its Info.plist.
        // This avoids assuming a parent directory token grants child access.
        var perRootGrants = 0
        for rawPath in Set(discoveredBundleRoots).sorted().prefix(2_048) {
            let path = rawPath.replacingOccurrences(of: "/private/var/", with: "/var/")
            guard path.hasPrefix(root + "/"),
                  UUID(uuidString: String(path.dropFirst(root.count + 1))) != nil,
                  !enumeratedPaths.contains(path) else { continue }
            let scopedLease = worse_query(path, groupID, false, true)
            guard scopedLease > 0 else { continue }
            perRootGrants += 1
            let before = readableApps
            inspectBundleRoot(path)
            if readableApps > before { readableBundleRoots += 1 }
            worse_query_release(scopedLease)
        }
        let info = "安装包根目录 token=\(rootLease)，pathleak 发现 \(discoveredBundleRoots.count) 个安装目录，单目录授权 \(perRootGrants)，读到 \(readableApps) 份 Info.plist。列表已关闭图标读取。"
        return WCAppCatalog(names: names, diagnostics: info)
    }
}
