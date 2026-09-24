#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
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

// Captured game state references
static __weak id gLatestGameState  = nil;
static __weak id gLatestBoardState = nil;
static __weak id gLatestFenObj     = nil;

static UIWindow *gBtnWin   = nil;
static UIButton *gFloatBtn = nil;
static UIWindow *gMenuWin  = nil;
static UILabel  *gEloLabel = nil;
static UILabel  *gStatusLabel = nil;
static BOOL      gSkipNextTap = NO;
static NSTimer  *gAutoPollTimer = nil;

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
    if (!fen || ![fen isKindOfClass:[NSString class]] || fen.length < 10) return;

    // Normalize FEN string: ensure standard 6 fields
    NSString *cleanFen = [fen stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSArray *parts = [cleanFen componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (parts.count < 2) {
        cleanFen = [NSString stringWithFormat:@"%@ w KQkq - 0 1", cleanFen];
    } else if (parts.count < 4) {
        cleanFen = [NSString stringWithFormat:@"%@ - - 0 1", cleanFen];
    }

    gCurrentFen = [cleanFen copy];

    if (gStatusLabel) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *preview = cleanFen.length > 25 ? [cleanFen substringToIndex:25] : cleanFen;
            gStatusLabel.text = [NSString stringWithFormat:@"Đã kết nối: %@...", preview];
            gStatusLabel.textColor = CH_ACCENT;
        });
    }

    if (!gEnabled) return;
    if ([cleanFen isEqualToString:gLastEvalFen] && gCurrentArrows.count) return;

    gLastEvalFen = [cleanFen copy];
    gFetching = YES;

    dbg([NSString stringWithFormat:@"Stockfish phân tích FEN: %@", cleanFen]);

    if (gUseMaia && MaiaAvailable()) {
        MaiaGo([cleanFen UTF8String], (int)gElo, (int)gElo, ^(MaiaResult res) {
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

    EngineGo([cleanFen UTF8String], depth, (int)gElo, multipv, ^(const EngineLine *lines, int count) {
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

// --- FEN RECONSTRUCTION & EXTRACTION HELPERS ---

static void updateOrientationFromGameState(id gs) {
    if (!gs) return;
    SEL userColSel = NSSelectorFromString(@"userColor");
    if ([gs respondsToSelector:userColSel]) {
        id uc = ((id (*)(id, SEL))objc_msgSend)(gs, userColSel);
        if (uc) {
            NSString *desc = [[uc description] lowercaseString];
            if ([desc containsString:@"black"]) {
                gBoardFlipped = YES;
            } else if ([desc containsString:@"white"]) {
                gBoardFlipped = NO;
            }
        }
    }
}

static NSString *extractFenFromGameState(id gs) {
    if (!gs) return nil;
    updateOrientationFromGameState(gs);

    // 1. Try gs.fen -> fenString
    SEL fenSel = NSSelectorFromString(@"fen");
    if ([gs respondsToSelector:fenSel]) {
        id fenObj = ((id (*)(id, SEL))objc_msgSend)(gs, fenSel);
        if (fenObj) {
            gLatestFenObj = fenObj;
            SEL fenStrSel = NSSelectorFromString(@"fenString");
            if ([fenObj respondsToSelector:fenStrSel]) {
                NSString *fs = ((NSString *(*)(id, SEL))objc_msgSend)(fenObj, fenStrSel);
                if (fs && [fs isKindOfClass:[NSString class]] && fs.length > 10) {
                    return fs;
                }
            }
        }
    }

    // 2. Try gs.setupModel -> fenNotation
    SEL setupSel = NSSelectorFromString(@"setupModel");
    if ([gs respondsToSelector:setupSel]) {
        id sm = ((id (*)(id, SEL))objc_msgSend)(gs, setupSel);
        if (sm) {
            SEL fnSel = NSSelectorFromString(@"fenNotation");
            if ([sm respondsToSelector:fnSel]) {
                NSString *fn = ((NSString *(*)(id, SEL))objc_msgSend)(sm, fnSel);
                if (fn && [fn isKindOfClass:[NSString class]] && fn.length > 10) {
                    return fn;
                }
            }
        }
    }

    // 3. Try gs.chessBoardState -> reconstruct 8x8 pieces
    SEL bsSel = NSSelectorFromString(@"chessBoardState");
    if ([gs respondsToSelector:bsSel]) {
        id bs = ((id (*)(id, SEL))objc_msgSend)(gs, bsSel);
        if (bs) {
            gLatestBoardState = bs;
            SEL chessSel = NSSelectorFromString(@"chess");
            if ([bs respondsToSelector:chessSel]) {
                NSArray *rows = ((NSArray *(*)(id, SEL))objc_msgSend)(bs, chessSel);
                if ([rows isKindOfClass:[NSArray class]] && rows.count == 8) {
                    NSMutableString *fenBuilder = [NSMutableString string];
                    for (int r = 0; r < 8; r++) {
                        id rowObj = rows[r];
                        if (![rowObj isKindOfClass:[NSArray class]]) continue;
                        NSArray *row = (NSArray *)rowObj;
                        int emptyCount = 0;
                        for (int c = 0; c < 8 && c < (int)row.count; c++) {
                            id piece = row[c];
                            if (!piece || piece == [NSNull null]) {
                                emptyCount++;
                            } else {
                                SEL symSel = NSSelectorFromString(@"fenSymbol");
                                NSString *sym = nil;
                                if ([piece respondsToSelector:symSel]) {
                                    sym = ((NSString *(*)(id, SEL))objc_msgSend)(piece, symSel);
                                }
                                if (sym && sym.length) {
                                    if (emptyCount > 0) {
                                        [fenBuilder appendFormat:@"%d", emptyCount];
                                        emptyCount = 0;
                                    }
                                    [fenBuilder appendString:sym];
                                } else {
                                    emptyCount++;
                                }
                            }
                        }
                        if (emptyCount > 0) {
                            [fenBuilder appendFormat:@"%d", emptyCount];
                        }
                        if (r < 7) [fenBuilder appendString:@"/"];
                    }

                    NSString *activeTurn = @"w";
                    SEL curSel = NSSelectorFromString(@"currentPlayer");
                    if ([gs respondsToSelector:curSel]) {
                        id cp = ((id (*)(id, SEL))objc_msgSend)(gs, curSel);
                        if (cp && [[[cp description] lowercaseString] containsString:@"black"]) {
                            activeTurn = @"b";
                        }
                    }
                    [fenBuilder appendFormat:@" %@ KQkq - 0 1", activeTurn];
                    return fenBuilder;
                }
            }
        }
    }

    return nil;
}

// Deep search view hierarchy for ChessBoardView
static UIView *findChessBoardViewInView(UIView *root) {
    if (!root) return nil;
    NSString *clsName = NSStringFromClass([root class]);
    if ([clsName containsString:@"ChessBoardView"] || [clsName containsString:@"StaticChessBoardView"]) {
        return root;
    }
    for (UIView *sub in root.subviews) {
        UIView *found = findChessBoardViewInView(sub);
        if (found) return found;
    }
    return nil;
}

static UIView *findActiveBoardView(void) {
    if (gBoardView && gBoardView.window) return gBoardView;

    UIWindow *keyWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.isKeyWindow && w != gBtnWin && w != gMenuWin) {
                        keyWindow = w; break;
                    }
                }
            }
            if (keyWindow) break;
        }
    }
    if (!keyWindow) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w != gBtnWin && w != gMenuWin && !w.hidden) {
                keyWindow = w; break;
            }
        }
    }
    if (keyWindow) {
        UIView *found = findChessBoardViewInView(keyWindow);
        if (found) {
            gBoardView = found;
            return found;
        }
    }
    return nil;
}

