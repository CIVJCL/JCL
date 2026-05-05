#!/usr/bin/env bash
# 2026-04-26T18:00:00+09:00
# 基本信息说明：
# 本脚本用于 Debian 13（Trixie）系统上以非交互、可重复执行（幂等）的方式完成
# Nginx、PHP、Composer、Node.js/nvm/pm2、certbot、SNMP、MariaDB 及常用工具初始化。
#
# 本次修订摘要：
# 1) 修正 Sury PHP 源安装方式：改用 debsuryorg-archive-keyring.deb + signed-by，
#    避免旧 apt.gpg / trusted.gpg.d 方式再次触发 EXPKEYSIG。
# 2) nvm 版本更新为 v0.40.4，并允许已安装 nvm 时进行更新。
# 3) 增强 Debian 13 / trixie 预检、systemd/snapd 兼容判断、APT 锁等待与强制 update 逻辑。
# 4) 保留原脚本组件范围、阶段结构、彩色 SSH 输出风格与最终汇总。
# 5) 对 Composer 安装加入 installer 签名校验；对 snap/certbot 加入更明确的就绪检测与软链。
#
# 文件名建议：Trixie_Init_202604_idempotent.sh

set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

#-----------------------------
# 1. 增强的输出与汇总功能
#-----------------------------
# 颜色定义：保持原脚本 SSH 输出风格，以亮色 ANSI 为主
COLOR_CYAN=$'\033[1;36m'
COLOR_RED=$'\033[1;31m'
COLOR_GREEN=$'\033[1;32m'
COLOR_YELLOW=$'\033[1;33m'
COLOR_NC=$'\033[0m'

SUCCESS_LOG=()
ERROR_LOG=()
CURRENT_STAGE=""
SUMMARY_PRINTED=0

log_task() {
    CURRENT_STAGE="$1"
    printf "\n${COLOR_CYAN}▸▸▸ [阶段开始] %s...${COLOR_NC}\n" "$CURRENT_STAGE"
}

