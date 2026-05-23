#!/usr/bin/env bash
# ============================================================================
#  系统初始化自动化脚本 (System Initialization Script)
#  支持: CentOS/RHEL 7/8/9, Ubuntu/Debian, Alpine, Arch Linux, openSUSE
#  版本: 2.0.0
#  作者: gxfdev
#  仓库: https://github.com/gxfdev/shell-scripts
# ============================================================================
#  用法:
#    bash system_init.sh --all              # 执行全部初始化
#    bash system_init.sh --mirror           # 仅配置镜像源
#    bash system_init.sh --packages         # 仅安装基础包
#    bash system_init.sh --kernel           # 仅优化内核参数
#    bash system_init.sh --network          # 仅优化网络
#    bash system_init.sh --ssh              # 仅加固SSH
#    bash system_init.sh --firewall         # 仅配置防火墙
#    bash system_init.sh --security         # 仅安全加固
#    bash system_init.sh --docker           # 仅安装Docker
#    bash system_init.sh --devtools         # 仅安装开发工具
#    bash system_init.sh --report           # 仅生成系统报告
#    bash system_init.sh --dry-run          # 模拟运行不实际执行
#    bash system_init.sh --config file.cfg  # 使用配置文件
#    bash system_init.sh --rollback         # 回滚上次初始化
# ============================================================================

set -euo pipefail

SCRIPT_VERSION="2.0.0"
SCRIPT_NAME="system_init"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/var/log/system_init"
BACKUP_DIR="/var/backups/system_init"
CONFIG_FILE=""
DRY_RUN=0
VERBOSE=0
INTERACTIVE=1
ROLLBACK_MODE=0
CHECK_MODE=""
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOG_DIR}/system_init_${TIMESTAMP}.log"
LOCK_FILE="/tmp/system_init.lock"

declare -A SELECTED_MODULES
declare -A OS_INFO
declare -A CONFIG_VALUES

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
WHITE='\033[1;37m'; NC='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'

print_banner() {
    echo -e "${CYAN}"
    cat << 'BANNER'
  ======================================================================
  =     SYSTEM INIT Automation Script v2.0.0                           =
  =     https://github.com/gxfdev/shell-scripts                       =
  ======================================================================
BANNER
    echo -e "${NC}"
    echo -e "${WHITE}  仓库: https://github.com/gxfdev/shell-scripts${NC}"
    echo -e "${WHITE}  时间: ${TIMESTAMP}${NC}"
    echo ""
}

log() {
    local level="$1"; shift; local message="$*"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    mkdir -p "${LOG_DIR}" 2>/dev/null || true
    echo "[${timestamp}] [${level}] ${message}" >> "${LOG_FILE}" 2>/dev/null || true
    case "${level}" in
        INFO)    echo -e "${BLUE}[INFO]${NC} ${message}" ;;
        SUCCESS) echo -e "${GREEN}[OK]${NC} ${message}" ;;
        WARNING) echo -e "${YELLOW}[WARN]${NC} ${message}" ;;
        ERROR)   echo -e "${RED}[FAIL]${NC} ${message}" ;;
        DEBUG)   [[ ${VERBOSE} -eq 1 ]] && echo -e "${DIM}[DEBUG]${NC} ${message}" ;;
        STEP)    echo -e "${MAGENTA}[STEP]${NC} ${message}" ;;
        *)       echo -e "[${level}] ${message}" ;;
    esac
}

log_info()    { log "INFO" "$@"; }
log_success() { log "SUCCESS" "$@"; }
log_warning() { log "WARNING" "$@"; }
log_error()   { log "ERROR" "$@"; }
log_debug()   { log "DEBUG" "$@"; }
log_step()    { log "STEP" "$@"; }

die() { log "ERROR" "$@"; exit 1; }

confirm_action() {
    local prompt="$1" default="${2:-n}"
    [[ ${INTERACTIVE} -eq 0 ]] && return 0
    local suffix; [[ "${default}" == "y" ]] && suffix="[Y/n]" || suffix="[y/N]"
    echo -ne "${YELLOW}${prompt} ${suffix}: ${NC}"; read -r answer
    answer="${answer:-${default}}"
    case "${answer}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

execute_cmd() {
    local description="$1"; shift; local cmd=("$@")
    log_debug "执行: ${cmd[*]}"
    [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟运行] ${description}: ${cmd[*]}"; return 0; }
    if "${cmd[@]}" 2>&1 | tee -a "${LOG_FILE}"; then
        log_success "${description} 完成"; return 0
    else
        log_error "${description} 失败"; return 1
    fi
}

backup_file() {
    local file="$1"
    [[ -f "${file}" ]] || return 0
    mkdir -p "${BACKUP_DIR}/${TIMESTAMP}" 2>/dev/null || true
    local backup_name="$(echo "${file}" | tr '/' '_')"
    cp -a "${file}" "${BACKUP_DIR}/${TIMESTAMP}/${backup_name}" 2>/dev/null
    log_debug "已备份: ${file}"
}

write_config() {
    local file="$1" content="$2" mode="${3:-0644}"
    backup_file "${file}"
    [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟运行] 写入文件: ${file}"; return 0; }
    echo "${content}" > "${file}"; chmod "${mode}" "${file}" 2>/dev/null || true
}

append_config() {
    local file="$1" content="$2"
    [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟运行] 追加到文件: ${file}"; return 0; }
    if [[ -f "${file}" ]] && ! grep -qF "${content}" "${file}" 2>/dev/null; then
        echo "${content}" >> "${file}"
    elif [[ ! -f "${file}" ]]; then
        echo "${content}" >> "${file}"
    fi
}

acquire_lock() {
    if [[ -f "${LOCK_FILE}" ]]; then
        local pid="$(cat "${LOCK_FILE}" 2>/dev/null)"
        [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null && die "另一个系统初始化进程正在运行 (PID: ${pid})"
        rm -f "${LOCK_FILE}"
    fi
    echo $$ > "${LOCK_FILE}"
}

release_lock() { rm -f "${LOCK_FILE}"; }

# ============================================================================
# 操作系统检测
# ============================================================================

detect_os() {
    log_step "检测操作系统..."
    OS_INFO[hostname]="$(hostname 2>/dev/null || echo 'unknown')"
    OS_INFO[kernel]="$(uname -r 2>/dev/null || echo 'unknown')"
    OS_INFO[arch]="$(uname -m 2>/dev/null || echo 'unknown')"
    OS_INFO[cpu_cores]="$(nproc 2>/dev/null || echo 1)"
    OS_INFO[cpu_model]="$(grep 'model name' /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs 2>/dev/null || echo 'unknown')"
    OS_INFO[mem_total]="$(free -g | awk '/^Mem:/{print $2}')"
    OS_INFO[disk_total]="$(df -hG / | awk 'NR==2{print $2}')"

    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_INFO[id]="${ID:-unknown}"; OS_INFO[id_like]="${ID_LIKE:-}"
        OS_INFO[name]="${NAME:-unknown}"; OS_INFO[version]="${VERSION:-unknown}"
        OS_INFO[version_id]="${VERSION_ID:-unknown}"; OS_INFO[pretty_name]="${PRETTY_NAME:-unknown}"
    elif [[ -f /etc/redhat-release ]]; then
        OS_INFO[id]="rhel"; OS_INFO[name]="$(cat /etc/redhat-release)"
        OS_INFO[version_id]="$(cat /etc/redhat-release | grep -oP '\d+' | head -1)"
    elif [[ -f /etc/alpine-release ]]; then
        OS_INFO[id]="alpine"; OS_INFO[name]="Alpine Linux"; OS_INFO[version_id]="$(cat /etc/alpine-release)"
    else
        OS_INFO[id]="unknown"; OS_INFO[name]="Unknown Linux"
    fi

    case "${OS_INFO[id]}" in
        centos|rhel|rocky|almalinux|ol|fedora)
            OS_INFO[family]="rhel"; OS_INFO[pkg_manager]="yum"
            [[ "${OS_INFO[id]}" == "fedora" || "${OS_INFO[version_id]%%.*}" -ge 8 ]] 2>/dev/null && OS_INFO[pkg_manager]="dnf"
            OS_INFO[service_manager]="systemd"; OS_INFO[firewall]="firewalld"; OS_INFO[config_dir]="/etc/sysconfig" ;;
        ubuntu|debian|linuxmint|pop|elementary)
            OS_INFO[family]="debian"; OS_INFO[pkg_manager]="apt"
            OS_INFO[service_manager]="systemd"; OS_INFO[firewall]="ufw"; OS_INFO[config_dir]="/etc/default" ;;
        alpine)
            OS_INFO[family]="alpine"; OS_INFO[pkg_manager]="apk"
            OS_INFO[service_manager]="openrc"; OS_INFO[firewall]="iptables"; OS_INFO[config_dir]="/etc/conf.d" ;;
        arch|manjaro|endeavouros|garuda)
            OS_INFO[family]="arch"; OS_INFO[pkg_manager]="pacman"
            OS_INFO[service_manager]="systemd"; OS_INFO[firewall]="iptables"; OS_INFO[config_dir]="/etc" ;;
        opensuse*|sles|sled)
            OS_INFO[family]="suse"; OS_INFO[pkg_manager]="zypper"
            OS_INFO[service_manager]="systemd"; OS_INFO[firewall]="firewalld"; OS_INFO[config_dir]="/etc/sysconfig" ;;
        *)
            OS_INFO[family]="unknown"; OS_INFO[pkg_manager]="unknown"
            OS_INFO[service_manager]="unknown"; OS_INFO[firewall]="iptables"; OS_INFO[config_dir]="/etc" ;;
    esac

    OS_INFO[is_container]=0
    [[ -f /.dockerenv ]] || grep -qE '(docker|lxc|containerd)' /proc/1/cgroup 2>/dev/null && OS_INFO[is_container]=1
    OS_INFO[virtual]="physical"
    command -v systemd-detect-virt &>/dev/null && OS_INFO[virtual]="$(systemd-detect-virt 2>/dev/null || echo 'physical')"

    log_success "操作系统检测完成:"
    log_info "  系统: ${OS_INFO[pretty_name]} | 家族: ${OS_INFO[family]}"
    log_info "  版本: ${OS_INFO[version_id]} | 内核: ${OS_INFO[kernel]} | 架构: ${OS_INFO[arch]}"
    log_info "  CPU: ${OS_INFO[cpu_model]} (${OS_INFO[cpu_cores]}核) | 内存: ${OS_INFO[mem_total]}GB"
    log_info "  包管理器: ${OS_INFO[pkg_manager]} | 服务管理: ${OS_INFO[service_manager]} | 防火墙: ${OS_INFO[firewall]}"
    [[ ${OS_INFO[is_container]} -eq 1 ]] && log_warning "  检测到容器环境, 部分功能可能受限"
}

check_root() { [[ ${EUID} -ne 0 ]] && die "此脚本需要root权限运行, 请使用 sudo 或切换到root用户"; }

check_prerequisites() {
    log_step "检查前置条件..."
    local missing_cmds=() required_cmds=(curl wget tar gzip)
    for cmd in "${required_cmds[@]}"; do
        ! command -v "${cmd}" &>/dev/null && missing_cmds+=("${cmd}")
    done
    if [[ ${#missing_cmds[@]} -gt 0 ]]; then
        log_warning "缺少必要命令: ${missing_cmds[*]}, 正在安装..."
        case "${OS_INFO[pkg_manager]}" in
            yum)    yum install -y "${missing_cmds[@]}" 2>/dev/null || true ;;
            dnf)    dnf install -y "${missing_cmds[@]}" 2>/dev/null || true ;;
            apt)    apt-get update -qq && apt-get install -y "${missing_cmds[@]}" 2>/dev/null || true ;;
            apk)    apk add --no-cache "${missing_cmds[@]}" 2>/dev/null || true ;;
            pacman) pacman -Sy --noconfirm "${missing_cmds[@]}" 2>/dev/null || true ;;
            zypper) zypper install -y "${missing_cmds[@]}" 2>/dev/null || true ;;
        esac
    fi
    log_success "前置条件检查完成"
}

# ============================================================================
# 镜像源配置
# ============================================================================

configure_mirror() {
    log_step "配置系统镜像源..."
    local mirror_site="${CONFIG_VALUES[mirror_site]:-https://mirrors.aliyun.com}"
    case "${OS_INFO[id]}" in
        centos|rhel|rocky|almalinux|ol) configure_rhel_mirror "${mirror_site}" ;;
        fedora)                         configure_fedora_mirror "${mirror_site}" ;;
        ubuntu)                         configure_ubuntu_mirror "${mirror_site}" ;;
        debian)                         configure_debian_mirror "${mirror_site}" ;;
        alpine)                         configure_alpine_mirror "${mirror_site}" ;;
        arch|manjaro)                   configure_arch_mirror "${mirror_site}" ;;
        opensuse*)                      configure_suse_mirror "${mirror_site}" ;;
        *) log_warning "不支持的系统: ${OS_INFO[id]}, 跳过镜像源配置"; return 0 ;;
    esac
    log_success "镜像源配置完成"
}

