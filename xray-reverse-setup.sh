#!/bin/sh
# =============================================================================
# Xray VLESS 反向代理（多场景一对一落地）中转 VPS 交互式部署脚本
#
# 适用系统：Alpine Linux（OpenRC）/ Debian / Ubuntu（systemd）
# 依赖：仅系统自带工具（sh、wget 或 curl、sed、awk、tr、grep），不安装 bash；
#       unzip 只在“手动下载安装”时使用，缺失时会尝试自动安装。
# 需要 root 运行。
#
# 四种场景（按“设备相对 GFW 的位置”理解，可一次多选，如 12 / 1,3 / 1234）：
#   方案1：出口在国外，入口在国内 -> 入口 REALITY，隧道 VLESS Encryption
#   方案2：入口在国外，出口在国内 -> 入口 VLESS Encryption，隧道 REALITY
#   方案3：出入口都在国外       -> 两端都是 VLESS Encryption
#   方案4：出入口都在国内       -> 两端都是 VLESS+REALITY
#   原则：哪一端在国内，那一端就套 REALITY 伪装；国外端用 VLESS Encryption。
#   可选：额外加一个“出口为本中转 VPS”的 VLESS+REALITY 单节点。
#
# 用法：
#   一条命令（root，脚本直接从终端读取输入，无需先落盘）：
#     sh -c "$(wget -qO- https://github.com/loser641/xray-reverse-setup/raw/main/xray-reverse-setup.sh)"
#   已下载到本地时：
#     ./xray-reverse-setup.sh              # 交互式部署
#     ./xray-reverse-setup.sh --defaults   # 所有提问使用默认值（预演/自动化）
#     ./xray-reverse-setup.sh --help
#   部署完成后会安装快捷命令 lray，直接输入 lray 即可重新唤起（自动取最新版，
#   失败时用本地缓存）。
#
# 说明：交互提示一律写到终端（stdout 只用于返回值），因此本脚本既能直接
#       运行，也能在 `sh -c "$(curl ...)"` / `curl ... | sh` 这类场景下工作。
# =============================================================================

set -eu
umask 022

# 受限环境（cron、非登录 shell）常常没有 sbin，这里固定一份可用的 PATH
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

# 脚本自身地址：lray 快捷命令、离线缓存都会用到
SCRIPT_URL="https://github.com/loser641/xray-reverse-setup/raw/main/xray-reverse-setup.sh"

# ---------------------------------------------------------------- 输出与颜色
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _esc=$(printf '\033')
  C_RED="${_esc}[31m"
  C_GREEN="${_esc}[32m"
  C_YELLOW="${_esc}[33m"
  C_BLUE="${_esc}[34m"
  C_RESET="${_esc}[0m"
else
  C_RED=''
  C_GREEN=''
  C_YELLOW=''
  C_BLUE=''
  C_RESET=''
fi

info() { printf '%s[*]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------- 交互输入
# 提示符绝不能写 stdout：ask() 的返回值是通过 $(ask ...) 捕获的，
# 一旦提示符也被 stdout 捕获，变量里就会变成 "[?] ... 1" 而不是 "1"。
# 优先使用 /dev/tty，这样 `curl ... | sh` 也能正常提问。
HAS_TTY=0
if [ -t 0 ]; then
  : # stdin 就是终端，直接读 stdin
elif [ -z "${XRAY_SETUP_NO_TTY:-}" ]; then
  # 用子 shell 探测：exec 重定向失败会让 dash/ash 直接退出（即使写在 if 里）
  if ( : </dev/tty ) 2>/dev/null; then
    HAS_TTY=1
  fi
fi

_ui() {
  if [ "$HAS_TTY" = "1" ]; then
    printf '%b' "$1" >/dev/tty 2>/dev/null || printf '%b' "$1" >&2
  else
    printf '%b' "$1" >&2
  fi
}

_read_line() {
  _line=''
  if [ "$HAS_TTY" = "1" ]; then
    IFS= read -r _line < /dev/tty
  else
    IFS= read -r _line
  fi
}

_trim() {
  printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# 读取一行并回显默认值；结果写入 stdout，只给 $(...) 用
ask() {
  _ask_prompt=$1
  _ask_def=${2-}
  _ask_hint=$_ask_prompt
  [ -n "$_ask_def" ] && _ask_hint="$_ask_hint [$_ask_def]"

  if [ "$ASSUME_DEFAULTS" = "1" ]; then
    _ui "${C_BLUE}[?]${C_RESET} ${_ask_hint}: ${C_YELLOW}${_ask_def}${C_RESET} (使用默认值)\n"
    printf '%s\n' "$_ask_def"
    return 0
  fi

  _ui "${C_BLUE}[?]${C_RESET} ${_ask_hint}: "
  if ! _read_line; then
    _ui '\n'
    die "读取输入失败（标准输入已结束）。"
  fi
  _ask_ans=$(_trim "$_line")
  [ -n "$_ask_ans" ] || _ask_ans=$_ask_def
  printf '%s\n' "$_ask_ans"
}

# 是/否；$2 为默认值（Y 或 N）
confirm() {
  _cf_prompt=$1
  _cf_def=${2:-N}
  if [ "$ASSUME_DEFAULTS" = "1" ]; then
    _ui "${C_BLUE}[?]${C_RESET} ${_cf_prompt} [${_cf_def}]: ${C_YELLOW}${_cf_def}${C_RESET} (使用默认值)\n"
    case "$_cf_def" in
      [yY]*) return 0 ;;
      *)     return 1 ;;
    esac
  fi

  _ui "${C_BLUE}[?]${C_RESET} ${_cf_prompt} [${_cf_def}]: "
  if ! _read_line; then
    _ui '\n'
    die "读取输入失败（标准输入已结束）。"
  fi
  _cf_ans=$(_trim "$_line")
  [ -n "$_cf_ans" ] || _cf_ans=$_cf_def
  case "$_cf_ans" in
    [yY]*) return 0 ;;
    *)     return 1 ;;
  esac
}

