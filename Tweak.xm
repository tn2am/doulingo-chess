#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>
#import "engine.h"
#import "maia.h"

#define CH_ACCENT [UIColor colorWithRed:0.35 green:0.75 blue:0.40 alpha:1.0]
#define CH_WARN   [UIColor colorWithRed:0.95 green:0.30 blue:0.30 alpha:1.0]

#define PREF_ELO         @"DuoChess_ELO"
#define PREF_ENABLED     @"DuoChess_Enabled"
#define PREF_WINPCT      @"DuoChess_WinPct"
#define PREF_ARROWS      @"DuoChess_ArrowCount"
#define PREF_ALPHA       @"DuoChess_ArrowAlpha"
#define PREF_THICK       @"DuoChess_ArrowThick"
#define PREF_EVALCLR     @"DuoChess_ArrowEvalColor"
#define PREF_EVALLBL     @"DuoChess_EvalLabels"
#define PREF_USEMAIA     @"DuoChess_UseMaia"
#define PREF_AUTOPLAY    @"DuoChess_AutoPlay"
#define PREF_APDELAY     @"DuoChess_AutoPlayDelay"
#define PREF_APJITEN     @"DuoChess_AutoPlayJitterEnabled"
#define PREF_APJITRNG    @"DuoChess_AutoPlayJitterRange"
#define PREF_AP2ND       @"DuoChess_AutoPlaySecondBest"
#define PREF_AP2NDPCT    @"DuoChess_AutoPlaySecondBestPct"
#define PREF_THREATS     @"DuoChess_ShowThreats"
#define PREF_FLIPMODE    @"DuoChess_FlipMode"

#define DEFAULT_ELO      2600

// --- GLOBAL PREFERENCES ---
static NSInteger gElo                  = DEFAULT_ELO;
static BOOL      gEnabled              = YES;
static BOOL      gShowWinPct           = NO;
static NSInteger gArrowCount           = 1;
static CGFloat   gArrowAlpha           = 0.80;
static CGFloat   gArrowThick           = 1.0;
static BOOL      gArrowEvalColor       = YES;
static BOOL      gShowEvalLabels       = YES;
static BOOL      gUseMaia              = NO;
static BOOL      gAutoPlay             = NO;
static double    gAutoPlayDelay        = 0.6;
static BOOL      gAutoPlayJitterEnabled = YES;
static double    gAutoPlayJitterRange  = 0.3;
static BOOL      gAutoPlaySecondBest   = YES;
static NSInteger gAutoPlaySecondBestPct = 10;
static BOOL      gShowThreats          = NO;  // Mac dinh tat canh bao doi thu de khong lam roi mat
static NSInteger gFlipMode             = 0;   // 0 = Auto, 1 = Force White bottom, 2 = Force Black bottom

// --- STATE VARIABLES ---
static NSString *gCurrentFen     = nil;
static NSString *gLastEvalFen    = nil;
static NSString *gEvaluatingFen  = nil;
static NSString *gLastAutoPlayed = nil;
static __weak UIView *gBoardView = nil;

// Board orientation & Player color (0 = White, 1 = Black)
static NSInteger gMyColor        = 0;
static NSInteger gTurnColor      = 0;
static BOOL      gBoardFlipped   = NO;
static BOOL      gMyColorLocked  = NO;
static __weak id gLastSetupModel = nil;


static NSMutableArray *gArrowLayers = nil;
static NSArray        *gCurrentArrows = nil;

// Best move and evaluation for UI display
static NSString *gBestMoveStr    = nil;
static NSString *gBestEvalStr    = nil;
static BOOL      gLastWasThreat  = NO;

// Captured game state references
static __weak id gLatestGameState = nil;

static UIWindow *gBtnWin      = nil;
static UIButton *gFloatBtn    = nil;
static UIWindow *gMenuWin     = nil;
static BOOL      gSkipNextTap = NO;

// 64-square board representation parsed from FEN
static char gBoard[64];

// --- LOGGING ---
static NSMutableArray *gLog = nil;
static NSString *gLogPath = nil;

static void dbg(NSString *msg) {
    if (!gLog) gLog = [NSMutableArray array];
    NSString *line = [NSString stringWithFormat:@"[%@] %@",
        [NSDateFormatter localizedStringFromDate:[NSDate date]
            dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle], msg];
    [gLog addObject:line];
    while (gLog.count > 200) [gLog removeObjectAtIndex:0];

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
    [d setBool:gAutoPlay forKey:PREF_AUTOPLAY];
    [d setDouble:gAutoPlayDelay forKey:PREF_APDELAY];
    [d setBool:gAutoPlayJitterEnabled forKey:PREF_APJITEN];
    [d setDouble:gAutoPlayJitterRange forKey:PREF_APJITRNG];
    [d setBool:gAutoPlaySecondBest forKey:PREF_AP2ND];
    [d setInteger:gAutoPlaySecondBestPct forKey:PREF_AP2NDPCT];
    [d setBool:gShowThreats forKey:PREF_THREATS];
    [d setInteger:gFlipMode forKey:PREF_FLIPMODE];
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
    if ([d objectForKey:PREF_AUTOPLAY]) gAutoPlay = [d boolForKey:PREF_AUTOPLAY];
    if ([d objectForKey:PREF_APDELAY]) gAutoPlayDelay = [d doubleForKey:PREF_APDELAY];
    if ([d objectForKey:PREF_APJITEN]) gAutoPlayJitterEnabled = [d boolForKey:PREF_APJITEN];
    if ([d objectForKey:PREF_APJITRNG]) gAutoPlayJitterRange = [d doubleForKey:PREF_APJITRNG];
    if ([d objectForKey:PREF_AP2ND]) gAutoPlaySecondBest = [d boolForKey:PREF_AP2ND];
    if ([d objectForKey:PREF_AP2NDPCT]) gAutoPlaySecondBestPct = [d integerForKey:PREF_AP2NDPCT];
    if ([d objectForKey:PREF_THREATS]) gShowThreats = [d boolForKey:PREF_THREATS];
    if ([d objectForKey:PREF_FLIPMODE]) gFlipMode = [d integerForKey:PREF_FLIPMODE];

    if (gArrowCount < 1) gArrowCount = 1; if (gArrowCount > 3) gArrowCount = 3;
}

static NSString *eloTierName(NSInteger elo) {
    if (elo <= 600)  return @"Mới bắt đầu";
    if (elo <= 1000) return @"Tập sự";
    if (elo <= 1400) return @"Phong trào";
    if (elo <= 1800) return @"Trung cấp";
    if (elo <= 2200) return @"Cao cấp";
    if (elo <= 2600) return @"Kiện tướng (Master)";
    return @"Đại kiện tướng (GM 3000 ELO)";
}

// Depth mapping for high-intelligence Grandmaster analysis
static NSInteger eloToDepth(NSInteger elo) {
    if (elo >= 2600) return 16;
    if (elo >= 2200) return 14;
    if (elo >= 1800) return 12;
    if (elo >= 1400) return 10;
    if (elo >= 1000) return 8;
    return 6;
}

// Forward declarations
static void clearArrows(void);
static void fetchMove(NSString *fen);
static void processFen(NSString *fen);
static void updateBoardFlipped(void);
static UIView *findBoardInView(UIView *root);
static UIView *findActiveBoardView(void);

// Reset clean state for a new game / opponent match
static void resetForNewGame(NSString *reason) {
    dbg([NSString stringWithFormat:@"[VÁN MỚI] %@ -> Đặt lại toàn bộ dữ liệu bàn cờ.", reason]);
    EngineStop();
    gCurrentFen = nil;
    gLastEvalFen = nil;
    gEvaluatingFen = nil;
    gLastAutoPlayed = nil;
    gBestMoveStr = nil;
    gBestEvalStr = nil;
    gLastWasThreat = NO;
    gLatestGameState = nil;
    gMyColorLocked = NO;
    clearArrows();
}


// --- FEN PARSER ---
static void parseFEN(NSString *fen) {
    memset(gBoard, ' ', sizeof(gBoard));
    if (!fen.length) return;
    NSArray *parts = [fen componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!parts.count) return;
    NSString *placement = parts[0];
    int rank = 7, file = 0;
    for (NSUInteger i = 0; i < placement.length; i++) {
        unichar c = [placement characterAtIndex:i];
        if (c == '/') {
            rank--; file = 0;
        } else if (c >= '1' && c <= '8') {
            file += (c - '0');
        } else if (rank >= 0 && rank < 8 && file >= 0 && file < 8) {
            gBoard[rank * 8 + file] = (char)c;
            file++;
        }
    }

    if (parts.count > 1) {
        NSString *stm = parts[1];
        gTurnColor = [stm isEqualToString:@"b"] ? 1 : 0;
    } else {
        gTurnColor = 0;
    }
}

static BOOL parseMoveUCI(NSString *uci, int *fromSq, int *toSq) {
    if (!uci || uci.length < 4) return NO;
    const char *s = [uci UTF8String];
    int f1 = s[0] - 'a', r1 = s[1] - '1';
    int f2 = s[2] - 'a', r2 = s[3] - '1';
    if (f1 < 0 || f1 > 7 || r1 < 0 || r1 > 7 || f2 < 0 || f2 > 7 || r2 < 0 || r2 > 7) return NO;
    *fromSq = r1 * 8 + f1;
    *toSq   = r2 * 8 + f2;
    return YES;
}

// Compute square coordinate on screen with exact aspect-ratio centering
static CGPoint squareToPoint(int sq, CGRect bounds, BOOL flipped) {
    CGFloat minDim = MIN(bounds.size.width, bounds.size.height);
    CGFloat offsetX = (bounds.size.width - minDim) / 2.0;
    CGFloat offsetY = (bounds.size.height - minDim) / 2.0;
    CGFloat s = minDim / 8.0;

    int file = sq % 8;
    int rank = sq / 8;
    CGFloat x = offsetX + (flipped ? (7 - file + 0.5) : (file + 0.5)) * s;
    CGFloat y = offsetY + (flipped ? (rank + 0.5) : (7 - rank + 0.5)) * s;
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
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ clearArrows(); });
        return;
    }
    if (gArrowLayers) {
        for (CALayer *l in gArrowLayers) [l removeFromSuperlayer];
        [gArrowLayers removeAllObjects];
    }
    gCurrentArrows = nil;
}

