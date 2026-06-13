#!/usr/bin/env bash
# Send an email through the Gmail API (users.me.messages.send). Builds an RFC 822
# message (plain text or HTML, optional attachments), base64url-encodes it, and
# POSTs {"raw": ...}. Needs a gmail.send (or broader gmail) scope.
#
# Usage:
#   gmail_send.sh --to a@x.com --subject "Hi" --body "text"
#   gmail_send.sh --to a@x.com --cc b@x.com --subject S --html-file out.html --attach r.pdf
#   echo "$BODY" | gmail_send.sh --to a@x.com --subject S --stdin
# Flags: --to (repeatable), --cc, --bcc, --subject, --body|--body-file|--stdin,
#        --html|--html-file, --attach (repeatable), --from-name.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null || true
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

TO=() CC=() BCC=() ATT=(); SUBJECT=""; BODY=""; HTML=""; FROM_NAME=""; USE_HTML=0
while [ $# -gt 0 ]; do
  case "$1" in
    --to)        TO+=("$2"); shift 2;;
    --cc)        CC+=("$2"); shift 2;;
    --bcc)       BCC+=("$2"); shift 2;;
    --subject)   SUBJECT="$2"; shift 2;;
    --body)      BODY="$2"; shift 2;;
    --body-file) BODY="$(cat "$2")"; shift 2;;
    --stdin)     BODY="$(cat)"; shift;;
    --html)      HTML="$2"; USE_HTML=1; shift 2;;
    --html-file) HTML="$(cat "$2")"; USE_HTML=1; shift 2;;
    --attach)    ATT+=("$2"); shift 2;;
    --from-name) FROM_NAME="$2"; shift 2;;
    *) die "unknown flag: $1";;
  esac
done
[ ${#TO[@]} -gt 0 ] || die "need at least one --to"
[ -n "$SUBJECT" ] || die "need --subject"

join() { local IFS=", "; echo "$*"; }   # comma-join an array
content_body() { [ "$USE_HTML" = 1 ] && printf '%s' "$HTML" || printf '%s' "$BODY"; }
ctype()        { [ "$USE_HTML" = 1 ] && echo "text/html" || echo "text/plain"; }

msg="$(mktemp)"; trap 'rm -f "$msg"' EXIT
{
  [ -n "$FROM_NAME" ] && printf 'From: %s\r\n' "$FROM_NAME"
  printf 'To: %s\r\n' "$(join "${TO[@]}")"
  [ ${#CC[@]}  -gt 0 ] && printf 'Cc: %s\r\n'  "$(join "${CC[@]}")"
  [ ${#BCC[@]} -gt 0 ] && printf 'Bcc: %s\r\n' "$(join "${BCC[@]}")"
  printf 'Subject: %s\r\n' "$SUBJECT"
  printf 'MIME-Version: 1.0\r\n'

  if [ ${#ATT[@]} -gt 0 ]; then
    b="mixed_$(date +%s)_$$"
    printf 'Content-Type: multipart/mixed; boundary="%s"\r\n\r\n' "$b"
    printf -- '--%s\r\n' "$b"
    printf 'Content-Type: %s; charset=UTF-8\r\n\r\n' "$(ctype)"
    content_body; printf '\r\n'
    for f in "${ATT[@]}"; do
      [ -f "$f" ] || die "attachment not found: $f"
      printf -- '--%s\r\n' "$b"
      printf 'Content-Type: application/octet-stream; name="%s"\r\n' "$(basename "$f")"
      printf 'Content-Transfer-Encoding: base64\r\n'
      printf 'Content-Disposition: attachment; filename="%s"\r\n\r\n' "$(basename "$f")"
      base64 < "$f"; printf '\r\n'
    done
    printf -- '--%s--\r\n' "$b"
  else
    printf 'Content-Type: %s; charset=UTF-8\r\n\r\n' "$(ctype)"
    content_body
  fi
} > "$msg"

raw=$(b64url < "$msg")
resp=$(gapi -X POST "https://gmail.googleapis.com/gmail/v1/users/me/messages/send" \
  -H "Content-Type: application/json" \
  --data-binary @<(jq -nc --arg raw "$raw" '{raw:$raw}'))

id=$(printf '%s' "$resp" | jq -r '.id // empty')
[ -n "$id" ] && echo "sent ok: id=$id" || die "send failed: $(printf '%s' "$resp" | jq -r '.error.message // .')"
