/**
 * Draven Mortis VCAM Pro — iOS tweak (rootless / Dopamine, arm64 + arm64e)
 *
 * Architecture
 * ------------
 *  SpringBoard : Hosts the ALWAYS-ON floating island + control panel (over every
 *                app), stores settings and broadcasts them system-wide through a
 *                Darwin notify state (works even inside sandboxed apps).
 *  Apps        : (App Store apps + Camera) — no UI at all. They read the settings,
 *                connect to the PC Studio only while a camera is running, and
 *                replace camera frames (sample buffers + preview layers).
 */

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <notify.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

#define DMLog(fmt, ...) NSLog(@"[DravenMortis] " fmt, ##__VA_ARGS__)

static CFStringRef const kDMDomain = CFSTR("com.dravenmortis.vcam");
static const char *const kDMStateName = "com.dravenmortis.vcam.state";
static NSString *const kDMStatusNote = @"DMStatusChanged";
static NSString *const kDMDefaultIP = @"192.168.1.4";
static const int kDMPort = 9998;

// ============================================================================
// MARK: - Shared settings (encoded into one 64-bit Darwin notify state)
// ============================================================================

static volatile BOOL g_enabled = NO;
static volatile BOOL g_flip = NO;
static volatile float g_zoom = 1.0f;
static volatile int g_rotation = 0;      // user rotation, steps of 90° (0-3)
static volatile uint32_t g_ip = 0;        // IPv4, network byte order
static volatile BOOL g_connected = NO;

#define DM_MAGIC 0xD7ULL

static uint64_t DMEncodeState(void) {
    uint64_t s = (uint64_t)g_ip;
    if (g_enabled) s |= (1ULL << 32);
    if (g_flip) s |= (1ULL << 33);
    s |= ((uint64_t)(g_rotation & 3)) << 34;
    s |= ((uint64_t)(lroundf(g_zoom * 10.0f) & 0xFF)) << 40;
    s |= DM_MAGIC << 56;
    return s;
}

static BOOL DMDecodeState(uint64_t s) {
    if (((s >> 56) & 0xFF) != DM_MAGIC) return NO;
    g_ip = (uint32_t)(s & 0xFFFFFFFFULL);
    g_enabled = ((s >> 32) & 1) != 0;
    g_flip = ((s >> 33) & 1) != 0;
    g_rotation = (int)((s >> 34) & 3);
    float z = (float)((s >> 40) & 0xFF) / 10.0f;
    g_zoom = (z >= 1.0f && z <= 5.0f) ? z : 1.0f;
    return YES;
}

static NSString *DMIPString(void) {
    uint32_t ip = g_ip;
    if (!ip) return @"0.0.0.0";
    char buf[INET_ADDRSTRLEN] = {0};
    struct in_addr a = { .s_addr = ip };
    inet_ntop(AF_INET, &a, buf, sizeof(buf));
    return [NSString stringWithUTF8String:buf];
}

static BOOL DMParseIP(NSString *str, uint32_t *out) {
    struct in_addr a;
    if (!str.length || inet_pton(AF_INET, str.UTF8String, &a) != 1) return NO;
    *out = a.s_addr;
    return YES;
}

static void DMPostStatus(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:kDMStatusNote object:nil];
    });
}

static void DMSetConnected(BOOL c) {
    if (g_connected == c) return;
    g_connected = c;
    DMPostStatus();
}

// ============================================================================
// MARK: - Networking
// ============================================================================

static int DMConnect(uint32_t ip, int timeoutSec) {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return -1;

    int one = 1;
    setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    int flags = fcntl(sock, F_GETFL, 0);
    fcntl(sock, F_SETFL, flags | O_NONBLOCK);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kDMPort);
    addr.sin_addr.s_addr = ip;

    int r = connect(sock, (struct sockaddr *)&addr, sizeof(addr));
    if (r < 0 && errno != EINPROGRESS) { close(sock); return -1; }
    if (r < 0) {
        fd_set wfds;
        FD_ZERO(&wfds);
        FD_SET(sock, &wfds);
        struct timeval tv = { .tv_sec = timeoutSec, .tv_usec = 0 };
        if (select(sock + 1, NULL, &wfds, NULL, &tv) <= 0) { close(sock); return -1; }
        int err = 0;
        socklen_t len = sizeof(err);
        getsockopt(sock, SOL_SOCKET, SO_ERROR, &err, &len);
        if (err) { close(sock); return -1; }
    }

    fcntl(sock, F_SETFL, flags);
    struct timeval rtv = { .tv_sec = 2, .tv_usec = 0 };
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &rtv, sizeof(rtv));
    return sock;
}

// --- Latest frame store ------------------------------------------------------

static os_unfair_lock g_frameLock = OS_UNFAIR_LOCK_INIT;
static CIImage *g_frameImage = nil;
static CGImageRef g_frameCG = NULL;
static uint64_t g_frameSerial = 0;
static CFAbsoluteTime g_frameTime = 0;

static void DMStoreFrame(NSData *jpeg) {
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
    if (!src) return;
    NSDictionary *opts = @{ (__bridge id)kCGImageSourceShouldCacheImmediately: @YES };
    CGImageRef cg = CGImageSourceCreateImageAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
    CFRelease(src);
    if (!cg) return;

    CIImage *ci = [CIImage imageWithCGImage:cg];
    CGImageRef old = NULL;
    os_unfair_lock_lock(&g_frameLock);
    old = g_frameCG;
    g_frameCG = cg;
    g_frameImage = ci;
    g_frameSerial++;
    g_frameTime = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_unlock(&g_frameLock);
    if (old) CGImageRelease(old);
}

