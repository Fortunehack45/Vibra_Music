package party

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"sync"

	"github.com/Fortunehack45/Vibra_Music/backend/clock"
	"github.com/Fortunehack45/Vibra_Music/backend/codes"
	"github.com/Fortunehack45/Vibra_Music/backend/config"
)

// PartyError represents an error with an HTTP status code and wire error code.
type PartyError struct {
	Status  int    `json:"status"`
	Code    string `json:"error"`
	Message string `json:"message"`
}

func (e *PartyError) Error() string {
	return e.Message
}

func NewPartyError(status int, code, message string) *PartyError {
	return &PartyError{Status: status, Code: code, Message: message}
}

func truncateRunes(s string, maxRunes int) string {
	runes := []rune(s)
	if len(runes) <= maxRunes {
		return s
	}
	return string(runes[:maxRunes])
}

const (
	MaxPositionMs = 24 * 60 * 60 * 1000 // 24 hours
)

// Track represents a song with metadata needed for display and synchronization.
type Track struct {
	VideoId      string  `json:"videoId"`
	Title        string  `json:"title"`
	Artist       string  `json:"artist"`
	ThumbnailUrl *string `json:"thumbnailUrl,omitempty"`
	DurationMs   *int64  `json:"durationMs,omitempty"`
	FromAutoplay bool    `json:"fromAutoplay"`
}

func TrackFromWire(raw map[string]interface{}) *Track {
	if raw == nil {
		return nil
	}
	vid, _ := raw["videoId"].(string)
	if vid == "" {
		return nil
	}
	vid = truncateRunes(vid, 128)

	title, _ := raw["title"].(string)
	title = truncateRunes(title, 300)

	artist, _ := raw["artist"].(string)
	artist = truncateRunes(artist, 300)

	var thumbPtr *string
	if t, ok := raw["thumbnailUrl"].(string); ok && t != "" {
		t = truncateRunes(t, 1000)
		thumbPtr = &t
	}

	var durPtr *int64
	if d, ok := raw["durationMs"].(float64); ok && !math.IsNaN(d) && !math.IsInf(d, 0) && d > 0 && d <= float64(MaxPositionMs) {
		dur := int64(d)
		durPtr = &dur
	}

	fromAutoplay, _ := raw["fromAutoplay"].(bool)

	return &Track{
		VideoId:      vid,
		Title:        title,
		Artist:       artist,
		ThumbnailUrl: thumbPtr,
		DurationMs:   durPtr,
		FromAutoplay: fromAutoplay,
	}
}

// PlaybackState tracks playhead, playback mode, anchor timestamps, and queue sequencing.
type PlaybackState struct {
	Track         *Track   `json:"track"`
	Queue         []*Track `json:"-"`
	QueueIndex    int      `json:"queueIndex"`
	IsPlaying     bool     `json:"isPlaying"`
	PositionMs    int64    `json:"positionMs"`
	AnchorMs      int64    `json:"anchorMs"`
	Seq           int      `json:"seq"`
	QueueSeq      int      `json:"queueSeq"`
	UpdatedBy     *string  `json:"updatedBy"`
	UpdatedAtMs   int64    `json:"updatedAtMs"`
	StartedBy     *string  `json:"startedBy"`
	StartedByName *string  `json:"startedByName"`
	AutoplayEnabled bool   `json:"autoplayEnabled"`
}

func NewPlaybackState() *PlaybackState {
	now := clock.NowMs()
	return &PlaybackState{
		Queue:       make([]*Track, 0),
		QueueIndex:  -1,
		AnchorMs:    now,
		UpdatedAtMs: now,
	}
}

func (p *PlaybackState) PositionAt(serverMs int64) int64 {
	if !p.IsPlaying {
		return p.PositionMs
	}
	elapsed := serverMs - p.AnchorMs
	if elapsed < 0 {
		elapsed = 0
	}
	pos := p.PositionMs + elapsed
	if p.Track != nil && p.Track.DurationMs != nil && *p.Track.DurationMs > 0 {
		if pos > *p.Track.DurationMs {
			return *p.Track.DurationMs
		}
	}
	return pos
}

