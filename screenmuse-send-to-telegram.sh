#!/bin/bash
# Send screenshots/videos directly to Telegram using OpenClaw

set -e

MEDIA_FILE="$1"
CAPTION="${2:-ScreenMuse screenshot}"

if [ ! -f "$MEDIA_FILE" ]; then
    echo "Usage: $0 <file.png|file.mp4> [caption]"
    exit 1
fi

# Get file extension
EXT="${MEDIA_FILE##*.}"

echo "📤 Sending $MEDIA_FILE to Telegram..."

case "$EXT" in
    png|jpg|jpeg)
        # Send as photo
        curl -X POST \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendPhoto" \
            -F "chat_id=${TELEGRAM_CHAT_ID}" \
            -F "photo=@${MEDIA_FILE}" \
            -F "caption=${CAPTION}"
        ;;
    mp4|mov)
        # Send as video
        curl -X POST \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendVideo" \
            -F "chat_id=${TELEGRAM_CHAT_ID}" \
            -F "video=@${MEDIA_FILE}" \
            -F "caption=${CAPTION}"
        ;;
    *)
        # Send as document
        curl -X POST \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
            -F "chat_id=${TELEGRAM_CHAT_ID}" \
            -F "document=@${MEDIA_FILE}" \
            -F "caption=${CAPTION}"
        ;;
esac

echo ""
echo "✅ Sent!"
