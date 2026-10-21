package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

type device struct {
	ID              string    `json:"deviceId"`
	Name            string    `json:"name"`
	PublicKey       string    `json:"publicKey"`
	Status          string    `json:"status"`
	ClaimStatus     string    `json:"claimStatus"`
	OwnerID         string    `json:"-"`
	DeviceTokenHash string    `json:"-"`
	ClaimHash       string    `json:"-"`
	ClaimRequestID  string    `json:"-"`
	ClaimExpiresAt  time.Time `json:"-"`
	LastSeen        time.Time `json:"lastSeen"`
}

type session struct {
	RTCSessionID string    `json:"rtcSessionId,omitempty"`
	ID           string    `json:"sessionId"`
	DeviceID     string    `json:"deviceId"`
	UserID       string    `json:"userId"`
	Expires      time.Time `json:"expiresAt"`
}

type cloud struct {
	mu                sync.RWMutex
	users             map[string]authUser
	accounts          map[string]string
	devices           map[string]device
	sessions          map[string]session
	accessTokens      map[string]tokenRecord
	refreshTokens     map[string]tokenRecord
	authStateFile     string
	stateFile         string
	relayMu           sync.Mutex
	relayPairs        map[string]*relayPair
	passwordResetCode string
	rtc               *rtcManager
}

func main() {
	admin := getenv("DEMO_ADMIN_PASSWORD", "change-me")
	c := &cloud{
		users:    map[string]authUser{"user-001": {ID: "user-001", Account: "admin", PasswordHash: hashPassword(admin)}},
		accounts: map[string]string{"admin": "user-001"},
		devices:  map[string]device{}, sessions: map[string]session{},
		accessTokens: map[string]tokenRecord{}, refreshTokens: map[string]tokenRecord{},
		authStateFile:     getenv("AUTH_STATE_FILE", "./data/auth-refresh.json"),
		stateFile:         getenv("CLOUD_STATE_FILE", "./data/cloud-state.json"),
		passwordResetCode: getenv("DEMO_PASSWORD_RESET_CODE", "change-me-reset"),
		relayPairs:        map[string]*relayPair{},
	}
	c.loadState()
	c.loadRefreshTokens()
	var rtcErr error
	c.rtc, rtcErr = newRTCManagerFromEnv()
	if rtcErr != nil {
		log.Fatalf("RTC initialization: %v", rtcErr)
	}
	addr := getenv("LISTEN_ADDR", ":"+getenv("PORT", "8080"))
	log.Printf("SE9 cloud service listening on %s", addr)
	handler := c.handler()
	server := &http.Server{Addr: addr, Handler: handler, ReadHeaderTimeout: 10 * time.Second, ReadTimeout: 60 * time.Second, WriteTimeout: 60 * time.Second, IdleTimeout: 120 * time.Second}
	certFile, keyFile := strings.TrimSpace(os.Getenv("TLS_CERT_FILE")), strings.TrimSpace(os.Getenv("TLS_KEY_FILE"))
	if certFile != "" || keyFile != "" {
		if certFile == "" || keyFile == "" {
			log.Fatal("TLS_CERT_FILE and TLS_KEY_FILE must be configured together")
		}
		log.Printf("SE9 cloud service TLS enabled with certificate %s", certFile)
		log.Fatal(server.ListenAndServeTLS(certFile, keyFile))
	}
	log.Printf("WARNING: TLS is disabled; configure TLS_CERT_FILE and TLS_KEY_FILE for production")
	log.Fatal(server.ListenAndServe())
}

func (c *cloud) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", c.health)
	mux.HandleFunc("/api/v2/auth/register", c.registerUser)
	mux.HandleFunc("/api/v2/auth/login", c.login)
	mux.HandleFunc("/api/v2/auth/refresh", c.refresh)
	mux.Handle("/api/v2/auth/me", c.userAuth(http.HandlerFunc(c.me)))
	mux.Handle("/api/v2/auth/password/change", c.userAuth(http.HandlerFunc(c.changePassword)))
	mux.HandleFunc("/api/v2/auth/password/reset", c.resetPassword)
	mux.Handle("/api/v2/auth/logout", c.userAuth(http.HandlerFunc(c.logout)))
	mux.HandleFunc("/api/v2/devices/register", c.register)
	mux.Handle("/api/v2/device_list", c.userAuth(http.HandlerFunc(c.deviceList)))
	mux.Handle("/api/v2/devices", c.userAuth(http.HandlerFunc(c.deviceList)))
	mux.Handle("/api/v2/devices/", c.deviceRoutes())
	mux.Handle("/api/v2/devices/claim/confirm", c.userAuth(http.HandlerFunc(c.confirmClaim)))
	mux.Handle("/api/v2/sessions", c.userAuth(http.HandlerFunc(c.sessionsHandler)))
	mux.Handle("/api/v2/relay/app", c.relayEndpoint("app"))
	mux.Handle("/api/v2/relay/device", c.relayEndpoint("device"))
	c.registerRTCRoutes(mux)
	return withJSON(mux)
}

