#!/bin/sh
# =============================================================================
# Xray VLESS 反向代理（多用户一对一落地）中转 VPS 交互式部署脚本
#
# 适用系统：Alpine Linux（OpenRC）/ Debian / Ubuntu（systemd）
# 依赖：仅使用系统自带工具（sh、wget 或 curl、sed、awk、tr、cut 等），
#       不额外安装 bash；unzip 仅在“手动下载安装”时会用到（Alpine 可用
#       busybox unzip，或 apk add unzip）。
#
# 用途：
#   - 外部用户 user1/user2/... 通过 VLESS + REALITY 接入 VPS；
#   - 每个用户对应一台专属落地设备（手机/家宽），该设备主动回连 VPS 建立反向隧道；
#   - 用户 N 的全部流量经 reverse-out-N 送入专属隧道，由落地设备 N 出口；
#   - 不需要分流，全部转发。
#
# 依据：
#   配置字段均以 Xray-core 官方全量文档（https://xtls.github.io/llms-full.txt）
#   中确认过的字段、取值与限制为准；安装与服务管理参考官方
#   XTLS/Xray-install（含 Alpine/OpenRC 专属说明）。
#
# 用法：
#   ./xray-reverse-setup.sh          （需 root）
# =============================================================================

set -eu

export PATH="/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin:${PATH:-}"

C_RED='\033[31m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_BLUE='\033[34m'
C_RESET='\033[0m'

info() { printf "${C_GREEN}[*]${C_RESET} %s\n" "$*"; }
warn() { printf "${C_YELLOW}[!]${C_RESET} %s\n" "$*"; }
err()  { printf "${C_RED}[x]${C_RESET} %s\n" "$*" >&2; }

die() { err "$*"; exit 1; }

# 带默认值的交互输入：输出用户输入或默认值
ask() {
  _ask_prompt="$1"
  _ask_def="$2"
  if [ -n "$_ask_def" ]; then
    printf "${C_BLUE}[?]${C_RESET} %s [%s]: " "$_ask_prompt" "$_ask_def"
  else
    printf "${C_BLUE}[?]${C_RESET} %s: " "$_ask_prompt"
  fi
  read -r _ask_ans
  printf '%s\n' "${_ask_ans:-$_ask_def}"
}

# 确认提问：默认 Y 返回 0，否则返回 1
confirm() {
  _cf_prompt="$1"
  _cf_def="$2"
  printf "${C_BLUE}[?]${C_RESET} %s [%s]: " "$_cf_prompt" "$_cf_def"
  read -r _cf_ans
  _cf_ans="${_cf_ans:-$_cf_def}"
  case "$_cf_ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# HTTP 下载到标准输出（优先 wget，其次 curl）
http_get() {
  if command -v wget >/dev/null 2>&1; then
    wget -qO- "$1"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1"
  else
    die "未找到 wget 或 curl，请先安装（Debian/Ubuntu: apt install -y curl；Alpine: apk add curl）。"
  fi
}

# HTTP 下载到文件
http_download() {
  if command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$1"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$2" "$1"
  else
    die "未找到 wget 或 curl，请先安装。"
  fi
}

# 端口校验：1-65535
valid_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null; then
    return 0
  fi
  return 1
}

# shortId 校验：文档确认要求为 0-f 十六进制、位数必须为偶数、不超过 16 位
valid_short_id() {
  case "$1" in
    *[!0-9a-fA-F]*) return 1 ;;
  esac
  _sid_len=${#1}
  if [ $((_sid_len % 2)) -ne 0 ]; then
    return 1
  fi
  if [ "$_sid_len" -gt 16 ]; then
    return 1
  fi
  return 0
}

# 架构检测，输出对应的 GitHub Release 文件名
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "Xray-linux-64.zip" ;;
    aarch64|arm64) echo "Xray-linux-arm64-v8a.zip" ;;
    *) die "不支持的 CPU 架构：$(uname -m)" ;;
  esac
}

