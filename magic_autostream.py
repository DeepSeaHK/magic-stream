#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError

SCOPES = ["https://www.googleapis.com/auth/youtube.force-ssl"]


def log(msg: str) -> None:
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{now}] {msg}", flush=True)


def get_youtube(auth_dir: str):
    token_path = os.path.join(auth_dir, "token.json")
    if not os.path.exists(token_path):
        raise RuntimeError(f"找不到 token.json: {token_path}")

    creds = Credentials.from_authorized_user_file(token_path, SCOPES)
    return build("youtube", "v3", credentials=creds)


def create_broadcast_and_stream(youtube, title: str, privacy_status: str = "unlisted"):
    """建立一場新的直播 + 推流串流，並回傳 (broadcast_id, rtmp_url)"""
    now = datetime.now(timezone.utc).isoformat()

    log("建立 YouTube 直播 broadcast ...")
    b_req = youtube.liveBroadcasts().insert(
        part="snippet,contentDetails,status",
        body={
            "snippet": {
                "title": title,
                "scheduledStartTime": now,
            },
            "status": {"privacyStatus": privacy_status},
            "contentDetails": {
                "monitorStream": {"enableMonitorStream": True}
            },
        },
    )
    broadcast = b_req.execute()
    broadcast_id = broadcast["id"]

    log("建立 YouTube 推流 liveStream ...")
    s_req = youtube.liveStreams().insert(
        part="snippet,cdn",
        body={
            "snippet": {"title": title},
            "cdn": {
                "frameRate": "30fps",
                "ingestionType": "rtmp",
                "resolution": "variable",
            },
        },
    )
    stream = s_req.execute()
    stream_id = stream["id"]

    log("綁定 broadcast 與 liveStream ...")
    youtube.liveBroadcasts().bind(
        part="id,contentDetails",
        id=broadcast_id,
        streamId=stream_id,
    ).execute()

    ingestion = stream["cdn"]["ingestionInfo"]
    rtmp_url = f"{ingestion['ingestionAddress']}/{ingestion['streamName']}"

    log(f"建立完成，broadcast_id={broadcast_id}")
    log(f"RTMP 推流地址: {rtmp_url}")
    return broadcast_id, rtmp_url


def wait_for_source_online(source_url: str, check_interval: int):
    """循環探測直播源是否可用，直到成功為止"""
    while True:
        log(f"檢查直播源是否在線: {source_url}")
        # 用 ffmpeg 探測 3 秒，如果成功返回 0，代表源可讀
        cmd = [
            "ffmpeg",
            "-v",
            "error",
            "-t",
            "3",
            "-i",
            source_url,
            "-f",
            "null",
            "-",
        ]
        try:
            result = subprocess.run(cmd)
            if result.returncode == 0:
                log("直播源已在線，可以開播。")
                return
            else:
                log(f"直播源暫時無法讀取 (returncode={result.returncode})")
        except FileNotFoundError:
            log("錯誤：找不到 ffmpeg 指令，請先安裝 ffmpeg。")
            raise

        log(f"{check_interval} 秒後再次檢查 ...")
        time.sleep(check_interval)


def run_single_broadcast(youtube, args):
    """
    開啟一場 YouTube 直播：
    - 建立 broadcast & stream
    - 啟動 ffmpeg 推流
    - 監控 ffmpeg 輸出，若 offline_seconds 內沒新畫面，則視為結束
    """
    broadcast_id, rtmp_url = create_broadcast_and_stream(youtube, args.title)

    ff_cmd = [
        "ffmpeg",
        "-reconnect",
        "1",
        "-reconnect_streamed",
        "1",
        "-reconnect_on_network_error",
        "1",
        "-i",
        args.source_url,
        "-c:v",
        "copy",
        "-c:a",
        "copy",
        "-f",
        "flv",
        rtmp_url,
    ]

    log("啟動 ffmpeg 推流：")
    log(" ".join(ff_cmd))

    proc = subprocess.Popen(
        ff_cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        universal_newlines=True,
    )

    last_progress_ts = time.time()
    last_frame = None
    offline_seconds = args.offline_seconds
    frame_re = re.compile(r"frame=\s*(\d+)")

    try:
        for line in proc.stdout:
            # 同步輸出到當前 log（方便 tail -f 查）
            sys.stdout.write(line)

            m = frame_re.search(line)
            if m:
                frame = int(m.group(1))
                if last_frame is None or frame != last_frame:
                    last_frame = frame
                    last_progress_ts = time.time()

            # watchdog：若超過 offline_seconds 沒有新 frame，視為直播結束
            if time.time() - last_progress_ts > offline_seconds:
                log(
                    f"{offline_seconds} 秒沒有新畫面，判定本場直播已結束，準備關閉 ffmpeg。"
                )
                proc.kill()
                break
    except Exception as e:
        log(f"讀取 ffmpeg 輸出時發生錯誤: {e}")
    finally:
        try:
            proc.wait(timeout=10)
        except Exception:
            proc.kill()

    # 把這場直播標記為 complete
    try:
        log(f"將 broadcast {broadcast_id} 標記為 complete ...")
        youtube.liveBroadcasts().transition(
            broadcastStatus="complete",
            part="id,status",
            id=broadcast_id,
        ).execute()
        log(f"broadcast {broadcast_id} 已標記為 complete。")
    except HttpError as e:
        log(f"標記 broadcast complete 失敗: {e}")

    log("本場直播流程結束。")


def main():
    parser = argparse.ArgumentParser(description="Magic Stream 自動轉播腳本")
    parser.add_argument("--source-url", required=True, help="抖音等平台的 FLV 直播源 URL")
    parser.add_argument("--title", default="Magic Stream Live", help="YouTube 直播標題")
    parser.add_argument(
        "--reconnect-seconds",
        type=int,
        default=60,
        help="當直播源不在線時，多久檢查一次（秒）",
    )
    parser.add_argument(
        "--offline-seconds",
        type=int,
        default=300,
        help="若超過這麼多秒沒有新畫面，視為本場直播結束（秒）",
    )
    parser.add_argument(
        "--auth-dir",
        default="youtube_auth",
        help="存放 client_secret.json / token.json 的目錄",
    )
    args = parser.parse_args()

    log(f"啟動 Magic Stream 自動轉播")
    log(f"source-url       = {args.source_url}")
    log(f"title            = {args.title}")
    log(f"reconnectSeconds = {args.reconnect_seconds}")
    log(f"offlineSeconds   = {args.offline_seconds}")
    log(f"authDir          = {args.auth_dir}")

    youtube = get_youtube(args.auth_dir)

    # 主循環：直播源每次開播 -> 開一場 YouTube 直播；結束 -> 等下一次
    while True:
        # 1. 等直播源上線
        wait_for_source_online(args.source_url, args.reconnect_seconds)

        # 2. 跑一場直播
        try:
            run_single_broadcast(youtube, args)
        except Exception as e:
            log(f"本場直播過程中發生錯誤: {e}")

        # 3. 稍微休息一下再開始下一輪檢查
        log(f"等待 {args.reconnect_seconds} 秒後再次檢查是否有新一場直播 ...")
        time.sleep(args.reconnect_seconds)


if __name__ == "__main__":
    main()
