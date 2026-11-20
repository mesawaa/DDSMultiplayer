-- DDS Multiplayer configuration. Edit, then restart the game.
return {
    -- Create a Steam lobby (if needed) and open the Steam invite dialog.
    HostInviteKey = "F6",
    -- Leave the current lobby.
    LeaveKey = "F7",
    -- Show lobby status as an in-game hint.
    StatusKey = "F8",
    -- Open the emote wheel: look at an emote and press the key again.
    EmoteKey = "V",
    -- Switch the strut walk on and off (slower, with a walk of its own).
    StrutKey = "CAPS_LOCK",
    -- The interaction key of the mod's own places: the clothes shop, the card room's door.
    WardrobeKey = "U",
    -- Open the MOD OPTIONS screen (also in the pause menu): skip a stuck story step, repairs, settings.
    ModOptionsKey = "F9",
    -- Show the other players on the map and the compass.
    ShowPlayersOnMap = true,

    -- More players, more to do (the host's settings count). For every player after the
    -- first: this much more of the street population ...
    PopulationPerExtraPlayer = 0.6,
    -- ... and this much more clients, found this much faster.
    ClientsPerExtraPlayer = 0.75,
    -- Eddie's order limit in a shared world: the limit your level gives is multiplied by
    -- OrderLimitMultiplier, plus OrderLimitPerExtraPlayer for every player after the first
    -- (two players: 1.5 + 0.5 = twice the normal limit). The debt stays shared.
    OrderLimitMultiplier = 1.5,
    OrderLimitPerExtraPlayer = 0.5,

    -- The highest level a player can reach; 0 = no highest level, which is how the game
    -- itself is (it goes on past 30: its story's last step asks for level 36 and it has
    -- achievements for levels 69 and 100). Set a number, 50 for example, to stop there.
    MaxLevel = 0,

    -- Police dogs. The game has them complete (a handler's dog smells a player who carries
    -- drugs from 800 units and sets the patrol on them) but never sends one out. With this
    -- on, a patrol comes with a dog at PoliceDogChance odds while a player near it has more
    -- exposure than PoliceDogExposure and a level above PoliceDogLevel (the numbers the
    -- game's own unused code has).
    PoliceDogs = true,
    PoliceDogChance = 0.3,
    PoliceDogExposure = 500,
    PoliceDogLevel = 7,

    -- The card room, the clothes shop and the wardrobe screen are there in single player
    -- too. false = only in co-op (hosting a lobby or in a shared world).
    SoloExtras = true,

    -- A woman's voice for the player's own sounds (jumping, landing, breathing, falling,
    -- coughing, taking a drug, climbing). The game's recordings are a man's; for a
    -- character who is a woman they are played this much higher (the climbing sounds by
    -- their own number) and at this share of their loudness. 1 = unchanged.
    FemaleVoicePitch = 1.2,
    FemaleVoiceClimbPitch = 1.3,
    FemaleVoiceVolume = 0.8,

    -- The card room in the night club's basement: blackjack for cash.
    Casino = true,
    -- true: the club lets everybody in at any hour, not only from 20:00 to 05:00.
    CardRoomAlwaysOpen = false,
    -- Seconds the lounge's sofas and tables stay away after a player gets up from the card
    -- table. (The player stands where a sofa is; the furniture comes back after this time
    -- and once the player has stepped out of it.)
    CardRoomStandUpSeconds = 3,
    -- Switch between the first-person view and a view from close behind your character.
    ThirdPersonKey = "P",
    -- false: an emote does not switch to that view by itself.
    EmoteThirdPerson = true,
    CasinoBets = { 50, 100, 250, 500, 1000, 2500 },

    -- Maximum players in a lobby (2-16).
    MaxPlayers = 4,

    -- While guests are in your world it is saved every this many minutes into a file of
    -- the mod's own (never one of your save slots). The multiplayer panel of the main
    -- menu can load it after a crash. 0 = off.
    AutosaveMinutes = 5,
    -- How many of those autosaves are kept (the oldest goes when a new one is written).
    -- CO-OP AUTOSAVES in the main menu's multiplayer panel lists them: any of them can be
    -- loaded, or copied into one of your save slots.
    AutosaveKeep = 10,

    -- Other players receive (amount * SharedXpMultiplier) of every shared XP gain.
    -- 1.0 = everyone gets the full amount.
    SharedXpMultiplier = 1.0,

    -- What to do with task XP the mod cannot classify: "shared" or "story".
    UnknownTaskXp = "shared",

    -- Show in-game hints for lobby events (joins, leaves, errors).
    InGameNotifications = true,
    -- Also show a hint each time a partner's XP is received (can be noisy).
    NotifyRemoteXp = false,

    -- Ignore single remote XP messages larger than this.
    MaxXpPerMessage = 100000,

    -- Co-op world sync. Set one to false to switch that part off (both players should
    -- use the same settings).
    Sync = {
        World = true,     -- guests can load the host's world
        Avatars = true,   -- see the other players
        Police = true,    -- see the policemen chasing the other players
        Time = true,      -- shared clock, sleeping/waiting skips time for everyone
        Doors = true,     -- doors opened or closed by one player move for everyone
        Objects = true,   -- containers, stashes, dead drops, apartments and other saved objects
        Homes = true,     -- a hideout rented by one player is rented and open for everybody; the "new apartments" hint only when there are new ones
        Tags = true,      -- a tag of your own (drawn) on the walls you spray; every wall shows its sprayer's tag in every game
        Spawns = true,    -- dropped items and cash, placed furniture; picking something up removes it for everyone
        Clients = true,   -- a client spawned for an order appears in both games, in the same spot
        Population = true, -- passers-by, police patrols and sample clients are the same people in both games
        Money = true,     -- bank account, messages, contacts
        Orders = true,    -- clients, orders, tasks, gang business
        Story = true,     -- every player has their own storyline; false = one storyline for everybody
        Managers = true,  -- remaining world state (exposure, sale areas, ...)
    },

    -- Each player does the story's steps in person. Only steps about the shared world that
    -- are already a fact (territory already unlocked and the like) complete by themselves.
    -- If a step ever turns out to be impossible in a world that is far ahead of you, set
    -- this to a number of minutes: a step somebody has already done in this world then
    -- completes for you after that long. 0 = never.
    StoryCatchUpMinutes = 0,

    -- Write every XP and sync decision to the log (ipc/mod.log). Useful when reporting a
    -- problem; leave off for normal play.
    Verbose = false,
}
