#!/usr/bin/env bash
# ============================================================================
#  自动备份脚本 (Auto Backup Script)
#  支持: CentOS/RHEL, Ubuntu/Debian, Alpine, Arch Linux, openSUSE
#  版本: 2.0.0
#  作者: gxfdev
#  仓库: https://github.com/gxfdev/shell-scripts
# ============================================================================
#  功能:
#    1. 文件/目录全量与增量备份
#    2. 数据库备份 (MySQL/PostgreSQL/MongoDB/Redis)
#    3. 配置文件备份
#    4. Docker容器与卷备份
#    5. 远程备份 (SCP/SFTP/S3/RSYNC)
#    6. 备份加密与压缩
#    7. 备份轮转与清理
#    8. 备份完整性校验
#    9. 备份恢复功能
#   10. 邮件/钉钉/企业微信通知
# ============================================================================
#  用法:
#    bash auto_backup.sh --all              # 执行全部备份
#    bash auto_backup.sh --files            # 仅备份文件
#    bash auto_backup.sh --database         # 仅备份数据库
#    bash auto_backup.sh --config           # 仅备份配置
#    bash auto_backup.sh --docker           # 仅备份Docker
#    bash auto_backup.sh --restore FILE     # 从备份恢复
#    bash auto_backup.sh --list             # 列出所有备份
#    bash auto_backup.sh --verify           # 校验备份完整性
#    bash auto_backup.sh --cleanup          # 清理过期备份
#    bash auto_backup.sh --config-file FILE # 使用配置文件
# ============================================================================

set -euo pipefail

SCRIPT_VERSION="2.0.0"
SCRIPT_NAME="auto_backup"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DATE_ONLY="$(date +%Y%m%d)"
HOSTNAME="$(hostname -s 2>/dev/null || echo 'unknown')"

BACKUP_ROOT="/data/backups"
LOG_DIR="/var/log/auto_backup"
LOG_FILE="${LOG_DIR}/backup_${TIMESTAMP}.log"
LOCK_FILE="/tmp/auto_backup.lock"
CONFIG_FILE=""
TEMP_DIR=""

DRY_RUN=0
VERBOSE=0
INTERACTIVE=1
COMPRESS_FORMAT="xz"
ENCRYPT_BACKUP=0
ENCRYPT_PASS=""
REMOTE_TYPE=""
REMOTE_HOST=""
REMOTE_USER=""
REMOTE_PATH=""
REMOTE_PORT=22
S3_BUCKET=""
S3_REGION=""
S3_ACCESS_KEY=""
S3_SECRET_KEY=""
NOTIFY_TYPE=""
NOTIFY_WEBHOOK=""
NOTIFY_EMAIL=""
RETENTION_DAYS=30
RETENTION_WEEKS=12
RETENTION_MONTHS=12

declare -A OS_INFO
declare -A DB_CONFIG
declare -A BACKUP_STATS
declare -a BACKUP_ITEMS
declare -a EXCLUDE_PATTERNS

BACKUP_STATS[start_time]="$(date +%s)"
BACKUP_STATS[total_size]=0
BACKUP_STATS[file_count]=0
BACKUP_STATS[error_count]=0
BACKUP_STATS[success_count]=0

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
log_debug()   { log "DEBUG" "$@"; }

die() { log "ERROR" "$@"; exit 1; }

print_banner() {
    echo -e "${CYAN}"
    cat << 'BANNER'
  ======================================================================
  =     Auto Backup Script v2.0.0                                     =
  =     https://github.com/gxfdev/shell-scripts                       =
  ======================================================================
BANNER
    echo -e "${NC}"
    echo -e "${WHITE}  主机: ${HOSTNAME} | 时间: ${TIMESTAMP}${NC}"
    echo ""
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_INFO[id]="${ID:-unknown}"; OS_INFO[family]=""
        case "${ID}" in
            centos|rhel|rocky|almalinux|ol|fedora) OS_INFO[family]="rhel"; OS_INFO[pkg_manager]="dnf" ;;
            ubuntu|debian|linuxmint)               OS_INFO[family]="debian"; OS_INFO[pkg_manager]="apt" ;;
            alpine)                                OS_INFO[family]="alpine"; OS_INFO[pkg_manager]="apk" ;;
            arch|manjaro)                          OS_INFO[family]="arch"; OS_INFO[pkg_manager]="pacman" ;;
            opensuse*)                             OS_INFO[family]="suse"; OS_INFO[pkg_manager]="zypper" ;;
        esac
    fi
}

check_root() { [[ ${EUID} -ne 0 ]] && die "需要root权限运行"; }

acquire_lock() {
    [[ -f "${LOCK_FILE}" ]] && {
        local pid="$(cat "${LOCK_FILE}" 2>/dev/null)"
        [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null && die "另一个备份进程正在运行 (PID: ${pid})"
        rm -f "${LOCK_FILE}"
    }
    echo $$ > "${LOCK_FILE}"
}

release_lock() { rm -f "${LOCK_FILE}"; }

init_backup_dir() {
    local backup_dir="${BACKUP_ROOT}/${HOSTNAME}/${DATE_ONLY}"
    mkdir -p "${backup_dir}/files" "${backup_dir}/databases" "${backup_dir}/configs" "${backup_dir}/docker" 2>/dev/null || true
    TEMP_DIR="$(mktemp -d /tmp/backup_XXXXXX)"
    echo "${backup_dir}"
}

get_compress_ext() {
    case "${COMPRESS_FORMAT}" in
        xz) echo ".tar.xz" ;;
        gz) echo ".tar.gz" ;;
        bz2) echo ".tar.bz2" ;;
        zst) echo ".tar.zst" ;;
        *) echo ".tar.gz" ;;
    esac
}

get_compress_cmd() {
    case "${COMPRESS_FORMAT}" in
        xz)  echo "tar -cJf" ;;
        gz)  echo "tar -czf" ;;
        bz2) echo "tar -cjf" ;;
        zst) echo "tar --zstd -cf" ;;
        *)   echo "tar -czf" ;;
    esac
}

