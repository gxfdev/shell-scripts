#!/usr/bin/env bash
# ============================================================================
#  服务管理脚本 (Service Manager Script)
#  支持: CentOS/RHEL, Ubuntu/Debian, Alpine, Arch Linux, openSUSE
#  版本: 2.0.0
#  作者: gxfdev
#  仓库: https://github.com/gxfdev/shell-scripts
# ============================================================================
#  功能:
#    1. 服务状态查询与监控
#    2. 服务启停/重启/重载
#    3. 服务自启动管理
#    4. 服务依赖分析
#    5. 服务日志查看
#    6. 服务健康检查
#    7. 服务资源限制配置
#    8. 服务配置管理
#    9. 服务故障自愈
#   10. 服务性能分析
# ============================================================================

set -euo pipefail

SCRIPT_VERSION="2.0.0"
SCRIPT_NAME="service_manager"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="/var/log/service_manager"
LOG_FILE="${LOG_DIR}/service_manager_${TIMESTAMP}.log"
LOCK_FILE="/tmp/service_manager.lock"

DRY_RUN=0
VERBOSE=0
WATCH_MODE=0
WATCH_INTERVAL=5
SERVICE_NAME=""
ACTION=""
HEALTH_CHECK_URL=""
HEALTH_CHECK_PORT=""
RESTART_ON_FAIL=0
MAX_RESTART=3
RESTART_INTERVAL=60

declare -A OS_INFO
declare -A STATS
STATS[total]=0; STATS[running]=0; STATS[stopped]=0; STATS[failed]=0

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
die()         { log "ERROR" "$@"; exit 1; }

print_banner() {
    echo -e "${CYAN}"
    cat << 'BANNER'
  ======================================================================
  =     Service Manager Script v2.0.0                                 =
  =     https://github.com/gxfdev/shell-scripts                       =
  ======================================================================
BANNER
    echo -e "${NC}"
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_INFO[id]="${ID:-unknown}"
        case "${ID}" in
            centos|rhel|rocky|almalinux|ol|fedora) OS_INFO[family]="rhel"; OS_INFO[svc_mgr]="systemd" ;;
            ubuntu|debian|linuxmint)               OS_INFO[family]="debian"; OS_INFO[svc_mgr]="systemd" ;;
            alpine)                                OS_INFO[family]="alpine"; OS_INFO[svc_mgr]="openrc" ;;
            arch|manjaro)                          OS_INFO[family]="arch"; OS_INFO[svc_mgr]="systemd" ;;
            opensuse*)                             OS_INFO[family]="suse"; OS_INFO[svc_mgr]="systemd" ;;
            *)                                     OS_INFO[family]="unknown"; OS_INFO[svc_mgr]="systemd" ;;
        esac
    fi
}

detect_service_manager() {
    if command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]; then
        echo "systemd"
    elif command -v rc-service &>/dev/null && [[ -d /run/openrc ]]; then
        echo "openrc"
    elif command -v service &>/dev/null; then
        echo "sysvinit"
    else
        echo "unknown"
    fi
}

# ============================================================================
# 服务状态查询
# ============================================================================

get_service_status() {
    local service="$1"
    local svc_mgr="$(detect_service_manager)"
    case "${svc_mgr}" in
        systemd)
            local status="$(systemctl is-active "${service}" 2>/dev/null)"
            echo "${status}"
            ;;
        openrc)
            rc-service "${service}" status 2>/dev/null | grep -q "started" && echo "active" || echo "inactive"
            ;;
        sysvinit)
            service "${service}" status 2>/dev/null | grep -qi "running" && echo "active" || echo "inactive"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

get_service_enabled() {
    local service="$1"
    local svc_mgr="$(detect_service_manager)"
    case "${svc_mgr}" in
        systemd) systemctl is-enabled "${service}" 2>/dev/null || echo "disabled" ;;
        openrc)  rc-update show default 2>/dev/null | grep -q "${service}" && echo "enabled" || echo "disabled" ;;
        *)       echo "unknown" ;;
    esac
}

get_service_pid() {
    local service="$1"
    local svc_mgr="$(detect_service_manager)"
    case "${svc_mgr}" in
        systemd) systemctl show "${service}" --property=MainPID --value 2>/dev/null ;;
        openrc)  rc-service "${service}" status 2>/dev/null | grep -oP 'pid \K\d+' ;;
        *)       pgrep -f "${service}" | head -1 ;;
    esac
}

get_service_uptime() {
    local service="$1"
    local svc_mgr="$(detect_service_manager)"
    case "${svc_mgr}" in
        systemd)
            local active_since="$(systemctl show "${service}" --property=ActiveEnterTimestamp --value 2>/dev/null)"
            [[ -n "${active_since}" ]] && echo "${active_since}" || echo "N/A"
            ;;
        *) echo "N/A" ;;
    esac
}

get_service_memory() {
    local service="$1"
    local svc_mgr="$(detect_service_manager)"
    case "${svc_mgr}" in
        systemd) systemctl status "${service}" 2>/dev/null | grep -oP 'Memory: \K[^ ]+' || echo "N/A" ;;
        *)
            local pid="$(get_service_pid "${service}")"
            [[ -n "${pid}" ]] && [[ "${pid}" != "0" ]] && ps -p "${pid}" -o rss= 2>/dev/null | awk '{printf "%.1fMB", $1/1024}' || echo "N/A"
            ;;
    esac
}

get_service_cpu() {
    local service="$1"
    local pid="$(get_service_pid "${service}")"
    [[ -n "${pid}" ]] && [[ "${pid}" != "0" ]] && ps -p "${pid}" -o %cpu= 2>/dev/null | xargs || echo "N/A"
}

# ============================================================================
# 服务操作
# ============================================================================

svc_start() {
    local service="$1"
    log_step "启动服务: ${service}"
    [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟运行] 启动 ${service}"; return 0; }

    local svc_mgr="$(detect_service_manager)"
    case "${svc_mgr}" in
        systemd) systemctl start "${service}" ;;
        openrc)  rc-service "${service}" start ;;
        sysvinit) service "${service}" start ;;
    esac

    sleep 1
    local status="$(get_service_status "${service}")"
    if [[ "${status}" == "active" ]]; then
        log_success "服务 ${service} 已启动"
    else
        log_error "服务 ${service} 启动失败"
        [[ ${VERBOSE} -eq 1 ]] && show_service_log "${service}" 20
        return 1
    fi
}

svc_stop() {
    local service="$1"
    log_step "停止服务: ${service}"
    [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟运行] 停止 ${service}"; return 0; }

    local svc_mgr="$(detect_service_manager)"
    case "${svc_mgr}" in
        systemd) systemctl stop "${service}" ;;
        openrc)  rc-service "${service}" stop ;;
        sysvinit) service "${service}" stop ;;
    esac

    sleep 1
    local status="$(get_service_status "${service}")"
    if [[ "${status}" != "active" ]]; then
        log_success "服务 ${service} 已停止"
    else
        log_warning "服务 ${service} 可能未完全停止"
        return 1
    fi
}

svc_restart() {
    local service="$1"
    log_step "重启服务: ${service}"
    [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟运行] 重启 ${service}"; return 0; }

    local svc_mgr="$(detect_service_manager)"
    case "${svc_mgr}" in
        systemd) systemctl restart "${service}" ;;
        openrc)  rc-service "${service}" restart ;;
        sysvinit) service "${service}" restart ;;
    esac

    sleep 2
    local status="$(get_service_status "${service}")"
    if [[ "${status}" == "active" ]]; then
        log_success "服务 ${service} 已重启"
    else
        log_error "服务 ${service} 重启失败"
        return 1
    fi
}

svc_reload() {
    local service="$1"
    log_step "重载服务: ${service}"
    [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟运行] 重载 ${service}"; return 0; }

    local svc_mgr="$(detect_service_manager)"
    case "${svc_mgr}" in
        systemd) systemctl reload "${service}" 2>/dev/null || systemctl restart "${service}" ;;
        openrc)  rc-service "${service}" reload 2>/dev/null || rc-service "${service}" restart ;;
        sysvinit) service "${service}" reload 2>/dev/null || service "${service}" restart ;;
    esac

    log_success "服务 ${service} 已重载"
}

svc_enable() {
    local service="$1"
    log_step "设置服务自启动: ${service}"
    [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟运行] 启用 ${service}"; return 0; }

    local svc_mgr="$(detect_service_manager)"
    case "${svc_mgr}" in
        systemd) systemctl enable "${service}" ;;
        openrc)  rc-update add "${service}" default ;;
    esac
    log_success "服务 ${service} 已设置自启动"
}

svc_disable() {
    local service="$1"
    log_step "取消服务自启动: ${service}"
    [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟运行] 禁用 ${service}"; return 0; }

    local svc_mgr="$(detect_service_manager)"
    case "${svc_mgr}" in
        systemd) systemctl disable "${service}" ;;
        openrc)  rc-update del "${service}" default ;;
    esac
    log_success "服务 ${service} 已取消自启动"
}

svc_mask() {
    local service="$1"
    log_step "屏蔽服务: ${service}"
    [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟运行] 屏蔽 ${service}"; return 0; }
    systemctl mask "${service}" 2>/dev/null && log_success "服务 ${service} 已屏蔽" || log_error "屏蔽失败"
}

svc_unmask() {
    local service="$1"
    log_step "取消屏蔽: ${service}"
    [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟运行] 取消屏蔽 ${service}"; return 0; }
    systemctl unmask "${service}" 2>/dev/null && log_success "服务 ${service} 已取消屏蔽" || log_error "取消屏蔽失败"
}

# ============================================================================
# 服务详细信息
# ============================================================================

