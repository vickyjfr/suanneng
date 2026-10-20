package main

import (
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/net/websocket"
)

const rtcSignalLimit = 256 * 1024
const rtcGrantTTL = 5 * time.Minute
const rtcLeaseTTL = 30 * time.Minute

type rtcDescription struct {
	Type string `json:"type"`
	SDP  string `json:"sdp"`
}
type rtcIceServer struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
}
type rtcGrant struct {
	Iss           string   `json:"iss"`
	Aud           string   `json:"aud"`
	Sub           string   `json:"sub"`
	Iat           int64    `json:"iat"`
	Nbf           int64    `json:"nbf"`
	Exp           int64    `json:"exp"`
	JTI           string   `json:"jti"`
	SessionID     string   `json:"rtcSessionId"`
	DeviceID      string   `json:"deviceId"`
	NegotiationID string   `json:"negotiationId"`
	OfferHash     string   `json:"offerSha256"`
	Fingerprint   string   `json:"appFingerprint"`
	Operations    []string `json:"operations"`
	Transports    []string `json:"allowedTransports"`
	Version       int      `json:"protocolVersion"`
}
type rtcEvent struct {
	Version       int             `json:"version"`
	Type          string          `json:"type"`
	SessionID     string          `json:"rtcSessionId,omitempty"`
	NegotiationID string          `json:"negotiationId,omitempty"`
	MessageID     string          `json:"messageId,omitempty"`
	Sequence      uint64          `json:"sequence,omitempty"`
	Payload       json.RawMessage `json:"payload,omitempty"`
}
type rtcSession struct {
	ID            string
	DeviceID      string
	UserID        string
	RequestID     string
	NegotiationID string
	Offer         rtcDescription
	OfferHash     string
	Fingerprint   string
	Grant         string
	Expires       time.Time
	GrantExpires  time.Time
	AllowLegacy   bool
	App           *rtcSignalPeer
	Events        []rtcEvent
	NextSequence  uint64
	Seen          map[string]bool
	Candidates    map[string]int
	Closed        bool
}
type rtcManager struct {
	mu            sync.Mutex
	key           ed25519.PrivateKey
	sessions      map[string]*rtcSession
	devices       map[string]*rtcSignalPeer
	iceURLs       []string
	turnSecret    []byte
	allowInsecure bool
	trustProxy    bool
}
type rtcSignalPeer struct {
	ws       *websocket.Conn
	outbound chan rtcEvent
	done     chan struct{}
	once     sync.Once
}

