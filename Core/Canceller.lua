-- Auction Master Suite -- Canceller
--
-- Pulling your own auctions back off the board. Like buying, this only works
-- from inside a real mouse click, so every entry point here must be wired
-- straight to an OnClick.
--
-- Two costs worth knowing before you press anything:
--
--   * Cancelling forfeits the deposit. Always. Relisting at a better price has
--     to earn that back before it is worth doing.
--   * Cancelling an auction somebody has BID on costs you a further fee, and
--     the bidder's gold is returned. Those are skipped by default.
--
-- Sold auctions cannot be cancelled at all - the gold is already on its way.
--
-- Indices are walked downwards: cancelling index i shifts everything above it
-- down by one, so working from the top means every index we have not used yet
-- is still valid. Auctionator walks upwards and gets away with it; downwards is
-- correct whether or not the client renumbers.

local AMS = AuctionMasterSuite
local Canceller = {}
AMS.Canceller = Canceller

local U

function Canceller:OnInit()
    U = AMS.Util
end

-- match(name, count, buyout, hasBid, index) -> boolean
-- Returns cancelled count, units, and estimated deposit forfeited.
function Canceller:CancelMatching(match, opts)
    opts = opts or {}
    if not AMS:AtAuctionHouse() then
        AMS:Print("open the auction house first.")
        return 0
    end
    if type(match) ~= "function" then return 0 end

    local n = GetNumAuctionItems("owner") or 0
    local cancelled, units, skippedBid, skippedSold = 0, 0, 0, 0

    for i = n, 1, -1 do
        local name, _, count, _, _, _, _, _, buyoutPrice, _, highBidder, _, saleStatus =
            GetAuctionItemInfo("owner", i)
        if name then
            count = count or 1
            if count < 1 then count = 1 end
            local sold   = (saleStatus == 1)
            local hasBid = (highBidder ~= nil and highBidder ~= 0 and highBidder ~= false)

            if match(name, count, buyoutPrice or 0, hasBid, i) then
                if sold then
                    skippedSold = skippedSold + 1
                elseif hasBid and not opts.includeBid then
                    skippedBid = skippedBid + 1
                else
                    CancelAuction(i)
                    cancelled = cancelled + 1
                    units     = units + count
                end
            end
        end
    end

    if skippedSold > 0 then
        AMS:Print("%d auction%s already sold - the gold is on its way, so those stay.",
            skippedSold, skippedSold == 1 and "" or "s")
    end
    if skippedBid > 0 then
        AMS:Print("|cffff9040%d auction%s left alone because %s been bid on|r - cancelling those costs an extra fee.",
            skippedBid, skippedBid == 1 and "" or "s", skippedBid == 1 and "it has" or "they have")
    end

    if cancelled > 0 then
        AMS.Scanner:InvalidatePage()
        AMS:Fire("AUCTIONS_CANCELLED", cancelled, units)
    end
    return cancelled, units
end

-- One specific auction, identified by content rather than by index.
function Canceller:CancelEntry(entry, opts)
    if not entry then return 0 end
    local used = false
    return self:CancelMatching(function(name, count, buyout)
        if used then return false end
        if name == entry.name and count == (entry.count or 1) and buyout == (entry.buyout or 0) then
            used = true
            return true
        end
        return false
    end, opts)
end

-- Everything you have listed for one item at one exact unit price.
function Canceller:CancelAtPrice(itemName, unit, opts)
    if not itemName or not unit then return 0 end
    return self:CancelMatching(function(name, count, buyout)
        if name ~= itemName then return false end
        return count > 0 and math.floor(buyout / count) == unit
    end, opts)
end

-- Everything you have listed for one item, at any price.
function Canceller:CancelAllForItem(itemName, opts)
    if not itemName then return 0 end
    return self:CancelMatching(function(name) return name == itemName end, opts)
end

-- What a cancel would cost you in forfeited deposit, as far as we can tell.
function Canceller:DepositCost(market, units)
    if not market or not market.deposit then return nil end
    return market.deposit * (units or 0)
end