show_service_info() {
    local service="$1"
    local status="$(get_service_status "${service}")"
    local enabled="$(get_service_enabled "${service}")"
    local pid="$(get_service_pid "${service}")"
    local uptime="$(get_service_uptime "${service}")"
    local memory="$(get_service_memory "${service}")"
    local cpu="$(get_service_cpu "${service}")"

    local status_color="${GREEN}"
    [[ "${status}" != "active" ]] && status_color="${RED}"

    echo -e "${CYAN}=== 服务信息: ${service} ===${NC}"
    echo -e "  状态:     ${status_color}${status}${NC}"
    echo -e "  自启动:   $([[ "${enabled}" == "enabled" ]] && echo "${GREEN}enabled${NC}" || echo "${YELLOW}${enabled}${NC}")"
    echo -e "  PID:      ${pid}"
    echo -e "  运行时间: ${uptime}"
    echo -e "  内存:     ${memory}"
    echo -e "  CPU:      ${cpu}%"

    local svc_mgr="$(detect_service_manager)"
    if [[ "${svc_mgr}" == "systemd" ]]; then
        echo -e "\n${WHITE}[Unit信息]${NC}"
        systemctl show "${service}" --property=Description,After,Wants,Requires,Conflicts 2>/dev/null | while read -r line; do
            echo "  ${line}"
        done

        echo -e "\n${WHITE}[服务配置]${NC}"
        systemctl cat "${service}" 2>/dev/null | head -30 | while read -r line; do
            echo "  ${line}"
        done
    fi
}

# ============================================================================
# 服务列表
# ============================================================================

list_services() {
    log_step "列出所有服务..."
    local svc_mgr="$(detect_service_manager)"

    case "${svc_mgr}" in
        systemd)
            echo -e "${CYAN}=== 运行中的服务 ===${NC}"
            systemctl list-units --type=service --state=running --no-pager --no-legend | while read -r name desc; do
                echo -e "  ${GREEN}${name}${NC}  ${DIM}${desc}${NC}"
            done

            echo -e "\n${CYAN}=== 失败的服务 ===${NC}"
            local failed="$(systemctl list-units --type=service --state=failed --no-pager --no-legend)"
            if [[ -n "${failed}" ]]; then
                echo "${failed}" | while read -r name desc; do
                    echo -e "  ${RED}${name}${NC}  ${DIM}${desc}${NC}"
                done
            else
                echo "  (无失败服务)"
            fi

            echo -e "\n${CYAN}=== 已停止的服务 ===${NC}"
            systemctl list-units --type=service --state=exited --no-pager --no-legend | head -20 | while read -r name desc; do
                echo -e "  ${YELLOW}${name}${NC}  ${DIM}${desc}${NC}"
            done
            ;;
        openrc)
            echo -e "${CYAN}=== OpenRC服务 ===${NC}"
            rc-status 2>/dev/null | while read -r line; do
                echo "  ${line}"
            done
            ;;
        *)
            echo -e "${CYAN}=== 服务列表 ===${NC}"
            ls /etc/init.d/ 2>/dev/null | while read -r svc; do
                echo "  ${svc}"
            done
            ;;
    esac
}

list_service_ports() {
    log_step "服务端口映射..."
    echo -e "${CYAN}=== 服务端口映射 ===${NC}"
    printf "%-30s %-10s %-20s %-10s\n" "服务" "端口" "地址" "进程"
    ss -tlnp 2>/dev/null | awk 'NR>1' | while read -r state recv send local remote process; do
        local port="$(echo "${local}" | rev | cut -d: -f1 | rev)"
        local addr="$(echo "${local}" | rev | cut -d: -f2- | rev)"
        local pid_name="$(echo "${process}" | grep -oP 'users:\(\("\K[^"]+' 2>/dev/null || echo "unknown")"
        printf "%-30s %-10s %-20s %-10s\n" "${pid_name}" "${port}" "${addr}" "${pid_name}"
    done
}

# ============================================================================
# 服务日志
# ============================================================================

show_service_log() {
    local service="$1" lines="${2:-50}"
    local svc_mgr="$(detect_service_manager)"

    echo -e "${CYAN}=== ${service} 日志 (最近${lines}行) ===${NC}"
    case "${svc_mgr}" in
        systemd)
            journalctl -u "${service}" -n "${lines}" --no-pager 2>/dev/null || \
            journalctl -u "${service}.service" -n "${lines}" --no-pager 2>/dev/null || \
            echo "  无法获取日志"
            ;;
        openrc)
            local log_files=("/var/log/${service}.log" "/var/log/${service}/${service}.log")
            for lf in "${log_files[@]}"; do
                [[ -f "${lf}" ]] && { tail -"${lines}" "${lf}"; return 0; }
            done
            echo "  日志文件未找到"
            ;;
        *)
            tail -"${lines}" "/var/log/${service}.log" 2>/dev/null || echo "  无法获取日志"
            ;;
    esac
}

follow_service_log() {
    local service="$1"
    local svc_mgr="$(detect_service_manager)"
    case "${svc_mgr}" in
        systemd) journalctl -u "${service}" -f ;;
        openrc)  tail -f "/var/log/${service}.log" 2>/dev/null || tail -f "/var/log/${service}/${service}.log" ;;
        *)       tail -f "/var/log/${service}.log" ;;
    esac
}

# ============================================================================
# 服务健康检查
# ============================================================================

check_service_health() {
    local service="$1"
    log_step "健康检查: ${service}"

    local status="$(get_service_status "${service}")"
    if [[ "${status}" != "active" ]]; then
        log_error "服务 ${service} 未运行 (状态: ${status})"
        [[ ${RESTART_ON_FAIL} -eq 1 ]] && {
            log_info "尝试自动重启..."
            auto_heal_service "${service}"
        }
        return 1
    fi

    local pid="$(get_service_pid "${service}")"
    if [[ -z "${pid}" ]] || [[ "${pid}" == "0" ]]; then
        log_warning "服务 ${service} 运行但无主PID"
        return 1
    fi

    if [[ -n "${HEALTH_CHECK_URL}" ]]; then
        log_info "HTTP健康检查: ${HEALTH_CHECK_URL}"
        local http_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${HEALTH_CHECK_URL}" 2>/dev/null || echo '000')"
        if [[ "${http_code}" =~ ^2 ]]; then
            log_success "HTTP健康检查通过 (状态码: ${http_code})"
        else
            log_error "HTTP健康检查失败 (状态码: ${http_code})"
            [[ ${RESTART_ON_FAIL} -eq 1 ]] && auto_heal_service "${service}"
            return 1
        fi
    fi

    if [[ -n "${HEALTH_CHECK_PORT}" ]]; then
        log_info "端口健康检查: ${HEALTH_CHECK_PORT}"
        if timeout 5 bash -c "echo > /dev/tcp/localhost/${HEALTH_CHECK_PORT}" 2>/dev/null; then
            log_success "端口 ${HEALTH_CHECK_PORT} 可达"
        else
            log_error "端口 ${HEALTH_CHECK_PORT} 不可达"
            [[ ${RESTART_ON_FAIL} -eq 1 ]] && auto_heal_service "${service}"
            return 1
        fi
    fi

    local memory="$(get_service_memory "${service}")"
    local cpu="$(get_service_cpu "${service}")"
    log_success "服务 ${service} 健康 (PID: ${pid}, 内存: ${memory}, CPU: ${cpu}%)"
    return 0
}

# ============================================================================
# 服务故障自愈
# ============================================================================

auto_heal_service() {
    local service="$1"
    local restart_count=0
    local restart_file="/tmp/svc_restart_${service}"

    if [[ -f "${restart_file}" ]]; then
        restart_count="$(cat "${restart_file}" 2>/dev/null)"
    fi

    if [[ ${restart_count} -ge ${MAX_RESTART} ]]; then
        log_error "服务 ${service} 已达到最大重启次数 (${MAX_RESTART}), 停止自动重启"
        log_error "请手动检查服务状态和日志"
        return 1
    fi

    ((restart_count++)) || true
    echo "${restart_count}" > "${restart_file}"

    log_warning "自动重启服务 ${service} (第${restart_count}次, 最大${MAX_RESTART}次)"

    svc_stop "${service}" 2>/dev/null || true
    sleep 3
    svc_start "${service}"

    sleep 5
    local new_status="$(get_service_status "${service}")"
    if [[ "${new_status}" == "active" ]]; then
        log_success "服务 ${service} 自动恢复成功"
        echo "0" > "${restart_file}"
    else
        log_error "服务 ${service} 自动恢复失败"
        if [[ ${restart_count} -lt ${MAX_RESTART} ]]; then
            log_info "将在 ${RESTART_INTERVAL}秒 后重试..."
            sleep "${RESTART_INTERVAL}"
            auto_heal_service "${service}"
        fi
    fi
}

# ============================================================================
# 服务依赖分析
# ============================================================================

show_service_deps() {
    local service="$1"
    local svc_mgr="$(detect_service_manager)"

    [[ "${svc_mgr}" != "systemd" ]] && { log_warning "依赖分析仅支持systemd"; return 0; }

    echo -e "${CYAN}=== ${service} 依赖关系 ===${NC}"
    echo -e "\n${WHITE}[依赖的服务]${NC}"
    systemctl list-dependencies "${service}" --no-pager 2>/dev/null | head -20

    echo -e "\n${WHITE}[被依赖的服务]${NC}"
    systemctl list-dependencies --reverse "${service}" --no-pager 2>/dev/null | head -20

    echo -e "\n${WHITE}[冲突的服务]${NC}"
    systemctl show "${service}" --property=Conflicts --value 2>/dev/null | tr ' ' '\n' | grep -v '^$' | while read -r c; do
        echo "  ${c}"
    done
}

# ============================================================================
# 服务资源限制
# ============================================================================

set_service_limits() {
    local service="$1" cpu_quota="$2" memory_limit="$3"
    local svc_mgr="$(detect_service_manager)"
    [[ "${svc_mgr}" != "systemd" ]] && { log_warning "资源限制仅支持systemd"; return 0; }

    log_step "设置服务资源限制: ${service}"
    local override_dir="/etc/systemd/system/${service}.d"
    mkdir -p "${override_dir}"

    local override_content="[Service]
CPUQuota=${cpu_quota}
MemoryMax=${memory_limit}
MemoryHigh=${memory_limit}
"

    [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟运行] 设置资源限制"; echo "${override_content}"; return 0; }

    echo "${override_content}" > "${override_dir}/limits.conf"
    systemctl daemon-reload
    systemctl restart "${service}"

    log_success "资源限制已设置: CPU=${cpu_quota}, 内存=${memory_limit}"
}

# ============================================================================
# 服务监控
# ============================================================================