// Inspect properties / ivars of a view or controller to locate GameState
static id findGameStateInObject(id obj, int depth) {
    if (!obj || depth > 2) return nil;

    Class cls = [obj class];
    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList(cls, &ivarCount);
    if (ivars) {
        for (unsigned int i = 0; i < ivarCount; i++) {
            const char *ivarName = ivar_getName(ivars[i]);
            if (!ivarName) continue;
            NSString *name = [NSString stringWithUTF8String:ivarName];
            if ([name containsString:@"gameState"] || [name containsString:@"GameState"] ||
                [name containsString:@"boardState"] || [name containsString:@"BoardState"]) {
                id val = object_getIvar(obj, ivars[i]);
                if (val) {
                    free(ivars);
                    return val;
                }
            }
        }
        free(ivars);
    }
    return nil;
}

// Continuous background auto-reader (Runs every 0.8s)
static void performAutoBoardScan(void) {
    UIView *board = findActiveBoardView();
    if (!board) return;

    // 1. Try latest game state
    if (gLatestGameState) {
        NSString *fen = extractFenFromGameState(gLatestGameState);
        if (fen.length > 10) {
            if (![fen isEqualToString:gCurrentFen]) {
                dbg([NSString stringWithFormat:@"[Tự Động] Bắt FEN mới từ GameState: %@", fen]);
                processFen(fen);
            }
            return;
        }
    }

    // 2. Scan board ivars
    id foundState = findGameStateInObject(board, 0);
    if (foundState) {
        gLatestGameState = foundState;
        NSString *fen = extractFenFromGameState(foundState);
        if (fen.length > 10) {
            dbg([NSString stringWithFormat:@"[Tự Động] Bắt FEN từ board ivars: %@", fen]);
            processFen(fen);
            return;
        }
    }

    // 3. Scan board viewController
    UIResponder *resp = board.nextResponder;
    while (resp && ![resp isKindOfClass:[UIViewController class]]) {
        resp = resp.nextResponder;
    }
    if (resp) {
        id vcState = findGameStateInObject(resp, 0);
        if (vcState) {
            gLatestGameState = vcState;
            NSString *fen = extractFenFromGameState(vcState);
            if (fen.length > 10) {
                dbg([NSString stringWithFormat:@"[Tự Động] Bắt FEN từ viewController: %@", fen]);
                processFen(fen);
                return;
            }
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
    // Force a scan whenever the floating button is tapped
    performAutoBoardScan();
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
    dbg([NSString stringWithFormat:@"Trạng thái trợ thủ: %@", gEnabled ? @"BẬT" : @"TẮT"]);
    showToast(gEnabled ? @"▶ Đã bật Trợ Thủ Cờ Vua" : @"⏸ Đã tạm dừng Trợ Thủ");
}
@end

@implementation DuoPanelHandler
+ (void)eloChanged:(UISlider *)slider {
    gElo = (NSInteger)slider.value;
    if (gEloLabel) {
        gEloLabel.text = [NSString stringWithFormat:@"Độ khó Engine: %ld ELO", (long)gElo];
    }
    savePrefs();
}
+ (void)copyFenTapped:(UIButton *)btn {
    // Attempt force re-scan right away
    performAutoBoardScan();

    if (gCurrentFen.length > 10) {
        [UIPasteboard generalPasteboard].string = gCurrentFen;
        [btn setTitle:@"✓ Đã sao chép FEN!" forState:UIControlStateNormal];
        showToast(@"📋 Đã chép FEN vào bộ nhớ tạm");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [btn setTitle:@"📋 Sao chép FEN bàn cờ" forState:UIControlStateNormal];
        });
    } else {
        [btn setTitle:@"⏳ Đang tìm bàn cờ..." forState:UIControlStateNormal];
        showToast(@"⚠️ Đang chờ bạn vào một ván cờ hoặc bài tập Duolingo");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [btn setTitle:@"📋 Sao chép FEN bàn cờ" forState:UIControlStateNormal];
        });
    }
}
+ (void)closeTapped:(UIButton *)btn {
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
        gFloatBtn.layer.borderColor = [UIColor colorWithRed:0.35 green:0.75 blue:0.40 alpha:0.95].CGColor;
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
    dbg(@"Đã hiển thị nút nổi ♟");
}

