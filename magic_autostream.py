#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Magic Stream 自動轉播腳本 v0.7.5 (Ultra Optimized - Stream Copy)
"""

import argparse
import datetime
import os
import shutil
import subprocess
import sys
import time
import requests
import uuid
import hashlib
from typing import Tuple

from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request

# 授權地址保持不變
LICENSE_URL = "https://gist.githubusercontent.com/DeepSeaHK/ba229af821aeae0d7501047523589ab5/raw/whitelist.txt"

def get_machine_code():
    node = uuid.getnode()
    mac = ':'.join(['{:02x}'.format((node >> ele) & 0xff) for ele in range(0,8*6,8)][::-1])
    signature = f"magic_stream_{mac}_v1"
    return hashlib.md5(signature.encode()).hexdigest()

def verify_license(silent=False):
    code = get_machine_code()
    if not silent:
        print(f"[系統] 本機機器碼: \033[33m{code}\033[0m") 
    try:
        resp = requests.get(LICENSE_URL, timeout=10)
        allowed_codes = [line.strip() for line in resp.text.splitlines() if line.strip()]
        if code in allowed_codes:
            if not silent: print("\033[32m[驗證成功] 正版授權已激活！\033[0m")
            return True
        else:
            if not silent: print("\033[31m[驗證失敗] 此機器未獲得授權！\033[0m")
            sys.exit(1)
    except Exception as e:
        if not silent: print(f"[錯誤] 驗證異常: {e}")
        sys.exit(1)

SCOPES = ["https://www.googleapis.com/auth/youtube"]

def load_credentials(auth_dir: str):
    token_path = os.path.join(auth_dir, "token.json")
    if not os.path.exists(token_path): sys.exit(1)
    creds = Credentials.from_authorized_user_file(token_path, SCOPES)
    if creds and creds.expired and creds.refresh_token:
        creds.refresh(Request())
    return creds

def get_youtube_service(auth_dir: str):
    creds = load_credentials(auth_dir)
    return build("youtube", "v3", credentials=creds)

def create_broadcast_and_stream(youtube, title: str, privacy: str):
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
    
    stream = youtube.liveStreams().insert(
        part="snippet,cdn,contentDetails",
        body={
            "snippet": {"title": title},
            "cdn": {"frameRate": "variable", "resolution": "variable", "ingestionType": "rtmp"},
            "contentDetails": {"isReusable": False},
        },
    ).execute()
    
    youtube.liveBroadcasts().bind(
        part="id,contentDetails",
        id=broadcast["id"],
        streamId=stream["id"],
    ).execute()

    ingestion = stream["cdn"]["ingestionInfo"]
    rtmp_url = f"{ingestion['ingestionAddress']}/{ingestion['streamName']}"
    return broadcast["id"], stream["id"], rtmp_url

def probe_source_once(source_url: str, timeout: int = 25) -> bool:
    # 增加 UA 偽裝，防止探測失敗
    cmd = [
        "ffprobe", "-v", "error", 
        "-user_agent", "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1",
        "-headers", "Referer: https://live.douyin.com/",
        "-select_streams", "v:0", "-show_entries", "stream=width", "-of", "csv=p=0", source_url
    ]
    try:
        return subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=timeout).returncode == 0
    except:
        return False

def wait_until_source_online(source_url: str, interval: int = 30):
    print(f"[探針] 偵測信號中...")
    while True:
        if probe_source_once(source_url):
            print("[探針] 信號已上線！")
            return
        time.sleep(interval)

def run_ffmpeg_once(source_url: str, rtmp_url: str) -> int:
    if not shutil.which("ffmpeg"): return 1
    
    # =================【关键修改】=================
    # 强制使用 Copy 模式 + 伪装头，与 Shell 脚本保持一致的流畅度
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel", "error",
        "-user_agent", "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1",
        "-headers", "Referer: https://live.douyin.com/",
        "-rw_timeout", "10000000",
        "-i", source_url,
        "-c", "copy",  # 核心：直接流复制，不转码
        "-f", "flv",
        rtmp_url
    ]
    # ============================================

    proc = subprocess.Popen(cmd)
    try:
        proc.wait()
    except KeyboardInterrupt:
        proc.terminate()
    return proc.returncode

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check-license", action="store_true")
    parser.add_argument("--source-url")
    parser.add_argument("--title")
    parser.add_argument("--privacy", default="unlisted")
    parser.add_argument("--reconnect-seconds", type=int, default=300)
    parser.add_argument("--auth-dir", default="youtube_auth")
    args = parser.parse_args()

    if args.check_license:
        verify_license(silent=True)
        sys.exit(0)

    verify_license(silent=False)

    if not args.source_url or not args.title:
        print("參數錯誤。")
        sys.exit(1)

    print("==========================================")
    print(" Magic Stream Auto - v0.7.5 (Ultra)")
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
            # 這裡調用的就是優化後的 FFmpeg 命令
            run_ffmpeg_once(args.source_url, rtmp_url)
            # 簡單的重連邏輯
            print("[系統] 推流中斷，嘗試重連...")
            time.sleep(5)
            # 如果源還在，繼續推同一個直播；如果源沒了，退出循環重建直播
            if probe_source_once(args.source_url):
                continue
            else:
                same_broadcast = False

if __name__ == "__main__":
    main()