# ---------------------------------------------------------------- 校验
valid_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    0*)          return 1 ;;   # 拒绝前导零（也拒绝 0）
  esac
  [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

valid_short_id() {
  [ -n "$1" ] || return 1
  case "$1" in
    *[!0-9a-fA-F]*) return 1 ;;
  esac
  [ $(( ${#1} % 2 )) -eq 0 ] && [ "${#1}" -le 16 ]
}

# 方案组合只允许 1-4 的数字（允许 1,2 / 1 2 / 1，2 这类写法，由 normalize_cases 预处理）
validate_cases() {
  case "$1" in
    ''|*[!1-4]*) return 1 ;;
  esac
  return 0
}

normalize_cases() {
  printf '%s' "$1" | tr -d ' \t,，、;；'
}

# ---------------------------------------------------------------- 环境探测
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "Xray-linux-64.zip" ;;
    aarch64|arm64)  echo "Xray-linux-arm64-v8a.zip" ;;
    *) die "不支持的 CPU 架构：$(uname -m)" ;;
  esac
}

detect_init() {
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    echo "systemd"
  elif [ -f /etc/alpine-release ]; then
    echo "openrc"
  elif command -v rc-service >/dev/null 2>&1 || [ -d /run/openrc ]; then
    echo "openrc"
  else
    echo "none"
  fi
}