# 检测初始化系统：systemd / openrc / none
detect_init() {
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    echo "systemd"
  elif command -v rc-service >/dev/null 2>&1 && [ -d /run/openrc ]; then
    echo "openrc"
  elif [ -f /etc/alpine-release ]; then
    echo "openrc"
  else
    echo "none"
  fi
}

# 逗号分隔列表转 JSON 字符串数组，如 ["a", "b"]
json_str_array() {
  _js_list="$1"
  _js_out=""
  _js_first=1
  while [ -n "$_js_list" ]; do
    case "$_js_list" in
      *",") _js_item="${_js_list%,}"; _js_list="" ;;
      *,*)  _js_item="${_js_list%%,*}"; _js_list="${_js_list#*,}" ;;
      *)    _js_item="$_js_list"; _js_list="" ;;
    esac
    _js_item=$(printf '%s' "$_js_item" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    if [ "$_js_first" -eq 1 ]; then
      _js_first=0
    else
      _js_out="${_js_out}, "
    fi
    _js_out="${_js_out}\"${_js_item}\""
  done
  printf '%s' "$_js_out"
}

# 安装或确认 Xray
install_xray() {
  if command -v xray >/dev/null 2>&1; then
    if xray vlessenc >/dev/null 2>&1; then
      info "检测到已安装 Xray：$(xray version | head -n 1)"
      if confirm "使用现有 Xray，跳过安装？" "Y"; then
        return 0
      fi
    else
      warn "检测到 Xray，但缺少 vlessenc 命令（版本过旧），需要升级后才能生成 VLESS Encryption 配置。"
      confirm "继续升级到最新版？" "Y" || die "需要新版 Xray，请升级后重试。"
    fi
  fi

  echo
  info "请选择安装方式："
  if [ "$INIT" = "openrc" ]; then
    echo "  1) 官方 Alpine 安装脚本（XTLS/Xray-install alpinelinux，推荐）"
  else
    echo "  1) 官方安装脚本 XTLS/Xray-install（官方文档确认的 Linux 安装脚本，推荐）"
  fi
  echo "  2) 手动从 GitHub Releases 下载"
  echo "  3) 跳过（稍后自行处理）"
  _inst_choice=$(ask "选择 [1/2/3]" "1")
  case "$_inst_choice" in
    1)
      if [ "$INIT" = "openrc" ]; then
        info "正在使用官方 Alpine 安装脚本安装 Xray ..."
        http_download "https://github.com/XTLS/Xray-install/raw/main/alpinelinux/install-release.sh" "$WD/install-release.sh"
        chmod +x "$WD/install-release.sh"
        ash "$WD/install-release.sh"
      else
        info "正在使用官方安装脚本安装 Xray ..."
        bash -c "$(http_get https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
      fi
      ;;
    2)
      _zip=$(detect_arch)
      info "下载 ${_zip} ..."
      http_download "https://github.com/XTLS/Xray-core/releases/latest/download/${_zip}" "$WD/${_zip}"
      _unzip_cmd=""
      if command -v unzip >/dev/null 2>&1; then
        _unzip_cmd="unzip"
      elif command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -q '^unzip$'; then
        _unzip_cmd="busybox unzip"
      else
        if command -v apk >/dev/null 2>&1; then
          info "安装 unzip（Alpine）..."
          apk add --no-cache unzip >/dev/null
          _unzip_cmd="unzip"
        elif command -v apt-get >/dev/null 2>&1; then
          info "安装 unzip（Debian/Ubuntu）..."
          apt-get update -qq >/dev/null
          apt-get install -y -qq unzip >/dev/null
          _unzip_cmd="unzip"
        else
          die "未找到 unzip，且无法自动安装，请先安装 unzip 后重试。"
        fi
      fi
      (
        cd "$WD"
        $_unzip_cmd -o "$_zip"
        install -m 755 xray /usr/local/bin/xray
        mkdir -p /usr/local/share/xray
        if [ -f geoip.dat ]; then
          install -m 644 geoip.dat geosite.dat /usr/local/share/xray/
        fi
      )
      ;;
    3)
      info "跳过安装，请自行确保 xray 可用且支持 vlessenc 命令。"
      ;;
    *)
      die "无效选择：$_inst_choice"
      ;;
  esac

  command -v xray >/dev/null 2>&1 || die "xray 不可用，安装失败。"
  xray vlessenc >/dev/null 2>&1 || die "xray 版本过旧，缺少 vlessenc 命令，无法继续。"
  info "Xray 版本：$(xray version | head -n 1)"
}

