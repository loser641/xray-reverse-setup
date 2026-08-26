#!/usr/bin/env bash
# =============================================================================
# Xray VLESS 反向代理（多用户一对一落地）中转 VPS 交互式部署脚本
#
# 用途：
#   在中转 VPS（公网服务器）上部署 Xray，实现多用户一一对应的全量转发：
#     - 外部用户 user1/user2/... 通过 VLESS + REALITY 接入 VPS；
#     - 每个用户对应一台专属落地设备（手机/家宽），该设备主动回连 VPS 建立反向隧道；
#     - 用户 N 的全部流量经 reverse-out-N 送入专属隧道，由落地设备 N 从本地出口访问公网；
#     - 不需要分流，全部转发。
#
# 依据：
#   配置字段均以 Xray-core 官方全量文档（https://xtls.github.io/llms-full.txt）
#   中确认过的字段、取值与限制为准，未使用文档未提及的字段。
#
# 用法：
#   sudo bash xray-reverse-setup.sh
# =============================================================================

set -euo pipefail

export PATH="/usr/local/bin:/usr/bin:/bin:${PATH:-}"

C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_RESET=$'\033[0m'

info() { printf '%s[*]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

die() { err "$*"; exit 1; }

# 带默认值的交互输入：输出用户输入或默认值
ask() {
  local prompt="$1" def="$2" ans
  if [ -n "$def" ]; then
    printf '%s[?]%s %s [%s]: ' "$C_BLUE" "$C_RESET" "$prompt" "$def"
  else
    printf '%s[?]%s %s: ' "$C_BLUE" "$C_RESET" "$prompt"
  fi
  read -r ans
  printf '%s\n' "${ans:-$def}"
}

# 确认提问：默认 Y 返回 0，否则返回 1
confirm() {
  local prompt="$1" def="$2" ans
  printf '%s[?]%s %s [%s]: ' "$C_BLUE" "$C_RESET" "$prompt" "$def"
  read -r ans
  ans="${ans:-$def}"
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# 端口校验：1-65535
valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

# shortId 校验：文档确认要求为 0-f 十六进制、位数必须为偶数、不超过 16 位
valid_short_id() {
  local s="$1"
  [[ "$s" =~ ^[0-9a-fA-F]*$ ]] || return 1
  (( ${#s} % 2 == 0 )) || return 1
  (( ${#s} <= 16 )) || return 1
}

# 架构检测，输出对应的 GitHub Release 文件名
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "Xray-linux-64.zip" ;;
    aarch64|arm64) echo "Xray-linux-arm64-v8a.zip" ;;
    *) die "不支持的 CPU 架构：$(uname -m)" ;;
  esac
}

# 逗号分隔列表转 JSON 字符串数组，如 ["a", "b"]
json_str_array() {
  local list="$1" item out="" first=1
  IFS=',' read -r -a items <<< "$list"
  for item in "${items[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    if [ "$first" -eq 1 ]; then first=0; else out+=", "; fi
    out+="\"${item}\""
  done
  printf '%s' "$out"
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
  echo "  1) 官方安装脚本 XTLS/Xray-install（官方文档确认的 Linux 安装脚本，推荐）"
  echo "  2) 手动从 GitHub Releases 下载"
  echo "  3) 跳过（稍后自行处理）"
  local choice
  choice=$(ask "选择 [1/2/3]" "1")
  case "$choice" in
    1)
      info "正在使用官方安装脚本安装 Xray ..."
      bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
      ;;
    2)
      local zip arch dir
      zip=$(detect_arch)
      dir=$(mktemp -d)
      info "下载 ${zip} ..."
      curl -L -o "${dir}/${zip}" "https://github.com/XTLS/Xray-core/releases/latest/download/${zip}"
      (
        cd "${dir}"
        unzip -o "${zip}"
        install -m 755 xray /usr/local/bin/xray
        mkdir -p /usr/local/share/xray
        install -m 644 geoip.dat geosite.dat /usr/local/share/xray/
      )
      rm -rf "${dir}"
      ;;
    3)
      info "跳过安装，请自行确保 xray 可用且支持 vlessenc 命令。"
      ;;
    *)
      die "无效选择：${choice}"
      ;;
  esac

  command -v xray >/dev/null 2>&1 || die "xray 不可用，安装失败。"
  xray vlessenc >/dev/null 2>&1 || die "xray 版本过旧，缺少 vlessenc 命令，无法继续。"
  info "Xray 版本：$(xray version | head -n 1)"
}

# 生成 REALITY 密钥对，写入全局变量
gen_reality_keys() {
  local out
  out=$(xray x25519)
  REALITY_PRIVATE_KEY=$(sed -n 's/^PrivateKey: \(.*\)/\1/p' <<< "${out}")
  REALITY_PUBLIC_KEY=$(sed -n 's/^Password (PublicKey): \(.*\)/\1/p' <<< "${out}")
  [ -n "${REALITY_PRIVATE_KEY}" ] && [ -n "${REALITY_PUBLIC_KEY}" ] || die "解析 x25519 输出失败。"
}

# 生成 VLESS Encryption 对，auth=x25519|mlkem，写入 DECRYPTION / ENCRYPTION
gen_vlessenc() {
  local auth="$1" out n=1
  out=$(xray vlessenc)
  [ "${auth}" = "mlkem" ] && n=2
  DECRYPTION=$(sed -n 's/^"decryption": "\([^"]*\)"/\1/p' <<< "${out}" | sed -n "${n}p")
  ENCRYPTION=$(sed -n 's/^"encryption": "\([^"]*\)"/\1/p' <<< "${out}" | sed -n "${n}p")
  [ -n "${DECRYPTION}" ] && [ -n "${ENCRYPTION}" ] || die "解析 vlessenc 输出失败。"
}

# 生成每个用户的外部接入 UUID 与隧道回连 UUID
# 全局数组：USER_EMAILS_ARR / EXT_UUIDS / BRIDGE_UUIDS / N_USERS
gen_all_uuids() {
  local i email
  for (( i = 0; i < N_USERS; i++ )); do
    email="${USER_EMAILS_ARR[$i]}"
    EXT_UUIDS[$i]=$(xray uuid)
    BRIDGE_UUIDS[$i]=$(xray uuid)
  done
}

# 生成 REALITY 入站（用户接入）的 users 数组条目
build_reality_users() {
  local i email first=1
  for (( i = 0; i < N_USERS; i++ )); do
    email="${USER_EMAILS_ARR[$i]}"
    if [ "$first" -eq 1 ]; then first=0; else printf ',\n'; fi
    printf '          { "id": "%s", "email": "%s", "flow": "xtls-rprx-vision" }' "${EXT_UUIDS[$i]}" "${email}"
  done
  printf '\n'
}

# 生成隧道入站（家宽设备回连）的 users 数组条目，每个用户独立 reverse tag
build_bridge_users() {
  local i first=1
  for (( i = 0; i < N_USERS; i++ )); do
    if [ "$first" -eq 1 ]; then first=0; else printf ',\n'; fi
    printf '          { "id": "%s", "flow": "xtls-rprx-vision", "reverse": { "tag": "reverse-out-%d" } }' "${BRIDGE_UUIDS[$i]}" "$(( i + 1 ))"
  done
  printf '\n'
}

# 生成路由规则：用户 N 的全部流量 -> reverse-out-N（不附加任何域名/IP 条件）
build_routing_rules() {
  local i email first=1
  for (( i = 0; i < N_USERS; i++ )); do
    email="${USER_EMAILS_ARR[$i]}"
    if [ "$first" -eq 1 ]; then first=0; else printf ',\n'; fi
    printf '      { "user": ["%s"], "outboundTag": "reverse-out-%d" }' "${email}" "$(( i + 1 ))"
  done
  printf '\n'
}

# 写入服务端配置（JSONC，含中文注释）
write_server_config() {
  local conf="/usr/local/etc/xray/config.json"

  cat > "${conf}" <<EOF
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
          "serverNames": [$(json_str_array "${SNIS}")],
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
}

# 配置 systemd 服务并启动
setup_service() {
  command -v systemctl >/dev/null 2>&1 || {
    warn "未检测到 systemd，跳过服务配置。请自行常驻运行：xray run -c /usr/local/etc/xray/config.json"
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

# 防火墙放行
setup_firewall() {
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
  local i email f safe
  for (( i = 0; i < N_USERS; i++ )); do
    email="${USER_EMAILS_ARR[$i]}"
    safe=$(printf '%s' "${email}" | tr -c 'A-Za-z0-9._-' '_')
    f="/root/xray-bridge-${safe}.jsonc"
    cat > "${f}" <<EOF
{
  // 落地设备配置（${email}）：设备主动连接 VPS 建立专属反向隧道
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
        "id": "${BRIDGE_UUIDS[$i]}",
        "encryption": "${ENCRYPTION}",
        "flow": "xtls-rprx-vision",
        "reverse": { "tag": "reverse-in-$(( i + 1 ))" }
      },
      "streamSettings": { "method": "raw", "security": "none" }
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "inboundTag": ["reverse-in-$(( i + 1 ))"], "outboundTag": "home-direct" }
    ]
  }
}
EOF
    info "已生成：${f}（请安全拷贝到用户 ${email} 的落地设备导入）"
  done
}

