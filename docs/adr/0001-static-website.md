# 0001: Static website on Vercel

## Context

LumaWall needs a public site. It should load fast, cost nothing, and not
track visitors.

## Decision

Write the site as static HTML, CSS and vanilla JavaScript in `site/`.
Host it on Vercel as a static project rooted at `site/`, with security
headers in `site/vercel.json`. Use no framework and no build step.

The first plan was GitHub Pages; the owner chose Vercel instead.

## Consequences

- No dependencies to audit or update.
- Fast pages, free static hosting, no third-party requests from the page.
- Vercel sets the response headers, which GitHub Pages can't.
- Without templates, contributors copy shared markup such as headers and
  footers by hand.
