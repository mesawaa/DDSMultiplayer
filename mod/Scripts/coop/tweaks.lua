-- TWEAKS: what the switches of the TWEAKS page of MOD OPTIONS do to the game itself (the
-- switches are in the list of coop/experimental.lua; the delivery list and the client marks
-- have modules of their own).
--
-- Hide offer messages ("NoOfferHints"): a client who would have ordered a drug that is not
-- on offer is counted by the game's sales manager, drug by drug (ClientWishlist), and at
-- the fourth for one drug the game says "Word says that people are asking around for ...
-- Consider expanding your offer!" and starts counting again. The count is for nothing but
-- that message. With the switch on it is put back to nothing after every time the game has
-- counted, so the fourth never comes. Counts in the game that runs the sales.

local Core = require("core")

local log = Core.log

local GEN = (rawget(_G, "DDSMP_TWEAKS_GEN") or 0) + 1
_G.DDSMP_TWEAKS_GEN = GEN
local function live() return rawget(_G, "DDSMP_TWEAKS_GEN") == GEN end

local Tweaks = { cleared = 0 }

local SALES = "/Game/WorldControlers/salesManager.salesManager_C"

-- Puts the sales manager's count of wished-for drugs back to nothing. Returns how many
-- drugs had a count.
function Tweaks.forgetWishes(manager)
    local had = 0
    manager.ClientWishlist:ForEach(function(_, item)
        local n = item:get()
        if type(n) == "number" and n ~= 0 then
            had = had + 1
            item:set(0)
        end
    end)
    return had
end

Core.Hooks.add(SALES .. ":AddDrugWishlist", function(context)
    if not live() or not Core.experimental("NoOfferHints") then return end
    local ok, e = pcall(function()
        local manager = context:get()
        if not Core.valid(manager) then return end
        if Tweaks.forgetWishes(manager) > 0 then Tweaks.cleared = Tweaks.cleared + 1 end
    end)
    if not ok then log("Tweaks: offer messages: %s", tostring(e)) end
end)

return Tweaks
