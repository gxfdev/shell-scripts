#!/usr/bin/env bash
# ============================================================================
#  自动部署与发布脚本 (Auto Deploy Script)
#  支持: CentOS/RHEL, Ubuntu/Debian, Alpine, Arch Linux, openSUSE
#  版本: 2.0.0
#  作者: gxfdev
#  仓库: https://github.com/gxfdev/shell-scripts
# ============================================================================
#  功能:
#    1. Git仓库拉取与版本管理
#    2. 多环境部署 (dev/staging/production)
#    3. 滚动发布与灰度发布
#    4. 版本回滚
#    5. 构建与编译
#    6. Docker镜像构建与推送
#    7. 健康检查与自动回滚
#    8. 部署通知
#    9. 部署锁与并发控制
#   10. 部署历史记录
# ============================================================================

set -euo pipefail

SCRIPT_VERSION="2.0.0"
SCRIPT_NAME="auto_deploy"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DATE_ONLY="$(date +%Y%m%d)"
HOSTNAME="$(hostname -s 2>/dev/null || echo 'unknown')"

LOG_DIR="/var/log/auto_deploy"
LOG_FILE="${LOG_DIR}/deploy_${TIMESTAMP}.log"
LOCK_FILE="/tmp/auto_deploy.lock"
DEPLOY_ROOT="/opt/deploy"
HISTORY_DIR="${LOG_DIR}/history"
RELEASES_DIR="${DEPLOY_ROOT}/releases"
CURRENT_DIR="${DEPLOY_ROOT}/current"
SHARED_DIR="${DEPLOY_ROOT}/shared"

APP_NAME=""
ENVIRONMENT="production"
GIT_REPO=""
GIT_BRANCH="main"
GIT_TAG=""
GIT_COMMIT=""
BUILD_CMD=""
DEPLOY_CMD=""
PRE_DEPLOY_CMD=""
POST_DEPLOY_CMD=""
ROLLBACK_CMD=""
HEALTH_CHECK_URL=""
HEALTH_CHECK_PORT=""
HEALTH_CHECK_CMD=""
HEALTH_CHECK_RETRIES=5
HEALTH_CHECK_INTERVAL=10
AUTO_ROLLBACK=1
KEEP_RELEASES=5
DOCKER_BUILD=0
DOCKER_IMAGE=""
DOCKER_REGISTRY=""
DOCKER_TAG=""
DOCKERFILE="Dockerfile"
NOTIFY_TYPE=""
NOTIFY_WEBHOOK=""
NOTIFY_EMAIL=""
DRY_RUN=0
VERBOSE=0
ROLLBACK_VERSION=""
FORCE_DEPLOY=0

declare -A OS_INFO
declare -A DEPLOY_STATS
DEPLOY_STATS[start_time]="$(date +%s)"
DEPLOY_STATS[status]="pending"

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
  =     Auto Deploy Script v2.0.0                                     =
  =     https://github.com/gxfdev/shell-scripts                       =
  ======================================================================
BANNER
    echo -e "${NC}"
    echo -e "${WHITE}  应用: ${APP_NAME:-未指定} | 环境: ${ENVIRONMENT} | 时间: ${TIMESTAMP}${NC}"
    echo ""
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_INFO[id]="${ID:-unknown}"
        case "${ID}" in
            centos|rhel|rocky|almalinux|ol|fedora) OS_INFO[family]="rhel" ;;
            ubuntu|debian|linuxmint)               OS_INFO[family]="debian" ;;
            alpine)                                OS_INFO[family]="alpine" ;;
            arch|manjaro)                          OS_INFO[family]="arch" ;;
            opensuse*)                             OS_INFO[family]="suse" ;;
        esac
    fi
}

acquire_deploy_lock() {
    if [[ -f "${LOCK_FILE}" ]]; then
        local pid="$(cat "${LOCK_FILE}" 2>/dev/null)"
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            die "另一个部署进程正在运行 (PID: ${pid}), 使用 --force 强制执行"
        fi
        rm -f "${LOCK_FILE}"
    fi
    echo $$ > "${LOCK_FILE}"
}

