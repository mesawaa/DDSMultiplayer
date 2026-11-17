-- The bags that hold nothing.
--
-- The game's loot spawners (the places where spray cans, bobby pins, water and money turn
-- up, and turn up again some time after they were taken) now and then put down a small bag
-- of drugs. The game rolls a drug and an amount for it, writes both into the bag's
-- description, and then gives the bag the id of a drug it never got (DMT, LSD, mushrooms:
-- it reads the wrong list). Such a bag holds nothing: it reads " (0g)" and puts an empty
-- thing into the pockets. One lies on the lowest board of the rack in Olivia's room.
--
-- Every such bag becomes the small find it was meant to be: one gram, of the drug the game
-- rolled for it or, about one time in three, of one of the cuts the pharmacist sells. The
-- spawners keep working as they do, so the places fill up again with something else.
--
-- What a bag holds follows from where it lies and what the game rolled for it: a bag that
-- every player's game has is the same in each, and it is what it was after a save is
-- loaded. A bag is set up the way the game sets its own up (what it is, how much, what it
-- is made of, then the game's own configPackage for its name and its model).

local Core = require("core")
local World = require("coop.world")
local Repl = require("coop.repl")

local log = Core.log

local GEN = (rawget(_G, "DDSMP_FINDS_GEN") or 0) + 1
_G.DDSMP_FINDS_GEN = GEN
local function live() return rawget(_G, "DDSMP_FINDS_GEN") == GEN end

local Finds = { stats = { made = 0 } }

local PICKUP = "/Game/Interactive/pickupItems/drugPickupItem.drugPickupItem_C"
local K_CONTENTS, K_PROPS = "MixContents_4_087C32B1445FBB5223EDA2A1A88D5B16", "MixProportions_7_B6CEC0E14F7E77A2F3CFCEB78B49F4C0"
local K_FORM, K_HUM, K_NAME = "SubstanceForm_10_C925520C4AB9EFE7114FA789E8C6ED6A", "Humidity_13_89BE6EF14389F8190C5A7FA273040A2B", "SubstanceName_16_B4DFC395423C963522E86AA3E95B2CFB"

-- What a bag can hold: the item, and the form the game keeps it in (0 powder, 1 crystals,
-- 2 pills, 3 dried plant: its drug table's own numbers). The game's seven drugs, and the
-- pharmacist's four.
Finds.POOL = {
    { id = "DRUG-MARIHUANA", form = 3 }, { id = "DRUG-AMPHETAMINE", form = 0 }, { id = "DRUG-ECSTASY", form = 2 }, { id = "DRUG-METH", form = 1 },
    { id = "DRUG-COCAINE", form = 0 }, { id = "DRUG-HEROIN", form = 0 }, { id = "DRUG-FENTANYL", form = 0 },
    { id = "ITEM-PARACETAMOL", form = 2 }, { id = "ITEM-IBUPROFEN", form = 2 }, { id = "ITEM-VIAGRA", form = 2 }, { id = "ITEM-NEBILANEX", form = 2 },
}
Finds.GRAMS = 1

-- The names the game's drug table has for its drugs (a bag's description carries the one
-- that was rolled for it), as numbers into POOL.
local ROLLED = { MJ = 1, AMP = 2, MDMA = 3, CRYSTAL = 4, COCO = 5, HERO = 6, FENT = 7 }
local DRUGS, CUTS = 7, 4

local function hash(l, text)
    local h = (math.floor(l.X + 0.5) * 73856093) ~ (math.floor(l.Y + 0.5) * 19349663) ~ (math.floor(l.Z + 0.5) * 83492791)
    h = h & 0x7fffffff
    for i = 1, #text do h = (h * 31 + text:byte(i)) & 0x7fffffff end
    return h
end

-- `rolled`: the game's name of the drug it meant the bag to hold ("" when unknown), and
-- `grams` the amount it rolled with it (which only serves to tell one roll from another:
-- a bag holds one gram).
local function pick(l, rolled, grams)
    rolled = tostring(rolled or "")
    local h = hash(l, rolled .. ":" .. tostring(grams or ""))
    local drug = ROLLED[rolled]
    if not drug then return Finds.POOL[h % #Finds.POOL + 1] end
    if h % (DRUGS + CUTS) < CUTS then return Finds.POOL[DRUGS + (h // 16) % CUTS + 1] end
    return Finds.POOL[drug]
end

local function rolledFor(a)
    local out, grams = "", ""
    pcall(function()
        local data = tostring(Repl.export(a, { "data" }).data)
        out = data:match('StringID_%d+_%x+="([^"]*)"') or ""
        grams = data:match("gramsPerItem_%d+_%x+=(%d+)") or ""
    end)
    return out, grams
end

-- True for a bag that holds nothing.
local function empty(a)
    local ok, v = pcall(function()
        if a.baseGramsPerItem ~= 0 then return false end
        return a.objName:ToString():match("^%s*%(0g%)%s*$") ~= nil
    end)
    return ok and v == true
end

local function fill(a)
    local l = a:K2_GetActorLocation()
    local rolled, grams = rolledFor(a)
    local what = pick(l, rolled, grams)
    a.SubstanceID = FName(what.id)
    a.baseGramsPerItem = Finds.GRAMS
    Repl.import(a, { SubstanceMixProp = string.format('(%s=("%s"),%s=(1.000000),%s=%d,%s=0.000000,%s="")', K_CONTENTS, what.id, K_PROPS, K_FORM, what.form, K_HUM, K_NAME) })
    a:configPackage()
    Finds.stats.made = Finds.stats.made + 1
    local name = "?"
    pcall(function() name = a.objName:ToString() end)
    log("Finds: the empty bag at %.0f %.0f %.0f now holds %s (the game had rolled %s)", l.X, l.Y, l.Z, name, rolled ~= "" and rolled or "nothing")
end

-- A bag is looked at twice, a few seconds apart, before it is touched: one that is only
-- just being put into the world may not have been told yet what it is.
local seen = {}           -- address -> time it was first seen holding nothing

Core.every(4, function()
    if not live() then return end
    local player = World.player()
    if not player or World.joining or World.gone then
        seen = {}
        return
    end
    local still = {}
    for _, a in ipairs(Core.actors(PICKUP) or {}) do
        if Core.alive(a) and empty(a) then
            local address = a:GetAddress()
            local since = seen[address] or os.clock()
            if os.clock() - since >= 3 then
                local ok, e = pcall(fill, a)
                if not ok then
                    log("Finds: a bag could not be filled: %s", tostring(e))
                    still[address] = os.clock() + 600       -- (not again for a while)
                end
            else
                still[address] = since
            end
        end
    end
    seen = still
end)

function Finds.pick(x, y, z, rolled, grams) return pick({ X = x, Y = y, Z = z }, rolled, grams) end

return Finds
