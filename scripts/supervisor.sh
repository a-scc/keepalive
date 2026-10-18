#!/usr/bin/env bash
# supervisor.sh — 长任务看门狗（由 runtime cron 每 5 分钟调用）
#
# 用法：
#   supervisor.sh           # 正常巡检：检查并重启死掉的任务
#   supervisor.sh --check   # 离线体检：只报告状态，不启动任何任务
#
# 任务定义 tasks/<name>.task：
#   CMD="完整启动命令（必须支持从检查点恢复）"
#   DONE_MARKER="完成标记文件路径"
#
set -uo pipefail

# 自定位：以技能文件夹为根（脚本在 scripts/ 子目录下），文件夹放任意位置都成立
SUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_DIR="$SUP_DIR/tasks"
STATE_DIR="$SUP_DIR/state"
LOG_DIR="$SUP_DIR/logs"
SUP_LOG="$LOG_DIR/supervisor.log"
LOCK_FILE="$SUP_DIR/supervisor.lock"
LOG_MAX_BYTES=$((10 * 1024 * 1024))
MAX_RESTARTS=5  # 连续启动失败超过此数则停手待查

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$SUP_LOG"
}

# 日志裁剪：超过 10MB 只保留末尾 10MB，按整行裁
trim_log() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    local size
    size=$(stat -c%s "$file" 2>/dev/null) || return 0
    (( size <= LOG_MAX_BYTES )) && return 0
    tail -c "$LOG_MAX_BYTES" "$file" | tail -n +2 > "$file.tmp" 2>/dev/null \
        && mv "$file.tmp" "$file"
}

# pidfile 格式："<pid> <cmd指纹>"，防 PID 复用误判
is_running() {
    local pidfile="$1" expect_fp="$2"
    [[ -f "$pidfile" ]] || return 1
    local pid fp
    read -r pid fp < "$pidfile" 2>/dev/null || return 1
    [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    # 指纹对不上说明 PID 被复用
    [[ "$fp" == "$expect_fp" ]] || return 1
    return 0
}

cmd_fingerprint() {
    echo -n "$1" | sha1sum | cut -d' ' -f1 | cut -c1-12
}

# 单个任务处理（子 shell 隔离，单个任务报错不拖死整轮）
process_task() {
    local taskfile="$1"
    local name
    name=$(basename "$taskfile" .task)

    local CMD="" DONE_MARKER=""
    # shellcheck disable=SC1090
    source "$taskfile" || { log "[$name] 定义文件语法错误，跳过"; return 1; }
    [[ -z "$CMD" ]] && { log "[$name] 无 CMD，跳过"; return 1; }

    local fp pidfile tasklog failfile
    fp=$(cmd_fingerprint "$CMD")
    pidfile="$STATE_DIR/$name.pid"
    tasklog="$LOG_DIR/$name.log"
    failfile="$STATE_DIR/$name.failcount"

    if [[ -n "$DONE_MARKER" && -f "$DONE_MARKER" ]]; then
        return 0
    fi

    if is_running "$pidfile" "$fp"; then
        return 0
    fi

    if (( CHECK_ONLY )); then
        echo "[$name] 未运行（--check，不启动）"
        return 0
    fi

    local fails=0
    [[ -f "$failfile" ]] && fails=$(cat "$failfile" 2>/dev/null || echo 0)
    if (( fails >= MAX_RESTARTS )); then
        log "[$name] 连续失败 $fails 次，停手待查（删 $failfile 可重置）"
        return 1
    fi

    log "[$name] 未运行，启动（第 $((fails + 1)) 次）"
    # 子进程关闭 lock FD（200），否则后台任务会继承锁导致永远不释放
    # shellcheck disable=SC2086
    nohup bash -c "exec 200>&-; $CMD" >> "$tasklog" 2>&1 &
    local newpid=$!
    echo "$newpid $fp" > "$pidfile"

    # 启动后 3 秒验活，秒崩则计失败
    sleep 3
    if is_running "$pidfile" "$fp"; then
        echo 0 > "$failfile"
        log "[$name] 启动成功 (pid $newpid)"
    else
        echo $((fails + 1)) > "$failfile"
        log "[$name] 启动后秒崩，失败计数 $((fails + 1))/$MAX_RESTARTS"
    fi
}

main() {
    mkdir -p "$TASK_DIR" "$STATE_DIR" "$LOG_DIR"

    # flock 防并发：上一轮没跑完，下一轮直接退出
    exec 200>"$LOCK_FILE"
    flock -n 200 || { log "上一轮未结束，跳过"; exit 0; }

    trim_log "$SUP_LOG"
    (( CHECK_ONLY )) || log "=== supervisor 启动 ==="

    local count=0
    for taskfile in "$TASK_DIR"/*.task; do
        [[ -f "$taskfile" ]] || continue
        ( process_task "$taskfile" ) || true
        ((count++)) || true
    done

    for lf in "$LOG_DIR"/*.log; do
        [[ -f "$lf" ]] || continue
        trim_log "$lf"
    done

    (( CHECK_ONLY )) || log "=== supervisor 结束（检查 $count 个任务）==="
}

main "$@"
