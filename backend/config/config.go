package config

import (
	"log"
	"net"
	"net/url"
	"os"
	"strconv"
	"strings"
)

func getIntBounded(key string, fallback, min, max int) int {
	val := os.Getenv(key)
	if val == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(strings.TrimSpace(val))
	if err != nil {
		log.Printf("config: invalid integer for %s=%q, using fallback %d", key, val, fallback)
		return fallback
	}
	if parsed < min || parsed > max {
		log.Printf("config: %s=%d out of bounds [%d, %d], using fallback %d", key, parsed, min, max, fallback)
		return fallback
	}
	return parsed
}

func getString(key, fallback string) string {
	val := strings.TrimSpace(os.Getenv(key))
	if val == "" {
		return fallback
	}
	return val
}

func getCSV(key string, fallback string) []string {
	val := os.Getenv(key)
	if val == "" {
		val = fallback
	}
	if val == "" {
		return nil
	}
	var res []string
	for _, item := range strings.Split(val, ",") {
		trimmed := strings.TrimSpace(item)
		if trimmed != "" {
			res = append(res, trimmed)
		}
	}
	return res
}

func getBool(key string, fallback bool) bool {
	val := os.Getenv(key)
	if val == "" {
		return fallback
	}
	parsed, err := strconv.ParseBool(strings.TrimSpace(val))
	if err != nil {
		return fallback
	}
	return parsed
}

// IsAllowedOrigin deliberately does not support a wildcard. Browser clients
// must be explicitly named; native clients send no Origin header.
func IsAllowedOrigin(origin string) bool {
	for _, allowed := range AllowedOrigins {
		if origin == allowed {
			return true
		}
	}
	return false
}

// IsAllowedHost checks whether a Host header matches configured allowed hosts.
func IsAllowedHost(host string) bool {
	// Strip optional port
	h, _, err := net.SplitHostPort(host)
	if err != nil {
		h = host
	}
	h = strings.ToLower(strings.TrimSpace(h))
	for _, allowed := range AllowedHosts {
		ah, _, err := net.SplitHostPort(allowed)
		if err != nil {
			ah = allowed
		}
		if strings.EqualFold(h, strings.TrimSpace(ah)) {
			return true
		}
	}
	return false
}

var (
	MaxMembers           = getIntBounded("JAM_MAX_MEMBERS", 5, 2, 50)
	StateHeartbeatMs     = getIntBounded("JAM_STATE_HEARTBEAT_MS", 5000, 1000, 60000)
	PlayLeadMs           = getIntBounded("JAM_PLAY_LEAD_MS", 350, 50, 5000)
	DisconnectGraceMs    = int64(getIntBounded("JAM_DISCONNECT_GRACE_MS", 15*60*1000, 10000, 24*60*60*1000))
	EmptyPartyTTLMs      = int64(getIntBounded("JAM_EMPTY_PARTY_TTL_MS", 30*60*1000, 10000, 24*60*60*1000))
	PartyMaxAgeMs        = int64(getIntBounded("JAM_PARTY_MAX_AGE_MS", 12*60*60*1000, 60000, 7*24*60*60*1000))
	ControlRatePerSecond = float64(getIntBounded("JAM_CONTROL_RATE_PER_SECOND", 25, 1, 500))
	MaxUpcomingQueue     = getIntBounded("JAM_MAX_UPCOMING_QUEUE", 25, 1, 200)
	MaxQueueLength       = getIntBounded("JAM_MAX_QUEUE_LENGTH", 1+MaxUpcomingQueue, 2, 500)
	MaxParties           = getIntBounded("JAM_MAX_PARTIES", 50, 1, 1000)
	CreateRatePerMinute  = getIntBounded("JAM_CREATE_RATE_PER_MINUTE", 10, 1, 60)
	RateLimitMaxEntries  = getIntBounded("JAM_RATE_LIMIT_MAX_ENTRIES", 10000, 100, 1000000)
	RequestMaxBytes      = int64(getIntBounded("JAM_REQUEST_MAX_BYTES", 16*1024, 1024, 10*1024*1024))
	WebSocketMaxBytes    = int64(getIntBounded("JAM_WEBSOCKET_MAX_BYTES", 16*1024, 1024, 10*1024*1024))
	ConnectionIdleMs     = int64(getIntBounded("JAM_CONNECTION_IDLE_MS", 15*60*1000, 10000, 24*60*60*1000))
	FrameRatePerSecond   = float64(getIntBounded("JAM_FRAME_RATE_PER_SECOND", 30, 1, 500))
	AllowedOrigins       = getCSV("JAM_ALLOWED_ORIGINS", "")
	TrustProxy           = getBool("JAM_TRUST_PROXY", true)
	Port                 = getIntBounded("PORT", 8000, 1, 65535)

	// PublicOrigin defines the authoritative public canonical origin of this server
	// (e.g. "https://party.vibramusic.store"). Prevents Host header poisoning of invite links.
	PublicOrigin = strings.TrimRight(getString("JAM_PUBLIC_ORIGIN", "https://party.vibramusic.store"), "/")

	// AllowedHosts defines hosts accepted in Host headers for invite pages.
	AllowedHosts = getCSV("JAM_ALLOWED_HOSTS", "party.vibramusic.store,vibra-music.onrender.com,localhost,127.0.0.1,0.0.0.0")
)

func init() {
	// If PublicOrigin has a hostname, ensure it is automatically allowed
	if PublicOrigin != "" {
		if u, err := url.Parse(PublicOrigin); err == nil && u.Host != "" {
			AllowedHosts = append(AllowedHosts, u.Host)
		}
	}
}
