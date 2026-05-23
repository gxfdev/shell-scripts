#!/usr/bin/env bash
# ============================================================================
#  跨平台基础函数库 (Cross-Platform Common Library)
#  支持: Linux (CentOS/Ubuntu/Debian/Alpine/Arch/openSUSE), macOS, Windows WSL/Git Bash
#  版本: 1.0.0
#  作者: gxfdev
#  仓库: https://github.com/gxfdev/shell-scripts
# ============================================================================
#  用法:
#    source common_lib.sh          # 在脚本中引入
#    common_init                   # 初始化基础库
#    detect_os                     # 检测操作系统
#    pkg_install nginx             # 跨平台安装包
#    svc_start nginx               # 跨平台启动服务
# ============================================================================
#  本库提供:
#    - 跨平台操作系统检测 (Linux/macOS/Windows WSL/Cygwin/Git Bash)
#    - 统一包管理接口 (apt/yum/dnf/apk/pacman/brew/choco/scoop)
#    - 统一服务管理接口 (systemd/launchctl/openrc/sc.exe)
#    - 统一用户管理接口
#    - 高级错误处理与信号捕获
#    - 结构化日志系统 (文件/控制台/JSON/syslog)
#    - 安全工具函数 (加密/校验/权限/审计)
#    - 性能监控工具
#    - 网络工具函数
#    - 文件系统工具函数
#    - 进程管理工具
#    - 配置文件解析器
#    - 通知系统 (邮件/钉钉/企业微信/Slack/Webhook)
# ============================================================================

COMMON_LIB_VERSION="1.0.0"
COMMON_LIB_LOADED=0

if [[ "${COMMON_LIB_LOADED}" -eq 1 ]]; then
    return 0 2>/dev/null || true
fi

# ============================================================================
# 颜色定义 (跨终端兼容)
# ============================================================================
if [[ -t 1 ]] && command -v tput &>/dev/null && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
    WHITE='\033[1;37m'; NC='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
    UNDERLINE='\033[4m'; BLINK='\033[5m'; REVERSE='\033[7m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; MAGENTA=''; CYAN=''
    WHITE=''; NC=''; BOLD=''; DIM=''; UNDERLINE=''; BLINK=''; REVERSE=''
fi

# ============================================================================
# 全局变量
# ============================================================================
COMMON_OS_TYPE=""
COMMON_OS_FAMILY=""
COMMON_OS_DISTRO=""
COMMON_OS_VERSION=""
COMMON_OS_ARCH=""
COMMON_OS_KERNEL=""
COMMON_IS_WSL=0
COMMON_IS_CYGWIN=0
COMMON_IS_MSYS=0
COMMON_IS_MACOS=0
COMMON_IS_LINUX=0
COMMON_IS_WINDOWS=0
COMMON_IS_CONTAINER=0
COMMON_IS_VM=0
COMMON_PKG_MANAGER=""
COMMON_SVC_MANAGER=""
COMMON_LOG_DIR="/var/log/shell-scripts"
COMMON_LOG_FILE=""
COMMON_LOG_LEVEL="INFO"
COMMON_LOG_FORMAT="text"
COMMON_LOG_ROTATE_SIZE=10485760
COMMON_LOG_ROTATE_COUNT=10
COMMON_LOCK_DIR="/tmp/shell-scripts-lock"
COMMON_TEMP_DIR=""
COMMON_UMASK_BACKUP=""
COMMON_TRAP_SET=0
COMMON_ERROR_COUNT=0
COMMON_WARNING_COUNT=0
COMMON_START_TIME=0
COMMON_SCRIPT_NAME=""
COMMON_SCRIPT_DIR=""
COMMON_SCRIPT_PATH=""
COMMON_CONFIG_FILE=""
COMMON_DRY_RUN=0
COMMON_VERBOSE=0
COMMON_NO_COLOR=0
COMMON_INTERACTIVE=1
COMMON_TIMESTAMP=""
COMMON_HOSTNAME=""
COMMON_USER=""
COMMON_UID=""
COMMON_SUDO_USER=""

# ============================================================================
# 最低Bash版本检查
# ============================================================================
_common_check_bash_version() {
    local major="${BASH_VERSINFO[0]:-0}"
    local minor="${BASH_VERSINFO[1]:-0}"
    if [[ ${major} -lt 4 ]] || [[ ${major} -eq 4 && ${minor} -lt 2 ]]; then
        echo "[ERROR] 本库需要 Bash 4.2+，当前版本: ${BASH_VERSION}" >&2
        echo "[ERROR] macOS 用户请执行: brew install bash" >&2
        return 1
    fi
}

