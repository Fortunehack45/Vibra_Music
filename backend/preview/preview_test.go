package preview

import (
	"bytes"
	"image/png"
	"testing"
)

func TestGenerateCard(t *testing.T) {
	pngBytes, err := GenerateCard("VIBRA1", "Fortune", "", "Starboy", "The Weeknd")
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
