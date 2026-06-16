// mocsd, MOCS (Mac Objectively Correct Shortcuts)

#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h> // kVK_* virtual keycodes
#import <Cocoa/Cocoa.h>

static const int64_t SYNTHETIC_MARKER = 0xC0DECAFE;
static const bool EXPERIMENTAL_CMD2CTRL = true;
static const float AX_MESSAGE_TIMEOUT = 1.0f;
static const CGFloat DRAG_TILE_EDGE_MARGIN = 32.0;
static const CGFloat DRAG_TILE_MIN_DISTANCE = 8.0;

// <IOKit/hidsystem/IOLLEvent.h> as NX_DEVICE* KEYMASK.
static const uint64_t LCTRL_MASK = 0x00000001;
static const uint64_t LSHIFT_MASK = 0x00000002;
static const uint64_t RSHIFT_MASK = 0x00000004;
static const uint64_t LCMD_MASK = 0x00000008;
static const uint64_t RCMD_MASK = 0x00000010;
static const uint64_t LOPT_MASK = 0x00000020;
static const uint64_t ROPT_MASK = 0x00000040;
static const uint64_t RCTRL_MASK = 0x00002000;

static CFMachPortRef tapSrc = NULL;
static CGEventSourceRef eventSrc = NULL;
static dispatch_queue_t winQueue = NULL;

// meta+drag
static bool isDragging = false;
static bool dragDidMove = false;
static AXUIElementRef dragWin = NULL;
static CGPoint dragStartMouse;
static CGPoint dragStartWinPos;

typedef enum {
    DragTileNone = 0,
    DragTileFill,
    DragTileLeft,
    DragTileRight,
} DragTileAction;

static void PostKey(const CGKeyCode k, const CGEventFlags flags) {
    const CGEventRef d = CGEventCreateKeyboardEvent(eventSrc, k, true);
    const CGEventRef u = CGEventCreateKeyboardEvent(eventSrc, k, false);

    CGEventSetFlags(d, flags);
    CGEventSetFlags(u, flags);

    CGEventSetIntegerValueField(d, kCGEventSourceUserData, SYNTHETIC_MARKER);
    CGEventSetIntegerValueField(u, kCGEventSourceUserData, SYNTHETIC_MARKER);

    CGEventPost(kCGHIDEventTap, d);
    CGEventPost(kCGHIDEventTap, u);

    CFRelease(d);
    CFRelease(u);
}

static void SetAXTimeout(const AXUIElementRef el) {
    if (el) {
        AXUIElementSetMessagingTimeout(el, AX_MESSAGE_TIMEOUT);
    }
}

static bool IsAXWindow(const AXUIElementRef el) {
    if (!el) {
        return false;
    }

    CFStringRef role = NULL;
    const AXError err = AXUIElementCopyAttributeValue(el, kAXRoleAttribute, (CFTypeRef* )&role);
    if (err != kAXErrorSuccess || !role) {
        return false;
    }

    const bool isWin = CFStringCompare(role, kAXWindowRole, 0) == kCFCompareEqualTo;
    CFRelease(role);
    return isWin;
}

static bool IsMinimizedWindow(const AXUIElementRef win) {
    CFTypeRef value = NULL;
    const AXError err = AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute, &value);
    if (err != kAXErrorSuccess || !value) {
        return false;
    }

    const bool minimized = (CFGetTypeID(value) == CFBooleanGetTypeID()) && CFBooleanGetValue((CFBooleanRef)value);
    CFRelease(value);
    return minimized;
}

static AXUIElementRef CopyWindowAttribute(const AXUIElementRef app, const CFStringRef attr) {
    AXUIElementRef win = NULL;
    const AXError err = AXUIElementCopyAttributeValue(app, attr, (CFTypeRef* )&win);
    if (err != kAXErrorSuccess || !win) {
        return NULL;
    }

    SetAXTimeout(win);
    if (!IsAXWindow(win)) {
        CFRelease(win);
        return NULL;
    }

    return win;
}