# ============================================================================
# 操作系统检测 (核心)
# ============================================================================
detect_os() {
    COMMON_OS_ARCH="$(uname -m 2>/dev/null || echo 'unknown')"
    COMMON_OS_KERNEL="$(uname -r 2>/dev/null || echo 'unknown')"
    COMMON_HOSTNAME="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo 'unknown')"
    COMMON_USER="$(whoami 2>/dev/null || echo 'unknown')"
    COMMON_UID="$(id -u 2>/dev/null || echo '0')"
    COMMON_SUDO_USER="${SUDO_USER:-}"
    COMMON_TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

    if [[ "$(uname -s)" == "Darwin" ]]; then
        COMMON_IS_MACOS=1
        COMMON_OS_TYPE="macos"
        COMMON_OS_FAMILY="darwin"
        COMMON_OS_DISTRO="macos"
        COMMON_OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo 'unknown')"
        COMMON_PKG_MANAGER="brew"
        COMMON_SVC_MANAGER="launchctl"
        return 0
    fi

    if grep -qi microsoft /proc/version 2>/dev/null; then
        COMMON_IS_WSL=1
        COMMON_IS_LINUX=1
        COMMON_OS_TYPE="wsl"
    elif [[ "$(uname -s)" == "CYGWIN"* ]]; then
        COMMON_IS_CYGWIN=1
        COMMON_IS_WINDOWS=1
        COMMON_OS_TYPE="cygwin"
        COMMON_OS_FAMILY="windows"
        COMMON_OS_DISTRO="cygwin"
        COMMON_OS_VERSION="$(uname -r 2>/dev/null || echo 'unknown')"
        COMMON_PKG_MANAGER="apt-cyg"
        COMMON_SVC_MANAGER="cygrunsrv"
        return 0
    elif [[ "$(uname -s)" == "MSYS"* ]] || [[ "$(uname -s)" == "MINGW"* ]]; then
        COMMON_IS_MSYS=1
        COMMON_IS_WINDOWS=1
        COMMON_OS_TYPE="msys"
        COMMON_OS_FAMILY="windows"
        COMMON_OS_DISTRO="msys"
        COMMON_OS_VERSION="$(uname -r 2>/dev/null || echo 'unknown')"
        COMMON_PKG_MANAGER="pacman"
        COMMON_SVC_MANAGER="sc.exe"
        return 0
    else
        COMMON_IS_LINUX=1
        COMMON_OS_TYPE="linux"
    fi

    if [[ -f /etc/os-release ]]; then
        local id="" version_id="" id_like="" name=""
        while IFS='=' read -r key value; do
            value="${value#\"}"; value="${value%\"}"
            case "${key}" in
                ID) id="${value}" ;;
                VERSION_ID) version_id="${value}" ;;
                ID_LIKE) id_like="${value}" ;;
                NAME) name="${value}" ;;
            esac
        done < /etc/os-release
        COMMON_OS_DISTRO="${id}"
        COMMON_OS_VERSION="${version_id}"

        case "${id}" in
            centos|rhel|rocky|almalinux|fedora|anolis)
                COMMON_OS_FAMILY="rhel"
                if command -v dnf &>/dev/null; then
                    COMMON_PKG_MANAGER="dnf"
                else
                    COMMON_PKG_MANAGER="yum"
                fi
                COMMON_SVC_MANAGER="systemd"
                ;;
            ubuntu|debian|linuxmint|pop|elementary|kali)
                COMMON_OS_FAMILY="debian"
                COMMON_PKG_MANAGER="apt"
                COMMON_SVC_MANAGER="systemd"
                ;;
            alpine)
                COMMON_OS_FAMILY="alpine"
                COMMON_PKG_MANAGER="apk"
                COMMON_SVC_MANAGER="openrc"
                ;;
            arch|manjaro|endeavouros|garuda)
                COMMON_OS_FAMILY="arch"
                COMMON_PKG_MANAGER="pacman"
                COMMON_SVC_MANAGER="systemd"
                ;;
            opensuse*|sles|sled)
                COMMON_OS_FAMILY="suse"
                COMMON_PKG_MANAGER="zypper"
                COMMON_SVC_MANAGER="systemd"
                ;;
            amzn|amazon)
                COMMON_OS_FAMILY="rhel"
                COMMON_PKG_MANAGER="yum"
                COMMON_SVC_MANAGER="systemd"
                ;;
            *)
                if echo "${id_like}" | grep -qi "rhel\|fedora\|centos"; then
                    COMMON_OS_FAMILY="rhel"
                    COMMON_PKG_MANAGER="yum"
                elif echo "${id_like}" | grep -qi "debian"; then
                    COMMON_OS_FAMILY="debian"
                    COMMON_PKG_MANAGER="apt"
                else
                    COMMON_OS_FAMILY="unknown"
                    COMMON_PKG_MANAGER="unknown"
                fi
                COMMON_SVC_MANAGER="systemd"
                ;;
        esac
    elif [[ -f /etc/redhat-release ]]; then
        COMMON_OS_FAMILY="rhel"
        COMMON_OS_DISTRO="rhel"
        COMMON_OS_VERSION="$(cat /etc/redhat-release | grep -oP '\d+' | head -1)"
        COMMON_PKG_MANAGER="yum"
        COMMON_SVC_MANAGER="systemd"
    elif [[ -f /etc/debian_version ]]; then
        COMMON_OS_FAMILY="debian"
        COMMON_OS_DISTRO="debian"
        COMMON_OS_VERSION="$(cat /etc/debian_version 2>/dev/null | head -1)"
        COMMON_PKG_MANAGER="apt"
        COMMON_SVC_MANAGER="systemd"
    elif [[ -f /etc/alpine-release ]]; then
        COMMON_OS_FAMILY="alpine"
        COMMON_OS_DISTRO="alpine"
        COMMON_OS_VERSION="$(cat /etc/alpine-release 2>/dev/null | head -1)"
        COMMON_PKG_MANAGER="apk"
        COMMON_SVC_MANAGER="openrc"
    elif [[ -f /etc/arch-release ]]; then
        COMMON_OS_FAMILY="arch"
        COMMON_OS_DISTRO="arch"
        COMMON_OS_VERSION="rolling"
        COMMON_PKG_MANAGER="pacman"
        COMMON_SVC_MANAGER="systemd"
    else
        COMMON_OS_FAMILY="unknown"
        COMMON_OS_DISTRO="unknown"
        COMMON_OS_VERSION="unknown"
        COMMON_PKG_MANAGER="unknown"
        COMMON_SVC_MANAGER="unknown"
    fi

    _detect_virtualization
    _detect_container
}

_detect_virtualization() {
    COMMON_IS_VM=0
    if [[ -f /sys/class/dmi/id/product_name ]]; then
        local product="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo '')"
        case "${product}" in
            VMware*|VirtualBox*|KVM*|QEMU*|Xen*|Hyper-V*|Parallels*)
                COMMON_IS_VM=1 ;;
        esac
    fi
    if systemd-detect-virt --vm &>/dev/null; then
        local virt_type="$(systemd-detect-virt --vm 2>/dev/null)"
        [[ "${virt_type}" != "none" ]] && COMMON_IS_VM=1
    fi
}

_detect_container() {
    COMMON_IS_CONTAINER=0
    if [[ -f /.dockerenv ]] || [[ -f /.dockerinit ]]; then
        COMMON_IS_CONTAINER=1
    elif grep -qE '(docker|lxc|containerd)' /proc/1/cgroup 2>/dev/null; then
        COMMON_IS_CONTAINER=1
    elif systemd-detect-virt --container &>/dev/null; then
        local ctype="$(systemd-detect-virt --container 2>/dev/null)"
        [[ "${ctype}" != "none" ]] && COMMON_IS_CONTAINER=1
    fi
}

# ============================================================================
# 跨平台包管理
# ============================================================================
pkg_update() {
    log_info "更新软件包索引..."
    case "${COMMON_PKG_MANAGER}" in
        apt)   sudo apt-get update -qq ${COMMON_DRY_RUN:+--dry-run} ;;
        yum)   sudo yum makecache fast -q ${COMMON_DRY_RUN:+--downloadonly} ;;
        dnf)   sudo dnf makecache --quiet ${COMMON_DRY_RUN:+--downloadonly} ;;
        apk)   sudo apk update ;;
        pacman) sudo pacman -Sy --noconfirm ${COMMON_DRY_RUN:+--print} ;;
        zypper) sudo zypper --non-interactive refresh ;;
        brew)  brew update ;;
        choco) choco upgrade all -y ${COMMON_DRY_RUN:+--whatif} ;;
        scoop) scoop update ;;
        *)     log_error "不支持的包管理器: ${COMMON_PKG_MANAGER}"; return 1 ;;
    esac
}

pkg_install() {
    local packages=("$@")
    [[ ${#packages[@]} -eq 0 ]] && { log_error "请指定要安装的包"; return 1; }

    log_info "安装软件包: ${packages[*]}"
    if [[ ${COMMON_DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] 将安装: ${packages[*]}"
        return 0
    fi

    case "${COMMON_PKG_MANAGER}" in
        apt)
            sudo apt-get install -y -qq "${packages[@]}" 2>&1 | tee -a "${COMMON_LOG_FILE}" ;;
        yum)
            sudo yum install -y -q "${packages[@]}" 2>&1 | tee -a "${COMMON_LOG_FILE}" ;;
        dnf)
            sudo dnf install -y --quiet "${packages[@]}" 2>&1 | tee -a "${COMMON_LOG_FILE}" ;;
        apk)
            sudo apk add "${packages[@]}" 2>&1 | tee -a "${COMMON_LOG_FILE}" ;;
        pacman)
            sudo pacman -S --noconfirm --needed "${packages[@]}" 2>&1 | tee -a "${COMMON_LOG_FILE}" ;;
        zypper)
            sudo zypper --non-interactive install "${packages[@]}" 2>&1 | tee -a "${COMMON_LOG_FILE}" ;;
        brew)
            brew install "${packages[@]}" 2>&1 | tee -a "${COMMON_LOG_FILE}" ;;
        choco)
            choco install -y "${packages[@]}" 2>&1 | tee -a "${COMMON_LOG_FILE}" ;;
        scoop)
            scoop install "${packages[@]}" 2>&1 | tee -a "${COMMON_LOG_FILE}" ;;
        *)
            log_error "不支持的包管理器: ${COMMON_PKG_MANAGER}"; return 1 ;;
    esac
}

