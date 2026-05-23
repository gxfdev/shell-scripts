# Shell Scripts - Linux 服务器自动化运维脚本集合

> 一套完整的 Linux 服务器自动化运维脚本，支持多种操作系统，覆盖系统初始化、自动备份、批量处理、定时任务、服务管理、自动部署等核心运维场景。

**仓库地址**: https://github.com/gxfdev/shell-scripts

---

## 支持的操作系统

| 操作系统 | 版本 | 包管理器 | 服务管理 | 防火墙 | 状态 |
|---------|------|---------|---------|--------|------|
| CentOS / RHEL | 7/8/9 | yum/dnf | systemd | firewalld | ✅ 完全支持 |
| Rocky Linux | 8/9 | dnf | systemd | firewalld | ✅ 完全支持 |
| AlmaLinux | 8/9 | dnf | systemd | firewalld | ✅ 完全支持 |
| Fedora | 35+ | dnf | systemd | firewalld | ✅ 完全支持 |
| Ubuntu | 18.04/20.04/22.04/24.04 | apt | systemd | ufw | ✅ 完全支持 |
| Debian | 10/11/12 | apt | systemd | ufw/iptables | ✅ 完全支持 |
| Alpine Linux | 3.x | apk | OpenRC | iptables | ✅ 完全支持 |
| Arch Linux | rolling | pacman | systemd | iptables | ✅ 完全支持 |
| Manjaro | rolling | pacman | systemd | iptables | ✅ 完全支持 |
| openSUSE | Leap/Tumbleweed | zypper | systemd | firewalld | ✅ 完全支持 |

---

## 脚本列表

### 1. 系统初始化脚本 (`system_init.sh`)

一键完成新服务器的初始化配置，自动检测操作系统并适配。

**功能模块：**
- 操作系统自动检测与适配
- 镜像源配置（阿里云镜像）
- 基础软件包安装
- 内核参数优化（网络/文件系统/内存/安全）
- 网络配置优化（DNS/网卡参数）
- 用户与权限管理
- SSH 安全加固（密钥认证/禁用root/加密算法/Fail2ban）
- 防火墙配置（firewalld/ufw/iptables）
- 时间同步（Chrony）
- Swap 配置
- 磁盘与文件系统优化
- 系统安全加固（密码策略/SUID检查/审计/禁用不必要服务）
- Docker 环境安装
- 开发工具安装（Go等）
- 系统信息报告
- 配置回滚功能

**使用方法：**
```bash
# 执行全部初始化
sudo bash system_init.sh --all

# 仅配置镜像源
sudo bash system_init.sh --mirror

# 仅加固SSH
sudo bash system_init.sh --ssh

# 模拟运行（不实际修改系统）
sudo bash system_init.sh --all --dry-run

# 使用配置文件
sudo bash system_init.sh --all --config system_init.cfg

# 回滚上次初始化
sudo bash system_init.sh --rollback
```

**各操作系统差异：**

| 功能 | CentOS/RHEL | Ubuntu/Debian | Alpine | Arch | openSUSE |
|------|------------|---------------|--------|------|----------|
| 镜像源 | yum.repos.d | sources.list | apk/repositories | mirrorlist | zypper repos |
| 包安装 | dnf/yum | apt-get | apk | pacman | zypper |
| 服务管理 | systemctl | systemctl | rc-service | systemctl | systemctl |
| 防火墙 | firewalld | ufw | iptables | iptables | firewalld |
| SSH服务名 | sshd | ssh | sshd | sshd | sshd |
| 管理用户组 | wheel | sudo | wheel | wheel | wheel |
| 配置目录 | /etc/sysconfig | /etc/default | /etc/conf.d | /etc | /etc/sysconfig |

---

### 2. 自动备份脚本 (`auto_backup.sh`)

支持全量/增量备份，覆盖文件、数据库、配置、Docker环境。

**功能模块：**
- 文件/目录全量与增量备份
- 数据库备份（MySQL/PostgreSQL/MongoDB/Redis）
- 系统配置文件备份
- Docker 容器与卷备份
- 远程备份传输（RSYNC/SCP/S3）
- 备份加密（AES-256-CBC）
- 备份压缩（xz/gz/bz2/zst）
- 备份轮转与清理（日/周/月策略）
- 备份完整性校验（SHA256/MD5）
- 备份恢复功能
- 邮件/钉钉/企业微信通知

**使用方法：**
```bash
# 执行全部备份
sudo bash auto_backup.sh --all

# 仅备份数据库
sudo bash auto_backup.sh --database

# 增量备份
sudo bash auto_backup.sh --incremental

# 从备份恢复
sudo bash auto_backup.sh --restore /data/backups/hostname/20240101/files/etc.tar.xz

# 列出所有备份
bash auto_backup.sh --list

# 校验备份完整性
bash auto_backup.sh --verify

# 使用配置文件
sudo bash auto_backup.sh --all --config-file backup.cfg
```