static AXUIElementRef CopyFirstAppWindow(const AXUIElementRef app, const bool allowMinimized) {
    CFArrayRef windows = NULL;
    const AXError err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, (CFTypeRef* )&windows);
    if (err != kAXErrorSuccess || !windows) {
        return NULL;
    }

    if (CFGetTypeID(windows) != CFArrayGetTypeID()) {
        CFRelease(windows);
        return NULL;
    }

    const CFIndex count = CFArrayGetCount(windows);
    for (CFIndex ii = 0; ii < count; ii++) {
        AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(windows, ii);
        if (!win) {
            continue;
        }

        CFRetain(win);
        SetAXTimeout(win);
        if (!IsAXWindow(win)) {
            CFRelease(win);
            continue;
        }

        if (!allowMinimized && IsMinimizedWindow(win)) {
            CFRelease(win);
            continue;
        }

        CFRelease(windows);
        return win;
    }

    CFRelease(windows);
    return NULL;
}

static AXUIElementRef FocusedWindow() {
    const AXUIElementRef sw = AXUIElementCreateSystemWide();
    SetAXTimeout(sw);

    AXUIElementRef app = NULL;
    const AXError err = AXUIElementCopyAttributeValue(sw, kAXFocusedApplicationAttribute, (CFTypeRef* )&app);
    CFRelease(sw);
    if (err != kAXErrorSuccess || !app) {
        return NULL;
    }

    SetAXTimeout(app);

    AXUIElementRef win = CopyWindowAttribute(app, kAXFocusedWindowAttribute);
    if (!win) {
        win = CopyWindowAttribute(app, kAXMainWindowAttribute);
    }
    if (!win) {
        win = CopyFirstAppWindow(app, false);
    }
    if (!win) {
        win = CopyFirstAppWindow(app, true);
    }

    CFRelease(app);
    return win;
}

static bool GetWinFrame(const AXUIElementRef win, CGRect* const out) {
    if (!win || !out) {
        return false;
    }

    SetAXTimeout(win);

    AXValueRef pv = NULL;
    AXValueRef sv = NULL;
    if (AXUIElementCopyAttributeValue(win, kAXPositionAttribute, (CFTypeRef* )&pv) != kAXErrorSuccess) {
        return false;
    }

    if (AXUIElementCopyAttributeValue(win, kAXSizeAttribute, (CFTypeRef* )&sv) != kAXErrorSuccess) {
        CFRelease(pv);
        return false;
    }

    CGPoint pp;
    CGSize ss;
    AXValueGetValue(pv, kAXValueTypeCGPoint, &pp);
    AXValueGetValue(sv, kAXValueTypeCGSize, &ss);

    CFRelease(pv);
    CFRelease(sv);

    *out = CGRectMake(pp.x, pp.y, ss.width, ss.height);
    return true;
}

static bool SetWinFrame(const AXUIElementRef win, const CGRect rect) {
    if (!win) {
        return false;
    }

    SetAXTimeout(win);

    AXUIElementSetAttributeValue(win, kAXMinimizedAttribute, kCFBooleanFalse);
    AXUIElementSetAttributeValue(win, CFSTR("AXFullScreen"), kCFBooleanFalse);
    AXUIElementPerformAction(win, kAXRaiseAction);

    const CGPoint pp = rect.origin;
    const CGSize s = rect.size;

    const AXValueRef pv = AXValueCreate(kAXValueTypeCGPoint, &pp);
    const AXValueRef sv = AXValueCreate(kAXValueTypeCGSize, &s);

    const AXError sizeErr1 = AXUIElementSetAttributeValue(win, kAXSizeAttribute, sv);
    const AXError posErr = AXUIElementSetAttributeValue(win, kAXPositionAttribute, pv);
    const AXError sizeErr2 = AXUIElementSetAttributeValue(win, kAXSizeAttribute, sv);

    CFRelease(pv);
    CFRelease(sv);

    return posErr == kAXErrorSuccess && (sizeErr1 == kAXErrorSuccess || sizeErr2 == kAXErrorSuccess);
}

static CGRect AxFullFrameForScreen(NSScreen* const screen) {
    const NSRect frame = [screen frame];
    const CGFloat ph = NSMaxY([[NSScreen screens][0] frame]);

    return CGRectMake(frame.origin.x, ph - (frame.origin.y + frame.size.height), frame.size.width, frame.size.height);
}

