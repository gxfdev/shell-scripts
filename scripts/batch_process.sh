#!/usr/bin/env bash
# ============================================================================
#  批量处理脚本 (Batch Process Script)
#  支持: CentOS/RHEL, Ubuntu/Debian, Alpine, Arch Linux, openSUSE
#  版本: 2.0.0
#  作者: gxfdev
#  仓库: https://github.com/gxfdev/shell-scripts
# ============================================================================
#  功能:
#    1. 批量命令执行 (SSH并行/串行)
#    2. 批量文件分发与收集
#    3. 批量软件包安装/更新/卸载
#    4. 批量服务管理
#    5. 批量用户管理
#    6. 批量配置同步
#    7. 批量系统监控与巡检
#    8. 批量安全检查
#    9. 批量日志收集与分析
#   10. 执行结果汇总与报告
# ============================================================================
#  用法:
#    bash batch_process.sh --hosts hosts.txt --exec "uptime"
#    bash batch_process.sh --hosts hosts.txt --copy-local /tmp/file --remote-dir /tmp
#    bash batch_process.sh --hosts hosts.txt --copy-remote /var/log/syslog --local-dir /tmp/logs
#    bash batch_process.sh --hosts hosts.txt --install nginx
#    bash batch_process.sh --hosts hosts.txt --service restart nginx
#    bash batch_process.sh --hosts hosts.txt --check
#    bash batch_process.sh --hosts hosts.txt --monitor
#    bash batch_process.sh --hosts hosts.txt --security-check
# ============================================================================

set -euo pipefail

SCRIPT_VERSION="2.0.0"
SCRIPT_NAME="batch_process"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="/var/log/batch_process"
LOG_FILE="${LOG_DIR}/batch_${TIMESTAMP}.log"
RESULT_DIR="${LOG_DIR}/results_${TIMESTAMP}"
LOCK_FILE="/tmp/batch_process.lock"
SSH_OPTIONS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3"
SSH_USER="root"
SSH_PORT=22
SSH_KEY=""
PARALLEL=10
TIMEOUT=300
DRY_RUN=0
VERBOSE=0
INVENTORY_FILE=""
INVENTORY_GROUP=""
HOST_FILTER=""
COMMAND_TIMEOUT=60

declare -a HOST_LIST=()
declare -A HOST_VARS=()
declare -A GROUP_HOSTS=()
declare -A STATS
STATS[total]=0; STATS[success]=0; STATS[failed]=0; STATS[unreachable]=0; STATS[skipped]=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
WHITE='\033[1;37m'; NC='\033[0m'; DIM='\033[2m'

log() {
    local level="$1"; shift; local message="$*"
    local ts="$(date '+%Y-%m-%d %H:%M:%S')"
    mkdir -p "${LOG_DIR}" 2>/dev/null || true
    echo "[${ts}] [${level}] ${message}" >> "${LOG_FILE}" 2>/dev/null || true
    case "${level}" in
        INFO)    echo -e "${BLUE}[INFO]${NC} ${message}" ;;
        SUCCESS) echo -e "${GREEN}[OK]${NC} ${message}" ;;
        WARNING) echo -e "${YELLOW}[WARN]${NC} ${message}" ;;
        ERROR)   echo -e "${RED}[FAIL]${NC} ${message}" ;;
        STEP)    echo -e "${MAGENTA}[STEP]${NC} ${message}" ;;
        DEBUG)   [[ ${VERBOSE} -eq 1 ]] && echo -e "${DIM}[DEBUG]${NC} ${message}" ;;
    esac
}

log_info()    { log "INFO" "$@"; }
log_success() { log "SUCCESS" "$@"; }
log_warning() { log "WARNING" "$@"; }
log_error()   { log "ERROR" "$@"; }
log_step()    { log "STEP" "$@"; }

die() { log "ERROR" "$@"; exit 1; }

print_banner() {
    echo -e "${CYAN}"
    cat << 'BANNER'
  ======================================================================
  =     Batch Process Script v2.0.0                                   =
  =     https://github.com/gxfdev/shell-scripts                       =
  ======================================================================
BANNER
    echo -e "${NC}"
}

# ============================================================================
# 主机清单解析
# ============================================================================