configure_rhel_mirror() {
    local mirror_site="$1" version_id="${OS_INFO[version_id]}" major_version="${version_id%%.*}"
    log_info "配置 RHEL/CentOS ${major_version} 镜像源..."
    if [[ ${major_version} -ge 8 ]]; then
        local repo_content="[baseos]
name=BaseOS
baseurl=${mirror_site}/centos/\$releasever-stream/BaseOS/\$basearch/os/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial

[appstream]
name=AppStream
baseurl=${mirror_site}/centos/\$releasever-stream/AppStream/\$basearch/os/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial

[extras]
name=Extras
baseurl=${mirror_site}/centos/\$releasever-stream/extras/\$basearch/os/
gpgcheck=1
enabled=1

[epel]
name=EPEL
baseurl=${mirror_site}/epel/\$releasever/Everything/\$basearch/
gpgcheck=1
enabled=1"
        mkdir -p /etc/yum.repos.d/backup 2>/dev/null
        mv -f /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/ 2>/dev/null || true
        write_config "/etc/yum.repos.d/local.repo" "${repo_content}"
        execute_cmd "清理DNF缓存" dnf clean all
        execute_cmd "重建DNF缓存" dnf makecache
    else
        local repo_content="[base]
name=CentOS-\$releasever - Base
baseurl=${mirror_site}/centos/\$releasever/os/\$basearch/
gpgcheck=1

[updates]
name=CentOS-\$releasever - Updates
baseurl=${mirror_site}/centos/\$releasever/updates/\$basearch/
gpgcheck=1

[extras]
name=CentOS-\$releasever - Extras
baseurl=${mirror_site}/centos/\$releasever/extras/\$basearch/
gpgcheck=1

[epel]
name=EPEL
baseurl=${mirror_site}/epel/\$releasever/\$basearch/
gpgcheck=1"
        mkdir -p /etc/yum.repos.d/backup 2>/dev/null
        mv -f /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/ 2>/dev/null || true
        write_config "/etc/yum.repos.d/local.repo" "${repo_content}"
        execute_cmd "清理YUM缓存" yum clean all
        execute_cmd "重建YUM缓存" yum makecache fast
    fi
}

configure_fedora_mirror() {
    local mirror_site="$1"
    local repo_content="[fedora]
name=Fedora \$releasever
baseurl=${mirror_site}/fedora/releases/\$releasever/Everything/\$basearch/os/
gpgcheck=1
enabled=1

[updates]
name=Fedora Updates
baseurl=${mirror_site}/fedora/updates/\$releasever/Everything/\$basearch/
gpgcheck=1
enabled=1"
    mkdir -p /etc/yum.repos.d/backup 2>/dev/null
    mv -f /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/ 2>/dev/null || true
    write_config "/etc/yum.repos.d/local.repo" "${repo_content}"
    execute_cmd "清理DNF缓存" dnf clean all; execute_cmd "重建DNF缓存" dnf makecache
}

configure_ubuntu_mirror() {
    local mirror_site="$1" codename="$(lsb_release -cs 2>/dev/null || echo 'focal')"
    local repo_content="deb ${mirror_site}/ubuntu/ ${codename} main restricted universe multiverse
deb ${mirror_site}/ubuntu/ ${codename}-security main restricted universe multiverse
deb ${mirror_site}/ubuntu/ ${codename}-updates main restricted universe multiverse
deb ${mirror_site}/ubuntu/ ${codename}-backports main restricted universe multiverse"
    backup_file "/etc/apt/sources.list"
    write_config "/etc/apt/sources.list" "${repo_content}"
    execute_cmd "更新APT缓存" apt-get update -qq
}

configure_debian_mirror() {
    local mirror_site="$1" codename="$(lsb_release -cs 2>/dev/null || echo 'bookworm')"
    local repo_content="deb ${mirror_site}/debian/ ${codename} main contrib non-free non-free-firmware
deb ${mirror_site}/debian/ ${codename}-updates main contrib non-free non-free-firmware
deb ${mirror_site}/debian/ ${codename}-backports main contrib non-free non-free-firmware
deb ${mirror_site}/debian-security/ ${codename}-security main contrib non-free non-free-firmware"
    backup_file "/etc/apt/sources.list"
    write_config "/etc/apt/sources.list" "${repo_content}"
    execute_cmd "更新APT缓存" apt-get update -qq
}

configure_alpine_mirror() {
    local mirror_site="$1" version="${OS_INFO[version_id]}" major_minor="${version%.*}"
    local repo_content="${mirror_site}/alpine/v${major_minor}/main
${mirror_site}/alpine/v${major_minor}/community
${mirror_site}/alpine/v${major_minor}/testing"
    backup_file "/etc/apk/repositories"; write_config "/etc/apk/repositories" "${repo_content}"
    execute_cmd "更新APK缓存" apk update
}

configure_arch_mirror() {
    local mirror_site="$1"
    backup_file "/etc/pacman.d/mirrorlist"
    write_config "/etc/pacman.d/mirrorlist" "Server = ${mirror_site}/archlinux/\$repo/os/\$arch"
    execute_cmd "更新Pacman缓存" pacman -Syy --noconfirm
}

configure_suse_mirror() {
    local mirror_site="$1"
    [[ ${DRY_RUN} -eq 0 ]] && {
        zypper mr -da 2>/dev/null || true
        zypper ar -f "${mirror_site}/opensuse/distribution/leap/\$releasever/repo/oss/" "oss" 2>/dev/null || true
        zypper ar -f "${mirror_site}/opensuse/distribution/leap/\$releasever/repo/non-oss/" "non-oss" 2>/dev/null || true
        zypper ar -f "${mirror_site}/opensuse/update/leap/\$releasever/oss/" "update-oss" 2>/dev/null || true
        zypper refresh 2>/dev/null || true
    }
}

# ============================================================================
# 基础软件包安装
# ============================================================================

install_base_packages() {
    log_step "安装基础软件包..."
    local common_pkgs=(curl wget git vim nano htop atop iotop tree lsof strace tcpdump ncdu nmap rsync zip unzip tar gzip bzip2 xz net-tools jq python3 ca-certificates gnupg2)
    local rhel_pkgs=(epel-release yum-utils bash-completion psmisc procps-ng sysstat)
    local debian_pkgs=(apt-transport-https software-properties-common bash-completion acl procps sysstat dnsutils)
    local alpine_pkgs=(bash bash-completion coreutils util-linux procps shadow)
    case "${OS_INFO[pkg_manager]}" in
        yum)    execute_cmd "安装EPEL" yum install -y epel-release; execute_cmd "更新系统" yum update -y; execute_cmd "安装基础包" yum install -y "${common_pkgs[@]}" "${rhel_pkgs[@]}" ;;
        dnf)    execute_cmd "安装EPEL" dnf install -y epel-release; execute_cmd "更新系统" dnf upgrade --refresh -y; execute_cmd "安装基础包" dnf install -y "${common_pkgs[@]}" "${rhel_pkgs[@]}" ;;
        apt)    execute_cmd "更新系统" bash -c 'apt-get update -qq && apt-get upgrade -y'; execute_cmd "安装基础包" apt-get install -y "${common_pkgs[@]}" "${debian_pkgs[@]}" ;;
        apk)    execute_cmd "更新系统" bash -c 'apk update && apk upgrade'; execute_cmd "安装基础包" apk add --no-cache "${common_pkgs[@]}" "${alpine_pkgs[@]}" ;;
        pacman) execute_cmd "更新系统" pacman -Syu --noconfirm; execute_cmd "安装基础包" pacman -S --noconfirm --needed "${common_pkgs[@]}" bash-completion ;;
        zypper) execute_cmd "更新系统" bash -c 'zypper refresh && zypper update -y'; execute_cmd "安装基础包" zypper install -y "${common_pkgs[@]}" ;;
    esac
    log_success "基础软件包安装完成"
}

# ============================================================================
# 内核参数优化
# ============================================================================

optimize_kernel() {
    log_step "优化内核参数..."
    local sysctl_content="# 系统内核参数优化 - 由 system_init.sh 生成
# 网络
net.core.somaxconn = 65535
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.ip_forward = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
# 文件系统
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
fs.aio-max-nr = 1048576
fs.suid_dumpable = 0
# 内存
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.overcommit_memory = 0
vm.min_free_kbytes = 65536
vm.max_map_count = 262144
vm.vfs_cache_pressure = 50
# 安全
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.log_martians = 1
kernel.randomize_va_space = 2
kernel.pid_max = 4194303
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
"
    backup_file "/etc/sysctl.conf"
    write_config "/etc/sysctl.conf" "${sysctl_content}"
    [[ -d /etc/sysctl.d ]] && write_config "/etc/sysctl.d/99-system-init.conf" "${sysctl_content}"
    [[ ${DRY_RUN} -eq 0 ]] && sysctl -p 2>/dev/null || true

    local limits_content="* soft nofile 655360
* hard nofile 655360
* soft nproc 655360
* hard nproc 655360
root soft nofile 655360
root hard nofile 655360
"
    backup_file "/etc/security/limits.conf"
    write_config "/etc/security/limits.conf" "${limits_content}"
    [[ -d /etc/security/limits.d ]] && write_config "/etc/security/limits.d/99-nofile.conf" "${limits_content}"

    [[ -d /etc/modules-load.d ]] && write_config "/etc/modules-load.d/system-init.conf" "nf_conntrack
br_netfilter
overlay
tcp_bbr
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
"
    [[ ${DRY_RUN} -eq 0 ]] && { for m in nf_conntrack br_netfilter overlay tcp_bbr ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh; do modprobe "${m}" 2>/dev/null || true; done; }
    log_success "内核参数优化完成"
}

# ============================================================================
# 网络配置优化
# ============================================================================

optimize_network() {
    log_step "优化网络配置..."
    local dns_servers="${CONFIG_VALUES[dns_servers]:-223.5.5.5,223.6.6.6,8.8.8.8}"
    local dns_content="# DNS配置 - 由 system_init.sh 生成
nameserver $(echo "${dns_servers}" | cut -d',' -f1)
nameserver $(echo "${dns_servers}" | cut -d',' -f2)
nameserver $(echo "${dns_servers}" | cut -d',' -f3)
options timeout:2 attempts:3 rotate
"
    backup_file "/etc/resolv.conf"
    chattr -i /etc/resolv.conf 2>/dev/null || true
    write_config "/etc/resolv.conf" "${dns_content}"
    chattr +i /etc/resolv.conf 2>/dev/null || true

    if command -v ethtool &>/dev/null; then
        local main_iface="$(ip route show default | awk '{print $5}' | head -1)"
        [[ -n "${main_iface}" ]] && {
            log_info "优化网卡 ${main_iface}..."
            ethtool -K "${main_iface}" tso on gso on gro on 2>/dev/null || true
        }
    fi
    log_success "网络配置优化完成"
}

# ============================================================================
# 用户与权限管理
# ============================================================================

manage_users() {
    log_step "配置用户与权限..."
    local admin_user="${CONFIG_VALUES[admin_user]:-admin}"
    local admin_group="${CONFIG_VALUES[admin_group]:-wheel}"
    [[ "${OS_INFO[family]}" == "debian" ]] && admin_group="sudo"

    if ! id "${admin_user}" &>/dev/null; then
        log_info "创建管理用户: ${admin_user}"
        [[ ${DRY_RUN} -eq 0 ]] && {
            groupadd -f "${admin_group}" 2>/dev/null || true
            useradd -m -s /bin/bash -G "${admin_group}" "${admin_user}" 2>/dev/null || true
            echo "${admin_user}:$(openssl rand -base64 16)" | chpasswd 2>/dev/null || true
            passwd -e "${admin_user}" 2>/dev/null || true
            log_warning "用户 ${admin_user} 已创建, 首次登录需修改密码"
        }
    fi

    local sudoers_content="# Sudoers配置 - 由 system_init.sh 生成
Defaults    env_reset
Defaults    secure_path = /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Defaults    !visiblepw
Defaults    logfile = /var/log/sudo.log
Defaults    log_input, log_output
Defaults    timestamp_timeout = 30

%${admin_group} ALL=(ALL) ALL
${admin_user} ALL=(ALL) NOPASSWD: ALL
"
    backup_file "/etc/sudoers"
    visudo -c &>/dev/null && write_config "/etc/sudoers" "${sudoers_content}" "0440"

    [[ -n "${CONFIG_VALUES[ssh_pub_key]:-}" ]] && [[ ${DRY_RUN} -eq 0 ]] && {
        local ssh_dir="/home/${admin_user}/.ssh"
        mkdir -p "${ssh_dir}"
        echo "${CONFIG_VALUES[ssh_pub_key]}" >> "${ssh_dir}/authorized_keys"
        chmod 700 "${ssh_dir}"; chmod 600 "${ssh_dir}/authorized_keys"
        chown -R "${admin_user}:${admin_user}" "${ssh_dir}"
    }

    log_info "锁定root账户..."
    [[ ${DRY_RUN} -eq 0 ]] && { passwd -l root 2>/dev/null || usermod -L root 2>/dev/null || true; }
    log_success "用户与权限配置完成"
}

