# eduwifi-watchdog

A small watchdog for Linux machines whose Wi-Fi adapter occasionally hangs and never comes back
until it is physically unplugged. It runs every minute from a systemd timer, detects when the
connection is gone, and recovers it by escalating through increasingly drastic steps — so you
don't have to get up and replug the USB dongle.

It was written for a Realtek RTL88x2BU USB adapter (`0bda:b812`, kernel driver `rtw88_8822bu`),
but everything is configurable, so it should work with any adapter managed by NetworkManager.

## How it works

Each check (once per minute) considers the Wi-Fi healthy when the interface exists,
NetworkManager reports it as connected, and the default gateway answers a ping.

After `FAILS_NEEDED` consecutive failed checks (2 by default, i.e. about two minutes, so short
glitches are ignored), it escalates, re-checking after every step:

1. **Reconnect** to the configured networks, one by one, in priority order
   (`nmcli connection up`). With no networks configured, NetworkManager picks one.
2. **Reload the kernel module** (`modprobe -r` + `modprobe`). This is what usually fixes a hung
   driver.
3. **Software USB reset** of the adapter (via `/sys/bus/usb/devices/*/authorized`), the
   equivalent of unplugging and replugging it.

Module reloads and USB resets are rate-limited (`MAX_HARD_PER_HOUR`, 3 by default) so a truly
dead adapter can't cause an endless loop. Every action is logged to the systemd journal with the
tag `eduwifi-watchdog`.

The watchdog respects deliberate user actions: if the Wi-Fi radio is turned off, or the
interface was disconnected manually (which makes NetworkManager disable autoconnect for the
device), it stays quiet until you turn it back on.

## Requirements

