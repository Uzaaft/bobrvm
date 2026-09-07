#!/bin/sh
# Invoked by the app with administrator authorization, or manually with sudo.
set -eu
[ "$(/usr/bin/id -u)" = 0 ] || { echo 'Administrator authorization is required.' >&2; exit 1; }
label=as.polymath.bobrvm.network
binary=/Library/PrivilegedHelperTools/as.polymath.bobrvm.network
plist=/Library/LaunchDaemons/as.polymath.bobrvm.network.plist
runtime=/var/run/bobrvm-network
case "${1:-}" in
    install)
        [ "$#" = 3 ] || exit 1
        case "$3" in ''|*[!0-9]*) exit 1;; esac
        [ "$3" -ge 501 ] && [ "$3" -le 2147483647 ] || exit 1
        [ -f "$2" ] && [ ! -L "$2" ] || exit 1
        # These parents and all installed files must remain root-controlled.
        for directory in /Library/PrivilegedHelperTools /Library/LaunchDaemons; do
            [ ! -L "$directory" ] || exit 1
            /usr/bin/install -d -o root -g wheel -m 755 "$directory"
        done
        [ ! -L "$binary" ] && [ ! -L "$plist" ] && [ ! -L "$runtime" ] || exit 1
        /bin/launchctl bootout "system/$label" 2>/dev/null || true
        /usr/bin/install -o root -g wheel -m 755 "$2" "$binary"
        /usr/bin/install -d -o root -g wheel -m 755 "$runtime"
        /bin/rm -f "$runtime/control.sock"
        # Same-directory temporary file avoids exposing a partially written plist.
        temporary=$(/usr/bin/mktemp /Library/LaunchDaemons/.bobrvm-network.XXXXXX)
        trap '/bin/rm -f "$temporary"' EXIT HUP INT TERM
        /bin/cat > "$temporary" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key><array><string>$binary</string><string>$3</string></array>
    <key>StandardErrorPath</key><string>/var/log/bobrvm-network.log</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>5</integer>
    <key>Umask</key><integer>18</integer>
</dict></plist>
PLIST
        /usr/sbin/chown root:wheel "$temporary"
        /bin/chmod 644 "$temporary"
        /usr/bin/plutil -lint "$temporary" >/dev/null
        /bin/mv -f "$temporary" "$plist"
        /bin/launchctl bootstrap system "$plist"
        ;;
    remove)
        [ "$#" = 1 ] || exit 1
        /bin/launchctl bootout "system/$label" 2>/dev/null || true
        /bin/rm -f "$plist" "$binary" "$runtime/control.sock"
        /bin/rmdir "$runtime" 2>/dev/null || true
        ;;
    *) echo 'Usage: manage-network-helper.sh install HELPER USER_ID | remove' >&2; exit 1;;
esac
