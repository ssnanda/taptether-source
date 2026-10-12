package identity

import (
 "crypto/ed25519"
 "crypto/rand"
 "crypto/sha256"
 "crypto/subtle"
 "encoding/base64"
 "encoding/hex"
 "encoding/json"
 "errors"
 "fmt"
 "os"
 "path/filepath"
 "regexp"
 "sync"
 "time"
)

// Device is public metadata. It never contains a private key or bearer token.
type Device struct {
 ID string `json:"id"`
 Name string `json:"name"`
 PublicKey string `json:"publicKey"`
}
type Registry struct {
 mu sync.Mutex
 path string
 challenges map[string]challenge
 sessions map[string]session
}
type challenge struct { deviceID string; expire time.Time }
type session struct { deviceID string; expire time.Time }
var deviceLabel=regexp.MustCompile("^[a-zA-Z0-9 _.-]{1,64}$")
var errCredentials=errors.New("device authentication failed")

func New(path string)*Registry{
 return &Registry{path:path,challenges:make(map[string]challenge),sessions:make(map[string]session)}
}
func (r *Registry) read()([]Device,error){
 content,err:=os.ReadFile(r.path)
 if os.IsNotExist(err){return nil,nil}
 if err!=nil{return nil,err}
 var devices []Device
 if err=json.Unmarshal(content,&devices);err!=nil{return nil,err}
 return devices,nil
}
func (r *Registry) save(devices []Device)error{
 encoded,err:=json.MarshalIndent(devices,"","  ")
 if err!=nil{return err}
 tmp,err:=os.CreateTemp(filepath.Dir(r.path),".authorized-devices-")
 if err!=nil{return err}
 defer os.Remove(tmp.Name())
 defer tmp.Close()
 if err=tmp.Chmod(0600);err!=nil{return err}
 if _,err=tmp.Write(encoded);err!=nil{return err}
 if err=tmp.Sync();err!=nil{return err}
 if err=tmp.Close();err!=nil{return err}
 return os.Rename(tmp.Name(),r.path)
}
func deviceID(pub ed25519.PublicKey)string{
 h:=sha256.Sum256(pub)
 return hex.EncodeToString(h[:16])
}
func decodeKey(key string)(ed25519.PublicKey,error){
 b,err:=base64.StdEncoding.DecodeString(key)
 if err!=nil || len(b)!=ed25519.PublicKeySize{return nil,errors.New("invalid Ed25519 key")}
 return ed25519.PublicKey(b),nil
}
func (r *Registry) Add(name,key string)(Device,error){
 pub,err:=decodeKey(key);if err!=nil{return Device{},err}
 if !deviceLabel.MatchString(name){return Device{},errors.New("invalid device label")}
 d:=Device{ID:deviceID(pub),Name:name,PublicKey:key}
 r.mu.Lock();defer r.mu.Unlock()
 devices,err:=r.read();if err!=nil{return Device{},err}
 for i,item:=range devices{
  if item.ID==d.ID{devices[i]=d;return d,r.save(devices)}
 }
 if len(devices)>=32{return Device{},errors.New("authorized device limit reached")}
 return d,r.save(append(devices,d))
}
func (r *Registry) List()([]Device,error){
 r.mu.Lock();defer r.mu.Unlock()
 return r.read()
}
func (r *Registry) Has(id string)bool{
 r.mu.Lock();defer r.mu.Unlock()
 devices,err:=r.read();if err!=nil{return false}
 for _,d:=range devices{if subtle.ConstantTimeCompare([]byte(d.ID),[]byte(id))==1{return true}}
 return false
}
func (r *Registry) Revoke(id string)error{
 r.mu.Lock();defer r.mu.Unlock()
 devices,err:=r.read();if err!=nil{return err}
 keep:=make([]Device,0,len(devices));found:=false
 for _,d:=range devices{
  if d.ID==id{found=true;continue}
  keep=append(keep,d)
 }
 if !found{return errors.New("device not found")}
 for n,v:=range r.challenges{if v.deviceID==id{delete(r.challenges,n)}}
 for t,v:=range r.sessions{if v.deviceID==id{delete(r.sessions,t)}}
 return r.save(keep)
}
func randomValue()(string,error){
 data:=make([]byte,32)
 if _,err:=rand.Read(data);err!=nil{return "",err}
 return base64.RawURLEncoding.EncodeToString(data),nil
}
func (r *Registry) cleanupLocked(now time.Time){
 for n,c:=range r.challenges{if !c.expire.After(now){delete(r.challenges,n)}}
 for t,s:=range r.sessions{if !s.expire.After(now){delete(r.sessions,t)}}
}
func (r *Registry) Challenge(id string)(string,error){
 if !r.Has(id){return "",errCredentials}
 r.mu.Lock();defer r.mu.Unlock()
 now:=time.Now();r.cleanupLocked(now)
 if len(r.challenges)>=128{return "",errors.New("too many outstanding challenges")}
 nonce,err:=randomValue();if err!=nil{return "",err}
 r.challenges[nonce]=challenge{deviceID:id,expire:now.Add(30*time.Second)}
 return nonce,nil
}
func (r *Registry) Session(id,nonce,sig64 string)(string,error){
 r.mu.Lock();defer r.mu.Unlock()
 now:=time.Now();r.cleanupLocked(now)
 pending,ok:=r.challenges[nonce]
 delete(r.challenges,nonce)
 if !ok || pending.deviceID!=id || !pending.expire.After(now){return "",errCredentials}
 signature,err:=base64.StdEncoding.DecodeString(sig64)
 if err!=nil || len(signature)!=ed25519.SignatureSize{return "",errCredentials}
 devices,err:=r.read();if err!=nil{return "",err}
 var key ed25519.PublicKey
 for _,d:=range devices{if d.ID==id{key,err=decodeKey(d.PublicKey);break}}
 if err!=nil || len(key)!=ed25519.PublicKeySize{return "",errCredentials}
 message:=[]byte(fmt.Sprintf("taptether-auth-v1\n%s\n%s",id,nonce))
 if !ed25519.Verify(key,message,signature){return "",errCredentials}
 if len(r.sessions)>=128{return "",errors.New("too many sessions")}
 token,err:=randomValue();if err!=nil{return "",err}
 r.sessions[token]=session{deviceID:id,expire:now.Add(15*time.Minute)}
 return token,nil
}
func (r *Registry) Verify(token string)bool{
 r.mu.Lock();defer r.mu.Unlock()
 now:=time.Now();r.cleanupLocked(now)
 v,ok:=r.sessions[token]
 if !ok{return false}
 devices,err:=r.read();if err!=nil{return false}
 for _,d:=range devices{if d.ID==v.deviceID{return true}}
 return false
}
