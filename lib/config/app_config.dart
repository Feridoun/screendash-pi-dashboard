/// Central configuration for the ambient dashboard.
///
/// The device is a read-only poller against a single origin (see docs/dashboard-plan.md,
/// Phase 1). Every feature resolves to "GET a small artifact on a timer", so all the URLs
/// and cadences live here in one place. Override [backendBaseUrl] per deployment.
library;

class AppConfig {
  const AppConfig();

  /// Base URL of the backend origin that serves the pre-computed artifacts
  /// (manifest.json, photos/*.jpg, events.json, rota.json, motd.json).
  ///
  /// Override at build time with:
  ///   flutter run --dart-define=BACKEND_BASE_URL=`https://screendash.<you>.workers.dev`
  ///
  /// The default points at the local sample backend (`sample_backend/`, served
  /// on :8080) so a fresh clone runs against fixtures without any deployment.
  /// Every real build passes --dart-define; deploy.sh requires BACKEND_URL.
  static const String backendBaseUrl = String.fromEnvironment(
    'BACKEND_BASE_URL',
    defaultValue: 'http://localhost:8080',
  );

  /// A single-use Tailscale auth key (`tskey-auth-…`), baked in at build time so
  /// the hidden admin panel can bring a stranded board onto the tailnet without
  /// anyone typing a 60-char key on a touchscreen:
  ///   flutterpi_tool build ... --dart-define=TAILSCALE_AUTHKEY=tskey-auth-xxxx
  ///
  /// SECURITY: this ends up in the published bundle on the storage origin. The
  /// bundle is no longer world-readable — the Worker gates `/bundles/*` behind
  /// the DEVICE_TOKEN bearer secret (worker/src/serve.js) — but a credential in
  /// a build artifact still outlives your attention, so generate the key
  /// **tagged `tag:kiosk`**, reusable-OFF, ephemeral-OFF, short expiry, and
  /// REVOKE it in the admin console once the device has joined. Empty by
  /// default, in which case the panel offers a manual paste field instead.
  /// See docs/tailnet-security.md.
  static const String tailscaleAuthKey = String.fromEnvironment(
    'TAILSCALE_AUTHKEY',
    defaultValue: '',
  );

  /// ACL tag the board advertises when it joins the tailnet.
  ///
  /// This is what makes the restrictive policy in deploy/tailscale-acl.json
  /// apply to this device: no rule there lists `tag:kiosk` as a source, so a
  /// board someone walks off with can open a connection to nothing on the
  /// tailnet. An untagged board inherits the tailnet default instead, which is
  /// usually allow-everything-to-everything.
  ///
  /// Set to '' (`--dart-define=TAILSCALE_TAG=`) to join untagged. [SystemOps]
  /// also falls back to an untagged join, and says so, if the tag is refused —
  /// a recovery tool that bricks the recovery because a policy file hasn't been
  /// saved yet would be worse than useless.
  static const String tailscaleTag = String.fromEnvironment(
    'TAILSCALE_TAG',
    defaultValue: 'tag:kiosk',
  );

  // --- Artifact paths (relative to backendBaseUrl) ---
  static const String manifestPath = '/manifest.json';
  static const String photosPath = '/photos'; // + '/<file>'
  static const String eventsPath = '/events.json';
  static const String motdPath = '/motd.json';
  static const String messagesPath = '/messages.json';
  static const String directoryPath = '/directory.json';
  static const String rotaPath = '/rota.json';
  static const String weatherPath = '/weather.json';

  // --- Admin triggers (POST). The one exception to "the device only reads".
  //     These ask the backend to re-sync from its upstream sources *now* rather
  //     than on its cron, so the on-screen refresh button reflects a Sheet or
  //     Calendar edit made seconds ago instead of up to 15 minutes later.     ---
  static const String syncDirectoryPath = '/admin/sync-directory';
  static const String syncCalendarPath = '/admin/sync-calendar';
  static const String syncRotaPath = '/admin/sync-rota';