human_size() {
    local bytes="$1"
    if [[ ${bytes} -ge 1073741824 ]]; then
        echo "$(echo "scale=2; ${bytes}/1073741824" | bc)GB"
    elif [[ ${bytes} -ge 1048576 ]]; then
        echo "$(echo "scale=2; ${bytes}/1048576" | bc)MB"
    elif [[ ${bytes} -ge 1024 ]]; then
        echo "$(echo "scale=2; ${bytes}/1024" | bc)KB"
    else
        echo "${bytes}B"
    fi
}

# ============================================================================
# 文件备份
# ============================================================================

backup_files() {
    log_step "备份文件/目录..."
    local backup_dir="$(init_backup_dir)/files"
    local compress_cmd="$(get_compress_cmd)"
    local ext="$(get_compress_ext)"

    local default_paths=("/etc" "/home" "/root" "/opt" "/var/www" "/var/lib" "/srv")
    local backup_paths=()
    [[ ${#BACKUP_ITEMS[@]} -gt 0 ]] && backup_paths=("${BACKUP_ITEMS[@]}") || backup_paths=("${default_paths[@]}")

    local exclude_opts=""
    local default_excludes=("*.log" "*.tmp" "*.cache" "__pycache__" "node_modules" ".git" "*.swp" "lost+found" ".DS_Store")
    [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]] && default_excludes=("${EXCLUDE_PATTERNS[@]}")
    for pat in "${default_excludes[@]}"; do
        exclude_opts="${exclude_opts} --exclude=${pat}"
    done

    for path in "${backup_paths[@]}"; do
        [[ ! -e "${path}" ]] && { log_debug "路径不存在, 跳过: ${path}"; continue; }
        local name="$(echo "${path}" | tr '/' '_' | sed 's/^_//;s/_$//')"
        local output="${backup_dir}/${name}${ext}"

        log_info "备份: ${path} -> ${output}"
        if [[ ${DRY_RUN} -eq 1 ]]; then
            log_info "[模拟运行] 将备份 ${path}"
            continue
        fi

        if ${compress_cmd} "${output}" ${exclude_opts} "${path}" 2>>"${LOG_FILE}"; then
            local fsize="$(stat -c%s "${output}" 2>/dev/null || echo 0)"
            BACKUP_STATS[total_size]=$((BACKUP_STATS[total_size] + fsize))
            ((BACKUP_STATS[success_count]++)) || true
            log_success "备份完成: ${path} ($(human_size ${fsize}))"

            if [[ ${ENCRYPT_BACKUP} -eq 1 ]] && [[ -n "${ENCRYPT_PASS}" ]]; then
                encrypt_file "${output}"
                output="${output}.enc"
            fi

            generate_checksum "${output}"
        else
            ((BACKUP_STATS[error_count]++)) || true
            log_error "备份失败: ${path}"
        fi
    done

    log_info "文件备份统计: 成功 ${BACKUP_STATS[success_count]}, 失败 ${BACKUP_STATS[error_count]}"
}

# ============================================================================
# 增量备份
# ============================================================================

backup_files_incremental() {
    log_step "执行增量文件备份..."
    local backup_dir="$(init_backup_dir)/files"
    local snapshot_file="${BACKUP_ROOT}/${HOSTNAME}/.snapshot"

    local default_paths=("/etc" "/home" "/root" "/opt" "/var/www")
    local backup_paths=()
    [[ ${#BACKUP_ITEMS[@]} -gt 0 ]] && backup_paths=("${BACKUP_ITEMS[@]}") || backup_paths=("${default_paths[@]}")

    for path in "${backup_paths[@]}"; do
        [[ ! -e "${path}" ]] && continue
        local name="$(echo "${path}" | tr '/' '_' | sed 's/^_//;s/_$//')"
        local output="${backup_dir}/${name}_incremental_$(get_compress_ext)"

        log_info "增量备份: ${path}"
        [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟运行] 增量备份 ${path}"; continue; }

        if [[ -f "${snapshot_file}_${name}" ]]; then
            tar --create --listed-incremental="${snapshot_file}_${name}" \
                --file=- "${path}" 2>/dev/null | \
                case "${COMPRESS_FORMAT}" in
                    xz)  xz -T0 ;;
                    gz)  gzip -9 ;;
                    bz2) bzip2 -9 ;;
                    zst) zstd -19 ;;
                    *)   gzip -9 ;;
                esac > "${output}" 2>>"${LOG_FILE}"
        else
            tar --create --listed-incremental="${snapshot_file}_${name}" \
                --file=- "${path}" 2>/dev/null | \
                case "${COMPRESS_FORMAT}" in
                    xz)  xz -T0 ;;
                    gz)  gzip -9 ;;
                    bz2) bzip2 -9 ;;
                    zst) zstd -19 ;;
                    *)   gzip -9 ;;
                esac > "${output}" 2>>"${LOG_FILE}"
        fi

        if [[ -f "${output}" ]]; then
            local fsize="$(stat -c%s "${output}" 2>/dev/null || echo 0)"
            BACKUP_STATS[total_size]=$((BACKUP_STATS[total_size] + fsize))
            log_success "增量备份完成: ${path} ($(human_size ${fsize}))"
            generate_checksum "${output}"
        else
            log_error "增量备份失败: ${path}"
        fi
    done
}

# ============================================================================
# 数据库备份
# ============================================================================

