/*
 Adapted from YangJiiii/3105's mcm_bridge.m (GPL-3.0-or-later).
 Only read-only MCM discovery is retained. No MobileHouseArrest identity
 impersonation, container activation, kernel exploit or AFC services.
*/
#import "WCCatalogBridge.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <xpc/xpc.h>

typedef void *(*WCQueryCreate)(void);
typedef void (*WCQuerySetU64)(void *, uint64_t);
typedef void (*WCQuerySetXPC)(void *, xpc_object_t);
typedef void *(*WCQueryGetSingle)(void *);
typedef bool (*WCQueryIterate)(void *, bool (^)(void *));
typedef void (*WCQueryFree)(void *);
typedef const char *(*WCObjectGetString)(void *);

typedef struct {
    WCQueryCreate create;
    WCQuerySetU64 setClass, setFlags, setPart;
    WCQuerySetXPC setIdentifiers;
    WCQueryGetSingle single;
    WCQueryIterate iterate;
    WCQueryFree freeQuery;
    WCObjectGetString getIdentifier, getPath;
} WCCatalogAPI;

static WCCatalogAPI WCLoadAPI(void) {
    WCCatalogAPI api = {0};
    void *handle = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!handle) return api;
#define LOAD(field, name) api.field = (__typeof(api.field))dlsym(handle, name)
    LOAD(create, "container_query_create");
    LOAD(setClass, "container_query_set_class");
    LOAD(setFlags, "container_query_operation_set_flags");
    LOAD(setPart, "container_query_operation_set_part");
    LOAD(setIdentifiers, "container_query_set_identifiers");
    LOAD(single, "container_query_get_single_result");
    LOAD(iterate, "container_query_iterate_results_sync");
    LOAD(freeQuery, "container_query_free");
    LOAD(getIdentifier, "container_object_get_identifier");
    LOAD(getPath, "container_object_get_path");
#undef LOAD
    // Deliberately keep the library loaded while these function pointers are in use.
    return api;
}

static BOOL WCValidIdentifier(NSString *value);

// 3105's AppIconHelper explicitly loads LaunchServices before resolving
// LSApplicationProxy. Class lookup alone may return nil on a cold launch.
static void WCLoadLaunchServices(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *paths[] = {
            "/System/Library/Frameworks/CoreServices.framework/CoreServices",
            "/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices",
            "/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",
        };
        for (NSUInteger i = 0; i < sizeof(paths) / sizeof(paths[0]); ++i) {
            if (dlopen(paths[i], RTLD_LAZY | RTLD_GLOBAL)) break;
        }
    });
}

static id WCInvoke(id object, NSString *method) {
    SEL selector = NSSelectorFromString(method);
    if (!object || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

NSString *WCLookupApplicationName(NSString *bundleID) {
    if (!WCValidIdentifier(bundleID)) return nil;
    WCLoadLaunchServices();
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL selector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!proxyClass || ![proxyClass respondsToSelector:selector]) return nil;
    id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, selector, bundleID);
    if (!proxy) return nil;
    NSString *actualIdentifier = WCInvoke(proxy, @"applicationIdentifier");
    if (!actualIdentifier.length) actualIdentifier = WCInvoke(proxy, @"bundleIdentifier");
    if (actualIdentifier.length && ![actualIdentifier isEqualToString:bundleID]) return nil;

    // Same precedence as 3105: localized Info.plist, bundle Info.plist,
    // then LaunchServices display names.
    NSURL *bundleURL = WCInvoke(proxy, @"bundleURL");
    if ([bundleURL isKindOfClass:NSURL.class]) {
        NSBundle *bundle = [NSBundle bundleWithURL:bundleURL];
        for (NSDictionary *info in @[bundle.localizedInfoDictionary ?: @{}, bundle.infoDictionary ?: @{}]) {
            for (NSString *key in @[@"CFBundleDisplayName", @"CFBundleName"]) {
                NSString *label = info[key];
                if ([label isKindOfClass:NSString.class] && label.length) return label;
            }
        }
    }
    for (NSString *selectorName in @[@"localizedName", @"localizedShortName", @"applicationLabel"]) {
        NSString *label = WCInvoke(proxy, selectorName);
        if ([label isKindOfClass:NSString.class] && label.length) return label;
    }
    return nil;
}

static BOOL WCValidIdentifier(NSString *value) {
    if (value.length < 3 || value.length > 255) return NO;
    NSCharacterSet *chars = [NSCharacterSet characterSetWithCharactersInString:
                            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
    return [value rangeOfCharacterFromSet:chars.invertedSet].location == NSNotFound;
}

static NSString *WCNormalizePath(NSString *path) {
    if ([path hasPrefix:@"/private/var/"]) return [path substringFromIndex:8];
    return path ?: @"";
}

static NSString *WCInfoString(NSDictionary *info, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        id value = info[key];
        if ([value isKindOfClass:NSString.class] && [value length]) return value;
    }
    return nil;
}

// 3105's read-only legacy fallback. On newer builds the symbol may be absent;
// that is a normal unsupported result, not an exploit failure.
static NSDictionary *WCReadMobileInstallationCatalog(void) {
    void *library = dlopen(
        "/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation",
        RTLD_LAZY | RTLD_LOCAL
    );
    void *symbol = dlsym(RTLD_DEFAULT, "MobileInstallationLookup");
    if (!symbol && library) symbol = dlsym(library, "MobileInstallationLookup");
    if (!symbol) return @{};
    NSDictionary *(*lookup)(NSDictionary *, void *) =
        (NSDictionary *(*)(NSDictionary *, void *))symbol;
    for (NSDictionary *options in @[@{@"ApplicationType":@"Any"},
                                    @{@"ApplicationType":@"User"}, @{}]) {
        NSDictionary *result = lookup(options, NULL);
        if ([result isKindOfClass:NSDictionary.class] && result.count) return result;
    }
    return @{};
}

