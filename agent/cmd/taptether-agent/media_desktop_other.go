//go:build !linux

package main

import "errors"

func linuxDesktopBrowser(_ string) error {
    return errors.New("Linux desktop browser unavailable on this OS")
}
