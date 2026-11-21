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
Policy: no inline scripts or styles, no third-party requests) and caching (scripts and styles revalidate on every load, so a deploy never pairs new HTML with stale JavaScript).
`site/.vercelignore` keeps the tests and this README out of the deploy.

Deploy from the repo root:

```sh
npx vercel@latest deploy site --prod
```

## Rules

- Static files only.
- No third-party runtime dependencies.
- No tracking or analytics.
- No third-party media (copyright).