func (p *PlaybackState) touch(memberId *string) {
	p.Seq++
	p.UpdatedBy = memberId
	p.UpdatedAtMs = clock.NowMs()
}

func (p *PlaybackState) touchQueue(memberId *string) {
	p.QueueSeq++
	p.UpdatedBy = memberId
	p.UpdatedAtMs = clock.NowMs()
}

func (p *PlaybackState) Play(memberId *string, positionMs *int64) {
	now := clock.NowMs()
	startAt := p.PositionAt(now)
	if positionMs != nil {
		startAt = *positionMs
	}
	if startAt < 0 {
		startAt = 0
	} else if startAt > MaxPositionMs {
		startAt = MaxPositionMs
	}
	p.PositionMs = startAt
	p.IsPlaying = true
	p.AnchorMs = now + int64(config.PlayLeadMs)
	p.touch(memberId)
}

func (p *PlaybackState) Pause(memberId *string, positionMs *int64) {
	now := clock.NowMs()
	pauseAt := p.PositionAt(now)
	if positionMs != nil {
		pauseAt = *positionMs
	}
	if pauseAt < 0 {
		pauseAt = 0
	} else if pauseAt > MaxPositionMs {
		pauseAt = MaxPositionMs
	}
	p.PositionMs = pauseAt
	p.IsPlaying = false
	p.AnchorMs = now
	p.touch(memberId)
}

func (p *PlaybackState) Seek(memberId *string, positionMs int64) {
	if positionMs < 0 {
		positionMs = 0
	} else if positionMs > MaxPositionMs {
		positionMs = MaxPositionMs
	}
	p.PositionMs = positionMs
	lead := int64(0)
	if p.IsPlaying {
		lead = int64(config.PlayLeadMs)
	}
	p.AnchorMs = clock.NowMs() + lead
	p.touch(memberId)
}

func (p *PlaybackState) SetTrack(
	memberId *string,
	track *Track,
	positionMs int64,
	isPlaying bool,
	queueIndex *int,
	memberName *string,
) {
	p.Track = track
	if positionMs < 0 {
		positionMs = 0
	}
	p.PositionMs = positionMs
	p.IsPlaying = isPlaying && track != nil
	lead := int64(0)
	if p.IsPlaying {
		lead = int64(config.PlayLeadMs)
	}
	p.AnchorMs = clock.NowMs() + lead

	if queueIndex != nil {
		p.QueueIndex = *queueIndex
	} else if track != nil {
		match := -1
		for i, item := range p.Queue {
			if item.VideoId == track.VideoId {
				match = i
				break
			}
		}
		p.QueueIndex = match
	}

	p.StartedBy = memberId
	p.StartedByName = memberName
	p.touch(memberId)
}

func (p *PlaybackState) SetQueue(memberId *string, queue []*Track, queueIndex int) {
	if p.Track != nil {
		for i, item := range queue {
			if item.VideoId == p.Track.VideoId {
				queueIndex = i
				break
			}
		}
	}

	if queueIndex >= 0 && queueIndex < len(queue) {
		pastAndCurrent := queue[:queueIndex+1]
		endUpcoming := queueIndex + 1 + config.MaxUpcomingQueue
		if endUpcoming > len(queue) {
			endUpcoming = len(queue)
		}
		upcoming := queue[queueIndex+1 : endUpcoming]
		newQ := make([]*Track, 0, len(pastAndCurrent)+len(upcoming))
		newQ = append(newQ, pastAndCurrent...)
		newQ = append(newQ, upcoming...)
		p.Queue = newQ
		p.QueueIndex = queueIndex
	} else {
		maxLen := config.MaxQueueLength
		if len(queue) < maxLen {
			maxLen = len(queue)
		}
		p.Queue = queue[:maxLen]
		if queueIndex >= 0 && queueIndex < len(p.Queue) {
			p.QueueIndex = queueIndex
		} else {
			p.QueueIndex = -1
		}
	}
	p.touchQueue(memberId)
}

