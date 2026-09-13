-- Auction Master Suite -- Database
-- Every managed market, every scan snapshot, and the trade ledger.
-- Money is always copper. Timestamps are always time() epoch seconds.
--
-- AuctionMasterSuiteDB.markets[itemID] = {
--     id, name, link, texture, quality, maxStack,
--     target,        -- the price you are defending, per unit
--     minMargin,     -- % margin required over your buy price (nil = global default)
--     tolerance,     -- % under target you leave alone (nil = global default)
--     maxInvest,     -- hard cap on gold tied up in this item (0 = no cap)
--     maxStock,      -- hard cap on units held (0 = no cap)
--     stack,         -- preferred posting stack size
--     duration,      -- 1/2/3
--     deposit,       -- measured deposit per unit at the preferred stack
--     added, lastScan,
-- }

local AMS = AuctionMasterSuite
local DB  = {}
AMS.DB = DB

local U        -- AMS.Util, bound on init

local MAX_LEDGER = 3000

-- Every per-realm table. Anything read as AMS.data.<name> MUST be listed here
-- or it is simply nil at runtime; the toccheck script cross-checks the two.
local DATA_TABLES = { "markets", "scans", "buys", "sales", "posts", "expiries",
                      "mailSeen", "pending", "auctions", "crafts", "recipes", "scrolls" }

-- Scope: settings live account-wide in AMS.db. Trading data lives per REALM in
-- AMS.data, shared by every character on that realm.
--
-- Per-realm rather than per-character because a market is a realm's market: the
-- watchlist, price history and books all describe one auction house, and your
-- bank alt's purchases are part of the same business as your main's. But WoW's
-- SavedVariables is per-account across every realm, so without this split a
-- character on a second realm would silently merge its prices into the first
-- one's history, which is worse than useless.
--
-- Only the bank snapshot and your listed auctions are genuinely per-character;
-- those stay in AMS.charDB.
function DB:OnInit()
    U = AMS.Util
    local db = AMS.db
    db.realms = db.realms or {}

    local realm = (GetRealmName and GetRealmName()) or "Unknown"

    -- Move pre-0.7 account-wide data under the realm it was gathered on.
    if not db._realmScoped then
        if db.markets or db.buys or db.sales then
            local moved = {}
            for _, k in ipairs(DATA_TABLES) do
                moved[k] = db[k]
                db[k] = nil
            end
            db.realms[realm] = moved
            AMS:Print("your books and price history now live per realm - the existing data has been filed under |cffffd070%s|r.", realm)
        end
        db._realmScoped = true
    end

    local r = db.realms[realm]
    if not r then r = {}; db.realms[realm] = r end
    for _, k in ipairs(DATA_TABLES) do r[k] = r[k] or {} end

    self.realmName = realm
    AMS.data = r
end

