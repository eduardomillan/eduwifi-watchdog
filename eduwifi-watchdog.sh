#!/bin/bash
# eduwifi-watchdog: monitors the Wi-Fi connection and recovers it when the adapter hangs.
# Escalation: reconnect to the configured networks -> reload kernel module -> software USB reset.
# Configuration: /etc/eduwifi-watchdog.conf (or the path in $EDUWIFI_WATCHDOG_CONF).

CONF=${EDUWIFI_WATCHDOG_CONF:-/etc/eduwifi-watchdog.conf}
SELF=$(readlink -f "$0")
PROG=eduwifi-watchdog

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

# --- Translations (gettext) ---
# Messages shown to the user are translated; journal entries always stay in English.
export TEXTDOMAIN=eduwifi-watchdog
if [ -z "$TEXTDOMAINDIR" ]; then
    # Running from a checkout with compiled translations, or installed system-wide
    if [ -d "$(dirname "$SELF")/build/locale" ]; then
        TEXTDOMAINDIR=$(dirname "$SELF")/build/locale
    else
        TEXTDOMAINDIR=/usr/share/locale
    fi
fi
export TEXTDOMAINDIR
command -v gettext >/dev/null 2>&1 || gettext() { printf '%s' "$1"; }

# say FORMAT [ARGS...]: print a translated message to stdout
say() {
    local fmt
    fmt=$(gettext "$1"); shift
    # shellcheck disable=SC2059
    printf "$fmt\n" "$@"
}

# err FORMAT [ARGS...]: print a translated message to stderr
err() {
    say "$@" >&2
}

# log FORMAT [ARGS...]: English to the journal, translated to the terminal
log() {
    local fmt=$1; shift
    # shellcheck disable=SC2059
    logger -t "$PROG" -- "$(printf "$fmt" "$@")"
    [ -t 1 ] && say "$fmt" "$@"
    return 0
}

usage() {
    say 'Usage: %s [command] [options]

Commands:
  check        Check the Wi-Fi and recover it if needed (default; used by the timer)
  status       Show Wi-Fi and watchdog status plus the latest events
  disconnect   Disconnect the Wi-Fi manually; the watchdog will not reconnect until "on"
  off          Turn the Wi-Fi radio off; stays off (even after reboot) until "on"
  on           Turn the Wi-Fi on, re-enable autoconnect and connect to the networks
  test         Simulate a driver hang and verify the watchdog recovers it (root)
  gui [ACTION] Desktop dialog used by the menu entry; ACTION is status, off, on or recover

Options for "check":
  --dry-run    Only report what would be done, change nothing
  --force      Skip straight to reloading the kernel module

Configuration: %s' "$(basename "$0")" "$CONF"
}

CMD=check
GUI_ACTION=""
DRY_RUN=0
FORCE=0
for arg in "$@"; do
    case "$arg" in
        status|off|on|recover)
            if [ "$CMD" = gui ] && [ -z "$GUI_ACTION" ]; then
                GUI_ACTION=$arg
            elif [ "$arg" != recover ]; then
                CMD=$arg
            else
                usage >&2; exit 2
            fi ;;
        check|disconnect|test|gui) CMD=$arg ;;
        --dry-run) DRY_RUN=1 ;;
        --force)   FORCE=1 ;;
        -h|--help|help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log '[dry-run] %s' "$*"
    else
        "$@"
    fi
}

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err 'The "%s" command requires root: sudo %s %s' "$CMD" "$0" "$CMD"
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

# Prints the (translated) reason and returns 0 if the user deliberately
# turned off or disconnected the Wi-Fi
user_paused() {
    if [ "$(nmcli radio wifi 2>/dev/null)" = "disabled" ]; then
        say 'Wi-Fi radio is off'
        return 0
    fi
    # 'nmcli device disconnect' sets the device's autoconnect to "no"
    if [ -e "/sys/class/net/$IFACE" ] && \
       [ "$(nmcli -g GENERAL.AUTOCONNECT device show "$IFACE" 2>/dev/null)" = "no" ]; then
        say '%s was disconnected manually' "$IFACE"
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
    log 'Latest kernel messages: %s' "$(journalctl -k -n 300 --no-pager 2>/dev/null | grep -iE "${pattern%%_*}|$IFACE" | grep -v UFW | tail -5 | tr '\n' '|')"
}

