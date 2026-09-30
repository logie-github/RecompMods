-- TM32 Double Team
-- Doubles Bill's PC from 12 boxes to 24 and makes CHANGE BOX scroll.
--
-- Also introduces itself in the save, so a tool outside the game can tell a
-- 24-box save from a broken one. Gen1Recomp has no way for a mod to announce
-- itself to anything but the running game, so the announcement goes somewhere
-- both sides can already reach: save.meta.mods, which travels with the save.

local MOD_ID = "tm32_double_team"
local MOD_NAME = "TM32 Double Team"
local MOD_VERSION = "1.0"

local TARGET_BOX_COUNT = 24
local VISIBLE_BOX_ROWS = 12

-- Boxes are still twenty deep. Said out loud rather than left to be assumed,
-- because a reader that has to guess will guess wrong for the next mod.
local BOX_CAPACITY = 20

-- Where the storage app leaves its own card, if it has been here. Read only:
-- this mod never writes it, and never requires it to be there.
local COMPANION_KEY = "storageSystem"

--- Writes this mod's card into the save.
--
-- Additive and idempotent: it touches one key inside save.meta.mods, which is
-- the table Gen1Recomp already keeps for exactly this, and leaves every other
-- mod's entry alone. Rewritten each time rather than written once, so the
-- numbers can never drift from what the mod is actually doing.
local function declare(save)
  if type(save) ~= "table" then return end
  if type(save.meta) ~= "table" then save.meta = {} end
  if type(save.meta.mods) ~= "table" then save.meta.mods = {} end

  -- A list of plain ids is also a legal shape for this table. If that is what
  -- is here, leave it be and add nothing rather than turning it into a map
  -- under another mod's feet.
  if save.meta.mods[1] ~= nil then return end

  save.meta.mods[MOD_ID] = {
    name = MOD_NAME,
    version = MOD_VERSION,
    boxCount = TARGET_BOX_COUNT,
    boxCapacity = BOX_CAPACITY,
  }
end

--- What the storage app has left in the save, or nil if it has not been here.
--
-- Nothing in this mod depends on it. It is read so the pairing is two-way and
-- so a save can be looked at and its history told.
local function companion(save)
  if type(save) ~= "table" or type(save.meta) ~= "table" then return nil end
  local card = save.meta[COMPANION_KEY]
  if type(card) == "table" then return card end
  return nil
end