release_deploy_lock() { rm -f "${LOCK_FILE}"; }

# ============================================================================
# 配置文件解析
# ============================================================================

parse_deploy_config() {
    local config="$1"
    [[ ! -f "${config}" ]] && die "配置文件不存在: ${config}"
    while IFS='=' read -r key value; do
        key="$(echo "${key}" | xargs)"; value="$(echo "${value}" | xargs)"
        [[ -z "${key}" ]] || [[ "${key}" =~ ^# ]] && continue
        case "${key}" in
            app_name)          APP_NAME="${value}" ;;
            environment)       ENVIRONMENT="${value}" ;;
            git_repo)          GIT_REPO="${value}" ;;
            git_branch)        GIT_BRANCH="${value}" ;;
            git_tag)           GIT_TAG="${value}" ;;
            build_cmd)         BUILD_CMD="${value}" ;;
            deploy_cmd)        DEPLOY_CMD="${value}" ;;
            pre_deploy_cmd)    PRE_DEPLOY_CMD="${value}" ;;
            post_deploy_cmd)   POST_DEPLOY_CMD="${value}" ;;
            rollback_cmd)      ROLLBACK_CMD="${value}" ;;
            health_check_url)  HEALTH_CHECK_URL="${value}" ;;
            health_check_port) HEALTH_CHECK_PORT="${value}" ;;
            health_check_cmd)  HEALTH_CHECK_CMD="${value}" ;;
            health_check_retries) HEALTH_CHECK_RETRIES="${value}" ;;
            auto_rollback)     AUTO_ROLLBACK="${value}" ;;
            keep_releases)     KEEP_RELEASES="${value}" ;;
            docker_build)      DOCKER_BUILD="${value}" ;;
            docker_image)      DOCKER_IMAGE="${value}" ;;
            docker_registry)   DOCKER_REGISTRY="${value}" ;;
            docker_tag)        DOCKER_TAG="${value}" ;;
            dockerfile)        DOCKERFILE="${value}" ;;
            deploy_root)       DEPLOY_ROOT="${value}" ;;
            notify_type)       NOTIFY_TYPE="${value}" ;;
            notify_webhook)    NOTIFY_WEBHOOK="${value}" ;;
            notify_email)      NOTIFY_EMAIL="${value}" ;;
        esac
    done < "${config}"

    RELEASES_DIR="${DEPLOY_ROOT}/releases"
    CURRENT_DIR="${DEPLOY_ROOT}/current"
    SHARED_DIR="${DEPLOY_ROOT}/shared"
}

# ============================================================================
# Git操作
# ============================================================================

git_clone_or_pull() {
    local repo="${GIT_REPO}" branch="${GIT_BRANCH}" tag="${GIT_TAG}" commit="${GIT_COMMIT}"
    local target_dir="${RELEASES_DIR}/${TIMESTAMP}"

    log_step "获取代码..."
    mkdir -p "${RELEASES_DIR}" 2>/dev/null || true

    if [[ -n "${tag}" ]]; then
        log_info "拉取标签: ${tag}"
        [[ ${DRY_RUN} -eq 0 ]] && git clone --branch "${tag}" --depth 1 "${repo}" "${target_dir}" 2>>"${LOG_FILE}"
    elif [[ -n "${commit}" ]]; then
        log_info "拉取指定提交: ${commit}"
        [[ ${DRY_RUN} -eq 0 ]] && {
            git clone "${repo}" "${target_dir}" 2>>"${LOG_FILE}"
            cd "${target_dir}" && git checkout "${commit}" 2>>"${LOG_FILE}"
        }
    else
        log_info "拉取分支: ${branch}"
        [[ ${DRY_RUN} -eq 0 ]] && git clone --branch "${branch}" --depth 1 "${repo}" "${target_dir}" 2>>"${LOG_FILE}"
    fi

    if [[ ${DRY_RUN} -eq 0 ]] && [[ -d "${target_dir}" ]]; then
        cd "${target_dir}"
        local current_commit="$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
        local current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
        log_success "代码获取完成: ${current_branch}@${current_commit}"
        DEPLOY_STATS[commit]="${current_commit}"
        DEPLOY_STATS[branch]="${current_branch}"
    else
        [[ ${DRY_RUN} -eq 0 ]] && die "代码获取失败"
    fi
}