// Hook hitTest on UIWindow without Substrate
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

// --- SETTINGS PANEL (VIETNAMESE UI) ---
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

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(24, 75, [UIScreen mainScreen].bounds.size.width - 48, 410)];
    panel.backgroundColor = [UIColor colorWithRed:0.12 green:0.15 blue:0.18 alpha:0.97];
    panel.layer.cornerRadius = 18;
    panel.layer.borderColor = [UIColor colorWithWhite:0.25 alpha:1].CGColor;
    panel.layer.borderWidth = 1;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 16, panel.bounds.size.width - 32, 24)];
    title.text = @"Trợ Thủ Cờ Vua Duolingo";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:18];
    [panel addSubview:title];

    UILabel *credit = [[UILabel alloc] initWithFrame:CGRectMake(16, 42, panel.bounds.size.width - 32, 18)];
    credit.text = @"Phát triển bởi tn2am • Stockfish 18 NNUE";
    credit.textColor = CH_ACCENT;
    credit.font = [UIFont systemFontOfSize:12];
    [panel addSubview:credit];

    // Status preview label
    gStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 68, panel.bounds.size.width - 32, 20)];
    if (gCurrentFen.length > 10) {
        NSString *preview = gCurrentFen.length > 25 ? [gCurrentFen substringToIndex:25] : gCurrentFen;
        gStatusLabel.text = [NSString stringWithFormat:@"Đã kết nối: %@...", preview];
        gStatusLabel.textColor = CH_ACCENT;
    } else {
        gStatusLabel.text = @"⏳ Đang tự động quét bàn cờ...";
        gStatusLabel.textColor = [UIColor colorWithRed:0.95 green:0.80 blue:0.3 alpha:1.0];
    }
    gStatusLabel.font = [UIFont systemFontOfSize:12];
    [panel addSubview:gStatusLabel];

    gEloLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 96, panel.bounds.size.width - 32, 20)];
    gEloLabel.text = [NSString stringWithFormat:@"Độ khó Engine: %ld ELO", (long)gElo];
    gEloLabel.textColor = [UIColor lightTextColor];
    gEloLabel.font = [UIFont systemFontOfSize:14];
    [panel addSubview:gEloLabel];

    UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(16, 122, panel.bounds.size.width - 32, 30)];
    slider.minimumValue = 400; slider.maximumValue = 3000; slider.value = gElo;
    [slider addTarget:[DuoPanelHandler class] action:@selector(eloChanged:) forControlEvents:UIControlEventValueChanged];
    [panel addSubview:slider];

    UIButton *fenBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    fenBtn.frame = CGRectMake(16, 170, panel.bounds.size.width - 32, 42);
    fenBtn.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1];
    fenBtn.layer.cornerRadius = 10;
    [fenBtn setTitle:@"📋 Sao chép FEN bàn cờ" forState:UIControlStateNormal];
    [fenBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    fenBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [fenBtn addTarget:[DuoPanelHandler class] action:@selector(copyFenTapped:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:fenBtn];

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(16, 226, panel.bounds.size.width - 32, 48)];
    hint.text = @"Mẹo: Mũi tên xanh sẽ tự động vẽ gợi ý ngay khi bạn vào ván cờ hoặc bài tập Duolingo.";
    hint.textColor = [UIColor colorWithWhite:0.75 alpha:1];
    hint.font = [UIFont systemFontOfSize:12];
    hint.numberOfLines = 3;
    hint.textAlignment = NSTextAlignmentCenter;
    [panel addSubview:hint];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(16, 335, panel.bounds.size.width - 32, 46);
    closeBtn.backgroundColor = CH_ACCENT;
    closeBtn.layer.cornerRadius = 12;
    [closeBtn setTitle:@"Hoàn tất" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [closeBtn addTarget:[DuoPanelHandler class] action:@selector(closeTapped:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:closeBtn];

    [gMenuWin.rootViewController.view.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    [gMenuWin.rootViewController.view addSubview:panel];
    gMenuWin.hidden = NO;
    [gMenuWin makeKeyAndVisible];
}

// --- PURE RUNTIME SWIZZLER (INSTANCE + CLASS METHODS) ---
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

static void SwizzleClassMethod(Class cls, SEL origSel, IMP newImp, IMP *origImp) {
    if (!cls || !origSel || !newImp) return;
    Class metaCls = object_getClass((id)cls);
    if (!metaCls) return;
    SwizzleInstanceMethod(metaCls, origSel, newImp, origImp);
}

// --- DUOLINGO HOOKS ---

typedef void (*OrigLayout)(id, SEL);
static OrigLayout gOrigBoardLayout = NULL;

static void hook_BoardLayout(UIView *self, SEL _cmd) {
    if (gOrigBoardLayout) gOrigBoardLayout(self, _cmd);
    gBoardView = self;
    performAutoBoardScan();
    if (gCurrentArrows.count) {
        drawArrows(gCurrentArrows, self, gBoardFlipped);
    }
}

// Hook DuolingoMultiplatformChessFen -> fenString
typedef NSString *(*OrigFenString)(id, SEL);
static OrigFenString gOrigFenString = NULL;

static NSString *hook_FenString(id self, SEL _cmd) {
    NSString *res = gOrigFenString ? gOrigFenString(self, _cmd) : nil;
    if (res && [res isKindOfClass:[NSString class]] && res.length > 10) {
        dbg([NSString stringWithFormat:@"Bắt FEN từ fenString: %@", res]);
        dispatch_async(dispatch_get_main_queue(), ^{
            processFen(res);
        });
    }
    return res;
}

// Hook DuolingoMultiplatformChessGameState -> fen
typedef id (*OrigGameStateFen)(id, SEL);
static OrigGameStateFen gOrigGameStateFen = NULL;

static id hook_GameStateFen(id self, SEL _cmd) {
    gLatestGameState = self;
    id fenObj = gOrigGameStateFen ? gOrigGameStateFen(self, _cmd) : nil;
    if (fenObj) {
        gLatestFenObj = fenObj;
        SEL fsSel = NSSelectorFromString(@"fenString");
        if ([fenObj respondsToSelector:fsSel]) {
            NSString *fs = ((NSString *(*)(id, SEL))objc_msgSend)(fenObj, fsSel);
            if (fs && [fs isKindOfClass:[NSString class]] && fs.length > 10) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    processFen(fs);
                });
            }
        }
    }
    return fenObj;
}

