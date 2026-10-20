package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

type user struct {
	Name         string
	PasswordHash []byte
}
type upload struct {
	ID, Path        string
	Size, ChunkSize int64
	TotalChunks     int
	Overwrite       bool
	Chunks          map[int]bool
	Created         time.Time
}

const (
	maxUploadSize = int64(20 * 1024 * 1024 * 1024)
	maxChunkSize  = int64(64 * 1024 * 1024)
)

type server struct {
	root          string
	users         map[string]user
	tokens        map[string]tokenRecord
	refreshTokens map[string]tokenRecord
	authStateFile string
	uploads       map[string]*upload
	mu            sync.Mutex
}

func main() {
	root := getenv("STORAGE_ROOT", "/vos/workspace/demo")
	if err := os.MkdirAll(root, 0o750); err != nil {
		log.Fatal(err)
	}
	adminPassword := getenv("DEMO_ADMIN_PASSWORD", "change-me")
	s := &server{root: root, users: map[string]user{}, tokens: map[string]tokenRecord{}, refreshTokens: map[string]tokenRecord{}, authStateFile: getenv("AUTH_STATE_FILE", filepath.Join(root, ".auth-refresh.json")), uploads: map[string]*upload{}}
	s.loadRefreshTokens()
	s.users["admin"] = newUser("admin", adminPassword)
	mux := http.NewServeMux()
	mux.HandleFunc("/api/v2/health", s.health)
	mux.HandleFunc("/api/v2/auth/login", s.login)
	mux.HandleFunc("/api/v2/auth/refresh", s.refresh)
	mux.HandleFunc("/api/v2/auth/logout", s.logout)
	mux.HandleFunc("/api/v2/files", s.files)
	mux.HandleFunc("/api/v2/folders", s.folders)
	mux.HandleFunc("/api/v2/upload/sessions", s.createUpload)
	mux.HandleFunc("/api/v2/upload/", s.upload)
	mux.HandleFunc("/api/v2/files/", s.file)
	addr := getenv("FILE_API_ADDR", "127.0.0.1:8443")
	log.Printf("SE9 file API listening on %s, root=%s", addr, root)
	log.Fatal(http.ListenAndServe(addr, withJSON(mux)))
}

func (s *server) health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, 200, "0", "success", map[string]any{"status": "ok", "time": time.Now().UTC()})
}

func (s *server) login(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	var in struct{ Username, Account, Password string }
	if json.NewDecoder(r.Body).Decode(&in) != nil {
		errorJSON(w, 400, "invalid request")
		return
	}
	username := in.Username
	if username == "" {
		username = in.Account
	}
	u, ok := s.users[username]
	if !ok || !verifyPassword(u.PasswordHash, in.Password) {
		errorJSON(w, 401, "40101", "invalid credentials")
		return
	}
	s.mu.Lock()
	access, refresh := randomSecret(), randomSecret()
	now := time.Now()
	s.tokens[hashToken(access)] = tokenRecord{UserID: username, ExpiresAt: now.Add(accessTTL)}
	s.refreshTokens[hashToken(refresh)] = tokenRecord{UserID: username, ExpiresAt: now.Add(refreshTTL)}
	s.persistRefreshTokensLocked()
	s.mu.Unlock()
	writeJSON(w, 200, "0", "success", map[string]any{"user": map[string]string{"userId": username, "account": username}, "accessToken": access, "refreshToken": refresh, "expiresIn": int(accessTTL.Seconds())})
}

func (s *server) refresh(w http.ResponseWriter, r *http.Request) {
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
	s.mu.Lock()
	key := hashToken(in.RefreshToken)
	record, ok := s.refreshTokens[key]
	if !ok || time.Now().After(record.ExpiresAt) {
		s.mu.Unlock()
		errorJSON(w, 401, "40101", "refresh token expired")
		return
	}
	delete(s.refreshTokens, key)
	access, refresh := randomSecret(), randomSecret()
	now := time.Now()
	s.tokens[hashToken(access)] = tokenRecord{UserID: record.UserID, ExpiresAt: now.Add(accessTTL)}
	s.refreshTokens[hashToken(refresh)] = tokenRecord{UserID: record.UserID, ExpiresAt: now.Add(refreshTTL)}
	s.persistRefreshTokensLocked()
	s.mu.Unlock()
	writeJSON(w, 200, "0", "success", map[string]any{"accessToken": access, "refreshToken": refresh, "expiresIn": int(accessTTL.Seconds())})
}