# ============================================================================
# SSH安全加固
# ============================================================================

harden_ssh() {
    log_step "加固SSH配置..."
    local ssh_port="${CONFIG_VALUES[ssh_port]:-22}"
    backup_file "/etc/ssh/sshd_config"
    local ssh_content="# SSH配置 - 由 system_init.sh 生成
Port ${ssh_port}
AddressFamily inet
Protocol 2
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key
KexAlgorithms curve25519-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes256-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
PermitRootLogin no
MaxAuthTries 3
MaxSessions 5
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
UsePAM yes
GSSAPIAuthentication no
HostbasedAuthentication no
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTunnel no
PrintMotd no
StrictModes yes
AllowUsers ${CONFIG_VALUES[admin_user]:-admin}
SyslogFacility AUTH
LogLevel VERBOSE
Subsystem sftp /usr/lib/openssh/sftp-server
"
    write_config "/etc/ssh/sshd_config" "${ssh_content}" "0600"
    [[ -d /etc/ssh/sshd_config.d ]] && rm -f /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true
    [[ ${DRY_RUN} -eq 0 ]] && {
        ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" -q 2>/dev/null || true
        ssh-keygen -t rsa -b 4096 -f /etc/ssh/ssh_host_rsa_key -N "" -q 2>/dev/null || true
        rm -f /etc/ssh/ssh_host_dsa_key* /etc/ssh/ssh_host_ecdsa_key* 2>/dev/null || true
    }

    if ! command -v fail2ban-server &>/dev/null; then
        case "${OS_INFO[pkg_manager]}" in
            yum|dnf) execute_cmd "安装fail2ban" "${OS_INFO[pkg_manager]}" install -y fail2ban ;;
            apt)     execute_cmd "安装fail2ban" apt-get install -y fail2ban ;;
            pacman)  execute_cmd "安装fail2ban" pacman -S --noconfirm fail2ban ;;
            zypper)  execute_cmd "安装fail2ban" zypper install -y fail2ban ;;
        esac
    fi
    mkdir -p /etc/fail2ban/jail.d 2>/dev/null
    write_config "/etc/fail2ban/jail.d/sshd.conf" "[sshd]
enabled = true
port = ${ssh_port}
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
"
    [[ ${DRY_RUN} -eq 0 ]] && {
        systemctl enable fail2ban 2>/dev/null || true; systemctl restart fail2ban 2>/dev/null || true
        systemctl enable sshd 2>/dev/null || systemctl enable ssh 2>/dev/null || true
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    }
    log_success "SSH加固完成"
}

# ============================================================================
# 防火墙配置
# ============================================================================

configure_firewall() {
    log_step "配置防火墙..."
    local ssh_port="${CONFIG_VALUES[ssh_port]:-22}" http_port="${CONFIG_VALUES[http_port]:-80}" https_port="${CONFIG_VALUES[https_port]:-443}"
    case "${OS_INFO[firewall]}" in
        firewalld)
            ! command -v firewall-cmd &>/dev/null && execute_cmd "安装firewalld" "${OS_INFO[pkg_manager]}" install -y firewalld
            [[ ${DRY_RUN} -eq 0 ]] && {
                systemctl enable firewalld; systemctl start firewalld
                firewall-cmd --set-default-zone=public
                firewall-cmd --permanent --add-port=${ssh_port}/tcp
                firewall-cmd --permanent --add-port=${http_port}/tcp
                firewall-cmd --permanent --add-port=${https_port}/tcp
                firewall-cmd --permanent --add-service=ssh
                firewall-cmd --permanent --add-service=http
                firewall-cmd --permanent --add-service=https
                firewall-cmd --permanent --remove-service=dhcpv6-client 2>/dev/null || true
                firewall-cmd --reload
                firewall-cmd --list-all
            } ;;
        ufw)
            ! command -v ufw &>/dev/null && execute_cmd "安装UFW" apt-get install -y ufw
            [[ ${DRY_RUN} -eq 0 ]] && {
                ufw default deny incoming; ufw default allow outgoing
                ufw limit ${ssh_port}/tcp; ufw allow ${http_port}/tcp; ufw allow ${https_port}/tcp
                ufw --force enable; ufw status verbose
            } ;;
        iptables)
            [[ ${DRY_RUN} -eq 0 ]] && {
                iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT ACCEPT
                iptables -A INPUT -i lo -j ACCEPT
                iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
                iptables -A INPUT -p tcp --dport ${ssh_port} -j ACCEPT
                iptables -A INPUT -p tcp --dport ${http_port} -j ACCEPT
                iptables -A INPUT -p tcp --dport ${https_port} -j ACCEPT
                iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 1/s -j ACCEPT
                command -v iptables-save &>/dev/null && iptables-save > /etc/iptables.rules
            } ;;
    esac
    log_success "防火墙配置完成"
}

# ============================================================================
# 时间同步
# ============================================================================

configure_time_sync() {
    log_step "配置时间同步..."
    local ntp_servers="${CONFIG_VALUES[ntp_servers]:-ntp.aliyun.com,ntp1.aliyun.com,time1.google.com}"
    local ntp1="$(echo "${ntp_servers}" | cut -d',' -f1)" ntp2="$(echo "${ntp_servers}" | cut -d',' -f2)"
    case "${OS_INFO[family]}" in
        rhel)   execute_cmd "安装chrony" "${OS_INFO[pkg_manager]}" install -y chrony
                write_config "/etc/chrony.conf" "server ${ntp1} iburst
server ${ntp2} iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony"
                [[ ${DRY_RUN} -eq 0 ]] && { systemctl enable chronyd; systemctl restart chronyd; } ;;
        debian) execute_cmd "安装chrony" apt-get install -y chrony
                write_config "/etc/chrony/chrony.conf" "server ${ntp1} iburst
server ${ntp2} iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync"
                [[ ${DRY_RUN} -eq 0 ]] && { systemctl enable chrony; systemctl restart chrony; } ;;
        alpine) execute_cmd "安装chrony" apk add --no-cache chrony
                write_config "/etc/chrony/chrony.conf" "server ${ntp1} iburst
server ${ntp2} iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync"
                [[ ${DRY_RUN} -eq 0 ]] && { rc-update add chronyd default; rc-service chronyd start; } ;;
        arch)   execute_cmd "安装chrony" pacman -S --noconfirm chrony
                write_config "/etc/chrony.conf" "server ${ntp1} iburst
server ${ntp2} iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync"
                [[ ${DRY_RUN} -eq 0 ]] && { systemctl enable chronyd; systemctl restart chronyd; } ;;
        suse)   execute_cmd "安装chrony" zypper install -y chrony
                write_config "/etc/chrony.conf" "server ${ntp1} iburst
server ${ntp2} iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync"
                [[ ${DRY_RUN} -eq 0 ]] && { systemctl enable chronyd; systemctl restart chronyd; } ;;
    esac
    [[ ${DRY_RUN} -eq 0 ]] && { timedatectl set-ntp true 2>/dev/null || true; hwclock --systohc 2>/dev/null || true; }
    log_success "时间同步配置完成"
}

# ============================================================================
# Swap配置
# ============================================================================

configure_swap() {
    log_step "配置Swap..."
    local swap_size="${CONFIG_VALUES[swap_size]:-2G}" swap_file="${CONFIG_VALUES[swap_file]:-/swapfile}" swappiness="${CONFIG_VALUES[swappiness]:-10}"
    local current_swap="$(free -m | awk '/^Swap:/{print $2}')"
    [[ ${current_swap} -gt 0 ]] && { log_info "当前Swap: ${current_swap}MB, 跳过"; return 0; }
    log_info "创建Swap: ${swap_file}, 大小: ${swap_size}"
    [[ ${DRY_RUN} -eq 0 ]] && {
        local swap_mb="$(echo "${swap_size}" | sed 's/G/*1024/;s/M//' | bc 2>/dev/null || echo 2048)"
        [[ -f "${swap_file}" ]] && { swapoff "${swap_file}" 2>/dev/null || true; rm -f "${swap_file}"; }
        dd if=/dev/zero of="${swap_file}" bs=1M count="${swap_mb}" status=progress
        chmod 600 "${swap_file}"; mkswap "${swap_file}"; swapon "${swap_file}"
        grep -q "${swap_file}" /etc/fstab || echo "${swap_file} none swap sw 0 0" >> /etc/fstab
        sysctl vm.swappiness="${swappiness}" 2>/dev/null || true
    }
    log_success "Swap配置完成"
}

# ============================================================================
# 磁盘与文件系统优化
# ============================================================================

configure_disk() {
    log_step "优化磁盘与文件系统..."
    backup_file "/etc/fstab"
    [[ ${DRY_RUN} -eq 0 ]] && {
        sed -i 's/\bdefaults\b/defaults,noatime,nodiratime/g' /etc/fstab 2>/dev/null || true
        for disk in /sys/block/sd*/queue/scheduler /sys/block/vd*/queue/scheduler /sys/block/nvme*/queue/scheduler; do
            [[ -f "${disk}" ]] && {
                local dn="$(echo "${disk}" | cut -d'/' -f4)"
                echo "${dn}" | grep -q "nvme" && echo "none" > "${disk}" 2>/dev/null || echo "deadline" > "${disk}" 2>/dev/null
            }
        done
    }
    write_config "/etc/logrotate.d/system-init" "/var/log/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
    sharedscripts
    postrotate
        /usr/bin/systemctl reload rsyslog > /dev/null 2>&1 || true
    endscript
}
"
    [[ ${DRY_RUN} -eq 0 ]] && {
        case "${OS_INFO[pkg_manager]}" in
            yum)    yum clean all 2>/dev/null || true ;;
            dnf)    dnf clean all 2>/dev/null || true; dnf autoremove -y 2>/dev/null || true ;;
            apt)    apt-get clean 2>/dev/null || true; apt-get autoremove -y 2>/dev/null || true ;;
            apk)    apk cache clean 2>/dev/null || true ;;
            pacman) pacman -Sc --noconfirm 2>/dev/null || true ;;
            zypper) zypper clean 2>/dev/null || true ;;
        esac
        find /var/log -type f -name "*.gz" -mtime +30 -delete 2>/dev/null || true
        find /tmp -type f -mtime +7 -delete 2>/dev/null || true
        journalctl --vacuum-time=7d 2>/dev/null || true
    }
    log_success "磁盘与文件系统优化完成"
}

# ============================================================================
# 系统安全加固
# ============================================================================

harden_security() {
    log_step "系统安全加固..."
    backup_file "/etc/login.defs"
    write_config "/etc/login.defs" "PASS_MAX_DAYS   90
PASS_MIN_DAYS   1
PASS_WARN_AGE   14
PASS_MIN_LEN    12
LOGIN_RETRIES   3
LOGIN_TIMEOUT   60
UMASK           027
ENCRYPT_METHOD  SHA512
"
    case "${OS_INFO[family]}" in
        rhel) [[ -f /etc/security/pwquality.conf ]] && {
                backup_file "/etc/security/pwquality.conf"
                write_config "/etc/security/pwquality.conf" "minlen = 12
minclass = 3
dcredit = -1
ucredit = -1
lcredit = -1
ocredit = -1
maxrepeat = 3
difok = 5
enforcing = 1
"; } ;;
        debian) [[ -f /etc/pam.d/common-password ]] && {
                backup_file "/etc/pam.d/common-password"
                grep -q "pam_pwquality" /etc/pam.d/common-password 2>/dev/null || \
                    sed -i '/pam_unix.so/i password requisite pam_pwquality.so retry=3 minlen=12 difok=5 minclass=3' /etc/pam.d/common-password 2>/dev/null || true; } ;;
    esac

    local unnecessary_services=(avahi-daemon cups bluetooth ModemManager rpcbind postfix)
    [[ ${DRY_RUN} -eq 0 ]] && for svc in "${unnecessary_services[@]}"; do
        case "${OS_INFO[service_manager]}" in
            systemd) systemctl stop "${svc}" 2>/dev/null || true; systemctl disable "${svc}" 2>/dev/null || true; systemctl mask "${svc}" 2>/dev/null || true ;;
            openrc)  rc-service "${svc}" stop 2>/dev/null || true; rc-update del "${svc}" default 2>/dev/null || true ;;
        esac
    done

    [[ ${DRY_RUN} -eq 0 ]] && {
        chmod 700 /root 2>/dev/null || true
        chmod 600 /etc/shadow 2>/dev/null || true
        chmod 644 /etc/passwd 2>/dev/null || true
        sysctl -w kernel.randomize_va_space=2 2>/dev/null || true
    }

    command -v auditctl &>/dev/null && [[ -d /etc/audit/rules.d ]] && {
        write_config "/etc/audit/rules.d/system-init.rules" "-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/sudoers -p wa -k sudoers
-w /etc/crontab -p wa -k cron
-a always,exit -F arch=b64 -S chmod,chown -F auid>=1000 -F auid!=4294967295 -k perm_mod
"
        [[ ${DRY_RUN} -eq 0 ]] && { systemctl enable auditd 2>/dev/null || true; systemctl restart auditd 2>/dev/null || true; }
    }

    [[ ${DRY_RUN} -eq 0 ]] && {
        local known_suids="/usr/bin/sudo /usr/bin/passwd /usr/bin/su /usr/bin/mount /usr/bin/umount /usr/bin/pkexec"
        local found_suids="$(find / -perm -4000 -type f 2>/dev/null)"
        for suid in ${found_suids}; do
            echo "${known_suids}" | grep -q "${suid}" || log_warning "发现未知SUID文件: ${suid}"
        done
    }
    log_success "系统安全加固完成"
}

