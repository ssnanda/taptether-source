package power

import "testing"

func TestShutdownDisabledByDefault(t *testing.T) {
    t.Setenv("TAPTETHER_ENABLE_SHUTDOWN", "")
    if Enabled() { t.Fatal("shutdown must be opt-in") }
    if err := RequestShutdown(); err == nil { t.Fatal("disabled shutdown should fail") }
}
