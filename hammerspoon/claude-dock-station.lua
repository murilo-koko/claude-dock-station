-- Claude Dock Station — Hammerspoon engine + shells.
local M = {}
local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
package.path = package.path .. ";" .. here .. "?.lua"
local core = dofile(here .. "core.lua")

local DOCK_HOME = os.getenv("HOME") .. "/.claude-dock-station"
local STATE_DIR = DOCK_HOME .. "/state"
local CONFIG    = DOCK_HOME .. "/config.json"
local RECENTS   = DOCK_HOME .. "/recents.json"

local DEFAULTS = {
  hotkey = { mods = {"cmd","shift"}, key = "space" },
  shells = { overlay = true, menubar = true, view = "none" },  -- view: one on-screen shell at a time (none|panel|mosaic|bar)
  screen = "main",                                             -- single monitor shared by the on-screen view
  panel = { corner = "topRight", width = 300, height = 420 },
  mosaic = { edge = "top", columns = 0, tile = 150, max = 0 },  -- columns 0 = auto; max 0 = all
  bar    = { edge = "bottom", height = 52, max = 0 },           -- edge top|bottom; max 0 = all
  thumbnails = true, interval_secs = 1, theme = "auto",
  host_app = "Code", stale_secs = 900,
  needs_after_secs = 30,         -- a tool call stuck this long (permission prompt) -> ⚠️ needs you
  remotes = {},                  -- SSH hosts whose Claude state to pull into the deck
  remote_interval_secs = 3,      -- how often to poll remotes (SSH is slower than the render tick)
}

function M.loadConfig()
  local raw = io.open(CONFIG, "r")
  local loaded = {}
  if raw then
    local txt = raw:read("a"); raw:close()
    local ok, decoded = pcall(hs.json.decode, txt)
    if ok and type(decoded) == "table" then loaded = decoded end
  end
  M.config = core.merge_config(DEFAULTS, loaded)
  core.migrate_view(M.config)   -- old 3-shell config -> single shells.view + shared screen
  return M.config
end