func (p *PlaybackState) AddUpcoming(memberId *string, tracks []*Track, playNext bool) (bool, string) {
	currentUpcoming := 0
	if p.QueueIndex >= 0 {
		currentUpcoming = len(p.Queue) - 1 - p.QueueIndex
		if currentUpcoming < 0 {
			currentUpcoming = 0
		}
	} else {
		currentUpcoming = len(p.Queue)
	}

	slotsLeft := config.MaxUpcomingQueue - currentUpcoming
	if slotsLeft <= 0 {
		return false, "queue_full"
	}

	toAdd := tracks
	if len(toAdd) > slotsLeft {
		toAdd = toAdd[:slotsLeft]
	}
	if len(toAdd) == 0 {
		return false, "no_tracks"
	}

	if playNext && p.QueueIndex >= 0 && p.QueueIndex < len(p.Queue) {
		insertAt := p.QueueIndex + 1
		newQ := make([]*Track, 0, len(p.Queue)+len(toAdd))
		newQ = append(newQ, p.Queue[:insertAt]...)
		newQ = append(newQ, toAdd...)
		newQ = append(newQ, p.Queue[insertAt:]...)
		p.Queue = newQ
	} else {
		p.Queue = append(p.Queue, toAdd...)
	}

	p.touchQueue(memberId)
	return true, ""
}

func (p *PlaybackState) RemoveUpcoming(memberId *string, videoId string) bool {
	match := -1
	for i, item := range p.Queue {
		if item.VideoId == videoId {
			match = i
			break
		}
	}
	if match == -1 || match == p.QueueIndex {
		return false
	}

	p.Queue = append(p.Queue[:match], p.Queue[match+1:]...)
	if p.QueueIndex > match {
		p.QueueIndex--
	}
	p.touchQueue(memberId)
	return true
}

func (p *PlaybackState) ClearUpcoming(memberId *string) bool {
	if p.QueueIndex >= 0 {
		if len(p.Queue) <= p.QueueIndex+1 {
			return false
		}
		p.Queue = p.Queue[:p.QueueIndex+1]
	} else {
		if len(p.Queue) == 0 {
			return false
		}
		p.Queue = p.Queue[:0]
	}
	p.touchQueue(memberId)
	return true
}

func (p *PlaybackState) MoveUpcoming(memberId *string, fromIdx, toIdx int, videoId string) bool {
	if videoId != "" {
		match := -1
		for i, item := range p.Queue {
			if item.VideoId == videoId {
				match = i
				break
			}
		}
		if match == -1 {
			return false
		}
		fromIdx = match
	}

	if fromIdx < 0 || fromIdx >= len(p.Queue) || toIdx < 0 || toIdx >= len(p.Queue) {
		return false
	}
	if fromIdx <= p.QueueIndex || toIdx <= p.QueueIndex {
		return false
	}
	if fromIdx == toIdx {
		return true
	}

	// In-place rotation: smoothly shifts intermediate items without off-by-one index corruption
	item := p.Queue[fromIdx]
	if fromIdx < toIdx {
		copy(p.Queue[fromIdx:toIdx], p.Queue[fromIdx+1:toIdx+1])
	} else {
		copy(p.Queue[toIdx+1:fromIdx+1], p.Queue[toIdx:fromIdx])
	}
	p.Queue[toIdx] = item

	p.touchQueue(memberId)
	return true
}

func (p *PlaybackState) Step(memberId *string, delta int, memberName *string) bool {
	target := p.QueueIndex + delta
	if target < 0 || target >= len(p.Queue) {
		return false
	}
	p.SetTrack(memberId, p.Queue[target], 0, true, &target, memberName)
	return true
}

