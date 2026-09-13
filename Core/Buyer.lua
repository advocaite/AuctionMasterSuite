-- Auction Master Suite -- Buyer
-- The buy queue.
--
-- THE RULE THAT SHAPES THIS WHOLE FILE: PlaceAuctionBid only works inside a
-- hardware event. Called from a timer or an event handler the client accepts
-- it and silently does nothing - no error, no gold moved, no auction bought.
-- Auctionator has a full OnUpdate state machine for querying and paging and
-- still reaches PlaceAuctionBid from exactly one place: a button's OnClick.
--
-- So buying is split in two:
--
--   Prepare()   asynchronous. Waits for the auction house to settle, finds the
--               page the queued auctions are on, and resolves them to row
--               indices. Does not buy anything.
--   Execute()   synchronous, and ONLY ever called from a click handler. Walks
--               the rows Prepare resolved, re-checks each one, and buys.
--
-- Everything else is safety:
--
--   * Auction results are global to the client and hold one page at a time, so
--     rows are matched by name + stack size + buyout, never by index, and the
--     page is re-found before every batch.
--   * Nothing above the buy ceiling or over the max stack is ever bought, even
--     if an older scan queued it.
--   * Purchases over the configured threshold ask first - and the dialog's
--     accept button is itself a click, so that path can still buy.
--   * Gold actually spent is compared against gold expected afterwards, because
--     the client accepting a call is not the server honouring it.

local AMS = AuctionMasterSuite
local Buyer = {}
AMS.Buyer = Buyer

local U

local PAGE_SIZE       = 50
local POST_BUY_SETTLE = 2.0   -- seconds to let the AH catch up after a buyout

Buyer.queue   = {}
Buyer.running = false
Buyer.busy    = false
Buyer.ready   = nil
Buyer.stats   = { auctions = 0, units = 0, spent = 0, skipped = 0 }

function Buyer:OnInit()
    U = AMS.Util
end

-- =============================================================================
-- Queue management
-- =============================================================================