backup_mysql() {
    log_step "备份MySQL数据库..."
    local backup_dir="$(init_backup_dir)/databases"
    local mysql_host="${DB_CONFIG[mysql_host]:-localhost}"
    local mysql_port="${DB_CONFIG[mysql_port]:-3306}"
    local mysql_user="${DB_CONFIG[mysql_user]:-root}"
    local mysql_pass="${DB_CONFIG[mysql_pass]:-}"
    local mysql_socket="${DB_CONFIG[mysql_socket]:-/var/run/mysqld/mysqld.sock}"

    command -v mysqldump &>/dev/null || { log_error "mysqldump未安装, 跳过MySQL备份"; return 0; }

    local auth_opts=""
    [[ -n "${mysql_pass}" ]] && auth_opts="-u${mysql_user} -p${mysql_pass} -h${mysql_host} -P${mysql_port}" || auth_opts="-u${mysql_user} --socket=${mysql_socket}"

    local databases
    databases="$(mysql ${auth_opts} -e "SHOW DATABASES;" -s --skip-column-names 2>/dev/null | grep -vE '(information_schema|performance_schema|sys)')" || {
        log_error "无法连接MySQL服务器"; return 1
    }

    for db in ${databases}; do
        local output="${backup_dir}/mysql_${db}_${TIMESTAMP}.sql"
        log_info "备份MySQL数据库: ${db}"

        [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟运行] 备份MySQL: ${db}"; continue; }

        mysqldump ${auth_opts} --single-transaction --routines --triggers --events \
            --set-gtid-purged=OFF --max-allowed-packet=512M \
            "${db}" > "${output}" 2>>"${LOG_FILE}"

        if [[ -f "${output}" ]] && [[ -s "${output}" ]]; then
            case "${COMPRESS_FORMAT}" in
                xz)  xz -T0 "${output}" ;;
                gz)  gzip -9 "${output}" ;;
                bz2) bzip2 -9 "${output}" ;;
                zst) zstd -19 "${output}" ;;
                *)   gzip -9 "${output}" ;;
            esac
            output="${output}.$(echo ${COMPRESS_FORMAT} | sed 's/gz/gz/')"
            local fsize="$(stat -c%s "${output}" 2>/dev/null || echo 0)"
            BACKUP_STATS[total_size]=$((BACKUP_STATS[total_size] + fsize))
            ((BACKUP_STATS[success_count]++)) || true
            log_success "MySQL备份完成: ${db} ($(human_size ${fsize}))"
            [[ ${ENCRYPT_BACKUP} -eq 1 ]] && [[ -n "${ENCRYPT_PASS}" ]] && encrypt_file "${output}"
            generate_checksum "${output}"
        else
            ((BACKUP_STATS[error_count]++)) || true
            log_error "MySQL备份失败: ${db}"
        fi
    done

    log_info "MySQL全库备份..."
    local all_output="${backup_dir}/mysql_alldatabases_${TIMESTAMP}.sql"
    [[ ${DRY_RUN} -eq 0 ]] && {
        mysqldump ${auth_opts} --all-databases --single-transaction --routines --triggers --events \
            --set-gtid-purged=OFF --max-allowed-packet=512M > "${all_output}" 2>>"${LOG_FILE}"
        [[ -f "${all_output}" ]] && [[ -s "${all_output}" ]] && {
            gzip -9 "${all_output}"
            log_success "MySQL全库备份完成"
        }
    }
}

backup_postgresql() {
    log_step "备份PostgreSQL数据库..."
    local backup_dir="$(init_backup_dir)/databases"
    local pg_host="${DB_CONFIG[pg_host]:-localhost}"
    local pg_port="${DB_CONFIG[pg_port]:-5432}"
    local pg_user="${DB_CONFIG[pg_user]:-postgres}"
    local pg_pass="${DB_CONFIG[pg_pass]:-}"

    command -v pg_dump &>/dev/null || { log_error "pg_dump未安装, 跳过PostgreSQL备份"; return 0; }

    local pg_env="PGPASSWORD=${pg_pass}"
    local conn_opts="-h${pg_host} -p${pg_port} -U${pg_user}"

    local databases
    databases="$(eval ${pg_env} psql ${conn_opts} -lt 2>/dev/null | awk -F'|' '{print $1}' | grep -vE '^\s*$|template|postgres' | xargs)" || {
        log_error "无法连接PostgreSQL服务器"; return 1
    }

    for db in ${databases}; do
        local output="${backup_dir}/postgresql_${db}_${TIMESTAMP}.sql"
        log_info "备份PostgreSQL数据库: ${db}"
        [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟运行] 备份PostgreSQL: ${db}"; continue; }

        eval ${pg_env} pg_dump ${conn_opts} -Fc -f "${output}" "${db}" 2>>"${LOG_FILE}"

        if [[ -f "${output}" ]] && [[ -s "${output}" ]]; then
            local fsize="$(stat -c%s "${output}" 2>/dev/null || echo 0)"
            BACKUP_STATS[total_size]=$((BACKUP_STATS[total_size] + fsize))
            ((BACKUP_STATS[success_count]++)) || true
            log_success "PostgreSQL备份完成: ${db} ($(human_size ${fsize}))"
            [[ ${ENCRYPT_BACKUP} -eq 1 ]] && [[ -n "${ENCRYPT_PASS}" ]] && encrypt_file "${output}"
            generate_checksum "${output}"
        else
            ((BACKUP_STATS[error_count]++)) || true
            log_error "PostgreSQL备份失败: ${db}"
        fi
    done
}

backup_mongodb() {
    log_step "备份MongoDB数据库..."
    local backup_dir="$(init_backup_dir)/databases"
    local mongo_host="${DB_CONFIG[mongo_host]:-localhost}"
    local mongo_port="${DB_CONFIG[mongo_port]:-27017}"
    local mongo_user="${DB_CONFIG[mongo_user]:-}"
    local mongo_pass="${DB_CONFIG[mongo_pass]:-}"
    local mongo_auth_db="${DB_CONFIG[mongo_auth_db]:-admin}"

    command -v mongodump &>/dev/null || { log_error "mongodump未安装, 跳过MongoDB备份"; return 0; }

    local output="${backup_dir}/mongodb_${TIMESTAMP}"
    local conn_opts="--host=${mongo_host} --port=${mongo_port}"
    [[ -n "${mongo_user}" ]] && conn_opts="${conn_opts} --username=${mongo_user} --password=${mongo_pass} --authenticationDatabase=${mongo_auth_db}"

    log_info "备份MongoDB..."
    [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟运行] 备份MongoDB"; return 0; }

    mongodump ${conn_opts} --out="${output}" --gzip 2>>"${LOG_FILE}"

    if [[ -d "${output}" ]] && [[ -n "$(ls -A "${output}" 2>/dev/null)" ]]; then
        local archive="${output}.tar.gz"
        tar -czf "${archive}" -C "$(dirname "${output}")" "$(basename "${output}")" 2>>"${LOG_FILE}"
        rm -rf "${output}"
        local fsize="$(stat -c%s "${archive}" 2>/dev/null || echo 0)"
        BACKUP_STATS[total_size]=$((BACKUP_STATS[total_size] + fsize))
        ((BACKUP_STATS[success_count]++)) || true
        log_success "MongoDB备份完成 ($(human_size ${fsize}))"
        [[ ${ENCRYPT_BACKUP} -eq 1 ]] && [[ -n "${ENCRYPT_PASS}" ]] && encrypt_file "${archive}"
        generate_checksum "${archive}"
    else
        ((BACKUP_STATS[error_count]++)) || true
        log_error "MongoDB备份失败"
    fi
}

