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
       --engine /usr/bin/stockfish --name "Stockfish (home server)"
   ```

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
       --engine /usr/bin/stockfish --name "Stockfish (home server)"
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

## Protocol notes (as observed, July 2026)

- `GET https://lichess.org/api/external-engine` → `[{id, name, clientSecret, userId,
  maxThreads, maxHash, variants, providerData}]`, OAuth scope `engine:read`.
- `POST https://engine.lichess.ovh/api/external-engine/{id}/analyse` with
  `{clientSecret, work: {sessionId, threads, hash, multiPv, variant, initialFen, moves,
  movetime|depth|nodes}}` (exactly one search limit; there is no `infinite` — the app sends
  `movetime`). Response is chunked ND-JSON; each line is
  `{time, depth, nodes, pvs: [{moves, cp|mate, depth}]}` with scores from the side to move's
  point of view (the app flips them to white PoV, mirroring its UCI parsing).
- Reusing a `sessionId` across requests keeps the provider's hash table; a new session triggers
  `ucinewgame`. The app uses one session per analysis screen.
- The broker caps `multiPv` at 5 and clamps `threads`/`hash` to the engine's registered maxima.
- Cancellation is by closing the HTTP connection (the broker watches for it); there is no
  explicit stop endpoint on the client side.

Validation checklist for these notes (automated by the **External engine live protocol test**
workflow — see `docs/external-engine-next-steps.md` for the `LICHESS_API_TOKEN` secret setup —
or run manually against your own provider with `tool/external_engine_spike.dart`):

- [ ] `list` works with a raw personal access token
- [ ] `list` works with the app's HMAC-signed bearer form (`--signed`) — determines whether the
      app needs auth changes upstream
- [ ] analyse streams eval lines; `cp` PoV confirmed with the spike's black-winning position
- [ ] closing the connection stops the provider (watch its logs)
- [ ] behavior when the provider is stopped: does analyse hang or return an error? (tunes the
      app's first-line timeout, currently 8s)

## End-to-end test checklist (on device)

- [ ] Fresh analysis session with external engine: gauge/lines/depth update, engine name shown
- [ ] Rapid move scrubbing: no stale evals, provider log shows cancelled work
- [ ] Kill the provider mid-analysis: snackbar appears, analysis continues on local engine
- [ ] Restart the provider, long-press engine button → Retry: external analysis resumes
- [ ] Delete the engine server-side: settings shows stale entry, analysis falls back to local
- [ ] Log out / switch account: analysis falls back to local, no crash
- [ ] Variant study not supported by the engine: local engine used silently
- [ ] Background the app 5 minutes mid-analysis, resume: no stuck state
- [ ] Airplane mode: offline fallback (local engine still works)
- [ ] "Go deeper" / infinite search time
- [ ] Threat mode (show threat): eval sign is correct

## Installing the fork on a device (Pixel 10 Pro)

The final deliverable of this feature is a sideloadable build of the fork:

1. Run the **Build sideload APK** workflow from the repository's Actions tab
   (`.github/workflows/build-apk.yml`) and download the `lichess-mobile-apk` artifact, or build
   locally:

   ```bash
   flutter build apk --release --target-platform android-arm64 \
       --dart-define=cronetHttpNoPlay=true \
       --dart-define=LICHESS_HOST=lichess.org \
       --dart-define=LICHESS_WS_HOST=socket.lichess.org
   ```

   (Local release builds need an `android/key.properties` signing config; see the workflow file
   for how to generate a keystore.)

2. The release application id is `org.lichess.mobileV2` — the same as the official app.
   **Uninstall the Play Store app first**, then install the APK (enable "install unknown apps"
   for your browser/file manager on the Pixel).

3. Sign in, then follow "Using it in the app" above. Note the fork is built without the
   official `LICHESS_WS_SECRET`; if authenticated API calls misbehave, that is the first thing
   to investigate (see open questions).

## Known limitations / open questions

- Whether the app's OAuth session (scope `web:mobile`) can call `GET /api/external-engine` on
  lichess.org is unverified — the fork may need to add `engine:read` to its requested scopes
  (`lib/src/model/auth/auth_repository.dart`), which requires re-login. Tracked in the
  maintainer discussion draft.
- The cores/hash sliders in engine settings apply to the local engine (including fallback);
  external analysis always requests the engine's registered `maxThreads`/`maxHash`.
- The engine list is cached for 5 minutes; a newly registered engine may take up to that long
  to appear in settings (or reopen the screen).
