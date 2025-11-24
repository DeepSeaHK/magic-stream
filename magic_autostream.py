#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Magic Stream 自動轉播腳本  v0.6.0

功能概要：
- 持續探測來源直播（例如抖音 FLV URL）
- 一旦檢測到有流，通過 YouTube API 創建直播 + 綁定推流
- 調用 ffmpeg 轉推到 YouTube
- ffmpeg 退出後：
    * 如果短時間內反覆斷線，會在同一直播間內重試
    * 如果累計離線超過 offline_seconds，就把這一場標記為 COMPLETE
- 然後回到「等待來源再次開播」的循環

需要：
- youtube_auth 目錄下：client_secret.json, token.json
- ffmpeg 可執行
"""

import argparse
import datetime
import os
import subprocess
import sys
import time
from typing import Tuple, Optional

import requests
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from google_auth_oauthlib.flow import InstalledAppFlow
from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials

SCOPES = ["https://www.googleapis.com/auth/youtube"]


def log(msg: str) -> None:
  now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
  print(f"[{now}] {msg}", flush=True)


def load_credentials(auth_dir: str) -> Credentials:
  os.makedirs(auth_dir, exist_ok=True)
  cred_path = os.path.join(auth_dir, "token.json")
  client_secret = os.path.join(auth_dir, "client_secret.json")

  creds = None
  if os.path.exists(cred_path):
    creds = Credentials.from_authorized_user_file(cred_path, SCOPES)

  if not creds or not creds.valid:
    if creds and creds.expired and creds.refresh_token:
      log("刷新 Google 憑證 ...")
      creds.refresh(Request())
    else:
      if not os.path.exists(client_secret):
        raise FileNotFoundError(f"找不到 client_secret.json：{client_secret}")
      log("打開瀏覽器進行 Google 授權 ...")
      flow = InstalledAppFlow.from_client_secrets_file(client_secret, SCOPES)
      creds = flow.run_local_server(port=0)
    with open(cred_path, "w", encoding="utf-8") as f:
      f.write(creds.to_json())

  return creds


def build_youtube(creds: Credentials):
  return build("youtube", "v3", credentials=creds)


def wait_for_source(url: str, probe_interval: int) -> None:
  """簡單探針：每 probe_interval 秒請求一次源地址，有數據就認為開播。"""
  log(f"開始探測來源直播：{url}")
  while True:
    try:
      # 有些平台會拒絕 HEAD，所以直接 GET 一小段
      resp = requests.get(url, stream=True, timeout=10)
      if resp.status_code == 200:
        # 嘗試讀一點點數據
        try:
          chunk = next(resp.iter_content(chunk_size=1024))
        except StopIteration:
          chunk = b""
        if chunk:
          log("探測到來源有數據，判斷為已開播。")
          return
        else:
          log("來源回應 200 但暫無數據，繼續等待 ...")
      else:
        log(f"來源返回 HTTP {resp.status_code}，繼續等待 ...")
    except Exception as e:
      log(f"探測來源出錯：{e}，稍後重試 ...")

    time.sleep(probe_interval)


def create_broadcast_and_stream(
  youtube,
  title: str,
) -> Tuple[str, str]:
  """創建直播 + 綁定推流，返回 (broadcast_id, rtmp_url)"""
  now = datetime.datetime.utcnow()
  start_time = (now + datetime.timedelta(minutes=1)).isoformat("T") + "Z"

  log("創建 YouTube 直播 ...")

  insert_broadcast = youtube.liveBroadcasts().insert(
    part="snippet,status,contentDetails",
    body={
      "snippet": {
        "title": title,
        "scheduledStartTime": start_time,
      },
      "status": {
        "privacyStatus": "unlisted",
      },
      "contentDetails": {
        "monitorStream": {"enableMonitorStream": True},
        "enableAutoStart": True,
        "enableAutoStop": True,
      },
    },
  )
  broadcast = insert_broadcast.execute()
  broadcast_id = broadcast["id"]

  insert_stream = youtube.liveStreams().insert(
    part="snippet,cdn,contentDetails",
    body={
      "snippet": {"title": f"{title} Stream"},
      "cdn": {
        "frameRate": "30fps",
        "ingestionType": "rtmp",
        "resolution": "1080p",
      },
      "contentDetails": {
        "isReusable": False,
      },
    },
  )
  stream = insert_stream.execute()
  stream_id = stream["id"]

  # 綁定
  youtube.liveBroadcasts().bind(
    part="id,contentDetails",
    id=broadcast_id,
    streamId=stream_id,
  ).execute()

  ingestion = stream["cdn"]["ingestionInfo"]
  rtmp_url = ingestion["ingestionAddress"] + "/" + ingestion["streamName"]

  log(f"已創建直播 ID={broadcast_id}")
  log(f"推流地址：{rtmp_url}")

  return broadcast_id, rtmp_url


def transition_broadcast(youtube, broadcast_id: str, status: str) -> None:
  try:
    log(f"切換直播 {broadcast_id} 狀態 → {status} ...")
    youtube.liveBroadcasts().transition(
      part="status",
      id=broadcast_id,
      broadcastStatus=status,
    ).execute()
  except HttpError as e:
    log(f"切換直播狀態失敗（可以忽略）：{e}")


def run_ffmpeg_loop(
  source_url: str,
  rtmp_url: str,
  offline_seconds: int,
) -> None:
  """
  執行 ffmpeg 轉推：
  - ffmpeg 正常跑 >=60s 視為「有效直播」，離線累計歸零；
  - ffmpeg 很快就退出則累積離線時間；
  - 累計離線超過 offline_seconds 就 break。
  """
  log(f"啟動 ffmpeg 轉推：{source_url} → {rtmp_url}")
  offline_acc = 0

  while True:
    start_ts = time.time()
    cmd = [
      "ffmpeg",
      "-re",
      "-i",
      source_url,
      "-c:v",
      "copy",
      "-c:a",
      "copy",
      "-f",
      "flv",
      rtmp_url,
    ]
    log("ffmpeg 命令：" + " ".join(cmd))
    proc = subprocess.Popen(cmd)
    proc.wait()
    end_ts = time.time()

    runtime = int(end_ts - start_ts)
    log(f"ffmpeg 退出，運行 {runtime} 秒，exit={proc.returncode}")

    if runtime >= 60:
      offline_acc = 0
    else:
      offline_acc += runtime

    if offline_seconds > 0 and offline_acc >= offline_seconds:
      log(f"累計離線時間 {offline_acc}s 超過限制 {offline_seconds}s，本場結束。")
      break

    # 仍在允許離線範圍內，稍後重試
    log("30 秒後重啟 ffmpeg 嘗試重連 ...")
    time.sleep(30)


def main():
  parser = argparse.ArgumentParser(description="Magic Stream 自動轉播腳本 v0.6.0")
  parser.add_argument("--source-url", required=True, help="來源直播地址（例如抖音 FLV URL）")
  parser.add_argument("--title", required=True, help="YouTube 直播標題")
  parser.add_argument(
    "--offline-seconds",
    type=int,
    default=300,
    help="同一場直播允許的累計離線秒數，超過則標記 COMPLETE（預設 300）",
  )
  parser.add_argument(
    "--probe-interval",
    type=int,
    default=30,
    help="探針檢查來源直播的間隔秒數（預設 30）",
  )
  parser.add_argument(
    "--auth-dir",
    default="./youtube_auth",
    help="存放 client_secret.json / token.json 的目錄（預設 ./youtube_auth）",
  )

  args = parser.parse_args()

  log("Magic Stream 自動轉播腳本 v0.6.0 啟動")
  log(f"來源：{args.source_url}")
  log(f"標題：{args.title}")
  log(f"最大離線：{args.offline_seconds} 秒")
  log(f"探針間隔：{args.probe_interval} 秒")
  log(f"授權目錄：{args.auth_dir}")

  creds = load_credentials(args.auth_dir)
  youtube = build_youtube(creds)

  # 無限循環：每次偵測到來源開播 → 開 1 場 YouTube 直播
  while True:
    log("=== 新一輪等待來源開播 ===")
    wait_for_source(args.source_url, args.probe_interval)

    # 來源已開播，創建 YouTube 直播
    try:
      broadcast_id, rtmp_url = create_broadcast_and_stream(youtube, args.title)
    except HttpError as e:
      log(f"創建直播失敗：{e}，60 秒後重試整個流程。")
      time.sleep(60)
      continue

    # 對新開的直播使用 ffmpeg 轉推，直到斷線超過 offline_seconds
    run_ffmpeg_loop(args.source_url, rtmp_url, args.offline_seconds)

    # 結束本場，切換狀態 COMPLETE
    try:
      transition_broadcast(youtube, broadcast_id, "complete")
    except Exception as e:
      log(f"結束直播時出錯（可忽略）：{e}")

    log("本場直播流程結束，回到待命狀態，等待下一次來源開播。")


if __name__ == "__main__":
  main()
