#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>
#import "engine.h"
#import "maia.h"

#define CH_ACCENT [UIColor colorWithRed:0.35 green:0.75 blue:0.40 alpha:1.0]

#define PREF_ELO     @"DuoChess_ELO"
#define PREF_ENABLED @"DuoChess_Enabled"
#define PREF_WINPCT  @"DuoChess_WinPct"
#define PREF_ARROWS  @"DuoChess_ArrowCount"
#define PREF_ALPHA   @"DuoChess_ArrowAlpha"
#define PREF_THICK   @"DuoChess_ArrowThick"
#define PREF_EVALCLR @"DuoChess_ArrowEvalColor"
#define PREF_EVALLBL @"DuoChess_EvalLabels"
#define PREF_USEMAIA @"DuoChess_UseMaia"
#define DEFAULT_ELO  1200

static NSInteger gElo            = DEFAULT_ELO;
static BOOL      gEnabled        = YES;
static BOOL      gShowWinPct     = NO;
static NSInteger gArrowCount     = 1;
static CGFloat   gArrowAlpha     = 0.75;
static CGFloat   gArrowThick     = 1.0;
static BOOL      gArrowEvalColor = YES;
static BOOL      gShowEvalLabels = YES;
static BOOL      gUseMaia        = NO;

static NSString *gCurrentFen     = nil;
static NSString *gLastEvalFen    = nil;
static BOOL      gFetching       = NO;
static __weak UIView *gBoardView = nil;
static BOOL      gBoardFlipped   = NO;
static NSMutableArray *gArrowLayers = nil;
static NSArray        *gCurrentArrows = nil;

static UIWindow *gBtnWin   = nil;
static UIButton *gFloatBtn = nil;
static UIWindow *gMenuWin  = nil;
static UILabel  *gEloLabel = nil;
static BOOL      gSkipNextTap = NO;

// --- LOGGING ---
static NSMutableArray *gLog = nil;
static NSString *gLogPath = nil;

static void dbg(NSString *msg) {
    if (!gLog) gLog = [NSMutableArray array];
    NSString *line = [NSString stringWithFormat:@"[%@] %@",
        [NSDateFormatter localizedStringFromDate:[NSDate date]
            dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle], msg];
    [gLog addObject:line];
    while (gLog.count > 150) [gLog removeObjectAtIndex:0];

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLogPath = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject]
                    stringByAppendingPathComponent:@"duo_chessassist.log"];
        [@"" writeToFile:gLogPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
    });
    if (gLogPath) {
        FILE *fp = fopen(gLogPath.fileSystemRepresentation, "a");
        if (fp) { fputs([line UTF8String], fp); fputc('\n', fp); fclose(fp); }
    }
}

static void savePrefs(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setInteger:gElo forKey:PREF_ELO];
    [d setBool:gEnabled forKey:PREF_ENABLED];
    [d setBool:gShowWinPct forKey:PREF_WINPCT];
    [d setInteger:gArrowCount forKey:PREF_ARROWS];
    [d setDouble:gArrowAlpha forKey:PREF_ALPHA];
    [d setDouble:gArrowThick forKey:PREF_THICK];
    [d setBool:gArrowEvalColor forKey:PREF_EVALCLR];
    [d setBool:gShowEvalLabels forKey:PREF_EVALLBL];
    [d setBool:gUseMaia forKey:PREF_USEMAIA];
    [d synchronize];
}

static void loadPrefs(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:PREF_ELO]) gElo = [d integerForKey:PREF_ELO];
    if ([d objectForKey:PREF_ENABLED]) gEnabled = [d boolForKey:PREF_ENABLED];
    if ([d objectForKey:PREF_WINPCT]) gShowWinPct = [d boolForKey:PREF_WINPCT];
    if ([d objectForKey:PREF_ARROWS]) gArrowCount = [d integerForKey:PREF_ARROWS];
    if ([d objectForKey:PREF_ALPHA])  gArrowAlpha = [d doubleForKey:PREF_ALPHA];
    if ([d objectForKey:PREF_THICK])  gArrowThick = [d doubleForKey:PREF_THICK];
    if ([d objectForKey:PREF_EVALCLR]) gArrowEvalColor = [d boolForKey:PREF_EVALCLR];
    if ([d objectForKey:PREF_EVALLBL]) gShowEvalLabels = [d boolForKey:PREF_EVALLBL];
    if ([d objectForKey:PREF_USEMAIA]) gUseMaia = [d boolForKey:PREF_USEMAIA];
    if (gArrowCount < 1) gArrowCount = 1; if (gArrowCount > 3) gArrowCount = 3;
}