  // --- Poll cadences. Kept gentle so N devices don't hammer the backend.
  //     Real jitter is applied per-controller (see BackendClient).            ---
  static const Duration manifestPollInterval = Duration(minutes: 5);
  static const Duration eventsPollInterval = Duration(minutes: 10);
  static const Duration motdPollInterval = Duration(minutes: 10);
  // The message panel is closer to a chat feed than a banner, so poll it on
  // the same cadence as the Gmail intake cron (every 5 minutes) rather than
  // the slower motd interval.
  static const Duration messagesPollInterval = Duration(minutes: 5);
  // The directory changes rarely — poll it slowly.
  static const Duration directoryPollInterval = Duration(minutes: 30);
  // The rota moves when someone books leave, which is a few times a week, and
  // the backend only rebuilds it every 15 minutes anyway. Same pace as events.
  static const Duration rotaPollInterval = Duration(minutes: 10);
  // The backend re-reads the forecast on its 15-minute cron, and a daily high
  // barely moves between reads. This is really paced by the rain chance, which
  // is the one number on the strip that can change meaningfully before lunch.
  static const Duration weatherPollInterval = Duration(minutes: 20);

  /// How long each photo stays on screen before cross-fading to the next.
  static const Duration photoDwell = Duration(seconds: 45);

  /// Cross-fade duration between photos. Slow — this is ambient furniture.
  static const Duration photoFade = Duration(milliseconds: 700);

  /// Cross-fade when the viewer re-scales the photo by tapping it. Much quicker
  /// than [photoFade]: this one answers a deliberate press, so it should feel
  /// like a response rather than a drift.
  static const Duration photoScaleFade = Duration(milliseconds: 220);

  /// How long the photo controls linger after a touch before fading away again.
  /// Long enough to step through a few photos without chasing the bar back.
  static const Duration photoControlsLinger = Duration(seconds: 6);

  // --- Notice banner. A notice can be a paragraph rather than a line, so the
  //     banner caps its height and scrolls the overflow past instead of
  //     truncating it.                                                        ---
  /// Most lines of notice text shown at once; beyond this the banner scrolls.
  static const int motdMaxLines = 3;

  /// Auto-scroll speed, logical pixels per second. Slow — this is meant to be
  /// read from across the room, not skimmed.
  static const double motdScrollSpeed = 24;

  /// Pause at the top and bottom of a long notice before scrolling on, so the
  /// first and last lines get a chance to be read.
  static const Duration motdScrollHold = Duration(seconds: 4);

  /// How long the banner keeps showing an older notice (and its cycle controls)
  /// after the last touch before returning to the current one. Longer than
  /// [photoControlsLinger] because reading a notice takes longer than judging a
  /// photo.
  static const Duration motdViewLinger = Duration(seconds: 25);

  // --- Directory column.                                                    ---
  /// How long the dashboard's directory column stays where someone scrolled it
  /// before easing back to the top. Without this the board is left showing the
  /// middle of the staff list until the next person touches it. Longer than
  /// [motdViewLinger]: scanning for a name takes longer than reading a notice.
  static const Duration directoryScrollLinger = Duration(seconds: 45);

  /// The glide back up. Slow enough to read as the board resetting itself
  /// rather than a jump.
  static const Duration directoryScrollReturn = Duration(milliseconds: 900);

  // --- Arrival celebration.                                                 ---
  /// How long the "something new landed" overlay stays up. Long enough to catch
  /// someone walking past, short enough that it never becomes the thing the
  /// board is showing.
  static const Duration celebrationDuration = Duration(seconds: 6);

  /// Confetti pieces in that overlay. Kept modest deliberately: this animates
  /// every frame, and the Pi 3B's VideoCore IV is the same GPU generation the
  /// Zero 2 W had — the extra RAM did not buy any fill rate.
  static const int celebrationParticles = 48;

