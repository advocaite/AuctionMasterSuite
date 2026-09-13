-- Auction Master Suite -- Inventory
-- How many units you are holding, and where. Bags are always readable; bank
-- contents are only readable with the bank open, so the last known bank count
-- is cached per character.

local AMS = AuctionMasterSuite
local Inv = {}
AMS.Inventory = Inv

local U

local BACKPACK   = 0
local NUM_BAGS   = 4       -- 0..4
local BANK_MAIN  = -1
local BANK_FIRST = 5       -- bank bags are 5..11 on 3.3.5
local BANK_LAST  = 11

function Inv:OnInit()
    U = AMS.Util
    AMS.charDB.bank   = AMS.charDB.bank   or {}   -- [itemID] = { count=, t= }
    AMS.charDB.listed = AMS.charDB.listed or {}   -- [itemID] = { units=, auctions=, t= }

    AMS:RegisterEvent("BANKFRAME_OPENED", function() Inv.bankOpen = true;  Inv:SnapshotBank() end)
    AMS:RegisterEvent("BANKFRAME_CLOSED", function() Inv.bankOpen = false end)
    AMS:RegisterEvent("PLAYERBANKSLOTS_CHANGED", function()
        if Inv.bankOpen then Inv:SnapshotBank() end
    end)
    AMS:RegisterEvent("BAG_UPDATE", function() AMS:Fire("BAGS_CHANGED") end)
end

-- ---------- bags ----------
local function scanContainers(first, last, itemID, out)
    local total = 0
    for bag = first, last do
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local link = GetContainerItemLink(bag, slot)
            if link and U:ItemIDFromLink(link) == itemID then
                local _, count, locked = GetContainerItemInfo(bag, slot)
                count = count or 1
                total = total + count
                if out then
                    out[#out+1] = { bag = bag, slot = slot, count = count, locked = locked }
                end
            end
        end
    end
    return total
end

-- Units of `itemID` in your bags right now.
function Inv:BagCount(itemID)
    if not itemID then return 0 end
    return scanContainers(BACKPACK, NUM_BAGS, itemID)
end

-- Everything in your bags as { [itemID] = count }. Used to work out what a
-- prospect or a mill actually consumed and produced, by diffing before against
-- after - no chat parsing, no locale strings, and it catches the input too.
function Inv:BagCensus()
    local out = {}
    for bag = BACKPACK, NUM_BAGS do
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local id = U:ItemIDFromLink(link)
                if id then
                    local _, count = GetContainerItemInfo(bag, slot)
                    out[id] = (out[id] or 0) + (count or 1)
                end
            end
        end
    end
    return out
end

-- Every bag stack of the item, largest first (fewest splits when posting).
function Inv:BagStacks(itemID)
    local out = {}
    if not itemID then return out end
    scanContainers(BACKPACK, NUM_BAGS, itemID, out)
    table.sort(out, function(a, b) return a.count > b.count end)
    return out
end

-- ---------- bank ----------
function Inv:SnapshotBank()
    -- Record everything in the bank so counts survive walking away from it.
    local counts = {}
    for bag = BANK_MAIN, BANK_MAIN do
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local id = U:ItemIDFromLink(link)
                local _, count = GetContainerItemInfo(bag, slot)
                if id then counts[id] = (counts[id] or 0) + (count or 1) end
            end
        end
    end
    for bag = BANK_FIRST, BANK_LAST do
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local id = U:ItemIDFromLink(link)
                local _, count = GetContainerItemInfo(bag, slot)
                if id then counts[id] = (counts[id] or 0) + (count or 1) end
            end
        end
    end

    local now = U:Now()
    local bank = {}
    for id, c in pairs(counts) do bank[id] = { count = c, t = now } end
    AMS.charDB.bank = bank
    AMS:Fire("BANK_CHANGED")
end

function Inv:BankCount(itemID)
    if not itemID then return 0, nil end
    local rec = AMS.charDB.bank[itemID]
    if not rec then return 0, nil end
    return rec.count or 0, rec.t
end

-- ---------- listed ----------
-- Fed by Scanner:ScanOwned results.
function Inv:SetListed(entries)
    local now = U:Now()
    local by = {}
    for _, e in ipairs(entries or {}) do
        if e.id then
            local rec = by[e.id] or { units = 0, auctions = 0, singles = 0, t = now, value = 0 }
            rec.units    = rec.units + (e.count or 0)
            rec.auctions = rec.auctions + 1
            rec.value    = rec.value + (e.buyout or 0)
            -- the server caps single-unit auctions per item, so track them
            if (e.count or 0) == 1 then rec.singles = rec.singles + 1 end
            by[e.id] = rec
        end
    end
    AMS.charDB.listed = by
    -- keep the full list too, so the Auctions tab can show every character's
    AMS.DB:SetOwnedAuctions(AMS:PlayerName(), entries or {})
    AMS:Fire("LISTED_CHANGED")
end

function Inv:ListedCount(itemID)
    if not itemID then return 0, 0, nil end
    local rec = AMS.charDB.listed[itemID]
    if not rec then return 0, 0, nil end
    return rec.units or 0, rec.auctions or 0, rec.t
end

-- How many single-unit auctions of this item you currently have posted.
function Inv:ListedSingles(itemID)
    if not itemID then return 0 end
    local rec = AMS.charDB.listed[itemID]
    return rec and rec.singles or 0
end

-- ---------- combined ----------
-- Returns a table: bags, bank, listed, total, plus staleness timestamps.
function Inv:Holdings(itemID)
    local bags = self:BagCount(itemID)
    local bank, bankT = self:BankCount(itemID)
    local listed, auctions, listedT = self:ListedCount(itemID)
    return {
        bags     = bags,
        bank     = bank,
        bankAt   = bankT,
        listed   = listed,
        auctions = auctions,
        listedAt = listedT,
        total    = bags + bank + listed,
    }
end

function Inv:Gold() return GetMoney() end

-- Free bag slots, so the buy queue can warn before it fills you up.
function Inv:FreeSlots()
    local free = 0
    for bag = BACKPACK, NUM_BAGS do
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            if not GetContainerItemLink(bag, slot) then free = free + 1 end
        end
    end
    return free
end
