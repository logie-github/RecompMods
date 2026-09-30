-- TM39 Swift
-- Replaces Professor Oak's Red/Blue new-game speech with a Mom-led opening.

local Assets = require("src.render.Assets")
local AnimPlayer = require("src.battle.AnimPlayer")
local Bag = require("src.inventory.Bag")
local Collision = require("src.world.Collision")
local Commands = require("src.script.Commands")
local Font = require("src.render.Font")
local Music = require("src.core.Music")
local NamingScreen = require("src.ui.NamingScreen")
local PaletteFX = require("src.render.PaletteFX")
local Screens = require("src.ui.Screens")
local Sound = require("src.core.Sound")
local Sprites = require("src.pokemon.Sprites")
local Strings = require("src.core.Strings")
local TextBox = require("src.render.TextBox")
local Transition = require("src.render.Transition")

local STARTER_ORDER = { "BULBASAUR", "CHARMANDER", "SQUIRTLE" }
local STARTER_CENTERS = { 29, 80, 131 }
local STARTER_SCALE = 1.5
local STARTER_BASELINE = 112
-- Use only the pull-in half of the battle capture sequence. The two
-- unchosen POKEMON poof away, hide, and are immediately replaced by closed
-- POKE BALLS. There is no throw arc and no ball-rocking sequence.
local STARTER_CAPTURE_STAGES = {
  { anim = "POOF_ANIM" },
  { anim = "HIDEPIC_ANIM", hide = true },
}
local STARTER_FLAGS = {
  BULBASAUR = "EVENT_CHOSE_BULBASAUR",
  CHARMANDER = "EVENT_CHOSE_CHARMANDER",
  SQUIRTLE = "EVENT_CHOSE_SQUIRTLE",
}

local INTRO_TEXT = "Good morning, sleepyhead! Time to wake up! You missed your appointment with Professor OAK. Don't worry. He knew you'd probably oversleep, so he reserved three of his POKEMON for you to choose from. The other POKEMON TRAINERS already chose their partners, so I brought these three home for you. Go ahead and choose your partner!"

local POKEDEX_TEXT = "He also gave me something special for you: a POKEDEX! It's a high-tech encyclopedia. He wants you to fill the POKEDEX while you're out on your adventure."

local RIVAL_TEXT = "He also gave a POKEDEX to his grandson. You know, the one who's always picking on you. What was his name again?"

local RIVAL_AFTER_TEXT = "Maybe the two of you will become friends along the way."

local GOODBYE_TEXT = "I guess the TV was right. You really are leaving home. I just didn't think that day would come so soon. Remember who you are, and always do your best. Come home anytime you need a rest."

local KIDDING_TEXT = "Tee hee! I know you're kidding. Being a POKEMON TRAINER is all you've ever talked about. Have fun on your journey!"

