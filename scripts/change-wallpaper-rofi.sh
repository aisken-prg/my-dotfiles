#!/usr/bin/env bash
set -e

# NOTE TO SELF
# - THIS IS HEAVILY VIBECODED.

# Wallpaper manager for X11 using rofi.
# - Local wallpapers: pick from $LOCAL_DIR and apply via xwallpaper.
# - Wallhaven: browse (Toplist/Views/Relevance+search), preview, download.
#
# Dependencies: rofi, jq, curl, xwallpaper
# Cache/state: $CACHE (thumbs, tmp downloads, last selected id, filter preset, query history)
#
# UI behavior:
# - Esc always backs out one level; Esc on the main menu exits.
# - Wallpaper lists keep "Next Page" at the top (-no-sort).
#
# --- CONFIG ---
CACHE="$HOME/.cache/rofi-wallhaven"
THUMBS="$CACHE/thumbs"
TMP_WALLS="$CACHE/tmp"
SELECTED_FILE="$CACHE/selected_wall.txt"
QUERY_HISTORY_FILE="$CACHE/query_history.txt"
LOCAL_DIR="$HOME/Pictures/Wallpapers"
CURRENT_FILE="$HOME/Pictures/current_wallpaper.txt"

mkdir -p "$THUMBS" "$TMP_WALLS" "$LOCAL_DIR"

API="https://wallhaven.cc/api/v1/search"
DEFAULT_RATIOS="16x9"
DEFAULT_ATLEAST="1920x1080"
FILTER_PRESET_FILE="$CACHE/filter_preset.txt"

# Filters applied to Wallhaven API calls. Empty means "no filter".
# These are set from the persistent preset (see load_filter_preset).
FILTER_RATIOS=""
FILTER_ATLEAST=""

# --- FUNCTIONS ---

# URL-encode user input for the API query string.
uri_encode() {
    # Uses jq's built-in @uri encoder to properly escape spaces and symbols.
    # Example: "no man sky" -> "no%20man%20sky"
    jq -nr --arg v "$1" '$v|@uri'
}

# Build the Wallhaven API URL with the currently active filters.
# Note: topRange only applies to sorting=toplist.
build_wallhaven_url() {
    local query sorting top page q url
    # Parameters:
    # - query: search string (can be empty for toplist/views browsing)
    # - sorting: relevance|views|toplist|...
    # - top: 1M|6M|1y (only used for toplist)
    # - page: 1-based page number
    query="${1:-}"
    sorting="${2:-relevance}"
    top="${3-}"
    page="${4:-1}"

    # Always URL-encode the query before putting it into the URL.
    q="$(uri_encode "$query")"
    url="$API?q=$q&sorting=$sorting&page=$page"

    # Wallhaven API only accepts topRange for toplist sorting.
    if [[ "$sorting" == "toplist" && -n "$top" ]]; then
        url="$url&topRange=$top"
    fi
    # Ratios filter (e.g. 16x9) helps avoid portrait/mobile wallpapers.
    if [[ -n "$FILTER_RATIOS" ]]; then
        url="$url&ratios=$FILTER_RATIOS"
    fi
    # Atleast filter (e.g. 1920x1080) enforces a minimum resolution.
    if [[ -n "$FILTER_ATLEAST" ]]; then
        url="$url&atleast=$FILTER_ATLEAST"
    fi

    # Print only the URL (no trailing newline) so callers can use it in command substitution.
    printf '%s' "$url"
}

# Map a human preset name to concrete Wallhaven API filters.
apply_filter_preset() {
    # Side effects: sets FILTER_RATIOS / FILTER_ATLEAST globals that affect all Wallhaven fetches.
    case "${1:-}" in
        desktop-16x9)
            FILTER_RATIOS="$DEFAULT_RATIOS"
            FILTER_ATLEAST=""
            ;;
        screen-fit)
            FILTER_RATIOS="$DEFAULT_RATIOS"
            FILTER_ATLEAST="$DEFAULT_ATLEAST"
            ;;
        any)
            FILTER_RATIOS=""
            FILTER_ATLEAST=""
            ;;
        *)
            # Default: avoid mobile wallpapers without being overly strict.
            FILTER_RATIOS="$DEFAULT_RATIOS"
            FILTER_ATLEAST=""
            ;;
    esac
}

