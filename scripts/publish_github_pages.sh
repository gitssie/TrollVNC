#!/bin/sh

set -eu
umask 077

export GIT_TERMINAL_PROMPT=0
export GCM_INTERACTIVE=Never
export GIT_ASKPASS=true
export SSH_ASKPASS=true
GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes -o StrictHostKeyChecking=yes"
export GIT_SSH_COMMAND

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
source_url=https://gitssie.github.io/TrollVNC
remote_name=origin
branch=gh-pages
dry_run=0
command_name=""
temporary=""

usage() {
    cat <<'EOF'
Usage: scripts/publish_github_pages.sh [--dry-run] publish

Build a fresh Dopamine RootHide package, validate a complete Sileo repository
and website, then commit and push an isolated gh-pages branch without force.

The first publication requires GitHub Pages to be set to gh-pages /(root).
EOF
}

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

cleanup() {
    [ -n "$temporary" ] || return 0
    case "$temporary" in
        "$root/.deploy/tmp/github-pages."*) rm -rf -- "$temporary" ;;
        *) printf 'error: refusing cleanup outside TrollVNC/.deploy/tmp\n' >&2 ;;
    esac
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) dry_run=1; shift ;;
        -h|--help) usage; exit 0 ;;
        publish) command_name=publish; shift; [ "$#" -eq 0 ] || fail "unexpected argument"; break ;;
        *) fail "unknown option or command: $1" ;;
    esac
done
[ "$command_name" = publish ] || fail "the publish command is required"

for command in git python3 make mktemp cp awk; do
    command -v "$command" >/dev/null 2>&1 || fail "required command is unavailable: $command"
done
[ -f "$root/pages/index.html" ] || fail "pages/index.html is missing"
[ -f "$root/pages/depiction.json" ] || fail "pages/depiction.json is missing"
[ -f "$root/scripts/render_github_pages.py" ] || fail "renderer is missing"

remote_url=$(git -C "$root" remote get-url "$remote_name") || fail "origin remote is missing"
[ "$remote_url" = git@github.com:gitssie/TrollVNC.git ] ||
    fail "origin must be git@github.com:gitssie/TrollVNC.git"

assert_main() {
    current_branch=$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    [ "$current_branch" = main ] || fail "publish from main only"
    [ -z "$(git -C "$root" status --porcelain --untracked-files=normal)" ] ||
        fail "main worktree must be clean"
    local_sha=$(git -C "$root" rev-parse HEAD)
    remote_line=$(git ls-remote --heads "$remote_url" refs/heads/main) ||
        fail "could not read remote main"
    remote_sha=$(printf '%s\n' "$remote_line" | awk 'NR == 1 {print $1}')
    [ -n "$remote_sha" ] || fail "remote main is missing"
    [ "$local_sha" = "$remote_sha" ] || fail "local main must match remote main"
}

assert_main
release_head=$local_sha

if [ -z "${THEOS:-}" ]; then
    THEOS=$(CDPATH= cd -- "$root/../../theos-roothide" 2>/dev/null && pwd -P) ||
        fail "set THEOS to the RootHide Theos checkout"
fi
export THEOS
[ -f "$THEOS/makefiles/common.mk" ] || fail "THEOS has no makefiles/common.mk"

package_id=$(awk -F': ' '$1 == "Package" {print $2}' "$root/layout/DEBIAN/control")
version=$(awk '$1 == "export" && $2 == "PACKAGE_VERSION" && $3 == ":=" {print $4}' "$root/Makefile")
[ -n "$package_id" ] && [ -n "$version" ] || fail "package identity is missing"
case "$package_id:$version" in
    *[!A-Za-z0-9.+:~_-]*) fail "package identity contains unsafe characters" ;;
