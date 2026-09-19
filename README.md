# 射频信号频谱分析与调制识别仪

基于Vue 3 + FastAPI的射频信号分析工具，支持IQ数据导入、FFT频谱/瀑布图/星座图三面板可视化、自动调制分类识别。

## 目标用户
业余无线电爱好者、信号工程师、通信专业学生

## 技术栈
- 前端: Vue 3 + TypeScript + Vite + Pinia + Element Plus + ECharts
- 后端: Python FastAPI + NumPy + SciPy

## 本地开发流程（可重复执行）

一条命令完成 依赖安装 → 构建 → 启动 → 页面/API 检查：

```bash
make all        # 或 scripts/devflow.sh all
```

- **缓存复用**：`.venv`、`node_modules`、npm/pip 缓存都会保留，重跑只装缺的部分
- **失败定位**：每步有编号和名称，失败/超时（默认构建 300s）会打印步骤名、退出码和日志末尾，完整日志在 `.run/logs/`
- **重跑无残留**：每次运行先清掉上次的旧进程、`dist/`、`__pycache__`、旧日志和 pid 文件
- **环境失效自愈**：`.venv` 在别的系统上创建导致不可用时，自动重建

常用命令：`make deps`（只装依赖）、`make build`、`make start`、`make verify`（页面+API 检查）、`make stop`、`make clean`、`make distclean`（连依赖一起清）。

可调环境变量：`BACKEND_PORT`/`FRONTEND_PORT`（默认 8000/3000）、`DEPS_TIMEOUT`/`BUILD_TIMEOUT`/`START_TIMEOUT`（秒）、`VERBOSE=1`（实时输出日志）。

## 核心功能
1. IQ基带数据CSV文件导入，支持采样率/中心频率参数配置
2. FFT频谱图(ECharts)、瀑布图(Canvas)与星座图(Canvas)三面板同步
3. AM/FM/BPSK/QPSK/16QAM五种调制模式自动识别分类
4. 信号参数估算(符号速率、载波频率偏移)
5. 频谱分析结果JSON/PNG导出