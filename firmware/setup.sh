#!/bin/bash
# Visionary AI Glasses — one-shot Pi provisioning for Raspberry Pi OS Bookworm (Lite, 64-bit)
# Run from the repo:  sudo bash firmware/setup.sh [--with-whisper] [--with-wakeword]
# Idempotent: safe to re-run after a git pull.
set -euo pipefail

WITH_WHISPER=0
WITH_WAKEWORD=0
for arg in "$@"; do
  case "$arg" in
    --with-whisper)  WITH_WHISPER=1 ;;
    --with-wakeword) WITH_WAKEWORD=1 ;;
    *) echo "unknown option: $arg (supported: --with-whisper, --with-wakeword)" >&2; exit 2 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "run as root: sudo bash $0" >&2
  exit 1
fi

SRC="$(cd "$(dirname "$0")" && pwd)"    # the repo's firmware/ dir
HOME_DIR=/opt/visionary
APP="$HOME_DIR/app"

echo "== 1/7 apt packages =="
apt-get update
apt-get install -y python3-picamera2 python3-gpiozero python3-requests \
  python3-pil python3-pip python3-numpy tesseract-ocr python3-pytesseract \
  espeak-ng alsa-utils sox avahi-daemon rsync git

echo "== 2/7 I2S audio overlay (MAX98357A out + ICS-43434 in) =="
CONFIG=/boot/firmware/config.txt
if grep -q '^dtparam=audio=' "$CONFIG"; then
  sed -i 's/^dtparam=audio=on/dtparam=audio=off/' "$CONFIG"
else
  echo 'dtparam=audio=off' >> "$CONFIG"
fi
grep -q 'googlevoicehat' "$CONFIG" || cat >> "$CONFIG" <<'EOF'
# Visionary: MAX98357A (out) + ICS-43434 (in) on one I2S bus
dtoverlay=googlevoicehat-soundcard
EOF

echo "== 3/7 pip packages =="
pip3 install --break-system-packages piper-tts fastapi uvicorn qrcode

echo "== 4/7 Piper voice (en_US-lessac-low) =="
mkdir -p "$HOME_DIR/voices" "$HOME_DIR/sounds" "$HOME_DIR/captures" "$HOME_DIR/recordings"
mkdir -p /var/log/visionary
V="$HOME_DIR/voices"
BASE=https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/low
# Each file goes to its own name: the old code/setup.sh clobbered the .onnx weights
# with the .onnx.json config (both wget'd to the same target). Keep them separate.
if [ ! -s "$V/en_US-lessac-low.onnx" ]; then
  wget -q -O "$V/en_US-lessac-low.onnx" "$BASE/en_US-lessac-low.onnx"
fi
if [ ! -s "$V/en_US-lessac-low.onnx.json" ]; then
  wget -q -O "$V/en_US-lessac-low.onnx.json" "$BASE/en_US-lessac-low.onnx.json"
fi

echo "== 5/7 feedback earcons =="
S="$HOME_DIR/sounds"
sox -n -r 22050 -c 1 "$S/capture.wav"   synth 0.12 sine 880 vol 0.5
sox -n -r 22050 -c 1 "$S/ok.wav"        synth 0.10 sine 1320 : synth 0.10 sine 1760 vol 0.5
sox -n -r 22050 -c 1 "$S/err.wav"       synth 0.25 sine 220 vol 0.6
sox -n -r 22050 -c 1 "$S/offline.wav"   synth 0.10 sine 660 : synth 0.10 sine 440 vol 0.5
sox -n -r 22050 -c 1 "$S/rec_start.wav" synth 0.20 sine 440:1040 vol 0.5   # rising = recording on
sox -n -r 22050 -c 1 "$S/rec_stop.wav"  synth 0.20 sine 1040:440 vol 0.5   # falling = recording off