level1_reconnect() {
    local net nets
    if [ -z "$NETWORKS" ]; then
        log 'Level 1: reconnecting %s with nmcli (no networks configured)' "$IFACE"
        run nmcli device connect "$IFACE" >/dev/null 2>&1
        [ "$DRY_RUN" -eq 1 ] && return 1
        wait_ok "$CONNECT_TIMEOUT"
        return
    fi
    IFS=',' read -ra nets <<< "$NETWORKS"
    for net in "${nets[@]}"; do
        net=$(echo "$net" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [ -n "$net" ] || continue
        log 'Level 1: connecting %s to "%s"' "$IFACE" "$net"
        run nmcli --wait "$CONNECT_TIMEOUT" connection up id "$net" ifname "$IFACE" >/dev/null 2>&1
        [ "$DRY_RUN" -eq 1 ] && continue
        wait_ok 10 && return 0
    done
    return 1
}

level2_reload_module() {
    if [ -z "$MODULE" ]; then
        log 'Level 2: no MODULE configured, skipping'
        return 1
    fi
    log 'Level 2: reloading kernel module %s' "$MODULE"
    record_hard_action
    if ! run modprobe -r "$MODULE"; then
        log 'modprobe -r %s failed' "$MODULE"
        return 1
    fi
    run sleep 3
    if ! run modprobe "$MODULE"; then
        log 'modprobe %s failed' "$MODULE"
        return 1
    fi
    [ "$DRY_RUN" -eq 1 ] && return 1
    wait_ok "$CONNECT_TIMEOUT" || level1_reconnect
}

level3_usb_reset() {
    local dev
    if [ -z "$USB_ID" ]; then
        log 'Level 3: no USB_ID configured, skipping'
        return 1
    fi
    if ! dev=$(find_usb_dev); then
        log 'Level 3: USB device %s not found; it must be unplugged physically' "$USB_ID"
        return 1
    fi
    log 'Level 3: software USB reset of %s' "$dev"
    record_hard_action
    if [ "$DRY_RUN" -eq 1 ]; then
        log '[dry-run] %s' "echo 0/1 > $dev/authorized"
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
        err 'Must be run as root (or with --dry-run)'
        exit 1
    fi
    mkdir -p "$STATE_DIR" 2>/dev/null

    if reason=$(user_paused); then
        [ -t 1 ] && say 'Paused: %s. Run "%s on" to resume.' "$reason" "$PROG"
        [ "$DRY_RUN" -eq 0 ] && rm -f "$STATE_DIR/fails"
        exit 0
    fi

    if [ "$FORCE" -eq 0 ]; then
        if wifi_ok; then
            [ "$DRY_RUN" -eq 0 ] && rm -f "$STATE_DIR/fails"
            [ -t 1 ] && say 'Wi-Fi OK, nothing to do'
            exit 0
        fi
        fails=$(( $(cat "$STATE_DIR/fails" 2>/dev/null || echo 0) + 1 ))
        [ "$DRY_RUN" -eq 0 ] && echo "$fails" > "$STATE_DIR/fails"
        if [ "$fails" -lt "$FAILS_NEEDED" ]; then
            log 'Wi-Fi not responding (failure %s/%s), waiting for the next check' "$fails" "$FAILS_NEEDED"
            exit 0
        fi
        save_dmesg
        if level1_reconnect; then
            log 'Recovered at level 1'; rm -f "$STATE_DIR/fails"; exit 0
        fi
    fi

    hard=$(hard_actions_last_hour)
    if [ "$hard" -ge "$MAX_HARD_PER_HOUR" ]; then
        log 'Limit reached (%s reloads/resets in the last hour); not acting until later' "$hard"
        exit 1
    fi

    if level2_reload_module; then
        log 'Recovered at level 2 (module reload)'; rm -f "$STATE_DIR/fails"; exit 0
    fi
    if level3_usb_reset; then
        log 'Recovered at level 3 (USB reset)'; rm -f "$STATE_DIR/fails"; exit 0
    fi

    log 'Could not recover the Wi-Fi; the adapter must be unplugged physically'
    exit 1
}

cmd_status() {
    local reason state
    state=$(nmcli -g GENERAL.STATE,GENERAL.CONNECTION device show "$IFACE" 2>/dev/null | paste -sd' ')
    say 'Interface:     %s (%s)' "$IFACE" "${state:-$(gettext 'not present')}"
    say 'Wi-Fi radio:   %s' "$(nmcli radio wifi 2>/dev/null)"
    if wifi_ok; then
        say 'Connectivity:  OK (gateway responds)'
    else
        say 'Connectivity:  NO RESPONSE'
    fi
    if reason=$(user_paused); then
        say 'Watchdog:      PAUSED (%s)' "$reason"
    else
        say 'Watchdog:      active'
    fi
    say 'Timer:         %s' "$(systemctl is-active "$PROG.timer" 2>/dev/null)"
    say 'Networks:      %s' "${NETWORKS:-$(gettext '(chosen by NetworkManager)')}"
    say 'Module:        %s    USB: %s' "${MODULE:-$(gettext '(none)')}" "${USB_ID:-$(gettext '(none)')}"
    echo
    say 'Latest events:'
    journalctl -t "$PROG" -n 10 --no-pager -o short 2>/dev/null | sed 's/^/  /'
}

cmd_disconnect() {
    nmcli device disconnect "$IFACE" >/dev/null || exit 1
    log 'Disconnected manually by %s; the watchdog will not reconnect until "on"' "$(id -un)"
}

cmd_off() {
    nmcli radio wifi off || exit 1
    log 'Wi-Fi radio turned off by %s; it will not reconnect until "on"' "$(id -un)"
}

cmd_on() {
    log 'Re-enabling Wi-Fi at the request of %s' "$(id -un)"
    nmcli radio wifi on || exit 1
    # Wait for the interface to come back after turning the radio on
    for _ in $(seq 10); do
        [ -e "/sys/class/net/$IFACE" ] && break
        sleep 1
    done
    nmcli device set "$IFACE" autoconnect yes 2>/dev/null
    if level1_reconnect; then
        log 'Wi-Fi connected: %s' "$(nmcli -g GENERAL.CONNECTION device show "$IFACE")"
    else
        log 'Wi-Fi is on but not connected yet; the watchdog will keep trying'
        exit 1
    fi
}

cmd_test() {
    local start elapsed limit timer level
    need_root
    if [ -z "$MODULE" ]; then
        err 'The test needs MODULE set in %s' "$CONF"
        exit 1
    fi
    if user_paused >/dev/null; then
        err 'Wi-Fi is paused by the user; run "%s on" first' "$PROG"
        exit 1
    fi
    if ! wifi_ok; then
        err 'Wi-Fi is not working right now; the test must start from a good connection'
        exit 1
    fi

    timer=$(systemctl is-active "$PROG.timer" 2>/dev/null)
    limit=$(( (FAILS_NEEDED + 1) * 60 + 3 * CONNECT_TIMEOUT + 30 ))
    say 'Test: unloading %s to simulate a hang. The Wi-Fi will drop.' "$MODULE"
    if [ "$timer" = active ]; then
        say 'The timer is active: waiting up to %ss for it to recover on its own.' "$limit"
    else
        say 'The timer is not active: running the recovery directly.'
    fi

    start=$(date +%s)
    log 'Test: simulating a hang (modprobe -r %s)' "$MODULE"
    if ! modprobe -r "$MODULE"; then
        log 'Test: could not unload %s' "$MODULE"
        exit 1
    fi

    if [ "$timer" != active ]; then
        "$SELF" check --force >/dev/null
    else
        while ! wifi_ok && [ $(( $(date +%s) - start )) -lt "$limit" ]; do
            sleep 5
            printf '.'
        done
        echo
    fi

    elapsed=$(( $(date +%s) - start ))
    if wifi_ok; then
        # The journal is always in English, so this match is language-independent
        level=$(journalctl -t "$PROG" --since "@$start" --no-pager -o cat 2>/dev/null | grep -m1 '^Recovered' || true)
        log 'Test passed: Wi-Fi recovered in %ss. %s' "$elapsed" "$level"
        exit 0
    fi

    log 'Test FAILED: no Wi-Fi after %ss; restoring the module manually' "$elapsed"
    modprobe "$MODULE"
    level1_reconnect || true
    err 'See: journalctl -t %s --since "@%s"' "$PROG" "$start"
    exit 1
}

# --- Desktop dialog (menu entry) ---

gui_tool() {
    if [ -n "$DISPLAY$WAYLAND_DISPLAY" ]; then
        case "$XDG_CURRENT_DESKTOP" in
            *KDE*) command -v kdialog >/dev/null && { echo kdialog; return; } ;;
        esac
        command -v zenity >/dev/null && { echo zenity; return; }
        command -v kdialog >/dev/null && { echo kdialog; return; }
    fi
    echo none
}

