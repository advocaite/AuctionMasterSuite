-- Auction Master Suite -- Ledger
-- Sales and expiries come from the mailbox, because that is the only place the
-- 3.3.5 client tells you the truth about what happened to your auctions.
--
--   "Auction successful: X"  money = sale price minus the AH cut, plus the
--                            deposit back. No items attached, so the stack
--                            size is recovered by matching against the post
--                            record we wrote when we listed it.
--   "Auction expired: X"     items come back, deposit is gone. The attachment
--                            gives us the exact stack size.
--   "Auction cancelled: X"   same, you pulled it yourself.
--   "Auction won: X"         deliberately ignored - the mail carries no price,
--                            and the Buyer already recorded what you paid.
--
-- Sale mail is held for an hour before it arrives, so timestamps are corrected
-- by that much. Mails are deduplicated on subject + money + arrival, so
-- rescanning the inbox as often as you like is harmless.

local AMS = AuctionMasterSuite
local Ledger = {}
AMS.Ledger = Ledger

local U

local MAIL_LIFETIME_DAYS = 30
local SALE_MAIL_DELAY    = 3600     -- sold auctions sit in limbo for an hour

-- Turn a Blizzard subject format string into a Lua capture pattern so this
-- works on any client locale, not just enUS.
local function subjectPattern(fmt)
    if not fmt then return nil end
    local escaped = fmt:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    escaped = escaped:gsub("%%%%s", "(.+)")
    return "^" .. escaped .. "$"
end

local P_SOLD, P_EXPIRED, P_CANCELLED

function Ledger:OnInit()
    U = AMS.Util
    P_SOLD      = subjectPattern(AUCTION_SOLD_MAIL_SUBJECT      or "Auction successful: %s")
    P_EXPIRED   = subjectPattern(AUCTION_EXPIRED_MAIL_SUBJECT   or "Auction expired: %s")
    P_CANCELLED = subjectPattern(AUCTION_REMOVED_MAIL_SUBJECT   or "Auction cancelled: %s")

    AMS:RegisterEvent("MAIL_SHOW",         function() Ledger:ScanInbox() end)
    AMS:RegisterEvent("MAIL_INBOX_UPDATE", function() Ledger:ScanInbox() end)

    self:PruneSeen()
end

-- =============================================================================
-- Helpers
-- =============================================================================

local function resolveItemID(name)
    if not name then return nil end
    for id, m in pairs(AMS.data.markets) do
        if m.name == name then return id end
    end
    local info = U:ItemInfo(name)
    return info and info.id or nil
end

local function arrivalTime(daysLeft)
    local left = tonumber(daysLeft) or MAIL_LIFETIME_DAYS
    local age  = (MAIL_LIFETIME_DAYS - left) * 86400
    if age < 0 then age = 0 end
    return math.floor(U:Now() - age)
end

-- Two mails from the same auction batch can be genuinely identical, so the key
-- includes the arrival time bucketed to five minutes.
local function seenKey(subject, money, itemCount, arrived)
    return ("%s|%d|%d|%d"):format(tostring(subject), money or 0, itemCount or 0,
        math.floor((arrived or 0) / 300))
end

function Ledger:PruneSeen()
    local cutoff = U:Now() - (MAIL_LIFETIME_DAYS + 15) * 86400
    local seen = AMS.data.mailSeen
    for k, t in pairs(seen) do
        if (t or 0) < cutoff then seen[k] = nil end
    end
end

-- =============================================================================
-- Inbox scan
-- =============================================================================

function Ledger:ScanInbox()
    if not U then return end
    local num = GetInboxNumItems()
    if not num or num == 0 then return end

    local seen = AMS.data.mailSeen
    local newSales, newExpiries = 0, 0

    for i = 1, num do
        local _, _, sender, subject, money, _, daysLeft, itemCount = GetInboxHeaderInfo(i)
        if subject then
            local arrived = arrivalTime(daysLeft)
            local key = seenKey(subject, money, itemCount, arrived)

            if not seen[key] then
                local handled = false

                -- ----- sold -----
                local soldName = P_SOLD and subject:match(P_SOLD)
                if soldName and (money or 0) > 0 then
                    local id  = resolveItemID(soldName)
                    local cut = AMS.Config:Cut()
                    local post = AMS.DB:MatchPost(id, soldName, money, cut)
                    local count = post and post.stack or nil

                    if not count then
                        -- No matching post (posted before this addon, or by
                        -- hand). Fall back to the market's preferred stack.
                        local m = id and AMS.DB:GetMarket(id)
                        count = m and m.stack or 1
                    end
                    if post then post.state = "sold" end

                    if id then
                        AMS.DB:RecordSale(id, soldName, count, money,
                            math.max(0, arrived - SALE_MAIL_DELAY), post)
                        newSales = newSales + 1
                    else
                        AMS:Debug("sale of '%s' ignored - item not in your cache", soldName)
                    end
                    handled = true
                end

                -- ----- expired / cancelled -----
                if not handled then
                    local expName = (P_EXPIRED   and subject:match(P_EXPIRED))
                                 or (P_CANCELLED and subject:match(P_CANCELLED))
                    if expName then
                        local id = resolveItemID(expName)
                        -- returned items are attached, so we get the real count
                        local count = 0
                        for slot = 1, (itemCount or 0) do
                            local _, _, c = GetInboxItem(i, slot)
                            count = count + (c or 0)
                        end
                        if count == 0 then count = 1 end

                        local m = id and AMS.DB:GetMarket(id)
                        local deposit = (m and m.deposit or 0) * count

                        local post = AMS.DB:MatchPost(id, expName, 0, 0)
                        if post then post.state = "expired" end

                        if id then
                            AMS.DB:RecordExpiry(id, expName, count, deposit, arrived)
                            newExpiries = newExpiries + 1
                        end
                        handled = true
                    end
                end

                if handled then seen[key] = U:Now() end
            end
        end
    end

    if newSales > 0 or newExpiries > 0 then
        AMS:Debug("mail: %d sales, %d expiries recorded", newSales, newExpiries)
        AMS:Fire("LEDGER_CHANGED")
    end