echo "== 6/7 install app -> $APP =="
# Keep a full git checkout on-device so POST /update can `git pull` and re-sync
# firmware/ into $APP. The app dir itself is a flattened copy of firmware/, so it
# can't be a git tree; the checkout under $SRC_CHECKOUT is.
REPO="$(cd "$SRC/.." && pwd)"
SRC_CHECKOUT="$HOME_DIR/src"
APP_SRC="$SRC"
if command -v git >/dev/null 2>&1 && [ -d "$REPO/.git" ]; then
  if [ -d "$SRC_CHECKOUT/.git" ]; then
    git -C "$SRC_CHECKOUT" pull --ff-only || true
  else
    rm -rf "$SRC_CHECKOUT"
    if git clone "$REPO" "$SRC_CHECKOUT"; then
      # point OTA at the real remote (a local clone would set origin to $REPO)
      ORIGIN="$(git -C "$REPO" config --get remote.origin.url || true)"
      [ -n "$ORIGIN" ] && git -C "$SRC_CHECKOUT" remote set-url origin "$ORIGIN"
    fi
  fi
  [ -d "$SRC_CHECKOUT/firmware" ] && APP_SRC="$SRC_CHECKOUT/firmware"
fi
mkdir -p "$APP"
rsync -a --delete --exclude '__pycache__' --exclude '*.pyc' "$APP_SRC/" "$APP/"

touch /etc/visionary.env
# Add placeholders only when absent — never clobber keys the operator already set.
grep -q '^ANTHROPIC_API_KEY=' /etc/visionary.env || \
  echo 'ANTHROPIC_API_KEY=PUT_YOUR_KEY_HERE' >> /etc/visionary.env
grep -q '^OPENAI_API_KEY=' /etc/visionary.env || \
  echo 'OPENAI_API_KEY=' >> /etc/visionary.env
chmod 600 /etc/visionary.env

echo "== 7/7 services (firmware + local API + avahi) =="
install -m 644 "$APP/systemd/visionary.service" /etc/systemd/system/visionary.service
install -m 644 "$APP/systemd/visionary-api.service" /etc/systemd/system/visionary-api.service
mkdir -p /etc/avahi/services
install -m 644 "$APP/systemd/avahi-visionary.service" /etc/avahi/services/visionary.service
systemctl daemon-reload
systemctl enable visionary.service visionary-api.service avahi-daemon.service
systemctl restart avahi-daemon.service || true

if [ "$WITH_WHISPER" -eq 1 ]; then
  echo "== optional: whisper.cpp (offline STT) =="
  apt-get install -y git build-essential cmake
  W="$HOME_DIR/whisper"
  mkdir -p "$W"
  if [ ! -x "$W/main" ]; then
    WSRC="$W/src"
    if [ ! -d "$WSRC/.git" ]; then
      git clone --depth 1 https://github.com/ggml-org/whisper.cpp "$WSRC"
    fi
    make -C "$WSRC" -j2
    BIN=""
    # binary name/location moved across whisper.cpp releases
    for c in "$WSRC/main" "$WSRC/build/bin/main" "$WSRC/build/bin/whisper-cli"; do
      if [ -x "$c" ]; then BIN="$c"; break; fi
    done
    if [ -z "$BIN" ]; then
      echo "whisper.cpp build produced no usable binary" >&2
      exit 1
    fi
    install -m 755 "$BIN" "$W/main"
  fi
  if [ ! -s "$W/ggml-tiny.en.bin" ]; then
    wget -q -O "$W/ggml-tiny.en.bin" \
      https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin
  fi
fi

if [ "$WITH_WAKEWORD" -eq 1 ]; then
  echo "== optional: openWakeWord (hands-free trigger) =="
  pip3 install --break-system-packages openwakeword
  # Pre-download the pretrained models (melspectrogram + embedding + wakewords incl.
  # hey_jarvis, the shipped default) so the first boot doesn't reach for the network.
  python3 -c "import openwakeword.utils as u; u.download_models()" || {
    echo "openWakeWord model download failed; check network and re-run --with-wakeword" >&2
    exit 1
  }
fi

echo
echo "Setup complete. Next steps:"
echo "  1. Put your API keys in /etc/visionary.env (ANTHROPIC_API_KEY required, OPENAI_API_KEY optional)"
echo "  2. Reboot to load the I2S audio overlay:  sudo reboot"
echo "  3. After reboot the device speaks 'Visionary ready' and, on first boot, its 6-digit pairing code"
echo "     (QR image at $HOME_DIR/pairing_qr.png for the iOS app)"
echo "  4. Test audio:  speaker-test -c1 -t sine -f 440"
if [ "$WITH_WHISPER" -eq 0 ]; then
  echo "  -  Offline voice input? re-run with --with-whisper"
fi
if [ "$WITH_WAKEWORD" -eq 0 ]; then
  echo "  -  Hands-free wake word? re-run with --with-wakeword"
fi
