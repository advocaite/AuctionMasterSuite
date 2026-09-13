-- Auction Master Suite -- Poster
--
-- This client supports MULTI-SELL: StartAuction takes two extra arguments,
-- StartAuction(minBid, buyoutPerStack, duration, stackSize, numStacks), and
-- the server splits your stacks for you. Posting 200 singles is one call, not
-- 200 round trips.
--
-- That matters enormously here, and it also fixes the thing that used to
-- break: the old code tried to SplitContainerItem a stack down to the posting
-- size itself. Auctionator never splits - it drops the WHOLE stack in the sell
-- slot and lets stackSize/numStacks do the work. Splitting by hand is both
-- unnecessary and unreliable, which is why posting worked from a stack of one
-- and failed from anything larger.
--
-- Capability is detected from the Blizzard multi-sell UI rather than by
-- attempting a post and seeing what happens, so a client without it never gets
-- a mis-posted auction. Clients that lack it fall back to one auction at a
-- time, splitting only when it is genuinely needed.

local AMS = AuctionMasterSuite
local Poster = {}
AMS.Poster = Poster

local U

local VERIFY_TIMEOUT    = 3     -- seconds for the item to land in the sell slot
local MULTISELL_TIMEOUT = 30    -- a long run still reports progress well inside this

Poster.job = nil

function Poster:OnInit()
    U = AMS.Util
    AMS:RegisterEvent("AUCTION_MULTISELL_START",   function() Poster:_MultiStart() end)
    AMS:RegisterEvent("AUCTION_MULTISELL_UPDATE",  function(_, a, b) Poster:_MultiUpdate(a, b) end)
    AMS:RegisterEvent("AUCTION_MULTISELL_FAILURE", function() Poster:_MultiFailure() end)
end

-- The Blizzard Auctions tab only has these entry boxes on a client that can
-- multi-sell, which makes them a safe capability probe.
function Poster:HasMultisell()
    return (AuctionsNumStacksEntry ~= nil and AuctionsStackSizeEntry ~= nil) and true or false
end

function Poster:IsRunning() return self.job ~= nil end

-- =============================================================================
-- Helpers
-- =============================================================================

local function sellSlotItem()
    local name, _, count = GetAuctionSellItemInfo()
    return name, count or 0
end

-- Takes whatever is sitting in the auction sell slot back out.
local function clearSellSlot()
    if sellSlotItem() then
        ClickAuctionSellItemButton()
        ClearCursor()
    end
end

local function ensureSellTab()
    if AuctionFrameTab3 and AuctionFrameAuctions and not AuctionFrameAuctions:IsShown() then
        AuctionFrameTab3:Click()
    end
end

-- Largest unlocked stack of the item, or nil.
local function biggestStack(itemID)
    local stacks = AMS.Inventory:BagStacks(itemID)   -- sorted largest first
    for _, s in ipairs(stacks) do
        if not s.locked then return s end
    end
    return nil
end

-- A stack of exactly `need`, else the smallest that can be split to cover it.
local function stackFor(itemID, need)
    local stacks = AMS.Inventory:BagStacks(itemID)
    local exact, smallest
    for _, s in ipairs(stacks) do
        if not s.locked then
            if s.count == need then exact = s break end
            if s.count > need and (not smallest or s.count < smallest.count) then smallest = s end
        end
    end
    return exact or smallest
end

local function finish(reason)
    local j = Poster.job
    Poster.job = nil
    if Poster._ticker then Poster._ticker:Cancel(); Poster._ticker = nil end
    ClearCursor()
    AMS:Fire("POST_STATE", false, reason)
    if not j then return end

    if j.posted > 0 then
        AMS:Print("posted |cffffd070%d auction%s|r of %dx %s at %s each%s.",
            j.posted, j.posted == 1 and "" or "s", j.stack, j.name or "?",
            U:Money(j.unit), j.deposit > 0 and (", deposit "..U:Money(j.deposit)) or "")
    end
    if reason then AMS:Print("posting stopped: %s", reason) end
    AMS:Fire("LEDGER_CHANGED", j.id)
end

function Poster:Abort(reason)
    if self.job then finish(reason or "aborted") end
end

-- =============================================================================
-- Posting
-- =============================================================================