// --- HELPER MATH & PARSING ---
static NSInteger eloToDepth(NSInteger elo) {
    if (elo >= 3000) return 18;
    if (elo >= 2400) return 16;
    if (elo >= 2000) return 14;
    if (elo >= 1600) return 11;
    if (elo >= 1200) return 9;
    return 6;
}

static BOOL parseMoveUCI(NSString *uci, int *fromSq, int *toSq) {
    if (uci.length < 4) return NO;
    const char *s = [uci UTF8String];
    int f1 = s[0] - 'a', r1 = s[1] - '1';
    int f2 = s[2] - 'a', r2 = s[3] - '1';
    if (f1 < 0 || f1 > 7 || r1 < 0 || r1 > 7 || f2 < 0 || f2 > 7 || r2 < 0 || r2 > 7) return NO;
    *fromSq = r1 * 8 + f1;
    *toSq   = r2 * 8 + f2;
    return YES;
}

static CGPoint squareToPoint(int sq, CGRect bounds, BOOL flipped) {
    CGFloat s = bounds.size.width / 8.0;
    int file = sq % 8;
    int rank = sq / 8;
    CGFloat x = flipped ? (7 - file + 0.5) * s : (file + 0.5) * s;
    CGFloat y = flipped ? (rank + 0.5) * s     : (7 - rank + 0.5) * s;
    return CGPointMake(x, y);
}

static UIBezierPath *arrowPath(CGPoint from, CGPoint to, CGFloat headLen, CGFloat headW, CGFloat shaftW) {
    CGFloat dx = to.x - from.x, dy = to.y - from.y;
    CGFloat len = sqrtf(dx * dx + dy * dy);
    if (len < 1) return nil;
    CGFloat ux = dx / len, uy = dy / len;
    CGFloat px = -uy,      py = ux;

    CGPoint shaftL1 = CGPointMake(from.x + px * shaftW / 2, from.y + py * shaftW / 2);
    CGPoint shaftR1 = CGPointMake(from.x - px * shaftW / 2, from.y - py * shaftW / 2);
    CGPoint neckL   = CGPointMake(to.x - ux * headLen + px * shaftW / 2, to.y - uy * headLen + py * shaftW / 2);
    CGPoint neckR   = CGPointMake(to.x - ux * headLen - px * shaftW / 2, to.y - uy * headLen - py * shaftW / 2);
    CGPoint wingL   = CGPointMake(to.x - ux * headLen + px * headW / 2,  to.y - uy * headLen + py * headW / 2);
    CGPoint wingR   = CGPointMake(to.x - ux * headLen - px * headW / 2,  to.y - uy * headLen - py * headW / 2);

    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:shaftL1];
    [path addLineToPoint:neckL];
    [path addLineToPoint:wingL];
    [path addLineToPoint:to];
    [path addLineToPoint:wingR];
    [path addLineToPoint:neckR];
    [path addLineToPoint:shaftR1];
    [path closePath];
    return path;
}

static void clearArrows(void) {
    if (gArrowLayers) {
        for (CALayer *l in gArrowLayers) [l removeFromSuperlayer];
        [gArrowLayers removeAllObjects];
    }
    gCurrentArrows = nil;
}

