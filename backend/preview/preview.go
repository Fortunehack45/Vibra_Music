package preview

import (
	"bytes"
	_ "embed"
	"image"
	"image/color"
	_ "image/jpeg"
	"image/png"
	"math"
	"net/http"
	"strings"
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
	Width  = 1200
	Height = 630
)

var httpClient = &http.Client{
	Timeout: 3 * time.Second,
}

var (
	cachedAppIcon image.Image
	cachedAppLogo image.Image

	fontBold   *opentype.Font
	fontMedium *opentype.Font

	faceHeaderTitle font.Face
	faceTitle       font.Face
	faceSubtitle    font.Face
	faceBody        font.Face
	faceCode        font.Face
	faceBadge       font.Face
	faceSmall       font.Face
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
		faceHeaderTitle, _ = opentype.NewFace(fontBold, &opentype.FaceOptions{Size: 26, DPI: 72, Hinting: font.HintingFull})
		faceTitle, _ = opentype.NewFace(fontBold, &opentype.FaceOptions{Size: 32, DPI: 72, Hinting: font.HintingFull})
		faceCode, _ = opentype.NewFace(fontBold, &opentype.FaceOptions{Size: 32, DPI: 72, Hinting: font.HintingFull})
		faceBadge, _ = opentype.NewFace(fontBold, &opentype.FaceOptions{Size: 14, DPI: 72, Hinting: font.HintingFull})
	}
	if fontMedium != nil {
		faceSubtitle, _ = opentype.NewFace(fontMedium, &opentype.FaceOptions{Size: 20, DPI: 72, Hinting: font.HintingFull})
		faceBody, _ = opentype.NewFace(fontMedium, &opentype.FaceOptions{Size: 18, DPI: 72, Hinting: font.HintingFull})
		faceSmall, _ = opentype.NewFace(fontMedium, &opentype.FaceOptions{Size: 14, DPI: 72, Hinting: font.HintingFull})
	}
}

