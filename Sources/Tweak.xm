#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <spawn.h>
#import <sys/wait.h>

static NSString * const YYSPItemKey = @"com.yuyu.siyubao.voicepack";
static NSString * const YYSPVoicePackDirName = @"YuyuSiyubao/VoicePacks";
static NSString * const YYSPThemeRootDirName = @"YuyuSiyubao/Theme";
static NSString * const YYSPThemeRuntimeDirName = @"YuyuSiyubao/Theme/Runtime";
static NSString * const YYSPThemePackagesDirName = @"YuyuSiyubao/Theme/Packages";
static NSString * const YYSPThemeSourcePlistName = @".yysp_theme_source.plist";

#if YYSP_DEBUG
#define YYSPLog(fmt, ...) NSLog((@"[屿宇私域宝] " fmt), ##__VA_ARGS__)
#else
#define YYSPLog(fmt, ...)
#endif

extern char **environ;

@interface KSIMChatMorePanelItem : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *localIconName;
@property (nonatomic, assign) NSUInteger page;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *titleCN;
@property (nonatomic, retain) UIColor *titleColor;
@end

@interface KSIMNTChatMoreUIState : NSObject
@property (nonatomic, copy) NSArray *items;
@end

@interface KSIMNTChatMorePanelDidClickedIconIntent : NSObject
@property (nonatomic, assign) NSUInteger index;
@property (nonatomic, retain) KSIMChatMorePanelItem *panelItem;
@end

@interface KSIMNTChatMoreViewModel : NSObject
@property (nonatomic, weak) id injector;
- (id)sendMessageService;
@end

@interface KSIMNTChatVoiceViewModel : NSObject
- (id)initWithInjector:(id)injector;
- (void)handleStopActionWithFileURL:(id)fileURL duration:(NSInteger)duration error:(id)error;
@end

@interface KSIMVoiceInfo : NSObject
@property (nonatomic, copy) NSString *filePath;
@property (nonatomic) NSInteger duration;
@property (nonatomic) BOOL isLocal;
- (id)initWithFilePath:(id)filePath duration:(NSInteger)duration;
@end

@interface KSIMNTChatVoiceUIState : NSObject
@property (nonatomic) NSInteger duration;
@property (nonatomic, copy) NSString *durationText;
@end

@interface KSIMNTChatVoiceContentView : UIView
@property (nonatomic, retain) UILabel *durationLabel;
- (void)updateUIWithFrameEntity:(id)frameEntity uiState:(id)uiState;
@end

@interface KSCommentVoiceInfo : NSObject
@property (nonatomic) BOOL didWeakNetOptimize;
@property (nonatomic) NSInteger duration;
@property (nonatomic, copy) NSString *filePath;
@end

@interface KSCommentVoiceCommentPanelView : UIView
@property (nonatomic, retain) UIButton *closeButton;
@property (nonatomic, weak) id delegate;
- (void)setupViewHierarchy;
- (void)voiceCommentRecorderDidFinishWithVoiceInfo:(id)voiceInfo;
@end

@interface YYSPAudioPreviewDelegate : NSObject <AVAudioPlayerDelegate>
@end

typedef NS_ENUM(NSUInteger, YYSPSendMode) {
    YYSPSendModeVoiceViewModel = 0,
    YYSPSendModeServicePath = 1,
    YYSPSendModeServiceURL = 2,
    YYSPSendModeServiceVoiceInfo = 3,
};

static NSString *YYSPClassName(id object) {
    return object ? NSStringFromClass([object class]) : @"<nil>";
}

static NSMutableArray *YYSPKeepAliveObjects(void) {
    static NSMutableArray *objects = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        objects = [NSMutableArray array];
    });
    return objects;
}

static AVAudioPlayer *YYSPPreviewPlayer;
static YYSPAudioPreviewDelegate *YYSPPreviewDelegate;
static char YYSPCommentVoicePackButtonKey;

static void YYSPShowAlert(NSString *title, NSString *message);

@implementation YYSPAudioPreviewDelegate

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    YYSPLog(@"preview finished successfully=%@", flag ? @"YES" : @"NO");
    if (player == YYSPPreviewPlayer) {
        YYSPPreviewPlayer = nil;
    }
}

- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(NSError *)error {
    YYSPLog(@"preview decode error player=%@ error=%@", player, error);
    if (player == YYSPPreviewPlayer) {
        YYSPPreviewPlayer = nil;
    }
}

@end

static void YYSPKeepAliveTemporarily(id object, NSTimeInterval seconds) {
    if (!object) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableArray *objects = YYSPKeepAliveObjects();
        [objects addObject:object];
        YYSPLog(@"keep alive %@ for %.0fs count=%lu", YYSPClassName(object), seconds, (unsigned long)objects.count);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [objects removeObject:object];
            YYSPLog(@"release keep alive %@ count=%lu", YYSPClassName(object), (unsigned long)objects.count);
        });
    });
}

static BOOL YYSPIsAweme(void) {
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    return [bundleID isEqualToString:@"com.ss.iphone.ugc.Aweme"];
}

static NSString *YYSPDocumentsPath(void) {
    NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return dirs.firstObject ?: NSTemporaryDirectory();
}

static NSString *YYSPDirectoryForRelativeName(NSString *relativeName) {
    NSString *path = [YYSPDocumentsPath() stringByAppendingPathComponent:relativeName];
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    return path;
}

static NSString *YYSPThemeRuntimeDirectory(void) {
    return YYSPDirectoryForRelativeName(YYSPThemeRuntimeDirName);
}

static NSString *YYSPThemePackagesDirectory(void) {
    return YYSPDirectoryForRelativeName(YYSPThemePackagesDirName);
}

static void YYSPClearThemeCache(void);

