package main

import (
	"net/http"
	"sort"
	"strconv"
	"time"
)

type boundDevice struct {
	ID           string         `json:"deviceId"`
	Name         string         `json:"name"`
	Status       string         `json:"status"`
	ClaimStatus  string         `json:"claimStatus"`
	Role         string         `json:"role"`
	LastSeen     time.Time      `json:"lastSeen"`
	Capabilities map[string]any `json:"capabilities,omitempty"`
}

func deviceStatus(d device, now time.Time) string {
	if d.Status == "offline" || d.LastSeen.IsZero() || now.Sub(d.LastSeen) > 90*time.Second {
		return "offline"
	}
	return "online"
}

func (c *cloud) deviceList(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	page, pageSize := 1, 20
	for key, target := range map[string]*int{"page": &page, "pageSize": &pageSize} {
		if value := r.URL.Query().Get(key); value != "" {
			number, err := strconv.Atoi(value)
			if err != nil || number < 1 || (key == "pageSize" && number > 100) {
				errorJSON(w, 400, "40002", "invalid pagination")
				return
			}
			*target = number
		}
	}
	status := r.URL.Query().Get("status")
	if status != "" && status != "online" && status != "offline" {
		errorJSON(w, 400, "40002", "invalid device status")
		return
	}
	now := time.Now()
	items := make([]boundDevice, 0)
	c.mu.RLock()
	for _, d := range c.devices {
		if d.OwnerID != currentUserID(r) || d.OwnerID == "" {
			continue
		}
		currentStatus := deviceStatus(d, now)
		if status != "" && status != currentStatus {
			continue
		}
		items = append(items, boundDevice{ID: d.ID, Name: d.Name, Status: currentStatus, ClaimStatus: d.ClaimStatus, Role: "owner", LastSeen: d.LastSeen})
	}
	c.mu.RUnlock()
	for i := range items {
		if c.rtcAvailable(items[i].ID) {
			items[i].Capabilities = map[string]any{"fileTransferTransports": []string{"webrtc", "legacy"}, "fileTransferProtocolVersions": []int{1}}
		}
	}
	sort.Slice(items, func(i, j int) bool { return items[i].ID < items[j].ID })
	total := len(items)
	if page > total/pageSize+1 {
		items = []boundDevice{}
	} else {
		start := (page - 1) * pageSize
		end := start + pageSize
		if end > total {
			end = total
		}
		items = items[start:end]
	}
	writeJSON(w, http.StatusOK, "0", "success", map[string]any{"items": items, "page": page, "pageSize": pageSize, "total": total})
}