func (s *server) logout(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	s.mu.Lock()
	delete(s.tokens, hashToken(bearerToken(r)))
	s.mu.Unlock()
	writeJSON(w, 200, "0", "success", map[string]any{})
}

func (s *server) files(w http.ResponseWriter, r *http.Request) {
	if !s.authorized(r) {
		errorJSON(w, 401, "unauthorized")
		return
	}
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	path, err := safePath(r.URL.Query().Get("path"))
	if err != nil {
		errorJSON(w, 400, err.Error())
		return
	}
	full, err := securePath(s.root, path, false)
	if err != nil {
		errorJSON(w, 400, err.Error())
		return
	}
	entries, err := os.ReadDir(full)
	if err != nil {
		errorJSON(w, 404, "directory not found")
		return
	}
	type item struct {
		Name      string    `json:"name"`
		Path      string    `json:"path"`
		Directory bool      `json:"directory"`
		Size      int64     `json:"size"`
		Modified  time.Time `json:"modified"`
	}
	out := make([]item, 0, len(entries))
	for _, e := range entries {
		info, _ := e.Info()
		p := filepath.ToSlash(filepath.Join(path, e.Name()))
		out = append(out, item{Name: e.Name(), Path: p, Directory: e.IsDir(), Size: info.Size(), Modified: info.ModTime()})
	}
	writeJSON(w, 200, map[string]any{"path": path, "items": out})
}

func (s *server) folders(w http.ResponseWriter, r *http.Request) {
	if !s.authorized(r) {
		errorJSON(w, 401, "unauthorized")
		return
	}
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	var in struct {
		Path string `json:"path"`
	}
	if json.NewDecoder(r.Body).Decode(&in) != nil {
		errorJSON(w, 400, "invalid request")
		return
	}
	p, err := safePath(in.Path)
	if err != nil || p == "." {
		errorJSON(w, 400, "invalid path")
		return
	}
	full, err := securePath(s.root, p, true)
	if err != nil {
		errorJSON(w, 400, err.Error())
		return
	}
	if err := os.MkdirAll(full, 0o750); err != nil {
		errorJSON(w, 500, err.Error())
		return
	}
	writeJSON(w, 201, map[string]string{"path": p})
}

func (s *server) createUpload(w http.ResponseWriter, r *http.Request) {
	if !s.authorized(r) {
		errorJSON(w, 401, "unauthorized")
		return
	}
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	var in struct {
		Path      string `json:"path"`
		Size      int64  `json:"size"`
		ChunkSize int64  `json:"chunkSize"`
		Overwrite bool   `json:"overwrite"`
	}
	if json.NewDecoder(r.Body).Decode(&in) != nil || in.Size <= 0 || in.Size > maxUploadSize {
		errorJSON(w, 400, "invalid request")
		return
	}
	p, err := safePath(in.Path)
	if err != nil || p == "." {
		errorJSON(w, 400, "invalid path")
		return
	}
	if in.ChunkSize <= 0 {
		in.ChunkSize = 8 * 1024 * 1024
	}
	if in.ChunkSize > maxChunkSize {
		errorJSON(w, 400, "chunk size exceeds limit")
		return
	}
	final, err := securePath(s.root, p, true)
	if err != nil {
		errorJSON(w, 400, err.Error())
		return
	}
	if _, statErr := os.Lstat(final); statErr == nil && !in.Overwrite {
		errorJSON(w, 409, "file already exists")
		return
	}
	id := randomString(16)
	totalChunks := int((in.Size + in.ChunkSize - 1) / in.ChunkSize)
	s.mu.Lock()
	s.uploads[id] = &upload{ID: id, Path: p, Size: in.Size, ChunkSize: in.ChunkSize, TotalChunks: totalChunks, Overwrite: in.Overwrite, Chunks: map[int]bool{}, Created: time.Now()}
	s.mu.Unlock()
	writeJSON(w, 201, map[string]any{"uploadId": id, "chunkSize": in.ChunkSize})
}

