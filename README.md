# keepalive

服务与长任务保活工具包。

## 分轨

| | 常驻服务 | 长任务 |
|---|---|---|
| 例子 | 网关、转发器、Web UI | 下载、扫描、批量处理 |
| 特点 | 无状态，死了重启即可 | 有状态，必须从断点恢复 |
| 机制 | systemd | cron 看门狗 + 检查点 |

## 常驻服务（systemd）

unit 模板见 `SKILL.md`。要点：
- `Restart=always`，`RestartSec=5`
- 二进制、配置、数据放家目录（跨整机替换保留）
- unit 权威副本存家目录，改完同步到 `/etc/systemd/system/`

## 长任务（cron 看门狗 + 检查点）

看门狗 `scripts/supervisor.sh` 每 5 分钟巡检一次，死了从检查点拉起。

任务定义 `tasks/<name>.task`：
```bash
CMD="<完整启动命令，必须支持从检查点恢复>"
CHECKPOINT="<检查点文件路径>"
DONE_MARKER="<完成标记文件路径>"
```

任务脚本必须做到：
1. 启动时读检查点，有则从断点继续
2. 每完成一个单元立刻写检查点落盘
3. 完成后 touch DONE_MARKER
4. 幂等：重复执行已完成单元不出错

## 详细文档

见 [SKILL.md](SKILL.md)。
