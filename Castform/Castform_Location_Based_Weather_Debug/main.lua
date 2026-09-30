-- Castform: Location Based Weather Debug v1.0
-- Target: Gen1Recomp v0.2.64
-- Emerald: real-world weather for your location drives the game's weather,
-- rain sounds and lightning. Location and current weather show on the mod screen.

return function(mod)
  local Weather = require("src.core.game3.weather")
  local Map = require("src.core.game3.map")
  local Dataset = require("src.core.game3.dataset")
  local S={phase="location",request=nil,city="Locating...",region="",country="",lat=nil,lon=nil,temp=nil,apparent=nil,wind=nil,windDir=nil,gust=nil,humidity=nil,precip=nil,rain=nil,showers=nil,snow=nil,code=nil,error=nil,lastWeather=0,nextRetry=0,gameWeather=nil,lastAppliedWeather=nil,lastWeatherSync=0,castformOwnsWeather=false,scriptBlockSeq=nil,audioRetryUntil=0,currentMapId="Unknown",indoorRainLatched=false,indoorRainLatchMap=nil,audioStatus="idle"}
  local REFRESH,RETRY,WEATHER_SYNC=30,30,1
  -- The conditions the mod acts on: the real Open-Meteo data for your location.
  local function wx(k) return S[k] end
  local function stringField(body,key)
    if type(body)~="string" then return nil end
    return body:match('"'..key..'"%s*:%s*"([^"]*)"')
  end
  local function numberField(body,key)
    if type(body)~="string" then return nil end
    return tonumber(body:match('"'..key..'"%s*:%s*(-?[%d%.]+)'))
  end
  local function weatherName(c)
    c=tonumber(c)
    if c==0 then return "Clear sky" elseif c==1 then return "Mainly clear" elseif c==2 then return "Partly cloudy" elseif c==3 then return "Overcast"
    elseif c==45 or c==48 then return "Fog" elseif c==51 or c==53 or c==55 then return "Drizzle" elseif c==56 or c==57 then return "Freezing drizzle"
    elseif c==61 or c==63 or c==65 then return "Rain" elseif c==66 or c==67 then return "Freezing rain"
    elseif c==71 or c==73 or c==75 or c==77 then return "Snow" elseif c==80 or c==81 or c==82 then return "Rain showers"
    elseif c==85 or c==86 then return "Snow showers" elseif c==95 then return "Thunderstorm" elseif c==96 or c==99 then return "Thunderstorm + hail" end
    return c and ("Weather code "..tostring(c)) or "Weather unavailable"
  end
  local function release() if S.request then mod.fetch:release(S.request); S.request=nil end end
  local startLocation,startWeather,applyGameWeather,markIndoorRainForDestination
  startLocation=function()
    if not mod.fetch:available() then S.error="Network fetch unavailable"; S.nextRetry=love.timer.getTime()+RETRY; return end
    release(); S.phase="location"; S.error=nil
    local h,e=mod.fetch:get("https://ipwho.is/"); if not h then S.error=e or "Location lookup failed"; S.nextRetry=love.timer.getTime()+RETRY; return end
    S.request=h
  end
  startWeather=function()
    if not S.lat or not S.lon then return startLocation() end
    release(); S.phase="weather"; S.error=nil
    local url=("https://api.open-meteo.com/v1/forecast?latitude=%.5f&longitude=%.5f&current=temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,rain,showers,snowfall,weather_code,wind_speed_10m,wind_direction_10m,wind_gusts_10m,cloud_cover,visibility&temperature_unit=fahrenheit&wind_speed_unit=mph&precipitation_unit=inch"):format(S.lat,S.lon)
    local h,e=mod.fetch:get(url); if not h then S.error=e or "Weather lookup failed"; S.nextRetry=love.timer.getTime()+RETRY; return end
    S.request=h
  end
  local function poll()
    local now=love.timer.getTime()
    if not S.request then
      if S.lat and now-S.lastWeather>=REFRESH then startWeather() elseif S.error and now>=S.nextRetry then if S.lat then startWeather() else startLocation() end end
      return
    end
    local p=mod.fetch:poll(S.request); if not p or p.status=="pending" then return end
    release()
    if p.status~="ok" then S.error=(p and p.err) or ("Network request failed ("..tostring(p and p.status or "unknown")..")"); S.nextRetry=now+RETRY; return end
    if S.phase=="location" then
      local b=p.body or ""; local lat,lon=numberField(b,"latitude"),numberField(b,"longitude")
      if not lat or not lon then S.error="Unexpected location response"; S.nextRetry=now+RETRY; return end
      S.lat,S.lon=lat,lon; S.city=stringField(b,"city") or "Unknown city"; S.region=stringField(b,"region") or ""; S.country=stringField(b,"country") or ""; startWeather()
    else
      local b=p.body or ""; S.temp=numberField(b,"temperature_2m"); S.apparent=numberField(b,"apparent_temperature"); S.code=numberField(b,"weather_code"); S.wind=numberField(b,"wind_speed_10m"); S.windDir=numberField(b,"wind_direction_10m"); S.gust=numberField(b,"wind_gusts_10m"); S.humidity=numberField(b,"relative_humidity_2m"); S.precip=numberField(b,"precipitation"); S.rain=numberField(b,"rain"); S.showers=numberField(b,"showers"); S.snow=numberField(b,"snowfall"); S.cloud=numberField(b,"cloud_cover"); S.visibility=numberField(b,"visibility")
      if S.temp==nil then S.error="Unexpected weather response"; S.nextRetry=now+RETRY else S.error=nil; S.lastWeather=now; applyGameWeather(true); if markIndoorRainForDestination then markIndoorRainForDestination(nil) end end
    end
  end
  local function raining()
    return (wx("rain") or 0)>0 or (wx("showers") or 0)>0 or (wx("precip") or 0)>0 and (wx("snow") or 0)<=0
  end
  local function emeraldWeatherId()
    local c=tonumber(wx("code"))
    -- Real heat becomes Emerald's intense sunlight. Keep active precipitation,
    -- storms, snow and fog more specific than temperature.
    local wetCode = c==51 or c==53 or c==55 or c==56 or c==57 or c==61 or c==63 or c==65 or c==66 or c==67 or c==71 or c==73 or c==75 or c==77 or c==80 or c==81 or c==82 or c==85 or c==86 or c==95 or c==96 or c==99 or c==45 or c==48
    if (tonumber(wx("temp")) or -999)>90 and not wetCode and not raining() then return 12,"Drought / intense sunlight" end
    if c==96 or c==99 then return 7,"Volcanic ash (hail)" end
    if c==95 then return 5,"Rain + thunderstorm" end
    if c==65 or c==82 then return 13,"Downpour" end
    if c==61 or c==63 or c==66 or c==67 or c==80 or c==81 or c==51 or c==53 or c==55 or c==56 or c==57 then return 3,"Rain" end
    if c==71 or c==73 or c==75 or c==77 or c==85 or c==86 or (wx("snow") or 0)>0 then return 4,"Snow" end
    if c==45 or c==48 then return 6,"Fog" end
    -- Dry sky: low visibility (under 1 km, WMO fog) is fog even when the
    -- weather code says clear; otherwise cloud cover picks the sky.
    local vis=tonumber(wx("visibility"))
    if vis and vis<1000 and not raining() then return 6,"Fog (low visibility)" end
    if c==0 or c==1 or c==2 or c==3 then
      local cloud=tonumber(wx("cloud"))
      if cloud then
        if cloud>=85 then return 11,"Shade / overcast" end
        if cloud>=20 then return 1,"Sunny / clear clouds" end
        return 2,"Sunny"
      end
      if c==3 then return 11,"Shade / overcast" end
      if c==0 then return 2,"Sunny" end
      return 1,"Sunny / clear clouds"
    end
    if raining() then
      if (wx("precip") or 0)>=0.25 then return 13,"Downpour" end
      return 3,"Rain"
    end
    return 0,"None"
  end
  local function currentMapType()
    local def=Map.currentDef and Map.currentDef()
    return def and tonumber(def.mapType) or nil
  end
  local function mapName()
    return (S.currentMapId and S.currentMapId~="") and tostring(S.currentMapId) or "Unknown"
  end
  local function underwater()
    return currentMapType()==5
  end
  local function outdoors()
    local mt=currentMapType()
    return mt~=nil and mt~=5 and Dataset.isOutdoorMapType(mt)
  end
  local function indoors()
    local mt=currentMapType()
    -- Emerald's ordinary indoor classifications are 4, 8 and 9 in the
    -- dataset; use "not outdoor" as a transition-safe fallback, but never
    -- treat underwater as indoors.
    return mt~=nil and mt~=5 and not Dataset.isOutdoorMapType(mt)
  end
  local function scriptControlsWeather()
    local pin=Weather._scriptSaved
    if pin~=nil then
      S.scriptBlockSeq=Weather._applySeq
      return true
    end
    -- If a script changed the weather/apply sequence since Castform last owned
    -- it, yield until a map transition clears/replaces that scripted state.
    if S.scriptBlockSeq~=nil and Weather._applySeq==S.scriptBlockSeq then return true end
    return false
  end
  -- The weather Castform wants right now (partly cloudy drifts: clouds drift
  -- past, so over a 45 s cycle the sky is cloudy for (cloud cover)% of the
  -- time and clear for the rest, timed from the latest cloud cover reading).
  local function targetWeatherId(now)
    local id=emeraldWeatherId()
    if id==1 then
      -- Partly cloudy = overcast (shade, 11) with a 5-10 s clear break now and
      -- then; overcast lasts 15-30 s between breaks. Changes fade (seamless).
      if S.pcNext==nil or now>=S.pcNext then
        if S.pcClear==nil then S.pcClear=false else S.pcClear=not S.pcClear end
        if S.pcClear then S.pcNext=now+5+math.random()*5 else S.pcNext=now+15+math.random()*15 end
      end
      id=S.pcClear and 2 or 11
    else
      S.pcNext=nil
      S.pcClear=nil
    end
    return id
  end
  -- Emerald applies the map header's weather while the map loads (inside the
  -- black screen). Substitute Castform's weather right there, so the real
  -- weather is already in place when the screen fades in instead of the header
  -- weather showing first and Castform correcting it a moment later. Script
  -- pinned weather keeps priority, exactly as in the engine's own check.
  local origApply=Weather._castformOrigApply or Weather.apply
  Weather._castformOrigApply=origApply
  Weather.apply=function(id,opts)
    local target=nil
    if S.temp~=nil and outdoors() and not underwater() then
      local pin=Weather._scriptSaved
      local Mp=package.loaded["src.core.game3.map"]
      local scripted=pin~=nil and pin.seq==Weather._applySeq and pin.map==(Mp and Mp.current)
      if not scripted then
        local ok,t=pcall(targetWeatherId,love.timer.getTime())
        if ok then target=t end
      end
    end
    return origApply(target or id,opts)
  end
  -- Indoor rain uses the game's own rain sound effect (Emerald SE_RAIN) instead
  -- of a separate audio Source. Emerald's outdoor rain loop lives on sound
  -- channel SE3, and the engine only stops it on a warp when SE1/SE2 happen to
  -- be busy, so it leaks into the first room after a door but is cut on stairs.
  -- Re-starting the same sound on every indoor map entry makes it consistent.
  local Audio=require("src.core.game3.audio")
  local SE=require("src.core.game3.se_ids")
  local function liveRainNow()
    local c=tonumber(wx("code"))
    local rainCode=c and ((c>=51 and c<=67) or (c>=80 and c<=82) or c==95 or c==96 or c==99)
    return raining() or rainCode or false
  end
  local function isRainId(id) return id==3 or id==5 or id==13 end
  -- Indoors, play the same rain sound Emerald uses outside for that intensity.
  local function rainSeFor(weatherId)
    if weatherId==13 and SE.SE_DOWNPOUR then return SE.SE_DOWNPOUR end
    if weatherId==5 and SE.SE_THUNDERSTORM then return SE.SE_THUNDERSTORM end
    return SE.SE_RAIN
  end
  local RAIN_STOP_FOR={}
  local function rainSeIds()
    RAIN_STOP_FOR[SE.SE_RAIN]=SE.SE_RAIN_STOP
    if SE.SE_DOWNPOUR then RAIN_STOP_FOR[SE.SE_DOWNPOUR]=SE.SE_DOWNPOUR_STOP end
    if SE.SE_THUNDERSTORM then RAIN_STOP_FOR[SE.SE_THUNDERSTORM]=SE.SE_THUNDERSTORM_STOP end
    return RAIN_STOP_FOR
  end
  local function playingRainSe()
    for id in pairs(rainSeIds()) do
      if Audio.isSePlaying(id) then return id end
    end
    return nil
  end
  -- Drizzle (WMO 51-57) is a light rain: play the rain sound softer.
  local function isDrizzle()
    local c=tonumber(wx("code"))
    return c~=nil and c>=51 and c<=57
  end
  -- Basements and caves are too far underground to hear rain.
  local function belowGround()
    if currentMapType()==4 then return true end
    local id=string.upper(tostring(S.currentMapId or ""))
    return id:find("_B%dF")~=nil or id:find("BASEMENT")~=nil
  end
  -- Muffle the engine's rain Source with a low-pass filter while indoors. The
  -- engine caches/clones SE Sources and never resets filters, so the filter is
  -- cleared from the live source and every cached one on any other destination.
  local function setRainFilter(src,on)
    if not (src and src.setFilter) then return end
    pcall(function()
      if on then src:setFilter({type="lowpass",volume=0.6,highgain=0.1}) else src:setFilter() end
    end)
  end
  local function muffleRain()
    setRainFilter(Audio._seByPlayer and Audio._seByPlayer[3],true)
  end
  local function unmuffleRain()
    setRainFilter(Audio._seByPlayer and Audio._seByPlayer[3],false)
    for _,entry in pairs(Audio._seSrcCache or {}) do setRainFilter(entry.src,false) end
  end
  -- The weather the engine is heading to (its nextWeather), not the one it is
  -- still fading out of.
  local function engineNextWeather()
    local E=Weather.rseEngine and Weather.rseEngine()
    local st=E and E.state
    if st and st.nextWeather~=nil then return st.nextWeather end
    return Weather.get()
  end
  -- End the rain loop the way the game intends: play its matching *_STOP sound
  -- (a short fade). Emerald's own trigger for this only fires when some other
  -- sound happens to be busy, so the rain loop could otherwise run on.
  local function endRainSe(muffled)
    local playing=playingRainSe()
    if not playing then return end
    local stopId=RAIN_STOP_FOR[playing]
    if stopId then
      pcall(Audio.playSe,stopId)
      if muffled then muffleRain() end
    else
      pcall(Audio.stopSe,playing)
    end
  end
  -- Runs every frame: keep the rain volume right (soft for drizzle) and end the
  -- rain loop the moment the engine's weather is no longer rain.
  local function syncRainAudio()
    if not playingRainSe() then return end
    local src=Audio._seByPlayer and Audio._seByPlayer[3]
    if src then
      local want=isDrizzle() and 0.35 or 1
      local ok,cur=pcall(src.getVolume,src)
      if ok and cur and math.abs(cur-want)>0.001 then pcall(src.setVolume,src,want) end
    end
    if not S.indoorRainLatched then
      local nextW=engineNextWeather()
      if nextW~=nil and not isRainId(nextW) then endRainSe(false) end
    end
  end
  markIndoorRainForDestination=function(ev)
    if ev and ev.mapId then S.currentMapId=tostring(ev.mapId) end
    if liveRainNow() and indoors() and not underwater() and not belowGround() then
      local desired=rainSeFor(emeraldWeatherId())
      if not Audio.isSePlaying(desired) then pcall(Audio.playSe,desired) end
      muffleRain()
      S.indoorRainLatched=true
      S.indoorRainLatchMap=S.currentMapId
      S.audioStatus="Emerald rain SE "..mapName()
    else
      local mustEnd=underwater() or belowGround() or (not liveRainNow() and (S.indoorRainLatched or indoors()))
      if mustEnd and playingRainSe() then
        endRainSe(indoors() and not underwater() and not belowGround())
      else
        unmuffleRain()
      end
      S.indoorRainLatched=false
      S.indoorRainLatchMap=nil
      S.audioStatus="off"
    end
  end

  -- Indoor lightning. In Emerald the thunderstorm is two layers: rain (sprites,
  -- rain loop, dark color map) and lightning (a palette flash to color map 19
  -- plus SE_THUNDER/SE_THUNDER2 claps). Indoors the engine runs no weather, so
  -- Castform fires its own flashes with the engine's own timings: a 6-12 s wait,
  -- 1-2 short flashes, sometimes a long one that fades out, then a thunder clap.
  -- Screen goes back to normal (map 0), no rain sprites are drawn.
  -- Half strength: color map 11 is halfway between the dark rain map (3) and the
  -- full-bright lightning map (19) the game uses outdoors.
  local LF_FLASH=11
  local function liveStormNow()
    local c=tonumber(wx("code"))
    return c==95 or c==96 or c==99
  end
  local function lightningEngine()
    local E=Weather.rseEngine and Weather.rseEngine()
    return E and E.state and E.applyColorMapIfIdle and E
  end
  local function lightningEnd()
    local E=lightningEngine()
    if E and S.lfFlashing and E.state.colorMapIndex==LF_FLASH and E.state.currWeather~=5 then
      E.applyColorMapIfIdle(0)
    end
    S.lfFlashing=false; S.lfStep=nil; S.lfThunder=nil
  end
  local function lightningClap(frames)
    S.lfThunder=frames
  end
  local function syncIndoorLightning()
    local now=love.timer.getTime()
    local dt=math.min(0.25,now-(S.lfLast or now)); S.lfLast=now
    local E=lightningEngine()
    local active=E and liveStormNow() and indoors() and not underwater() and not belowGround()
      and E.state.currWeather~=5 and E.state.nextWeather~=5
    if not active then
      if S.lfStep or S.lfFlashing then lightningEnd() end
      return
    end
    local f=dt*60
    if S.lfThunder then
      S.lfThunder=S.lfThunder-f
      if S.lfThunder<=0 then
        S.lfThunder=nil
        pcall(Audio.playSe,(math.random(2)==1) and SE.SE_THUNDER or SE.SE_THUNDER2)
      end
    end
    if not S.lfStep then S.lfStep="wait"; S.lfTimer=360+math.random(0,359); S.lfLong=math.random(0,1) end
    S.lfTimer=S.lfTimer-f
    if S.lfTimer>0 then return end
    local st=S.lfStep
    if st=="wait" then
      S.lfShorts=math.random(1,2); S.lfStep="flash"; S.lfTimer=0
    elseif st=="flash" then
      E.applyColorMapIfIdle(LF_FLASH); S.lfFlashing=true
      if S.lfLong==0 and S.lfShorts==1 then lightningClap(math.random(0,19)) end
      S.lfTimer=6+math.random(0,2); S.lfStep="flashoff"
    elseif st=="flashoff" then
      E.applyColorMapIfIdle(0); S.lfFlashing=false
      S.lfShorts=S.lfShorts-1
      if S.lfShorts>0 then S.lfTimer=60+math.random(0,15); S.lfStep="flash"
      elseif S.lfLong==0 then S.lfStep="wait"; S.lfTimer=360+math.random(0,359); S.lfLong=math.random(0,1)
      else S.lfTimer=60+math.random(0,15); S.lfStep="long" end
    elseif st=="long" then
      lightningClap(math.random(0,99)); E.applyColorMapIfIdle(LF_FLASH); S.lfFlashing=true
      S.lfTimer=30+math.random(0,15); S.lfStep="longfade"
    elseif st=="longfade" then
      -- gradual fade 19 -> 0 (same shape as the engine's long bolt)
      if E.applyColorMapIfIdleGradual then E.applyColorMapIfIdleGradual(LF_FLASH,0,5) else E.applyColorMapIfIdle(0) end
      S.lfFlashing=false; S.lfStep="wait"; S.lfTimer=360+math.random(0,359); S.lfLong=math.random(0,1)
    end
  end

  mod.events:on("map.entered",function(ev)
    markIndoorRainForDestination(ev)
    applyGameWeather(true)
  end)

  -- Only touches the engine when its target weather really differs. Re-applying
  -- the same weather every second restarts the engine's fade (setNextWeather
  -- resets finishStep), which is what made weather changes crawl or stall.
  -- instant=true swaps the weather immediately instead of fading.
  applyGameWeather=function(force,instant)
    if S.temp==nil then return end
    local now=love.timer.getTime()
    if not force and now-S.lastWeatherSync<WEATHER_SYNC then return end
    S.lastWeatherSync=now
    local id=targetWeatherId(now)
    S.gameWeather=id
    if underwater() then
      S.castformOwnsWeather=false
      return
    end
    if not outdoors() then
      S.castformOwnsWeather=false
      return
    end
    if scriptControlsWeather() then
      S.castformOwnsWeather=false
      return
    end
    if engineNextWeather()~=id or (instant and Weather.get()~=id) then
      local ok,err=pcall(origApply,id,{seamless=not instant})
      if ok then
        S.lastAppliedWeather=id
        S.castformOwnsWeather=true
        S.scriptBlockSeq=nil
      else
        S.error="Game weather sync failed: "..tostring(err)
      end
    else
      S.castformOwnsWeather=true
    end
  end
  local function infoText()
    local loc
    if S.lat then
      local t={}
      if S.city~="" then t[#t+1]=S.city end
      if S.region~="" then t[#t+1]=S.region end
      if #t==0 and S.country~="" then t[1]=S.country end
      loc=table.concat(t,", "):gsub("[\128-\255]","")
    else
      loc=S.error and "Unavailable" or "Locating..."
    end
    local wxt
    if S.temp~=nil then
      wxt=weatherName(S.code)..", "..math.floor(S.temp+0.5).."F"
    else
      wxt=S.error and "Unavailable" or "Loading..."
    end
    return "Location: "..loc.."\nWeather: "..wxt
  end
  mod.hooks:wrap("render.hud",function(next,game,viewport)
    next(game,viewport)
    local g=love.graphics
    local text=infoText()
    g.push("all")
    g.setColor(.035,.055,.075,.78); g.rectangle("fill",16,16,260,44,6,6)
    g.setColor(1,1,1,.6); g.rectangle("line",16.5,16.5,259,43,6,6)
    g.setColor(1,1,1,1); g.print(text,26,22)
    g.pop()
  end)
  mod.hooks:wrap("core.update",function(next,game,dt)
    next(game,dt)
    poll()
    applyGameWeather(false)
    syncRainAudio()
    syncIndoorLightning()
  end)
  startLocation()
end
