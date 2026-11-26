-- Shared XP: every XP gain goes through statisticsManager_C:addExp(expAmount). Gains from
-- sales, dead drops, regular tasks and the psychedelic gang's tasks are sent to the other
-- players; storyline task XP (recognised through questManager_C:markTaskStatus) stays with
-- the player who earned it.

local Core = require("core")
local Net = require("net")

local config, log, vlog, valid = Core.config, Core.log, Core.vlog, Core.valid

local XP = {}

local S = {
    session = tostring(os.time()),
    seq = 0,
    lastSeq = {},
    pendingXp = {},      -- received XP waiting for a game world
    applyingRemote = false,
    pendingLocal = {},   -- local XP gains waiting to be classified on the next tick
    expected = {},       -- task/quest rewards seen recently, used to classify them
    resolveQueued = false,
    storyNames = nil,
    regularNames = nil,
    stats = { sent = 0, received = 0, story = 0 },
}
XP.S = S

local function findStats()
    return Core.find("statisticsManager_C")
end

---------------------------------------------------------------- task classification data

local QUEST_TABLE = "/Game/StringTables/strTable_questTasks.strTable_questTasks"

-- Tasks that belong to the storyline (Eddie's calls, tutorials, long-term goals,
-- gang story, endgame). Their XP is never shared.
local STORY_KEYS = {
    "TASK-MERCHANDISE-NAM", "TASK-GAS-STATION-NAM", "TASK-CARTEL-REFUND-NAM", "TASK-BANK-NAM",
    "TASK-GROWING-BUSINESS-NAM", "TASK-GOINGBIG-NAM", "TASK-READ-LAUNDER-NAM", "TASK-THEWALL-NAM",
    "TASK-JAY-NAM", "TASK-FURNITURE-MODE-NAM", "TASK-KEYS-NAM", "TASK-CHEMIST-NAM",
    "TASK-DOMINATION-NAM", "TASK-FURTHER-NORTH-NAM", "TASK-DRUGSTORE-NAM", "TASK-FIRST-DAY-NAM",
    "TASK-FIRST-PACK-NAM", "TASK-FIRST-CLIENTS-NAM", "TASK-SECTORC-UNLOCK-NAME",
    "TASK-ENDGAME-SEARCH-SECT-NAM", "TASK-WORK-STATION-NAM", "TASK-HIDEOUTS-NAM", "TASK-RENT-NAM",
    "TASK-FURNITURE-NAM", "TASK-FIRST-DEALER-NAM", "TASK-SECTOR-HIDEOUT-NAM",
    "TASK-SECTOR-FACTORY-NAM", "TASK-SECTOR-LAUNDRY-NAM", "TASK-ENDGAME-GREENE1-NAM",
    "TASK-ENDGAME-VILLA1-NAM", "TASK-ENDGAME-VILLA2-NAM", "TASK-ENDGAME-VILLA3-NAM",
    "TASK-ENDGAME-SITES-DESC", "TASK-ENDGAME-SITES-NAM", "TASK-ENDGAME-CONCRETE-NAM",
    "TASK-ENDGAME-CALLPOLICE-NAM", "TASK-ENDGAME-GSM1-NAM", "TASK-ENDGAME-STASHES-NAM",
    "TASK-ENDGAME-BOMBS-NAM", "TASK-ENDGAME-FUNERAL-NAM", "TASK-ENDGAME-GOODS-NAM",
    "TASK-ENDGAME-BASS-NAM", "TASK-ENDGAME-GREENE2-NAM", "TASK-ENDGAME-LAB-NAM",
    "TASK-ENDGAME-SICARIO1-NAM", "TASK-ENDGAME-TAPGSM", "TASK-PSYCHEDELIC-ENDGAME-NAME",
    "TASK-GANG-FINALISE-NAME",
}

-- Tasks whose XP is shared: repeatable everyday tasks, and the psychedelic gang's tasks
-- (the gang is one for the whole world, and any player may do its steps).
local REGULAR_KEYS = {
    "TASK-PSYCH-RAT-TITLE",      -- envelopes, the minion's details
    "TASK-PSYCH-EVIDENCE-TITLE", -- the police archive: virus, documents
    "TASK-CLIENT-NAM",      -- client order (sale / dead drop delivery)
    "TASK-DEALER-CASH-NAM", -- collect cash from a dealer
    "TASK-CASH-EDDIE-NAM",  -- pay Eddie
    "TASK-LAUNDERING-NAM",  -- money laundering
    "TASK-GET-SEEDS-TITLE", -- pick up seeds
    "TASK-PACKAGE-NAM",     -- pick up a package from a dead drop
    "TASK-PAYDAY-NAM",      -- gang payday
}

