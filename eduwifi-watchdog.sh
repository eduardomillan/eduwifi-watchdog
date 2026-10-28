#!/bin/bash
# eduwifi-watchdog: monitors the Wi-Fi connection and recovers it when the adapter hangs.
# Escalation: reconnect to the configured networks -> reload kernel module -> software USB reset.
# Configuration: /etc/eduwifi-watchdog.conf (or the path in $EDUWIFI_WATCHDOG_CONF).

CONF=${EDUWIFI_WATCHDOG_CONF:-/etc/eduwifi-watchdog.conf}

# Defaults (overridden by the configuration file)
IFACE=wlan0
NETWORKS=""             # comma-separated NetworkManager profiles, in priority order
MODULE=""               # kernel module to reload (empty = never reload)
USB_ID=""               # vendor:product of the USB adapter (empty = no USB reset)
FAILS_NEEDED=2          # consecutive failed checks before acting
MAX_HARD_PER_HOUR=3     # max module reloads / USB resets per hour
CONNECT_TIMEOUT=30      # seconds to wait for each connection attempt
STATE_DIR=/run/eduwifi-watchdog

if [ -r "$CONF" ]; then
    # shellcheck source=/dev/null
    . "$CONF"
fi

usage() {
    cat <<EOF
Usage: $(basename "$0") [command] [options]

Commands:
  check        Check the Wi-Fi and recover it if needed (default; used by the timer)
  status       Show Wi-Fi and watchdog status plus the latest events
  disconnect   Disconnect the Wi-Fi manually; the watchdog won't reconnect until 'on'
  off          Turn the Wi-Fi radio off; stays off (even after reboot) until 'on'
  on           Turn the Wi-Fi on, re-enable autoconnect and connect to the networks
  test         Simulate a driver hang and verify the watchdog recovers it (root)

Options for 'check':
  --dry-run    Only report what would be done, change nothing
  --force      Skip straight to reloading the kernel module

Configuration: $CONF
EOF
}

CMD=check
DRY_RUN=0
FORCE=0
for arg in "$@"; do
    case "$arg" in
        check|status|disconnect|off|on|test) CMD=$arg ;;
        --dry-run) DRY_RUN=1 ;;
        --force)   FORCE=1 ;;
        -h|--help|help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

log() {
    logger -t eduwifi-watchdog -- "$*"
    [ -t 1 ] && echo "$*"
    return 0
}

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] $*"
    else
        "$@"
    fi
}

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "The '$CMD' command requires root: sudo $0 $CMD" >&2
        exit 1
    fi
}

wifi_ok() {
    [ -e "/sys/class/net/$IFACE" ] || return 1
    nmcli -g GENERAL.STATE device show "$IFACE" 2>/dev/null | grep -q '^100' || return 1
    local gw
    gw=$(ip -4 route show default dev "$IFACE" 2>/dev/null | awk '{print $3; exit}')
    [ -n "$gw" ] || return 1
    ping -I "$IFACE" -c 2 -W 2 "$gw" >/dev/null 2>&1
}

wait_ok() {
    local secs=$1
    for _ in $(seq "$secs"); do
        sleep 1
        wifi_ok && return 0
    done
    return 1
}

# Returns 0 if the user deliberately turned off or disconnected the Wi-Fi
user_paused() {
    if [ "$(nmcli radio wifi 2>/dev/null)" = "disabled" ]; then
        echo "Wi-Fi radio is off"
        return 0
    fi
    # 'nmcli device disconnect' sets the device's autoconnect to "no"
    if [ -e "/sys/class/net/$IFACE" ] && \
       [ "$(nmcli -g GENERAL.AUTOCONNECT device show "$IFACE" 2>/dev/null)" = "no" ]; then
        echo "$IFACE was disconnected manually"
        return 0
    fi
    return 1
}

hard_actions_last_hour() {
    local cutoff count=0
    cutoff=$(( $(date +%s) - 3600 ))
    [ -f "$STATE_DIR/hard" ] || { echo 0; return; }
    while read -r t; do
        [ "$t" -ge "$cutoff" ] 2>/dev/null && count=$((count + 1))
    done < "$STATE_DIR/hard"
    echo "$count"
}

record_hard_action() {
    [ "$DRY_RUN" -eq 1 ] && return
    date +%s >> "$STATE_DIR/hard"
    # Keep only the timestamps from the last hour
    local cutoff=$(( $(date +%s) - 3600 ))
    awk -v c="$cutoff" '$1 >= c' "$STATE_DIR/hard" > "$STATE_DIR/hard.tmp" && mv "$STATE_DIR/hard.tmp" "$STATE_DIR/hard"
}