# Human-readable filters label for menu prompts.
filters_label() {
    if [[ -n "$FILTER_RATIOS" && -n "$FILTER_ATLEAST" ]]; then
        printf '%s @ >=%s' "$FILTER_RATIOS" "$FILTER_ATLEAST"
        return
    fi
    if [[ -n "$FILTER_RATIOS" ]]; then
        printf '%s' "$FILTER_RATIOS"
        return
    fi
    printf 'any'
}

# Load the persisted preset from disk and apply it to FILTER_*.
load_filter_preset() {
    local preset
    preset=""
    # The preset file is 1 line containing: desktop-16x9|screen-fit|any
    if [[ -f "$FILTER_PRESET_FILE" ]]; then
        preset="$(head -n 1 "$FILTER_PRESET_FILE" 2>/dev/null || true)"
    fi
    # If file is missing/empty/unknown, apply_filter_preset falls back to default behavior.
    apply_filter_preset "$preset"
}

# UI to choose the global Wallhaven filter preset (persistent).
set_wallhaven_filters() {
    local choice preset
    # -dmenu reads options from stdin and returns the selected line on stdout.
    # NOTE: we append `|| true` everywhere rofi is used, because `set -e` would
    # otherwise exit the entire script when you press Esc (rofi returns non-zero).
    choice="$(
        printf '%s\n' \
            "Desktop (16:9 only)" \
            "Screen-fit (16:9 + >=1080p)" \
            "Web-like (any size/ratio)" \
            | rofi -dmenu -i -p "Wallhaven filters" || true
    )"
    # Esc/cancel returns empty -> just go back to the previous menu.
    [ -z "$choice" ] && return

    preset=""
    case "$choice" in
        "Desktop (16:9 only)")
            preset="desktop-16x9"
            ;;
        "Screen-fit (16:9 + >=1080p)")
            preset="screen-fit"
            ;;
        "Web-like (any size/ratio)")
            preset="any"
            ;;
        *)
            return
            ;;
    esac

    # Apply immediately and persist for the next run.
    apply_filter_preset "$preset"
    printf '%s\n' "$preset" > "$FILTER_PRESET_FILE" 2>/dev/null || true
}

# Show an error toast via rofi (non-fatal).
rofi_error() {
    # Non-blocking notification. If rofi isn't available for some reason, ignore failures.
    rofi -e "$1" || true
}

# Prompt the user for a search query (with suggestions).
# Uses -no-config so custom input is accepted even if the user's rofi config
# has dmenu-only-match / no-custom set.
prompt_wallhaven_query() {
    local history_file
    history_file="$QUERY_HISTORY_FILE"
    # Ensure the history file exists so `tac` works even on first run.
    touch "$history_file"

    # Show recent queries as suggestions, but still allow typing a new one.
    # Keep it simple + portable: "most recent unique" via tac+awk.
    local suggestions
    # `tac` reverses history so the most recent entries appear first.
    # `awk` filters out empty lines and keeps first occurrence (unique suggestions).
    suggestions="$(tac "$history_file" 2>/dev/null | awk 'NF && !seen[$0]++ {print} NR>=50 {exit}')"
    # -no-config is important: user rofi configs often set -only-match/-no-custom,
    # which would prevent typing a new query.
    printf '%s\n' "$suggestions" | rofi -no-config -dmenu -i -p "Wallhaven search" || true
}

# --- WALLHAVEN BROWSER (shared by preview + download) ---

wallhaven_fetch_json() {
    local query="${1:-}"
    local page="${2:-1}"
    local sorting="${3:-relevance}"
    local top="${4-}"
    local url

    # Build the request URL with the active sorting + filters.
    url="$(build_wallhaven_url "$query" "$sorting" "$top" "$page")"
    # -sL: silent + follow redirects
    # --fail: return non-zero on HTTP errors (handled by caller)
    curl -sL --fail "$url" || true
}

wallhaven_validate_json_or_error() {
    local json="$1"
    # Verify that the response looks like what we expect:
    # - `.data` exists and is an array
    echo "$json" | jq -e '.data and (.data|type=="array")' >/dev/null 2>&1 || {
        rofi_error "Wallhaven request failed (check network / API)."
        return 1
    }
}

wallhaven_download_thumb() {
    local id="$1"
    local url="$2"
    local file="$THUMBS/$id.jpg"
    # Thumbnails are cached on disk by wallpaper id, so paging doesn't re-download.
    [ ! -f "$file" ] && curl -sL "$url" -o "$file"
    echo "$file"
}