func (p *PlaybackState) ToWire(serverMs int64) map[string]interface{} {
	var trackWire interface{}
	if p.Track != nil {
		trackWire = p.Track
	}

	return map[string]interface{}{
		"seq":                 p.Seq,
		"track":               trackWire,
		"queueSeq":            p.QueueSeq,
		"queueIndex":          p.QueueIndex,
		"queueLength":         len(p.Queue),
		"isPlaying":           p.IsPlaying,
		"positionMs":          p.PositionMs,
		"anchorMs":            p.AnchorMs,
		"effectivePositionMs": p.PositionAt(serverMs),
		"updatedBy":           p.UpdatedBy,
		"startedBy":           p.StartedBy,
		"startedByName":       p.StartedByName,
		"autoplayEnabled":     p.AutoplayEnabled,
		"updatedAtMs":         p.UpdatedAtMs,
	}
}

// SetAutoplay changes the party-wide AutoPlay choice. It belongs to playback
// state so a replacement AutoPlay supplier can continue after the host leaves.
func (p *PlaybackState) SetAutoplay(memberId *string, enabled bool) {
	if p.AutoplayEnabled == enabled {
		return
	}
	p.AutoplayEnabled = enabled
	p.UpdatedBy = memberId
	p.UpdatedAtMs = clock.NowMs()
}

func (p *PlaybackState) QueueToWire() map[string]interface{} {
	return map[string]interface{}{
		"seq":   p.QueueSeq,
		"index": p.QueueIndex,
		"items": p.Queue,
	}
}

// Member represents a joined device.
type Member struct {
	MemberId           string  `json:"memberId"`
	UserId             string  `json:"userId"`
	DeviceId           string  `json:"-"`
	DisplayName        string  `json:"displayName"`
	AvatarUrl          *string `json:"avatarUrl,omitempty"`
	Token              string  `json:"-"`
	IsHost             bool    `json:"isHost"`
	Connected          bool    `json:"connected"`
	JoinedAtMs         int64   `json:"joinedAtMs"`
	LastSeenMs         int64   `json:"lastSeenMs"`
	ControlBudget      float64 `json:"-"`
	ControlBudgetAtMs  int64   `json:"-"`
	FrameBudget        float64 `json:"-"`
	FrameBudgetAtMs    int64   `json:"-"`
}

func (m *Member) ToWire() map[string]interface{} {
	return map[string]interface{}{
		"memberId":    m.MemberId,
		"userId":      m.UserId,
		"displayName": m.DisplayName,
		"avatarUrl":   m.AvatarUrl,
		"isHost":      m.IsHost,
		"connected":   m.Connected,
		"joinedAtMs":  m.JoinedAtMs,
		"lastSeenMs":  m.LastSeenMs,
	}
}

// Party holds members and playback state for a single room code.
type Party struct {
	mu         sync.Mutex
	Code       string
	Members    map[string]*Member
	Playback   *PlaybackState
	MaxMembers int
	// HostOnlyControl restricts every playback and queue action to the host.
	//
	// Deliberately on Party rather than on PlaybackState: it changes rarely and
	// PlaybackState.ToWire rides the heartbeat to every device every few
	// seconds. It travels with MaxMembers on the members frame instead, which
	// is only sent when something about the membership actually changes.
	HostOnlyControl bool
	CreatedAtMs     int64
	TouchedAtMs     int64
	EmptySinceMs    *int64
}

func NewParty(code string) *Party {
	return NewPartyWithMaxMembers(code, config.MaxMembers)
}

func NewPartyWithMaxMembers(code string, maxMembers int) *Party {
	if maxMembers < 2 || maxMembers > 10 {
		maxMembers = 5
	}
	now := clock.NowMs()
	empty := now
	return &Party{
		Code:         code,
		Members:      make(map[string]*Member),
		Playback:     NewPlaybackState(),
		MaxMembers:   maxMembers,
		CreatedAtMs:  now,
		TouchedAtMs:  now,
		EmptySinceMs: &empty,
	}
}

func (p *Party) Lock()   { p.mu.Lock() }
func (p *Party) Unlock() { p.mu.Unlock() }

func (p *Party) Touch() {
	p.TouchedAtMs = clock.NowMs()
}

func (p *Party) Host() *Member {
	for _, m := range p.Members {
		if m.IsHost {
			return m
		}
	}
	return nil
}

