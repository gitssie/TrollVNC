#!/bin/sh
set -eu
helper=/var/jb/usr/libexec/trollvnc/app-state-idfv-worker
rule=/var/jb/etc/sudoers.d/trollvnc-app-state
case "${1:-install}" in
    remove) rm -f "$rule"; exit 0 ;;
    install) ;;
    *) exit 64 ;;
esac
fail() {
    printf 'TrollVNC app-state: %s\n' "$*" >&2
    exit 1
}
[ -x "$helper" ] || fail "missing executable helper: $helper"
[ -x /var/jb/usr/sbin/visudo ] || fail "missing /var/jb/usr/sbin/visudo; install the sudo package"
step="set helper ownership and permissions"
trap 'status=$?; if [ "$status" -ne 0 ]; then printf "TrollVNC app-state: failed to %s (exit %s)\n" "$step" "$status" >&2; fi' EXIT
chown root:wheel /var/jb/usr/libexec/trollvnc "$helper"
chmod 755 /var/jb/usr/libexec/trollvnc "$helper"
step="resolve the helper path"
native="$helper"
case "$native" in /*) ;; *) fail "helper path is not absolute" ;; esac
case "$native" in *[!a-zA-Z0-9/._-]*) fail "helper path contains unsupported characters" ;; esac
step="create the sudoers rule"
mkdir -p /var/jb/etc/sudoers.d
temp=$(mktemp /var/jb/etc/sudoers.d/.trollvnc-app-state.XXXXXX)
trap 'status=$?; rm -f "$temp"; if [ "$status" -ne 0 ]; then printf "TrollVNC app-state: failed to %s (exit %s)\n" "$step" "$status" >&2; fi' EXIT
trap 'exit 1' HUP INT TERM
printf 'mobile ALL=(root) NOPASSWD: %s\n' "$native" > "$temp"
chown root:wheel "$temp"
chmod 440 "$temp"
# Procursus visudo on the tested Dopamine 3 bootstrap does not include the
# sudo-private library directory in its rpaths. Scope this lookup to visudo;
# Dopamine handles executable trust without manual library trust insertion.
step="locate the sudo utility library"
libraries=/var/jb/usr/libexec/sudo
[ -f "$libraries/libsudo_util.0.dylib" ] || fail "missing sudo utility library; reinstall the sudo package"
step="validate the sudoers rule with visudo"
DYLD_LIBRARY_PATH="$libraries" /var/jb/usr/sbin/visudo -cf "$temp"
step="install the sudoers rule"
mv -f "$temp" "$rule"
trap - EXIT HUP INT TERM
