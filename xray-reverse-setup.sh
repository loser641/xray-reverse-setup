#!/bin/sh
# =============================================================================
# Xray VLESS 反向代理（多场景一对一落地）中转 VPS 交互式部署脚本
#
# 适用系统：Alpine Linux（OpenRC）/ Debian / Ubuntu（systemd）
# 依赖：仅使用系统自带工具（sh、wget 或 curl、sed、awk、tr、cut 等），
#       不额外安装 bash；unzip 仅在“手动下载安装”时会用到。
#
# 四种场景（VPS 均在国内/国外以“设备相对 GFW 的位置”理解）：
#   方案1：出口设备在国外，入口设备在国内
#         -> 入口用 VLESS+REALITY，出口隧道用 VLESS Encryption
#   方案2：入口设备在国外，出口设备在国内
#         -> 入口用 VLESS Encryption，出口隧道用 VLESS+REALITY
#   方案3：出入口设备都在国外
#         -> 两端都用 VLESS Encryption
#   方案4：出入口设备都在国内
#         -> 两端都用 VLESS+REALITY
#   原则：哪一端设备在国内，那一端就用 VLESS+REALITY 伪装；国外端用简单
#         VLESS Encryption 即可。可一次选择多个方案（如 12/1234）。
#   可选：额外添加一个出口为中转 VPS 的 VLESS+REALITY 单节点。
#
# 依据：
#   配置字段均以 Xray-core 官方全量文档（https://xtls.github.io/llms-full.txt）
#   中确认过的字段与限制为准；VLESS 入站统一使用 clients（实测运行时仅
#   clients 生效）；安装与服务管理参考官方 XTLS/Xray-install（含 Alpine/OpenRC）。
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

http_get() {
  if command -v wget >/dev/null 2>&1; then
    wget -qO- "$1"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1"
  else
    die "未找到 wget 或 curl，请先安装（Debian/Ubuntu: apt install -y curl；Alpine: apk add curl）。"
  fi
}

http_download() {
  if command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$1"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$2" "$1"
  else
    die "未找到 wget 或 curl，请先安装。"
  fi
}

valid_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null; then
    return 0
  fi
  return 1
}

valid_short_id() {
  case "$1" in
    *[!0-9a-fA-F]*) return 1 ;;
  esac
  _sid_len=${#1}
  if [ $((_sid_len % 2)) -ne 0 ]; then return 1; fi
  if [ "$_sid_len" -gt 16 ]; then return 1; fi
  return 0
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "Xray-linux-64.zip" ;;
    aarch64|arm64) echo "Xray-linux-arm64-v8a.zip" ;;
    *) die "不支持的 CPU 架构：$(uname -m)" ;;
  esac
}

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

# 校验方案选择：只允许 1-4 的数字组合
validate_cases() {
  case "$1" in
    ''|*[!1-4]*) return 1 ;;
  esac
  return 0
}

# 方案 -> 入口/隧道协议
entry_proto_of() { # 1/4 -> reality; 2/3 -> enc
  case "$1" in
    1|4) echo "reality" ;;
    *) echo "enc" ;;
  esac
}
bridge_proto_of() { # 1/3 -> enc; 2/4 -> reality
  case "$1" in
    2|4) echo "reality" ;;
    *) echo "enc" ;;
  esac
}

# 默认端口建议
default_entry_port() {
  case "$1" in
    1) echo 40143 ;;
    2) echo 40243 ;;
    3) echo 40343 ;;
    4) echo 40443 ;;
  esac
}
default_bridge_port() {
  case "$1" in
    1) echo 50143 ;;
    2) echo 50243 ;;
    3) echo 50343 ;;
    4) echo 50443 ;;
  esac
}

