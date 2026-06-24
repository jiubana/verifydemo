// Verification.m
// 注入版 - 自动启动验证 (API v2 + 时间同步 + 心跳下线 + UI优化)

#import "Verification.h"
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>

// ==========================================
//    配置区域 - 占位符 (由后台自动替换，请勿手动修改)
// ==========================================
// 占位符长度说明: ServerUrl=100, AppKey=32, AppSecret=64
// url不要带/
#define kServerUrl  @"__PLACEHOLDER_SERVER_URL_000000000000000000000000000000000000000000000000000000000000000000000000__"
#define kAppKey     @"__PLACEHOLDER_APP_KEY_0000000000__"
#define kAppSecret  @"__PLACEHOLDER_APP_SECRET_0000000000000000000000000000000000000000__"
#define kAppVersion @"__PLACEHOLDER_APP_VERSION_0000000000__"


// 心跳间隔 (秒)
// 心跳间隔 (秒) - 已废弃宏定义，改用云端动态配置属性


#define SAFE_STR(obj) ((obj == nil || [obj isEqual:[NSNull null]]) ? @"" : [NSString stringWithFormat:@"%@", obj])
// ==========================================

@interface Verification ()
@property (nonatomic, strong) UIWindow *alertWindow; // 独立弹窗窗口，确保覆盖在最上层
@property (nonatomic, strong) NSTimer *heartbeatTimer;
@property (nonatomic, strong) NSTimer *windowKeepTopTimer; // 持续置顶定时器
@property (nonatomic, assign) NSInteger serverTimeOffset; // 时间偏移量
@property (nonatomic, assign) BOOL isVerified; // 是否已验证通过
@property (nonatomic, assign) BOOL needsReshowActivation; // 从外部链接返回后需要重新弹窗

// 动态配置
@property (nonatomic, copy) NSString *contactLink;
@property (nonatomic, copy) NSString *buyLink;
@property (nonatomic, copy) NSString *popupAnnouncement;
@property (nonatomic, copy) NSString *notice; // 滚动公告/简短提示
@property (nonatomic, assign) NSTimeInterval heartbeatInterval; // 云端心跳间隔

// 弹窗状态记录 (用于被挤掉后自动恢复)
@property (nonatomic, assign) NSInteger currentAlertStyle;
@property (nonatomic, copy) NSString *lastErrorMessage;
@property (nonatomic, copy) NSString *lastUpdateVersion;
@property (nonatomic, assign) BOOL lastUpdateMandatory;
@property (nonatomic, copy) NSString *lastUpdateUrl;
@property (nonatomic, copy) NSString *lastUpdateLog;
@property (nonatomic, copy) void(^lastUpdateCompletion)(void);
@property (nonatomic, copy) NSString *lastAnnouncementTitle;
@property (nonatomic, copy) NSString *lastAnnouncementMsg;
@property (nonatomic, copy) void(^lastAnnouncementAction)(void);

- (void)startVerificationFlowWithManualFlag:(BOOL)isManual;
- (void)executeActualResponseHandling:(BOOL)success data:(NSDictionary *)root msg:(NSString *)msg isManual:(BOOL)isManual;
- (NSTimeInterval)timeElapsedSinceLaunch;
@end

@implementation Verification

#pragma mark - Initialization

static NSTimeInterval gLaunchTimestamp = 0;

+ (void)load {
    gLaunchTimestamp = [NSDate timeIntervalSinceReferenceDate];
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"[JiubanAuth] Framework loaded. Listening for App Launch...");
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidFinishLaunching:)
                                                     name:UIApplicationDidFinishLaunchingNotification
                                                   object:nil];
        // 监听 App 回到前台，用于处理从外部链接返回后重新弹窗
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidBecomeActiveNotification:)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
    });
}

- (NSTimeInterval)timeElapsedSinceLaunch {
    if (gLaunchTimestamp == 0) return 0;
    return [NSDate timeIntervalSinceReferenceDate] - gLaunchTimestamp;
}

+ (instancetype)sharedInstance {
    static Verification *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[Verification alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    if (self = [super init]) {
        self.serverTimeOffset = 0;
        self.isVerified = NO;
        self.needsReshowActivation = NO;
        self.heartbeatInterval = 60.0; // 默认 60s
    }
    return self;
}

// 当 App 从后台回到前台时触发
+ (void)applicationDidBecomeActiveNotification:(NSNotification *)notification {
    Verification *instance = [Verification sharedInstance];
    if (instance.needsReshowActivation && !instance.isVerified) {
        instance.needsReshowActivation = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            [instance showActivationAlert:nil];
        });
    }
}

// ----------------------------------------------------------------
//  辅助方法：清洗占位符字符串 (去除二进制替换产生的 \0 填充)
// ----------------------------------------------------------------
- (NSString *)cleanString:(NSString *)original {
    if (!original) return @"";
    // 转为 C 字符串会在 \0 处自动截断，再转回 NSString 即可去除尾部填充
    return [NSString stringWithUTF8String:[original UTF8String]];
}

