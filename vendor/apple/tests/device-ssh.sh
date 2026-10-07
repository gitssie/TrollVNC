#!/bin/bash
# 通用真机 SSH 包装；下次换设备只修改本节，不需要设置环境变量。
# 用法：bash device-ssh.sh /usr/bin/apple-state
#       bash device-ssh.sh /usr/bin/apple-login
# JSON/密码通过标准输入交给远端程序，不能放在下面的配置或命令参数里。
# 连接前应已配置 SSH 密钥，并通过独立渠道核对、保存该设备的 host key。
DEVICE_HOST='10.17.12.17'
DEVICE_PORT='2222'
DEVICE_USER='mobile'
DEVICE_KNOWN_HOSTS='/tmp/cazer-iproxy-10.17.12.17-known-hosts'

set -euo pipefail
if [[ ${1:-} == '--help' || $# == 0 ]]; then
    printf '%s\n' 'Usage: bash device-ssh.sh <remote-program> [arguments...]' \
        'Edit DEVICE_* at the top when changing devices. Input echo is disabled.' \
        'Send credentials on stdin; do not pass them as arguments.'
    if [[ $# == 0 ]]; then exit 2; fi
    exit 0
fi

# 保留完整终端状态；非终端输入（管道/文件）无需操作 stty。
terminal_state=''
restore_terminal() {
    if [[ -n $terminal_state ]]; then stty "$terminal_state" || true; fi
}
trap restore_terminal EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
if [[ -t 0 ]]; then
    terminal_state=$(stty -g)
    stty -echo
fi

# SSH 将远端参数交给 shell；逐项引用以保留空格及特殊字符。
# 此脚本接受程序与参数，不解释调用方提供的管道、重定向等 shell 表达式。
remote_command=''
for argument in "$@"; do
    escaped=${argument//\'/\'\\\'\'}
    remote_command+="'$escaped' "
done
ssh -T -o BatchMode=yes \
    -o "UserKnownHostsFile=$DEVICE_KNOWN_HOSTS" \
    -o StrictHostKeyChecking=yes \
    -p "$DEVICE_PORT" "$DEVICE_USER@$DEVICE_HOST" "$remote_command"