detect_public_ip() {
  _ip=''
  if command -v curl >/dev/null 2>&1; then
    _ip=$(curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null || true)
  fi
  if [ -z "$_ip" ] && command -v wget >/dev/null 2>&1; then
    _ip=$(wget -qO- -T 5 https://api.ipify.org 2>/dev/null || true)
  fi
  if [ -z "$_ip" ]; then
    _ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi
  if [ -z "$_ip" ]; then
    _ip=$(hostname -i 2>/dev/null | awk '{print $1}')
  fi
  printf '%s' "$_ip"
}

# ---------------------------------------------------------------- 网络
http_get() {
  if command -v wget >/dev/null 2>&1; then
    wget -qO- -T 30 "$1"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 15 "$1"
  else
    die "未找到 wget 或 curl，请先安装（Alpine: apk add curl；Debian/Ubuntu: apt install -y curl）。"
  fi
}

# 下载到文件，失败返回非 0（不直接退出，便于调用方给出更准确的提示）
download() {
  rm -f "$2"
  if command -v wget >/dev/null 2>&1; then
    # BusyBox wget 没有 --tries，先探测再决定参数
    if wget --help 2>&1 | grep -q -- '--tries'; then
      wget -q -T 30 --tries=2 -O "$2" "$1" || { rm -f "$2"; return 1; }
    else
      wget -q -T 30 -O "$2" "$1" || { rm -f "$2"; return 1; }
    fi
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 15 --retry 2 -o "$2" "$1" || { rm -f "$2"; return 1; }
  else
    return 1
  fi
  [ -s "$2" ]
}

unzip_file() { # $1=zip 文件；解压到当前目录
  if command -v unzip >/dev/null 2>&1; then
    unzip -o "$1"
  elif command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -qx 'unzip'; then
    busybox unzip -o "$1"
  elif command -v apk >/dev/null 2>&1; then
    info "安装 unzip（Alpine）..."
    apk add --no-cache unzip >/dev/null
    unzip -o "$1"
  elif command -v apt-get >/dev/null 2>&1; then
    info "安装 unzip（Debian/Ubuntu）..."
    apt-get update -qq >/dev/null
    apt-get install -y -qq unzip >/dev/null
    unzip -o "$1"
  else
    die "未找到 unzip 且无法自动安装，请先安装 unzip 后重试。"
  fi
}

# ---------------------------------------------------------------- lray 快捷命令
# 安装 /usr/local/bin/lray：输入 lray 即可重新唤起本脚本。
# 每次先尝试拉最新版并更新缓存，失败时用本地缓存；首次缓存由本次部署写入。
install_lray() {
  _lray_bin=/usr/local/bin
  _lray_dir=/usr/local/share/xray-setup
  _lray_cache="$_lray_dir/xray-reverse-setup.sh"

  if ! mkdir -p "$_lray_bin" "$_lray_dir" 2>/dev/null; then
    warn "无法创建 lray 安装目录，跳过快捷命令安装。"
    return 0
  fi

  # 首次缓存：从文件运行就直接复制当前脚本；管道方式运行则重新拉一份
  if [ -f "$0" ] && [ -r "$0" ] && head -n 1 "$0" 2>/dev/null | grep -q '^#!/bin/sh'; then
    case "$0" in
      */*) grep -q 'xray-reverse-setup' "$0" 2>/dev/null && cp "$0" "$_lray_cache" 2>/dev/null || true ;;
    esac
  fi
  if [ ! -s "$_lray_cache" ]; then
    if download "$SCRIPT_URL" "${_lray_cache}.tmp" 2>/dev/null; then
      mv "${_lray_cache}.tmp" "$_lray_cache"
    else
      rm -f "${_lray_cache}.tmp"
    fi
  fi

  sed "s|@SCRIPT_URL@|$SCRIPT_URL|" > "$_lray_bin/lray" <<'LRAY'
#!/bin/sh
# lray — 重新唤起 Xray 反向代理部署脚本（由 xray-reverse-setup.sh 安装）
# 先取最新版并更新缓存，失败时用本地缓存；LRAY_OFFLINE=1 可强制离线。
set -u

URL=${LRAY_URL:-@SCRIPT_URL@}
CACHE=${LRAY_CACHE:-/usr/local/share/xray-setup/xray-reverse-setup.sh}

if [ "$(id -u)" -ne 0 ]; then
  echo "[x] 请用 root 运行：sudo lray" >&2
  exit 1
fi

mkdir -p "${CACHE%/*}" 2>/dev/null || true

_tmp="${CACHE}.new.$$"
_ok=1
if [ -z "${LRAY_OFFLINE:-}" ]; then
  if command -v wget >/dev/null 2>&1; then
    if wget --help 2>&1 | grep -q -- '--tries'; then
      wget -q -T 30 --tries=1 -O "$_tmp" "$URL" && _ok=0
    else
      wget -q -T 30 -O "$_tmp" "$URL" && _ok=0
    fi
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 15 --retry 2 -o "$_tmp" "$URL" && _ok=0
  fi
fi

if [ "$_ok" -eq 0 ] && head -n 1 "$_tmp" 2>/dev/null | grep -q '^#!/bin/sh'; then
  mv "$_tmp" "$CACHE"
else
  rm -f "$_tmp"
  if [ -f "$CACHE" ]; then
    if [ -z "${LRAY_OFFLINE:-}" ]; then
      echo "[!] 获取最新脚本失败，改用本地缓存：$CACHE" >&2
    fi
  else
    echo "[x] 获取脚本失败，且本地没有缓存。" >&2
    exit 1
  fi
fi

exec sh "$CACHE" "$@"
LRAY

  chmod 755 "$_lray_bin/lray"
  info "已安装快捷命令 lray（重新唤起：lray；帮助：lray --help）"
}

# ---------------------------------------------------------------- 安装 Xray
install_xray() {
  if command -v xray >/dev/null 2>&1; then
    if xray vlessenc >/dev/null 2>&1; then
      info "检测到已安装 Xray：$(xray version | head -n 1)"
      if confirm "直接使用现有 Xray（跳过安装）？" "Y"; then
        return 0
      fi
    else
      warn "检测到 Xray，但缺少 vlessenc 命令（版本过旧，需 >= v24.11）。"
      confirm "继续安装/升级到最新版？" "Y" \
        || die "需要新版 Xray（含 VLESS Encryption）才能继续。"
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
        download "https://github.com/XTLS/Xray-install/raw/main/alpinelinux/install-release.sh" \
          "$WD/install-release.sh" || die "下载官方安装脚本失败，请检查网络。"
        sh "$WD/install-release.sh"
      else
        command -v bash >/dev/null 2>&1 \
          || die "官方安装脚本需要 bash，请先安装 bash（apt install -y bash）。"
        info "正在使用官方安装脚本安装 Xray ..."
        bash -c "$(http_get https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
      fi
      ;;
    2)
      _zip=$(detect_arch)
      info "下载 ${_zip} ..."
      download "https://github.com/XTLS/Xray-core/releases/latest/download/${_zip}" \
        "$WD/${_zip}" || die "下载 ${_zip} 失败，请检查网络后重试。"
      (
        cd "$WD"
        unzip_file "$_zip" >/dev/null
        [ -f xray ] || die "压缩包内未找到 xray 可执行文件。"
        install -m 755 xray /usr/local/bin/xray
        mkdir -p /usr/local/share/xray
        [ -f geoip.dat ]  && install -m 644 geoip.dat  /usr/local/share/xray/ || true
        [ -f geosite.dat ] && install -m 644 geosite.dat /usr/local/share/xray/ || true
      )
      ;;
    3)
      info "跳过安装，请自行确保 xray 可用且支持 vlessenc 命令。"
      ;;
    *)
      die "无效选择：$_inst_choice（应为 1、2 或 3）"
      ;;
  esac

  command -v xray >/dev/null 2>&1 || die "xray 不可用，安装失败。"
  xray vlessenc >/dev/null 2>&1 || die "xray 版本过旧（缺少 vlessenc），无法继续。"
  info "Xray 版本：$(xray version | head -n 1)"
}

# ---------------------------------------------------------------- 密钥生成
gen_reality_keys() {
  _x25519_out=$(xray x25519) || die "执行 xray x25519 失败。"
  REALITY_PRIVATE_KEY=$(printf '%s\n' "$_x25519_out" | sed -n 's/^PrivateKey:[[:space:]]*//p' | head -n 1)
  # 新版输出 Password (PublicKey)，旧版输出 PublicKey / Password
  REALITY_PUBLIC_KEY=$(printf '%s\n' "$_x25519_out" \
    | sed -n -e 's/^Password (PublicKey):[[:space:]]*//p' \
             -e 's/^PublicKey:[[:space:]]*//p' \
             -e 's/^Password:[[:space:]]*//p' \
    | head -n 1)
  [ -n "$REALITY_PRIVATE_KEY" ] && [ -n "$REALITY_PUBLIC_KEY" ] || die "解析 x25519 输出失败。"
}

# $1=x25519|mlkem；vlessenc 会依次输出两对（先 X25519，后 ML-KEM-768）
gen_vlessenc() {
  _ve_auth=$1
  _ve_n=1
  [ "$_ve_auth" = "mlkem" ] && _ve_n=2

  _ve_out=$(xray vlessenc) || die "执行 xray vlessenc 失败。"
  _ve_dec_all=$(printf '%s\n' "$_ve_out" \
    | sed -n 's/^[[:space:]]*"decryption":[[:space:]]*"\([^"]*\)".*/\1/p')
  _ve_enc_all=$(printf '%s\n' "$_ve_out" \
    | sed -n 's/^[[:space:]]*"encryption":[[:space:]]*"\([^"]*\)".*/\1/p')

  DECRYPTION=$(printf '%s\n' "$_ve_dec_all" | sed -n "${_ve_n}p")
  ENCRYPTION=$(printf '%s\n' "$_ve_enc_all" | sed -n "${_ve_n}p")
  [ -n "$DECRYPTION" ] && [ -n "$ENCRYPTION" ] || die "解析 vlessenc 输出失败。"
}

# ---------------------------------------------------------------- JSON 片段
# 逗号分隔列表 -> JSON 字符串数组，如 "a.com,b.com" -> "a.com", "b.com"
json_str_array() {
  _js_list=$1
  _js_out=''
  _js_first=1
  while [ -n "$_js_list" ]; do
    case "$_js_list" in
      *,*) _js_item=${_js_list%%,*}; _js_list=${_js_list#*,} ;;
      *)   _js_item=$_js_list; _js_list='' ;;
    esac
    _js_item=$(_trim "$_js_item")
    [ -n "$_js_item" ] || continue
    if [ "$_js_first" -eq 1 ]; then
      _js_first=0
    else
      _js_out="$_js_out, "
    fi
    _js_out="${_js_out}\"${_js_item}\""
  done
  printf '%s' "$_js_out"
}

