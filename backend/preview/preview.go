package preview

import (
	"bytes"
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
	"golang.org/x/image/font/basicfont"
	"golang.org/x/image/math/fixed"
)

const (
	Width  = 1200
	Height = 630
)

var httpClient = &http.Client{
	Timeout: 3 * time.Second,
}

// GenerateCard produces a 1200x630 branded social preview PNG for Vibra Music Listen Together.
func GenerateCard(code, hostName, avatarURL, songTitle, songArtist string) ([]byte, error) {
	img := image.NewRGBA(image.Rect(0, 0, Width, Height))

	// 1. Draw rich dark gradient background
	for y := 0; y < Height; y++ {
		t := float64(y) / float64(Height)
		// Blend from #090a10 to #151628
		r := uint8(9 + t*12)
		g := uint8(10 + t*12)
		b := uint8(16 + t*24)
		for x := 0; x < Width; x++ {
			img.SetRGBA(x, y, color.RGBA{R: r, G: g, B: b, A: 255})
		}
	}

	// 2. Ambient radial glow in center & top-left
	drawRadialGlow(img, 600, 260, 360, color.RGBA{R: 124, G: 77, B: 255, A: 50})
	drawRadialGlow(img, 120, 100, 220, color.RGBA{R: 61, G: 90, B: 254, A: 40})
	drawRadialGlow(img, 1050, 500, 280, color.RGBA{R: 224, G: 64, B: 251, A: 30})

	// 3. Central Glassmorphic Card Container
	cardBounds := image.Rect(140, 70, 1060, 560)
	drawGlassCard(img, cardBounds, color.RGBA{R: 20, G: 20, B: 34, A: 215}, color.RGBA{R: 255, G: 255, B: 255, A: 30})

	// 4. Top-Left Badge: Vibra Music Logo & Listen Together
	drawAppLogo(img, 180, 105)
	drawScaledText(img, "VIBRA MUSIC", 244, 114, 2, color.RGBA{R: 255, G: 255, B: 255, A: 255})
	drawScaledText(img, "LISTEN TOGETHER", 246, 142, 1, color.RGBA{R: 179, G: 136, B: 255, A: 240})

	// 5. Host Avatar / Profile Section
	avatarRadius := 56
	avatarCenterX := 600
	avatarCenterY := 220

	// Glowing outer ring for avatar
	drawRing(img, avatarCenterX, avatarCenterY, avatarRadius+5, 3, color.RGBA{R: 124, G: 77, B: 255, A: 220})

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

	// 6. Host Invitation Label
	displayHost := hostName
	if displayHost == "" {
		displayHost = "Music Lover"
	}
	hostLine := displayHost + " invited you to listen"
	drawCenteredScaledText(img, hostLine, 600, 305, 2, color.RGBA{R: 245, G: 245, B: 250, A: 255})

	// 7. Now Playing Song or Subtitle
	if songTitle != "" {
		songLine := "Now Playing: " + songTitle
		if songArtist != "" {
			songLine += " - " + songArtist
		}
		if len(songLine) > 52 {
			songLine = songLine[:49] + "..."
		}
		drawCenteredScaledText(img, songLine, 600, 345, 1, color.RGBA{R: 190, G: 195, B: 220, A: 230})
	} else {
		drawCenteredScaledText(img, "Sync playback and listen together in real time", 600, 345, 1, color.RGBA{R: 160, G: 165, B: 190, A: 200})
	}

	// 8. Party Code Badge / Box
	codeBox := image.Rect(430, 385, 770, 465)
	drawRoundedRect(img, codeBox, 16, color.RGBA{R: 35, G: 32, B: 55, A: 240})
	drawRoundedRectBorder(img, codeBox, 16, color.RGBA{R: 124, G: 77, B: 255, A: 120})

	drawCenteredScaledText(img, "PARTY CODE", 600, 400, 1, color.RGBA{R: 160, G: 150, B: 200, A: 220})
	spacedCode := strings.ToUpper(strings.Join(strings.Split(code, ""), "  "))
	drawCenteredScaledText(img, spacedCode, 600, 428, 2, color.RGBA{R: 255, G: 255, B: 255, A: 255})

	// 9. Footer Info
	drawCenteredScaledText(img, "Tap invite link to launch Vibra Music on Android", 600, 505, 1, color.RGBA{R: 130, G: 130, B: 155, A: 180})

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
	req.Header.Set("User-Agent", "VibraMusic-Bot/1.8.0")
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

func drawGlassCard(img *image.RGBA, r image.Rectangle, fill, border color.RGBA) {
	drawRoundedRect(img, r, 24, fill)
	drawRoundedRectBorder(img, r, 24, border)
}

func drawAppLogo(img *image.RGBA, x, y int) {
	// Draw circular gradient emblem
	r := 22
	cx := x + r
	cy := y + r
	for py := cy - r; py <= cy + r; py++ {
		for px := cx - r; px <= cx + r; px++ {
			dx := px - cx
			dy := py - cy
			if dx*dx+dy*dy <= r*r {
				t := float64(dx+r) / float64(2*r)
				cr := uint8(124 + t*50)
				cg := uint8(77 + t*80)
				cb := uint8(255)
				blendPixel(img, px, py, cr, cg, cb, 255)
			}
		}
	}
	// Sound wave bars
	drawVibraWaveBars(img, cx, cy)
}

func drawVibraWaveBars(img *image.RGBA, cx, cy int) {
	heights := []int{10, 18, 26, 16, 8}
	startX := cx - 12
	white := color.RGBA{R: 255, G: 255, B: 255, A: 255}
	for i, h := range heights {
		bx := startX + i*6
		by := cy - h/2
		for y := by; y < by+h; y++ {
			img.SetRGBA(bx, y, white)
			img.SetRGBA(bx+1, y, white)
		}
	}
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
	drawCenteredScaledText(img, initial, cx, cy-8, 3, color.RGBA{R: 255, G: 255, B: 255, A: 255})
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

func drawScaledText(dst *image.RGBA, text string, x, y, scale int, col color.RGBA) {
	if scale <= 1 {
		d := &font.Drawer{
			Dst:  dst,
			Src:  image.NewUniform(col),
			Face: basicfont.Face7x13,
			Dot:  fixed.Point26_6{X: fixed.I(x), Y: fixed.I(y + 11)},
		}
		d.DrawString(text)
		return
	}

	rawWidth := len(text) * 7
	rawHeight := 13
	scratch := image.NewRGBA(image.Rect(0, 0, rawWidth, rawHeight))
	d := &font.Drawer{
		Dst:  scratch,
		Src:  image.NewUniform(col),
		Face: basicfont.Face7x13,
		Dot:  fixed.Point26_6{X: 0, Y: fixed.I(11)},
	}
	d.DrawString(text)

	scaledRect := image.Rect(x, y, x+rawWidth*scale, y+rawHeight*scale)
	xdraw.NearestNeighbor.Scale(dst, scaledRect, scratch, scratch.Bounds(), xdraw.Over, nil)
}

func drawCenteredScaledText(dst *image.RGBA, text string, cx, y, scale int, col color.RGBA) {
	charWidth := 7 * scale
	totalWidth := len(text) * charWidth
	x := cx - totalWidth/2
	drawScaledText(dst, text, x, y, scale, col)
}
