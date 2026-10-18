//go:build !darwin || !cgo

package main

// On non-Mac desktops the browser must already be focused by the user.
// Never invoke an OS URL opener just to focus: it commonly adds a new tab.
func focusMediaBrowser() error { return nil }