# 生成 REALITY 密钥对，写入全局变量
gen_reality_keys() {
  _x25519_out=$(xray x25519)
  REALITY_PRIVATE_KEY=$(printf '%s\n' "$_x25519_out" | sed -n 's/^PrivateKey: \(.*\)/\1/p')
  REALITY_PUBLIC_KEY=$(printf '%s\n' "$_x25519_out" | sed -n 's/^Password (PublicKey): \(.*\)/\1/p')
  [ -n "$REALITY_PRIVATE_KEY" ] && [ -n "$REALITY_PUBLIC_KEY" ] || die "解析 x25519 输出失败。"
}

# 生成 VLESS Encryption 对，auth=x25519|mlkem，写入 DECRYPTION / ENCRYPTION
gen_vlessenc() {
  _ve_auth="$1"
  _ve_n=1
  [ "$_ve_auth" = "mlkem" ] && _ve_n=2
  _ve_out=$(xray vlessenc)
  DECRYPTION=$(printf '%s\n' "$_ve_out" | sed -n 's/^"decryption": "\([^"]*\)"/\1/p' | sed -n "${_ve_n}p")
  ENCRYPTION=$(printf '%s\n' "$_ve_out" | sed -n 's/^"encryption": "\([^"]*\)"/\1/p' | sed -n "${_ve_n}p")
  [ -n "$DECRYPTION" ] && [ -n "$ENCRYPTION" ] || die "解析 vlessenc 输出失败。"
}

# 生成每个用户的外部接入 UUID 与隧道回连 UUID，存入 $WD/u<i>.ext / $WD/u<i>.br
gen_all_uuids() {
  _i=1
  while [ "$_i" -le "$N_USERS" ]; do
    xray uuid > "$WD/u${_i}.ext"
    xray uuid > "$WD/u${_i}.br"
    _i=$((_i + 1))
  done
}

# 生成 REALITY 入站（用户接入）的 users 数组条目
build_reality_users() {
  _i=1
  _first=1
  while [ "$_i" -le "$N_USERS" ]; do
    _email=$(sed -n "${_i}p" "$WD/emails")
    if [ "$_first" -eq 1 ]; then
      _first=0
    else
      printf ',\n'
    fi
    printf '          { "id": "%s", "email": "%s", "flow": "xtls-rprx-vision" }' "$(cat "$WD/u${_i}.ext")" "$_email"
    _i=$((_i + 1))
  done
  printf '\n'
}

# 生成隧道入站（落地设备回连）的 users 数组条目，每个用户独立 reverse tag
build_bridge_users() {
  _i=1
  _first=1
  while [ "$_i" -le "$N_USERS" ]; do
    if [ "$_first" -eq 1 ]; then
      _first=0
    else
      printf ',\n'
    fi
    printf '          { "id": "%s", "flow": "xtls-rprx-vision", "reverse": { "tag": "reverse-out-%d" } }' "$(cat "$WD/u${_i}.br")" "$_i"
    _i=$((_i + 1))
  done
  printf '\n'
}