find_usb_dev() {
    local d
    [ -n "$USB_ID" ] || return 1
    for d in /sys/bus/usb/devices/*; do
        [ "$(cat "$d/idVendor" 2>/dev/null):$(cat "$d/idProduct" 2>/dev/null)" = "$USB_ID" ] && { echo "$d"; return 0; }
    done
    return 1
}

save_dmesg() {
    local pattern=${MODULE:-$IFACE}
    log "Latest kernel messages: $(journalctl -k -n 300 --no-pager 2>/dev/null | grep -iE "${pattern%%_*}|$IFACE" | grep -v UFW | tail -5 | tr '\n' '|')"
}

level1_reconnect() {
    local net nets
    if [ -z "$NETWORKS" ]; then
        log "Level 1: reconnecting $IFACE with nmcli (no networks configured)"
        run nmcli device connect "$IFACE" >/dev/null 2>&1
        [ "$DRY_RUN" -eq 1 ] && return 1
        wait_ok "$CONNECT_TIMEOUT"
        return
    fi
    IFS=',' read -ra nets <<< "$NETWORKS"
    for net in "${nets[@]}"; do
        net=$(echo "$net" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [ -n "$net" ] || continue
        log "Level 1: connecting $IFACE to \"$net\""
        run nmcli --wait "$CONNECT_TIMEOUT" connection up id "$net" ifname "$IFACE" >/dev/null 2>&1
        [ "$DRY_RUN" -eq 1 ] && continue
        wait_ok 10 && return 0
    done
    return 1
}

level2_reload_module() {
    [ -n "$MODULE" ] || { log "Level 2: no MODULE configured, skipping"; return 1; }
    log "Level 2: reloading kernel module $MODULE"
    record_hard_action
    run modprobe -r "$MODULE" || { log "modprobe -r $MODULE failed"; return 1; }
    run sleep 3
    run modprobe "$MODULE" || { log "modprobe $MODULE failed"; return 1; }
    [ "$DRY_RUN" -eq 1 ] && return 1
    wait_ok "$CONNECT_TIMEOUT" || level1_reconnect
}

level3_usb_reset() {
    local dev
    [ -n "$USB_ID" ] || { log "Level 3: no USB_ID configured, skipping"; return 1; }
    dev=$(find_usb_dev) || { log "Level 3: USB device $USB_ID not found; it must be unplugged physically"; return 1; }
    log "Level 3: software USB reset of $dev"
    record_hard_action
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] echo 0/1 > $dev/authorized"
        return 1
    fi
    echo 0 > "$dev/authorized" && sleep 2 && echo 1 > "$dev/authorized"
    sleep 5
    [ -e "/sys/class/net/$IFACE" ] || { [ -n "$MODULE" ] && modprobe "$MODULE"; }
    wait_ok "$CONNECT_TIMEOUT" || level1_reconnect
}

cmd_check() {
    local fails hard reason
    if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" -eq 0 ]; then
        echo "Must be run as root (or with --dry-run)" >&2
        exit 1
    fi
    mkdir -p "$STATE_DIR" 2>/dev/null

    if reason=$(user_paused); then
        [ -t 1 ] && echo "Paused: $reason. Run '$(basename "$0") on' to resume."
        [ "$DRY_RUN" -eq 0 ] && rm -f "$STATE_DIR/fails"
        exit 0
    fi

    if [ "$FORCE" -eq 0 ]; then
        if wifi_ok; then
            [ "$DRY_RUN" -eq 0 ] && rm -f "$STATE_DIR/fails"
            [ -t 1 ] && echo "Wi-Fi OK, nothing to do"
            exit 0
        fi
        fails=$(( $(cat "$STATE_DIR/fails" 2>/dev/null || echo 0) + 1 ))
        [ "$DRY_RUN" -eq 0 ] && echo "$fails" > "$STATE_DIR/fails"
        if [ "$fails" -lt "$FAILS_NEEDED" ]; then
            log "Wi-Fi not responding (failure $fails/$FAILS_NEEDED), waiting for the next check"
            exit 0
        fi
        save_dmesg
        if level1_reconnect; then
            log "Recovered at level 1"; rm -f "$STATE_DIR/fails"; exit 0
        fi
    fi

    hard=$(hard_actions_last_hour)
    if [ "$hard" -ge "$MAX_HARD_PER_HOUR" ]; then
        log "Limit reached ($hard reloads/resets in the last hour); not acting until later"
        exit 1
    fi

    if level2_reload_module; then
        log "Recovered at level 2 (module reload)"; rm -f "$STATE_DIR/fails"; exit 0
    fi
    if level3_usb_reset; then
        log "Recovered at level 3 (USB reset)"; rm -f "$STATE_DIR/fails"; exit 0
    fi

    log "Could not recover the Wi-Fi; the adapter must be unplugged physically"
    exit 1
}

cmd_status() {
    local reason
    echo "Interface:    $IFACE ($(nmcli -g GENERAL.STATE,GENERAL.CONNECTION device show "$IFACE" 2>/dev/null | paste -sd' ' || echo 'not present'))"
    echo "Wi-Fi radio:  $(nmcli radio wifi 2>/dev/null)"
    if wifi_ok; then echo "Connectivity: OK (gateway responds)"; else echo "Connectivity: NO RESPONSE"; fi
    if reason=$(user_paused); then echo "Watchdog:     PAUSED ($reason)"; else echo "Watchdog:     active"; fi
    echo "Timer:        $(systemctl is-active eduwifi-watchdog.timer 2>/dev/null)"
    echo "Networks:     ${NETWORKS:-(chosen by NetworkManager)}"
    echo "Module:       ${MODULE:-(none)}    USB: ${USB_ID:-(none)}"
    echo
    echo "Latest events:"
    journalctl -t eduwifi-watchdog -n 10 --no-pager -o short 2>/dev/null | sed 's/^/  /'
}

cmd_disconnect() {
    nmcli device disconnect "$IFACE" || exit 1
    log "Disconnected manually by $(id -un); the watchdog won't reconnect until 'on'"
}

cmd_off() {
    nmcli radio wifi off || exit 1
    log "Wi-Fi radio turned off by $(id -un); it won't reconnect until 'on'"
}

cmd_on() {
    log "Re-enabling Wi-Fi at the request of $(id -un)"
    nmcli radio wifi on || exit 1
    # Wait for the interface to come back after turning the radio on
    for _ in $(seq 10); do
        [ -e "/sys/class/net/$IFACE" ] && break
        sleep 1
    done
    nmcli device set "$IFACE" autoconnect yes 2>/dev/null
    if level1_reconnect; then
        log "Wi-Fi connected: $(nmcli -g GENERAL.CONNECTION device show "$IFACE")"
    else
        log "Wi-Fi is on but not connected yet; the watchdog will keep trying"
        exit 1
    fi
}

cmd_test() {
    local start elapsed limit timer level
    need_root
    [ -n "$MODULE" ] || { echo "The test needs MODULE set in $CONF" >&2; exit 1; }
    if user_paused >/dev/null; then
        echo "Wi-Fi is paused by the user; run '$(basename "$0") on' first" >&2
        exit 1
    fi
    wifi_ok || { echo "Wi-Fi is not working right now; the test must start from a good connection" >&2; exit 1; }

    timer=$(systemctl is-active eduwifi-watchdog.timer 2>/dev/null)
    limit=$(( (FAILS_NEEDED + 1) * 60 + 3 * CONNECT_TIMEOUT + 30 ))
    echo "Test: unloading $MODULE to simulate a hang. The Wi-Fi will drop."
    if [ "$timer" = active ]; then
        echo "The timer is active: waiting up to ${limit}s for it to recover on its own."
    else
        echo "The timer is not active: running the recovery directly."
    fi

    start=$(date +%s)
    log "Test: simulating a hang (modprobe -r $MODULE)"
    modprobe -r "$MODULE" || { log "Test: could not unload $MODULE"; exit 1; }

    if [ "$timer" != active ]; then
        "$0" check --force >/dev/null
    else
        while ! wifi_ok && [ $(( $(date +%s) - start )) -lt "$limit" ]; do
            sleep 5
            printf '.'
        done
        echo
    fi

    elapsed=$(( $(date +%s) - start ))
    if wifi_ok; then
        level=$(journalctl -t eduwifi-watchdog --since "@$start" --no-pager -o cat 2>/dev/null | grep -m1 '^Recovered' || true)
        log "Test passed: Wi-Fi recovered in ${elapsed}s. ${level}"
        exit 0
    fi

    log "Test FAILED: no Wi-Fi after ${elapsed}s; restoring the module manually"
    modprobe "$MODULE"
    level1_reconnect || true
    echo "See: journalctl -t eduwifi-watchdog --since '@$start'" >&2
    exit 1
}

case "$CMD" in
    check)      cmd_check ;;
    status)     cmd_status ;;
    disconnect) cmd_disconnect ;;
    off)        cmd_off ;;
    on)         cmd_on ;;
    test)       cmd_test ;;
esac
