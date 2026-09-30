package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"html/template"
	"io"
	"log"
	"math"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/Fortunehack45/Vibra_Music/backend/clock"
	"github.com/Fortunehack45/Vibra_Music/backend/codes"
	"github.com/Fortunehack45/Vibra_Music/backend/config"
	"github.com/Fortunehack45/Vibra_Music/backend/hub"
	"github.com/Fortunehack45/Vibra_Music/backend/party"
	"github.com/Fortunehack45/Vibra_Music/backend/preview"
	"github.com/Fortunehack45/Vibra_Music/backend/protocol"
)

type previewCacheItem struct {
	bytes []byte
	genAt time.Time
}

var (
	store          = party.NewPartyStore()
	hubInst        = hub.NewHub()
	createLimiter  = newIPRateLimiter(time.Minute, config.CreateRatePerMinute, config.RateLimitMaxEntries)
	joinLimiter    = newIPRateLimiter(time.Minute, 30, config.RateLimitMaxEntries)
	previewLimiter = newIPRateLimiter(time.Minute, 40, config.RateLimitMaxEntries)
	wsLimiter      = newIPRateLimiter(time.Minute, 60, config.RateLimitMaxEntries)
	imageLimiter   = newIPRateLimiter(time.Minute, 30, config.RateLimitMaxEntries)
	previewCache   = make(map[string]previewCacheItem)
	previewCacheMu sync.Mutex
	upgrader       = websocket.Upgrader{
		CheckOrigin: func(r *http.Request) bool {
			origin := r.Header.Get("Origin")
			return origin == "" || config.IsAllowedOrigin(origin)
		},
	}
)

func getCachedPreviewCard(key string) []byte {
	previewCacheMu.Lock()
	defer previewCacheMu.Unlock()
	item, ok := previewCache[key]
	if ok && time.Since(item.genAt) < 2*time.Minute {
		return item.bytes
	}
	return nil
}

func setCachedPreviewCard(key string, b []byte) {
	previewCacheMu.Lock()
	defer previewCacheMu.Unlock()
	if len(previewCache) > 100 {
		now := time.Now()
		for k, v := range previewCache {
			if now.Sub(v.genAt) > 5*time.Minute {
				delete(previewCache, k)
			}
		}
	}
	previewCache[key] = previewCacheItem{bytes: b, genAt: time.Now()}
}

