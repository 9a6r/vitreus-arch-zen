#!/usr/bin/env bash
# Resolve the entire live system against the same databases as the builder.
# pacstrap will install from this local mirror, including on a network timeout.
set -euo pipefail
profile=$(realpath -e "${1:?expected profile directory}")
work=$(realpath -e "${2:?expected build directory}")
db="$work/image-db"
mirror="$work/image-mirror"
cache=/var/cache/pacman/pkg
install -d "$db/local" "$db/sync" "$mirror" "$cache"
for repo in core extra; do
    cp -L "/var/lib/pacman/sync/$repo.db" "$db/sync/"
    if [[ -f "/var/lib/pacman/sync/$repo.db.sig" ]]; then
        cp -L "/var/lib/pacman/sync/$repo.db.sig" "$db/sync/"
    fi
done
cp -L "$work/repo/vitreus-local.db" "$db/sync/"
mapfile -t targets < <(awk 'NF && $1 !~ /^#/ { print $1 }' "$profile/packages.x86_64")
for attempt in 1 2 3 4; do
    if pacman --config "$profile/pacman.conf" --dbpath "$db" --cachedir "$cache" \
        -Sw --noconfirm "${targets[@]}"; then
        break
    fi
    (( attempt < 4 )) || exit 1
    sleep $((attempt * 5))
done

# A single flat directory can serve both official repositories. Keep their
# original database names, signatures and package bytes. The custom repo
# continues to point to its own directory.
cp -L "$db/sync/"{core,extra}.db "$mirror/"
shopt -s nullglob
signatures=("$db"/sync/{core,extra}.db.sig)
if (( ${#signatures[@]} )); then
    cp -L "${signatures[@]}" "$mirror/"
fi
for archive in "$cache/"*.pkg.tar.*; do
    ln -sf -- "$archive" "$mirror/"
done
export VITREUS_MIRROR_DIR="$mirror"
python - "$profile/pacman.conf" <<'PY'
import os
import sys
from pathlib import Path

config = Path(sys.argv[1])
include = "Include = /etc/pacman.d/mirrorlist"
lines = config.read_text().splitlines()
if lines.count(include) != 2:
    sys.exit("Expected the core and extra mirror lists in the releng profile")
server = "Server = " + Path(os.environ["VITREUS_MIRROR_DIR"]).as_uri()
config.write_text("\n".join(server if line == include else line for line in lines) + "\n")
PY