backup_redis() {
    log_step "备份Redis..."
    local backup_dir="$(init_backup_dir)/databases"
    local redis_host="${DB_CONFIG[redis_host]:-localhost}"
    local redis_port="${DB_CONFIG[redis_port]:-6379}"
    local redis_pass="${DB_CONFIG[redis_pass]:-}"

    command -v redis-cli &>/dev/null || { log_error "redis-cli未安装, 跳过Redis备份"; return 0; }

    local auth_opts=""
    [[ -n "${redis_pass}" ]] && auth_opts="-a ${redis_pass}"

    log_info "触发Redis BGSAVE..."
    [[ ${DRY_RUN} -eq 0 ]] && redis-cli -h "${redis_host}" -p "${redis_port}" ${auth_opts} BGSAVE 2>>"${LOG_FILE}"

    sleep 2

    local redis_dir
    redis_dir="$(redis-cli -h "${redis_host}" -p "${redis_port}" ${auth_opts} CONFIG GET dir 2>/dev/null | tail -1)" || redis_dir="/var/lib/redis"
    local redis_dbfile
    redis_dbfile="$(redis-cli -h "${redis_host}" -p "${redis_port}" ${auth_opts} CONFIG GET dbfilename 2>/dev/null | tail -1)" || redis_dbfile="dump.rdb"

    local rdb_file="${redis_dir}/${redis_dbfile}"
    if [[ -f "${rdb_file}" ]]; then
        local output="${backup_dir}/redis_${TIMESTAMP}.rdb"
        cp -a "${rdb_file}" "${output}"
        gzip -9 "${output}"
        local fsize="$(stat -c%s "${output}.gz" 2>/dev/null || echo 0)"
        BACKUP_STATS[total_size]=$((BACKUP_STATS[total_size] + fsize))
        log_success "Redis备份完成 ($(human_size ${fsize}))"
        generate_checksum "${output}.gz"
    else
        log_warning "Redis RDB文件不存在: ${rdb_file}"
    fi
}

backup_databases() {
    log_step "备份数据库..."
    command -v mysql &>/dev/null && backup_mysql
    command -v psql &>/dev/null && backup_postgresql
    command -v mongodump &>/dev/null && backup_mongodb
    command -v redis-cli &>/dev/null && backup_redis
    log_success "数据库备份完成"
}

# ============================================================================
# 配置文件备份
# ============================================================================

backup_configs() {
    log_step "备份系统配置文件..."
    local backup_dir="$(init_backup_dir)/configs"
    local compress_cmd="$(get_compress_cmd)"
    local ext="$(get_compress_ext)"

    local config_paths=(
        "/etc/ssh/sshd_config"
        "/etc/ssh/ssh_config"
        "/etc/sysctl.conf"
        "/etc/sysctl.d"
        "/etc/fstab"
        "/etc/resolv.conf"
        "/etc/hosts"
        "/etc/hostname"
        "/etc/sudoers"
        "/etc/sudoers.d"
        "/etc/security"
        "/etc/pam.d"
        "/etc/crontab"
        "/etc/cron.d"
        "/etc/nginx"
        "/etc/apache2"
        "/etc/haproxy"
        "/etc/keepalived"
        "/etc/docker"
        "/etc/kubernetes"
        "/etc/etcd"
        "/etc/consul.d"
        "/etc/prometheus"
        "/etc/grafana"
        "/etc/systemd/system"
        "/etc/logrotate.d"
        "/etc/fail2ban"
        "/etc/audit"
        "/etc/chrony.conf"
        "/etc/chrony"
        "/etc/yum.repos.d"
        "/etc/apt/sources.list"
        "/etc/apt/sources.list.d"
        "/etc/pacman.d"
        "/etc/zypp/repos.d"
        "/etc/apk/repositories"
        "/etc/firewalld"
        "/etc/ufw"
        "/etc/iptables"
        "/etc/selinux"
        "/etc/rsyncd.conf"
        "/etc/exports"
    )

    local existing_paths=()
    for p in "${config_paths[@]}"; do
        [[ -e "${p}" ]] && existing_paths+=("${p}")
    done

    [[ ${#existing_paths[@]} -eq 0 ]] && { log_warning "没有找到可备份的配置文件"; return 0; }

    local output="${backup_dir}/system_configs${ext}"
    log_info "备份 ${#existing_paths[@]} 个配置路径..."

    [[ ${DRY_RUN} -eq 1 ]] && { log_info "[模拟运行] 备份配置文件"; return 0; }

    if ${compress_cmd} "${output}" "${existing_paths[@]}" 2>>"${LOG_FILE}"; then
        local fsize="$(stat -c%s "${output}" 2>/dev/null || echo 0)"
        BACKUP_STATS[total_size]=$((BACKUP_STATS[total_size] + fsize))
        log_success "配置文件备份完成 ($(human_size ${fsize}))"
        [[ ${ENCRYPT_BACKUP} -eq 1 ]] && [[ -n "${ENCRYPT_PASS}" ]] && encrypt_file "${output}"
        generate_checksum "${output}"
    else
        log_error "配置文件备份失败"
    fi

    log_info "收集系统信息..."
    local sysinfo="${backup_dir}/system_info.txt"
    [[ ${DRY_RUN} -eq 0 ]] && {
        echo "=== 系统信息 $(date) ===" > "${sysinfo}"
        echo "--- 操作系统 ---" >> "${sysinfo}"
        cat /etc/os-release >> "${sysinfo}" 2>/dev/null || true
        echo "--- 内核 ---" >> "${sysinfo}"
        uname -a >> "${sysinfo}" 2>/dev/null || true
        echo "--- 网络配置 ---" >> "${sysinfo}"
        ip addr show >> "${sysinfo}" 2>/dev/null || true
        echo "--- 路由表 ---" >> "${sysinfo}"
        ip route show >> "${sysinfo}" 2>/dev/null || true
        echo "--- 磁盘使用 ---" >> "${sysinfo}"
        df -h >> "${sysinfo}" 2>/dev/null || true
        echo "--- 挂载点 ---" >> "${sysinfo}"
        mount >> "${sysinfo}" 2>/dev/null || true
        echo "--- 已安装软件 ---" >> "${sysinfo}"
        case "${OS_INFO[pkg_manager]:-unknown}" in
            dnf|yum) rpm -qa >> "${sysinfo}" 2>/dev/null || true ;;
            apt)     dpkg -l >> "${sysinfo}" 2>/dev/null || true ;;
            apk)     apk info >> "${sysinfo}" 2>/dev/null || true ;;
            pacman)  pacman -Q >> "${sysinfo}" 2>/dev/null || true ;;
            zypper)  zypper se --installed-only >> "${sysinfo}" 2>/dev/null || true ;;
        esac
        echo "--- 监听端口 ---" >> "${sysinfo}"
        ss -tlnp >> "${sysinfo}" 2>/dev/null || true
        echo "--- 运行服务 ---" >> "${sysinfo}"
        systemctl list-units --type=service --state=running >> "${sysinfo}" 2>/dev/null || true
        echo "--- Crontab ---" >> "${sysinfo}"
        for user in $(cut -d':' -f1 /etc/passwd); do
            crontab -u "${user}" -l >> "${sysinfo}" 2>/dev/null || true
        done
        echo "--- iptables规则 ---" >> "${sysinfo}"
        iptables-save >> "${sysinfo}" 2>/dev/null || true
        echo "--- 用户列表 ---" >> "${sysinfo}"
        cat /etc/passwd >> "${sysinfo}" 2>/dev/null || true
        echo "--- 组列表 ---" >> "${sysinfo}"
        cat /etc/group >> "${sysinfo}" 2>/dev/null || true
    }
}

