#!/usr/bin/env bash
# ============================================================
# Left 4 Dead 2 专用服务器 —— 阿里云 ECS 一键部署
# 支持: Ubuntu 20.04/22.04/24.04 · Debian 11/12
#       Alibaba Cloud Linux 3 · CentOS 8+ (dnf/yum)
# 用法(在 ECS 上以 root 执行):
#   bash deploy.sh
#   SERVER_NAME="老王服" MAXPLAYERS=12 bash deploy.sh
#   WORKSHOP_COLLECTION=123456789 bash deploy.sh     # 隐藏血条等 Mod
# ============================================================
set -euo pipefail
# 任何未捕获失败都打印行号与命令，避免"静默退出"
trap 'printf "\033[1;31m[x]\033[0m 失败: 第 %s 行 -> %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ---------------- 可调参数（环境变量可覆盖） ----------------
INSTALL_DIR="${INSTALL_DIR:-/opt/l4d2}"
STEAMCMD_DIR="${STEAMCMD_DIR:-/opt/steamcmd}"
STEAM_USER="${STEAM_USER:-steam}"
SERVICE_NAME="${SERVICE_NAME:-l4d2ds}"
SRCDS_PORT="${SRCDS_PORT:-27015}"
MAXPLAYERS="${MAXPLAYERS:-8}"
START_MAP="${START_MAP:-c1m1_hotel}"
DIFFICULTY="${DIFFICULTY:-Normal}"          # Easy|Normal|Hard|Impossible
SERVER_NAME="${SERVER_NAME:-L4D2 Server}"
SV_PASSWORD="${SV_PASSWORD:-}"               # 进服密码，留空=无
RCON_PASSWORD="${RCON_PASSWORD:-}"           # 留空=自动生成
WORKSHOP_COLLECTION="${WORKSHOP_COLLECTION:-}"  # 创意工坊收藏夹 ID
APP_ID=222860

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 执行：sudo bash deploy.sh"
[ -f /etc/os-release ] || die "无法识别系统发行版"
# shellcheck disable=SC1091
. /etc/os-release
log "系统: ${PRETTY_NAME:-unknown}"
if [ -z "$RCON_PASSWORD" ]; then
  # 用 dd|od|tr|cut 组合：不产生 SIGPIPE，pipefail 下安全
  RCON_PASSWORD="$(dd if=/dev/urandom bs=24 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n' | cut -c1-12)"
  [ -n "$RCON_PASSWORD" ] || RCON_PASSWORD="l4d2$(date +%s)"
fi

# ---------------- 1. 依赖 ----------------
install_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    log "apt 安装依赖（含 i386 运行库，srcds/steamcmd 需要）"
    dpkg --add-architecture i386 >/dev/null 2>&1 || true
    apt-get update -y -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      ca-certificates curl tar xz-utils procps lib32gcc-s1 lib32stdc++6
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      lib32tinfo6 lib32ncurses6 lib32z1 libcurl4-gnutls-dev:i386 \
      || warn "部分 32 位可选库装不上，启动若报缺库见 README 排障"
  elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    PM="$(command -v dnf || command -v yum)"
    log "用 $PM 安装依赖"
    "$PM" install -y ca-certificates curl tar xz glibc.i686 libstdc++.i686 \
      ncurses-libs.i686 zlib.i686 libcurl.i686 procps-ng \
      || warn "部分 32 位库装不上，启动若报缺库见 README 排障"
  else
    die "不支持的包管理器（请用 Ubuntu/Debian 或 Alibaba Cloud Linux）"
  fi
}

# ---------------- 2. 运行用户 ----------------
setup_user() {
  if ! id -u "$STEAM_USER" >/dev/null 2>&1; then
    log "创建运行用户 $STEAM_USER（禁止登录）"
    useradd -r -m -d "/home/$STEAM_USER" -s /usr/sbin/nologin "$STEAM_USER" 2>/dev/null \
      || useradd -r -m -d "/home/$STEAM_USER" -s /bin/false "$STEAM_USER"
  else
    log "运行用户 $STEAM_USER 已存在"
  fi
}

