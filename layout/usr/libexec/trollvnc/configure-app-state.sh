#!/bin/sh
set -eu
helper=/usr/libexec/trollvnc/app-state-idfv-worker
rule=/etc/sudoers.d/trollvnc-app-state
case "${1:-install}" in
    remove) rm -f "$rule"; exit 0 ;;
    install) ;;
    *) exit 64 ;;
esac
[ -x "$helper" ] || exit 0
chown root:wheel /usr/libexec/trollvnc "$helper"
chmod 755 /usr/libexec/trollvnc "$helper"
native=$(/usr/bin/jbroot "$helper")
case "$native" in /*) ;; *) exit 1 ;; esac
case "$native" in *[!a-zA-Z0-9/._-]*) exit 1 ;; esac
mkdir -p /etc/sudoers.d
temp=$(mktemp /etc/sudoers.d/.trollvnc-app-state.XXXXXX)
trap 'rm -f "$temp"' EXIT HUP INT TERM
printf 'mobile ALL=(root) NOPASSWD: %s\n' "$native" > "$temp"
chown root:wheel "$temp"
chmod 440 "$temp"
libraries=$(/usr/bin/jbroot /usr/libexec/sudo)
/usr/bin/env "DYLD_LIBRARY_PATH=$libraries" /usr/sbin/visudo -cf "$temp"
mv -f "$temp" "$rule"
trap - EXIT HUP INT TERM