# 生成路由规则：用户 N 的全部流量 -> reverse-out-N（不附加任何域名/IP 条件）
build_routing_rules() {
  _i=1
  _first=1
  while [ "$_i" -le "$N_USERS" ]; do
    _email=$(sed -n "${_i}p" "$WD/emails")
    if [ "$_first" -eq 1 ]; then
      _first=0
    else
      printf ',\n'
    fi
    printf '      { "user": ["%s"], "outboundTag": "reverse-out-%d" }' "$_email" "$_i"
    _i=$((_i + 1))
  done
  printf '\n'
}

# 写入服务端配置（JSONC，含中文注释）
write_server_config() {
  cat > "$CONF" <<EOF
{
  // 日志级别：debug / info / warning / error / none（官方文档确认）
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      // 用户接入入口：VLESS + REALITY（RAW/TCP）
      // 文档确认：serverNames/privateKey/shortIds 为必填；target 与旧名 dest 互为别名
      "tag": "user-in",
      "listen": "0.0.0.0",
      "port": ${REALITY_PORT},
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "users": [
$(build_reality_users)
        ]
      },
      "streamSettings": {
        "method": "raw",
        "security": "reality",
        "realitySettings": {
          "target": "${REALITY_TARGET}",
          "serverNames": [$(json_str_array "$SNIS")],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    },
    {
      // 隧道入口：VLESS + VLESS Encryption
      // 每个落地设备使用自己的 UUID 与独立 reverse tag，形成一一对应的专属隧道
      // 文档确认：启用 VLESS Encryption 后，streamSettings.security 才允许为 none
      "tag": "bridge-in",
      "listen": "0.0.0.0",
      "port": ${BRIDGE_PORT},
      "protocol": "vless",
      "settings": {
        "decryption": "${DECRYPTION}",
        "users": [
$(build_bridge_users)
        ]
      },
      "streamSettings": { "method": "raw", "security": "none" }
    }
  ],
  "outbounds": [
    // 文档强调：公网服务器必须保留明确的默认出站，否则未命中规则的流量可能误入反向隧道
    { "protocol": "freedom", "tag": "direct" }
  ],
  "routing": {
    // 全量转发：仅按用户 email 匹配，不附加任何域名/IP 条件
    "domainStrategy": "AsIs",
    "rules": [
$(build_routing_rules)
    ]
  }
}
EOF
  chmod 644 "$CONF"
}

# 配置服务并启动（systemd 或 OpenRC）
setup_service() {
  if [ "$INIT" = "openrc" ]; then
    if [ -f /etc/init.d/xray ]; then
      info "使用已存在的 OpenRC 服务 xray"
    else
      info "创建 OpenRC 服务 /etc/init.d/xray"
      cat > /etc/init.d/xray <<'EOF'
#!/sbin/openrc-run

name="Xray Daemon"
description="Xray service"

supervisor=supervise-daemon
respawn_delay=5
respawn_max=2
respawn_period=600

pidfile="/run/${RC_SVCNAME}.pid"
rc_ulimit="-n 1024000 -u 1024000"
capabilities="^cap_net_bind_service,^cap_net_admin,^cap_net_raw"
extra_commands="checkconfig"

env=${env:-"XRAY_LOCATION_ASSET=/usr/local/share/xray/"}
command="/usr/local/bin/xray"
command_user="nobody:nobody"
command_args="run -c /usr/local/etc/xray/config.json"
required_files="/usr/local/etc/xray/config.json"

depend() {
	need net
	want dns ntp-client
	after firewall
}

checkconfig() {
	export $env
	$command $command_args -test
	eend $?
}

start_pre() {
	checkconfig || return 1
}
EOF
      chmod +x /etc/init.d/xray
    fi
    rc-update add xray >/dev/null 2>&1 || true
    rc-service xray restart
    sleep 2
    if rc-service xray status >/dev/null 2>&1; then
      info "Xray 服务运行中"
    else
      warn "Xray 服务状态异常，请查看：rc-service xray status"
    fi
    return 0
  fi

  command -v systemctl >/dev/null 2>&1 || {
    warn "未检测到 systemd 或 OpenRC，跳过服务配置。请自行常驻运行：xray run -c $CONF"
    return 0
  }

  if [ -f /etc/systemd/system/xray.service ]; then
    info "使用已存在的 xray.service"
  else
    info "创建 systemd 服务 xray.service"
    cat > /etc/systemd/system/xray.service <<'UNIT'
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
Type=simple
Environment="XRAY_LOCATION_ASSET=/usr/local/share/xray"
ExecStart=/usr/local/bin/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
  fi

  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray
  sleep 2
  if systemctl is-active --quiet xray; then
    info "Xray 服务运行中"
  else
    warn "Xray 服务未正常运行，请查看：journalctl -u xray -n 50"
  fi
}

