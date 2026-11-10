/*
 * Cleaner read-only container discovery.
 * Inspired by WQFiles (kolbicz/WQFiles) and the KAMUI inode enumeration
 * approach. GPL-3.0-or-later; see ../LICENSE and the README acknowledgments.
 *
 * Only the two app-owned data-container roots are collected. Internal daemon
 * and system containers are deliberately excluded from the cleaner.
 */

#import "WCContainerDiscovery.h"
#import <sys/fsgetpath.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>

static NSString *const kWCAppRoot = @"/private/var/mobile/Containers/Data/Application";
static NSString *const kWCExtensionRoot = @"/private/var/mobile/Containers/Data/PluginKitPlugin";
static const uint64_t kWCInodeMargin = 100000;
static const uint64_t kWCChunkSize = 32768;
static const NSTimeInterval kWCFullRefreshAfter = 7 * 24 * 3600;

static NSString *WCIndexPath(void) {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                          NSUserDomainMask, YES).firstObject;
    if (!base.length) return nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:base
                                   withIntermediateDirectories:YES attributes:nil error:nil]) return nil;
    return [base stringByAppendingPathComponent:@"CleanerContainerIndex.plist"];
}

static BOOL WCProbeDataVolume(fsid_t *fsid, uint64_t *inode) {
    NSString *name = [NSString stringWithFormat:@".wc-inode-%@", [NSUUID UUID].UUIDString];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0) return NO;
    struct stat st = {0};
    struct statfs fs = {0};
    BOOL ok = fstat(fd, &st) == 0 && fstatfs(fd, &fs) == 0;
    close(fd);
    unlink(path.fileSystemRepresentation);
    if (!ok || st.st_ino == 0 || (uint64_t)st.st_ino > INT64_MAX - kWCInodeMargin) return NO;
    *fsid = fs.f_fsid;
    *inode = (uint64_t)st.st_ino;
    return YES;
}

static BOOL WCIsDirectUUIDChild(const char *path, const char *root, size_t len) {
    if (strnlen(path, PATH_MAX) <= len + 1) return NO;
    if (strncmp(path, root, len) != 0 || path[len] != '/') return NO;
    const char *last = path + len + 1;
    if (!*last || strchr(last, '/')) return NO;
    NSString *identifier = [NSString stringWithUTF8String:last];
    return identifier && [[NSUUID alloc] initWithUUIDString:identifier] != nil;
}

static NSMutableDictionary<NSString *, NSNumber *> *WCVerifiedIndex(
    NSDictionary *saved, fsid_t fsid, NSString *root
) {
    NSMutableDictionary<NSString *, NSNumber *> *verified = [NSMutableDictionary new];
    if (![saved isKindOfClass:NSDictionary.class]) return verified;
    const char *rootBytes = root.fileSystemRepresentation;
    size_t rootLength = strlen(rootBytes);
    char resolved[PATH_MAX];
    for (id path in saved) {
        NSNumber *value = saved[path];
        if (![path isKindOfClass:NSString.class] || ![value isKindOfClass:NSNumber.class]) continue;
        NSString *candidate = path;
        if (!WCIsDirectUUIDChild(candidate.fileSystemRepresentation, rootBytes, rootLength)) continue;
        fsid_t volume = fsid;
        if (fsgetpath(resolved, sizeof(resolved), &volume, value.unsignedLongLongValue) > 0 &&
            strcmp(resolved, candidate.fileSystemRepresentation) == 0) {
            verified[candidate] = value;
        }
    }
    return verified;
}