static BOOL YYSPIsThemePackageName(NSString *name) {
    NSString *lower = name.lowercaseString;
    return [lower hasSuffix:@".zip"] || [lower hasSuffix:@".theme"] || [lower hasSuffix:@".theme.zip"];
}

static BOOL YYSPRunDittoUnzip(NSString *zipPath, NSString *destinationPath) {
    NSArray<NSString *> *dittoCandidates = @[@"/var/jb/usr/bin/ditto", @"/usr/bin/ditto", @"/bin/ditto"];
    NSString *dittoPath = nil;
    for (NSString *candidate in dittoCandidates) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:candidate]) {
            dittoPath = candidate;
            break;
        }
    }
    if (dittoPath.length == 0) {
        YYSPLog(@"ditto missing, cannot import theme package");
        return NO;
    }

    const char *argv[] = {
        dittoPath.fileSystemRepresentation,
        "-x",
        "-k",
        zipPath.fileSystemRepresentation,
        destinationPath.fileSystemRepresentation,
        NULL
    };
    pid_t pid = 0;
    int status = 0;
    int result = posix_spawn(&pid, dittoPath.fileSystemRepresentation, NULL, NULL, (char * const *)argv, environ);
    if (result != 0) {
        YYSPLog(@"posix_spawn ditto failed=%d", result);
        return NO;
    }
    if (waitpid(pid, &status, 0) < 0) {
        YYSPLog(@"waitpid ditto failed");
        return NO;
    }
    BOOL ok = WIFEXITED(status) && WEXITSTATUS(status) == 0;
    YYSPLog(@"theme package unzip %@ status=%d ok=%@", zipPath.lastPathComponent, status, ok ? @"YES" : @"NO");
    return ok;
}

static NSString *YYSPNewestThemePackagePath(void) {
    NSString *packagesDir = YYSPThemePackagesDirectory();
    NSArray<NSString *> *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:packagesDir error:nil] ?: @[];
    NSString *newest = nil;
    NSDate *newestDate = nil;
    for (NSString *name in names) {
        if (!YYSPIsThemePackageName(name)) {
            continue;
        }
        NSString *path = [packagesDir stringByAppendingPathComponent:name];
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        NSDate *date = attrs[NSFileModificationDate] ?: [NSDate distantPast];
        if (!newest || [date compare:newestDate] == NSOrderedDescending) {
            newest = path;
            newestDate = date;
        }
    }
    return newest;
}

static NSString *YYSPCurrentThemeSignature(void) {
    NSString *sourcePath = [YYSPThemeRuntimeDirectory() stringByAppendingPathComponent:YYSPThemeSourcePlistName];
    NSDictionary *source = [NSDictionary dictionaryWithContentsOfFile:sourcePath];
    return source[@"signature"];
}

static NSString *YYSPThemePackageSignature(NSString *path) {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSNumber *size = attrs[NSFileSize] ?: @0;
    NSDate *date = attrs[NSFileModificationDate] ?: [NSDate distantPast];
    return [NSString stringWithFormat:@"%@:%@:%@", path.lastPathComponent, size, @((long long)date.timeIntervalSince1970)];
}

static void YYSPImportNewestThemePackageIfNeeded(void) {
    if (!YYSPIsAweme()) {
        return;
    }
    NSString *packagePath = YYSPNewestThemePackagePath();
    if (packagePath.length == 0) {
        return;
    }
    NSString *signature = YYSPThemePackageSignature(packagePath);
    if ([signature isEqualToString:YYSPCurrentThemeSignature()]) {
        return;
    }

    NSString *runtimeDir = YYSPThemeRuntimeDirectory();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *oldNames = [fm contentsOfDirectoryAtPath:runtimeDir error:nil] ?: @[];
    for (NSString *name in oldNames) {
        [fm removeItemAtPath:[runtimeDir stringByAppendingPathComponent:name] error:nil];
    }
    [fm createDirectoryAtPath:runtimeDir withIntermediateDirectories:YES attributes:nil error:nil];

    BOOL ok = YYSPRunDittoUnzip(packagePath, runtimeDir);
    if (!ok) {
        return;
    }
    NSDictionary *source = @{
        @"signature": signature,
        @"zip_path": packagePath,
        @"modified_at": @((long long)[[NSDate date] timeIntervalSince1970]),
        @"file_size": ([[fm attributesOfItemAtPath:packagePath error:nil] objectForKey:NSFileSize] ?: @0)
    };
    [source writeToFile:[runtimeDir stringByAppendingPathComponent:YYSPThemeSourcePlistName] atomically:YES];
    YYSPClearThemeCache();
}

static NSArray<NSString *> *YYSPThemeLookupNames(NSString *imageName) {
    if (imageName.length == 0) {
        return @[];
    }
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSString *ext = imageName.pathExtension;
    NSString *base = ext.length > 0 ? [imageName stringByDeletingPathExtension] : imageName;
    NSArray<NSString *> *extensions = ext.length > 0 ? @[ext] : @[@"png", @"jpg", @"jpeg", @"webp"];

    for (NSString *candidateExt in extensions) {
        [names addObject:[base stringByAppendingPathExtension:candidateExt]];
        [names addObject:[[base stringByAppendingString:@"@3x"] stringByAppendingPathExtension:candidateExt]];
        [names addObject:[[base stringByAppendingString:@"@2x"] stringByAppendingPathExtension:candidateExt]];
    }
    return names;
}

