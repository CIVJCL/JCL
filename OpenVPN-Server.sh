#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# OpenVPN 2.6 (Debian 13 / Trixie) 自动化部署脚本 - 优化版
#
# 特性：
#   - UDP 服务器（默认 443/udp），端口可自定义
#   - Easy-RSA PKI：CA / 服务端证书 / DH / CRL
#   - 控制信道：tls-crypt-v2（每客户端独立 key）
#   - 数据信道：AEAD（AES-256-GCM / CHACHA20-POLY1305）
#   - 优先启用 DCO（若内核模块可用）
#   - 可选 PAM 用户名/密码认证（系统账户）
#   - IPv4/IPv6 转发与 iptables/ip6tables NAT
#   - 幂等，可重复执行
#
# 用法：
#   ./deploy-openvpn.sh [PORT] [Auth]
#   PORT  默认 443
#   Auth  传入 "Auth"（大小写不敏感）时启用证书 + 用户名/密码双因子
# -----------------------------------------------------------------------------

set -euo pipefail

# -----------------------
# 彩色日志输出
# -----------------------
C_BLUE="\e[38;5;39m"
C_GREEN="\e[32m"
C_RED="\e[31m"
C_RESET="\e[0m"

log_info() { echo -e "${C_BLUE}[信息] $*${C_RESET}"; }
log_ok()   { echo -e "${C_GREEN}[信息] $*${C_RESET}"; }
log_err()  { echo -e "${C_RED}[错误] $*${C_RESET}" >&2; }

# -----------------------
# 基础检查
# -----------------------
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  log_err "请以 root 身份运行此脚本。"
  exit 1
fi

SERVICE="OpenVPN-SSL-UDP"
BASE="/root/OpenVPN-SSL"
PORT="${1:-443}"
AUTH_MODE="${2:-}"

export DEBIAN_FRONTEND=noninteractive
umask 077

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  log_err "端口参数无效：${PORT}。允许范围为 1-65535。"
  exit 1
fi

AUTH_FLAG=0
if printf '%s' "$AUTH_MODE" | grep -qiE '^auth$'; then
  AUTH_FLAG=1
fi

log_info "准备在 Debian 13 环境中部署 OpenVPN 2.6 服务端（端口：${PORT}/udp）..."

# -----------------------
# 依赖安装
# -----------------------
log_info "更新软件源并安装依赖..."
apt update -y >/dev/null

# 为 DCO 尽量补齐 DKMS 所需环境；headers 缺失时允许继续走传统 tun
apt install -y \
  openvpn \
  openvpn-dco-dkms \
  easy-rsa \
  curl \
  dkms \
  iptables \
  iptables-persistent >/dev/null

apt install -y "linux-headers-$(uname -r)" >/dev/null 2>&1 || \
  log_info "未安装到当前内核匹配的 headers，若 DCO DKMS 未构建成功将自动回退到传统 tun 模式。"

ln -sf /usr/share/easy-rsa/easyrsa /usr/local/bin/easyrsa || true

# 目录规划：
#   /etc/openvpn/${SERVICE}         私有材料（server.key / tc2-server.key 等）
#   /etc/openvpn/server             systemd server 配置目录 + 可读 CRL
#   /var/lib/openvpn/${SERVICE}     运行状态文件（IPP / status）
CONF_PRIV_DIR="/etc/openvpn/${SERVICE}"
CONF_SERVER_DIR="/etc/openvpn/server"
STATE_DIR="/var/lib/openvpn/${SERVICE}"

install -d -m 755 "$CONF_SERVER_DIR"
install -d -m 700 "$CONF_PRIV_DIR"
install -d -m 750 -o nobody -g nogroup "$STATE_DIR"

# -----------------------
# DCO 检测
# -----------------------
DCO_AVAILABLE=0
if modinfo ovpn-dco >/dev/null 2>&1; then
  if modprobe ovpn-dco >/dev/null 2>&1; then
    DCO_AVAILABLE=1
    log_ok "检测到 ovpn-dco 内核模块，OpenVPN 将在条件满足时自动启用 DCO。"
  else
    log_info "检测到 ovpn-dco 模块但加载失败，将继续使用传统 tun 模式。"
  fi
else
  log_info "未检测到 ovpn-dco 模块，将使用传统 tun 模式。"
fi