# 方案 -> 入口 / 隧道协议
entry_proto_of() {
  case "$1" in
    1|4) echo "reality" ;;
    *)   echo "enc" ;;
  esac
}

bridge_proto_of() {
  case "$1" in
    2|4) echo "reality" ;;
    *)   echo "enc" ;;
  esac
}

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

# 单个 VLESS 入站：$1=tag $2=port $3=proto $4=id $5=email $6=reverse-tag $7=注释
emit_inbound() {
  _tag=$1
  _port=$2
  _proto=$3
  _id=$4
  _email=$5
  _rev=$6
  _note=$7

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

emit_inbounds() {
  _first=1
  for _c in $CASES; do
    _ep=$(cat "$WD/c${_c}.entry_port")
    _bp=$(cat "$WD/c${_c}.bridge_port")
    _eid=$(cat "$WD/c${_c}.entry_id")
    _bid=$(cat "$WD/c${_c}.bridge_id")
    _eemail=$(cat "$WD/c${_c}.entry_email")

    [ "$_first" -eq 1 ] || printf ',\n'
    _first=0

    if [ "$(entry_proto_of "$_c")" = "reality" ]; then
      emit_inbound "user-case-${_c}" "$_ep" reality "$_eid" "$_eemail" "" \
        "方案${_c} 用户接入（VLESS+REALITY）-> reverse-out-${_c}"
    else
      emit_inbound "user-case-${_c}" "$_ep" enc "$_eid" "$_eemail" "" \
        "方案${_c} 用户接入（VLESS Encryption）-> reverse-out-${_c}"
    fi

    printf ',\n'

    if [ "$(bridge_proto_of "$_c")" = "reality" ]; then
      emit_inbound "bridge-case-${_c}" "$_bp" reality "$_bid" "" "reverse-out-${_c}" \
        "方案${_c} 隧道入口（VLESS+REALITY）"
    else
      emit_inbound "bridge-case-${_c}" "$_bp" enc "$_bid" "" "reverse-out-${_c}" \
        "方案${_c} 隧道入口（VLESS Encryption）"
    fi
  done

  if [ "$DIRECT_ENABLED" = "1" ]; then
    printf ',\n'
    emit_inbound "user-direct" "$DIRECT_PORT" reality "$(cat "$WD/direct.uuid")" "$DIRECT_EMAIL" "" \
      "中转 VPS 直连节点（VLESS+REALITY）"
  fi
  printf '\n'
}

emit_routing_rules() {
  _first=1
  for _c in $CASES; do
    if [ "$_first" -eq 1 ]; then
      _first=0
    else
      printf ',\n'
    fi
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
  // 本文件由 xray-reverse-setup.sh 生成，修改后请执行：xray run -test -c $CONF
  "log": { "loglevel": "warning" },
  "inbounds": [
$(emit_inbounds)
  ],
  "outbounds": [
    // 必须保留明确的默认出站，避免未命中规则的流量误入反向隧道
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
}

# ---------------------------------------------------------------- 客户端配置
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

# 出口（落地）设备配置：$1=case
write_bridge_client() {
  _c=$1
  _bid=$(cat "$WD/c${_c}.bridge_id")
  _bp=$(cat "$WD/c${_c}.bridge_port")
  _bproto=$(bridge_proto_of "$_c")
  _f="${OUT_DIR}/xray-bridge-case${_c}.jsonc"

  if [ "$_bproto" = "reality" ]; then
    _b_enc='none'
    _b_stream=$(client_reality_stream)
  else
    _b_enc=$ENCRYPTION
    _b_stream=$(client_enc_stream)
  fi

  cat > "$_f" <<EOF
{
  // 方案${_c} 出口设备（落地）配置：主动连接 ${VPS_HOST}:${_bp} 建立反向隧道
  // 导入方式：v2rayNG「自定义配置」/ v2rayN「添加自定义配置服务器」，保持在线
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
        "encryption": "${_b_enc}",
        "flow": "xtls-rprx-vision",
        "reverse": { "tag": "reverse-in-${_c}" }
      },
${_b_stream}
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
  chmod 600 "$_f"
  info "已生成：$_f（方案${_c} 出口设备导入此文件并保持在线）"
}

# 入口设备为 VLESS Encryption（方案2/3）时的客户端配置：$1=case
write_entry_enc_client() {
  _c=$1
  _eid=$(cat "$WD/c${_c}.entry_id")
  _ep=$(cat "$WD/c${_c}.entry_port")
  _f="${OUT_DIR}/xray-entry-case${_c}.jsonc"

  cat > "$_f" <<EOF
{
  // 方案${_c} 入口设备配置（VLESS Encryption，设备在境外无需伪装）
  // 提供本地 SOCKS 127.0.0.1:1080；用 v2rayNG/v2rayN 时请按其要求修改本地入站端口
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
  chmod 600 "$_f"
  info "已生成：$_f（方案${_c} 入口设备境外端配置）"
}

print_case_link() {
  _c=$1
  _eid=$(cat "$WD/c${_c}.entry_id")
  _ep=$(cat "$WD/c${_c}.entry_port")
  printf '    方案%s: vless://%s@%s:%s?security=reality&flow=xtls-rprx-vision&type=tcp&sni=%s&pbk=%s&sid=%s&fp=chrome#case%s\n' \
    "$_c" "$_eid" "$VPS_HOST" "$_ep" "$SNI_HOST" "$REALITY_PUBLIC_KEY" "$SHORT_ID" "$_c"
}

write_credentials() {
  _f="${OUT_DIR}/xray-deploy/credentials.txt"
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
      echo "  出口设备配置=${OUT_DIR}/xray-bridge-case${_c}.jsonc"
      if [ "$(entry_proto_of "$_c")" = "enc" ]; then
        echo "  入口设备配置=${OUT_DIR}/xray-entry-case${_c}.jsonc"
      fi
      echo
    done
    if [ "$DIRECT_ENABLED" = "1" ]; then
      echo "== 中转 VPS 直连节点 =="
      echo "  端口=${DIRECT_PORT}  入口UUID=$(cat "$WD/direct.uuid")"
    fi
  } > "$_f"
  chmod 600 "$_f"
  info "凭据汇总：$_f"
}

port_listening() { # 0=在听 1=没在听 2=无法检测
  # 优先读 /proc（Alpine 等最小化系统常常没有 ss/netstat）
  if [ -r /proc/net/tcp ] || [ -r /proc/net/tcp6 ]; then
    _pl_hex=$(printf '%04X' "$1")
    if awk -v p=":$_pl_hex" '
        $4 == "0A" && substr($2, length($2) - 4) == p { found = 1 }
        END { exit(found ? 0 : 1) }
      ' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
      return 0
    fi
    return 1
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -lnt 2>/dev/null | awk 'NR>1 {print $4}' | grep -q "[:.]$1\$"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -lnt 2>/dev/null | awk 'NR>2 {print $4}' | grep -q "[:.]$1\$"
  else
    return 2
  fi
}

print_summary() {
  echo
  info "================ 部署完成 ================"
  echo "  VPS 地址      : ${VPS_HOST}"
  echo "  REALITY target: ${REALITY_TARGET}  SNI: ${SNIS}"
  echo "  shortId       : ${SHORT_ID}"
  echo
  for _c in $CASES; do
    echo "  方案${_c}：入口 $(entry_proto_of "$_c")/${VPS_HOST}:$(cat "$WD/c${_c}.entry_port")，隧道 $(bridge_proto_of "$_c")/${VPS_HOST}:$(cat "$WD/c${_c}.bridge_port")"
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
      printf '    方案%s: 使用 %s/xray-entry-case%s.jsonc（VLESS Encryption）\n' "$_c" "$OUT_DIR" "$_c"
    fi
  done
  if [ "$DIRECT_ENABLED" = "1" ]; then
    printf '    直连: vless://%s@%s:%s?security=reality&flow=xtls-rprx-vision&type=tcp&sni=%s&pbk=%s&sid=%s&fp=chrome#vps-direct\n' \
      "$(cat "$WD/direct.uuid")" "$VPS_HOST" "$DIRECT_PORT" "$SNI_HOST" "$REALITY_PUBLIC_KEY" "$SHORT_ID"
  fi

  echo
  echo "  == 端口监听检查 =="
  for _p in $ALL_PORTS; do
    if port_listening "$_p"; then
      printf '    端口 %-5s : %s监听正常%s\n' "$_p" "$C_GREEN" "$C_RESET"
    else
      _st=$?
      if [ "$_st" -eq 2 ]; then
        printf '    端口 %-5s : 无法检测（缺少 ss/netstat）\n' "$_p"
      else
        printf '    端口 %-5s : %s未监听%s（请查看服务日志）\n' "$_p" "$C_YELLOW" "$C_RESET"
      fi
    fi
  done

  echo
  info "后续步骤："
  echo "  1) 出口设备导入 ${OUT_DIR}/xray-bridge-caseN.jsonc 并保持在线"
  echo "     （方案1/3 隧道为 VLESS Encryption，方案2/4 隧道为 REALITY）。"
  echo "  2) 入口设备导入上面的分享链接或 ${OUT_DIR}/xray-entry-caseN.jsonc。"
  echo "  3) 详细凭据见 ${OUT_DIR}/xray-deploy/credentials.txt。"
  echo "  4) 云厂商安全组 / 防火墙需放行：${ALL_PORTS}"
}

# ---------------------------------------------------------------- 服务
service_user() {
  _su=''
  if [ -f /etc/systemd/system/xray.service ]; then
    _su=$(sed -n 's/^User=[[:space:]]*//p' /etc/systemd/system/xray.service | head -n 1)
  fi
  if [ -z "$_su" ] && [ -f /etc/init.d/xray ]; then
    _su=$(sed -n 's/^[[:space:]]*command_user="\([^":]*\).*/\1/p' /etc/init.d/xray | head -n 1)
  fi
  printf '%s' "${_su:-root}"
}

secure_config() {
  _user=$(service_user)
  if chown "$_user" "$CONF" 2>/dev/null; then
    chmod 600 "$CONF"
  else
    chmod 644 "$CONF"
    warn "无法将 $CONF 归属到服务用户 ${_user}，已设为 644（服务用户需可读）。"
  fi
}

setup_service_openrc() {
  if [ -f /etc/init.d/xray ]; then
    info "复用已有 OpenRC 服务：/etc/init.d/xray"
  else
    info "创建 OpenRC 服务：/etc/init.d/xray"
    cat > /etc/init.d/xray <<'UNIT'
#!/sbin/openrc-run

name="Xray Daemon"
description="Xray service"

pidfile="/run/${RC_SVCNAME}.pid"
command="/usr/local/bin/xray"
command_args="run -c /usr/local/etc/xray/config.json"
command_user="root"
command_background="true"
output_log="/var/log/xray/out.log"
error_log="/var/log/xray/err.log"
extra_commands="checkconfig"
required_files="/usr/local/etc/xray/config.json"
directory="/usr/local/share/xray"

depend() {
	need net
	want dns ntp-client
	after firewall
}

checkconfig() {
	XRAY_LOCATION_ASSET=/usr/local/share/xray/ "$command" run -test -c /usr/local/etc/xray/config.json
}

start_pre() {
	mkdir -p /var/log/xray
	checkconfig || return 1
}
UNIT
    chmod +x /etc/init.d/xray
  fi

  mkdir -p /var/log/xray
  rc-update add xray default >/dev/null 2>&1 || true
  rc-service xray restart >/dev/null 2>&1 || true

  _i=0
  _up=0
  while [ "$_i" -lt 10 ]; do
    if rc-service xray status >/dev/null 2>&1; then
      _up=1
      break
    fi
    sleep 1
    _i=$((_i + 1))
  done

  if [ "$_up" -eq 1 ]; then
    info "Xray 服务运行中（OpenRC）"
    return 0
  fi

  warn "OpenRC 未能拉起 Xray，改用 local.d + nohup 兜底（受限容器/最小化 Alpine 常见）。"
  mkdir -p /etc/local.d /var/log/xray
  cat > /etc/local.d/xray.start <<'EOF'
#!/bin/sh
[ -x /usr/local/bin/xray ] || exit 0
pgrep -f '/usr/local/bin/xray run' >/dev/null 2>&1 && exit 0
nohup env XRAY_LOCATION_ASSET=/usr/local/share/xray/ \
  /usr/local/bin/xray run -c /usr/local/etc/xray/config.json \
  >>/var/log/xray/out.log 2>&1 &
EOF
  chmod +x /etc/local.d/xray.start
  rc-update add local default >/dev/null 2>&1 || true
  sh /etc/local.d/xray.start

  _i=0
  while [ "$_i" -lt 10 ]; do
    if pgrep -f '/usr/local/bin/xray run' >/dev/null 2>&1; then
      info "Xray 已通过 local.d 启动（开机自启）"
      return 0
    fi
    sleep 1
    _i=$((_i + 1))
  done
  warn "Xray 仍未运行，请查看 /var/log/xray/out.log"
  return 0
}

setup_service_systemd() {
  if [ -f /etc/systemd/system/xray.service ]; then
    info "复用已有 systemd 服务：/etc/systemd/system/xray.service"
  else
    info "创建 systemd 服务：xray.service"
    cat > /etc/systemd/system/xray.service <<'UNIT'
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
Type=simple
Environment="XRAY_LOCATION_ASSET=/usr/local/share/xray"
ExecStart=/usr/local/bin/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=3
RestartPreventExitStatus=23
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
  fi

  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray >/dev/null 2>&1 || true

  _i=0
  while [ "$_i" -lt 10 ]; do
    if systemctl is-active --quiet xray; then
      info "Xray 服务运行中（systemd）"
      return 0
    fi
    sleep 1
    _i=$((_i + 1))
  done
  warn "Xray 服务未正常运行，请查看：journalctl -u xray -n 50"
  return 0
}

setup_service() {
  case "$INIT" in
    openrc)  setup_service_openrc ;;
    systemd) setup_service_systemd ;;
    *)
      warn "未检测到 systemd/OpenRC，跳过服务配置。请自行常驻运行："
      echo "    xray run -c $CONF"
      ;;
  esac
}

