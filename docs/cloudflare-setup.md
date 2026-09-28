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
# Paste the client ID and secret into worker/.dev.vars first (gitignored), or pass
# them as arguments — see worker/README.md, "The OAuth client".
node get-refresh-token.mjs
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

While you're here, make the token that guards the manual `/admin/*` triggers the
later steps use to skip the cron. Keep the laptop's copy in `worker/.dev.vars`
(gitignored) as `ADMIN_TOKEN = "…"`:

```bash
openssl rand -hex 32                      # paste into worker/.dev.vars as ADMIN_TOKEN
npx wrangler secret put ADMIN_TOKEN       # and the same value here
export ADMIN_TOKEN=<that value>           # for the curl commands below
```

Without it, `poll-gmail`, `sync-weather` and `rebuild-manifest` answer **503** (fail
closed). The three the board's refresh button uses — `sync-calendar`,
`sync-directory`, `sync-rota` — also work with no token at all, but only once a minute
each; inside that window an anonymous call gets **429**. With the token they always run.
See `worker/src/admin.js`.

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
   curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" $BACKEND/admin/sync-directory   # don't wait for the cron
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

## 10b. Set up the rota sheet and form

The **DOCTORS ROTA** under the directory shows who is in over the next three working days. Like the directory it
has no email flow: it is built from a second Google Sheet, re-read on the 15-minute cron.
Two tabs — the usual weekly pattern, and the exceptions to it — and, optionally but
recommended, a Google Form so the doctors can book leave from a phone without touching
the sheet.

**A second spreadsheet, not more tabs on the directory one.** Sharing is per spreadsheet,
and this one gets a Form writing into it and possibly *anyone with the link* editing the
`Team` tab; the directory needn't be opened up along with it.

### The quick way: let a script build it

```bash
cd worker
# optional: put the real team in a copy of ../sample_backend/Team.csv first
node create-rota-sheet.mjs [--team my-team.csv]
```

Same OAuth client and redirect as `get-refresh-token.mjs`; sign in as the dashboard
account when the browser opens. It creates the spreadsheet (both tabs, header frozen,
weekday columns forced to plain text, date columns day-first, dropdowns on Name / Type /
Contact) **and** the Google Form with the seven questions below, then prints the
`ROTA_SHEET_ID` line and the two clicks it can't do for you: linking the Form to the
sheet, and sharing. Enable the **Google Forms API** on the Cloud project first, or pass
`--no-form`. `--dry-run` prints what it would build without signing in. If the
spreadsheet already exists and only the Form is missing, `--form-only --names "A,B,C"`
builds just that, with the names spelled as they are on the Team sheet. If you made the
Form by hand too and it's sitting empty, add `--form-id <ID>` (the token between `/d/`
and `/edit` in its editor URL) and the questions go into that one instead — anything
already on it is replaced, and a Form you've already linked to a sheet stays linked.

The rest of this section is what that script does, for doing it by hand or checking it.

### The `Team` tab — the usual pattern

Quickest start: as the dashboard account, create a spreadsheet and **File → Import →
Upload** [`sample_backend/Team.csv`](../sample_backend/Team.csv), *Replace spreadsheet*.
The tab lands as `Team` with the headers in place; replace the sample rows. Then
**File → Import → Upload** [`sample_backend/Leave.csv`](../sample_backend/Leave.csv) with
*Insert new sheet(s)* to get a `Leave` tab too.

| Name | Role | Mon | Tue | Wed | Thu | Fri | From | Until |
|---|---|---|---|---|---|---|---|---|
| Dr A Khan | Consultant | 08:00-18:00 | | | 08:00-18:00 | 08:00-18:00 | | |
| Dr B Smith | Consultant | | 08:00-18:00 | 08:00-18:00 | | 08:00-18:00 | | |
| Dr G Brown | F1 | 09:00-17:00 | 09:00-17:00 | 09:00-17:00 | 09:00-17:00 | 09:00-17:00 | 2026-08-05 | 2026-12-01 |

- **Row order is card order.** Seniors first is the convention.
- A day cell is **blank (or a dash) for a day they don't work**, otherwise their hours:
  `08:00-18:00`, `8am-6pm`, `AM`, `PM`, or just `y` for the default hours
  (`ROTA_DEFAULT_HOURS`).