static void drawArrows(NSArray *arrows, UIView *board, BOOL flipped) {
    if (!board || !board.window) return;
    clearArrows();
    gCurrentArrows = [arrows copy];
    if (!gArrowLayers) gArrowLayers = [NSMutableArray array];

    CGRect bounds = board.bounds;
    CGFloat sqSize = bounds.size.width / 8.0;

    for (NSDictionary *a in arrows) {
        NSString *move = a[@"move"];
        int rank = [a[@"rank"] intValue];

        int fromSq = 0, toSq = 0;
        if (!parseMoveUCI(move, &fromSq, &toSq)) continue;

        CGPoint fromPt = squareToPoint(fromSq, bounds, flipped);
        CGPoint toPt   = squareToPoint(toSq,   bounds, flipped);

        CGFloat t = gArrowThick;
        UIBezierPath *path = arrowPath(fromPt, toPt, sqSize * 0.45, sqSize * 0.65 * t, sqSize * 0.25 * t);
        if (!path) continue;

        UIColor *fillColor = (rank == 0) ?
            [UIColor colorWithRed:0.25 green:0.80 blue:0.35 alpha:gArrowAlpha] :
            [UIColor colorWithRed:0.95 green:0.75 blue:0.20 alpha:gArrowAlpha * 0.7];

        CAShapeLayer *layer = [CAShapeLayer layer];
        layer.path = path.CGPath;
        layer.fillColor = fillColor.CGColor;
        layer.strokeColor = [UIColor colorWithWhite:0.1 alpha:0.8].CGColor;
        layer.lineWidth = 1.2;
        layer.zPosition = 9999 - rank;
        [board.layer addSublayer:layer];
        [gArrowLayers addObject:layer];

        NSString *label = a[@"label"];
        if (gShowEvalLabels && label.length) {
            CATextLayer *tl = [CATextLayer layer];
            tl.string = label;
            tl.fontSize = MAX(9.0, sqSize * 0.32);
            tl.alignmentMode = kCAAlignmentCenter;
            tl.foregroundColor = [UIColor whiteColor].CGColor;
            tl.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.7].CGColor;
            tl.cornerRadius = 3;
            tl.masksToBounds = YES;
            tl.contentsScale = [UIScreen mainScreen].scale;
            CGFloat lw = sqSize * 0.75, lh = sqSize * 0.38;
            tl.frame = CGRectMake(toPt.x - lw / 2, toPt.y - lh / 2, lw, lh);
            tl.zPosition = 10001;
            [board.layer addSublayer:tl];
            [gArrowLayers addObject:tl];
        }
    }
}

// --- ENGINE INTEGRATION ---
static void processFen(NSString *fen) {
    if (!gEnabled || !fen.length) return;
    if ([fen isEqualToString:gLastEvalFen] && gCurrentArrows.count) return;

    gCurrentFen = [fen copy];
    gLastEvalFen = [fen copy];
    gFetching = YES;

    dbg([NSString stringWithFormat:@"Engine analyzing FEN: %@", fen]);

    if (gUseMaia && MaiaAvailable()) {
        MaiaGo([fen UTF8String], (int)gElo, (int)gElo, ^(MaiaResult res) {
            dispatch_async(dispatch_get_main_queue(), ^{
                gFetching = NO;
                if (!res.ok) return;
                NSString *mv = [NSString stringWithUTF8String:res.move];
                NSDictionary *arrow = @{
                    @"move": mv,
                    @"eval": @(res.whiteEval),
                    @"label": [NSString stringWithFormat:@"%.0f%%", res.winPct],
                    @"rank": @0
                };
                if (gBoardView) drawArrows(@[arrow], gBoardView, gBoardFlipped);
            });
        });
        return;
    }

    int depth = (int)eloToDepth(gElo);
    int multipv = (int)gArrowCount;

    EngineGo([fen UTF8String], depth, (int)gElo, multipv, ^(const EngineLine *lines, int count) {
        dispatch_async(dispatch_get_main_queue(), ^{
            gFetching = NO;
            if (count <= 0) return;
            NSMutableArray *arrows = [NSMutableArray array];
            for (int i = 0; i < count; i++) {
                NSString *mv = [NSString stringWithUTF8String:lines[i].move];
                double scorePawns = lines[i].score / 100.0;
                NSString *lbl = lines[i].isMate ?
                    [NSString stringWithFormat:@"M%d", lines[i].score] :
                    [NSString stringWithFormat:@"%+.1f", scorePawns];
                [arrows addObject:@{
                    @"move": mv,
                    @"eval": @(scorePawns),
                    @"label": lbl,
                    @"rank": @(i)
                }];
            }
            if (gBoardView) drawArrows(arrows, gBoardView, gBoardFlipped);
        });
    });
}

// --- FLOATING BUTTON & UI ---
@interface DuoChessBtnHandler : NSObject
+ (void)floatBtnTapped;
+ (void)handlePan:(UIPanGestureRecognizer *)pan;
+ (void)handleLongPress:(UILongPressGestureRecognizer *)lp;
@end

@interface DuoPanelHandler : NSObject
+ (void)eloChanged:(UISlider *)slider;
+ (void)copyFenTapped:(UIButton *)btn;
+ (void)closeTapped:(UIButton *)btn;
@end

static void showSettingsMenu(void);

