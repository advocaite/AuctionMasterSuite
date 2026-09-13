-- Auction Master Suite -- Analysis
-- Turns a raw scan into the numbers that decide whether to buy.
--
-- The three that matter, in order:
--
--   1. BUY CEILING. Not "below my target" - below what I can resell at a
--      profit. Reselling at 5g nets 4.75g after the 5% cut, so buying at 4.90g
--      loses money on every unit. This is the mistake that quietly eats flips.
--
--   2. COST TO CLEAR. What it costs to remove every competitor under the
--      ceiling, and what that leaves you holding.
--
--   3. RETURN PER DAY. Profit per unit multiplied by how many units actually
--      sell per day, divided by the gold tied up. A 50% margin on something
--      that moves three units a day is worse than 20% on something that moves
--      ninety. ROI alone will happily talk you into a dead market.
--
-- Deposit note: WoW charges the deposit per ITEM, not per auction, so posting
-- 200 singles costs exactly the same deposit as one stack of 200. Singles are
-- in fact cheaper on deposit risk, because only the unsold ones forfeit. The
-- deposit only becomes a real cost through relisting, which is what
-- relistFactor below models.

local AMS = AuctionMasterSuite
local A   = {}
AMS.Analysis = A

local U, DB, Config

local function init()
    U, DB, Config = AMS.Util, AMS.DB, AMS.Config
end

-- =============================================================================
-- Price levels
-- =============================================================================

-- Everything derived purely from the target price and your settings - no scan
-- needed. Used by the Post tab too.
function A:Levels(market)
    if not U then init() end
    local target = market and market.target or 0
    local cut    = Config:Cut()
    local margin = DB:MarginOf(market)
    local tol    = DB:ToleranceOf(market)

    local depositPerUnit = market and market.deposit or 0

    -- How many times you expect to relist a unit before it sells.
    -- 100% sell-through = 0 relists = no deposit cost at all.
    local sellThrough = market and DB:SellThrough(market.id) or nil
    local relistFactor = 0
    if sellThrough and sellThrough > 0.05 then
        relistFactor = (1 / sellThrough) - 1
    end
    local depositDrag = math.floor(depositPerUnit * relistFactor)

    local netPerUnit      = math.floor(target * (1 - cut))
    local netAfterDeposit = netPerUnit - depositDrag
    local breakEven       = netAfterDeposit
    local maxBuy          = math.floor(netAfterDeposit / (1 + margin))
    local tolCeiling      = math.floor(target * (1 - tol))
    local buyCeiling      = math.min(maxBuy, tolCeiling)
    if buyCeiling < 0 then buyCeiling = 0 end

    return {
        target          = target,
        cut             = cut,
        margin          = margin,
        tolerance       = tol,
        depositPerUnit  = depositPerUnit,
        depositKnown    = (market and market.deposit) and true or false,
        sellThrough     = sellThrough,
        relistFactor    = relistFactor,
        depositDrag     = depositDrag,
        netPerUnit      = netPerUnit,
        netAfterDeposit = netAfterDeposit,
        breakEven       = breakEven,
        maxBuy          = maxBuy,
        tolCeiling      = tolCeiling,
        buyCeiling      = buyCeiling,
    }
end

-- =============================================================================
-- Full evaluation of a scan
-- =============================================================================