**配置文件示例 (`backup.cfg`)：**
```
backup_root=/data/backups
compress_format=xz
encrypt_backup=1
encrypt_pass=YourStrongPassword
remote_type=rsync
remote_host=192.168.1.100
remote_user=backup
remote_path=/backup
mysql_host=localhost
mysql_user=root
mysql_pass=YourMySQLPassword
notify_type=dingtalk
notify_webhook=https://oapi.dingtalk.com/robot/send?access_token=xxx
retention_days=30
```

---

### 3. 批量处理脚本 (`batch_process.sh`)

多主机并行/串行批量操作，支持 Ansible 风格的主机清单。

**功能模块：**
- 批量命令执行（SSH并行/串行）
- 批量文件分发与收集（SCP/RSYNC）
- 批量软件包安装/更新/卸载
- 批量服务管理
- 批量用户管理
- 批量系统巡检
- 批量系统监控
- 批量安全检查
- 批量日志收集
- 批量配置同步

**使用方法：**
```bash
# 批量执行命令
bash batch_process.sh --hosts hosts.txt --exec "uptime"

# 批量分发文件
bash batch_process.sh --hosts hosts.txt --copy-local /tmp/file --remote-dir /tmp

# 批量收集远程文件
bash batch_process.sh --hosts hosts.txt --copy-remote /var/log/syslog --local-dir /tmp/logs

# 批量安装软件
bash batch_process.sh --hosts hosts.txt --install nginx

# 批量服务管理
bash batch_process.sh --hosts hosts.txt --service restart nginx

# 批量系统巡检
bash batch_process.sh --hosts hosts.txt --check

# 批量安全检查
bash batch_process.sh --hosts hosts.txt --security-check

# 指定组操作
bash batch_process.sh --hosts hosts.txt --group web --exec "nginx -t"
```

**主机清单格式 (`hosts.txt`)：**
```
192.168.1.10
192.168.1.11 ssh_port=2222 ansible_user=admin

[web]
192.168.1.10
192.168.1.11

[db]
192.168.1.20
192.168.1.21

[web:vars]
ansible_user=deploy
```

---

### 4. 定时任务管理脚本 (`cron_manager.sh`)

统一管理 Cron 定时任务和 Systemd Timer，支持模板和冲突检测。

**功能模块：**
- 定时任务 CRUD（创建/读取/更新/删除）
- 定时任务模板管理
- 定时任务分组与标签
- Cron 表达式验证与人类可读转换
- Systemd Timer 管理
- 定时任务冲突检测
- 健康检查
- 备份与恢复
- 可视化时间表
- 执行结果通知

**使用方法：**
```bash
# 添加定时任务
bash cron_manager.sh --add --name "daily_backup" --schedule "0 2 * * *" --command "/opt/scripts/backup.sh"

# 使用别名
bash cron_manager.sh --add --name "hourly_check" --schedule "@hourly" --command "/opt/scripts/check.sh"

# 列出所有任务
bash cron_manager.sh --list

# 删除任务
bash cron_manager.sh --remove daily_backup

# 禁用/启用任务
bash cron_manager.sh --disable daily_backup
bash cron_manager.sh --enable daily_backup

# 检测冲突
bash cron_manager.sh --detect-conflicts

# 可视化时间表
bash cron_manager.sh --timeline

# 创建 Systemd Timer
sudo bash cron_manager.sh --systemd-add --name "myapp-sync" --schedule "*/30 * * * *" --command "/opt/app/sync.sh"

# 初始化默认模板
bash cron_manager.sh --template-init

# 从模板创建任务
bash cron_manager.sh --template-load system_backup
```

**Cron 表达式速查：**
```
┌──────── 分钟 (0-59)
│ ┌────── 小时 (0-23)
│ │ ┌──── 日 (1-31)
│ │ │ ┌── 月 (1-12)
│ │ │ │ ┌ 星期 (0-7, 0和7都是周日)
│ │ │ │ │
* * * * * command

@yearly    = 0 0 1 1 *       (每年1月1日午夜)
@monthly   = 0 0 1 * *       (每月1日午夜)
@weekly    = 0 0 * * 0       (每周日午夜)
@daily     = 0 0 * * *       (每天午夜)
@hourly    = 0 * * * *       (每小时)
@every5min = */5 * * * *     (每5分钟)
```

---

### 5. 服务管理脚本 (`service_manager.sh`)

跨平台服务管理，支持 systemd 和 OpenRC，含健康检查和故障自愈。

**功能模块：**
- 服务启停/重启/重载
- 服务自启动管理
- 服务状态查询与监控
- 服务详细信息展示
- 服务依赖分析
- 服务日志查看与跟踪
- HTTP/端口/自定义健康检查
- 故障自动重启（自愈）
- 服务资源限制配置
- 服务性能分析
- 批量服务操作
- 服务端口映射

