#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Resize the checked-in platform masters; no image generation or new dependencies.
for platform in macOS iOS; do
    source="$ROOT/apple/Artwork/AppIcon-$platform.png"
    catalog="$ROOT/apple/Apps/$platform/Assets.xcassets"
    destination="$catalog/AppIcon.appiconset"
    [[ -f "$source" ]] || { echo "Missing icon master: $source" >&2; exit 1; }
    if [[ "$platform" == iOS ]]; then
        /usr/bin/sips -g hasAlpha "$source" | /usr/bin/grep -q 'hasAlpha: no' || {
            echo 'The iOS icon master must be opaque.' >&2
            exit 1
        }
        sizes=(20 29 40 58 60 76 80 87 120 152 167 180 1024)
    else
        sizes=(16 32 64 128 256 512 1024)
    fi
    mkdir -p "$destination"
    cat > "$catalog/Contents.json" <<'JSON'
{
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
    for pixels in "${sizes[@]}"; do
        /usr/bin/sips -s format png -z "$pixels" "$pixels" "$source" \
            --out "$destination/AppIcon-$pixels.png" > /dev/null
    done
done

cat > "$ROOT/apple/Apps/macOS/Assets.xcassets/AppIcon.appiconset/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "AppIcon-16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "AppIcon-32.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "AppIcon-32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "AppIcon-64.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "AppIcon-128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "AppIcon-256.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "AppIcon-256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "AppIcon-512.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "AppIcon-512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "AppIcon-1024.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

cat > "$ROOT/apple/Apps/iOS/Assets.xcassets/AppIcon.appiconset/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "AppIcon-40.png", "idiom" : "iphone", "scale" : "2x", "size" : "20x20" },
    { "filename" : "AppIcon-60.png", "idiom" : "iphone", "scale" : "3x", "size" : "20x20" },
    { "filename" : "AppIcon-58.png", "idiom" : "iphone", "scale" : "2x", "size" : "29x29" },
    { "filename" : "AppIcon-87.png", "idiom" : "iphone", "scale" : "3x", "size" : "29x29" },
    { "filename" : "AppIcon-80.png", "idiom" : "iphone", "scale" : "2x", "size" : "40x40" },
    { "filename" : "AppIcon-120.png", "idiom" : "iphone", "scale" : "3x", "size" : "40x40" },
    { "filename" : "AppIcon-120.png", "idiom" : "iphone", "scale" : "2x", "size" : "60x60" },
    { "filename" : "AppIcon-180.png", "idiom" : "iphone", "scale" : "3x", "size" : "60x60" },
    { "filename" : "AppIcon-20.png", "idiom" : "ipad", "scale" : "1x", "size" : "20x20" },
    { "filename" : "AppIcon-40.png", "idiom" : "ipad", "scale" : "2x", "size" : "20x20" },
    { "filename" : "AppIcon-29.png", "idiom" : "ipad", "scale" : "1x", "size" : "29x29" },
    { "filename" : "AppIcon-58.png", "idiom" : "ipad", "scale" : "2x", "size" : "29x29" },
    { "filename" : "AppIcon-40.png", "idiom" : "ipad", "scale" : "1x", "size" : "40x40" },
    { "filename" : "AppIcon-80.png", "idiom" : "ipad", "scale" : "2x", "size" : "40x40" },
    { "filename" : "AppIcon-76.png", "idiom" : "ipad", "scale" : "1x", "size" : "76x76" },
    { "filename" : "AppIcon-152.png", "idiom" : "ipad", "scale" : "2x", "size" : "76x76" },
    { "filename" : "AppIcon-167.png", "idiom" : "ipad", "scale" : "2x", "size" : "83.5x83.5" },
    { "filename" : "AppIcon-1024.png", "idiom" : "ios-marketing", "scale" : "1x", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

# Shared monochrome brand glyph, tinted by SwiftUI for light and dark appearances.
brand="$ROOT/apple/Resources/BrandAssets.xcassets/ConnDockBrand.imageset"
mkdir -p "$brand"
cat > "$ROOT/apple/Resources/BrandAssets.xcassets/Contents.json" <<'JSON'
{
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
for scale in 1 2 3; do
    pixels=$((32 * scale))
    /usr/bin/sips -s format png -z "$pixels" "$pixels" "$ROOT/apple/Artwork/BrandIcon.png" \
        --out "$brand/ConnDockBrand-${scale}x.png" > /dev/null
done
cat > "$brand/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "ConnDockBrand-1x.png", "idiom" : "universal", "scale" : "1x" },
    { "filename" : "ConnDockBrand-2x.png", "idiom" : "universal", "scale" : "2x" },
    { "filename" : "ConnDockBrand-3x.png", "idiom" : "universal", "scale" : "3x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "template-rendering-intent" : "template" }
}
JSON
echo 'Generated platform AppIcon assets and shared monochrome brand assets from apple/Artwork/.'