static void drawArrows(NSArray *arrows, UIView *board, BOOL flipped, BOOL isThreat) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ drawArrows(arrows, board, flipped, isThreat); });
        return;
    }
    if (!board || !board.window) return;
    clearArrows();
    gCurrentArrows = [arrows copy];
    if (!gArrowLayers) gArrowLayers = [NSMutableArray array];

    CGRect bounds = board.bounds;
    CGFloat minDim = MIN(bounds.size.width, bounds.size.height);
    CGFloat sqSize = minDim / 8.0;

    for (NSDictionary *a in arrows) {
        NSString *move = a[@"move"];
        int rank = [a[@"rank"] intValue];

        int fromSq = 0, toSq = 0;
        if (!parseMoveUCI(move, &fromSq, &toSq)) continue;

        CGPoint fromPt = squareToPoint(fromSq, bounds, flipped);
        CGPoint toPt   = squareToPoint(toSq,   bounds, flipped);

        CGFloat t = gArrowThick;
        UIBezierPath *path = arrowPath(fromPt, toPt, sqSize * 0.42, sqSize * 0.55 * t, sqSize * 0.20 * t);
        if (!path) continue;

        UIColor *fillColor;
        if (isThreat) {
            fillColor = [CH_WARN colorWithAlphaComponent:gArrowAlpha];
        } else if (rank == 0) {
            // Nước đi tối ưu: Xanh dạ quang Neon Chess
            fillColor = [UIColor colorWithRed:0.0 green:0.90 blue:0.46 alpha:gArrowAlpha];
        } else if (rank == 1) {
            // Nước đi thứ 2: Cyan thanh lịch
            fillColor = [UIColor colorWithRed:0.0 green:0.69 blue:1.0 alpha:gArrowAlpha * 0.9];
        } else {
            // Nước đi thứ 3: Vàng cam ấm
            fillColor = [UIColor colorWithRed:1.0 green:0.72 blue:0.0 alpha:gArrowAlpha * 0.8];
        }

        // 1. Origin Dot: Chấm tròn đánh dấu quân cờ xuất phát
        CGFloat dotR = sqSize * 0.16;
        UIBezierPath *dotPath = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(fromPt.x - dotR, fromPt.y - dotR, dotR * 2, dotR * 2)];
        CAShapeLayer *dotLayer = [CAShapeLayer layer];
        dotLayer.path = dotPath.CGPath;
        dotLayer.fillColor = fillColor.CGColor;
        dotLayer.strokeColor = [UIColor whiteColor].CGColor;
        dotLayer.lineWidth = 1.2;
        dotLayer.zPosition = 9998 - rank;
        [board.layer addSublayer:dotLayer];
        [gArrowLayers addObject:dotLayer];

        // 2. Main Arrow Layer với hiệu ứng đổ bóng 3D
        CAShapeLayer *layer = [CAShapeLayer layer];
        layer.path = path.CGPath;
        layer.fillColor = fillColor.CGColor;
        layer.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.85].CGColor;
        layer.lineWidth = 1.0;
        layer.shadowColor = [UIColor blackColor].CGColor;
        layer.shadowOpacity = 0.55;
        layer.shadowRadius = 4.0;
        layer.shadowOffset = CGSizeMake(0, 1.5);
        layer.zPosition = 9999 - rank;
        [board.layer addSublayer:layer];
        [gArrowLayers addObject:layer];

        // 3. Score / Win% Label
        NSString *label = a[@"label"];
        if (gShowEvalLabels && label.length) {
            CATextLayer *tl = [CATextLayer layer];
            tl.string = label;
            tl.fontSize = MAX(10.0, sqSize * 0.30);
            tl.alignmentMode = kCAAlignmentCenter;
            tl.foregroundColor = [UIColor whiteColor].CGColor;
            tl.backgroundColor = [[UIColor colorWithRed:0.1 green:0.1 blue:0.14 alpha:0.85] CGColor];
            tl.cornerRadius = 5.0;
            tl.masksToBounds = YES;
            tl.borderColor = [fillColor CGColor];
            tl.borderWidth = 1.0;
            tl.contentsScale = [UIScreen mainScreen].scale;
            CGFloat lw = sqSize * 0.85, lh = sqSize * 0.38;
            tl.frame = CGRectMake(toPt.x - lw / 2, toPt.y - lh / 2, lw, lh);
            tl.zPosition = 10001;
            [board.layer addSublayer:tl];
            [gArrowLayers addObject:tl];
        }
    }
}

// --- TOAST NOTIFICATION ---
static void showToast(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        static UIWindow *toastWin = nil;
        if (!toastWin) {
            toastWin = [[UIWindow alloc] initWithFrame:CGRectMake(0, 50, [UIScreen mainScreen].bounds.size.width, 60)];
            toastWin.windowLevel = UIWindowLevelStatusBar + 150.0;
            toastWin.backgroundColor = [UIColor clearColor];
            toastWin.userInteractionEnabled = NO;
        }

        [toastWin.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];

        UIView *toast = [[UIView alloc] initWithFrame:CGRectMake(24, 6, toastWin.bounds.size.width - 48, 48)];
        toast.backgroundColor = [UIColor colorWithRed:0.12 green:0.15 blue:0.18 alpha:0.96];
        toast.layer.cornerRadius = 24;
        toast.layer.borderColor = [CH_ACCENT CGColor];
        toast.layer.borderWidth = 1.4;

        UILabel *lbl = [[UILabel alloc] initWithFrame:toast.bounds];
        lbl.text = text;
        lbl.textColor = [UIColor whiteColor];
        lbl.font = [UIFont boldSystemFontOfSize:14];
        lbl.textAlignment = NSTextAlignmentCenter;
        [toast addSubview:lbl];
        [toastWin addSubview:toast];
        toastWin.hidden = NO;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            toastWin.hidden = YES;
        });
    });
}

// --- AUTOPLAY TOUCH SIMULATION ---
static NSMutableArray *gFakeTouches = nil;
static UITouch *chAcquireFakeTouch(void) {
    if (!gFakeTouches) gFakeTouches = [NSMutableArray array];
    UITouch *t = gFakeTouches.firstObject;
    if (!t) {
        t = [[UITouch alloc] init];
        [gFakeTouches addObject:t];
    }
    return t;
}

static void chSetKvc(id obj, NSString *key, id val) {
    @try {
        [obj setValue:val forKey:key];
    } @catch (NSException *e) {}
}

static void chFakeTouchFire(CGPoint ptInWin, UIWindow *win, UITouchPhase phase) {
    if (!win) return;
    @try {
        UITouch *touch = chAcquireFakeTouch();
        chSetKvc(touch, @"_phase", @(phase));
        chSetKvc(touch, @"_locationInWindow", [NSValue valueWithCGPoint:ptInWin]);
        chSetKvc(touch, @"_tapCount", @1);
        chSetKvc(touch, @"_timestamp", @(NSDate.date.timeIntervalSince1970));
        chSetKvc(touch, @"_window", win);

        UIView *target = [win hitTest:ptInWin withEvent:nil] ?: win;
        chSetKvc(touch, @"_view", target);

        static UIEvent *sCarrierEvent = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ sCarrierEvent = [[UIEvent alloc] init]; });

        NSSet *touches = [NSSet setWithObject:touch];
        switch (phase) {
            case UITouchPhaseBegan:
                [target touchesBegan:touches withEvent:sCarrierEvent];
                break;
            case UITouchPhaseMoved:
                [target touchesMoved:touches withEvent:sCarrierEvent];
                break;
            case UITouchPhaseCancelled:
                [target touchesCancelled:touches withEvent:sCarrierEvent];
                break;
            default:
                [target touchesEnded:touches withEvent:sCarrierEvent];
                break;
        }

        // Chuyển tiếp sự kiện chạm tới toàn bộ Gesture Recognizers trong phân cấp View
        UIView *v = target;
        while (v && v != win) {
            for (UIGestureRecognizer *gr in v.gestureRecognizers) {
                @try {
                    if (phase == UITouchPhaseBegan) [gr touchesBegan:touches withEvent:sCarrierEvent];
                    else if (phase == UITouchPhaseMoved) [gr touchesMoved:touches withEvent:sCarrierEvent];
                    else if (phase == UITouchPhaseCancelled) [gr touchesCancelled:touches withEvent:sCarrierEvent];
                    else [gr touchesEnded:touches withEvent:sCarrierEvent];
                } @catch (NSException *e) {}
            }
            v = v.superview;
        }
    } @catch (NSException *e) {
        dbg([NSString stringWithFormat:@"Lỗi giả lập chạm: %@", e.reason]);
    }
}

static void performAutoPlay(NSString *moveUCI, UIView *board) {
    if (!gAutoPlay || !gEnabled || !board || !board.window) return;
    int fromSq = 0, toSq = 0;
    if (!parseMoveUCI(moveUCI, &fromSq, &toSq)) return;

    CGRect winRect = [board convertRect:board.bounds toView:nil];
    UIWindow *win = board.window;

    CGPoint fromLocal = squareToPoint(fromSq, board.bounds, gBoardFlipped);
    CGPoint toLocal   = squareToPoint(toSq,   board.bounds, gBoardFlipped);
    CGPoint fromWin = CGPointMake(winRect.origin.x + fromLocal.x, winRect.origin.y + fromLocal.y);
    CGPoint toWin   = CGPointMake(winRect.origin.x + toLocal.x,   winRect.origin.y + toLocal.y);

    BOOL promo = moveUCI.length > 4;
    CGPoint promoWin = CGPointZero;
    if (promo) {
        int qSq = (gMyColor == 1) ? toSq + 8 : toSq - 8;
        if (qSq < 0 || qSq > 63) qSq = toSq;
        CGPoint qLocal = squareToPoint(qSq, board.bounds, gBoardFlipped);
        promoWin = CGPointMake(winRect.origin.x + qLocal.x, winRect.origin.y + qLocal.y);
    }

    double delay = gAutoPlayDelay;
    if (gAutoPlayJitterEnabled && gAutoPlayJitterRange > 0.0) {
        double jit = ((double)arc4random_uniform(2001) / 1000.0 - 1.0) * gAutoPlayJitterRange;
        delay = MAX(0.1, delay + jit);
    }

    dbg([NSString stringWithFormat:@"[TỰ ĐỘNG ĐI] %@ (từ ô %d sang ô %d, trễ: %.2fs)", moveUCI, fromSq, toSq, delay]);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!gAutoPlay || !gEnabled || !board.window) return;

        // Bước 1: Chạm chọn quân cờ (Tap-to-select)
        chFakeTouchFire(fromWin, win, UITouchPhaseBegan);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            chFakeTouchFire(fromWin, win, UITouchPhaseEnded);

            // Bước 2: Chờ Duolingo hiển thị các ô hợp lệ (0.09s), sau đó chạm ô đích (Tap-to-move)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.09 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                chFakeTouchFire(toWin, win, UITouchPhaseBegan);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    chFakeTouchFire(toWin, win, UITouchPhaseEnded);

                    // Bước 3: Nếu là nước phong cấp (Promotion)
                    if (promo) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            chFakeTouchFire(promoWin, win, UITouchPhaseBegan);
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                chFakeTouchFire(promoWin, win, UITouchPhaseEnded);
                            });
                        });
                    }
                });
            });
        });
    });
}

