#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString * const YYSPItemKey = @"com.yuyu.siyubao.voicepack";
static NSString * const YYSPVoicePackDirName = @"YuyuSiyubao/VoicePacks";

#if YYSP_DEBUG
#define YYSPLog(fmt, ...) NSLog((@"[屿宇私域宝] " fmt), ##__VA_ARGS__)
#else
#define YYSPLog(fmt, ...)
#endif

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

static NSString *YYSPClassName(id object) {
    return object ? NSStringFromClass([object class]) : @"<nil>";
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

    YYSPLog(@"class KSIMNTChatMoreViewModel=%@", moreVM ? @"YES" : @"NO");
    YYSPLog(@"class KSIMNTChatMoreUIState=%@", uiState ? @"YES" : @"NO");
    YYSPLog(@"class KSIMChatMorePanelItem=%@", panelItem ? @"YES" : @"NO");
    YYSPLog(@"class KSIMNTChatMorePanelDidClickedIconIntent=%@", clickIntent ? @"YES" : @"NO");
    YYSPLog(@"class KSIMNTChatSendMessageComponent=%@", sendComponent ? @"YES" : @"NO");
    YYSPLog(@"class KSIMNTChatVoiceViewModel=%@", voiceVM ? @"YES" : @"NO");

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

static NSInteger YYSPAudioDuration(NSURL *url) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    Float64 seconds = CMTimeGetSeconds(asset.duration);
    if (!isfinite(seconds) || seconds <= 0) {
        return 1;
    }
    return MAX(1, (NSInteger)llround(seconds));
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

static void YYSPSendVoiceWithMoreViewModel(id moreViewModel, NSString *filePath) {
    NSURL *fileURL = [NSURL fileURLWithPath:filePath];
    NSInteger duration = YYSPAudioDuration(fileURL);
    YYSPLog(@"send requested file=%@ duration=%ld moreViewModel=%@", filePath.lastPathComponent, (long)duration, YYSPClassName(moreViewModel));

    SEL sendMessageServiceSEL = @selector(sendMessageService);
    if (![moreViewModel respondsToSelector:sendMessageServiceSEL]) {
        YYSPLog(@"%@ does not respond to sendMessageService", YYSPClassName(moreViewModel));
        YYSPShowAlert(@"屿宇私域宝", @"当前聊天页没有找到发送服务。");
        return;
    }

    id (*sendMessageServiceMsg)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id sendService = sendMessageServiceMsg(moreViewModel, sendMessageServiceSEL);
    SEL sendVoiceSEL = @selector(sendVoiceMessage:withReferenceMessage:duration:);
    if (!sendService || ![sendService respondsToSelector:sendVoiceSEL]) {
        YYSPLog(@"sendService=%@ does not respond to %@", YYSPClassName(sendService), NSStringFromSelector(sendVoiceSEL));
        YYSPShowAlert(@"屿宇私域宝", @"当前版本未暴露原生语音发送入口。");
        return;
    }

    YYSPLog(@"calling %@ -%@", YYSPClassName(sendService), NSStringFromSelector(sendVoiceSEL));
    void (*sendVoiceMsg)(id, SEL, id, id, NSInteger) = (void (*)(id, SEL, id, id, NSInteger))objc_msgSend;
    sendVoiceMsg(sendService, sendVoiceSEL, fileURL, nil, duration);
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
                YYSPSendVoiceWithMoreViewModel(moreViewModel, filePath);
            }]];
        }

        [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        UIPopoverPresentationController *popover = sheet.popoverPresentationController;
        popover.sourceView = topVC.view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(topVC.view.bounds), CGRectGetMaxY(topVC.view.bounds), 1, 1);
        [topVC presentViewController:sheet animated:YES completion:nil];
    });
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

%ctor {
    YYSPLog(@"loaded bundle=%@", NSBundle.mainBundle.bundleIdentifier);
    YYSPValidateHeadersAtRuntime();
}