parse_inventory() {
    local file="$1"
    [[ ! -f "${file}" ]] && die "主机清单文件不存在: ${file}"
    local current_group="default"
    while IFS= read -r line; do
        line="$(echo "${line}" | xargs)"
        [[ -z "${line}" ]] && continue
        [[ "${line}" =~ ^# ]] && continue
        if [[ "${line}" =~ ^\[([a-zA-Z0-9_-]+)\]$ ]]; then
            current_group="${BASH_REMATCH[1]}"
            continue
        fi
        if [[ "${line}" =~ ^\[([a-zA-Z0-9_-]+):vars\]$ ]]; then
            current_group="${BASH_REMATCH[1]}_vars"
            continue
        fi
        if [[ "${current_group}" == *"_vars" ]]; then
            local key="${line%%=*}" val="${line#*=}"
            HOST_VARS["${current_group}_${key}"]="${val}"
        else
            local host="${line%% *}"
            HOST_LIST+=("${host}")
            GROUP_HOSTS["${current_group}"]+=" ${host}"
            local rest="${line#* }"
            if [[ "${rest}" != "${host}" ]]; then
                for pair in ${rest}; do
                    local k="${pair%%=*}" v="${pair#*=}"
                    HOST_VARS["${host}_${k}"]="${v}"
                done
            fi
        fi
    done < "${file}"
    HOST_LIST=($(echo "${HOST_LIST[@]}" | tr ' ' '\n' | sort -u))
    STATS[total]=${#HOST_LIST[@]}
}

get_ssh_opts() {
    local host="$1"
    local opts="${SSH_OPTIONS} -p ${SSH_PORT}"
    local key="${SSH_KEY}"
    [[ -n "${HOST_VARS[${host}_ssh_key]:-}" ]] && key="${HOST_VARS[${host}_ssh_key]}"
    [[ -n "${HOST_VARS[${host}_ssh_port]:-}" ]] && opts="${SSH_OPTIONS} -p ${HOST_VARS[${host}_ssh_port]}"
    [[ -n "${key}" ]] && opts="${opts} -i ${key}"
    echo "${opts}"
}

get_ssh_user() {
    local host="$1"
    echo "${HOST_VARS[${host}_ansible_user]:-${HOST_VARS[${host}_ssh_user]:-${SSH_USER}}}"
}

filter_hosts() {
    [[ -z "${HOST_FILTER}" ]] && return 0
    local filtered=()
    for host in "${HOST_LIST[@]}"; do
        if [[ "${host}" == *"${HOST_FILTER}"* ]]; then
            filtered+=("${host}")
        fi
    done
    HOST_LIST=("${filtered[@]}")
    STATS[total]=${#HOST_LIST[@]}
}

filter_by_group() {
    [[ -z "${INVENTORY_GROUP}" ]] && return 0
    local group_hosts="${GROUP_HOSTS[${INVENTORY_GROUP}]:-}"
    [[ -z "${group_hosts}" ]] && die "组 '${INVENTORY_GROUP}' 不存在"
    local filtered=()
    for host in ${group_hosts}; do
        filtered+=("${host}")
    done
    HOST_LIST=("${filtered[@]}")
    STATS[total]=${#HOST_LIST[@]}
}

# ============================================================================
# SSH执行引擎
# ============================================================================

ssh_exec() {
    local host="$1" cmd="$2"
    local user="$(get_ssh_user "${host}")"
    local opts="$(get_ssh_opts "${host}")"
    local result_file="${RESULT_DIR}/${host}.result"
    local start_time="$(date +%s)"

    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[模拟] ${host}: ${cmd}"
        echo "DRY_RUN" > "${result_file}"
        return 0
    fi

    timeout "${COMMAND_TIMEOUT}" ssh ${opts} "${user}@${host}" "${cmd}" > "${result_file}" 2>&1
    local rc=$?
    local end_time="$(date +%s)"
    local duration=$((end_time - start_time))

    if [[ ${rc} -eq 0 ]]; then
        ((STATS[success]++)) || true
        log_success "[${host}] 成功 (${duration}s)"
        [[ ${VERBOSE} -eq 1 ]] && cat "${result_file}" 2>/dev/null | while read -r line; do
            echo -e "  ${DIM}${line}${NC}"
        done
    elif [[ ${rc} -eq 124 ]]; then
        ((STATS[failed]++)) || true
        log_error "[${host}] 超时 (${COMMAND_TIMEOUT}s)"
        echo "TIMEOUT" >> "${result_file}"
    else
        ((STATS[failed]++)) || true
        log_error "[${host}] 失败 (rc=${rc})"
        [[ ${VERBOSE} -eq 1 ]] && cat "${result_file}" 2>/dev/null | while read -r line; do
            echo -e "  ${RED}${line}${NC}"
        done
    fi
    return ${rc}
}

ssh_exec_script() {
    local host="$1" script="$2"
    local user="$(get_ssh_user "${host}")"
    local opts="$(get_ssh_opts "${host}")"
    local result_file="${RESULT_DIR}/${host}.result"

    [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟] ${host}: 执行脚本 ${script}"; return 0; }

    timeout "${TIMEOUT}" ssh ${opts} "${user}@${host}" "bash -s" < "${script}" > "${result_file}" 2>&1
    local rc=$?
    if [[ ${rc} -eq 0 ]]; then
        ((STATS[success]++)) || true
        log_success "[${host}] 脚本执行成功"
    else
        ((STATS[failed]++)) || true
        log_error "[${host}] 脚本执行失败 (rc=${rc})"
    fi
    return ${rc}
}

# ============================================================================
# 并行执行
# ============================================================================

parallel_exec() {
    local cmd="$1"
    local pids=()
    local running=0
    local tmpdir="$(mktemp -d /tmp/batch_XXXXXX)"

    log_info "并行执行 (并发数: ${PARALLEL}): ${cmd}"
    log_info "目标主机数: ${#HOST_LIST[@]}"

    for host in "${HOST_LIST[@]}"; do
        while [[ ${running} -ge ${PARALLEL} ]]; do
            for pid_file in "${tmpdir}"/*.pid 2>/dev/null; do
                [[ -f "${pid_file}" ]] || continue
                local pid="$(cat "${pid_file}")"
                if ! kill -0 "${pid}" 2>/dev/null; then
                    rm -f "${pid_file}"
                    ((running--)) || true
                fi
            done
            sleep 0.5
        done

        (
            ssh_exec "${host}" "${cmd}"
        ) &
        echo $! > "${tmpdir}/${host}.pid"
        ((running++)) || true
    done

    wait
    rm -rf "${tmpdir}"
}

serial_exec() {
    local cmd="$1"
    log_info "串行执行: ${cmd}"
    log_info "目标主机数: ${#HOST_LIST[@]}"
    for host in "${HOST_LIST[@]}"; do
        ssh_exec "${host}" "${cmd}" || true
    done
}

# ============================================================================
# 批量命令执行
# ============================================================================

batch_exec() {
    local cmd="$1"
    log_step "批量执行命令..."
    mkdir -p "${RESULT_DIR}"
    parallel_exec "${cmd}"
    print_summary
}

# ============================================================================
# 批量文件分发
# ============================================================================

batch_copy_to_remote() {
    local local_file="$1" remote_dir="$2"
    [[ ! -e "${local_file}" ]] && die "本地文件不存在: ${local_file}"
    log_step "批量分发文件: ${local_file} -> ${remote_dir}"
    mkdir -p "${RESULT_DIR}"

    for host in "${HOST_LIST[@]}"; do
        local user="$(get_ssh_user "${host}")"
        local opts="$(get_ssh_opts "${host}")"
        local result_file="${RESULT_DIR}/${host}.result"

        if [[ ${DRY_RUN} -eq 1 ]]; then
            log_info "[模拟] ${host}: scp ${local_file} -> ${remote_dir}"
            continue
        fi

        (
            if [[ -d "${local_file}" ]]; then
                scp -r ${opts} "${local_file}" "${user}@${host}:${remote_dir}/" > "${result_file}" 2>&1
            else
                scp ${opts} "${local_file}" "${user}@${host}:${remote_dir}/" > "${result_file}" 2>&1
            fi
            if [[ $? -eq 0 ]]; then
                ((STATS[success]++)) || true
                log_success "[${host}] 文件分发成功"
            else
                ((STATS[failed]++)) || true
                log_error "[${host}] 文件分发失败"
            fi
        ) &
        [[ $(jobs -r | wc -l) -ge ${PARALLEL} ]] && wait -n
    done
    wait
    print_summary
}

batch_copy_from_remote() {
    local remote_file="$1" local_dir="$2"
    log_step "批量收集文件: ${remote_file} -> ${local_dir}"
    mkdir -p "${RESULT_DIR}" "${local_dir}"

    for host in "${HOST_LIST[@]}"; do
        local user="$(get_ssh_user "${host}")"
        local opts="$(get_ssh_opts "${host}")"
        local host_dir="${local_dir}/${host}"
        mkdir -p "${host_dir}"

        if [[ ${DRY_RUN} -eq 1 ]]; then
            log_info "[模拟] ${host}: scp ${remote_file} -> ${host_dir}"
            continue
        fi

        (
            scp ${opts} "${user}@${host}:${remote_file}" "${host_dir}/" 2>>"${RESULT_DIR}/${host}.result"
            if [[ $? -eq 0 ]]; then
                ((STATS[success]++)) || true
                log_success "[${host}] 文件收集成功"
            else
                ((STATS[failed]++)) || true
                log_error "[${host}] 文件收集失败"
            fi
        ) &
        [[ $(jobs -r | wc -l) -ge ${PARALLEL} ]] && wait -n
    done
    wait
    print_summary
}

batch_rsync_to_remote() {
    local local_path="$1" remote_path="$2"
    [[ ! -e "${local_path}" ]] && die "本地路径不存在: ${local_path}"
    log_step "批量RSYNC: ${local_path} -> ${remote_path}"
    mkdir -p "${RESULT_DIR}"

    for host in "${HOST_LIST[@]}"; do
        local user="$(get_ssh_user "${host}")"
        local opts="-e 'ssh $(get_ssh_opts "${host}")'"
        local result_file="${RESULT_DIR}/${host}.result"

        [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟] ${host}: rsync ${local_path} -> ${remote_path}"; continue; }

        (
            rsync -avz --progress ${opts} "${local_path}/" "${user}@${host}:${remote_path}/" > "${result_file}" 2>&1
            if [[ $? -eq 0 ]]; then
                ((STATS[success]++)) || true
                log_success "[${host}] RSYNC完成"
            else
                ((STATS[failed]++)) || true
                log_error "[${host}] RSYNC失败"
            fi
        ) &
        [[ $(jobs -r | wc -l) -ge ${PARALLEL} ]] && wait -n
    done
    wait
    print_summary
}

# ============================================================================
# 批量软件包管理
# ============================================================================

batch_install() {
    local package="$1"
    log_step "批量安装软件包: ${package}"
    mkdir -p "${RESULT_DIR}"

    for host in "${HOST_LIST[@]}"; do
        (
            local user="$(get_ssh_user "${host}")"
            local opts="$(get_ssh_opts "${host}")"
            local result_file="${RESULT_DIR}/${host}.result"
            local cmd="if command -v dnf &>/dev/null; then dnf install -y ${package}; elif command -v yum &>/dev/null; then yum install -y ${package}; elif command -v apt-get &>/dev/null; then apt-get update -qq && apt-get install -y ${package}; elif command -v apk &>/dev/null; then apk add --no-cache ${package}; elif command -v pacman &>/dev/null; then pacman -Sy --noconfirm ${package}; elif command -v zypper &>/dev/null; then zypper install -y ${package}; fi"

            [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟] ${host}: 安装 ${package}"; exit 0; }

            timeout "${TIMEOUT}" ssh ${opts} "${user}@${host}" "${cmd}" > "${result_file}" 2>&1
            if [[ $? -eq 0 ]]; then
                ((STATS[success]++)) || true
                log_success "[${host}] ${package} 安装成功"
            else
                ((STATS[failed]++)) || true
                log_error "[${host}] ${package} 安装失败"
            fi
        ) &
        [[ $(jobs -r | wc -l) -ge ${PARALLEL} ]] && wait -n
    done
    wait
    print_summary
}

batch_update() {
    log_step "批量更新系统..."
    mkdir -p "${RESULT_DIR}"

    for host in "${HOST_LIST[@]}"; do
        (
            local user="$(get_ssh_user "${host}")"
            local opts="$(get_ssh_opts "${host}")"
            local result_file="${RESULT_DIR}/${host}.result"
            local cmd="if command -v dnf &>/dev/null; then dnf upgrade -y; elif command -v yum &>/dev/null; then yum update -y; elif command -v apt-get &>/dev/null; then apt-get update && apt-get upgrade -y; elif command -v apk &>/dev/null; then apk update && apk upgrade; elif command -v pacman &>/dev/null; then pacman -Syu --noconfirm; elif command -v zypper &>/dev/null; then zypper update -y; fi"

            [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟] ${host}: 系统更新"; exit 0; }

            timeout "${TIMEOUT}" ssh ${opts} "${user}@${host}" "${cmd}" > "${result_file}" 2>&1
            if [[ $? -eq 0 ]]; then
                ((STATS[success]++)) || true
                log_success "[${host}] 系统更新成功"
            else
                ((STATS[failed]++)) || true
                log_error "[${host}] 系统更新失败"
            fi
        ) &
        [[ $(jobs -r | wc -l) -ge ${PARALLEL} ]] && wait -n
    done
    wait
    print_summary
}

batch_remove() {
    local package="$1"
    log_step "批量卸载软件包: ${package}"
    mkdir -p "${RESULT_DIR}"

    for host in "${HOST_LIST[@]}"; do
        (
            local user="$(get_ssh_user "${host}")"
            local opts="$(get_ssh_opts "${host}")"
            local result_file="${RESULT_DIR}/${host}.result"
            local cmd="if command -v dnf &>/dev/null; then dnf remove -y ${package}; elif command -v yum &>/dev/null; then yum remove -y ${package}; elif command -v apt-get &>/dev/null; then apt-get remove -y ${package}; elif command -v apk &>/dev/null; then apk del ${package}; elif command -v pacman &>/dev/null; then pacman -R --noconfirm ${package}; elif command -v zypper &>/dev/null; then zypper remove -y ${package}; fi"

            [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟] ${host}: 卸载 ${package}"; exit 0; }

            timeout "${TIMEOUT}" ssh ${opts} "${user}@${host}" "${cmd}" > "${result_file}" 2>&1
            if [[ $? -eq 0 ]]; then
                ((STATS[success]++)) || true
                log_success "[${host}] ${package} 卸载成功"
            else
                ((STATS[failed]++)) || true
                log_error "[${host}] ${package} 卸载失败"
            fi
        ) &
        [[ $(jobs -r | wc -l) -ge ${PARALLEL} ]] && wait -n
    done
    wait
    print_summary
}

# ============================================================================
# 批量服务管理
# ============================================================================

batch_service() {
    local action="$1" service="$2"
    log_step "批量服务管理: ${action} ${service}"
    mkdir -p "${RESULT_DIR}"

    for host in "${HOST_LIST[@]}"; do
        (
            local user="$(get_ssh_user "${host}")"
            local opts="$(get_ssh_opts "${host}")"
            local result_file="${RESULT_DIR}/${host}.result"
            local cmd="if command -v systemctl &>/dev/null; then systemctl ${action} ${service}; elif command -v rc-service &>/dev/null; then rc-service ${service} ${action}; elif command -v service &>/dev/null; then service ${service} ${action}; fi"

            [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟] ${host}: ${action} ${service}"; exit 0; }

            timeout "${COMMAND_TIMEOUT}" ssh ${opts} "${user}@${host}" "${cmd}" > "${result_file}" 2>&1
            if [[ $? -eq 0 ]]; then
                ((STATS[success]++)) || true
                log_success "[${host}] ${action} ${service} 成功"
            else
                ((STATS[failed]++)) || true
                log_error "[${host}] ${action} ${service} 失败"
            fi
        ) &
        [[ $(jobs -r | wc -l) -ge ${PARALLEL} ]] && wait -n
    done
    wait
    print_summary
}

# ============================================================================
# 批量用户管理
# ============================================================================

batch_user_add() {
    local username="$1"
    local shell="${2:-/bin/bash}"
    local groups="${3:-}"
    log_step "批量创建用户: ${username}"
    mkdir -p "${RESULT_DIR}"

    for host in "${HOST_LIST[@]}"; do
        (
            local user="$(get_ssh_user "${host}")"
            local opts="$(get_ssh_opts "${host}")"
            local result_file="${RESULT_DIR}/${host}.result"
            local cmd="id ${username} &>/dev/null || useradd -m -s ${shell} ${username}"
            [[ -n "${groups}" ]] && cmd="${cmd} && usermod -aG ${groups} ${username}"
            cmd="${cmd} && echo '${username}:$(openssl rand -base64 12)' | chpasswd && passwd -e ${username}"

            [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟] ${host}: 创建用户 ${username}"; exit 0; }

            timeout "${COMMAND_TIMEOUT}" ssh ${opts} "${user}@${host}" "${cmd}" > "${result_file}" 2>&1
            if [[ $? -eq 0 ]]; then
                ((STATS[success]++)) || true
                log_success "[${host}] 用户 ${username} 创建成功"
            else
                ((STATS[failed]++)) || true
                log_error "[${host}] 用户 ${username} 创建失败"
            fi
        ) &
        [[ $(jobs -r | wc -l) -ge ${PARALLEL} ]] && wait -n
    done
    wait
    print_summary
}

batch_user_del() {
    local username="$1"
    log_step "批量删除用户: ${username}"
    mkdir -p "${RESULT_DIR}"

    for host in "${HOST_LIST[@]}"; do
        (
            local user="$(get_ssh_user "${host}")"
            local opts="$(get_ssh_opts "${host}")"
            local result_file="${RESULT_DIR}/${host}.result"

            [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟] ${host}: 删除用户 ${username}"; exit 0; }

            timeout "${COMMAND_TIMEOUT}" ssh ${opts} "${user}@${host}" "userdel -r ${username} 2>/dev/null || userdel ${username}" > "${result_file}" 2>&1
            if [[ $? -eq 0 ]]; then
                ((STATS[success]++)) || true
                log_success "[${host}] 用户 ${username} 删除成功"
            else
                ((STATS[failed]++)) || true
                log_error "[${host}] 用户 ${username} 删除失败"
            fi
        ) &
        [[ $(jobs -r | wc -l) -ge ${PARALLEL} ]] && wait -n
    done
    wait
    print_summary
}

# ============================================================================
# 批量系统巡检
# ============================================================================

batch_check() {
    log_step "批量系统巡检..."
    mkdir -p "${RESULT_DIR}"

    local check_script='#!/bin/bash
echo "=== 系统巡检 $(hostname) $(date) ==="
echo "--- 操作系统 ---"
cat /etc/os-release 2>/dev/null | head -5
echo "--- 内核 ---"
uname -r
echo "--- 运行时间 ---"
uptime
echo "--- CPU使用率 ---"
top -bn1 | head -5
echo "--- 内存使用 ---"
free -h
echo "--- 磁盘使用 ---"
df -h | grep -v tmpfs | grep -v devtmpfs
echo "--- 网络连接 ---"
ss -s
echo "--- 监听端口 ---"
ss -tlnp | head -20
echo "--- 系统负载 ---"
cat /proc/loadavg
echo "--- 最近登录 ---"
last -5 2>/dev/null
echo "--- 失败登录 ---"
lastb -5 2>/dev/null || echo "无记录"
echo "--- 运行服务 ---"
systemctl list-units --type=service --state=running 2>/dev/null | head -20 || rc-status 2>/dev/null | head -20
echo "--- 待更新包 ---"
if command -v dnf &>/dev/null; then dnf check-update --quiet 2>/dev/null | wc -l; elif command -v apt-get &>/dev/null; then apt list --upgradable 2>/dev/null | wc -l; elif command -v yum &>/dev/null; then yum check-update --quiet 2>/dev/null | wc -l; fi
echo "--- 安全事件 ---"
journalctl -p err --since "24 hours ago" 2>/dev/null | tail -10 || tail -20 /var/log/syslog 2>/dev/null || tail -20 /var/log/messages 2>/dev/null
echo "=== 巡检完成 ==="
'

    local script_file="$(mktemp /tmp/check_XXXXXX.sh)"
    echo "${check_script}" > "${script_file}"
    chmod +x "${script_file}"

    for host in "${HOST_LIST[@]}"; do
        (
            ssh_exec_script "${host}" "${script_file}"
        ) &
        [[ $(jobs -r | wc -l) -ge ${PARALLEL} ]] && wait -n
    done
    wait
    rm -f "${script_file}"

    echo ""
    log_info "巡检结果汇总:"
    for host in "${HOST_LIST[@]}"; do
        local result_file="${RESULT_DIR}/${host}.result"
        if [[ -f "${result_file}" ]]; then
            echo -e "\n${CYAN}=== ${host} ===${NC}"
            cat "${result_file}"
        fi
    done
    print_summary
}

# ============================================================================
# 批量监控
# ============================================================================

batch_monitor() {
    log_step "批量系统监控..."
    mkdir -p "${RESULT_DIR}"

    local monitor_script='#!/bin/bash
echo "{"
echo "  \"hostname\": \"$(hostname)\","
echo "  \"timestamp\": \"$(date -Iseconds)\","
echo "  \"cpu_usage\": \"$(top -bn1 | grep 'Cpu(s)' | awk '{print $2}')\","
echo "  \"mem_total\": \"$(free -m | awk '/^Mem:/{print $2}')\","
echo "  \"mem_used\": \"$(free -m | awk '/^Mem:/{print $3}')\","
echo "  \"mem_percent\": \"$(free | awk '/^Mem:/{printf \"%.1f\", $3/$2*100}')\","
echo "  \"swap_total\": \"$(free -m | awk '/^Swap:/{print $2}')\","
echo "  \"swap_used\": \"$(free -m | awk '/^Swap:/{print $3}')\","
echo "  \"load_1m\": \"$(cut -d' ' -f1 /proc/loadavg)\","
echo "  \"load_5m\": \"$(cut -d' ' -f2 /proc/loadavg)\","
echo "  \"load_15m\": \"$(cut -d' ' -f3 /proc/loadavg)\","
echo "  \"disk_root_percent\": \"$(df / | awk 'NR==2{print $5}')\","
echo "  \"tcp_established\": \"$(ss -s | grep estab | awk '{print $2}')\","
echo "  \"processes\": \"$(ps aux | wc -l)\","
echo "  \"zombie_processes\": \"$(ps aux | awk '{if($8=="Z") print}' | wc -l)\""
echo "}"
'

    local script_file="$(mktemp /tmp/monitor_XXXXXX.sh)"
    echo "${monitor_script}" > "${script_file}"
    chmod +x "${script_file}"

    for host in "${HOST_LIST[@]}"; do
        (
            ssh_exec_script "${host}" "${script_file}"
        ) &
        [[ $(jobs -r | wc -l) -ge ${PARALLEL} ]] && wait -n
    done
    wait
    rm -f "${script_file}"

    echo ""
    echo -e "${CYAN}=== 监控汇总 ===${NC}"
    printf "%-20s %-8s %-12s %-12s %-10s %-10s %-10s\n" "主机" "CPU%" "内存(MB)" "内存%" "负载1m" "磁盘%" "僵尸"
    for host in "${HOST_LIST[@]}"; do
        local result_file="${RESULT_DIR}/${host}.result"
        if [[ -f "${result_file}" ]]; then
            local cpu="$(grep cpu_usage "${result_file}" | cut -d'"' -f4)"
            local mem_used="$(grep mem_used "${result_file}" | cut -d'"' -f4)"
            local mem_pct="$(grep mem_percent "${result_file}" | cut -d'"' -f4)"
            local load="$(grep load_1m "${result_file}" | cut -d'"' -f4)"
            local disk="$(grep disk_root_percent "${result_file}" | cut -d'"' -f4 | tr -d '%')"
            local zombie="$(grep zombie_processes "${result_file}" | cut -d'"' -f4)"
            printf "%-20s %-8s %-12s %-12s %-10s %-10s %-10s\n" "${host}" "${cpu}" "${mem_used}" "${mem_pct}%" "${load}" "${disk}%" "${zombie}"
        fi
    done
    print_summary
}

# ============================================================================
# 批量安全检查
# ============================================================================

batch_security_check() {
    log_step "批量安全检查..."
    mkdir -p "${RESULT_DIR}"

    local sec_script='#!/bin/bash
echo "=== 安全检查 $(hostname) $(date) ==="
echo "[1] SSH配置检查"
ssh_root_login="$(grep -E "^PermitRootLogin" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')"
[[ "${ssh_root_login}" == "yes" ]] && echo "  [WARN] Root SSH登录已启用" || echo "  [OK] Root SSH登录已禁用"
ssh_pwd_auth="$(grep -E "^PasswordAuthentication" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')"
[[ "${ssh_pwd_auth}" == "yes" ]] && echo "  [WARN] SSH密码认证已启用" || echo "  [OK] SSH密码认证已禁用"
echo "[2] 防火墙状态"
if command -v firewall-cmd &>/dev/null; then firewall-cmd --state 2>/dev/null; elif command -v ufw &>/dev/null; then ufw status 2>/dev/null | head -1; elif command -v iptables &>/dev/null; then iptables -L INPUT 2>/dev/null | head -3; fi
echo "[3] 开放端口"
ss -tlnp 2>/dev/null | awk 'NR>1{print "  "$4" "$6}' | head -15
echo "[4] SUID文件"
find / -perm -4000 -type f 2>/dev/null | head -10
echo "[5] 可写目录"
find / -maxdepth 3 -type d -perm -o+w 2>/dev/null | grep -v -E '(tmp|shm|lock)' | head -10
echo "[6] 空密码账户"
awk -F: '($2==""||$2=="!") {print $1}' /etc/shadow 2>/dev/null | head -5
echo "[7] 最近失败登录"
lastb -10 2>/dev/null || journalctl _SYSTEMD_UNIT=sshd.service -p err --since "7 days ago" 2>/dev/null | tail -10
echo "[8] 异常进程"
ps aux | awk '{if($3>50) print}' | head -5
echo "[9] 磁盘空间告警"
df -h | awk 'NR>1 && $5+0>85 {print "  [WARN] "$1" "$6" 使用率"$5}'
echo "[10] 内核漏洞检查"
uname -r
echo "=== 检查完成 ==="
'

    local script_file="$(mktemp /tmp/sec_check_XXXXXX.sh)"
    echo "${sec_script}" > "${script_file}"
    chmod +x "${script_file}"

    for host in "${HOST_LIST[@]}"; do
        ( ssh_exec_script "${host}" "${script_file}" ) &
        [[ $(jobs -r | wc -l) -ge ${PARALLEL} ]] && wait -n
    done
    wait
    rm -f "${script_file}"

    echo ""
    for host in "${HOST_LIST[@]}"; do
        local result_file="${RESULT_DIR}/${host}.result"
        [[ -f "${result_file}" ]] && {
            echo -e "\n${CYAN}=== ${host} ===${NC}"
            cat "${result_file}"
        }
    done
    print_summary
}

# ============================================================================
# 批量日志收集
# ============================================================================

batch_collect_logs() {
    local log_path="${1:-/var/log}"
    local local_dir="${2:-${LOG_DIR}/collected_${TIMESTAMP}}"
    log_step "批量收集日志: ${log_path}"
    mkdir -p "${RESULT_DIR}" "${local_dir}"

    for host in "${HOST_LIST[@]}"; do
        local user="$(get_ssh_user "${host}")"
        local opts="$(get_ssh_opts "${host}")"
        local host_dir="${local_dir}/${host}"
        mkdir -p "${host_dir}"

        [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟] ${host}: 收集 ${log_path}"; continue; }

        (
            scp -r ${opts} "${user}@${host}:${log_path}/*.log" "${host_dir}/" 2>/dev/null || \
            scp -r ${opts} "${user}@${host}:${log_path}" "${host_dir}/" 2>/dev/null
            if [[ $? -eq 0 ]]; then
                ((STATS[success]++)) || true
                log_success "[${host}] 日志收集成功"
            else
                ((STATS[failed]++)) || true
                log_error "[${host}] 日志收集失败"
            fi
        ) &
        [[ $(jobs -r | wc -l) -ge ${PARALLEL} ]] && wait -n
    done
    wait
    print_summary
}

# ============================================================================
# 批量配置同步
# ============================================================================

batch_sync_config() {
    local local_config="$1" remote_path="$2"
    [[ ! -f "${local_config}" ]] && die "配置文件不存在: ${local_config}"
    log_step "批量同步配置: ${local_config} -> ${remote_path}"
    mkdir -p "${RESULT_DIR}"

    for host in "${HOST_LIST[@]}"; do
        (
            local user="$(get_ssh_user "${host}")"
            local opts="$(get_ssh_opts "${host}")"
            local result_file="${RESULT_DIR}/${host}.result"

            [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟] ${host}: 同步配置"; exit 0; }

            scp ${opts} "${local_config}" "${user}@${host}:${remote_path}" > "${result_file}" 2>&1
            if [[ $? -eq 0 ]]; then
                timeout "${COMMAND_TIMEOUT}" ssh ${opts} "${user}@${host}" "chmod 644 ${remote_path} && \
                    (systemctl reload nginx 2>/dev/null || systemctl reload apache2 2>/dev/null || systemctl reload sshd 2>/dev/null || true)" >> "${result_file}" 2>&1
                ((STATS[success]++)) || true
                log_success "[${host}] 配置同步成功"
            else
                ((STATS[failed]++)) || true
                log_error "[${host}] 配置同步失败"
            fi
        ) &
        [[ $(jobs -r | wc -l) -ge ${PARALLEL} ]] && wait -n
    done
    wait
    print_summary
}

# ============================================================================
# 结果汇总
# ============================================================================

print_summary() {
    echo ""
    echo -e "${CYAN}=========================================="
    echo -e "  执行结果汇总"
    echo -e "==========================================${NC}"
    echo -e "  总主机数:  ${WHITE}${STATS[total]}${NC}"
    echo -e "  成功:      ${GREEN}${STATS[success]}${NC}"
    echo -e "  失败:      ${RED}${STATS[failed]}${NC}"
    echo -e "  不可达:    ${YELLOW}${STATS[unreachable]}${NC}"
    echo -e "${CYAN}==========================================${NC}"
    echo -e "  详细结果: ${RESULT_DIR}"
    echo -e "  日志文件: ${LOG_FILE}"
    echo ""

    local report_file="${RESULT_DIR}/summary.txt"
    echo "批量操作报告 - $(date)" > "${report_file}"
    echo "总主机: ${STATS[total]}, 成功: ${STATS[success]}, 失败: ${STATS[failed]}" >> "${report_file}"
    for host in "${HOST_LIST[@]}"; do
        local result_file="${RESULT_DIR}/${host}.result"
        echo "--- ${host} ---" >> "${report_file}"
        [[ -f "${result_file}" ]] && tail -5 "${result_file}" >> "${report_file}"
    done
}

# ============================================================================
# 批量Docker管理模块
# ============================================================================

# ============================================================================
# 批量主机资产登记
# ============================================================================

# ============================================================================
# 批量主机分组管理
# ============================================================================

# ============================================================================
# 批量主机配置差异检测
# ============================================================================

batch_config_diff() {
    local config_path="$1"
    [[ -z "${config_path}" ]] && { log_error "请指定配置文件路径"; return 1; }
    log_step "批量检测配置差异: ${config_path}..."

    local ref_content=""
    local ref_host="${HOST_LIST[0]}"
    ref_content="$(ssh_exec_cmd "${ref_host}" "cat ${config_path}" 2>/dev/null || echo '')"

    if [[ -z "${ref_content}" ]]; then
        log_error "参考主机 ${ref_host} 配置文件读取失败"
        return 1
    fi

    log_info "参考主机: ${ref_host}"
    for host in "${HOST_LIST[@]:1}"; do
        local host_content="$(ssh_exec_cmd "${host}" "cat ${config_path}" 2>/dev/null || echo '')"
        if [[ "${host_content}" == "${ref_content}" ]]; then
            log_success "[${host}] 配置一致"
        else
            log_warning "[${host}] 配置不一致"
            [[ ${VERBOSE} -eq 1 ]] && {
                diff <(echo "${ref_content}") <(echo "${host_content}") | head -20 || true
            }
        fi
    done
}

# ============================================================================
# 批量主机负载均衡检查
# ============================================================================

batch_load_check() {
    log_step "批量检查主机负载..."
    for host in "${HOST_LIST[@]}"; do
        local load_info="$(ssh_exec_cmd "${host}" "cat /proc/loadavg 2>/dev/null && nproc 2>/dev/null" 2>/dev/null || echo 'unknown')"
        local load1="$(echo "${load_info}" | head -1 | awk '{print $1}')"
        local cpu_count="$(echo "${load_info}" | tail -1)"
        if [[ "${load1}" != "unknown" ]] && [[ -n "${cpu_count}" ]]; then
            local load_pct="$(echo "scale=0; ${load1} * 100 / ${cpu_count}" | bc 2>/dev/null || echo '0')"
            if [[ ${load_pct%.*} -gt 80 ]]; then
                log_error "[${host}] 负载过高: ${load1}/${cpu_count}核 (${load_pct}%)"
            elif [[ ${load_pct%.*} -gt 50 ]]; then
                log_warning "[${host}] 负载较高: ${load1}/${cpu_count}核 (${load_pct}%)"
            else
                log_success "[${host}] 负载正常: ${load1}/${cpu_count}核 (${load_pct}%)"
            fi
        fi
    done
}

# ============================================================================
# 批量主机分组管理
# ============================================================================

batch_group_hosts() {
    local group_name="$1" group_pattern="$2"
    [[ -z "${group_name}" ]] && { log_error "请指定组名"; return 1; }
    log_step "创建主机组: ${group_name}..."
    local group_file="${SCRIPT_DIR}/host_groups.ini"
    echo "[${group_name}]" >> "${group_file}"
    for host in "${HOST_LIST[@]}"; do
        if [[ -n "${group_pattern}" ]]; then
            [[ "${host}" =~ ${group_pattern} ]] && echo "${host}" >> "${group_file}"
        else
            echo "${host}" >> "${group_file}"
        fi
    done
    log_success "主机组 ${group_name} 已创建"
}

# ============================================================================
# 批量主机标签查询
# ============================================================================

batch_query_by_label() {
    local label="$1"
    [[ -z "${label}" ]] && { log_error "请指定标签"; return 1; }
    log_step "查询标签为 ${label} 的主机..."
    local label_file="${SCRIPT_DIR}/host_labels.txt"
    if [[ -f "${label_file}" ]]; then
        grep ":${label}$" "${label_file}" | while read -r line; do
            local host="${line%%:*}"
            log_info "  ${host}"
        done
    else
        log_warning "标签文件不存在"
    fi
}

# ============================================================================
# 批量执行结果汇总
# ============================================================================

batch_summary() {
    log_step "执行结果汇总..."
    local total=${#HOST_LIST[@]}
    local success=0 failed=0 timeout=0

    for host in "${HOST_LIST[@]}"; do
        local result_file="${RESULT_DIR}/${host}.result"
        if [[ -f "${result_file}" ]]; then
            local exit_code="$(tail -1 "${result_file}" | grep -oP 'EXIT_CODE:\K\d+' 2>/dev/null || echo '0')"
            case "${exit_code}" in
                0)  ((success++)) || true ;;
                124) ((timeout++)) || true ;;
                *)  ((failed++)) || true ;;
            esac
        else
            ((failed++)) || true
        fi
    done

    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  批量操作结果汇总${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo -e "  总主机数: ${total}"
    echo -e "  ${GREEN}成功: ${success}${NC}"
    echo -e "  ${RED}失败: ${failed}${NC}"
    echo -e "  ${YELLOW}超时: ${timeout}${NC}"
    echo -e "${CYAN}========================================${NC}"

    if [[ ${failed} -gt 0 ]]; then
        log_warning "失败主机:"
        for host in "${HOST_LIST[@]}"; do
            local result_file="${RESULT_DIR}/${host}.result"
            if [[ -f "${result_file}" ]]; then
                local exit_code="$(tail -1 "${result_file}" | grep -oP 'EXIT_CODE:\K\d+' 2>/dev/null || echo '0')"
                [[ "${exit_code}" != "0" ]] && [[ "${exit_code}" != "124" ]] && log_warning "  ${host}"
            else
                log_warning "  ${host} (无结果)"
            fi
        done
    fi
}

# ============================================================================
# 批量主机资产登记
# ============================================================================

batch_asset_inventory() {
    log_step "批量主机资产登记..."
    local inventory_file="${RESULT_DIR}/asset_inventory.csv"
    echo "主机,IP,OS,内核,CPU核数,内存(GB),磁盘(GB),运行时间,主机名" > "${inventory_file}"

    for host in "${HOST_LIST[@]}"; do
        local info="$(ssh_exec_cmd "${host}" "source /etc/os-release 2>/dev/null; echo \"\${PRETTY_NAME:-unknown}\"; uname -r; nproc; free -g | awk '/Mem:/{print \$2}'; df -BG / | awk 'NR==2{print \$2}'; uptime -p 2>/dev/null || uptime | awk -F'up ' '{print \$2}' | awk -F',' '{print \$1}'; hostname" 2>/dev/null || echo "unknown")"
        local os_name="$(echo "${info}" | sed -n '1p')"
        local kernel="$(echo "${info}" | sed -n '2p')"
        local cpu_cores="$(echo "${info}" | sed -n '3p')"
        local memory="$(echo "${info}" | sed -n '4p')"
        local disk="$(echo "${info}" | sed -n '5p')"
        local uptime_info="$(echo "${info}" | sed -n '6p')"
        local hostname_val="$(echo "${info}" | sed -n '7p')"
        echo "${hostname_val},${host},${os_name},${kernel},${cpu_cores},${memory},${disk},${uptime_info},${hostname_val}" >> "${inventory_file}"
        log_info "[${host}] 资产已登记"
    done

    log_success "资产登记完成: ${inventory_file}"
    column -t -s',' "${inventory_file}"
}

# ============================================================================
# 批量主机合规检查
# ============================================================================

batch_compliance_check() {
    log_step "批量合规检查..."
    local check_items=(
        "密码策略:awk '/pass_min_days/{print \$2}' /etc/login.defs"
        "密码长度:awk '/minlen/{print \$NF}' /etc/security/pwquality.conf 2>/dev/null || echo N/A"
        "SSH root登录:grep -c '^PermitRootLogin yes' /etc/ssh/sshd_config 2>/dev/null || echo 0"
        "空密码账户:awk -F: '(\$2==\"\"||\$2==\"!\")' /etc/shadow | wc -l"
        "密码过期:awk -F: '(\$5>0 && \$5<90)' /etc/shadow | wc -l"
        "sudo免密:grep -c 'NOPASSWD' /etc/sudoers /etc/sudoers.d/* 2>/dev/null || echo 0"
        "开放端口:ss -tlnp | wc -l"
        "防火墙状态:systemctl is-active firewalld 2>/dev/null || ufw status 2>/dev/null | head -1"
        "SELinux:getenforce 2>/dev/null || echo N/A"
        "最近登录:last -5 2>/dev/null | head -5"
    )

    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 合规检查:"
        for item in "${check_items[@]}"; do
            local name="${item%%:*}"
            local cmd="${item#*:}"
            local result="$(ssh_exec_cmd "${host}" "${cmd}" 2>/dev/null || echo '检查失败')"
            log_info "  ${name}: ${result}"
        done
    done
}

# ============================================================================
# 批量日志分析
# ============================================================================

batch_analyze_logs() {
    local log_path="${1:-/var/log/syslog}"
    local pattern="${2:-error|fail|critical|fatal}"
    log_step "批量分析日志: ${log_path} (关键词: ${pattern})..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 日志分析:"
        ssh_exec_cmd "${host}" "grep -ciE '${pattern}' ${log_path} 2>/dev/null || echo '0'" | while read -r count; do
            if [[ ${count} -gt 0 ]]; then
                log_warning "[${host}] 发现${count}条匹配记录"
                ssh_exec_cmd "${host}" "grep -iE '${pattern}' ${log_path} 2>/dev/null | tail -5" || true
            else
                log_success "[${host}] 无匹配记录"
            fi
        done
    done
}

# ============================================================================
# 批量服务依赖检查
# ============================================================================

batch_check_dependencies() {
    log_step "批量检查服务依赖..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 服务依赖:"
        ssh_exec_cmd "${host}" "systemctl list-dependencies --all 2>/dev/null | grep 'failed' || echo '所有依赖正常'" || log_warning "[${host}] 依赖检查失败"
    done
}

# ============================================================================
# 批量证书检查
# ============================================================================

batch_check_certificates() {
    log_step "批量检查SSL证书..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] SSL证书:"
        ssh_exec_cmd "${host}" "for cert in /etc/ssl/certs/*.pem /etc/pki/tls/certs/*.crt /etc/letsencrypt/live/*/cert.pem; do [[ -f \"\${cert}\" ]] && echo \"\${cert}: \$(openssl x509 -enddate -noout -in \"\${cert}\" 2>/dev/null | cut -d= -f2)\"; done 2>/dev/null | head -10 || echo '无证书文件'" || log_warning "[${host}] 证书检查失败"
    done
}

# ============================================================================
# 批量内核参数检查
# ============================================================================

batch_check_sysctl() {
    local param="${1:-}"
    log_step "批量检查内核参数${param:+: ${param}}..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 内核参数:"
        if [[ -n "${param}" ]]; then
            ssh_exec_cmd "${host}" "sysctl ${param} 2>/dev/null || echo '参数不存在'" || true
        else
            ssh_exec_cmd "${host}" "sysctl -a 2>/dev/null | grep -E 'net.core.somaxconn|net.ipv4.tcp_max_syn_backlog|vm.swappiness|fs.file-max|net.ipv4.ip_forward' | head -10" || true
        fi
    done
}

# ============================================================================
# 批量Docker管理模块
# ============================================================================

batch_docker_ps() {
    log_step "批量查看Docker容器状态..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] Docker容器:"
        ssh_exec_cmd "${host}" "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}'" 2>/dev/null || log_warning "[${host}] Docker不可用"
    done
}

batch_docker_pull() {
    local image="$1"
    [[ -z "${image}" ]] && { log_error "请指定镜像名称"; return 1; }
    log_step "批量拉取Docker镜像: ${image}..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 拉取 ${image}..."
        ssh_exec_cmd "${host}" "docker pull ${image}" || log_warning "[${host}] 拉取失败"
    done
}

batch_docker_cleanup() {
    log_step "批量清理Docker资源..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 清理Docker..."
        ssh_exec_cmd "${host}" "docker system prune -af --volumes 2>/dev/null" || log_warning "[${host}] Docker清理失败"
    done
}

batch_docker_compose() {
    local action="$1" compose_file="${2:-docker-compose.yml}"
    [[ -z "${action}" ]] && { log_error "请指定compose操作 (up/down/restart)"; return 1; }
    log_step "批量Docker Compose ${action}..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] docker-compose ${action}..."
        ssh_exec_cmd "${host}" "cd $(dirname "${compose_file}") && docker-compose ${action} -d" || log_warning "[${host}] compose操作失败"
    done
}

# ============================================================================
# 批量磁盘与文件系统管理
# ============================================================================

batch_disk_usage() {
    log_step "批量检查磁盘使用情况..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 磁盘使用:"
        ssh_exec_cmd "${host}" "df -h | grep -v tmpfs | grep -v devtmpfs" || log_warning "[${host}] 获取磁盘信息失败"
    done
}

batch_disk_io() {
    log_step "批量检查磁盘IO..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 磁盘IO:"
        ssh_exec_cmd "${host}" "iostat -x 1 3 2>/dev/null || cat /proc/diskstats" || log_warning "[${host}] 获取IO信息失败"
    done
}

batch_find_large_files() {
    local min_size="${1:-100M}"
    local search_dir="${2:-/}"
    log_step "批量查找大文件 (>${min_size})..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 查找大文件..."
        ssh_exec_cmd "${host}" "find ${search_dir} -type f -size +${min_size} -exec ls -lh {} \; 2>/dev/null | head -20" || log_warning "[${host}] 查找失败"
    done
}

batch_clean_tmp() {
    local days="${1:-7}"
    log_step "批量清理临时文件 (>${days}天)..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 清理临时文件..."
        [[ ${DRY_RUN} -eq 0 ]] && {
            ssh_exec_cmd "${host}" "find /tmp -type f -mtime +${days} -delete 2>/dev/null; find /var/tmp -type f -mtime +${days} -delete 2>/dev/null" || true
        }
    done
}

# ============================================================================
# 批量网络管理
# ============================================================================

batch_network_info() {
    log_step "批量获取网络信息..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 网络信息:"
        ssh_exec_cmd "${host}" "ip addr show | grep 'inet ' | awk '{print \$2, \$NF}'" || log_warning "[${host}] 获取网络信息失败"
    done
}

batch_port_check() {
    local port="$1"
    [[ -z "${port}" ]] && { log_error "请指定端口号"; return 1; }
    log_step "批量检查端口: ${port}..."
    for host in "${HOST_LIST[@]}"; do
        local result="$(ssh_exec_cmd "${host}" "ss -tlnp | grep ':${port} ' || echo 'NOT_LISTENING'")"
        if [[ "${result}" == "NOT_LISTENING" ]]; then
            log_warning "[${host}] 端口${port}未监听"
        else
            log_success "[${host}] 端口${port}已监听"
        fi
    done
}

batch_firewall_manage() {
    local action="$1" rule="${2:-}"
    [[ -z "${action}" ]] && { log_error "请指定防火墙操作 (status/open/close/rule)"; return 1; }
    log_step "批量防火墙管理: ${action}..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 防火墙${action}..."
        case "${action}" in
            status)
                ssh_exec_cmd "${host}" "systemctl is-active firewalld 2>/dev/null || ufw status 2>/dev/null || iptables -L -n 2>/dev/null" || true
                ;;
            open)
                ssh_exec_cmd "${host}" "systemctl start firewalld 2>/dev/null || ufw enable 2>/dev/null" || true
                ;;
            close)
                ssh_exec_cmd "${host}" "systemctl stop firewalld 2>/dev/null || ufw disable 2>/dev/null" || true
                ;;
            rule)
                [[ -z "${rule}" ]] && { log_error "请指定规则"; continue; }
                ssh_exec_cmd "${host}" "firewall-cmd --add-port=${rule}/tcp --permanent 2>/dev/null && firewall-cmd --reload 2>/dev/null || ufw allow ${rule} 2>/dev/null || iptables -A INPUT -p tcp --dport ${rule} -j ACCEPT 2>/dev/null" || true
                ;;
        esac
    done
}

batch_ping_test() {
    log_step "批量Ping测试..."
    for host in "${HOST_LIST[@]}"; do
        if ping -c 1 -W 3 "${host}" &>/dev/null; then
            local latency="$(ping -c 3 -W 3 "${host}" 2>/dev/null | tail -1 | awk -F '/' '{print $5}')"
            log_success "[${host}] 可达 (${latency}ms)"
        else
            log_error "[${host}] 不可达"
        fi
    done
}

# ============================================================================
# 批量进程管理
# ============================================================================

batch_process_list() {
    local pattern="${1:-}"
    log_step "批量查看进程${pattern:+ (过滤: ${pattern})}..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 进程列表:"
        if [[ -n "${pattern}" ]]; then
            ssh_exec_cmd "${host}" "ps aux | grep -E '${pattern}' | grep -v grep" || log_warning "[${host}] 未找到匹配进程"
        else
            ssh_exec_cmd "${host}" "ps aux --sort=-%mem | head -20" || log_warning "[${host}] 获取进程列表失败"
        fi
    done
}

batch_process_kill() {
    local pattern="$1"
    [[ -z "${pattern}" ]] && { log_error "请指定进程名或PID"; return 1; }
    log_step "批量终止进程: ${pattern}..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 终止进程..."
        [[ ${DRY_RUN} -eq 0 ]] && {
            ssh_exec_cmd "${host}" "pkill -f '${pattern}' 2>/dev/null || kill ${pattern} 2>/dev/null" || log_warning "[${host}] 进程终止失败"
        }
    done
}

# ============================================================================
# 批量系统信息收集
# ============================================================================

batch_system_info() {
    log_step "批量收集系统信息..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 系统信息:"
        ssh_exec_cmd "${host}" "echo '=== OS ===' && cat /etc/os-release 2>/dev/null | head -3 && echo '=== Kernel ===' && uname -r && echo '=== CPU ===' && nproc && echo '=== Memory ===' && free -h | head -2 && echo '=== Uptime ===' && uptime && echo '=== Hostname ===' && hostname" || log_warning "[${host}] 信息收集失败"
    done
}

batch_kernel_info() {
    log_step "批量收集内核信息..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 内核信息:"
        ssh_exec_cmd "${host}" "uname -a && echo '---' && cat /proc/cmdline 2>/dev/null" || log_warning "[${host}] 内核信息获取失败"
    done
}

# ============================================================================
# 批量Cron任务管理
# ============================================================================

batch_cron_list() {
    log_step "批量列出Cron任务..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] Cron任务:"
        ssh_exec_cmd "${host}" "crontab -l 2>/dev/null || echo '(无Cron任务)'" || log_warning "[${host}] 获取Cron任务失败"
    done
}

batch_cron_add() {
    local cron_entry="$1"
    [[ -z "${cron_entry}" ]] && { log_error "请指定Cron条目"; return 1; }
    log_step "批量添加Cron任务: ${cron_entry}..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 添加Cron任务..."
        [[ ${DRY_RUN} -eq 0 ]] && {
            ssh_exec_cmd "${host}" "(crontab -l 2>/dev/null; echo '${cron_entry}') | crontab -" || log_warning "[${host}] Cron添加失败"
        }
    done
}

batch_cron_remove() {
    local pattern="$1"
    [[ -z "${pattern}" ]] && { log_error "请指定Cron条目匹配模式"; return 1; }
    log_step "批量删除Cron任务: ${pattern}..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 删除Cron任务..."
        [[ ${DRY_RUN} -eq 0 ]] && {
            ssh_exec_cmd "${host}" "crontab -l 2>/dev/null | grep -v '${pattern}' | crontab -" || log_warning "[${host}] Cron删除失败"
        }
    done
}

# ============================================================================
# 批量环境变量管理
# ============================================================================

batch_set_env() {
    local key="$1" value="$2"
    [[ -z "${key}" ]] && { log_error "请指定环境变量名"; return 1; }
    log_step "批量设置环境变量: ${key}=${value}..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 设置环境变量..."
        [[ ${DRY_RUN} -eq 0 ]] && {
            ssh_exec_cmd "${host}" "grep -q '^export ${key}=' /etc/profile && sed -i 's|^export ${key}=.*|export ${key}=${value}|' /etc/profile || echo 'export ${key}=${value}' >> /etc/profile" || log_warning "[${host}] 环境变量设置失败"
        }
    done
}

batch_get_env() {
    local key="$1"
    [[ -z "${key}" ]] && { log_error "请指定环境变量名"; return 1; }
    log_step "批量获取环境变量: ${key}..."
    for host in "${HOST_LIST[@]}"; do
        local val="$(ssh_exec_cmd "${host}" "source /etc/profile 2>/dev/null; echo \${${key}}" 2>/dev/null)"
        log_info "[${host}] ${key}=${val:-未设置}"
    done
}

# ============================================================================
# 批量文件权限管理
# ============================================================================

batch_chmod() {
    local path="$1" perms="$2"
    [[ -z "${path}" ]] || [[ -z "${perms}" ]] && { log_error "用法: --chmod 路径 权限"; return 1; }
    log_step "批量修改文件权限: ${path} -> ${perms}..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 修改权限..."
        [[ ${DRY_RUN} -eq 0 ]] && {
            ssh_exec_cmd "${host}" "chmod ${perms} ${path}" || log_warning "[${host}] 权限修改失败"
        }
    done
}

batch_chown() {
    local path="$1" owner="$2"
    [[ -z "${path}" ]] || [[ -z "${owner}" ]] && { log_error "用法: --chown 路径 所有者"; return 1; }
    log_step "批量修改文件所有者: ${path} -> ${owner}..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 修改所有者..."
        [[ ${DRY_RUN} -eq 0 ]] && {
            ssh_exec_cmd "${host}" "chown ${owner} ${path}" || log_warning "[${host}] 所有者修改失败"
        }
    done
}

# ============================================================================
# 批量时间同步管理
# ============================================================================

batch_time_sync() {
    log_step "批量时间同步..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 当前时间: $(ssh_exec_cmd "${host}" 'date' 2>/dev/null)"
        [[ ${DRY_RUN} -eq 0 ]] && {
            ssh_exec_cmd "${host}" "timedatectl set-ntp true 2>/dev/null || ntpdate -u pool.ntp.org 2>/dev/null || chronyc -a makestep 2>/dev/null" || log_warning "[${host}] 时间同步失败"
        }
    done
}

batch_timezone_set() {
    local tz="$1"
    [[ -z "${tz}" ]] && { log_error "请指定时区 (如 Asia/Shanghai)"; return 1; }
    log_step "批量设置时区: ${tz}..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 设置时区..."
        [[ ${DRY_RUN} -eq 0 ]] && {
            ssh_exec_cmd "${host}" "timedatectl set-timezone ${tz} 2>/dev/null || ln -sf /usr/share/zoneinfo/${tz} /etc/localtime" || log_warning "[${host}] 时区设置失败"
        }
    done
}

# ============================================================================
# 批量SSH密钥管理
# ============================================================================

batch_deploy_ssh_key() {
    local key_file="${1:-${HOME}/.ssh/id_rsa.pub}"
    [[ ! -f "${key_file}" ]] && { log_error "公钥文件不存在: ${key_file}"; return 1; }
    local pub_key="$(cat "${key_file}")"
    log_step "批量部署SSH公钥..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 部署SSH公钥..."
        [[ ${DRY_RUN} -eq 0 ]] && {
            ssh_exec_cmd "${host}" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '${pub_key}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys" || log_warning "[${host}] SSH公钥部署失败"
        }
    done
}

batch_rotate_ssh_key() {
    log_step "批量轮换SSH密钥..."
    local key_type="${1:-ed25519}"
    local key_comment="rotated-$(date +%Y%m%d)"
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 轮换SSH密钥..."
        [[ ${DRY_RUN} -eq 0 ]] && {
            ssh_exec_cmd "${host}" "ssh-keygen -t ${key_type} -C '${key_comment}' -f ~/.ssh/id_${key_type} -N '' -q && cat ~/.ssh/id_${key_type}.pub" || log_warning "[${host}] SSH密钥轮换失败"
        }
    done
}

# ============================================================================
# 批量系统更新与补丁管理
# ============================================================================

batch_security_update() {
    log_step "批量安装安全更新..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 安装安全更新..."
        [[ ${DRY_RUN} -eq 0 ]] && {
            local os_family="$(ssh_exec_cmd "${host}" "source /etc/os-release 2>/dev/null && echo \${ID}" 2>/dev/null)"
            case "${os_family}" in
                centos|rhel|rocky|almalinux)
                    ssh_exec_cmd "${host}" "yum update --security -y 2>/dev/null || dnf update --security -y 2>/dev/null" || log_warning "[${host}] 安全更新失败"
                    ;;
                ubuntu|debian)
                    ssh_exec_cmd "${host}" "apt-get update && unattended-upgrade -v 2>/dev/null || apt-get upgrade --with-new-pkgs -y 2>/dev/null" || log_warning "[${host}] 安全更新失败"
                    ;;
                *)
                    ssh_exec_cmd "${host}" "echo '不支持自动安全更新'" || true
                    ;;
            esac
        }
    done
}

