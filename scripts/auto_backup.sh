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
DECRYPT_FILE=""

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

confirm_action() {
    local prompt="$1"
    echo -ne "${YELLOW}${prompt} [y/N]: ${NC}"
    read -r response
    [[ "${response}" =~ ^[Yy]$ ]]
}

# ============================================================================
# 备份前检查模块
# ============================================================================

pre_backup_check() {
    log_step "执行备份前检查..."

    log_info "检查磁盘空间..."
    local backup_dir="${BACKUP_ROOT}"
    local available_space
    available_space="$(df "${backup_dir}" 2>/dev/null | awk 'NR==2{print $4}')"
    available_space="${available_space:-0}"
    local available_gb=$((available_space / 1024 / 1024))
    if [[ ${available_gb} -lt 5 ]]; then
        log_error "磁盘空间不足: ${available_gb}GB 可用 (需要至少5GB)"
        return 1
    fi
    log_info "可用磁盘空间: ${available_gb}GB"

    log_info "检查备份目录权限..."
    [[ ${DRY_RUN} -eq 0 ]] && {
        mkdir -p "${BACKUP_ROOT}" 2>/dev/null || { log_error "无法创建备份目录: ${BACKUP_ROOT}"; return 1; }
        touch "${BACKUP_ROOT}/.write_test" 2>/dev/null || { log_error "备份目录不可写: ${BACKUP_ROOT}"; return 1; }
        rm -f "${BACKUP_ROOT}/.write_test"
    }

    log_info "检查必要工具..."
    local required_tools=("tar" "gzip" "sha256sum")
    for tool in "${required_tools[@]}"; do
        if ! command -v "${tool}" &>/dev/null; then
            log_error "必要工具未安装: ${tool}"
            return 1
        fi
    done

    log_info "检查数据库连接..."
    command -v mysql &>/dev/null && {
        local mysql_host="${DB_CONFIG[mysql_host]:-localhost}"
        local mysql_port="${DB_CONFIG[mysql_port]:-3306}"
        if timeout 5 bash -c "echo > /dev/tcp/${mysql_host}/${mysql_port}" 2>/dev/null; then
            log_info "MySQL连接正常: ${mysql_host}:${mysql_port}"
        else
            log_warning "MySQL连接失败: ${mysql_host}:${mysql_port}"
        fi
    }
    command -v psql &>/dev/null && {
        local pg_host="${DB_CONFIG[pg_host]:-localhost}"
        local pg_port="${DB_CONFIG[pg_port]:-5432}"
        if timeout 5 bash -c "echo > /dev/tcp/${pg_host}/${pg_port}" 2>/dev/null; then
            log_info "PostgreSQL连接正常: ${pg_host}:${pg_port}"
        else
            log_warning "PostgreSQL连接失败: ${pg_host}:${pg_port}"
        fi
    }

    log_info "检查远程备份目标..."
    case "${REMOTE_TYPE}" in
        rsync|scp)
            if [[ -n "${REMOTE_HOST}" ]]; then
                if timeout 5 ssh -o ConnectTimeout=3 -p "${REMOTE_PORT}" "${REMOTE_USER}@${REMOTE_HOST}" "echo ok" &>/dev/null; then
                    log_info "远程主机连接正常: ${REMOTE_HOST}"
                else
                    log_warning "远程主机连接失败: ${REMOTE_HOST}"
                fi
            fi
            ;;
        s3)
            command -v aws &>/dev/null || log_warning "AWS CLI未安装"
            ;;
    esac

    log_success "备份前检查完成"
    return 0
}

# ============================================================================
# 备份计划与调度模块
# ============================================================================

