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

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --start)        action="start"; action_svc="$2"; shift ;;
            --stop)         action="stop"; action_svc="$2"; shift ;;
            --restart)      action="restart"; action_svc="$2"; shift ;;
            --reload)       action="reload"; action_svc="$2"; shift ;;
            --status)       action="status"; action_svc="$2"; shift ;;
            --info)         action="info"; action_svc="$2"; shift ;;
            --enable)       action="enable"; action_svc="$2"; shift ;;
            --disable)      action="disable"; action_svc="$2"; shift ;;
            --mask)         action="mask"; action_svc="$2"; shift ;;
            --unmask)       action="unmask"; action_svc="$2"; shift ;;
            --log)          action="log"; action_svc="$2"; shift; [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]] && { action_arg="$1"; shift; } ;;
            --follow)       action="follow"; action_svc="$2"; shift ;;
            --health)       action="health"; action_svc="$2"; shift ;;
            --deps)         action="deps"; action_svc="$2"; shift ;;
            --analyze)      action="analyze"; action_svc="$2"; shift ;;
            --limits)       action="limits"; action_svc="$2"; shift; local cpu_q="$2"; shift; local mem_l="$2"; shift ;;
            --list)         action="list" ;;
            --ports)        action="ports" ;;
            --watch)        action="watch"; shift; local watch_svcs=(); while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do watch_svcs+=("$1"); shift; done; set -- "--watch-end" "$@" ;;
            --batch-start)  action="batch_start"; shift; local batch_svcs=("$@"); set -- ;;
            --batch-stop)   action="batch_stop"; shift; local batch_svcs=("$@"); set -- ;;
            --batch-restart) action="batch_restart"; shift; local batch_svcs=("$@"); set -- ;;
            --batch-check)  action="batch_check"; shift; local batch_svcs=("$@"); set -- ;;
            --health-url)   HEALTH_CHECK_URL="$2"; shift ;;
            --health-port)  HEALTH_CHECK_PORT="$2"; shift ;;
            --auto-restart) RESTART_ON_FAIL=1 ;;
            --max-restart)  MAX_RESTART="$2"; shift ;;
            --watch-interval) WATCH_INTERVAL="$2"; shift ;;
            --dry-run)      DRY_RUN=1 ;;
            --verbose)      VERBOSE=1 ;;
            --help|-h)      show_usage; exit 0 ;;
            --version|-v)   echo "v${SCRIPT_VERSION}"; exit 0 ;;
            --watch-end)    ;; # internal marker
            *)              log_error "未知选项: $1"; show_usage; exit 1 ;;
        esac
        shift
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
        *)           show_usage ;;
    esac
}

parse_args "$@"