static CIImage *DMCopyFrameImage(void) {
    CIImage *img = nil;
    os_unfair_lock_lock(&g_frameLock);
    if (CFAbsoluteTimeGetCurrent() - g_frameTime < 3.0) img = g_frameImage;
    os_unfair_lock_unlock(&g_frameLock);
    return img;
}

static CGImageRef DMCopyFrameCG(uint64_t *serial) {
    CGImageRef r = NULL;
    os_unfair_lock_lock(&g_frameLock);
    if (g_frameCG && CFAbsoluteTimeGetCurrent() - g_frameTime < 3.0) {
        r = CGImageRetain(g_frameCG);
        *serial = g_frameSerial;
    }
    os_unfair_lock_unlock(&g_frameLock);
    return r;
}

// --- Stream client (apps only) ----------------------------------------------

static volatile int32_t g_sockGen = 0;
static BOOL g_sockActive = NO; // main thread only

static BOOL DMRecvAll(int sock, void *buf, size_t len, int32_t gen) {
    size_t got = 0;
    while (got < len) {
        if (gen != g_sockGen) return NO;
        ssize_t r = recv(sock, (char *)buf + got, len - got, 0);
        if (r > 0) { got += (size_t)r; continue; }
        if (r == 0) return NO;
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) continue; // PC idle, keep waiting
        return NO;
    }
    return YES;
}

static void DMStreamLoop(int32_t gen) {
    int backoff = 1;
    while (gen == g_sockGen) {
        @autoreleasepool {
            uint32_t ip = g_ip;
            int sock = ip ? DMConnect(ip, 4) : -1;
            if (sock < 0) {
                DMSetConnected(NO);
                for (int i = 0; i < backoff * 4 && gen == g_sockGen; i++) usleep(250000);
                backoff = MIN(backoff * 2, 8);
                continue;
            }
            backoff = 1;
            DMSetConnected(YES);
            DMLog(@"Conectado al PC %@:%d", DMIPString(), kDMPort);

            while (gen == g_sockGen) {
                @autoreleasepool {
                    uint32_t netLen = 0;
                    if (!DMRecvAll(sock, &netLen, 4, gen)) break;
                    uint32_t len = ntohl(netLen);
                    if (len == 0 || len > 12 * 1024 * 1024) break;
                    NSMutableData *buf = [NSMutableData dataWithLength:len];
                    if (!DMRecvAll(sock, buf.mutableBytes, len, gen)) break;
                    DMStoreFrame(buf);
                }
            }
            close(sock);
            if (gen == g_sockGen) DMSetConnected(NO);
        }
    }
}

static void DMStreamStart(void) {
    if (g_sockActive || !g_ip) return;
    g_sockActive = YES;
    int32_t gen = __atomic_add_fetch(&g_sockGen, 1, __ATOMIC_SEQ_CST);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        DMStreamLoop(gen);
    });
}

static void DMStreamStop(void) {
    if (!g_sockActive) return;
    g_sockActive = NO;
    __atomic_add_fetch(&g_sockGen, 1, __ATOMIC_SEQ_CST);
    DMSetConnected(NO);
}

// ============================================================================
// MARK: - Generic safe hook helper
// ============================================================================

// Hooks -[cls sel]. If cls only INHERITS the method, an override is added to cls
// (so the superclass — e.g. CALayer — is never touched for everyone else).
static BOOL DMHook(Class cls, SEL sel, id block, IMP *origOut) {
    if (!cls) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    IMP inherited = method_getImplementation(m);
    *origOut = inherited;
    IMP newImp = imp_implementationWithBlock(block);
    if (!class_addMethod(cls, sel, newImp, method_getTypeEncoding(m))) {
        *origOut = method_setImplementation(m, newImp);
    }
    return YES;
}

// ============================================================================
// MARK: - APP SIDE: camera frame replacement
// ============================================================================

static BOOL g_cameraActive = NO; // main thread only
static int g_appStateToken = -1;
static CIContext *g_ciContext = nil;
static NSMutableSet<NSString *> *g_hookedDelegates = nil;

static void DMAppUpdateStreaming(BOOL ipChanged) {
    BOOL want = g_enabled && g_cameraActive && g_ip;
    if (!want) { DMStreamStop(); return; }
    if (ipChanged) DMStreamStop();
    DMStreamStart();
}

static void DMEnsureStreaming(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ DMEnsureStreaming(); });
        return;
    }
    g_cameraActive = YES;
    DMAppUpdateStreaming(NO);
}

