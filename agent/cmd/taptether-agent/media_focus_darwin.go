//go:build darwin && cgo

package main

/*
#cgo LDFLAGS: -framework CoreServices
#include <CoreServices/CoreServices.h>
#include <stdlib.h>
#include <string.h>

// LaunchServices supplies the user's existing HTTPS default browser. We
// activate its app *without providing a URL*, so macOS does not open a tab.
static char *tt_default_https_browser(void) {
    CFStringRef name = LSCopyDefaultHandlerForURLScheme(CFSTR("https"));
    if (name == NULL) return NULL;
    char buf[256];
    Boolean ok = CFStringGetCString(name, buf, sizeof(buf), kCFStringEncodingUTF8);
    CFRelease(name);
    if (!ok || buf[0] == '\0') return NULL;
    return strdup(buf);
}
*/
import "C"

import (
    "errors"
    "os/exec"
    "strings"
    "unsafe"
)

func focusMediaBrowser() error {
    bundle := C.tt_default_https_browser()
    if bundle == nil {
        return errors.New("macOS default HTTPS browser is not configured")
    }
    defer C.free(unsafe.Pointer(bundle))
    name := C.GoString(bundle)
    if !strings.HasPrefix(name, "com.") && !strings.HasPrefix(name, "org.") {
        return errors.New("unexpected default browser identifier")
    }
    // Activates the existing browser window, including restored Firefox tabs.
    // The phone then navigates the foreground tab through Cmd+L. This
    // intentionally does not enumerate private browser tabs or read history.
    return exec.Command("/usr/bin/open", "-b", name).Run()
}
