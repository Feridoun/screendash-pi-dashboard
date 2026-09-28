# screendash worker

The Cloudflare backend. It is the only component that holds credentials — the Pi
performs anonymous GETs for everything on the wall and stores nothing sensitive.

The one exception is `bundles/*`, the app itself: it can carry build-time secrets,
so it requires the `DEVICE_TOKEN` bearer secret and the updater is the only thing
that sends it. See [`docs/tailnet-security.md`](../docs/tailnet-security.md).

**No domain required.** Mail is pulled from Gmail rather than pushed by Cloudflare
Email Routing, so this runs on the free `*.workers.dev` URL.

```
cron */5   ──▶ pollGmail()    ──▶ yourteam.dev gate ──▶ notice ──▶ motd.json
                                              ├──▶ message ──▶ messages.json
                                              ├──▶ pinphoto ──▶ pin.json + manifest.json
                                              └──▶ photos ──▶ photos/*.jpg + manifest.json
cron */15  ──▶ syncCalendar() ──▶ Google Calendar ─────────▶ events.json
           ├─▶ syncDirectory()──▶ Google Sheet ────────────▶ directory.json
           ├─▶ syncRota()     ──▶ Google Sheet (2 tabs) ───▶ rota.json
           └─▶ syncWeather()  ──▶ Open-Meteo (no key) ─────▶ weather.json
Pi         ──▶ fetch()        ──▶ serves the above out of R2
```

Full click-by-click setup: [`docs/cloudflare-setup.md`](../docs/cloudflare-setup.md).

## Modules

| File | Role |
|---|---|
| `index.js` | Cron branching + HTTP entry points |
| `gmail.js` | Gmail API: list unprocessed mail, decode parts, fetch attachments, label as done |
| `intake.js` | Shared rules: yourteam.dev sender gate, subject-is-the-command parsing (`notice` / `message` / `pinphoto` / `delete`), photo routing |
| `photos.js` | Resize, write to R2, prune, pin, rebuild `manifest.json` |
| `motd.js` | Parse and write `motd.json` |
| `messages.js` | Append to the capped `messages.json` chat feed |
| `calendar.js` | Google Calendar → `events.json` |
| `directory.js` | Google Sheet → `directory.json` |
| `rota.js` | Google Sheet (`Team` pattern + `Leave` exceptions) → `rota.json`, resolved per person per day |
| `sheets.js` | Shared Sheets fetch and header-name column matching, for the two above |
| `weather.js` | Open-Meteo → `weather.json` (two days; no account or key) |
| `google_auth.js` | Refresh-token → access-token exchange (shared) |
| `serve.js` | Serves artifacts with ETags; gates `bundles/*` behind `DEVICE_TOKEN` |

## Artifacts written to R2

| Key | Written by | Read by |
|---|---|---|
| `manifest.json` | photo pipeline | `PhotoController` |
| `photos/*.jpg` | photo pipeline | `PhotoController` |
| `motd.json` | `notice` emails | `MotdController` |
| `messages.json` | `message` emails | `MessageController` |
| `events.json` | calendar cron | `CalendarController` |
| `directory.json` | directory cron (Google Sheet) | `DirectoryController` |
| `rota.json` | rota cron (Google Sheet) | `RotaController` |
| `weather.json` | weather cron (Open-Meteo) | `WeatherController` |
| `pin.json` | `pinphoto` emails | nothing — internal, not served |
| `removed/*.jpg` | `delete` emails + `MAX_PHOTOS` cull | nothing — internal, not served |

## Setup summary