func (c *cloud) health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, "0", "success", map[string]string{"status": "ok"})
}

func (c *cloud) registerUser(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	var in struct{ Account, Password, Nickname string }
	if json.NewDecoder(r.Body).Decode(&in) != nil || in.Account == "" || len(in.Password) < 8 {
		errorJSON(w, 400, "40002", "invalid registration")
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, exists := c.accounts[in.Account]; exists {
		errorJSON(w, 409, "40904", "account already exists")
		return
	}
	id := randomID()
	c.accounts[in.Account] = id
	c.users[id] = authUser{ID: id, Account: in.Account, Nickname: in.Nickname, PasswordHash: hashPassword(in.Password)}
	c.persistStateLocked()
	access, refresh := c.issueTokensLocked(id)
	writeJSON(w, 201, "0", "success", map[string]any{"user": c.userView(c.users[id]), "accessToken": access, "refreshToken": refresh, "expiresIn": int(accessTTL.Seconds())})
}

func (c *cloud) login(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	var in struct{ Account, Username, Password string }
	if json.NewDecoder(r.Body).Decode(&in) != nil {
		errorJSON(w, 400, "40001", "invalid request")
		return
	}
	account := in.Account
	if account == "" {
		account = in.Username
	}
	c.mu.RLock()
	id, ok := c.accounts[account]
	u := c.users[id]
	c.mu.RUnlock()
	if !ok || !verifyPassword(u.PasswordHash, in.Password) {
		errorJSON(w, 401, "40101", "invalid credentials")
		return
	}
	c.mu.Lock()
	access, refresh := c.issueTokensLocked(id)
	c.mu.Unlock()
	writeJSON(w, 200, "0", "success", map[string]any{"user": c.userView(c.users[id]), "accessToken": access, "refreshToken": refresh, "expiresIn": int(accessTTL.Seconds())})
}

func (c *cloud) userView(user authUser) map[string]string {
	return map[string]string{"userId": user.ID, "account": user.Account, "nickname": user.Nickname}
}

func (c *cloud) me(w http.ResponseWriter, r *http.Request) {
	c.mu.RLock()
	user := c.users[currentUserID(r)]
	c.mu.RUnlock()
	writeJSON(w, 200, "0", "success", map[string]any{"user": c.userView(user)})
}

func (c *cloud) changePassword(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	var in struct{ CurrentPassword, NewPassword string }
	if json.NewDecoder(r.Body).Decode(&in) != nil || len(in.NewPassword) < 8 {
		errorJSON(w, 400, "40002", "invalid password")
		return
	}
	id := currentUserID(r)
	c.mu.Lock()
	defer c.mu.Unlock()
	user := c.users[id]
	if !verifyPassword(user.PasswordHash, in.CurrentPassword) {
		errorJSON(w, 401, "40101", "current password invalid")
		return
	}
	user.PasswordHash = hashPassword(in.NewPassword)
	c.users[id] = user
	c.persistStateLocked()
	writeJSON(w, 200, "0", "success", map[string]any{})
}

func (c *cloud) resetPassword(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	var in struct{ Account, ResetCode, NewPassword string }
	if json.NewDecoder(r.Body).Decode(&in) != nil || in.Account == "" || len(in.NewPassword) < 8 || in.ResetCode != c.passwordResetCode {
		errorJSON(w, 400, "40002", "invalid reset request")
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	id, ok := c.accounts[in.Account]
	if !ok {
		errorJSON(w, 404, "40402", "account not found")
		return
	}
	user := c.users[id]
	user.PasswordHash = hashPassword(in.NewPassword)
	c.users[id] = user
	c.persistStateLocked()
	writeJSON(w, 200, "0", "success", map[string]any{})
}

func (c *cloud) refresh(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	var in struct {
		RefreshToken string `json:"refreshToken"`
	}
	if json.NewDecoder(r.Body).Decode(&in) != nil {
		errorJSON(w, 400, "40001", "invalid request")
		return
	}
	c.mu.Lock()
	key := hashToken(in.RefreshToken)
	record, ok := c.refreshTokens[key]
	if !ok || time.Now().After(record.ExpiresAt) {
		c.mu.Unlock()
		errorJSON(w, 401, "40101", "refresh token expired")
		return
	}
	delete(c.refreshTokens, key)
	access, refresh := c.issueTokensLocked(record.UserID)
	c.mu.Unlock()
	writeJSON(w, 200, "0", "success", map[string]any{"accessToken": access, "refreshToken": refresh, "expiresIn": int(accessTTL.Seconds())})
}

func (c *cloud) logout(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	c.mu.Lock()
	delete(c.accessTokens, hashToken(bearerToken(r)))
	c.mu.Unlock()
	writeJSON(w, 200, "0", "success", map[string]any{})
}

func (c *cloud) register(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	var in struct {
		DeviceID  string `json:"deviceId"`
		Name      string `json:"name"`
		PublicKey string `json:"publicKey"`
	}
	if json.NewDecoder(r.Body).Decode(&in) != nil || in.DeviceID == "" || in.PublicKey == "" {
		errorJSON(w, 400, "40002", "invalid device registration")
		return
	}
	now := time.Now().UTC()
	c.mu.RLock()
	previous, exists := c.devices[in.DeviceID]
	c.mu.RUnlock()
	deviceToken := randomSecret()
	if exists && previous.DeviceTokenHash != "" {
		deviceToken = strings.TrimSpace(r.Header.Get("X-Device-Token"))
		if deviceToken == "" || hashToken(deviceToken) != previous.DeviceTokenHash {
			errorJSON(w, 409, "40906", "device already registered")
			return
		}
	}
	claimStatus := previous.ClaimStatus
	if claimStatus == "" {
		claimStatus = "pending_claim"
	}
	d := device{ID: in.DeviceID, Name: in.Name, PublicKey: in.PublicKey, Status: "pending_claim", ClaimStatus: claimStatus, LastSeen: now, OwnerID: previous.OwnerID, DeviceTokenHash: hashToken(deviceToken), ClaimHash: previous.ClaimHash, ClaimRequestID: previous.ClaimRequestID, ClaimExpiresAt: previous.ClaimExpiresAt}
	c.mu.Lock()
	c.devices[in.DeviceID] = d
	c.persistStateLocked()
	c.mu.Unlock()
	writeJSON(w, http.StatusCreated, "0", "success", map[string]any{"device": d, "deviceToken": deviceToken})
}

func (c *cloud) confirmClaim(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	var in struct{ DeviceID, ClaimRequestID, ClaimString string }
	if json.NewDecoder(r.Body).Decode(&in) != nil || in.DeviceID == "" || !isHexClaim(in.ClaimString) {
		errorJSON(w, 400, "40002", "invalid claim request")
		return
	}
	userID := currentUserID(r)
	c.mu.Lock()
	d, ok := c.devices[in.DeviceID]
	if !ok {
		c.mu.Unlock()
		errorJSON(w, 404, "40402", "device not found")
		return
	}
	if d.OwnerID != "" || d.ClaimStatus == "claimed" {
		c.mu.Unlock()
		errorJSON(w, 409, "40901", "device already claimed")
		return
	}
	if d.ClaimHash == "" || !strings.EqualFold(d.ClaimHash, hashToken(in.ClaimString)) || (in.ClaimRequestID != "" && in.ClaimRequestID != d.ClaimRequestID) || time.Now().After(d.ClaimExpiresAt) {
		c.mu.Unlock()
		errorJSON(w, 410, "41001", "claim string expired or invalid")
		return
	}
	d.OwnerID = userID
	d.ClaimStatus = "claimed"
	d.ClaimHash, d.ClaimRequestID = "", ""
	d.ClaimExpiresAt = time.Time{}
	c.devices[in.DeviceID] = d
	c.persistStateLocked()
	c.mu.Unlock()
	writeJSON(w, 200, "0", "success", map[string]any{"deviceId": in.DeviceID, "role": "owner", "claimedAt": time.Now().Unix()})
}

func (c *cloud) prepareClaim(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	var in struct {
		ClaimString, RequestID string
		ExpiresAt              int64
	}
	if json.NewDecoder(r.Body).Decode(&in) != nil || !isHexClaim(in.ClaimString) || in.RequestID == "" || in.ExpiresAt <= time.Now().Unix() || in.ExpiresAt > time.Now().Add(10*time.Minute).Unix() {
		errorJSON(w, 400, "40002", "invalid claim preparation")
		return
	}
	id := deviceIDFromPath(r.URL.Path)
	c.mu.Lock()
	d, ok := c.devices[id]
	if !ok {
		c.mu.Unlock()
		errorJSON(w, 404, "40402", "device not found")
		return
	}
	if d.OwnerID != "" || d.ClaimStatus == "claimed" {
		c.mu.Unlock()
		errorJSON(w, 409, "40901", "device already claimed")
		return
	}
	d.ClaimHash, d.ClaimRequestID, d.ClaimExpiresAt = hashToken(in.ClaimString), in.RequestID, time.Unix(in.ExpiresAt, 0)
	c.devices[id] = d
	c.persistStateLocked()
	c.mu.Unlock()
	writeJSON(w, 200, "0", "success", map[string]any{"deviceId": id, "requestId": in.RequestID, "expiresAt": in.ExpiresAt})
}

func (c *cloud) device(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(parts) < 3 {
		errorJSON(w, 400, "40001", "invalid device path")
		return
	}
	if len(parts) < 4 {
		errorJSON(w, 400, "40001", "invalid device path")
		return
	}
	id := parts[3]
	c.mu.Lock()
	d, ok := c.devices[id]
	if ok && len(parts) == 5 && parts[4] == "heartbeat" {
		d.Status = "online"
		d.LastSeen = time.Now().UTC()
		c.devices[id] = d
		c.persistStateLocked()
	}
	c.mu.Unlock()
	if !ok {
		errorJSON(w, 404, "40402", "device not found")
		return
	}
	if len(parts) == 5 && parts[4] == "heartbeat" {
		writeJSON(w, 200, "0", "success", d)
		return
	}
	writeJSON(w, 200, "0", "success", d)
}

func (c *cloud) sessionsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	var in struct {
		DeviceID     string `json:"deviceId"`
		RTCSessionID string `json:"rtcSessionId"`
	}
	if json.NewDecoder(r.Body).Decode(&in) != nil || in.DeviceID == "" {
		errorJSON(w, 400, "40002", "invalid session request")
		return
	}
	c.mu.RLock()
	d, ok := c.devices[in.DeviceID]
	c.mu.RUnlock()
	if !ok {
		errorJSON(w, 404, "40402", "device not found")
		return
	}
	if d.OwnerID == "" || d.OwnerID != currentUserID(r) {
		errorJSON(w, 403, "40301", "device access denied")
		return
	}
	if deviceStatus(d, time.Now()) == "offline" {
		errorJSON(w, 409, "40905", "device offline")
		return
	}
	if in.RTCSessionID != "" && !c.rtcLegacyAllowed(in.RTCSessionID, in.DeviceID, currentUserID(r)) {
		errorJSON(w, 403, "RTC_AUTH_FAILED", "legacy transfer session not authorized")
		return
	}
	s := session{RTCSessionID: in.RTCSessionID, ID: randomID(), DeviceID: in.DeviceID, UserID: currentUserID(r), Expires: time.Now().UTC().Add(10 * time.Minute)}
	c.mu.Lock()
	c.sessions[s.ID] = s
	c.persistStateLocked()
	c.mu.Unlock()
	writeJSON(w, http.StatusCreated, "0", "success", s)
}

func (c *cloud) issueTokensLocked(userID string) (string, string) {
	access, refresh := randomSecret(), randomSecret()
	now := time.Now()
	c.accessTokens[hashToken(access)] = tokenRecord{UserID: userID, ExpiresAt: now.Add(accessTTL)}
	c.refreshTokens[hashToken(refresh)] = tokenRecord{UserID: userID, ExpiresAt: now.Add(refreshTTL)}
	c.persistRefreshTokensLocked()
	return access, refresh
}

func (c *cloud) userAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token := bearerToken(r)
		c.mu.RLock()
		record, ok := c.accessTokens[hashToken(token)]
		c.mu.RUnlock()
		if token == "" || !ok || time.Now().After(record.ExpiresAt) {
			errorJSON(w, 401, "40101", "access token invalid or expired")
			return
		}
		next.ServeHTTP(w, withUserID(r, record.UserID))
	})
}