# 防火墙放行（Debian/Ubuntu 的 ufw；Alpine 默认无防火墙）
setup_firewall() {
  if [ "$INIT" = "openrc" ]; then
    warn "Alpine 默认未启用防火墙；若使用云厂商安全组，请手动放行 ${REALITY_PORT}/tcp 与 ${BRIDGE_PORT}/tcp。"
    return 0
  fi
  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q "Status: active"; then
      if confirm "检测到 ufw 已启用，放行 ${REALITY_PORT}/tcp 和 ${BRIDGE_PORT}/tcp？" "Y"; then
        ufw allow "${REALITY_PORT}/tcp" >/dev/null
        ufw allow "${BRIDGE_PORT}/tcp" >/dev/null
        info "ufw 已放行 ${REALITY_PORT}/tcp、${BRIDGE_PORT}/tcp"
      fi
    else
      warn "检测到 ufw 未启用，跳过。若使用云厂商安全组请自行放行端口。"
    fi
  else
    warn "未检测到 ufw。若使用云厂商安全组/防火墙，请手动放行 ${REALITY_PORT}/tcp 与 ${BRIDGE_PORT}/tcp。"
  fi
}

# 为每个落地设备生成一份客户端配置（主动回连 VPS 建立专属反向隧道）
write_bridge_clients() {
  _i=1
  while [ "$_i" -le "$N_USERS" ]; do
    _email=$(sed -n "${_i}p" "$WD/emails")
    _safe=$(printf '%s' "$_email" | tr -c 'A-Za-z0-9._-' '_')
    _bf="/root/xray-bridge-${_safe}.jsonc"
    cat > "$_bf" <<EOF
{
  // 落地设备配置（${_email}）：设备主动连接 VPS 建立专属反向隧道
  // 使用方式：v2rayNG 自定义配置导入 / v2rayN 添加自定义配置服务器
  "log": { "loglevel": "warning" },
  "inbounds": [],
  "outbounds": [
    // 默认直连出站（文档示例保留）
    { "protocol": "freedom" },
    {
      // 承接从 reverse-in 进入的流量，仅放行公网目标（文档示例配置）
      "protocol": "freedom",
      "tag": "home-direct",
      "settings": {
        "finalRules": [
          { "action": "allow", "network": "tcp,udp", "ip": ["!geoip:private"] }
        ]
      }
    },
    {
      // 主动回连 VPS 建立反向隧道
      "protocol": "vless",
      "tag": "to-vps",
      "settings": {
        "address": "${VPS_HOST}",
        "port": ${BRIDGE_PORT},
        "id": "$(cat "$WD/u${_i}.br")",
        "encryption": "${ENCRYPTION}",
        "flow": "xtls-rprx-vision",
        "reverse": { "tag": "reverse-in-${_i}" }
      },
      "streamSettings": { "method": "raw", "security": "none" }
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "inboundTag": ["reverse-in-${_i}"], "outboundTag": "home-direct" }
    ]
  }
}
EOF
    info "已生成：$_bf（请安全拷贝到用户 $_email 的落地设备导入）"
    _i=$((_i + 1))
  done
}