```bash
npm install
npx wrangler login
npx wrangler r2 bucket create screendash
npx wrangler deploy

# Google: enable Calendar + Gmail + Sheets APIs, create a Web-application OAuth client
# with redirect http://localhost:8976/callback, then paste the client ID and secret
# into .dev.vars (see "The OAuth client" below) and:
node get-refresh-token.mjs

npx wrangler secret put GOOGLE_CLIENT_ID
npx wrangler secret put GOOGLE_CLIENT_SECRET
npx wrangler secret put GOOGLE_REFRESH_TOKEN

# Required: the bearer token devices send to download an app bundle. Same value
# goes to the Pi as DEVICE_TOKEN during `deploy.sh provision`.
openssl rand -hex 32
npx wrangler secret put DEVICE_TOKEN

npx wrangler deploy        # pick up the secrets

# Optional: build the rota spreadsheet + leave Form for rota.json in one go
# (enable the Google Forms API first, or add --no-form). Prints ROTA_SHEET_ID.
node create-rota-sheet.mjs
```

## The OAuth client

`GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` are Worker secrets, and
`wrangler secret list` prints their names but never their values — so once the first
setup is over there is nothing on the laptop to re-mint a token with. Keep them in
**`worker/.dev.vars`** instead:

```
GOOGLE_CLIENT_ID = "....apps.googleusercontent.com"
GOOGLE_CLIENT_SECRET = "GOCSPX-..."
```

That file is gitignored in two places and never deployed. `get-refresh-token.mjs` and
`create-rota-sheet.mjs` read it through `oauth-client.mjs` — arguments first, then the
environment, then the file — so neither needs the secret on the command line, where it
would stay in shell history. `wrangler dev` reads the same file, so a local run can use
the real Google values without touching the deployed secrets.

Lost the secret? Cloud Console → APIs & Services → Credentials → the Web-application
client → **Reset secret**, then `wrangler secret put GOOGLE_CLIENT_SECRET` as well, or
the Worker keeps using the old one.

## How staff use it

**The subject is the command; the body is what it acts on.** The four commands are
`notice`, `message`, `pinphoto` and `delete`; a trailing colon is optional.

| To do this | Send an email that… |
|---|---|
| Add photos | has one or more image attachments, and a subject that is not one of the four commands |
| Update the banner | subject `notice`, banner text in the body |
| Set a banner color | includes `#accent=#E8A33D` on a line in the body |
| Clear the banner | subject `notice` with an empty body |
| Post a chat message | subject `message`, text in the body — recorded as "sender - text" in the message panel, up to the last `MAX_MESSAGES` (default 50) |
| Hold a photo on screen | subject `pinphoto` **with the photo attached** — stored and pinned together |
| Pin a photo already up | subject `pinphoto`, part of its filename in the body |
| Resume rotation | subject `pinphoto` with an empty body, or a body of `off` / `clear` / `none` / `unpin` |
| Remove photos | **reply to the mail that added them** with subject `delete` (see below) |

The older one-line form still works — `notice: Coffee machine is fixed` — and an
argument after the colon **wins over the body**. That ordering is the point: bodies
arrive with signature blocks and gateway disclaimers stapled on by clients we don't
control, so a subject somebody typed deliberately has to outrank them. Where the
argument is a single token rather than prose (`pinphoto`, `delete`), a body only
counts as one when its first line is a single whitespace-free word — which is what
stops an Outlook footer being read as a filename.

The **directory** and the **rota** are the exceptions — neither has an email path. Edit
the Google Sheet (or, for leave, submit the Google Form; see below); the change is live
within ~15 min on the Worker plus one device poll, or at once via the board's refresh dot.

All the rest go to the **same Gmail address**; the subject decides. A `notice` message with
attachments is treated as a banner update and the images are ignored. Only senders
at the domains in `ALLOWED_SENDER_DOMAINS` (default `yourteam.dev`) are honoured.

### Notice notes

A notice longer than the banner's three lines isn't truncated — the device
scrolls it past and starts over, so the whole thing gets read.

The body is trimmed before it becomes the banner (`cleanText` in `motd.js`): the
accent directive comes out, and the text ends at whichever comes first of

- a blank line — this is the rule that catches ordinary signature blocks, which
  Exchange, Outlook and Gmail all put below one. A sentence a client has
  hard-wrapped at 76 columns has no blank line in it, so it stays whole;
- a sign-off alone on a line (`Kind regards`, `Thanks,`), for a signature typed
  straight under the notice — but never on the first line, so a message that
  is just "Thanks!" still posts;
