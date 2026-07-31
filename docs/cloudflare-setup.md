# Cloudflare Setup — step by step

Everything needed to stand up the backend in [`worker/`](../worker/): the R2 bucket the Pi
polls, and the Worker that reads your Gmail for photos and notices, and syncs your calendar.

**No domain required.** Mail is *pulled* from Gmail rather than pushed by Cloudflare Email
Routing, so the whole backend runs on the free `*.workers.dev` URL. Staff send **from** their
yourteam.dev accounts **to** the Gmail address; the Worker enforces
`ALLOWED_SENDER_DOMAINS = "yourteam.dev"` and ignores everything else. Flow and routing rules:
[dashboard-plan.md](dashboard-plan.md#backend-flow).

Two things to know before you start:

- **R2 requires a payment method** even for the free tier (10 GB). For this workload — a few
  dozen JPEGs and some tiny JSON — you sit comfortably inside it.
- **Image transformations only work on a *zone*** (a domain added to Cloudflare). **No
  domain? Skip step 6** — the Worker stores the original bytes and logs a warning instead of
  failing. Inbound photos are already phone-sized JPEGs and the app decodes with
  `cacheWidth`, so this is a storage-size concern, not a correctness one.

---

## 1. Create a Cloudflare account

[dash.cloudflare.com/sign-up](https://dash.cloudflare.com/sign-up). Verify your email.

## 2. Enable R2

1. Dashboard → **R2 Object Storage**.
2. Click through the activation prompt and **add a payment method**.

You are not charged for staying inside the free tier, but the card is required to turn the
product on.

## 3. Install Wrangler and log in

```bash
cd worker
npm install
npx wrangler login
npx wrangler whoami     # confirm
```

## 4. Create the bucket

The name must match `bucket_name` in [`wrangler.toml`](../worker/wrangler.toml):

```bash
npx wrangler r2 bucket create screendash
```

## 5. First deploy

```bash
npx wrangler deploy
```

This publishes the Worker, binds R2, and registers both cron triggers (`*/5` for Gmail,
`*/15` for the calendar). It prints a `*.workers.dev` URL — that's your `BACKEND_URL`:

```bash
curl https://screendash.<your-subdomain>.workers.dev/healthz     # -> ok
```

> Note the URL down. The Pi bakes it in at build time.

## 6. *(Optional)* Enable image transformations

Only possible if you have a domain on Cloudflare. If so: Dashboard → **Images** →
**Transformations** → select your zone → **Enable for zone**. Otherwise skip — see the note
at the top.

## 7. Set up Google API access

In [Google Cloud Console](https://console.cloud.google.com/), signed in as the account the
dashboard will read (e.g. `your-dashboard@gmail.com`):

1. Create a project (or reuse one).
2. **APIs & Services → Library** → enable **all three**:
   - **Google Calendar API**
   - **Gmail API**
   - **Google Sheets API**
3. **OAuth consent screen** → **External** → fill in the required fields.
4. Add your Google account as a **Test user**.
5. **Credentials → Create credentials → OAuth client ID** → **Web application**.
6. Under *Authorised redirect URIs* add exactly: `http://localhost:8976/callback`
7. Copy the **Client ID** and **Client secret**.

> **Important — token expiry.** While the consent screen is in **Testing**, Google expires
> refresh tokens after **7 days**, and the dashboard would silently stop updating a week
> later. Publish the app (**OAuth consent screen → Publish app**) so tokens last until you
> revoke them. No formal review is needed for these scopes on your own account.

## 8. Mint the refresh token

```bash
node get-refresh-token.mjs <CLIENT_ID> <CLIENT_SECRET>
```

Sign in as the dashboard's Google account. The script requests **all three** scopes it
needs — `calendar.readonly`, `gmail.modify` and `spreadsheets.readonly` — captures the
callback, and prints the refresh token plus the exact commands to store it.

```bash
npx wrangler secret put GOOGLE_CLIENT_ID
npx wrangler secret put GOOGLE_CLIENT_SECRET
npx wrangler secret put GOOGLE_REFRESH_TOKEN
npx wrangler deploy        # redeploy so the Worker picks up the secrets
```

> `gmail.modify` is required (not just `gmail.readonly`) because the Worker labels each
> handled message so it never processes the same email twice.

## 9. Point the calendar at the right place

A brand-new Google account has an **empty calendar** — `events.json` will be valid but
contain nothing.

- Using that account's own calendar? Leave `GOOGLE_CALENDAR_ID = "primary"`.
- Displaying an existing team calendar? Share it to the dashboard account (Calendar →
  Settings → *Share with specific people* → "See all event details"), then set
  `GOOGLE_CALENDAR_ID` in `wrangler.toml` to that calendar's ID and redeploy.

## 10. Set up the directory sheet

`directory.json` has no email flow. It is built from a Google Sheet owned by (or shared
with) the dashboard account, re-read on the 15-minute cron.

Quickest start: in Google Drive as the dashboard account, create a spreadsheet and use
**File → Import → Upload** with [`sample_backend/Directory.csv`](../sample_backend/Directory.csv),
choosing *Replace spreadsheet*. The tab is named after the file, so it comes out as
`Directory` with the right headers in row 1 — then just replace the sample rows.

By hand instead:

1. Create a spreadsheet in the dashboard account's Drive.
2. Rename the **tab** to `Directory` (bottom-left) — the default `Sheet1` won't match the range.
3. Put these headers in row 1 and fill in the staff underneath:

   | Group | Name | Role | Phone | Email |
   |---|---|---|---|---|
   | Engineering | Priya Shah | Eng Lead | x4021 | priya@yourteam.dev |
   | Engineering | Sam Cole | Backend | x4022 | sam@yourteam.dev |
   | Operations | Front Desk | | x4000 | reception@yourteam.dev |

4. Copy the sheet's **ID** out of its URL — the long token between `/d/` and `/edit`:
   `https://docs.google.com/spreadsheets/d/`**`1a2b3c…`**`/edit`
5. Set it in `wrangler.toml` and redeploy:

   ```toml
   DIRECTORY_SHEET_ID = "1a2b3c…"
   ```

   ```bash
   npx wrangler deploy
   curl -X POST $BACKEND/admin/sync-directory   # don't wait for the cron
   ```

If the sheet lives in someone else's Drive, share it to the dashboard account as **Viewer**.

**Sheet rules**

- Only the **header names** matter, not column order — reorder or insert columns freely.
  Common synonyms are accepted (`Team`/`Department` for Group, `Ext`/`Telephone` for Phone,
  `Title`/`Job Title` for Role).
- **Group order on screen follows the sheet.** The first group to appear is the first one
  rendered — sort the rows to control the layout.
- A **blank Group cell inherits the row above**, so you only need to name each group once
  at the top of its block.
- Blank rows are ignored; a row with no **Name** is ignored. Blank Role/Phone/Email simply
  omit that line for that person.
- **An empty sheet is never published.** If the sync finds no people — a cleared sheet, a
  renamed tab, a wrong range — it logs and leaves the last good directory on the wall.
- The file is only rewritten when the content actually changed, so idle syncs don't cause
  the displays to re-download it.

Once `DIRECTORY_SHEET_ID` is set, **the sheet is the source of truth**: a `directory.json`
uploaded by hand will be overwritten within 15 minutes. To go back to hand-editing, clear
`DIRECTORY_SHEET_ID`, redeploy, and upload the file directly:

```bash
npx wrangler r2 object put screendash/directory.json \
  --file ../sample_backend/directory.json \
  --content-type application/json
```

## 11. Verify end to end

```bash
BACKEND=https://screendash.<your-subdomain>.workers.dev

curl $BACKEND/healthz
curl -X POST $BACKEND/admin/sync-calendar     # force a calendar sync
curl $BACKEND/events.json
curl -X POST $BACKEND/admin/sync-directory    # force a directory sync
curl $BACKEND/directory.json
```

Then test the mail paths **from an yourteam.dev account**, and force a poll rather than waiting:

| Test | Send to the Gmail | Then | Expect |
|---|---|---|---|
| Notice | Subject `notice: Hello from Cloudflare` | `curl -X POST $BACKEND/admin/poll-gmail` | `curl $BACKEND/motd.json` shows the text |
| Photos | 2–3 image attachments, any other subject | same | `curl $BACKEND/manifest.json` lists them |
| Pin | Subject `pinphoto:` with one image attached | same | `manifest.json` has `"pinned": true` on that entry |
| Unpin | Subject `pinphoto:` with no attachment | same | No entry in `manifest.json` carries `pinned` |
| Rejection | Send from a non-yourteam.dev address | same | Log shows `sender not allowed`; nothing changes |

Watch it live in another terminal:

```bash
npx wrangler tail
```

Handled messages get the **screendash-done** label in Gmail — a quick visual confirmation
that the pipeline ran, and what it has already consumed.

## 12. Point the Pi at it

```bash
PI_HOST=pi@screendash.local \
BACKEND_URL=https://screendash.<your-subdomain>.workers.dev \
  ./deploy/deploy.sh provision
```

`BACKEND_URL` is compiled into the app *and* written to `/etc/default/dashboard-update`,
so the app and the self-updater poll the same origin.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Nothing happens after emailing | Force `POST /admin/poll-gmail` and read `wrangler tail`. Cron only runs every 5 min |
| `sender not allowed` in logs | The From address isn't `@yourteam.dev` |
| Email accepted, no photo | A subject starting `notice:` routes to the banner, not photos — that's by design |
| Photo stuck, won't rotate | Something is pinned. Email `pinphoto:` with no attachment, or click the photo on screen |
| `pin failed: no unique photo` | The `pinphoto:` fragment matched zero or several files. Check `manifest.json` for the exact name |
| Same email processed twice | The `screendash-done` label was removed in Gmail |
| Emails skipped entirely | Gmail filed them as spam. Check Spam; the query excludes `in:spam` |
| `invalid_grant` in logs | Refresh token expired — consent screen still in **Testing** (step 7). Publish the app and re-mint |
| `events.json` has no events | Empty calendar, or wrong `GOOGLE_CALENDAR_ID` (step 9) |
| `insufficient authentication scopes` | Token was minted before Gmail scope was added. Re-run `get-refresh-token.mjs` |
| `manifest.json` 404 | No photos yet — only written after the first successful photo email |
| Deploy fails on the R2 binding | Bucket name mismatch with `wrangler.toml`, or R2 not activated |

### Useful commands

```bash
npx wrangler tail                          # live logs
curl -X POST $BACKEND/admin/poll-gmail     # force a mail poll
curl -X POST $BACKEND/admin/sync-calendar  # force a calendar sync
npx wrangler r2 object get screendash/manifest.json --file -
npx wrangler secret list
```

---

## What it costs

| Product | Free allowance | This project uses |
|---|---|---|
| Workers | 100k requests/day | ~800/day (one Pi + 384 cron runs) |
| R2 storage | 10 GB | Well under 1 GB (40 photos capped) |
| R2 egress | Free — no egress fees | — |
| Gmail API | 1bn quota units/day | Negligible |
| Cron triggers | Included | 384/day |
| Domain | — | **Not required** |

Total: **£0**, assuming you stay inside the free tiers — which this workload does
comfortably.

---

Sources: [R2 pricing](https://developers.cloudflare.com/r2/pricing/) ·
[Images pricing](https://developers.cloudflare.com/images/pricing/) ·
[Gmail API](https://developers.google.com/gmail/api/guides)
