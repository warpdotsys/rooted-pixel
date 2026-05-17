#!/usr/bin/env python3
"""
fetch_latest_ota.py — 抓取 Google Pixel OTA 下载链接

使用方法:
    python fetch_latest_ota.py --output devices.json
    python fetch_latest_ota.py --device shiba  # 输出指定设备的最新 OTA 信息

无需额外依赖（仅使用 Python 标准库）。

使用 curl-like HTTP 请求 + Cookie 绕过 Google TOS 墙，
不再依赖 Playwright / headless Chromium。
"""

import argparse
import json
import os
import re
import sys
import urllib.request
import urllib.error
from datetime import datetime

# Google OTA 页面 URL
OTA_PAGE_URL = "https://developers.google.com/android/ota?hl=zh-cn"
FACTORY_PAGE_URL = "https://developers.google.com/android/images?hl=zh-cn"

# Google 下载服务器基础 URL
DL_BASE = "https://dl.google.com/dl/android/aosp"

# 请求头（含 TOS cookie，参考 auto_ota_manual_patch.sh）
REQUEST_HEADERS = {
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                  "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Cookie": "devsite_wall_acks=nexus-ota-tos",
}


def parse_ota_url(url: str):
    """
    从 OTA zip URL 中提取设备代号、build ID 和 SHA。

    URL 格式:
    https://dl.google.com/dl/android/aosp/{device}-ota-{build_id}-{sha}.zip

    返回 (device, build_id, sha) 或 None
    """
    # 精确匹配标准格式
    m = re.search(
        r'/([a-z]+[0-9]*)-ota-([A-Z0-9]+\.[0-9]{6}\.[0-9]{3})-([a-f0-9]{8})\.zip$',
        url
    )
    if m:
        return m.group(1), m.group(2), m.group(3)

    # 宽松匹配
    m = re.search(
        r'/([a-z]+[0-9]*)-ota-([^/]+)\.zip$',
        url
    )
    if m:
        device = m.group(1)
        rest = m.group(2)
        parts = rest.rsplit('-', 1)
        if len(parts) == 2 and re.match(r'^[a-f0-9]{8}$', parts[1]):
            return device, parts[0], parts[1]
        return device, rest, ""

    return None


def parse_factory_url(url: str):
    """
    从 factory image URL 中提取设备代号和 build ID。

    URL 格式:
    https://dl.google.com/dl/android/aosp/{device}-factory-{build_id}.zip
    """
    m = re.search(r'/([a-z]+[0-9]*)-factory-([A-Z0-9]+\.[0-9]{6}\.[0-9]{3})\.zip$', url)
    if m:
        return m.group(1), m.group(2)
    return None


def fetch_page_text(url: str) -> str:
    """使用 urllib 获取页面 HTML 文本（带 TOS cookie）"""
    req = urllib.request.Request(url, headers=REQUEST_HEADERS)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.read().decode('utf-8', errors='replace')
    except urllib.error.HTTPError as e:
        print(f"HTTP 错误 {e.code}: {e.reason} （{url}）", file=sys.stderr)
        return ""
    except Exception as e:
        print(f"请求失败: {e} （{url}）", file=sys.stderr)
        return ""


def extract_ota_links(html: str, target_device: str = None) -> list:
    """
    从 HTML 页面中提取所有 OTA zip 链接。

    使用正则匹配（同 auto_ota_manual_patch.sh 的 grep 方式）。
    """
    links = re.findall(
        r'https://dl\.google\.com/dl/android/aosp/[a-z]+[0-9]*-ota-[a-zA-Z0-9.\-]*\.zip',
        html
    )

    if target_device:
        links = [l for l in links if f'/{target_device}-ota-' in l]

    # 去重并保持顺序
    seen = set()
    unique_links = []
    for link in links:
        if link not in seen:
            seen.add(link)
            unique_links.append(link)

    return unique_links


def extract_factory_links(html: str, target_device: str = None) -> list:
    """从 HTML 页面中提取 factory image 链接"""
    links = re.findall(
        r'https://dl\.google\.com/dl/android/aosp/[a-z]+[0-9]*-factory-[A-Z0-9]+\.[0-9]{6}\.[0-9]{3}\.zip',
        html
    )

    if target_device:
        links = [l for l in links if f'/{target_device}-factory-' in l]

    seen = set()
    unique_links = []
    for link in links:
        if link not in seen:
            seen.add(link)
            unique_links.append(link)

    return unique_links