- (NSString *)serverUrl { return [self cleanString:kServerUrl]; }
- (NSString *)appKey { return [self cleanString:kAppKey]; }
- (NSString *)appSecret { return [self cleanString:kAppSecret]; }
- (NSString *)appVersion { return [self cleanString:kAppVersion]; }
// ----------------------------------------------------------------

+ (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSLog(@"[JiubanAuth] App finished launching. Starting verification flow immediately.");
    dispatch_async(dispatch_get_main_queue(), ^{
        [[Verification sharedInstance] startVerificationFlow];
    });
}

#pragma mark - Verification Flow

#pragma mark - Verification Flow

- (void)startVerificationFlow {
    [self startVerificationFlowWithManualFlag:NO];
}

- (void)startVerificationFlowWithManualFlag:(BOOL)isManual {
    double cachedDelay = isManual ? 0.0 : [[NSUserDefaults standardUserDefaults] doubleForKey:@"jb_launch_delay"];
    if (cachedDelay <= 0.0) {
        [self showLoadingToast:@"正在同步云端配置..."];
    } else {
        NSLog(@"[JiubanAuth] Cached delay is %.2f, fetching config silently in background.", cachedDelay);
    }
    
    // 获取缓存
    NSDictionary *cache = [self loadVerificationCache];
    NSString *savedCard = cache[@"card_code"];
    
    // 无论有无卡密，都先联网 Init 拉取公告和链接
    [self apiInitWithCard:savedCard completion:^(BOOL success, NSDictionary *data, NSString *msg) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // 此时配置已同步，handleServerResponse 会根据 status 决定下一步
            [self handleServerResponse:success data:data msg:msg isManual:isManual];
        });
    }];
}

// 统一处理服务器返回结果
- (void)handleServerResponse:(BOOL)success data:(NSDictionary *)root msg:(NSString *)msg isManual:(BOOL)isManual {
    // 解析 Payload (data 子对象)
    NSDictionary *payload = [root isKindOfClass:[NSDictionary class]] ? root[@"data"] : nil;
    
    // 更新配置 (优先 Payload)
    if (payload && [payload isKindOfClass:[NSDictionary class]]) {
        [self updateConfig:payload];
    } else if (root && [root isKindOfClass:[NSDictionary class]]) {
        [self updateConfig:root];
    }
    
    // 获取最新的 launch_delay
    double actualDelay = [[NSUserDefaults standardUserDefaults] doubleForKey:@"jb_launch_delay"];
    if (actualDelay < 0.0) actualDelay = 0.0;
    
    NSTimeInterval elapsed = [self timeElapsedSinceLaunch];
    NSTimeInterval remainingDelay = actualDelay - elapsed;
    
    NSLog(@"[JiubanAuth] Server launch_delay: %.2f, elapsed since launch: %.2f, remaining: %.2f", actualDelay, elapsed, remainingDelay);
    
    if (!isManual && remainingDelay > 0.0) {
        // 如果有剩余延迟，且不是手动操作，我们需要隐藏 loading 框（如果在显示），并在延迟结束后再处理
        [self hideLoadingToast];
        
        NSLog(@"[JiubanAuth] Scheduling verification UI after remaining delay: %.2f seconds", remainingDelay);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remainingDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self executeActualResponseHandling:success data:root msg:msg isManual:isManual];
        });
    } else {
        // 无需延迟，或者手动触发，直接隐藏 loading 框并执行
        [self hideLoadingToast];
        [self executeActualResponseHandling:success data:root msg:msg isManual:isManual];
    }
}

- (void)executeActualResponseHandling:(BOOL)success data:(NSDictionary *)root msg:(NSString *)msg isManual:(BOOL)isManual {
    NSDictionary *payload = [root isKindOfClass:[NSDictionary class]] ? root[@"data"] : nil;
    
    if (!success) {
        // 网络/物理层面的连接失败 (如：联网权限未下发、离线、超时)
        if (msg && ([msg containsString:@"Internet"] || [msg containsString:@"offline"] || [msg containsString:@"timed out"] || [msg containsString:@"Network"])) {
            [self showNetworkErrorAlert:msg];
        } else {
            [self showBlockingErrorAlert:msg ?: @"服务器连接失败"];
        }
        return;
    }

    // --- 第一步: 检查热更新 ---
    NSDictionary *hotupdate = (payload && [payload isKindOfClass:[NSDictionary class]]) ? payload[@"hotupdate"] : root[@"hotupdate"];
    if (hotupdate && [hotupdate[@"has_update"] boolValue]) {
        NSString *ver = hotupdate[@"update_version"] ?: @"";
        NSString *url = hotupdate[@"update_url"] ?: @"";
        NSString *log = hotupdate[@"changelog"] ?: @"";
        
        // 健壮解析 update_type
        NSInteger type = 0;
        id typeObj = hotupdate[@"update_type"];
        if (typeObj) type = [typeObj integerValue];
        
        // 与后台对齐：0=建议, 1=强制
        BOOL isMandatory = (type == 1);
        
        [self showUpdateAlert:ver isMandatory:isMandatory url:url changelog:log completion:^{
            [self proceedWithSuccessData:(payload ?: root) isManual:isManual];
        }];
        return;
    }
    
    // --- 第二步: 无更新，进入成功流程 (携带 isManual) ---
    [self proceedWithSuccessData:(payload ?: root) isManual:isManual];
}

