//go:build darwin && !cgo

package input

import "errors"

func tapViaInputCore(Event) error {
    return errors.New("macOS absolute preview taps require the cgo-enabled agent")
}
