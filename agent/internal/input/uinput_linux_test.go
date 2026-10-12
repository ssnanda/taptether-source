//go:build linux

package input

import "testing"

func TestASCIIKeyMap(t *testing.T) {
	cases := []struct {
		ch    rune
		code  int
		shift bool
		ok    bool
	}{
		{'a', 30, false, true}, {'A', 30, true, true}, {'1', 2, false, true}, {'!', 2, true, true},
		{' ', 57, false, true}, {'\n', 28, false, true}, {'?', 53, true, true}, {'é', 0, false, false},
	}
	for _, tt := range cases {
		code, shift, ok := asciiKey(tt.ch)
		if code != tt.code || shift != tt.shift || ok != tt.ok {
			t.Errorf("asciiKey(%q)=(%d,%t,%t)", tt.ch, code, shift, ok)
		}
	}
}
func TestKeyChords(t *testing.T) {
	tests := []struct {
		input string
		want  []int
	}{
		{"ctrl+c", []int{29, 46}}, {"alt+Tab", []int{56, 15}},
		{"XF86AudioRaiseVolume", []int{115}}, {"XF86AudioLowerVolume", []int{114}},
		{"XF86AudioMute", []int{113}},
	}
	for _, tt := range tests {
		got, err := parseChord(tt.input)
		if err != nil || len(got) != len(tt.want) {
			t.Errorf("parseChord(%q): %v %v", tt.input, got, err)
			continue
		}
		for i, k := range got {
			if k != tt.want[i] {
				t.Errorf("parseChord(%q) [%d]=%d, want %d", tt.input, i, k, tt.want[i])
			}
		}
	}
	for _, bad := range []string{"unknown", "ctrl+", "ctrl+alt+shift+meta+x"} {
		if _, err := parseChord(bad); err == nil {
			t.Errorf("wanted error for %q", bad)
		}
	}
}
func TestVirtualDeviceLayout(t *testing.T) {
	// CI has no physical /dev/uinput. Validate ioctl ABI via sizeof in build test.
	if got := uinputSetupSize(); got != 92 {
		t.Fatalf("uinput_setup size=%d want=92", got)
	}
}
