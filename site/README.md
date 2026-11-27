# LumaWall website

Static HTML, CSS and vanilla JavaScript. No build step.

## Preview

```sh
python3 -m http.server -d site 8000
```

Open <http://localhost:8000>.

## Test

```sh
node --test 'site/tests/*.test.*'
```

## Deployment

The site is hosted on Vercel as a static project whose root is `site/`.
`site/vercel.json` sets the security headers (a strict Content Security
Policy: no inline scripts or styles, no third-party requests; `media-src 'self'` allows the clips) and caching (scripts and styles revalidate on every load, so a deploy never pairs new HTML with stale JavaScript).
`site/.vercelignore` keeps the tests and this README out of the deploy.

Deploy from the repo root:

```sh
npx vercel@latest deploy site --prod
```

## Production origin

Use the canonical link in `site/index.html` as the source for the production origin.
Crawlers read these static files directly, so the social tags, robots file, and sitemap
also contain absolute URLs. To move domains, run this from the repo root before
editing the canonical link. Supply the new HTTPS origin without a trailing slash.

```sh
python3 - 'https://new.example.com' <<'PYTHON'
import re
import sys
from pathlib import Path

site = Path("site")
html = (site / "index.html").read_text()
origin = re.search(r'<link rel="canonical" href="(https://[^/]+)/" />', html)[1]
for name in ("index.html", "robots.txt", "sitemap.xml"):
    path = site / name
    path.write_text(path.read_text().replace(origin + "/", sys.argv[1] + "/"))
PYTHON
```

## Social preview

Regenerate `site/og.png` from the repo root with ImageMagick 7 and the macOS
Helvetica Neue font. The waterfall comes from the wall-3 poster (`wall-3-1600.jpg`). Its
source and license are in [the media credits](media/CREDITS.md). The indexed palette
keeps the 1200 × 630 card under 250 KB.

```sh
magick -size 1200x630 xc:'#f5f5f7' \
  \( site/media/wall-3-1600.jpg -resize '600x506^' -gravity center -extent 600x506 \
     \( -size 600x506 xc:none -fill white -draw 'roundrectangle 0,0 599,505 32,32' \) \
     -alpha off -compose CopyOpacity -composite \) \
  -gravity northwest -geometry +538+62 -compose Over -composite \
  \( site/icon.png -resize 48x48 \
     \( -size 48x48 xc:none -fill white -draw 'roundrectangle 0,0 47,47 11,11' \) \
     -alpha off -compose CopyOpacity -composite \) -geometry +62+146 -compose Over -composite \
  -font /System/Library/Fonts/HelveticaNeue.ttc -fill '#1d1d1f' \
  -weight 600 -pointsize 32 -annotate +122+150 'LumaWall' \
  -weight 700 -pointsize 63 -kerning -2 -interline-spacing -7 \
  -annotate +62+241 'Your videos as\nlive Mac\nwallpapers.' \
  -strip +dither -colors 256 PNG8:site/og.png
```

## Media

`site/media/` holds the wallpaper clips `wall-1.mp4` through `wall-6.mp4`.
Their posters have 800- and 1600-pixel-wide variants in AVIF, WebP, and JPEG;
a 360-pixel portrait poster (`wall-portrait-360.jpg`) fills the displays tile.
Clips are muted, loop, and load only when in view. Reduced motion shows the
posters.

`app-home`, `app-displays` and `app-settings` are real screenshots of the
LumaWall window with the sample loops imported, at 800 and 1324 pixels wide in
AVIF and WebP (transparent rounded corners) and JPEG. The hero puts the Home
screenshot over the cycling clips; the app section shows the other two.

Playback: each clip is loaded on demand with `<source>` elements. Phones and tiles drawn small get
`wall-N-960.mp4` first and fall back to the original file, so a missing copy
still plays. Chrome ignores `media` on video sources, so `js/videos.js` picks the order itself from the
viewport width, element width and devicePixelRatio. With Data Saver on, nothing autoplays and a tap on a gallery
card loads its clip. If the browser refuses autoplay (iOS Low Power Mode) the poster stays and the pause button
becomes "Play wallpapers". The hero fades to the next clip only once it can play through.

## Themes

The site follows `prefers-color-scheme`. The nav switch (System, Light, Dark) stores a Light or Dark choice in
localStorage (`lumawall-theme`). `js/theme.js` is a tiny classic script in `<head>` that sets `data-theme` on
`<html>` before first paint (the CSP forbids inline scripts). All colours are custom properties in `styles.css`;
the dark values are written twice, once for the media query and once for `[data-theme="dark"]`, so change both.

## Rules

- Static files only.
- No third-party runtime dependencies.
- No tracking or analytics.
- No third-party media (copyright).