# ============================================================================
# Docker安装
# ============================================================================

install_docker() {
    log_step "安装Docker环境..."
    command -v docker &>/dev/null && { log_info "Docker已安装: $(docker --version)"; return 0; }
    local docker_mirror="${CONFIG_VALUES[docker_mirror]:-https://mirrors.aliyun.com/docker-ce}"
    case "${OS_INFO[family]}" in
        rhel)   execute_cmd "安装Docker依赖" "${OS_INFO[pkg_manager]}" install -y yum-utils device-mapper-persistent-data lvm2
                [[ ${DRY_RUN} -eq 0 ]] && "${OS_INFO[pkg_manager]}" config-manager --add-repo "${docker_mirror}/linux/centos/docker-ce.repo" 2>/dev/null || true
                execute_cmd "安装Docker" "${OS_INFO[pkg_manager]}" install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin ;;
        debian) [[ ${DRY_RUN} -eq 0 ]] && {
                    apt-get update -qq; apt-get install -y ca-certificates curl gnupg lsb-release
                    mkdir -p /etc/apt/keyrings
                    curl -fsSL "${docker_mirror}/linux/${OS_INFO[id]}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || true
                    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] ${docker_mirror}/linux/${OS_INFO[id]} $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
                    apt-get update -qq
                }
                execute_cmd "安装Docker" apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin ;;
        alpine) execute_cmd "安装Docker" apk add --no-cache docker docker-compose
                [[ ${DRY_RUN} -eq 0 ]] && { rc-update add docker default; rc-service docker start; } ;;
        arch)   execute_cmd "安装Docker" pacman -S --noconfirm docker docker-compose ;;
        suse)   execute_cmd "安装Docker" zypper install -y docker docker-compose ;;
    esac
    [[ ${DRY_RUN} -eq 0 ]] && {
        case "${OS_INFO[service_manager]}" in
            systemd) systemctl enable docker; systemctl start docker ;;
            openrc)  rc-update add docker default; rc-service docker start ;;
        esac
    }
    mkdir -p /etc/docker 2>/dev/null
    write_config "/etc/docker/daemon.json" "{
    \"registry-mirrors\": [\"${CONFIG_VALUES[docker_registry_mirror]:-https://mirror.ccs.tencentyun.com}\"],
    \"exec-opts\": [\"native.cgroupdriver=systemd\"],
    \"log-driver\": \"json-file\",
    \"log-opts\": {\"max-size\": \"100m\", \"max-file\": \"3\"},
    \"storage-driver\": \"overlay2\",
    \"live-restore\": true,
    \"userland-proxy\": false,
    \"bip\": \"172.17.0.1/16\"
}
"
    [[ ${DRY_RUN} -eq 0 ]] && systemctl restart docker 2>/dev/null || true
    log_success "Docker环境安装完成"
}

# ============================================================================
# 开发工具安装
# ============================================================================

install_devtools() {
    log_step "安装开发工具..."
    case "${OS_INFO[pkg_manager]}" in
        yum)    execute_cmd "安装开发工具" yum groupinstall -y "Development Tools"; execute_cmd "安装开发库" yum install -y openssl-devel zlib-devel bzip2-devel readline-devel sqlite-devel ;;
        dnf)    execute_cmd "安装开发工具" dnf groupinstall -y "Development Tools"; execute_cmd "安装开发库" dnf install -y openssl-devel zlib-devel bzip2-devel readline-devel sqlite-devel ;;
        apt)    execute_cmd "安装开发工具" apt-get install -y build-essential; execute_cmd "安装开发库" apt-get install -y libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev ;;
        apk)    execute_cmd "安装开发工具" apk add --no-cache build-base; execute_cmd "安装开发库" apk add --no-cache openssl-dev zlib-dev bzip2-dev readline-dev sqlite-dev ;;
        pacman) execute_cmd "安装开发工具" pacman -S --noconfirm base-devel; execute_cmd "安装开发库" pacman -S --noconfirm openssl zlib bzip2 readline sqlite ;;
        zypper) execute_cmd "安装开发工具" zypper install -y -t pattern devel_C_C++; execute_cmd "安装开发库" zypper install -y libopenssl-devel zlib-devel libbz2-devel readline-devel sqlite3-devel ;;
    esac
    ! command -v go &>/dev/null && [[ ${DRY_RUN} -eq 0 ]] && {
        local go_arch="${OS_INFO[arch]}"; [[ "${go_arch}" == "x86_64" ]] && go_arch="amd64"; [[ "${go_arch}" == "aarch64" ]] && go_arch="arm64"
        curl -fsSL "https://go.dev/dl/go1.22.0.linux-${go_arch}.tar.gz" -o /tmp/go.tar.gz
        rm -rf /usr/local/go; tar -C /usr/local -xzf /tmp/go.tar.gz; rm -f /tmp/go.tar.gz
        grep -q '/usr/local/go/bin' /etc/profile || echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
        log_info "Go 安装完成"
    }
    log_success "开发工具安装完成"
}

# ============================================================================
# 系统报告
# ============================================================================

