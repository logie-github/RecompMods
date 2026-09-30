-- Gen 1 Swift V2
-- Gen 1 only: Red/Blue use Mom + three starters; Yellow uses Mom + Pikachu.

local GameVersion = require("src.core.GameVersion")

return function(mod)
  local version = GameVersion.get()
  local path

  if version == "yellow" then
    path = "variants/yellow.lua"
  elseif version == "red" or version == "blue" then
    path = "variants/redblue.lua"
  else
    -- The manifest restricts this build to Red, Blue, and Yellow.
    return
  end

  local source = mod:read(path)
  if not source then
    error("Gen 1 Swift V2: could not read " .. path .. " from the installed mod", 0)
  end

  local chunk, compileErr = load(source, "@" .. mod.path .. "/" .. path)
  if not chunk then
    error("Gen 1 Swift V2: could not compile " .. path .. ": " .. tostring(compileErr), 0)
  end

  local ok, init = pcall(chunk)
  if not ok then
    error("Gen 1 Swift V2: could not load " .. path .. ": " .. tostring(init), 0)
  end
  if type(init) ~= "function" then
    error("Gen 1 Swift V2: " .. path .. " did not return a mod initializer", 0)
  end

  return init(mod)
end