# -----------------------
# 清理旧实例
# -----------------------
log_info "清理旧的 OpenVPN 实例与配置..."
systemctl disable --now "openvpn@${SERVICE}" >/dev/null 2>&1 || true
systemctl disable --now "openvpn-server@${SERVICE}" >/dev/null 2>&1 || true
rm -f "/etc/openvpn/${SERVICE}.conf" >/dev/null 2>&1 || true
rm -f "${CONF_SERVER_DIR}/${SERVICE}.conf" >/dev/null 2>&1 || true
rm -rf "/etc/systemd/system/openvpn@${SERVICE}.service.d" >/dev/null 2>&1 || true
rm -rf "/etc/systemd/system/openvpn-server@${SERVICE}.service.d" >/dev/null 2>&1 || true

# -----------------------
# PKI 初始化
# -----------------------
log_info "初始化/复用 Easy-RSA PKI（CA / 服务端证书 / DH / CRL）..."
[ -d "$BASE" ] || make-cadir "$BASE"
cd "$BASE"

[ -d pki ] || easyrsa init-pki
[ -f pki/ca.crt ] || EASYRSA_BATCH=1 EASYRSA_REQ_CN="OpenVPN-SSL-CA" easyrsa --batch build-ca nopass
[ -f pki/dh.pem ] || easyrsa gen-dh

SERVER_CN="${SERVICE}-server"
[ -f "pki/issued/${SERVER_CN}.crt" ] || easyrsa --batch build-server-full "${SERVER_CN}" nopass

# CRL 每次都重新生成，确保吊销立即生效
EASYRSA_BATCH=1 easyrsa gen-crl

# -----------------------
# 安装证书与密钥
# -----------------------
log_info "安装服务端证书、私钥、DH 参数与 CRL..."
# 私有材料
install -m 600 -D "$BASE/pki/ca.crt"                   "${CONF_PRIV_DIR}/ca.crt"
install -m 600 -D "$BASE/pki/issued/${SERVER_CN}.crt"  "${CONF_PRIV_DIR}/server.crt"
install -m 600 -D "$BASE/pki/private/${SERVER_CN}.key" "${CONF_PRIV_DIR}/server.key"
install -m 600 -D "$BASE/pki/dh.pem"                   "${CONF_PRIV_DIR}/dh.pem"

# CRL 单独放在可穿越目录，且文件本身可读；否则 user nobody 后无法读取
CRL_PATH="${CONF_SERVER_DIR}/${SERVICE}.crl.pem"
install -m 644 -D "$BASE/pki/crl.pem" "$CRL_PATH"

# -----------------------
# tls-crypt-v2
# -----------------------
log_info "配置 tls-crypt-v2 控制信道密钥..."
TC2_SERVER_KEY="${CONF_PRIV_DIR}/tc2-server.key"
if [ ! -f "$TC2_SERVER_KEY" ]; then
  openvpn --genkey tls-crypt-v2-server "$TC2_SERVER_KEY"
  chmod 600 "$TC2_SERVER_KEY"
fi

# -----------------------
# IPv4 / IPv6 出口网卡探测
# -----------------------
OUT_IF="$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}')"
if [ -z "${OUT_IF:-}" ]; then
  OUT_IF="$(ip route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}')"
fi

OUT_IF6="$(ip -6 route show default 2>/dev/null | awk '{print $5; exit}' || true)"
ENABLE_V6=0
if [ -n "${OUT_IF6:-}" ] && ip6tables -t nat -L >/dev/null 2>&1; then
  ENABLE_V6=1
fi

if [ "$ENABLE_V6" -eq 1 ]; then
  V6_BLOCK='server-ipv6 fd00:beef:1234:5680::/64'
  V6_PUSH=$'push "route-ipv6 ::/0"\npush "dhcp-option DNS6 2606:4700:4700::1111"\npush "dhcp-option DNS6 2606:4700:4700::1001"'
  log_info "检测到 IPv6 出口 ${OUT_IF6}，将启用 IPv6 VPN 网络。"
else
  V6_BLOCK=''
  V6_PUSH=''
  log_info "未启用 IPv6 转发或 NAT，将仅配置 IPv4 VPN 网络。"
fi