// GenerateCard produces a 1200x630 branded social preview PNG for Vibra Music Listen Together,
// featuring the authentic official app logo and Liquid Glass player UI matching the Android app.
func GenerateCard(code, hostName, avatarURL, songTitle, songArtist string) ([]byte, error) {
	img := image.NewRGBA(image.Rect(0, 0, Width, Height))

	// 1. Deep OLED Dark Background (#050508 to #0D0E16)
	for y := 0; y < Height; y++ {
		t := float64(y) / float64(Height)
		r := uint8(5 + t*8)
		g := uint8(5 + t*9)
		b := uint8(8 + t*14)
		for x := 0; x < Width; x++ {
			img.SetRGBA(x, y, color.RGBA{R: r, G: g, B: b, A: 255})
		}
	}

	// 2. Dynamic Liquid Glass ambient glow / mesh gradient
	// Vibra Music signature red accent glow on top-left (#FA2D48)
	drawRadialGlow(img, 180, 100, 320, color.RGBA{R: 250, G: 45, B: 72, A: 50})
	// Aurora Purple Glow centered around player card (#7C4DFF)
	drawRadialGlow(img, 620, 290, 440, color.RGBA{R: 124, G: 77, B: 255, A: 58})
	// Deep indigo/violet sheen on bottom-right (#3D5AFE)
	drawRadialGlow(img, 1050, 480, 340, color.RGBA{R: 61, G: 90, B: 254, A: 40})

	// 3. Header Bar: Official App Logo + Vibra Music Brand + Live Badge
	// Official App Launcher Icon (52x52 with 13px rounded corners)
	iconRect := image.Rect(100, 40, 154, 94)
	if cachedAppIcon != nil {
		drawImageScaled(img, cachedAppIcon, iconRect, 13)
	} else {
		drawFallbackAppIcon(img, 100, 40, 54)
	}

	// Brand title and subtitle using real SF Pro Display typography
	drawText(img, "Vibra Music", 168, 64, faceHeaderTitle, color.RGBA{R: 255, G: 255, B: 255, A: 255})
	drawText(img, "LISTEN TOGETHER", 170, 85, faceBadge, color.RGBA{R: 179, G: 136, B: 255, A: 240})

	// Right header: "LIVE ROOM" glass pill badge
	livePill := image.Rect(910, 46, 1100, 88)
	drawGlassCard(img, livePill, 16, color.RGBA{R: 18, G: 26, B: 22, A: 220}, color.RGBA{R: 0, G: 230, B: 118, A: 130})
	drawCircleFilled(img, 936, 67, 5, color.RGBA{R: 0, G: 230, B: 118, A: 255})
	drawText(img, "LIVE ROOM", 952, 72, faceBadge, color.RGBA{R: 0, G: 230, B: 118, A: 255})

	// 4. Central Liquid Glass Player Card Container
	cardBounds := image.Rect(100, 112, 1100, 580)
	drawGlassCard(img, cardBounds, 28, color.RGBA{R: 13, G: 14, B: 22, A: 228}, color.RGBA{R: 255, G: 255, B: 255, A: 36})

	// 5. Host Info Section (Avatar with glowing ring + invitation)
	avatarRadius := 38
	avatarCenterX := 165
	avatarCenterY := 168

	drawRing(img, avatarCenterX, avatarCenterY, avatarRadius+5, 3, color.RGBA{R: 124, G: 77, B: 255, A: 230})

	avatarDrawn := false
	if avatarURL != "" {
		if fetched, err := fetchImage(avatarURL); err == nil && fetched != nil {
			drawCircularAvatar(img, fetched, avatarCenterX, avatarCenterY, avatarRadius)
			avatarDrawn = true
		}
	}
	if !avatarDrawn {
		drawFallbackAvatar(img, avatarCenterX, avatarCenterY, avatarRadius, hostName)
	}

	displayHost := strings.TrimSpace(hostName)
	if displayHost == "" {
		displayHost = "Music Lover"
	}
	hostHeader := displayHost + " started a listening party"
	drawText(img, hostHeader, 222, 162, faceBody, color.RGBA{R: 245, G: 245, B: 252, A: 255})
	drawText(img, "Synced music playback · Real-time listen together", 224, 184, faceSmall, color.RGBA{R: 160, G: 162, B: 185, A: 220})

	// Divider line
	drawLine(img, 130, 214, 1070, 214, 1, color.RGBA{R: 255, G: 255, B: 255, A: 22})

	// 6. Now Playing Section (Album Art + Title + Artist + Hi-Res Badge)
	artRect := image.Rect(135, 230, 207, 302)
	drawAlbumArtPlaceholder(img, artRect)

	trackTitle := songTitle
	if strings.TrimSpace(trackTitle) == "" {
		trackTitle = "Synchronized Listening Room"
	}
	if len(trackTitle) > 34 {
		trackTitle = trackTitle[:31] + "..."
	}
	drawText(img, trackTitle, 225, 262, faceTitle, color.RGBA{R: 255, G: 255, B: 255, A: 255})

	trackArtist := songArtist
	if strings.TrimSpace(trackArtist) == "" {
		trackArtist = "Vibra Music Party · YouTube Music Library"
	}
	if len(trackArtist) > 46 {
		trackArtist = trackArtist[:43] + "..."
	}
	drawText(img, trackArtist, 227, 292, faceSubtitle, color.RGBA{R: 168, G: 172, B: 195, A: 230})

	// Audio Format Badge: HI-RES LOSSLESS pill (like in the app)
	qualityPill := image.Rect(870, 248, 1060, 286)
	drawGlassCard(img, qualityPill, 12, color.RGBA{R: 28, G: 22, B: 48, A: 235}, color.RGBA{R: 179, G: 136, B: 255, A: 160})
	drawCenteredText(img, "HI-RES LOSSLESS", 965, 272, faceBadge, color.RGBA{R: 225, G: 215, B: 255, A: 255})

	// 7. Scrubber / Progress Bar (matching the app's player slider)
	scrubberStartX := 135
	scrubberEndX := 1060
	scrubberY := 332
	scrubberWidth := scrubberEndX - scrubberStartX
	scrubberProgress := int(float64(scrubberWidth) * 0.44)

	// Inactive track
	drawLine(img, scrubberStartX, scrubberY, scrubberEndX, scrubberY, 4, color.RGBA{R: 255, G: 255, B: 255, A: 38})
	// Active track (white)
	drawLine(img, scrubberStartX, scrubberY, scrubberStartX+scrubberProgress, scrubberY, 4, color.RGBA{R: 255, G: 255, B: 255, A: 245})
	// Scrubber thumb
	drawCircleFilled(img, scrubberStartX+scrubberProgress, scrubberY, 7, color.RGBA{R: 255, G: 255, B: 255, A: 255})

	// Timestamps
	drawText(img, "1:24", scrubberStartX, scrubberY+20, faceSmall, color.RGBA{R: 145, G: 145, B: 170, A: 210})
	drawText(img, "-2:16", scrubberEndX-42, scrubberY+20, faceSmall, color.RGBA{R: 145, G: 145, B: 170, A: 210})

	// 8. Player Transport Controls (Previous, Play Circle, Next)
	controlsCenterY := 390
	controlsCenterX := 600

	// Previous Button (|◀◀)
	drawPreviousIcon(img, controlsCenterX-95, controlsCenterY)

	// Large Primary Play Button (Glass/White Circle with dark play triangle)
	playRadius := 28
	drawCircleFilled(img, controlsCenterX, controlsCenterY, playRadius, color.RGBA{R: 255, G: 255, B: 255, A: 255})
	drawPlayTriangle(img, controlsCenterX+3, controlsCenterY, 11, color.RGBA{R: 15, G: 15, B: 22, A: 255})

	// Next Button (▶▶|)
	drawNextIcon(img, controlsCenterX+95, controlsCenterY)

	// 9. Party Code Box & Join Prompt (matching app party sheet)
	codeBox := image.Rect(370, 442, 830, 520)
	drawGlassCard(img, codeBox, 18, color.RGBA{R: 25, G: 20, B: 46, A: 238}, color.RGBA{R: 124, G: 77, B: 255, A: 175})

	drawCenteredText(img, "PARTY CODE", 600, 460, faceSmall, color.RGBA{R: 179, G: 136, B: 255, A: 240})
	spacedCode := strings.ToUpper(strings.Join(strings.Split(code, ""), "   "))
	drawCenteredText(img, spacedCode, 600, 498, faceCode, color.RGBA{R: 255, G: 255, B: 255, A: 255})

	// Footer call to action
	drawCenteredText(img, "Tap invite link to launch Vibra Music & listen in real time", 600, 544, faceSmall, color.RGBA{R: 145, G: 148, B: 178, A: 220})

	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func fetchImage(url string) (image.Image, error) {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "VibraMusic-Bot/1.8.1")
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, http.ErrMissingFile
	}
	img, _, err := image.Decode(resp.Body)
	return img, err
}