// --- DYNAMIC BOARD FINDER (BOT & PVP SUPPORT) ---
static UIView *findBoardInView(UIView *root) {
    if (!root) return nil;
    NSString *rootName = NSStringFromClass([root class]);
    if ([rootName containsString:@"ChessBoardView"] || [rootName containsString:@"StaticChessBoardView"]) {
        return root;
    }
    for (UIView *sub in root.subviews) {
        if (!sub.hidden && sub.alpha > 0.1) {
            NSString *cn = NSStringFromClass([sub class]);
            if ([cn containsString:@"ChessBoardView"] || [cn containsString:@"StaticChessBoardView"] ||
                [cn containsString:@"ChessBoardRiveWrapper"] || [cn containsString:@"ChessOscarBoardView"] ||
                [cn containsString:@"ChessUnityView"]) {
                return sub;
            }
            if (sub.bounds.size.width >= 180 && sub.bounds.size.height >= 180 &&
                fabs(sub.bounds.size.width - sub.bounds.size.height) < 40.0) {
                return sub;
            }
            UIView *deep = findBoardInView(sub);
            if (deep && deep != root) return deep;
        }
    }
    return root;
}

static void scanViewHierarchy(UIView *v, int *bestScore, UIView **bestBoard) {
    if (!v || v.hidden || v.alpha < 0.1) return;
    CGRect b = v.bounds;
    CGFloat w = b.size.width;
    CGFloat h = b.size.height;
    NSString *clsName = NSStringFromClass([v class]);

    int score = -1;
    if ([clsName containsString:@"ChessBoardView"] || [clsName containsString:@"StaticChessBoardView"] || [clsName containsString:@"ChessBoardRiveWrapper"]) {
        score = 100;
    } else if ([clsName containsString:@"ChessOscarBoardView"] || [clsName containsString:@"ChessUnityView"]) {
        score = 90;
    } else if ([clsName containsString:@"ChessPvPMatchContentView"] || [clsName containsString:@"ChessPvPMatchContainerView"] || [clsName containsString:@"ChessMatchContainerView"]) {
        score = 50;
    } else if (w >= 180 && h >= 180 && fabs(w - h) < 40.0 && [clsName containsString:@"Chess"]) {
        score = 70;
    }

    if (score > *bestScore && w >= 150 && h >= 150) {
        *bestScore = score;
        *bestBoard = v;
    }

    for (UIView *sub in v.subviews) {
        scanViewHierarchy(sub, bestScore, bestBoard);
    }
}

static UIView *findActiveBoardView(void) {
    UIWindow *keyWin = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                for (UIWindow *w in ws.windows) {
                    if (w != gBtnWin && w != gMenuWin && !w.hidden && w.alpha > 0.5) {
                        keyWin = w;
                        break;
                    }
                }
            }
            if (keyWin) break;
        }
    }
    if (!keyWin) keyWin = [UIApplication sharedApplication].keyWindow;
    if (!keyWin) return nil;

    UIView *bestBoard = nil;
    int bestScore = -1;
    scanViewHierarchy(keyWin, &bestScore, &bestBoard);

    if (bestBoard) {
        UIView *inner = findBoardInView(bestBoard);
        if (inner) return inner;
    }
    return bestBoard;
}

// Forward declaration
static void fetchMove(NSString *fen);

// --- FAST ENGINE DISPATCHER ---
static void processFen(NSString *fen) {
    if (!fen || ![fen isKindOfClass:[NSString class]] || fen.length < 10) return;

    NSString *cleanFen = [fen stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSArray *parts = [cleanFen componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (parts.count < 2) {
        cleanFen = [NSString stringWithFormat:@"%@ w KQkq - 0 1", cleanFen];
    } else if (parts.count < 4) {
        cleanFen = [NSString stringWithFormat:@"%@ - - 0 1", cleanFen];
    }

    // Tự động nhận diện ván cờ mới nếu FEN quay lại vị trí xuất phát chuẩn
    if ([cleanFen hasPrefix:@"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR"]) {
        if (gCurrentFen && ![gCurrentFen hasPrefix:@"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR"]) {
            resetForNewGame(@"Phát hiện bàn cờ xuất phát chuẩn ván mới");
        }
    }

    // Nếu FEN không đổi và đã đánh giá xong thì không cần xử lý lại
    if ([cleanFen isEqualToString:gCurrentFen] && [cleanFen isEqualToString:gLastEvalFen] && gCurrentArrows.count > 0) {
        return;
    }

    gCurrentFen = [cleanFen copy];
    parseFEN(cleanFen);

    dispatch_async(dispatch_get_main_queue(), ^{
        fetchMove(cleanFen);
    });
}

static void fetchMove(NSString *fen) {
    if (!gEnabled || !fen.length) return;

    if (!gBoardView || !gBoardView.window) {
        gBoardView = findActiveBoardView();
        if (gBoardView) updateBoardFlipped();
    }

    parseFEN(fen);

    BOOL isOurTurn = (gMyColor == gTurnColor);

    // 1. NẾU LÀ LƯỢT ĐỐI THỦ:
    if (!isOurTurn) {
        EngineStop();          // DỪNG NGAY MỌI TÍNH TOÁN CŨ ĐỂ TIẾT KIỆM TÀI NGUYÊN
        clearArrows();         // XÓA SẠCH MŨI TÊN (KHÔNG HIỆN NƯỚC ĐỐI THỦ!)
        gBestMoveStr = nil;
        gBestEvalStr = @"⏳ Đang chờ đối thủ đi...";
        gEvaluatingFen = nil;
        dbg([NSString stringWithFormat:@"[LƯỢT ĐỐI THỦ] Đã xóa mũi tên và dừng engine (Bạn: %@, Lượt FEN: %@)",
             gMyColor == 0 ? @"Trắng" : @"Đen", gTurnColor == 0 ? @"Trắng" : @"Đen"]);
        return;
    }

    // 2. NẾU LÀ LƯỢT CỦA BẠN:
    // Nếu FEN này đang được tính toán dở, không kích hoạt lại trùng lặp
    if ([fen isEqualToString:gEvaluatingFen]) {
        return;
    }

    // Nếu FEN này đã được đánh giá xong và đang có mũi tên hiển thị rồi thì giữ nguyên
    if ([fen isEqualToString:gLastEvalFen] && gCurrentArrows.count > 0) {
        return;
    }

    gEvaluatingFen = [fen copy];
    dbg([NSString stringWithFormat:@"[LƯỢT CỦA BẠN] Bắt đầu tính toán cho %@: %@",
         gMyColor == 0 ? @"TRẮNG ⚪" : @"ĐEN ⚫", fen]);

    if (gUseMaia && MaiaAvailable()) {
        MaiaGo([fen UTF8String], (int)gElo, (int)gElo, ^(MaiaResult res) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!res.ok) {
                    gEvaluatingFen = nil;
                    return;
                }
                if (![fen isEqualToString:gCurrentFen]) return;

                gLastEvalFen = [fen copy];
                gEvaluatingFen = nil;

                NSString *mv = [NSString stringWithUTF8String:res.move];
                gBestMoveStr = [mv copy];
                gBestEvalStr = [NSString stringWithFormat:@"%.0f%%", res.winPct];
                gLastWasThreat = NO;

                NSDictionary *arrow = @{
                    @"move": mv,
                    @"eval": @(res.whiteEval),
                    @"label": gBestEvalStr,
                    @"rank": @0
                };
                if (!gBoardView || !gBoardView.window) {
                    gBoardView = findActiveBoardView();
                    if (gBoardView) updateBoardFlipped();
                }
                if (gBoardView && (gMyColor == gTurnColor)) {
                    drawArrows(@[arrow], gBoardView, gBoardFlipped, NO);
                    if (gAutoPlay && ![gLastAutoPlayed isEqualToString:fen]) {
                        gLastAutoPlayed = [fen copy];
                        performAutoPlay(mv, gBoardView);
                    }
                }
            });
        });
        return;
    }

    int depth = (int)eloToDepth(gElo);
    int multipv = (int)gArrowCount;

    EngineGo([fen UTF8String], depth, (int)gElo, multipv, ^(const EngineLine *lines, int count) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (count <= 0) {
                gEvaluatingFen = nil;
                return;
            }
            if (![fen isEqualToString:gCurrentFen]) return;

            gLastEvalFen = [fen copy];
            gEvaluatingFen = nil;

            gLastWasThreat = NO;
            NSMutableArray *arrows = [NSMutableArray array];
            for (int i = 0; i < count; i++) {
                NSString *mv = [NSString stringWithUTF8String:lines[i].move];
                double scorePawns = lines[i].score / 100.0;
                NSString *lbl = lines[i].isMate ?
                    [NSString stringWithFormat:@"M%d", lines[i].score] :
                    (gShowWinPct ? [NSString stringWithFormat:@"%.0f%%", (50.0 + 50.0 * (2.0 / (1.0 + exp(-0.00368208 * lines[i].score)) - 1.0))] :
                     [NSString stringWithFormat:@"%+.1f", scorePawns]);

                if (i == 0) {
                    gBestMoveStr = [mv copy];
                    gBestEvalStr = [lbl copy];
                }

                [arrows addObject:@{
                    @"move": mv,
                    @"eval": @(scorePawns),
                    @"label": lbl,
                    @"rank": @(i)
                }];
            }

            if (!gBoardView || !gBoardView.window) {
                gBoardView = findActiveBoardView();
                if (gBoardView) updateBoardFlipped();
            }
            if (gBoardView && (gMyColor == gTurnColor)) {
                drawArrows(arrows, gBoardView, gBoardFlipped, NO);

                // AutoPlay logic
                if (gAutoPlay && ![gLastAutoPlayed isEqualToString:fen] && arrows.count) {
                    gLastAutoPlayed = [fen copy];
                    NSString *chosenMove = arrows[0][@"move"];
                    if (gAutoPlaySecondBest && arrows.count >= 2 && arc4random_uniform(100) < gAutoPlaySecondBestPct) {
                        chosenMove = arrows[1][@"move"];
                    }
                    performAutoPlay(chosenMove, gBoardView);
                }
            }
        });
    });
}

