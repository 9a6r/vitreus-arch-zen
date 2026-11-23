#!/usr/bin/env bash
# Build the project packages as an unprivileged user inside an Arch build host.
set -euo pipefail

if (( EUID != 0 || $# != 1 )); then
    echo "Usage (as root): $0 /absolute/path/to/repo" >&2
    exit 2
fi
repo=$(realpath -m -- "$1")
recipes=$(cd -- "$(dirname -- "$0")/../packages" && pwd)
mkdir -p -- "$repo"

# Use the same Arch package repositories as the ISO builder.
# These also supply the font instancer and wallpaper tools for staging.
pacman -S --needed --noconfirm base-devel git rust curl libxkbcommon pam wayland \
    vulkan-icd-loader fontconfig mpv mesa libglvnd wayland-protocols meson ninja \
    python-build python-installer python-hatchling python-pillow python-numpy \
    python-fonttools imagemagick

build_root=$(mktemp -d /var/tmp/vitreus-makepkg.XXXXXXXX)
trap 'rm -rf -- "$build_root"' EXIT
builder=nobody
chown "$builder" "$build_root"
install -d -o "$builder" "$build_root/home" "$build_root/pkgs"

for name in pleamar iris-colors mpvpaper; do
    install -d -o "$builder" "$build_root/$name"
    install -m644 "$recipes/$name/PKGBUILD" "$build_root/$name/PKGBUILD"
    (
        cd "$build_root/$name"
        runuser -u "$builder" -- env HOME="$build_root/home" PKGDEST="$build_root/pkgs" \
            CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}" makepkg --clean --noconfirm
    )
done
packages=()
for archive in "$build_root/pkgs/"*.pkg.tar.*; do
    install -m644 "$archive" "$repo/"
    packages+=("$repo/${archive##*/}")
done
repo-add "$repo/vitreus-local.db.tar.gz" "${packages[@]}"