wallhaven_rofi_select() {
    # Args: json query page prompt
    local json="$1"
    local query="$2"
    local page="$3"
    local prompt="$4"

    {
        # Put paging controls at the top of the list.
        echo "󰁔 Next Page"
        [ "$page" -gt 1 ] && echo "󰁍 Previous Page"

        # Each API entry becomes a rofi entry where:
        # - The visible text is the wallpaper id (e.g. "abc123")
        # - rofi's icon is the cached thumbnail
        # - "meta" stores the full image URL (useful for themes/debugging)
        echo "$json" | jq -r '.data[] | "\(.id)|\(.thumbs.small)|\(.path)"' | while IFS="|" read -r id thumb full; do
            icon="$(wallhaven_download_thumb "$id" "$thumb")"
            # rofi dmenu "rich" row format:
            # - `\0key\x1fvalue` pairs after the displayed text
            # - icon key uses a local file path
            echo -en "$id\0icon\x1f$icon\x1fmeta\x1f$full\n"
        done
        # -no-sort keeps our "Next Page" entry at the top.
    } | rofi -dmenu -theme ~/.config/rofi/Arc-Dark-wall.rasi -show-icons -i -no-sort -p "$prompt [$query p$page]" || true
}

wallhaven_full_url_for_id() {
    local json="$1"
    local id="$2"
    # Resolve the chosen ID back to the full wallpaper URL from the same JSON payload.
    echo "$json" | jq -r ".data[] | select(.id==\"$id\") | .path"
}

wallhaven_browse() {
    # Args: mode query sorting top
    local mode="$1" # preview|download
    local query="${2:-}"
    local sorting="${3:-relevance}"
    local top="${4-}"
    local page=1
    local prompt

    # Prompt text shown in rofi.
    prompt="Wallhaven"
    [[ "$mode" == "download" ]] && prompt="Download Wallpaper"

    while true; do
        local json selection wall file

        # 1) Fetch current page.
        json="$(wallhaven_fetch_json "$query" "$page" "$sorting" "$top")"
        wallhaven_validate_json_or_error "$json" || return

        # 2) Render rofi list and read selection.
        selection="$(wallhaven_rofi_select "$json" "$query" "$page" "$prompt")"
        # Esc/cancel -> back to sorting menu/main menu depending on call site.
        [ -z "$selection" ] && return

        # 3) Pagination is handled by special "rows" at the top.
        case "$selection" in
            "󰁔 Next Page")
                page=$((page + 1))
                continue
                ;;
            "󰁍 Previous Page")
                page=$((page - 1))
                continue
                ;;
        esac

        # 4) For a real wallpaper id, look up the full URL.
        wall="$(wallhaven_full_url_for_id "$json" "$selection")"
        [ -z "$wall" ] && return

        if [[ "$mode" == "preview" ]]; then
            # Preview:
            # - download to TMP_WALLS (cache)
            # - set it immediately via xwallpaper
            # - remember the id for "Download Selected Wallpaper"
            file="$TMP_WALLS/wallhaven-$selection.jpg"
            [ ! -f "$file" ] && curl -fL "$wall" -o "$file"
            echo "$selection" > "$SELECTED_FILE"
            xwallpaper --zoom "$file"
        else
            # Download:
            # - download to LOCAL_DIR (persistent)
            file="$LOCAL_DIR/wallhaven-$selection.jpg"
            [ ! -f "$file" ] && curl -fL "$wall" -o "$file"
        fi

        # After a successful selection, return to the sorting menu (one level up).
        return
    done
}