- a line a mail client generates verbatim: a quoted reply, `On … wrote:`,
  Outlook's `From:` header block, the `--` signature delimiter, and the
  "Sent from my …" / "Get Outlook for …" footers (`BODY_TAIL_RE`). These may
  match on the first line, so a `notice` sent from a phone with nothing typed
  clears the banner instead of posting the footer.

A mail with no plain-text part at all falls back to its HTML, tags stripped, so an
HTML-only client doesn't post an empty notice.

`npm test` runs the fixtures for this in `test/motd.test.mjs`; when a client's
signature leaks onto the wall, add its body shape there first.

Each `notice` email pushes the notice it replaces onto a `history` array inside
`motd.json` (newest first, capped at `MAX_NOTICE_HISTORY`), and the arrows on the
banner step back through it. Blank notices and a straight repost of the same text
are not recorded, so clearing the banner doesn't fill the history with holes.
Clearing also blanks the banner outright — the device hides the whole feed when
the current notice is empty, rather than falling back to the last one.

### Pinning notes

The pin lives in `pin.json`, not in `manifest.json` — the manifest is rebuilt from
scratch on every intake and would otherwise lose it. It reaches the device as
`"pinned": true` on one manifest entry, which changes the manifest hash and so
propagates on the next 5-minute poll.

Photos culled by `MAX_PHOTOS` are **archived to `removed/`, not deleted** — the same
place an emailed `delete` puts them, restored the same way (below). A pinned photo is
**exempt from the cull** on top of that, so the effective cap is
`MAX_PHOTOS + 1` while an aged-out photo is pinned. If the pinned file disappears
anyway, the next rebuild clears the pin rather than publishing a dangling one.

Filenames are machine-generated (`2026-07-28-jsmith-1753…-1.jpg`), so a `pinphoto`
body naming a fragment matches on a unique substring. An ambiguous fragment is
refused rather than guessed — check the Worker log (`npm run tail`) for
`pin failed: no unique photo matching …`.

Staff can also **click the photo on the dashboard** to pin or unpin it. That local
choice wins until the emailed pin actually changes, so a poll five minutes later
doesn't undo what someone just did at the wall.

### Deleting notes

Filenames are machine-generated and nothing on the wall or the device shows one, so
the *email that added a photo* is the practical way to identify it — not its name.
To take a photo down, find that email in the inbox and reply to it with subject
`delete` (an auto-added `Re:` — or a stack of them from a long back-and-forth — is
fine, and so is `Fwd:`). Every photo that message added is removed. **Do not include
the original photo as an attachment when replying** — a forward carries the images
along, and they're deliberately ignored on a `delete` subject so a forward can't
silently re-add what you just asked to remove.

A reply body is mostly quoted mail and pleasantries, so it is only read as a target
when it is one bare word carrying a digit or a dot — an ordinal (`2`) or a filename
fragment. "Thanks" leaves the default intact: everything that thread added.

Matching happens two ways so a client that boxes replies into a fresh thread doesn't
break it: the Gmail thread ID of the reply, and the RFC `Message-ID`s in its
`In-Reply-To`/`References` headers, both checked against what was recorded on each
photo at intake time. A message stored before this feature shipped has neither and can
only be removed by name (below).

When the mail is gone — deleted, or from before this shipped — a `delete` whose body
is a filename fragment removes one photo by (a unique substring of) its name, the
same matching `pinphoto` uses. An ambiguous or empty match changes nothing and logs
`delete failed: …` (`npx wrangler tail`) rather than guessing. A `delete` reply that
doesn't resolve to any photo — wrong thread, or the email genuinely added none — is
reported the same way and leaves everything untouched.

Photos leaving the rotation aren't deleted outright; they move to a `removed/` key in
R2 (not served to the device) so a mistaken delete — or a cull you'd rather undo — can
be reversed by hand:
```bash
npx wrangler r2 object get screendash/removed/<file> --file <file> --remote --config worker/wrangler.toml
npx wrangler r2 object put screendash/photos/<file> --file <file> --remote --config worker/wrangler.toml
npx wrangler r2 object delete screendash/removed/<file> --remote --config worker/wrangler.toml
```
then force a manifest rebuild the same way pinning does (below), or wait for the next
intake.