watch_services() {
    local services=("$@")
    [[ ${#services[@]} -eq 0 ]] && { log_error "未指定监控的服务"; return 1; }

    log_step "监控服务状态 (间隔: ${WATCH_INTERVAL}s)..."
    while true; do
        clear
        echo -e "${CYAN}=== 服务监控 $(date '+%Y-%m-%d %H:%M:%S') ===${NC}"
        printf "%-30s %-10s %-10s %-10s %-15s %-10s\n" "服务" "状态" "PID" "CPU%" "内存" "自启动"

        for svc in "${services[@]}"; do
            local status="$(get_service_status "${svc}")"
            local pid="$(get_service_pid "${svc}")"
            local cpu="$(get_service_cpu "${svc}")"
            local mem="$(get_service_memory "${svc}")"
            local enabled="$(get_service_enabled "${svc}")"

            local status_color="${GREEN}"
            [[ "${status}" != "active" ]] && status_color="${RED}"

            printf "%-30s " "${svc}"
            echo -e "${status_color}${status}${NC}\c"
            printf " %-10s %-10s %-15s %-10s\n" "${pid}" "${cpu}" "${mem}" "${enabled}"
        done

        echo -e "\n${DIM}按Ctrl+C退出${NC}"
        sleep "${WATCH_INTERVAL}"
    done
}

# ============================================================================
# 服务性能分析
# ============================================================================

analyze_service() {
    local service="$1"
    log_step "分析服务性能: ${service}"

    local pid="$(get_service_pid "${service}")"
    if [[ -z "${pid}" ]] || [[ "${pid}" == "0" ]]; then
        log_error "服务 ${service} 未运行"
        return 1
    fi

    echo -e "${CYAN}=== 性能分析: ${service} (PID: ${pid}) ===${NC}"

    echo -e "\n${WHITE}[进程信息]${NC}"
    ps -p "${pid}" -o pid,ppid,user,%cpu,%mem,vsz,rss,stat,start,time,comm 2>/dev/null

    echo -e "\n${WHITE}[线程数]${NC}"
    local threads="$(ls /proc/${pid}/task 2>/dev/null | wc -l)"
    echo "  线程数: ${threads}"

    echo -e "\n${WHITE}[文件描述符]${NC}"
    local fd_count="$(ls /proc/${pid}/fd 2>/dev/null | wc -l)"
    local fd_limit="$(cat /proc/${pid}/limits 2>/dev/null | grep 'open files' | awk '{print $4}')"
    echo "  已打开: ${fd_count} / 限制: ${fd_limit}"
    [[ ${fd_count} -gt $((fd_limit * 80 / 100)) ]] && log_warning "文件描述符使用率超过80%"

    echo -e "\n${WHITE}[网络连接]${NC}"
    ss -tnp 2>/dev/null | grep "pid=${pid}" | awk '{print $1,$4,$5}' | sort | uniq -c | sort -rn | head -10

    echo -e "\n${WHITE}[内存映射]${NC}"
    cat /proc/${pid}/status 2>/dev/null | grep -E 'Vm|Rss' | while read -r line; do
        echo "  ${line}"
    done

    echo -e "\n${WHITE}[IO统计]${NC}"
    cat /proc/${pid}/io 2>/dev/null | while read -r line; do
        echo "  ${line}"
    done
}

# ============================================================================
# 批量服务操作
# ============================================================================

batch_start() {
    local services=("$@")
    log_step "批量启动服务..."
    for svc in "${services[@]}"; do
        svc_start "${svc}" || true
    done
}

batch_stop() {
    local services=("$@")
    log_step "批量停止服务..."
    for svc in "${services[@]}"; do
        svc_stop "${svc}" || true
    done
}

batch_restart() {
    local services=("$@")
    log_step "批量重启服务..."
    for svc in "${services[@]}"; do
        svc_restart "${svc}" || true
    done
}

batch_health_check() {
    local services=("$@")
    log_step "批量健康检查..."
    local all_ok=1
    for svc in "${services[@]}"; do
        if check_service_health "${svc}"; then
            ((STATS[running]++)) || true
        else
            ((STATS[failed]++)) || true
            all_ok=0
        fi
        ((STATS[total]++)) || true
    done

    echo -e "\n${CYAN}=== 健康检查汇总 ===${NC}"
    echo "  总计: ${STATS[total]} | 正常: ${STATS[running]} | 异常: ${STATS[failed]}"
    [[ ${all_ok} -eq 0 ]] && return 1 || return 0
}

# ============================================================================
# 服务高级管理模块
# ============================================================================

svc_snapshot() {
    log_step "创建服务状态快照..."
    local snapshot_file="${LOG_DIR}/service_snapshot_${TIMESTAMP}.txt"
    mkdir -p "${LOG_DIR}" 2>/dev/null || true

    echo "服务状态快照 - $(date)" > "${snapshot_file}"
    echo "主机: ${HOSTNAME}" >> "${snapshot_file}"
    echo "================================" >> "${snapshot_file}"

    case "${OS_FAMILY}" in
        rhel|debian|arch|suse)
            echo "=== 运行中的服务 ===" >> "${snapshot_file}"
            systemctl list-units --type=service --state=running --no-pager >> "${snapshot_file}" 2>/dev/null || true
            echo "" >> "${snapshot_file}"
            echo "=== 失败的服务 ===" >> "${snapshot_file}"
            systemctl list-units --type=service --state=failed --no-pager >> "${snapshot_file}" 2>/dev/null || true
            echo "" >> "${snapshot_file}"
            echo "=== 自启动服务 ===" >> "${snapshot_file}"
            systemctl list-unit-files --type=service --state=enabled --no-pager >> "${snapshot_file}" 2>/dev/null || true
            ;;
        alpine)
            rc-status >> "${snapshot_file}" 2>/dev/null || true
            ;;
    esac

    log_success "快照已保存: ${snapshot_file}"
}

svc_restore_snapshot() {
    local snapshot_file="$1"
    [[ -z "${snapshot_file}" ]] && { log_error "请指定快照文件"; return 1; }
    [[ ! -f "${snapshot_file}" ]] && { log_error "快照文件不存在: ${snapshot_file}"; return 1; }

    log_step "从快照恢复服务状态: ${snapshot_file}..."
    confirm_action "确定要从快照恢复吗？"

    local enabled_svcs="$(grep -A1000 '=== 自启动服务 ===' "${snapshot_file}" | grep '\.service' | awk '{print $1}')"
    for svc in ${enabled_svcs}; do
        svc_enable "${svc}" 2>/dev/null || true
    done

    log_success "快照恢复完成"
}

svc_compare() {
    local svc1="$1" svc2="$2"
    [[ -z "${svc1}" ]] || [[ -z "${svc2}" ]] && { log_error "请指定两个服务进行比较"; return 1; }

    log_step "比较服务: ${svc1} vs ${svc2}..."
    echo -e "${CYAN}=== 服务比较 ===${NC}"
    printf "%-20s %-30s %-30s\n" "属性" "${svc1}" "${svc2}"
    printf "%-20s %-30s %-30s\n" "--------------------" "------------------------------" "------------------------------"

    local s1_status="$(get_service_status "${svc1}")"
    local s2_status="$(get_service_status "${svc2}")"
    printf "%-20s %-30s %-30s\n" "状态" "${s1_status}" "${s2_status}"

    local s1_enabled="$(systemctl is-enabled "${svc1}" 2>/dev/null || echo 'N/A')"
    local s2_enabled="$(systemctl is-enabled "${svc2}" 2>/dev/null || echo 'N/A')"
    printf "%-20s %-30s %-30s\n" "自启动" "${s1_enabled}" "${s2_enabled}"

    local s1_pid="$(systemctl show "${svc1}" -p MainPID --value 2>/dev/null || echo 'N/A')"
    local s2_pid="$(systemctl show "${svc2}" -p MainPID --value 2>/dev/null || echo 'N/A')"
    printf "%-20s %-30s %-30s\n" "PID" "${s1_pid}" "${s2_pid}"

    local s1_mem="$(systemctl show "${svc1}" -p MemoryCurrent --value 2>/dev/null || echo 'N/A')"
    local s2_mem="$(systemctl show "${svc2}" -p MemoryCurrent --value 2>/dev/null || echo 'N/A')"
    [[ "${s1_mem}" != "N/A" ]] && s1_mem="$(numfmt --to=iec ${s1_mem} 2>/dev/null || echo ${s1_mem})"
    [[ "${s2_mem}" != "N/A" ]] && s2_mem="$(numfmt --to=iec ${s2_mem} 2>/dev/null || echo ${s2_mem})"
    printf "%-20s %-30s %-30s\n" "内存" "${s1_mem}" "${s2_mem}"
}

svc_top() {
    log_step "服务资源排行..."
    echo -e "${CYAN}=== 按内存使用排行 (Top 10) ===${NC}"
    systemctl show --type=service --property=Name,MemoryCurrent --no-pager 2>/dev/null | \
        paste - - | sort -t= -k4 -n -r | head -10 | while read -r line; do
        local name="$(echo "${line}" | grep -oP 'Name=\K[^ ]+')"
        local mem="$(echo "${line}" | grep -oP 'MemoryCurrent=\K\d+')"
        [[ -n "${mem}" ]] && [[ "${mem}" != "0" ]] && {
            local human_mem="$(numfmt --to=iec "${mem}" 2>/dev/null || echo "${mem}")"
            printf "  %-40s %s\n" "${name}" "${human_mem}"
        }
    done

    echo ""
    echo -e "${CYAN}=== 按CPU使用排行 (Top 10) ===${NC}"
    ps -eo pid,pcpu,comm --sort=-pcpu | head -11 | while read -r pid cpu comm; do
        [[ "${pid}" == "PID" ]] && continue
        printf "  PID: %-8s CPU: %-6s%% 命令: %s\n" "${pid}" "${cpu}" "${comm}"
    done
}

svc_security_audit() {
    log_step "服务安全审计..."
    local audit_file="${LOG_DIR}/service_audit_${TIMESTAMP}.txt"
    local issues=0

    echo "服务安全审计报告 - $(date)" > "${audit_file}"
    echo "================================" >> "${audit_file}"

    echo "" >> "${audit_file}"
    echo "[1] 以root运行的服务" >> "${audit_file}"
    systemctl show --type=service --property=Name,User --no-pager 2>/dev/null | \
        paste - - | grep 'User=$\|User=root' | while read -r line; do
        local name="$(echo "${line}" | grep -oP 'Name=\K[^ ]+')"
        echo "  [风险] ${name} 以root运行" >> "${audit_file}"
        ((issues++)) || true
    done

    echo "" >> "${audit_file}"
    echo "[2] 失败的服务" >> "${audit_file}"
    systemctl list-units --type=service --state=failed --no-pager 2>/dev/null | grep '\.service' | while read -r line; do
        echo "  [错误] ${line}" >> "${audit_file}"
        ((issues++)) || true
    done

    echo "" >> "${audit_file}"
    echo "[3] 不必要的服务" >> "${audit_file}"
    local unnecessary_services=("telnet" "rsh" "rlogin" "vsftpd" "xinetd" "avahi-daemon" "cups" "bluetooth")
    for svc in "${unnecessary_services[@]}"; do
        if systemctl is-active "${svc}" &>/dev/null; then
            echo "  [警告] ${svc} 正在运行（可能不必要）" >> "${audit_file}"
            ((issues++)) || true
        fi
    done

    echo "" >> "${audit_file}"
    echo "[4] 监听所有接口的服务" >> "${audit_file}"
    ss -tlnp 2>/dev/null | grep '0.0.0.0\|::' | while read -r line; do
        echo "  [信息] ${line}" >> "${audit_file}"
    done

    echo "" >> "${audit_file}"
    echo "发现问题: ${issues}" >> "${audit_file}"

    [[ ${issues} -eq 0 ]] && log_success "服务安全审计通过" || log_warning "审计发现${issues}个问题 (详见: ${audit_file})"
    cat "${audit_file}"
}

svc_dependency_tree() {
    local svc="$1"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }

    log_step "服务依赖树: ${svc}..."
    case "${OS_FAMILY}" in
        rhel|debian|arch|suse)
            systemctl list-dependencies "${svc}" --no-pager 2>/dev/null || \
                log_warning "无法获取依赖树"
            ;;
        alpine)
            rc-depend "${svc}" 2>/dev/null || log_warning "rc-depend不可用"
            ;;
    esac
}