pkg_remove() {
    local packages=("$@")
    [[ ${#packages[@]} -eq 0 ]] && { log_error "请指定要卸载的包"; return 1; }

    log_info "卸载软件包: ${packages[*]}"
    if [[ ${COMMON_DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] 将卸载: ${packages[*]}"
        return 0
    fi

    case "${COMMON_PKG_MANAGER}" in
        apt)    sudo apt-get remove -y -qq "${packages[@]}" ;;
        yum)    sudo yum remove -y -q "${packages[@]}" ;;
        dnf)    sudo dnf remove -y --quiet "${packages[@]}" ;;
        apk)    sudo apk del "${packages[@]}" ;;
        pacman) sudo pacman -Rns --noconfirm "${packages[@]}" ;;
        zypper) sudo zypper --non-interactive remove "${packages[@]}" ;;
        brew)   brew uninstall "${packages[@]}" ;;
        choco)  choco uninstall -y "${packages[@]}" ;;
        scoop)  scoop uninstall "${packages[@]}" ;;
        *)      log_error "不支持的包管理器: ${COMMON_PKG_MANAGER}"; return 1 ;;
    esac
}

pkg_is_installed() {
    local pkg="$1"
    [[ -z "${pkg}" ]] && return 1
    case "${COMMON_PKG_MANAGER}" in
        apt)    dpkg -s "${pkg}" &>/dev/null ;;
        yum|dnf) rpm -q "${pkg}" &>/dev/null ;;
        apk)    apk info -e "${pkg}" &>/dev/null ;;
        pacman) pacman -Qi "${pkg}" &>/dev/null ;;
        zypper) rpm -q "${pkg}" &>/dev/null ;;
        brew)   brew list "${pkg}" &>/dev/null ;;
        choco)  choco list --local-only "${pkg}" &>/dev/null ;;
        scoop)  scoop list "${pkg}" &>/dev/null ;;
        *)      command -v "${pkg}" &>/dev/null ;;
    esac
}

pkg_search() {
    local keyword="$1"
    [[ -z "${keyword}" ]] && { log_error "请指定搜索关键词"; return 1; }
    case "${COMMON_PKG_MANAGER}" in
        apt)    apt-cache search "${keyword}" ;;
        yum)    yum search "${keyword}" ;;
        dnf)    dnf search "${keyword}" ;;
        apk)    apk search "${keyword}" ;;
        pacman) pacman -Ss "${keyword}" ;;
        zypper) zypper search "${keyword}" ;;
        brew)   brew search "${keyword}" ;;
        choco)  choco search "${keyword}" ;;
        scoop)  scoop search "${keyword}" ;;
        *)      log_error "不支持的包管理器: ${COMMON_PKG_MANAGER}"; return 1 ;;
    esac
}

# ============================================================================
# 跨平台服务管理
# ============================================================================
svc_start() {
    local svc="$1"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }
    log_info "启动服务: ${svc}"
    case "${COMMON_SVC_MANAGER}" in
        systemd)  sudo systemctl start "${svc}" ;;
        openrc)   sudo rc-service "${svc}" start ;;
        launchctl) sudo launchctl load -w "/Library/LaunchDaemons/${svc}.plist" 2>/dev/null || \
                   sudo launchctl kickstart -k "system/${svc}" 2>/dev/null || \
                   brew services start "${svc}" 2>/dev/null ;;
        sc.exe)   sudo sc.exe start "${svc}" ;;
        *)        log_error "不支持的服务管理器: ${COMMON_SVC_MANAGER}"; return 1 ;;
    esac
}

svc_stop() {
    local svc="$1"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }
    log_info "停止服务: ${svc}"
    case "${COMMON_SVC_MANAGER}" in
        systemd)  sudo systemctl stop "${svc}" ;;
        openrc)   sudo rc-service "${svc}" stop ;;
        launchctl) sudo launchctl unload -w "/Library/LaunchDaemons/${svc}.plist" 2>/dev/null || \
                   brew services stop "${svc}" 2>/dev/null ;;
        sc.exe)   sudo sc.exe stop "${svc}" ;;
        *)        log_error "不支持的服务管理器: ${COMMON_SVC_MANAGER}"; return 1 ;;
    esac
}

svc_restart() {
    local svc="$1"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }
    log_info "重启服务: ${svc}"
    case "${COMMON_SVC_MANAGER}" in
        systemd)  sudo systemctl restart "${svc}" ;;
        openrc)   sudo rc-service "${svc}" restart ;;
        launchctl) sudo launchctl unload -w "/Library/LaunchDaemons/${svc}.plist" 2>/dev/null; \
                   sleep 1; \
                   sudo launchctl load -w "/Library/LaunchDaemons/${svc}.plist" 2>/dev/null || \
                   brew services restart "${svc}" 2>/dev/null ;;
        sc.exe)   sudo sc.exe stop "${svc}"; sleep 2; sudo sc.exe start "${svc}" ;;
        *)        log_error "不支持的服务管理器: ${COMMON_SVC_MANAGER}"; return 1 ;;
    esac
}

svc_status() {
    local svc="$1"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }
    case "${COMMON_SVC_MANAGER}" in
        systemd)  systemctl status "${svc}" --no-pager -l ;;
        openrc)   rc-service "${svc}" status ;;
        launchctl) sudo launchctl print "system/${svc}" 2>/dev/null || brew services list ;;
        sc.exe)   sc.exe query "${svc}" ;;
        *)        log_error "不支持的服务管理器: ${COMMON_SVC_MANAGER}"; return 1 ;;
    esac
}

svc_enable() {
    local svc="$1"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }
    log_info "启用服务自启动: ${svc}"
    case "${COMMON_SVC_MANAGER}" in
        systemd)   sudo systemctl enable "${svc}" ;;
        openrc)    sudo rc-update add "${svc}" default ;;
        launchctl) sudo launchctl load -w "/Library/LaunchDaemons/${svc}.plist" 2>/dev/null ;;
        sc.exe)    sudo sc.exe config "${svc}" start=auto ;;
        *)         log_error "不支持的服务管理器: ${COMMON_SVC_MANAGER}"; return 1 ;;
    esac
}

svc_disable() {
    local svc="$1"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }
    log_info "禁用服务自启动: ${svc}"
    case "${COMMON_SVC_MANAGER}" in
        systemd)   sudo systemctl disable "${svc}" ;;
        openrc)    sudo rc-update del "${svc}" default ;;
        launchctl) sudo launchctl unload -w "/Library/LaunchDaemons/${svc}.plist" 2>/dev/null ;;
        sc.exe)    sudo sc.exe config "${svc}" start=disabled ;;
        *)         log_error "不支持的服务管理器: ${COMMON_SVC_MANAGER}"; return 1 ;;
    esac
}

svc_is_active() {
    local svc="$1"
    [[ -z "${svc}" ]] && return 1
    case "${COMMON_SVC_MANAGER}" in
        systemd)   systemctl is-active "${svc}" &>/dev/null ;;
        openrc)    rc-service "${svc}" status &>/dev/null ;;
        launchctl) sudo launchctl print "system/${svc}" &>/dev/null || brew services list 2>/dev/null | grep -q "${svc}.*started" ;;
        sc.exe)    sc.exe query "${svc}" 2>/dev/null | grep -q "RUNNING" ;;
        *)         pgrep -f "${svc}" &>/dev/null ;;
    esac
}

