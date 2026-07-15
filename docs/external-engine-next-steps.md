# External engine — open hurdles (sandbox-actionable)

Status: the feature is merged (`219c7e1`) and its 23 unit tests pass, but those tests
mock the broker (`MockClient`) and the local engine (`FakeStockfish`) — no real provider,
no real Lichess login, no real broker connection has ever been exercised. See
`docs/external-engine.md` for the full design and the (still entirely unchecked) manual
validation checklists.

This file lists the issues that can be investigated **from the sandbox** (no phone, no
personal Lichess account, no server required). A later agent should find the right
approach — these are the problems, not the solutions.

## Environment constraints (already confirmed — don't re-litigate)

- No hardware virtualization (`/dev/kvm` absent) → no Android emulator, so the real app
  cannot be run here.
- The agent proxy blocks egress to `lichess.org` and `engine.lichess.ovh` (403 CONNECT) →
  nothing here can reach the real API or broker.
- No Lichess credentials are available in this environment (and none should be handled here).

So anything requiring a live broker, a real login, or an on-device run is **out of scope
for the sandbox** and belongs to a human/hardware pass. Everything below is code/analysis
work that does not need those.

## Hurdles to resolve

1. **OAuth scope mismatch (highest priority).** The app requests only `web:mobile`
   (`lib/src/model/auth/auth_repository.dart`), but listing engines
   (`GET /api/external-engine`, used by `ExternalEngineRepository.listEngines`) is
   documented to need `engine:read`. As built the settings list may always come up empty.
   Determine whether the scope must change and what the re-login implications are.

2. **Verify the analyse request/response contract against the documented protocol.**
   The protocol notes in `docs/external-engine.md` were written "as observed" and are
   unverified. Cross-check the request body builder and the ND-JSON eval parser
   (`external_engine_repository.dart`) against those notes — field names, the single
   search-limit rule, `multiPv`/`threads`/`hash` clamping, and the score point-of-view
   flip — for internal consistency.

3. **The protocol spike CLI (`tool/external_engine_spike.dart`) has no automated coverage.**
   It is the intended tool for validating auth/protocol against a live provider, yet nothing
   confirms it even builds or that its argument/auth handling is correct before someone
   points it at real hardware. Make it trustworthy offline.

4. **Fallback / watchdog behavior is only tested against synthetic streams.** Review the
   connect/stall watchdogs and the offline-fallback path
   (`evaluation_service.dart`, `external_engine_client.dart`) for edge cases the current
   tests don't cover (e.g. partial lines, mid-stream errors, session reuse, timeout tuning).

5. **The sideload build path is unverified.** `.github/workflows/build-apk.yml` and the
   release-build instructions have never been run/validated. Confirm the workflow is
   sound (inputs, signing config expectations, `--dart-define`s) without needing to
   actually ship an APK.

6. **Provider setup ergonomics.** The runbook in `docs/external-engine.md` is manual
   prose. Anything that makes standing up a provider more turnkey (so the eventual
   hardware pass is faster) is useful groundwork.

## Handoff to a hardware/account pass (context only — NOT sandbox work)

For the record, the following require a real server, a real Lichess account, and a
KVM-capable host or physical phone, and cannot be done here:

- Running the reference provider + Stockfish and registering it with an account.
- Executing `external_engine_spike.dart` against the live broker.
- Walking the on-device E2E checklist in `docs/external-engine.md`.