function Poster:Post(market, stack, unitPrice, count, duration)
    if self.job then AMS:Print("already posting.") return false end
    if not AMS:AtAuctionHouse() then AMS:Print("open the auction house first.") return false end
    if not market or not market.id then AMS:Print("no item selected.") return false end

    stack     = math.max(1, math.floor(stack or 1))
    count     = math.max(0, math.floor(count or 0))
    duration  = duration or market.duration or 3
    unitPrice = math.floor(unitPrice or 0)

    if count == 0 then AMS:Print("nothing to post.") return false end
    if unitPrice <= 0 then AMS:Print("set a price first.") return false end

    local have = AMS.Inventory:BagCount(market.id)
    if have < stack * count then
        count = math.floor(have / stack)
        if count == 0 then
            AMS:Print("you only have %d in your bags - not enough for a stack of %d.", have, stack)
            return false
        end
        AMS:Print("only %d in bags; posting %d auctions instead.", have, count)
    end

    ensureSellTab()

    self.job = {
        market   = market,
        id       = market.id,
        name     = market.name,
        stack    = stack,
        unit     = unitPrice,
        buyout   = unitPrice * stack,       -- multi-sell prices are per stack
        duration = duration,
        total    = count,
        posted   = 0,
        deposit  = 0,
        depositPerUnit = 0,
        multi    = self:HasMultisell(),
        state    = "place",
        stateAt  = GetTime(),
        nextAt   = 0,
    }

    AMS:Fire("POST_STATE", true, nil, self.job)

    local delay = (AMS.db.poster and AMS.db.poster.postDelay) or 0.4
    self._ticker = U:Ticker(0.1, function() Poster:Step(delay) end)
    return true
end

function Poster:Step(delay)
    local j = self.job
    if not j then return end
    if not AMS:AtAuctionHouse() then finish("the auction house closed") return end

    -- ---------- put the item in the sell slot ----------
    if j.state == "place" then
        if j.posted >= j.total then finish(nil) return end

        local slot
        if j.multi then
            slot = biggestStack(j.id)              -- never split: the server does it
        else
            slot = stackFor(j.id, j.stack)
        end
        if not slot then
            finish(("ran out of %s in your bags"):format(j.name or "stock"))
            return
        end

        clearSellSlot()
        ClearCursor()

        if j.multi or slot.count == j.stack then
            PickupContainerItem(slot.bag, slot.slot)
        else
            SplitContainerItem(slot.bag, slot.slot, j.stack)
        end

        -- Auctionator checks the cursor synchronously right here, so this is
        -- reliable; the retry is for the locked-slot case.
        if GetCursorInfo() == "item" then
            ClickAuctionSellItemButton()
            ClearCursor()
            j.state, j.stateAt = "verify", GetTime()
        elseif GetTime() - j.stateAt > VERIFY_TIMEOUT then
            ClearCursor()
            finish("could not pick the item up out of your bags")
        end

    -- ---------- start the auction(s) ----------
    elseif j.state == "verify" then
        local name, slotCount = sellSlotItem()
        if name and slotCount > 0 then
            local deposit = CalculateAuctionDeposit(j.duration) or 0
            j.depositPerUnit = math.floor(deposit / math.max(1, slotCount))
            if j.depositPerUnit > 0 then j.market.deposit = j.depositPerUnit end

            local remaining = j.total - j.posted
            local needed    = j.depositPerUnit * j.stack * remaining
            if GetMoney() < needed then
                finish(("not enough gold for the deposit (%s needed)"):format(U:Money(needed, true)))
                return
            end

            local minBid = (AMS.db.poster and AMS.db.poster.minBidEqualsBuyout ~= false)
                and j.buyout or math.floor(j.buyout * 0.95)

            if j.multi then
                StartAuction(minBid, j.buyout, j.duration, j.stack, remaining)
                j.state, j.stateAt = "posting", GetTime()
                j.sawMulti = false
            else
                StartAuction(minBid, j.buyout, j.duration)
                j.posted  = j.posted + 1
                j.deposit = j.deposit + j.depositPerUnit * j.stack
                AMS.DB:RecordPost(j.id, j.name, j.stack, j.unit, j.depositPerUnit * j.stack)
                AMS:Fire("POST_PROGRESS", j.posted, j.total)
                j.state  = "cooldown"
                j.nextAt = GetTime() + delay
            end

        elseif GetTime() - j.stateAt > VERIFY_TIMEOUT then
            ClearCursor()
            finish("could not put the item in the auction slot")
        end

    -- ---------- multi-sell in progress ----------
    elseif j.state == "posting" then
        if j.posted >= j.total then finish(nil) return end
        if GetTime() - j.stateAt > MULTISELL_TIMEOUT then
            finish("the auction house stopped reporting progress")
        end

    -- ---------- one-at-a-time pacing ----------
    elseif j.state == "cooldown" then
        if GetTime() >= j.nextAt then
            if j.posted >= j.total then finish(nil) else j.state = "place" end
        end
    end
