#!/usr/bin/env bash
# Delivered only to the disposable QEMU guest by systemd credentials.
set -euo pipefail
exec >/dev/ttyS0 2>&1
data=/home/vitreus/.local/share/pleamar/vitreus

diagnose() {
    status=$?
    if (( status )); then
        systemctl status display-manager --no-pager || true
        journalctl -b -u sddm -n 35 --no-pager || true
        journalctl -b _UID="$(id -u vitreus)" -n 65 --no-pager || true
        tail -n 45 "$data/vitreus.log" "$data/logs/vitreus.log" 2>/dev/null || true
        tail -n 25 /home/vitreus/.local/share/sddm/wayland-session.log 2>/dev/null || true
        echo VITREUS_SMOKE_FAILURE
    fi
}
trap diagnose EXIT

kernel=$(uname -r)
echo "Booted kernel $kernel"
[[ $kernel == *-zen* ]]
test "$(cat "/usr/lib/modules/$kernel/pkgbase")" = linux-zen
runtime=/run/user/$(id -u vitreus)

# Read the actual session environment. The shell may run beside auxiliary
# pleamar scenes such as the lock screen.
find_scene() {
    local environment
    for pid in $(pgrep -x -u vitreus pleamar); do
        grep -zq '/vitreus\.plm$' "/proc/$pid/cmdline" 2>/dev/null || continue
        environment=$(tr '\0' '\n' <"/proc/$pid/environ") || continue
        display=$(sed -n 's/^WAYLAND_DISPLAY=//p' <<<"$environment")
        [[ -S "$runtime/$display" ]] || continue
        signature=$(sed -n 's/^HYPRLAND_INSTANCE_SIGNATURE=//p' <<<"$environment")
        [[ -n "$signature" ]] || continue
        binary=$(readlink -e "/proc/$pid/exe") || continue
        return 0
    done
    return 1
}
# Hyprland lists only mapped layers here. Matching the exact live scene PID
# catches a shell that answers IPC before its first buffer reaches the monitor.
mapped_layer() {
    timeout 6 runuser -u vitreus -- env XDG_RUNTIME_DIR="$runtime" HYPRLAND_INSTANCE_SIGNATURE="$signature" \
        /usr/bin/hyprctl -j layers | jq -e --argjson pid "$pid" \
        'any(.[] | .levels[][]; .pid == $pid and .alpha > 0 and .w > 0 and .h > 0)' >/dev/null
}
say() {
    timeout 18 runuser -u vitreus -- env XDG_RUNTIME_DIR="$runtime" WAYLAND_DISPLAY="$display" \
        "$binary" --say vitreus "$1"
}

deadline=$((SECONDS + 480))
while (( SECONDS < deadline )); do
    if find_scene && mapped_layer && [[ $(say 'wait screen.width > 0 and bar_c0 == true 5s' 2>/dev/null) == yes* ]]; then
        break
    fi
    sleep 3
done
(( SECONDS < deadline ))
systemctl is-active --quiet display-manager.service
pgrep -xi -u vitreus Hyprland >/dev/null
echo "Wayland $display; Vitreus answered on $runtime"
echo "Mapped bar from PID $pid; anchor $(say 'get bar_anchor'); frame $(say 'get bar_frame')"
echo VITREUS_SMOKE_DESKTOP

# The host takes a screenshot, then presses the real SUPER+C binding.
[[ $(timeout 75 runuser -u vitreus -- env XDG_RUNTIME_DIR="$runtime" WAYLAND_DISPLAY="$display" \
    "$binary" --say vitreus 'wait panel == controls and dk > 0.95 60s') == yes* ]]
sleep 2
mapped_layer
echo VITREUS_SMOKE_CONTROLS
