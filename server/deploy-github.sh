#!/usr/bin/env bash
# ============================================================================
# Left 4 Dead 2 一键部署（单文件版 · 走 GitHub raw · 不落任何本地配置文件）
#
# 用法（在全新的 ECS 上，root 执行）：
#   curl -fsSL https://raw.githubusercontent.com/yanshui233/left4dead2-serve/main/server/deploy-github.sh \
#     | bash -s -- --password '你的RCON密码'
#
# 常用参数：
#   --password <str>             RCON 密码（不填则随机生成）
#   --port <int>                 游戏端口，默认 27015
#   --server-name <str>          服务器名，默认 L4D2-Asia-Server
#   --maxplayers <int>           最大人数，默认 8
#   --tick <30|60|100|128>       tickrate，默认 100
#   --vac <true|false>           是否开启 VAC（false 会加 -insecure，服务器不进列表），默认 true
#   --workshop-collection <id>   创意工坊收藏夹 ID（隐藏血条等 Mod），默认空
#   --addon-url <url[,url]>      额外 addons 直链（.vpk），下载到 addons/
#   --mirror <url>               Docker 镜像加速器（如阿里云 https://xxxx.mirror.aliyuncs.com）
#   --puller <host>              额外镜像站前缀，如 docker.1panel.live
#   --skip-if-running            已经在跑就直接退出（默认行为）
#
# 特性：幂等（可反复执行）、镜像已存在则跳过 12GB 下载、失败自动重试拉取
# ============================================================================
set -euo pipefail
trap 'printf "\033[1;31m[x]\033[0m 失败于第 %s 行: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

IMAGE="laoyutang/l4d2-pure:latest"
PORT=27015
RCON_PASSWORD=""
SERVER_NAME="L4D2-Asia-Server"
MAXPLAYERS=8
TICK=100
VAC=true
WORKSHOP=""
ADDON_URLS=""
MIRROR=""
PULLER=""
INSTALL_DIR="/opt/l4d2"
CONTAINER="l4d2"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '3,30p' "$0" 2>/dev/null || echo "见脚本头部注释"; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --password)            RCON_PASSWORD="${2:-}"; shift 2 ;;
    --port)                PORT="${2:-}"; shift 2 ;;
    --server-name)         SERVER_NAME="${2:-}"; shift 2 ;;
    --maxplayers)          MAXPLAYERS="${2:-}"; shift 2 ;;
    --tick)                TICK="${2:-}"; shift 2 ;;
    --vac)                 VAC="${2:-}"; shift 2 ;;
    --workshop-collection) WORKSHOP="${2:-}"; shift 2 ;;
    --addon-url)           ADDON_URLS="${2:-}"; shift 2 ;;
    --mirror)              MIRROR="${2:-}"; shift 2 ;;
    --puller)              PULLER="${2:-}"; shift 2 ;;
    -h|--help)             usage ;;
    *) die "未知参数: $1（--help 查看用法）" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "请用 root 执行（sudo -i 后再跑）"
[ -f /etc/os-release ] || die "无法识别系统"
. /etc/os-release
log "系统: ${PRETTY_NAME:-unknown}"

if [ -z "$RCON_PASSWORD" ]; then
  RCON_PASSWORD="$(dd if=/dev/urandom bs=24 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n' | cut -c1-12)"
fi

PUBIP="$(curl -fsS --max-time 6 https://api.ipify.org 2>/dev/null \
      || curl -fsS --max-time 6 https://ifconfig.me 2>/dev/null \
      || echo '<本机公网IP>')"

# ---------------------------------------------------------------- 1. Docker
install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker 已安装: $(docker --version | cut -d, -f1)"
  else
    log "安装 Docker"
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io docker-compose-v2 \
        || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
      PM="$(command -v dnf || command -v yum)"
      "$PM" install -y docker docker-compose-plugin || "$PM" install -y docker
    else
      die "不支持的包管理器（需要 apt / dnf / yum）"
    fi
    systemctl enable --now docker >/dev/null 2>&1 || true
  fi
  systemctl is-active --quiet docker || systemctl start docker
  log "Docker 就绪"
}

compose_up() {
  if docker compose version >/dev/null 2>&1; then
    ( cd "$INSTALL_DIR" && docker compose up -d )
  elif command -v docker-compose >/dev/null 2>&1; then
    ( cd "$INSTALL_DIR" && docker-compose up -d )
  else
    die "缺少 docker compose 插件"
  fi
}

