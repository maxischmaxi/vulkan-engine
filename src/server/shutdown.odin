package main

import "base:intrinsics"
import "core:log"
import "core:sys/posix"

// Graceful shutdown: SIGTERM/SIGINT set one atomic flag, the tick loop picks
// it up and drains -- kick everyone with .Shutdown, tell the master goodbye,
// keep ticking briefly so the datagrams and Steam close handshakes flush, then
// stop. This is what makes an instance safe to stop from systemd, an agent, or
// a keyboard.

// Ticks between the kick and the exit: enough for the redundant disconnect
// datagrams and the Steam linger to get out.
SHUTDOWN_FLUSH_TICKS :: 32

@(private = "file")
stop_requested: bool

@(private = "file")
shutdown: struct {
	draining: bool, // begin_shutdown ran; the flush deadline is armed
	deadline: u32,
}

signal_install :: proc() {
	act: posix.sigaction_t
	act.sa_handler = proc "c" (sig: posix.Signal) {
		// Async-signal-safe: one atomic store, everything else happens on the
		// tick loop.
		intrinsics.atomic_store(&stop_requested, true)
	}
	posix.sigaction(.SIGTERM, &act, nil)
	posix.sigaction(.SIGINT, &act, nil)
}

// Called at the top of every tick.
shutdown_tick :: proc() {
	if intrinsics.atomic_load(&stop_requested) {
		intrinsics.atomic_store(&stop_requested, false)
		if shutdown.draining {
			// Second signal: the operator means it.
			sv.running = false
			return
		}
		begin_shutdown()
	}
	if shutdown.draining && sv.tick >= shutdown.deadline {
		sv.running = false
	}
}

shutting_down :: proc() -> bool {
	return shutdown.draining
}

begin_shutdown :: proc() {
	if shutdown.draining do return
	shutdown.draining = true
	shutdown.deadline = sv.tick + SHUTDOWN_FLUSH_TICKS
	log.info("Server: shutting down")
	heartbeat_bye()
	for &slot in clients {
		if slot.state == .Empty do continue
		kick_client(&slot, .Shutdown)
	}
}
