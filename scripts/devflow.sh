#!/usr/bin/env bash
# devflow.sh — 可重复执行的本地开发流水线：依赖安装 → 构建 → 启动 → 端到端检查
#
# 用法:
#   ./scripts/devflow.sh [all|deps|build|start|verify|stop|clean|distclean]
#
# 设计约定:
#   - 依赖缓存保留复用: .venv / node_modules / npm 缓存 / pip 缓存 一律不删除
#     (distclean 才会连依赖一起清掉)
#   - 每一步都有编号、名称、耗时; 失败时打印步骤名、退出码/超时、日志末尾, 直接能看出卡在哪
#   - 每次重跑先清理上次的中间产物: 旧进程、dist/、__pycache__、旧日志、pid 文件
#   - 幂等: 重复执行、关掉终端再打开、换机器, 行为一致
#
# 可用环境变量(默认值如下):
#   BACKEND_PORT=8000  FRONTEND_PORT=3000
#   DEPS_TIMEOUT=900   BUILD_TIMEOUT=300   START_TIMEOUT=60   (单位: 秒)
#   VERBOSE=1  实时输出每步日志(默认静默, 失败时才打印日志末尾)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DIR="$ROOT/backend"
FRONTEND_DIR="$ROOT/frontend"
VENV="$BACKEND_DIR/.venv"
RUN_DIR="$ROOT/.run"
LOG_DIR="$RUN_DIR/logs"

BACKEND_PORT="${BACKEND_PORT:-8000}"
FRONTEND_PORT="${FRONTEND_PORT:-3000}"
DEPS_TIMEOUT="${DEPS_TIMEOUT:-900}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-300}"
START_TIMEOUT="${START_TIMEOUT:-60}"
VERBOSE="${VERBOSE:-0}"

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_RED=; C_GRN=; C_BLU=; C_DIM=; C_RST=
fi

