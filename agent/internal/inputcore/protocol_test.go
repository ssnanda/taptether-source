package inputcore

import (
	"encoding/json"
	"testing"

	"github.com/ssnanda/taptether.com/agent/internal/input"
)

func TestProtocolDoesNotAuthorizeWithoutToken(t *testing.T) {
	encoded, err := json.Marshal(Request{Protocol: ProtocolVersion, Event: input.Event{Type: "click", Button: "left"}})
	if err != nil {
		t.Fatal(err)
	}
	var decoded Request
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.Token != "" {
		t.Fatal("unexpected authorization token")
	}
	if decoded.Protocol != ProtocolVersion {
		t.Fatal("protocol version lost")
	}
}

func TestInputCommandValidationAtIPCBoundary(t *testing.T) {
	invalid := []input.Event{
		{Type: "move", DX: 301},
		{Type: "click", Button: "middle"},
		{Type: "shell"},
	}
	for _, event := range invalid {
		if err := event.Validate(); err == nil {
			t.Fatalf("accepted invalid command: %#v", event)
		}
	}
}
