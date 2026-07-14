# DRAFT — GitHub discussion for lichess-org maintainers

> **Status: DRAFT — do not post without review.** Intended venue: a GitHub Discussion on
> `lichess-org/mobile` (or the Lichess dev Discord). Written from the perspective of a fork
> author proposing/validating the work.

---

**Title:** External engine support in the mobile app — interest in upstreaming, and a few
protocol questions

Hi! I've been building external engine support (the
[External Engine API](https://lichess.org/api#tag/External-engine)) into a fork of the mobile
app: a picker in the engine settings that lists the account's registered engines, with analysis
requests streamed from `engine.lichess.ovh` and a graceful fallback to the local Stockfish when
the provider is unreachable. It plugs in behind `EvaluationService` as a third evaluation
backend next to local Stockfish and cloud evals, and is only reachable from the same contexts
as the local engine (analysis/study/broadcast/retro — never live games).

Since the API is marked alpha and asks for coordination, I wanted to check in before going
further:

1. **Would you take this upstream** (behind whatever flag/settings treatment you prefer), or is
   external engine support intentionally out of scope for the official app?

2. **OAuth scopes**: the app's session uses the `web:mobile` scope. Does that cover
   `GET /api/external-engine` (`engine:read`), or would you prefer the app request
   `engine:read` explicitly / extend `web:mobile` server-side? Relatedly, does that endpoint
   accept the mobile app's HMAC-signed bearer form?

3. **Broker behavior for a dead provider**: when an engine is registered but its provider is
   offline, should clients expect `POST .../analyse` to hang, or to fail fast? I'm currently
   using an 8s first-line timeout before falling back to the local engine — is there a
   recommended value?

4. **PoV of `cp`/`mate` in the analyse stream**: scores appear to be side-to-move PoV (raw UCI
   relay). Is that a stable contract we can rely on?

5. **Search limits**: the client `work` object takes `movetime | depth | nodes` (no
   `infinite`). I'm sending `movetime` so the provider self-stops even if the connection close
   is delayed on mobile networks. Any objection / better practice?

6. **Rate limits / connection etiquette** on the analyse endpoint we should respect (e.g. max
   one connection per clientSecret)?

7. **Change management**: how would breaking changes to the alpha protocol be signalled
   (release notes, API changelog, Discord)?

Happy to share the branch and adjust the design to whatever direction you'd want for upstream.

---

> Reviewer notes (not part of the post): the fork branch is
> `claude/planning-session-3ovesf` on `charles022/lichess-mobile-fork`; design details are in
> `docs/external-engine.md`.
