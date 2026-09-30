-- TM35 Metronome v2.61
-- Target: Gen1Recomp 0.2.61
--
-- Full-screen swipe/tap gesture navigation:
--   Tap -> A
--   Tap-and-hold -> B
--   Long hold -> Fast Forward
--   Double tap -> Start
--   Tap-release, then hold second tap -> Select
--   Swipe any direction -> D-pad
-- Active everywhere except the Mod Manager, which keeps its own native
-- touch handling.

return function(mod)
  -- User-facing sensitivity control in the Gen1Recomp Mod Manager.
  -- Lower values require less finger travel, allowing tighter turns.
  mod.options:define({
    {
      key = "swipe_size",
      type = "number",
      label = "SWIPE SIZE",
      default = 100,
      min = 25,
      max = 150,
      step = 5,
    },
  })

  local function swipeScale()
    local value = tonumber(mod.options:get("swipe_size")) or 100
    if value < 25 then value = 25 end
    if value > 150 then value = 150 end
    return value / 100
  end

  local SWIPE_RATIO = 0.055
  local MIN_SWIPE = 22
  local TAP_SLOP_RATIO = 0.025
  local MIN_TAP_SLOP = 10

  local DOUBLE_TAP_TIME = 0.18
  local DOUBLE_TAP_DISTANCE_RATIO = 0.08
  local MIN_DOUBLE_TAP_DISTANCE = 28
  local DOUBLE_TAP_MOVE_SLOP_RATIO = 0.012
  local MIN_DOUBLE_TAP_MOVE_SLOP = 5

  -- A stationary hold becomes B after this delay.
  local HOLD_B_DELAY = 0.50

  -- Continuing the same stationary hold switches from B to fast-forward.
  local HOLD_SPEED_DELAY = 1.25

  local game
  local touches = {}
  local pendingTap = nil
  local directionOwner = nil
  local directionHeld = nil
  local gestureMode = false

  local speedHoldOwner = nil
  local speedHoldOriginal = nil
  local heldInput = {}

  local function now()
    if love and love.timer and love.timer.getTime then
      return love.timer.getTime()
    end
    return os.clock()
  end

  local function dimensions()
    if love and love.graphics and love.graphics.getDimensions then
      return love.graphics.getDimensions()
    end
    return 1, 1
  end

  -- Gen 1 and Gen 2 use different battle presenters. Identify both shapes
  -- without requiring a generation-specific engine module.
  local function isGen1BattleState(state)
    return state ~= nil
       and type(state.updateQueue) == "function"
       and type(state.startMessage) == "function"
       and type(state.beginMsgLine) == "function"
       and type(state.phase) == "string"
       and state.player ~= nil
       and state.enemy ~= nil
  end

  local function isGen2BattleState(state)
    return state ~= nil
       and type(state.syncTyper) == "function"
       and type(state.advanceQueue) == "function"
       and type(state.phase) == "string"
       and state.battle ~= nil
  end

  local function isBattleState(state)
    return isGen1BattleState(state) or isGen2BattleState(state)
  end

  local function battleInStack()
    if not (game and game.stack and game.stack.states) then return nil end
    for i = #game.stack.states, 1, -1 do
      local state = game.stack.states[i]
      if isBattleState(state) then return state end
    end
    return nil
  end

  local function shortSide()
    local w, h = dimensions()
    return math.max(1, math.min(w, h))
  end

  local function swipeThreshold()
    return math.max(MIN_SWIPE * swipeScale(), shortSide() * SWIPE_RATIO * swipeScale())
  end

  local function tapSlop()
    return math.max(MIN_TAP_SLOP, shortSide() * TAP_SLOP_RATIO)
  end

  local function doubleTapDistance()
    return math.max(MIN_DOUBLE_TAP_DISTANCE,
                    shortSide() * DOUBLE_TAP_DISTANCE_RATIO)
  end

  local function doubleTapMoveSlop()
    return math.max(MIN_DOUBLE_TAP_MOVE_SLOP,
                    shortSide() * DOUBLE_TAP_MOVE_SLOP_RATIO)
  end

  local function dist2(dx, dy)
    return dx * dx + dy * dy
  end

  local function directionFor(dx, dy)
    if math.abs(dx) >= math.abs(dy) then
      return dx < 0 and "left" or "right"
    end
    return dy < 0 and "up" or "down"
  end

  local function press(btn)
    if heldInput[btn] then return heldInput[btn] end
    local token = mod.input:press(game, btn)
    heldInput[btn] = token
    return token
  end

  local function release(btn)
    local token = heldInput[btn]
    if not token then return end
    heldInput[btn] = nil
    mod.input:release(token)
  end

  local function tap(btn)
    mod.input:tap(game, btn)
  end

  local function releaseDirection()
    if directionHeld then
      release(directionHeld)
    end
    directionOwner = nil
    directionHeld = nil
  end

  local function holdDirection(id, btn)
    if directionOwner == id and directionHeld == btn then return end
    releaseDirection()
    press(btn)
    directionOwner = id
    directionHeld = btn
  end

  local function flushPendingA()
    if pendingTap then
      tap("a")
      pendingTap = nil
    end
  end

  local function flushPendingAIfExpired()
    -- Never emit a deferred A while any touch is still down. A swipe can
    -- begin during the double-tap window; firing the older tap here makes
    -- that swipe appear to press A. The pending tap is either resolved once
    -- all touches are up or cancelled if the new touch turns into movement.
    if next(touches) ~= nil then return end
    if pendingTap and (now() - pendingTap.time) > DOUBLE_TAP_TIME then
      flushPendingA()
    end
  end

  local function completeTap(x, y, allowDoubleTap)
    local t = now()

    if pendingTap then
      local dt = t - pendingTap.time
      local dx = x - pendingTap.x
      local dy = y - pendingTap.y
      local maxD = doubleTapDistance()

      if allowDoubleTap and pendingTap.cleanDoubleTap
         and dt <= DOUBLE_TAP_TIME and dist2(dx, dy) <= maxD * maxD then
        pendingTap = nil
        tap("start")
        return
      end

      flushPendingA()
    end

    pendingTap = { time = t, x = x, y = y, cleanDoubleTap = allowDoubleTap == true }
  end

  local function autoAdvanceText()
    if speedHoldOwner == nil or not (game and game.stack) then return end

    local top = game.stack:top()
    if not top then return end

    local battle = battleInStack()

    -- Gen 2/Crystal has a different BattleState. Its narration is driven by
    -- messageTimer/Typer instead of Gen 1's shown/codes queue. Only advance
    -- non-choice narration and the post-level stats box; choices stay manual.
    if battle and top == battle and isGen2BattleState(battle) then
      local phase = battle.phase
      if phase == "stats-box" then
        tap("a")
        return
      end
      if (phase == "resolving" or phase == "intro" or phase == "shift-intro")
         and (tonumber(battle.messageTimer) or 0) > 0 then
        tap("a")
      end
      return
    end

    -- Gen 1 BattleState narration fast-forward.
    if battle and top == battle and battle.phase == "messages" then
      local item = battle.current

      -- Between queue rows, leave actions, animations, waits, drains and UI
      -- pushes to BattleState:updateQueue() itself.
      if not item then return end

      local cur = battle.shown and battle.shown[#battle.shown]
      local codes = battle.codes

      -- Choice-bearing text may be revealed quickly, but the ChoiceBox that
      -- BattleState pushes afterward remains manual.
      if item.choice then
        if cur and codes and #cur < #codes then
          while #cur < #codes do
            cur[#cur + 1] = codes[#cur + 1]
            battle.charIndex = (battle.charIndex or 0) + 1
          end
        end
        return
      end

      -- Native v0.1.38 CONT behavior on A/B:
      -- msgWaiting=nil; beginMsgLine().
      if battle.msgWaiting then
        battle.msgWaiting = nil
        battle:beginMsgLine()
        return
      end

      -- Native typewriter fills shown[#shown] from codes, two glyphs per
      -- fixed step. Hold mode finishes the current line immediately.
      if cur and codes and #cur < #codes then
        while #cur < #codes do
          cur[#cur + 1] = codes[#cur + 1]
          battle.charIndex = (battle.charIndex or 0) + 1
        end
        return
      end

      -- Current line is complete and more lines remain. The native queue
      -- either begins the next newline immediately or first enters
      -- msgWaiting for a CONT line. Hold mode proceeds immediately.
      if battle.lines and battle.lineIndex
         and battle.lineIndex < #battle.lines then
        battle.msgWaiting = nil
        battle:beginMsgLine()
        return
      end

      -- Final ordinary narration page. Native v0.1.38 sets msgPrompt=true,
      -- waits for A/B, then clears msgPrompt and current. Do that exact final
      -- transition directly while the hold is active.
      battle.msgPrompt = nil
      battle.current = nil
      return
    end

    -- Ordinary non-battle dialogue: 2X outside battles. Advance only actual
    -- TextBox waiting/done states; choices remain manual.
    if not top.isTextBox then return end
    if top.choice and top.done then return end
    if top.auto or top.stay then return end
    if top.waiting or top.done then
      tap("a")
    end
  end

  local function stopSpeedHold(id)
    if speedHoldOwner == nil then return end
    if id ~= nil and speedHoldOwner ~= id then return end

    if game then
      game.speedOverride = speedHoldOriginal
    end

    speedHoldOwner = nil
    speedHoldOriginal = nil
  end

  local function startSpeedHold(id)
    if speedHoldOwner ~= nil or not game then return false end

    speedHoldOwner = id
    speedHoldOriginal = game.speedOverride

    -- speedOverride is honored by both the current Gen 1 Game and Gen 2 Game2.
    -- It also restores cleanly without rewriting the player's saved speed.
    if battleInStack() then
      game.speedOverride = 4
    else
      game.speedOverride = 2
    end
    return true
  end

  local function updateLongPresses()
    if not gestureMode then return end

    local t = now()
    local slop = tapSlop()
    local slop2 = slop * slop

    for id, p in pairs(touches) do
      local dx = (p.x or p.x0) - p.x0
      local dy = (p.y or p.y0) - p.y0
      local stationary = not p.movedBeyondTap and dist2(dx, dy) <= slop2
      local heldFor = p.pressedAt and (t - p.pressedAt) or 0

      if stationary and not p.claimed and heldFor >= HOLD_B_DELAY then
        pendingTap = nil
        p.claimed = true

        if p.secondTapCandidate then
          p.action = "select"
          tap("select")
        else
          p.action = "back_hold"
          press("b")
        end
      elseif stationary and p.action == "back_hold"
             and speedHoldOwner == nil and heldFor >= HOLD_SPEED_DELAY then
        -- Only leave B-hold mode if fast-forward actually initializes.
        -- This avoids losing the B release path on unusual engine states.
        if startSpeedHold(id) then
          release("b")
          p.action = "speed"
        end
      end
    end
  end

  local function clearGestureState()
    releaseDirection()
    stopSpeedHold()
    for _, p in pairs(touches) do
      if p.action == "back_hold" then
        release("b")
      end
    end
    touches = {}
    pendingTap = nil
  end

  local function gestureModeAllowed()
    if not (game and game.stack) then
      return false
    end

    local top = game.stack:top()

    -- Always hand the Mod Manager back to Gen1Recomp so its own touch
    -- navigation, option editing, and B-to-exit behavior remain intact.
    if top and top.screenId == "ManagerState" then
      return false
    end

    -- Gen 2/Crystal's normal overworld is not a stack state. Game2 clears the
    -- stack before startWorld(), then drives the map through game.world while
    -- game.phase == "play". Treat that empty-stack state as normal gameplay.
    if not top then
      return game.phase == "play"
         and game.world ~= nil
         and game.world.map ~= nil
    end

    -- Everywhere else -- boot splash, intro, title screen, title/menu
    -- flow, and gameplay -- gestures are active from the moment the ROM
    -- starts:
    --   Tap -> A
    --   Tap-and-hold -> B
    --   Long hold -> Fast Forward
    --   Double tap -> Start
    --   Tap-release then second tap-hold -> Select
    --   Swipe any direction -> D-pad
    return true
  end

  local function syncMode()
    local shouldGesture = gestureModeAllowed()

    if shouldGesture == gestureMode then
      return gestureMode
    end

    clearGestureState()
    gestureMode = shouldGesture

    if game.touchControls then
      game.touchControls:reset()

      local top = game.stack and game.stack:top()
      local inManager = top and top.screenId == "ManagerState"

      if inManager then
        -- Mod Manager is the only place where the stock touch pad is shown.
        -- It needs LEFT/RIGHT/A/B for option editing and leaving the screen.
        game.touchControls.active = true
        if game.touchControls.enabled ~= nil then
          game.touchControls.enabled = true
        end
        if game.touchControls.controllerHidden ~= nil then
          game.touchControls.controllerHidden = false
        end
      else
        -- Keep the stock overlay hidden from ROM boot onward:
        -- splash, intro movie, title, gameplay, battle, and all normal menus.
        game.touchControls.active = false
        if game.touchControls.enabled ~= nil then
          game.touchControls.enabled = false
        end
        if game.touchControls.controllerHidden ~= nil then
          game.touchControls.controllerHidden = true
        end
      end
    end

    if gestureMode then
      mod.log:info("TM35 Metronome: gameplay mode enabled")
    else
      mod.log:info("TM35 Metronome: stock engine touch mode enabled")
    end

    return gestureMode
  end

  local function gesturePressed(id, x, y)
    flushPendingAIfExpired()

    local secondTapCandidate = false
    if pendingTap then
      local t = now()
      local dt = t - pendingTap.time
      local dx = x - pendingTap.x
      local dy = y - pendingTap.y
      local maxD = doubleTapDistance()
      secondTapCandidate = pendingTap.cleanDoubleTap == true
        and dt <= DOUBLE_TAP_TIME
        and dist2(dx, dy) <= maxD * maxD
    end

    touches[id] = {
      x0 = x, y0 = y,
      x = x, y = y,
      claimed = false,
      movedBeyondTap = false,
      action = nil,
      pressedAt = now(),
      secondTapCandidate = secondTapCandidate,
      maxTravel2 = 0,
    }
  end

  local function gestureMoved(id, x, y)
    local p = touches[id]
    if not p then return end

    p.x, p.y = x, y
    local dx, dy = x - p.x0, y - p.y0
    local travel2 = dist2(dx, dy)
    if travel2 > (p.maxTravel2 or 0) then p.maxTravel2 = travel2 end

    -- Tap recognition is one-way: once this touch moves farther than tap
    -- slop, it can never become A later, even if it has not yet crossed a
    -- directional swipe threshold. Also cancel any older deferred A so
    -- no A can mature while this swipe is happening.
    local slop = tapSlop()
    if not p.movedBeyondTap and dist2(dx, dy) > slop * slop then
      p.movedBeyondTap = true
      pendingTap = nil
    end

    if not p.claimed then
      local threshold = swipeThreshold()
      if dist2(dx, dy) >= threshold * threshold then
        -- Any directional swipe cancels tap recognition entirely.
        pendingTap = nil
        p.claimed = true
        local dir = directionFor(dx, dy)
        p.action = "direction"
        p.direction = dir
        holdDirection(id, dir)
      end
      return
    end

    if p.action == "direction" then
      local newDir = directionFor(dx, dy)
      local threshold = swipeThreshold() * 1.35
      if newDir ~= p.direction and dist2(dx, dy) >= threshold * threshold then
        p.direction = newDir
        holdDirection(id, newDir)
      end
    end
  end

  local function gestureReleased(id, x, y)
    local p = touches[id]
    if not p then return end
    touches[id] = nil

    local dx, dy = x - p.x0, y - p.y0
    local travel2 = dist2(dx, dy)
    if travel2 > (p.maxTravel2 or 0) then p.maxTravel2 = travel2 end

    -- Release whichever D-pad direction this touch owns.
    if directionOwner == id then
      releaseDirection()
    elseif p.action == "back_hold" then
      release("b")
    elseif p.action == "speed" and speedHoldOwner == id then
      stopSpeedHold(id)
    end

    if p.claimed then return end

    -- Any touch that ever exceeded tap slop is permanently ineligible for A.
    -- It may still resolve to a directional swipe below.
    if p.movedBeyondTap then
      local threshold = swipeThreshold()
      if dist2(dx, dy) >= threshold * threshold then
        local dir = directionFor(dx, dy)
        pendingTap = nil
        tap(dir)
      end
      return
    end

    local threshold = swipeThreshold()
    if dist2(dx, dy) >= threshold * threshold then
      local dir = directionFor(dx, dy)
      pendingTap = nil
      tap(dir)
      return
    end

    local slop = tapSlop()
    if dist2(dx, dy) <= slop * slop then
      local dblSlop = doubleTapMoveSlop()
      local cleanDoubleTap = (p.maxTravel2 or 0) <= dblSlop * dblSlop
      completeTap(x, y, cleanDoubleTap)
    end
  end

  local function setStockTouchMode(inManager)
    if not (game and game.touchControls) then return end

    game.touchControls:reset()
    if inManager then
      game.touchControls.active = true
      if game.touchControls.enabled ~= nil then
        game.touchControls.enabled = true
      end
      if game.touchControls.controllerHidden ~= nil then
        game.touchControls.controllerHidden = false
      end
    else
      game.touchControls.active = false
      if game.touchControls.enabled ~= nil then
        game.touchControls.enabled = false
      end
      if game.touchControls.controllerHidden ~= nil then
        game.touchControls.controllerHidden = true
      end
    end
  end

  local function install(g)
    game = g
    clearGestureState()

    -- game.ready is emitted before the Gen 2 boot stack is populated. Keep the
    -- stock pad out of the way immediately; screen.pushed/input.step will then
    -- keep the mode synchronized with the live top state.
    setStockTouchMode(false)
    gestureMode = false
    syncMode()

    mod.log:info(
      "TM35 Metronome v2.61 installed; gestures enabled from title screen onward"
    )
  end

  -- Current Gen1Recomp exposes gameplay pointers through one generation-neutral
  -- hook. TouchControls gets first refusal, so syncMode keeps it disabled during
  -- gesture mode and restores it only in the Mod Manager.
  mod.hooks:wrap("input.pointer", function(next, g, ev)
    if game == nil then game = g end
    if not ev then return next(g, ev) end

    local enabled = syncMode()
    if not enabled then
      return next(g, ev)
    end

    if ev.source == "mouse" and ev.phase == "pressed"
       and ev.button ~= nil and ev.button ~= 1 then
      return next(g, ev)
    end

    if ev.phase == "pressed" then
      gesturePressed(ev.id, ev.x, ev.y)
    elseif ev.phase == "moved" then
      gestureMoved(ev.id, ev.x, ev.y)
    elseif ev.phase == "released" then
      gestureReleased(ev.id, ev.x, ev.y)
    elseif ev.phase == "cancelled" then
      local p = touches[ev.id]
      if p then
        touches[ev.id] = nil
        if directionOwner == ev.id then releaseDirection() end
        if p.action == "back_hold" then release("b") end
        if p.action == "speed" and speedHoldOwner == ev.id then
          stopSpeedHold(ev.id)
        end
      end
      pendingTap = nil
    end

    return true
  end)

  -- Runs immediately before the engine promotes queued input edges, so actions
  -- generated here are visible to the same logic step on both generations.
  mod.hooks:wrap("input.step", function(next, g, dt)
    if game == nil then game = g end
    syncMode()
    if gestureMode then
      updateLongPresses()
      autoAdvanceText()
      flushPendingAIfExpired()
    end
    return next(g, dt)
  end)

  -- Switch the stock touch pad immediately when the Manager is pushed/popped,
  -- avoiding a one-frame window where it could capture the first touch.
  mod.events:on("screen.pushed", function()
    if game then syncMode() end
  end)

  mod.events:on("screen.popped", function()
    if game then syncMode() end
  end)

  mod.events:on("game.ready", function(ev)
    if ev and ev.game then
      install(ev.game)
    end
  end)
end