generate_report() {
    log_step "生成系统报告..."
    local report_file="${LOG_DIR}/system_report_${TIMESTAMP}.txt"
    mkdir -p "${LOG_DIR}" 2>/dev/null || true
    cat > "${report_file}" << REPORT
================================================================
  系统初始化报告 - ${TIMESTAMP}
================================================================
[操作系统] ${OS_INFO[pretty_name]}
[内核版本] ${OS_INFO[kernel]}
[CPU] ${OS_INFO[cpu_model]} (${OS_INFO[cpu_cores]}核)
[内存] ${OS_INFO[mem_total]}GB
[磁盘] ${OS_INFO[disk_total]}
[虚拟化] ${OS_INFO[virtual]}
[容器] $([[ ${OS_INFO[is_container]} -eq 1 ]] && echo "是" || echo "否")
[网络]
$(ip addr show | grep 'inet ' | awk '{print "  "$NF": "$2}')
$(ip route show default | awk '{print "  默认网关: "$3}')
[磁盘使用]
$(df -h | awk 'NR>1{print "  "$1" "$6" 总"$2" 已用"$3" 可用"$4" "$5}')
[监听端口]
$(ss -tlnp 2>/dev/null | awk 'NR>1{print "  "$4" "$6}' | head -20)
[Docker] $(command -v docker &>/dev/null && docker --version || echo "未安装")
[SSH端口] $(grep -E '^Port' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
[Root登录] $(grep -E '^PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "yes")
================================================================
REPORT
    echo "${TIMESTAMP}" > "${LOG_DIR}/last_init_time"
    log_success "系统报告已生成: ${report_file}"
}

# ============================================================================
# 回滚
# ============================================================================

do_rollback() {
    log_step "回滚上次初始化..."
    local last_backup="$(ls -dt "${BACKUP_DIR}"/20* 2>/dev/null | head -1)"
    [[ -z "${last_backup}" ]] && { log_error "没有找到可回滚的备份"; return 1; }
    log_info "回滚到备份: ${last_backup}"
    confirm_action "确认回滚?" || { log_info "回滚已取消"; return 0; }
    [[ ${DRY_RUN} -eq 0 ]] && for f in "${last_backup}"/*; do
        local orig="/$(echo "$(basename "${f}")" | tr '_' '/')"
        log_info "恢复: ${f} -> ${orig}"
        cp -a "${f}" "${orig}" 2>/dev/null || true
    done
    log_success "回滚完成"
}

parse_config_file() {
    local config="$1"
    [[ ! -f "${config}" ]] && { log_error "配置文件不存在: ${config}"; return 1; }
    while IFS='=' read -r key value; do
        key="$(echo "${key}" | xargs)"; value="$(echo "${value}" | xargs)"
        [[ -n "${key}" ]] && [[ ! "${key}" =~ ^# ]] && CONFIG_VALUES["${key}"]="${value}"
    done < "${config}"
}

show_usage() {
    cat << USAGE
系统初始化自动化脚本 v${SCRIPT_VERSION}

用法: bash system_init.sh [选项]

模块选项:
  --all          执行全部初始化模块
  --mirror       仅配置镜像源
  --packages     仅安装基础包
  --kernel       仅优化内核参数
  --network      仅优化网络
  --users        仅配置用户与权限
  --ssh          仅加固SSH
  --firewall     仅配置防火墙
  --time-sync    仅配置时间同步
  --swap         仅配置Swap
  --disk         仅优化磁盘
  --security     仅安全加固
  --docker       仅安装Docker
  --devtools     仅安装开发工具
  --report       仅生成系统报告
  --audit        仅执行安全审计
  --hardening    仅执行CIS加固
  --monitoring   仅安装监控代理
  --logrotate    仅配置日志轮转
  --selinux      仅配置SELinux/AppArmor
  --limits       仅配置系统资源限制
  --sysctl-check 仅检查sysctl配置
  --network-check 仅检查网络配置
  --firewall-check 仅检查防火墙状态

控制选项:
  --dry-run          模拟运行, 不实际执行
  --non-interactive  非交互模式, 自动确认
  --verbose          详细输出模式
  --config FILE      使用配置文件
  --rollback         回滚上次初始化
  --help             显示帮助信息
  --version          显示版本信息

配置文件格式 (system_init.cfg):
  mirror_site=https://mirrors.aliyun.com
  ssh_port=22
  admin_user=admin
  dns_servers=223.5.5.5,223.6.6.6,8.8.8.8
  ntp_servers=ntp.aliyun.com,ntp1.aliyun.com
  swap_size=2G
  swap_file=/swapfile
  docker_mirror=https://mirrors.aliyun.com/docker-ce
  docker_registry_mirror=https://mirror.ccs.tencentyun.com
  timezone=Asia/Shanghai
  locale=en_US.UTF-8

支持的操作系统:
  - CentOS/RHEL 7/8/9, Rocky Linux, AlmaLinux, Fedora
  - Ubuntu 18.04/20.04/22.04/24.04, Debian 10/11/12
  - Alpine Linux, Arch Linux / Manjaro, openSUSE
USAGE
}

# ============================================================================
# 安全审计模块
# ============================================================================

run_security_audit() {
    log_step "执行系统安全审计..."
    local audit_file="${LOG_DIR}/security_audit_${TIMESTAMP}.txt"
    local score=0 total=0

    echo "================================================================" > "${audit_file}"
    echo "  系统安全审计报告 - ${TIMESTAMP}" >> "${audit_file}"
    echo "================================================================" >> "${audit_file}"

    echo -e "\n[1] 账户安全检查" >> "${audit_file}"
    ((total++)) || true
    local empty_pass="$(awk -F: '($2 == "" || $2 == "!") {print $1}' /etc/shadow 2>/dev/null)"
    if [[ -z "${empty_pass}" ]]; then
        echo "  [PASS] 无空密码账户" >> "${audit_file}"; ((score++)) || true
    else
        echo "  [FAIL] 发现空密码账户: ${empty_pass}" >> "${audit_file}"
        log_warning "发现空密码账户: ${empty_pass}"
    fi

    ((total++)) || true
    local uid0_users="$(awk -F: '($3 == 0) {print $1}' /etc/passwd 2>/dev/null)"
    if [[ "$(echo "${uid0_users}" | wc -l)" -le 1 ]]; then
        echo "  [PASS] UID=0账户数正常: ${uid0_users}" >> "${audit_file}"; ((score++)) || true
    else
        echo "  [FAIL] 多个UID=0账户: ${uid0_users}" >> "${audit_file}"
        log_warning "多个UID=0账户: ${uid0_users}"
    fi

    ((total++)) || true
    if [[ -f /etc/login.defs ]] && grep -q "PASS_MAX_DAYS.*90" /etc/login.defs 2>/dev/null; then
        echo "  [PASS] 密码最大有效期已设置为90天" >> "${audit_file}"; ((score++)) || true
    else
        echo "  [FAIL] 密码最大有效期未设置或超过90天" >> "${audit_file}"
    fi

    ((total++)) || true
    if [[ -f /etc/login.defs ]] && grep -q "PASS_MIN_LEN.*1[0-9]" /etc/login.defs 2>/dev/null; then
        echo "  [PASS] 密码最小长度已设置为12位以上" >> "${audit_file}"; ((score++)) || true
    else
        echo "  [FAIL] 密码最小长度不足12位" >> "${audit_file}"
    fi

    ((total++)) || true
    local expired_users="$(awk -F: '{if($2 !~ /^[!*]/ && $2 != "") system("chage -l "$1" 2>/dev/null | grep -q \"password must be changed\" && echo "$1")}' /etc/passwd 2>/dev/null)"
    if [[ -z "${expired_users}" ]]; then
        echo "  [PASS] 无密码过期账户" >> "${audit_file}"; ((score++)) || true
    else
        echo "  [WARN] 密码已过期账户: ${expired_users}" >> "${audit_file}"
    fi

    echo -e "\n[2] SSH安全检查" >> "${audit_file}"
    ((total++)) || true
    if grep -q "^PermitRootLogin no" /etc/ssh/sshd_config 2>/dev/null; then
        echo "  [PASS] 禁止Root SSH登录" >> "${audit_file}"; ((score++)) || true
    else
        echo "  [FAIL] 允许Root SSH登录" >> "${audit_file}"
    fi

    ((total++)) || true
    if grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config 2>/dev/null; then
        echo "  [PASS] 禁止密码认证" >> "${audit_file}"; ((score++)) || true
    else
        echo "  [FAIL] 允许密码认证" >> "${audit_file}"
    fi

    ((total++)) || true
    if grep -q "^Protocol 2" /etc/ssh/sshd_config 2>/dev/null || ! grep -q "^Protocol 1" /etc/ssh/sshd_config 2>/dev/null; then
        echo "  [PASS] SSH协议版本正确" >> "${audit_file}"; ((score++)) || true
    else
        echo "  [FAIL] SSH使用不安全协议版本" >> "${audit_file}"
    fi

    ((total++)) || true
    local ssh_port="$(grep -E '^Port' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')"
    if [[ -n "${ssh_port}" ]] && [[ "${ssh_port}" != "22" ]]; then
        echo "  [PASS] SSH端口已修改: ${ssh_port}" >> "${audit_file}"; ((score++)) || true
    else
        echo "  [WARN] SSH使用默认端口22" >> "${audit_file}"
    fi

    ((total++)) || true
    if grep -q "^MaxAuthTries" /etc/ssh/sshd_config 2>/dev/null; then
        local max_tries="$(grep '^MaxAuthTries' /etc/ssh/sshd_config | awk '{print $2}')"
        if [[ ${max_tries} -le 5 ]]; then
            echo "  [PASS] SSH最大认证尝试次数: ${max_tries}" >> "${audit_file}"; ((score++)) || true
        else
            echo "  [FAIL] SSH最大认证尝试次数过多: ${max_tries}" >> "${audit_file}"
        fi
    else
        echo "  [WARN] 未设置SSH最大认证尝试次数" >> "${audit_file}"
    fi

    echo -e "\n[3] 文件权限检查" >> "${audit_file}"
    local perm_checks=(
        "/etc/passwd:644"
        "/etc/shadow:600"
        "/etc/group:644"
        "/etc/gshadow:600"
        "/etc/ssh/sshd_config:600"
        "/etc/crontab:600"
        "/etc/sudoers:440"
    )
    for check in "${perm_checks[@]}"; do
        local file="${check%%:*}" expected="${check##*:}"
        ((total++)) || true
        if [[ -f "${file}" ]]; then
            local actual="$(stat -c %a "${file}" 2>/dev/null || stat -f %Lp "${file}" 2>/dev/null)"
            if [[ "${actual}" -le "${expected}" ]]; then
                echo "  [PASS] ${file} 权限: ${actual} (要求<=${expected})" >> "${audit_file}"; ((score++)) || true
            else
                echo "  [FAIL] ${file} 权限: ${actual} (要求<=${expected})" >> "${audit_file}"
            fi
        fi
    done

    echo -e "\n[4] 内核安全参数检查" >> "${audit_file}"
    local sysctl_checks=(
        "kernel.randomize_va_space:2"
        "kernel.kptr_restrict:2"
        "kernel.dmesg_restrict:1"
        "net.ipv4.conf.all.rp_filter:1"
        "net.ipv4.conf.all.accept_source_route:0"
        "net.ipv4.conf.all.accept_redirects:0"
        "net.ipv4.icmp_echo_ignore_broadcasts:1"
        "net.ipv4.tcp_syncookies:1"
    )
    for check in "${sysctl_checks[@]}"; do
        local key="${check%%:*}" expected="${check##*:}"
        ((total++)) || true
        local actual="$(sysctl -n "${key}" 2>/dev/null || echo 'N/A')"
        if [[ "${actual}" == "${expected}" ]]; then
            echo "  [PASS] ${key} = ${actual}" >> "${audit_file}"; ((score++)) || true
        else
            echo "  [FAIL] ${key} = ${actual} (期望: ${expected})" >> "${audit_file}"
        fi
    done

    echo -e "\n[5] 服务安全检查" >> "${audit_file}"
    local unsafe_services=(telnet rsh rlogin vsftpd tftp xinetd inetd)
    for svc in "${unsafe_services[@]}"; do
        ((total++)) || true
        if ! systemctl is-active "${svc}" &>/dev/null 2>&1; then
            echo "  [PASS] 不安全服务 ${svc} 未运行" >> "${audit_file}"; ((score++)) || true
        else
            echo "  [FAIL] 不安全服务 ${svc} 正在运行" >> "${audit_file}"
        fi
    done

    echo -e "\n[6] SUID/SGID文件检查" >> "${audit_file}"
    local known_suids="/usr/bin/sudo /usr/bin/passwd /usr/bin/su /usr/bin/mount /usr/bin/umount /usr/bin/pkexec /usr/bin/chsh /usr/bin/chfn /usr/bin/gpasswd /usr/bin/newgrp /usr/bin/at /usr/lib/openssh/ssh-keysign /usr/lib/dbus-1.0/dbus-daemon-launch-helper"
    local suid_files="$(find /usr -perm -4000 -type f 2>/dev/null)"
    for suid in ${suid_files}; do
        ((total++)) || true
        if echo "${known_suids}" | grep -q "${suid}"; then
            echo "  [PASS] 已知SUID: ${suid}" >> "${audit_file}"; ((score++)) || true
        else
            echo "  [WARN] 未知SUID: ${suid}" >> "${audit_file}"
        fi
    done

    echo -e "\n[7] 防火墙检查" >> "${audit_file}"
    ((total++)) || true
    case "${OS_INFO[firewall]}" in
        firewalld)
            if systemctl is-active firewalld &>/dev/null; then
                echo "  [PASS] firewalld 已启用" >> "${audit_file}"; ((score++)) || true
            else
                echo "  [FAIL] firewalld 未启用" >> "${audit_file}"
            fi
            ;;
        ufw)
            if ufw status 2>/dev/null | grep -q "active"; then
                echo "  [PASS] UFW 已启用" >> "${audit_file}"; ((score++)) || true
            else
                echo "  [FAIL] UFW 未启用" >> "${audit_file}"
            fi
            ;;
        iptables)
            if iptables -L INPUT 2>/dev/null | grep -q "DROP\|REJECT"; then
                echo "  [PASS] iptables 已配置" >> "${audit_file}"; ((score++)) || true
            else
                echo "  [FAIL] iptables 未配置" >> "${audit_file}"
            fi
            ;;
    esac

    echo -e "\n[8] 日志与审计检查" >> "${audit_file}"
    ((total++)) || true
    if systemctl is-active rsyslog &>/dev/null || systemctl is-active syslog &>/dev/null; then
        echo "  [PASS] 系统日志服务运行中" >> "${audit_file}"; ((score++)) || true
    else
        echo "  [FAIL] 系统日志服务未运行" >> "${audit_file}"
    fi

    ((total++)) || true
    if command -v auditctl &>/dev/null && systemctl is-active auditd &>/dev/null; then
        echo "  [PASS] 审计服务运行中" >> "${audit_file}"; ((score++)) || true
    else
        echo "  [WARN] 审计服务未运行" >> "${audit_file}"
    fi

    echo -e "\n[9] 磁盘与分区检查" >> "${audit_file}"
    df -h | awk 'NR>1 {
        usage = $5; gsub(/%/, "", usage)
        if (usage + 0 > 85) print "  [FAIL] 分区 "$6" 使用率 "usage"%"
        else print "  [PASS] 分区 "$6" 使用率 "usage"%"
    }' >> "${audit_file}" 2>/dev/null

    echo -e "\n[10] 网络安全检查" >> "${audit_file}"
    ((total++)) || true
    local listening_ports="$(ss -tlnp 2>/dev/null | awk 'NR>1{print $4}' | rev | cut -d: -f1 | rev | sort -n | uniq)"
    echo "  监听端口:" >> "${audit_file}"
    for port in ${listening_ports}; do
        echo "    - ${port}" >> "${audit_file}"
    done
    echo "  [INFO] 共 $(echo "${listening_ports}" | wc -l) 个监听端口" >> "${audit_file}"

    echo -e "\n================================================================" >> "${audit_file}"
    local pct=$((score * 100 / total))
    echo "  审计评分: ${score}/${total} (${pct}%)" >> "${audit_file}"
    if [[ ${pct} -ge 90 ]]; then
        echo "  安全等级: 优秀" >> "${audit_file}"
    elif [[ ${pct} -ge 75 ]]; then
        echo "  安全等级: 良好" >> "${audit_file}"
    elif [[ ${pct} -ge 60 ]]; then
        echo "  安全等级: 一般" >> "${audit_file}"
    else
        echo "  安全等级: 危险" >> "${audit_file}"
    fi
    echo "================================================================" >> "${audit_file}"

    cat "${audit_file}"
    log_success "安全审计完成, 评分: ${score}/${total} (${pct}%)"
}

# ============================================================================
# CIS基准加固模块
# ============================================================================

apply_cis_hardening() {
    log_step "应用CIS安全基准加固..."

    log_info "[CIS 1.1] 文件系统加固..."
    local tmp_mounts=("tmp" "var/tmp" "dev/shm")
    for m in "${tmp_mounts[@]}"; do
        if ! mountpoint -q "/${m}" 2>/dev/null; then
            log_info "配置 /${m} 挂载选项..."
            [[ ${DRY_RUN} -eq 0 ]] && {
                grep -q "/${m}" /etc/fstab || echo "tmpfs /${m} tmpfs defaults,nodev,nosuid,noexec 0 0" >> /etc/fstab
                mount -o remount,nodev,nosuid,noexec "/${m}" 2>/dev/null || true
            }
        else
            [[ ${DRY_RUN} -eq 0 ]] && mount -o remount,nodev,nosuid,noexec "/${m}" 2>/dev/null || true
        fi
    done

    log_info "[CIS 1.2] 配置软件源GPG检查..."
    case "${OS_INFO[pkg_manager]}" in
        yum)
            backup_file "/etc/yum.conf"
            sed -i 's/^gpgcheck=.*/gpgcheck=1/' /etc/yum.conf 2>/dev/null || true
            ;;
        dnf)
            backup_file "/etc/dnf/dnf.conf"
            sed -i 's/^gpgcheck=.*/gpgcheck=1/' /etc/dnf/dnf.conf 2>/dev/null || true
            ;;
        apt)
            backup_file "/etc/apt/apt.conf.d/99security"
            write_config "/etc/apt/apt.conf.d/99security" 'Acquire::AllowUnauthenticated "false";
APT::Get::AllowUnauthenticated "false";'
            ;;
    esac

    log_info "[CIS 2.1] 禁用不必要的服务..."
    local disable_services=(
        "avahi-daemon" "cups" "dhcpd" "slapd" "nfs" "rpcbind"
        "bind9" "vsftpd" "apache2" "httpd" "dovecot" "smbd"
        "squid" "snmpd" "rysnc" "talk" "telnet" "tftp"
        "xinetd" "daytime" "time" "echo" "discard" "chargen"
        "bluetooth" "ModemManager" "postfix"
    )
    [[ ${DRY_RUN} -eq 0 ]] && for svc in "${disable_services[@]}"; do
        case "${OS_INFO[service_manager]}" in
            systemd)
                systemctl stop "${svc}" 2>/dev/null || true
                systemctl disable "${svc}" 2>/dev/null || true
                systemctl mask "${svc}" 2>/dev/null || true
                ;;
            openrc)
                rc-service "${svc}" stop 2>/dev/null || true
                rc-update del "${svc}" default 2>/dev/null || true
                ;;
        esac
    done

    log_info "[CIS 3.1] 网络参数加固..."
    [[ ${DRY_RUN} -eq 0 ]] && {
        sysctl -w net.ipv4.conf.all.send_redirects=0 2>/dev/null || true
        sysctl -w net.ipv4.conf.default.send_redirects=0 2>/dev/null || true
        sysctl -w net.ipv4.conf.all.accept_source_route=0 2>/dev/null || true
        sysctl -w net.ipv4.conf.default.accept_source_route=0 2>/dev/null || true
        sysctl -w net.ipv6.conf.all.accept_ra=0 2>/dev/null || true
        sysctl -w net.ipv6.conf.default.accept_ra=0 2>/dev/null || true
        sysctl -w net.ipv4.conf.all.log_martians=1 2>/dev/null || true
        sysctl -w net.ipv4.conf.default.log_martians=1 2>/dev/null || true
    }

    log_info "[CIS 4.1] 配置审计系统..."
    [[ ${DRY_RUN} -eq 0 ]] && {
        case "${OS_INFO[pkg_manager]}" in
            yum|dnf) "${OS_INFO[pkg_manager]}" install -y audit auditd 2>/dev/null || true ;;
            apt)     apt-get install -y auditd 2>/dev/null || true ;;
            pacman)  pacman -S --noconfirm audit 2>/dev/null || true ;;
            zypper)  zypper install -y audit 2>/dev/null || true ;;
        esac

        if [[ -d /etc/audit/rules.d ]]; then
            write_config "/etc/audit/rules.d/cis.rules" "-D
