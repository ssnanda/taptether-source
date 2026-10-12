package identity
import ("crypto/ed25519";"crypto/rand";"encoding/base64";"path/filepath";"testing")
func TestPairAuthReplayAndRevoke(t *testing.T){
 r:=New(filepath.Join(t.TempDir(),"devices.json"))
 pub,priv,err:=ed25519.GenerateKey(rand.Reader);if err!=nil{t.Fatal(err)}
 d,err:=r.Add("iPhone",base64.StdEncoding.EncodeToString(pub));if err!=nil{t.Fatal(err)}
 n,err:=r.Challenge(d.ID);if err!=nil{t.Fatal(err)}
 sig:=base64.StdEncoding.EncodeToString(ed25519.Sign(priv,[]byte("taptether-auth-v1\n"+d.ID+"\n"+n)))
 token,err:=r.Session(d.ID,n,sig);if err!=nil{t.Fatal(err)}
 if !r.Verify(token){t.Fatal("session rejected")}
 if _,err:=r.Session(d.ID,n,sig);err==nil{t.Fatal("replay accepted")}
 if err:=r.Revoke(d.ID);err!=nil{t.Fatal(err)}
 if r.Verify(token){t.Fatal("revoked session valid")}
 if _,err:=r.Challenge(d.ID);err==nil{t.Fatal("revoked challenge accepted")}
}
func TestBadSignature(t *testing.T){
 r:=New(filepath.Join(t.TempDir(),"devices.json"))
 if _,err:=r.Challenge("unknown");err==nil{t.Fatal("unknown ID challenged")}
 pub,_,_:=ed25519.GenerateKey(rand.Reader)
 d,err:=r.Add("Phone",base64.StdEncoding.EncodeToString(pub));if err!=nil{t.Fatal(err)}
 n,_:=r.Challenge(d.ID)
 if _,err:=r.Session(d.ID,n,base64.StdEncoding.EncodeToString(make([]byte,ed25519.SignatureSize)));err==nil {t.Fatal("bad signature")}
}
