#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Magic Stream 自動 / 手動轉播核心腳本 v0.5.0

功能：
- 手動轉播（mode=manual）：SOURCE_URL -> RTMP_URL
- 自動轉播（mode=auto）：SOURCE_URL -> YouTube 新建直播間，RTMP 自動生成
- 內置探針 + standby：
    * WAITING：源未開播，按 probe_interval 輪詢
    * LIVE：ffmpeg 推流 + 監控 frame 進度
    * END ：offline_seconds 秒無畫面，結束本場（auto 模式會設定 broadcast=complete），回到 WAITING

注意：
- auto 模式需要在 auth_dir 下有 client_secret.json / token.json
"""

import argparse
import os
import sys
import time
import subprocess
import re
from typing import Optional, Tuple

# --- auto 模式才會用到這些 ---
try:
    from googleapiclient.discovery import build
    from google_auth_oauthlib.flow import InstalledAppFlow
    from google.auth.transport.requests import Request
    import google.auth.exceptions
    import pickle
except Exception:
    # manual 模式不一定需要這些庫
    build = None
    InstalledAppFlow = None
    Request = None
    google = None


SCOPES = ["https://www.googleapis.com/auth/youtube"]


def log(msg: str):
    ts = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())
    print(f"[{ts}] {msg}", flush=True)


# ==================== 探針 / ffmpeg 部分 ====================

def probe_source(source_url: str, timeout: int = 15) -> bool:
    """
    用 ffmpeg 簡單探測 source 是否有流。
    """
    cmd = [
        "ffmpeg",
        "-v", "error",
        "-t", "3",
        "-i", source_url,
        "-f", "null",
        "-"
    ]
    log(f"探針：測試直播源是否在線... ({source_url})")
    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            text=True
        )
    except FileNotFoundError:
        log("錯誤：未找到 ffmpeg，請先安裝。")
        return False
    except subprocess.TimeoutExpired:
        log("探針超時，暫時視為不在線。")
        return False

    if proc.returncode == 0:
        log("探針：檢測到直播源在線。")
        return True
    else:
        log("探針：暫時沒有檢測到有效畫面。")
        return False


def wait_for_source_online(source_url: str, probe_interval: int):
    """
    WAITING 狀態：每 probe_interval 秒探針一次，直到 source 在線。
    """
    while True:
        if probe_source(source_url):
            return
        log(f"源未在線，{probe_interval} 秒後重試...")
        time.sleep(probe_interval)


def run_single_broadcast_ffmpeg(
    source_url: str,
    rtmp_url: str,
    offline_seconds: int
) -> None:
    """
    LIVE 狀態：啟動 ffmpeg 推流，監控 frame 進度，若 offline_seconds 秒沒有新 frame，
    則視為本場結束，停止 ffmpeg。
    """
    log("準備啟動 ffmpeg 推流...")
    cmd = [
        "ffmpeg",
        "-reconnect", "1",
        "-reconnect_streamed", "1",
        "-reconnect_on_network_error", "1",
        "-i", source_url,
        "-c:v", "copy",
        "-c:a", "copy",
        "-f", "flv",
        rtmp_url,
    ]

    log("ffmpeg 命令：")
    log(" ".join(cmd))

    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
    except FileNotFoundError:
        log("錯誤：未找到 ffmpeg，無法推流。")
        return

    frame_re = re.compile(r"frame=\s*(\d+)")
    last_frame = None
    last_progress_ts = time.time()
    log(f"開始監控 ffmpeg 輸出，offline_seconds = {offline_seconds}")

    try:
        while True:
            line = proc.stdout.readline()
            if not line:
                # 沒有新輸出，檢查進程是否已退出
                if proc.poll() is not None:
                    log(f"ffmpeg 進程已退出，returncode={proc.returncode}")
                    break
                time.sleep(1)
                continue

            line_stripped = line.rstrip()
            # 原樣打印 ffmpeg log（方便 tail）
            print(line_stripped, flush=True)

            m = frame_re.search(line_stripped)
            if m:
                frame = int(m.group(1))
                if last_frame is None or frame != last_frame:
                    last_frame = frame
                    last_progress_ts = time.time()

            # 判斷是否超時無畫面
            if time.time() - last_progress_ts > offline_seconds:
                log(
                    f"已超過 {offline_seconds} 秒沒有新畫面，判定本場直播已結束，準備停止 ffmpeg..."
                )
                proc.kill()
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    log("ffmpeg 無法正常退出，強制結束。")
                break

    except KeyboardInterrupt:
        log("收到中斷訊號，停止 ffmpeg...")
        proc.kill()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass


# ==================== YouTube API 部分（auto 模式） ====================

def load_credentials(auth_dir: str):
    """
    從 auth_dir 中載入 / 刷新 YouTube OAuth 憑證。
    兼容 token.pickle / token.json 兩種使用者習慣。
    """
    if build is None:
        raise RuntimeError("尚未安裝 google-api-python-client 等依賴。")

    os.makedirs(auth_dir, exist_ok=True)
    token_pickle = os.path.join(auth_dir, "token.pickle")
    token_json = os.path.join(auth_dir, "token.json")
    client_secret = os.path.join(auth_dir, "client_secret.json")

    creds = None

    # 1. 優先讀取 token.pickle
    if os.path.exists(token_pickle):
        with open(token_pickle, "rb") as f:
            creds = pickle.load(f)

    # 2. 其次讀取 token.json（google-auth-oauthlib 標準格式）
    if creds is None and os.path.exists(token_json):
        from google.oauth2.credentials import Credentials
        creds = Credentials.from_authorized_user_file(token_json, SCOPES)

    # 3. 如無有效憑證，走 OAuth 流程（需要瀏覽器授權）
    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            log("憑證已過期，嘗試刷新 token...")
            try:
                creds.refresh(Request())
            except google.auth.exceptions.RefreshError as e:
                log(f"刷新 token 失敗：{e}")
                creds = None
        if not creds:
            if not os.path.exists(client_secret):
                raise FileNotFoundError(
                    f"找不到 client_secret.json（路徑：{client_secret)})"
                )
            flow = InstalledAppFlow.from_client_secrets_file(
                client_secret, SCOPES
            )
            creds = flow.run_local_server(port=0)

        # 保存憑證（兩種格式都寫一份）
        with open(token_pickle, "wb") as f:
            pickle.dump(creds, f)
        try:
            from google.oauth2.credentials import Credentials
            if isinstance(creds, Credentials):
                with open(token_json, "w", encoding="utf-8") as f:
                    f.write(creds.to_json())
        except Exception:
            pass

    return creds


def create_youtube_service(auth_dir: str):
    creds = load_credentials(auth_dir)
    youtube = build("youtube", "v3", credentials=creds)
    return youtube


def create_livestream_and_broadcast(
    youtube,
    title: str,
    description: str,
    privacy_status: str,
) -> Tuple[str, str, str]:
    """
    返回 (broadcast_id, stream_id, rtmp_url)
    """
    log("創建 liveStream ...")
    stream_body = {
        "snippet": {
            "title": f"{title} Stream",
            "description": description,
        },
        "cdn": {
            "frameRate": "variable",
            "ingestionType": "rtmp",
            "resolution": "variable",
        },
        "contentDetails": {
            "isReusable": False
        },
    }

    stream_insert = youtube.liveStreams().insert(
        part="snippet,cdn,contentDetails",
        body=stream_body,
    )
    stream = stream_insert.execute()
    stream_id = stream["id"]
    ingestion = stream["cdn"]["ingestionInfo"]
    ingestion_address = ingestion["ingestionAddress"]
    stream_name = ingestion["streamName"]
    rtmp_url = f"{ingestion_address}/{stream_name}"

    log(f"liveStream 創建完成：stream_id={stream_id}")
    log(f"RTMP 推流地址：{rtmp_url}")

    log("創建 liveBroadcast ...")
    broadcast_body = {
        "snippet": {
            "title": title,
            "description": description,
        },
        "status": {
            "privacyStatus": privacy_status,
        },
        "contentDetails": {
            "monitorStream": {"enableMonitorStream": True},
        },
    }

    broadcast_insert = youtube.liveBroadcasts().insert(
        part="snippet,status,contentDetails",
        body=broadcast_body,
    )
    broadcast = broadcast_insert.execute()
    broadcast_id = broadcast["id"]
    log(f"liveBroadcast 創建完成：broadcast_id={broadcast_id}")

    log("綁定 broadcast <-> stream ...")
    bind_req = youtube.liveBroadcasts().bind(
        part="id,contentDetails",
        id=broadcast_id,
        streamId=stream_id,
    )
    bind_req.execute()
    log("綁定完成。")

    # 將 broadcast 狀態切到 live（讓直播真正開始）
    log("嘗試將 broadcast 狀態切換為 'live' ...")
    try:
        transition_req = youtube.liveBroadcasts().transition(
            part="status",
            broadcastStatus="live",
            id=broadcast_id,
        )
        transition_req.execute()
        log("狀態已切換為 live。")
    except Exception as e:
        log(f"切換 broadcast 狀態為 live 時發生錯誤（可忽略）：{e}")

    return broadcast_id, stream_id, rtmp_url


def complete_broadcast(youtube, broadcast_id: str):
    """
    將當前 broadcast 標記為 complete。
    """
    try:
        log(f"將 broadcast({broadcast_id}) 標記為 complete ...")
        req = youtube.liveBroadcasts().transition(
            part="status",
            broadcastStatus="complete",
            id=broadcast_id,
        )
        req.execute()
        log("broadcast 已標記為 complete。")
    except Exception as e:
        log(f"標記 broadcast complete 時出錯（可忽略）：{e}")


# ==================== 主流程：手動 / 自動 ====================

def relay_manual(
    source_url: str,
    rtmp_url: str,
    probe_interval: int,
    offline_seconds: int,
):
    """
    手動轉播模式：
    - 使用固定 RTMP_URL
    - 多場直播共享同一個 RTMP（YouTube 那邊的行為由你在 Studio 設定）
    - 本腳本負責 standby / 開播 / 下播判定
    """
    log("啟動 手動轉播 模式。")
    log(f"Source URL: {source_url}")
    log(f"RTMP URL  : {rtmp_url}")
    log(f"probe_interval={probe_interval}, offline_seconds={offline_seconds}")

    while True:
        log("進入 WAITING 狀態，等待直播源上線...")
        wait_for_source_online(source_url, probe_interval)

        log("檢測到直播源上線，開始本場推流...")
        run_single_broadcast_ffmpeg(source_url, rtmp_url, offline_seconds)

        log("本場推流結束，回到 WAITING 狀態，等待下一次開播。")


def relay_auto(
    source_url: str,
    title: str,
    description: str,
    privacy_status: str,
    auth_dir: str,
    probe_interval: int,
    offline_seconds: int,
):
    """
    自動轉播模式：
    - 每次源上線：
        * 自動創建一個全新 YouTube 直播間
        * 綁定 stream
        * 用 ffmpeg 推流到該 RTMP
    - 當 offline_seconds 秒無畫面：
        * 停止 ffmpeg
        * 將該 broadcast 標記為 complete
        * 回到 WAITING，等下一場
    """
    log("啟動 自動轉播 模式。")
    log(f"Source URL      : {source_url}")
    log(f"Title           : {title}")
    log(f"Privacy         : {privacy_status}")
    log(f"probe_interval  : {probe_interval}")
    log(f"offline_seconds : {offline_seconds}")
    log(f"auth_dir        : {auth_dir}")

    youtube = create_youtube_service(auth_dir)
    log("YouTube API 服務初始化完成。")

    while True:
        log("進入 WAITING 狀態，等待直播源上線...")
        wait_for_source_online(source_url, probe_interval)

        # 每次新一場直播，創建新的 broadcast + stream
        log("檢測到直播源上線，創建 YouTube 直播間...")
        broadcast_id, stream_id, rtmp_url = create_livestream_and_broadcast(
            youtube,
            title=title,
            description=description,
            privacy_status=privacy_status,
        )

        log(f"本場直播 RTMP：{rtmp_url}")
        run_single_broadcast_ffmpeg(source_url, rtmp_url, offline_seconds)

        # ffmpeg 結束 -> 將 broadcast 標記 complete
        complete_broadcast(youtube, broadcast_id)

        log("本場推流 & broadcast 已結束，回到 WAITING 狀態，等待下一次開播。")


# ==================== CLI 參數解析 ====================

def parse_args():
    parser = argparse.ArgumentParser(
        description="Magic Stream 轉播核心腳本"
    )
    parser.add_argument(
        "--mode",
        choices=["manual", "auto"],
        required=True,
        help="manual：手動 RTMP 轉播；auto：YouTube API 自動直播",
    )
    parser.add_argument(
        "--source-url",
        required=True,
        help="直播源地址（FLV/HLS 等）。",
    )
    parser.add_argument(
        "--probe-interval",
        type=int,
        default=30,
        help="探針間隔秒數（默認 30）。",
    )
    parser.add_argument(
        "--offline-seconds",
        type=int,
        default=300,
        help="無畫面判定下播的秒數（默認 300）。",
    )

    # manual 模式相關
    parser.add_argument(
        "--rtmp-url",
        help="手動模式下使用的 RTMP 推流地址（含 key）。",
    )

    # auto 模式相關
    parser.add_argument(
        "--title",
        help="自動模式下直播標題。",
    )
    parser.add_argument(
        "--description",
        default="Magic Stream relay",
        help="自動模式下直播說明（默認：Magic Stream relay）。",
    )
    parser.add_argument(
        "--privacy-status",
        default="unlisted",
        choices=["public", "unlisted", "private"],
        help="自動模式隱私狀態（public / unlisted / private），默認 unlisted。",
    )
    parser.add_argument(
        "--auth-dir",
        default=os.path.join(os.path.expanduser("~"), "magic_stream", "youtube_auth"),
        help="存放 client_secret.json / token.json 的目錄。",
    )

    return parser.parse_args()


def main():
    args = parse_args()

    if args.mode == "manual":
        if not args.rtmp_url:
            print("錯誤：manual 模式需要提供 --rtmp-url", file=sys.stderr)
            sys.exit(1)
        relay_manual(
            source_url=args.source_url,
            rtmp_url=args.rtmp_url,
            probe_interval=args.probe_interval,
            offline_seconds=args.offline_seconds,
        )

    elif args.mode == "auto":
        if not args.title:
            print("錯誤：auto 模式需要提供 --title", file=sys.stderr)
            sys.exit(1)
        relay_auto(
            source_url=args.source_url,
            title=args.title,
            description=args.description,
            privacy_status=args.privacy_status,
            auth_dir=args.auth_dir,
            probe_interval=args.probe_interval,
            offline_seconds=args.offline_seconds,
        )


if __name__ == "__main__":
    main()
