#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Magic Stream 自動轉播腳本 v0.6.0
從指定直播源 URL 自動開 YouTube 直播並轉播，
內建「探針」邏輯：
- 掉線後在 reconnect_seconds 內自動等待源恢復並重連；
- 超過 reconnect_seconds 視為本場結束，關閉該場直播；
- 腳本不退出，改為待命，下一次源有信號再自動開新的一場。
"""

import argparse
import datetime
import os
import subprocess
import sys
import time
from typing import Tuple

from googleapiclient.discovery import build
from googleapiclient.errors import HttpError

from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from google.auth.transport.requests import Request

SCOPES = ["https://www.googleapis.com/auth/youtube"]


# ---------------- 認證相關 ----------------


def load_credentials(auth_dir: str) -> Credentials:
  """
  從 auth_dir 載入 / 取得 YouTube 憑證：
  - 有 token.json 就嘗試讀取並刷新；
  - 若無或失敗，就走一次 OAuth，生成新的 token.json。
  """
  os.makedirs(auth_dir, exist_ok=True)
  client_secret = os.path.join(auth_dir, "client_secret.json")
  token_path = os.path.join(auth_dir, "token.json")

  if not os.path.exists(client_secret):
    print(f"[錯誤] 找不到 client_secret.json，請先把檔案放到：{client_secret}")
    sys.exit(1)

  creds = None

  # 1. 如果 token.json 存在，先嘗試讀取 + 刷新
  if os.path.exists(token_path):
    try:
      creds = Credentials.from_authorized_user_file(token_path, SCOPES)
    except Exception as e:
      print(f"[警告] 讀取 token.json 失敗，將重新授權：{e}")
      creds = None

  if creds and creds.expired and creds.refresh_token:
    try:
      creds.refresh(Request())
      print("[OK] 已自動刷新 token。")
    except Exception as e:
      print(f"[警告] 刷新 token 失敗，將重新授權：{e}")
      creds = None

  # 2. 沒有可用憑證 → 走一遍 OAuth 授權流程，產生新的 token.json
  if not creds or not creds.valid:
    print("[INFO] 需要一次性 YouTube 授權，請依照瀏覽器中的提示完成。")
    flow = InstalledAppFlow.from_client_secrets_file(client_secret, SCOPES)
    # headless 環境建議使用 run_console()，會印出 URL，讓你自己開瀏覽器 + 貼回驗證碼
    creds = flow.run_console()
    with open(token_path, "w", encoding="utf-8") as f:
      f.write(creds.to_json())
    print(f"[OK] 已儲存新的 token 到 {token_path}")

  return creds


def get_youtube_service(auth_dir: str):
  creds = load_credentials(auth_dir)
  return build("youtube", "v3", credentials=creds)


# ---------------- YouTube 相關 ----------------


def create_broadcast_and_stream(youtube, title: str) -> Tuple[str, str, str]:
  """
  建立一場新的直播（liveBroadcast + liveStream），並回傳：
    broadcast_id, stream_id, rtmp_url
  """
  now = datetime.datetime.utcnow().isoformat("T") + "Z"

  print("[INFO] 建立 liveBroadcast...")
  broadcast = youtube.liveBroadcasts().insert(
    part="snippet,status,contentDetails",
    body={
      "snippet": {
        "title": title,
        "scheduledStartTime": now,
      },
      "status": {
        "privacyStatus": "unlisted",
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
  print(f"[OK] 建立 liveBroadcast：{broadcast_id}")

  print("[INFO] 建立 liveStream...")
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
  print(f"[OK] 建立 liveStream：{stream_id}")

  print("[INFO] 綁定 broadcast <-> stream...")
  youtube.liveBroadcasts().bind(
    part="id,contentDetails",
    id=broadcast_id,
    streamId=stream_id,
  ).execute()

  ingestion = stream["cdn"]["ingestionInfo"]
  ingestion_address = ingestion["ingestionAddress"]
  stream_name = ingestion["streamName"]
  rtmp_url = f"{ingestion_address}/{stream_name}"

  print(f"[OK] RTMP 推流位址：{rtmp_url}")
  return broadcast_id, stream_id, rtmp_url


def complete_broadcast(youtube, broadcast_id: str):
  """
  將直播狀態切到 complete（結束直播）。
  """
  try:
    print(f"[INFO] 嘗試將直播 {broadcast_id} 切換為 complete...")
    youtube.liveBroadcasts().transition(
      broadcastStatus="complete",
      id=broadcast_id,
      part="status",
    ).execute()
    print("[OK] 已呼叫 complete。")
  except HttpError as e:
    print(f"[警告] 切換 complete 時發生錯誤：{e}")


# ---------------- 探針 & ffmpeg ----------------


def probe_source_once(source_url: str, timeout: int = 25) -> bool:
  """
  探針：用 ffprobe 簡單打一次源，看能不能成功讀到資料。
  只要 ffprobe 回傳 0 就當作「源有信號」。
  """
  cmd = [
    "ffprobe",
    "-v",
    "error",
    "-select_streams",
    "v:0",
    "-show_entries",
    "stream=width,height",
    "-of",
    "csv=p=0",
    source_url,
  ]
  try:
    proc = subprocess.run(
      cmd,
      stdout=subprocess.DEVNULL,
      stderr=subprocess.DEVNULL,
      timeout=timeout,
    )
    return proc.returncode == 0
  except Exception as e:
    print(f"[探針] ffprobe 失敗：{e}")
    return False


def wait_until_source_online(source_url: str, interval: int = 30):
  """
  初次等待：一直等到源有信號為止（無上限）。
  """
  print("[探針] 等待直播源有信號中...")
  while True:
    if probe_source_once(source_url):
      print("[探針] 偵測到源已上線，準備開播。")
      return
    print(f"[探針] 仍無信號，{interval} 秒後重試...")
    time.sleep(interval)


def wait_source_back_within(source_url: str, max_wait: int, interval: int = 30) -> bool:
  """
  ffmpeg 掉線後，在 max_wait 秒內反覆探測源是否恢復。
  - 回傳 True：源在期限內恢復（適合在同一場直播中重啟 ffmpeg）
  - 回傳 False：源超過 max_wait 都沒信號，視為本場結束
  """
  deadline = time.time() + max_wait
  while time.time() < deadline:
    remain = int(deadline - time.time())
    if probe_source_once(source_url):
      print("[探針] 在容忍時間內偵測到源已恢復。")
      return True
    print(f"[探針] 仍無信號，剩餘 {remain} 秒，{interval} 秒後再試一次...")
    time.sleep(interval)
  print("[探針] 超過容忍時間仍無信號，判斷本場直播已結束。")
  return False


def run_ffmpeg_once(source_url: str, rtmp_url: str) -> int:
  """
  啟動一次 ffmpeg 轉播，直到進程結束為止。
  回傳 ffmpeg 的 returncode。
  """
  cmd = [
    "ffmpeg",
    "-loglevel",
    "warning",
    "-re",
    "-i",
    source_url,
    "-c",
    "copy",
    "-f",
    "flv",
    rtmp_url,
  ]
  print("[FFMPEG] 啟動命令：", " ".join(cmd))
  proc = subprocess.Popen(cmd)
  try:
    proc.wait()
  except KeyboardInterrupt:
    print("[FFMPEG] 收到 Ctrl+C，準備結束 ffmpeg。")
    proc.terminate()
    proc.wait()
  return proc.returncode


# ---------------- 主流程（帶探針的自動轉播） ----------------


def main():
  parser = argparse.ArgumentParser(description="Magic Stream 自動轉播（含探針邏輯）")
  parser.add_argument("--source-url", required=True, help="直播源 URL（例如 FLV）")
  parser.add_argument("--title", required=True, help="YouTube 直播標題")
  parser.add_argument(
    "--reconnect-seconds",
    type=int,
    default=300,
    help="短暫掉線容忍秒數，超過視為本場結束（預設 300）",
  )
  parser.add_argument(
    "--auth-dir",
    default=os.path.join(os.path.dirname(__file__), "youtube_auth"),
    help="存放 client_secret.json / token.json 的目錄",
  )
  args = parser.parse_args()

  source_url = args.source_url
  reconnect_seconds = args.reconnect_seconds
  auth_dir = args.auth_dir
  title = args.title

  print("==========================================================")
  print(" Magic Stream 自動轉播腳本 v0.6.0  （含探針守候）")
  print("==========================================================")
  print(f"[設定] 直播源 URL        : {source_url}")
  print(f"[設定] 直播標題          : {title}")
  print(f"[設定] 短暫掉線容忍秒數  : {reconnect_seconds}")
  print(f"[設定] 認證目錄          : {auth_dir}")
  print("----------------------------------------------------------")

  youtube = get_youtube_service(auth_dir)

  # 大循環：代表「一個主播頻道的長期守候」，每次迴圈是一場 YouTube 直播
  while True:
    # 1) 先等待源真正有信號
    wait_until_source_online(source_url, interval=30)

    # 2) 開一場新的 YouTube 直播
    try:
      broadcast_id, stream_id, rtmp_url = create_broadcast_and_stream(youtube, title)
    except HttpError as e:
      print(f"[錯誤] 建立直播時發生 API 錯誤：{e}")
      print("[提示] 30 秒後再試一次...")
      time.sleep(30)
      continue

    print("[INFO] 開始本場轉播。")
    same_broadcast = True

    # 3) 小循環：在同一場 broadcast 裡，只要源在容忍時間內恢復，就重啟 ffmpeg
    while same_broadcast:
      rc = run_ffmpeg_once(source_url, rtmp_url)
      print(f"[FFMPEG] 進程結束，returncode = {rc}")

      # ffmpeg 結束後，檢查源是否在 reconnect_seconds 內恢復
      if wait_source_back_within(source_url, reconnect_seconds, interval=30):
        print("[INFO] 準備在同一場直播中重啟 ffmpeg...")
        continue  # 回到 while same_broadcast，重新 run_ffmpeg_once
      else:
        # 超過容忍時間仍無信號 → 結束本場
        complete_broadcast(youtube, broadcast_id)
        same_broadcast = False
        print("[INFO] 本場直播流程已結束，進入待命，等待下一次開播。")

    # 4) 回到最外層 while True，探針會重新等待下一次主播開播
    print("[守候] 探針將持續待命，等待下一次源有信號...")


if __name__ == "__main__":
  main()