static NSString *YYSPThemePathForImageName(NSString *imageName) {
    NSString *runtimeDir = YYSPThemeRuntimeDirectory();
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *lookupName in YYSPThemeLookupNames(imageName)) {
        NSArray<NSString *> *candidates = @[
            [runtimeDir stringByAppendingPathComponent:lookupName],
            [[runtimeDir stringByAppendingPathComponent:@"Images"] stringByAppendingPathComponent:lookupName],
            [[runtimeDir stringByAppendingPathComponent:@"Icons"] stringByAppendingPathComponent:lookupName],
            [[runtimeDir stringByAppendingPathComponent:@"Bundles/com.ss.iphone.ugc.Aweme"] stringByAppendingPathComponent:lookupName],
            [[runtimeDir stringByAppendingPathComponent:@"Bundles/Aweme"] stringByAppendingPathComponent:lookupName],
        ];
        for (NSString *path in candidates) {
            if ([fm fileExistsAtPath:path]) {
                return path;
            }
        }
    }
    return nil;
}

static NSCache *YYSPThemeImageCache(void) {
    static NSCache *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.name = @"YYSPThemeImageCache";
    });
    return cache;
}

static void YYSPClearThemeCache(void) {
    [YYSPThemeImageCache() removeAllObjects];
}

static UIImage *YYSPThemeImageForName(NSString *imageName) {
    if (!YYSPIsAweme() || imageName.length == 0) {
        return nil;
    }
    NSString *path = YYSPThemePathForImageName(imageName);
    if (path.length == 0) {
        return nil;
    }
    UIImage *cached = [YYSPThemeImageCache() objectForKey:path];
    if (cached) {
        return cached;
    }
    UIImage *image = [UIImage imageWithContentsOfFile:path];
    if (image) {
        [YYSPThemeImageCache() setObject:image forKey:path];
        YYSPLog(@"theme image hit %@ -> %@", imageName, path.lastPathComponent);
    }
    return image;
}

static NSString *YYSPPanelItemKey(id item) {
    if (![item isKindOfClass:%c(KSIMChatMorePanelItem)]) {
        return nil;
    }
    return ((KSIMChatMorePanelItem *)item).key;
}

static void YYSPValidateInstanceMethod(Class cls, SEL sel) {
    if (!cls) {
        YYSPLog(@"class missing while validating selector %@", NSStringFromSelector(sel));
        return;
    }

    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        YYSPLog(@"%@ missing -%@", NSStringFromClass(cls), NSStringFromSelector(sel));
        return;
    }

    const char *typeEncoding = method_getTypeEncoding(method);
    YYSPLog(@"%@ has -%@ type=%s", NSStringFromClass(cls), NSStringFromSelector(sel), typeEncoding ?: "<nil>");
}

static void YYSPValidateHeadersAtRuntime(void) {
    YYSPLog(@"runtime validation begin");

    Class moreVM = %c(KSIMNTChatMoreViewModel);
    Class uiState = %c(KSIMNTChatMoreUIState);
    Class panelItem = %c(KSIMChatMorePanelItem);
    Class clickIntent = %c(KSIMNTChatMorePanelDidClickedIconIntent);
    Class sendComponent = %c(KSIMNTChatSendMessageComponent);
    Class voiceVM = %c(KSIMNTChatVoiceViewModel);
    Class imVoiceInfo = %c(KSIMVoiceInfo);
    Class voiceUIState = %c(KSIMNTChatVoiceUIState);
    Class voiceContentView = %c(KSIMNTChatVoiceContentView);

    YYSPLog(@"class KSIMNTChatMoreViewModel=%@", moreVM ? @"YES" : @"NO");
    YYSPLog(@"class KSIMNTChatMoreUIState=%@", uiState ? @"YES" : @"NO");
    YYSPLog(@"class KSIMChatMorePanelItem=%@", panelItem ? @"YES" : @"NO");
    YYSPLog(@"class KSIMNTChatMorePanelDidClickedIconIntent=%@", clickIntent ? @"YES" : @"NO");
    YYSPLog(@"class KSIMNTChatSendMessageComponent=%@", sendComponent ? @"YES" : @"NO");
    YYSPLog(@"class KSIMNTChatVoiceViewModel=%@", voiceVM ? @"YES" : @"NO");
    YYSPLog(@"class KSIMVoiceInfo=%@", imVoiceInfo ? @"YES" : @"NO");
    YYSPLog(@"class KSIMNTChatVoiceUIState=%@", voiceUIState ? @"YES" : @"NO");
    YYSPLog(@"class KSIMNTChatVoiceContentView=%@", voiceContentView ? @"YES" : @"NO");

    YYSPValidateInstanceMethod(moreVM, @selector(genUIState));
    YYSPValidateInstanceMethod(moreVM, @selector(handleIMNT_KSIMNTChatMorePanelDidClickedIconIntent:));
    YYSPValidateInstanceMethod(moreVM, @selector(sendMessageService));
    YYSPValidateInstanceMethod(uiState, @selector(items));
    YYSPValidateInstanceMethod(uiState, @selector(setItems:));
    YYSPValidateInstanceMethod(panelItem, @selector(key));
    YYSPValidateInstanceMethod(panelItem, @selector(setKey:));
    YYSPValidateInstanceMethod(panelItem, @selector(title));
    YYSPValidateInstanceMethod(panelItem, @selector(setTitle:));
    YYSPValidateInstanceMethod(clickIntent, @selector(panelItem));
    YYSPValidateInstanceMethod(sendComponent, @selector(sendVoiceMessage:withReferenceMessage:duration:));
    YYSPValidateInstanceMethod(voiceVM, @selector(handleStopActionWithFileURL:duration:error:));
    YYSPValidateInstanceMethod(voiceVM, @selector(voiceRecordAction:fileURL:duration:voiceText:error:completion:));
    YYSPValidateInstanceMethod(imVoiceInfo, @selector(initWithFilePath:duration:));
    YYSPValidateInstanceMethod(imVoiceInfo, @selector(setFilePath:));
    YYSPValidateInstanceMethod(imVoiceInfo, @selector(setDuration:));
    YYSPValidateInstanceMethod(imVoiceInfo, @selector(setIsLocal:));
    YYSPValidateInstanceMethod(voiceUIState, @selector(duration));
    YYSPValidateInstanceMethod(voiceUIState, @selector(durationText));
    YYSPValidateInstanceMethod(voiceContentView, @selector(durationLabel));
    YYSPValidateInstanceMethod(voiceContentView, @selector(updateUIWithFrameEntity:uiState:));

    Class commentPanel = %c(KSCommentVoiceCommentPanelView);
    Class commentVoiceInfo = %c(KSCommentVoiceInfo);
    YYSPLog(@"class KSCommentVoiceCommentPanelView=%@", commentPanel ? @"YES" : @"NO");
    YYSPLog(@"class KSCommentVoiceInfo=%@", commentVoiceInfo ? @"YES" : @"NO");
    YYSPValidateInstanceMethod(commentPanel, @selector(setupViewHierarchy));
    YYSPValidateInstanceMethod(commentPanel, @selector(layoutSubviews));
    YYSPValidateInstanceMethod(commentPanel, @selector(closeButton));
    YYSPValidateInstanceMethod(commentPanel, @selector(delegate));
    YYSPValidateInstanceMethod(commentPanel, @selector(voiceCommentRecorderDidFinishWithVoiceInfo:));
    YYSPValidateInstanceMethod(commentVoiceInfo, @selector(setFilePath:));
    YYSPValidateInstanceMethod(commentVoiceInfo, @selector(setDuration:));
}