svc_is_enabled() {
    local svc="$1"
    [[ -z "${svc}" ]] && return 1
    case "${COMMON_SVC_MANAGER}" in
        systemd)   systemctl is-enabled "${svc}" &>/dev/null ;;
        openrc)    rc-update show default 2>/dev/null | grep -q "${svc}" ;;
        launchctl) [[ -f "/Library/LaunchDaemons/${svc}.plist" ]] ;;
        sc.exe)    sc.exe qc "${svc}" 2>/dev/null | grep -q "AUTO_START" ;;
        *)         false ;;
    esac
}

svc_log() {
    local svc="$1" lines="${2:-100}"
    [[ -z "${svc}" ]] && { log_error "请指定服务名"; return 1; }
    case "${COMMON_SVC_MANAGER}" in
        systemd)   journalctl -u "${svc}" -n "${lines}" --no-pager ;;
        openrc)    cat "/var/log/${svc}.log" 2>/dev/null | tail -n "${lines}" ;;
        launchctl) log show --predicate "process == '${svc}'" --last 1h --style compact 2>/dev/null | tail -n "${lines}" ;;
        *)         cat "/var/log/${svc}.log" 2>/dev/null | tail -n "${lines}" ;;
    esac
}

# ============================================================================
# 结构化日志系统
# ============================================================================
_log_level_num() {
    case "${1^^}" in
        DEBUG) echo 0 ;;
        INFO)  echo 1 ;;
        WARN)  echo 2 ;;
        ERROR) echo 3 ;;
        FATAL) echo 4 ;;
        *)     echo 1 ;;
    esac
}

log() {
    local level="$1"; shift
    local message="$*"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S.%3N')"
    local caller="${FUNCNAME[2]:-main}:${BASH_LINENO[1]:-0}"

    if [[ $(_log_level_num "${level}") -lt $(_log_level_num "${COMMON_LOG_LEVEL}") ]]; then
        return 0
    fi

    local log_entry="[${timestamp}] [${level^^}] [${caller}] ${message}"

    if [[ -n "${COMMON_LOG_FILE}" ]]; then
        mkdir -p "$(dirname "${COMMON_LOG_FILE}")" 2>/dev/null || true
        echo "${log_entry}" >> "${COMMON_LOG_FILE}" 2>/dev/null || true
    fi

    if [[ "${COMMON_LOG_FORMAT}" == "json" ]]; then
        local json_msg
        json_msg=$(printf '%s' "${message}" | sed 's/"/\\"/g')
        echo "{\"timestamp\":\"${timestamp}\",\"level\":\"${level^^}\",\"caller\":\"${caller}\",\"message\":\"${json_msg}\"}"
        return
    fi

    case "${level^^}" in
        DEBUG)   [[ ${COMMON_VERBOSE} -eq 1 ]] && echo -e "${DIM}[DEBUG]${NC} ${message}" ;;
        INFO)    echo -e "${BLUE}[INFO]${NC} ${message}" ;;
        SUCCESS) echo -e "${GREEN}[OK]${NC} ${message}" ;;
        WARN)    echo -e "${YELLOW}[WARN]${NC} ${message}"; ((COMMON_WARNING_COUNT++)) || true ;;
        ERROR)   echo -e "${RED}[FAIL]${NC} ${message}"; ((COMMON_ERROR_COUNT++)) || true ;;
        FATAL)   echo -e "${RED}${BOLD}[FATAL]${NC} ${message}"; ((COMMON_ERROR_COUNT++)) || true ;;
        STEP)    echo -e "${MAGENTA}[STEP]${NC} ${message}" ;;
        *)       echo -e "[${level}] ${message}" ;;
    esac
}

log_info()    { log "INFO" "$@"; }
log_success() { log "SUCCESS" "$@"; }
log_warn()    { log "WARN" "$@"; }
log_error()   { log "ERROR" "$@"; }
log_fatal()   { log "FATAL" "$@"; }
log_debug()   { log "DEBUG" "$@"; }
log_step()    { log "STEP" "$@"; }

log_rotate() {
    local log_file="${1:-${COMMON_LOG_FILE}}"
    [[ -z "${log_file}" ]] && return 0
    [[ ! -f "${log_file}" ]] && return 0

    local size="$(stat -f%z "${log_file}" 2>/dev/null || stat -c%s "${log_file}" 2>/dev/null || echo 0)"
    if [[ ${size} -gt ${COMMON_LOG_ROTATE_SIZE} ]]; then
        local i
        for ((i = COMMON_LOG_ROTATE_COUNT - 1; i >= 1; i--)); do
            [[ -f "${log_file}.${i}" ]] && mv "${log_file}.${i}" "${log_file}.$((i + 1))"
        done
        mv "${log_file}" "${log_file}.1"
        gzip "${log_file}.1" 2>/dev/null &
    fi
}

log_section() {
    local title="$1"
    echo ""
    echo -e "${CYAN}$(printf '=%.0s' {1..70})${NC}"
    echo -e "${CYAN}  ${title}${NC}"
    echo -e "${CYAN}$(printf '=%.0s' {1..70})${NC}"
    echo ""
}

