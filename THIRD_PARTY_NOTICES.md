# Third-party software

Floating AI includes these libraries and fonts for offline Markdown and mathematical typesetting. Their license files are included in `Resources/MathRendering` and in the app's bundled MathRendering resources.

| Component | Version | License | Source |
| --- | --- | --- | --- |
| KaTeX, including fonts | 0.19.0 | MIT | https://github.com/KaTeX/KaTeX |
| Marked | 18.1.1 | MIT | https://github.com/markedjs/marked |
| DOMPurify | 3.4.17 | Apache-2.0 (dual licensed with MPL-2.0) | https://github.com/cure53/DOMPurify |

The files were obtained from the official npm packages, with each archive's SHA-512 integrity verified against its npm metadata. `Resources/MathRendering/vendor-manifest.json` records the exact package URLs and integrity values; `vendor-sha256.txt` records the bundled vendor files.

KaTeX's CSS is modified only to remove unused WOFF and TTF font fallbacks; the bundled WOFF2 fonts are unchanged. Other vendor JavaScript and license files are unmodified. The renderer uses these local assets and does not load a CDN.