batch_kernel_update() {
    log_step "批量更新内核..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 当前内核: $(ssh_exec_cmd "${host}" 'uname -r' 2>/dev/null)"
        [[ ${DRY_RUN} -eq 0 ]] && {
            local os_family="$(ssh_exec_cmd "${host}" "source /etc/os-release 2>/dev/null && echo \${ID}" 2>/dev/null)"
            case "${os_family}" in
                centos|rhel|rocky|almalinux)
                    ssh_exec_cmd "${host}" "yum update kernel -y 2>/dev/null || dnf update kernel -y 2>/dev/null" || log_warning "[${host}] 内核更新失败"
                    ;;
                ubuntu|debian)
                    ssh_exec_cmd "${host}" "apt-get update && apt-get install --only-upgrade linux-image-generic -y 2>/dev/null" || log_warning "[${host}] 内核更新失败"
                    ;;
                *)
                    log_warning "[${host}] 不支持自动内核更新"
                    ;;
            esac
        }
    done
}

# ============================================================================
# 批量配置备份
# ============================================================================

batch_backup_configs() {
    local backup_dir="${1:-/tmp/config_backup_${TIMESTAMP}}"
    log_step "批量备份配置文件到: ${backup_dir}..."
    mkdir -p "${backup_dir}" 2>/dev/null || true

    local config_paths="/etc/nginx /etc/ssh/sshd_config /etc/fstab /etc/hosts /etc/resolv.conf /etc/sysctl.conf /etc/crontab /etc/sudoers"
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 备份配置..."
        local host_backup="${backup_dir}/${host}"
        mkdir -p "${host_backup}" 2>/dev/null || true
        for path in ${config_paths}; do
            scp -P ${SSH_PORT} ${SSH_OPTIONS} -r "${SSH_USER}@${host}:${path}" "${host_backup}/" 2>/dev/null || true
        done
        log_success "[${host}] 配置已备份到: ${host_backup}"
    done
}