func (s *server) upload(w http.ResponseWriter, r *http.Request) {
	if !s.authorized(r) {
		errorJSON(w, 401, "unauthorized")
		return
	}
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	offset := 3
	if len(parts) > offset && parts[offset] == "sessions" {
		offset++
	}
	if len(parts) <= offset {
		errorJSON(w, 400, "invalid upload path")
		return
	}
	if len(parts) == offset+2 && parts[offset+1] == "complete" {
		s.completeUpload(w, r, parts[offset])
		return
	}
	if len(parts) != offset+3 || parts[offset+1] != "chunks" {
		errorJSON(w, 400, "invalid upload path")
		return
	}
	id, indexText := parts[offset], parts[offset+2]
	index, err := strconv.Atoi(indexText)
	if err != nil || index < 0 {
		errorJSON(w, 400, "invalid chunk index")
		return
	}
	s.mu.Lock()
	u, ok := s.uploads[id]
	s.mu.Unlock()
	if !ok {
		errorJSON(w, 404, "upload not found")
		return
	}
	if index >= u.TotalChunks {
		errorJSON(w, 400, "invalid chunk index")
		return
	}
	expected := u.ChunkSize
	if index == u.TotalChunks-1 {
		expected = u.Size - int64(index)*u.ChunkSize
	}
	if r.ContentLength != expected {
		errorJSON(w, 400, "invalid chunk length")
		return
	}
	tmpDir := filepath.Join(s.root, ".uploading", id)
	if err := os.MkdirAll(tmpDir, 0o750); err != nil {
		errorJSON(w, 500, err.Error())
		return
	}
	f, err := os.Create(filepath.Join(tmpDir, fmt.Sprintf("%08d.part", index)))
	if err != nil {
		errorJSON(w, 500, err.Error())
		return
	}
	_, copyErr := io.Copy(f, r.Body)
	closeErr := f.Close()
	if copyErr != nil || closeErr != nil {
		errorJSON(w, 500, "chunk write failed")
		return
	}
	s.mu.Lock()
	u.Chunks[index] = true
	s.mu.Unlock()
	writeJSON(w, 200, map[string]any{"uploadId": id, "chunk": index})
}

func (s *server) file(w http.ResponseWriter, r *http.Request) {
	if !s.authorized(r) {
		errorJSON(w, 401, "unauthorized")
		return
	}
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(parts) < 4 {
		errorJSON(w, 400, "invalid file path")
		return
	}
	p, err := safePath(strings.Join(parts[3:], "/"))
	if err != nil {
		errorJSON(w, 400, err.Error())
		return
	}
	full, err := securePath(s.root, p, false)
	if err != nil {
		errorJSON(w, 400, err.Error())
		return
	}
	switch r.Method {
	case http.MethodGet:
		info, statErr := os.Stat(full)
		if statErr != nil || info.IsDir() {
			errorJSON(w, 404, "file not found")
			return
		}
		w.Header().Set("Content-Type", mimeType(full))
		w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=%q", filepath.Base(full)))
		http.ServeFile(w, r, full)
	case http.MethodDelete:
		info, statErr := os.Lstat(full)
		if statErr != nil || info.IsDir() {
			errorJSON(w, 404, "file not found")
			return
		}
		if err := os.RemoveAll(full); err != nil {
			errorJSON(w, 500, err.Error())
			return
		}
		writeJSON(w, 200, map[string]string{"deleted": p})
	default:
		methodNotAllowed(w)
	}
}

