# rooted-pixel

使用 KernelSU（或 Magisk）修补 **Pixel 出厂系统** OTA 镜像，支持 AVB 验证、锁定 Bootloader **和** Root 权限。
可通过 [Custota](https://github.com/chenxiaolong/Custota) 和自建 OTA 服务器进行无线升级。
支持通过 OTA 在 KernelSU root、Magisk root 和 rootless 之间切换。

> **⚠️ 推荐使用 KernelSU**（而非 Magisk），因为它兼容性更好、不易被检测。
> Magisk 的 Zygisk 在 AOSP 上支持良好，但 KernelSU 在内核层面提供 root，更难被检测。
> 参见[下方](#使用其他-root-方案)了解各方案的对比。

## 项目背景

本仓库是 [rooted-graphene](https://github.com/warpdotsys/rooted-graphene) 的改版，将 OTA 源从 GrapheneOS 替换为 Google Pixel 原厂系统。

核心流程一致：
1. 从 Google 服务器下载 Pixel 官方 OTA 镜像
2. 使用 [avbroot](https://github.com/chenxiaolong/avbroot) 修补 boot 分区注入 root
3. 使用自定义密钥签名（AVB + OTA）
4. 发布到 GitHub Release，同时向 GitHub Pages 上的 Custota OTA 服务器推送更新

## 支持的设备

参见本仓库的 [devices.json](devices.json) 和 [.github/workflows/release-multiple.yaml](.github/workflows/release-multiple.yaml)。

当前支持的主流 Pixel 设备：

| 设备 | 代号 | Android | KMI | Magisk preinit |
|------|------|---------|-----|----------------|
| Pixel 9 | tokay | 15+ | android15-6.6 | sda10 |
| Pixel 9 Pro | caiman | 15+ | android15-6.6 | sda10 |
| Pixel 9 Pro XL | komodo | 15+ | android15-6.6 | sda10 |
| Pixel 9 Pro Fold | comet | 15+ | android15-6.6 | sda10 |
| Pixel 8 | shiba | 14+ | android14-6.1 | sda10 |
| Pixel 8 Pro | husky | 14+ | android14-6.1 | sda10 |
| Pixel 8a | akita | 14+ | android14-6.1 | sda10 |
| Pixel Fold | felix | 14+ | android14-6.1 | sda10 |
| Pixel Tablet | tangorpro | 14+ | android14-6.1 | sda10 |
| Pixel 7 | panther | 13+ | android13-5.15 | metadata |
| Pixel 7 Pro | cheetah | 13+ | android13-5.15 | metadata |
| Pixel 7a | lynx | 13+ | android13-5.15 | metadata |
| Pixel 6 | oriole | 12+ | android12-5.10 | metadata |
| Pixel 6 Pro | raven | 12+ | android12-5.10 | metadata |
| Pixel 6a | bluejay | 12+ | android12-5.10 | metadata |

如果这个项目对你有帮助，请考虑 **[向原作者 chenxiaolong 捐赠](https://github.com/sponsors/chenxiaolong)**（avbroot、Custota）。

## 与 rooted-graphene 的主要区别

| 特性 | rooted-graphene | rooted-pixel |
|------|----------------|-------------|
| OTA 源 | GrapheneOS 服务器 | Google Pixel 官方服务器 |
| 版本格式 | 日期版 (2025021100) | Build ID (AP4A.250205.002) |
| 版本检测 | API: releases.grapheneos.org/\{device\}-\{channel\} | 仓库维护的 devices.json + 自动抓取 |
| OEMUnlockOnBoot | 内置（GrapheneOS 需要重锁） | 不需要（Pixel 出厂无此机制） |
| 安全预览频道 | 支持 (stable-security-preview) | Google 无此概念，始终为稳定版 |
| 设备范围 | GrapheneOS 支持的设备 | Google Pixel 设备 |

## 重要说明

### OTA URL 机制

Pixel 出厂 OTA 镜像的 URL 包含一个 8 位 SHA 哈希（如 `shiba-ota-AP4A.250205.002-a1b2c3d4.zip`），
与 factory image（无 SHA，`shiba-factory-AP4A.250205.002.zip`）不同。

本仓库通过以下方式获取 OTA URL：

- **devices.json**: 维护已知的 device → build_id → SHA 映射
- **自动抓取脚本**: `scripts/fetch_latest_ota.py` 使用 Playwright 从 Google 开发者页面抓取最新 OTA 链接
- **CI 自动更新**: 每周运行 update-devices workflow 更新 devices.json
- **手动指定**: 可通过 `OTA_VERSION` 和 `OTA_SHA` 环境变量手动指定

### OTA 频道

Google 每月第一个周一发布 Pixel 安全更新。本仓库在发布后数小时内自动检测并构建。

## 首次安装系统

### 准备工作

1. 确保你的 Pixel 设备 bootloader 已解锁
2. 备份所有数据（首次刷机会清除数据）
3. 下载对应机型的 **原版** factory image 或 OTA 文件

### 刷写 custom OTA

1. 从 [Releases 页面](https://github.com/warpdotsys/rooted-pixel/releases) 下载与当前系统版本一致的修补 OTA
2. 获取最新的 [platform-tools (ADB/Fastboot)](https://developer.android.com/tools/releases/platform-tools)
3. 解锁 bootloader：
   ```bash
   adb reboot bootloader
   fastboot flashing unlock
   ```
4. 刷入修补后的 OTA（通过 Recovery）：
   ```bash
   # 重启到 recovery
   fastboot reboot recovery
   # 选择 "Apply update from ADB"
   adb sideload rooted-pixel-ota-xxx.zip
   ```
5. 设置自定义 AVB 密钥：
   ```bash
   fastboot reboot-bootloader
   fastboot erase avb_custom_key
   fastboot flash avb_custom_key avb_pkmd.bin
   ```
6. 锁定 bootloader（会清除数据）：
   ```bash
   fastboot flashing lock
   ```
7. 重启设备

### 设置 OTA 更新

1. 从设置 → 应用 → 查看所有应用 →（三点菜单）→ 显示系统
2. 找到 "System Updater" 应用，禁用或阻止其网络访问
3. 打开 Custota 应用，设置 OTA 服务器地址：
   - KernelSU: `https://warpdotsys.github.io/rooted-pixel/kernelsu`
   - Magisk: `https://warpdotsys.github.io/rooted-pixel/magisk`
   - Rootless: `https://warpdotsys.github.io/rooted-pixel/rootless`

### 在 root 和 rootless 之间切换

在 Custota 应用中修改 URL 后升级即可。
如果 Custota 提示已是最新版本，长按 `Version` 选择 `Allow reinstall` 强制升级。

| 效果 | Custota URL |
|------|------------|
| **KernelSU root（推荐）** | https://warpdotsys.github.io/rooted-pixel/kernelsu |
| Magisk root | https://warpdotsys.github.io/rooted-pixel/magisk |
| 无 root | https://warpdotsys.github.io/rooted-pixel/rootless |

## 自行搭建 OTA 构建

### 生成密钥

```bash
bash -c 'source rooted-ota.sh && generateKeys'
```

生成的密钥位于 `keys/` 目录，**请安全保管！**

### 本地构建

```bash
# 安装依赖
sudo apt install docker.io git jq curl unzip

# 交互式构建
export PASSPHRASE_AVB=1
export PASSPHRASE_OTA=1
DEVICE_ID=tokay \
KSU_VERSION=v3.2.4 \
MAGISK_PREINIT_DEVICE=sda10 \
bash -c '. rooted-ota.sh && createRootedOta'

# 指定特定版本
DEVICE_ID=tokay \
OTA_VERSION=AP4A.250205.002 \
KSU_VERSION=v3.2.4 \
MAGISK_PREINIT_DEVICE=sda10 \
bash -c '. rooted-ota.sh && createRootedOta'
```

### GitHub Actions 自动构建

1. Fork 本仓库
2. 在仓库 Settings → Secrets and variables → Actions 中设置：
   - `KEY_AVB_BASE64` — AVB 签名密钥（base64 编码）
   - `KEY_OTA_BASE64` — OTA 签名密钥（base64 编码）
   - `CERT_OTA_BASE64` — OTA 证书（base64 编码）
   - `PASSPHRASE_AVB` — AVB 密钥密码
   - `PASSPHRASE_OTA` — OTA 密钥密码
3. 启用 GitHub Pages：Settings → Pages → 选择 `gh-pages` 分支
4. 在 `.github/workflows/release-multiple.yaml` 中添加/修改你的设备

### 密钥 base64 编码

```bash
# 编码密钥
base64 -w0 keys/avb.key   # → KEY_AVB_BASE64
base64 -w0 keys/ota.key   # → KEY_OTA_BASE64
base64 -w0 keys/ota.crt   # → CERT_OTA_BASE64
```

### 更新设备数据库

```bash
# 手动运行抓取脚本
pip install playwright beautifulsoup4 lxml
playwright install chromium
python scripts/fetch_latest_ota.py --output devices.json
```

## 脚本用法

```bash
# 创建修补后的 OTA
source rooted-ota.sh && createRootedOta

# 创建并发布到 GitHub Release
GITHUB_TOKEN=ghp_xxx \
GITHUB_REPO=yourname/rooted-pixel \
DEVICE_ID=tokay \
KSU_VERSION=v3.2.4 \
MAGISK_PREINIT_DEVICE=sda10 \
bash -c '. rooted-ota.sh && createAndReleaseRootedOta'

# 仅测试修补（跳过下载）
SKIP_CLEANUP=true \
DEVICE_ID=tokay \
KSU_VERSION=v3.2.4 \
MAGISK_PREINIT_DEVICE=sda10 \
bash -c '. rooted-ota.sh && createRootedOta'
```

### 环境变量参考

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `DEVICE_ID` | 设备代号（必填） | — |
| `OTA_VERSION` | 构建 ID 或 latest | latest |
| `KSU_VERSION` | KernelSU 版本 | ''（禁用） |
| `KSU_KMI` | KernelSU KMI，留空自动检测 | '' |
| `MAGISK_PREINIT_DEVICE` | Magisk preinit 分区 | '' |
| `MAGISK_VERSION` | Magisk 版本 | auto |
| `UPLOAD_TEST_OTA` | 上传到 test 目录 | false |
| `SKIP_ROOTLESS` | 跳过 rootless 构建 | false |
| `SKIP_MODULES` | 跳过模块注入 | false |
| `SKIP_OTA_SERVER_UPLOAD` | 跳过 OTA 服务器更新 | false |
| `FORCE_BUILD` | 强制重新构建 | false |

## Magisk preinit 参数

如何确定 `MAGISK_PREINIT_DEVICE`：

1. 从 factory image 或 OTA 中提取 boot.img：
   ```bash
   avbroot ota extract \
     --input /path/to/ota.zip \
     --directory . \
     --boot-only
   ```
2. 安装 Magisk，修补 boot.img，在输出中找到：
   `Pre-init storage partition device ID: <name>`
3. 或从修补后的 boot.img 中提取：
   ```bash
   avbroot boot magisk-info \
     --image magisk_patched-*.img
   ```

| Pixel 系列 | Preinit 分区 |
|------------|-------------|
| Pixel 6/7/7a | metadata |
| Pixel 8/8 Pro/8a | sda10 |
| Pixel 9/9 Pro/9 Pro XL | sda10 |
| Pixel Fold | sda10 |
| Pixel Tablet | sda10 |

## 使用其他 Root 方案

### KernelSU（推荐）

KernelSU 在内核层面实现 root，优势：
- 兼容性好，更难被检测
- 支持非 GKI 设备的内核模块
- OTA 升级后 root 保持（内核模块自动重编）

构建 KernelSU OTA：

```bash
DEVICE_ID=tokay \
KSU_VERSION=v3.2.4 \
KSU_KMI=android15-6.6 \
MAGISK_PREINIT_DEVICE=sda10 \
bash -c '. rooted-ota.sh && createRootedOta'
```

设置 `KSU_ALLOW_SHELL=false` 可禁用 shell root 访问。

### Magisk

Magisk 在 userspace 实现 root，Zygisk 支持良好。

```bash
DEVICE_ID=tokay \
MAGISK_PREINIT_DEVICE=sda10 \
bash -c '. rooted-ota.sh && createRootedOta'
```

## 开发

```bash
# 交互式调试
DEBUG=1 bash --init-file rooted-ota.sh

# 测试密钥加载
PASSPHRASE_AVB=1 PASSPHRASE_OTA=1 bash -c '. rooted-ota.sh && key2base64'

# 避免重复下载 OTA
mkdir -p .tmp && ln -s /path/to/tokay-ota-xxx.zip .tmp/tokay-ota-xxx.zip

# 端到端测试
GITHUB_TOKEN=ghp_xxx \
GITHUB_REPO=yourname/rooted-pixel \
DEVICE_ID=tokay \
KSU_VERSION=v3.2.4 \
MAGISK_PREINIT_DEVICE=sda10 \
SKIP_CLEANUP=true \
bash -c '. rooted-ota.sh && createAndReleaseRootedOta'
```

## 参考与致谢

- [rooted-graphene](https://github.com/warpdotsys/rooted-graphene) — 本项目的前身与灵感来源
- [avbroot](https://github.com/chenxiaolong/avbroot) — OTA 修补与签名工具
- [Custota](https://github.com/chenxiaolong/Custota) — OTA 更新客户端
- [KernelSU](https://kernelsu.org/) — 内核级 Root 方案
- [Magisk](https://github.com/topjohnwu/Magisk) — Userspace Root 方案
- Google [Factory Images](https://developers.google.com/android/images) / [OTA Images](https://developers.google.com/android/ota) — Pixel 出厂镜像下载

## License

Apache 2.0 — 参见 [LICENSE](LICENSE)
