package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"
)

const (
	accessTTL  = 48 * time.Hour
	refreshTTL = 30 * 24 * time.Hour
)

type authUser struct {
	ID           string
	Account      string
	Nickname     string
	PasswordHash []byte
}

type tokenRecord struct {
	UserID    string
	ExpiresAt time.Time
}

type persistedDevice struct {
	ID              string    `json:"deviceId"`
	Name            string    `json:"name"`
	PublicKey       string    `json:"publicKey"`
	Status          string    `json:"status"`
	ClaimStatus     string    `json:"claimStatus"`
	OwnerID         string    `json:"ownerId"`
	DeviceTokenHash string    `json:"deviceTokenHash"`
	ClaimHash       string    `json:"claimHash"`
	ClaimRequestID  string    `json:"claimRequestId"`
	ClaimExpiresAt  time.Time `json:"claimExpiresAt"`
	LastSeen        time.Time `json:"lastSeen"`
}

type cloudState struct {
	Users    map[string]authUser        `json:"users"`
	Accounts map[string]string          `json:"accounts"`
	Devices  map[string]persistedDevice `json:"devices"`
	Sessions map[string]session         `json:"sessions"`
}

type responseEnvelope struct {
	ResponseID string `json:"responseId"`
	Timestamp  int64  `json:"timestamp"`
	Code       string `json:"code"`
	Message    string `json:"message"`
	Data       any    `json:"data"`
}

type authContextKey string

const userIDKey authContextKey = "userID"

func hashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func randomSecret() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func hashPassword(password string) []byte {
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		panic(err)
	}
	return hash
}

func verifyPassword(hash []byte, password string) bool {
	return bcrypt.CompareHashAndPassword(hash, []byte(password)) == nil
}

func writeJSON(w http.ResponseWriter, status int, code, message string, data any) {
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(responseEnvelope{
		ResponseID: randomSecret()[:32],
		Timestamp:  time.Now().UnixMilli(),
		Code:       code,
		Message:    message,
		Data:       data,
	})
}

func errorJSON(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, code, message, nil)
}

func bearerToken(r *http.Request) string {
	value := strings.TrimSpace(r.Header.Get("Authorization"))
	if !strings.HasPrefix(value, "Bearer ") {
		return ""
	}
	return strings.TrimSpace(strings.TrimPrefix(value, "Bearer "))
}

func withUserID(r *http.Request, userID string) *http.Request {
	return r.WithContext(context.WithValue(r.Context(), userIDKey, userID))
}

func currentUserID(r *http.Request) string {
	value, _ := r.Context().Value(userIDKey).(string)
	return value
}

func (c *cloud) loadRefreshTokens() {
	data, err := os.ReadFile(c.authStateFile)
	if err != nil {
		return
	}
	var tokens map[string]tokenRecord
	if json.Unmarshal(data, &tokens) == nil {
		c.refreshTokens = tokens
	}
}

func (c *cloud) persistRefreshTokensLocked() {
	data, err := json.Marshal(c.refreshTokens)
	if err != nil {
		return
	}
	_ = os.MkdirAll(filepath.Dir(c.authStateFile), 0o750)
	_ = os.WriteFile(c.authStateFile, data, 0o600)
}

func (c *cloud) loadState() {
	data, err := os.ReadFile(c.stateFile)
	if err != nil {
		return
	}
	var state cloudState
	if json.Unmarshal(data, &state) != nil {
		return
	}
	if len(state.Users) > 0 {
		c.users = state.Users
		c.accounts = state.Accounts
	}
	for id, saved := range state.Devices {
		c.devices[id] = device{ID: saved.ID, Name: saved.Name, PublicKey: saved.PublicKey, Status: saved.Status, ClaimStatus: saved.ClaimStatus, OwnerID: saved.OwnerID, DeviceTokenHash: saved.DeviceTokenHash, ClaimHash: saved.ClaimHash, ClaimRequestID: saved.ClaimRequestID, ClaimExpiresAt: saved.ClaimExpiresAt, LastSeen: saved.LastSeen}
	}
	for id, saved := range state.Sessions {
		c.sessions[id] = saved
	}
}

func (c *cloud) persistStateLocked() {
	state := cloudState{Users: c.users, Accounts: c.accounts, Devices: make(map[string]persistedDevice, len(c.devices)), Sessions: c.sessions}
	for id, current := range c.devices {
		state.Devices[id] = persistedDevice{ID: current.ID, Name: current.Name, PublicKey: current.PublicKey, Status: current.Status, ClaimStatus: current.ClaimStatus, OwnerID: current.OwnerID, DeviceTokenHash: current.DeviceTokenHash, ClaimHash: current.ClaimHash, ClaimRequestID: current.ClaimRequestID, ClaimExpiresAt: current.ClaimExpiresAt, LastSeen: current.LastSeen}
	}
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return
	}
	if err := os.MkdirAll(filepath.Dir(c.stateFile), 0o750); err != nil {
		return
	}
	temporary := c.stateFile + ".tmp"
	if os.WriteFile(temporary, data, 0o600) == nil {
		_ = os.Rename(temporary, c.stateFile)
	}
}