Note the restored copy counts as **newest**, not as old as it originally was: the cull
ranks photos by R2 upload time, and putting the object back stamps that to now. So a
restored photo lands at the end of the rotation rather than back in its old
chronological slot — and, if the bucket was already at `MAX_PHOTOS`, it pushes the
genuine oldest into `removed/` in its place.

Deleting the pinned photo clears the pin, same as it aging out under `MAX_PHOTOS` does.

Because the dashboard's own mailbox address sends the `delete` reply, it's listed in
`ALLOWED_SENDER_ADDRESSES` (`wrangler.toml`) alongside the `yourteam.dev` domain gate —
sending it at all already requires the mailbox password.

## The directory sheet

`directory.json` is rebuilt every 15 minutes from one flat tab of a Google Sheet
owned by (or shared with) the dashboard account. Set `DIRECTORY_SHEET_ID` to the
long token in the sheet's URL; leaving it empty disables the sync entirely and
keeps whatever was uploaded by hand.

| Group | Name | Role | Phone | Email |
|---|---|---|---|---|
| Engineering | Priya Shah | Eng Lead | x4021 | priya@yourteam.dev |
| Engineering | Sam Cole | Backend | x4022 | sam@yourteam.dev |
| Operations | Front Desk | | x4000 | reception@yourteam.dev |

`sample_backend/Directory.csv` is this layout ready to import (**File → Import → Upload**,
*Replace spreadsheet*) — the tab takes the file's name, so it lands as `Directory` with the
headers in place.

- Columns are matched by **header name, not position**, with synonyms accepted
  (`Team`/`Department`, `Ext`/`Telephone`, `Title`/`Job Title`). Row 1 is the header.
- **Group order on screen = order of first appearance** in the sheet; the app renders
  backend order rather than sorting.
- A blank Group cell **inherits the row above**, so each group is named once per block.
- Rows with no Name are skipped; blank Role/Phone/Email are omitted for that person.
- Values are read as `FORMATTED_VALUE`, so `x4021` and `020 7946 0011` stay strings
  instead of being coerced into numbers.

Two deliberate refusals: a sync that finds **no people** keeps the previous directory
rather than blanking the wall (a renamed tab or a mid-edit clear would otherwise take
the column down), and a header with **no Name column** throws instead of silently
publishing nothing. Both show up in `npm run tail`.

The file is written **only when the content changed**. An unconditional put would rotate
the R2 ETag every 15 minutes and cost every device a re-download of an identical file,
and would move `updated` on days nothing moved.

## The rota sheet

`rota.json` — the **DOCTORS ROTA** card — is rebuilt every 15 minutes from two tabs of a
second Google Sheet (`ROTA_SHEET_ID`; a second spreadsheet so it can be shared more widely
than the directory). The device does none of the arithmetic: the Worker publishes one
already-resolved entry per person per day for `ROTA_SPAN_DAYS`, and the app looks up
today and draws it.

**`Team`** — the usual weekly pattern, row order = card order:

| Name | Role | Mon | Tue | Wed | Thu | Fri | From | Until | Email |
|---|---|---|---|---|---|---|---|---|
| Dr A Khan | Consultant | 08:00-18:00 | | | 08:00-18:00 | 08:00-18:00 | | |
| Dr G Brown | F1 | 09:00-17:00 | 09:00-17:00 | 09:00-17:00 | 09:00-17:00 | 09:00-17:00 | 2026-08-05 | 2026-12-01 |

**`Leave`** — the exceptions, normally written by a Google Form (its `Timestamp` column
is ignored; point `ROTA_LEAVE_RANGE` at the responses tab):

| Name | First day | Last day | Type | Hours | Contact | Note |
|---|---|---|---|---|---|---|
| Dr A Khan | 22/09/2026 | 26/09/2026 | Annual leave | | None | |
| Dr D Patel | 18/09/2026 | | Meeting | 10-12 | Phone | Trust board |

