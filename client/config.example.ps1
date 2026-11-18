# ============================================================
# 复制本文件为 config.ps1 后填写真实值。
# config.ps1 已被 .gitignore 排除，绝不会进 GitHub。
# ============================================================
$Config = @{
    # ---- 连接 ----
    ServerIP = '127.0.0.1'          # 阿里云 ECS 公网 IP
    SshUser  = 'root'
    SshPort  = 22

    # 认证方式二选一（推荐密钥：新建实例时绑定同一个密钥对，以后零密码）
    KeyPath  = ''                   # 例: 'C:\Users\me\.ssh\l4d2_rsa'
    Password = ''                   # 密码登录需要 plink.exe: winget install PuTTY.PuTTY

    # ---- 部署参数 ----
    ServerName         = 'L4D2 专用服'
    Port               = 27015
    MaxPlayers         = 8
    StartMap           = 'c1m1_hotel'
    Difficulty         = 'Normal'   # Easy|Normal|Hard|Impossible
    SvPassword         = ''         # 进服密码，留空=不设
    WorkshopCollection = ''         # 隐藏血条等 Mod 的收藏夹 ID，留空=不启用
}
