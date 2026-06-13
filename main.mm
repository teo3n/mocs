// mocsd, MOCS (Mac Objectively Correct Shortcuts)

#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h> // kVK_* virtual keycodes
#import <Cocoa/Cocoa.h>

static const int64_t SYNTHETIC_MARKER = 0xC0DECAFE;

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

// meta+drag
static bool isDragging = false;
static AXUIElementRef dragWin = NULL;
static CGPoint dragStartMouse;
static CGPoint dragStartWinPos;

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

static AXUIElementRef FocusedWindow() {
    const AXUIElementRef sw = AXUIElementCreateSystemWide();
    AXUIElementRef app = NULL;
    const AXError err = AXUIElementCopyAttributeValue(sw, kAXFocusedApplicationAttribute, (CFTypeRef* )&app);
    CFRelease(sw);
    if (err != kAXErrorSuccess || !app) {
        return NULL;
    }

    AXUIElementRef win = NULL;
    AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, (CFTypeRef* )&win);
    CFRelease(app);

    return win;
}

static bool GetWinFrame(const AXUIElementRef win, CGRect* const out) {
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

static void SetWinFrame(const AXUIElementRef win, const CGRect rect) {
    const CGPoint pp = rect.origin;
    const CGSize s = rect.size;

    const AXValueRef pv = AXValueCreate(kAXValueTypeCGPoint, &pp);
    const AXValueRef sv = AXValueCreate(kAXValueTypeCGSize, &s);

    AXUIElementSetAttributeValue(win, kAXPositionAttribute, pv);
    AXUIElementSetAttributeValue(win, kAXSizeAttribute, sv);

    CFRelease(pv);
    CFRelease(sv);
}

static CGRect AxFrameForScreen(NSScreen* const screen) {
    const NSRect vis = [screen visibleFrame];
    const CGFloat ph = NSMaxY([[NSScreen screens][0] frame]);

    return CGRectMake(vis.origin.x, ph - (vis.origin.y + vis.size.height), vis.size.width, vis.size.height);
}

static NSScreen* ScreenForWindow(const AXUIElementRef win) {
    CGRect rect;
    if (!GetWinFrame(win, &rect)) {
        return [NSScreen mainScreen];
    }

    const CGPoint point = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
    const CGFloat ph = NSMaxY([[NSScreen screens][0] frame]);
    const NSPoint ns = NSMakePoint(point.x, ph - point.y);

    for (NSScreen* screen in [NSScreen screens]) {
        if (NSPointInRect(ns, [screen frame])) {
            return screen;
        }
    }

    return [NSScreen mainScreen];
}

static void TileTo(const CGFloat fracX, const CGFloat fracW) {
    const AXUIElementRef win = FocusedWindow();
    if (!win) {
        return;
    }

    CGRect rect = AxFrameForScreen(ScreenForWindow(win));
    const CGFloat newW = floor(rect.size.width*  fracW);

    rect.origin.x += floor(rect.size.width*  fracX);
    rect.size.width = newW;
    
    SetWinFrame(win, rect);
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


static void Minimize() {
    const AXUIElementRef win = FocusedWindow();
    if (!win) {
        return;
    }

    AXUIElementSetAttributeValue(win, kAXMinimizedAttribute, kCFBooleanTrue);
    CFRelease(win);
}

static AXUIElementRef WindowAtPoint(const CGPoint point) {
    const AXUIElementRef sw = AXUIElementCreateSystemWide();
    AXUIElementRef el = NULL;

    AXUIElementCopyElementAtPosition(sw, (float)point.x, (float)point.y, &el);
    CFRelease(sw);
    if (!el) {
        return NULL;
    }

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
                isDragging = true;
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
            const CGPoint pp = CGPointMake(dragStartWinPos.x + (loc.x - dragStartMouse.x), dragStartWinPos.y + (loc.y - dragStartMouse.y));
            const AXValueRef pv = AXValueCreate(kAXValueTypeCGPoint, &pp);
            AXUIElementSetAttributeValue(dragWin, kAXPositionAttribute, pv);
            CFRelease(pv);

            return NULL;
        }

        if (type == kCGEventLeftMouseUp) {
            isDragging = false;
            CFRelease(dragWin);
            dragWin = NULL;

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
                if (down) {
                    Maximize();
                }
                return NULL;
            case kVK_DownArrow:
                if (down) {
                    Minimize();
                }
                return NULL;
            case kVK_LeftArrow:
                if (down) {
                    TileTo(0.0, 0.5);
                }
                return NULL;
            case kVK_RightArrow:
                if (down) {
                    TileTo(0.5, 0.5);
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