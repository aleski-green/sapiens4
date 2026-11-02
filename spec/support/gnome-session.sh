#!/bin/sh
set -eu

if [ "$#" -eq 0 ]; then echo 'Usage: gnome-session.sh COMMAND [ARGUMENTS...]' >&2; exit 64; fi
scale=${SAPIENS_TEST_SCALE:-1}
case $scale in 1|2) ;; *) echo 'Fixture scale must be 1 or 2' >&2; exit 64 ;; esac
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
logs=${SAPIENS_TEST_GNOME_LOGS:-$root/.build/gnome}
mkdir -p "$logs"
if [ "${1:-}" != --session ]; then
    if [ "${SAPIENS_TEST_VISIBLE:-}" = 1 ]; then
        : "${DISPLAY:?A parent X display is required for visible GNOME}"
        if [ "${SAPIENS_TEST_HEADLESS:-}" = 1 ] || [ "${SAPIENS_TEST_VIRTUAL_DISPLAY:-}" = 1 ]; then
            echo 'Visible GNOME cannot use a headless or virtual-display backend' >&2
            exit 64
        fi
    fi
    if [ "${SAPIENS_TEST_XORG:-}" != 1 ] && [ "${SAPIENS_TEST_VIRTUAL_DISPLAY:-}" != 1 ] && [ "${SAPIENS_TEST_HEADLESS:-}" != 1 ]; then : "${DISPLAY:?A parent X display is required for nested GNOME}"; fi
    temporary=$(mktemp -d)
    cleanup_directory() {
        attempt=0
        until rm -rf "$temporary" 2>/dev/null; do
            attempt=$((attempt + 1))
            [ "$attempt" -lt 20 ] || return 1
            sleep 0.1
        done
    }
    trap cleanup_directory EXIT
    export XDG_RUNTIME_DIR=$temporary/runtime XDG_CONFIG_HOME=$temporary/config
    export XDG_DATA_HOME=$temporary/data XDG_CACHE_HOME=$temporary/cache
    mkdir -p "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME/gnome-shell/modes" "$XDG_CACHE_HOME"
    chmod 700 "$XDG_RUNTIME_DIR"
    overview=false
    if [ "${SAPIENS_TEST_OVERVIEW:-}" = 1 ]; then overview=true; fi
    printf '{"parentMode":"user","hasOverview":%s}\n' "$overview" > "$XDG_DATA_HOME/gnome-shell/modes/sapiens-test.json"
    export XDG_DATA_DIRS=$XDG_DATA_HOME:/usr/local/share:/usr/share
    export XDG_CURRENT_DESKTOP=GNOME XDG_SESSION_TYPE=wayland GSETTINGS_BACKEND=keyfile
    if [ "${SAPIENS_TEST_XORG:-}" = 1 ]; then export XDG_SESSION_TYPE=x11; fi
    export LIBGL_ALWAYS_SOFTWARE=1
    if [ "${SAPIENS_TEST_LINUX_EXTERNAL_DESKTOP:-}" = 1 ]; then
        gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us')]"
        gsettings set org.gnome.desktop.input-sources xkb-options '[]'
    fi
    if [ "${SAPIENS_TEST_GNOME_FOREGROUND:-}" = 1 ]; then
        sh "$root/submodules/blindly4/linux/gnome/install.sh" --accept-foreground-verification
        gsettings set org.gnome.shell enabled-extensions "['foreground@blindly4.sapiens4']"
    fi
    if [ "${SAPIENS_TEST_LOCKDOWN:-}" = 1 ]; then
        mkdir -p "$temporary/policy/locks"
        printf '%s\n' '[org/gnome/shell]' "enabled-extensions=['foreground@blindly4.sapiens4']" \
            'disable-user-extensions=true' 'allow-extension-installation=false' > "$temporary/policy/extensions"
        printf '%s\n' '/org/gnome/shell/disable-user-extensions' '/org/gnome/shell/enabled-extensions' \
            '/org/gnome/shell/allow-extension-installation' > "$temporary/policy/locks/extensions"
        dconf compile "$temporary/policy.db" "$temporary/policy"
        export GSETTINGS_BACKEND=dconf DCONF_PROFILE=$temporary/dconf-profile
        printf '%s\n' 'user-db:user' "file-db:$temporary/policy.db" > "$DCONF_PROFILE"
    fi
    unset AT_SPI_BUS_ADDRESS
    dbus-run-session -- "$0" --session "$@"
    exit
fi
shift