static UIViewController *YYSPTopViewController(void) {
    UIWindow *keyWindow = nil;
    for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive) {
            continue;
        }
        for (UIWindow *window in scene.windows) {
            if (window.isKeyWindow) {
                keyWindow = window;
                break;
            }
        }
        if (keyWindow) {
            break;
        }
    }
    if (!keyWindow) {
        for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
            keyWindow = scene.windows.firstObject;
            if (keyWindow) {
                break;
            }
        }
    }

    UIViewController *vc = keyWindow.rootViewController;
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }
    while ([vc isKindOfClass:UINavigationController.class]) {
        vc = ((UINavigationController *)vc).topViewController;
    }
    while ([vc isKindOfClass:UITabBarController.class]) {
        vc = ((UITabBarController *)vc).selectedViewController;
    }
    return vc;
}

static NSString *YYSPVoicePackDirectory(void) {
    NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documents = dirs.firstObject ?: NSTemporaryDirectory();
    NSString *path = [documents stringByAppendingPathComponent:YYSPVoicePackDirName];
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    return path;
}

static NSArray<NSString *> *YYSPVoiceFiles(void) {
    NSString *directory = YYSPVoicePackDirectory();
    NSArray<NSString *> *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil] ?: @[];
    NSSet<NSString *> *allowed = [NSSet setWithArray:@[@"m4a", @"aac", @"mp3", @"wav", @"amr"]];
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    for (NSString *name in names) {
        NSString *ext = name.pathExtension.lowercaseString;
        if ([allowed containsObject:ext]) {
            [files addObject:[directory stringByAppendingPathComponent:name]];
        }
    }
    return [files sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

static NSTimeInterval YYSPAudioDurationSeconds(NSURL *url) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    Float64 seconds = CMTimeGetSeconds(asset.duration);
    if (isfinite(seconds) && seconds > 0) {
        return seconds;
    }

    NSError *error = nil;
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&error];
    if (player.duration > 0) {
        YYSPLog(@"duration fallback via AVAudioPlayer file=%@ seconds=%.3f", url.lastPathComponent, player.duration);
        return player.duration;
    }

    YYSPLog(@"duration fallback failed file=%@ error=%@", url.lastPathComponent, error);
    return 1.0;
}

static NSInteger YYSPAudioDuration(NSURL *url) {
    NSTimeInterval seconds = YYSPAudioDurationSeconds(url);
    return MAX(1, (NSInteger)llround(seconds));
}

static NSInteger YYSPAudioDurationMilliseconds(NSURL *url) {
    NSTimeInterval seconds = YYSPAudioDurationSeconds(url);
    return MAX(1000, (NSInteger)llround(seconds * 1000.0));
}

static BOOL YYSPIsPreviewingFile(NSString *filePath) {
    return YYSPPreviewPlayer.isPlaying && [YYSPPreviewPlayer.url.path isEqualToString:filePath];
}

static void YYSPStopPreview(void) {
    if (!YYSPPreviewPlayer) {
        return;
    }
    YYSPLog(@"stop preview %@", YYSPPreviewPlayer.url.lastPathComponent);
    [YYSPPreviewPlayer stop];
    YYSPPreviewPlayer.currentTime = 0;
    YYSPPreviewPlayer = nil;
}

static void YYSPPreviewVoiceFile(NSString *filePath) {
    NSURL *fileURL = [NSURL fileURLWithPath:filePath];
    if (YYSPIsPreviewingFile(filePath)) {
        YYSPStopPreview();
        return;
    }

    YYSPStopPreview();

    NSError *sessionError = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&sessionError];
    if (sessionError) {
        YYSPLog(@"preview audio session category error=%@", sessionError);
    }
    [[AVAudioSession sharedInstance] setActive:YES error:&sessionError];
    if (sessionError) {
        YYSPLog(@"preview audio session active error=%@", sessionError);
    }

    NSError *error = nil;
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:fileURL error:&error];
    if (!player || error) {
        YYSPLog(@"preview create player failed file=%@ error=%@", filePath.lastPathComponent, error);
        YYSPShowAlert(@"试听失败", error.localizedDescription ?: @"当前音频无法播放。");
        return;
    }

    if (!YYSPPreviewDelegate) {
        YYSPPreviewDelegate = [[YYSPAudioPreviewDelegate alloc] init];
    }
    player.delegate = YYSPPreviewDelegate;
    player.numberOfLoops = 0;
    [player prepareToPlay];

    BOOL ok = [player play];
    YYSPLog(@"preview play file=%@ duration=%.2f ok=%@", filePath.lastPathComponent, player.duration, ok ? @"YES" : @"NO");
    if (!ok) {
        YYSPShowAlert(@"试听失败", @"播放器启动失败，请查看日志。");
        return;
    }

    YYSPPreviewPlayer = player;
}