func main() {
	go startHeartbeatTicker()

	mux := http.NewServeMux()

	// REST endpoints
	mux.HandleFunc("GET /{$}", handleRoot)
	mux.HandleFunc("GET /healthz", handleHealthz)
	mux.HandleFunc("GET /api/time", handleTime)
	mux.HandleFunc("POST /api/parties", handleCreateParty)
	mux.HandleFunc("POST /api/parties/{code}/join", handleJoinParty)
	mux.HandleFunc("GET /api/parties/{code}", handleGetParty)
	mux.HandleFunc("GET /api/parties/{code}/preview", handlePreviewParty)
	mux.HandleFunc("POST /api/parties/{code}/leave", handleLeaveParty)

	// Web invite endpoint & social preview card
	mux.HandleFunc("GET /invite/{code}", handleInviteLanding)
	mux.HandleFunc("GET /invite/{code}/preview", handleInvitePreviewImage)
	mux.HandleFunc("GET /invite/{code}/preview.png", handleInvitePreviewImage)

	// Digital Asset Links for Android App Links autoVerify
	mux.HandleFunc("GET /.well-known/assetlinks.json", handleAssetLinks)

	// Favicon for browser tabs and invite pages
	mux.HandleFunc("GET /favicon.ico", handleFavicon)

	// WebSocket endpoint
	mux.HandleFunc("GET /ws/parties/{code}", handleWebSocket)

	handler := corsMiddleware(mux)

	addr := fmt.Sprintf("0.0.0.0:%d", config.Port)
	log.Printf("Vibra Music Listen Together (Go) starting on %s...", addr)
	server := &http.Server{
		Addr:              addr,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       20 * time.Second,
		WriteTimeout:      20 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	if err := server.ListenAndServe(); err != nil {
		log.Fatalf("Server stopped: %v", err)
	}
}

func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if origin != "" && config.IsAllowedOrigin(origin) {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Vary", "Origin")
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
		}
		if r.Method == "OPTIONS" {
			if origin != "" && !config.IsAllowedOrigin(origin) {
				http.Error(w, "origin not allowed", http.StatusForbidden)
				return
			}
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

type ipRateLimiter struct {
	mu      sync.Mutex
	window  time.Duration
	limit   int
	maxKeys int
	entries map[string]ipRateEntry
}

type ipRateEntry struct {
	started time.Time
	count   int
}

func newIPRateLimiter(window time.Duration, limit, maxKeys int) *ipRateLimiter {
	return &ipRateLimiter{window: window, limit: limit, maxKeys: maxKeys, entries: make(map[string]ipRateEntry)}
}

func (l *ipRateLimiter) Allow(ip string) bool {
	if l.limit <= 0 {
		return true
	}
	now := time.Now()
	l.mu.Lock()
	defer l.mu.Unlock()
	for key, entry := range l.entries {
		if now.Sub(entry.started) >= l.window {
			delete(l.entries, key)
		}
	}
	entry := l.entries[ip]
	if entry.started.IsZero() || now.Sub(entry.started) >= l.window {
		if entry.started.IsZero() && l.maxKeys > 0 && len(l.entries) >= l.maxKeys {
			return false
		}
		l.entries[ip] = ipRateEntry{started: now, count: 1}
		return true
	}
	if entry.count >= l.limit {
		return false
	}
	entry.count++
	l.entries[ip] = entry
	return true
}

func clientIP(r *http.Request) string {
	if config.TrustProxy {
		if realIP := strings.TrimSpace(r.Header.Get("X-Real-IP")); realIP != "" {
			return realIP
		}
		if cfIP := strings.TrimSpace(r.Header.Get("CF-Connecting-IP")); cfIP != "" {
			return cfIP
		}
		if forwarded := r.Header.Get("X-Forwarded-For"); forwarded != "" {
			parts := strings.Split(forwarded, ",")
			if len(parts) > 0 {
				client := strings.TrimSpace(parts[0])
				if client != "" {
					return client
				}
			}
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil {
		return host
	}
	return r.RemoteAddr
}

func decodeJSONBody(w http.ResponseWriter, r *http.Request, dst interface{}) bool {
	r.Body = http.MaxBytesReader(w, r.Body, config.RequestMaxBytes)
	defer r.Body.Close()
	decoder := json.NewDecoder(r.Body)
	if err := decoder.Decode(dst); err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			jsonError(w, http.StatusRequestEntityTooLarge, "request_too_large", "Request body is too large.")
		} else {
			jsonError(w, http.StatusUnprocessableEntity, "invalid_json", "Malformed JSON body.")
		}
		return false
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		jsonError(w, http.StatusUnprocessableEntity, "invalid_json", "Request body must contain one JSON object.")
		return false
	}
	return true
}

func jsonResponse(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(data)
}

func jsonError(w http.ResponseWriter, status int, errCode, msg string) {
	jsonResponse(w, status, map[string]string{
		"error":   errCode,
		"message": msg,
	})
}

func parseBearerToken(r *http.Request) string {
	auth := r.Header.Get("Authorization")
	parts := strings.SplitN(auth, " ", 2)
	if len(parts) == 2 && strings.EqualFold(parts[0], "Bearer") {
		return strings.TrimSpace(parts[1])
	}
	return ""
}

// REST Handlers

func handleRoot(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	jsonResponse(w, http.StatusOK, map[string]interface{}{
		"service":    "vibra-listen-together",
		"maxMembers": config.MaxMembers,
		"parties":    store.Len(),
		"serverMs":   clock.NowMs(),
	})
}

func handleHealthz(w http.ResponseWriter, r *http.Request) {
	jsonResponse(w, http.StatusOK, map[string]interface{}{
		"ok":       true,
		"serverMs": clock.NowMs(),
	})
}

func handleTime(w http.ResponseWriter, r *http.Request) {
	jsonResponse(w, http.StatusOK, map[string]interface{}{
		"serverMs": clock.NowMs(),
	})
}

func handleFavicon(w http.ResponseWriter, r *http.Request) {
	icon := preview.AppIconBytes()
	if len(icon) == 0 {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "public, max-age=86400, immutable")
	w.Write(icon)
}

func handleCreateParty(w http.ResponseWriter, r *http.Request) {
	if !createLimiter.Allow(clientIP(r)) {
		jsonError(w, http.StatusTooManyRequests, "create_rate_limited", "The party server is rate-limited. Please try again shortly.")
		return
	}
	var req protocol.JoinRequest
	if !decodeJSONBody(w, r, &req) {
		return
	}
	if err := req.Validate(); err != nil {
		jsonError(w, http.StatusUnprocessableEntity, "validation_error", err.Error())
		return
	}

	maxMembers := 5
	if req.MaxMembers != nil { maxMembers = *req.MaxMembers }
	p, err := store.CreateWithLimits(config.MaxParties, maxMembers)
	if err != nil {
		if pe, ok := err.(*party.PartyError); ok {
			jsonError(w, pe.Status, pe.Code, pe.Message)
			return
		}
		jsonError(w, http.StatusInternalServerError, "server_error", "Failed to create party.")
		return
	}
	// This must be present in the creation response. Waiting for the first
	// WebSocket control can lose the setting before that socket is established.
	if req.AutoplayEnabled != nil {
		p.Playback.AutoplayEnabled = *req.AutoplayEnabled
	}

	p.Lock()
	m, err := p.Join(req.UserId, req.DeviceId, req.DisplayName, req.AvatarUrl)
	if err != nil {
		p.Unlock()
		store.Drop(p.Code)
		if pe, ok := err.(*party.PartyError); ok {
			jsonError(w, pe.Status, pe.Code, pe.Message)
			return
		}
		jsonError(w, http.StatusInternalServerError, "server_error", err.Error())
		return
	}
	if req.InitialTrack != nil && req.InitialTrack.Title != "" {
		p.Playback.SetTrack(
			&m.MemberId,
			&party.Track{
				VideoId:      req.InitialTrack.VideoId,
				Title:        req.InitialTrack.Title,
				Artist:       req.InitialTrack.Artist,
				ThumbnailUrl: req.InitialTrack.ThumbnailUrl,
				DurationMs:   req.InitialTrack.DurationMs,
			},
			0,
			true,
			nil,
			&m.DisplayName,
		)
	}
	partyWire := p.ToWire()
	youWire := m.ToWire()
	token := m.Token
	code := p.Code
	p.Unlock()
	store.Save()

	jsonResponse(w, http.StatusCreated, map[string]interface{}{
		"code":  code,
		"token": token,
		"you":   youWire,
		"party": partyWire,
	})
}

func handleJoinParty(w http.ResponseWriter, r *http.Request) {
	if !joinLimiter.Allow(clientIP(r)) {
		jsonError(w, http.StatusTooManyRequests, "join_rate_limited", "Too many join attempts. Please try again shortly.")
		return
	}
	code := r.PathValue("code")
	var req protocol.JoinRequest
	if !decodeJSONBody(w, r, &req) {
		return
	}
	if err := req.Validate(); err != nil {
		jsonError(w, http.StatusUnprocessableEntity, "validation_error", err.Error())
		return
	}

	p, err := store.Get(code)
	if err != nil {
		if pe, ok := err.(*party.PartyError); ok {
			jsonError(w, pe.Status, pe.Code, pe.Message)
			return
		}
		jsonError(w, http.StatusNotFound, "no_such_party", "No party with that code.")
		return
	}

	p.Lock()
	m, err := p.Join(req.UserId, req.DeviceId, req.DisplayName, req.AvatarUrl)
	if err != nil {
		p.Unlock()
		if pe, ok := err.(*party.PartyError); ok {
			jsonError(w, pe.Status, pe.Code, pe.Message)
			return
		}
		jsonError(w, http.StatusInternalServerError, "server_error", err.Error())
		return
	}
	partyWire := p.ToWire()
	youWire := m.ToWire()
	token := m.Token
	pCode := p.Code
	p.Unlock()
	store.Save()

	jsonResponse(w, http.StatusOK, map[string]interface{}{
		"code":  pCode,
		"token": token,
		"you":   youWire,
		"party": partyWire,
	})
}

// handlePreviewParty answers who is in a party, without a token and without
// joining it.
//
// Deliberately unauthenticated to let users see who started a party before joining.
// Protected by rate limiting and privacy bounds (at most 3 avatars disclosed to prevent scraping).
func handlePreviewParty(w http.ResponseWriter, r *http.Request) {
	if !previewLimiter.Allow(clientIP(r)) {
		jsonError(w, http.StatusTooManyRequests, "preview_rate_limited", "Too many preview requests. Please try again shortly.")
		return
	}
	code := r.PathValue("code")
	p, err := store.Get(code)
	if err != nil {
		if pe, ok := err.(*party.PartyError); ok {
			jsonError(w, pe.Status, pe.Code, pe.Message)
			return
		}
		jsonError(w, http.StatusNotFound, "no_such_party", "No party with that code.")
		return
	}

	p.Lock()
	// Joined order, as the snapshot uses: the caller draws the first few faces
	// and counts the rest, so which faces those are must not change between two
	// reads of an unchanged party.
	ordered := make([]*party.Member, 0, len(p.Members))
	for _, m := range p.Members {
		ordered = append(ordered, m)
	}
	sort.Slice(ordered, func(i, j int) bool {
		return ordered[i].JoinedAtMs < ordered[j].JoinedAtMs
	})
	members := make([]map[string]interface{}, 0, len(ordered))
	hostName := ""
	for i, m := range ordered {
		var avatar *string
		// Privacy guard: Only disclose avatars for the first 3 members to prevent mass scraping
		if i < 3 {
			avatar = m.AvatarUrl
		}
		members = append(members, map[string]interface{}{
			"displayName": m.DisplayName,
			"avatarUrl":   avatar,
			"isHost":      m.IsHost,
		})
		if m.IsHost {
			hostName = m.DisplayName
		}
	}
	preview := map[string]interface{}{
		"code":        p.Code,
		"hostName":    hostName,
		"memberCount": len(p.Members),
		"maxMembers":  p.MaxMembers,
		"isFull":      len(p.Members) >= p.MaxMembers,
		"members":     members,
	}
	p.Unlock()

	jsonResponse(w, http.StatusOK, preview)
}

func handleGetParty(w http.ResponseWriter, r *http.Request) {
	code := r.PathValue("code")
	token := parseBearerToken(r)
	if token == "" {
		jsonError(w, http.StatusUnauthorized, "unauthorized", "Missing bearer token.")
		return
	}

	p, err := store.Get(code)
	if err != nil {
		if pe, ok := err.(*party.PartyError); ok {
			jsonError(w, pe.Status, pe.Code, pe.Message)
			return
		}
		jsonError(w, http.StatusNotFound, "no_such_party", "No party with that code.")
		return
	}

	p.Lock()
	_, err = p.Authenticate(token)
	if err != nil {
		p.Unlock()
		if pe, ok := err.(*party.PartyError); ok {
			jsonError(w, pe.Status, pe.Code, pe.Message)
			return
		}
		jsonError(w, http.StatusUnauthorized, "unauthorized", "Bad token.")
		return
	}
	partyWire := p.ToWire()
	p.Unlock()

	jsonResponse(w, http.StatusOK, partyWire)
}

func handleLeaveParty(w http.ResponseWriter, r *http.Request) {
	code := r.PathValue("code")
	token := parseBearerToken(r)
	if token == "" {
		jsonError(w, http.StatusUnauthorized, "unauthorized", "Missing bearer token.")
		return
	}

	p, err := store.Get(code)
	if err != nil {
		if pe, ok := err.(*party.PartyError); ok {
			jsonError(w, pe.Status, pe.Code, pe.Message)
			return
		}
		jsonError(w, http.StatusNotFound, "no_such_party", "No party with that code.")
		return
	}

	p.Lock()
	member, err := p.Authenticate(token)
	if err != nil {
		p.Unlock()
		if pe, ok := err.(*party.PartyError); ok {
			jsonError(w, pe.Status, pe.Code, pe.Message)
			return
		}
		jsonError(w, http.StatusUnauthorized, "unauthorized", "Bad token.")
		return
	}

	memberId := member.MemberId
	p.Remove(memberId)
	membersFrame := membersFrame(p)
	p.Unlock()

	// Notify room and drop leaving member socket
	hubInst.Send(p.Code, memberId, map[string]interface{}{
		"type":   protocol.FrameBye,
		"reason": "left",
	})
	hubInst.Broadcast(p.Code, membersFrame, memberId)

	jsonResponse(w, http.StatusOK, map[string]bool{"ok": true})
}

// Web Invite Landing Handler

type invitePageData struct {
	Code              string
	DeepLink          string
	IntentURI         template.URL
	SafeDeepLink      template.URL
	ServerOrigin      string
	HostName          string
	HostAvatarUrl     string
	CurrentSongTitle  string
	CurrentSongArtist string
	CurrentSongThumb  string
	PreviewImgURL     string
	MemberCount       int
	MaxMembers        int
	IsActive          bool
}

var inviteTemplate = template.Must(template.New("invite").Parse(`<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{{if .HostName}}Join {{.HostName}}'s Party{{else}}Vibra Music Listen Together{{end}} - {{.Code}}</title>
    
    <!-- Open Graph / WhatsApp / Telegram / Discord Preview Metadata -->
    <meta property="og:type" content="music.song">
    <meta property="og:site_name" content="Vibra Music">
    <meta property="og:title" content="Join {{if .HostName}}{{.HostName}}'s{{else}}a{{end}} Party on Vibra Music">
    <meta property="og:description" content="Party {{.Code}} • {{if .CurrentSongTitle}}Now Playing: {{.CurrentSongTitle}} by {{.CurrentSongArtist}} • {{end}}{{if .IsActive}}{{.MemberCount}} listening in real time{{else}}Listen together in real time{{end}}">
    <meta property="og:url" content="{{.ServerOrigin}}/invite/{{.Code}}">
    <meta property="og:image" content="{{.PreviewImgURL}}">
    <meta property="og:image:secure_url" content="{{.PreviewImgURL}}">
    <meta property="og:image:type" content="image/png">
    <meta property="og:image:width" content="834">
    <meta property="og:image:height" content="1024">
    <link rel="image_src" href="{{.PreviewImgURL}}">
    
    <!-- Twitter Card -->
    <meta name="twitter:card" content="summary_large_image">
    <meta name="twitter:title" content="Join {{if .HostName}}{{.HostName}}'s{{else}}a{{end}} Party on Vibra Music">
    <meta name="twitter:description" content="Party {{.Code}} • {{if .CurrentSongTitle}}Now Playing: {{.CurrentSongTitle}} by {{.CurrentSongArtist}} • {{end}}Real-time synchronized playback on Vibra Music">
    <meta name="twitter:image" content="{{.PreviewImgURL}}">
    <meta name="twitter:image:src" content="{{.PreviewImgURL}}">

    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            background-color: #0b0b12;
            color: #f3f3f7;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 24px;
            background-image: 
                radial-gradient(circle at 15% 15%, rgba(124, 77, 255, 0.12) 0%, transparent 40%),
                radial-gradient(circle at 85% 85%, rgba(61, 90, 254, 0.12) 0%, transparent 40%);
        }
        .container {
            background: rgba(22, 22, 34, 0.88);
            backdrop-filter: blur(28px);
            -webkit-backdrop-filter: blur(28px);
            border: 1px solid rgba(255, 255, 255, 0.08);
            border-radius: 32px;
            max-width: 450px;
            width: 100%;
            padding: 36px 30px;
            text-align: center;
            box-shadow: 0 24px 60px rgba(0, 0, 0, 0.6), 0 0 50px rgba(124, 77, 255, 0.12);
        }
        .brand-header {
            display: flex;
            align-items: center;
            justify-content: space-between;
            margin-bottom: 24px;
            padding-bottom: 16px;
            border-bottom: 1px solid rgba(255, 255, 255, 0.06);
        }
        .brand-logo-group {
            display: flex;
            align-items: center;
            gap: 10px;
        }
        .brand-logo {
            width: 32px;
            height: 32px;
            border-radius: 10px;
            background: linear-gradient(135deg, #7c4dff, #3d5afe);
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 16px;
            box-shadow: 0 4px 12px rgba(124, 77, 255, 0.4);
        }
        .brand-title {
            font-size: 16px;
            font-weight: 700;
            letter-spacing: -0.3px;
            color: #ffffff;
        }
        .badge {
            display: inline-flex;
            align-items: center;
            gap: 6px;
            background: rgba(124, 77, 255, 0.16);
            color: #b388ff;
            font-size: 12px;
            font-weight: 600;
            padding: 5px 12px;
            border-radius: 9999px;
            letter-spacing: 0.3px;
        }
        .badge-dot {
            width: 8px;
            height: 8px;
            background: #00e676;
            border-radius: 50%;
            box-shadow: 0 0 8px #00e676;
        }
        .badge-dot.offline {
            background: #ff5252;
            box-shadow: 0 0 8px #ff5252;
        }
        .avatar-wrap {
            position: relative;
            width: 96px;
            height: 96px;
            margin: 0 auto 16px;
        }
        .host-avatar {
            width: 96px;
            height: 96px;
            border-radius: 50%;
            object-fit: cover;
            border: 3px solid #7c4dff;
            box-shadow: 0 0 20px rgba(124, 77, 255, 0.5);
        }
        .fallback-avatar {
            width: 96px;
            height: 96px;
            border-radius: 50%;
            background: linear-gradient(135deg, #7c4dff, #3d5afe);
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 38px;
            font-weight: 800;
            color: #ffffff;
            box-shadow: 0 0 20px rgba(124, 77, 255, 0.5);
            margin: 0 auto 16px;
        }
        h1 {
            font-size: 22px;
            font-weight: 700;
            margin-bottom: 6px;
            letter-spacing: -0.4px;
        }
        .subtitle {
            color: #9e9ea7;
            font-size: 14px;
            line-height: 1.5;
            margin-bottom: 24px;
        }
        .song-card {
            display: flex;
            align-items: center;
            gap: 12px;
            background: rgba(255, 255, 255, 0.05);
            border: 1px solid rgba(255, 255, 255, 0.08);
            border-radius: 16px;
            padding: 12px 14px;
            margin-bottom: 20px;
            text-align: left;
        }
        .song-thumb {
            width: 44px;
            height: 44px;
            border-radius: 10px;
            object-fit: cover;
            background: #20202e;
        }
        .song-info {
            flex: 1;
            min-width: 0;
        }
        .song-title {
            font-size: 14px;
            font-weight: 600;
            color: #ffffff;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }
        .song-artist {
            font-size: 12px;
            color: #a0a0ab;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }
        .code-box {
            background: rgba(255, 255, 255, 0.04);
            border: 1px solid rgba(255, 255, 255, 0.1);
            border-radius: 18px;
            padding: 14px 20px;
            margin-bottom: 24px;
        }
        .code-label {
            font-size: 11px;
            color: #71717a;
            text-transform: uppercase;
            letter-spacing: 1.5px;
            margin-bottom: 4px;
        }
        .code-val {
            font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
            font-size: 32px;
            font-weight: 800;
            letter-spacing: 6px;
            color: #ffffff;
        }
        .btn {
            display: block;
            width: 100%;
            padding: 16px 24px;
            background: linear-gradient(135deg, #7c4dff 0%, #3d5afe 100%);
            color: #ffffff;
            font-size: 16px;
            font-weight: 600;
            text-decoration: none;
            border-radius: 16px;
            border: none;
            cursor: pointer;
            transition: transform 0.15s ease, opacity 0.15s ease;
            box-shadow: 0 8px 24px rgba(124, 77, 255, 0.35);
        }
        .btn:hover {
            transform: translateY(-1px);
            opacity: 0.95;
        }
        .btn:active {
            transform: scale(0.98);
        }
        .footer-note {
            margin-top: 22px;
            font-size: 13px;
            color: #71717a;
            line-height: 1.5;
        }
        .footer-note a {
            color: #b388ff;
            text-decoration: none;
        }
        .footer-note a:hover {
            text-decoration: underline;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="brand-header">
            <div class="brand-logo-group">
                <div class="brand-logo">🎵</div>
                <div class="brand-title">Vibra Music</div>
            </div>
            {{if .IsActive}}
                <div class="badge">
                    <span class="badge-dot"></span>
                    <span>{{.MemberCount}} in party</span>
                </div>
            {{else}}
                <div class="badge">
                    <span class="badge-dot offline"></span>
                    <span>Inactive</span>
                </div>
            {{end}}
        </div>

        {{if .IsActive}}
            {{if .HostAvatarUrl}}
                <div class="avatar-wrap">
                    <img src="{{.HostAvatarUrl}}" class="host-avatar" alt="{{.HostName}}" />
                </div>
            {{else}}
                <div class="fallback-avatar">
                    {{if .HostName}}{{.HostName | printf "%.1s"}}{{else}}V{{end}}
                </div>
            {{end}}

            <h1>{{if .HostName}}{{.HostName}}{{else}}Host{{end}} invited you</h1>
            <p class="subtitle">Listen together in real time on Vibra Music.</p>

            {{if .CurrentSongTitle}}
                <div class="song-card">
                    {{if .CurrentSongThumb}}
                        <img src="{{.CurrentSongThumb}}" class="song-thumb" alt="Track thumbnail" />
                    {{else}}
                        <div class="song-thumb" style="display:flex;align-items:center;justify-content:center;">🎵</div>
                    {{end}}
                    <div class="song-info">
                        <div class="song-title">{{.CurrentSongTitle}}</div>
                        <div class="song-artist">{{.CurrentSongArtist}}</div>
                    </div>
                </div>
            {{end}}

            <div class="code-box">
                <div class="code-label">Party Code</div>
                <div class="code-val">{{.Code}}</div>
            </div>

            <a id="joinBtn" href="{{.IntentURI}}" class="btn">Join Party in Vibra Music</a>
            <p class="footer-note">
                Didn’t open automatically? Tap the button above.<br>
                Don't have Vibra Music yet? <a href="https://github.com/Fortunehack45/Vibra_Music_Releases/releases" target="_blank" rel="noopener">Download APK here</a>.<br>
                <a href="https://t.me/vibramusictg" target="_blank" rel="noopener">Telegram</a> · <a href="https://fortuneadebayo.space/" target="_blank" rel="noopener">Website</a> · <a href="https://x.com/OnNerd_eth" target="_blank" rel="noopener">Developer</a>
            </p>
            <script>
                var intentUri = {{.IntentURI}};
                var deepLink = {{.SafeDeepLink}};
                function launch() {
                    if (/Android/i.test(navigator.userAgent)) {
                        window.location.href = intentUri;
                    } else {
                        window.location.href = deepLink;
                    }
                }
                setTimeout(launch, 100);
            </script>
        {{else}}
            <div class="fallback-avatar" style="background:#2a2a38;">✕</div>
            <h1>Party Not Found</h1>
            <p class="subtitle">This party code has expired or does not exist on this server.</p>
            <div class="code-box">
                <div class="code-label">Party Code</div>
                <div class="code-val" style="color: #a1a1aa;">{{.Code}}</div>
            </div>
            <p class="footer-note">
                Please ask the host for a new invite link.
            </p>
        {{end}}
    </div>
</body>
</html>`))

func requestOrigin(r *http.Request) string {
	if config.PublicOrigin != "" {
		return config.PublicOrigin
	}
	proto := "http"
	if r.TLS != nil {
		proto = "https"
	}
	if config.TrustProxy {
		if forwardedProto := r.Header.Get("X-Forwarded-Proto"); forwardedProto != "" {
			p := strings.ToLower(strings.TrimSpace(strings.Split(forwardedProto, ",")[0]))
			if p == "https" || p == "http" {
				proto = p
			}
		}
	}
	host := r.Host
	if host == "" || !config.IsAllowedHost(host) {
		host = "party.vibramusic.store"
	}
	return fmt.Sprintf("%s://%s", proto, host)
}

func handleInviteLanding(w http.ResponseWriter, r *http.Request) {
	code := codes.Normalise(r.PathValue("code"))
	origin := requestOrigin(r)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")

	if len(code) != codes.CodeLength {
		w.WriteHeader(http.StatusOK)
		_ = inviteTemplate.Execute(w, invitePageData{
			Code:          html.EscapeString(r.PathValue("code")),
			ServerOrigin:  origin,
			PreviewImgURL: fmt.Sprintf("%s/invite/%s/preview.png", origin, url.PathEscape(r.PathValue("code"))),
			IsActive:      false,
		})
		return
	}

	deepLink := fmt.Sprintf("vibra://party/%s?server=%s", url.PathEscape(code), url.QueryEscape(origin))
	intentURI := fmt.Sprintf("intent://party/%s?server=%s#Intent;scheme=vibra;package=com.fortune.vibramusic;end", url.PathEscape(code), url.QueryEscape(origin))

	p := store.Find(code)

	hostName := strings.TrimSpace(r.URL.Query().Get("host"))
	hostAvatarUrl := strings.TrimSpace(r.URL.Query().Get("avatar"))
	currentSongTitle := strings.TrimSpace(r.URL.Query().Get("title"))
	currentSongArtist := strings.TrimSpace(r.URL.Query().Get("artist"))
	currentSongThumb := strings.TrimSpace(r.URL.Query().Get("thumb"))
	if currentSongThumb == "" {
		currentSongThumb = strings.TrimSpace(r.URL.Query().Get("cover"))
	}

	memberCount := 1
	maxMembers := 5
	isActive := p != nil || currentSongTitle != "" || hostName != ""

	if p != nil {
		p.Lock()
		if hostName == "" {
			for _, m := range p.Members {
				if m.IsHost {
					hostName = m.DisplayName
					if m.AvatarUrl != nil && hostAvatarUrl == "" {
						hostAvatarUrl = *m.AvatarUrl
					}
					break
				}
			}
		}
		if hostName == "" && len(p.Members) > 0 {
			for _, m := range p.Members {
				hostName = m.DisplayName
				if m.AvatarUrl != nil && hostAvatarUrl == "" {
					hostAvatarUrl = *m.AvatarUrl
				}
				break
			}
		}
		if p.Playback != nil && p.Playback.Track != nil {
			if currentSongTitle == "" {
				currentSongTitle = p.Playback.Track.Title
			}
			if currentSongArtist == "" {
				currentSongArtist = p.Playback.Track.Artist
			}
			if currentSongThumb == "" && p.Playback.Track.ThumbnailUrl != nil {
				currentSongThumb = *p.Playback.Track.ThumbnailUrl
			}
		} else if currentSongTitle != "" {
			var thumbPtr *string
			if currentSongThumb != "" {
				thumbPtr = &currentSongThumb
			}
			p.Playback.Track = &party.Track{
				VideoId:      "shared",
				Title:        currentSongTitle,
				Artist:       currentSongArtist,
				ThumbnailUrl: thumbPtr,
			}
		}
		memberCount = len(p.Members)
		maxMembers = p.MaxMembers
		p.Unlock()
	}

	v := url.Values{}
	if currentSongTitle != "" {
		v.Set("title", currentSongTitle)
	}
	if currentSongArtist != "" {
		v.Set("artist", currentSongArtist)
	}
	if currentSongThumb != "" {
		v.Set("thumb", currentSongThumb)
	}
	if hostName != "" {
		v.Set("host", hostName)
	}
	if hostAvatarUrl != "" {
		v.Set("avatar", hostAvatarUrl)
	}
	previewImgURL := fmt.Sprintf("%s/invite/%s/preview.png", origin, code)
	if len(v) > 0 {
		previewImgURL += "?" + v.Encode()
	}

	w.WriteHeader(http.StatusOK)
	_ = inviteTemplate.Execute(w, invitePageData{
		Code:              code,
		DeepLink:          deepLink,
		IntentURI:         template.URL(intentURI),
		SafeDeepLink:      template.URL(deepLink),
		ServerOrigin:      origin,
		HostName:          hostName,
		HostAvatarUrl:     hostAvatarUrl,
		CurrentSongTitle:  currentSongTitle,
		CurrentSongArtist: currentSongArtist,
		CurrentSongThumb:  currentSongThumb,
		PreviewImgURL:     previewImgURL,
		MemberCount:       memberCount,
		MaxMembers:        maxMembers,
		IsActive:          isActive,
	})
}

func handleInvitePreviewImage(w http.ResponseWriter, r *http.Request) {
	if !imageLimiter.Allow(clientIP(r)) {
		http.Error(w, "rate limited", http.StatusTooManyRequests)
		return
	}
	code := codes.Normalise(r.PathValue("code"))
	p := store.Find(code)

	hostName := strings.TrimSpace(r.URL.Query().Get("host"))
	hostAvatarUrl := strings.TrimSpace(r.URL.Query().Get("avatar"))
	currentSongTitle := strings.TrimSpace(r.URL.Query().Get("title"))
	currentSongArtist := strings.TrimSpace(r.URL.Query().Get("artist"))
	currentSongThumb := strings.TrimSpace(r.URL.Query().Get("thumb"))
	if currentSongThumb == "" {
		currentSongThumb = strings.TrimSpace(r.URL.Query().Get("cover"))
	}

	if p != nil {
		p.Lock()
		if hostName == "" {
			for _, m := range p.Members {
				if m.IsHost {
					hostName = m.DisplayName
					if m.AvatarUrl != nil && hostAvatarUrl == "" {
						hostAvatarUrl = *m.AvatarUrl
					}
					break
				}
			}
		}
		if hostName == "" && len(p.Members) > 0 {
			for _, m := range p.Members {
				hostName = m.DisplayName
				if m.AvatarUrl != nil && hostAvatarUrl == "" {
					hostAvatarUrl = *m.AvatarUrl
				}
				break
			}
		}
		if p.Playback != nil && p.Playback.Track != nil {
			if currentSongTitle == "" {
				currentSongTitle = p.Playback.Track.Title
			}
			if currentSongArtist == "" {
				currentSongArtist = p.Playback.Track.Artist
			}
			if currentSongThumb == "" && p.Playback.Track.ThumbnailUrl != nil {
				currentSongThumb = *p.Playback.Track.ThumbnailUrl
			}
		} else if currentSongTitle != "" {
			var thumbPtr *string
			if currentSongThumb != "" {
				thumbPtr = &currentSongThumb
			}
			p.Playback.Track = &party.Track{
				VideoId:      "shared",
				Title:        currentSongTitle,
				Artist:       currentSongArtist,
				ThumbnailUrl: thumbPtr,
			}
		}
		p.Unlock()
	}

	cacheKey := fmt.Sprintf("%s:%s:%s:%s:%s:%s", code, hostName, hostAvatarUrl, currentSongTitle, currentSongArtist, currentSongThumb)
	if cached := getCachedPreviewCard(cacheKey); cached != nil {
		w.Header().Set("Content-Type", "image/png")
		w.Header().Set("Cache-Control", "public, max-age=60")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(cached)
		return
	}

	cardBytes, err := preview.GenerateCard(code, hostName, hostAvatarUrl, currentSongTitle, currentSongArtist, currentSongThumb)
	if err != nil {
		http.Error(w, "Failed to render card", http.StatusInternalServerError)
		return
	}

	setCachedPreviewCard(cacheKey, cardBytes)

	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "public, max-age=60")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(cardBytes)
}

// Digital Asset Links for Android App Links autoVerify

const assetLinksJSON = `[
  {
    "relation": ["delegate_permission/common.handle_all_urls"],
    "target": {
      "namespace": "android_app",
      "package_name": "com.fortune.vibramusic",
      "sha256_cert_fingerprints": [
        "C7:B2:26:F2:2A:AC:AB:05:AE:1B:57:29:C4:A6:C0:A2:92:54:C5:16:2F:23:8B:86:84:89:E3:27:00:0F:52:B8"
      ]
    }
  }
]
`

func handleAssetLinks(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(assetLinksJSON))
}

