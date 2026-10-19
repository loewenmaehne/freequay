/* macswitch: switches apps the way a user does, but from a program, for tests of how Windows
 * programs behave on Cmd+Tab and in the Dock (minimize-on-deactivate). It posts real key and
 * mouse events, so the program that starts it needs Accessibility in Privacy & Security, and
 * nobody should use the Mac meanwhile.
 *   macswitch idle              seconds since the last keyboard or mouse input
 *   macswitch front             the active app
 *   macswitch info <pid>        an app's state and its windows as macOS sees them
 *   macswitch cmdtab            Cmd+Tab
 *   macswitch click <x> <y>     a click at a point of the screen; the pointer goes back
 *   macswitch dock <text>       a click on the Dock item whose title is the text or whose path
 *                               contains it (every Wine program is called "wine" there)
 * Build: clang -fobjc-arc -framework Cocoa -o macswitch macswitch.m */
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>

static NSString *ax_string(AXUIElementRef el, CFStringRef attr)
{
    CFTypeRef v = NULL;
    NSString *s;

    if (AXUIElementCopyAttributeValue(el, attr, &v) != kAXErrorSuccess || !v) return nil;
    s = [(__bridge id)v isKindOfClass:[NSString class]] ? [(__bridge NSString *)v copy] : [[(__bridge id)v description] copy];
    CFRelease(v);
    return s;
}

static BOOL ax_value(AXUIElementRef el, CFStringRef attr, AXValueType type, void *out)
{
    CFTypeRef v = NULL;
    BOOL ok = AXUIElementCopyAttributeValue(el, attr, &v) == kAXErrorSuccess && v && AXValueGetValue(v, type, out);

    if (v) CFRelease(v);
    return ok;
}

static int ax_bool(AXUIElementRef el, CFStringRef attr)
{
    CFTypeRef v = NULL;
    int r = -1;

    if (AXUIElementCopyAttributeValue(el, attr, &v) == kAXErrorSuccess && v && CFGetTypeID(v) == CFBooleanGetTypeID())
        r = CFBooleanGetValue(v);
    if (v) CFRelease(v);
    return r;
}

static NSArray *ax_array(AXUIElementRef el, CFStringRef attr)
{
    CFTypeRef v = NULL;

    if (AXUIElementCopyAttributeValue(el, attr, &v) != kAXErrorSuccess || !v) return @[];
    return CFBridgingRelease(v);
}

static void post_key(CGKeyCode key, BOOL down, CGEventFlags flags)
{
    CGEventRef e = CGEventCreateKeyboardEvent(NULL, key, down);

    CGEventSetFlags(e, flags);
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
    usleep(30000);
}

static void post_mouse(CGEventType type, CGPoint at)
{
    CGEventRef e = CGEventCreateMouseEvent(NULL, type, at, kCGMouseButtonLeft);

    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
    usleep(40000);
}

static void click(CGPoint at)
{
    CGEventRef now = CGEventCreate(NULL);
    CGPoint back = CGEventGetLocation(now);

    CFRelease(now);
    post_mouse(kCGEventMouseMoved, at);
    usleep(300000);  /* a Dock that hides itself shows up first */
    post_mouse(kCGEventMouseMoved, at);
    post_mouse(kCGEventLeftMouseDown, at);
    post_mouse(kCGEventLeftMouseUp, at);
    usleep(200000);
    post_mouse(kCGEventMouseMoved, back);
    printf("clicked at %.0f,%.0f\n", at.x, at.y);
}