static CGRect AxFrameForScreen(NSScreen* const screen) {
    const NSRect vis = [screen visibleFrame];
    const CGFloat ph = NSMaxY([[NSScreen screens][0] frame]);

    return CGRectMake(vis.origin.x, ph - (vis.origin.y + vis.size.height), vis.size.width, vis.size.height);
}

static NSPoint NSPointFromAXPoint(const CGPoint point) {
    const CGFloat ph = NSMaxY([[NSScreen screens][0] frame]);
    return NSMakePoint(point.x, ph - point.y);
}

static CGFloat DistanceToRect(const NSPoint point, const NSRect rect) {
    const CGFloat dx = (point.x < NSMinX(rect)) ? NSMinX(rect) - point.x : ((point.x > NSMaxX(rect)) ? point.x - NSMaxX(rect) : 0.0);
    const CGFloat dy = (point.y < NSMinY(rect)) ? NSMinY(rect) - point.y : ((point.y > NSMaxY(rect)) ? point.y - NSMaxY(rect) : 0.0);
    return dx*dx + dy*dy;
}

static NSScreen* ScreenForPoint(const CGPoint point) {
    const NSPoint ns = NSPointFromAXPoint(point);
    NSScreen* best = [NSScreen mainScreen];
    CGFloat bestDist = CGFLOAT_MAX;

    for (NSScreen* screen in [NSScreen screens]) {
        const NSRect frame = [screen frame];
        if (NSPointInRect(ns, frame)) {
            return screen;
        }

        const CGFloat dist = DistanceToRect(ns, frame);
        if (dist < bestDist) {
            best = screen;
            bestDist = dist;
        }
    }

    return best;
}

static NSScreen* ScreenForWindow(const AXUIElementRef win) {
    CGRect rect;
    if (!GetWinFrame(win, &rect)) {
        return [NSScreen mainScreen];
    }

    return ScreenForPoint(CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect)));
}

static CGRect DefaultFrameForScreen(NSScreen* const screen) {
    const CGRect sf = AxFrameForScreen(screen);
    const CGFloat w = floor(sf.size.width*  0.6);
    const CGFloat h = floor(sf.size.height*  0.7);

    return CGRectMake(sf.origin.x + floor((sf.size.width - w) / 2.0), sf.origin.y + floor((sf.size.height - h) / 2.0), w, h);
}

static bool IsFilled(const AXUIElementRef win) {
    CGRect rect;
    if (!GetWinFrame(win, &rect)) {
        return false;
    }

    const CGRect sf = AxFrameForScreen(ScreenForWindow(win));
    return fabs(rect.origin.y - sf.origin.y) < 20 && fabs(rect.size.height - sf.size.height) < 20;
}

static CGRect TileFrameForScreen(NSScreen* const screen, const CGFloat fracX, const CGFloat fracW) {
    CGRect rect = AxFrameForScreen(screen);
    const CGFloat newW = floor(rect.size.width*  fracW);

    rect.origin.x += floor(rect.size.width*  fracX);
    rect.size.width = newW;

    return rect;
}

static DragTileAction DragTileActionForPoint(const CGPoint point, NSScreen** const outScreen) {
    NSScreen* const screen = ScreenForPoint(point);
    if (outScreen) {
        *outScreen = screen;
    }

    const CGRect full = AxFullFrameForScreen(screen);
    const CGRect vis = AxFrameForScreen(screen);
    const CGFloat margin = DRAG_TILE_EDGE_MARGIN;

    const bool nearTop = point.y <= CGRectGetMinY(full) + margin || point.y <= CGRectGetMinY(vis) + margin;
    const bool nearLeft = point.x <= CGRectGetMinX(full) + margin || point.x <= CGRectGetMinX(vis) + margin;
    const bool nearRight = point.x >= CGRectGetMaxX(full) - margin || point.x >= CGRectGetMaxX(vis) - margin;

    if (nearTop) {
        return DragTileFill;
    }
    if (nearLeft) {
        return DragTileLeft;
    }
    if (nearRight) {
        return DragTileRight;
    }

    return DragTileNone;
}

static CGRect DragTileFrameForScreen(NSScreen* const screen, const DragTileAction action) {
    switch (action) {
        case DragTileFill:
            return AxFrameForScreen(screen);
        case DragTileLeft:
            return TileFrameForScreen(screen, 0.0, 0.5);
        case DragTileRight:
            return TileFrameForScreen(screen, 0.5, 0.5);
        case DragTileNone:
            return CGRectZero;
    }

    return CGRectZero;
}

