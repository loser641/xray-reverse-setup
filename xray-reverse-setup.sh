#!/bin/sh
# =============================================================================
# Xray VLESS 反向代理（多场景一对一落地）中转 VPS 部署 / 管理脚本
#
# 适用系统：Alpine Linux（OpenRC）/ Debian / Ubuntu（systemd）
# 依赖：仅系统自带工具（sh、wget 或 curl、sed、awk、tr、grep），不安装 bash；
#       unzip 只在“手动下载安装”时使用，缺失时会尝试自动安装。
# 需要 root 运行。
#
# 设计：
#   入站按协议合并，不再每个方案各占一个端口：
#     - REALITY 入站（默认 40443）：方案 1/4 的入口 + 方案 2/4 的隧道 + 直连节点
#     - VLESS Encryption 入站（默认 50443）：方案 2/3 的入口 + 方案 1/3 的隧道
#   每个方案仍然有独立的入口/隧道 UUID（作为同一入站里的不同用户），
#   路由按用户邮箱区分：entry-caseN -> reverse-out-N。
#
# 四种场景（按“设备相对 GFW 的位置”理解，可多选，如 12 / 1,4 / 1234）：
#   方案1：出口在国外，入口在国内 -> 入口 REALITY，隧道 VLESS Encryption
#   方案2：入口在国外，出口在国内 -> 入口 VLESS Encryption，隧道 REALITY
#   方案3：出入口都在国外       -> 两端都是 VLESS Encryption
#   方案4：出入口都在国内       -> 两端都是 VLESS+REALITY
#   原则：哪一端在国内，那一端就套 REALITY 伪装；国外端用 VLESS Encryption。
#
# 用法：
#   一条命令安装（root，脚本直接从终端读取输入，无需先落盘）：
#     sh -c "$(wget -qO- https://github.com/loser641/xray-reverse-setup/raw/main/xray-reverse-setup.sh)"
#   安装后输入 lray 打开管理面板（改 SNI/端口/UUID/密钥、查看凭据）。
#
#   ./xray-reverse-setup.sh            已部署则打开面板，否则进入安装
#   ./xray-reverse-setup.sh --panel    打开管理面板
#   ./xray-reverse-setup.sh --install  重新安装/部署
#   ./xray-reverse-setup.sh --defaults 安装时全部取默认值（无人值守）
#   ./xray-reverse-setup.sh --help
#
# 安全：UUID、REALITY 私钥/公钥、VLESS Encryption 密钥、shortId 全部随机生成，
#       不内置任何默认凭证；状态文件与控制面板都可随时重新生成。
# =============================================================================

set -eu
umask 022

# 受限环境（cron、非登录 shell）常常没有 sbin，这里固定一份可用的 PATH
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

# 脚本自身地址：lray 快捷命令、离线缓存都会用到
SCRIPT_URL="https://github.com/loser641/xray-reverse-setup/raw/main/xray-reverse-setup.sh"

CONF="/usr/local/etc/xray/config.json"
STATE="/usr/local/etc/xray/xray-setup.state"
DEFAULT_REALITY_PORT=40443
DEFAULT_ENC_PORT=50443

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

valid_uuid() {
  case "$1" in
    ????????-????-????-????-????????????|????????????????????????????????) : ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!0-9a-fA-F-]*) return 1 ;;
  esac
  _uuid_hex=$(printf '%s' "$1" | tr -d '-')
  [ "${#_uuid_hex}" -eq 32 ]
}

valid_cases() {
  case "$1" in
    ''|*[!1-4]*) return 1 ;;
  esac
  return 0
}

normalize_cases() {
  printf '%s' "$1" | tr -d ' \t,，、;；'
}

