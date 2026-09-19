#!/usr/bin/env bash
# dev-pipeline.sh — 把「清理残留 → 装依赖 → 构建 → 启动检查」串成一条可重复执行的流水线。
#
# 用法:
#   ./scripts/dev-pipeline.sh [all|deps|build|check|clean|distclean]   (默认 all)
#
# 约定:
#   - 每步带编号/计时, 失败或超时直接指出卡在哪一步, 并打印该步日志末尾
#   - 中间产物 (dist、日志、pid、残留进程) 每次运行前自动清理
#   - 依赖缓存 (node_modules、.venv、~/.npm、~/.cache/pip) 保留复用, distclean 才会删
#   - 完整日志在 .dev/logs/
#
# 可用环境变量:
#   BACKEND_PORT=8000  FRONTEND_PORT=3000
#   DEPS_TIMEOUT=600   BUILD_TIMEOUT=300   STARTUP_TIMEOUT=60   (秒)

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DIR="$ROOT/backend"
FRONTEND_DIR="$ROOT/frontend"
DEV_DIR="$ROOT/.dev"
LOG_DIR="$DEV_DIR/logs"
PID_DIR="$DEV_DIR/pids"

BACKEND_PORT="${BACKEND_PORT:-8000}"
FRONTEND_PORT="${FRONTEND_PORT:-3000}"
DEPS_TIMEOUT="${DEPS_TIMEOUT:-600}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-300}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-60}"

VENV_DIR="$BACKEND_DIR/.venv"
VENV_PY="$VENV_DIR/bin/python"

mkdir -p "$LOG_DIR" "$PID_DIR"

# ---------- 输出 ----------
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'
  C_RED=$'\033[1;31m'; C_YELLOW=$'\033[1;33m'
else
  C_RESET=''; C_BLUE=''; C_GREEN=''; C_RED=''; C_YELLOW=''
fi

