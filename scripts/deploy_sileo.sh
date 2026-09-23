#!/bin/bash

set -Eeuo pipefail

umask 077

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
DEPLOY_ROOT="$PROJECT_ROOT/.deploy"
CONFIG_FILE="$DEPLOY_ROOT/deploy.env"
REPO_DIR="$DEPLOY_ROOT/repo"
STATE_DIR="$DEPLOY_ROOT/state"
LOG_DIR="$DEPLOY_ROOT/logs"
TMP_DIR="$DEPLOY_ROOT/tmp"
SSH_CONFIG="$STATE_DIR/ssh.conf"
SIGNATURE_FILE="$STATE_DIR/config.signature"
COMMAND=""
DRY_RUN=0
WORK_DIR=""
ROLLBACK_SERVICES=0
STARTED_HTTP=0
STARTED_TUNNEL=0
DRY_RUN_REPO_VALIDATED=0

usage() {
    cat <<'EOF'
Usage: scripts/deploy_sileo.sh [--dry-run] COMMAND

Commands:
  deploy   Validate the current arm64e package, publish it, start, and verify.
  start    Start or reuse the loopback HTTP server and SSH reverse tunnel.
  verify   Verify the local repository and the device-loopback endpoint.
  status   Report repository, HTTP server, tunnel, and endpoint health.
  stop     Stop only identity-verified deployment processes.

Options:
  --dry-run   Validate deploy/start/stop without starting or stopping services.
  -h, --help  Show this help.

Configuration is read only from .deploy/deploy.env. Copy
scripts/deploy.env.example there, chmod .deploy to 700, and chmod the file to
600. This script never adds a Sileo source and never installs TrollVNC.
EOF
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

config_fail() {
    printf 'error: %s\n' "$*" >&2
    printf 'setup: copy scripts/deploy.env.example to .deploy/deploy.env and restrict permissions\n' >&2
    exit 2
}

while (($#)); do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        deploy|start|verify|status|stop)
            COMMAND=$1
            shift
            break
            ;;
        *) fail "unknown option or command: $1 (use --help)" ;;
    esac
done

[[ -n "$COMMAND" ]] || fail "a command is required (use --help)"
(($# == 0)) || fail "unexpected argument after $COMMAND"
if ((DRY_RUN)) && [[ "$COMMAND" == verify || "$COMMAND" == status ]]; then
    fail "--dry-run is only valid with deploy, start, or stop"
fi

file_owner() {
    stat -f '%u' "$1" 2>/dev/null || stat -c '%u' "$1" 2>/dev/null
}

file_mode() {
    stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

require_private_permissions() {
    local description=$1 path=$2 mode
    mode=$(file_mode "$path") || config_fail "could not inspect $description permissions"
    [[ "$mode" =~ ^[0-7]+$ ]] || config_fail "$description has an invalid permission mode"
    [[ "$mode" != *[1-7][0-7] && "$mode" != *[0-7][1-7] ]] ||
        config_fail "$description must not grant group or other access"
}

require_private_file() {
    local description=$1 path=$2
    [[ ! -L "$path" && -f "$path" && -r "$path" ]] || config_fail "$description is missing, unreadable, or a symlink"
    [[ "$(file_owner "$path")" == "$(id -u)" ]] || config_fail "$description must be owned by the current user"
    require_private_permissions "$description" "$path"
}

SOURCE_URL=""
HTTP_PORT=""
DEVICE_PORT=""
SSH_HOST=""
SSH_PORT=""
SSH_USER=""
SSH_IDENTITY=""
PACKAGE_OVERRIDE=""

load_config() {
    local line assignment key raw value seen=" " line_number=0 length
    [[ ! -L "$DEPLOY_ROOT" && -d "$DEPLOY_ROOT" ]] || config_fail ".deploy is missing or a symlink"
    [[ "$(CDPATH= cd -- "$DEPLOY_ROOT" && pwd -P)" == "$DEPLOY_ROOT" ]] || config_fail ".deploy resolves outside TrollVNC"
    [[ "$(file_owner "$DEPLOY_ROOT")" == "$(id -u)" ]] || config_fail ".deploy must be owned by the current user"
    require_private_permissions .deploy "$DEPLOY_ROOT"
    require_private_file deploy.env "$CONFIG_FILE"

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))
        [[ "$line" != *$'\r'* ]] || config_fail "carriage returns are not supported on config line $line_number"
        [[ -z "$line" || "$line" == \#* ]] && continue
        assignment=${line#export }
        [[ "$assignment" == *=* ]] || config_fail "expected NAME=value on config line $line_number"
        key=${assignment%%=*}
        raw=${assignment#*=}
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || config_fail "invalid key on config line $line_number"
        [[ "$seen" != *" $key "* ]] || config_fail "duplicate config key on line $line_number"
        seen+="$key "

        length=${#raw}
        if [[ "$raw" == \"* ]]; then
            ((length >= 2)) && [[ "$raw" == *\" ]] || config_fail "unmatched quote on config line $line_number"
            value=${raw:1:length-2}
            [[ "$value" != *\"* ]] || config_fail "embedded quotes are not supported on config line $line_number"
        elif [[ "$raw" == \'* ]]; then
            ((length >= 2)) && [[ "$raw" == *\' ]] || config_fail "unmatched quote on config line $line_number"
            value=${raw:1:length-2}
            [[ "$value" != *\'* ]] || config_fail "embedded quotes are not supported on config line $line_number"
        else
            [[ ! "$raw" =~ [[:space:]] ]] || config_fail "unquoted whitespace on config line $line_number"
            value=$raw
        fi

        case "$key" in
            TROLLVNC_SILEO_SOURCE_URL) SOURCE_URL=$value ;;
            TROLLVNC_SILEO_HTTP_PORT) HTTP_PORT=$value ;;
            TROLLVNC_SILEO_DEVICE_PORT) DEVICE_PORT=$value ;;
            TROLLVNC_SILEO_SSH_HOST) SSH_HOST=$value ;;
            TROLLVNC_SILEO_SSH_PORT) SSH_PORT=$value ;;
            TROLLVNC_SILEO_SSH_USER) SSH_USER=$value ;;
            TROLLVNC_SILEO_SSH_IDENTITY) SSH_IDENTITY=$value ;;
            TROLLVNC_SILEO_PACKAGE) PACKAGE_OVERRIDE=$value ;;
            *) config_fail "unknown config key on line $line_number: $key" ;;
        esac
    done < "$CONFIG_FILE"
}

validate_port() {
    local name=$1 value=$2
    [[ "$value" =~ ^[0-9]+$ ]] && ((value >= 1 && value <= 65535)) ||
        config_fail "$name must be an integer from 1 through 65535"
}

validate_connection_config() {
    local name value
    while (($#)); do
        name=$1
        value=$2
        [[ -n "$value" ]] || config_fail "missing required configuration: $name"
        shift 2
    done
    validate_port TROLLVNC_SILEO_HTTP_PORT "$HTTP_PORT"
    validate_port TROLLVNC_SILEO_DEVICE_PORT "$DEVICE_PORT"
    validate_port TROLLVNC_SILEO_SSH_PORT "$SSH_PORT"
    [[ "$SSH_USER" == mobile ]] || config_fail "TROLLVNC_SILEO_SSH_USER must be mobile"
    [[ "$SSH_HOST" =~ ^[A-Za-z0-9._:-]+$ ]] || config_fail "TROLLVNC_SILEO_SSH_HOST contains unsupported characters"
    [[ "$SOURCE_URL" == "http://127.0.0.1:$DEVICE_PORT/" ]] ||
        config_fail "TROLLVNC_SILEO_SOURCE_URL must equal http://127.0.0.1:<device-port>/"
    [[ "$SSH_IDENTITY" == /* && "$SSH_IDENTITY" != *['"\\%']* ]] ||
        config_fail "TROLLVNC_SILEO_SSH_IDENTITY must be a safe absolute path"
    require_private_file "SSH identity" "$SSH_IDENTITY"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

require_common_commands() {
    local command
    for command in awk cmp ps shasum stat; do require_command "$command"; done
    command -v md5 >/dev/null 2>&1 || command -v md5sum >/dev/null 2>&1 ||
        fail "required command is unavailable: md5 or md5sum"
}

require_publish_commands() {
    local command
    for command in ar gzip tar xz; do require_command "$command"; done
}

require_runtime_commands() {
    local command
    for command in curl lsof nohup python3 ssh; do require_command "$command"; done
}

assert_managed_path() {
    [[ "$1" == "$DEPLOY_ROOT/"* && "$1" != *'/../'* && "$1" != */.. ]] ||
        fail "refusing to modify a path outside TrollVNC/.deploy"
}

remove_managed() {
    local path
    for path in "$@"; do assert_managed_path "$path"; done
    rm -rf -- "$@"
}

initialize_state() {
    local path
    for path in "$STATE_DIR" "$LOG_DIR" "$TMP_DIR"; do
        [[ ! -L "$path" ]] || fail "deployment state directories must not be symlinks"
    done
    mkdir -p "$STATE_DIR" "$LOG_DIR" "$TMP_DIR"
    chmod 700 "$DEPLOY_ROOT" "$STATE_DIR" "$LOG_DIR" "$TMP_DIR"
    for path in "$SSH_CONFIG" "$SIGNATURE_FILE" \
        "$STATE_DIR/http.process" "$STATE_DIR/tunnel.process" \
        "$LOG_DIR/http.log" "$LOG_DIR/tunnel.log"; do
        [[ ! -L "$path" ]] || fail "deployment state files must not be symlinks"
    done
}

process_start() {
    LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null | awk '{$1=$1; print}'
}

hash_text() {
    shasum -a 256 | awk '{print $1}'
}

process_hash() {
    ps -p "$1" -o command= 2>/dev/null | hash_text
}

process_state_file() {
    printf '%s/%s.process\n' "$STATE_DIR" "$1"
}

record_process() {
    local component=$1 pid=$2 marker=$3 state temp command hash previous="" start=""
    local stable=0 attempt=0
    state=$(process_state_file "$component")
    temp="$state.tmp.$$"
    while ((attempt < 30)); do
        start=$(process_start "$pid")
        command=$(ps -p "$pid" -o command= 2>/dev/null || true)
        hash=""
        [[ "$command" == *"$marker"* ]] && hash=$(printf '%s\n' "$command" | hash_text)
        if [[ -n "$hash" && "$hash" == "$previous" ]]; then
            stable=$((stable + 1))
        else
            stable=0
        fi
        [[ -n "$start" && $stable -ge 2 ]] && break
        previous=$hash
        kill -0 "$pid" 2>/dev/null || return 1
        sleep 0.1
        attempt=$((attempt + 1))
    done
    [[ -n "$start" && -n "$hash" && $stable -ge 2 ]] || return 1
    printf '%s\n%s\n%s\n' "$pid" "$start" "$hash" > "$temp"
    mv "$temp" "$state"
}

owned_pid() {
    local component=$1 state pid expected_start expected_hash
    state=$(process_state_file "$component")
    [[ -f "$state" && ! -L "$state" ]] || return 1
    pid=$(awk 'NR == 1 {print; exit}' "$state")
    expected_start=$(awk 'NR == 2 {print; exit}' "$state")
    expected_hash=$(awk 'NR == 3 {print; exit}' "$state")
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || return 1
    [[ "$(process_start "$pid")" == "$expected_start" ]] || return 1
    [[ "$(process_hash "$pid")" == "$expected_hash" ]] || return 1
    printf '%s\n' "$pid"
}

stop_process() {
    local component=$1 quiet=${2:-0} state pid attempt=0
    state=$(process_state_file "$component")
    if pid=$(owned_pid "$component" 2>/dev/null); then
        kill -TERM "$pid" 2>/dev/null || return 1
        wait "$pid" 2>/dev/null || true
        while kill -0 "$pid" 2>/dev/null && ((attempt < 100)); do
            sleep 0.1
            attempt=$((attempt + 1))
        done
        kill -0 "$pid" 2>/dev/null && return 1
        ((quiet)) || printf '%s=stopped\n' "$component"
    elif [[ -e "$state" ]]; then
        ((quiet)) || printf '%s=stale-state-cleared\n' "$component"
    else
        ((quiet)) || printf '%s=not-running\n' "$component"
    fi
    remove_managed "$state"
}

cleanup() {
    local result=$?
    trap - EXIT HUP INT TERM
    if ((result != 0 && ROLLBACK_SERVICES)); then
        ((STARTED_TUNNEL == 0)) || stop_process tunnel 1 >/dev/null 2>&1 || true
        ((STARTED_HTTP == 0)) || stop_process http 1 >/dev/null 2>&1 || true
    fi
    if [[ -n "$WORK_DIR" && -e "$WORK_DIR" ]]; then remove_managed "$WORK_DIR"; fi
    exit "$result"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

control_field() {
    local field=$1 file=$2
    awk -v requested="$field" '
        index($0, requested ":") == 1 {
            value = substr($0, length(requested) + 2)
            sub(/^[[:space:]]*/, "", value)
            count++
        }
        END { if (count != 1 || value == "") exit 1; print value }
    ' "$file"
}

EXPECTED_PACKAGE=""
EXPECTED_VERSION=""
EXPECTED_ARCH=""

load_source_identity() {
    local control="$PROJECT_ROOT/layout/DEBIAN/control" source_arch
    [[ -f "$control" && -f "$PROJECT_ROOT/Makefile" ]] || fail "source package metadata is missing"
    EXPECTED_PACKAGE=$(control_field Package "$control") || fail "source control has invalid Package metadata"
    source_arch=$(control_field Architecture "$control") || fail "source control has invalid Architecture metadata"
    [[ "$source_arch" == iphoneos-arm ]] || fail "source control Architecture must be iphoneos-arm"
    EXPECTED_ARCH="${source_arch}64e"
    EXPECTED_VERSION=$(awk '
        $1 == "export" && $2 == "PACKAGE_VERSION" && $3 == ":=" && NF == 4 {
            value = $4; count++
        }
        END { if (count != 1 || value == "") exit 1; print value }
    ' "$PROJECT_ROOT/Makefile") || fail "Makefile has invalid PACKAGE_VERSION metadata"
    [[ "$EXPECTED_PACKAGE:$EXPECTED_VERSION" =~ ^[A-Za-z0-9.+:~_-]+$ ]] ||
        fail "source package identity contains unsupported characters"
}

SELECTED_PACKAGE=""
SELECTED_BASENAME=""
PACKAGE_CONTROL=""

select_package() {
    local packages_dir candidate parent
    packages_dir=$(CDPATH= cd -- "$PROJECT_ROOT/packages" && pwd -P) || fail "packages directory is missing"
    if [[ -n "$PACKAGE_OVERRIDE" ]]; then
        [[ "$PACKAGE_OVERRIDE" == /* ]] || config_fail "TROLLVNC_SILEO_PACKAGE must be an absolute path"
        candidate=$PACKAGE_OVERRIDE
    else
        candidate="$packages_dir/${EXPECTED_PACKAGE}_${EXPECTED_VERSION}_${EXPECTED_ARCH}.deb"
    fi
    [[ ! -L "$candidate" && -f "$candidate" && -r "$candidate" ]] || fail "current arm64e package is missing, unreadable, or a symlink"
    parent=$(CDPATH= cd -- "$(dirname -- "$candidate")" && pwd -P) || fail "selected package parent is unavailable"
    [[ "$parent" == "$packages_dir" ]] || fail "selected package must remain directly inside TrollVNC/packages"
    SELECTED_BASENAME=$(basename -- "$candidate")
    [[ "$SELECTED_BASENAME" == *.deb && "$SELECTED_BASENAME" != *..* &&
       "$SELECTED_BASENAME" =~ ^[A-Za-z0-9.+:~_-]+$ ]] || fail "selected package has an unsafe filename"
    SELECTED_PACKAGE="$parent/$SELECTED_BASENAME"
}

extract_package_control() {
    local package=$1 destination=$2 member archive plain
    member=$(ar -t "$package" | awk '/^control\.tar($|\.(gz|xz|lzma|bz2|zst)$)/ {print}') ||
        fail "could not inspect package control archive"
    [[ -n "$member" && "$member" != *$'\n'* ]] || fail "package control archive is missing or ambiguous"
    archive="$destination/$member"
    plain="$destination/control.tar"
    ar -p "$package" "$member" > "$archive" || fail "could not read package control archive"
    case "$member" in
        control.tar) cp "$archive" "$plain" ;;
        control.tar.gz) gzip -dc "$archive" > "$plain" ;;
        control.tar.xz) xz -dc "$archive" > "$plain" ;;
        control.tar.lzma) xz --format=lzma -dc "$archive" > "$plain" ;;
        control.tar.bz2) require_command bzip2; bzip2 -dc "$archive" > "$plain" ;;
        control.tar.zst) require_command zstd; zstd -q -d -c "$archive" > "$plain" ;;
        *) fail "package uses unsupported control archive compression" ;;
    esac
    PACKAGE_CONTROL="$destination/control"
    tar -xOf "$plain" ./control > "$PACKAGE_CONTROL" 2>/dev/null ||
        tar -xOf "$plain" control > "$PACKAGE_CONTROL" 2>/dev/null ||
        fail "package control metadata is missing"
    [[ -s "$PACKAGE_CONTROL" ]] || fail "package control metadata is empty"
}

validate_package_identity() {
    local field
    [[ "$(control_field Package "$PACKAGE_CONTROL")" == "$EXPECTED_PACKAGE" ]] || fail "package identifier does not match source control"
    [[ "$(control_field Version "$PACKAGE_CONTROL")" == "$EXPECTED_VERSION" ]] || fail "package version does not match Makefile PACKAGE_VERSION"
    [[ "$(control_field Architecture "$PACKAGE_CONTROL")" == "$EXPECTED_ARCH" ]] || fail "package architecture is not the source-derived arm64e architecture"
    for field in Filename Size MD5sum SHA1 SHA256; do
        ! awk -v requested="$field" 'index($0, requested ":") == 1 {found = 1} END {exit found ? 0 : 1}' "$PACKAGE_CONTROL" ||
            fail "package control unexpectedly contains repository field: $field"
    done
}

hash_file() {
    local algorithm=$1 path=$2
    case "$algorithm" in
        md5)
            if command -v md5 >/dev/null 2>&1; then md5 -q "$path"; else md5sum "$path" | awk '{print $1}'; fi
            ;;
        sha1) shasum -a 1 "$path" | awk '{print $1}' ;;
        sha256) shasum -a 256 "$path" | awk '{print $1}' ;;
        *) fail "unsupported hash algorithm: $algorithm" ;;
    esac
}

file_size() {
    wc -c < "$1" | awk '{$1=$1; print}'
}

release_has_entry() {
    local release=$1 section=$2 hash=$3 size=$4 name=$5
    awk -v section="$section" -v hash="$hash" -v size="$size" -v name="$name" '
        $0 == section ":" {active = 1; next}
        /^[A-Za-z0-9-]+:/ {active = 0}
        active && $1 == hash && $2 == size && $3 == name {found = 1}
        END {exit found ? 0 : 1}
    ' "$release"
}

validate_repository() {
    local repo=$1 name filename package size md5_hash sha1_hash sha256_hash algorithm section
    local -a packages
    [[ -d "$repo" && ! -L "$repo" && -d "$repo/pool" && ! -L "$repo/pool" ]] || return 1
    for name in Packages Packages.gz Packages.xz Release; do
        [[ -f "$repo/$name" && ! -L "$repo/$name" ]] || return 1
    done
    [[ "$(control_field Package "$repo/Packages")" == "$EXPECTED_PACKAGE" ]] || return 1
    [[ "$(control_field Version "$repo/Packages")" == "$EXPECTED_VERSION" ]] || return 1
    [[ "$(control_field Architecture "$repo/Packages")" == "$EXPECTED_ARCH" ]] || return 1
    filename=$(control_field Filename "$repo/Packages") || return 1
    [[ "$filename" == pool/*.deb && "$filename" != *..* && "$filename" =~ ^[A-Za-z0-9./+:~_-]+$ ]] || return 1
    package="$repo/$filename"
    packages=("$repo"/pool/*.deb)
    [[ ${#packages[@]} -eq 1 && "${packages[0]}" == "$package" && -f "$package" && ! -L "$package" ]] || return 1
    size=$(control_field Size "$repo/Packages") || return 1
    md5_hash=$(control_field MD5sum "$repo/Packages") || return 1
    sha1_hash=$(control_field SHA1 "$repo/Packages") || return 1
    sha256_hash=$(control_field SHA256 "$repo/Packages") || return 1
    [[ "$(file_size "$package")" == "$size" && "$(hash_file md5 "$package")" == "$md5_hash" &&
       "$(hash_file sha1 "$package")" == "$sha1_hash" && "$(hash_file sha256 "$package")" == "$sha256_hash" ]] || return 1
    cmp -s "$repo/Packages" <(gzip -dc "$repo/Packages.gz") || return 1
    cmp -s "$repo/Packages" <(xz -dc "$repo/Packages.xz") || return 1
    [[ "$(control_field Architectures "$repo/Release")" == "$EXPECTED_ARCH" ]] || return 1
    for section in MD5Sum SHA1 SHA256; do
        case "$section" in MD5Sum) algorithm=md5 ;; SHA1) algorithm=sha1 ;; SHA256) algorithm=sha256 ;; esac
        for name in Packages Packages.gz Packages.xz; do
            release_has_entry "$repo/Release" "$section" "$(hash_file "$algorithm" "$repo/$name")" "$(file_size "$repo/$name")" "$name" || return 1
        done
    done
}

publish_repository() {
    local destination package size md5_hash sha1_hash sha256_hash section algorithm name
    select_package
    WORK_DIR=$(mktemp -d "$TMP_DIR/publish.XXXXXX")
    destination="$WORK_DIR/repo"
    mkdir -p "$destination/pool" "$WORK_DIR/package"
    extract_package_control "$SELECTED_PACKAGE" "$WORK_DIR/package"
    validate_package_identity
    cp "$SELECTED_PACKAGE" "$destination/pool/$SELECTED_BASENAME"
    package="$destination/pool/$SELECTED_BASENAME"
    size=$(file_size "$package")
    md5_hash=$(hash_file md5 "$package")
    sha1_hash=$(hash_file sha1 "$package")
    sha256_hash=$(hash_file sha256 "$package")
    {
        awk '{print}' "$PACKAGE_CONTROL"
        printf 'Filename: pool/%s\nSize: %s\nMD5sum: %s\nSHA1: %s\nSHA256: %s\n\n' \
            "$SELECTED_BASENAME" "$size" "$md5_hash" "$sha1_hash" "$sha256_hash"
    } > "$destination/Packages"
    gzip -9 -n -c "$destination/Packages" > "$destination/Packages.gz"
    xz -9 -c "$destination/Packages" > "$destination/Packages.xz"
    {
        printf 'Origin: TrollVNC Local Development\nLabel: TrollVNC Local Development\n'
        printf 'Suite: stable\nCodename: trollvnc-local\nArchitectures: %s\n' "$EXPECTED_ARCH"
        printf 'Components: main\nDescription: Local TrollVNC development packages\n'
        LC_ALL=C date -u '+Date: %a, %d %b %Y %H:%M:%S GMT'
        printf 'Acquire-By-Hash: no\n'
        for section in MD5Sum SHA1 SHA256; do
            printf '%s:\n' "$section"
            case "$section" in MD5Sum) algorithm=md5 ;; SHA1) algorithm=sha1 ;; SHA256) algorithm=sha256 ;; esac
            for name in Packages Packages.gz Packages.xz; do
                printf ' %s %16s %s\n' "$(hash_file "$algorithm" "$destination/$name")" "$(file_size "$destination/$name")" "$name"
            done
        done
    } > "$destination/Release"
    validate_repository "$destination" || fail "generated APT repository failed validation"
    if ((DRY_RUN)); then
        printf 'dry-run: validated %s and generated APT metadata\n' "$SELECTED_BASENAME"
        printf 'dry-run: would publish only under TrollVNC/.deploy/repo\n'
        DRY_RUN_REPO_VALIDATED=1
        remove_managed "$WORK_DIR"
        WORK_DIR=""
        return
    fi
    [[ ! -L "$REPO_DIR" ]] || fail ".deploy/repo must not be a symlink"
    [[ ! -e "$REPO_DIR" || -d "$REPO_DIR" ]] || fail ".deploy/repo is not a directory"
    [[ ! -e "$REPO_DIR" ]] || remove_managed "$REPO_DIR"
    mv "$destination" "$REPO_DIR"
    remove_managed "$WORK_DIR"
    WORK_DIR=""
    validate_repository "$REPO_DIR" || fail "published APT repository failed validation"
    printf 'repository=published package=%s\n' "$SELECTED_BASENAME"
}

write_ssh_config() {
    local temporary="$SSH_CONFIG.tmp.$$"
    cat > "$temporary" <<EOF
Host trollvnc-sileo-client
    HostName $SSH_HOST
    User mobile
    Port $SSH_PORT
    IdentityFile "$SSH_IDENTITY"
    IdentitiesOnly yes
    BatchMode yes
    NumberOfPasswordPrompts 0
    StrictHostKeyChecking yes
    UpdateHostKeys no
    ConnectTimeout 10
    LogLevel ERROR

Host trollvnc-sileo-tunnel
    HostName $SSH_HOST
    User mobile
    Port $SSH_PORT
    IdentityFile "$SSH_IDENTITY"
    IdentitiesOnly yes
    BatchMode yes
    NumberOfPasswordPrompts 0
    StrictHostKeyChecking yes
    UpdateHostKeys no
    ExitOnForwardFailure yes
    ServerAliveInterval 15
    ServerAliveCountMax 3
    LogLevel ERROR
    RemoteForward 127.0.0.1:$DEVICE_PORT 127.0.0.1:$HTTP_PORT
EOF
    chmod 600 "$temporary"
    mv "$temporary" "$SSH_CONFIG"
}

configuration_signature() {
    printf '%s\n' "$SOURCE_URL" "$HTTP_PORT" "$DEVICE_PORT" "$SSH_HOST" "$SSH_PORT" "$SSH_USER" "$SSH_IDENTITY" | hash_text
}

local_release_matches() {
    cmp -s "$REPO_DIR/Release" <(curl -fsS --max-time 5 "http://127.0.0.1:$HTTP_PORT/Release" 2>/dev/null)
}

device_release_matches() {
    local probe result=1
    probe=$(mktemp "$TMP_DIR/.device-release.XXXXXX") || return 1
    if ssh -F "$SSH_CONFIG" trollvnc-sileo-client /usr/bin/zsh -s -- "$DEVICE_PORT" \
        > "$probe" 2>/dev/null <<'REMOTE_ZSH'
set -eu
zmodload zsh/net/tcp
ztcp 127.0.0.1 "$1"
socket_fd=$REPLY
printf 'GET /Release HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n' >&$socket_fd
IFS= read -r response_line <&$socket_fd
response_line=${response_line%$'\r'}
case "$response_line" in
    'HTTP/'*' 200 '*) : ;;
    *) exit 22 ;;
esac
while IFS= read -r header_line <&$socket_fd; do
    header_line=${header_line%$'\r'}
    [[ -n "$header_line" ]] || break
done
dd bs=65536 <&$socket_fd 2>/dev/null
ztcp -c "$socket_fd"
REMOTE_ZSH
    then
        cmp -s "$REPO_DIR/Release" "$probe" && result=0
    fi
    remove_managed "$probe"
    return "$result"
}

http_listener_owned() {
    local expected=$1 pid found=0
    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        [[ "$pid" == "$expected" ]] || return 1
        found=1
    done < <(lsof -nP -tiTCP:"$HTTP_PORT" -sTCP:LISTEN 2>/dev/null | awk '!seen[$0]++')
    ((found == 1))
}

services_healthy() {
    local http_pid
    http_pid=$(owned_pid http 2>/dev/null) || return 1
    owned_pid tunnel >/dev/null 2>&1 || return 1
    http_listener_owned "$http_pid" && local_release_matches && device_release_matches
}

wait_for_http() {
    local attempt=0 pid
    while ((attempt < 50)); do
        pid=$(owned_pid http 2>/dev/null) || return 1
        http_listener_owned "$pid" && local_release_matches && return 0
        sleep 0.1
        attempt=$((attempt + 1))
    done
    return 1
}

wait_for_tunnel() {
    local attempt=0
    while ((attempt < 10)); do
        owned_pid tunnel >/dev/null 2>&1 || return 1
        device_release_matches && return 0
        sleep 1
        attempt=$((attempt + 1))
    done
    return 1
}

start_services() {
    local signature http_pid tunnel_pid foreign
    if ((DRY_RUN)); then
        ((DRY_RUN_REPO_VALIDATED)) || validate_repository "$REPO_DIR" || fail "publish a valid repository before start"
        printf 'dry-run: would bind HTTP only to Mac loopback\n'
        printf 'dry-run: would establish the mobile-user device loopback reverse tunnel\n'
        return
    fi
    validate_repository "$REPO_DIR" || fail "publish a valid repository before start"
    write_ssh_config
    signature=$(configuration_signature)
    if owned_pid http >/dev/null 2>&1 || owned_pid tunnel >/dev/null 2>&1; then
        [[ -f "$SIGNATURE_FILE" && "$(awk 'NR == 1 {print; exit}' "$SIGNATURE_FILE")" == "$signature" ]] ||
            fail "running services use different configuration; run stop first"
        services_healthy || fail "owned services are unhealthy; run stop, then start"
        printf 'services=reused\n'
        return
    fi
    remove_managed "$(process_state_file http)" "$(process_state_file tunnel)"
    foreign=$(lsof -nP -tiTCP:"$HTTP_PORT" -sTCP:LISTEN 2>/dev/null | awk '!seen[$0]++' || true)
    [[ -z "$foreign" ]] || fail "configured Mac HTTP port is already in use"
    printf '%s\n' "$signature" > "$SIGNATURE_FILE"
    : >> "$LOG_DIR/http.log"
    : >> "$LOG_DIR/tunnel.log"
    ROLLBACK_SERVICES=1
    nohup python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$REPO_DIR" \
        </dev/null >> "$LOG_DIR/http.log" 2>&1 &
    http_pid=$!
    record_process http "$http_pid" "http.server $HTTP_PORT" || fail "HTTP server exited before ownership was recorded"
    STARTED_HTTP=1
    wait_for_http || fail "loopback HTTP server did not become healthy"
    nohup ssh -F "$SSH_CONFIG" trollvnc-sileo-tunnel -N -T \
        </dev/null >> "$LOG_DIR/tunnel.log" 2>&1 &
    tunnel_pid=$!
    record_process tunnel "$tunnel_pid" "trollvnc-sileo-tunnel -N -T" || fail "SSH tunnel exited before ownership was recorded"
    STARTED_TUNNEL=1
    wait_for_tunnel || fail "SSH reverse tunnel did not expose the repository on device loopback"
    ROLLBACK_SERVICES=0
    printf 'services=started\n'
}

verify_services() {
    local http_pid
    validate_repository "$REPO_DIR" || fail "published repository is invalid"
    write_ssh_config
    [[ -f "$SIGNATURE_FILE" && "$(awk 'NR == 1 {print; exit}' "$SIGNATURE_FILE")" == "$(configuration_signature)" ]] ||
        fail "running service configuration does not match deploy.env"
    http_pid=$(owned_pid http 2>/dev/null) || fail "owned HTTP server is not running"
    owned_pid tunnel >/dev/null 2>&1 || fail "owned SSH tunnel is not running"
    http_listener_owned "$http_pid" && local_release_matches || fail "Mac loopback repository verification failed"
    device_release_matches || fail "device loopback repository verification failed"
    printf 'repository=verified\ndevice_endpoint=verified\n'
}

status_services() {
    local ok=1 http_pid
    if [[ -f "$SIGNATURE_FILE" && "$(awk 'NR == 1 {print; exit}' "$SIGNATURE_FILE")" == "$(configuration_signature)" ]]; then
        printf 'configuration=current\n'
    else
        printf 'configuration=not-running-or-changed\n'
        ok=0
    fi
    if validate_repository "$REPO_DIR"; then printf 'repository=ready\n'; else printf 'repository=missing-or-invalid\n'; ok=0; fi
    if http_pid=$(owned_pid http 2>/dev/null); then
        if http_listener_owned "$http_pid" && local_release_matches; then printf 'http=healthy\n'; else printf 'http=unhealthy\n'; ok=0; fi
    else
        printf 'http=stopped\n'
        ok=0
    fi
    if owned_pid tunnel >/dev/null 2>&1; then
        printf 'tunnel=running\n'
        if ((ok)) && device_release_matches; then printf 'device_endpoint=healthy\n'; else printf 'device_endpoint=unreachable-or-mismatched\n'; ok=0; fi
    else
        printf 'tunnel=stopped\ndevice_endpoint=unreachable\n'
        ok=0
    fi
    ((ok == 1))
}

stop_services() {
    if ((DRY_RUN)); then
        printf 'dry-run: would stop only identity-verified deployment processes\n'
        return
    fi
    stop_process tunnel
    stop_process http
    remove_managed "$SIGNATURE_FILE" "$SSH_CONFIG"
}

load_config
if [[ "$COMMAND" != stop ]]; then
    validate_connection_config \
        TROLLVNC_SILEO_SOURCE_URL "$SOURCE_URL" \
        TROLLVNC_SILEO_HTTP_PORT "$HTTP_PORT" \
        TROLLVNC_SILEO_DEVICE_PORT "$DEVICE_PORT" \
        TROLLVNC_SILEO_SSH_HOST "$SSH_HOST" \
        TROLLVNC_SILEO_SSH_PORT "$SSH_PORT" \
        TROLLVNC_SILEO_SSH_USER "$SSH_USER" \
        TROLLVNC_SILEO_SSH_IDENTITY "$SSH_IDENTITY"
fi
require_common_commands
initialize_state
[[ "$COMMAND" == stop ]] || load_source_identity

case "$COMMAND" in
    deploy)
        require_publish_commands
        require_runtime_commands
        publish_repository
        start_services
        ((DRY_RUN)) || verify_services
        ;;
    start)
        require_publish_commands
        require_runtime_commands
        start_services
        ;;
    verify)
        require_publish_commands
        require_runtime_commands
        verify_services
        ;;
    status)
        require_publish_commands
        require_runtime_commands
        write_ssh_config
        status_services
        ;;
    stop) stop_services ;;
esac
