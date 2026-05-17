#!/usr/bin/env python3
"""
fetch_latest_ota.py — 抓取 Google Pixel OTA 下载链接

使用方法:
    python fetch_latest_ota.py --output devices.json
    python fetch_latest_ota.py --device shiba  # 输出指定设备的最新 OTA 信息

依赖:
    pip install playwright beautifulsoup4 lxml
    playwright install chromium

该脚本使用 Playwright 打开 Google 的 OTA 下载页面，
解析 JavaScript 渲染后的表格，提取所有设备的 OTA 下载链接，
然后解析出 build ID 和 SHA，输出到 JSON 文件。
"""

import argparse
import json
import os
import re
import sys
import urllib.parse
from datetime import datetime

try:
    from bs4 import BeautifulSoup
except ImportError:
    BeautifulSoup = None

try:
    from playwright.sync_api import sync_playwright
except ImportError:
    sync_playwright = None


# Google OTA 页面 URL
OTA_PAGE_URL = "https://developers.google.com/android/ota"
FACTORY_PAGE_URL = "https://developers.google.com/android/images"

# Google 下载服务器基础 URL
DL_BASE = "https://dl.google.com/dl/android/aosp"


def parse_ota_url(url: str):
    """
    从 OTA zip URL 中提取设备代号、build ID 和 SHA。

    URL 格式:
    https://dl.google.com/dl/android/aosp/{device}-ota-{build_id}-{sha}.zip

    返回 (device, build_id, sha) 或 None
    """
    # 匹配正则
    m = re.search(
        r'/([a-z]+[0-9]*)-ota-([A-Z0-9]+\.[0-9]{6}\.[0-9]{3})-([a-f0-9]{8})\.zip$',
        url
    )
    if m:
        return m.group(1), m.group(2), m.group(3)

    # 尝试更宽松的匹配
    m = re.search(
        r'/([a-z]+[0-9]*)-ota-([^/]+)\.zip$',
        url
    )
    if m:
        device = m.group(1)
        rest = m.group(2)
        # 尝试拆分 build_id 和 sha
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


def scrape_with_playwright(output: str, target_device: str = None, headless: bool = True):
    """使用 Playwright 抓取页面"""
    if sync_playwright is None:
        print("错误: 需要安装 playwright: pip install playwright && playwright install chromium",
              file=sys.stderr)
        sys.exit(1)

    ota_entries = []

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=headless)
        context = browser.new_context(
            user_agent="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                       "KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
        )
        page = context.new_page()

        # 同时加载 OTA 和 Factory 页面
        print(f"正在打开 OTA 页面: {OTA_PAGE_URL}")
        page.goto(OTA_PAGE_URL, wait_until="networkidle", timeout=60000)
        page.wait_for_timeout(3000)

        # 检查是否有下载链接表格
        html = page.content()
        soup = BeautifulSoup(html, 'lxml') if BeautifulSoup else None

        # 方法 1: 查找包含下载链接的表格
        ota_links = []
        for a_tag in page.locator('a[href*="dl.google.com"][href$=".zip"]').all():
            href = a_tag.get_attribute('href')
            if href and href.endswith('.zip') and '-ota-' in href:
                ota_links.append(href)

        if not ota_links:
            # 方法 2: 直接搜索页面内容
            print("未找到直接链接，尝试搜索页面文本...")
            content_text = page.content()
            all_links = re.findall(
                r'https://dl\.google\.com/dl/android/aosp/[^"\'<>]+\.zip',
                content_text
            )
            for link in all_links:
                if '-ota-' in link:
                    ota_links.append(link)

        print(f"找到 {len(ota_links)} 个 OTA 链接")

        for link in ota_links:
            parsed = parse_ota_url(link)
            if parsed:
                device, build_id, sha = parsed
                if target_device and device != target_device:
                    continue
                ota_entries.append({
                    "device": device,
                    "build_id": build_id,
                    "ota_sha": sha,
                    "url": link,
                })
                print(f"  {device}: {build_id} (SHA: {sha})")

        # 也尝试获取 factory 页面作为补充
        print(f"\n正在打开 Factory 页面: {FACTORY_PAGE_URL}")
        page.goto(FACTORY_PAGE_URL, wait_until="networkidle", timeout=60000)
        page.wait_for_timeout(3000)

        factory_links = []
        for a_tag in page.locator('a[href*="dl.google.com"][href$=".zip"]').all():
            href = a_tag.get_attribute('href')
            if href and href.endswith('.zip') and '-factory-' in href:
                factory_links.append(href)

        if not factory_links:
            content_text = page.content()
            all_links = re.findall(
                r'https://dl\.google\.com/dl/android/aosp/[^"\'<>]+\.zip',
                content_text
            )
            for link in all_links:
                if '-factory-' in link:
                    factory_links.append(link)

        print(f"找到 {len(factory_links)} 个 Factory 链接")

        # 合并 factory 数据（补充 OTA 数据中可能缺失的设备信息）
        factory_devices = {}  # device -> build_id
        for link in factory_links:
            parsed = parse_factory_url(link)
            if parsed:
                device, build_id = parsed
                factory_devices[device] = build_id

        browser.close()

    return ota_entries, factory_devices


