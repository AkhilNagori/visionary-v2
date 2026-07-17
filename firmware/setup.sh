#!/bin/bash
# Visionary AI Glasses — one-shot Pi provisioning for Raspberry Pi OS Bookworm/Trixie Lite
# Run from the repo:  sudo bash firmware/setup.sh
# Idempotent: safe to re-run after a git pull.
set -euo pipefail

if [ "$#" -ne 0 ]; then
  echo "setup.sh no longer accepts local-model flags; run it with no options" >&2
  exit 2
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "run as root: sudo bash $0" >&2
  exit 1
fi

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  arm64|armhf) ;;
  *) echo "unsupported architecture: $ARCH (expected arm64 or armhf)" >&2; exit 1 ;;
esac

SRC="$(cd "$(dirname "$0")" && pwd)"    # the repo's firmware/ dir
HOME_DIR=/opt/visionary
APP="$HOME_DIR/app"

echo "== 1/7 apt packages =="
apt-get update
apt-get install -y python3-picamera2 python3-gpiozero python3-requests \
  python3-pil python3-pip python3-numpy \
  alsa-utils sox avahi-daemon rsync git

echo "== 2/7 I2S audio overlay (MAX98357A out + ICS-43434 in) =="
CONFIG=/boot/firmware/config.txt
if grep -q '^dtparam=audio=' "$CONFIG"; then
  sed -i 's/^dtparam=audio=on/dtparam=audio=off/' "$CONFIG"
else
  echo 'dtparam=audio=off' >> "$CONFIG"
fi
# Remove the old speaker-only overlay; it conflicts with the duplex sound card.
sed -i -E '/^[[:space:]]*dtoverlay=max98357a([,[:space:]].*)?$/d' "$CONFIG"
grep -Eq '^[[:space:]]*dtoverlay=googlevoicehat-soundcard([,[:space:]].*)?$' "$CONFIG" || cat >> "$CONFIG" <<'EOF'
# Visionary: MAX98357A (out) + ICS-43434 (in) on one I2S bus
dtoverlay=googlevoicehat-soundcard
EOF

echo "== 3/7 pip packages =="
pip3 install --break-system-packages fastapi uvicorn qrcode

echo "== 4/7 runtime directories =="
mkdir -p "$HOME_DIR/sounds" "$HOME_DIR/captures" "$HOME_DIR/recordings"
mkdir -p /var/log/visionary

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
# can't be a git tree; the checkout under $SRC_CHECKOUT is. This setup run copies
# the exact working tree it was launched from; the checkout is for later OTA pulls.
REPO="$(cd "$SRC/.." && pwd)"
SRC_CHECKOUT="$HOME_DIR/src"
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
fi
mkdir -p "$APP"
rsync -a --delete --exclude '__pycache__' --exclude '*.pyc' "$SRC/" "$APP/"

touch /etc/visionary.env
# Add the placeholder only when absent — never clobber a key the operator set.
grep -q '^OPENAI_API_KEY=' /etc/visionary.env || \
  echo 'OPENAI_API_KEY=PUT_YOUR_KEY_HERE' >> /etc/visionary.env
# Measured defaults for the shipped ICS-43434 wiring (SEL -> GND / left slot).
# Preserve operator tuning on every idempotent setup run.
grep -q '^VISIONARY_MIC_CHANNEL=' /etc/visionary.env || \
  echo 'VISIONARY_MIC_CHANNEL=1' >> /etc/visionary.env
grep -q '^VISIONARY_MIC_GAIN_DB=' /etc/visionary.env || \
  echo 'VISIONARY_MIC_GAIN_DB=24' >> /etc/visionary.env
grep -q '^VISIONARY_MIC_HIGHPASS_HZ=' /etc/visionary.env || \
  echo 'VISIONARY_MIC_HIGHPASS_HZ=100' >> /etc/visionary.env
chmod 600 /etc/visionary.env

echo "== 7/7 services (firmware + local API + avahi) =="
install -m 644 "$APP/systemd/visionary.service" /etc/systemd/system/visionary.service
install -m 644 "$APP/systemd/visionary-api.service" /etc/systemd/system/visionary-api.service
mkdir -p /etc/avahi/services
install -m 644 "$APP/systemd/avahi-visionary.service" /etc/avahi/services/visionary.service
systemctl daemon-reload
systemctl enable visionary.service visionary-api.service avahi-daemon.service
systemctl restart avahi-daemon.service || true

echo
echo "Setup complete. Next steps:"
echo "  1. Put your API key in /etc/visionary.env (OPENAI_API_KEY required)"
echo "  2. Reboot to load the I2S audio overlay:  sudo reboot"
echo "  3. After reboot the device speaks 'Visionary ready' and, on first boot, its 6-digit pairing code"
echo "     (QR image at $HOME_DIR/pairing_qr.png for the iOS app)"
echo "  4. Test audio:  speaker-test -c1 -t sine -f 440"
echo "  5. AI speech is generated by OpenAI; internet access is required"
