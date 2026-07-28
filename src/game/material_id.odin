package game

// Layer indices into the client's texture arrays. Named so the map data reads
// as material intent rather than array offsets. Lives here rather than with
// the material system because the map is authored in it and the map is shared;
// the server just carries the numbers around.
Material_ID :: enum u32 {
	Wall_Main    = 0,
	Wall_Alt     = 1,
	Wall_Trim    = 2,
	Ground       = 3,
	Floor_Indoor = 4,
	Brick        = 5,
	Brick_Alt    = 6,
	Rock         = 7,
	Rock_Alt     = 8,
	Crate        = 9,
	// Decoration markers: the client swaps these brushes for modular meshes
	// (map_decor.odin); until then they render with the fallback rows below.
	Railing      = 10,
	Fence        = 11,
	Pillar       = 12,
}