// WebSocket Handler

func handleWebSocket(w http.ResponseWriter, r *http.Request) {
	if !wsLimiter.Allow(clientIP(r)) {
		http.Error(w, "too many websocket requests", http.StatusTooManyRequests)
		return
	}
	code := r.PathValue("code")
	token := parseBearerToken(r)
	if token == "" {
		http.Error(w, "missing token", http.StatusUnauthorized)
		return
	}

	p, err := store.Get(code)
	if err != nil {
		http.Error(w, "no such party", http.StatusNotFound)
		return
	}

	p.Lock()
	member, err := p.Authenticate(token)
	if err != nil {
		p.Unlock()
		http.Error(w, "bad token", http.StatusUnauthorized)
		return
	}
	p.Unlock()

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("WebSocket upgrade failed: %v", err)
		return
	}
	conn.SetReadLimit(config.WebSocketMaxBytes)
	_ = conn.SetReadDeadline(time.Now().Add(time.Duration(config.ConnectionIdleMs) * time.Millisecond))

	p.Lock()
	p.MarkConnected(member, true)
	p.Unlock()

	sc := hubInst.Attach(p.Code, member.MemberId, conn)

	// Send welcome frame
	p.Lock()
	welcome := map[string]interface{}{
		"type":     protocol.FrameWelcome,
		"you":      member.ToWire(),
		"party":    p.ToWire(),
		"serverMs": clock.NowMs(),
	}
	membersF := membersFrame(p)
	p.Unlock()

	_ = sc.WriteJSON(welcome)
	hubInst.Broadcast(p.Code, membersF, "")

	// Read loop
	defer func() {
		hubInst.Detach(p.Code, member.MemberId, sc)
		_ = sc.Close()

		p.Lock()
		p.MarkConnected(member, false)
		mFrame := membersFrame(p)
		p.Unlock()

		hubInst.Broadcast(p.Code, mFrame, "")
	}()

	for {
		var raw map[string]interface{}
		if err := conn.ReadJSON(&raw); err != nil {
			break
		}
		_ = conn.SetReadDeadline(time.Now().Add(time.Duration(config.ConnectionIdleMs) * time.Millisecond))
		handleSocketFrame(p, member, sc, raw)
	}
}

