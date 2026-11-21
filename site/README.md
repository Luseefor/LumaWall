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

`.github/workflows/pages.yml` deploys `site/` to GitHub Pages on pushes to
`main` that touch `site/**` or the workflow. It skips until `site/index.html`
exists. You can also run it by hand, from `main` only.

The repo owner must set Settings → Pages → Source to **GitHub Actions** once.

## Rules

- Static files only.
- No third-party runtime dependencies.
- No tracking or analytics.
- No third-party media (copyright).