def scrape_ota_data(target_device: str = None) -> list:
    """
    抓取 Google OTA 页面，提取所有设备的 OTA 信息。

    返回 [{"device": ..., "build_id": ..., "ota_sha": ..., "url": ...}, ...]
    """
    print("正在获取 OTA 页面...", file=sys.stderr)
    html = fetch_page_text(OTA_PAGE_URL)
    if not html:
        print("失败：无法获取 OTA 页面", file=sys.stderr)
        return []

    print(f"页面大小: {len(html)} 字节", file=sys.stderr)

    ota_links = extract_ota_links(html, target_device)
    print(f"找到 {len(ota_links)} 个 OTA 链接", file=sys.stderr)

    entries = []
    for link in ota_links:
        parsed = parse_ota_url(link)
        if parsed:
            device, build_id, sha = parsed
            entries.append({
                "device": device,
                "build_id": build_id,
                "ota_sha": sha,
                "url": link,
            })
            print(f"  {device}: {build_id} (SHA: {sha})", file=sys.stderr)
        else:
            print(f"  无法解析: {link}", file=sys.stderr)

    return entries


def scrape_factory_data(target_device: str = None) -> dict:
    """
    抓取 Google Factory Image 页面，用于补充 OTA 数据中缺失的设备信息。

    返回 {device: build_id, ...}
    """
    print("\n正在获取 Factory Image 页面...", file=sys.stderr)
    html = fetch_page_text(FACTORY_PAGE_URL)
    if not html:
        print("失败：无法获取 Factory Image 页面", file=sys.stderr)
        return {}

    factory_links = extract_factory_links(html, target_device)
    print(f"找到 {len(factory_links)} 个 Factory 链接", file=sys.stderr)

    factory_devices = {}
    for link in factory_links:
        parsed = parse_factory_url(link)
        if parsed:
            device, build_id = parsed
            factory_devices[device] = build_id

    return factory_devices


