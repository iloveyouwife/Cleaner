//
//  pathleak.m
//  worse_query
//
//  Created by Taj C on 9/2/26.
//

/*
     pathleak - The dumbest arbitrary path enumeration.
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
#include <sys/fsgetpath.h>
#include <sys/mount.h>

// Bounded multi-volume inode enumeration via fsgetpath for direct child directories.
NSArray<NSString *> *pathleak_multiple(NSArray<NSString *> *paths, uint64_t max_inode) {
    // Group requested roots by APFS volume fsid so each distinct volume is walked once.
    if (!paths.count || max_inode < 1) return nil;
    NSMutableArray<NSValue *> *volumeIDs = [NSMutableArray array];
    NSMutableArray<NSMutableArray<NSData *> *> *volumePrefixes = [NSMutableArray array];
    for (NSString *path in paths) {
        if (![path isKindOfClass:NSString.class] || !path.length) continue;
        NSString *trimmed = path;
        while (trimmed.length > 1 && [trimmed hasSuffix:@"/"]) {
            trimmed = [trimmed substringToIndex:trimmed.length - 1];
        }
        NSData *prefix = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
        if (prefix.length == 0 || prefix.length >= PATH_MAX - 2) continue;

        struct statfs sfs;
        // statfs need not allow readdir; try the parent when lookup of the
        // protected leaf fails. Do not infer an fsid from a different root.
        NSString *probe = trimmed;
        BOOL foundVolume = NO;
        for (NSUInteger attempt = 0; attempt < 3; ++attempt) {
            if (statfs(probe.fileSystemRepresentation, &sfs) == 0) {
                foundVolume = YES;
                break;
            }
            NSString *parent = [probe stringByDeletingLastPathComponent];
            if ([parent isEqualToString:probe]) break;
            probe = parent;
        }
        if (!foundVolume) continue;

        NSUInteger volume = NSNotFound;
        for (NSUInteger i = 0; i < volumeIDs.count; ++i) {
            fsid_t saved;
            [volumeIDs[i] getValue:&saved];
            if (memcmp(&saved, &sfs.f_fsid, sizeof(fsid_t)) == 0) {
                volume = i;
                break;
            }
        }
        if (volume == NSNotFound) {
            volume = volumeIDs.count;
            [volumeIDs addObject:[NSValue valueWithBytes:&sfs.f_fsid objCType:@encode(fsid_t)]];
            [volumePrefixes addObject:[NSMutableArray array]];
        }
        [volumePrefixes[volume] addObject:prefix];
    }
    if (!volumeIDs.count) return nil;
    
    NSFileManager *files = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    char buffer[PATH_MAX];
    
    for (NSUInteger volume = 0; volume < volumeIDs.count; ++volume) {
        fsid_t fsid;
        [volumeIDs[volume] getValue:&fsid];
        NSArray<NSData *> *prefixes = volumePrefixes[volume];
        // One inode walk per distinct volume, not one for every root.
        for (uint64_t inode = 1; inode <= max_inode; ++inode) {
            ssize_t n = fsgetpath(buffer, sizeof(buffer), &fsid, inode);
            if (n <= 0) continue;
            for (NSData *prefix in prefixes) {
                size_t len = prefix.length;
                if (n <= (ssize_t)len || strncmp(buffer, prefix.bytes, len) != 0) continue;
                if (buffer[len] != '/' || strchr(buffer + len + 1, '/')) continue;
                NSString *string = [files stringWithFileSystemRepresentation:buffer length:strlen(buffer)];
                if (string) [result addObject:string];
                break;
            }
        }
    }
    return result;
}

