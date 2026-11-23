#!/usr/bin/env bash
# Boot the ISO itself with BIOS in a disposable offline VM, then exercise its UI.
set -euo pipefail
if (( $# != 2 )); then
    echo "Usage: $0 image.iso new-results-directory" >&2
    exit 2
fi
if [[ ${VITREUS_TEST_X11:-} != 1 ]]; then
    exec xvfb-run -a -s '-screen 0 1280x800x24 +extension GLX' \
        env VITREUS_TEST_X11=1 LIBGL_ALWAYS_SOFTWARE=1 GDK_BACKEND=x11 "$0" "$@"
fi

iso=$(realpath -e -- "$1")
script_dir=$(dirname "$(realpath "$0")")
results=$(realpath -m -- "$2")
mkdir -p "$results"
work=$(mktemp -d)
vm=
clean() {
    if [[ -n $vm ]]; then
        kill "$vm" 2>/dev/null || true
        wait "$vm" 2>/dev/null || true
    fi
    rm -rf -- "$work"
}
trap clean EXIT
cd "$work"
mkfifo monitor
exec 3<>monitor

cat > unit <<'UNIT'
[Unit]
Description=Inspect the disposable Vitreus test session
ConditionPathExists=!/etc/initrd-release
After=local-fs.target
[Service]
Type=simple
ImportCredential=vitreus.probe
ExecStart=/usr/bin/bash %d/vitreus.probe
UNIT
printf '[Unit]\nWants=vitreus-probe.service\n' > dropin
credential() {
    printf 'type=11,value=io.systemd.credential.binary:%s=%s' "$1" "$(base64 -w0 "$2")"
}
accel=tcg
cpu=max
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    accel=kvm
    cpu=host
fi
echo "Booting $iso with $accel and software virgl graphics."
qemu-system-x86_64 -machine "q35,accel=$accel" -cpu "$cpu" -smp 4 -m 4096 \
    -boot order=d -cdrom "$iso" -nic none -no-reboot \
    -vga none -device virtio-vga-gl -display gtk,gl=on -serial "file:$results/serial.log" \
    -monitor stdio -smbios "$(credential systemd.extra-unit.vitreus-probe.service unit)" \
    -smbios "$(credential systemd.unit-dropin.multi-user.target dropin)" \
    -smbios "$(credential vitreus.probe "$script_dir/test/guest-session.sh")" \
    <monitor >"$results/qemu.log" 2>&1 &
vm=$!

wait_marker() {
    local marker=$1 limit=$((SECONDS + $2))
    while (( SECONDS < limit )); do
        grep -Fq "$marker" "$results/serial.log" 2>/dev/null && return 0
        if ! kill -0 "$vm" 2>/dev/null || grep -Fq VITREUS_SMOKE_FAILURE "$results/serial.log" 2>/dev/null; then
            break
        fi
        sleep 2
    done
    echo "Guest did not reach $marker." >&2
    tail -n 120 "$results/serial.log" >&2 || true
    return 1
}
capture() {
    local name=$1
    printf 'screendump %s.png -f png\n' "$name" >&3
    for ((n=0; n<40; n++)); do
        # IEND marks a complete PNG before moving it out of the monitor's working directory.
        if [[ -f $name.png ]] && tail -c 12 "$name.png" | LC_ALL=C grep -aq IEND; then
            mv -- "$name.png" "$results/"
            return
        fi
        sleep 0.25
    done
    echo "QEMU could not capture $name.png" >&2
    return 1
}
if ! wait_marker VITREUS_SMOKE_DESKTOP 720; then
    if kill -0 "$vm" 2>/dev/null; then capture failed || true; fi
    tail -c 1800 "$results/qemu.log" >&2
    exit 1
fi
capture desktop
printf 'sendkey meta_l-c\n' >&3
if ! wait_marker VITREUS_SMOKE_CONTROLS 85; then
    capture failed || true
    exit 1
fi
capture controls
cat "$results/serial.log"