- Linux with systemd and NetworkManager (`nmcli`)
- bash, iproute2 (`ip`), `ping`
- Root access for installing and for the recovery steps
- The Wi-Fi networks to watch saved in NetworkManager, available to all users and with the
  password stored by the system (see [Choosing the networks to watch](#choosing-the-networks-to-watch))

Tested on LliureX 23 (Ubuntu 22.04 based), kernel 6.8, NetworkManager 1.36.

## Installation

Clone this repository (or download it as a ZIP and extract it), then run the installer from its
folder:

```sh
cd eduwifi-watchdog
sudo ./install.sh
```

The installer requires root. It autodetects the Wi-Fi interface, its kernel module and its USB
ID and offers them as defaults (just press Enter to accept them). Then it lists the Wi-Fi networks
saved in NetworkManager and asks which ones to watch — see
[Choosing the networks to watch](#choosing-the-networks-to-watch) below, it is the most
important setting.

It then writes `/etc/eduwifi-watchdog.conf`, installs the script to
`/usr/local/sbin/eduwifi-watchdog.sh` (with an `eduwifi-watchdog` command in `/usr/local/bin`) and
enables `eduwifi-watchdog.timer`.

Running the installer again updates the installation and offers the current settings as
defaults.

## Choosing the networks to watch

The watchdog reconnects to the networks listed in `NETWORKS`, trying them **one by one, in the
order given**, and stops at the first one that works. Put your preferred network first, for
example the 5 GHz band of your router and then its 2.4 GHz band as a fallback.

### 1. Make sure each network is saved in NetworkManager

The watchdog does not store Wi-Fi passwords: it can only connect to networks that NetworkManager
already knows. Connect to each network once from the desktop or with `nmcli`.

Because the watchdog runs as root from a systemd timer, without your desktop session, the
password must be **available to all users and stored by the system**, not only in your personal
keyring. Otherwise the reconnection fails with a `no-secrets` error. In the NetworkManager GUI
this is the "All users may connect to this network" option plus "Store the password for all
users (not encrypted)". From a terminal:

```sh
nmcli connection modify "MyNetwork-5G" connection.permissions "" \
    802-11-wireless-security.psk-flags 0 802-11-wireless-security.psk "<password>"
```

Check it with `nmcli -g connection.permissions,802-11-wireless-security.psk-flags connection show "MyNetwork-5G"`:
an empty first line (all users) and `0` (stored by the system) mean it is ready.

### 2. Use the NetworkManager profile name, not necessarily the SSID

`NETWORKS` takes the **name of the connection profile**, which may differ from the SSID (for
example `MyNetwork 1`). List the exact names with:

```sh
nmcli -f NAME,TYPE connection show | grep wifi
```

### 3. Give them to the installer

When asked, type the names comma-separated, in priority order:

```
Wi-Fi networks saved in NetworkManager:
  - MyNetwork
  - MyNetwork-5G
Networks to retry, comma-separated, in priority order []: MyNetwork-5G,MyNetwork
```

Or pass them on the command line for a non-interactive install:

```sh
sudo ./install.sh --networks "MyNetwork-5G,MyNetwork"
```

The installer warns about any name that is not a saved NetworkManager profile. Leaving the list
empty lets NetworkManager choose the network by itself.

### 4. Change them later

Either run `sudo ./install.sh` again (it offers the current list as the default), or edit the
`NETWORKS=` line in `/etc/eduwifi-watchdog.conf`:

```sh
NETWORKS="MyNetwork-5G,MyNetwork,Office"
```

Changes take effect at the next check; nothing needs restarting. Check which networks are in use
with `eduwifi-watchdog status`.

## Configuration

Settings live in `/etc/eduwifi-watchdog.conf` (see `eduwifi-watchdog.conf.example`):

| Setting             | Default  | Meaning                                                                 |
|---------------------|----------|-------------------------------------------------------------------------|
| `IFACE`             | `wlan0`  | Wi-Fi interface to monitor                                              |
| `NETWORKS`          | (empty)  | NetworkManager profiles to retry, comma-separated, in priority order    |
| `MODULE`            | (empty)  | Kernel module to reload at level 2 (empty skips the level)              |
| `USB_ID`            | (empty)  | `vendor:product` of the USB adapter for level 3 (empty skips the level) |
| `FAILS_NEEDED`      | `2`      | Consecutive failed checks before acting                                 |
| `MAX_HARD_PER_HOUR` | `3`      | Max module reloads / USB resets per hour                                |
| `CONNECT_TIMEOUT`   | `30`     | Seconds to wait for each connection attempt                             |

Changes take effect at the next check; no restart is needed.

## Usage

All features are subcommands of the same script. The installer creates the `eduwifi-watchdog`
command (a symlink in `/usr/local/bin`), so they can be used from anywhere.

| Command                                | What it does                                                                                     | Root? |
|----------------------------------------|--------------------------------------------------------------------------------------------------|-------|
| `eduwifi-watchdog status`                 | Wi-Fi state, whether the watchdog is active or paused, the timer, the settings and the last 10 events | no    |
| `eduwifi-watchdog disconnect`             | Disconnects the Wi-Fi manually; the watchdog won't reconnect it                                  | no    |
| `eduwifi-watchdog off`                    | Turns the Wi-Fi radio off; it stays off even after a reboot                                      | no    |
| `eduwifi-watchdog on`                     | Turns the Wi-Fi on, re-enables autoconnect and connects to your networks in priority order       | no    |
| `sudo eduwifi-watchdog test`              | Automatic recovery test (see below)                                                              | yes   |
| `sudo eduwifi-watchdog` (or `check`)      | The check the timer runs every minute                                                            | yes   |
| `eduwifi-watchdog --help`                 | Shows all commands and options                                                                   | no    |

`check` also accepts `--dry-run` (report what would be done without changing anything) and
`--force` (skip straight to reloading the module).

### How the watchdog knows you disconnected on purpose

It keeps no state files of its own; it asks NetworkManager:

- If the Wi-Fi radio is off, it does nothing.
- If the interface has autoconnect disabled, it also stays quiet. This is what
  `nmcli device disconnect` does. Disconnecting from the desktop network applet probably does the
  same, but this has not been verified yet.

So it respects your disconnections even if you don't use `eduwifi-watchdog disconnect`.
`eduwifi-watchdog on` re-enables everything.

### Verifying that recovery really works

```sh
sudo eduwifi-watchdog test
```

The test:

1. Checks that the Wi-Fi works before starting.
2. Unloads the kernel module to simulate a driver hang.
3. Waits for the watchdog to recover it on its own, up to about 5 minutes with the default
   settings. If the timer is not active, it runs the recovery directly.
4. Reports whether the test passed, how many seconds it took and at which level it recovered.

If the test fails, it reloads the module and reconnects so you are not left offline.

### Logs

```sh
journalctl -t eduwifi-watchdog -f
```

## Testing

### Without root and without touching the connection

These checks are safe to run at any time; nothing is changed.

```sh
bash -n eduwifi-watchdog.sh && bash -n install.sh   # syntax check
./eduwifi-watchdog.sh --help                   # help is shown
./eduwifi-watchdog.sh status                   # status works as a normal user
./eduwifi-watchdog.sh --dry-run                # with working Wi-Fi: "Wi-Fi OK, nothing to do"
./eduwifi-watchdog.sh --dry-run --force        # simulates levels 2 and 3
./install.sh --help                         # installer help, no root needed
```

To simulate a failure and see the whole escalation without touching the real adapter, point the
script at a test configuration with a non-existent interface:

```sh
cat > /tmp/test.conf <<'EOF'
IFACE=wlan9
NETWORKS="NetA,Net B"
MODULE=rtw88_8822bu
USB_ID=0bda:b812
FAILS_NEEDED=1
EOF
EDUWIFI_WATCHDOG_CONF=/tmp/test.conf ./eduwifi-watchdog.sh --dry-run
journalctl -t eduwifi-watchdog --since "-1 min" -o cat
```

The log should show level 1 trying `NetA` and then `Net B` (in that order, spaces trimmed), then
level 2 (module reload) and level 3 (USB reset). The commands it would run are shown with a
`[dry-run]` prefix instead of being executed.

### On a real installation

These tests drop the Wi-Fi for a moment. Run them from a local terminal, not over a Wi-Fi SSH
session.

1. **Automatic recovery from a driver hang:**

   ```sh
   sudo eduwifi-watchdog test
   ```

   Expected: `Test passed: Wi-Fi recovered in Ns. Recovered at level 2 (module reload)`.

2. **Manual disconnection is respected:**

   ```sh
   eduwifi-watchdog disconnect
   sleep 150                 # longer than FAILS_NEEDED checks
   eduwifi-watchdog status      # expected: "Watchdog: PAUSED (wlan0 was disconnected manually)"
   eduwifi-watchdog on          # expected: "Wi-Fi connected: <network>"
   ```

3. **Radio off is respected:**

   ```sh
   eduwifi-watchdog off
   sleep 150
   eduwifi-watchdog status      # expected: "Watchdog: PAUSED (Wi-Fi radio is off)"
   eduwifi-watchdog on
   ```

4. **Network priority:** with two networks configured, run `eduwifi-watchdog disconnect` and then
   `eduwifi-watchdog on`; it should connect to the first network in `NETWORKS` if it is in range.

5. **Disconnecting from the desktop network applet** (not verified yet): disconnect from the
   applet, wait a few minutes and check `eduwifi-watchdog status`. If it reconnects by itself
   instead of showing `PAUSED`, please open an issue.

Follow what the watchdog does during any test with `journalctl -t eduwifi-watchdog -f`.

## Uninstallation

```sh
sudo ./install.sh --uninstall
```

This disables the timer and removes the script, the `eduwifi-watchdog` command and the systemd
units. `/etc/eduwifi-watchdog.conf` is kept; delete it manually if you no longer need it.

## Tip for Realtek rtw88 adapters

Many rtw88 hangs come from the firmware's power saving ("firmware failed to leave lps state" in
`dmesg`). Disabling it often prevents the hangs in the first place:

```sh
echo 'options rtw88_core disable_lps_deep=Y' | sudo tee /etc/modprobe.d/rtw88.conf
nmcli connection modify "<your network>" 802-11-wireless.powersave 2
sudo modprobe -r rtw88_8822bu rtw88_8822b rtw88_usb rtw88_core && sudo modprobe rtw88_8822bu
```

Adjust the module names to your chip (`lsmod | grep rtw88`).

## Contributing

Issues and pull requests are welcome, especially reports of other adapters and distributions
where it works (or doesn't).

## License

Released under the [MIT License](LICENSE). Copyright (c) 2026 Eduardo Millán.