return function(mod)
  local boxesOk, Boxes = pcall(require, "src.pokemon.Boxes")
  local menuOk, Menu = pcall(require, "src.ui.Menu")
  local stackOk, StateStack = pcall(require, "src.core.StateStack")
  local fontOk, Font = pcall(require, "src.render.Font")
  local textBoxOk, TextBox = pcall(require, "src.render.TextBox")
  local stringsOk, Strings = pcall(require, "src.core.Strings")

  if not boxesOk or type(Boxes) ~= "table" then return end

  -- Core storage count. All stock Gen 1 box/deposit code reads this table.
  Boxes.COUNT = TARGET_BOX_COUNT

  -- Expand existing saves that already have only the original 12 boxes.
  -- The stock ensure() only creates boxes when save.boxes is nil, so it does
  -- not add new slots to an already-existing save on its own.
  if type(Boxes.ensure) == "function" and not Boxes._tm32DoubleTeamEnsureV12 then
    local previousEnsure = Boxes.ensure
    Boxes._tm32DoubleTeamEnsureV12 = previousEnsure

    function Boxes.ensure(save)
      local boxes = previousEnsure(save)
      if type(boxes) ~= "table" then
        save.boxes = type(save.boxes) == "table" and save.boxes or {}
        boxes = save.boxes
      end
      for i = 1, TARGET_BOX_COUNT do
        if type(boxes[i]) ~= "table" then boxes[i] = {} end
      end
      save.currentBox = math.max(1,
        math.min(TARGET_BOX_COUNT, tonumber(save.currentBox) or 1))
      -- Written in the same breath as the boxes themselves, so the card in
      -- the save can never describe a shape the save does not have.
      declare(save)
      return boxes
    end
  end

  -- For anything else in the load order that wants to know what this mod did
  -- without having to infer it from the save.
  mod.boxCount = TARGET_BOX_COUNT
  mod.boxCapacity = BOX_CAPACITY
  mod.readCompanion = companion

  if not (menuOk and stackOk and fontOk and textBoxOk and stringsOk) then
    return
  end
  if type(Menu) ~= "table" or type(Menu.new) ~= "function"
      or type(Menu.draw) ~= "function" then return end
  if type(StateStack) ~= "table" or type(StateStack.push) ~= "function" then
    return
  end

  -- Fix the actual source of the overflow: BoxMenu creates CHANGE BOX with
  -- 24 items but still gives Menu the original 14-tile-tall window. Make
  -- Menu.new enable its built-in scrolling before BoxMenu captures Menu.draw.
  -- This is deliberately based on the stock CHANGE BOX geometry rather than
  -- an event, so it works even on builds where screen.pushed payloads differ.
  if not Menu._tm32DoubleTeamNewV12 then
    local previousMenuNew = Menu.new
    Menu._tm32DoubleTeamNewV12 = previousMenuNew

    function Menu.new(game, items, opts)
      if type(items) == "table" and #items == TARGET_BOX_COUNT
          and type(opts) == "table"
          and opts.tx == 11 and opts.ty == 0
          and opts.tw == 9 and opts.th == 14
          and opts.rowStep == 1 and opts.itemY == 1 then
        opts.maxVisible = VISIBLE_BOX_ROWS
      end
      return previousMenuNew(game, items, opts)
    end
  end

  local ballTile
  local function drawBallTile(tx, ty)
    if ballTile == nil then
      local ok, img = pcall(love.graphics.newImage,
        "assets/generated/battle/balls.png")
      ballTile = ok and {
        img = img,
        quad = love.graphics.newQuad(0, 0, 8, 8, img:getDimensions()),
      } or false
    end
    if not ballTile then return end
    local r, g, b, a = love.graphics.getColor()
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(ballTile.img, ballTile.quad, tx * 8, ty * 8)
    love.graphics.setColor(r, g, b, a)
  end

  local function isChangeBoxMenu(state)
    return type(state) == "table"
      and state.kind == "pc_box_change"
      and type(state.items) == "table"
      and #state.items == TARGET_BOX_COUNT
      and state.tx == 11 and state.ty == 0
      and state.tw == 9 and state.th == 14
      and state.rowStep == 1 and state.itemY == 1
  end

  local function patchChangeBoxMenu(state)
    if state._tm32DoubleTeamScrollableV12 then return end
    state._tm32DoubleTeamScrollableV12 = true
    state.maxVisible = VISIBLE_BOX_ROWS
    state.scroll = tonumber(state.scroll) or 0
    if type(state.clampScroll) == "function" then state:clampScroll() end

    -- BoxMenu's stock draw wrapper draws occupancy balls at absolute rows
    -- 1..24. Replace that wrapper so both text and balls use the same scroll
    -- offset. Menu.draw handles cursor movement and the visible item window.
    function state:draw()
      local game = self.game
      local boxes = Boxes.ensure(game.save)
      local t = game.data and game.data.text or {}

      -- Stock "Choose a POKEMON BOX" prompt.
      Font.drawBox(0, 12, 20, 6)
      love.graphics.setColor(0, 0, 0, 1)
      local y = 112
      local prompt = TextBox.strip(t._ChooseABoxText
        or Strings("Choose a\n<PK><MN> BOX."))
      for line in (prompt .. "\n"):gmatch("([^\n]*)\n") do
        Font.draw(line, 8, y)
        y = y + 16
      end

      -- Stock current-box panel.
      Font.drawBox(0, 0, 11, 4)
      love.graphics.setColor(0, 0, 0, 1)
      Font.draw(Strings("BOX No."), 8, 16)
      local n = game.save.currentBox or 1
      Font.draw(tostring(n), n >= 10 and 64 or 72, 16)

      -- Native Menu scrolling: only 12 rows are drawn. As index advances
      -- past row 12, self.scroll advances and the list moves upward.
      Menu.draw(self)

      -- Occupancy Pokeballs follow the same viewport instead of drawing at
      -- absolute rows 13..24 below the screen.
      love.graphics.setColor(0, 0, 0, 1)
      local scroll = self.scroll or 0
      local first = scroll + 1
      local last = math.min(scroll + VISIBLE_BOX_ROWS, TARGET_BOX_COUNT)
      for boxIndex = first, last do
        if boxes[boxIndex] and #boxes[boxIndex] > 0 then
          drawBallTile(18, boxIndex - scroll)
        end
      end
      love.graphics.setColor(1, 1, 1, 1)
    end
  end

  -- Patch the completed menu object directly at StateStack:push(). BoxMenu
  -- installs its own draw wrapper immediately before this call, so this point
  -- is late enough that our replacement cannot be overwritten afterward.
  if not StateStack._tm32DoubleTeamPushV12 then
    local previousPush = StateStack.push
    StateStack._tm32DoubleTeamPushV12 = previousPush

    function StateStack:push(state, ...)
      if isChangeBoxMenu(state) then patchChangeBoxMenu(state) end
      return previousPush(self, state, ...)
    end
  end
end