-- entries: the list Scanner:ScanItem produced (already sorted cheapest first).
function A:Evaluate(market, entries)
    if not U then init() end
    local L = self:Levels(market)
    local r = {
        levels   = L,
        target   = L.target,
        scanned  = entries ~= nil,
        t        = U:Now(),
        entries  = entries or {},
    }

    local ignoreBidOnly = AMS.db.market.ignoreBidOnly ~= false

    -- ---------- market picture ----------
    local priceable = {}          -- entries with a buyout, not ours
    local mySupply, myAuctions = 0, 0
    local totalSupply, totalAuctions = 0, 0
    local myLowest

    for _, e in ipairs(r.entries) do
        totalSupply   = totalSupply + (e.count or 0)
        totalAuctions = totalAuctions + 1
        if e.mine then
            mySupply   = mySupply + (e.count or 0)
            myAuctions = myAuctions + 1
            if e.unit and (not myLowest or e.unit < myLowest) then myLowest = e.unit end
        elseif e.unit or not ignoreBidOnly then
            priceable[#priceable+1] = e
        end
    end

    r.totalSupply   = totalSupply
    r.totalAuctions = totalAuctions
    r.mySupply      = mySupply
    r.myAuctions    = myAuctions
    r.myLowest      = myLowest
    r.compSupply    = totalSupply - mySupply

    r.lowest = nil
    for _, e in ipairs(priceable) do
        if e.unit then r.lowest = e.unit break end
    end
    r.median = U:WeightedMedian(priceable)
    r.mean   = U:Mean(priceable)

    -- ---------- what is worth buying ----------
    -- Two separate questions, deliberately kept apart:
    --   "is this profitable stock?"  -> price only; stack size does not change
    --                                   margin per unit
    --   "must I clear this to hold my price?" -> a 20-stack listed at 140g is
    --                                   not competing for the buyer who wants
    --                                   three, if `bigStacksCompete` is off
    local maxStack  = DB:MaxBuyStackOf(market)
    local bigCompete = AMS.db.market.bigStacksCompete ~= false

    local buyList, buyUnits, buyCost = {}, 0, 0
    local underTargetUnits, underTargetCost = 0, 0   -- competition you count
    local allUnderUnits, allUnderCost = 0, 0         -- competition that exists
    local skippedUnits, skippedCost = 0, 0           -- under target, too dear
    local bigUnits, bigCost = 0, 0                   -- under ceiling, too big

    for _, e in ipairs(priceable) do
        if e.unit then
            local tooBig = maxStack > 0 and e.count > maxStack
            e.tooBig = tooBig

            if e.unit < L.target then
                allUnderUnits = allUnderUnits + e.count
                allUnderCost  = allUnderCost + e.buyout
                if bigCompete or not tooBig then
                    underTargetUnits = underTargetUnits + e.count
                    underTargetCost  = underTargetCost + e.buyout
                end
            end

            if L.target > 0 and e.unit <= L.buyCeiling then
                if tooBig then
                    bigUnits = bigUnits + e.count
                    bigCost  = bigCost + e.buyout
                else
                    buyList[#buyList+1] = e
                    buyUnits = buyUnits + e.count
                    buyCost  = buyCost + e.buyout
                end
            elseif e.unit < L.target then
                skippedUnits = skippedUnits + e.count
                skippedCost  = skippedCost + e.buyout
            end
        end
    end

    -- Queue order. "smallest" buys the singles and small lots first, so
    -- stopping half way through leaves you holding the flexible stock.
    if DB:BuyOrderOf(market) == "smallest" then
        table.sort(buyList, function(a, b)
            if a.count ~= b.count then return a.count < b.count end
            return (a.unit or 0) < (b.unit or 0)
        end)
    end

    r.buyList  = buyList
    r.buyUnits = buyUnits
    r.buyCost  = buyCost
    r.buyAvg   = buyUnits > 0 and math.floor(buyCost / buyUnits) or 0
    r.maxStack = maxStack
    r.bigCompete = bigCompete
    r.underTargetUnits = underTargetUnits
    r.underTargetCost  = underTargetCost
    r.allUnderUnits = allUnderUnits
    r.allUnderCost  = allUnderCost
    r.skippedUnits = skippedUnits
    r.skippedCost  = skippedCost
    r.bigUnits = bigUnits
    r.bigCost  = bigCost
    -- what leaving the big stacks alone costs you in foregone profit
    r.bigForegone = bigUnits > 0 and (bigUnits * L.netAfterDeposit - bigCost) or 0

    -- ---------- supply walls ----------
    local byPrice = {}
    local order = {}
    for _, e in ipairs(priceable) do
        if e.unit and (L.target == 0 or e.unit < L.target) then
            local w = byPrice[e.unit]
            if not w then
                w = { unit = e.unit, units = 0, auctions = 0, cost = 0 }
                byPrice[e.unit] = w
                order[#order+1] = w
            end
            w.units    = w.units + e.count
            w.auctions = w.auctions + 1
            w.cost     = w.cost + e.buyout
        end
    end
    table.sort(order, function(a, b) return a.units > b.units end)
    r.walls = order
    r.biggestWall = order[1]
    -- Measured against ALL sub-target supply, including stacks you have chosen
    -- not to treat as competition: someone else can always buy a big stack and
    -- relist it as singles against you, so it stays on the radar.
    r.wallIsSignificant = r.biggestWall and allUnderUnits > 0
        and (r.biggestWall.units / allUnderUnits) >= 0.25 or false

    -- ---------- profit projection ----------
    r.gross  = buyUnits * L.target
    r.net    = buyUnits * L.netAfterDeposit
    r.profit = r.net - buyCost
    r.roi    = buyCost > 0 and (r.profit / buyCost) or 0
    r.profitPerUnit = buyUnits > 0 and math.floor(r.profit / buyUnits) or 0

    -- ---------- velocity ----------
    local vel, conf = DB:Velocity(market and market.id)
    r.velocity     = vel
    r.velocityConf = conf
    r.refillRate, r.refillHours = DB:RefillRate(market and market.id)

    local holdings = AMS.Inventory:Holdings(market and market.id)
    r.holdings = holdings

    local stockAfter = holdings.total + buyUnits
    r.stockAfter = stockAfter
    if vel > 0 then
        r.daysToSell = stockAfter / vel
        r.daysToSellCurrent = holdings.total / vel
    end

    local stats = DB:Stats(market and market.id)
    r.stats = stats
    local unitBasis = stats.avgBuy > 0 and stats.avgBuy or (r.lowest or 0)
    r.invested      = holdings.total * unitBasis
    r.exposureAfter = r.invested + buyCost

    -- Return per day: the number the whole thing hinges on.
    if vel > 0 and buyUnits > 0 then
        local sellable = math.min(vel, buyUnits)   -- can't sell more than you bought, per day
        r.dailyProfit = math.floor(r.profitPerUnit * sellable)
        if r.exposureAfter > 0 then
            r.dailyReturn = r.dailyProfit / r.exposureAfter
        end
    end

    -- ---------- affordability ----------
    local gold = AMS.Inventory:Gold()
    r.gold = gold
    local spend, afford = 0, 0
    for _, e in ipairs(buyList) do
        if spend + e.buyout > gold then break end
        spend  = spend + e.buyout
        afford = afford + e.count
    end
    r.affordUnits = afford
    r.affordCost  = spend
    r.canAffordAll = (buyCost <= gold)

    -- ---------- caps ----------
    r.overInvest = (market and market.maxInvest or 0) > 0 and r.exposureAfter > market.maxInvest
    r.overStock  = (market and market.maxStock  or 0) > 0 and stockAfter > market.maxStock

    -- ---------- is it unusually cheap right now? ----------
    if r.scanned and r.lowest then
        r.dislocation = self:Dislocation(market, r.lowest)
        if r.dislocation and r.dislocation.isDump then
            r.dumpPlan = self:DumpPlan(market, priceable, r.dislocation)
        end
    end

    -- ---------- health + verdict ----------
    r.health, r.healthParts = self:Health(market, r)
    r.verdict = self:Verdict(market, r)
    r.score   = self:Score(market, r)
    return r
end

-- =============================================================================
-- Health: 0-100, four components
-- =============================================================================

function A:Health(market, r)
    local parts = {}

    -- Control (40): how little competitor supply sits under your target.
    local comp = r.underTargetUnits or 0
    local mine = (r.mySupply or 0)
    local control
    if comp == 0 then
        control = 1
    else
        control = mine / (mine + comp)
        -- an empty book with competitors in it is zero control, not 0.5
        if mine == 0 then control = 0 end
    end
    parts.control = control * 40

    -- Margin (25): headroom between the cheapest competitor and your break-even.
    local margin = 0
    if r.levels.breakEven > 0 and r.lowest then
        margin = (r.levels.breakEven - r.lowest) / r.levels.breakEven
    elseif r.levels.breakEven > 0 and not r.lowest then
        margin = 1   -- nothing listed against you at all
    end
    parts.margin = U:Clamp(margin / 0.4, 0, 1) * 25

    -- Velocity (25): how fast the stock you would hold actually clears.
    local vel = 0
    if r.daysToSell then
        -- 3 days or better is full marks; 21 days is zero.
        vel = U:Clamp((21 - r.daysToSell) / 18, 0, 1)
    elseif (r.velocityConf or "none") == "none" then
        vel = 0.4   -- unknown, not necessarily bad
    end
    parts.velocity = vel * 25

    -- Exposure (10): how much of your cap this would consume.
    local exp = 1
    if market and (market.maxInvest or 0) > 0 then
        exp = U:Clamp(1 - (r.exposureAfter / market.maxInvest), 0, 1)
    end
    parts.exposure = exp * 10

    local total = parts.control + parts.margin + parts.velocity + parts.exposure
    return math.floor(total + 0.5), parts
end

-- =============================================================================
-- Verdict: the one-line recommendation
-- =============================================================================

function A:Verdict(market, r)
    local C = AMS.Skin.COLOR

    if not market or (market.target or 0) <= 0 then
        return { level = "idle", color = C.textDim,
                 title = "SET A TARGET PRICE",
                 detail = "The target is the price you intend to defend. Everything else is derived from it." }
    end
    if not r.scanned then
        return { level = "idle", color = C.textDim,
                 title = "SCAN THE MARKET",
                 detail = "Open the auction house and scan to see the cost to clear." }
    end

    

    -- A genuine dislocation outranks routine market-keeping: the gold comes
    -- back faster and there is more of it.
    if r.dumpPlan and r.dislocation then
        local d, p = r.dislocation, r.dumpPlan
        local rec = d.recoveryDays
            and ("past dips came back in about %.1f days (%d seen)"):format(d.recoveryDays, d.episodes)
            or  "no past dip on record to judge recovery by"
        return { level = "good", color = C.info,
                 title = ("PRICE DISLOCATION - %.0f%% BELOW NORMAL"):format(-d.pct * 100),
                 detail = ("Cheapest is %s against a %s baseline (%.1f sigma). Taking the %d units under %s costs %s and returns about %s at baseline - %s profit. %s.")
                     :format(U:Money(r.lowest, true), U:Money(d.baseline, true), d.z,
                             p.units, U:Money(p.ceiling, true), U:Money(p.cost, true),
                             U:Money(p.net, true), U:Money(p.profit, true), rec) }
    end

    if r.buyUnits == 0 then
        -- Priced right, but every remaining lot is bigger than you buy.
        if r.bigUnits > 0 then
            return { level = "warn", color = C.warn,
                     title = ("ONLY BIG STACKS LEFT - %d UNITS SKIPPED"):format(r.bigUnits),
                     detail = ("%d units under your ceiling sit in stacks larger than %d, costing %s to take. The margin per unit is identical - a big stack just ties up more gold at once. Passing on them leaves about %s of profit on the table.")
                         :format(r.bigUnits, r.maxStack, U:Money(r.bigCost, true),
                                 U:Money(r.bigForegone, true)) }
        end
        if r.skippedUnits > 0 then
            return { level = "good", color = C.good,
                     title = "HOLD - NOTHING WORTH BUYING",
                     detail = ("%d units sit under your target but above your buy ceiling of %s. Clearing them would cost more than reselling returns.")
                         :format(r.skippedUnits, U:Money(r.levels.buyCeiling, true)) }
        end
        return { level = "good", color = C.good,
                 title = "MARKET CONTROLLED",
                 detail = ("No competitor under %s. Lowest is %s; you hold %d listed.%s")
                     :format(U:Money(r.levels.buyCeiling, true),
                             r.lowest and U:Money(r.lowest, true) or "nothing",
                             r.mySupply or 0,
                             (not r.bigCompete and r.allUnderUnits > r.underTargetUnits)
                                and (" %d units under target are in big stacks and not counted as competition."):format(r.allUnderUnits - r.underTargetUnits)
                                or "") }
    end

    if r.overInvest then
        return { level = "bad", color = C.bad,
                 title = "DO NOT BUY - OVER EXPOSURE CAP",
                 detail = ("Clearing costs %s and would put %s into this item, over your %s cap. Raise the cap deliberately or take a partial position.")
                     :format(U:Money(r.buyCost, true), U:Money(r.exposureAfter, true), U:Money(market.maxInvest, true)) }
    end

    if r.overStock then
        return { level = "bad", color = C.bad,
                 title = "DO NOT BUY - OVER STOCK CAP",
                 detail = ("You would hold %d units against a cap of %d.")
                     :format(r.stockAfter, market.maxStock) }
    end

    if r.daysToSell and r.daysToSell > 21 and (r.velocityConf or "none") ~= "none" then
        return { level = "warn", color = C.warn,
                 title = "SLOW MARKET - CAPITAL WILL SIT",
                 detail = ("Buying all %d leaves %d units and roughly %.0f days of stock at %.1f sales/day. The gold is not lost, but it is parked.")
                     :format(r.buyUnits, r.stockAfter, r.daysToSell, r.velocity) }
    end

    if not r.canAffordAll then
        return { level = "warn", color = C.warn,
                 title = ("PARTIAL - AFFORD %d OF %d"):format(r.affordUnits, r.buyUnits),
                 detail = ("Clearing everything costs %s; you have %s. Buying cheapest-first gets you %d units for %s.")
                     :format(U:Money(r.buyCost, true), U:Money(r.gold, true), r.affordUnits, U:Money(r.affordCost, true)) }
    end

    if r.wallIsSignificant and r.biggestWall then
        local w = r.biggestWall
        local pct = r.underTargetUnits > 0 and (w.units / r.underTargetUnits * 100) or 0
        return { level = "warn", color = C.warn,
                 title = ("BUY %d FOR %s - WALL AHEAD"):format(r.buyUnits, U:Money(r.buyCost, true)),
                 detail = ("%d units (%.0f%% of the supply) sit at one price, %s, costing %s. That is one seller who can relist. Worth clearing only if you can hold the price afterwards.")
                     :format(w.units, pct, U:Money(w.unit, true), U:Money(w.cost, true)) }
    end

    return { level = "good", color = C.good,
             title = ("BUY %d FOR %s"):format(r.buyUnits, U:Money(r.buyCost, true)),
             detail = ("Average %s per unit, resells net %s. Profit %s (%.0f%% ROI)%s.%s")
                 :format(U:Money(r.buyAvg, true), U:Money(r.levels.netAfterDeposit, true),
                         U:Money(r.profit, true), r.roi * 100,
                         r.dailyProfit and (", about "..U:Money(r.dailyProfit, true).."/day at current velocity") or "",
                         r.bigUnits > 0
                            and (" Skipping %d more units in stacks over %d, worth %s of profit."):format(
                                    r.bigUnits, r.maxStack, U:Money(r.bigForegone, true))
                            or "") }
end

-- =============================================================================
-- Opportunity score for the watchlist
-- =============================================================================

-- Deliberately NOT ROI. Return per day on capital, capped by how much we trust
-- the velocity number. An unproven market cannot score above 45.
function A:Score(market, r)
    if not r.scanned or r.buyUnits == 0 or r.buyCost <= 0 then return 0 end

    local base
    if r.dailyReturn and r.dailyReturn > 0 then
        -- 5% return per day on tied-up capital is an excellent flip = 100.
        base = U:Clamp(r.dailyReturn / 0.05, 0, 1) * 100
    else
        -- No velocity data: fall back to raw ROI, heavily discounted.
        base = U:Clamp(r.roi / 0.5, 0, 1) * 45
    end

    local conf = r.velocityConf or "none"
    if conf == "none" then base = math.min(base, 45)
    elseif conf == "low" then base = math.min(base, 75) end

    if r.overInvest or r.overStock then base = base * 0.3 end
    if r.wallIsSignificant then base = base * 0.85 end

    return math.floor(base + 0.5)
end

-- =============================================================================
-- Scan + evaluate + record, in one call
-- =============================================================================

-- The standard cycle: scan the item, run the numbers, write a history
-- snapshot. cb(result, entries, err).
function A:ScanAndEvaluate(market, cb)
    if not U then init() end
    if not market then if cb then cb(nil, nil, "no market") end return end

    AMS.Scanner:ScanItem(market.name, function(entries, err)
        if err then if cb then cb(nil, nil, err) end return end

        local r = A:Evaluate(market, entries)
        A:Snapshot(market, r)
        if cb then cb(r, entries, nil) end
    end)
end

-- Everything the watchlist needs to rank a market without rescanning it.
function A:Snapshot(market, r)
    if not market or not r then return end
    DB:AddSnapshot(market.id, {
        t          = U:Now(),
        min        = r.lowest or 0,
        median     = r.median or 0,
        mean       = r.mean or 0,
        supply     = r.totalSupply or 0,
        mine       = r.mySupply or 0,
        underUnits = r.underTargetUnits or 0,
        underCost  = r.underTargetCost or 0,
        buyUnits   = r.buyUnits or 0,
        buyCost    = r.buyCost or 0,
        profit     = r.profit or 0,
        roi        = r.roi or 0,
        score      = r.score or 0,
        health     = r.health or 0,
        velocity   = r.velocity or 0,
        daysToSell = r.daysToSell,
        target     = market.target or 0,
        verdict    = r.verdict and r.verdict.level or "idle",
        z          = r.dislocation and r.dislocation.z or nil,
        baseline   = r.dislocation and r.dislocation.baseline or nil,
        dumpUnits  = r.dumpPlan and r.dumpPlan.units or nil,
        dumpCost   = r.dumpPlan and r.dumpPlan.cost or nil,
        dumpProfit = r.dumpPlan and r.dumpPlan.profit or nil,
    })

    -- Say something out loud: a dislocation is worth interrupting for, and you
    -- will not be staring at the right tab when one turns up.
    if r.dumpPlan and r.dislocation
       and (AMS.db.dislocation and AMS.db.dislocation.alert ~= false) then
        AMS:Print("|cff70b0ff%s is %.0f%% below its normal|r - %d units under %s for %s, worth about %s.",
            market.name or "?", -r.dislocation.pct * 100, r.dumpPlan.units,
            U:Money(r.dumpPlan.ceiling, true), U:Money(r.dumpPlan.cost, true),
            U:Money(r.dumpPlan.profit, true))
    end
end

-- =============================================================================
-- Dislocation: is this item unusually cheap right now?
-- =============================================================================
--
-- Somebody quits, needs gold tonight, or misreads the market and dumps stock
-- well under the going rate. Buy it, let the dump clear, sell back into the
-- normal price. It is the highest-return play there is, and the only one where
-- the gold comes back in days rather than weeks.
--
-- The hard part is telling a dump from an ordinary wobble, and "30% below
-- average" does not do it: a jumpy market is 30% below average twice a week. So
-- the deviation is measured in units of the item's OWN volatility - a z-score.
-- On a placid item a 15% drop is enormous; on a volatile one it is Tuesday.
--
-- The baseline is a median of daily medians, not a mean, because a mean would
-- be dragged down by the very dumps we are trying to spot.

function A:Baseline(market)
    if not U then init() end
    if not market then return nil end

    local window = (AMS.db.dislocation and AMS.db.dislocation.window) or 21
    local days   = DB:DailyHistory(market.id, window)

    local vals = {}
    for _, d in ipairs(days) do
        if (d.median or 0) > 0 then vals[#vals+1] = d.median end
    end

    local minDays = (AMS.db.dislocation and AMS.db.dislocation.minDays) or 4
    if #vals < minDays then
        return nil, ("needs %d days of scans, has %d"):format(minDays, #vals)
    end

    local baseline = U:Median(vals)
    local sd       = U:StdDev(vals)
    -- A perfectly flat history would make every wobble look infinite, so put a
    -- floor of 2% of the baseline under the volatility.
    local floor = baseline * 0.02
    if sd < floor then sd = floor end

    return { baseline = baseline, sd = sd, samples = #vals, days = days }, nil
end

-- How long past dips took to come back. This is the number that separates a
-- flip from dead capital, and it is the question people skip.
local function recoveryDays(days, baseline)
    local episodes, inDip, dipAt = {}, false, nil
    for _, d in ipairs(days) do
        if not inDip then
            if (d.min or 0) > 0 and d.min < baseline * 0.85 then
                inDip, dipAt = true, d.t
            end
        elseif (d.median or 0) >= baseline * 0.95 then
            episodes[#episodes+1] = math.max(0, (d.t - dipAt) / 86400)
            inDip = false
        end
    end
    if #episodes == 0 then return nil, 0 end
    return U:Median(episodes), #episodes
end

-- lowest: the cheapest competitor price seen in the current scan.
function A:Dislocation(market, lowest)
    if not U then init() end
    if not market or not lowest or lowest <= 0 then return nil end

    local base, why = self:Baseline(market)
    if not base then return nil, why end

    local z   = (lowest - base.baseline) / base.sd
    local pct = (lowest - base.baseline) / base.baseline
    local rec, n = recoveryDays(base.days, base.baseline)

    local zAlert = (AMS.db.dislocation and AMS.db.dislocation.zAlert) or -1.5
    local level  = "normal"
    if z <= zAlert * 1.5 then level = "severe"
    elseif z <= zAlert   then level = "dislocated"
    elseif z <= zAlert / 2 then level = "soft"
    elseif z >= -zAlert  then level = "rich" end

    return {
        baseline     = math.floor(base.baseline),
        sd           = math.floor(base.sd),
        samples      = base.samples,
        z            = z,
        pct          = pct,
        level        = level,
        isDump       = (z <= zAlert),
        recoveryDays = rec,
        episodes     = n,
    }
end

-- What the dislocation is worth: everything under the baseline, and what
-- reselling it there would net.
function A:DumpPlan(market, entries, dis)
    if not U or not dis then return nil end
    local cut  = Config:Cut()
    local ceil = math.floor(dis.baseline * 0.9)   -- leave room to undercut on the way out

    local units, cost, list = 0, 0, {}
    for _, e in ipairs(entries or {}) do
        if e.unit and not e.mine and e.unit <= ceil then
            list[#list+1] = e
            units = units + e.count
            cost  = cost + e.buyout
        end
    end
    if units == 0 then return nil end

    local net    = math.floor(units * dis.baseline * (1 - cut))
    local profit = net - cost
    return {
        ceiling = ceil,
        units   = units,
        cost    = cost,
        avg     = math.floor(cost / units),
        net     = net,
        profit  = profit,
        roi     = cost > 0 and (profit / cost) or 0,
        list    = list,
    }
end

-- =============================================================================
-- Appraisal: is this item any good for the single-unit strategy?
-- =============================================================================

-- THE measurement the whole strategy rests on, and one no tool seems to make:
-- do single units actually fetch more PER UNIT than bulk stacks?
--
-- That differential is the entire edge. You buy somebody's stack of twenty and
-- sell twenty singles; if singles trade at the same unit price as stacks there
-- is no trade, however cheap the stacks look. Measured straight off a scan, so
-- it works on an item you have never touched.
--
-- Returns premium (1.0 = no edge, 1.4 = singles fetch 40% more), the two
-- medians, and how many auctions backed each.
function A:StackPremium(entries)
    if not U then init() end
    local singles, bulk = {}, {}
    for _, e in ipairs(entries or {}) do
        -- your own listings would just measure your own pricing back at you
        if e.unit and not e.mine then
            if e.count == 1 then singles[#singles+1] = e
            elseif e.count >= 5 then bulk[#bulk+1] = e end
        end
    end
    if #singles < 3 or #bulk < 3 then
        return nil, nil, nil, #singles, #bulk
    end

    local s = U:WeightedMedian(singles)
    local b = U:WeightedMedian(bulk)
    if b <= 0 then return nil, s, b, #singles, #bulk end
    return s / b, s, b, #singles, #bulk
end

local function band(v, lo, hi)
    if not v then return 0 end
    if hi <= lo then return 0 end
    return U:Clamp((v - lo) / (hi - lo), 0, 1)
end

-- Scores an item out of 100 for buy-bulk-sell-singles, with the reasoning
-- shown rather than hidden behind a number.
function A:Appraise(market, entries)
    if not U then init() end
    local C = AMS.Skin.COLOR
    local r = { lines = {}, score = 0 }

    local function line(label, value, note, tone)
        r.lines[#r.lines+1] = { label = label, value = value, note = note, tone = tone }
    end

    -- ---------- 1. the stack premium (30) ----------
    local premium, singleMed, bulkMed, nSingles, nBulk = self:StackPremium(entries)
    local pScore = 0
    if premium then
        pScore = band(premium, 1.0, 1.30) * 30
        local pct = (premium - 1) * 100
        line("Single-unit premium", ("%+.0f%%"):format(pct),
            ("singles %s vs bulk %s per unit"):format(U:MoneyShort(singleMed), U:MoneyShort(bulkMed)),
            pct >= 15 and C.good or pct >= 5 and C.warn or C.bad)
    else
        line("Single-unit premium", "cannot measure",
            ("needs 3+ singles and 3+ bulk stacks listed by others - found %d and %d")
                :format(nSingles or 0, nBulk or 0), C.textDim)
    end

    -- ---------- 2. bulk supply to buy from (15) ----------
    local bulkUnits, bulkCost = 0, 0
    for _, e in ipairs(entries or {}) do
        if e.unit and not e.mine and (e.count or 1) >= 5 then
            bulkUnits = bulkUnits + e.count
            bulkCost  = bulkCost + e.buyout
        end
    end
    local sScore = band(bulkUnits, 20, 200) * 15
    line("Bulk stock available", ("%d units"):format(bulkUnits),
        bulkUnits > 0 and ("costing %s to take"):format(U:MoneyShort(bulkCost)) or "nothing to buy in bulk",
        bulkUnits >= 100 and C.good or bulkUnits >= 20 and C.warn or C.bad)

    -- ---------- 3. deposit drag (15) ----------
    local dScore, depNote = 15, "not measured - press Deposit on the Market tab"
    local dep = market and market.deposit
    if dep and singleMed and singleMed > 0 then
        local ratio = dep / singleMed
        dScore = (1 - band(ratio, 0.01, 0.10)) * 15
        depNote = ("%s per unit, %.1f%% of the single price"):format(U:MoneyShort(dep), ratio * 100)
        line("Deposit drag", ratio < 0.02 and "negligible" or ratio < 0.05 and "modest" or "heavy",
            depNote, ratio < 0.02 and C.good or ratio < 0.05 and C.warn or C.bad)
    else
        line("Deposit drag", "unknown", depNote, C.textDim)
    end

    -- ---------- 4. how fast it moves (25) ----------
    local vel, conf = DB:Velocity(market and market.id)
    local vScore
    if conf == "none" then
        vScore = 8   -- unknown is not the same as bad, but it is not proven
        line("Sales per day", "no history yet",
            "sell some and this fills in - it is the number that decides everything", C.textDim)
    else
        vScore = band(vel, 1, 40) * 25
        line("Sales per day", ("%.1f"):format(vel),
            conf == "ok" and "well established" or "based on a short window",
            vel >= 10 and C.good or vel >= 3 and C.warn or C.bad)
    end

    -- ---------- 5. who else is selling singles (15) ----------
    local cScore = band(10 - (nSingles or 0), 0, 8) * 15
    line("Competing singles", ("%d listed by others"):format(nSingles or 0),
        (nSingles or 0) <= 2 and "the niche is open" or
        (nSingles or 0) <= 8 and "some competition" or "crowded - you would be one of many",
        (nSingles or 0) <= 2 and C.good or (nSingles or 0) <= 8 and C.warn or C.bad)

    r.score = math.floor(pScore + sScore + dScore + vScore + cScore + 0.5)
    r.premium, r.singleMed, r.bulkMed = premium, singleMed, bulkMed
    r.bulkUnits, r.bulkCost = bulkUnits, bulkCost

    -- ---------- the verdict ----------
    if not entries then
        r.grade, r.color = "?", C.textDim
        r.verdict = "SCAN THIS ITEM"
        r.detail  = "Appraisal reads the live auction house: it compares what singles fetch against what bulk stacks fetch."
    elseif premium and premium >= 1.15 and bulkUnits >= 20 then
        r.grade, r.color = "A", C.good
        r.verdict = ("GOOD FOR SINGLES - %+.0f%% PREMIUM"):format((premium - 1) * 100)
        r.detail  = ("Buying the %d bulk units for %s and reselling as singles at %s would gross about %s. The premium is the trade; the rest is how fast it moves.")
            :format(bulkUnits, U:MoneyShort(bulkCost), U:MoneyShort(singleMed),
                    U:MoneyShort(bulkUnits * singleMed))
    elseif premium and premium >= 1.05 then
        r.grade, r.color = "B", C.warn
        r.verdict = ("THIN PREMIUM - %+.0f%%"):format((premium - 1) * 100)
        r.detail  = "Singles do fetch more, but not by much. After the 5% cut and the deposit there may be little left. Worth it only if it moves fast."
    elseif premium then
        r.grade, r.color = "D", C.bad
        r.verdict = "NO SINGLE-UNIT EDGE"
        r.detail  = ("Singles trade at %s and bulk at %s per unit - there is no premium to harvest here. Splitting stacks would just cost you the auction house cut.")
            :format(U:MoneyShort(singleMed), U:MoneyShort(bulkMed))
    else
        r.grade, r.color = "?", C.textDim
        r.verdict = "NOT ENOUGH LISTINGS TO JUDGE"
        r.detail  = "Nobody is posting singles and bulk side by side, so the premium cannot be measured. Either the market is thin, or you are the only one working it."
    end

    if r.score >= 70 and r.grade == "B" then r.grade = "A" end
    return r
end

-- =============================================================================
-- Pricing: the ladder, and undercutting
-- =============================================================================

-- Every distinct price on the board with how much sits at each. This is the
-- honest version of "what should I charge": it shows where the walls are while
-- you pick, instead of hiding the shape behind a single number.
function A:PriceLadder(entries)
    if not U then init() end
    local by, order = {}, {}
    for _, e in ipairs(entries or {}) do
        if e.unit then
            local r = by[e.unit]
            if not r then
                r = { unit = e.unit, auctions = 0, units = 0, mine = 0, others = 0 }
                by[e.unit] = r
                order[#order+1] = r
            end
            r.auctions = r.auctions + 1
            r.units    = r.units + (e.count or 0)
            if e.mine then r.mine = r.mine + 1 else r.others = r.others + 1 end
        end
    end
    table.sort(order, function(a, b) return a.unit < b.unit end)

    -- mark the cheapest listing that is not yours: that is what you undercut
    for _, r in ipairs(order) do
        if r.others > 0 then r.isLowestOther = true break end
    end
    return order
end

-- The least you can sell a unit for without losing money, based on what your
-- stock actually cost. Nil when there is no purchase history to judge by -
-- better to say nothing than to invent a floor.
function A:SellFloor(market)
    if not U then init() end
    if not market then return nil end
    local s = DB:Stats(market.id)
    if (s.avgBuy or 0) <= 0 then return nil end
    -- what you paid has to survive the auction house cut on the way out
    return math.ceil(s.avgBuy / (1 - Config:Cut())), s.avgBuy
end

-- Price to post at in order to sit just under `unit`.
-- Returns price, blockedReason.
function A:UndercutPrice(unit, market)
    if not U then init() end
    unit = math.floor(unit or 0)
    if unit <= 1 then return 1 end

    local p = AMS.db.poster or {}
    local out
    if p.undercutUsePct then
        out = math.floor(unit * (1 - (p.undercutPct or 1) / 100))
    else
        out = unit - math.max(1, math.floor(p.undercutFlat or 1))
    end
    if out >= unit then out = unit - 1 end
    if out < 1 then out = 1 end

    if p.neverBelowCost ~= false then
        local floorPrice, basis = self:SellFloor(market)
        if floorPrice and out < floorPrice then
            return floorPrice, ("that would sell under your cost - your stock averaged %s a unit, so %s is the least that breaks even after the cut")
                :format(U:Money(basis, true), U:Money(floorPrice, true))
        end
    end
    return out
end

-- =============================================================================
-- Posting advice
-- =============================================================================

-- What the ledger says about which stack size actually sells.
function A:StackAdvice(market)
    if not U then init() end
    if not market then return nil end
    local perf = DB:StackPerformance(market.id)
    if #perf == 0 then return nil end

    local best, bestScore
    for _, p in ipairs(perf) do
        local closed = p.sold + p.expired
        if closed >= 3 then
            -- prefer high sell-through, break ties on speed
            local score = (p.sellThrough or 0) * 100
            if p.avgTime then score = score + (86400 / math.max(3600, p.avgTime)) end
            if not bestScore or score > bestScore then best, bestScore = p, score end
        end
    end
    return perf, best
end

-- Units you can post right now, and what it will cost in deposit.
function A:PostPlan(market, stack, unitPrice, count)
    if not U then init() end
    local holdings = AMS.Inventory:Holdings(market.id)
    stack = math.max(1, math.floor(stack or 1))
    local available = holdings.bags
    local maxAuctions = math.floor(available / stack)
    count = math.min(count or maxAuctions, maxAuctions)

    local depositPerUnit = market.deposit or 0
    return {
        stack        = stack,
        auctions     = count,
        units        = count * stack,
        unitPrice    = unitPrice,
        perAuction   = unitPrice * stack,
        gross        = unitPrice * stack * count,
        netIfAllSell = math.floor(unitPrice * stack * count * (1 - Config:Cut())),
        deposit      = depositPerUnit * stack * count,
        depositKnown = (market.deposit ~= nil),
        available    = available,
        maxAuctions  = maxAuctions,
        -- multi-sell posts the whole run in one call; without it every auction
        -- is its own round trip
        multisell    = AMS.Poster:HasMultisell(),
        estSeconds   = AMS.Poster:HasMultisell()
                        and math.max(2, count * 0.15)
                        or  count * ((AMS.db.poster and AMS.db.poster.postDelay) or 0.4) * 2,
    }
end
