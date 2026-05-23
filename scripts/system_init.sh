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

支持的操作系统:
  - CentOS/RHEL 7/8/9, Rocky Linux, AlmaLinux, Fedora
  - Ubuntu 18.04/20.04/22.04/24.04, Debian 10/11/12
  - Alpine Linux, Arch Linux / Manjaro, openSUSE
USAGE
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
                SELECTED_MODULES[devtools]=1; SELECTED_MODULES[report]=1 ;;
            --mirror)      SELECTED_MODULES[mirror]=1 ;;
            --packages)    SELECTED_MODULES[packages]=1 ;;
            --kernel)      SELECTED_MODULES[kernel]=1 ;;
            --network)     SELECTED_MODULES[network]=1 ;;
            --users)       SELECTED_MODULES[users]=1 ;;
            --ssh)         SELECTED_MODULES[ssh]=1 ;;
            --firewall)    SELECTED_MODULES[firewall]=1 ;;
            --time-sync)   SELECTED_MODULES[time_sync]=1 ;;
            --swap)        SELECTED_MODULES[swap]=1 ;;
            --disk)        SELECTED_MODULES[disk]=1 ;;
            --security)    SELECTED_MODULES[security]=1 ;;
            --docker)      SELECTED_MODULES[docker]=1 ;;
            --devtools)    SELECTED_MODULES[devtools]=1 ;;
            --report)      SELECTED_MODULES[report]=1 ;;
            --dry-run)          DRY_RUN=1 ;;
            --non-interactive)  INTERACTIVE=0 ;;
            --verbose)          VERBOSE=1 ;;
            --config)           CONFIG_FILE="$2"; shift ;;
            --rollback)         ROLLBACK_MODE=1 ;;
            --help|-h)          show_usage; exit 0 ;;
            --version|-v)       echo "v${SCRIPT_VERSION}"; exit 0 ;;
            *)                  log_error "未知选项: $1"; show_usage; exit 1 ;;
        esac
        shift
    done
}

run_modules() {
    local total=${#SELECTED_MODULES[@]} current=0
    [[ ${total} -eq 0 ]] && { log_error "没有选择任何模块"; show_usage; exit 1; }
    log_info "将执行 ${total} 个模块..."

    [[ -n "${SELECTED_MODULES[mirror]:-}" ]]      && { ((current++)); configure_mirror; }
    [[ -n "${SELECTED_MODULES[packages]:-}" ]]     && { ((current++)); install_base_packages; }
    [[ -n "${SELECTED_MODULES[kernel]:-}" ]]       && { ((current++)); optimize_kernel; }
    [[ -n "${SELECTED_MODULES[network]:-}" ]]      && { ((current++)); optimize_network; }
    [[ -n "${SELECTED_MODULES[users]:-}" ]]        && { ((current++)); manage_users; }
    [[ -n "${SELECTED_MODULES[ssh]:-}" ]]          && { ((current++)); harden_ssh; }
    [[ -n "${SELECTED_MODULES[firewall]:-}" ]]     && { ((current++)); configure_firewall; }
    [[ -n "${SELECTED_MODULES[time_sync]:-}" ]]    && { ((current++)); configure_time_sync; }
    [[ -n "${SELECTED_MODULES[swap]:-}" ]]         && { ((current++)); configure_swap; }
    [[ -n "${SELECTED_MODULES[disk]:-}" ]]         && { ((current++)); configure_disk; }
    [[ -n "${SELECTED_MODULES[security]:-}" ]]     && { ((current++)); harden_security; }
    [[ -n "${SELECTED_MODULES[docker]:-}" ]]       && { ((current++)); install_docker; }
    [[ -n "${SELECTED_MODULES[devtools]:-}" ]]     && { ((current++)); install_devtools; }
    [[ -n "${SELECTED_MODULES[report]:-}" ]]       && { ((current++)); generate_report; }

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