static int dock(NSString *text)
{
    NSRunningApplication *dock = [[NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.dock"] firstObject];
    AXUIElementRef app;
    int ret = 1;

    if (!dock) return 1;
    app = AXUIElementCreateApplication(dock.processIdentifier);
    for (id list in ax_array(app, kAXChildrenAttribute))
    {
        for (id item in ax_array((__bridge AXUIElementRef)list, kAXChildrenAttribute))
        {
            AXUIElementRef el = (__bridge AXUIElementRef)item;
            CGPoint pos;
            CGSize size;

            if (![ax_string(el, kAXTitleAttribute) isEqualToString:text] && ![ax_string(el, kAXURLAttribute) containsString:text])
                continue;
            if (ax_value(el, kAXPositionAttribute, kAXValueCGPointType, &pos) &&
                ax_value(el, kAXSizeAttribute, kAXValueCGSizeType, &size))
            {
                click(CGPointMake(pos.x + size.width / 2, pos.y + size.height / 2));
                ret = 0;
            }
            goto done;
        }
    }
    printf("no Dock item for \"%s\"\n", text.UTF8String);
done:
    CFRelease(app);
    return ret;
}

static void info(pid_t pid)
{
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
    AXUIElementRef ax;

    if (!app)
    {
        printf("no app with pid %d\n", pid);
        return;
    }
    printf("app %s pid %d active=%d hidden=%d\n", app.localizedName.UTF8String, pid, app.active, app.hidden);
    /* the window server's view, including the black shield windows of captured displays */
    for (NSDictionary *w in list)
    {
        CGRect b;

        if ([w[(id)kCGWindowOwnerPID] intValue] != pid) continue;
        CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds], &b);
        printf("  window %d layer %d onscreen=%d %.0fx%.0f@%.0f,%.0f\n", [w[(id)kCGWindowNumber] intValue],
               [w[(id)kCGWindowLayer] intValue], [w[(id)kCGWindowIsOnscreen] boolValue],
               b.size.width, b.size.height, b.origin.x, b.origin.y);
    }
    ax = AXUIElementCreateApplication(pid);
    for (id w in ax_array(ax, kAXWindowsAttribute))
    {
        AXUIElementRef win = (__bridge AXUIElementRef)w;
        CGPoint p = {0};
        CGSize s = {0};

        ax_value(win, kAXPositionAttribute, kAXValueCGPointType, &p);
        ax_value(win, kAXSizeAttribute, kAXValueCGSizeType, &s);
        printf("  \"%s\" minimized=%d main=%d %.0fx%.0f@%.0f,%.0f\n", [ax_string(win, kAXTitleAttribute) ?: @"" UTF8String],
               ax_bool(win, kAXMinimizedAttribute), ax_bool(win, kAXMainAttribute), s.width, s.height, p.x, p.y);
    }
    CFRelease(ax);
}

int main(int argc, char **argv)
{
    @autoreleasepool
    {
        NSString *cmd = argc > 1 ? @(argv[1]) : @"";

        if ([cmd isEqualToString:@"idle"])
            printf("%.1f\n", CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateHIDSystemState, kCGAnyInputEventType));
        else if ([cmd isEqualToString:@"front"])
        {
            NSRunningApplication *f = [[NSWorkspace sharedWorkspace] frontmostApplication];
            printf("%s pid %d\n", f.localizedName.UTF8String, f.processIdentifier);
        }
        else if ([cmd isEqualToString:@"info"] && argc > 2)
            info(atoi(argv[2]));
        else if ([cmd isEqualToString:@"cmdtab"])
        {
            if (!AXIsProcessTrusted()) { fprintf(stderr, "macswitch: no Accessibility\n"); return 1; }
            post_key(55, YES, kCGEventFlagMaskCommand);  /* command */
            post_key(48, YES, kCGEventFlagMaskCommand);  /* tab */
            post_key(48, NO, kCGEventFlagMaskCommand);
            post_key(55, NO, 0);
        }
        else if ([cmd isEqualToString:@"click"] && argc > 3)
            click(CGPointMake(atof(argv[2]), atof(argv[3])));
        else if ([cmd isEqualToString:@"dock"] && argc > 2)
        {
            if (!AXIsProcessTrusted()) { fprintf(stderr, "macswitch: no Accessibility\n"); return 1; }
            return dock(@(argv[2]));
        }
        else
        {
            fprintf(stderr, "usage: macswitch idle|front|info <pid>|cmdtab|click <x> <y>|dock <text>\n");
            return 2;
        }
    }
    return 0;
}