# ============================================================================
# 批量性能测试
# ============================================================================

batch_benchmark() {
    log_step "批量性能测试..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 性能测试..."
        ssh_exec_cmd "${host}" "echo '=== CPU ===' && sysbench cpu --time=10 run 2>/dev/null | grep 'total time' || echo 'sysbench未安装' && echo '=== Memory ===' && sysbench memory --time=10 run 2>/dev/null | grep 'total time' || echo 'sysbench未安装' && echo '=== Disk ===' && dd if=/dev/zero of=/tmp/bench bs=1M count=1024 oflag=dsync 2>&1 | tail -1 && rm -f /tmp/bench" || log_warning "[${host}] 性能测试失败"
    done
}

# ============================================================================
# 批量主机连通性报告
# ============================================================================

batch_connectivity_report() {
    log_step "生成主机连通性报告..."
    local report_file="${RESULT_DIR}/connectivity_report.txt"
    local online=0 offline=0

    echo "主机连通性报告 - $(date)" > "${report_file}"
    echo "================================" >> "${report_file}"

    for host in "${HOST_LIST[@]}"; do
        if ping -c 1 -W 3 "${host}" &>/dev/null; then
            echo "[在线] ${host}" >> "${report_file}"
            ((online++)) || true
        else
            echo "[离线] ${host}" >> "${report_file}"
            ((offline++)) || true
        fi
    done

    echo "" >> "${report_file}"
    echo "总计: ${#HOST_LIST[@]}台, 在线: ${online}台, 离线: ${offline}台" >> "${report_file}"
    log_success "连通性报告: 在线${online}台, 离线${offline}台"
    cat "${report_file}"
}