svc_reverse_deps() {
    local svc="$1"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }

    log_step "反向依赖: 依赖 ${svc} 的服务..."
    case "${OS_FAMILY}" in
        rhel|debian|arch|suse)
            systemctl list-dependencies --reverse "${svc}" --no-pager 2>/dev/null || \
                log_warning "无法获取反向依赖"
            ;;
        alpine)
            log_warning "Alpine OpenRC不支持反向依赖查询"
            ;;
    esac
}

svc_config_backup() {
    log_step "备份服务配置文件..."
    local backup_dir="${LOG_DIR}/config_backup_${TIMESTAMP}"
    mkdir -p "${backup_dir}"

    local config_dirs=("/etc/systemd/system" "/etc/init.d" "/etc/default" "/etc/sysconfig")
    for dir in "${config_dirs[@]}"; do
        [[ -d "${dir}" ]] && {
            cp -r "${dir}" "${backup_dir}/" 2>/dev/null || true
            log_info "已备份: ${dir}"
        }
    done

    local archive="${backup_dir}.tar.gz"
    tar czf "${archive}" -C "${backup_dir}" . 2>/dev/null && rm -rf "${backup_dir}"
    log_success "配置已备份: ${archive}"
}

svc_config_verify() {
    local svc="$1"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }

    log_step "验证服务配置: ${svc}..."
    case "${OS_FAMILY}" in
        rhel|debian|arch|suse)
            if [[ -f "/etc/systemd/system/${svc}.service" ]]; then
                systemd-analyze verify "/etc/systemd/system/${svc}.service" 2>&1 || \
                    log_warning "配置验证发现问题"
            elif [[ -f "/lib/systemd/system/${svc}.service" ]]; then
                systemd-analyze verify "/lib/systemd/system/${svc}.service" 2>&1 || \
                    log_warning "配置验证发现问题"
            else
                log_info "未找到systemd单元文件"
            fi
            ;;
        alpine)
            if [[ -f "/etc/init.d/${svc}" ]]; then
                bash -n "/etc/init.d/${svc}" 2>&1 && log_success "脚本语法正确" || log_error "脚本语法错误"
            else
                log_info "未找到init脚本"
            fi
            ;;
    esac
}

svc_config_edit() {
    local svc="$1"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }

    local unit_file=""
    for f in "/etc/systemd/system/${svc}.service" "/lib/systemd/system/${svc}.service" "/usr/lib/systemd/system/${svc}.service"; do
        [[ -f "${f}" ]] && { unit_file="${f}"; break; }
    done

    [[ -z "${unit_file}" ]] && { log_error "未找到服务单元文件"; return 1; }

    log_info "编辑服务配置: ${unit_file}"
    cp "${unit_file}" "${unit_file}.bak.${TIMESTAMP}"
    ${EDITOR:-vi} "${unit_file}"
    systemctl daemon-reload 2>/dev/null || true
    log_success "配置已更新（备份: ${unit_file}.bak.${TIMESTAMP}）"
}

svc_override_create() {
    local svc="$1"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }

    log_step "创建服务覆盖配置: ${svc}..."
    local override_dir="/etc/systemd/system/${svc}.service.d"
    mkdir -p "${override_dir}"

    local override_file="${override_dir}/override.conf"
    if [[ ! -f "${override_file}" ]]; then
        cat > "${override_file}" << OVERRIDE
[Service]
# 在此添加覆盖配置
# Restart=always
# RestartSec=5
# LimitNOFILE=65536
OVERRIDE
        log_success "覆盖配置已创建: ${override_file}"
    else
        log_info "覆盖配置已存在: ${override_file}"
    fi

    systemctl daemon-reload 2>/dev/null || true
}

svc_override_remove() {
    local svc="$1"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }

    log_step "移除服务覆盖配置: ${svc}..."
    local override_dir="/etc/systemd/system/${svc}.service.d"
    if [[ -d "${override_dir}" ]]; then
        rm -rf "${override_dir}"
        systemctl daemon-reload 2>/dev/null || true
        log_success "覆盖配置已移除"
    else
        log_info "无覆盖配置"
    fi
}

svc_restart_history() {
    local svc="$1"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }

    log_step "服务重启历史: ${svc}..."
    journalctl -u "${svc}" --no-pager 2>/dev/null | grep -i "start\|stop\|restart\|fail" | tail -20 || \
        log_info "无历史记录"
}

svc_uptime() {
    local svc="$1"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }

    log_step "服务运行时间: ${svc}..."
    local active_since="$(systemctl show "${svc}" -p ActiveEnterTimestamp --value 2>/dev/null || true)"
    if [[ -n "${active_since}" ]]; then
        echo "  启动时间: ${active_since}"
        local since_epoch="$(date -d "${active_since}" +%s 2>/dev/null || true)"
        if [[ -n "${since_epoch}" ]]; then
            local now_epoch="$(date +%s)"
            local diff=$((now_epoch - since_epoch))
            local days=$((diff / 86400))
            local hours=$(( (diff % 86400) / 3600 ))
            local mins=$(( (diff % 3600) / 60 ))
            echo "  运行时长: ${days}天 ${hours}小时 ${mins}分钟"
        fi
    else
        log_info "服务未运行或信息不可用"
    fi
}

svc_connection_track() {
    local svc="$1"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }

    log_step "服务连接追踪: ${svc}..."
    local pid="$(systemctl show "${svc}" -p MainPID --value 2>/dev/null || true)"
    if [[ -n "${pid}" ]] && [[ "${pid}" != "0" ]]; then
        echo -e "${CYAN}=== TCP连接 ===${NC}"
        ss -tnp 2>/dev/null | grep "pid=${pid}" | head -20 || echo "(无TCP连接)"
        echo ""
        echo -e "${CYAN}=== UDP连接 ===${NC}"
        ss -unp 2>/dev/null | grep "pid=${pid}" | head -20 || echo "(无UDP连接)"
        echo ""
        echo -e "${CYAN}=== 连接统计 ===${NC}"
        ss -tnp 2>/dev/null | grep "pid=${pid}" | awk '{print $1}' | sort | uniq -c | sort -rn
    else
        log_info "服务未运行"
    fi
}

svc_env_show() {
    local svc="$1"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }

    log_step "服务环境变量: ${svc}..."
    local pid="$(systemctl show "${svc}" -p MainPID --value 2>/dev/null || true)"
    if [[ -n "${pid}" ]] && [[ "${pid}" != "0" ]]; then
        cat "/proc/${pid}/environ" 2>/dev/null | tr '\0' '\n' || log_info "无法读取环境变量"
    else
        log_info "服务未运行"
    fi
}

svc_fd_list() {
    local svc="$1"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }

    log_step "服务文件描述符: ${svc}..."
    local pid="$(systemctl show "${svc}" -p MainPID --value 2>/dev/null || true)"
    if [[ -n "${pid}" ]] && [[ "${pid}" != "0" ]]; then
        local fd_count="$(ls /proc/${pid}/fd 2>/dev/null | wc -l)"
        local fd_limit="$(cat /proc/${pid}/limits 2>/dev/null | grep 'open files' | awk '{print $4}')"
        echo "  打开FD数: ${fd_count}"
        echo "  FD限制: ${fd_limit}"
        if [[ -n "${fd_limit}" ]] && [[ ${fd_count} -gt $((fd_limit * 80 / 100)) ]]; then
            log_warning "FD使用率超过80% (${fd_count}/${fd_limit})"
        else
            log_success "FD使用正常 (${fd_count}/${fd_limit})"
        fi

        echo ""
        echo -e "${CYAN}=== FD类型分布 ===${NC}"
        ls -l /proc/${pid}/fd 2>/dev/null | awk '{print $NF}' | grep -oP '(socket|pipe|/dev/|/tmp/|/var/|/etc/|/home/)[^\)]*' | sort | uniq -c | sort -rn | head -10
    else
        log_info "服务未运行"
    fi
}

svc_thread_count() {
    local svc="$1"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }

    log_step "服务线程统计: ${svc}..."
    local pid="$(systemctl show "${svc}" -p MainPID --value 2>/dev/null || true)"
    if [[ -n "${pid}" ]] && [[ "${pid}" != "0" ]]; then
        local threads="$(ls /proc/${pid}/task 2>/dev/null | wc -l)"
        echo "  线程数: ${threads}"

        if [[ ${threads} -gt 100 ]]; then
            log_warning "线程数过多 (${threads})"
        elif [[ ${threads} -gt 50 ]]; then
            log_info "线程数较多 (${threads})"
        else
            log_success "线程数正常 (${threads})"
        fi
    else
        log_info "服务未运行"
    fi
}