static void TileTo(const CGFloat fracX, const CGFloat fracW) {
    const AXUIElementRef win = FocusedWindow();
    if (!win) {
        return;
    }

    SetWinFrame(win, TileFrameForScreen(ScreenForWindow(win), fracX, fracW));
    CFRelease(win);
}


static void Maximize() {
    const AXUIElementRef win = FocusedWindow();
    if (!win) {
        return;
    }

    SetWinFrame(win, AxFrameForScreen(ScreenForWindow(win)));
    CFRelease(win);
}


static void RestoreOrMinimize() {
    const AXUIElementRef win = FocusedWindow();
    if (!win) {
        return;
    }

    if (IsFilled(win)) {
        SetWinFrame(win, DefaultFrameForScreen(ScreenForWindow(win)));
    } else {
        AXUIElementSetAttributeValue(win, kAXMinimizedAttribute, kCFBooleanTrue);
    }

    CFRelease(win);
}

static AXUIElementRef WindowAtPoint(const CGPoint point) {
    const AXUIElementRef sw = AXUIElementCreateSystemWide();
    SetAXTimeout(sw);

    AXUIElementRef el = NULL;
    AXUIElementCopyElementAtPosition(sw, (float)point.x, (float)point.y, &el);
    CFRelease(sw);
    if (!el) {
        return NULL;
    }

    SetAXTimeout(el);
    AXUIElementRef cur = el;
    CFRetain(cur);
    while (cur) {
        CFStringRef role = NULL;
        if (AXUIElementCopyAttributeValue(cur, kAXRoleAttribute, (CFTypeRef* )&role) == kAXErrorSuccess && role) {
            const bool isWin = CFStringCompare(role, kAXWindowRole, 0) == kCFCompareEqualTo;
            CFRelease(role);

            if (isWin) {
                CFRelease(el);
                return cur;
            }
        }

        AXUIElementRef parent = NULL;
        AXUIElementCopyAttributeValue(cur, kAXParentAttribute, (CFTypeRef* )&parent);
        SetAXTimeout(parent);
        CFRelease(cur);
        cur = parent;
    }

    CFRelease(el);
    return NULL;
}