install_xray() {
  if command -v xray >/dev/null 2>&1; then
    if xray vlessenc >/dev/null 2>&1; then
      info "检测到已安装 Xray：$(xray version | head -n 1)"
      if confirm "使用现有 Xray，跳过安装？" "Y"; then
        return 0
      fi
    else
      warn "检测到 Xray，但缺少 vlessenc 命令（版本过旧）。"
      confirm "继续升级到最新版？" "Y" || die "需要新版 Xray，请升级后重试。"
    fi
  fi

  echo
  info "请选择安装方式："
  if [ "$INIT" = "openrc" ]; then
    echo "  1) 官方 Alpine 安装脚本（XTLS/Xray-install alpinelinux，推荐）"
  else
    echo "  1) 官方安装脚本 XTLS/Xray-install（推荐）"
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
          die "未找到 unzip 且无法自动安装，请先安装 unzip 后重试。"
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

gen_reality_keys() {
  _x25519_out=$(xray x25519)
  REALITY_PRIVATE_KEY=$(printf '%s\n' "$_x25519_out" | sed -n 's/^PrivateKey: \(.*\)/\1/p')
  REALITY_PUBLIC_KEY=$(printf '%s\n' "$_x25519_out" | sed -n 's/^Password (PublicKey): \(.*\)/\1/p')
  [ -n "$REALITY_PRIVATE_KEY" ] && [ -n "$REALITY_PUBLIC_KEY" ] || die "解析 x25519 输出失败。"
}

gen_vlessenc() {
  _ve_auth="$1"
  _ve_n=1
  [ "$_ve_auth" = "mlkem" ] && _ve_n=2
  _ve_out=$(xray vlessenc)
  DECRYPTION=$(printf '%s\n' "$_ve_out" | sed -n 's/^"decryption": "\([^"]*\)"/\1/p' | sed -n "${_ve_n}p")
  ENCRYPTION=$(printf '%s\n' "$_ve_out" | sed -n 's/^"encryption": "\([^"]*\)"/\1/p' | sed -n "${_ve_n}p")
  [ -n "$DECRYPTION" ] && [ -n "$ENCRYPTION" ] || die "解析 vlessenc 输出失败。"
}

# ---------- JSON 片段生成 ----------

# REALITY stream 设置（缩进 8 空格用于 streamSettings 内）
reality_stream_block() {
  printf '        "method": "raw",\n'
  printf '        "security": "reality",\n'
  printf '        "realitySettings": {\n'
  printf '          "target": "%s",\n' "$REALITY_TARGET"
  printf '          "serverNames": [%s],\n' "$(json_str_array "$SNIS")"
  printf '          "privateKey": "%s",\n' "$REALITY_PRIVATE_KEY"
  printf '          "shortIds": ["%s"]\n' "$SHORT_ID"
  printf '        }\n'
}

enc_stream_block() {
  printf '        "method": "raw",\n'
  printf '        "security": "none"\n'
}

# 单个 VLESS 入站：proto = reality|enc
# $1=tag $2=port $3=proto $4=id $5=email(可空) $6=reverse-tag(可空) $7=说明注释
emit_inbound() {
  _tag="$1"; _port="$2"; _proto="$3"; _id="$4"; _email="$5"; _rev="$6"; _note="$7"
  printf '    {\n'
  printf '      // %s\n' "$_note"
  printf '      "tag": "%s",\n' "$_tag"
  printf '      "listen": "0.0.0.0",\n'
  printf '      "port": %s,\n' "$_port"
  printf '      "protocol": "vless",\n'
  printf '      "settings": {\n'
  if [ "$_proto" = "enc" ]; then
    printf '        "decryption": "%s",\n' "$DECRYPTION"
  else
    printf '        "decryption": "none",\n'
  fi
  printf '        "clients": [\n'
  if [ -n "$_rev" ]; then
    printf '          { "id": "%s", "flow": "xtls-rprx-vision", "reverse": { "tag": "%s" } }\n' "$_id" "$_rev"
  elif [ -n "$_email" ]; then
    printf '          { "id": "%s", "email": "%s", "flow": "xtls-rprx-vision" }\n' "$_id" "$_email"
  else
    printf '          { "id": "%s", "flow": "xtls-rprx-vision" }\n' "$_id"
  fi
  printf '        ]\n'
  printf '      },\n'
  printf '      "streamSettings": {\n'
  if [ "$_proto" = "enc" ]; then
    enc_stream_block
  else
    reality_stream_block
  fi
  printf '      }\n'
  printf '    }\n'
}

# 组装全部 inbounds
emit_inbounds() {
  _first=1
  for _c in $CASES; do
    _ep=$(cat "$WD/c${_c}.entry_port")
    _bp=$(cat "$WD/c${_c}.bridge_port")
    _eid=$(cat "$WD/c${_c}.entry_id")
    _bid=$(cat "$WD/c${_c}.bridge_id")
    _eemail=$(cat "$WD/c${_c}.entry_email")
    _eproto=$(entry_proto_of "$_c")
    _bproto=$(bridge_proto_of "$_c")
    [ "$_first" -eq 1 ] || printf ',\n'
    _first=0
    if [ "$_eproto" = "reality" ]; then
      emit_inbound "user-case-${_c}" "$_ep" reality "$_eid" "$_eemail" "" "方案${_c} 用户接入（VLESS+REALITY）-> reverse-out-${_c}"
    else
      emit_inbound "user-case-${_c}" "$_ep" enc "$_eid" "$_eemail" "" "方案${_c} 用户接入（VLESS Encryption）-> reverse-out-${_c}"
    fi
    printf ',\n'
    if [ "$_bproto" = "reality" ]; then
      emit_inbound "bridge-case-${_c}" "$_bp" reality "$_bid" "" "reverse-out-${_c}" "方案${_c} 隧道入口（VLESS+REALITY）"
    else
      emit_inbound "bridge-case-${_c}" "$_bp" enc "$_bid" "" "reverse-out-${_c}" "方案${_c} 隧道入口（VLESS Encryption）"
    fi
  done
  if [ "$DIRECT_ENABLED" = "1" ]; then
    printf ',\n'
    emit_inbound "user-direct" "$DIRECT_PORT" reality "$(cat "$WD/direct.uuid")" "$DIRECT_EMAIL" "" "中转 VPS 直连节点（VLESS+REALITY）"
  fi
  printf '\n'
}

emit_routing_rules() {
  _first=1
  for _c in $CASES; do
    if [ "$_first" -eq 1 ]; then _first=0; else printf ',\n'; fi
    printf '      { "inboundTag": ["user-case-%s"], "outboundTag": "reverse-out-%s" }' "$_c" "$_c"
  done
  if [ "$DIRECT_ENABLED" = "1" ]; then
    printf ',\n'
    printf '      { "inboundTag": ["user-direct"], "outboundTag": "direct" }'
  fi
  printf '\n'
}

write_server_config() {
  cat > "$CONF" <<EOF
{
  // 日志级别：debug / info / warning / error / none（官方文档确认）
  "log": { "loglevel": "warning" },
  "inbounds": [
$(emit_inbounds)
  ],
  "outbounds": [
    // 文档强调：公网服务器必须保留明确的默认出站，避免未命中规则误入反向隧道
    { "protocol": "freedom", "tag": "direct" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
$(emit_routing_rules)
    ]
  }
}
EOF
  chmod 644 "$CONF"
}

# ---------- 客户端配置生成 ----------

# VLESS+REALITY 客户端 stream 段（缩进 6 空格，用于 outbound streamSettings）
client_reality_stream() {
  printf '      "streamSettings": {\n'
  printf '        "method": "raw",\n'
  printf '        "security": "reality",\n'
  printf '        "realitySettings": {\n'
  printf '          "serverName": "%s",\n' "$SNI_HOST"
  printf '          "fingerprint": "chrome",\n'
  printf '          "password": "%s",\n' "$REALITY_PUBLIC_KEY"
  printf '          "shortId": "%s"\n' "$SHORT_ID"
  printf '        }\n'
  printf '      }\n'
}

client_enc_stream() {
  printf '      "streamSettings": { "method": "raw", "security": "none" }\n'
}

# 出口（隧道）设备配置：$1=case
write_bridge_client() {
  _c="$1"
  _bid=$(cat "$WD/c${_c}.bridge_id")
  _bp=$(cat "$WD/c${_c}.bridge_port")
  _bproto=$(bridge_proto_of "$_c")
  _f="/root/xray-bridge-case${_c}.jsonc"
  cat > "$_f" <<EOF
{
  // 方案${_c} 出口设备（落地）配置：主动连接 VPS:${_bp} 建立反向隧道
  // v2rayNG 自定义配置导入 / v2rayN 添加自定义配置服务器；保持在线
  "log": { "loglevel": "warning" },
  "inbounds": [],
  "outbounds": [
    { "protocol": "freedom" },
    {
      "protocol": "freedom",
      "tag": "home-direct",
      "settings": {
        "finalRules": [
          { "action": "allow", "network": "tcp,udp", "ip": ["!geoip:private"] }
        ]
      }
    },
    {
      "protocol": "vless",
      "tag": "to-vps",
      "settings": {
        "address": "${VPS_HOST}",
        "port": ${_bp},
        "id": "${_bid}",
        "encryption": "$(if [ "$_bproto" = "reality" ]; then printf 'none'; else printf '%s' "$ENCRYPTION"; fi)",
        "flow": "xtls-rprx-vision",
        "reverse": { "tag": "reverse-in-${_c}" }
      },
$(if [ "$_bproto" = "reality" ]; then client_reality_stream; else client_enc_stream; fi)
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "inboundTag": ["reverse-in-${_c}"], "outboundTag": "home-direct" }
    ]
  }
}
EOF
  info "已生成：$_f（方案${_c} 出口设备导入此文件并保持在线）"
}

