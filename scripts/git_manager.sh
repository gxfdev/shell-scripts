#!/usr/bin/env bash
# ============================================================================
#  Git集成管理脚本 (Git Integration Manager)
#  支持: Linux (CentOS/Ubuntu/Debian/Alpine/Arch/openSUSE), macOS, Windows WSL/Git Bash
#  版本: 1.0.0
#  作者: gxfdev
#  仓库: https://github.com/gxfdev/shell-scripts
# ============================================================================

set -euo pipefail

SCRIPT_VERSION="1.0.0"
SCRIPT_NAME="git_manager"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "${SCRIPT_DIR}")/lib"

if [[ -f "${LIB_DIR}/common_lib.sh" ]]; then
    source "${LIB_DIR}/common_lib.sh"
    common_init
else
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
    WHITE='\033[1;37m'; NC='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
    log() { local level="$1"; shift; echo -e "[$(date '+%H:%M:%S')] [${level}] $*"; }
    log_info() { log "INFO" "$@"; }; log_success() { log "OK" "$@"; }
    log_warn() { log "WARN" "$@"; }; log_error() { log "FAIL" "$@"; }
    log_step() { log "STEP" "$@"; }; log_debug() { :; }
    COMMON_IS_WSL=0; COMMON_IS_MACOS=0; COMMON_PKG_MANAGER="unknown"
    COMMON_DRY_RUN=0; COMMON_VERBOSE=0; COMMON_INTERACTIVE=1; COMMON_LOG_FILE="/dev/null"
fi

LOG_DIR="${LOG_DIR:-/var/log/shell-scripts}/${SCRIPT_NAME}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}_${TIMESTAMP}.log"
mkdir -p "${LOG_DIR}" 2>/dev/null || true

WORK_DIR="" GIT_USER="" GIT_EMAIL="" REMOTE_NAME="origin" DEFAULT_BRANCH="main"
DRY_RUN=0 VERBOSE=0 FORCE=0 NO_PUSH=0 INTERACTIVE=1 SIGN_COMMITS=0

confirm() { local m="${1:-确认?}"; [[ ${INTERACTIVE} -eq 0 ]] && return 0; read -rp "$(echo -e "${YELLOW}${m} [y/N]${NC} ")" a; [[ "${a}" =~ ^[Yy] ]]; }

git_check_env() {
    log_step "检测Git环境..."
    if ! command -v git &>/dev/null; then
        log_error "Git未安装，请先安装Git"; return 1
    fi
    log_success "Git版本: $(git --version 2>/dev/null | awk '{print $3}')"
    if [[ ${COMMON_IS_WSL:-0} -eq 1 ]]; then
        log_info "检测到WSL环境，配置凭据管理器..."
        git config --global credential.helper cache --timeout=3600 2>/dev/null || true
    fi
    [[ -n "${GIT_USER}" ]] && git config user.name "${GIT_USER}" 2>/dev/null || true
    [[ -n "${GIT_EMAIL}" ]] && git config user.email "${GIT_EMAIL}" 2>/dev/null || true
    if [[ ${SIGN_COMMITS} -eq 1 ]] && command -v gpg &>/dev/null; then
        local gpg_key="$(gpg --list-secret-keys --keyid-format=long 2>/dev/null | grep sec | head -1 | awk '{print $2}' | cut -d'/' -f2)"
        [[ -n "${gpg_key}" ]] && { git config commit.gpgsign true 2>/dev/null; git config user.signingkey "${gpg_key}" 2>/dev/null; log_success "GPG签名已配置"; }
    fi
}

git_is_repo() { git -C "${1:-${WORK_DIR:-.}}" rev-parse --is-inside-work-tree &>/dev/null; }
git_current_branch() { git -C "${1:-${WORK_DIR:-.}}" branch --show-current 2>/dev/null || echo "detached"; }
git_repo_root() { git -C "${1:-${WORK_DIR:-.}}" rev-parse --show-toplevel 2>/dev/null || echo "${1:-.}"; }

git_init_repo() {
    local dir="${1:-${WORK_DIR:-.}}" remote_url="${2:-}"
    log_step "初始化Git仓库: ${dir}"
    [[ ${DRY_RUN} -eq 1 ]] && { log_info "[DRY-RUN] 将初始化: ${dir}"; return 0; }
    mkdir -p "${dir}" 2>/dev/null || true; cd "${dir}"
    git_is_repo "${dir}" && { log_warn "已是Git仓库"; return 0; }
    git init --initial-branch="${DEFAULT_BRANCH}" 2>/dev/null || git init 2>/dev/null
    log_success "Git仓库已初始化"
    [[ ! -f ".gitignore" ]] && cat > .gitignore << 'GI'
.DS_Store Thumbs.db .idea/ .vscode/ *.swp build/ dist/ node_modules/ .env *.log *.pem *.key secrets/
GI
    [[ ! -f "README.md" ]] && echo "# $(basename "${dir}")" > README.md
    [[ -n "${remote_url}" ]] && { git remote add "${REMOTE_NAME}" "${remote_url}" 2>/dev/null || true; log_success "远程仓库已配置"; }
    git add -A 2>/dev/null; git commit -m "chore: 初始化仓库" --allow-empty 2>/dev/null
    log_success "初始提交已完成"
}

git_clone_repo() {
    local url="$1" dir="${2:-}" branch="${3:-${DEFAULT_BRANCH}}"
    [[ -z "${url}" ]] && { log_error "请指定仓库URL"; return 1; }
    log_step "克隆仓库: ${url}"
    [[ ${DRY_RUN} -eq 1 ]] && { log_info "[DRY-RUN] 将克隆: ${url}"; return 0; }
    local opts=(); [[ -n "${branch}" ]] && opts+=("-b" "${branch}"); [[ -n "${dir}" ]] && opts+=("${dir}")
    git clone "${opts[@]}" "${url}" 2>&1 | tee -a "${LOG_FILE}"; log_success "仓库克隆完成"
}

