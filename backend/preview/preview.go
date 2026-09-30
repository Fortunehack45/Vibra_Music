package preview

import (
	"bytes"
	"context"
	_ "embed"
	"fmt"
	"image"
	"image/color"
	_ "image/jpeg"
	"image/png"
	"io"
	"math"
	"net"
	"net/http"
	"net/url"
	"strings"
	"syscall"
	"time"

	xdraw "golang.org/x/image/draw"
	"golang.org/x/image/font"
	"golang.org/x/image/font/opentype"
	"golang.org/x/image/math/fixed"
)

//go:embed app_logo.png
var appLogoBytes []byte

//go:embed app_icon.png
var appIconBytes []byte

//go:embed font_bold.otf
var fontBoldBytes []byte

//go:embed font_medium.otf
var fontMediumBytes []byte

const (
	Width  = 834
	Height = 1024
)

func isPrivateOrRestrictedIP(ip net.IP) bool {
	if ip == nil {
		return true
	}
	if ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsMulticast() || ip.IsUnspecified() {
		return true
	}
	if ipv4 := ip.To4(); ipv4 != nil {
		if ipv4[0] == 127 || ipv4[0] == 10 || ipv4[0] == 0 {
			return true
		}
		if ipv4[0] == 172 && (ipv4[1] >= 16 && ipv4[1] <= 31) {
			return true
		}
		if ipv4[0] == 192 && ipv4[1] == 168 {
			return true
		}
		if ipv4[0] == 169 && ipv4[1] == 254 { // Link-local & cloud metadata 169.254.169.254
			return true
		}
		if ipv4[0] >= 224 {
			return true
		}
	}
	return false
}

var safeTransport = &http.Transport{
	DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
		host, _, err := net.SplitHostPort(addr)
		if err != nil {
			return nil, err
		}
		ips, err := net.DefaultResolver.LookupIP(ctx, "ip", host)
		if err != nil {
			return nil, err
		}
		for _, ip := range ips {
			if isPrivateOrRestrictedIP(ip) {
				return nil, fmt.Errorf("ssrf prevention: restricted ip address %s for host %s", ip, host)
			}
		}
		var dialer net.Dialer
		dialer.Timeout = 2 * time.Second
		dialer.Control = func(network, address string, c syscall.RawConn) error {
			h, _, err := net.SplitHostPort(address)
			if err == nil {
				if ip := net.ParseIP(h); ip != nil && isPrivateOrRestrictedIP(ip) {
					return fmt.Errorf("ssrf prevention: raw connection blocked to %s", ip)
				}
			}
			return nil
		}
		return dialer.DialContext(ctx, network, addr)
	},
	ResponseHeaderTimeout: 3 * time.Second,
	TLSHandshakeTimeout:   3 * time.Second,
	MaxIdleConns:          10,
	IdleConnTimeout:       30 * time.Second,
}

var httpClient = &http.Client{
	Transport: safeTransport,
	Timeout:   4 * time.Second,
	CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) >= 2 {
			return fmt.Errorf("too many redirects")
		}
		if req.URL.Scheme != "https" {
			return fmt.Errorf("redirect to non-https rejected")
		}
		host := req.URL.Hostname()
		ips, err := net.LookupIP(host)
		if err != nil {
			return err
		}
		for _, ip := range ips {
			if isPrivateOrRestrictedIP(ip) {
				return fmt.Errorf("redirect to restricted ip %s rejected", ip)
			}
		}
		return nil
	},
}

var (
	cachedAppIcon image.Image
	cachedAppLogo image.Image

	fontBold   *opentype.Font
	fontMedium *opentype.Font

	faceSongTitle  font.Face
	faceSongArtist font.Face
	faceBrand      font.Face
	faceSender     font.Face
	faceInitial    font.Face
)

