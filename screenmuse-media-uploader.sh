#!/bin/bash
# Upload ScreenMuse screenshots and videos to Cloudflare R2 for sharing

set -e

# Configuration
R2_BUCKET="${R2_BUCKET:-screenmuse-dev}"
R2_ENDPOINT="${R2_ENDPOINT:-https://ACCOUNT_ID.r2.cloudflarestorage.com}"
R2_ACCESS_KEY="${R2_ACCESS_KEY}"
R2_SECRET_KEY="${R2_SECRET_KEY}"
PUBLIC_URL_BASE="${PUBLIC_URL_BASE:-https://screenmuse.dev}"

if [ -z "$R2_ACCESS_KEY" ] || [ -z "$R2_SECRET_KEY" ]; then
    echo "❌ Missing R2 credentials"
    echo "Set R2_ACCESS_KEY and R2_SECRET_KEY environment variables"
    exit 1
fi

MEDIA_FILE="$1"

if [ ! -f "$MEDIA_FILE" ]; then
    echo "Usage: $0 <file.png|file.mp4>"
    exit 1
fi

FILENAME=$(basename "$MEDIA_FILE")
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
UPLOAD_PATH="screenmuse/${TIMESTAMP}-${FILENAME}"

echo "📤 Uploading $FILENAME to R2..."

# Upload using AWS S3 CLI (R2 is S3-compatible)
aws s3 cp "$MEDIA_FILE" \
    "s3://${R2_BUCKET}/${UPLOAD_PATH}" \
    --endpoint-url "$R2_ENDPOINT" \
    --profile r2

PUBLIC_URL="${PUBLIC_URL_BASE}/${UPLOAD_PATH}"

echo "✅ Uploaded!"
echo ""
echo "🔗 Public URL:"
echo "$PUBLIC_URL"
echo ""
echo "📋 Copy to clipboard:"
echo "$PUBLIC_URL" | pbcopy 2>/dev/null && echo "   ✅ Copied!" || echo "   (Manual copy needed)"
