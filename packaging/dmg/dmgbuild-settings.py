# dmgbuild settings for Lectern's DMG, run by scripts/release/build-dmg. dmgbuild executes this file
# with `defines` (from -D) in scope. It writes the window's .DS_Store itself and mounts its scratch
# image with -nobrowse, so building never opens a Finder window.
#
#   -D staging=<folder>      Lectern.app and the three text files
#   -D background=<png>      from make-background.swift; its @2x twin must sit next to it
#   -D icon=<icns>           the volume icon (the app's own AppIcon.icns)
#   -D layout=<json>         packaging/dmg/layout.json, shared with make-background.swift
import json
import os.path

with open(defines["layout"]) as fp:  # noqa: F821 (defines comes from dmgbuild)
    layout = json.load(fp)
staging = defines["staging"]  # noqa: F821

format = "UDZO"
filesystem = "HFS+"
icon = defines["icon"]  # noqa: F821
background = defines["background"]  # noqa: F821

files = [os.path.join(staging, layout["app"]["name"])]
files += [os.path.join(staging, item["name"]) for item in layout["files"]]
symlinks = {layout["applications"]["name"]: "/Applications"}
# No hide_extensions: it sets Finder info on Lectern.app, which then fails
# `codesign --verify --strict` ("Finder information, or similar detritus") on every copy.

icon_locations = {
    item["name"]: (item["x"], item["y"])
    for item in [layout["app"], layout["applications"]] + layout["files"]
}

window_rect = ((200, 120), (layout["window"]["width"], layout["window"]["height"]))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
icon_size = layout["iconSize"]
text_size = layout["textSize"]
label_pos = "bottom"
