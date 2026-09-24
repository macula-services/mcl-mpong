# mcl-mpong

**Two bots play pong over the mesh, and the match reports how the mesh carried it.**

This exists so anyone watching a pong match between two bots is also watching
the mesh: how long a paddle move takes to come back, how many frames go missing,
and which stations each end is on.

## Status

Built and tested. Its fleet definition (two bots, pinned by digest) is in `macula-fleet`; see Deployment. Runs on macula 12 through `mcl_om`.
The spectator, macula-portal's `mpong_subscriber`, still reads the old topics
and gets repointed at the contract below. This replaces
`hecate-services/hecate-mpong-bot`, which ran on macula 10 and inherits nothing:
no identity, no topic, no store.

**No event store, by decision.** A match is throwaway state held in the engine
process. This is a scoped waiver of the house rule that business processes are
event sourced, for this demo only (Raf, 2026-09-23).

## What it does

- **Finds an opponent.** Each bot listens for open games for a jittered few
  seconds. If it hears one it asks for the seat; if not it hosts its own and
  advertises it. The jitter makes each bot a host or a challenger, never both.
  A host nobody joins gives up and seeks again, so two bots that both started
  hosting still pair.
- **Plays.** The host runs the authoritative game (25 Hz, a game to 11, win by
  2, best of 3) and publishes a frame 5 times a second. The challenger steers
  its paddle toward the ball in the host's frames and publishes its moves.
- **Measures.** Every move and every frame carries what its sender has observed
  of the other end through the mesh (below).
- **Refuses a third player** with `seat_denied`, so a refusal is a fact on the
  mesh rather than a silence.
- **Pauses** when the challenger's paddle goes silent for 3 s, and ends the game
  if it stays silent for 10 s more. The other way round, a challenger whose host
  sends no frame for 10 s leaves the game and seeks again, so the pair re-forms
  after either bot restarts. `/health` says `degraded` while the other end of a
  match has been silent for more than 3 s.

Every fact is attributed by the **publisher macula verified**, never by the
payload: a seat goes to whoever asked for it, a move counts only from the bot
holding the seat, a frame only from the host of the game. The mesh hands a bot
its own facts back, and those are ignored.

## The fact contract

Six topics, org `mcl-mpong`, app `mpong`, domain `match`, version 2, for example
`io.macula/mcl-mpong/mpong/match/state_broadcast_v2`. The `game_id` is in the
payload, never in a topic. Values are binaries, integers, lists and maps; flags
are 1/0; node ids are lowercase hex. `apps/mcl_mpong/test/mcl_mpong_facts_tests.erl`
pins every topic and every key, and a change that breaks it gets a new `_vN`.

| Fact | From | Carries |
|---|---|---|
| `game_advertised_v2` | host | `game_id`, `status` (`open`, `playing`, `ended`, `withdrawn`), `host_node_id`, `max_players`, `at_ms` |
| `seat_requested_v2` | challenger | `game_id`, `wall_index`, `at_ms` |
| `seat_reserved_v2` | host | `game_id`, `challenger_node_id`, `wall_index`, `at_ms` |
| `seat_denied_v2` | host | `game_id`, `challenger_node_id`, `reason`, `at_ms` |
| `paddle_moved_v2` | challenger | `game_id`, `wall_index`, `y`, `tick`, `move_seq`, and the challenger's measurements |
| `state_broadcast_v2` | host | the game (`ball`, `paddles`, `alive`, `points`, `games_won`, `serving`, `obstacles`, `paused`, `tick`, `arena`) and a `mesh` block |

### What the match measures

The `mesh` block in every `state_broadcast_v2`:

| Key | Meaning |
|---|---|
| `frame_seq`, `frames_sent` | the host numbers its frames from 1 |
| `host_stations` | node ids of the stations the host's pool is connected to |
| `moves_seen`, `moves_missed` | the challenger's moves the host received, and the gaps in `move_seq` |
| `moves_delivered_via` | how the last move arrived: `direct`, `plumtree`, or `none` yet |
| `echo_move_seq`, `echo_held_ms` | the latest move the host applied, and how long it held it before this frame |
| `challenger` | the challenger's own report, from its latest move |

The challenger's report, in every `paddle_moved_v2` and echoed in `mesh.challenger`:

| Key | Meaning |
|---|---|
| `frames_seen`, `frames_missed` | the host's frames it received, and the gaps in `frame_seq` since it joined |
| `rtt_ms_last`, `rtt_ms_p50`, `rtt_samples` | round trip of its moves, over the last 32 |
| `stations` | node ids of the stations the challenger's pool is connected to |
| `frames_delivered_via` | how the last frame arrived |

**The round trip needs no synchronised clocks.** The challenger times a move
from sending it to seeing it echoed, and subtracts `echo_held_ms`, the time the
host held it. Each side reads only its own monotonic clock. Before any sample
exists the counts are 0, and `rtt_samples` says so.

Two ends, two station sets, two delivery channels: `host_stations` →
`challenger.stations` is the path a spectator can draw.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `MCL_REALM` | required | 64-hex realm tag, sha256 of the realm name |
| `MCL_REALM_NAME` | required | the realm name the topics carry, e.g. `io.macula`. The service **refuses to start** unless its sha256 is `MCL_REALM` |
| `MCL_REALM_KEY` | required | the realm's public signing key, hex. The trust anchor, public material |
| `MACULA_STATION_SEEDS` | required | station hosts, `host[:port]`, comma-separated |
| `MACULA_STATION_NODE_IDS` | required | the matching 64-hex station node ids, index-paired |
| `MCL_HEALTH_PORT` | `8472` | health endpoint; host networking makes a clash a silent bind failure |
| `MCL_NODE_NAME` | `mcl_mpong` | Erlang node name |
| `MCL_NODE_HOST` | `127.0.0.1` | Erlang node host |
| `MCL_COOKIE` | `mcl_mpong` | Erlang cookie |

A match needs **two** running bots. One alone hosts, gives up, seeks, and hosts
again, and reports itself degraded after 15 minutes of that.

`deploy/docker-compose.yml` runs one bot. It mounts a named volume at
`/etc/mcl/secrets` for the node identity key, which is the bot's verified
identity on the mesh; without it every recreate mints a new one. The volume is
named `mcl-mpong-secrets` in the file, not derived from the project name, so a
second bot on the same host needs its own copy with a different volume name,
container name and health port, or the two share one identity.

### Node id

Once its pool is up, a bot logs `[mpong] node id: <64 hex>`. That is the id the
other bot and the spectator see as this bot's verified publisher. It is stable
as long as the identity volume is.

## Health

`/health` reports the **match**, because a bot with nobody to play is the mesh
failing at the one thing this service shows:

- `down` when the coordinator is not answering;
- `degraded` when the bot has had no opponent for more than 15 minutes;
- `ok` otherwise, including while seeking.

`scripts/health.sh [host]` asks a running node.

## Build and test

    scripts/check.sh        # compile, eunit, lint, as CI runs them

OTP **28.4.3**, the team standard. The image builds in the team's
`macula-ci-otp` by digest and runs on the matching `macula-pq-runtime` by digest
(`Containerfile`), and CI lints and tests in that same `macula-ci-otp` digest
(`lint.yml`). A test fails when the two files name different images, or when the
VM running the suite is not the release `.tool-versions` names. `check.sh` puts
OTP 28.4.3 first on the path. The same gate, in the CI image, as root:

    podman run --rm --cpus=4 --memory=8g -v "$PWD:/src:Z" -w /src \
      "$(sed -n 's/^ARG CI_OTP=//p' Containerfile)" \
      bash -c 'rebar3 compile && rebar3 eunit && rebar3 lint'

The image carries the commit it was built from as
`org.opencontainers.image.revision`.

The suite pairs two bots without a mesh: two coordinators find each other and
trade frames and moves, round trips included, through an in-test bus that sends
every fact through macula's own CBOR codec and back to every bot, the sender
included. It does not play a match to its end.

## Deployment

CI pushes `ghcr.io/macula-services/mcl-mpong:latest` on every push to `main`
that touches code, and the semver tag on a `v*` tag. A push deploys nothing:
the fleet runs the image **pinned by digest** in `macula-io/macula-fleet`
(`edge/scripts/docker-compose.mcl-mpong.yml`), two bots, beam01 dialling
nuremberg and beam02 helsinki, so every match crosses stations. A new build
reaches them only when that pin moves.

The package is public.

## The service contract

`mcl_mpong_service` implements the six `mcl_om_service` callbacks, all resolved
**by name** at startup, plus `subscriptions/0`, which gives mcl_om one
subscriber per match fact. It announces no capability and asks the realm for no
authority: the bot's whole output is its published facts.

## License

Apache-2.0.