def build_devices_json(ota_entries, factory_devices, existing_path=None):
    """构建 devices.json 格式的数据"""
    # 加载现有的 devices.json 来保留旧版本信息
    existing = {}
    if existing_path and os.path.exists(existing_path):
        try:
            with open(existing_path) as f:
                existing = json.load(f).get('devices', {})
            print(f"已加载现有设备数据，包含 {len(existing)} 个设备")
        except (json.JSONDecodeError, KeyError):
            pass

    # 设备中文名映射
    DEVICE_NAMES = {
        "oriole": "Pixel 6",
        "raven": "Pixel 6 Pro",
        "bluejay": "Pixel 6a",
        "panther": "Pixel 7",
        "cheetah": "Pixel 7 Pro",
        "lynx": "Pixel 7a",
        "shiba": "Pixel 8",
        "husky": "Pixel 8 Pro",
        "akita": "Pixel 8a",
        "tokay": "Pixel 9",
        "caiman": "Pixel 9 Pro",
        "komodo": "Pixel 9 Pro XL",
        "comet": "Pixel 9 Pro Fold",
        "felix": "Pixel Fold",
        "tangorpro": "Pixel Tablet",
    }

    # 默认 KMI 映射
    DEFAULT_KMI = {
        "oriole": "android12-5.10",
        "raven": "android12-5.10",
        "bluejay": "android12-5.10",
        "panther": "android13-5.15",
        "cheetah": "android13-5.15",
        "lynx": "android13-5.15",
        "shiba": "android14-6.1",
        "husky": "android14-6.1",
        "akita": "android14-6.1",
        "tokay": "android15-6.6",
        "caiman": "android15-6.6",
        "komodo": "android15-6.6",
        "comet": "android15-6.6",
        "felix": "android14-6.1",
        "tangorpro": "android14-6.1",
    }

    # 默认 Magisk preinit 分区
    DEFAULT_PREINIT = {
        "oriole": "metadata",
        "raven": "metadata",
        "bluejay": "metadata",
        "panther": "metadata",
        "cheetah": "metadata",
        "lynx": "metadata",
        "shiba": "sda10",
        "husky": "sda10",
        "akita": "sda10",
        "tokay": "sda10",
        "caiman": "sda10",
        "komodo": "sda10",
        "comet": "sda10",
        "felix": "sda10",
        "tangorpro": "sda10",
    }

    devices = {}

    # 收集所有 OTA 条目的设备
    devices_from_ota = set()
    for entry in ota_entries:
        d = entry["device"]
        devices_from_ota.add(d)
        if d not in devices:
            devices[d] = {
                "name": DEVICE_NAMES.get(d, d),
                "builds": [],
                "latest_build": entry["build_id"],
                "magisk_preinit": existing.get(d, {}).get("magisk_preinit",
                                                          DEFAULT_PREINIT.get(d, "sda10")),
                "ksu_kmi": existing.get(d, {}).get("ksu_kmi",
                                                    DEFAULT_KMI.get(d, "android14-6.1")),
            }

        # 检查 build 是否已存在
        existing_builds = {b["build_id"]: b for b in devices[d]["builds"]}
        if entry["build_id"] not in existing_builds:
            devices[d]["builds"].append({
                "build_id": entry["build_id"],
                "ota_sha": entry["ota_sha"],
                "date": datetime.now().strftime("%Y-%m"),
            })
        else:
            # 更新 SHA 如果为空
            if not existing_builds[entry["build_id"]].get("ota_sha"):
                existing_builds[entry["build_id"]]["ota_sha"] = entry["ota_sha"]

        # 更新 latest_build 为最新的
        devices[d]["latest_build"] = entry["build_id"]

    # 从 factory 页面补充设备信息（没有 OTA 链接的设备可能可以通过 SHA 推导）
    for device, build_id in factory_devices.items():
        if device not in devices:
            devices[device] = {
                "name": DEVICE_NAMES.get(device, device),
                "builds": [{
                    "build_id": build_id,
                    "ota_sha": "",
                    "date": datetime.now().strftime("%Y-%m"),
                }],
                "latest_build": build_id,
                "magisk_preinit": existing.get(device, {}).get("magisk_preinit",
                                                               DEFAULT_PREINIT.get(device, "sda10")),
                "ksu_kmi": existing.get(device, {}).get("ksu_kmi",
                                                        DEFAULT_KMI.get(device, "android14-6.1")),
            }

    # 保留旧设备数据中那些没有被新数据覆盖的版本信息
    for device, old_data in existing.items():
        if device not in devices:
            # 设备在新数据中没有，保留旧的
            devices[device] = old_data
        else:
            # 在新数据中已有的设备，补充旧版本号（保留历史记录）
            existing_build_ids = {b["build_id"] for b in devices[device]["builds"]}
            for old_build in old_data.get("builds", []):
                if old_build["build_id"] not in existing_build_ids:
                    devices[device]["builds"].append(old_build)

    result = {
        "schema_version": 1,
        "description": "Pixel 设备 OTA 信息数据库。由 fetch_latest_ota.py 自动更新。",
        "updated": datetime.now().strftime("%Y-%m-%d"),
        "devices": dict(sorted(devices.items())),
    }

    return result


