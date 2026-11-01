# APOD Wallpaper

A Dux Shell (DankMaterialShell 2.x) plugin that sets NASA's
[Astronomy Picture of the Day](https://apod.nasa.gov/apod/) as your wallpaper
and keeps it updated daily. Works on any compositor Dux Shell supports (tested on niri).

## What it does

- A background daemon checks APOD on login and every N hours (default 3).
- A new picture is downloaded only when the date changes, to `~/Pictures/APOD/apod-YYYY-MM-DD.jpg`,
  then applied through the shell's wallpaper manager, so matugen theming follows it.
- Once today's picture is applied it won't override a wallpaper you pick by hand until tomorrow.
- On video days it keeps your current wallpaper, or (optionally) uses a still image NASA publishes for the video. Images with "logo" in the URL are never used.
- It checks both the NASA API and the newest article on science.nasa.gov/apod/ and uses whichever is newer,
  so a lagging or broken API never leaves you on an old picture.
- Optional bar/dock widget: left click shows title, image and explanation; right click refreshes.

## Install

```bash
mkdir -p ~/.config/dms/plugins
cp -r ApodWallpaper ~/.config/dms/plugins/
```

Then Settings → Plugins → **Scan for Plugins** → enable **APOD Wallpaper**.
Wallpaper management must be on (Settings → Wallpaper); external tools like swww/swaybg won't be touched.

Requires Dux Shell 2.0 or newer. No extra packages: downloads use DMS's built-in `dms dl`.

### API key

`DEMO_KEY` works but is limited to a handful of requests per hour/day per IP.
Get a free key at <https://api.nasa.gov> and paste it into the plugin settings.

## IPC

```bash
dms ipc call apodWallpaper refresh   # fetch and apply now (re-applies even if already set today)
dms ipc call apodWallpaper info      # JSON of the current picture
dms ipc call apodWallpaper open      # open today's APOD page in your browser
```

niri keybind (`~/.config/niri/config.kdl`):

```kdl
binds {
    Mod+Shift+A { spawn "dms" "ipc" "call" "apodWallpaper" "refresh"; }
}
```

## Development

```bash
dms ipc call plugins reload apodWallpaper   # reload after edits
dms kill && dms run                          # see console logs ([apodWallpaper] ...)
```

Last applied picture is stored in `~/.local/state/dms/plugins/apodWallpaper_state.json`.