- (void)proceedWithSuccessData:(NSDictionary *)data isManual:(BOOL)isManual {
    // 检查状态 (优先支持 status 字段)
    NSString *status = data[@"status"];
    
    // 兼容逻辑：如果没有 status 字段但有 expire_time，尝试视为 active
    if (!status && data[@"expire_time"]) status = @"active";

    if ([status isEqualToString:@"active"]) {
        // 激活成功，强力清理 UI 残留
        if (self.alertWindow) {
            UIViewController *root = self.alertWindow.rootViewController;
            if (root.presentedViewController) {
                // 显式 dismiss 当前展示的 Alert 控制器，防止残留
                [root.presentedViewController dismissViewControllerAnimated:YES completion:^{
                    [self destroyAlertWindow];
                }];
            } else {
                [self destroyAlertWindow];
            }
        }
        
        // 持久化存储 (保存卡密原文)
        [self saveVerificationCache:YES expire:data[@"expire_time"] card:data[@"card_code"]];
        
        self.isVerified = YES;
        [self startHeartbeat];
        
        // 获取本地已确认过的卡密
        NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
        NSString *confirmedCard = [def stringForKey:@"jb_confirmed_card"];
        
        // 核心修复：如果服务器没返回卡密，尝试从本地缓存获取当前正在使用的卡密
        NSString *currentCard = data[@"card_code"];
        if (!currentCard || currentCard.length == 0) {
            NSDictionary *cache = [self loadVerificationCache];
            currentCard = cache[@"card_code"] ?: @"";
        }
        
        NSString *expire = data[@"expire_time"] ?: @"永久";
        NSString *finalMsg = [NSString stringWithFormat:@"验证通过！\n有效期至: %@", expire];

        if (isManual || ![currentCard isEqualToString:confirmedCard]) {
            // 需要弹窗确认的情况：1.手动点击激活 2.当前卡密从未确认过
            [self showAnnouncementAlert:@"激活成功" message:finalMsg nextAction:^{
                // 用户点击确定，记录已确认状态
                [def setObject:currentCard forKey:@"jb_confirmed_card"];
                [def synchronize];
                
                // 接着展示系统公告（如果有）
                if (self.popupAnnouncement && self.popupAnnouncement.length > 0) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self showAnnouncementAlert:@"系统公告" message:self.popupAnnouncement nextAction:nil];
                    });
                }
            }];
        } else {
            // 静默模式：已经确认过且是自动登录，直接启动，不弹任何提示
            if (self.popupAnnouncement && self.popupAnnouncement.length > 0) {
                // 如果有必须显示的公告，则弹公告，但不提示到期时间
                [self showAnnouncementAlert:@"系统公告" message:self.popupAnnouncement nextAction:nil];
            }
            // 这里不再调用 showToast，实现完全静默
        }
    } else {
        // 验证失败 (Expired / Banned / Unbound / NoCard)
        self.isVerified = NO;
        [self stopHeartbeat];
        
        // 检查本地是否有卡密记录
        NSDictionary *cache = [self loadVerificationCache];
        NSString *savedCard = cache[@"card_code"];
        
        if (savedCard && savedCard.length > 0) {
            // 情况 A：曾经激活过但现在失效了（过期/封禁/解绑），显示阻断报错及“更换卡密”
            [self showBlockingErrorAlert:data[@"msg"] ?: @"激活已失效，请联系客服"];
        } else {
            // 情况 B：全新用户，或清除数据后首次启动，直接弹激活框，无需报错
            [self showActivationAlert:nil];
        }
    }
}

#pragma mark - Local Cache

- (void)saveVerificationCache:(BOOL)active expire:(NSString *)expire card:(NSString *)card {
    NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
    [def setObject:@(active) forKey:@"jb_local_active"];
    if (expire) [def setObject:expire forKey:@"jb_local_expire"];
    if (card) [def setObject:card forKey:@"jb_card_code"]; // 新增卡密持久化
    [def synchronize];
}

- (NSDictionary *)loadVerificationCache {
    NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
    if ([def objectForKey:@"jb_card_code"]) {
        BOOL active = [def boolForKey:@"jb_local_active"];
        NSString *expire = [def objectForKey:@"jb_local_expire"] ?: @"";
        NSString *card = [def objectForKey:@"jb_card_code"] ?: @"";
        return @{ @"is_active": @(active), @"expire_time": expire, @"card_code": card };
    }
    return nil;
}

