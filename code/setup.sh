#!/bin/bash
# Visionary AI Glasses — one-shot setup for Raspberry Pi OS Bookworm (Lite, 64-bit)
# Run: sudo bash setup.sh
set -e

echo "== 1/6 Packages =="
apt update
apt install -y python3-picamera2 python3-gpiozero python3-requests \
  python3-pil python3-pip tesseract-ocr python3-pytesseract \
  espeak-ng alsa-utils sox

echo "== 2/6 I2S audio (MAX98357A) =="
CONFIG=/boot/firmware/config.txt
sed -i 's/^dtparam=audio=on/dtparam=audio=off/' $CONFIG
grep -q "googlevoicehat" $CONFIG || cat >> $CONFIG <<'EOF'
# Visionary: MAX98357A (out) + ICS-43434 (in) on one I2S bus
dtoverlay=googlevoicehat-soundcard
EOF

echo "== 3/6 Piper TTS =="
pip3 install piper-tts --break-system-packages || pip3 install piper-tts
mkdir -p /opt/visionary/voices /opt/visionary/sounds
V=/opt/visionary/voices
BASE=https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/low
[ -f $V/en_US-lessac-low.onnx ] || {
  wget -q -O $V/en_US-lessac-low.onnx  "$BASE/en_US-lessac-low.onnx"
  wget -q -O $V/en_US-lessac-low.onnx.json "$BASE/en_US-lessac-low.onnx.json"
}

echo "== 4/6 Feedback beeps =="
S=/opt/visionary/sounds
sox -n -r 22050 -c 1 $S/capture.wav synth 0.12 sine 880 vol 0.5
sox -n -r 22050 -c 1 $S/ok.wav      synth 0.10 sine 1320 : synth 0.10 sine 1760 vol 0.5
sox -n -r 22050 -c 1 $S/err.wav     synth 0.25 sine 220 vol 0.6
sox -n -r 22050 -c 1 $S/offline.wav synth 0.10 sine 660 : synth 0.10 sine 440 vol 0.5

echo "== 5/6 Install app =="
install -m 755 "$(dirname "$0")/visionary.py" /opt/visionary/visionary.py
touch /etc/visionary.env
grep -q ANTHROPIC_API_KEY /etc/visionary.env || \
  echo 'ANTHROPIC_API_KEY=PUT_YOUR_KEY_HERE' >> /etc/visionary.env
chmod 600 /etc/visionary.env

echo "== 6/6 systemd service (starts on boot) =="
cat > /etc/systemd/system/visionary.service <<'EOF'
[Unit]
Description=Visionary AI Glasses
After=network.target

[Service]
EnvironmentFile=/etc/visionary.env
ExecStart=/usr/bin/python3 /opt/visionary/visionary.py
Restart=on-failure
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable visionary

echo
echo "DONE. Now: 1) put your API key in /etc/visionary.env  2) reboot"
echo "Test audio after reboot:  speaker-test -c1 -t sine -f 440"
