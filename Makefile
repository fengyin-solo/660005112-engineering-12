.DEFAULT_GOAL := help
.PHONY: help dev deps build check clean distclean

PIPELINE := ./scripts/dev-pipeline.sh

help: ## 显示可用命令
	@echo "射频信号频谱分析仪 — 本地开发流程"
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  make %-10s %s\n", $$1, $$2}'
	@echo ""
	@echo "可调环境变量: BACKEND_PORT(8000) FRONTEND_PORT(3000) DEPS_TIMEOUT(600) BUILD_TIMEOUT(300) STARTUP_TIMEOUT(60)"

dev: ## 一键流水线: 清理 → 装依赖 → 构建 → 启动检查
	@$(PIPELINE) all

deps: ## 仅安装/校验前后端依赖 (复用缓存)
	@$(PIPELINE) deps

build: ## 仅构建前端 (带超时)
	@$(PIPELINE) build

check: ## 仅启动前后端做冒烟检查, 结束后自动停掉
	@$(PIPELINE) check

clean: ## 清理中间产物 (dist/日志/pid/残留进程), 保留依赖缓存
	@$(PIPELINE) clean

distclean: ## 深度清理: 连 node_modules/.venv 一起删
	@$(PIPELINE) distclean