func init() {
	if len(appIconBytes) > 0 {
		cachedAppIcon, _ = png.Decode(bytes.NewReader(appIconBytes))
	}
	if len(appLogoBytes) > 0 {
		cachedAppLogo, _ = png.Decode(bytes.NewReader(appLogoBytes))
	}

	if len(fontBoldBytes) > 0 {
		fontBold, _ = opentype.Parse(fontBoldBytes)
	}
	if len(fontMediumBytes) > 0 {
		fontMedium, _ = opentype.Parse(fontMediumBytes)
	}

	if fontBold != nil {
		faceSongTitle, _ = opentype.NewFace(fontBold, &opentype.FaceOptions{Size: 46, DPI: 72, Hinting: font.HintingFull})
		faceBrand, _ = opentype.NewFace(fontBold, &opentype.FaceOptions{Size: 26, DPI: 72, Hinting: font.HintingFull})
		faceSender, _ = opentype.NewFace(fontBold, &opentype.FaceOptions{Size: 26, DPI: 72, Hinting: font.HintingFull})
		faceInitial, _ = opentype.NewFace(fontBold, &opentype.FaceOptions{Size: 40, DPI: 72, Hinting: font.HintingFull})
	}
	if fontMedium != nil {
		faceSongArtist, _ = opentype.NewFace(fontMedium, &opentype.FaceOptions{Size: 32, DPI: 72, Hinting: font.HintingFull})
	}
}

