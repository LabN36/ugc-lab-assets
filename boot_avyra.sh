#!/bin/bash
set -e
pip install -q runpod
apt-get -qq update >/dev/null 2>&1 || true
apt-get -qq install -y ffmpeg >/dev/null 2>&1 || true
curl -sfL https://raw.githubusercontent.com/LabN36/ugc-lab-assets/main/worker_avyra.py -o /w.py
exec python /w.py
