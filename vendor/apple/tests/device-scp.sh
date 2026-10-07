#!/bin/bash
# 通用真机文件传输；换设备直接修改本节，无需环境变量。
# 上传：bash device-scp.sh /tmp/apple-state /tmp/apple-state
# 下载：bash device-scp.sh --download /tmp/device-report.json /tmp/device-report.json
# 两个路径分别引用即可保留空格。不保存密码；须先配置密钥及核对host key。
# 目录传输加 --recursive；下载会覆盖指定本地目标，请使用明确的输出路径。
DEVICE_HOST='10.17.12.17'
DEVICE_PORT='2222'
DEVICE_USER='mobile'
DEVICE_KNOWN_HOSTS='/tmp/cazer-iproxy-10.17.12.17-known-hosts'

set -euo pipefail
usage() {
    printf '%s\n' 'Usage: device-scp.sh [--download] [--recursive] <source-path> <destination-path>' \
        'Default: upload local source to remote destination.' \
        '--download: remote source to local destination.' \
        'Edit DEVICE_* at the top when changing devices. Uses SSH keys and BatchMode.'
}
download=false
recursive=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --download) download=true; shift ;;
        --recursive) recursive=true; shift ;;
        --help) usage; exit 0 ;;
        --) shift; break ;;
        -*) usage >&2; exit 2 ;;
        *) break ;;
    esac
done
if [[ $# -ne 2 || -z $1 || -z $2 ]]; then usage >&2; exit 2; fi
options=(-o BatchMode=yes -o "UserKnownHostsFile=$DEVICE_KNOWN_HOSTS" -o StrictHostKeyChecking=yes -P "$DEVICE_PORT")
if $recursive; then options+=(-r); fi
if $download; then
    scp "${options[@]}" -- "$DEVICE_USER@$DEVICE_HOST:$1" "$2"
else
    scp "${options[@]}" -- "$1" "$DEVICE_USER@$DEVICE_HOST:$2"
fi