# ============================================================================
# Docker备份
# ============================================================================

backup_docker() {
    log_step "备份Docker环境..."
    local backup_dir="$(init_backup_dir)/docker"

    command -v docker &>/dev/null || { log_warning "Docker未安装, 跳过"; return 0; }

    log_info "备份Docker容器列表..."
    [[ ${DRY_RUN} -eq 0 ]] && {
        docker ps -a --format "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}" > "${backup_dir}/containers_list.txt" 2>/dev/null || true
        docker images --format "{{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}" > "${backup_dir}/images_list.txt" 2>/dev/null || true
        docker volume ls --format "{{.Name}}" > "${backup_dir}/volumes_list.txt" 2>/dev/null || true
        docker network ls --format "{{.Name}}\t{{.Driver}}" > "${backup_dir}/networks_list.txt" 2>/dev/null || true
    }

    log_info "备份Docker Compose文件..."
    [[ ${DRY_RUN} -eq 0 ]] && {
        find /opt /root /home /srv -name "docker-compose*.yml" -o -name "compose*.yml" 2>/dev/null | while read -r compose_file; do
            local name="$(echo "${compose_file}" | tr '/' '_' | sed 's/^_//')"
            cp -a "${compose_file}" "${backup_dir}/${name}" 2>/dev/null || true
        done
    }

    log_info "备份Docker配置..."
    [[ ${DRY_RUN} -eq 0 ]] && {
        [[ -f /etc/docker/daemon.json ]] && cp -a /etc/docker/daemon.json "${backup_dir}/daemon.json"
        [[ -d /etc/docker ]] && tar -czf "${backup_dir}/docker_config.tar.gz" -C /etc docker 2>/dev/null || true
    }

    log_info "备份Docker卷..."
    [[ ${DRY_RUN} -eq 0 ]] && {
        local volumes
        volumes="$(docker volume ls -q 2>/dev/null)" || true
        for vol in ${volumes}; do
            local output="${backup_dir}/volume_${vol}.tar.gz"
            docker run --rm -v "${vol}:/source:ro" -v "${backup_dir}:/backup" alpine \
                tar -czf "/backup/volume_${vol}.tar.gz" -C /source . 2>>"${LOG_FILE}" || true
            [[ -f "${output}" ]] && {
                local fsize="$(stat -c%s "${output}" 2>/dev/null || echo 0)"
                BACKUP_STATS[total_size]=$((BACKUP_STATS[total_size] + fsize))
                log_success "Docker卷备份完成: ${vol} ($(human_size ${fsize}))"
            }
        done
    }

    log_success "Docker备份完成"
}

# ============================================================================
# 加密与校验
# ============================================================================

encrypt_file() {
    local file="$1"
    [[ ! -f "${file}" ]] && return 1
    [[ -z "${ENCRYPT_PASS}" ]] && { log_error "未设置加密密码"; return 1; }
    log_info "加密: ${file}"
    openssl enc -aes-256-cbc -salt -pbkdf2 -in "${file}" -out "${file}.enc" -pass "pass:${ENCRYPT_PASS}" 2>>"${LOG_FILE}"
    [[ $? -eq 0 ]] && rm -f "${file}" && log_success "加密完成: ${file}.enc"
}

decrypt_file() {
    local file="$1" output="${2:-${file%.enc}}"
    [[ ! -f "${file}" ]] && return 1
    log_info "解密: ${file}"
    openssl enc -aes-256-cbc -d -pbkdf2 -in "${file}" -out "${output}" -pass "pass:${ENCRYPT_PASS}" 2>>"${LOG_FILE}"
    [[ $? -eq 0 ]] && log_success "解密完成: ${output}"
}