Columns are matched by header name through `LEAVE_COLUMNS`, which allows a few spellings
each — a Form question titled `Contactable` lands in `Contact`, `From`/`To` in the two
date columns — so the Form's wording need not match this table exactly.

How the two resolve, per person per day (`buildRota` in `rota.js`, pinned by
`test/rota.test.mjs`):

1. Not on `Team`, or outside `From`/`Until` → not published. Rotations are handled by
   dating rows, not deleting them.
2. Blank pattern cell → `off`. Otherwise `in` with the hours. A pattern cell reads
   `08:00-18:00`, `8am-6pm`, `0800-1800`, `AM`/`PM`, or anything else non-blank as
   "working, `ROTA_DEFAULT_HOURS`" — including a cell Sheets auto-formatted into a date
   because someone typed `8-6`. Fail open: on the wall with default hours beats missing.
3. A `Leave` row covering the date overrides. **Later rows win**, and a row of type
   `cancel` restores the pattern for its dates — so undoing a booking is another
   submission, not a hunt through the sheet. Hours blank → the whole day, status by
   type; hours given → `partial`, in as usual with the window as `detail`.
4. `Type` is matched on a vocabulary (`KINDS`): annual/AL/holiday, study/SL/course,
   sick, meeting/clinic/teaching, WFH/remote, off/TOIL, cancel. A cell that *starts
   with* a known word gets the canonical label; one that merely *contains* one keeps its
   own wording with that status; anything unknown is an absence labelled as typed.
   Wording lives here for the same reason the weather's does.
5. `Contact` normalises to `phone` / `email` / `phone or email` / `none`, or free text.

Names match loosely — squashed, minus a leading "Dr" and any bracketed suffix — so a Form
dropdown of `Dr A Khan (Consultant)` finds the `Team` row `Dr A Khan`. A `Leave` row for
nobody is logged (`matches nobody`) and skipped.

Two things are deliberate about the read:

- **`UNFORMATTED_VALUE`**, unlike the directory. A date cell then arrives as a Sheets
  serial number rather than as `22/09/2026` or `9/22/2026` depending on the sheet's
  locale — there is nothing to guess. Text dates (ISO, British day-first, `22 Sep 2026`)
  are parsed as a fallback for a cell someone forced to plain text.
- **"Today" is computed in `ROTA_TZ`**, not the Worker's UTC. At 23:30 BST the Worker's
  clock already says tomorrow.

The four statuses — `in`, `partial`, `away`, `off` — are what the device colours; that
set is the app's contract and shouldn't grow without an app change. `label`, `detail`,
`contact` and `note` are free text shown (or not) as sent.