-- Gen 1's normal dialogue box is 18 glyphs wide. Author all custom text as
-- two-line pages so nothing relies on soft wrapping or spills outside a box.
local function boxText(text, width)
  width = width or 18
  local lines = {}

  -- Wrap one sentence at a time. That guarantees the next sentence always
  -- begins on a fresh dialogue line instead of continuing after punctuation.
  local function wrapSentence(sentence)
    local line = ""
    for word in sentence:gmatch("%S+") do
      if line == "" then
        line = word
      elseif #line + 1 + #word <= width then
        line = line .. " " .. word
      else
        lines[#lines + 1] = line
        line = word
      end
    end
    if line ~= "" then lines[#lines + 1] = line end
  end

  local sentenceWords = {}
  for word in tostring(text):gmatch("%S+") do
    sentenceWords[#sentenceWords + 1] = word
    if word:match("[%.%!%?][\"']?$") then
      wrapSentence(table.concat(sentenceWords, " "))
      sentenceWords = {}
    end
  end
  if #sentenceWords > 0 then
    wrapSentence(table.concat(sentenceWords, " "))
  end

  local pages = {}
  for i = 1, #lines, 2 do
    local page = lines[i]
    if lines[i + 1] then page = page .. "\n" .. lines[i + 1] end
    pages[#pages + 1] = page
  end
  return table.concat(pages, "\f")
end

local function setFlag(save, name, value)
  save.flags = save.flags or {}
  if value then save.flags[name] = true else save.flags[name] = nil end
end

local function clearStarterFlags(save)
  for _, flag in pairs(STARTER_FLAGS) do setFlag(save, flag, false) end
end

local function loadImage(path, filter)
  local ok, img = pcall(love.graphics.newImage, Assets.resolve(path))
  if not ok then return nil end
  if img and img.setFilter then
    filter = filter or "nearest"
    img:setFilter(filter, filter)
  end
  return img
end

-- The starter art is shown at 150%.  A non-integer nearest-neighbor scale
-- creates visibly uneven 1px/2px blocks, so use linear sampling only for these
-- three pictures.  The source sprites remain untouched and alpha bounds are
-- still used for visual centering and a shared feet baseline.
local function pokemonImage(game, species)
  local path = Sprites.path(game.data, species, "front", { kind = "oak" })
  local resolved = Assets.resolve(path)
  local img = loadImage(path, "linear")
  if not img then return nil end

  local w, h = img:getDimensions()
  local pic = {
    image = img,
    minX = 0, minY = 0,
    maxX = w - 1, maxY = h - 1,
  }

  local imageApi = love.image
  if imageApi and imageApi.newImageData then
    local ok, src = pcall(imageApi.newImageData, resolved)
    if ok and src then
      local sw, sh = src:getDimensions()
      local minX, minY, maxX, maxY
      for y = 0, sh - 1 do
        for x = 0, sw - 1 do
          local _, _, _, a = src:getPixel(x, y)
          if a and a > 0.01 then
            minX = minX and math.min(minX, x) or x
            minY = minY and math.min(minY, y) or y
            maxX = maxX and math.max(maxX, x) or x
            maxY = maxY and math.max(maxY, y) or y
          end
        end
      end
      if minX then
        pic.minX, pic.minY = minX, minY
        pic.maxX, pic.maxY = maxX, maxY
      end
    end
  end

  return pic
end

-- The battle animation sprites use Game Boy OAM coordinates. Read the final
-- closed-ball frame from the engine's capture assets once, without playing
-- that animation, so the ball can simply appear where each unchosen POKEMON
-- vanished. This keeps the native POKE BALL art while avoiding any throw or
-- rocking motion.
local function captureBallAnchor(data)
  local fallbackX, fallbackY, fallbackBottom = 120, 48, 56
  if not data then return fallbackX, fallbackY, fallbackBottom, nil end
  local probe = AnimPlayer.new(data)
  local ok = pcall(probe.start, probe, "SHAKE_ANIM", true)
  if not ok then
    if probe.release then probe:release() end
    return fallbackX, fallbackY, fallbackBottom, nil
  end
  local sprites = probe.finalSprites and probe:finalSprites() or nil
  if not sprites or #sprites == 0 then
    if probe.release then probe:release() end
    return fallbackX, fallbackY, fallbackBottom, nil
  end
  local minX, minY, maxX, maxY
  for _, sp in ipairs(sprites) do
    -- AnimPlayer draws OAM at (x - 8, y - 16); use each 8x8 tile center.
    local x, y = sp.x - 4, sp.y - 12
    minX = minX and math.min(minX, x) or x
    minY = minY and math.min(minY, y) or y
    maxX = maxX and math.max(maxX, x) or x
    maxY = maxY and math.max(maxY, y) or y
  end
  if probe.release then probe:release() end
  -- x/y above are tile centers, so the bottom of the closed ball is 4 px
  -- below the lowest center.  Keep both center and bottom anchors: the poof /
  -- pull-in animation belongs over the POKEMON body, while the finished ball
  -- should sit on the same baseline where the POKEMON's feet were.
  return (minX + maxX) / 2, (minY + maxY) / 2, maxY + 4, sprites
end

-- Cutscene pathfinding uses the engine's own collision verdict for every
-- candidate step. This keeps Mom on the real collision map, respects other
-- entities, tile-pair rules, and any movement.collision hooks installed by
-- other mods.
local DIRS4 = { "up", "down", "left", "right" }

local function bfsPath(map, sx, sy, tx, ty, entities, mover)
  local function key(x, y) return y * 1000 + x end
  local prev = { [key(sx, sy)] = false }
  local queue = { { sx, sy } }
  local qi = 1

  -- Collision.canMove reads mover.cellX/cellY. Temporarily place the same
  -- mover at each BFS node so occupancy ignores Mom by identity and every
  -- engine collision rule is evaluated exactly as it would be for a real step.
  local originalX, originalY = mover.cellX, mover.cellY
  local function canStep(cx, cy, dir)
    mover.cellX, mover.cellY = cx, cy
    local allowed = Collision.canMove(map, entities, mover, dir)
    mover.cellX, mover.cellY = originalX, originalY
    return allowed
  end

  while queue[qi] do
    local cx, cy = queue[qi][1], queue[qi][2]
    qi = qi + 1
    if cx == tx and cy == ty then
      local path = {}
      local k = key(tx, ty)
      while prev[k] do
        table.insert(path, 1, prev[k][3])
        k = key(prev[k][1], prev[k][2])
      end
      mover.cellX, mover.cellY = originalX, originalY
      return path
    end

    for _, dir in ipairs(DIRS4) do
      local nx, ny = Collision.target(cx, cy, dir)
      local nk = key(nx, ny)
      if prev[nk] == nil and canStep(cx, cy, dir) then
        prev[nk] = { cx, cy, dir }
        queue[#queue + 1] = { nx, ny }
      end
    end
  end

  mover.cellX, mover.cellY = originalX, originalY
  return nil
end

local MomIntro = {}
MomIntro.__index = MomIntro
MomIntro.isOpaque = true
MomIntro.letterboxWhite = true

local function isBedroomPhase(phase)
  return phase == "bedroom_hold"
      or phase == "mom_walk"
      or phase == "mom_walk_pause"
      or phase == "mom_walk_underwear"
      or phase == "native_fade"
end

function MomIntro.new(game, mod, onDone, speech)
  local self = setmetatable({}, MomIntro)
  self.game = game
  self.mod = mod
  self.onDone = onDone
  self.speech = speech
  self.speechWasOpaque = speech and speech.isOpaque or nil
  self.speechWasLetterboxWhite = speech and speech.letterboxWhite or nil
  self.speechWasDraw = speech and speech.draw or nil
  self.phase = "dialogue"
  self.selected = 1
  self.showStarters = false
  self.mom = loadImage(mod.path .. "/assets/mom_intro.png")
  self.monPics = {}
  self.starterVisible = {}
  for _, species in ipairs(STARTER_ORDER) do
    self.monPics[species] = pokemonImage(game, species)
    self.starterVisible[species] = true
  end
  self.captureAnims = nil
  self.captureFinished = false
  return self
end

function MomIntro:sgbPalettes(game)
  if isBedroomPhase(self.phase) then
    local ow = game.overworld
    if ow and ow.sgbPalettes then return ow:sgbPalettes() end
  end
  return PaletteFX.wholeNamed(game.data, "MEWMON")
end

function MomIntro:sgbWorldZones()
  if isBedroomPhase(self.phase) then
    local ow = self.game.overworld
    if ow and ow.sgbWorldZones then return ow:sgbWorldZones() end
  end
  return nil
end

-- OakSpeech remains underneath this mod state for the entire custom step.
-- During the bedroom cutscene both states must become transparent so the
-- REAL overworld state is Game:draw's visible base. Calling ow:draw() from an
-- opaque intro state is not equivalent: Renderer then clears/composites the
-- frame as a classic white UI screen, which produces the giant white slab in
-- wide/voxel rendering.
function MomIntro:setBedroomPresentation(active)
  if active then
    self.isOpaque = false
    self.letterboxWhite = false
    if self.speech then
      self.speech.isOpaque = false
      self.speech.letterboxWhite = false
      -- OakSpeech:draw() always paints a solid 160x144 white field. Merely
      -- making OakSpeech non-opaque is not enough: the state still draws
      -- above the overworld and becomes the giant white slab in wide/voxel
      -- mode. Suppress only this instance's draw while the bedroom is live.
      self.speech.draw = function() end
    end
  else
    self.isOpaque = true
    self.letterboxWhite = true
    if self.speech then
      self.speech.isOpaque = self.speechWasOpaque
      self.speech.letterboxWhite = self.speechWasLetterboxWhite
      self.speech.draw = self.speechWasDraw
    end
  end
end

function MomIntro:enter()
  -- OakSpeech starts its normal intro tune before running modded steps.
  -- Replace it immediately with Pallet Town for Mom's entire white-screen intro.
  Music.playMap(self.game.data, "PALLET_TOWN")
  self:showText(INTRO_TEXT, function()
    self.phase = "starter"
    self.showStarters = true
    self.selected = 1
    self.captureFinished = false
    for _, species in ipairs(STARTER_ORDER) do
      self.starterVisible[species] = true
    end
    Sound.playCry(self.game.data, STARTER_ORDER[self.selected])
  end)
end

function MomIntro:showText(text, onDone)
  self.game.stack:push(TextBox.new(self.game, boxText(text), onDone))
end

function MomIntro:ask(text, onAnswer)
  self.game.stack:push(TextBox.new(self.game, boxText(text), nil, {
    choice = function(yes) onAnswer(yes) end,
  }))
end

function MomIntro:starterName()
  return STARTER_ORDER[self.selected]
end

function MomIntro:confirmStarter()
  local species = self:starterName()
  self.phase = "dialogue"
  self:ask("Yay! So you want " .. species .. " as your partner?", function(yes)
    if not yes then
      self.phase = "starter"
      self.showStarters = true
      return
    end
    self:startStarterCapture(species)
  end)
end

function MomIntro:playCaptureEvents(cap)
  -- The two pull-in animations run in sync, so only one owns their shared
  -- battle SFX. No ball-rocking sound is played.
  if not cap.soundOwner or not cap.player.pollEffects then return end
  for _, ev in ipairs(cap.player:pollEffects()) do
    if ev.sound then
      if Sound.playMove then
        Sound.playMove(self.game.data, ev)
      else
        Sound.play(self.game.data, ev.sound)
      end
    end
  end
end

function MomIntro:startCaptureStage(cap)
  local stage = STARTER_CAPTURE_STAGES[cap.stage]
  if not stage then
    cap.done = true
    return
  end

  if stage.hide then
    self.starterVisible[cap.species] = false
  end

  local ok = pcall(cap.player.start, cap.player, stage.anim, true)
  if not ok then
    -- If an animation asset is unavailable, still complete the selection
    -- instead of trapping New Game in a cutscene.
    self.starterVisible[cap.species] = false
    cap.done = true
    return
  end
  self:playCaptureEvents(cap) -- frame-zero battle sound/effect events
end

function MomIntro:startStarterCapture(species)
  self.phase = "starter_capture"
  self.captureStarter = species
  self.captureFinished = false
  self.captureAnims = {}

  local anchorX, anchorY, anchorBottom, closedBallSprites =
    captureBallAnchor(self.game.data.battle_anims)
  for i, other in ipairs(STARTER_ORDER) do
    if other ~= species then
      local pic = self.monPics[other]
      local visibleH = pic and (pic.maxY - pic.minY + 1) or 56
      local targetX = STARTER_CENTERS[i]
      local targetY = STARTER_BASELINE - (visibleH * STARTER_SCALE) / 2
      local cap = {
        species = other,
        player = AnimPlayer.new(self.game.data.battle_anims),
        stage = 1,
        -- Active POOF/HIDEPIC stays centered on the POKEMON body.
        offsetX = targetX - anchorX,
        offsetY = targetY - anchorY,
        -- The resting closed ball uses a separate offset so its bottom lands
        -- exactly on the old sprite baseline instead of floating at mid-body.
        finalOffsetX = targetX - anchorX,
        finalOffsetY = STARTER_BASELINE - anchorBottom,
        closedBallSprites = closedBallSprites,
        soundOwner = #self.captureAnims == 0,
      }
      self.captureAnims[#self.captureAnims + 1] = cap
      self:startCaptureStage(cap)
    end
  end

  if #self.captureAnims == 0 then
    self.captureFinished = true
    self.phase = "dialogue"
    self:giveStarter(species)
  end
end

function MomIntro:updateStarterCapture()
  if self.captureFinished then return end
  local allDone = true
  for _, cap in ipairs(self.captureAnims or {}) do
    if not cap.done then
      allDone = false
      cap.player:update()
      self:playCaptureEvents(cap)
      if cap.player:isDone() then
        cap.stage = cap.stage + 1
        if STARTER_CAPTURE_STAGES[cap.stage] then
          self:startCaptureStage(cap)
        else
          -- The pull-in is complete: show the closed POKE BALL immediately.
          cap.finalSprites = cap.closedBallSprites
          cap.done = true
        end
      end
    end
  end

  -- Re-evaluate because the last active stages may have completed this frame.
  allDone = true
  for _, cap in ipairs(self.captureAnims or {}) do
    if not cap.done then allDone = false break end
  end
  if allDone then
    self.captureFinished = true
    self.phase = "dialogue"
    self:giveStarter(self.captureStarter or self:starterName())
  end
end

function MomIntro:giveStarter(species)
  self.mod.save:set("selected_starter", species)
  local ctx = {
    game = self.game,
    save = self.game.save,
    overworld = self.game.overworld,
  }
  Commands.give_pokemon(ctx, species, 5, true)
  if not ctx.lastCheck then
    error("TM39 Swift: starter could not be added to the party/boxes", 0)
  end

  clearStarterFlags(ctx.save)
  setFlag(ctx.save, "EVENT_GOT_STARTER", true)
  setFlag(ctx.save, STARTER_FLAGS[species], true)

  local mon
  if ctx.addedToParty then
    for i = #(ctx.save.party or {}), 1, -1 do
      local candidate = ctx.save.party[i]
      if candidate and (candidate.species == species
          or candidate.species == ctx.pendingPokemonName) then
        mon = candidate
        break
      end
    end
    mon = mon or ctx.save.party[#ctx.save.party]
  end
  self.starterMon = mon

  self:ask("Would you like to give " .. species .. " a nickname?", function(yes)
    if yes and self.starterMon then
      Screens.push(self.game, "NamingScreen", {
        title = "NICKNAME?",
        maxLen = 10,
        mon = self.starterMon,
        onDone = function(nick)
          if nick and #nick > 0 then self.starterMon.nickname = nick end
          self:showHappyTogether(species)
        end,
      })
    else
      self:showHappyTogether(species)
    end
  end)
end

function MomIntro:showHappyTogether(species)
  local partnerName = species
  if self.starterMon and self.starterMon.nickname
      and #self.starterMon.nickname > 0 then
    partnerName = self.starterMon.nickname
  end
  self:showText("I'm sure you and " .. partnerName
      .. " will be very happy together!", function()
    self:showPokedexOffer()
  end)
end

function MomIntro:applyAdventureState()
  local save = self.game.save
  local species = self.mod.save:get("selected_starter")
  if not species or not STARTER_FLAGS[species] then
    error("TM39 Swift: invalid starter at Pokédex handoff", 0)
  end

  -- Skip the Oak escort, lab starter scene, lab rival fight, Parcel trip,
  -- and Oak Pokédex handoff while leaving the world in the corresponding
  -- post-Pokédex Red/Blue story state.
  setFlag(save, "EVENT_FOLLOWED_OAK_INTO_LAB", true)
  setFlag(save, "EVENT_FOLLOWED_OAK_INTO_LAB_2", true)
  setFlag(save, "EVENT_OAK_ASKED_TO_CHOOSE_MON", true)
  clearStarterFlags(save)
  setFlag(save, "EVENT_GOT_STARTER", true)
  setFlag(save, STARTER_FLAGS[species], true)

  setFlag(save, "EVENT_BATTLED_RIVAL_IN_OAKS_LAB", true)
  setFlag(save, "EVENT_GOT_POKEBALLS_FROM_OAK", true)
  setFlag(save, "EVENT_GOT_POKEDEX", true)
  setFlag(save, "EVENT_OAK_GOT_PARCEL", true)
  setFlag(save, "EVENT_GOT_OAKS_PARCEL", true)

  setFlag(save, "EVENT_1ST_ROUTE22_RIVAL_BATTLE", true)
  setFlag(save, "EVENT_2ND_ROUTE22_RIVAL_BATTLE", false)
  setFlag(save, "EVENT_ROUTE22_RIVAL_WANTS_BATTLE", true)
  setFlag(save, "EVENT_BEAT_ROUTE22_RIVAL_1ST_BATTLE", false)
  setFlag(save, "EVENT_BEAT_ROUTE22_RIVAL_2ND_BATTLE", false)

  local ctx = {
    game = self.game,
    save = save,
    overworld = self.game.overworld,
  }

  Commands.hide_object(ctx, "PALLET_TOWN", "PALLETTOWN_OAK")
  Commands.show_object(ctx, "OAKS_LAB", "OAKSLAB_OAK1")
  Commands.hide_object(ctx, "OAKS_LAB", "OAKSLAB_OAK2")
  Commands.hide_object(ctx, "OAKS_LAB", "OAKSLAB_RIVAL")
  Commands.hide_object(ctx, "OAKS_LAB", "OAKSLAB_POKEDEX1")
  Commands.hide_object(ctx, "OAKS_LAB", "OAKSLAB_POKEDEX2")

  -- Mom says the other trainers already received theirs, so none of the
  -- starter balls should remain waiting on Oak's table.
  Commands.hide_object(ctx, "OAKS_LAB", "OAKSLAB_BULBASAUR_POKE_BALL")
  Commands.hide_object(ctx, "OAKS_LAB", "OAKSLAB_CHARMANDER_POKE_BALL")
  Commands.hide_object(ctx, "OAKS_LAB", "OAKSLAB_SQUIRTLE_POKE_BALL")

  Commands.hide_object(ctx, "VIRIDIAN_CITY", "VIRIDIANCITY_OLD_MAN_SLEEPY")
  Commands.show_object(ctx, "VIRIDIAN_CITY", "VIRIDIANCITY_OLD_MAN")
  Commands.show_object(ctx, "ROUTE_22", "ROUTE22_RIVAL1")

  self.mod.save:set("completed", true)
  -- Completion is persisted in mod.save; no custom event is required here.
end

function MomIntro:showAdventureQuestion()
  self:applyAdventureState()
  self:showText(GOODBYE_TEXT, function()
    -- Move the underwear beat into the physical walk downstairs so the
    -- scene never drops back to the white intro field between beats.
    self:beginBedroomCutscene()
  end)
end

function MomIntro:openPlayerNaming()
  local constants = self.game.data.constants or {}

  -- Keep the confirmation inside the naming screen. Confirming a typed name
  -- opens a YES/NO box over the still-visible name grid. NO returns directly
  -- to editing; YES accepts the name and returns to Mom.
  local screen = NamingScreen.new(self.game, {
    title = "YOUR NAME?",
    maxLen = constants.playerNameLength or 7,
  })

  screen.confirm = function(naming)
    local name = table.concat(naming.glyphs or {})
    if name == "" then return end

    Sound.play(naming.game.data, "Press_AB")
    naming.game.stack:push(TextBox.new(naming.game, boxText("Continue?"), nil, {
      choice = function(yes)
        if not yes then return end

        naming.game.save.player.name = name
        naming.game.stack:pop() -- close the naming screen itself
        self:showText("Now you're a real POKEMON TRAINER.", function()
          self:showText(RIVAL_TEXT, function()
            self:openRivalNaming()
          end)
        end)
      end,
    }))
  end

  self.game.stack:push(screen)
end

function MomIntro:openRivalNaming()
  local constants = self.game.data.constants or {}
  local boot = self.game.data.field and self.game.data.field.boot
  local presets = boot and boot.namePresets and boot.namePresets.rival
  if type(presets) ~= "table" or #presets == 0 then
    presets = { "BLUE", "GARY", "JOHN" }
  end

  Screens.push(self.game, "NamingScreen", {
    title = "RIVAL's NAME?",
    presets = presets,
    introBox = true,
    maxLen = constants.playerNameLength or 7,
    onDone = function(name)
      if name and #name > 0 then
        self.game.save.player.rival = name
      end
      self:showText(RIVAL_AFTER_TEXT, function()
        self:showAdventureQuestion()
      end)
    end,
  })
end

function MomIntro:showPokedexOffer()
  self:showText(POKEDEX_TEXT, function()
    self:showText("Go ahead and register your name in it.", function()
      self:openPlayerNaming()
    end)
  end)
end

function MomIntro:spawnBedroomMom()
  local ow = self.game.overworld
  if not ow or not ow.map or ow.map.id ~= "REDS_HOUSE_2F" then return nil end

  local def = {
    name = "SWIFT_MOM_UPSTAIRS",
    sprite = "SPRITE_MOM",
    movement = "STAY",
    range = "LEFT",
    x = self.momSpawnX or 2,
    y = self.momSpawnY or 6,
  }

  if ow.addRuntimeObject then
    local id = ow:addRuntimeObject("REDS_HOUSE_2F", def, self.mod.id)
    self.runtimeMomId = id
    if id then
      for _, npc in ipairs(ow.npcs or {}) do
        if npc.id == id then return npc end
      end
    end
  end

  -- Compatibility fallback for builds predating addRuntimeObject.
  local NPC = require("src.world.NPC")
  local maxIndex = 0
  for _, npc in ipairs(ow.npcs or {}) do
    maxIndex = math.max(maxIndex, npc.def and npc.def.index or 0)
  end
  def.index = maxIndex + 1
  local npc = NPC.new(self.game.data, "REDS_HOUSE_2F", def)
  self.fallbackMom = npc
  ow.npcs = ow.npcs or {}
  ow.entities = ow.entities or {}
  ow.npcPool = ow.npcPool or {}
  table.insert(ow.npcs, npc)
  table.insert(ow.entities, npc)
  ow.npcPool[npc.id] = npc
  return npc
end

function MomIntro:removeBedroomMom()
  local ow = self.game.overworld
  if not ow then return end
  if self.runtimeMomId and ow.removeRuntimeObject then
    ow:removeRuntimeObject(self.runtimeMomId, self.mod.id)
    self.runtimeMomId = nil
    self.bedroomMom = nil
    return
  end
  local npc = self.fallbackMom or self.bedroomMom
  if npc then
    for _, list in ipairs({ ow.npcs or {}, ow.entities or {} }) do
      for i = #list, 1, -1 do
        if list[i] == npc then table.remove(list, i) end
      end
    end
    if ow.npcPool then ow.npcPool[npc.id] = nil end
  end
  self.fallbackMom = nil
  self.bedroomMom = nil
end

local function placePlayer(player, save, x, y, facing)
  if not player then return end
  player.cellX, player.cellY = x, y
  player.px, player.py = x * 16, y * 16
  player.targetX, player.targetY = nil, nil
  player.moving = false
  player.marching = false
  player.progress = 0
  player.facing = facing or player.facing
  if save and save.player then
    save.player.x, save.player.y = x, y
    save.player.facing = player.facing
  end
end

local function staircaseWarp(map)
  for _, warp in ipairs((map and map.def and map.def.warps) or {}) do
    if warp.destMap == "REDS_HOUSE_1F" then return warp end
  end
  return nil
end

function MomIntro:beginBedroomCutscene()
  self.showStarters = false
  self.phase = "bedroom_hold"
  self.holdFrames = 45
  self.isOverworld = true
  self:setBedroomPresentation(true)

  local ow = self.game.overworld
  if not ow or not ow.map or ow.map.id ~= "REDS_HOUSE_2F" then
    self:finishIntro()
    return
  end

  -- Put Red right beside the bed instead of leaving him at the stock new-game
  -- center-floor spawn. (1,6) is the vanilla floor cell immediately east of
  -- the bed. If another map mod makes that cell solid, keep the live position.
  local px, py = 1, 6
  if not ow.map:isWalkableCell(px, py) then
    px, py = ow.player.cellX, ow.player.cellY
  end
  placePlayer(ow.player, self.game.save, px, py, "right")

  -- Pick a real walkable cell beside Red for Mom. This also avoids placing her
  -- inside a runtime object contributed by another map mod.
  local momSpawns = { { 2, 6 }, { 1, 5 }, { 2, 5 }, { 3, 6 } }
  self.momSpawnX, self.momSpawnY = nil, nil
  for _, cell in ipairs(momSpawns) do
    if ow.map:isWalkableCell(cell[1], cell[2])
        and not Collision.occupied(ow.entities or {}, cell[1], cell[2], nil) then
      self.momSpawnX, self.momSpawnY = cell[1], cell[2]
      break
    end
  end
  if not self.momSpawnX then
    self:finishIntro()
    return
  end

  self.bedroomMom = self:spawnBedroomMom()
  if self.bedroomMom and ow.player then
    self.bedroomMom:facePlayer(ow.player)
  end

  -- Switch from the intro tune to the bedroom theme as the white intro
  -- gives way to the actual map.
  Music.playMap(self.game.data, "REDS_HOUSE_2F")
end

function MomIntro:startMomWalk()
  local ow = self.game.overworld
  local mom = self.bedroomMom
  if not ow or not mom then
    self:finishIntro()
    return
  end

  -- Resolve the actual staircase warp from the loaded map instead of assuming
  -- coordinates. That makes the cutscene follow map edits and still sends Mom
  -- through the real REDS_HOUSE_2F -> REDS_HOUSE_1F exit.
  local warp = staircaseWarp(ow.map)
  if not warp then
    self:finishIntro()
    return
  end
  self.momExitWarp = warp

  local path = bfsPath(ow.map, mom.cellX, mom.cellY, warp.x, warp.y,
                       ow.entities, mom)
  if not path then
    -- A collision-changing mod can legitimately make the route unavailable.
    -- Keep the scene safe rather than ghosting Mom through blocked tiles.
    self:finishIntro()
    return
  end
  self.walkPath = path
  self.walkIndex = 0
  self.underwearDone = false
  -- Stop roughly halfway to the stairs, after at least one visible step and
  -- before the final stair step. The vanilla bedroom route is long enough
  -- for this to read as Mom remembering something mid-walk.
  self.underwearPauseAfter = math.max(1, math.floor(#path / 2))
  if #path > 1 then
    self.underwearPauseAfter = math.min(self.underwearPauseAfter, #path - 1)
  end
  self.phase = "mom_walk"
  self:startNextMomStep()
end

function MomIntro:pauseForUnderwear()
  if self.underwearDone then return false end
  local pathLen = #(self.walkPath or {})
  if pathLen <= 1 or self.walkIndex < (self.underwearPauseAfter or 1)
      or self.walkIndex >= pathLen then
    return false
  end

  local mom = self.bedroomMom
  local ow = self.game.overworld
  if mom and ow and ow.player then mom:facePlayer(ow.player) end
  self.phase = "mom_walk_pause"
  self.pauseFrames = 120 -- two seconds at the engine's 60 Hz fixed step
  return true
end

function MomIntro:startNextMomStep()
  self.walkIndex = self.walkIndex + 1
  local dir = self.walkPath and self.walkPath[self.walkIndex]
  local mom = self.bedroomMom
  local ow = self.game.overworld

  if not dir or not mom or not ow then
    -- Reaching the actual stair warp is Mom leaving the upstairs map. Hand off
    -- to the normal downstairs Mom, then use Gen1Recomp's native warp fade.
    Sound.play(self.game.data, "Go_Inside")
    self:removeBedroomMom()
    self:beginNativeFade()
    return
  end

  -- Re-check the real collision verdict immediately before each visible step.
  -- If another runtime entity changed the route, recalculate from Mom's current
  -- cell instead of walking through it.
  if not Collision.canMove(ow.map, ow.entities, mom, dir) then
    local warp = self.momExitWarp or staircaseWarp(ow.map)
    local path = warp and bfsPath(ow.map, mom.cellX, mom.cellY, warp.x, warp.y,
                                  ow.entities, mom) or nil
    if not path then
      self:finishIntro()
      return
    end
    self.walkPath = path
    self.walkIndex = 0
    self:startNextMomStep()
    return
  end

  mom.facing = dir
  mom.targetX, mom.targetY = Collision.target(mom.cellX, mom.cellY, dir)
  mom.moving = true
  mom.progress = 0
end

function MomIntro:beginNativeFade()
  if self.nativeFadeStarted then return end
  self.nativeFadeStarted = true
  self.phase = "native_fade"

  -- Use the engine's native warp fade, but finish the custom intro only AFTER
  -- the Transition state has removed itself. Doing this from onMidpoint is
  -- unsafe on builds/mod setups that give the transition a fade-in phase: the
  -- Transition would still be the stack top, so OakSpeech:finish() could pop
  -- the transition instead of OakSpeech and leave this cutscene frozen.
  -- Explicit black + framesIn=0 also prevents a white return flash.
  self.game.stack:push(Transition.new(self.game, nil, function()
    self:finishIntro()
  end, true, {
    color = { 0, 0, 0 },
    framesIn = 0,
  }))
end

function MomIntro:releaseCaptureAnims()
  for _, cap in ipairs(self.captureAnims or {}) do
    if cap.player and cap.player.release then cap.player:release() end
  end
  self.captureAnims = nil
end

function MomIntro:finishIntro()
  if self.finished then return end
  self.finished = true
  self.isOverworld = nil
  self:setBedroomPresentation(false)
  self:releaseCaptureAnims()
  self:removeBedroomMom()
  if self.game.stack:top() == self then self.game.stack:pop() end
  if self.onDone then self.onDone() end
end

function MomIntro:exit()
  self:setBedroomPresentation(false)
  self:releaseCaptureAnims()
  if not self.finished then self:removeBedroomMom() end
end

function MomIntro:update(dt)
  if self.phase == "starter" then
    local input = self.game.input
    local old = self.selected
    if input:wasPressed("left") then
      self.selected = self.selected > 1 and self.selected - 1 or #STARTER_ORDER
    elseif input:wasPressed("right") then
      self.selected = self.selected < #STARTER_ORDER and self.selected + 1 or 1
    elseif input:wasPressed("a") then
      Sound.play(self.game.data, "Press_AB")
      self:confirmStarter()
      return
    end
    if self.selected ~= old then
      Sound.playCry(self.game.data, STARTER_ORDER[self.selected])
    end
    return
  end

  if self.phase == "starter_capture" then
    self:updateStarterCapture()
    return
  end

  if self.phase == "bedroom_hold" then
    self.holdFrames = self.holdFrames - 1
    if self.holdFrames <= 0 then self:startMomWalk() end
    return
  end

  if self.phase == "mom_walk" then
    local mom = self.bedroomMom
    if not mom then
      self:finishIntro()
      return
    end
    local wasMoving = mom.moving
    mom:update(self.game.overworld.map, self.game.overworld.entities)
    if wasMoving and not mom.moving then
      if not self:pauseForUnderwear() then self:startNextMomStep() end
    end
    return
  end

  if self.phase == "mom_walk_pause" then
    self.pauseFrames = (self.pauseFrames or 0) - 1
    if self.pauseFrames <= 0 then
      self.phase = "mom_walk_underwear"
      self:showText("I also packed you some fresh underwear.", function()
        self.underwearDone = true
        self.phase = "mom_walk"
        self:startNextMomStep()
      end)
    end
    return
  end

end

function MomIntro:drawIntro()
  local g = love.graphics
  g.setColor(1, 1, 1, 1)
  g.rectangle("fill", 0, 0, 160, 144)

  if self.mom then
    local w = self.mom:getWidth()
    g.draw(self.mom, math.floor((160 - w) / 2), 2)
  end

  if not self.showStarters then return end

  -- Draw the original Gen 1 front sprites at 150%.  Linear sampling avoids
  -- the alternating 1px/2px block pattern that makes 1.5x nearest-neighbor
  -- scaling look malformed.  Visible alpha bounds control centering/baseline.
  local centers = STARTER_CENTERS
  local baseline = STARTER_BASELINE
  local scale = STARTER_SCALE
  for i, species in ipairs(STARTER_ORDER) do
    local pic = self.monPics[species]
    if pic and pic.image and self.starterVisible[species] ~= false then
      local visibleCenterX = (pic.minX + pic.maxX + 1) / 2
      local x = centers[i] - visibleCenterX * scale
      local y = baseline - (pic.maxY + 1) * scale
      g.draw(pic.image, math.floor(x), math.floor(y), 0, scale, scale)
    end
  end

  -- Draw the two closed POKE BALLS where the unchosen partners vanished.
  -- Their art comes from the engine's native capture assets, but the throw
  -- and rocking portions are never played.
  for _, cap in ipairs(self.captureAnims or {}) do
    if cap.player then
      g.push()
      if cap.finalSprites then
        g.translate(cap.finalOffsetX or cap.offsetX or 0,
                    cap.finalOffsetY or cap.offsetY or 0)
        if cap.player.drawSprites then cap.player:drawSprites(cap.finalSprites) end
      elseif not cap.done then
        g.translate(cap.offsetX or 0, cap.offsetY or 0)
        cap.player:draw()
      end
      g.pop()
    end
  end

  -- Upward arrow under the selected partner, then its name centered below.
  local cx = centers[self.selected]
  local species = self:starterName()
  g.setColor(0, 0, 0, 1)
  g.polygon("fill", cx, baseline + 2,
            cx - 5, baseline + 9, cx + 5, baseline + 9)
  Font.draw(species, math.floor((160 - #species * 8) / 2), 132)
  g.setColor(1, 1, 1, 1)
end

function MomIntro:draw()
  if isBedroomPhase(self.phase) then
    -- The actual OverworldController draws beneath this transparent state.
    -- Do not manually draw it into the intro/UI pass.
    return
  end
  self:drawIntro()
end

-- One-time downstairs POKE BALL handoff. Mom steps one cell toward whichever
-- side Red used to pass her, delivers the gift, then returns to her vanilla
-- (5,4) spot. This state is transparent and marks itself as overworld so the
-- normal map remains visible and NPC walking animates exactly like field play.
local BallGift = {}
BallGift.__index = BallGift
BallGift.isOpaque = false
BallGift.isOverworld = true

local function npcName(npc)
  return (npc and npc.def and npc.def.name) or (npc and npc.name)
end

local function findDownstairsMom(ow)
  for _, npc in ipairs((ow and ow.npcs) or {}) do
    if npcName(npc) == "REDSHOUSE1F_MOM" then return npc end
  end
  return nil
end

local function startNpcStep(ow, npc, dir)
  if not ow or not npc or not dir then return false end
  if not Collision.canMove(ow.map, ow.entities, npc, dir) then return false end
  npc.facing = dir
  npc.targetX, npc.targetY = Collision.target(npc.cellX, npc.cellY, dir)
  npc.moving = true
  npc.progress = 0
  return true
end

local function directionToward(sx, sy, tx, ty)
  if tx < sx and ty == sy then return "left" end
  if tx > sx and ty == sy then return "right" end
  if ty < sy and tx == sx then return "up" end
  if ty > sy and tx == sx then return "down" end
  return nil
end

function BallGift.new(game, mod, mom, side)
  local self = setmetatable({}, BallGift)
  self.game = game
  self.mod = mod
  self.mom = mom
  self.side = side
  self.homeX = mom.cellX
  self.homeY = mom.cellY
  self.homeFacing = mom.facing or "left"
  self.phase = "approach"
  return self
end

function BallGift:enter()
  local ow = self.game.overworld
  local dir = self.side == "left" and "left" or "right"
  if not startNpcStep(ow, self.mom, dir) then
    self:startSpeech()
  end
end

function BallGift:showText(text, onDone, opts)
  self.game.stack:push(TextBox.new(self.game, boxText(text), onDone, opts))
end

function BallGift:startSpeech()
  self.phase = "speech"
  local ow = self.game.overworld
  if self.mom and ow and ow.player then self.mom:facePlayer(ow.player) end
  local playerName = (self.game.save.player and self.game.save.player.name) or "RED"
  self:showText("Oh, " .. playerName .. ", I forgot! Professor OAK's aide dropped these POKE BALLS off for you!", function()
    self:giveBalls()
  end)
end

function BallGift:giveBalls()
  local game = self.game
  local save = game.save
  if not Bag.add(save, "POKE_BALL", 5, game.data) then
    local full = (game.data.text and game.data.text._BagFullText)
      or Strings("You can't carry\nany more items!")
    game.stack:push(TextBox.new(game, full, function()
      self:startReturn(false)
    end))
    return
  end

  -- Match Commands.give_item's native received-item presentation: same item
  -- name buffer, Get_Item1 fanfare, wait-for-fanfare behavior, and stock
  -- "{PLAYER} got <item>!" wording.
  local def = game.data.items and game.data.items.POKE_BALL
  game.stringBuffer = (def and def.name) or "POKE BALL"
  self.mod.save:set("pokeball_gift_done", true)
  local gotText = Strings("{PLAYER} got\n%s!", game.stringBuffer)
  game.stack:push(TextBox.new(game, gotText, function()
    self:showText("Bye now!", function()
      self:startReturn(true)
    end)
  end, {
    auto = {
      sound = function() return Sound.play(game.data, "Get_Item1") end,
      wait = true,
    },
  }))
end

function BallGift:startReturn(gifted)
  self.phase = "return"
  self.gifted = gifted
  local mom = self.mom
  local ow = self.game.overworld
  if not mom or not ow then
    self:finish()
    return
  end
  local dir = directionToward(mom.cellX, mom.cellY, self.homeX, self.homeY)
  if not dir or not startNpcStep(ow, mom, dir) then
    mom.facing = self.homeFacing
    self:finish()
  end
end

function BallGift:finish()
  if self.finished then return end
  self.finished = true
  if self.mom then self.mom.facing = self.homeFacing end
  if self.game.stack:top() == self then self.game.stack:pop() end
end

function BallGift:update(dt)
  if self.phase ~= "approach" and self.phase ~= "return" then return end
  local ow = self.game.overworld
  local mom = self.mom
  if not ow or not mom then
    self:finish()
    return
  end
  local wasMoving = mom.moving
  mom:update(ow.map, ow.entities)
  if wasMoving and not mom.moving then
    if self.phase == "approach" then
      self:startSpeech()
    else
      mom.facing = self.homeFacing
      self:finish()
    end
  end
end

function BallGift:draw() end

return function(mod)
  mod.hooks:wrap("intro.oak_speech.build", function(next, steps, speech)
    -- Let lower-priority wrappers complete, then intentionally replace the
    -- whole Oak speech with Swift's Mom sequence.
    next(steps, speech)
    return {
      {
        id = "tm39_swift_v2_mom_intro",
        kind = "fn",
        run = function(activeSpeech, done)
          activeSpeech.game.stack:push(MomIntro.new(activeSpeech.game, mod, done, activeSpeech))
        end,
      },
    }
  end)

  -- Once the intro is complete, Mom must catch Red before he can leave home.
  -- The hook runs before the overworld reads this frame's input, so pushing
  -- BallGift here stops a pending exit step as well. Passing either side of
  -- Mom triggers normally; row 6 is a safety net that guarantees the handoff
  -- before either bottom-door warp can be entered.
  mod.hooks:wrap("input.step", function(next, game, dt)
    if mod.save:get("completed", false)
        and not mod.save:get("pokeball_gift_done", false) then
      local ow = game.overworld
      if ow and ow.map and ow.map.id == "REDS_HOUSE_1F"
          and game.stack:top() == ow and not ow.transitioning then
        local p = ow.player
        local mom = findDownstairsMom(ow)
        if p and not p.moving and mom and not mom.moving then
          local dx = p.cellX - mom.cellX
          local dy = p.cellY - mom.cellY
          local passingSide = math.abs(dx) <= 2 and dy >= 0 and dy <= 2
          local approachingExit = p.cellY >= 6
          if passingSide or approachingExit then
            local side = p.cellX <= mom.cellX and "left" or "right"
            game.stack:push(BallGift.new(game, mod, mom, side))
            return next(game, dt)
          end
        end
      end
    end
    return next(game, dt)
  end)
end
