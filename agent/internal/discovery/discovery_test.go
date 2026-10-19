package discovery

import (
    "encoding/json"
    "net"
    "testing"
)

func TestAnnouncementsHaveNoSecrets(t *testing.T) {
    payload,err:=MakeAnnouncement("my-ubuntu","0.5.0+12",48321)
    if err!=nil { t.Fatal(err) }
    var a Announcement
    if err:=json.Unmarshal(payload,&a);err!=nil {t.Fatal(err)}
    if a.Name!="my-ubuntu" || a.Port!=48321 || a.Protocol!=1 {
        t.Fatalf("unexpected announcement: %+v",a)
    }
    var raw map[string]any
    _=json.Unmarshal(payload,&raw)
    for _,secret:=range []string{"token","fingerprint","key","secret"} {
        if _,ok:=raw[secret];ok {t.Fatalf("discovery must not contain %s",secret)}
    }
}

func TestAcceptProbeLANOnly(t *testing.T) {
    for _,tc:=range []struct{ip string; probe string; want bool}{
        {"192.168.1.12",Probe,true},
        {"10.1.2.3",Probe,true},
        {"8.8.8.8",Probe,false},
        {"192.168.1.12","other",false},
    }{
        got:=AcceptProbe([]byte(tc.probe),&net.UDPAddr{IP:net.ParseIP(tc.ip),Port:5555})
        if got!=tc.want {t.Errorf("%s got %v want %v",tc.ip,got,tc.want)}
    }
}

func TestChangeDetectionOnlyWhenIPActuallyChanges(t *testing.T) {
    original := []string{"192.168.68.87"}
    if changedAddresses(original, original) {
        t.Fatal("stable IP should never trigger a broadcast")
    }
    if !changedAddresses(original, []string{"192.168.68.112"}) {
        t.Fatal("DHCP address change must trigger recovery broadcast")
    }
    if !changedAddresses(original, nil) {
        t.Fatal("interface loss should be detected, but no broadcast sent offline")
    }
}