Same refusals as the directory: an empty `Team` keeps the last good rota on the wall, and
an unreadable `Leave` header throws rather than publishing the pattern without its
exceptions (which would put someone on the wall as in on a day they're on leave). The
file is written only when the content changed — which is once a day at minimum, as the
window rolls forward, rather than every tick.

Each rota sync also does two things that never touch `rota.json`. Each has its own
try/catch, so if one fails the card still updates:

- **The Form's Name list follows the Team tab** (`forms.js`). This runs when the
  `ROTA_FORM_ID` secret is set. The dropdown becomes everyone on `Team` whose `Until` hasn't
  passed, in Team order, so starters can book before day one. Only that question's options
  are updated in place, and its question ID stays the same, so the responses sheet keeps its
  columns. An empty Team tab is skipped rather than emptying the dropdown. This needs the
  `forms.body` scope. A token minted before that scope was added gets a 403 on this step
  only, and the log names the fix.
- **Staffing alerts** (`rota_alerts.js`) run while the notify list (below) has anyone on it. A day
  counts as short when more than `ROTA_ALERT_LIMIT` doctors are away for the whole of a day
  they normally work. Anyone whose role contains a word in `ROTA_ALERT_EXCLUDE_ROLES` is not
  counted. A meeting with Hours doesn't count, and neither does a day that isn't one of
  theirs. The check looks as far ahead as the last Leave row. When a day becomes short, the
  person with the latest Leave row on it gets a mail, copied to the notify list. After that,
  each person who books onto the day gets their own mail. Their address comes from an
  optional `Email` column on `Team`, and falls back to the directory sheet by name. With no
  address found, the mail goes to the notify list only and says so. `rota-alerts.json` in R2
  (not served) remembers who has already been reported. The first run with alerts on only
  records what is already short and sends nothing. The alert is sent from the dashboard
  mailbox, with Reply-To set to the people involved, and is labelled as processed so the
  poller never treats it as a command.
- **A mail for every booking** (also `rota_alerts.js`, also sent to the notify list). Each new
  Leave row, meaning each Form submission, is mailed once, giving who, type, dates, hours,
  contact and note. Reply-To is the booker's Team email. A row is recognised by a hash of the
  whole row, Timestamp included, and the hashes already seen are kept in `rota-bookings.json`.
  That means a row edited by hand is mailed again, as a change. The first run only records.
  More than 10 new rows at once is taken as a swapped or re-sorted sheet, so those rows are
  recorded without being mailed.
- **The notify list** is every email address on the rota spreadsheet's `Notify_list` tab
  (`ROTA_NOTIFY_RANGE`). It's read on each sync, so whoever runs the rota can edit it
  without Cloudflare access. Headers and any cell without an @ are ignored. If the tab
  can't be read or has no addresses, the `ROTA_ALERT_TO` secret is used instead, so that
  an emptied or renamed tab doesn't stop notifications without anyone noticing. To stop
  notifications, clear both.

## The weather outlook

`weather.json` carries **two days** — today and tomorrow — for the strip under the clock.
Open-Meteo needs no account and no key, so unlike every other upstream here there is
nothing to authorise: the only configuration is where the board is.

The Worker flattens the response rather than passing it through: whole degrees, a rounded
rain probability, and the WMO code paired with its English text. The **wording lives here**
so rephrasing "Light rain" is a Worker deploy rather than an app rebuild plus a wait on the
device's update timer; the **icon** is picked app-side from the raw code.

`WEATHER_TZ` is load-bearing. It tells Open-Meteo where to cut its days, and without it a
British summer evening publishes tomorrow's forecast as day zero.

The app then **refuses to display a forecast whose first day isn't today**. Everything else
here fails soft by holding the last good artifact, which is right for photos and a
directory and wrong for weather: R2 would go on serving last week's outlook as current
long after this sync stopped. A blank space is the honest failure.

## Configuration (`wrangler.toml` `[vars]`)

| Var | Default | Meaning |
|---|---|---|
| `ALLOWED_SENDER_DOMAINS` | `yourteam.dev` | Comma-separated domains permitted to write to the display |
| `ALLOWED_SENDER_ADDRESSES` | *(empty)* | Comma-separated individual addresses permitted on top of the domains above — set to the dashboard's own mailbox so it can send itself `delete` replies |
| `GMAIL_PROCESSED_LABEL` | `screendash-done` | Label applied to handled mail; also the "skip me" filter |
| `GMAIL_MAX_BATCH` | `10` | Messages processed per poll |
| `GOOGLE_CALENDAR_ID` | `primary` | Which calendar to read |
| `CALENDAR_SPAN_DAYS` | `13` | Days of events to publish — must match `CalendarGrid.span` |
| `DIRECTORY_SHEET_ID` | *(empty)* | Sheet behind `directory.json`; empty disables the sync |
| `DIRECTORY_SHEET_RANGE` | `Directory!A:E` | Tab + columns to read |
| `ROTA_SHEET_ID` | *(empty)* | Sheet behind `rota.json`; empty publishes no rota |
| `ROTA_TEAM_RANGE` | `Team!A:J` | The weekly pattern tab |
| `ROTA_LEAVE_RANGE` | `Leave!A:J` | The exceptions tab — or the Form's responses tab; `""` for pattern only |
| `ROTA_LEAVE_SHEET_ID` | *(empty)* | Spreadsheet holding that range when it isn't `ROTA_SHEET_ID` (a Form's own response sheet, say) |
| `ROTA_SPAN_DAYS` | `14` | Days published, from today |
| `ROTA_DEFAULT_HOURS` | `08:00-18:00` | What a pattern cell means when it only says "yes" |
| `ROTA_TZ` | `Europe/London` | Decides which calendar day is "today" |
| `WEATHER_LAT` / `WEATHER_LON` | *(site coords)* | Where to forecast for; empty disables the outlook |
| `WEATHER_TZ` | `Europe/London` | Decides where "today" ends — wrong value shows tomorrow's forecast |
| `WEATHER_PLACE` | *(empty)* | Display label only |
| `MAX_ATTACHMENTS` | `10` | Images accepted per email |
| `MAX_PHOTOS` | `40` | Photos retained in rotation; oldest archived to `removed/` |
| `MAX_IMAGE_EDGE` | `1920` | Longest edge for stored photos |
| `MAX_NOTICE_HISTORY` | `5` | Superseded notices kept in `motd.json` for the banner's arrows |
| `MAX_MESSAGES` | `50` | Messages kept in `messages.json` for the chat panel |

