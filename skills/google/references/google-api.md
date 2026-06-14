# Google API reference (Gmail + Drive over OAuth)

Everything the `google` skill does is plain HTTPS against Google's REST APIs,
authenticated with a short-lived **access token** that `_common.sh` mints from a
long-lived **refresh token**. This file covers minting that refresh token, the
scopes, and endpoints/queries beyond what the wrapper scripts expose.

## Minting a refresh token (one-time, ~5 minutes)

1. **Create an OAuth client.** Google Cloud Console → APIs & Services →
   Credentials → *Create credentials* → *OAuth client ID* → type **Desktop app**
   (or *Web* with redirect `https://developers.google.com/oauthplayground`).
   Note the **Client ID** and **Client secret** → `GOOGLE_CLIENT_ID` /
   `GOOGLE_CLIENT_SECRET`.
2. **Enable the APIs** you'll use: *Gmail API* and *Google Drive API* (APIs &
   Services → Enable APIs).
3. **Get a refresh token** with both scopes, easiest via the OAuth Playground
   (<https://developers.google.com/oauthplayground>):
   - Gear icon → *Use your own OAuth credentials* → paste the client id/secret.
   - In *Select & authorize APIs*, add the scopes you want (below), authorize,
     then *Exchange authorization code for tokens*. Copy the **refresh token** →
     `GOOGLE_REFRESH_TOKEN`.
   - Important: the refresh token only carries the scopes you selected here. To
     add a scope later, re-run this step.

The access token (~1 h) is derived automatically and cached in
`<workspace>/google/.access_token`; you never set it by hand.

## Scopes (least-privilege first)

| Need | Scope |
|------|-------|
| Send mail | `https://www.googleapis.com/auth/gmail.send` |
| Read/search mail | `https://www.googleapis.com/auth/gmail.readonly` |
| Mark read / modify labels | `https://www.googleapis.com/auth/gmail.modify` |
| Upload/manage only files this app created | `https://www.googleapis.com/auth/drive.file` |
| Full Drive access | `https://www.googleapis.com/auth/drive` |
| List metadata only | `https://www.googleapis.com/auth/drive.metadata.readonly` |
| Read calendar events | `https://www.googleapis.com/auth/calendar.readonly` |
| Create/edit events | `https://www.googleapis.com/auth/calendar.events` |
| Full calendar access | `https://www.googleapis.com/auth/calendar` |

`gmail_read.sh --mark-read` needs `gmail.modify`. `drive_download.sh` of files
not created by this app needs `drive` or `drive.readonly` (not just `drive.file`).
`gcal_add.sh` needs `calendar.events` (or `calendar`); `gcal_list.sh` needs
`calendar.readonly`. Enable the **Google Calendar API** too if you use it.

## Token endpoint (what `_common.sh` calls)

```bash
curl -s https://oauth2.googleapis.com/token \
  -d client_id=$GOOGLE_CLIENT_ID -d client_secret=$GOOGLE_CLIENT_SECRET \
  -d refresh_token=$GOOGLE_REFRESH_TOKEN -d grant_type=refresh_token
# -> {"access_token":"ya29...","expires_in":3599,"scope":"...","token_type":"Bearer"}
```

`invalid_grant` here means the refresh token was revoked, expired (test/"unverified"
apps expire refresh tokens after 7 days — publish the app to stop that), or the
client id/secret don't match the token. Re-mint.

## Gmail beyond the scripts

- **Search query** (`?q=`): same syntax as the Gmail search box —
  `is:unread`, `from:x@y.com`, `subject:invoice`, `newer_than:2d`, `has:attachment`,
  `label:work`. URL-encode it (the scripts use `--data-urlencode`).
- **Threads:** `GET /gmail/v1/users/me/threads/{id}` returns the whole thread.
- **Attachments:** in a `format=full` message, a part has
  `body.attachmentId`; fetch it at
  `GET /gmail/v1/users/me/messages/{id}/attachments/{attachmentId}` → `{data}`
  (base64url). `gmail_read.sh` decodes only the text body, not attachments.
- **Labels:** `GET /gmail/v1/users/me/labels`; modify with the `/modify` endpoint
  used by `--mark-read` (`addLabelIds` / `removeLabelIds`).

## Drive beyond the scripts

- **Query syntax** (`q=`): `name contains 'q2'`, `mimeType='application/pdf'`,
  `'<FOLDER_ID>' in parents`, `trashed=false`, `modifiedTime > '2026-01-01T00:00:00'`,
  combine with `and`/`or`. Folders are `mimeType='application/vnd.google-apps.folder'`.
- **Create a folder:** POST `/drive/v3/files` with
  `{"name":"X","mimeType":"application/vnd.google-apps.folder"}`.
- **Shared drives:** add `supportsAllDrives=true&includeItemsFromAllDrives=true`.
- **Resumable upload** for files > ~5 MB: `uploadType=resumable` (the skill uses
  the simpler `multipart`, fine up to ~5 MB; larger files still work but buffer
  fully in memory).
- **Native Google Docs** (Docs/Sheets/Slides) have no binary content — `alt=media`
  returns 403; use `/export?mimeType=...` (see `drive_download.sh --export`).

## Calendar beyond the scripts

- **Calendar ids:** `primary` is the signed-in user; a shared/secondary calendar
  uses its address (e.g. `team@group.calendar.google.com`). List them at
  `GET /calendar/v3/users/me/calendarList`.
- **Listing** (`gcal_list.sh`): `singleEvents=true` + `orderBy=startTime` expands
  recurring events into instances; `timeMin`/`timeMax` are RFC 3339
  (`2026-06-15T00:00:00Z`); `q=` is free-text search across event fields.
- **Times:** a timed event uses `start.dateTime` + `start.timeZone`; an all-day
  event uses `start.date` (YYYY-MM-DD) and the **end date is exclusive**.
- **Update / delete:** `PATCH` or `DELETE /calendar/v3/calendars/{calId}/events/{eventId}`.
- **Invites:** add `sendUpdates=all` as a query param on create to email attendees.
- **Meet link:** add `conferenceData` with `conferenceDataVersion=1` to attach a
  Google Meet (not wired into `gcal_add.sh`).

## Errors

- **401** — access token expired/invalid; `_common.sh` re-mints automatically on
  the next call, so a one-off 401 usually means a scope problem, not expiry.
- **403 `insufficientPermissions` / `ACCESS_TOKEN_SCOPE_INSUFFICIENT`** — the
  refresh token lacks the scope for this call. Re-mint with the scope added.
- **403 `userRateLimitExceeded`** — back off; Gmail/Drive have per-user QPS caps.
- **In a Kubernetes pod**, the stock NetworkPolicy in `ops/agent.yaml` allows
  egress on 443, so all of these endpoints work without changes.