log_table() {
    local title="$1"; shift
    echo -e "${CYAN}┌─────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│ ${BOLD}${title}${NC}"
    echo -e "${CYAN}├──────────────────┬──────────────────────────────────┤${NC}"
    while [[ $# -ge 2 ]]; do
        printf "${CYAN}│${NC} %-16s ${CYAN}│${NC} %-32s ${CYAN}│${NC}\n" "$1" "$2"
        shift 2
    done
    echo -e "${CYAN}└──────────────────┴──────────────────────────────────┘${NC}"
}

# ============================================================================
# 高级错误处理与信号捕获
# ============================================================================
common_error_handler() {
    local exit_code=$?
    local line_no="$1"
    local func_name="${FUNCNAME[2]:-main}"
    local command="${BASH_COMMAND:-unknown}"

    log_error "错误发生在 ${func_name}() 第 ${line_no} 行: 命令 '${command}' 退出码 ${exit_code}"

    if [[ ${COMMON_VERBOSE} -eq 1 ]]; then
        local frame=0
        while caller ${frame} 2>/dev/null; do
            ((frame++)) || true
        done
    fi
}

common_cleanup() {
    local exit_code=$?
    local elapsed=$(( SECONDS - COMMON_START_TIME ))

    log_info "脚本执行完成，退出码: ${exit_code}，耗时: ${elapsed}秒"
    log_info "错误数: ${COMMON_ERROR_COUNT}，警告数: ${COMMON_WARNING_COUNT}"

    if [[ -n "${COMMON_LOCK_DIR}" ]] && [[ -d "${COMMON_LOCK_DIR}" ]]; then
        rm -rf "${COMMON_LOCK_DIR}" 2>/dev/null || true
    fi

    if [[ -n "${COMMON_UMASK_BACKUP}" ]]; then
        umask "${COMMON_UMASK_BACKUP}" 2>/dev/null || true
    fi

    log_rotate
    exit ${exit_code}
}

setup_traps() {
    if [[ ${COMMON_TRAP_SET} -eq 0 ]]; then
        trap 'common_error_handler ${LINENO}' ERR
        trap 'common_cleanup' EXIT INT TERM HUP
        COMMON_TRAP_SET=1
    fi
}

# ============================================================================
# 锁机制 (防止并发执行)
# ============================================================================
acquire_lock() {
    local lock_name="${1:-${COMMON_SCRIPT_NAME}}"
    local timeout="${2:-300}"
    local lock_file="${COMMON_LOCK_DIR}/${lock_name}.lock"

    mkdir -p "${COMMON_LOCK_DIR}" 2>/dev/null || true

    if [[ -f "${lock_file}" ]]; then
        local pid="$(cat "${lock_file}" 2>/dev/null)"
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            local lock_age=$(( $(date +%s) - $(stat -c%Y "${lock_file}" 2>/dev/null || stat -f%m "${lock_file}" 2>/dev/null || echo 0) ))
            if [[ ${lock_age} -gt ${timeout} ]]; then
                log_warn "锁文件已过期 (${lock_age}秒)，强制释放"
                rm -f "${lock_file}"
            else
                log_error "另一个实例正在运行 (PID: ${pid})，请稍后重试"
                return 1
            fi
        else
            rm -f "${lock_file}"
        fi
    fi

    echo $$ > "${lock_file}"
    log_debug "获取锁: ${lock_file}"
}

release_lock() {
    local lock_name="${1:-${COMMON_SCRIPT_NAME}}"
    local lock_file="${COMMON_LOCK_DIR}/${lock_name}.lock"
    rm -f "${lock_file}" 2>/dev/null
    log_debug "释放锁: ${lock_file}"
}

# ============================================================================
# 安全工具函数
# ============================================================================
secure_umask() {
    COMMON_UMASK_BACKUP="$(umask)"
    umask 0077
    log_debug "设置安全umask: 0077"
}

check_root() {
    if [[ ${COMMON_UID} -ne 0 ]]; then
        log_error "此操作需要root权限，请使用 sudo 执行"
        return 1
    fi
}

check_sudo() {
    if [[ ${COMMON_UID} -ne 0 ]] && ! sudo -n true 2>/dev/null; then
        log_error "需要sudo权限，请配置免密sudo或使用root执行"
        return 1
    fi
}

validate_input() {
    local input="$1" pattern="$2" name="$3"
    if [[ ! "${input}" =~ ${pattern} ]]; then
        log_error "输入验证失败: ${name}='${input}' 不匹配模式 '${pattern}'"
        return 1
    fi
}

sanitize_path() {
    local path="$1"
    path="${path//../}"
    path="${path//~\//}"
    path="${path//;/}"
    echo "${path}"
}

secure_temp_dir() {
    local prefix="${1:-shtmp}"
    COMMON_TEMP_DIR="$(mktemp -d "/tmp/${prefix}.XXXXXX")"
    chmod 700 "${COMMON_TEMP_DIR}"
    echo "${COMMON_TEMP_DIR}"
}

file_checksum() {
    local file="$1" algo="${2:-sha256}"
    [[ ! -f "${file}" ]] && { log_error "文件不存在: ${file}"; return 1; }
    case "${algo}" in
        md5)    md5sum "${file}" 2>/dev/null || md5 -q "${file}" 2>/dev/null ;;
        sha1)   sha1sum "${file}" 2>/dev/null || shasum -a 1 "${file}" 2>/dev/null ;;
        sha256) sha256sum "${file}" 2>/dev/null || shasum -a 256 "${file}" 2>/dev/null ;;
        sha512) sha512sum "${file}" 2>/dev/null || shasum -a 512 "${file}" 2>/dev/null ;;
        *)      sha256sum "${file}" 2>/dev/null || shasum -a 256 "${file}" 2>/dev/null ;;
    esac
}

verify_checksum() {
    local file="$1" expected="$2" algo="${3:-sha256}"
    local actual="$(file_checksum "${file}" "${algo}" | awk '{print $1}')"
    if [[ "${actual}" == "${expected}" ]]; then
        log_success "校验通过: ${file}"
        return 0
    else
        log_error "校验失败: ${file} (期望: ${expected}, 实际: ${actual})"
        return 1
    fi
}

encrypt_file() {
    local input="$1" output="${2:-${input}.enc}" password="${3:-}"
    [[ ! -f "${input}" ]] && { log_error "文件不存在: ${input}"; return 1; }

    if [[ -n "${password}" ]]; then
        openssl enc -aes-256-cbc -salt -pbkdf2 -in "${input}" -out "${output}" -pass "pass:${password}"
    else
        read -rsp "输入加密密码: " password; echo
        openssl enc -aes-256-cbc -salt -pbkdf2 -in "${input}" -out "${output}" -pass "pass:${password}"
    fi
    log_success "文件已加密: ${output}"
}

decrypt_file() {
    local input="$1" output="${2:-${input%.enc}}" password="${3:-}"
    [[ ! -f "${input}" ]] && { log_error "文件不存在: ${input}"; return 1; }

    if [[ -n "${password}" ]]; then
        openssl enc -aes-256-cbc -d -pbkdf2 -in "${input}" -out "${output}" -pass "pass:${password}"
    else
        read -rsp "输入解密密码: " password; echo
        openssl enc -aes-256-cbc -d -pbkdf2 -in "${input}" -out "${output}" -pass "pass:${password}"
    fi
    log_success "文件已解密: ${output}"
}

check_suid() {
    log_info "检查SUID/SGID文件..."
    local suid_files
    suid_files="$(find / -perm -4000 -type f 2>/dev/null | grep -v -E '^/(usr/bin/(sudo|passwd|chsh|chfn|newgrp|gpasswd|mount|umount|su|ping|traceroute)|usr/lib/(openssh|dbus|xorg)|bin/(su|mount|umount|ping))$')"
    if [[ -n "${suid_files}" ]]; then
        log_warn "发现可疑SUID文件:"
        echo "${suid_files}" | while read -r f; do log_warn "  ${f}"; done
    else
        log_success "未发现可疑SUID文件"
    fi
}

# ============================================================================
# 性能监控工具
# ============================================================================
perf_cpu_usage() {
    if [[ ${COMMON_IS_MACOS} -eq 1 ]]; then
        ps -A -o %cpu | awk 'NR>1{sum+=$1} END{printf "%.1f", sum}'
    else
        top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1
    fi
}

perf_mem_usage() {
    if [[ ${COMMON_IS_MACOS} -eq 1 ]]; then
        local total="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
        local used="$(vm_stat 2>/dev/null | grep 'Pages active' | awk '{print $3}' | tr -d '.')"
        [[ ${total} -gt 0 ]] && [[ -n "${used}" ]] && awk "BEGIN{printf \"%.1f\", ${used}*4096/${total}*100}" || echo "0.0"
    else
        free | awk '/Mem:/{printf "%.1f", $3/$2*100}'
    fi
}

perf_disk_usage() {
    local path="${1:-/}"
    if [[ ${COMMON_IS_MACOS} -eq 1 ]]; then
        df -h "${path}" | awk 'NR==2{print $5}' | tr -d '%'
    else
        df -h "${path}" | awk 'NR==2{print $5}' | tr -d '%'
    fi
}

perf_load_avg() {
    if [[ ${COMMON_IS_MACOS} -eq 1 ]]; then
        sysctl -n vm.loadavg 2>/dev/null | awk '{print $2, $3, $4}' || uptime | awk -F'load averages: ' '{print $2}'
    else
        cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}' || uptime | awk -F'load average: ' '{print $2}'
    fi
}