ok()   { printf '%s✔%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s!%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }

STEP_NO=0
TOTAL_STEPS=0

# run_step <显示名> <超时秒> <步骤函数>
run_step() {
  local name="$1" timeout_s="$2" fn="$3"
  local log="$LOG_DIR/step-${fn#step_}.log"
  STEP_NO=$((STEP_NO + 1))
  printf '\n%s==>%s [%d/%d] %s\n' "$C_BLU" "$C_RST" "$STEP_NO" "$TOTAL_STEPS" "$name"
  : > "$log"

  local start=$SECONDS rc=0
  if [[ "$VERBOSE" == "1" ]]; then
    timeout "$timeout_s" "$0" __step__ "$fn" 2>&1 | tee -a "$log"
    rc=${PIPESTATUS[0]}
  else
    timeout "$timeout_s" "$0" __step__ "$fn" >>"$log" 2>&1
    rc=$?
  fi
  local dur=$((SECONDS - start))

  if [[ $rc -eq 0 ]]; then
    ok "[$STEP_NO/$TOTAL_STEPS] $name (${dur}s)"
    return 0
  fi

  # ---- 失败报告: 哪一步、什么原因、看哪个日志 ----
  warn "步骤失败: [$STEP_NO/$TOTAL_STEPS] $name"
  if [[ $rc -eq 124 ]]; then
    warn "原因: 超过 ${timeout_s}s 时限被杀 (可用环境变量调大, 如 BUILD_TIMEOUT=600)"
  else
    warn "退出码: $rc"
  fi
  warn "完整日志: $log"
  printf '%s--- 日志末尾 ---%s\n' "$C_DIM" "$C_RST" >&2
  tail -n 25 "$log" >&2
  printf '%s----------------%s\n' "$C_DIM" "$C_RST" >&2
  warn "修复后直接重跑同一命令即可, 上次的中断产物会自动清理"
  exit "$rc"
}

# ---------------- 进程/端口工具 ----------------

# stop_pidfile <pid文件> <进程特征>: 只杀匹配的进程, 避免 pid 复用误杀
stop_pidfile() {
  local f="$RUN_DIR/$1" pat="$2" p
  [[ -f $f ]] || return 0
  p=$(cat "$f" 2>/dev/null || true)
  if [[ -n ${p:-} && -d /proc/$p ]] && tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q "$pat"; then
    kill "$p" 2>/dev/null || true
    for _ in $(seq 1 15); do [[ -d /proc/$p ]] || break; sleep 0.2; done
    [[ -d /proc/$p ]] && kill -9 "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
  fi
  rm -f "$f"
}

ensure_port_free() { # <端口> <服务名>
  local port="$1"
  # 用 bash 内建的 /dev/tcp 探测, 不依赖 ss/lsof(最小化环境里可能没有)
  if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    echo "端口 $port ($2) 已被占用" >&2
    if command -v ss >/dev/null 2>&1; then
      ss -tlnpH "sport = :$port" 2>/dev/null | sed 's/^/    /' >&2
    elif command -v lsof >/dev/null 2>&1; then
      lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | sed 's/^/    /' >&2
    fi
    echo "提示: 若是上次残留, 执行 scripts/devflow.sh stop; 否则释放端口或用环境变量换端口" >&2
    return 1
  fi
}

# wait_ready <url> <pid文件> <服务日志>: 在 START_TIMEOUT 内等 HTTP 就绪, 进程提前死则立刻失败
wait_ready() {
  local url="$1" pidfile="$2" server_log="$3" deadline=$((SECONDS + START_TIMEOUT))
  while (( SECONDS < deadline )); do
    if curl -fsS -o /dev/null --max-time 2 "$url" 2>/dev/null; then return 0; fi
    local p; p=$(cat "$pidfile" 2>/dev/null || true)
    if [[ -n ${p:-} && ! -d /proc/$p ]]; then
      echo "服务进程已退出, 服务日志末尾:" >&2
      tail -n 30 "$server_log" >&2
      return 1
    fi
    sleep 0.5
  done
  echo "等待 ${START_TIMEOUT}s 后服务仍未就绪, 服务日志末尾:" >&2
  tail -n 30 "$server_log" >&2
  return 1
}

# ---------------- 清理 ----------------

# 清理上次运行的中间产物(不动依赖缓存)
clean_runtime() {
  stop_pidfile backend.pid uvicorn
  stop_pidfile frontend.pid vite
  rm -rf "$FRONTEND_DIR/dist"
  find "$BACKEND_DIR/app" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null
  rm -rf "$LOG_DIR"
  mkdir -p "$LOG_DIR"
}

# ---------------- 步骤定义 ----------------

step_deps_backend() {
  if ! [[ -x "$VENV/bin/python" ]] || ! "$VENV/bin/python" -c 'import sys' 2>/dev/null; then
    echo ".venv 缺失或已失效(例如在别的系统上创建), 重新创建..."
    rm -rf "$VENV" 2>/dev/null || { sleep 1; rm -rf "$VENV"; }
    if ! python3 -m venv "$VENV" 2>/dev/null; then
      echo "系统 Python 无 ensurepip, 改用 --without-pip 创建后引导 pip..."
      rm -rf "$VENV" 2>/dev/null || { sleep 1; rm -rf "$VENV"; }
      python3 -m venv --without-pip "$VENV"
    fi
  fi
  if ! "$VENV/bin/python" -m pip --version >/dev/null 2>&1; then
    echo "venv 内缺少 pip, 通过 get-pip.py 引导..."
    curl -fsSL --max-time 60 https://bootstrap.pypa.io/get-pip.py -o "$RUN_DIR/get-pip.py"
    "$VENV/bin/python" "$RUN_DIR/get-pip.py" -q
    rm -f "$RUN_DIR/get-pip.py"
  fi
  echo "Python: $("$VENV/bin/python" --version 2>&1)"
  # pip 缓存默认保留在 ~/.cache/pip, 重复安装直接命中
  "$VENV/bin/python" -m pip install --disable-pip-version-check -q -r "$BACKEND_DIR/requirements.txt"
  "$VENV/bin/python" -c 'import fastapi, uvicorn, numpy, multipart; print("依赖导入自检通过")'
}

step_deps_frontend() {
  cd "$FRONTEND_DIR"
  # npm 缓存默认保留在 ~/.npm; node_modules 已就绪时此处近乎秒过
  npm install --no-audit --no-fund
  [[ -x node_modules/.bin/vite ]] || { echo "vite 未正确安装" >&2; return 1; }
  echo "Node: $(node --version), Vite: $(node_modules/.bin/vite --version)"
}

step_build_backend() {
  find "$BACKEND_DIR/app" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
  "$VENV/bin/python" -m compileall -q "$BACKEND_DIR/app"
  (cd "$BACKEND_DIR" && "$VENV/bin/python" -c 'from app.main import app; print("后端导入检查通过:", app.title)')
}

step_build_frontend() {
  rm -rf "$FRONTEND_DIR/dist"   # 先清掉上次构建产物
  cd "$FRONTEND_DIR"
  npm run build
  [[ -f dist/index.html ]] || { echo "构建产物 dist/index.html 缺失" >&2; return 1; }
  echo "构建产物: $(du -sh dist | cut -f1) (dist/)"
}

step_start_backend() {
  stop_pidfile backend.pid uvicorn
  ensure_port_free "$BACKEND_PORT" "后端"
  local log="$LOG_DIR/backend.log"; : > "$log"
  # 单独的简单后台命令, 保证 $! 就是服务进程本身(不能和 cd 用 && 串成列表, 否则 $! 是包装子壳)
  ( cd "$BACKEND_DIR" || exit 1
    nohup "$VENV/bin/uvicorn" app.main:app --host 127.0.0.1 --port "$BACKEND_PORT" >>"$log" 2>&1 &
    echo $! > "$RUN_DIR/backend.pid" )
  wait_ready "http://127.0.0.1:$BACKEND_PORT/openapi.json" "$RUN_DIR/backend.pid" "$log"
  ok "后端已就绪: http://127.0.0.1:$BACKEND_PORT (文档 /docs)"
}

step_start_frontend() {
  stop_pidfile frontend.pid vite
  ensure_port_free "$FRONTEND_PORT" "前端"
  local log="$LOG_DIR/frontend.log"; : > "$log"
  ( cd "$FRONTEND_DIR" || exit 1
    nohup node_modules/.bin/vite --host 127.0.0.1 --port "$FRONTEND_PORT" --strictPort >>"$log" 2>&1 &
    echo $! > "$RUN_DIR/frontend.pid" )
  wait_ready "http://127.0.0.1:$FRONTEND_PORT/" "$RUN_DIR/frontend.pid" "$log"
  ok "前端已就绪: http://127.0.0.1:$FRONTEND_PORT"
}

step_verify() {
  local page
  page=$(curl -fsS --max-time 5 "http://127.0.0.1:$FRONTEND_PORT/") \
    || { echo "前端页面打不开: http://127.0.0.1:$FRONTEND_PORT/" >&2; return 1; }
  grep -q 'id="app"' <<<"$page" || { echo "前端页面内容异常(缺少 #app 挂载点)" >&2; return 1; }
  echo "页面检查通过 (含 #app 挂载点)"

  local resp
  resp=$(curl -fsS --max-time 10 -X POST "http://127.0.0.1:$FRONTEND_PORT/api/generate" \
    -H 'Content-Type: application/json' \
    -d '{"modulation":"QPSK","samples":256,"snr":20}') \
    || { echo "经前端代理调用后端 API 失败" >&2; return 1; }
  grep -q '"spectrum"' <<<"$resp" || { echo "API 响应异常: ${resp:0:200}" >&2; return 1; }
  echo "端到端检查通过 (前端页面 → 代理 → 后端 /api/generate)"
}

# 供 run_step 以子进程方式执行步骤函数(这样 timeout 才能管住 shell 函数)
# set -e: 步骤内任何命令失败立即终止该步骤, 保证失败一定反映为步骤失败
if [[ ${1:-} == __step__ ]]; then
  shift
  set -e
  mkdir -p "$LOG_DIR"
  "$@"
  exit $?
fi

# ---------------- 命令入口 ----------------

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

command -v timeout >/dev/null || { warn "缺少 timeout 命令(coreutils)"; exit 1; }
command -v curl    >/dev/null || { warn "缺少 curl 命令"; exit 1; }

cmd="${1:-all}"
case "$cmd" in
  all)
    clean_runtime
    TOTAL_STEPS=7
    run_step "依赖安装 · 后端 (pip)"            "$DEPS_TIMEOUT"  step_deps_backend
    run_step "依赖安装 · 前端 (npm)"            "$DEPS_TIMEOUT"  step_deps_frontend
    run_step "构建 · 后端 (编译+导入检查)"       "$BUILD_TIMEOUT" step_build_backend
    run_step "构建 · 前端 (vue-tsc + vite)"     "$BUILD_TIMEOUT" step_build_frontend
    run_step "启动 · 后端 uvicorn:$BACKEND_PORT"  "$START_TIMEOUT" step_start_backend
    run_step "启动 · 前端 vite:$FRONTEND_PORT"    "$START_TIMEOUT" step_start_frontend
    run_step "端到端检查 (页面+API)"            "$START_TIMEOUT" step_verify
    printf '\n%s✔ 全部通过%s\n' "$C_GRN" "$C_RST"
    echo "  前端页面:  http://127.0.0.1:$FRONTEND_PORT/"
    echo "  后端 API:  http://127.0.0.1:$BACKEND_PORT/docs"
    echo "  服务日志:  .run/logs/{backend,frontend}.log"
    echo "  停止服务:  scripts/devflow.sh stop"
    ;;
  deps)
    mkdir -p "$LOG_DIR"; TOTAL_STEPS=2
    run_step "依赖安装 · 后端 (pip)" "$DEPS_TIMEOUT" step_deps_backend
    run_step "依赖安装 · 前端 (npm)" "$DEPS_TIMEOUT" step_deps_frontend
    ;;
  build)
    mkdir -p "$LOG_DIR"; TOTAL_STEPS=2
    run_step "构建 · 后端 (编译+导入检查)"   "$BUILD_TIMEOUT" step_build_backend
    run_step "构建 · 前端 (vue-tsc + vite)" "$BUILD_TIMEOUT" step_build_frontend
    ;;
  start)
    mkdir -p "$LOG_DIR"; TOTAL_STEPS=3
    run_step "启动 · 后端 uvicorn:$BACKEND_PORT" "$START_TIMEOUT" step_start_backend
    run_step "启动 · 前端 vite:$FRONTEND_PORT"   "$START_TIMEOUT" step_start_frontend
    run_step "端到端检查 (页面+API)"           "$START_TIMEOUT" step_verify
    ;;
  verify)
    mkdir -p "$LOG_DIR"; TOTAL_STEPS=1
    run_step "端到端检查 (页面+API)" "$START_TIMEOUT" step_verify
    ;;
  stop)
    stop_pidfile backend.pid uvicorn
    stop_pidfile frontend.pid vite
    ok "已停止前后端服务"
    ;;
  clean)
    clean_runtime
    ok "已清理中间产物 (旧进程/dist/__pycache__/日志/pid); 依赖缓存 .venv、node_modules、npm/pip 缓存保留"
    ;;
  distclean)
    clean_runtime
    rm -rf "$VENV" "$FRONTEND_DIR/node_modules"
    ok "已连依赖一起清空 (下次需重新安装)"
    ;;
  *)
    usage
    ;;
esac