esac
package="$root/packages/${package_id}_${version}_iphoneos-arm64e.deb"
[ ! -L "$package" ] || fail "expected package path must not be a symlink"
rm -f -- "$package"
make -C "$root" clean package THEOS_PACKAGE_SCHEME=roothide THEBOOTSTRAP= THEOS_DEVICE_SIMULATOR=
[ -f "$package" ] && [ ! -L "$package" ] || fail "fresh RootHide package was not produced"

mkdir -p "$root/.deploy/tmp"
temporary=$(mktemp -d "$root/.deploy/tmp/github-pages.XXXXXX")
site="$temporary/site"
repository="$temporary/git"
metadata="$temporary/metadata"
mkdir -p "$site" "$repository"
python3 "$root/scripts/render_github_pages.py" --package "$package" --output "$site" > "$metadata"
published_version=$(awk -F= '$1 == "version" {print $2}' "$metadata")
published_sha256=$(awk -F= '$1 == "sha256" {print $2}' "$metadata")
[ -n "$published_version" ] && [ -n "$published_sha256" ] || fail "renderer did not report package metadata"

assert_main
[ "$local_sha" = "$release_head" ] || fail "main changed while building"

git -C "$repository" init --quiet
git -C "$repository" remote add "$remote_name" "$remote_url"
remote_pages=$(git ls-remote --heads "$remote_url" "refs/heads/$branch") ||
    fail "could not inspect remote gh-pages"
if [ -n "$remote_pages" ]; then
    git -C "$repository" fetch --quiet --depth=1 "$remote_name" "$branch"
    git -C "$repository" checkout --quiet -B "$branch" FETCH_HEAD
    old_packages="$repository/Packages"
    [ -f "$old_packages" ] || fail "existing gh-pages has no Packages index"
    old_version=$(awk -F': ' '$1 == "Version" {print $2}' "$old_packages")
    old_sha256=$(awk -F': ' '$1 == "SHA256" {print $2}' "$old_packages")
    [ -n "$old_version" ] && [ -n "$old_sha256" ] ||
        fail "existing gh-pages package metadata is incomplete"
    if [ "$old_version" = "$published_version" ]; then
        [ "$old_sha256" = "$published_sha256" ] ||
            fail "version $published_version is already published with different bytes; bump PACKAGE_VERSION"
        if cmp -s "$repository/Packages" "$site/Packages" &&
           cmp -s "$repository/Packages.gz" "$site/Packages.gz" &&
           cmp -s "$repository/Packages.xz" "$site/Packages.xz"; then
            cp -f "$repository/Release" "$site/Release"
        fi
    fi
else
    git -C "$repository" checkout --quiet --orphan "$branch"
fi

if [ "$dry_run" -eq 1 ]; then
    printf 'validated_version=%s\nvalidated_sha256=%s\nsource_url=%s\n' \
        "$published_version" "$published_sha256" "$source_url"
    printf 'dry-run: would publish to origin/%s\n' "$branch"
    exit 0
fi

cp -Rf "$site/." "$repository/"
git -C "$repository" add --all

assert_main
[ "$local_sha" = "$release_head" ] || fail "main changed while preparing publication"
if git -C "$repository" diff --cached --quiet; then
    printf 'already_published_version=%s\nsource_url=%s\n' "$published_version" "$source_url"
    exit 0
fi

git_name=$(git -C "$root" config user.name || true)
git_email=$(git -C "$root" config user.email || true)
[ -n "$git_name" ] && [ -n "$git_email" ] || fail "Git user name and email must be configured"
git -C "$repository" -c "user.name=$git_name" -c "user.email=$git_email" \
    commit --quiet -m "repo: publish TrollVNC $published_version"

assert_main
[ "$local_sha" = "$release_head" ] || fail "main changed before push"
git -C "$repository" push "$remote_name" "HEAD:refs/heads/$branch"
printf 'published_version=%s\npublished_sha256=%s\npublished_branch=%s\nsource_url=%s\nsileo_url=sileo://source/%s\n' \
    "$published_version" "$published_sha256" "$branch" "$source_url" "$source_url"
