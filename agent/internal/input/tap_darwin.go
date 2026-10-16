//go:build darwin && cgo

package input

/*
#cgo LDFLAGS: -framework ApplicationServices
#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>
#include <math.h>

// Read-only pointer inspection; mouse injection remains in protected Input
// Core, so existing installations retain their Accessibility grants.
static bool tt_tap_delta(int x, int y, int *dx, int *dy) {
  CGEventRef event = CGEventCreate(NULL);
  if (!event) return false;
  CGPoint current = CGEventGetLocation(event);
  CFRelease(event);
  CGRect bounds = CGDisplayBounds(CGMainDisplayID());
  if (bounds.size.width <= 0 || bounds.size.height <= 0) return false;
  CGPoint target = CGPointMake(bounds.origin.x + bounds.size.width * ((double)x/10000.0),
                               bounds.origin.y + bounds.size.height * ((double)y/10000.0));
  *dx = (int)round(target.x - current.x);
  *dy = (int)round(target.y - current.y);
  return true;
}
*/
import "C"

import "errors"

// Existing Input Core version 1 already supports relative move and click.
// Normal agent updates must not replace its separately approved executable.
func tapViaInputCore(event Event) error {
    var dx, dy C.int
    if !bool(C.tt_tap_delta(C.int(event.X), C.int(event.Y), &dx, &dy)) {
        return errors.New("unable to locate macOS primary display cursor")
    }
    remainingX, remainingY := int(dx), int(dy)
    for remainingX != 0 || remainingY != 0 {
        stepX, stepY := remainingX, remainingY
        if stepX > 300 { stepX = 300 }
        if stepX < -300 { stepX = -300 }
        if stepY > 300 { stepY = 300 }
        if stepY < -300 { stepY = -300 }
        if err := Send(Event{Type:"move", DX:stepX, DY:stepY}); err != nil { return err }
        remainingX -= stepX
        remainingY -= stepY
    }
    return Send(Event{Type:"click", Button:event.Button})
}