func handleSocketFrame(p *party.Party, member *party.Member, sc *hub.SafeConn, frame map[string]interface{}) {
	kind, _ := frame["type"].(string)
	if kind == "" {
		return
	}

	p.Lock()
	defer p.Unlock()
	if !p.SpendFrameBudget(member) {
		_ = sc.WriteJSON(map[string]interface{}{
			"type": protocol.FrameError, "error": "rate_limited", "message": "Too many messages at once.",
		})
		return
	}

	member.LastSeenMs = clock.NowMs()

	switch kind {
	case protocol.FramePing:
		_ = sc.WriteJSON(map[string]interface{}{
			"type":     protocol.FramePong,
			"clientMs": frame["clientMs"],
			"serverMs": clock.NowMs(),
		})

	case protocol.FrameSync:
		_ = sc.WriteJSON(stateFrame(p))

	case protocol.FrameSyncQueue:
		_ = sc.WriteJSON(queueFrame(p))

	case protocol.FrameReport:
		// Playhead position report from client for monitoring
		if posNum, ok := frame["positionMs"].(float64); ok && p.Playback.IsPlaying {
			drift := int64(posNum) - p.Playback.PositionAt(clock.NowMs())
			if drift > 1500 || drift < -1500 {
				log.Printf("party %s: %s drifted %dms", p.Code, member.DisplayName, drift)
			}
		}

	case protocol.FrameControl:
		if !p.SpendControlBudget(member) {
			_ = sc.WriteJSON(map[string]interface{}{
				"type":    protocol.FrameError,
				"error":   "rate_limited",
				"message": "Too many controls at once.",
			})
			return
		}

		queueBefore := p.Playback.QueueSeq
		action, _ := frame["action"].(string)
		success, errCode, errMsg := applyControl(p, member, action, frame)
		if success {
			p.Touch()
			// If queue changed, broadcast queue first
			if p.Playback.QueueSeq != queueBefore {
				hubInst.Broadcast(p.Code, queueFrame(p), "")
			}
			hubInst.Broadcast(p.Code, stateFrame(p), "")
			if action == protocol.ActionKick ||
				action == protocol.ActionSetMaxMembers ||
				action == protocol.ActionSetHostOnlyControl {
				hubInst.Broadcast(p.Code, membersFrame(p), "")
			}
			hubInst.Broadcast(p.Code, activityFrame(member, action, frame), "")
		} else if errCode != "" {
			_ = sc.WriteJSON(map[string]interface{}{
				"type":    protocol.FrameError,
				"error":   errCode,
				"message": errMsg,
			})
		}
	}
}

