# left4dead2-serve

阿里云按量付费 ECS 上的 **Left 4 Dead 2 专用服务器**，一条命令装好，不玩就释放实例 —— 不运行时 0 元。

- 服务端：SteamCMD 官方 app `222860`（L4D2 Dedicated Server），不依赖第三方整合包
- 已内置：关闭队友伤害、隐藏血条 Mod 下发位、systemd 托管、开机自启
- 幂等：`deploy.sh` 可以反复跑，第二次起是增量更新/改配置

---

## 1. 成本模型（先看这段，决定你怎么反复搭）

按量付费 ECS **关机不等于免费**：

| 项目 | 关机/节省停机模式下 |
|---|---|
| vCPU / 内存 | 不计费 |
| 系统盘（云盘） | **继续计费** |
| 弹性公网 IP(EIP) | **继续计费**（未绑定实例也会收） |
| 快照 / 自定义镜像 | **继续计费**（按 GB·月） |

**只有「释放实例」才把系统盘一起删掉、真正停表。** 所以本项目的止损动作是：

```
不玩了 → down.ps1（停服） → 控制台释放实例 → 有 EIP 就一起释放
```

一次性开销参考：首次装服要下 ~12 GB，按量流量 + 1 小时 2 核 4G 大约几毛钱。

---

## 2. 反复搭建的两种方式

### 方式 A：纯脚本重装 —— 零残留费用（推荐）

每次要玩：

1. 控制台创建按量付费实例（Ubuntu 22.04，安全组放行 27015 TCP+UDP）
2. 双击跑 `client\up.ps1`（10~20 分钟，主要在下载 12 GB）
3. 进游戏 `connect <公网IP>:27015`
4. 玩完 `client\down.ps1` → 释放实例

代价：每次等下载。收益：不玩的时候真的没有任何费用，也没有快照/镜像在后台扣钱。

### 方式 B：自定义镜像 —— 1 分钟起服，但要交存储费

装好一次后创建**自定义镜像**，之后用镜像创建实例，开机即有服（不用等 SteamCMD）。
镜像按 GB·月 计费（40 GB 系统盘 ≈ 4 元/月左右），属于"不用也在花钱"。

### 怎么选

| 频率 | 选 |
|---|---|
| 一周一两次、每次几小时 | A |
| 天天开、或者开黑时间不固定但很频繁 | B |
| 只是偶尔朋友约一局 | A |

> 想在 A 里少等一点：把 `MaxPlayers` 调小、下载时别中断；`up.ps1` 支持重复执行，断了直接再跑一次即可续传。

---

## 3. 首次使用

### 3.1 创建实例的要点

| 项 | 建议 |
|---|---|
| 镜像 | Ubuntu 22.04 LTS（Debian 11/12、Alibaba Cloud Linux 3 也支持） |
| 规格 | 2 核 4 GB 起（8 人 coop 够用；4 人 2 核 2 GB 也能跑） |
| 系统盘 | ESSD 40 GB（服务端约 12~15 GB） |
| 公网 | 分配公网 IPv4，**按使用流量计费**（玩得短更省） |
| 登录 | 密码 或 **密钥对（推荐，之后 up.ps1 全自动免密）** |
| 安全组 | 入方向放行 `27015` **TCP 和 UDP**；SSH `22` 建议只放行你自己的 IP |

### 3.2 本地跑起来

```powershell
git clone https://github.com/yanshui233/left4dead2-serve.git
```

> github.com 打不开（被重置）时，直接用本机这份文件夹就行，或走 `client\publish.ps1` 走 API 同步。

```powershell
cd left4dead2-serve\client

Copy-Item .\config.example.ps1 .\config.ps1
notepad .\config.ps1        # 填 ServerIP，以及 KeyPath 或用 Password

powershell -ExecutionPolicy Bypass -File .\up.ps1
```

- 想完全不依赖 GitHub（避免 raw 拉取失败）：`.\up.ps1 -Local`，直接把本机 `server\deploy.sh` 传上去执行

- **密码方式**需要 `plink.exe`：`winget install PuTTY.PuTTY`（首次连接会问一次主机指纹，输 `y`）
- **密钥方式**：阿里云创建实例时选同一个密钥对，把下载的 `.pem` 路径填进 `KeyPath`，之后一次都不用手输密码

### 3.3 进服务器

游戏内按 `~` 打开控制台：

```
connect <公网IP>:27015
```

`config.ps1` 里填了 `Port` 就换成对应端口。服务器名会显示为 `ServerName`。

---

## 4. 关闭队友伤害 / 隐藏血条

### 4.1 关闭队友伤害（已默认开启）

`deploy.sh` 生成的 `server.cfg` 里写了两层，避免被难度系数覆盖：

```
mp_friendlyfire 0
survivor_friendly_fire_factor_easy 0
survivor_friendly_fire_factor_normal 0
survivor_friendly_fire_factor_hard 0
survivor_friendly_fire_factor_expert 0
```

临时改（不用重装）：

```bash
# 服务器上
rcon_password <部署时打印的RCON密码>   # 或用服务器控制台
rcon mp_friendlyfire 0
```

改完持久生效就直接编辑 `/opt/l4d2/left4dead2/cfg/server.cfg` 后 `systemctl restart l4d2ds`。

### 4.2 隐藏血条（重要：没有原生 cvar）

**L4D2 服务端不存在"隐藏血条/隐藏 HUD"的原生指令**。网上流传的那些 `l4d2_hide_hud 1` 之类并不是真实 cvar，写进 cfg 只会被当成未知命令忽略。真实可行的是下面两种：

