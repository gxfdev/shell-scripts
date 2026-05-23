#!/usr/bin/env bash
# ============================================================================
#  定时任务管理脚本 (Cron Manager Script)
#  支持: Linux (CentOS/Ubuntu/Debian/Alpine/Arch/openSUSE), macOS, Windows WSL/Git Bash
#  版本: 2.1.0
#  作者: gxfdev
#  仓库: https://github.com/gxfdev/shell-scripts
# ============================================================================
#  功能:
#    1. 定时任务CRUD (创建/读取/更新/删除)
#    2. 定时任务模板管理
#    3. 定时任务分组与标签
#    4. 定时任务执行日志
#    5. 定时任务健康检查
#    6. Systemd Timer管理
#    7. 定时任务备份与恢复
#    8. 定时任务冲突检测
#    9. 执行结果通知
#   10. 定时任务可视化时间表
# ============================================================================

set -euo pipefail

SCRIPT_VERSION="2.1.0"
SCRIPT_NAME="cron_manager"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "${SCRIPT_DIR}")/lib"

if [[ -f "${LIB_DIR}/common_lib.sh" ]]; then
    source "${LIB_DIR}/common_lib.sh"
    common_init
else
    echo "[WARN] common_lib.sh not found in ${LIB_DIR}, using fallback" >&2
fi

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="/var/log/cron_manager"
LOG_FILE="${LOG_DIR}/cron_manager_${TIMESTAMP}.log"
BACKUP_DIR="/var/backups/cron_manager"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"
LOCK_FILE="/tmp/cron_manager.lock"

DRY_RUN=0
VERBOSE=0
CRON_USER=""
TASK_NAME=""
TASK_SCHEDULE=""
TASK_COMMAND=""
TASK_GROUP=""
TASK_COMMENT=""
NOTIFY_ON_FAIL=0
NOTIFY_WEBHOOK=""
SYSTEMD_MODE=0

if [[ -z "${RED:-}" ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
    WHITE='\033[1;37m'; NC='\033[0m'; DIM='\033[2m'
fi

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
  =     Cron Manager Script v2.0.0                                    =
  =     https://github.com/gxfdev/shell-scripts                       =
  ======================================================================
BANNER
    echo -e "${NC}"
}

# ============================================================================
# Cron表达式解析与验证
# ============================================================================

validate_cron_expr() {
    local expr="$1"
    local parts=(${expr})
    [[ ${#parts[@]} -lt 5 ]] || [[ ${#parts[@]} -gt 7 ]] && return 1

    local minute="${parts[0]}" hour="${parts[1]}" dom="${parts[2]}" month="${parts[3]}" dow="${parts[4]}"

    for field in "${minute}" "${hour}" "${dom}" "${month}" "${dow}"; do
        [[ "${field}" =~ ^[\*/0-9,\-]+$ ]] || return 1
    done

    [[ "${minute}" != "*" ]] && [[ "${minute}" -lt 0 || "${minute}" -gt 59 ]] 2>/dev/null && return 1
    [[ "${hour}"   != "*" ]] && [[ "${hour}"   -lt 0 || "${hour}"   -gt 23 ]] 2>/dev/null && return 1
    [[ "${dom}"    != "*" ]] && [[ "${dom}"    -lt 1 || "${dom}"    -gt 31 ]] 2>/dev/null && return 1
    [[ "${month}"  != "*" ]] && [[ "${month}"  -lt 1 || "${month}"  -gt 12 ]] 2>/dev/null && return 1
    [[ "${dow}"    != "*" ]] && [[ "${dow}"    -lt 0 || "${dow}"    -gt 7 ]]  2>/dev/null && return 1

    return 0
}

parse_schedule_alias() {
    local alias="$1"
    case "${alias}" in
        @yearly|@annually) echo "0 0 1 1 *" ;;
        @monthly)          echo "0 0 1 * *" ;;
        @weekly)           echo "0 0 * * 0" ;;
        @daily|@midnight)  echo "0 0 * * *" ;;
        @hourly)           echo "0 * * * *" ;;
        @every5min)        echo "*/5 * * * *" ;;
        @every10min)       echo "*/10 * * * *" ;;
        @every15min)       echo "*/15 * * * *" ;;
        @every30min)       echo "*/30 * * * *" ;;
        *)                 echo "${alias}" ;;
    esac
}

cron_to_human() {
    local expr="$1"
    expr="$(parse_schedule_alias "${expr}")"
    local parts=(${expr})
    [[ ${#parts[@]} -lt 5 ]] && { echo "无效表达式"; return; }
    local minute="${parts[0]}" hour="${parts[1]}" dom="${parts[2]}" month="${parts[3]}" dow="${parts[4]}"
    local desc=""

    case "${minute}" in
        *\/*) desc="每隔${minute#*/}分钟" ;;
        *)    desc="第${minute}分钟" ;;
    esac

    case "${hour}" in
        *\/*) desc="${desc}, 每隔${hour#*/}小时" ;;
        *)    [[ "${hour}" != "*" ]] && desc="${desc}, ${hour}时" ;;
    esac

    case "${dom}" in
        *\/*) desc="${desc}, 每隔${dom#*/}天" ;;
        *)    [[ "${dom}" != "*" ]] && desc="${desc}, ${dom}日" ;;
    esac

    case "${month}" in
        *\/*) desc="${desc}, 每隔${month#*/}月" ;;
        *)    [[ "${month}" != "*" ]] && desc="${desc}, ${month}月" ;;
    esac

    case "${dow}" in
        0|7)  desc="${desc}, 周日" ;;
        1)    desc="${desc}, 周一" ;;
        2)    desc="${desc}, 周二" ;;
        3)    desc="${desc}, 周三" ;;
        4)    desc="${desc}, 周四" ;;
        5)    desc="${desc}, 周五" ;;
        6)    desc="${desc}, 周六" ;;
        *)    [[ "${dow}" != "*" ]] && desc="${desc}, 周${dow}" ;;
    esac

    echo "${desc}"
}

next_run_time() {
    local expr="$1"
    expr="$(parse_schedule_alias "${expr}")"
    if command -v python3 &>/dev/null; then
        python3 -c "
from datetime import datetime, timedelta
import re
parts = '${expr}'.split()
if len(parts) >= 5:
    print('下次执行时间需要crontab解析器, 建议安装python-crontab')
" 2>/dev/null || echo "无法计算"
    else
        echo "需要python3计算"
    fi
}

# ============================================================================
# Cron任务管理
# ============================================================================

get_crontab_file() {
    local user="${CRON_USER:-$(whoami)}"
    if [[ "${user}" == "root" ]]; then
        echo "/var/spool/cron/crontabs/root 2>/dev/null || /var/spool/cron/root"
    else
        echo "/var/spool/cron/crontabs/${user} 2>/dev/null || /var/spool/cron/${user}"
    fi
}

list_cron_tasks() {
    log_step "列出定时任务..."
    local user="${CRON_USER:-$(whoami)}"
    echo -e "${CYAN}=== 定时任务列表 (${user}) ===${NC}"

    if [[ "${user}" == "root" ]] && [[ ${EUID} -eq 0 ]]; then
        echo -e "\n${WHITE}[系统Cron任务]${NC}"
        [[ -d /etc/cron.d ]] && for f in /etc/cron.d/*; do
            [[ -f "${f}" ]] && [[ ! "${f}" =~ \.bak$ ]] && {
                echo -e "  ${GREEN}$(basename "${f}")${NC}:"
                grep -v '^#' "${f}" | grep -v '^\s*$' | while read -r line; do
                    echo -e "    ${line}"
                done
            }
        done

        for dir in /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly; do
            [[ -d "${dir}" ]] && {
                local tasks="$(ls -1 "${dir}" 2>/dev/null | grep -v '^\.' | head -20)"
                [[ -n "${tasks}" ]] && {
                    echo -e "\n${WHITE}[$(basename "${dir}")]${NC}"
                    echo "${tasks}" | while read -r t; do
                        [[ -n "${t}" ]] && echo -e "  ${GREEN}${t}${NC}"
                    done
                }
            }
        done
    fi

    echo -e "\n${WHITE}[用户Cron任务 - ${user}]${NC}"
    local crontab_content
    if [[ "${user}" == "$(whoami)" ]]; then
        crontab_content="$(crontab -l 2>/dev/null)" || true
    else
        crontab_content="$(crontab -u "${user}" -l 2>/dev/null)" || true
    fi

    if [[ -n "${crontab_content}" ]]; then
        local idx=0
        echo "${crontab_content}" | while read -r line; do
            [[ "${line}" =~ ^# ]] && { echo -e "  ${DIM}${line}${NC}"; continue; }
            [[ -z "${line}" || "${line}" =~ ^\s*$ ]] && continue
            local schedule="$(echo "${line}" | awk '{print $1,$2,$3,$4,$5}')"
            local command="$(echo "${line}" | awk '{$1=$2=$3=$4=$5=""; print $0}' | sed 's/^ *//')"
            local human="$(cron_to_human "${schedule}")"
            echo -e "  ${GREEN}${schedule}${NC} ${CYAN}${command}${NC}"
            echo -e "    ${DIM}说明: ${human}${NC}"
        done
    else
        echo "  (无任务)"
    fi

    echo -e "\n${WHITE}[Systemd Timers]${NC}"
    systemctl list-timers --all --no-pager 2>/dev/null | head -20 || echo "  (不可用)"
}