svc_systemd_analyze() {
    log_step "Systemd启动分析..."
    echo -e "${CYAN}=== 启动耗时 ===${NC}"
    systemd-analyze 2>/dev/null || echo "(systemd-analyze不可用)"
    echo ""
    echo -e "${CYAN}=== 关键路径 ===${NC}"
    systemd-analyze critical-chain --no-pager 2>/dev/null | head -20 || true
    echo ""
    echo -e "${CYAN}=== 启动耗时排行 (Top 10) ===${NC}"
    systemd-analyze blame --no-pager 2>/dev/null | head -10 || true
}

svc_boot_target() {
    log_step "启动目标管理..."
    echo -e "${CYAN}=== 当前默认目标 ===${NC}"
    systemctl get-default 2>/dev/null || echo "(无法获取)"
    echo ""
    echo -e "${CYAN}=== 可用目标 ===${NC}"
    systemctl list-units --type=target --no-pager 2>/dev/null | head -20 || true
}

svc_set_target() {
    local target="$1"
    [[ -z "${target}" ]] && { log_error "请指定目标 (如: multi-user.target, graphical.target)"; return 1; }

    log_step "设置默认启动目标: ${target}..."
    confirm_action "确定要更改默认启动目标吗？"
    systemctl set-default "${target}" 2>/dev/null && log_success "默认目标已设置为: ${target}" || log_error "设置失败"
}

svc_failed_list() {
    log_step "列出失败的服务..."
    echo -e "${CYAN}=== 失败的服务 ===${NC}"
    local failed_count="$(systemctl list-units --type=service --state=failed --no-pager 2>/dev/null | grep '\.service' | wc -l)"
    if [[ ${failed_count} -eq 0 ]]; then
        log_success "无失败服务"
    else
        systemctl list-units --type=service --state=failed --no-pager 2>/dev/null
    fi
}

svc_failed_reset() {
    log_step "重置失败服务状态..."
    systemctl reset-failed 2>/dev/null && log_success "失败状态已重置" || log_error "重置失败"
}

svc_timer_list() {
    log_step "列出Systemd Timer..."
    echo -e "${CYAN}=== Systemd Timer ===${NC}"
    systemctl list-timers --all --no-pager 2>/dev/null || log_info "无Timer"
}

svc_socket_list() {
    log_step "列出Systemd Socket..."
    echo -e "${CYAN}=== Systemd Socket ===${NC}"
    systemctl list-units --type=socket --no-pager 2>/dev/null || log_info "无Socket"
}

svc_mount_list() {
    log_step "列出Systemd Mount..."
    echo -e "${CYAN}=== Systemd Mount ===${NC}"
    systemctl list-units --type=mount --no-pager 2>/dev/null || log_info "无Mount"
}

svc_unit_show() {
    local svc="$1"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }

    log_step "显示服务单元详情: ${svc}..."
    systemctl show "${svc}" --no-pager 2>/dev/null || log_error "无法获取单元详情"
}

svc_dropin_show() {
    local svc="$1"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }

    log_step "显示服务Drop-in配置: ${svc}..."
    systemctl cat "${svc}" --no-pager 2>/dev/null || log_info "无Drop-in配置"
}

svc_cgroup_tree() {
    local svc="$1"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }

    log_step "服务Cgroup树: ${svc}..."
    systemd-cgls "system.slice/${svc}.service" 2>/dev/null || systemctl status "${svc}" --no-pager 2>/dev/null || true
}

svc_cgroup_resources() {
    local svc="$1"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }

    log_step "服务Cgroup资源使用: ${svc}..."
    systemctl show "${svc}" -p CPUUsageNSec,MemoryCurrent,MemoryPeak,TasksCurrent,IOReadBytes,IOWriteBytes --no-pager 2>/dev/null || \
        log_info "无法获取Cgroup资源信息"
}

svc_signal_send() {
    local svc="$1" signal="$2"
    [[ -z "${svc}" ]] || [[ -z "${signal}" ]] && { log_error "用法: --signal 服务名 信号"; return 1; }

    log_step "发送信号 ${signal} 到服务 ${svc}..."
    local pid="$(systemctl show "${svc}" -p MainPID --value 2>/dev/null || true)"
    if [[ -n "${pid}" ]] && [[ "${pid}" != "0" ]]; then
        kill -"${signal}" "${pid}" && log_success "信号已发送" || log_error "信号发送失败"
    else
        log_error "服务未运行"
    fi
}

svc_graceful_stop() {
    local svc="$1" timeout="${2:-30}"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }

    log_step "优雅停止服务: ${svc} (超时: ${timeout}s)..."
    case "${OS_FAMILY}" in
        rhel|debian|arch|suse)
            systemctl stop "${svc}" --timeout="${timeout}" 2>/dev/null && log_success "服务已优雅停止" || {
                log_warning "优雅停止超时，强制终止..."
                systemctl kill "${svc}" 2>/dev/null || true
            }
            ;;
        alpine)
            rc-service "${svc}" stop 2>/dev/null || true
            ;;
    esac
}

svc_reload_or_restart() {
    local svc="$1"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }

    log_step "重载或重启服务: ${svc}..."
    case "${OS_FAMILY}" in
        rhel|debian|arch|suse)
            systemctl reload-or-restart "${svc}" 2>/dev/null && log_success "服务已重载/重启" || log_error "操作失败"
            ;;
        alpine)
            rc-service "${svc}" restart 2>/dev/null || true
            ;;
    esac
}

svc_try_restart() {
    local svc="$1"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }

    log_step "条件重启服务 (仅运行中): ${svc}..."
    case "${OS_FAMILY}" in
        rhel|debian|arch|suse)
            systemctl try-restart "${svc}" 2>/dev/null && log_success "服务已条件重启" || log_info "服务未运行，跳过"
            ;;
        alpine)
            rc-service "${svc}" status &>/dev/null && rc-service "${svc}" restart || log_info "服务未运行"
            ;;
    esac
}

svc_wait_online() {
    local svc="$1" timeout="${2:-60}"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }

    log_step "等待服务上线: ${svc} (超时: ${timeout}s)..."
    local elapsed=0
    while [[ ${elapsed} -lt ${timeout} ]]; do
        if check_service_health "${svc}"; then
            log_success "服务已上线 (${elapsed}s)"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    log_error "服务上线超时 (${timeout}s)"
    return 1
}

svc_startup_order() {
    log_step "分析服务启动顺序..."
    echo -e "${CYAN}=== 启动顺序 ===${NC}"
    systemd-analyze plot 2>/dev/null | grep -oP 'unit="[^\"]+\.service"' | sed 's/unit="//;s/"//' | head -30 || \
        systemctl list-units --type=service --no-pager 2>/dev/null | head -30
}

svc_port_check() {
    local port="$1"
    [[ -z "${port}" ]] && { log_error "请指定端口号"; return 1; }

    log_step "检查端口 ${port} 对应的服务..."
    ss -tlnp 2>/dev/null | grep ":${port} " || netstat -tlnp 2>/dev/null | grep ":${port} " || log_info "端口 ${port} 未被监听"
}

svc_kill_all() {
    local svc="$1"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }

    log_step "终止服务所有进程: ${svc}..."
    confirm_action "确定要终止 ${svc} 的所有进程吗？"
    systemctl kill "${svc}" 2>/dev/null && log_success "所有进程已终止" || log_error "终止失败"
}

svc_log_level() {
    local svc="$1" level="$2"
    [[ -z "${svc}" ]] || [[ -z "${level}" ]] && { log_error "用法: --log-level 服务名 级别(debug/info/notice/warning/err)"; return 1; }

    log_step "设置服务日志级别: ${svc} -> ${level}..."
    systemctl service-log-level "${svc}" "${level}" 2>/dev/null && log_success "日志级别已设置" || log_error "设置失败"
}

svc_env_set() {
    local svc="$1" env_var="$2"
    [[ -z "${svc}" ]] || [[ -z "${env_var}" ]] && { log_error "用法: --env-set 服务名 环境变量(如: KEY=VALUE)"; return 1; }

    log_step "设置服务环境变量: ${svc} -> ${env_var}..."
    local override_dir="/etc/systemd/system/${svc}.service.d"
    mkdir -p "${override_dir}"

    local env_file="${override_dir}/env.conf"
    if [[ ! -f "${env_file}" ]]; then
        echo "[Service]" > "${env_file}"
    fi
    echo "Environment=\"${env_var}\"" >> "${env_file}"

    systemctl daemon-reload 2>/dev/null || true
    log_success "环境变量已设置 (需重启服务生效)"
}

svc_working_dir() {
    local svc="$1" workdir="$2"
    [[ -z "${svc}" ]] || [[ -z "${workdir}" ]] && { log_error "用法: --working-dir 服务名 工作目录"; return 1; }

    log_step "设置服务工作目录: ${svc} -> ${workdir}..."
    local override_dir="/etc/systemd/system/${svc}.service.d"
    mkdir -p "${override_dir}"

    cat > "${override_dir}/workdir.conf" << CONF
[Service]
WorkingDirectory=${workdir}
CONF

    systemctl daemon-reload 2>/dev/null || true
    log_success "工作目录已设置 (需重启服务生效)"
}

svc_restart_policy() {
    local svc="$1" policy="$2" delay="${3:-5}"
    [[ -z "${svc}" ]] || [[ -z "${policy}" ]] && { log_error "用法: --restart-policy 服务名 策略(always/on-failure/no) [延迟秒数]"; return 1; }

    log_step "设置服务重启策略: ${svc} -> ${policy} (延迟: ${delay}s)..."
    local override_dir="/etc/systemd/system/${svc}.service.d"
    mkdir -p "${override_dir}"

    cat > "${override_dir}/restart.conf" << CONF
[Service]
Restart=${policy}
RestartSec=${delay}
CONF

    systemctl daemon-reload 2>/dev/null || true
    log_success "重启策略已设置"
}

