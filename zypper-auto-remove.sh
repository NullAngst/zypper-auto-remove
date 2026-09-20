#!/usr/bin/env bash
#
# zypper-auto-remove - remove orphaned/unneeded packages on openSUSE systems.
#
# Rough equivalent of "apt autoremove" for zypper. It asks zypper which
# installed packages are no longer required by anything else, shows them,
# and hands the list to "zypper remove".
#
# See README.md for caveats. Short version: review the list before confirming.

set -euo pipefail

PROGNAME=${0##*/}
VERSION=2.0.0
NAME_RE='^[A-Za-z0-9][A-Za-z0-9._+-]*$'

REPEAT_LIMIT=5

DRY_RUN=0
ASSUME_YES=0
CLEAN_DEPS=1
MAX_PASSES=1

usage() {
    cat <<EOF
$PROGNAME $VERSION - remove unneeded (orphaned) packages on openSUSE.

Usage: $PROGNAME [options]

Options:
  -n, --dry-run     List what would be removed and exit. Does not need root.
  -y, --yes         Do not prompt; passes --non-interactive to zypper.
  -k, --keep-deps   Do not pass --clean-deps to zypper remove.
  -r, --repeat      Repeat until no unneeded packages remain (max $REPEAT_LIMIT passes).
  -h, --help        Show this help and exit.
  -V, --version     Show version and exit.

Exit status:
  0    Success, or nothing to do.
  1    Usage error, missing dependency, or zypper failure.
  2    Removal succeeded but a reboot is required (zypper exit 102).
  3    Removal succeeded but zypper itself must be restarted (zypper exit 103).
EOF
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    exit 1
}

parse_args() {
    while (( $# )); do
        case $1 in
            -n|--dry-run)   DRY_RUN=1 ;;
            -y|--yes)       ASSUME_YES=1 ;;
            -k|--keep-deps) CLEAN_DEPS=0 ;;
            -r|--repeat)    MAX_PASSES=$REPEAT_LIMIT ;;
            -h|--help)      usage; exit 0 ;;
            -V|--version)   printf '%s %s\n' "$PROGNAME" "$VERSION"; exit 0 ;;
            --)             shift; break ;;
            -*)             die "unknown option '$1' (try --help)" ;;
            *)              die "unexpected argument '$1' (try --help)" ;;
        esac
        shift
    done
    (( $# == 0 )) || die "unexpected argument '$1' (try --help)"
}

list_unneeded() {
    local raw status

    set +e
    raw=$(LC_ALL=C zypper --no-refresh --non-interactive packages --unneeded 2>&1)
    status=$?
    set -e

    if (( status != 0 && status != 104 )); then
        printf '%s\n' "$raw" >&2
        die "zypper exited $status while listing unneeded packages"
    fi

    printf '%s\n' "$raw" | awk -F'|' '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        NF >= 5 {
            state = trim($1)
            if (state != "i" && state != "i+") next
            name = trim($(NF - 2))
            if (name != "") print name
        }
    ' | sort -u
}

filter_names() {
    local name
    while IFS= read -r name; do
        if [[ $name =~ $NAME_RE ]]; then
            printf '%s\n' "$name"
        else
            printf '%s: skipping unparseable entry: %q\n' "$PROGNAME" "$name" >&2
        fi
    done
}

warn_about_sensitive() {
    local name
    local -a hits=()

    for name in "$@"; do
        case $name in
            kernel|kernel-*|*-kmp-*|dracut|grub2|grub2-*|systemd|glibc)
                hits+=("$name") ;;
        esac
    done

    if (( ${#hits[@]} > 0 )); then
        printf '\nWarning: this list includes packages that can affect booting or\n'
        printf 'hardware support. Check these before confirming:\n'
        printf '  %s\n' "${hits[@]}"
    fi
}

remove_packages() {
    local -a cmd=(zypper)
    local rc=0

    (( ASSUME_YES )) && cmd+=(--non-interactive)
    cmd+=(remove)
    (( CLEAN_DEPS )) && cmd+=(--clean-deps)
    cmd+=(-- "$@")

    set +e
    "${cmd[@]}"
    rc=$?
    set -e

    case $rc in
        0)   return 0 ;;
        102) printf '\n%s: removal succeeded; a reboot is required.\n' "$PROGNAME"; exit 2 ;;
        103) printf '\n%s: removal succeeded; zypper must be restarted.\n' "$PROGNAME"; exit 3 ;;
        *)   die "zypper remove exited $rc" ;;
    esac
}

main() {
    parse_args "$@"

    command -v zypper >/dev/null 2>&1 \
        || die "zypper not found; this script is for openSUSE-based systems"

    if (( DRY_RUN == 0 )) && [[ $(id -u) -ne 0 ]]; then
        die "must be run as root (use sudo), or pass --dry-run"
    fi

    local pass=1 listing
    local -a pkgs

    while (( pass <= MAX_PASSES )); do
        pkgs=()
        listing=$(list_unneeded | filter_names)
        if [[ -n $listing ]]; then
            mapfile -t pkgs <<<"$listing"
        fi

        if (( ${#pkgs[@]} == 0 )); then
            if (( pass == 1 )); then
                echo "No unneeded packages found. Nothing to do."
            else
                echo "No unneeded packages left."
            fi
            return 0
        fi

        if (( MAX_PASSES > 1 )); then
            printf 'Pass %d of %d.\n' "$pass" "$MAX_PASSES"
        fi

        printf 'Unneeded packages (%d):\n' "${#pkgs[@]}"
        printf '  %s\n' "${pkgs[@]}"
        warn_about_sensitive "${pkgs[@]}"
        echo

        if (( DRY_RUN )); then
            echo "Dry run: nothing was removed."
            return 0
        fi

        if (( CLEAN_DEPS )); then
            echo "Note: --clean-deps is in use, so zypper may remove more than the list above."
            echo "Read zypper's own summary before confirming."
            echo
        fi

        remove_packages "${pkgs[@]}"

        if (( MAX_PASSES == 1 )); then
            echo
            echo "Done. Removing orphans can orphan more packages; run again (or use --repeat)"
            echo "if you want the list drained completely."
            return 0
        fi

        (( pass++ )) || true
    done

    printf '%s: reached the pass limit (%d); run again if orphans remain.\n' \
        "$PROGNAME" "$MAX_PASSES"
}

main "$@"