# ============================================================================
# 批量主机标签管理
# ============================================================================

batch_label_hosts() {
    local label="$1"
    [[ -z "${label}" ]] && { log_error "请指定标签"; return 1; }
    log_step "为主机添加标签: ${label}..."
    local label_file="${SCRIPT_DIR}/host_labels.txt"
    for host in "${HOST_LIST[@]}"; do
        if grep -q "^${host}:" "${label_file}" 2>/dev/null; then
            sed -i "s|^${host}:.*|${host}:${label}|" "${label_file}" 2>/dev/null || true
        else
            echo "${host}:${label}" >> "${label_file}"
        fi
        log_info "[${host}] 标签已设置: ${label}"
    done
}

# ============================================================================
# 批量SELinux/AppArmor管理
# ============================================================================

batch_selinux_manage() {
    local action="$1"
    [[ -z "${action}" ]] && { log_error "请指定操作 (status/enforce/permissive/disable)"; return 1; }
    log_step "批量SELinux管理: ${action}..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] SELinux ${action}..."
        case "${action}" in
            status)
                ssh_exec_cmd "${host}" "getenforce 2>/dev/null || echo 'SELinux未安装'" || true
                ;;
            enforce)
                [[ ${DRY_RUN} -eq 0 ]] && ssh_exec_cmd "${host}" "setenforce 1 2>/dev/null" || true
                ;;
            permissive)
                [[ ${DRY_RUN} -eq 0 ]] && ssh_exec_cmd "${host}" "setenforce 0 2>/dev/null" || true
                ;;
            disable)
                [[ ${DRY_RUN} -eq 0 ]] && ssh_exec_cmd "${host}" "sed -i 's/SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config 2>/dev/null" || true
                ;;
        esac
    done
}

