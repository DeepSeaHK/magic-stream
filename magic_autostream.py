#!/usr/bin/env python3
# magic_autostream.py - 自動轉播推流 (YouTube API)

import argparse
import datetime
import os
import subprocess
import sys
import time

from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
AUTH_DIR = os.path.join(BASE_DIR, "youtube_auth")
CLIENT_SECRETS_FILE = os.path.join(AUTH_DIR, "client_secret.json")
TOKEN_FILE = os.path.join(AUTH_DIR, "token.json")

SCOPES = ["https://www.googleapis.com/auth/youtube.force-ssl"]


def get_youtube_service():
    if not os.path.exists(TOKEN_FILE):
        print(f"未找到 token.json：{TOKEN_FILE}")
        sys.exit(1)

    creds = Credentials.from_authorized_user_file(TOKEN_FILE, SCOPES)
    if not creds.valid:
        if creds.expired and creds.refresh_token:
            creds.refresh(Request())
            with open(TOKEN_FILE, "w", encoding="utf-8") as f:
                f.write(creds.to_json())
        else:
            print("token 無效且無法刷新，請重新生成 token.json。")
            sys.exit(1)

    return build("youtube", "v3", credentials=creds)


def create_stream(youtube, title: str):
    body = {
        "snippet": {"title": f"{title} Stream"},
        "cdn": {
            "resolution": "1080p",
            "frameRate": "30fps",
            "ingestionType": "rtmp",
        },
        "contentDetails": {"isReusable": True},
    }
    request = youtube.liveStreams().insert(
        part="snippet,cdn,contentDetails",
        body=body,
    )
    return request.execute()


def create_broadcast(youtube, title: str):
    start_time = (datetime.datetime.utcnow() + datetime.timedelta(seconds=30)).isoformat("T") + "Z"
    body = {
        "snippet": {
            "title": title,
            "scheduledStartTime": start_time,
        },
        "status": {
            "privacyStatus": "public",
        },
        "contentDetails": {
            "monitorStream": {"enableMonitorStream": True},
        },
    }
    request = youtube.liveBroadcasts().insert(
        part="snippet,contentDetails,status",
        body=body,
    )
    return request.execute()


def bind_broadcast_stream(youtube, broadcast_id: str, stream_id: str):
    request = youtube.liveBroadcasts().bind(
        part="id,contentDetails",
        id=broadcast_id,
        streamId=stream_id,
    )
    return request.execute()


def complete_broadcast(youtube, broadcast_id: str):
    try:
        youtube.liveBroadcasts().transition(
            part="status",
            id=broadcast_id,
            broadcastStatus="complete",
        ).execute()
        print(f"[YouTube] 已將直播 {broadcast_id} 標記為 complete")
    except HttpError as e:
        print(f"[YouTube] 標記 complete 失敗：{e}")


def check_source_online(source_url: str) -> bool:
    # 用 ffprobe 檢測源是否在線
    try:
        cmd = [
            "ffprobe",
            "-v", "error",
            "-show_streams",
            "-timeout", "5000000",
            "-rw_timeout", "5000000",
            source_url,
        ]
        result = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return result.returncode == 0
    except FileNotFoundError:
        print("未找到 ffprobe，請先安裝 ffmpeg。")
        sys.exit(1)


def run_ffmpeg(source_url: str, rtmp_url: str) -> int:
    cmd = [
        "ffmpeg",
        "-reconnect", "1",
        "-reconnect_streamed", "1",
        "-reconnect_delay_max", "5",
        "-i", source_url,
        "-c:v", "copy",
        "-c:a", "copy",
        "-f", "flv",
        rtmp_url,
    ]
    print("[ffmpeg] 啟動推流：", " ".join(cmd))
    proc = subprocess.Popen(cmd)
    proc.wait()
    print("[ffmpeg] 退出，返回碼：", proc.returncode)
    return proc.returncode


def main():
    parser = argparse.ArgumentParser(description="Magic Stream 自動轉播推流 (YouTube API)")
    parser.add_argument("--source-url", required=True, help="抖音等平台的直播源地址")
    parser.add_argument("--title", default="Magic Stream Live", help="YouTube 直播間標題")
    parser.add_argument(
        "--reconnect-seconds",
        type=int,
        default=300,
        help="掉線阈值（秒），小於此值視為同一場，大於則下一次開播新建一場",
    )
    args = parser.parse_args()

    youtube = get_youtube_service()
    last_end_time = None
    current_broadcast_id = None

    print("=== Magic Stream 自動推流啟動 ===")
    print(f"直播源：{args.source_url}")
    print(f"默認標題：{args.title}")
    print(f"掉線阈值：{args.reconnect_seconds} 秒")
    print("等待直播源上線...")

    while True:
        # 等待直播源上線
        while not check_source_online(args.source_url):
            print("[源檢測] 尚未檢測到信號，10 秒後重試...")
            time.sleep(10)

        now = datetime.datetime.utcnow()
        if last_end_time is None:
            new_session = True
        else:
            diff = (now - last_end_time).total_seconds()
            new_session = diff > args.reconnect_seconds

        if new_session:
            print("[YouTube] 創建新的直播事件和推流流...")
            stream = create_stream(youtube, args.title)
            broadcast = create_broadcast(youtube, args.title)
            bind_broadcast_stream(youtube, broadcast["id"], stream["id"])
            current_broadcast_id = broadcast["id"]

            ingestion = stream["cdn"]["ingestionInfo"]
            rtmp_url = ingestion["ingestionAddress"].rstrip("/") + "/" + ingestion["streamName"]
            print(f"[YouTube] RTMP 推流地址：{rtmp_url}")
        else:
            # 這裡為了簡化，掉線也重新建一場，避免狀態混亂
            print("[YouTube] 視為掉線重連，但為穩定起見仍新建一場直播。")
            stream = create_stream(youtube, args.title)
            broadcast = create_broadcast(youtube, args.title)
            bind_broadcast_stream(youtube, broadcast["id"], stream["id"])
            current_broadcast_id = broadcast["id"]
            ingestion = stream["cdn"]["ingestionInfo"]
            rtmp_url = ingestion["ingestionAddress"].rstrip("/") + "/" + ingestion["streamName"]
            print(f"[YouTube] 新 RTMP 推流地址：{rtmp_url}")

        start_time = datetime.datetime.utcnow()
        run_ffmpeg(args.source_url, rtmp_url)
        end_time = datetime.datetime.utcnow()
        last_end_time = end_time

        duration = (end_time - start_time).total_seconds()
        print(f"[Info] 本次推流持續 {int(duration)} 秒。")

        if current_broadcast_id:
            complete_broadcast(youtube, current_broadcast_id)
            current_broadcast_id = None

        print(f"[Info] 等待下一次直播源上線（阈值 {args.reconnect_seconds} 秒）...")


if __name__ == "__main__":
    main()