- (void)clearVerificationCache {
    NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
    [def removeObjectForKey:@"jb_local_active"];
    [def removeObjectForKey:@"jb_local_expire"];
    [def removeObjectForKey:@"jb_card_code"];
    [def removeObjectForKey:@"jb_confirmed_card"]; // 同时清除确认标识
    [def removeObjectForKey:@"jb_launch_delay"]; // 同时清除启动延迟
    [def synchronize];
}

#pragma mark - UI Logic (Using UIWindow for Overlay)

- (UIWindow *)createAlertWindow {
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                window = [[UIWindow alloc] initWithWindowScene:scene];
                break;
            }
        }
    }
    if (!window) {
        window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    }
    window.windowLevel = UIWindowLevelAlert + 100; // 高于普通 Alert，但不遮挡系统编辑菜单

    window.backgroundColor = [UIColor clearColor];
    window.rootViewController = [[UIViewController alloc] init];
    window.rootViewController.view.backgroundColor = [UIColor clearColor];
    
    // 启动置顶定时器，持续确保窗口在最顶层
    [self startKeepTopTimer];
    
    return window;
}

- (void)destroyAlertWindow {
    // 停止置顶定时器
    [self stopKeepTopTimer];
    
    if (self.alertWindow) {
        self.alertWindow.hidden = YES;
        self.alertWindow = nil;
    }
}

// 启动持续置顶定时器
- (void)startKeepTopTimer {
    [self stopKeepTopTimer];
    self.windowKeepTopTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(keepWindowOnTop) userInfo:nil repeats:YES];
}

// 停止置顶定时器
- (void)stopKeepTopTimer {
    if (self.windowKeepTopTimer) {
        [self.windowKeepTopTimer invalidate];
        self.windowKeepTopTimer = nil;
    }
}

// 停止心跳定时器
- (void)stopHeartbeat {
    if (self.heartbeatTimer) {
        [self.heartbeatTimer invalidate];
        self.heartbeatTimer = nil;
    }
}

// 强制将验证弹窗保持在最顶层，并在异常被挤掉时自动重弹
- (void)keepWindowOnTop {
    if (self.alertWindow && !self.alertWindow.hidden) {
        // 兼容 iOS 13+ SceneDelegate：动态绑定活跃的 UIWindowScene
        if (@available(iOS 13.0, *)) {
            if (!self.alertWindow.windowScene) {
                for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                    if ([scene isKindOfClass:[UIWindowScene class]] &&
                        (scene.activationState == UISceneActivationStateForegroundActive ||
                         scene.activationState == UISceneActivationStateForegroundInactive)) {
                        self.alertWindow.windowScene = (UIWindowScene *)scene;
                        break;
                    }
                }
            }
        }
        
        // 重新设置 windowLevel 并使其成为 key window
        self.alertWindow.windowLevel = UIWindowLevelAlert + 100;

        if (!self.alertWindow.isKeyWindow) {
            [self.alertWindow makeKeyAndVisible];
        }
        
        if (!self.isVerified) {
            UIViewController *rootVC = self.alertWindow.rootViewController;
            // 如果没有正在展现的 ViewController，并且 view 里也没有 loadingToast 的 subview，说明弹窗被挤掉/意外关闭了
            if (rootVC && !rootVC.presentedViewController && rootVC.view.subviews.count == 0) {
                NSLog(@"[JiubanAuth] Alert was dismissed unexpectedly. Restoring style: %ld", (long)self.currentAlertStyle);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self restoreLastAlert];
                });
            }
        }
    }
}

- (void)restoreLastAlert {
    switch (self.currentAlertStyle) {
        case 1:
            [self showActivationAlert:self.lastErrorMessage];
            break;
        case 2:
            [self showBlockingErrorAlert:self.lastErrorMessage];
            break;
        case 3:
            [self showNetworkErrorAlert:self.lastErrorMessage];
            break;
        case 4:
            [self showUpdateAlert:self.lastUpdateVersion
                       isMandatory:self.lastUpdateMandatory
                               url:self.lastUpdateUrl
                         changelog:self.lastUpdateLog
                        completion:self.lastUpdateCompletion];
            break;
        case 5:
            [self showAnnouncementAlert:self.lastAnnouncementTitle
                               message:self.lastAnnouncementMsg
                            nextAction:self.lastAnnouncementAction];
            break;
        default:
            [self showActivationAlert:nil];
            break;
    }
}

// 激活弹窗 (无预填内容)
- (void)showActivationAlert:(NSString *)errorMsg {
    [self showActivationAlertWithPrefilledCode:nil errorMsg:errorMsg];
}