system_bus_pid= display_pid= pipewire_pid= shell_pid=
cleanup() {
    if mountpoint -q "$XDG_RUNTIME_DIR/doc"; then fusermount3 -u "$XDG_RUNTIME_DIR/doc" || true; fi
    for pid in "$shell_pid" "$pipewire_pid" "$system_bus_pid" "$display_pid"; do
        if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
    done
    for pid in "$shell_pid" "$pipewire_pid" "$display_pid"; do
        if [ -n "$pid" ]; then wait "$pid" 2>/dev/null || true; fi
    done
}
trap cleanup EXIT
# WSLg has no system bus; give this fixture its own unprivileged bus.
dbus-daemon --session --fork --print-address=1 --print-pid=1 > "$XDG_RUNTIME_DIR/system-bus"
DBUS_SYSTEM_BUS_ADDRESS=$(sed -n '1p' "$XDG_RUNTIME_DIR/system-bus")
system_bus_pid=$(sed -n '2p' "$XDG_RUNTIME_DIR/system-bus")
export DBUS_SYSTEM_BUS_ADDRESS
if [ "$XDG_SESSION_TYPE" = x11 ] || [ "${SAPIENS_TEST_VIRTUAL_DISPLAY:-}" = 1 ] || [ "${SAPIENS_TEST_VISIBLE:-}" = 1 ]; then
    if [ "${SAPIENS_TEST_VISIBLE:-}" = 1 ]; then
        Xephyr -displayfd 3 -screen "$((1440 * scale))x$((960 * scale))" -noreset -nolisten tcp -nolisten unix \
            -title 'Sapiens4 GUI tests — Ubuntu GNOME' 3> "$XDG_RUNTIME_DIR/display" > "$logs/xephyr.log" 2>&1 &
    else
        Xvfb -displayfd 3 -screen 0 "$((1440 * scale))x$((960 * scale))x24" -nolisten tcp -nolisten unix 3> "$XDG_RUNTIME_DIR/display" > "$logs/xvfb.log" 2>&1 &
    fi
    display_pid=$!
    attempt=0
    until [ -s "$XDG_RUNTIME_DIR/display" ]; do
        kill -0 "$display_pid"
        attempt=$((attempt + 1))
        [ "$attempt" -lt 15 ] || exit 1
        sleep 1
    done
    export DISPLAY=:$(cat "$XDG_RUNTIME_DIR/display")
fi
if [ "$XDG_SESSION_TYPE" = x11 ]; then
    export GDK_BACKEND=x11
    unset WAYLAND_DISPLAY
    set -- --xorg "$@"
else
    export WAYLAND_DISPLAY=sapiens-test GDK_BACKEND=wayland
fi
dbus-update-activation-environment XDG_RUNTIME_DIR XDG_CONFIG_HOME XDG_DATA_HOME XDG_DATA_DIRS XDG_CACHE_HOME XDG_CURRENT_DESKTOP XDG_SESSION_TYPE GSETTINGS_BACKEND LIBGL_ALWAYS_SOFTWARE DBUS_SYSTEM_BUS_ADDRESS DISPLAY GDK_BACKEND
if [ -n "${DCONF_PROFILE:-}" ]; then dbus-update-activation-environment DCONF_PROFILE; fi
if [ "$XDG_SESSION_TYPE" = wayland ]; then dbus-update-activation-environment WAYLAND_DISPLAY; fi
pipewire > "$logs/pipewire.log" 2>&1 &
pipewire_pid=$!
if [ "$1" = --xorg ]; then
    shift
    gnome-shell --mode=sapiens-test --x11 > "$logs/shell.log" 2>&1 &
elif [ "${SAPIENS_TEST_HEADLESS:-}" = 1 ]; then
    gnome-shell --mode=sapiens-test --headless --virtual-monitor="$((1440 * scale))x$((960 * scale))" --wayland --no-x11 --wayland-display=sapiens-test > "$logs/shell.log" 2>&1 &
else
    export SAPIENS_TEST_NESTED=1
    gnome-shell --mode=sapiens-test --nested --wayland --no-x11 --wayland-display=sapiens-test > "$logs/shell.log" 2>&1 &
fi
shell_pid=$!
attempt=0
until gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner org.gnome.Shell | grep -q true; do
    kill -0 "$shell_pid"
    attempt=$((attempt + 1))
    [ "$attempt" -lt 15 ] || exit 1
    sleep 1
done
if [ "${SAPIENS_TEST_HEADLESS:-}" = 1 ] && [ "$scale" != 1 ]; then
    python3 - "$scale" <<'PY'
import sys
from gi.repository import Gio, GLib

display = Gio.DBusProxy.new_for_bus_sync(Gio.BusType.SESSION, Gio.DBusProxyFlags.NONE, None,
    'org.gnome.Mutter.DisplayConfig', '/org/gnome/Mutter/DisplayConfig', 'org.gnome.Mutter.DisplayConfig', None)
serial, monitors, _, properties = display.call_sync('GetCurrentState', None, Gio.DBusCallFlags.NONE, 5000, None).unpack()
if len(monitors) != 1 or properties.get('layout-mode') != 2:
    raise SystemExit('The scaling fixture requires one virtual monitor in physical layout mode')
identity, modes, _ = monitors[0]
mode = next(mode for mode in modes if mode[-1].get('is-current'))
configuration = GLib.Variant('(uua(iiduba(ssa{sv}))a{sv})',
    (serial, 1, [(0, 0, float(sys.argv[1]), 0, True, [(identity[0], mode[0], {})])], {}))
display.call_sync('ApplyMonitorsConfig', configuration, Gio.DBusCallFlags.NONE, 5000, None)
PY
fi
if [ "$XDG_SESSION_TYPE" = wayland ]; then unset DISPLAY; fi
export SAPIENS_TEST_LINUX_DESKTOP=1
"$@"
