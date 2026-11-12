#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <sys/types.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

/// iOS 15.4-compatible UIKit and Objective-C only.
/// No SwiftUI, Swift runtime, worse_query, file writes or deletion.
@interface LegacyProbeController : UIViewController
@end

@interface LegacyProbeController ()
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIButton *scanButton;
@end

@implementation LegacyProbeController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Cleaner Legacy";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    UILabel *intro = [UILabel new];
    intro.translatesAutoresizingMaskIntoConstraints = NO;
    intro.text = @"iOS 15.4 · TrollStore 只读权限检测";
    intro.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    intro.textColor = [UIColor labelColor];
    intro.adjustsFontForContentSizeCategory = YES;
    intro.numberOfLines = 0;
    [self.view addSubview:intro];

    UIButton *scan = [UIButton buttonWithType:UIButtonTypeSystem];
    scan.translatesAutoresizingMaskIntoConstraints = NO;
    [scan setTitle:@"检查 App 容器读取权限" forState:UIControlStateNormal];
    scan.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    scan.titleLabel.adjustsFontForContentSizeCategory = YES;
    scan.layer.cornerRadius = 10;
    scan.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    [scan addTarget:self action:@selector(runReadOnlyProbe) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:scan];
    self.scanButton = scan;

    UITextView *logView = [UITextView new];
    logView.translatesAutoresizingMaskIntoConstraints = NO;
    logView.editable = NO;
    logView.selectable = YES;
    logView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    logView.textColor = [UIColor labelColor];
    logView.layer.cornerRadius = 10;
    logView.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    logView.textContainerInset = UIEdgeInsetsMake(12, 10, 12, 10);
    [self.view addSubview:logView];
    self.logView = logView;

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [intro.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [intro.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [intro.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
        [scan.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [scan.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [scan.topAnchor constraintEqualToAnchor:intro.bottomAnchor constant:14],
        [scan.heightAnchor constraintGreaterThanOrEqualToConstant:48],
        [logView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [logView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [logView.topAnchor constraintEqualToAnchor:scan.bottomAnchor constant:14],
        [logView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16]
    ]];

    self.logView.text = [NSString stringWithFormat:
        @"启动成功\niOS: %@\nUID/EUID: %u/%u\n\n本版本无 SwiftUI，无漏洞授权，不会修改或删除文件。\n\n点击上方按钮检查。\n",
        [UIDevice currentDevice].systemVersion, getuid(), geteuid()];
}

static NSString *DirectoryStatus(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) {
        int error = errno;
        if (error == ENOENT) { return @"不存在"; }
        return [NSString stringWithFormat:@"errno=%d", error];
    }
    // Opening a directory does not mean enumeration is allowed: verify readdir.
    int duplicate = dup(fd);
    close(fd);
    if (duplicate < 0) { return [NSString stringWithFormat:@"dup errno=%d", errno]; }
    DIR *directory = fdopendir(duplicate);
    if (!directory) {
        int error = errno;
        close(duplicate);
        return [NSString stringWithFormat:@"fdopendir errno=%d", error];
    }
    errno = 0;
    (void)readdir(directory);
    int readError = errno;
    closedir(directory);
    if (readError != 0) {
        return [NSString stringWithFormat:@"readdir errno=%d", readError];
    }
    return @"可读取";
}

- (void)runReadOnlyProbe {
    self.scanButton.enabled = NO;
    self.logView.text = @"正在只读枚举数据容器…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *base = @"/var/mobile/Containers/Data/Application";
        NSError *error = nil;
        NSArray<NSString *> *entries =
            [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:&error];
        if (!entries) {
            base = @"/private/var/mobile/Containers/Data/Application";
            error = nil;
            entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:&error];
        }
        NSMutableString *result = [NSMutableString string];
        [result appendFormat:@"iOS: %@  UID/EUID: %u/%u\n",
            [UIDevice currentDevice].systemVersion, getuid(), geteuid()];
        [result appendString:@"模式：纯 UIKit + Objective-C / 只读\n"];
        if (!entries) {
            [result appendFormat:@"无法枚举 App 数据目录：%@\n", error.localizedDescription ?: @"未知错误"];
            [result appendString:@"请确认 IPA 是否经 TrollStore 安装，查看签名与崩溃日志。\n"];
        } else {
            NSUUID *uuid = nil;
            NSMutableArray<NSString *> *containers = [NSMutableArray array];
            for (NSString *entry in entries) {
                uuid = [[NSUUID alloc] initWithUUIDString:entry];
                if (uuid != nil) { [containers addObject:entry]; }
            }
            [containers sortUsingSelector:@selector(compare:)];
            NSUInteger rootOK = 0, cachesOK = 0, tmpOK = 0;
            for (NSUInteger i = 0; i < containers.count; i++) {
                NSString *uuidPart = containers[i];
                NSString *root = [base stringByAppendingPathComponent:uuidPart];
                NSString *r = DirectoryStatus(root);
                NSString *c = DirectoryStatus([root stringByAppendingPathComponent:@"Library/Caches"]);
                NSString *t = DirectoryStatus([root stringByAppendingPathComponent:@"tmp"]);
                rootOK += [r isEqualToString:@"可读取"];
                cachesOK += [c isEqualToString:@"可读取"];
                tmpOK += [t isEqualToString:@"可读取"];
                if (i < 20) {
                    [result appendFormat:@"%@\n  根=%@ Caches=%@ tmp=%@\n",
                        uuidPart, r, c, t];
                }
            }
            [result insertString:[NSString stringWithFormat:
                @"目录：%@\n发现=%lu 根可读=%lu Caches可读=%lu tmp可读=%lu\n\n",
                base, (unsigned long)containers.count, (unsigned long)rootOK,
                (unsigned long)cachesOK, (unsigned long)tmpOK] atIndex:0];
            if (containers.count > 20) {
                [result appendFormat:@"\n其余 %lu 个容器省略明细。\n",
                    (unsigned long)(containers.count - 20)];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.logView.text = result;
            self.scanButton.enabled = YES;
        });
    });
}
@end

@interface LegacyProbeAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation LegacyProbeAppDelegate
- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController =
        [[UINavigationController alloc] initWithRootViewController:[LegacyProbeController new]];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char * argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([LegacyProbeAppDelegate class]));
    }
}