// 激活弹窗 (支持预填卡密)
- (void)showActivationAlertWithPrefilledCode:(NSString *)prefilledCode errorMsg:(NSString *)errorMsg {
    self.currentAlertStyle = 1;
    self.lastErrorMessage = errorMsg;
    [self destroyAlertWindow];
    
    // 如果有 Notice，也在激活弹窗里显示一下
    NSString *baseMsg = errorMsg ?: (self.notice ?: @"请输入卡密以激活应用");
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"应用激活" message:baseMsg preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"请输入卡密";
        textField.textAlignment = NSTextAlignmentCenter;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        // 预填内容
        if (prefilledCode && prefilledCode.length > 0) {
            textField.text = prefilledCode;
        }
    }];

    // 激活按钮
    [alert addAction:[UIAlertAction actionWithTitle:@"激活" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        UITextField *field = alert.textFields.firstObject;
        if (field.text.length > 0) {
            [self verifyCardCode:field.text];
        } else {
            [self showActivationAlert:@"卡密不能为空"];
        }
    }]];
    
    // 购买按钮

    if (self.buyLink.length > 0) {
        [alert addAction:[UIAlertAction actionWithTitle:@"购买卡密" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            self.needsReshowActivation = YES; // 标记需要在返回时重新弹窗
            [self destroyAlertWindow]; // 销毁当前弹窗，避免定时器在跳转期间误重弹
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:self.buyLink] options:@{} completionHandler:nil];
        }]];
    }
    
    // 客服按钮
    if (self.contactLink.length > 0) {
        [alert addAction:[UIAlertAction actionWithTitle:@"联系客服" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            self.needsReshowActivation = YES; // 标记需要在返回时重新弹窗
            [self destroyAlertWindow]; // 销毁当前弹窗，避免定时器在跳转期间误重弹
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:self.contactLink] options:@{} completionHandler:nil];
        }]];
    }
    
    // 【新增】退出应用按钮
    [alert addAction:[UIAlertAction actionWithTitle:@"退出应用" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        exit(0);
    }]];
    
    self.alertWindow = [self createAlertWindow];
    [self.alertWindow makeKeyAndVisible];
    [self.alertWindow.rootViewController presentViewController:alert animated:YES completion:^{
        // 让输入框自动获得焦点，这样长按就能显示粘贴/复制菜单
        UITextField *textField = alert.textFields.firstObject;
        [textField becomeFirstResponder];
    }];
}


// 验证输入的卡密
- (void)verifyCardCode:(NSString *)code {
    [self showLoadingToast:@"正在验证卡密..."];
    [self apiActivate:code completion:^(BOOL success, NSDictionary *data, NSString *msg) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self hideLoadingToast];
            // 手动激活，isManual = YES
            [self handleServerResponse:success data:data msg:msg isManual:YES];
        });
    }];
}

- (void)hideLoadingToast {
    [self destroyAlertWindow];
}

// 错误/冻结 阻断弹窗
- (void)showBlockingErrorAlert:(NSString *)msg {
    self.currentAlertStyle = 2;
    self.lastErrorMessage = msg;
    [self destroyAlertWindow];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"系统验证提示" message:msg preferredStyle:UIAlertControllerStyleAlert];
    
    // 重试
    [alert addAction:[UIAlertAction actionWithTitle:@"重试连接" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self startVerificationFlowWithManualFlag:YES];
    }]];
    
    // 输入卡密 (新增，允许用户在异常状态下输入新卡密)
    [alert addAction:[UIAlertAction actionWithTitle:@"输入卡密" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self showActivationAlert:nil];
    }]];

    if (self.contactLink.length > 0) {
        [alert addAction:[UIAlertAction actionWithTitle:@"联系客服" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            self.needsReshowActivation = YES; // 标记需要在返回时重新弹窗 (这里统一弹激活窗，因为激活窗更通用)
            [self destroyAlertWindow]; // 销毁当前弹窗，避免定时器在跳转期间误重弹
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:self.contactLink] options:@{} completionHandler:nil];
        }]];
    }
    
    // 【新增】退出应用
     [alert addAction:[UIAlertAction actionWithTitle:@"退出应用" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        exit(0);
    }]];
    
    self.alertWindow = [self createAlertWindow];
    [self.alertWindow makeKeyAndVisible];
    [self.alertWindow.rootViewController presentViewController:alert animated:YES completion:nil];
}

- (void)showNetworkErrorAlert:(NSString *)errorMsg {
    self.currentAlertStyle = 3;
    self.lastErrorMessage = errorMsg;
    [self destroyAlertWindow];
    NSString *guidance = @"检测到网络连接受阻。\n如果您是首次安装，请在系统弹窗中选择“允许”使用数据，然后点击重试即可。";
    NSString *fullMsg = [NSString stringWithFormat:@"%@\n\n(详情: %@)", guidance, errorMsg];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"联网权限提示" message:fullMsg preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"重试连接" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self startVerificationFlowWithManualFlag:YES];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"输入卡密" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self showActivationAlert:nil];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"退出应用" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        exit(0);
    }]];
    
    self.alertWindow = [self createAlertWindow];
    [self.alertWindow makeKeyAndVisible];
    [self.alertWindow.rootViewController presentViewController:alert animated:YES completion:nil];
}