static NSInteger detectColorValue(id obj) {
    if (!obj) return -1;
    NSString *desc = [[obj description] lowercaseString];
    if ([desc containsString:@"black"] || [desc containsString:@"đen"]) return 1;
    if ([desc containsString:@"white"] || [desc containsString:@"trắng"]) return 0;

    SEL nameSel = NSSelectorFromString(@"name");
    if ([obj respondsToSelector:nameSel]) {
        id n = ((id (*)(id, SEL))objc_msgSend)(obj, nameSel);
        if (n && [n isKindOfClass:[NSString class]]) {
            NSString *ns = [((NSString *)n) lowercaseString];
            if ([ns containsString:@"black"] || [ns containsString:@"đen"]) return 1;
            if ([ns containsString:@"white"] || [ns containsString:@"trắng"]) return 0;
        }
    }

    // Kotlin Enum: ordinal 0 = WHITE, 1 = BLACK
    SEL ordSel = NSSelectorFromString(@"ordinal");
    if ([obj respondsToSelector:ordSel]) {
        NSInteger ord = ((NSInteger (*)(id, SEL))objc_msgSend)(obj, ordSel);
        if (ord == 0) return 0;
        if (ord == 1) return 1;
    }

    SEL isWhiteSel = NSSelectorFromString(@"isWhite");
    if ([obj respondsToSelector:isWhiteSel]) {
        BOOL isW = ((BOOL (*)(id, SEL))objc_msgSend)(obj, isWhiteSel);
        return isW ? 0 : 1;
    }
    return -1;
}

static BOOL isBoardViewFlipped(UIView *board) {
    if (!board) return NO;
    NSArray *flipSelectors = @[@"isFlipped", @"flipped", @"isReversed", @"reversed", @"isRotated", @"rotated"];
    for (NSString *selName in flipSelectors) {
        SEL sel = NSSelectorFromString(selName);
        if ([board respondsToSelector:sel]) {
            return ((BOOL (*)(id, SEL))objc_msgSend)(board, sel);
        }
    }
    return NO;
}

static void updateBoardFlipped(void) {
    if (gFlipMode == 1) {
        gBoardFlipped = NO; // Ép Trắng ở dưới
    } else if (gFlipMode == 2) {
        gBoardFlipped = YES; // Ép Đen ở dưới
    } else {
        if (gBoardView && isBoardViewFlipped(gBoardView)) {
            gBoardFlipped = YES;
            return;
        }
        gBoardFlipped = (gMyColor == 1);
    }
}

// Nhận diện và KHÓA CỨNG màu quân cho người chơi từ setupModel ban đầu
static void detectColorFromSetupModel(id sm) {
    if (!sm || gMyColorLocked) return;
    SEL umnSel = NSSelectorFromString(@"userMovesNext");
    if (![sm respondsToSelector:umnSel]) return;

    BOOL umn = ((BOOL (*)(id, SEL))objc_msgSend)(sm, umnSel);

    // Lấy FEN ban đầu của chính setupModel, tuyệt đối KHÔNG dùng live FEN!
    NSString *initFen = nil;
    SEL fnSel = NSSelectorFromString(@"fenNotation");
    if ([sm respondsToSelector:fnSel]) {
        initFen = ((NSString *(*)(id, SEL))objc_msgSend)(sm, fnSel);
    }

    BOOL isWhiteFirst = YES;
    if (initFen && initFen.length > 10) {
        NSArray *parts = [initFen componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (parts.count > 1) {
            isWhiteFirst = ![parts[1] isEqualToString:@"b"];
        }
    }

    // Nếu ở thế cờ ban đầu lượt đi là Trắng:
    //   userMovesNext == YES -> Bạn cầm Trắng (0)
    //   userMovesNext == NO  -> Bạn cầm Đen (1)
    // Nếu ở thế cờ ban đầu lượt đi là Đen:
    //   userMovesNext == YES -> Bạn cầm Đen (1)
    //   userMovesNext == NO  -> Bạn cầm Trắng (0)
    NSInteger detected = isWhiteFirst ? (umn ? 0 : 1) : (umn ? 1 : 0);
    gMyColor = detected;
    gMyColorLocked = YES;
    updateBoardFlipped();

    dbg([NSString stringWithFormat:@"[KHÓA MÀU VÁN CỜ] Bạn là: %@ (Setup userMovesNext=%d, isWhiteFirst=%d, initFen=%@)",
         gMyColor == 0 ? @"TRẮNG ⚪" : @"ĐEN ⚫", (int)umn, (int)isWhiteFirst, initFen]);
}

static void detectColorFromGameState(id gs) {
    if (!gs || gMyColorLocked) return;

    NSInteger detected = -1;

    // 1. Ưu tiên cao nhất: Lấy userColor trực tiếp từ GameState (chuẩn xác cho cả Bot và PvP)
    SEL ucSel = NSSelectorFromString(@"userColor");
    if ([gs respondsToSelector:ucSel]) {
        id uc = ((id (*)(id, SEL))objc_msgSend)(gs, ucSel);
        detected = detectColorValue(uc);
        if (detected >= 0) {
            gMyColor = detected;
            gMyColorLocked = YES;
            updateBoardFlipped();
            dbg([NSString stringWithFormat:@"[KHÓA MÀU VÁN CỜ] Nhận diện chuẩn từ GameState.userColor: %@",
                 gMyColor == 0 ? @"TRẮNG ⚪" : @"ĐEN ⚫"]);
            return;
        }
    }

    // 2. Kiểm tra các selector màu khác
    NSArray *colorSelectors = @[@"playerColor", @"myColor", @"humanColor", @"side"];
    for (NSString *sName in colorSelectors) {
        SEL s = NSSelectorFromString(sName);
        if ([gs respondsToSelector:s]) {
            id uc = ((id (*)(id, SEL))objc_msgSend)(gs, s);
            detected = detectColorValue(uc);
            if (detected >= 0) {
                gMyColor = detected;
                gMyColorLocked = YES;
                updateBoardFlipped();
                dbg([NSString stringWithFormat:@"[KHÓA MÀU VÁN CỜ] Nhận diện từ GameState.%@: %@",
                     sName, gMyColor == 0 ? @"TRẮNG ⚪" : @"ĐEN ⚫"]);
                return;
            }
        }
    }

    // 3. Dự phòng cho Bot: lấy từ setupModel
    SEL smSel = NSSelectorFromString(@"setupModel");
    if ([gs respondsToSelector:smSel]) {
        id sm = ((id (*)(id, SEL))objc_msgSend)(gs, smSel);
        if (sm) {
            detectColorFromSetupModel(sm);
        }
    }
}

static NSString *extractFenFromGameState(id gs) {
    if (!gs) return nil;

    // 1. Luôn ưu tiên FEN live trực tiếp từ GameState.fen.fenString
    SEL fenSel = NSSelectorFromString(@"fen");
    if ([gs respondsToSelector:fenSel]) {
        id fenObj = ((id (*)(id, SEL))objc_msgSend)(gs, fenSel);
        if (fenObj) {
            SEL fenStrSel = NSSelectorFromString(@"fenString");
            if ([fenObj respondsToSelector:fenStrSel]) {
                NSString *fs = ((NSString *(*)(id, SEL))objc_msgSend)(fenObj, fenStrSel);
                if (fs && [fs isKindOfClass:[NSString class]] && fs.length > 10) {
                    if (!gMyColorLocked) detectColorFromGameState(gs);
                    return fs;
                }
            }
        }
    }

    // 2. Dự phòng: lấy FEN ban đầu từ setupModel
    SEL setupSel = NSSelectorFromString(@"setupModel");
    if ([gs respondsToSelector:setupSel]) {
        id sm = ((id (*)(id, SEL))objc_msgSend)(gs, setupSel);
        if (sm) {
            detectColorFromSetupModel(sm);
            SEL fnSel = NSSelectorFromString(@"fenNotation");
            if ([sm respondsToSelector:fnSel]) {
                NSString *fn = ((NSString *(*)(id, SEL))objc_msgSend)(sm, fnSel);
                if (fn && [fn isKindOfClass:[NSString class]] && fn.length > 10) {
                    return fn;
                }
            }
        }
    }
    return nil;
}

// --- RUNTIME SWIZZLER ---
static void SwizzleInstanceMethod(Class cls, SEL origSel, IMP newImp, IMP *origImp) {
    if (!cls || !origSel || !newImp) return;
    Method origMethod = class_getInstanceMethod(cls, origSel);
    if (!origMethod) return;

    if (origImp) *origImp = method_getImplementation(origMethod);

    const char *types = method_getTypeEncoding(origMethod);
    if (class_addMethod(cls, origSel, newImp, types)) {
        Method superMethod = class_getInstanceMethod(class_getSuperclass(cls), origSel);
        if (superMethod && origImp) *origImp = method_getImplementation(superMethod);
    } else {
        method_setImplementation(origMethod, newImp);
    }
}

// --- SAFE MULTI-CLASS HOOK DEFINITIONS ---

static CFMutableDictionaryRef gOrigLayoutMap = NULL;
typedef void (*OrigLayout)(id, SEL);

static void hook_BoardLayout(UIView *self, SEL _cmd) {
    Class cls = [self class];
    OrigLayout orig = NULL;
    if (gOrigLayoutMap) {
        orig = (OrigLayout)CFDictionaryGetValue(gOrigLayoutMap, (__bridge const void *)(cls));
    }
    if (orig) {
        orig(self, _cmd);
    }

    UIView *targetBoard = findBoardInView(self);
    if (!targetBoard) targetBoard = self;

    if (targetBoard != gBoardView) {
        gBoardView = targetBoard;
        dbg([NSString stringWithFormat:@"[BÀN CỜ ĐƯỢC CHỌN] %@ (%.0fx%.0f)",
             NSStringFromClass([targetBoard class]), targetBoard.bounds.size.width, targetBoard.bounds.size.height]);
        updateBoardFlipped();
    }

    if (gLatestGameState) {
        NSString *fen = extractFenFromGameState(gLatestGameState);
        if (fen.length > 10 && ![fen isEqualToString:gCurrentFen]) {
            processFen(fen);
        }
    }

    // Chỉ hiển thị mũi tên nếu đang là lượt của người dùng
    if (gCurrentArrows.count && (gMyColor == gTurnColor)) {
        drawArrows(gCurrentArrows, gBoardView, gBoardFlipped, gLastWasThreat);
    } else if (gMyColor != gTurnColor) {
        clearArrows();
    }
}

static CFMutableDictionaryRef gOrigVCAppearMap = NULL;
typedef void (*OrigVCAppear)(UIViewController *, SEL, BOOL);

static void hook_VCViewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    Class cls = [self class];
    OrigVCAppear orig = NULL;
    if (gOrigVCAppearMap) {
        orig = (OrigVCAppear)CFDictionaryGetValue(gOrigVCAppearMap, (__bridge const void *)(cls));
    }
    if (orig) {
        orig(self, _cmd, animated);
    }

    dbg([NSString stringWithFormat:@"[GIAO DIỆN TRẬN ĐẤU] Xuất hiện: %@", NSStringFromClass(cls)]);
    resetForNewGame([NSString stringWithFormat:@"Bắt đầu giao diện %@", NSStringFromClass(cls)]);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *board = findActiveBoardView();
        if (board) {
            gBoardView = board;
            updateBoardFlipped();
            dbg([NSString stringWithFormat:@"[GIAO DIỆN TRẬN ĐẤU] Đã gắn bàn cờ: %@", NSStringFromClass([board class])]);
        }
        if (gLatestGameState) {
            detectColorFromGameState(gLatestGameState);
            NSString *fen = extractFenFromGameState(gLatestGameState);
            if (fen) processFen(fen);
        }
    });
}