@implementation DuoChessBtnHandler
+ (void)floatBtnTapped {
    if (gSkipNextTap) { gSkipNextTap = NO; return; }
    showSettingsMenu();
}
+ (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *btn = pan.view;
    UIView *container = btn.superview;
    CGPoint tr = [pan translationInView:container];
    btn.center = CGPointMake(btn.center.x + tr.x, btn.center.y + tr.y);
    [pan setTranslation:CGPointZero inView:container];
}
+ (void)handleLongPress:(UILongPressGestureRecognizer *)lp {
    if (lp.state != UIGestureRecognizerStateBegan) return;
    gSkipNextTap = YES;
    gEnabled = !gEnabled;
    savePrefs();
    if (!gEnabled) clearArrows();
    dbg([NSString stringWithFormat:@"Toggled Assistant: %@", gEnabled ? @"ON" : @"OFF"]);
}
@end

@implementation DuoPanelHandler
+ (void)eloChanged:(UISlider *)slider {
    gElo = (NSInteger)slider.value;
    if (gEloLabel) {
        gEloLabel.text = [NSString stringWithFormat:@"Engine ELO: %ld", (long)gElo];
    }
    savePrefs();
}
+ (void)copyFenTapped:(UIButton *)btn {
    if (gCurrentFen.length) {
        [UIPasteboard generalPasteboard].string = gCurrentFen;
        [btn setTitle:@"Copied!" forState:UIControlStateNormal];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [btn setTitle:@"Copy Current FEN" forState:UIControlStateNormal];
        });
    }
}
+ (void)closeTapped:(UIButton *)btn {
    if (gMenuWin) gMenuWin.hidden = YES;
}
@end

static void setupFloatingButton(void) {
    if (gBtnWin) return;
    gBtnWin = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    gBtnWin.windowLevel = UIWindowLevelAlert + 2;
    gBtnWin.backgroundColor = [UIColor clearColor];
    gBtnWin.rootViewController = [[UIViewController alloc] init];
    gBtnWin.rootViewController.view.backgroundColor = [UIColor clearColor];

    CGFloat btnSize = 44;
    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;

    gFloatBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    gFloatBtn.frame = CGRectMake(screenW - btnSize - 12, screenH * 0.40, btnSize, btnSize);
    gFloatBtn.backgroundColor = [UIColor colorWithRed:0.18 green:0.22 blue:0.25 alpha:0.92];
    gFloatBtn.layer.cornerRadius = 10;
    gFloatBtn.layer.borderColor = [UIColor colorWithRed:0.35 green:0.75 blue:0.40 alpha:0.8].CGColor;
    gFloatBtn.layer.borderWidth = 1.5;
    [gFloatBtn setTitle:@"♟" forState:UIControlStateNormal];
    gFloatBtn.titleLabel.font = [UIFont systemFontOfSize:22];

    [gFloatBtn addTarget:[DuoChessBtnHandler class] action:@selector(floatBtnTapped) forControlEvents:UIControlEventTouchUpInside];
    [gFloatBtn addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:[DuoChessBtnHandler class] action:@selector(handlePan:)]];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:[DuoChessBtnHandler class] action:@selector(handleLongPress:)];
    lp.minimumPressDuration = 0.4;
    [gFloatBtn addGestureRecognizer:lp];

    [gBtnWin.rootViewController.view addSubview:gFloatBtn];
    gBtnWin.hidden = NO;
    [gBtnWin makeKeyAndVisible];
}

%hook UIWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self == gBtnWin) {
        CGPoint btnPoint = [gFloatBtn convertPoint:point fromView:self.rootViewController.view];
        if ([gFloatBtn pointInside:btnPoint withEvent:event]) return gFloatBtn;
        return nil;
    }
    return %orig;
}
%end

