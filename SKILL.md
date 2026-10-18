---
name: keepalive
description: "常驻服务用 systemd 保活（秒级重启），一次性长任务用 cron 看门狗 + 检查点恢复。覆盖进程崩溃、整机重启、整机替换三层故障。"
version: 1.0.0
license: MIT
---

# 服务与长任务保活

家目录指 `$HOME`（本机为 `/home/hatch`，换机器时按实际路径替换）。

环境说明：本文的三层故障模型（进程崩溃、整机重启、整机替换），以及「无用户总线」「出网走代理」等前提，源于云沙盒类环境的特性（家目录持久、系统盘易失、出网经代理）。部署到普通服务器或个人电脑时逐项核对，不存在的层直接跳过，不要硬套。

## 分轨

| | 常驻服务 | 长任务 |
|---|---|---|
| 例子 | 网关、转发器、Web UI | 下载、扫描、批量处理 |
| 特点 | 无状态，死了重启即可 | 有状态，必须从断点恢复 |
| 机制 | systemd | cron 看门狗 + 检查点 |

## 为什么不用脚本看门狗拉活

运行时重启会回收整个进程树，已脱离会话的后台进程一并被杀。systemd 是 1 号进程，不在任何会话的进程树里，是唯一能全程盯住服务的监护人。定时巡检只做兜底，不做主保活。

## 轨道一：常驻服务（systemd）

本类沙盒环境以 root 运行且无用户总线，`systemctl --user` 不可用（换环境先核实，用户总线可用时优先用 `--user`）。用系统级 unit 时装到 `/etc/systemd/system/`。

二进制、配置、数据放家目录。家目录跨整机替换保留，系统路径的会丢。

unit 的权威副本存一份在家目录。改配置先改副本，再同步到 `/etc`，改完读回核对。

unit 模板：

```
[Unit]
Description=<一句话说明>
After=network.target

[Service]
Type=simple
ExecStart=<绝对路径和参数>
WorkingDirectory=<家目录下的工作目录>
Environment=HOME=<家目录绝对路径>
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

`Restart` 按类型选：常驻服务用 `always`；一次性任务用 `on-failure` 或 `no`（`always` 会把正常结束的任务无限拉起）。

服务要联网、且所在环境出网走代理时，把出口代理写进 unit 的 `Environment`（`http_proxy` / `https_proxy`）。systemd 不继承交互 shell 的环境变量，漏写表现为 TLS 握手失败，易被误判为上游封锁。

密钥类变量放独立的 EnvironmentFile 并设 600，unit 里只写 `EnvironmentFile=<路径>`。密钥值不进 unit 正本、不进聊天、不进记忆。

安装：

```
cp <家目录副本> /etc/systemd/system/<name>.service
systemctl daemon-reload
systemctl enable --now <name>
```

装完验 `systemctl is-active <name>` 和端口。

## 轨道二：长任务（cron 看门狗 + 检查点）

看门狗只负责"死了拉起来"，恢复逻辑在任务自己手里。

任务定义 `<技能目录>/tasks/<name>.task`：

```bash
CMD="<完整启动命令，必须支持从检查点恢复>"
CHECKPOINT="<检查点文件路径>"
DONE_MARKER="<完成标记文件路径>"
```

任务脚本必须做到四条：

1. 启动时读检查点，有则从断点继续，无则从头开始。
2. 每完成一个单元立刻写检查点落盘，不攒在内存。
3. 完成后 `touch` DONE_MARKER，看门狗看到即不再重启。
4. 幂等：重复执行已完成单元不出错。

随附脚本 `scripts/supervisor.sh` 是看门狗本体。它按自身所在位置定位技能目录为数据根，tasks、state、logs 三个子目录首次运行时自动建在技能目录下。整个技能文件夹放任意位置都成立，部署只需把 cron 指向 `<技能目录>/scripts/supervisor.sh`，不钦定路径。

升级时只替换 SKILL.md 与 scripts/，tasks、state、logs 三个数据目录保留，不要覆盖删除。

看门狗由 cron 每 5 分钟调用。特性：flock 防并发、pidfile 存 PID+命令指纹（防重建后 PID 复用误判）、单任务错误隔离、日志超 10MB 自动裁剪、启动 3 秒验活（秒崩计入启动失败，连续启动失败 5 次停手）、`--check` 离线体检模式。

任务死后最多 5 分钟被拉起。

停手只针对启动失败。任务若在固定检查点定点崩溃（如某个坏输入文件），看门狗会持续重启、不会停手，靠任务日志发现后人工处理。

看门狗停手时在 `logs/supervisor.log` 写「停手待查」。上层 agent 巡检或复查时应读该日志，捡到停手记录要上报用户，不要只留在日志里。

注册：写 `.task` 文件后手动跑一轮 `bash <技能目录>/scripts/supervisor.sh` 验证，再看 `logs/supervisor.log`。

停任务：`touch` 对应的 DONE_MARKER 文件。

## 守护巡检

一条低频 cron（每 10 分钟），只做本地检查，不访问外网。

对 systemd 服务查三项：unit 文件在不在、`systemctl is-active`、端口有无响应。unit 丢失（整机被替换的迹象）时按家目录副本重装、daemon-reload、enable、start；unit 在但服务没跑时 `systemctl reset-failed` 后 start。

对看门狗任务：由 `supervisor.sh` 自带逻辑处理（见"轨道二"），无需额外巡检。

三项都正常则静默。只有实际执行了修复才报一句话，注明此前状态；修复失败报失败点并附 `journalctl -u <name> -n 5 --no-pager` 关键行。

巡检禁止手动拉起 systemd 托管的进程本体（会撞端口），禁止改动服务定义内容。

> 注：部署首个 systemd 服务时，一并创建这条守护巡检 cron，不要等服务出事后再补。

## 验收

进程级：`kill` 服务主进程，10 秒内应出现新进程，`systemctl show <name> -p NRestarts` 加 1，端口恢复响应。

定义级：家目录副本存在且与 `/etc` 中一致；巡检指令写明重装路径。整机替换无法主动实测，靠巡检在一个周期内恢复。

每次改完 unit 或巡检任务，用 `cron.view` 或读文件读回确认后再报完成。

## 硬规则

停服务只用 `systemctl stop`，杀单个进程用精确 PID。不用会杀整棵进程树的工具碰守护进程或服务进程。

全局包安装落在家目录前缀（如 npm `--prefix ~/.local`）。装进 `/usr` 的整机替换时会消失。

汇报恢复能力分三层：进程崩溃秒级自拉，整机重启靠开机自启，整机替换靠巡检在一个周期内重装。后两层不许说成无感恢复。