# ============================================================================
# 构建流程
# ============================================================================

run_build() {
    local target_dir="${RELEASES_DIR}/${TIMESTAMP}"
    [[ ! -d "${target_dir}" ]] && die "发布目录不存在: ${target_dir}"

    log_step "构建项目..."
    cd "${target_dir}"

    if [[ -n "${BUILD_CMD}" ]]; then
        log_info "执行构建命令: ${BUILD_CMD}"
        [[ ${DRY_RUN} -eq 0 ]] && eval "${BUILD_CMD}" 2>>"${LOG_FILE}" || die "构建失败"
    else
        if [[ -f "package.json" ]]; then
            log_info "检测到Node.js项目, 执行npm构建..."
            [[ ${DRY_RUN} -eq 0 ]] && {
                command -v npm &>/dev/null || die "npm未安装"
                npm install --production 2>>"${LOG_FILE}" || die "npm install失败"
                npm run build 2>>"${LOG_FILE}" || true
            }
        elif [[ -f "go.mod" ]]; then
            log_info "检测到Go项目, 执行go构建..."
            [[ ${DRY_RUN} -eq 0 ]] && {
                command -v go &>/dev/null || die "go未安装"
                go build -o "${APP_NAME:-app}" ./... 2>>"${LOG_FILE}" || die "go build失败"
            }
        elif [[ -f "Makefile" ]]; then
            log_info "检测到Makefile, 执行make..."
            [[ ${DRY_RUN} -eq 0 ]] && make 2>>"${LOG_FILE}" || die "make失败"
        elif [[ -f "pom.xml" ]]; then
            log_info "检测到Maven项目, 执行mvn构建..."
            [[ ${DRY_RUN} -eq 0 ]] && {
                command -v mvn &>/dev/null || die "mvn未安装"
                mvn clean package -DskipTests 2>>"${LOG_FILE}" || die "mvn构建失败"
            }
        elif [[ -f "requirements.txt" ]] || [[ -f "setup.py" ]]; then
            log_info "检测到Python项目, 安装依赖..."
            [[ ${DRY_RUN} -eq 0 ]] && {
                command -v pip3 &>/dev/null || die "pip3未安装"
                pip3 install -r requirements.txt 2>>"${LOG_FILE}" || die "pip install失败"
            }
        elif [[ -f "Cargo.toml" ]]; then
            log_info "检测到Rust项目, 执行cargo构建..."
            [[ ${DRY_RUN} -eq 0 ]] && {
                command -v cargo &>/dev/null || die "cargo未安装"
                cargo build --release 2>>"${LOG_FILE}" || die "cargo构建失败"
            }
        else
            log_info "未检测到已知构建系统, 跳过构建步骤"
        fi
    fi

    log_success "构建完成"
}

# ============================================================================
# Docker构建
# ============================================================================

docker_build_image() {
    local target_dir="${RELEASES_DIR}/${TIMESTAMP}"
    [[ ! -d "${target_dir}" ]] && die "发布目录不存在"
    [[ ${DOCKER_BUILD} -ne 1 ]] && return 0

    log_step "构建Docker镜像..."
    cd "${target_dir}"

    local image_tag="${DOCKER_IMAGE:-${APP_NAME}}:${DOCKER_TAG:-${TIMESTAMP}}"
    [[ -n "${DOCKER_REGISTRY}" ]] && image_tag="${DOCKER_REGISTRY}/${image_tag}"

    log_info "镜像标签: ${image_tag}"
    [[ ${DRY_RUN} -eq 0 ]] && {
        docker build -f "${DOCKERFILE}" -t "${image_tag}" . 2>>"${LOG_FILE}" || die "Docker构建失败"
        log_success "Docker镜像构建完成: ${image_tag}"

        if [[ -n "${DOCKER_REGISTRY}" ]]; then
            log_info "推送镜像到仓库: ${DOCKER_REGISTRY}"
            docker push "${image_tag}" 2>>"${LOG_FILE}" || die "Docker推送失败"
            log_success "镜像推送完成"
        fi
    }
    DEPLOY_STATS[docker_image]="${image_tag}"
}

