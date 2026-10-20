package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"
)

const (
	accessTTL  = time.Hour
	refreshTTL = 30 * 24 * time.Hour
)

type tokenRecord struct {
	UserID    string
	ExpiresAt time.Time
}

type responseEnvelope struct {
	ResponseID string `json:"responseId"`
	Timestamp  int64  `json:"timestamp"`
	Code       string `json:"code"`
	Message    string `json:"message"`
	Data       any    `json:"data"`
}

func randomSecret() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func hashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
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

func writeJSON(w http.ResponseWriter, status int, args ...any) {
	code, message := "0", "success"
	var data any
	if len(args) == 1 {
		data = args[0]
	}
	if len(args) >= 3 {
		code, _ = args[0].(string)
		message, _ = args[1].(string)
		data = args[2]
	}
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(responseEnvelope{ResponseID: randomSecret()[:32], Timestamp: time.Now().UnixMilli(), Code: code, Message: message, Data: data})
}

func errorJSON(w http.ResponseWriter, status int, args ...string) {
	code, message := "50001", "request failed"
	if len(args) == 1 {
		message = args[0]
	}
	if len(args) >= 2 {
		code, message = args[0], args[1]
	}
	writeJSON(w, status, code, message, nil)
}

func bearerToken(r *http.Request) string {
	value := strings.TrimSpace(r.Header.Get("Authorization"))
	if !strings.HasPrefix(value, "Bearer ") {
		return ""
	}
	return strings.TrimSpace(strings.TrimPrefix(value, "Bearer "))
}

func (s *server) loadRefreshTokens() {
	data, err := os.ReadFile(s.authStateFile)
	if err != nil {
		return
	}
	var tokens map[string]tokenRecord
	if json.Unmarshal(data, &tokens) == nil {
		s.refreshTokens = tokens
	}
}

func (s *server) persistRefreshTokensLocked() {
	data, err := json.Marshal(s.refreshTokens)
	if err != nil {
		return
	}
	_ = os.WriteFile(s.authStateFile, data, 0o600)
}
