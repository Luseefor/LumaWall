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
Helvetica Neue font. The waterfall comes from `site/media/wall-3.jpg`. Its source
and license are in [the media credits](media/CREDITS.md). The indexed palette
keeps the 1200 × 630 card under 250 KB.

```sh
magick -size 1200x630 xc:'#f5f5f7' \
  \( site/media/wall-3.jpg -resize '600x506^' -gravity center -extent 600x506 \
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

`site/media/` holds the wallpaper clips: `wall-1.mp4` to `wall-6.mp4` with posters `wall-1.jpg` to
`wall-6.jpg` (1600x900), and `wall-portrait.mp4` and `.jpg` (720x1280). Clips are muted, loop and load
only when in view. Reduced motion shows the posters.

## Rules

- Static files only.
- No third-party runtime dependencies.
- No tracking or analytics.
- No third-party media (copyright).