static id YYSPGetSendMessageService(id moreViewModel) {
    SEL sendMessageServiceSEL = @selector(sendMessageService);
    if (![moreViewModel respondsToSelector:sendMessageServiceSEL]) {
        YYSPLog(@"%@ does not respond to sendMessageService", YYSPClassName(moreViewModel));
        return nil;
    }

    id (*sendMessageServiceMsg)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return sendMessageServiceMsg(moreViewModel, sendMessageServiceSEL);
}

static void YYSPShowAlert(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *topVC = YYSPTopViewController();
        if (!topVC) {
            return;
        }
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
        [topVC presentViewController:alert animated:YES completion:nil];
    });
}

static BOOL YYSPSendVoiceViaVoiceViewModel(id moreViewModel, NSURL *fileURL, NSInteger duration) {
    Class voiceVMClass = %c(KSIMNTChatVoiceViewModel);
    if (!voiceVMClass) {
        YYSPLog(@"KSIMNTChatVoiceViewModel class missing");
        return NO;
    }

    id injector = nil;
    if ([moreViewModel respondsToSelector:@selector(injector)]) {
        injector = ((KSIMNTChatMoreViewModel *)moreViewModel).injector;
    }
    YYSPLog(@"creating voiceViewModel with injector=%@", YYSPClassName(injector));

    id voiceVM = [[voiceVMClass alloc] initWithInjector:injector];
    SEL stopSEL = @selector(handleStopActionWithFileURL:duration:error:);
    if (!voiceVM || ![voiceVM respondsToSelector:stopSEL]) {
        YYSPLog(@"voiceVM=%@ does not respond to %@", YYSPClassName(voiceVM), NSStringFromSelector(stopSEL));
        return NO;
    }

    YYSPLog(@"calling %@ -%@ fileURL=%@ duration=%ld", YYSPClassName(voiceVM), NSStringFromSelector(stopSEL), fileURL, (long)duration);
    YYSPKeepAliveTemporarily(voiceVM, 120);
    void (*stopMsg)(id, SEL, id, NSInteger, id) = (void (*)(id, SEL, id, NSInteger, id))objc_msgSend;
    stopMsg(voiceVM, stopSEL, fileURL, duration, nil);
    return YES;
}

static BOOL YYSPSendVoiceViaSendService(id moreViewModel, id fileObject, NSInteger duration) {
    id sendService = YYSPGetSendMessageService(moreViewModel);
    SEL sendVoiceSEL = @selector(sendVoiceMessage:withReferenceMessage:duration:);
    if (!sendService || ![sendService respondsToSelector:sendVoiceSEL]) {
        YYSPLog(@"sendService=%@ does not respond to %@", YYSPClassName(sendService), NSStringFromSelector(sendVoiceSEL));
        return NO;
    }

    YYSPLog(@"calling %@ -%@ fileObjectClass=%@ duration=%ld", YYSPClassName(sendService), NSStringFromSelector(sendVoiceSEL), YYSPClassName(fileObject), (long)duration);
    void (*sendVoiceMsg)(id, SEL, id, id, NSInteger) = (void (*)(id, SEL, id, id, NSInteger))objc_msgSend;
    sendVoiceMsg(sendService, sendVoiceSEL, fileObject, nil, duration);
    return YES;
}

static KSIMVoiceInfo *YYSPCreateIMVoiceInfo(NSString *filePath, NSInteger durationSeconds) {
    Class voiceInfoClass = %c(KSIMVoiceInfo);
    if (!voiceInfoClass) {
        YYSPLog(@"KSIMVoiceInfo class missing");
        return nil;
    }

    KSIMVoiceInfo *voiceInfo = nil;
    SEL initSEL = @selector(initWithFilePath:duration:);
    if ([voiceInfoClass instancesRespondToSelector:initSEL]) {
        voiceInfo = [[voiceInfoClass alloc] initWithFilePath:filePath duration:durationSeconds];
    }
    if (!voiceInfo) {
        voiceInfo = [[voiceInfoClass alloc] init];
        if ([voiceInfo respondsToSelector:@selector(setFilePath:)]) {
            voiceInfo.filePath = filePath;
        }
        if ([voiceInfo respondsToSelector:@selector(setDuration:)]) {
            voiceInfo.duration = durationSeconds;
        }
    }
    if ([voiceInfo respondsToSelector:@selector(setIsLocal:)]) {
        voiceInfo.isLocal = YES;
    }

    NSInteger actualDuration = [voiceInfo respondsToSelector:@selector(duration)] ? voiceInfo.duration : -1;
    NSString *actualPath = [voiceInfo respondsToSelector:@selector(filePath)] ? voiceInfo.filePath : nil;
    YYSPLog(@"created im voiceInfo=%@ file=%@ actualPath=%@ durationSeconds=%ld isLocal=%@",
            YYSPClassName(voiceInfo),
            filePath.lastPathComponent,
            actualPath.lastPathComponent,
            (long)actualDuration,
            ([voiceInfo respondsToSelector:@selector(isLocal)] && voiceInfo.isLocal) ? @"YES" : @"NO");
    return voiceInfo;
}