// Hook DuolingoMultiplatformChessGameState -> chessBoardState
typedef id (*OrigGameStateBoardState)(id, SEL);
static OrigGameStateBoardState gOrigGameStateBoardState = NULL;

static id hook_GameStateBoardState(id self, SEL _cmd) {
    gLatestGameState = self;
    id bs = gOrigGameStateBoardState ? gOrigGameStateBoardState(self, _cmd) : nil;
    if (bs) {
        gLatestBoardState = bs;
        if (!gCurrentFen || gCurrentFen.length < 10) {
            NSString *fen = extractFenFromGameState(self);
            if (fen.length > 10) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    processFen(fen);
                });
            }
        }
    }
    return bs;
}

// Hook DuolingoMultiplatformChessGameState -> setupModel
typedef id (*OrigGameStateSetupModel)(id, SEL);
static OrigGameStateSetupModel gOrigGameStateSetupModel = NULL;

static id hook_GameStateSetupModel(id self, SEL _cmd) {
    gLatestGameState = self;
    id sm = gOrigGameStateSetupModel ? gOrigGameStateSetupModel(self, _cmd) : nil;
    if (sm) {
        SEL fnSel = NSSelectorFromString(@"fenNotation");
        if ([sm respondsToSelector:fnSel]) {
            NSString *fn = ((NSString *(*)(id, SEL))objc_msgSend)(sm, fnSel);
            if (fn && [fn isKindOfClass:[NSString class]] && fn.length > 10) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    processFen(fn);
                });
            }
        }
    }
    return sm;
}

