# Barline website

A small static HTML/CSS site for Cloudflare Pages. No framework, third-party
fonts, cookies, database, or app backend. A narrowly allowlisted Plausible
script provides aggregate, privacy-friendly website analytics; the native app
contains no analytics.
Optional contributions open Stripe-hosted checkout; the site contains no
payment SDK, secret keys, card fields, webhook, or entitlement logic.

## Local development

```sh
cd site
npm test
npm run build
npm run preview
```

No dependency installation is needed. Build output is ignored `site/dist/`.
Preview binds to `127.0.0.1:4178`. The icon comes from the native app asset.

## Deployment and availability

The configured Cloudflare Pages project is `barline-site`, with `site` as the
project root and `dist` as output. It uses Direct Upload. Deployment ownership
must be chosen deliberately; do not add another GitHub workflow as a shortcut.

The `staging` branch is a Preview environment. Its pages are marked `noindex`
and show pending app-release availability. The contribution link accepts real
payments even from preview, and the visible copy says so. `noindex` discourages
indexing; it is not access control.

`usebarline.com` is the canonical production domain. DNS/TLS, redirects,
deployed content, and app-download destinations must be revalidated for each
release deployment.

Production builds require an explicit operator-reviewed JSON configuration:

```sh
node scripts/build.mjs --production /absolute/approved-release.json
```

It must contain `version`, `canonicalOrigin`, `downloadURL`, `sourceURL`,
`checksumsURL`, `releaseURL`, and `contributionURL`. Destinations must be the
canonical domain, approved hosted Stripe link, and exact version-specific
Mabry-Ventures/mv-barline GitHub release assets emitted by `script/release.sh`.
No keys, tokens, account state, latest-release redirect, or alternate repository
is accepted. The launch-ready source must contain anchors to those destinations, use
correct per-page canonical URLs, and remove preview availability/indexing blocks.
The launch source is production-ready, but the gate still requires the exact
operator-reviewed configuration before it will write production output.

The configuration is operator input, **not** proof of release qualification or
asset availability. Validate the published artifacts, hashes, matching source,
required local/physical gates and launch approval separately before deployment.
Build and deployment remain separate operations. Preview remains the default.
Production markup is intentionally constrained: no comments or templates,
quoted href attributes, and explicitly allowlisted external destinations.
This is a source guard, not a general HTML parser or proof of visual/AX visibility.
Rendered desktop/mobile/keyboard QA remains required. Source tests assert the
approved production copy, canonical URLs, indexing policy, and release links.

## Public launch checklist

- Finish app qualification and provide exact signed binary, corresponding
  source, checksums, license notices, and version-specific release notes.
- Validate approved download and support destinations; no placeholder buttons.
- Confirm production domain ownership, DNS/TLS, HTTPS redirects, and canonical URL.
- Update preview-only copy and indexing controls only for the approved launch.
- Verify deployed response bodies, CSP/security headers, and a genuine 404.
- Repeat desktop/mobile, keyboard, reduced-motion, and contrast checks.
- Confirm the private security/conduct reporting channels before linking them.

See [QA](QA.md) and [support delivery](../docs/SUPPORT_DELIVERY.md). Keep provider
identifiers, payment receipts, private workspace links, and detailed operator
logs in ignored local evidence rather than public documentation.

## Design

Use white surfaces, graphite text, restrained cobalt actions, native system
fonts, open columns, and thin rules. Avoid commercial pricing tiers, donation
nags, animated backgrounds, and invented screenshots or performance claims.

The tagline is **Your menu bar, organized. Your Mac, uninterrupted.** The menu
illustration is a labeled demonstration, not a screenshot or live OS control.
Preserve the About page's Ice attribution, source/provenance links, GPL notices,
and independent-project language.