static CIImage *DMTransformedFrame(CIImage *src, CGFloat W, CGFloat H) {
    int steps = g_rotation;
    CGRect e = src.extent;
    // Camera buffers are usually sensor-native landscape; the app rotates them
    // for display. Pre-rotate portrait PC frames so they end up upright.
    if (e.size.height > e.size.width && W > H) steps += 1;
    steps &= 3;

    static const CGImagePropertyOrientation orients[4] = {
        kCGImagePropertyOrientationUp, kCGImagePropertyOrientationLeft,
        kCGImagePropertyOrientationDown, kCGImagePropertyOrientationRight
    };
    CIImage *img = steps ? [src imageByApplyingCGOrientation:orients[steps]] : src;
    if (g_flip) img = [img imageByApplyingCGOrientation:kCGImagePropertyOrientationUpMirrored];

    e = img.extent;
    img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(-e.origin.x, -e.origin.y)];
    CGFloat scale = MAX(W / e.size.width, H / e.size.height) * g_zoom;
    img = [img imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGFloat tx = (W - e.size.width * scale) / 2.0;
    CGFloat ty = (H - e.size.height * scale) / 2.0;
    return [img imageByApplyingTransform:CGAffineTransformMakeTranslation(tx, ty)];
}

static void DMReplaceSampleBuffer(CMSampleBufferRef sb) {
    if (!g_enabled || !sb) return;
    CIImage *frame = DMCopyFrameImage();
    if (!frame) return;

    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb) return;
    size_t W = CVPixelBufferGetWidth(pb), H = CVPixelBufferGetHeight(pb);
    if (!W || !H) return;

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_ciContext = [CIContext contextWithOptions:@{ kCIContextCacheIntermediates: @NO }];
    });

    CIImage *img = DMTransformedFrame(frame, (CGFloat)W, (CGFloat)H);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    [g_ciContext render:img toCVPixelBuffer:pb bounds:CGRectMake(0, 0, W, H) colorSpace:cs];
    CGColorSpaceRelease(cs);
}

typedef void (*DMCaptureIMP)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *);

// Every delegate class gets its OWN block IMP capturing its OWN original IMP.
static void DMHookDelegateClass(Class cls) {
    if (!cls) return;
    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    // Walk up to the class that actually owns this implementation.
    Class owner = cls;
    Class sup = class_getSuperclass(owner);
    while (sup && class_getInstanceMethod(sup, sel) == m) {
        owner = sup;
        sup = class_getSuperclass(owner);
    }

    static dispatch_once_t once;
    dispatch_once(&once, ^{ g_hookedDelegates = [NSMutableSet set]; });

    @synchronized (g_hookedDelegates) {
        NSString *key = NSStringFromClass(owner);
        if (!key || [g_hookedDelegates containsObject:key]) return;
        [g_hookedDelegates addObject:key];

        DMCaptureIMP orig = (DMCaptureIMP)method_getImplementation(m);
        if (!orig) return;
        IMP hook = imp_implementationWithBlock(^(id self, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) {
            if (g_enabled) {
                @try { DMReplaceSampleBuffer(sampleBuffer); } @catch (NSException *e) {}
            }
            orig(self, sel, output, sampleBuffer, connection);
        });
        method_setImplementation(m, hook);
        DMLog(@"Hook de camara en %@", key);
    }
}

// --- Preview layer overlay (Camera app & apps that only show a preview) ------

static const void *kDMOverlayKey = &kDMOverlayKey;
static NSHashTable *g_previewLayers = nil;
static uint64_t g_shownSerial = 0;

@interface DMOverlayTicker : NSObject
+ (instancetype)shared;
- (void)start;
@end

@implementation DMOverlayTicker {
    CADisplayLink *_link;
}

+ (instancetype)shared {
    static DMOverlayTicker *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [DMOverlayTicker new]; });
    return t;
}

- (void)start {
    if (_link) return;
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    _link.preferredFramesPerSecond = 30;
    [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)tick:(CADisplayLink *)link {
    BOOL on = g_enabled;
    uint64_t serial = 0;
    CGImageRef img = on ? DMCopyFrameCG(&serial) : NULL;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *preview in g_previewLayers) {
        CALayer *container = objc_getAssociatedObject(preview, kDMOverlayKey);
        CALayer *content = container.sublayers.firstObject;
        if (!container || !content) continue;
        if (!img) { container.hidden = YES; continue; }

        container.hidden = NO;
        container.frame = preview.bounds;
        CGSize s = preview.bounds.size;
        BOOL swap = (g_rotation & 1) != 0;
        content.bounds = CGRectMake(0, 0, swap ? s.height : s.width, swap ? s.width : s.height);
        content.position = CGPointMake(s.width / 2.0, s.height / 2.0);
        CATransform3D t = CATransform3DMakeRotation(g_rotation * M_PI_2, 0, 0, 1);
        t = CATransform3DScale(t, g_flip ? -g_zoom : g_zoom, g_zoom, 1);
        content.transform = t;
        if (serial != g_shownSerial || !content.contents) content.contents = (__bridge id)img;
    }
    [CATransaction commit];

    if (img) {
        g_shownSerial = serial;
        CGImageRelease(img);
    }
}
@end