as_steam() {
  if command -v runuser >/dev/null 2>&1; then
    runuser -u "$STEAM_USER" -- "$@"
  else
    su -s /bin/bash "$STEAM_USER" -c "$(printf '%q ' "$@")"
  fi
}

# ---------------- 3. SteamCMD ----------------
install_steamcmd() {
  if [ -x "$STEAMCMD_DIR/steamcmd.sh" ]; then
    log "SteamCMD 已存在，跳过下载"
  else
    log "下载 SteamCMD"
    mkdir -p "$STEAMCMD_DIR"
    curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
      -o /tmp/steamcmd_linux.tar.gz
    tar -xzf /tmp/steamcmd_linux.tar.gz -C "$STEAMCMD_DIR"
    rm -f /tmp/steamcmd_linux.tar.gz
  fi
  chown -R "$STEAM_USER:$STEAM_USER" "$STEAMCMD_DIR"
}

# ---------------- 4. 安装 / 更新 L4D2 服务端 ----------------
install_l4d2() {
  mkdir -p "$INSTALL_DIR/left4dead2/cfg" "$INSTALL_DIR/left4dead2/addons"
  chown -R "$STEAM_USER:$STEAM_USER" "$INSTALL_DIR"
  log "SteamCMD 拉取 L4D2 专用服务器 app $APP_ID（约 12 GB，5-20 分钟，别中断）"
  as_steam "$STEAMCMD_DIR/steamcmd.sh" \
    +force_install_dir "$INSTALL_DIR" \
    +login anonymous \
    +app_update "$APP_ID" validate \
    +quit
  [ -x "$INSTALL_DIR/srcds_run" ] || die "srcds_run 未生成 —— 安装失败，看上面 SteamCMD 的报错"
  log "服务端本体就绪: $INSTALL_DIR"
}

# ---------------- 5. 写入配置 ----------------
write_configs() {
  log "写入 server.cfg / start.sh / systemd 单元"
  cat > "$INSTALL_DIR/left4dead2/cfg/server.cfg" <<CFG
// ================= L4D2 专用服务器配置 =================
// 本文件由 deploy.sh 生成。改完执行: systemctl restart $SERVICE_NAME
hostname "$SERVER_NAME"
sv_password "$SV_PASSWORD"
rcon_password "$RCON_PASSWORD"

// ---------- 网络 / 基础 ----------
sv_lan 0
sv_region 4
sv_steamgroup_exclusive 0
sv_allow_lobby_connect_only 0
sv_consistency 0
sv_pure 0
sv_cheats 0
sv_maxupdaterate 60
sv_minupdaterate 30
sv_minrate 30000
sv_maxrate 0
sv_timeout 60

// ---------- 关闭队友伤害（cvar + 难度因子两层都关） ----------
mp_friendlyfire 0
survivor_friendly_fire_factor_easy 0
survivor_friendly_fire_factor_normal 0
survivor_friendly_fire_factor_hard 0
survivor_friendly_fire_factor_expert 0

// ---------- 玩法 ----------
mp_gamemode "coop"
z_difficulty "$DIFFICULTY"
director_no_death_check 1

// ---------- 隐藏血条 / HUD ----------
// L4D2 服务端没有"隐藏血条"原生 cvar，只能下发 HUD 类 Mod。
// host_workshop_collection 会让进服玩家自动订阅整个收藏夹。
CFG

  if [ -n "$WORKSHOP_COLLECTION" ]; then
    echo "host_workshop_collection \"$WORKSHOP_COLLECTION\"" \
      >> "$INSTALL_DIR/left4dead2/cfg/server.cfg"
  else
    cat >> "$INSTALL_DIR/left4dead2/cfg/server.cfg" <<'CFG'
// 未配置收藏夹。做法:
//   1. Steam 创意工坊找"隐藏 HUD / 关闭血条显示"类 Mod；
//   2. 建收藏夹把 Mod 收进去，复制收藏页 URL 中的 id；
//   3. 重跑: WORKSHOP_COLLECTION=<id> bash deploy.sh
// host_workshop_collection "收藏夹ID"
CFG
  fi

  cat > "$INSTALL_DIR/start.sh" <<START
#!/usr/bin/env bash
cd "$INSTALL_DIR" || exit 1
exec ./srcds_run -game left4dead2 -console -norestart \\
  -ip 0.0.0.0 -port $SRCDS_PORT \\
  +maxplayers $MAXPLAYERS +map $START_MAP \\
  +exec server.cfg +sv_lan 0
START
  chmod +x "$INSTALL_DIR/start.sh"

  cat > "/etc/systemd/system/$SERVICE_NAME.service" <<UNIT
[Unit]
Description=Left 4 Dead 2 Dedicated Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$STEAM_USER
Group=$STEAM_USER
WorkingDirectory=$INSTALL_DIR
Environment=LD_LIBRARY_PATH=$INSTALL_DIR/bin:$INSTALL_DIR
ExecStart=$INSTALL_DIR/start.sh
Restart=on-failure
RestartSec=15
LimitNOFILE=65535
KillSignal=SIGINT
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
UNIT
  chown -R "$STEAM_USER:$STEAM_USER" "$INSTALL_DIR"
}

