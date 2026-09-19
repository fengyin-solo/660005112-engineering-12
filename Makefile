# 本地开发统一入口: 依赖安装 → 构建 → 启动 → 端到端检查
# 实现都在 scripts/devflow.sh, 这里只是快捷方式, 保证每个人、每次打开环境做法一致

SCRIPT := ./scripts/devflow.sh

.PHONY: all deps build start verify stop clean distclean help

all: ## 完整流水线: 清理残留 → 装依赖 → 构建 → 启动 → 页面/API 检查
	@$(SCRIPT) all

deps: ## 只装依赖 (复用 .venv / node_modules / npm / pip 缓存)
	@$(SCRIPT) deps

build: ## 只构建 (后端编译+导入检查, 前端 vue-tsc + vite build)
	@$(SCRIPT) build

start: ## 只启动前后端并做端到端检查
	@$(SCRIPT) start

verify: ## 对已启动的服务做页面 + API 检查
	@$(SCRIPT) verify

stop: ## 停止前后端服务
	@$(SCRIPT) stop

clean: ## 清理中间产物 (旧进程/dist/__pycache__/日志), 保留依赖缓存
	@$(SCRIPT) clean

distclean: ## 连依赖一起清空, 下次从头安装
	@$(SCRIPT) distclean

help: ## 显示本帮助
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  make %-10s %s\n", $$1, $$2}'