static void DMAttachOverlay(CALayer *preview) {
    if (![NSThread isMainThread] || !preview) return;
    if (!g_previewLayers) g_previewLayers = [NSHashTable weakObjectsHashTable];
    if (![g_previewLayers containsObject:preview]) {
        [g_previewLayers addObject:preview];
        [[DMOverlayTicker shared] start];
        DMEnsureStreaming();
    }
    if (objc_getAssociatedObject(preview, kDMOverlayKey)) return;

    CALayer *container = [CALayer layer];
    container.masksToBounds = YES;
    container.zPosition = 1000;
    container.hidden = YES;
    CALayer *content = [CALayer layer];
    content.contentsGravity = kCAGravityResizeAspectFill;
    [container addSublayer:content];
    objc_setAssociatedObject(preview, kDMOverlayKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [preview addSublayer:container];
}

// --- Hook installation -------------------------------------------------------

static void (*orig_setSampleBufferDelegate)(id, SEL, id, dispatch_queue_t);
static void (*orig_startRunning)(id, SEL);
static void (*orig_previewLayoutSublayers)(id, SEL);
static NSData *(*orig_photoFileData)(id, SEL);
static CGImageRef (*orig_photoCGImage)(id, SEL);
static CVPixelBufferRef (*orig_photoPixelBuffer)(id, SEL);
static void (*orig_captureStillImage)(id, SEL, AVCaptureConnection *, void (^)(CMSampleBufferRef, NSError *));

static NSData *DMGetTransformedJpegData(void) {
    uint64_t serial = 0;
    CGImageRef cg = DMCopyFrameCG(&serial);
    if (!cg) return nil;
    UIImage *img = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return UIImageJPEGRepresentation(img, 0.92);
}

static void DMInstallCameraHooks(void) {
    SEL setDelSel = @selector(setSampleBufferDelegate:queue:);
    DMHook(NSClassFromString(@"AVCaptureVideoDataOutput"), setDelSel,
        ^(id self, id delegate, dispatch_queue_t queue) {
            if (delegate) {
                @try { DMHookDelegateClass([delegate class]); } @catch (NSException *e) {}
            }
            orig_setSampleBufferDelegate(self, setDelSel, delegate, queue);
        }, (IMP *)&orig_setSampleBufferDelegate);

    SEL startSel = @selector(startRunning);
    DMHook(NSClassFromString(@"AVCaptureSession"), startSel,
        ^(AVCaptureSession *self) {
            @try {
                for (AVCaptureOutput *o in self.outputs) {
                    if ([o isKindOfClass:[AVCaptureVideoDataOutput class]]) {
                        id d = [(AVCaptureVideoDataOutput *)o sampleBufferDelegate];
                        if (d) DMHookDelegateClass([d class]);
                    }
                }
            } @catch (NSException *e) {}
            DMEnsureStreaming();
            orig_startRunning(self, startSel);
        }, (IMP *)&orig_startRunning);

    SEL layoutSel = @selector(layoutSublayers);
    DMHook(NSClassFromString(@"AVCaptureVideoPreviewLayer"), layoutSel,
        ^(CALayer *self) {
            orig_previewLayoutSublayers(self, layoutSel);
            @try { DMAttachOverlay(self); } @catch (NSException *e) {}
        }, (IMP *)&orig_previewLayoutSublayers);

    // --- STILL PHOTO HOOKS (Fixes photo capture taking real camera image) ---
    Class photoClass = NSClassFromString(@"AVCapturePhoto");
    if (photoClass) {
        // 1. Hook fileDataRepresentation (JPEG/HEIC file output)
        DMHook(photoClass, @selector(fileDataRepresentation),
            ^NSData *(id self) {
                if (g_enabled) {
                    NSData *d = DMGetTransformedJpegData();
                    if (d) return d;
                }
                return orig_photoFileData ? orig_photoFileData(self, @selector(fileDataRepresentation)) : nil;
            }, (IMP *)&orig_photoFileData);

        // 2. Hook CGImageRepresentation
        DMHook(photoClass, @selector(CGImageRepresentation),
            ^CGImageRef(id self) {
                if (g_enabled) {
                    uint64_t serial = 0;
                    CGImageRef cg = DMCopyFrameCG(&serial);
                    if (cg) return cg;
                }
                return orig_photoCGImage ? orig_photoCGImage(self, @selector(CGImageRepresentation)) : NULL;
            }, (IMP *)&orig_photoCGImage);

        // 3. Hook pixelBuffer
        DMHook(photoClass, @selector(pixelBuffer),
            ^CVPixelBufferRef(id self) {
                CVPixelBufferRef pb = orig_photoPixelBuffer ? orig_photoPixelBuffer(self, @selector(pixelBuffer)) : NULL;
                if (g_enabled && pb) {
                    size_t W = CVPixelBufferGetWidth(pb), H = CVPixelBufferGetHeight(pb);
                    CIImage *frame = DMCopyFrameImage();
                    if (frame && W && H) {
                        CIImage *img = DMTransformedFrame(frame, (CGFloat)W, (CGFloat)H);
                        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
                        CVPixelBufferLockBaseAddress(pb, 0);
                        if (!g_ciContext) {
                            g_ciContext = [CIContext contextWithOptions:@{ kCIContextCacheIntermediates: @NO }];
                        }
                        [g_ciContext render:img toCVPixelBuffer:pb bounds:CGRectMake(0, 0, W, H) colorSpace:cs];
                        CVPixelBufferUnlockBaseAddress(pb, 0);
                        CGColorSpaceRelease(cs);
                    }
                }
                return pb;
            }, (IMP *)&orig_photoPixelBuffer);
    }

    // 4. Hook AVCaptureStillImageOutput (legacy photo capture)
    Class stillOutClass = NSClassFromString(@"AVCaptureStillImageOutput");
    if (stillOutClass) {
        DMHook(stillOutClass, @selector(captureStillImageAsynchronouslyFromConnection:completionHandler:),
            ^(id self, AVCaptureConnection *conn, void (^handler)(CMSampleBufferRef, NSError *)) {
                void (^wrapped)(CMSampleBufferRef, NSError *) = ^(CMSampleBufferRef sb, NSError *err) {
                    if (g_enabled && sb) {
                        @try { DMReplaceSampleBuffer(sb); } @catch (NSException *e) {}
                    }
                    if (handler) handler(sb, err);
                };
                orig_captureStillImage(self, @selector(captureStillImageAsynchronouslyFromConnection:completionHandler:), conn, wrapped);
            }, (IMP *)&orig_captureStillImage);

        Method m = class_getClassMethod(stillOutClass, @selector(jpegStillImageNSDataRepresentation:));
        if (m) {
            NSData *(*orig_jpegRep)(id, SEL, CMSampleBufferRef) = (NSData *(*)(id, SEL, CMSampleBufferRef))method_getImplementation(m);
            method_setImplementation(m, imp_implementationWithBlock(^NSData *(id self, CMSampleBufferRef sb) {
                if (g_enabled) {
                    NSData *d = DMGetTransformedJpegData();
                    if (d) return d;
                }
                return orig_jpegRep(self, @selector(jpegStillImageNSDataRepresentation:), sb);
            }));
        }
    }
}

static void DMAppApplyState(void) {
    uint64_t s = 0;
    if (g_appStateToken < 0 || notify_get_state(g_appStateToken, &s) != NOTIFY_STATUS_OK) return;
    uint32_t oldIP = g_ip;
    if (!DMDecodeState(s)) return;
    DMAppUpdateStreaming(oldIP != g_ip);
}

static void DMAppInit(void) {
    notify_register_dispatch(kDMStateName, &g_appStateToken, dispatch_get_main_queue(), ^(int token) {
        DMAppApplyState();
    });
    DMAppApplyState();
    DMInstallCameraHooks();

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil
                     queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { DMStreamStop(); }];
    [nc addObserverForName:UIApplicationWillEnterForegroundNotification object:nil
                     queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        DMAppApplyState();
        DMAppUpdateStreaming(NO);
    }];
}