**方式一：创意工坊 Mod + 收藏夹强制下发（推荐，不用装插件）**

1. Steam 创意工坊搜 `Hide HUD` / `No HUD`，只挑 **L4D2 专属、且明确说是隐藏 HUD/血条** 的 Mod（看清楚是不是 CS:GO/其他游戏的）
2. 新建一个**收藏夹**，把这个 Mod 收进去
3. 打开收藏夹页面，URL 形如
   `https://steamcommunity.com/sharedfiles/filedetails/?id=`**`1234567890`**
   末尾那串数字就是收藏夹 ID
4. 填进 `client\config.ps1` 的 `WorkshopCollection`，重跑 `up.ps1`；
   或者直接在服务器上执行：
   ```bash
   WORKSHOP_COLLECTION=1234567890 bash /root/l4d2-deploy.sh
   ```
5. 生成的 server.cfg 里会出现 `host_workshop_collection "1234567890"`，
   玩家连服时会自动订阅下载整个收藏夹，下载完 **重进一次** 即生效

**方式二：SourceMod 插件**（要装 MM+SM，见第 5 节）
插件可以在服务端层面直接压掉 HUD 元素，效果对所有人生效，但装插件本身就是一堆额外维护。

> 提醒：血条是客户端渲染的，服务端不能直接"关掉"。所谓"服主关血条"本质都是让客户端装上会隐藏 HUD 的 Mod。

---

## 5. 懒人包 / 插件怎么打（可选）

- **VPK 类**（枪械、模型、HUD 贴图替换）：直接丢 `addons/`
  ```bash
  scp .\xxx.vpk root@<IP>:/opt/l4d2/left4dead2/addons/
  systemctl restart l4d2ds
  ```
- **SourceMod / MetaMod**：必须用 **Linux 版**压缩包（`mmsource-*.tar.gz`、`sourcemod-*.tar.gz`），
  解压后把里面的 `addons/` 覆盖到 `/opt/l4d2/left4dead2/`，重启服务。
  Windows 版 `.dll` 在 Linux 上没有任何用处。
- **第三方"整合懒人包"**：绝大多数是给 Windows 本地开服用的一键安装器（.exe），
  里面能在 Linux 复用的只有 `addons/*.vpk`、`cfg/*.cfg`、以及 Linux 版 `*.so`。
  不要指望在 ECS 上双击安装器。

---

## 6. 排障

| 现象 | 处理 |
|---|---|
| 服务没起来 | `journalctl -u l4d2ds -n 80 --no-pager` |
| 报缺 `libstdc++` / 32 位库 | Ubuntu：`apt install lib32gcc-s1 lib32stdc++6`；ALinux3/CentOS：`dnf install glibc.i686 libstdc++.i686` |
| SteamCMD 报 update failed | 直接重跑 `up.ps1`；仍失败就 `rm -rf /opt/steamcmd` 后重跑 |
| 客户端连不上 | ①安全组放行 27015 **TCP+UDP** ②`ss -lunp \| grep 27015` 看有没有在听 ③进游戏前先在控制台 `connect ip:port` |
| 服务器列表里搜不到 | 公网服务器在列表里本来就不好搜，直接 `connect` 最稳；`sv_allow_lobby_connect_only 0` 已开 |
| 队友还能互相打 | 确认 cfg 真被加载：日志里找 `execing server.cfg`；再 `rcon mp_friendlyfire 0` 现场确认 |
| 血条还在 | ①收藏夹 ID 填了没 ②Mod 是不是 HUD 类 ③玩家是否订阅完成并重进服务器 |
| 磁盘满 | 系统盘至少 40 GB；`du -sh /opt/l4d2/*` 看占用 |

常用命令：

```bash
systemctl status l4d2ds
systemctl restart l4d2ds
journalctl -u l4d2ds -f
cat /opt/l4d2/left4dead2/cfg/server.cfg
```

---

## 7. 目录结构

```
left4dead2-serve/
├─ server/
│  ├─ deploy.sh      # ECS 上一键安装（幂等，可反复执行）
│  └─ uninstall.sh   # 彻底卸载（停服务 + 删 12GB 文件 + 删运行用户）
├─ client/
│  ├─ up.ps1             # 本地一键部署到 ECS
│  ├─ down.ps1           # 停服 / -Purge 彻底卸载
│  ├─ config.example.ps1 # 配置模板
│  └─ config.ps1         # 你的私有配置（gitignore，不会上传）
├─ .gitignore
└─ README.md
```

部署参数（都可环境变量覆盖）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `SRCDS_PORT` | 27015 | 服务器端口 |
| `MAXPLAYERS` | 8 | 最大玩家数 |
| `START_MAP` | c1m1_hotel | 启动地图 |
| `DIFFICULTY` | Normal | Easy/Normal/Hard/Impossible |
| `SV_PASSWORD` | 空 | 进服密码 |
| `RCON_PASSWORD` | 随机 12 位 | RCON 密码 |
| `WORKSHOP_COLLECTION` | 空 | 隐藏血条等 Mod 收藏夹 ID |
| `INSTALL_DIR` | /opt/l4d2 | 安装目录 |

---

## 8. 安全

- 仓库里**不含任何密码**：密码只在你本地 `client/config.ps1`（已被 `.gitignore` 排除）
- 强烈建议实例绑定**密钥对**：`up.ps1` 走密钥通道，SSH 密码可整个关掉
- 安全组里 SSH `22` 只放行你自己的 IP
- 用过的 GitHub PAT 建议到 `Settings → Developer settings → Personal access tokens` 撤销重建