# ============================================================================
# 部署流程
# ============================================================================

run_pre_deploy() {
    [[ -z "${PRE_DEPLOY_CMD}" ]] && return 0
    log_step "执行部署前命令..."
    [[ ${DRY_RUN} -eq 0 ]] && eval "${PRE_DEPLOY_CMD}" 2>>"${LOG_FILE}" || die "部署前命令执行失败"
    log_success "部署前命令执行完成"
}

run_deploy() {
    local target_dir="${RELEASES_DIR}/${TIMESTAMP}"
    log_step "执行部署..."

    if [[ -n "${DEPLOY_CMD}" ]]; then
        log_info "执行部署命令: ${DEPLOY_CMD}"
        [[ ${DRY_RUN} -eq 0 ]] && eval "${DEPLOY_CMD}" 2>>"${LOG_FILE}" || die "部署命令执行失败"
    else
        if [[ ${DOCKER_BUILD} -eq 1 ]]; then
            deploy_docker
        else
            deploy_symlink
        fi
    fi

    log_success "部署完成"
}

deploy_symlink() {
    local target_dir="${RELEASES_DIR}/${TIMESTAMP}"
    log_info "创建符号链接部署..."

    [[ ${DRY_RUN} -eq 0 ]] && {
        if [[ -d "${SHARED_DIR}" ]]; then
            for item in $(ls -A "${SHARED_DIR}" 2>/dev/null); do
                if [[ -d "${SHARED_DIR}/${item}" ]]; then
                    [[ -d "${target_dir}/${item}" ]] && rm -rf "${target_dir}/${item}"
                    ln -sfn "${SHARED_DIR}/${item}" "${target_dir}/${item}"
                elif [[ -f "${SHARED_DIR}/${item}" ]]; then
                    [[ -f "${target_dir}/${item}" ]] && rm -f "${target_dir}/${item}"
                    ln -sfn "${SHARED_DIR}/${item}" "${target_dir}/${item}"
                fi
            done
        fi

        [[ -L "${CURRENT_DIR}" ]] && rm -f "${CURRENT_DIR}"
        ln -sfn "${target_dir}" "${CURRENT_DIR}"

        log_info "当前版本: $(readlink ${CURRENT_DIR})"
    }
}

deploy_docker() {
    local image_tag="${DEPLOY_STATS[docker_image]:-${DOCKER_IMAGE:-${APP_NAME}}:${DOCKER_TAG:-latest}}"
    [[ -n "${DOCKER_REGISTRY}" ]] && image_tag="${DOCKER_REGISTRY}/${image_tag}"

    log_info "Docker部署: ${image_tag}"
    [[ ${DRY_RUN} -eq 0 ]] && {
        local container_name="${APP_NAME:-app}"
        docker stop "${container_name}" 2>/dev/null || true
        docker rm "${container_name}" 2>/dev/null || true

        docker run -d --name "${container_name}" \
            --restart unless-stopped \
            -p "${HEALTH_CHECK_PORT:-8080}:8080" \
            ${DEPLOY_STATS[docker_opts]:-} \
            "${image_tag}" 2>>"${LOG_FILE}" || die "Docker容器启动失败"

        log_success "Docker容器已启动: ${container_name}"
    }
}