// ============================================================================
// MARK: - SPRINGBOARD SIDE: settings
// ============================================================================

static int g_pubToken = -1;

static void DMPublish(void) {
    if (g_pubToken < 0 && notify_register_check(kDMStateName, &g_pubToken) != NOTIFY_STATUS_OK) {
        g_pubToken = -1;
        return;
    }
    notify_set_state(g_pubToken, DMEncodeState());
    notify_post(kDMStateName);
}

static id DMPref(CFStringRef key, Class cls) {
    id v = CFBridgingRelease(CFPreferencesCopyAppValue(key, kDMDomain));
    return [v isKindOfClass:cls] ? v : nil;
}

static void DMSBLoad(void) {
    CFPreferencesAppSynchronize(kDMDomain);
    uint32_t ip = 0;
    if (!DMParseIP(DMPref(CFSTR("ip"), [NSString class]), &ip)) DMParseIP(kDMDefaultIP, &ip);
    g_ip = ip;
    g_enabled = [DMPref(CFSTR("enabled"), [NSNumber class]) boolValue];
    g_flip = [DMPref(CFSTR("flip"), [NSNumber class]) boolValue];
    g_rotation = [DMPref(CFSTR("rotation"), [NSNumber class]) intValue] & 3;
    float z = [DMPref(CFSTR("zoom"), [NSNumber class]) floatValue];
    g_zoom = (z >= 1.0f && z <= 5.0f) ? z : 1.0f;
}

static void DMSBSaveAndPublish(void) {
    CFPreferencesSetAppValue(CFSTR("ip"), (__bridge CFStringRef)DMIPString(), kDMDomain);
    CFPreferencesSetAppValue(CFSTR("enabled"), g_enabled ? kCFBooleanTrue : kCFBooleanFalse, kDMDomain);
    CFPreferencesSetAppValue(CFSTR("flip"), g_flip ? kCFBooleanTrue : kCFBooleanFalse, kDMDomain);
    CFPreferencesSetAppValue(CFSTR("rotation"), (__bridge CFNumberRef)@(g_rotation), kDMDomain);
    CFPreferencesSetAppValue(CFSTR("zoom"), (__bridge CFNumberRef)@(g_zoom), kDMDomain);
    CFPreferencesAppSynchronize(kDMDomain);
    DMPublish();
    DMPostStatus();
}

// Lightweight connectivity probe so the island can show if the PC is reachable.
static dispatch_source_t g_probeTimer;

static void DMStartProbe(void) {
    dispatch_queue_t q = dispatch_queue_create("com.dravenmortis.probe", DISPATCH_QUEUE_SERIAL);
    g_probeTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(g_probeTimer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                              4 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(g_probeTimer, ^{
        uint32_t ip = g_ip;
        int s = ip ? DMConnect(ip, 2) : -1;
        if (s >= 0) {
            send(s, "P", 1, 0); // tells the PC this is only a status probe
            close(s);
        }
        DMSetConnected(s >= 0);
    });
    dispatch_resume(g_probeTimer);
}

// ============================================================================
// MARK: - SPRINGBOARD SIDE: always-on island UI
// ============================================================================

#define DMColor(r, g, b) [UIColor colorWithRed:(r) / 255.0 green:(g) / 255.0 blue:(b) / 255.0 alpha:1.0]
#define DM_GREEN DMColor(16, 214, 128)
#define DM_AMBER DMColor(255, 176, 32)
#define DM_CYAN  DMColor(56, 189, 248)
#define DM_GRAY  DMColor(120, 128, 145)

static BOOL g_windowWantsKey = NO;

@interface DMIslandWindow : UIWindow
@end

@implementation DMIslandWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self || v == self.rootViewController.view) return nil; // touches pass through
    return v;
}
- (BOOL)canBecomeKeyWindow { return g_windowWantsKey; }
- (BOOL)_shouldCreateContextAsSecure { return YES; }
@end

