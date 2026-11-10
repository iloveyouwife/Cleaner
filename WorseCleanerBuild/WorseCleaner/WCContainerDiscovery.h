#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Discovers data containers without changing any other app's files. A missing
// or truncated result must never be presented as a complete installed-app list.
NSDictionary<NSString *, id> * _Nullable WCDiscoverDataContainers(
    BOOL forceFullScan,
    void (^ _Nullable progress)(uint64_t done, uint64_t total)
);

NS_ASSUME_NONNULL_END
