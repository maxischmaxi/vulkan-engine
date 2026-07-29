# Multi-server architecture: master, fleet agents, auto-scaling

How the game scales from one hand-started server to a fleet of instances
across regions, and how players end up on the right one. Built 2026-07;
everything here is implemented and locally verified unless marked otherwise.

## Goals and non-goals

- Spawn arbitrarily many `vulkan-server` instances per region (EU, US, ...),
  route players to a joinable one in their region, and scale the fleet up and
  down with load -- ideally without anyone touching a shell.
- Adding a region or a host must be trivial: boot a machine, start one agent
  process, done.
- **No Redis, no database.** The only shared state is "which servers exist and
  how full are they", and that is *soft state*: every server and agent
  heartbeats every 2 seconds, so any registry can be rebuilt from thin air in
  one heartbeat interval. A master that crashes and restarts self-heals; a
  persistent store would only add a second source of truth to keep consistent.
- **No self-built proxies or entry nodes.** Release builds already run all
  game traffic over Steam Datagram Relay (SDR): clients connect to a
  *SteamID64*, not an IP, and Valve's worldwide relay network does geo-routing
  and DDoS absorption while hiding the server's address. What was missing was
  purely discovery -- *which* SteamID to connect to. That is the master's job.

## The pieces

```
                    Find_Server / Find_Response
        Client ────────────────────────────────▶ Master (vulkan-master)
           ▲                                      ▲   ▲
           │ game traffic                         │   │ Spawn_Server / Stop_Server
           │ (SDR by SteamID, or UDP in dev)      │   │ Spawn_Result
           ▼                        Server_Heart- │   │
        Game server ◀── spawns ── Fleet agent ────┘   │
        (vulkan-server)           (vulkan-agent) ─────┘
                                   one per host        Agent_Heartbeat
```

| Process | Package | Role |
|---|---|---|
| `vulkan-master` | `src/master/` | The directory: registry of servers and agents, server selection for clients, scale-up/down decisions. One instance, one thread, one UDP socket. |
| `vulkan-agent` | `src/agent/` | One per game-server host. Registers region + capacity, spawns/stops `vulkan-server` children on the master's command, forwards its own SIGTERM to them. |
| `vulkan-server` | `src/server/` | Unchanged game server, plus: heartbeat sender, drain handling, graceful shutdown (`heartbeat.odin`, `shutdown.odin`). |
| client | `src/` | `--master=H:P` routes PLAY through a master query instead of a hardcoded address (`master_query.odin`). |

All four share the wire protocol in `src/mm/` (package `mm`).

Scaling worldwide is therefore: run the master anywhere with a public UDP
port; per region, boot hosts that run the agent. Nothing else needs
configuring -- the master learns capacity from agent heartbeats.

## The control-plane protocol (`src/mm/`)

Deliberately the opposite of the game protocol: **stateless request/response
datagrams**. No sessions, no acks, no reliability -- a lost datagram costs at
most one heartbeat interval, and the next one carries the full state again.

Frame on every datagram (little-endian, `mm.frame_begin`/`mm.frame_open`):

```
u16 magic   0x4D53          (distinct from the game's 0xB0F5)
u8  version 1
u8  msg                     (Mm_Msg)
... payload
```

Payload primitives reuse `src/protocol`'s sticky-error Writer/Reader. Shared
field types: `Token` = fixed 32 bytes (zero-padded shared secret), `Region` =
u8 length + fixed 16-byte block (zero-padded, so `==` compares), `Server_Addr`
= kind u8 (`Udp`/`Steam`) + steam_id u64 + ip4 [4]u8 + port u16.

### Messages

| Msg | Id | Direction | Payload / semantics |
|---|---|---|---|
| `Server_Heartbeat` | 0x01 | server → master | token, server_id, spawn_id (0 = hand-started), region, `Server_Addr`, players, max_players, phase, joinable, draining. Upserts the registry entry. |
| `Server_Bye` | 0x02 | server → master | token, server_id. Sent 3x on graceful exit so the entry dies now, not at TTL. |
| `Server_Drain` | 0x03 | master → server | token, server_id. Sent to the heartbeat's source endpoint: stop accepting joins, exit when empty. Resent every sweep until the entry disappears. |
| `Agent_Heartbeat` | 0x10 | agent → master | token, agent_id (random at boot), region, capacity, running. |
| `Spawn_Server` | 0x11 | master → agent | token, spawn_id. Start one child. |
| `Spawn_Result` | 0x12 | agent → master | token, spawn_id, ok, port. `ok=false` frees the pending slot immediately. |
| `Stop_Server` | 0x13 | master → agent | token, server_id. Escalation: agent SIGTERMs that child, SIGKILL after 5 s. |
| `Find_Server` | 0x20 | client → master | nonce, region (empty = any), game_version, accepts bitmask (bit 0 UDP, bit 1 Steam). Unauthenticated. |
| `Find_Response` | 0x21 | master → client | nonce, status (`Ok`/`Spawning`/`No_Capacity`), `Server_Addr` (valid on `Ok`). |