static void hookBoardClass(Class cls) {
    if (!cls) return;
    SEL sel = @selector(layoutSubviews);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    IMP origImp = method_getImplementation(m);
    if (!gOrigLayoutMap) {
        gOrigLayoutMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
    }
    if (!CFDictionaryContainsKey(gOrigLayoutMap, (__bridge const void *)(cls))) {
        CFDictionarySetValue(gOrigLayoutMap, (__bridge const void *)(cls), (const void *)origImp);
    }

    class_replaceMethod(cls, sel, (IMP)hook_BoardLayout, method_getTypeEncoding(m));
}

static void hookVCClass(Class cls) {
    if (!cls) return;
    SEL sel = @selector(viewDidAppear:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    IMP origImp = method_getImplementation(m);
    if (!gOrigVCAppearMap) {
        gOrigVCAppearMap = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
    }
    if (!CFDictionaryContainsKey(gOrigVCAppearMap, (__bridge const void *)(cls))) {
        CFDictionarySetValue(gOrigVCAppearMap, (__bridge const void *)(cls), (const void *)origImp);
    }

    class_replaceMethod(cls, sel, (IMP)hook_VCViewDidAppear, method_getTypeEncoding(m));
}

typedef NSString *(*OrigFenString)(id, SEL);
static OrigFenString gOrig_fenString = NULL;

static NSString *hook_FenString(id self, SEL _cmd) {
    NSString *res = gOrig_fenString ? gOrig_fenString(self, _cmd) : nil;
    if (res && [res isKindOfClass:[NSString class]] && res.length > 10) {
        if (!gMyColorLocked && gLatestGameState) {
            detectColorFromGameState(gLatestGameState);
        }
        processFen(res);
    }
    return res;
}

typedef id (*OrigGameStateFen)(id, SEL);
static OrigGameStateFen gOrig_gameStateFen = NULL;

static id hook_GameStateFen(id self, SEL _cmd) {
    if (self != gLatestGameState) {
        gLatestGameState = self;
    }
    if (!gMyColorLocked) {
        detectColorFromGameState(self);
    }

    id fenObj = gOrig_gameStateFen ? gOrig_gameStateFen(self, _cmd) : nil;
    if (fenObj) {
        SEL fsSel = NSSelectorFromString(@"fenString");
        if ([fenObj respondsToSelector:fsSel]) {
            NSString *fs = ((NSString *(*)(id, SEL))objc_msgSend)(fenObj, fsSel);
            if (fs && [fs isKindOfClass:[NSString class]] && fs.length > 10) {
                processFen(fs);
            }
        }
    }
    return fenObj;
}

typedef id (*OrigGameStateSetupModel)(id, SEL);
static OrigGameStateSetupModel gOrig_gameStateSetupModel = NULL;

static id hook_GameStateSetupModel(id self, SEL _cmd) {
    if (self != gLatestGameState) {
        gLatestGameState = self;
    }
    id sm = gOrig_gameStateSetupModel ? gOrig_gameStateSetupModel(self, _cmd) : nil;
    if (sm) {
        if (sm != gLastSetupModel) {
            gLastSetupModel = sm;
            resetForNewGame(@"Phát hiện GameSetupModel ván mới");
        }
        detectColorFromSetupModel(sm);
    }
    return sm;
}

typedef NSString *(*OrigFenNotation)(id, SEL);
static OrigFenNotation gOrig_setupModelFenNotation = NULL;

static NSString *hook_FenNotation(id self, SEL _cmd) {
    NSString *res = gOrig_setupModelFenNotation ? gOrig_setupModelFenNotation(self, _cmd) : nil;
    if (res && [res isKindOfClass:[NSString class]] && res.length > 10) {
        if (self != gLastSetupModel) {
            gLastSetupModel = self;
            resetForNewGame(@"Phát hiện GameSetupModel.fenNotation ván mới");
        }
        detectColorFromSetupModel(self);
        // Nếu vừa bắt đầu ván mới và chưa có live FEN nào thì kích hoạt ván cờ
        if (!gCurrentFen) {
            processFen(res);
        }
    }
    return res;
}

static void installDuolingoHooks(void) {
    static BOOL fenHooked = NO;
    static BOOL gsHooked = NO;
    static BOOL smHooked = NO;
    static BOOL boardHooked = NO;

    if (!fenHooked) {
        Class fenCls = objc_getClass("DuolingoMultiplatformChessFen");
        if (fenCls) {
            SwizzleInstanceMethod(fenCls, NSSelectorFromString(@"fenString"), (IMP)hook_FenString, (IMP *)&gOrig_fenString);
            fenHooked = YES;
        }
    }

    if (!gsHooked) {
        Class gsCls = objc_getClass("DuolingoMultiplatformChessGameState");
        if (gsCls) {
            SwizzleInstanceMethod(gsCls, NSSelectorFromString(@"fen"), (IMP)hook_GameStateFen, (IMP *)&gOrig_gameStateFen);
            SwizzleInstanceMethod(gsCls, NSSelectorFromString(@"setupModel"), (IMP)hook_GameStateSetupModel, (IMP *)&gOrig_gameStateSetupModel);
            gsHooked = YES;
        }
    }

    if (!smHooked) {
        Class smCls = objc_getClass("DuolingoMultiplatformChessGameSetupModel");
        if (smCls) {
            SwizzleInstanceMethod(smCls, NSSelectorFromString(@"fenNotation"), (IMP)hook_FenNotation, (IMP *)&gOrig_setupModelFenNotation);
            smHooked = YES;
        }
    }

    if (!boardHooked) {
        NSArray *boardNames = @[
            @"ChessBoardView",
            @"_TtC5Chess14ChessBoardView",
            @"Chess.ChessBoardView",
            @"StaticChessBoardView",
            @"_TtC14DuolingoMobile20StaticChessBoardView",
            @"_TtC5Chess21ChessBoardRiveWrapper",
            @"_TtC14DuolingoMobile19ChessOscarBoardView",
            @"_TtC14DuolingoMobile14ChessUnityView",
            @"_TtC14DuolingoMobile24ChessPvPMatchContentView",
            @"_TtC14DuolingoMobile26ChessPvPMatchContainerView",
            @"_TtC14DuolingoMobile23ChessMatchContainerView",
            @"_TtC14DuolingoMobile27ChessMiniMatchContainerView",
            @"_TtC14DuolingoMobile18ChessChallengeView"
        ];
        for (NSString *name in boardNames) {
            Class bCls = objc_getClass(name.UTF8String);
            if (bCls) {
                hookBoardClass(bCls);
            }
        }

        NSArray *vcNames = @[
            @"_TtC14DuolingoMobile22ChessPvPMatchContentVC",
            @"_TtC14DuolingoMobile24ChessPvPMatchContainerVC",
            @"_TtC14DuolingoMobile23ChessMatchRiveContentVC",
            @"_TtC14DuolingoMobile24ChessMatchUnityContentVC",
            @"_TtC14DuolingoMobile21ChessMatchContainerVC",
            @"_TtC14DuolingoMobile25ChessMiniMatchContainerVC"
        ];
        for (NSString *name in vcNames) {
            Class vcCls = objc_getClass(name.UTF8String);
            if (vcCls) {
                hookVCClass(vcCls);
            }
        }
        boardHooked = YES;
    }

    // Periodic match check and active board lookup
    static BOOL timerStarted = NO;
    if (!timerStarted) {
        timerStarted = YES;
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
            if (!gBoardView || !gBoardView.window || gBoardView.hidden || gBoardView.alpha < 0.1) {
                UIView *found = findActiveBoardView();
                if (found) {
                    if (found != gBoardView) {
                        gBoardView = found;
                        updateBoardFlipped();
                        dbg([NSString stringWithFormat:@"[TÌM THẤY BÀN CỜ TỰ ĐỘNG] %@", NSStringFromClass([found class])]);
                    }
                    if (gCurrentArrows.count && (gMyColor == gTurnColor)) {
                        drawArrows(gCurrentArrows, gBoardView, gBoardFlipped, gLastWasThreat);
                    }
                } else if (gBoardView) {
                    gBoardView = nil;
                    resetForNewGame(@"Bàn cờ đã rời khỏi màn hình");
                }
            }
        }];
    }
}

// --- SETTINGS PANEL (VIETNAMESE UI) ---
@interface DuoRichSettingsView : UIView
- (void)populate;
@end