# 打印分享链接（格式依据官方文档引用的 VLESS 分享链接标准）
print_links() {
  echo "  == 分享链接（vless://，依据官方文档引用的分享链接标准）=="
  local i email
  for (( i = 0; i < N_USERS; i++ )); do
    email="${USER_EMAILS_ARR[$i]}"
    printf '    %s: vless://%s@%s:%s?security=reality&flow=xtls-rprx-vision&type=tcp&sni=%s&pbk=%s&sid=%s&fp=chrome#%s\n' \
      "${email}" "${EXT_UUIDS[$i]}" "${VPS_HOST}" "${REALITY_PORT}" "${SNI_HOST}" "${REALITY_PUBLIC_KEY}" "${SHORT_ID}" "${email}"
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
  local i email safe
  for (( i = 0; i < N_USERS; i++ )); do
    email="${USER_EMAILS_ARR[$i]}"
    safe=$(printf '%s' "${email}" | tr -c 'A-Za-z0-9._-' '_')
    echo "  用户 ${email}（隧道 #$(( i + 1 ))）"
    echo "    外部接入 UUID : ${EXT_UUIDS[$i]}"
    echo "    隧道回连 UUID : ${BRIDGE_UUIDS[$i]}"
    echo "    落地设备配置 : /root/xray-bridge-${safe}.jsonc"
  done
  echo
  if confirm "打印客户端分享链接？" "Y"; then
    print_links
  fi
  echo
  info "后续步骤："
  echo "  1) 每台落地设备安装 Xray 客户端并导入对应配置文件，保持在线以建立专属反向隧道。"
  echo "  2) 各用户导入上面的分享链接，全部流量将经对应落地设备出口。"
  echo "  3) 服务管理：systemctl restart xray / systemctl status xray"
  echo "  4) 若无法连接，先检查云厂商安全组是否放行 ${REALITY_PORT}/tcp 与 ${BRIDGE_PORT}/tcp。"
}