# ============================================================================
# 批量Swap管理
# ============================================================================

batch_swap_manage() {
    local action="${1:-status}"
    log_step "批量Swap管理: ${action}..."
    for host in "${HOST_LIST[@]}"; do
        case "${action}" in
            status)
                log_info "[${host}] Swap: $(ssh_exec_cmd "${host}" 'free -h | grep Swap' 2>/dev/null || echo '未知')"
                ;;
            off)
                [[ ${DRY_RUN} -eq 0 ]] && ssh_exec_cmd "${host}" "swapoff -a 2>/dev/null" || true
                ;;
            on)
                [[ ${DRY_RUN} -eq 0 ]] && ssh_exec_cmd "${host}" "swapon -a 2>/dev/null" || true
                ;;
            *)
                log_warning "未知Swap操作: ${action}"
                ;;
        esac
    done
}

# ============================================================================
# 批量系统限制管理
# ============================================================================

batch_set_ulimits() {
    local limit_type="$1" value="$2"
    [[ -z "${limit_type}" ]] && { log_error "请指定限制类型 (nofile/nproc等)"; return 1; }
    log_step "批量设置系统限制: ${limit_type}=${value}..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 设置${limit_type}..."
        [[ ${DRY_RUN} -eq 0 ]] && {
            ssh_exec_cmd "${host}" "grep -q '^* soft ${limit_type}' /etc/security/limits.conf && sed -i 's|^* soft ${limit_type}.*|* soft ${limit_type} ${value}|' /etc/security/limits.conf || echo '* soft ${limit_type} ${value}' >> /etc/security/limits.conf; grep -q '^* hard ${limit_type}' /etc/security/limits.conf && sed -i 's|^* hard ${limit_type}.*|* hard ${limit_type} ${value}|' /etc/security/limits.conf || echo '* hard ${limit_type} ${value}' >> /etc/security/limits.conf" || log_warning "[${host}] 限制设置失败"
        }
    done
}

