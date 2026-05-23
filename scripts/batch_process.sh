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
WHITE='\033[1;37m'; NC='\033[0m'

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
    local action="" action_arg=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hosts)        INVENTORY_FILE="$2"; shift ;;
            --group)        INVENTORY_GROUP="$2"; shift ;;
            --filter)       HOST_FILTER="$2"; shift ;;
            --user)         SSH_USER="$2"; shift ;;
            --port)         SSH_PORT="$2"; shift ;;
            --key)          SSH_KEY="$2"; shift ;;
            --parallel)     PARALLEL="$2"; shift ;;
            --timeout)      COMMAND_TIMEOUT="$2"; shift ;;
            --dry-run)      DRY_RUN=1 ;;
            --verbose)      VERBOSE=1 ;;
            --exec)         action="exec"; action_arg="$2"; shift ;;
            --exec-script)  action="exec_script"; action_arg="$2"; shift ;;
            --copy-local)   action="copy_local"; action_arg="$2"; shift; action_arg2="$2"; shift ;;
            --copy-remote)  action="copy_remote"; action_arg="$2"; shift; action_arg2="$2"; shift ;;
            --rsync)        action="rsync"; action_arg="$2"; shift; action_arg2="$2"; shift ;;
            --install)      action="install"; action_arg="$2"; shift ;;
            --update)       action="update" ;;
            --remove)       action="remove"; action_arg="$2"; shift ;;
            --service)      action="service"; action_arg="$2"; shift; action_arg2="$2"; shift ;;
            --user-add)     action="user_add"; action_arg="$2"; shift ;;
            --user-del)     action="user_del"; action_arg="$2"; shift ;;
            --check)        action="check" ;;
            --monitor)      action="monitor" ;;
            --security-check) action="security_check" ;;
            --collect-logs) action="collect_logs"; action_arg="${2:-/var/log}" ;;
            --sync-config)  action="sync_config"; action_arg="$2"; shift; action_arg2="$2"; shift ;;
            --help|-h)      show_usage; exit 0 ;;
            --version|-v)   echo "v${SCRIPT_VERSION}"; exit 0 ;;
            *)              log_error "未知选项: $1"; show_usage; exit 1 ;;
        esac
        shift
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
        *)             die "未指定操作"; ;;
    esac
}

parse_args "$@"
