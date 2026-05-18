#!/usr/bin/env bash

# rooted-pixel — 使用 KernelSU (或 Magisk) 修补 Pixel 出厂 OTA 镜像，
# 支持 AVB 验证、锁定 Bootloader 和 Root 权限。
# 通过 Custota 和自建 OTA 服务器进行无线升级。
#
# 基于 rooted-graphene (https://github.com/warpdotsys/rooted-graphene) 修改
# Copyright 2024-2026 参见 LICENSE
# Workflow 位置: .github/workflows/release-single.yaml

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 依赖：git、jq、curl、docker、python3、unzip

# ============================================================
# 密钥配置
# ============================================================
KEY_AVB=${KEY_AVB:-avb.key}
KEY_OTA=${KEY_OTA:-ota.key}
CERT_OTA=${CERT_OTA:-ota.crt}
KEY_AVB_BASE64=${KEY_AVB_BASE64:-''}
KEY_OTA_BASE64=${KEY_OTA_BASE64:-''}
CERT_OTA_BASE64=${CERT_OTA_BASE64:-''}

# 密码（通过环境变量传入以支持非交互式）
# PASSPHRASE_AVB
# PASSPHRASE_OTA

DEBUG=${DEBUG:-''}
if [[ -n "${DEBUG}" ]]; then set -x; fi

# ============================================================
# 必填参数
# ============================================================
DEVICE_ID=${DEVICE_ID:-}           # Pixel 设备代号，如 shiba (Pixel 8)
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
GITHUB_REPO=${GITHUB_REPO:-''}

# ============================================================
# 可选参数
# ============================================================
MAGISK_PREINIT_DEVICE=${MAGISK_PREINIT_DEVICE:-}
SKIP_ROOTLESS=${SKIP_ROOTLESS:-'false'}
OTA_VERSION=${OTA_VERSION:-'latest'}   # 可指定 Build ID，如 AP4A.250205.002

MAGISK_VERSION=${MAGISK_VERSION:-auto} # renovate: datasource=github-releases packageName=topjohnwu/Magisk versioning=semver-coerced

SKIP_CLEANUP=${SKIP_CLEANUP:-''}
PAGES_REPO_FOLDER=${PAGES_REPO_FOLDER:-''}

FORCE_OTA_SERVER_UPLOAD=${FORCE_OTA_SERVER_UPLOAD:-'false'}
FORCE_BUILD=${FORCE_BUILD:-'false'}
SKIP_OTA_SERVER_UPLOAD=${SKIP_OTA_SERVER_UPLOAD:-'false'}
SKIP_MODULES=${SKIP_MODULES:-'false'}
UPLOAD_TEST_OTA=${UPLOAD_TEST_OTA:-false}

# KernelSU 支持
KSU_VERSION=${KSU_VERSION:-latest}   # 默认启用最新版 KernelSU
KSU_KMI=${KSU_KMI:-''}               # 留空则自动检测
KSU_ALLOW_SHELL=${KSU_ALLOW_SHELL:-'true'}
KERNELPATCH_VERSION=${KERNELPATCH_VERSION:-'0.13.1'}

NO_COLOR=${NO_COLOR:-''}

# 宽松检查：schedule 构建只匹配 OTA 版本（忽略 commit hash），workflow_dispatch 严格匹配
CHECK_LENIENT=${CHECK_LENIENT:-'false'}

# 全局变量
RELEASE_ID=''

# ============================================================
# Pixel 出厂 OTA 源
# ============================================================
# Pixel 出厂镜像托管在 Google 的 dl.google.com
OTA_BASE_URL="https://dl.google.com/dl/android/aosp"
# 设备数据库：维护设备代号到已知 OTA URL 的映射
DEVICES_JSON="${PROJECT_ROOT}/devices.json"

# 以下版本默认自动检测最新版，失败时回退到列出的版本号
AVB_ROOT_VERSION=${AVB_ROOT_VERSION:-auto}        # 回退: 3.29.1
CUSTOTA_VERSION=${CUSTOTA_VERSION:-auto}           # 回退: 5.22
PATCH_PY_COMMIT=${PATCH_PY_COMMIT:-auto}           # 回退: master 最新 commit
PYTHON_VERSION=${PYTHON_VERSION:-3.14.5-alpine}
OEMUNLOCKONBOOT_VERSION=${OEMUNLOCKONBOOT_VERSION:-auto}  # 回退: 1.3 (用于 GrapheneOS)
AFSR_VERSION=${AFSR_VERSION:-auto}                 # 回退: 1.0.4

CHENXIAOLONG_PK='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDOe6/tBnO7xZhAWXRj3ApUYgn+XZ0wnQiXM8B7tPgv4'
GIT_PUSH_RETRIES=10

set -o nounset -o pipefail -o errexit

# ============================================================
# 工具函数
# ============================================================