- (void)showAnnouncementAlert:(NSString *)title message:(NSString *)msg nextAction:(void(^)(void))action {
    self.currentAlertStyle = 5;
    self.lastAnnouncementTitle = title;
    self.lastAnnouncementMsg = msg;
    self.lastAnnouncementAction = action;
    [self destroyAlertWindow];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"我知道了" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        [self destroyAlertWindow];
        if (action) action();
    }]];
    
    self.alertWindow = [self createAlertWindow];
    [self.alertWindow makeKeyAndVisible];
    [self.alertWindow.rootViewController presentViewController:alert animated:YES completion:nil];
}

- (void)showUpdateAlert:(NSString *)version isMandatory:(BOOL)isMandatory url:(NSString *)url changelog:(NSString *)changelog completion:(void(^)(void))completion {
    self.currentAlertStyle = 4;
    self.lastUpdateVersion = version;
    self.lastUpdateMandatory = isMandatory;
    self.lastUpdateUrl = url;
    self.lastUpdateLog = changelog;
    self.lastUpdateCompletion = completion;
    [self destroyAlertWindow];
    
    NSString *title = [NSString stringWithFormat:@"发现新版本: %@", version];
    NSString *message = (changelog && changelog.length > 0) ? changelog : @"请更新到最新版本以继续使用。";
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    
    // 【公共 Action】立即更新按钮
    [alert addAction:[UIAlertAction actionWithTitle:@"立即更新" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:url] options:@{} completionHandler:nil];
        
        // 无论是否强制更新，点击“立即更新”后都重新弹回，保持阻塞状态
        // 这样既解决了窗口残留假死问题，又强制引导用户操作弹窗
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self showUpdateAlert:version isMandatory:isMandatory url:url changelog:changelog completion:completion];
        });
    }]];
    
    // 【条件 Action】根据是否强制更新，分流不同的控制逻辑
    if (isMandatory) {
        // 模式 A：强制更新 -> 严禁添加“稍后再说”，仅提供“退出应用”
        [alert addAction:[UIAlertAction actionWithTitle:@"退出应用" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            exit(0);
        }]];
    } else {
        // 模式 B：建议更新 -> 允许“稍后再说”
        [alert addAction:[UIAlertAction actionWithTitle:@"稍后再说" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
            [self destroyAlertWindow];
            if (completion) completion();
        }]];
    }
    
    self.alertWindow = [self createAlertWindow];
    [self.alertWindow makeKeyAndVisible];
    [self.alertWindow.rootViewController presentViewController:alert animated:YES completion:nil];
}

- (void)showToast:(NSString *)msg {
    [self destroyAlertWindow];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:msg preferredStyle:UIAlertControllerStyleAlert];
    self.alertWindow = [self createAlertWindow];
    [self.alertWindow makeKeyAndVisible];
    [self.alertWindow.rootViewController presentViewController:alert animated:YES completion:nil];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [alert dismissViewControllerAnimated:YES completion:^{
            [self destroyAlertWindow];
        }];
    });
}

// 显示不自动消失的 Loading (用于首次无缓存连接)
- (void)showLoadingToast:(NSString *)msg {
    self.currentAlertStyle = 0;
    [self destroyAlertWindow];
    
    // 创建窗口
    self.alertWindow = [self createAlertWindow];
    
    // 设置全屏灰色背景 (遮罩效果)
    self.alertWindow.backgroundColor = [UIColor colorWithWhite:0 alpha:0.7];
    
    // 获取根视图
    UIView *containerView = self.alertWindow.rootViewController.view;
    containerView.backgroundColor = [UIColor clearColor]; // 保持透明，由 Window 背景色负责遮罩
    
    // 创建 Loading 容器 (居中)
    UIView *loadingBox = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 160, 120)];
    // 使用 window 自身的 bounds 居中，避免 containerView 在首次加载时布局未完成导致 center 偏到 (0,0)
    loadingBox.center = CGPointMake(self.alertWindow.bounds.size.width / 2, self.alertWindow.bounds.size.height / 2);
    loadingBox.layer.cornerRadius = 10;
    loadingBox.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.9]; // 深色小方块背景
    [containerView addSubview:loadingBox];
    
    // Spinner
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    spinner.center = CGPointMake(80, 45);
    [spinner startAnimating];
    [loadingBox addSubview:spinner];
    
    // Label
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 80, 160, 20)];
    label.text = msg;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont systemFontOfSize:14];
    label.textColor = [UIColor whiteColor];
    [loadingBox addSubview:label];
    
    [self.alertWindow makeKeyAndVisible];
}

#pragma mark - Heartbeat & API

- (void)startHeartbeat {
    if (self.heartbeatTimer) [self.heartbeatTimer invalidate];
    // 采用 CommonModes 确保用户在滑屏交互时，心跳依然能正常触发，防止秒踢延迟
    self.heartbeatTimer = [NSTimer timerWithTimeInterval:self.heartbeatInterval target:self selector:@selector(sendHeartbeat) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.heartbeatTimer forMode:NSRunLoopCommonModes];
}

