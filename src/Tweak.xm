// ============================================================
// VoiceSaver —— 微信语音保存 (theos / rootless / iOS16)
// 功能:
//   1) 收到别人语音(type=34) -> 后台转 MP3 -> 静默存进微信容器 Documents/VoiceSaverMP3/
//   2) 长按任意消息 -> 系统菜单追加「保存」-> 点了把该条语音转 MP3 并弹「存到文件」分享面板
// 链路: -[CMessageMgr AddMsg:MsgWrap:] -> getVoicePath(.aud/SILK)
//       -> +[MJSilkCodec decodeToPCMFromSilkData:] -> shine 编码 MP3
// ============================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include "layer3.h"

#define WXLOG(...) NSLog(@"[WXSaver] " __VA_ARGS__)

// ---------- 微信私有类前向声明 ----------
@interface CMessageWrap : NSObject
- (unsigned int)m_uiMessageType;
- (NSString *)m_nsFromUsr;
- (NSString *)m_nsToUsr;
- (NSString *)m_nsContent;
- (NSString *)getVoicePath;
@end

@interface CMessageMgr : NSObject
- (void)AddMsg:(id)arg1 MsgWrap:(id)wrap;
@end

@interface CContact : NSObject
- (NSString *)m_nsUsrName;
@end

@interface CContactMgr : NSObject
- (CContact *)getSelfContact;
@end

@interface MMServiceCenter : NSObject
+ (id)defaultCenter;
- (id)getService:(Class)cls;
@end

// ---------- 全局状态 ----------
static dispatch_queue_t g_workQueue = nil;
static NSString *g_savedDir = nil;                 // 容器内保存目录
static __strong id g_lastWrap = nil;              // 最近一条收到的语音(菜单兜底)
static __strong id g_longPressedWrap = nil;       // 当前长按的语音(优先)

static id WXGetService(Class cls) {
    if (!cls) return nil;
    Class sc = objc_getClass("MMServiceCenter");
    if (!sc) return nil;
    @try {
        id center = [sc performSelector:@selector(defaultCenter)];
        if (!center) return nil;
        return [center performSelector:@selector(getService:) withObject:cls];
    } @catch (id e) { return nil; }
}

static NSString *WXSane(NSString *s) {
    if (!s || s.length == 0) return @"unknown";
    NSMutableString *out = [NSMutableString string];
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:
        @"/\\:*?\"<>| \t\n"] invertedSet];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if ([bad characterIsMember:c]) [out appendFormat:@"%C", c];
    }
    if (out.length == 0) return @"unknown";
    if (out.length > 48) return [out substringToIndex:48];
    return out;
}

// ---------- WAV 头解析: RIFF -> 纯 PCM s16le ----------
static BOOL WXParseWAV(NSData *wav, NSData **pcmOut, int *rateOut, int *chOut) {
    const uint8_t *b = (const uint8_t *)wav.bytes;
    NSUInteger len = wav.length;
    if (len < 44 || memcmp(b, "RIFF", 4) != 0 || memcmp(b + 8, "WAVE", 4) != 0) return NO;
    NSUInteger off = 12;
    uint16_t audioFmt = 1, channels = 1, bits = 16;
    uint32_t rate = 16000;
    BOOL foundFmt = NO, foundData = NO;
    NSUInteger dataOff = 0, dataSize = 0;
    while (off + 8 <= len) {
        char id[5] = {0};
        memcpy(id, b + off, 4);
        uint32_t sz = 0;
        memcpy(&sz, b + off + 4, 4);
        if (memcmp(id, "fmt ", 4) == 0 && off + 8 + 16 <= len) {
            memcpy(&audioFmt, b + off + 8, 2);
            memcpy(&channels, b + off + 10, 2);
            memcpy(&rate, b + off + 12, 4);
            memcpy(&bits, b + off + 22, 2);
            foundFmt = YES;
        } else if (memcmp(id, "data", 4) == 0) {
            dataOff = off + 8;
            dataSize = sz;
            if (dataOff + dataSize > len) dataSize = len - dataOff;
            foundData = YES;
            break;
        }
        off += 8 + sz + (sz & 1);
    }
    if (!foundFmt || !foundData || audioFmt != 1 || bits != 16 || dataSize == 0) return NO;
    *pcmOut = [wav subdataWithRange:NSMakeRange(dataOff, dataSize)];
    *rateOut = (int)rate;
    *chOut = (int)channels;
    return YES;
}