func applyControl(p *party.Party, member *party.Member, action string, frame map[string]interface{}) (bool, string, string) {
	// Enforced here rather than left to the clients. An app that hides its own
	// next button is a courtesy; this is what actually stops a listener's
	// device — a stale build, a backgrounded one still echoing an old intent,
	// or something else entirely — from moving the music for everybody.
	if protocol.ControlActions[action] && !p.MayControl(member) {
		return false, "host_only", "Only the host can control the music in this party."
	}

	var posPtr *int64
	if pos, ok := frame["positionMs"].(float64); ok && !math.IsNaN(pos) && !math.IsInf(pos, 0) {
		pVal := int64(pos)
		if pVal < 0 {
			pVal = 0
		} else if pVal > party.MaxPositionMs {
			pVal = party.MaxPositionMs
		}
		posPtr = &pVal
	}

	switch action {
	case protocol.ActionPlay:
		p.Playback.Play(&member.MemberId, posPtr)
		return true, "", ""

	case protocol.ActionPause:
		p.Playback.Pause(&member.MemberId, posPtr)
		return true, "", ""

	case protocol.ActionSeek:
		if posPtr == nil {
			return false, "missing_position", "seek requires positionMs"
		}
		p.Playback.Seek(&member.MemberId, *posPtr)
		return true, "", ""

	case protocol.ActionSetTrack:
		trackMap, _ := frame["track"].(map[string]interface{})
		t := party.TrackFromWire(trackMap)
		if t == nil {
			return false, "invalid_track", "Track must include videoId"
		}
		pos := int64(0)
		if posPtr != nil {
			pos = *posPtr
		}
		isPlaying := true
		if pVal, ok := frame["isPlaying"].(bool); ok {
			isPlaying = pVal
		}
		var qIndexPtr *int
		if qIndex, ok := frame["queueIndex"].(float64); ok && !math.IsNaN(qIndex) && !math.IsInf(qIndex, 0) {
			qi := int(qIndex)
			if qi >= -1 && qi < 10000 {
				qIndexPtr = &qi
			}
		}
		p.Playback.SetTrack(&member.MemberId, t, pos, isPlaying, qIndexPtr, &member.DisplayName)
		return true, "", ""

	case protocol.ActionSetQueue:
		itemsRaw, _ := frame["queue"].([]interface{})
		var tracks []*party.Track
		for _, item := range itemsRaw {
			if m, ok := item.(map[string]interface{}); ok {
				if tr := party.TrackFromWire(m); tr != nil {
					tracks = append(tracks, tr)
				}
			}
		}
		qIdx := -1
		if idxNum, ok := frame["queueIndex"].(float64); ok && !math.IsNaN(idxNum) && !math.IsInf(idxNum, 0) {
			qIdx = int(idxNum)
		}
		p.Playback.SetQueue(&member.MemberId, tracks, qIdx)
		return true, "", ""

	case protocol.ActionQueueAdd:
		var tracksToAdd []*party.Track
		if singleMap, ok := frame["track"].(map[string]interface{}); ok {
			if tr := party.TrackFromWire(singleMap); tr != nil {
				tracksToAdd = append(tracksToAdd, tr)
			}
		} else if itemsRaw, ok := frame["tracks"].([]interface{}); ok {
			for _, item := range itemsRaw {
				if m, ok := item.(map[string]interface{}); ok {
					if tr := party.TrackFromWire(m); tr != nil {
						tracksToAdd = append(tracksToAdd, tr)
					}
				}
			}
		}
		playNext, _ := frame["playNext"].(bool)
		ok, reason := p.Playback.AddUpcoming(&member.MemberId, tracksToAdd, playNext)
		if !ok {
			if reason == "queue_full" {
				return false, "queue_full", fmt.Sprintf("Queue is full (maximum %d upcoming songs).", config.MaxUpcomingQueue)
			}
			return false, reason, "Could not add track to queue."
		}
		return true, "", ""

	case protocol.ActionQueueRemove:
		vid, _ := frame["videoId"].(string)
		if vid == "" {
			if idxNum, ok := frame["index"].(float64); ok && !math.IsNaN(idxNum) && !math.IsInf(idxNum, 0) {
				idx := int(idxNum)
				if idx >= 0 && idx < len(p.Playback.Queue) {
					vid = p.Playback.Queue[idx].VideoId
				}
			}
		}
		if vid == "" {
			return false, "missing_track", "queueRemove requires videoId or index"
		}
		if !p.Playback.RemoveUpcoming(&member.MemberId, vid) {
			return false, "not_found", "Track is not in the upcoming queue"
		}
		return true, "", ""

	case protocol.ActionQueueClear:
		if !p.Playback.ClearUpcoming(&member.MemberId) {
			return false, "no_upcoming", "No upcoming tracks to clear"
		}
		return true, "", ""

	case protocol.ActionQueueMove:
		fromNum, okFrom := frame["fromIndex"].(float64)
		toNum, okTo := frame["toIndex"].(float64)
		if !okFrom || !okTo || math.IsNaN(fromNum) || math.IsInf(fromNum, 0) || math.IsNaN(toNum) || math.IsInf(toNum, 0) {
			return false, "missing_indices", "queueMove requires valid fromIndex and toIndex"
		}
		fromIdx := int(fromNum)
		toIdx := int(toNum)
		if fromIdx < 0 || toIdx < 0 || fromIdx > 1000 || toIdx > 1000 {
			return false, "invalid_indices", "queue move indices out of bounds"
		}
		var videoId string
		if v, ok := frame["videoId"].(string); ok {
			videoId = v
		}
		if !p.Playback.MoveUpcoming(&member.MemberId, fromIdx, toIdx, videoId) {
			return false, "invalid_move", "Invalid queue move indices"
		}
		return true, "", ""

	case protocol.ActionNext:
		if !p.Playback.Step(&member.MemberId, 1, &member.DisplayName) {
			return false, "end_of_queue", "Already at the end of the queue."
		}
		return true, "", ""

	case protocol.ActionPrevious:
		if !p.Playback.Step(&member.MemberId, -1, &member.DisplayName) {
			return false, "start_of_queue", "Already at the beginning of the queue."
		}
		return true, "", ""

	case protocol.ActionSetMaxMembers:
		value, ok := frame["maxMembers"].(float64)
		if !ok || math.IsNaN(value) || math.IsInf(value, 0) {
			return false, "invalid_capacity", "Choose a party size between 2 and 10."
		}
		valInt := int(value)
		if valInt < 2 || valInt > 10 {
			return false, "invalid_capacity", "Choose a party size between 2 and 10."
		}
		if err := p.SetMaxMembers(member, valInt); err != nil {
			pe := err.(*party.PartyError)
			return false, pe.Code, pe.Message
		}
		return true, "", ""

	case protocol.ActionSetAutoplay:
		enabled, ok := frame["enabled"].(bool)
		if !ok {
			return false, "invalid_autoplay", "AutoPlay must be enabled or disabled."
		}
		p.Playback.SetAutoplay(&member.MemberId, enabled)
		return true, "", ""

	case protocol.ActionSetHostOnlyControl:
		enabled, ok := frame["enabled"].(bool)
		if !ok {
			return false, "invalid_control_policy", "Host-only control must be enabled or disabled."
		}
		if err := p.SetHostOnlyControl(member, enabled); err != nil {
			pe := err.(*party.PartyError)
			return false, pe.Code, pe.Message
		}
		return true, "", ""

	case protocol.ActionKick:
		targetID, _ := frame["memberId"].(string)
		if !member.IsHost { return false, "host_only", "Only the host can remove listeners." }
		if targetID == "" || targetID == member.MemberId { return false, "invalid_member", "Choose another listener to remove." }
		if p.Remove(targetID) == nil { return false, "not_found", "That listener is no longer in this party." }
		hubInst.Send(p.Code, targetID, map[string]interface{}{
			"type":    protocol.FrameBye,
			"reason":  "kicked",
			"message": "The host removed you from this party.",
		})
		hubInst.CloseMember(p.Code, targetID)
		return true, "", ""

	default:
		return false, "unknown_action", fmt.Sprintf("Unknown control action '%s'", action)
	}
}

