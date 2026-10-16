package input

import "fmt"

type Event struct {
	Type   string `json:"type"`
	DX     int    `json:"dx,omitempty"`
	DY     int    `json:"dy,omitempty"`
	X      int    `json:"x,omitempty"`
	Y      int    `json:"y,omitempty"`
	Button string `json:"button,omitempty"`
	Key    string `json:"key,omitempty"`
	Text   string `json:"text,omitempty"`
}

func (e Event) Validate() error {
	switch e.Type {
	case "ping", "shutdown":
		return nil
	case "move":
		if e.DX < -300 || e.DX > 300 || e.DY < -300 || e.DY > 300 {
			return fmt.Errorf("movement too large")
		}
	case "scroll":
		if e.DY < -100 || e.DY > 100 {
			return fmt.Errorf("scroll too large")
		}
	case "tap":
		if e.X < 0 || e.X > 10000 || e.Y < 0 || e.Y > 10000 {
			return fmt.Errorf("tap coordinates outside primary display")
		}
		if e.Button != "left" && e.Button != "right" && e.Button != "double" {
			return fmt.Errorf("invalid tap button")
		}
	case "click":
		if e.Button != "left" && e.Button != "right" && e.Button != "double" {
			return fmt.Errorf("invalid mouse button")
		}
	case "key":
		if len(e.Key) < 1 || len(e.Key) > 48 {
			return fmt.Errorf("invalid key")
		}
	case "text":
		if len(e.Text) == 0 || len(e.Text) > 256 {
			return fmt.Errorf("text length outside limits")
		}
	default:
		return fmt.Errorf("unknown command type")
	}
	return nil
}