NSDictionary<NSString *, id> *WCDiscoverDataContainers(
    BOOL forceFullScan, void (^progress)(uint64_t done, uint64_t total)
) {
    fsid_t volume = {0};
    uint64_t probeInode = 0;
    if (!WCProbeDataVolume(&volume, &probeInode)) return nil;
    const uint64_t upper = probeInode + kWCInodeMargin;
    const char *appPrefix = kWCAppRoot.fileSystemRepresentation;
    const char *extensionPrefix = kWCExtensionRoot.fileSystemRepresentation;
    const size_t appLength = strlen(appPrefix), extensionLength = strlen(extensionPrefix);

    NSString *indexPath = WCIndexPath();
    NSDictionary *saved = indexPath ? [NSDictionary dictionaryWithContentsOfFile:indexPath] : nil;
    NSNumber *version = saved[@"version"];
    NSNumber *fs0 = saved[@"fs0"], *fs1 = saved[@"fs1"];
    NSNumber *priorProbe = saved[@"probe"], *fullAt = saved[@"fullAt"];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    BOOL reusable = !forceFullScan && [version isKindOfClass:NSNumber.class] &&
        version.integerValue == 1 && [fs0 isKindOfClass:NSNumber.class] &&
        [fs1 isKindOfClass:NSNumber.class] &&
        fs0.intValue == volume.val[0] && fs1.intValue == volume.val[1] &&
        [priorProbe isKindOfClass:NSNumber.class] &&
        priorProbe.unsignedLongLongValue > 0 && priorProbe.unsignedLongLongValue <= probeInode &&
        [fullAt isKindOfClass:NSNumber.class] && now >= fullAt.doubleValue &&
        now - fullAt.doubleValue < kWCFullRefreshAfter &&
        [saved[@"apps"] isKindOfClass:NSDictionary.class] &&
        [saved[@"extensions"] isKindOfClass:NSDictionary.class];

    NSMutableDictionary<NSString *, NSNumber *> *apps = reusable
        ? WCVerifiedIndex(saved[@"apps"], volume, kWCAppRoot) : [NSMutableDictionary new];
    NSMutableDictionary<NSString *, NSNumber *> *extensions = reusable
        ? WCVerifiedIndex(saved[@"extensions"], volume, kWCExtensionRoot) : [NSMutableDictionary new];
    uint64_t first = reusable ? priorProbe.unsignedLongLongValue + 1 : 1;
    uint64_t total = first <= upper ? upper - first + 1 : 0;

    NSLock *lock = [NSLock new];
    __block uint64_t next = first, finished = 0;
    __block NSInteger lastPercent = -1;
    NSUInteger cores = NSProcessInfo.processInfo.activeProcessorCount;
    // Up to six workers on a six-core iPhone. Workers above a thermal limit
    // retire after their current chunk; the remaining workers still finish
    // every unclaimed chunk. This avoids an unbounded hot full-volume scan.
    size_t workers = MAX((NSUInteger)1, MIN((NSUInteger)6, cores));
    dispatch_apply(workers, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(size_t worker) {
        fsid_t fsid = volume;
        char buffer[PATH_MAX];
        for (;;) {
            NSProcessInfoThermalState thermal = NSProcessInfo.processInfo.thermalState;
            if ((thermal >= NSProcessInfoThermalStateSerious && worker >= 2) ||
                (thermal >= NSProcessInfoThermalStateFair && worker >= 4)) return;
            [lock lock];
            uint64_t chunkFirst = next;
            if (next <= upper) next += MIN(kWCChunkSize, upper - next + 1);
            [lock unlock];
            if (chunkFirst > upper) break;
            uint64_t chunkLast = MIN(chunkFirst + kWCChunkSize - 1, upper);
            NSMutableDictionary<NSString *, NSNumber *> *localApps = [NSMutableDictionary new];
            NSMutableDictionary<NSString *, NSNumber *> *localExtensions = [NSMutableDictionary new];
            for (uint64_t ino = chunkFirst; ino <= chunkLast; ++ino) {
                if (fsgetpath(buffer, sizeof(buffer), &fsid, ino) <= 0) continue;
                if (WCIsDirectUUIDChild(buffer, appPrefix, appLength)) {
                    NSString *path = [NSString stringWithUTF8String:buffer];
                    if (path) localApps[path] = @(ino);
                } else if (WCIsDirectUUIDChild(buffer, extensionPrefix, extensionLength)) {
                    NSString *path = [NSString stringWithUTF8String:buffer];
                    if (path) localExtensions[path] = @(ino);
                }
            }
            BOOL shouldReport = NO;
            uint64_t snapshot = 0;
            [lock lock];
            [apps addEntriesFromDictionary:localApps];
            [extensions addEntriesFromDictionary:localExtensions];
            finished += chunkLast - chunkFirst + 1;
            snapshot = finished;
            NSInteger percent = total ? (NSInteger)(finished * 100 / total) : 100;
            if (percent != lastPercent) { lastPercent = percent; shouldReport = YES; }
            [lock unlock];
            if (progress && shouldReport) progress(snapshot, total);
        }
    });

    fsid_t afterVolume = {0};
    uint64_t afterProbe = 0;
    BOOL reachedEnd = WCProbeDataVolume(&afterVolume, &afterProbe) &&
        memcmp(&afterVolume, &volume, sizeof(fsid_t)) == 0 && afterProbe <= upper;
    if (indexPath) {
        NSDictionary *index = @{
            @"version": @1, @"fs0": @(volume.val[0]), @"fs1": @(volume.val[1]),
            @"probe": @(probeInode), @"fullAt": @(reusable ? fullAt.doubleValue : now),
            @"apps": apps, @"extensions": extensions
        };
        [index writeToFile:indexPath atomically:YES];
    }
    return @{
        @"apps": [apps.allKeys sortedArrayUsingSelector:@selector(compare:)],
        @"extensions": [extensions.allKeys sortedArrayUsingSelector:@selector(compare:)],
        @"incremental": @(reusable), @"scanned": @(total), @"upper": @(upper),
        @"completeBound": @(reachedEnd)
    };
}