end

-- =============================================================================
-- Multi-sell events
-- =============================================================================

function Poster:_MultiStart()
    local j = self.job
    if not j then return end
    j.sawMulti = true
    j.stateAt  = GetTime()
    AMS:Debug("multi-sell started")
end

function Poster:_MultiUpdate(done, total)
    local j = self.job
    if not j then return end
    done  = tonumber(done)  or tonumber(arg1) or 0
    total = tonumber(total) or tonumber(arg2) or j.total

    local delta = done - j.posted
    if delta > 0 then
        for _ = 1, delta do
            AMS.DB:RecordPost(j.id, j.name, j.stack, j.unit, j.depositPerUnit * j.stack)
        end
        j.posted  = done
        j.deposit = j.deposit + j.depositPerUnit * j.stack * delta
        AMS:Fire("POST_PROGRESS", j.posted, j.total)
    end
    j.stateAt = GetTime()

    if done >= total then finish(nil) end
end

function Poster:_MultiFailure()
    local j = self.job
    if not j then return end
    -- Auctionator adds one here too: the failure arrives after the last
    -- successful post rather than instead of it.
    AMS.DB:RecordPost(j.id, j.name, j.stack, j.unit, j.depositPerUnit * j.stack)
    j.posted  = j.posted + 1
    j.deposit = j.deposit + j.depositPerUnit * j.stack
    AMS:Fire("POST_PROGRESS", j.posted, j.total)
    finish("the auction house refused the rest - check your gold, bag space and stock")
end

-- =============================================================================
-- Deposit probe
-- =============================================================================

-- Puts a stack in the sell slot purely to read CalculateAuctionDeposit, then
-- takes it straight back out. The deposit is the one number the API will not
-- tell you without the item being in the slot, and the maths needs it.
--
-- The whole stack goes in and the result is divided by what is actually in the
-- slot, so this works with any stack size. The old version tried to split down
-- to one unit first, which is what made it fail on anything but a single.
function Poster:ProbeDeposit(market, stack, duration, cb)
    if self.job then if cb then cb(nil, "busy posting") end return end
    if not AMS:AtAuctionHouse() then if cb then cb(nil, "open the auction house first") end return end
    if not market or not market.id then if cb then cb(nil, "no item selected") end return end

    duration = duration or market.duration or 3

    local slot = biggestStack(market.id)
    if not slot then
        if cb then cb(nil, "you need at least one "..(market.name or "of it").." in your bags to measure the deposit") end
        return
    end

    ensureSellTab()
    clearSellSlot()
    ClearCursor()
    PickupContainerItem(slot.bag, slot.slot)

    if GetCursorInfo() ~= "item" then
        ClearCursor()
        if cb then cb(nil, "could not pick the item up") end
        return
    end
    ClickAuctionSellItemButton()
    ClearCursor()

    local started = GetTime()
    local ticker
    ticker = U:Ticker(0.1, function()
        local name, slotCount = sellSlotItem()
        if name and slotCount > 0 then
            ticker:Cancel()
            local deposit = CalculateAuctionDeposit(duration) or 0
            local perUnit = math.floor(deposit / slotCount)
            market.deposit = perUnit

            clearSellSlot()   -- put it back

            AMS:Print("deposit for %s: %s per unit at %s (measured on a stack of %d).",
                market.name or "?", U:Money(perUnit),
                duration == 1 and "12h" or duration == 2 and "24h" or "48h", slotCount)
            AMS:Fire("MARKETS_CHANGED")
            if cb then cb(perUnit, nil) end

        elseif GetTime() - started > VERIFY_TIMEOUT then
            ticker:Cancel()
            ClearCursor()
            if cb then cb(nil, "could not read the deposit") end
        end
    end)
end
