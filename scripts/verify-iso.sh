#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 ISO [BUILT_SQUASHFS]" >&2
    exit 2
fi
iso=$(realpath -- "$1")
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# Read the finished medium, including the El Torito catalog and boot entries.
xorriso -abort_on FAILURE -indev "$iso" -report_el_torito plain \
    -osirrox on -extract /loader/entries/01-archiso-linux.conf "$tmp/uefi" \
    -extract /boot/syslinux/archiso_sys-linux.cfg "$tmp/bios" \
    -extract /boot/grub/loopback.cfg "$tmp/loopback" \
    -extract /arch/pkglist.x86_64.txt "$tmp/packages" >"$tmp/catalog"
grep -Eq 'El Torito boot img.*BIOS' "$tmp/catalog"
grep -Eq 'El Torito boot img.*UEFI' "$tmp/catalog"
for menu in uefi bios loopback; do
    grep -Fq '/arch/boot/x86_64/vmlinuz-linux-zen' "$tmp/$menu"
    grep -Fq '/arch/boot/x86_64/initramfs-linux-zen.img' "$tmp/$menu"
done
bsdtar -tf "$iso" >"$tmp/contents"
grep -Fxq arch/boot/x86_64/vmlinuz-linux-zen "$tmp/contents"
grep -Fxq arch/boot/x86_64/initramfs-linux-zen.img "$tmp/contents"
for package in linux-zen hyprland sddm pleamar iris-colors mpvpaper; do
    grep -q "^$package " "$tmp/packages"
done
if grep -q '^linux ' "$tmp/packages"; then
    echo "The live system contains the stock linux kernel." >&2
    exit 1
fi

member=arch/x86_64/airootfs.sfs
if [[ $# == 2 ]]; then
    sfs=$2
    # Verify the existing image against the ISO without storing another copy.
    bsdtar -xOf "$iso" "$member" | cmp - "$sfs"
else
    sfs="$tmp/airootfs.sfs"
    xorriso -abort_on FAILURE -osirrox on -indev "$iso" -extract "/$member" "$sfs"
fi
unsquashfs -ls "$sfs" >"$tmp/live-files"
shell=home/vitreus/.config/pleamar/shells/vitreus
for path in usr/bin/pleamar usr/bin/Hyprland usr/share/wayland-sessions/hyprland.desktop \
    usr/share/hypr/hyprland.lua usr/share/sddm/themes/vitreus/Main.qml \
    home/vitreus/.config/hypr/hyprland.lua home/vitreus/.config/pleamar/autostart \
    "$shell/vitreus.plm" "$shell/vitreus.luau"; do
    grep -Fxq "squashfs-root/$path" "$tmp/live-files" || { echo "Missing /$path" >&2; exit 1; }
done
for theme in glass cyber doodle milk paper proxy retro; do
    grep -Fxq "squashfs-root/$shell/themes/$theme.toml" "$tmp/live-files"
done
if grep -q '/themes/uwu.toml$' "$tmp/live-files"; then
    echo "UwU is still installed." >&2
    exit 1
fi
unsquashfs -cat "$sfs" etc/sddm.conf.d/20-vitreus-live.conf >"$tmp/autologin"
grep -Fxq 'User=vitreus' "$tmp/autologin"
grep -Fxq 'Session=hyprland.desktop' "$tmp/autologin"
echo "Verified the Zen kernel, hybrid boot configuration and Vitreus live filesystem in $iso"