**使用方法：**
```bash
# 启动/停止/重启服务
sudo bash service_manager.sh --start nginx
sudo bash service_manager.sh --stop nginx
sudo bash service_manager.sh --restart nginx

# 查看服务状态
bash service_manager.sh --status nginx

# 查看详细信息
bash service_manager.sh --info nginx

# 查看服务日志
bash service_manager.sh --log nginx 100
bash service_manager.sh --follow nginx

# 健康检查（含自动重启）
sudo bash service_manager.sh --health nginx --health-url http://localhost:8080/health --auto-restart

# 依赖分析
bash service_manager.sh --deps nginx

# 性能分析
bash service_manager.sh --analyze nginx

# 设置资源限制
sudo bash service_manager.sh --limits nginx 200% 512M

# 监控多个服务
bash service_manager.sh --watch nginx mysql redis --watch-interval 3

# 列出所有服务
bash service_manager.sh --list

# 服务端口映射
bash service_manager.sh --ports

# 批量操作
sudo bash service_manager.sh --batch-restart nginx php-fpm mysql
```

**各操作系统服务管理差异：**

| 操作 | systemd (CentOS/Ubuntu/Arch) | OpenRC (Alpine) |
|------|-----|--------|
| 启动 | systemctl start svc | rc-service svc start |
| 停止 | systemctl stop svc | rc-service svc stop |
| 重启 | systemctl restart svc | rc-service svc restart |
| 状态 | systemctl status svc | rc-service svc status |
| 自启动 | systemctl enable svc | rc-update add svc default |
| 禁用 | systemctl disable svc | rc-update del svc default |
| 日志 | journalctl -u svc | /var/log/svc.log |

---

### 6. 自动部署与发布脚本 (`auto_deploy.sh`)

支持多环境部署、Docker构建、灰度发布、自动回滚。

**功能模块：**
- Git 仓库拉取（分支/标签/提交）
- 多环境部署（dev/staging/production）
- 自动构建（Node.js/Go/Java/Python/Rust/Makefile）
- Docker 镜像构建与推送
- 符号链接部署
- 健康检查与自动回滚
- 版本管理与回滚
- 部署锁与并发控制
- 部署历史记录
- 部署通知

**使用方法：**
```bash
# 部署最新版本
sudo bash auto_deploy.sh --deploy --app myapp --repo https://github.com/user/repo.git --branch main

# 部署指定标签
sudo bash auto_deploy.sh --deploy --app myapp --repo https://github.com/user/repo.git --tag v1.2.0

# Docker部署
sudo bash auto_deploy.sh --deploy --app myapp --repo https://github.com/user/repo.git --docker --docker-image myapp --docker-registry registry.example.com

# 使用配置文件
sudo bash auto_deploy.sh --deploy --config deploy.cfg

# 回滚到上一版本
sudo bash auto_deploy.sh --rollback

# 回滚到指定版本
sudo bash auto_deploy.sh --rollback 20240101_120000

# 列出版本
bash auto_deploy.sh --list

# 查看部署历史
bash auto_deploy.sh --history

# 模拟部署
bash auto_deploy.sh --deploy --app myapp --repo https://github.com/user/repo.git --dry-run
```

**配置文件示例 (`deploy.cfg`)：**
```
app_name=myapp
environment=production
git_repo=https://github.com/user/repo.git
git_branch=main
build_cmd=npm run build
health_check_url=http://localhost:8080/health
health_check_retries=5
auto_rollback=1
keep_releases=5
docker_build=1
docker_image=myapp
docker_registry=registry.example.com
notify_type=dingtalk
notify_webhook=https://oapi.dingtalk.com/robot/send?access_token=xxx
```

---

## 快速开始

```bash
# 克隆仓库
git clone https://github.com/gxfdev/shell-scripts.git
cd shell-scripts

# 赋予执行权限
chmod +x scripts/*.sh

# 系统初始化（新服务器首次使用）
sudo bash scripts/system_init.sh --all --dry-run  # 先模拟
sudo bash scripts/system_init.sh --all             # 实际执行

# 设置自动备份
sudo bash scripts/auto_backup.sh --all --config-file backup.cfg

# 添加定时备份任务
bash scripts/cron_manager.sh --add --name "daily_backup" --schedule "0 2 * * *" \
  --command "/path/to/shell-scripts/scripts/auto_backup.sh --all --config-file /etc/backup.cfg" \
  --notify --webhook "https://oapi.dingtalk.com/robot/send?access_token=xxx"
```

---

## 目录结构

```
shell-scripts/
├── scripts/
│   ├── system_init.sh      # 系统初始化脚本
│   ├── auto_backup.sh      # 自动备份脚本
│   ├── batch_process.sh    # 批量处理脚本
│   ├── cron_manager.sh     # 定时任务管理脚本
│   ├── service_manager.sh  # 服务管理脚本
│   └── auto_deploy.sh      # 自动部署与发布脚本
├── configs/                # 配置文件示例
└── README.md
```

---

## 注意事项

1. **所有脚本需要 root 权限运行**（除查看类操作外），请使用 `sudo` 执行
2. **建议先使用 `--dry-run` 模拟运行**，确认无误后再实际执行
3. **系统初始化脚本会修改系统配置**，建议在全新服务器上使用，生产环境请谨慎
4. **备份脚本中的数据库密码**建议使用配置文件，避免在命令行中暴露
5. **批量操作前**请确认主机清单正确，建议先用少量主机测试
6. **部署脚本**建议配合 CI/CD 流水线使用

---

## License

MIT License