-- Every realm we have data for, for the Books scope selector.
function DB:Realms()
    local out = {}
    for name in pairs(AMS.db.realms or {}) do out[#out+1] = name end
    table.sort(out)
    return out
end

-- =============================================================================
-- Markets
-- =============================================================================

function DB:GetMarket(itemID)
    if not itemID then return nil end
    return AMS.data.markets[itemID]
end

function DB:AllMarkets()
    local out = {}
    for _, m in pairs(AMS.data.markets) do out[#out+1] = m end
    table.sort(out, function(a, b) return (a.name or "") < (b.name or "") end)
    return out
end

function DB:MarketCount()
    return U:Count(AMS.data.markets)
end

-- Creates the market if it does not exist yet. `info` comes from Util:ItemInfo.
function DB:EnsureMarket(info)
    if not info or not info.id then return nil end
    local m = AMS.data.markets[info.id]
    if m then
        -- refresh anything the client only knew later
        m.name    = info.name    or m.name
        m.link    = info.link    or m.link
        m.texture = info.texture or m.texture
        m.quality = info.quality or m.quality
        m.maxStack = info.maxStack or m.maxStack
        return m
    end

    local mk = AMS.db.market
    m = {
        id        = info.id,
        name      = info.name,
        link      = info.link,
        texture   = info.texture,
        quality   = info.quality,
        maxStack  = info.maxStack or 20,
        target    = 0,
        minMargin = nil,
        tolerance = nil,
        maxInvest = 0,
        maxStock  = 0,
        stack     = mk and mk.defaultStack or 1,
        duration  = mk and mk.defaultDuration or 3,
        buyMaxStack = mk and mk.buyMaxStack or 0,
        buyOrder    = mk and mk.buyOrder or "cheapest",
        deposit   = nil,
        added     = U:Now(),
        lastScan  = 0,
    }
    AMS.data.markets[info.id] = m
    AMS:Fire("MARKETS_CHANGED")
    return m
end

function DB:RemoveMarket(itemID)
    if not itemID then return end
    AMS.data.markets[itemID] = nil
    AMS.data.scans[itemID]   = nil
    AMS:Fire("MARKETS_CHANGED")
end

-- Adds by name. Works immediately if the client has the item cached, otherwise
-- the name is parked and resolved by the next scan that turns up a link.
function DB:AddMarketByName(name)
    if not name or name == "" then return nil end
    local info = U:ItemInfo(name)
    if info and info.id then
        local m = self:EnsureMarket(info)
        AMS:Print("watching |cffffd070%s|r.", info.name)
        return m
    end
    AMS.data.pending[name:lower()] = U:Now()
    AMS:Print("'%s' is not in your item cache yet. Use |cffffd070Search|r on the Watchlist tab to look it up "..
              "on the auction house, drag the item onto the Market tab's item slot, or shift-click it into the name box.", name)
    return nil
end

-- Called by the scanner when it learns a link for a name we were waiting on.
function DB:ResolvePending(name, link)
    if not name or not link then return end
    if not AMS.data.pending[name:lower()] then return end
    local info = U:ItemInfo(link)
    if not info then return end
    AMS.data.pending[name:lower()] = nil
    self:EnsureMarket(info)
    AMS:Print("watching |cffffd070%s|r (resolved from scan).", info.name)
end

-- Effective per-market settings, falling back to the global defaults.
function DB:MarginOf(m)
    local pct = m and m.minMargin
    if pct == nil then return AMS.Config:MinMargin() end
    return pct / 100
end

function DB:ToleranceOf(m)
    local pct = m and m.tolerance
    if pct == nil then return AMS.Config:Tolerance() end
    return pct / 100
end

-- Largest stack the buy queue will touch. 0 means any size.
function DB:MaxBuyStackOf(m)
    local n = m and m.buyMaxStack
    if n == nil then return AMS.db.market.buyMaxStack or 0 end
    return n
end

function DB:BuyOrderOf(m)
    return (m and m.buyOrder) or AMS.db.market.buyOrder or "cheapest"
end

-- =============================================================================
-- Scan history
-- =============================================================================

function DB:AddSnapshot(itemID, snap)
    if not itemID or not snap then return end
    local list = AMS.data.scans[itemID]
    if not list then list = {}; AMS.data.scans[itemID] = list end
    list[#list+1] = snap
    local cap = (AMS.db.history and AMS.db.history.maxScans) or 250
    while #list > cap do table.remove(list, 1) end

    local m = self:GetMarket(itemID)
    if m then m.lastScan = snap.t end
end

function DB:GetSnapshots(itemID)
    return AMS.data.scans[itemID] or {}
end

function DB:LastSnapshot(itemID)
    local list = self:GetSnapshots(itemID)
    return list[#list]
end

-- Daily rollup: { {day="09/08", min=, median=, supply=, mine=, n=}, ... } oldest first.
function DB:DailyHistory(itemID, days)
    local list = self:GetSnapshots(itemID)
    local buckets, order = {}, {}
    local cutoff = U:Now() - (days or 14) * 86400
    for _, s in ipairs(list) do
        if s.t >= cutoff then
            local key = date("%m/%d", s.t)
            local b = buckets[key]
            if not b then
                b = { day = key, min = s.min, median = 0, supply = 0, mine = 0, n = 0, t = s.t,
                      medianSum = 0 }
                buckets[key] = b
                order[#order+1] = b
            end
            if s.min and s.min > 0 and (b.min == 0 or s.min < b.min) then b.min = s.min end
            b.medianSum = b.medianSum + (s.median or 0)
            b.supply    = math.max(b.supply, s.supply or 0)
            b.mine      = math.max(b.mine, s.mine or 0)
            b.n         = b.n + 1
        end
    end
    for _, b in ipairs(order) do
        b.median = b.n > 0 and math.floor(b.medianSum / b.n) or 0
    end
    return order
end

-- Units of new supply appearing under your target, per hour, over the window.
-- Only positive deltas count: a drop means you (or someone) bought them out.
function DB:RefillRate(itemID)
    local list = self:GetSnapshots(itemID)
    if #list < 2 then return nil end
    local window = (AMS.db.history and AMS.db.history.refillWindow) or 86400
    local cutoff = U:Now() - window

    local added, firstT, lastT, prev = 0, nil, nil, nil
    for _, s in ipairs(list) do
        if s.t >= cutoff then
            if prev then
                local d = (s.underUnits or 0) - (prev.underUnits or 0)
                if d > 0 then added = added + d end
            end
            firstT = firstT or s.t
            lastT  = s.t
            prev   = s
        end
    end
    if not firstT or lastT - firstT < 600 then return nil end  -- need 10+ minutes of span
    local hours = (lastT - firstT) / 3600
    return added / hours, hours
end

-- =============================================================================
-- Ledger
-- =============================================================================

local function push(list, entry)
    list[#list+1] = entry
    while #list > MAX_LEDGER do table.remove(list, 1) end
end

function DB:RecordBuy(itemID, name, count, totalCopper)
    push(AMS.data.buys, {
        t = U:Now(), id = itemID, name = name,
        count = count, total = totalCopper,
        unit = count > 0 and math.floor(totalCopper / count) or totalCopper,
        who = AMS:PlayerName(),
    })
    AMS:Fire("LEDGER_CHANGED", itemID)
end

function DB:RecordPost(itemID, name, stack, unitPrice, deposit)
    push(AMS.data.posts, {
        t = U:Now(), id = itemID, name = name,
        stack = stack, unit = unitPrice,
        total = unitPrice * stack, deposit = deposit or 0,
        state = "listed",
        who = AMS:PlayerName(),
    })
    local m = self:GetMarket(itemID)
    if m and deposit and stack > 0 then
        m.deposit = math.floor(deposit / stack)   -- measured deposit per unit
    end
    AMS:Fire("LEDGER_CHANGED", itemID)
end

-- Sales come from the mailbox: we know the item name and the money received,
-- and we match back to the post record to recover the stack size.
function DB:RecordSale(itemID, name, count, netCopper, when, postRef)
    push(AMS.data.sales, {
        t = when or U:Now(), id = itemID, name = name,
        count = count, net = netCopper,
        unit = count > 0 and math.floor(netCopper / count) or netCopper,
        post = postRef,
        -- auction mail goes to the seller, so whoever read it posted it
        who = AMS:PlayerName(),
    })
    AMS:Fire("LEDGER_CHANGED", itemID)
end

function DB:RecordExpiry(itemID, name, count, depositLost, when)
    push(AMS.data.expiries, {
        t = when or U:Now(), id = itemID, name = name,
        count = count, deposit = depositLost or 0,
        who = AMS:PlayerName(),
    })
    AMS:Fire("LEDGER_CHANGED", itemID)
end

-- Marks the oldest still-listed post of this item whose expected proceeds are
-- closest to `money`, and returns it. Lets us recover the stack size of a sale.
function DB:MatchPost(itemID, name, money, cut)
    local best, bestDiff
    for i = 1, #AMS.data.posts do
        local p = AMS.data.posts[i]
        if p.state == "listed" and ((itemID and p.id == itemID) or (not itemID and p.name == name)) then
            -- sale mail money = stack price minus the AH cut, plus the deposit back
            local expected = math.floor(p.total * (1 - cut)) + (p.deposit or 0)
            local diff = math.abs(expected - (money or 0))
            if not bestDiff or diff < bestDiff then best, bestDiff = p, diff end
        end
    end
    -- accept the match only if it is within 2% or 1 gold, whichever is larger
    if best then
        local tolerance = math.max(10000, math.floor((money or 0) * 0.02))
        if bestDiff <= tolerance then return best end
    end
    return nil
end

-- =============================================================================
-- Aggregates
-- =============================================================================

-- =============================================================================
-- Your live auctions
-- =============================================================================
--
-- Kept per character but realm-wide, so an alt's listings survive logging out
-- and the totals cover your whole operation rather than whoever is standing at
-- the auctioneer. Only the character actually logged in can refresh their own.

-- Replaces that character's list outright. A refresh is a fresh truth, never a
-- merge - anything that has sold or expired since the last look must disappear.
function DB:SetOwnedAuctions(who, entries)
    if not who then return end
    AMS.data.auctions[who] = { t = U:Now(), list = entries or {} }
    AMS:Fire("AUCTIONS_CHANGED")
end

-- who = nil clears every character.
function DB:ClearOwnedAuctions(who)
    if who then
        AMS.data.auctions[who] = nil
    else
        AMS.data.auctions = {}
    end
    AMS:Fire("AUCTIONS_CHANGED")
end

-- Flattened across every character, newest scan data per character.
-- Returns rows, and a summary of what they add up to.
function DB:AllOwnedAuctions()
    local rows = {}
    local sum = {
        active = 0, activeUnits = 0, askValue = 0,
        sold = 0, soldGross = 0,
        bidOn = 0, bidValue = 0,
        expiringSoon = 0,
        characters = 0, oldest = nil,
    }

    for who, rec in pairs(AMS.data.auctions or {}) do
        sum.characters = sum.characters + 1
        if not sum.oldest or (rec.t or 0) < sum.oldest then sum.oldest = rec.t end
        for _, e in ipairs(rec.list or {}) do
            local row = {}
            for k, v in pairs(e) do row[k] = v end
            row.who = who
            row.scannedAt = rec.t
            rows[#rows+1] = row

            if e.sold then
                sum.sold      = sum.sold + 1
                -- a sold auction reports the winning amount in bid; fall back
                -- to the buyout for a straight buyout purchase
                sum.soldGross = sum.soldGross + math.max(e.bid or 0, e.buyout or 0)
            else
                sum.active      = sum.active + 1
                sum.activeUnits = sum.activeUnits + (e.count or 0)
                sum.askValue    = sum.askValue + (e.buyout or 0)
                if e.hasBidder and (e.bid or 0) > 0 then
                    sum.bidOn    = sum.bidOn + 1
                    sum.bidValue = sum.bidValue + e.bid
                end
                if (e.timeLeft or 4) <= 2 then sum.expiringSoon = sum.expiringSoon + 1 end
            end
        end
    end

    local cut = AMS.Config:Cut()
    sum.soldNet = math.floor(sum.soldGross * (1 - cut))
    return rows, sum
end

function DB:OwnedAuctionsAge(who)
    local rec = AMS.data.auctions[who]
    return rec and rec.t or nil
end

-- Every item the books know about: watched markets plus anything that has ever
-- been bought, sold, posted or expired.
--
-- The odds and ends you clear out of your bags belong in the books too. Noticing
-- that some random thing sells briskly is how you find the next market worth
-- running, and that only happens if it is in front of you.
function DB:LedgerItems()
    local seen, out = {}, {}
    local function note(id, name)
        if not id or seen[id] then return end
        seen[id] = true
        out[#out+1] = { id = id, name = name }
    end
    for id, m in pairs(AMS.data.markets) do note(id, m.name) end
    for _, e in ipairs(AMS.data.sales)    do note(e.id, e.name) end
    for _, e in ipairs(AMS.data.buys)     do note(e.id, e.name) end
    for _, e in ipairs(AMS.data.posts)    do note(e.id, e.name) end
    for _, e in ipairs(AMS.data.expiries) do note(e.id, e.name) end
    return out
end

-- Every character that has traded on this realm, for the Books scope selector.
function DB:Characters()
    local seen, out = {}, {}
    local function note(list)
        for _, e in ipairs(list) do
            if e.who and not seen[e.who] then seen[e.who] = true; out[#out+1] = e.who end
        end
    end
    note(AMS.data.buys); note(AMS.data.sales); note(AMS.data.expiries)
    table.sort(out)
    return out
end

-- nil = every character. Entries written before 0.7 have no `who` and are
-- counted under "everyone" only, rather than being blamed on whoever is logged
-- in now.
function DB:SetScope(who) self.scope = who end
function DB:Scope() return self.scope end

local function inScope(e, who)
    if not who then return true end
    return e.who == who
end

local function inWindow(entry, cutoff) return (entry.t or 0) >= cutoff end

-- Everything the Books tab and the velocity maths need for one item.
function DB:Stats(itemID)
    local s = {
        bought = 0, spent = 0, sold = 0, earned = 0,
        posted = 0, postedAuctions = 0, expired = 0, depositLost = 0, depositPaid = 0,
        firstBuy = nil, lastBuy = nil, firstSale = nil, lastSale = nil,
        avgBuy = 0, avgSale = 0,
    }

    local who = self.scope
    for _, b in ipairs(AMS.data.buys) do
        if b.id == itemID and inScope(b, who) then
            s.bought = s.bought + (b.count or 0)
            s.spent  = s.spent  + (b.total or 0)
            s.firstBuy = s.firstBuy or b.t
            s.lastBuy  = b.t
        end
    end
    for _, sa in ipairs(AMS.data.sales) do
        if sa.id == itemID and inScope(sa, who) then
            s.sold   = s.sold   + (sa.count or 0)
            s.earned = s.earned + (sa.net or 0)
            s.firstSale = s.firstSale or sa.t
            s.lastSale  = sa.t
        end
    end
    for _, p in ipairs(AMS.data.posts) do
        if p.id == itemID and inScope(p, who) then
            s.posted = s.posted + (p.stack or 0)
            s.postedAuctions = s.postedAuctions + 1
            s.depositPaid = s.depositPaid + (p.deposit or 0)
        end
    end
    for _, e in ipairs(AMS.data.expiries) do
        if e.id == itemID and inScope(e, who) then
            s.expired     = s.expired + (e.count or 0)
            s.depositLost = s.depositLost + (e.deposit or 0)
        end
    end

    if s.bought > 0 then s.avgBuy  = math.floor(s.spent  / s.bought) end
    if s.sold   > 0 then s.avgSale = math.floor(s.earned / s.sold)   end
    s.profit = s.earned - s.spent - s.depositLost
    return s
end

-- Units sold per day. Uses the last `days` of sales, or the whole record if
-- shorter. Returns rate, confidence ("none"/"low"/"ok"), spanHours.
function DB:Velocity(itemID, days)
    days = days or 7
    local cutoff = U:Now() - days * 86400
    local units, first, last = 0, nil, nil
    for _, sa in ipairs(AMS.data.sales) do
        if sa.id == itemID and inWindow(sa, cutoff) then
            units = units + (sa.count or 0)
            first = first or sa.t
            last  = sa.t
        end
    end
    if units == 0 or not first then return 0, "none", 0 end

    -- Span the sales actually cover, floored at 6h so one busy hour does not
    -- extrapolate to "1400 units per day".
    local span = math.max(21600, U:Now() - first)
    local rate = units / (span / 86400)
    local conf = span >= 3 * 86400 and "ok" or "low"
    return rate, conf, span / 3600
end

-- Fraction of posted UNITS that sold rather than expired. Unit-based, not
-- auction-based, because the deposit is charged per item: a 50% sell-through
-- means every unit you eventually sell carried a second, forfeited deposit.
function DB:SellThrough(itemID)
    local sold, expired = 0, 0
    for _, sa in ipairs(AMS.data.sales)    do if sa.id == itemID then sold    = sold    + (sa.count or 0) end end
    for _, e  in ipairs(AMS.data.expiries) do if e.id  == itemID then expired = expired + (e.count or 0)  end end
    local total = sold + expired
    if total < 20 then return nil, total end  -- not enough units to trust
    return sold / total, total
end

-- Post performance grouped by stack size: which configuration actually sells.
function DB:StackPerformance(itemID)
    local by = {}
    local function bucket(stack)
        by[stack] = by[stack] or { stack = stack, posted = 0, sold = 0, expired = 0, soldTime = 0, soldN = 0 }
        return by[stack]
    end
    for _, p in ipairs(AMS.data.posts) do
        if p.id == itemID then bucket(p.stack or 1).posted = bucket(p.stack or 1).posted + 1 end
    end
    for _, sa in ipairs(AMS.data.sales) do
        if sa.id == itemID and sa.count then
            local b = bucket(sa.count)
            b.sold = b.sold + 1
            if sa.post and sa.post.t then
                b.soldTime = b.soldTime + (sa.t - sa.post.t)
                b.soldN = b.soldN + 1
            end
        end
    end
    for _, e in ipairs(AMS.data.expiries) do
        if e.id == itemID and e.count then
            local b = bucket(e.count)
            b.expired = b.expired + 1
        end
    end

    local out = {}
    for _, b in pairs(by) do
        local closed = b.sold + b.expired
        b.sellThrough = closed > 0 and (b.sold / closed) or nil
        b.avgTime     = b.soldN > 0 and (b.soldTime / b.soldN) or nil
        out[#out+1] = b
    end
    table.sort(out, function(a, b) return a.stack < b.stack end)
    return out
end

-- Portfolio-wide totals for the Books header.
function DB:Totals()
    local t = { spent = 0, earned = 0, depositLost = 0, buys = 0, sales = 0 }
    local who = self.scope
    for _, b  in ipairs(AMS.data.buys) do
        if inScope(b, who) then t.spent = t.spent + (b.total or 0); t.buys = t.buys + 1 end
    end
    for _, sa in ipairs(AMS.data.sales) do
        if inScope(sa, who) then t.earned = t.earned + (sa.net or 0); t.sales = t.sales + 1 end
    end
    for _, e  in ipairs(AMS.data.expiries) do
        if inScope(e, who) then t.depositLost = t.depositLost + (e.deposit or 0) end
    end
    t.profit = t.earned - t.spent - t.depositLost
    return t
end

-- Stamps a character name onto ledger entries that predate per-character
-- tracking. Untagged entries otherwise only ever show under "All characters",
-- which is correct but not very useful once you start splitting the books up.
function DB:AttributeUntagged(who, force)
    if not who or who == "" then return 0 end
    local n = 0
    for _, list in ipairs({ AMS.data.buys, AMS.data.sales, AMS.data.posts, AMS.data.expiries }) do
        for _, e in ipairs(list) do
            if force or not e.who then e.who = who; n = n + 1 end
        end
    end
    if n > 0 then AMS:Fire("LEDGER_CHANGED") end
    return n
end

function DB:WipeLedger()
    AMS.data.buys, AMS.data.sales, AMS.data.posts, AMS.data.expiries = {}, {}, {}, {}
    AMS.data.mailSeen = {}
    AMS:Fire("LEDGER_CHANGED")
    AMS:Print("ledger cleared.")
end

function DB:WipeHistory(itemID)
    if itemID then AMS.data.scans[itemID] = nil else AMS.data.scans = {} end
    AMS:Fire("HISTORY_CHANGED", itemID)
end
