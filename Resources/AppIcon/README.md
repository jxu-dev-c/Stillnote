# Stillnote app icon

The blue glass tile combines an ivory notebook page with an audio waveform and
note lines. `AppIcon.png` is the 1024 × 1024 RGBA master, with transparent margins.
`../AppIcon.icns` contains the standard macOS sizes from 16 px through 1024 px.

Regenerate the committed ICNS on macOS after changing the master:

```sh
./scripts/build-icon.sh
./scripts/build-app.sh debug
```

The app build copies the ICNS into `Contents/Resources`; `CFBundleIconFile` in
`Resources/Info.plist` selects it for Finder, the Dock, and the standard About panel.

Artwork generated using the built-in image generation tool. Final prompt:

> Use case: logo-brand. Asset type: production macOS application icon for Stillnote, a private native meeting recorder and notebook. Create ONE polished icon, straight-on orthographic view on a truly transparent background, 1024x1024 square canvas. A macOS rounded-square squircle tile occupying about 82% of canvas width, centered with even transparent margins. Tile is rich desaturated ocean blue with subtle luminous cyan upper-left light, deep blue lower-right, softly beveled glass-like edge, restrained dimensionality and gentle shadow. Center a single substantial ivory-white notebook page with gently rounded corners and tiny folded upper right corner; on its face a bold simple blue audio waveform of five rounded vertical bars in the upper half, and two thick short blue horizontal note lines below. The page is large, upright and perfectly front-facing, with soft depth. Elegant, calm, premium Mac productivity app aesthetic. Strong silhouette, generous breathing room, clean shapes legible at 32px. No letters, words, numbers, pencil, microphone, badges, extra objects, thin details, busy texture, mockup, grid, or surrounding scene. Actual alpha transparency outside the tile; never a checkerboard painted into the image.