// Frame builders

func stateFrame(p *party.Party) map[string]interface{} {
	return map[string]interface{}{
		"type":     protocol.FrameState,
		"playback": p.Playback.ToWire(clock.NowMs()),
		"serverMs": clock.NowMs(),
	}
}

func activityFrame(member *party.Member, action string, frame map[string]interface{}) map[string]interface{} {
	detail := action
	trackTitle := func(raw interface{}) string {
		track, _ := raw.(map[string]interface{})
		title, _ := track["title"].(string)
		return title
	}
	switch action {
	case protocol.ActionSetTrack:
		if title := trackTitle(frame["track"]); title != "" { detail = "Changed the song to \"" + title + "\"" }
	case protocol.ActionQueueAdd:
		if tracks, ok := frame["tracks"].([]interface{}); ok && len(tracks) > 0 {
			title := trackTitle(tracks[0])
			if title != "" {
				if len(tracks) == 1 { detail = "Added \"" + title + "\" to the queue" } else { detail = fmt.Sprintf("Added \"%s\" and %d more to the queue", title, len(tracks)-1) }
			}
		}
	case protocol.ActionSetQueue:
		if tracks, ok := frame["queue"].([]interface{}); ok { detail = fmt.Sprintf("Replaced the queue with %d tracks", len(tracks)) }
	case protocol.ActionQueueRemove: detail = "Removed a track from the queue"
	case protocol.ActionQueueClear: detail = "Cleared upcoming tracks"
	case protocol.ActionQueueMove: detail = "Reordered the upcoming queue"
	case protocol.ActionNext: detail = "Skipped to the next song"
	case protocol.ActionPrevious: detail = "Went back to the previous song"
	case protocol.ActionPlay: detail = "Started playback"
	case protocol.ActionPause: detail = "Paused playback"
	case protocol.ActionSeek: detail = "Changed the playback position"
	case protocol.ActionKick: detail = "Removed a listener from the party"
	case protocol.ActionSetMaxMembers: detail = "Changed the party size"
	case protocol.ActionSetAutoplay: detail = "Changed AutoPlay"
	}
	return map[string]interface{}{"type": protocol.FrameActivity, "action": action, "by": member.DisplayName, "detail": detail, "atMs": clock.NowMs()}
}

