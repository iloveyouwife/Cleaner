#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Discovers data containers without changing any other app's files. A missing
// or truncated result must never be presented as a complete installed-app list.
NSDictionary<NSString *, id> * _Nullable WCDiscoverDataContainers(
    BOOL forceFullScan,
    void (^ _Nullable progress)(uint64_t done, uint64_t total)
);

// Read-only, bounded lookup of lsd's CSStore2 index. Unlike the complete
// inode discovery above, this searches recent inode IDs for at most 20 s.
// A returned path is only a candidate; the Swift parser must validate it.
NSString * _Nullable WCFindLaunchServicesStoreQuick(void);

// Read the *verified* results of the last full/incremental scan, if any.
// Fast database discovery must not silently discard previously known UUID
// containers that LaunchServices does not register.
NSDictionary<NSString *, NSArray<NSString *> *> * _Nullable WCReadCachedDataContainers(void);

NS_ASSUME_NONNULL_END