-b 8192
-f 1
--backlog_wait_time 60000
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers
-w /etc/crontab -p wa -k cron
-w /etc/cron.allow -p wa -k cron
-w /etc/cron.deny -p wa -k cron
-w /etc/cron.d/ -p wa -k cron
-w /etc/cron.daily/ -p wa -k cron
-w /etc/cron.weekly/ -p wa -k cron
-w /etc/cron.monthly/ -p wa -k cron
-w /etc/hosts -p wa -k network
-w /etc/hostname -p wa -k network
-w /etc/resolv.conf -p wa -k network
-w /etc/sysctl.conf -p wa -k sysctl
-w /etc/sysctl.d/ -p wa -k sysctl
-w /etc/login.defs -p wa -k auth
-w /etc/pam.d/ -p wa -k auth
-w /etc/security/ -p wa -k auth
-w /var/log/faillog -p wa -k logins
-w /var/log/lastlog -p wa -k logins
-w /var/log/tallylog -p wa -k logins
-a always,exit -F arch=b64 -S chmod,chown,fchmod,fchown,lchown -F auid>=1000 -F auid!=4294967295 -k perm_mod
-a always,exit -F arch=b64 -S creat,open,openat,truncate,ftruncate -F auid>=1000 -F auid!=4294967295 -k file_access
-a always,exit -F arch=b64 -S mount -F auid>=1000 -F auid!=4294967295 -k mounts
-a always,exit -F arch=b64 -S unlink,rename,unlinkat,renameat -F auid>=1000 -F auid!=4294967295 -k file_delete
-a always,exit -F arch=b64 -S setuid,setgid -F auid>=1000 -F auid!=4294967295 -k priv_esc
-a always,exit -F arch=b64 -S execve -F auid>=1000 -F auid!=4294967295 -k exec
-a always,exit -F arch=b64 -S init_module,delete_module -k modules
"
            systemctl enable auditd 2>/dev/null || true
            systemctl restart auditd 2>/dev/null || true
        fi
    }

    log_info "[CIS 5.1] 配置日志轮转..."
    write_config "/etc/logrotate.d/cis-hardening" "/var/log/auth.log {
    weekly
    rotate 13
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
}
/var/log/syslog {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
    postrotate
        /usr/bin/systemctl reload rsyslog > /dev/null 2>&1 || true
    endscript
}
/var/log/kern.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
}
/var/log/daemon.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
}"

    log_info "[CIS 5.2] 配置日志服务器..."
    if [[ -f /etc/rsyslog.conf ]]; then
        backup_file "/etc/rsyslog.conf"
        grep -q "MaxMessageSize" /etc/rsyslog.conf || echo '$MaxMessageSize 64k' >> /etc/rsyslog.conf
        [[ ${DRY_RUN} -eq 0 ]] && systemctl restart rsyslog 2>/dev/null || true
    fi

    log_info "[CIS 6.1] 配置crontab权限..."
    [[ ${DRY_RUN} -eq 0 ]] && {
        touch /etc/cron.allow 2>/dev/null; chmod 600 /etc/cron.allow 2>/dev/null || true
        touch /etc/at.allow 2>/dev/null; chmod 600 /etc/at.allow 2>/dev/null || true
        rm -f /etc/cron.deny /etc/at.deny 2>/dev/null || true
    }

    log_info "[CIS 6.2] 配置SSH安全..."
    if [[ -f /etc/ssh/sshd_config ]]; then
        [[ ${DRY_RUN} -eq 0 ]] && {
            sed -i 's/^#*LoginGraceTime.*/LoginGraceTime 60/' /etc/ssh/sshd_config 2>/dev/null || true
            sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config 2>/dev/null || true
            sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 4/' /etc/ssh/sshd_config 2>/dev/null || true
            sed -i 's/^#*MaxSessions.*/MaxSessions 4/' /etc/ssh/sshd_config 2>/dev/null || true
            sed -i 's/^#*ClientAliveInterval.*/ClientAliveInterval 300/' /etc/ssh/sshd_config 2>/dev/null || true
            sed -i 's/^#*ClientAliveCountMax.*/ClientAliveCountMax 0/' /etc/ssh/sshd_config 2>/dev/null || true
            sed -i 's/^#*PermitEmptyPasswords.*/PermitEmptyPasswords no/' /etc/ssh/sshd_config 2>/dev/null || true
            sed -i 's/^#*HostbasedAuthentication.*/HostbasedAuthentication no/' /etc/ssh/sshd_config 2>/dev/null || true
            sed -i 's/^#*X11Forwarding.*/X11Forwarding no/' /etc/ssh/sshd_config 2>/dev/null || true
            sed -i 's/^#*AllowTcpForwarding.*/AllowTcpForwarding no/' /etc/ssh/sshd_config 2>/dev/null || true
            systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
        }
    fi

    log_success "CIS安全基准加固完成"
}

# ============================================================================
# 监控代理安装模块
# ============================================================================

install_monitoring() {
    log_step "安装监控代理..."
    local monitor_type="${CONFIG_VALUES[monitor_type]:-node_exporter}"

    case "${monitor_type}" in
        node_exporter)
            install_node_exporter
            ;;
        zabbix)
            install_zabbix_agent
            ;;
        prometheus)
            install_node_exporter
            ;;
        *)
            log_info "默认安装 node_exporter"
            install_node_exporter
            ;;
    esac
    log_success "监控代理安装完成"
}

install_node_exporter() {
    log_info "安装 Prometheus Node Exporter..."
    local version="${CONFIG_VALUES[node_exporter_version]:-1.7.0}"
    local arch="${OS_INFO[arch]}"
    [[ "${arch}" == "x86_64" ]] && arch="amd64"
    [[ "${arch}" == "aarch64" ]] && arch="arm64"

    command -v node_exporter &>/dev/null && { log_info "node_exporter 已安装"; return 0; }

    [[ ${DRY_RUN} -eq 0 ]] && {
        local download_url="https://github.com/prometheus/node_exporter/releases/download/v${version}/node_exporter-${version}.linux-${arch}.tar.gz"
        curl -fsSL "${download_url}" -o /tmp/node_exporter.tar.gz || { log_error "下载失败"; return 1; }
        tar -xzf /tmp/node_exporter.tar.gz -C /tmp/
        cp "/tmp/node_exporter-${version}.linux-${arch}/node_exporter" /usr/local/bin/
        chmod +x /usr/local/bin/node_exporter
        rm -rf /tmp/node_exporter*

        id node_exporter &>/dev/null || useradd -r -s /sbin/nologin node_exporter 2>/dev/null || true

        write_config "/etc/systemd/system/node_exporter.service" "[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
Type=simple
User=node_exporter
Group=node_exporter
ExecStart=/usr/local/bin/node_exporter \\
    --web.listen-address=:9100 \\
    --collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|run)($$|/) \\
    --collector.filesystem.fs-types-exclude=^(sys|proc|auto|devtmpfs|tmpfs|overlay)$$
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
"
        systemctl daemon-reload
        systemctl enable node_exporter
        systemctl start node_exporter
    }
    log_success "Node Exporter 安装完成"
}

install_zabbix_agent() {
    log_info "安装 Zabbix Agent..."
    local zabbix_server="${CONFIG_VALUES[zabbix_server]:-127.0.0.1}"
    local hostname="$(hostname -s 2>/dev/null || echo 'unknown')"

    [[ ${DRY_RUN} -eq 0 ]] && {
        case "${OS_INFO[family]}" in
            rhel)
                rpm -Uvh "https://repo.zabbix.com/zabbix/7.0/rhel/$(rpm -E %rhel)/x86_64/zabbix-release-7.0-1.el$(rpm -E %rhel).noarch.rpm" 2>/dev/null || true
                dnf install -y zabbix-agent2 2>/dev/null || yum install -y zabbix-agent2 2>/dev/null || true
                ;;
            debian)
                wget -q "https://repo.zabbix.com/zabbix/7.0/debian/pool/main/z/zabbix-release/zabbix-release_7.0-1+$(lsb_release -cs)_all.deb" -O /tmp/zabbix-release.deb 2>/dev/null || true
                dpkg -i /tmp/zabbix-release.deb 2>/dev/null || true
                apt-get update -qq
                apt-get install -y zabbix-agent2 2>/dev/null || true
                ;;
        esac

        if [[ -f /etc/zabbix/zabbix_agent2.conf ]]; then
            backup_file "/etc/zabbix/zabbix_agent2.conf"
            sed -i "s/^Server=.*/Server=${zabbix_server}/" /etc/zabbix/zabbix_agent2.conf 2>/dev/null || true
            sed -i "s/^ServerActive=.*/ServerActive=${zabbix_server}/" /etc/zabbix/zabbix_agent2.conf 2>/dev/null || true
            sed -i "s/^Hostname=.*/Hostname=${hostname}/" /etc/zabbix/zabbix_agent2.conf 2>/dev/null || true
            systemctl enable zabbix-agent2 2>/dev/null || true
            systemctl restart zabbix-agent2 2>/dev/null || true
        fi
    }
    log_success "Zabbix Agent 安装完成"
}

# ============================================================================
# 日志轮转配置模块
# ============================================================================

configure_logrotate() {
    log_step "配置日志轮转策略..."

    write_config "/etc/logrotate.d/system-logs" "/var/log/syslog
/var/log/messages
/var/log/kern.log
/var/log/auth.log
/var/log/daemon.log
/var/log/cron.log
{
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
    sharedscripts
    postrotate
        /usr/bin/systemctl reload rsyslog > /dev/null 2>&1 || true
    endscript
}

/var/log/nginx/*.log
/var/log/httpd/*.log
{
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 www-data adm
    sharedscripts
    prerotate
        if [ -d /etc/logrotate.d/httpd-prerotate ]; then \\
            run-parts /etc/logrotate.d/httpd-prerotate; \\
        fi
    endscript
    postrotate
        invoke-rc.d nginx rotate >/dev/null 2>&1 || true
    endscript
}

/var/log/mysql/*.log
/var/log/mysql/*.err
{
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 640 mysql adm
    sharedscripts
    postrotate
        test -x /usr/bin/mysqladmin && mysqladmin flush-logs 2>/dev/null || true
    endscript
}

/var/log/docker/*.log
{
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    create 0644 root root
}"

    log_info "配置journald日志大小限制..."
    if [[ -f /etc/systemd/journald.conf ]]; then
        backup_file "/etc/systemd/journald.conf"
        [[ ${DRY_RUN} -eq 0 ]] && {
            sed -i 's/^#SystemMaxUse=.*/SystemMaxUse=500M/' /etc/systemd/journald.conf 2>/dev/null || true
            sed -i 's/^#SystemKeepFree=.*/SystemKeepFree=1G/' /etc/systemd/journald.conf 2>/dev/null || true
            sed -i 's/^#MaxRetentionSec=.*/MaxRetentionSec=7day/' /etc/systemd/journald.conf 2>/dev/null || true
            sed -i 's/^#MaxFileSec=.*/MaxFileSec=1day/' /etc/systemd/journald.conf 2>/dev/null || true
            systemctl restart systemd-journald 2>/dev/null || true
        }
    fi

    log_success "日志轮转配置完成"
}

# ============================================================================
# SELinux/AppArmor配置模块
# ============================================================================

