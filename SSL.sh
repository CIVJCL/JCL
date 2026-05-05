#!/bin/bash
# 本脚本在 Debian 13 上为指定域名自动申请 Let's Encrypt SSL 证书，
# 并生成对应的 Nginx HTTPS 配置。脚本为非交互模式，尽量保持幂等，
# 其中通过自动探测当前 PHP-FPM 版本，而不是硬编码具体 PHP 版本。

# --- 颜色定义 ---
BLUE='\033[1;36m'   # 信息
GREEN='\033[1;32m'  # 成功
RED='\033[1;31m'    # 错误
NC='\033[0m'        # 无颜色

# --- 基本检查 ---
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}[错误] 请使用 root 权限运行本脚本。${NC}"
  exit 1
fi

# 检查是否提供了域名作为参数
if [ -z "$1" ]; then
  echo -e "${BLUE}用法: $0 your_domain${NC}"
  exit 1
fi

DOMAIN="$1"
WEB_ROOT="/var/www/$DOMAIN"
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"

echo -e "${BLUE}==========================================================${NC}"
echo -e "${BLUE}  开始为域名申请SSL证书: $DOMAIN   ${NC}"
echo -e "${BLUE}==========================================================${NC}"

# --- 自动探测 PHP-FPM 版本（而非硬编码）---
echo -e "${BLUE}[信息] 正在自动检测 PHP-FPM 版本...${NC}"
PHP_FPM_ID=""

# 优先使用 php CLI 版本信息进行推断
if command -v php >/dev/null 2>&1; then
  PHP_VERSION_CLI="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
  if [ -n "$PHP_VERSION_CLI" ] && [ -S "/var/run/php/php${PHP_VERSION_CLI}-fpm.sock" ]; then
    PHP_FPM_ID="php${PHP_VERSION_CLI}"
  fi
fi

# 如果上一步未检测到，则尝试从现有 sock 文件中推断
if [ -z "$PHP_FPM_ID" ]; then
  CANDIDATE_SOCK="$(ls /var/run/php/php*-fpm.sock 2>/dev/null | head -n1 || true)"
  if [ -n "$CANDIDATE_SOCK" ]; then
    # 例如 php8.3-fpm.sock -> php8.3
    PHP_FPM_ID="$(basename "$CANDIDATE_SOCK" | sed -E 's/\.sock$//' | sed -E 's/-fpm$//')"
  fi
fi

if [ -z "$PHP_FPM_ID" ]; then
  echo -e "${RED}[错误] 无法自动检测 PHP-FPM 版本，请确认 PHP-FPM 已安装并正在运行。${NC}"
  exit 1
fi

echo -e "${GREEN}[成功] 检测到 PHP-FPM 标识: ${PHP_FPM_ID}${NC}"

# --- 创建网站根目录（幂等）---
echo -e "\n${BLUE}[信息] 正在创建网站根目录: $WEB_ROOT...${NC}"
mkdir -p "$WEB_ROOT"
echo -e "${GREEN}[成功] 网站根目录已创建（若之前存在则复用）。${NC}"

# --- 为 HTTP 挑战创建临时 Nginx 配置 ---
echo -e "\n${BLUE}[信息] 正在为 HTTP 挑战创建临时 Nginx 配置...${NC}"
cat > "$NGINX_CONF" << 'EOM'
server {
    listen 80;
    server_name DOMAIN_PLACEHOLDER;
    root WEB_ROOT_PLACEHOLDER;

    location / {
        try_files $uri $uri/ =404;
    }
}
EOM

# 替换占位符
sed -i "s|DOMAIN_PLACEHOLDER|$DOMAIN|g" "$NGINX_CONF"
sed -i "s|WEB_ROOT_PLACEHOLDER|$WEB_ROOT|g" "$NGINX_CONF"
echo -e "${GREEN}[成功] 临时 Nginx 配置已创建于 $NGINX_CONF。${NC}"

# --- 启用 Nginx 站点（幂等处理符号链接）---
echo -e "\n${BLUE}[信息] 正在启用 Nginx 站点...${NC}"
if [ -L "/etc/nginx/sites-enabled/$DOMAIN" ]; then
  echo -e "${BLUE}[信息] Nginx 站点符号链接已存在，跳过创建。${NC}"
else
  ln -s "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN"
  echo -e "${GREEN}[成功] 站点已启用。${NC}"
fi

# --- 重载 Nginx 应用临时配置 ---
echo -e "\n${BLUE}[信息] 正在重载 Nginx 以应用临时配置...${NC}"
systemctl reload nginx
echo -e "${GREEN}[成功] Nginx 已重载。${NC}"

# --- 使用 certbot 自动申请 Let's Encrypt SSL 证书 ---
echo -e "\n${BLUE}[信息] 正在使用 Certbot 请求 Let's Encrypt SSL 证书...${NC}"
certbot certonly --webroot -w "$WEB_ROOT" -d "$DOMAIN" --agree-tos --email root@omnios.world --non-interactive
if [ $? -ne 0 ]; then
  echo -e "${RED}[错误] Certbot 申请证书失败，请检查输出日志。${NC}"
  exit 1
fi
echo -e "${GREEN}[成功] Certbot 处理完成。${NC}"

# --- 删除临时 Nginx 配置（幂等）---
echo -e "\n${BLUE}[信息] 正在移除临时 Nginx 配置...${NC}"
if [ -f "$NGINX_CONF" ]; then
  rm -f "$NGINX_CONF"
  echo -e "${GREEN}[成功] 临时配置已移除。${NC}"
else
  echo -e "${BLUE}[信息] 未发现临时配置文件，可能已被删除，略过。${NC}"
fi

# --- 创建最终 HTTPS Nginx 配置 ---
echo -e "\n${BLUE}[信息] 正在创建最终的 HTTPS Nginx 配置...${NC}"
cat > "$NGINX_CONF" << EOM
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;
    root $WEB_ROOT;
    client_max_body_size 8000M;
    index index.php index.html;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    access_log /var/log/nginx/$DOMAIN-access.log;
    error_log /var/log/nginx/$DOMAIN-error.log;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    location / {
        try_files \$uri \$uri/ /index.php\$request_uri;
    }

    location ~ \.php(?:\$|/) {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        include snippets/fastcgi-php.conf;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_param HTTPS on;
        fastcgi_pass unix:/var/run/php/${PHP_FPM_ID}-fpm.sock;
    }
}
EOM
echo -e "${GREEN}[成功] 最终 Nginx 配置已创建。${NC}"

# --- 再次重载 Nginx 应用最终配置 ---
echo -e "\n${BLUE}[信息] 正在重载 Nginx 以应用最终 HTTPS 配置...${NC}"
systemctl reload nginx
echo -e "${GREEN}[成功] Nginx 已重载。${NC}"

# --- 延迟策略 + 迂回验证 HTTPS 连通性 ---
echo -e "\n${BLUE}[信息] 暂停 5 秒后进行 HTTPS 验证...${NC}"
sleep 5
echo -e "\n${BLUE}[信息] 正在验证 HTTPS 连接: https://$DOMAIN ...${NC}"
curl --head "https://$DOMAIN"

echo -e "\n${BLUE}==========================================================${NC}"
echo -e "${BLUE}  脚本执行完毕。请检查以上输出信息。${NC}"
echo -e "${BLUE}==========================================================${NC}"
