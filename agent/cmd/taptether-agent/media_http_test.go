package main

import (
    "strings"
    "testing"
)

func TestAllowlistedMediaDestinations(t *testing.T) {
    cases := []struct{ service, query, want string }{
        {"youtube", "cats & dogs", "https://www.youtube.com/results?search_query=cats+%26+dogs"},
        {"netflix", "star wars", "https://www.netflix.com/search?q=star+wars"},
        {"youtube", "", "https://www.youtube.com"},
        {"netflix", "", "https://www.netflix.com"},
    }
    for _, tc := range cases {
        got, err := mediaDestination(tc.service, tc.query)
        if err != nil || got != tc.want { t.Errorf("%q/%q: got %q, %v; want %q",tc.service,tc.query,got,err,tc.want) }
    }
    for _, tc := range []struct{service, query string}{
        {"other","cats"}, {"youtube","hello\nworld"}, {"netflix", strings.Repeat("a",71)},
        {"youtube","\x00"}, {"netflix","hello\rworld"},
    } {
        if _, err := mediaDestination(tc.service, tc.query); err == nil { t.Errorf("accepted unsafe media request: %+v",tc) }
    }
}
