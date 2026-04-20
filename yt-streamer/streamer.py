import os
import random
import subprocess
import tempfile
import time
import logging

import boto3

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

STREAM_KEY  = os.environ["YOUTUBE_STREAM_KEY"]
S3_BUCKET   = os.environ["S3_BUCKET"]
S3_PREFIX   = os.environ.get("S3_PREFIX", "videos/")
BITRATE     = os.environ.get("VIDEO_BITRATE", "3000k")
RTMP_URL    = f"rtmp://a.rtmp.youtube.com/live2/{STREAM_KEY}"


def list_s3_videos():
    s3 = boto3.client("s3")
    resp = s3.list_objects_v2(Bucket=S3_BUCKET, Prefix=S3_PREFIX)
    return [
        obj["Key"]
        for obj in resp.get("Contents", [])
        if obj["Key"].lower().endswith((".mp4", ".mkv", ".avi"))
    ]


def download_video(key: str) -> str:
    s3 = boto3.client("s3")
    tmp = tempfile.NamedTemporaryFile(suffix=".mp4", delete=False)
    logging.info("Downloading s3://%s/%s", S3_BUCKET, key)
    s3.download_fileobj(S3_BUCKET, key, tmp)
    tmp.flush()
    return tmp.name


def stream_video(path: str):
    cmd = [
        "ffmpeg", "-re", "-i", path,
        "-c:v", "copy",
        "-c:a", "aac", "-b:a", "128k", "-ar", "44100",
        "-f", "flv", RTMP_URL,
    ]
    logging.info("Streaming: %s", path)
    subprocess.run(cmd, check=False)


def main():
    while True:
        try:
            keys = list_s3_videos()
            if not keys:
                logging.warning("No videos found in s3://%s/%s — retrying in 60s", S3_BUCKET, S3_PREFIX)
                time.sleep(60)
                continue

            random.shuffle(keys)
            for key in keys:
                path = download_video(key)
                try:
                    stream_video(path)
                finally:
                    os.unlink(path)

        except Exception:
            logging.exception("Unhandled error — retrying in 30s")
            time.sleep(30)


if __name__ == "__main__":
    main()
