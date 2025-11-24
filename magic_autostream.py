#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Magic Stream 自動轉播腳本

功能：
- 探針監測直播源（HTTP-FLV / m3u8 等），每 N 秒探測一次
- 源開播 -> 自動建立 YouTube 直播 & RTMP 串流 -> ffmpeg 推流
- 中途斷線：在「重連窗口」內自動重連，同一個直播間
- 斷線超過重連窗口：將本場直播標記 complete，下一次開播自動開新直播間
"""

import argparse
import datetime
import logging
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import requests
from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build

SCOPES = ["https://www.googleapis.com/auth/youtube"]


# ------------------ YouTube API ------------------


def get_credentials(auth_dir: Path) -> Credentials:
  auth_dir.mkdir(parents=True, exist_ok=True)
  token_path = auth_dir / "token.json"
  secret_path = auth_dir / "client_secret.json"

  creds = None
  if token_path.exists():
    creds = Credentials.from_authorized_user_file(str(token_path), SCOPES)

  if not creds or not creds.valid:
    if creds and creds.expired and creds.refresh_token:
      logging.info("刷新 YouTube token ...")
      creds.refresh(Request())
    else:
      if not secret_path.exists():
        raise FileNotFoundError(f"找不到 client_secret.json：{secret_path}")
      logging.info("首次授權，請依照提示在瀏覽器中完成登入 ...")
      flow = InstalledAppFlow.from_client_secrets_file(str(secret_path), SCOPES)
      creds = flow.run_console()
    token_path.write_text(creds.to_json(), encoding="utf-8")

  return creds


def create_broadcast_and_stream(youtube, title: str, privacy_status: str):
  now = datetime.datetime.utcnow().isoformat("T") + "Z"

  logging.info("建立 YouTube 直播間 ...")
  broadcast = (
    youtube.liveBroadcasts()
    .insert(
      part="snippet,contentDetails,status",
      body={
        "snippet": {
          "title": title,
          "scheduledStartTime": now,
        },
        "status": {"privacyStatus": privacy_status},
        "contentDetails": {
          "monitorStream": {"enableMonitorStream": False},
        },
      },
    )
    .execute()
  )

  logging.info("建立 RTMP 串流 ...")
  stream = (
    youtube.liveStreams()
    .insert(
      part="snippet,cdn,contentDetails",
      body={
        "snippet": {"title": title},
        "cdn": {
          "ingestionType": "rtmp",
          "resolution": "variable",
          "frameRate": "variable",
        },
      },
    )
    .execute()
  )

  logging.info("綁定直播間與串流 ...")
  youtube.liveBroadcasts().bind(
    part="id,contentDetails",
    id=broadcast["id"],
    streamId=stream["id"],
  ).execute()

  ingestion = stream["cdn"]["ingestionInfo"]
  rtmp_url = f"{ingestion['ingestionAddress']}/{ingestion['streamName']}"

  logging.info("建立完成，直播 ID：%s", broadcast["id"])
  logging.info("RTMP 推流地址：%s", rtmp_url)

  return broadcast["id"], rtmp_url


def transition_broadcast(youtube, broadcast_id: str, status: str):
  try:
    youtube.liveBroadcasts().transition(
      part="status", id=broadcast_id, broadcastStatus=status
    ).execute()
    logging.info("已將直播 %s 狀態切換為 %s", broadcast_id, status)
  except Exception as e:  # noqa: BLE001
    logging.warning("切換直播狀態失敗：%s", e)


# ------------------ 探針 & ffmpeg ------------------


def probe_source_http(url: str, timeout: int = 5) -> bool:
  """HTTP 探針：適用 http(s) / flv / m3u8 等，僅做存活檢查。"""
  try:
    resp = requests.get(url, stream=True, timeout=timeout)
    # 只讀幾 KB 測試是否有資料輸出
    chunk = next(resp.iter_content(chunk_size=1024), None)
    resp.close()
    if chunk:
      logging.debug("探針：源有數據流動。")
      return True
    logging.debug("探針：源暫無數據。")
    return False
  except Exception as e:  # noqa: BLE001
    logging.debug("探針失敗：%s", e)
    return False


def start_ffmpeg(source_url: str, rtmp_url: str) -> subprocess.Popen:
  """
  啟動 ffmpeg 轉推：
  - 盡量保持原始碼流（-c copy），只做容器轉封裝
  - 啟用自動重連參數
  """
  cmd = [
    "ffmpeg",
    "-reconnect",
    "1",
    "-reconnect_streamed",
    "1",
    "-reconnect_delay_max",
    "5",
    "-i",
    source_url,
    "-c",
    "copy",
    "-f",
    "flv",
    rtmp_url,
  ]
  logging.info("啟動 ffmpeg：%s", " ".join(cmd))
  return subprocess.Popen(cmd, stdout=sys.stdout, stderr=sys.stdout)


# ------------------ 主邏輯：探針 + 重連窗口 ------------------


class AutoRelay:
  def __init__(
    self,
    source_url: str,
    youtube,
    title: str,
    reconnect_seconds: int,
    probe_interval: int,
    privacy_status: str,
  ):
    self.source_url = source_url
    self.youtube = youtube
    self.title = title
    self.reconnect_seconds = reconnect_seconds
    self.probe_interval = probe_interval
    self.privacy_status = privacy_status

    self.current_broadcast_id: str | None = None
    self.current_rtmp_url: str | None = None
    self.ffmpeg_proc: subprocess.Popen | None = None

    self.last_live_end: float | None = None
    self._stop = False

  # ---- 信號處理 ----
  def stop(self, *_):
    logging.info("收到停止信號，正在清理 ...")
    self._stop = True
    if self.ffmpeg_proc and self.ffmpeg_proc.poll() is None:
      try:
        self.ffmpeg_proc.terminate()
      except Exception:
        pass

  # ---- 狀態機 ----

  def _wait_for_source_online(self):
    """阻塞等待直播源開播。"""
    logging.info("探針啟動，開始輪詢直播源 ...")
    while not self._stop:
      if probe_source_http(self.source_url):
        logging.info("探針：檢測到直播源在線。")
        return
      logging.info("直播源離線，%d 秒後重試 ...", self.probe_interval)
      time.sleep(self.probe_interval)

  def _ensure_broadcast(self):
    if self.current_broadcast_id and self.current_rtmp_url:
      return
    self.current_broadcast_id, self.current_rtmp_url = create_broadcast_and_stream(
      self.youtube, self.title, self.privacy_status
    )

  def _run_ffmpeg_until_stop(self):
    assert self.current_rtmp_url is not None
    self.ffmpeg_proc = start_ffmpeg(self.source_url, self.current_rtmp_url)
    start_time = time.time()
    try:
      while not self._stop:
        ret = self.ffmpeg_proc.poll()
        if ret is None:
          time.sleep(5)
          continue
        # ffmpeg 已退出
        break
    finally:
      end_time = time.time()
      self.last_live_end = end_time
      uptime = end_time - start_time
      logging.info("ffmpeg 已退出，本輪推流持續 %.1f 秒。", uptime)

  def run(self):
    """
    狀態機：
    idle -> source online -> 建立直播間 -> pushing
    pushing -> ffmpeg 退出 -> waiting_reconnect
    waiting_reconnect:
       - 若超過 reconnect_seconds，complete 本場直播 -> idle
       - 若未超時且源重新在線 -> 重啟 ffmpeg（同一直播間）
    """
    logging.info(
      "自動轉播啟動，重連窗口：%d 秒，探針間隔：%d 秒，隱私：%s",
      self.reconnect_seconds,
      self.probe_interval,
      self.privacy_status,
    )
    state = "idle"

    while not self._stop:
      if state == "idle":
        self.current_broadcast_id = None
        self.current_rtmp_url = None
        logging.info("狀態：idle，等待主播開播 ...")
        self._wait_for_source_online()
        if self._stop:
          break
        self._ensure_broadcast()
        state = "pushing"

      elif state == "pushing":
        logging.info("狀態：pushing，開始推流 ...")
        self._run_ffmpeg_until_stop()
        if self._stop:
          break
        state = "waiting_reconnect"

      elif state == "waiting_reconnect":
        if self.last_live_end is None:
          state = "idle"
          continue

        elapsed = time.time() - self.last_live_end
        if elapsed > self.reconnect_seconds:
          logging.info(
            "斷線已超過重連窗口 (%d 秒 > %d 秒)，視為本場直播結束。",
            int(elapsed),
            self.reconnect_seconds,
          )
          if self.current_broadcast_id:
            transition_broadcast(self.youtube, self.current_broadcast_id, "complete")
          state = "idle"
          continue

        logging.info(
          "等待主播重新開播（已離線 %.0f 秒 / 窗口 %d 秒）...",
          elapsed,
          self.reconnect_seconds,
        )
        if probe_source_http(self.source_url):
          logging.info("探針：源重新在線，在同一直播間內重啟 ffmpeg。")
          state = "pushing"
        else:
          time.sleep(self.probe_interval)

    logging.info("自動轉播進程結束。")


# ------------------ CLI ------------------


def parse_args():
  p = argparse.ArgumentParser(
    description="Magic Stream 自動轉播腳本（探針 + YouTube API + ffmpeg 重連）"
  )
  p.add_argument("--source-url", required=True, help="直播源地址（http-flv / m3u8 等）")
  p.add_argument("--title", required=True, help="YouTube 直播標題")
  p.add_argument(
    "--reconnect-seconds",
    type=int,
    default=300,
    help="斷線重連窗口（秒），超過視為本場直播結束",
  )
  p.add_argument(
    "--probe-interval",
    type=int,
    default=30,
    help="探針檢測間隔（秒）",
  )
  p.add_argument(
    "--privacy-status",
    choices=["public", "unlisted", "private"],
    default="unlisted",
    help="直播隱私狀態",
  )
  p.add_argument(
    "--auth-dir",
    default=str(Path(__file__).resolve().parent / "youtube_auth"),
    help="存放 client_secret.json / token.json 的目錄",
  )
  p.add_argument(
    "--log-level",
    default="info",
    choices=["debug", "info", "warning", "error"],
    help="日誌等級",
  )
  return p.parse_args()


def main():
  args = parse_args()

  logging.basicConfig(
    level=getattr(logging, args.log_level.upper(), logging.INFO),
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
  )

  auth_dir = Path(args.auth_dir)
  creds = get_credentials(auth_dir)
  youtube = build("youtube", "v3", credentials=creds)

  relay = AutoRelay(
    source_url=args.source_url,
    youtube=youtube,
    title=args.title,
    reconnect_seconds=args.reconnect_seconds,
    probe_interval=args.probe_interval,
    privacy_status=args.privacy_status,
  )

  # 信號處理
  signal.signal(signal.SIGINT, relay.stop)
  signal.signal(signal.SIGTERM, relay.stop)

  try:
    relay.run()
  except KeyboardInterrupt:
    relay.stop()
  finally:
    logging.info("腳本已退出。")


if __name__ == "__main__":
  main()