// GenerateCard produces an 834x1024 branded social preview card for Vibra Music Listen Together,
// featuring the prominent album cover, dynamic artwork color palette, bottom gradient, and host metadata.
func GenerateCard(code, hostName, avatarURL, songTitle, songArtist, coverURL string) ([]byte, error) {
	img := image.NewRGBA(image.Rect(0, 0, Width, Height))

	var coverImg image.Image
	if coverURL != "" {
		if fetched, err := fetchImage(coverURL); err == nil && fetched != nil {
			coverImg = fetched
		}
	}

	// 1. Extract dominant color from cover image and determine luminance
	bgR, bgG, bgB, isDark := extractDominantColor(coverImg)

	// 2. Compute bottom gradient target color based on background darkness
	var botR, botG, botB uint8
	if isDark {
		// When picked color is dark, bottom gradient fades to white
		botR, botG, botB = 255, 255, 255
	} else {
		// When picked color is light/medium, bottom gradient fades to dark black tint
		botR = uint8(float64(bgR) * 0.18)
		botG = uint8(float64(bgG) * 0.20)
		botB = uint8(float64(bgB) * 0.22)
	}

	// 3. Render smooth background gradient
	for y := 0; y < Height; y++ {
		t := float64(y) / float64(Height)
		factor := t * 0.95
		r := uint8(float64(bgR)*(1.0-factor) + float64(botR)*factor)
		g := uint8(float64(bgG)*(1.0-factor) + float64(botG)*factor)
		b := uint8(float64(bgB)*(1.0-factor) + float64(botB)*factor)
		for x := 0; x < Width; x++ {
			img.SetRGBA(x, y, color.RGBA{R: r, G: g, B: b, A: 255})
		}
	}

	// 4. Music Cover Artwork
	// Center horizontally: (834 - 690) / 2 = 72
	// Bounds: Rect(72, 63, 762, 753), Radius: 42
	coverRect := image.Rect(72, 63, 762, 753)
	drawCoverShadow(img, 72, 63, 690, 690, 42)

	if coverImg != nil {
		drawImageScaledCover(img, coverImg, coverRect, 42)
	} else {
		drawFallbackCover(img, coverRect, 42, bgR, bgG, bgB)
	}

	// 5. Text & Foreground Colors
	var textColor, subTextColor, borderCol color.RGBA
	if isDark {
		textColor = color.RGBA{R: 15, G: 23, B: 42, A: 255}       // #0f172a
		subTextColor = color.RGBA{R: 71, G: 85, B: 105, A: 245}    // #475569
		borderCol = color.RGBA{R: 15, G: 23, B: 42, A: 255}
	} else {
		textColor = color.RGBA{R: 255, G: 255, B: 255, A: 255}   // #ffffff
		subTextColor = color.RGBA{R: 226, G: 232, B: 240, A: 245} // #e2e8f0
		borderCol = color.RGBA{R: 255, G: 255, B: 255, A: 255}
	}

	// 6. Song Title & Artist (Bottom Left)
	title := strings.TrimSpace(songTitle)
	if title == "" {
		if strings.TrimSpace(code) != "" {
			title = "Vibra Party " + strings.ToUpper(code)
		} else {
			title = "Listen Together"
		}
	}
	title = truncateToWidth(title, 530, faceSongTitle)
	drawText(img, title, 75, 816, faceSongTitle, textColor)

	artist := strings.TrimSpace(songArtist)
	if artist == "" {
		artist = "Vibra Music"
	}
	artist = truncateToWidth(artist, 530, faceSongArtist)
	drawText(img, artist, 75, 878, faceSongArtist, subTextColor)

	// 7. Vibra Music Brand (Bottom Left)
	// Logo icon: 50x50 at x=75, y=926
	if cachedAppIcon != nil {
		drawIconWithTint(img, cachedAppIcon, 75, 926, 50, isDark)
	} else {
		drawFallbackAppIcon(img, 75, 926, 50)
	}
	drawText(img, "Vibra Music", 138, 964, faceBrand, textColor)

	// 8. Circular Profile Picture / Avatar (Bottom Right)
	// Center: (714, 862), Radius: 56 -> right edge at 770
	avatarCenterX := 714
	avatarCenterY := 862
	avatarRadius := 56

	// Outer border (4px)
	drawCircleFilled(img, avatarCenterX, avatarCenterY, avatarRadius, borderCol)

	// Inner image (radius 52)
	innerRadius := avatarRadius - 4
	avatarDrawn := false
	if avatarURL != "" {
		if fetchedAvatar, err := fetchImage(avatarURL); err == nil && fetchedAvatar != nil {
			drawCircularAvatar(img, fetchedAvatar, avatarCenterX, avatarCenterY, innerRadius)
			avatarDrawn = true
		}
	}
	if !avatarDrawn {
		drawFallbackAvatar(img, avatarCenterX, avatarCenterY, innerRadius, hostName)
	}

	// 9. Sender Name (Bottom Right)
	sender := strings.TrimSpace(hostName)
	if sender == "" {
		sender = "Party Host"
	}
	sender = truncateToWidth(sender, 280, faceSender)
	senderWidth := measureTextWidth(faceSender, sender)
	senderX := 770 - senderWidth
	drawText(img, sender, senderX, 964, faceSender, textColor)

	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func extractDominantColor(cover image.Image) (r, g, b uint8, isDark bool) {
	if cover == nil {
		return 51, 122, 154, false // Default teal
	}
	bounds := cover.Bounds()
	w := bounds.Dx()
	h := bounds.Dy()
	if w <= 0 || h <= 0 {
		return 51, 122, 154, false
	}
	var bestScore float64 = -1
	var bestR, bestG, bestB uint8 = 51, 122, 154
	var foundVibrant bool
	var sumR, sumG, sumB, totalCount uint64

	stepX := max(1, w/50)
	stepY := max(1, h/50)
	for y := bounds.Min.Y; y < bounds.Max.Y; y += stepY {
		for x := bounds.Min.X; x < bounds.Max.X; x += stepX {
			pr, pg, pb, pa := cover.At(x, y).RGBA()
			if pa < 128*257 {
				continue
			}
			cr := uint8(pr >> 8)
			cg := uint8(pg >> 8)
			cb := uint8(pb >> 8)

			sumR += uint64(cr)
			sumG += uint64(cg)
			sumB += uint64(cb)
			totalCount++

			maxC := max(cr, max(cg, cb))
			minC := min(cr, min(cg, cb))
			delta := maxC - minC
			lum := 0.299*float64(cr) + 0.587*float64(cg) + 0.114*float64(cb)
			if lum < 20 || lum > 235 {
				continue
			}
			sat := float64(delta) / float64(int(maxC)+1)
			score := sat * (1.0 - math.Abs(lum-128.0)/160.0)
			if score > bestScore {
				bestScore = score
				bestR, bestG, bestB = cr, cg, cb
				foundVibrant = true
			}
		}
	}

	if !foundVibrant && totalCount > 0 {
		bestR = uint8(sumR / totalCount)
		bestG = uint8(sumG / totalCount)
		bestB = uint8(sumB / totalCount)
	}

	lum := 0.299*float64(bestR) + 0.587*float64(bestG) + 0.114*float64(bestB)
	isDark = lum < 65.0
	return bestR, bestG, bestB, isDark
}

func drawCoverShadow(img *image.RGBA, x, y, w, h, radius int) {
	shadowRect := image.Rect(x-2, y+8, x+w+2, y+h+12)
	for py := shadowRect.Min.Y; py < shadowRect.Max.Y; py++ {
		for px := shadowRect.Min.X; px < shadowRect.Max.X; px++ {
			if insideRoundedRect(px, py, shadowRect, radius+4) {
				blendPixel(img, px, py, 0, 0, 0, 75)
			}
		}
	}
}

func drawImageScaledCover(dst *image.RGBA, src image.Image, r image.Rectangle, radius int) {
	bounds := src.Bounds()
	sw := bounds.Dx()
	sh := bounds.Dy()
	if sw <= 0 || sh <= 0 {
		return
	}
	side := min(sw, sh)
	cropMinX := bounds.Min.X + (sw-side)/2
	cropMinY := bounds.Min.Y + (sh-side)/2
	cropRect := image.Rect(cropMinX, cropMinY, cropMinX+side, cropMinY+side)

	w := r.Dx()
	h := r.Dy()
	scaled := image.NewRGBA(image.Rect(0, 0, w, h))
	xdraw.BiLinear.Scale(scaled, scaled.Bounds(), src, cropRect, xdraw.Over, nil)

	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			if radius <= 0 || insideRoundedRectLocal(x, y, w, h, radius) {
				c := scaled.RGBAAt(x, y)
				dst.SetRGBA(r.Min.X+x, r.Min.Y+y, c)
			}
		}
	}
}

