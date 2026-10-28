# QuotaBar and provider icons

## QuotaBar app icon

The QuotaBar icon is original, code-drawn vector artwork: a usage dashboard with two remaining-quota meters and a fuel-style capacity gauge. It contains no provider branding or text, and it is covered by the project's MIT License.

`scripts/draw-app-icon.swift` is the editable source. It draws with native AppKit paths and produces vector PDFs plus transparent 1024px PNG previews. `scripts/build-icon.sh` regenerates that artwork and the app's standard 16-1024px macOS ICNS representations, then strips metadata from PNGs, embedded ICNS PNGs and vector PDFs. Normal builds use the committed files; run the regeneration script only after changing the drawing. The in-app header and fallback menu icon load the PDF; Finder uses the bundled ICNS.

## Provider marks

Provider symbols are unchanged vendor vector paths, rendered locally onto simple app-icon tiles. They identify the integrations and are not QuotaBar's own branding. They are neither screenshot crops nor approximate hand redraws:

- `ChatGPT-mark.svg`: the 20×20 ChatGPT symbol in the navigation at [chatgpt.com](https://chatgpt.com/), read from its rendered SVG on 23 October 2026. OpenAI owns this mark. See [OpenAI brand guidance](https://openai.com/brand/).
- `Claude-mark.svg`: the 125×125 Claude symbol path from the header wordmark at [claude.com](https://claude.com/), read from its rendered SVG on 23 October 2026. Anthropic owns this mark.

These marks, and the `Codex*`, `Claude*` and `ChatGPT*` files rendered from them, belong to their owners and are not covered by the MIT License. QuotaBar uses them only to identify the services it integrates with and is not affiliated with, endorsed by or sponsored by OpenAI or Anthropic.

The renderer supports the absolute SVG path commands used by these committed assets and fails on unsupported syntax. The menu bar uses separate `CodexMenu.pdf` and `ClaudeMenu.pdf` bare vector marks with transparent backgrounds, tinted to the menu text color for the current appearance. It never falls back to tiled application icons. The dashboard keeps the provider app-icon tiles. Installed application icons and bundled ICNS files remain dashboard fallbacks if its PDF cannot load.

## Documentation screenshots

App UI images live in [`docs/screenshots/`](../docs/screenshots/), with source and privacy notes in [the screenshot guide](../docs/SCREENSHOTS.md). The PNG previews in this folder are artwork previews, not captures of provider accounts.
