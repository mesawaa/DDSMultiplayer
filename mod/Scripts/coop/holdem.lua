-- Texas hold'em, no limit: the rules of a hand at a table of up to four seats, and how the
-- house player decides. Nothing in this file touches the game (coop/poker.lua runs it), so
-- it can be tried on its own: Holdem.selfTest().
--
-- A card is rank * 10 + suit as at the blackjack table: rank 1 (ace) to 13 (king), suit 1
-- to 4. Seats are numbered the way the deal goes round the table.

local Holdem = {}

---------------------------------------------------------------- the value of a hand

local function high(card)
    local r = card // 10
    return r == 1 and 14 or r
end

local function pack(category, a, b, c, d, e)
    return ((((category * 15 + (a or 0)) * 15 + (b or 0)) * 15 + (c or 0)) * 15 + (d or 0)) * 15 + (e or 0)
end

-- The highest card of five in a row among the ranks in `has` (the ace also counts as one).
local function straightTop(has)
    local run = 0
    for r = 14, 2, -1 do
        if has[r] then
            run = run + 1
            if run == 5 then return r + 4 end
        else
            run = 0
        end
    end
    if run == 4 and has[14] then return 5 end
    return nil
end

-- The best five of up to seven cards as one number (the higher number is the better hand),
-- and its kind: 0 high card, 1 pair, 2 two pair, 3 three of a kind, 4 straight, 5 flush,
-- 6 full house, 7 four of a kind, 8 straight flush.
function Holdem.score(cards)
    local count = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    local suitCount = { 0, 0, 0, 0 }
    for _, c in ipairs(cards) do
        local r, s = high(c), c % 10
        count[r] = count[r] + 1
        suitCount[s] = suitCount[s] + 1
    end
    local flush = nil
    for s = 1, 4 do if suitCount[s] >= 5 then flush = s end end
    local suited = nil
    if flush then
        suited = {}
        local has = {}
        for _, c in ipairs(cards) do
            if c % 10 == flush then
                suited[#suited + 1] = high(c)
                has[high(c)] = true
            end
        end
        local top = straightTop(has)
        if top then return pack(8, top), 8 end
    end
    local four, threes, twos = nil, {}, {}
    for r = 14, 2, -1 do
        local n = count[r]
        if n == 4 then four = four or r
        elseif n == 3 then threes[#threes + 1] = r
        elseif n == 2 then twos[#twos + 1] = r end
    end
    local function rest(n, skip1, skip2)
        local out = {}
        for r = 14, 2, -1 do
            if count[r] > 0 and r ~= skip1 and r ~= skip2 then
                out[#out + 1] = r
                if #out == n then break end
            end
        end
        return out
    end
    if four then
        return pack(7, four, rest(1, four)[1]), 7
    end
    if threes[1] and (threes[2] or twos[1]) then
        local pair = threes[2]
        if twos[1] and (not pair or twos[1] > pair) then pair = twos[1] end
        return pack(6, threes[1], pair), 6
    end
    if suited then
        table.sort(suited, function(a, b) return a > b end)
        return pack(5, suited[1], suited[2], suited[3], suited[4], suited[5]), 5
    end
    local has = {}
    for r = 2, 14 do has[r] = count[r] > 0 end
    local top = straightTop(has)
    if top then return pack(4, top), 4 end
    if threes[1] then
        local k = rest(2, threes[1])
        return pack(3, threes[1], k[1], k[2]), 3
    end
    if twos[2] then
        return pack(2, twos[1], twos[2], rest(1, twos[1], twos[2])[1]), 2
    end
    if twos[1] then
        local k = rest(3, twos[1])
        return pack(1, twos[1], k[1], k[2], k[3]), 1
    end
    local k = rest(5)
    return pack(0, k[1], k[2], k[3], k[4], k[5]), 0
end

local ONE = { [2] = "TWO", [3] = "THREE", [4] = "FOUR", [5] = "FIVE", [6] = "SIX", [7] = "SEVEN", [8] = "EIGHT", [9] = "NINE",
    [10] = "TEN", [11] = "JACK", [12] = "QUEEN", [13] = "KING", [14] = "ACE" }
local MANY = { [2] = "TWOS", [3] = "THREES", [4] = "FOURS", [5] = "FIVES", [6] = "SIXES", [7] = "SEVENS", [8] = "EIGHTS", [9] = "NINES",
    [10] = "TENS", [11] = "JACKS", [12] = "QUEENS", [13] = "KINGS", [14] = "ACES" }

-- What a hand is called.
function Holdem.name(cards)
    local score, kind = Holdem.score(cards)
    local b = (score // 3375) % 15
    local a = (score // 50625) % 15
    if kind == 8 then return a == 14 and "A ROYAL FLUSH" or ("A STRAIGHT FLUSH, " .. ONE[a] .. " HIGH") end
    if kind == 7 then return "FOUR " .. MANY[a] end
    if kind == 6 then return "A FULL HOUSE, " .. MANY[a] .. " OVER " .. MANY[b] end
    if kind == 5 then return "A FLUSH, " .. ONE[a] .. " HIGH" end
    if kind == 4 then return "A STRAIGHT, " .. ONE[a] .. " HIGH" end
    if kind == 3 then return "THREE " .. MANY[a] end
    if kind == 2 then return "TWO PAIR, " .. MANY[a] .. " AND " .. MANY[b] end
    if kind == 1 then return "A PAIR OF " .. MANY[a] end
    return (ONE[a] or "NOTHING") .. " HIGH"
end

---------------------------------------------------------------- a table

local Table = {}
Table.__index = Table

-- opts: seats (how many, 4), sb, bb, random (a function like math.random)
function Holdem.new(opts)
    opts = opts or {}
    local t = setmetatable({}, Table)
    t.n = opts.seats or 4
    t.sb, t.bb = opts.sb or 25, opts.bb or 50
    t.random = opts.random or math.random
    t.seats = {}
    for i = 1, t.n do t.seats[i] = { stack = 0, bet = 0, total = 0 } end
    t.button, t.hand, t.phase, t.turn = 0, 0, "idle", nil
    t.board, t.current, t.lastRaise = {}, 0, t.bb
    return t
end

function Table:sit(i, id, stack)
    local s = self.seats[i]
    if not s or s.id ~= nil or s.leaving then return false end
    s.id, s.stack = id, math.max(0, math.floor(stack or 0))
    s.inHand, s.folded, s.allin, s.cards, s.bet, s.total, s.last, s.won = false, false, false, nil, 0, 0, nil, nil
    return true
end

function Table:add(i, amount)
    local s = self.seats[i]
    if not s or s.id == nil or s.leaving then return false end
    s.stack = s.stack + math.max(0, math.floor(amount or 0))
    return true
end

-- Who can be dealt in.
function Table:ready()
    local out = {}
    for i, s in ipairs(self.seats) do
        if s.id ~= nil and not s.leaving and s.stack > 0 then out[#out + 1] = i end
    end
    return out
end

local function after(t, i, fits)
    for k = 1, t.n do
        local j = (i - 1 + k) % t.n + 1
        if fits(t.seats[j], j) then return j end
    end
    return nil
end

local function put(s, amount)
    amount = math.min(amount, s.stack)
    s.stack = s.stack - amount
    s.bet = s.bet + amount
    s.total = s.total + amount
    if s.stack == 0 then s.allin = true end
    return amount
end

local function dealt(s) return s.inHand end
local function inPlay(s) return s.inHand and not s.folded end
local function canAct(s) return s.inHand and not s.folded and not s.allin end

function Table:count(fits)
    local n = 0
    for _, s in ipairs(self.seats) do if fits(s) then n = n + 1 end end
    return n
end

-- Everything that has been put in during this hand.
function Table:pot()
    local sum = 0
    for _, s in ipairs(self.seats) do sum = sum + (s.total or 0) end
    return sum
end

-- Deals a new hand. False when fewer than two seats have chips.
function Table:start()
    if self.phase ~= "idle" then return false end
    local ready = self:ready()
    if #ready < 2 then return false end
    self.hand = self.hand + 1
    for _, s in ipairs(self.seats) do
        s.inHand, s.folded, s.allin, s.cards, s.bet, s.total = false, false, false, nil, 0, 0
        s.acted, s.noRaise, s.last, s.won, s.name = false, false, nil, nil, nil
    end
    for _, i in ipairs(ready) do self.seats[i].inHand = true end
    self.button = after(self, self.button, dealt)
    -- the cards
    local deck = {}
    for rank = 1, 13 do for suit = 1, 4 do deck[#deck + 1] = rank * 10 + suit end end
    for i = #deck, 2, -1 do
        local j = self.random(i)
        deck[i], deck[j] = deck[j], deck[i]
    end
    self.deck = deck
    for _ = 1, 2 do
        local i = self.button
        for _ = 1, #ready do
            i = after(self, i, dealt)
            local s = self.seats[i]
            s.cards = s.cards or {}
            s.cards[#s.cards + 1] = table.remove(deck)
        end
    end
    -- the blinds: with two players the button has the small one and speaks first
    local small, big
    if #ready == 2 then
        small = self.button
        big = after(self, small, dealt)
    else
        small = after(self, self.button, dealt)
        big = after(self, small, dealt)
    end
    self.small, self.big = small, big
    put(self.seats[small], self.sb)
    put(self.seats[big], self.bb)
    self.seats[small].last, self.seats[big].last = "SMALL BLIND", "BIG BLIND"
    self.board, self.result, self.open = {}, nil, false
    self.current, self.lastRaise = self.bb, self.bb
    self.phase = "preflop"
    self.turn = after(self, big, function(s) return canAct(s) end)
    self:settleStreet()
    return true
end

-- What the seat whose turn it is may do: call (what it costs to stay in), check (true when
-- nothing is to pay), raise (true when a raise is allowed), minTo and maxTo (the lowest and
-- highest total bet of this round a raise may go to).
function Table:legal(i)
    if self.turn ~= i then return nil end
    local s = self.seats[i]
    local owed = math.max(0, self.current - s.bet)
    local out = { call = math.min(owed, s.stack), check = owed == 0 }
    local others = 0
    for j, o in ipairs(self.seats) do if j ~= i and canAct(o) then others = others + 1 end end
    out.maxTo = s.bet + s.stack
    -- a raise goes to at least twice what is to call (and never by less than the raise before)
    out.minTo = math.min(out.maxTo, math.max(self.current + self.lastRaise, self.current * 2))
    out.raise = not s.noRaise and s.stack > owed and others > 0
    return out
end

-- Is the betting of this round over? If so, on to the next cards (or the end).
function Table:settleStreet()
    if self:count(inPlay) <= 1 then return self:finish() end
    local t = self.turn
    if t then
        local s = self.seats[t]
        if canAct(s) and (not s.acted or s.bet < self.current) then
            -- nobody else can answer, and nothing is owed: no decision to make
            if not (s.bet >= self.current and self:count(canAct) <= 1) then return end
        end
    end
    local nextSeat = after(self, t or self.button, function(s) return canAct(s) and (not s.acted or s.bet < self.current) end)
    if nextSeat then
        local s = self.seats[nextSeat]
        if not (s.bet >= self.current and self:count(canAct) <= 1) then
            self.turn = nextSeat
            return
        end
    end
    -- the round is over
    self.turn = nil
    for _, s in ipairs(self.seats) do s.bet, s.acted, s.noRaise = 0, false, false end
    self.current, self.lastRaise = 0, self.bb
    if self:count(canAct) <= 1 then self.open = true end       -- no more betting: the hands are turned over
    self.pending = true
end

-- After a round of betting: the next cards, or the showdown. (Called by whoever runs the
-- table, so that the cards can come with a pause.)
function Table:proceed()
    if not self.pending then return false end
    self.pending = false
    if self.phase == "river" then return self:finish() end
    local deck = self.deck
    if self.phase == "preflop" then
        self.phase = "flop"
        for _ = 1, 3 do self.board[#self.board + 1] = table.remove(deck) end
    elseif self.phase == "flop" then
        self.phase = "turn"
        self.board[#self.board + 1] = table.remove(deck)
    else
        self.phase = "river"
        self.board[#self.board + 1] = table.remove(deck)
    end
    for _, s in ipairs(self.seats) do if s.inHand and not s.folded and not s.allin then s.last = nil end end
    if self:count(canAct) <= 1 then
        self.pending = true
        return true
    end
    self.turn = after(self, self.button, function(s) return canAct(s) end)
    return true
end

-- kind: "fold", "check", "call" or "raise" (amount: the total bet of this round to raise to).
function Table:act(i, kind, amount)
    local legal = self:legal(i)
    if not legal then return false end
    local s = self.seats[i]
    if kind == "check" then
        if not legal.check then return false end
        s.last = "CHECK"
    elseif kind == "fold" then
        s.folded = true
        s.last = "FOLD"
    elseif kind == "call" then
        if legal.check then return false end
        put(s, legal.call)
        s.last = s.allin and "ALL IN" or "CALL"
    elseif kind == "raise" then
        if not legal.raise then return false end
        local to = math.floor(tonumber(amount) or 0)
        if to < legal.minTo then to = legal.minTo end
        if to > legal.maxTo then to = legal.maxTo end
        if to <= self.current then return false end
        local by = to - self.current
        local opened = self.current == 0
        put(s, to - s.bet)
        if by >= self.lastRaise then
            self.lastRaise = by
            for j, o in ipairs(self.seats) do if j ~= i then o.acted, o.noRaise = false, false end end
        else
            -- all in for less than a raise: the others may only call or fold
            for j, o in ipairs(self.seats) do
                if j ~= i and o.acted then o.acted, o.noRaise = false, true end
            end
        end
        self.current = to
        s.last = s.allin and "ALL IN" or (opened and "BET" or "RAISE")
    else
        return false
    end
    s.acted = true
    self:settleStreet()
    return true
end

-- A player gets up. In the middle of a hand that is a fold: everything they have put in
-- stays in the pot. Returns the chips they take along.
function Table:leave(i)
    local s = self.seats[i]
    if not s or s.id == nil then return 0 end
    local chips = s.stack
    s.stack = 0
    if s.inHand and self.phase ~= "idle" and self.phase ~= "showdown" then
        s.folded, s.leaving, s.last = true, true, "FOLD"
        s.id = nil
        if self.turn == i then
            s.acted = true
            self:settleStreet()
        elseif self:count(inPlay) <= 1 then
            self:finish()
        end
    else
        local total, inHand, folded = s.total, s.inHand, s.folded
        self.seats[i] = { stack = 0, bet = 0, total = 0 }
        if self.phase == "showdown" then
            -- (the hand is being shown: what they put in stays on the books until it is cleared)
            self.seats[i].total, self.seats[i].inHand, self.seats[i].folded, self.seats[i].leaving = total, inHand, folded, true
        end
    end
    return chips
end

-- The end of a hand: the pots go to the best hands.
function Table:finish()
    self.turn, self.pending = nil, false
    local seats = self.seats
    -- what nobody matched goes back
    local top, second, topSeat = 0, 0, nil
    for _, s in ipairs(seats) do
        if s.inHand then
            if s.total > top then
                second, top, topSeat = top, s.total, s
            elseif s.total > second then
                second = s.total
            end
        end
    end
    -- (not to somebody who got up in the middle of the hand: that is a fold, and all they
    -- had put in stays in the pot)
    if topSeat and top > second and not topSeat.folded then
        topSeat.stack = topSeat.stack + (top - second)
        topSeat.total = second
        if topSeat.stack > 0 then topSeat.allin = false end
    end
    local live = {}
    for i, s in ipairs(seats) do if inPlay(s) then live[#live + 1] = i end end
    local showdown = #live > 1
    local scores = {}
    if showdown then
        while #self.board < 5 do self.board[#self.board + 1] = table.remove(self.deck) end
        for _, i in ipairs(live) do
            local seven = { seats[i].cards[1], seats[i].cards[2] }
            for _, c in ipairs(self.board) do seven[#seven + 1] = c end
            scores[i] = Holdem.score(seven)
            seats[i].name = Holdem.name(seven)
        end
    end
    -- one pot for every level somebody is all in at
    local levels, seen = {}, {}
    for _, i in ipairs(live) do
        local v = seats[i].total
        if v > 0 and not seen[v] then
            seen[v] = true
            levels[#levels + 1] = v
        end
    end
    table.sort(levels)
    local pots, before, counted = {}, 0, 0
    for _, level in ipairs(levels) do
        local amount, eligible = 0, {}
        for i, s in ipairs(seats) do
            if s.inHand then
                amount = amount + math.max(0, math.min(s.total, level) - before)
                if not s.folded and s.total >= level then eligible[#eligible + 1] = i end
            end
        end
        if amount > 0 then pots[#pots + 1] = { amount = amount, eligible = eligible } end
        counted = counted + amount
        before = level
    end
    local left = self:pot() - counted
    if left > 0 then
        if #pots == 0 then pots[1] = { amount = 0, eligible = live } end
        pots[#pots].amount = pots[#pots].amount + left
    end
    local result = { showdown = showdown, pots = {}, won = {} }
    for _, pot in ipairs(pots) do
        local best, winners = -1, {}
        for _, i in ipairs(pot.eligible) do
            local v = scores[i] or 0
            if v > best then
                best, winners = v, { i }
            elseif v == best then
                winners[#winners + 1] = i
            end
        end
        if #winners > 0 then
            local share = pot.amount // #winners
            local odd = pot.amount - share * #winners
            -- the odd chip goes to the first winner after the button
            local first = after(self, self.button, function(_, j)
                for _, w in ipairs(winners) do if w == j then return true end end
                return false
            end)
            for _, w in ipairs(winners) do
                local got = share + ((w == first) and odd or 0)
                seats[w].stack = seats[w].stack + got
                seats[w].won = (seats[w].won or 0) + got
                result.won[w] = (result.won[w] or 0) + got
            end
            result.pots[#result.pots + 1] = { amount = pot.amount, winners = winners }
        end
    end
    for _, s in ipairs(seats) do if s.stack > 0 then s.allin = false end end
    self.result = result
    self.phase = "showdown"
    return true
end

-- The table is cleared for the next hand.
function Table:clear()
    if self.phase ~= "showdown" then return false end
    for i, s in ipairs(self.seats) do
        if s.leaving then
            self.seats[i] = { stack = 0, bet = 0, total = 0 }
        else
            s.inHand, s.folded, s.allin, s.cards, s.bet, s.total = false, false, false, nil, 0, 0
            s.acted, s.noRaise, s.last, s.won, s.name = false, false, nil, nil, nil
        end
    end
    self.board, self.result, self.open, self.turn, self.pending = {}, nil, false, nil, false
    self.current, self.lastRaise = 0, self.bb
    self.phase = "idle"
    return true
end

---------------------------------------------------------------- the house player

-- How good two cards are before the flop (Bill Chen's count: about -1 to 20).
function Holdem.startValue(a, b)
    local ra, rb = high(a), high(b)
    if rb > ra then ra, rb = rb, ra end
    local function points(r)
        if r == 14 then return 10 elseif r == 13 then return 8 elseif r == 12 then return 7 elseif r == 11 then return 6 end
        return r / 2
    end
    local v = points(ra)
    if ra == rb then return math.max(5, v * 2) end
    if a % 10 == b % 10 then v = v + 2 end
    local gap = ra - rb - 1
    if gap == 1 then v = v - 1 elseif gap == 2 then v = v - 2 elseif gap == 3 then v = v - 4 elseif gap >= 4 then v = v - 5 end
    if gap <= 1 and ra < 12 then v = v + 1 end
    return v
end

-- The share of the pot two cards win on average against `opponents` unknown hands, by
-- dealing the rest out `rounds` times.
function Holdem.equity(hole, board, opponents, rounds, random)
    random = random or math.random
    local used = {}
    for _, c in ipairs(hole) do used[c] = true end
    for _, c in ipairs(board) do used[c] = true end
    local deck = {}
    for rank = 1, 13 do
        for suit = 1, 4 do
            local c = rank * 10 + suit
            if not used[c] then deck[#deck + 1] = c end
        end
    end
    local need = (5 - #board) + opponents * 2
    local won = 0
    local mine, theirs = {}, {}
    for _ = 1, rounds do
        for k = 1, need do
            local j = k + random(#deck - k + 1) - 1
            deck[k], deck[j] = deck[j], deck[k]
        end
        local n = 0
        mine[1], mine[2] = hole[1], hole[2]
        for k, c in ipairs(board) do mine[2 + k], theirs[2 + k] = c, c end
        for k = #board + 1, 5 do
            n = n + 1
            mine[2 + k], theirs[2 + k] = deck[n], deck[n]
        end
        local my = Holdem.score(mine)
        local best, ties = true, 0
        for _ = 1, opponents do
            theirs[1], theirs[2] = deck[n + 1], deck[n + 2]
            n = n + 2
            local v = Holdem.score(theirs)
            if v > my then
                best = false
                break
            elseif v == my then
                ties = ties + 1
            end
        end
        if best then won = won + 1 / (ties + 1) end
    end
    return won / rounds
end

-- What the house player at seat i does now: kind, amount (see Table:act). He plays many
-- hands, pays too often to see the next card and likes a bluff: a player who waits for good
-- cards and bets them takes his money in the long run, and he can still win any one hand.
function Holdem.decide(t, i)
    local legal = t:legal(i)
    if not legal then return nil end
    local s = t.seats[i]
    local random = t.random
    local function chance(p) return random(1000) <= p * 1000 end
    local pot = t:pot()
    local owed = legal.call
    local bb = t.bb
    local function raiseTo(to)
        to = math.floor(to / 25 + 0.5) * 25
        if to >= legal.maxTo * 0.8 then to = legal.maxTo end
        return "raise", math.max(legal.minTo, math.min(legal.maxTo, to))
    end
    local opponents = 0
    for j, o in ipairs(t.seats) do if j ~= i and inPlay(o) then opponents = opponents + 1 end end
    opponents = math.max(1, opponents)

    if t.phase == "preflop" then
        local v = Holdem.startValue(s.cards[1], s.cards[2])
        if opponents > 1 then v = v - 1 end
        local raised = t.current > bb
        if not raised then
            if legal.raise and (v >= 7 or (v >= 5 and chance(0.5)) or chance(0.08)) then
                return raiseTo(bb * (2 + random(3) / 2))
            end
            if legal.check then return "check" end
            if v >= 2 or chance(0.3) then return "call" end
            return "fold"
        end
        -- somebody raised
        local price = owed / math.max(1, s.stack + s.bet)       -- how much of what he has it costs
        if v >= 12 or (v >= 10 and chance(0.6)) then
            if legal.raise and chance(0.75) then return raiseTo(t.current * 3) end
            return "call"
        end
        if price > 0.5 then
            if v >= 9 then return "call" end
            return "fold"
        end
        if price > 0.2 then
            if v >= 7 then return "call" end
            return "fold"
        end
        if v >= 4 or (v >= 2 and chance(0.5)) then return "call" end
        return "fold"
    end

    -- after the flop: what the cards are worth against hands he cannot see
    local eq = Holdem.equity(s.cards, t.board, opponents, 140, random)
    if owed == 0 then
        if legal.raise then
            if eq > 0.64 then
                if chance(0.82) then return raiseTo(t.current + pot * (0.5 + random(30) / 100)) end
            elseif eq > 0.5 then
                if chance(0.4) then return raiseTo(t.current + pot * (0.3 + random(20) / 100)) end
            elseif eq < 0.36 then
                if chance(t.phase == "river" and 0.14 or 0.24) then return raiseTo(t.current + pot * (0.5 + random(25) / 100)) end
            end
        end
        return "check"
    end
    -- a bet to answer: a big one means something
    local potBefore = pot - owed
    if owed > potBefore * 0.6 then eq = eq - 0.07 end
    if s.acted and s.bet > 0 then eq = eq - 0.08 end           -- raised after he bet
    local odds = owed / (pot + owed)
    local big = owed > (s.stack + s.bet) * 0.5
    if eq > 0.8 and legal.raise and chance(0.7) then
        return raiseTo(t.current + (pot + owed) * (0.6 + random(40) / 100))
    end
    if big then
        if eq > math.max(odds, 0.46) then return "call" end
        return "fold"
    end
    if eq > odds - 0.07 then return "call" end
    if legal.raise and owed < potBefore * 0.5 and chance(0.06) then
        return raiseTo(t.current + (pot + owed) * 0.8)
    end
    return "fold"
end

---------------------------------------------------------------- trying it out

-- Plays hands with every seat acting at random (or as the house player) and checks that no
-- chip appears or disappears. Returns a line to print, or raises an error.
function Holdem.selfTest(hands, random)
    random = random or math.random
    local function is(cards, kind, text)
        local _, k = Holdem.score(cards)
        if k ~= kind then error(text .. ": kind " .. tostring(k)) end
    end
    is({ 11, 131, 121, 111, 101, 22, 33 }, 8, "royal flush")
    is({ 11, 21, 31, 41, 51, 122, 133 }, 8, "wheel straight flush")
    is({ 91, 92, 93, 94, 11, 22, 33 }, 7, "four of a kind")
    is({ 91, 92, 93, 124, 121, 22, 23 }, 6, "full house")
    is({ 91, 92, 93, 124, 121, 122, 23 }, 6, "two threes")
    is({ 11, 31, 71, 91, 121, 122, 23 }, 5, "flush")
    is({ 11, 22, 33, 44, 51, 122, 123 }, 4, "wheel")
    is({ 101, 112, 123, 134, 11, 22, 23 }, 4, "broadway")
    is({ 91, 92, 93, 124, 111, 22, 43 }, 3, "three of a kind")
    is({ 91, 92, 43, 124, 121, 22, 23 }, 2, "two pair of three")
    is({ 91, 92, 43, 124, 111, 22, 73 }, 1, "pair")
    is({ 91, 132, 43, 124, 111, 22, 73 }, 0, "high card")
    if not (Holdem.score({ 11, 12, 53, 64, 71, 92, 103 }) > Holdem.score({ 131, 132, 53, 64, 71, 92, 103 })) then error("aces beat kings") end
    if not (Holdem.score({ 11, 132, 53, 54, 71, 92, 103 }) > Holdem.score({ 121, 132, 53, 54, 71, 92, 103 })) then error("kicker") end
    if Holdem.score({ 21, 32, 53, 54, 71, 92, 103, }) ~= Holdem.score({ 23, 34, 53, 54, 71, 92, 103 }) then error("board plays") end

    local t = Holdem.new({ random = random })
    local total = 0
    for i = 1, 4 do
        t:sit(i, "p" .. i, 2000 + i * 500)
        total = total + 2000 + i * 500
    end
    local played, showdowns, steps = 0, 0, 0
    for _ = 1, hands or 300 do
        -- somebody who lost everything buys in again; now and then somebody gets up and sits down
        for i = 1, 4 do
            local s = t.seats[i]
            if s.id ~= nil and s.stack == 0 then t:add(i, 1500) total = total + 1500 end
            if s.id == nil and not s.leaving then t:sit(i, "p" .. i, 1000) total = total + 1000 end
        end
        if t:start() then
            played = played + 1
            local guard = 0
            while t.phase ~= "showdown" do
                guard = guard + 1
                if guard > 400 then error("a hand that does not end, phase " .. t.phase) end
                if t.turn then
                    local i = t.turn
                    local legal = t:legal(i)
                    steps = steps + 1
                    if random(40) == 1 then
                        total = total - t:leave(i)
                    elseif i == 1 or random(3) == 1 then
                        local kind, amount = Holdem.decide(t, i)
                        if not t:act(i, kind, amount) then error("the house player's move was refused: " .. tostring(kind)) end
                    else
                        local pick = random(10)
                        local ok
                        if pick <= 1 and not legal.check then ok = t:act(i, "fold")
                        elseif pick <= 7 then ok = t:act(i, legal.check and "check" or "call")
                        elseif legal.raise then ok = t:act(i, "raise", legal.minTo + random(0, math.max(0, legal.maxTo - legal.minTo)) * (random(4) == 1 and 1 or 0) + random(0, 200))
                        else ok = t:act(i, legal.check and "check" or "call") end
                        if not ok then error("a legal move was refused") end
                    end
                elseif t.pending then
                    t:proceed()
                else
                    error("nobody's turn and nothing pending, phase " .. t.phase)
                end
                local sum = t.phase == "showdown" and 0 or t:pot()
                for _, s in ipairs(t.seats) do sum = sum + s.stack end
                if sum ~= total then error(string.format("chips: %d on the table, %d expected (hand %d, %s)", sum, total, t.hand, t.phase)) end
            end
            if t.result.showdown then showdowns = showdowns + 1 end
            local sum = 0
            for _, s in ipairs(t.seats) do sum = sum + s.stack end
            if sum ~= total then error(string.format("after hand %d: %d in the stacks, %d expected", t.hand, sum, total)) end
            t:clear()
        end
    end
    return string.format("%d hands, %d shown down, %d moves, every chip accounted for", played, showdowns, steps)
end

return Holdem
