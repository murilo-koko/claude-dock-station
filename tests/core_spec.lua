package.path = package.path .. ";./hammerspoon/?.lua;./tests/?.lua"
local t = require("harness")
local core = require("core")

t.describe("smoke")
t.ok(core.VERSION ~= nil, "core loads and exposes VERSION")

t.describe("match_window")
local wins = {
  { title = "webapp-core — index.ts", id = 11 },
  { title = "toolbox — server.py", id = 22 },
}
t.eq(core.match_window("/Users/m/Documents/Dev/git/webapp-core", wins).id, 11, "matches by folder basename")
t.eq(core.match_window("/Users/m/x/TOOLBOX", wins).id, 22, "match is case-insensitive")
t.eq(core.match_window("/Users/m/x/nope", wins), nil, "no match returns nil")
-- local windows show the conversation title (no folder) -> match by ai-title prefix
local locwins = { { title = "Adicionar miniaturas ao…", id = 99 } }
t.eq(core.match_window("/tmp/zzz", locwins, "Adicionar miniaturas ao vivo nos cards").id, 99, "matches by ai-title prefix when folder absent")
t.eq(core.match_window("/tmp/zzz", locwins, "Outra conversa qualquer"), nil, "wrong title does not match")
t.eq(core.match_window("/tmp/zzz", locwins, "Adici"), nil, "too-short title prefix (<6) ignored")

t.describe("to_card")
local c1 = core.to_card({ session_id="a", cwd="/x/webapp-core", state="needs_you", detail="permissão", updated_at=100 }, 130)
t.eq(c1.project, "webapp-core", "project = basename of cwd")
t.eq(c1.badge, "⚠️", "needs_you -> warning")
t.eq(c1.rank, 0, "needs_you rank 0")
t.eq(c1.age_secs, 30, "age = now - updated_at")
t.eq(core.to_card({session_id="b",cwd="/x/y",state="done",updated_at=100},100).badge, "✅", "done -> check")
t.eq(core.to_card({session_id="c",cwd="/x/y",state="working",updated_at=100},100).badge, "🛠️", "working -> tools")
t.eq(core.to_card({session_id="d",cwd="/x/y",state="idle",updated_at=100},100).badge, "🏖️", "idle -> beach")

-- a PreToolUse that stalled (permission prompt) becomes needs_you after needs_after
t.eq(core.to_card({session_id="p",cwd="/x/y",state="working",event="PreToolUse",updated_at=100}, 140, 30).status,
     "needs_you", "stale PreToolUse (>30s) -> needs_you")
t.eq(core.to_card({session_id="p",cwd="/x/y",state="working",event="PreToolUse",updated_at=100}, 120, 30).status,
     "working", "fresh PreToolUse (<30s) stays working")
t.eq(core.to_card({session_id="p",cwd="/x/y",state="working",event="PostToolUse",updated_at=100}, 200, 30).status,
     "working", "stale PostToolUse (tool completed, just thinking) stays working")
t.eq(core.to_card({session_id="p",cwd="/x/y",state="working",event="PreToolUse",updated_at=100}, 999, 0).status,
     "working", "needs_after=0 disables the stale-PreToolUse reclassification")

t.describe("project label = first non-generic segment (leaf up)")
-- Deploy layouts nest the project under generic scaffolding (…/webapp/production/repo,
-- …/acme/production). WITHOUT a window to anchor to, the label is the first non-generic
-- segment walking up from the leaf, so the project name stays visible.
t.eq(core.to_card({session_id="e1",cwd="/opt/clients/acme/production",state="done",updated_at=100},100).project,
     "acme", "skips env leaf 'production' -> project folder")
t.eq(core.to_card({session_id="e2",cwd="/x/webapp-core",state="done",updated_at=100},100).project,
     "webapp-core", "non-generic leaf stays bare")
t.eq(core.to_card({session_id="e3",cwd="/opt/apps/webapp/production/repo",state="done",updated_at=100},100).project,
     "webapp", "skips 'repo' + 'production' wrappers -> project folder")
t.eq(core.to_card({session_id="e4",cwd="/production",state="done",updated_at=100},100).project,
     "production", "all-generic path falls back to bare leaf")
t.eq(core.to_card({session_id="e5",cwd="/opt/dev/arcade/tracking-gateway",state="done",updated_at=100},100).project,
     "tracking-gateway", "no window: falls back to the leaf subproject")

t.describe("a session in the home dir is labeled ~, not after the home's owner")
-- A session started from the bare home dir (or ~/.claude) is not in a project. Labeling it
-- after the home's leaf segment reads as a fake project named after the user ('dev', 'claude').
-- Same signal upsert_recent uses to keep these out of the launcher. Marker: '~'.
t.eq(core.to_card({session_id="h1",cwd="/Users/dev",home="/Users/dev",state="working",updated_at=100},100).project,
     "~", "local home dir -> ~, not the owning segment")
t.eq(core.to_card({session_id="h2",cwd="/home/claude",home="/home/claude",state="working",updated_at=100,host="my-vps"},100).project,
     "~", "remote home dir -> ~, not 'claude'")
t.eq(core.to_card({session_id="h3",cwd="/Users/dev/.claude/plugins/cache",home="/Users/dev",state="working",updated_at=100},100).project,
     "~", "inside ~/.claude -> ~ (Claude's own cache is not a project)")
-- A real project must NOT be hijacked just because home is set.
t.eq(core.to_card({session_id="h4",cwd="/opt/apps/webapp",home="/home/claude",root="/opt/apps/webapp",state="working",updated_at=100,host="my-vps"},100).project,
     "webapp", "a real project with home set keeps its own name")
