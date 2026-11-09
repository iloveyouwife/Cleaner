#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Read-only container discovery. Does not activate an MCM sandbox extension.
/// Each dictionary contains bundleID, name, path.
NSArray<NSDictionary<NSString *, NSString *> *> *WCEnumerateApplicationContainers(NSString * _Nullable * _Nullable error);
NSString * _Nullable WCLookupApplicationName(NSString *bundleID);
/// Best-effort installed application icon from the same on-device
/// LaunchServices proxy used by 3105. Never fetches third-party icons online.
NSData * _Nullable WCLookupApplicationIconData(NSString *bundleID);

NS_ASSUME_NONNULL_END