# 把 CASES 整理成去重、空格分隔的 "1 2 3 4" 形式；空或非法返回非 0
normalize_cases_var() {
  _nc_raw=$(normalize_cases "$CASES")
  valid_cases "$_nc_raw" || return 1
  _nc_out=''
  _nc_seen=''
  _nc_rest=$_nc_raw
  while [ -n "$_nc_rest" ]; do
    _nc_ch=${_nc_rest%"${_nc_rest#?}"}
    _nc_rest=${_nc_rest#?}
    case " $_nc_seen " in
      *" $_nc_ch "*) continue ;;
    esac
    _nc_seen="$_nc_seen $_nc_ch"
    _nc_out="${_nc_out:+$_nc_out }${_nc_ch}"
  done
  CASES=$_nc_out
  [ -n "$CASES" ]
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
# 安装 /usr/local/bin/lray：输入 lray 即打开管理面板（无状态时提示安装）。
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
      */*) grep -q 'xray-reverse-setup' "$0" 2>/dev/null && [ "$0" != "$_lray_cache" ] \
             && cp "$0" "$_lray_cache" 2>/dev/null || true ;;
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
# lray — 打开 Xray 反向代理管理面板（由 xray-reverse-setup.sh 安装）
# 先取最新版脚本并更新缓存，失败时用本地缓存；LRAY_OFFLINE=1 可强制离线。
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

[ "$#" -gt 0 ] || set -- --panel
exec sh "$CACHE" "$@"
LRAY

  chmod 755 "$_lray_bin/lray"
  info "已安装快捷命令 lray（打开管理面板：lray）"
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
  ENC_AUTH=$_ve_auth
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

gen_short_id() {
  xray uuid | tr -d '-' | cut -c1-8
}

enc_auth_of() {
  if [ "${#DECRYPTION}" -gt 100 ]; then
    echo "mlkem"
  else
    echo "x25519"
  fi
}

# ---------------------------------------------------------------- 方案与协议
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

entry_inbound_of() {
  if [ "$(entry_proto_of "$1")" = "reality" ]; then
    echo "in-reality"
  else
    echo "in-enc"
  fi
}

bridge_port_of() {
  if [ "$(bridge_proto_of "$1")" = "reality" ]; then
    printf '%s' "$REALITY_PORT"
  else
    printf '%s' "$ENC_PORT"
  fi
}

need_reality() {
  [ "$DIRECT_ENABLED" = "1" ] && return 0
  for _nc in $CASES; do
    case "$_nc" in
      1|2|4) return 0 ;;
    esac
  done
  return 1
}

need_enc() {
  for _nc in $CASES; do
    case "$_nc" in
      1|2|3) return 0 ;;
    esac
  done
  return 1
}

var() { eval "printf '%s' \"\${$1-}\""; }
setvar() { eval "$1=\$2"; }

# ---------------------------------------------------------------- 状态
state_ready() {
  [ -f "$STATE" ] && grep -q "^STATE_VERSION='2'$" "$STATE" 2>/dev/null
}

init_state_defaults() {
  STATE_VERSION=2
  VPS_HOST=''
  REALITY_TARGET="itunes.apple.com:443"
  SNI_HOST="itunes.apple.com"
  SNIS="itunes.apple.com"
  SHORT_ID=''
  REALITY_PRIVATE_KEY=''
  REALITY_PUBLIC_KEY=''
  REALITY_PORT=$DEFAULT_REALITY_PORT
  ENC_PORT=$DEFAULT_ENC_PORT
  DECRYPTION=''
  ENCRYPTION=''
  ENC_AUTH=''
  CASES=''
  DIRECT_ENABLED=0
  DIRECT_UUID=''
  U_ENTRY_1=''; U_ENTRY_2=''; U_ENTRY_3=''; U_ENTRY_4=''
  U_BRIDGE_1=''; U_BRIDGE_2=''; U_BRIDGE_3=''; U_BRIDGE_4=''
}

load_state() {
  init_state_defaults
  [ -f "$STATE" ] || return 1
  # shellcheck disable=SC1090
  . "$STATE" 2>/dev/null || true
  if [ "${STATE_VERSION:-0}" != "2" ]; then
    warn "状态文件版本不兼容：$STATE（请重新运行安装）"
    init_state_defaults
    return 1
  fi
  normalize_cases_var || true
  return 0
}

save_state() {
  _ss_dir=${STATE%/*}
  mkdir -p "$_ss_dir" 2>/dev/null || true
  _ss_tmp="${STATE}.tmp.$$"
  {
    printf '%s\n' '# 由 xray-reverse-setup.sh 生成；lray 管理面板读取此文件'
    printf "STATE_VERSION='%s'\n" 2
    printf "VPS_HOST='%s'\n" "$VPS_HOST"
    printf "REALITY_TARGET='%s'\n" "$REALITY_TARGET"
    printf "SNI_HOST='%s'\n" "$SNI_HOST"
    printf "SNIS='%s'\n" "$SNIS"
    printf "SHORT_ID='%s'\n" "$SHORT_ID"
    printf "REALITY_PRIVATE_KEY='%s'\n" "$REALITY_PRIVATE_KEY"
    printf "REALITY_PUBLIC_KEY='%s'\n" "$REALITY_PUBLIC_KEY"
    printf "REALITY_PORT='%s'\n" "$REALITY_PORT"
    printf "ENC_PORT='%s'\n" "$ENC_PORT"
    printf "DECRYPTION='%s'\n" "$DECRYPTION"
    printf "ENCRYPTION='%s'\n" "$ENCRYPTION"
    printf "ENC_AUTH='%s'\n" "$ENC_AUTH"
    printf "CASES='%s'\n" "$CASES"
    printf "DIRECT_ENABLED='%s'\n" "$DIRECT_ENABLED"
    printf "DIRECT_UUID='%s'\n" "$DIRECT_UUID"
    for _c in 1 2 3 4; do
      printf "U_ENTRY_%s='%s'\n" "$_c" "$(var "U_ENTRY_$_c")"
      printf "U_BRIDGE_%s='%s'\n" "$_c" "$(var "U_BRIDGE_$_c")"
    done
  } > "$_ss_tmp"
  chmod 600 "$_ss_tmp"
  mv "$_ss_tmp" "$STATE"
}

ensure_uuids() {
  for _c in 1 2 3 4; do
    [ -n "$(var "U_ENTRY_$_c")" ] || setvar "U_ENTRY_$_c" "$(xray uuid)"
    [ -n "$(var "U_BRIDGE_$_c")" ] || setvar "U_BRIDGE_$_c" "$(xray uuid)"
  done
  [ -n "$DIRECT_UUID" ] || DIRECT_UUID=$(xray uuid)
}

ensure_credentials() {
  ensure_uuids
  [ -n "$SHORT_ID" ] || SHORT_ID=$(gen_short_id)
  if need_reality; then
    if [ -z "$REALITY_PRIVATE_KEY" ] || [ -z "$REALITY_PUBLIC_KEY" ]; then
      gen_reality_keys
    fi
  fi
  if need_enc; then
    if [ -z "$DECRYPTION" ] || [ -z "$ENCRYPTION" ]; then
      gen_vlessenc "${ENC_AUTH:-x25519}"
    fi
    ENC_AUTH=${ENC_AUTH:-$(enc_auth_of)}
  fi
}

# ---------------------------------------------------------------- JSON 片段
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

# 输出一行 client；$1=id $2=email $3=reverse tag（可空）
emit_client_line() {
  if [ "$_cl_n" -gt 0 ]; then
    printf ',\n'
  fi
  _cl_n=$((_cl_n + 1))
  if [ -n "${3-}" ]; then
    printf '          { "id": "%s", "email": "%s", "flow": "xtls-rprx-vision", "reverse": { "tag": "%s" } }' \
      "$1" "$2" "$3"
  else
    printf '          { "id": "%s", "email": "%s", "flow": "xtls-rprx-vision" }' "$1" "$2"
  fi
}

# $1=reality|enc：按协议输出该入站的全部用户
emit_clients_for() {
  _cl_n=0
  for _ec in $CASES; do
    if [ "$(entry_proto_of "$_ec")" = "$1" ]; then
      emit_client_line "$(var "U_ENTRY_$_ec")" "entry-case$_ec" ""
    fi
    if [ "$(bridge_proto_of "$_ec")" = "$1" ]; then
      emit_client_line "$(var "U_BRIDGE_$_ec")" "bridge-case$_ec" "reverse-out-$_ec"
    fi
  done
  if [ "$1" = "reality" ] && [ "$DIRECT_ENABLED" = "1" ]; then
    emit_client_line "$DIRECT_UUID" "direct" ""
  fi
  printf '\n'
}

emit_in_reality() {
  printf '    {\n'
  printf '      // REALITY 入站：方案1/4 入口 + 方案2/4 隧道 + 直连，共用端口 %s\n' "$REALITY_PORT"
  printf '      "tag": "in-reality",\n'
  printf '      "listen": "0.0.0.0",\n'
  printf '      "port": %s,\n' "$REALITY_PORT"
  printf '      "protocol": "vless",\n'
  printf '      "settings": {\n'
  printf '        "decryption": "none",\n'
  printf '        "clients": [\n'
  emit_clients_for reality
  printf '        ]\n'
  printf '      },\n'
  printf '      "streamSettings": {\n'
  reality_stream_block
  printf '      }\n'
  printf '    }\n'
}

emit_in_enc() {
  printf '    {\n'
  printf '      // VLESS Encryption 入站：方案2/3 入口 + 方案1/3 隧道，共用端口 %s\n' "$ENC_PORT"
  printf '      "tag": "in-enc",\n'
  printf '      "listen": "0.0.0.0",\n'
  printf '      "port": %s,\n' "$ENC_PORT"
  printf '      "protocol": "vless",\n'
  printf '      "settings": {\n'
  printf '        "decryption": "%s",\n' "$DECRYPTION"
  printf '        "clients": [\n'
  emit_clients_for enc
  printf '        ]\n'
  printf '      },\n'
  printf '      "streamSettings": {\n'
  enc_stream_block
  printf '      }\n'
  printf '    }\n'
}

emit_rules() {
  _rn=0
  for _rc in $CASES; do
    if [ "$_rn" -gt 0 ]; then
      printf ',\n'
    fi
    _rn=$((_rn + 1))
    printf '      { "inboundTag": ["%s"], "user": ["entry-case%s"], "outboundTag": "reverse-out-%s" }' \
      "$(entry_inbound_of "$_rc")" "$_rc" "$_rc"
  done
  if [ "$DIRECT_ENABLED" = "1" ]; then
    if [ "$_rn" -gt 0 ]; then
      printf ',\n'
    fi
    printf '      { "inboundTag": ["in-reality"], "user": ["direct"], "outboundTag": "direct" }'
  fi
  printf '\n'
}

write_server_config_to() {
  _cfg_out=$1
  _inb=''
  if need_reality; then
    _inb=$(emit_in_reality)
  fi
  if need_enc; then
    if [ -n "$_inb" ]; then
      _inb="$_inb,
"
    fi
    _inb="${_inb}$(emit_in_enc)"
  fi
  _rules=$(emit_rules)

  cat > "$_cfg_out" <<EOF
{
  // 由 xray-reverse-setup.sh 生成；修改后请执行：xray run -test -c $CONF
  "log": { "loglevel": "warning" },
  "inbounds": [
$_inb
  ],
  "outbounds": [
    // 保留明确的默认出站，避免未命中规则的流量误入反向隧道
    { "protocol": "freedom", "tag": "direct" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
$_rules
    ]
  }
}
EOF
}

# ---------------------------------------------------------------- 客户端产物
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
  _bid=$(var "U_BRIDGE_$_c")
  _bp=$(bridge_port_of "$_c")
  _bproto=$(bridge_proto_of "$_c")
  _f="$OUT_DIR/xray-bridge-case${_c}.jsonc"

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
  _eid=$(var "U_ENTRY_$_c")
  _f="$OUT_DIR/xray-entry-case${_c}.jsonc"

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
        "port": ${ENC_PORT},
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

write_all_clients() {
  for _wc in $CASES; do
    write_bridge_client "$_wc"
    if [ "$(entry_proto_of "$_wc")" = "enc" ]; then
      write_entry_enc_client "$_wc"
    fi
  done
  # 清理已取消方案的生成文件
  for _wc in 1 2 3 4; do
    case " $CASES " in
      *" $_wc "*) : ;;
      *) rm -f "$OUT_DIR/xray-bridge-case${_wc}.jsonc" "$OUT_DIR/xray-entry-case${_wc}.jsonc" ;;
    esac
  done
}

print_case_link() {
  _c=$1
  printf '    方案%s: vless://%s@%s:%s?security=reality&flow=xtls-rprx-vision&type=tcp&sni=%s&pbk=%s&sid=%s&fp=chrome#case%s\n' \
    "$_c" "$(var "U_ENTRY_$_c")" "$VPS_HOST" "$REALITY_PORT" "$SNI_HOST" "$REALITY_PUBLIC_KEY" "$SHORT_ID" "$_c"
}

print_direct_link() {
  printf '    直连: vless://%s@%s:%s?security=reality&flow=xtls-rprx-vision&type=tcp&sni=%s&pbk=%s&sid=%s&fp=chrome#vps-direct\n' \
    "$DIRECT_UUID" "$VPS_HOST" "$REALITY_PORT" "$SNI_HOST" "$REALITY_PUBLIC_KEY" "$SHORT_ID"
}

write_credentials() {
  _f="$OUT_DIR/xray-deploy/credentials.txt"
  mkdir -p "${_f%/*}"
  {
    echo "== 服务端信息 =="
    echo "VPS_IP=${VPS_HOST}"
    echo "REALITY target: ${REALITY_TARGET}  SNI: ${SNIS}"
    echo "shortId: ${SHORT_ID}"
    echo "REALITY PublicKey(password): ${REALITY_PUBLIC_KEY}"
    echo "REALITY 端口: ${REALITY_PORT}"
    echo "VLESS Encryption 端口: ${ENC_PORT}  认证: ${ENC_AUTH:-x25519}"
    echo
    for _c in $CASES; do
      echo "== 方案${_c} =="
      echo "  入口 inbound=$(entry_inbound_of "$_c") 协议=$(entry_proto_of "$_c") 端口=$(if [ "$(entry_proto_of "$_c")" = reality ]; then echo "$REALITY_PORT"; else echo "$ENC_PORT"; fi)"
      echo "  入口 UUID=$(var "U_ENTRY_$_c")  email=entry-case${_c}"
      echo "  隧道 协议=$(bridge_proto_of "$_c") 端口=$(bridge_port_of "$_c")"
      echo "  隧道 UUID=$(var "U_BRIDGE_$_c")  email=bridge-case${_c}  reverse-out-${_c}"
      echo "  出口设备配置=${OUT_DIR}/xray-bridge-case${_c}.jsonc"
      if [ "$(entry_proto_of "$_c")" = "enc" ]; then
        echo "  入口设备配置=${OUT_DIR}/xray-entry-case${_c}.jsonc"
      fi
      echo
    done
    if [ "$DIRECT_ENABLED" = "1" ]; then
      echo "== 中转 VPS 直连节点 =="
      echo "  端口=${REALITY_PORT}  UUID=${DIRECT_UUID}"
    fi
  } > "$_f"
  chmod 600 "$_f"
  info "凭据汇总：$_f"
}

# ---------------------------------------------------------------- 端口/服务状态
port_listening() { # 0=在听 1=没在听 2=无法检测
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

listen_mark() {
  if port_listening "$1"; then
    printf '%s监听中%s' "$C_GREEN" "$C_RESET"
  else
    printf '%s未监听%s' "$C_YELLOW" "$C_RESET"
  fi
}

service_active() {
  case "$INIT" in
    openrc)  rc-service xray status >/dev/null 2>&1 ;;
    systemd) systemctl is-active --quiet xray >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

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
    warn "Alpine 默认没有启用防火墙；若有云厂商安全组，请放行：${NEED_PORTS}"
    return 0
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    confirm "检测到 ufw 已启用，放行本次使用的端口？" "Y" || return 0
    for _p in $NEED_PORTS; do
      ufw allow "${_p}/tcp" >/dev/null
    done
    info "ufw 已放行：${NEED_PORTS}"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    confirm "检测到 firewalld 已启用，放行本次使用的端口？" "Y" || return 0
    for _p in $NEED_PORTS; do
      firewall-cmd --permanent --add-port="${_p}/tcp" >/dev/null
    done
    firewall-cmd --reload >/dev/null
    info "firewalld 已放行：${NEED_PORTS}"
  else
    warn "未检测到已启用的 ufw/firewalld；请自行放行：${NEED_PORTS}"
  fi
}

# ---------------------------------------------------------------- 应用配置
state_ports() {
  NEED_PORTS=''
  if need_reality; then
    NEED_PORTS="$NEED_PORTS $REALITY_PORT"
  fi
  if need_enc; then
    NEED_PORTS="$NEED_PORTS $ENC_PORT"
  fi
  NEED_PORTS=$(_trim "$NEED_PORTS")
}

validate_state() {
  _verr=''
  if ! normalize_cases_var; then
    _verr="方案组合无效（只允许 1-4，可组合，如 14）"
  fi
  if need_reality; then
    valid_port "$REALITY_PORT" || _verr="REALITY 端口无效（1-65535，无前导零）"
    valid_short_id "$SHORT_ID" || _verr="shortId 无效（0-f 十六进制、偶数位、≤16 位）"
    [ -n "$SNIS" ] || _verr="SNI 不能为空"
    if [ -z "$REALITY_PRIVATE_KEY" ] || [ -z "$REALITY_PUBLIC_KEY" ]; then
      _verr="缺少 REALITY 密钥"
    fi
  fi
  if need_enc; then
    valid_port "$ENC_PORT" || _verr="VLESS Encryption 端口无效（1-65535，无前导零）"
    if [ -z "$DECRYPTION" ] || [ -z "$ENCRYPTION" ]; then
      _verr="缺少 VLESS Encryption 密钥"
    fi
  fi
  if need_reality && need_enc && [ "$REALITY_PORT" = "$ENC_PORT" ]; then
    _verr="REALITY 与 VLESS Encryption 不能使用同一端口"
  fi
  for _vc in $CASES; do
    valid_uuid "$(var "U_ENTRY_$_vc")" || _verr="方案$_vc 入口 UUID 无效"
    valid_uuid "$(var "U_BRIDGE_$_vc")" || _verr="方案$_vc 出口 UUID 无效"
  done
  if [ "$DIRECT_ENABLED" = "1" ]; then
    valid_uuid "$DIRECT_UUID" || _verr="直连节点 UUID 无效"
  fi
  if [ -n "$_verr" ]; then
    err "$_verr"
    return 1
  fi
  return 0
}

apply_config() {
  if ! validate_state; then
    return 1
  fi

  if ! mkdir -p "${CONF%/*}" 2>/dev/null; then
    err "无法创建 ${CONF%/*}"
    return 1
  fi

  _cfg_tmp="${CONF}.tmp.$$"
  write_server_config_to "$_cfg_tmp" || { rm -f "$_cfg_tmp"; return 1; }

  info "校验配置（xray run -test）..."
  if ! _test_out=$(xray run -test -c "$_cfg_tmp" 2>&1); then
    printf '%s\n' "$_test_out" >&2
    rm -f "$_cfg_tmp"
    err "配置校验失败，现有配置未修改。"
    return 1
  fi

  if [ -f "$CONF" ]; then
    _cfg_bak="${CONF}.bak.$(date +%Y%m%d%H%M%S)"
    if cp -a "$CONF" "$_cfg_bak" 2>/dev/null; then
      info "已备份旧配置：$_cfg_bak"
    else
      warn "旧配置备份失败：$_cfg_bak"
    fi
  fi

  if ! mv "$_cfg_tmp" "$CONF"; then
    rm -f "$_cfg_tmp"
    err "写入 $CONF 失败。"
    return 1
  fi
  secure_config || true
  save_state || warn "状态文件写入失败：$STATE"

  write_all_clients || warn "客户端配置生成失败（检查 $OUT_DIR 权限）。"
  write_credentials || warn "凭据文件写入失败。"

  state_ports
  setup_service
  return 0
}

# ---------------------------------------------------------------- 展示
print_summary() {
  state_ports
  echo
  info "================ 配置概览 ================"
  echo "  VPS 地址      : ${VPS_HOST}"
  echo "  REALITY target: ${REALITY_TARGET}"
  echo "  SNI           : ${SNIS}"
  echo "  shortId       : ${SHORT_ID}"
  if need_reality; then
    echo "  REALITY       : ${VPS_HOST}:${REALITY_PORT}  ($(listen_mark "$REALITY_PORT"))"
  fi
  if need_enc; then
    echo "  VLESS Enc     : ${VPS_HOST}:${ENC_PORT}  ($(listen_mark "$ENC_PORT"))  认证 ${ENC_AUTH:-x25519}"
  fi
  echo "  方案          : ${CASES}"
  if [ "$DIRECT_ENABLED" = "1" ]; then
    echo "  直连节点      : REALITY/${VPS_HOST}:${REALITY_PORT}"
  fi

  echo
  echo "  == 客户端（入口设备）=="
  for _sc in $CASES; do
    if [ "$(entry_proto_of "$_sc")" = "reality" ]; then
      print_case_link "$_sc"
    else
      printf '    方案%s: 使用 %s/xray-entry-case%s.jsonc（VLESS Encryption）\n' \
        "$_sc" "$OUT_DIR" "$_sc"
    fi
  done
  if [ "$DIRECT_ENABLED" = "1" ]; then
    print_direct_link
  fi

  echo
  echo "  == 出口设备 =="
  for _sc in $CASES; do
    printf '    方案%s: %s/xray-bridge-case%s.jsonc（隧道 %s/%s）\n' \
      "$_sc" "$OUT_DIR" "$_sc" "$(bridge_proto_of "$_sc")" "$(bridge_port_of "$_sc")"
  done

  echo
  echo "  == 服务 =="
  if service_active; then
    echo "    Xray 服务运行中"
  else
    echo "    Xray 服务未运行（查看服务日志）"
  fi
  echo "    凭据文件: ${OUT_DIR}/xray-deploy/credentials.txt"
  echo "    管理面板: 输入 lray"
  echo
  if [ -n "$NEED_PORTS" ]; then
    info "需放行的 TCP 端口：${NEED_PORTS}"
  fi
}

# ---------------------------------------------------------------- 安装
run_install() {
  install_xray

  echo
  info "==== 开始部署 ===="
  init_state_defaults

  _detected_ip=$(detect_public_ip)
  VPS_HOST=$(ask "VPS 公网 IP 或域名" "${_detected_ip:-}")
  [ -n "$VPS_HOST" ] || die "VPS 地址不能为空。"

  REALITY_TARGET=$(ask "REALITY 伪装目标 target（格式 域名:端口）" "itunes.apple.com:443")
  case "$REALITY_TARGET" in
    *:*) : ;;
    *)   REALITY_TARGET="${REALITY_TARGET}:443" ;;
  esac
  SNI_HOST=${REALITY_TARGET%%:*}
  SNIS=$(ask "SNI 列表（逗号分隔）" "$SNI_HOST")
  [ -n "$SNIS" ] || die "SNI 不能为空。"

  echo
  info "请选择要部署的方案（可多选，如 1、4、12、1,3、1234）："
  echo "  1) 出口在国外 / 入口在国内（入口 REALITY，隧道 VLESS Encryption）"
  echo "  2) 入口在国外 / 出口在国内（入口 VLESS Encryption，隧道 REALITY）"
  echo "  3) 出入口都在国外（两端 VLESS Encryption）"
  echo "  4) 出入口都在国内（两端 VLESS+REALITY）"
  _case_choice=$(normalize_cases "$(ask "方案组合" "4")")
  valid_cases "$_case_choice" || die "无效方案组合：$_case_choice（只允许 1-4）"

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

  echo
  if confirm "是否额外添加一个“出口为本中转 VPS”的 VLESS+REALITY 直连节点？" "Y"; then
    DIRECT_ENABLED=1
  else
    DIRECT_ENABLED=0
  fi

  if need_reality; then
    while :; do
      REALITY_PORT=$(ask "REALITY 端口" "$DEFAULT_REALITY_PORT")
      valid_port "$REALITY_PORT" && break
      warn "端口无效（1-65535，且不要前导零）。"
    done
  fi
  if need_enc; then
    while :; do
      ENC_PORT=$(ask "VLESS Encryption 端口" "$DEFAULT_ENC_PORT")
      valid_port "$ENC_PORT" || { warn "端口无效。"; continue; }
      if need_reality && [ "$ENC_PORT" = "$REALITY_PORT" ]; then
        warn "不能与 REALITY 端口相同。"
        continue
      fi
      break
    done
  fi

  SHORT_ID=$(gen_short_id)
  info "已随机生成 shortId：$SHORT_ID"

  if need_enc; then
    echo
    info "VLESS Encryption 认证方式（服务端与客户端必须一致）："
    echo "  1) X25519（默认，较短）"
    echo "  2) ML-KEM-768（后量子，较长）"
    _ve_choice=$(ask "选择 [1/2]" "1")
    case "$_ve_choice" in
      1) ENC_AUTH=x25519 ;;
      2) ENC_AUTH=mlkem ;;
      *) die "无效选择：$_ve_choice（应为 1 或 2）" ;;
    esac
  else
    ENC_AUTH=x25519
  fi

  info "生成随机凭证（UUID / REALITY 密钥 / Encryption 密钥）..."
  ensure_credentials

  if ! apply_config; then
    die "部署失败，请根据上面的提示处理后重试。"
  fi

  setup_firewall
  print_summary
}

# ---------------------------------------------------------------- 管理面板
panel_edit_target() {
  _old_sni=$SNI_HOST
  _t=$(ask "REALITY target（域名:端口）" "$REALITY_TARGET")
  case "$_t" in
    *:*) : ;;
    *)   _t="${_t}:443" ;;
  esac
  REALITY_TARGET=$_t
  SNI_HOST=${REALITY_TARGET%%:*}
  if [ "$SNIS" = "$_old_sni" ]; then
    SNIS=$SNI_HOST
  fi
  _s=$(ask "SNI 列表（逗号分隔）" "$SNIS")
  [ -n "$_s" ] || _s=$SNI_HOST
  SNIS=$_s
  DIRTY=1
  info "已更新 target/SNI（记得应用）"
}

panel_edit_shortid() {
  _sid=$(ask "shortId（直接回车 = 重新随机生成）" "")
  if [ -z "$_sid" ]; then
    _sid=$(gen_short_id)
  fi
  if valid_short_id "$_sid"; then
    SHORT_ID=$_sid
    DIRTY=1
    info "shortId 已更新：$SHORT_ID（记得应用）"
  else
    err "shortId 无效：0-f 十六进制、偶数位、不超过 16 位"
  fi
}

panel_edit_ports() {
  if need_reality; then
    while :; do
      _p=$(ask "REALITY 端口" "$REALITY_PORT")
      valid_port "$_p" && break
      warn "端口无效。"
    done
    REALITY_PORT=$_p
  fi
  if need_enc; then
    while :; do
      _p=$(ask "VLESS Encryption 端口" "$ENC_PORT")
      valid_port "$_p" || { warn "端口无效。"; continue; }
      if need_reality && [ "$_p" = "$REALITY_PORT" ]; then
        warn "不能与 REALITY 端口相同。"
        continue
      fi
      break
    done
    ENC_PORT=$_p
  fi
  DIRTY=1
  info "端口已更新（记得应用）"
}

panel_edit_uuid() {
  echo
  echo "  == 当前 UUID =="
  _ci=1
  for _c in 1 2 3 4; do
    printf '  %s) 方案%s 入口  %s\n' "$_ci" "$_c" "$(var "U_ENTRY_$_c")"
    _ci=$((_ci + 1))
  done
  for _c in 1 2 3 4; do
    printf '  %s) 方案%s 出口  %s\n' "$_ci" "$_c" "$(var "U_BRIDGE_$_c")"
    _ci=$((_ci + 1))
  done
  printf '  9) 直连节点  %s\n' "${DIRECT_UUID:-（未生成）}"
  printf '  0) 返回\n'

  _n=$(ask "选择要修改的项" "0")
  case "$_n" in
    1|2|3|4)
      _var="U_ENTRY_$_n"; _label="方案${_n} 入口" ;;
    5|6|7|8)
      _idx=$((_n - 4)); _var="U_BRIDGE_$_idx"; _label="方案${_idx} 出口" ;;
    9)
      _var="DIRECT_UUID"; _label="直连节点" ;;
    0)
      return 0 ;;
    *)
      warn "无效选择。"; return 0 ;;
  esac

  _v=$(ask "$_label 新 UUID（直接回车 = 重新生成）" "")
  if [ -z "$_v" ]; then
    _v=$(xray uuid)
  fi
  if valid_uuid "$_v"; then
    setvar "$_var" "$_v"
    DIRTY=1
    info "$_label UUID 已更新：$_v（记得应用）"
  else
    err "UUID 无效（标准 8-4-4-4-12 格式）"
  fi
}

panel_regen_reality() {
  confirm "重新生成 REALITY 密钥对？所有 REALITY 客户端都要换新配置。" "N" || return 0
  gen_reality_keys
  DIRTY=1
  info "新公钥：$REALITY_PUBLIC_KEY（记得应用并更新客户端）"
}

panel_edit_enc() {
  echo
  echo "  当前认证：${ENC_AUTH:-x25519}"
  echo "  decryption: $(printf '%s' "$DECRYPTION" | cut -c1-40)..." 
  echo "  1) 重新生成 X25519 对"
  echo "  2) 重新生成 ML-KEM-768 对"
  echo "  3) 手动粘贴 decryption / encryption"
  echo "  0) 返回"
  _n=$(ask "选择" "0")
  case "$_n" in
    1) gen_vlessenc x25519; DIRTY=1; info "已重新生成 X25519 对（记得应用）" ;;
    2) gen_vlessenc mlkem;  DIRTY=1; info "已重新生成 ML-KEM-768 对（记得应用）" ;;
    3)
      _d=$(ask "decryption（服务端）" "")
      _e=$(ask "encryption（客户端）" "")
      if [ -z "$_d" ] || [ -z "$_e" ]; then
        err "两个值都不能为空。"
        return 0
      fi
      _pd=$(printf '%s' "$_d" | cut -d. -f1-2)
      _pe=$(printf '%s' "$_e" | cut -d. -f1-2)
      if [ "$_pd" != "$_pe" ]; then
        err "两段密钥的算法前缀不一致（$_pd vs $_pe），请确认是同一对。"
        return 0
      fi
      DECRYPTION=$_d
      ENCRYPTION=$_e
      ENC_AUTH=$(enc_auth_of)
      DIRTY=1
      info "密钥已更新，认证=${ENC_AUTH}（记得应用）"
      ;;
    0) : ;;
    *) warn "无效选择。" ;;
  esac
}

panel_edit_cases() {
  echo
  echo "  1) 出口在国外 / 入口在国内（入口 REALITY，隧道 Encryption）"
  echo "  2) 入口在国外 / 出口在国内（入口 Encryption，隧道 REALITY）"
  echo "  3) 出入口都在国外（两端 Encryption）"
  echo "  4) 出入口都在国内（两端 REALITY）"
  _cc=$(normalize_cases "$(ask "方案组合（直接回车保持不变）" "$CASES")")
  if [ -z "$_cc" ]; then
    return 0
  fi
  if ! valid_cases "$_cc"; then
    err "无效方案组合。"
    return 0
  fi
  _new=''
  _seen=''
  _rest=$_cc
  while [ -n "$_rest" ]; do
    _ch=${_rest%"${_rest#?}"}
    _rest=${_rest#?}
    case " $_seen " in
      *" $_ch "*) continue ;;
    esac
    _seen="${_seen} ${_ch}"
    _new="${_new:+$_new }${_ch}"
  done
  CASES=$_new
  DIRTY=1
  info "方案已更新为：$CASES（记得应用）"
}

panel_toggle_direct() {
  if [ "$DIRECT_ENABLED" = "1" ]; then
    DIRECT_ENABLED=0
    info "已关闭直连节点（记得应用）"
  else
    DIRECT_ENABLED=1
    [ -n "$DIRECT_UUID" ] || DIRECT_UUID=$(xray uuid)
    info "已开启直连节点（记得应用）"
  fi
  DIRTY=1
}

panel_status() {
  echo
  info "服务状态："
  case "$INIT" in
    openrc)  rc-service xray status 2>&1 | tail -3 ;;
    systemd) systemctl status xray --no-pager 2>&1 | head -8 ;;
    *)       echo "  未检测到 systemd/OpenRC" ;;
  esac
  echo
  state_ports
  for _p in $NEED_PORTS; do
    printf '  端口 %-5s : %s\n' "$_p" "$(listen_mark "$_p")"
  done
  echo
  if xray run -test -c "$CONF" >/dev/null 2>&1; then
    echo "  配置文件校验：OK（$CONF）"
  else
    echo "  配置文件校验：失败"
  fi
  [ -f "$STATE" ] && echo "  状态文件：$STATE"
}

panel_apply() {
  echo
  info "生成缺失凭证并应用配置..."
  ensure_credentials
  if apply_config; then
    DIRTY=0
    setup_firewall
    print_summary
    return 0
  fi
  err "应用失败，未修改现有配置；可继续在面板中调整。"
  return 1
}

panel_render() {
  echo
  info "================ Xray 管理面板 ================"
  if service_active; then
    echo "  服务: 运行中"
  else
    echo "  服务: 未运行"
  fi
  if need_reality; then
    printf '  REALITY 端口 : %-5s %s\n' "$REALITY_PORT" "$(listen_mark "$REALITY_PORT")"
  fi
  if need_enc; then
    printf '  Enc 端口     : %-5s %s\n' "$ENC_PORT" "$(listen_mark "$ENC_PORT")"
  fi
  printf '  方案         : %s   直连: %s\n' "${CASES:-无}" "$([ "$DIRECT_ENABLED" = 1 ] && echo 开 || echo 关)"
  printf '  target       : %s   SNI: %s\n' "$REALITY_TARGET" "$SNIS"
  printf '  shortId      : %s   Enc认证: %s\n' "$SHORT_ID" "${ENC_AUTH:-x25519}"
  if [ "$DIRTY" = "1" ]; then
    warn "有未应用的修改（选 10 应用）"
  fi
  echo
  echo "   1) 查看凭据 / 分享链接 / 客户端文件"
  echo "   2) 修改 REALITY target / SNI"
  echo "   3) 修改 shortId"
  echo "   4) 修改端口（REALITY / Encryption）"
  echo "   5) 修改 UUID（按方案入口/出口/直连）"
  echo "   6) 重新生成 REALITY 密钥对"
  echo "   7) 修改 / 重新生成 VLESS Encryption 密钥"
  echo "   8) 修改方案组合"
  echo "   9) 开关直连节点"
  echo "  10) 应用配置（写入 + 校验 + 重启 + 重建客户端）"
  echo "  11) 查看服务/端口/配置校验状态"
  echo "   0) 退出"
}

panel_main() {
  if ! load_state; then
    warn "未找到有效的部署状态（$STATE）。"
    if confirm "现在进入安装流程？" "Y"; then
      run_install
    fi
    return 0
  fi

  DIRTY=0
  while :; do
    panel_render
    _pc=$(ask "选择操作" "0")
    case "$_pc" in
      1)  print_summary ;;
      2)  panel_edit_target ;;
      3)  panel_edit_shortid ;;
      4)  panel_edit_ports ;;
      5)  panel_edit_uuid ;;
      6)  panel_regen_reality ;;
      7)  panel_edit_enc ;;
      8)  panel_edit_cases ;;
      9)  panel_toggle_direct ;;
      10) panel_apply ;;
      11) panel_status ;;
      0)
        if [ "$DIRTY" = "1" ]; then
          confirm "有未应用的修改，确定退出？" "N" && return 0
        else
          return 0
        fi
        ;;
      *) warn "无效选择：$_pc" ;;
    esac
  done
}

# ---------------------------------------------------------------- 参数与入口
usage() {
  cat <<'EOF'
Xray VLESS 反向代理（多场景一对一落地）中转 VPS 部署 / 管理脚本

用法：
  # 一条命令安装（root，交互输入照常）
  sh -c "$(wget -qO- https://github.com/loser641/xray-reverse-setup/raw/main/xray-reverse-setup.sh)"
  lray                                已安装时打开管理面板
  ./xray-reverse-setup.sh             已部署则打开面板，否则安装
  ./xray-reverse-setup.sh --panel     打开管理面板
  ./xray-reverse-setup.sh --install   重新安装/部署
  ./xray-reverse-setup.sh --defaults  安装时全部取默认值（无人值守）
  ./xray-reverse-setup.sh --help      显示本帮助

端口默认值：
  REALITY 入站        40443（方案1/4 入口 + 方案2/4 隧道 + 直连）
  VLESS Encryption    50443（方案2/3 入口 + 方案1/3 隧道）

同一协议的方案共用一个入站/端口，通过不同 UUID（用户）区分，
路由按用户邮箱 entry-caseN -> reverse-out-N。

环境变量：
  NO_COLOR=1              关闭彩色输出
  XRAY_SETUP_NO_TTY=1     不读取 /dev/tty，仅从 stdin 取输入（CI 用）
  XRAY_SETUP_OUT_DIR=DIR  客户端配置/凭据输出目录（默认 /root）
EOF
}

parse_args() {
  ASSUME_DEFAULTS=0
  MODE=auto
  for _arg in "$@"; do
    case "$_arg" in
      -y|--yes|--defaults) ASSUME_DEFAULTS=1; MODE=install ;;
      --install) MODE=install ;;
      --panel)   MODE=panel ;;
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

  OUT_DIR=${XRAY_SETUP_OUT_DIR:-/root}
  mkdir -p /usr/local/etc/xray /usr/local/share/xray "$OUT_DIR/xray-deploy"
  chmod 700 "$OUT_DIR/xray-deploy"

  WD=$(mktemp -d "${TMPDIR:-/tmp}/xray-setup.XXXXXX") || {
    WD="/tmp/xray-setup.$$"
    mkdir -p "$WD"
  }
  trap 'rm -rf "$WD"' EXIT INT TERM

  install_lray

  case "$MODE" in
    install) run_install ;;
    panel)   panel_main ;;
    auto)
      if state_ready; then
        panel_main
      else
        run_install
      fi
      ;;
  esac
}

main "$@"