// ---------- SILK -> PCM (微信自带解码器, 多头部变体兜底) ----------
static NSData *WXSilkToPCM(NSData *silk, int *rateOut, int *chOut) {
    *rateOut = 16000; *chOut = 1;
    Class codec = objc_getClass("MJSilkCodec");
    if (!codec) { WXLOG(@"MJSilkCodec missing"); return nil; }
    SEL sel = @selector(decodeToPCMFromSilkData:);
    if (![(id)codec respondsToSelector:sel]) { WXLOG(@"decode sel missing"); return nil; }
    NSMutableArray<NSData *> *tries = [NSMutableArray array];
    [tries addObject:silk];
    if (silk.length > 1) [tries addObject:[silk subdataWithRange:NSMakeRange(1, silk.length - 1)]];
    {
        NSMutableData *p2 = [NSMutableData data];
        uint8_t b = 0x02;
        [p2 appendBytes:&b length:1];
        [p2 appendData:silk];
        [tries addObject:p2];
    }
    for (NSUInteger i = 0; i < tries.count; i++) {
        @try {
            IMP imp = [(id)codec methodForSelector:sel];
            NSData *(*fn)(id, SEL, NSData *) = (NSData *(*)(id, SEL, NSData *))imp;
            NSData *out = fn((id)codec, sel, tries[i]);
            if (out.length > 0) {
                WXLOG(@"decode ok variant %lu: %lu bytes", (unsigned long)i, (unsigned long)out.length);
                NSData *pcm = nil; int r = 0, c = 0;
                if (WXParseWAV(out, &pcm, &r, &c)) {
                    *rateOut = r; *chOut = c;
                    return pcm;
                }
                return out; // 裸 PCM s16le
            }
        } @catch (id e) { WXLOG(@"decode variant %lu err: %@", (unsigned long)i, e); }
    }
    WXLOG(@"decode all variants failed");
    return nil;
}

// ---------- PCM -> MP3 (shine 定点编码器) ----------
static NSData *WXPCMToMP3(NSData *pcm, int rate, int channels) {
    if (pcm.length < 2) return nil;
    shine_config_t config;
    shine_set_config_mpeg_defaults(&config.mpeg);
    config.wave.channels = (channels == 2) ? PCM_STEREO : PCM_MONO;
    config.wave.samplerate = rate;
    config.mpeg.mode = (channels == 2) ? JOINT_STEREO : MONO;
    config.mpeg.bitr = 64;

    shine_t s = shine_initialise(&config);
    if (!s) { WXLOG(@"shine_initialise failed"); return nil; }

    int samplesPerPass = shine_samples_per_pass(s);
    int blockBytes = samplesPerPass * channels * 2;

    NSMutableData *mp3 = [NSMutableData data];
    const uint8_t *src = (const uint8_t *)pcm.bytes;
    NSUInteger total = pcm.length;
    NSUInteger off = 0;
    uint8_t *block = (uint8_t *)malloc(blockBytes);
    if (!block) { shine_close(s); return nil; }

    while (off < total) {
        NSUInteger avail = total - off;
        NSUInteger take = MIN((NSUInteger)blockBytes, avail);
        memcpy(block, src + off, take);
        if (take < (NSUInteger)blockBytes) memset(block + take, 0, blockBytes - take);
        off += blockBytes;
        int written = 0;
        unsigned char *out = shine_encode_buffer_interleaved(s, (int16_t *)block, &written);
        if (out && written > 0) [mp3 appendBytes:out length:written];
    }
    int written = 0;
    unsigned char *tail = shine_flush(s, &written);
    if (tail && written > 0) [mp3 appendBytes:tail length:written];
    free(block);
    shine_close(s);
    WXLOG(@"mp3 encoded: %lu bytes", (unsigned long)mp3.length);
    return mp3;
}