git_branch_list() {
    local dir="${WORK_DIR:-.}" pattern="${1:-}"
    log_step "列出分支..."
    if [[ -n "${pattern}" ]]; then git -C "${dir}" branch -a --list "*${pattern}*" --color=always 2>/dev/null
    else echo -e "${CYAN}=== 本地分支 ===${NC}"; git -C "${dir}" branch -vv --color=always 2>/dev/null; echo ""; echo -e "${CYAN}=== 远程分支 ===${NC}"; git -C "${dir}" branch -r --color=always 2>/dev/null; fi
}

git_branch_create() {
    local name="$1" start="${2:-${DEFAULT_BRANCH}}"
    [[ -z "${name}" ]] && { log_error "请指定分支名"; return 1; }
    log_step "创建分支: ${name} (基于 ${start})"
    [[ ${DRY_RUN} -eq 1 ]] && { log_info "[DRY-RUN] 将创建: ${name}"; return 0; }
    local dir="${WORK_DIR:-.}"; git -C "${dir}" fetch --all --prune 2>/dev/null || true
    git -C "${dir}" branch --list "${name}" | grep -q "${name}" && { [[ ${FORCE} -eq 1 ]] && git -C "${dir}" branch -D "${name}" 2>/dev/null || { log_warn "分支已存在"; return 1; }; }
    git -C "${dir}" checkout -b "${name}" "${start}" 2>&1 | tee -a "${LOG_FILE}"; log_success "分支已创建: ${name}"
}

git_branch_switch() {
    local name="$1"; [[ -z "${name}" ]] && { log_error "请指定分支名"; return 1; }
    log_step "切换分支: ${name}"; local dir="${WORK_DIR:-.}"
    local dirty="$(git -C "${dir}" status --porcelain 2>/dev/null)"
    [[ -n "${dirty}" ]] && { git -C "${dir}" stash push -m "auto-stash-${name}" 2>/dev/null; log_info "已暂存更改"; }
    git -C "${dir}" checkout "${name}" 2>&1 | tee -a "${LOG_FILE}"; log_success "已切换到: ${name}"
}

git_branch_merge() {
    local source="$1" target="${2:-}"
    [[ -z "${source}" ]] && { log_error "请指定源分支"; return 1; }
    local dir="${WORK_DIR:-.}"; target="${target:-$(git_current_branch "${dir}")}"
    log_step "合并分支: ${source} -> ${target}"
    [[ ${DRY_RUN} -eq 1 ]] && { log_info "[DRY-RUN] 将合并"; return 0; }
    git -C "${dir}" checkout "${target}" 2>/dev/null
    git -C "${dir}" merge --no-ff "${source}" -m "merge: 合并 ${source} 到 ${target}" 2>&1 | tee -a "${LOG_FILE}" || { log_error "合并冲突!"; return 1; }
    log_success "分支合并完成"
}

git_branch_delete() {
    local name="$1"; [[ -z "${name}" ]] && { log_error "请指定分支名"; return 1; }
    log_step "删除分支: ${name}"; local dir="${WORK_DIR:-.}"
    [[ "$(git_current_branch "${dir}")" == "${name}" ]] && git -C "${dir}" checkout "${DEFAULT_BRANCH}" 2>/dev/null
    git -C "${dir}" branch -d "${name}" 2>/dev/null || [[ ${FORCE} -eq 1 ]] && git -C "${dir}" branch -D "${name}" 2>/dev/null
    log_success "分支已删除: ${name}"
}

git_branch_rename() {
    local old="$1" new="$2"
    [[ -z "${old}" ]] || [[ -z "${new}" ]] && { log_error "用法: --branch-rename 旧名 新名"; return 1; }
    log_step "重命名分支: ${old} -> ${new}"; git -C "${WORK_DIR:-.}" branch -m "${old}" "${new}" 2>&1 | tee -a "${LOG_FILE}"; log_success "分支已重命名"
}

git_branch_diff() {
    local b1="$1" b2="${2:-HEAD}"; [[ -z "${b1}" ]] && { log_error "请指定分支"; return 1; }
    log_step "比较分支: ${b1} vs ${b2}"; local dir="${WORK_DIR:-.}"
    echo -e "${CYAN}=== 提交差异 ===${NC}"; git -C "${dir}" log --oneline "${b1}..${b2}" 2>/dev/null
    echo -e "${CYAN}=== 文件差异 ===${NC}"; git -C "${dir}" diff --stat "${b1}" "${b2}" 2>/dev/null
}

git_tag_list() { log_step "列出标签..."; git -C "${WORK_DIR:-.}" tag -l --sort=-v:refname 2>/dev/null | head -30; }

git_tag_create() {
    local name="$1" msg="${2:-Release ${name}}"; [[ -z "${name}" ]] && { log_error "请指定标签名"; return 1; }
    log_step "创建标签: ${name}"; [[ ${DRY_RUN} -eq 1 ]] && { log_info "[DRY-RUN] 将创建标签: ${name}"; return 0; }
    local dir="${WORK_DIR:-.}"
    git -C "${dir}" tag -l "${name}" | grep -q "${name}" && { [[ ${FORCE} -eq 1 ]] && { git -C "${dir}" tag -d "${name}" 2>/dev/null; git -C "${dir}" push "${REMOTE_NAME}" ":refs/tags/${name}" 2>/dev/null || true; } || { log_error "标签已存在"; return 1; }; }
    git -C "${dir}" tag -a "${name}" -m "${msg}" 2>&1 | tee -a "${LOG_FILE}"; log_success "标签已创建: ${name}"
    [[ ${NO_PUSH} -eq 0 ]] && git -C "${dir}" push "${REMOTE_NAME}" "${name}" 2>/dev/null && log_success "标签已推送" || true
}

git_tag_delete() {
    local name="$1"; [[ -z "${name}" ]] && { log_error "请指定标签名"; return 1; }
    log_step "删除标签: ${name}"; local dir="${WORK_DIR:-.}"
    git -C "${dir}" tag -d "${name}" 2>/dev/null; [[ ${NO_PUSH} -eq 0 ]] && git -C "${dir}" push "${REMOTE_NAME}" ":refs/tags/${name}" 2>/dev/null || true
    log_success "标签已删除"
}

