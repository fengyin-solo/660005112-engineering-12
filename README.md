# 射频信号频谱分析与调制识别仪

基于Vue 3 + FastAPI的射频信号分析工具，支持IQ数据导入、FFT频谱/瀑布图/星座图三面板可视化、自动调制分类识别。

## 目标用户
业余无线电爱好者、信号工程师、通信专业学生

## 技术栈
- 前端: Vue 3 + TypeScript + Vite + Pinia + Element Plus + ECharts
- 后端: Python FastAPI + NumPy + SciPy

## 核心功能
1. IQ基带数据CSV文件导入，支持采样率/中心频率参数配置
2. FFT频谱图(ECharts)、瀑布图(Canvas)与星座图(Canvas)三面板同步
3. AM/FM/BPSK/QPSK/16QAM五种调制模式自动识别分类
4. 信号参数估算(符号速率、载波频率偏移)
5. 频谱分析结果JSON/PNG导出

## 本地开发一键流程

```bash
make dev        # 或 ./scripts/dev-pipeline.sh
```

一条命令串起：**清理上次残留 → 装依赖 → 前端构建 → 启动前后端并冒烟检查**（后端 `/api/health`、前端页面、`/api` 代理联通），检查完自动停掉服务。

- **失败定位**：每步带编号和计时；任何一步失败或超时，会直接指出卡在哪一步并打印该步日志末尾，完整日志在 `.dev/logs/`
- **缓存复用**：`node_modules`、`.venv`、`~/.npm`、`~/.cache/pip` 全部保留，重跑时依赖秒级校验
- **重跑干净**：每次运行自动清理上次的 `dist`、日志、pid 文件和残留进程；`.venv` 损坏（如从别的机器拷贝）会自动重建
- **环境一致**：`frontend/package-lock.json` 已纳入版本管理，新终端/重启/新克隆后都是同一条 `make dev`

常用子命令：

| 命令 | 作用 |
| --- | --- |
| `make deps` | 只安装/校验前后端依赖 |
| `make build` | 只构建前端（vue-tsc + vite build，带超时） |
| `make check` | 只启动前后端做冒烟检查 |
| `make clean` | 清理中间产物，保留依赖缓存 |
| `make distclean` | 连 `node_modules`/`.venv` 一起删，从零重装 |

可调环境变量（秒）：`BACKEND_PORT`(8000) `FRONTEND_PORT`(3000) `DEPS_TIMEOUT`(600) `BUILD_TIMEOUT`(300) `STARTUP_TIMEOUT`(60)