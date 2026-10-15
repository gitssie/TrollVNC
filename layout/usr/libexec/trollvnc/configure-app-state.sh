#!/bin/sh
set -eu
helper=/usr/libexec/trollvnc/app-state-idfv-worker
rule=/etc/sudoers.d/trollvnc-app-state
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
[ -x /usr/bin/jbroot ] || fail "missing RootHide path resolver: /usr/bin/jbroot"
[ -x /usr/sbin/visudo ] || fail "missing /usr/sbin/visudo; install the sudo package"
step="set helper ownership and permissions"
trap 'status=$?; if [ "$status" -ne 0 ]; then printf "TrollVNC app-state: failed to %s (exit %s)\n" "$step" "$status" >&2; fi' EXIT
chown root:wheel /usr/libexec/trollvnc "$helper"
chmod 755 /usr/libexec/trollvnc "$helper"
step="resolve the native helper path"
native=$(/usr/bin/jbroot "$helper")
case "$native" in /*) ;; *) fail "helper path is not absolute" ;; esac
case "$native" in *[!a-zA-Z0-9/._-]*) fail "helper path contains unsupported characters" ;; esac
step="create the sudoers rule"
mkdir -p /etc/sudoers.d
temp=$(mktemp /etc/sudoers.d/.trollvnc-app-state.XXXXXX)
trap 'status=$?; rm -f "$temp"; if [ "$status" -ne 0 ]; then printf "TrollVNC app-state: failed to %s (exit %s)\n" "$step" "$status" >&2; fi' EXIT
trap 'exit 1' HUP INT TERM
printf 'mobile ALL=(root) NOPASSWD: %s\n' "$native" > "$temp"
chown root:wheel "$temp"
chmod 440 "$temp"
step="resolve the sudo library path"
libraries=$(/usr/bin/jbroot /usr/libexec/sudo)
case "$libraries" in /*) ;; *) fail "sudo library path is not absolute" ;; esac
# The library supplied through DYLD_LIBRARY_PATH is outside visudo's embedded
# rpath. RootHide's executable dependency walk may therefore miss its trust
# registration. Register the existing library before dyld tries to load it.
step="prepare RootHide trust for the sudo utility library"
sudo_library="$libraries/libsudo_util.0.dylib"
[ -f "$sudo_library" ] || fail "missing sudo utility library; reinstall the sudo package"
[ -x /basebin/jbctl ] || fail "missing RootHide trust tool: /basebin/jbctl"
/basebin/jbctl trustcache add "$sudo_library"
step="validate the sudoers rule with visudo"
/usr/bin/env "DYLD_LIBRARY_PATH=$libraries" /usr/sbin/visudo -cf "$temp"
step="install the sudoers rule"
mv -f "$temp" "$rule"
trap - EXIT HUP INT TERM