- (void)sendHeartbeat {
    if (!self.isVerified) return;
    
    NSString *ts = [self getCurrentTimestamp];
    NSString *nonce = [self getRandomNonce];
    NSString *sign = [self signWithTimestamp:ts nonce:nonce];
    
    NSDictionary *body = @{ 
        @"app_key": [self appKey], 
        @"device_id": [self getDeviceId], 
        @"timestamp": ts, 
        @"nonce": nonce,
        @"sign": sign,
        @"platform": @"ios",
        @"current_version": [self appVersion]
    };
    
    [self requestPath:@"/api/heartbeat" body:body completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            NSLog(@"[JiubanAuth] Heartbeat Network Error: %@", error.localizedDescription);
            // 弱网容忍：30秒后重试
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self sendHeartbeat];
            });
            return;
        }
        
        if (json && ([json[@"code"] integerValue] == 1 || [json[@"code"] integerValue] == 403)) {
            // 被踢下线 (冻结/过期/解绑/签名错误)
            NSLog(@"[JiubanAuth] Heartbeat Error/Kick: %@", json[@"msg"]);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.isVerified = NO;
                [self stopHeartbeat];
                [self showActivationAlert:json[@"msg"]];
            });
        }
    }];
}

- (void)apiInitWithCard:(NSString *)cardCode completion:(void (^)(BOOL, NSDictionary *, NSString *))completion {
    NSString *ts = [self getCurrentTimestamp];
    NSString *nonce = [self getRandomNonce];
    NSString *sign = [self signWithTimestamp:ts nonce:nonce];
    
    NSMutableDictionary *body = [NSMutableDictionary dictionaryWithDictionary:@{ 
        @"app_key": [self appKey], 
        @"device_id": [self getDeviceId], 
        @"timestamp": ts, 
        @"nonce": nonce,
        @"sign": sign,
        @"platform": @"ios",
        @"current_version": [self appVersion]
    }];
    
    if (cardCode) { 
        body[@"card_code"] = cardCode; 
        body[@"is_auto"] = @(YES); 
    }
    
    [self requestPath:@"/api/init" body:body completion:^(NSDictionary *json, NSError *error) {
        if (error) { completion(NO, nil, error.localizedDescription); return; }
        if ([json[@"code"] integerValue] == 0) {
            completion(YES, json[@"data"], nil);
        } else {
            // 如果是业务逻辑错误（例如设备未绑定），视为“未激活”状态，并保留服务器返回的完整配置数据（如客服/购买链接/启动延迟等）
            NSMutableDictionary *inactiveData = [NSMutableDictionary dictionary];
            if ([json[@"data"] isKindOfClass:[NSDictionary class]]) {
                [inactiveData addEntriesFromDictionary:json[@"data"]];
            }
            inactiveData[@"status"] = @"inactive";
            inactiveData[@"msg"] = json[@"msg"] ?: @"设备未绑定";
            completion(YES, inactiveData, nil);
        }
    }];
}

- (void)apiActivate:(NSString *)code completion:(void (^)(BOOL, NSDictionary *, NSString *))completion {
    NSString *ts = [self getCurrentTimestamp];
    NSString *nonce = [self getRandomNonce];
    NSString *sign = [self signWithTimestamp:ts nonce:nonce];
    
    NSDictionary *body = @{ 
        @"app_key": [self appKey], 
        @"code": code, 
        @"device_id": [self getDeviceId], 
        @"timestamp": ts, 
        @"nonce": nonce,
        @"sign": sign,
        @"platform": @"ios",
        @"current_version": [self appVersion]
    };
    
    [self requestPath:@"/api/activate" body:body completion:^(NSDictionary *json, NSError *error) {
        if (error) { completion(NO, nil, error.localizedDescription); return; }
        if ([json[@"code"] integerValue] == 0) completion(YES, json[@"data"], nil);
        else completion(NO, nil, json[@"msg"]);
    }];
}

- (void)requestPath:(NSString *)path body:(NSDictionary *)body completion:(void (^)(NSDictionary *, NSError *))completion {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@", [self serverUrl], path]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 10.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { 
            completion(nil, error); 
            return; 
        }
        
        // 尝试解析
        NSError *jsonError;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        
        if (jsonError || !json) {
            NSString *rawStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSString *errMsg = rawStr.length > 0 ? rawStr : @"Server returned invalid data";
            completion(nil, [NSError errorWithDomain:@"ServerError" code:((NSHTTPURLResponse*)response).statusCode userInfo:@{NSLocalizedDescriptionKey: errMsg}]);
            return;
        }
        
        // --- 核心安全性更新: 校验服务器响应签名 ---
        NSString *serverSign = json[@"sign"];
        if (serverSign) {
            BOOL signValid = [self verifyResponseSign:serverSign data:json[@"data"] code:[json[@"code"] integerValue]];
            if (!signValid) {
                NSLog(@"[JiubanAuth] Security Alert: Server response signature is UNTRUSTED!");
                completion(nil, [NSError errorWithDomain:@"SecurityError" code:403 userInfo:@{NSLocalizedDescriptionKey: @"数据完整性检查失败：响应被篡改"}]);
                return;
            }
        }
        
        // 更新时间同步
        if (json[@"server_time"]) {
            long serverTime = [json[@"server_time"] longValue];
            long localTime = (long)[[NSDate date] timeIntervalSince1970];
            self.serverTimeOffset = serverTime - localTime;
        }
        
        completion(json, nil);
    }] resume];
}