func drawImageScaled(dst *image.RGBA, src image.Image, r image.Rectangle, radius int) {
	w := r.Dx()
	h := r.Dy()
	scaled := image.NewRGBA(image.Rect(0, 0, w, h))
	xdraw.BiLinear.Scale(scaled, scaled.Bounds(), src, src.Bounds(), xdraw.Over, nil)

	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			if radius <= 0 || insideRoundedRectLocal(x, y, w, h, radius) {
				c := scaled.RGBAAt(x, y)
				blendPixel(dst, r.Min.X+x, r.Min.Y+y, c.R, c.G, c.B, c.A)
			}
		}
	}
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

func drawRadialGlow(img *image.RGBA, cx, cy, radius int, col color.RGBA) {
	r2 := float64(radius * radius)
	minX := max(0, cx-radius)
	maxX := min(Width-1, cx+radius)
	minY := max(0, cy-radius)
	maxY := min(Height-1, cy+radius)

	for y := minY; y <= maxY; y++ {
		dy := float64(y - cy)
		for x := minX; x <= maxX; x++ {
			dx := float64(x - cx)
			dist2 := dx*dx + dy*dy
			if dist2 < r2 {
				factor := 1.0 - math.Sqrt(dist2)/float64(radius)
				alpha := float64(col.A) * factor * factor
				blendPixel(img, x, y, col.R, col.G, col.B, uint8(alpha))
			}
		}
	}
}

func drawGlassCard(img *image.RGBA, r image.Rectangle, radius int, fill, border color.RGBA) {
	drawRoundedRect(img, r, radius, fill)
	drawRoundedRectBorder(img, r, radius, border)
}