end

-- =============================================================================
-- Reporting helpers used by the Books tab
-- =============================================================================

-- Merged, newest-first activity feed for one item (or everything if nil).
function Ledger:Feed(itemID, limit)
    local out = {}
    local who = AMS.DB:Scope()
    local function add(kind, e)
        if itemID and e.id ~= itemID then return end
        if who and e.who ~= who then return end
        out[#out+1] = {
            kind = kind, t = e.t, id = e.id, name = e.name, who = e.who,
            count = e.count, amount = e.total or e.net or e.deposit or 0,
            unit = e.unit, stack = e.stack,
        }
    end
    for _, e in ipairs(AMS.data.buys)     do add("buy",     e) end
    for _, e in ipairs(AMS.data.sales)    do add("sale",    e) end
    for _, e in ipairs(AMS.data.posts)    do add("post",    e) end
    for _, e in ipairs(AMS.data.expiries) do add("expire",  e) end

    table.sort(out, function(a, b) return (a.t or 0) > (b.t or 0) end)
    if limit and #out > limit then
        for i = #out, limit + 1, -1 do out[i] = nil end
    end
    return out
end

-- =============================================================================
-- Breakdowns for the Insights tab
-- =============================================================================

-- Slices the ledger by whatever dimension you ask for and returns
-- { {key, label, spent, earned, lost, profit, units, sales, buys}, ... }
--
-- dimension: "character" | "item" | "day" | "hour" | "weekday"
local WEEKDAYS = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }

function Ledger:Breakdown(dimension, days)
    days = days or 30
    local cutoff = U:Now() - days * 86400
    local who = AMS.DB:Scope()
    local buckets, order = {}, {}

    local function keyOf(e)
        if dimension == "character" then
            return e.who or "(unrecorded)", e.who or "(unrecorded)"
        elseif dimension == "item" then
            return e.id or e.name or "?", e.name or "?"
        elseif dimension == "hour" then
            local h = tonumber(date("%H", e.t or 0)) or 0
            return h, ("%02d:00"):format(h)
        elseif dimension == "weekday" then
            local w = tonumber(date("%w", e.t or 0)) or 0
            return w, WEEKDAYS[w + 1] or "?"
        end
        return date("%m/%d", e.t or 0), date("%m/%d", e.t or 0)
    end

    local function bucket(e)
        local k, label = keyOf(e)
        local b = buckets[k]
        if not b then
            b = { key = k, label = label, spent = 0, earned = 0, lost = 0,
                  units = 0, sales = 0, buys = 0, t = e.t }
            buckets[k] = b
            order[#order+1] = b
        end
        return b
    end

    local function want(e)
        if (e.t or 0) < cutoff then return false end
        if who and e.who ~= who then return false end
        return true
    end

    for _, e in ipairs(AMS.data.buys) do
        if want(e) then local b = bucket(e); b.spent = b.spent + (e.total or 0); b.buys = b.buys + 1 end
    end
    for _, e in ipairs(AMS.data.sales) do
        if want(e) then
            local b = bucket(e)
            b.earned = b.earned + (e.net or 0)
            b.units  = b.units + (e.count or 0)
            b.sales  = b.sales + 1
        end
    end
    for _, e in ipairs(AMS.data.expiries) do
        if want(e) then local b = bucket(e); b.lost = b.lost + (e.deposit or 0) end
    end

    for _, b in ipairs(order) do b.profit = b.earned - b.spent - b.lost end

    -- time-like dimensions read as a series; everything else ranks by size
    if dimension == "hour" or dimension == "weekday" then
        table.sort(order, function(a, b) return a.key < b.key end)
    elseif dimension == "day" then
        table.sort(order, function(a, b) return (a.t or 0) < (b.t or 0) end)
    else
        table.sort(order, function(a, b) return a.profit > b.profit end)
    end
    return order
end

-- Profit per day over the last `days` days, for the Books chart.
function Ledger:DailyProfit(itemID, days)
    days = days or 14
    local cutoff = U:Now() - days * 86400
    local buckets, order = {}, {}

    local function bucket(t)
        local key = date("%m/%d", t)
        local b = buckets[key]
        if not b then
            b = { day = key, t = t, spent = 0, earned = 0, lost = 0 }
            buckets[key] = b
            order[#order+1] = b
        end
        return b
    end

    local who = AMS.DB:Scope()
    local function want(e)
        if itemID and e.id ~= itemID then return false end
        if who and e.who ~= who then return false end
        return (e.t or 0) >= cutoff
    end

    for _, e in ipairs(AMS.data.buys) do
        if want(e) then bucket(e.t).spent = bucket(e.t).spent + (e.total or 0) end
    end
    for _, e in ipairs(AMS.data.sales) do
        if want(e) then bucket(e.t).earned = bucket(e.t).earned + (e.net or 0) end
    end
    for _, e in ipairs(AMS.data.expiries) do
        if want(e) then bucket(e.t).lost = bucket(e.t).lost + (e.deposit or 0) end
    end

    for _, b in ipairs(order) do b.profit = b.earned - b.spent - b.lost end
    table.sort(order, function(a, b) return (a.t or 0) < (b.t or 0) end)
    return order
end