---------------------------------------------------------------- classification

local function buildTaskNameSets()
    local story, regular = {}, {}
    local lib = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    local srcLib = StaticFindObject("/Script/Engine.Default__KismetStringTableLibrary")
    local tableId = FName(QUEST_TABLE)
    local resolved = 0
    local function resolve(key)
        local name
        if valid(lib) then
            pcall(function() name = lib:TextFromStringTable(tableId, key):ToString() end)
        end
        if (not name or name == "") and valid(srcLib) then
            pcall(function() name = srcLib:GetTableEntrySourceString(tableId, key):ToString() end)
        end
        if name and name ~= "" and not name:find("<MISSING", 1, true) then
            resolved = resolved + 1
            return name
        end
        return nil
    end
    for _, key in ipairs(STORY_KEYS) do
        local name = resolve(key)
        if name then story[name] = key end
    end
    for _, key in ipairs(REGULAR_KEYS) do
        local name = resolve(key)
        if name then regular[name] = key; story[name] = nil end
    end
    -- Endgame antenna quests carry their own task title on the placed actor.
    pcall(function()
        local antennas = FindAllOf("GSMAntenna_QuestActivator_C")
        if antennas then
            for _, a in ipairs(antennas) do
                if valid(a) then
                    local name = a.QuestTask:ToString()
                    if name and name ~= "" then story[name] = "GSM-ANTENNA" end
                end
            end
        end
    end)
    S.storyNames, S.regularNames = story, regular
    log("Task names resolved: %d of %d", resolved, #STORY_KEYS + #REGULAR_KEYS)
    return resolved
end

-- Returns "story" or "shared" plus a short reason for the task with the given id.
local function classifyTask(qm, id)
    local isSale, name = false, nil
    pcall(function() isSale = qm.taskIsSale[id + 1] == true end)
    if isSale then return "shared", "sale-task" end
    pcall(function() name = qm.taskNames[id + 1]:ToString() end)
    if not name or name == "" then
        return config.UnknownTaskXp == "story" and "story" or "shared", "task-unnamed"
    end
    if not S.storyNames or next(S.storyNames) == nil then buildTaskNameSets() end
    if S.regularNames[name] then return "shared", S.regularNames[name] end
    if S.storyNames[name] then return "story", S.storyNames[name] end
    return config.UnknownTaskXp == "story" and "story" or "shared", "task-unknown:" .. name
end

-- UE4SS delivers script-hook callbacks after the hooked function has returned on this
-- engine version, so the addExp callback of a task reward arrives just before the
-- markTaskStatus callback that paid it. Local XP gains are therefore held until the next
-- engine tick and matched (by time and amount) against the task rewards seen meanwhile.
-- Matching works for either callback order.
local MATCH_WINDOW = 0.25

local function sameAmount(a, b)
    return math.abs(a - b) <= 0.01 + 0.0001 * math.abs(b)
end

local function expect(amounts, kind, why)
    local now = os.clock()
    local kept = {}
    for _, ex in ipairs(S.expected) do
        if not ex.used and now - ex.at <= 1.0 then kept[#kept + 1] = ex end
    end
    kept[#kept + 1] = { amounts = amounts, kind = kind, why = why, at = now }
    S.expected = kept
end

local function takeExpectation(xp)
    for _, ex in ipairs(S.expected) do
        if not ex.used and math.abs(ex.at - xp.at) <= MATCH_WINDOW then
            for _, amount in ipairs(ex.amounts) do
                if sameAmount(xp.amount, amount) then
                    ex.used = true
                    return ex
                end
            end
        end
    end
    return nil
end

---------------------------------------------------------------- XP sharing

local function applyRemoteXp(amount, fromName)
    ExecuteInGameThread(function()
        local sm = findStats()
        if not sm then
            if #S.pendingXp < 500 then S.pendingXp[#S.pendingXp + 1] = { amount, fromName } end
            return
        end
        S.applyingRemote = true
        local ok, e = pcall(function() sm:addExp(amount) end)
        S.applyingRemote = false
        if ok then
            S.stats.received = S.stats.received + amount
            vlog("Applied %.1f shared XP from %s", amount, fromName)
        else
            log("Failed to apply shared XP: %s", tostring(e))
        end
    end)
end

local function flushPendingXp()
    if #S.pendingXp == 0 then return end
    ExecuteInGameThread(function()
        if not findStats() then return end
        local queue = S.pendingXp
        S.pendingXp = {}
        for _, item in ipairs(queue) do applyRemoteXp(item[1], item[2]) end
    end)
end

local function shareOrKeep(amount, kind, why)
    if kind == "story" then
        -- With one storyline for everybody a step is done once, by one player, for all of
        -- them: its XP is shared like that of any other task.
        local Story = package.loaded["coop.story"]
        local one = type(Story) == "table" and Story.oneStoryline ~= nil and Story.oneStoryline() == true
        if not one then
            S.stats.story = S.stats.story + amount
            vlog("XP %.1f (%s): storyline, kept local", amount, why)
            return
        end
        why = tostring(why) .. ", one storyline"
    end
    if not Net.hasPeers() then
        vlog("XP %.1f (%s): shareable, not in a lobby", amount, why)
        return
    end
    S.seq = S.seq + 1
    S.stats.sent = S.stats.sent + amount
    local reason = why:gsub("[|\r\n\t]", " ")
    Net.send("xp", { s = S.session, n = S.seq, a = amount, w = reason })
    vlog("XP %.1f (%s): shared with lobby", amount, why)
end

local function resolveLocalXp()
    local pending = S.pendingLocal
    S.pendingLocal, S.resolveQueued = {}, false
    for _, xp in ipairs(pending) do
        local ex = takeExpectation(xp)
        if ex then
            shareOrKeep(xp.amount, ex.kind, ex.why)
        else
            shareOrKeep(xp.amount, "shared", "direct")
        end
    end
end

local function onAddExp(_, expParam)
    if S.applyingRemote then return end
    local amount = expParam:get()
    if type(amount) ~= "number" or amount <= 0 then return end
    S.pendingLocal[#S.pendingLocal + 1] = { amount = amount, at = os.clock() }
    if not S.resolveQueued then
        S.resolveQueued = true
        ExecuteInGameThread(function()
            local ok, e = pcall(resolveLocalXp)
            if not ok then log("resolveLocalXp failed: %s", tostring(e)) end
        end)
    end
end

-- markTaskStatus(ID, Status): Status 1 = completed. A completed task pays
-- taskExpRewards[ID] (x1.15 at night) unless it completes a quest, which pays instead.
local function onMarkTask(ctx, idParam, statusParam)
    local id, status = idParam:get(), statusParam:get()
    if status ~= 1 then return end
    local qm = ctx:get()
    local reward, linkedQuest = 0, -1
    pcall(function() reward = qm.taskExpRewards[id + 1] end)
    pcall(function() linkedQuest = qm.taskCompletesQuest[id + 1] end)
    if type(reward) ~= "number" or reward <= 0 then return end
    if type(linkedQuest) == "number" and linkedQuest >= 0 then return end
    local kind, why = classifyTask(qm, id)
    expect({ reward, reward * 1.15 }, kind, why)
end

-- questEnded(Success, QuestID) pays questListExpReward[QuestID]: always storyline.
local function onQuestEnded(ctx, successParam, questIdParam)
    if successParam:get() ~= true then return end
    local reward = 0
    local questId = questIdParam:get()
    pcall(function() reward = ctx:get().questListExpReward[questId + 1] end)
    if type(reward) == "number" and reward > 0 then expect({ reward }, "story", "quest") end
end

---------------------------------------------------------------- wiring

Net.on("xp", function(senderId, data, senderName)
    local session, seq, amount = tostring(data.s), tonumber(data.n), tonumber(data.a)
    if not seq or not amount then return end
    local key = senderId .. ":" .. session
    if (S.lastSeq[key] or 0) >= seq then return end
    S.lastSeq[key] = seq
    if amount <= 0 or amount > config.MaxXpPerMessage then
        log("Ignoring out-of-range XP %.1f from %s", amount, senderName)
        return
    end
    amount = amount * (config.SharedXpMultiplier or 1.0)
    if amount <= 0 then return end
    applyRemoteXp(amount, senderName)
    if config.NotifyRemoteXp then Net.notify(string.format("+%.0f XP from %s", amount, senderName)) end
end)

Net.listen("lobby", function() S.lastSeq = {} end)

Core.Hooks.add("/Game/Interactive/statisticsManager.statisticsManager_C:addExp", onAddExp, function()
    S.storyNames, S.regularNames = nil, nil
end)
Core.Hooks.add("/Game/WorldControlers/questManager.questManager_C:markTaskStatus", onMarkTask)
Core.Hooks.add("/Game/WorldControlers/questManager.questManager_C:questEnded", onQuestEnded)

Core.every(2, flushPendingXp)

XP.findStats = findStats
XP.classifyTask = classifyTask
XP.buildTaskNameSets = buildTaskNameSets
-- Lets other modules change XP without it being shared again (state replication).
function XP.suppress(fn)
    local was = S.applyingRemote
    S.applyingRemote = true
    local ok, e = pcall(fn)
    S.applyingRemote = was
    if not ok then error(e, 0) end
end

return XP