func (p *Party) Join(userId, deviceId, displayName string, avatarUrl *string) (*Member, error) {
	now := clock.NowMs()
	// Rejoining device check
	for _, m := range p.Members {
		if m.DeviceId == deviceId {
			tok, err := randomToken(24)
			if err != nil {
				return nil, NewPartyError(500, "internal_error", "Failed to generate security token.")
			}
			m.DisplayName = displayName
			m.AvatarUrl = avatarUrl
			m.UserId = userId
			m.LastSeenMs = now
			m.Token = tok
			p.Touch()
			return m, nil
		}
	}

	if len(p.Members) >= p.MaxMembers {
		return nil, NewPartyError(409, "party_full", fmt.Sprintf("This party is full (%d devices).", p.MaxMembers))
	}

	memId, err := randomHex(8)
	if err != nil {
		return nil, NewPartyError(500, "internal_error", "Failed to generate member id.")
	}
	tok, err := randomToken(24)
	if err != nil {
		return nil, NewPartyError(500, "internal_error", "Failed to generate security token.")
	}

	m := &Member{
		MemberId:          memId,
		UserId:            userId,
		DeviceId:          deviceId,
		DisplayName:       displayName,
		AvatarUrl:         avatarUrl,
		Token:             tok,
		IsHost:            len(p.Members) == 0,
		Connected:         false,
		JoinedAtMs:        now,
		LastSeenMs:        now,
		ControlBudget:     config.ControlRatePerSecond,
		ControlBudgetAtMs: now,
		FrameBudget:       config.FrameRatePerSecond,
		FrameBudgetAtMs:   now,
	}
	p.Members[m.MemberId] = m
	p.EmptySinceMs = nil
	p.Touch()
	return m, nil
}

func (p *Party) SetMaxMembers(member *Member, maxMembers int) error {
	if !member.IsHost {
		return NewPartyError(403, "host_only", "Only the host can change the party size.")
	}
	if maxMembers < 2 || maxMembers > 10 {
		return NewPartyError(422, "invalid_capacity", "Party size must be between 2 and 10.")
	}
	if maxMembers < len(p.Members) {
		return NewPartyError(409, "party_too_small", "Party size cannot be smaller than the current member count.")
	}
	p.MaxMembers = maxMembers
	p.Touch()
	return nil
}

// SetHostOnlyControl restricts the music to the host, or hands it back to
// everyone. Host-only, like SetMaxMembers: a listener who could turn this off
// is not restricted by it.
func (p *Party) SetHostOnlyControl(member *Member, enabled bool) error {
	if !member.IsHost {
		return NewPartyError(403, "host_only", "Only the host can change who controls the music.")
	}
	if p.HostOnlyControl == enabled {
		return nil
	}
	p.HostOnlyControl = enabled
	p.Touch()
	return nil
}

// MayControl reports whether this member is allowed to drive playback and the
// queue right now.
//
// The host always may. Everyone else may until the host says otherwise — which
// is the behaviour this feature shipped with and stays the default for a party
// that never touches the setting.
func (p *Party) MayControl(member *Member) bool {
	return !p.HostOnlyControl || member.IsHost
}

func (p *Party) Authenticate(token string) (*Member, error) {
	for _, m := range p.Members {
		if subtle.ConstantTimeCompare([]byte(m.Token), []byte(token)) == 1 {
			return m, nil
		}
	}
	return nil, NewPartyError(401, "bad_token", "This device is not a member of that party.")
}

func (p *Party) Remove(memberId string) *Member {
	m, ok := p.Members[memberId]
	if !ok {
		return nil
	}
	delete(p.Members, memberId)
	if m.IsHost && len(p.Members) > 0 {
		for _, next := range p.Members {
			next.IsHost = true
			break
		}
	}
	p.Touch()
	p.refreshEmptiness()
	return m
}