func newRTCManagerFromEnv() (*rtcManager, error) {
	if os.Getenv("RTC_ENABLED") != "1" {
		return nil, nil
	}
	path := getenv("RTC_GRANT_KEY_FILE", "./data/rtc-grant.pem")
	keyData, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		if err = os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			return nil, err
		}
		_, key, e := ed25519.GenerateKey(rand.Reader)
		if e != nil {
			return nil, e
		}
		der, e := x509.MarshalPKCS8PrivateKey(key)
		if e != nil {
			return nil, e
		}
		keyData = pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
		f, e := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if e != nil {
			return nil, e
		}
		_, err = f.Write(keyData)
		if err == nil {
			err = f.Sync()
		}
		closeErr := f.Close()
		if err != nil {
			return nil, err
		}
		if closeErr != nil {
			return nil, closeErr
		}
	} else if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(keyData)
	if block == nil {
		return nil, errors.New("invalid RTC signing PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	key, ok := parsed.(ed25519.PrivateKey)
	if !ok {
		return nil, errors.New("RTC signing key must be Ed25519")
	}
	m := &rtcManager{key: key, sessions: map[string]*rtcSession{}, devices: map[string]*rtcSignalPeer{}, allowInsecure: os.Getenv("RTC_ALLOW_INSECURE_LOCAL") == "1", trustProxy: os.Getenv("RTC_TRUST_PROXY") == "1"}
	for _, raw := range strings.Split(os.Getenv("TURN_URLS"), ",") {
		if u := strings.TrimSpace(raw); u != "" {
			if !strings.HasPrefix(u, "stun:") && !strings.HasPrefix(u, "turn:") && !strings.HasPrefix(u, "turns:") {
				return nil, errors.New("invalid ICE URL")
			}
			m.iceURLs = append(m.iceURLs, u)
		}
	}
	if secretFile := os.Getenv("TURN_SHARED_SECRET_FILE"); secretFile != "" {
		data, e := os.ReadFile(secretFile)
		if e != nil {
			return nil, e
		}
		m.turnSecret = []byte(strings.TrimSpace(string(data)))
	}
	for _, u := range m.iceURLs {
		if strings.HasPrefix(u, "turn") && len(m.turnSecret) < 32 {
			return nil, errors.New("TURN requires a server shared secret of at least 32 bytes")
		}
	}
	return m, nil
}
func (m *rtcManager) secure(r *http.Request) bool {
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	ip := net.ParseIP(host)
	loop := ip != nil && ip.IsLoopback()
	return r.TLS != nil || (loop && m.trustProxy && r.Header.Get("X-Forwarded-Proto") == "https") || (loop && m.allowInsecure)
}
func rtcDigest(text string) string {
	sum := sha256.Sum256([]byte(text))
	return hex.EncodeToString(sum[:])
}

var rtcFingerprintRE = regexp.MustCompile(`(?im)^a=fingerprint:sha-256 ([0-9a-f:]+)\r?$`)

func rtcFingerprint(sdp string) (string, error) {
	if len(sdp) == 0 || len(sdp) > 128*1024 || strings.ContainsRune(sdp, 0) {
		return "", errors.New("invalid SDP")
	}
	app := false
	for _, line := range strings.Split(strings.ReplaceAll(sdp, "\r\n", "\n"), "\n") {
		if strings.HasPrefix(line, "m=") {
			if !strings.HasPrefix(line, "m=application ") {
				return "", errors.New("data-only SDP required")
			}
			app = true
		}
	}
	matches := rtcFingerprintRE.FindAllStringSubmatch(sdp, -1)
	if !app || len(matches) == 0 {
		return "", errors.New("missing data transport or fingerprint")
	}
	var result string
	for _, v := range matches {
		normalized := strings.ToUpper(v[1])
		raw, e := hex.DecodeString(strings.ReplaceAll(normalized, ":", ""))
		if e != nil || len(raw) != 32 {
			return "", errors.New("invalid fingerprint")
		}
		if result != "" && result != normalized {
			return "", errors.New("ambiguous fingerprint")
		}
		result = normalized
	}
	return result, nil
}
func (m *rtcManager) signGrant(s *rtcSession, now time.Time) string {
	transports := []string{"webrtc"}
	if s.AllowLegacy {
		transports = append(transports, "legacy")
	}
	claims := rtcGrant{Iss: "se9-cloud", Aud: "se9-transfer", Sub: s.UserID, Iat: now.Unix(), Nbf: now.Add(-5 * time.Second).Unix(), Exp: now.Add(rtcGrantTTL).Unix(), JTI: randomID(), SessionID: s.ID, DeviceID: s.DeviceID, NegotiationID: s.NegotiationID, OfferHash: s.OfferHash, Fingerprint: s.Fingerprint, Operations: []string{"upload", "download", "list", "stat"}, Transports: transports, Version: 1}
	body, _ := json.Marshal(claims)
	head := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"EdDSA","typ":"JWT"}`))
	content := head + "." + base64.RawURLEncoding.EncodeToString(body)
	s.GrantExpires = now.Add(rtcGrantTTL)
	return content + "." + base64.RawURLEncoding.EncodeToString(ed25519.Sign(m.key, []byte(content)))
}
func (m *rtcManager) ice(id, role string) []rtcIceServer {
	result := make([]rtcIceServer, 0, len(m.iceURLs))
	for _, u := range m.iceURLs {
		entry := rtcIceServer{URLs: []string{u}}
		if strings.HasPrefix(u, "turn") {
			entry.Username = strconv.FormatInt(time.Now().Add(time.Hour).Unix(), 10) + ":" + id + ":" + role
			mac := hmac.New(sha1.New, m.turnSecret)
			_, _ = mac.Write([]byte(entry.Username))
			entry.Credential = base64.StdEncoding.EncodeToString(mac.Sum(nil))
		}
		result = append(result, entry)
	}
	return result
}
func (c *cloud) registerRTCRoutes(mux *http.ServeMux) {
	mux.Handle("/api/v2/rtc/ice", c.userAuth(http.HandlerFunc(c.rtcICE)))
	mux.Handle("/api/v2/rtc/sessions", c.userAuth(http.HandlerFunc(c.rtcCreateSession)))
	mux.Handle("/api/v2/rtc/sessions/", c.userAuth(http.HandlerFunc(c.rtcSessionRoute)))
	mux.Handle("/api/v2/rtc/signaling/app", c.userAuth(http.HandlerFunc(c.rtcAppSignal)))
	mux.HandleFunc("/api/v2/rtc/signaling/device", c.rtcDeviceSignal)
}
func (c *cloud) requireRTC(w http.ResponseWriter, r *http.Request) bool {
	if c.rtc == nil {
		errorJSON(w, 503, "RTC_UNSUPPORTED", "WebRTC is disabled")
		return false
	}
	if !c.rtc.secure(r) {
		errorJSON(w, 403, "RTC_TLS_REQUIRED", "verified HTTPS/WSS required")
		return false
	}
	return true
}
func (c *cloud) rtcOwnedDevice(w http.ResponseWriter, r *http.Request, id string) (device, bool) {
	c.mu.RLock()
	d, exists := c.devices[id]
	c.mu.RUnlock()
	if !exists {
		errorJSON(w, 404, "40402", "device not found")
		return d, false
	}
	if d.OwnerID == "" || d.OwnerID != currentUserID(r) {
		errorJSON(w, 403, "40301", "device access denied")
		return d, false
	}
	if deviceStatus(d, time.Now()) != "online" {
		errorJSON(w, 409, "40905", "device offline")
		return d, false
	}
	return d, true
}
func (c *cloud) rtcICE(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	if !c.requireRTC(w, r) {
		return
	}
	if _, ok := c.rtcOwnedDevice(w, r, r.URL.Query().Get("deviceId")); !ok {
		return
	}
	writeJSON(w, 200, "0", "success", map[string]any{"iceServers": c.rtc.ice("bootstrap-"+randomID(), "app"), "expiresIn": 3600})
}
func (c *cloud) rtcCreateSession(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	if !c.requireRTC(w, r) {
		return
	}
	var in struct {
		DeviceID         string         `json:"deviceId"`
		RequestID        string         `json:"requestId"`
		Offer            rtcDescription `json:"offer"`
		AllowLegacy      bool           `json:"allowLegacyRelay"`
		ProtocolVersions []int          `json:"protocolVersions"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, rtcSignalLimit)
	if json.NewDecoder(r.Body).Decode(&in) != nil || in.DeviceID == "" || len(in.RequestID) < 16 || len(in.RequestID) > 128 || in.Offer.Type != "offer" {
		errorJSON(w, 400, "40002", "invalid RTC session")
		return
	}
	versionOK := false
	for _, v := range in.ProtocolVersions {
		if v == 1 {
			versionOK = true
		}
	}
	if !versionOK {
		errorJSON(w, 409, "PROTOCOL_MISMATCH", "protocol version 1 required")
		return
	}
	fingerprint, err := rtcFingerprint(in.Offer.SDP)
	if err != nil {
		errorJSON(w, 400, "40002", err.Error())
		return
	}
	d, ok := c.rtcOwnedDevice(w, r, in.DeviceID)
	if !ok {
		return
	}
	m := c.rtc
	now := time.Now()
	user := currentUserID(r)
	m.mu.Lock()
	for id, s := range m.sessions {
		if now.After(s.Expires) {
			delete(m.sessions, id)
			if s.App != nil {
				s.App.close()
			}
		}
	}
	for _, s := range m.sessions {
		if !s.Closed && s.UserID == user && s.RequestID == in.RequestID {
			if s.DeviceID != in.DeviceID || s.OfferHash != rtcDigest(in.Offer.SDP) {
				m.mu.Unlock()
				errorJSON(w, 409, "RTC_REQUEST_CONFLICT", "idempotency key reused")
				return
			}
			result := m.sessionView(s, d)
			m.mu.Unlock()
			writeJSON(w, 201, "0", "success", result)
			return
		}
	}
	peer := m.devices[in.DeviceID]
	if peer == nil {
		m.mu.Unlock()
		errorJSON(w, 409, "RTC_DEVICE_UNAVAILABLE", "device RTC control is not connected")
		return
	}
	count := 0
	for _, s := range m.sessions {
		if !s.Closed && s.DeviceID == in.DeviceID {
			count++
		}
	}
	if count >= 4 {
		m.mu.Unlock()
		errorJSON(w, 429, "RTC_QUOTA", "too many RTC sessions")
		return
	}
	s := &rtcSession{ID: randomID(), DeviceID: in.DeviceID, UserID: user, RequestID: in.RequestID, NegotiationID: randomID(), Offer: in.Offer, OfferHash: rtcDigest(in.Offer.SDP), Fingerprint: fingerprint, Expires: now.Add(rtcLeaseTTL), AllowLegacy: in.AllowLegacy, Seen: map[string]bool{}, Candidates: map[string]int{}}
	s.Grant = m.signGrant(s, now)
	m.sessions[s.ID] = s
	event := m.invite(s)
	result := m.sessionView(s, d)
	if !peer.enqueue(event) {
		delete(m.sessions, s.ID)
		m.mu.Unlock()
		errorJSON(w, 503, "RTC_DEVICE_BUSY", "device control queue full")
		return
	}
	m.mu.Unlock()
	writeJSON(w, 201, "0", "success", result)
}
func (m *rtcManager) sessionView(s *rtcSession, d device) map[string]any {
	return map[string]any{"rtcSessionId": s.ID, "negotiationId": s.NegotiationID, "grant": s.Grant, "expiresIn": int(time.Until(s.Expires).Seconds()), "grantExpiresIn": int(time.Until(s.GrantExpires).Seconds()), "signalPath": "/api/v2/rtc/signaling/app", "iceServers": m.ice(s.ID, "app"), "devicePublicKey": d.PublicKey, "capabilities": map[string]any{"protocolVersion": 1, "maxFrameBytes": 16384, "blockBytes": 1048576}}
}
func (m *rtcManager) invite(s *rtcSession) rtcEvent {
	payload, _ := json.Marshal(map[string]any{"grant": s.Grant, "offer": s.Offer, "iceServers": m.ice(s.ID, "device"), "userId": s.UserID})
	return rtcEvent{Version: 1, Type: "session.invite", SessionID: s.ID, NegotiationID: s.NegotiationID, MessageID: randomID(), Payload: payload}
}
func (c *cloud) rtcSessionRoute(w http.ResponseWriter, r *http.Request) {
	if !c.requireRTC(w, r) {
		return
	}
	parts := strings.Split(strings.Trim(strings.TrimPrefix(r.URL.Path, "/api/v2/rtc/sessions/"), "/"), "/")
	if len(parts) > 2 || parts[0] == "" {
		errorJSON(w, 404, "40402", "RTC session not found")
		return
	}
	m := c.rtc
	m.mu.Lock()
	s := m.sessions[parts[0]]
	if s == nil || s.UserID != currentUserID(r) || s.Closed || time.Now().After(s.Expires) {
		m.mu.Unlock()
		errorJSON(w, 404, "40402", "RTC session not found")
		return
	}
	deviceID := s.DeviceID
	m.mu.Unlock()
	d, ok := c.rtcOwnedDevice(w, r, deviceID)
	if !ok {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if r.Method == http.MethodPost && len(parts) == 2 && parts[1] == "renew" {
		s.Expires = time.Now().Add(rtcLeaseTTL)
		s.Grant = m.signGrant(s, time.Now())
		event := m.invite(s)
		event.Type = "session.renewed"
		if p := m.devices[s.DeviceID]; p != nil {
			p.enqueue(event)
		}
		writeJSON(w, 200, "0", "success", m.sessionView(s, d))
		return
	}
	if len(parts) != 1 {
		methodNotAllowed(w)
		return
	}
	if r.Method == http.MethodDelete {
		s.Closed = true
		if p := m.devices[s.DeviceID]; p != nil {
			p.enqueue(rtcEvent{Version: 1, Type: "session.close", SessionID: s.ID, NegotiationID: s.NegotiationID})
		}
		if s.App != nil {
			s.App.close()
		}
		writeJSON(w, 200, "0", "success", map[string]any{})
		return
	}
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	writeJSON(w, 200, "0", "success", m.sessionView(s, d))
}
func (p *rtcSignalPeer) close() { p.once.Do(func() { close(p.done); _ = p.ws.Close() }) }
func (p *rtcSignalPeer) enqueue(event rtcEvent) bool {
	select {
	case <-p.done:
		return false
	default:
	}
	select {
	case p.outbound <- event:
		return true
	default:
		return false
	}
}
func rtcServeSignal(w http.ResponseWriter, r *http.Request, run func(*rtcSignalPeer)) {
	server := websocket.Server{Handshake: func(_ *websocket.Config, _ *http.Request) error { return nil }, Handler: func(ws *websocket.Conn) {
		ws.MaxPayloadBytes = rtcSignalLimit
		p := &rtcSignalPeer{ws: ws, outbound: make(chan rtcEvent, 256), done: make(chan struct{})}
		defer p.close()
		go func() {
			ticker := time.NewTicker(20 * time.Second)
			defer ticker.Stop()
			for {
				select {
				case event := <-p.outbound:
					_ = ws.SetWriteDeadline(time.Now().Add(10 * time.Second))
					if websocket.JSON.Send(ws, event) != nil {
						p.close()
						return
					}
				case <-ticker.C:
					if !p.enqueue(rtcEvent{Version: 1, Type: "ping"}) {
						p.close()
						return
					}
				case <-p.done:
					return
				}
			}
		}()
		run(p)
	}}
	server.ServeHTTP(w, r)
}
func (c *cloud) rtcDeviceSignal(w http.ResponseWriter, r *http.Request) {
	if !c.requireRTC(w, r) {
		return
	}
	id := r.URL.Query().Get("deviceId")
	token := strings.TrimSpace(r.Header.Get("X-Device-Token"))
	c.mu.RLock()
	d, ok := c.devices[id]
	c.mu.RUnlock()
	if !ok || token == "" || hashToken(token) != d.DeviceTokenHash {
		errorJSON(w, 401, "40101", "device token required")
		return
	}
	rtcServeSignal(w, r, func(p *rtcSignalPeer) {
		m := c.rtc
		m.mu.Lock()
		if old := m.devices[id]; old != nil {
			old.close()
		}
		m.devices[id] = p
		for _, s := range m.sessions {
			if !s.Closed && s.DeviceID == id && time.Now().Before(s.Expires) {
				p.enqueue(m.invite(s))
			}
		}
		m.mu.Unlock()
		defer func() {
			m.mu.Lock()
			if m.devices[id] == p {
				delete(m.devices, id)
			}
			m.mu.Unlock()
		}()
		for {
			var event rtcEvent
			if websocket.JSON.Receive(p.ws, &event) != nil {
				return
			}
			if event.Type == "pong" {
				continue
			}
			if !c.routeRTCEvent(p, id, "device", event) {
				return
			}
		}
	})
}
func (c *cloud) rtcAppSignal(w http.ResponseWriter, r *http.Request) {
	if !c.requireRTC(w, r) {
		return
	}
	m := c.rtc
	id := r.URL.Query().Get("rtcSessionId")
	m.mu.Lock()
	s := m.sessions[id]
	valid := s != nil && !s.Closed && s.UserID == currentUserID(r) && time.Now().Before(s.Expires)
	deviceID := ""
	if valid {
		deviceID = s.DeviceID
	}
	m.mu.Unlock()
	if !valid {
		errorJSON(w, 404, "40402", "RTC session not found")
		return
	}
	if _, ok := c.rtcOwnedDevice(w, r, deviceID); !ok {
		return
	}
	since, _ := strconv.ParseUint(r.URL.Query().Get("since"), 10, 64)
	rtcServeSignal(w, r, func(p *rtcSignalPeer) {
		m.mu.Lock()
		if s.App != nil {
			s.App.close()
		}
		s.App = p
		for _, e := range s.Events {
			if e.Sequence > since {
				p.enqueue(e)
			}
		}
		m.mu.Unlock()
		defer func() {
			m.mu.Lock()
			if s.App == p {
				s.App = nil
			}
			m.mu.Unlock()
		}()
		for {
			var event rtcEvent
			if websocket.JSON.Receive(p.ws, &event) != nil {
				return
			}
			if event.Type == "pong" {
				continue
			}
			if event.SessionID != id || !c.routeRTCEvent(p, deviceID, "app", event) {
				return
			}
		}
	})
}
func (c *cloud) routeRTCEvent(peer *rtcSignalPeer, deviceID, role string, e rtcEvent) bool {
	m := c.rtc
	m.mu.Lock()
	defer m.mu.Unlock()
	s := m.sessions[e.SessionID]
	if e.Version != 1 || s == nil || s.Closed || s.DeviceID != deviceID || e.NegotiationID != s.NegotiationID || time.Now().After(s.Expires) || len(e.MessageID) < 8 || len(e.MessageID) > 128 {
		return false
	}
	if (role == "app" && s.App != peer) || (role == "device" && m.devices[deviceID] != peer) {
		return false
	}
	key := role + ":" + e.MessageID
	if s.Seen[key] {
		return true
	}
	if len(s.Seen) >= 1024 {
		return false
	}
	if e.Type == "ice.candidate" {
		s.Candidates[role]++
		if s.Candidates[role] > 128 {
			return false
		}
	} else if e.Type == "session.answer" && role == "device" {
		var answer struct {
			Answer    rtcDescription `json:"answer"`
			Signature string         `json:"deviceSignature"`
		}
		if json.Unmarshal(e.Payload, &answer) != nil || answer.Answer.Type != "answer" {
			return false
		}
		if _, err := rtcFingerprint(answer.Answer.SDP); err != nil {
			return false
		}
		c.mu.RLock()
		d := c.devices[deviceID]
		c.mu.RUnlock()
		public, err := base64.StdEncoding.DecodeString(d.PublicKey)
		signature, err2 := base64.StdEncoding.DecodeString(answer.Signature)
		transcript := "se9-rtc-v1|" + s.ID + "|" + s.NegotiationID + "|" + s.OfferHash + "|" + rtcDigest(answer.Answer.SDP)
		if err != nil || err2 != nil || len(public) != ed25519.PublicKeySize || !ed25519.Verify(public, []byte(transcript), signature) {
			return false
		}
	} else if e.Type != "session.error" && e.Type != "session.close" {
		return false
	}
	c.mu.RLock()
	owner := c.devices[deviceID].OwnerID
	c.mu.RUnlock()
	if owner != s.UserID {
		return false
	}
	s.Seen[key] = true
	s.NextSequence++
	e.Sequence = s.NextSequence
	if role == "device" {
		s.Events = append(s.Events, e)
		if len(s.Events) > 256 {
			s.Events = s.Events[len(s.Events)-256:]
		}
		if s.App != nil && !s.App.enqueue(e) {
			s.App.close()
		}
	} else {
		if p := m.devices[deviceID]; p == nil || !p.enqueue(e) {
			return false
		}
	}
	return true
}
func (c *cloud) rtcAvailable(id string) bool {
	if c.rtc == nil {
		return false
	}
	c.rtc.mu.Lock()
	defer c.rtc.mu.Unlock()
	return c.rtc.devices[id] != nil
}

func (c *cloud) rtcLegacyAllowed(rtcID, deviceID, userID string) bool {
	if c.rtc == nil {
		return false
	}
	m := c.rtc
	m.mu.Lock()
	defer m.mu.Unlock()
	s := m.sessions[rtcID]
	return s != nil && !s.Closed && s.AllowLegacy && s.DeviceID == deviceID && s.UserID == userID && time.Now().Before(s.Expires) && time.Now().Before(s.GrantExpires)
}
func (c *cloud) rtcRelayContext(sessionID string) (rtcEvent, bool, bool) {
	c.mu.RLock()
	relay, ok := c.sessions[sessionID]
	c.mu.RUnlock()
	if !ok {
		return rtcEvent{}, true, false
	}
	if relay.RTCSessionID == "" {
		return rtcEvent{}, false, true
	}
	if c.rtc == nil {
		return rtcEvent{}, true, false
	}
	m := c.rtc
	m.mu.Lock()
	defer m.mu.Unlock()
	s := m.sessions[relay.RTCSessionID]
	if s == nil || s.Closed || !s.AllowLegacy || s.DeviceID != relay.DeviceID || s.UserID != relay.UserID || time.Now().After(s.GrantExpires) || time.Now().After(s.Expires) {
		return rtcEvent{}, true, false
	}
	now := time.Now()
	claims := map[string]any{"iss": "se9-cloud", "aud": "se9-relay", "sub": s.UserID, "deviceId": s.DeviceID, "rtcSessionId": s.ID, "relaySessionId": relay.ID, "grantId": rtcDigest(s.Grant), "jti": randomID(), "iat": now.Unix(), "nbf": now.Add(-5 * time.Second).Unix(), "exp": s.GrantExpires.Unix()}
	body, _ := json.Marshal(claims)
	head := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"EdDSA","typ":"JWT"}`))
	content := head + "." + base64.RawURLEncoding.EncodeToString(body)
	token := content + "." + base64.RawURLEncoding.EncodeToString(ed25519.Sign(m.key, []byte(content)))
	payload, _ := json.Marshal(map[string]string{"context": token})
	return rtcEvent{Version: 1, Type: "relay.attach", SessionID: s.ID, Payload: payload}, true, true
}
