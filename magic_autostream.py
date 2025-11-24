#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Magic Stream 自動轉播腳本

功能：
1. 使用 YouTube Data API 自動建立直播流 & 直播間
2. 從指定直播源（例如抖音 FLV）拉流，轉推到 YouTube RTMP
3. 探針機制：
   - ffmpeg 出錯時，每隔 reconnect_seconds 重試
   - 如果累計離線時間超過 offline_seconds（>0），則視為本次直播結束並退出
   - offline_seconds = 0 表示永不放棄，持續重試

依賴：
  pip install --upgrade google-api-python-client google-auth-httplib2 google-auth-oauthlib
"""

import argparse
import datetime
import os
import sys
import time
import subprocess
from typing import Tuple

from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from google_auth_oauthlib.flow import InstalledAppFlow
from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request

SCOPES = ["https://www.googleapis.com/auth/youtube"]


def log(msg: str) -> None:
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{now}] {msg}", flush=True)


def get_youtube(auth_dir: str):
    os.makedirs(auth_dir, exist_ok=True)
    client_secret = os.path.join(auth_dir, "client_secret.json")
    token_file = os.path.join(auth_dir, "token.json")

    if not os.path.exists(client_secret):
        log(f"ERROR: 找不到 client_secret.json：{client_secret}")
        sys.exit(1)

    creds = None
    if os.path.exists(token_file):
        creds = Credentials.from_authorized_user_file(token_file, SCOPES)

    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            log("刷新 YouTube 憑證中...")
            creds.refresh(Request())
        else:
            log("首次授權，請在彈出的瀏覽器中同意存取 YouTube 帳號。")
            flow = InstalledAppFlow.from_client_secrets_file(client_secret, SCOPES)
            # 本地埠自動生成
            creds = flow.run_local_server(port=0, prompt="consent")

        with open(token_file, "w", encoding="utf-8") as f:
            f.write(creds.to_json())
            log(f"已更新 token.json：{token_file}")

    youtube = build("youtube", "v3", credentials=creds, cache_discovery=False)
    return youtube


def create_stream(youtube, title: str) -> Tuple[str, str]:
    """建立 liveStream 並返回 (stream_id, rtmp_url)."""
    body = {
        "snippet": {"title": title},
        "cdn": {
            "ingestionType": "rtmp",
            "resolution": "variable",
            "frameRate": "variable",
        },
        "contentDetails": {},
    }
    resp = youtube.liveStreams().insert(
        part="snippet,cdn,contentDetails", body=body
    ).execute()

    stream_id = resp["id"]
    ingestion = resp["cdn"]["ingestionInfo"]
    ingestion_addr = ingestion["ingestionAddress"]
    stream_name = ingestion["streamName"]
    rtmp_url = f"{ingestion_addr}/{stream_name}"

    log(f"已建立 liveStream: {stream_id}")
    log(f"RTMP 推流地址：{rtmp_url}")
    return stream_id, rtmp_url


def create_broadcast(youtube, title: str, stream_id: str) -> str:
    """建立 liveBroadcast 並綁定 stream，返回 broadcast_id。"""
    now = datetime.datetime.utcnow()
    # 預定開始時間：現在 + 1 分鐘
    start_time = (now + datetime.timedelta(minutes=1)).isoformat("T") + "Z"

    body = {
        "snippet": {
            "title": title,
            "scheduledStartTime": start_time,
        },
        "status": {
            "privacyStatus": "unlisted",
        },
        "contentDetails": {
            "monitorStream": {"enableMonitorStream": True}
        },
    }

    resp = youtube.liveBroadcasts().insert(
        part="snippet,contentDetails,status", body=body
    ).execute()

    broadcast_id = resp["id"]
    log(f"已建立 liveBroadcast: {broadcast_id}")

    youtube.liveBroadcasts().bind(
        id=broadcast_id, part="id,contentDetails", streamId=stream_id
    ).execute()
    log("已綁定 broadcast 與 stream。")

    return broadcast_id


def transition_broadcast(youtube, broadcast_id: str, status: str) -> None:
    """切換直播狀態：testing / live / complete。"""
    try:
        youtube.liveBroadcasts().transition(
            broadcastStatus=status, id=broadcast_id, part="status"
        ).execute()
        log(f"已切換 broadcast 狀態為：{status}")
    except HttpError as e:
        log(f"切換 broadcast 狀態失敗（{status}）：{e}")


def relay_forever(
    source_url: str,
    rtmp_url: str,
    reconnect_seconds: int,
    offline_seconds: int,
) -> None:
    """
    探針 + 重試：
      - ffmpeg 退出後，等待 reconnect_seconds 再重試
      - 累計離線超過 offline_seconds（>0）就停止
    """
    log(f"開始轉播：source={source_url}")
    log(
        f"重試間隔：{reconnect_seconds}s，"
        f"最大離線時間：{'無上限' if offline_seconds <= 0 else str(offline_seconds) + 's'}"
    )

    offline_accum = 0

    while True:
        cmd = [
            "ffmpeg",
            "-reconnect", "1",
            "-reconnect_streamed", "1",
            "-reconnect_delay_max", "30",
            "-i", source_url,
            "-c:v", "copy",
            "-c:a", "copy",
            "-f", "flv",
            rtmp_url,
        ]

        log("啟動 ffmpeg： " + " ".join(cmd))
        try:
            proc = subprocess.run(cmd)
            code = proc.returncode
        except KeyboardInterrupt:
            log("收到 Ctrl+C，停止轉播。")
            break

        log(f"ffmpeg 已退出，返回碼：{code}")

        if offline_seconds > 0 and offline_accum >= offline_seconds:
            log(
                f"累計離線時間已達 {offline_accum}s ≥ {offline_seconds}s，"
                "視為本次直播結束，不再重試。"
            )
            break

        log(f"{reconnect_seconds}s 後重試拉流 ...")
        time.sleep(reconnect_seconds)
        offline_accum += reconnect_seconds


def parse_args():
    parser = argparse.ArgumentParser(
        description="Magic Stream 自動轉播（YouTube API）"
    )
    parser.add_argument(
        "--source-url",
        required=True,
        help="直播源地址（例如抖音 FLV 播放地址）",
    )
    parser.add_argument(
        "--title",
        default=None,
        help="YouTube 直播標題（留空則自動以時間生成）",
    )
    parser.add_argument(
        "--reconnect-seconds",
        type=int,
        default=60,
        help="ffmpeg 退出後的重試間隔秒數（預設 60）",
    )
    parser.add_argument(
        "--offline-seconds",
        type=int,
        default=0,
        help="源離線多久後放棄本次直播（0 = 永不放棄，預設 0）",
    )
    parser.add_argument(
        "--auth-dir",
        default=os.path.join(os.path.dirname(__file__), "youtube_auth"),
        help="client_secret.json / token.json 所在目錄（預設為腳本同層的 youtube_auth）",
    )
    return parser.parse_args()


def main():
    args = parse_args()

    if not args.title:
        args.title = datetime.datetime.now().strftime("Magic Stream %Y-%m-%d %H:%M")

    log("==== Magic Stream 自動轉播啟動 ====")
    log(f"使用標題：{args.title}")
    log(f"Auth 目錄：{args.auth_dir}")

    youtube = get_youtube(args.auth_dir)

    stream_id, rtmp_url = create_stream(youtube, args.title)
    broadcast_id = create_broadcast(youtube, args.title, stream_id)

    # 先進入 testing，再進入 live（如果失敗就忽略，讓 YouTube 自己處理）
    transition_broadcast(youtube, broadcast_id, "testing")
    time.sleep(5)
    transition_broadcast(youtube, broadcast_id, "live")

    try:
        relay_forever(
            source_url=args.source_url,
            rtmp_url=rtmp_url,
            reconnect_seconds=args.reconnect_seconds,
            offline_seconds=args.offline_seconds,
        )
    finally:
        # 嘗試優雅結束直播
        log("準備結束 broadcast ...")
        transition_broadcast(youtube, broadcast_id, "complete")
        log("==== Magic Stream 自動轉播結束 ====")


if __name__ == "__main__":
    main()
