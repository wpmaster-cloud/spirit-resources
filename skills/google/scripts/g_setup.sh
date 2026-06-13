#!/usr/bin/env bash
# Verify the Google credentials end-to-end: mint an access token, then call the
# Gmail profile and Drive "about" endpoints. Prints the account email and Drive
# storage so you know the refresh token works and which scopes it carries.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null || true   # workspace root
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

echo "==> Minting access token from refresh token..."
tok=$(g_access_token) || die "could not mint an access token — check GOOGLE_CLIENT_ID/SECRET/REFRESH_TOKEN"
echo "    ok (cached in $TOKEN_CACHE)"

echo "==> Gmail profile (needs a gmail.* scope)..."
prof=$(gapi "https://gmail.googleapis.com/gmail/v1/users/me/profile" || true)
email=$(printf '%s' "$prof" | jq -r '.emailAddress // empty')
if [ -n "$email" ]; then
  echo "    email: $email  (messages: $(printf '%s' "$prof" | jq -r '.messagesTotal // "?"'))"
else
  echo "    WARN: no Gmail access — $(printf '%s' "$prof" | jq -r '.error.message // .')"
fi

echo "==> Drive about (needs a drive.* scope)..."
about=$(gapi "https://www.googleapis.com/drive/v3/about?fields=user(emailAddress),storageQuota(usage,limit)" || true)
duser=$(printf '%s' "$about" | jq -r '.user.emailAddress // empty')
if [ -n "$duser" ]; then
  used=$(printf '%s' "$about" | jq -r '.storageQuota.usage // "?"')
  lim=$(printf '%s' "$about"  | jq -r '.storageQuota.limit // "unlimited"')
  echo "    drive user: $duser  (storage: $used / $lim bytes)"
else
  echo "    WARN: no Drive access — $(printf '%s' "$about" | jq -r '.error.message // .')"
fi

echo "==> Calendar list (needs a calendar.* scope)..."
cals=$(gapi "https://www.googleapis.com/calendar/v3/users/me/calendarList?fields=items(id,primary)" || true)
ncal=$(printf '%s' "$cals" | jq -r '.items | length' 2>/dev/null || echo "")
if [ -n "$ncal" ] && [ "$ncal" != "null" ]; then
  echo "    calendars accessible: $ncal"
else
  echo "    WARN: no Calendar access — $(printf '%s' "$cals" | jq -r '.error.message // .')"
fi

echo "==> Done. If a scope is missing, re-mint the refresh token with it (references/google-api.md)."
