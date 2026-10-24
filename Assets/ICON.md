# QuotaBar and provider icons

The current QuotaBar icon is original, code-drawn vector artwork: a usage dashboard with two remaining-quota meters and a fuel-style capacity gauge. The human selected this direction after rejecting the earlier abstract Q/ring icon, then requested a fuel gauge in place of the clock. It contains no provider branding or text.

`scripts/draw-app-icon.swift` is the editable source. It draws with native AppKit paths and produces vector PDFs plus transparent 1024px PNG previews. `scripts/build-icon.sh` generates the app's standard 16-1024px macOS ICNS representations. The in-app header and fallback menu icon load the PDF; Finder uses the bundled ICNS. No image-generation tool is used for the replacement artwork.

Provider symbols are unchanged vendor vector paths, rendered locally onto simple app-icon tiles. They identify integrations and are not QuotaBar's own branding. They are neither screenshot crops nor approximate hand redraws:

- `ChatGPT-mark.svg`: the 20×20 ChatGPT symbol in the navigation at https://chatgpt.com/, read from its rendered SVG on 23 October 2026. OpenAI owns this mark. See https://openai.com/brand/.
- `Claude-mark.svg`: the 125×125 Claude symbol path from the header wordmark at https://claude.com/, read from its rendered SVG on 23 October 2026. Anthropic owns this mark.

The renderer supports the absolute SVG path commands used by these committed assets and fails on unsupported syntax. The menu bar uses separate `CodexMenu.pdf` and `ClaudeMenu.pdf` bare vector marks with transparent backgrounds, tinted to the menu text color for the current appearance. It never falls back to tiled application icons. The dashboard keeps the provider app-icon tiles. Installed application icons and bundled ICNS files remain dashboard fallbacks if its PDF cannot load.