log()  { printf '%s[%s]%s %s\n' "$C_BLUE" "$(date +%H:%M:%S)" "$C_RESET" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[WARN ]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf '%s[FAIL ]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

STEP_INDEX=0
STEP_TOTAL=1
CURRENT_STEP="初始化"
CURRENT_LOG=""

banner() {
  STEP_INDEX=$((STEP_INDEX + 1))
  CURRENT_STEP="$1"
  CURRENT_LOG=""
  printf '\n%s========== [%d/%d] %s ==========%s\n' "$C_BLUE" "$STEP_INDEX" "$STEP_TOTAL" "$1" "$C_RESET"
}

fail() {
  err "卡在步骤「$CURRENT_STEP」: $1"
  if [ -n "$CURRENT_LOG" ] && [ -f "$CURRENT_LOG" ]; then
    err "---- 该步日志末尾 ($CURRENT_LOG) ----"
    tail -n 30 "$CURRENT_LOG" >&2 || true
    err "---- 完整日志见 $CURRENT_LOG ----"
  fi
  exit 1
}

# ---------- 进程/超时 ----------
SERVER_PIDS=""

kill_pid() {
  kill "$1" 2>/dev/null || true
}

cleanup() {
  trap - EXIT INT TERM
  local pid
  for pid in $SERVER_PIDS; do kill_pid "$pid"; done
  [ -z "$SERVER_PIDS" ] || sleep 1
  for pid in $SERVER_PIDS; do kill -9 "$pid" 2>/dev/null || true; done
  rm -f "$PID_DIR"/*.pid 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 兼容 macOS (无 GNU timeout): 后台跑 + 轮询, 超时先 TERM 后 KILL
run_with_timeout() { # <秒> <命令...>
  local seconds="$1"; shift
  "$@" &
  local pid=$! elapsed=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$elapsed" -ge "$seconds" ]; then
      kill_pid "$pid"; sleep 2
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1; elapsed=$((elapsed + 1))
  done
  wait "$pid"
}

run_logged() { # <日志文件> <超时秒> <命令...>
  local logfile="$1" t="$2"; shift 2
  CURRENT_LOG="$logfile"
  log "运行: $*"
  local start=$SECONDS rc=0
  run_with_timeout "$t" "$@" >>"$logfile" 2>&1 || rc=$?
  if [ "$rc" -eq 124 ]; then
    fail "超过 ${t}s 未结束, 已强制终止 (可调大对应 *_TIMEOUT)"
  elif [ "$rc" -ne 0 ]; then
    fail "命令退出码 $rc"
  fi
  ok "完成 (用时 $((SECONDS - start))s)"
}

port_in_use() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

wait_for_url() { # <url> <超时秒>
  local url="$1" t="$2" elapsed=0
  while [ "$elapsed" -lt "$t" ]; do
    if curl -fsS -o /dev/null --max-time 2 "$url" 2>/dev/null; then
      return 0
    fi
    sleep 1; elapsed=$((elapsed + 1))
  done
  return 1
}

# ---------- 步骤 ----------
step_clean() {
  banner "清理上次中间产物"
  local pidfile pid
  for pidfile in "$PID_DIR"/*.pid; do
    [ -e "$pidfile" ] || continue
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      case "$(ps -p "$pid" -o command= 2>/dev/null)" in
        *uvicorn*|*vite*)
          warn "结束上次残留进程 (pid $pid)"
          kill_pid "$pid" ;;
      esac
    fi
    rm -f "$pidfile"
  done
  rm -rf "$FRONTEND_DIR/dist"
  rm -f "$LOG_DIR"/*.log
  find "$FRONTEND_DIR/src" -name '*.js' -delete 2>/dev/null || true   # vue-tsc 误emit的残留
  ok "已清理 dist / 日志 / pid (保留 node_modules、.venv 与依赖缓存)"
}

step_deps_backend() {
  banner "安装后端依赖 (pip)"
  CURRENT_LOG="$LOG_DIR/deps-backend.log"
  if ! "$VENV_PY" -m pip --version >/dev/null 2>&1; then
    if [ -d "$VENV_DIR" ]; then
      warn "已有 backend/.venv 不可用 (可能来自其他机器), 自动重建"
      rm -rf "$VENV_DIR"
    fi
    log "创建虚拟环境 backend/.venv"
    if ! python3 -m venv "$VENV_DIR" >>"$CURRENT_LOG" 2>&1; then
      # 某些系统缺 ensurepip (如 Debian 未装 python3-venv), 退化为 --without-pip + get-pip
      warn "python3 -m venv 失败 (常见原因: 缺 ensurepip), 尝试 --without-pip 方式"
      rm -rf "$VENV_DIR"
      python3 -m venv --without-pip "$VENV_DIR" >>"$CURRENT_LOG" 2>&1 \
        || fail "python3 -m venv --without-pip 仍失败"
      curl -fsSL https://bootstrap.pypa.io/get-pip.py -o "$DEV_DIR/get-pip.py" >>"$CURRENT_LOG" 2>&1 \
        || fail "下载 get-pip.py 失败 (检查网络)"
      "$VENV_PY" "$DEV_DIR/get-pip.py" >>"$CURRENT_LOG" 2>&1 \
        || fail "get-pip.py 安装 pip 失败"
      rm -f "$DEV_DIR/get-pip.py"
    fi
  fi
  run_logged "$CURRENT_LOG" "$DEPS_TIMEOUT" \
    "$VENV_PY" -m pip install --disable-pip-version-check -r "$BACKEND_DIR/requirements.txt"
  # 显式校验, 避免「跑到一半才发现依赖缺失」
  if ! "$VENV_PY" -c 'import fastapi, uvicorn, numpy, multipart' 2>>"$CURRENT_LOG"; then
    fail "依赖校验未通过: fastapi/uvicorn/numpy/multipart 有缺失"
  fi
  ok "后端依赖就绪 ($("$VENV_PY" --version 2>&1))"
}

step_deps_frontend() {
  banner "安装前端依赖 (npm)"
  CURRENT_LOG="$LOG_DIR/deps-frontend.log"
  if [ ! -d "$FRONTEND_DIR/node_modules" ]; then
    log "node_modules 不存在, 按 lockfile 全量安装 (npm ci)"
    run_logged "$CURRENT_LOG" "$DEPS_TIMEOUT" \
      npm --prefix "$FRONTEND_DIR" ci --prefer-offline --no-audit --no-fund
  else
    log "node_modules 已存在, 增量校验/补齐 (缓存复用)"
    run_logged "$CURRENT_LOG" "$DEPS_TIMEOUT" \
      npm --prefix "$FRONTEND_DIR" install --prefer-offline --no-audit --no-fund
  fi
  ok "前端依赖就绪 ($(node --version), npm $(npm --version))"
}

step_build() {
  banner "构建前端 (vue-tsc + vite build)"
  [ -d "$FRONTEND_DIR/node_modules" ] || fail "node_modules 不存在, 请先运行: $0 deps"
  run_logged "$LOG_DIR/build.log" "$BUILD_TIMEOUT" \
    "$FRONTEND_DIR/node_modules/.bin/vue-tsc" --project "$FRONTEND_DIR/tsconfig.json"
  run_logged "$LOG_DIR/build.log" "$BUILD_TIMEOUT" \
    "$FRONTEND_DIR/node_modules/.bin/vite" build "$FRONTEND_DIR"
  [ -f "$FRONTEND_DIR/dist/index.html" ] || fail "构建产物缺失: frontend/dist/index.html"
  ok "构建产物: frontend/dist/"
}

step_check() {
  banner "启动前后端并冒烟检查"
  [ -x "$VENV_PY" ] || fail "backend/.venv 不存在, 请先运行: $0 deps"
  [ -d "$FRONTEND_DIR/node_modules" ] || fail "node_modules 不存在, 请先运行: $0 deps"

  if port_in_use "$BACKEND_PORT"; then
    fail "端口 $BACKEND_PORT 已被占用 (可能是上次手动启动的服务), 请先停止或设置 BACKEND_PORT"
  fi
  if port_in_use "$FRONTEND_PORT"; then
    fail "端口 $FRONTEND_PORT 已被占用, 请先停止或设置 FRONTEND_PORT"
  fi

  log "启动后端 uvicorn → http://127.0.0.1:$BACKEND_PORT"
  CURRENT_LOG="$LOG_DIR/backend.log"
  (cd "$BACKEND_DIR" && exec "$VENV_PY" -m uvicorn app.main:app \
      --host 127.0.0.1 --port "$BACKEND_PORT") >"$CURRENT_LOG" 2>&1 &
  SERVER_PIDS="$SERVER_PIDS $!"
  echo "$!" >"$PID_DIR/backend.pid"
  wait_for_url "http://127.0.0.1:$BACKEND_PORT/api/health" "$STARTUP_TIMEOUT" \
    || fail "后端 ${STARTUP_TIMEOUT}s 内未就绪"
  ok "后端 /api/health 通过"

  log "启动前端 vite → http://127.0.0.1:$FRONTEND_PORT"
  CURRENT_LOG="$LOG_DIR/frontend.log"
  (cd "$FRONTEND_DIR" && BACKEND_PORT="$BACKEND_PORT" FRONTEND_PORT="$FRONTEND_PORT" \
      exec ./node_modules/.bin/vite --host 127.0.0.1 --port "$FRONTEND_PORT" --strictPort) \
      >"$CURRENT_LOG" 2>&1 &
  SERVER_PIDS="$SERVER_PIDS $!"
  echo "$!" >"$PID_DIR/frontend.pid"
  wait_for_url "http://127.0.0.1:$FRONTEND_PORT/" "$STARTUP_TIMEOUT" \
    || fail "前端 ${STARTUP_TIMEOUT}s 内未就绪"
  curl -fsS "http://127.0.0.1:$FRONTEND_PORT/" 2>>"$CURRENT_LOG" | grep -q '<div id="app">' \
    || fail "前端页面已响应但内容异常 (缺少 #app 挂载点)"
  ok "前端页面可打开"

  log "检查 /api 代理 (前端 → 后端 联通)"
  curl -fsS -X POST "http://127.0.0.1:$FRONTEND_PORT/api/generate" \
      -H 'Content-Type: application/json' \
      -d '{"modulation":"QPSK","samples":256,"snr":20}' 2>>"$CURRENT_LOG" \
    | grep -q '"spectrum"' || fail "经前端代理调用 /api/generate 未返回预期数据"
  ok "/api 代理联通 (POST /api/generate 返回正常)"

  ok "冒烟检查全部通过, 自动停止服务"
}

# ---------- 入口 ----------
cmd="${1:-all}"
case "$cmd" in
  all)
    STEP_TOTAL=5
    step_clean
    step_deps_backend
    step_deps_frontend
    step_build
    step_check
    ;;
  deps)
    STEP_TOTAL=2
    step_deps_backend
    step_deps_frontend
    ;;
  build)  step_build ;;
  check)  step_check ;;
  clean)
    step_clean
    ;;
  distclean)
    step_clean
    warn "删除依赖目录: node_modules, backend/.venv (缓存下次重装)"
    rm -rf "$FRONTEND_DIR/node_modules" "$VENV_DIR"
    ok "distclean 完成"
    ;;
  *)
    err "未知命令: $cmd (可用: all|deps|build|check|clean|distclean)"
    exit 2
    ;;
esac

printf '\n%s[ DONE ]%s 流水线「%s」全部通过\n' "$C_GREEN" "$C_RESET" "$cmd"