func (c *cloud) deviceAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		deviceID := deviceIDFromPath(r.URL.Path)
		token := strings.TrimSpace(r.Header.Get("X-Device-Token"))
		c.mu.RLock()
		d, exists := c.devices[deviceID]
		c.mu.RUnlock()
		if token == "" || !exists || hashToken(token) != d.DeviceTokenHash {
			errorJSON(w, 401, "40101", "device token required")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (c *cloud) deviceRoutes() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(strings.TrimSuffix(r.URL.Path, "/"), "/heartbeat") {
			c.deviceAuth(http.HandlerFunc(c.device)).ServeHTTP(w, r)
			return
		}
		if strings.HasSuffix(strings.TrimSuffix(r.URL.Path, "/"), "/claim/prepare") {
			c.deviceAuth(http.HandlerFunc(c.prepareClaim)).ServeHTTP(w, r)
			return
		}
		c.userAuth(http.HandlerFunc(c.device)).ServeHTTP(w, r)
	})
}

func deviceIDFromPath(path string) string {
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) >= 4 {
		return parts[3]
	}
	return ""
}

func randomID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func isHexClaim(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, r := range value {
		if !(r >= '0' && r <= '9') && !(r >= 'a' && r <= 'f') && !(r >= 'A' && r <= 'F') {
			return false
		}
	}
	return true
}

func getenv(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}
func withJSON(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		next.ServeHTTP(w, r)
	})
}
func methodNotAllowed(w http.ResponseWriter) {
	errorJSON(w, http.StatusMethodNotAllowed, "40001", "method not allowed")
}
