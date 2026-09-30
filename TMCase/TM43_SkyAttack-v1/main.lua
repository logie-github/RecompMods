-- TM43 Sky Attack: device-top dialogue positioning.
--   dialogue                  -> literal device/window top
--   attached YES/NO choices   -> directly below dialogue
--   UI scale                  -> preserved
--   horizontal centering      -> preserved
--
-- Built on the documented render.hud hook. Vanilla dialogue and attached
-- choices are suppressed during the normal playfield draw, then redrawn in
-- window space at LOVE y=0 so portrait and landscape layouts use the actual
-- top edge rather than the Game Boy playfield/viewport top.

return function(mod)
  local Renderer = require("src.render.Renderer")
  local TextBox = require("src.render.TextBox")
  local ChoiceBox = require("src.ui.ChoiceBox")

  -- Put dialogue geometry at y=0 in its own 160x144 coordinate system. The
  -- render.hud hook below maps that coordinate system to the actual device /
  -- window top instead of the Game Boy playfield top.
  mod.content.field:patch("theme", {
    textBox = { tx = 0, ty = 0, tw = 20, th = 6, maxCols = 18 },
  })

  local oldSetUIAnchor = Renderer.setUIAnchor
  if not Renderer._tm43sa20Anchor then
    Renderer._tm43sa20Anchor = true
    function Renderer:setUIAnchor(...)
      -- HUD-redrawn dialogue is already positioned in literal window space,
      -- so do not register another playfield-relative anchor during redraw.
      if self._tm43sa20HudPass then return end
      return oldSetUIAnchor(self, ...)
    end
  end

  local oldTextDraw = TextBox.draw
  if not TextBox._tm43sa20TextDraw then
    TextBox._tm43sa20TextDraw = true
    function TextBox:draw(...)
      local r = self.game and self.game.renderer
      if r and not r._tm43sa20HudPass then
        -- Remember that vanilla wanted this state drawn, suppress the normal
        -- playfield draw, and let render.hud redraw it at the device top.
        self._tm43sa20Hud = true
        return
      end
      return oldTextDraw(self, ...)
    end
  end

  local oldChoiceNew = ChoiceBox.new
  if not ChoiceBox._tm43sa20ChoiceNew then
    ChoiceBox._tm43sa20ChoiceNew = true
    function ChoiceBox.new(game, onChoose, opts)
      if opts and opts.anchor == "bottom" then
        local o = {}
        for k, v in pairs(opts) do o[k] = v end

        -- Attached YES/NO choices follow directly below the six-tile-high
        -- dialogue box in the HUD coordinate system.
        o.ty = 6

        local box = oldChoiceNew(game, onChoose, o)
        box._tm43sa20Attached = true
        return box
      end
      return oldChoiceNew(game, onChoose, opts)
    end
  end

  local oldChoiceDraw = ChoiceBox.draw
  if not ChoiceBox._tm43sa20ChoiceDraw then
    ChoiceBox._tm43sa20ChoiceDraw = true
    function ChoiceBox:draw(...)
      local r = self.game and self.game.renderer
      if self._tm43sa20Attached and r and not r._tm43sa20HudPass then
        self._tm43sa20Hud = true
        return
      end
      return oldChoiceDraw(self, ...)
    end
  end

  mod.hooks:wrap("render.hud", function(next, game, viewport)
    next(game, viewport)

    local r = game and game.renderer
    local stack = game and game.stack and game.stack.states
    if not (r and stack) then return end

    -- frameRects supplies the current UI scale and horizontal centering in
    -- LOVE window units. Deliberately avoid viewY/gameY/playfield Y: y=0 is
    -- the literal top edge of the device/window.
    local fr = r.frameRects and r:frameRects() or nil
    local sx, sy, x0
    if fr then
      sx, sy, x0 = fr.Ux, fr.Uy, fr.uox
    else
      local dpiX = (viewport and viewport.dpiX) or 1
      local dpiY = (viewport and viewport.dpiY) or 1
      local scale = (viewport and viewport.scale) or 1
      sx, sy = scale / dpiX, scale / dpiY
      x0 = (viewport and viewport.gameX) or 0
    end

    love.graphics.push("all")
    love.graphics.origin()
    love.graphics.translate(x0, 0)
    love.graphics.scale(sx, sy)

    r._tm43sa20HudPass = true
    for i = 1, #stack do
      local state = stack[i]
      if state and state._tm43sa20Hud then
        state._tm43sa20Hud = nil
        state:draw()
      end
    end
    r._tm43sa20HudPass = nil

    love.graphics.pop()
  end, 100)

  mod.log:info("TM43 Sky Attack v2.0 active - dialogue pinned to literal device top")
end