func (p *Party) SpendControlBudget(member *Member) bool {
	now := clock.NowMs()
	elapsedS := float64(now-member.ControlBudgetAtMs) / 1000.0
	if elapsedS < 0 {
		elapsedS = 0
	}
	member.ControlBudget = member.ControlBudget + elapsedS*config.ControlRatePerSecond
	if member.ControlBudget > config.ControlRatePerSecond {
		member.ControlBudget = config.ControlRatePerSecond
	}
	member.ControlBudgetAtMs = now
	if member.ControlBudget < 1.0 {
		return false
	}
	member.ControlBudget -= 1.0
	return true
}

// SpendFrameBudget limits every received WebSocket frame, not just controls.
// This prevents ping/sync frames from bypassing the control rate limit.
func (p *Party) SpendFrameBudget(member *Member) bool {
	now := clock.NowMs()
	elapsedS := float64(now-member.FrameBudgetAtMs) / 1000.0
	if elapsedS < 0 {
		elapsedS = 0
	}
	member.FrameBudget += elapsedS * config.FrameRatePerSecond
	if member.FrameBudget > config.FrameRatePerSecond {
		member.FrameBudget = config.FrameRatePerSecond
	}
	member.FrameBudgetAtMs = now
	if member.FrameBudget < 1.0 {
		return false
	}
	member.FrameBudget -= 1.0
	return true
}

func (p *Party) MarkConnected(member *Member, connected bool) {
	member.Connected = connected
	member.LastSeenMs = clock.NowMs()
	p.Touch()
	p.refreshEmptiness()
}

func (p *Party) refreshEmptiness() {
	if len(p.Members) == 0 {
		if p.EmptySinceMs == nil {
			now := clock.NowMs()
			p.EmptySinceMs = &now
		}
	} else {
		p.EmptySinceMs = nil
	}
}

func (p *Party) ExpiredMembers(now int64) []*Member {
	var expired []*Member
	for _, m := range p.Members {
		// A solo host who created the party must never be expired by inactivity
		// while waiting for friends to join or when switching between apps.
		if m.IsHost && len(p.Members) == 1 {
			continue
		}
		if !m.Connected && now-m.LastSeenMs > config.DisconnectGraceMs {
			expired = append(expired, m)
		}
	}
	return expired
}

func (p *Party) IsExpired(now int64) bool {
	if now-p.CreatedAtMs > config.PartyMaxAgeMs {
		return true
	}
	// A party expires as empty ONLY if it has zero members!
	if len(p.Members) == 0 {
		if p.EmptySinceMs != nil {
			return now-*p.EmptySinceMs > config.EmptyPartyTTLMs
		}
		return true
	}
	return false
}

func (p *Party) ToWire() map[string]interface{} {
	now := clock.NowMs()
	membersList := make([]*Member, 0, len(p.Members))
	for _, m := range p.Members {
		membersList = append(membersList, m)
	}
	sort.Slice(membersList, func(i, j int) bool {
		return membersList[i].JoinedAtMs < membersList[j].JoinedAtMs
	})

	membersWire := make([]map[string]interface{}, 0, len(membersList))
	for _, m := range membersList {
		membersWire = append(membersWire, m.ToWire())
	}

	return map[string]interface{}{
		"code":            p.Code,
		"createdAtMs":     p.CreatedAtMs,
		"maxMembers":      p.MaxMembers,
		"hostOnlyControl": p.HostOnlyControl,
		"members":         membersWire,
		"playback":        p.Playback.ToWire(now),
		"queue":           p.Playback.QueueToWire(),
		"serverMs":        now,
	}
}

// PartyStore holds all live parties in process memory.
type PartyStore struct {
	mu      sync.RWMutex
	parties map[string]*Party
}

func persistencePath() string {
	if custom := os.Getenv("JAM_STORAGE_PATH"); custom != "" {
		return custom
	}
	tmp := os.TempDir()
	return filepath.Join(tmp, "vibra_parties_store.json")
}

func (s *PartyStore) saveToDiskLocked() {
	filePath := persistencePath()
	data, err := json.Marshal(s.parties)
	if err != nil {
		return
	}
	tmpFile := filePath + ".tmp"
	if err := os.WriteFile(tmpFile, data, 0600); err == nil {
		_ = os.Rename(tmpFile, filePath)
	}
}