# -----------------------
# PAM 插件路径探测
# -----------------------
find_pam_plugin() {
  local cands=(
    "/usr/lib/x86_64-linux-gnu/openvpn/plugins/openvpn-plugin-auth-pam.so"
    "/usr/lib/openvpn/openvpn-plugin-auth-pam.so"
  )
  local p
  for p in "${cands[@]}"; do
    [ -f "$p" ] && { echo "$p"; return 0; }
  done

  local dp
  dp="$(dpkg -L openvpn 2>/dev/null | grep -m1 'openvpn-plugin-auth-pam.so' || true)"
  [ -n "$dp" ] && { echo "$dp"; return 0; }
  return 1
}

PAM_SO=""
if [ "$AUTH_FLAG" -eq 1 ]; then
  PAM_SO="$(find_pam_plugin)" || {
    log_err "未找到 openvpn PAM 插件库（openvpn-plugin-auth-pam.so）。"
    exit 1
  }

  log_info "启用证书 + 用户名/密码双因子认证（PAM / 系统账户）..."

  if [ ! -f /etc/pam.d/openvpn ]; then
    install -m 644 /dev/stdin /etc/pam.d/openvpn <<'PAMCFG'
# OpenVPN PAM profile - 基于系统账户（/etc/shadow）
auth     required pam_unix.so
account  required pam_unix.so
PAMCFG
  fi
fi

# -----------------------
# 生成 OpenVPN 服务端配置
# -----------------------
log_info "生成 OpenVPN 服务端配置文件..."
cat > "${CONF_SERVER_DIR}/${SERVICE}.conf" <<EOF
port ${PORT}
proto udp
dev tun

server 10.10.0.0 255.255.255.0
${V6_BLOCK}

ca ${CONF_PRIV_DIR}/ca.crt
cert ${CONF_PRIV_DIR}/server.crt
key ${CONF_PRIV_DIR}/server.key
dh ${CONF_PRIV_DIR}/dh.pem

topology subnet
ifconfig-pool-persist ${STATE_DIR}/ipp.txt 600

push "redirect-gateway def1 bypass-dhcp"
${V6_PUSH}
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 1.0.0.1"

keepalive 10 120
persist-key
persist-tun

# 控制信道：tls-crypt-v2
tls-crypt-v2 ${TC2_SERVER_KEY}

# 最低 TLS 1.2
tls-version-min 1.2
tls-cert-profile preferred
tls-ciphersuites TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
tls-groups X25519:secp256r1

# 数据信道（AEAD）
data-ciphers AES-256-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-GCM

# 禁用压缩
allow-compression no

# CRL
crl-verify ${CRL_PATH}

# 运行状态文件
status ${STATE_DIR}/status.log
status-version 2

# 非特权运行
user nobody
group nogroup

verb 3
explicit-exit-notify 1
EOF

if [ "$AUTH_FLAG" -eq 1 ]; then
  {
    echo "plugin ${PAM_SO} openvpn"
  } >> "${CONF_SERVER_DIR}/${SERVICE}.conf"
fi

# -----------------------
# sysctl
# -----------------------
log_info "启用内核 IPv4/IPv6 转发..."
install -m 644 /dev/stdin /etc/sysctl.d/99-openvpn-forward.conf <<SYSCTL
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = ${ENABLE_V6}
net.ipv6.conf.default.forwarding = ${ENABLE_V6}
SYSCTL
sysctl --system >/dev/null

# -----------------------
# 防火墙（10.10.0.0/24）+ 放行入站 ${PORT}/udp
# -----------------------
CIDR_V4="10.10.0.0/24"

if [ -n "${OUT_IF:-}" ]; then
  log_info "配置 IPv4 防火墙与 NAT（出口：${OUT_IF}，网段：${CIDR_V4}）..."
  iptables -C INPUT -p udp --dport "${PORT}" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 1 -p udp --dport "${PORT}" -j ACCEPT

  iptables -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

  iptables -C FORWARD -s "$CIDR_V4" -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 2 -s "$CIDR_V4" -j ACCEPT

  iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
    iptables -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

  iptables -t nat -C POSTROUTING -s "$CIDR_V4" -o "$OUT_IF" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$CIDR_V4" -o "$OUT_IF" -j MASQUERADE
else
  log_err "无法检测 IPv4 默认出口网卡，未配置 NAT 规则，请手工检查路由与 iptables。"
fi