perf_network_stats() {
    if [[ ${COMMON_IS_MACOS} -eq 1 ]]; then
        netstat -ibn 2>/dev/null | awk 'NR>1 && $1!="lo0"{print $1, "RX:", $7, "TX:", $10}'
    else
        cat /proc/net/dev 2>/dev/null | awk 'NR>2 && $1!="lo:"{gsub(/:/,"",$1); print $1, "RX:", $2, "TX:", $10}'
    fi
}

perf_process_top() {
    local count="${1:-10}"
    if [[ ${COMMON_IS_MACOS} -eq 1 ]]; then
        ps -arcwww -o %cpu,%mem,pid,command | head -n $((count + 1))
    else
        ps -eo %cpu,%mem,pid,cmd --sort=-%cpu | head -n $((count + 1))
    fi
}

perf_io_stats() {
    if [[ ${COMMON_IS_MACOS} -eq 1 ]]; then
        iostat -d -c 3 2>/dev/null | head -20
    else
        iostat -dx 1 3 2>/dev/null | tail -20 || cat /proc/diskstats 2>/dev/null | head -20
    fi
}

# ============================================================================
# 网络工具函数
# ============================================================================
net_check_port() {
    local port="$1" host="${2:-localhost}" timeout="${3:-3}"
    [[ -z "${port}" ]] && { log_error "请指定端口号"; return 1; }

    if command -v nc &>/dev/null; then
        nc -z -w "${timeout}" "${host}" "${port}" 2>/dev/null
    elif command -v timeout &>/dev/null; then
        timeout "${timeout}" bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null
    elif [[ ${COMMON_IS_MACOS} -eq 1 ]]; then
        (echo >/dev/tcp/"${host}"/"${port}") &>/dev/null
    else
        curl -s --connect-timeout "${timeout}" "http://${host}:${port}" &>/dev/null
    fi
}

net_check_url() {
    local url="$1" timeout="${2:-10}" expected_code="${3:-200}"
    [[ -z "${url}" ]] && { log_error "请指定URL"; return 1; }

    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout "${timeout}" --max-time "${timeout}" "${url}" 2>/dev/null)"
    if [[ "${code}" == "${expected_code}" ]]; then
        return 0
    else
        log_error "URL检查失败: ${url} (期望: ${expected_code}, 实际: ${code})"
        return 1
    fi
}

net_get_public_ip() {
    local sources=(
        "https://api.ipify.org"
        "https://ifconfig.me"
        "https://icanhazip.com"
        "https://checkip.amazonaws.com"
    )
    for src in "${sources[@]}"; do
        local ip
        ip="$(curl -s --connect-timeout 5 --max-time 10 "${src}" 2>/dev/null)"
        if [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "${ip}"
            return 0
        fi
    done
    log_error "无法获取公网IP"
    return 1
}

net_get_local_ip() {
    if [[ ${COMMON_IS_MACOS} -eq 1 ]]; then
        ifconfig 2>/dev/null | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}' | head -1
    else
        ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I 2>/dev/null | awk '{print $1}'
    fi
}

net_dns_lookup() {
    local domain="$1" type="${2:-A}"
    [[ -z "${domain}" ]] && { log_error "请指定域名"; return 1; }

    if command -v dig &>/dev/null; then
        dig +short "${domain}" "${type}" 2>/dev/null
    elif command -v nslookup &>/dev/null; then
        nslookup -type="${type}" "${domain}" 2>/dev/null | grep -A1 "Name:" | grep "Address" | awk '{print $2}'
    elif command -v host &>/dev/null; then
        host -t "${type}" "${domain}" 2>/dev/null | awk '{print $NF}'
    else
        log_error "未找到DNS查询工具 (dig/nslookup/host)"
        return 1
    fi
}

net_ssl_check() {
    local host="$1" port="${2:-443}"
    [[ -z "${host}" ]] && { log_error "请指定主机名"; return 1; }

    echo | openssl s_client -servername "${host}" -connect "${host}:${port}" 2>/dev/null | \
        openssl x509 -noout -dates -subject -issuer 2>/dev/null
}

net_ssl_expiry() {
    local host="$1" port="${2:-443}"
    [[ -z "${host}" ]] && { log_error "请指定主机名"; return 1; }

    local expiry
    expiry="$(echo | openssl s_client -servername "${host}" -connect "${host}:${port}" 2>/dev/null | \
              openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
    if [[ -n "${expiry}" ]]; then
        local expiry_epoch="$(date -d "${expiry}" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "${expiry}" +%s 2>/dev/null)"
        local now_epoch="$(date +%s)"
        local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
        echo "${days_left}"
    else
        echo "-1"
    fi
}

# ============================================================================
# 文件系统工具函数
# ============================================================================
fs_disk_usage() {
    local path="${1:-/}"
    if [[ ${COMMON_IS_MACOS} -eq 1 ]]; then
        df -h "${path}"
    else
        df -hT "${path}"
    fi
}

fs_dir_size() {
    local dir="$1"
    [[ -z "${dir}" ]] && { log_error "请指定目录"; return 1; }
    [[ ! -d "${dir}" ]] && { log_error "目录不存在: ${dir}"; return 1; }

    if [[ ${COMMON_IS_MACOS} -eq 1 ]]; then
        du -sh "${dir}" 2>/dev/null
    else
        du -sh --apparent-size "${dir}" 2>/dev/null
    fi
}

fs_find_large() {
    local path="${1:-/}" min_size="${2:-100M}" count="${3:-20}"
    log_info "查找大于 ${min_size} 的文件 (前 ${count} 个)..."
    find "${path}" -type f -size "+${min_size}" -exec ls -lh {} \; 2>/dev/null | \
        awk '{print $5, $9}' | sort -rh | head -n "${count}"
}

fs_find_old() {
    local path="${1:-/}" days="${2:-90}" count="${3:-20}"
    log_info "查找超过 ${days} 天未修改的文件..."
    find "${path}" -type f -mtime "+${days}" -exec ls -lh {} \; 2>/dev/null | \
        awk '{print $6, $7, $8, $9}' | head -n "${count}"
}

fs_inodes_usage() {
    if [[ ${COMMON_IS_MACOS} -eq 1 ]]; then
        df -i 2>/dev/null || df -h
    else
        df -i
    fi
}

fs_backup_file() {
    local file="$1" backup_dir="${2:-/var/backups/shell-scripts}"
    [[ ! -f "${file}" ]] && { log_error "文件不存在: ${file}"; return 1; }

    mkdir -p "${backup_dir}" 2>/dev/null || true
    local backup_name="$(basename "${file}").${COMMON_TIMESTAMP}.bak"
    cp -a "${file}" "${backup_dir}/${backup_name}"
    log_success "文件已备份: ${backup_dir}/${backup_name}"
}

fs_ensure_dir() {
    local dir="$1" mode="${2:-755}" owner="${3:-}"
    mkdir -p "${dir}" 2>/dev/null || true
    chmod "${mode}" "${dir}" 2>/dev/null || true
    [[ -n "${owner}" ]] && chown "${owner}" "${dir}" 2>/dev/null || true
}

fs_safe_remove() {
    local target="$1"
    [[ -z "${target}" ]] && return 1
    [[ "${target}" == "/" ]] && { log_error "拒绝删除根目录"; return 1; }
    [[ "${target}" == "/home" ]] && { log_error "拒绝删除/home"; return 1; }
    [[ "${target}" == "/etc" ]] && { log_error "拒绝删除/etc"; return 1; }
    [[ "${target}" == "/var" ]] && { log_error "拒绝删除/var"; return 1; }

    rm -rf "${target}"
}