  // --- Image cache ceilings (Phase 3). A 1080p frame decodes to ~8 MB, and the
  //     rotation only ever needs the current image plus the precached next one.
  //     The Pi 3B's 1 GB leaves room to hold a couple more, so stepping back
  //     through photos by hand doesn't re-decode every time.                   ---
  //     Count is a little above the frames actually in flight because each
  //     letterboxed photo also holds a thumbnail-sized matte entry (see
  //     [photoMatteDecodeWidth]); at ~3 KB apiece those must not be the thing
  //     that evicts the precached next photo. The byte ceiling still governs.
  static const int imageCacheMaxCount = 8;
  static const int imageCacheMaxBytes = 48 << 20; // 48 MB

  /// Max width to decode photos at. Matches a 1080p panel; anything wider is
  /// downsampled on decode so we never pin a frame larger than the screen.
  static const int photoDecodeWidth = 1920;

  /// Width to decode the backdrop behind a letterboxed photo at. Absurdly small
  /// on purpose: stretched over the panel, the bilinear upscale of a ~32 px
  /// bitmap *is* the blur, so the Pi 3B's VideoCore IV never sees an
  /// ImageFilter. Costs about 3 KB and one extra decode per photo.
  static const int photoMatteDecodeWidth = 32;

  /// How much of a photo the stage may crop away before it stops filling the
  /// panel and letterboxes onto a matte instead. The photo panel is a tall
  /// third of the screen, so an untouched landscape group shot loses over half
  /// its width to a cover fit — well past this — while a phone portrait loses
  /// almost nothing and should still go edge to edge.
  static const double photoAutoFillMaxCrop = 0.2;

  // --- Dimming schedule (Phase 2/3). 24h local time.
  //     Overridable at build time so office hours can be tuned per site, and so
  //     the dimming can be pushed out of the way while testing after hours:
  //       --dart-define=ACTIVE_END_HOUR=23
  //                                                                            ---
  /// Office hours: full brightness.
  static const int activeStartHour =
      int.fromEnvironment('ACTIVE_START_HOUR', defaultValue: 8);
  static const int activeEndHour =
      int.fromEnvironment('ACTIVE_END_HOUR', defaultValue: 18);

  /// Evening: soft-dim via in-app scrim (panel stays on).
  static const int dimmedEndHour =
      int.fromEnvironment('DIMMED_END_HOUR', defaultValue: 22);

  /// Outside [activeStartHour, dimmedEndHour): hard-blank the panel.
  /// Opacity of the black scrim during the "dimmed" window (0.0 = off, 1.0 = black).
  static const double dimmedScrimOpacity = 0.55;

  /// How often the dim controller re-evaluates the schedule.
  static const Duration dimTick = Duration(minutes: 1);

  /// How long a wake keeps the panel lit outside office hours before the
  /// schedule takes back over. Measured from the last pointer movement, so it
  /// only starts counting down once someone stops using the board. Long enough
  /// to read it, short enough that a stray bump doesn't light it all night.
  static const Duration wakeDuration = Duration(seconds: 60);

  Uri get manifestUri => Uri.parse('$backendBaseUrl$manifestPath');
  Uri get eventsUri => Uri.parse('$backendBaseUrl$eventsPath');
  Uri get motdUri => Uri.parse('$backendBaseUrl$motdPath');
  Uri get messagesUri => Uri.parse('$backendBaseUrl$messagesPath');
  Uri get directoryUri => Uri.parse('$backendBaseUrl$directoryPath');
  Uri get rotaUri => Uri.parse('$backendBaseUrl$rotaPath');
  Uri get weatherUri => Uri.parse('$backendBaseUrl$weatherPath');
  Uri photoUri(String file) => Uri.parse('$backendBaseUrl$photosPath/$file');

  Uri get syncDirectoryUri => Uri.parse('$backendBaseUrl$syncDirectoryPath');
  Uri get syncCalendarUri => Uri.parse('$backendBaseUrl$syncCalendarPath');
  Uri get syncRotaUri => Uri.parse('$backendBaseUrl$syncRotaPath');
}