setup_firewall() {
  if [ "$INIT" = "openrc" ]; then
    warn "Alpine 默认没有启用防火墙；若有云厂商安全组，请放行：${ALL_PORTS}"
    return 0
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    confirm "检测到 ufw 已启用，放行本次使用的端口？" "Y" || return 0
    for _p in $ALL_PORTS; do
      ufw allow "${_p}/tcp" >/dev/null
    done
    info "ufw 已放行：${ALL_PORTS}"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    confirm "检测到 firewalld 已启用，放行本次使用的端口？" "Y" || return 0
    for _p in $ALL_PORTS; do
      firewall-cmd --permanent --add-port="${_p}/tcp" >/dev/null
    done
    firewall-cmd --reload >/dev/null
    info "firewalld 已放行：${ALL_PORTS}"
  else
    warn "未检测到已启用的 ufw/firewalld；请自行放行：${ALL_PORTS}"
  fi
}

# ---------------------------------------------------------------- 参数与主流程
usage() {
  cat <<'EOF'
Xray VLESS 反向代理（多场景一对一落地）中转 VPS 部署脚本

用法：
  # 一条命令（root，交互输入照常）
  sh -c "$(wget -qO- https://github.com/loser641/xray-reverse-setup/raw/main/xray-reverse-setup.sh)"
  ./xray-reverse-setup.sh             交互式部署（推荐）
  ./xray-reverse-setup.sh --defaults  所有提问取默认值（预演/无人值守）
  ./xray-reverse-setup.sh --help      显示本帮助
  lray                                部署后安装的快捷命令，重新唤起本脚本

环境变量：
  NO_COLOR=1              关闭彩色输出
  XRAY_SETUP_NO_TTY=1     不读取 /dev/tty，仅从 stdin 取输入（CI 用）
  XRAY_SETUP_OUT_DIR=DIR  客户端配置/凭据输出目录（默认 /root）

方案：
  1) 出口在国外 / 入口在国内（入口 REALITY，隧道 VLESS Encryption）
  2) 入口在国外 / 出口在国内（入口 VLESS Encryption，隧道 REALITY）
  3) 出入口都在国外（两端 VLESS Encryption）
  4) 出入口都在国内（两端 VLESS+REALITY）
  可多选：12、1,3、1234
