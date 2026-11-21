-- Who you are in co-op: a character (a small set of strengths and weaknesses), and how
-- the others see you (outfit, face, hair).
--
-- The character and a first outfit, face and hair are chosen once, on the "who are you"
-- screen. New outfits and hats are bought at the clothes shop: a counter in the furniture
-- shop, marked on the map; purchases come out of the (shared) bank account. At a wardrobe
-- (the piece of furniture, in any hideout) the wardrobe key opens the same kind of screen
-- with what the player owns. A fugitive who changes clothes at a wardrobe, as the game has
-- it, really does: another outfit and hat of their own, picked at random.
-- Everything is kept in one file per player on that player's computer and applies in any
-- world, hosted or joined.
--
-- The game is first-person, so you do not see your own clothes: the other players do.

local Core = require("core")
local Net = require("net")
local Repl = require("coop.repl")
local World = require("coop.world")
local Avatar = require("coop.avatar")
local Hud = require("coop.hud")
local Screen = require("coop.screen")
local Thumbs = require("coop.thumbs")
local Clerk = require("coop.clerk")
local Guests = require("coop.guests")
local json = require("json")

local log, vlog, valid = Core.log, Core.vlog, Core.valid

local Look = { page = nil, index = 1 }

-- A body "MESH#MATERIAL" is the mesh in another of the game's colours (coop/avatar.lua). A
-- colour costs what the outfit it is a colour of costs.
local OUTFITS = {
    { id = "jacket", starter = true, name = "Yellow jacket", body = "SK_ma_casual_jacket_01_a", price = 800 },
    { id = "jacket2", name = "Dark jacket", body = "SK_ma_casual_jacket_01_b#MI_casual_jacket_01_dark", price = 800 },
    { id = "jacket3", name = "Black jacket", body = "SK_ma_casual_jacket_01_a#MI_casual_jacket_equipmentGuy", price = 1000 },
    { id = "jacket_b", name = "Yellow jacket", body = "SK_ma_casual_jacket_01_b", price = 800 },
    { id = "jacket_ad", name = "Dark jacket", body = "SK_ma_casual_jacket_01_a#MI_casual_jacket_01_dark", price = 800 },
    { id = "jacket_bk", name = "Black jacket", body = "SK_ma_casual_jacket_01_b#MI_casual_jacket_equipmentGuy", price = 1000 },
    { id = "shirt1", starter = true, name = "Shirt, rolled sleeves", body = "SK_ma_casual_02_a", price = 250 },
    { id = "shirt1b", name = "Shirt, rolled sleeves", body = "SK_ma_casual_02_a#MI_casual_02_blue", price = 250 },
    { id = "shirt1r", name = "Shirt, rolled sleeves", body = "SK_ma_casual_02_a#MI_casual_02_red", price = 250 },
    { id = "shirt1g", name = "Shirt, rolled sleeves", body = "SK_ma_casual_02_a#MI_casual_02_seedGuy", price = 250 },
    { id = "shirt1c", name = "Shirt, rolled sleeves", body = "SK_ma_casual_02_a#MI_casual_DeadDealer02", price = 250 },
    { id = "shirt1p", name = "Shirt, rolled sleeves", body = "SK_ma_casual_02_a#MI_casual_jay", price = 250 },
    { id = "shirt1o", name = "Shirt, rolled sleeves", body = "SK_ma_casual_02_a#MI_construction_worker_02_dirt_orange", price = 250 },
    { id = "track1", starter = true, name = "Tracksuit", body = "SK_ma_sport_01_a", price = 450 },
    { id = "track1w", name = "Tracksuit", body = "SK_ma_sport_01_a#MI_ma_sport_01_red", price = 450 },
    { id = "track1n", name = "Tracksuit", body = "SK_ma_sport_01_a#MI_ma_sport_01_base", price = 450 },
    { id = "track1k", name = "Tracksuit", body = "SK_ma_sport_01_a#MI_ma_sport_Sicario", price = 450 },
    { id = "track1s", name = "Tracksuit", body = "SK_ma_sport_01_a#MI_ma_sport_02", price = 450 },
    { id = "track1d", name = "Tracksuit", body = "SK_ma_sport_01_a#MI_ma_sport_02_dark", price = 450 },
    { id = "track2", name = "Sports T-shirt", body = "SK_ma_sport_01_b", price = 500 },
    { id = "track2d", name = "Sports T-shirt", body = "SK_ma_sport_01_b#MI_ma_sport_02_dark", price = 500 },
    { id = "track2k", name = "Sports T-shirt", body = "SK_ma_sport_01_b#MI_ma_sport_02_dark2", price = 500 },
    { id = "track2n", name = "Sports T-shirt", body = "SK_ma_sport_01_b#MI_ma_sport_01_base", price = 500 },
    { id = "track2o", name = "Sports T-shirt", body = "SK_ma_sport_01_b#MI_ma_sport_01_blue", price = 500 },
    { id = "track2w", name = "Sports T-shirt", body = "SK_ma_sport_01_b#MI_ma_sport_01_red", price = 500 },
    { id = "track3", name = "Sweatshirt", body = "SK_ma_sport_01_c", price = 500 },
    { id = "track3o", name = "Sweatshirt", body = "SK_ma_sport_01_c#MI_ma_sport_01_blue", price = 500 },
    { id = "track3w", name = "Sweatshirt", body = "SK_ma_sport_01_c#MI_ma_sport_01_red", price = 500 },
    { id = "track3k", name = "Sweatshirt", body = "SK_ma_sport_01_c#MI_ma_sport_02_dark2", price = 500 },
    { id = "work1", starter = true, name = "Work clothes", body = "SK_ma_construction_worker_01", price = 200 },
    { id = "work1d", name = "Work clothes", body = "SK_ma_construction_worker_01#MI_construction_worker_02_dirt_orange", price = 200 },
    { id = "work1g", name = "Work clothes", body = "SK_ma_construction_worker_01#MI_casual_02_seedGuy", price = 200 },
    { id = "work1c", name = "Work clothes", body = "SK_ma_construction_worker_01#MI_casual_DeadDealer02", price = 200 },
    { id = "work1p", name = "Work clothes", body = "SK_ma_construction_worker_01#MI_casual_jay", price = 200 },
    { id = "work2", name = "Work clothes second", body = "SK_ma_construction_worker_01_c", price = 200 },
    { id = "work2c", name = "Work clothes second", body = "SK_ma_construction_worker_01_c#MI_casual_DeadDealer02", price = 200 },
    { id = "work3", name = "Work clothes third", body = "SK_ma_construction_worker_02_a", price = 200 },
    { id = "work3n", name = "Work clothes third", body = "SK_ma_construction_worker_02_a#MI_casual_02", price = 200 },
    { id = "work3b", name = "Work clothes third", body = "SK_ma_construction_worker_02_a#MI_casual_02_blue", price = 200 },
    { id = "work3d", name = "Work clothes third", body = "SK_ma_construction_worker_02_b", price = 200 },
    { id = "work4w", name = "Work clothes third", body = "SK_ma_construction_worker_02_b#MI_construction_worker_01", price = 200 },
    { id = "work4b", name = "Work clothes third", body = "SK_ma_construction_worker_02_b#MI_casual_02_blue", price = 200 },
    { id = "work4r", name = "Work clothes third", body = "SK_ma_construction_worker_02_b#MI_casual_02_red", price = 200 },
    { id = "work4g", name = "Work clothes third", body = "SK_ma_construction_worker_02_b#MI_casual_02_seedGuy", price = 200 },
    { id = "work4c", name = "Work clothes third", body = "SK_ma_construction_worker_02_b#MI_casual_DeadDealer02", price = 200 },
    { id = "shirt2", name = "Hoodie", body = "SK_ma_casual_02_b", price = 250 },
    { id = "shirt2b", name = "Hoodie", body = "SK_ma_casual_02_b#MI_casual_02_blue", price = 250 },
    { id = "shirt2r", name = "Hoodie", body = "SK_ma_casual_02_b#MI_casual_02_red", price = 250 },
    { id = "shirt2g", name = "Hoodie", body = "SK_ma_casual_02_b#MI_casual_02_seedGuy", price = 250 },
    { id = "shirt2c", name = "Hoodie", body = "SK_ma_casual_02_b#MI_casual_DeadDealer02", price = 250 },
    { id = "shirt2p", name = "Hoodie", body = "SK_ma_casual_02_b#MI_casual_jay", price = 250 },
    { id = "shirt2o", name = "Hoodie", body = "SK_ma_casual_02_b#MI_construction_worker_02_dirt_orange", price = 250 },
    { id = "shirt3", name = "Hoodie, second cut", body = "SK_ma_casual_02_c", price = 250 },
    { id = "shirt3b", name = "Hoodie, second cut", body = "SK_ma_casual_02_c#MI_casual_02_blue", price = 250 },
    { id = "shirt3r", name = "Hoodie, second cut", body = "SK_ma_casual_02_c#MI_casual_02_red", price = 250 },
    { id = "shirt3g", name = "Hoodie, second cut", body = "SK_ma_casual_02_c#MI_casual_02_seedGuy", price = 250 },
    { id = "shirt3c", name = "Hoodie, second cut", body = "SK_ma_casual_02_c#MI_casual_DeadDealer02", price = 250 },
    { id = "shirt3p", name = "Hoodie, second cut", body = "SK_ma_casual_02_c#MI_casual_jay", price = 250 },
    { id = "shirt3o", name = "Hoodie, second cut", body = "SK_ma_casual_02_c#MI_construction_worker_02_dirt_orange", price = 250 },
    { id = "waiter", shop = "formal", name = "Waiter", body = "SK_ma_waiter_01", price = 900 },
    { id = "doctor", shop = "formal", name = "Doctor's coat", body = "SK_ma_physician_01", price = 1200 },
    { id = "suit1", shop = "formal", name = "Suit", body = "SK_ma_business_01", price = 2000 },
    { id = "suit2", shop = "formal", name = "Suit, second cut", body = "SK_ma_business_01_b", price = 2000 },
    { id = "suit1c", shop = "formal", name = "Suit", body = "SK_ma_business_01#MI_ma_business_01_c", price = 2000 },
    { id = "suit1d", shop = "formal", name = "Suit", body = "SK_ma_business_01#MI_ma_business_01_c_dark", price = 2000 },
    { id = "suit1m", shop = "formal", name = "Suit", body = "SK_ma_business_01#MI_ma_business_01_moneyLaunderer", price = 2000 },
    { id = "suit1k", shop = "formal", name = "Suit", body = "SK_ma_business_01#MI_ma_business_bodyguard", price = 2000 },
    { id = "suit1p", shop = "formal", name = "Suit", body = "SK_ma_business_01#MI_donaldSuit", price = 2000 },
    { id = "suit1b", shop = "formal", name = "Suit", body = "SK_ma_business_01#MI_ma_business_01", price = 2000 },
    { id = "suit2w", shop = "formal", name = "Suit, second cut", body = "SK_ma_business_01_b#MI_ma_business_01_blue_white", price = 2000 },
    { id = "suit2c", shop = "formal", name = "Suit, second cut", body = "SK_ma_business_01_b#MI_ma_business_01_c", price = 2000 },
    { id = "suit2d", shop = "formal", name = "Suit, second cut", body = "SK_ma_business_01_b#MI_ma_business_01_c_dark", price = 2000 },
    { id = "suit2m", shop = "formal", name = "Suit, second cut", body = "SK_ma_business_01_b#MI_ma_business_01_moneyLaunderer", price = 2000 },
    { id = "suit2k", shop = "formal", name = "Suit, second cut", body = "SK_ma_business_01_b#MI_ma_business_bodyguard", price = 2000 },
    { id = "suit2p", shop = "formal", name = "Suit, second cut", body = "SK_ma_business_01_b#MI_donaldSuit", price = 2000 },
}
local FACES = { "SK_ma_head_01", "SK_ma_head_02", "SK_ma_head_04_dark", "SK_ma_head_05_asian", "SK_ma_head_05_basian" }
local HAIR = {
    { name = "Hair 1", mesh = "Hats_Hair/SK_ma_hair_02" }, { name = "Hair 2", mesh = "Hats_Hair/SK_ma_hair_01" },
    { name = "Hair 3", mesh = "Hats_Hair/SK_ma_hair_03" }, { name = "Hair 4", mesh = "Hats_Hair/SK_ma_hair_04" },
    { name = "Hair 5", mesh = "Hats_Hair/SK_ma_hair_05" }, { name = "Hair 6", mesh = "Hats_Hair/SK_ma_hair_06" },
    { name = "Cap", price = 300, mesh = "Hats_Hair/SK_ma_hat_cap_01" }, { name = "Cap, second", price = 300, mesh = "Hats_Hair/SK_ma_hat_cap_02" },
    { name = "Beanie", price = 200, mesh = "Hats_Hair/SK_ma_hat_casual_set_beanie_01" }, { name = "Flat cap", price = 600, shop = "formal", mesh = "Hats_Hair/SK_ma_hat_flatcap_01" },
    { name = "Beret", price = 500, shop = "formal", mesh = "Hats_Hair/SK_ma_hat_beret_01" }, { name = "Country hat", price = 1500, shop = "formal", mesh = "Hats_Hair/SK_ma_hat_country_02" },
    { name = "Bald", mesh = "" },
    -- (added later: after Bald, so that what players own keeps its number)
    { name = "Cap", price = 300, mesh = "Hats_Hair/SK_ma_hat_cap_01#MI_hat_cap_01_darkblue" },
    { name = "Cap, second", price = 300, mesh = "Hats_Hair/SK_ma_hat_cap_02#MI_hat_cap_02_logo1" },
    { name = "Army cap", price = 400, mesh = "Hats_Hair/SK_ma_hat_casual_set_army_cap_01" },
    { name = "Army cap, second", price = 400, mesh = "Hats_Hair/SK_ma_hat_casual_set_army_cap_01_back_hair" },
    { name = "Hard hat", price = 250, mesh = "Hats_Hair/SK_ma_hat_construction_worker_01" },
    { name = "Ear defenders", price = 1200, mesh = "Hats_Hair/SK_ma_hat_headset_01" },
    { name = "Cap, second", price = 300, mesh = "Hats_Hair/SK_ma_hat_cap_02#MI_hat_cap_01" },
    { name = "Cap, second", price = 300, mesh = "Hats_Hair/SK_ma_hat_cap_02#MI_hat_cap_01_brownblue" },
}
-- The female catalogue. Every one of these outfits comes with shoes and needs no body under
-- it (coop/avatar.lua builds a female figure on the male skeleton, so every animation of the
-- mod plays on it). Colours as for the men's.
local F_OUTFITS = {
    { id = "f_sweater", starter = true, name = "Sweater, jeans", body = "SK_fe_casual_02_a", price = 400 },
    { id = "f_sweater_g", name = "Sweater, jeans", body = "SK_fe_casual_02_a#MI_fe_casual_01_dark", price = 400 },
    { id = "f_sweater_o", name = "Sweater, jeans", body = "SK_fe_casual_02_a#MI_fe_casual_01_yellow", price = 400 },
    { id = "f_sweater_s", name = "Sweater, jeans", body = "SK_fe_casual_02_a#MI_fe_casual_03", price = 400 },
    -- (the four to start with are four different colours: the light one, green, the stripes, orange)
    { id = "f_jumper", name = "Jumper, jeans", body = "SK_fe_casual_02_b", price = 300 },
    { id = "f_jumper_g", starter = true, name = "Jumper, jeans", body = "SK_fe_casual_02_b#MI_fe_casual_01_dark", price = 300 },
    { id = "f_jumper_o", name = "Jumper, jeans", body = "SK_fe_casual_02_b#MI_fe_casual_01_yellow", price = 300 },
    { id = "f_jumper_s", name = "Jumper, jeans", body = "SK_fe_casual_02_b#MI_fe_casual_03", price = 300 },
    { id = "f_stripes", starter = true, name = "Striped top", body = "SK_fe_casual_02_c", price = 250 },
    { id = "f_stripes_b", name = "Striped top", body = "SK_fe_casual_02_c#MI_fe_casual_01", price = 250 },
    { id = "f_stripes_g", name = "Striped top", body = "SK_fe_casual_02_c#MI_fe_casual_01_dark", price = 250 },
    { id = "f_stripes_o", name = "Striped top", body = "SK_fe_casual_02_c#MI_fe_casual_01_yellow", price = 250 },
    { id = "f_crop", name = "Crop top", body = "SK_fe_casual_02_d", price = 200 },
    { id = "f_crop_g", name = "Crop top", body = "SK_fe_casual_02_d#MI_fe_casual_01_dark", price = 200 },
    { id = "f_crop_o", starter = true, name = "Crop top", body = "SK_fe_casual_02_d#MI_fe_casual_01_yellow", price = 200 },
    { id = "f_crop_s", name = "Crop top", body = "SK_fe_casual_02_d#MI_fe_casual_03", price = 200 },
    { id = "f_skirt", name = "Sweater, skirt", body = "SK_fe_clerk_01", price = 200 },
    { id = "f_skirt_b", name = "Sweater, skirt", body = "SK_fe_clerk_01#MI_fe_casual_01", price = 200 },
    { id = "f_skirt_g", name = "Sweater, skirt", body = "SK_fe_clerk_01#MI_fe_casual_01_dark", price = 200 },
    { id = "f_skirt_s", name = "Sweater, skirt", body = "SK_fe_clerk_01#MI_fe_casual_03", price = 200 },
    { id = "f_jog", name = "Jogging set", body = "SK_fe_sport_01", price = 600 },
    { id = "f_hoodie", name = "Hoodie, sweatpants", body = "SK_fe_sport_02_b", price = 200 },
    { id = "f_hoodie_b", name = "Hoodie, sweatpants", body = "SK_fe_sport_02_b#MI_fe_sport_02_blue", price = 200 },
    { id = "f_hoodie_o", name = "Hoodie, sweatpants", body = "SK_fe_sport_02_b#MI_fe_sport_02_orange", price = 200 },
    { id = "f_hoodie_a", name = "Hoodie, sweatpants", body = "SK_fe_sport_02_b#MI_fe_sport_Amy", price = 200 },
    { id = "f_suit", shop = "formal", name = "Suit", body = "SK_fe_business_01_c", price = 1800 },
    { id = "f_suit_w", shop = "formal", name = "Suit", body = "SK_fe_business_01_c#MI_fe_business_01", price = 1800 },
    { id = "f_suit_b", shop = "formal", name = "Suit", body = "SK_fe_business_01_c#MI_fe_business_01_blue", price = 1800 },
    { id = "f_suit_p", shop = "formal", name = "Suit", body = "SK_fe_business_01_c#MI_fe_business_01_SicarioWife", price = 1800 },
    { id = "f_suit_r", shop = "formal", name = "Suit", body = "SK_fe_business_01_c#MI_fe_business_01_b_red", price = 1800 },
    { id = "f_tights", shop = "formal", name = "Suit, tights", body = "SK_fe_business_01_b", price = 1800 },
    { id = "f_tights_d", shop = "formal", name = "Suit, tights", body = "SK_fe_business_01_b#MI_fe_business_01_d", price = 1800 },
    { id = "f_tights_b", shop = "formal", name = "Suit, tights", body = "SK_fe_business_01_b#MI_fe_business_01_blue", price = 1800 },
    { id = "f_tights_p", shop = "formal", name = "Suit, tights", body = "SK_fe_business_01_b#MI_fe_business_01_SicarioWife", price = 1800 },
    { id = "f_tights_r", shop = "formal", name = "Suit, tights", body = "SK_fe_business_01_b#MI_fe_business_01_b_red", price = 1800 },
    { id = "f_tshirt", name = "T-shirt, sweatpants", body = "SK_fe_sport_02_a", price = 200 },
    { id = "f_tshirt_o", name = "T-shirt, sweatpants", body = "SK_fe_sport_02_a#MI_fe_sport_02_orange", price = 200 },
    { id = "f_tshirt_b", name = "T-shirt, sweatpants", body = "SK_fe_sport_02_a#MI_fe_sport_02_blue", price = 200 },
    { id = "f_tshirt_a", name = "T-shirt, sweatpants", body = "SK_fe_sport_02_a#MI_fe_sport_Amy", price = 200 },
    { id = "f_tsuit", shop = "formal", name = "Trouser suit", body = "SK_fe_business_01_a", price = 2200 },
    { id = "f_tsuit_d", shop = "formal", name = "Trouser suit", body = "SK_fe_business_01_a#MI_fe_business_01_d", price = 2200 },
    { id = "f_tsuit_w", shop = "formal", name = "Trouser suit", body = "SK_fe_business_01_a#MI_fe_business_01", price = 2200 },
    { id = "f_tsuit_p", shop = "formal", name = "Trouser suit", body = "SK_fe_business_01_a#MI_fe_business_01_SicarioWife", price = 2200 },
    { id = "f_tsuit_r", shop = "formal", name = "Trouser suit", body = "SK_fe_business_01_a#MI_fe_business_01_b_red", price = 2200 },
}
local F_FACES = { "SK_fe_head_01", "SK_fe_head_01_dark", "SK_fe_head_02_asian", "SK_fe_head_02_b", "SK_fe_head_03", "SK_fe_head_05" }
local F_HAIR = {
    { name = "Bald", mesh = "" },
    { name = "Hair 1", mesh = "Hats_Hair/SK_fe_hair_01" }, { name = "Hair 2", mesh = "Hats_Hair/SK_fe_hair_02" },
    { name = "Hair 3", mesh = "Hats_Hair/SK_fe_hair_03" }, { name = "Hair 4", mesh = "Hats_Hair/SK_fe_hair_04" },
    { name = "Hair 5", mesh = "Hats_Hair/SK_fe_hair_05" },
    { name = "Cap", price = 300, mesh = "Hats_Hair/SK_fe_hat_cap_01" }, { name = "Cap", price = 300, mesh = "Hats_Hair/SK_fe_hat_cap_01#MI_hat_cap_01_darkblue" },
    { name = "Army cap", price = 400, mesh = "Hats_Hair/SK_fe_hat_casual_set_army_cap_01" },
    { name = "Beanie", price = 200, mesh = "Hats_Hair/SK_fe_hat_casual_set_beanie_01_hair" }, { name = "Beanie, second", price = 200, mesh = "Hats_Hair/SK_fe_hat_casual_set_beanie_02" },
    { name = "Beret", price = 500, shop = "formal", mesh = "Hats_Hair/SK_fe_hat_beret_01_a" }, { name = "Beret, second", price = 500, shop = "formal", mesh = "Hats_Hair/SK_fe_hat_beret_01_b" },
    -- (Olivia's only: not among the styles a new character chooses from)
    { name = "Hair 6", mesh = "Hats_Hair/SK_fe_hair_02_eyeglass", barber = true },
}
-- Glasses, bought at Marco's and worn with any hair or hat. None to begin with.
local M_GLASSES = {
    { name = "Wire glasses", mesh = "SK_ma_glass_01", price = 150, shop = "formal" }, { name = "Round glasses", mesh = "SK_ma_glass_02", price = 150, shop = "formal" },
    { name = "Black frames", mesh = "SK_ma_glass_04", price = 200, shop = "formal" }, { name = "Rectangle glasses", mesh = "SK_ma_glass_05", price = 200, shop = "formal" },
    { name = "Sports sunglasses", mesh = "SK_ma_glass_03", price = 2000 },
    -- (other frame colours: "MESH#MATERIAL" puts the material on the frame, coop/avatar.lua)
    { name = "Wire glasses", mesh = "SK_ma_glass_01#MI_glass_01_red", price = 150, shop = "formal" },
    { name = "Wire glasses", mesh = "SK_ma_glass_01#MI_glass_dark2", price = 150, shop = "formal" },
    { name = "Round glasses", mesh = "SK_ma_glass_02#MI_glass_01_red", price = 150, shop = "formal" },
    { name = "Round glasses", mesh = "SK_ma_glass_02#MI_glass_dark2", price = 150, shop = "formal" },
    { name = "Sports sunglasses", mesh = "SK_ma_glass_03#MI_glass_01", price = 2000 },
    { name = "Sports sunglasses", mesh = "SK_ma_glass_03#MI_glass_01_dark", price = 2000 },
    { name = "Sports sunglasses", mesh = "SK_ma_glass_03#MI_glass_black", price = 2000 },
    { name = "Sports sunglasses", mesh = "SK_ma_glass_03#MI_glass_dark2", price = 2000 },
    { name = "Black frames", mesh = "SK_ma_glass_04#MI_glass_01", price = 200, shop = "formal" },
    { name = "Rectangle glasses", mesh = "SK_ma_glass_05#MI_glass_01", price = 200, shop = "formal" },
}
-- Watches: the game's two watch models, worn on the left wrist by men and women alike
-- (coop/avatar.lua). What a player owns of them is kept as "w1", "w2". None to begin with.
local WATCHES = {
    { name = "Steel watch", code = "analog", price = 1500 },
    { name = "Gold watch", code = "digital", price = 6000, shop = "formal" },
}
local watchAllowed = { [""] = true }
for _, w in ipairs(WATCHES) do watchAllowed[w.code] = true end
-- Men's hats are worn over the hair (where hair sticks through, Bald is free). Every
-- women's hat takes the hair off: none of their hairstyles fits under one.
Avatar.hidesHair = function(hatMesh)
    local name = (tostring(hatMesh or ""):gsub("#.*$", "")):match("[^/]+$") or ""
    return name:sub(1, 10) == "SK_fe_hat_"
end

-- Beards (men): chosen on the "who are you" screen, worn with any hair, hat or glasses.
local BEARDS = {
    { name = "Beard 1", mesh = "Hats_Hair/SK_ma_beard_single_01" }, { name = "Beard 2", mesh = "Hats_Hair/SK_ma_beard_single_02" },
}
local F_GLASSES = {
    { name = "Rimless glasses", mesh = "SK_fe_glass_01_generic", price = 150, shop = "formal" }, { name = "Rectangle glasses", mesh = "SK_fe_glass_05", price = 150, shop = "formal" },
    { name = "Sports glasses", mesh = "SK_fe_glass_02_scientist", price = 1000 }, { name = "Thick frames", mesh = "SK_fe_glass_03", price = 1000, gone = true },
    { name = "Thin frames", mesh = "SK_fe_glass_04", price = 200, shop = "formal", gone = true },
    { name = "Rimless glasses", mesh = "SK_fe_glass_01_generic#MI_glass_01_red", price = 150, shop = "formal" },
    { name = "Rimless glasses", mesh = "SK_fe_glass_01_generic#MI_glass_dark2", price = 150, shop = "formal" },
    { name = "Sports glasses", mesh = "SK_fe_glass_02_scientist#MI_glass_black", price = 1000 },
    { name = "Thick frames", mesh = "SK_fe_glass_03#MI_glass_01", price = 1000 },
    { name = "Thick frames", mesh = "SK_fe_glass_03#MI_glass_black", price = 1000 },
    { name = "Thin frames", mesh = "SK_fe_glass_04#MI_glass_01", price = 200, shop = "formal" },
    { name = "Thin frames", mesh = "SK_fe_glass_04#MI_glass_black", price = 200, shop = "formal" },
    { name = "Rectangle glasses", mesh = "SK_fe_glass_05#MI_glass_01", price = 150, shop = "formal" },
}
-- Hair colours (Olivia's, coop/barber.lua): the game's hair materials. Each of them fits
-- every hairstyle and both beards. A hairstyle that was never dyed has the colour the game
-- made it in (NATURAL). A player has one hair colour; the beard is always that colour.
local HAIR_COLOURS = {
    { id = "MI_hair", name = "Brown" }, { id = "MI_hair_02_blond", name = "Light brown" }, { id = "MI_hair_02_brown", name = "Ash" },
    { id = "MI_fe_hair_02_dark", name = "Chestnut" }, { id = "MI_hair_02_dark", name = "Black" }, { id = "MI_fe_hair_02_diana", name = "Jet black" },
    { id = "MI_ma_hair_03_amy", name = "Blue" }, { id = "MI_fe_hair_04", name = "Red" }, { id = "hairSicarioWife", name = "Blond" },
    { id = "MI_hairJay", name = "Grey" }, { id = "MI_fe_hair_02_grey", name = "White" },
}
-- (a beard is always the very material the hair has, dyed or not: only so do the two look
-- alike in every light; with no hair it is the beard's own brown)
local hairColourListed = {}
for _, c in ipairs(HAIR_COLOURS) do hairColourListed[c.id] = true end
local function beardColourFor(colour) return colour end
local NATURAL = {
    SK_ma_hair_01 = "MI_hair", SK_ma_hair_02 = "MI_ma_hair_05_short", SK_ma_hair_03 = "MI_ma_hair_03_dark1", SK_ma_hair_04 = "MI_hair_02_blond",
    SK_ma_hair_05 = "MI_hair_02_dark", SK_ma_hair_06 = "MI_ma_hair_05_short", SK_fe_hair_01 = "MI_hair_02_blond", SK_fe_hair_02 = "MI_fe_hair_02_dark",
    SK_fe_hair_03 = "MI_hair_02_dark", SK_fe_hair_04 = "MI_fe_hair_04", SK_fe_hair_05 = "MI_hair_02_brown",
    SK_fe_hair_02_eyeglass = "MI_ma_hair_03_asian",
}
local hairColourAllowed = Avatar.HAIR_MATERIALS or {}
-- What Olivia charges for each thing that is changed.
local BARBER_PRICE = { cut = 60, colour = 150, beard = 40 }
-- Each gender's lists. A player's choices for the other one are kept for when they switch
-- back on the "who are you" screen. Hats owned are kept by index, the women's with "f".
local SETS = {
    m = { outfits = OUTFITS, faces = FACES, hair = HAIR, glasses = M_GLASSES, default = "jacket", hairKey = "" },
    f = { outfits = F_OUTFITS, faces = F_FACES, hair = F_HAIR, glasses = F_GLASSES, default = "f_sweater", hairKey = "f" },
}
-- Every number of every kind of character is in this list. stamina and speed multiply the
-- character's base values; seen multiplies how visible the player is to police (lower is
-- harder to spot); pockets adds pocket slots. The others are looked after by
-- coop/traits.lua: tagTime multiplies how long a wall tag takes, drugTime how long a drug
-- works and seenHigh how visible the player is while one does, freePick opens a lock for a
-- bobby pin without the lockpick game and pickHeat is what that counts as with the police
-- (a row of the game's ExpoEventsDatabase), once in every pickHeatEvery locks: the game's
-- list has no row milder than a police search, so half of one is one for every second lock.
local CHARACTERS = {
    { id = "hustler", name = "The Hustler", stamina = 1.0, speed = 1.0, seen = 1.0, pockets = 0 },
    { id = "runner", name = "The Runner", stamina = 1.25, speed = 1.1, seen = 1.12, pockets = 0 },
    { id = "ghost", name = "The Ghost", stamina = 0.8, speed = 1.0, seen = 0.85, pockets = 0 },
    { id = "tagger", name = "The Tagger", stamina = 1.0, speed = 1.0, seen = 1.0, pockets = -1, tagTime = 0.5 },
    { id = "lightweight", name = "The Lightweight", stamina = 1.0, speed = 1.0, seen = 1.0, pockets = 0, drugTime = 2, seenHigh = 1.2 },
    { id = "crook", name = "The Crook", stamina = 1.0, speed = 1.0, seen = 1.0, pockets = 0, freePick = true, pickHeat = "POLICE-SEARCH", pickHeatEvery = 2 },
}
-- Kinds that are gone, and what a player who was one is now.
local FORMER = { athlete = "runner", mule = "hustler" }
-- Goes up when the list changes so much that everybody should choose again: a player who
-- chose under an older list gets the "who are you" screen once more, with what they are
-- now already selected.
local ROSTER = 2
local CHARACTER_CHANGE_PRICE = 300
-- Donald's furniture shop at the Old Market (where the game's own shop actor stands).
local SHOP = { x = -1495, y = -12945, z = 110, reach = 600 }

local byId, bodyAllowed, faceAllowed, hairAllowed, glassesAllowed = {}, {}, {}, { [""] = true }, { [""] = true }
local beardAllowed = { [""] = true }
for _, b in ipairs(BEARDS) do beardAllowed[b.mesh] = true end
local genderOf = {}
for g, set in pairs(SETS) do
    for _, o in ipairs(set.outfits) do byId[o.id] = o; bodyAllowed[o.body] = true; genderOf[o.id] = g end
    for _, f in ipairs(set.faces) do faceAllowed[f] = true end
    for _, h in ipairs(set.hair) do hairAllowed[h.mesh] = true end
    for _, g in ipairs(set.glasses) do glassesAllowed[g.mesh] = true end
end
local characterById = {}
for _, c in ipairs(CHARACTERS) do characterById[c.id] = c end

local state = { gender = "m", other = {}, outfit = "jacket", face = 1, hair = 1, hat = 0, glasses = 0, watch = 0, beard = 0, hairOff = false, character = "hustler", owned = { jacket = true }, ownedHair = {}, ownedGlasses = {}, ownedWatches = {}, characterPicked = false, roster = ROSTER }

---------------------------------------------------------------- what is owned, per save

-- What the player owns (outfits, hats, glasses) belongs to the save, like the "who are you"
-- choice (coop/guests.lua: the host's own and single player beside the save, a guest's in
-- the host's world). It is written when the game saves, so a purchase in a game that is
-- not saved is gone with it, like the money paid for it. The lists in state are this
-- world's; they are set when a world is there (applyOwned) and sent on with every purchase.
local function copyTrue(t)
    local out = {}
    for k, v in pairs(type(t) == "table" and t or {}) do if v == true then out[tostring(k)] = true end end
    return out
end
local loaded = false
local applyingTraits = false

local function S() return SETS[state.gender] or SETS.m end
-- the first hairstyle with hair (Bald comes first in the women's list)
local function firstHair()
    for i, h in ipairs(S().hair) do if not h.price and not h.barber and h.mesh ~= "" then return i end end
    return 1
end
-- the key a hat of the current gender's list is kept under
local function hk(i) return S().hairKey .. tostring(i) end
-- the same for glasses ("g3", "fg3")
local function gk(i) return S().hairKey .. "g" .. tostring(i) end
local function glassesOf(key)
    local f, n = tostring(key):match("^(f?)g(%d+)$")
    if not n then return nil end
    return (f == "f" and F_GLASSES or M_GLASSES)[tonumber(n)]
end
-- the same for watches ("w2"), which are the same for everybody
local function wk(i) return "w" .. tostring(i) end
local function watchOf(key)
    local n = tostring(key):match("^w(%d+)$")
    return n and WATCHES[tonumber(n)] or nil
end
-- Watches are EXPERIMENTAL ("Watches", coop/experimental.lua): without the switch there is
-- no WATCHES tab, nothing is worn and nothing is told to the others. What is owned stays.
local function watchesOn() return Core.experimental("Watches") end
local function watchCode()
    if not watchesOn() then return "" end
    local w = WATCHES[state.watch or 0]
    return w and w.code or ""
end
local function hatMesh()
    local h = (state.hat or 0) > 0 and S().hair[state.hat] or nil
    return h and h.price and h.mesh or ""
end
local function beardMesh()
    local b = state.gender == "m" and BEARDS[state.beard or 0] or nil
    return b and b.mesh or ""
end
-- The hairstyle the player has (the barber's work; "" for bald), and what is worn of it:
-- nothing while it is shaved off at a clothes shop (hairOff), else the style in its colour.
-- "MESH#MATERIAL" is the mesh in that hair colour (coop/avatar.lua).
local function styleMesh()
    local h = S().hair[state.hair]
    return h and not h.price and h.mesh or ""
end
local function naturalOf(meshName) return NATURAL[tostring(meshName or ""):match("[^/]*$") or ""] end
local function dressed(meshName, colour)
    if meshName == "" or not colour then return meshName end
    return meshName .. "#" .. colour
end
local function split(part)
    local m, c = tostring(part or ""):match("^([^#]*)#?(.*)$")
    return m or "", (c ~= nil and c ~= "") and c or nil
end
local function hairWorn()
    if state.hairOff then return "" end
    return dressed(styleMesh(), state.hairColour)
end
local function beardWorn()
    return dressed(beardMesh(), beardColourFor(state.hairColour or naturalOf(styleMesh())))
end
local function glassesMesh()
    local g = S().glasses[state.glasses or 0]
    return g and not g.gone and g.mesh or ""
end
local function hatOf(key)
    local f, n = tostring(key):match("^(f?)(%d+)$")
    if not n then return nil end
    return (f == "f" and F_HAIR or HAIR)[tonumber(n)]
end

---------------------------------------------------------------- the player's file

local function filePath()
    local base = os.getenv("LOCALAPPDATA")
    local dir = base and (base:gsub("\\", "/") .. "/DrugDealerSimulator/Saved/SaveGames") or Core.MOD_DIR
    return string.format("%s/ddsmp_player%s.json", dir, Core.instance and ("_" .. Core.instance) or "")
end

local function load()
    if loaded then return end
    loaded = true
    local f = io.open(filePath(), "rb")
    if not f then return end
    local text = f:read("a")
    f:close()
    local ok, data = pcall(json.decode, text)
    if not ok or type(data) ~= "table" then return end
    if SETS[data.gender] then state.gender = data.gender end
    if type(data.other) == "table" then state.other = data.other end
    if byId[data.outfit] and genderOf[data.outfit] == state.gender then state.outfit = data.outfit else state.outfit = S().default end
    if S().faces[tonumber(data.face) or 0] then state.face = tonumber(data.face) end
    if S().hair[tonumber(data.hair) or 0] then state.hair = tonumber(data.hair) end
    if type(data.ownedGlasses) == "table" then
        for id, v in pairs(data.ownedGlasses) do
            if glassesOf(id) and v == true then state.ownedGlasses[tostring(id)] = true end
        end
    end
    if BEARDS[tonumber(data.beard) or 0] then state.beard = tonumber(data.beard) end
    if type(data.hairColour) == "string" and hairColourListed[data.hairColour] then state.hairColour = data.hairColour end
    state.hairOff = data.hairOff == true
    local g = tonumber(data.glasses) or 0
    if S().glasses[g] and state.ownedGlasses[gk(g)] then state.glasses = g else state.glasses = 0 end
    if type(data.ownedWatches) == "table" then
        for id, v in pairs(data.ownedWatches) do
            if watchOf(id) and v == true then state.ownedWatches[tostring(id)] = true end
        end
    end
    local w = tonumber(data.watch) or 0
    if WATCHES[w] and state.ownedWatches[wk(w)] then state.watch = w else state.watch = 0 end
    local kind = FORMER[data.character] or data.character
    if characterById[kind] then state.character = kind end
    state.characterPicked = data.characterPicked == true
    state.roster = tonumber(data.roster) or 1
    state.forced = math.max(0, math.floor(tonumber(data.forced) or 0))
    if state.characterPicked and state.roster < ROSTER then
        -- (A test copy started with -ddsmp=NAME keeps its choice: nobody is there to answer.)
        if Core.instance and not Look.debug then state.roster = ROSTER else state.characterPicked = false end
    end
    if type(data.owned) == "table" then
        for id, v in pairs(data.owned) do
            if byId[id] and v == true then state.owned[id] = true end
        end
    end
    state.owned[state.outfit] = true
    if type(data.ownedHair) == "table" then
        for id, v in pairs(data.ownedHair) do
            if hatOf(id) and v == true then state.ownedHair[tostring(id)] = true end
        end
    end
    if S().hair[state.hair].price then
        state.ownedHair[hk(state.hair)] = true
        state.hat, state.hair = state.hair, firstHair()
    end
    local hat = tonumber(data.hat) or 0
    if hat > 0 and S().hair[hat] and S().hair[hat].price and state.ownedHair[hk(hat)] then state.hat = hat end
    if not S().hair[state.hat or 0] or not S().hair[state.hat].price then state.hat = 0 end
    -- What was bought before purchases went with the saves (this file kept them for every
    -- save at once): kept as it was then, for saves that do not say what they own yet.
    if type(data.legacy) == "table" then
        state.legacy = data.legacy
    else
        state.legacy = { owned = state.owned, hair = state.ownedHair, glasses = state.ownedGlasses }
    end
end

local function save()
    local ok, text = pcall(json.encode, state)
    if not ok then return end
    local f = io.open(filePath(), "wb")
    if not f then
        log("Cannot write %s", filePath())
        return
    end
    f:write(text)
    f:close()
end

-- The character is chosen anew on the next join (a guest who starts over in a world).
-- The lists of this world: the save's, or (a save of before) what was owned then; a new
-- game starts with nothing bought. What is worn and not owned is taken off.
local function applyOwned(record)
    local src = nil
    if type(record) == "table" and type(record.owned) == "table" then
        src = record
    elseif not Guests.newGame() then
        src = state.legacy
    end
    src = type(src) == "table" and src or {}
    state.owned, state.ownedHair, state.ownedGlasses, state.ownedWatches = {}, {}, {}, {}
    for id in pairs(copyTrue(src.owned)) do if byId[id] then state.owned[id] = true end end
    for id in pairs(copyTrue(src.hair)) do if hatOf(id) then state.ownedHair[id] = true end end
    for id in pairs(copyTrue(src.glasses)) do if glassesOf(id) then state.ownedGlasses[id] = true end end
    for id in pairs(copyTrue(src.watches)) do if watchOf(id) then state.ownedWatches[id] = true end end
    if not (byId[state.outfit] and byId[state.outfit].starter) and not state.owned[state.outfit] then state.outfit = S().default end
    if (state.hat or 0) > 0 and not state.ownedHair[hk(state.hat)] then state.hat = 0 end
    if (state.glasses or 0) > 0 and not state.ownedGlasses[gk(state.glasses)] then state.glasses = 0 end
    if (state.watch or 0) > 0 and not state.ownedWatches[wk(state.watch)] then state.watch = 0 end
end

-- The choice and what is owned, to go with the save (and, for a guest, to the host).
local function syncSelf()
    Guests.setSelf({ character = state.character, owned = copyTrue(state.owned), hair = copyTrue(state.ownedHair), glasses = copyTrue(state.ownedGlasses), watches = copyTrue(state.ownedWatches) })
end

function Look.startOver()
    load()
    state.characterPicked = false
    save()
end

---------------------------------------------------------------- how the others see us

function Look.current()
    load()
    return { body = byId[state.outfit].body, head = S().faces[state.face], hair = hairWorn(), hat = hatMesh(), glasses = glassesMesh(), beard = beardWorn(), watch = watchCode(), arms = true }
end

local function describe(owner)
    local l = Look.current()
    local hair, hairColour = split(l.hair)
    local beard, beardColour = split(l.beard)
    -- (the colours in fields of their own: a game of an older version reads the meshes as it
    -- always did and shows them in the colour they come in)
    -- (wt: the watch, "" for none; a game of before the watches does not read it)
    return { b = l.body, h = l.head, r = hair, c = l.hat, g = l.glasses, w = beard, hc = hairColour, bc = beardColour, wt = l.watch, p = owner }
end

-- Tells the other players in the world how we look.
function Look.announce(target)
    if not World.shared() then return end
    local data = describe(nil)
    if target then
        Net.send("look", data, target)
    else
        for _, id in ipairs(World.targets()) do Net.send("look", data, id) end
    end
end

Net.on("look", function(sender, data)
    if not World.active then return end
    if World.role == "host" and not World.inWorld[sender] then return end
    if World.role == "guest" and sender ~= Net.S.owner then return end
    -- A guest hears about the other guests through the host.
    local who = sender
    if World.role == "guest" and data.p ~= nil then who = data.p end
    if who == Net.S.me then return end
    local body, head, hair, glasses = tostring(data.b), tostring(data.h), tostring(data.r or ""), tostring(data.g or "")
    local beard, hat = tostring(data.w or ""), tostring(data.c or "")
    if not bodyAllowed[body] or not faceAllowed[head] or not hairAllowed[hair] or not glassesAllowed[glasses] or not beardAllowed[beard] or not hairAllowed[hat] then return end
    local hairColour = type(data.hc) == "string" and hairColourAllowed[data.hc] and data.hc or nil
    local beardColour = type(data.bc) == "string" and hairColourAllowed[data.bc] and data.bc or nil
    local watch = type(data.wt) == "string" and watchAllowed[data.wt] and data.wt or ""
    Avatar.setLook(who, { body = "" .. body, head = head, hair = dressed(hair, hairColour), hat = hat, glasses = glasses, beard = dressed(beard, beardColour), watch = watch, arms = true })
    vlog("Look: %s wears %s", Net.name(who), body)
    if World.role == "host" then
        for id in pairs(World.inWorld) do
            if id ~= sender then Net.send("look", { b = body, h = head, r = hair, c = hat, g = glasses, w = beard, hc = hairColour, bc = beardColour, wt = watch, p = sender }, id) end
        end
    end
end)

---------------------------------------------------------------- character traits

local function character()
    load()
    return characterById[state.character] or CHARACTERS[1]
end

Look.character = character

local function afterSkills(player)
    local c = character()
    local seen = c.seen
    -- coop/traits.lua: more visible for a while (a drug is working)
    if Look.seenNow then
        local ok, factor = pcall(Look.seenNow, c)
        if ok and type(factor) == "number" then seen = seen * factor end
    end
    pcall(function() player.skillStealthMultiplier = player.skillStealthMultiplier * seen end)
end

-- The highest pocket that holds something (-1: all are empty).
local function highestPocket(player)
    local top = -1
    pcall(function()
        player.InventoryComponent.ItemPocketIndex:ForEach(function(_, v)
            local i = tonumber(v:get())
            if i and i > top then top = i end
        end)
    end)
    return top
end

-- How many pockets the character starts from. A kind with fewer pockets does not make
-- anything disappear: the game simply stops showing a pocket that is beyond the count,
-- with what is in it. So a pocket that would go stays for as long as something is in it.
-- Returns the number and how many of them are only there for that reason.
local function pocketBase(player, defaults, c)
    local want = defaults.basePocketCount + c.pockets
    local fromSkill = 0
    pcall(function() fromSkill = math.floor(Core.find("statisticsManager_C").skillLevelPockets / 25 + 0.5) end)
    local need = math.min(highestPocket(player) + 1 - fromSkill, defaults.basePocketCount + 1)
    if need > want then return need, need - want end
    return want, 0
end

Look.pocketsKept = 0

-- Sets the character's base values from the game's defaults and lets the game work out
-- the rest (skills add to these as usual).
function Look.applyTraits()
    local player = World.player()
    if not player then return false end
    local defaults = StaticFindObject("/Game/Player/playerCharacterBP.Default__playerCharacterBP_C")
    if not valid(defaults) then return false end
    local c = character()
    local ok, e = pcall(function()
        player.staminaMaxBase = defaults.staminaMaxBase * c.stamina
        player.baseMaxWalkSpeed = defaults.baseMaxWalkSpeed * c.speed
        player.basePocketCount, Look.pocketsKept = pocketBase(player, defaults, c)
        applyingTraits = true
        player:updateSkillAbilities()
        applyingTraits = false
        afterSkills(player)
    end)
    applyingTraits = false
    if not ok then log("Character traits could not be applied: %s", tostring(e)) end
    return ok
end

-- The game recalculates when a skill is bought; our share goes back on top.
Core.Hooks.add("/Game/Player/playerCharacterBP.playerCharacterBP_C:updateSkillAbilities", function(ctx)
    if applyingTraits then return end
    local player = ctx:get()
    if valid(player) then afterSkills(player) end
end)

---------------------------------------------------------------- the shop

local function bank()
    local computer = Core.find("mainComputer_C")
    local ok, money = pcall(function() return computer.playerBankMoney end)
    if ok and type(money) == "number" then return money, computer end
    return 0, nil
end

local function pay(price)
    if price <= 0 then return true end
    local money, computer = bank()
    if not computer or money < price then return false end
    computer.playerBankMoney = money - price
    pcall(function() if valid(computer.interface) then computer.interface:UpdateDesktop() end end)
    return true
end

-- The clothes shops: Marco's corner at Donald's (coop/clerk.lua) and the formal store
-- (coop/boutique.lua, when it is there). Each has a shopkeeper to talk to, a place the
-- player looks on from (VIEWPOINT) and a place the figure dressed like them stands (FITTING).
local boutiqueModule = false
local function boutique()
    if boutiqueModule == false then
        local ok, b = pcall(require, "coop.boutique")
        boutiqueModule = ok and type(b) == "table" and b or nil
        if boutiqueModule then
            boutiqueModule.wanted = function() return World.extras() end
            boutiqueModule.onShow = function() Look.openShop(boutiqueModule) end
        end
    end
    return boutiqueModule
end
local barberModule = false
local function barber()
    if barberModule == false then
        local ok, b = pcall(require, "coop.barber")
        barberModule = ok and type(b) == "table" and b or nil
        if barberModule then
            barberModule.wanted = function() return World.extras() end
            barberModule.onShow = function() Look.openShop(barberModule) end
        end
    end
    return barberModule
end
local function storeNear()
    if Clerk.near() then return Clerk end
    local b = boutique()
    if b and b.near() then return b end
    b = barber()
    if b and b.near() then return b end
    return nil
end
Look.store = Clerk

-- In the shop whose screen is (to be) open.
function Look.atShop(store) return (store or Look.store or Clerk).distance() < 520 end

-- Where the figure stands while the shop screen is open.
Look.fitting = Clerk.FITTING

-- The panel covers the left part of the picture; the figure is shown in the middle of
-- what is left.
local PANEL_W, LEFT = 0.68, 0.027
local FIGURE_X = (PANEL_W + 1) / 2

-- The player's eye, and what half the picture's width and height are at distance 1. The
-- eye is taken from where the player stands, not from the camera: right after a dialogue
-- the camera is still on its way back.
local EYE_HEIGHT, CAMERA_FORWARD = 86, 10
-- The field of view is the player's own setting. It is read while nothing else has the
-- camera (a dialogue zooms in).
local seenFov = 90
local fovNow = nil       -- the field of view a store has set while its screen is open (the barber: a close-up)
Core.every(1.5, function()
    local player = World.player()
    if not player or Screen.current then return end
    pcall(function()
        if player.inDialogue == true then return end
        local fov = player:GetController().PlayerCameraManager:GetFOVAngle()
        if fov and fov >= 50 and fov <= 140 then seenFov = fov end
    end)
end)
local function view()
    local player = World.player()
    local at = player:K2_GetActorLocation()
    local _, _, w, h = Look.mouse()
    local tx = math.tan(math.rad((fovNow or seenFov) / 2))
    return { X = at.X, Y = at.Y, Z = at.Z + EYE_HEIGHT }, tx, tx * (h or 9) / (w or 16)
end

-- Next to the clothes shopkeeper.
function Look.atClerk() return storeNear() ~= nil end
Clerk.wanted = function() return World.extras() end

-- A marker on the map, like the game's own shop markers.
local shopMarker = nil
local function ensureMarker()
    if shopMarker and Core.alive(shopMarker) then return end
    -- A little north of the furniture shop's own marker, so that the two names can be read.
    shopMarker = Hud.mapMarker("Marco's Clothing", "Outfits and hats", SHOP.x + 650, SHOP.y, SHOP.z, Hud.MARKER_SHOP)
end

-- The game is first-person, so both screens show the player as a figure dressed like them,
-- standing to the right of the panel and turning slowly.
local mirror, mirrorKey, mirrorAt = nil, nil, nil
-- what is being tried on in the shop, any of { body, hair, glasses } at once (nil: nothing)
local preview = nil
local function tryOn(slot, value)
    preview = preview or {}
    preview[slot] = value
end
local function takeOff(slot)
    if not preview then return end
    preview[slot] = nil
    if next(preview) == nil then preview = nil end
end

local function shownLook()
    local l = Look.current()
    if preview then
        if preview.body then l.body = preview.body end
        if preview.hair ~= nil then l.hair = preview.hair end
        if preview.hat ~= nil then l.hat = preview.hat end
        if preview.glasses ~= nil then l.glasses = preview.glasses end
        if preview.watch ~= nil then l.watch = preview.watch end
        if preview.beard ~= nil then l.beard = preview.beard end
    end
    return l
end

local function removeMirror()
    if mirror then Avatar.destroyStandIn(mirror) end
    mirror, mirrorKey, mirrorAt = nil, nil, nil
end

-- The figure turns slowly by itself. Holding the left mouse button on it (the part of the
-- screen right of the panel) stops it, and dragging turns it by hand; a few seconds after
-- the button is let go it turns by itself again.
local SPIN = 12              -- degrees per second
local DRAG = 0.45            -- degrees per pixel dragged
local RESUME = 4             -- seconds after letting go
local spin = { yaw = 0, at = nil, grabbed = false, wasDown = false, lastX = nil, resumeAt = 0 }
Look.spin = spin

local function mouse()
    local player = World.player()
    local pc = player and player:GetController()
    if not pc then return nil end
    local x, y, w, h = {}, {}, {}, {}
    pc:GetMousePosition(x, y)
    pc:GetViewportSize(w, h)
    local down = pc:IsInputKeyDown({ KeyName = FName("LeftMouseButton") }) == true
    return tonumber(x.LocationX), tonumber(y.LocationY), tonumber(w.SizeX), tonumber(h.SizeY), down
end
Look.mouse = mouse

Core.onTick(function()
    if not mirror or not mirrorAt then
        spin.at, spin.grabbed, spin.wasDown = nil, false, false
        return
    end
    local now = os.clock()
    local step = math.min(0.1, now - (spin.at or now))
    spin.at = now
    local ok, x, _, w, _, down = pcall(mouse)
    if ok and x and w and w > 0 then
        if down and not spin.wasDown then spin.grabbed = x / w > 0.69 end
        if not down then
            if spin.grabbed then spin.resumeAt = now + RESUME end
            spin.grabbed = false
        end
        if spin.grabbed and spin.lastX then spin.yaw = spin.yaw - (x - spin.lastX) * DRAG end
        spin.wasDown, spin.lastX = down, x
    end
    if spin.force then spin.yaw, spin.resumeAt = spin.force, now + 1 end     -- tests
    if not spin.grabbed and now >= spin.resumeAt then spin.yaw = spin.yaw + SPIN * step end
    spin.yaw = spin.yaw % 360
    pcall(Avatar.moveStandIn, mirror, mirrorAt.x, mirrorAt.y, mirrorAt.z, mirrorAt.facing + spin.yaw)
end)

local function showMirror()
    local player = World.player()
    if not player then return end
    local l = shownLook()
    local key = l.body .. "|" .. l.head .. "|" .. l.hair .. "|" .. tostring(l.hat) .. "|" .. tostring(l.glasses) .. "|" .. tostring(l.beard) .. "|" .. tostring(l.watch)
    local loc = player:K2_GetActorLocation()
    local yaw = player:K2_GetActorRotation().Yaw
    pcall(function() yaw = player:GetControlRotation().Yaw end)
    local r = math.rad(yaw)
    local x, y, facing, size
    local spot = (Look.page == "shop" or Look.page == "wardrobe" or Look.page == "barber") and Look.fitting or nil
    if spot then
        -- In the shop the figure stands full size on the floor in front of the rack, like
        -- somebody trying the clothes on; the player has been turned to it. (At the wardrobe
        -- the same; where the room is small nearer and as much smaller: Look.openWardrobe.)
        x, y, loc.Z, size = spot.x, spot.y, spot.z, spot.size or 1
        facing = math.deg(math.atan(loc.Y - y, loc.X - x))
    else
        -- Half size and close by (a wall or a lamp post further off cannot hide it), in
        -- the middle of the part of the picture the panel leaves free, between the bar at
        -- the top and the button at the bottom.
        local eye, tx, ty = loc, 1, 0.5625
        local ok, e, a, b = pcall(view)
        if ok and e then eye, tx, ty = e, a, b end
        local F = 125
        local right = (2 * FIGURE_X - 1) * tx * F
        -- (on the "who are you" screen a little lower: the MALE | FEMALE switch is above it)
        local up = (1 - 2 * (Look.page == "start" and 0.57 or 0.475)) * ty * F
        -- (the camera is a little in front of where the player stands)
        x = eye.X + math.cos(r) * (F + CAMERA_FORWARD) - math.sin(r) * right
        y = eye.Y + math.sin(r) * (F + CAMERA_FORWARD) + math.cos(r) * right
        facing = math.deg(math.atan(eye.Y - y, eye.X - x))
        size = 0.5 * F / 125
        loc.Z = (ok and e) and (eye.Z + up + 45 * F / 125) or (loc.Z + 100)       -- a half-size figure's middle is 45 below this
    end
    local since = mirrorAt and mirrorAt.since or os.clock()
    if mirror and mirrorKey == key and valid(mirror.body) then
        mirrorAt = { x = x, y = y, z = loc.Z, facing = facing, since = since }
        return
    end
    removeMirror()
    mirror = Avatar.buildStandIn(l, x, y, loc.Z, facing, nil)
    if mirror then pcall(function() mirror.body:SetActorScale3D({ X = size, Y = size, Z = size }) end) end
    mirrorKey = key
    mirrorAt = { x = x, y = y, z = loc.Z, facing = facing, since = since }
    -- Light of its own from above and a little in front, so that it can be seen at night
    -- and in dark rooms. It reaches the figure only (Avatar.lightFromAbove): the room stays
    -- as it is. (All of it is in this game only, like the figure.)
    if mirror then
        local toX, toY = loc.X - x, loc.Y - y
        local n = math.max(1, math.sqrt(toX * toX + toY * toY))
        pcall(Avatar.lightFromAbove, mirror, x + toX / n * 70 * size, y + toY / n * 70 * size, loc.Z + 150 * size, 420 * size, 6000)
        -- at the barber's (a dim room, and the face is what is looked at) a lamp in front of
        -- the figure at the height of the face, there while the screen is open
        if Look.page == "barber" then
            pcall(Avatar.lamp, mirror, x + toX / n * 125 * size, y + toY / n * 125 * size - 40, loc.Z + 70 * size, 420 * size, 4000)
        end
    end
end

---------------------------------------------------------------- the two screens

local function key(name) return tostring(Core.config[name] or "?") end

local PANEL = { R = 0.006, G = 0.006, B = 0.006, A = 0.95 }
local BAR_COLOR = { R = 0, G = 0, B = 0, A = 1 }
local CARD = { R = 0.0, G = 0.0, B = 0.0, A = 1 }
local SWITCH_ON = { R = 0.36, G = 0.78, B = 0.45, A = 1 }
local SWITCH_OFF = { R = 0.03, G = 0.03, B = 0.03, A = 1 }
local SWITCH_TEXT_ON = { R = 0.0, G = 0.0, B = 0.0, A = 1 }
local SWITCH_EDGE = { R = 0.25, G = 0.25, B = 0.25, A = 1 }
local FRAME_ON = { R = 0.10, G = 0.62, B = 0.18, A = 1 }

local scr = nil          -- the open screen
local pose = nil         -- where the player is held while it is open: { x, y, z, yaw, back }
-- The player stays where they are, looking level, while a screen is open.
local function hold(pitch)
    local player = World.player()
    if not player then return end
    local l = player:K2_GetActorLocation()
    local yaw = player:K2_GetActorRotation().Yaw
    pcall(function() yaw = player:GetControlRotation().Yaw end)
    pose = { x = l.X, y = l.Y, z = l.Z, yaw = yaw, pitch = pitch or 0, owner = player:GetAddress() }
    -- the game's own HUD (hints, compass) is put away while a screen is open
    pcall(function()
        pose.hud = player.HUD.Visibility
        player.HUD:SetVisibility(1)
    end)
    pcall(function() player:GetController():SetControlRotation({ Pitch = pose.pitch, Yaw = yaw, Roll = 0 }) end)
end

local function release()
    local p = pose
    pose = nil
    if Look.store and Look.store.solid then pcall(Look.store.solid, true) end
    local player = World.player()
    if fovNow then
        fovNow = nil
        -- back to what the game itself would set (its own setting, a drug, a dialogue's zoom)
        if player then
            pcall(function() player.Camera:SetFieldOfView(player.baseFOV * player.duaFovTarget * player.camFocusFovMultiplier) end)
        end
    end
    if p and player and player:GetAddress() == p.owner then
        pcall(function() player.HUD:SetVisibility(p.hud or 4) end)
    end
    if p and p.lowered and player and player:GetAddress() == p.owner then
        pcall(function()
            player:SetActorEnableCollision(true)
            player.CharacterMovement:SetMovementMode(1, 0)
        end)
    end
    if p and p.back and player and player:GetAddress() == p.owner then
        pcall(function() player:K2_SetActorLocation({ X = p.back.x, Y = p.back.y, Z = p.back.z }, false, {}, true) end)
    end
end

Core.onTick(function()
    if not pose then return end
    local player = World.player()
    if not player or player:GetAddress() ~= pose.owner then
        pose = nil
        return
    end
    pcall(function()
        local l = player:K2_GetActorLocation()
        if math.abs(l.X - pose.x) > 3 or math.abs(l.Y - pose.y) > 3 then
            player:K2_SetActorLocation({ X = pose.x, Y = pose.y, Z = l.Z }, false, {}, true)
        end
        player:GetController():SetControlRotation({ Pitch = pose.pitch or 0, Yaw = pose.yaw, Roll = 0 })
        -- (the game sets the camera's field of view itself now and then: a drug wearing off)
        if fovNow and math.abs(player.Camera.FieldOfView - fovNow) > 0.5 then player.Camera:SetFieldOfView(fovNow) end
    end)
end)
local drawn = {}         -- what the current picture consists of
local shopTab = "all"

local function wipe()
    if scr then
        scr.removeAll(drawn)
    end
    drawn = {}
end

local function put(widget, ax, ay, x, y, alignX, alignY)
    scr.place(widget, ax, ay, x, y, alignX, alignY)
    drawn[#drawn + 1] = widget
    return widget
end

local function closeScreen()
    local s = scr
    scr, drawn = nil, {}
    Look.page = nil
    preview = nil
    removeMirror()
    release()
    if s then
        s.onClose = nil
        pcall(s.close)
    end
end

local function frame(title)
    scr = Screen.open()
    if not scr then return false end
    scr.onClose = function()
        scr, drawn = nil, {}
        Look.page = nil
        preview = nil
        removeMirror()
        release()
    end
    scr.area(scr.box(PANEL), 0, 0, PANEL_W, 1)
    scr.quickLeft = PANEL_W            -- short messages: right of the panel (coop/hud.lua)
    scr.area(scr.box(BAR_COLOR), 0, 0, 1, 0.1)
    scr.place(scr.text(title, "name", 26), LEFT, 0.05, 0, 0, 0, 0.5)
    return true
end

-- One card of a grid, top to bottom: a picture, a price or note (right), a name, lines of
-- small text (a string, or { text, colour }), one or two buttons ({ label, onClick,
-- disabled, colour } each). Any part may be left out.
-- `onClick`: what a click anywhere else on the card does (the card's buttons stay theirs).
local SELF_HIT_INVISIBLE, HIT_INVISIBLE = 4, 3
local function tile(w, h, name, lines, corner, cornerColor, buttons, on, picture, pictureGap, onClick, clickLabel)
    local column = scr.new("VerticalBox")
    local function row(widget, top, align, bottom)
        local slot = column:AddChildToVerticalBox(widget)
        slot:SetPadding({ Left = 0, Top = top or 0, Right = 0, Bottom = bottom or 0 })
        slot:SetHorizontalAlignment(align or 2)
        return slot
    end
    if corner then row(scr.text(corner, "price", 16, cornerColor or Screen.GREEN), 0, 3) end
    if picture then
        pcall(function() picture:SetVisibility(HIT_INVISIBLE) end)
        row(picture, pictureGap or 0, 2, pictureGap or 0)
    end
    if name then row(scr.text(name, "name", 15), 8) end
    for _, line in ipairs(lines or {}) do
        if type(line) == "table" then
            row(scr.text(line[1], "button", 13, line[2] or Screen.GREY), 3)
        else
            row(scr.text(line, "small", 11, Screen.GREY), 4)
        end
    end
    local line = scr.new("HorizontalBox")
    for n, def in ipairs(buttons or {}) do
        local b = scr.button(def[1], 1.0, def[2])
        if def[3] then scr.enable(b, false) end
        if def[4] then scr.tint(b, def[4]) end
        local slot = line:AddChildToHorizontalBox(b.widget)
        slot:SetPadding({ Left = n > 1 and 6 or 0, Top = 0, Right = 0, Bottom = 0 })
    end
    row(line, 10)
    local face = scr.box(CARD, column)
    face:SetPadding({ Left = 8, Top = 6, Right = 8, Bottom = 8 })
    -- The one in use has a green frame. The others have the same frame in the card's own
    -- colour, so that every card is laid out alike and the pictures (black) sit on black.
    local card = scr.sized(scr.box(on and FRAME_ON or CARD, face, 2), w, h)
    if not onClick then return card end
    -- what is drawn lets clicks through to the invisible button underneath, except the
    -- card's own buttons
    for _, wd in ipairs({ column, line, face, card, card:GetChildAt(0) }) do
        pcall(function() wd:SetVisibility(SELF_HIT_INVISIBLE) end)
    end
    local hit = scr.hit(clickLabel or name or "card", onClick)
    local stack = scr.new("Overlay")
    stack:AddChildToOverlay(scr.sized(hit.widget, w, h))
    stack:AddChildToOverlay(card)
    return stack
end

local function texture(path)
    local o = StaticFindObject(path)
    if valid(o) then return o end
    pcall(function() o = LoadAsset(path) end)
    if valid(o) then return o end
    return nil
end

-- The game's own pictograms, one per kind of character.
local ICONS = {
    hustler = { "/Game/GUI/Phone/newIncomeIcon.newIncomeIcon" },
    runner = { "/Game/GUI/shadyComm/Remastered/areaMarkerIcon.areaMarkerIcon", angle = -90 },
    ghost = { "/Game/GUI/WorldMap/mapMarkerClient.mapMarkerClient", opacity = 0.3 },      -- a figure, barely there
    tagger = { "/Game/TerritorySpraying/sprayPaint_Icon.sprayPaint_Icon" },
    lightweight = { "/Game/GUI/shadyComm/addictionIcon.addictionIcon" },
    crook = { "/Game/GUI/shadyComm/Remastered/lockedIcon.lockedIcon" },
}

local function icon(id, size)
    local def = ICONS[id]
    local tex = def and texture(def[1])
    if not tex then return nil end
    local img = scr.new("Image")
    pcall(function() img:SetBrushFromTexture(tex, false) end)
    if def.angle then pcall(function() img:SetRenderTransformAngle(def.angle) end) end
    if def.opacity then pcall(function() img:SetRenderOpacity(def.opacity) end) end
    return scr.sized(img, size, size)
end

-- What a kind of character is better and worse at: green for the one, red for the other.
local function traitLines(c)
    local out = {}
    local function pct(v) return math.floor(math.abs(v - 1) * 100 + 0.5) end
    local function add(v, label)
        if v ~= 1 then out[#out + 1] = { string.format("%s%d%% %s", v > 1 and "+" or "-", pct(v), label), v > 1 and Screen.GREEN or Screen.RED } end
    end
    add(c.stamina, "STAMINA")
    add(c.speed, "SPEED")
    if c.seen ~= 1 then
        out[#out + 1] = { string.format("%d%% %s TO SPOT", pct(c.seen), c.seen < 1 and "HARDER" or "EASIER"), c.seen < 1 and Screen.GREEN or Screen.RED }
    end
    local function times(v) return (string.format("%.1f", v):gsub("%.0$", "")) end
    if c.tagTime and c.tagTime ~= 1 then
        out[#out + 1] = c.tagTime < 1 and { "TAGS " .. times(1 / c.tagTime) .. "X FASTER", Screen.GREEN } or { "TAGS " .. times(c.tagTime) .. "X SLOWER", Screen.RED }
    end
    if c.pockets ~= 0 then out[#out + 1] = { string.format("%+d POCKET", c.pockets), c.pockets > 0 and Screen.GREEN or Screen.RED } end
    if c.drugTime and c.drugTime ~= 1 then out[#out + 1] = { "DRUGS LAST " .. times(c.drugTime) .. "X", c.drugTime > 1 and Screen.GREEN or Screen.RED } end
    if c.seenHigh and c.seenHigh ~= 1 then out[#out + 1] = { (c.seenHigh > 1 and "EASIER" or "HARDER") .. " TO SPOT WHILE HIGH", c.seenHigh > 1 and Screen.RED or Screen.GREEN } end
    if c.freePick then out[#out + 1] = { "NO LOCKPICK MINIGAME", Screen.GREEN } end
    if c.pickHeat then out[#out + 1] = { "FORCED DOORS ADD HEAT", Screen.RED } end
    if #out == 0 then out[1] = { "BALANCED", Screen.GREY } end
    while #out < 3 do out[#out + 1] = { " ", Screen.GREY } end
    return out
end

---------------------------------------------------------------- who are you (once)

local renderStart

-- Everything on the panel is one column: a heading, a row of cards, a heading, a row...
-- Every row is as wide as the panel between its margins, whatever the shape of the
-- window: its cards share that width equally, with the same gap between them, and the
-- distances between the rows are the same.
local GAP = 12
local BUTTON_INSET = 10.5        -- the empty room at either side of the game's button

renderStart = function()
    if not scr then return end
    wipe()
    local U = scr.units()
    local width = (PANEL_W - 2 * LEFT) * U
    local look = Look.current()
    local panel = scr.new("VerticalBox")
    local function heading(str, top)
        local slot = panel:AddChildToVerticalBox(scr.text(str, "button", 16, Screen.GREY))
        slot:SetPadding({ Left = 0, Top = top, Right = 0, Bottom = 8 })
    end
    local function row(count, height, make)
        local line = scr.new("HorizontalBox")
        local w = math.floor((width - (count - 1) * GAP) / count)
        for i = 1, count do
            local slot = line:AddChildToHorizontalBox(make(i, w, height))
            slot:SetPadding({ Left = i > 1 and GAP or 0, Top = 0, Right = 0, Bottom = 0 })
        end
        panel:AddChildToVerticalBox(line)
    end

    heading("CHARACTER", 0)
    row(#CHARACTERS, 208, function(i, w, h)
        local c = CHARACTERS[i]
        local on = c.id == state.character
        local pick = function()
            state.character = c.id
            renderStart()
        end
        return tile(w, h, c.name:upper(), traitLines(c), nil, nil, { { on and "SELECTED" or "SELECT", pick, false, on and Screen.GREEN or nil } },
            on, icon(c.id, 50), 2, pick, c.id)
    end)

    local starters = {}
    for _, o in ipairs(S().outfits) do if o.starter then starters[#starters + 1] = o end end
    heading("OUTFIT", 24)
    row(#starters, 232, function(i, w, h)
        local o = starters[i]
        local on = o.id == state.outfit
        local pic = Thumbs.image(scr, "b|" .. o.body .. "|" .. look.head, { look = { body = o.body, head = look.head, hair = look.hair, arms = true }, shot = "body" }, 100, 150)
        local pick = function()
            state.outfit = o.id
            renderStart()
        end
        return tile(w, h, o.name, nil, nil, nil, { { on and "WEARING" or "WEAR", pick, false, on and Screen.GREEN or nil } }, on, pic, nil, pick, o.id)
    end)

    local faces = S().faces
    local men = state.gender == "m"
    if men then
        -- FACE over the faces, BEARD over the two beards: cards as wide as the hair cards
        local count = #faces + #BEARDS
        local cw = math.floor((width - (count - 1) * GAP) / count)
        local line = scr.new("HorizontalBox")
        line:AddChildToHorizontalBox(scr.sized(scr.text("FACE", "button", 16, Screen.GREY), #faces * (cw + GAP), nil))
        line:AddChildToHorizontalBox(scr.text("BEARD", "button", 16, Screen.GREY))
        local slot = panel:AddChildToVerticalBox(line)
        slot:SetPadding({ Left = 0, Top = 24, Right = 0, Bottom = 8 })
        row(count, 140, function(i, w, h)
            if i > #faces then
                local n = i - #faces
                local b = BEARDS[n]
                local on = state.beard == n
                local beard = dressed(b.mesh, beardColourFor(state.hairColour or naturalOf(styleMesh())))
                local pic = Thumbs.image(scr, "w|" .. beard .. "|" .. look.head .. "|" .. look.hair, { look = { body = look.body, head = look.head, hair = look.hair, beard = beard, arms = true }, shot = "face" }, 84, 84)
                local pick = function()
                    state.beard = on and 0 or n       -- the chosen one again: no beard
                    renderStart()
                end
                return tile(w, h, nil, nil, nil, nil, { { b.name:upper(), pick, false, on and Screen.GREEN or nil } }, on, pic, nil, pick, "beard" .. n)
            end
            local on = i == state.face
            local pic = Thumbs.image(scr, "f|" .. faces[i] .. "|" .. look.hair, { look = { body = look.body, head = faces[i], hair = look.hair, arms = true }, shot = "face" }, 84, 84)
            local pick = function()
                state.face = i
                renderStart()
            end
            return tile(w, h, nil, nil, nil, nil, { { "FACE " .. i, pick, false, on and Screen.GREEN or nil } }, on, pic, nil, pick, "face" .. i)
        end)
    end
    if not men then heading("FACE", 24) end
    if not men then row(#faces, 140, function(i, w, h)
        local on = i == state.face
        local pic = Thumbs.image(scr, "f|" .. faces[i] .. "|" .. look.hair, { look = { body = look.body, head = faces[i], hair = look.hair, arms = true }, shot = "face" }, 84, 84)
        local pick = function()
            state.face = i
            renderStart()
        end
        return tile(w, h, nil, nil, nil, nil, { { "FACE " .. i, pick, false, on and Screen.GREEN or nil } }, on, pic, nil, pick, "face" .. i)
    end) end

    local free = {}
    local hairs = S().hair
    for i, h in ipairs(hairs) do if not h.price and h.mesh == "" then free[#free + 1] = i end end
    for i, h in ipairs(hairs) do if not h.price and not h.barber and h.mesh ~= "" then free[#free + 1] = i end end
    heading("HAIR", 24)
    row(#free, 140, function(n, w, h)
        local i = free[n]
        local hair = hairs[i]
        local on = i == state.hair
        local pic = Thumbs.image(scr, "h|" .. hair.mesh .. "|" .. look.head, { look = { body = look.body, head = look.head, hair = hair.mesh, arms = true }, shot = "hair" }, 84, 84)
        local pick = function()
            -- (a first choice, or a new start: the style as it comes, nothing dyed or shaved)
            state.hair, state.hairOff, state.hairColour = i, false, nil
            renderStart()
        end
        return tile(w, h, nil, nil, nil, nil, { { hair.name:upper(), pick, false, on and Screen.GREEN or nil } }, on, pic, nil, pick, "hair" .. i)
    end)
    put(panel, LEFT, 0.1, 0, 24, 0, 0)

    local start = scr.bigButton("START AS " .. character().name:upper(), 1.7, function()
        state.characterPicked = true
        state.roster = ROSTER
        -- the choice belongs to this save (a guest: to this player in the host's world)
        syncSelf()
        state.owned[state.outfit] = true
        save()
        Look.applyTraits()
        Look.announce()
        closeScreen()
        Hud.toast("You are " .. character().name, 4)
    end)
    put(start.box, FIGURE_X, 0.9)

    -- MALE | FEMALE above the figure: the selected half green
    local switch = scr.new("HorizontalBox")
    local SW, SH = 160, 44
    for n, def in ipairs({ { "m", "MALE" }, { "f", "FEMALE" } }) do
        local on = state.gender == def[1]
        local words = scr.text(def[2], "button", 18, on and SWITCH_TEXT_ON or Screen.WHITE)
        local inner = scr.new("SizeBox")
        inner:SetWidthOverride(SW)
        inner:SetHeightOverride(SH)
        local slot = inner:AddChild(words)
        pcall(function()
            slot:SetHorizontalAlignment(2)
            slot:SetVerticalAlignment(2)
        end)
        local face = scr.box(on and SWITCH_ON or SWITCH_OFF, inner, 0)
        local cell = face
        if not on then
            pcall(function()
                face:SetVisibility(4)
                inner:SetVisibility(4)
            end)
            local hit = scr.hit(def[2], function() Look.setGender(def[1]) end)
            cell = scr.new("Overlay")
            cell:AddChildToOverlay(scr.sized(hit.widget, SW, SH))
            cell:AddChildToOverlay(face)
        end
        switch:AddChildToHorizontalBox(cell):SetPadding({ Left = n > 1 and 2 or 0, Top = 0, Right = 0, Bottom = 0 })
    end
    -- (below the game's own warning banner, which can stand at the top right)
    put(scr.box(SWITCH_EDGE, switch, 2), FIGURE_X, 0.225)
    pcall(showMirror)
end

-- The other gender on the "who are you" screen: its lists, and what was chosen there before.
function Look.setGender(g)
    if not SETS[g] or g == state.gender then return end
    state.other[state.gender] = { outfit = state.outfit, face = state.face, hair = state.hair, hat = state.hat, glasses = state.glasses }
    state.gender = g
    local back = type(state.other[g]) == "table" and state.other[g] or {}
    state.outfit = (byId[back.outfit] and genderOf[back.outfit] == g) and back.outfit or S().default
    state.face = S().faces[tonumber(back.face) or 0] and tonumber(back.face) or 1
    state.hair = S().hair[tonumber(back.hair) or 0] and tonumber(back.hair) or firstHair()
    if S().hair[state.hair].price or S().hair[state.hair].barber then state.hair = firstHair() end
    state.hairOff, state.hairColour = false, nil
    local hat = tonumber(back.hat) or 0
    state.hat = (S().hair[hat] and S().hair[hat].price and state.ownedHair[hk(hat)]) and hat or 0
    if not byId[state.outfit].starter and not state.owned[state.outfit] then state.outfit = S().default end
    local g = tonumber(back.glasses) or 0
    state.glasses = (S().glasses[g] and state.ownedGlasses[gk(g)]) and g or 0
    if Look.page == "start" then renderStart() end
end

-- A screen that was taken away with its world (a load, the main menu) is forgotten
-- without touching it.
local function stale()
    if scr and Screen.current ~= scr then
        scr, drawn, pose = nil, {}, nil
        Look.page, preview = nil, nil
        mirror, mirrorKey, mirrorAt = nil, nil, nil
    end
end

function Look.openStart()
    stale()
    if scr or not World.player() then return false end
    load()
    if S().hair[state.hair] and (S().hair[state.hair].price or S().hair[state.hair].barber) then state.hair = firstHair() end
    if not byId[state.outfit].starter and not state.owned[state.outfit] then state.outfit = S().default end
    -- (a new character: every style as it comes, nothing dyed or shaved; the beard goes by
    -- the colour of the style that is chosen)
    state.hairOff, state.hairColour = false, nil
    if not frame("WHO ARE YOU?") then return false end
    hold()
    Look.page = "start"
    renderStart()
    return true
end

---------------------------------------------------------------- the clothes shop

local renderShop

local function changed()
    save()
    Look.announce()
end

local shopScroll = 0

-- Things the formal store sells that are not clothes. The briefcase is the game's own
-- "Elegant suitcase" (a bag of 4 x 4 that no shop of the game sells any more): the game's
-- pick-up is made on the shop floor at the buyer's feet, and taken up at once by a buyer
-- who carries no bag. (The game takes up a bag only into an empty backpack slot.)
local SUITCASE = "/Game/Interactive/Backpacks/suitcaseBP"
local function deliverSuitcase()
    local player = World.player()
    if not player then return false end
    local class = StaticFindObject(SUITCASE .. ".suitcaseBP_C")
    if not valid(class) then
        pcall(function() LoadAsset(SUITCASE) end)
        class = StaticFindObject(SUITCASE .. ".suitcaseBP_C")
    end
    if not valid(class) then return false end
    local l = player:K2_GetActorLocation()
    local r = math.rad(player:K2_GetActorRotation().Yaw)
    local case = player:GetWorld():SpawnActor(class, { X = l.X + math.cos(r) * 60, Y = l.Y + math.sin(r) * 60, Z = l.Z }, { Pitch = 0, Yaw = 0, Roll = 0 })
    if not valid(case) then return false end
    local free = false
    pcall(function() free = player.InventoryComponent.CurBackpackID:ToString() == "None" end)
    if free then
        Core.after(0.4, function()
            pcall(function() if Core.alive(case) then case:objectPickup() end end)
        end)
        Hud.toast("The briefcase is yours", 4)
    else
        Hud.toast("Put your bag down to take the briefcase", 7)
    end
    return true
end
local OTHER_GOODS = {
    { name = "Elegant briefcase", kind = "Bag", price = 600, icon = "/Game/Interactive/Backpacks/Icons/Suitcase1.Suitcase1", deliver = deliverSuitcase },
}

-- What the grid shows: everything there is at the shop, what the player owns at a wardrobe.
local function shopItems()
    -- (watches switched off since the tab was last open)
    if not watchesOn() and shopTab == "watches" then shopTab = "all" end
    local items = {}
    local mine = Look.page == "wardrobe"
    -- the formal store has formal wear only; Marco everything else, hats and glasses
    local formal = not mine and Look.store ~= nil and Look.store.ID == "formal"
    if shopTab == "all" or shopTab == "outfits" then
        for _, o in ipairs(S().outfits) do
            local owned = state.owned[o.id] == true
            local sold = mine or formal == (o.shop == "formal")
            if sold and (owned or not mine) then
                items[#items + 1] = { name = o.name, kind = "Outfit", body = o.body, price = o.price, owned = owned, on = state.outfit == o.id,
                    slot = "body", tried = preview ~= nil and preview.body == o.body,
                    try = function() tryOn("body", o.body) end,
                    take = function() state.outfit = o.id end, own = function() state.owned[o.id] = true end }
            end
        end
    end
    if shopTab == "all" or shopTab == "hats" or shopTab == "hair" then
        -- Hair is the barber's (coop/barber.lua). Here it can only be worn or not: "Bald"
        -- and, for whoever has hair, "Hair": the style and colour they have. Then "No hat"
        -- and the hats this shop sells.
        if shopTab ~= "hats" then
            local own = hairWorn()
            if state.hairOff then own = dressed(styleMesh(), state.hairColour) end
            local bald = state.hairOff == true or own == ""
            items[#items + 1] = { name = "Bald", kind = "Hair", hair = "", price = 0, owned = true, on = bald,
                slot = "hair", tried = preview ~= nil and preview.hair == "", try = function() tryOn("hair", "") end,
                take = function() state.hairOff = true end, own = function() end }
            if own ~= "" then
                items[#items + 1] = { name = "Hair", kind = "Hair", hair = own, price = 0, owned = true, on = not bald,
                    slot = "hair", tried = preview ~= nil and preview.hair == own, try = function() tryOn("hair", own) end,
                    take = function() state.hairOff = false end, own = function() end }
            end
        end
        if shopTab ~= "hair" then
            local nowHat = state.hat or 0
            local first = true
            for i, h in ipairs(S().hair) do
                if h.price and (mine or formal == (h.shop == "formal")) then
                    local owned = state.ownedHair[hk(i)] == true
                    if owned or not mine then
                        if first then
                            first = false
                            items[#items + 1] = { name = "No hat", kind = "Hat", hat = "", price = 0, owned = true, on = nowHat == 0,
                                slot = "hat", tried = preview ~= nil and preview.hat == "", try = function() tryOn("hat", "") end,
                                take = function() state.hat = 0 end, own = function() end }
                        end
                        items[#items + 1] = { name = h.name, kind = "Hat", hat = h.mesh, price = h.price, owned = owned,
                            on = nowHat == i, slot = "hat", tried = preview ~= nil and preview.hat == h.mesh,
                            try = function() tryOn("hat", h.mesh) end,
                            take = function() state.hat = i end, own = function() state.ownedHair[hk(i)] = true end }
                    end
                end
            end
        end
    end
    if shopTab == "all" or shopTab == "glasses" then
        local now = state.glasses or 0
        items[#items + 1] = { name = "No glasses", kind = "Glasses", glasses = "", price = 0, owned = true, on = now == 0,
            slot = "glasses", tried = preview ~= nil and preview.glasses == "", try = function() tryOn("glasses", "") end,
            take = function() state.glasses = 0 end, own = function() end }
        for i, g in ipairs(S().glasses) do
            local owned = state.ownedGlasses[gk(i)] == true
            if not g.gone and (owned or not mine) and (mine or formal == (g.shop == "formal")) then
                items[#items + 1] = { name = g.name, kind = "Glasses", glasses = g.mesh, price = g.price, owned = owned,
                    on = now == i, slot = "glasses", tried = preview ~= nil and preview.glasses == g.mesh,
                    try = function() tryOn("glasses", g.mesh) end,
                    take = function() state.glasses = i end, own = function() state.ownedGlasses[gk(i)] = true end }
            end
        end
    end
    if watchesOn() and (shopTab == "all" or shopTab == "watches") then
        local now = state.watch or 0
        items[#items + 1] = { name = "No watch", kind = "Watch", watch = "", price = 0, owned = true, on = now == 0,
            slot = "watch", tried = preview ~= nil and preview.watch == "", try = function() tryOn("watch", "") end,
            take = function() state.watch = 0 end, own = function() end }
        for i, w in ipairs(WATCHES) do
            local owned = state.ownedWatches[wk(i)] == true
            if (owned or not mine) and (mine or formal == (w.shop == "formal")) then
                items[#items + 1] = { name = w.name, kind = "Watch", watch = w.code, price = w.price, owned = owned,
                    on = now == i, slot = "watch", tried = preview ~= nil and preview.watch == w.code,
                    try = function() tryOn("watch", w.code) end,
                    take = function() state.watch = i end, own = function() state.ownedWatches[wk(i)] = true end }
            end
        end
    end
    -- OTHER, at the formal store: things that are not worn. Bought again every time.
    if formal and (shopTab == "all" or shopTab == "other") then
        for _, o in ipairs(OTHER_GOODS) do
            items[#items + 1] = { name = o.name, kind = o.kind, price = o.price, owned = false, on = false, other = o }
        end
    end
    return items
end

renderShop = function()
    if not scr then return end
    for _, w in ipairs(drawn) do
        if w == scr.shopList then pcall(function() shopScroll = w:GetScrollOffset() end) end
    end
    wipe()
    local money = math.floor(bank())
    local mine = Look.page == "wardrobe"
    local U = scr.units()
    -- top bar, from the right margin: close, then (at the shop) the balance
    local top = scr.new("HorizontalBox")
    if not mine then
        local balance = top:AddChildToHorizontalBox(scr.text(string.format("your account balance: $%d", money), "price", 18))
        balance:SetVerticalAlignment(2)
        balance:SetPadding({ Left = 0, Top = 0, Right = 28, Bottom = 0 })
    end
    local x = scr.bigButton("X", 1.5, closeScreen)
    scr.tint(x, Screen.RED)
    top:AddChildToHorizontalBox(x.box):SetVerticalAlignment(2)
    put(top, 1 - LEFT, 0.05, BUTTON_INSET * 1.5, 0, 1, 0.5)
    -- the tabs: one row starting at the left margin, the same distance between them
    local tabs = { { "all", "ALL" }, { "outfits", "OUTFITS" }, { "hair", "HAIR" }, { "hats", "HATS" }, { "glasses", "GLASSES" } }
    if watchesOn() then tabs[#tabs + 1] = { "watches", "WATCHES" } end
    if not mine and Look.store ~= nil and Look.store.ID == "formal" then tabs[#tabs + 1] = { "other", "OTHER" } end
    local bar = scr.new("HorizontalBox")
    for i, t in ipairs(tabs) do
        local b = scr.bigButton(t[2], 1.3, function()
            shopTab, shopScroll = t[1], 0
            renderShop()
        end)
        if shopTab == t[1] then scr.tint(b, Screen.GREEN) end
        bar:AddChildToHorizontalBox(b.box):SetPadding({ Left = i > 1 and 36 or 0, Top = 0, Right = 0, Bottom = 0 })
    end
    put(bar, LEFT, 0.14, -BUTTON_INSET * 1.3, 0, 0, 0.5)
    -- The grid: as many columns as fit, each as wide as it takes to fill the panel from
    -- the left margin to the scroll bar.
    local x0, x1 = LEFT, PANEL_W - 0.012
    local available = (x1 - x0) * U - 34 - GAP        -- the scroll bar, and the gap after the last card of a row
    local columns = math.max(2, math.floor((available + GAP) / (224 + GAP)))
    local tileW = math.floor((available - (columns - 1) * GAP) / columns)
    local list, wrap = scr.new("ScrollBox"), scr.new("WrapBox")
    list:AddChild(wrap)
    scr.area(list, x0, 0.18, x1, 0.98)
    scr.shopList = list
    drawn[#drawn + 1] = list
    for _, it in ipairs(shopItems()) do
        local label, corner, color = "BUY", "$ " .. it.price, Screen.GREEN
        if it.on then label, corner, color = "WEARING", "yours", Screen.GREY
        elseif it.owned then label, corner, color = "WEAR", it.price > 0 and "yours" or "free", Screen.GREY end
        if mine then corner = nil end
        local buttons = {}
        if it.other then
            local o = it.other
            buttons[1] = { "BUY", function()
                if not pay(o.price) then
                    Hud.toast(string.format("Not enough money in the bank for this ($%d)", o.price), 4)
                    return
                end
                local ok, done = pcall(o.deliver)
                if not ok or not done then
                    -- (nothing handed over: the money goes back)
                    pcall(function() local m, c = bank() c.playerBankMoney = m + o.price end)
                    log("Could not hand over %s: %s", o.name, tostring(done))
                end
                renderShop()
            end, money < o.price }
            local pic = nil
            local tex = texture(o.icon)
            if tex then
                local img = scr.new("Image")
                pcall(function() img:SetBrushFromTexture(tex, false) end)
                pic = scr.sized(img, 120, 120)
            end
            local cell = tile(tileW, 330, it.name, { it.kind }, corner, color, buttons, false, pic, 30, nil, "other:" .. o.name)
            local slot = wrap:AddChild(cell)
            pcall(function() slot:SetPadding({ Left = 0, Top = 0, Right = GAP, Bottom = GAP }) end)
            goto continue
        end
        if not it.on and not mine then
            buttons[1] = { "PREVIEW", function()
                if it.tried then takeOff(it.slot) else it.try() end
                renderShop()
            end, false, it.tried and Screen.GREEN or nil }
        end
        buttons[#buttons + 1] = { label, function()
            if not it.owned then
                if not pay(it.price) then
                    Hud.toast(string.format("Not enough money in the bank for this ($%d)", it.price), 4)
                    return
                end
                it.own()
                syncSelf()
            end
            it.take()
            takeOff(it.slot)
            changed()
            renderShop()
        end, it.on or (not it.owned and money < it.price) }
        local now = Look.current()
        local pic, gap
        if it.body then
            pic = Thumbs.image(scr, "b|" .. it.body .. "|" .. now.head, { look = { body = it.body, head = now.head, hair = now.hair, arms = true }, shot = "body" }, 120, 180)
        elseif it.glasses then
            pic, gap = Thumbs.image(scr, "g|" .. it.glasses .. "|" .. now.head .. "|" .. now.hair, { look = { body = now.body, head = now.head, hair = now.hair, glasses = it.glasses, arms = true }, shot = "face" }, 120, 120), 30
        elseif it.watch then
            -- (the wrist, in the outfit the player wears: under a sleeve a watch sits lower)
            pic, gap = Thumbs.image(scr, "w|" .. it.watch .. "|" .. now.body, { look = { body = now.body, head = now.head, hair = now.hair, watch = it.watch, arms = true }, shot = "wrist" }, 120, 120), 30
        else
            if it.hat then
                -- (a hat on a bald head, so that the hat itself is what the picture shows;
                -- "No hat" with the player's own hair)
                local short = it.hat == "" and (now.hair or "") or ""
                pic, gap = Thumbs.image(scr, "c|" .. it.hat .. "|" .. now.head .. "|" .. short, { look = { body = now.body, head = now.head, hair = short, hat = it.hat, arms = true }, shot = "hair" }, 120, 120), 30
            else
                local hat = (now.hat and not Avatar.hidesHair(now.hat)) and now.hat or nil
                pic, gap = Thumbs.image(scr, "h|" .. it.hair .. "|" .. now.head .. "|" .. tostring(hat), { look = { body = now.body, head = now.head, hair = it.hair, hat = hat, arms = true }, shot = "hair" }, 120, 120), 30
            end
        end
        local onCard = nil
        if mine then
            if not it.on then onCard = buttons[#buttons][2] end
        elseif not it.on then
            onCard = function()
                if not it.tried then it.try() end
                renderShop()
            end
        end
        local cell = tile(tileW, mine and 306 or 330, it.name, { it.kind }, corner, color, buttons, it.on, pic, gap, onCard,
            it.body or it.hair or (it.hat and ("hat:" .. it.hat)) or (it.glasses and ("glasses:" .. it.glasses)) or ("watch:" .. it.watch))
        local slot = wrap:AddChild(cell)
        pcall(function() slot:SetPadding({ Left = 0, Top = 0, Right = GAP, Bottom = GAP }) end)
        ::continue::
    end
    local offset = shopScroll
    pcall(function() list:SetScrollOffset(offset) end)
    Core.after(0.05, function() pcall(function() if scr and scr.shopList == list then list:SetScrollOffset(offset) end end) end)
    -- (below where the game's own tips and warnings stand at the top right)
    if preview then put(scr.text("PREVIEW", "button", 18, Screen.GREEN), FIGURE_X, 0.215) end
    pcall(showMirror)
end

---------------------------------------------------------------- the barber

-- Olivia's (coop/barber.lua): the only place where hair and beard are changed. Cards as in
-- the clothes shops. HAIR shows the cuts; choosing one shows that cut in every colour (ALL
-- CUTS goes back), and the colours can be tried one after the other on the figure, a
-- close-up of the face, before anything is paid. BEARD (men) has the beards, which are
-- always the colour of the hair. PAY takes what is different from what the player has.
-- Bald costs nothing, ever: the head is shaved and the style the player paid for is kept
-- (state.hairOff), so going back to that style in its colour costs nothing either.
local barberTab, barberStep, barberScroll, pick = "hair", "cuts", 0, nil
local renderBarber

local function baldIndex()
    for i, h in ipairs(S().hair) do if not h.price and h.mesh == "" then return i end end
    return state.hair
end
local function barberStart()
    barberTab, barberStep, barberScroll = "hair", "cuts", 0
    pick = { hair = state.hairOff and baldIndex() or state.hair, colour = state.hairColour, beard = state.beard or 0 }
    pick.had = pick.hair
    -- (the hat the player came in with: it can be taken off here and put on again)
    pick.hat = state.hat or 0
end
local function pickedStyle()
    local h = S().hair[pick.hair]
    return h and h.mesh or ""
end
local function pickedBeard()
    local b = state.gender == "m" and BEARDS[pick.beard or 0] or nil
    if not b then return "" end
    return dressed(b.mesh, beardColourFor(pick.colour or naturalOf(pickedStyle())))
end
-- What the choice costs, and the lines it is made of.
local function barberCost()
    local lines, total = {}, 0
    local function add(label, price)
        lines[#lines + 1] = string.format("%s $%d", label, price)
        total = total + price
    end
    if pickedStyle() ~= "" then
        if pick.hair ~= state.hair then add("CUT", BARBER_PRICE.cut) end
        if pick.colour ~= state.hairColour then add("COLOUR", BARBER_PRICE.colour) end
    end
    if state.gender == "m" and pick.beard ~= (state.beard or 0) then add("BEARD", BARBER_PRICE.beard) end
    return total, lines
end
-- Whether the choice is anything else than what the player wears now (it may cost nothing).
local function barberDiffers()
    if pick.hair ~= pick.had then return true end
    if pickedStyle() ~= "" and pick.colour ~= state.hairColour then return true end
    return state.gender == "m" and pick.beard ~= (state.beard or 0)
end

renderBarber = function()
    if not scr or not pick then return end
    for _, w in ipairs(drawn) do
        if w == scr.shopList then pcall(function() barberScroll = w:GetScrollOffset() end) end
    end
    wipe()
    local money = math.floor(bank())
    local U = scr.units()
    local men = state.gender == "m"
    local now = Look.current()
    -- top bar, from the right margin: close, then the balance (as in the clothes shops)
    local top = scr.new("HorizontalBox")
    local balance = top:AddChildToHorizontalBox(scr.text(string.format("your account balance: $%d", money), "price", 18))
    balance:SetVerticalAlignment(2)
    balance:SetPadding({ Left = 0, Top = 0, Right = 28, Bottom = 0 })
    local x = scr.bigButton("X", 1.5, closeScreen)
    scr.tint(x, Screen.RED)
    top:AddChildToHorizontalBox(x.box):SetVerticalAlignment(2)
    put(top, 1 - LEFT, 0.05, BUTTON_INSET * 1.5, 0, 1, 0.5)
    -- the tabs, as in the clothes shops; while a cut's colours are shown, the way back
    local bar, tabs = scr.new("HorizontalBox"), 0
    local function tab(label, on, fn)
        local b = scr.bigButton(label, 1.3, fn)
        if on then scr.tint(b, Screen.GREEN) end
        tabs = tabs + 1
        bar:AddChildToHorizontalBox(b.box):SetPadding({ Left = tabs > 1 and 36 or 0, Top = 0, Right = 0, Bottom = 0 })
    end
    tab("HAIR", barberTab == "hair", function()
        barberTab, barberStep, barberScroll = "hair", "cuts", 0
        renderBarber()
    end)
    if men then
        tab("BEARD", barberTab == "beard", function()
            barberTab, barberScroll = "beard", 0
            renderBarber()
        end)
    end
    tab("HATS", barberTab == "hats", function()
        barberTab, barberScroll = "hats", 0
        renderBarber()
    end)
    if barberTab == "hair" and barberStep == "colours" then
        tab("ALL CUTS", false, function()
            barberStep, barberScroll = "cuts", 0
            renderBarber()
        end)
    end
    put(bar, LEFT, 0.14, -BUTTON_INSET * 1.3, 0, 0, 0.5)
    -- the grid of the clothes shops: as many columns as fit, filling the panel
    local x0, x1 = LEFT, PANEL_W - 0.012
    local available = (x1 - x0) * U - 34 - GAP
    local columns = math.max(2, math.floor((available + GAP) / (224 + GAP)))
    local tileW = math.floor((available - (columns - 1) * GAP) / columns)
    local list, wrap = scr.new("ScrollBox"), scr.new("WrapBox")
    list:AddChild(wrap)
    scr.area(list, x0, 0.18, x1, 0.88)
    scr.shopList = list
    drawn[#drawn + 1] = list
    -- one card: the price in the corner ("yours" for what the player has), a picture, the
    -- name, what it is, SELECT; a click anywhere on it selects
    local function card(name, kind, price, mine, on, pic, fn, id, button, corner)
        local cell = tile(tileW, 238, name, { kind }, corner or (mine and "yours" or ("$ " .. price)), mine and Screen.GREY or Screen.GREEN,
            { { button or (on and "SELECTED" or "SELECT"), fn, false, on and Screen.GREEN or nil } }, on, pic, 4, fn, id)
        local slot = wrap:AddChild(cell)
        pcall(function() slot:SetPadding({ Left = 0, Top = 0, Right = GAP, Bottom = GAP }) end)
    end
    if barberTab == "hats" then
        -- Hats are the clothes shops' business. Here one can only be taken off, to see the
        -- hair, and put on again: nothing to pay, and it is done at once.
        local worn = state.hat or 0
        local list = { 0 }
        if (pick.hat or 0) ~= 0 and S().hair[pick.hat] then list[2] = pick.hat end
        for _, n in ipairs(list) do
            local h = S().hair[n]
            local mesh = h and h.mesh or ""
            local short = mesh == "" and (now.hair or "") or ""
            local pic = Thumbs.image(scr, "c|" .. mesh .. "|" .. now.head .. "|" .. short, { look = { body = now.body, head = now.head, hair = short, hat = mesh, arms = true }, shot = "hair" }, 104, 104)
            card(h and h.name or "No hat", "Hat", 0, true, worn == n, pic, function()
                if (state.hat or 0) == n then return end
                state.hat = n
                changed()
                renderBarber()
            end, "hat" .. n, worn == n and "WEARING" or "WEAR", n == 0 and "free" or "yours")
        end
    elseif barberTab == "beard" and men then
        for n = 0, #BEARDS do
            local b = BEARDS[n]
            local beard = b and dressed(b.mesh, beardColourFor(pick.colour or naturalOf(pickedStyle()))) or ""
            local pic = Thumbs.image(scr, "w|" .. beard .. "|" .. now.head .. "|", { look = { body = now.body, head = now.head, hair = "", beard = beard, arms = true }, shot = "face" }, 104, 104)
            card(b and b.name or "No beard", "Beard", BARBER_PRICE.beard, n == (state.beard or 0), pick.beard == n, pic, function()
                pick.beard = n
                renderBarber()
            end, "beard" .. n)
        end
    elseif barberStep == "colours" and pickedStyle() ~= "" then
        local colours = { { id = nil, name = "Natural" } }
        for _, c in ipairs(HAIR_COLOURS) do colours[#colours + 1] = c end
        for _, c in ipairs(colours) do
            local hair = dressed(pickedStyle(), c.id)
            local pic = Thumbs.image(scr, "h|" .. hair .. "|" .. now.head, { look = { body = now.body, head = now.head, hair = hair, arms = true }, shot = "hair" }, 104, 104)
            card(c.name, "Colour", BARBER_PRICE.colour, c.id == state.hairColour, pick.colour == c.id, pic, function()
                pick.colour = c.id
                renderBarber()
            end, "colour:" .. tostring(c.id))
        end
    else
        local styles = {}
        for i, h in ipairs(S().hair) do if not h.price and h.mesh == "" then styles[#styles + 1] = i end end
        for i, h in ipairs(S().hair) do if not h.price and h.mesh ~= "" then styles[#styles + 1] = i end end
        for _, i in ipairs(styles) do
            local style = S().hair[i]
            local hair = dressed(style.mesh, pick.colour)
            local pic = Thumbs.image(scr, "h|" .. hair .. "|" .. now.head, { look = { body = now.body, head = now.head, hair = hair, arms = true }, shot = "hair" }, 104, 104)
            local bald = style.mesh == ""
            card(style.name, "Cut", BARBER_PRICE.cut, bald or i == state.hair, pick.hair == i, pic, function()
                pick.hair = i
                -- a cut with hair goes on to its colours; a shaved head keeps the colour the
                -- player has (the beard's, and the hair's when it is worn again)
                if bald then pick.colour = state.hairColour else barberStep, barberScroll = "colours", 0 end
                renderBarber()
            end, "hair" .. i, nil, bald and "free" or nil)
        end
    end
    local offset = barberScroll
    pcall(function() list:SetScrollOffset(offset) end)
    Core.after(0.05, function() pcall(function() if scr and scr.shopList == list then list:SetScrollOffset(offset) end end) end)

    -- what it comes to, and the button that pays: at the panel's right margin, at the bottom
    local total, lines = barberCost()
    local foot = scr.new("HorizontalBox")
    if #lines > 0 then
        local sum = foot:AddChildToHorizontalBox(scr.text(table.concat(lines, "   +   "), "button", 16, Screen.GREY))
        sum:SetVerticalAlignment(2)
        sum:SetPadding({ Left = 0, Top = 0, Right = 28, Bottom = 0 })
    end
    local differs = barberDiffers()
    local payButton = scr.bigButton(total > 0 and string.format("PAY $%d", total) or (differs and "APPLY" or "NOTHING CHANGED"), 1.5, function()
        local cost = barberCost()
        if not barberDiffers() then return end
        if cost > 0 and not pay(cost) then
            Hud.toast(string.format("Not enough money in the bank for this ($%d)", cost), 4)
            return
        end
        -- (what has been paid at Olivia's: the wall quest counts it, coop/wallquest.lua)
        Look.barberPaid = (Look.barberPaid or 0) + cost
        if pickedStyle() == "" and pick.hair ~= state.hair then
            state.hairOff = true                 -- (shaved: the style and its colour stay the player's)
        else
            state.hair, state.hairOff, state.hairColour = pick.hair, false, pick.colour
        end
        if men then state.beard = pick.beard end
        pick.had = pick.hair
        changed()
        Hud.toast("Olivia: there you go", 4)
        renderBarber()
    end)
    if not differs or money < total then scr.enable(payButton, false) end
    if differs and money >= total then scr.tint(payButton, Screen.GREEN) end
    foot:AddChildToHorizontalBox(payButton.box):SetVerticalAlignment(2)
    put(foot, PANEL_W - LEFT, 0.94, BUTTON_INSET * 1.5, 0, 1, 0.5)

    -- the figure shows the choice (without a hat: the hair is what this is about; under
    -- HATS with the hat that is worn, or none)
    local hatNow = barberTab == "hats" and S().hair[state.hat or 0] or nil
    preview = { hair = dressed(pickedStyle(), pick.colour), hat = hatNow and hatNow.mesh or "", beard = pickedBeard() }
    pcall(showMirror)
end

function Look.openShop(store)
    stale()
    if scr or not World.player() then return false end
    load()
    store = store or storeNear() or Clerk
    if not Look.atShop(store) then return false end
    Look.store, Look.fitting = store, store.FITTING
    if store.ID == "formal" then shopTab, shopScroll = "all", 0 end
    if not frame(store.TITLE or "CLOTHES") then return false end
    if store.solid then pcall(store.solid, false) end
    -- The player is put at the viewpoint and turned so that the figure in front of the
    -- rack is in the middle of the part of the picture the panel leaves free, between the
    -- bar at the top and the bottom edge. Closing the screen puts the player back.
    local pitch, back, lowered = 0, nil, false
    pcall(function()
        local p = World.player()
        local l = p:K2_GetActorLocation()
        back = { x = l.X, y = l.Y, z = l.Z }
        p:K2_SetActorLocation({ X = store.VIEWPOINT.x, Y = store.VIEWPOINT.y, Z = l.Z }, false, {}, true)
        local spot = store.FITTING
        if store.FOV then
            -- (the player's own camera; held until the screen closes: the tick below, release)
            local ok, e = pcall(function() p.Camera:SetFieldOfView(store.FOV) end)
            if ok then fovNow = store.FOV else log("Shop: the close-up is not available: %s", tostring(e)) end
        end
        local eye, tx, ty = view()
        local dx, dy = spot.x - eye.X, spot.y - eye.Y
        local aside = math.atan((2 * FIGURE_X - 1) * tx)
        local depth = math.max(60, math.sqrt(dx * dx + dy * dy) * math.cos(aside))
        -- The camera stays level (looking down at the figure would make it lean in the
        -- picture): the player is let down until the eye is just above the figure's middle,
        -- which then sits a little below the middle of the picture, as on the other screens.
        -- (No walking until the screen closes; then back where they were. Collision stays:
        -- the game puts a shop's furniture up only around a player with collision.)
        -- (a store may want another part of the figure in the picture: the barber the head)
        local focus = store.FOCUS or { up = 0, at = 0.55 }
        local lift = (2 * focus.at - 1) * ty * depth
        p.CharacterMovement:SetMovementMode(0, 0)
        p:K2_SetActorLocation({ X = store.VIEWPOINT.x, Y = store.VIEWPOINT.y, Z = spot.z + focus.up + lift - EYE_HEIGHT }, false, {}, true)
        lowered = true
        pitch = 0
        p:GetController():SetControlRotation({ Pitch = pitch, Yaw = math.deg(math.atan(dy, dx)) - math.deg(aside), Roll = 0 })
    end)
    hold(pitch)
    if pose then pose.back, pose.lowered = back, lowered end
    if store.ID == "barber" then
        Look.page = "barber"
        barberStart()
        renderBarber()
        return true
    end
    Look.page = "shop"
    renderShop()
    return true
end

-- Next to a wardrobe (the game's piece of furniture; a hideout can have several). The
-- places are looked up every few seconds: furniture is bought, moved and sold.
local WARDROBE = "/Game/Interactive/FunctionalFurniture/clothesWardrobeBP.clothesWardrobeBP_C"
local WARDROBE_REACH = 230
local wardrobes, wardrobesAt = {}, -100
local function wardrobeNear()
    local player = World.player()
    if not player then return nil end
    local now = os.clock()
    if now - wardrobesAt > 4 then
        wardrobesAt, wardrobes = now, {}
        for _, a in ipairs(Core.actors(WARDROBE) or {}) do
            local ok, l = pcall(function() return a:K2_GetActorLocation() end)
            if ok and l then wardrobes[#wardrobes + 1] = { x = l.X, y = l.Y, z = l.Z } end
        end
    end
    local l = player:K2_GetActorLocation()
    for _, w in ipairs(wardrobes) do
        local dx, dy = w.x - l.X, w.y - l.Y
        if math.abs(w.z - l.Z) < 170 and dx * dx + dy * dy < WARDROBE_REACH * WARDROBE_REACH then return w end
    end
    return nil
end
function Look.atWardrobe() return wardrobeNear() ~= nil end

-- How far along `yaw` the room is free for the wardrobe's figure: lines from the eye to
-- points ahead at three heights (feet, middle, head), up to the first thing in the way.
local KSL = nil
local SHOP_DISTANCE = 307        -- how far the shops' figures are from their viewpoints
local function roomAlong(p, floor, yaw)
    KSL = KSL or StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local eye = view()
    local r = math.rad(yaw)
    local free = 0
    for d = 90, SHOP_DISTANCE + 60, 15 do
        local x, y = eye.X + math.cos(r) * d, eye.Y + math.sin(r) * d
        local blocked = false
        for _, h in ipairs({ 25, 90, 165 }) do
            local hit = {}
            local ok, yes = pcall(function()
                return KSL:LineTraceSingle(p, eye, { X = x, Y = y, Z = floor + h }, 0, false, {}, 0, hit, true,
                    { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0)
            end)
            if ok and yes then blocked = true break end
        end
        if blocked then break end
        free = d
    end
    return free
end

-- The wardrobe at home: what the player owns, nothing to buy.
function Look.openWardrobe()
    stale()
    if scr or not World.player() then return false end
    load()
    local w = wardrobeNear()
    if not w then return false end
    if not frame("WARDROBE") then return false end
    -- The figure is shown as in the shops: standing on the floor where the room is most
    -- open (first choice: with the player's back to the wardrobe, so that it is not inside
    -- the furniture), the camera level at its height. Where the room is small it stands
    -- nearer and is made as much smaller, so that it looks the same.
    local back, lowered = nil, false
    Look.fitting = nil
    pcall(function()
        local p = World.player()
        local l = p:K2_GetActorLocation()
        back = { x = l.X, y = l.Y, z = l.Z }
        local half = 92
        pcall(function() half = p.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
        local floor = l.Z - half
        local away = math.deg(math.atan(l.Y - w.y, l.X - w.x))
        local best, bestRoom = away, -1
        for _, turn in ipairs({ 0, 45, -45, 90, -90, 135, -135, 180 }) do
            local room = roomAlong(p, floor, away + turn)
            if room > bestRoom + 15 then best, bestRoom = away + turn, room end
            if room >= SHOP_DISTANCE + 40 then break end
        end
        local d = math.max(70, math.min(SHOP_DISTANCE, bestRoom - 40))
        local size = d / SHOP_DISTANCE
        local eye, tx, ty = view()
        local r = math.rad(best)
        Look.fitting = { x = eye.X + math.cos(r) * d, y = eye.Y + math.sin(r) * d, z = floor + 88, size = size }
        -- turned so that the figure is in the middle of the part of the picture the panel
        -- leaves free; let down until the eye is just above the figure's middle
        local aside = math.atan((2 * FIGURE_X - 1) * tx)
        local lift = (2 * 0.55 - 1) * ty * d * math.cos(aside)
        p.CharacterMovement:SetMovementMode(0, 0)
        p:K2_SetActorLocation({ X = l.X, Y = l.Y, Z = floor + 88 * size + lift - EYE_HEIGHT }, false, {}, true)
        lowered = true
        p:GetController():SetControlRotation({ Pitch = 0, Yaw = best - math.deg(aside), Roll = 0 })
    end)
    hold(0)
    if pose then pose.back, pose.lowered = back, lowered end
    Look.page = "wardrobe"
    shopTab, shopScroll = "all", 0
    renderShop()
    return true
end

function Look.close() closeScreen() end
-- (for test scripts) show another tab of the open shop
function Look.showTab(t)
    if not scr or Look.page == "start" then return end
    if Look.page == "barber" then
        barberTab, barberScroll = t, 0
        renderBarber()
    else
        shopTab, shopScroll = t, 0
        renderShop()
    end
end
-- (for test scripts) the barber's screen: what is chosen (a table to change), draw it again
function Look.barberPick() return pick end
function Look.barberRedraw() if scr and Look.page == "barber" then renderBarber() end end
function Look.scrollTo(v) if scr and scr.shopList then pcall(function() if v >= 99 then scr.shopList:ScrollToEnd() else scr.shopList:SetScrollOffset(v) end end) end end

-- The interaction key: the blackjack table at the club, the clothes shop at Donald's, a
-- wardrobe at home.
function Look.toggle()
    if scr then
        if Look.page == "shop" or Look.page == "wardrobe" or Look.page == "barber" then closeScreen() end
        return
    end
    local store = storeNear()
    if store then
        -- the shopkeeper's dialogue leads to the screen; without it the screen opens directly
        if not store.talk() then Look.openShop(store) end
    elseif Look.atWardrobe() then
        Look.openWardrobe()
    end
end

-- A fugitive who changes clothes at a wardrobe (the game's own way of shaking off the
-- police) comes out in another outfit of their own, and another hat if they have one.
-- With nothing else to wear nothing happens. Returns what was put on.
function Look.disguise()
    load()
    local outfits, hats = {}, {}
    for _, o in ipairs(S().outfits) do
        if state.owned[o.id] and o.id ~= state.outfit then outfits[#outfits + 1] = o end
    end
    for i, h in ipairs(S().hair) do
        if h.price and state.ownedHair[hk(i)] and i ~= state.hat then hats[#hats + 1] = i end
    end
    if #outfits == 0 and #hats == 0 then return nil end
    local worn = {}
    if #outfits > 0 then
        local o = outfits[math.random(#outfits)]
        state.outfit = o.id
        worn[#worn + 1] = o.name
    end
    if #hats > 0 then
        local i = hats[math.random(#hats)]
        state.hat = i
        worn[#worn + 1] = S().hair[i].name
    end
    save()
    Look.announce()
    if scr and (Look.page == "shop" or Look.page == "wardrobe") then pcall(renderShop) end
    if Hud.ready() then Hud.toast("You changed into: " .. table.concat(worn, ", "), 4) end
    return worn
end

-- The wardrobe calls this (and nothing else does) at the moment the fugitive stops being one.
Core.Hooks.add(WARDROBE .. ":endCopAlert", function()
    local ok, e = pcall(Look.disguise)
    if not ok then log("Wardrobe: change of clothes failed: %s", tostring(e)) end
end)
Clerk.onShow = function() Look.openShop(Clerk) end

if Core.bindKey then
    Core.bindKey(Core.config.WardrobeKey or "U", function()
        local ok, e = xpcall(function()
            local t = Look.takeover
            if t and (t.isOpen() or (not scr and t.near())) then t.toggle() else Look.toggle() end
        end, debug.traceback)
        if not ok then log("Wardrobe: %s", tostring(e)) end
    end)
end

---------------------------------------------------------------- the player's own hands

-- In first person the game shows one pair of arms (with the phone, the flashlight...),
-- always pale. With a dark face (the men's dark one, the women's 2 and 6) they are darker:
-- see armsSkin. Every other face keeps the game's arms. This is the player's own view only.
-- The darker arms: the citizens' skin material, one colour all over (with the arms' own
-- relief), so dark. (Their skin materials cut out what the arms' picture leaves
-- transparent, the fingernails among it: so not the arms' picture itself.)
local ARMS_SKIN = {
    SK_ma_head_04_dark = { R = 0.025, G = 0.01, B = 0.004, A = 1 },
    SK_fe_head_05 = { R = 0.025, G = 0.01, B = 0.004, A = 1 },
    SK_fe_head_01_dark = { R = 0.06, G = 0.025, B = 0.01, A = 1 },
}
local ARMS_BASE = "/Game/CitizenNPC/CharacterParts/Materials/Basebody/MI_ma_body_01_deep.MI_ma_body_01_deep"
local WHITE = "/Engine/EngineResources/WhiteSquareTexture.WhiteSquareTexture"
local ARMS = "/Game/Skeletal/FPP_Arms/"
local armsFor = nil

local function armsSkin()
    local player = World.player()
    if not player then
        armsFor = nil
        return
    end
    load()
    local head = S().faces[state.face] or ""
    local key = player:GetAddress() .. "|" .. head
    if armsFor == key then return end
    local ok, e = pcall(function()
        local c = player.fpsArms
        if not valid(c) then return end
        local tone = ARMS_SKIN[head]
        if not tone then
            local own = Avatar.asset(ARMS .. "fppArms_MAT.fppArms_MAT")
            if own then c:SetMaterial(1, own) end
        else
            local base = Avatar.asset(ARMS_BASE)
            if not base then return end
            local d = c:CreateDynamicMaterialInstance(1, base, FName("None"))
            if not valid(d) then return end
            local white = Avatar.asset(WHITE)
            d:SetTextureParameterValue(FName("Albedo"), white)
            d:SetTextureParameterValue(FName("Normal"), Avatar.asset(ARMS .. "fppArms_texNorm.fppArms_texNorm"))
            d:SetTextureParameterValue(FName("Tint Mask"), white)
            d:SetVectorParameterValue(FName("R: Primary"), tone)
        end
        armsFor = key
    end)
    if not ok then
        armsFor = key
        log("First-person arms: %s", tostring(e))
    end
end
Core.every(1, armsSkin)

---------------------------------------------------------------- the inventory figure

-- The inventory screen shows a figure seen from behind: the game films its own posed model
-- (inventoryCharacterBP: a hooded man, a camera in front of his back, far outside the
-- city) into the screen's picture. That model is hidden as soon as the world is there and
-- a figure dressed like the player stands in its place all the time (built anew whenever
-- the look changes), so that the screen never shows the hooded man, not even while opening.
local INV_CHARACTER = "inventoryCharacterBP_C"
local invFigure = nil       -- { fig, key, model }
local invCheck = 0
local invWasOpen = false

-- The figure stands far outside the city, and the game keeps the textures of what is far
-- from the player at their coarsest: on the screen its clothes were a blur. Its parts keep
-- their textures in full and are drawn as their finest meshes. (`always`: the lasting part,
-- when the figure is made; the request to load the textures now is made again whenever
-- the screen opens.)
local function invDetail(fig, always)
    for _, a in ipairs(fig and fig.actors or {}) do
        pcall(function()
            local m = a.SkeletalMeshComponent
            if not valid(m) then return end
            if always then
                m:SetForcedLOD(1)                   -- (1 is the finest)
                m.bForceMipStreaming = true
                m.StreamingDistanceMultiplier = 20
            end
            m:PrestreamTextures(30, true, 0)
        end)
    end
end

Core.onTick(function()
    local now = os.clock()
    local player = World.player()
    local open = false
    if player then pcall(function() open = player.inventoryOpen == true end) end
    if open ~= invWasOpen then
        invWasOpen = open
        if open and invFigure then invDetail(invFigure.fig, false) end
    end
    if now - invCheck < (open and 0.1 or 0.5) then return end
    invCheck = now
    if not player then
        invFigure = nil
        return
    end
    local actor = Core.find(INV_CHARACTER)
    if not valid(actor) then return end
    local model = nil
    pcall(function() model = actor.Player_FullRigged end)
    if not valid(model) then return end
    pcall(function() if model:IsVisible() then model:SetVisibility(false, false) end end)
    load()
    local look = Look.current()
    local key = table.concat({ look.body or "", look.head or "", look.hair or "", look.hat or "", look.glasses or "", look.beard or "", look.watch or "" }, "|")
    local modelAt = model:GetAddress()
    if invFigure and invFigure.key == key and invFigure.modelAt == modelAt and valid(invFigure.fig.body) then return end
    if invFigure then pcall(Avatar.destroyStandIn, invFigure.fig) end
    invFigure = nil
    local ok, e = pcall(function()
        local at = model:K2_GetComponentLocation()
        local yaw = model:K2_GetComponentRotation().Yaw + 90       -- the model faces +Y at yaw 0
        -- (standing calmly: the citizens' standing loop without the look over the shoulder)
        local fig = Avatar.buildStandIn(look, at.X, at.Y, at.Z + 88, yaw, nil, "calm")
        if not fig then return end
        -- lit from above and a little behind (the camera looks at its back), itself only
        pcall(function()
            local cam = actor.SceneCaptureComponent2D:K2_GetComponentLocation()
            local dx, dy = cam.X - at.X, cam.Y - at.Y
            local n = math.max(1, math.sqrt(dx * dx + dy * dy))
            Avatar.lightFromAbove(fig, at.X + dx / n * 50, at.Y + dy / n * 50, at.Z + 230, 420, 6000)
        end)
        -- (only the game's camera for the screen sees it: its pose must move all the same)
        pcall(function()
            for _, a in ipairs(fig.actors or {}) do a.SkeletalMeshComponent.VisibilityBasedAnimTickOption = 0 end
        end)
        invFigure = { fig = fig, key = key, modelAt = modelAt }
        invDetail(fig, true)
    end)
    if not ok then log("Inventory figure: %s", tostring(e)) end
end)

World.listen("stop", function() invFigure = nil end)
function Look.inventoryFigure() return invFigure and invFigure.fig end      -- (for test scripts)

---------------------------------------------------------------- upkeep

local traitsFor = nil
local traitsSettled = nil       -- false while a guest's own level and skills are not in place yet
local startedAt = 0
local worldAt = nil
local ownedFor = nil

-- A new game's first call (Eddie) comes while the player is still on the "who are you"
-- screen, and it comes again and again until it is answered. Until the choice is made the
-- phone makes no sound (ring or vibration: both are the phone's one sound component); the
-- call itself is the game's and goes on, so the phone rings at its next ring (every three
-- seconds) once the choice is made.
local ringQuiet = nil       -- { phone address, the volume it had }
local function tendRing(player, quiet)
    local ok, e = pcall(function()
        local phone = player.phoneRef
        if not valid(phone) or not valid(phone.ringTone) then
            ringQuiet = nil
            return
        end
        local address = phone:GetAddress()
        if ringQuiet and ringQuiet.phone ~= address then ringQuiet = nil end
        if quiet and not ringQuiet then
            local was = tonumber(phone.ringTone.VolumeMultiplier) or 1
            ringQuiet = { phone = address, was = was > 0 and was or 1 }
            phone.ringTone:SetVolumeMultiplier(0)
            log("Look: the phone is silent until the player has chosen who they are")
        elseif not quiet and ringQuiet then
            phone.ringTone:SetVolumeMultiplier(ringQuiet.was)
            ringQuiet = nil
            log("Look: the phone rings again")
        end
    end)
    if not ok then log("Look: the phone's ring: %s", tostring(e)) end
end
function Look.ringQuiet() return ringQuiet ~= nil end       -- (for test scripts)

Core.every(1, function()
    local player = World.player()
    -- A host is asked who they are as soon as they have a lobby, not only once somebody
    -- has joined.
    if not player then
        traitsFor = nil
        return
    end
    load()
    -- A new character object after every load: who the player is in this save, then the
    -- traits again. (The "who are you" screen and the traits are there in single player
    -- too; the shops and the wardrobe screen with SoloExtras.)
    local address = player:GetAddress()
    if address ~= worldAt then
        worldAt, startedAt = address, os.clock()
    end
    local mine = Guests.ready() and Guests.self() or nil
    if Guests.ready() and ownedFor ~= address then
        ownedFor = address
        local before = Look.current().body
        applyOwned(mine)
        -- (a record of before, with the choice only: what was owned then goes into it)
        if mine and type(mine.owned) ~= "table" then syncSelf() end
        save()
        if Look.current().body ~= before then Look.announce() end
    end
    if mine and characterById[mine.character] and mine.character ~= state.character then
        state.character = mine.character
        traitsFor = nil
    end
    -- A guest's own level and skills are put in place a few seconds after the join
    -- (coop/story.lua). Until then the game holds the host's, and what the character can do
    -- (stamina, speed, pockets, lock picking, stealth) was worked out from those: it is
    -- worked out again once the guest's own are there (reported with v0.15.1: after a
    -- rejoin a guest's skills "look identical to the host's").
    local story = package.loaded["coop.story"]
    local settled = World.role ~= "guest" or (story ~= nil and story.isReady() == true)
    if settled ~= traitsSettled then
        traitsSettled = settled
        if settled then traitsFor = nil end
    end
    if traitsFor ~= address and Core.find("statisticsManager_C") then
        if Look.applyTraits() then traitsFor = address end
    elseif Look.pocketsKept > 0 then
        -- a pocket that is only still there because of what was in it: gone once it is empty
        local c = character()
        local defaults = StaticFindObject("/Game/Player/playerCharacterBP.Default__playerCharacterBP_C")
        if valid(defaults) then
            local _, kept = pocketBase(player, defaults, c)
            if kept ~= Look.pocketsKept then Look.applyTraits() end
        end
    end
    do
        -- (as below: who has not chosen yet; a test copy that keeps its choice has)
        local choosing = Look.page == "start" or (Guests.ready() and Guests.self() == nil and not World.joining and not World.gone and not Core.server
            and not (Core.instance and not Look.debug and state.characterPicked))
        tendRing(player, choosing == true)
    end
    if not Hud.ready() then return end
    if World.extras() then ensureMarker() end
    if scr then pcall(showMirror) end
    local t = Look.takeover
    if scr or (t and t.isOpen()) then
        Hud.prompt(nil)
    elseif t and t.near() then
        Hud.prompt(t.prompt())
    elseif Look.atClerk() then
        local talking = false
        pcall(function() talking = player.inDialogue == true end)
        if talking then Hud.prompt(nil) else Hud.prompt(key("WardrobeKey"), "Talk") end
    elseif World.extras() and Look.atWardrobe() then
        -- under the game's own "change clothes (wardrobe)"
        Hud.prompt(key("WardrobeKey"), "view wardrobe (outfits)", true)
    else
        Hud.prompt(nil)
        -- Once in every save (and for a guest once in every world): who the player is.
        local undecided = Guests.ready() and Guests.self() == nil and not World.joining and not World.gone
        -- (A test copy started with -ddsmp=NAME keeps the choice it has: nobody is there to
        -- answer, and the open screen would hold its player where the screen opened.)
        if undecided and Core.instance and not Look.debug and state.characterPicked then
            syncSelf()
            undecided = false
        end
        if undecided and not Core.server and not Screen.current and os.clock() - startedAt > 8 and Core.find("statisticsManager_C") then
            local q = Core.find("questManager_C")
            local busy = false
            pcall(function() busy = q.tipActive == true end)
            -- not on top of the pause menu (the lobby is made from there)
            pcall(function() busy = busy or Core.statics():IsGamePaused(player) == true end)
            if not busy then Look.openStart() end
        end
    end
end)

World.listen("start", function()
    startedAt = os.clock()
    load()
    Avatar.looks = {}
    Core.after(4, function() Look.announce() end)
end)

-- The host tells a newcomer how everybody already there looks.
World.listen("peer", function(id)
    Net.send("look", describe(nil), id)
    for other, l in pairs(Avatar.looks) do
        if other ~= id and type(l) == "table" then
            local hair, hairColour = split(l.hair)
            local beard, beardColour = split(l.beard)
            Net.send("look", { b = l.body, h = l.head, r = hair, c = l.hat or "", g = l.glasses or "", w = beard, hc = hairColour, bc = beardColour, wt = l.watch or "", p = other }, id)
        end
    end
end)

World.listen("stop", function()
    traitsFor = nil
    closeScreen()
end)

-- The kind of character whose traits are on the player right now (nil outside co-op).
function Look.active()
    local player = World.player()
    if not player or traitsFor ~= player:GetAddress() then return nil end
    return character()
end

function Look.state() return state end

-- coop/traits.lua: one more lock forced by this player, ever (kept in the player's file so
-- that "every second one" does not start again with every session). Returns the count.
function Look.forcedLock()
    load()
    state.forced = (tonumber(state.forced) or 0) + 1
    save()
    return state.forced
end
Look.OUTFITS, Look.CHARACTERS, Look.SHOP = OUTFITS, CHARACTERS, SHOP
Look.HAIR_COLOURS, Look.BARBER_PRICE, Look.SETS = HAIR_COLOURS, BARBER_PRICE, SETS

return Look