add_cron_task() {
    local schedule="${TASK_SCHEDULE}" command="${TASK_COMMAND}" name="${TASK_NAME}" group="${TASK_GROUP}"
    schedule="$(parse_schedule_alias "${schedule}")"

    validate_cron_expr "${schedule}" || die "无效的Cron表达式: ${schedule}"

    log_step "添加定时任务..."
    local user="${CRON_USER:-$(whoami)}"
    local marker_start="# >>> ${name:-cron_task_$(date +%s)} <<<"
    local marker_end="# <<< ${name:-cron_task_$(date +%s)} <<<"
    local comment="${TASK_COMMENT:-${name:-auto task}}"
    local log_redirect=">> ${LOG_DIR}/${name:-task}_\$(date +\%Y\%m\%d).log 2>&1"

    local task_line="${schedule} ${command} ${log_redirect}"

    local wrapper_command="${command}"
    if [[ ${NOTIFY_ON_FAIL} -eq 1 ]] && [[ -n "${NOTIFY_WEBHOOK}" ]]; then
        wrapper_command="${command} || curl -s -X POST '${NOTIFY_WEBHOOK}' -H 'Content-Type: application/json' -d '{\"msgtype\":\"text\",\"text\":{\"content\":\"定时任务失败: ${name} 在 \$(hostname) \"}}'"
        task_line="${schedule} ${wrapper_command} ${log_redirect}"
    fi

    local full_entry="${marker_start}
# 任务: ${comment}
# 分组: ${group:-default}
# 创建: $(date '+%Y-%m-%d %H:%M:%S')
${task_line}
${marker_end}"

    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[模拟运行] 将添加任务:"
        echo "${full_entry}"
        return 0
    fi

    local tmp_cron="$(mktemp)"
    if [[ "${user}" == "$(whoami)" ]]; then
        crontab -l 2>/dev/null > "${tmp_cron}" || true
    else
        crontab -u "${user}" -l 2>/dev/null > "${tmp_cron}" || true
    fi

    echo "" >> "${tmp_cron}"
    echo "${full_entry}" >> "${tmp_cron}"

    if [[ "${user}" == "$(whoami)" ]]; then
        crontab "${tmp_cron}"
    else
        crontab -u "${user}" "${tmp_cron}"
    fi
    rm -f "${tmp_cron}"

    log_success "定时任务已添加: ${comment}"
    log_info "  表达式: ${schedule} ($(cron_to_human "${schedule}"))"
    log_info "  命令: ${command}"
}

remove_cron_task() {
    local name="$1"
    local user="${CRON_USER:-$(whoami)}"
    log_step "删除定时任务: ${name}"

    [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟运行] 将删除任务: ${name}"; return 0; }

    local tmp_cron="$(mktemp)"
    if [[ "${user}" == "$(whoami)" ]]; then
        crontab -l 2>/dev/null > "${tmp_cron}" || true
    else
        crontab -u "${user}" -l 2>/dev/null > "${tmp_cron}" || true
    fi

    local in_block=0
    local new_cron="$(mktemp)"
    while IFS= read -r line; do
        if [[ "${line}" =~ .*">>> ${name} <<<".* ]]; then
            in_block=1
            continue
        fi
        if [[ ${in_block} -eq 1 ]] && [[ "${line}" =~ .*"<<< ${name} <<<".* ]]; then
            in_block=0
            continue
        fi
        [[ ${in_block} -eq 1 ]] && continue
        echo "${line}" >> "${new_cron}"
    done < "${tmp_cron}"

    if [[ "${user}" == "$(whoami)" ]]; then
        crontab "${new_cron}"
    else
        crontab -u "${user}" "${new_cron}"
    fi
    rm -f "${tmp_cron}" "${new_cron}"

    log_success "定时任务已删除: ${name}"
}

update_cron_task() {
    local name="$1" new_schedule="$2" new_command="$3"
    remove_cron_task "${name}"
    TASK_NAME="${name}"; TASK_SCHEDULE="${new_schedule}"; TASK_COMMAND="${new_command}"
    add_cron_task
}

enable_cron_task() {
    local name="$1"
    local user="${CRON_USER:-$(whoami)}"
    log_step "启用定时任务: ${name}"
    [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟运行] 启用: ${name}"; return 0; }

    local tmp_cron="$(mktemp)"
    if [[ "${user}" == "$(whoami)" ]]; then
        crontab -l 2>/dev/null > "${tmp_cron}" || true
    else
        crontab -u "${user}" -l 2>/dev/null > "${tmp_cron}" || true
    fi

    sed -i "s/^#\s*\(.*>>> ${name} <<<\)/\1/" "${tmp_cron}"
    sed -i "/>>> ${name} <<<$/,/<<< ${name} <<<$/ s/^#\s*\([0-9*]/\1/" "${tmp_cron}"

    if [[ "${user}" == "$(whoami)" ]]; then
        crontab "${tmp_cron}"
    else
        crontab -u "${user}" "${tmp_cron}"
    fi
    rm -f "${tmp_cron}"
    log_success "定时任务已启用: ${name}"
}

disable_cron_task() {
    local name="$1"
    local user="${CRON_USER:-$(whoami)}"
    log_step "禁用定时任务: ${name}"
    [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟运行] 禁用: ${name}"; return 0; }

    local tmp_cron="$(mktemp)"
    if [[ "${user}" == "$(whoami)" ]]; then
        crontab -l 2>/dev/null > "${tmp_cron}" || true
    else
        crontab -u "${user}" -l 2>/dev/null > "${tmp_cron}" || true
    fi

    sed -i "/>>> ${name} <<<$/,/<<< ${name} <<<$/ { /^[0-9*]/ s/^/#DISABLED# / }" "${tmp_cron}"

    if [[ "${user}" == "$(whoami)" ]]; then
        crontab "${tmp_cron}"
    else
        crontab -u "${user}" "${tmp_cron}"
    fi
    rm -f "${tmp_cron}"
    log_success "定时任务已禁用: ${name}"
}

# ============================================================================
# Systemd Timer管理
# ============================================================================

