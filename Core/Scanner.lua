-- Auction Master Suite -- Scanner
-- Page-by-page auction house scanning for ONE item name at a time.
--
-- Two things about the 3.3.5 auction API drive this whole file:
--
--   1. QueryAuctionItems' getAll flag is throttled to roughly one call every
--      15 minutes and a lot of private servers disable it outright. A targeted
--      name scan of a single commodity is one or two pages, so paging is both
--      faster and safer.
--
--   2. GetAuctionItemInfo("list", i) only reads the page that is CURRENTLY
--      loaded. Scanning page 2 throws away your access to page 1. That is why
--      everything here is built on QueryPage() - the buyer needs to reload a
--      specific page before it can touch an auction on it.
--
-- Queries are gated on CanSendAuctionQuery() rather than a guessed delay,
-- which is what produces "you can't do that yet" spam.

local AMS = AuctionMasterSuite
local Scanner = {}
AMS.Scanner = Scanner

local U
local PAGE_SIZE     = 50
local QUERY_TIMEOUT = 6      -- seconds to wait for AUCTION_ITEM_LIST_UPDATE
local MAX_RETRIES   = 3

Scanner.loadedName = nil     -- which name/page the "list" results currently hold
Scanner.loadedPage = nil

function Scanner:OnInit()
    U = AMS.Util
end

-- =============================================================================
-- Single page query - the primitive everything else uses
-- =============================================================================

local pageJob = nil   -- { name, page, cb, retries, gate, timeout }

-- Long query strings are a known cause of disconnects on 3.3.5 servers.
local function truncateName(name)
    if not name or #name <= 63 then return name end
    local s = name:sub(1, 63)
    -- never leave a half-finished UTF-8 sequence on the end
    while #s > 0 and s:byte(#s) >= 128 and s:byte(#s) < 192 do s = s:sub(1, #s - 1) end
    return s
end

local function clearPageJob()
    if pageJob then
        if pageJob.gate    then pageJob.gate:Cancel()    end
        if pageJob.timeout then pageJob.timeout:Cancel() end
    end
    pageJob = nil
    Scanner.awaiting = false
end

local function runPageQuery()
    local j = pageJob
    if not j then return end

    if not AMS:AtAuctionHouse() then
        local cb = j.cb
        clearPageJob()
        if cb then cb(nil, nil, "the auction house is closed") end
        return
    end

    if j.gate then j.gate:Cancel() end
    j.gate = U:Ticker(0.1, function()
        if pageJob ~= j then return end
        if not CanSendAuctionQuery() then return end

        j.gate:Cancel(); j.gate = nil
        Scanner.awaiting = true
        j.settleUntil = GetTime() + (j.settle or 0)

        AMS:Debug("query '%s' page %d", tostring(j.name), j.page)
        -- Argument shape copied from Auctionator, which is proven against this
        -- client: empty strings for the level range, 0 for the class filters,
        -- and no getAll flag at all. The name is truncated because long query
        -- strings are a known cause of disconnects on 3.3.5 servers.
        QueryAuctionItems(truncateName(j.name), "", "", nil, 0, 0, j.page, nil, nil)

        if j.timeout then j.timeout:Cancel() end
        j.timeout = U:After(QUERY_TIMEOUT + (j.settle or 0), function()
            if pageJob ~= j or not Scanner.awaiting then return end
            -- A validated query that never settled has its answer: what is
            -- loaded is the best we are going to get. Hand it over and let the
            -- caller decide, rather than retrying forever.
            if j.validate then
                local cb = j.cb
                local batch, total = GetNumAuctionItems("list")
                clearPageJob()
                if cb then cb(batch or 0, total or 0, nil) end
                return
            end
            j.retries = (j.retries or 0) + 1
            if j.retries > MAX_RETRIES then
                local cb = j.cb
                clearPageJob()
                if cb then cb(nil, nil, "no response from the auction house") end
            else
                AMS:Debug("page %d timed out, retry %d", j.page, j.retries)
                Scanner.awaiting = false
                runPageQuery()
            end
        end)
    end)