static BOOL YYSPSendVoiceViaSendServiceVoiceInfo(id moreViewModel, NSString *filePath, NSInteger durationSeconds) {
    KSIMVoiceInfo *voiceInfo = YYSPCreateIMVoiceInfo(filePath, durationSeconds);
    if (!voiceInfo) {
        return NO;
    }
    return YYSPSendVoiceViaSendService(moreViewModel, voiceInfo, durationSeconds);
}

static void YYSPSendVoiceWithMoreViewModel(id moreViewModel, NSString *filePath, YYSPSendMode mode) {
    NSURL *fileURL = [NSURL fileURLWithPath:filePath];
    NSInteger durationSeconds = YYSPAudioDuration(fileURL);
    NSInteger durationMs = YYSPAudioDurationMilliseconds(fileURL);
    YYSPLog(@"send requested mode=%lu file=%@ exists=%@ durationSeconds=%ld durationMs=%ld moreViewModel=%@", (unsigned long)mode, filePath.lastPathComponent, [[NSFileManager defaultManager] fileExistsAtPath:filePath] ? @"YES" : @"NO", (long)durationSeconds, (long)durationMs, YYSPClassName(moreViewModel));

    BOOL didCall = NO;
    switch (mode) {
        case YYSPSendModeVoiceViewModel:
            didCall = YYSPSendVoiceViaVoiceViewModel(moreViewModel, fileURL, durationSeconds);
            break;
        case YYSPSendModeServicePath:
            didCall = YYSPSendVoiceViaSendService(moreViewModel, filePath, durationSeconds);
            break;
        case YYSPSendModeServiceURL:
            didCall = YYSPSendVoiceViaSendService(moreViewModel, fileURL, durationSeconds);
            break;
        case YYSPSendModeServiceVoiceInfo:
            didCall = YYSPSendVoiceViaSendServiceVoiceInfo(moreViewModel, filePath, durationSeconds);
            break;
    }

    if (!didCall) {
        YYSPShowAlert(@"屿宇私域宝", @"当前发送链路没有命中，请查看日志。");
        return;
    }

    YYSPShowAlert(@"屿宇私域宝", @"已调用发送方法；如果聊天里仍未出现语音，请把日志发我继续定位。");
}

static void YYSPPresentSendModeSheet(id moreViewModel, NSString *filePath) {
    UIViewController *topVC = YYSPTopViewController();
    if (!topVC) {
        YYSPLog(@"top view controller not found while presenting send mode sheet");
        return;
    }

    NSString *name = filePath.lastPathComponent;
    NSInteger duration = YYSPAudioDuration([NSURL fileURLWithPath:filePath]);
    BOOL isPreviewing = YYSPIsPreviewingFile(filePath);
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:name
                                                                   message:[NSString stringWithFormat:@"时长约 %ld 秒，选择试听或发送链路", (long)duration]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:(isPreviewing ? @"停止试听" : @"试听") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        YYSPPreviewVoiceFile(filePath);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"原生录音链路" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        YYSPStopPreview();
        YYSPSendVoiceWithMoreViewModel(moreViewModel, filePath, YYSPSendModeVoiceViewModel);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"发送服务 Path" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        YYSPStopPreview();
        YYSPSendVoiceWithMoreViewModel(moreViewModel, filePath, YYSPSendModeServicePath);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"发送服务 URL" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        YYSPStopPreview();
        YYSPSendVoiceWithMoreViewModel(moreViewModel, filePath, YYSPSendModeServiceURL);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"发送服务 VoiceInfo" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        YYSPStopPreview();
        YYSPSendVoiceWithMoreViewModel(moreViewModel, filePath, YYSPSendModeServiceVoiceInfo);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    popover.sourceView = topVC.view;
    popover.sourceRect = CGRectMake(CGRectGetMidX(topVC.view.bounds), CGRectGetMaxY(topVC.view.bounds), 1, 1);
    [topVC presentViewController:sheet animated:YES completion:nil];
}

static void YYSPPresentVoicePack(id moreViewModel) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<NSString *> *files = YYSPVoiceFiles();
        NSString *directory = YYSPVoicePackDirectory();
        YYSPLog(@"present voice pack files=%lu directory=%@", (unsigned long)files.count, directory);
        UIViewController *topVC = YYSPTopViewController();
        if (!topVC) {
            YYSPLog(@"top view controller not found");
            return;
        }

        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"屿宇私域宝"
                                                                       message:@"选择要发送的语音"
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        if (files.count == 0) {
            NSString *message = [NSString stringWithFormat:@"请先把语音文件放到：\n%@", directory];
            [sheet setMessage:message];
        }

        for (NSString *filePath in files) {
            NSString *name = filePath.lastPathComponent;
            [sheet addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                YYSPPresentSendModeSheet(moreViewModel, filePath);
            }]];
        }

        [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        UIPopoverPresentationController *popover = sheet.popoverPresentationController;
        popover.sourceView = topVC.view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(topVC.view.bounds), CGRectGetMaxY(topVC.view.bounds), 1, 1);
        [topVC presentViewController:sheet animated:YES completion:nil];
    });
}

static KSCommentVoiceInfo *YYSPCreateCommentVoiceInfo(NSString *filePath) {
    Class voiceInfoClass = %c(KSCommentVoiceInfo);
    if (!voiceInfoClass) {
        YYSPLog(@"KSCommentVoiceInfo class missing");
        return nil;
    }

    KSCommentVoiceInfo *voiceInfo = [[voiceInfoClass alloc] init];
    voiceInfo.filePath = filePath;
    voiceInfo.duration = YYSPAudioDurationMilliseconds([NSURL fileURLWithPath:filePath]);
    voiceInfo.didWeakNetOptimize = NO;
    YYSPLog(@"created comment voiceInfo=%@ file=%@ durationMs=%ld", YYSPClassName(voiceInfo), filePath.lastPathComponent, (long)voiceInfo.duration);
    return voiceInfo;
}

