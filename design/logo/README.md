# Lectern logo and app icon

- **`lectern-logo.webp`:** the logo as supplied by the maintainer on 2026-10-30. It's a red rounded square with a folded white "L", on a transparent background, 1254 × 1254 px.
- **`make-icon-art.py`:** turns the logo into `App/AppIcon.icon/Assets/lectern.png`, a full-bleed 1024 × 1024 square.
- **`App/AppIcon.icon`:** the app icon, as an Icon Composer document.
  - It has one image layer with Liquid Glass off, so the artwork appears as drawn.
  - macOS applies the rounded shape and the margins, and derives the dark, tinted and clear appearances.
  - `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` in `project.yml` makes `actool` compile it into `Assets.car` and `AppIcon.icns`.

To check every appearance without opening Icon Composer:

```sh
ictool=/Applications/Xcode.app/Contents/Applications/Icon\ Composer.app/Contents/Executables/ictool
"$ictool" App/AppIcon.icon --export-image --output-file icon.png --platform macOS \
  --rendition Default --width 512 --height 512 --scale 1
```

The other renditions are `Dark`, `TintedLight`, `TintedDark`, `ClearLight` and `ClearDark`.

**Licence:** the logo and app icon are kept out of the GPL, decided by the maintainer on 2026-10-30. They may be redistributed unchanged with Lectern and used to refer to it, but forks must use their own. The terms are in [`LICENSE.md`](LICENSE.md).

**Higher resolution:** the source is about 1,030 px across inside its rounded square, so 1024 px is the most the icon can honestly use. A vector version, or a 2048 px or larger PNG, would sharpen it on Retina screens at the largest sizes.
