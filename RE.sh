#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 描述：
#   在 Debian 系统上，将“使用 PHP-FPM 的 Nginx 站点配置”自动转换为
#   “反向代理到指定端口”的配置。
#
#   逻辑保持与原脚本一致：
#     1. 接受两个参数：domain、port
#     2. 仅在配置文件中同时存在：
#        - try_files $uri $uri/ /index.php$request_uri;
#        - fastcgi_pass unix:/var/run/php/phpX.Y-fpm.sock;（X.Y 为系统 PHP 主次版本）
#        时才进行修改，否则不做任何更改并退出
#     3. 使用 awk 将原有 location / 与 PHP 相关 location 块替换为反向代理
#     4. 执行 nginx -t，然后重启 nginx
#
#   改动点：
#     - 不再硬编码 PHP 版本（例如 8.5）
#     - 通过 `php` 命令自动检测 PHP 主次版本（如 8.2），再构造匹配的 fastcgi_pass
#
#   特性：
#     - 幂等、非交互
#     - 关键输出使用 [信息]/[错误] 前缀，并采用天蓝色/绿色/红色标记
# -----------------------------------------------------------------------------

# 颜色定义（天蓝色 / 绿色 / 红色）
COLOR_INFO="\033[36m"   # 天蓝色
COLOR_OK="\033[32m"     # 绿色
COLOR_ERR="\033[31m"    # 红色
COLOR_RESET="\033[0m"

log_info() {
    echo -e "${COLOR_INFO}[信息] $*${COLOR_RESET}"
}

log_success() {
    echo -e "${COLOR_OK}[信息] $*${COLOR_RESET}"
}

log_error() {
    echo -e "${COLOR_ERR}[错误] $*${COLOR_RESET}" >&2
}

die() {
    log_error "$*"
    exit 1
}

#--------------------------- 参数检查 ---------------------------#

if [[ $# -ne 2 ]]; then
    log_error "You must provide exactly two arguments: domain and port."
    echo "Usage: $0 example.com 8080" >&2
    exit 1
fi

domain="$1"
port="$2"

# 检查端口是否为有效数字
if ! [[ "$port" =~ ^[0-9]+$ ]]; then
    die "Port must be a valid number. Given: $port"
fi

file="/etc/nginx/sites-enabled/$domain"
tmp="${file}.tmp"

# 检查 Nginx 配置文件是否存在
if [[ ! -f "$file" ]]; then
    die "Nginx config file not found: $file"
fi

#--------------------------- PHP 版本检测 ---------------------------#

if ! command -v php >/dev/null 2>&1; then
    die "php command not found. Please install PHP and ensure it is in PATH."
fi

# 使用 PHP 自身输出来获取主次版本号，例如 8.2、8.3 等
php_version="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)"
if [[ -z "$php_version" ]]; then
    die "Failed to detect PHP version via 'php' command."
fi

log_info "Detected PHP version: $php_version"

# 构造 fastcgi_pass 的固定字符串，以便在 Nginx 配置中匹配
fastcgi_line="fastcgi_pass unix:/var/run/php/php${php_version}-fpm.sock;"

log_info "Expecting fastcgi_pass line: $fastcgi_line"

#--------------------------- 模式检查（逻辑保持不变） ---------------------------#

# 仅当配置文件中同时存在：
#   try_files $uri $uri/ /index.php$request_uri;
#   fastcgi_pass unix:/var/run/php/phpX.Y-fpm.sock;
# 时才继续，否则不修改
if ! grep -q 'try_files \$uri \$uri/ /index\.php\$request_uri;' "$file" \
   || ! grep -Fq "$fastcgi_line" "$file"; then
    log_info "Pattern not found in $file; no changes made."
    exit 0
fi

log_info "Required PHP-related patterns found, proceeding to transform config."

#--------------------------- 使用 awk 进行配置转换 ---------------------------#

awk -v port="$port" '
/^[[:space:]]*location[[:space:]]*\/[[:space:]]*\{/ {
    in_loc=1
    print "    location / {"
    print "        proxy_pass         http://127.0.0.1:" port ";"
    print "        proxy_http_version 1.1;"
    print "        proxy_set_header   Upgrade $http_upgrade;"
    print "        proxy_set_header   Connection   \"upgrade\";"
    print "        proxy_set_header   Host         $host;"
    print "        proxy_set_header   X-Real-IP    $remote_addr;"
    print "        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;"
    print "        proxy_buffering    off;   # For SSE or WebSocket buffering should be off"
    print "    }"
    next
}
in_loc {
    if ($0 ~ /^\s*\}/) { in_loc=0; skip_php=1 }
    next
}
skip_php && /^[[:space:]]*$/ {
    next
}
skip_php==1 && /^[[:space:]]*location[[:space:]]*~[[:space:]]*\\\.php/ {
    skip_php=2
    next
}
skip_php==2 {
    if ($0 ~ /^\s*\}/) { skip_php=0 }
    next
}
{ print }
' "$file" > "$tmp" && mv "$tmp" "$file"

log_success "Nginx config updated for domain: $domain (proxy to port: $port)."

#--------------------------- 测试并重启 Nginx（逻辑保持与原脚本一致） ---------------------------#

log_info "Running nginx -t to test configuration ..."
nginx -t

# 原脚本未根据 nginx -t 的返回码做条件分支，这里保持逻辑不变，仅输出信息后重启
log_info "Restarting nginx service ..."
systemctl restart nginx

log_success "Completed. Nginx restarted."