generate_backup_plan() {
    log_step "生成备份计划..."
    local plan_file="${BACKUP_ROOT}/${HOSTNAME}/backup_plan.txt"

    mkdir -p "$(dirname "${plan_file}")" 2>/dev/null || true

    cat > "${plan_file}" << PLAN
================================================================
  备份计划 - ${HOSTNAME} - ${TIMESTAMP}
================================================================

[1] 备份类型与策略
  - 全量备份: 每周日 02:00
  - 增量备份: 周一至周六 02:00
  - 数据库备份: 每日 03:00
  - 配置备份: 每日 04:00
  - Docker备份: 每日 04:30

[2] 保留策略
  - 日备份保留: ${RETENTION_DAYS} 天
  - 周备份保留: ${RETENTION_WEEKS} 周
  - 月备份保留: ${RETENTION_MONTHS} 月

[3] 存储与传输
  - 本地路径: ${BACKUP_ROOT}
  - 压缩格式: ${COMPRESS_FORMAT}
  - 加密: $([[ ${ENCRYPT_BACKUP} -eq 1 ]] && echo "是" || echo "否")
  - 远程类型: ${REMOTE_TYPE:-无}

[4] 备份路径
PLAN

    local default_paths=("/etc" "/home" "/root" "/opt" "/var/www" "/var/lib" "/srv")
    local backup_paths=()
    [[ ${#BACKUP_ITEMS[@]} -gt 0 ]] && backup_paths=("${BACKUP_ITEMS[@]}") || backup_paths=("${default_paths[@]}")
    for p in "${backup_paths[@]}"; do
        echo "  - ${p}" >> "${plan_file}"
    done

    cat >> "${plan_file}" << PLAN

[5] 排除规则
PLAN
    local default_excludes=("*.log" "*.tmp" "*.cache" "__pycache__" "node_modules" ".git" "*.swp" "lost+found" ".DS_Store")
    [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]] && default_excludes=("${EXCLUDE_PATTERNS[@]}")
    for pat in "${default_excludes[@]}"; do
        echo "  - ${pat}" >> "${plan_file}"
    done

    cat >> "${plan_file}" << PLAN

[6] 数据库配置
  - MySQL: ${DB_CONFIG[mysql_host]:-未配置}:${DB_CONFIG[mysql_port]:-3306}
  - PostgreSQL: ${DB_CONFIG[pg_host]:-未配置}:${DB_CONFIG[pg_port]:-5432}
  - MongoDB: ${DB_CONFIG[mongo_host]:-未配置}:${DB_CONFIG[mongo_port]:-27017}
  - Redis: ${DB_CONFIG[redis_host]:-未配置}:${DB_CONFIG[redis_port]:-6379}

[7] 通知配置
  - 类型: ${NOTIFY_TYPE:-无}
  - 邮件: ${NOTIFY_EMAIL:-未配置}
  - Webhook: $([[ -n "${NOTIFY_WEBHOOK}" ]] && echo "已配置" || echo "未配置")

[8] 建议Cron配置
  # 全量备份 (每周日)
  0 2 * * 0 /bin/bash $(realpath "$0" 2>/dev/null || echo "$0") --all --config-file /etc/auto_backup/backup.cfg >> /var/log/auto_backup/cron.log 2>&1
  # 增量备份 (周一至周六)
  0 2 * * 1-6 /bin/bash $(realpath "$0" 2>/dev/null || echo "$0") --incremental --config-file /etc/auto_backup/backup.cfg >> /var/log/auto_backup/cron.log 2>&1
  # 数据库备份 (每日)
  0 3 * * * /bin/bash $(realpath "$0" 2>/dev/null || echo "$0") --database --config-file /etc/auto_backup/backup.cfg >> /var/log/auto_backup/cron.log 2>&1
  # 清理过期备份 (每周一)
  0 5 * * 1 /bin/bash $(realpath "$0" 2>/dev/null || echo "$0") --cleanup --config-file /etc/auto_backup/backup.cfg >> /var/log/auto_backup/cron.log 2>&1
================================================================
PLAN

    log_success "备份计划已生成: ${plan_file}"
    cat "${plan_file}"
}

# ============================================================================
# 备份报告模块
# ============================================================================

generate_backup_report() {
    log_step "生成备份报告..."
    local report_file="${BACKUP_ROOT}/${HOSTNAME}/report_${TIMESTAMP}.html"

    local duration=0
    if [[ -n "${BACKUP_STATS[end_time]:-}" ]]; then
        duration=$((BACKUP_STATS[end_time] - BACKUP_STATS[start_time]))
    fi

    local total_size_human="$(human_size ${BACKUP_STATS[total_size]})"
    local os_name="$(cat /etc/os-release 2>/dev/null | grep '^PRETTY_NAME=' | cut -d'"' -f2 || echo 'Unknown')"

    cat > "${report_file}" << REPORT
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<title>备份报告 - ${HOSTNAME} - ${TIMESTAMP}</title>
<style>
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; margin: 20px; background: #f5f5f5; }
.container { max-width: 800px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
h1 { color: #333; border-bottom: 2px solid #4CAF50; padding-bottom: 10px; }
h2 { color: #555; margin-top: 25px; }
.info-table { width: 100%; border-collapse: collapse; margin: 15px 0; }
.info-table td { padding: 8px 12px; border: 1px solid #ddd; }
.info-table td:first-child { background: #f9f9f9; font-weight: bold; width: 40%; }
.success { color: #4CAF50; font-weight: bold; }
.error { color: #f44336; font-weight: bold; }
.warning { color: #ff9800; font-weight: bold; }
.footer { margin-top: 30px; padding-top: 15px; border-top: 1px solid #eee; color: #999; font-size: 12px; }
.progress-bar { background: #e0e0e0; border-radius: 4px; overflow: hidden; height: 20px; margin: 10px 0; }
.progress-fill { height: 100%; background: #4CAF50; text-align: center; color: white; line-height: 20px; }
</style>
</head>
<body>
<div class="container">
<h1>备份报告</h1>
<table class="info-table">
<tr><td>主机名</td><td>${HOSTNAME}</td></tr>
<tr><td>操作系统</td><td>${os_name}</td></tr>
<tr><td>备份时间</td><td>$(date '+%Y-%m-%d %H:%M:%S')</td></tr>
<tr><td>备份耗时</td><td>${duration} 秒</td></tr>
<tr><td>备份根目录</td><td>${BACKUP_ROOT}</td></tr>
<tr><td>压缩格式</td><td>${COMPRESS_FORMAT}</td></tr>
<tr><td>加密状态</td><td>$([[ ${ENCRYPT_BACKUP} -eq 1 ]] && echo "已加密" || echo "未加密")</td></tr>
</table>

<h2>备份统计</h2>
<table class="info-table">
<tr><td>总大小</td><td>${total_size_human}</td></tr>
<tr><td>成功数</td><td class="success">${BACKUP_STATS[success_count]}</td></tr>
<tr><td>失败数</td><td class="error">${BACKUP_STATS[error_count]}</td></tr>
<tr><td>文件数</td><td>${BACKUP_STATS[file_count]}</td></tr>
</table>

<h2>保留策略</h2>
<table class="info-table">
<tr><td>日备份保留</td><td>${RETENTION_DAYS} 天</td></tr>
<tr><td>周备份保留</td><td>${RETENTION_WEEKS} 周</td></tr>
<tr><td>月备份保留</td><td>${RETENTION_MONTHS} 月</td></tr>
</table>

<h2>远程备份</h2>
<table class="info-table">
<tr><td>传输方式</td><td>${REMOTE_TYPE:-未配置}</td></tr>
<tr><td>远程主机</td><td>${REMOTE_HOST:-未配置}</td></tr>
<tr><td>远程路径</td><td>${REMOTE_PATH:-未配置}</td></tr>
</table>

<h2>磁盘使用</h2>
<table class="info-table">
REPORT

    df -h "${BACKUP_ROOT}" 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++)h[i]=$i;next}{for(i=1;i<=NF;i++)printf "<tr><td>%s</td><td>%s</td></tr>\n",h[i],$i}' >> "${report_file}"

    cat >> "${report_file}" << REPORT
</table>

<div class="footer">
<p>报告生成时间: $(date '+%Y-%m-%d %H:%M:%S') | 脚本版本: v${SCRIPT_VERSION}</p>
<p>https://github.com/gxfdev/shell-scripts</p>
</div>
</div>
</body>
</html>
REPORT

    log_success "备份报告已生成: ${report_file}"
}

# ============================================================================
# 备份比较模块
# ============================================================================

compare_backups() {
    log_step "比较备份差异..."
    local backup_dir1="$1"
    local backup_dir2="$2"
    [[ -z "${backup_dir1}" ]] || [[ -z "${backup_dir2}" ]] && { log_error "需要指定两个备份目录"; return 1; }
    [[ ! -d "${backup_dir1}" ]] && { log_error "备份目录不存在: ${backup_dir1}"; return 1; }
    [[ ! -d "${backup_dir2}" ]] && { log_error "备份目录不存在: ${backup_dir2}"; return 1; }

    echo -e "${CYAN}=== 备份差异比较 ===${NC}"
    echo -e "  目录1: ${backup_dir1}"
    echo -e "  目录2: ${backup_dir2}"
    echo ""

    echo -e "${WHITE}[仅存在于目录1]${NC}"
    diff <(cd "${backup_dir1}" && find . -type f | sort) <(cd "${backup_dir2}" && find . -type f | sort) | grep "^<" | sed 's/^<  /  /'

    echo -e "\n${WHITE}[仅存在于目录2]${NC}"
    diff <(cd "${backup_dir1}" && find . -type f | sort) <(cd "${backup_dir2}" && find . -type f | sort) | grep "^>" | sed 's/^>  /  /'

    echo -e "\n${WHITE}[文件大小变化]${NC}"
    comm -12 <(cd "${backup_dir1}" && find . -type f | sort) <(cd "${backup_dir2}" && find . -type f | sort) | while read -r file; do
        local size1="$(stat -c%s "${backup_dir1}/${file}" 2>/dev/null || echo 0)"
        local size2="$(stat -c%s "${backup_dir2}/${file}" 2>/dev/null || echo 0)"
        if [[ ${size1} -ne ${size2} ]]; then
            echo "  ${file}: $(human_size ${size1}) -> $(human_size ${size2})"
        fi
    done

    log_success "备份差异比较完成"
}

# ============================================================================
# 备份同步模块 (双向同步)
# ============================================================================

sync_backup_to_remote() {
    log_step "同步备份到远程 (双向)..."
    [[ -z "${REMOTE_HOST}" ]] && { log_error "未配置远程主机"; return 1; }

    local local_dir="${BACKUP_ROOT}/${HOSTNAME}"
    local remote_dir="${REMOTE_PATH}/${HOSTNAME}"

    log_info "本地 -> 远程同步..."
    [[ ${DRY_RUN} -eq 0 ]] && {
        rsync -avz --delete --progress \
            -e "ssh -p ${REMOTE_PORT}" \
            "${local_dir}/" "${REMOTE_USER}@${REMOTE_HOST}:${remote_dir}/" 2>>"${LOG_FILE}"
    }

    log_success "双向同步完成"
}

# ============================================================================
# 备份压缩优化模块
# ============================================================================

optimize_backup_compression() {
    log_step "优化备份压缩..."
    local backup_dir="${BACKUP_ROOT}/${HOSTNAME}/${DATE_ONLY}"

    [[ ! -d "${backup_dir}" ]] && { log_warning "备份目录不存在"; return 0; }

    log_info "查找未压缩的备份文件..."
    find "${backup_dir}" -type f \( -name "*.sql" -o -name "*.rdb" -o -name "*.txt" \) ! -name "*.gz" ! -name "*.xz" ! -name "*.bz2" ! -name "*.zst" | while read -r file; do
        log_info "压缩: ${file}"
        [[ ${DRY_RUN} -eq 0 ]] && {
            case "${COMPRESS_FORMAT}" in
                xz)  xz -T0 "${file}" ;;
                gz)  gzip -9 "${file}" ;;
                bz2) bzip2 -9 "${file}" ;;
                zst) zstd -19 "${file}" ;;
                *)   gzip -9 "${file}" ;;
            esac
        }
    done

    log_info "重新压缩大文件 (使用更高压缩率)..."
    find "${backup_dir}" -type f -name "*.tar.gz" -size +100M | while read -r file; do
        local fsize="$(stat -c%s "${file}" 2>/dev/null || echo 0)"
        if [[ ${fsize} -gt 104857600 ]]; then
            log_info "重新压缩大文件: ${file} ($(human_size ${fsize}))"
            [[ ${DRY_RUN} -eq 0 ]] && {
                local tmp_dir="$(mktemp -d)"
                tar -xzf "${file}" -C "${tmp_dir}" 2>/dev/null || true
                xz -T0 -9 -f "${file}" 2>/dev/null || true
                rm -rf "${tmp_dir}"
            }
        fi
    done

    log_success "备份压缩优化完成"
}

# ============================================================================
# 备份去重模块
# ============================================================================

deduplicate_backups() {
    log_step "备份去重..."
    local backup_dir="${BACKUP_ROOT}/${HOSTNAME}/${DATE_ONLY}"
    [[ ! -d "${backup_dir}" ]] && { log_warning "备份目录不存在"; return 0; }

    log_info "查找重复文件..."
    local dup_count=0 dup_size=0

    declare -A file_hashes
    find "${backup_dir}" -type f ! -name "*.sha256" ! -name "*.md5" | while read -r file; do
        local hash="$(sha256sum "${file}" 2>/dev/null | awk '{print $1}')"
        local fsize="$(stat -c%s "${file}" 2>/dev/null || echo 0)"
        if [[ -n "${file_hashes[${hash}]:-}" ]]; then
            log_info "发现重复: ${file} = ${file_hashes[${hash}]}"
            [[ ${DRY_RUN} -eq 0 ]] && {
                ln -f "${file_hashes[${hash}]}" "${file}"
            }
            dup_size=$((dup_size + fsize))
            ((dup_count++)) || true
        else
            file_hashes[${hash}]="${file}"
        fi
    done

    if [[ ${dup_count} -gt 0 ]]; then
        log_success "去重完成: 发现 ${dup_count} 个重复文件, 节省 $(human_size ${dup_size})"
    else
        log_info "未发现重复文件"
    fi
}

# ============================================================================
# 数据库备份增强模块
# ============================================================================

backup_mysql_table() {
    local db="$1" table="$2"
    local backup_dir="$(init_backup_dir)/databases"
    local mysql_host="${DB_CONFIG[mysql_host]:-localhost}"
    local mysql_port="${DB_CONFIG[mysql_port]:-3306}"
    local mysql_user="${DB_CONFIG[mysql_user]:-root}"
    local mysql_pass="${DB_CONFIG[mysql_pass]:-}"

    command -v mysqldump &>/dev/null || { log_error "mysqldump未安装"; return 1; }

    local auth_opts=""
    [[ -n "${mysql_pass}" ]] && auth_opts="-u${mysql_user} -p${mysql_pass} -h${mysql_host} -P${mysql_port}"

    local output="${backup_dir}/mysql_${db}_${table}_${TIMESTAMP}.sql"
    log_info "备份MySQL表: ${db}.${table}"

    [[ ${DRY_RUN} -eq 0 ]] && {
        mysqldump ${auth_opts} --single-transaction --set-gtid-purged=OFF "${db}" "${table}" > "${output}" 2>>"${LOG_FILE}"
        [[ -f "${output}" ]] && [[ -s "${output}" ]] && {
            gzip -9 "${output}"
            log_success "MySQL表备份完成: ${db}.${table}"
            generate_checksum "${output}.gz"
        }
    }
}

backup_mysql_replication() {
    log_step "备份MySQL复制状态..."
    local backup_dir="$(init_backup_dir)/databases"
    local mysql_host="${DB_CONFIG[mysql_host]:-localhost}"
    local mysql_port="${DB_CONFIG[mysql_port]:-3306}"
    local mysql_user="${DB_CONFIG[mysql_user]:-root}"
    local mysql_pass="${DB_CONFIG[mysql_pass]:-}"

    command -v mysql &>/dev/null || return 0

    local auth_opts=""
    [[ -n "${mysql_pass}" ]] && auth_opts="-u${mysql_user} -p${mysql_pass} -h${mysql_host} -P${mysql_port}"

    [[ ${DRY_RUN} -eq 0 ]] && {
        mysql ${auth_opts} -e "SHOW MASTER STATUS\G" > "${backup_dir}/mysql_master_status_${TIMESTAMP}.txt" 2>/dev/null || true
        mysql ${auth_opts} -e "SHOW SLAVE STATUS\G" > "${backup_dir}/mysql_slave_status_${TIMESTAMP}.txt" 2>/dev/null || true
        mysql ${auth_opts} -e "SHOW BINARY LOGS;" > "${backup_dir}/mysql_binary_logs_${TIMESTAMP}.txt" 2>/dev/null || true
        mysql ${auth_opts} -e "SHOW VARIABLES LIKE '%gtid%';" > "${backup_dir}/mysql_gtid_status_${TIMESTAMP}.txt" 2>/dev/null || true
        log_success "MySQL复制状态备份完成"
    }
}

backup_postgresql_table() {
    local db="$1" table="$2"
    local backup_dir="$(init_backup_dir)/databases"
    local pg_host="${DB_CONFIG[pg_host]:-localhost}"
    local pg_port="${DB_CONFIG[pg_port]:-5432}"
    local pg_user="${DB_CONFIG[pg_user]:-postgres}"
    local pg_pass="${DB_CONFIG[pg_pass]:-}"

    command -v pg_dump &>/dev/null || { log_error "pg_dump未安装"; return 1; }

    local conn_opts="-h${pg_host} -p${pg_port} -U${pg_user}"
    local output="${backup_dir}/postgresql_${db}_${table}_${TIMESTAMP}.sql"

    log_info "备份PostgreSQL表: ${db}.${table}"
    [[ ${DRY_RUN} -eq 0 ]] && {
        PGPASSWORD="${pg_pass}" pg_dump ${conn_opts} -t "${table}" -Fc "${db}" -f "${output}" 2>>"${LOG_FILE}"
        [[ -f "${output}" ]] && [[ -s "${output}" ]] && {
            log_success "PostgreSQL表备份完成: ${db}.${table}"
            generate_checksum "${output}"
        }
    }
}

backup_etcd() {
    log_step "备份etcd..."
    local backup_dir="$(init_backup_dir)/databases"
    local etcd_endpoints="${DB_CONFIG[etcd_endpoints]:-https://127.0.0.1:2379}"
    local etcd_cert="${DB_CONFIG[etcd_cert]:-/etc/etcd/ssl/server.pem}"
    local etcd_key="${DB_CONFIG[etcd_key]:-/etc/etcd/ssl/server-key.pem}"
    local etcd_cacert="${DB_CONFIG[etcd_cacert]:-/etc/etcd/ssl/ca.pem}"

    command -v etcdctl &>/dev/null || { log_info "etcdctl未安装, 跳过"; return 0; }

    local output="${backup_dir}/etcd_snapshot_${TIMESTAMP}.db"
    log_info "备份etcd快照..."

    [[ ${DRY_RUN} -eq 0 ]] && {
        ETCDCTL_API=3 etcdctl snapshot save "${output}" \
            --endpoints="${etcd_endpoints}" \
            --cert="${etcd_cert}" \
            --key="${etcd_key}" \
            --cacert="${etcd_cacert}" 2>>"${LOG_FILE}"

        if [[ -f "${output}" ]]; then
            local fsize="$(stat -c%s "${output}" 2>/dev/null || echo 0)"
            BACKUP_STATS[total_size]=$((BACKUP_STATS[total_size] + fsize))
            log_success "etcd备份完成 ($(human_size ${fsize}))"
            generate_checksum "${output}"
        else
            log_error "etcd备份失败"
        fi
    }
}

backup_elasticsearch() {
    log_step "备份Elasticsearch..."
    local backup_dir="$(init_backup_dir)/databases"
    local es_host="${DB_CONFIG[es_host]:-localhost}"
    local es_port="${DB_CONFIG[es_port]:-9200}"
    local es_user="${DB_CONFIG[es_user]:-}"
    local es_pass="${DB_CONFIG[es_pass]:-}"

    command -v curl &>/dev/null || return 0

    local auth_opts=""
    [[ -n "${es_user}" ]] && auth_opts="-u ${es_user}:${es_pass}"

    log_info "获取Elasticsearch索引列表..."
    local indices
    indices="$(curl -s ${auth_opts} "http://${es_host}:${es_port}/_cat/indices?h=index" 2>/dev/null | grep -v "^\." | head -50)" || true

    for index in ${indices}; do
        local output="${backup_dir}/es_${index}_${TIMESTAMP}.json"
        log_info "备份Elasticsearch索引: ${index}"
        [[ ${DRY_RUN} -eq 0 ]] && {
            curl -s ${auth_opts} -X POST "http://${es_host}:${es_port}/${index}/_export" 2>/dev/null > "${output}" || true
            [[ -f "${output}" ]] && [[ -s "${output}" ]] && {
                gzip -9 "${output}"
                log_success "Elasticsearch索引备份完成: ${index}"
            }
        }
    done
}

# ============================================================================
# 备份验证增强模块
# ============================================================================

verify_backup_content() {
    log_step "验证备份内容..."
    local backup_dir="${BACKUP_ROOT}/${HOSTNAME}/${DATE_ONLY}"
    [[ ! -d "${backup_dir}" ]] && { log_warning "备份目录不存在"; return 0; }

    local total_files=0 valid_files=0 invalid_files=0

    echo -e "${CYAN}=== 备份内容验证 ===${NC}"

    find "${backup_dir}" -type f -name "*.tar.*" -o -name "*.sql.*" -o -name "*.rdb.*" | while read -r file; do
        ((total_files++)) || true
        local ext="${file##*.}"

        case "${ext}" in
            gz)
                if gzip -t "${file}" 2>/dev/null; then
                    echo -e "  ${GREEN}[VALID]${NC} ${file}"
                    ((valid_files++)) || true
                else
                    echo -e "  ${RED}[INVALID]${NC} ${file}"
                    ((invalid_files++)) || true
                fi
                ;;
            xz)
                if xz -t "${file}" 2>/dev/null; then
                    echo -e "  ${GREEN}[VALID]${NC} ${file}"
                    ((valid_files++)) || true
                else
                    echo -e "  ${RED}[INVALID]${NC} ${file}"
                    ((invalid_files++)) || true
                fi
                ;;
            bz2)
                if bzip2 -t "${file}" 2>/dev/null; then
                    echo -e "  ${GREEN}[VALID]${NC} ${file}"
                    ((valid_files++)) || true
                else
                    echo -e "  ${RED}[INVALID]${NC} ${file}"
                    ((invalid_files++)) || true
                fi
                ;;
            zst)
                if zstd -t "${file}" 2>/dev/null; then
                    echo -e "  ${GREEN}[VALID]${NC} ${file}"
                    ((valid_files++)) || true
                else
                    echo -e "  ${RED}[INVALID]${NC} ${file}"
                    ((invalid_files++)) || true
                fi
                ;;
            *)
                if [[ -f "${file}.sha256" ]]; then
                    if sha256sum -c "${file}.sha256" &>/dev/null; then
                        echo -e "  ${GREEN}[VALID]${NC} ${file}"
                        ((valid_files++)) || true
                    else
                        echo -e "  ${RED}[INVALID]${NC} ${file}"
                        ((invalid_files++)) || true
                    fi
                else
                    echo -e "  ${YELLOW}[SKIP]${NC} ${file} (无校验文件)"
                fi
                ;;
        esac
    done

    echo ""
    log_info "验证结果: 总计 ${total_files}, 有效 ${valid_files}, 无效 ${invalid_files}"
    [[ ${invalid_files} -eq 0 ]] && log_success "所有备份文件验证通过" || log_error "发现 ${invalid_files} 个无效备份文件"
}

# ============================================================================
# 备份加密增强模块
# ============================================================================

encrypt_backup_directory() {
    log_step "加密备份目录..."
    local backup_dir="${BACKUP_ROOT}/${HOSTNAME}/${DATE_ONLY}"
    [[ ! -d "${backup_dir}" ]] && { log_warning "备份目录不存在"; return 0; }
    [[ -z "${ENCRYPT_PASS}" ]] && { log_error "未设置加密密码"; return 1; }

    log_info "加密整个备份目录..."
    local output="${backup_dir}.enc"
    [[ ${DRY_RUN} -eq 0 ]] && {
        tar -cf - -C "$(dirname "${backup_dir}")" "$(basename "${backup_dir}")" | \
            openssl enc -aes-256-cbc -salt -pbkdf2 -pass "pass:${ENCRYPT_PASS}" -out "${output}" 2>>"${LOG_FILE}"

        if [[ -f "${output}" ]]; then
            log_success "目录加密完成: ${output}"
            generate_checksum "${output}"
        else
            log_error "目录加密失败"
        fi
    }
}

decrypt_backup_directory() {
    local enc_file="$1" output_dir="${2:-.}"
    [[ ! -f "${enc_file}" ]] && { log_error "加密文件不存在: ${enc_file}"; return 1; }
    [[ -z "${ENCRYPT_PASS}" ]] && { log_error "未设置加密密码"; return 1; }

    log_info "解密备份目录: ${enc_file}"
    [[ ${DRY_RUN} -eq 0 ]] && {
        openssl enc -aes-256-cbc -d -pbkdf2 -pass "pass:${ENCRYPT_PASS}" -in "${enc_file}" | \
            tar -xf - -C "${output_dir}" 2>>"${LOG_FILE}"
        log_success "目录解密完成"
    }
}

# ============================================================================
# 远程备份增强模块
# ============================================================================

remote_backup_rclone() {
    local local_path="$1"
    command -v rclone &>/dev/null || { log_error "rclone未安装"; return 1; }
    [[ -z "${REMOTE_PATH}" ]] && { log_error "未配置远程路径"; return 1; }

    log_info "Rclone传输到: ${REMOTE_PATH}"
    [[ ${DRY_RUN} -eq 0 ]] && {
        rclone sync "${local_path}" "${REMOTE_PATH}" \
            --progress \
            --transfers 4 \
            --checkers 8 \
            --contimeout 60s \
            --timeout 300s \
            --retries 3 \
            --low-level-retries 10 \
            2>>"${LOG_FILE}"
    }
}

remote_backup_oss() {
    local local_path="$1"
    command -v ossutil &>/dev/null || { log_error "ossutil未安装"; return 1; }
    [[ -z "${S3_BUCKET}" ]] && { log_error "未配置OSS Bucket"; return 1; }

    log_info "OSS上传: ${S3_BUCKET}"
    [[ ${DRY_RUN} -eq 0 ]] && {
        ossutil cp -r -f "${local_path}" "oss://${S3_BUCKET}/${REMOTE_PATH}/" 2>>"${LOG_FILE}"
    }
}

remote_backup_cos() {
    local local_path="$1"
    command -v coscli &>/dev/null || { log_error "coscli未安装"; return 1; }
    [[ -z "${S3_BUCKET}" ]] && { log_error "未配置COS Bucket"; return 1; }

    log_info "COS上传: ${S3_BUCKET}"
    [[ ${DRY_RUN} -eq 0 ]] && {
        coscli cp -r "${local_path}" "cos://${S3_BUCKET}/${REMOTE_PATH}/" 2>>"${LOG_FILE}"
    }
}

# ============================================================================
# 备份监控与告警模块
# ============================================================================

check_backup_health() {
    log_step "检查备份健康状态..."
    local healthy=1

    echo -e "${CYAN}=== 备份健康检查 ===${NC}"

    echo -e "\n${WHITE}[最近备份时间]${NC}"
    local last_backup
    last_backup="$(ls -dt "${BACKUP_ROOT}/${HOSTNAME}"/20* 2>/dev/null | head -1)"
    if [[ -n "${last_backup}" ]]; then
        local last_date="$(basename "${last_backup}")"
        local days_ago=$(( ($(date +%s) - $(date -d "${last_date}" +%s 2>/dev/null || echo 0)) / 86400 ))
        if [[ ${days_ago} -gt 1 ]]; then
            echo -e "  ${RED}[WARN]${NC} 最近备份在 ${days_ago} 天前"
            healthy=0
        else
            echo -e "  ${GREEN}[OK]${NC} 最近备份在 ${days_ago} 天前"
        fi
    else
        echo -e "  ${RED}[ERROR]${NC} 没有找到任何备份"
        healthy=0
    fi

    echo -e "\n${WHITE}[备份大小趋势]${NC}"
    local prev_size=0
    ls -dt "${BACKUP_ROOT}/${HOSTNAME}"/20* 2>/dev/null | head -7 | while read -r dir; do
        local name="$(basename "${dir}")"
        local size="$(du -sh "${dir}" 2>/dev/null | cut -f1)"
        echo "  ${name}: ${size}"
    done

    echo -e "\n${WHITE}[磁盘空间]${NC}"
    local usage_pct
    usage_pct="$(df -h "${BACKUP_ROOT}" 2>/dev/null | awk 'NR==2{print $5}' | tr -d '%')"
    if [[ -n "${usage_pct}" ]] && [[ ${usage_pct} -gt 90 ]]; then
        echo -e "  ${RED}[CRITICAL]${NC} 磁盘使用率: ${usage_pct}%"
        healthy=0
    elif [[ -n "${usage_pct}" ]] && [[ ${usage_pct} -gt 80 ]]; then
        echo -e "  ${YELLOW}[WARNING]${NC} 磁盘使用率: ${usage_pct}%"
    else
        echo -e "  ${GREEN}[OK]${NC} 磁盘使用率: ${usage_pct:-0}%"
    fi

    echo -e "\n${WHITE}[校验文件完整性]${NC}"
    local failed_checks=0
    find "${BACKUP_ROOT}" -name "*.sha256" -mtime -7 | while read -r sha_file; do
        if ! sha256sum -c "${sha_file}" &>/dev/null; then
            echo -e "  ${RED}[FAIL]${NC} ${sha_file%.sha256}"
            failed_checks=$((failed_checks + 1))
        fi
    done
    [[ ${failed_checks} -eq 0 ]] && echo -e "  ${GREEN}[OK]${NC} 所有校验文件通过"

    [[ ${healthy} -eq 1 ]] && log_success "备份健康检查通过" || log_warning "备份健康检查发现问题"
    return ${healthy}
}

# ============================================================================
# 备份恢复增强模块
# ============================================================================

restore_mysql_database() {
    local backup_file="$1" target_db="$2"
    [[ ! -f "${backup_file}" ]] && { log_error "备份文件不存在: ${backup_file}"; return 1; }
    command -v mysql &>/dev/null || { log_error "mysql未安装"; return 1; }

    local mysql_host="${DB_CONFIG[mysql_host]:-localhost}"
    local mysql_port="${DB_CONFIG[mysql_port]:-3306}"
    local mysql_user="${DB_CONFIG[mysql_user]:-root}"
    local mysql_pass="${DB_CONFIG[mysql_pass]:-}"

    local auth_opts=""
    [[ -n "${mysql_pass}" ]] && auth_opts="-u${mysql_user} -p${mysql_pass} -h${mysql_host} -P${mysql_port}"

    log_info "恢复MySQL数据库: ${target_db}"

    if [[ "${backup_file}" == *.gz ]]; then
        gunzip -c "${backup_file}" | mysql ${auth_opts} "${target_db}" 2>>"${LOG_FILE}"
    elif [[ "${backup_file}" == *.xz ]]; then
        xz -dc "${backup_file}" | mysql ${auth_opts} "${target_db}" 2>>"${LOG_FILE}"
    else
        mysql ${auth_opts} "${target_db}" < "${backup_file}" 2>>"${LOG_FILE}"
    fi

    [[ $? -eq 0 ]] && log_success "MySQL数据库恢复完成: ${target_db}" || log_error "MySQL数据库恢复失败: ${target_db}"
}

restore_postgresql_database() {
    local backup_file="$1" target_db="$2"
    [[ ! -f "${backup_file}" ]] && { log_error "备份文件不存在: ${backup_file}"; return 1; }
    command -v pg_restore &>/dev/null || { log_error "pg_restore未安装"; return 1; }

    local pg_host="${DB_CONFIG[pg_host]:-localhost}"
    local pg_port="${DB_CONFIG[pg_port]:-5432}"
    local pg_user="${DB_CONFIG[pg_user]:-postgres}"
    local pg_pass="${DB_CONFIG[pg_pass]:-}"

    local conn_opts="-h${pg_host} -p${pg_port} -U${pg_user}"

    log_info "恢复PostgreSQL数据库: ${target_db}"
    PGPASSWORD="${pg_pass}" pg_restore ${conn_opts} -d "${target_db}" -c "${backup_file}" 2>>"${LOG_FILE}"

    [[ $? -eq 0 ]] && log_success "PostgreSQL数据库恢复完成: ${target_db}" || log_error "PostgreSQL数据库恢复失败: ${target_db}"
}

# ============================================================================
# 备份调度安装模块
# ============================================================================

install_cron_schedule() {
    log_step "安装备份定时任务..."
    local script_path="$(realpath "$0" 2>/dev/null || echo "$0")"
    local config_arg=""
    [[ -n "${CONFIG_FILE}" ]] && config_arg="--config-file ${CONFIG_FILE}"

    local cron_entry_full="0 2 * * 0 ${script_path} --all ${config_arg} >> /var/log/auto_backup/cron.log 2>&1"
    local cron_entry_incr="0 2 * * 1-6 ${script_path} --incremental ${config_arg} >> /var/log/auto_backup/cron.log 2>&1"
    local cron_entry_db="0 3 * * * ${script_path} --database ${config_arg} >> /var/log/auto_backup/cron.log 2>&1"
    local cron_entry_cleanup="0 5 * * 1 ${script_path} --cleanup ${config_arg} >> /var/log/auto_backup/cron.log 2>&1"

    echo -e "${CYAN}=== 建议的Cron配置 ===${NC}"
    echo "  # 全量备份 (每周日 02:00)"
    echo "  ${cron_entry_full}"
    echo "  # 增量备份 (周一至周六 02:00)"
    echo "  ${cron_entry_incr}"
    echo "  # 数据库备份 (每日 03:00)"
    echo "  ${cron_entry_db}"
    echo "  # 清理过期备份 (每周一 05:00)"
    echo "  ${cron_entry_cleanup}"

    if [[ ${INTERACTIVE} -eq 1 ]] && [[ ${DRY_RUN} -eq 0 ]]; then
        confirm_action "是否自动安装以上Cron任务?" && {
            (crontab -l 2>/dev/null | grep -v "auto_backup.sh"; echo "${cron_entry_full}"; echo "${cron_entry_incr}"; echo "${cron_entry_db}"; echo "${cron_entry_cleanup}") | crontab -
            log_success "Cron任务已安装"
        }
    fi
}

# ============================================================================
# 备份统计模块
# ============================================================================

show_backup_statistics() {
    log_step "备份统计信息..."
    echo -e "${CYAN}=== 备份统计 ===${NC}"

    echo -e "\n${WHITE}[备份概览]${NC}"
    local total_backups=0 total_size=0
    if [[ -d "${BACKUP_ROOT}/${HOSTNAME}" ]]; then
        for dir in "${BACKUP_ROOT}/${HOSTNAME}"/20*; do
            [[ -d "${dir}" ]] || continue
            ((total_backups++)) || true
            local dir_size="$(du -sb "${dir}" 2>/dev/null | cut -f1)"
            total_size=$((total_size + dir_size))
        done
    fi
    echo "  备份总数: ${total_backups}"
    echo "  总大小: $(human_size ${total_size})"

    echo -e "\n${WHITE}[最近7天备份]${NC}"
    ls -dt "${BACKUP_ROOT}/${HOSTNAME}"/20* 2>/dev/null | head -7 | while read -r dir; do
        local name="$(basename "${dir}")"
        local size="$(du -sh "${dir}" 2>/dev/null | cut -f1)"
        local file_count="$(find "${dir}" -type f | wc -l)"
        echo "  ${name}: ${size} (${file_count} 文件)"
    done

    echo -e "\n${WHITE}[数据库备份统计]${NC}"
    find "${BACKUP_ROOT}/${HOSTNAME}" -name "mysql_*" -o -name "postgresql_*" -o -name "mongodb_*" -o -name "redis_*" 2>/dev/null | \
        awk -F/ '{print $(NF-1)"/"$NF}' | sort | tail -10 | while read -r f; do
        echo "  ${f}"
    done

    echo -e "\n${WHITE}[磁盘使用趋势]${NC}"
    df -h "${BACKUP_ROOT}" 2>/dev/null | awk 'NR==2{printf "  总计: %s | 已用: %s | 可用: %s | 使用率: %s\n", $2, $3, $4, $5}'

    log_success "备份统计完成"
}

# ============================================================================
# 备份清单导出模块
# ============================================================================

export_backup_manifest() {
    log_step "导出备份清单..."
    local backup_dir="${BACKUP_ROOT}/${HOSTNAME}/${DATE_ONLY}"
    local manifest_file="${backup_dir}/MANIFEST.json"
    [[ ! -d "${backup_dir}" ]] && { log_warning "备份目录不存在"; return 0; }

    log_info "生成JSON格式备份清单..."
    cat > "${manifest_file}" << MANIFEST_HEAD
{
  "hostname": "${HOSTNAME}",
  "timestamp": "${TIMESTAMP}",
  "date": "${DATE_ONLY}",
  "backup_root": "${BACKUP_ROOT}",
  "compress_format": "${COMPRESS_FORMAT}",
  "encrypted": $([[ ${ENCRYPT_BACKUP} -eq 1 ]] && echo "true" || echo "false"),
  "retention_days": ${RETENTION_DAYS},
  "retention_weeks": ${RETENTION_WEEKS},
  "retention_months": ${RETENTION_MONTHS},
  "files": [
MANIFEST_HEAD

    local first=1
    find "${backup_dir}" -type f ! -name "MANIFEST.json" ! -name "*.sha256" ! -name "*.md5" | sort | while read -r file; do
        local rel_path="${file#${backup_dir}/}"
        local fsize="$(stat -c%s "${file}" 2>/dev/null || echo 0)"
        local fmod="$(stat -c%Y "${file}" 2>/dev/null || echo 0)"
        local ftype="${file##*.}"
        local checksum=""
        [[ -f "${file}.sha256" ]] && checksum="$(awk '{print $1}' "${file}.sha256" 2>/dev/null)"
        [[ ${first} -eq 0 ]] && echo "," >> "${manifest_file}"
        first=0
        cat >> "${manifest_file}" << FILE_ENTRY
    {
      "path": "${rel_path}",
      "size": ${fsize},
      "modified": ${fmod},
      "type": "${ftype}",
      "sha256": "${checksum}"
    }
FILE_ENTRY
    done

    echo "" >> "${manifest_file}"
    echo "  ]," >> "${manifest_file}"

    local total_size="$(du -sb "${backup_dir}" 2>/dev/null | cut -f1)"
    local total_files="$(find "${backup_dir}" -type f ! -name "MANIFEST.json" | wc -l)"
    cat >> "${manifest_file}" << MANIFEST_FOOT
  "total_size": ${total_size:-0},
  "total_files": ${total_files:-0},
  "stats": {
    "success_count": ${BACKUP_STATS[success_count]},
    "error_count": ${BACKUP_STATS[error_count]},
    "total_size": ${BACKUP_STATS[total_size]}
  }
}
MANIFEST_FOOT

    log_success "备份清单已导出: ${manifest_file}"
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
  --verify-content   验证备份压缩文件内容
  --cleanup          清理过期备份
  --health-check     检查备份健康状态
  --plan             生成备份计划
  --report           生成HTML备份报告
  --statistics       显示备份统计
  --install-cron     安装备份定时任务
  --pre-check        执行备份前检查
  --dedup            备份去重
  --optimize         优化备份压缩
  --encrypt-dir      加密整个备份目录
  --decrypt-dir FILE 解密备份目录

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
  remote_type=rsync|scp|s3|rclone|oss|cos
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
            --all)         SELECTED_MODULES[all]=1; shift ;;
            --files)       SELECTED_MODULES[files]=1; shift ;;
            --incremental) SELECTED_MODULES[incremental]=1; shift ;;
            --database)    SELECTED_MODULES[database]=1; shift ;;
            --config)      SELECTED_MODULES[config]=1; shift ;;
            --docker)      SELECTED_MODULES[docker]=1; shift ;;
            --restore)     SELECTED_MODULES[restore]=1; RESTORE_FILE="$2"; shift 2 ;;
            --list)        SELECTED_MODULES[list]=1; shift ;;
            --verify)      SELECTED_MODULES[verify]=1; shift ;;
            --verify-content) SELECTED_MODULES[verify_content]=1; shift ;;
            --cleanup)     SELECTED_MODULES[cleanup]=1; shift ;;
            --health-check) SELECTED_MODULES[health_check]=1; shift ;;
            --plan)        SELECTED_MODULES[plan]=1; shift ;;
            --report)      SELECTED_MODULES[report]=1; shift ;;
            --statistics)  SELECTED_MODULES[statistics]=1; shift ;;
            --install-cron) SELECTED_MODULES[install_cron]=1; shift ;;
            --pre-check)   SELECTED_MODULES[pre_check]=1; shift ;;
            --dedup)       SELECTED_MODULES[dedup]=1; shift ;;
            --optimize)    SELECTED_MODULES[optimize]=1; shift ;;
            --encrypt-dir) SELECTED_MODULES[encrypt_dir]=1; shift ;;
            --decrypt-dir) SELECTED_MODULES[decrypt_dir]=1; DECRYPT_FILE="$2"; shift 2 ;;
            --dry-run)     DRY_RUN=1; shift ;;
            --verbose)     VERBOSE=1; shift ;;
            --config-file) CONFIG_FILE="$2"; shift 2 ;;
            --help|-h)     show_usage; exit 0 ;;
            --version|-v)  echo "v${SCRIPT_VERSION}"; exit 0 ;;
            *)             log_error "未知选项: $1"; show_usage; exit 1 ;;
        esac
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

    [[ -n "${SELECTED_MODULES[restore]:-}" ]]       && { restore_backup "${RESTORE_FILE}"; exit $?; }
    [[ -n "${SELECTED_MODULES[list]:-}" ]]           && { list_backups; exit 0; }
    [[ -n "${SELECTED_MODULES[verify]:-}" ]]         && { verify_all_backups; exit 0; }
    [[ -n "${SELECTED_MODULES[verify_content]:-}" ]] && { verify_backup_content; exit 0; }
    [[ -n "${SELECTED_MODULES[cleanup]:-}" ]]        && { check_root; cleanup_backups; exit 0; }
    [[ -n "${SELECTED_MODULES[health_check]:-}" ]]   && { check_backup_health; exit $?; }
    [[ -n "${SELECTED_MODULES[plan]:-}" ]]           && { generate_backup_plan; exit 0; }
    [[ -n "${SELECTED_MODULES[statistics]:-}" ]]     && { show_backup_statistics; exit 0; }
    [[ -n "${SELECTED_MODULES[install_cron]:-}" ]]   && { install_cron_schedule; exit 0; }
    [[ -n "${SELECTED_MODULES[pre_check]:-}" ]]      && { pre_backup_check; exit $?; }
    [[ -n "${SELECTED_MODULES[encrypt_dir]:-}" ]]    && { check_root; encrypt_backup_directory; exit 0; }
    [[ -n "${SELECTED_MODULES[decrypt_dir]:-}" ]]    && { decrypt_backup_directory "${DECRYPT_FILE}"; exit $?; }

    check_root; acquire_lock; trap release_lock EXIT
    mkdir -p "${BACKUP_ROOT}" "${LOG_DIR}" 2>/dev/null || true

    [[ ${DRY_RUN} -eq 1 ]] && log_warning "====== 模拟运行模式 ======"

    [[ -n "${SELECTED_MODULES[pre_check]:-}" ]] || pre_backup_check

    if [[ -n "${SELECTED_MODULES[all]:-}" ]]; then
        backup_files; backup_databases; backup_configs; backup_docker
    else
        [[ -n "${SELECTED_MODULES[files]:-}" ]]       && backup_files
        [[ -n "${SELECTED_MODULES[incremental]:-}" ]]  && backup_files_incremental
        [[ -n "${SELECTED_MODULES[database]:-}" ]]     && backup_databases
        [[ -n "${SELECTED_MODULES[config]:-}" ]]       && backup_configs
        [[ -n "${SELECTED_MODULES[docker]:-}" ]]       && backup_docker
    fi

    [[ -n "${SELECTED_MODULES[dedup]:-}" ]]           && deduplicate_backups
    [[ -n "${SELECTED_MODULES[optimize]:-}" ]]        && optimize_backup_compression

    [[ -n "${REMOTE_TYPE}" ]] && transfer_backup
    cleanup_backups

    [[ -n "${SELECTED_MODULES[report]:-}" ]]          && generate_backup_report

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
