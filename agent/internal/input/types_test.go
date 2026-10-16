package input

import "testing"

func TestTapCoordinatesAndButtons(t *testing.T) {
    for _, e := range []Event{
        {Type:"tap", X:0, Y:0, Button:"left"},
        {Type:"tap", X:10000, Y:10000, Button:"double"},
        {Type:"tap", X:5000, Y:2000, Button:"right"},
    } {
        if err:=e.Validate(); err!=nil {t.Fatal(err)}
    }
    for _, e := range []Event{
        {Type:"tap", X:-1, Y:200, Button:"left"},
        {Type:"tap", X:10001, Y:0, Button:"right"},
        {Type:"tap", X:300, Y:300, Button:"middle"},
    } {
        if err:=e.Validate(); err==nil {t.Fatalf("expected rejection for %+v",e)}
    }
}
