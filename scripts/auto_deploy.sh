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
# 灰度发布/金丝雀部署模块
# ============================================================================

canary_deploy() {
    log_step "执行金丝雀部署..."
    local canary_weight="${1:-10}"
    local canary_image="${DEPLOY_STATS[docker_image]:-${DOCKER_IMAGE:-${APP_NAME}}:${DOCKER_TAG:-latest}}"
    [[ -n "${DOCKER_REGISTRY}" ]] && canary_image="${DOCKER_REGISTRY}/${canary_image}"

    log_info "金丝雀权重: ${canary_weight}%"
    log_info "金丝雀镜像: ${canary_image}"

    local container_name="${APP_NAME:-app}-canary"
    local main_container="${APP_NAME:-app}"

    [[ ${DRY_RUN} -eq 0 ]] && {
        local main_port="${HEALTH_CHECK_PORT:-8080}"
        local canary_port=$((main_port + 1))

        docker run -d --name "${container_name}" \
            --restart unless-stopped \
            -p "${canary_port}:${main_port}" \
            -e "CANARY=true" \
            -e "CANARY_WEIGHT=${canary_weight}" \
            --label "deploy.type=canary" \
            --label "deploy.version=${TIMESTAMP}" \
            --label "deploy.weight=${canary_weight}" \
            "${canary_image}" 2>>"${LOG_FILE}" || die "金丝雀容器启动失败"

        log_success "金丝雀容器已启动: ${container_name} (端口: ${canary_port})"
        log_info "请配置负载均衡器将${canary_weight}%流量转发到端口${canary_port}"
    }

    DEPLOY_STATS[canary_container]="${container_name}"
    DEPLOY_STATS[canary_weight]="${canary_weight}"
    record_history "canary_deploy" "${TIMESTAMP}"
}

canary_promote() {
    log_step "提升金丝雀为正式版本..."
    local canary_container="${APP_NAME:-app}-canary"
    local main_container="${APP_NAME:-app}"

    [[ ${DRY_RUN} -eq 0 ]] && {
        docker stop "${canary_container}" 2>/dev/null || true
        docker rm "${canary_container}" 2>/dev/null || true

        docker stop "${main_container}" 2>/dev/null || true
        docker rm "${main_container}" 2>/dev/null || true

        local image="${DEPLOY_STATS[docker_image]:-${DOCKER_IMAGE:-${APP_NAME}}:${DOCKER_TAG:-latest}}"
        [[ -n "${DOCKER_REGISTRY}" ]] && image="${DOCKER_REGISTRY}/${image}"

        docker run -d --name "${main_container}" \
            --restart unless-stopped \
            -p "${HEALTH_CHECK_PORT:-8080}:8080" \
            --label "deploy.type=production" \
            --label "deploy.version=${TIMESTAMP}" \
            "${image}" 2>>"${LOG_FILE}" || die "正式容器启动失败"

        log_success "金丝雀已提升为正式版本"
    }
    record_history "canary_promote" "${TIMESTAMP}"
}

canary_rollback() {
    log_step "回滚金丝雀部署..."
    local canary_container="${APP_NAME:-app}-canary"

    [[ ${DRY_RUN} -eq 0 ]] && {
        docker stop "${canary_container}" 2>/dev/null || true
        docker rm "${canary_container}" 2>/dev/null || true
        log_success "金丝雀容器已移除, 流量恢复到正式版本"
    }
    record_history "canary_rollback" "${TIMESTAMP}"
}

# ============================================================================
# 蓝绿部署模块
# ============================================================================

blue_green_deploy() {
    log_step "执行蓝绿部署..."
    local current_env=""
    local deploy_env=""

    if docker ps --format '{{.Names}}' | grep -q "${APP_NAME:-app}-blue"; then
        current_env="blue"
        deploy_env="green"
    else
        current_env="green"
        deploy_env="blue"
    fi

    log_info "当前环境: ${current_env}, 部署目标: ${deploy_env}"

    local image="${DEPLOY_STATS[docker_image]:-${DOCKER_IMAGE:-${APP_NAME}}:${DOCKER_TAG:-latest}}"
    [[ -n "${DOCKER_REGISTRY}" ]] && image="${DOCKER_REGISTRY}/${image}"

    local deploy_container="${APP_NAME:-app}-${deploy_env}"
    local main_port="${HEALTH_CHECK_PORT:-8080}"
    local deploy_port=$((main_port + 1))

    [[ ${DRY_RUN} -eq 0 ]] && {
        docker run -d --name "${deploy_container}" \
            --restart unless-stopped \
            -p "${deploy_port}:${main_port}" \
            --label "deploy.type=blue_green" \
            --label "deploy.env=${deploy_env}" \
            --label "deploy.version=${TIMESTAMP}" \
            "${image}" 2>>"${LOG_FILE}" || die "蓝绿部署: ${deploy_env}容器启动失败"

        log_success "${deploy_env}环境已启动 (端口: ${deploy_port})"

        local health_url="http://localhost:${deploy_port}/health"
        local health_ok=0
        for i in $(seq 1 ${HEALTH_CHECK_RETRIES}); do
            local code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${health_url}" 2>/dev/null || echo '000')"
            if [[ "${code}" =~ ^2 ]]; then
                health_ok=1; break
            fi
            sleep "${HEALTH_CHECK_INTERVAL}"
        done

        if [[ ${health_ok} -eq 1 ]]; then
            log_info "切换流量到${deploy_env}环境..."
            local current_container="${APP_NAME:-app}-${current_env}"
            docker stop "${current_container}" 2>/dev/null || true
            docker rm "${current_container}" 2>/dev/null || true

            docker stop "${deploy_container}" 2>/dev/null || true
            docker rm "${deploy_container}" 2>/dev/null || true

            docker run -d --name "${APP_NAME:-app}" \
                --restart unless-stopped \
                -p "${main_port}:${main_port}" \
                --label "deploy.type=production" \
                --label "deploy.env=${deploy_env}" \
                --label "deploy.version=${TIMESTAMP}" \
                "${image}" 2>>"${LOG_FILE}" || die "流量切换失败"

            log_success "蓝绿部署完成, 当前环境: ${deploy_env}"
        else
            log_error "${deploy_env}环境健康检查失败, 保持${current_env}环境"
            docker stop "${deploy_container}" 2>/dev/null || true
            docker rm "${deploy_container}" 2>/dev/null || true
            return 1
        fi
    }

    DEPLOY_STATS[blue_green_env]="${deploy_env}"
    record_history "blue_green_deploy" "${TIMESTAMP}"
}

# ============================================================================
# 滚动部署模块
# ============================================================================