// ---------- 找顶层 VC ----------
static UIViewController *WXTopVC(void) {
    UIWindow *kw = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) { kw = w; break; }
    }
    if (!kw) kw = [UIApplication sharedApplication].windows.lastObject;
    if (!kw) return nil;
    UIViewController *top = kw.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    return top;
}

// ---------- 拿语音文件路径(等落盘) ----------
static NSString *WXWaitVoicePath(id wrap) {
    NSString *path = nil;
    @try { if ([wrap respondsToSelector:@selector(getVoicePath)]) path = [wrap getVoicePath]; } @catch (id e) {}
    if (!path.length) {
        @try { NSString *c = [wrap m_nsContent]; if (c.length) path = c; } @catch (id e) {}
    }
    if (!path.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (int i = 0; i < 30; i++) {
        if ([fm fileExistsAtPath:path] && [fm attributesOfItemAtPath:path error:nil].fileSize > 4)
            return path;
        [NSThread sleepForTimeInterval:1.0];
    }
    return nil;
}

// ---------- 转一条语音, 返回 MP3 路径(已存容器) ----------
static NSString *WXConvertWrap(id wrap, NSString **chatOut) {
    NSString *path = WXWaitVoicePath(wrap);
    if (!path) { WXLOG(@"voice file not ready"); return nil; }
    WXLOG(@"voice file ready: %@ (%llu bytes)", path,
          (unsigned long long)[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil].fileSize);
    NSData *silk = [NSData dataWithContentsOfFile:path];
    if (!silk || silk.length < 4) { WXLOG(@"read silk fail"); return nil; }
    int rate = 16000, ch = 1;
    NSData *pcm = WXSilkToPCM(silk, &rate, &ch);
    if (!pcm || pcm.length < 2) { WXLOG(@"silk decode fail"); return nil; }
    NSData *mp3 = WXPCMToMP3(pcm, rate, ch);
    if (!mp3 || mp3.length < 64) { WXLOG(@"mp3 encode fail"); return nil; }

    NSString *from = nil, *to = nil;
    @try { from = [wrap m_nsFromUsr]; to = [wrap m_nsToUsr]; } @catch (id e) {}
    NSString *selfID = nil;
    @try { CContact *sc = [WXGetService(objc_getClass("CContactMgr")) getSelfContact]; selfID = [sc m_nsUsrName]; } @catch (id e) {}
    NSString *chat = ([from isEqualToString:selfID] && to.length) ? to : from;
    if (!chat.length) chat = @"unknown";
    if (chatOut) *chatOut = chat;

    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"MMdd_HHmmss";
        fmt.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    });
    NSString *name = [NSString stringWithFormat:@"voice_%@_%@.mp3", WXSane(chat), [fmt stringFromDate:[NSDate date]]];
    if (!g_savedDir) return nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:g_savedDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *outPath = [g_savedDir stringByAppendingPathComponent:name];
    if (![mp3 writeToFile:outPath atomically:YES]) { WXLOG(@"write container fail"); return nil; }
    WXLOG(@"saved: %@", outPath);
    // 尽量多写一份到 /var/mobile/Documents (Filza 直接取; 沙盒不允许则忽略)
    NSString *sysDir = @"/var/mobile/Documents/VoiceSaverMP3";
    [[NSFileManager defaultManager] createDirectoryAtPath:sysDir withIntermediateDirectories:YES attributes:nil error:nil];
    [mp3 writeToFile:[sysDir stringByAppendingPathComponent:name] atomically:YES];
    return outPath;
}