// resolve the positions of dock pinned apps
static NSString* dockSlotBundle(const int idx) {
    CFPreferencesAppSynchronize(CFSTR("com.apple.dock"));
    const CFPropertyListRef plist = CFPreferencesCopyAppValue(CFSTR("persistent-apps"), CFSTR("com.apple.dock"));
    if (!plist) {
        return nil;
    }

    if (CFGetTypeID(plist) != CFArrayGetTypeID()) {
        CFRelease(plist);
        return nil;
    }

    NSArray* const apps = (__bridge_transfer NSArray* )plist;
    if (idx < 0 || (NSUInteger)idx >= apps.count) {
        return nil;
    }

    NSDictionary* const entry = apps[idx];
    if (![entry isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSDictionary* const tile = entry[@"tile-data"];
    if (![tile isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSString* const bundle = tile[@"bundle-identifier"];
    if (![bundle isKindOfClass:[NSString class]]) {
        return nil;
    }

    return bundle;
}

static int DigitFromKeycode(const CGKeyCode kc) {
    switch (kc) {
        case kVK_ANSI_0:
            return 0;
        case kVK_ANSI_1:
            return 1;
        case kVK_ANSI_2:
            return 2;
        case kVK_ANSI_3:
            return 3;
        case kVK_ANSI_4:
            return 4;
        case kVK_ANSI_5:
            return 5;
        case kVK_ANSI_6:
            return 6;
        case kVK_ANSI_7:
            return 7;
        case kVK_ANSI_8:
            return 8;
        case kVK_ANSI_9:
            return 9;
    }

  return -1;
}

static void launchBundle(NSString* const bundleID) {
    NSWorkspace* const ws = [NSWorkspace sharedWorkspace];
    NSURL* const url = [ws URLForApplicationWithBundleIdentifier:bundleID];
    if (!url) {
        return;
    }

    NSWorkspaceOpenConfiguration* const cfg = [NSWorkspaceOpenConfiguration configuration];
    cfg.activates = YES;

    [ws openApplicationAtURL:url configuration:cfg completionHandler:nil];
}

//  event tap handler
static CGEventRef Handler(const CGEventTapProxy proxy, const CGEventType type, const CGEventRef event, void* const refcon) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        CGEventTapEnable(tapSrc, true);
        return event;
    }

    // ignore own
    if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) == SYNTHETIC_MARKER) {
        return event;
    }

    const CGEventFlags flags = CGEventGetFlags(event);
    const bool ctrl = flags & kCGEventFlagMaskControl;
    const bool cmd = flags & kCGEventFlagMaskCommand;
    const bool opt = flags & kCGEventFlagMaskAlternate;
    const bool shift = flags & kCGEventFlagMaskShift;
    const bool lcmd = flags & LCMD_MASK;
    const bool rcmd = flags & RCMD_MASK;

    // meta + mouse drag
    if (type == kCGEventLeftMouseDown && opt && !isDragging) {
        const CGPoint loc = CGEventGetLocation(event);
        const AXUIElementRef win = WindowAtPoint(loc);

        if (win) {
            CGRect rect;
            if (GetWinFrame(win, &rect)) {
                if (IsFilled(win)) {
                    CGRect def = DefaultFrameForScreen(ScreenForWindow(win));

                    const CGFloat fx = (rect.size.width > 0) ? (loc.x - rect.origin.x) / rect.size.width : 0.5;
                    def.origin.x = loc.x - floor(fx*  def.size.width);
                    def.origin.y = loc.y - 10;

                    SetWinFrame(win, def);
                    rect = def;
                }

                isDragging = true;
                dragDidMove = false;
                dragWin = win;
                dragStartMouse = loc;
                dragStartWinPos = rect.origin;

                return NULL;
            }

            CFRelease(win);
        }
    }

    if (isDragging) {
        if (type == kCGEventLeftMouseDragged) {
            const CGPoint loc = CGEventGetLocation(event);
            const CGFloat dx = loc.x - dragStartMouse.x;
            const CGFloat dy = loc.y - dragStartMouse.y;

            if ((dx*  dx + dy*  dy) >= (DRAG_TILE_MIN_DISTANCE*  DRAG_TILE_MIN_DISTANCE)) {
                dragDidMove = true;
            }

            const CGPoint pp = CGPointMake(dragStartWinPos.x + dx, dragStartWinPos.y + dy);
            const AXValueRef pv = AXValueCreate(kAXValueTypeCGPoint, &pp);
            AXUIElementSetAttributeValue(dragWin, kAXPositionAttribute, pv);
            CFRelease(pv);

            return NULL;
        }

        if (type == kCGEventLeftMouseUp) {
            const CGPoint loc = CGEventGetLocation(event);
            const CGFloat dx = loc.x - dragStartMouse.x;
            const CGFloat dy = loc.y - dragStartMouse.y;
            const bool shouldTile = dragDidMove || (dx*dx + dy*dy) >= (DRAG_TILE_MIN_DISTANCE*DRAG_TILE_MIN_DISTANCE);
            AXUIElementRef win = dragWin;

            isDragging = false;
            dragDidMove = false;
            dragWin = NULL;

            if (shouldTile && win) {
                NSScreen* screen = nil;
                const DragTileAction tileAction = DragTileActionForPoint(loc, &screen);
                if (tileAction != DragTileNone) {
                    const CGRect target = DragTileFrameForScreen(screen, tileAction);
                    dispatch_async(winQueue, ^{ @autoreleasepool {
                        SetWinFrame(win, target);
                        CFRelease(win);
                    } });
                } else {
                    CFRelease(win);
                }
            } else if (win) {
                CFRelease(win);
            }

            return NULL;
        }
    }

    // ctrl + left-click
    if (ctrl && !cmd && !opt && (type == kCGEventLeftMouseDown || type == kCGEventLeftMouseUp || type == kCGEventLeftMouseDragged)) {
        const CGEventFlags base = flags & ~kCGEventFlagMaskControl & ~LCTRL_MASK & ~RCTRL_MASK;
        CGEventSetFlags(event, base | kCGEventFlagMaskCommand | LCMD_MASK);

        return event;
    }

    if (type != kCGEventKeyDown && type != kCGEventKeyUp) {
        return event;
    }

    const CGKeyCode kc = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    const bool down = (type == kCGEventKeyDown);
    const bool repeat = down && CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) != 0;

    // right-cmd alone -> AltGr
    if (rcmd && !lcmd && !ctrl && !opt) {
        struct Xlate {
            CGKeyCode src, dst;
            bool shift;
        };

        static const struct Xlate kAltGrTable[] = {
            {kVK_ANSI_7, kVK_ANSI_8, false},      // { Opt+8
            {kVK_ANSI_8, kVK_ANSI_8, true},       // [ Opt+Shift+8
            {kVK_ANSI_9, kVK_ANSI_9, true},       // ] Opt+Shift+9
            {kVK_ANSI_0, kVK_ANSI_9, false},      // } Opt+9
            {kVK_ANSI_Minus, kVK_ANSI_7, true},   // '\' (+ key) Opt+Shift+7
            {kVK_ISO_Section, kVK_ANSI_7, false}, // | (< key)  Opt+7
        };

        const bool shiftHeld = flags & kCGEventFlagMaskShift;
        // only translate when shift isn't held
        if (!shiftHeld) {
            for (size_t ii = 0; ii < sizeof(kAltGrTable) / sizeof(kAltGrTable[0]); ii++) {
                if (kc == kAltGrTable[ii].src) {
                    CGEventFlags ff = (flags & ~kCGEventFlagMaskCommand & ~LCMD_MASK & ~RCMD_MASK) | kCGEventFlagMaskAlternate | LOPT_MASK;
                    if (kAltGrTable[ii].shift) {
                        ff |= kCGEventFlagMaskShift | LSHIFT_MASK;
                    }

                    CGEventSetIntegerValueField(event, kCGKeyboardEventKeycode, kAltGrTable[ii].dst);
                    CGEventSetFlags(event, ff);
                    
                    return event;
                }
            }
        }

        // native option behavior, fallback
        const CGEventFlags base = (flags & ~kCGEventFlagMaskCommand & ~LCMD_MASK & ~RCMD_MASK) | kCGEventFlagMaskAlternate | LOPT_MASK;
        CGEventSetFlags(event, base);

        return event;
    }

    // ctrl-based shortcuts
    if (ctrl && !cmd && !opt) {
        const CGEventFlags noCtrl = flags & ~kCGEventFlagMaskControl & ~LCTRL_MASK & ~RCTRL_MASK;
        switch (kc) {
            case kVK_ANSI_T:
            case kVK_ANSI_W:
            case kVK_ANSI_X:
            case kVK_ANSI_C:
            case kVK_ANSI_V:
            case kVK_ANSI_Z:
            case kVK_ANSI_Y:
            case kVK_ANSI_O:
            case kVK_ANSI_A:
            case kVK_ANSI_S:
            case kVK_ANSI_L:
            case kVK_ANSI_F: // find
            case kVK_ANSI_R: // reload
            case kVK_ANSI_N: // new window
            case kVK_ANSI_P: // print
            case kVK_ANSI_Equal:
            case kVK_ANSI_Minus: // zoom in / out (US)
            case kVK_ANSI_Slash: // zoom out (FIN)
            case kVK_ANSI_0: // reset zoom
                CGEventSetFlags(event, noCtrl | kCGEventFlagMaskCommand | LCMD_MASK);
                return event;
            // word-jump
            case kVK_LeftArrow:
            case kVK_RightArrow:
            case kVK_Delete:
                CGEventSetFlags(event, noCtrl | kCGEventFlagMaskAlternate | LOPT_MASK);
                return event;
            case kVK_Tab:
                return event;
        }

        if (EXPERIMENTAL_CMD2CTRL) {
            CGEventSetFlags(event, noCtrl | kCGEventFlagMaskCommand | LCMD_MASK);
            return event;
        }
    }

    // ctrl+Alt+arrow
    if (ctrl && opt && !cmd && (kc == kVK_LeftArrow || kc == kVK_RightArrow)) {
        const CGEventFlags base = flags & ~kCGEventFlagMaskControl & ~LCTRL_MASK & ~RCTRL_MASK & ~kCGEventFlagMaskAlternate & ~LOPT_MASK & ~ROPT_MASK;
        CGEventSetFlags(event, base | kCGEventFlagMaskCommand | LCMD_MASK);

        return event;
    }

    // cmd+§, spotlight
    if (cmd && !ctrl && !opt && kc == kVK_ISO_Section) {
        CGEventSetIntegerValueField(event, kCGKeyboardEventKeycode, kVK_Space);

        return event;
    }

    // meta+Q
    if (opt && !ctrl && !cmd && !shift && kc == kVK_ANSI_Q) {
        const CGEventFlags base = flags & ~kCGEventFlagMaskAlternate & ~LOPT_MASK & ~ROPT_MASK;
        CGEventSetFlags(event, base | kCGEventFlagMaskCommand | LCMD_MASK);

        return event;
    }

    // meta + window actions
    if (opt && !ctrl && !cmd && !shift) {
        switch (kc) {
            case kVK_UpArrow:
                if (down && !repeat) {
                    dispatch_async(winQueue, ^{ @autoreleasepool { Maximize(); } });
                }
                return NULL;
            case kVK_DownArrow:
                if (down && !repeat) {
                    dispatch_async(winQueue, ^{ @autoreleasepool { RestoreOrMinimize(); } });
                }
                return NULL;
            case kVK_LeftArrow:
                if (down && !repeat) {
                    dispatch_async(winQueue, ^{ @autoreleasepool { TileTo(0.0, 0.5); } });
                }
                return NULL;
            case kVK_RightArrow:
                if (down && !repeat) {
                    dispatch_async(winQueue, ^{ @autoreleasepool { TileTo(0.5, 0.5); } });
                }
                return NULL;
            case kVK_ANSI_E:
                if (down) {
                    launchBundle(@"com.apple.finder");
                }
                return NULL;
            case kVK_ANSI_T:
                if (down) {
                    launchBundle(@"com.apple.Terminal");
                }
                return NULL;
        }

        // meta+N dock launchers
        const int num = DigitFromKeycode(kc);
        if (num >= 0) {
            if (!down) {
                return NULL;
            }

            const int idx = (num == 0) ? 9 : num - 1;
            NSString* const bundle = dockSlotBundle(idx);
            
            if (bundle) {
                launchBundle(bundle);
            } else {
                NSLog(@"mocsd: dock slot %d empty", num);
            }

            return NULL;
        }
    }

    // meta+shift
    if (opt && shift && !ctrl && !cmd) {
        // rectangle screenshot to clipboard
        if (kc == kVK_ANSI_S) {
            if (down) {
                PostKey(kVK_ANSI_4, kCGEventFlagMaskCommand | kCGEventFlagMaskControl | kCGEventFlagMaskShift);
            }

            return NULL;
        }
        
        // desktop switch, ctrl+shift+arrow
        if (kc == kVK_LeftArrow || kc == kVK_RightArrow) {
            const CGEventFlags base = flags & ~kCGEventFlagMaskAlternate & ~LOPT_MASK & ~ROPT_MASK & ~kCGEventFlagMaskShift & ~LSHIFT_MASK & ~RSHIFT_MASK;
            CGEventSetFlags(event, base | kCGEventFlagMaskControl | LCTRL_MASK);

            return event;
        }
    }

    return event;
}

int main(const int argc, char* * const argv) {
    @autoreleasepool {
        // ask perms
        (void)AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef) @{(__bridge id)kAXTrustedCheckOptionPrompt : @YES});

        while (!AXIsProcessTrusted()) {
            NSLog(@"mocsd: waiting for permission");
            sleep(3);
        }

        eventSrc = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
        winQueue = dispatch_queue_create("mocsd.window", DISPATCH_QUEUE_SERIAL);

        const CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) | CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp) | CGEventMaskBit(kCGEventLeftMouseDragged);

        tapSrc = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask, Handler, NULL);
        if (!tapSrc) {
            NSLog(@"mocsd: failed to create event tap (check Accessibility perm)");
            return 1;
        }
        
        const CFRunLoopSourceRef rls = CFMachPortCreateRunLoopSource(NULL, tapSrc, 0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), rls, kCFRunLoopCommonModes);
        CGEventTapEnable(tapSrc, true);
        NSLog(@"mocs: running");
        
        CFRunLoopRun();
    }

    return 0;
}