local function readStates()
  local states = {}
  -- hs.fs.dir raises if STATE_DIR is missing; guard so a reset/uninstalled
  -- state dir degrades to an empty deck instead of a per-tick crash.
  local ok, iter, dir_obj, first = pcall(hs.fs.dir, STATE_DIR)
  if not ok then return states end
  for file in iter, dir_obj, first do
    if file:match("%.json$") then
      local f = io.open(STATE_DIR .. "/" .. file, "r")
      if f then
        local txt = f:read("a"); f:close()
        local ok, s = pcall(hs.json.decode, txt)
        if ok and type(s) == "table" and s.session_id then states[#states+1] = s end
      end
    end
  end
  return states
end

local function vscodeWindows()
  local out = {}
  local app = hs.application.find(M.config.host_app)
  if app then
    for _, w in ipairs(app:allWindows()) do
      out[#out+1] = { title = w:title(), id = w:id(), _win = w }
    end
  end
  return out
end

function M.buildDeck(want_thumbs)
  if want_thumbs == nil then want_thumbs = true end
  local states = readStates()
  -- merge in remote sessions pulled asynchronously from configured SSH hosts
  for _, arr in pairs(M.remoteCache or {}) do
    for _, s in ipairs(arr) do states[#states+1] = s end
  end
  local windows = vscodeWindows()
  local cards = core.build_deck(states, windows, os.time(),
    { stale_secs = M.config.stale_secs, needs_after = M.config.needs_after_secs })
  for _, c in ipairs(cards) do
    if c.window and want_thumbs and M.config.thumbnails then
      local w = c.window._win
      local ok, img = pcall(function() return w:snapshot() end)
      -- Scale to card size BEFORE encoding: encoding a full-res window PNG to a
      -- base64 data URI costs ~800ms each; at 360px it's ~10ms. This is what kept
      -- the render tick from blocking the main thread (and delaying clicks).
      if ok and img then c.thumb = img:setSize({ w = 360, h = 225 }):encodeAsURLString() end
    end
  end
  return cards
end

function M.focus(session_id)
  for _, c in ipairs(M.buildDeck(false)) do
    if c.session_id == session_id and c.window and c.window._win then
      c.window._win:focus(); return true
    end
  end
  return false
end

function M.reload()
  local old_interval = M.config and M.config.interval_secs
  M.loadConfig()
  if M.applyShells then M.applyShells() end
  if M.timer and old_interval ~= M.config.interval_secs then
    M.timer:stop()
    M.timer = hs.timer.doEvery(M.config.interval_secs, function()
      if M.tick then M.tick() end
    end)
  end
end

local UI = here .. "ui/"

local function ageLabel(secs)
  if secs < 60 then return "agora" end
  if secs < 3600 then return math.floor(secs/60) .. "min" end
  return math.floor(secs/3600) .. "h"
end

local function deckForJS(want_thumbs)
  local cards = M.buildDeck(want_thumbs ~= false)
  local slim = {}
  for _, c in ipairs(cards) do
    slim[#slim+1] = { session_id=c.session_id, project=c.project, badge=c.badge,
                      detail=c.detail, age=ageLabel(c.age_secs), thumb=c.thumb, host=c.host, title=c.title }
  end
  return slim   -- views show LIVE sessions only; recents live in the menu bar
end

-- Recents store keyed by WINDOW (host+cwd -> {cwd,project,host,title,last_seen}) persisted to
-- recents.json so closed windows survive a Hammerspoon restart. Observed-only: no crawl.
function M.loadRecents()
  M.recents = {}
  local f = io.open(RECENTS, "r")
  if f then
    local txt = f:read("a"); f:close()
    local ok, d = pcall(hs.json.decode, txt)
    if ok and type(d) == "table" then
      -- re-key by window (older files were keyed by session_id) and dedup, newest wins
      for _, e in pairs(d) do
        if e.cwd and e.cwd ~= "" then
          local ws = core.workspace_path(e.cwd, e.project)
          local k = core.window_key(e.host, ws)
          local ex = M.recents[k]
          if not ex or (e.last_seen or 0) > (ex.last_seen or 0) then
            M.recents[k] = { cwd=ws, project=e.project, host=e.host, title=e.title, last_seen=e.last_seen or 0 }
          end
        end
      end
    end
  end
  return M.recents
end

function M.saveRecents()
  local f = io.open(RECENTS, "w")
  if not f then return false end
  f:write(hs.json.encode(M.recents or {})); f:close()
  return true
end

-- Upsert every live session into the store each tick; flush at most every 10s (last_seen
-- churns every tick, so a per-tick disk write would be wasteful).
function M.upsertRecents(cards)
  M.recents = M.recents or {}
  local now = os.time()
  for _, c in ipairs(cards or {}) do
    if c.window then core.upsert_recent(M.recents, c, now) end   -- real VS Code windows only (skips temp/scratchpad cwds)
  end
  core.prune_recents(M.recents, 50)   -- bound growth: keep the 50 most-recent windows
  if now - (M.recentsFlushAt or 0) >= 10 then
    M.saveRecents(); M.recentsFlushAt = now
  end
end

-- Resolve the VS Code CLI: `code` is often NOT on the login-shell PATH, so derive it from the
-- running host app's bundle (…/Contents/Resources/app/bin/code), falling back to `code`.
local function codeBin()
  local app = hs.application.find(M.config.host_app)
  local p = app and app:path()
  if p then
    local bin = p .. "/Contents/Resources/app/bin/code"
    if hs.fs.attributes(bin) then return bin end
  end
  return "code"
end

-- Reopen a window's folder in VS Code (Remote-SSH window for remote hosts).
function M.relaunchWindow(host, cwd)
  if not cwd or cwd == "" then return false end
  hs.execute(core.relaunch_cmd({ host = host, cwd = cwd }, codeBin()), true)
  return true
end

function M.renderInto(wv, layout, opts)
  layout = layout or "list"
  local slim = deckForJS(layout ~= "bar")            -- bar shows no thumbnails
  if opts and opts.max and opts.max > 0 then slim = core.take(slim, opts.max) end
  local json = hs.json.encode(slim)
  -- theme is a plain string ("auto"/"dark"/"light"); hs.json.encode rejects a bare
  -- string, so emit it (and the layout) as JS string literals directly.
  local theme = '"' .. tostring(M.config.theme or "auto") .. '"'
  local optsJson = opts and hs.json.encode(opts) or "{}"
  wv:evaluateJavaScript("render(" .. json .. ", " .. theme .. ", \"" .. layout .. "\", " .. optsJson .. ")")
end

local function makeBridge()
  return hs.webview.usercontent.new("dock"):setCallback(function(msg)
    local body = msg.body
    if body and body.action == "focus" then
      M.focus(body.id)
      M.hideOverlay()
    elseif body and body.action == "mosaicHeight" then
      if M.setMosaicHeight then M.setMosaicHeight(body.h) end
    end
  end)
end

function M.showOverlay()
  if not M.overlay then
    local screen = hs.screen.mainScreen():frame()
    M.overlay = hs.webview.new(screen, {}, makeBridge())
      :windowStyle({"borderless"}):level(hs.drawing.windowLevels.overlay)
      :allowTextEntry(true):transparent(true)
    M.overlay:url("file://" .. UI .. "grid.html")
  end
  M.overlay:show()
  hs.timer.doAfter(0.15, function() M.renderInto(M.overlay, "list") end)
end

function M.hideOverlay() if M.overlay then M.overlay:hide() end end

function M.bindHotkey()
  if M.hotkeyHandle then M.hotkeyHandle:delete() end
  M.hotkeyHandle = hs.hotkey.bind(M.config.hotkey.mods, M.config.hotkey.key, function()
    if M.overlay and M.overlay:isVisible() then M.hideOverlay() else M.showOverlay() end
  end)
end

-- List the connected screens for the settings dropdown: stable UUID + a label.
local function screenList()
  local out = {}
  for i, scr in ipairs(hs.screen.allScreens()) do
    local nm = scr:name()
    if not nm or nm == "" then nm = "Monitor " .. i end
    out[#out+1] = { uuid = scr:getUUID(), name = nm }
  end
  return out
end

-- Resolve a config screen value ("main" or a UUID) to an hs.screen, falling back
-- to main when "main" is set or the chosen monitor is currently disconnected.
local function screenByUUID(sel)
  if not sel or sel == "main" then return hs.screen.mainScreen() end
  for _, scr in ipairs(hs.screen.allScreens()) do
    if scr:getUUID() == sel then return scr end
  end
  return hs.screen.mainScreen()
end

-- The on-screen view (panel/mosaic/bar) shares one monitor: M.config.screen.
local function panelScreen()  return screenByUUID(M.config.screen) end
local function mosaicScreen() return screenByUUID(M.config.screen) end
local function barScreen()    return screenByUUID(M.config.screen) end

local function panelFrame()
  local sf = panelScreen():frame()
  local w, h = M.config.panel.width, M.config.panel.height
  local m = 16
  local corners = {
    topRight    = { x = sf.x + sf.w - w - m, y = sf.y + m },
    topLeft     = { x = sf.x + m,            y = sf.y + m },
    bottomRight = { x = sf.x + sf.w - w - m, y = sf.y + sf.h - h - m },
    bottomLeft  = { x = sf.x + m,            y = sf.y + sf.h - h - m },
  }
  local p = corners[M.config.panel.corner] or corners.topRight
  return { x = p.x, y = p.y, w = w, h = h }
end

function M.showPanel()
  if not M.panel then
    M.panel = hs.webview.new(panelFrame(), {}, makeBridge())
      :windowStyle({"borderless","nonactivating"})
      :level(hs.drawing.windowLevels.floating):transparent(true)
    M.panel:url("file://" .. UI .. "grid.html")
  else
    M.panel:frame(panelFrame())
  end
  M.panel:show()
  hs.timer.doAfter(0.15, function() M.renderInto(M.panel, "list") end)
end

function M.hidePanel() if M.panel then M.panel:hide() end end

local function mosaicFrame(height)
  local sf = mosaicScreen():frame()
  local edge = M.config.mosaic.edge or "top"
  local y = (edge == "bottom") and (sf.y + sf.h - height) or sf.y
  return { x = sf.x, y = y, w = sf.w, h = height }
end

-- Apply a content height the renderer measured (thumbnails on/off + variable meta lines make
-- the exact band height only knowable after layout). Capped at 60% of the screen; past that the
-- band scrolls internally. Reframes only on change — and after a screen/edge change, where
-- showMosaic clears M.mosaicH to force a reframe here.
function M.setMosaicHeight(h)
  if not M.mosaic then return end
  local sf = mosaicScreen():frame()
  local cap = math.floor(sf.h * 0.6)
  h = math.min(math.max(math.floor(h or 120), 80), cap)
  if M.mosaicH ~= h then
    M.mosaic:frame(mosaicFrame(h)); M.mosaicH = h
  end
end

-- Render the band; the renderer reports its real content height back via setMosaicHeight.
function M.refreshMosaic()
  if not M.mosaic then return end
  local mc = M.config.mosaic
  local n = #deckForJS(false)                        -- cheap count (no thumbnails)
  if mc.max and mc.max > 0 and n > mc.max then n = mc.max end
  local sf = mosaicScreen():frame()
  local dims = core.mosaic_dims(n, sf.w, { columns = mc.columns, tile = mc.tile, screen_h = sf.h })
  M.renderInto(M.mosaic, "mosaic", { cols = dims.cols, tile = mc.tile, max = mc.max })
end

function M.showMosaic()
  if not M.mosaic then
    M.mosaic = hs.webview.new(mosaicFrame(120), {}, makeBridge())
      :windowStyle({"borderless","nonactivating"})
      :level(hs.drawing.windowLevels.floating):transparent(true)
    M.mosaic:url("file://" .. UI .. "grid.html")
    M.mosaicH = 120
  else
    M.mosaicH = nil  -- force refreshMosaic to re-apply the frame (screen/edge may have changed)
  end
  M.mosaic:show()
  hs.timer.doAfter(0.15, function() M.refreshMosaic() end)
end

function M.hideMosaic() if M.mosaic then M.mosaic:hide() end end

local function barFrame()
  local sf = barScreen():frame()
  local h = M.config.bar.height or 52
  local edge = M.config.bar.edge or "bottom"
  local y = (edge == "top") and sf.y or (sf.y + sf.h - h)
  return { x = sf.x, y = y, w = sf.w, h = h }
end

function M.showBar()
  if not M.barview then
    M.barview = hs.webview.new(barFrame(), {}, makeBridge())
      :windowStyle({"borderless","nonactivating"})
      :level(hs.drawing.windowLevels.floating):transparent(true)
    M.barview:url("file://" .. UI .. "grid.html")
  else
    M.barview:frame(barFrame())
  end
  M.barview:show()
  hs.timer.doAfter(0.15, function() M.renderInto(M.barview, "bar", { max = M.config.bar.max }) end)
end

function M.hideBar() if M.barview then M.barview:hide() end end

-- The menu bar is the launcher/history: it lists RECENT windows (deduped by folder), most-recent
-- first, with 🟢 on the ones currently live. Click a live one to focus it; a closed one relaunches
-- its VS Code window. The title badge still counts live sessions.
function M.buildMenubar()
  if not M.menubar then M.menubar = hs.menubar.new() end
  local live = M.buildDeck(false)
  local live_keys, live_focus, needs = {}, {}, 0
  for _, c in ipairs(live) do
    local k = core.window_key(c.host, core.workspace_path(c.cwd, c.project))  -- same key as the recents store
    live_keys[k] = true
    if not live_focus[k] then live_focus[k] = c.session_id end
    if c.status == "needs_you" then needs = needs + 1 end
  end
  M.menubar:setTitle("🤖 " .. #live .. (needs > 0 and " ⚠️" .. needs or ""))
  local menu = {}
  for _, w in ipairs(core.recent_windows(M.recents or {}, live_keys, os.time(), 25)) do
    local host = w.host and ("   ☁ " .. w.host) or ""
    local label = (w.active and "🟢  " or "🕘  ") .. (w.project or "?") .. host  -- project name only, no tab title
    local sid, whost, wcwd = live_focus[w.key], w.host, w.cwd
    menu[#menu+1] = { title = label, fn = function()
      if sid then M.focus(sid) else M.relaunchWindow(whost, wcwd) end
    end }
  end
  if #menu == 0 then menu[#menu+1] = { title = "Nenhuma janela recente", disabled = true } end
  menu[#menu+1] = { title = "-" }
  menu[#menu+1] = { title = "⚙️ Configurações", fn = function() if M.showSettings then M.showSettings() end end }
  M.menubar:setMenu(menu)
end

function M.applyShells()
  -- overlay (hotkey) and menubar are independent
  if M.config.shells.overlay then M.bindHotkey()
  elseif M.hotkeyHandle then M.hotkeyHandle:delete(); M.hotkeyHandle = nil end
  -- exactly one on-screen view at a time: panel | mosaic | bar | none
  local view = M.config.shells.view or "none"
  if view == "panel"  then M.showPanel()  else M.hidePanel()  end
  if view == "mosaic" then M.showMosaic() else M.hideMosaic() end
  if view == "bar"    then M.showBar()    else M.hideBar()    end
  -- menubar
  if M.config.shells.menubar then M.buildMenubar()
  elseif M.menubar then M.menubar:delete(); M.menubar = nil end
end

function M.tick()
  M.upsertRecents(M.buildDeck(false))   -- remember live sessions even when no view is open
  if M.overlay and M.overlay:isVisible() then M.renderInto(M.overlay, "list") end
  local view = M.config.shells.view or "none"
  if view == "panel" and M.panel and M.panel:isVisible() then M.renderInto(M.panel, "list") end
  if view == "mosaic" and M.mosaic and M.mosaic:isVisible() then M.refreshMosaic() end
  if view == "bar" and M.barview and M.barview:isVisible() then
    M.renderInto(M.barview, "bar", { max = M.config.bar.max })
  end
  if M.config.shells.menubar and M.menubar then M.buildMenubar() end
end

function M.permissionStatus()
  return {
    accessibility = hs.accessibilityState(),
    -- snapshot() returns nil (without raising) when Screen Recording is denied,
    -- so pcall's `ok` alone is always true — require a non-nil image.
    screen = (function()
      local ok, img = pcall(function() return hs.screen.mainScreen():snapshot() end)
      return ok and img ~= nil
    end)(),
  }
end

function M.saveConfig(tbl)
  local merged = core.merge_config(DEFAULTS, tbl)
  local f = io.open(CONFIG, "w")
  if not f then return false end
  f:write(hs.json.encode(merged)); f:close()
  M.reload()
  return true
end

-- Recent windows formatted for the settings management list (all of them, most-recent first).
local function recentsForSettings()
  local out = {}
  for _, w in ipairs(core.recent_windows(M.recents or {}, {}, os.time())) do
    out[#out+1] = { key = w.key, project = w.project, title = w.title,
                    host = w.host, age = ageLabel(w.age_secs) }
  end
  return out
end

function M.pushRecents()
  if M.settings then
    M.settings:evaluateJavaScript("renderRecents(" .. hs.json.encode(recentsForSettings()) .. ")")
  end
end

local function settingsBridge()
  return hs.webview.usercontent.new("dockcfg"):setCallback(function(m)
    local b = m.body or {}
    if b.action == "save" then
      if M.saveConfig(b.config) then
        hs.alert.show("Configurações salvas")
      else
        hs.alert.show("Erro ao salvar configurações")
      end
    elseif b.action == "perm" then
      hs.execute("open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'")
    elseif b.action == "reinstall" then
      local _, status, _, rc = hs.execute("bash '" .. here .. "../install.sh'", true)
      if status and rc == 0 then
        hs.alert.show("Hooks reinstalados")
      else
        hs.alert.show("Falha — rode pelo terminal")
      end
    elseif b.action == "uninstall" then
      local _, status, _, rc = hs.execute("bash '" .. here .. "../uninstall.sh'", true)
      if status and rc == 0 then
        hs.alert.show("Desinstalado")
      else
        hs.alert.show("Falha — rode pelo terminal")
      end
    elseif b.action == "recordHotkey" then
      M.recordHotkey()
    elseif b.action == "forgetRecent" then
      if M.recents then M.recents[b.key] = nil; M.saveRecents() end
      M.pushRecents()
    elseif b.action == "clearRecents" then
      M.recents = {}; M.saveRecents()
      M.pushRecents()
    end
  end)
end

function M.recordHotkey()
  if M.recorder then M.recorder:stop(); M.recorder = nil end
  M.recorder = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(e)
    local flags = e:getFlags()
    local mods = {}
    for _, mod in ipairs({"cmd","shift","alt","ctrl"}) do if flags[mod] then mods[#mods+1] = mod end end
    local key = hs.keycodes.map[e:getKeyCode()]
    if key and #mods > 0 then
      M.recorder:stop(); M.recorder = nil
      local hk = { mods = mods, key = key }
      if M.settings then
        M.settings:evaluateJavaScript("setHotkey(" .. hs.json.encode(hk) .. ")")
      end
      return true
    end
    return false
  end):start()
  -- Safety: never leave a global keyDown tap running. If no full chord is
  -- captured (modifier-only press, window closed, Salvar clicked mid-capture),
  -- force-stop after a timeout and restore the form to the current hotkey.
  hs.timer.doAfter(6, function()
    if M.recorder then
      M.recorder:stop(); M.recorder = nil
      if M.settings then M.settings:evaluateJavaScript("setHotkey(" .. hs.json.encode(M.config.hotkey) .. ")") end
    end
  end)
end

function M.showSettings()
  if not M.settings then
    local sf = hs.screen.mainScreen():frame()
    local w, h = 420, 620
    M.settings = hs.webview.new({ x = sf.x + (sf.w-w)/2, y = sf.y + (sf.h-h)/2, w = w, h = h }, {}, settingsBridge())
      :windowStyle({"titled","closable"}):allowTextEntry(true)
    M.settings:url("file://" .. UI .. "settings.html")
  end
  M.settings:show():bringToFront(true)
  hs.timer.doAfter(0.2, function()
    M.settings:evaluateJavaScript("load(" .. hs.json.encode(M.config) .. ","
      .. hs.json.encode(M.permissionStatus()) .. "," .. hs.json.encode(screenList()) .. ","
      .. hs.json.encode(recentsForSettings()) .. ")")
  end)
end

-- Pull live session state from configured SSH hosts, non-blocking.
-- One persistent ControlMaster connection per host keeps each poll ~10ms.
M.remoteCache = M.remoteCache or {}   -- host -> array of remote state tables
M.remoteTasks = M.remoteTasks or {}   -- host -> in-flight hs.task (avoids pile-up)

function M.syncRemotes()
  local cmpath = os.getenv("HOME") .. "/.claude-dock-station/cm-%h-%p"
  for _, host in ipairs(M.config.remotes or {}) do
    local inflight = M.remoteTasks[host]
    if not (inflight and inflight:isRunning()) then
      local args = {
        "-o", "BatchMode=yes", "-o", "ConnectTimeout=6",
        "-o", "ControlMaster=auto", "-o", "ControlPath=" .. cmpath, "-o", "ControlPersist=60",
        host,
        "jq -s '.' ~/.claude-dock-station/state/*.json 2>/dev/null || echo '[]'",
      }
      local task = hs.task.new("/usr/bin/ssh", function(_code, out, _err)
        local ok, arr = pcall(hs.json.decode, out or "")
        if ok and type(arr) == "table" then
          for _, s in ipairs(arr) do s.host = host; s.remote = true end
          M.remoteCache[host] = arr
        end
      end, args)
      if task then M.remoteTasks[host] = task; task:start() end
    end
  end
end

-- boot
M.loadConfig()
M.loadRecents()
M.applyShells()
M.timer = hs.timer.doEvery(M.config.interval_secs, function()
  if M.tick then M.tick() end
end)
M.syncRemotes()
M.remoteTimer = hs.timer.doEvery(M.config.remote_interval_secs, function()
  if M.syncRemotes then M.syncRemotes() end
end)

DockStation = M
return M
