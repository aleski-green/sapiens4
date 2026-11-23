# Bundled typography

These fonts are served locally, included in native packages, and cached with the
remote app shell. No Google Fonts request is made at runtime.

- DM Sans variable (optical size and weight): google/fonts, `ofl/dmsans`.
- Zen Maru Gothic Light (300) and Medium (500): google/fonts, `ofl/zenmarugothic`.
- IBM Plex Mono Regular (400): google/fonts, `ofl/ibmplexmono`.

Source: https://github.com/google/fonts (downloaded November 23, 2026).
The original TTFs were losslessly encoded as WOFF2 with fontTools; the full glyph
sets are retained for custom faces and multilingual content. SIL Open Font
License notices are in `license/fonts/` and ship in the native package.