svc_html_report() {
    log_step "生成服务管理HTML报告..."
    local report_file="${LOG_DIR}/service_report_${TIMESTAMP}.html"
    mkdir -p "${LOG_DIR}" 2>/dev/null || true

    local total=0 running=0 stopped=0 failed=0
    case "${OS_FAMILY}" in
        rhel|debian|arch|suse)
            total="$(systemctl list-units --type=service --no-pager --no-legend 2>/dev/null | wc -l)"
            running="$(systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | wc -l)"
            failed="$(systemctl list-units --type=service --state=failed --no-pager --no-legend 2>/dev/null | wc -l)"
            stopped=$((total - running - failed))
            ;;
        alpine)
            total="$(rc-status -s 2>/dev/null | wc -l)"
            running="$(rc-status -s 2>/dev/null | grep 'started' | wc -l)"
            stopped="$(rc-status -s 2>/dev/null | grep 'stopped' | wc -l)"
            failed="$(rc-status -s 2>/dev/null | grep 'crashed' | wc -l)"
            ;;
    esac

    cat > "${report_file}" << HTMLEOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<title>服务管理报告 - ${HOSTNAME}</title>
<style>
body{font-family:Arial,sans-serif;margin:20px;background:#f5f5f5}
.container{max-width:1200px;margin:0 auto;background:#fff;padding:20px;border-radius:8px;box-shadow:0 2px 4px rgba(0,0,0,0.1)}
h1{color:#333;border-bottom:2px solid #4CAF50;padding-bottom:10px}
.summary{display:flex;gap:20px;margin:20px 0}
.card{flex:1;padding:15px;border-radius:6px;text-align:center}
.card.total{background:#e3f2fd}
.card.running{background:#e8f5e9}
.card.stopped{background:#fff3e0}
.card.failed{background:#ffebee}
.card h3{margin:0;font-size:2em}
.card p{margin:5px 0 0;color:#666}
table{width:100%;border-collapse:collapse;margin:20px 0}
th,td{padding:10px;text-align:left;border-bottom:1px solid #ddd}
th{background:#4CAF50;color:#fff}
tr:hover{background:#f5f5f5}
.status-running{color:#4CAF50;font-weight:bold}
.status-stopped{color:#FF9800}
.status-failed{color:#f44336;font-weight:bold}
footer{margin-top:20px;text-align:center;color:#999;font-size:0.9em}
</style>
</head>
<body>
<div class="container">
<h1>服务管理报告 - ${HOSTNAME}</h1>
<p>生成时间: $(date '+%Y-%m-%d %H:%M:%S')</p>
<div class="summary">
<div class="card total"><h3>${total}</h3><p>总服务数</p></div>
<div class="card running"><h3>${running}</h3><p>运行中</p></div>
<div class="card stopped"><h3>${stopped}</h3><p>已停止</p></div>
<div class="card failed"><h3>${failed}</h3><p>失败</p></div>
</div>
<h2>服务列表</h2>
<table>
<tr><th>服务名</th><th>状态</th><th>自启动</th><th>PID</th><th>内存</th></tr>
HTMLEOF

    case "${OS_FAMILY}" in
        rhel|debian|arch|suse)
            systemctl list-units --type=service --no-pager --no-legend 2>/dev/null | while read -r name load active sub job; do
                local status_class="status-${active}"
                local enabled="$(systemctl is-enabled "${name}" 2>/dev/null || echo 'unknown')"
                local pid="$(systemctl show "${name}" -p MainPID --value 2>/dev/null || echo '-')"
                local mem="$(systemctl show "${name}" -p MemoryCurrent --value 2>/dev/null || echo '-')"
                [[ "${mem}" != "-" ]] && [[ "${mem}" != "0" ]] && mem="$(numfmt --to=iec "${mem}" 2>/dev/null || echo "${mem}")"
                echo "<tr><td>${name}</td><td class=\"${status_class}\">${active} (${sub})</td><td>${enabled}</td><td>${pid}</td><td>${mem}</td></tr>" >> "${report_file}"
            done
            ;;
        alpine)
            rc-status -s 2>/dev/null | while read -r name status; do
                echo "<tr><td>${name}</td><td>${status}</td><td>-</td><td>-</td><td>-</td></tr>" >> "${report_file}"
            done
            ;;
    esac

    cat >> "${report_file}" << HTMLEOF
</table>
<footer>由 service_manager.sh v${SCRIPT_VERSION} 自动生成</footer>
</div>
</body>
</html>
HTMLEOF

    log_success "HTML报告已生成: ${report_file}"
}

svc_bulk_enable() {
    log_step "批量启用服务自启动..."
    local svcs=("$@")
    for svc in "${svcs[@]}"; do
        svc_enable "${svc}" || true
    done
}

svc_bulk_disable() {
    log_step "批量禁用服务自启动..."
    local svcs=("$@")
    for svc in "${svcs[@]}"; do
        svc_disable "${svc}" || true
    done
}

svc_port_mapping() {
    log_step "服务端口映射..."
    echo -e "${CYAN}=== 服务端口映射 ===${NC}"
    ss -tlnp 2>/dev/null | tail -n +2 | while read -r state recv send local remote process; do
        local port="$(echo "${local}" | rev | cut -d: -f1 | rev)"
        local addr="$(echo "${local}" | rev | cut -d: -f2- | rev)"
        local pid_name="$(echo "${process}" | grep -oP 'users:\(\("\K[^"]+' 2>/dev/null || echo 'unknown')"
        printf "  %-30s %-8s %-20s %s\n" "${pid_name}" "${port}" "${addr}" "${local}"
    done
}

svc_resource_dashboard() {
    log_step "服务资源仪表盘..."
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  服务资源仪表盘 - ${HOSTNAME}${NC}"
    echo -e "${CYAN}========================================${NC}"

    local total_mem="$(free -m | awk '/Mem:/{print $2}')"
    local svc_mem=0
    local running_count=0

    case "${OS_FAMILY}" in
        rhel|debian|arch|suse)
            running_count="$(systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | wc -l)"
            svc_mem="$(systemctl show --type=service --property=MemoryCurrent --no-pager 2>/dev/null | grep -v 'MemoryCurrent=0$\|MemoryCurrent=\[not set\]' | grep -oP '\d+' | paste -sd+ | bc 2>/dev/null || echo '0')"
            ;;
        alpine)
            running_count="$(rc-status -s 2>/dev/null | grep 'started' | wc -l)"
            ;;
    esac

    local svc_mem_mb="$(echo "scale=0; ${svc_mem:-0} / 1048576" | bc 2>/dev/null || echo '0')"
    local mem_pct="$(echo "scale=1; ${svc_mem_mb:-0} * 100 / ${total_mem:-1}" | bc 2>/dev/null || echo '0')"

    echo "  运行服务: ${running_count}"
    echo "  服务内存: ${svc_mem_mb}MB / ${total_mem}MB (${mem_pct}%)"
    echo "  系统负载: $(cat /proc/loadavg | awk '{print $1" "$2" "$3}')"
    echo "  CPU核心: $(nproc)"
    echo -e "${CYAN}========================================${NC}"
}

svc_quick_diag() {
    local svc="$1"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }

    log_step "快速诊断服务: ${svc}..."
    echo -e "${CYAN}=== 快速诊断: ${svc} ===${NC}"

    echo -e "\n${WHITE}[1] 服务状态${NC}"
    systemctl status "${svc}" --no-pager -l 2>/dev/null | head -15 || true

    echo -e "\n${WHITE}[2] 最近日志${NC}"
    journalctl -u "${svc}" --no-pager -n 10 2>/dev/null || true

    echo -e "\n${WHITE}[3] 进程信息${NC}"
    local pid="$(systemctl show "${svc}" -p MainPID --value 2>/dev/null || true)"
    if [[ -n "${pid}" ]] && [[ "${pid}" != "0" ]]; then
        ps -fp "${pid}" 2>/dev/null || true
        echo ""
        echo "FD数: $(ls /proc/${pid}/fd 2>/dev/null | wc -l)"
        echo "线程数: $(ls /proc/${pid}/task 2>/dev/null | wc -l)"
        echo "内存: $(cat /proc/${pid}/status 2>/dev/null | grep VmRSS || echo 'N/A')"
    else
        echo "服务未运行"
    fi

    echo -e "\n${WHITE}[4] 端口监听${NC}"
    ss -tlnp 2>/dev/null | grep "pid=${pid}" || echo "(无监听端口)"

    echo -e "\n${WHITE}[5] 配置验证${NC}"
    svc_config_verify "${svc}" || true
}

svc_systemd_env() {
    log_step "显示Systemd环境变量..."
    systemctl show-environment --no-pager 2>/dev/null || log_info "无法获取"
}

svc_systemd_version() {
    log_step "Systemd版本信息..."
    systemctl --version 2>/dev/null || log_info "systemctl不可用"
}

svc_daemon_reload() {
    log_step "重新加载Systemd守护进程..."
    systemctl daemon-reload 2>/dev/null && log_success "守护进程已重新加载" || log_error "重新加载失败"
}

svc_list_templates() {
    log_step "列出Systemd模板..."
    echo -e "${CYAN}=== Systemd模板 ===${NC}"
    find /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system -name '*@.service' 2>/dev/null | sort | while read -r f; do
        echo "  $(basename "${f}")"
    done
}

svc_instance_list() {
    local template="$1"
    [[ -z "${template}" ]] && { log_error "请指定模板名 (如: user@)"; return 1; }

    log_step "列出模板实例: ${template}..."
    systemctl list-units "${template}*" --no-pager 2>/dev/null || log_info "无实例"
}

# ============================================================================
# 参数解析
# ============================================================================

show_usage() {
    cat << USAGE
服务管理脚本 v${SCRIPT_VERSION}

用法: bash service_manager.sh [选项] [操作] [服务名...]

操作:
  --start SVC          启动服务
  --stop SVC           停止服务
  --restart SVC        重启服务
  --reload SVC         重载服务配置
  --status SVC         查看服务状态
  --info SVC           查看服务详细信息
  --enable SVC         设置服务自启动
  --disable SVC        取消服务自启动
  --mask SVC           屏蔽服务
  --unmask SVC         取消屏蔽
  --log SVC [N]        查看服务日志 (默认50行)
  --follow SVC         实时跟踪服务日志
  --health SVC         健康检查
  --deps SVC           依赖分析
  --analyze SVC        性能分析
  --limits SVC CPU MEM 设置资源限制 (如: 200% 512M)
  --list               列出所有服务
  --ports              列出服务端口映射
  --watch SVC...       监控服务状态
  --batch-start        批量启动
  --batch-stop         批量停止
  --batch-restart      批量重启
  --batch-check        批量健康检查
  --snapshot           创建服务状态快照
  --restore-snap FILE  从快照恢复
  --compare SVC1 SVC2  比较两个服务
  --top                服务资源排行
  --security-audit     服务安全审计
  --dep-tree SVC       服务依赖树
  --reverse-deps SVC   反向依赖查询
  --config-backup      备份服务配置
  --config-verify SVC  验证服务配置
  --config-edit SVC    编辑服务配置
  --override-create SVC 创建覆盖配置
  --override-remove SVC 移除覆盖配置
  --restart-history SVC 重启历史
  --uptime SVC         服务运行时间
  --conn-track SVC     连接追踪
  --env-show SVC       显示环境变量
  --fd-list SVC        文件描述符列表
  --thread-count SVC   线程统计
  --systemd-analyze    Systemd启动分析
  --boot-target        启动目标管理
  --set-target TARGET  设置启动目标
  --failed-list        列出失败服务
  --failed-reset       重置失败状态
  --timer-list         列出Timer
  --socket-list        列出Socket
  --mount-list         列出Mount
  --unit-show SVC      显示单元详情
  --dropin-show SVC    显示Drop-in配置
  --cgroup-tree SVC    Cgroup树
  --cgroup-res SVC     Cgroup资源
  --signal SVC SIG     发送信号
  --graceful-stop SVC  优雅停止
  --reload-or-restart SVC 重载或重启
  --try-restart SVC    条件重启
  --wait-online SVC    等待服务上线
  --startup-order      启动顺序分析
  --port-check PORT    端口检查
  --kill-all SVC       终止所有进程
  --log-level SVC LVL  设置日志级别
  --env-set SVC VAR    设置环境变量
  --working-dir SVC DIR 设置工作目录
  --restart-policy SVC POLICY 设置重启策略
  --html-report        生成HTML报告
  --bulk-enable SVC... 批量启用自启动
  --bulk-disable SVC... 批量禁用自启动
  --port-mapping       端口映射
  --resource-dashboard 资源仪表盘
  --quick-diag SVC     快速诊断
  --systemd-env        Systemd环境变量
  --systemd-version    Systemd版本
  --daemon-reload      重载守护进程
  --list-templates     列出模板
  --instance-list TPL  列出模板实例

选项:
  --health-url URL     HTTP健康检查URL
  --health-port PORT   端口健康检查
  --auto-restart       故障自动重启
  --max-restart N      最大重启次数 (默认3)
  --watch-interval N   监控间隔秒数 (默认5)
  --dry-run            模拟运行
  --verbose            详细输出
  --help               显示帮助
  --version            显示版本

支持的操作系统:
  CentOS/RHEL (systemd), Ubuntu/Debian (systemd),
  Alpine (OpenRC), Arch Linux (systemd), openSUSE (systemd)
USAGE
}

parse_args() {
    [[ $# -eq 0 ]] && { show_usage; exit 0; }
    local action="" action_svc="" action_arg=""
    local cpu_q="" mem_l=""
    local -a watch_svcs=() batch_svcs=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --start)        action="start"; action_svc="$2"; shift 2 ;;
            --stop)         action="stop"; action_svc="$2"; shift 2 ;;
            --restart)      action="restart"; action_svc="$2"; shift 2 ;;
            --reload)       action="reload"; action_svc="$2"; shift 2 ;;
            --status)       action="status"; action_svc="$2"; shift 2 ;;
            --info)         action="info"; action_svc="$2"; shift 2 ;;
            --enable)       action="enable"; action_svc="$2"; shift 2 ;;
            --disable)      action="disable"; action_svc="$2"; shift 2 ;;
            --mask)         action="mask"; action_svc="$2"; shift 2 ;;
            --unmask)       action="unmask"; action_svc="$2"; shift 2 ;;
            --log)
                action="log"; action_svc="$2"; shift 2
                if [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; then
                    action_arg="$1"; shift
                fi
                ;;
            --follow)       action="follow"; action_svc="$2"; shift 2 ;;
            --health)       action="health"; action_svc="$2"; shift 2 ;;
            --deps)         action="deps"; action_svc="$2"; shift 2 ;;
            --analyze)      action="analyze"; action_svc="$2"; shift 2 ;;
            --limits)       action="limits"; action_svc="$2"; cpu_q="$3"; mem_l="$4"; shift 4 ;;
            --list)         action="list"; shift ;;
            --ports)        action="ports"; shift ;;
            --watch)
                action="watch"; shift
                while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
                    watch_svcs+=("$1"); shift
                done
                ;;
            --batch-start)  action="batch_start"; shift; while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do batch_svcs+=("$1"); shift; done ;;
            --batch-stop)   action="batch_stop"; shift; while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do batch_svcs+=("$1"); shift; done ;;
            --batch-restart) action="batch_restart"; shift; while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do batch_svcs+=("$1"); shift; done ;;
            --batch-check)  action="batch_check"; shift; while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do batch_svcs+=("$1"); shift; done ;;
            --snapshot)     action="snapshot"; shift ;;
            --restore-snap) action="restore_snap"; action_arg="$2"; shift 2 ;;
            --compare)      action="compare"; action_svc="$2"; action_arg="$3"; shift 3 ;;
            --top)          action="top"; shift ;;
            --security-audit) action="security_audit"; shift ;;
            --dep-tree)     action="dep_tree"; action_svc="$2"; shift 2 ;;
            --reverse-deps) action="reverse_deps"; action_svc="$2"; shift 2 ;;
            --config-backup) action="config_backup"; shift ;;
            --config-verify) action="config_verify"; action_svc="$2"; shift 2 ;;
            --config-edit)  action="config_edit"; action_svc="$2"; shift 2 ;;
            --override-create) action="override_create"; action_svc="$2"; shift 2 ;;
            --override-remove) action="override_remove"; action_svc="$2"; shift 2 ;;
            --restart-history) action="restart_history"; action_svc="$2"; shift 2 ;;
            --uptime)       action="uptime"; action_svc="$2"; shift 2 ;;
            --conn-track)   action="conn_track"; action_svc="$2"; shift 2 ;;
            --env-show)     action="env_show"; action_svc="$2"; shift 2 ;;
            --fd-list)      action="fd_list"; action_svc="$2"; shift 2 ;;
            --thread-count) action="thread_count"; action_svc="$2"; shift 2 ;;
            --systemd-analyze) action="systemd_analyze"; shift ;;
            --boot-target)  action="boot_target"; shift ;;
            --set-target)   action="set_target"; action_arg="$2"; shift 2 ;;
            --failed-list)  action="failed_list"; shift ;;
            --failed-reset) action="failed_reset"; shift ;;
            --timer-list)   action="timer_list"; shift ;;
            --socket-list)  action="socket_list"; shift ;;
            --mount-list)   action="mount_list"; shift ;;
            --unit-show)    action="unit_show"; action_svc="$2"; shift 2 ;;
            --dropin-show)  action="dropin_show"; action_svc="$2"; shift 2 ;;
            --cgroup-tree)  action="cgroup_tree"; action_svc="$2"; shift 2 ;;
            --cgroup-res)   action="cgroup_res"; action_svc="$2"; shift 2 ;;
            --signal)       action="signal"; action_svc="$2"; action_arg="$3"; shift 3 ;;
            --graceful-stop) action="graceful_stop"; action_svc="$2"; shift 2 ;;
            --reload-or-restart) action="reload_or_restart"; action_svc="$2"; shift 2 ;;
            --try-restart)  action="try_restart"; action_svc="$2"; shift 2 ;;
            --wait-online)  action="wait_online"; action_svc="$2"; shift 2 ;;
            --startup-order) action="startup_order"; shift ;;
            --port-check)   action="port_check_svc"; action_arg="$2"; shift 2 ;;
            --kill-all)     action="kill_all"; action_svc="$2"; shift 2 ;;
            --log-level)    action="log_level"; action_svc="$2"; action_arg="$3"; shift 3 ;;
            --env-set)      action="env_set"; action_svc="$2"; action_arg="$3"; shift 3 ;;
            --working-dir)  action="working_dir"; action_svc="$2"; action_arg="$3"; shift 3 ;;
            --restart-policy) action="restart_policy"; action_svc="$2"; action_arg="$3"; shift 3 ;;
            --html-report)  action="html_report"; shift ;;
            --bulk-enable)  action="bulk_enable"; shift; while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do batch_svcs+=("$1"); shift; done ;;
            --bulk-disable) action="bulk_disable"; shift; while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do batch_svcs+=("$1"); shift; done ;;
            --port-mapping) action="port_mapping"; shift ;;
            --resource-dashboard) action="resource_dashboard"; shift ;;
            --quick-diag)   action="quick_diag"; action_svc="$2"; shift 2 ;;
            --systemd-env)  action="systemd_env"; shift ;;
            --systemd-version) action="systemd_version"; shift ;;
            --daemon-reload) action="daemon_reload"; shift ;;
            --list-templates) action="list_templates"; shift ;;
            --instance-list) action="instance_list"; action_svc="$2"; shift 2 ;;
            --health-url)   HEALTH_CHECK_URL="$2"; shift 2 ;;
            --health-port)  HEALTH_CHECK_PORT="$2"; shift 2 ;;
            --auto-restart) RESTART_ON_FAIL=1; shift ;;
            --max-restart)  MAX_RESTART="$2"; shift 2 ;;
            --watch-interval) WATCH_INTERVAL="$2"; shift 2 ;;
            --dry-run)      DRY_RUN=1; shift ;;
            --verbose)      VERBOSE=1; shift ;;
            --help|-h)      show_usage; exit 0 ;;
            --version|-v)   echo "v${SCRIPT_VERSION}"; exit 0 ;;
            *)              log_error "未知选项: $1"; show_usage; exit 1 ;;
        esac
    done

    print_banner; detect_os

    case "${action}" in
        start)       svc_start "${action_svc}" ;;
        stop)        svc_stop "${action_svc}" ;;
        restart)     svc_restart "${action_svc}" ;;
        reload)      svc_reload "${action_svc}" ;;
        status)      local s="$(get_service_status "${action_svc}")"; echo "${action_svc}: ${s}" ;;
        info)        show_service_info "${action_svc}" ;;
        enable)      svc_enable "${action_svc}" ;;
        disable)     svc_disable "${action_svc}" ;;
        mask)        svc_mask "${action_svc}" ;;
        unmask)      svc_unmask "${action_svc}" ;;
        log)         show_service_log "${action_svc}" "${action_arg:-50}" ;;
        follow)      follow_service_log "${action_svc}" ;;
        health)      check_service_health "${action_svc}" ;;
        deps)        show_service_deps "${action_svc}" ;;
        analyze)     analyze_service "${action_svc}" ;;
        limits)      set_service_limits "${action_svc}" "${cpu_q}" "${mem_l}" ;;
        list)        list_services ;;
        ports)       list_service_ports ;;
        watch)       watch_services "${watch_svcs[@]}" ;;
        batch_start)   batch_start "${batch_svcs[@]}" ;;
        batch_stop)    batch_stop "${batch_svcs[@]}" ;;
        batch_restart) batch_restart "${batch_svcs[@]}" ;;
        batch_check)   batch_health_check "${batch_svcs[@]}" ;;
        snapshot)      svc_snapshot ;;
        restore_snap)  svc_restore_snapshot "${action_arg}" ;;
        compare)       svc_compare "${action_svc}" "${action_arg}" ;;
        top)           svc_top ;;
        security_audit) svc_security_audit ;;
        dep_tree)      svc_dependency_tree "${action_svc}" ;;
        reverse_deps)  svc_reverse_deps "${action_svc}" ;;
        config_backup) svc_config_backup ;;
        config_verify) svc_config_verify "${action_svc}" ;;
        config_edit)   svc_config_edit "${action_svc}" ;;
        override_create) svc_override_create "${action_svc}" ;;
        override_remove) svc_override_remove "${action_svc}" ;;
        restart_history) svc_restart_history "${action_svc}" ;;
        uptime)        svc_uptime "${action_svc}" ;;
        conn_track)    svc_connection_track "${action_svc}" ;;
        env_show)      svc_env_show "${action_svc}" ;;
        fd_list)       svc_fd_list "${action_svc}" ;;
        thread_count)  svc_thread_count "${action_svc}" ;;
        systemd_analyze) svc_systemd_analyze ;;
        boot_target)   svc_boot_target ;;
        set_target)    svc_set_target "${action_arg}" ;;
        failed_list)   svc_failed_list ;;
        failed_reset)  svc_failed_reset ;;
        timer_list)    svc_timer_list ;;
        socket_list)   svc_socket_list ;;
        mount_list)    svc_mount_list ;;
        unit_show)     svc_unit_show "${action_svc}" ;;
        dropin_show)   svc_dropin_show "${action_svc}" ;;
        cgroup_tree)   svc_cgroup_tree "${action_svc}" ;;
        cgroup_res)    svc_cgroup_resources "${action_svc}" ;;
        signal)        svc_signal_send "${action_svc}" "${action_arg}" ;;
        graceful_stop) svc_graceful_stop "${action_svc}" ;;
        reload_or_restart) svc_reload_or_restart "${action_svc}" ;;
        try_restart)   svc_try_restart "${action_svc}" ;;
        wait_online)   svc_wait_online "${action_svc}" ;;
        startup_order) svc_startup_order ;;
        port_check_svc) svc_port_check "${action_arg}" ;;
        kill_all)      svc_kill_all "${action_svc}" ;;
        log_level)     svc_log_level "${action_svc}" "${action_arg}" ;;
        env_set)       svc_env_set "${action_svc}" "${action_arg}" ;;
        working_dir)   svc_working_dir "${action_svc}" "${action_arg}" ;;
        restart_policy) svc_restart_policy "${action_svc}" "${action_arg}" ;;
        html_report)   svc_html_report ;;
        bulk_enable)   svc_bulk_enable "${batch_svcs[@]}" ;;
        bulk_disable)  svc_bulk_disable "${batch_svcs[@]}" ;;
        port_mapping)  svc_port_mapping ;;
        resource_dashboard) svc_resource_dashboard ;;
        quick_diag)    svc_quick_diag "${action_svc}" ;;
        systemd_env)   svc_systemd_env ;;
        systemd_version) svc_systemd_version ;;
        daemon_reload) svc_daemon_reload ;;
        list_templates) svc_list_templates ;;
        instance_list) svc_instance_list "${action_svc}" ;;
        *)           show_usage ;;
    esac
}