func drawFallbackCover(img *image.RGBA, r image.Rectangle, radius int, bgR, bgG, bgB uint8) {
	for y := r.Min.Y; y < r.Max.Y; y++ {
		t := float64(y-r.Min.Y) / float64(r.Dy())
		cr := uint8(float64(bgR) * (0.8 + 0.3*t))
		cg := uint8(float64(bgG) * (0.8 + 0.3*t))
		cb := uint8(float64(bgB) * (0.8 + 0.3*t))
		for x := r.Min.X; x < r.Max.X; x++ {
			if insideRoundedRect(x, y, r, radius) {
				img.SetRGBA(x, y, color.RGBA{R: cr, G: cg, B: cb, A: 255})
			}
		}
	}
	cx := (r.Min.X + r.Max.X) / 2
	cy := (r.Min.Y + r.Max.Y) / 2
	drawRing(img, cx, cy, 140, 4, color.RGBA{R: 255, G: 255, B: 255, A: 40})
	drawRing(img, cx, cy, 90, 4, color.RGBA{R: 255, G: 255, B: 255, A: 60})
	drawCircleFilled(img, cx, cy, 45, color.RGBA{R: 255, G: 255, B: 255, A: 200})
	drawCircleFilled(img, cx, cy, 15, color.RGBA{R: bgR, G: bgG, B: bgB, A: 255})
}

func drawIconWithTint(dst *image.RGBA, src image.Image, x, y, size int, isDark bool) {
	scaled := image.NewRGBA(image.Rect(0, 0, size, size))
	xdraw.BiLinear.Scale(scaled, scaled.Bounds(), src, src.Bounds(), xdraw.Over, nil)
	for py := 0; py < size; py++ {
		for px := 0; px < size; px++ {
			c := scaled.RGBAAt(px, py)
			if c.A > 0 {
				if isDark {
					blendPixel(dst, x+px, y+py, 15, 23, 42, c.A)
				} else {
					blendPixel(dst, x+px, y+py, 255, 255, 255, c.A)
				}
			}
		}
	}
}

func truncateToWidth(s string, maxWidth int, face font.Face) string {
	if face == nil || measureTextWidth(face, s) <= maxWidth {
		return s
	}
	runes := []rune(s)
	for len(runes) > 1 {
		runes = runes[:len(runes)-1]
		cand := string(runes) + "..."
		if measureTextWidth(face, cand) <= maxWidth {
			return cand
		}
	}
	return s
}

func measureTextWidth(face font.Face, text string) int {
	if face == nil {
		return len(text) * 10
	}
	var d font.Drawer
	d.Face = face
	return d.MeasureString(text).Round()
}