git_tag_show() { local name="$1"; [[ -z "${name}" ]] && { log_error "请指定标签名"; return 1; }; git -C "${WORK_DIR:-.}" show "${name}" --stat --color=always 2>/dev/null; }

git_version_bump() {
    local type="$1"; [[ -z "${type}" ]] && { log_error "请指定: major/minor/patch"; return 1; }
    local dir="${WORK_DIR:-.}" latest
    latest="$(git -C "${dir}" describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")"; latest="${latest#v}"
    local major minor patch; IFS='.' read -r major minor patch <<< "${latest}"
    major="${major:-0}"; minor="${minor:-0}"; patch="${patch:-0}"
    case "${type}" in
        major) major=$((major + 1)); minor=0; patch=0 ;;
        minor) minor=$((minor + 1)); patch=0 ;;
        patch) patch=$((patch + 1)) ;;
        *) log_error "无效类型: ${type}"; return 1 ;;
    esac
    local new_ver="v${major}.${minor}.${patch}"; log_info "版本升级: v${latest} -> ${new_ver}"
    [[ ${DRY_RUN} -eq 1 ]] && { log_info "[DRY-RUN] 将创建: ${new_ver}"; return 0; }
    git_tag_create "${new_ver}" "Release ${new_ver}"
}

git_changelog() {
    local from="${1:-}" to="${2:-HEAD}" output="${3:-CHANGELOG.md}"
    local dir="${WORK_DIR:-.}"; log_step "生成变更日志..."
    [[ -z "${from}" ]] && from="$(git -C "${dir}" describe --tags --abbrev=0 2>/dev/null || echo '')"
    local range="${to}"; [[ -n "${from}" ]] && range="${from}..${to}"
    local features="" fixes="" others=""
    while IFS= read -r line; do
        local hash="$(echo "${line}" | awk '{print $1}')" msg="$(echo "${line}" | awk '{$1=""; print $0}' | sed 's/^ //')"
        echo "${msg}" | grep -qiE '^(feat|feature)' && features+="  - ${msg} (${hash})\n"
        echo "${msg}" | grep -qiE '^(fix|bugfix)' && fixes+="  - ${msg} (${hash})\n"
        others+="  - ${msg} (${hash})\n"
    done < <(git -C "${dir}" log --oneline --no-merges "${range}" 2>/dev/null)
    local cl="# Changelog\n\n## [${to}] - $(date +%Y-%m-%d)\n"
    [[ -n "${features}" ]] && cl+="\n### Features\n$(echo -e "${features}")"
    [[ -n "${fixes}" ]] && cl+="\n### Bug Fixes\n$(echo -e "${fixes}")"
    [[ -n "${others}" ]] && cl+="\n### Other Changes\n$(echo -e "${others}")"
    if [[ ${DRY_RUN} -eq 0 ]]; then
        if [[ -f "${output}" ]]; then local tmp="$(mktemp)"; echo -e "${cl}" > "${tmp}"; echo "" >> "${tmp}"; cat "${output}" >> "${tmp}"; mv "${tmp}" "${output}"; else echo -e "${cl}" > "${output}"; fi
        log_success "变更日志已生成: ${output}"
    else echo -e "${cl}"; fi
}

git_commit_stats() {
    local dir="${WORK_DIR:-.}" since="${1:-1.month.ago}"
    log_step "提交统计 (自 ${since} 起)..."
    echo -e "${CYAN}=== 提交者排行 ===${NC}"; git -C "${dir}" shortlog -sn --since="${since}" --no-merges 2>/dev/null
    echo -e "${CYAN}=== 文件变更排行 ===${NC}"; git -C "${dir}" log --since="${since}" --format="" --name-only 2>/dev/null | sort | uniq -c | sort -rn | head -10
}

git_hook_setup() {
    local dir="${WORK_DIR:-.}" hook_type="${1:-all}"
    log_step "安装Git钩子..."
    local hook_dir; hook_dir="$(git -C "${dir}" config core.hooksPath 2>/dev/null || echo "$(git_repo_root "${dir}")/.git/hooks")"
    mkdir -p "${hook_dir}" 2>/dev/null || true
    _ih() { local n="$1" c="$2"; local f="${hook_dir}/${n}"; [[ -f "${f}" ]] && [[ ${FORCE} -ne 1 ]] && { log_warn "钩子已存在: ${n}"; return; }; echo "${c}" > "${f}"; chmod +x "${f}"; log_success "钩子已安装: ${n}"; }

    [[ "${hook_type}" == "all" || "${hook_type}" == "pre-commit" ]] && _ih "pre-commit" '#!/usr/bin/env bash
echo "[pre-commit] 代码检查..."
for f in $(git diff --cached --name-only --diff-filter=ACM | grep -E "\.(sh|bash)$"); do
    command -v shellcheck &>/dev/null && { shellcheck -x "$f" 2>/dev/null || { echo "[ERROR] ShellCheck: $f"; exit 1; }; }
done
for f in $(git diff --cached --name-only --diff-filter=ACM); do
    grep -qiE "(password|secret|api_key|token)\s*[:=]\s*[\"'"'"']?[^\s]" "$f" 2>/dev/null && { echo "[ERROR] 敏感信息: $f"; exit 1; }
done
echo "[pre-commit] 通过"'

    [[ "${hook_type}" == "all" || "${hook_type}" == "commit-msg" ]] && _ih "commit-msg" '#!/usr/bin/env bash
MSG="$(cat "$1")"
echo "$MSG" | grep -qE "^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\(.+\))?: .{1,100}" || { echo "[commit-msg] 需符合 Conventional Commits"; exit 1; }'

    [[ "${hook_type}" == "all" || "${hook_type}" == "pre-push" ]] && _ih "pre-push" '#!/usr/bin/env bash
BRANCH="$(git branch --show-current)"
echo "$BRANCH" | grep -qE "^(main|master|develop)$" && { echo "[pre-push] 禁止直接推送: $BRANCH"; exit 1; }'
    log_success "Git钩子安装完成"
}