configure_selinux_apparmor() {
    log_step "配置SELinux/AppArmor..."

    if command -v getenforce &>/dev/null; then
        log_info "检测到SELinux系统"
        local current_mode="$(getenforce 2>/dev/null || echo 'Unknown')"
        log_info "当前SELinux模式: ${current_mode}"

        if [[ "${current_mode}" == "Enforcing" ]]; then
            log_info "SELinux已处于Enforcing模式"
        elif [[ "${current_mode}" == "Permissive" ]]; then
            log_info "将SELinux设置为Enforcing模式..."
            [[ ${DRY_RUN} -eq 0 ]] && {
                backup_file "/etc/selinux/config"
                sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config 2>/dev/null || true
                setenforce 1 2>/dev/null || true
            }
        elif [[ "${current_mode}" == "Disabled" ]]; then
            log_warning "SELinux已禁用, 建议启用"
            [[ ${DRY_RUN} -eq 0 ]] && {
                backup_file "/etc/selinux/config"
                sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config 2>/dev/null || true
                log_warning "SELinux将在下次重启后生效"
            }
        fi

        log_info "安装SELinux管理工具..."
        case "${OS_INFO[pkg_manager]}" in
            yum|dnf) "${OS_INFO[pkg_manager]}" install -y setroubleshoot setools policycoreutils-python-utils 2>/dev/null || true ;;
        esac

        log_info "检查SELinux布尔值..."
        [[ ${DRY_RUN} -eq 0 ]] && {
            setsebool -P httpd_can_network_connect 1 2>/dev/null || true
            setsebool -P httpd_can_network_connect_db 1 2>/dev/null || true
            setsebool -P nis_enabled 0 2>/dev/null || true
        }

    elif command -v aa-status &>/dev/null; then
        log_info "检测到AppArmor系统"
        local aa_status="$(aa-status 2>/dev/null | head -5)"
        log_info "AppArmor状态: ${aa_status}"

        [[ ${DRY_RUN} -eq 0 ]] && {
            case "${OS_INFO[pkg_manager]}" in
                apt) apt-get install -y apparmor apparmor-utils 2>/dev/null || true ;;
            esac
            systemctl enable apparmor 2>/dev/null || true
            systemctl start apparmor 2>/dev/null || true
        }
    else
        log_info "未检测到SELinux或AppArmor, 跳过"
    fi

    log_success "SELinux/AppArmor配置完成"
}

# ============================================================================
# 系统资源限制配置模块
# ============================================================================

configure_system_limits() {
    log_step "配置系统资源限制..."

    write_config "/etc/security/limits.d/99-system-limits.conf" "# 系统资源限制 - 由 system_init.sh 生成
# 文件描述符
*               soft    nofile          655360
*               hard    nofile          655360
root            soft    nofile          655360
root            hard    nofile          655360

# 进程数
*               soft    nproc           655360
*               hard    nproc           655360
root            soft    nproc           655360
root            hard    nproc           655360

# 核心转储
*               soft    core            unlimited
*               hard    core            unlimited

# 内存锁定
*               soft    memlock         65536
*               hard    memlock         65536

# 堆栈大小
*               soft    stack           8192
*               hard    stack           65536

# 优先级
*               soft    priority        0
*               hard    priority        0
"

    write_config "/etc/security/limits.d/99-docker-limits.conf" "# Docker资源限制
docker          soft    nofile          655360
docker          hard    nofile          655360
docker          soft    nproc           655360
docker          hard    nproc           655360
"

    if [[ -f /etc/systemd/system.conf ]]; then
        backup_file "/etc/systemd/system.conf"
        [[ ${DRY_RUN} -eq 0 ]] && {
            sed -i 's/^#DefaultLimitNOFILE=.*/DefaultLimitNOFILE=655360/' /etc/systemd/system.conf 2>/dev/null || true
            sed -i 's/^#DefaultLimitNPROC=.*/DefaultLimitNPROC=655360/' /etc/systemd/system.conf 2>/dev/null || true
            sed -i 's/^#DefaultLimitCORE=.*/DefaultLimitCORE=infinity/' /etc/systemd/system.conf 2>/dev/null || true
        }
    fi

    if [[ -f /etc/systemd/user.conf ]]; then
        backup_file "/etc/systemd/user.conf"
        [[ ${DRY_RUN} -eq 0 ]] && {
            sed -i 's/^#DefaultLimitNOFILE=.*/DefaultLimitNOFILE=655360/' /etc/systemd/user.conf 2>/dev/null || true
            sed -i 's/^#DefaultLimitNPROC=.*/DefaultLimitNPROC=655360/' /etc/systemd/user.conf 2>/dev/null || true
        }
    fi

    log_info "配置内核核心转储..."
    write_config "/etc/sysctl.d/99-core-dump.conf" "kernel.core_pattern = /var/core/core.%e.%p.%t
kernel.core_uses_pid = 1
fs.suid_dumpable = 0
"
    [[ ${DRY_RUN} -eq 0 ]] && {
        mkdir -p /var/core 2>/dev/null || true
        chmod 777 /var/core 2>/dev/null || true
        sysctl -p /etc/sysctl.d/99-core-dump.conf 2>/dev/null || true
    }

    log_success "系统资源限制配置完成"
}

# ============================================================================
# Sysctl配置检查模块
# ============================================================================

check_sysctl_config() {
    log_step "检查sysctl配置..."
    local expected_params=(
        "net.core.somaxconn:65535"
        "net.ipv4.tcp_tw_reuse:1"
        "net.ipv4.tcp_fin_timeout:15"
        "net.ipv4.tcp_keepalive_time:600"
        "net.ipv4.tcp_syncookies:1"
        "net.ipv4.ip_local_port_range:1024 65535"
        "vm.swappiness:10"
        "vm.overcommit_memory:0"
        "fs.file-max:2097152"
        "kernel.randomize_va_space:2"
        "kernel.kptr_restrict:2"
        "kernel.dmesg_restrict:1"
        "net.ipv4.conf.all.rp_filter:1"
        "net.ipv4.conf.all.accept_source_route:0"
        "net.ipv4.conf.all.accept_redirects:0"
        "net.ipv4.icmp_echo_ignore_broadcasts:1"
    )

    local pass=0 fail=0
    echo -e "${CYAN}=== Sysctl配置检查 ===${NC}"
    for check in "${expected_params[@]}"; do
        local key="${check%%:*}" expected="${check##*:}"
        local actual="$(sysctl -n "${key}" 2>/dev/null || echo 'N/A')"
        if [[ "${actual}" == "${expected}" ]]; then
            echo -e "  ${GREEN}[PASS]${NC} ${key} = ${actual}"
            ((pass++)) || true
        else
            echo -e "  ${RED}[FAIL]${NC} ${key} = ${actual} (期望: ${expected})"
            ((fail++)) || true
        fi
    done
    echo ""
    log_info "Sysctl检查: ${pass}通过, ${fail}失败"
    [[ ${fail} -eq 0 ]] && log_success "Sysctl配置检查全部通过" || log_warning "Sysctl配置有${fail}项不符合预期"
}

# ============================================================================
# 网络配置检查模块
# ============================================================================

check_network_config() {
    log_step "检查网络配置..."
    echo -e "${CYAN}=== 网络配置检查 ===${NC}"

    echo -e "\n${WHITE}[DNS配置]${NC}"
    if [[ -f /etc/resolv.conf ]]; then
        cat /etc/resolv.conf | grep -v '^#' | grep -v '^$' | while read -r line; do
            echo "  ${line}"
        done
    fi

    echo -e "\n${WHITE}[网络接口]${NC}"
    ip -br addr show 2>/dev/null | while read -r iface status addrs; do
        echo "  ${iface}: ${status} ${addrs}"
    done

    echo -e "\n${WHITE}[路由表]${NC}"
    ip route show | while read -r line; do
        echo "  ${line}"
    done

    echo -e "\n${WHITE}[DNS解析测试]${NC}"
    local test_domains=("google.com" "github.com" "aliyun.com")
    for domain in "${test_domains[@]}"; do
        local result="$(dig +short "${domain}" @8.8.8.8 2>/dev/null | head -1)"
        if [[ -n "${result}" ]]; then
            echo -e "  ${GREEN}[PASS]${NC} ${domain} -> ${result}"
        else
            echo -e "  ${RED}[FAIL]${NC} ${domain} 解析失败"
        fi
    done

    echo -e "\n${WHITE}[连接测试]${NC}"
    local test_hosts=("8.8.8.8:53" "1.1.1.1:53" "223.5.5.5:53")
    for target in "${test_hosts[@]}"; do
        local host="${target%%:*}" port="${target##*:}"
        if timeout 3 bash -c "echo > /dev/tcp/${host}/${port}" 2>/dev/null; then
            echo -e "  ${GREEN}[PASS]${NC} ${host}:${port} 可达"
        else
            echo -e "  ${RED}[FAIL]${NC} ${host}:${port} 不可达"
        fi
    done

    echo -e "\n${WHITE}[MTU检查]${NC}"
    for iface in $(ip -br link show | awk '{print $1}' | grep -v lo); do
        local mtu="$(cat /sys/class/net/${iface}/mtu 2>/dev/null || echo 'unknown')"
        echo "  ${iface}: MTU=${mtu}"
    done

    echo -e "\n${WHITE}[TCP连接统计]${NC}"
    ss -s 2>/dev/null | head -5 | while read -r line; do
        echo "  ${line}"
    done

    log_success "网络配置检查完成"
}

# ============================================================================
# 防火墙状态检查模块
# ============================================================================

check_firewall_status() {
    log_step "检查防火墙状态..."
    echo -e "${CYAN}=== 防火墙状态检查 ===${NC}"

    case "${OS_INFO[firewall]}" in
        firewalld)
            if command -v firewall-cmd &>/dev/null; then
                echo -e "\n${WHITE}[Firewalld状态]${NC}"
                firewall-cmd --state 2>/dev/null || echo "  未运行"
                echo -e "\n${WHITE}[默认区域]${NC}"
                firewall-cmd --get-default-zone 2>/dev/null
                echo -e "\n${WHITE}[开放服务]${NC}"
                firewall-cmd --list-services 2>/dev/null | tr ' ' '\n' | while read -r svc; do
                    echo "  ${svc}"
                done
                echo -e "\n${WHITE}[开放端口]${NC}"
                firewall-cmd --list-ports 2>/dev/null | tr ' ' '\n' | while read -r port; do
                    echo "  ${port}"
                done
                echo -e "\n${WHITE}[富规则]${NC}"
                firewall-cmd --list-rich-rules 2>/dev/null | while read -r rule; do
                    echo "  ${rule}"
                done
            else
                echo "  firewalld 未安装"
            fi
            ;;
        ufw)
            if command -v ufw &>/dev/null; then
                echo -e "\n${WHITE}[UFW状态]${NC}"
                ufw status verbose 2>/dev/null
            else
                echo "  ufw 未安装"
            fi
            ;;
        iptables)
            echo -e "\n${WHITE}[iptables规则]${NC}"
            echo "  INPUT:"
            iptables -L INPUT -n --line-numbers 2>/dev/null | while read -r line; do
                echo "    ${line}"
            done
            echo "  OUTPUT:"
            iptables -L OUTPUT -n --line-numbers 2>/dev/null | while read -r line; do
                echo "    ${line}"
            done
            ;;
    esac

    log_success "防火墙状态检查完成"
}

# ============================================================================
# 时区与区域设置模块
# ============================================================================

configure_timezone_locale() {
    log_step "配置时区与区域设置..."
    local timezone="${CONFIG_VALUES[timezone]:-Asia/Shanghai}"
    local locale="${CONFIG_VALUES[locale]:-en_US.UTF-8}"

    [[ ${DRY_RUN} -eq 0 ]] && {
        if command -v timedatectl &>/dev/null; then
            timedatectl set-timezone "${timezone}" 2>/dev/null || true
        elif [[ -f /usr/share/zoneinfo/${timezone} ]]; then
            ln -sf "/usr/share/zoneinfo/${timezone}" /etc/localtime
            echo "${timezone}" > /etc/timezone
        fi

        case "${OS_INFO[pkg_manager]}" in
            apt)
                apt-get install -y locales 2>/dev/null || true
                sed -i "s/^# ${locale}/${locale}/" /etc/locale.gen 2>/dev/null || true
                locale-gen 2>/dev/null || true
                update-locale LANG="${locale}" 2>/dev/null || true
                ;;
            yum|dnf)
                "${OS_INFO[pkg_manager]}" install -y glibc-langpack-en 2>/dev/null || true
                localectl set-locale LANG="${locale}" 2>/dev/null || true
                ;;
            *)
                log_info "跳过locale配置 (不支持的包管理器)"
                ;;
        esac
    }

    log_info "时区: ${timezone}, 区域: ${locale}"
    log_success "时区与区域设置完成"
}

# ============================================================================
# 系统清理模块
# ============================================================================