# ---------------------------------------------------------------- 2. 镜像加速
config_mirror() {
  local mirrors=""
  if [ -n "$MIRROR" ]; then mirrors="\"$MIRROR\""; fi
  if [ -n "$PULLER" ]; then
    if [ -n "$mirrors" ]; then mirrors="$mirrors, \"https://$PULLER\""
    else mirrors="\"https://$PULLER\""; fi
  fi
  [ -n "$mirrors" ] || mirrors="\"https://docker.1panel.live\""

  log "配置 Docker 镜像加速: $mirrors"
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<JSON
{
  "registry-mirrors": [$mirrors],
  "max-concurrent-downloads": 16,
  "max-concurrent-uploads": 4
}
JSON
  systemctl restart docker
  sleep 3
  systemctl is-active --quiet docker || die "docker 重启失败"
  log "镜像加速已生效"
}

# ---------------------------------------------------------------- 3. compose
write_compose() {
  mkdir -p "$INSTALL_DIR/cfg" "$INSTALL_DIR/addons"
  log "写入 $INSTALL_DIR/docker-compose.yml"
  cat > "$INSTALL_DIR/docker-compose.yml" <<YAML
services:
  $CONTAINER:
    image: $IMAGE
    container_name: $CONTAINER
    restart: unless-stopped
    ports:
      - "$PORT:$PORT"
      - "$PORT:$PORT/udp"
    volumes:
      - $INSTALL_DIR/cfg:/l4d2/left4dead2/cfg
      - $INSTALL_DIR/addons:/l4d2/left4dead2/addons
      - $INSTALL_DIR/start.sh:/start.sh:ro
    environment:
      - L4D2_TICK=$TICK
      - L4D2_VAC=$VAC
      - L4D2_PORT=$PORT
      - L4D2_MAXPLAYERS=$MAXPLAYERS
      - L4D2_RCON_PASSWORD=$RCON_PASSWORD
    security_opt:
      - seccomp:unconfined
    ulimits:
      nofile:
        soft: 65535
        hard: 65535
    logging:
      options:
        max-size: "50m"
        max-file: "3"
YAML

  # 自带 start.sh（保持镜像原逻辑，另加 +maxplayers，并保证 tick 模板与 rcon 注入）
  log "写入 $INSTALL_DIR/start.sh"
  cat > "$INSTALL_DIR/start.sh" <<'START'
#!/bin/bash
set -e
CFG=/l4d2/left4dead2/cfg
TICK="${L4D2_TICK:-30}"
case "$TICK" in
  30|60|100|128) ;;
  *) TICK=30 ;;
esac
if [ -f "$CFG/server.cfg.${TICK}tick" ]; then
  cp "$CFG/server.cfg.${TICK}tick" "$CFG/server.cfg"
elif [ -f "$CFG/server.cfg.30tick" ]; then
  TICK=30
  cp "$CFG/server.cfg.30tick" "$CFG/server.cfg"
fi
if [ -n "${L4D2_RCON_PASSWORD:-}" ] && [ -f "$CFG/server.cfg" ]; then
  if grep -q '^rcon_password' "$CFG/server.cfg"; then
    sed -i "s|^rcon_password .*|rcon_password \"${L4D2_RCON_PASSWORD}\"|" "$CFG/server.cfg"
  else
    printf 'rcon_password "%s"\n' "$L4D2_RCON_PASSWORD" >> "$CFG/server.cfg"
  fi
fi
SEC=""
[ "${L4D2_VAC:-false}" = "true" ] || SEC="-insecure"
cd /l4d2
exec ./srcds_run -game left4dead2 ${SEC} -tickrate "$TICK" -condebug \
  +hostport "${L4D2_PORT:-27015}" \
  +maxplayers "${L4D2_MAXPLAYERS:-8}" \
  +exec server.cfg
START
  chmod +x "$INSTALL_DIR/start.sh"
}

