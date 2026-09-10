// sblaunch — launch an app on a jailbroken iOS 9 device by bundle identifier
// (what `uiopen <url>` cannot do). Uses the private SpringBoardServices API and
// must be signed with the launchapplications entitlements (see sblaunch.entitlements).
//   usage: sblaunch <bundle-id>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>

extern int SBSLaunchApplicationWithIdentifier(CFStringRef identifier, Boolean suspended);
extern CFStringRef SBSApplicationLaunchingErrorString(int error);

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: sblaunch <bundle-id>\n"); return 1; }
    CFStringRef ident = CFStringCreateWithCString(NULL, argv[1], kCFStringEncodingUTF8);
    int r = SBSLaunchApplicationWithIdentifier(ident, false);
    if (r != 0) {
        char buf[256] = "";
        CFStringRef e = SBSApplicationLaunchingErrorString(r);
        if (e) CFStringGetCString(e, buf, sizeof buf, kCFStringEncodingUTF8);
        fprintf(stderr, "launch failed (%d): %s\n", r, buf);
        return r;
    }
    printf("launched %s\n", argv[1]);
    return 0;
}