end

-- cb(batchCount, totalAuctions, err) once the page is loaded and readable.
--
-- opts.validate(batch, total) -> boolean. Auction results are GLOBAL to the
-- client: a late update from our own previous query, the default auction house
-- UI, or another addon's scan can all land in the window between our request
-- and the server's answer. Consuming the first update that arrives therefore
-- reads whatever happens to be loaded. When validate is given we keep waiting
-- for a later update until it passes or opts.settle seconds elapse.
function Scanner:QueryPage(name, page, cb, opts)
    if pageJob then
        if cb then cb(nil, nil, "a query is already running") end
        return false
    end
    opts = opts or {}
    pageJob = {
        name = name, page = page or 0, cb = cb, retries = 0,
        validate = opts.validate,
        settle   = opts.validate and (opts.settle or 2) or nil,
    }
    runPageQuery()
    return true
end

function Scanner:PageBusy() return pageJob ~= nil end

local function onListUpdate()
    if not pageJob or not Scanner.awaiting then return end
    local j = pageJob

    local batch, total = GetNumAuctionItems("list")
    batch, total = batch or 0, total or 0

    -- Not the data we asked for? Keep listening; the real answer is still in
    -- flight. Without this the buyer reads another query's page and concludes
    -- the auction it wanted has been sold.
    if j.validate and not j.validate(batch, total) then
        if GetTime() < (j.settleUntil or 0) then
            AMS:Debug("ignoring an auction update that is not the one we asked for (wanted page %d)", j.page)
            return
        end
    end

    local cb = j.cb
    Scanner.awaiting = false
    if j.timeout then j.timeout:Cancel(); j.timeout = nil end
    pageJob = nil

    Scanner.loadedName = j.name
    Scanner.loadedPage = j.page

    if cb then cb(batch, total, nil) end
end

AMS:RegisterEvent("AUCTION_ITEM_LIST_UPDATE", onListUpdate)

-- Anything that changes the auction house invalidates the loaded page.
function Scanner:InvalidatePage()
    self.loadedName, self.loadedPage = nil, nil
end

-- =============================================================================
-- Reading the loaded page
-- =============================================================================

-- Reads the page currently in the "list" results. `exactName` filters out the
-- substring matches the server throws in (searching "Bloodstone" also returns
-- "Bloodstone Band").
function Scanner:ReadPage(exactName, page)
    local batch = GetNumAuctionItems("list") or 0
    local me    = AMS:PlayerName()
    local want  = exactName and exactName:lower()
    local out   = {}

    for i = 1, batch do
        local name, texture, count, quality, canUse, level, minBid, minIncrement,
              buyoutPrice, bidAmount, highBidder, owner = GetAuctionItemInfo("list", i)

        if name and (not want or name:lower() == want) then
            local link = GetAuctionItemLink("list", i)
            count = count or 1
            if count < 1 then count = 1 end
            local buyout = buyoutPrice or 0

            out[#out+1] = {
                index      = i,
                page       = page,
                name       = name,
                link       = link,
                id         = U:ItemIDFromLink(link),
                texture    = texture,
                quality    = quality,
                count      = count,
                minBid     = minBid or 0,
                bid        = bidAmount or 0,
                buyout     = buyout,
                unit       = buyout > 0 and math.floor(buyout / count) or nil,
                owner      = owner,
                mine       = (owner ~= nil and owner == me),
                highBidder = highBidder,
                timeLeft   = GetAuctionItemTimeLeft("list", i),
            }

            if link and name then AMS.DB:ResolvePending(name, link) end
        end
    end
    return out
end