# ---------------------------------------------------------------- 4. cfg 补丁
patch_cfg() {
  if [ ! -s "$INSTALL_DIR/cfg/server.cfg" ]; then
    log "从镜像提取 cfg 模板"
    docker rm -f "${CONTAINER}-tmp" >/dev/null 2>&1 || true
    docker create --name "${CONTAINER}-tmp" "$IMAGE" >/dev/null
    docker cp "${CONTAINER}-tmp:/l4d2/left4dead2/cfg/." "$INSTALL_DIR/cfg/" >/dev/null
    docker rm -f "${CONTAINER}-tmp" >/dev/null
  fi

  log "写入自定义配置（关友伤 / 直连 / 自定义资源 / 收藏夹）"
  local f
  for f in "$INSTALL_DIR"/cfg/server.cfg "$INSTALL_DIR"/cfg/server.cfg.*tick; do
    [ -f "$f" ] || continue
    if grep -q 'deploy-github.sh 注入' "$f"; then
      sed -i "s|^hostname .*|hostname \"$SERVER_NAME\"|" "$f"
      if [ -n "$WORKSHOP" ]; then
        if grep -q '^host_workshop_collection' "$f"; then
          sed -i "s|^host_workshop_collection .*|host_workshop_collection \"$WORKSHOP\"|" "$f"
        else
          printf 'host_workshop_collection "%s"\n' "$WORKSHOP" >> "$f"
        fi
      fi
      continue
    fi
    {
      echo ""
      echo "// ===== deploy-github.sh 注入 ====="
      echo "hostname \"$SERVER_NAME\""
      echo "mp_friendlyfire 0"
      echo "survivor_friendly_fire_factor_easy 0"
      echo "survivor_friendly_fire_factor_normal 0"
      echo "survivor_friendly_fire_factor_hard 0"
      echo "survivor_friendly_fire_factor_expert 0"
      echo "sv_lan 0"
      echo "sv_allow_lobby_connect_only 0"
      echo "sv_consistency 0"
      echo "sv_region 4"
      [ -n "$WORKSHOP" ] && echo "host_workshop_collection \"$WORKSHOP\""
    } >> "$f"
  done
}

# ---------------------------------------------------------------- 5. 拉镜像
pull_image() {
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    log "镜像已存在，跳过 12GB 下载"
    return 0
  fi
  log "首次部署需拉取 $IMAGE（约 12 GB；中断后重跑本脚本会续传已完成分层）"
  local n
  for n in 1 2 3; do
    if docker pull "$IMAGE"; then log "镜像拉取完成"; return 0; fi
    warn "第 $n 次拉取失败，20 秒后重试"
    sleep 20
  done
  if [ -n "$PULLER" ]; then
    warn "改从 $PULLER 前缀拉取"
    if docker pull "$PULLER/$IMAGE"; then
      docker tag "$PULLER/$IMAGE" "$IMAGE"
      log "镜像拉取完成（来自 $PULLER）"
      return 0
    fi
  fi
  die "镜像拉取失败；重跑脚本继续，或加 --mirror 你的阿里云加速器地址"
}

# ---------------------------------------------------------------- 6. addons
fetch_addons() {
  [ -n "$ADDON_URLS" ] || return 0
  local url name
  mkdir -p "$INSTALL_DIR/addons"
  for url in $(echo "$ADDON_URLS" | tr ',' ' '); do
    [ -n "$url" ] || continue
    name="$(basename "${url%%\?*}")"
    log "下载 addon: $name"
    curl -fsSL --max-time 300 "$url" -o "$INSTALL_DIR/addons/$name" || warn "下载失败: $url"
  done
}

# ---------------------------------------------------------------- 主流程
main() {
  install_docker
  config_mirror
  write_compose
  pull_image
  patch_cfg
  fetch_addons

  log "启动容器"
  compose_up
  sleep 15

  if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    log "容器已在运行"
  else
    warn "容器未运行，执行: docker logs --tail 50 $CONTAINER"
  fi

  echo
  echo "================================================================"
  echo " L4D2 服务器已就绪"
  echo "----------------------------------------------------------------"
  echo " 直连地址   : connect $PUBIP:$PORT"
  echo " 服务器名   : $SERVER_NAME"
  echo " RCON 密码  : $RCON_PASSWORD"
  echo " 安装目录   : $INSTALL_DIR"
  echo " 配置文件   : $INSTALL_DIR/cfg/server.cfg"
  echo " addons 目录: $INSTALL_DIR/addons"
  echo " 收藏夹 ID  : ${WORKSHOP:-（未设置）}"
  echo "----------------------------------------------------------------"
  echo " 常用命令"
  echo "   启动 : cd $INSTALL_DIR && docker compose up -d"
  echo "   停止 : cd $INSTALL_DIR && docker compose down"
  echo "   日志 : docker logs -f $CONTAINER"
  echo "   改配置: vi $INSTALL_DIR/cfg/server.cfg && docker restart $CONTAINER"
  echo "----------------------------------------------------------------"
  echo " 记得在阿里云安全组放行 $PORT TCP + UDP"
  echo " 不玩了就【释放实例】——关机仍收磁盘/EIP 费用"
  echo "================================================================"
}

main "$@"