main() {
  [ "$(id -u)" -eq 0 ] || die "请使用 root 运行：sudo bash $0"
  command -v curl >/dev/null 2>&1 || die "缺少 curl，请先安装：apt install -y curl"

  install_xray

  echo
  info "==== 开始收集部署参数 ===="

  local detected_ip=""
  detected_ip=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null || true)
  [ -n "${detected_ip}" ] || detected_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  VPS_HOST=$(ask "VPS 公网 IP 或域名（用于落地设备配置和分享链接）" "${detected_ip:-}")
  [ -n "${VPS_HOST}" ] || die "VPS 地址不能为空。"

  while :; do
    REALITY_PORT=$(ask "用户接入端口（VLESS+REALITY）" "443")
    valid_port "${REALITY_PORT}" && break
    warn "端口无效，请输入 1-65535 之间的数字。"
  done

  while :; do
    BRIDGE_PORT=$(ask "反向隧道端口（落地设备回连）" "8443")
    if ! valid_port "${BRIDGE_PORT}"; then
      warn "端口无效，请输入 1-65535 之间的数字。"
      continue
    fi
    [ "${BRIDGE_PORT}" != "${REALITY_PORT}" ] && break
    warn "两个端口不能相同。"
  done

  REALITY_TARGET=$(ask "REALITY 伪装目标 target（格式 域名:端口）" "itunes.apple.com:443")
  [[ "${REALITY_TARGET}" == *":"* ]] || REALITY_TARGET="${REALITY_TARGET}:443"
  SNI_HOST="${REALITY_TARGET%%:*}"
  SNIS=$(ask "SNI 列表（逗号分隔，默认与 target 主机名一致）" "${SNI_HOST}")
  [ -n "${SNIS}" ] || die "SNI 不能为空。"

  local def_sid
  def_sid=$(xray uuid | tr -d '-' | cut -c1-4)
  while :; do
    SHORT_ID=$(ask "REALITY shortId（16 位以内十六进制，位数必须为偶数）" "${def_sid}")
    valid_short_id "${SHORT_ID}" && break
    warn "shortId 必须是 0-f 十六进制、偶数位、不超过 16 位。"
  done

  echo
  info "请按顺序输入用户 email 列表，第 N 个用户对应第 N 台落地设备："
  local users_input
  users_input=$(ask "用户 email（逗号分隔）" "user1,user2")
  [ -n "${users_input}" ] || die "用户列表不能为空。"

  IFS=',' read -r -a USER_EMAILS_ARR <<< "${users_input}"
  local i email
  N_USERS=0
  for i in "${!USER_EMAILS_ARR[@]}"; do
    email="${USER_EMAILS_ARR[$i]}"
    email="${email#"${email%%[![:space:]]*}"}"
    email="${email%"${email##*[![:space:]]}"}"
    [ -n "${email}" ] || die "用户列表中存在空项，请重新填写。"
    USER_EMAILS_ARR[$i]="${email}"
    N_USERS=$(( N_USERS + 1 ))
  done
  local dup
  dup=$(printf '%s\n' "${USER_EMAILS_ARR[@]}" | sort | uniq -d | tr '\n' ' ')
  [ -z "${dup}" ] || die "用户 email 重复：${dup}"

  gen_all_uuids

  echo
  info "VLESS Encryption 认证方式（文档确认二者均可，服务端与客户端必须一致）："
  echo "  1) X25519（默认，较短）"
  echo "  2) ML-KEM-768（后量子，较长）"
  VLESS_AUTH=$(ask "选择 [1/2]" "1")
  case "${VLESS_AUTH}" in
    1) gen_vlessenc x25519 ;;
    2) gen_vlessenc mlkem ;;
    *) die "无效选择：${VLESS_AUTH}" ;;
  esac

  gen_reality_keys

  local conf="/usr/local/etc/xray/config.json" bak=""
  mkdir -p /usr/local/etc/xray
  if [ -f "${conf}" ]; then
    bak="${conf}.bak.$(date +%Y%m%d%H%M%S)"
    if confirm "检测到已有 ${conf}，备份后覆盖？" "Y"; then
      cp -a "${conf}" "${bak}"
      info "已备份到 ${bak}"
    else
      die "已取消，请先手动处理 ${conf} 后重试。"
    fi
  fi

  write_server_config

  info "校验配置（xray run -test）..."
  if ! xray run -test -c "${conf}"; then
    if [ -n "${bak}" ]; then
      cp -a "${bak}" "${conf}"
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