if [ "$ENABLE_V6" -eq 1 ]; then
  V6CIDR="fd00:beef:1234:5680::/64"
  log_info "配置 IPv6 防火墙与 NAT（出口：${OUT_IF6}，网段：${V6CIDR}）..."

  ip6tables -C INPUT -p udp --dport "${PORT}" -j ACCEPT 2>/dev/null || \
    ip6tables -I INPUT 1 -p udp --dport "${PORT}" -j ACCEPT

  ip6tables -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    ip6tables -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

  ip6tables -C FORWARD -s "$V6CIDR" -j ACCEPT 2>/dev/null || \
    ip6tables -I FORWARD 2 -s "$V6CIDR" -j ACCEPT

  ip6tables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
    ip6tables -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

  if [ -n "${OUT_IF6:-}" ] && ip6tables -t nat -L >/dev/null 2>&1; then
    ip6tables -t nat -C POSTROUTING -s "$V6CIDR" -o "$OUT_IF6" -j MASQUERADE 2>/dev/null || \
      ip6tables -t nat -A POSTROUTING -s "$V6CIDR" -o "$OUT_IF6" -j MASQUERADE
  fi
fi

netfilter-persistent save >/dev/null || true

# -----------------------
# 启动服务
# -----------------------
log_info "启用并重启 OpenVPN 服务..."
systemctl daemon-reload
systemctl enable "openvpn-server@${SERVICE}" >/dev/null
systemctl restart "openvpn-server@${SERVICE}"

# -----------------------
# 客户端配置生成
# -----------------------
log_info "生成基础客户端配置与每个客户端的 .ovpn 文件..."
CLIENT_DIR="$BASE/client-configs/files"
mkdir -p "$CLIENT_DIR"
chmod 700 "$CLIENT_DIR"

SERVER_IP="$(curl -4 -s --fail https://api.ipify.org || true)"
[ -n "$SERVER_IP" ] || SERVER_IP="YOUR_PUBLIC_IP"

BASE_UDP="$BASE/client-configs/base-udp.conf"
cat > "$BASE_UDP" <<EOF
client
dev tun
proto udp
remote ${SERVER_IP} ${PORT}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
tls-version-min 1.2
data-ciphers AES-256-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-GCM
auth-nocache
verb 3
EOF

if [ "$AUTH_FLAG" -eq 1 ]; then
  echo "auth-user-pass" >> "$BASE_UDP"
fi

gen_profile() {
  local CN="$1"
  local KEY="$BASE/pki/private/${CN}.key"
  local CRT="$BASE/pki/issued/${CN}.crt"
  local OUT="$CLIENT_DIR/${CN}-udp.ovpn"
  [ -f "$KEY" ] && [ -f "$CRT" ] || return 0

  local TC2="$CLIENT_DIR/${CN}-tc2-client.key"
  if [ ! -f "$TC2" ]; then
    openvpn --tls-crypt-v2 "${TC2_SERVER_KEY}" --genkey tls-crypt-v2-client "$TC2"
    chmod 600 "$TC2"
  fi

  {
    cat "$BASE_UDP"
    echo "<ca>";           cat "$BASE/pki/ca.crt"; echo "</ca>"
    echo "<cert>";         cat "$CRT";             echo "</cert>"
    echo "<key>";          cat "$KEY";             echo "</key>"
    echo "<tls-crypt-v2>"; cat "$TC2";             echo "</tls-crypt-v2>"
  } > "$OUT"
  chmod 600 "$OUT"
}

shopt -s nullglob
for crt in "$BASE/pki/issued/"*.crt; do
  CN="$(basename "$crt" .crt)"
  [[ "$CN" == *server* ]] && continue
  gen_profile "$CN"
done
shopt -u nullglob

if [ "$AUTH_FLAG" -eq 1 ]; then
  log_ok "${SERVICE} 已启动，端口 ${PORT}，已启用用户名/密码认证（PAM）。"
else
  log_ok "${SERVICE} 已启动，端口 ${PORT}。"
fi

log_ok "客户端配置目录：${CLIENT_DIR}"

if [ "$AUTH_FLAG" -eq 1 ]; then
  log_info "如启用了 Auth，请使用系统账户凭据登录；可用 adduser 创建或管理。"
fi

if [ "$DCO_AVAILABLE" -eq 1 ]; then
  log_info "提示：服务器侧已具备 DCO 能力，OpenVPN 会在条件满足时自动启用内核数据通道加速。"
else
  log_info "提示：当前未启用 DCO，将使用传统 tun 数据通道。"
fi