@interface DMRootViewController : UIViewController
@end

@implementation DMRootViewController
- (void)loadView {
    UIView *v = [UIView new];
    v.backgroundColor = [UIColor clearColor];
    self.view = v;
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }
- (BOOL)shouldAutorotate { return NO; }
@end

@class DMIslandView, DMPanelView;
static DMIslandWindow *g_window = nil;
static DMIslandView *g_island = nil;
static DMPanelView *g_panel = nil;

static void DMTogglePanel(void);
static void DMPromptIP(void);

static void DMHaptic(UIImpactFeedbackStyle style) {
    UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
    [g impactOccurred];
}

// --- Island ------------------------------------------------------------------

@interface DMIslandView : UIView
@end

@implementation DMIslandView {
    UIVisualEffectView *_blur;
    UIView *_dot;
    UILabel *_label;
}

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        CGFloat r = f.size.height / 2.0;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.5;
        self.layer.shadowRadius = 12;
        self.layer.shadowOffset = CGSizeMake(0, 4);

        _blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
        _blur.frame = self.bounds;
        _blur.layer.cornerRadius = r;
        _blur.layer.borderWidth = 1.2;
        _blur.clipsToBounds = YES;
        _blur.userInteractionEnabled = NO;
        UIView *tint = [[UIView alloc] initWithFrame:_blur.bounds];
        tint.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
        [_blur.contentView addSubview:tint];
        [self addSubview:_blur];

        _dot = [[UIView alloc] initWithFrame:CGRectMake(14, r - 5, 10, 10)];
        _dot.layer.cornerRadius = 5;
        _dot.layer.shadowOffset = CGSizeZero;
        _dot.layer.shadowRadius = 5;
        _dot.layer.shadowOpacity = 1;
        _dot.userInteractionEnabled = NO;
        [self addSubview:_dot];

        CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
        pulse.fromValue = @1.0;
        pulse.toValue = @0.35;
        pulse.duration = 0.9;
        pulse.autoreverses = YES;
        pulse.repeatCount = HUGE_VALF;
        [_dot.layer addAnimation:pulse forKey:@"pulse"];

        _label = [[UILabel alloc] initWithFrame:CGRectMake(32, 0, f.size.width - 42, f.size.height)];
        _label.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightHeavy];
        _label.textColor = [UIColor whiteColor];
        _label.adjustsFontSizeToFitWidth = YES;
        _label.minimumScaleFactor = 0.7;
        _label.userInteractionEnabled = NO;
        [self addSubview:_label];

        [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)]];
        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)]];
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLongPress:)];
        lp.minimumPressDuration = 0.5;
        [self addGestureRecognizer:lp];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh) name:kDMStatusNote object:nil];
        [self refresh];
    }
    return self;
}

- (void)refresh {
    UIColor *c;
    NSString *t;
    if (g_enabled && g_connected)      { c = DM_GREEN; t = @"VCAM · EN VIVO"; }
    else if (g_enabled)                { c = DM_AMBER; t = @"VCAM · SIN PC"; }
    else if (g_connected)              { c = DM_CYAN;  t = @"VCAM · LISTO"; }
    else                               { c = DM_GRAY;  t = @"VCAM · APAGADO"; }
    _dot.backgroundColor = c;
    _dot.layer.shadowColor = c.CGColor;
    _label.text = t;
    _blur.layer.borderColor = [c colorWithAlphaComponent:0.6].CGColor;
}

- (void)onPan:(UIPanGestureRecognizer *)p {
    UIView *sv = self.superview;
    if (!sv) return;
    CGPoint d = [p translationInView:sv];
    [p setTranslation:CGPointZero inView:sv];
    CGFloat hw = self.bounds.size.width / 2.0, hh = self.bounds.size.height / 2.0;
    CGFloat x = MIN(MAX(self.center.x + d.x, hw + 6), sv.bounds.size.width - hw - 6);
    CGFloat y = MIN(MAX(self.center.y + d.y, hh + 20), sv.bounds.size.height - hh - 20);
    self.center = CGPointMake(x, y);
    if (p.state == UIGestureRecognizerStateEnded) {
        CFPreferencesSetAppValue(CFSTR("islandX"), (__bridge CFNumberRef)@(x), kDMDomain);
        CFPreferencesSetAppValue(CFSTR("islandY"), (__bridge CFNumberRef)@(y), kDMDomain);
        CFPreferencesAppSynchronize(kDMDomain);
    }
}

- (void)onTap:(UITapGestureRecognizer *)t {
    DMHaptic(UIImpactFeedbackStyleLight);
    DMTogglePanel();
}

