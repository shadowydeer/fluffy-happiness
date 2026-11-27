#!/usr/bin/env bash
# Installs the pinned Godot editor and a software-rendering stack for headless sandboxes.
set -euo pipefail

GODOT_VERSION="4.3-stable"
GODOT_ZIP="Godot_v${GODOT_VERSION}_linux.x86_64.zip"
GODOT_URL="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}"
GODOT_BIN="/usr/local/bin/godot"

if ! "$GODOT_BIN" --version 2>/dev/null | grep -q "^4\.3\.stable"; then
	tmp="$(mktemp -d)"
	trap 'rm -rf "$tmp"' EXIT
	curl -fsSL -o "$tmp/$GODOT_ZIP" "$GODOT_URL/$GODOT_ZIP"
	curl -fsSL -o "$tmp/SHA512-SUMS.txt" "$GODOT_URL/SHA512-SUMS.txt"
	(cd "$tmp" && grep " $GODOT_ZIP\$" SHA512-SUMS.txt | sha512sum -c -)
	unzip -q -o "$tmp/$GODOT_ZIP" -d "$tmp"
	install -m 0755 "$tmp/Godot_v${GODOT_VERSION}_linux.x86_64" "$GODOT_BIN"
fi

# Xvfb + lavapipe let Forward+ render without a GPU or display.
if ! command -v xvfb-run >/dev/null || ! ls /usr/share/vulkan/icd.d/lvp_icd*.json >/dev/null 2>&1; then
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get install -y -qq --no-install-recommends xvfb xauth mesa-vulkan-drivers
fi

# Build the import cache so scripts and scenes can load.
cd "$(dirname "$0")/.."
"$GODOT_BIN" --headless --import >/dev/null 2>&1 || true
"$GODOT_BIN" --version