# ---------------- 6. 本机防火墙 ----------------
open_ports() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep "Status: active" >/dev/null; then
    log "ufw 放行 $SRCDS_PORT tcp/udp"
    ufw allow "$SRCDS_PORT"/tcp  >/dev/null
    ufw allow "$SRCDS_PORT"/udp  >/dev/null
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    log "firewalld 放行 $SRCDS_PORT tcp/udp"
    firewall-cmd --permanent --add-port="$SRCDS_PORT"/tcp --add-port="$SRCDS_PORT"/udp >/dev/null
    firewall-cmd --reload >/dev/null
  else
    warn "本机未启用防火墙；阿里云还需在【安全组】放行 $SRCDS_PORT TCP+UDP"
  fi
}

# ---------------- 主流程 ----------------
main() {
  install_deps
  setup_user
  install_steamcmd
  install_l4d2
  write_configs
  open_ports

  log "注册并启动 systemd 服务 $SERVICE_NAME"
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE_NAME"
  sleep 10

  if systemctl is-active --quiet "$SERVICE_NAME"; then
    log "服务运行中"
  else
    warn "服务没起来，执行看日志: journalctl -u $SERVICE_NAME -n 60 --no-pager"
  fi

  PUBIP="$(curl -fsS --max-time 6 https://api.ipify.org 2>/dev/null \
        || curl -fsS --max-time 6 https://ifconfig.me 2>/dev/null \
        || echo '<本机公网IP>')"

  cat <<EOF

================================================================
 L4D2 专用服务器已部署完成
----------------------------------------------------------------
 直连地址   : connect $PUBIP:$SRCDS_PORT
 服务器名   : $SERVER_NAME
 进服密码   : ${SV_PASSWORD:-（无）}
 RCON 密码  : $RCON_PASSWORD
 安装目录   : $INSTALL_DIR
 配置文件   : $INSTALL_DIR/left4dead2/cfg/server.cfg
 收藏夹 ID  : ${WORKSHOP_COLLECTION:-（未配置，隐藏血条 Mod 未启用）}
----------------------------------------------------------------
 常用命令
   启停   : systemctl start|stop|restart $SERVICE_NAME
   状态   : systemctl status $SERVICE_NAME
   日志   : journalctl -u $SERVICE_NAME -f
   看配置 : cat $INSTALL_DIR/left4dead2/cfg/server.cfg
----------------------------------------------------------------
 记得在阿里云安全组放行 $SRCDS_PORT TCP+UDP
 玩完想彻底不花钱：systemctl stop 之后【释放实例】，不是关机
================================================================
EOF
}

main "$@"
