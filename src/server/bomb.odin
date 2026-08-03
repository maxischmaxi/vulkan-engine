package main

import "../game"
import "../physics"
import "../protocol"
import "core:log"
import "core:math/rand"

// The bomb's server state machine: who carries it, where it lies, plant and
// defuse progress, the detonation. Driven from comp_tick once per tick; the
// round consequences (phase change, win attribution) stay in comp.odin.
//
// Bots never plant, defuse or pick up in v1 -- a bot-held bomb resolves the
// round by elimination or the clock, by design.

Bomb :: struct {
	state:           game.Bomb_State,
	carrier:         int, // pawn id, -1 for none
	planter:         int,
	defuser:         int, // pawn id currently making progress, -1
	position:        [3]f32, // dropped or planted
	site:            int, // MAP_BOMBSITES index once planted
	plant_progress:  f32, // seconds
	defuse_progress: f32,
}

bomb: Bomb

// Round start: the bomb goes to a random T, humans preferred -- a human can
// actually plant it, a bot only ever carries it to its grave.
bomb_round_reset :: proc() {
	bomb = {
		carrier = -1,
		planter = -1,
		defuser = -1,
		site    = -1,
	}
	if match.mode.id != .Comp do return

	humans: [MAX_CLIENTS]int
	human_count := 0
	bots: [game.MAX_PAWNS]int
	bot_count := 0
	for &p, i in sv.gs.pawns {
		if !p.active || !p.alive || p.team != .T do continue
		if p.is_bot {
			bots[bot_count] = i
			bot_count += 1
		} else {
			humans[human_count] = i
			human_count += 1
		}
	}

	if human_count > 0 {
		bomb.carrier = humans[rand.int_max(human_count, sv.gs.rng)]
	} else if bot_count > 0 {
		bomb.carrier = bots[rand.int_max(bot_count, sv.gs.rng)]
	}
	if bomb.carrier >= 0 {
		bomb.state = .Carried
		log.infof("Server: bomb carried by pawn {}", bomb.carrier)
	}
}

// Once per tick from comp_tick, in .Live and .Bomb.
bomb_tick :: proc() {
	#partial switch match.phase {
	case .Live:
		bomb_tick_carry()
		bomb_tick_plant()
	case .Bomb:
		bomb_tick_defuse()
	}
}

// Drops and pickups. The carrier dying puts the bomb on the ground; an alive
// T human walking over it takes it.
@(private = "file")
bomb_tick_carry :: proc() {
	if bomb.state == .Carried {
		p := &sv.gs.pawns[bomb.carrier]
		if !p.active || !p.alive {
			bomb_drop_at(p.body.position)
		}
		return
	}

	if bomb.state != .Dropped do return
	for &slot in clients {
		if slot.state != .In_Game || slot.team != .T do continue
		p := &sv.gs.pawns[slot.pawn_id]
		if !p.active || !p.alive do continue
		if physics.horizontal_distance(p.body.position, bomb.position) > game.BOMB_PICKUP_RANGE do continue
		if abs(p.body.position.z - bomb.position.z) > 1.5 do continue
		bomb.state = .Carried
		bomb.carrier = slot.pawn_id
		log.infof("Server: bomb picked up by pawn {}", bomb.carrier)
		return
	}
}

// Whether this pawn's hands are on the bomb this tick -- the fire-strip
// condition sim_tick asks before the weapon runs, and exactly the condition
// that accumulates progress below.
bomb_hands_busy :: proc(pawn_id: int, cmd: game.Pawn_Input) -> bool {
	if .Use not_in cmd.buttons do return false
	if match.phase == .Live {
		return bomb_carried_by(pawn_id) && bomb_plant_engaged(pawn_id)
	}
	if match.phase == .Bomb {
		return bomb.state == .Planted && bomb_defuse_engaged(pawn_id)
	}
	return false
}

// Whether this pawn is the one currently carrying the bomb. The hands read it
// to decide whether the bomb may be selected at all, so it lives beside the
// carrier rather than being spelled out at each call site.
bomb_carried_by :: proc(pawn_id: int) -> bool {
	return bomb.state == .Carried && bomb.carrier == pawn_id
}

// Both the fire strip and the progress stepper ask through here, so the rule
// only exists once. What it means to be ready is game.bomb_plant_ready; this
// only supplies the map.
@(private = "file")
bomb_plant_engaged :: proc(pawn_id: int) -> bool {
	return game.bomb_plant_ready(sv.gs.pawns[pawn_id], game.MAP_BOMBSITES)
}

@(private = "file")
bomb_defuse_engaged :: proc(pawn_id: int) -> bool {
	p := &sv.gs.pawns[pawn_id]
	if !p.active || !p.alive || p.team != .CT || !p.body.on_ground do return false
	if physics.horizontal_distance(p.body.position, bomb.position) > game.BOMB_DEFUSE_RANGE do return false
	return abs(p.body.position.z - bomb.position.z) < 2
}