git_hook_remove() {
    local dir="${WORK_DIR:-.}" name="${1:-all}"
    local hook_dir; hook_dir="$(git -C "${dir}" config core.hooksPath 2>/dev/null || echo "$(git_repo_root "${dir}")/.git/hooks")"
    if [[ "${name}" == "all" ]]; then for h in pre-commit commit-msg pre-push; do rm -f "${hook_dir}/${h}" 2>/dev/null; done; log_success "所有钩子已移除"
    else rm -f "${hook_dir}/${name}" 2>/dev/null; log_success "钩子已移除: ${name}"; fi
}

git_submodule_add() {
    local url="$1" path="${2:-}"; [[ -z "${url}" ]] && { log_error "请指定子模块URL"; return 1; }
    log_step "添加子模块: ${url}"; local dir="${WORK_DIR:-.}"
    git -C "${dir}" submodule add "${url}" ${path:+"${path}"} 2>&1 | tee -a "${LOG_FILE}"
    git -C "${dir}" commit -m "chore: 添加子模块" 2>/dev/null; log_success "子模块已添加"
}

git_submodule_update() { log_step "更新子模块..."; git -C "${WORK_DIR:-.}" submodule update --init --recursive 2>&1 | tee -a "${LOG_FILE}"; log_success "子模块已更新"; }
git_submodule_list() { log_step "列出子模块..."; git -C "${WORK_DIR:-.}" submodule status 2>/dev/null || log_info "无子模块"; }

git_submodule_remove() {
    local path="$1"; [[ -z "${path}" ]] && { log_error "请指定子模块路径"; return 1; }
    log_step "移除子模块: ${path}"; local dir="${WORK_DIR:-.}"
    git -C "${dir}" submodule deinit -f "${path}" 2>/dev/null; git -C "${dir}" rm -f "${path}" 2>/dev/null
    rm -rf "$(git_repo_root "${dir}")/.git/modules/${path}" 2>/dev/null; log_success "子模块已移除"
}

git_remote_list() { log_step "列出远程仓库..."; git -C "${WORK_DIR:-.}" remote -v 2>/dev/null; }
git_remote_add() { local n="$1" u="$2"; [[ -z "${n}" ]] || [[ -z "${u}" ]] && { log_error "用法: --remote-add 名称 URL"; return 1; }; log_step "添加远程: ${n}"; git -C "${WORK_DIR:-.}" remote add "${n}" "${u}" 2>&1 | tee -a "${LOG_FILE}"; log_success "远程仓库已添加"; }
git_remote_remove() { local n="$1"; [[ -z "${n}" ]] && { log_error "请指定名称"; return 1; }; git -C "${WORK_DIR:-.}" remote remove "${n}" 2>&1 | tee -a "${LOG_FILE}"; log_success "远程仓库已移除"; }
git_remote_set_url() { local n="$1" u="$2"; [[ -z "${n}" ]] || [[ -z "${u}" ]] && { log_error "用法: --remote-set-url 名称 URL"; return 1; }; git -C "${WORK_DIR:-.}" remote set-url "${n}" "${u}" 2>&1 | tee -a "${LOG_FILE}"; log_success "URL已更新"; }

git_stash_save() { local msg="${1:-auto-stash-$(date +%H%M%S)}"; log_step "暂存更改..."; git -C "${WORK_DIR:-.}" stash push -m "${msg}" 2>&1 | tee -a "${LOG_FILE}"; log_success "已暂存"; }
git_stash_pop() { log_step "恢复暂存..."; git -C "${WORK_DIR:-.}" stash pop 2>&1 | tee -a "${LOG_FILE}"; log_success "已恢复"; }
git_stash_list() { log_step "列出暂存..."; git -C "${WORK_DIR:-.}" stash list 2>/dev/null; }

git_cherry_pick() {
    local commit="$1"; [[ -z "${commit}" ]] && { log_error "请指定提交哈希"; return 1; }
    log_step "Cherry-pick: ${commit}"; git -C "${WORK_DIR:-.}" cherry-pick "${commit}" 2>&1 | tee -a "${LOG_FILE}" || { log_error "Cherry-pick冲突!"; return 1; }; log_success "Cherry-pick完成"
}

git_rebase() {
    local target="${1:-${DEFAULT_BRANCH}}"; log_step "Rebase到: ${target}"; local dir="${WORK_DIR:-.}"
    git -C "${dir}" fetch "${REMOTE_NAME}" "${target}" 2>/dev/null || true
    git -C "${dir}" rebase "${REMOTE_NAME}/${target}" 2>&1 | tee -a "${LOG_FILE}" || { log_error "Rebase冲突!"; return 1; }; log_success "Rebase完成"
}

git_resolve_conflicts() {
    local strategy="${1:-ours}"; local dir="${WORK_DIR:-.}"; log_step "解决冲突 (策略: ${strategy})..."
    local conflicts="$(git -C "${dir}" diff --name-only --diff-filter=U 2>/dev/null)"
    [[ -z "${conflicts}" ]] && { log_info "无冲突"; return 0; }
    echo "${conflicts}" | while read -r f; do
        case "${strategy}" in
            ours) git -C "${dir}" checkout --ours "${f}" ;;
            theirs) git -C "${dir}" checkout --theirs "${f}" ;;
            manual) log_info "手动解决: ${f}"; continue ;;
        esac; git -C "${dir}" add "${f}" 2>/dev/null; log_info "已解决: ${f}"
    done
    [[ "${strategy}" != "manual" ]] && { git -C "${dir}" commit --no-edit 2>/dev/null; log_success "冲突已解决"; }
}