- A day cell can instead hold **a word for a regular day that isn't a ward day** — `WFH`,
  `Clinic`, `Study`, `Community` — and the card shows that word, coloured as the same word
  on a `Leave` row would be (amber for remote, meetings and anything it doesn't know; red
  for study or leave). Hours alongside it are kept: `Clinic 10:00-12:00` shows as
  `Clinic 10–12`. A `Leave` row for that day still wins. Anything else unrecognised — a
  tick, a `1` — still counts as *working*, at default hours.
- **Beware `8-6`.** Google Sheets silently turns it into a date (8 June). Either write the
  hours with colons or am/pm, or select the Mon–Fri columns and set **Format → Number →
  Plain text** first. (A cell that was turned into a date still reads as "working, default
  hours" rather than vanishing, so the failure is mild — but the hours will be wrong.)
- **`From` / `Until`** are optional and handle rotations: the next intake can be typed in
  before it starts and appears on its first day; the outgoing rows drop off after their
  `Until`. Nothing needs deleting on changeover day.
- The card shows the **Role** column, under the name, only while the team is small enough
  for its roomiest rows (eight or fewer at the board's height). For a bigger team put a
  short one after the name if you want it on the wall — `Dr A Khan (Cons)` — the bracketed
  part is ignored when matching leave to people.
- Add `Sat` / `Sun` columns if anyone works weekends; otherwise the board skips them, so a
  Friday shows Fri · Mon · Tue and the weekend shows the coming week.

### The `Leave` tab — the exceptions

| Name | First day | Last day | Type | Hours | Contact | Note |
|---|---|---|---|---|---|---|
| Dr A Khan | 22/09/2026 | 26/09/2026 | Annual leave | | None | |
| Dr B Smith | 18/09/2026 | | Study leave | | Email | MRCPsych |
| Dr D Patel | 18/09/2026 | 18/09/2026 | Meeting | 10-12 | Phone | Trust board |

- **Name** must match a row on the `Team` tab — loosely: "Dr", brackets, punctuation and
  case are ignored, so `A. Khan` finds `Dr A Khan`. A row for nobody is logged and skipped.
- **Last day** blank means one day. Dates can be typed however the sheet's locale likes;
  they're read as real dates, not text.
- **Type** is free text with a vocabulary underneath: `Annual leave` / `AL` / `holiday`,
  `Study leave` / `SL` / `course`, `Sick`, `Meeting` / `clinic` / `teaching`, `WFH` /
  `remote`, `Off` / `TOIL`, and `Cancel`. Anything else is shown as typed, as an absence —
  so "Compassionate leave" comes out right without anyone editing the Worker.
- **Hours** blank means the whole day. `10-12` means they're in as usual and away for that
  window only — shown in amber with the window beside the name.
- **Contact**: `Phone`, `Email`, both, or `None`. Shown after the status.
- **Later rows win.** To cancel a leave, don't hunt for the old row — add one with Type
  `Cancel` over the same dates, and the usual pattern is back.

### The Form (recommended)

A Google Form is how the doctors will actually use this. In the dashboard account's Drive,
**New → Google Forms**, then add these questions — the *titles* matter, because the sheet
columns take their names from them:

| Question title | Kind | Notes |
|---|---|---|
| **Name** | Dropdown | one option per person, spelled as on the `Team` tab |
| **First day** | Date | |
| **Last day** | Date | not required — blank means one day |
| **Type** | Dropdown | Annual leave · Study leave · Sick · Meeting · Working from home · Off · Cancel · Other |
| **Hours** | Short answer | not required; "leave blank for the whole day, or e.g. 10-12" |
| **Contact** | Checkboxes | Phone · Email — none ticked means not contactable |
| **Note** | Short answer | not required |

Titles are matched by name, not position, and each column answers to a few spellings —
`Contactable` for **Contact**, `From`/`To` for **First day**/**Last day**, `Reason` for
**Type** (the full lists are `LEAVE_COLUMNS` in `rota.js`). Order doesn't matter, and a
question the Worker doesn't recognise is ignored rather than breaking the rest.

Then **Responses → Link to Sheets**. Either **Select existing spreadsheet** → the rota
spreadsheet, which adds a `Form responses 1` tab there, or **Create a new spreadsheet**,
which makes a separate `<form name> (Responses)` sheet. Both get a `Timestamp` column
in front (ignored) and the questions as headers. Point the Worker at whichever you chose:

```toml
ROTA_LEAVE_RANGE = "Form responses 1!A:J"
ROTA_LEAVE_SHEET_ID = ""            # or the (Responses) sheet's ID if you made a new one
```

The same knob covers a `Leave` sheet that was created as its own spreadsheet rather than
as a tab: put its ID in `ROTA_LEAVE_SHEET_ID` and its tab name in `ROTA_LEAVE_RANGE`.
Only the one range is read, so a `Leave` tab typed out by hand before the Form existed is
simply ignored once the range names the responses tab — delete it or leave it.

Under the Form's **Settings**: turn *off* "Collect email addresses" and "Limit to 1
response" — either would demand a Google login, and the doctors' mail is on yourteam.dev, not Google. Share
the Form link (**Send → link**) with the team; that link is the whole user interface.

Corrections happen in the responses tab (the office manager can edit or delete rows
there) or by submitting a `Cancel`.

### Point the Worker at it

```toml
ROTA_SHEET_ID = "1x2y3z…"          # the token between /d/ and /edit in the sheet's URL
ROTA_TEAM_RANGE = "Team!A:J"
ROTA_LEAVE_RANGE = "Leave!A:J"     # or the Form responses tab, above
ROTA_TZ = "Europe/London"
```

```bash
npx wrangler deploy
curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" $BACKEND/admin/sync-rota   # don't wait for the cron
curl $BACKEND/rota.json                 # days[0].date must be *today*
```

No new Google scope is needed — the refresh token's `spreadsheets.readonly` already
covers it. If the sheet lives in someone else's Drive, share it to the dashboard account
as **Viewer**.

**Sheet rules**, same as the directory: header *names* not positions; an empty `Team` tab
is never published (the last good rota stays on the wall); an unreadable `Leave` header
also keeps the last good rota rather than publishing the pattern without its exceptions;
and the file is only rewritten when the content changed. "Today" is decided in
`ROTA_TZ`, not UTC — a summer evening would otherwise roll the card over an hour early.

Leave `ROTA_SHEET_ID` empty to switch the card off; it shows "Rota not available".

## 11. Set the weather location

The two-day outlook under the clock comes from [Open-Meteo](https://open-meteo.com/).
There is **no account, no API key and nothing to authorise** — the only thing to configure
is where the board is. In `wrangler.toml`:

```toml
WEATHER_LAT = "51.5074"
WEATHER_LON = "-0.1278"
WEATHER_TZ  = "Europe/London"
WEATHER_PLACE = "London"       # label only; doesn't affect the forecast
```

Get coordinates by right-clicking the building in Google Maps — the first menu entry is the
lat/lon pair. Three decimal places is plenty: the forecast model is gridded to roughly a
kilometre, so more precision changes nothing.

`WEATHER_TZ` decides where "today" ends. Leave it as the office's real timezone or a summer
evening will show tomorrow's forecast as today's.

```bash
npx wrangler deploy
curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" $BACKEND/admin/sync-weather   # don't wait for the cron
```

Leave `WEATHER_LAT`/`WEATHER_LON` empty to switch the feature off: the sync skips, no
`weather.json` is ever written, and the strip simply doesn't appear.

> The app **hides the strip** whenever the forecast's first day isn't today. So if the
> board shows no weather, the sync has stopped — the artifact is being served from storage
> and would otherwise go on showing last week's outlook indefinitely.

## 12. Verify end to end

```bash
BACKEND=https://screendash.<your-subdomain>.workers.dev

curl $BACKEND/healthz
curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" $BACKEND/admin/sync-calendar     # force a calendar sync
curl $BACKEND/events.json
curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" $BACKEND/admin/sync-directory    # force a directory sync
curl $BACKEND/directory.json
curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" $BACKEND/admin/sync-rota         # force a rota sync
curl $BACKEND/rota.json                       # days[0].date must be *today*
curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" $BACKEND/admin/sync-weather      # force a weather sync
curl $BACKEND/weather.json                    # first date must be *today*
```

Then test the mail paths **from an yourteam.dev account**, and force a poll rather than waiting:

| Test | Send to the Gmail | Then | Expect |
|---|---|---|---|
| Notice | Subject `notice`, body `Hello from Cloudflare` | `curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" $BACKEND/admin/poll-gmail` | `curl $BACKEND/motd.json` shows the body text |
| Message | Subject `message`, body `Cakes in the kitchen` | same | `curl $BACKEND/messages.json` lists it |
| Photos | 2–3 image attachments, any other subject | same | `curl $BACKEND/manifest.json` lists them |
| Pin | Subject `pinphoto` with one image attached | same | `manifest.json` has `"pinned": true` on that entry |
| Unpin | Subject `pinphoto`, no attachment, empty body | same | No entry in `manifest.json` carries `pinned` |
| Rejection | Send from a non-yourteam.dev address | same | Log shows `sender not allowed`; nothing changes |

Watch it live in another terminal:

```bash
npx wrangler tail
```

Handled messages get the **screendash-done** label in Gmail — a quick visual confirmation
that the pipeline ran, and what it has already consumed.

## 13. Point the Pi at it

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
| Nothing happens after emailing | Force `POST /admin/poll-gmail` (with the `ADMIN_TOKEN` header) and read `wrangler tail`. Cron only runs every 5 min |
| `/admin/*` answers 401 | No `Authorization: Bearer $ADMIN_TOKEN` header, or it doesn't match the Worker's `ADMIN_TOKEN` secret |
| `/admin/*` answers 503 | `ADMIN_TOKEN` was never set on the Worker: `wrangler secret put ADMIN_TOKEN` |
| `/admin/sync-rota` answers 429 | Called with no token inside a minute of the last anonymous run (the board's refresh button counts). Add the header, or wait |
| `sender not allowed` in logs | The From address isn't `@yourteam.dev` |
| Email accepted, no photo | The subject was a command word (`notice`, `message`, `pinphoto`, `delete`), which routes away from photos — that's by design |
| Photo stuck, won't rotate | Something is pinned. Email `pinphoto` with no attachment and an empty body, or click the photo on screen |
| `pin failed: no unique photo` | The fragment in the body matched zero or several files. Check `manifest.json` for the exact name |
| Notice shows a signature block | The signature had no blank line, sign-off or client footer in front of it — see `cleanText` in `worker/src/motd.js`, and add the body as a case in `worker/test/motd.test.mjs` |
| Same email processed twice | The `screendash-done` label was removed in Gmail |
| Emails skipped entirely | Gmail filed them as spam. Check Spam; the query excludes `in:spam` |
| `invalid_grant` in logs | Refresh token expired — consent screen still in **Testing** (step 7). Publish the app and re-mint |
| `events.json` has no events | Empty calendar, or wrong `GOOGLE_CALENDAR_ID` (step 9) |
| Card says "Rota not available" | `ROTA_SHEET_ID` unset, the sync has stopped (`days[0].date` isn't today), or the `Team` tab has no `Name` header (step 10b) |
| Someone is shown "in" on a day they booked off | Their leave row's Name doesn't match the `Team` tab — `wrangler tail` logs `matches nobody`; or the Worker is reading `Leave!` while the Form writes to `Form responses 1!` |
| Wrong hours on the card | The pattern cell was auto-formatted as a date (`8-6` → 8 June). Set the day columns to Plain text, or write `08:00-18:00` |
| No weather on the board | `WEATHER_LAT`/`WEATHER_LON` unset, or the sync has stopped — the app hides any forecast not starting today (step 11) |
| Weather is a day ahead | `WEATHER_TZ` is wrong or unset, so Open-Meteo is cutting days on UTC |
| `insufficient authentication scopes` | Token was minted before Gmail scope was added. Re-run `get-refresh-token.mjs` |
| `manifest.json` 404 | No photos yet — only written after the first successful photo email |
| Deploy fails on the R2 binding | Bucket name mismatch with `wrangler.toml`, or R2 not activated |

### Useful commands

```bash
npx wrangler tail                          # live logs
curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" $BACKEND/admin/poll-gmail     # force a mail poll
curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" $BACKEND/admin/sync-calendar  # force a calendar sync
curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" $BACKEND/admin/sync-rota      # force a rota sync
curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" $BACKEND/admin/sync-weather   # force a weather sync
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