// Hook DuolingoMultiplatformChessGameSetupModel -> fenNotation
typedef NSString *(*OrigFenNotation)(id, SEL);
static OrigFenNotation gOrigFenNotation = NULL;

static NSString *hook_FenNotation(id self, SEL _cmd) {
    NSString *res = gOrigFenNotation ? gOrigFenNotation(self, _cmd) : nil;
    if (res && [res isKindOfClass:[NSString class]] && res.length > 10) {
        dbg([NSString stringWithFormat:@"Bắt FEN từ setupModel fenNotation: %@", res]);
        dispatch_async(dispatch_get_main_queue(), ^{
            processFen(res);
        });
    }
    return res;
}

// Factory hook for 1-arg FEN selectors (e.g. createForMiniMatchFenNotation:, createFenNotation:, constructFromFenFen:)
typedef id (*OrigFactory1)(id, SEL, NSString *);
static OrigFactory1 gOrigFactory1 = NULL;

static id hook_Factory1(id self, SEL _cmd, NSString *fenNotation) {
    id res = gOrigFactory1 ? gOrigFactory1(self, _cmd, fenNotation) : self;
    if (fenNotation && [fenNotation isKindOfClass:[NSString class]] && fenNotation.length > 10) {
        dbg([NSString stringWithFormat:@"Bắt FEN từ Factory: %@", fenNotation]);
        dispatch_async(dispatch_get_main_queue(), ^{
            processFen(fenNotation);
        });
    }
    return res;
}

