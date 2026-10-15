package inputcore

import "github.com/ssnanda/taptether.com/agent/internal/input"

const ProtocolVersion = 1

type Request struct {
	Protocol int         `json:"protocol"`
	Token    string      `json:"token"`
	Event    input.Event `json:"event"`
}

type Response struct {
	OK      bool   `json:"ok"`
	Error   string `json:"error,omitempty"`
	Version string `json:"version,omitempty"`
	Trusted *bool  `json:"trusted,omitempty"`
}
