# eGlu symbol

The brand symbol: a globe that is also an "e", with a cursor in the e's opening and motion crescents behind it. The app icon, `Shared/eGlu.icon`, is drawn from it: the cursor is `eglu-icon-cursor.svg`, in Liquid Glass; the globe is seen through fluted glass, a picture for light and one for dark (`glass-light.png`, `glass-dark.png`) that `fluted-glass/fluted.py` draws, where the glass makes the crescents. The icon before it is `App/Globe.icon`.

| File | Use |
| --- | --- |
| `eglu-symbol.svg` | The symbol, black, for light backgrounds |
| `eglu-symbol-white.svg` | The same, white, for dark backgrounds |
| `eglu-symbol-compact.svg` | Without the motion crescents, for 32 px and smaller (favicons, small UI) |
| `eglu-symbol-compact-white.svg` | The same, white |
| `eglu-icon.svg`, `eglu-icon-white.svg` | The symbol in the sketch's 800-point frame, the e's bowl centred top to bottom |
| `eglu-icon-e.svg`, `eglu-icon-cursor.svg` | The letter (with its crescents) and the cursor apart, in that frame, white; the cursor is the app icon's layer |
| `fluted-glass/` | The app icon's globe behind fluted glass: `fluted.py` and what it draws from (below) |
| `*-preview-light.png`, `*-preview-dark.png` | Each at 640, 128, 64, 32 and 16 px |
| `symbol.swift` | Draws all of the above |
| `mac-icons.swift` | Draws the Mac's pictures of the app icons, light and dark, from the Icon Composer files (`Mac/Assets.xcassets/AppIcons`, for Settings › General › App Icon and the Dock); run it after changing an icon |

Each SVG is one filled path on a square artboard. The `eglu-symbol` ones are centred on the symbol's bounds; the `eglu-icon` ones keep the sketch's frame, so the layers line up.

## How it is drawn

Redrawn from the sketch in the Figma file (node 31:8, "globe 1"), with true curves in place of the sketch's traced outlines:

- The bowl is two ellipses, the inner one offset to the left: thick on the right, a hairline on the left, as a serif "e" is.
- The meridian is an even ring centred in the bowl's counter. The equator is the e's bar.
- The e's opening is cut out, not covered.
- The cursor is the classic arrow, tilted 6.8° as in the sketch, with rounded corners and a clear gap around it: the right wing's underside level, the left one at about 45°, both notches cut in as deep and the tail's sides parallel. Its tip is the sketch's, (532, 427), and it is about as tall (311).
- The motion crescents are built like the bowl, from offset ellipses, each thinner, further out and shorter than the one inside it.

To try a different measure, set it when running `symbol.swift` (each is read with `v("NAME", default)` in the file, for example `LEFT=20`). From the repository's folder:

```bash
swiftc -O Marketing/Brand/symbol.swift -o /tmp/symbol && /tmp/symbol Marketing/Brand
```

```bash
COUNT=0 NAME=eglu-symbol-compact /tmp/symbol Marketing/Brand
```

```bash
FRAME=1 NAME=eglu-icon /tmp/symbol Marketing/Brand
```

After changing the cursor, copy `eglu-icon-cursor.svg` over `Shared/eGlu.icon/Assets/cursor.svg`, then draw the icon's black fill again. The fill is the cursor drawn smaller by the white border's width (`--border`, 12 by default), lying over the white cursor in light and dark:

```bash
python3 Marketing/Brand/cursor-inset.py
```

It writes `Shared/eGlu.icon/Assets/cursor-fill.svg`.

## The fluted glass

`fluted-glass/fluted.py` lays vertical fluted glass over the globe, as a photograph of reeded glass would show it: each flute a shallow rod that bends what is behind it, strongest on the left, where the rim breaks into the crescents, and fading to nearly clear by the cursor. The globe is a little out of focus, more so on the left. Behind it, light mode is white with the dark globe's blues blurred behind the globe; dark mode is near-black, lifted towards a milky white at the corners. Every measure is a named constant at the top of the file, and each can be set when running it (`python3 fluted.py --help`).

What it draws from, in the same folder: `globe-layer-Default.png` and `globe-layer-Dark.png`, the globe without its crescents as Icon Composer drew it, apart from its ground (drawn over black and over white, the difference giving its transparency); `squircle-mask.png`, the icon's outline; `cursor-Default.png` and `cursor-Dark.png`, the cursor alone, for the previews. It needs NumPy, SciPy and Pillow. To draw the app icon's two pictures, from the repository's folder:

```bash
python3 Marketing/Brand/fluted-glass/fluted.py --plates Shared/eGlu.icon/Assets
```

`--all` draws the previews instead (the whole icon with its cursor, light and dark, and at 180 and 60 px) into the folder. Then redraw the icon's pictures, as for any icon (`mac-icons.swift`, and the Settings previews).