add_systemd_timer() {
    local name="${TASK_NAME:-custom_timer}" schedule="${TASK_SCHEDULE}" command="${TASK_COMMAND}"
    [[ ${EUID} -ne 0 ]] && die "Systemd Timer管理需要root权限"

    schedule="$(parse_schedule_alias "${schedule}")"
    local on_calendar=""
    local parts=(${schedule})
    if [[ ${#parts[@]} -ge 5 ]]; then
        local minute="${parts[0]}" hour="${parts[1]}" dom="${parts[2]}" month="${parts[3]}" dow="${parts[4]}"
        on_calendar="*-${month//\*/~}-${dom//\*/~} ${hour//\*/~}:${minute//\*/~}:00"
        [[ "${dow}" != "*" ]] && on_calendar="${dow} ${on_calendar}"
        on_calendar="$(echo "${on_calendar}" | sed 's/~/*/g')"
    fi

    local service_content="[Unit]
Description=${name} service
After=network.target

[Service]
Type=oneshot
ExecStart=${command}
StandardOutput=journal
StandardError=journal
"

    local timer_content="[Unit]
Description=${name} timer

[Timer]
OnCalendar=${on_calendar}
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
"

    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[模拟运行] 创建Systemd Timer:"
        echo "--- /etc/systemd/system/${name}.service ---"
        echo "${service_content}"
        echo "--- /etc/systemd/system/${name}.timer ---"
        echo "${timer_content}"
        return 0
    fi

    echo "${service_content}" > "/etc/systemd/system/${name}.service"
    echo "${timer_content}" > "/etc/systemd/system/${name}.timer"

    systemctl daemon-reload
    systemctl enable "${name}.timer"
    systemctl start "${name}.timer"

    log_success "Systemd Timer已创建: ${name}"
    log_info "  日历: ${on_calendar}"
    systemctl status "${name}.timer" --no-pager 2>/dev/null | head -10
}

remove_systemd_timer() {
    local name="$1"
    [[ ${DRY_RUN} -eq 0 ]] && {
        systemctl stop "${name}.timer" 2>/dev/null || true
        systemctl disable "${name}.timer" 2>/dev/null || true
        rm -f "/etc/systemd/system/${name}.timer" "/etc/systemd/system/${name}.service"
        systemctl daemon-reload
    }
    log_success "Systemd Timer已删除: ${name}"
}

list_systemd_timers() {
    echo -e "${CYAN}=== Systemd Timers ===${NC}"
    systemctl list-timers --all --no-pager 2>/dev/null || echo "  (不可用)"
}

# ============================================================================
# 模板管理
# ============================================================================

save_template() {
    local name="$1" schedule="$2" command="$3"
    mkdir -p "${TEMPLATE_DIR}"
    cat > "${TEMPLATE_DIR}/${name}.tpl" << TPL
SCHEDULE="${schedule}"
COMMAND="${command}"
NAME="${name}"
COMMENT="${TASK_COMMENT:-}"
GROUP="${TASK_GROUP:-}"
NOTIFY_ON_FAIL=${NOTIFY_ON_FAIL}
NOTIFY_WEBHOOK="${NOTIFY_WEBHOOK}"
TPL
    log_success "模板已保存: ${name}"
}

load_template() {
    local name="$1"
    local tpl_file="${TEMPLATE_DIR}/${name}.tpl"
    [[ ! -f "${tpl_file}" ]] && die "模板不存在: ${name}"
    source "${tpl_file}"
    TASK_SCHEDULE="${SCHEDULE}"; TASK_COMMAND="${COMMAND}"; TASK_NAME="${NAME}"
    TASK_COMMENT="${COMMENT:-}"; TASK_GROUP="${GROUP:-}"
    NOTIFY_ON_FAIL="${NOTIFY_ON_FAIL:-0}"; NOTIFY_WEBHOOK="${NOTIFY_WEBHOOK:-}"
    log_info "已加载模板: ${name}"
}

list_templates() {
    echo -e "${CYAN}=== 定时任务模板 ===${NC}"
    if [[ -d "${TEMPLATE_DIR}" ]] && [[ -n "$(ls -A "${TEMPLATE_DIR}" 2>/dev/null)" ]]; then
        for tpl in "${TEMPLATE_DIR}"/*.tpl; do
            [[ -f "${tpl}" ]] || continue
            source "${tpl}"
            echo -e "  ${GREEN}$(basename "${tpl}" .tpl)${NC}: ${SCHEDULE} -> ${COMMAND}"
            unset SCHEDULE COMMAND NAME COMMENT GROUP NOTIFY_ON_FAIL NOTIFY_WEBHOOK
        done
    else
        echo "  (无模板)"
    fi
}

init_default_templates() {
    mkdir -p "${TEMPLATE_DIR}"
    [[ -f "${TEMPLATE_DIR}/system_backup.tpl" ]] && return 0

    cat > "${TEMPLATE_DIR}/system_backup.tpl" << 'TPL'
SCHEDULE="0 2 * * *"
COMMAND="/opt/shell-scripts/auto_backup.sh --all --config-file /etc/backup.cfg"
NAME="system_backup"
COMMENT="每日凌晨2点系统全量备份"
GROUP="backup"
NOTIFY_ON_FAIL=0
NOTIFY_WEBHOOK=""
TPL

    cat > "${TEMPLATE_DIR}/log_cleanup.tpl" << 'TPL'
SCHEDULE="0 3 * * 0"
COMMAND="find /var/log -type f -name '*.gz' -mtime +30 -delete && journalctl --vacuum-time=7d"
NAME="log_cleanup"
COMMENT="每周日凌晨3点清理过期日志"
GROUP="maintenance"
NOTIFY_ON_FAIL=0
NOTIFY_WEBHOOK=""
TPL

    cat > "${TEMPLATE_DIR}/system_update.tpl" << 'TPL'
SCHEDULE="0 4 * * 6"
COMMAND="bash -c 'if command -v dnf &>/dev/null; then dnf upgrade -y; elif command -v apt-get &>/dev/null; then apt-get update && apt-get upgrade -y; fi'"
NAME="system_update"
COMMENT="每周六凌晨4点系统更新"
GROUP="maintenance"
NOTIFY_ON_FAIL=1
NOTIFY_WEBHOOK=""
TPL

    cat > "${TEMPLATE_DIR}/disk_check.tpl" << 'TPL'
SCHEDULE="*/30 * * * *"
COMMAND="df -h | awk 'NR>1 && \$5+0>85 {print \$1\" \"\$6\" 使用率\"\$5}' | xargs -r -I{} bash -c 'echo 磁盘告警: {}'"
NAME="disk_check"
COMMENT="每30分钟检查磁盘使用率"
GROUP="monitor"
NOTIFY_ON_FAIL=0
NOTIFY_WEBHOOK=""
TPL

    cat > "${TEMPLATE_DIR}/ssl_check.tpl" << 'TPL'
SCHEDULE="0 9 * * 1"
COMMAND="for cert in /etc/letsencrypt/live/*/cert.pem; do [ -f \"\$cert\" ] && openssl x509 -checkend 2592000 -noout -in \"\$cert\" || echo \"SSL证书即将过期: \$cert\"; done"
NAME="ssl_check"
COMMENT="每周一上午9点检查SSL证书有效期"
GROUP="security"
NOTIFY_ON_FAIL=1
NOTIFY_WEBHOOK=""
TPL

    log_success "默认模板已初始化"
}

# ============================================================================
# 冲突检测
# ============================================================================

detect_conflicts() {
    log_step "检测定时任务冲突..."
    local user="${CRON_USER:-$(whoami)}"
    local crontab_content
    if [[ "${user}" == "$(whoami)" ]]; then
        crontab_content="$(crontab -l 2>/dev/null)" || true
    else
        crontab_content="$(crontab -u "${user}" -l 2>/dev/null)" || true
    fi

    local tasks=()
    while read -r line; do
        [[ "${line}" =~ ^# ]] && continue
        [[ -z "${line}" ]] && continue
        local parts=(${line})
        [[ ${#parts[@]} -ge 6 ]] && tasks+=("${line}")
    done <<< "${crontab_content}"

    local conflicts=0
    for ((i=0; i<${#tasks[@]}; i++)); do
        for ((j=i+1; j<${#tasks[@]}; j++)); do
            local s1=(${tasks[$i]}) s2=(${tasks[$j]})
            if [[ "${s1[0]} ${s1[1]}" == "${s2[0]} ${s2[1]}" ]]; then
                ((conflicts++)) || true
                log_warning "时间冲突:"
                log_warning "  任务1: ${tasks[$i]}"
                log_warning "  任务2: ${tasks[$j]}"
            fi
        done
    done

    [[ ${conflicts} -eq 0 ]] && log_success "未检测到时间冲突" || log_warning "发现 ${conflicts} 个时间冲突"
}

# ============================================================================
# 健康检查
# ============================================================================

health_check() {
    log_step "定时任务健康检查..."

    echo -e "${CYAN}=== Cron服务状态 ===${NC}"
    if command -v systemctl &>/dev/null; then
        systemctl status cron 2>/dev/null || systemctl status crond 2>/dev/null || echo "  Cron服务状态未知"
    elif command -v rc-service &>/dev/null; then
        rc-service cron status 2>/dev/null || echo "  Cron服务状态未知"
    fi

    echo -e "\n${CYAN}=== Cron执行日志 ===${NC}"
    if [[ -f /var/log/cron.log ]]; then
        tail -20 /var/log/cron.log
    elif command -v journalctl &>/dev/null; then
        journalctl -u cron --since "1 hour ago" --no-pager 2>/dev/null | tail -20 || \
        journalctl -u crond --since "1 hour ago" --no-pager 2>/dev/null | tail -20 || \
        echo "  无Cron日志"
    else
        echo "  无法获取Cron日志"
    fi

    echo -e "\n${CYAN}=== 最近失败任务 ===${NC}"
    if command -v journalctl &>/dev/null; then
        journalctl -u cron -p err --since "24 hours ago" --no-pager 2>/dev/null | tail -10 || \
        journalctl -u crond -p err --since "24 hours ago" --no-pager 2>/dev/null | tail -10 || \
        echo "  无失败记录"
    fi

    echo -e "\n${CYAN}=== Cron用户权限 ===${NC}"
    [[ -f /etc/cron.allow ]] && { echo "  cron.allow:"; cat /etc/cron.allow; } || echo "  无cron.allow (所有用户允许)"
    [[ -f /etc/cron.deny ]]  && { echo "  cron.deny:"; cat /etc/cron.deny; }  || echo "  无cron.deny"
}

# ============================================================================
# 备份与恢复
# ============================================================================

backup_crontabs() {
    log_step "备份所有Cron任务..."
    local backup_file="${BACKUP_DIR}/crontab_backup_${TIMESTAMP}.tar.gz"
    mkdir -p "${BACKUP_DIR}"

    local tmp_dir="$(mktemp -d)"
    mkdir -p "${tmp_dir}/users" "${tmp_dir}/system"

    for user in $(cut -d':' -f1 /etc/passwd); do
        local user_cron="$(crontab -u "${user}" -l 2>/dev/null)" || true
        [[ -n "${user_cron}" ]] && echo "${user_cron}" > "${tmp_dir}/users/${user}"
    done

    [[ -d /etc/cron.d ]] && cp -a /etc/cron.d/* "${tmp_dir}/system/" 2>/dev/null || true

    tar -czf "${backup_file}" -C "${tmp_dir}" . 2>/dev/null
    rm -rf "${tmp_dir}"

    log_success "Cron备份完成: ${backup_file}"
}

restore_crontabs() {
    local backup_file="$1"
    [[ ! -f "${backup_file}" ]] && die "备份文件不存在: ${backup_file}"
    log_step "恢复Cron任务: ${backup_file}"

    local tmp_dir="$(mktemp -d)"
    tar -xzf "${backup_file}" -C "${tmp_dir}"

    for user_file in "${tmp_dir}/users/"*; do
        [[ -f "${user_file}" ]] || continue
        local user="$(basename "${user_file}")"
        crontab -u "${user}" "${user_file}" 2>/dev/null && log_success "已恢复: ${user}" || log_error "恢复失败: ${user}"
    done

    [[ -d "${tmp_dir}/system" ]] && {
        cp -a "${tmp_dir}/system/"* /etc/cron.d/ 2>/dev/null || true
        log_success "系统Cron已恢复"
    }

    rm -rf "${tmp_dir}"
    log_success "Cron恢复完成"
}

# ============================================================================
# 可视化时间表
# ============================================================================

show_timeline() {
    log_step "生成定时任务时间表..."
    local user="${CRON_USER:-$(whoami)}"
    local crontab_content
    if [[ "${user}" == "$(whoami)" ]]; then
        crontab_content="$(crontab -l 2>/dev/null)" || true
    else
        crontab_content="$(crontab -u "${user}" -l 2>/dev/null)" || true
    fi

    echo -e "${CYAN}=== 24小时时间表 ===${NC}"
    printf "%-6s" "时"
    for h in $(seq 0 23); do printf "%-4s" "${h}"; done
    echo ""

    local minute_groups=("00" "15" "30" "45")
    for mg in "${minute_groups[@]}"; do
        printf "%-6s" "${mg}m"
        for h in $(seq 0 23); do
            local has_task=0
            while read -r line; do
                [[ "${line}" =~ ^# ]] || [[ -z "${line}" ]] && continue
                local parts=(${line})
                [[ ${#parts[@]} -lt 5 ]] && continue
                local m="${parts[0]}" hr="${parts[1]}"
                if [[ "${hr}" == "*" ]] || [[ "${hr}" == "${h}" ]]; then
                    if [[ "${m}" == "*" ]] || [[ "${m}" == "${mg}" ]] || [[ "${m}" == "*/15" ]] || \
                       [[ "${m}" == "*/30" ]] || [[ "${m}" == "0,15,30,45" ]]; then
                        has_task=1; break
                    fi
                fi
            done <<< "${crontab_content}"
            [[ ${has_task} -eq 1 ]] && printf "${GREEN}%-4s${NC}" "X" || printf "%-4s" "."
        done
        echo ""
    done
    echo -e "\n${GREEN}X${NC} = 有任务  ${NC}.${NC} = 无任务"
}

# ============================================================================
# Cron任务高级管理模块
# ============================================================================

cron_export_all() {
    log_step "导出所有Cron任务..."
    local export_file="${LOG_DIR}/cron_export_${TIMESTAMP}.txt"
    mkdir -p "${LOG_DIR}" 2>/dev/null || true

    echo "# Cron任务导出 - $(date)" > "${export_file}"
    echo "# 主机: ${HOSTNAME}" >> "${export_file}"
    echo "" >> "${export_file}"

    echo "## 系统Cron任务" >> "${export_file}"
    for f in /etc/crontab /etc/cron.d/*; do
        [[ -f "${f}" ]] && {
            echo "### ${f}" >> "${export_file}"
            cat "${f}" >> "${export_file}"
            echo "" >> "${export_file}"
        }
    done

    echo "## 用户Cron任务" >> "${export_file}"
    for user in $(cut -d: -f1 /etc/passwd); do
        local user_cron="$(crontab -u "${user}" -l 2>/dev/null || true)"
        if [[ -n "${user_cron}" ]]; then
            echo "### 用户: ${user}" >> "${export_file}"
            echo "${user_cron}" >> "${export_file}"
            echo "" >> "${export_file}"
        fi
    done

    echo "## Anacron配置" >> "${export_file}"
    [[ -f /etc/anacrontab ]] && cat /etc/anacrontab >> "${export_file}"

    log_success "Cron任务已导出: ${export_file}"
}

cron_import() {
    local import_file="$1"
    [[ -z "${import_file}" ]] && { log_error "请指定导入文件"; return 1; }
    [[ ! -f "${import_file}" ]] && { log_error "导入文件不存在: ${import_file}"; return 1; }

    log_step "导入Cron任务: ${import_file}..."
    local user="${2:-$(whoami)}"
    local existing="$(crontab -u "${user}" -l 2>/dev/null || true)"

    {
        echo "${existing}"
        echo ""
        echo "# 导入自 ${import_file} - $(date)"
        grep -v '^#' "${import_file}" | grep -v '^$'
    } | crontab -u "${user}" -

    log_success "Cron任务已导入"
}

cron_duplicate_check() {
    log_step "检查重复Cron任务..."
    local user="${1:-$(whoami)}"
    local cron_data="$(crontab -u "${user}" -l 2>/dev/null || true)"
    [[ -z "${cron_data}" ]] && { log_info "无Cron任务"; return 0; }

    local lines=()
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        [[ "${line}" =~ ^# ]] && continue
        lines+=("${line}")
    done <<< "${cron_data}"

    local duplicates=0
    for i in "${!lines[@]}"; do
        for j in "${!lines[@]}"; do
            [[ ${i} -lt ${j} ]] && [[ "${lines[$i]}" == "${lines[$j]}" ]] && {
                log_warning "重复任务: ${lines[$i]}"
                ((duplicates++)) || true
            }
        done
    done

    [[ ${duplicates} -eq 0 ]] && log_success "无重复Cron任务" || log_warning "发现${duplicates}对重复任务"
}

cron_schedule_analyze() {
    log_step "分析Cron执行时间表..."
    local user="${1:-$(whoami)}"
    local cron_data="$(crontab -u "${user}" -l 2>/dev/null || true)"
    [[ -z "${cron_data}" ]] && { log_info "无Cron任务"; return 0; }

    echo -e "${CYAN}=== Cron执行时间表分析 ===${NC}"
    local task_num=0
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        [[ "${line}" =~ ^# ]] && continue
        ((task_num++)) || true

        local min hour dom mon dow cmd
        read -r min hour dom mon dow cmd <<< "${line}"

        echo -e "${WHITE}任务${task_num}:${NC} ${line}"
        echo "  分钟: ${min} | 小时: ${hour} | 日: ${dom} | 月: ${mon} | 星期: ${dow}"
        echo "  命令: ${cmd}"

        local next_run="$(date -d "$(echo "${min} ${hour} ${dom} ${mon} ${dow}" | awk '{print "next " $0}' 2>/dev/null)" 2>/dev/null || echo '计算失败')"
        [[ -n "${next_run}" ]] && echo "  下次执行: ${next_run}"
        echo ""
    done <<< "${cron_data}"
}

cron_runtime_estimate() {
    log_step "估算Cron任务运行时间..."
    local user="${1:-$(whoami)}"
    local cron_data="$(crontab -u "${user}" -l 2>/dev/null || true)"
    [[ -z "${cron_data}" ]] && { log_info "无Cron任务"; return 0; }

    echo -e "${CYAN}=== Cron任务运行时间估算 ===${NC}"
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        [[ "${line}" =~ ^# ]] && continue

        local cmd="${line#* * * * * }"
        local cmd_name="$(basename "${cmd%% *}" 2>/dev/null || echo 'unknown')"

        local log_file="/var/log/cron_${cmd_name}.log"
        if [[ -f "${log_file}" ]]; then
            local avg_time="$(awk '/duration/ {sum+=$NF; count++} END {if(count>0) print sum/count "s"; else print "N/A"}' "${log_file}" 2>/dev/null || echo 'N/A')"
            log_info "  ${cmd_name}: 平均耗时 ${avg_time}"
        else
            log_info "  ${cmd_name}: 无历史数据"
        fi
    done <<< "${cron_data}"
}

cron_error_check() {
    log_step "检查Cron任务错误..."
    local user="${1:-$(whoami)}"
    local cron_data="$(crontab -u "${user}" -l 2>/dev/null || true)"

    local errors=0
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        [[ "${line}" =~ ^# ]] && continue

        local min hour dom mon dow cmd
        read -r min hour dom mon dow cmd <<< "${line}"

        [[ "${min}" =~ [^0-9,\-\*/] ]] && { log_warning "无效分钟字段: ${line}"; ((errors++)) || true; }
        [[ "${hour}" =~ [^0-9,\-\*/] ]] && { log_warning "无效小时字段: ${line}"; ((errors++)) || true; }

        local full_cmd="${line#* * * * * }"
        local exec_cmd="${full_cmd%% *}"
        if ! command -v "${exec_cmd}" &>/dev/null && [[ ! -x "${exec_cmd}" ]]; then
            log_warning "命令不存在: ${exec_cmd} (行: ${line})"
            ((errors++)) || true
        fi
    done <<< "${cron_data}"

    [[ ${errors} -eq 0 ]] && log_success "未发现Cron任务错误" || log_warning "发现${errors}个错误"
}

cron_notify_setup() {
    log_step "设置Cron任务通知..."
    local notify_email="$1"
    [[ -z "${notify_email}" ]] && { log_error "请指定通知邮箱"; return 1; }

    local user="${2:-$(whoami)}"
    local cron_data="$(crontab -u "${user}" -l 2>/dev/null || true)"

    local new_cron="MAILTO=${notify_email}"
    [[ -n "${cron_data}" ]] && new_cron="${new_cron}\n${cron_data}"

    echo -e "${new_cron}" | crontab -u "${user}" -
    log_success "Cron通知已设置: ${notify_email}"
}

cron_disable_all() {
    log_step "禁用所有Cron任务..."
    local user="${1:-$(whoami)}"
    local cron_data="$(crontab -u "${user}" -l 2>/dev/null || true)"
    [[ -z "${cron_data}" ]] && { log_info "无Cron任务"; return 0; }

    local backup_file="${LOG_DIR}/cron_backup_${user}_${TIMESTAMP}.txt"
    echo "${cron_data}" > "${backup_file}"
    log_info "已备份到: ${backup_file}"

    local disabled_cron=""
    while IFS= read -r line; do
        if [[ -z "${line}" ]] || [[ "${line}" =~ ^# ]]; then
            disabled_cron+="${line}"$'\n'
        else
            disabled_cron+="#DISABLED# ${line}"$'\n'
        fi
    done <<< "${cron_data}"

    echo "${disabled_cron}" | crontab -u "${user}" -
    log_success "所有Cron任务已禁用 (备份: ${backup_file})"
}

cron_enable_all() {
    log_step "启用所有Cron任务..."
    local user="${1:-$(whoami)}"
    local cron_data="$(crontab -u "${user}" -l 2>/dev/null || true)"
    [[ -z "${cron_data}" ]] && { log_info "无Cron任务"; return 0; }

    local enabled_cron=""
    while IFS= read -r line; do
        enabled_cron+="${line//#DISABLED# /}"$'\n'
    done <<< "${cron_data}"

    echo "${enabled_cron}" | crontab -u "${user}" -
    log_success "所有Cron任务已启用"
}

cron_run_now() {
    local job_id="$1"
    [[ -z "${job_id}" ]] && { log_error "请指定任务编号"; return 1; }
    log_step "立即执行Cron任务 #${job_id}..."

    local user="${2:-$(whoami)}"
    local cron_data="$(crontab -u "${user}" -l 2>/dev/null || true)"
    local line_num=0
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        [[ "${line}" =~ ^# ]] && continue
        ((line_num++)) || true
        if [[ ${line_num} -eq ${job_id} ]]; then
            local cmd="${line#* * * * * }"
            log_info "执行: ${cmd}"
            eval "${cmd}" 2>>"${LOG_FILE}" || log_error "任务执行失败"
            log_success "任务执行完成"
            return 0
        fi
    done <<< "${cron_data}"

    log_error "未找到任务 #${job_id}"
}

cron_lock_setup() {
    local job_name="$1" lock_dir="${2:-/tmp/cron_locks}"
    [[ -z "${job_name}" ]] && { log_error "请指定任务名称"; return 1; }

    mkdir -p "${lock_dir}" 2>/dev/null || true
    local lock_file="${lock_dir}/${job_name}.lock"

    if [[ -f "${lock_file}" ]]; then
        local pid="$(cat "${lock_file}" 2>/dev/null)"
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            log_error "任务 ${job_name} 已在运行 (PID: ${pid})"
            return 1
        fi
        rm -f "${lock_file}"
    fi

    echo $$ > "${lock_file}"
    trap "rm -f ${lock_file}" EXIT
    log_info "任务锁已获取: ${lock_file}"
}

cron_log_rotate() {
    log_step "轮转Cron日志..."
    local cron_log="/var/log/cron"
    [[ -f "${cron_log}" ]] && {
        local archive="${cron_log}.${TIMESTAMP}.gz"
        gzip -c "${cron_log}" > "${archive}" 2>/dev/null || true
        : > "${cron_log}"
        log_success "Cron日志已轮转: ${archive}"
    }
    find /var/log -name "cron*.gz" -mtime +30 -delete 2>/dev/null || true
}

cron_systemd_timer_list() {
    log_step "列出Systemd Timer..."
    echo -e "${CYAN}=== Systemd Timer ===${NC}"
    systemctl list-timers --all --no-pager 2>/dev/null || log_warning "systemctl不可用"
}

cron_systemd_timer_create() {
    local name="$1" schedule="$2" command="$3"
    [[ -z "${name}" ]] || [[ -z "${schedule}" ]] || [[ -z "${command}" ]] && {
        log_error "用法: --systemd-timer-create 名称 计划 命令"
        return 1
    }

    log_step "创建Systemd Timer: ${name}..."
    local timer_file="/etc/systemd/system/${name}.timer"
    local service_file="/etc/systemd/system/${name}.service"

    cat > "${service_file}" << SERVICE
[Unit]
Description=${name} Service

[Service]
Type=oneshot
ExecStart=${command}
SERVICE

    cat > "${timer_file}" << TIMER
[Unit]
Description=${name} Timer

[Timer]
OnCalendar=${schedule}
Persistent=true

[Install]
WantedBy=timers.target
TIMER

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable "${name}.timer" 2>/dev/null || true
    systemctl start "${name}.timer" 2>/dev/null || true
    log_success "Systemd Timer已创建: ${name}"
}

cron_systemd_timer_delete() {
    local name="$1"
    [[ -z "${name}" ]] && { log_error "请指定Timer名称"; return 1; }

    log_step "删除Systemd Timer: ${name}..."
    systemctl stop "${name}.timer" 2>/dev/null || true
    systemctl disable "${name}.timer" 2>/dev/null || true
    rm -f "/etc/systemd/system/${name}.timer" "/etc/systemd/system/${name}.service"
    systemctl daemon-reload 2>/dev/null || true
    log_success "Systemd Timer已删除: ${name}"
}

cron_health_dashboard() {
    log_step "生成Cron健康仪表盘..."
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  Cron健康仪表盘 - ${HOSTNAME}${NC}"
    echo -e "${CYAN}========================================${NC}"

    local total_jobs=0 active_jobs=0 disabled_jobs=0
    local cron_data="$(crontab -l 2>/dev/null || true)"
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        [[ "${line}" =~ ^#DISABLED# ]] && { ((disabled_jobs++)) || true; continue; }
        [[ "${line}" =~ ^# ]] && continue
        ((active_jobs++)) || true
    done <<< "${cron_data}"
    total_jobs=$((active_jobs + disabled_jobs))

    echo -e "  总任务数: ${total_jobs}"
    echo -e "  ${GREEN}活跃任务: ${active_jobs}${NC}"
    echo -e "  ${YELLOW}禁用任务: ${disabled_jobs}${NC}"

    echo ""
    echo -e "${WHITE}Systemd Timer:${NC}"
    local timer_count="$(systemctl list-timers --no-pager --no-legend 2>/dev/null | wc -l)"
    echo "  活跃Timer: ${timer_count}"

    echo ""
    echo -e "${WHITE}Cron服务状态:${NC}"
    systemctl is-active crond 2>/dev/null || systemctl is-active cron 2>/dev/null || echo "未知"

    echo ""
    echo -e "${WHITE}最近Cron日志:${NC}"
    tail -5 /var/log/cron 2>/dev/null || journalctl -u crond --no-pager -n 5 2>/dev/null || journalctl -u cron --no-pager -n 5 2>/dev/null || echo "(无日志)"

    echo -e "${CYAN}========================================${NC}"
}

cron_migration() {
    local source_user="$1" target_user="$2"
    [[ -z "${source_user}" ]] || [[ -z "${target_user}" ]] && {
        log_error "用法: --migrate 源用户 目标用户"
        return 1
    }

    log_step "迁移Cron任务: ${source_user} -> ${target_user}..."
    local source_cron="$(crontab -u "${source_user}" -l 2>/dev/null || true)"
    [[ -z "${source_cron}" ]] && { log_error "源用户无Cron任务"; return 1; }

    echo "${source_cron}" | crontab -u "${target_user}" -
    log_success "Cron任务已迁移: ${source_user} -> ${target_user}"
}

cron_audit() {
    log_step "审计Cron任务..."
    local audit_file="${LOG_DIR}/cron_audit_${TIMESTAMP}.txt"
    local issues=0

    echo "Cron审计报告 - $(date)" > "${audit_file}"
    echo "==============================" >> "${audit_file}"

    local cron_data="$(crontab -l 2>/dev/null || true)"
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        [[ "${line}" =~ ^# ]] && continue

        local cmd="${line#* * * * * }"

        if [[ "${cmd}" =~ rm\  ]] || [[ "${cmd}" =~ del ]] || [[ "${cmd}" =~ drop ]]; then
            echo "[风险] 删除操作: ${line}" >> "${audit_file}"
            ((issues++)) || true
        fi

        if [[ "${cmd}" =~ sudo ]]; then
            echo "[风险] sudo使用: ${line}" >> "${audit_file}"
            ((issues++)) || true
        fi

        if [[ "${cmd}" =~ \> ]] || [[ "${cmd}" =~ \>\> ]]; then
            echo "[信息] 文件写入: ${line}" >> "${audit_file}"
        fi

        local exec_cmd="${cmd%% *}"
        if ! command -v "${exec_cmd}" &>/dev/null; then
            echo "[错误] 命令不存在: ${exec_cmd}" >> "${audit_file}"
            ((issues++)) || true
        fi
    done <<< "${cron_data}"

    echo "" >> "${audit_file}"
    echo "发现问题: ${issues}" >> "${audit_file}"

    [[ ${issues} -eq 0 ]] && log_success "Cron审计通过" || log_warning "审计发现${issues}个问题 (详见: ${audit_file})"
    cat "${audit_file}"
}

# ============================================================================
# Cron任务模板系统
# ============================================================================

cron_template_list() {
    log_step "列出可用Cron模板..."
    local template_dir="${SCRIPT_DIR}/cron_templates"
    if [[ -d "${template_dir}" ]]; then
        echo -e "${CYAN}=== 可用Cron模板 ===${NC}"
        for f in "${template_dir}"/*.template; do
            [[ -f "${f}" ]] && {
                local name="$(basename "${f}" .template)"
                local desc="$(head -2 "${f}" | grep '^# ' | sed 's/^# //')"
                echo -e "  ${GREEN}${name}${NC}: ${desc:-无描述}"
            }
        done
    else
        log_info "模板目录不存在，创建内置模板..."
        mkdir -p "${template_dir}"
        cron_create_builtin_templates
        cron_template_list
    fi
}

cron_create_builtin_templates() {
    local template_dir="${SCRIPT_DIR}/cron_templates"
    mkdir -p "${template_dir}"

    cat > "${template_dir}/log_cleanup.template" << 'TEMPLATE'
# 日志清理模板 - 每天凌晨2点执行
0 2 * * * find /var/log -name "*.log" -mtime +30 -delete 2>/dev/null; find /var/log -name "*.gz" -mtime +60 -delete 2>/dev/null
TEMPLATE

    cat > "${template_dir}/backup.template" << 'TEMPLATE'
# 备份模板 - 每天凌晨1点执行
0 1 * * * tar czf /backup/system_$(date +\%Y\%m\%d).tar.gz /etc /home /var/lib/mysql 2>/dev/null
TEMPLATE

    cat > "${template_dir}/disk_monitor.template" << 'TEMPLATE'
# 磁盘监控模板 - 每5分钟执行
*/5 * * * * df -h | awk 'NR>1 && int($5)>80 {print $1 " " $5 " " $6}' | while read part pct mount; do echo "磁盘告警: ${mount} 使用率 ${pct}"; done
TEMPLATE

    cat > "${template_dir}/ssl_check.template" << 'TEMPLATE'
# SSL证书检查模板 - 每周一上午8点执行
0 8 * * 1 for cert in /etc/letsencrypt/live/*/cert.pem; do openssl x509 -enddate -noout -in "$cert" 2>/dev/null; done | while read line; do echo "$line"; done
TEMPLATE

    cat > "${template_dir}/system_update.template" << 'TEMPLATE'
# 系统安全更新模板 - 每天凌晨3点执行
0 3 * * * yum -y update --security 2>/dev/null || apt-get -y upgrade --security 2>/dev/null
TEMPLATE

    cat > "${template_dir}/mysql_backup.template" << 'TEMPLATE'
# MySQL备份模板 - 每天凌晨2点执行
0 2 * * * mysqldump -u root --all-databases --single-transaction | gzip > /backup/mysql_$(date +\%Y\%m\%d).sql.gz 2>/dev/null
TEMPLATE

    cat > "${template_dir}/redis_backup.template" << 'TEMPLATE'
# Redis备份模板 - 每小时执行
0 * * * * redis-cli BGSAVE 2>/dev/null && cp /var/lib/redis/dump.rdb /backup/redis_$(date +\%Y\%m\%d_\%H).rdb 2>/dev/null
TEMPLATE

    cat > "${template_dir}/docker_cleanup.template" << 'TEMPLATE'
# Docker清理模板 - 每周日凌晨4点执行
0 4 * * 0 docker system prune -af --volumes 2>/dev/null; docker image prune -a --filter "until=168h" 2>/dev/null
TEMPLATE

    cat > "${template_dir}/nginx_logrotate.template" << 'TEMPLATE'
# Nginx日志轮转模板 - 每天凌晨0点执行
0 0 * * * mv /var/log/nginx/access.log /var/log/nginx/access_$(date +\%Y\%m\%d).log 2>/dev/null; kill -USR1 $(cat /var/run/nginx.pid 2>/dev/null) 2>/dev/null
TEMPLATE

    cat > "${template_dir}/health_check.template" << 'TEMPLATE'
# 系统健康检查模板 - 每10分钟执行
*/10 * * * * curl -sf http://localhost/health > /dev/null 2>&1 || echo "服务异常" | mail -s "健康检查失败" admin@example.com
TEMPLATE

    log_success "内置模板已创建"
}

cron_template_apply() {
    local template_name="$1"
    [[ -z "${template_name}" ]] && { log_error "请指定模板名称"; return 1; }

    local template_file="${SCRIPT_DIR}/cron_templates/${template_name}.template"
    [[ ! -f "${template_file}" ]] && { log_error "模板不存在: ${template_name}"; return 1; }

    log_step "应用Cron模板: ${template_name}..."
    local user="${2:-$(whoami)}"
    local existing="$(crontab -u "${user}" -l 2>/dev/null || true)"

    local template_content="$(grep -v '^#' "${template_file}" | grep -v '^$')"

    {
        echo "${existing}"
        echo ""
        echo "# 模板: ${template_name} - $(date)"
        echo "${template_content}"
    } | crontab -u "${user}" -

    log_success "模板 ${template_name} 已应用到用户 ${user}"
}

cron_template_create() {
    local template_name="$1" schedule="$2" command="$3"
    [[ -z "${template_name}" ]] || [[ -z "${schedule}" ]] || [[ -z "${command}" ]] && {
        log_error "用法: --template-create 名称 计划 命令"
        return 1
    }

    local template_dir="${SCRIPT_DIR}/cron_templates"
    mkdir -p "${template_dir}"

    cat > "${template_dir}/${template_name}.template" << TEMPLATE
# ${template_name} - 自定义模板
${schedule} ${command}
TEMPLATE

    log_success "模板已创建: ${template_name}"
}

# ============================================================================
# Cron任务版本控制
# ============================================================================

cron_version_save() {
    log_step "保存Cron任务版本..."
    local version_dir="${LOG_DIR}/cron_versions"
    mkdir -p "${version_dir}"

    local version_file="${version_dir}/v$(date +%Y%m%d%H%M%S)"
    for user in $(cut -d: -f1 /etc/passwd); do
        local user_cron="$(crontab -u "${user}" -l 2>/dev/null || true)"
        if [[ -n "${user_cron}" ]]; then
            echo "=== 用户: ${user} ===" >> "${version_file}"
            echo "${user_cron}" >> "${version_file}"
            echo "" >> "${version_file}"
        fi
    done

    [[ -f "${version_file}" ]] && log_success "版本已保存: ${version_file}" || log_warning "无Cron任务可保存"
}

cron_version_restore() {
    local version_file="$1"
    [[ -z "${version_file}" ]] && { log_error "请指定版本文件"; return 1; }
    local version_dir="${LOG_DIR}/cron_versions"
    [[ ! -f "${version_dir}/${version_file}" ]] && { log_error "版本文件不存在"; return 1; }

    log_step "恢复Cron任务版本: ${version_file}..."
    confirm_action "确定要恢复此版本吗？当前Cron任务将被覆盖"

    local current_section=""
    while IFS= read -r line; do
        if [[ "${line}" =~ ^===\ 用户:\ (.*)\ ===$ ]]; then
            current_section="${BASH_REMATCH[1]}"
        elif [[ -n "${current_section}" ]] && [[ -n "${line}" ]]; then
            echo "${line}"
        fi
    done < "${version_dir}/${version_file}" | crontab -u "${current_section}" - 2>/dev/null || true

    log_success "版本已恢复"
}

cron_version_list() {
    log_step "列出Cron任务版本..."
    local version_dir="${LOG_DIR}/cron_versions"
    if [[ -d "${version_dir}" ]]; then
        ls -lt "${version_dir}" | head -20
    else
        log_info "无保存的版本"
    fi
}

# ============================================================================
# Cron任务执行历史
# ============================================================================

cron_history_show() {
    log_step "显示Cron执行历史..."
    local count="${1:-20}"
    echo -e "${CYAN}=== 最近Cron执行记录 ===${NC}"

    if [[ -f /var/log/cron ]]; then
        tail -${count} /var/log/cron
    elif command -v journalctl &>/dev/null; then
        journalctl -u crond --no-pager -n ${count} 2>/dev/null || journalctl -u cron --no-pager -n ${count} 2>/dev/null || echo "(无日志)"
    else
        echo "(无Cron日志)"
    fi
}

cron_history_search() {
    local pattern="$1"
    [[ -z "${pattern}" ]] && { log_error "请指定搜索关键词"; return 1; }
    log_step "搜索Cron执行历史: ${pattern}..."

    if [[ -f /var/log/cron ]]; then
        grep -i "${pattern}" /var/log/cron | tail -20
    elif command -v journalctl &>/dev/null; then
        journalctl -u crond --no-pager 2>/dev/null | grep -i "${pattern}" | tail -20 || \
        journalctl -u cron --no-pager 2>/dev/null | grep -i "${pattern}" | tail -20 || echo "(无匹配)"
    else
        echo "(无Cron日志)"
    fi
}

# ============================================================================
# Cron任务依赖管理
# ============================================================================

cron_dependency_add() {
    local job_name="$1" depends_on="$2"
    [[ -z "${job_name}" ]] || [[ -z "${depends_on}" ]] && {
        log_error "用法: --dep-add 任务名 依赖任务名"
        return 1
    }

    local dep_file="${SCRIPT_DIR}/cron_dependencies.txt"
    echo "${job_name}:${depends_on}" >> "${dep_file}"
    log_success "依赖已添加: ${job_name} -> ${depends_on}"
}

cron_dependency_check() {
    log_step "检查Cron任务依赖..."
    local dep_file="${SCRIPT_DIR}/cron_dependencies.txt"
    [[ ! -f "${dep_file}" ]] && { log_info "无依赖配置"; return 0; }

    while IFS=: read -r job dep; do
        local dep_status="$(crontab -l 2>/dev/null | grep -c "${dep}" || echo '0')"
        if [[ ${dep_status} -eq 0 ]]; then
            log_warning "任务 ${job} 依赖 ${dep}，但 ${dep} 不存在"
        else
            log_success "任务 ${job} -> ${dep} 依赖正常"
        fi
    done < "${dep_file}"
}

# ============================================================================
# Cron任务性能监控
# ============================================================================

cron_perf_monitor() {
    log_step "Cron任务性能监控..."
    local monitor_dir="${LOG_DIR}/cron_perf"
    mkdir -p "${monitor_dir}"

    local cron_data="$(crontab -l 2>/dev/null || true)"
    local job_num=0
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        [[ "${line}" =~ ^# ]] && continue
        ((job_num++)) || true

        local cmd="${line#* * * * * }"
        local cmd_name="$(basename "${cmd%% *}" 2>/dev/null || echo "job${job_num}")"
        local perf_file="${monitor_dir}/${cmd_name}.perf"

        local start_time="$(date +%s)"
        eval "timeout 300 ${cmd}" &>/dev/null || true
        local end_time="$(date +%s)"
        local duration=$((end_time - start_time))

        echo "$(date +%Y-%m-%d_%H:%M) ${duration}s" >> "${perf_file}"

        if [[ ${duration} -gt 300 ]]; then
            log_warning "[${cmd_name}] 执行耗时过长: ${duration}s"
        elif [[ ${duration} -gt 60 ]]; then
            log_info "[${cmd_name}] 执行耗时: ${duration}s"
        else
            log_success "[${cmd_name}] 执行耗时: ${duration}s"
        fi
    done <<< "${cron_data}"
}

# ============================================================================
# Cron任务负载优化
# ============================================================================

cron_load_balance() {
    log_step "分析Cron任务负载分布..."
    local cron_data="$(crontab -l 2>/dev/null || true)"
    [[ -z "${cron_data}" ]] && { log_info "无Cron任务"; return 0; }

    declare -A hour_jobs
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        [[ "${line}" =~ ^# ]] && continue

        local min hour rest
        read -r min hour rest <<< "${line}"

        if [[ "${hour}" =~ ^[0-9]+$ ]]; then
            hour_jobs["${hour}"]="${hour_jobs[${hour}]:-0}+1"
        elif [[ "${hour}" == "*" ]]; then
            for h in $(seq 0 23); do
                hour_jobs["${h}"]="${hour_jobs[${h}]:-0}+1"
            done
        fi
    done <<< "${cron_data}"

    echo -e "${CYAN}=== 每小时任务分布 ===${NC}"
    for h in $(seq 0 23 | sort -n); do
        local count="${hour_jobs[${h}]:-0}"
        local bar=""
        for i in $(seq 1 "${count}" 2>/dev/null); do bar+="#"; done
        printf "%02d:00 | %-20s (%d)\n" "${h}" "${bar}" "${count}"
    done

    local peak_hour="" peak_count=0
    for h in "${!hour_jobs[@]}"; do
        [[ "${hour_jobs[${h}]}" -gt "${peak_count}" ]] && {
            peak_count="${hour_jobs[${h}]}"
            peak_hour="${h}"
        }
    done

    [[ -n "${peak_hour}" ]] && log_info "高峰时段: ${peak_hour}:00 (${peak_count}个任务)"
}

# ============================================================================
# Cron任务HTML报告
# ============================================================================

cron_html_report() {
    log_step "生成Cron任务HTML报告..."
    local report_file="${LOG_DIR}/cron_report_${TIMESTAMP}.html"
    local cron_data="$(crontab -l 2>/dev/null || true)"
    local total=0 active=0 disabled=0

    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        [[ "${line}" =~ ^#DISABLED# ]] && { ((disabled++)) || true; continue; }
        [[ "${line}" =~ ^# ]] && continue
        ((active++)) || true
    done <<< "${cron_data}"
    total=$((active + disabled))

    cat > "${report_file}" << HTMLEOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<title>Cron任务报告 - ${HOSTNAME}</title>
<style>
body{font-family:Arial,sans-serif;margin:20px;background:#f5f5f5}
.container{max-width:1200px;margin:0 auto;background:#fff;padding:20px;border-radius:8px;box-shadow:0 2px 4px rgba(0,0,0,0.1)}
h1{color:#333;border-bottom:2px solid #4CAF50;padding-bottom:10px}
.summary{display:flex;gap:20px;margin:20px 0}
.card{flex:1;padding:15px;border-radius:6px;text-align:center}
.card.total{background:#e3f2fd}
.card.active{background:#e8f5e9}
.card.disabled{background:#fff3e0}
.card h3{margin:0;font-size:2em}
.card p{margin:5px 0 0;color:#666}
table{width:100%;border-collapse:collapse;margin:20px 0}
th,td{padding:10px;text-align:left;border-bottom:1px solid #ddd}
th{background:#4CAF50;color:#fff}
tr:hover{background:#f5f5f5}
.disabled-row{color:#999;text-decoration:line-through}
footer{margin-top:20px;text-align:center;color:#999;font-size:0.9em}
</style>
</head>
<body>
<div class="container">
<h1>Cron任务报告 - ${HOSTNAME}</h1>
<p>生成时间: $(date '+%Y-%m-%d %H:%M:%S')</p>
<div class="summary">
<div class="card total"><h3>${total}</h3><p>总任务数</p></div>
<div class="card active"><h3>${active}</h3><p>活跃任务</p></div>
<div class="card disabled"><h3>${disabled}</h3><p>禁用任务</p></div>
</div>
<h2>任务列表</h2>
<table>
<tr><th>#</th><th>分钟</th><th>小时</th><th>日</th><th>月</th><th>星期</th><th>命令</th><th>状态</th></tr>
HTMLEOF

    local num=0
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        [[ "${line}" =~ ^MAILTO ]] && continue
        ((num++)) || true

        local status="活跃" row_class=""
        if [[ "${line}" =~ ^#DISABLED# ]]; then
            status="禁用"
            row_class=" class=\"disabled-row\""
            line="${line//#DISABLED# /}"
        elif [[ "${line}" =~ ^# ]]; then
            continue
        fi

        local min hour dom mon dow cmd
        read -r min hour dom mon dow cmd <<< "${line}"
        echo "<tr${row_class}><td>${num}</td><td>${min}</td><td>${hour}</td><td>${dom}</td><td>${mon}</td><td>${dow}</td><td>${cmd}</td><td>${status}</td></tr>" >> "${report_file}"
    done <<< "${cron_data}"

    cat >> "${report_file}" << HTMLEOF
</table>
<footer>由 cron_manager.sh v${SCRIPT_VERSION} 自动生成</footer>
</div>
</body>
</html>
HTMLEOF

    log_success "HTML报告已生成: ${report_file}"
}

# ============================================================================
# Cron任务跨主机同步
# ============================================================================

cron_sync_remote() {
    local remote_host="$1" remote_user="$2"
    [[ -z "${remote_host}" ]] && { log_error "请指定远程主机"; return 1; }
    remote_user="${remote_user:-$(whoami)}"

    log_step "同步Cron任务到 ${remote_host}..."
    local local_cron="$(crontab -l 2>/dev/null || true)"
    [[ -z "${local_cron}" ]] && { log_error "本地无Cron任务"; return 1; }

    echo "${local_cron}" | ssh "${remote_user}@${remote_host}" "crontab -" 2>/dev/null
    [[ $? -eq 0 ]] && log_success "Cron任务已同步到 ${remote_host}" || log_error "同步失败"
}

cron_sync_from_remote() {
    local remote_host="$1" remote_user="$2"
    [[ -z "${remote_host}" ]] && { log_error "请指定远程主机"; return 1; }
    remote_user="${remote_user:-$(whoami)}"

    log_step "从 ${remote_host} 同步Cron任务..."
    local remote_cron="$(ssh "${remote_user}@${remote_host}" "crontab -l" 2>/dev/null || true)"
    [[ -z "${remote_cron}" ]] && { log_error "远程无Cron任务"; return 1; }

    echo "${remote_cron}" | crontab -
    log_success "Cron任务已从 ${remote_host} 同步"
}

# ============================================================================
# Cron任务加密存储
# ============================================================================

cron_encrypt_save() {
    log_step "加密保存Cron任务..."
    local cron_data="$(crontab -l 2>/dev/null || true)"
    [[ -z "${cron_data}" ]] && { log_error "无Cron任务"; return 1; }

    local enc_file="${LOG_DIR}/cron_encrypted_${TIMESTAMP}.enc"
    if command -v openssl &>/dev/null; then
        echo "${cron_data}" | openssl enc -aes-256-cbc -salt -pbkdf2 -out "${enc_file}" 2>/dev/null
        log_success "Cron任务已加密保存: ${enc_file}"
    else
        log_error "openssl不可用，无法加密"
    fi
}

cron_decrypt_restore() {
    local enc_file="$1"
    [[ -z "${enc_file}" ]] && { log_error "请指定加密文件"; return 1; }
    [[ ! -f "${enc_file}" ]] && { log_error "文件不存在: ${enc_file}"; return 1; }

    log_step "解密恢复Cron任务..."
    if command -v openssl &>/dev/null; then
        local decrypted="$(openssl enc -aes-256-cbc -d -pbkdf2 -in "${enc_file}" 2>/dev/null || true)"
        if [[ -n "${decrypted}" ]]; then
            echo "${decrypted}" | crontab -
            log_success "Cron任务已解密恢复"
        else
            log_error "解密失败（密码错误？）"
        fi
    else
        log_error "openssl不可用"
    fi
}

# ============================================================================
# Cron任务批量操作
# ============================================================================

cron_batch_add() {
    local jobs_file="$1"
    [[ -z "${jobs_file}" ]] && { log_error "请指定任务文件"; return 1; }
    [[ ! -f "${jobs_file}" ]] && { log_error "文件不存在: ${jobs_file}"; return 1; }

    log_step "批量添加Cron任务..."
    local user="${2:-$(whoami)}"
    local existing="$(crontab -u "${user}" -l 2>/dev/null || true)"
    local new_jobs="$(grep -v '^#' "${jobs_file}" | grep -v '^$')"

    {
        echo "${existing}"
        echo ""
        echo "# 批量添加 - $(date)"
        echo "${new_jobs}"
    } | crontab -u "${user}" -

    log_success "批量添加完成"
}

cron_batch_remove() {
    local pattern="$1"
    [[ -z "${pattern}" ]] && { log_error "请指定匹配模式"; return 1; }

    log_step "批量删除匹配Cron任务: ${pattern}..."
    local user="${2:-$(whoami)}"
    local cron_data="$(crontab -u "${user}" -l 2>/dev/null || true)"
    local removed=0

    local new_cron=""
    while IFS= read -r line; do
        if [[ "${line}" =~ ${pattern} ]]; then
            log_info "删除: ${line}"
            ((removed++)) || true
        else
            new_cron+="${line}"$'\n'
        fi
    done <<< "${cron_data}"

    echo "${new_cron}" | crontab -u "${user}" -
    log_success "已删除${removed}个匹配任务"
}

# ============================================================================
# Cron表达式转换
# ============================================================================

cron_to_human() {
    local expr="$1"
    [[ -z "${expr}" ]] && { log_error "请指定Cron表达式"; return 1; }

    local min hour dom mon dow
    read -r min hour dom mon dow <<< "${expr}"

    local desc=""

    [[ "${min}" == "*" ]] && desc+="每分钟" || desc+="在第${min}分钟"
    [[ "${hour}" == "*" ]] && desc+=" 每小时" || desc+=" ${hour}点"
    [[ "${dom}" == "*" ]] && desc+=" 每天" || desc+=" 每月${dom}日"
    [[ "${mon}" == "*" ]] && desc+=" 每月" || {
        local months=("1月" "2月" "3月" "4月" "5月" "6月" "7月" "8月" "9月" "10月" "11月" "12月")
        local mon_num="${mon}"
        [[ "${mon_num}" =~ ^[0-9]+$ ]] && [[ ${mon_num} -ge 1 ]] && [[ ${mon_num} -le 12 ]] && desc+=" ${months[$((mon_num-1))]}"
    }
    [[ "${dow}" == "*" ]] && desc+="" || {
        local days=("周日" "周一" "周二" "周三" "周四" "周五" "周六")
        [[ "${dow}" =~ ^[0-6]$ ]] && desc+=" ${days[${dow}]}"
    }

    echo -e "${GREEN}${desc}${NC}"
}

cron_validate_expr() {
    local expr="$1"
    [[ -z "${expr}" ]] && { log_error "请指定Cron表达式"; return 1; }

    local min hour dom mon dow
    read -r min hour dom mon dow <<< "${expr}"

    local valid=true

    validate_field() {
        local val="$1" min_val="$2" max_val="$3" name="$4"
        if [[ "${val}" != "*" ]] && ! [[ "${val}" =~ ^[0-9,\-\*/]+$ ]]; then
            log_error "无效${name}字段: ${val}"
            valid=false
            return
        fi
        if [[ "${val}" =~ ^[0-9]+$ ]]; then
            [[ ${val} -lt ${min_val} ]] || [[ ${val} -gt ${max_val} ]] && {
                log_error "${name}超出范围: ${val} (${min_val}-${max_val})"
                valid=false
            }
        fi
    }

    validate_field "${min}" 0 59 "分钟"
    validate_field "${hour}" 0 23 "小时"
    validate_field "${dom}" 1 31 "日"
    validate_field "${mon}" 1 12 "月"
    validate_field "${dow}" 0 6 "星期"

    [[ "${valid}" == "true" ]] && log_success "Cron表达式有效" || log_error "Cron表达式无效"
}

# ============================================================================
# 参数解析
# ============================================================================

show_usage() {
    cat << USAGE
定时任务管理脚本 v${SCRIPT_VERSION}

用法: bash cron_manager.sh [选项] [操作]

操作:
  --list                    列出所有定时任务
  --add                     添加定时任务 (需配合--schedule/--command)
  --remove NAME             删除指定定时任务
  --update NAME             更新指定定时任务
  --enable NAME             启用定时任务
  --disable NAME            禁用定时任务
  --detect-conflicts        检测时间冲突
  --health-check            Cron健康检查
  --backup                  备份所有Cron任务
  --restore FILE            从备份恢复
  --timeline                可视化时间表
  --systemd-list            列出Systemd Timers
  --systemd-add             添加Systemd Timer
  --systemd-remove NAME     删除Systemd Timer
  --template-list           列出模板
  --template-save NAME      保存当前配置为模板
  --template-load NAME      从模板加载
  --template-init           初始化默认模板
  --export                  导出所有Cron任务
  --import FILE             从文件导入Cron任务
  --duplicate-check         检查重复Cron任务
  --schedule-analyze        分析Cron执行时间表
  --runtime-estimate        估算Cron任务运行时间
  --error-check             检查Cron任务错误
  --notify-setup EMAIL      设置Cron任务通知邮箱
  --disable-all             禁用所有Cron任务
  --enable-all              启用所有Cron任务
  --run-now ID              立即执行指定编号的Cron任务
  --log-rotate              轮转Cron日志
  --health-dashboard        生成Cron健康仪表盘
  --audit                   审计Cron任务安全性
  --template-list2          列出可用Cron模板(V2)
  --template-apply NAME     应用Cron模板(V2)
  --template-create NAME    创建自定义Cron模板(V2)
  --version-save            保存Cron任务版本
  --version-restore FILE    恢复Cron任务版本
  --version-list            列出Cron任务版本
  --history [N]             显示最近N条Cron执行历史
  --history-search PATTERN  搜索Cron执行历史
  --dep-add JOB DEP         添加任务依赖
  --dep-check               检查任务依赖
  --perf-monitor            监控Cron任务性能
  --load-balance            分析Cron任务负载分布
  --html-report             生成HTML报告
  --sync-remote HOST        同步Cron任务到远程主机
  --sync-from HOST          从远程主机同步Cron任务
  --encrypt-save            加密保存Cron任务
  --decrypt-restore FILE    解密恢复Cron任务
  --batch-add FILE          批量添加Cron任务
  --batch-remove PATTERN    批量删除Cron任务
  --to-human EXPR           Cron表达式转人类可读
  --validate EXPR           验证Cron表达式
  --config-show             显示Cron相关配置文件
  --dirs-check              检查Cron目录
  --service-status          检查Cron服务状态

选项:
  --user USER          指定Cron用户
  --name NAME          任务名称
  --schedule EXPR      Cron表达式
  --command CMD        执行命令
  --group GROUP        任务分组
  --comment TEXT       任务说明
  --notify             失败时通知
  --webhook URL        通知Webhook
  --dry-run            模拟运行
  --verbose            详细输出
  --help               显示帮助
  --version            显示版本

Cron表达式示例:
  */5 * * * *          每5分钟
  0 * * * *            每小时
  0 2 * * *            每天凌晨2点
  0 0 * * 0            每周日午夜
  0 0 1 * *            每月1号午夜
  0 0 1 1 *            每年1月1日
  @daily               每天午夜 (= 0 0 * * *)
  @hourly              每小时 (= 0 * * * *)
  @every5min           每5分钟 (= */5 * * * *)

支持的操作系统:
  CentOS/RHEL, Ubuntu/Debian, Alpine, Arch Linux, openSUSE
USAGE
}

parse_args() {
    [[ $# -eq 0 ]] && { show_usage; exit 0; }
    local action="" restore_file="" action_arg="" action_arg2=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list)             action="list"; shift ;;
            --add)              action="add"; shift ;;
            --remove)           action="remove"; TASK_NAME="$2"; shift 2 ;;
            --update)           action="update"; TASK_NAME="$2"; shift 2 ;;
            --enable)           action="enable"; TASK_NAME="$2"; shift 2 ;;
            --disable)          action="disable"; TASK_NAME="$2"; shift 2 ;;
            --detect-conflicts) action="detect_conflicts"; shift ;;
            --health-check)     action="health_check"; shift ;;
            --backup)           action="backup"; shift ;;
            --restore)          action="restore"; restore_file="$2"; shift 2 ;;
            --timeline)         action="timeline"; shift ;;
            --systemd-list)     action="systemd_list"; shift ;;
            --systemd-add)      action="systemd_add"; shift ;;
            --systemd-remove)   action="systemd_remove"; TASK_NAME="$2"; shift 2 ;;
            --template-list)    action="template_list"; shift ;;
            --template-save)    action="template_save"; TASK_NAME="$2"; shift 2 ;;
            --template-load)    action="template_load"; TASK_NAME="$2"; shift 2 ;;
            --template-init)    action="template_init"; shift ;;
            --export)           action="export"; shift ;;
            --import)           action="import"; action_arg="$2"; shift 2 ;;
            --duplicate-check)  action="duplicate_check"; shift ;;
            --schedule-analyze) action="schedule_analyze"; shift ;;
            --runtime-estimate) action="runtime_estimate"; shift ;;
            --error-check)      action="error_check"; shift ;;
            --notify-setup)     action="notify_setup"; action_arg="$2"; shift 2 ;;
            --disable-all)      action="disable_all"; shift ;;
            --enable-all)       action="enable_all"; shift ;;
            --run-now)          action="run_now"; action_arg="$2"; shift 2 ;;
            --log-rotate)       action="log_rotate"; shift ;;
            --health-dashboard) action="health_dashboard"; shift ;;
            --audit)            action="audit"; shift ;;
            --template-list2)   action="template_list2"; shift ;;
            --template-apply)   action="template_apply"; action_arg="$2"; shift 2 ;;
            --template-create)  action="template_create"; TASK_NAME="$2"; shift 2 ;;
            --version-save)     action="version_save"; shift ;;
            --version-restore)  action="version_restore"; action_arg="$2"; shift 2 ;;
            --version-list)     action="version_list"; shift ;;
            --history)          action="history"; action_arg="${2:-20}"; [[ $# -gt 1 && ! "$2" =~ ^-- ]] && shift 2 || shift ;;
            --history-search)   action="history_search"; action_arg="$2"; shift 2 ;;
            --dep-add)          action="dep_add"; action_arg="$2"; action_arg2="$3"; shift 3 ;;
            --dep-check)        action="dep_check"; shift ;;
            --perf-monitor)     action="perf_monitor"; shift ;;
            --load-balance)     action="load_balance"; shift ;;
            --html-report)      action="html_report"; shift ;;
            --sync-remote)      action="sync_remote"; action_arg="$2"; shift 2 ;;
            --sync-from)        action="sync_from"; action_arg="$2"; shift 2 ;;
            --encrypt-save)     action="encrypt_save"; shift ;;
            --decrypt-restore)  action="decrypt_restore"; action_arg="$2"; shift 2 ;;
            --batch-add)        action="batch_add"; action_arg="$2"; shift 2 ;;
            --batch-remove)     action="batch_remove"; action_arg="$2"; shift 2 ;;
            --to-human)         action="to_human"; action_arg="$2"; shift 2 ;;
            --validate)         action="validate"; action_arg="$2"; shift 2 ;;
            --config-show)      action="config_show"; shift ;;
            --dirs-check)       action="dirs_check"; shift ;;
            --service-status)   action="service_status"; shift ;;
            --user)             CRON_USER="$2"; shift 2 ;;
            --name)             TASK_NAME="$2"; shift 2 ;;
            --schedule)         TASK_SCHEDULE="$2"; shift 2 ;;
            --command)          TASK_COMMAND="$2"; shift 2 ;;
            --group)            TASK_GROUP="$2"; shift 2 ;;
            --comment)          TASK_COMMENT="$2"; shift 2 ;;
            --notify)           NOTIFY_ON_FAIL=1; shift ;;
            --webhook)          NOTIFY_WEBHOOK="$2"; shift 2 ;;
            --dry-run)          DRY_RUN=1; shift ;;
            --verbose)          VERBOSE=1; shift ;;
            --help|-h)          show_usage; exit 0 ;;
            --version|-v)       echo "v${SCRIPT_VERSION}"; exit 0 ;;
            *)                  log_error "未知选项: $1"; show_usage; exit 1 ;;
        esac
    done

    print_banner

    case "${action}" in
        list)              list_cron_tasks ;;
        add)               [[ -z "${TASK_SCHEDULE}" ]] || [[ -z "${TASK_COMMAND}" ]] && die "必须指定 --schedule 和 --command"; add_cron_task ;;
        remove)            [[ -z "${TASK_NAME}" ]] && die "必须指定 --name"; remove_cron_task "${TASK_NAME}" ;;
        update)            [[ -z "${TASK_NAME}" ]] && die "必须指定 --name"; update_cron_task "${TASK_NAME}" "${TASK_SCHEDULE}" "${TASK_COMMAND}" ;;
        enable)            [[ -z "${TASK_NAME}" ]] && die "必须指定 --name"; enable_cron_task "${TASK_NAME}" ;;
        disable)           [[ -z "${TASK_NAME}" ]] && die "必须指定 --name"; disable_cron_task "${TASK_NAME}" ;;
        detect_conflicts)  detect_conflicts ;;
        health_check)      health_check ;;
        backup)            backup_crontabs ;;
        restore)           restore_crontabs "${restore_file}" ;;
        timeline)          show_timeline ;;
        systemd_list)      list_systemd_timers ;;
        systemd_add)       [[ -z "${TASK_SCHEDULE}" ]] || [[ -z "${TASK_COMMAND}" ]] && die "必须指定 --schedule 和 --command"; add_systemd_timer ;;
        systemd_remove)    [[ -z "${TASK_NAME}" ]] && die "必须指定 --name"; remove_systemd_timer "${TASK_NAME}" ;;
        template_list)     list_templates ;;
        template_save)     [[ -z "${TASK_NAME}" ]] && die "必须指定 --name"; save_template "${TASK_NAME}" "${TASK_SCHEDULE}" "${TASK_COMMAND}" ;;
        template_load)     [[ -z "${TASK_NAME}" ]] && die "必须指定 --name"; load_template "${TASK_NAME}"; add_cron_task ;;
        template_init)     init_default_templates ;;
        export)            cron_export_all ;;
        import)            cron_import "${action_arg}" ;;
        duplicate_check)   cron_duplicate_check ;;
        schedule_analyze)  cron_schedule_analyze ;;
        runtime_estimate)  cron_runtime_estimate ;;
        error_check)       cron_error_check ;;
        notify_setup)      cron_notify_setup "${action_arg}" ;;
        disable_all)       cron_disable_all ;;
        enable_all)        cron_enable_all ;;
        run_now)           cron_run_now "${action_arg}" ;;
        log_rotate)        cron_log_rotate ;;
        health_dashboard)  cron_health_dashboard ;;
        audit)             cron_audit ;;
        template_list2)    cron_template_list ;;
        template_apply)    cron_template_apply "${action_arg}" ;;
        template_create)   cron_template_create "${TASK_NAME}" "${TASK_SCHEDULE}" "${TASK_COMMAND}" ;;
        version_save)      cron_version_save ;;
        version_restore)   cron_version_restore "${action_arg}" ;;
        version_list)      cron_version_list ;;
        history)           cron_history_show "${action_arg}" ;;
        history_search)    cron_history_search "${action_arg}" ;;
        dep_add)           cron_dependency_add "${action_arg}" "${action_arg2}" ;;
        dep_check)         cron_dependency_check ;;
        perf_monitor)      cron_perf_monitor ;;
        load_balance)      cron_load_balance ;;
        html_report)       cron_html_report ;;
        sync_remote)       cron_sync_remote "${action_arg}" ;;
        sync_from)         cron_sync_from_remote "${action_arg}" ;;
        encrypt_save)      cron_encrypt_save ;;
        decrypt_restore)   cron_decrypt_restore "${action_arg}" ;;
        batch_add)         cron_batch_add "${action_arg}" ;;
        batch_remove)      cron_batch_remove "${action_arg}" ;;
        to_human)          cron_to_human "${action_arg}" ;;
        validate)          cron_validate_expr "${action_arg}" ;;
        config_show)       cron_config_show ;;
        dirs_check)        cron_cron_dirs_check ;;
        service_status)    cron_service_status ;;
        *)                 show_usage ;;
    esac
}