static NSString *WCLookupPath(WCCatalogAPI api, NSString *identifier) {
    if (!api.create || !api.setClass || !api.setIdentifiers || !api.setFlags ||
        !api.single || !api.getPath || !api.freeQuery) return nil;
    void *query = api.create();
    if (!query) return nil;
    api.setClass(query, 2);
    xpc_object_t value = xpc_string_create(identifier.UTF8String);
    api.setIdentifiers(query, value);
#if !OS_OBJECT_USE_OBJC
    xpc_release(value);
#endif
    api.setFlags(query, 0x100000000ULL);
    if (api.setPart) api.setPart(query, 0);
    void *result = api.single(query);
    const char *raw = result ? api.getPath(result) : NULL;
    NSString *path = raw ? [NSString stringWithUTF8String:raw] : nil;
    api.freeQuery(query);
    return WCNormalizePath(path);
}

NSArray<NSDictionary<NSString *, NSString *> *> *WCEnumerateApplicationContainers(NSString **error) {
    WCCatalogAPI api = WCLoadAPI();
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSString *> *> *apps =
        [NSMutableDictionary dictionary];
    NSMutableOrderedSet<NSString *> *identifiers = [NSMutableOrderedSet orderedSet];

    // 3105's read-only MCM class-2 query; do not activate its old exploit.
    if (api.create && api.setClass && api.setFlags && api.iterate &&
        api.getIdentifier && api.freeQuery) {
        void *query = api.create();
        if (query) {
            api.setClass(query, 2);
            api.setFlags(query, 0x100000000ULL);
            if (api.setPart) api.setPart(query, 0);
            api.iterate(query, ^bool(void *object) {
                const char *raw = object ? api.getIdentifier(object) : NULL;
                NSString *identifier = raw ? [NSString stringWithUTF8String:raw] : nil;
                if (WCValidIdentifier(identifier)) [identifiers addObject:identifier];
                return identifiers.count < 1024;
            });
            api.freeQuery(query);
        }
    }

    // Best-effort LaunchServices names and paths, without linking private frameworks.
    WCLoadLaunchServices();
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = WCInvoke(workspaceClass, @"defaultWorkspace");
    NSArray *installed = WCInvoke(workspace, @"allApplications");
    if (![installed isKindOfClass:NSArray.class] || !installed.count) {
        installed = WCInvoke(workspace, @"allInstalledApplications");
    }
    if ([installed isKindOfClass:NSArray.class]) {
        for (id item in installed) {
            NSString *identifier = WCInvoke(item, @"applicationIdentifier");
            if (!identifier.length) identifier = WCInvoke(item, @"bundleIdentifier");
            if (!WCValidIdentifier(identifier)) continue;
            [identifiers addObject:identifier];
            NSString *label = WCInvoke(item, @"localizedName");
            if (!label.length) label = WCInvoke(item, @"localizedShortName");
            if (!label.length) label = WCInvoke(item, @"applicationLabel");
            NSURL *url = WCInvoke(item, @"dataContainerURL");
            NSString *path = [url isKindOfClass:NSURL.class] ? WCNormalizePath(url.path) : @"";
            apps[identifier] = [@{@"bundleID":identifier,
                                  @"name":label.length ? label : identifier,
                                  @"path":path ?: @""} mutableCopy];
        }
    }

    if (apps.count < 20) {
        NSDictionary *legacy = WCReadMobileInstallationCatalog();
        for (NSString *identifier in legacy) {
            if (!WCValidIdentifier(identifier) || apps[identifier]) continue;
            NSDictionary *record = legacy[identifier];
            if (![record isKindOfClass:NSDictionary.class]) continue;
            NSString *label = WCInfoString(record, @[@"CFBundleDisplayName", @"CFBundleName", @"LocalizedName", @"Name"]);
            id urlOrPath = record[@"Container"] ?: record[@"DataContainer"]
                ?: record[@"DataContainerURL"] ?: record[@"ContainerPath"];
            NSString *path = [urlOrPath isKindOfClass:NSURL.class]
                ? [urlOrPath path] : ([urlOrPath isKindOfClass:NSString.class] ? urlOrPath : @"");
            [identifiers addObject:identifier];
            apps[identifier] = [@{@"bundleID":identifier,
                                  @"name":label.length ? label : identifier,
                                  @"path":WCNormalizePath(path)} mutableCopy];
        }
    }

    for (NSString *identifier in identifiers) {
        NSString *path = WCLookupPath(api, identifier);
        NSMutableDictionary *record = apps[identifier] ?: [@{
            @"bundleID":identifier, @"name":identifier, @"path":@""} mutableCopy];
        if (path.length) record[@"path"] = path;
        apps[identifier] = record;
    }

    NSMutableArray<NSDictionary<NSString *, NSString *> *> *result = [NSMutableArray array];
    for (NSDictionary *record in apps.allValues) {
        if ([record[@"path"] length]) [result addObject:record];
    }
    [result sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    if (!result.count && error) {
        *error = @"MCM 与 LaunchServices 未返回可用容器路径；可手动填写已知 App 容器 UUID 路径。";
    }
    return result;
}