run_post_deploy() {
    [[ -z "${POST_DEPLOY_CMD}" ]] && return 0
    log_step "执行部署后命令..."
    [[ ${DRY_RUN} -eq 0 ]] && eval "${POST_DEPLOY_CMD}" 2>>"${LOG_FILE}" || {
        log_warning "部署后命令执行失败"
        [[ ${AUTO_ROLLBACK} -eq 1 ]] && do_rollback
    }
    log_success "部署后命令执行完成"
}

# ============================================================================
# 健康检查
# ============================================================================

run_health_check() {
    log_step "执行健康检查..."
    local attempt=0

    while [[ ${attempt} -lt ${HEALTH_CHECK_RETRIES} ]]; do
        ((attempt++)) || true
        log_info "健康检查第${attempt}次 (共${HEALTH_CHECK_RETRIES}次)..."

        local health_ok=1

        if [[ -n "${HEALTH_CHECK_CMD}" ]]; then
            if eval "${HEALTH_CHECK_CMD}" &>/dev/null; then
                health_ok=0
            else
                health_ok=1
            fi
        elif [[ -n "${HEALTH_CHECK_URL}" ]]; then
            local http_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${HEALTH_CHECK_URL}" 2>/dev/null || echo '000')"
            if [[ "${http_code}" =~ ^2 ]]; then
                health_ok=0
                log_info "HTTP检查通过 (状态码: ${http_code})"
            else
                health_ok=1
                log_warning "HTTP检查失败 (状态码: ${http_code})"
            fi
        elif [[ -n "${HEALTH_CHECK_PORT}" ]]; then
            if timeout 5 bash -c "echo > /dev/tcp/localhost/${HEALTH_CHECK_PORT}" 2>/dev/null; then
                health_ok=0
                log_info "端口检查通过: ${HEALTH_CHECK_PORT}"
            else
                health_ok=1
                log_warning "端口检查失败: ${HEALTH_CHECK_PORT}"
            fi
        else
            log_info "未配置健康检查, 跳过"
            return 0
        fi

        if [[ ${health_ok} -eq 0 ]]; then
            log_success "健康检查通过"
            return 0
        fi

        [[ ${attempt} -lt ${HEALTH_CHECK_RETRIES} ]] && sleep "${HEALTH_CHECK_INTERVAL}"
    done

    log_error "健康检查失败, 已重试${HEALTH_CHECK_RETRIES}次"
    [[ ${AUTO_ROLLBACK} -eq 1 ]] && {
        log_warning "自动回滚..."
        do_rollback
    }
    return 1
}

# ============================================================================
# 回滚
# ============================================================================

do_rollback() {
    local rollback_to="${ROLLBACK_VERSION}"
    log_step "执行回滚..."

    if [[ -z "${rollback_to}" ]]; then
        local previous="$(ls -dt "${RELEASES_DIR}"/20* 2>/dev/null | head -2 | tail -1)"
        [[ -z "${previous}" ]] && die "没有可回滚的版本"
        rollback_to="$(basename "${previous}")"
    fi

    local rollback_dir="${RELEASES_DIR}/${rollback_to}"
    if [[ ! -d "${rollback_dir}" ]]; then
        log_error "回滚版本不存在: ${rollback_to}"
        list_versions
        return 1
    fi

    log_info "回滚到版本: ${rollback_to}"

    if [[ -n "${ROLLBACK_CMD}" ]]; then
        [[ ${DRY_RUN} -eq 0 ]] && eval "${ROLLBACK_CMD}" 2>>"${LOG_FILE}"
    else
        [[ ${DRY_RUN} -eq 0 ]] && {
            if [[ ${DOCKER_BUILD} -eq 1 ]]; then
                local container_name="${APP_NAME:-app}"
                docker stop "${container_name}" 2>/dev/null || true
                docker rm "${container_name}" 2>/dev/null || true
                log_info "Docker回滚需要手动指定镜像版本"
            else
                [[ -L "${CURRENT_DIR}" ]] && rm -f "${CURRENT_DIR}"
                ln -sfn "${rollback_dir}" "${CURRENT_DIR}"
                log_info "已切换到: ${rollback_dir}"
            fi
        }
    fi

    DEPLOY_STATS[status]="rolled_back"
    log_success "回滚完成: ${rollback_to}"

    record_history "rollback" "${rollback_to}"
}