### Identity and correlation

`spawn_id` is the one correlation id end to end: the master mints it, the
agent passes it to the child as `-server-id`, the child heartbeats it as its
`server_id`, and the master's pending-spawn entry clears when that first
heartbeat arrives. A hand-started server has `spawn_id = 0` and a random
`server_id`; the master never drains or stops those.

### Authentication

Server and agent messages carry the 32-byte token as their first payload
field; the master silently drops mismatches. Client queries are
unauthenticated -- they can only ever learn what servers advertise anyway --
and are protected against spoofed answers by the nonce plus a source-endpoint
check on the client. See *Known limitations* for what this model does not do.

### Timing constants (`src/mm/mm.odin`)

| Constant | Value | Meaning |
|---|---|---|
| `HEARTBEAT_SECONDS` | 2.0 | server + agent heartbeat cadence |
| `ENTRY_TTL_SECONDS` | 7.0 | 3 missed heartbeats + slack → entry dropped |
| `SPAWN_TIMEOUT_SECONDS` | 20.0 | boot budget (world bake + Steam logon) before a pending spawn is declared failed |
| `RESERVE_SECONDS` | 10.0 | server held off the menu after being handed to a client |
| `CLIENT_RETRY_SECONDS` | 1.0 | client resend cadence for `Find_Server` |
| `CLIENT_GIVEUP_SECONDS` | 30.0 | client's total search budget |
| `MM_DEFAULT_PORT` | 27050 | master's UDP port |
| `MM_MAX_DATAGRAM` | 256 | biggest control datagram (~90 bytes today) |

## Game server integration

New flags (same single-dash style as the rest): `-master=HOST:PORT`,
`-region=STR` (default `local`), `-token=STR`, `-server-id=N` (set by the
agent), `-advertise=IP:PORT`. Without `-master` nothing changes -- the control
plane is fully opt-in.

**Heartbeat** (`src/server/heartbeat.odin`): a dedicated control socket that
exists in *every* build -- `STEAM_REQUIRED` compiles out the game's UDP
listener, not this. Sends every 128 ticks (2 s at 64 Hz), plus immediately
whenever a packed status signature (players, phase, joinable, draining)
changes -- so the master's view lags a join or leave by one tick, not by two
seconds, without dirty-flag hooks scattered through match/client code.

- The **joinable predicate lives server-side**: today it is
  `match.phase == .Idle && !draining`. When multi-human matches arrive, this
  one line changes and the master stays ignorant of match semantics.
- **Advertised address**: `STEAM_REQUIRED` builds advertise their SteamID64
  and hold heartbeats until the anonymous logon confirms (before that the
  server has no address). Dev builds advertise their UDP port and leave the IP
  zero; the master substitutes the heartbeat's source IP, which is correct
  whenever clients and master see the server from the same side of the
  network. `-advertise=IP:PORT` is the override for split-NAT setups.

**Graceful shutdown** (`src/server/shutdown.odin`): SIGTERM/SIGINT set one
atomic flag from a `proc "c"` handler; the tick loop picks it up.
`begin_shutdown` kicks every client with the existing `.Shutdown` reason,
fires 3x `Server_Bye`, keeps ticking `SHUTDOWN_FLUSH_TICKS` (32, ~0.5 s) so
the datagrams and Steam close handshakes flush, then stops the loop -- the
first and only place `sv.running` ever goes false. A second signal exits
immediately. This is what makes an instance safe to stop from systemd, an
agent, or Ctrl-C.

**Drain** (scale-down path): on `Server_Drain` the server sets a flag; new
handshakes are answered `Connect_Deny{.Full}` (`server_refusing_joins` in
`clients.odin`), and once every slot is empty it runs the same shutdown. Since
the master only drains empty servers, this exits within a tick in practice --
connected players are never cut by a drain.

## Master internals (`src/master/`)

Single thread: drain socket → dispatch → sweep (at 1 s cadence) → sleep 10 ms.
Flags: `-port=27050`, `-token=STR` (required), `-idle-stop=300` (seconds),
`-floor=1`.

**Registry** (`registry.odin`): fixed tables in the codebase's bounded style
-- 64 servers, 16 agents, 16 pending spawns; overflow logs and drops. Entries
die by TTL when heartbeats stop, so crash cleanup and state repair are the
same code path. `empty_since` tracks how long a server has reported zero
players; `reserved_at` implements the 10 s reservation.