git_ci_init_github() {
    local dir="${WORK_DIR:-.}"; log_step "初始化GitHub Actions..."
    mkdir -p "${dir}/.github/workflows" 2>/dev/null || true
    cat > "${dir}/.github/workflows/ci.yml" << 'CI'
name: CI
on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ludeeus/action-shellcheck@master
        with:
          scandir: './scripts'
          severity: warning
  test:
    runs-on: ubuntu-latest
    needs: lint
    steps:
      - uses: actions/checkout@v4
      - run: chmod +x scripts/*.sh && for s in scripts/*.sh; do bash "$s" --help || true; done
  security:
    runs-on: ubuntu-latest
    needs: lint
    steps:
      - uses: actions/checkout@v4
      - run: grep -rn "password\|secret\|api_key" scripts/ --include="*.sh" || true
CI
    log_success "GitHub Actions CI配置已创建"
}

git_ci_init_gitlab() {
    local dir="${WORK_DIR:-.}"; log_step "初始化GitLab CI..."
    cat > "${dir}/.gitlab-ci.yml" << 'CI'
stages: [lint, test, security]
shellcheck:
  stage: lint
  image: koalaman/shellcheck-alpine:latest
  script: [shellcheck scripts/*.sh]
  allow_failure: true
test:
  stage: test
  image: bash:latest
  script: [chmod +x scripts/*.sh, "for s in scripts/*.sh; do bash $s --help || true; done"]
CI
    log_success "GitLab CI配置已创建"
}

git_ci_init_jenkins() {
    local dir="${WORK_DIR:-.}"; log_step "初始化Jenkinsfile..."
    cat > "${dir}/Jenkinsfile" << 'CI'
pipeline {
    agent any
    stages {
        stage('Lint') { steps { sh 'shellcheck scripts/*.sh || true' } }
        stage('Test') { steps { sh 'chmod +x scripts/*.sh && for s in scripts/*.sh; do bash "$s" --help || true; done' } }
        stage('Security') { steps { sh 'grep -rn "password\\|secret" scripts/ --include="*.sh" || true' } }
    }
    post { always { cleanWs() } }
}
CI
    log_success "Jenkinsfile已创建"
}

git_security_scan() {
    local dir="${WORK_DIR:-.}" issues=0
    log_step "执行Git仓库安全扫描..."
    log_info "1. 检查敏感信息..."
    for p in "password\s*[:=]" "api_key\s*[:=]" "secret\s*[:=]" "BEGIN.*PRIVATE KEY"; do
        git -C "${dir}" log --all -p 2>/dev/null | grep -iE "${p}" | head -3 | while read -r l; do log_error "敏感信息: ${l:0:80}"; ((issues++)) || true; done
    done
    log_info "2. 检查大文件..."
    git -C "${dir}" rev-list --objects --all 2>/dev/null | git -C "${dir}" cat-file --batch-check='%(objecttype) %(objectsize) %(rest)' 2>/dev/null | awk '/^blob/ && $2>10485760 {print $2, $3}' | sort -rn | head -5 | while read -r s p; do log_warn "大文件: ${p} ($((s/1048576))MB)"; ((issues++)) || true; done
    log_info "3. 检查提交者..."
    git -C "${dir}" log --format='%ae' 2>/dev/null | sort -u | while read -r e; do echo "${e}" | grep -qE '(localhost|root@)' && { log_warn "可疑提交者: ${e}"; ((issues++)) || true; }; done
    log_info "4. 检查.gitignore..."
    [[ ! -f "$(git_repo_root "${dir}")/.gitignore" ]] && { log_warn "缺少.gitignore"; ((issues++)) || true; }
    log_info "5. 检查未追踪敏感文件..."
    git -C "${dir}" ls-files --others --exclude-standard 2>/dev/null | while read -r f; do echo "${f}" | grep -qiE '\.(pem|key|env)$' && { log_warn "敏感文件: ${f}"; ((issues++)) || true; }; done
    [[ ${issues} -eq 0 ]] && log_success "安全扫描通过" || { log_error "发现 ${issues} 个问题"; return 1; }
}

git_history_cleanup() {
    local target="$1"; [[ -z "${target}" ]] && { log_error "请指定文件路径"; return 1; }
    log_step "从历史中清除: ${target}"; log_warn "此操作将重写Git历史"
    [[ ${INTERACTIVE} -eq 1 ]] && ! confirm "确认永久删除 ${target}?" && return 1
    local dir="${WORK_DIR:-.}"
    git -C "${dir}" filter-branch --force --index-filter "git rm --cached --ignore-unmatch ${target}" --prune-empty --tag-name-filter cat -- --all 2>&1 | tee -a "${LOG_FILE}"
    echo "${target}" >> "$(git_repo_root "${dir}")/.gitignore"; git -C "${dir}" add .gitignore 2>/dev/null
    git -C "${dir}" commit -m "chore: 从历史中清除 ${target}" 2>/dev/null; log_success "历史清理完成"
}

git_status_report() {
    local dir="${WORK_DIR:-.}"; git_is_repo "${dir}" || { log_error "不是Git仓库"; return 1; }
    log_section "Git仓库状态报告"
    echo -e "${BOLD}仓库路径:${NC}     $(git_repo_root "${dir}")"
    echo -e "${BOLD}当前分支:${NC}     $(git_current_branch "${dir}")"
    echo -e "${BOLD}最新提交:${NC}     $(git -C "${dir}" log -1 --oneline 2>/dev/null)"
    echo -e "${BOLD}提交总数:${NC}     $(git -C "${dir}" rev-list --count HEAD 2>/dev/null)"
    echo -e "${BOLD}贡献者数:${NC}     $(git -C "${dir}" shortlog -sn 2>/dev/null | wc -l)"
    echo -e "${BOLD}标签数量:${NC}     $(git -C "${dir}" tag -l 2>/dev/null | wc -l)"
    echo -e "${BOLD}分支数量:${NC}     $(git -C "${dir}" branch -a 2>/dev/null | wc -l)"
    echo ""; echo -e "${BOLD}远程仓库:${NC}"; git -C "${dir}" remote -v 2>/dev/null | while read -r l; do echo -e "  ${l}"; done
    echo ""; echo -e "${BOLD}工作区:${NC}"
    local dirty="$(git -C "${dir}" status --porcelain 2>/dev/null)"
    [[ -z "${dirty}" ]] && log_success "工作区干净" || { local s m u; s="$(echo "${dirty}" | grep -c '^[MADRC]' 2>/dev/null || echo 0)"; m="$(echo "${dirty}" | grep -c '^.[MADRC]' 2>/dev/null || echo 0)"; u="$(echo "${dirty}" | grep -c '^??' 2>/dev/null || echo 0)"; echo -e "  暂存:${GREEN}${s}${NC} 修改:${YELLOW}${m}${NC} 未追踪:${RED}${u}${NC}"; }
    echo ""; echo -e "${BOLD}最近提交:${NC}"; git -C "${dir}" log --oneline -5 --color=always 2>/dev/null | while read -r l; do echo -e "  ${l}"; done
}

git_sync() {
    local dir="${WORK_DIR:-.}"; log_step "同步仓库..."
    local dirty="$(git -C "${dir}" status --porcelain 2>/dev/null)"
    [[ -n "${dirty}" ]] && git_stash_save "auto-sync"
    git -C "${dir}" fetch --all --prune --tags 2>&1 | tee -a "${LOG_FILE}"
    git -C "${dir}" pull --rebase "${REMOTE_NAME}" "$(git_current_branch "${dir}")" 2>&1 | tee -a "${LOG_FILE}"
    [[ -n "${dirty}" ]] && git_stash_pop 2>/dev/null || true
    log_success "仓库同步完成"
}

git_prune() {
    local dir="${WORK_DIR:-.}"; log_step "清理仓库..."
    git -C "${dir}" branch --merged "${DEFAULT_BRANCH}" 2>/dev/null | grep -v -E "(${DEFAULT_BRANCH}|master|develop|\*)" | while read -r b; do b="$(echo "${b}" | xargs)"; [[ -n "${b}" ]] && git -C "${dir}" branch -d "${b}" 2>/dev/null && log_info "已删除: ${b}"; done
    git -C "${dir}" remote prune "${REMOTE_NAME}" 2>/dev/null
    git -C "${dir}" reflog expire --expire=30.days.ago 2>/dev/null
    git -C "${dir}" gc --auto --prune=30.days.ago 2>/dev/null; log_success "仓库清理完成"
}

git_archive() {
    local fmt="${1:-tar.gz}" dir="${WORK_DIR:-.}" branch
    branch="$(git_current_branch "${dir}")"; local output="$(basename "$(git_repo_root "${dir}")")-${branch}.$(date +%Y%m%d).${fmt}"
    log_step "创建归档: ${output}"; git -C "${dir}" archive --format="${fmt}" --output="${output}" "${branch}" 2>&1 | tee -a "${LOG_FILE}"
    log_success "归档已创建: ${output}"
}

git_blame_report() { local f="$1"; [[ -z "${f}" ]] && { log_error "请指定文件"; return 1; }; git -C "${WORK_DIR:-.}" blame --color-by-age "${f}" 2>/dev/null | head -50; }

git_contributors() {
    local dir="${WORK_DIR:-.}" since="${1:-1.year.ago}"; log_step "贡献者统计..."
    echo -e "${CYAN}=== 提交数排行 ===${NC}"; git -C "${dir}" shortlog -sn --since="${since}" --no-merges 2>/dev/null
    echo -e "${CYAN}=== 变更行数排行 ===${NC}"; git -C "${dir}" log --since="${since}" --format='%aN' --numstat 2>/dev/null | awk '/^[a-zA-Z]/ {a=$0;next} {add[a]+=$1;del[a]+=$2} END{for(x in add) printf "%8d +%d -%d %s\n",add[x]+del[x],add[x],del[x],x}' | sort -rn | head -20
}

git_hotspot() { local dir="${WORK_DIR:-.}" since="${1:-6.months.ago}"; log_step "代码热点..."; git -C "${dir}" log --since="${since}" --format="" --name-only 2>/dev/null | sort | uniq -c | sort -rn | head -20; }

git_html_report() {
    local dir="${WORK_DIR:-.}" report="${LOG_DIR}/git_report_${TIMESTAMP}.html"
    log_step "生成Git HTML报告..."
    local name repo branch commits contribs tags branches ltag
    name="$(basename "$(git_repo_root "${dir}")")"; branch="$(git_current_branch "${dir}")"
    commits="$(git -C "${dir}" rev-list --count HEAD 2>/dev/null || echo 0)"
    contribs="$(git -C "${dir}" shortlog -sn 2>/dev/null | wc -l || echo 0)"
    tags="$(git -C "${dir}" tag -l 2>/dev/null | wc -l || echo 0)"
    branches="$(git -C "${dir}" branch -a 2>/dev/null | wc -l || echo 0)"
    ltag="$(git -C "${dir}" describe --tags --abbrev=0 2>/dev/null || echo 'N/A')"
    cat > "${report}" << EOF
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Git Report - ${name}</title>
<style>body{font-family:sans-serif;margin:20px;background:#f5f5f5;color:#333}.s{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:15px;margin:20px 0}.c{background:#fff;border-radius:8px;padding:20px;text-align:center;box-shadow:0 2px 4px rgba(0,0,0,.1)}.c .v{font-size:2em;font-weight:bold;color:#e94560}.c .l{color:#666;margin-top:5px}table{width:100%;border-collapse:collapse;background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 2px 4px rgba(0,0,0,.1)}th{background:#1a1a2e;color:#fff;padding:12px;text-align:left}td{padding:10px 12px;border-bottom:1px solid #eee}tr:hover{background:#f0f0f0}</style></head>
<body><h1>Git Report - ${name}</h1>
<div class="s"><div class="c"><div class="v">${commits}</div><div class="l">Commits</div></div><div class="c"><div class="v">${contribs}</div><div class="l">Contributors</div></div><div class="c"><div class="v">${branches}</div><div class="l">Branches</div></div><div class="c"><div class="v">${tags}</div><div class="l">Tags</div></div><div class="c"><div class="v">${ltag}</div><div class="l">Latest Tag</div></div><div class="c"><div class="v">${branch}</div><div class="l">Branch</div></div></div>
<h2>Recent Commits</h2><table><tr><th>Date</th><th>Author</th><th>Message</th></tr>
EOF
    git -C "${dir}" log --format='<tr><td>%ai</td><td>%aN</td><td>%s</td></tr>' -20 2>/dev/null >> "${report}"
    echo '</table><h2>Contributors</h2><table><tr><th>Author</th><th>Commits</th></tr>' >> "${report}"
    git -C "${dir}" shortlog -sn --no-merges 2>/dev/null | while read -r c n; do echo "<tr><td>${n}</td><td>${c}</td></tr>"; done >> "${report}"
    echo "</table><p style='text-align:center;color:#999;margin-top:30px'>Generated by git_manager.sh v${SCRIPT_VERSION}</p></body></html>" >> "${report}"
    log_success "HTML报告已生成: ${report}"
}

git_worktree_add() { local b="$1" p="${2:-worktrees/${1}}"; [[ -z "${b}" ]] && { log_error "请指定分支"; return 1; }; log_step "添加工作树: ${b}"; git -C "${WORK_DIR:-.}" worktree add "${p}" "${b}" 2>&1 | tee -a "${LOG_FILE}"; log_success "工作树已添加"; }
git_worktree_list() { git -C "${WORK_DIR:-.}" worktree list 2>/dev/null; }
git_worktree_remove() { local p="$1"; [[ -z "${p}" ]] && { log_error "请指定路径"; return 1; }; git -C "${WORK_DIR:-.}" worktree remove "${p}" 2>&1 | tee -a "${LOG_FILE}"; log_success "工作树已移除"; }
git_bisect_start() { local g="$1" b="${2:-HEAD}"; [[ -z "${g}" ]] && { log_error "请指定好的提交"; return 1; }; log_step "启动二分查找..."; git -C "${WORK_DIR:-.}" bisect start "${b}" "${g}" 2>&1 | tee -a "${LOG_FILE}"; }

# ============================================================================
# 参数解析
# ============================================================================
show_usage() {
    cat << 'USAGE'
Git集成管理脚本 v1.0.0

用法: bash git_manager.sh [选项] [参数]

仓库操作:
  --init [DIR] [URL]         初始化Git仓库
  --clone URL [DIR]          克隆仓库
  --status                   仓库状态概览
  --sync                     同步仓库(fetch+pull)
  --prune                    清理仓库(已合并分支/GC)
  --archive [FORMAT]         创建归档

分支管理:
  --branch-list [PATTERN]    列出分支
  --branch-create NAME [BASE] 创建分支
  --branch-switch NAME       切换分支
  --branch-merge SRC [TGT]   合并分支
  --branch-delete NAME       删除分支
  --branch-rename OLD NEW    重命名分支
  --branch-diff BRANCH       比较分支差异

标签管理:
  --tag-list [PATTERN]       列出标签
  --tag-create NAME [MSG]    创建标签
  --tag-delete NAME          删除标签
  --tag-show NAME            显示标签信息
  --version-bump TYPE        版本升级(major/minor/patch)

协作开发:
  --stash-save [MSG]         暂存更改
  --stash-pop                恢复暂存
  --stash-list               列出暂存
  --cherry-pick COMMIT       Cherry-pick
  --rebase [TARGET]          Rebase
  --resolve-conflicts [STRATEGY] 解决冲突(ours/theirs/manual)

远程仓库:
  --remote-list              列出远程仓库
  --remote-add NAME URL      添加远程仓库
  --remote-remove NAME       移除远程仓库
  --remote-set-url NAME URL  设置远程URL

子模块:
  --submodule-add URL [PATH] 添加子模块
  --submodule-update         更新子模块
  --submodule-list           列出子模块
  --submodule-remove PATH    移除子模块

Git钩子:
  --hook-setup [TYPE]        安装Git钩子(all/pre-commit/commit-msg/pre-push)
  --hook-remove [TYPE]       移除Git钩子

CI/CD:
  --ci-github                初始化GitHub Actions
  --ci-gitlab                初始化GitLab CI
  --ci-jenkins               初始化Jenkinsfile

安全与审计:
  --security-scan            安全扫描
  --history-cleanup PATH     从历史中清除文件

分析报告:
  --changelog [FROM] [TO]    生成变更日志
  --commit-stats [SINCE]     提交统计
  --contributors [SINCE]     贡献者统计
  --hotspot [SINCE]          代码热点分析
  --blame FILE               Blame报告
  --html-report              生成HTML报告

其他:
  --worktree-add BRANCH      添加工作树
  --worktree-list            列出工作树
  --worktree-remove PATH     移除工作树
  --bisect-start GOOD [BAD]  启动二分查找

通用选项:
  --dir DIR                  指定工作目录
  --user NAME                设置Git用户名
  --email EMAIL              设置Git邮箱
  --remote-name NAME         远程仓库名(默认:origin)
  --default-branch NAME      默认分支名(默认:main)
  --sign                     启用GPG签名
  --dry-run                  模拟运行
  --force                    强制操作
  --no-push                  不推送到远程
  --verbose                  详细输出
  --non-interactive          非交互模式
  --help                     显示帮助
USAGE
}

parse_args() {
    local action="" action_arg="" action_arg2=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --init)         action="init"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; }; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg2="$1"; shift; } ;;
            --clone)        action="clone"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; }; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg2="$1"; shift; } ;;
            --status)       action="status"; shift ;;
            --sync)         action="sync"; shift ;;
            --prune)        action="prune"; shift ;;
            --archive)      action="archive"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; } ;;
            --branch-list)  action="branch_list"; shift ;;
            --branch-create) action="branch_create"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; }; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg2="$1"; shift; } ;;
            --branch-switch) action="branch_switch"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; } ;;
            --branch-merge) action="branch_merge"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; }; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg2="$1"; shift; } ;;
            --branch-delete) action="branch_delete"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; } ;;
            --branch-rename) action="branch_rename"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; }; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg2="$1"; shift; } ;;
            --branch-diff)  action="branch_diff"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; } ;;
            --tag-list)     action="tag_list"; shift ;;
            --tag-create)   action="tag_create"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; }; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg2="$1"; shift; } ;;
            --tag-delete)   action="tag_delete"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; } ;;
            --tag-show)     action="tag_show"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; } ;;
            --version-bump) action="version_bump"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; } ;;
            --stash-save)   action="stash_save"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; } ;;
            --stash-pop)    action="stash_pop"; shift ;;
            --stash-list)   action="stash_list"; shift ;;
            --cherry-pick)  action="cherry_pick"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; } ;;
            --rebase)       action="rebase"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; } ;;
            --resolve-conflicts) action="resolve_conflicts"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; } ;;
            --remote-list)  action="remote_list"; shift ;;
            --remote-add)   action="remote_add"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; }; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg2="$1"; shift; } ;;
            --remote-remove) action="remote_remove"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; } ;;
            --remote-set-url) action="remote_set_url"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; }; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg2="$1"; shift; } ;;
            --submodule-add) action="submodule_add"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; }; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg2="$1"; shift; } ;;
            --submodule-update) action="submodule_update"; shift ;;
            --submodule-list) action="submodule_list"; shift ;;
            --submodule-remove) action="submodule_remove"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; } ;;
            --hook-setup)   action="hook_setup"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; } ;;
            --hook-remove)  action="hook_remove"; shift ;;
            --ci-github)    action="ci_github"; shift ;;
            --ci-gitlab)    action="ci_gitlab"; shift ;;
            --ci-jenkins)   action="ci_jenkins"; shift ;;
            --security-scan) action="security_scan"; shift ;;
            --history-cleanup) action="history_cleanup"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; } ;;
            --changelog)    action="changelog"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; } ;;
            --commit-stats) action="commit_stats"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; } ;;
            --contributors) action="contributors"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; } ;;
            --hotspot)      action="hotspot"; shift ;;
            --blame)        action="blame"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; } ;;
            --html-report)  action="html_report"; shift ;;
            --worktree-add) action="worktree_add"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; } ;;
            --worktree-list) action="worktree_list"; shift ;;
            --worktree-remove) action="worktree_remove"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; } ;;
            --bisect-start) action="bisect_start"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg="$1"; shift; }; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { action_arg2="$1"; shift; } ;;
            --dir)          WORK_DIR="$2"; shift 2 ;;
            --user)         GIT_USER="$2"; shift 2 ;;
            --email)        GIT_EMAIL="$2"; shift 2 ;;
            --remote-name)  REMOTE_NAME="$2"; shift 2 ;;
            --default-branch) DEFAULT_BRANCH="$2"; shift 2 ;;
            --sign)         SIGN_COMMITS=1; shift ;;
            --dry-run)      DRY_RUN=1; shift ;;
            --force)        FORCE=1; shift ;;
            --no-push)      NO_PUSH=1; shift ;;
            --verbose)      VERBOSE=1; shift ;;
            --non-interactive) INTERACTIVE=0; shift ;;
            --help|-h)      show_usage; exit 0 ;;
            *)              log_error "未知选项: $1"; show_usage; exit 1 ;;
        esac
    done

    git_check_env || exit 1

    case "${action}" in
        init)           git_init_repo "${action_arg}" "${action_arg2}" ;;
        clone)          git_clone_repo "${action_arg}" "${action_arg2}" ;;
        status)         git_status_report ;;
        sync)           git_sync ;;
        prune)          git_prune ;;
        archive)        git_archive "${action_arg}" ;;
        branch_list)    git_branch_list ;;
        branch_create)  git_branch_create "${action_arg}" "${action_arg2}" ;;
        branch_switch)  git_branch_switch "${action_arg}" ;;
        branch_merge)   git_branch_merge "${action_arg}" "${action_arg2}" ;;
        branch_delete)  git_branch_delete "${action_arg}" ;;
        branch_rename)  git_branch_rename "${action_arg}" "${action_arg2}" ;;
        branch_diff)    git_branch_diff "${action_arg}" ;;
        tag_list)       git_tag_list ;;
        tag_create)     git_tag_create "${action_arg}" "${action_arg2}" ;;
        tag_delete)     git_tag_delete "${action_arg}" ;;
        tag_show)       git_tag_show "${action_arg}" ;;
        version_bump)   git_version_bump "${action_arg}" ;;
        stash_save)     git_stash_save "${action_arg}" ;;
        stash_pop)      git_stash_pop ;;
        stash_list)     git_stash_list ;;
        cherry_pick)    git_cherry_pick "${action_arg}" ;;
        rebase)         git_rebase "${action_arg}" ;;
        resolve_conflicts) git_resolve_conflicts "${action_arg}" ;;
        remote_list)    git_remote_list ;;
        remote_add)     git_remote_add "${action_arg}" "${action_arg2}" ;;
        remote_remove)  git_remote_remove "${action_arg}" ;;
        remote_set_url) git_remote_set_url "${action_arg}" "${action_arg2}" ;;
        submodule_add)  git_submodule_add "${action_arg}" "${action_arg2}" ;;
        submodule_update) git_submodule_update ;;
        submodule_list) git_submodule_list ;;
        submodule_remove) git_submodule_remove "${action_arg}" ;;
        hook_setup)     git_hook_setup "${action_arg}" ;;
        hook_remove)    git_hook_remove ;;
        ci_github)      git_ci_init_github ;;
        ci_gitlab)      git_ci_init_gitlab ;;
        ci_jenkins)     git_ci_init_jenkins ;;
        security_scan)  git_security_scan ;;
        history_cleanup) git_history_cleanup "${action_arg}" ;;
        changelog)      git_changelog "${action_arg}" ;;
        commit_stats)   git_commit_stats "${action_arg}" ;;
        contributors)   git_contributors "${action_arg}" ;;
        hotspot)        git_hotspot ;;
        blame)          git_blame_report "${action_arg}" ;;
        html_report)    git_html_report ;;
        worktree_add)   git_worktree_add "${action_arg}" ;;
        worktree_list)  git_worktree_list ;;
        worktree_remove) git_worktree_remove "${action_arg}" ;;
        bisect_start)   git_bisect_start "${action_arg}" "${action_arg2}" ;;
        "")             show_usage ;;
        *)              log_error "未知操作: ${action}"; show_usage; exit 1 ;;
    esac
}

parse_args "$@"