// ---------- 分享面板(存到文件) ----------
static void WXShareFile(NSString *path) {
    if (!path.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            UIViewController *top = WXTopVC();
            if (!top) { WXLOG(@"no VC for share"); return; }
            NSURL *url = [NSURL fileURLWithPath:path];
            UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
            @try { [top presentViewController:av animated:YES completion:nil]; }
            @catch (id e) { WXLOG(@"share present err: %@", e); }
        }
    });
}

// ---------- 收到语音: 静默转存(不打扰) ----------
static void WXProcessReceivedVoice(id wrap) {
    dispatch_async(g_workQueue, ^{
        @autoreleasepool {
            @try {
                NSString *chat = nil;
                NSString *p = WXConvertWrap(wrap, &chat);
                if (p) WXLOG(@"auto-saved voice from %@", chat);
                else WXLOG(@"auto-save skipped");
            } @catch (id e) { WXLOG(@"process err: %@", e); }
        }
    });
}

// ============================================================
// hooks
// ============================================================

%hook CMessageMgr
- (void)AddMsg:(id)arg1 MsgWrap:(id)wrap {
    %orig;
    @try {
        if (!wrap) return;
        unsigned int type = [wrap m_uiMessageType];
        if (type != 34) return;                 // 34 = 语音
        // 只处理别人发来的(过滤自己发的)
        NSString *from = nil, *selfID = nil;
        @try { from = [wrap m_nsFromUsr]; } @catch (id e) {}
        @try { CContact *sc = [WXGetService(objc_getClass("CContactMgr")) getSelfContact]; selfID = [sc m_nsUsrName]; } @catch (id e) {}
        if (from.length && selfID.length && [from isEqualToString:selfID]) return;
        g_lastWrap = wrap;                      // 菜单兜底用
        WXProcessReceivedVoice(wrap);
    } @catch (id e) { WXLOG(@"AddMsg hook err: %@", e); }
}
%end

// 长按菜单: 给 UIMenuController 追加「保存」
%hook UIMenuController
- (void)setMenuItems:(NSArray *)items {
    NSMutableArray *arr = items ? [items mutableCopy] : [NSMutableArray new];
    BOOL has = NO;
    for (id it in arr) {
        if ([[it title] isEqualToString:@"保存"]) { has = YES; break; }
    }
    if (!has) {
        UIMenuItem *item = [[UIMenuItem alloc] initWithTitle:@"保存" action:@selector(voiceSaver_save:)];
        [arr addObject:item];
    }
    %orig(arr);
}
%end

// 让 BaseMsgContentViewController 能响应我们的 action, 并捕获长按的语音
%hook BaseMsgContentViewController
- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    if (action == @selector(voiceSaver_save:)) return YES;
    return %orig;
}

- (void)onLongPressMsg:(UILongPressGestureRecognizer *)gesture {
    %orig;
    @try {
        UIView *v = gesture.view;
        id w = nil;
        if (v) w = [v valueForKey:@"msgWrap"];
        if (!w) w = [v.superview valueForKey:@"msgWrap"];
        if (w) g_longPressedWrap = w;
    } @catch (id e) { WXLOG(@"capture longpress err: %@", e); }
}

%new
- (void)voiceSaver_save:(id)sender {
    id wrap = g_longPressedWrap ?: g_lastWrap;
    if (!wrap) { WXLOG(@"no wrap to save"); return; }
    g_longPressedWrap = nil;
    dispatch_async(g_workQueue, ^{
        @autoreleasepool {
            @try {
                NSString *chat = nil;
                NSString *p = WXConvertWrap(wrap, &chat);
                if (p) WXShareFile(p);
                else WXLOG(@"menu save failed");
            } @catch (id e) { WXLOG(@"menu save err: %@", e); }
        }
    });
}
%end

%ctor {
    g_workQueue = dispatch_queue_create("com.yzdmm.voicesaver.work", DISPATCH_QUEUE_SERIAL);
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    g_savedDir = [docs stringByAppendingPathComponent:@"VoiceSaverMP3"];
    WXLOG(@"loaded, save dir: %@", g_savedDir);
}