# 入口设备为 VLESS Encryption（方案2/3）时的客户端配置：$1=case
write_entry_enc_client() {
  _c="$1"
  _eid=$(cat "$WD/c${_c}.entry_id")
  _ep=$(cat "$WD/c${_c}.entry_port")
  _f="/root/xray-entry-case${_c}.jsonc"
  cat > "$_f" <<EOF
{
  // 方案${_c} 入口设备配置（VLESS Encryption，设备在境外无需伪装）
  // 提供本地 SOCKS 127.0.0.1:1080；若用 v2rayNG/v2rayN 自定义配置，请把本地
  // 入站端口改为客户端要求的值，或仅作为纯出站导入使用。
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "listen": "127.0.0.1", "port": 1080, "protocol": "socks", "settings": { "udp": true } }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "tag": "proxy",
      "settings": {
        "address": "${VPS_HOST}",
        "port": ${_ep},
        "id": "${_eid}",
        "encryption": "${ENCRYPTION}",
        "flow": "xtls-rprx-vision"
      },
$(client_enc_stream)
    },
    { "protocol": "freedom", "tag": "direct" }
  ]
}
EOF
  info "已生成：$_f（方案${_c} 入口设备境外端配置）"
}

# 入口设备为 REALITY 时的分享链接：$1=case
print_case_link() {
  _c="$1"
  _eid=$(cat "$WD/c${_c}.entry_id")
  _ep=$(cat "$WD/c${_c}.entry_port")
  printf '    方案%s: vless://%s@%s:%s?security=reality&flow=xtls-rprx-vision&type=tcp&sni=%s&pbk=%s&sid=%s&fp=chrome#case%s\n' \
    "$_c" "$_eid" "$VPS_HOST" "$_ep" "$SNI_HOST" "$REALITY_PUBLIC_KEY" "$SHORT_ID" "$_c"
}

