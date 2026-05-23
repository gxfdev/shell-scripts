#!/usr/bin/env bash
# ============================================================================
#  定时任务管理脚本 (Cron Manager Script)
#  支持: CentOS/RHEL, Ubuntu/Debian, Alpine, Arch Linux, openSUSE
#  版本: 2.0.0
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

SCRIPT_VERSION="2.0.0"
SCRIPT_NAME="cron_manager"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
    local action=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list)             action="list" ;;
            --add)              action="add" ;;
            --remove)           action="remove"; TASK_NAME="$2"; shift ;;
            --update)           action="update"; TASK_NAME="$2"; shift ;;
            --enable)           action="enable"; TASK_NAME="$2"; shift ;;
            --disable)          action="disable"; TASK_NAME="$2"; shift ;;
            --detect-conflicts) action="detect_conflicts" ;;
            --health-check)     action="health_check" ;;
            --backup)           action="backup" ;;
            --restore)          action="restore"; local restore_file="$2"; shift ;;
            --timeline)         action="timeline" ;;
            --systemd-list)     action="systemd_list" ;;
            --systemd-add)      action="systemd_add" ;;
            --systemd-remove)   action="systemd_remove"; TASK_NAME="$2"; shift ;;
            --template-list)    action="template_list" ;;
            --template-save)    action="template_save"; TASK_NAME="$2"; shift ;;
            --template-load)    action="template_load"; TASK_NAME="$2"; shift ;;
            --template-init)    action="template_init" ;;
            --user)             CRON_USER="$2"; shift ;;
            --name)             TASK_NAME="$2"; shift ;;
            --schedule)         TASK_SCHEDULE="$2"; shift ;;
            --command)          TASK_COMMAND="$2"; shift ;;
            --group)            TASK_GROUP="$2"; shift ;;
            --comment)          TASK_COMMENT="$2"; shift ;;
            --notify)           NOTIFY_ON_FAIL=1 ;;
            --webhook)          NOTIFY_WEBHOOK="$2"; shift ;;
            --dry-run)          DRY_RUN=1 ;;
            --verbose)          VERBOSE=1 ;;
            --help|-h)          show_usage; exit 0 ;;
            --version|-v)       echo "v${SCRIPT_VERSION}"; exit 0 ;;
            *)                  log_error "未知选项: $1"; show_usage; exit 1 ;;
        esac
        shift
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
        *)                 show_usage ;;
    esac
}

parse_args "$@"
