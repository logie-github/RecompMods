-- TM01 Focus Punch v3.64
-- Target: Gen1Recomp v0.2.64
-- FireRed: skip the Controls Guide + Pikachu adventure tutorial pages while
-- entering the normal Oak/new-game speech with the scene layers initialized.

local Scene = require("src.ui.game3.new_game_scene")
local Pal = require("src.core.game3.pal_fade")

return function(mod)
  -- Preserve FireRed's state-0 reset. The skipped tutorial normally turns on
  -- BG0/BG1 later and leaves the palette fully black before Oak starts. Oak's
  -- own initializer only enables BG2, so jumping there without reproducing
  -- those two conditions gives exactly this failure:
  --   * black background (BG1 hidden)
  --   * no dialogue box/text (BG0 hidden)
  if not Scene._tm01FocusPunchOriginalNewGameScene then
    Scene._tm01FocusPunchOriginalNewGameScene = Scene.Task_NewGameScene
  end

  local original = Scene._tm01FocusPunchOriginalNewGameScene

  Scene.Task_NewGameScene = function(self, t)
    original(self, t)

    -- We invoke this replacement only from the initial Task_NewGameScene task.
    -- After the original state-0 reset, reconstruct the visual state that the
    -- Controls/Pikachu chain would have left behind immediately before
    -- Task_OakSpeech_Init.
    self.win.topbar = nil
    self.win.guide = nil
    self.win.pika = nil
    self.win.dialog = nil
    self.win.menu = nil
    self.win0Pika = false
    self.bg1 = nil
    self.bld = nil
    self.currentPage = 0

    -- These are the critical flags skipped by bypassing Task_NewGameScene
    -- state 10. BG0 draws the dialogue window/text; BG1 draws Oak/Mom's scene.
    self.bgVisible[0] = true
    self.bgVisible[1] = true

    -- The normal Pikachu-clear transition reaches Oak from a fully black
    -- palette. Recreate that so Oak/TM39's own fade-in behaves identically.
    self.pal:blend(Pal.ALL, 16, Pal.BLACK)

    t.data = t.data or {}
    t.data.timer = 0
    t.state = 0

    -- Resolve this at runtime so another mod (such as TM39 Swift) can replace
    -- the Oak initializer and still receive control normally.
    t.func = Scene.Task_OakSpeech_Init
  end

  mod.log:info("TM01 Focus Punch v3.64: FireRed pre-intro help screens skipped")
end