// --- SETTINGS PANEL ---
static void showSettingsMenu(void) {
    if (!gMenuWin) {
        gMenuWin = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        gMenuWin.windowLevel = UIWindowLevelAlert + 3;
        gMenuWin.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.45];
        gMenuWin.rootViewController = [[UIViewController alloc] init];
    }

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(24, 80, [UIScreen mainScreen].bounds.size.width - 48, 380)];
    panel.backgroundColor = [UIColor colorWithRed:0.12 green:0.15 blue:0.18 alpha:0.96];
    panel.layer.cornerRadius = 16;
    panel.layer.borderColor = [UIColor colorWithWhite:0.25 alpha:1].CGColor;
    panel.layer.borderWidth = 1;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 16, 200, 24)];
    title.text = @"Duolingo Chess Assist";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:17];
    [panel addSubview:title];

    gEloLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 56, 200, 20)];
    gEloLabel.text = [NSString stringWithFormat:@"Engine ELO: %ld", (long)gElo];
    gEloLabel.textColor = [UIColor lightTextColor];
    gEloLabel.font = [UIFont systemFontOfSize:14];
    [panel addSubview:gEloLabel];

    UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(16, 80, panel.bounds.size.width - 32, 30)];
    slider.minimumValue = 400; slider.maximumValue = 3000; slider.value = gElo;
    [slider addTarget:[DuoPanelHandler class] action:@selector(eloChanged:) forControlEvents:UIControlEventValueChanged];
    [panel addSubview:slider];

    UIButton *fenBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    fenBtn.frame = CGRectMake(16, 130, panel.bounds.size.width - 32, 40);
    fenBtn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    fenBtn.layer.cornerRadius = 8;
    [fenBtn setTitle:@"Copy Current FEN" forState:UIControlStateNormal];
    [fenBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [fenBtn addTarget:[DuoPanelHandler class] action:@selector(copyFenTapped:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:fenBtn];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(16, 310, panel.bounds.size.width - 32, 44);
    closeBtn.backgroundColor = CH_ACCENT;
    closeBtn.layer.cornerRadius = 10;
    [closeBtn setTitle:@"Done" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [closeBtn addTarget:[DuoPanelHandler class] action:@selector(closeTapped:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:closeBtn];

    [gMenuWin.rootViewController.view.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    [gMenuWin.rootViewController.view addSubview:panel];
    gMenuWin.hidden = NO;
    [gMenuWin makeKeyAndVisible];
}

// --- DUOLINGO HOOKS ---

typedef void (*OrigLayout)(id, SEL);
static OrigLayout gOrigBoardLayout = NULL;

static void hook_BoardLayout(UIView *self, SEL _cmd) {
    if (gOrigBoardLayout) gOrigBoardLayout(self, _cmd);
    gBoardView = self;
    if (gCurrentArrows.count) {
        drawArrows(gCurrentArrows, self, gBoardFlipped);
    }
}

typedef id (*OrigFenInit)(id, SEL, NSString *);
static OrigFenInit gOrigFenInit = NULL;

static id hook_FenInit(id self, SEL _cmd, NSString *fenNotation) {
    id res = gOrigFenInit ? gOrigFenInit(self, _cmd, fenNotation) : self;
    if (fenNotation && [fenNotation isKindOfClass:[NSString class]] && fenNotation.length > 10) {
        dbg([NSString stringWithFormat:@"Captured FEN from init: %@", fenNotation]);
        dispatch_async(dispatch_get_main_queue(), ^{
            processFen(fenNotation);
        });
    }
    return res;
}

static void installDuolingoHooks(void) {
    static BOOL hooksInstalled = NO;
    if (hooksInstalled) return;

    // 1. Hook DuolingoMultiplatformChessFen
    Class fenCls = objc_getClass("DuolingoMultiplatformChessFen");
    if (fenCls) {
        SEL initSel = NSSelectorFromString(@"initWithFenNotation:");
        Method m = class_getInstanceMethod(fenCls, initSel);
        if (m) {
            MSHookMessageEx(fenCls, initSel, (IMP)hook_FenInit, (IMP *)&gOrigFenInit);
            dbg(@"HOOKED DuolingoMultiplatformChessFen initWithFenNotation:");
        }
    }

    // 2. Hook ChessBoardView layoutSubviews
    NSArray *boardNames = @[@"ChessBoardView", @"_TtC5Chess14ChessBoardView", @"Chess.ChessBoardView", @"StaticChessBoardView"];
    SEL layoutSel = @selector(layoutSubviews);
    for (NSString *name in boardNames) {
        Class bCls = objc_getClass(name.UTF8String);
        if (bCls) {
            MSHookMessageEx(bCls, layoutSel, (IMP)hook_BoardLayout, (IMP *)&gOrigBoardLayout);
            dbg([NSString stringWithFormat:@"HOOKED layoutSubviews on %@", name]);
            hooksInstalled = YES;
            break;
        }
    }
}

// --- INITIALIZER ---
%ctor {
    loadPrefs();
    dbg(@"Duolingo Chess Assistant loaded!");
    EngineStart();

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            setupFloatingButton();
            installDuolingoHooks();
        });
    }];
}