write_credentials() {
  _f="/root/xray-deploy/credentials.txt"
  {
    echo "== 服务端信息 =="
    echo "VPS_IP=${VPS_HOST}"
    echo "REALITY target: ${REALITY_TARGET}  SNI: ${SNIS}"
    echo "shortId: ${SHORT_ID}"
    echo "REALITY PublicKey(password): ${REALITY_PUBLIC_KEY}"
    echo
    for _c in $CASES; do
      echo "== 方案${_c} =="
      echo "  入口端口=$(cat "$WD/c${_c}.entry_port") 入口协议=$(entry_proto_of "$_c")"
      echo "  隧道端口=$(cat "$WD/c${_c}.bridge_port") 隧道协议=$(bridge_proto_of "$_c")"
      echo "  入口UUID=$(cat "$WD/c${_c}.entry_id")"
      echo "  隧道UUID=$(cat "$WD/c${_c}.bridge_id")"
      echo "  出口设备配置=/root/xray-bridge-case${_c}.jsonc"
      if [ "$(entry_proto_of "$_c")" = "enc" ]; then
        echo "  入口设备配置=/root/xray-entry-case${_c}.jsonc"
      fi
      echo
    done
    if [ "$DIRECT_ENABLED" = "1" ]; then
      echo "== 中转 VPS 直连节点 =="
      echo "  端口=${DIRECT_PORT}  入口UUID=$(cat "$WD/direct.uuid")"
    fi
  } > "$_f"
  info "凭据汇总：$_f"
}