# ============================================================================
# 进程管理工具
# ============================================================================
proc_find() {
    local pattern="$1"
    [[ -z "${pattern}" ]] && { log_error "请指定进程名或模式"; return 1; }
    ps aux 2>/dev/null | grep -E "${pattern}" | grep -v grep
}

proc_kill_by_name() {
    local name="$1" signal="${2:-TERM}"
    [[ -z "${name}" ]] && { log_error "请指定进程名"; return 1; }
    pkill -"${signal}" -f "${name}" 2>/dev/null
}

proc_kill_by_port() {
    local port="$1" signal="${2:-TERM}"
    [[ -z "${port}" ]] && { log_error "请指定端口号"; return 1; }

    if [[ ${COMMON_IS_MACOS} -eq 1 ]]; then
        local pid="$(lsof -ti :${port} 2>/dev/null)"
        [[ -n "${pid}" ]] && kill -"${signal}" "${pid}"
    else
        local pid="$(ss -tlnp 2>/dev/null | grep ":${port}" | grep -oP 'pid=\K[0-9]+' | head -1)"
        [[ -n "${pid}" ]] && kill -"${signal}" "${pid}"
    fi
}

proc_wait_for() {
    local pid="$1" timeout="${2:-300}"
    [[ -z "${pid}" ]] && { log_error "请指定PID"; return 1; }

    local elapsed=0
    while kill -0 "${pid}" 2>/dev/null; do
        sleep 1
        ((elapsed++)) || true
        if [[ ${elapsed} -ge ${timeout} ]]; then
            log_error "等待进程 ${pid} 超时 (${timeout}秒)"
            return 1
        fi
    done
    return 0
}

proc_memory_top() {
    local count="${1:-10}"
    if [[ ${COMMON_IS_MACOS} -eq 1 ]]; then
        ps -arcwww -o %mem,rss,pid,command | head -n $((count + 1))
    else
        ps -eo %mem,rss,pid,cmd --sort=-%mem | head -n $((count + 1))
    fi
}

# ============================================================================
# 配置文件解析器
# ============================================================================
config_parse() {
    local config_file="$1"
    [[ ! -f "${config_file}" ]] && { log_error "配置文件不存在: ${config_file}"; return 1; }

    declare -gA CONFIG_VALUES

    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%%#*}"
        line="${line%%;*}"
        line="${line// /}"
        [[ -z "${line}" ]] && continue

        if [[ "${line}" =~ ^\[([^]]+)\]$ ]]; then
            local section="${BASH_REMATCH[1]}"
            continue
        fi

        if [[ "${line}" =~ ^([^=]+)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            value="${value#\"}"; value="${value%\"}"
            value="${value#\'}"; value="${value%\'}"
            if [[ -n "${section:-}" ]]; then
                CONFIG_VALUES["${section}.${key}"]="${value}"
            else
                CONFIG_VALUES["${key}"]="${value}"
            fi
        fi
    done < "${config_file}"

    log_debug "配置文件已解析: ${config_file} (${#CONFIG_VALUES[@]} 项)"
}

config_get() {
    local key="$1" default="${2:-}"
    echo "${CONFIG_VALUES[${key}]:-${default}}"
}

config_set() {
    local key="$1" value="$2"
    CONFIG_VALUES["${key}"]="${value}"
}

# ============================================================================
# 通知系统
# ============================================================================
notify_email() {
    local to="$1" subject="$2" body="$3"
    [[ -z "${to}" ]] && { log_error "请指定收件人"; return 1; }

    if command -v mail &>/dev/null; then
        echo "${body}" | mail -s "${subject}" "${to}"
    elif command -v sendmail &>/dev/null; then
        echo -e "Subject: ${subject}\nTo: ${to}\n\n${body}" | sendmail -t
    else
        log_warn "未找到邮件发送工具 (mail/sendmail)"
        return 1
    fi
}

notify_dingtalk() {
    local webhook="$1" title="$2" text="$3"
    [[ -z "${webhook}" ]] && { log_error "请指定钉钉Webhook"; return 1; }

    local payload
    payload="$(cat <<EOF
{
    "msgtype": "markdown",
    "markdown": {
        "title": "${title}",
        "text": "${text}"
    }
}
EOF
)"
    curl -s -X POST -H 'Content-Type: application/json' -d "${payload}" "${webhook}" &>/dev/null
}

notify_wechat() {
    local webhook="$1" content="$2"
    [[ -z "${webhook}" ]] && { log_error "请指定企业微信Webhook"; return 1; }

    local payload
    payload="$(cat <<EOF
{
    "msgtype": "text",
    "text": {
        "content": "${content}"
    }
}
EOF
)"
    curl -s -X POST -H 'Content-Type: application/json' -d "${payload}" "${webhook}" &>/dev/null
}

notify_slack() {
    local webhook="$1" text="$2"
    [[ -z "${webhook}" ]] && { log_error "请指定Slack Webhook"; return 1; }

    local payload
    payload="$(cat <<EOF
{
    "text": "${text}"
}
EOF
)"
    curl -s -X POST -H 'Content-Type: application/json' -d "${payload}" "${webhook}" &>/dev/null
}

notify_webhook() {
    local url="$1" payload="$2"
    [[ -z "${url}" ]] && { log_error "请指定Webhook URL"; return 1; }
    curl -s -X POST -H 'Content-Type: application/json' -d "${payload}" "${url}" &>/dev/null
}

notify_send() {
    local type="${1:-webhook}" webhook="$2" title="$3" body="$4"
    case "${type}" in
        email)    notify_email "${webhook}" "${title}" "${body}" ;;
        dingtalk) notify_dingtalk "${webhook}" "${title}" "${body}" ;;
        wechat)   notify_wechat "${webhook}" "${body}" ;;
        slack)    notify_slack "${webhook}" "${body}" ;;
        webhook)  notify_webhook "${webhook}" "${body}" ;;
        *)        log_warn "不支持的通知类型: ${type}" ;;
    esac
}

# ============================================================================
# 用户交互工具
# ============================================================================
confirm() {
    local message="${1:-确认执行?}" default="${2:-n}"
    if [[ ${COMMON_INTERACTIVE} -eq 0 ]]; then
        return 0
    fi

    local prompt
    if [[ "${default}" == "y" ]]; then
        prompt="${message} [Y/n] "
    else
        prompt="${message} [y/N] "
    fi

    read -rp "$(echo -e "${YELLOW}${prompt}${NC}")" answer 2>/dev/null
    answer="${answer:-${default}}"

    [[ "${answer}" =~ ^[Yy] ]] && return 0 || return 1
}

prompt_input() {
    local message="$1" default="${2:-}" is_secret="${3:-0}"
    echo -ne "${CYAN}${message}${NC}: "
    if [[ "${is_secret}" == "1" ]]; then
        read -rs answer 2>/dev/null; echo
    else
        read -r answer 2>/dev/null
    fi
    echo "${answer:-${default}}"
}

select_option() {
    local message="$1"; shift
    local options=("$@")
    echo -e "${CYAN}${message}${NC}"
    for i in "${!options[@]}"; do
        echo -e "  ${GREEN}$((i + 1)))${NC} ${options[${i}]}"
    done
    read -rp "$(echo -e "${YELLOW}请选择 [1-${#options[@]}]: ${NC}")" choice 2>/dev/null
    if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -le "${#options[@]}" ]]; then
        echo "${options[$((choice - 1))]}"
    else
        echo ""
    fi
}

