#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Magic Stream 自動轉播腳本 v0.7.0
功能：探針偵測、斷線重連、自定義隱私狀態、純文件認證模式
"""

import argparse
import datetime
import os
import shutil
import subprocess
import sys
import time
from typing import Tuple

from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request

# 權限範圍
SCOPES = ["https://www.googleapis.com/auth/youtube"]

def load_credentials(auth_dir: str) -> Credentials:
    """
    從 auth_dir 載入 token.json。
    注意：此版本僅支持讀取已存在的 token，不支持交互式登錄。
    """
    token_path = os.path.join(auth_dir, "token.json")
    
    if not os.path.exists(token_path):
        print(f"[致命錯誤] 找不到憑證文件：{token_path}")
        print("請在本地電腦生成 token.json 後上傳至 VPS。")
        sys.exit(1)

    creds = None
    try:
        creds = Credentials.from_authorized_user_file(token_path, SCOPES)
    except Exception as e:
        print(f"[致命錯誤] token.json 格式錯誤或損壞：{e}")
        sys.exit(1)

    if creds and creds.expired and creds.refresh_token:
        try:
            print("[INFO] Token 已過期，正在刷新...")
            creds.refresh(Request())
            # 刷新成功後寫回文件
            with open(token_path, "w", encoding="utf-8") as f:
                f.write(creds.to_json())
            print("[OK] Token 刷新成功。")
        except Exception as e:
            print(f"[致命錯誤] 無法刷新 Token (可能 Refresh Token 已失效)：{e}")
            sys.exit(1)

    if not creds or not creds.valid:
        print("[致命錯誤] 憑證無效。")
        sys.exit(1)

    return creds

def get_youtube_service(auth_dir: str):
    creds = load_credentials(auth_dir)
    return build("youtube", "v3", credentials=creds)

def create_broadcast_and_stream(youtube, title: str, privacy: str) -> Tuple[str, str, str]:
    """
    建立直播並回傳 ID 與 推流地址。
    privacy: public / unlisted / private
    """
    # 修正 datetime 警告，使用帶時區的時間
    now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")

    print(f"[API] 建立 Broadcast (標題: {title}, 隱私: {privacy})...")
    broadcast = youtube.liveBroadcasts().insert(
        part="snippet,status,contentDetails",
        body={
            "snippet": {
                "title": title,
                "scheduledStartTime": now,
            },
            "status": {
                "privacyStatus": privacy,
                "selfDeclaredMadeForKids": False,
            },
            "contentDetails": {
                "monitorStream": {"enableMonitorStream": False},
                "enableAutoStart": True,
                "enableAutoStop": True,
            },
        },
    ).execute()
    broadcast_id = broadcast["id"]
    print(f"[OK] Broadcast ID: {broadcast_id}")

    print("[API] 建立 LiveStream...")
    stream = youtube.liveStreams().insert(
        part="snippet,cdn,contentDetails",
        body={
            "snippet": {"title": title},
            "cdn": {
                "frameRate": "variable",
                "resolution": "variable",
                "ingestionType": "rtmp",
            },
            "contentDetails": {"isReusable": False},
        },
    ).execute()
    stream_id = stream["id"]
    print(f"[OK] Stream ID: {stream_id}")

    print("[API] 綁定 Broadcast 與 Stream...")
    youtube.liveBroadcasts().bind(
        part="id,contentDetails",
        id=broadcast_id,
        streamId=stream_id,
    ).execute()

    ingestion = stream["cdn"]["ingestionInfo"]
    rtmp_url = f"{ingestion['ingestionAddress']}/{ingestion['streamName']}"

    print(f"[OK] 推流地址獲取成功。")
    return broadcast_id, stream_id, rtmp_url

def complete_broadcast(youtube, broadcast_id: str):
    try:
        print(f"[API] 正在結束直播 {broadcast_id} ...")
        youtube.liveBroadcasts().transition(
            broadcastStatus="complete",
            id=broadcast_id,
            part="status",
        ).execute()
        print("[OK] 直播已設為 Complete。")
    except HttpError as e:
        print(f"[警告] 結束直播時 API 報錯：{e}")

def probe_source_once(source_url: str, timeout: int = 25) -> bool:
    cmd = [
        "ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height", "-of", "csv=p=0",
        source_url
    ]
    try:
        proc = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=timeout)
        return proc.returncode == 0
    except Exception:
        return False

def wait_until_source_online(source_url: str, interval: int = 30):
    print(f"[探針] 正在偵測信號: {source_url}")
    while True:
        if probe_source_once(source_url):
            print("[探針] 信號已上線！")
            return
        print(f"[探針] 無信號，{interval}秒後重試...")
        time.sleep(interval)

def wait_source_back_within(source_url: str, max_wait: int, interval: int = 30) -> bool:
    deadline = time.time() + max_wait
    while time.time() < deadline:
        if probe_source_once(source_url):
            print("[探針] 信號已恢復。")
            return True
        print(f"[探針] 等待恢復... (剩餘 {int(deadline - time.time())}秒)")
        time.sleep(interval)
    print("[探針] 超時未恢復，放棄本場直播。")
    return False

def run_ffmpeg_once(source_url: str, rtmp_url: str) -> int:
    # 檢查 ffmpeg
    if not shutil.which("ffmpeg"):
        print("[錯誤] 系統找不到 ffmpeg，請確認已安裝。")
        return 1

    cmd = [
        "ffmpeg", "-loglevel", "warning", "-re",
        "-i", source_url,
        "-c", "copy", "-f", "flv", rtmp_url
    ]
    print("[FFmpeg] 啟動推流...")
    proc = subprocess.Popen(cmd)
    try:
        proc.wait()
    except KeyboardInterrupt:
        proc.terminate()
        proc.wait()
    return proc.returncode

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-url", required=True)
    parser.add_argument("--title", required=True)
    parser.add_argument("--privacy", default="unlisted", help="public, unlisted, private")
    parser.add_argument("--reconnect-seconds", type=int, default=300)
    parser.add_argument("--auth-dir", default="youtube_auth")
    args = parser.parse_args()

    print("==========================================")
    print(" Magic Stream Auto - v0.7.0")
    print("==========================================")
    print(f" Source  : {args.source_url}")
    print(f" Title   : {args.title}")
    print(f" Privacy : {args.privacy}")
    print("------------------------------------------")

    youtube = get_youtube_service(args.auth_dir)

    while True:
        wait_until_source_online(args.source_url)

        try:
            broadcast_id, stream_id, rtmp_url = create_broadcast_and_stream(
                youtube, args.title, args.privacy
            )
        except Exception as e:
            print(f"[錯誤] 建立直播失敗: {e}")
            time.sleep(30)
            continue

        same_broadcast = True
        while same_broadcast:
            run_ffmpeg_once(args.source_url, rtmp_url)
            
            # FFmpeg 退出後，檢查是否能在限時內恢復
            if wait_source_back_within(args.source_url, args.reconnect_seconds):
                print("[INFO] 嘗試重連回同一場直播...")
                continue
            else:
                complete_broadcast(youtube, broadcast_id)
                same_broadcast = False

        print("[守候] 本場結束，進入待命狀態...")

if __name__ == "__main__":
    main()
