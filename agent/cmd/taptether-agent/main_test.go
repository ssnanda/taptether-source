package main

import "testing"

func TestLANRestrictions(t *testing.T) {
	cases := map[string]bool{"192.168.1.11:3000": true, "10.0.0.1:80": true, "127.0.0.1:443": true, "8.8.8.8:443": false, "1.1.1.1:80": false, "garbage": false}
	for s, want := range cases {
		if got := privateRemote(s); got != want {
			t.Errorf("%s=%v; want %v", s, got, want)
		}
	}
}
