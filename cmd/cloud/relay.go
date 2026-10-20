package main

import (
	"net/http"
	"sync"
	"time"

	"golang.org/x/net/websocket"
)

type relayPair struct {
	mu     sync.Mutex
	app    *websocket.Conn
	device *websocket.Conn
	ready  chan struct{}
	once   sync.Once
	start  sync.Once
}

func (p *relayPair) set(side string, conn *websocket.Conn) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if side == "app" {
		if p.app != nil {
			return false
		}
		p.app = conn
	} else {
		if p.device != nil {
			return false
		}
		p.device = conn
	}
	if p.app != nil && p.device != nil {
		p.once.Do(func() { close(p.ready) })
	}
	return true
}

func (c *cloud) relayApp(ws *websocket.Conn) {
	sessionID := ws.Request().URL.Query().Get("sessionId")
	token := bearerToken(ws.Request())
	c.mu.RLock()
	record, tokenOK := c.accessTokens[hashToken(token)]
	s, sessionOK := c.sessions[sessionID]
	c.mu.RUnlock()
	if token == "" || !tokenOK || time.Now().After(record.ExpiresAt) || !sessionOK || s.UserID != record.UserID || time.Now().After(s.Expires) {
		_ = websocket.Message.Send(ws, []byte("{\"type\":\"error\",\"code\":\"40101\",\"message\":\"relay authorization failed\"}"))
		_ = ws.Close()
		return
	}
	c.bridgeRelay(sessionID, "app", ws)
}

func (c *cloud) relayDevice(ws *websocket.Conn) {
	deviceID := ws.Request().URL.Query().Get("deviceId")
	token := ws.Request().Header.Get("X-Device-Token")
	c.mu.RLock()
	d, ok := c.devices[deviceID]
	c.mu.RUnlock()
	if !ok || token == "" || hashToken(token) != d.DeviceTokenHash {
		_ = websocket.Message.Send(ws, []byte("{\"type\":\"error\",\"code\":\"40101\",\"message\":\"device authorization failed\"}"))
		_ = ws.Close()
		return
	}
	c.mu.RLock()
	c.relayMu.Lock()
	var sessionID string
	for id, s := range c.sessions {
		pair := c.relayPairs[id]
		if s.DeviceID != deviceID || time.Now().After(s.Expires) || pair == nil {
			continue
		}
		pair.mu.Lock()
		available := pair.app != nil && pair.device == nil
		pair.mu.Unlock()
		if available {
			sessionID = id
			break
		}
	}
	c.relayMu.Unlock()
	c.mu.RUnlock()
	if sessionID == "" {
		_ = websocket.Message.Send(ws, []byte("{\"type\":\"error\",\"code\":\"40402\",\"message\":\"no active session\"}"))
		_ = ws.Close()
		return
	}
	c.bridgeRelay(sessionID, "device", ws)
}

func (c *cloud) bridgeRelay(sessionID, side string, conn *websocket.Conn) {
	c.relayMu.Lock()
	pair := c.relayPairs[sessionID]
	if pair == nil {
		pair = &relayPair{ready: make(chan struct{})}
		c.relayPairs[sessionID] = pair
	}
	if !pair.set(side, conn) {
		c.relayMu.Unlock()
		_ = conn.Close()
		return
	}
	c.relayMu.Unlock()
	select {
	case <-pair.ready:
		pair.start.Do(func() {
			c.forward(sessionID, pair.app, pair.device)
			c.relayMu.Lock()
			delete(c.relayPairs, sessionID)
			c.relayMu.Unlock()
			c.mu.Lock()
			delete(c.sessions, sessionID)
			c.persistStateLocked()
			c.mu.Unlock()
		})
	case <-time.After(30 * time.Second):
		_ = conn.Close()
		c.relayMu.Lock()
		delete(c.relayPairs, sessionID)
		c.relayMu.Unlock()
	}
}

func (c *cloud) forward(sessionID string, app, device *websocket.Conn) {
	if attach, required, ok := c.rtcRelayContext(sessionID); required {
		if !ok {
			_ = app.Close()
			_ = device.Close()
			return
		}
		_ = device.SetWriteDeadline(time.Now().Add(10 * time.Second))
		if websocket.JSON.Send(device, attach) != nil {
			_ = app.Close()
			_ = device.Close()
			return
		}
		_ = device.SetReadDeadline(time.Now().Add(10 * time.Second))
		var ack struct {
			Type string `json:"type"`
		}
		if websocket.JSON.Receive(device, &ack) != nil || ack.Type != "relay.attached" {
			_ = app.Close()
			_ = device.Close()
			return
		}
		_ = device.SetReadDeadline(time.Time{})
		_ = device.SetWriteDeadline(time.Time{})
	}

	var wg sync.WaitGroup
	wg.Add(2)
	copyFrames := func(dst, src *websocket.Conn) {
		defer wg.Done()
		defer app.Close()
		defer device.Close()
		for {
			var payload []byte
			if err := websocket.Message.Receive(src, &payload); err != nil {
				return
			}
			if err := websocket.Message.Send(dst, payload); err != nil {
				return
			}
		}
	}
	go copyFrames(device, app)
	go copyFrames(app, device)
	wg.Wait()
	_ = app.Close()
	_ = device.Close()
}

func (c *cloud) relayEndpoint(side string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c.mu.RLock()
		valid := false
		if side == "app" {
			record, ok := c.accessTokens[hashToken(bearerToken(r))]
			session, exists := c.sessions[r.URL.Query().Get("sessionId")]
			valid = ok && exists && time.Now().Before(record.ExpiresAt) && time.Now().Before(session.Expires) && record.UserID == session.UserID
		} else {
			device, exists := c.devices[r.URL.Query().Get("deviceId")]
			token := r.Header.Get("X-Device-Token")
			valid = exists && token != "" && hashToken(token) == device.DeviceTokenHash
		}
		c.mu.RUnlock()
		if !valid {
			errorJSON(w, 401, "40101", "relay authorization failed")
			return
		}
		handler := c.relayApp
		if side == "device" {
			handler = c.relayDevice
		}
		server := websocket.Server{Handler: websocket.Handler(handler)}
		server.ServeHTTP(w, r)
	})
}