**Selection** (`handlers.odin`, on `Find_Server`): candidates must match the
requested region (empty = any), be joinable, not draining, not full, not
reserved, and advertise an address kind the client accepts. Among those, pick
the *fullest* (fill-first keeps the fleet dense). On `Ok` the server is
reserved for 10 s so two concurrent queries cannot land on the same
single-human instance; an unused reservation lapses harmlessly. A client whose
`game_version` differs from the master's build gets `No_Capacity` -- it could
only bounce off the handshake anyway.

**Scale-up** (`scale.odin`, `ensure_region_capacity`): reached from a
`Find_Server` miss and from the sweep's floor check. If the region has no
pending spawn, pick an agent with `running + pending < capacity`, mint a
spawn_id, record the pending entry, send `Spawn_Server`. The pending entry
*is* the double-spawn guard while an instance boots; `SPAWN_TIMEOUT_SECONDS`
un-sticks a failed boot. The **floor** keeps `-floor` joinable servers warm
per region that has an agent, so the first player of the day never waits out a
cold boot -- it also means the fleet pre-warms a replacement the moment a
server stops being joinable (a match starting counts).

**Scale-down**: only agent-spawned servers (`spawn_id != 0`) that are
joinable, empty past `-idle-stop`, and above the region's floor get a
`Server_Drain` (resent every sweep until the entry dies via Bye or TTL). A
drain ignored for `3 * ENTRY_TTL_SECONDS` escalates to `Stop_Server` at the
owning agent.

**Port allocation: the agent picks.** The master never invents addresses; it
only hands out what servers themselves advertised via heartbeat, so
`Spawn_Server` carries no port.

## Fleet agent internals (`src/agent/`)

Flags: `-master=H:P` (required), `-token=STR` (required), `-region=STR`
(default `local`), `-capacity=N` (default 2, max 16), `-server-bin=PATH`
(default `./vulkan-server`), `-port-base=N` (default 27100), `-insecure`
(children run UDP-only -- the local dev fleet switch).

Loop at 100 ms: receive commands → reap children → escalate ignored SIGTERMs
→ heartbeat (2 s cadence, immediately on occupancy change).

- **Spawn**: port = `port-base + slot index` (freed slots reuse their port).
  Children are started via `core:os` `process_start` with
  `-port -master -region -server-id -token` (+ `-insecure`), inheriting the
  agent's stdout/stderr (one journal per host) and working directory (where
  `steam_appid.txt` and `libsteam_api.so` live). A duplicated `Spawn_Server`
  datagram answers with the existing child instead of double-spawning.
- **Reap**: `process_wait(child, 0)` polls; an exit frees the slot and forces
  a heartbeat. **No restart-on-crash** -- the master notices the missing
  heartbeats and asks for a fresh spawn within seconds; one respawn brain, not
  two.
- **Stop**: `Stop_Server` → SIGTERM to that child; still alive 5 s later →
  SIGKILL.
- **Agent shutdown**: SIGTERM forwards to all children, waits out the same 5 s
  grace per child, kills stragglers, exits 0. systemd's `KillMode=mixed` +
  `TimeoutStopSec=15` in the unit are built around this.

## Client flow (`src/master_query.odin`)

Flags: `--master=HOST:PORT`, `--region=STR` (empty = any region). Precedence
in `.Connecting` (`scene.odin`): practice → `--connect` (direct SteamID, still
works and wins) → `--master` → dev loopback / `NO SERVER CONFIGURED`.

The query resends `Find_Server` every second until answered `Ok`; `Spawning`
just keeps it retrying (a booting server flips the answer a couple of seconds
later via its first heartbeat). Responses are accepted only from the master's
endpoint with the right nonce. Mapping: `Steam` addr → existing
`net_connect_start_steam`; `Udp` addr → `net_connect_start_ep` (the loopback
hardcoding in `net_open` was generalized to any endpoint). The accepts mask is
Steam-only in `STEAM_REQUIRED` builds, UDP+Steam-if-running in dev.

UX: the connecting screen shows `FINDING SERVER` → `STARTING SERVER` (while
spawning) → `CONNECTING TO SERVER`; failures land on the menu with
`NO SERVER FOUND` (30 s budget), `NO SERVERS AVAILABLE` (no capacity), or
`BAD MASTER ADDRESS`. ESC/CANCEL tears the query down via
`enter_scene(.Menu)` like it tears a connection down.

Headless testing stays flag-driven:
`--no-steam --master=127.0.0.1:27050 --region=local --join=t`.

## Failure modes and self-healing

