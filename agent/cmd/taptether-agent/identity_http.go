package main

import (
 "crypto/subtle"
 "encoding/json"
 "io"
 "net/http"
 "strings"

 "github.com/ssnanda/taptether.com/agent/internal/identity"
)

type identityAPI struct {
 devices *identity.Registry
 legacyToken string
}
func (a *identityAPI) legacy(r *http.Request) bool {
 got:=strings.TrimPrefix(r.Header.Get("Authorization"),"Bearer ")
 return len(got)==len(a.legacyToken) &&
  subtle.ConstantTimeCompare([]byte(got),[]byte(a.legacyToken))==1
}
func (a *identityAPI) authorized(r *http.Request) bool {
 got:=strings.TrimPrefix(r.Header.Get("Authorization"),"Bearer ")
 return a.legacy(r) || a.devices.Verify(got)
}
func identityLAN(w http.ResponseWriter,r *http.Request)bool{
 w.Header().Set("Cache-Control","no-store")
 if r.Method!=http.MethodPost {http.Error(w,"POST required",http.StatusMethodNotAllowed);return false}
 if r.TLS==nil || !privateRemote(r.RemoteAddr){http.Error(w,"LAN TLS required",http.StatusForbidden);return false}
 return true
}
func decodeIdentityJSON(w http.ResponseWriter,r *http.Request,dst any)bool{
 body:=http.MaxBytesReader(w,r.Body,2048);defer body.Close()
 dec:=json.NewDecoder(body);dec.DisallowUnknownFields()
 if dec.Decode(dst)!=nil{http.Error(w,"invalid request",http.StatusBadRequest);return false}
 var extra any
 if dec.Decode(&extra)!=io.EOF{http.Error(w,"trailing data",http.StatusBadRequest);return false}
 return true
}
func (a *identityAPI) Register(mux *http.ServeMux){
 mux.HandleFunc("/api/pair",func(w http.ResponseWriter,r *http.Request){
  if !identityLAN(w,r){return}
  if !a.legacy(r){http.Error(w,"owner approval required",http.StatusUnauthorized);return}
  var req struct{ Name string `json:"name"`; PublicKey string `json:"publicKey"` }
  if !decodeIdentityJSON(w,r,&req){return}
  d,err:=a.devices.Add(req.Name,req.PublicKey)
  if err!=nil{http.Error(w,"invalid enrollment",http.StatusBadRequest);return}
  w.Header().Set("Content-Type","application/json")
  _=json.NewEncoder(w).Encode(map[string]string{"id":d.ID})
 })
 mux.HandleFunc("/api/auth/challenge",func(w http.ResponseWriter,r *http.Request){
  if !identityLAN(w,r){return}
  var req struct{ ID string `json:"id"` }
  if !decodeIdentityJSON(w,r,&req){return}
  n,err:=a.devices.Challenge(req.ID)
  if err!=nil{http.Error(w,"device not authorized",http.StatusUnauthorized);return}
  w.Header().Set("Content-Type","application/json")
  _=json.NewEncoder(w).Encode(map[string]string{"nonce":n})
 })
 mux.HandleFunc("/api/auth/session",func(w http.ResponseWriter,r *http.Request){
  if !identityLAN(w,r){return}
  var req struct{ ID string `json:"id"`; Nonce string `json:"nonce"`; Signature string `json:"signature"` }
  if !decodeIdentityJSON(w,r,&req){return}
  t,err:=a.devices.Session(req.ID,req.Nonce,req.Signature)
  if err!=nil{http.Error(w,"signature rejected",http.StatusUnauthorized);return}
  w.Header().Set("Content-Type","application/json")
  _=json.NewEncoder(w).Encode(map[string]any{"token":t,"expiresIn":900})
 })
}
