package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func deviceListCloud(t *testing.T) *cloud {
	t.Helper()
	now := time.Now().UTC()
	return &cloud{
		devices: map[string]device{
			"a":         {ID: "a", Name: "Home", OwnerID: "owner", ClaimStatus: "claimed", Status: "online", LastSeen: now, DeviceTokenHash: "private-token", ClaimHash: "private-claim"},
			"b":         {ID: "b", Name: "Old heartbeat", OwnerID: "owner", ClaimStatus: "claimed", Status: "online", LastSeen: now.Add(-2 * time.Minute)},
			"c":         {ID: "c", Name: "Explicit offline", OwnerID: "owner", Status: "offline", LastSeen: now},
			"other":     {ID: "other", Name: "Someone else", OwnerID: "other", Status: "online", LastSeen: now},
			"unclaimed": {ID: "unclaimed", Status: "online", LastSeen: now},
		},
		accessTokens: map[string]tokenRecord{
			hashToken("owner-token"):   {UserID: "owner", ExpiresAt: now.Add(time.Hour)},
			hashToken("empty-token"):   {UserID: "empty", ExpiresAt: now.Add(time.Hour)},
			hashToken("expired-token"): {UserID: "owner", ExpiresAt: now.Add(-time.Hour)},
		},
	}
}

func TestDeviceListAuthorizationAndPagination(t *testing.T) {
	c := deviceListCloud(t)
	for _, path := range []string{"/api/v2/device_list", "/api/v2/devices"} {
		for _, tc := range []struct {
			name, token, method, query string
			status                     int
			ids                        []string
			total                      int
		}{
			{"owner", "owner-token", "GET", "", 200, []string{"a", "b", "c"}, 3},
			{"empty", "empty-token", "GET", "", 200, []string{}, 0},
			{"online", "owner-token", "GET", "?status=online", 200, []string{"a"}, 1},
			{"offline", "owner-token", "GET", "?status=offline", 200, []string{"b", "c"}, 2},
			{"page", "owner-token", "GET", "?page=2&pageSize=1", 200, []string{"b"}, 3},
			{"past end", "owner-token", "GET", "?page=9223372036854775807", 200, []string{}, 3},
			{"missing token", "", "GET", "", 401, nil, 0},
			{"expired token", "expired-token", "GET", "", 401, nil, 0},
			{"method", "owner-token", "POST", "", 405, nil, 0},
			{"bad page", "owner-token", "GET", "?page=0", 400, nil, 0},
			{"bad size", "owner-token", "GET", "?pageSize=101", 400, nil, 0},
			{"bad status", "owner-token", "GET", "?status=anything", 400, nil, 0},
		} {
			t.Run(path+"/"+tc.name, func(t *testing.T) {
				r := httptest.NewRequest(tc.method, path+tc.query, nil)
				if tc.token != "" {
					r.Header.Set("Authorization", "Bearer "+tc.token)
				}
				w := httptest.NewRecorder()
				c.handler().ServeHTTP(w, r)
				if w.Code != tc.status {
					t.Fatalf("status %d: %s", w.Code, w.Body.String())
				}
				if tc.status != 200 {
					return
				}
				var body struct {
					Code string
					Data struct {
						Items []boundDevice
						Total int
					}
				}
				if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
					t.Fatal(err)
				}
				if body.Code != "0" || body.Data.Total != tc.total || body.Data.Items == nil || len(body.Data.Items) != len(tc.ids) {
					t.Fatalf("unexpected envelope: %s", w.Body.String())
				}
				for i, id := range tc.ids {
					if body.Data.Items[i].ID != id || body.Data.Items[i].Role != "owner" {
						t.Fatalf("unexpected device: %+v", body.Data.Items[i])
					}
				}
				for _, secret := range []string{"private-token", "private-claim", "ownerId", "publicKey", "Someone else"} {
					if strings.Contains(w.Body.String(), secret) {
						t.Fatalf("leaked %s", secret)
					}
				}
			})
		}
	}
}

func TestOfflineSessionIsRejected(t *testing.T) {
	c := deviceListCloud(t)
	r := httptest.NewRequest(http.MethodPost, "/api/v2/sessions", strings.NewReader(`{"deviceId":"b"}`))
	r.Header.Set("Authorization", "Bearer owner-token")
	w := httptest.NewRecorder()
	c.handler().ServeHTTP(w, r)
	if w.Code != 409 || !strings.Contains(w.Body.String(), "40905") {
		t.Fatalf("offline session allowed: %s", w.Body.String())
	}
}
