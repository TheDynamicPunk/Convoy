# dmgbuild settings for make-dmg.sh, which passes the paths as defines.

files = [defines["app"]]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]
background = defines["background"]
format = "UDZO"

# A bare icon window: no toolbar, sidebar or bars.
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
show_icon_preview = False
arrange_by = None

# Finder's window height includes its title bar area: on macOS 26, 440
# shows the 352pt-tall background exactly, with no scroll bars.
window_rect = ((200, 120), (660, 440))

# Icon centres, on the row background.swift draws around (iconY).
icon_size = 128
text_size = 13
label_pos = "bottom"
icon_locations = {"Convoy.app": (170, 140), "Applications": (490, 140)}
hide_extension = ["Convoy.app"]