def build_devices_json(ota_entries: list, factory_devices: dict) -> dict:
    """
    将 OTA 条目和 factory 数据合并为 devices.json 格式。

    输出格式:
    {
      "schema_version": 1,
      "description": "...",
      "updated": "2026-05-17",
      "devices": {
        "shiba": {
          "name": "Pixel 8",
          "builds": [{"build_id": "...", "ota_sha": "...", "date": "..."}],
          "latest_build": "...",
          "magisk_preinit": "",
          "ksu_kmi": ""
        },
        ...
      }
    }
    """
    # 设备名称映射（常用 Pixel 设备）
    DEVICE_NAMES = {
        "rango": "Pixel 10 Pro Fold",
        "blazer": "Pixel 10 Pro",
        "frankel": "Pixel 10",
        "mustang": "Pixel 10 Pro XL",
        "tegu": "Pixel 9a",
        "comet": "Pixel 9 Pro Fold",
        "caiman": "Pixel 9 Pro",
        "komodo": "Pixel 9 Pro XL",
        "tokay": "Pixel 9",
        "akita": "Pixel 8a",
        "husky": "Pixel 8 Pro",
        "shiba": "Pixel 8",
        "felix": "Pixel Fold",
        "tangorpro": "Pixel Tablet",
        "lynx": "Pixel 7a",
        "cheetah": "Pixel 7 Pro",
        "panther": "Pixel 7",
        "bluejay": "Pixel 6a",
        "oriole": "Pixel 6",
        "raven": "Pixel 6 Pro",
        "barbet": "Pixel 5a",
        "redfin": "Pixel 5",
        "bramble": "Pixel 4a (5G)",
        "sunfish": "Pixel 4a",
        "coral": "Pixel 4 XL",
        "flame": "Pixel 4",
        "bonito": "Pixel 3a XL",
        "sargo": "Pixel 3a",
        "crosshatch": "Pixel 3 XL",
        "blueline": "Pixel 3",
        "taimen": "Pixel 2 XL",
        "walleye": "Pixel 2",
        "marlin": "Pixel XL",
        "sailfish": "Pixel",
        "ryu": "Pixel C",
    }

    # KMI 映射（基于 Android 版本和设备 SoC）
    DEFAULT_KMI = {
        "oriole": "android12-5.10", "raven": "android12-5.10", "bluejay": "android12-5.10",
        "panther": "android13-5.15", "cheetah": "android13-5.15", "lynx": "android13-5.15",
        "shiba": "android14-6.1", "husky": "android14-6.1", "akita": "android14-6.1",
        "tokay": "android15-6.6", "caiman": "android15-6.6", "komodo": "android15-6.6",
        "comet": "android15-6.6",
    }

    DEFAULT_PREINIT = {
        "shiba": "sda10", "husky": "sda10", "akita": "sda10",
        "tokay": "sda10", "caiman": "sda10", "komodo": "sda10", "comet": "sda10",
    }

    # 按设备分组
    device_builds = {}
    for entry in ota_entries:
        dev = entry["device"]
        if dev not in device_builds:
            device_builds[dev] = []
        device_builds[dev].append(entry)

    devices = {}
    for dev, builds in device_builds.items():
        # 按页面出现顺序（最晚出现的 = 最新版本）
        # Google OTA 页面中最新版本位于页面底部
        build_list = []
        for b in builds:
            # 从 build_id 中提取日期: AP4A.250205.002 -> 250205 -> 2025-02
            date_str = ""
            m = re.search(r'(20\d{2})(\d{2})\d{2}', b["build_id"])
            if m:
                date_str = f"{m.group(1)}-{m.group(2)}"
            else:
                date_str = datetime.now().strftime("%Y-%m")

            build_list.append({
                "build_id": b["build_id"],
                "ota_sha": b["ota_sha"],
                "date": date_str,
            })

        # 最新版本 = builds 列表中最后出现的（页面底部）
        latest_build = builds[-1]["build_id"] if builds else ""

        devices[dev] = {
            "name": DEVICE_NAMES.get(dev, dev),
            "builds": build_list,
            "latest_build": latest_build,
            "magisk_preinit": DEFAULT_PREINIT.get(dev, ""),
            "ksu_kmi": DEFAULT_KMI.get(dev, ""),
        }

    return {
        "schema_version": 1,
        "description": "Pixel 设备 OTA 信息数据库。每次构建前请通过 update-devices workflow 更新此文件。",
        "updated": datetime.now().strftime("%Y-%m-%d"),
        "devices": devices,
    }


def main():
    parser = argparse.ArgumentParser(description="抓取 Google Pixel OTA 下载链接")
    parser.add_argument("--output", "-o", help="输出到 devices.json 文件")
    parser.add_argument("--device", "-d", help="指定设备代号（可选）")
    args = parser.parse_args()

    target_device = args.device or None

    # 1. 抓取 OTA 数据
    ota_entries = scrape_ota_data(target_device)
    if not ota_entries:
        print("未获取到任何 OTA 数据，退出", file=sys.stderr)
        sys.exit(1)

    # 2. 抓取 Factory 数据作为补充
    factory_data = scrape_factory_data(target_device)

    # 3. 构建 JSON
    data = build_devices_json(ota_entries, factory_data)

    total_devices = len(data["devices"])
    total_builds = sum(len(d["builds"]) for d in data["devices"].values())
    print(f"\n共 {total_devices} 个设备，{total_builds} 个构建", file=sys.stderr)

    # 4. 输出
    json_str = json.dumps(data, indent=2, ensure_ascii=False)

    if args.output:
        with open(args.output, "w") as f:
            f.write(json_str)
        print(f"已写入 {args.output}", file=sys.stderr)
    else:
        print(json_str)

    # 单设备查询模式：打印摘要
    if target_device and target_device in data["devices"]:
        dev = data["devices"][target_device]
        latest = dev.get("latest_build", "")
        builds = dev.get("builds", [])
        print(f"\n{dev['name']} ({target_device}):", file=sys.stderr)
        print(f"  最新版本: {latest}", file=sys.stderr)
        print(f"  可用构建: {len(builds)} 个", file=sys.stderr)
        for b in builds:
            print(f"    {b['build_id']}  SHA: {b['ota_sha']}", file=sys.stderr)


if __name__ == "__main__":
    main()
