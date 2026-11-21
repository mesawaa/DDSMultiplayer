-- Olivia's wall: how a player gets the one hair colour Olivia will not do.
--
-- The blue is Amy's (the gas station): Olivia mixed it for her, and for nobody since the
-- writing appeared on the barbershop's wall. The story, a step at a time:
--
--   0  nothing yet. What the player pays at Olivia's is counted; from SPEND on she has
--      one more answer, "What's with the wall outside?". She paints over the writing and
--      it comes back; the gas station is the only place that sells spray cans.
--   1  ask Amy who buys the cans. She cannot remember faces half asleep: five grams of
--      amphetamine, and "don't you dare think about cutting it". (She takes it from PURITY
--      up. The player is never told that number: how far to cut it is their gamble.)
--   2  bring them: they are handed over in the game's own window for a sale (drag them
--      from the pockets, ACCEPT), for no money. Exactly five grams, and what is in the
--      window is hers when it is accepted. Cut too far, she keeps it and wants something
--      else instead: one gram of cocaine, and that one pure (said out loud this time).
--      A gram of cocaine that is cut she keeps as well, and that is the end of it: the
--      quest has failed for this player, for good (step -1). With the real thing, the
--      five grams or the one, she admits it is her: Olivia would not touch her hair again until she
--      got clean. She is tired of it and will not write it again.
--   3  paint over the writing, only now, in three parts, each one spray from a can (a
--      full can for the whole line). It is done the way walls are sprayed in the game:
--      hold F with a can in the pockets. Such a spray on the writing paints a part over
--      and leaves the player's tag on the paint; it is no wall marking (nothing of the
--      territory changes with it), and the wall can be sprayed three times although a
--      marked wall cannot be marked again. There is no other way to do it: a player
--      sprays once the game lets them (its story switches spraying on).
--   4  tell Olivia. She mixed the blue for Amy when they were best friends and swore
--      nobody else would wear it; Amy swore she would stay clean and broke that first, so
--      Olivia's promise is off. (They are still angry with each other.)
--   5  done: Blue is among Olivia's colours.
--
-- The goal of the moment is shown the way the game shows a task: its banner, a task
-- marker on the map and the compass, a line in the organizer's task list; a step done
-- gives experience as the game's early tasks do. None of it is a task of the game's (its
-- task table is saved and shared between players; this is one player's own).
--
-- Every player has their own: the step is kept where the "who are you" choice is kept
-- (coop/guests.lua: beside the save, a guest's with the host), and what a game shows (the
-- answers, the wall, the colour) is that game's player's. Nothing of the game's own is
-- changed for good: Amy's dialogue is saved with the world, so she gets a copy of it that
-- is not (her own is put back whenever the player is away or the step needs nothing of
-- her); the writing is hidden, not removed; nothing here is written into a save.

local Core = require("core")
local World = require("coop.world")
local Repl = require("coop.repl")
local Guests = require("coop.guests")
local Hud = require("coop.hud")
local Look = require("coop.look")
local Barber = require("coop.barber")

local log, valid = Core.log, Core.valid

local GEN = (rawget(_G, "DDSMP_WALLQUEST_GEN") or 0) + 1
_G.DDSMP_WALLQUEST_GEN = GEN
local function live() return rawget(_G, "DDSMP_WALLQUEST_GEN") == GEN end

local Quest = { TITLE = "Olivia's wall", SPEND = 500, GRAMS = 5, PURITY = 0.95, BLUE = "MI_ma_hair_03_amy", DRUG = "DRUG-AMPHETAMINE",
    -- what Amy wants after five grams that were cut: this much of this, and nothing else in it
    SECOND = "DRUG-COCAINE", SECOND_GRAMS = 1, SECOND_PURITY = 1 }

local NONE, ASK, BRING, COVER, TELL, DONE = 0, 1, 2, 3, 4, 5
local FAILED = -1         -- Amy got a second cut bag: nothing more comes of it for this player
Quest.NONE, Quest.ASK, Quest.BRING, Quest.COVER, Quest.TELL, Quest.DONE, Quest.FAILED = NONE, ASK, BRING, COVER, TELL, DONE, FAILED

-- What to do at each step (the banner and the map marker say it).
local GOAL = {
    [ASK] = "Ask Amy at the gas station who buys spray cans",
    [BRING] = "Bring Amy 5g of Amphetamine",      -- (how clean it has to be is not said anywhere: PURITY)
    [COVER] = "Paint over the writing on Olivia's wall",
    [TELL] = "Tell Olivia her wall is clean",
}

-- Experience for having done a step (the game's early tasks give 150 to 600 each).
local REWARD = { [ASK] = 150, [BRING] = 300, [COVER] = 350, [TELL] = 250 }

local AMY_CLASS = "/Game/Skeletal/NPC/ShopOwners/Amy/npcAmy.npcAmy_C"
local DIALOGUE = "/Game/Interactive/dialogueInstance.dialogueInstance_C"
local BANNER = "/Game/GUI/PopupWidgets/newTaskWidget.newTaskWidget_C"
local PLAYER = "/Game/Player/playerCharacterBP.playerCharacterBP_C"
local INVENTORY = "/Game/Player/inventoryScreen.inventoryScreen_C"
local TASK_ENTRY = "/Game/GUI/oneTaskWidget.oneTaskWidget_C"
local MARKER_TASK = 4         -- the game's marker for a task: the exclamation mark, on map and compass

-- The writing: a decal on the north wall of Olivia's building, facing an alley. The line
-- of text itself is about 340 wide and 30 high around TEXT. The same decal holds the
-- anarchy sign below the line's right half (its top about 55 under the line's middle):
-- the decal is never hidden, and the paint must not reach down to the sign.
local WRITING = "oliviaWhoreDecal"
local STAINS = "leakWall"           -- the leak stains on the same wall (a decal of the game's)
local WALL = { x = -3054.5, y = -1920, z = 309.3 }
local TEXT = { x = -3054.5, z = 362, w = 430, h = 60 }
local PAINT = { 0.4, 0.41, 0.4 }            -- wall paint: a grey a little lighter than the concrete
local AMY_RANGE = 2500
local MARKING = "/Game/TerritorySpraying/wallSprayMarking.wallSprayMarking_C"
local GIZMO = "/Game/TerritorySpraying/sprayPlacementGizmo.sprayPlacementGizmo_C"
local TAG_SIZE = 150          -- a sprayed tag on the paint, when the game's own size is not known
local TAG_LIFE = 1800         -- seconds it stays, when the game's own time for a wall marking is not known
local OURS = "DDSMP-WALL"

---------------------------------------------------------------- the player's step

local mine = nil          -- { s, spent }: this world's player; nil until it is known
local mineFor = nil

local function worldKey(player)
    return tostring(player:GetAddress()) .. "/" .. tostring(World.loadStartedAt)
end

-- The record this is kept in is written by coop/look.lua as a whole (the choice and what
-- is owned): whatever it writes keeps the step.
if not rawget(_G, "DDSMP_WALLQUEST_SETSELF") then _G.DDSMP_WALLQUEST_SETSELF = Guests.setSelf end
local setSelf = _G.DDSMP_WALLQUEST_SETSELF
Guests.setSelf = function(record)
    if live() and type(record) == "table" and record.wq == nil then
        local old = Guests.self()
        if type(old) == "table" and type(old.wq) == "table" then
            record.wq = old.wq
        elseif mine and (mine.s ~= NONE or mine.spent > 0) then
            local player = World.player()
            if player and mineFor == worldKey(player) then record.wq = { s = mine.s, spent = mine.spent, c = mine.c, t = mine.t, k = mine.k } end
        end
    end
    return setSelf(record)
end

local function store()
    local r = Guests.ready() and Guests.self() or nil
    if type(r) ~= "table" or not mine then return end      -- (nobody yet: it goes in with the choice)
    r.wq = { s = mine.s, spent = mine.spent, c = mine.c, t = mine.t, k = mine.k }
    Guests.setSelf(r)
end

local function learn(player)
    local key = worldKey(player)
    if mineFor == key and mine then return true end
    if not Guests.ready() then return false end
    local r = Guests.self()
    local q = type(r) == "table" and type(r.wq) == "table" and r.wq or {}
    -- (c: which parts of the writing are painted over, bits 1, 2 and 4)
    mine = { s = math.max(FAILED, math.min(DONE, math.floor(tonumber(q.s) or 0))), spent = math.max(0, math.floor(tonumber(q.spent) or 0)),
        c = math.floor(tonumber(q.c) or 0) & 7, t = {} }
    -- (k: at the step "bring", Amy is on her second demand, the gram of cocaine)
    mine.k = (q.k == true and mine.s == BRING) or nil
    -- (t: the player's tags on the paint: where, how big, and for how many more seconds:
    -- { x, z, w, l } each)
    for i, t in ipairs(type(q.t) == "table" and q.t or {}) do
        if i <= 3 and type(t) == "table" and tonumber(t.x) and tonumber(t.z) then
            mine.t[#mine.t + 1] = { x = tonumber(t.x), z = tonumber(t.z), w = tonumber(t.w) or TAG_SIZE, l = tonumber(t.l) or TAG_LIFE }
        end
    end
    mineFor = key
    log("Wall: this player is at step %d (%d paid at Olivia's)", mine.s, mine.spent)
    -- (the HUD made its task list before this was known: once more, with the goal in it)
    if GOAL[mine.s] then
        Core.after(2, function()
            if not live() or World.gone then return end
            pcall(function()
                local hud = World.player().HUD
                if valid(hud) then hud:updateMiniTaskList() end
            end)
        end)
    end
    return true
end

function Quest.step() return mine and mine.s or NONE end
function Quest.state() return mine end

-- What Amy wants handed over right now.
local function demand()
    if mine and mine.k then return { drug = Quest.SECOND, grams = Quest.SECOND_GRAMS, purity = Quest.SECOND_PURITY, second = true } end
    return { drug = Quest.DRUG, grams = Quest.GRAMS, purity = Quest.PURITY }
end

-- The goal of the moment in words, nil when there is none.
local function goalText()
    if not mine then return nil end
    if mine.s == BRING and mine.k then return "Bring Amy 1g of Cocaine" end
    return GOAL[mine.s]
end

---------------------------------------------------------------- telling the player

-- The game's own "new task" banner (status 0 new, 1 done).
local function banner(desc, status)
    local player = World.player()
    if not player then return end
    local ok = pcall(function()
        local class = StaticFindObject(BANNER)
        if not valid(class) then
            pcall(function() LoadAsset((BANNER:gsub("%.[^%.]+$", ""))) end)
            class = StaticFindObject(BANNER)
        end
        local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        local w = lib:Create(player, class, nil)
        w:Setup(FText(Quest.TITLE), FText(desc), status or 0)
        w:AddToViewport(6)
    end)
    if not ok then Hud.toast(Quest.TITLE .. ": " .. desc, 6) end
end

local marker = nil        -- { actor, owner, step }
local function dropMarker()
    local m = marker
    marker = nil
    if m and not World.gone then
        pcall(Hud.forgetMarker, m.actor)
        pcall(function() if Core.alive(m.actor) then m.actor:K2_DestroyActor() end end)
        pcall(function() World.player().HUD:refreshCompass() end)
    end
end

local amyAt = nil         -- where Amy stands in this world (learned when she is seen)

local function tendMarker(player)
    local s = mine.s
    local goal = goalText()
    local want = goal ~= nil and Hud.ready()
    local key = worldKey(player)
    if marker and (marker.owner ~= key or marker.step ~= s or marker.goal ~= goal or not Core.alive(marker.actor)) then
        if marker.owner ~= key then marker = nil else dropMarker() end
    end
    if not want or marker then return end
    local x, y, z
    if s == ASK or s == BRING then
        local a = amyAt or { x = 6061, y = -7292, z = 172 }
        x, y, z = a.x, a.y, a.z
    elseif s == COVER then
        x, y, z = WALL.x, WALL.y + 60, 200
    else
        x, y, z = Barber.SPOT.x, Barber.SPOT.y, Barber.SPOT.z
    end
    local actor = Hud.mapMarker(Quest.TITLE, goal, x, y, z, MARKER_TASK)
    if actor then
        marker = { actor = actor, owner = key, step = s, goal = goal }
        -- (the marker gets its kind a second after it is made: the compass is drawn anew then)
        Core.after(1.4, function()
            if live() and marker and marker.actor == actor then pcall(function() World.player().HUD:refreshCompass() end) end
        end)
    end
end

-- The organizer's task list (the inventory screen draws it from the game's task table
-- whenever something changes): the goal of the moment is put on top of it.
local function listGoal(screen)
    if not goalText() then return end
    local list = screen.activeTaskList
    if not valid(list) then return end
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local class = StaticFindObject(TASK_ENTRY)
    if not valid(lib) or not valid(class) then return end
    local entry = lib:Create(screen, class, nil)
    if not valid(entry) then return end
    entry:Setup(FText(Quest.TITLE), FText(goalText()), false)
    -- (a panel only adds at its end: what it holds is taken out and put back after ours)
    local others = {}
    for i = 0, list:GetChildrenCount() - 1 do others[#others + 1] = list:GetChildAt(i) end
    list:ClearChildren()
    list:AddChild(entry)
    for _, w in ipairs(others) do if valid(w) then list:AddChild(w) end end
end

Core.Hooks.add(INVENTORY .. ":renderTasklist", function(ctx)
    if not live() or not goalText() then return end
    local ok, e = pcall(function()
        local screen = ctx:get()
        if valid(screen) then listGoal(screen) end
    end)
    if not ok then log("Wall: the task list: %s", tostring(e)) end
end)

-- The list of tasks at the left of the screen (it slides in for a few seconds when a task
-- is new, and while Tab is held): the game fills it from its task table in the HUD's
-- updateMiniTaskList. The goal of the moment is put on top of it, as one of the game's own
-- entries. (Never one that is "done" or "failed": such an entry writes into the game's task
-- table by its number when it goes.)
local HUD_CLASS = "/Game/Player/playerHUD.playerHUD_C"
local MINI_ENTRY = "/Game/GUI/miniTaskListItem.miniTaskListItem_C"

local function miniGoal(hud)
    local goal = goalText()
    if not goal then return end
    local list = hud.curTaskPanel
    if not valid(list) then return end
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local class = StaticFindObject(MINI_ENTRY)
    if not valid(lib) or not valid(class) then return end
    local entry = lib:Create(hud, class, nil)
    if not valid(entry) then return end
    entry:Setup(FText(goal), false, 0, false, false, false)
    local others = {}
    for i = 0, list:GetChildrenCount() - 1 do others[#others + 1] = list:GetChildAt(i) end
    list:ClearChildren()
    list:AddChild(entry)
    for _, w in ipairs(others) do if valid(w) then list:AddChild(w) end end
end

Core.Hooks.add(HUD_CLASS .. ":updateMiniTaskList", function(ctx)
    if not live() or not goalText() then return end
    local ok, e = pcall(function()
        local hud = ctx:get()
        if valid(hud) then miniGoal(hud) end
    end)
    if not ok then log("Wall: the HUD's task list: %s", tostring(e)) end
end)

local function refreshTaskList()
    pcall(function()
        local w = World.player().InventoryWidget
        if valid(w) then w:renderTasklist() end
    end)
    -- (the game's own call for a change of tasks: the list is made anew and shown a while)
    pcall(function()
        local hud = World.player().HUD
        if valid(hud) then hud:updateMiniTaskList() end
    end)
end

-- Experience, as the game gives it for a task (a little more at night).
local function reward(amount)
    if not amount or amount <= 0 then return end
    pcall(function()
        local night = false
        pcall(function()
            local h = Core.find("dayTimeControler_C").curHour
            night = h >= 22 or h <= 6
        end)
        Core.find("statisticsManager_C"):addExp(night and amount * 1.15 or amount)
    end)
end

local function advance(step, quiet)
    if not mine then return end
    local before = mine.s
    mine.s = step
    if step <= COVER then mine.c, mine.t = 0, {} end
    if step ~= BRING then mine.k = nil end
    store()
    log("Wall: step %d", step)
    if step == before + 1 then reward(REWARD[before]) end
    refreshTaskList()
    if quiet then return end
    if step == DONE then
        banner("Olivia mixes her blue again", 1)
    elseif step == FAILED then
        banner("Amy wants nothing more to do with it", 2)
    elseif goalText() then
        banner(goalText(), 0)
    end
end
Quest.advance = advance

---------------------------------------------------------------- dialogue lines

-- A dialogue is a list of lines; a line has what is said and four answers; an answer may
-- lead to another line (its number, from 0), end the talk, and with `event` have the
-- dialogue actor's (empty) SubclassLoaded function called when the talk ends: that is how
-- this module hears of it.
local F = {
    line = "DialogueLine_2_8B15268449F65976C471C581FC5582DB", audio = "DialogueAudio_5_AB869F204D883555C2EB44AEBCEA4839",
    r = { "Response01_23_59E9B44C445C519843261E8243697FED", "Response02_25_88B8209D400E5A6FFF8607B5AEC1A21B",
        "Response03_27_3943CC4D4027A576FA194B9BC91D3965", "Response04_29_19AF821E40CCD72AB3556489E54859CB" },
    text = "ResponseText_2_3DC4585B4FB4F1C79DACFAA7F3A5BBD7", next = "ResponseNextID_5_B03F1ECB41D0DA0A004B2094CBDB92BE",
    exits = "ExitsDialogue_8_F9D0948C4212613C0EB7A99AE04781AB", sale = "EntersSale_10_5F69660840FE1C4711AEEE9A575B671C",
    event = "questEventName_14_5EE56CC74B5A697A833062903B51783A", onEnd = "runQuestOnEnd_17_865977E34D8EC2A2492838B4D89C5623",
    localFn = "LocalFunction_19_E42951F74D03145CE7173680C32D5F10",
}
local EVENT = "SubclassLoaded"

local function clean(s) return (tostring(s):gsub('[\\"()]', "")) end

-- answer: { text, to = line number | nil (ends the talk), event = true | nil, sale = true | nil }
-- (sale: the talk stays, hidden, and the game opens its trade window with the speaker;
-- when that closes the talk goes on at the dialogue's tradeReturnID)
local function answerText(a)
    if not a then
        return string.format('(%s="",%s=-1,%s=False,%s=False,%s="",%s=False,%s=False)', F.text, F.next, F.exits, F.sale, F.event, F.onEnd, F.localFn)
    end
    if a.sale then
        return string.format('(%s="%s",%s=-2,%s=False,%s=True,%s="",%s=False,%s=False)', F.text, clean(a[1]), F.next, F.exits, F.sale, F.event, F.onEnd, F.localFn)
    end
    return string.format('(%s="%s",%s=%d,%s=%s,%s=False,%s="%s",%s=False,%s=%s)', F.text, clean(a[1]), F.next, a.to or -1, F.exits, a.to and "False" or "True", F.sale,
        F.event, a.event and EVENT or "", F.onEnd, F.localFn, a.event and "True" or "False")
end

-- line: { say, answer, answer, ... }
local function lineText(l)
    return string.format('(%s="%s",%s=None,%s=%s,%s=%s,%s=%s,%s=%s)', F.line, clean(l[1]), F.audio, F.r[1], answerText(l[2]), F.r[2], answerText(l[3]), F.r[3], answerText(l[4]),
        F.r[4], answerText(l[5]))
end

-- The end of the bracket that opens at `from` (quotes are skipped).
local function closing(text, from)
    local depth, inQuote = 0, false
    local i, n = from, #text
    while i <= n do
        local c = text:sub(i, i)
        if inQuote then
            if c == "\\" then i = i + 1 elseif c == '"' then inQuote = false end
        elseif c == '"' then
            inQuote = true
        elseif c == "(" then
            depth = depth + 1
        elseif c == ")" then
            depth = depth - 1
            if depth == 0 then return i end
        end
        i = i + 1
    end
    return nil
end

-- A dialogue's lines with one more answer on its first line (before the last answer it
-- has, which is the goodbye) and more lines after its own. `add` is a function of the
-- number the first new line gets: returns the answer and the new lines. nil if it cannot
-- be done.
local function extended(base, add)
    local lines = Repl.splitArray(base)
    if #lines == 0 then return nil end
    local first = lines[1]
    local own, spans = {}, {}
    for i = 1, 4 do
        local a = first:find(F.r[i] .. "=(", 1, true)
        if not a then return nil end
        local open = a + #F.r[i] + 1
        local close = closing(first, open)
        if not close then return nil end
        spans[i] = { open, close }
        local block = first:sub(open, close)
        if not block:find(F.text .. '=""', 1, true) then own[#own + 1] = block end
    end
    if #own >= 4 then return nil end
    local answer, more = add(#lines)
    local blocks = {}
    for i, b in ipairs(own) do
        if i == #own then blocks[#blocks + 1] = answerText(answer) end
        blocks[#blocks + 1] = b
    end
    if #own == 0 then blocks[1] = answerText(answer) end
    for i = 4, 1, -1 do
        first = first:sub(1, spans[i][1] - 1) .. (blocks[i] or answerText(nil)) .. first:sub(spans[i][2] + 1)
    end
    lines[1] = first
    for _, l in ipairs(more or {}) do lines[#lines + 1] = lineText(l) end
    return Repl.joinArray(lines)
end

-- Olivia's part at a step: the answer on her first line and the lines it leads to
-- (n: the number of the first of them). `key` tells the versions apart.
local function oliviaPart(step, spent)
    if step == NONE and spent >= Quest.SPEND then
        return "offer", function(n)
            return { "What's with the wall outside?", to = n }, {
                { "Somebody keeps writing that about me. I paint over it and a few days later it's back.", { "Any idea who?", to = n + 1 } },
                { "No. But it's spray paint, and the gas station is the only place around here that sells cans. Amy would know who buys them.",
                    { "I'll ask her", event = true }, { "Not my problem" } },
            }
        end
    elseif step == ASK or step == BRING then
        return "ask", function(n)
            return { "About the wall", to = n }, {
                { "Ask Amy at the gas station who buys the spray cans. That's all I've got.", { "On it" } },
            }
        end
    elseif step == COVER then
        return "cover", function(n)
            return { "About the wall", to = n }, {
                { "It's still out there. I'll believe it's over when I can't read it anymore.", { "Give me a minute" } },
            }
        end
    elseif step == TELL then
        return "tell", function(n)
            return { "Your wall is clean", to = n }, {
                { "I saw. And who was it?", { "Amy", to = n + 1 } },
                { "Amy. I told her I wouldn't touch her hair again until she got clean. So that's how she took it.", { "She says she's done", to = n + 2 } },
                { "Done. Right. You know that blue in her hair? I mixed it for her back when she was my best friend. She made me swear nobody else would ever wear it. It's back on the shelves now.",
                    { "So why sell it now?", to = n + 3 } },
                { "Because she swore to me she'd stay clean. She broke hers first. It's on the shelf.", { "Sure. Thanks, Olivia.", event = true } },
            }
        end
    end
    return step == DONE and "done" or "plain", nil
end

local SEE = "Let's see it."      -- Amy, before the hand-over window (the talk is told by this line)

local function amyPart(step)
    if step == ASK then
        return function(n)
            return { "Who's been buying spray cans?", to = n }, {
                { "Why, are you a cop? I work double shifts here. I can't remember faces half asleep.", { "Maybe I can help with that", to = n + 1 } },
                { "Five grams of amphetamine. Bring me that and I'll remember. And don't you dare think about cutting it.",
                    { "Five grams. Deal", event = true }, { "Forget it" } },
            }
        end
    elseif step == BRING then
        -- (after the "let's see it" line: three lines of owning up, then what she says to the
        -- wrong thing, then what she says to the right thing cut: AFTER)
        local second = mine ~= nil and mine.k == true
        return function(n)
            return { second and "I've got your gram" or "I've got your five grams", to = n }, {
                { SEE, { "Here", sale = true }, { "Not yet" } },
                { "That's the real thing. Alright. Nobody's been buying cans. It's me.", { "You?", to = n + 2 } },
                { "Olivia said she won't touch my hair again until I get clean. So I let the whole street know what I think of her. Every time she paints over it.",
                    { "And now?", to = n + 3 } },
                { "Now I'm tired of it. I can't face her. Cover it for good, it takes a whole can. I won't write it again.", { "I'll cover it" } },
                second and { "That's not what I asked for. One gram of Colombian. No more, no less.", { "Fine" } }
                    or { "That's not what I asked for. Five grams of amphetamine. No more, no less.", { "Fine" } },
                second and { "You cut that too. We're done. Don't ever bring up that wall with me again.", { "Damn" } }
                    or { "I told you not to cut it. I can tell. Now you owe me. One gram of Colombian, pure. Cut that too and we're done.", { "Fine" } },
            }
        end
    elseif step == COVER then
        return function(n)
            return { "About that wall", to = n }, {
                { "It takes a whole can to cover it. I sell them. I'm done with it, I promise.", { "Okay" } },
            }
        end
    end
    return nil
end

-- Where the talk goes on after the hand-over, counted from the "let's see it" line.
local AFTER = { ok = 1, wrong = 4, cut = 5 }

local function setLines(actor, text)
    return Repl.importRaw(actor, "dialogueLines", text)
end

-- The dialogue actors this module listens to: address -> what to do when their event
-- comes.
local events = {}

Core.Hooks.add(DIALOGUE .. ":" .. EVENT, function(ctx)
    if not live() or next(events) == nil then return end
    local ok, address = pcall(function() return ctx:get():GetAddress() end)
    local fn = ok and events[address] or nil
    if not fn then return end
    Core.after(0.3, function()
        if not live() then return end
        local done, e = pcall(fn)
        if not done then log("Wall: %s", tostring(e)) end
    end)
end)

local function talkingNow(player)
    local ok, v = pcall(function() return player.inDialogue == true end)
    return ok and v
end

local function near(a, x, y, z, reach)
    local ok, l = pcall(function() return a:K2_GetActorLocation() end)
    return ok and l and (l.X - x) ^ 2 + (l.Y - y) ^ 2 + (l.Z - z) ^ 2 <= reach * reach
end

---------------------------------------------------------------- Olivia

local olivia = nil        -- { owner, actor, address, base, key, at }

-- Her dialogue (coop/barber.lua makes it whenever a player comes near; it is in no save).
-- What she says at a step is always made from the lines the barber gave her, never from
-- what the actor holds: that may already carry an answer of ours.
local function oliviaDialogue(player)
    local key = worldKey(player)
    local d, base = Barber.dialogue()
    if not d then
        if olivia then events[olivia.address] = nil end
        olivia = nil
        return nil
    end
    local address = d:GetAddress()
    if olivia and olivia.owner == key and olivia.address == address and olivia.base == base then return olivia end
    if olivia then events[olivia.address] = nil end
    -- (key nil: whatever she holds, her lines are written once)
    olivia = { owner = key, actor = d, address = address, base = base, key = nil }
    return olivia
end

local GREETING = { '"Never mind the wall outside. What are we doing today?"', '"Thanks again. What are we doing today?"' }

local function tendOlivia(player)
    local o = oliviaDialogue(player)
    if not o or talkingNow(player) then return end
    local key, add = oliviaPart(mine.s, mine.spent)
    if o.key == key then return end
    local text = o.base
    if add then text = extended(o.base, add) end
    if text and key == "done" then
        local a, b = text:find(GREETING[1], 1, true)
        if a then text = text:sub(1, a - 1) .. GREETING[2] .. text:sub(b + 1) end
    end
    if not text or not setLines(o.actor, text) then
        log("Wall: Olivia's lines for '%s' could not be set", key)
        o.key = key
        return
    end
    o.key = key
    events[o.address] = function()
        if not mine then return end
        if mine.s == NONE and mine.spent >= Quest.SPEND then
            advance(ASK)
        elseif mine.s == TELL then
            advance(DONE)
        end
    end
end

---------------------------------------------------------------- what is paid at Olivia's

-- The hair screen changes what the player has when PAY is pressed: what changed is what
-- was paid for.
-- (The hair screen adds up what it took: Look.barberPaid. Shaving the head and going back
-- to one's own hair cost nothing and count for nothing.)
local paidSeen = nil

local function tendSpending()
    local total = tonumber(Look.barberPaid) or 0
    if not paidSeen then
        paidSeen = total
        return
    end
    local paid = total - paidSeen
    paidSeen = total
    if paid > 0 and mine and mine.s == NONE then
        mine.spent = mine.spent + paid
        store()
        log("Wall: %d paid at Olivia's so far", mine.spent)
    end
end

---------------------------------------------------------------- the colour

-- Olivia's list of colours has Blue only for a player who is done. (The list is
-- coop/look.lua's own table; a player who already wears the colour keeps it.)
local blueEntry, blueIndex = nil, nil

local function tendColour(unlocked)
    local list = Look.HAIR_COLOURS
    if type(list) ~= "table" then return end
    local at = nil
    for i, c in ipairs(list) do if c.id == Quest.BLUE then at = i end end
    if at and not unlocked then
        blueEntry, blueIndex = list[at], at
        table.remove(list, at)
    elseif not at and unlocked and blueEntry then
        table.insert(list, math.min(blueIndex or (#list + 1), #list + 1), blueEntry)
    end
end

---------------------------------------------------------------- Amy

local amy = nil           -- { owner, npc, original, root, rootStep, seeLine, handFailed }

local function findAmy(player)
    local key = worldKey(player)
    if amy and amy.owner == key and Core.alive(amy.npc) then return amy end
    amy = nil
    local npc = nil
    for _, a in ipairs(Core.actors(AMY_CLASS) or {}) do
        if Core.alive(a) then npc = a break end
    end
    if not npc then return nil end
    amy = { owner = key, npc = npc }
    pcall(function()
        local l = npc:K2_GetActorLocation()
        amyAt = { x = l.X, y = l.Y, z = l.Z }
    end)
    return amy
end

local function same(a, b)
    local ok, v = pcall(function() return a:GetAddress() == b:GetAddress() end)
    return ok and v
end

-- A dialogue actor of ours beside Amy (never saved).
local function spawnDialogue(player, like)
    local class = StaticFindObject(DIALOGUE)
    if not valid(class) then return nil end
    local l = like:K2_GetActorLocation()
    local d = player:GetWorld():SpawnActor(class, { X = l.X, Y = l.Y, Z = l.Z }, { Pitch = 0, Yaw = 0, Roll = 0 })
    if not valid(d) then return nil end
    pcall(function() if valid(d.RamaSave) then d.RamaSave:K2_DestroyComponent(d) end end)
    -- (how one of ours is told from the game's: this name is otherwise unused in a
    -- dialogue that does not take its lines from the game's table)
    pcall(function() d.DialogueID = FName(OURS) end)
    return d
end

-- (any dialogue the mod made counts: the scratch tickets' cashing talk, coop/lotto.lua, is
-- given to Amy as well and must never be taken for her own)
local function isOurs(d)
    local ok, v = pcall(function() return d.DialogueID:ToString():sub(1, 6) == "DDSMP-" end)
    return ok and v
end

-- Amy's own dialogue: what she has unless it is one of ours, else the game's dialogue
-- that names her as its speaker.
local function herOwn(a)
    if Core.alive(a.original) then return a.original end
    a.original = nil
    local cur = nil
    pcall(function() cur = a.npc.curDialogue end)
    if valid(cur) and not isOurs(cur) then
        a.original = cur
        return cur
    end
    for _, d in ipairs(Core.actors(DIALOGUE) or {}) do
        local ok, hers = pcall(function() return Core.alive(d) and not isOurs(d) and valid(d.talkerRef) and same(d.talkerRef, a.npc) end)
        if ok and hers then
            a.original = d
            return d
        end
    end
    return nil
end

local function putBack(a)
    if not a then return end
    pcall(function()
        local cur = a.npc.curDialogue
        if valid(cur) and not isOurs(cur) then return end
        local own = herOwn(a)
        if own then a.npc.curDialogue = own end
    end)
end

local function dropAmy()
    local a = amy
    if not a then return end
    if not World.gone and Core.alive(a.npc) then
        putBack(a)
        pcall(function()
            if Core.alive(a.root) then
                events[a.root:GetAddress()] = nil
                a.root:K2_DestroyActor()
            end
        end)
    end
    a.root, a.rootStep, a.seeLine, a.extraLine = nil, nil, nil, nil
end

-- How much of a thing is the drug `drug`: `name` the item, `mix` what it is made of (as text).
local K_CONTENTS, K_PROPS = "MixContents_4_087C32B1445FBB5223EDA2A1A88D5B16", "MixProportions_7_B6CEC0E14F7E77A2F3CFCEB78B49F4C0"

local function shareOf(name, mix, drug)
    drug = drug or Quest.DRUG
    local m = tostring(mix or "")
    local contents, props = m:match(K_CONTENTS .. "=(%b())"), m:match(K_PROPS .. "=(%b())")
    if contents and props then
        local c, p = Repl.splitArray(contents), Repl.splitArray(props)
        if #c > 0 then
            local share = 0
            for k, what in ipairs(c) do
                if (what:gsub('"', "")) == drug then share = share + (tonumber(p[k]) or 0) end
            end
            return share
        end
    end
    return name == drug and 1 or 0
end

-- The amphetamine in the player's pockets: rows of { guid, units, grams (of one unit),
-- share (of amphetamine in it) }. (For test scripts.)
local function pockets(player, drug)
    local names = { "InventoryComponent.ItemNames", "InventoryComponent.ItemQuantities", "InventoryComponent.ItemCurAmount", "InventoryComponent.ItemMixProportions",
        "InventoryComponent.ItemLocalGuids" }
    local v = Repl.export(player, names)
    local item, units, grams = Repl.splitArray(v[names[1]] or "()"), Repl.splitArray(v[names[2]] or "()"), Repl.splitArray(v[names[3]] or "()")
    local mix, guids = Repl.splitArray(v[names[4]] or "()"), Repl.splitArray(v[names[5]] or "()")
    local rows = {}
    for i, n in ipairs(item) do
        local share = shareOf((n:gsub('"', "")), mix[i], drug)
        local g = tostring(guids[i] or "")
        local a, b, c, d = g:match("A=(%-?%d+),B=(%-?%d+),C=(%-?%d+),D=(%-?%d+)")
        if share > 0 and a then
            rows[#rows + 1] = { guid = { A = tonumber(a), B = tonumber(b), C = tonumber(c), D = tonumber(d) }, units = math.floor(tonumber(units[i]) or 0),
                grams = math.max(1, math.floor(tonumber(grams[i]) or 1)), share = share }
        end
    end
    return rows
end
Quest.pockets = pockets

---------------------------------------------------------------- the hand-over
--
-- The five grams change hands in the game's own window for a sale: "Here" in the talk
-- opens the game's trade window with Amy (the talk stays, hidden), and since Amy keeps a
-- shop the game lays that window out for buying. It is laid out anew for a sale to a
-- client: what she wants on the right (the game's own list), the player's things to drag
-- there, ACCEPT, CLEAR, CANCEL.
--
-- What ACCEPT does is the game's shop branch (Amy is a shopkeeper again by then): nothing
-- was bought, so nothing is paid and nothing counted, the window closes and the talk comes
-- back. None of what the game does for a real sale happens (no money, no order closed,
-- no client's records touched, nothing for the territory). What lay in the window is then
-- still in the window's list, and this module settles it:
--     exactly five grams, clean enough   she keeps it and owns up
--     exactly five grams, cut too far    she keeps it and says so
--     anything else                      back into the pockets
-- CANCEL is the game's own: everything back, and the talk is where it was.
local hand = nil          -- while the window is open: { npc, screen, root, line, back, was }

local function saying(player)
    local ok, t = pcall(function() return player.dialogueWidget.txtDialLine:GetText():ToString() end)
    return ok and t or ""
end

-- What lies in the window: grams in all, grams of the drug asked for in that, whether
-- something that holds none of it is among it, and the number of stacks.
local TRADED = { "tradedItemIDs", "tradedItemsAmounts", "tradedItemQuantities", "TradedItemsMixProportions" }

local function offered(screen, drug)
    -- (reading from an object the engine has let go of takes the game down)
    if not valid(screen) or not valid(screen.tradeItemList) then return 0, 0, false, 0 end
    local v = Repl.export(screen.tradeItemList, TRADED)
    local ids, grams, units = Repl.splitArray(v[TRADED[1]] or "()"), Repl.splitArray(v[TRADED[2]] or "()"), Repl.splitArray(v[TRADED[3]] or "()")
    local mix = Repl.splitArray(v[TRADED[4]] or "()")
    local total, amph, other = 0, 0, false
    for i, id in ipairs(ids) do
        local g = (tonumber(grams[i]) or 0) * (tonumber(units[i]) or 0)
        local share = shareOf((id:gsub('"', "")), mix[i], drug)
        if share <= 0 then other = true end
        total, amph = total + g, amph + g * share
    end
    return total, amph, other, #ids
end

local function judge(total, amph, other, d)
    d = d or demand()
    if other or total ~= d.grams then return "wrong" end
    return amph / total >= d.purity - 0.0001 and "ok" or "cut"
end

local function wantsHandover(player, a)
    return player.isTrading == true and same(player.curSeller, a.npc) and saying(player) == SEE
end

local DEMAND = { "drugsDemandedID", "drugsDemandedQuantity", "drugsExpectedPrices" }

local function openHandover(player, a)
    if hand or a.handFailed then return end
    local screen = player.InventoryWidget
    local npc = a.npc
    if not valid(screen) or not Core.alive(a.root) or not a.seeLine then return end
    local was = Repl.export(npc, DEMAND)
    local d = demand()
    Repl.import(npc, { drugsDemandedID = '("' .. d.drug .. '")', drugsDemandedQuantity = "(" .. d.grams .. ")", drugsExpectedPrices = "(0.000000)" })
    -- (the window is laid out for a sale when its other side keeps no shop: for the
    -- moment of laying it out, Amy does not)
    local ok, e = pcall(function()
        npc.shopOwner = false
        local done = pcall(function() screen:prepareInventoryMode(player.curContainer, npc, player) end)
        if not done then screen:prepareInventoryMode(nil, npc, player) end
    end)
    pcall(function() npc.shopOwner = true end)
    if not ok then
        log("Wall: the hand-over window could not be laid out: %s", tostring(e))
        a.handFailed = true
        pcall(Repl.import, npc, was)
        return
    end
    local back = 0
    pcall(function() back = a.root.tradeReturnID end)
    hand = { npc = npc, screen = screen, root = a.root, line = a.seeLine, back = back, was = was, demand = d }
    -- whichever way the window closes, the talk is back at "let's see it" first
    pcall(function() a.root.tradeReturnID = a.seeLine end)
    log("Wall: the hand-over window is open")
end

-- The window has closed. Returns what became of it: "ok", "cut", "wrong", or nil when
-- nothing lay in it (cancelled, or accepted empty).
local function settle(h)
    local total, amph, other, stacks = offered(h.screen, h.demand.drug)
    if stacks == 0 then return nil end
    local v = judge(total, amph, other, h.demand)
    if v == "wrong" then
        h.screen:clearTradeItems()                  -- (the game's own: everything back into the pockets)
    else
        local list = h.screen.tradeItemList
        list:ClearTradedItems()
        list:renderTradeItems()
        log("Wall: Amy took %d g, %.0f%% of it %s", total, 100 * amph / math.max(1, total), h.demand.second and "cocaine" or "amphetamine")
    end
    return v
end

local goalDue = false     -- the banner of the next goal is owed (shown once the talk is over)
local failDue = false     -- ... or the one that says it is over

local function closeHandover(player)
    local h = hand
    hand = nil
    if not h then return end
    local ok, v = pcall(settle, h)
    if not ok then
        log("Wall: the hand-over could not be settled: %s", tostring(v))
        v = nil
        pcall(function() h.screen:clearTradeItems() end)
    end
    pcall(function()
        if v and Core.alive(h.root) and player then
            h.root.tradeReturnID = h.line + AFTER[v]
            player.dialogueWidget:returnFromTrade()
        end
    end)
    pcall(function() if Core.alive(h.root) then h.root.tradeReturnID = h.back end end)
    pcall(function() if Core.alive(h.npc) then Repl.import(h.npc, h.was) end end)
    log("Wall: the hand-over window is closed (%s)", tostring(v or "nothing handed over"))
    if not mine or mine.s ~= BRING then return end
    if v == "ok" then
        advance(COVER, true)
        goalDue = true
    elseif v == "cut" and h.demand.second then
        -- the second bag was cut as well: that was the last chance
        advance(FAILED, true)
        failDue = true
    elseif v == "cut" then
        -- she kept the five grams and wants a gram of cocaine now
        mine.k = true
        store()
        refreshTaskList()
        goalDue = true
        log("Wall: the five grams were cut: Amy wants a gram of cocaine instead")
    end
end

-- (the game opens its trade window from the talk: ours is told by the line the talk is at)
Core.Hooks.add(PLAYER .. ":openTrade", function()
    if not live() or hand or not mine or mine.s ~= BRING then return end
    local player, a = World.player(), amy
    if not player or not a or not Core.alive(a.npc) then return end
    local ok, ours = pcall(wantsHandover, player, a)
    if ok and ours then
        local done, e = pcall(openHandover, player, a)
        if not done then log("Wall: %s", tostring(e)) end
    end
end)

Core.onTick(function()
    if not live() or not mine then return end
    local h = hand
    if not h then
        -- (should the hook not be in place yet, the window is caught here a frame later)
        local a = amy
        if mine.s ~= BRING or not a or not a.seeLine or a.handFailed then return end
        local player = World.player()
        if not player then return end
        local ok, ours = pcall(wantsHandover, player, a)
        if ok and ours then pcall(openHandover, player, a) end
        return
    end
    local player = World.player()
    local open = false
    pcall(function() open = player ~= nil and player.isTrading == true and valid(h.screen) end)
    if not open then
        closeHandover(player)
        return
    end
    -- (the game takes ACCEPT away from a shop's window while nothing is being bought)
    pcall(function() h.screen.btnAcceptTrade:SetIsEnabled(true) end)
end)

local function amyEvent()
    if mine and mine.s == ASK then advance(BRING) end
end

local function tendAmy(player)
    if goalDue and not talkingNow(player) then
        goalDue = false
        if goalText() then banner(goalText(), 0) end
    end
    if failDue and not talkingNow(player) then
        failDue = false
        banner("Amy wants nothing more to do with it", 2)
    end
    local a = findAmy(player)
    if not a then return end
    -- (Amy keeps a shop, whatever a hand-over that went wrong may have left)
    if not hand then pcall(function() if a.npc.shopOwner ~= true then a.npc.shopOwner = true end end) end
    local add = amyPart(mine.s)
    local close = false
    pcall(function()
        local l, p = a.npc:K2_GetActorLocation(), player:K2_GetActorLocation()
        close = (l.X - p.X) ^ 2 + (l.Y - p.Y) ^ 2 < AMY_RANGE * AMY_RANGE
    end)
    if not add or not close then
        if a.root then
            if talkingNow(player) then return end
            dropAmy()
        end
        return
    end
    if talkingNow(player) then return end
    local cur = nil
    pcall(function() cur = a.npc.curDialogue end)
    if not herOwn(a) then return end
    if not Core.alive(a.root) then
        a.root, a.rootStep = spawnDialogue(player, a.original), nil
        if not a.root then return end
        events[a.root:GetAddress()] = amyEvent
    end
    -- A player with a winning scratch ticket cashes it at Amy's (coop/lotto.lua): while the
    -- talk on her is the quest's, that answer goes into it too.
    local extra = nil
    pcall(function()
        local Lotto = package.loaded["coop.lotto"]
        extra = Lotto and Lotto.cashAnswer and Lotto.cashAnswer(player) or nil
    end)
    -- (her lines at the step "bring" differ with what she wants)
    local face = mine.s * 2 + (mine.k and 1 or 0) + (extra and 100 or 0)
    if a.rootStep ~= face then
        local base = Repl.export(a.original, { "dialogueLines" }).dialogueLines
        local text = type(base) == "string" and extended(base, add) or nil
        local extraLine = nil
        if text and extra then
            local both = extended(text, extra)
            if both then
                extraLine, text = #Repl.splitArray(text), both
            else
                log("Wall: no room in Amy's talk for the ticket answer")
            end
        end
        a.extraLine = nil
        if not text or not setLines(a.root, text) then
            log("Wall: Amy's lines could not be set")
            dropAmy()
            return
        end
        pcall(function()
            a.root.firstDialougueID, a.root.startDialogueID, a.root.tradeReturnID = a.original.firstDialougueID, a.original.startDialogueID, a.original.tradeReturnID
            a.root.talkerRef = a.npc
        end)
        a.rootStep = face
        a.extraLine = extraLine
        -- (the number of the "let's see it" line: the first one after her own)
        a.seeLine, a.handFailed = mine.s == BRING and #Repl.splitArray(base) or nil, nil
    end
    if not valid(cur) or not same(cur, a.root) then
        pcall(function() a.npc.curDialogue = a.root end)
    end
end

---------------------------------------------------------------- the wall

-- The line of text is painted over in three parts. Each part is one spray from a can: a
-- full can for the whole line (a can is three sprays; the game takes them, it is the
-- game's own spraying). Which parts are done is kept with the step (mine.c): the paint
-- is there for good, for this player, wherever they are. The player's tags on it
-- (mine.t) last as long as a wall marking of the game lasts, then they are gone.
local wall = nil          -- { owner, writing, paint = { [part] = actor }, tags = { actor, ... } }

local PARTS = 3
-- (part 1 is the left one as the player sees it from the alley: there +x is on the right)
local function partX(i) return TEXT.x + (i - 2) * (TEXT.w / PARTS) end
local function partDone(i) return mine ~= nil and (mine.s >= TELL or (mine.c & (1 << (i - 1))) ~= 0) end

local function findWriting(player)
    local key = worldKey(player)
    if wall and wall.owner == key then return wall end
    wall = { owner = key, paint = {}, tags = {} }
    local stains = 0
    for _, a in ipairs(Core.actors("/Script/Engine.DecalActor") or {}) do
        local ok, name = pcall(function() return a.Decal:GetDecalMaterial():GetFullName() end)
        if ok and name:find(WRITING, 1, true) and near(a, WALL.x, WALL.y, WALL.z, 200) then
            wall.writing = a
        elseif ok and name:find(STAINS, 1, true) and near(a, WALL.x, WALL.y, WALL.z, 700) then
            -- The wall's leak stains reach up over the writing, and the game gives them, the
            -- writing and the tag below it the same place in the order decals are drawn in:
            -- which of them ends up in front is then left to chance, anew in every session,
            -- and in some the stains wash the writing out. They go behind (in this game only;
            -- nothing of it is saved).
            pcall(function()
                a.Decal:SetSortOrder(-1)
                stains = stains + 1
            end)
        end
    end
    if not wall.writing then log("Wall: the writing was not found") end
    if stains > 0 then log("Wall: the wall's leak stains are drawn behind the writing") end
    return wall
end

-- Fresh paint over a part of the line: broad strokes one above the other, their ends and
-- the patch's upper and lower edge uneven, every part a little different. (Points in the
-- drawing's 512 x 512.)
local ENDS = {
    { { 44, 470 }, { 14, 500 }, { 30, 486 }, { 8, 478 }, { 22, 506 }, { 50, 462 } },
    { { 10, 498 }, { 36, 474 }, { 6, 504 }, { 28, 490 }, { 12, 468 }, { 40, 500 } },
    { { 30, 480 }, { 8, 506 }, { 46, 472 }, { 16, 498 }, { 34, 464 }, { 6, 492 } },
}
local WAVE = { 0, 9, -6, 12, 3, -10, 6, -3, 10 }
local function paintStrokes(part)
    local out = {}
    for i = 1, 6 do
        local y = 62 + (i - 1) * 77.5
        local x0, x1 = ENDS[part][i][1], ENDS[part][i][2]
        local p = {}
        for k = 0, 8 do
            p[#p + 1] = x0 + (x1 - x0) * k / 8
            -- the outer rows wander most: they are the patch's edges
            p[#p + 1] = y + WAVE[(k + i * 2 + part * 3) % #WAVE + 1] * ((i == 1 or i == 6) and 1.5 or 0.6)
        end
        out[i] = { w = 112, c = PAINT, p = p }
    end
    return out
end

-- A decal on the wall, turned as the writing is (a decal looks along its X; its Y is up
-- the wall here and its Z along it).
local function decal(player, w, material, x, z, width, height, order)
    local class = StaticFindObject("/Script/Engine.DecalActor")
    -- (made upright and turned afterwards: a rotation given to SpawnActor goes to the wrong axes)
    local a = player:GetWorld():SpawnActor(class, { X = x, Y = WALL.y, Z = z }, { Pitch = 0, Yaw = 0, Roll = 0 })
    if not valid(a) then return nil end
    pcall(function()
        local turn = { Pitch = 0, Yaw = -90, Roll = 90 }
        pcall(function()
            local r = w.writing:K2_GetActorRotation()
            turn = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }
        end)
        a:K2_SetActorRotation(turn, false)
        a.Decal.DecalSize = { X = 128, Y = 256, Z = 256 }
        a:SetActorScale3D({ X = 0.03, Y = height / 512, Z = width / 512 })
        a.Decal:SetSortOrder(order)
        a.Decal:SetDecalMaterial(material)
    end)
    return a
end

local function showPart(player, w, part)
    if Core.alive(w.paint[part]) then return true end
    local Tags = package.loaded["coop.tags"]
    if type(Tags) ~= "table" or not Tags.paintOf then return false end
    local m = Tags.paintOf("wallquest-" .. part, paintStrokes(part))
    if not m then return false end      -- (a copy that cannot draw)
    -- (a little wider than a third: the parts run into each other)
    w.paint[part] = decal(player, w, m, partX(part), TEXT.z, TEXT.w / PARTS + 34, TEXT.h, 1)
    return w.paint[part] ~= nil
end

local function hidePart(w, part)
    local a = w.paint[part]
    if not a then return end
    w.paint[part] = nil
    pcall(function() if Core.alive(a) then a:K2_DestroyActor() end end)
end

-- The player's tag where they sprayed it, on the paint.
local function showTags(player, w)
    local Tags = package.loaded["coop.tags"]
    for i, t in ipairs(mine.t) do
        if not Core.alive(w.tags[i]) then
            local m = type(Tags) == "table" and Tags.materialOf and Tags.materialOf() or nil
            if not m then return end
            w.tags[i] = decal(player, w, m, t.x, t.z, t.w, t.w, 2)
        end
    end
end

local function hideTags(w, from)
    for i = #w.tags, from or 1, -1 do
        local a = w.tags[i]
        w.tags[i] = nil
        pcall(function() if Core.alive(a) then a:K2_DestroyActor() end end)
    end
end

local function uncover(w)
    for part = 1, PARTS do hidePart(w, part) end
    hideTags(w)
end

-- True for a place on the wall that is on or about the writing.
local function onWriting(l)
    return math.abs(l.X - TEXT.x) <= TEXT.w / 2 + 50 and math.abs(l.Z - TEXT.z) <= TEXT.h / 2 + 70 and math.abs(l.Y - WALL.y) < 40
end

local function inAlley(player)
    local ok, l = pcall(function() return player:K2_GetActorLocation() end)
    return ok and math.abs(l.X - WALL.x) < 320 and l.Y > WALL.y and l.Y < WALL.y + 330 and l.Z < 420
end

-- A spray of the game's own (hold F) has landed on the writing. The game has taken the
-- spray out of the can and made a wall marking there; a marking counts for the territory a
-- second after it appears, and keeps the wall from being marked again. This one is taken
-- away before that: what stays is our paint over the nearest part still to do, and the
-- player's tag on it where they sprayed.
local function sprayed(at)
    local player = World.player()
    if not player or not mine or mine.s ~= COVER then return end
    local w = findWriting(player)
    local size, life = TAG_SIZE, TAG_LIFE
    for _, m in ipairs(Core.actors(MARKING) or {}) do
        -- (the marking of this spray: one that has not counted yet. A marking that was
        -- there before, even at the very same place, has, and stays.)
        local fresh = false
        pcall(function() fresh = Core.alive(m) and m.spawned ~= true and near(m, at.X, at.Y, at.Z, 15) end)
        if fresh then
            pcall(function()
                local scale, box = m:GetActorScale3D(), m.Decal.DecalSize
                local seen = 2 * math.max(box.Y * scale.Y, box.Z * scale.Z)
                if seen > 20 and seen < 400 then size = seen end
            end)
            pcall(function()
                local v = m.Lifetime
                if type(v) == "number" and v > 1 then life = v end
            end)
            pcall(function() m:K2_DestroyActor() end)
        end
    end
    local part, bestD = nil, math.huge
    for i = 1, PARTS do
        if not partDone(i) then
            local d = math.abs(partX(i) - at.X)
            if d < bestD then part, bestD = i, d end
        end
    end
    if not part then return end
    pcall(showPart, player, w, part)
    mine.c = mine.c | (1 << (part - 1))
    -- (no tag on the paint: a spray here only covers. A tag drawn over the fresh paint
    -- showed a moment before the paint did, and with a filled background hid it.)
    log("Wall: part %d of the writing is painted over", part)
    if mine.c == (1 << PARTS) - 1 then advance(TELL) else store() end
end

local hideUntil, hideAt = 0, nil

local function hideFresh(at)
    for _, m in ipairs(Core.actors(MARKING) or {}) do
        pcall(function()
            if Core.alive(m) and m.spawned ~= true and near(m, at.X, at.Y, at.Z, 15) then m:SetActorHiddenInGame(true) end
        end)
    end
end

Core.onTick(function()
    if not live() or not hideAt then return end
    if os.clock() > hideUntil or not mine or mine.s < COVER then
        hideAt = nil
        return
    end
    hideFresh(hideAt)
end)

Core.Hooks.add(GIZMO .. ":PutSpraySymbol", function(ctx)
    if not live() or not mine or mine.s ~= COVER then return end
    local at = nil
    pcall(function()
        local g = ctx:get()
        if not valid(g) then return end
        local l = g:K2_GetActorLocation()
        at = { X = l.X, Y = l.Y, Z = l.Z }
    end)
    if not at or not onWriting(at) then return end
    -- The game's marking of this spray must never be seen (it would show the tag for a
    -- moment before the paint): out of sight now, and on the next ticks should it only
    -- appear then; it is taken away below.
    hideFresh(at)
    hideUntil, hideAt = os.clock() + 0.4, at
    Core.after(0.1, function()
        if not live() then return end
        local ok, e = pcall(sprayed, at)
        if not ok then log("Wall: %s", tostring(e)) end
    end)
end)

-- coop/tags.lua leaves such a spray alone (no tag of its own, nothing sent to other games).
do
    local Tags = package.loaded["coop.tags"]
    if type(Tags) == "table" then
        Tags.claim = function(l)
            return live() and mine ~= nil and mine.s == COVER and onWriting(l)
        end
    end
end

-- A wall that carries a marking cannot be sprayed again: the game looks for markings that
-- touch the place. While the writing is to be painted over and the player stands at it,
-- the markings around it do not count for that (their collision is off; they stay what
-- they are otherwise).
local quiet = {}          -- address -> marking whose collision is off

local function tendMarkings(player)
    local on = mine.s == COVER and inAlley(player)
    if on then
        for _, m in ipairs(Core.actors(MARKING) or {}) do
            pcall(function()
                local address = m:GetAddress()
                if not quiet[address] and Core.alive(m) and near(m, WALL.x, WALL.y, WALL.z, 1200) then
                    m:SetActorEnableCollision(false)
                    quiet[address] = m
                end
            end)
        end
    elseif next(quiet) ~= nil then
        for _, m in pairs(quiet) do
            pcall(function() if Core.alive(m) then m:SetActorEnableCollision(true) end end)
        end
        quiet = {}
    end
end

-- The tags grow older while the game runs (as its wall markings do) and go when their
-- time is up. What is left of their time is kept with the step, once a minute.
local agedAt, keptAt = nil, 0

local function ageTags(player, w)
    local now = os.clock()
    local dt = math.min(1, now - (agedAt or now))
    agedAt = now
    if #mine.t == 0 or dt <= 0 then return end
    local paused = false
    pcall(function() paused = Core.statics():IsGamePaused(player) == true end)
    if paused then return end
    local gone = false
    for i = #mine.t, 1, -1 do
        local t = mine.t[i]
        t.l = (tonumber(t.l) or TAG_LIFE) - dt
        if t.l <= 0 then
            table.remove(mine.t, i)
            gone = true
        end
    end
    if gone then
        hideTags(w)         -- (those that are left are drawn again)
        keptAt = now
        store()
        log("Wall: a tag on the paint has had its time (%d left)", #mine.t)
    elseif now - keptAt > 60 then
        keptAt = now
        store()
    end
end

local function tendWall(player)
    local w = findWriting(player)
    if mine.s == COVER and mine.c == (1 << PARTS) - 1 then advance(TELL) end
    tendMarkings(player)
    -- the paint: on every part that is done, for good, wherever the player is
    for part = 1, PARTS do
        if partDone(part) then
            pcall(showPart, player, w, part)
        else
            hidePart(w, part)
        end
    end
    -- (tags on the paint are no longer made; those an older version kept are dropped)
    hideTags(w)
    if #mine.t > 0 then
        mine.t = {}
        store()
    end
end

---------------------------------------------------------------- the round

Core.every(1, function()
    if not live() then return end
    local player = World.player()
    if not player or World.joining or World.gone or not World.extras() then
        if not player or World.gone then amy, olivia, wall, marker, events, quiet, hand = nil, nil, nil, nil, {}, {}, nil end
        return
    end
    if not learn(player) then
        pcall(tendColour, false)
        return
    end
    local ok, e = pcall(function()
        tendColour(mine.s >= DONE)
        tendOlivia(player)
        tendAmy(player)
        tendMarker(player)
    end)
    if not ok then log("Wall: %s", tostring(e)) end
end)

Core.every(0.25, function()
    if not live() or not mine then return end
    local player = World.player()
    if not player or World.joining or World.gone or not World.extras() then return end
    local ok, e = pcall(function()
        tendSpending()
        tendWall(player)
    end)
    if not ok then log("Wall: %s", tostring(e)) end
end)

function Quest.shutdown()
    if hand and not World.gone then pcall(closeHandover, World.player()) end
    hand = nil
    tendColour(true)
    dropMarker()
    dropAmy()
    if wall and not World.gone then pcall(uncover, wall) end
    if not World.gone then
        for _, m in pairs(quiet) do pcall(function() if Core.alive(m) then m:SetActorEnableCollision(true) end end) end
    end
    quiet = {}
    pcall(function() package.loaded["coop.tags"].claim = nil end)
    Guests.setSelf = setSelf
end

-- RELOAD (coop/options.lua): Amy's talk and the step's marker are made anew on the next
-- look, the organizer and the HUD are drawn again.
function Quest.reload()
    if not mine then return false end
    if hand and not World.gone then pcall(closeHandover, World.player()) end
    hand = nil
    pcall(dropMarker)
    pcall(dropAmy)
    pcall(refreshTaskList)
    log("Wall: step %d reloaded", mine.s)
    return true
end

-- (for test scripts)
function Quest.set(step, spent, parts, second)
    if not mine then return false end
    mine.s, mine.spent, mine.c, mine.t = step, spent or mine.spent, parts or 0, {}
    mine.k = (second == true and step == BRING) or nil
    store()
    return true
end
function Quest.amy() return amy end
function Quest.hand() return hand end
Quest.offered, Quest.judge, Quest.SEE, Quest.demand, Quest.goal = offered, judge, SEE, demand, goalText
function Quest.olivia() return olivia end
function Quest.wall() return wall end
Quest.extended, Quest.lineText = extended, lineText

return Quest
