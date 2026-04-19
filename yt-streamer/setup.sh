#!/bin/bash
set -e

# Install dependencies
sudo apt-get update -y
sudo apt-get install -y ffmpeg python3-pip

pip3 install boto3

# Copy streamer script
sudo mkdir -p /opt/yt-streamer
sudo cp streamer.py /opt/yt-streamer/streamer.py

# Create systemd service
sudo tee /etc/systemd/system/yt-streamer.service > /dev/null <<EOF
[Unit]
Description=YouTube 24/7 Auto Streamer
After=network.target

[Service]
ExecStart=/usr/bin/python3 -u /opt/yt-streamer/streamer.py
Restart=always
RestartSec=10
User=ubuntu
EnvironmentFile=/opt/yt-streamer/.env

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable yt-streamer
echo "Setup complete. Add your .env file at /opt/yt-streamer/.env then run: sudo systemctl start yt-streamer"