@implementation DuoRichSettingsView {
    UIScrollView *_scroll;
    UIStackView  *_stack;
    UILabel      *_eloValueLabel;
    UILabel      *_eloTierLabel;
    UILabel      *_statusLabel;
    UILabel      *_alphaValueLabel;
    UILabel      *_delayValueLabel;
    UILabel      *_secondMoveValueLabel;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor colorWithRed:0.10 green:0.12 blue:0.15 alpha:0.98];
        self.layer.cornerRadius = 24;
        self.layer.borderColor = [UIColor colorWithWhite:0.25 alpha:1.0].CGColor;
        self.layer.borderWidth = 1.0;
        self.clipsToBounds = YES;

        UIView *grab = [[UIView alloc] initWithFrame:CGRectMake(frame.size.width / 2 - 20, 8, 40, 5)];
        grab.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.25];
        grab.layer.cornerRadius = 2.5;
        [self addSubview:grab];

        _scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 20, frame.size.width, frame.size.height - 20)];
        _scroll.alwaysBounceVertical = YES;
        [self addSubview:_scroll];

        _stack = [[UIStackView alloc] init];
        _stack.axis = UILayoutConstraintAxisVertical;
        _stack.spacing = 14;
        _stack.translatesAutoresizingMaskIntoConstraints = NO;
        [_scroll addSubview:_stack];

        [NSLayoutConstraint activateConstraints:@[
            [_stack.topAnchor constraintEqualToAnchor:_scroll.topAnchor constant:10],
            [_stack.bottomAnchor constraintEqualToAnchor:_scroll.bottomAnchor constant:-20],
            [_stack.leadingAnchor constraintEqualToAnchor:_scroll.leadingAnchor constant:16],
            [_stack.trailingAnchor constraintEqualToAnchor:_scroll.trailingAnchor constant:-16],
            [_stack.widthAnchor constraintEqualToConstant:frame.size.width - 32]
        ]];

        [self populate];
    }
    return self;
}

- (UILabel *)lbl:(NSString *)text size:(CGFloat)sz weight:(UIFontWeight)w color:(UIColor *)c {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = [UIFont systemFontOfSize:sz weight:w];
    l.textColor = c;
    l.numberOfLines = 0;
    return l;
}

- (UIView *)sep {
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    [v.heightAnchor constraintEqualToConstant:1].active = YES;
    return v;
}

- (UILabel *)sectionLabel:(NSString *)title {
    return [self lbl:[title uppercaseString] size:12 weight:UIFontWeightBold color:[UIColor colorWithWhite:0.55 alpha:1.0]];
}

- (UIView *)group:(UIView *)content {
    UIView *c = [[UIView alloc] init];
    c.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.05];
    c.layer.cornerRadius = 14;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [c addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:c.topAnchor constant:12],
        [content.bottomAnchor constraintEqualToAnchor:c.bottomAnchor constant:-12],
        [content.leadingAnchor constraintEqualToAnchor:c.leadingAnchor constant:14],
        [content.trailingAnchor constraintEqualToAnchor:c.trailingAnchor constant:-14]
    ]];
    return c;
}

- (UIStackView *)rowTitle:(NSString *)title control:(UIView *)ctrl {
    UIStackView *h = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self lbl:title size:15 weight:UIFontWeightMedium color:UIColor.whiteColor], ctrl]];
    h.axis = UILayoutConstraintAxisHorizontal;
    h.alignment = UIStackViewAlignmentCenter;
    h.distribution = UIStackViewDistributionEqualSpacing;
    return h;
}

- (UISwitch *)switchOn:(BOOL)on sel:(SEL)action {
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = on;
    sw.onTintColor = CH_ACCENT;
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    return sw;
}

