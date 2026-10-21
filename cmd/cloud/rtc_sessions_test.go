package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func rtcTestCloud(t *testing.T) *cloud {
	t.Helper()
	c := deviceListCloud(t)
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	c.rtc = &rtcManager{key: key, sessions: map[string]*rtcSession{}, devices: map[string]*rtcSignalPeer{"a": {outbound: make(chan rtcEvent, 64), done: make(chan struct{})}}, allowInsecure: true}
	return c
}
func rtcSDP() string {
	return "v=0\r\na=fingerprint:sha-256 " + strings.TrimSuffix(strings.Repeat("AB:", 32), ":") + "\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n"
}
func TestRTCFingerprintValidation(t *testing.T) {
	if _, err := rtcFingerprint(rtcSDP()); err != nil {
		t.Fatal(err)
	}
	for _, value := range []string{strings.Replace(rtcSDP(), "m=application", "m=video", 1), strings.Replace(rtcSDP(), "AB:", "X:", 1), rtcSDP() + "a=fingerprint:sha-256 " + strings.TrimSuffix(strings.Repeat("CD:", 32), ":") + "\r\n"} {
		if _, err := rtcFingerprint(value); err == nil {
			t.Fatal("invalid fingerprint accepted")
		}
	}
}
func TestRTCSessionOwnershipIdempotencyAndGrant(t *testing.T) {
	c := rtcTestCloud(t)
	input := map[string]any{"deviceId": "a", "requestId": "rtc-test-request-1", "protocolVersions": []int{1}, "offer": rtcDescription{Type: "offer", SDP: rtcSDP()}, "allowLegacyRelay": true}
	call := func(token string) *httptest.ResponseRecorder {
		b, _ := json.Marshal(input)
		r := httptest.NewRequest("POST", "/api/v2/rtc/sessions", strings.NewReader(string(b)))
		r.RemoteAddr = "127.0.0.1:1234"
		r.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		c.handler().ServeHTTP(w, r)
		return w
	}
	if w := call("empty-token"); w.Code != 403 {
		t.Fatalf("nonowner: %d %s", w.Code, w.Body.String())
	}
	w := call("owner-token")
	if w.Code != 201 {
		t.Fatalf("create: %d %s", w.Code, w.Body.String())
	}
	var envelope struct {
		Data struct {
			ID    string `json:"rtcSessionId"`
			Grant string `json:"grant"`
		}
	}
	if err := json.Unmarshal(w.Body.Bytes(), &envelope); err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(envelope.Data.Grant, ".")
	signature, _ := base64.RawURLEncoding.DecodeString(parts[2])
	if !ed25519.Verify(c.rtc.key.Public().(ed25519.PublicKey), []byte(parts[0]+"."+parts[1]), signature) {
		t.Fatal("grant signature")
	}
	claims, _ := base64.RawURLEncoding.DecodeString(parts[1])
	var grant rtcGrant
	if err := json.Unmarshal(claims, &grant); err != nil {
		t.Fatal(err)
	}
	if grant.Sub != "owner" || grant.DeviceID != "a" || grant.OfferHash != rtcDigest(rtcSDP()) || grant.Exp <= time.Now().Unix() || grant.Exp > time.Now().Add(6*time.Minute).Unix() {
		t.Fatalf("invalid scoped grant %+v", grant)
	}
	if w := call("owner-token"); w.Code != 201 || len(c.rtc.sessions) != 1 {
		t.Fatalf("idempotency %s", w.Body.String())
	}
	input["offer"] = rtcDescription{Type: "offer", SDP: rtcSDP() + "a=ice-options:trickle\r\n"}
	if w := call("owner-token"); w.Code != 409 {
		t.Fatal("reused request accepted")
	}
	if !c.rtcLegacyAllowed(envelope.Data.ID, "a", "owner") || c.rtcLegacyAllowed(envelope.Data.ID, "a", "empty") {
		t.Fatal("legacy authorization")
	}
	c.rtc.sessions[envelope.Data.ID].Closed = true
	if c.rtcLegacyAllowed(envelope.Data.ID, "a", "owner") {
		t.Fatal("closed session accepted")
	}
}
func TestRTCTLSBoundaryAndDisabled(t *testing.T) {
	c := rtcTestCloud(t)
	c.rtc.allowInsecure = false
	r := httptest.NewRequest("GET", "/api/v2/rtc/ice?deviceId=a", nil)
	r.RemoteAddr = "203.0.113.7:1234"
	r.Header.Set("Authorization", "Bearer owner-token")
	r.Header.Set("X-Forwarded-Proto", "https")
	w := httptest.NewRecorder()
	c.handler().ServeHTTP(w, r)
	if w.Code != 403 || !strings.Contains(w.Body.String(), "RTC_TLS_REQUIRED") {
		t.Fatal(w.Body.String())
	}
	c.rtc = nil
	w = httptest.NewRecorder()
	c.handler().ServeHTTP(w, r)
	if w.Code != 503 {
		t.Fatal(w.Body.String())
	}
}
func TestRTCAnswerAuthenticity(t *testing.T) {
	c := rtcTestCloud(t)
	pub, key, _ := ed25519.GenerateKey(rand.Reader)
	d := c.devices["a"]
	d.PublicKey = base64.StdEncoding.EncodeToString(pub)
	c.devices["a"] = d
	s := &rtcSession{ID: "test-session", DeviceID: "a", UserID: "owner", NegotiationID: "negotiation", OfferHash: rtcDigest(rtcSDP()), Expires: time.Now().Add(time.Minute), Seen: map[string]bool{}, Candidates: map[string]int{}}
	c.rtc.sessions[s.ID] = s
	transcript := "se9-rtc-v1|" + s.ID + "|" + s.NegotiationID + "|" + s.OfferHash + "|" + rtcDigest(rtcSDP())
	answer := map[string]any{"answer": rtcDescription{Type: "answer", SDP: rtcSDP()}, "deviceSignature": base64.StdEncoding.EncodeToString(ed25519.Sign(key, []byte(transcript)))}
	payload, _ := json.Marshal(answer)
	e := rtcEvent{Version: 1, Type: "session.answer", SessionID: s.ID, NegotiationID: s.NegotiationID, MessageID: "message-valid", Payload: payload}
	if !c.routeRTCEvent(c.rtc.devices["a"], "a", "device", e) {
		t.Fatal("valid answer denied")
	}
	answer["answer"] = rtcDescription{Type: "answer", SDP: rtcSDP() + "a=changed\r\n"}
	e.Payload, _ = json.Marshal(answer)
	e.MessageID = "message-tampered"
	if c.routeRTCEvent(c.rtc.devices["a"], "a", "device", e) {
		t.Fatal("tampered answer accepted")
	}
}

func TestRTCICETransportValidation(t *testing.T) {
	t.Setenv("RTC_ENABLED", "1")
	t.Setenv("RTC_GRANT_KEY_FILE", filepath.Join(t.TempDir(), "grant.pem"))
	secret := filepath.Join(t.TempDir(), "turn-secret")
	if err := os.WriteFile(secret, []byte(strings.Repeat("x", 32)), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TURN_SHARED_SECRET_FILE", secret)
	for _, tc := range []struct {
		uri   string
		valid bool
	}{
		{"turns:123.56.147.51:5349?transport=tcp", true},
		{"turn:123.56.147.51:3478?transport=udp", true},
		{"stun:123.56.147.51:3478", true},
		{"turns:123.56.147.51:5349?transport=tls", false},
		{"turn:123.56.147.51:3478?transport=tcp&transport=udp", false},
		{"stun:123.56.147.51:3478?transport=tcp", false},
	} {
		t.Run(tc.uri, func(t *testing.T) {
			t.Setenv("TURN_URLS", tc.uri)
			_, err := newRTCManagerFromEnv()
			if (err == nil) != tc.valid {
				t.Fatalf("valid=%v err=%v", tc.valid, err)
			}
		})
	}
}
