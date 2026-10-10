# dmgbuild settings: app on the left, Applications shortcut on the right (the standard layout)
app = defines.get('app', 'WordCraft.app')
appname = 'WordCraft.app'
format = 'UDZO'
files = [app]
symlinks = {'Applications': '/Applications'}
background = 'dmg-background.tiff'
icon_size = 128
text_size = 13
window_rect = ((200, 200), (600, 380))
default_view = 'icon-view'
show_icon_preview = False
include_icon_view_settings = 'auto'
icon_locations = {appname: (150, 190), 'Applications': (450, 190)}
