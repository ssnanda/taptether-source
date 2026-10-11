//go:build !linux

package input

import "fmt"

// Cross-platform Go binaries compile now; native input backends are planned.
func Send(e Event) error {
	if e.Type == "ping" {
		return nil
	}
	return fmt.Errorf("input backend for this operating system is not implemented yet")
}