static BOOL YYSPSendCommentVoiceWithPanel(KSCommentVoiceCommentPanelView *panel, NSString *filePath) {
    YYSPStopPreview();

    KSCommentVoiceInfo *voiceInfo = YYSPCreateCommentVoiceInfo(filePath);
    if (!voiceInfo) {
        YYSPShowAlert(@"屿宇私域宝", @"评论语音对象创建失败，请查看日志。");
        return NO;
    }

    SEL panelFinishSEL = @selector(voiceCommentRecorderDidFinishWithVoiceInfo:);
    if ([panel respondsToSelector:panelFinishSEL]) {
        YYSPLog(@"calling panel finish %@ -%@ file=%@", YYSPClassName(panel), NSStringFromSelector(panelFinishSEL), filePath.lastPathComponent);
        void (*finishMsg)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
        finishMsg(panel, panelFinishSEL, voiceInfo);
        return YES;
    }

    id delegate = panel.delegate;
    SEL delegateFinishSEL = @selector(voiceCommentPanel:didFinishRecordingWithAttachment:);
    if (delegate && [delegate respondsToSelector:delegateFinishSEL]) {
        YYSPLog(@"calling comment delegate %@ -%@ file=%@", YYSPClassName(delegate), NSStringFromSelector(delegateFinishSEL), filePath.lastPathComponent);
        void (*delegateMsg)(id, SEL, id, id) = (void (*)(id, SEL, id, id))objc_msgSend;
        delegateMsg(delegate, delegateFinishSEL, panel, voiceInfo);
        return YES;
    }

    YYSPLog(@"comment panel/delegate finish selector missing panel=%@ delegate=%@", YYSPClassName(panel), YYSPClassName(delegate));
    YYSPShowAlert(@"屿宇私域宝", @"当前评论语音发送回调没有命中，请查看日志。");
    return NO;
}

static void YYSPPresentCommentVoiceFileSheet(KSCommentVoiceCommentPanelView *panel, NSString *filePath) {
    UIViewController *topVC = YYSPTopViewController();
    if (!topVC) {
        YYSPLog(@"top view controller not found while presenting comment voice file sheet");
        return;
    }

    NSInteger duration = YYSPAudioDuration([NSURL fileURLWithPath:filePath]);
    BOOL isPreviewing = YYSPIsPreviewingFile(filePath);
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:filePath.lastPathComponent
                                                                   message:[NSString stringWithFormat:@"评论语音，时长约 %ld 秒", (long)duration]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:(isPreviewing ? @"停止试听" : @"试听") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        YYSPPreviewVoiceFile(filePath);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"发送到评论区" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        BOOL ok = YYSPSendCommentVoiceWithPanel(panel, filePath);
        if (ok) {
            YYSPShowAlert(@"屿宇私域宝", @"已调用评论语音原生回调；如果没有出现，请把日志发我。");
        }
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    popover.sourceView = topVC.view;
    popover.sourceRect = CGRectMake(CGRectGetMidX(topVC.view.bounds), CGRectGetMaxY(topVC.view.bounds), 1, 1);
    [topVC presentViewController:sheet animated:YES completion:nil];
}

static void YYSPPresentCommentVoicePack(KSCommentVoiceCommentPanelView *panel) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<NSString *> *files = YYSPVoiceFiles();
        NSString *directory = YYSPVoicePackDirectory();
        YYSPLog(@"present comment voice pack files=%lu directory=%@ panel=%@ delegate=%@", (unsigned long)files.count, directory, YYSPClassName(panel), YYSPClassName(panel.delegate));

        UIViewController *topVC = YYSPTopViewController();
        if (!topVC) {
            YYSPLog(@"top view controller not found while presenting comment voice pack");
            return;
        }

        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"评论语音包"
                                                                       message:@"选择要发送的语音"
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        if (files.count == 0) {
            [sheet setMessage:[NSString stringWithFormat:@"请先把语音文件放到：\n%@", directory]];
        }

        for (NSString *filePath in files) {
            [sheet addAction:[UIAlertAction actionWithTitle:filePath.lastPathComponent style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                YYSPPresentCommentVoiceFileSheet(panel, filePath);
            }]];
        }

        [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        UIPopoverPresentationController *popover = sheet.popoverPresentationController;
        popover.sourceView = topVC.view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(topVC.view.bounds), CGRectGetMaxY(topVC.view.bounds), 1, 1);
        [topVC presentViewController:sheet animated:YES completion:nil];
    });
}