notify() {
    if command -v notify-send >/dev/null; then
        notify-send -a "$PROG" -i network-wireless "Wi-Fi" "$1"
    elif [ "$(gui_tool)" = kdialog ]; then
        kdialog --title "Wi-Fi" --passivepopup "$1" 8
    elif [ "$(gui_tool)" = zenity ]; then
        zenity --notification --text="$1"
    else
        echo "$1"
    fi
}

gui_summary() {
    local conn reason
    if reason=$(user_paused); then
        say 'Watchdog paused: %s' "$reason"
    elif wifi_ok; then
        conn=$(nmcli -g GENERAL.CONNECTION device show "$IFACE" 2>/dev/null)
        say 'Wi-Fi connected to "%s". Watchdog active.' "$conn"
    else
        say 'Wi-Fi not connected. The watchdog will try to recover it.'
    fi
}

gui_status() {
    local tmp tool
    tool=$(gui_tool)
    tmp=$(mktemp)
    cmd_status > "$tmp" 2>&1
    case "$tool" in
        kdialog) kdialog --title "$(gettext 'Wi-Fi status')" --textbox "$tmp" 900 450 ;;
        zenity)  zenity --text-info --title="$(gettext 'Wi-Fi status')" --filename="$tmp" --width=900 --height=450 ;;
        *)       cat "$tmp" ;;
    esac
    rm -f "$tmp"
}

