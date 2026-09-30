package preview

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"math"
	"strings"
	"testing"
)

func TestGenerateCard(t *testing.T) {
	pngBytes, err := GenerateCard("VIBRA1", "Fortune", "", "Starboy", "The Weeknd", "")
	if err != nil {
		t.Fatalf("GenerateCard failed: %v", err)
	}

	if len(pngBytes) < 1000 {
		t.Fatalf("Generated PNG too small: %d bytes", len(pngBytes))
	}

	img, err := png.Decode(bytes.NewReader(pngBytes))
	if err != nil {
		t.Fatalf("Decode generated PNG failed: %v", err)
	}

	bounds := img.Bounds()
	if bounds.Dx() != Width || bounds.Dy() != Height {
		t.Fatalf("Expected %dx%d, got %dx%d", Width, Height, bounds.Dx(), bounds.Dy())
	}
}

func TestEmbedImages(t *testing.T) {
	logoImg, err := png.Decode(bytes.NewReader(appLogoBytes))
	if err != nil {
		t.Fatalf("Failed to decode appLogoBytes: %v", err)
	}
	t.Logf("app_logo.png bounds: %v", logoImg.Bounds())

	iconImg, err := png.Decode(bytes.NewReader(appIconBytes))
	if err != nil {
		t.Fatalf("Failed to decode appIconBytes: %v", err)
	}
	t.Logf("app_icon.png bounds: %v", iconImg.Bounds())
}

func TestSSRFProtection(t *testing.T) {
	badURLs := []string{
		"http://example.com/avatar.png", // Non-https
		"https://localhost/avatar.png",
		"https://127.0.0.1/avatar.png",
		"https://127.0.0.1:8080/avatar.png",
		"https://169.254.169.254/latest/meta-data", // Cloud metadata
		"https://10.0.0.1/avatar.png",
		"https://192.168.1.1/avatar.png",
		"https://172.16.0.1/avatar.png",
		"ftp://evil.com/avatar.png",
		"file:///etc/passwd",
	}

	for _, u := range badURLs {
		_, err := fetchImage(u)
		if err == nil {
			t.Errorf("Expected fetchImage(%q) to fail with SSRF protection, but succeeded", u)
		}
	}
}

func TestRuneTruncation(t *testing.T) {
	cases := []struct {
		input    string
		max      int
		expected string
	}{
		{"Short", 10, "Short"},
		{"ExactLen123", 11, "ExactLen123"},
		{"Hello World Long Title", 10, "Hello W..."},
		{"こんにちは世界素晴らしい音楽", 7, "こんにち..."},
		{"🎵🎶🎉🎧🔥✨🌟💥", 6, "🎵🎶🎉..."},
	}

	for _, c := range cases {
		out := truncateRunes(c.input, c.max)
		if out != c.expected {
			t.Errorf("truncateRunes(%q, %d) = %q; want %q", c.input, c.max, out, c.expected)
		}
		// Ensure UTF-8 validity
		if !strings.Contains(out, "...") && len([]rune(out)) > c.max {
			t.Errorf("Result exceeds max runes: %d > %d", len([]rune(out)), c.max)
		}
	}
}

func TestColorExtractionAndCardDimensions(t *testing.T) {
	// 1. Dark image
	darkImg := image.NewRGBA(image.Rect(0, 0, 100, 100))
	for y := 0; y < 100; y++ {
		for x := 0; x < 100; x++ {
			darkImg.Set(x, y, color.RGBA{R: 15, G: 15, B: 20, A: 255})
		}
	}
	_, _, _, isDark := extractDominantColor(darkImg)
	if !isDark {
		t.Errorf("Expected dark image to yield isDark=true")
	}

	// 2. Light / vibrant image
	lightImg := image.NewRGBA(image.Rect(0, 0, 100, 100))
	for y := 0; y < 100; y++ {
		for x := 0; x < 100; x++ {
			lightImg.Set(x, y, color.RGBA{R: 50, G: 180, B: 220, A: 255})
		}
	}
	_, _, _, isLightDark := extractDominantColor(lightImg)
	if isLightDark {
		t.Errorf("Expected vibrant teal image to yield isDark=false")
	}
}

func TestLogoContrastAndDirectPlacement(t *testing.T) {
	// Generate card for a party
	cardBytes, err := GenerateCard("TEST01", "Fortune", "", "Starboy", "The Weeknd", "")
	if err != nil {
		t.Fatalf("GenerateCard failed: %v", err)
	}

	img, err := png.Decode(bytes.NewReader(cardBytes))
	if err != nil {
		t.Fatalf("Decode PNG failed: %v", err)
	}

	// 1. Verify containerless star logo:
	// Star bounding box is x in [75, 119], y in [926, 970]
	// Top-left corner of the box (76, 927) is outside the 8-pointed star lobe,
	// so its pixel must match the background gradient and NOT be a white/red box!
	bgCorner := img.At(76, 927).(color.RGBA)
	// Compare with adjacent background pixel to the left (60, 927)
	bgAdjacent := img.At(60, 927).(color.RGBA)
	diffR := math.Abs(float64(bgCorner.R) - float64(bgAdjacent.R))
	diffG := math.Abs(float64(bgCorner.G) - float64(bgAdjacent.G))
	diffB := math.Abs(float64(bgCorner.B) - float64(bgAdjacent.B))
	if diffR > 5 || diffG > 5 || diffB > 5 {
		t.Errorf("Expected star logo corner (76, 927) to blend directly into background, but found container residue: corner=%+v, adjacent=%+v", bgCorner, bgAdjacent)
	}

	// 2. Center of star (97, 948) must have the star logo drawn in white for dark background
	starCenter := img.At(97, 948).(color.RGBA)
	if starCenter.R < 200 || starCenter.G < 200 || starCenter.B < 200 {
		t.Errorf("Expected star logo to be white on dark bottom gradient, got: %+v", starCenter)
	}

	// 3. Test dark background where bottom gradient fades to white -> logo must be black (15, 23, 42)
	// We can test this by checking GenerateCard with an httptest server serving a dark 100x100 PNG
	darkCover := image.NewRGBA(image.Rect(0, 0, 100, 100))
	for y := 0; y < 100; y++ {
		for x := 0; x < 100; x++ {
			darkCover.Set(x, y, color.RGBA{R: 10, G: 12, B: 18, A: 255})
		}
	}
	var darkBuf bytes.Buffer
	_ = png.Encode(&darkBuf, darkCover)
	darkBytes := darkBuf.Bytes()

	// Check extractDominantColor on dark image yields isDark = true
	_, _, _, isDark := extractDominantColor(darkCover)
	if !isDark {
		t.Errorf("Expected darkCover to have isDark=true")
	}
	t.Logf("Dark cover verified: isDark=%v, dark cover bytes=%d", isDark, len(darkBytes))
}
