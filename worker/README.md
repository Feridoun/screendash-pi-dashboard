# screendash worker

The Cloudflare backend. It is the only component that holds credentials — the Pi
performs anonymous GETs and stores nothing sensitive.

**No domain required.** Mail is pulled from Gmail rather than pushed by Cloudflare
Email Routing, so this runs on the free `*.workers.dev` URL.

```
cron */5   ──▶ pollGmail()    ──▶ yourteam.dev gate ──▶ notice: ──▶ motd.json
                                              ├──▶ message: ──▶ messages.json
                                              ├──▶ pinphoto: ──▶ pin.json + manifest.json
                                              └──▶ photos ──▶ photos/*.jpg + manifest.json
cron */15  ──▶ syncCalendar() ──▶ Google Calendar ─────────▶ events.json
           └─▶ syncDirectory()──▶ Google Sheet ────────────▶ directory.json
Pi         ──▶ fetch()        ──▶ serves the above out of R2
```

Full click-by-click setup: [`docs/cloudflare-setup.md`](../docs/cloudflare-setup.md).

## Modules

| File | Role |
|---|---|
| `index.js` | Cron branching + HTTP entry points |
| `gmail.js` | Gmail API: list unprocessed mail, decode parts, fetch attachments, label as done |
| `intake.js` | Shared rules: yourteam.dev sender gate, `pinphoto:` / `notice:` / `message:` / photo routing |
| `photos.js` | Resize, write to R2, prune, pin, rebuild `manifest.json` |
| `motd.js` | Parse and write `motd.json` |
| `messages.js` | Append to the capped `messages.json` chat feed |
| `calendar.js` | Google Calendar → `events.json` |
| `directory.js` | Google Sheet → `directory.json` |
| `google_auth.js` | Refresh-token → access-token exchange (shared) |
| `serve.js` | Serves artifacts with ETags |

## Artifacts written to R2

| Key | Written by | Read by |
|---|---|---|
| `manifest.json` | photo pipeline | `PhotoController` |
| `photos/*.jpg` | photo pipeline | `PhotoController` |
| `motd.json` | `notice:` emails | `MotdController` |
| `messages.json` | `message:` emails | `MessageController` |
| `events.json` | calendar cron | `CalendarController` |
| `directory.json` | directory cron (Google Sheet) | `DirectoryController` |
| `pin.json` | `pinphoto:` emails | nothing — internal, not served |
| `removed/*.jpg` | `delete:` emails | nothing — internal, not served |

## Setup summary

```bash
npm install
npx wrangler login
npx wrangler r2 bucket create screendash
npx wrangler deploy

# Google: enable Calendar + Gmail + Sheets APIs, create a Web-application OAuth client
# with redirect http://localhost:8976/callback, then:
node get-refresh-token.mjs <CLIENT_ID> <CLIENT_SECRET>

npx wrangler secret put GOOGLE_CLIENT_ID
npx wrangler secret put GOOGLE_CLIENT_SECRET
npx wrangler secret put GOOGLE_REFRESH_TOKEN
npx wrangler deploy        # pick up the secrets
```

## How staff use it

| To do this | Send an email that… |
|---|---|
| Add photos | has one or more image attachments (subject **not** starting with `notice:`, `message:`, `pinphoto:` or `delete:`) |
| Update the banner | has a subject starting with `notice:` — e.g. `notice: Coffee machine is fixed` |
| Set a banner color | includes `#accent=#E8A33D` on a line in the body |
| Clear the banner | subject is exactly `notice:` with an empty body |
| Post a chat message | subject starting with `message:` — e.g. `message: Anyone want tea?` — recorded as "sender - text" in the message panel, up to the last `MAX_MESSAGES` (default 50) |
| Hold a photo on screen | subject `pinphoto:` **with the photo attached** — stored and pinned together |
| Pin a photo already up | subject `pinphoto: <part of its filename>` |
| Resume rotation | subject exactly `pinphoto:`, or `pinphoto: off` / `clear` / `none` / `unpin` |
| Remove photos | **reply to the mail that added them** with subject `delete:` (see below) |

The **directory** is the exception — it has no email path. Edit the Google Sheet
(see below); the change is live within ~15 min on the Worker plus one device poll.

All the rest go to the **same Gmail address**; the subject decides. A `notice:` message with
attachments is treated as a banner update and the images are ignored. Only senders
at the domains in `ALLOWED_SENDER_DOMAINS` (default `yourteam.dev`) are honoured.

### Notice notes

A notice longer than the banner's three lines isn't truncated — the device
scrolls it past and starts over, so the whole thing gets read.

Each `notice:` email pushes the notice it replaces onto a `history` array inside
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

A pinned photo is **exempt from the `MAX_PHOTOS` cull**, so the effective cap is
`MAX_PHOTOS + 1` while an aged-out photo is pinned. If the pinned file disappears
anyway, the next rebuild clears the pin rather than publishing a dangling one.

