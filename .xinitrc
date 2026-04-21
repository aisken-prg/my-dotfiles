xrdb ~/.config/.xresources-gruvbox
export GTK_THEME=Adwaita:dark
export GTK2_RC_FILES=/usr/share/themes/Adwaita-dark/gtk-2.0/gtkrc
export QT_STYLE_OVERRIDE=Adwaita-Dark
#xrdb -merge ~/.Xresources-wal-dwm

CURRENT_WALL="$HOME/Pictures/current_wallpaper.txt"

if [ -f "$CURRENT_WALL" ]; then
    WALL=$(cat "$CURRENT_WALL")
    [ -f "$WALL" ] && xwallpaper --zoom "$WALL"
fi
slstatus &
picom &
exec dwm