| Failure | What happens |
|---|---|
| Master crashes (kill -9) | Servers/agents keep running and heartbeating into the void. A restarted master rebuilds the full registry within ~2 s. Clients searching meanwhile retry up to 30 s. |
| Server crashes | Heartbeats stop → entry dropped at 7 s TTL. If that leaves the region under floor, the next sweep spawns a replacement. |
| Server stopped gracefully | 3x `Server_Bye` removes the entry immediately; connected players see `SERVER SHUT DOWN`. |
| Agent crashes | Its entry TTLs out; its children keep running and heartbeating (still joinable). Only stop-escalation for those children is lost until the agent returns. |
| Spawn fails / child boots too slowly | `Spawn_Result{ok=false}` frees the pending slot immediately; otherwise the 20 s pending timeout does. Next demand triggers a fresh spawn. |
| Drain ignored | Resent every sweep; after ~21 s escalated to `Stop_Server` → SIGTERM → SIGKILL. |
| Master handed out a server that filled meanwhile | 10 s reservation makes this rare; the residual race lands on the server's own deny/resync path. |

## Operations

### Local dev loop

```
just master        # vulkan-master on 27050, token "dev", floor 1, idle-stop 60
just agent         # builds vulkan-server-dev, agent with capacity 2, -insecure
just run           # + --no-steam --master=127.0.0.1:27050 --join=t
```

The floor spawn means a joinable server exists a second or two after the
agent registers; the first client gets it instantly, and the fleet pre-warms
the next one the moment a match starts.

### Build targets

`just server-bin` (dev server binary for the agent), `just release-master`,
`just release-agent` (no Steam dependency -- these two binaries never import
steamworks). `just check` covers `src/mm`, `src/master`, `src/agent` and both
`STEAM_REQUIRED` server/client modes; `just test` runs the `mm` roundtrips.

### Deployment (`deploy/`)

`vulkan-master.service` and `vulkan-agent.service` are the systemd sketches.
A master host ships `vulkan-master` alone. A game host ships `vulkan-agent`,
`vulkan-server`, `libsteam_api.so` (next to the server binary, found via its
`$ORIGIN` rpath) and -- dev fleets under AppID 480 only -- `steam_appid.txt`.
The token comes from an `EnvironmentFile`, one shared value across the fleet.
Scaling a region up is cloning the agent host; scaling to a new region is the
same with a different `-region=`.

## Security model and known limitations

- The token authenticates *hosts we operate* to the master over a trusted
  path; it is visible in `ps`/`/proc` on those hosts (a `-token-file=` variant
  is a small follow-up), compared non-constant-time, and datagrams are
  unencrypted. Fine for the current threat model; revisit before untrusted
  parties share infrastructure.
- Client queries can be spoofed toward the *client* only by an off-path
  attacker guessing a 32-bit nonce; release clients additionally only accept
  Steam ids, and the game connection authenticates the server end anyway.
- UDP source-IP advertising is wrong when clients and master sit on different
  sides of a NAT relative to the server; `-advertise=` is the escape hatch.
  The Steam/SDR release path never has this problem.
- Join-while-live race: if a reservation lapses (client took >10 s to connect)
  a second client can hit a running match and gets the current resync
  behavior. First thing the multi-human-match iteration must clean up.
- Registry tables are fixed-size (64/16/16) by design; growth is a constant.

## Verified scenarios

Run locally without Steam (master + agent + `-insecure` fleet), all verified
via logs, 2026-07-29:

1. **Cold start**: agent registers → floor spawns a server → first heartbeat
   clears the pending entry ("server ... up in local").
2. **Join via master**: client `--master ... --join=t` → `MASTER: got server
   127.0.0.1:27100` → normal accept and match start.
3. **Auto-scale-up**: second client while the first plays → lands on a second,
   freshly spawned instance (the floor had already pre-warmed it).
4. **Scale-down**: both clients leave → after `-idle-stop` the surplus server
   gets drained, exits 0, exactly `-floor` servers remain.
5. **Graceful stop with a player on**: SIGTERM → client shows `SERVER SHUT
   DOWN`, server exits 0, master drops the entry on Bye, floor replaces it.
6. **Agent stop**: SIGTERM forwards to children, all exit 0, agent exits 0.
7. **Master is soft state**: kill -9 + restart → registry repopulated from
   heartbeats within 2 s, nothing else restarted.
8. **Steam path** (manual, needs a running Steam client): release server +
   agent without `-insecure`; the heartbeat carries the SteamID after logon
   and the client hands off to the existing `--connect` machinery. Everything
   up to that handoff is proven by 1-7. *Not yet run.*

## Future work

- Cloud provider integration: a second implementation of "run an agent
  somewhere" (boot/destroy hosts via Hetzner/Fly API when regional capacity
  runs low). The agent protocol already is the seam.
- `-token-file=` and constant-time comparison.
- Fleet-wide ban sync: `ban_add` / `ban_list_load` in `banlist.odin` are the
  documented seams; the master is the natural distribution point.
- Server browser / region auto-selection by measured ping (SDR ping locations
  could estimate latency without connecting).
- Multi-human matches, which turn the joinable predicate and the reservation
  into real capacity management.