func (s *PartyStore) loadFromDiskLocked() {
	filePath := persistencePath()
	data, err := os.ReadFile(filePath)
	if err != nil {
		return
	}
	var loaded map[string]*Party
	if err := json.Unmarshal(data, &loaded); err == nil && loaded != nil {
		for k, v := range loaded {
			if _, exists := s.parties[k]; !exists && v != nil {
				s.parties[k] = v
			}
		}
	}
}

func (s *PartyStore) Save() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.saveToDiskLocked()
}

func NewPartyStore() *PartyStore {
	store := &PartyStore{
		parties: make(map[string]*Party),
	}
	store.mu.Lock()
	store.loadFromDiskLocked()
	store.mu.Unlock()
	return store
}

func (s *PartyStore) Len() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.parties)
}

func (s *PartyStore) Create() (*Party, error) {
	return s.CreateWithLimit(0)
}

// CreateWithLimit atomically rejects creation once the service-wide room limit
// is reached. A non-positive limit means unlimited (used by unit tests).
func (s *PartyStore) CreateWithLimit(maxParties int) (*Party, error) {
	return s.CreateWithLimits(maxParties, config.MaxMembers)
}

func (s *PartyStore) CreateWithLimits(maxParties, maxMembers int) (*Party, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if maxParties > 0 && len(s.parties) >= maxParties {
		return nil, NewPartyError(503, "server_full", "The party server is busy. Please try again in a few minutes.")
	}

	for i := 0; i < 12; i++ {
		code := codes.NewCode()
		if _, exists := s.parties[code]; !exists {
			p := NewPartyWithMaxMembers(code, maxMembers)
			s.parties[code] = p
			s.saveToDiskLocked()
			return p, nil
		}
	}
	return nil, NewPartyError(503, "code_exhausted", "Could not allocate a party code.")
}

func (s *PartyStore) Get(code string) (*Party, error) {
	norm := codes.Normalise(code)
	s.mu.RLock()
	p, ok := s.parties[norm]
	s.mu.RUnlock()
	if !ok {
		s.mu.Lock()
		s.loadFromDiskLocked()
		p, ok = s.parties[norm]
		s.mu.Unlock()
	}
	if !ok {
		return nil, NewPartyError(404, "no_such_party", "No party with that code.")
	}
	return p, nil
}

func (s *PartyStore) Find(code string) *Party {
	norm := codes.Normalise(code)
	s.mu.RLock()
	p, ok := s.parties[norm]
	s.mu.RUnlock()
	if !ok {
		s.mu.Lock()
		s.loadFromDiskLocked()
		p = s.parties[norm]
		s.mu.Unlock()
	}
	return p
}

func (s *PartyStore) Drop(code string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.parties, code)
	s.saveToDiskLocked()
}

func (s *PartyStore) All() []*Party {
	s.mu.RLock()
	defer s.mu.RUnlock()
	res := make([]*Party, 0, len(s.parties))
	for _, p := range s.parties {
		res = append(res, p)
	}
	return res
}

func (s *PartyStore) Sweep(now int64) []*Party {
	s.mu.Lock()
	defer s.mu.Unlock()

	var changed []*Party
	hadDeletions := false
	for code, party := range s.parties {
		party.Lock()
		gone := party.ExpiredMembers(now)
		for _, m := range gone {
			party.Remove(m.MemberId)
		}
		expired := party.IsExpired(now)
		party.Unlock()

		if expired {
			delete(s.parties, code)
			hadDeletions = true
			continue
		}
		if len(gone) > 0 {
			changed = append(changed, party)
		}
	}
	if hadDeletions || len(changed) > 0 {
		s.saveToDiskLocked()
	}
	return changed
}

func randomHex(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("crypto rand failed: %w", err)
	}
	return hex.EncodeToString(b), nil
}

func randomToken(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("crypto rand failed: %w", err)
	}
	return hex.EncodeToString(b), nil
}
