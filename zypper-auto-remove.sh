#!/bin/bash
# Auto-remove unneeded packages on openSUSE (zypper equivalent of apt autoremove)

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (or via sudo)." >&2
    exit 1
fi

# Collect unneeded packages, trimming whitespace around the name field
mapfile -t pkgs < <(
    zypper packages --unneeded \
    | grep "^i" \
    | cut -d"|" -f3 \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
)

if [[ ${#pkgs[@]} -eq 0 ]]; then
    echo "No unneeded packages found. Nothing to do."
    exit 0
fi

echo "The following unneeded packages will be removed:"
printf '  %s\n' "${pkgs[@]}"
echo

zypper remove --clean-deps -- "${pkgs[@]}"