#pragma mark - Utils

- (BOOL)verifyResponseSign:(NSString *)sign data:(NSDictionary *)data code:(NSInteger)code {
    if (!sign) return NO;
    
    // 规则: code + status + expire_time + app_secret
    NSString *status = SAFE_STR(data[@"status"]);
    NSString *expire = SAFE_STR(data[@"expire_time"]);
    NSString *secret = [[self appSecret] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    NSString *rawStr = [NSString stringWithFormat:@"%ld%@%@%@", (long)code, status, expire, secret];
    
    // iOS 平台使用 SHA256 算法校验响应
    NSString *calcSign = [self sha256:rawStr];
    return [[calcSign lowercaseString] isEqualToString:[sign lowercaseString]];
}

- (NSString *)getRandomNonce {
    NSString *alphabet = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    NSMutableString *s = [NSMutableString stringWithCapacity:16];
    for (NSUInteger i = 0; i < 16; i++) {
        uint32_t r = arc4random_uniform((uint32_t)[alphabet length]);
        [s appendFormat:@"%C", [alphabet characterAtIndex:r]];
    }
    return s;
}

- (void)updateConfig:(NSDictionary *)data {
    if (!data || ![data isKindOfClass:[NSDictionary class]]) return;
    
    // 增量更新逻辑：只有当新值不为空且非 NSNull 时才覆盖，防止激活后的空数据包冲掉有效配置
    id contact = data[@"contact_link"];
    if (contact && ![contact isKindOfClass:[NSNull class]]) self.contactLink = contact;
    
    id buy = data[@"buy_link"];
    if (buy && ![buy isKindOfClass:[NSNull class]]) self.buyLink = buy;
    
    id popup = data[@"popup_announcement"];
    if (popup && ![popup isKindOfClass:[NSNull class]]) self.popupAnnouncement = popup;
    
    id notice = data[@"notice"];
    if (notice && ![notice isKindOfClass:[NSNull class]]) self.notice = notice;
    
    // 动态心跳监测适配
    id intervalObj = data[@"heartbeat_interval"];
    if (intervalObj && ![intervalObj isKindOfClass:[NSNull class]]) {
        NSTimeInterval newInterval = [intervalObj doubleValue];
        // 最小保护 10 秒，防止恶意或错误配置导致死循环 API
        if (newInterval >= 10.0 && newInterval != self.heartbeatInterval) {
            NSLog(@"[JiubanAuth] Heartbeat Interval updated: %.0fs -> %.0fs", self.heartbeatInterval, newInterval);
            self.heartbeatInterval = newInterval;
            if (self.isVerified) {
                // 如果当前已是验证通过状态，立即重启定时器以应用新频率
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self startHeartbeat];
                });
            }
        }
    }
    
    // 动态启动延迟适配
    id delayObj = data[@"launch_delay"];
    if (delayObj && ![delayObj isKindOfClass:[NSNull class]]) {
        double newDelay = [delayObj doubleValue];
        NSLog(@"[JiubanAuth] Server returned launch_delay: %.2f", newDelay);
        if (newDelay >= 0.0) {
            [[NSUserDefaults standardUserDefaults] setDouble:newDelay forKey:@"jb_launch_delay"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            NSLog(@"[JiubanAuth] Saved launch_delay to NSUserDefaults: %.2f", newDelay);
        }
    }
}

- (NSString *)getDeviceId {
    NSString *uuid = [[NSUserDefaults standardUserDefaults] stringForKey:@"jb_device_id_v2"];
    if (!uuid) {
        // 优先使用 IDFV，保证卸载重装不变
        uuid = [[UIDevice currentDevice] identifierForVendor].UUIDString;
        if (!uuid) {
            uuid = [[NSUUID UUID] UUIDString];
        }
        [[NSUserDefaults standardUserDefaults] setObject:uuid forKey:@"jb_device_id_v2"];
    }
    return uuid;
}

- (NSString *)getCurrentTimestamp {
    return [NSString stringWithFormat:@"%ld", (long)[[NSDate date] timeIntervalSince1970] + self.serverTimeOffset];
}

- (NSString *)signWithTimestamp:(NSString *)ts nonce:(NSString *)nonce {
    // 规则: app_key + app_secret + timestamp + nonce
    NSString *raw = [NSString stringWithFormat:@"%@%@%@%@", [self appKey], [self appSecret], ts, nonce];
    return [self sha256:raw];
}

- (NSString *)sha256:(NSString *)input {
    const char *str = [input UTF8String];
    unsigned char result[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(str, (CC_LONG)strlen(str), result);
    NSMutableString *ret = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for(int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [ret appendFormat:@"%02x", result[i]];
    return ret;
}

@end