Filenames are machine-generated (`2026-07-28-jsmith-1753…-1.jpg`), so
`pinphoto: <fragment>` matches on a unique substring. An ambiguous fragment is
refused rather than guessed — check the Worker log (`npm run tail`) for
`pin failed: no unique photo matching …`.

Staff can also **click the photo on the dashboard** to pin or unpin it. That local
choice wins until the emailed pin actually changes, so a poll five minutes later
doesn't undo what someone just did at the wall.

### Deleting notes

Filenames are machine-generated and nothing on the wall or the device shows one, so
the *email that added a photo* is the practical way to identify it — not its name.
To take a photo down, find that email in the inbox and reply to it with subject
`delete:` (an auto-added `Re:` — or a stack of them from a long back-and-forth — is
fine, and so is `Fwd:`). Every photo that message added is removed. **Do not include
the original photo as an attachment when replying** — a forward carries the images
along, and they're deliberately ignored on a `delete:` subject so a forward can't
silently re-add what you just asked to remove.

Matching happens two ways so a client that boxes replies into a fresh thread doesn't
break it: the Gmail thread ID of the reply, and the RFC `Message-ID`s in its
`In-Reply-To`/`References` headers, both checked against what was recorded on each
photo at intake time. A message stored before this feature shipped has neither and can
only be removed by name (below).

When the mail is gone — deleted, or from before this shipped — `delete: <fragment>`
removes one photo by (a unique substring of) its filename, the same matching
`pinphoto:` uses. An ambiguous or empty match changes nothing and logs
`delete failed: …` (`npx wrangler tail`) rather than guessing. A `delete:` reply that
doesn't resolve to any photo — wrong thread, or the email genuinely added none — is
reported the same way and leaves everything untouched.

Removed photos aren't deleted outright; they move to a `removed/` key in R2 (not
served to the device) so a mistaken delete can be undone by hand:
```bash
npx wrangler r2 object get screendash/removed/<file> --file <file> --remote --config worker/wrangler.toml
npx wrangler r2 object put screendash/photos/<file> --file <file> --remote --config worker/wrangler.toml
npx wrangler r2 object delete screendash/removed/<file> --remote --config worker/wrangler.toml
```
then force a manifest rebuild the same way pinning does (below), or wait for the next
intake.

Deleting the pinned photo clears the pin, same as it aging out under `MAX_PHOTOS` does.

Because the dashboard's own mailbox address sends the `delete:` reply, it's listed in
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

## Configuration (`wrangler.toml` `[vars]`)

| Var | Default | Meaning |
|---|---|---|
| `ALLOWED_SENDER_DOMAINS` | `yourteam.dev` | Comma-separated domains permitted to write to the display |
| `ALLOWED_SENDER_ADDRESSES` | *(empty)* | Comma-separated individual addresses permitted on top of the domains above — set to the dashboard's own mailbox so it can send itself `delete:` replies |
| `GMAIL_PROCESSED_LABEL` | `screendash-done` | Label applied to handled mail; also the "skip me" filter |
| `GMAIL_MAX_BATCH` | `10` | Messages processed per poll |
| `GOOGLE_CALENDAR_ID` | `primary` | Which calendar to read |
| `CALENDAR_SPAN_DAYS` | `13` | Days of events to publish — must match `CalendarGrid.span` |
| `DIRECTORY_SHEET_ID` | *(empty)* | Sheet behind `directory.json`; empty disables the sync |
| `DIRECTORY_SHEET_RANGE` | `Directory!A:E` | Tab + columns to read |
| `MAX_ATTACHMENTS` | `10` | Images accepted per email |
| `MAX_PHOTOS` | `40` | Photos retained in rotation; oldest pruned |
| `MAX_IMAGE_EDGE` | `1920` | Longest edge for stored photos |
| `MAX_NOTICE_HISTORY` | `5` | Superseded notices kept in `motd.json` for the banner's arrows |
| `MAX_MESSAGES` | `50` | Messages kept in `messages.json` for the chat panel |

## Manual triggers

Useful during setup — don't wait for the cron:

```bash
curl -X POST $BACKEND/admin/poll-gmail
curl -X POST $BACKEND/admin/sync-calendar
curl -X POST $BACKEND/admin/sync-directory
curl $BACKEND/healthz
npx wrangler tail
```

## Notes & limitations

- **Idempotency.** Messages are selected with `-label:screendash-done` and labelled
  *after* successful processing, so a mid-batch failure retries next tick rather
  than dropping mail. Using a label (not read/unread) means a human opening the
  email in Gmail doesn't break the pipeline. Removing the label re-processes it.
- **Latency.** Photos, notices and pins appear within one poll interval on the
  Worker side, plus another on the device — so up to ~10 min end to end. Force
  the Worker half with `POST /admin/poll-gmail`.
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
