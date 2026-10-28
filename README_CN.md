# pi-web-alive

[English](README.md) | 中文

**一句话部署。** 在要运行 pi-web 的机器上，对你的 AI agent（Claude Code、pi 等）说：

```text
用 https://github.com/Tigerrr07/pi-web-alive 在这台机器上部署 pi-web
```

---

让 [pi-web](https://github.com/agegr/pi-web)（pi coding agent 的网页版）在 Linux、WSL2 或 macOS 上通过 tmux 一直运行，并能从手机或其他电脑访问：

- **Tailscale**：只在你的 tailnet 内提供 HTTPS 访问，适合装了 Tailscale 的设备。
- **Cloudflare Tunnel + Access**：公网域名，任何浏览器都能打开，由 Cloudflare Access 先验证身份。Access 没有生效时，隧道会自动关闭。

这是一个 [Agent Skill](https://agentskills.io/specification)：`SKILL.md` 是完整的操作说明，`scripts/` 负责具体执行。既可以交给 AI agent 来用，也可以自己手动运行脚本。

## 前提条件

- 内存 ≥ 4 GB。内存更小的机器在第一次启动或 agent 干活时会耗尽内存，可能卡死
- Node ≥ 22.19
- tmux ≥ 3.0
- curl
- C/C++ 编译工具链（node-pty 需要）
- pi coding agent：

  ```bash
  npm i -g @earendil-works/pi-coding-agent
  ```

- 远程访问需要：Tailscale 和/或 cloudflared；用 Cloudflare 还需要一个托管在 Cloudflare 上的域名。

## 用 AI agent 快速开始

用页面顶部那一句话即可，也可以加上你的需求，比如：*"……并且能用手机通过 Tailscale 访问。"*

agent 会安装 skill 并完成部署，只把需要你本人做的步骤交给你：
- 打开 Tailscale 登录链接
- 在 Cloudflare 控制台里操作
- 粘贴隧道 token
- 需要 sudo 或管理员 PowerShell 的操作

skill 装好以后，之后的请求就不用再带链接了，比如：*"查一下 pi-web 的状态"*、*"给 pi-web 加上 Cloudflare 访问"*。

### 写给 AI agent 的说明

如果用户让你使用这个仓库：

1. **安装 skill。** 把仓库放进你的 skills 目录，文件夹名保持 `pi-web-alive`：
   - Claude Code：`~/.claude/skills/pi-web-alive`
   - pi：`~/.pi/agent/skills/pi-web-alive`
   - 其他遵循 Agent Skills 标准的 agent：`~/.agents/skills/pi-web-alive`

   ```bash
   git clone https://github.com/Tigerrr07/pi-web-alive ~/.claude/skills/pi-web-alive

   # 没有 git 时（新服务器常常没装）：
   mkdir -p ~/.claude/skills && curl -fsSL https://github.com/Tigerrr07/pi-web-alive/archive/refs/heads/main.tar.gz \
     | tar xz -C ~/.claude/skills && mv ~/.claude/skills/pi-web-alive-main ~/.claude/skills/pi-web-alive
   ```

   如果文件夹已经存在，改用 `git pull` 更新。
2. **按 skill 操作。** 阅读该文件夹里的 `SKILL.md` 并照着做，脚本从它的 `scripts/` 目录运行。
3. **缺少前提条件时。** 告诉用户缺什么，得到同意后再安装。

### 自己安装 skill（可选）

```bash
git clone https://github.com/Tigerrr07/pi-web-alive ~/.claude/skills/pi-web-alive   # 或 ~/.pi/agent/skills/、~/.agents/skills/
```

在 pi 里可以用 `/skill:pi-web-alive` 主动加载。只想临时试一次、不安装的话，运行 `pi --skill ./pi-web-alive`。

## 手动使用（Linux）

```bash
git clone https://github.com/Tigerrr07/pi-web-alive ~/pi-web-alive
S=~/pi-web-alive/scripts

bash $S/setup.sh --port 30141     # 写配置、生成密码、安装看门狗
bash $S/service.sh install        # systemd 用户服务 + linger：开机自启
bash $S/status.sh                 # 期望：pi-web 返回 HTTP 307，API 返回 401

# Tailscale（先登录：sudo tailscale up；sudo tailscale set --operator=$USER）
bash $S/ts.sh serve
bash $S/service.sh restart        # 在普通终端里运行，不要在 pi-web 里运行

cat ~/.config/pi-web/password     # pi-web 的登录密码
```

然后在任何登录了你 tailnet 的设备上打开 `https://<机器名>.<tailnet>.ts.net`。

更多内容：[SKILL.md](SKILL.md)（macOS、WSL、日常操作）、[Tailscale 模式](reference/tailscale.md)、[Cloudflare](reference/cloudflare.md)、[问题排查](reference/troubleshooting.md)（均为英文）。

## 关闭 / 打开

```bash
bash <skill>/scripts/service.sh stop        # 关闭，重启机器后也保持关闭
bash <skill>/scripts/service.sh start       # 重新打开
bash <skill>/scripts/service.sh uninstall   # 删除开机自启（保留配置）
```

要在普通终端里运行，不要在 pi-web 里运行。也可以直接对 agent 说：*"把 pi-web 关掉"*。

## 更新

```bash
git -C ~/.pi/agent/skills/pi-web-alive pull   # 或者你 clone 到的其他位置
bash <clone>/scripts/setup.sh                 # 重新安装 ~/bin/piweb-keepalive.sh，保留你的配置
bash <clone>/scripts/service.sh restart       # 在普通终端里运行
```

## 文件位置

仓库里不存放任何机密信息。每个用户自己的数据放在：

- `~/.config/pi-web/`：`env`、`password`、`cf-token`
- `~/bin/piweb-keepalive.sh`：看门狗
- `~/.cache/piweb-keepalive.log`：日志

## 安全

pi-web 能以你的用户身份执行任何命令。所以这个项目：

- 必须设置密码
- 只让 pi-web 监听 `127.0.0.1`
- 只通过 `tailscale serve` 或有 Access 保护的隧道对外开放

不要使用 `tailscale funnel`、路由器端口转发或 `0.0.0.0`。

## 测试环境

**Windows 上的 WSL2**（Ubuntu 26.04，用 nvm 安装的 Node 24，tmux 3.6）：
- 部署、看门狗和崩溃恢复、`status.sh`
- 计划任务的 `start` / `stop` / `restart`（用测试任务验证：任务关闭后，即使触发器一直在触发，也保持关闭）
- Cloudflare Access 检查：受保护的域名会放行，没保护的会拒绝（失败时默认关闭）

**AWS EC2 上的 Linux**（RHEL 10.2，x86_64，2 vCPU，7.5 GB 内存，系统自带 Node 22，没有 nvm）：
- 只给 Claude Code 一句话，它仅凭 skill 就完成了全部部署
- 崩溃、tmux 会话被删、`service.sh restart` 之后都能恢复
- 重启机器后，不用登录就能自动恢复
- `stop` 后重启机器仍保持关闭，`start` 能重新打开
- Tailscale（`system` 模式）：从其他设备 HTTPS 访问正常，必须输入密码，serve 配置被清掉后自动恢复，重启 25 秒后即可再次访问

**还没测过：** macOS，以及用这个仓库完整跑一遍 Cloudflare Tunnel。
