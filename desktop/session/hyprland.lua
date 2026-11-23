-- Use the compositor defaults that Vitreus's installer starts from.
dofile("/usr/share/hypr/hyprland.lua")
hl.env("PATH", os.getenv("HOME") .. "/.local/bin:" .. os.getenv("PATH"))

-- The terminal shipped with the image uses Vitreus's Ghostty settings.
hl.unbind("SUPER + Q")
hl.bind("SUPER + Q", hl.dsp.exec_cmd("ghostty"))

-- The upstream module starts pleamar --autostart and owns the Vitreus keys.
require("hypr_vitreus")
pcall(require, "vitreus_monitors")
pcall(require, "vitreus_hypr")
pcall(require, "vitreus_colors")