print_summary() {
  echo
  info "================ 部署完成 ================"
  echo "  VPS 地址      : ${VPS_HOST}"
  echo "  REALITY target: ${REALITY_TARGET}  SNI: ${SNIS}"
  echo "  shortId       : ${SHORT_ID}"
  echo
  for _c in $CASES; do
    echo "  方案${_c}：入口$(entry_proto_of "$_c")/${VPS_HOST}:$(cat "$WD/c${_c}.entry_port")，隧道$(bridge_proto_of "$_c")/${VPS_HOST}:$(cat "$WD/c${_c}.bridge_port")"
  done
  if [ "$DIRECT_ENABLED" = "1" ]; then
    echo "  直连节点：REALITY/${VPS_HOST}:${DIRECT_PORT}"
  fi
  echo
  echo "  == 客户端（入口设备）=="
  for _c in $CASES; do
    if [ "$(entry_proto_of "$_c")" = "reality" ]; then
      print_case_link "$_c"
    else
      printf '    方案%s: 使用 /root/xray-entry-case%s.jsonc（VLESS Encryption）\n' "$_c" "$_c"
    fi
  done
  if [ "$DIRECT_ENABLED" = "1" ]; then
    printf '    直连: vless://%s@%s:%s?security=reality&flow=xtls-rprx-vision&type=tcp&sni=%s&pbk=%s&sid=%s&fp=chrome#vps-direct\n' \
      "$(cat "$WD/direct.uuid")" "$VPS_HOST" "$DIRECT_PORT" "$SNI_HOST" "$REALITY_PUBLIC_KEY" "$SHORT_ID"
  fi
  echo
  info "后续步骤："
  echo "  1) 出口设备导入 /root/xray-bridge-caseN.jsonc 并保持在线（方案2/4 隧道为 REALITY，方案1/3 隧道为 VLESS Encryption）。"
  echo "  2) 入口设备按上面提示导入分享链接或配置文件。"
  echo "  3) 详细凭据见 /root/xray-deploy/credentials.txt。"
}