cleanup_system() {
    log_step "清理系统..."

    log_info "清理包管理器缓存..."
    [[ ${DRY_RUN} -eq 0 ]] && {
        case "${OS_INFO[pkg_manager]}" in
            yum)    yum clean all 2>/dev/null || true ;;
            dnf)    dnf clean all 2>/dev/null || true; dnf autoremove -y 2>/dev/null || true ;;
            apt)    apt-get clean 2>/dev/null || true; apt-get autoremove -y 2>/dev/null || true ;;
            apk)    apk cache -v clean 2>/dev/null || true ;;
            pacman) pacman -Sc --noconfirm 2>/dev/null || true ;;
            zypper) zypper clean 2>/dev/null || true ;;
        esac
    }

    log_info "清理旧内核..."
    [[ ${DRY_RUN} -eq 0 ]] && {
        case "${OS_INFO[family]}" in
            rhel)
                if command -v package-cleanup &>/dev/null; then
                    local kernel_count="$(package-cleanup --oldkernels --count=2 -q 2>/dev/null | wc -l)"
                    [[ ${kernel_count} -gt 0 ]] && package-cleanup --oldkernels --count=2 -y 2>/dev/null || true
                fi
                ;;
            debian)
                local old_kernels="$(dpkg -l 'linux-image-*' 2>/dev/null | grep '^ii' | awk '{print $2}' | grep -v "$(uname -r)" | head -5)"
                for kernel in ${old_kernels}; do
                    apt-get purge -y "${kernel}" 2>/dev/null || true
                done
                ;;
        esac
    }

    log_info "清理临时文件..."
    [[ ${DRY_RUN} -eq 0 ]] && {
        find /tmp -type f -atime +7 -delete 2>/dev/null || true
        find /var/tmp -type f -atime +7 -delete 2>/dev/null || true
        find /var/log -type f -name "*.gz" -mtime +30 -delete 2>/dev/null || true
        find /var/log -type f -name "*.old" -mtime +30 -delete 2>/dev/null || true
        find /var/log -type f -name "*.1" -mtime +30 -delete 2>/dev/null || true
    }

    log_info "清理systemd日志..."
    [[ ${DRY_RUN} -eq 0 ]] && journalctl --vacuum-time=7d 2>/dev/null || true

    log_info "清理Docker..."
    [[ ${DRY_RUN} -eq 0 ]] && command -v docker &>/dev/null && {
        docker system prune -af --volumes 2>/dev/null || true
        docker image prune -af 2>/dev/null || true
        docker volume prune -f 2>/dev/null || true
    } || true

    log_success "系统清理完成"
}

# ============================================================================
# 系统完整性检查模块
# ============================================================================

check_system_integrity() {
    log_step "检查系统完整性..."

    echo -e "${CYAN}=== 系统完整性检查 ===${NC}"

    echo -e "\n${WHITE}[关键文件完整性]${NC}"
    local critical_files=(
        "/etc/passwd" "/etc/shadow" "/etc/group" "/etc/gshadow"
        "/etc/ssh/sshd_config" "/etc/sudoers" "/etc/fstab"
        "/etc/hosts" "/etc/resolv.conf" "/etc/crontab"
    )
    for file in "${critical_files[@]}"; do
        if [[ -f "${file}" ]]; then
            local checksum="$(sha256sum "${file}" 2>/dev/null | awk '{print $1}')"
            local perms="$(stat -c %a "${file}" 2>/dev/null || stat -f %Lp "${file}" 2>/dev/null)"
            local owner="$(stat -c '%U:%G' "${file}" 2>/dev/null || stat -f '%Su:%Sg' "${file}" 2>/dev/null)"
            echo "  ${file}: sha256=${checksum:0:16}... perms=${perms} owner=${owner}"
        else
            echo -e "  ${RED}[MISSING]${NC} ${file}"
        fi
    done

    echo -e "\n${WHITE}[RPM/DPKG完整性检查]${NC}"
    if command -v rpm &>/dev/null; then
        local rpm_check="$(rpm -Va 2>/dev/null | head -20)"
        if [[ -n "${rpm_check}" ]]; then
            echo "  已修改的RPM包 (前20条):"
            echo "${rpm_check}" | while read -r line; do
                echo "    ${line}"
            done
        else
            echo "  所有RPM包完整性正常"
        fi
    elif command -v debsums &>/dev/null; then
        local deb_check="$(debsums -c 2>/dev/null | head -20)"
        if [[ -n "${deb_check}" ]]; then
            echo "  已修改的DEB包文件 (前20条):"
            echo "${deb_check}" | while read -r line; do
                echo "    ${line}"
            done
        else
            echo "  所有DEB包完整性正常"
        fi
    fi

    echo -e "\n${WHITE}[系统运行状态]${NC}"
    echo "  运行时间: $(uptime -p 2>/dev/null || uptime)"
    echo "  负载: $(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}')"
    echo "  内存: $(free -h | awk '/^Mem:/{print "已用"$3"/总计"$2" ("$3/$2*100"%)"}')"
    echo "  Swap: $(free -h | awk '/^Swap:/{print "已用"$3"/总计"$2}')"

    log_success "系统完整性检查完成"
}

parse_args() {
    [[ $# -eq 0 ]] && { show_usage; exit 0; }
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)
                SELECTED_MODULES[mirror]=1; SELECTED_MODULES[packages]=1; SELECTED_MODULES[kernel]=1
                SELECTED_MODULES[network]=1; SELECTED_MODULES[users]=1; SELECTED_MODULES[ssh]=1
                SELECTED_MODULES[firewall]=1; SELECTED_MODULES[time_sync]=1; SELECTED_MODULES[swap]=1
                SELECTED_MODULES[disk]=1; SELECTED_MODULES[security]=1; SELECTED_MODULES[docker]=1
                SELECTED_MODULES[devtools]=1; SELECTED_MODULES[report]=1
                SELECTED_MODULES[audit]=1; SELECTED_MODULES[hardening]=1; SELECTED_MODULES[monitoring]=1
                SELECTED_MODULES[logrotate]=1; SELECTED_MODULES[selinux]=1; SELECTED_MODULES[limits]=1
                SELECTED_MODULES[timezone_locale]=1; SELECTED_MODULES[cleanup]=1; SELECTED_MODULES[integrity]=1
                shift ;;
            --mirror)      SELECTED_MODULES[mirror]=1; shift ;;
            --packages)    SELECTED_MODULES[packages]=1; shift ;;
            --kernel)      SELECTED_MODULES[kernel]=1; shift ;;
            --network)     SELECTED_MODULES[network]=1; shift ;;
            --users)       SELECTED_MODULES[users]=1; shift ;;
            --ssh)         SELECTED_MODULES[ssh]=1; shift ;;
            --firewall)    SELECTED_MODULES[firewall]=1; shift ;;
            --time-sync)   SELECTED_MODULES[time_sync]=1; shift ;;
            --swap)        SELECTED_MODULES[swap]=1; shift ;;
            --disk)        SELECTED_MODULES[disk]=1; shift ;;
            --security)    SELECTED_MODULES[security]=1; shift ;;
            --docker)      SELECTED_MODULES[docker]=1; shift ;;
            --devtools)    SELECTED_MODULES[devtools]=1; shift ;;
            --report)      SELECTED_MODULES[report]=1; shift ;;
            --audit)       SELECTED_MODULES[audit]=1; shift ;;
            --hardening)   SELECTED_MODULES[hardening]=1; shift ;;
            --monitoring)  SELECTED_MODULES[monitoring]=1; shift ;;
            --logrotate)   SELECTED_MODULES[logrotate]=1; shift ;;
            --selinux)     SELECTED_MODULES[selinux]=1; shift ;;
            --limits)      SELECTED_MODULES[limits]=1; shift ;;
            --sysctl-check)   CHECK_MODE=sysctl; shift ;;
            --network-check)  CHECK_MODE=network; shift ;;
            --firewall-check) CHECK_MODE=firewall; shift ;;
            --cleanup)     SELECTED_MODULES[cleanup]=1; shift ;;
            --integrity)   SELECTED_MODULES[integrity]=1; shift ;;
            --timezone)    SELECTED_MODULES[timezone_locale]=1; shift ;;
            --dry-run)          DRY_RUN=1; shift ;;
            --non-interactive)  INTERACTIVE=0; shift ;;
            --verbose)          VERBOSE=1; shift ;;
            --config)           CONFIG_FILE="$2"; shift 2 ;;
            --rollback)         ROLLBACK_MODE=1; shift ;;
            --help|-h)          show_usage; exit 0 ;;
            --version|-v)       echo "v${SCRIPT_VERSION}"; exit 0 ;;
            *)                  log_error "未知选项: $1"; show_usage; exit 1 ;;
        esac
    done
}

run_modules() {
    local total=${#SELECTED_MODULES[@]} current=0
    [[ ${total} -eq 0 ]] && { log_error "没有选择任何模块"; show_usage; exit 1; }
    log_info "将执行 ${total} 个模块..."

    [[ -n "${SELECTED_MODULES[mirror]:-}" ]]           && { ((current++)); configure_mirror; }
    [[ -n "${SELECTED_MODULES[packages]:-}" ]]          && { ((current++)); install_base_packages; }
    [[ -n "${SELECTED_MODULES[kernel]:-}" ]]            && { ((current++)); optimize_kernel; }
    [[ -n "${SELECTED_MODULES[network]:-}" ]]           && { ((current++)); optimize_network; }
    [[ -n "${SELECTED_MODULES[users]:-}" ]]             && { ((current++)); manage_users; }
    [[ -n "${SELECTED_MODULES[ssh]:-}" ]]               && { ((current++)); harden_ssh; }
    [[ -n "${SELECTED_MODULES[firewall]:-}" ]]          && { ((current++)); configure_firewall; }
    [[ -n "${SELECTED_MODULES[time_sync]:-}" ]]         && { ((current++)); configure_time_sync; }
    [[ -n "${SELECTED_MODULES[swap]:-}" ]]              && { ((current++)); configure_swap; }
    [[ -n "${SELECTED_MODULES[disk]:-}" ]]              && { ((current++)); configure_disk; }
    [[ -n "${SELECTED_MODULES[security]:-}" ]]          && { ((current++)); harden_security; }
    [[ -n "${SELECTED_MODULES[docker]:-}" ]]            && { ((current++)); install_docker; }
    [[ -n "${SELECTED_MODULES[devtools]:-}" ]]          && { ((current++)); install_devtools; }
    [[ -n "${SELECTED_MODULES[audit]:-}" ]]             && { ((current++)); run_security_audit; }
    [[ -n "${SELECTED_MODULES[hardening]:-}" ]]         && { ((current++)); apply_cis_hardening; }
    [[ -n "${SELECTED_MODULES[monitoring]:-}" ]]        && { ((current++)); install_monitoring; }
    [[ -n "${SELECTED_MODULES[logrotate]:-}" ]]         && { ((current++)); configure_logrotate; }
    [[ -n "${SELECTED_MODULES[selinux]:-}" ]]           && { ((current++)); configure_selinux_apparmor; }
    [[ -n "${SELECTED_MODULES[limits]:-}" ]]            && { ((current++)); configure_system_limits; }
    [[ -n "${SELECTED_MODULES[timezone_locale]:-}" ]]   && { ((current++)); configure_timezone_locale; }
    [[ -n "${SELECTED_MODULES[cleanup]:-}" ]]           && { ((current++)); cleanup_system; }
    [[ -n "${SELECTED_MODULES[integrity]:-}" ]]         && { ((current++)); check_system_integrity; }
    [[ -n "${SELECTED_MODULES[report]:-}" ]]            && { ((current++)); generate_report; }

    echo ""
    log_success "=========================================="
    log_success "  系统初始化完成!"
    log_success "  日志: ${LOG_FILE}"
    log_success "  备份: ${BACKUP_DIR}/${TIMESTAMP}"
    log_success "=========================================="
}

main() {
    parse_args "$@"
    print_banner

    [[ ${ROLLBACK_MODE} -eq 1 ]] && { check_root; do_rollback; exit $?; }
    [[ -n "${CONFIG_FILE}" ]] && parse_config_file "${CONFIG_FILE}"

    check_root; acquire_lock; trap release_lock EXIT
    detect_os; check_prerequisites

    [[ ${DRY_RUN} -eq 1 ]] && log_warning "====== 模拟运行模式 ======"

    case "${CHECK_MODE:-}" in
        sysctl)   check_sysctl_config; exit 0 ;;
        network)  check_network_config; exit 0 ;;
        firewall) check_firewall_status; exit 0 ;;
    esac

    [[ ${INTERACTIVE} -eq 1 ]] && [[ ${DRY_RUN} -eq 0 ]] && {
        echo -e "${YELLOW}即将执行系统初始化, 所有原始配置将被备份到: ${BACKUP_DIR}/${TIMESTAMP}${NC}"
        confirm_action "确认继续?" || { log_info "操作已取消"; exit 0; }
    }

    run_modules

    [[ ${DRY_RUN} -eq 0 ]] && {
        log_info "建议重启系统以使所有更改生效"
        confirm_action "是否立即重启?" && reboot
    }
}

main "$@"
