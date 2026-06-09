# Telegram Bot API — curl reference

Everything here is plain HTTPS. Base URL for every call:

```
https://api.telegram.org/bot<TOKEN>/<method>
```

The bundled scripts wrap the common cases; reach for raw `curl` (or extend the
scripts) for anything below.

## Table of contents
1. [Response shape](#response-shape)
2. [The update object (getUpdates)](#the-update-object-getupdates)
3. [Sending text](#sending-text)
4. [Parse modes & escaping](#parse-modes--escaping)
5. [Sending media & files](#sending-media--files)
6. [Chat actions, editing, deleting](#chat-actions-editing-deleting)
7. [Keyboards & buttons](#keyboards--buttons)
8. [Long polling vs webhooks](#long-polling-vs-webhooks)
9. [Error codes & rate limits](#error-codes--rate-limits)

---

## Response shape
Every method returns JSON:
```json
{ "ok": true, "result": ... }
```
or on failure:
```json
{ "ok": false, "error_code": 400, "description": "Bad Request: ..." }
```
Always branch on `.ok` first.

## The update object (getUpdates)
`GET/POST getUpdates` returns `result` as an array of **updates**. Each update has
a monotonically increasing `update_id` and exactly one content field — usually
`message`, but also `edited_message`, `channel_post`, `callback_query`
(button presses), `inline_query`, etc.

```jsonc
{
  "update_id": 123456789,
  "message": {
    "message_id": 42,
    "from": { "id": 11111, "first_name": "Ada", "username": "ada", "is_bot": false },
    "chat": { "id": 11111, "type": "private", "first_name": "Ada" },
    "date": 1717600000,
    "text": "hello",                      // or .caption on media; absent on stickers/locations
    "reply_to_message": { ... },          // present if the user replied to a message
    "photo": [ ... ], "document": { ... },"voice": { ... }   // media variants
  }
}
```

**Offset / acknowledgement.** Pass `offset=<last_update_id + 1>` to get only newer
updates; this also confirms (drops) all updates with a lower id server-side. This
is how `tg_read.sh` guarantees each message is read once. Updates are otherwise
retained ~24h.

```bash
curl -sS "https://api.telegram.org/bot$TOKEN/getUpdates" \
  -d offset=123456790 -d timeout=25 -d limit=100 \
  -d allowed_updates='["message","callback_query"]'
```
`timeout` = long-poll seconds (server holds the connection until a message arrives
or the timeout elapses). `allowed_updates` filters update types.

## Sending text
```bash
curl -sS "https://api.telegram.org/bot$TOKEN/sendMessage" \
  -d chat_id="$CHAT" \
  --data-urlencode text="Multi-line
and emoji 🚀 are fine via --data-urlencode" \
  -d disable_notification=true \
  -d reply_to_message_id=42
```
`chat_id` accepts a numeric id or a public `@channelusername`. Always use
`--data-urlencode` for `text` so newlines/quotes/special chars survive.

## Parse modes & escaping
Default is plain text. To format, add `parse_mode`:

- **`HTML`** (easiest to escape): allowed tags `b i u s a code pre`. Escape only
  `&` `<` `>` in the body (as `&amp; &lt; &gt;`).
  ```
  -d parse_mode=HTML --data-urlencode text='<b>Bold</b> <code>x &lt; y</code>'
  ```
- **`MarkdownV2`** (strict): you MUST backslash-escape every one of these
  characters when they appear as literal text:
  ```
  _ * [ ] ( ) ~ ` > # + - = | { } . !
  ```
  Forgetting even one returns `400 Bad Request: can't parse entities`. Because
  this is error-prone, prefer plain text or HTML unless you specifically need
  MarkdownV2.

When unsure, send plain text (omit `parse_mode`) — it never 400s on content.

## Sending media & files
By URL or `file_id` (cheap, no upload), or by uploading a local file with `-F`.
```bash
# photo by URL
curl -sS "https://api.telegram.org/bot$TOKEN/sendPhoto" \
  -d chat_id="$CHAT" -d photo="https://example.com/pic.png" \
  --data-urlencode caption="a caption"

# document upload (multipart)
curl -sS "https://api.telegram.org/bot$TOKEN/sendDocument" \
  -F chat_id="$CHAT" -F document=@/path/to/report.pdf \
  -F caption="Here is the report"
```
Other media methods: `sendPhoto`, `sendDocument`, `sendAudio`, `sendVoice`,
`sendVideo`, `sendAnimation`, `sendLocation`, `sendMediaGroup` (album).

## Chat actions, editing, deleting
```bash
# "typing…" indicator (also: upload_photo, upload_document, record_voice)
curl -sS "https://api.telegram.org/bot$TOKEN/sendChatAction" -d chat_id="$CHAT" -d action=typing

# edit a message you already sent
curl -sS "https://api.telegram.org/bot$TOKEN/editMessageText" \
  -d chat_id="$CHAT" -d message_id=42 --data-urlencode text="updated"

# delete a message (within 48h, your own)
curl -sS "https://api.telegram.org/bot$TOKEN/deleteMessage" -d chat_id="$CHAT" -d message_id=42
```

## Keyboards & buttons
Pass `reply_markup` as a JSON string.
```bash
# inline buttons (callbacks arrive as update.callback_query)
curl -sS "https://api.telegram.org/bot$TOKEN/sendMessage" \
  -d chat_id="$CHAT" --data-urlencode text="Pick one:" \
  --data-urlencode reply_markup='{"inline_keyboard":[[{"text":"Yes","callback_data":"yes"},{"text":"No","callback_data":"no"}]]}'

# acknowledge a button press so the client stops its spinner
curl -sS "https://api.telegram.org/bot$TOKEN/answerCallbackQuery" -d callback_query_id="$ID" -d text="got it"
```
Custom reply keyboard: `{"keyboard":[["A","B"]],"resize_keyboard":true,"one_time_keyboard":true}`.
Remove it: `{"remove_keyboard":true}`.

## Long polling vs webhooks
A bot uses **either** `getUpdates` (polling — what this skill does) **or** a
webhook, never both at once.
- `getUpdates` while a webhook is set → **HTTP 409 Conflict**. Clear it:
  ```bash
  curl -sS "https://api.telegram.org/bot$TOKEN/deleteWebhook"
  curl -sS "https://api.telegram.org/bot$TOKEN/getWebhookInfo"   # confirm url is empty
  ```
- This runtime has no inbound webhook endpoint, so polling is the right model here.

## Error codes & rate limits
| code | meaning | fix |
|------|---------|-----|
| 400  | bad request (often parse_mode escaping, bad chat_id) | check `description`; try plain text |
| 401  | unauthorized | token wrong/revoked — recheck with `getMe` |
| 403  | bot blocked by user, or never started | the user must `/start` or unblock the bot |
| 409  | conflict — webhook is set, or another `getUpdates` is running | `deleteWebhook`; don't poll twice concurrently |
| 429  | too many requests | back off `result.parameters.retry_after` seconds |

Limits (approx): ~1 message/sec to a single chat, ~30 messages/sec total, ~20
messages/min to a group. Pace bursts; honor `retry_after` on 429.
Message text max length: **4096** characters — split longer content.