setup_service() {
  if [ "$INIT" = "openrc" ]; then
    info "创建/更新 OpenRC 服务 /etc/init.d/xray"
    cat > /etc/init.d/xray <<'EOF'
#!/sbin/openrc-run

name="Xray Daemon"
description="Xray service"

pidfile="/run/${RC_SVCNAME}.pid"
command="/usr/local/bin/xray"
command_user="root"
command_args="run -c /usr/local/etc/xray/config.json"
extra_commands="checkconfig"

env=${env:-"XRAY_LOCATION_ASSET=/usr/local/share/xray/"}
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
    rc-update add xray >/dev/null 2>&1 || true
    rc-service xray restart >/dev/null 2>&1 || true
    sleep 2
    if pgrep -f '/usr/local/bin/xray run' >/dev/null 2>&1; then
      info "Xray 服务运行中（OpenRC）"
    else
      warn "OpenRC 方式未能保持运行，改用 local.d + nohup（适用受限容器/最小化 Alpine）"
      mkdir -p /var/log/xray
      cat > /etc/local.d/xray.start <<'EOF'
#!/bin/sh
if ! pgrep -f 'xray run' >/dev/null 2>&1; then
  nohup env XRAY_LOCATION_ASSET=/usr/local/share/xray/ /usr/local/bin/xray run -c /usr/local/etc/xray/config.json >/var/log/xray/out.log 2>&1 &
fi
EOF
      chmod +x /etc/local.d/xray.start
      rc-update add local >/dev/null 2>&1 || true
      sh /etc/local.d/xray.start
      sleep 2
      if pgrep -f '/usr/local/bin/xray run' >/dev/null 2>&1; then
        info "Xray 已通过 local.d 启动（开机自启）"
      else
        warn "Xray 仍未运行，请查看 /var/log/xray/out.log"
      fi
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

setup_firewall() {
  if [ "$INIT" = "openrc" ]; then
    warn "Alpine 默认未启用防火墙；若使用云厂商安全组，请手动放行所选端口。"
    return 0
  fi
  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q "Status: active"; then
      if confirm "检测到 ufw 已启用，放行脚本使用到的全部端口？" "Y"; then
        for _p in $ALL_PORTS; do
          ufw allow "${_p}/tcp" >/dev/null
        done
        info "ufw 已放行：$ALL_PORTS"
      fi
    else
      warn "ufw 未启用；若使用云厂商安全组请自行放行端口。"
    fi
  else
    warn "未检测到 ufw；请手动放行云厂商安全组中的相应端口。"
  fi
}

main() {
  [ "$(id -u)" -eq 0 ] || die "请使用 root 运行：sudo $0"

  INIT=$(detect_init)
  info "检测到初始化系统：${INIT}"
  [ "$INIT" != "none" ] || warn "未检测到 systemd/OpenRC，将跳过服务自动配置。"

  DIRECT_ENABLED=0
  ALL_PORTS=""

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
  VPS_HOST=$(ask "VPS 公网 IP 或域名" "${_detected_ip:-}")
  [ -n "$VPS_HOST" ] || die "VPS 地址不能为空。"

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
  info "请选择要部署的方案（可多选，如 1、4、12、1234）："
  echo "  1) 出口在国外 / 入口在国内（入口 REALITY，隧道 VLESS-enc）"
  echo "  2) 入口在国外 / 出口在国内（入口 VLESS-enc，隧道 REALITY）"
  echo "  3) 出入口都在国外（入口 VLESS-enc，隧道 VLESS-enc）"
  echo "  4) 出入口都在国内（入口 REALITY，隧道 REALITY）"
  _case_choice=$(ask "方案组合" "4")
  validate_cases "$_case_choice" || die "无效方案组合：$_case_choice"
  CASES=""
  _seen=""
  _i=0
  while [ -n "$_case_choice" ]; do
    _ch=$(printf '%s' "$_case_choice" | cut -c1)
    _case_choice=$(printf '%s' "$_case_choice" | cut -c2-)
    case "$_seen" in
      *"$_ch"*) continue ;;
    esac
    _seen="${_seen}${_ch}"
    _i=$((_i + 1))
    printf '%s ' "$_ch" >> "$WD/caseorder"
  done
  CASES=$(cat "$WD/caseorder" 2>/dev/null | sed 's/ *$//' || printf '')
  [ -n "$CASES" ] || die "请至少选择一个方案。"

  info "已选择方案：$CASES"

  # 每个方案生成凭证与端口
  for _c in $CASES; do
    echo
    info "配置方案${_c}："
    _def_ep=$(default_entry_port "$_c")
    _def_bp=$(default_bridge_port "$_c")
    while :; do
      _ep=$(ask "方案${_c} 入口端口" "$_def_ep")
      valid_port "$_ep" && break
      warn "端口无效。"
    done
    while :; do
      _bp=$(ask "方案${_c} 隧道端口" "$_def_bp")
      valid_port "$_bp" && break
      warn "端口无效。"
    done
    _eemail=$(ask "方案${_c} 用户 email" "user-case${_c}")
    [ -n "$_eemail" ] || die "email 不能为空。"
    printf '%s\n' "$_ep" > "$WD/c${_c}.entry_port"
    printf '%s\n' "$_bp" > "$WD/c${_c}.bridge_port"
    printf '%s\n' "$_eemail" > "$WD/c${_c}.entry_email"
    xray uuid > "$WD/c${_c}.entry_id"
    xray uuid > "$WD/c${_c}.bridge_id"
    ALL_PORTS="${ALL_PORTS} ${_ep} ${_bp}"
  done

  # 端口唯一性检查
  if printf '%s\n' $ALL_PORTS | tr ' ' '\n' | sed '/^$/d' | sort | uniq -d | grep -q .; then
    die "所选端口存在重复，请重新运行并避免重复端口。"
  fi

  echo
  if confirm "是否需要额外添加一个出口为中转 VPS 的 VLESS+REALITY 单节点？" "Y"; then
    DIRECT_ENABLED=1
    DIRECT_EMAIL=$(ask "直连节点用户 email" "direct")
    while :; do
      DIRECT_PORT=$(ask "直连节点端口" "57717")
      valid_port "$DIRECT_PORT" && break
      warn "端口无效。"
    done
    case " $ALL_PORTS " in
      *" $DIRECT_PORT "*) die "直连节点端口与方案端口重复：$DIRECT_PORT" ;;
    esac
    ALL_PORTS="${ALL_PORTS} ${DIRECT_PORT}"
    xray uuid > "$WD/direct.uuid"
  fi

  echo
  info "VLESS Encryption 认证方式（服务端与客户端必须一致）："
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
  mkdir -p /usr/local/etc/xray /root/xray-deploy
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

  # 生成客户端产物
  for _c in $CASES; do
    write_bridge_client "$_c"
    if [ "$(entry_proto_of "$_c")" = "enc" ]; then
      write_entry_enc_client "$_c"
    fi
  done
  write_credentials

  setup_service
  setup_firewall
  print_summary
}

main "$@"
