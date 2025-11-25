#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Magic Stream 自動轉播腳本 v0.7.2 (授权验证版)
集成在线机器码验证与防破解逻辑
"""

import argparse
import datetime
import os
import shutil
import subprocess
import sys
import time
import requests  # 必須安裝: pip install requests
import uuid
import hashlib
from typing import Tuple

from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request

# ==========================================
#  🔴 授权验证配置 (已自动修复为最新版链接)
# ==========================================
# 这里使用的是去掉了 commit hash 的干净链接，确保始终读取 Gist 的最新内容
LICENSE_URL = "https://gist.githubusercontent.com/DeepSeaHK/ba229af821aeae0d7501047523589ab5/raw/whitelist.txt"
# ==========================================

def get_machine_code():
    """生成唯一机器码 (MAC + 盐值)"""
    node = uuid.getnode()
    mac = ':'.join(['{:02x}'.format((node >> ele) & 0xff) for ele in range(0,8*6,8)][::-1])
    # 这里的 magic_stream_..._v1 是盐值，防止被轻易反推
    signature = f"magic_stream_{mac}_v1"
    return hashlib.md5(signature.encode()).hexdigest()

def verify_license():
    """联网验证核心逻辑"""
    code = get_machine_code()
    print("-" * 50)
    print(f"[系統] 正在驗證授權許可...")
    # 這裡用黃色高亮顯示機器碼，方便客戶複製
    print(f"[系統] 本機機器碼: \033[33m{code}\033[0m") 

    try:
        # 设置 10 秒超时，避免网络不好卡住
        resp = requests.get(LICENSE_URL, timeout=10)
        
        if resp.status_code != 200:
            print(f"[錯誤] 無法連接授權服務器 (Status: {resp.status_code})")
            print("請檢查 VPS 網絡連接。")
            sys.exit(1)
            
        # 核心判斷：Gist 内容里是否包含本机机器码
        if code in resp.text:
            print("\033[32m[驗證成功] 正版授權已激活！\033[0m")
            print("-" * 50)
            return True
        else:
            print("\n\033[31m[驗證失敗] 此機器未獲得授權！\033[0m")
            print(f"請複製上方黃色機器碼發送給管理員開通。")
            print("-" * 50)
            sys.exit(1)
            
    except Exception as e:
        print(f"[錯誤] 驗證過程發生異常: {e}")
        sys.exit(1)

# ---------------- 下面是原有的轉播功能代碼 ----------------

SCOPES = ["https://www.googleapis.com/auth/youtube"]

def load_credentials(auth_dir: str) -> Credentials:
    token_path = os.path.join(auth_dir, "token.json")
    if not os.path.exists(token_path):
        print(f"[致命錯誤] 找不到憑證文件：{token_path}")
        sys.exit(1)
    try:
        creds = Credentials.from_authorized_user_file(token_path, SCOPES)
    except Exception as e:
        print(f"[致命錯誤] token.json 損壞：{e}")
        sys.exit(1)
    if creds and creds.expired and creds.refresh_token:
        try:
            creds.refresh(Request())
            with open(token_path, "w", encoding="utf-8") as f:
                f.write(creds.to_json())
        except Exception:
            print(f"[致命錯誤] Token 刷新失敗。")
            sys.exit(1)
    return creds

def get_youtube_service(auth_dir: str):
    creds = load_credentials(auth_dir)
    return build("youtube", "v3", credentials=creds)

def create_broadcast_and_stream(youtube, title: str, privacy: str) -> Tuple[str, str, str]:
    # 修正时间格式
    now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
    print(f"[API] 建立直播: {title} ({privacy})")
    
    broadcast = youtube.liveBroadcasts().insert(
        part="snippet,status,contentDetails",
        body={
            "snippet": {"title": title, "scheduledStartTime": now},
            "status": {"privacyStatus": privacy, "selfDeclaredMadeForKids": False},
            "contentDetails": {
                "monitorStream": {"enableMonitorStream": False},
                "enableAutoStart": True, "enableAutoStop": True
            },
        },
    ).execute()
    broadcast_id = broadcast["id"]

    stream = youtube.liveStreams().insert(
        part="snippet,cdn,contentDetails",
        body={
            "snippet": {"title": title},
            "cdn": {"frameRate": "variable", "resolution": "variable", "ingestionType": "rtmp"},
            "contentDetails": {"isReusable": False},
        },
    ).execute()
    stream_id = stream["id"]

    youtube.liveBroadcasts().bind(
        part="id,contentDetails",
        id=broadcast_id,
        streamId=stream_id,
    ).execute()

    ingestion = stream["cdn"]["ingestionInfo"]
    rtmp_url = f"{ingestion['ingestionAddress']}/{ingestion['streamName']}"
    return broadcast_id, stream_id, rtmp_url

def complete_broadcast(youtube, broadcast_id: str):
    try:
        youtube.liveBroadcasts().transition(
            broadcastStatus="complete", id=broadcast_id, part="status"
        ).execute()
        print("[API] 直播已結束並存檔。")
    except HttpError:
        pass

def probe_source_once(source_url: str, timeout: int = 25) -> bool:
    cmd = ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width", "-of", "csv=p=0", source_url]
    try:
        return subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=timeout).returncode == 0
    except Exception:
        return False

def wait_until_source_online(source_url: str, interval: int = 30):
    print(f"[探針] 偵測信號中...")
    while True:
        if probe_source_once(source_url):
            print("[探針] 信號已上線！")
            return
        time.sleep(interval)

def wait_source_back_within(source_url: str, max_wait: int) -> bool:
    deadline = time.time() + max_wait
    while time.time() < deadline:
        if probe_source_once(source_url):
            return True
        time.sleep(10)
    return False

def run_ffmpeg_once(source_url: str, rtmp_url: str) -> int:
    if not shutil.which("ffmpeg"):
        print("[錯誤] 未安裝 ffmpeg。")
        return 1
    cmd = ["ffmpeg", "-loglevel", "warning", "-re", "-i", source_url, "-c", "copy", "-f", "flv", rtmp_url]
    proc = subprocess.Popen(cmd)
    try:
        proc.wait()
    except KeyboardInterrupt:
        proc.terminate()
    return proc.returncode

def main():
    # 🔴 启动时首先进行验证
    verify_license()

    parser = argparse.ArgumentParser()
    parser.add_argument("--source-url", required=True)
    parser.add_argument("--title", required=True)
    parser.add_argument("--privacy", default="unlisted")
    parser.add_argument("--reconnect-seconds", type=int, default=300)
    parser.add_argument("--auth-dir", default="youtube_auth")
    args = parser.parse_args()

    print("==========================================")
    print(" Magic Stream Auto - v0.7.2")
    print("==========================================")

    youtube = get_youtube_service(args.auth_dir)

    while True:
        wait_until_source_online(args.source_url)
        try:
            broadcast_id, stream_id, rtmp_url = create_broadcast_and_stream(youtube, args.title, args.privacy)
        except Exception as e:
            print(f"[錯誤] {e}")
            time.sleep(30)
            continue

        same_broadcast = True
        while same_broadcast:
            run_ffmpeg_once(args.source_url, rtmp_url)
            if wait_source_back_within(args.source_url, args.reconnect_seconds):
                continue
            else:
                complete_broadcast(youtube, broadcast_id)
                same_broadcast = False
        print("[守候] 等待下一次開播...")

if __name__ == "__main__":
    main()