## Manual triggers

Useful during setup — don't wait for the cron. Each needs the `ADMIN_TOKEN` secret as
a bearer token (keep the laptop's copy in `.dev.vars`, beside the OAuth client):

```bash
curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" $BACKEND/admin/poll-gmail
curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" $BACKEND/admin/sync-calendar
curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" $BACKEND/admin/sync-directory
curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" $BACKEND/admin/sync-rota
curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" $BACKEND/admin/sync-weather
curl $BACKEND/healthz
npx wrangler tail
```

Who may pull which is `src/admin.js`. `poll-gmail`, `sync-weather` and
`rebuild-manifest` need the token outright (401 without it, 503 if the secret was never
set — it fails closed). `sync-calendar`, `sync-directory` and `sync-rota` are what the
board's refresh button POSTs, and the app holds no credential, so those three also take
anonymous calls — at most one run a minute each across every caller, 429 in between.
The token skips that limit. The limit is what stops a loop of anonymous POSTs spending
the Google quota the cron needs.

## Notes & limitations

- **Idempotency.** Messages are selected with `-label:screendash-done` and labelled
  *after* successful processing, so a mid-batch failure retries next tick rather
  than dropping mail. Using a label (not read/unread) means a human opening the
  email in Gmail doesn't break the pipeline. Removing the label re-processes it.
- **Latency.** Photos, notices and pins appear within one poll interval on the
  Worker side, plus another on the device — so up to ~10 min end to end. Force
  the Worker half with `POST /admin/poll-gmail` (bearer `ADMIN_TOKEN`).
- **Scopes.** One refresh token covers `calendar.readonly`, `gmail.modify` and
  `spreadsheets.readonly`. `gmail.modify` is required, not just `gmail.readonly` —
  the Worker must apply its processed label. If you see `insufficient authentication
  scopes`, the token predates a scope; re-run `get-refresh-token.mjs` and
  `wrangler secret put GOOGLE_REFRESH_TOKEN`.
- **Token expiry.** While the OAuth consent screen is in **Testing**, Google expires
  refresh tokens after **7 days** and the dashboard silently stops updating. Publish
  the app to get non-expiring tokens. `invalid_grant` in `wrangler tail` is the tell.
- **Image resizing** uses Cloudflare Image Resizing, which needs a zone (domain).
  Without one it stores originals and logs `resize unavailable` — a storage-size
  concern, not a correctness one, since the app decodes with `cacheWidth`.
- **Spam.** The Gmail query excludes `in:spam`. If mail from yourteam.dev lands there,
  add a Gmail filter to never mark it as spam.
- **Manifest dimensions** are recorded as nominal `1920×1080`; the app decodes with
  `cacheWidth`, so exact values aren't load-bearing.