-- Finds an auction on the loaded page matching a queued entry. Matching on
-- content rather than index is the only thing that survives other people
-- buying and posting while you work.
--
-- Name + stack size + buyout is the triple Auctionator uses and it is the right
-- one: seller names are frequently nil on 3.3.5 because the client only knows
-- the ones it has cached, so requiring an owner match would reject perfectly
-- good rows. An exact owner match is preferred when we have one; your own
-- listings are never matched, since you cannot buy them.
function Scanner:FindOnPage(entry)
    local batch = GetNumAuctionItems("list") or 0
    local me = AMS:PlayerName()
    local fallback

    for i = 1, batch do
        local name, _, count, _, _, _, _, _, buyoutPrice, _, _, owner =
            GetAuctionItemInfo("list", i)
        if name == entry.name
           and (count or 1) == entry.count
           and (buyoutPrice or 0) == entry.buyout
        then
            if owner ~= nil and owner == me then
                -- ours; skip
            elseif owner ~= nil and entry.owner ~= nil and owner == entry.owner then
                return i                       -- same seller: the best match there is
            else
                fallback = fallback or i       -- identical listing, unknown seller
            end
        end
    end
    return fallback
end

-- A cheap fingerprint of the page currently loaded, plus whether every row on
-- it is identical. Used to notice the client handing back a page we have
-- already seen, which means our query has not landed yet.
--
-- The all-identical flag matters: a seller who posts 200 lots of "20 @ 2.50g"
-- produces pages that are legitimately indistinguishable, and treating those as
-- duplicates would loop forever.
function Scanner:PageSignature()
    local batch = GetNumAuctionItems("list") or 0
    local parts, allSame = { tostring(batch) }, true
    local first
    for i = 1, batch do
        local name, _, count, _, _, _, minBid, _, buyoutPrice, bidAmount =
            GetAuctionItemInfo("list", i)
        local row = ("%s_%d_%d_%d_%d"):format(name or "", count or 0, minBid or 0,
                                              buyoutPrice or 0, bidAmount or 0)
        parts[#parts+1] = row
        if i == 1 then first = row elseif row ~= first then allSame = false end
    end
    if batch <= 1 then allSame = true end
    return table.concat(parts, "|"), allSame
end

-- Returns a validate function for QueryPage that only accepts results which
-- differ from whatever was on screen when the query went out.
function Scanner:FreshPageValidator()
    local before, beforeAllSame = self:PageSignature()
    return function()
        local sig, allSame = Scanner:PageSignature()
        -- Indistinguishable pages: we cannot tell stale from fresh, so accept
        -- rather than spin.
        if allSame or beforeAllSame then return true end
        return sig ~= before
    end
end

-- =============================================================================
-- Full item scan
-- =============================================================================

local scanJob = nil

local function finishScan(err)
    local j = scanJob
    scanJob = nil
    AMS:Fire("SCAN_STATE", false)
    if not j then return end
    if err then
        AMS:Debug("scan failed: %s", err)
        if j.onDone then j.onDone(nil, err) end
    else
        table.sort(j.entries, function(a, b)
            local au, bu = a.unit, b.unit
            if au and bu then
                if au ~= bu then return au < bu end
                return (a.count or 0) < (b.count or 0)
            end
            if au then return true end
            if bu then return false end
            return (a.name or "") < (b.name or "")
        end)
        -- Every scan prices everything it saw, not just what it was asked for.
        -- A partial-name search reads whole pages of other people's items and
        -- those are real, current prices; a reagent should not sit unpriced
        -- because we only ever met it sideways.
        --
        -- The scan's own item is skipped: Analysis writes it a full snapshot
        -- with target, buy plan and verdict, and a bare price on top of that
        -- would bury the real one.
        local primary = j.exact and j.entries[1] and j.entries[1].id or nil
        AMS.DB:ObserveEntries(j.entries, primary)

        if j.onDone then j.onDone(j.entries, nil) end
    end
end

local function scanPage()
    local j = scanJob
    if not j then return end

    Scanner:QueryPage(j.name, j.page, function(batch, total, err)
        if not scanJob then return end
        if err then finishScan(err) return end

        -- If the client hands back a page identical to the one before it, our
        -- query has not landed yet and we are looking at stale results. Ask
        -- again rather than recording the same auctions twice and losing a
        -- page. (Auctionator's CheckForDuplicatePage does the same thing.)
        local sig, allSame = Scanner:PageSignature()
        if j.page > 0 and not allSame and sig == j.lastSig then
            j.dupRetries = (j.dupRetries or 0) + 1
            if j.dupRetries <= 3 then
                AMS:Debug("page %d came back identical to the previous one; asking again (%d)",
                    j.page, j.dupRetries)
                U:After(0.4, scanPage)
                return
            end
        end
        j.lastSig, j.dupRetries = sig, 0

        local rows = Scanner:ReadPage(j.exact and j.name or nil, j.page)
        for _, row in ipairs(rows) do j.entries[#j.entries+1] = row end

        local maxPages = (AMS.db.scan and AMS.db.scan.maxPages) or 25
        local scanned  = (j.page + 1) * PAGE_SIZE
        AMS:Fire("SCAN_PROGRESS", j.page + 1, math.ceil((total or 0) / PAGE_SIZE), #j.entries)

        if batch >= PAGE_SIZE and scanned < (total or 0) and (j.page + 1) < maxPages then
            j.page = j.page + 1
            U:After((AMS.db.scan and AMS.db.scan.pageDelay) or 0.5, scanPage)
        else
            j.pages = j.page + 1
            finishScan(nil)
        end
    end)
end

-- Scanner:ScanItem("Bloodstone", function(entries, err) ... end)
function Scanner:ScanItem(name, onDone, opts)
    opts = opts or {}
    if scanJob or pageJob then
        if onDone then onDone(nil, "a scan is already running") end
        return false
    end
    if not name or name == "" then
        if onDone then onDone(nil, "no item name") end
        return false
    end
    if not AMS:AtAuctionHouse() then
        if onDone then onDone(nil, "open the auction house first") end
        return false
    end

    scanJob = {
        name    = name,
        exact   = opts.exact ~= false,
        page    = 0,
        entries = {},
        onDone  = onDone,
    }
    AMS:Fire("SCAN_STATE", true, name)
    scanPage()
    return true
end

function Scanner:IsScanning() return scanJob ~= nil end

function Scanner:Abort(reason)
    if scanJob then
        clearPageJob()
        finishScan(reason or "aborted")
    elseif pageJob then
        local cb = pageJob.cb
        clearPageJob()
        if cb then cb(nil, nil, reason or "aborted") end
    end
end

-- =============================================================================
-- Your own auctions (the "Auctions" tab list)
-- =============================================================================

-- The owner list is not something you can reliably request. Nothing else on
-- this client calls GetOwnerAuctionItems at all: Auctionator and the rest just
-- register AUCTION_OWNED_LIST_UPDATE and read whatever is there, because the
-- auction house's own Auctions tab is what populates it when shown.
--
-- So we do all three - show the tab, ask anyway, and poll for the data - and
-- treat "the event never came" as a reason to read what is loaded rather than
-- as a failure. An empty auction list is a perfectly good answer too.

local ownerJob = nil
local OWNER_WAIT = 5      -- seconds to give the server before taking what we have

local function finishOwner(err)
    local oj = ownerJob
    ownerJob = nil
    Scanner.awaitingOwner = false
    if Scanner._ownerPoll then Scanner._ownerPoll:Cancel(); Scanner._ownerPoll = nil end
    if not oj then return end

    -- put the auction house back on whatever tab the user was looking at
    if oj.prevTab and oj.prevTab ~= 3 then
        local tab = _G["AuctionFrameTab"..oj.prevTab]
        if tab and tab.Click then tab:Click() end
    end

    if oj.onDone then oj.onDone(err and nil or oj.entries, err) end
end

-- Signature of the owner page currently loaded, so we can tell a fresh page
-- from the one we already read.
local function ownerSignature()
    local batch = GetNumAuctionItems("owner") or 0
    local parts = { tostring(batch) }
    for i = 1, batch do
        local name, _, count, _, _, _, minBid, _, buyoutPrice = GetAuctionItemInfo("owner", i)
        parts[#parts+1] = ("%s_%d_%d_%d"):format(name or "", count or 0, minBid or 0, buyoutPrice or 0)
    end
    return table.concat(parts, "|")
end

local collectOwner

local function requestOwnerPage()
    local oj = ownerJob
    if not oj then return end
    if not AMS:AtAuctionHouse() then finishOwner("the auction house is closed") return end

    Scanner.awaitingOwner = true
    if GetOwnerAuctionItems then GetOwnerAuctionItems(oj.page) end

    local started = GetTime()
    if Scanner._ownerPoll then Scanner._ownerPoll:Cancel() end
    Scanner._ownerPoll = U:Ticker(0.25, function()
        if ownerJob ~= oj or not Scanner.awaitingOwner then return end
        local sig = ownerSignature()
        -- fresh data, or we have waited long enough to stop hoping
        if (sig ~= oj.lastSig and (GetNumAuctionItems("owner") or 0) > 0)
           or GetTime() - started > OWNER_WAIT then
            collectOwner()
        end
    end)
end

collectOwner = function()
    local oj = ownerJob
    if not oj then return end
    Scanner.awaitingOwner = false
    if Scanner._ownerPoll then Scanner._ownerPoll:Cancel(); Scanner._ownerPoll = nil end

    oj.lastSig = ownerSignature()

    local batch, total = GetNumAuctionItems("owner")
    batch, total = batch or 0, total or 0

    for i = 1, batch do
        local name, texture, count, quality, canUse, level, minBid, minIncrement,
              buyoutPrice, bidAmount, highBidder, owner, saleStatus = GetAuctionItemInfo("owner", i)
        if name then
            local link = GetAuctionItemLink("owner", i)
            -- A sold auction reports a count of 0, and dividing a buyout by
            -- that produced an infinity the money formatter rendered as junk.
            count = count or 1
            if count < 1 then count = 1 end
            oj.entries[#oj.entries+1] = {
                name     = name,
                link     = link,
                id       = U:ItemIDFromLink(link),
                texture  = texture,
                quality  = quality,
                count    = count,
                buyout   = buyoutPrice or 0,
                unit     = (buyoutPrice or 0) > 0 and math.floor(buyoutPrice / count) or nil,
                minBid   = minBid or 0,
                bid      = bidAmount or 0,
                -- saleStatus 1 means it has sold and the gold is on its way;
                -- the mail is held for an hour, so this is the only place the
                -- client will tell you about it before then
                sold     = saleStatus == 1,
                hasBidder = (highBidder ~= nil and highBidder ~= 0 and highBidder ~= false),
                timeLeft = GetAuctionItemTimeLeft("owner", i),
            }
        end
    end

    -- The owner list is NOT paged: it hands back everything you have listed in
    -- one batch, which is why Auctionator just loops 1..GetNumAuctionItems and
    -- never asks for a page. Trying to page it re-reads the same auctions over
    -- and over - that is what turned 495 auctions into 5808.
    if total > batch then
        AMS:Debug("owner list reported %d total but only %d readable", total, batch)
    end
    finishOwner(nil)
end

-- The event is a bonus, not a requirement: if it arrives we stop waiting early.
AMS:RegisterEvent("AUCTION_OWNED_LIST_UPDATE", function()
    if ownerJob and Scanner.awaitingOwner then collectOwner() end
end)

function Scanner:ScanOwned(onDone)
    if ownerJob then
        if onDone then onDone(nil, "already reading your auctions") end
        return false
    end
    if not AMS:AtAuctionHouse() then
        if onDone then onDone(nil, "open the auction house first") end
        return false
    end

    ownerJob = { page = 0, entries = {}, onDone = onDone }

    -- Showing the Auctions tab is what actually makes the client fetch this
    -- list; asking for it without the tab having been opened is why this used
    -- to sit there and time out. We remember the tab you were on and put it
    -- back when we are done.
    ownerJob.prevTab = (AuctionFrame and PanelTemplates_GetSelectedTab)
        and PanelTemplates_GetSelectedTab(AuctionFrame) or nil
    if AuctionFrameTab3 and AuctionFrameAuctions and not AuctionFrameAuctions:IsShown() then
        AuctionFrameTab3:Click()
    end

    requestOwnerPage()
    return true
end
