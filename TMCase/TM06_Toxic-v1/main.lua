-- TM06 Toxic v1.0
-- Replaces the default rival name presets.

return function(mod)
  local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do
      out[copy(key)] = copy(item)
    end
    return out
  end

  -- field.boot is a deep-registry entry, so patching an array appends to
  -- vanilla. Copy the effective boot config, replace only the rival list,
  -- then override the boot entry so every other boot setting is preserved.
  local boot = copy(mod.content.field:get("boot") or {})
  boot.namePresets = copy(boot.namePresets or {})
  boot.namePresets.rival = { "ASSHAT", "BLUE", "GARY" }

  mod.content.field:override("boot", boot)

  mod.log:info("TM06 Toxic v1.0 active - rival name presets replaced")
end