- (UIButton *)btnWithTitle:(NSString *)title bg:(UIColor *)bg fg:(UIColor *)fg sel:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.backgroundColor = bg;
    b.layer.cornerRadius = 12;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:fg forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [b.heightAnchor constraintEqualToConstant:44].active = YES;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)populate {
    for (UIView *v in [_stack.arrangedSubviews copy]) {
        [_stack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    // Header
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [closeBtn setTitleColor:[UIColor colorWithWhite:0.7 alpha:1.0] forState:UIControlStateNormal];
    [closeBtn addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *headerRow = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self lbl:@"Trợ Thủ Cờ Vua Duolingo" size:20 weight:UIFontWeightBold color:UIColor.whiteColor], closeBtn]];
    headerRow.axis = UILayoutConstraintAxisHorizontal;
    headerRow.distribution = UIStackViewDistributionEqualSpacing;
    headerRow.alignment = UIStackViewAlignmentCenter;
    [_stack addArrangedSubview:headerRow];

    UILabel *creditLbl = [self lbl:@"Phát triển bởi tn2am • Stockfish 18 NNUE & Maia" size:12 weight:UIFontWeightMedium color:CH_ACCENT];
    [_stack addArrangedSubview:creditLbl];

    // Status Card
    BOOL isOurTurn = (gMyColor == gTurnColor);
    NSString *turnText = (gMyColor == 0 ? @"Bạn: Trắng ⚪" : @"Bạn: Đen ⚫");
    NSString *statText = gCurrentFen.length > 10 ?
        [NSString stringWithFormat:@"Đã kết nối (%@ - Lượt: %@)", turnText, isOurTurn ? @"CỦA BẠN" : @"ĐỐI THỦ"] :
        @"Chưa nhận diện bàn cờ (hãy vào bài học/ván cờ)";
    _statusLabel = [self lbl:statText size:12 weight:UIFontWeightRegular color:(gCurrentFen.length > 10 ? CH_ACCENT : [UIColor colorWithRed:0.95 green:0.80 blue:0.3 alpha:1.0])];

    NSString *moveInfo = isOurTurn ?
        (gBestMoveStr.length ? [NSString stringWithFormat:@"Gợi ý: %@ (%@)", gBestMoveStr, gBestEvalStr ?: @""] : @"Đang tính nước cờ...") :
        @"⏳ Đang chờ đối thủ đi...";
    UILabel *moveLbl = [self lbl:moveInfo size:14 weight:UIFontWeightSemibold color:(isOurTurn ? UIColor.whiteColor : [UIColor colorWithWhite:0.65 alpha:1.0])];

    UISegmentedControl *colorSeg = [[UISegmentedControl alloc] initWithItems:@[@"⚪ Bạn: Quân Trắng", @"⚫ Bạn: Quân Đen"]];
    colorSeg.selectedSegmentIndex = (gMyColor == 1 ? 1 : 0);
    colorSeg.selectedSegmentTintColor = (gMyColor == 1 ? [UIColor colorWithRed:0.22 green:0.25 blue:0.30 alpha:1.0] : UIColor.whiteColor);
    [colorSeg setTitleTextAttributes:@{NSForegroundColorAttributeName: (gMyColor == 1 ? UIColor.whiteColor : UIColor.blackColor)} forState:UIControlStateSelected];
    [colorSeg setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.75 alpha:1.0]} forState:UIControlStateNormal];
    [colorSeg addTarget:self action:@selector(colorSegChanged:) forControlEvents:UIControlEventValueChanged];

    UIStackView *statusCol = [[UIStackView alloc] initWithArrangedSubviews:@[_statusLabel, moveLbl, [self sep], colorSeg]];
    statusCol.axis = UILayoutConstraintAxisVertical;
    statusCol.spacing = 8;
    [_stack addArrangedSubview:[self group:statusCol]];

    // 1. Engine Section
    [_stack addArrangedSubview:[self sectionLabel:@"Động Cơ Phân Tích (Engine)"]];

    UISegmentedControl *engSeg = [[UISegmentedControl alloc] initWithItems:@[@"Stockfish 18", @"Maia (Tự nhiên)"]];
    engSeg.selectedSegmentIndex = gUseMaia ? 1 : 0;
    engSeg.selectedSegmentTintColor = CH_ACCENT;
    [engSeg setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.blackColor} forState:UIControlStateSelected];
    [engSeg setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor} forState:UIControlStateNormal];
    [engSeg addTarget:self action:@selector(engSegChanged:) forControlEvents:UIControlEventValueChanged];

    _eloValueLabel = [self lbl:[NSString stringWithFormat:@"%ld ELO", (long)gElo] size:15 weight:UIFontWeightBold color:CH_ACCENT];
    _eloTierLabel = [self lbl:eloTierName(gElo) size:12 weight:UIFontWeightRegular color:[UIColor colorWithWhite:0.6 alpha:1.0]];

    UISlider *eloSlider = [[UISlider alloc] init];
    eloSlider.minimumValue = 400; eloSlider.maximumValue = 3000; eloSlider.value = gElo;
    eloSlider.minimumTrackTintColor = CH_ACCENT;
    [eloSlider addTarget:self action:@selector(eloSliding:) forControlEvents:UIControlEventValueChanged];

    UIStackView *eloHeader = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self lbl:@"Độ mạnh (ELO)" size:15 weight:UIFontWeightMedium color:UIColor.whiteColor], _eloValueLabel]];
    eloHeader.axis = UILayoutConstraintAxisHorizontal;
    eloHeader.distribution = UIStackViewDistributionEqualSpacing;

    UIStackView *engCol = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self rowTitle:@"Mô hình" control:engSeg], [self sep],
        eloHeader, eloSlider, _eloTierLabel]];
    engCol.axis = UILayoutConstraintAxisVertical;
    engCol.spacing = 8;
    [_stack addArrangedSubview:[self group:engCol]];

    // 2. Display & Warnings Section
    [_stack addArrangedSubview:[self sectionLabel:@"Hiển Thị Gợi Ý & Cảnh Báo"]];

    UISegmentedControl *flipSeg = [[UISegmentedControl alloc] initWithItems:@[@"Tự động", @"Trắng dưới", @"Đen dưới"]];
    flipSeg.selectedSegmentIndex = gFlipMode;
    flipSeg.selectedSegmentTintColor = CH_ACCENT;
    [flipSeg setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.blackColor} forState:UIControlStateSelected];
    [flipSeg setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor} forState:UIControlStateNormal];
    [flipSeg addTarget:self action:@selector(flipSegChanged:) forControlEvents:UIControlEventValueChanged];

    UISegmentedControl *evalSeg = [[UISegmentedControl alloc] initWithItems:@[@"Điểm (+/-)", @"% Thắng"]];
    evalSeg.selectedSegmentIndex = gShowWinPct ? 1 : 0;
    evalSeg.selectedSegmentTintColor = CH_ACCENT;
    [evalSeg setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.blackColor} forState:UIControlStateSelected];
    [evalSeg setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor} forState:UIControlStateNormal];
    [evalSeg addTarget:self action:@selector(evalSegChanged:) forControlEvents:UIControlEventValueChanged];

    UISegmentedControl *arrSeg = [[UISegmentedControl alloc] initWithItems:@[@"1 mũi tên", @"2", @"3"]];
    arrSeg.selectedSegmentIndex = MIN(2, MAX(0, (int)gArrowCount - 1));
    arrSeg.selectedSegmentTintColor = CH_ACCENT;
    [arrSeg setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.blackColor} forState:UIControlStateSelected];
    [arrSeg setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor} forState:UIControlStateNormal];
    [arrSeg addTarget:self action:@selector(arrSegChanged:) forControlEvents:UIControlEventValueChanged];

    UISegmentedControl *thickSeg = [[UISegmentedControl alloc] initWithItems:@[@"Mảnh", @"Vừa", @"Dày"]];
    thickSeg.selectedSegmentIndex = gArrowThick < 0.85 ? 0 : (gArrowThick > 1.2 ? 2 : 1);
    thickSeg.selectedSegmentTintColor = CH_ACCENT;
    [thickSeg setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.blackColor} forState:UIControlStateSelected];
    [thickSeg setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor} forState:UIControlStateNormal];
    [thickSeg addTarget:self action:@selector(thickSegChanged:) forControlEvents:UIControlEventValueChanged];

    _alphaValueLabel = [self lbl:[NSString stringWithFormat:@"%d%%", (int)round(gArrowAlpha * 100)] size:15 weight:UIFontWeightSemibold color:CH_ACCENT];
    UISlider *alphaSlider = [[UISlider alloc] init];
    alphaSlider.minimumValue = 0.3; alphaSlider.maximumValue = 1.0; alphaSlider.value = gArrowAlpha;
    alphaSlider.minimumTrackTintColor = CH_ACCENT;
    [alphaSlider addTarget:self action:@selector(alphaSliding:) forControlEvents:UIControlEventValueChanged];

    UIStackView *dispCol = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self rowTitle:@"Chiều bàn cờ" control:flipSeg], [self sep],
        [self rowTitle:@"Cảnh báo nước đối thủ (Mũi tên đỏ ⚠️)" control:[self switchOn:gShowThreats sel:@selector(swThreatsChanged:)]], [self sep],
        [self rowTitle:@"Kiểu đánh giá" control:evalSeg], [self sep],
        [self rowTitle:@"Số mũi tên của bạn" control:arrSeg], [self sep],
        [self rowTitle:@"Độ dày mũi tên" control:thickSeg], [self sep],
        [self rowTitle:@"Nhãn điểm trên mũi tên" control:[self switchOn:gShowEvalLabels sel:@selector(swEvalLabelsChanged:)]], [self sep],
        [self rowTitle:@"Độ trong suốt" control:_alphaValueLabel], alphaSlider]];
    dispCol.axis = UILayoutConstraintAxisVertical;
    dispCol.spacing = 10;
    [_stack addArrangedSubview:[self group:dispCol]];

    // 3. Auto Play Section
    [_stack addArrangedSubview:[self sectionLabel:@"Tự Động Đi Cờ (Auto Play)"]];

    _delayValueLabel = [self lbl:[NSString stringWithFormat:@"%.1fs", gAutoPlayDelay] size:15 weight:UIFontWeightBold color:CH_ACCENT];
    UISlider *delaySlider = [[UISlider alloc] init];
    delaySlider.minimumValue = 0.1; delaySlider.maximumValue = 3.0; delaySlider.value = gAutoPlayDelay;
    delaySlider.minimumTrackTintColor = CH_ACCENT;
    [delaySlider addTarget:self action:@selector(delaySliding:) forControlEvents:UIControlEventValueChanged];

    _secondMoveValueLabel = [self lbl:[NSString stringWithFormat:@"%ld%%", (long)gAutoPlaySecondBestPct] size:15 weight:UIFontWeightBold color:CH_ACCENT];
    UISlider *secondMoveSlider = [[UISlider alloc] init];
    secondMoveSlider.minimumValue = 0; secondMoveSlider.maximumValue = 40; secondMoveSlider.value = gAutoPlaySecondBestPct;
    secondMoveSlider.minimumTrackTintColor = CH_ACCENT;
    [secondMoveSlider addTarget:self action:@selector(secondMoveSliding:) forControlEvents:UIControlEventValueChanged];

    UIStackView *apCol = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self rowTitle:@"Bật Tự Động Đi" control:[self switchOn:gAutoPlay sel:@selector(swAutoPlayChanged:)]], [self sep],
        [self rowTitle:@"Thời gian trễ" control:_delayValueLabel], delaySlider, [self sep],
        [self rowTitle:@"Biến thiên tự nhiên (Jitter)" control:[self switchOn:gAutoPlayJitterEnabled sel:@selector(swJitterChanged:)]], [self sep],
        [self rowTitle:@"Tỉ lệ đi nước phụ (Tránh ban)" control:_secondMoveValueLabel], secondMoveSlider,
        [self lbl:@"Chỉ tự động đi khi ĐẾN LƯỢT CỦA BẠN. Không đi thay lượt của đối thủ." size:11 weight:UIFontWeightRegular color:[UIColor colorWithWhite:0.55 alpha:1.0]]]];
    apCol.axis = UILayoutConstraintAxisVertical;
    apCol.spacing = 10;
    [_stack addArrangedSubview:[self group:apCol]];

    // 4. Actions Section
    [_stack addArrangedSubview:[self sectionLabel:@"Thao Tác Nhanh (Controls)"]];

    UIButton *gmPresetBtn = [self btnWithTitle:@"👑 Siêu Máy Tính (3500 ELO - Bất Bại)"
                                            bg:[UIColor colorWithRed:0.25 green:0.18 blue:0.40 alpha:1.0]
                                            fg:[UIColor colorWithRed:0.85 green:0.65 blue:1.0 alpha:1.0]
                                           sel:@selector(applyGrandmasterPreset)];
    [_stack addArrangedSubview:gmPresetBtn];

    UIButton *safePresetBtn = [self btnWithTitle:@"🛡️ Cài đặt An Toàn (Mô phỏng người thật)"
                                              bg:[UIColor colorWithWhite:0.18 alpha:1.0]
                                              fg:CH_ACCENT
                                             sel:@selector(applySafePreset)];
    [_stack addArrangedSubview:safePresetBtn];

    UIButton *resetMatchBtn = [self btnWithTitle:@"🔄 Nhận diện lại bàn cờ mới"
                                              bg:[UIColor colorWithWhite:0.18 alpha:1.0]
                                              fg:[UIColor colorWithRed:0.40 green:0.80 blue:1.0 alpha:1.0]
                                             sel:@selector(manualResetMatch)];
    [_stack addArrangedSubview:resetMatchBtn];

    UIButton *toggleBtn = [self btnWithTitle:(gEnabled ? @"⏸ Tạm dừng Trợ Thủ" : @"▶ Bật lại Trợ Thủ")
                                          bg:(gEnabled ? [UIColor colorWithRed:0.8 green:0.25 blue:0.25 alpha:1.0] : CH_ACCENT)
                                          fg:(gEnabled ? UIColor.whiteColor : UIColor.blackColor)
                                         sel:@selector(toggleEnabled)];
    [_stack addArrangedSubview:toggleBtn];

    UIButton *copyFenBtn = [self btnWithTitle:@"📋 Sao chép FEN bàn cờ"
                                           bg:[UIColor colorWithWhite:0.18 alpha:1.0]
                                           fg:UIColor.whiteColor
                                          sel:@selector(copyFenTapped)];
    [_stack addArrangedSubview:copyFenBtn];

    UIButton *doneBtn = [self btnWithTitle:@"Hoàn tất" bg:CH_ACCENT fg:UIColor.blackColor sel:@selector(closeTapped)];
    [_stack addArrangedSubview:doneBtn];
}

- (void)engSegChanged:(UISegmentedControl *)s {
    gUseMaia = (s.selectedSegmentIndex == 1);
    savePrefs();
    gLastEvalFen = nil;
    if (gCurrentFen) processFen(gCurrentFen);
}

- (void)eloSliding:(UISlider *)s {
    gElo = (NSInteger)s.value;
    _eloValueLabel.text = [NSString stringWithFormat:@"%ld ELO", (long)gElo];
    _eloTierLabel.text = eloTierName(gElo);
    savePrefs();
}

- (void)flipSegChanged:(UISegmentedControl *)s {
    gFlipMode = s.selectedSegmentIndex;
    updateBoardFlipped();
    savePrefs();
    if (gCurrentArrows.count && gBoardView) {
        drawArrows(gCurrentArrows, gBoardView, gBoardFlipped, gLastWasThreat);
    }
}

- (void)swThreatsChanged:(UISwitch *)s {
    gShowThreats = s.on;
    savePrefs();
    if (gCurrentFen) processFen(gCurrentFen);
}

- (void)evalSegChanged:(UISegmentedControl *)s {
    gShowWinPct = (s.selectedSegmentIndex == 1);
    savePrefs();
    if (gCurrentFen) processFen(gCurrentFen);
}

- (void)arrSegChanged:(UISegmentedControl *)s {
    gArrowCount = s.selectedSegmentIndex + 1;
    savePrefs();
    if (gCurrentFen) processFen(gCurrentFen);
}

- (void)thickSegChanged:(UISegmentedControl *)s {
    gArrowThick = (s.selectedSegmentIndex == 0 ? 0.7 : (s.selectedSegmentIndex == 2 ? 1.4 : 1.0));
    savePrefs();
    if (gCurrentArrows.count && gBoardView) drawArrows(gCurrentArrows, gBoardView, gBoardFlipped, gLastWasThreat);
}

- (void)alphaSliding:(UISlider *)s {
    gArrowAlpha = s.value;
    _alphaValueLabel.text = [NSString stringWithFormat:@"%d%%", (int)round(s.value * 100)];
    savePrefs();
    if (gCurrentArrows.count && gBoardView) drawArrows(gCurrentArrows, gBoardView, gBoardFlipped, gLastWasThreat);
}