# ============================================================================
# Cron任务配置文件管理
# ============================================================================

cron_config_show() {
    log_step "显示Cron相关配置文件..."
    echo -e "${CYAN}=== /etc/crontab ===${NC}"
    [[ -f /etc/crontab ]] && cat /etc/crontab || echo "(不存在)"
    echo ""
    echo -e "${CYAN}=== /etc/cron.d/ ===${NC}"
    for f in /etc/cron.d/*; do
        [[ -f "${f}" ]] && {
            echo "--- $(basename "${f}") ---"
            cat "${f}"
            echo ""
        }
    done
    echo -e "${CYAN}=== Cron允许/拒绝 ===${NC}"
    [[ -f /etc/cron.allow ]] && { echo "允许:"; cat /etc/cron.allow; } || echo "cron.allow: 不存在"
    [[ -f /etc/cron.deny ]] && { echo "拒绝:"; cat /etc/cron.deny; } || echo "cron.deny: 不存在"
}

cron_cron_dirs_check() {
    log_step "检查Cron目录..."
    for dir in /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /var/spool/cron /var/spool/cron/crontabs; do
        if [[ -d "${dir}" ]]; then
            local count="$(find "${dir}" -type f 2>/dev/null | wc -l)"
            log_success "${dir}: ${count}个文件"
        else
            log_warning "${dir}: 不存在"
        fi
    done
}

cron_service_status() {
    log_step "检查Cron服务状态..."
    if systemctl is-active crond &>/dev/null; then
        log_success "crond 服务运行中"
        systemctl status crond --no-pager 2>/dev/null | head -10
    elif systemctl is-active cron &>/dev/null; then
        log_success "cron 服务运行中"
        systemctl status cron --no-pager 2>/dev/null | head -10
    elif pgrep -x "crond" &>/dev/null || pgrep -x "cron" &>/dev/null; then
        log_success "Cron进程运行中"
    else
        log_error "Cron服务未运行"
        log_info "尝试启动Cron服务..."
        systemctl start crond 2>/dev/null || systemctl start cron 2>/dev/null || service crond start 2>/dev/null || service cron start 2>/dev/null || log_error "无法启动Cron服务"
    fi
}

# ============================================================================
# 脚本入口
# ============================================================================

parse_args "$@"