rolling_deploy() {
    log_step "执行滚动部署..."
    local replicas="${1:-3}"
    local image="${DEPLOY_STATS[docker_image]:-${DOCKER_IMAGE:-${APP_NAME}}:${DOCKER_TAG:-latest}}"
    [[ -n "${DOCKER_REGISTRY}" ]] && image="${DOCKER_REGISTRY}/${image}"

    log_info "目标副本数: ${replicas}"

    [[ ${DRY_RUN} -eq 0 ]] && {
        local base_name="${APP_NAME:-app}"
        local main_port="${HEALTH_CHECK_PORT:-8080}"

        for i in $(seq 1 ${replicas}); do
            local container_name="${base_name}-${i}"
            local port=$((main_port + i - 1))

            log_info "更新副本 ${i}/${replicas}: ${container_name}"
            docker stop "${container_name}" 2>/dev/null || true
            docker rm "${container_name}" 2>/dev/null || true

            docker run -d --name "${container_name}" \
                --restart unless-stopped \
                -p "${port}:${main_port}" \
                --label "deploy.type=rolling" \
                --label "deploy.replica=${i}" \
                --label "deploy.version=${TIMESTAMP}" \
                "${image}" 2>>"${LOG_FILE}" || {
                log_error "副本${i}启动失败, 回滚已更新副本"
                for j in $(seq 1 $((i-1))); do
                    docker stop "${base_name}-${j}" 2>/dev/null || true
                    docker rm "${base_name}-${j}" 2>/dev/null || true
                done
                die "滚动部署失败"
            }

            local replica_ok=0
            for attempt in $(seq 1 ${HEALTH_CHECK_RETRIES}); do
                local health_url="http://localhost:${port}/health"
                local code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${health_url}" 2>/dev/null || echo '000')"
                if [[ "${code}" =~ ^2 ]]; then
                    replica_ok=1; break
                fi
                sleep "${HEALTH_CHECK_INTERVAL}"
            done

            if [[ ${replica_ok} -ne 1 ]]; then
                log_error "副本${i}健康检查失败"
                docker stop "${container_name}" 2>/dev/null || true
                docker rm "${container_name}" 2>/dev/null || true
                die "滚动部署中止: 副本${i}不健康"
            fi

            log_success "副本${i}更新完成并健康"
            [[ ${i} -lt ${replicas} ]] && sleep 5
        done

        log_success "滚动部署完成: ${replicas}个副本"
    }

    DEPLOY_STATS[rolling_replicas]="${replicas}"
    record_history "rolling_deploy" "${TIMESTAMP}"
}

# ============================================================================
# 多阶段Docker构建
# ============================================================================

docker_multi_stage_build() {
    local target_dir="${RELEASES_DIR}/${TIMESTAMP}"
    [[ ! -d "${target_dir}" ]] && die "发布目录不存在"
    [[ ${DOCKER_BUILD} -ne 1 ]] && return 0

    log_step "执行多阶段Docker构建..."
    cd "${target_dir}"

    local stages=()
    if [[ -f "${DOCKERFILE}" ]]; then
        while IFS= read -r line; do
            if [[ "${line}" =~ ^FROM\ .*AS\ (.+)$ ]]; then
                stages+=("${BASH_REMATCH[1]}")
            fi
        done < "${DOCKERFILE}"
    fi

    if [[ ${#stages[@]} -gt 1 ]]; then
        log_info "检测到多阶段构建: ${stages[*]}"
        for stage in "${stages[@]}"; do
            log_info "构建阶段: ${stage}"
            local stage_tag="${DOCKER_IMAGE:-${APP_NAME}}:${DOCKER_TAG:-${TIMESTAMP}}-${stage}"
            [[ -n "${DOCKER_REGISTRY}" ]] && stage_tag="${DOCKER_REGISTRY}/${stage_tag}"
            [[ ${DRY_RUN} -eq 0 ]] && {
                docker build -f "${DOCKERFILE}" --target "${stage}" -t "${stage_tag}" . 2>>"${LOG_FILE}" \
                    || log_warning "阶段${stage}构建失败"
            }
        done
    fi

    local image_tag="${DOCKER_IMAGE:-${APP_NAME}}:${DOCKER_TAG:-${TIMESTAMP}}"
    [[ -n "${DOCKER_REGISTRY}" ]] && image_tag="${DOCKER_REGISTRY}/${image_tag}"

    log_info "构建最终镜像: ${image_tag}"
    [[ ${DRY_RUN} -eq 0 ]] && {
        docker build -f "${DOCKERFILE}" -t "${image_tag}" \
            --build-arg BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
            --build-arg VCS_REF="${DEPLOY_STATS[commit]:-unknown}" \
            --build-arg VERSION="${TIMESTAMP}" \
            . 2>>"${LOG_FILE}" || die "Docker构建失败"
        log_success "Docker镜像构建完成: ${image_tag}"
    }
    DEPLOY_STATS[docker_image]="${image_tag}"
}

# ============================================================================
# Docker镜像缓存管理
# ============================================================================

docker_cache_manage() {
    log_step "管理Docker构建缓存..."
    local action="${1:-clean}"

    case "${action}" in
        clean)
            log_info "清理Docker构建缓存..."
            [[ ${DRY_RUN} -eq 0 ]] && {
                docker builder prune -f --filter "until=168h" 2>>"${LOG_FILE}" || true
                log_success "构建缓存已清理"
            }
            ;;
        stats)
            log_info "Docker磁盘使用:"
            [[ ${DRY_RUN} -eq 0 ]] && docker system df 2>/dev/null || true
            ;;
        *)
            log_warning "未知缓存操作: ${action}"
            ;;
    esac
}

# ============================================================================
# 环境配置管理
# ============================================================================

