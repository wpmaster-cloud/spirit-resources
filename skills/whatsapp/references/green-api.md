# Green API reference (extended)

Full docs: <https://green-api.com/en/docs/>. Everything below is the subset an
agent is likely to need beyond the bundled scripts.

## URL anatomy

```
{apiUrl}/waInstance{idInstance}/{method}/{apiTokenInstance}
```

- `apiUrl` — per instance, from the console (e.g. `https://7103.api.greenapi.com`).
  Media uploads use the matching `mediaUrl` (e.g. `https://7103.media.greenapi.com`).
- One exception to the shape: `deleteNotification` appends the receipt **after**
  the token: `…/deleteNotification/{apiTokenInstance}/{receiptId}`.
- POST bodies are JSON (`Content-Type: application/json`). Responses are JSON.
- The bundled `_common.sh` provides `wa_api <method> [curl args…]` for all of this.

## chatId formats

| Target | chatId |
|---|---|
| person | `<digits>@c.us` — international format, no `+` (e.g. `79001234567@c.us`) |
| group  | `<id>@g.us` (e.g. `120363043968066463@g.us`) |

Group ids come from incoming notifications (`senderData.chatId`) or `getChats`.

## Account / instance methods

| Method | Verb | Notes |
|---|---|---|
| `getStateInstance` | GET | `{"stateInstance":"authorized"}` — see states below |
| `getSettings` | GET | includes `wid` (the account's own chatId) and all webhook toggles |
| `setSettings` | POST | partial JSON ok; **reboots the instance**, applies in ≤5 min |
| `qr` | GET | `{"type":"qrCode","message":"<base64 png>"}`; error type when already authorized |
| `getAuthorizationCode` | POST | `{"phoneNumber":79001234567}` — pair by code instead of QR |
| `reboot` | GET | restart the instance |
| `logout` | GET | unlink the WhatsApp account |

Instance states: `notAuthorized` (needs QR), `authorized` (good), `starting`
(restarting, wait), `sleepMode` (phone offline too long), `blocked` /
`yellowCard` (WhatsApp restricted the account — stop sending, check console).

## Sending

| Method | Required body | Optional |
|---|---|---|
| `sendMessage` | `chatId`, `message` (≤20000 chars) | `quotedMessageId`, `linkPreview` (bool) |
| `sendFileByUrl` | `chatId`, `urlFile`, `fileName` | `caption` (≤1024), `quotedMessageId` |
| `sendFileByUpload` | multipart to **mediaUrl**: fields `chatId`, `file` | `fileName`, `caption` |
| `sendLocation` | `chatId`, `latitude`, `longitude` | `nameLocation`, `address` |
| `sendContact` | `chatId`, `contact:{phoneContact,firstName,…}` | |
| `sendPoll` | `chatId`, `message`, `options:[{optionName}…]` | `multipleAnswers` |
| `forwardMessages` | `chatId`, `chatIdFrom`, `messages:[idMessage…]` | |

All return `{"idMessage":"…"}` on success. Outgoing file cap: 100 MB. Text
formatting is WhatsApp markdown: `*bold*`, `_italic_`, `~strikethrough~`,
` ```monospace``` `.

`sendFileByUpload` example (note the different host and multipart form):

```bash
curl -sS "$GREENAPI_MEDIA_URL/waInstance$GREENAPI_ID_INSTANCE/sendFileByUpload/$GREENAPI_API_TOKEN" \
  -F chatId=79001234567@c.us -F file=@./report.pdf -F fileName=report.pdf -F caption="Q2"
```

## Receiving (HTTP polling)

| Method | Verb | Notes |
|---|---|---|
| `receiveNotification?receiveTimeout=N` | GET | N=5..60s; empty body when queue empty; 400 if a webhookUrl is set |
| `deleteNotification/{token}/{receiptId}` | DELETE | confirms; next call returns the next item |

The queue is FIFO, holds events for 24h, and only fills for event types whose
toggle is `yes` in settings (`incomingWebhook`, `outgoingWebhook`,
`outgoingAPIMessageWebhook`, `stateWebhook`, `incomingCallWebhook`, …). The
response envelope is `{"receiptId": 1234, "body": {…notification…}}`.

### Notification body shape

```json
{
  "typeWebhook": "incomingMessageReceived",
  "instanceData": {"idInstance": 1101000001, "wid": "79001111111@c.us"},
  "timestamp": 1718000000,
  "idMessage": "F7AEC1B7086ECDC7E6E45923F5EDA1FB",
  "senderData": {
    "chatId": "79001234567@c.us",
    "sender": "79001234567@c.us",
    "senderName": "Tomer",
    "senderContactName": "Tomer F"
  },
  "messageData": {
    "typeMessage": "textMessage",
    "textMessageData": {"textMessage": "hi"}
  }
}
```

`typeWebhook` values you'll meet: `incomingMessageReceived`,
`outgoingMessageReceived` (sent from the phone), `outgoingAPIMessageReceived`
(sent by you via the API), `outgoingMessageStatus` (`sent` → `delivered` →
`read`), `stateInstanceChanged`, `incomingCall`.

`messageData.typeMessage` → where the content lives:

| typeMessage | content |
|---|---|
| `textMessage` | `textMessageData.textMessage` |
| `extendedTextMessage` | `extendedTextMessageData.text` (links, formatted text) |
| `quotedMessage` | `extendedTextMessageData.text` + `quotedMessage{…}` |
| `imageMessage` / `videoMessage` / `documentMessage` / `audioMessage` | `fileMessageData.{downloadUrl,caption,fileName,mimeType}` |
| `locationMessage` | `locationMessageData.{latitude,longitude,address}` |
| `contactMessage` | `contactMessageData.{displayName,vcard}` |
| `stickerMessage`, `reactionMessage`, `pollMessage`, … | analogous `*Data` objects |

In **group** messages `senderData.chatId` is the group (`…@g.us`) and
`senderData.sender` is the person who wrote (`…@c.us`).

## History & journal methods (read without consuming the queue)

| Method | Verb / body | Notes |
|---|---|---|
| `getChatHistory` | POST `{chatId, count}` | last N messages of one chat |
| `lastIncomingMessages?minutes=N` | GET | journal of incoming msgs (default 24h) |
| `lastOutgoingMessages?minutes=N` | GET | journal of outgoing msgs |
| `getMessage` | POST `{chatId, idMessage}` | one message |
| `downloadFile` | POST `{chatId, idMessage}` | re-issue a media `downloadUrl` |
| `readChat` | POST `{chatId}` | mark a chat read (clears unread badge) |

## Contacts & groups

| Method | Verb / body |
|---|---|
| `checkWhatsapp` | POST `{phoneNumber: 79001234567}` → `{existsWhatsapp: bool}` |
| `getContacts` | GET — all contacts + group chats |
| `getContactInfo` | POST `{chatId}` |
| `createGroup` | POST `{groupName, chatIds:[…]}` (not on the free plan) |
| `getGroupData` | POST `{groupId}` |
| `addGroupParticipant` / `removeGroupParticipant` | POST `{groupId, participantChatId}` |
| `setGroupPicture`, `updateGroupName`, `leaveGroup` | … |

## Errors & limits

- **401 / 403** — bad idInstance/token, or instance deleted/expired.
- **400 `"Message cannot be received because custom webhook url is set"`** —
  clear `webhookUrl` (use `wa_setup.sh --fix-settings`).
- **429** — too many API calls; back off. Independently of HTTP limits,
  WhatsApp itself bans accounts that message strangers in bulk — pace sends
  (seconds apart), warm up new accounts slowly, never cold-spam.
- **466** — monthly quota exceeded (free plan: limited chats/messages).
- Sends while `notAuthorized` return an error body instead of `idMessage` —
  always check for `idMessage` in the response (the bundled `wa_send.sh` does).
- Media `downloadUrl`s expire (~24h on the free plan); download promptly or
  re-issue via `downloadFile`.
