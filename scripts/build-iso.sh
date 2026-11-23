#!/usr/bin/env bash
set -euo pipefail
umask 022

if [[ $# != 2 ]]; then
    echo "Usage: $0 NEW_WORK_DIRECTORY ISO_OUTPUT_DIRECTORY" >&2
    exit 2
fi
if (( EUID != 0 )) || [[ $(uname -m) != x86_64 || ! -f /etc/arch-release ]]; then
    echo "Run on an x86_64 Arch Linux build host as root." >&2
    exit 1
fi

project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
work=$(realpath -m -- "$1")
out=$(realpath -m -- "$2")
mkdir -p -- "$work" "$out"
# mkarchiso skips successful steps from earlier runs in its work directory.
# Always start fresh so edited files make it into the next image.
if [[ -n $(find "$work" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
    echo "Use a new, empty work directory: $work" >&2
    exit 1
fi
if [[ "$out" == "$work" || "$out" == "$work"/* ]]; then
    echo "Place the output directory outside the work directory." >&2
    exit 1
fi
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$project" log -1 --format=%ct 2>/dev/null || date +%s)}
profile="$work/profile"
"$project/scripts/build-packages.sh" "$work/repo"
cp -a /usr/share/archiso/configs/releng "$profile"

# The local pacman repository is for the builder. The booted ISO keeps Arch's
# normal pacman.conf and package signature policy.
repo_url=$(python -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).as_uri())' "$work/repo")
printf '\n[vitreus-local]\nSigLevel = Optional TrustAll\nServer = %s\n' "$repo_url" >>"$profile/pacman.conf"
sed -i '/^linux$/c\linux-zen' "$profile/packages.x86_64"
cat "$project/packages/desktop.list" >>"$profile/packages.x86_64"
LC_ALL=C sort -u -o "$profile/packages.x86_64" "$profile/packages.x86_64"
grep -qx linux-zen "$profile/packages.x86_64"

# Keep the releng loader identifiers that its menus include, changing only the
# kernel/initrd paths in the BIOS, UEFI, PXE and GRUB loopback entries.
find "$profile/syslinux" "$profile/efiboot" "$profile/grub" -type f \
    \( -name '*.cfg' -o -name '*.conf' \) \
    -exec sed -i -e 's|/vmlinuz-linux\>|/vmlinuz-linux-zen|g' \
                 -e 's|/initramfs-linux\.img|/initramfs-linux-zen.img|g' \
                 -e 's/Arch Linux install medium/Vitreus Arch Zen/g' {} +
if [[ -e "$profile/airootfs/etc/mkinitcpio.d/linux.preset" ]]; then
    sed 's|/vmlinuz-linux\>|/vmlinuz-linux-zen|g; s|/initramfs-linux|/initramfs-linux-zen|g' \
        "$profile/airootfs/etc/mkinitcpio.d/linux.preset" >"$profile/airootfs/etc/mkinitcpio.d/linux-zen.preset"
    rm -- "$profile/airootfs/etc/mkinitcpio.d/linux.preset"
fi
cat "$project/profile/image-settings.sh" >>"$profile/profiledef.sh"
cp -a "$project/profile/airootfs/." "$profile/airootfs/"
etc="$profile/airootfs/etc"
system="$etc/systemd/system"

# The display manager owns the first login. NetworkManager owns the network
# devices. Disable releng's matching automatic console, SSH and network logins.
rm -f -- "$system/getty@tty1.service.d/autologin.conf" "$etc/ssh/sshd_config.d/10-archiso.conf"
find "$system" -type l \( -lname '*/systemd-networkd*.service' -o -lname '*/systemd-networkd*.socket' \
    -o -name iwd.service -o -name sshd.service \) -delete
rm -f -- "$etc/systemd/network/"*.network
ln -sfn /usr/lib/systemd/system/graphical.target "$system/default.target"
ln -sfn /usr/lib/systemd/system/sddm.service "$system/display-manager.service"
ln -sfn /usr/lib/systemd/system/NetworkManager.service "$system/multi-user.target.wants/NetworkManager.service"
mkdir -p "$system/bluetooth.target.wants"
ln -sfn /usr/lib/systemd/system/bluetooth.service "$system/bluetooth.target.wants/bluetooth.service"
ln -sfn /usr/lib/systemd/system/bluetooth.service "$system/dbus-org.bluez.service"
ln -sfn /usr/lib/systemd/system/power-profiles-daemon.service "$system/multi-user.target.wants/power-profiles-daemon.service"

"$project/scripts/stage-desktop.sh" "$profile/airootfs"
# archiso normalizes modes when copying the overlay. Retain execute permission
# for each shipped executable, including Vitreus helpers in the user's skel.
while IFS= read -r -d '' file; do
    path=${file#"$profile/airootfs"}
    printf 'file_permissions[%q]="0:0:755"\n' "$path" >>"$profile/profiledef.sh"
done < <(find "$profile/airootfs" -type f -perm /111 -print0)
mkarchiso -v -w "$work/archiso" -o "$work/output" "$profile"
shopt -s nullglob
images=("$work/output/"*.iso)
if (( ${#images[@]} != 1 )); then
    echo "Expected exactly one ISO in $work/output" >&2
    exit 1
fi
"$project/scripts/verify-iso.sh" "${images[0]}" "$work/archiso/iso/arch/x86_64/airootfs.sfs"
mv -- "${images[0]}" "$out/"