func truncateRunes(s string, maxRunes int) string {
	runes := []rune(s)
	if len(runes) <= maxRunes {
		return s
	}
	if maxRunes <= 3 {
		return string(runes[:maxRunes])
	}
	return string(runes[:maxRunes-3]) + "..."
}

const maxImageBytes = 2 * 1024 * 1024 // 2 MB
const maxDimension = 2048

func fetchImage(rawURL string) (image.Image, error) {
	parsed, err := url.Parse(rawURL)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" {
		return nil, fmt.Errorf("invalid image url or unsupported non-https scheme")
	}

	req, err := http.NewRequest("GET", parsed.String(), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "VibraMusic-Bot/1.8.10")
	req.Header.Set("Accept", "image/png,image/jpeg,image/*;q=0.8")

	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, http.ErrMissingFile
	}

	limitedReader := io.LimitReader(resp.Body, maxImageBytes+1)
	data, err := io.ReadAll(limitedReader)
	if err != nil {
		return nil, err
	}
	if len(data) > maxImageBytes {
		return nil, fmt.Errorf("image exceeds maximum allowed size (2MB)")
	}

	cfg, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	if cfg.Width <= 0 || cfg.Height <= 0 || cfg.Width > maxDimension || cfg.Height > maxDimension {
		return nil, fmt.Errorf("image dimensions out of bounds: %dx%d", cfg.Width, cfg.Height)
	}

	img, _, err := image.Decode(bytes.NewReader(data))
	return img, err
}

func insideRoundedRectLocal(x, y, w, h, radius int) bool {
	if x >= radius && x < w-radius && y >= 0 && y < h {
		return true
	}
	if y >= radius && y < h-radius && x >= 0 && x < w {
		return true
	}
	var cx, cy int
	if x < radius {
		cx = radius
	} else {
		cx = w - radius - 1
	}
	if y < radius {
		cy = radius
	} else {
		cy = h - radius - 1
	}
	dx := x - cx
	dy := y - cy
	return dx*dx+dy*dy <= radius*radius
}

func drawFallbackAppIcon(img *image.RGBA, x, y, size int) {
	r := image.Rect(x, y, x+size, y+size)
	drawRoundedRect(img, r, 12, color.RGBA{R: 250, G: 45, B: 72, A: 255})
	drawCenteredText(img, "V", x+size/2, y+size/2+8, faceBrand, color.RGBA{R: 255, G: 255, B: 255, A: 255})
}

func drawCircularAvatar(dst *image.RGBA, src image.Image, cx, cy, radius int) {
	size := radius * 2
	bounds := src.Bounds()
	sw := bounds.Dx()
	sh := bounds.Dy()
	side := min(sw, sh)
	cropMinX := bounds.Min.X + (sw-side)/2
	cropMinY := bounds.Min.Y + (sh-side)/2
	cropRect := image.Rect(cropMinX, cropMinY, cropMinX+side, cropMinY+side)

	scaled := image.NewRGBA(image.Rect(0, 0, size, size))
	xdraw.BiLinear.Scale(scaled, scaled.Bounds(), src, cropRect, xdraw.Over, nil)

	r2 := radius * radius
	for dy := -radius; dy < radius; dy++ {
		for dx := -radius; dx < radius; dx++ {
			if dx*dx+dy*dy <= r2 {
				px := cx + dx
				py := cy + dy
				if px >= 0 && px < Width && py >= 0 && py < Height {
					col := scaled.RGBAAt(dx+radius, dy+radius)
					dst.SetRGBA(px, py, col)
				}
			}
		}
	}
}

func drawFallbackAvatar(img *image.RGBA, cx, cy, radius int, name string) {
	r2 := radius * radius
	for dy := -radius; dy <= radius; dy++ {
		for dx := -radius; dx <= radius; dx++ {
			if dx*dx+dy*dy <= r2 {
				px := cx + dx
				py := cy + dy
				if px >= 0 && px < Width && py >= 0 && py < Height {
					t := float64(dx+radius) / float64(2*radius)
					cr := uint8(100 + t*50)
					cg := uint8(60 + t*40)
					cb := uint8(220)
					img.SetRGBA(px, py, color.RGBA{R: cr, G: cg, B: cb, A: 255})
				}
			}
		}
	}
	initial := "V"
	if len(strings.TrimSpace(name)) > 0 {
		initial = strings.ToUpper(string([]rune(strings.TrimSpace(name))[0]))
	}
	drawCenteredText(img, initial, cx, cy+14, faceInitial, color.RGBA{R: 255, G: 255, B: 255, A: 255})
}