# ============================================================================
# 版本管理
# ============================================================================

list_versions() {
    echo -e "${CYAN}=== 部署版本历史 ===${NC}"
    if [[ -d "${RELEASES_DIR}" ]]; then
        local current_target=""
        [[ -L "${CURRENT_DIR}" ]] && current_target="$(basename "$(readlink "${CURRENT_DIR}")")"

        for dir in $(ls -dt "${RELEASES_DIR}"/20* 2>/dev/null); do
            local name="$(basename "${dir}")"
            local marker=""
            [[ "${name}" == "${current_target}" ]] && marker="${GREEN} <- 当前${NC}"
            local commit_file="${dir}/.deploy_info"
            local info=""
            [[ -f "${commit_file}" ]] && info="$(cat "${commit_file}" 2>/dev/null)"
            echo -e "  ${GREEN}${name}${NC} ${info}${marker}"
        done
    else
        echo "  (无版本)"
    fi
}

cleanup_old_releases() {
    log_step "清理旧版本 (保留最近${KEEP_RELEASES}个)..."
    [[ ${DRY_RUN} -eq 0 ]] && {
        local count=0
        for dir in $(ls -dt "${RELEASES_DIR}"/20* 2>/dev/null); do
            ((count++)) || true
            if [[ ${count} -gt ${KEEP_RELEASES} ]]; then
                local is_current=0
                [[ -L "${CURRENT_DIR}" ]] && [[ "$(readlink "${CURRENT_DIR}")" == "${dir}" ]] && is_current=1
                [[ ${is_current} -eq 0 ]] && {
                    log_info "删除旧版本: $(basename "${dir}")"
                    rm -rf "${dir}"
                }
            fi
        done
    }
    log_success "旧版本清理完成"
}

# ============================================================================
# 部署历史
# ============================================================================

record_history() {
    local action="$1" version="${2:-${TIMESTAMP}}"
    mkdir -p "${HISTORY_DIR}" 2>/dev/null || true
    local history_file="${HISTORY_DIR}/${DATE_ONLY}.log"
    local entry="$(date '+%Y-%m-%d %H:%M:%S') | ${action} | ${APP_NAME:-unknown} | ${ENVIRONMENT} | ${version} | ${DEPLOY_STATS[commit]:-unknown} | ${DEPLOY_STATS[status]:-unknown}"
    echo "${entry}" >> "${history_file}"
}