// Factory hook for 2-arg FEN selectors (e.g. createFromFenFenNotation:shouldRecordAccoladeDetails:)
typedef id (*OrigFactory2)(id, SEL, NSString *, BOOL);
static OrigFactory2 gOrigFactory2 = NULL;

static id hook_Factory2(id self, SEL _cmd, NSString *fenNotation, BOOL arg2) {
    id res = gOrigFactory2 ? gOrigFactory2(self, _cmd, fenNotation, arg2) : self;
    if (fenNotation && [fenNotation isKindOfClass:[NSString class]] && fenNotation.length > 10) {
        dbg([NSString stringWithFormat:@"Bắt FEN từ Factory2: %@", fenNotation]);
        dispatch_async(dispatch_get_main_queue(), ^{
            processFen(fenNotation);
        });
    }
    return res;
}

// Hook UIWindow makeKeyAndVisible
static void (*gOrig_WindowMakeKeyAndVisible)(UIWindow *, SEL) = NULL;
static void hook_WindowMakeKeyAndVisible(UIWindow *self, SEL _cmd) {
    if (gOrig_WindowMakeKeyAndVisible) gOrig_WindowMakeKeyAndVisible(self, _cmd);
    if (self != gBtnWin && self != gMenuWin) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            setupFloatingButton();
        });
    }
}

