package main

import "../mm"
import "base:intrinsics"
import "core:log"
import "core:math/rand"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

// The fleet agent: one per game-server host. It registers its region and
// capacity with the master, spawns vulkan-server children when asked, reaps
// them when they exit, and forwards its own SIGTERM to them on the way out.
// Scaling a region up means booting a machine that runs this; the master
// learns everything else from the heartbeats.

Agent :: struct {
	socket:     net.UDP_Socket,
	master_str: string,
	master_ep:  net.Endpoint,
	token:      mm.Token,
	token_str:  string, // the raw flag, passed through to the children
	region:     mm.Region,
	agent_id:   u64,
	capacity:   int,
	server_bin: string,
	port_base:  int,
	insecure:   bool, // children run -insecure: the local no-Steam fleet
	last_hb:    time.Tick,
}

ag: Agent

// The loop turns at this pace; nothing here is latency-critical.
AGENT_SLEEP :: 100 * time.Millisecond

@(private = "file")
stop_requested: bool

main :: proc() {
	context.logger = log.create_console_logger()

	ag.capacity = 2
	ag.server_bin = "./vulkan-server"
	ag.port_base = 27100
	have_token := false

	for arg in os.args[1:] {
		switch {
		case strings.has_prefix(arg, "-master="):
			ag.master_str = arg[len("-master="):]

		case strings.has_prefix(arg, "-token="):
			ag.token_str = arg[len("-token="):]
			ag.token = mm.token_from_string(ag.token_str)
			have_token = true

		case strings.has_prefix(arg, "-region="):
			ag.region = mm.region_from_string(arg[len("-region="):])

		case strings.has_prefix(arg, "-capacity="):
			value, ok := strconv.parse_int(arg[len("-capacity="):])
			if !ok || value <= 0 || value > MAX_CHILDREN {
				log.errorf("-capacity wants 1..{}, got {}", MAX_CHILDREN, arg)
				os.exit(1)
			}
			ag.capacity = value

		case strings.has_prefix(arg, "-server-bin="):
			ag.server_bin = arg[len("-server-bin="):]

		case strings.has_prefix(arg, "-port-base="):
			value, ok := strconv.parse_int(arg[len("-port-base="):])
			if !ok || value <= 0 || value > 65535 - MAX_CHILDREN {
				log.errorf("-port-base wants a port number, got {}", arg)
				os.exit(1)
			}
			ag.port_base = value

		case arg == "-insecure":
			ag.insecure = true

		case arg == "-help" || arg == "--help":
			log.info(
				"Options:\n" +
				"  -master=H:P     the master to register with (required)\n" +
				"  -token=STR      shared secret for master traffic (required)\n" +
				"  -region=STR     region this host serves (default local)\n" +
				"  -capacity=N     game servers this host may run (default 2)\n" +
				"  -server-bin=P   the vulkan-server binary (default ./vulkan-server)\n" +
				"  -port-base=N    children listen on N, N+1, ... (default 27100)\n" +
				"  -insecure       children run UDP-only, no Steam (dev fleets)",
			)
			os.exit(0)

		case:
			log.warnf("Ignoring unknown option {}", arg)
		}
	}

	if ag.master_str == "" || !have_token {
		log.error("-master and -token are required")
		os.exit(1)
	}
	if ag.region.len == 0 do ag.region = mm.region_from_string("local")

	ep, ok := net.parse_endpoint(ag.master_str)
	if !ok {
		resolved, err := net.resolve_ip4(ag.master_str)
		if err != nil {
			log.errorf("Agent: cannot resolve -master={}: {}", ag.master_str, err)
			os.exit(1)
		}
		ep = resolved
	}
	if ep.port == 0 do ep.port = mm.MM_DEFAULT_PORT
	ag.master_ep = ep

	socket, serr := net.make_bound_udp_socket(net.IP4_Any, 0)
	if serr != nil {
		log.errorf("Agent: cannot open a socket: {}", serr)
		os.exit(1)
	}
	ag.socket = socket
	if berr := net.set_blocking(ag.socket, false); berr != nil {
		log.errorf("Agent: cannot make the socket non-blocking: {}", berr)
		os.exit(1)
	}

	ag.agent_id = rand.uint64()

	act: posix.sigaction_t
	act.sa_handler = proc "c" (sig: posix.Signal) {
		intrinsics.atomic_store(&stop_requested, true)
	}
	posix.sigaction(.SIGTERM, &act, nil)
	posix.sigaction(.SIGINT, &act, nil)

	log.infof(
		"Agent: id {} region {} capacity {}, serving {} to {}",
		ag.agent_id,
		mm.region_string(&ag.region),
		ag.capacity,
		ag.server_bin,
		net.to_string(ag.master_ep),
	)

	buf: [mm.MM_MAX_DATAGRAM]u8
	for {
		if intrinsics.atomic_load(&stop_requested) {
			log.info("Agent: shutting down, stopping the children")
			children_shutdown_all()
			os.exit(0)
		}

		for {
			n, from, rerr := net.recv_udp(ag.socket, buf[:])
			if rerr == .Would_Block do break
			if rerr != nil {
				log.warnf("Agent: recv error {}", rerr)
				break
			}
			if from != ag.master_ep do continue
			handle_master(buf[:n])
		}

		if children_reap() {
			agent_heartbeat(true) // occupancy changed; tell the master now
		}
		children_escalate()
		agent_heartbeat(false)

		free_all(context.temp_allocator)
		time.sleep(AGENT_SLEEP)
	}
}

@(private = "file")
handle_master :: proc(data: []u8) {
	r, msg, ok := mm.frame_open(data)
	if !ok do return

	#partial switch msg {
	case .Spawn_Server:
		if m, mok := mm.read_spawn_server(&r); mok && m.token == ag.token {
			port, sok := children_spawn(m.spawn_id)
			result := mm.Spawn_Result {
				token    = ag.token,
				spawn_id = m.spawn_id,
				ok       = sok,
				port     = port,
			}
			out: [mm.MM_MAX_DATAGRAM]u8
			w := mm.writer(out[:])
			mm.frame_begin(&w, .Spawn_Result)
			mm.write_spawn_result(&w, result)
			agent_send(out[:w.off])
			agent_heartbeat(true)
		}

	case .Stop_Server:
		if m, mok := mm.read_stop_server(&r); mok && m.token == ag.token {
			children_stop(m.server_id)
		}
	}
}

agent_send :: proc(data: []u8) {
	if _, err := net.send_udp(ag.socket, data, ag.master_ep); err != nil {
		log.warnf("Agent: send error {}", err)
	}
}