- (void)onLongPress:(UILongPressGestureRecognizer *)lp {
    if (lp.state != UIGestureRecognizerStateBegan) return;
    g_enabled = !g_enabled;
    DMHaptic(UIImpactFeedbackStyleHeavy);
    DMSBSaveAndPublish();
}
@end

// --- Control panel -----------------------------------------------------------

@interface DMPanelView : UIView
@end

@implementation DMPanelView {
    UILabel *_status;
    UIButton *_toggle, *_ipButton, *_flip, *_zoom, *_rotate;
}

static UIButton *DMMakeButton(id target, SEL action, CGFloat height) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.09];
    b.layer.cornerRadius = 13;
    b.layer.borderWidth = 1;
    b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
    b.tintColor = [UIColor whiteColor];
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.7;
    [b addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    [b.heightAnchor constraintEqualToConstant:height].active = YES;
    return b;
}

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.55;
        self.layer.shadowRadius = 30;
        self.layer.shadowOffset = CGSizeMake(0, 12);

        UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
        blur.frame = self.bounds;
        blur.layer.cornerRadius = 28;
        blur.layer.borderWidth = 1;
        blur.layer.borderColor = [DM_CYAN colorWithAlphaComponent:0.35].CGColor;
        blur.clipsToBounds = YES;
        [self addSubview:blur];

        CAGradientLayer *glow = [CAGradientLayer layer];
        glow.frame = blur.bounds;
        glow.colors = @[ (id)[DM_CYAN colorWithAlphaComponent:0.18].CGColor,
                         (id)[UIColor colorWithWhite:0 alpha:0.35].CGColor ];
        glow.startPoint = CGPointMake(0, 0);
        glow.endPoint = CGPointMake(1, 1);
        [blur.contentView.layer addSublayer:glow];

        UILabel *title = [UILabel new];
        title.text = @"DRAVEN MORTIS";
        title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBlack];
        title.textColor = DM_AMBER;
        title.textAlignment = NSTextAlignmentCenter;

        _status = [UILabel new];
        _status.font = [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightSemibold];
        _status.textAlignment = NSTextAlignmentCenter;

        _toggle = DMMakeButton(self, @selector(onToggle), 54);
        _toggle.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightHeavy];
        _ipButton = DMMakeButton(self, @selector(onIP), 46);
        _flip = DMMakeButton(self, @selector(onFlip), 44);
        _zoom = DMMakeButton(self, @selector(onZoom), 44);
        _rotate = DMMakeButton(self, @selector(onRotate), 44);

        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ _flip, _zoom, _rotate ]];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.distribution = UIStackViewDistributionFillEqually;
        row.spacing = 8;

        UILabel *hint = [UILabel new];
        hint.text = @"Tip: mantén presionada la isla para encender/apagar";
        hint.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightMedium];
        hint.textColor = [UIColor colorWithWhite:1 alpha:0.45];
        hint.textAlignment = NSTextAlignmentCenter;
        hint.numberOfLines = 2;

        UIButton *close = DMMakeButton(self, @selector(onClose), 44);
        [close setTitle:@"Cerrar" forState:UIControlStateNormal];

        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ title, _status, _toggle, _ipButton, row, hint, close ]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 11;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [blur.contentView addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:blur.contentView.leadingAnchor constant:18],
            [stack.trailingAnchor constraintEqualToAnchor:blur.contentView.trailingAnchor constant:-18],
            [stack.centerYAnchor constraintEqualToAnchor:blur.contentView.centerYAnchor],
        ]];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh) name:kDMStatusNote object:nil];
        [self refresh];
    }
    return self;
}

- (void)refresh {
    if (g_connected) {
        _status.text = [NSString stringWithFormat:@"● PC CONECTADO  %@", DMIPString()];
        _status.textColor = DM_GREEN;
    } else {
        _status.text = [NSString stringWithFormat:@"○ BUSCANDO PC  %@", DMIPString()];
        _status.textColor = DM_AMBER;
    }

    if (g_enabled) {
        [_toggle setTitle:@"◉  CÁMARA VIRTUAL: ON" forState:UIControlStateNormal];
        _toggle.backgroundColor = [DM_GREEN colorWithAlphaComponent:0.85];
        _toggle.layer.borderColor = DM_GREEN.CGColor;
    } else {
        [_toggle setTitle:@"○  CÁMARA VIRTUAL: OFF" forState:UIControlStateNormal];
        _toggle.backgroundColor = [UIColor colorWithWhite:1 alpha:0.09];
        _toggle.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
    }

    [_ipButton setTitle:[NSString stringWithFormat:@"IP del PC:  %@   ✎", DMIPString()] forState:UIControlStateNormal];
    [_flip setTitle:g_flip ? @"Espejo ✓" : @"Espejo" forState:UIControlStateNormal];
    _flip.layer.borderColor = g_flip ? DM_CYAN.CGColor : [UIColor colorWithWhite:1 alpha:0.12].CGColor;
    [_zoom setTitle:[NSString stringWithFormat:@"Zoom %.1fx", g_zoom] forState:UIControlStateNormal];
    [_rotate setTitle:[NSString stringWithFormat:@"Rotar %d°", g_rotation * 90] forState:UIControlStateNormal];
}