generate_checksum() {
    local file="$1"
    [[ ! -f "${file}" ]] && return 1
    sha256sum "${file}" > "${file}.sha256" 2>/dev/null
    md5sum "${file}" > "${file}.md5" 2>/dev/null || true
    log_debug "校验文件已生成: ${file}.sha256"
}

verify_checksum() {
    local file="$1"
    [[ ! -f "${file}" ]] && return 1
    [[ ! -f "${file}.sha256" ]] && { log_error "校验文件不存在: ${file}.sha256"; return 1; }
    if sha256sum -c "${file}.sha256" &>/dev/null; then
        log_success "校验通过: ${file}"
        return 0
    else
        log_error "校验失败: ${file}"
        return 1
    fi
}

# ============================================================================
# 远程备份传输
# ============================================================================

remote_backup_rsync() {
    local local_path="$1"
    [[ -z "${REMOTE_HOST}" ]] && { log_error "未配置远程主机"; return 1; }
    log_info "RSYNC传输到: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}"
    [[ ${DRY_RUN} -eq 0 ]] && {
        rsync -avz --progress --delete -e "ssh -p ${REMOTE_PORT}" \
            "${local_path}/" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/" 2>>"${LOG_FILE}"
    }
}

remote_backup_scp() {
    local local_path="$1"
    [[ -z "${REMOTE_HOST}" ]] && { log_error "未配置远程主机"; return 1; }
    log_info "SCP传输到: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}"
    [[ ${DRY_RUN} -eq 0 ]] && {
        scp -P "${REMOTE_PORT}" -r "${local_path}" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/" 2>>"${LOG_FILE}"
    }
}

remote_backup_s3() {
    local local_path="$1"
    command -v aws &>/dev/null || { log_error "AWS CLI未安装"; return 1; }
    [[ -z "${S3_BUCKET}" ]] && { log_error "未配置S3 Bucket"; return 1; }
    log_info "S3上传: s3://${S3_BUCKET}/${REMOTE_PATH}"
    [[ ${DRY_RUN} -eq 0 ]] && {
        AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY}" AWS_SECRET_ACCESS_KEY="${S3_SECRET_KEY}" \
            aws s3 sync "${local_path}" "s3://${S3_BUCKET}/${REMOTE_PATH}/" \
            --region "${S3_REGION}" 2>>"${LOG_FILE}"
    }
}

transfer_backup() {
    log_step "传输备份到远程..."
    local backup_dir="${BACKUP_ROOT}/${HOSTNAME}/${DATE_ONLY}"
    [[ ! -d "${backup_dir}" ]] && { log_error "备份目录不存在"; return 1; }

    case "${REMOTE_TYPE}" in
        rsync) remote_backup_rsync "${backup_dir}" ;;
        scp)   remote_backup_scp "${backup_dir}" ;;
        s3)    remote_backup_s3 "${backup_dir}" ;;
        *)     log_warning "未配置远程备份类型, 跳过传输" ;;
    esac
}

# ============================================================================
# 备份轮转与清理
# ============================================================================

cleanup_backups() {
    log_step "清理过期备份..."
    local daily_days="${RETENTION_DAYS}"
    local weekly_weeks="${RETENTION_WEEKS}"
    local monthly_months="${RETENTION_MONTHS}"

    log_info "保留策略: 日备份${daily_days}天, 周备份${weekly_weeks}周, 月备份${monthly_months}月"

    [[ ${DRY_RUN} -eq 0 ]] && {
        find "${BACKUP_ROOT}/${HOSTNAME}" -maxdepth 1 -type d -name "20*" | sort -r | {
            local count=0
            while read -r dir; do
                ((count++)) || true
                local dirname="$(basename "${dir}")"
                local day_of_week="$(date -d "${dirname}" +%w 2>/dev/null || echo 0)"
                local day_of_month="$(date -d "${dirname}" +%d 2>/dev/null || echo 01)"

                if [[ ${count} -le ${daily_days} ]]; then
                    continue
                elif [[ "${day_of_week}" == "0" ]] && [[ ${count} -le $((daily_days + weekly_weeks * 7)) ]]; then
                    continue
                elif [[ "${day_of_month}" == "01" ]] && [[ ${count} -le $((daily_days + monthly_months * 30)) ]]; then
                    continue
                else
                    log_info "删除过期备份: ${dir}"
                    rm -rf "${dir}"
                fi
            done
        }

        find "${BACKUP_ROOT}" -name "*.tmp" -mtime +1 -delete 2>/dev/null || true
        find "${BACKUP_ROOT}" -name "*.log" -mtime +30 -delete 2>/dev/null || true
        find "${LOG_DIR}" -name "*.log" -mtime +30 -delete 2>/dev/null || true
    }
    log_success "过期备份清理完成"
}

# ============================================================================
# 备份恢复
# ============================================================================

restore_backup() {
    local backup_file="$1"
    [[ ! -f "${backup_file}" ]] && die "备份文件不存在: ${backup_file}"

    log_step "恢复备份: ${backup_file}"

    if [[ "${backup_file}" == *.enc ]]; then
        log_info "检测到加密备份, 先解密..."
        decrypt_file "${backup_file}"
        backup_file="${backup_file%.enc}"
    fi

    if [[ -f "${backup_file}.sha256" ]]; then
        verify_checksum "${backup_file}" || die "备份文件校验失败, 可能已损坏"
    fi

    local restore_dir="${TEMP_DIR}/restore_$(date +%s)"
    mkdir -p "${restore_dir}"

    case "${backup_file}" in
        *.tar.xz)  tar -xJf "${backup_file}" -C "${restore_dir}" ;;
        *.tar.gz)  tar -xzf "${backup_file}" -C "${restore_dir}" ;;
        *.tar.bz2) tar -xjf "${backup_file}" -C "${restore_dir}" ;;
        *.tar.zst) tar --zstd -xf "${backup_file}" -C "${restore_dir}" ;;
        *.sql.gz)  gunzip -c "${backup_file}" > "${restore_dir}/restore.sql" ;;
        *.sql)     cp -a "${backup_file}" "${restore_dir}/" ;;
        *.rdb.gz)  gunzip -c "${backup_file}" > "${restore_dir}/restore.rdb" ;;
        *)         log_error "不支持的备份格式: ${backup_file}"; return 1 ;;
    esac

    log_success "备份已解压到: ${restore_dir}"
    log_info "请手动检查恢复内容并复制到目标位置"
}

