#!/bin/sh
# Applies Betterfox and installs uBlock Origin, LibRedirect and Dark Reader
# Usage: setup-firefox.sh [profile_dir] [user-overrides.js]

browserdir="${XDG_CONFIG_HOME:-$HOME/.config}/mozilla/firefox"
profilesini="$browserdir/profiles.ini"

# Launch headlessly to ensure a profile exists, then kill it
firefox --headless >/dev/null 2>&1 &
sleep 1
pkill firefox

# Resolve profile and overrides paths
pdir="$1"
profile="$(sed -n "/Default=.*.default-release/ s/.*=//p" "$profilesini")"
[ -z "$1" ] && pdir="$browserdir/$profile"
overrides="$2"
[ -z "$2" ] && overrides="$HOME/.config/firefox/user-overrides.js"

# Download Betterfox and merge with overrides
curl "https://raw.githubusercontent.com/yokoffing/Betterfox/main/user.js" > "$pdir/betterfox.js"
cat "$pdir/betterfox.js" "$overrides" > "$pdir/user.js"

# Install extensions
addonlist="ublock-origin libredirect darkreader"
addontmp="$(mktemp -d)"
trap "rm -fr $addontmp" HUP INT QUIT TERM PWR EXIT
IFS=' '
mkdir -p "$pdir/extensions/"
for addon in $addonlist; do
	echo "Downloading $addon"
	addonurl="$(curl --connect-timeout 5 "https://addons.mozilla.org/en-US/firefox/addon/${addon}/" |
		grep -o 'https://addons.mozilla.org/firefox/downloads/file/[^"]*')"
	file="${addonurl##*/}"
	curl -LOs "$addonurl" > "$addontmp/$file"
	# Some extensions (e.g. LibRedirect) nest their ID under browser_specific_settings.gecko
	id="$(unzip -p "$file" manifest.json | grep -o '"id":"[^"]*"' | tail -1)"
	id="${id%\"*}"
	id="${id##*\"}"
	mv "$file" "$pdir/extensions/$id.xpi"
done