-- home absent (old hook) -> unchanged, no regression.
t.eq(core.to_card({session_id="h5",cwd="/Users/dev",state="working",updated_at=100},100).project,
     "dev", "home absent (old hook) -> previous behaviour, labeled by segment")
-- The final deck path (build_deck overrides to_card's project) must agree.
local hdeck = core.build_deck({
  { session_id="hh", cwd="/Users/dev", home="/Users/dev", state="working", updated_at=100 },
}, {}, 100, {})
t.eq(hdeck[1].project, "~", "build_deck also labels a home-dir session ~")

t.describe("window-anchored label for deploy-layout cwds")
-- The VS Code window title shows the workspace ROOT folder, which sits ABOVE the session
-- cwd (…/webapp/production/repo runs under a window opened at 'webapp'). The label and
-- the match must resolve to that folder whatever the cwd depth — leaf-first, so the
-- DEEPEST cwd segment that appears in a title wins (that's the real workspace root).
local dwins = {
  { title = "Aprovar o layout do e-mail… — webapp [SSH: my-vps]", id = 1 },
  { title = "revisa? — arcade [SSH: my-vps]", id = 2 },
}
local w1, seg1 = core.match_window("/opt/apps/webapp/production/repo", dwins)
t.eq(w1 and w1.id, 1, "webapp: matches window via ancestor segment, not leaf 'repo'")
t.eq(seg1, "webapp", "webapp: matched segment is the workspace folder")
-- arcade has an EMPTY ai-title (VS Code shows the raw prompt), so ONLY the path links it
local w2, seg2 = core.match_window("/opt/dev/arcade/tracking-gateway", dwins, "")
t.eq(w2 and w2.id, 2, "arcade: links via 'arcade' segment despite empty ai-title")
t.eq(seg2, "arcade", "arcade: label anchors to the VS Code folder 'arcade'")
-- build_deck stamps the window-anchored label onto the card
local ddeck = core.build_deck({
  { session_id="k", cwd="/opt/apps/webapp/production/repo", state="done", updated_at=100 },
  { session_id="g", cwd="/opt/dev/arcade/tracking-gateway", state="done", updated_at=100, title="" },
}, dwins, 100, { stale_secs = 900 })
local byid = {}
for _, c in ipairs(ddeck) do byid[c.session_id] = c end
t.eq(byid.k.project, "webapp", "deck: webapp card labeled 'webapp', not 'repo'")
t.eq(byid.k.window and byid.k.window.id, 1, "deck: webapp linked to its window")
t.eq(byid.g.project, "arcade", "deck: arcade card labeled 'arcade'")
t.eq(byid.g.window and byid.g.window.id, 2, "deck: arcade linked to its window")

t.describe("folder match beats an earlier title-prefix collision")
-- Two windows share a conversation-title prefix; only the second shows the folder.
-- The session must link to the FOLDER window, not the prefix-colliding one before it.
local colwins = {
  { title = "Verificar a conexão ap…", id = 70 },                          -- no folder, same prefix
  { title = "Verificar a conexão ap… — acme [SSH: my-vps]", id = 80 }, -- the real one
}
local wc, segc = core.match_window("/opt/clients/acme", colwins, "Verificar a conexão após a troca de chave")
t.eq(wc and wc.id, 80, "links via folder segment 'acme', not the earlier prefix window")
t.eq(segc, "acme", "matched segment is the folder")

t.describe("scratchpad session inherits its window's folder label")
-- A session running in a throwaway scratchpad cwd matches its VS Code window ONLY by the
-- conversation-title prefix (Pass 2, no cwd segment). It shares that window with a real
-- project session (cwd under the folder). The scratchpad card must show the window's
-- folder ('crm'), not the meaningless 'scratchpad' leaf.
local spwins = {
  { title = "Revisar a página in… — crm [SSH: my-vps]", id = 5 },
}
local spdeck = core.build_deck({
  { session_id="real", cwd="/opt/apps/crm", state="working", updated_at=100,
    title="Verificar status da implementação de pagamentos" },
  { session_id="scratch", cwd="/tmp/claude/abc/scratchpad", state="needs_you", updated_at=100,
    title="Revisar a página inicial para prospecção" },
}, spwins, 100, { stale_secs = 900 })
local spby = {}
for _, c in ipairs(spdeck) do spby[c.session_id] = c end
t.eq(spby.real.project, "crm", "real session labeled by its folder")
t.eq(spby.scratch.window and spby.scratch.window.id, 5, "scratchpad session linked to the crm window")
t.eq(spby.scratch.project, "crm", "scratchpad session inherits the window's folder, not 'scratchpad'")

t.describe("project label from the git root (hook-provided)")
-- The hook runs ON the machine that owns the cwd (local AND remote via install-remote.sh), so
-- it can ask git for the workspace root instead of leaving the engine to guess. The root does
-- not REPLACE the segment heuristic, it feeds it: verified against the real host, a repo root
-- can itself be an env wrapper (/opt/clients/acme/production), so the label is the first
-- non-generic segment OF THE ROOT. The root's job is to cut the deep subfolder noise.
t.eq(core.to_card({session_id="r1", cwd="/opt/apps/dash/supabase/functions",
                   root="/opt/apps/dash", state="done", updated_at=100}, 100).project,
     "dash", "deep subfolder labeled by its git root, not the 'functions' leaf")
-- REAL case: acme's repo root IS the 'production' wrapper — bare basename would say
-- "production". The generic-segment skip still has to run on top of the root.
t.eq(core.to_card({session_id="r2", cwd="/opt/clients/acme/production/supabase/functions",
                   root="/opt/clients/acme/production", state="done", updated_at=100}, 100).project,
     "acme", "root that is itself an env wrapper still resolves to the project")
t.eq(core.to_card({session_id="r3", cwd="/opt/dev/legal-app/web/seed/corpus/jurisprudencia",
                   root="/opt/dev/legal-app", state="done", updated_at=100}, 100).project,
     "legal-app", "5-deep cwd labeled by its git root")
-- Back-compat: a state from an OLD hook has no `root` key at all -> heuristic, unchanged.
t.eq(core.to_card({session_id="r4", cwd="/opt/clients/acme/production", state="done", updated_at=100}, 100).project,
     "acme", "root absent (old hook) -> falls back to the segment heuristic")
-- REAL case: webapp and crm are NOT git repos. 'no repo' must NEVER mean 'not a project' —
-- that would erase the user's main projects from the launcher.
t.eq(core.to_card({session_id="r5", cwd="/opt/apps/webapp", root="", state="done", updated_at=100}, 100).project,
     "webapp", "root='' (no repo) -> heuristic still names the project")

t.describe("match_window anchors to the git root")
-- Without the root, project_candidates(cwd, 2) for '/opt/apps/dash/supabase/functions' yields
-- {'functions','supabase'} — NEITHER appears in the window title, so the session never links
-- to its own window. The root basename is the folder VS Code actually shows.
local rootwins = { { title = "Adicionar o filtro… — dash [SSH: my-vps]", id = 42 } }
local wr, segr = core.match_window("/opt/apps/dash/supabase/functions", rootwins, "", "/opt/apps/dash")
t.eq(wr and wr.id, 42, "deep cwd links to its window via the git-root folder")
t.eq(segr, "dash", "matched segment is the git-root folder")

t.describe("recents dedup once the label is right")
-- The window key stays the WORKSPACE folder (what VS Code opens), not the git root: acme's
-- repo root is '…/acme/production' but the window is opened at '…/acme'. A correct label is
-- what makes the existing truncation land on the right folder.
local rstore = {}
core.upsert_recent(rstore, {cwd="/opt/apps/dash", project="dash", root="/opt/apps/dash", host="vps"}, 100)
core.upsert_recent(rstore, {cwd="/opt/apps/dash/supabase/functions", project="dash", root="/opt/apps/dash", host="vps"}, 200)
local rc=0; for _ in pairs(rstore) do rc=rc+1 end
t.eq(rc, 1, "root + subfolder sessions collapse to ONE window entry")
t.eq(rstore["vps|/opt/apps/dash"].cwd, "/opt/apps/dash", "entry stored at the workspace folder")
-- The two '…/supabase/functions' cwds that used to collide as 'functions' now split correctly.
core.upsert_recent(rstore, {cwd="/opt/clients/acme/production/supabase/functions", project="acme",
                            root="/opt/clients/acme/production", host="vps"}, 300)
t.eq(rstore["vps|/opt/clients/acme"].project, "acme", "the other 'functions' cwd lands under acme")
t.eq(rstore["vps|/opt/clients/acme"].cwd, "/opt/clients/acme", "keyed at the folder VS Code opens, not the repo root")

t.describe("home dirs and Claude's own cache are not windows")
-- Verified on the real host: 'no repo' does NOT mean 'not a project' (webapp and crm have no
-- repo at all). The signal for junk is the HOME the hook reports — a session sitting in the home
-- dir itself, or inside Claude's own ~/.claude cache, is not a folder you reopen as a project.
local nstore = {}
core.upsert_recent(nstore, {cwd="/Users/dev", project="dev", home="/Users/dev"}, 100)
core.upsert_recent(nstore, {cwd="/home/claude", project="claude", home="/home/claude", host="vps"}, 100)
core.upsert_recent(nstore, {cwd="/Users/m/.claude/plugins/cache/x/skills/subagent-driven-development",
                            project="subagent-driven-development", home="/Users/m"}, 100)
core.upsert_recent(nstore, {cwd="/Users/m/.claude/plugins/cache/x/skills/sdd/scripts",
                            project="scripts", home="/Users/m"}, 100)
local nc=0; for _ in pairs(nstore) do nc=nc+1 end
t.eq(nc, 0, "home dir + ~/.claude cache are not tracked as windows")
-- A REAL project with no git repo must still be tracked — this is the regression that would
-- have erased webapp/crm from the launcher.
local kstore = {}
core.upsert_recent(kstore, {cwd="/opt/apps/webapp", project="webapp", root="", home="/home/claude", host="vps"}, 100)
t.eq(kstore["vps|/opt/apps/webapp"].project, "webapp", "a repo-less real project is still a window")
-- and a state from an old hook (no root/home keys) still tracks, so nothing regresses
local ostore = {}
core.upsert_recent(ostore, {cwd="/opt/clients/globex", project="globex", host="vps"}, 100)
local oc=0; for _ in pairs(ostore) do oc=oc+1 end
t.eq(oc, 1, "root/home absent (old hook) -> still tracked")

t.describe("temp roots are not windows, with or without a trailing path")
-- The temp check used to anchor on '^/tmp/', which requires a segment AFTER the slash — so a
-- session sitting AT the temp root itself slipped through and the launcher grew a 'tmp' card.
-- Every form has to be rejected: the bare root, the /private twin macOS resolves it to, and
-- the /var/folders sandbox. A path merely STARTING with those letters is still a real project.
local tstore = {}
for _, cwd in ipairs({ "/tmp", "/private/tmp", "/var/folders",
                       "/tmp/", "/tmp/claude-1000/-opt-apps-crm/abc/scratchpad" }) do
  core.upsert_recent(tstore, {cwd=cwd, project="whatever", host="vps"}, 100)
end
local tc=0; for _ in pairs(tstore) do tc=tc+1 end
t.eq(tc, 0, "temp roots and their subpaths are never tracked as windows")
-- Guard the other side: the denylist must not swallow a project whose name merely starts
-- with a temp segment. '/opt/apps/tmpl' is a real folder, not the temp root.
local tkeep = {}
core.upsert_recent(tkeep, {cwd="/opt/apps/tmpl", project="tmpl", host="vps"}, 100)
t.eq(tkeep["vps|/opt/apps/tmpl"].project, "tmpl", "a project whose name starts with 'tmp' is still a window")

t.describe("title-only inheritance is limited to throwaway cwds")
-- Regression: build_deck let ANY title-only card borrow a sibling's folder, so a LOCAL
-- session in its own repo inherited an unrelated remote project's name — the real cwd
-- '…/git/claude-dock-station' was labeled 'crm' purely from a conversation-title collision.
-- Only a temp/scratchpad cwd (which has no folder of its own) may inherit.
local xwins = { { title = "Revisar a página in… — crm [SSH: my-vps]", id = 5 } }
local xdeck = core.build_deck({
  { session_id="remote", cwd="/opt/apps/crm", state="working", updated_at=100, host="my-vps",
    title="Verificar status da implementação" },
  -- shares the window's title prefix, but has a REAL cwd of its own -> must keep its own name
  { session_id="localrepo", cwd="/Users/dev/Documents/Dev/git/claude-dock-station",
    root="/Users/dev/Documents/Dev/git/claude-dock-station", state="working", updated_at=100,
    title="Revisar a página inicial para prospecção" },
}, xwins, 100, { stale_secs = 900 })
local xby = {}
for _, c in ipairs(xdeck) do xby[c.session_id] = c end
t.eq(xby.remote.project, "crm", "the real crm session keeps its folder")
t.eq(xby.localrepo.project, "claude-dock-station", "a real cwd never inherits another project's label")

t.describe("window_folder: read the folder out of the VS Code title")
-- Verified against the 6 real windows: VS Code's default title is
-- "${activeEditorShort} — ${rootName}", and rootName carries " [SSH: host]" when remote.
-- rootName IS the folder the window was opened at — the thing the label wants.
t.eq(core.window_folder("Preparar a proposta com… — acme [SSH: my-vps]"), "acme",
     "remote title -> folder, SSH suffix stripped")
t.eq(core.window_folder("Corrigir nomes dos proje… — claude-dock-station-wt"), "claude-dock-station-wt",
     "local titles name the folder too (they are not title-only, contrary to the old comment)")
t.eq(core.window_folder("Adicionar o filtro de d… — webapp [SSH: my-vps]"), "webapp",
     "multibyte ellipsis in the editor name does not confuse the separator scan")
t.eq(core.window_folder("sem separador nenhum"), nil, "no separator (no editor open) -> nil")
t.eq(core.window_folder(""), nil, "empty title -> nil")
-- A VS Code profile appends "${separator}${profileName}", so the last chunk is NOT the folder.
-- window_folder cannot know that; the slug cross-check below is what catches it.
t.eq(core.window_folder("a — acme [SSH: my-vps] — Perfil Dev"), "Perfil Dev",
     "profile name lands in the last chunk (why the caller must corroborate)")

t.describe("scratchpad card: title + slug must agree")
-- A scratchpad cwd carries the session's project as a slug: /tmp/claude-<uid>/<slug>/<uuid>/…
-- where <slug> is the project path with '/' turned into '-'. Two independent signals — the
-- window title and the slug — so a mis-parsed title cannot silently rename a card.
local slugwins = { { title = "Preparar a proposta com… — acme [SSH: my-vps]", id = 9 } }
local slugdeck = core.build_deck({
  -- NO sibling session in this window: the old code fell back to the meaningless leaf 'shots'
  { session_id="shots", cwd="/tmp/claude-1000/-opt-clients-acme/f298b84d/scratchpad/shots",
    state="done", updated_at=100, host="my-vps", title="Preparar a proposta comercial" },
}, slugwins, 100, { stale_secs = 900 })
t.eq(slugdeck[1].project, "acme", "title says 'acme' and the slug agrees -> card is acme")

-- Profile case: the title parses to "Perfil Dev", the slug does NOT corroborate it -> refuse
-- the name and keep the leaf. Wrong-but-plausible is worse than obviously-unknown.
local profwins = { { title = "Preparar a proposta com… — acme [SSH: my-vps] — Perfil Dev", id = 9 } }
local profdeck = core.build_deck({
  { session_id="shots", cwd="/tmp/claude-1000/-opt-clients-acme/f298b84d/scratchpad/shots",
    state="done", updated_at=100, host="my-vps", title="Preparar a proposta comercial" },
}, profwins, 100, { stale_secs = 900 })
t.eq(profdeck[1].project, "shots", "slug refutes the parsed name -> falls back to the leaf")

-- The slug corroborates an ANCESTOR folder too: a deploy-layout session (…/webapp/production/repo)
-- runs in a window opened at 'webapp', so the folder sits mid-slug, not at its end.
local deepwins = { { title = "Adicionar o filtro… — webapp [SSH: my-vps]", id = 8 } }
local deepdeck = core.build_deck({
  { session_id="sp", cwd="/tmp/claude-1000/-opt-apps-webapp-production-repo/abc/scratchpad",
    state="done", updated_at=100, host="my-vps", title="Adicionar o filtro de data" },
}, deepwins, 100, { stale_secs = 900 })
t.eq(deepdeck[1].project, "webapp", "folder found mid-slug still corroborates")

-- A real sibling still wins: real cwd data beats parsing when both are available.
local sibwins = { { title = "Revisar a página in… — crm [SSH: my-vps]", id = 5 } }
local sibdeck = core.build_deck({
  { session_id="real", cwd="/opt/apps/crm", state="working", updated_at=100, host="my-vps",
    title="Verificar status" },
  { session_id="scr", cwd="/tmp/claude-1000/-opt-apps-crm/e282/scratchpad", state="done", updated_at=100,
    host="my-vps", title="Revisar a página inicial" },
}, sibwins, 100, { stale_secs = 900 })
local sibby = {}
for _, c in ipairs(sibdeck) do sibby[c.session_id] = c end
t.eq(sibby.scr.project, "crm", "sibling folder still names the scratchpad card")

t.describe("a repo-less deep cwd is named by the window it links to")
-- REAL case from the host: '/opt/clients/globex' has NO git repo, so the hook sends root="".
-- With no root the label falls to the segment heuristic, which caps at 2 candidates and so can
-- never reach 'globex' from a docs/ subfolder — it offered {_anexos, Campanha-Aniversario}
-- and the card showed '_anexos'. The window itself always knew: its title names the folder.
-- The cwd is what corroborates the parsed name — a profile name or a colliding window's folder
-- is never a segment of the session's own cwd.
local swins = { { title = "Preparar o material de la… — globex [SSH: my-vps]", id = 11 } }
local ws1, segs1 = core.match_window("/opt/clients/globex/docs/Campanha-Aniversario/_anexos",
                                     swins, "Preparar o material de lançamento", "")
t.eq(ws1 and ws1.id, 11, "repo-less deep cwd links to its window via the window's own folder")
t.eq(segs1, "globex", "matched segment is the folder the window shows")

local sdeck = core.build_deck({
  { session_id="fon", cwd="/opt/clients/globex/docs/Campanha-Aniversario/_anexos",
    root="", state="working", updated_at=100, host="my-vps",
    title="Preparar o material de lançamento" },
  { session_id="mail", cwd="/opt/clients/globex/docs/Campanha-Agradecimento",
    root="", state="done", updated_at=100, host="my-vps",
    title="Preparar o material de lançamento" },
}, swins, 100, { stale_secs = 900 })
local sby = {}
for _, c in ipairs(sdeck) do sby[c.session_id] = c end
t.eq(sby.fon.project, "globex", "card named by the window, not the '_anexos' leaf")
t.eq(sby.mail.project, "globex", "sibling subfolder card is named by the same window")

-- ...and because the label is what workspace_path truncates on, every subfolder session of the
-- one globex window collapses to ONE launcher entry instead of six.
local sstore = {}
for _, c in ipairs(sdeck) do core.upsert_recent(sstore, c, 100) end
local sc=0; for _ in pairs(sstore) do sc=sc+1 end
t.eq(sc, 1, "every subfolder of the one globex window collapses to a single entry")
t.eq(sstore["my-vps|/opt/clients/globex"].cwd, "/opt/clients/globex",
     "entry keyed at the folder VS Code actually opened")

-- A window folder that is generic scaffolding must NOT grab sessions: a window opened at a
-- folder literally named 'Dev' would otherwise claim every session under ~/Documents/Dev.
local gwins = { { title = "algo… — Dev", id = 12 } }
t.eq(core.match_window("/Users/dev/Documents/Dev/git/some-app", gwins, "", ""), nil,
     "a generic window folder never claims a session")

-- Nested windows: a worktree lives INSIDE its parent repo, so BOTH folders are segments of the
-- cwd and both windows are open. Deep enough that no cwd candidate reaches either window title
-- (the {functions, supabase} leaves match nothing), so this lands in the window-title pass —
-- where iterating windows in list order would hand the session to the ANCESTOR and silently fold
-- the worktree into the parent's launcher entry. The deepest matching folder is the real window.
local nestwins = {
  { title = "Listar hardcodes do módu… — webapp [SSH: my-vps]", id = 20 },   -- ancestor, listed first
  { title = "Auditar a fase 0… — fase0-auth [SSH: my-vps]", id = 21 },   -- the real one
}
local nestcwd = "/opt/apps/webapp/production/repo/.claude/worktrees/fase0-auth/supabase/functions"
local wn, segn = core.match_window(nestcwd, nestwins, "", "")
t.eq(wn and wn.id, 21, "session links to the deepest matching window, not its ancestor")
t.eq(segn, "fase0-auth", "worktree keeps its own identity")
-- ...and a session in the PARENT repo (outside the worktree) still lands on the parent window.
local wp, segp = core.match_window("/opt/apps/webapp/production/repo/supabase/functions", nestwins, "", "")
t.eq(wp and wp.id, 20, "the parent repo's own session still links to the parent window")
t.eq(segp, "webapp", "parent session labeled webapp")

t.describe("container_child: a declared container names its direct child")
-- A container is a folder whose DIRECT CHILDREN are projects; the container itself never is.
-- This is the signal that survives when no window and no repo can name the project.
-- Deepest listed FIRST, deliberately: the code ranks by depth, not position. ONE ordering can
-- never prove order-independence — it only rules out the OPPOSITE order-dependent bug. Listing
-- shallow first leaves a last-match implementation alive; listing deep first leaves a first-match
-- one alive. That is why the deepest-wins case below is asserted at BOTH orderings; together they
-- kill first-match, last-match and shortest-string alike.
local CONT = { "/opt/clients/globex/sites", "/opt/clients" }
t.eq(core.container_child("/opt/clients/acme", CONT), "acme",
     "direct child of a container is the project")
t.eq(core.container_child("/opt/clients/acme/production/repo", CONT), "acme",
     "a deep cwd still resolves to the container's direct child")
-- Nested containers: the NARROWER declaration must refine the broader one, or declaring a
-- sub-container would be pointless — '/opt/clients' alone would keep answering 'globex'.
t.eq(core.container_child("/opt/clients/globex/sites/arcade", CONT), "arcade",
     "the DEEPEST container wins over a shallower one")
-- Same expectation with the declaration order flipped. Config is hand-written, so the broad
-- container may well be listed after the narrow one; the answer must not depend on that.
t.eq(core.container_child("/opt/clients/globex/sites/arcade",
     { "/opt/clients", "/opt/clients/globex/sites" }), "arcade",
     "deepest wins regardless of declaration order (shallow listed first)")
-- The container itself is not a project: it has no child to name.
t.eq(core.container_child("/opt/clients", CONT), nil, "the container itself is never a project")
-- Prefix guard: a sibling whose name merely starts with the container's name is NOT inside it.
t.eq(core.container_child("/opt/clients-archive/acme", CONT), nil,
     "a name that only shares the container's prefix is not contained")
-- Absent config must be inert — this is what keeps the shipped default ({}) a no-op.
t.eq(core.container_child("/opt/clients/acme", {}), nil, "no containers -> no opinion")
t.eq(core.container_child("/opt/clients/acme", nil), nil, "nil containers -> no opinion")
-- A trailing slash in hand-edited config must not defeat the match.
t.eq(core.container_child("/opt/clients/acme", { "/opt/clients/" }), "acme",
     "a trailing slash in the declared path is tolerated")
-- Hand-edited JSON can put anything in this list. A non-string entry must be skipped, not
-- indexed: core.container_child runs on every render tick, so an error here takes the whole
-- dock down rather than degrading one card.
t.eq(core.container_child("/opt/clients/acme", { 5, true, "/opt/clients" }), "acme",
     "non-string container entries are skipped, not indexed")

t.describe("project name = the DEEPEST signal (container / git root / window folder)")
-- The three signals compete on equal footing and the deepest one in the cwd wins. A tie is
-- reachable only between case-variants of ONE name (depth d is a single position, so both
-- tying labels are the same segment); consideration order settles the casing, never which
-- project. See resolve_project's comment in core.lua.
-- Deepest listed FIRST, same reasoning as CONT above: order-dependent iteration would answer
-- 'globex' instead of the deeper 'arcade'/'legal-app', so this ordering is what makes the
-- assertions below exercise depth-ranking instead of passing by list position.
local UCONT = { "/opt/clients/globex/sites", "/opt/clients" }
-- ONE window opened at the client root — the scenario that collapses today. Every session
-- below it matched the client's name because the window folder is coarser than the project.
local uwin = { { id = 1, title = "arq.ts — globex [SSH: my-vps]" } }
local function name_of(cwd, root, containers)
  local st = { { session_id = "s", cwd = cwd, root = root, state = "idle", updated_at = 100 } }
  local d = core.build_deck(st, uwin, 100, { containers = containers })
  return d[1] and d[1].project or nil
end
-- Baseline: without containers, both sub-projects collapse into the window's folder.
t.eq(name_of("/opt/clients/globex/sites/arcade", "", nil), "globex",
     "no containers -> the coarse window folder still wins (today's behaviour)")
-- With the sub-container declared, each project keeps its own identity.
t.eq(name_of("/opt/clients/globex/sites/arcade", "", UCONT), "arcade",
     "container beats a shallower window folder")
t.eq(name_of("/opt/clients/globex/sites/legal-app", "", UCONT), "legal-app",
     "sibling project under the same container stays separate")
-- No windows at all: the ONLY signal left is the container. With uwin passed instead,
-- Pass 1b would answer "globex" from the title on its own and the container branch could
-- be deleted without failing this assertion.
local function name_no_window(cwd, root, containers)
  local st = { { session_id = "s", cwd = cwd, root = root, state = "idle", updated_at = 100 } }
  local d = core.build_deck(st, {}, 100, { containers = containers })
  return d[1] and d[1].project or nil
end
t.eq(name_no_window("/opt/clients/globex/docs/Campanha-Aniversario/_anexos", "", UCONT), "globex",
     "container names a repo-less project with NO window open at all")
-- Same cwd, no container: the deep leaf is all that is left. This is the pair that proves
-- the container did the work.
t.eq(name_no_window("/opt/clients/globex/docs/Campanha-Aniversario/_anexos", "", nil), "_anexos",
     "without the container, a repo-less deep cwd falls back to its leaf")
-- A git root DEEPER than the container must win: a worktree has its own root, so it keeps its
-- identity without anyone declaring '.../worktrees' as a container.
t.eq(name_of("/opt/apps/webapp/worktrees/arcade", "/opt/apps/webapp/worktrees/arcade",
             { "/opt/apps" }), "arcade",
     "a deeper git root beats the container child")

-- The window folder must WIN when it is deeper than the container child: a window opened
-- directly on the sub-project outranks a container that only names its parent. Without the
-- `seg` line in resolve_project the fallback chain silently answers with the container child.
local deepwin = { { id = 9, title = "arq.ts — arcade [SSH: my-vps]" } }
local dst = { { session_id = "s", cwd = "/opt/clients/globex/sites/arcade/src",
                root = "", state = "idle", updated_at = 100 } }
t.eq(core.build_deck(dst, deepwin, 100, { containers = { "/opt/clients" } })[1].project, "arcade",
     "a window folder deeper than the container child wins")

-- folder_by_window must carry the RAW window folder, not the resolved name. A scratchpad
-- session has no folder of its own and borrows this from a sibling in the same window; if the
-- container's resolved name were stored instead, the scratchpad card would inherit a label
-- that is not the folder VS Code shows.
local shwin = { { id = 11, title = "arq.ts — globex [SSH: my-vps]" } }
local shared = {
  { session_id = "real", cwd = "/opt/clients/globex/sites/arcade", root = "",
    state = "idle", updated_at = 100 },
  { session_id = "scratch", cwd = "/tmp/claude-1000/-opt-clients-globex/ab/scratchpad",
    title = "arq.ts", state = "idle", updated_at = 100 },
}
local shby = {}
for _, c in ipairs(core.build_deck(shared, shwin, 100, { containers = { "/opt/clients/globex/sites" } })) do
  shby[c.session_id] = c
end
t.eq(shby.real.project, "arcade", "the real session is named by its container child")
t.eq(shby.scratch.project, "globex", "the scratchpad borrows the RAW window folder, not the resolved name")

t.describe("prune")
local has = function(s) return s.cwd == "/live" end
local states = {
  { session_id="1", cwd="/live",  state="working", updated_at=1000 },
  { session_id="2", cwd="/dead",  state="ended",   updated_at=1000 },
  { session_id="3", cwd="/gone",  state="done",    updated_at=10   },  -- no window + old
  { session_id="4", cwd="/gone2", state="done",    updated_at=999  },  -- no window but fresh
}
local kept = core.prune(states, has, 1000, 900)
local ids = {}
for _, s in ipairs(kept) do ids[#ids+1] = s.session_id end
t.eq(ids, {"1","4"}, "keeps live + fresh-no-window; drops ended + stale-no-window")

t.describe("sort_cards")
local cards = {
  { session_id="w", rank=2, age_secs=5 },
  { session_id="n", rank=0, age_secs=50 },
  { session_id="d1", rank=1, age_secs=30 },
  { session_id="d2", rank=1, age_secs=10 },
}
local sorted = core.sort_cards(cards)
local order = {}
for _, c in ipairs(sorted) do order[#order+1] = c.session_id end
t.eq(order, {"n","d2","d1","w"}, "needs_you first, then done by freshness, then working")

t.describe("build_deck")
local ws = { { title="webapp-core — a", id=7 } }
local st = {
  { session_id="1", cwd="/x/webapp-core", state="working", updated_at=90 },
  { session_id="2", cwd="/x/other",        state="needs_you", updated_at=80 },
}
local deck = core.build_deck(st, ws, 100, { stale_secs = 900 })
t.eq(deck[1].session_id, "2", "needs_you sorts first")
t.eq(deck[1].window, nil, "session 2 has no matching window")
t.eq(deck[2].window.id, 7, "session 1 gets matched window")

t.describe("merge_config")
local cfg = core.merge_config({ a=1, b=2 }, { b=9, zzz=5 })
t.eq(cfg, { a=1, b=9 }, "loaded overrides known keys, unknown dropped")

t.describe("host on card")
t.eq(core.to_card({session_id="r",cwd="/home/claude/webapp",state="working",updated_at=100,host="my-vps"},100).host,
     "my-vps", "remote state carries host onto card")
t.eq(core.to_card({session_id="l",cwd="/x/y",state="working",updated_at=100},100).host,
     nil, "local state has nil host")
local rdeck = core.build_deck({{session_id="r",cwd="/home/claude/webapp",state="needs_you",updated_at=100,host="my-vps"}}, {}, 100, {stale_secs=900})
t.eq(rdeck[1].host, "my-vps", "host survives build_deck pipeline")

t.describe("title on card")
t.eq(core.to_card({session_id="t",cwd="/x/edu",state="working",updated_at=100,title="Adicionar miniaturas"},100).title,
     "Adicionar miniaturas", "ai-title carried onto card")

t.describe("take")
t.eq(core.take({"a","b","c"}, 2), {"a","b"}, "take first 2")
t.eq(core.take({"a","b","c"}, 0), {"a","b","c"}, "0 = all")
t.eq(core.take({"a","b"}, 5), {"a","b"}, "n > len = all")
t.eq(core.take({}, 3), {}, "empty stays empty")

t.describe("mosaic_dims")
local d1 = core.mosaic_dims(5, 1000, { tile=150, screen_h=1000 })
t.eq(d1.cols, 5, "auto cols: 1000px wide, 150 tile -> 5 columns")
t.eq(d1.rows, 1, "5 cards / 5 cols = 1 row")
t.eq(d1.height, 198, "1 row height = 48 pad + 150 tile")
t.ok(not d1.capped, "1 row is not capped")

local d2 = core.mosaic_dims(7, 1000, { columns=3, tile=150, screen_h=1000 })
t.eq(d2.cols, 3, "explicit columns respected")
t.eq(d2.rows, 3, "7 cards / 3 cols = 3 rows")
t.eq(d2.height, 530, "3 rows = 48 pad + 450 tiles + 32 gaps")
t.ok(not d2.capped, "530 < 600 cap")

local d3 = core.mosaic_dims(13, 1000, { columns=3, tile=150, screen_h=1000 })
t.eq(d3.rows, 5, "13 cards / 3 cols = 5 rows")
t.eq(d3.height, 600, "capped at 60% of 1000px screen")
t.ok(d3.capped, "content taller than cap -> capped = true")

local d4 = core.mosaic_dims(0, 1000, { tile=150, screen_h=1000 })
t.eq(d4.rows, 0, "no cards -> 0 rows")
t.eq(d4.height, 128, "empty band = 48 pad + 80 for the message")

t.describe("migrate_view")
local mv1 = core.migrate_view({ shells={panel=true,mosaic=false,bar=false,overlay=true,menubar=true},
                                panel={screen="UUID1"}, mosaic={screen="main"}, bar={screen="UUID2"} })
t.eq(mv1.shells.view, "panel", "old panel=true -> view=panel")
t.eq(mv1.screen, "UUID1", "single screen inherited from active view (panel)")
local mv2 = core.migrate_view({ shells={panel=false,mosaic=true,bar=false}, mosaic={screen="UUIDm"} })
t.eq(mv2.shells.view, "mosaic", "mosaic=true wins -> view=mosaic")
t.eq(mv2.screen, "UUIDm", "single screen inherited from active view (mosaic)")
local mv3 = core.migrate_view({ shells={panel=false,mosaic=false,bar=false} })
t.eq(mv3.shells.view, "none", "nothing active -> view=none")
local mv4 = core.migrate_view({ shells={view="bar", overlay=true}, screen="keep" })
t.eq(mv4.shells.view, "bar", "existing view untouched (idempotent)")
t.eq(mv4.screen, "keep", "existing screen untouched")

t.describe("window_key + upsert_recent (dedup by window, not session)")
t.eq(core.window_key("vps", "/x/proj"), "vps|/x/proj", "remote key = host|cwd")
t.eq(core.window_key(nil, "/x/proj"), "local|/x/proj", "local key = local|cwd")
local store = {}
core.upsert_recent(store, {session_id="s1", cwd="/x/proj", project="proj", host="vps", title="T1"}, 100)
core.upsert_recent(store, {session_id="s2", cwd="/x/proj", project="proj", host="vps", title="T2"}, 200)
local wcount=0; for _ in pairs(store) do wcount=wcount+1 end
t.eq(wcount, 1, "two sessions in the same window (host+cwd) collapse to ONE entry")
t.eq(store["vps|/x/proj"].last_seen, 200, "kept the most-recent last_seen")
t.eq(store["vps|/x/proj"].title, "T2", "kept the most-recent fields")
core.upsert_recent(store, {session_id="s3", project="noproj"}, 300)
local wcount2=0; for _ in pairs(store) do wcount2=wcount2+1 end
t.eq(wcount2, 1, "card without cwd ignored")
-- subfolder sessions of one window collapse via the workspace folder (build_deck sets project=folder)
core.upsert_recent(store, {cwd="/opt/apps/webapp/production/repo", project="webapp", host="vps"}, 300)
core.upsert_recent(store, {cwd="/opt/apps/webapp", project="webapp", host="vps"}, 400)
t.eq(store["vps|/opt/apps/webapp"].cwd, "/opt/apps/webapp", "webapp root + subfolder -> one window at the workspace folder")
-- scratchpad/temp cwds are never real windows (even if a session matched a window by title)
local ts = {}
core.upsert_recent(ts, {cwd="/tmp/claude/xxx/scratchpad/juris", project="juris", host="k"}, 1)
core.upsert_recent(ts, {cwd="/private/var/folders/ab/cd", project="cd", host="k"}, 1)
local tc=0; for _ in pairs(ts) do tc=tc+1 end
t.eq(tc, 0, "temp/scratchpad cwds are not tracked as windows")

t.describe("workspace_path")
t.eq(core.workspace_path("/opt/apps/webapp/production/repo", "webapp"), "/opt/apps/webapp", "truncate at project segment")
t.eq(core.workspace_path("/opt/clients/globex", "globex"), "/opt/clients/globex", "leaf project = full path")
t.eq(core.workspace_path("/x/y", nil), "/x/y", "no project -> full cwd")

t.describe("recent_windows")
local st = { ["h|/a"]={cwd="/a",project="pa",title="ta",host="h",last_seen=90},
             ["h|/b"]={cwd="/b",project="pb",title="tb",host="h",last_seen=50},
             ["local|/c"]={cwd="/c",project="pc",last_seen=80} }
local rw = core.recent_windows(st, {["h|/a"]=true}, 100)
local rkeys={}; for _,w in ipairs(rw) do rkeys[#rkeys+1]=w.key end
t.eq(rkeys, {"h|/a","local|/c","h|/b"}, "all windows, most-recent first (a=10,c=20,b=50)")
t.eq(rw[1].active, true, "window in live_keys is active")
t.eq(rw[2].active, false, "window not live is inactive")
t.eq(rw[1].age_secs, 10, "age = now - last_seen")
t.eq(#core.recent_windows(st, {}, 100, 2), 2, "limit caps the list")

t.describe("prune_recents")
local ps = { a={last_seen=10}, b={last_seen=30}, c={last_seen=20}, d={last_seen=5} }
core.prune_recents(ps, 2)
local pk={}; for k in pairs(ps) do pk[k]=true end
t.eq(pk, {b=true, c=true}, "keeps the 2 newest (b=30,c=20); drops a,d")
core.prune_recents(ps, 0)
local pc=0; for _ in pairs(ps) do pc=pc+1 end
t.eq(pc, 2, "max<=0 = no prune")

t.describe("relaunch_cmd")
t.eq(core.relaunch_cmd({host="my-vps", cwd="/root/proj"}),
     [['code' --folder-uri "vscode-remote://ssh-remote+my-vps/root/proj"]], "remote -> vscode-remote uri (code on PATH)")
t.eq(core.relaunch_cmd({cwd="/Users/m/proj"}), [['code' '/Users/m/proj']], "local -> code <path>")
t.eq(core.relaunch_cmd({host="h", cwd="/p"}, "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"),
     [['/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code' --folder-uri "vscode-remote://ssh-remote+h/p"]], "code_bin override quoted")

t.run()