-- entries: the buyList from Analysis:Evaluate, already in the order you want to
-- buy them (cheapest first, or smallest stacks first).
function Buyer:SetQueue(market, entries, ceiling, maxStack, budget)
    self:Stop()
    self.market     = market
    self.searchName = market and market.name
    self.ceiling    = ceiling
    self.maxStack   = maxStack or 0   -- 0 = any stack size
    self.budget     = budget          -- optional copper cap for this run
    self.queue      = {}
    self.ready      = nil
    self.stats      = { auctions = 0, units = 0, spent = 0, skipped = 0 }

    for _, e in ipairs(entries or {}) do
        local priced       = e.unit and (e.buyout or 0) > 0
        local underCeiling = not ceiling or e.unit <= ceiling
        local sizeOk       = (self.maxStack == 0) or (e.count or 1) <= self.maxStack
        if priced and underCeiling and sizeOk then
            self.queue[#self.queue+1] = e
        end
    end
    self.total = #self.queue
    AMS:Fire("QUEUE_CHANGED", self.queue)
    return #self.queue
end

function Buyer:Clear()
    self:Stop()
    self.queue = {}
    self.ready = nil
    self.total = 0
    AMS:Fire("QUEUE_CHANGED", self.queue)
end

function Buyer:Count() return #self.queue end

function Buyer:Remaining()
    local units, cost = 0, 0
    for _, e in ipairs(self.queue) do
        units = units + (e.count or 0)
        cost  = cost + (e.buyout or 0)
    end
    return units, cost
end

function Buyer:Progress()
    local done = (self.total or 0) - #self.queue
    return done, self.total or 0
end

function Buyer:IsReady()
    return self.ready ~= nil and #self.ready.rows > 0
end

function Buyer:Stop(reason)
    if self._ticker then self._ticker:Cancel(); self._ticker = nil end
    if self.running then
        self.running = false
        AMS:Fire("BUY_STATE", false, reason)
        if reason then AMS:Print("auto-prepare stopped: %s", reason) end
    end
end

function Buyer:_Finish()
    self.busy = false
    AMS:Fire("BUY_BUSY", false)
end

local function dropHead(why)
    local B = Buyer
    local e = table.remove(B.queue, 1)
    B.stats.skipped = B.stats.skipped + 1
    if e and why then
        AMS:Print("skipped %dx %s: %s", e.count or 0, e.name or "?", why)
    end
    AMS:Fire("QUEUE_CHANGED", B.queue)
end

-- =============================================================================
-- Prepare: find the page and resolve rows. Buys nothing.
-- =============================================================================

function Buyer:Prepare()
    if self.busy then return false end
    if #self.queue == 0 then
        self.ready = nil
        AMS:Fire("BUY_READY")
        return false
    end
    if not AMS:AtAuctionHouse() then
        self:Stop("the auction house is closed")
        return false
    end

    local entry = self.queue[1]

    -- guards that do not need the auction house at all
    if self.ceiling and entry.unit and entry.unit > self.ceiling then
        dropHead(("%s is above your buy ceiling of %s"):format(
            U:Money(entry.unit, true), U:Money(self.ceiling, true)))
        return false
    end
    if (self.maxStack or 0) > 0 and (entry.count or 1) > self.maxStack then
        dropHead(("stack of %d is over your max buy stack of %d"):format(
            entry.count or 1, self.maxStack))
        return false
    end
    if (entry.buyout or 0) > GetMoney() then
        self:Stop("not enough gold")
        return false
    end

    self.ready = nil
    self.busy  = true
    AMS:Fire("BUY_BUSY", true)

    -- The auction house answers with the pre-purchase page if asked too soon.
    local settle = (AMS.db.buyer and AMS.db.buyer.settleAfterBuy) or POST_BUY_SETTLE
    local since  = GetTime() - (self._lastBuyAt or 0)
    if since < settle then
        U:After(settle - since, function()
            if Buyer.queue[1] ~= entry then Buyer:_Finish() return end
            Buyer:_Hunt(entry, entry.page or 0, 1)
        end)
    else
        self:_Hunt(entry, entry.page or 0, 1)
    end
    return true
end

-- Looks for `entry`, walking every page and then sweeping again before
-- accepting that it is gone. Auctions move between pages constantly as other
-- people buy and post.
-- onFound: given for a hand-picked auction, where `entry` is not the queue head
-- and finding it should not touch the queue.
function Buyer:_Hunt(entry, page, pass, onFound)
    local Scanner = AMS.Scanner
    local fresh = Scanner:FreshPageValidator()

    Scanner:QueryPage(self.searchName, page, function(batch, total, err)
        if err then
            Buyer:_Finish()
            if not onFound then Buyer:Stop(err) else AMS:Print("could not read the auction house: %s", err) end
            return
        end
        if not onFound and Buyer.queue[1] ~= entry then Buyer:_Finish() return end

        if Scanner:FindOnPage(entry) then
            if onFound then onFound() else Buyer:_Resolve() end
            return
        end

        local pages = math.max(1, math.ceil((total or 0) / PAGE_SIZE))
        if page + 1 < pages then
            AMS:Debug("not on page %d of %d, trying the next one", page, pages)
            Buyer:_Hunt(entry, page + 1, pass, onFound)
        elseif pass == 1 then
            AMS:Debug("first pass found nothing; sweeping again from page 0")
            Buyer:_Hunt(entry, 0, 2, onFound)
        else
            Buyer:_Finish()
            if onFound then
                AMS:Print("could not find that auction - it may have sold. Scan again.")
            else
                dropHead("it is no longer listed - it sold, or was cancelled")
                -- keep going: the next one may still be there
                if Buyer.running then Buyer:Prepare() end
            end
        end
    end, {
        -- Accept as soon as the auction we want is visible; otherwise insist on
        -- results that actually changed, so a stale update cannot convince us
        -- the auction has gone.
        validate = function()
            if Scanner:FindOnPage(entry) then return true end
            return fresh()
        end,
        settle = 1.5,
    })
end

-- Indexes the loaded page and resolves as many queued auctions as the batch
-- size allows into concrete row indices, ready for a click to buy.
function Buyer:_Resolve()
    local batch     = GetNumAuctionItems("list") or 0
    local me        = AMS:PlayerName()
    local threshold = (AMS.db.buyer and AMS.db.buyer.confirmAbove) or 0
    local gold      = GetMoney()

    local limit = (AMS.db.buyer and AMS.db.buyer.batchSize) or 10
    if limit <= 0 then limit = PAGE_SIZE end

    -- Index the page by name/stack/price. Two identical listings get two
    -- entries, so a queue holding both resolves to two different rows.
    local rows = {}
    for i = 1, batch do
        local name, _, count, _, _, _, _, _, buyoutPrice, _, _, owner =
            GetAuctionItemInfo("list", i)
        if name and (buyoutPrice or 0) > 0 and not (owner ~= nil and owner == me) then
            local key = ("%s_%d_%d"):format(name, count or 1, buyoutPrice)
            rows[key] = rows[key] or {}
            table.insert(rows[key], i)
        end
    end

    -- Walk the QUEUE, not the page, so "cheapest first" and "small stacks
    -- first" still decide what gets bought when gold runs short.
    local picked, cost, units, needsConfirm = {}, 0, 0, false
    for qi = 1, #self.queue do
        if #picked >= limit then break end
        local e   = self.queue[qi]
        local key = ("%s_%d_%d"):format(e.name or "", e.count or 1, e.buyout or 0)
        local idx = rows[key] and table.remove(rows[key], 1)

        if idx then
            if (e.buyout or 0) > (gold - cost) then break end
            if self.budget and (self.stats.spent + cost + e.buyout) > self.budget then break end
            if threshold > 0 and (e.buyout or 0) > threshold then
                if #picked == 0 then needsConfirm = true end
                break
            end
            picked[#picked+1] = { index = idx, entry = e }
            cost  = cost + (e.buyout or 0)
            units = units + (e.count or 0)
        end
    end

    if #picked == 0 and needsConfirm then
        -- one expensive auction, resolved, waiting on a confirmation click
        local e   = self.queue[1]
        local key = ("%s_%d_%d"):format(e.name or "", e.count or 1, e.buyout or 0)
        -- re-index because the loop above consumed the row
        for i = 1, batch do
            local name, _, count, _, _, _, _, _, buyoutPrice, _, _, owner =
                GetAuctionItemInfo("list", i)
            if name and not (owner ~= nil and owner == me)
               and ("%s_%d_%d"):format(name, count or 1, buyoutPrice or 0) == key then
                picked[1] = { index = i, entry = e }
                cost, units = e.buyout or 0, e.count or 0
                break
            end
        end
    end

    self.ready = {
        rows    = picked,
        cost    = cost,
        units   = units,
        confirm = needsConfirm,
        at      = GetTime(),
    }
    self:_Finish()
    AMS:Fire("BUY_READY", self.ready)

    if #picked == 0 then
        AMS:Debug("page found but nothing resolved; queue head may be unaffordable")
    end
end

-- =============================================================================
-- Execute: the actual purchase. MUST be reached from a click.
-- =============================================================================

local function recordPurchase(entry, paid, quiet)
    local B = Buyer
    B.stats.auctions = B.stats.auctions + 1
    B.stats.units    = B.stats.units + (entry.count or 0)
    B.stats.spent    = B.stats.spent + paid

    AMS.DB:RecordBuy(entry.id, entry.name, entry.count or 0, paid)
    if quiet then
        AMS:Debug("bought %dx %s for %s", entry.count or 0, entry.name or "?", U:Money(paid, true))
    else
        AMS:Print("bought |cffffd070%dx %s|r for %s (%s each)",
            entry.count or 0, entry.name or "?", U:Money(paid), U:Money(entry.unit or 0))
    end

    B._lastBuyAt = GetTime()
    AMS.Scanner:InvalidatePage()
    AMS:Fire("BOUGHT", entry)
end

-- Call ONLY from a click handler. Anywhere else and the purchases are dropped
-- on the floor by the client without a word.
function Buyer:Execute(force)
    local ready = self.ready
    if not ready or #ready.rows == 0 then return 0 end
    if not AMS:AtAuctionHouse() then self.ready = nil return 0 end

    self.ready = nil

    local threshold  = (AMS.db.buyer and AMS.db.buyer.confirmAbove) or 0
    local goldBefore = GetMoney()
    local bought, spent = 0, 0
    local doneEntries = {}

    for _, r in ipairs(ready.rows) do
        -- Re-read the row as it stands right now. Indices from one loaded page
        -- stay valid across the whole sweep because the client does not
        -- renumber until the next update, but the numbers still have to match.
        local name, _, count, _, _, _, _, _, buyoutPrice =
            GetAuctionItemInfo("list", r.index)
        count       = count or 1
        buyoutPrice = buyoutPrice or 0

        local e = r.entry
        if name == e.name and count == e.count and buyoutPrice == e.buyout
           and buyoutPrice > 0
           and buyoutPrice <= (goldBefore - spent)
           and (force or threshold <= 0 or buyoutPrice <= threshold)
        then
            PlaceAuctionBid("list", r.index, buyoutPrice)
            recordPurchase(e, buyoutPrice, #ready.rows > 1)
            doneEntries[e] = true
            bought = bought + 1
            spent  = spent + buyoutPrice
        end
    end

    -- drop everything we bought out of the queue
    if bought > 0 then
        for i = #self.queue, 1, -1 do
            if doneEntries[self.queue[i]] then table.remove(self.queue, i) end
        end
        AMS:Fire("QUEUE_CHANGED", self.queue)

        if bought > 1 then
            AMS:Print("bought |cffffd070%d auctions|r for %s.", bought, U:Money(spent))
        end

        -- The client accepts every one of those calls; the server has the final
        -- say. Comparing gold is the only honest check that the ledger is real.
        local settle = (AMS.db.buyer and AMS.db.buyer.settleAfterBuy) or POST_BUY_SETTLE
        U:After(settle, function()
            local actual = goldBefore - GetMoney()
            if actual < spent * 0.98 then
                AMS:Error("only %s of an expected %s actually left your bags - the auction house refused some of that. Rescan before trusting the numbers.",
                    U:Money(actual), U:Money(spent))
            end
        end)
    end

    -- line up the next batch straight away so the next click is instant
    U:After(0.05, function() Buyer:Prepare() end)
    return bought
end

-- =============================================================================
-- Buying one hand-picked auction
-- =============================================================================
--
-- Wired to the small Buy button on each row of the Market list. A row click is
-- a hardware event, so if the auction happens to be on the page the client
-- currently holds it is bought there and then. If it is not, the page is
-- fetched and you click again - there is no way around the second click.

function Buyer:_BuyIndex(entry, idx)
    local name, _, count, _, _, _, _, _, buyoutPrice = GetAuctionItemInfo("list", idx)
    if name ~= entry.name or (count or 1) ~= entry.count or (buyoutPrice or 0) ~= entry.buyout then
        AMS:Print("that listing has changed - scan again.")
        return false
    end
    if (buyoutPrice or 0) > GetMoney() then
        AMS:Print("not enough gold for that one.")
        return false
    end

    local goldBefore = GetMoney()
    PlaceAuctionBid("list", idx, buyoutPrice)
    recordPurchase(entry, buyoutPrice)

    for i = #self.queue, 1, -1 do
        if self.queue[i] == entry then table.remove(self.queue, i) end
    end
    self.ready = nil
    AMS:Fire("QUEUE_CHANGED", self.queue)

    local settle = (AMS.db.buyer and AMS.db.buyer.settleAfterBuy) or POST_BUY_SETTLE
    U:After(settle, function()
        if goldBefore - GetMoney() < buyoutPrice * 0.98 then
            AMS:Error("that purchase did not go through - the auction house refused it. Scan again.")
        end
    end)
    return true
end

-- Call ONLY from a click handler.
function Buyer:BuyOne(entry, force)
    if not entry or (entry.buyout or 0) <= 0 then return false end
    if not AMS:AtAuctionHouse() then AMS:Print("open the auction house first.") return false end
    if entry.mine then AMS:Print("that is your own auction.") return false end
    if self.busy then AMS:Print("busy - try again in a moment.") return false end
    if (entry.buyout or 0) > GetMoney() then AMS:Print("not enough gold for that one.") return false end

    local idx = AMS.Scanner:FindOnPage(entry)
    if not idx then
        -- Its page is not the one loaded. Fetch it, then the next click buys.
        AMS:Print("finding that auction...")
        self.busy = true
        AMS:Fire("BUY_BUSY", true)
        self.searchName = entry.name or self.searchName
        self:_Hunt(entry, entry.page or 0, 1, function()
            Buyer:_Finish()
            AMS:Print("|cffffd070%dx %s|r is ready - click Buy again.",
                entry.count or 0, entry.name or "?")
            AMS:Fire("MANUAL_READY", entry)
        end)
        return false
    end

    -- Manual picks are allowed to be bad buys, but not silently.
    if not force then
        local m = AMS:CurrentMarket()
        local L = (m and (m.target or 0) > 0) and AMS.Analysis:Levels(m) or nil
        local overpriced = L and L.breakEven > 0 and entry.unit and entry.unit > L.breakEven
        local threshold  = (AMS.db.buyer and AMS.db.buyer.confirmAbove) or 0
        if overpriced or (threshold > 0 and entry.buyout > threshold) then
            self:ConfirmOne(entry, overpriced and L or nil)
            return false
        end
    end

    return self:_BuyIndex(entry, idx)
end

function Buyer:ConfirmOne(entry, levels)
    StaticPopupDialogs["AMS_CONFIRM_ONE"] = {
        text = "%s",
        button1 = "Buy",
        button2 = "Cancel",
        OnAccept = function() Buyer:BuyOne(entry, true) end,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }
    local msg = ("Buy %dx %s for %s?\n(%s each)"):format(
        entry.count or 0, entry.name or "?",
        U:Money(entry.buyout or 0, true), U:Money(entry.unit or 0, true))
    if levels then
        msg = msg .. ("\n\nThat is above your break-even of %s.\nReselling at %s would lose money on every unit.")
            :format(U:Money(levels.breakEven, true), U:Money(levels.target, true))
    end
    StaticPopup_Show("AMS_CONFIRM_ONE", msg)
end

-- What the BUY button does. Must be wired straight to OnClick.
function Buyer:Click()
    if self.busy then return end

    if self.ready and self.ready.confirm and #self.ready.rows > 0 then
        self:ConfirmPurchase(self.ready.rows[1].entry)
        return
    end
    if self:IsReady() then
        self:Execute()
    else
        self:Prepare()
    end
end

function Buyer:ConfirmPurchase(entry)
    StaticPopupDialogs["AMS_CONFIRM_BUY"] = {
        text = "%s",
        button1 = "Buy",
        button2 = "Cancel",
        -- a static popup button is a hardware event, so this can still buy
        OnAccept = function() Buyer:Execute(true) end,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }
    StaticPopup_Show("AMS_CONFIRM_BUY", ("Buy %dx %s for %s?\n(%s each)"):format(
        entry.count or 0, entry.name or "?",
        U:Money(entry.buyout or 0, true), U:Money(entry.unit or 0, true)))
end

-- Kept for the slash command and older call sites.
function Buyer:BuyNext(force)
    if force then return self:Execute(true) end
    return self:Click()
end

-- =============================================================================
-- Auto-prepare
-- =============================================================================
--
-- This cannot buy for you - see the note at the top of the file. What it does
-- is keep the next batch found, resolved and waiting, so clearing a market is
-- one click per batch with no pause in between.

function Buyer:Start()
    if self.running then return end
    if #self.queue == 0 then AMS:Print("buy queue empty.") return end

    self.running = true
    AMS:Fire("BUY_STATE", true)

    local delay = (AMS.db.buyer and AMS.db.buyer.stepDelay) or 0.3
    self._ticker = U:Ticker(delay, function()
        if not Buyer.running then return end
        if Buyer.busy or Buyer:IsReady() then return end
        if #Buyer.queue == 0 then Buyer:Stop("queue finished") return end
        if not AMS:AtAuctionHouse() then Buyer:Stop("the auction house is closed") return end
        Buyer:Prepare()
    end)

    self:Prepare()
end

function Buyer:Toggle()
    if self.running then self:Stop("stopped") else self:Start() end
end