func queueFrame(p *party.Party) map[string]interface{} {
	return map[string]interface{}{
		"type":     protocol.FrameQueue,
		"queue":    p.Playback.QueueToWire(),
		"serverMs": clock.NowMs(),
	}
}

func membersFrame(p *party.Party) map[string]interface{} {
	membersList := make([]map[string]interface{}, 0, len(p.Members))
	for _, m := range p.Members {
		membersList = append(membersList, m.ToWire())
	}
	return map[string]interface{}{
		"type":            protocol.FrameMembers,
		"members":         membersList,
		"maxMembers":      p.MaxMembers,
		"hostOnlyControl": p.HostOnlyControl,
		"serverMs":        clock.NowMs(),
	}
}

// Background Heartbeat Ticker

func startHeartbeatTicker() {
	interval := time.Duration(config.StateHeartbeatMs) * time.Millisecond
	if interval < 1*time.Second {
		interval = 1 * time.Second
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for range ticker.C {
		now := clock.NowMs()
		for _, p := range store.All() {
			if len(hubInst.MembersOnline(p.Code)) > 0 {
				p.Lock()
				sf := stateFrame(p)
				p.Unlock()
				hubInst.Broadcast(p.Code, sf, "")
			}
		}

		changed := store.Sweep(now)
		for _, p := range changed {
			p.Lock()
			mf := membersFrame(p)
			p.Unlock()
			hubInst.Broadcast(p.Code, mf, "")
		}

		activeCodes := hubInst.ActiveCodes()
		liveParties := store.All()
		liveMap := make(map[string]bool)
		for _, lp := range liveParties {
			liveMap[lp.Code] = true
		}
		for _, code := range activeCodes {
			if !liveMap[code] {
				hubInst.DropParty(code)
			}
		}
	}
}