def main():
    parser = argparse.ArgumentParser(description="抓取 Pixel OTA 下载链接")
    parser.add_argument("--output", "-o", help="输出文件路径 (devices.json)")
    parser.add_argument("--device", "-d", help="仅查询指定设备（如 shiba）")
    parser.add_argument("--headless", action="store_true", default=True,
                        help="使用 headless 模式（默认开启）")
    parser.add_argument("--headed", action="store_true",
                        help="显示浏览器窗口（调试用）")
    args = parser.parse_args()

    headless = not args.headed

    print("rooted-pixel OTA 抓取工具")
    print(f"目标设备: {args.device or '全部'}")
    print()

    ota_entries, factory_devices = scrape_with_playwright(
        output=args.output,
        target_device=args.device,
        headless=headless
    )

    if not ota_entries and not factory_devices:
        print("\n未从页面中找到任何下载链接。")
        print("可能原因:")
        print("  1. Google 页面结构已变更")
        print("  2. 网络连接问题")
        print("  3. Playwright 浏览器启动失败")
        sys.exit(1)

    # 构建 JSON 数据
    data = build_devices_json(ota_entries, factory_devices, args.output)

    device_count = len(data["devices"])
    build_count = sum(len(d["builds"]) for d in data["devices"].values())
    print(f"\n总设备数: {device_count}")
    print(f"总构建数: {build_count}")

    if args.output:
        with open(args.output, 'w') as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        print(f"\n已写入 {args.output}")
    else:
        # 输出到 stdout
        json.dump(data, sys.stdout, indent=2, ensure_ascii=False)

    # 如果指定了设备，打印设备概要
    if args.device and args.device in data["devices"]:
        info = data["devices"][args.device]
        print(f"\n设备 {args.device} ({info['name']}) 概要:")
        print(f"  最新版本: {info['latest_build']}")
        for b in info["builds"]:
            sha_info = f" (SHA: {b['ota_sha']})" if b.get("ota_sha") else " (SHA: 未知)"
            print(f"  - {b['build_id']}{sha_info}")
        print(f"  KMI: {info.get('ksu_kmi', '未设置')}")
        print(f"  Magisk preinit: {info.get('magisk_preinit', '未设置')}")


if __name__ == "__main__":
    main()
