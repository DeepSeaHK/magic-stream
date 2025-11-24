#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Magic Stream 自動轉播腳本 v0.6.0

功能概述：
- 探測來源直播（抖音 FLV / HTTP / RTMP）是否上線
- 來源一旦上線：自動用 YouTube API 建立直播 + 串流，綁定後開播
- 用 ffmpeg 把來源原樣轉推到 YouTube
- 若來源中斷超過 offline_seconds 秒，視為本場直播結束，將 YouTube 直播標記為 complete
- 然後進入待機，等下一次來源再開播時自動開新場直播
- OAuth 憑證：
    - 優先使用 youtube_auth/token.json
    - 若 token 過期會自動 refresh
    - 若 scope 不符 / 被撤銷（invalid_scope / invalid_grant），會自動刪除 token.json 並重新走瀏覽器授權

必要檔案：
- auth 目錄內必須有：client_secret.json
- token.json 會由程式自動產生
"""

import argparse
import datetime
import os
import subprocess
import sys
import time
from typing import Tuple

import requests
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError

from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from google.auth.transport.requests import Request
from google.auth.exceptions import RefreshError

# ============================================================
# 設定
# ============================================================

# 建議 scope：可讀可寫直播（含建立 / 管理 liveBroadcast）
SCOPES = ["https://www.googleapis.com/auth/youtube.force-ssl"]


# ============================================================
# 工具函式
# ============================================================

def log(msg: str) -> None:
    """帶時間戳的 log。"""
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{now}] {msg}", flush=True)


# ============================================================
# OAuth / YouTube API
# ============================================================

def load_credentials(auth_dir: str) -> Credentials:
    """
    在 auth_dir 裡面讀取 / 建立 YouTube API 憑證。

    流程：
    1. 若存在 token.json，先嘗試載入
    2. 若 token 過期且有 refresh_token -> 嘗試 refresh
       - 若出現 invalid_scope / invalid_grant 等 RefreshError
         -> 刪除 token.json，重新授權
    3. 若沒有有效憑證 -> 用 client_secret.json 跑一輪瀏覽器授權
    """
    os.makedirs(auth_dir, exist_ok=True)

    token_path = os.path.join(auth_dir, "token.json")
    client_path = os.path.join(auth_dir, "client_secret.json")

    if not os.path.exists(client_path):
        raise FileNotFoundError(
            f"找不到 client_secret.json：{client_path}\n"
            f"請先把 Google Cloud 下載的 OAuth 用戶端 JSON 放到這個資料夾。"
        )

    creds = None

    # 1. 先嘗試讀取 token.json
    if os.path.exists(token_path):
        try:
            log(f"從 {token_path} 載入現有 token.json ...")
            creds = Credentials.from_authorized_user_file(token_path, SCOPES)
        except Exception as e:
            log(f"[警告] 讀取 token.json 失敗，將重新授權：{e}")
            creds = None

    # 2. 若有憑證但可能過期，嘗試 refresh
    if creds and not creds.valid:
        if creds.expired and creds.refresh_token:
            try:
                log("[訊息] token 已過期，嘗試刷新憑證...")
                creds.refresh(Request())
                log("[訊息] token 刷新成功。")
            except RefreshError as e:
                # 這裡會吃到 invalid_scope / invalid_grant 等
                log(f"[警告] token 無效（{e}），刪除 token.json 並重新授權。")
                try:
                    os.remove(token_path)
                except FileNotFoundError:
                    pass
                creds = None
        else:
            log("[警告] 憑證無效且沒有 refresh_token，將重新授權。")
            creds = None

    # 3. 若沒有有效憑證，跑瀏覽器授權流程
    if not creds:
        log("[訊息] 開始瀏覽器授權流程，請在瀏覽器中同意存取 YouTube ...")
        flow = InstalledAppFlow.from_client_secrets_file(client_path, SCOPES)
        creds = flow.run_local_server(port=0)
        with open(token_path, "w", encoding="utf-8") as token_file:
            token_file.write(creds.to_json())
        log(f"[訊息] 已儲存新的 token.json 到：{token_path}")

    return creds


def get_youtube_service(auth_dir: str):
    """建立 YouTube API client。"""
    creds = load_credentials(auth_dir)
    log("建立 YouTube API 客戶端 ...")
    return build("youtube", "v3", credentials=creds)


def create_live_broadcast(youtube, title: str) -> str:
    """建立一個新的 liveBroadcast，回傳 broadcast_id。"""
    start_time = (datetime.datetime.utcnow() + datetime.timedelta(seconds=5)).isoformat("T") + "Z"

    body = {
        "snippet": {
            "title": title,
            "scheduledStartTime": start_time,
        },
        "status": {
            # 開播時你自己再從 Studio 調整公開/不公開也行
            "privacyStatus": "unlisted",
        },
        "contentDetails": {
            "enableAutoStart": True,
            "enableAutoStop": True,
        },
    }

    log("呼叫 YouTube API 建立 liveBroadcast ...")
    resp = youtube.liveBroadcasts().insert(
        part="snippet,contentDetails,status",
        body=body,
    ).execute()

    broadcast_id = resp["id"]
    log(f"已建立 liveBroadcast：{broadcast_id}")
    return broadcast_id


def create_live_stream(youtube, title: str) -> Tuple[str, str]:
    """
    建立 liveStream（串流設定），回傳 (stream_id, rtmp_url)。
    rtmp_url 已經是 ingestionAddress + streamName 拼好的完整地址。
    """
    body = {
        "snippet": {
            "title": title,
        },
        "cdn": {
            "format": "variable",      # 讓 YouTube 自己適配
            "ingestionType": "rtmp",
        },
        "contentDetails": {},
    }

    log("呼叫 YouTube API 建立 liveStream ...")
    resp = youtube.liveStreams().insert(
        part="snippet,cdn,contentDetails",
        body=body,
    ).execute()

    stream_id = resp["id"]
    ingestion = resp["cdn"]["ingestionInfo"]
    address = ingestion["ingestionAddress"]
    stream_name = ingestion["streamName"]

    if address.endswith("/"):
        rtmp_url = address + stream_name
    else:
        rtmp_url = address + "/" + stream_name

    log(f"已建立 liveStream：{stream_id}")
    log(f"YouTube RTMP 推流地址：{rtmp_url}")
    return stream_id, rtmp_url


def bind_broadcast_stream(youtube, broadcast_id: str, stream_id: str) -> None:
    """把 liveBroadcast 綁定到 liveStream。"""
    log(f"綁定 broadcast {broadcast_id} 到 stream {stream_id} ...")
    youtube.liveBroadcasts().bind(
        part="id,contentDetails",
        id=broadcast_id,
        streamId=stream_id,
    ).execute()
    log("綁定完成。")


def transition_broadcast(youtube, broadcast_id: str, status: str) -> None:
    """
    切換直播狀態：
    status 可以是 'live' / 'complete' / 'testing'
    """
    log(f"將 broadcast {broadcast_id} 切換狀態：{status} ...")
    youtube.liveBroadcasts().transition(
        part="id,status,contentDetails",
        id=broadcast_id,
        broadcastStatus=status,
    ).execute()
    log("狀態切換完成。")


# ============================================================
# 探測來源直播是否上線
# ============================================================

def is_source_online(url: str, timeout: int = 5) -> bool:
    """
    粗略判斷來源是否「看起來有東西」：
    - HTTP/HTTPS：用 requests 讀一點點資料
    - RTMP：沒辦法簡單 HTTP 探測，直接回 True，交給 ffmpeg 自己連
    """
    if url.startswith("rtmp://") or url.startswith("rtmps://"):
        # RTMP 不好探測，只要能連就交給 ffmpeg 處理
        return True

    try:
        log(f"探測直播源是否上線：{url}")
        with requests.get(url, stream=True, timeout=timeout) as resp:
            if resp.status_code != 200:
                log(f"[探針] HTTP 狀態碼 {resp.status_code}，暫時視為未上線。")
                return False

            # 試圖讀少量資料
            for chunk in resp.iter_content(chunk_size=1024):
                if chunk:
                    log("[探針] 收到資料，視為來源已上線。")
                    return True

            log("[探針] 沒有讀到任何資料，暫時視為未上線。")
            return False
    except Exception as e:
        log(f"[探針] 探測來源失敗：{e}，視為未上線。")
        return False


def wait_for_source_online(url: str, check_interval: int = 10) -> None:
    """一直等到來源上線為止。"""
    while True:
        if is_source_online(url):
            log("✅ 探測到來源直播已上線，準備開啟 YouTube 直播。")
            return
        log(f"來源尚未上線，{check_interval} 秒後再檢查 ...")
        time.sleep(check_interval)


# ============================================================
# ffmpeg 推流
# ============================================================

def run_ffmpeg_relay(
    source_url: str,
    rtmp_url: str,
    offline_seconds: int,
    reconnect_seconds: int,
) -> None:
    """
    啟動 ffmpeg，把 source_url 原樣轉推到 rtmp_url。

    - 透過讀取 ffmpeg stderr 來判斷是否有 frame 輸出
    - 若超過 offline_seconds 都沒有新的 frame，就視為來源下播，結束本次推流
    """
    log("啟動 ffmpeg 轉播 ...")

    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "info"]

    # HTTP/HTTPS 來源，加上一些重連參數
    if source_url.startswith("http://") or source_url.startswith("https://"):
        # -rw_timeout 單位是 microseconds
        rw_timeout_us = reconnect_seconds * 1_000_000
        cmd += [
            "-rw_timeout",
            str(rw_timeout_us),
            "-reconnect",
            "1",
            "-reconnect_streamed",
            "1",
            "-reconnect_at_eof",
            "1",
            "-reconnect_on_network_error",
            "1",
            "-reconnect_delay_max",
            "5",
        ]

    cmd += [
        "-re",
        "-i",
        source_url,
        "-c",
        "copy",
        "-f",
        "flv",
        "-flvflags",
        "no_duration_filesize",
        rtmp_url,
    ]

    log("ffmpeg 命令：")
    log(" ".join(cmd))

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        universal_newlines=True,
    )

    last_frame_time = time.time()
    log(f"開始監控 ffmpeg 輸出，若 {offline_seconds} 秒沒有新畫面則判定為下播。")

    try:
        while True:
            line = proc.stderr.readline()
            if line == "" and proc.poll() is not None:
                # ffmpeg 已結束
                log(f"ffmpeg 已退出，return code = {proc.returncode}")
                break

            if line:
                line = line.rstrip("\n")
                # 原樣輸出一份到 log
                print(line, flush=True)

                # 粗略判斷有 frame 在跑
                if "frame=" in line or "bitrate=" in line or "time=" in line:
                    last_frame_time = time.time()

            # 判斷是否太久沒有新畫面
            if time.time() - last_frame_time > offline_seconds:
                log(
                    f"{offline_seconds} 秒內沒有收到新畫面，"
                    f"判定來源已下播，準備關閉 ffmpeg。"
                )
                proc.terminate()
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    log("ffmpeg 未在 10 秒內結束，強制 kill。")
                    proc.kill()
                break

    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()

        log("本次 ffmpeg 推流已結束。")


# ============================================================
# 主流程
# ============================================================

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Magic Stream 自動轉播腳本（YouTube API）"
    )
    parser.add_argument(
        "--source-url",
        required=True,
        help="來源直播 URL（抖音 FLV / HTTP / RTMP 等）",
    )
    parser.add_argument(
        "--title",
        default="Magic Stream Relay",
        help="YouTube 直播標題（每一場都會用這個標題新建）",
    )
    parser.add_argument(
        "--reconnect-seconds",
        type=int,
        default=300,
        help="HTTP 讀取超時 / 重連相關的時間設定（秒），預設 300。",
    )
    parser.add_argument(
        "--offline-seconds",
        type=int,
        default=300,
        help="若超過這個秒數沒有新畫面，就視為本場直播結束，預設 300。",
    )
    default_auth_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "youtube_auth")
    parser.add_argument(
        "--auth-dir",
        default=default_auth_dir,
        help=f"存放 client_secret.json / token.json 的資料夾，預設：{default_auth_dir}",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    log("============================================================")
    log(" Magic Stream 自動轉播腳本 v0.6.0 啟動")
    log("============================================================")
    log(f"來源 URL       : {args.source_url}")
    log(f"直播標題       : {args.title}")
    log(f"offline 秒數   : {args.offline_seconds}")
    log(f"reconnect 秒數 : {args.reconnect_seconds}")
    log(f"憑證資料夾     : {args.auth_dir}")

    try:
        youtube = get_youtube_service(args.auth_dir)
    except Exception as e:
        log(f"[致命錯誤] 無法建立 YouTube API 客戶端：{e}")
        sys.exit(1)

    # 主循環：一個 while True = 多場直播輪迴
    while True:
        # 1. 先等來源真的上線
        wait_for_source_online(args.source_url, check_interval=10)

        # 2. 建立一場新的 YouTube 直播
        try:
            broadcast_id = create_live_broadcast(youtube, args.title)
            stream_id, rtmp_url = create_live_stream(youtube, args.title)
            bind_broadcast_stream(youtube, broadcast_id, stream_id)
        except HttpError as e:
            log(f"[致命錯誤] 建立 / 綁定 YouTube 直播失敗：{e}")
            log("30 秒後重試整個流程 ...")
            time.sleep(30)
            continue

        # 3. 試著切換到 live 狀態（enableAutoStart 的情況下可選）
        try:
            transition_broadcast(youtube, broadcast_id, "live")
        except HttpError as e:
            log(f"[警告] 嘗試將直播切換為 live 失敗（可能已自動開始）：{e}")

        # 4. 用 ffmpeg 推流，直到來源下播
        run_ffmpeg_relay(
            source_url=args.source_url,
            rtmp_url=rtmp_url,
            offline_seconds=args.offline_seconds,
            reconnect_seconds=args.reconnect_seconds,
        )

        # 5. 將本場直播標記為 complete
        try:
            transition_broadcast(youtube, broadcast_id, "complete")
        except HttpError as e:
            log(f"[警告] 將直播切換為 complete 失敗：{e}")

        log("本場直播流程已結束，進入待機，等待下一次開播 ...")
        # 這裡直接回到 while True 開頭，重新 wait_for_source_online()


if __name__ == "__main__":
    main()