func drawAlbumArtPlaceholder(img *image.RGBA, r image.Rectangle) {
	drawRoundedRect(img, r, 16, color.RGBA{R: 35, G: 25, B: 60, A: 245})
	drawRoundedRectBorder(img, r, 16, color.RGBA{R: 124, G: 77, B: 255, A: 140})

	// Inner Vinyl Sheen Circles
	cx := (r.Min.X + r.Max.X) / 2
	cy := (r.Min.Y + r.Max.Y) / 2
	drawRing(img, cx, cy, 26, 2, color.RGBA{R: 255, G: 255, B: 255, A: 40})
	drawRing(img, cx, cy, 18, 2, color.RGBA{R: 255, G: 255, B: 255, A: 60})
	drawCircleFilled(img, cx, cy, 9, color.RGBA{R: 250, G: 45, B: 72, A: 240})
	drawCircleFilled(img, cx, cy, 3, color.RGBA{R: 255, G: 255, B: 255, A: 255})
}

func drawFallbackAppIcon(img *image.RGBA, x, y, size int) {
	r := image.Rect(x, y, x+size, y+size)
	drawRoundedRect(img, r, 13, color.RGBA{R: 250, G: 45, B: 72, A: 255})
	drawCenteredText(img, "V", x+size/2, y+size/2+8, faceTitle, color.RGBA{R: 255, G: 255, B: 255, A: 255})
}

func drawCircularAvatar(dst *image.RGBA, src image.Image, cx, cy, radius int) {
	size := radius * 2
	scaled := image.NewRGBA(image.Rect(0, 0, size, size))
	xdraw.BiLinear.Scale(scaled, scaled.Bounds(), src, src.Bounds(), xdraw.Over, nil)

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
	drawCenteredText(img, initial, cx, cy+9, faceHeaderTitle, color.RGBA{R: 255, G: 255, B: 255, A: 255})
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

func drawLine(img *image.RGBA, x1, y, x2, _ int, thickness int, col color.RGBA) {
	half := thickness / 2
	for py := y - half; py <= y+half; py++ {
		for px := x1; px <= x2; px++ {
			blendPixel(img, px, py, col.R, col.G, col.B, col.A)
		}
	}
}

func drawPlayTriangle(img *image.RGBA, cx, cy, size int, col color.RGBA) {
	for dy := -size; dy <= size; dy++ {
		maxX := int(float64(size-int(math.Abs(float64(dy)))) * 1.3)
		for dx := -size / 2; dx <= maxX; dx++ {
			blendPixel(img, cx+dx, cy+dy, col.R, col.G, col.B, col.A)
		}
	}
}

func drawNextIcon(img *image.RGBA, cx, cy int) {
	white := color.RGBA{R: 220, G: 220, B: 240, A: 230}
	drawPlayTriangle(img, cx-6, cy, 9, white)
	drawPlayTriangle(img, cx+4, cy, 9, white)
	drawLine(img, cx+13, cy-9, cx+13, cy+9, 2, white)
}

func drawPreviousIcon(img *image.RGBA, cx, cy int) {
	white := color.RGBA{R: 220, G: 220, B: 240, A: 230}
	drawLine(img, cx-13, cy-9, cx-13, cy+9, 2, white)
	// Left pointing triangles
	for dy := -9; dy <= 9; dy++ {
		minX := -int(float64(9-int(math.Abs(float64(dy)))) * 1.3)
		for dx := minX; dx <= 9/2; dx++ {
			blendPixel(img, cx-4+dx, cy+dy, white.R, white.G, white.B, white.A)
			blendPixel(img, cx+6+dx, cy+dy, white.R, white.G, white.B, white.A)
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

func drawRoundedRectBorder(img *image.RGBA, r image.Rectangle, radius int, col color.RGBA) {
	for y := r.Min.Y; y < r.Max.Y; y++ {
		for x := r.Min.X; x < r.Max.X; x++ {
			if insideRoundedRect(x, y, r, radius) && !insideRoundedRect(x, y, image.Rect(r.Min.X+1, r.Min.Y+1, r.Max.X-1, r.Max.Y-1), radius-1) {
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
