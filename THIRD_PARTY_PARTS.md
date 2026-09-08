# Third-party Fritzing parts

Release packages built with this repository's release scripts include the
published Fritzing bin bundles listed below. The files are copied without
modification and remain separate from Fritzing's core parts database.

## Adafruit Fritzing Library

- Source: https://github.com/adafruit/Fritzing-Library
- Revision: `7d905c3e982de3712c3033da4596cc71ea32de1c`
- License: Creative Commons Attribution-ShareAlike 3.0 Unported
- Included files: the `.fzbz` bin bundles published at the repository root

Copyright and attribution notices are preserved in the packaged copy of the
upstream `README.md` and `LICENSE` files.

## SparkFun Fritzing Parts

- Source: https://github.com/sparkfun/Fritzing_Parts
- Revision: `71b17bbea66f92123f0a39dcf6f8c9ae566e31d1`
- License: hardware design files are Creative Commons Attribution-ShareAlike
  4.0 International; code is MIT licensed
- Included files: the `.fzbz` bin bundles published at the repository root

Copyright and attribution notices are preserved in the packaged copy of the
upstream `README.md` and `License.md` files.

## Using the packaged bins

Open a `.fzbz` file in Fritzing. To keep the bin in the Parts palette, choose
**Save Bin** from the palette menu. The vendor bins are not imported into
`parts.db`, because vendor and core libraries may contain overlapping parts or
module IDs.

On Windows and Linux, the `third-party-parts` folder is beside the packaged
Fritzing executable. On macOS, Control-click `Fritzing.app`, choose **Show
Package Contents**, then open `Contents/Resources/third-party-parts` for the
local package or `Contents/MacOS/third-party-parts` for the legacy release
script.

## Packaging requirements

The release scripts use `tools/package-third-party-parts.py` and require Python
3 plus a Git version that supports partial clone and sparse checkout. Packaging
stops if a pinned revision, expected filename, or SHA-256 digest does not match.

Adafruit and SparkFun do not endorse this distribution. The parts are provided
by their respective authors without a guarantee of correctness. Check a part's
footprint and pin mapping before manufacturing a PCB.