# ============================================================================
# 服务配置模板系统
# ============================================================================

svc_template_create_web() {
    local name="$1" port="${2:-80}" root="${3:-/var/www/html}"
    [[ -z "${name}" ]] && { log_error "请指定服务名"; return 1; }

    log_step "创建Web服务模板: ${name}..."
    local unit_file="/etc/systemd/system/${name}.service"

    cat > "${unit_file}" << UNIT
[Unit]
Description=${name} Web Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/nginx -g 'daemon off;'
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload 2>/dev/null || true
    log_success "Web服务模板已创建: ${unit_file}"
}

svc_template_create_app() {
    local name="$1" exec_path="$2" user="${3:-nobody}"
    [[ -z "${name}" ]] || [[ -z "${exec_path}" ]] && { log_error "用法: --template-app 名称 执行路径 [用户]"; return 1; }

    log_step "创建应用服务模板: ${name}..."
    local unit_file="/etc/systemd/system/${name}.service"

    cat > "${unit_file}" << UNIT
[Unit]
Description=${name} Application Service
After=network.target

[Service]
Type=simple
User=${user}
ExecStart=${exec_path}
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload 2>/dev/null || true
    log_success "应用服务模板已创建: ${unit_file}"
}

svc_template_create_docker() {
    local name="$1" image="$2" port="${3:-}"
    [[ -z "${name}" ]] || [[ -z "${image}" ]] && { log_error "用法: --template-docker 名称 镜像 [端口]"; return 1; }

    log_step "创建Docker服务模板: ${name}..."
    local unit_file="/etc/systemd/system/${name}.service"
    local port_opt=""
    [[ -n "${port}" ]] && port_opt="-p ${port}:${port}"

    cat > "${unit_file}" << UNIT
[Unit]
Description=${name} Docker Container
Requires=docker.service
After=docker.service

[Service]
Type=simple
ExecStartPre=-/usr/bin/docker rm -f ${name}
ExecStart=/usr/bin/docker run --name ${name} ${port_opt} ${image}
ExecStop=/usr/bin/docker stop ${name}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload 2>/dev/null || true
    log_success "Docker服务模板已创建: ${unit_file}"
}