manage_env_config() {
    log_step "管理环境配置..."
    local env="${ENVIRONMENT}"
    local config_dir="${SHARED_DIR}/config"

    mkdir -p "${config_dir}" 2>/dev/null || true

    local env_file="${config_dir}/${env}.env"
    if [[ -f "${env_file}" ]]; then
        log_info "加载环境配置: ${env_file}"
        while IFS='=' read -r key value; do
            key="$(echo "${key}" | xargs)"; value="$(echo "${value}" | xargs)"
            [[ -z "${key}" ]] || [[ "${key}" =~ ^# ]] && continue
            export "${key}=${value}"
            log_info "  ${key}=***"
        done < "${env_file}"
    else
        log_info "未找到环境配置文件: ${env_file}"
        log_info "创建示例配置..."
        cat > "${env_file}" << ENVSAMPLE
# ${env} 环境配置
# 生成时间: $(date)
APP_ENV=${env}
APP_PORT=8080
APP_DEBUG=false
LOG_LEVEL=info
DATABASE_URL=
REDIS_URL=
SECRET_KEY=
ENVSAMPLE
        log_success "示例配置已创建: ${env_file}"
    fi

    local secret_file="${config_dir}/${env}.secrets"
    if [[ -f "${secret_file}" ]]; then
        log_info "加载密钥配置: ${secret_file}"
        chmod 600 "${secret_file}" 2>/dev/null || true
        while IFS='=' read -r key value; do
            key="$(echo "${key}" | xargs)"; value="$(echo "${value}" | xargs)"
            [[ -z "${key}" ]] || [[ "${key}" =~ ^# ]] && continue
            export "${key}=${value}"
        done < "${secret_file}"
    fi
}

# ============================================================================
# 部署审批流程
# ============================================================================

request_deploy_approval() {
    local env="${ENVIRONMENT}"
    [[ "${env}" != "production" ]] && return 0

    log_step "生产环境部署审批..."
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}  生产环境部署审批${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo -e "  应用: ${APP_NAME}"
    echo -e "  版本: ${TIMESTAMP}"
    echo -e "  提交: ${DEPLOY_STATS[commit]:-unknown}"
    echo -e "  分支: ${DEPLOY_STATS[branch]:-unknown}"
    echo -e "${YELLOW}========================================${NC}"
    echo -ne "${YELLOW}确认部署到生产环境? [yes/NO]: ${NC}"
    read -r confirm
    [[ "${confirm}" != "yes" ]] && die "部署已取消"

    if [[ -n "${NOTIFY_WEBHOOK}" ]]; then
        send_notification "部署审批 - ${APP_NAME}" "生产环境部署已审批\n应用: ${APP_NAME}\n版本: ${TIMESTAMP}\n审批人: $(whoami)"
    fi

    log_success "部署已审批"
}

# ============================================================================
# 部署前检查
# ============================================================================

pre_deploy_check() {
    log_step "执行部署前检查..."
    local checks_passed=0
    local checks_failed=0

    log_info "检查必要工具..."
    for tool in git curl; do
        if command -v "${tool}" &>/dev/null; then
            ((checks_passed++)) || true
            log_info "  [OK] ${tool}"
        else
            ((checks_failed++)) || true
            log_error "  [FAIL] ${tool} 未安装"
        fi
    done

    log_info "检查磁盘空间..."
    local available="$(df -BG "${DEPLOY_ROOT}" 2>/dev/null | awk 'NR==2{print $4}' | tr -d 'G')"
    if [[ -n "${available}" ]] && [[ ${available} -lt 1 ]]; then
        ((checks_failed++)) || true
        log_error "  [FAIL] 磁盘空间不足: ${available}GB"
    else
        ((checks_passed++)) || true
        log_info "  [OK] 可用空间: ${available}GB"
    fi

    log_info "检查内存..."
    local mem_available="$(free -m 2>/dev/null | awk '/Mem:/{print $7}')"
    if [[ -n "${mem_available}" ]] && [[ ${mem_available} -lt 100 ]]; then
        ((checks_failed++)) || true
        log_error "  [FAIL] 可用内存不足: ${mem_available}MB"
    else
        ((checks_passed++)) || true
        log_info "  [OK] 可用内存: ${mem_available}MB"
    fi

    log_info "检查Docker..."
    if [[ ${DOCKER_BUILD} -eq 1 ]]; then
        if command -v docker &>/dev/null && docker info &>/dev/null; then
            ((checks_passed++)) || true
            log_info "  [OK] Docker可用"
        else
            ((checks_failed++)) || true
            log_error "  [FAIL] Docker不可用"
        fi
    fi

    log_info "检查Git仓库连通性..."
    if [[ -n "${GIT_REPO}" ]]; then
        if git ls-remote "${GIT_REPO}" &>/dev/null; then
            ((checks_passed++)) || true
            log_info "  [OK] Git仓库可达"
        else
            ((checks_failed++)) || true
            log_error "  [FAIL] Git仓库不可达"
        fi
    fi

    log_info "检查端口占用..."
    if [[ -n "${HEALTH_CHECK_PORT}" ]]; then
        if ! ss -tlnp 2>/dev/null | grep -q ":${HEALTH_CHECK_PORT} "; then
            ((checks_passed++)) || true
            log_info "  [OK] 端口${HEALTH_CHECK_PORT}可用"
        else
            log_info "  [WARN] 端口${HEALTH_CHECK_PORT}已被占用 (可能为当前版本)"
            ((checks_passed++)) || true
        fi
    fi

    log_info "检查配置文件..."
    local target_dir="${RELEASES_DIR}/${TIMESTAMP}"
    if [[ -d "${target_dir}" ]]; then
        local required_files=(".env" "config.yaml" "config.json")
        for f in "${required_files[@]}"; do
            if [[ -f "${target_dir}/${f}" ]]; then
                ((checks_passed++)) || true
                log_info "  [OK] ${f}"
            fi
        done
    fi

    echo ""
    log_info "部署前检查: ${checks_passed}通过, ${checks_failed}失败"

    if [[ ${checks_failed} -gt 0 ]]; then
        log_error "部署前检查未通过, 请修复后重试"
        return 1
    fi

    log_success "部署前检查全部通过"
    return 0
}

# ============================================================================
# 部署后验证
# ============================================================================

post_deploy_verify() {
    log_step "执行部署后验证..."
    local target_dir="${RELEASES_DIR}/${TIMESTAMP}"

    log_info "验证文件完整性..."
    if [[ -d "${target_dir}" ]]; then
        local file_count="$(find "${target_dir}" -type f | wc -l)"
        local total_size="$(du -sh "${target_dir}" 2>/dev/null | cut -f1)"
        log_info "  文件数: ${file_count}, 大小: ${total_size}"
    fi

    log_info "验证符号链接..."
    if [[ -L "${CURRENT_DIR}" ]]; then
        local link_target="$(readlink "${CURRENT_DIR}")"
        if [[ "${link_target}" == "${target_dir}" ]]; then
            log_info "  [OK] current -> ${link_target}"
        else
            log_error "  [FAIL] current -> ${link_target} (期望: ${target_dir})"
        fi
    fi

    log_info "验证进程状态..."
    if [[ -n "${APP_NAME}" ]]; then
        local pids="$(pgrep -f "${APP_NAME}" 2>/dev/null || true)"
        if [[ -n "${pids}" ]]; then
            log_info "  [OK] 进程运行中: ${pids}"
        else
            log_warning "  [WARN] 未检测到应用进程"
        fi
    fi

    log_info "验证端口监听..."
    if [[ -n "${HEALTH_CHECK_PORT}" ]]; then
        if ss -tlnp 2>/dev/null | grep -q ":${HEALTH_CHECK_PORT} "; then
            log_info "  [OK] 端口${HEALTH_CHECK_PORT}正在监听"
        else
            log_warning "  [WARN] 端口${HEALTH_CHECK_PORT}未监听"
        fi
    fi

    log_info "验证日志输出..."
    local app_log="${LOG_DIR}/${APP_NAME}.log"
    if [[ -f "${app_log}" ]]; then
        local errors="$(grep -ci "error\|exception\|fatal" "${app_log}" 2>/dev/null || echo 0)"
        if [[ ${errors} -gt 0 ]]; then
            log_warning "  [WARN] 日志中发现${errors}个错误"
        else
            log_info "  [OK] 日志无错误"
        fi
    fi

    log_success "部署后验证完成"
}

# ============================================================================
# 部署报告生成
# ============================================================================

generate_deploy_report() {
    log_step "生成部署报告..."
    local report_file="${LOG_DIR}/report_${TIMESTAMP}.html"
    local duration=0
    [[ -n "${DEPLOY_STATS[end_time]:-}" ]] && duration=$((DEPLOY_STATS[end_time] - DEPLOY_STATS[start_time]))

    cat > "${report_file}" << REPORT
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <title>部署报告 - ${APP_NAME} ${TIMESTAMP}</title>
    <style>
        body { font-family: 'Segoe UI', sans-serif; margin: 20px; background: #f5f5f5; }
        .container { max-width: 900px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #333; border-bottom: 2px solid #4CAF50; padding-bottom: 10px; }
        h2 { color: #555; margin-top: 25px; }
        .info-grid { display: grid; grid-template-columns: 150px 1fr; gap: 8px; margin: 15px 0; }
        .info-key { font-weight: bold; color: #666; }
        .info-value { color: #333; }
        .status-success { color: #4CAF50; font-weight: bold; }
        .status-failed { color: #f44336; font-weight: bold; }
        .status-rolled_back { color: #FF9800; font-weight: bold; }
        table { width: 100%; border-collapse: collapse; margin: 15px 0; }
        th, td { padding: 10px; text-align: left; border-bottom: 1px solid #ddd; }
        th { background: #f5f5f5; font-weight: bold; }
        .footer { margin-top: 30px; padding-top: 15px; border-top: 1px solid #eee; color: #999; font-size: 12px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>部署报告</h1>
        <div class="info-grid">
            <span class="info-key">应用名称:</span><span class="info-value">${APP_NAME:-未知}</span>
            <span class="info-key">部署环境:</span><span class="info-value">${ENVIRONMENT}</span>
            <span class="info-key">部署版本:</span><span class="info-value">${TIMESTAMP}</span>
            <span class="info-key">Git提交:</span><span class="info-value">${DEPLOY_STATS[commit]:-unknown}</span>
            <span class="info-key">Git分支:</span><span class="info-value">${DEPLOY_STATS[branch]:-unknown}</span>
            <span class="info-key">部署状态:</span><span class="status-${DEPLOY_STATS[status]}">${DEPLOY_STATS[status]}</span>
            <span class="info-key">部署耗时:</span><span class="info-value">${duration}秒</span>
            <span class="info-key">主机名:</span><span class="info-value">${HOSTNAME}</span>
            <span class="info-key">操作人:</span><span class="info-value">$(whoami)</span>
            <span class="info-key">Docker镜像:</span><span class="info-value">${DEPLOY_STATS[docker_image]:-N/A}</span>
        </div>

        <h2>部署历史</h2>
        <table>
            <tr><th>时间</th><th>操作</th><th>版本</th><th>状态</th></tr>
REPORT

    if [[ -d "${HISTORY_DIR}" ]]; then
        tail -20 "${HISTORY_DIR}"/*.log 2>/dev/null | while read -r line; do
            echo "            <tr><td>${line//|/</td><td>}</td></tr>" >> "${report_file}"
        done
    fi

    cat >> "${report_file}" << REPORT_FOOT
        </table>

        <div class="footer">
            <p>报告生成时间: $(date '+%Y-%m-%d %H:%M:%S') | Auto Deploy Script v${SCRIPT_VERSION}</p>
        </div>
    </div>
</body>
</html>
REPORT_FOOT

    log_success "部署报告已生成: ${report_file}"
}

# ============================================================================
# 部署指标收集
# ============================================================================

collect_deploy_metrics() {
    log_step "收集部署指标..."
    local metrics_file="${LOG_DIR}/metrics_${TIMESTAMP}.json"
    local duration=0
    [[ -n "${DEPLOY_STATS[end_time]:-}" ]] && duration=$((DEPLOY_STATS[end_time] - DEPLOY_STATS[start_time]))

    cat > "${metrics_file}" << METRICS
{
  "timestamp": "${TIMESTAMP}",
  "app": "${APP_NAME:-unknown}",
  "env": "${ENVIRONMENT}",
  "status": "${DEPLOY_STATS[status]}",
  "duration_seconds": ${duration},
  "commit": "${DEPLOY_STATS[commit]:-unknown}",
  "branch": "${DEPLOY_STATS[branch]:-unknown}",
  "hostname": "${HOSTNAME}",
  "docker_image": "${DEPLOY_STATS[docker_image]:-N/A}",
  "deployer": "$(whoami)",
  "system": {
    "cpu_count": "$(nproc 2>/dev/null || echo 'unknown')",
    "memory_total_mb": "$(free -m 2>/dev/null | awk '/Mem:/{print $2}' || echo 'unknown')",
    "disk_available_gb": "$(df -BG "${DEPLOY_ROOT}" 2>/dev/null | awk 'NR==2{print $4}' || echo 'unknown')"
  }
}
METRICS

    log_success "部署指标已收集: ${metrics_file}"
}

# ============================================================================
# 服务重启辅助
# ============================================================================

restart_service() {
    local service_name="${1:-${APP_NAME}}"
    log_step "重启服务: ${service_name}"

    if [[ ${DOCKER_BUILD} -eq 1 ]]; then
        local container_name="${service_name}"
        [[ ${DRY_RUN} -eq 0 ]] && {
            docker restart "${container_name}" 2>>"${LOG_FILE}" || die "Docker容器重启失败"
            log_success "Docker容器已重启: ${container_name}"
        }
    else
        if command -v systemctl &>/dev/null && systemctl list-unit-files "${service_name}.service" &>/dev/null 2>&1; then
            [[ ${DRY_RUN} -eq 0 ]] && systemctl restart "${service_name}" 2>>"${LOG_FILE}" || die "systemctl重启失败"
            log_success "服务已通过systemctl重启"
        elif command -v service &>/dev/null; then
            [[ ${DRY_RUN} -eq 0 ]] && service "${service_name}" restart 2>>"${LOG_FILE}" || die "service重启失败"
            log_success "服务已通过service重启"
        else
            log_warning "无法确定服务管理方式, 请手动重启"
        fi
    fi
}

# ============================================================================
# 配置文件模板生成
# ============================================================================

generate_config_template() {
    log_step "生成配置文件模板..."
    local template_dir="${DEPLOY_ROOT}/templates"
    mkdir -p "${template_dir}" 2>/dev/null || true

    cat > "${template_dir}/deploy.cfg.template" << TEMPLATE
# 部署配置文件模板
# 生成时间: $(date)

# === 基本配置 ===
app_name=myapp
environment=production
deploy_root=/opt/deploy

# === Git配置 ===
git_repo=https://github.com/user/repo.git
git_branch=main
# git_tag=v1.0.0
# git_commit=abc123

# === 构建配置 ===
# build_cmd=npm run build
# pre_deploy_cmd=echo "pre-deploy"
# deploy_cmd=echo "deploy"
# post_deploy_cmd=echo "post-deploy"
# rollback_cmd=echo "rollback"

# === 健康检查 ===
health_check_url=http://localhost:8080/health
# health_check_port=8080
# health_check_cmd=pgrep myapp
health_check_retries=5
auto_rollback=1

# === Docker配置 ===
docker_build=0
# docker_image=myapp
# docker_registry=registry.example.com
# docker_tag=latest
# dockerfile=Dockerfile

# === 版本管理 ===
keep_releases=5

# === 通知配置 ===
# notify_type=dingtalk
# notify_webhook=https://oapi.dingtalk.com/robot/send?access_token=xxx
# notify_email=admin@example.com
TEMPLATE

    cat > "${template_dir}/systemd.service.template" << SERVICE_TEMPLATE
[Unit]
Description=${APP_NAME:-myapp} Service
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
User=deploy
Group=deploy
WorkingDirectory=${DEPLOY_ROOT}/current
ExecStart=${DEPLOY_ROOT}/current/start.sh
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

# 安全限制
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${DEPLOY_ROOT} /var/log/${APP_NAME:-myapp}

[Install]
WantedBy=multi-user.target
SERVICE_TEMPLATE

    cat > "${template_dir}/nginx.conf.template" << NGINX_TEMPLATE
upstream ${APP_NAME:-myapp} {
    server 127.0.0.1:${HEALTH_CHECK_PORT:-8080};
    keepalive 32;
}

server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://${APP_NAME:-myapp};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 30s;
        proxy_read_timeout 300s;
    }

    location /health {
        proxy_pass http://${APP_NAME:-myapp}/health;
        access_log off;
    }
}
NGINX_TEMPLATE

    log_success "配置模板已生成: ${template_dir}/"
}

# ============================================================================
# 部署锁状态检查
# ============================================================================

check_deploy_lock() {
    if [[ -f "${LOCK_FILE}" ]]; then
        local pid="$(cat "${LOCK_FILE}" 2>/dev/null)"
        local lock_time="$(stat -c%Y "${LOCK_FILE}" 2>/dev/null || echo 0)"
        local current_time="$(date +%s)"
        local age=$((current_time - lock_time))

        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            log_warning "部署锁: 活跃 (PID: ${pid}, 持续: ${age}秒)"
            return 1
        elif [[ ${age} -gt 3600 ]]; then
            log_warning "部署锁: 过期 (持续${age}秒, 可能是残留锁文件)"
            log_info "使用 --force 清除锁文件"
            return 1
        else
            log_info "部署锁: 空闲 (残留锁文件, PID ${pid}已退出)"
            return 0
        fi
    else
        log_info "部署锁: 无"
        return 0
    fi
}

# ============================================================================
# 部署差异比较
# ============================================================================

compare_versions() {
    local v1="${1:-}"
    local v2="${2:-}"
    [[ -z "${v1}" ]] && { log_error "请指定版本1"; return 1; }
    [[ -z "${v2}" ]] && { log_error "请指定版本2"; return 1; }

    local dir1="${RELEASES_DIR}/${v1}"
    local dir2="${RELEASES_DIR}/${v2}"

    [[ ! -d "${dir1}" ]] && { log_error "版本不存在: ${v1}"; return 1; }
    [[ ! -d "${dir2}" ]] && { log_error "版本不存在: ${v2}"; return 1; }

    log_step "比较版本差异: ${v1} vs ${v2}"
    log_info "版本 ${v1}: $(du -sh "${dir1}" 2>/dev/null | cut -f1)"
    log_info "版本 ${v2}: $(du -sh "${dir2}" 2>/dev/null | cut -f1)"

    echo ""
    echo -e "${CYAN}=== 文件差异 ===${NC}"
    diff -rq "${dir1}" "${dir2}" 2>/dev/null | head -50 || echo "(无差异)"

    echo ""
    echo -e "${CYAN}=== 配置差异 ===${NC}"
    for config_file in .env config.yaml config.json config.toml; do
        if [[ -f "${dir1}/${config_file}" ]] && [[ -f "${dir2}/${config_file}" ]]; then
            echo -e "\n${YELLOW}[${config_file}]${NC}"
            diff "${dir1}/${config_file}" "${dir2}/${config_file}" 2>/dev/null | head -30 || echo "(无差异)"
        fi
    done
}

# ============================================================================
# 部署回滚验证
# ============================================================================

verify_rollback() {
    log_step "验证回滚结果..."
    local rollback_version="${1:-${ROLLBACK_VERSION}}"

    if [[ -z "${rollback_version}" ]]; then
        local previous="$(ls -dt "${RELEASES_DIR}"/20* 2>/dev/null | head -2 | tail -1)"
        rollback_version="$(basename "${previous}")"
    fi

    log_info "验证回滚版本: ${rollback_version}"

    if [[ -L "${CURRENT_DIR}" ]]; then
        local current_target="$(basename "$(readlink "${CURRENT_DIR}")")"
        if [[ "${current_target}" == "${rollback_version}" ]]; then
            log_success "回滚验证通过: current -> ${rollback_version}"
        else
            log_error "回滚验证失败: current -> ${current_target} (期望: ${rollback_version})"
            return 1
        fi
    fi

    if [[ -n "${HEALTH_CHECK_URL}" ]]; then
        local http_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${HEALTH_CHECK_URL}" 2>/dev/null || echo '000')"
        if [[ "${http_code}" =~ ^2 ]]; then
            log_success "健康检查通过 (状态码: ${http_code})"
        else
            log_error "健康检查失败 (状态码: ${http_code})"
            return 1
        fi
    fi

    log_success "回滚验证完成"
    return 0
}

# ============================================================================
# 制品仓库集成
# ============================================================================

upload_artifact() {
    log_step "上传构建制品..."
    local target_dir="${RELEASES_DIR}/${TIMESTAMP}"
    local artifact_name="${APP_NAME:-app}-${TIMESTAMP}.tar.gz"
    local artifact_path="${LOG_DIR}/${artifact_name}"

    [[ ! -d "${target_dir}" ]] && { log_warning "发布目录不存在"; return 0; }

    log_info "打包构建制品..."
    [[ ${DRY_RUN} -eq 0 ]] && {
        tar -czf "${artifact_path}" -C "${RELEASES_DIR}" "${TIMESTAMP}" 2>>"${LOG_FILE}" || {
            log_error "制品打包失败"
            return 1
        }
        local artifact_size="$(du -sh "${artifact_path}" 2>/dev/null | cut -f1)"
        log_info "制品大小: ${artifact_size}"
    }

    local nexus_url="${NEXUS_URL:-}"
    local artifactory_url="${ARTIFACTORY_URL:-}"

    if [[ -n "${nexus_url}" ]]; then
        log_info "上传到Nexus: ${nexus_url}"
        [[ ${DRY_RUN} -eq 0 ]] && {
            curl -s -u "${NEXUS_USER:-admin}:${NEXUS_PASS:-admin}" \
                --upload-file "${artifact_path}" \
                "${nexus_url}/repository/releases/${APP_NAME}/${artifact_name}" \
                2>>"${LOG_FILE}" || log_warning "Nexus上传失败"
        }
    elif [[ -n "${artifactory_url}" ]]; then
        log_info "上传到Artifactory: ${artifactory_url}"
        [[ ${DRY_RUN} -eq 0 ]] && {
            curl -s -u "${ARTIFACTORY_USER:-admin}:${ARTIFACTORY_PASS:-admin}" \
                --upload-file "${artifact_path}" \
                "${artifactory_url}/${APP_NAME}/${artifact_name}" \
                2>>"${LOG_FILE}" || log_warning "Artifactory上传失败"
        }
    else
        log_info "未配置制品仓库, 制品保存在: ${artifact_path}"
    fi

    log_success "制品上传完成"
}

download_artifact() {
    local artifact_name="$1"
    [[ -z "${artifact_name}" ]] && { log_error "请指定制品名称"; return 1; }

    log_step "下载构建制品: ${artifact_name}"
    local target_dir="${RELEASES_DIR}/${TIMESTAMP}"
    mkdir -p "${target_dir}" 2>/dev/null || true

    local nexus_url="${NEXUS_URL:-}"
    local artifactory_url="${ARTIFACTORY_URL:-}"
    local artifact_path="/tmp/${artifact_name}"

    if [[ -n "${nexus_url}" ]]; then
        curl -s -u "${NEXUS_USER:-admin}:${NEXUS_PASS:-admin}" \
            -o "${artifact_path}" \
            "${nexus_url}/repository/releases/${APP_NAME}/${artifact_name}" \
            2>>"${LOG_FILE}" || die "制品下载失败"
    elif [[ -n "${artifactory_url}" ]]; then
        curl -s -u "${ARTIFACTORY_USER:-admin}:${ARTIFACTORY_PASS:-admin}" \
            -o "${artifact_path}" \
            "${artifactory_url}/${APP_NAME}/${artifact_name}" \
            2>>"${LOG_FILE}" || die "制品下载失败"
    else
        die "未配置制品仓库"
    fi

    log_info "解压制品..."
    tar -xzf "${artifact_path}" -C "${RELEASES_DIR}" 2>>"${LOG_FILE}" || die "制品解压失败"
    rm -f "${artifact_path}"

    log_success "制品下载并解压完成"
}

# ============================================================================
# 部署定时任务
# ============================================================================

install_deploy_cron() {
    log_step "安装部署定时任务..."
    local schedule="${1:-0 2 * * *}"
    local cron_cmd="cd ${DEPLOY_ROOT} && bash $(realpath "${BASH_SOURCE[0]}") --deploy --config ${DEPLOY_ROOT}/deploy.cfg >> ${LOG_DIR}/cron.log 2>&1"

    echo -e "${YELLOW}将添加以下Cron任务:${NC}"
    echo "  ${schedule} ${cron_cmd}"
    echo ""
    echo -ne "${YELLOW}确认添加? [y/N]: ${NC}"
    read -r confirm
    [[ ! "${confirm}" =~ ^[Yy]$ ]] && { log_info "已取消"; return 0; }

    (crontab -l 2>/dev/null | grep -v "auto_deploy.sh"; echo "${schedule} ${cron_cmd}") | crontab -
    log_success "定时任务已安装"
}

# ============================================================================
# 部署状态概览
# ============================================================================

show_deploy_status() {
    echo -e "${CYAN}=== 部署状态概览 ===${NC}"
    echo ""

    echo -e "${WHITE}应用信息:${NC}"
    echo "  应用名称: ${APP_NAME:-未配置}"
    echo "  部署环境: ${ENVIRONMENT}"
    echo "  部署根目录: ${DEPLOY_ROOT}"

    echo ""
    echo -e "${WHITE}当前版本:${NC}"
    if [[ -L "${CURRENT_DIR}" ]]; then
        local current_target="$(readlink "${CURRENT_DIR}")"
        echo "  current -> ${current_target}"
        if [[ -f "${current_target}/.deploy_info" ]]; then
            echo "  版本信息: $(cat "${current_target}/.deploy_info" 2>/dev/null)"
        fi
    else
        echo "  (未部署)"
    fi

    echo ""
    echo -e "${WHITE}版本列表:${NC}"
    list_versions

    echo ""
    echo -e "${WHITE}部署锁:${NC}"
    check_deploy_lock

    echo ""
    echo -e "${WHITE}系统资源:${NC}"
    echo "  CPU: $(nproc 2>/dev/null || echo 'unknown')核"
    echo "  内存: $(free -h 2>/dev/null | awk '/Mem:/{print $3 "/" $2}' || echo 'unknown')"
    echo "  磁盘: $(df -h "${DEPLOY_ROOT}" 2>/dev/null | awk 'NR==2{print $3 "/" $2 " (" $5 ")"}' || echo 'unknown')"

    if [[ ${DOCKER_BUILD} -eq 1 ]]; then
        echo ""
        echo -e "${WHITE}Docker状态:${NC}"
        if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
            echo "  状态: 运行中"
            echo "  容器数: $(docker ps -q 2>/dev/null | wc -l)"
            echo "  镜像数: $(docker images -q 2>/dev/null | wc -l)"
            local app_container="${APP_NAME:-app}"
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "${app_container}"; then
                echo "  应用容器: 运行中"
                docker ps --filter "name=${app_container}" --format "    {{.Names}}: {{.Status}} ({{.Image}})" 2>/dev/null
            else
                echo "  应用容器: 未运行"
            fi
        else
            echo "  状态: 不可用"
        fi
    fi
}

# ============================================================================
# Git标签管理
# ============================================================================

manage_git_tags() {
    log_step "管理Git标签..."
    local target_dir="${RELEASES_DIR}/${TIMESTAMP}"
    [[ ! -d "${target_dir}" ]] && { log_warning "发布目录不存在"; return 0; }

    cd "${target_dir}"

    echo -e "${CYAN}=== Git标签 ===${NC}"
    git tag -l 2>/dev/null | tail -20 || echo "(无标签)"

    echo ""
    echo -e "${WHITE}最近提交:${NC}"
    git log --oneline -10 2>/dev/null || echo "(无提交记录)"

    echo ""
    echo -e "${WHITE}当前分支:${NC}"
    git branch -a 2>/dev/null | head -10 || echo "(无分支信息)"
}

# ============================================================================
# 部署环境变量注入
# ============================================================================

inject_env_vars() {
    log_step "注入环境变量..."
    local target_dir="${RELEASES_DIR}/${TIMESTAMP}"
    [[ ! -d "${target_dir}" ]] && return 0

    local env_file="${target_dir}/.env"
    local env_content=""

    env_content+="DEPLOY_TIMESTAMP=${TIMESTAMP}\n"
    env_content+="DEPLOY_ENV=${ENVIRONMENT}\n"
    env_content+="DEPLOY_HOST=${HOSTNAME}\n"
    env_content+="DEPLOY_COMMIT=${DEPLOY_STATS[commit]:-unknown}\n"
    env_content+="DEPLOY_BRANCH=${DEPLOY_STATS[branch]:-unknown}\n"
    env_content+="DEPLOY_VERSION=${TIMESTAMP}\n"

    if [[ -f "${env_file}" ]]; then
        local backup_env="${env_file}.bak.${TIMESTAMP}"
        cp "${env_file}" "${backup_env}" 2>/dev/null || true
        echo -e "${env_content}" >> "${env_file}"
        log_info "环境变量已追加到: ${env_file}"
    else
        echo -e "${env_content}" > "${env_file}"
        log_info "环境变量文件已创建: ${env_file}"
    fi
}

# ============================================================================
# 部署依赖检查
# ============================================================================

check_deploy_dependencies() {
    log_step "检查部署依赖..."
    local target_dir="${RELEASES_DIR}/${TIMESTAMP}"
    [[ ! -d "${target_dir}" ]] && return 0

    cd "${target_dir}"

    if [[ -f "package.json" ]]; then
        log_info "Node.js依赖检查..."
        if [[ -d "node_modules" ]]; then
            local outdated="$(npm outdated 2>/dev/null | wc -l)"
            [[ ${outdated} -gt 0 ]] && log_warning "发现${outdated}个过时的依赖包"
        else
            log_warning "node_modules目录不存在, 需要运行npm install"
        fi
    fi

    if [[ -f "go.sum" ]]; then
        log_info "Go依赖检查..."
        if command -v go &>/dev/null; then
            go mod verify 2>/dev/null || log_warning "Go模块验证失败"
        fi
    fi

    if [[ -f "requirements.txt" ]]; then
        log_info "Python依赖检查..."
        if command -v pip3 &>/dev/null; then
            pip3 check 2>/dev/null || log_warning "Python依赖存在冲突"
        fi
    fi

    log_success "依赖检查完成"
}

# ============================================================================
# 部署日志管理
# ============================================================================

manage_deploy_logs() {
    log_step "管理部署日志..."
    local action="${1:-rotate}"

    case "${action}" in
        rotate)
            log_info "轮转部署日志..."
            [[ -f "${LOG_FILE}" ]] && {
                local archive="${LOG_FILE}.$(date +%Y%m%d%H%M%S).gz"
                gzip -c "${LOG_FILE}" > "${archive}" 2>/dev/null || true
                : > "${LOG_FILE}"
                log_info "日志已轮转: ${archive}"
            }
            find "${LOG_DIR}" -name "*.gz" -mtime +30 -delete 2>/dev/null || true
            find "${LOG_DIR}" -name "*.log" -mtime +90 -delete 2>/dev/null || true
            ;;
        clean)
            log_info "清理部署日志..."
            find "${LOG_DIR}" -name "*.gz" -delete 2>/dev/null || true
            find "${LOG_DIR}" -name "report_*.html" -mtime +7 -delete 2>/dev/null || true
            find "${LOG_DIR}" -name "metrics_*.json" -mtime +7 -delete 2>/dev/null || true
            log_success "日志已清理"
            ;;
        stats)
            log_info "部署日志统计:"
            echo "  日志目录: ${LOG_DIR}"
            echo "  日志文件数: $(find "${LOG_DIR}" -name "*.log" 2>/dev/null | wc -l)"
            echo "  压缩日志数: $(find "${LOG_DIR}" -name "*.gz" 2>/dev/null | wc -l)"
            echo "  总大小: $(du -sh "${LOG_DIR}" 2>/dev/null | cut -f1)"
            ;;
        *)
            log_warning "未知日志操作: ${action}"
            ;;
    esac
}

# ============================================================================
# 部署安全扫描
# ============================================================================

security_scan() {
    log_step "执行部署安全扫描..."
    local target_dir="${RELEASES_DIR}/${TIMESTAMP}"
    [[ ! -d "${target_dir}" ]] && { log_warning "发布目录不存在"; return 0; }

    cd "${target_dir}"

    log_info "扫描敏感文件..."
    local sensitive_files=0
    while IFS= read -r -d '' file; do
        local filename="$(basename "${file}")"
        case "${filename}" in
            *.key|*.pem|*.p12|*.pfx|id_rsa|id_ed25519|*.secret)
                log_warning "  发现密钥文件: ${file}"
                ((sensitive_files++)) || true
                ;;
            .env|.env.*|*.env)
                log_warning "  发现环境变量文件: ${file}"
                ((sensitive_files++)) || true
                ;;
            credentials*|passwords*|secrets*)
                log_warning "  发现凭证文件: ${file}"
                ((sensitive_files++)) || true
                ;;
        esac
    done < <(find . -type f -print0 2>/dev/null)

    log_info "扫描文件权限..."
    local bad_perms=0
    while IFS= read -r -d '' file; do
        local perms="$(stat -c%a "${file}" 2>/dev/null)"
        if [[ "${perms: -1}" -ge 6 ]] || [[ "${perms: -2:1}" -ge 6 ]]; then
            log_warning "  不安全权限: ${file} (${perms})"
            ((bad_perms++)) || true
        fi
    done < <(find . -type f -name "*.sh" -print0 2>/dev/null)

    log_info "扫描硬编码密钥..."
    local hardcoded=0
    if command -v grep &>/dev/null; then
        while IFS= read -r line; do
            log_warning "  可能的硬编码密钥: ${line:0:80}..."
            ((hardcoded++)) || true
        done < <(grep -rn -i "password\s*=\s*['\"]" . --include="*.{py,js,rb,go,java,php,sh,yaml,yml,json}" 2>/dev/null | head -10)
    fi

    echo ""
    log_info "安全扫描结果:"
    log_info "  敏感文件: ${sensitive_files}"
    log_info "  不安全权限: ${bad_perms}"
    log_info "  硬编码密钥: ${hardcoded}"

    if [[ $((sensitive_files + bad_perms + hardcoded)) -gt 0 ]]; then
        log_warning "发现安全问题, 请检查后再部署"
    else
        log_success "安全扫描通过"
    fi
}

# ============================================================================
# 部署通知增强
# ============================================================================

send_slack_notification() {
    local subject="$1" message="$2" color="${3:-good}"
    [[ -z "${SLACK_WEBHOOK:-}" ]] && return 0

    local emoji=":white_check_mark:"
    [[ "${color}" == "danger" ]] && emoji=":x:"
    [[ "${color}" == "warning" ]] && emoji=":warning:"

    curl -s -X POST "${SLACK_WEBHOOK}" \
        -H 'Content-Type: application/json' \
        -d "{\"attachments\":[{\"color\":\"${color}\",\"title\":\"${emoji} ${subject}\",\"text\":\"${message}\",\"footer\":\"Auto Deploy v${SCRIPT_VERSION}\",\"ts\":$(date +%s)}]}" \
        &>/dev/null
}

send_feishu_notification() {
    local subject="$1" message="$2"
    [[ -z "${FEISHU_WEBHOOK:-}" ]] && return 0

    curl -s -X POST "${FEISHU_WEBHOOK}" \
        -H 'Content-Type: application/json' \
        -d "{\"msg_type\":\"interactive\",\"card\":{\"header\":{\"title\":{\"tag\":\"plain_text\",\"content\":\"${subject}\"}},\"elements\":[{\"tag\":\"div\",\"text\":{\"tag\":\"plain_text\",\"content\":\"${message}\"}}]}}" \
        &>/dev/null
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
  --status              查看部署状态概览
  --pre-check           执行部署前检查
  --post-verify         执行部署后验证
  --report              生成部署报告
  --metrics             收集部署指标
  --diff V1 V2          比较两个版本差异
  --verify-rollback     验证回滚结果
  --template            生成配置文件模板
  --upload-artifact     上传构建制品
  --download-artifact F 下载构建制品
  --install-cron        安装备份定时任务
  --canary [WEIGHT]     金丝雀部署 (默认10%)
  --canary-promote      提升金丝雀为正式
  --canary-rollback     回滚金丝雀部署
  --blue-green          蓝绿部署
  --rolling [N]         滚动部署 (默认3副本)
  --docker-cache ACTION Docker缓存管理 (clean/stats)
  --restart             重启服务

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
            --deploy)              action="deploy"; shift ;;
            --rollback)            action="rollback"; [[ $# -gt 1 && ! "$2" =~ ^-- ]] && { ROLLBACK_VERSION="$2"; shift 2; } || shift ;;
            --list)                action="list"; shift ;;
            --history)             action="history"; shift ;;
            --init)                action="init"; shift ;;
            --status)              action="status"; shift ;;
            --pre-check)           action="pre_check"; shift ;;
            --post-verify)         action="post_verify"; shift ;;
            --report)              action="report"; shift ;;
            --metrics)             action="metrics"; shift ;;
            --diff)                action="diff"; shift; local v1="$1"; shift; local v2="$1"; shift ;;
            --verify-rollback)     action="verify_rollback"; shift ;;
            --template)            action="template"; shift ;;
            --upload-artifact)     action="upload_artifact"; shift ;;
            --download-artifact)   action="download_artifact"; shift; local artifact_name="$1"; shift ;;
            --install-cron)        action="install_cron"; shift ;;
            --canary)              action="canary"; [[ $# -gt 1 && "$2" =~ ^[0-9]+$ ]] && { local canary_weight="$2"; shift 2; } || shift ;;
            --canary-promote)      action="canary_promote"; shift ;;
            --canary-rollback)     action="canary_rollback"; shift ;;
            --blue-green)          action="blue_green"; shift ;;
            --rolling)             action="rolling"; [[ $# -gt 1 && "$2" =~ ^[0-9]+$ ]] && { local rolling_replicas="$2"; shift 2; } || shift ;;
            --docker-cache)        action="docker_cache"; local cache_action="${2:-clean}"; shift 2 ;;
            --restart)             action="restart"; shift ;;
            --app)                 APP_NAME="$2"; shift 2 ;;
            --env)                 ENVIRONMENT="$2"; shift 2 ;;
            --repo)                GIT_REPO="$2"; shift 2 ;;
            --branch)              GIT_BRANCH="$2"; shift 2 ;;
            --tag)                 GIT_TAG="$2"; shift 2 ;;
            --commit)              GIT_COMMIT="$2"; shift 2 ;;
            --build-cmd)           BUILD_CMD="$2"; shift 2 ;;
            --deploy-cmd)          DEPLOY_CMD="$2"; shift 2 ;;
            --pre-deploy)          PRE_DEPLOY_CMD="$2"; shift 2 ;;
            --post-deploy)         POST_DEPLOY_CMD="$2"; shift 2 ;;
            --rollback-cmd)        ROLLBACK_CMD="$2"; shift 2 ;;
            --health-url)          HEALTH_CHECK_URL="$2"; shift 2 ;;
            --health-port)         HEALTH_CHECK_PORT="$2"; shift 2 ;;
            --health-cmd)          HEALTH_CHECK_CMD="$2"; shift 2 ;;
            --health-retries)      HEALTH_CHECK_RETRIES="$2"; shift 2 ;;
            --no-auto-rollback)    AUTO_ROLLBACK=0; shift ;;
            --docker)              DOCKER_BUILD=1; shift ;;
            --docker-image)        DOCKER_IMAGE="$2"; shift 2 ;;
            --docker-registry)     DOCKER_REGISTRY="$2"; shift 2 ;;
            --docker-tag)          DOCKER_TAG="$2"; shift 2 ;;
            --dockerfile)          DOCKERFILE="$2"; shift 2 ;;
            --config)              parse_deploy_config "$2"; shift 2 ;;
            --keep)                KEEP_RELEASES="$2"; shift 2 ;;
            --force)               FORCE_DEPLOY=1; shift ;;
            --dry-run)             DRY_RUN=1; shift ;;
            --verbose)             VERBOSE=1; shift ;;
            --help|-h)             show_usage; exit 0 ;;
            --version|-v)          echo "v${SCRIPT_VERSION}"; exit 0 ;;
            *)                     log_error "未知选项: $1"; show_usage; exit 1 ;;
        esac
    done

    detect_os

    case "${action}" in
        deploy)            [[ -z "${GIT_REPO}" ]] && [[ -z "${DEPLOY_CMD}" ]] && die "必须指定 --repo 或 --deploy-cmd"; do_deploy ;;
        rollback)          do_rollback ;;
        list)              list_versions ;;
        history)           show_history ;;
        init)              mkdir -p "${RELEASES_DIR}" "${SHARED_DIR}" "${LOG_DIR}" "${HISTORY_DIR}"; log_success "部署目录已初始化: ${DEPLOY_ROOT}" ;;
        status)            show_deploy_status ;;
        pre_check)         pre_deploy_check ;;
        post_verify)       post_deploy_verify ;;
        report)            generate_deploy_report ;;
        metrics)           collect_deploy_metrics ;;
        diff)              compare_versions "${v1:-}" "${v2:-}" ;;
        verify_rollback)   verify_rollback ;;
        template)          generate_config_template ;;
        upload_artifact)   upload_artifact ;;
        download_artifact) download_artifact "${artifact_name:-}" ;;
        install_cron)      install_deploy_cron ;;
        canary)            canary_deploy "${canary_weight:-10}" ;;
        canary_promote)    canary_promote ;;
        canary_rollback)   canary_rollback ;;
        blue_green)        blue_green_deploy ;;
        rolling)           rolling_deploy "${rolling_replicas:-3}" ;;
        docker_cache)      docker_cache_manage "${cache_action:-clean}" ;;
        restart)           restart_service ;;
    esac
}

parse_args "$@"