// Planting: a human carrier holding Use on a site. Bots hold the bomb but
// never the button.
@(private = "file")
bomb_tick_plant :: proc() {
	if bomb.state != .Carried do return
	slot := find_slot_by_pawn(bomb.carrier)
	if slot == nil {
		bomb.plant_progress = 0
		return
	}

	engaged :=
		.Use in slot.last_cmd.buttons &&
		bomb_plant_engaged(bomb.carrier)
	done: bool
	bomb.plant_progress, done = game.bomb_plant_step(bomb.plant_progress, engaged, game.TICK_DT)
	if !done do return

	p := &sv.gs.pawns[bomb.carrier]
	position := p.body.position
	if z, found := physics.grid_ground_below(&sv.gs.grid, position + {0, 0, 0.5}, 4); found {
		position.z = z
	}
	bomb.state = .Planted
	bomb.position = position
	bomb.site = game.bomb_site_at(game.MAP_BOMBSITES, position)
	bomb.planter = bomb.carrier
	bomb.carrier = -1
	bomb.defuse_progress = 0
	comp.planted_this_round = true
	award(slot, game.ECON_PLANT_BONUS)

	site_tag := bomb.site >= 0 ? rune(game.MAP_BOMBSITES[bomb.site].tag) : '?'
	log.infof("Server: bomb planted at site {} by pawn {}", site_tag, bomb.planter)
	set_phase(.Bomb, sv.tick + u32(comp_fuse_s() * game.TICK_RATE))
}

// How long the pawn currently on the wire needs. Read by the stepper and by
// the snapshot's progress fraction, so the bar always spans the time this
// defuser actually needs rather than a constant the kit made wrong.
@(private = "file")
bomb_defuse_time_for :: proc(pawn_id: int) -> f32 {
	if pawn_id < 0 || pawn_id >= game.MAX_PAWNS do return game.BOMB_DEFUSE_TIME
	return game.bomb_defuse_time(sv.gs.pawns[pawn_id].loadout.defuse_kit)
}

// Defusing: any alive CT human in range holding Use. Switching defusers or
// letting go resets the wire.
@(private = "file")
bomb_tick_defuse :: proc() {
	if bomb.state != .Planted do return

	active := -1
	for &slot in clients {
		if slot.state != .In_Game || slot.team != .CT do continue
		if .Use not_in slot.last_cmd.buttons do continue
		if !bomb_defuse_engaged(slot.pawn_id) do continue
		active = slot.pawn_id
		break
	}

	if active != bomb.defuser {
		bomb.defuser = active
		bomb.defuse_progress = 0
	}
	if active < 0 do return

	done: bool
	bomb.defuse_progress, done = game.bomb_defuse_step(
		bomb.defuse_progress,
		true,
		game.TICK_DT,
		bomb_defuse_time_for(bomb.defuser),
	)
	if !done do return

	bomb.state = .Defused
	if slot := find_slot_by_pawn(bomb.defuser); slot != nil {
		award(slot, game.ECON_DEFUSE_BONUS)
	}
	log.infof(
		"Server: bomb defused by pawn {} ({})",
		bomb.defuser,
		sv.gs.pawns[bomb.defuser].loadout.defuse_kit ? "with kit" : "no kit",
	)
	comp_round_end(.CT, .Bomb_Defused)
}

// The fuse burned down: detonation damage around the plant spot, kills
// attributed to the world.
bomb_explode :: proc() {
	if bomb.state != .Planted do return
	bomb.state = .Exploded
	log.info("Server: bomb exploded")
	// The same blast the HE gets. A round ending in a silent, invisible
	// explosion is worse than one ending in no explosion at all.
	queue_event(.He_Blast, -1, bomb.position, game.BLAST_EVENT_RANGE)
	for &p, i in sv.gs.pawns {
		if !p.active || !p.alive do continue
		delta := p.body.position - bomb.position
		dist := physics.horizontal_distance(p.body.position, bomb.position) + abs(delta.z) * 0.5
		damage := game.bomb_explosion_damage(dist)
		if damage <= 0 do continue
		queue_damage(bomb.position, i, damage)
		if game.damage_pawn(&p, damage, game.BOMB_ARMOR_PEN) {
			on_pawn_killed(-1, i)
		}
	}
}

// A pawn is about to be removed (disconnect): the bomb must not vanish.
bomb_pawn_removed :: proc(pawn_id: int) {
	if bomb.state == .Carried && bomb.carrier == pawn_id {
		bomb_drop_at(sv.gs.pawns[pawn_id].body.position)
	}
	if bomb.defuser == pawn_id {
		bomb.defuser = -1
		bomb.defuse_progress = 0
	}
}

@(private = "file")
bomb_drop_at :: proc(position: [3]f32) {
	dropped := position
	if z, found := physics.grid_ground_below(&sv.gs.grid, position + {0, 0, 0.5}, 6); found {
		dropped.z = z
	}
	bomb.state = .Dropped
	bomb.position = dropped
	bomb.carrier = -1
	bomb.plant_progress = 0
	log.infof("Server: bomb dropped at {}", dropped)
}

// The snapshot block. Progress is whichever wire is currently live: the
// plant while carried, the defuse while planted.
fill_bomb_snapshot :: proc(snap: ^protocol.Snapshot) {
	if match.mode.id != .Comp do return

	snap.bomb_state = bomb.state
	snap.bomb_carrier = bomb.carrier >= 0 ? u8(bomb.carrier) : game.BOMB_NO_PAWN
	snap.bomb_defuser = bomb.defuser >= 0 ? u8(bomb.defuser) : game.BOMB_NO_PAWN
	snap.bomb_position = bomb.position

	progress: f32 = 0
	if bomb.state == .Carried && bomb.plant_progress > 0 {
		progress = bomb.plant_progress / game.BOMB_PLANT_TIME
	}
	if bomb.state == .Planted && bomb.defuser >= 0 {
		progress = bomb.defuse_progress / bomb_defuse_time_for(bomb.defuser)
	}
	snap.bomb_progress = u8(clamp(progress * 255, 0, 255))
}