print_summary() {
    if [[ "${SUMMARY_PRINTED}" == "1" ]]; then
      return 0
    fi
    SUMMARY_PRINTED=1

    printf "\n\n${COLOR_CYAN}======================== 执行汇总 ========================${COLOR_NC}\n"

    if ((${#SUCCESS_LOG[@]} > 0)); then
        printf "${COLOR_GREEN}✔ 成功完成的阶段:${COLOR_NC}\n"
        for task in "${SUCCESS_LOG[@]}"; do
            printf "  - %s\n" "$task"
        done
    fi

    if ((${#ERROR_LOG[@]} > 0)); then
        printf "\n${COLOR_RED}✘ 发现问题的阶段:${COLOR_NC}\n"
        for task in "${ERROR_LOG[@]}"; do
            printf "  - %s\n" "$task"
        done
        printf "\n${COLOR_RED}脚本执行期间出现问题，请检查以上红色错误信息。${COLOR_NC}\n"
    else
        printf "\n${COLOR_GREEN}✔ 所有阶段均已成功完成。可以重复执行本脚本以验证幂等性。${COLOR_NC}\n"
    fi

    printf "${COLOR_CYAN}==========================================================${COLOR_NC}\n"
}

on_exit() {
  local rc=$?
  if (( rc != 0 )); then
    ERROR_LOG+=("阶段 '${CURRENT_STAGE}': 未捕获错误导致退出 (退出码: ${rc})")
  fi
  print_summary
}
trap on_exit EXIT

#-----------------------------
# 2. 基础函数
#-----------------------------
log()   { printf '[%s] %s\n' "$(date +'%F %T')" "$*"; }
warn()  { printf "${COLOR_YELLOW}[%s] [WARN] %s${COLOR_NC}\n" "$(date +'%F %T')" "$*" >&2; }

error() {
    local msg="$*"
    printf "${COLOR_RED}[%s] [ERROR] %s${COLOR_NC}\n" "$(date +'%F %T')" "$msg" >&2
    ERROR_LOG+=("阶段 '$CURRENT_STAGE': $msg")
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    error "请以 root 身份运行。"
    exit 1
  fi
}

retry() {
  local tries="$1"; shift
  local delay="$1"; shift
  local attempt=1

  until "$@"; do
    local rc=$?
    if (( attempt >= tries )); then
      error "命令在 ${tries} 次尝试后最终失败 (退出码: ${rc}): $*"
      return "$rc"
    fi
    warn "命令失败（第 ${attempt} 次），${delay}s 后重试：$*"
    sleep "$delay"
    ((attempt++))
  done
}

systemctl_usable() {
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

wait_apt_locks() {
  local timeout_sec="${1:-180}"
  local elapsed=0
  local locks=(
    /var/lib/dpkg/lock
    /var/lib/dpkg/lock-frontend
    /var/lib/apt/lists/lock
    /var/cache/apt/archives/lock
  )

  while (( elapsed < timeout_sec )); do
    local busy=0
    for lock in "${locks[@]}"; do
      if command -v fuser >/dev/null 2>&1 && fuser "$lock" >/dev/null 2>&1; then
        busy=1
        break
      fi
    done

    if (( busy == 0 )); then
      return 0
    fi

    warn "检测到 APT/dpkg 锁占用，等待 5 秒后重试..."
    sleep 5
    elapsed=$((elapsed + 5))
  done

  warn "等待 APT/dpkg 锁超时，将继续尝试执行命令。"
  return 0
}

apt_update_once() {
  local force="${1:-0}"

  wait_apt_locks 180

  if [[ "$force" == "1" ]]; then
    log "检测到 APT 源/密钥变更，强制更新软件包索引..."
    retry 3 5 apt-get update
    return 0
  fi

  if [[ ! -f /var/lib/apt/periodic/update-success-stamp ]]; then
    log "未发现 APT update-success-stamp，正在更新 APT 软件包索引..."
    retry 3 5 apt-get update
    return 0
  fi

  if find /var/lib/apt/periodic/update-success-stamp -mmin +30 -print -quit 2>/dev/null | grep -q .; then
    log "APT 索引超过 30 分钟未更新，正在更新..."
    retry 3 5 apt-get update
  else
    log "APT 索引近期已更新，跳过 apt-get update。"
  fi
}

apt_install() {
  wait_apt_locks 180
  retry 3 5 apt-get install -y "$@"
}

apt_install_no_recommends() {
  wait_apt_locks 180
  retry 3 5 apt-get install -y --no-install-recommends "$@"
}

ensure_line_in_file() {
  local line="$1"
  local file="$2"
  grep -Fxq -- "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}

set_php_ini_kv() {
  local file="$1" key="$2" val="$3"
  if [[ -f "$file" ]]; then
    if grep -qE "^[;[:space:]]*${key}[[:space:]]*=" "$file"; then
      sed -i "s|^[;[:space:]]*${key}[[:space:]]*=.*|${key} = ${val}|" "$file"
    else
      printf '%s = %s\n' "$key" "$val" >> "$file"
    fi
  else
    warn "未发现 $file，跳过 ${key} 设置。"
  fi
}

php_pkg_available() {
  local ver="$1"
  apt-cache policy "php${ver}-cli" 2>/dev/null | awk '/Candidate:/ {print $2}' | grep -vq '^(none)$'
}

detect_codename() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s' "${VERSION_CODENAME:-}"
    return 0
  fi
  lsb_release -sc 2>/dev/null || true
}

check_debian_trixie() {
  local codename=""
  codename="$(detect_codename)"

  if [[ ! -r /etc/debian_version ]]; then
    error "当前系统看起来不是 Debian，脚本仅面向 Debian 13 Trixie。"
    exit 1
  fi

  if [[ "$codename" != "trixie" ]]; then
    warn "检测到系统代号为 '${codename:-未知}'，不是 trixie。脚本将继续执行，但请确认这确实是 Debian 13。"
  else
    log "检测到 Debian 13 Trixie。"
  fi
}

#-----------------------------
# 3. 脚本执行主体
#-----------------------------

# 阶段 0: 预检
log_task "预检与环境检查"
require_root
check_debian_trixie
log "开始执行（幂等/非交互模式）……"
SUCCESS_LOG+=("$CURRENT_STAGE")

# 阶段 1: 系统更新与时区
log_task "系统更新与时区设置"
apt_update_once
wait_apt_locks 180
retry 3 5 apt-get -o Dpkg::Options::="--force-confold" -y upgrade

if systemctl_usable && command -v timedatectl >/dev/null 2>&1; then
  timedatectl set-timezone Asia/Shanghai || warn "设置时区失败，已忽略。"
else
  warn "未检测到可用 systemd/timedatectl，跳过时区设置。"
fi

log "系统更新与时区设置完成。"
SUCCESS_LOG+=("$CURRENT_STAGE")

# 阶段 2: 基础工具
log_task "安装基础工具与 Python 包"
apt_update_once
apt_install_no_recommends \
  vim nano gcc rsync p7zip-full unzip curl wget sshpass nload net-tools tree iftop sudo nmap make git \
  apache2-utils expect yq dnsutils apt-transport-https lsb-release ca-certificates gnupg dirmngr procps psmisc

apt_install python3-pip python3-setuptools

# 保留原脚本注释：如需在 Debian 13 上强制向系统 Python 安装包，请自行确认后再取消注释。
# python3 -m pip install --break-system-packages -q python-docx openpyxl python-pptx PyMuPDF xlrd
# python3 -m pip install --break-system-packages -q openai

log "基础工具安装完成。"
SUCCESS_LOG+=("$CURRENT_STAGE")

# 阶段 3: Node.js (nvm) + pm2
log_task "配置 Node.js (nvm) 与 pm2"
NVM_VERSION="v0.40.4"
NODE_MAJOR="22"
export NVM_DIR="/root/.nvm"

if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
  retry 3 5 bash -c "PROFILE=/dev/null curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | bash"
else
  # 已安装时也允许更新到指定版本；失败不影响后续使用已存在的 nvm。
  retry 3 5 bash -c "PROFILE=/dev/null curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | bash" || warn "nvm 更新失败，将尝试继续使用现有版本。"
fi

# shellcheck source=/dev/null
if [[ -s "$NVM_DIR/nvm.sh" ]]; then
  . "$NVM_DIR/nvm.sh"
else
  error "未找到 $NVM_DIR/nvm.sh，nvm 安装失败。"
  exit 1
fi

if ! command -v nvm >/dev/null 2>&1; then
  error "nvm 未能正确加载。"
  exit 1
fi

if ! command -v node >/dev/null 2>&1 || [[ "$(node -v 2>/dev/null || true)" != v${NODE_MAJOR}.* ]]; then
  retry 3 5 nvm install "$NODE_MAJOR"
fi

nvm use "$NODE_MAJOR" >/dev/null
nvm alias default "$NODE_MAJOR" >/dev/null
retry 3 5 npm install -g pm2

ln -sf "$(command -v node)" /usr/local/bin/node
ln -sf "$(command -v npm)"  /usr/local/bin/npm
ln -sf "$(command -v pm2)"  /usr/local/bin/pm2

cat >/etc/profile.d/nvm.sh <<'EOF'
export NVM_DIR="/root/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
EOF

log "Node.js 环境配置完成。Node: $(node -v), npm: $(npm -v), pm2: $(pm2 -v 2>/dev/null || true)"
SUCCESS_LOG+=("$CURRENT_STAGE")

# 阶段 4: PHP 源 & PHP/扩展 & Composer（优先 PHP 8.5；不可用则自动回退）
log_task "配置 PHP 源、安装 Nginx/PHP 与 Composer"

changed_repo=0
SURY_KEY_DEB="/tmp/debsuryorg-archive-keyring.deb"
SURY_LIST="/etc/apt/sources.list.d/php.list"
SURY_ENTRY="deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ $(detect_codename) main"

# 清理旧脚本可能遗留的 Sury 源文件，避免同一仓库重复定义或继续引用旧 key。
if [[ -f /etc/apt/sources.list.d/sury-php.list ]]; then
  mv /etc/apt/sources.list.d/sury-php.list "/etc/apt/sources.list.d/sury-php.list.disabled.$(date +%Y%m%d%H%M%S)"
  log "已禁用旧 Sury 源文件：/etc/apt/sources.list.d/sury-php.list"
  changed_repo=1
fi

# 旧 key 文件不再作为 apt 源引用；保留文件本身无必要，直接移走以减少误判。
if [[ -f /etc/apt/trusted.gpg.d/php.gpg ]]; then
  mv /etc/apt/trusted.gpg.d/php.gpg "/etc/apt/trusted.gpg.d/php.gpg.disabled.$(date +%Y%m%d%H%M%S)" || true
  log "已移走旧 Sury trusted.gpg.d key 文件。"
  changed_repo=1
fi

# 官方推荐方式：安装 debsuryorg-archive-keyring.deb。
if [[ ! -f /usr/share/keyrings/debsuryorg-archive-keyring.gpg ]]; then
  retry 3 5 curl -fsSL -o "$SURY_KEY_DEB" https://packages.sury.org/debsuryorg-archive-keyring.deb
  retry 3 5 dpkg -i "$SURY_KEY_DEB"
  rm -f "$SURY_KEY_DEB"
  changed_repo=1
else
  # 即使 keyring 已存在，也尝试刷新一次，解决三个月后 key 更新或过期问题。
  retry 3 5 curl -fsSL -o "$SURY_KEY_DEB" https://packages.sury.org/debsuryorg-archive-keyring.deb
  retry 3 5 dpkg -i "$SURY_KEY_DEB"
  rm -f "$SURY_KEY_DEB"
fi

if [[ ! -f "$SURY_LIST" ]] || ! grep -Fxq "$SURY_ENTRY" "$SURY_LIST"; then
  printf '%s\n' "$SURY_ENTRY" > "$SURY_LIST"
  changed_repo=1
fi

if [[ "$changed_repo" == "1" ]]; then
  apt_update_once 1
else
  apt_update_once
fi

PHP_VERSION_SHORT="8.5"
if ! php_pkg_available "$PHP_VERSION_SHORT"; then
  warn "未在当前 APT 索引中发现 php${PHP_VERSION_SHORT}-*，将自动回退到 PHP 8.4。"
  PHP_VERSION_SHORT="8.4"
  apt_update_once
fi

if ! php_pkg_available "$PHP_VERSION_SHORT"; then
  warn "未发现 php${PHP_VERSION_SHORT}-*，将继续回退到 PHP 8.3。"
  PHP_VERSION_SHORT="8.3"
  apt_update_once
fi

if ! php_pkg_available "$PHP_VERSION_SHORT"; then
  error "未能在 APT 索引中发现 PHP 8.5/8.4/8.3 包，请检查 Sury 源是否可用。"
  exit 1
fi

apt_install_no_recommends \
  acl curl fping git graphviz mtr-tiny nginx-full nmap \
  "php${PHP_VERSION_SHORT}-cli" "php${PHP_VERSION_SHORT}-fpm" "php${PHP_VERSION_SHORT}-common" \
  "php${PHP_VERSION_SHORT}-curl" "php${PHP_VERSION_SHORT}-gd" "php${PHP_VERSION_SHORT}-gmp" \
  "php${PHP_VERSION_SHORT}-mbstring" "php${PHP_VERSION_SHORT}-mysql" \
  "php${PHP_VERSION_SHORT}-snmp" "php${PHP_VERSION_SHORT}-xml" "php${PHP_VERSION_SHORT}-zip" \
  python3-dotenv python3-pymysql python3-redis rrdtool snmp snmpd whois

if command -v "php${PHP_VERSION_SHORT}" >/dev/null 2>&1; then
  update-alternatives --install /usr/bin/php php "/usr/bin/php${PHP_VERSION_SHORT}" 85 || true
  update-alternatives --set php "/usr/bin/php${PHP_VERSION_SHORT}" || true
fi

if systemctl_usable; then
  systemctl enable --now nginx >/dev/null 2>&1 || warn "nginx enable/start 失败，请稍后手动检查。"
  systemctl enable --now "php${PHP_VERSION_SHORT}-fpm" >/dev/null 2>&1 || warn "php${PHP_VERSION_SHORT}-fpm enable/start 失败，请稍后手动检查。"
fi

# Composer：安装前校验 installer 签名，避免下载异常或被污染。
if ! command -v composer >/dev/null 2>&1; then
  EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"
  php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
  ACTUAL_SIGNATURE="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"

  if [[ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]]; then
    rm -f composer-setup.php
    error "Composer installer 签名校验失败，已中止安装。"
    exit 1
  fi

  php composer-setup.php --install-dir=/usr/local/bin --filename=composer
  rm -f composer-setup.php
fi

log "Nginx, PHP ${PHP_VERSION_SHORT} 及 Composer 安装配置完成。"
SUCCESS_LOG+=("$CURRENT_STAGE")

# 阶段 5: snapd 与 certbot
log_task "安装与配置 snapd 及 certbot"
apt_install snapd

if systemctl_usable; then
  systemctl enable --now snapd.socket >/dev/null 2>&1 || true
  systemctl enable --now snapd.service >/dev/null 2>&1 || true
else
  warn "未检测到可用 systemd，snapd 在容器/裁剪环境中可能无法正常工作。"
fi

if command -v snap >/dev/null 2>&1; then
  log "等待 snap 系统服务就绪..."
  timeout 180 bash -c 'until snap wait system seed >/dev/null 2>&1; do sleep 2; done' || warn "snap seed 等待超时，继续尝试安装。"

  # Snapcraft 当前建议先安装 snapd snap，以获得较新的 snapd。
  retry 3 10 snap install snapd || warn "snap install snapd 失败，继续尝试 core/certbot。"
  retry 3 10 snap install core || true
  retry 3 10 snap refresh core || true

  if ! snap list 2>/dev/null | awk '{print $1}' | grep -Fxq 'certbot'; then
    retry 5 10 snap install --classic certbot
  fi

  ln -sf /snap/bin/certbot /usr/bin/certbot

  if ! command -v certbot >/dev/null 2>&1; then
    error "certbot 未能正确安装到 PATH。"
    exit 1
  fi

  log "Certbot 安装成功：$(certbot --version 2>/dev/null || true)"
else
  error "snap 命令不可用，无法通过 snap 安装 certbot。"
  exit 1
fi

SUCCESS_LOG+=("$CURRENT_STAGE")

# 阶段 6: SNMP 配置
log_task "配置 SNMP 服务"
apt_install snmpd snmp

if systemctl_usable; then
  systemctl stop snmpd >/dev/null 2>&1 || true
fi

cat > /etc/snmp/snmpd.conf <<'EOF'
sysLocation    Foundry
sysContact     Eiswein.OS@outlook.com
sysServices    72
agentAddress   udp:161,udp6:[::1]:161
view all included .1 80
rouser AzureEC priv
EOF

if ! grep -q 'AzureEC' /var/lib/snmp/snmpd.conf 2>/dev/null; then
  net-snmp-create-v3-user -ro -A "publicAzure+++++++" -a SHA -X "publicAzure+++++++" -x AES AzureEC
else
  log "检测到 SNMPv3 用户 AzureEC 已存在，跳过创建。"
fi

if systemctl_usable; then
  systemctl enable --now snmpd >/dev/null 2>&1 || warn "snmpd enable/start 失败，请稍后手动检查。"
  systemctl restart snmpd >/dev/null 2>&1 || warn "snmpd restart 失败，请稍后手动检查。"
fi

log "SNMP 配置已更新。尝试 snmpwalk 自检……"
snmpwalk -v3 -u AzureEC -l authPriv -a SHA -A 'publicAzure+++++++' -x AES -X 'publicAzure+++++++' localhost \
  || warn "snmpwalk 自检失败，请稍后手动核查配置。"

SUCCESS_LOG+=("$CURRENT_STAGE")

# 阶段 7: MariaDB（使用 Debian 官方推荐版本）
log_task "安装 MariaDB（使用 Debian 官方仓库）"

# 如果存在旧脚本遗留的第三方 MariaDB 源，优雅地禁用它。
if [[ -f /etc/apt/sources.list.d/mariadb.list ]]; then
  if grep -q 'archive.mariadb.org' /etc/apt/sources.list.d/mariadb.list 2>/dev/null; then
    mv /etc/apt/sources.list.d/mariadb.list "/etc/apt/sources.list.d/mariadb.list.disabled.$(date +%Y%m%d%H%M%S)"
    log "发现旧的 MariaDB 外部仓库配置，已禁用：/etc/apt/sources.list.d/mariadb.list"
    apt_update_once 1
  fi
fi

apt_update_once
apt_install mariadb-server mariadb-client

if systemctl_usable; then
  systemctl enable --now mariadb >/dev/null 2>&1 || warn "MariaDB enable/start 失败，请稍后手动检查。"
fi

log "MariaDB 安装完成。版本信息：$(mariadb --version || true)"
log "重要提示：请手动运行 'mariadb-secure-installation' 来加固您的数据库。"
SUCCESS_LOG+=("$CURRENT_STAGE")

# 阶段 8: PHP ini 调优（自动检测当前 PHP 主版本）
log_task "调优 PHP 配置 (ini)"

PHP_INI_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "${PHP_VERSION_SHORT}")"
CLI_INI="/etc/php/${PHP_INI_VERSION}/cli/php.ini"
FPM_INI="/etc/php/${PHP_INI_VERSION}/fpm/php.ini"

log "检测到 PHP 版本：${PHP_INI_VERSION}，即将调优 ${CLI_INI} 与 ${FPM_INI}。"

for ini in "$CLI_INI" "$FPM_INI"; do
  set_php_ini_kv "$ini" upload_max_filesize  "8000M"
  set_php_ini_kv "$ini" post_max_size        "8000M"
  set_php_ini_kv "$ini" memory_limit         "800M"
  set_php_ini_kv "$ini" max_execution_time   "300"
  set_php_ini_kv "$ini" max_input_time       "300"
  set_php_ini_kv "$ini" max_file_uploads     "500"
done

if systemctl_usable; then
  systemctl restart "php${PHP_INI_VERSION}-fpm" 2>/dev/null || warn "php${PHP_INI_VERSION}-fpm 服务不存在或未安装，已跳过重启。"
fi

log "PHP.ini 配置调优完成。"
SUCCESS_LOG+=("$CURRENT_STAGE")

#-----------------------------
# 4. 收尾
#-----------------------------
print_summary
