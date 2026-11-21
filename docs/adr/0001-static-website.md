# 0001: Static website on GitHub Pages

## Context

LumaWall needs a public site. It should load fast, cost nothing, and not
track visitors.

## Decision

Write the site as static HTML, CSS and vanilla JavaScript in `site/`.
Deploy it to GitHub Pages with a GitHub Actions workflow. Use no framework
and no build step.

## Consequences

- No dependencies to audit or update.
- Fast pages, free hosting on a public repo, no third-party requests.
- Without templates, contributors copy shared markup such as headers and
  footers by hand.
