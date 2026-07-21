-- Pure logic for Claude Dock Station. NO dependency on hs.* so it runs under
-- the standalone `lua` interpreter in tests. All IO/JSON happens in the caller.
local core = {}

core.VERSION = "0.1.0"

local function basename(path)
  return (path or ""):gsub("/+$", ""):match("([^/]+)$") or ""
end

-- Path segments that are deploy scaffolding, never a project identity: filesystem
-- roots, group containers, and env/worktree wrappers. Used both to skip them when
-- guessing a label and to keep them from matching unrelated window titles.
local GENERIC = {
  opt=true, home=true, root=true, srv=true, var=true, usr=true, mnt=true, www=true,
  users=true, documents=true, apps=true, app=true, clients=true, client=true,
  sites=true, code=true, git=true, repos=true, repo=true, projects=true, project=true,
  dev=true, development=true, production=true, prod=true, staging=true, stage=true,
  release=true, live=true, current=true, main=true, master=true, worktrees=true,
}

-- Candidate project segments, leaf first, skipping generic scaffolding. `limit` caps
-- how far up we look — the workspace root is the leaf or a near ancestor, and a tight
-- cap keeps deep container names (a home dir, a group folder) from matching by accident.
local function project_candidates(path, limit)
  local rev = {}
  for seg in (path or ""):gmatch("[^/]+") do table.insert(rev, 1, seg) end  -- leaf first
  local cands = {}
  for _, seg in ipairs(rev) do
    if not GENERIC[seg:lower()] then
      cands[#cands+1] = seg
      if limit and #cands >= limit then break end
    end
  end
  return cands
end

-- Best-effort label WITHOUT a window: the first non-generic segment from the leaf up
-- (…/webapp/production/repo -> "webapp"). Falls back to the bare leaf when every
-- segment is generic (/production -> "production").
local function project_label(path)
  return project_candidates(path, 1)[1] or basename(path)
end

-- Label from the workspace root the hook resolved (`git rev-parse --show-toplevel`). The root
-- FEEDS the heuristic rather than replacing it: it cuts the deep subfolder noise no denylist
-- could ever cover (…/dash/supabase/functions -> dash), while the generic-segment skip still has
-- to run on top of it, because a repo root can itself be an env wrapper — verified on the real
-- host, acme's repo root is '/opt/clients/acme/production'. Tri-state, so old hooks work:
--   • "/opt/apps/dash" -> repo root; label = its first non-generic segment
--   • ""              -> the hook looked and found NO repo. NOT a verdict on whether this is a
--                        project: webapp and crm have no repo at all. Just fall back.
--   • nil             -> hook predates `root`; fall back to the segment heuristic
local function root_label(root)
  if root and root ~= "" then return project_label(root) end
  return nil
end

-- Is `path` inside `dir` (or equal to it)? Both plain absolute paths, no normalization.
local function is_within(path, dir)
  if not path or not dir or dir == "" then return false end
  return path == dir or path:sub(1, #dir + 1) == dir .. "/"
end

-- A cwd that is the home dir itself, or inside ~/.claude. Such a session is not in a project,
-- so labeling it by the home's leaf segment ("dev", "claude") reads as a fake project named
-- after the user. `home` is the $HOME the hook emits for the machine owning the cwd (nil for old
-- hooks). This is the same signal upsert_recent uses to keep these out of the launcher.
local HOME_LABEL = "~"
local function is_home_cwd(cwd, home)
  if not cwd or not home or home == "" then return false end
  return cwd == home or is_within(cwd, home .. "/.claude")
end

-- cwds that are never a real VS Code project window: Claude scratchpads and OS temp dirs.
-- (A session running in one can still match a window by conversation-title, so filter the path.)
-- Matched with is_within, NOT a '^/tmp/' prefix: that pattern demands a segment after the slash,
-- so a session sitting AT the root leaked through and the launcher grew a 'tmp' card. is_within
-- accepts the bare root and its subpaths while still rejecting a mere name prefix ('/opt/apps/tmpl').
local TEMP_ROOTS = { "/tmp", "/private/tmp", "/var/folders", "/private/var/folders" }
local function is_temp_cwd(cwd)
  cwd = cwd or ""
  if cwd:find("/scratchpad", 1, true) ~= nil then return true end
  for _, root in ipairs(TEMP_ROOTS) do
    if is_within(cwd, root) then return true end
  end
  return false
end

-- The folder a VS Code window is opened at, read off its title. The default title is
-- "${activeEditorShort} — ${rootName}" (macOS drops appName), and on a Remote-SSH window
-- rootName renders as "<folder> [SSH: <host>]". rootName IS the folder — verified against
-- every real window, local ones included: they name the folder just like remote ones do.
-- Byte-safe on purpose: the separator is a multibyte em dash, so this scans with plain find.
-- A Lua character class ([^—]) would match the em dash's individual UTF-8 bytes and split on
-- any other multibyte char that shares one — "…" (E2 80 A6) collides with "—" (E2 80 94).
-- NOTE: a VS Code profile appends "${separator}${profileName}", which lands in this same slot.
-- This function cannot tell the two apart, so callers must corroborate the name (see
-- slug_has_folder) before renaming anything.
local TITLE_SEP = " — "
function core.window_folder(title)
  local t = title or ""
  local start, last = 1, nil
  while true do
    local i, j = t:find(TITLE_SEP, start, true)
    if not i then break end
    last = j + 1; start = j + 1
  end
  if not last then return nil end
  local folder = t:sub(last):gsub("%s*%[SSH:[^%]]*%]%s*$", "")
  folder = folder:gsub("^%s+", ""):gsub("%s+$", "")
  if folder == "" then return nil end
  return folder
end

-- A Claude scratchpad path embeds the session's own project as a slug:
--   /tmp/claude-<uid>/-opt-clients-acme/<session-uuid>/scratchpad/…
-- i.e. the project path with '/' rewritten to '-'. So a folder named X shows up as a '-X'
-- segment. This is a signal fully independent of the window title, which is what makes it
-- worth checking: title says "acme" AND slug says "acme" -> trust it. Title says
-- "Perfil Dev" and the slug has no such segment -> refuse. A wrong-but-plausible project
-- name is worse than an obviously-unknown one.
local function slug_has_folder(cwd, folder)
  if not cwd or not folder or folder == "" then return false end
  local hay, needle = cwd:lower(), "-" .. folder:lower()
  local start = 1
  while true do
    local i, j = hay:find(needle, start, true)
    if not i then return false end
    local after = j < #hay and hay:sub(j + 1, j + 1) or ""
    -- Must end a slug segment, so "webapp" matches "-opt-apps-webapp-production-repo"
    -- (the mid-slug ancestor case this exists for). Note it ALSO matches "webapp"
    -- inside "-webapp-core-staging": both read as "-webapp" followed by "-", and the
    -- slug cannot tell them apart — it rewrites '/' to '-', so the separator that
    -- would distinguish an ancestor dir from a longer name is already gone by the
    -- time we see it. Tightening this check cannot fix that; the information is not
    -- in the input. title_has_segment does reject the prefix collision (word chars
    -- include '-'), so the title pass carries that guarantee and this one does not.
    if after == "" or after == "-" or after == "/" then return true end
    start = i + 1
  end
end

-- Depth of `folder` within `cwd` as a whole path segment (1-based, deepest occurrence), or nil
-- if it is not a segment at all. Two jobs in one number:
--   • nil = refusal. This is what corroborates a folder parsed off a window title before it may
--     name a card, and it is independent of the title by construction — so it rejects exactly the
--     two ways window_folder goes wrong: a VS Code profile name (lands in the title's last slot
--     but is nobody's cwd segment) and a window linked only by a conversation-title collision
--     (its folder belongs to some other project's path).
--   • the depth ranks nested windows. A worktree sits INSIDE its parent repo, so both folders are
--     segments of the cwd; the deeper one is the window the session actually belongs to.
local function cwd_segment_depth(cwd, folder)
  if not cwd or not folder or folder == "" then return nil end
  local want, depth, found = folder:lower(), 0, nil
  for seg in cwd:gmatch("[^/]+") do
    depth = depth + 1
    if seg:lower() == want then found = depth end
  end
  return found
end

-- The project a declared container folder names. A container is a folder whose DIRECT CHILDREN
-- are projects ("/opt/clients" -> acme, globex); the container itself never is. This is the only
-- naming signal that needs neither a repo nor an open window, which is exactly the gap it fills:
-- a client folder holding several projects, opened as ONE window, collapses every session under
-- it to the client's name because the window folder is coarser than the project.
-- Containers may nest, and the DEEPEST match wins, so a narrower declaration always refines a
-- broader one. Matched with is_within, so a sibling sharing only a name prefix is not contained.
function core.container_child(cwd, containers)
  if not cwd or cwd == "" then return nil end
  local best_child, best_len = nil, -1
  for _, dir in ipairs(containers or {}) do
    if type(dir) == "string" and dir ~= "" then
      local d = dir:gsub("/+$", "")
      if #d > best_len and cwd ~= d and is_within(cwd, d) then
        local child = cwd:sub(#d + 2):match("^([^/]+)")
        if child then best_child, best_len = child, #d end
      end
    end
  end
  return best_child
end

-- Whole-token containment: `seg` must sit in `wt` flanked by non-word chars (or edges),
-- both already lowercased. Keeps a short ancestor dir ("x") from matching inside a word
-- ("index") and "webapp" from matching "webapp-core". Word chars: alnum, "_", "-".
local function is_word_char(c) return c ~= "" and c:match("[%w_-]") ~= nil end
local function title_has_segment(wt, seg)
  local start = 1
  while true do
    local i, j = wt:find(seg, start, true)
    if not i then return false end
    local before = i > 1 and wt:sub(i - 1, i - 1) or ""
    local after  = j < #wt and wt:sub(j + 1, j + 1) or ""
    if not is_word_char(before) and not is_word_char(after) then return true end
    start = i + 1
  end
end

-- Match a session to its VS Code window, and report WHICH cwd segment matched (so the
-- caller can label the card with the folder VS Code actually shows). Two passes:
--   • Pass 1 — the window title names the workspace folder ("… — webapp [SSH: host]", and
--     "… — claude-dock-station-wt" locally: every window names its folder, remote or not).
--     That folder can sit ABOVE the session cwd (…/webapp/production/repo), so we test the
--     cwd's non-generic segments leaf-first — the deepest one in the title is the root.
--   • Pass 2 — the cwd names no folder that appears in the title (a scratchpad lives in
--     /tmp/…), so fall back to the leading chunk of the ai-title. This links the window but
--     learns no folder, hence the nil segment; build_deck recovers the name from a sibling
--     session or from core.window_folder.
-- Returns (window, matched_segment) or nil.
function core.match_window(cwd, windows, title, root)
  local cands = project_candidates(cwd, 2)
  -- The git root names the folder VS Code shows, so it outranks every cwd guess. Without it
  -- a deep cwd (…/dash/supabase/functions) offers only {functions, supabase} — neither is in
  -- the title, so the session would never link to its own window at all.
  local rl = root_label(root)
  if rl then table.insert(cands, 1, rl) end
  -- Pass 1 (strongest): the workspace folder appears in the title. Preferred over the
  -- title-prefix pass so a conversation-title collision on some OTHER window can't grab
  -- the session before its real folder window is even reached.
  for _, w in ipairs(windows or {}) do
    local wt = (w.title or ""):lower()
    for _, seg in ipairs(cands) do
      if title_has_segment(wt, seg:lower()) then return w, seg end
    end
  end
  -- Pass 1b (inverted): ask the WINDOW which folder it is, then let the cwd confirm it. Pass 1
  -- guesses candidates out of the cwd and needs one to appear in the title, which fails whenever
  -- the folder sits above the candidate cap and no git root points at it — the REAL case being a
  -- repo-less project (…/globex/docs/<x>/_anexos offers only {_anexos, <x>}, so the card showed
  -- '_anexos'). Reading the title instead has no cap and needs no repo: the window names its
  -- folder outright, and requiring that name to be a segment of the cwd keeps a profile name or a
  -- title-colliding window from renaming anything. Generic scaffolding is skipped so a window
  -- opened at a folder named 'Dev' cannot claim every session under it.
  -- Deepest match wins, NOT the first: with a worktree window and its parent-repo window both
  -- open, both folders are cwd segments and list order would fold the worktree into the parent.
  local best_w, best_seg, best_depth = nil, nil, 0
  for _, w in ipairs(windows or {}) do
    local folder = core.window_folder(w.title)
    if folder and not GENERIC[folder:lower()] then
      local depth = cwd_segment_depth(cwd, folder)
      if depth and depth > best_depth then best_w, best_seg, best_depth = w, folder, depth end
    end
  end
  if best_w then return best_w, best_seg end
  -- Pass 2: local windows show only the conversation title -> match its leading chunk.
  if title and #title > 0 then
    local tprefix = title:lower():sub(1, 16)
    if #tprefix >= 6 then
      for _, w in ipairs(windows or {}) do
        if (w.title or ""):lower():find(tprefix, 1, true) then return w, nil end
      end
    end
  end
  return nil
end

local STATUS = {
  needs_you = { badge = "⚠️", rank = 0 },
  done      = { badge = "✅", rank = 1 },
  working   = { badge = "🛠️", rank = 2 },
  idle      = { badge = "🏖️", rank = 3 },
}

-- Name a card by whichever signal sits DEEPEST in the cwd: the container child, the git root,
-- or the folder the window shows. Not a precedence chain: depth is a name's DEEPEST occurrence,
-- so a tie is reachable only when two labels are the SAME cwd segment apart from casing — strict
-- '>' then just picks which casing wins, never which project. A worktree outranks a container
-- because its root sits STRICTLY deeper, not because of consideration order.
local function consider(cwd, label, best, best_depth)
  if label and label ~= "" then
    local d = cwd_segment_depth(cwd, label)
    if d and d > best_depth then return label, d end
  end
  return best, best_depth
end

local function resolve_project(cwd, root, seg, containers)
  local best, bd = nil, 0
  best, bd = consider(cwd, core.container_child(cwd, containers), best, bd)
  best, bd = consider(cwd, root_label(root), best, bd)
  best, bd = consider(cwd, seg, best, bd)
  -- Fall back exactly as before when no signal is a cwd segment (a title-only match reports
  -- no folder at all, and build_deck's inheritance pass handles that case afterwards). `or seg`
  -- is defensive, not expected to be reached: every non-nil seg is itself a cwd segment by
  -- construction, so consider() above would already have set best from it.
  return best or seg or root_label(root) or project_label(cwd)
end

function core.to_card(state, now, needs_after)
  needs_after = needs_after or 30
  local age = math.max(0, (now or 0) - (state.updated_at or 0))
  local status = STATUS[state.state] and state.state or "idle"
  -- Claude Code fires no hook when it blocks on a permission prompt: the session
  -- just sits at PreToolUse (working) with the tool never completing. Treat a
  -- pending tool call that has gone stale as "needs you". PostToolUse resets the
  -- event once a tool completes, so a session that's merely thinking won't trip this.
  if needs_after > 0 and status == "working" and state.event == "PreToolUse" and age > needs_after then
    status = "needs_you"
  end
  local meta = STATUS[status]
  return {
    session_id = state.session_id,
    project    = is_home_cwd(state.cwd, state.home) and HOME_LABEL
                 or root_label(state.root) or project_label(state.cwd),
    cwd        = state.cwd,
    root       = state.root,   -- git workspace root; "" = no repo, nil = hook predates it
    home       = state.home,   -- $HOME on the machine owning the cwd (marks non-project cwds)
    status     = status,
    detail     = state.detail,
    badge      = meta.badge,
    rank       = meta.rank,
    age_secs   = age,
    host       = state.host,    -- nil for local sessions; SSH host for remote ones
    title      = state.title,   -- ai-title (VS Code tab label), disambiguates same-folder sessions
  }
end

function core.prune(states, has_window_fn, now, stale_secs)
  local out = {}
  for _, s in ipairs(states or {}) do
    local keep = true
    if s.state == "ended" then keep = false
    elseif not has_window_fn(s) and (now - (s.updated_at or 0)) > stale_secs then keep = false end
    if keep then out[#out+1] = s end
  end
  return out
end

function core.sort_cards(cards)
  table.sort(cards, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    return (a.age_secs or 0) < (b.age_secs or 0)
  end)
  return cards
end

function core.build_deck(states, windows, now, opts)
  opts = opts or {}
  local has = function(s) return core.match_window(s.cwd, windows, s.title, s.root) ~= nil end
  local pruned = core.prune(states, has, now, opts.stale_secs or 900)
  local cards = {}
  local folder_by_window = {}   -- window id -> folder label from a cwd-segment (Pass 1) match
  for _, s in ipairs(pruned) do
    local card = core.to_card(s, now, opts.needs_after)
    local w, seg = core.match_window(s.cwd, windows, s.title, s.root)
    card.window = w
    -- Only a card with NO folder of its own may borrow one (see the inheritance pass below).
    -- A real cwd that merely shares a conversation-title prefix must keep its own name.
    card._title_only = w ~= nil and seg == nil and is_temp_cwd(s.cwd)
    card.project = is_home_cwd(s.cwd, s.home) and HOME_LABEL
                   or resolve_project(s.cwd, s.root, seg, opts.containers)
    -- folder_by_window keeps the raw WINDOW folder, not the resolved name: it exists so a
    -- scratchpad sibling can borrow the folder VS Code actually shows.
    if seg and w and w.id ~= nil then folder_by_window[w.id] = seg end
    cards[#cards+1] = card
  end
  -- A session in a throwaway cwd (scratchpad/temp) links to its VS Code window only by the
  -- conversation title, so no cwd segment names the folder. Borrow the folder label from a
  -- sibling session in the SAME window that DID match by segment — otherwise the card shows
  -- the meaningless leaf ('scratchpad') instead of the project the window belongs to ('crm').
  -- Strictly temp cwds only: a title-prefix collision once let a real local repo inherit an
  -- unrelated remote project's name ('…/git/claude-dock-station' shown as 'crm').
  for _, card in ipairs(cards) do
    if card._title_only and card.window then
      -- 1) a sibling session that named this window from its real cwd — the strongest signal
      local folder = card.window.id ~= nil and folder_by_window[card.window.id] or nil
      -- 2) no sibling: the window title names the folder itself, but a VS Code profile lands
      --    in that same slot, so only take it when the scratchpad slug independently agrees.
      if not folder then
        local parsed = core.window_folder(card.window.title)
        if parsed and slug_has_folder(card.cwd, parsed) then folder = parsed end
      end
      -- 3) neither agrees -> keep the leaf; an unknown name beats a confidently wrong one
      if folder then card.project = folder end
    end
    card._title_only = nil
  end
  return core.sort_cards(cards)
end

function core.merge_config(defaults, loaded)
  local out = {}
  for k, v in pairs(defaults) do out[k] = v end
  for k, v in pairs(loaded or {}) do if defaults[k] ~= nil then out[k] = v end end
  return out
end

-- Return the first n items of a list. n <= 0 (or nil) means "all". Non-mutating.
function core.take(list, n)
  if not n or n <= 0 then return list end
  local out = {}
  for i = 1, math.min(n, #list) do out[i] = list[i] end
  return out
end

-- Mosaic band geometry from a card count. Pure (no hs.*): the engine passes real
-- screen numbers, tests pass fixtures. opts = { columns, tile, gap, pad, screen_h, cap_frac }.
-- Returns { cols, rows, height, capped }.
function core.mosaic_dims(count, screen_w, opts)
  opts = opts or {}
  local tile = opts.tile or 150
  local gap  = opts.gap or 16
  local pad  = opts.pad or 24
  local cap_frac = opts.cap_frac or 0.6
  local cols
  if opts.columns and opts.columns > 0 then
    cols = opts.columns
  else
    cols = math.max(1, math.floor((screen_w - 2*pad + gap) / (tile + gap)))
  end
  local rows = count == 0 and 0 or math.ceil(count / cols)
  local content_h
  if rows == 0 then
    content_h = pad*2 + 80
  else
    content_h = pad*2 + rows*tile + (rows-1)*gap
  end
  local cap = opts.screen_h and math.floor(opts.screen_h * cap_frac) or content_h
  local height = math.min(content_h, cap)
  return { cols = cols, rows = rows, height = height, capped = content_h > cap }
end

-- Migrate the pre-"single view" config: three independent on-screen shells
-- (shells.panel/mosaic/bar booleans, each with its own .screen) -> one exclusive
-- on-screen view (shells.view) sharing a single top-level cfg.screen. Idempotent:
-- once shells.view exists it does nothing.
function core.migrate_view(cfg)
  cfg.shells = cfg.shells or {}
  local s = cfg.shells
  if s.view == nil then
    s.view = (s.mosaic and "mosaic") or (s.bar and "bar") or (s.panel and "panel") or "none"
    if not cfg.screen or cfg.screen == "main" then
      local src = (s.view == "panel" and cfg.panel) or (s.view == "mosaic" and cfg.mosaic)
                  or (s.view == "bar" and cfg.bar) or nil
      if src and src.screen and src.screen ~= "main" then cfg.screen = src.screen end
    end
  end
  return cfg
end

-- === Recents launcher ========================================================
-- Keyed by host + the resolved project's folder, not a session/tab: usually one key per VS Code
-- window, but ANY signal deeper than the window folder — a container child or a nested git root
-- (worktree, submodule) — can resolve two tabs of one window to two different projects. That
-- happens with no container declared at all, so it is not a container-only case.
function core.window_key(host, cwd)
  return (host and host ~= "" and host or "local") .. "|" .. (cwd or "")
end

-- The cwd truncated at the RESOLVED project segment — whichever signal won in resolve_project
-- (container child, git root, or window folder), not necessarily the window's own folder.
-- Deploy cwds like …/webapp/production/repo -> …/webapp. Falls back to the full cwd.
function core.workspace_path(cwd, project)
  if not cwd or cwd == "" or not project or project == "" then return cwd end
  local acc = ""
  for seg in cwd:gmatch("[^/]+") do
    acc = acc .. "/" .. seg
    if seg == project then return acc end
  end
  return cwd
end

-- Upsert a live card into the recents store, keyed by host + the RESOLVED project's folder
-- (see workspace_path) — not necessarily the folder VS Code opens.
function core.upsert_recent(store, card, now)
  if not card or not card.cwd or card.cwd == "" or is_temp_cwd(card.cwd) then return store end
  -- Not every cwd is a folder you'd reopen as a project. The signal is the HOME the hook
  -- reports (it runs on the machine that owns the cwd, so this works for remote hosts too):
  -- the home dir itself is a shell landing spot, and ~/.claude is Claude's own config/cache.
  -- Note this is deliberately NOT "has no git repo" — webapp and crm have no repo and are
  -- very much real projects. (home absent = old hook -> track, nothing regresses.)
  if card.home and card.home ~= "" then
    if card.cwd == card.home or is_within(card.cwd, card.home .. "/.claude") then return store end
  end
  -- Key by the RESOLVED project's folder (whichever signal won in resolve_project), not
  -- necessarily what VS Code opens: a worktree's deeper git root now wins its own key.
  local ws = core.workspace_path(card.cwd, card.project)
  store[core.window_key(card.host, ws)] = {
    cwd = ws, project = card.project, host = card.host,
    title = card.title, last_seen = now or 0,
  }
  return store
end

-- Cap the store to the `max` most-recent windows (bounds recents.json growth). max<=0 = no cap.
function core.prune_recents(store, max)
  if not max or max <= 0 then return store end
  local keys = {}
  for k, e in pairs(store) do keys[#keys+1] = { k = k, t = e.last_seen or 0 } end
  if #keys <= max then return store end
  table.sort(keys, function(a, b) return a.t > b.t end)   -- newest first
  for i = max + 1, #keys do store[keys[i].k] = nil end
  return store
end

-- One launcher entry per window, most-recent first, flagging the windows that are currently
-- live (live_keys[key] == true). `now` yields age_secs; `limit` caps the count.
function core.recent_windows(store, live_keys, now, limit)
  local out = {}
  for key, e in pairs(store or {}) do
    out[#out+1] = {
      key = key, cwd = e.cwd, project = e.project, host = e.host, title = e.title,
      active = (live_keys and live_keys[key]) and true or false,
      age_secs = math.max(0, (now or 0) - (e.last_seen or 0)),
    }
  end
  table.sort(out, function(a, b) return (a.age_secs or 0) < (b.age_secs or 0) end)
  if limit and limit > 0 and #out > limit then
    local capped = {}
    for i = 1, limit do capped[i] = out[i] end
    return capped
  end
  return out
end

-- Build the shell command that reopens a window's folder in VS Code.
-- Remote (has host) -> a Remote-SSH window; local -> the folder directly. code_bin is the
-- VS Code CLI path (`code` is often not on PATH; the engine passes the app-bundle binary).
function core.relaunch_cmd(entry, code_bin)
  local bin = "'" .. (code_bin or "code") .. "'"
  local cwd = entry.cwd or ""
  if entry.host and entry.host ~= "" then
    return string.format('%s --folder-uri "vscode-remote://ssh-remote+%s%s"', bin, entry.host, cwd)
  end
  return string.format("%s '%s'", bin, cwd)
end

return core
