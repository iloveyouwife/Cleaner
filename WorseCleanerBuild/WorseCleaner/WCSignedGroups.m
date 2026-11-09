#import "WCSignedGroups.h"
#import <dlfcn.h>

typedef CFTypeRef (*WCSecTaskCreateFromSelf)(CFAllocatorRef);
typedef CFTypeRef (*WCSecTaskCopyValueForEntitlement)(CFTypeRef, CFStringRef, CFErrorRef *);

NSArray<NSString *> *WCSignedAppGroups(void) {
    void *security = dlopen("/System/Library/Frameworks/Security.framework/Security",
                            RTLD_NOW | RTLD_LOCAL);
    if (!security) return @[];
    WCSecTaskCreateFromSelf makeTask =
        (WCSecTaskCreateFromSelf)dlsym(security, "SecTaskCreateFromSelf");
    WCSecTaskCopyValueForEntitlement copyValue =
        (WCSecTaskCopyValueForEntitlement)dlsym(security, "SecTaskCopyValueForEntitlement");
    if (!makeTask || !copyValue) {
        dlclose(security);
        return @[];
    }
    CFTypeRef task = makeTask(kCFAllocatorDefault);
    if (!task) {
        dlclose(security);
        return @[];
    }
    CFTypeRef value = copyValue(
        task, CFSTR("com.apple.security.application-groups"), NULL
    );
    CFRelease(task);
    dlclose(security);
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