function fetchLatestGithubTag() {
  local repo="$1" fallback="$2"
  local tag
  tag=$(curl --fail -sL -I -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest" 2>/dev/null | sed 's/.*\/tag\/v\?//;')
  echo "${tag:-$fallback}"
}

function fetchLatestCommit() {
  local repo="$1" branch="${2:-master}" fallback="${3:-}"
  local sha
  sha=$(curl --fail -sL "https://api.github.com/repos/$repo/commits/$branch" 2>/dev/null | jq -r '.sha' 2>/dev/null)
  echo "${sha:-$fallback}"
}

function initToolCache() {
  if [ -d ".tool-cache" ] && [ "$(ls -A .tool-cache 2>/dev/null)" ]; then
    mkdir -p .tmp
    cp -r .tool-cache/* .tmp/
    print "从 .tool-cache 恢复了 $(ls .tool-cache | wc -l) 个工具"
  else
    print "工具缓存不存在，将在线下载"
  fi

  # 自动检测版本号（"auto" → 实际版本）
  [[ "$AVB_ROOT_VERSION" == "auto" ]] && AVB_ROOT_VERSION=$(fetchLatestGithubTag "chenxiaolong/avbroot" "3.29.1")
  [[ "$CUSTOTA_VERSION" == "auto" ]] && CUSTOTA_VERSION=$(fetchLatestGithubTag "chenxiaolong/Custota" "5.22")
  [[ "$AFSR_VERSION" == "auto" ]] && AFSR_VERSION=$(fetchLatestGithubTag "chenxiaolong/afsr" "1.0.4")
  [[ "$PATCH_PY_COMMIT" == "auto" ]] && PATCH_PY_COMMIT=$(fetchLatestCommit "chenxiaolong/my-avbroot-setup" "master" "84139189c8cbe244a676582a3b3517f31fabc421")
  print "已检测依赖版本: avbroot=$AVB_ROOT_VERSION Custota=$CUSTOTA_VERSION afsr=$AFSR_VERSION"
}

function saveToolCache() {
  if [ ! -d ".tmp" ]; then printRed "saveToolCache: .tmp 不存在"; return; fi
  mkdir -p .tool-cache
  local count=0
  local tools="avbroot magiskboot ksud ksud.version ksu_module.ko afsr custota-tool"
  for tool in $tools; do
    if [ -f ".tmp/$tool" ]; then
      cp ".tmp/$tool" ".tool-cache/$tool"
      count=$((count + 1))
    fi
  done
  if [ -n "$OTA_TARGET" ] && [ -f ".tmp/$OTA_TARGET.zip" ]; then
    rm -f ".tool-cache/${DEVICE_ID}-ota-"*.zip
    cp ".tmp/$OTA_TARGET.zip" ".tool-cache/$OTA_TARGET.zip"
    count=$((count + 1))
  fi
  if [ $count -gt 0 ]; then
    printGreen "已缓存 $count 个工具/文件到 .tool-cache"
  fi
}

function checkMandatoryVariable() {
  for var in "$@"; do
    if [ -z "${!var:-}" ]; then
      printRed "缺少必要变量：$var"
      exit 1
    fi
  done
}

function key2base64() {
  set +x
  for f in "$KEY_AVB" "$KEY_OTA" "$CERT_OTA"; do
    local var_name
    var_name="$(echo "$f" | tr '[:lower:]' '[:upper:]' | sed 's/\./_/')_BASE64"
    if [ -f "$f" ]; then
      export "$var_name"="$(base64 < "$f" | tr -d '\n')"
      printf "%s=%s\n" "$var_name" "${!var_name:0:20}..."
    else
      print "文件 $f 不存在，跳过 base64 编码"
    fi
  done
  if [[ -n "${DEBUG}" ]]; then set -x; fi
}

function createAssetSuffix() {
  local suffix=''
  if [[ "${SKIP_MODULES}" == 'true' ]]; then
    suffix+='-minimal'
  fi
  if [[ "${UPLOAD_TEST_OTA}" == 'true' ]]; then
    suffix+='-test'
  fi
  if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    suffix+='-dirty'
  fi
  echo "$suffix"
}

# ============================================================
# 直接抓取 Google OTA 页面（参照 auto_ota_manual_patch.sh）
# ============================================================

function fetchPixelOtaUrl() {
  local device="$1"
  local version_filter="${2:-}"
  local page_file=".tmp/ota_page.html"
  local ua="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

  # 确保临时目录存在（CI 中工具缓存为空时 .tmp 可能未创建）
  mkdir -p .tmp

  echo >&2 "$(date '+%Y-%m-%d %H:%M:%S'): 正在抓取 Google OTA 页面（device=$device, version=${version_filter:-latest}）..."

  # 不设 --fail：即使 Google 返回非 200（如 302/401）也下载页面内容。
  # --retry 增加网络容错性。
  curl -sL -H "Cookie: devsite_wall_acks=nexus-ota-tos" \
    -A "$ua" \
    --retry 3 --retry-delay 2 \
    -o "$page_file" \
    "https://developers.google.com/android/ota?hl=zh-cn" 2>/dev/null || {
    local rc=$?
    rm -f "$page_file"
    echo >&2 "$(date '+%Y-%m-%d %H:%M:%S'): curl 请求失败（exit code=$rc）"
    return 1
  }

  local page_size
  page_size=$(stat -c%s "$page_file" 2>/dev/null || echo 0)
  echo >&2 "$(date '+%Y-%m-%d %H:%M:%S'): OTA 页面已下载（${page_size} 字节）"

  local url=""
  if [ -n "$version_filter" ]; then
    local filter_lc
    filter_lc=$(echo "$version_filter" | tr '[:upper:]' '[:lower:]')
    url=$(grep -o "https://dl.google.com/dl/android/aosp/${device}-ota-${filter_lc}-[a-f0-9]*\.zip" "$page_file" 2>/dev/null | tail -1)
  fi
  if [ -z "$url" ]; then
    url=$(grep -o "https://dl.google.com/dl/android/aosp/${device}-ota-[a-zA-Z0-9.\-]*\.zip" "$page_file" 2>/dev/null | tail -1)
  fi

  rm -f "$page_file"

  if [ -n "$url" ]; then
    echo >&2 "$(date '+%Y-%m-%d %H:%M:%S'): 从 Google OTA 页面找到 URL: $(basename "$url")"
    echo "$url"
    return 0
  else
    echo >&2 "$(date '+%Y-%m-%d %H:%M:%S'): 在页面中未找到 ${device} 的 OTA 链接（可能被反爬或页面结构变更）"
    return 1
  fi
}

# ============================================================
# 版本检测：从 Google OTA 页面或 devices.json 获取 Pixel OTA URL
# ============================================================

function findLatestVersion() {
  checkMandatoryVariable DEVICE_ID

  # 解析 Magisk 版本
  if [[ "$MAGISK_VERSION" == 'latest' ]] || [[ "$MAGISK_VERSION" == 'auto' ]]; then
    MAGISK_VERSION=$(curl --fail -sL -I -o /dev/null -w '%{url_effective}' \
      https://github.com/topjohnwu/Magisk/releases/latest | sed 's/.*\/tag\///;')
  fi
  print "Magisk 版本: $MAGISK_VERSION"

  # --------------- Pixel OTA URL 获取 ---------------
  # 策略（参照 auto_ota_manual_patch.sh）：
  # 1. 直接抓取 Google OTA 页面（curl + TOS cookie）获取完整 OTA URL（含 SHA）
  # 2. 若失败，回退到 devices.json 构造 URL
  # 3. 若 devices.json 也无 SHA，尝试 factory image

  local scraped_url=""
  if [[ "$OTA_VERSION" == 'latest' ]]; then
    scraped_url=$(fetchPixelOtaUrl "$DEVICE_ID") || true
  else
    scraped_url=$(fetchPixelOtaUrl "$DEVICE_ID" "$OTA_VERSION") || true
  fi

  if [ -n "$scraped_url" ]; then
    OTA_URL="$scraped_url"
    OTA_TARGET=$(basename "$scraped_url" .zip)
    # 从 target 中提取 OTA_VERSION: {device}-ota-{version}-{sha}
    OTA_VERSION=$(echo "$OTA_TARGET" | sed 's/^[a-z0-9]*-ota-//; s/-[a-f0-9]\{8\}$//')
    printGreen "通过 Google OTA 页面获取到: $OTA_TARGET"
  else
    printYellow "直接抓取 Google OTA 页面失败，回退到 devices.json..."

    # --------------- OTA 版本检测 ---------------
    if [[ "$OTA_VERSION" == 'latest' ]]; then
      if [ -f "$DEVICES_JSON" ]; then
        OTA_VERSION=$(python3 -c "
import json, sys
with open('$DEVICES_JSON') as f:
    devices = json.load(f)
device = devices.get('$DEVICE_ID', {})
ver = device.get('latest_build', '')
if not ver:
    builds = device.get('builds', [])
    if builds:
        ver = builds[-1].get('build_id', '')
sys.stdout.write(ver)
" 2>/dev/null) || OTA_VERSION=""
      fi
    fi

    if [[ -z "$OTA_VERSION" ]]; then
      printRed "无法确定 $DEVICE_ID 的 OTA 版本。"
      printRed "请通过 OTA_VERSION 环境变量指定版本，如 OTA_VERSION=AP4A.250205.002"
      printRed "或在 devices.json 中配置该设备的版本信息。"
      exit 1
    fi

    # --------------- 构造 OTA URL ---------------
    local ota_sha=""
    if [ -f "$DEVICES_JSON" ]; then
      ota_sha=$(python3 -c "
import json
with open('$DEVICES_JSON') as f:
    devices = json.load(f)
builds = devices.get('$DEVICE_ID', {}).get('builds', [])
sha = ''
for b in builds:
    if b.get('build_id') == '$OTA_VERSION':
        sha = b.get('ota_sha', '')
        break
sys.stdout.write(sha)
" 2>/dev/null) || ota_sha=""
    fi

    if [[ -n "$ota_sha" ]]; then
      OTA_TARGET="${DEVICE_ID}-ota-${OTA_VERSION}-${ota_sha}"
      OTA_URL="${OTA_BASE_URL}/${OTA_TARGET}.zip"
    else
      printYellow "devices.json 中未找到 $DEVICE_ID-$OTA_VERSION 的 SHA，尝试 factory image..."
      OTA_TARGET="${DEVICE_ID}-factory-${OTA_VERSION}"
      OTA_URL="${OTA_BASE_URL}/${OTA_TARGET}.zip"
      printYellow "警告：将使用 factory image 而非 OTA zip。部分功能可能受限。"
    fi
  fi

  # --------------- Magisk preinit 自动检测 ---------------
  if [[ -z "$MAGISK_PREINIT_DEVICE" ]]; then
    print "MAGISK_PREINIT_DEVICE 未设置，将在 OTA 下载后从 boot.img 自动检测"
  fi

  print "设备: $DEVICE_ID"
  print "版本: $OTA_VERSION"
  print "目标: $OTA_TARGET"
  print "下载: $OTA_URL"
}

# ============================================================
# 依赖下载
# ============================================================

function downloadAndroidDependencies() {
  checkMandatoryVariable 'MAGISK_VERSION' 'OTA_TARGET'

  mkdir -p .tmp
  if ! ls ".tmp/magisk-$MAGISK_VERSION.apk" >/dev/null 2>&1 && \
     [[ "${POTENTIAL_ASSETS['magisk']+isset}" ]]; then
    curl --fail -sLo ".tmp/magisk-$MAGISK_VERSION.apk" \
      "https://github.com/topjohnwu/Magisk/releases/download/$MAGISK_VERSION/Magisk-$MAGISK_VERSION.apk"
  fi

  if ! ls ".tmp/$OTA_TARGET.zip" >/dev/null 2>&1; then
    if [[ -n "$PRESEED_OTA_DIR" ]] && [ -f "$PRESEED_OTA_DIR/$OTA_TARGET.zip" ]; then
      cp "$PRESEED_OTA_DIR/$OTA_TARGET.zip" ".tmp/$OTA_TARGET.zip"
      printGreen "从预置目录复制了 OTA: $PRESEED_OTA_DIR/$OTA_TARGET.zip"
    else
      print "正在下载 $OTA_URL ..."
      # dl.google.com 需要 TOS cookie，否则返回 "Sorry... automated queries"
      curl -4 -sL -H "Cookie: devsite_wall_acks=nexus-ota-tos" \
        -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
        --retry 3 --retry-delay 5 \
        -o ".tmp/$OTA_TARGET.zip" "$OTA_URL"
    fi
  fi
  if [ -f ".tmp/$OTA_TARGET.zip" ] && [ "$(stat -c%s ".tmp/$OTA_TARGET.zip")" -lt 10240 ]; then
    printRed "下载文件过小（可能是错误页面），删除重试"
    rm -f ".tmp/$OTA_TARGET.zip"
    if [[ -n "$PRESEED_OTA_DIR" ]] && [ -f "$PRESEED_OTA_DIR/$OTA_TARGET.zip" ]; then
      cp "$PRESEED_OTA_DIR/$OTA_TARGET.zip" ".tmp/$OTA_TARGET.zip"
      printGreen "从预置目录重新复制了 OTA: $PRESEED_OTA_DIR/$OTA_TARGET.zip"
    else
      curl -4 -sL -H "Cookie: devsite_wall_acks=nexus-ota-tos" \
        -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
        --retry 3 --retry-delay 5 \
        -o ".tmp/$OTA_TARGET.zip" "$OTA_URL"
    fi
  fi
}

function downloadAvBroot() {
  downloadAndVerifyFromChenxiaolong 'avbroot' "$AVB_ROOT_VERSION"
}

function downloadAndVerifyFromChenxiaolong() {
  local repo="$1" version="$2" artifact="${3:-$1}"
  local url="https://github.com/chenxiaolong/${repo}/releases/download/v${version}/${artifact}-${version}-x86_64-unknown-linux-gnu.zip"
  local downloadedZipFile
  downloadedZipFile="$(mktemp)"

  mkdir -p .tmp

  if ! ls ".tmp/${artifact}" >/dev/null 2>&1; then
    curl --fail -sL "${url}" > "${downloadedZipFile}"
    curl --fail -sL "${url}.sig" > "${downloadedZipFile}.sig"

    ssh-keygen -Y verify -I chenxiaolong -f <(echo "chenxiaolong $CHENXIAOLONG_PK") -n file \
      -s "${downloadedZipFile}.sig" < "${downloadedZipFile}"

    echo N | unzip "${downloadedZipFile}" -d .tmp
    rm "${downloadedZipFile}"*
    chmod +x ".tmp/${artifact}"
  fi
}

# ============================================================
# OTA 修补
# ============================================================

function patchOTAs() {
  downloadAvBroot
  downloadAndVerifyFromChenxiaolong 'afsr' "$AFSR_VERSION"

  if ! ls ".tmp/custota.zip" >/dev/null 2>&1; then
    curl --fail -sL "https://github.com/chenxiaolong/Custota/releases/download/v${CUSTOTA_VERSION}/Custota-${CUSTOTA_VERSION}-release.zip" > .tmp/custota.zip
    curl --fail -sL "https://github.com/chenxiaolong/Custota/releases/download/v${CUSTOTA_VERSION}/Custota-${CUSTOTA_VERSION}-release.zip.sig" > .tmp/custota.zip.sig
  fi

  # 注意：OEMUnlockOnBoot 是 GrapheneOS 特定的模块，在 Pixel 出厂系统上不需要
  # Pixel 出厂系统没有 GrapheneOS 的额外锁，所以跳过

  if ! ls ".tmp/my-avbroot-setup" >/dev/null 2>&1; then
    git clone https://github.com/chenxiaolong/my-avbroot-setup .tmp/my-avbroot-setup
    (cd .tmp/my-avbroot-setup && git checkout ${PATCH_PY_COMMIT})
  fi

  base642key

  # --------------- 从 boot.img 自动检测 KMI 和 Magisk preinit ---------------
  # 只要未显式设置 KSU_KMI 或 MAGISK_PREINIT_DEVICE，就从 OTA 提取 boot.img 检测
  if [[ -z "$KSU_KMI" ]] || [[ -z "$MAGISK_PREINIT_DEVICE" ]]; then
    local otaZip=".tmp/$OTA_TARGET.zip"
    if [ -f "$otaZip" ]; then
      downloadMagiskBoot
      print "正在从 OTA 提取 boot.img 以检测设备参数..."
      local detectDir=".tmp/preinit_detect"
      mkdir -p "$detectDir/boot_extracted"
      .tmp/avbroot ota extract \
        --input "$otaZip" \
        --directory "$detectDir/boot_extracted" \
        --boot-only 2>/dev/null || true
      local bootImg="$detectDir/boot_extracted/boot.img"
      if [ -f "$bootImg" ]; then
        DETECTED_KMI=""
        DETECTED_PREINIT=""
        detectDeviceParams "$bootImg"
        if [[ -z "$KSU_KMI" ]] && [[ -n "$DETECTED_KMI" ]]; then
          KSU_KMI="$DETECTED_KMI"
          printGreen "自动检测到 KSU_KMI: $KSU_KMI"
        fi
        if [[ -z "$MAGISK_PREINIT_DEVICE" ]] && [[ -n "$DETECTED_PREINIT" ]]; then
          MAGISK_PREINIT_DEVICE="$DETECTED_PREINIT"
          printGreen "自动检测到 MAGISK_PREINIT_DEVICE: $MAGISK_PREINIT_DEVICE"
        fi
      else
        printYellow "无法从 OTA 提取 boot.img，将尝试在后续步骤中检测"
      fi
      rm -rf "$detectDir"
    fi
  fi

  for flavor in "${!POTENTIAL_ASSETS[@]}"; do
    if [[ "$flavor" == 'ksu' ]]; then
      continue
    fi

    local targetFile=".tmp/${POTENTIAL_ASSETS[$flavor]}"

    if ls "$targetFile" >/dev/null 2>&1; then
      printGreen "文件 $targetFile 已存在本地，跳过修补。"
    else
      local args=()
      args+=("--output" "$targetFile")
      args+=("--input" ".tmp/$OTA_TARGET.zip")
      args+=("--sign-key-avb" "$KEY_AVB")
      args+=("--sign-key-ota" "$KEY_OTA")
      args+=("--sign-cert-ota" "$CERT_OTA")

      if [[ "$flavor" == 'magisk' ]]; then
        args+=("--patch-arg=--magisk" "--patch-arg" ".tmp/magisk-$MAGISK_VERSION.apk")
        if [[ -n "$MAGISK_PREINIT_DEVICE" ]]; then
          args+=("--patch-arg=--magisk-preinit-device" "--patch-arg" "$MAGISK_PREINIT_DEVICE")
        fi
      fi

      if [ -v PASSPHRASE_AVB ]; then
        args+=("--pass-avb-env-var" "PASSPHRASE_AVB")
      fi
      if [ -v PASSPHRASE_OTA ]; then
        args+=("--pass-ota-env-var" "PASSPHRASE_OTA")
      fi

      if [[ "${SKIP_MODULES}" != 'true' ]]; then
        args+=("--module-custota" ".tmp/custota.zip")
        # Pixel 出厂系统不需要 OEMUnlockOnBoot 模块
      fi
      args+=("--skip-custota-tool")

      local patch_image="rooted-ota-patch:latest"
      if docker image inspect "$patch_image" &>/dev/null; then
        # shellcheck disable=SC2046
        docker run --rm -i $(tty &>/dev/null && echo '-t') -v "$PWD:/app" -w /app \
          -e PATH='/bin:/usr/local/bin:/sbin:/usr/bin/:/app/.tmp' \
          --env-file <(env) \
          "$patch_image" sh -c \
            "python .tmp/my-avbroot-setup/patch.py ${args[*]} ; result=\$?; \
             chown -R $(id -u):$(id -g) .tmp; exit \$result"
      else
        print "预构建镜像 $patch_image 不存在，回退到 python:${PYTHON_VERSION}"
        # shellcheck disable=SC2046
        docker run --rm -i $(tty &>/dev/null && echo '-t') -v "$PWD:/app" -w /app \
          -e PATH='/bin:/usr/local/bin:/sbin:/usr/bin/:/app/.tmp' \
          --env-file <(env) \
          "python:${PYTHON_VERSION}" sh -c \
            "apk add openssh && \
             pip install -r .tmp/my-avbroot-setup/requirements.txt && \
             python .tmp/my-avbroot-setup/patch.py ${args[*]} ; result=\$?; \
             chown -R $(id -u):$(id -g) .tmp; exit \$result"
      fi

      printGreen "修补完成：${targetFile}"
    fi
  done

  # KernelSU 后处理：将 KSU .ko 注入到 rootless OTA 的 boot 中
  if [[ -n "${POTENTIAL_ASSETS['ksu']+isset}" ]]; then
    local rootlessOta=".tmp/${POTENTIAL_ASSETS['rootless']}"
    local ksuTarget=".tmp/${POTENTIAL_ASSETS['ksu']}"

    if ls "$ksuTarget" >/dev/null 2>&1; then
      printGreen "文件 $ksuTarget 已存在本地，跳过修补。"
    elif ls "$rootlessOta" >/dev/null 2>&1; then
      print "正在从 rootless 基础包构建 KSU OTA: $rootlessOta"
      injectKsuIntoOta "$rootlessOta" "$ksuTarget"
    else
      printRed "无法构建 KSU OTA: 未找到 rootless OTA 位于 $rootlessOta"
      exit 1
    fi
  fi
}

# ============================================================
# KernelSU 相关函数
# ============================================================

function downloadKsud() {
  local ksudBin=".tmp/ksud"
  local ksuVer="${KSU_VERSION#v}"

  if [ -f "$ksudBin" ] && [ -f ".tmp/ksud.version" ] && [ "$(cat .tmp/ksud.version)" = "$KSU_VERSION" ]; then
    return
  fi

  rm -f "$ksudBin"

  local ksudUrl=""
  ksudUrl=$(curl -sL "https://api.github.com/repos/tiann/KernelSU/releases/tags/v${ksuVer}" \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
for a in data.get('assets', []):
    if 'ksud-x86_64-unknown-linux-musl' in a['name']:
        print(a['browser_download_url'])
        break
" 2>/dev/null)

  if [ -z "$ksudUrl" ]; then
    print "KSU $KSU_VERSION 没有 Linux ksud 二进制。回退到 v3.2.1..."
    ksuVer="3.2.1"
    ksudUrl="https://github.com/tiann/KernelSU/releases/download/v${ksuVer}/ksud-x86_64-unknown-linux-musl"

    local kmi="${KSU_KMI}"
    if [ -n "$kmi" ]; then
      local koTarget=".tmp/ksu_module.ko"
      print "正在从 KernelSU v${ksuVer} 下载 ${kmi}_kernelsu.ko..."
      curl --fail -sLo "$koTarget" \
        "https://github.com/tiann/KernelSU/releases/download/v${ksuVer}/${kmi}_kernelsu.ko" || {
        printYellow "从 v${ksuVer} 下载 KMI $kmi 的 .ko 失败，将使用内置模块"
        rm -f "$koTarget"
      }
    fi
  fi

  print "正在下载 ksud..."
  curl --fail -sLo "$ksudBin" "$ksudUrl"
  chmod +x "$ksudBin"
  echo "$KSU_VERSION" > ".tmp/ksud.version"
  printGreen "ksud 已下载（来自 ${ksudUrl}）"
}

function downloadMagiskBoot() {
  local magiskbootBin=".tmp/magiskboot"

  if [ -f "$magiskbootBin" ]; then
    return
  fi

  print "正在从 Magisk APK 中提取 magiskboot..."
  local magiskApk=".tmp/magisk-$MAGISK_VERSION.apk"
  if [ ! -f "$magiskApk" ]; then
    print "正在下载 Magisk $MAGISK_VERSION..."
    curl --fail -sLo "$magiskApk" \
      "https://github.com/topjohnwu/Magisk/releases/download/$MAGISK_VERSION/Magisk-$MAGISK_VERSION.apk"
  fi

  python3 -c "
import zipfile, os, stat
with zipfile.ZipFile('$magiskApk') as z:
    z.extract('lib/x86_64/libmagiskboot.so', '.')
os.rename('lib/x86_64/libmagiskboot.so', '$magiskbootBin')
os.chmod('$magiskbootBin', stat.S_IRWXU)
import shutil; shutil.rmtree('lib', ignore_errors=True)
"
  printGreen "magiskboot 提取完成"
}

function detectDeviceParams() {
  local bootImg="$1"
  local kernelVer=""

  # 主方案：使用 magiskboot 解包 boot.img 并自动解压内核
  #
  # 文档依据：
  #   magiskboot unpack（不带 -n 时）默认自动解压所有组件
  #   https://topjohnwu.github.io/Magisk/tools.html#magiskboot
  #   "By default, each component will be automatically decompressed
  #    on-the-fly before writing to the output file."
  #
  # avbroot 也采用相同方法（avbroot/src/patch/boot.rs·get_kmi_version）：
  #   1. 从 boot image 中提取内核数据
  #   2. 自动检测压缩格式并解压（CompressedReader::new(raw_reader, true)）
  #   3. 在解压后的内核中搜索 "Linux version X.Y..." 正则
  #
  # 输出的组件文件名包括: kernel, kernel_dtb, ramdisk.cpio, second, dtb, ...
  # GKI 设备（Pixel 8+）通常输出 kernel_dtb（内核+DTB 合并格式）
  # 传统设备输出 kernel
  local workDir=".tmp/device_detect"
  rm -rf "$workDir"
  mkdir -p "$workDir"
  (cd "$workDir" && ../.tmp/magiskboot unpack "../$bootImg" >/dev/null 2>&1) || true

  local kernelFile=""
  for f in kernel kernel_dtb kernel.gz Image Image.gz Image.lz4; do
    if [ -f "$workDir/$f" ]; then
      kernelFile="$workDir/$f"
      break
    fi
  done

  if [ -n "$kernelFile" ]; then
    # magiskboot 已自动解压，直接读取版本字符串
    kernelVer=$(strings "$kernelFile" | grep -m1 'Linux version [0-9]\+\.[0-9]\+')
  fi
  rm -rf "$workDir"

  if [ -n "$kernelVer" ]; then
    print "内核版本: $kernelVer"
    local major minor
    major=$(echo "$kernelVer" | sed 's/.*Linux version //' | cut -d'.' -f1)
    minor=$(echo "$kernelVer" | sed 's/.*Linux version //' | cut -d'.' -f2)

    case "${major}.${minor}" in
      "5.10") DETECTED_KMI="android12-5.10"; DETECTED_PREINIT="metadata";;
      "5.15") DETECTED_KMI="android13-5.15"; DETECTED_PREINIT="metadata";;
      "6.1")  DETECTED_KMI="android14-6.1";  DETECTED_PREINIT="sda10";;
      "6.6")  DETECTED_KMI="android15-6.6";  DETECTED_PREINIT="sda10";;
      "6.12") DETECTED_KMI="android16-6.12"; DETECTED_PREINIT="sda10";;
      *)
        printRed "未知内核版本 ${major}.${minor}" >&2
        DETECTED_KMI=""; DETECTED_PREINIT=""
        return 1;;
    esac
    printGreen "检测到 KMI: $DETECTED_KMI, preinit: $DETECTED_PREINIT"
    return 0
  fi

  # 回退方案：magiskboot 无法处理该 boot.img 格式，使用设备已知参数
  printYellow "无法从 boot.img 检测内核版本，使用设备已知参数" >&2
  case "${DEVICE_ID}" in
    # Tensor G1/G2 (Pixel 6/7 系列) — kernel 5.10/5.15
    oriole|raven|bluejay|panther|cheetah|lynx|felix|tangorpro)
      DETECTED_KMI="android13-5.15"
      DETECTED_PREINIT="metadata"
      ;;
    # Tensor G3 (Pixel 8 系列) — kernel 6.1
    shiba|husky|akita)
      DETECTED_KMI="android14-6.1"
      DETECTED_PREINIT="sda10"
      ;;
    # Tensor G4 (Pixel 9 系列) — kernel 6.6
    tokay|caiman|komodo|comet)
      DETECTED_KMI="android15-6.6"
      DETECTED_PREINIT="sda10"
      ;;
    # 未知设备，使用通用默认值
    *)
      printYellow "未知设备 $DEVICE_ID，使用通用默认值" >&2
      DETECTED_KMI="android14-6.1"
      DETECTED_PREINIT="sda10"
      ;;
  esac
}

function injectKsuIntoOta() {
  local rootlessOta="$1"
  local ksuTarget="$2"
  local workDir=".tmp/ksu_work"

  print "正在向 OTA 中注入 KernelSU..."
  mkdir -p "$workDir"

  downloadAvBroot
  downloadKsud
  downloadMagiskBoot

  print "正在从 rootless OTA 中提取 boot.img..."
  .tmp/avbroot ota extract \
    --input "$rootlessOta" \
    --directory "$workDir/extracted" \
    --boot-only
  printGreen "boot.img 提取完成"

  local kmi="${KSU_KMI}"
  if [ -z "$kmi" ]; then
    print "正在从 boot.img 自动检测 KMI..."
    DETECTED_KMI=""
    DETECTED_PREINIT=""
    detectDeviceParams "$workDir/extracted/boot.img"
    kmi="$DETECTED_KMI"
    if [ -z "$kmi" ]; then
      printYellow "KMI 自动检测失败，使用设备默认值"
      case "$DEVICE_ID" in
        shiba|husky|akita)  kmi="android14-6.1" ;;  # Pixel 8 系列
        tokay|caiman|komodo) kmi="android15-6.6" ;; # Pixel 9 系列
        oriole|raven|bluejay) kmi="android12-5.10" ;; # Pixel 6 系列
        panther|cheetah|lynx) kmi="android13-5.15" ;; # Pixel 7 系列
        *)                  kmi="android14-6.1" ;;
      esac
      print "默认 KMI: $kmi"
    else
      printGreen "KMI: $kmi"
    fi
  else
    print "使用已配置的 KMI: $kmi"
  fi

  local bootImgPath="$PROJECT_ROOT/$workDir/extracted/boot.img"
  if [ ! -f "$bootImgPath" ]; then
    printRed "boot.img 不存在于 $bootImgPath"
    ls -la "$PROJECT_ROOT/$workDir/extracted/" 2>/dev/null || true
    exit 1
  fi

  mkdir -p "$workDir/patched"
  local ksudArgs=()
  ksudArgs+=("-b" "$bootImgPath")
  ksudArgs+=("--kmi" "$kmi")
  ksudArgs+=("--magiskboot" "$PROJECT_ROOT/.tmp/magiskboot")
  ksudArgs+=("-o" "$PROJECT_ROOT/$workDir/patched")
  ksudArgs+=("--out-name" "ksu_patched_boot.img")

  if [ -f "$PROJECT_ROOT/.tmp/ksu_module.ko" ]; then
    print "使用外部 .ko 模块（来自请求的 KSU 版本）"
    ksudArgs+=("--module" "$PROJECT_ROOT/.tmp/ksu_module.ko")
  fi

  if [ "$KSU_ALLOW_SHELL" = 'true' ]; then
    ksudArgs+=("--allow-shell")
  fi

  "$PROJECT_ROOT/.tmp/ksud" boot-patch "${ksudArgs[@]}"

  local patchedBoot
  patchedBoot=$(find "$workDir/patched" -maxdepth 1 -type f -name "*.img" 2>/dev/null | head -1)
  if [ -z "$patchedBoot" ]; then
    printRed "在 $workDir/patched 中未找到修补后的 boot 镜像"
    ls -la "$workDir/patched/" 2>/dev/null || true
    exit 1
  fi
  printGreen "KernelSU 修补后的 boot 镜像: $patchedBoot"

  print "正在使用预修补的 boot.img 创建签名的 KSU OTA..."
  local avbrootArgs=()
  avbrootArgs+=("ota" "patch")
  avbrootArgs+=("--input" "$rootlessOta")
  avbrootArgs+=("--output" "$ksuTarget")
  avbrootArgs+=("--prepatched" "$patchedBoot")
  avbrootArgs+=("--key-avb" "$KEY_AVB")
  avbrootArgs+=("--key-ota" "$KEY_OTA")
  avbrootArgs+=("--cert-ota" "$CERT_OTA")

  if [ -v PASSPHRASE_AVB ] && [ -n "${PASSPHRASE_AVB+x}" ]; then
    avbrootArgs+=("--pass-avb-env-var" "PASSPHRASE_AVB")
  fi
  if [ -v PASSPHRASE_OTA ] && [ -n "${PASSPHRASE_OTA+x}" ]; then
    avbrootArgs+=("--pass-ota-env-var" "PASSPHRASE_OTA")
  fi

  .tmp/avbroot "${avbrootArgs[@]}"

  if [ "$SKIP_CLEANUP" != 'true' ]; then
    rm -rf "$workDir"
  fi

  printGreen "KSU OTA created: $ksuTarget"
}

function base642key() {
  set +x
  if [ -n "$KEY_AVB_BASE64" ]; then
    echo "$KEY_AVB_BASE64" | base64 -d > .tmp/$KEY_AVB
    KEY_AVB=.tmp/$KEY_AVB
  fi
  if [ -n "$KEY_OTA_BASE64" ]; then
    echo "$KEY_OTA_BASE64" | base64 -d > .tmp/$KEY_OTA
    KEY_OTA=.tmp/$KEY_OTA
  fi
  if [ -n "$CERT_OTA_BASE64" ]; then
    echo "$CERT_OTA_BASE64" | base64 -d > .tmp/$CERT_OTA
    CERT_OTA=.tmp/$CERT_OTA
  fi
  if [[ -n "${DEBUG}" ]]; then set -x; fi
}

# ============================================================
# 发布到 GitHub Release
# ============================================================

function releaseOta() {
  createReleaseIfNecessary
  for flavor in "${!POTENTIAL_ASSETS[@]}"; do
    local assetName="${POTENTIAL_ASSETS[$flavor]}"
    uploadFile ".tmp/$assetName" "$assetName" "application/zip"
  done
}

function createReleaseIfNecessary() {
  checkMandatoryVariable 'GITHUB_REPO' 'GITHUB_TOKEN'

  local response changelog src_repo current_commit

  if [[ -z "$RELEASE_ID" ]]; then
    src_repo=$(extractGithubRepo "$(git config --get remote.origin.url)")

    if [[ "${GITHUB_REPO}" == "${src_repo}" ]]; then
      changelog=$(curl -sL -X POST -H "Authorization: token $GITHUB_TOKEN" \
        -d "{
                \"tag_name\": \"$OTA_VERSION\",
                \"target_commitish\": \"master\"
              }" \
        "https://api.github.com/repos/$GITHUB_REPO/releases/generate-notes" | jq -r '.body // empty')
      changelog="更新到 Pixel $OTA_VERSION.\n\n$(echo "${changelog}" | sed ':a;N;$!ba;s/\n/\\n/g')"
    else
      current_commit=$(git rev-parse --short HEAD)
      changelog="更新到 Pixel $OTA_VERSION.\n\n由 ${src_repo}@${current_commit} 构建。"
    fi

    response=$(curl -sL -X POST -H "Authorization: token $GITHUB_TOKEN" \
      -d "{
              \"tag_name\": \"$OTA_VERSION\",
              \"target_commitish\": \"master\",
              \"name\": \"$OTA_VERSION\",
              \"body\": \"${changelog}\"
            }" \
      "https://api.github.com/repos/$GITHUB_REPO/releases")
    RELEASE_ID=$(echo "${response}" | jq -r '.id // empty')

    if [[ -n "${RELEASE_ID}" ]]; then
      printGreen "Release 创建成功，ID: ${RELEASE_ID}"
    elif echo "${response}" | jq -e '.status == "422"' > /dev/null; then
      RELEASE_ID=$(curl -sL \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/${GITHUB_REPO}/releases" | \
        jq -r --arg release_tag "${OTA_VERSION}" '.[] | select(.tag_name == $release_tag) | .id // empty')
      if [[ -n "${RELEASE_ID}" ]]; then
        printGreen "Release 已存在。ID=$RELEASE_ID"
      else
        printRed "无法创建 release ${OTA_VERSION}"
        exit 1
      fi
    else
      errors=$(echo "${response}" | jq -r '.errors')
      printRed "创建 release ${OTA_VERSION} 失败。错误: ${errors}"
      exit 1
    fi
  fi
}

function uploadFile() {
  local sourceFileName="$1" targetFileName="$2" contentType="$3"
  curl --fail -X POST -H "Authorization: token $GITHUB_TOKEN" \
    -H "Content-Type: $contentType" \
    --upload-file "$sourceFileName" \
    "https://uploads.github.com/repos/$GITHUB_REPO/releases/$RELEASE_ID/assets?name=$targetFileName"
}

# ============================================================
# OTA 服务器数据（Custota）
# ============================================================

function createOtaServerData() {
  downloadCusotaTool

  for flavor in "${!POTENTIAL_ASSETS[@]}"; do
    local assetName="${POTENTIAL_ASSETS[$flavor]}"
    local targetFile=".tmp/${assetName}"

    local args=()
    args+=("--input" "${targetFile}")
    args+=("--output" "${targetFile}.csig")
    args+=("--key" "$KEY_OTA")
    args+=("--cert" "$CERT_OTA")

    if [ -v PASSPHRASE_OTA ]; then
      args+=("--passphrase-env-var" "PASSPHRASE_OTA")
    fi

    .tmp/custota-tool gen-csig "${args[@]}"

    mkdir -p ".tmp/${flavor}"

    local args2=()
    args2+=("--file" ".tmp/${flavor}/${DEVICE_ID}.json")
    args2+=("--location" "https://github.com/$GITHUB_REPO/releases/download/$OTA_VERSION/$assetName")

    .tmp/custota-tool gen-update-info "${args2[@]}"
  done
}

function downloadCusotaTool() {
  downloadAndVerifyFromChenxiaolong 'Custota' "$CUSTOTA_VERSION" 'custota-tool'
}

function uploadOtaServerData() {
  local current_branch current_commit base_dir src_repo
  current_commit=$(git rev-parse --short HEAD)
  folderPrefix=''

  if [[ "${UPLOAD_TEST_OTA}" == 'true' ]]; then
    folderPrefix='test/'
  fi

  (
    base_dir="$(pwd)"
    src_repo=$(extractGithubRepo "$(git config --get remote.origin.url)")

    if [[ -n "${PAGES_REPO_FOLDER}" ]]; then
      cd "${PAGES_REPO_FOLDER}"
    fi

    current_branch=$(git rev-parse --abbrev-ref HEAD)
    git checkout gh-pages

    for flavor in "${!POTENTIAL_ASSETS[@]}"; do
      local assetName="${POTENTIAL_ASSETS[$flavor]}"
      local targetFile="${folderPrefix}${flavor}/${DEVICE_ID}.json"

      uploadFile "${base_dir}/.tmp/${assetName}.csig" "$assetName.csig" "application/octet-stream"

      mkdir -p "${folderPrefix}${flavor}"
      if ! grep -q "$OTA_VERSION" "${targetFile}" || \
         [[ "$FORCE_OTA_SERVER_UPLOAD" == 'true' ]] && [[ "$SKIP_OTA_SERVER_UPLOAD" != 'true' ]]; then
        cp "${base_dir}/.tmp/${flavor}/$DEVICE_ID.json" "${targetFile}"
        git add "${targetFile}"
      elif grep -q "${OTA_VERSION}" "${targetFile}"; then
        printGreen "跳过 OTA 服务器更新，${OTA_VERSION} 已存在。"
      else
        printGreen "跳过 OTA 服务器更新（SKIP_OTA_SERVER_UPLOAD=true）。"
      fi
    done

    if ! git diff-index --quiet HEAD; then
      git config user.name "GitHub Actions" && git config user.email "actions@github.com"
      git commit \
        --message "更新设备 ${DEVICE_ID}，基于 ${src_repo}@${current_commit}"
      gitPushWithRetries
    fi

    git checkout "$current_branch"
  )
}

function extractGithubRepo() {
  local remote_url="$1" repo
  remote_url=$(echo "$remote_url" | sed -e 's/.*:\/\/\|.*@//' -e 's/\.git$//')
  repo=$(echo "$remote_url" | sed -e 's/.*[:\/]\([^\/]*\/[^\/]*\)$/\1/')
  echo "$repo"
}

function gitPushWithRetries() {
  local count=0
  while [ $count -lt $GIT_PUSH_RETRIES ]; do
    git pull --rebase
    if git push origin gh-pages; then
      break
    else
      count=$((count + 1))
      print "重试 $count/$GIT_PUSH_RETRIES..."
      sleep 2
    fi
  done
  if [ $count -eq $GIT_PUSH_RETRIES ]; then
    printRed "推送 gh-pages 失败。"
    exit 1
  fi
}

# ============================================================
# 顶层操作
# ============================================================

function determineAssets() {
  # 确定需要构建的 flavor，使用包含 commit hash 的命名以支持跳过逻辑

  local currentCommit
  currentCommit=$(git rev-parse --short HEAD)

  if [[ "$OTA_TARGET" == *-factory-* ]]; then
    printYellow "使用 factory image，仅支持 rootless（无 OTA 更新功能）"
    POTENTIAL_ASSETS['rootless']="${OTA_TARGET}.patched.zip"
    return
  fi

  # 命名格式: {DEVICE_ID}-{OTA_VERSION}-{commitHash}-{flavor}{suffix}.zip
  local baseName="${DEVICE_ID}-${OTA_VERSION}-${currentCommit}"

  # Rootless
  POTENTIAL_ASSETS['rootless']="${baseName}-rootless$(createAssetSuffix).zip"

  # Magisk（如果指定了 preinit device）
  if [[ -n "$MAGISK_PREINIT_DEVICE" ]]; then
    POTENTIAL_ASSETS['magisk']="${baseName}-magisk-${MAGISK_VERSION}$(createAssetSuffix).zip"
  fi

  # KernelSU（如果指定了版本）
  if [[ -n "$KSU_VERSION" ]]; then
    POTENTIAL_ASSETS['ksu']="${baseName}-ksu-${KSU_VERSION}$(createAssetSuffix).zip"
  fi

  if [[ "${SKIP_ROOTLESS}" == 'true' ]]; then
    unset 'POTENTIAL_ASSETS[rootless]'
  fi
}

declare -A POTENTIAL_ASSETS

function checkBuildNecessary() {
  local currentCommit
  currentCommit=$(git rev-parse --short HEAD)

  RELEASE_ID=''
  local response

  if [[ -z "$GITHUB_REPO" ]]; then
    print "未设置环境变量 GITHUB_REPO，跳过已存在 release 的检查"
    return
  fi

  print "潜在 release 版本: ${OTA_VERSION}"

  local params=()
  local url="https://api.github.com/repos/${GITHUB_REPO}/releases"

  if [ -n "${GITHUB_TOKEN}" ]; then
    params+=("-H" "Authorization: token ${GITHUB_TOKEN}")
  fi
  params+=("-H" "Accept: application/vnd.github.v3+json")

  response=$(
    curl --fail -sL "${params[@]}" "${url}" |
      jq --arg release_tag "${OTA_VERSION}" '.[] | select(.tag_name == $release_tag) | {id, tag_name, assets}' 2>/dev/null || true
  )

  if [[ -n ${response} ]]; then
    RELEASE_ID=$(echo "${response}" | jq -r '.id')
    print "Release ${OTA_VERSION} 已存在。ID=$RELEASE_ID"

    for flavor in "${!POTENTIAL_ASSETS[@]}"; do
      local selectedAsset POTENTIAL_ASSET_NAME="${POTENTIAL_ASSETS[$flavor]}"
      print "检查制品是否已存在: ${POTENTIAL_ASSET_NAME}"

      # 严格模式（默认）：包含 commit hash，确保脚本变更后重新构建
      # 宽松模式（CHECK_LENIENT=true）：只按 OTA 版本匹配，适合每日自动构建
      local assetPrefix
      if [[ "${CHECK_LENIENT:-false}" == 'true' ]]; then
        assetPrefix="${DEVICE_ID}-${OTA_VERSION}"
      else
        assetPrefix="${DEVICE_ID}-${OTA_VERSION}-${currentCommit}"
      fi
      selectedAsset=$(echo "${response}" | jq -r --arg assetPrefix "$assetPrefix" \
        '.assets[] | select(.name | startswith($assetPrefix)) | .name' \
          | grep "${flavor}" || true)

      if [[ -n "${selectedAsset}" ]] && [[ "$FORCE_BUILD" != 'true' ]] && [[ "$UPLOAD_TEST_OTA" != 'true' ]]; then
        printGreen "跳过构建 '$POTENTIAL_ASSET_NAME'。该 flavor 已存在其他 commit 的产物。" \
          "设置 FORCE_BUILD 或 UPLOAD_TEST_OTA 可强制构建。Release 中已有的产物: ${selectedAsset//$'\n'/ }"
        unset "POTENTIAL_ASSETS[$flavor]"
      else
        print "在 release 中未找到同名产物。"
      fi
    done

    if [ "${#POTENTIAL_ASSETS[@]}" -eq 0 ]; then
      printGreen "所有潜在产物均已存在。退出。"
      exit 0
    fi
  else
    print "Release ${OTA_VERSION} 尚未存在。"
  fi
}

function createRootedOta() {
  initToolCache
  findLatestVersion
  determineAssets
  checkBuildNecessary   # 如果 release 中已存在相同 commit 的产物则跳过
  downloadAndroidDependencies
  patchOTAs
  if [ "$SKIP_CLEANUP" != 'true' ]; then
    saveToolCache
  fi
  printGreen "所有 OTA 构建完成！"
  for flavor in "${!POTENTIAL_ASSETS[@]}"; do
    ls -lh ".tmp/${POTENTIAL_ASSETS[$flavor]}"
  done
}

function createAndReleaseRootedOta() {
  createRootedOta
  createOtaServerData
  releaseOta
  uploadOtaServerData
}

function generateKeys() {
  # 生成 AVB 和 OTA 签名密钥
  mkdir -p keys
  print "正在生成 AVB 签名密钥..."
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 \
    -out keys/avb.key
  print "正在生成 OTA 签名密钥..."
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 \
    -out keys/ota.key
  openssl req -new -x509 -days 36500 -key keys/ota.key \
    -out keys/ota.crt -subj '/CN=Rooted Pixel OTA/'
  printGreen "密钥已生成到 keys/ 目录"
  printYellow "请安全保管这些密钥文件！"
}

# ============================================================
# 打印函数
# ============================================================

function print() {
  echo -e "$(date '+%Y-%m-%d %H:%M:%S'): $*"
}

function printGreen() {
  if [[ -z "${NO_COLOR}" ]]; then
    echo -e "\e[32m$(date '+%Y-%m-%d %H:%M:%S'): $*\e[0m"
  else
    print "$@"
  fi
}

function printRed() {
  if [[ -z "${NO_COLOR}" ]]; then
    echo -e "\e[31m$(date '+%Y-%m-%d %H:%M:%S'): $*\e[0m" >&2
  else
    print "$@" >&2
  fi
}

function printYellow() {
  if [[ -z "${NO_COLOR}" ]]; then
    echo -e "\e[33m$(date '+%Y-%m-%d %H:%M:%S'): $*\e[0m"
  else
    print "$@"
  fi
}

# ============================================================
# 主入口（source 时不执行）
# ============================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "rooted-pixel OTA 工具"
  echo ""
  echo "用法: source rooted-ota.sh && <函数名>"
  echo ""
  echo "可用函数:"
  echo "  generateKeys              - 生成签名密钥"
  echo "  createRootedOta           - 创建修补后的 OTA"
  echo "  createAndReleaseRootedOta - 创建并发布 OTA"
  echo ""
  echo "环境变量:"
  echo "  DEVICE_ID     - Pixel 设备代号（必填）"
  echo "  OTA_VERSION   - Build ID（默认 latest，从 devices.json 读取）"
  echo "  KSU_VERSION   - KernelSU 版本（如 v3.2.4）"
  echo "  MAGISK_PREINIT_DEVICE - Magisk preinit 分区"
fi
