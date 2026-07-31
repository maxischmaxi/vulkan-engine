package main

import "core:math"

// The one palette. Authored as sRGB hex (in the comments), stored linear
// because the swapchain is B8G8R8A8_SRGB and the shaders write linear values.
// Regenerate literals with the sRGB EOTF when changing a color; eyeballing
// linear numbers produces washed-out tints.

UI_BG :: [4]f32{0.0048, 0.0097, 0.0168, 1} // #0F1923
UI_PANEL :: [4]f32{0.0080, 0.0144, 0.0242, 0.92} // #16202B
UI_PANEL_RAISED :: [4]f32{0.0137, 0.0252, 0.0395, 0.96} // #1F2C38
UI_STROKE :: [4]f32{0.0742, 0.0999, 0.1329, 1} // #4D5966
UI_TEXT :: [4]f32{0.8388, 0.8070, 0.7529, 1} // #ECE8E1
UI_TEXT_DIM :: [4]f32{0.4910, 0.4735, 0.4342, 1} // #BAB7B0
UI_TEXT_FAINT :: [4]f32{0.2542, 0.2789, 0.3185, 1} // #8A9099
UI_ACCENT :: [4]f32{1.0000, 0.0612, 0.0908, 1} // #FF4655
UI_GOOD :: [4]f32{0.0999, 0.6939, 0.2623, 1} // #59D98C
UI_WARN :: [4]f32{0.8714, 0.4508, 0.0452, 1} // #F0B33C
UI_BAD :: UI_ACCENT // danger and signature red are the same statement
UI_T_COLOR :: [4]f32{0.8070, 0.3663, 0.0467, 1} // #E8A33D attackers, warm
UI_CT_COLOR :: [4]f32{0.0782, 0.3916, 0.8070, 1} // #4FA8E8 defenders, cool

// The damage vignette, fed to damage.frag via push constants so the palette
// reaches the one HUD element that lives in GLSL.
UI_DAMAGE_EDGE :: [4]f32{0.30, 0.005, 0.012, 0} // deep red, the quiet ring
UI_DAMAGE_CORE :: [4]f32{1.0, 0.0612, 0.0908, 0} // the accent, hot inside a lobe

// Full-screen dims. Three strengths, so overlays stop inventing their own.
UI_SCRIM_LIGHT :: [4]f32{0.0048, 0.0097, 0.0168, 0.45}
UI_SCRIM_MED :: [4]f32{0.0048, 0.0097, 0.0168, 0.60}
UI_SCRIM_HEAVY :: [4]f32{0.0048, 0.0097, 0.0168, 0.80}

// Type scale in reference pixels against a 1080-tall screen, like all layout.
UI_DISPLAY :: f32(96) // menu title, VICTORY / DEFEAT
UI_H1 :: f32(56) // banners, big scores
UI_H2 :: f32(36) // timers, health, ammo
UI_BODY :: f32(22) // buttons, rows, names
UI_LABEL :: f32(15) // uppercase micro-labels, letter-spaced
UI_MICRO :: f32(12) // key hints, footers

UI_RADIUS :: f32(2)
UI_STROKE_W :: f32(1)
UI_PAD :: f32(12)
UI_GAP :: f32(8)

// Aliases keeping the old names alive while screens migrate to the roles
// above. New code names the role; a redesign pass retires these per file.
HUD_WHITE :: UI_TEXT
HUD_DIM :: UI_TEXT_DIM
HUD_FAINT :: UI_TEXT_FAINT
HUD_GOOD :: UI_GOOD
HUD_WARN :: UI_WARN
HUD_BAD :: UI_BAD
HUD_PANEL :: UI_PANEL
MENU_DIM :: UI_SCRIM_MED
MENU_HOVER_BG :: UI_PANEL_RAISED
MENU_T_COLOR :: UI_T_COLOR
MENU_CT_COLOR :: UI_CT_COLOR

// For colors that only exist at runtime (user crosshair presets and the like).
srgb_hex :: proc(hex: u32, alpha: f32 = 1) -> [4]f32 {
	lin :: proc(c8: u32) -> f32 {
		c := f32(c8) / 255
		return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4)
	}
	return {lin(hex >> 16 & 0xFF), lin(hex >> 8 & 0xFF), lin(hex & 0xFF), alpha}
}
