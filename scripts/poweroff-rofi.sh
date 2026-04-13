#!/usr/bin/env bash

# Options
options="⏻  Shutdown\n↺  Reboot\n⏾  Sleep\n  Btop"

# Launch rofi and capture selection
# -layer overlay keeps rofi on top of all windows (requires rofi with layer support / compositor)
chosen=$(echo -e "$options" | rofi \
    -dmenu \
    -i \
    -p "  System" \
    -lines 4 \
    -layer overlay \
    -theme-str 'window { location: center; anchor: center; }' \
    -theme-str 'window { location: center; anchor: center; width: 200px; }' \
    -theme-str 'listview { lines: 4; }')

# Act on selection
case "$chosen" in
    "  Shutdown")
        systemctl poweroff
        ;;
    "↺  Reboot")
        systemctl reboot
        ;;
    "⏾  Sleep")
        systemctl suspend
        ;;
    "  Btop")
        # Respect $TERMINAL env var, then fall back to x-terminal-emulator, then xterm
        term="${TERMINAL:-$(command -v x-terminal-emulator 2>/dev/null || echo st)}"
        $term -e btop &
        ;;
    *)
        # No selection / Escape pressed — do nothing
        ;;
esac