progress_bar() {
    local current="$1" total="$2" width="${3:-50}" label="${4:-}"
    local percentage=$(( current * 100 / total ))
    local filled=$(( current * width / total ))
    local empty=$(( width - filled ))

    printf "\r${label} [${GREEN}%${filled}s${NC}${DIM}%${empty}s${NC] %3d%%" "" "" "${percentage}"
    [[ ${current} -eq ${total} ]] && echo
}

spinner() {
    local pid="$1" message="${2:-处理中}"
    local spin='|/-\'
    local i=0
    while kill -0 "${pid}" 2>/dev/null; do
        i=$(( (i + 1) % 4 ))
        printf "\r${CYAN}${spin:${i}:1}${NC} ${message}..."
        sleep 0.1
    done
    printf "\r%${#message}s\r" ""
}

# ============================================================================
# 跨平台工具检测与安装
# ============================================================================
require_cmd() {
    local cmd="$1" install_hint="${2:-}"
    if ! command -v "${cmd}" &>/dev/null; then
        log_error "缺少必要命令: ${cmd}"
        if [[ -n "${install_hint}" ]]; then
            log_info "安装提示: ${install_hint}"
        else
            case "${COMMON_PKG_MANAGER}" in
                apt)    log_info "尝试安装: sudo apt-get install -y ${cmd}" ;;
                yum)    log_info "尝试安装: sudo yum install -y ${cmd}" ;;
                dnf)    log_info "尝试安装: sudo dnf install -y ${cmd}" ;;
                apk)    log_info "尝试安装: sudo apk add ${cmd}" ;;
                pacman) log_info "尝试安装: sudo pacman -S ${cmd}" ;;
                zypper) log_info "尝试安装: sudo zypper install ${cmd}" ;;
                brew)   log_info "尝试安装: brew install ${cmd}" ;;
            esac
        fi
        return 1
    fi
    return 0
}

require_cmds() {
    local missing=0
    for cmd in "$@"; do
        if ! command -v "${cmd}" &>/dev/null; then
            log_error "缺少必要命令: ${cmd}"
            missing=1
        fi
    done
    return ${missing}
}

ensure_cmd() {
    local cmd="$1"
    if ! command -v "${cmd}" &>/dev/null; then
        log_info "自动安装缺失命令: ${cmd}"
        pkg_install "${cmd}" 2>/dev/null && return 0
        log_error "无法自动安装: ${cmd}，请手动安装"
        return 1
    fi
}

# ============================================================================
# 跨平台路径处理
# ============================================================================
path_normalize() {
    local path="$1"
    if [[ ${COMMON_IS_WINDOWS} -eq 1 ]] || [[ ${COMMON_IS_WSL} -eq 1 ]]; then
        cygpath -u "${path}" 2>/dev/null || echo "${path}"
    else
        readlink -f "${path}" 2>/dev/null || realpath "${path}" 2>/dev/null || echo "${path}"
    fi
}

path_to_windows() {
    if [[ ${COMMON_IS_WSL} -eq 1 ]]; then
        wslpath -w "$1" 2>/dev/null || echo "$1"
    elif [[ ${COMMON_IS_CYGWIN} -eq 1 ]]; then
        cygpath -w "$1" 2>/dev/null || echo "$1"
    else
        echo "$1"
    fi
}

path_to_unix() {
    if [[ ${COMMON_IS_WSL} -eq 1 ]]; then
        wslpath -u "$1" 2>/dev/null || echo "$1"
    elif [[ ${COMMON_IS_CYGWIN} -eq 1 ]]; then
        cygpath -u "$1" 2>/dev/null || echo "$1"
    else
        echo "$1"
    fi
}

# ============================================================================
# 系统信息收集
# ============================================================================
sys_info() {
    detect_os
    log_section "系统信息"

    echo -e "${BOLD}操作系统:${NC}     ${COMMON_OS_DISTRO} ${COMMON_OS_VERSION} (${COMMON_OS_FAMILY})"
    echo -e "${BOLD}架构:${NC}         ${COMMON_OS_ARCH}"
    echo -e "${BOLD}内核:${NC}         ${COMMON_OS_KERNEL}"
    echo -e "${BOLD}主机名:${NC}       ${COMMON_HOSTNAME}"
    echo -e "${BOLD}当前用户:${NC}     ${COMMON_USER} (UID: ${COMMON_UID})"
    [[ -n "${COMMON_SUDO_USER}" ]] && echo -e "${BOLD}Sudo用户:${NC}    ${COMMON_SUDO_USER}"
    echo -e "${BOLD}包管理器:${NC}     ${COMMON_PKG_MANAGER}"
    echo -e "${BOLD}服务管理器:${NC}   ${COMMON_SVC_MANAGER}"
    echo -e "${BOLD}WSL:${NC}          $([[ ${COMMON_IS_WSL} -eq 1 ]] && echo '是' || echo '否')"
    echo -e "${BOLD}容器:${NC}         $([[ ${COMMON_IS_CONTAINER} -eq 1 ]] && echo '是' || echo '否')"
    echo -e "${BOLD}虚拟机:${NC}       $([[ ${COMMON_IS_VM} -eq 1 ]] && echo '是' || echo '否')"
    echo ""
    echo -e "${BOLD}CPU使用率:${NC}    $(perf_cpu_usage)%"
    echo -e "${BOLD}内存使用率:${NC}   $(perf_mem_usage)%"
    echo -e "${BOLD}磁盘使用率:${NC}   $(perf_disk_usage /)%"
    echo -e "${BOLD}负载均值:${NC}     $(perf_load_avg)"
    echo -e "${BOLD}本地IP:${NC}       $(net_get_local_ip)"
}

# ============================================================================
# 基础库初始化
# ============================================================================
common_init() {
    _common_check_bash_version || return 1

    COMMON_SCRIPT_NAME="$(basename "${BASH_SOURCE[1]:-${0}}" .sh)"
    COMMON_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]:-${0}}")" && pwd)"
    COMMON_SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[1]:-${0}}" 2>/dev/null || realpath "${BASH_SOURCE[1]:-${0}}" 2>/dev/null || echo "${BASH_SOURCE[1]:-${0}}")"
    COMMON_START_TIME="${SECONDS}"

    detect_os

    COMMON_LOG_DIR="${COMMON_LOG_DIR}/${COMMON_SCRIPT_NAME}"
    COMMON_LOG_FILE="${COMMON_LOG_DIR}/${COMMON_SCRIPT_NAME}_${COMMON_TIMESTAMP}.log"
    mkdir -p "${COMMON_LOG_DIR}" 2>/dev/null || true

    setup_traps
    secure_umask

    log_debug "基础库初始化完成 (v${COMMON_LIB_VERSION})"
    log_debug "OS: ${COMMON_OS_DISTRO} ${COMMON_OS_VERSION} (${COMMON_OS_FAMILY})"
    log_debug "包管理器: ${COMMON_PKG_MANAGER}, 服务管理器: ${COMMON_SVC_MANAGER}"
    log_debug "WSL: ${COMMON_IS_WSL}, 容器: ${COMMON_IS_CONTAINER}, 虚拟机: ${COMMON_IS_VM}"
}

COMMON_LIB_LOADED=1