# ============================================================================
# 批量DNS管理
# ============================================================================

batch_set_dns() {
    local dns_server="$1"
    [[ -z "${dns_server}" ]] && { log_error "请指定DNS服务器"; return 1; }
    log_step "批量设置DNS: ${dns_server}..."
    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 设置DNS..."
        [[ ${DRY_RUN} -eq 0 ]] && {
            ssh_exec_cmd "${host}" "grep -q 'nameserver ${dns_server}' /etc/resolv.conf || echo 'nameserver ${dns_server}' >> /etc/resolv.conf" || log_warning "[${host}] DNS设置失败"
        }
    done
}

batch_dns_test() {
    local domain="${1:-google.com}"
    log_step "批量DNS解析测试: ${domain}..."
    for host in "${HOST_LIST[@]}"; do
        local result="$(ssh_exec_cmd "${host}" "nslookup ${domain} 2>/dev/null | grep 'Address' | tail -1" 2>/dev/null)"
        if [[ -n "${result}" ]]; then
            log_success "[${host}] ${domain} -> ${result}"
        else
            log_error "[${host}] ${domain} 解析失败"
        fi
    done
}

# ============================================================================
# 批量主机密钥验证
# ============================================================================

batch_verify_host_keys() {
    log_step "批量验证主机SSH密钥..."
    for host in "${HOST_LIST[@]}"; do
        local key_info="$(ssh-keyscan -p ${SSH_PORT} -t rsa,ecdsa,ed25519 "${host}" 2>/dev/null | head -3)"
        if [[ -n "${key_info}" ]]; then
            log_success "[${host}] SSH密钥有效"
            [[ ${VERBOSE} -eq 1 ]] && echo "${key_info}"
        else
            log_warning "[${host}] SSH密钥获取失败"
        fi
    done
}

# ============================================================================
# 批量主机重启管理
# ============================================================================

batch_reboot() {
    log_step "批量重启主机..."
    echo -e "${YELLOW}警告: 即将重启 ${#HOST_LIST[@]} 台主机!${NC}"
    echo -ne "${YELLOW}确认重启? [yes/NO]: ${NC}"
    read -r confirm
    [[ "${confirm}" != "yes" ]] && { log_info "已取消"; return 0; }

    for host in "${HOST_LIST[@]}"; do
        log_info "[${host}] 发送重启命令..."
        [[ ${DRY_RUN} -eq 0 ]] && {
            ssh_exec_cmd "${host}" "shutdown -r +1 'Batch reboot initiated'" || log_warning "[${host}] 重启命令发送失败"
        }
    done

    log_info "等待主机重启..."
    sleep 60

    for host in "${HOST_LIST[@]}"; do
        local retries=0
        while [[ ${retries} -lt 10 ]]; do
            if ssh_exec_cmd "${host}" "uptime" &>/dev/null; then
                log_success "[${host}] 已重启并恢复"
                break
            fi
            ((retries++)) || true
            sleep 10
        done
        [[ ${retries} -ge 10 ]] && log_error "[${host}] 重启后未恢复"
    done
}

# ============================================================================
# 批量操作结果HTML报告
# ============================================================================