func (s *server) completeUpload(w http.ResponseWriter, _ *http.Request, id string) {
	s.mu.Lock()
	u, ok := s.uploads[id]
	s.mu.Unlock()
	if !ok {
		errorJSON(w, 404, "upload not found")
		return
	}
	tmpDir := filepath.Join(s.root, ".uploading", id)
	final, err := securePath(s.root, u.Path, true)
	if err != nil {
		errorJSON(w, 400, err.Error())
		return
	}
	if _, statErr := os.Lstat(final); statErr == nil && !u.Overwrite {
		errorJSON(w, 409, "file already exists")
		return
	}
	if err := os.MkdirAll(filepath.Dir(final), 0o750); err != nil {
		errorJSON(w, 500, err.Error())
		return
	}
	out, err := os.Create(final)
	if err != nil {
		errorJSON(w, 500, err.Error())
		return
	}
	for i := 0; i < u.TotalChunks; i++ {
		part := filepath.Join(tmpDir, fmt.Sprintf("%08d.part", i))
		f, e := os.Open(part)
		if errors.Is(e, os.ErrNotExist) {
			errorJSON(w, 409, "missing upload chunk")
			out.Close()
			os.Remove(final)
			return
		}
		if e != nil {
			out.Close()
			errorJSON(w, 500, e.Error())
			return
		}
		if _, e = io.Copy(out, f); e != nil {
			f.Close()
			out.Close()
			errorJSON(w, 500, e.Error())
			return
		}
		f.Close()
	}
	out.Close()
	os.RemoveAll(tmpDir)
	s.mu.Lock()
	delete(s.uploads, id)
	s.mu.Unlock()
	writeJSON(w, 200, map[string]string{"path": u.Path})
}

func (s *server) authorized(r *http.Request) bool {
	token := bearerToken(r)
	s.mu.Lock()
	record, ok := s.tokens[hashToken(token)]
	s.mu.Unlock()
	return token != "" && ok && time.Now().Before(record.ExpiresAt)
}
func newUser(name, password string) user {
	return user{Name: name, PasswordHash: hashPassword(password)}
}
func randomString(n int) string {
	b := make([]byte, n)
	if _, e := rand.Read(b); e != nil {
		panic(e)
	}
	return hex.EncodeToString(b)[:n]
}
func safePath(p string) (string, error) {
	p = strings.TrimSpace(strings.ReplaceAll(p, "\\", "/"))
	if p == "" {
		return ".", nil
	}
	clean := filepath.Clean("/" + p)
	if clean == "/" {
		return ".", nil
	}
	if strings.Contains(clean, "..") {
		return "", errors.New("invalid path")
	}
	return strings.TrimPrefix(clean, "/"), nil
}

func securePath(root, relative string, allowMissing bool) (string, error) {
	full := filepath.Join(root, relative)
	rootAbs, err := filepath.Abs(root)
	if err != nil {
		return "", errors.New("invalid storage root")
	}
	if resolvedRoot, evalErr := filepath.EvalSymlinks(rootAbs); evalErr == nil {
		rootAbs = resolvedRoot
	}
	check := func(candidate string) error {
		candidateAbs, err := filepath.Abs(candidate)
		if err != nil {
			return errors.New("invalid path")
		}
		rel, err := filepath.Rel(rootAbs, candidateAbs)
		if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
			return errors.New("path escapes storage root")
		}
		return nil
	}
	if info, statErr := os.Lstat(full); statErr == nil {
		if info.Mode()&os.ModeSymlink != 0 {
			return "", errors.New("symbolic links are not allowed")
		}
		resolved, evalErr := filepath.EvalSymlinks(full)
		if evalErr != nil {
			return "", errors.New("invalid path")
		}
		if err := check(resolved); err != nil {
			return "", err
		}
		return full, nil
	} else if !allowMissing || !errors.Is(statErr, os.ErrNotExist) {
		return "", errors.New("path does not exist")
	}
	parent := filepath.Dir(full)
	for {
		if _, statErr := os.Lstat(parent); statErr == nil {
			break
		}
		next := filepath.Dir(parent)
		if next == parent {
			return "", errors.New("invalid parent path")
		}
		parent = next
	}
	resolvedParent, err := filepath.EvalSymlinks(parent)
	if err != nil {
		return "", errors.New("invalid parent path")
	}
	if err := check(resolvedParent); err != nil {
		return "", err
	}
	return full, nil
}

func mimeType(path string) string {
	if value := mime.TypeByExtension(filepath.Ext(path)); value != "" {
		return value
	}
	return "application/octet-stream"
}
func getenv(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
func withJSON(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		next.ServeHTTP(w, r)
	})
}
func methodNotAllowed(w http.ResponseWriter) { errorJSON(w, 405, "method not allowed") }