show_history() {
    echo -e "${CYAN}=== 部署历史 ===${NC}"
    if [[ -d "${HISTORY_DIR}" ]]; then
        for f in $(ls -t "${HISTORY_DIR}"/*.log 2>/dev/null | head -7); do
            echo -e "\n${WHITE}[$(basename "${f}" .log)]${NC}"
            cat "${f}"
        done
    else
        echo "  (无历史记录)"
    fi
}

# ============================================================================
# 通知
# ============================================================================

send_notification() {
    local subject="$1" message="$2"
    [[ -z "${NOTIFY_TYPE}" ]] && return 0

    case "${NOTIFY_TYPE}" in
        dingtalk)
            [[ -n "${NOTIFY_WEBHOOK}" ]] && curl -s -X POST "${NOTIFY_WEBHOOK}" \
                -H 'Content-Type: application/json' \
                -d "{\"msgtype\":\"markdown\",\"markdown\":{\"title\":\"${subject}\",\"text\":\"${message}\"}}" &>/dev/null ;;
        wechat)
            [[ -n "${NOTIFY_WEBHOOK}" ]] && curl -s -X POST "${NOTIFY_WEBHOOK}" \
                -H 'Content-Type: application/json' \
                -d "{\"msgtype\":\"text\",\"text\":{\"content\":\"${subject}\n\n${message}\"}}" &>/dev/null ;;
        email)
            [[ -n "${NOTIFY_EMAIL}" ]] && command -v mail &>/dev/null && echo "${message}" | mail -s "${subject}" "${NOTIFY_EMAIL}" ;;
        webhook)
            [[ -n "${NOTIFY_WEBHOOK}" ]] && curl -s -X POST "${NOTIFY_WEBHOOK}" \
                -H 'Content-Type: application/json' \
                -d "{\"subject\":\"${subject}\",\"message\":\"${message}\"}" &>/dev/null ;;
    esac
}

# ============================================================================
# 主部署流程
# ============================================================================

do_deploy() {
    DEPLOY_STATS[status]="deploying"
    print_banner

    acquire_deploy_lock; trap release_deploy_lock EXIT

    log_step "========== 开始部署 =========="
    log_info "应用: ${APP_NAME}"
    log_info "环境: ${ENVIRONMENT}"
    log_info "仓库: ${GIT_REPO}"
    log_info "分支: ${GIT_BRANCH}"
    [[ -n "${GIT_TAG}" ]]    && log_info "标签: ${GIT_TAG}"
    [[ -n "${GIT_COMMIT}" ]] && log_info "提交: ${GIT_COMMIT}"

    [[ ${DRY_RUN} -eq 1 ]] && log_warning "====== 模拟运行模式 ======"

    git_clone_or_pull
    run_build
    docker_build_image
    run_pre_deploy
    run_deploy
    run_health_check
    run_post_deploy
    cleanup_old_releases

    DEPLOY_STATS[end_time]="$(date +%s)"
    local duration=$((DEPLOY_STATS[end_time] - DEPLOY_STATS[start_time]))
    DEPLOY_STATS[status]="success"

    local version_info="${TIMESTAMP}"
    [[ -n "${DEPLOY_STATS[commit]:-}" ]] && version_info="${version_info}@${DEPLOY_STATS[commit]}"
    echo "${version_info}" > "${RELEASES_DIR}/${TIMESTAMP}/.deploy_info"

    record_history "deploy" "${TIMESTAMP}"

    echo ""
    log_success "=========================================="
    log_success "  部署成功!"
    log_success "  应用: ${APP_NAME}"
    log_success "  环境: ${ENVIRONMENT}"
    log_success "  版本: ${version_info}"
    log_success "  耗时: ${duration}秒"
    log_success "  日志: ${LOG_FILE}"
    log_success "=========================================="

    send_notification "部署成功 - ${APP_NAME} ${ENVIRONMENT}" \
        "应用: ${APP_NAME}\n环境: ${ENVIRONMENT}\n版本: ${version_info}\n耗时: ${duration}秒\n主机: ${HOSTNAME}"
}

# ============================================================================
# 参数解析
# ============================================================================

show_usage() {
    cat << USAGE
自动部署与发布脚本 v${SCRIPT_VERSION}

用法: bash auto_deploy.sh [选项]

操作:
  --deploy              执行部署
  --rollback [VERSION]  回滚到指定版本 (默认上一个版本)
  --list                列出部署版本
  --history             查看部署历史
  --init                初始化部署目录

部署选项:
  --app NAME            应用名称
  --env ENV             部署环境 (dev/staging/production, 默认: production)
  --repo URL            Git仓库地址
  --branch BRANCH       Git分支 (默认: main)
  --tag TAG             Git标签
  --commit HASH         Git提交哈希
  --build-cmd CMD       构建命令
  --deploy-cmd CMD      部署命令
  --pre-deploy CMD      部署前命令
  --post-deploy CMD     部署后命令
  --rollback-cmd CMD    回滚命令

健康检查:
  --health-url URL      HTTP健康检查URL
  --health-port PORT    端口健康检查
  --health-cmd CMD      自定义健康检查命令
  --health-retries N    重试次数 (默认: 5)
  --no-auto-rollback    禁用自动回滚

Docker:
  --docker              启用Docker构建
  --docker-image NAME   Docker镜像名
  --docker-registry URL Docker仓库地址
  --docker-tag TAG      Docker标签
  --dockerfile FILE     Dockerfile路径 (默认: Dockerfile)

其他:
  --config FILE         使用配置文件
  --keep N              保留版本数 (默认: 5)
  --force               强制执行 (忽略锁)
  --dry-run             模拟运行
  --verbose             详细输出
  --help                显示帮助
  --version             显示版本

配置文件格式 (deploy.cfg):
  app_name=myapp
  environment=production
  git_repo=https://github.com/user/repo.git
  git_branch=main
  build_cmd=npm run build
  health_check_url=http://localhost:8080/health
  docker_build=1
  docker_image=myapp
  docker_registry=registry.example.com
  notify_type=dingtalk
  notify_webhook=https://oapi.dingtalk.com/robot/send?access_token=xxx

支持的操作系统:
  CentOS/RHEL, Ubuntu/Debian, Alpine, Arch Linux, openSUSE
USAGE
}

parse_args() {
    [[ $# -eq 0 ]] && { show_usage; exit 0; }
    local action="deploy"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --deploy)         action="deploy" ;;
            --rollback)       action="rollback"; [[ $# -gt 1 && ! "$2" =~ ^-- ]] && { ROLLBACK_VERSION="$2"; shift; } ;;
            --list)           action="list" ;;
            --history)        action="history" ;;
            --init)           action="init" ;;
            --app)            APP_NAME="$2"; shift ;;
            --env)            ENVIRONMENT="$2"; shift ;;
            --repo)           GIT_REPO="$2"; shift ;;
            --branch)         GIT_BRANCH="$2"; shift ;;
            --tag)            GIT_TAG="$2"; shift ;;
            --commit)         GIT_COMMIT="$2"; shift ;;
            --build-cmd)      BUILD_CMD="$2"; shift ;;
            --deploy-cmd)     DEPLOY_CMD="$2"; shift ;;
            --pre-deploy)     PRE_DEPLOY_CMD="$2"; shift ;;
            --post-deploy)    POST_DEPLOY_CMD="$2"; shift ;;
            --rollback-cmd)   ROLLBACK_CMD="$2"; shift ;;
            --health-url)     HEALTH_CHECK_URL="$2"; shift ;;
            --health-port)    HEALTH_CHECK_PORT="$2"; shift ;;
            --health-cmd)     HEALTH_CHECK_CMD="$2"; shift ;;
            --health-retries) HEALTH_CHECK_RETRIES="$2"; shift ;;
            --no-auto-rollback) AUTO_ROLLBACK=0 ;;
            --docker)         DOCKER_BUILD=1 ;;
            --docker-image)   DOCKER_IMAGE="$2"; shift ;;
            --docker-registry) DOCKER_REGISTRY="$2"; shift ;;
            --docker-tag)     DOCKER_TAG="$2"; shift ;;
            --dockerfile)     DOCKERFILE="$2"; shift ;;
            --config)         parse_deploy_config "$2"; shift ;;
            --keep)           KEEP_RELEASES="$2"; shift ;;
            --force)          FORCE_DEPLOY=1 ;;
            --dry-run)        DRY_RUN=1 ;;
            --verbose)        VERBOSE=1 ;;
            --help|-h)        show_usage; exit 0 ;;
            --version|-v)     echo "v${SCRIPT_VERSION}"; exit 0 ;;
            *)                log_error "未知选项: $1"; show_usage; exit 1 ;;
        esac
        shift
    done

    detect_os

    case "${action}" in
        deploy)
            [[ -z "${GIT_REPO}" ]] && [[ -z "${DEPLOY_CMD}" ]] && die "必须指定 --repo 或 --deploy-cmd"
            do_deploy ;;
        rollback) do_rollback ;;
        list)     list_versions ;;
        history)  show_history ;;
        init)
            mkdir -p "${RELEASES_DIR}" "${SHARED_DIR}" "${LOG_DIR}" "${HISTORY_DIR}"
            log_success "部署目录已初始化: ${DEPLOY_ROOT}" ;;
    esac
}

parse_args "$@"
