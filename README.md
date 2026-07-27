[![Build static aMule binaries (release)](https://github.com/m3r3nix/amule-static-binary/actions/workflows/release.yml/badge.svg)](https://github.com/m3r3nix/amule-static-binary/actions/workflows/release.yml)
# Static aMule Binaries

本仓库提供完全静态编译的 aMule 二进制文件，源码来自 [amule-project/amule](https://github.com/amule-project/amule)。

目标是提供便携的 Linux 二进制文件，可在大多数发行版上直接运行，无需手动编译 aMule 或安装运行时库依赖。

## 什么是静态二进制？

完全静态的二进制文件将所需的库直接包含在可执行文件自身中。

这对于以下场景非常有用：

- 精简的 Linux 系统
- 容器环境
- NAS / 服务器环境
- 较旧的发行版
- 不方便从源码编译的系统
- 需要单个可移植可执行文件的部署场景

## 支持的平台

提供以下架构的预编译二进制文件：

- `amd64`
- `arm64`

## 二进制变体

每个发布版本可能包含多个 aMule 变体。

| 变体 | 说明 |
|---|---|
| `amuled-linux-{arch}` | aMule 守护进程（headless daemon） |
| `amulecmd-linux-{arch}` | aMule 命令行客户端 |
| `amuleweb-linux-{arch}` | aMule Web 服务器 |

### 构建内容

本构建脚本从源码编译以下内容，全部静态链接：

- **musl libc** — C 标准库
- **rpmalloc** — 现代堆内存分配器
- **zlib-ng** — 带优化的 zlib 替代品
- **LibreSSL** — OpenSSL 替代品
- **nghttp2** — HTTP/2 库
- **ncurses** — 终端处理库
- **c-ares** — 异步 DNS 解析器
- **curl** — HTTP/HTTPS 工具和库（libcurl）
- **Boost** — C++ 库集合（头文件）
- **Crypto++** — 加密库
- **libpng** — PNG 图像处理库
- **libgd** — GD 图形库（用于 C aMule Statistics）
- **pupnp** — 便携 UPnP 库
- **wxWidgets** — C++ 跨平台 GUI 库（仅 wxBase/wxNet，无 GUI）
- **aMule** — 主程序（amuled + amulecmd）

## 安装

1. 从最新的 [Release](https://github.com/m3r3nix/amule-static-binary/releases) 页面下载适合你架构的二进制文件。

2. 赋予可执行权限：
```sh
chmod +x amuled-linux-*
chmod +x amulecmd-linux-*
```

3. 将它们移动到 PATH 中：
```sh
sudo mv amuled-linux-* /usr/local/bin/amuled
sudo mv amulecmd-linux-* /usr/local/bin/amulecmd
```

4. 验证运行：
```sh
amuled --version
amulecmd --help
```

## 说明

这些二进制文件直接从上游 aMule 发布源码构建。

本仓库**不修改** aMule 功能。它仅自动化构建过程并发布静态 Linux 二进制文件。

有关 aMule 的使用、配置和上游文档，请参考原始项目：[amule-project/amule](https://github.com/amule-project/amule)