gui_off() {
    if ( cmd_off ) >/dev/null 2>&1; then
        notify "$(gettext 'Wi-Fi turned off. It will stay off until you turn it on again.')"
    else
        notify "$(gettext 'Could not turn the Wi-Fi off.')"
    fi
}

gui_on() {
    notify "$(gettext 'Turning the Wi-Fi on and connecting...')"
    if ( cmd_on ) >/dev/null 2>&1; then
        notify "$(say 'Wi-Fi connected to "%s".' "$(nmcli -g GENERAL.CONNECTION device show "$IFACE" 2>/dev/null)")"
    else
        notify "$(gettext 'The Wi-Fi is on but not connected yet. The watchdog will keep trying.')"
    fi
}

gui_recover() {
    local rc
    if user_paused >/dev/null; then
        notify "$(gettext 'The Wi-Fi is paused. Use "Turn Wi-Fi on" instead.')"
        return 1
    fi
    notify "$(gettext 'Recovering the Wi-Fi. This may take up to a minute...')"
    pkexec "$SELF" check --force >/dev/null 2>&1
    rc=$?
    case "$rc" in
        0)       notify "$(gettext 'Wi-Fi recovered.')" ;;
        126|127) notify "$(gettext 'Recovery cancelled: administrator authorization is required.')" ;;
        *)       notify "$(gettext 'Could not recover the Wi-Fi. Unplug the adapter and plug it in again.')" ;;
    esac
    return "$rc"
}

gui_menu() {
    local tool choice summary
    tool=$(gui_tool)
    summary=$(gui_summary)
    case "$tool" in
        kdialog)
            choice=$(kdialog --title "$PROG" --radiolist "$summary" \
                status  "$(gettext 'Show status and latest events')" on \
                off     "$(gettext 'Turn Wi-Fi off')" off \
                on      "$(gettext 'Turn Wi-Fi on')" off \
                recover "$(gettext 'Recover now (asks for the password)')" off) || return 0 ;;
        zenity)
            choice=$(zenity --list --radiolist --title="$PROG" --text="$summary" \
                --column="" --column=id --column="$(gettext 'Action')" --hide-column=2 \
                --width=420 --height=300 \
                TRUE  status  "$(gettext 'Show status and latest events')" \
                FALSE off     "$(gettext 'Turn Wi-Fi off')" \
                FALSE on      "$(gettext 'Turn Wi-Fi on')" \
                FALSE recover "$(gettext 'Recover now (asks for the password)')") || return 0 ;;
        *)
            err 'No graphical session or dialog tool (kdialog or zenity) available.'
            return 1 ;;
    esac
    [ -n "$choice" ] && cmd_gui_action "$choice"
}

cmd_gui_action() {
    case "$1" in
        status)  gui_status ;;
        off)     gui_off ;;
        on)      gui_on ;;
        recover) gui_recover ;;
    esac
}

cmd_gui() {
    if [ -n "$GUI_ACTION" ]; then
        cmd_gui_action "$GUI_ACTION"
    else
        gui_menu
    fi
}

case "$CMD" in
    check)      cmd_check ;;
    status)     cmd_status ;;
    disconnect) cmd_disconnect ;;
    off)        cmd_off ;;
    on)         cmd_on ;;
    test)       cmd_test ;;
    gui)        cmd_gui ;;
esac
