#!/bin/bash
# Omarchy (and other Hyprland setups): make the iPhone window float, phone-shaped, instead of
# being tiled and stretched across half the screen.
#
#   tools/omarchy-window.sh            install the rule (asks before editing hyprland.lua)
#   tools/omarchy-window.sh --remove   take it out again
#
# The window is reims-vgpu's SDL window: Wayland app id "reims-vgpu", title "vphone-linux"
# (run-vphone.sh's REIMS_VGPU_WINDOW_TITLE). The rule floats it, centred, 85% of the monitor's
# height tall at the iPhone's 1290:2796 aspect ratio, kept when resized; fully opaque, and it
# keeps the host awake while focused. Omarchy configures Hyprland in Lua
# (~/.config/hypr/hyprland.lua requires user modules), so the rule is a module of its own,
# ~/.config/hypr/vphone-linux.lua, required from hyprland.lua.
set -euo pipefail
HYPR=${XDG_CONFIG_HOME:-$HOME/.config}/hypr
MOD=$HYPR/vphone-linux.lua
MAIN=$HYPR/hyprland.lua
REQ='require("hypr.vphone-linux")'

reload() {
  command -v hyprctl >/dev/null && [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || return 0
  hyprctl reload >/dev/null
  local errs; errs=$(hyprctl configerrors 2>/dev/null || true)
  if [ -n "$errs" ] && ! printf '%s' "$errs" | grep -qi 'no errors'; then
    echo "Hyprland reports config errors:"; printf '%s\n' "$errs"; return 1
  fi
}

if [ "${1:-}" = --remove ]; then
  rm -f "$MOD"
  [ -f "$MAIN" ] && sed -i "\|^$REQ\$|d" "$MAIN"
  reload; echo "removed the vphone-linux window rule"; exit 0
fi

[ -d "$HYPR" ] || { echo "no Hyprland config at $HYPR: nothing to do"; exit 0; }

if [ -f "$MAIN" ]; then
  cat > "$MOD" <<'EOF'
-- vphone-linux: the iPhone window (reims-vgpu's SDL window) floats, phone-shaped.
-- Written by vphone-linux/tools/omarchy-window.sh; remove with its --remove.
local rule = {
  float = true,
  center = true,
  size = { "(monitor_h*0.85*1290/2796)", "(monitor_h*0.85)" },
  keep_aspect_ratio = true,
  opacity = "1 1",
  idle_inhibit = "focus",
}
if o and o.window then
  rule.tag = "-default-opacity"
  o.window("^reims-vgpu$", rule)
else
  rule.match = { class = "^reims-vgpu$" }
  hl.window_rule(rule)
end
EOF
  if ! grep -qxF "$REQ" "$MAIN"; then
    read -rp "Add '$REQ' to $MAIN? [Y/n] " a
    case ${a:-y} in y|Y) cp "$MAIN" "$MAIN.bak.$(date +%s)"; printf '\n%s\n' "$REQ" >> "$MAIN" ;;
      *) echo "skipped: add '$REQ' to $MAIN yourself"; exit 0 ;; esac
  fi
else
  echo "no hyprland.lua in $HYPR (Omarchy configures Hyprland in Lua): float the window class reims-vgpu yourself"; exit 0
fi
reload
echo "installed: the vphone-linux window now floats phone-shaped (start it with GFX=1 WINDOW=1 ./run-vphone.sh <vm>)"
