#import <UIKit/UIKit.h>

// ============= 配置区域 =============
#define API_BASE_URL @"https://124.221.191.2/api.php"
#define APP_KEY @"F2BC57BF898505E3E6AB6E3091FBFEA517D09FF639AA6F5CF06273E7862E32BE"
#define ANNOUNCEMENT @"demo测试公告"
#define BUY_URL @"https://example.com/buy"
#define HEARTBEAT_INTERVAL 60.0
// ====================================

static BOOL isAuthorized = NO;
static BOOL hasShownPopup = NO;
static NSString *savedCardKey = nil;
static NSTimer *heartbeatTimer = nil;

static NSString* getUDID() {
    return [[[UIDevice currentDevice] identifierForVendor] UUIDString];
}

static void showAuthPopup(void);

static void sendHeartbeat() {
    if (!isAuthorized || !savedCardKey) return;
    
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@?action=heartbeat", API_BASE_URL]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    
    NSDictionary *bodyDict = @{
        @"card_key": savedCardKey,
        @"udid": getUDID(),
        @"app_key": APP_KEY,
        @"timestamp": @((long)[[NSDate date] timeIntervalSince1970])
    };
    
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:bodyDict options:0 error:nil];
    request.HTTPBody = jsonData;
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) return;
        
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        BOOL status = [json[@"status"] boolValue];
        
        if (!status) {
            isAuthorized = NO;
            hasShownPopup = NO;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (heartbeatTimer) {
                    [heartbeatTimer invalidate];
                    heartbeatTimer = nil;
                }
                showAuthPopup();
            });
        }
    }];
    [task resume];
}

static void startHeartbeat() {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (heartbeatTimer) [heartbeatTimer invalidate];
        heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:HEARTBEAT_INTERVAL repeats:YES block:^(NSTimer *timer) {
            sendHeartbeat();
        }];
    });
}

static void validateCardKey(NSString *cardKey, void (^completion)(BOOL success, NSString *message)) {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@?action=validate", API_BASE_URL]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    
    NSDictionary *bodyDict = @{
        @"card_key": cardKey,
        @"udid": getUDID(),
        @"app_key": APP_KEY
    };
    
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:bodyDict options:0 error:nil];
    request.HTTPBody = jsonData;
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            if (completion) completion(NO, @"网络错误");
            return;
        }
        
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        BOOL status = [json[@"status"] boolValue];
        NSString *msg = json[@"message"] ?: @"验证失败";
        
        if (status) {
            isAuthorized = YES;
            savedCardKey = cardKey;
            [[NSUserDefaults standardUserDefaults] setObject:cardKey forKey:@"QQAuth_CardKey"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            startHeartbeat();
        }
        
        if (completion) completion(status, msg);
    }];
    [task resume];
}

static void showAuthPopup() {
    if (isAuthorized || hasShownPopup) return;
    hasShownPopup = YES;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
        if (!keyWindow) {
            if (@available(iOS 13.0, *)) {
                for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                    if (scene.activationState == UISceneActivationStateForegroundActive) {
                        for (UIWindow *window in scene.windows) {
                            if (window.isKeyWindow) { keyWindow = window; break; }
                        }
                    }
                }
            }
        }
        
        if (!keyWindow) { hasShownPopup = NO; return; }
        
        UIViewController *rootVC = keyWindow.rootViewController;
        while (rootVC.presentedViewController) rootVC = rootVC.presentedViewController;
        if (!rootVC) { hasShownPopup = NO; return; }
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"卡密验证"
                                                                       message:ANNOUNCEMENT
                                                                preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
            textField.placeholder = @"请输入解锁码";
            textField.text = savedCardKey;
        }];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"解锁" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            NSString *cardKey = alert.textFields.firstObject.text;
            hasShownPopup = NO;
            if (cardKey.length > 0) {
                validateCardKey(cardKey, ^(BOOL success, NSString *message) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        UIAlertController *resultAlert = [UIAlertController alertControllerWithTitle:success ? @"验证成功" : @"验证失败"
                                                                                             message:message
                                                                                      preferredStyle:UIAlertControllerStyleAlert];
                        [resultAlert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                            if (!success) showAuthPopup();
                        }]];
                        [rootVC presentViewController:resultAlert animated:YES completion:nil];
                    });
                });
            } else {
                showAuthPopup();
            }
        }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"获取解锁码" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            hasShownPopup = NO;
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:BUY_URL] options:@{} completionHandler:^(BOOL s) {
                showAuthPopup();
            }];
        }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
            hasShownPopup = NO;
        }]];
        
        [rootVC presentViewController:alert animated:YES completion:nil];
    });
}

// Hook UIViewController 的 viewDidAppear
%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"[QQAuthPlugin] First viewDidAppear - showing popup");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            showAuthPopup();
        });
    });
}

%end

%ctor {
    NSLog(@"[QQAuthPlugin] ========== LOADED ==========");
    savedCardKey = [[NSUserDefaults standardUserDefaults] objectForKey:@"QQAuth_CardKey"];
    NSLog(@"[QQAuthPlugin] Saved card key: %@", savedCardKey ?: @"none");
}
