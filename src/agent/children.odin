package main

import "../mm"
import "core:fmt"
import "core:log"
import "core:os"
import "core:sys/posix"
import "core:time"

// The children: vulkan-server processes this agent started. Ports are
// port_base + slot index, so a freed slot's port is reusable immediately. No
// restart-on-crash here -- the master notices the missing heartbeats and asks
// for a fresh spawn; one respawn brain, not two.

MAX_CHILDREN :: 16

// A stopped child gets SIGTERM, and this long to act on it before SIGKILL.
STOP_GRACE_SECONDS :: 5.0

Child :: struct {
	active:    bool,
	server_id: u64, // the spawn_id, handed down as -server-id
	port:      u16,
	process:   os.Process,
	term_at:   time.Tick,
	term_sent: bool,
}

children: [MAX_CHILDREN]Child

children_running :: proc() -> int {
	n := 0
	for &c in children {
		if c.active do n += 1
	}
	return n
}

children_spawn :: proc(spawn_id: u64) -> (port: u16, ok: bool) {
	// A duplicated datagram must not double-spawn; answer with what exists.
	for &c in children {
		if c.active && c.server_id == spawn_id do return c.port, true
	}
	if children_running() >= ag.capacity {
		log.warn("Agent: spawn refused, at capacity")
		return 0, false
	}

	slot := -1
	for &c, i in children {
		if !c.active {
			slot = i
			break
		}
	}
	if slot < 0 do return 0, false
	port = u16(ag.port_base + slot)

	cmd: [8]string
	n := 0
	cmd[n] = ag.server_bin; n += 1
	cmd[n] = fmt.tprintf("-port={}", port); n += 1
	cmd[n] = fmt.tprintf("-master={}", ag.master_str); n += 1
	cmd[n] = fmt.tprintf("-region={}", mm.region_string(&ag.region)); n += 1
	cmd[n] = fmt.tprintf("-server-id={}", spawn_id); n += 1
	cmd[n] = fmt.tprintf("-token={}", ag.token_str); n += 1
	if ag.insecure {
		cmd[n] = "-insecure"; n += 1
	}

	// Children inherit our stdout/stderr (one journal per host) and our
	// working directory (where steam_appid.txt and libsteam_api.so live).
	process, err := os.process_start({command = cmd[:n], stdout = os.stdout, stderr = os.stderr})
	if err != nil {
		log.errorf("Agent: cannot start {}: {}", ag.server_bin, err)
		return 0, false
	}

	children[slot] = {
		active    = true,
		server_id = spawn_id,
		port      = port,
		process   = process,
	}
	log.infof("Agent: spawned server pid {} port {} (id {})", process.pid, port, spawn_id)
	return port, true
}

// Polls every child once; true when something exited and the occupancy the
// master knows is stale.
children_reap :: proc() -> bool {
	changed := false
	for &c in children {
		if !c.active do continue
		state, _ := os.process_wait(c.process, 0) // 0 = poll, .Timeout while alive
		if !state.exited do continue
		log.infof("Agent: server {} (port {}) exited {}", c.server_id, c.port, state.exit_code)
		c = {}
		changed = true
	}
	return changed
}

children_stop :: proc(server_id: u64) {
	for &c in children {
		if !c.active || c.server_id != server_id do continue
		if !c.term_sent {
			log.infof("Agent: stopping server {} (pid {})", server_id, c.process.pid)
			posix.kill(posix.pid_t(c.process.pid), .SIGTERM)
			c.term_sent = true
			c.term_at = time.tick_now()
		}
		return
	}
}

// SIGTERM was sent and ignored past the grace: the hammer.
children_escalate :: proc() {
	for &c in children {
		if !c.active || !c.term_sent do continue
		if time.duration_seconds(time.tick_since(c.term_at)) < STOP_GRACE_SECONDS do continue
		log.warnf("Agent: server {} ignored SIGTERM, killing", c.server_id)
		_ = os.process_kill(c.process)
		c.term_sent = false // one kill; the reap collects the corpse
	}
}

// Our own SIGTERM: pass it on, give everyone the grace, then leave. Anything
// still alive after the grace gets killed so systemd never waits on us.
children_shutdown_all :: proc() {
	for &c in children {
		if !c.active do continue
		posix.kill(posix.pid_t(c.process.pid), .SIGTERM)
	}
	deadline := time.Duration(STOP_GRACE_SECONDS * f64(time.Second))
	for &c in children {
		if !c.active do continue
		state, _ := os.process_wait(c.process, deadline)
		if !state.exited {
			log.warnf("Agent: server {} ignored SIGTERM, killing", c.server_id)
			_ = os.process_kill(c.process)
			_, _ = os.process_wait(c.process, time.Second)
		}
		c = {}
	}
}