list_backups() {
    log_step "列出所有备份..."
    echo -e "${CYAN}=== 备份列表 ===${NC}"
    if [[ -d "${BACKUP_ROOT}/${HOSTNAME}" ]]; then
        for dir in $(ls -dt "${BACKUP_ROOT}/${HOSTNAME}"/20* 2>/dev/null); do
            local name="$(basename "${dir}")"
            local size="$(du -sh "${dir}" 2>/dev/null | cut -f1)"
            local file_count="$(find "${dir}" -type f | wc -l)"
            echo -e "  ${GREEN}${name}${NC}  大小: ${size}  文件数: ${file_count}"
            for f in "${dir}"/*; do
                [[ -d "${f}" ]] && {
                    local sub_size="$(du -sh "${f}" 2>/dev/null | cut -f1)"
                    echo -e "    └─ $(basename "${f}"): ${sub_size}"
                }
            done
        done
    else
        echo "  没有找到备份"
    fi
}

verify_all_backups() {
    log_step "校验所有备份..."
    local total=0 pass=0 fail=0
    find "${BACKUP_ROOT}" -name "*.sha256" | while read -r sha_file; do
        ((total++)) || true
        local backup_file="${sha_file%.sha256}"
        if sha256sum -c "${sha_file}" &>/dev/null; then
            ((pass++)) || true
            log_success "校验通过: ${backup_file}"
        else
            ((fail++)) || true
            log_error "校验失败: ${backup_file}"
        fi
    done
    log_info "校验结果: 总计 ${total}, 通过 ${pass}, 失败 ${fail}"
}

# ============================================================================
# 通知
# ============================================================================

send_notification() {
    local subject="$1" message="$2"
    [[ -z "${NOTIFY_TYPE}" ]] && return 0

    case "${NOTIFY_TYPE}" in
        email)
            [[ -n "${NOTIFY_EMAIL}" ]] && command -v mail &>/dev/null && {
                echo "${message}" | mail -s "${subject}" "${NOTIFY_EMAIL}" 2>/dev/null || true
            } ;;
        dingtalk)
            [[ -n "${NOTIFY_WEBHOOK}" ]] && {
                curl -s -X POST "${NOTIFY_WEBHOOK}" \
                    -H 'Content-Type: application/json' \
                    -d "{\"msgtype\":\"text\",\"text\":{\"content\":\"${subject}\n\n${message}\"}}" &>/dev/null || true
            } ;;
        wechat)
            [[ -n "${NOTIFY_WEBHOOK}" ]] && {
                curl -s -X POST "${NOTIFY_WEBHOOK}" \
                    -H 'Content-Type: application/json' \
                    -d "{\"msgtype\":\"text\",\"text\":{\"content\":\"${subject}\n\n${message}\"}}" &>/dev/null || true
            } ;;
        webhook)
            [[ -n "${NOTIFY_WEBHOOK}" ]] && {
                curl -s -X POST "${NOTIFY_WEBHOOK}" \
                    -H 'Content-Type: application/json' \
                    -d "{\"subject\":\"${subject}\",\"message\":\"${message}\"}" &>/dev/null || true
            } ;;
    esac
}

# ============================================================================
# 配置文件解析
# ============================================================================

parse_config_file() {
    local config="$1"
    [[ ! -f "${config}" ]] && { log_error "配置文件不存在: ${config}"; return 1; }
    while IFS='=' read -r key value; do
        key="$(echo "${key}" | xargs)"; value="$(echo "${value}" | xargs)"
        [[ -z "${key}" ]] || [[ "${key}" =~ ^# ]] && continue
        case "${key}" in
            backup_root)     BACKUP_ROOT="${value}" ;;
            compress_format) COMPRESS_FORMAT="${value}" ;;
            encrypt_backup)  ENCRYPT_BACKUP="${value}" ;;
            encrypt_pass)    ENCRYPT_PASS="${value}" ;;
            remote_type)     REMOTE_TYPE="${value}" ;;
            remote_host)     REMOTE_HOST="${value}" ;;
            remote_user)     REMOTE_USER="${value}" ;;
            remote_path)     REMOTE_PATH="${value}" ;;
            remote_port)     REMOTE_PORT="${value}" ;;
            s3_bucket)       S3_BUCKET="${value}" ;;
            s3_region)       S3_REGION="${value}" ;;
            s3_access_key)   S3_ACCESS_KEY="${value}" ;;
            s3_secret_key)   S3_SECRET_KEY="${value}" ;;
            notify_type)     NOTIFY_TYPE="${value}" ;;
            notify_webhook)  NOTIFY_WEBHOOK="${value}" ;;
            notify_email)    NOTIFY_EMAIL="${value}" ;;
            retention_days)  RETENTION_DAYS="${value}" ;;
            retention_weeks) RETENTION_WEEKS="${value}" ;;
            retention_months) RETENTION_MONTHS="${value}" ;;
            mysql_host)  DB_CONFIG[mysql_host]="${value}" ;;
            mysql_port)  DB_CONFIG[mysql_port]="${value}" ;;
            mysql_user)  DB_CONFIG[mysql_user]="${value}" ;;
            mysql_pass)  DB_CONFIG[mysql_pass]="${value}" ;;
            pg_host)     DB_CONFIG[pg_host]="${value}" ;;
            pg_port)     DB_CONFIG[pg_port]="${value}" ;;
            pg_user)     DB_CONFIG[pg_user]="${value}" ;;
            pg_pass)     DB_CONFIG[pg_pass]="${value}" ;;
            mongo_host)  DB_CONFIG[mongo_host]="${value}" ;;
            mongo_port)  DB_CONFIG[mongo_port]="${value}" ;;
            mongo_user)  DB_CONFIG[mongo_user]="${value}" ;;
            mongo_pass)  DB_CONFIG[mongo_pass]="${value}" ;;
            redis_host)  DB_CONFIG[redis_host]="${value}" ;;
            redis_port)  DB_CONFIG[redis_port]="${value}" ;;
            redis_pass)  DB_CONFIG[redis_pass]="${value}" ;;
            backup_paths)   IFS=',' read -ra BACKUP_ITEMS <<< "${value}" ;;
            exclude_patterns) IFS=',' read -ra EXCLUDE_PATTERNS <<< "${value}" ;;
        esac
    done < "${config}"
}

show_usage() {
    cat << USAGE
自动备份脚本 v${SCRIPT_VERSION}

用法: bash auto_backup.sh [选项]

备份类型:
  --all              执行全部备份 (文件+数据库+配置+Docker)
  --files            仅备份文件/目录
  --incremental      执行增量文件备份
  --database         仅备份数据库
  --config           仅备份系统配置
  --docker           仅备份Docker环境

操作:
  --restore FILE     从备份文件恢复
  --list             列出所有备份
  --verify           校验备份完整性
  --cleanup          清理过期备份

控制选项:
  --dry-run          模拟运行
  --verbose          详细输出
  --config-file FILE 使用配置文件
  --help             显示帮助
  --version          显示版本

配置文件格式 (backup.cfg):
  backup_root=/data/backups
  compress_format=xz
  encrypt_backup=1
  encrypt_pass=YourPassword
  remote_type=rsync|scp|s3
  remote_host=192.168.1.100
  remote_user=backup
  remote_path=/backup
  notify_type=email|dingtalk|wechat|webhook
  notify_webhook=https://...
  retention_days=30
  mysql_host=localhost
  mysql_user=root
  mysql_pass=Password
  backup_paths=/etc,/home,/opt
  exclude_patterns=*.log,node_modules,.git

支持的操作系统:
  CentOS/RHEL, Ubuntu/Debian, Alpine, Arch Linux, openSUSE
USAGE
}

parse_args() {
    [[ $# -eq 0 ]] && { show_usage; exit 0; }
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)         SELECTED_MODULES[all]=1 ;;
            --files)       SELECTED_MODULES[files]=1 ;;
            --incremental) SELECTED_MODULES[incremental]=1 ;;
            --database)    SELECTED_MODULES[database]=1 ;;
            --config)      SELECTED_MODULES[config]=1 ;;
            --docker)      SELECTED_MODULES[docker]=1 ;;
            --restore)     SELECTED_MODULES[restore]=1; RESTORE_FILE="$2"; shift ;;
            --list)        SELECTED_MODULES[list]=1 ;;
            --verify)      SELECTED_MODULES[verify]=1 ;;
            --cleanup)     SELECTED_MODULES[cleanup]=1 ;;
            --dry-run)     DRY_RUN=1 ;;
            --verbose)     VERBOSE=1 ;;
            --config-file) CONFIG_FILE="$2"; shift ;;
            --help|-h)     show_usage; exit 0 ;;
            --version|-v)  echo "v${SCRIPT_VERSION}"; exit 0 ;;
            *)             log_error "未知选项: $1"; show_usage; exit 1 ;;
        esac
        shift
    done
}

# ============================================================================
# 主流程
# ============================================================================

main() {
    parse_args "$@"
    print_banner
    detect_os

    [[ -n "${CONFIG_FILE}" ]] && parse_config_file "${CONFIG_FILE}"

    [[ -n "${SELECTED_MODULES[restore]:-}" ]] && { restore_backup "${RESTORE_FILE}"; exit $?; }
    [[ -n "${SELECTED_MODULES[list]:-}" ]]    && { list_backups; exit 0; }
    [[ -n "${SELECTED_MODULES[verify]:-}" ]]  && { verify_all_backups; exit 0; }
    [[ -n "${SELECTED_MODULES[cleanup]:-}" ]] && { check_root; cleanup_backups; exit 0; }

    check_root; acquire_lock; trap release_lock EXIT
    mkdir -p "${BACKUP_ROOT}" "${LOG_DIR}" 2>/dev/null || true

    [[ ${DRY_RUN} -eq 1 ]] && log_warning "====== 模拟运行模式 ======"

    if [[ -n "${SELECTED_MODULES[all]:-}" ]]; then
        backup_files; backup_databases; backup_configs; backup_docker
    else
        [[ -n "${SELECTED_MODULES[files]:-}" ]]       && backup_files
        [[ -n "${SELECTED_MODULES[incremental]:-}" ]]  && backup_files_incremental
        [[ -n "${SELECTED_MODULES[database]:-}" ]]     && backup_databases
        [[ -n "${SELECTED_MODULES[config]:-}" ]]       && backup_configs
        [[ -n "${SELECTED_MODULES[docker]:-}" ]]       && backup_docker
    fi

    [[ -n "${REMOTE_TYPE}" ]] && transfer_backup
    cleanup_backups

    BACKUP_STATS[end_time]="$(date +%s)"
    local duration=$((BACKUP_STATS[end_time] - BACKUP_STATS[start_time]))
    local total_size_human="$(human_size ${BACKUP_STATS[total_size]})"

    echo ""
    log_success "=========================================="
    log_success "  备份完成!"
    log_success "  耗时: ${duration}秒"
    log_success "  总大小: ${total_size_human}"
    log_success "  成功: ${BACKUP_STATS[success_count]} | 失败: ${BACKUP_STATS[error_count]}"
    log_success "  日志: ${LOG_FILE}"
    log_success "=========================================="

    send_notification "备份完成 - ${HOSTNAME}" "主机: ${HOSTNAME}
时间: $(date)
耗时: ${duration}秒
大小: ${total_size_human}
成功: ${BACKUP_STATS[success_count]}
失败: ${BACKUP_STATS[error_count]}"

    rm -rf "${TEMP_DIR}" 2>/dev/null || true
}

main "$@"