# 打印分享链接（格式依据官方文档引用的 VLESS 分享链接标准）
print_links() {
  echo "  == 分享链接（vless://，依据官方文档引用的分享链接标准）=="
  _i=1
  while [ "$_i" -le "$N_USERS" ]; do
    _email=$(sed -n "${_i}p" "$WD/emails")
    printf '    %s: vless://%s@%s:%s?security=reality&flow=xtls-rprx-vision&type=tcp&sni=%s&pbk=%s&sid=%s&fp=chrome#%s\n' \
      "$_email" "$(cat "$WD/u${_i}.ext")" "$VPS_HOST" "$REALITY_PORT" "$SNI_HOST" "$REALITY_PUBLIC_KEY" "$SHORT_ID" "$_email"
    _i=$((_i + 1))
  done
}

# 部署结果汇总
print_summary() {
  echo
  info "================ 部署完成 ================"
  echo "  VPS 地址      : ${VPS_HOST}"
  echo "  用户入口端口  : ${REALITY_PORT}  (VLESS + REALITY)"
  echo "  隧道端口      : ${BRIDGE_PORT}  (VLESS + VLESS Encryption)"
  echo "  REALITY target: ${REALITY_TARGET}  SNI: ${SNIS}"
  echo "  shortId       : ${SHORT_ID}"
  echo
  echo "  == 用户与落地设备一一对应 =="
  _i=1
  while [ "$_i" -le "$N_USERS" ]; do
    _email=$(sed -n "${_i}p" "$WD/emails")
    _safe=$(printf '%s' "$_email" | tr -c 'A-Za-z0-9._-' '_')
    echo "  用户 ${_email}（隧道 #${_i}）"
    echo "    外部接入 UUID : $(cat "$WD/u${_i}.ext")"
    echo "    隧道回连 UUID : $(cat "$WD/u${_i}.br")"
    echo "    落地设备配置 : /root/xray-bridge-${_safe}.jsonc"
    _i=$((_i + 1))
  done
  echo
  if confirm "打印客户端分享链接？" "Y"; then
    print_links
  fi
  echo
  info "后续步骤："
  echo "  1) 每台落地设备安装 Xray 客户端并导入对应配置文件，保持在线以建立专属反向隧道。"
  echo "  2) 各用户导入上面的分享链接，全部流量将经对应落地设备出口。"
  if [ "$INIT" = "openrc" ]; then
    echo "  3) 服务管理：rc-service xray restart / rc-service xray status / rc-update add xray"
  else
    echo "  3) 服务管理：systemctl restart xray / systemctl status xray"
  fi
  echo "  4) 若无法连接，先检查云厂商安全组是否放行 ${REALITY_PORT}/tcp 与 ${BRIDGE_PORT}/tcp。"
}