static UIButton *YYSPCommentVoicePackButton(KSCommentVoiceCommentPanelView *panel) {
    UIButton *button = objc_getAssociatedObject(panel, &YYSPCommentVoicePackButtonKey);
    if (!button) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        [button setTitle:@"语音包" forState:UIControlStateNormal];
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        button.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.28];
        button.layer.cornerRadius = 16;
        button.layer.masksToBounds = YES;
        [button addTarget:panel action:@selector(yysp_commentVoicePackButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(panel, &YYSPCommentVoicePackButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return button;
}

static void YYSPInstallCommentVoicePackButton(KSCommentVoiceCommentPanelView *panel) {
    UIButton *closeButton = panel.closeButton;
    if (!closeButton) {
        YYSPLog(@"comment panel closeButton missing panel=%@", YYSPClassName(panel));
        return;
    }

    UIButton *button = YYSPCommentVoicePackButton(panel);
    UIView *container = closeButton.superview ?: panel;
    if (button.superview != container) {
        [container addSubview:button];
        YYSPLog(@"comment voice pack button installed panel=%@ container=%@ closeButtonFrame=%@", YYSPClassName(panel), YYSPClassName(container), NSStringFromCGRect(closeButton.frame));
    }

    CGFloat width = 72.0;
    CGFloat height = 32.0;
    CGRect closeFrame = closeButton.frame;
    CGFloat x = CGRectGetMinX(closeFrame) - width - 8.0;
    CGFloat y = CGRectGetMidY(closeFrame) - height / 2.0;
    if (!CGRectIsEmpty(closeFrame) && isfinite(x) && isfinite(y)) {
        button.frame = CGRectMake(MAX(8.0, x), y, width, height);
    } else {
        button.frame = CGRectMake(MAX(8.0, CGRectGetWidth(container.bounds) - width - 64.0), 12.0, width, height);
    }
    button.hidden = closeButton.hidden;
}

static BOOL YYSPItemExists(NSArray *items) {
    for (id item in items) {
        NSString *key = YYSPPanelItemKey(item);
        if ([key isEqualToString:YYSPItemKey]) {
            return YES;
        }
    }
    return NO;
}

static KSIMChatMorePanelItem *YYSPCreatePanelItem(void) {
    KSIMChatMorePanelItem *item = [[%c(KSIMChatMorePanelItem) alloc] init];
    item.key = YYSPItemKey;
    item.title = @"语音包";
    item.titleCN = @"语音包";
    item.localIconName = @"";
    item.page = 0;
    return item;
}

%hook KSIMNTChatMoreViewModel

- (id)genUIState {
    KSIMNTChatMoreUIState *state = %orig;
    if (![state respondsToSelector:@selector(items)]) {
        YYSPLog(@"genUIState hit but state=%@ has no items selector", YYSPClassName(state));
        return state;
    }

    NSArray *items = state.items ?: @[];
    YYSPLog(@"genUIState hit state=%@ originalItems=%lu", YYSPClassName(state), (unsigned long)items.count);
    if (YYSPItemExists(items)) {
        YYSPLog(@"voice pack item already exists");
        return state;
    }

    NSMutableArray *mutableItems = [items mutableCopy];
    [mutableItems addObject:YYSPCreatePanelItem()];
    state.items = mutableItems.copy;
    YYSPLog(@"voice pack item injected newItems=%lu", (unsigned long)state.items.count);
    return state;
}

- (void)handleIMNT_KSIMNTChatMorePanelDidClickedIconIntent:(KSIMNTChatMorePanelDidClickedIconIntent *)intent {
    KSIMChatMorePanelItem *item = intent.panelItem;
    NSString *key = YYSPPanelItemKey(item);
    YYSPLog(@"more panel click intent=%@ item=%@ key=%@ index=%lu", YYSPClassName(intent), YYSPClassName(item), key, (unsigned long)intent.index);
    if ([key isEqualToString:YYSPItemKey]) {
        YYSPPresentVoicePack(self);
        return;
    }
    %orig;
}

%end

static BOOL YYSPDurationTextLooksZero(NSString *text) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length == 0 || [trimmed hasPrefix:@"0"];
}

static NSString *YYSPDurationDisplayText(NSInteger duration) {
    return [NSString stringWithFormat:@"%ld秒", (long)MAX(1, duration)];
}

%hook KSIMNTChatVoiceContentView

- (void)updateUIWithFrameEntity:(id)frameEntity uiState:(KSIMNTChatVoiceUIState *)uiState {
    NSInteger beforeDuration = [uiState respondsToSelector:@selector(duration)] ? uiState.duration : -1;
    NSString *beforeText = [uiState respondsToSelector:@selector(durationText)] ? uiState.durationText : nil;
    if (beforeDuration > 0 && [uiState respondsToSelector:@selector(setDurationText:)] && YYSPDurationTextLooksZero(beforeText)) {
        uiState.durationText = YYSPDurationDisplayText(beforeDuration);
        YYSPLog(@"voice uiState durationText patched before update duration=%ld oldText=%@ newText=%@ frameEntity=%@",
                (long)beforeDuration,
                beforeText,
                uiState.durationText,
                YYSPClassName(frameEntity));
    }

    %orig;

    UILabel *label = [self respondsToSelector:@selector(durationLabel)] ? ((KSIMNTChatVoiceContentView *)self).durationLabel : nil;
    NSInteger afterDuration = [uiState respondsToSelector:@selector(duration)] ? uiState.duration : -1;
    NSString *afterText = [uiState respondsToSelector:@selector(durationText)] ? uiState.durationText : nil;
    YYSPLog(@"voice content update view=%@ frameEntity=%@ durationBefore=%ld textBefore=%@ durationAfter=%ld textAfter=%@ label=%@",
            YYSPClassName(self),
            YYSPClassName(frameEntity),
            (long)beforeDuration,
            beforeText,
            (long)afterDuration,
            afterText,
            label.text);

    if (afterDuration > 0 && label && YYSPDurationTextLooksZero(label.text)) {
        label.text = YYSPDurationDisplayText(afterDuration);
        YYSPLog(@"voice durationLabel patched duration=%ld label=%@", (long)afterDuration, label.text);
    }
}

%end

%hook KSCommentVoiceCommentPanelView

- (void)setupViewHierarchy {
    %orig;
    YYSPInstallCommentVoicePackButton((KSCommentVoiceCommentPanelView *)self);
}

- (void)layoutSubviews {
    %orig;
    YYSPInstallCommentVoicePackButton((KSCommentVoiceCommentPanelView *)self);
}

%new
- (void)yysp_commentVoicePackButtonTapped:(id)sender {
    YYSPLog(@"comment voice pack button tapped panel=%@ sender=%@", YYSPClassName(self), YYSPClassName(sender));
    YYSPPresentCommentVoicePack((KSCommentVoiceCommentPanelView *)self);
}

%end

%ctor {
    YYSPLog(@"loaded bundle=%@", NSBundle.mainBundle.bundleIdentifier);
    YYSPValidateHeadersAtRuntime();
}