static void installDuolingoHooks(void) {
    static BOOL hooksInstalled = NO;
    if (hooksInstalled) return;

    dbg(@"Bắt đầu nạp hệ thống Hook tự động cho Duolingo Chess...");

    // 1. Hook DuolingoMultiplatformChessFen
    Class fenCls = objc_getClass("DuolingoMultiplatformChessFen");
    if (fenCls) {
        SwizzleInstanceMethod(fenCls, NSSelectorFromString(@"fenString"), (IMP)hook_FenString, (IMP *)&gOrigFenString);
        dbg(@"ĐÃ HOOK DuolingoMultiplatformChessFen fenString");
    }

    // 2. Hook DuolingoMultiplatformChessGameState
    Class gsCls = objc_getClass("DuolingoMultiplatformChessGameState");
    if (gsCls) {
        SwizzleInstanceMethod(gsCls, NSSelectorFromString(@"fen"), (IMP)hook_GameStateFen, (IMP *)&gOrigGameStateFen);
        SwizzleInstanceMethod(gsCls, NSSelectorFromString(@"chessBoardState"), (IMP)hook_GameStateBoardState, (IMP *)&gOrigGameStateBoardState);
        SwizzleInstanceMethod(gsCls, NSSelectorFromString(@"setupModel"), (IMP)hook_GameStateSetupModel, (IMP *)&gOrigGameStateSetupModel);
        dbg(@"ĐÃ HOOK DuolingoMultiplatformChessGameState (fen, chessBoardState, setupModel)");
    }

    // 3. Hook DuolingoMultiplatformChessGameSetupModel
    Class smCls = objc_getClass("DuolingoMultiplatformChessGameSetupModel");
    if (smCls) {
        SwizzleInstanceMethod(smCls, NSSelectorFromString(@"fenNotation"), (IMP)hook_FenNotation, (IMP *)&gOrigFenNotation);
        dbg(@"ĐÃ HOOK DuolingoMultiplatformChessGameSetupModel fenNotation");
    }

    // 4. Hook factory methods on Companion / Factory classes
    NSArray *factorySelectors1 = @[
        @"createForMiniMatchFenNotation:",
        @"createForStarFromFenFenNotation:",
        @"createFenNotation:",
        @"constructFromFenFen:"
    ];
    NSArray *factorySelectors2 = @[
        @"createFromFenFenNotation:shouldRecordAccoladeDetails:"
    ];

    // Scan loaded classes for these selectors
    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses > 0) {
        Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
        numClasses = objc_getClassList(classes, numClasses);
        for (int i = 0; i < numClasses; i++) {
            Class c = classes[i];
            const char *cName = class_getName(c);
            if (!cName) continue;

            // Target classes containing Chess or Duolingo
            if (strstr(cName, "Chess") || strstr(cName, "Duolingo")) {
                for (NSString *selStr in factorySelectors1) {
                    SEL s = NSSelectorFromString(selStr);
                    if (class_getClassMethod(c, s)) {
                        SwizzleClassMethod(c, s, (IMP)hook_Factory1, (IMP *)&gOrigFactory1);
                        dbg([NSString stringWithFormat:@"ĐÃ HOOK class factory %@ trên %s", selStr, cName]);
                    }
                    if (class_getInstanceMethod(c, s)) {
                        SwizzleInstanceMethod(c, s, (IMP)hook_Factory1, (IMP *)&gOrigFactory1);
                        dbg([NSString stringWithFormat:@"ĐÃ HOOK instance factory %@ trên %s", selStr, cName]);
                    }
                }
                for (NSString *selStr in factorySelectors2) {
                    SEL s = NSSelectorFromString(selStr);
                    if (class_getClassMethod(c, s)) {
                        SwizzleClassMethod(c, s, (IMP)hook_Factory2, (IMP *)&gOrigFactory2);
                        dbg([NSString stringWithFormat:@"ĐÃ HOOK class factory %@ trên %s", selStr, cName]);
                    }
                    if (class_getInstanceMethod(c, s)) {
                        SwizzleInstanceMethod(c, s, (IMP)hook_Factory2, (IMP *)&gOrigFactory2);
                        dbg([NSString stringWithFormat:@"ĐÃ HOOK instance factory %@ trên %s", selStr, cName]);
                    }
                }
            }
        }
        free(classes);
    }

    // 5. Hook ChessBoardView layoutSubviews
    NSArray *boardNames = @[@"ChessBoardView", @"_TtC5Chess14ChessBoardView", @"Chess.ChessBoardView", @"StaticChessBoardView"];
    SEL layoutSel = @selector(layoutSubviews);
    for (NSString *name in boardNames) {
        Class bCls = objc_getClass(name.UTF8String);
        if (bCls) {
            SwizzleInstanceMethod(bCls, layoutSel, (IMP)hook_BoardLayout, (IMP *)&gOrigBoardLayout);
            dbg([NSString stringWithFormat:@"ĐÃ HOOK layoutSubviews trên %@", name]);
            hooksInstalled = YES;
            break;
        }
    }

    // 6. Start continuous automatic background poller
    if (!gAutoPollTimer) {
        dispatch_async(dispatch_get_main_queue(), ^{
            gAutoPollTimer = [NSTimer scheduledTimerWithTimeInterval:0.8
                                                             repeats:YES
                                                               block:^(NSTimer * _Nonnull timer) {
                performAutoBoardScan();
            }];
            dbg(@"ĐÃ KHỞI CHẠY BỘ QUÉT TỰ ĐỘNG BÀN CỜ DUOLINGO (0.8s)");
        });
    }
}

// --- CONSTRUCTOR ---
__attribute__((constructor)) static void initTweak(void) {
    loadPrefs();
    dbg(@"Trợ Thủ Cờ Vua Duolingo (Tự Động • tn2am) đã nạp!");
    EngineStart();

    // Hook UIWindow hitTest and makeKeyAndVisible
    Class winCls = [UIWindow class];
    SwizzleInstanceMethod(winCls, @selector(hitTest:withEvent:), (IMP)hook_WindowHitTest, (IMP *)&gOrig_WindowHitTest);
    SwizzleInstanceMethod(winCls, @selector(makeKeyAndVisible), (IMP)hook_WindowMakeKeyAndVisible, (IMP *)&gOrig_WindowMakeKeyAndVisible);

    // Setup hooks on scene and app active
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        setupFloatingButton();
        installDuolingoHooks();
    }];

    // Multiple delayed fail-safe attempts
    double delays[] = { 0.5, 1.2, 2.5, 4.0, 6.0 };
    for (int i = 0; i < 5; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            setupFloatingButton();
            installDuolingoHooks();
        });
    }
}