# Sorting menu for Wallhaven. Runs in a loop so Esc/backing out returns to the
# main menu instead of terminating the script (see "Esc behavior" comment at top).
wallhaven_menu() {
    local mode="$1"
    local query="${2:-}"
    local choice sorting top

    while true; do
        # This is the "one level up" menu from the wallpaper list.
        # Esc here returns to the main menu.
        choice="$(
            printf '%s\n' \
                "Relevance/Search" \
                "Toplist / 1 Month" \
                "Toplist / 6 Months" \
                "Toplist / 1 Year" \
                "Views" \
                | rofi -dmenu -i -p "Sorting ($(filters_label))" || true
        )"
        [ -z "$choice" ] && return

        case "$choice" in
            "Relevance/Search")
                sorting="relevance"
                top=""
                # Ask for a query. Esc here returns to this sorting menu.
                query="$(prompt_wallhaven_query)"
                [ -z "$query" ] && continue
                # Append query to history (best effort).
                printf '%s\n' "$query" >> "$QUERY_HISTORY_FILE" 2>/dev/null || true
                ;;
            "Toplist / 1 Month")
                sorting="toplist"
                top="1M"
                query=""
                ;;
            "Toplist / 6 Months")
                sorting="toplist"
                top="6M"
                query=""
                ;;
            "Toplist / 1 Year")
                sorting="toplist"
                top="1y"
                query=""
                ;;
            "Views")
                sorting="views"
                top=""
                query=""
                ;;
            *)
                continue
                ;;
        esac

        # Enter the wallpaper browser menu (one level down).
        wallhaven_browse "$mode" "$query" "$sorting" "$top"
    done
}

# Change wallpaper from local directory
change_wallpaper() {
    local menu file selected
    menu=""
    # Build a rofi list where each line:
    # - shows the full path
    # - uses the file itself as the icon (works for most image formats)
    #
    # Note: for very large wallpaper folders, building this string can be slow.
    while IFS= read -r file; do
        # Add each file as a line with its icon
        menu+="$file\0icon\x1f$file\n"
    done < <(find "$LOCAL_DIR" -type f \( -iname "*.jpg" -o -iname "*.png" \) | sort)

    # Show menu with icons
    selected="$(echo -e "$menu" | rofi -dmenu -theme ~/.config/rofi/Arc-Dark-wall.rasi -i -show-icons -p "Change Wallpaper" || true)"
    # If user pressed Esc, selected is empty -> return to main menu.
    if [ -n "$selected" ]; then
        # Apply wallpaper and remember the path for external scripts.
        xwallpaper --zoom "$selected"
        echo "$selected" > "$CURRENT_FILE"
        # Per request: selecting a local wallpaper should quit the script.
        exit 0
    fi
}

# Download last selected wallpaper
# Copies the last previewed wallpaper from TMP_WALLS into LOCAL_DIR.
download_selected() {
    local selection src
    # Download Selected Wallpaper = copy the last previewed wallhaven file into LOCAL_DIR.
    # This only works for wallpapers that were previewed (so the tmp file exists).
    [ ! -f "$SELECTED_FILE" ] && { echo "No wallpaper selected"; return; }
    selection=$(cat "$SELECTED_FILE")
    src="$TMP_WALLS/wallhaven-$selection.jpg"
    [ ! -f "$src" ] && { echo "Selected wallpaper not found"; return; }
    cp "$src" "$LOCAL_DIR/"
    echo "Downloaded: wallhaven-$selection.jpg"
}

# --- MAIN MENU ---
# Returns the menu selection. Empty selection means "Esc" / cancel.
main_menu() {
    local selection
    # Main menu: returns the selected string. Empty means Esc/cancel.
    selection="$(
        printf '%s\n' \
            "Change Wallpaper" \
            "Wallhaven Filters" \
            "Preview Wallpaper" \
            "Download Wallpaper" \
            "Download Selected Wallpaper" \
            | rofi -dmenu -i -p "Wallpaper Manager" || true
    )"
    printf '%s' "$selection"
}

# Load filter preset once at startup (user can change it via "Wallhaven Filters").
load_filter_preset

# Main UI loop:
# - Always return to the main menu after finishing an action.
# - Esc on the main menu exits the script.
while true; do
    # If rofi is closed with Esc, ACTION becomes empty and we exit.
    ACTION="$(main_menu)" || true
    [ -z "$ACTION" ] && exit 0

    case "$ACTION" in
        "Wallhaven Filters")
            # Change/persist Wallhaven filter preset.
            set_wallhaven_filters
            ;;
        "Change Wallpaper")
            # Pick a local wallpaper and exit after applying.
            change_wallpaper
            ;;
        "Preview Wallpaper")
            # Browse Wallhaven and apply the chosen wallpaper (doesn't save to LOCAL_DIR).
            wallhaven_menu preview
            ;;
        "Download Wallpaper")
            # Browse Wallhaven and download the chosen wallpaper into LOCAL_DIR.
            wallhaven_menu download
            ;;
        "Download Selected Wallpaper")
            # Copy the last previewed wallpaper into LOCAL_DIR.
            download_selected
            ;;
    esac
done