EOF
}

parse_args() {
  ASSUME_DEFAULTS=0
  for _arg in "$@"; do
    case "$_arg" in
      -y|--yes|--defaults) ASSUME_DEFAULTS=1 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "未知参数：$_arg" ;;
    esac
  done
}

main() {
  parse_args "$@"

  [ "$(id -u)" -eq 0 ] || die "请使用 root 运行（sudo -i 后重试）。"

  INIT=$(detect_init)
  info "初始化系统：${INIT}"
  [ "$INIT" != "none" ] || warn "未检测到 systemd/OpenRC，将跳过服务自动配置。"

  install_lray

  DIRECT_ENABLED=0
  ALL_PORTS=''
  OUT_DIR=${XRAY_SETUP_OUT_DIR:-/root}

  WD=$(mktemp -d "${TMPDIR:-/tmp}/xray-setup.XXXXXX") || {
    WD="/tmp/xray-setup.$$"
    mkdir -p "$WD"
  }
  trap 'rm -rf "$WD"' EXIT INT TERM

  CONF="/usr/local/etc/xray/config.json"
  mkdir -p /usr/local/etc/xray /usr/local/share/xray "$OUT_DIR/xray-deploy"
  chmod 700 "$OUT_DIR/xray-deploy"

  install_xray

  echo
  info "==== 开始收集部署参数 ===="
  _detected_ip=$(detect_public_ip)
  VPS_HOST=$(ask "VPS 公网 IP 或域名" "${_detected_ip:-}")
  [ -n "$VPS_HOST" ] || die "VPS 地址不能为空。"

  REALITY_TARGET=$(ask "REALITY 伪装目标 target（格式 域名:端口）" "itunes.apple.com:443")
  case "$REALITY_TARGET" in
    *:*) : ;;
    *)   REALITY_TARGET="${REALITY_TARGET}:443" ;;
  esac
  SNI_HOST=${REALITY_TARGET%%:*}
  SNIS=$(ask "SNI 列表（逗号分隔，默认与 target 主机名一致）" "$SNI_HOST")
  [ -n "$SNIS" ] || die "SNI 不能为空。"

  _def_sid=$(xray uuid | tr -d '-' | cut -c1-4)
  while :; do
    SHORT_ID=$(ask "REALITY shortId（0-f 十六进制、偶数位、不超过 16 位）" "$_def_sid")
    valid_short_id "$SHORT_ID" && break
    warn "shortId 必须是 0-f 十六进制、偶数位、不超过 16 位，且不能为空。"
  done

  echo
  info "请选择要部署的方案（可多选，如 1、4、12、1,3、1234）："
  echo "  1) 出口在国外 / 入口在国内（入口 REALITY，隧道 VLESS Encryption）"
  echo "  2) 入口在国外 / 出口在国内（入口 VLESS Encryption，隧道 REALITY）"
  echo "  3) 出入口都在国外（两端 VLESS Encryption）"
  echo "  4) 出入口都在国内（两端 VLESS+REALITY）"
  _case_choice=$(normalize_cases "$(ask "方案组合" "4")")
  validate_cases "$_case_choice" || die "无效方案组合：$_case_choice（只允许 1-4）"

  CASES=''
  _seen=''
  _rest=$_case_choice
  while [ -n "$_rest" ]; do
    _ch=${_rest%"${_rest#?}"}
    _rest=${_rest#?}
    case " $_seen " in
      *" $_ch "*) continue ;;
    esac
    _seen="${_seen} ${_ch}"
    CASES="${CASES:+$CASES }${_ch}"
  done
  [ -n "$CASES" ] || die "请至少选择一个方案。"
  info "已选择方案：${CASES}"

  for _c in $CASES; do
    echo
    info "配置方案${_c}："
    _def_ep=$(default_entry_port "$_c")
    _def_bp=$(default_bridge_port "$_c")

    while :; do
      _ep=$(ask "方案${_c} 入口端口" "$_def_ep")
      valid_port "$_ep" && break
      warn "端口无效（1-65535，且不要前导零）。"
    done
    while :; do
      _bp=$(ask "方案${_c} 隧道端口" "$_def_bp")
      valid_port "$_bp" && break
      warn "端口无效（1-65535，且不要前导零）。"
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

  if printf '%s\n' $ALL_PORTS | sed '/^$/d' | sort | uniq -d | grep -q .; then
    die "所选端口存在重复，请重新运行并避免重复端口。"
  fi

  echo
  if confirm "是否需要额外添加一个“出口为本中转 VPS”的 VLESS+REALITY 单节点？" "Y"; then
    DIRECT_ENABLED=1
    DIRECT_EMAIL=$(ask "直连节点用户 email" "direct")
    while :; do
      DIRECT_PORT=$(ask "直连节点端口" "57717")
      valid_port "$DIRECT_PORT" && break
      warn "端口无效。"
    done
    case " ${ALL_PORTS} " in
      *" ${DIRECT_PORT} "*) die "直连节点端口与方案端口重复：${DIRECT_PORT}" ;;
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
    *) die "无效选择：$_ve_choice（应为 1 或 2）" ;;
  esac

  gen_reality_keys

  _bak=''
  if [ -f "$CONF" ]; then
    if confirm "检测到已有 $CONF，备份后覆盖？" "Y"; then
      _bak="${CONF}.bak.$(date +%Y%m%d%H%M%S)"
      cp -a "$CONF" "$_bak"
      info "已备份到 $_bak"
    else
      die "已取消，请先手动处理 $CONF 后重试。"
    fi
  fi

  write_server_config
  secure_config

  info "校验配置（xray run -test）..."
  if ! _test_out=$(xray run -test -c "$CONF" 2>&1); then
    printf '%s\n' "$_test_out" >&2
    if [ -n "$_bak" ]; then
      cp -a "$_bak" "$CONF"
      secure_config
      warn "配置校验失败，已还原备份配置。"
    fi
    die "配置校验失败，请根据上面的报错修正后重试。"
  fi
  info "配置校验通过。"

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