svc_service_catalog() {
    log_step "服务目录..."
    echo -e "${CYAN}=== 系统服务目录 ===${NC}"

    local categories=("网络服务" "数据库服务" "Web服务" "文件服务" "安全服务" "系统服务" "监控服务")
    local network_svcs=("nginx" "apache2" "httpd" "haproxy" "keepalived" "dnsmasq" "bind9" "named")
    local db_svcs=("mysql" "mariadb" "postgresql" "redis" "mongodb" "memcached" "etcd")
    local web_svcs=("php-fpm" "gunicorn" "uwsgi" "node" "pm2")
    local file_svcs=("nfs-server" "smbd" "vsftpd" "sshd" "rsync")
    local security_svcs=("firewalld" "ufw" "fail2ban" "clamd" "auditd")
    local system_svcs=("crond" "cron" "rsyslog" "systemd-journald" "dbus" "NetworkManager" "systemd-resolved")
    local monitor_svcs=("prometheus" "grafana" "node_exporter" "zabbix-agent" "telegraf")

    for svc in "${network_svcs[@]}"; do
        systemctl is-active "${svc}" &>/dev/null && log_success "[网络] ${svc}: 运行中" || true
    done
    for svc in "${db_svcs[@]}"; do
        systemctl is-active "${svc}" &>/dev/null && log_success "[数据库] ${svc}: 运行中" || true
    done
    for svc in "${web_svcs[@]}"; do
        systemctl is-active "${svc}" &>/dev/null && log_success "[Web] ${svc}: 运行中" || true
    done
    for svc in "${file_svcs[@]}"; do
        systemctl is-active "${svc}" &>/dev/null && log_success "[文件] ${svc}: 运行中" || true
    done
    for svc in "${security_svcs[@]}"; do
        systemctl is-active "${svc}" &>/dev/null && log_success "[安全] ${svc}: 运行中" || true
    done
    for svc in "${system_svcs[@]}"; do
        systemctl is-active "${svc}" &>/dev/null && log_success "[系统] ${svc}: 运行中" || true
    done
    for svc in "${monitor_svcs[@]}"; do
        systemctl is-active "${svc}" &>/dev/null && log_success "[监控] ${svc}: 运行中" || true
    done
}

svc_auto_heal() {
    local svc="$1" max_attempts="${2:-3}" check_interval="${3:-30}"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }

    log_step "启动服务自愈守护: ${svc} (最大重试: ${max_attempts}, 间隔: ${check_interval}s)..."
    local attempt=0

    while true; do
        if ! systemctl is-active "${svc}" &>/dev/null; then
            ((attempt++)) || true
            if [[ ${attempt} -le ${max_attempts} ]]; then
                log_warning "[${attempt}/${max_attempts}] ${svc} 已停止，尝试重启..."
                svc_restart "${svc}" || true
                sleep ${check_interval}
            else
                log_error "${svc} 重启${max_attempts}次后仍失败，停止自愈"
                return 1
            fi
        else
            attempt=0
            sleep ${check_interval}
        fi
    done
}

svc_export_config() {
    log_step "导出服务配置..."
    local export_dir="${LOG_DIR}/service_export_${TIMESTAMP}"
    mkdir -p "${export_dir}"

    case "${OS_FAMILY}" in
        rhel|debian|arch|suse)
            systemctl list-units --type=service --no-pager > "${export_dir}/services_list.txt" 2>/dev/null || true
            systemctl list-unit-files --type=service --no-pager > "${export_dir}/service_files.txt" 2>/dev/null || true
            for svc in $(systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | awk '{print $1}'); do
                systemctl cat "${svc}" > "${export_dir}/${svc}.conf" 2>/dev/null || true
            done
            ;;
        alpine)
            rc-status -s > "${export_dir}/rc_status.txt" 2>/dev/null || true
            ;;
    esac

    local archive="${export_dir}.tar.gz"
    tar czf "${archive}" -C "${export_dir}" . 2>/dev/null && rm -rf "${export_dir}"
    log_success "配置已导出: ${archive}"
}

# ============================================================================
# 脚本入口
# ============================================================================

parse_args "$@"
