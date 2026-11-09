#import "WCSignedGroups.h"
#import <Security/Security.h>

NSArray<NSString *> *WCSignedAppGroups(void) {
    SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task) return @[];
    CFTypeRef value = SecTaskCopyValueForEntitlement(
        task, CFSTR("com.apple.security.application-groups"), NULL
    );
    CFRelease(task);
    if (!value) return @[];
    NSArray *groups = CFGetTypeID(value) == CFArrayGetTypeID()
        ? [(__bridge NSArray *)value copy] : @[];
    CFRelease(value);
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (id candidate in groups) {
        if ([candidate isKindOfClass:NSString.class] &&
            [candidate hasPrefix:@"group."]) {
            [result addObject:candidate];
        }
    }
    return result;
}