- (void)onToggle {
    g_enabled = !g_enabled;
    DMHaptic(UIImpactFeedbackStyleMedium);
    DMSBSaveAndPublish();
}
- (void)onIP { DMPromptIP(); }
- (void)onFlip { g_flip = !g_flip; DMSBSaveAndPublish(); }
- (void)onZoom { g_zoom = (g_zoom >= 2.95f) ? 1.0f : g_zoom + 0.5f; DMSBSaveAndPublish(); }
- (void)onRotate { g_rotation = (g_rotation + 1) & 3; DMSBSaveAndPublish(); }
- (void)onClose { DMTogglePanel(); }
@end

static void DMTogglePanel(void) {
    UIView *host = g_window.rootViewController.view;
    if (!host) return;

    if (g_panel) {
        DMPanelView *p = g_panel;
        g_panel = nil;
        [UIView animateWithDuration:0.2 animations:^{
            p.alpha = 0;
            p.transform = CGAffineTransformMakeScale(0.9, 0.9);
        } completion:^(BOOL finished) { [p removeFromSuperview]; }];
        return;
    }

    CGFloat w = MIN(330, host.bounds.size.width - 32);
    g_panel = [[DMPanelView alloc] initWithFrame:CGRectMake(0, 0, w, 400)];
    g_panel.center = CGPointMake(host.bounds.size.width / 2.0, host.bounds.size.height / 2.0);
    g_panel.alpha = 0;
    g_panel.transform = CGAffineTransformMakeScale(0.9, 0.9);
    [host addSubview:g_panel];
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.6
                        options:0 animations:^{
        g_panel.alpha = 1;
        g_panel.transform = CGAffineTransformIdentity;
    } completion:nil];
}

static void DMPromptIP(void) {
    UIViewController *vc = g_window.rootViewController;
    if (!vc || vc.presentedViewController) return;

    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"IP del PC"
                                                               message:@"Escribe la IP que muestra el Studio en tu PC"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = DMIPString();
        tf.placeholder = @"192.168.1.X";
        tf.keyboardType = UIKeyboardTypeDecimalPad;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    __weak UIAlertController *weakA = a;
    [a addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) {
        g_windowWantsKey = NO;
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Guardar" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        g_windowWantsKey = NO;
        NSString *t = [weakA.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        uint32_t ip = 0;
        if (DMParseIP(t, &ip)) {
            g_ip = ip;
            DMSetConnected(NO);
            DMSBSaveAndPublish();
        }
    }]];

    g_windowWantsKey = YES;
    [g_window makeKeyWindow];
    [vc presentViewController:a animated:YES completion:nil];
}

static void DMSBSetupIsland(int attempt) {
    if (g_window) return;

    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    }
    if (!scene && attempt < 20) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            DMSBSetupIsland(attempt + 1);
        });
        return;
    }

    CGRect screen = [UIScreen mainScreen].bounds;
    g_window = scene ? [[DMIslandWindow alloc] initWithWindowScene:scene] : [[DMIslandWindow alloc] initWithFrame:screen];
    g_window.frame = screen;
    g_window.windowLevel = 1500; // above apps, status bar, banners
    g_window.backgroundColor = [UIColor clearColor];
    g_window.rootViewController = [DMRootViewController new];

    CGFloat w = 150, h = 34;
    NSNumber *sx = DMPref(CFSTR("islandX"), [NSNumber class]);
    NSNumber *sy = DMPref(CFSTR("islandY"), [NSNumber class]);
    CGPoint c = CGPointMake(sx ? sx.doubleValue : screen.size.width / 2.0, sy ? sy.doubleValue : 70);
    g_island = [[DMIslandView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    g_island.center = c;
    [g_window.rootViewController.view addSubview:g_island];

    g_window.hidden = NO;
    DMLog(@"Isla activa en SpringBoard");
}

static void DMSpringBoardInit(void) {
    DMSBLoad();
    DMPublish();
    DMStartProbe();

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil
                                                       queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            @try { DMSBSetupIsland(0); } @catch (NSException *e) { DMLog(@"Error isla: %@", e); }
        });
    }];
}

// ============================================================================
// MARK: - Process gate & entry point
// ============================================================================

static BOOL DMIsTargetApp(NSString *bundleID, NSString *bundlePath) {
    if (!bundleID.length || ![bundlePath hasSuffix:@".app"]) return NO; // no extensions/daemons

    static NSArray *blocked;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        blocked = @[ @"com.apple.Preferences", @"org.coolstar.", @"xyz.willy.", @"com.saurik.",
                     @"com.opa334.", @"com.tigisoftware.", @"com.serena." ];
    });
    for (NSString *b in blocked) {
        if ([bundleID hasPrefix:b]) return NO;
    }

    if ([bundleID isEqualToString:@"com.apple.camera"]) return YES;
    return [bundlePath containsString:@"/containers/Bundle/Application/"]; // App Store / sideloaded apps
}

__attribute__((constructor)) static void DMInit(void) {
    @autoreleasepool {
        NSBundle *main = [NSBundle mainBundle];
        NSString *bundleID = main.bundleIdentifier;
        @try {
            if ([bundleID isEqualToString:@"com.apple.springboard"]) {
                DMLog(@"Cargado en SpringBoard");
                DMSpringBoardInit();
            } else if (DMIsTargetApp(bundleID, main.bundlePath)) {
                DMLog(@"Cargado en %@", bundleID);
                DMAppInit();
            }
        } @catch (NSException *e) {
            DMLog(@"Error en init: %@", e);
        }
    }
}