generate_html_report() {
    log_step "生成HTML批量操作报告..."
    local report_file="${RESULT_DIR}/batch_report_${TIMESTAMP}.html"

    cat > "${report_file}" << REPORT_HEAD
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <title>批量操作报告 - ${TIMESTAMP}</title>
    <style>
        body { font-family: 'Segoe UI', sans-serif; margin: 20px; background: #f5f5f5; }
        .container { max-width: 1200px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #333; border-bottom: 2px solid #2196F3; padding-bottom: 10px; }
        table { width: 100%; border-collapse: collapse; margin: 15px 0; }
        th, td { padding: 8px 12px; text-align: left; border-bottom: 1px solid #ddd; }
        th { background: #f5f5f5; }
        .success { color: #4CAF50; }
        .failed { color: #f44336; }
        .warning { color: #FF9800; }
        .stats { display: flex; gap: 20px; margin: 20px 0; }
        .stat-card { background: #f8f9fa; padding: 15px 25px; border-radius: 6px; text-align: center; }
        .stat-card h3 { margin: 0; color: #666; font-size: 14px; }
        .stat-card .value { font-size: 28px; font-weight: bold; margin-top: 5px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>批量操作报告</h1>
        <div class="stats">
            <div class="stat-card"><h3>总主机</h3><div class="value">${STATS[total]:-0}</div></div>
            <div class="stat-card"><h3>成功</h3><div class="value success">${STATS[success]:-0}</div></div>
            <div class="stat-card"><h3>失败</h3><div class="value failed">${STATS[failed]:-0}</div></div>
        </div>
        <table>
            <tr><th>主机</th><th>状态</th><th>输出摘要</th></tr>
REPORT_HEAD

    for host in "${HOST_LIST[@]}"; do
        local result_file="${RESULT_DIR}/${host}.result"
        local status="success"
        local summary=""
        if [[ -f "${result_file}" ]]; then
            summary="$(tail -3 "${result_file}" | head -1 | cut -c1-100)"
            grep -qi "error\|fail\|denied" "${result_file}" && status="failed"
        else
            status="failed"
            summary="(无结果文件)"
        fi
        echo "            <tr><td>${host}</td><td class=\"${status}\">${status}</td><td>${summary}</td></tr>" >> "${report_file}"
    done

    cat >> "${report_file}" << REPORT_FOOT
        </table>
        <p style="color:#999;font-size:12px;margin-top:30px;">报告生成时间: $(date '+%Y-%m-%d %H:%M:%S') | Batch Process Script v${SCRIPT_VERSION}</p>
    </div>
</body>
</html>
REPORT_FOOT

    log_success "HTML报告已生成: ${report_file}"
}

# ============================================================================
# 参数解析
# ============================================================================

show_usage() {
    cat << USAGE
批量处理脚本 v${SCRIPT_VERSION}

用法: bash batch_process.sh --hosts FILE [选项] [操作]

主机清单格式 (hosts.txt):
  192.168.1.10
  192.168.1.11 ssh_port=2222 ansible_user=admin
  [web]
  192.168.1.10
  192.168.1.11
  [db]
  192.168.1.20
  [web:vars]
  ansible_user=deploy

操作:
  --exec CMD             批量执行命令
  --exec-script FILE     批量执行脚本
  --copy-local FILE DIR  批量分发本地文件到远程
  --copy-remote FILE DIR 批量收集远程文件到本地
  --rsync SRC DST        批量RSYNC同步
  --install PKG          批量安装软件包
  --update               批量更新系统
  --remove PKG           批量卸载软件包
  --service ACT SVC      批量服务管理 (start/stop/restart/status)
  --user-add USER        批量创建用户
  --user-del USER        批量删除用户
  --check                批量系统巡检
  --monitor              批量系统监控
  --security-check       批量安全检查
  --collect-logs [PATH]  批量日志收集
  --sync-config SRC DST  批量配置同步
  --docker-ps            批量查看Docker容器
  --docker-pull IMAGE    批量拉取Docker镜像
  --docker-cleanup       批量清理Docker资源
  --disk-usage           批量检查磁盘使用
  --find-large [SIZE]    批量查找大文件
  --network-info         批量获取网络信息
  --port-check PORT      批量检查端口
  --ping-test            批量Ping测试
  --process-list [PAT]   批量查看进程
  --system-info          批量收集系统信息
  --cron-list            批量列出Cron任务
  --cron-add ENTRY       批量添加Cron任务
  --cron-remove PATTERN  批量删除Cron任务
  --time-sync            批量时间同步
  --deploy-ssh-key [KEY] 批量部署SSH公钥
  --security-update      批量安装安全更新
  --backup-configs [DIR] 批量备份配置文件
  --connectivity-report  生成连通性报告
  --html-report          生成HTML操作报告
  --reboot               批量重启主机
  --asset-inventory       批量主机资产登记
  --compliance-check      批量合规检查
  --analyze-logs [PATH]   批量日志分析
  --check-certs           批量SSL证书检查
  --check-sysctl [PARAM]  批量内核参数检查
  --config-diff PATH      批量配置差异检测
  --load-check            批量负载检查

选项:
  --hosts FILE       主机清单文件 (必须)
  --group GROUP      仅操作指定组
  --filter PATTERN   过滤主机名
  --user USER        SSH用户 (默认: root)
  --port PORT        SSH端口 (默认: 22)
  --key FILE         SSH密钥文件
  --parallel N       并发数 (默认: 10)
  --timeout SECS     命令超时 (默认: 60)
  --dry-run          模拟运行
  --verbose          详细输出
  --help             显示帮助
  --version          显示版本

支持的操作系统:
  CentOS/RHEL, Ubuntu/Debian, Alpine, Arch Linux, openSUSE
USAGE
}

parse_args() {
    [[ $# -eq 0 ]] && { show_usage; exit 0; }
    local action="" action_arg="" action_arg2=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hosts)        INVENTORY_FILE="$2"; shift 2 ;;
            --group)        INVENTORY_GROUP="$2"; shift 2 ;;
            --filter)       HOST_FILTER="$2"; shift 2 ;;
            --user)         SSH_USER="$2"; shift 2 ;;
            --port)         SSH_PORT="$2"; shift 2 ;;
            --key)          SSH_KEY="$2"; shift 2 ;;
            --parallel)     PARALLEL="$2"; shift 2 ;;
            --timeout)      COMMAND_TIMEOUT="$2"; shift 2 ;;
            --dry-run)      DRY_RUN=1; shift ;;
            --verbose)      VERBOSE=1; shift ;;
            --exec)         action="exec"; action_arg="$2"; shift 2 ;;
            --exec-script)  action="exec_script"; action_arg="$2"; shift 2 ;;
            --copy-local)   action="copy_local"; action_arg="$2"; action_arg2="$3"; shift 3 ;;
            --copy-remote)  action="copy_remote"; action_arg="$2"; action_arg2="$3"; shift 3 ;;
            --rsync)        action="rsync"; action_arg="$2"; action_arg2="$3"; shift 3 ;;
            --install)      action="install"; action_arg="$2"; shift 2 ;;
            --update)       action="update"; shift ;;
            --remove)       action="remove"; action_arg="$2"; shift 2 ;;
            --service)      action="service"; action_arg="$2"; action_arg2="$3"; shift 3 ;;
            --user-add)     action="user_add"; action_arg="$2"; shift 2 ;;
            --user-del)     action="user_del"; action_arg="$2"; shift 2 ;;
            --check)        action="check"; shift ;;
            --monitor)      action="monitor"; shift ;;
            --security-check) action="security_check"; shift ;;
            --collect-logs) action="collect_logs"; action_arg="${2:-/var/log}"; [[ $# -gt 1 ]] && shift 2 || shift ;;
            --sync-config)  action="sync_config"; action_arg="$2"; action_arg2="$3"; shift 3 ;;
            --docker-ps)    action="docker_ps"; shift ;;
            --docker-pull)  action="docker_pull"; action_arg="$2"; shift 2 ;;
            --docker-cleanup) action="docker_cleanup"; shift ;;
            --disk-usage)   action="disk_usage"; shift ;;
            --find-large)   action="find_large"; action_arg="${2:-100M}"; [[ $# -gt 1 && ! "$2" =~ ^-- ]] && shift 2 || shift ;;
            --network-info) action="network_info"; shift ;;
            --port-check)   action="port_check"; action_arg="$2"; shift 2 ;;
            --ping-test)    action="ping_test"; shift ;;
            --process-list) action="process_list"; action_arg="${2:-}"; [[ $# -gt 1 && ! "$2" =~ ^-- ]] && shift 2 || shift ;;
            --system-info)  action="system_info"; shift ;;
            --cron-list)    action="cron_list"; shift ;;
            --cron-add)     action="cron_add"; action_arg="$2"; shift 2 ;;
            --cron-remove)  action="cron_remove"; action_arg="$2"; shift 2 ;;
            --time-sync)    action="time_sync"; shift ;;
            --deploy-ssh-key) action="deploy_ssh_key"; action_arg="${2:-${HOME}/.ssh/id_rsa.pub}"; [[ $# -gt 1 && ! "$2" =~ ^-- ]] && shift 2 || shift ;;
            --security-update) action="security_update"; shift ;;
            --backup-configs) action="backup_configs"; action_arg="${2:-/tmp/config_backup_${TIMESTAMP}}"; [[ $# -gt 1 && ! "$2" =~ ^-- ]] && shift 2 || shift ;;
            --connectivity-report) action="connectivity_report"; shift ;;
            --html-report)  action="html_report"; shift ;;
            --reboot)       action="reboot"; shift ;;
            --asset-inventory) action="asset_inventory"; shift ;;
            --compliance-check) action="compliance_check"; shift ;;
            --analyze-logs) action="analyze_logs"; action_arg="${2:-/var/log/syslog}"; [[ $# -gt 1 && ! "$2" =~ ^-- ]] && shift 2 || shift ;;
            --check-certs)  action="check_certs"; shift ;;
            --check-sysctl) action="check_sysctl"; action_arg="${2:-}"; [[ $# -gt 1 && ! "$2" =~ ^-- ]] && shift 2 || shift ;;
            --config-diff)  action="config_diff"; action_arg="$2"; shift 2 ;;
            --load-check)   action="load_check"; shift ;;
            --help|-h)      show_usage; exit 0 ;;
            --version|-v)   echo "v${SCRIPT_VERSION}"; exit 0 ;;
            *)              log_error "未知选项: $1"; show_usage; exit 1 ;;
        esac
    done

    [[ -z "${INVENTORY_FILE}" ]] && die "必须指定主机清单文件 (--hosts)"
    parse_inventory "${INVENTORY_FILE}"
    filter_by_group
    filter_hosts
    [[ ${#HOST_LIST[@]} -eq 0 ]] && die "没有可操作的主机"

    print_banner
    log_info "目标主机: ${#HOST_LIST[@]}台"

    case "${action}" in
        exec)          batch_exec "${action_arg}" ;;
        exec_script)   for host in "${HOST_LIST[@]}"; do ssh_exec_script "${host}" "${action_arg}"; done ;;
        copy_local)    batch_copy_to_remote "${action_arg}" "${action_arg2}" ;;
        copy_remote)   batch_copy_from_remote "${action_arg}" "${action_arg2}" ;;
        rsync)         batch_rsync_to_remote "${action_arg}" "${action_arg2}" ;;
        install)       batch_install "${action_arg}" ;;
        update)        batch_update ;;
        remove)        batch_remove "${action_arg}" ;;
        service)       batch_service "${action_arg}" "${action_arg2}" ;;
        user_add)      batch_user_add "${action_arg}" ;;
        user_del)      batch_user_del "${action_arg}" ;;
        check)         batch_check ;;
        monitor)       batch_monitor ;;
        security_check) batch_security_check ;;
        collect_logs)  batch_collect_logs "${action_arg}" ;;
        sync_config)   batch_sync_config "${action_arg}" "${action_arg2}" ;;
        docker_ps)     batch_docker_ps ;;
        docker_pull)   batch_docker_pull "${action_arg}" ;;
        docker_cleanup) batch_docker_cleanup ;;
        disk_usage)    batch_disk_usage ;;
        find_large)    batch_find_large_files "${action_arg}" ;;
        network_info)  batch_network_info ;;
        port_check)    batch_port_check "${action_arg}" ;;
        ping_test)     batch_ping_test ;;
        process_list)  batch_process_list "${action_arg}" ;;
        system_info)   batch_system_info ;;
        cron_list)     batch_cron_list ;;
        cron_add)      batch_cron_add "${action_arg}" ;;
        cron_remove)   batch_cron_remove "${action_arg}" ;;
        time_sync)     batch_time_sync ;;
        deploy_ssh_key) batch_deploy_ssh_key "${action_arg}" ;;
        security_update) batch_security_update ;;
        backup_configs) batch_backup_configs "${action_arg}" ;;
        connectivity_report) batch_connectivity_report ;;
        html_report)   generate_html_report ;;
        reboot)        batch_reboot ;;
        asset_inventory) batch_asset_inventory ;;
        compliance_check) batch_compliance_check ;;
        analyze_logs)  batch_analyze_logs "${action_arg}" ;;
        check_certs)   batch_check_certificates ;;
        check_sysctl)  batch_check_sysctl "${action_arg}" ;;
        config_diff)   batch_config_diff "${action_arg}" ;;
        load_check)    batch_load_check ;;
        *)             die "未指定操作"; ;;
    esac

    batch_summary
}

# ============================================================================
# 脚本入口
# ============================================================================

parse_args "$@"