- (void)swEvalLabelsChanged:(UISwitch *)s {
    gShowEvalLabels = s.on;
    savePrefs();
    if (gCurrentArrows.count && gBoardView) drawArrows(gCurrentArrows, gBoardView, gBoardFlipped, gLastWasThreat);
}

- (void)swAutoPlayChanged:(UISwitch *)s {
    gAutoPlay = s.on;
    savePrefs();
    showToast(gAutoPlay ? @"▶ Đã bật Tự Động Đi Cờ" : @"⏸ Đã tắt Tự Động Đi Cờ");
}

- (void)delaySliding:(UISlider *)s {
    gAutoPlayDelay = s.value;
    _delayValueLabel.text = [NSString stringWithFormat:@"%.1fs", s.value];
    savePrefs();
}

- (void)swJitterChanged:(UISwitch *)s {
    gAutoPlayJitterEnabled = s.on;
    savePrefs();
}

- (void)secondMoveSliding:(UISlider *)s {
    gAutoPlaySecondBestPct = (NSInteger)s.value;
    _secondMoveValueLabel.text = [NSString stringWithFormat:@"%ld%%", (long)gAutoPlaySecondBestPct];
    savePrefs();
}

- (void)toggleEnabled {
    gEnabled = !gEnabled;
    savePrefs();
    if (!gEnabled) clearArrows();
    else if (gCurrentFen) processFen(gCurrentFen);
    showToast(gEnabled ? @"▶ Đã bật Trợ Thủ Cờ Vua" : @"⏸ Đã tạm dừng Trợ Thủ");
    [self populate];
}

- (void)applySafePreset {
    gElo = 1200;
    gAutoPlay = YES;
    gAutoPlayDelay = 0.8;
    gAutoPlayJitterEnabled = YES;
    gAutoPlayJitterRange = 0.4;
    gAutoPlaySecondBest = YES;
    gAutoPlaySecondBestPct = 12;
    gArrowCount = 1;
    gShowThreats = NO;
    savePrefs();
    showToast(@"✓ Đã áp dụng cấu hình An Toàn");
    [self populate];
}

- (void)colorSegChanged:(UISegmentedControl *)s {
    gMyColor = s.selectedSegmentIndex;
    gMyColorLocked = YES;
    updateBoardFlipped();
    savePrefs();
    showToast(gMyColor == 0 ? @"⚪ Đã chọn: Bạn là quân Trắng (Đi trước)" : @"⚫ Đã chọn: Bạn là quân Đen (Đi sau)");
    gLastEvalFen = nil;
    gEvaluatingFen = nil;
    if (gCurrentFen) processFen(gCurrentFen);
    [self populate];
}

- (void)applyGrandmasterPreset {
    gElo = 3000;
    gArrowCount = 1;
    gShowThreats = NO;
    gUseMaia = NO;
    savePrefs();
    showToast(@"👑 Đã bật Siêu Máy Tính (Stockfish 18 NNUE Max)");
    [self populate];
    gLastEvalFen = nil;
    gEvaluatingFen = nil;
    if (gCurrentFen) processFen(gCurrentFen);
}

- (void)manualResetMatch {
    id gs = gLatestGameState;
    resetForNewGame(@"Người dùng bấm làm mới ván cờ");
    showToast(@"🔄 Đã làm mới! Đang nhận diện lại bàn cờ...");
    UIView *board = findActiveBoardView();
    if (board) {
        gBoardView = board;
        updateBoardFlipped();
    }
    if (gs) {
        gLatestGameState = gs;
        detectColorFromGameState(gs);
        NSString *fen = extractFenFromGameState(gs);
        if (fen) processFen(fen);
    } else if (gCurrentFen) {
        processFen(gCurrentFen);
    }
    [self populate];
}

- (void)copyFenTapped {
    if (gCurrentFen.length > 10) {
        [UIPasteboard generalPasteboard].string = gCurrentFen;
        showToast(@"📋 Đã sao chép FEN vào bộ nhớ tạm");
    } else {
        showToast(@"⏳ Chưa có dữ liệu FEN bàn cờ");
    }
}

- (void)closeTapped {
    if (gMenuWin) gMenuWin.hidden = YES;
}

@end

static UIWindowScene *getActiveWindowScene(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                if (ws.activationState == UISceneActivationStateForegroundActive ||
                    ws.activationState == UISceneActivationStateForegroundInactive) {
                    return ws;
                }
            }
        }
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                return (UIWindowScene *)scene;
            }
        }
    }
    return nil;
}

static void showSettingsMenu(void) {
    UIWindowScene *scene = getActiveWindowScene();

    if (!gMenuWin) {
        if (@available(iOS 13.0, *)) {
            if (scene) gMenuWin = [[UIWindow alloc] initWithWindowScene:scene];
        }
        if (!gMenuWin) gMenuWin = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        gMenuWin.windowLevel = UIWindowLevelStatusBar + 120.0;
        gMenuWin.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.5];
        gMenuWin.rootViewController = [[UIViewController alloc] init];
    } else if (@available(iOS 13.0, *)) {
        if (!gMenuWin.windowScene && scene) gMenuWin.windowScene = scene;
    }

    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
    CGFloat menuH = MIN(screenH * 0.85, 590);

    [gMenuWin.rootViewController.view.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];

    DuoRichSettingsView *menuView = [[DuoRichSettingsView alloc] initWithFrame:CGRectMake(16, (screenH - menuH) / 2, screenW - 32, menuH)];
    [gMenuWin.rootViewController.view addSubview:menuView];
    gMenuWin.hidden = NO;
    [gMenuWin makeKeyAndVisible];
}

// --- FLOATING BUTTON ---
@interface DuoChessBtnHandler : NSObject
+ (void)floatBtnTapped;
+ (void)handlePan:(UIPanGestureRecognizer *)pan;
+ (void)handleLongPress:(UILongPressGestureRecognizer *)lp;
@end

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
    else if (gCurrentFen) processFen(gCurrentFen);
    dbg([NSString stringWithFormat:@"Trạng thái trợ thủ: %@", gEnabled ? @"BẬT" : @"TẮT"]);
    showToast(gEnabled ? @"▶ Đã bật Trợ Thủ Cờ Vua" : @"⏸ Đã tạm dừng Trợ Thủ");
}
@end

static void setupFloatingButton(void) {
    UIWindowScene *scene = getActiveWindowScene();

    if (!gBtnWin) {
        if (@available(iOS 13.0, *)) {
            if (scene) gBtnWin = [[UIWindow alloc] initWithWindowScene:scene];
        }
        if (!gBtnWin) gBtnWin = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    } else if (@available(iOS 13.0, *)) {
        if (!gBtnWin.windowScene && scene) gBtnWin.windowScene = scene;
    }

    gBtnWin.windowLevel = UIWindowLevelStatusBar + 100.0;
    gBtnWin.backgroundColor = [UIColor clearColor];
    if (!gBtnWin.rootViewController) {
        gBtnWin.rootViewController = [[UIViewController alloc] init];
        gBtnWin.rootViewController.view.backgroundColor = [UIColor clearColor];
    }

    CGFloat btnSize = 48;
    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;

    if (!gFloatBtn) {
        gFloatBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        gFloatBtn.frame = CGRectMake(screenW - btnSize - 12, screenH * 0.40, btnSize, btnSize);
        gFloatBtn.backgroundColor = [UIColor colorWithRed:0.18 green:0.22 blue:0.25 alpha:0.95];
        gFloatBtn.layer.cornerRadius = 14;
        gFloatBtn.layer.borderColor = [CH_ACCENT CGColor];
        gFloatBtn.layer.borderWidth = 2.0;
        [gFloatBtn setTitle:@"♟" forState:UIControlStateNormal];
        gFloatBtn.titleLabel.font = [UIFont systemFontOfSize:24];

        [gFloatBtn addTarget:[DuoChessBtnHandler class] action:@selector(floatBtnTapped) forControlEvents:UIControlEventTouchUpInside];
        [gFloatBtn addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:[DuoChessBtnHandler class] action:@selector(handlePan:)]];
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:[DuoChessBtnHandler class] action:@selector(handleLongPress:)];
        lp.minimumPressDuration = 0.4;
        [gFloatBtn addGestureRecognizer:lp];

        [gBtnWin.rootViewController.view addSubview:gFloatBtn];
    }

    gBtnWin.hidden = NO;
    [gBtnWin makeKeyAndVisible];
}

static UIView *(*gOrig_WindowHitTest)(UIWindow *, SEL, CGPoint, UIEvent *) = NULL;
static UIView *hook_WindowHitTest(UIWindow *self, SEL _cmd, CGPoint point, UIEvent *event) {
    if (self == gBtnWin) {
        if (gFloatBtn && self.rootViewController) {
            CGPoint btnPoint = [gFloatBtn convertPoint:point fromView:self.rootViewController.view];
            if ([gFloatBtn pointInside:btnPoint withEvent:event]) return gFloatBtn;
        }
        return nil;
    }
    return gOrig_WindowHitTest ? gOrig_WindowHitTest(self, _cmd, point, event) : nil;
}

static void (*gOrig_WindowMakeKeyAndVisible)(UIWindow *, SEL) = NULL;
static void hook_WindowMakeKeyAndVisible(UIWindow *self, SEL _cmd) {
    if (gOrig_WindowMakeKeyAndVisible) gOrig_WindowMakeKeyAndVisible(self, _cmd);
    if (self != gBtnWin && self != gMenuWin) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            setupFloatingButton();
        });
    }
}

// --- CONSTRUCTOR ---
__attribute__((constructor)) static void initTweak(void) {
    loadPrefs();
    dbg(@"Trợ Thủ Cờ Vua Duolingo (tn2am • Tốc Độ Cao & Cảnh Báo) đã nạp!");

    Class winCls = [UIWindow class];
    SwizzleInstanceMethod(winCls, @selector(hitTest:withEvent:), (IMP)hook_WindowHitTest, (IMP *)&gOrig_WindowHitTest);
    SwizzleInstanceMethod(winCls, @selector(makeKeyAndVisible), (IMP)hook_WindowMakeKeyAndVisible, (IMP *)&gOrig_WindowMakeKeyAndVisible);

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        setupFloatingButton();
        installDuolingoHooks();
    }];

    double delays[] = { 0.5, 1.2, 2.5, 4.0 };
    for (int i = 0; i < 4; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            setupFloatingButton();
            installDuolingoHooks();
        });
    }
}
