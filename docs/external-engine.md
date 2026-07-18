# External engine support (fork feature)

This fork adds the ability to power position analysis with a chess engine running on your own
hardware, via the official [Lichess External Engine API](https://lichess.org/api#tag/External-engine).

**The API is in alpha and subject to change.** Lichess asks that production integrations be
coordinated with their team (see `external-engine-discussion-draft.md`).

## How it works

```
┌──────────────┐   OAuth (engine:read)    ┌─────────────┐
│  mobile app  │─────────────────────────▶│ lichess.org  │  list registered engines
│              │                          └─────────────┘
│              │   clientSecret            ┌──────────────────┐      long-poll       ┌──────────────┐
│              │──────────────────────────▶│ engine.lichess.ovh│◀────────────────────│ your server   │
│              │◀── ND-JSON eval stream ───│   (broker)        │── UCI stream ──────▶│ (provider +   │
└──────────────┘                           └──────────────────┘                      │  Stockfish)   │
                                                                                     └──────────────┘
```

- The **provider** is an off-the-shelf daemon on your server. It registers the engine with your
  Lichess account (OAuth token with `engine:read` + `engine:write`) and long-polls the broker
  for analysis work. Your server only needs outbound HTTPS — no port forwarding.
- The **app** lists your registered engines (`GET /api/external-engine`) and, when one is
  selected in Settings → Chess engine, streams analysis from the broker. Auth for the analysis
  call is the engine's `clientSecret`; the secret is fetched fresh each session and never stored
  on the device.
- **Cancellation**: the broker stops the provider when the client closes the HTTP connection.
  The app closes the connection on every position change (one in-flight request at a time,
  cancel-before-start) and additionally bounds every request with `movetime`, so a lost
  connection can't leave the provider analysing forever.
- **Fallback**: if the provider is unreachable (timeouts, HTTP errors), the app falls back to
  the local Stockfish for the rest of the analysis session and shows an "offline" state; the
  engine long-press popup has a Retry action.
- **Fair play**: the external engine is only reachable from analysis/study/broadcast/retro
  contexts — the same contexts where the local engine is available. Live games and the offline
  computer opponent never touch it (enforced structurally: those code paths cannot construct an
  external-engine work item).

## Provider setup (Ubuntu/Debian-family Linux)

**Fast path:** `scripts/setup-external-engine.sh` automates all of the steps below (install
prerequisites, check out the reference provider into a venv, and install + start the systemd
service). On the engine machine:

```bash
sudo LICHESS_API_TOKEN=lip_*** ./scripts/setup-external-engine.sh
```

Run it with `--help` for options (engine name, binary path, threads/hash caps, `--no-service`
for a foreground test run). The manual steps below explain exactly what it does.

1. Install prerequisites:

   ```bash
   sudo apt install python3 python3-venv stockfish
   ```

2. Create an OAuth token at
   <https://lichess.org/account/oauth/token/create?scopes[]=engine:read&scopes[]=engine:write&description=External+engine+provider>

3. Set up the reference provider:

   ```bash
   git clone https://github.com/lichess-org/external-engine.git /opt/external-engine
   cd /opt/external-engine
   python3 -m venv venv
   venv/bin/pip install -r requirements.txt
   ```

4. Test run:

   ```bash
   LICHESS_API_TOKEN=lip_*** venv/bin/python example-provider.py \
       --engine /usr/games/stockfish --name "Stockfish (home server)"
   ```

   (Debian/Ubuntu's `stockfish` package installs the binary to `/usr/games/stockfish`,
   which may not be on `PATH` in non-interactive shells.)

   Then open <https://lichess.org/analysis>, click the engine manager (gear icon in the engine
   pane), and select your engine. Verify analysis works and that the provider log shows work.

   Useful flags: `--default-max-threads`, `--default-max-hash`, `--keep-alive`. Run with
   `--help` for the full list. ([tors42/ee](https://github.com/tors42/ee) is a Java alternative
   with similar behavior.)

5. Run as a systemd service — `/etc/systemd/system/lichess-engine-provider.service`:

   ```ini
   [Unit]
   Description=Lichess external engine provider
   After=network-online.target
   Wants=network-online.target

   [Service]
   Type=simple
   User=engine
   EnvironmentFile=/etc/lichess-engine-provider.env
   ExecStart=/opt/external-engine/venv/bin/python /opt/external-engine/example-provider.py \
       --engine /usr/games/stockfish --name "Stockfish (home server)"
   Restart=on-failure
   RestartSec=5

   [Install]
   WantedBy=multi-user.target
   ```

   `/etc/lichess-engine-provider.env` (mode 0600, owned by root):

   ```
   LICHESS_API_TOKEN=lip_***
   ```

   ```bash
   sudo useradd -r -s /usr/sbin/nologin engine
   sudo systemctl daemon-reload
   sudo systemctl enable --now lichess-engine-provider
   journalctl -u lichess-engine-provider -f
   ```

## Using it in the app

1. Sign in with the same account the provider is registered to.
2. Settings → Chess engine → **External engines**: your engine appears in the list; tap to
   select it (tap again to go back to the local engine).
3. Open any analysis screen. The engine button (bottom bar) shows the external engine's name
   while it is computing. Long-press the engine button for status; if the engine is offline a
   Retry action appears there.

## Protocol notes (verified against the live broker, 2026-07-15)

- `GET https://lichess.org/api/external-engine` → `[{id, name, clientSecret, userId,
  maxThreads, maxHash, variants, providerData}]`, OAuth scope `engine:read`.
- `POST https://engine.lichess.ovh/api/external-engine/{id}/analyse` with
  `{clientSecret, work: {sessionId, threads, hash, multiPv, variant, initialFen, moves,
  movetime|depth|nodes}}` (exactly one search limit; there is no `infinite` — the app sends
  `movetime`). Response is chunked ND-JSON; each line is
  `{time, depth, nodes, pvs: [{moves, cp|mate, depth}]}` with scores from **white's point of
  view** — unlike raw UCI, no flip is needed. Verified live: a black-to-move winning position
  streams cp ≈ -800. (An earlier draft of these notes wrongly assumed side-to-move PoV and the
  app flipped scores accordingly, which would have inverted the eval whenever black was to
  move — the live protocol test caught it.)
- Reusing a `sessionId` across requests keeps the provider's hash table; a new session triggers
  `ucinewgame`. The app uses one session per analysis screen.
- The broker caps `multiPv` at 5 and clamps `threads`/`hash` to the engine's registered maxima.
- Cancellation is by closing the HTTP connection (the broker watches for it); there is no
  explicit stop endpoint on the client side.

Validation checklist for these notes (automated by the **External engine live protocol test**
workflow — see `docs/external-engine-next-steps.md` for the `LICHESS_API_TOKEN` secret setup —
or run manually against your own provider with `tool/external_engine_spike.dart`):

- [x] `list` works with a raw personal access token (HTTP 200, run 4, 2026-07-15)
- [x] `list` works with the app's HMAC-signed bearer form (`--signed`) — **accepted** by
      lichess.org (HTTP 200), so the app's bearer signing needs no changes for this endpoint
- [x] analyse streams eval lines; `cp` PoV confirmed with the spike's black-winning position:
      **white-anchored** (cp ≈ -890), see the protocol notes above
- [x] closing the connection cancels the request cleanly at the broker (client sees the close
      immediately; provider log uploaded as a run artifact)
- [x] behavior when the provider is stopped: the broker holds the analyse request for ~15s and
      then returns **HTTP 503** and closes the stream — no indefinite hang. The app's 8s
      first-line watchdog fires before that, so the offline fallback kicks in even earlier;
      the timeout needs no tuning.

## End-to-end test checklist (on device)

> **Status (2026-07-17):** the E2E workflow is green — run 29549888431 passed all ten
> automated phases against a genuinely streaming external engine. Getting there required
> fixing a real Android streaming bug (cronet buffered the analyse ND-JSON stream; the
> app now uses a `dart:io` client for that request) and an unhandled-refresh-error app
> bug — see `docs/external-engine-next-steps.md` for the record and
> `docs/external-engine-status.md` for the current status.

The items marked **automated** run in CI on every relevant push via the
**External engine E2E test (emulator)** workflow
(`.github/workflows/external-engine-e2e-test.yml`), which boots the app on an Android
emulator and drives `integration_test/external_engine_test.dart` against the real API and
broker — see `docs/external-engine-next-steps.md` for how it works. The rest still needs a
manual pass on a phone.

- [x] Fresh analysis session with external engine: engine listed and selectable in settings,
      evals stream, engine name shown — **automated**
- [x] Kill the provider mid-analysis: snackbar appears, analysis continues on local engine —
      **automated** (provider is paused via SIGSTOP)
- [x] Restart the provider, long-press engine button → Retry: external analysis resumes —
      **automated**
- [x] Rapid move scrubbing: cancelled work handled cleanly, evals recover — **automated**
      (provider-log inspection of the cancellations stays manual via the run artifact)
- [x] Delete the engine server-side: analysis falls back to local — **automated**; the
      "settings shows stale entry" half needs the 5-minute engine-list cache to expire, so
      it stays manual
- [ ] Log out / switch account: analysis falls back to local, no crash — **must stay
      manual**: the app's sign-out revokes its token (`DELETE /api/token`), which in CI
      would destroy the `LICHESS_API_TOKEN` secret itself
- [x] Variant analysis not supported by the engine: local engine used silently —
      **automated** (antichess against the chess-only CI engine)
- [x] Background the app mid-analysis, resume: no stuck state — **automated with reduced
      fidelity** (simulated lifecycle pause/resume for 15s; a real 5-minute OS
      backgrounding with process freeze still needs a phone)
- [x] Airplane mode: offline fallback (local engine still works) — **automated with reduced
      fidelity** (emulator airplane mode via adb; real radio behavior needs a phone)
- [x] "Go deeper" — **automated** (infinite search time stays manual)
- [ ] Threat mode (show threat): eval sign is correct — manual by eye; the underlying
      white-anchored score convention is asserted on every Tier 1 live protocol run

## Installing the fork on a device (Pixel 10 Pro)

The final deliverable of this feature is a sideloadable build of the fork:

1. Run the **Build sideload APK** workflow from the repository's Actions tab
   (`.github/workflows/build-apk.yml`) and download the `lichess-mobile-apk` artifact, or build
   locally:

   ```bash
   flutter build apk --release --target-platform android-arm64 \
       --dart-define=cronetHttpNoPlay=true \
       --dart-define=LICHESS_HOST=lichess.org \
       --dart-define=LICHESS_WS_HOST=socket.lichess.org \
       --dart-define=LICHESS_WS_SECRET="$LICHESS_WS_SECRET"
   ```

   (Local release builds need an `android/key.properties` signing config; see the workflow file
   for how to generate a keystore.) `LICHESS_WS_SECRET` must be the official production Lichess
   Mobile HMAC value; a personal access token cannot replace it. Lichess publishes this client
   build constant in its
   [F-Droid workflow](https://github.com/lichess-org/mobile/blob/fdroid/.github/workflows/upload_fdroid_apks.yml)
   for reproducible builds. The workflow stores it as the `WS_SECRET` repository secret and
   stops before building if it is absent.

2. The release application id is `org.lichess.mobileV2` — the same as the official app.
   **Uninstall the Play Store app first**, then install the APK (enable "install unknown apps"
   for your browser/file manager on the Pixel).

3. Sign in, then follow "Using it in the app" above.

## Known limitations / open questions

- The app requests `engine:read` in addition to `web:mobile`. A Pixel 10 Pro test confirmed
  that `GET /api/external-engine` returns 403 when the session has only `web:mobile`; users
  upgrading from that build must sign in again to grant the added scope.
- The cores/hash sliders in engine settings apply to the local engine (including fallback);
  external analysis always requests the engine's registered `maxThreads`/`maxHash`.
- The engine list is cached for 5 minutes; a newly registered engine may take up to that long
  to appear in settings (or reopen the screen).
