# dmgbuild settings for MeetingNotes.dmg (see packaging/make-dmg.sh), run as:
#   dmgbuild -s packaging/dmg-settings.py -D app=<Meeting Notes.app> -D background=<bg.png> "Meeting Notes" MeetingNotes.dmg
import os.path

app = defines["app"]  # noqa: F821 (provided by dmgbuild)
background = defines["background"]  # noqa: F821
format = "UDZO"
size = defines.get("size")  # noqa: F821 (set by make-dmg.sh; dmgbuild's own estimate is too small for big apps)
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon_locations = {os.path.basename(app): (170, 190), "Applications": (470, 190)}
window_rect = ((200, 120), (640, 420))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