func drawRing(img *image.RGBA, cx, cy, radius, thickness int, col color.RGBA) {
	rInner2 := (radius - thickness) * (radius - thickness)
	rOuter2 := radius * radius
	for dy := -radius; dy <= radius; dy++ {
		for dx := -radius; dx <= radius; dx++ {
			d2 := dx*dx + dy*dy
			if d2 <= rOuter2 && d2 >= rInner2 {
				px := cx + dx
				py := cy + dy
				if px >= 0 && px < Width && py >= 0 && py < Height {
					blendPixel(img, px, py, col.R, col.G, col.B, col.A)
				}
			}
		}
	}
}

func drawCircleFilled(img *image.RGBA, cx, cy, radius int, col color.RGBA) {
	r2 := radius * radius
	for dy := -radius; dy <= radius; dy++ {
		for dx := -radius; dx <= radius; dx++ {
			if dx*dx+dy*dy <= r2 {
				blendPixel(img, cx+dx, cy+dy, col.R, col.G, col.B, col.A)
			}
		}
	}
}

func drawRoundedRect(img *image.RGBA, r image.Rectangle, radius int, col color.RGBA) {
	for y := r.Min.Y; y < r.Max.Y; y++ {
		for x := r.Min.X; x < r.Max.X; x++ {
			if insideRoundedRect(x, y, r, radius) {
				blendPixel(img, x, y, col.R, col.G, col.B, col.A)
			}
		}
	}
}

func insideRoundedRect(x, y int, r image.Rectangle, radius int) bool {
	if x >= r.Min.X+radius && x < r.Max.X-radius && y >= r.Min.Y && y < r.Max.Y {
		return true
	}
	if y >= r.Min.Y+radius && y < r.Max.Y-radius && x >= r.Min.X && x < r.Max.X {
		return true
	}
	var cx, cy int
	if x < r.Min.X+radius {
		cx = r.Min.X + radius
	} else {
		cx = r.Max.X - radius - 1
	}
	if y < r.Min.Y+radius {
		cy = r.Min.Y + radius
	} else {
		cy = r.Max.Y - radius - 1
	}
	dx := x - cx
	dy := y - cy
	return dx*dx+dy*dy <= radius*radius
}

func blendPixel(img *image.RGBA, x, y int, r, g, b, a uint8) {
	if a == 0 || x < 0 || x >= Width || y < 0 || y >= Height {
		return
	}
	if a == 255 {
		img.SetRGBA(x, y, color.RGBA{R: r, G: g, B: b, A: 255})
		return
	}
	orig := img.RGBAAt(x, y)
	alpha := float64(a) / 255.0
	invAlpha := 1.0 - alpha
	nr := uint8(float64(r)*alpha + float64(orig.R)*invAlpha)
	ng := uint8(float64(g)*alpha + float64(orig.G)*invAlpha)
	nb := uint8(float64(b)*alpha + float64(orig.B)*invAlpha)
	img.SetRGBA(x, y, color.RGBA{R: nr, G: ng, B: nb, A: 255})
}

func drawText(dst *image.RGBA, text string, x, y int, face font.Face, col color.RGBA) {
	if face == nil {
		return
	}
	d := &font.Drawer{
		Dst:  dst,
		Src:  image.NewUniform(col),
		Face: face,
		Dot:  fixed.Point26_6{X: fixed.I(x), Y: fixed.I(y)},
	}
	d.DrawString(text)
}

func drawCenteredText(dst *image.RGBA, text string, cx, y int, face font.Face, col color.RGBA) {
	if face == nil {
		return
	}
	d := &font.Drawer{
		Dst:  dst,
		Src:  image.NewUniform(col),
		Face: face,
	}
	width := d.MeasureString(text).Round()
	x := cx - width/2
	d.Dot = fixed.Point26_6{X: fixed.I(x), Y: fixed.I(y)}
	d.DrawString(text)
}