main() {
  [ "$(id -u)" -eq 0 ] || die "请使用 root 运行：sudo $0"

  INIT=$(detect_init)
  info "检测到初始化系统：${INIT}"
  [ "$INIT" != "none" ] || warn "未检测到 systemd/OpenRC，将跳过服务自动配置。"

  WD=$(mktemp -d "${TMPDIR:-/tmp}/xray-setup.XXXXXX") || WD="/tmp/xray-setup.$$"
  mkdir -p "$WD"
  trap 'rm -rf "$WD"' EXIT

  CONF="/usr/local/etc/xray/config.json"

  install_xray

  echo
  info "==== 开始收集部署参数 ===="

  _detected_ip=""
  if command -v curl >/dev/null 2>&1; then
    _detected_ip=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null || true)
  elif command -v wget >/dev/null 2>&1; then
    _detected_ip=$(wget -qO- -T 5 https://api.ipify.org 2>/dev/null || true)
  fi
  if [ -z "$_detected_ip" ]; then
    _detected_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  fi
  if [ -z "$_detected_ip" ]; then
    _detected_ip=$(hostname -i 2>/dev/null || true)
  fi
  VPS_HOST=$(ask "VPS 公网 IP 或域名（用于落地设备配置和分享链接）" "${_detected_ip:-}")
  [ -n "$VPS_HOST" ] || die "VPS 地址不能为空。"

  while :; do
    REALITY_PORT=$(ask "用户接入端口（VLESS+REALITY）" "443")
    valid_port "$REALITY_PORT" && break
    warn "端口无效，请输入 1-65535 之间的数字。"
  done

  while :; do
    BRIDGE_PORT=$(ask "反向隧道端口（落地设备回连）" "8443")
    if ! valid_port "$BRIDGE_PORT"; then
      warn "端口无效，请输入 1-65535 之间的数字。"
      continue
    fi
    [ "$BRIDGE_PORT" != "$REALITY_PORT" ] && break
    warn "两个端口不能相同。"
  done

  REALITY_TARGET=$(ask "REALITY 伪装目标 target（格式 域名:端口）" "itunes.apple.com:443")
  case "$REALITY_TARGET" in
    *":") : ;;
    *":"*) : ;;
    *) REALITY_TARGET="${REALITY_TARGET}:443" ;;
  esac
  SNI_HOST="${REALITY_TARGET%%:*}"
  SNIS=$(ask "SNI 列表（逗号分隔，默认与 target 主机名一致）" "$SNI_HOST")
  [ -n "$SNIS" ] || die "SNI 不能为空。"

  _def_sid=$(xray uuid | tr -d '-' | cut -c1-4)
  while :; do
    SHORT_ID=$(ask "REALITY shortId（16 位以内十六进制，位数必须为偶数）" "$_def_sid")
    valid_short_id "$SHORT_ID" && break
    warn "shortId 必须是 0-f 十六进制、偶数位、不超过 16 位。"
  done

  echo
  info "请按顺序输入用户 email 列表，第 N 个用户对应第 N 台落地设备："
  _users_input=$(ask "用户 email（逗号分隔）" "user1,user2")
  [ -n "$_users_input" ] || die "用户列表不能为空。"

  printf '%s' "$_users_input" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d' > "$WD/emails"
  N_USERS=$(wc -l < "$WD/emails")
  [ "$N_USERS" -ge 1 ] || die "用户列表不能为空。"
  _dup=$(sort "$WD/emails" | uniq -d | tr '\n' ' ')
  [ -z "$_dup" ] || die "用户 email 重复：$_dup"
  info "共 ${N_USERS} 个用户：$(tr '\n' ',' < "$WD/emails" | sed 's/,$//')"

  gen_all_uuids

  echo
  info "VLESS Encryption 认证方式（文档确认二者均可，服务端与客户端必须一致）："
  echo "  1) X25519（默认，较短）"
  echo "  2) ML-KEM-768（后量子，较长）"
  _ve_choice=$(ask "选择 [1/2]" "1")
  case "$_ve_choice" in
    1) gen_vlessenc x25519 ;;
    2) gen_vlessenc mlkem ;;
    *) die "无效选择：$_ve_choice" ;;
  esac

  gen_reality_keys

  _bak=""
  mkdir -p /usr/local/etc/xray
  if [ -f "$CONF" ]; then
    _bak="${CONF}.bak.$(date +%Y%m%d%H%M%S)"
    if confirm "检测到已有 $CONF，备份后覆盖？" "Y"; then
      cp -a "$CONF" "$_bak"
      info "已备份到 $_bak"
    else
      die "已取消，请先手动处理 $CONF 后重试。"
    fi
  fi

  write_server_config

  info "校验配置（xray run -test）..."
  if ! xray run -test -c "$CONF"; then
    if [ -n "$_bak" ]; then
      cp -a "$_bak" "$CONF"
      warn "配置校验失败，已还原备份配置。"
    fi
    die "配置校验失败，请根据上面的报错修正后重试。"
  fi

  setup_service
  setup_firewall
  write_bridge_clients
  print_summary
}

main "$@"
