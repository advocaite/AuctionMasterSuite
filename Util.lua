-- Auction Master Suite -- Util
-- Money formatting/parsing, timers, item helpers, small math.
-- Every gold value in this addon is stored as an integer number of copper.

local AMS = AuctionMasterSuite
local U = {}
AMS.Util = U

U.COPPER_PER_GOLD   = 10000
U.COPPER_PER_SILVER = 100

local GOLD_C, SILVER_C, COPPER_C = "|cffffd700", "|cffc7c7cf", "|cffeda55f"

-- ---------- numbers ----------
function U:Round(v, places)
    local m = 10 ^ (places or 0)
    return math.floor((tonumber(v) or 0) * m + 0.5) / m
end

function U:Clamp(v, lo, hi)
    v = tonumber(v) or lo
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function U:Comma(n)
    n = tostring(math.floor(tonumber(n) or 0))
    local out = n:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

-- ---------- money ----------
-- Money(copper)          -> "|cffffd7001,234g|r 56s 78c" (coloured)
-- Money(copper, true)    -> "1,234g 56s 78c" (plain, for edit boxes)
function U:Money(copper, plain)
    copper = math.floor(tonumber(copper) or 0)
    local sign = ""
    if copper < 0 then sign = "-"; copper = -copper end

    local g  = math.floor(copper / 10000)
    local s  = math.floor((copper % 10000) / 100)
    local c  = copper % 100

    local parts = {}
    if g > 0 then
        parts[#parts+1] = plain and (self:Comma(g).."g") or (GOLD_C..self:Comma(g).."g|r")
    end
    if s > 0 or (g > 0 and c > 0) then
        parts[#parts+1] = plain and (s.."s") or (SILVER_C..s.."s|r")
    end
    if c > 0 or #parts == 0 then
        parts[#parts+1] = plain and (c.."c") or (COPPER_C..c.."c|r")
    end
    return sign..table.concat(parts, " ")
end

-- Compact fixed-width-ish form for table columns: 4.35g / 128g / 12.4kg
function U:MoneyShort(copper)
    local raw = tonumber(copper) or 0
    -- Infinity and NaN arrive here when something upstream divides by a zero
    -- count. On Windows %f renders those as "1.#J", which reads as a corrupt
    -- price rather than as the bug it is, so refuse them outright.
    if raw ~= raw or raw == math.huge or raw == -math.huge then return "-" end
    local g = raw / 10000
    local sign = ""
    if g < 0 then sign = "-"; g = -g end
    if g >= 10000  then return ("%s%.1fkg"):format(sign, g / 1000) end
    if g >= 1000   then return ("%s%.0fg"):format(sign, g) end
    if g >= 100    then return ("%s%.1fg"):format(sign, g) end
    if g >= 1      then return ("%s%.2fg"):format(sign, g) end
    if copper == 0 then return "0g" end
    return ("%s%.2fg"):format(sign, g)
end

-- Accepts "5", "5.5", "5g", "5g50s", "5g 50s 25c", "250s". Returns copper or nil.
-- A bare number is read as GOLD, which is what people type at the AH.
function U:ParseMoney(str)
    if type(str) == "number" then return math.floor(str) end
    if not str then return nil end
    str = tostring(str):lower():gsub("[%s,]", "")
    if str == "" then return nil end

    if str:match("^%-?%d+%.?%d*$") then
        return math.floor(tonumber(str) * 10000 + 0.5)
    end

    local g = tonumber(str:match("(%d+%.?%d*)g")) or 0
    local s = tonumber(str:match("(%d+%.?%d*)s")) or 0
    local c = tonumber(str:match("(%d+%.?%d*)c")) or 0
    if g == 0 and s == 0 and c == 0 then return nil end
    return math.floor(g * 10000 + s * 100 + c + 0.5)
end

function U:Percent(v, places)
    return ("%." .. (places or 1) .. "f%%"):format((tonumber(v) or 0) * 100)
end

-- ---------- time ----------
function U:Now() return time() end

function U:DateShort(t)
    if not t or t == 0 then return "-" end
    return date("%m/%d %H:%M", t)
end

function U:Ago(t)
    if not t or t == 0 then return "never" end
    local d = time() - t
    if d < 60      then return "just now" end
    if d < 3600    then return math.floor(d / 60) .. "m ago" end
    if d < 86400   then return math.floor(d / 3600) .. "h ago" end
    return math.floor(d / 86400) .. "d ago"
end

function U:Duration(seconds)
    seconds = math.floor(tonumber(seconds) or 0)
    if seconds < 60 then return seconds .. "s" end
    if seconds < 3600 then return ("%dm"):format(seconds / 60) end
    if seconds < 86400 then return ("%.1fh"):format(seconds / 3600) end
    return ("%.1fd"):format(seconds / 86400)
end

-- ---------- timers (single shared OnUpdate) ----------
local timerFrame = CreateFrame("Frame", "AuctionMasterSuiteTimerFrame")
timerFrame:Hide()
local timers = {}

timerFrame:SetScript("OnUpdate", function()
    local now = GetTime()
    local i = 1
    while i <= #timers do
        local t = timers[i]
        if t.cancelled then
            table.remove(timers, i)
        elseif now >= t.at then
            if t.interval then
                t.at = now + t.interval
                local ok, err = pcall(t.fn)
                if not ok then AMS:Error("timer: %s", tostring(err)); t.cancelled = true end
                if t.cancelled then table.remove(timers, i) else i = i + 1 end
            else
                table.remove(timers, i)
                local ok, err = pcall(t.fn)
                if not ok then AMS:Error("timer: %s", tostring(err)) end
            end
        else
            i = i + 1
        end
    end
    if #timers == 0 then timerFrame:Hide() end
end)

local function addTimer(t)
    timers[#timers+1] = t
    timerFrame:Show()
    return t
end

-- Returns a handle; call handle:Cancel() to stop it.
local timerMeta = { Cancel = function(self) self.cancelled = true end }
timerMeta.__index = timerMeta

function U:After(delay, fn)
    return addTimer(setmetatable({ at = GetTime() + (delay or 0), fn = fn }, timerMeta))
end

function U:Ticker(interval, fn)
    interval = interval or 0.1
    return addTimer(setmetatable({ at = GetTime() + interval, interval = interval, fn = fn }, timerMeta))
end

-- ---------- items ----------
function U:ItemIDFromLink(link)
    if not link then return nil end
    local id = tostring(link):match("item:(%d+)")
    return id and tonumber(id) or nil
end

-- Safe wrapper: GetItemInfo can return nil for items the client hasn't cached.
function U:ItemInfo(idOrLink)
    if not idOrLink then return nil end
    local name, link, quality, iLevel, reqLevel, class, subclass, maxStack, equipSlot, texture =
        GetItemInfo(idOrLink)
    if not name then return nil end
    return {
        name     = name,
        link     = link,
        quality  = quality,
        iLevel   = iLevel,
        class    = class,
        subclass = subclass,
        maxStack = maxStack or 1,
        texture  = texture,
        id       = self:ItemIDFromLink(link) or (type(idOrLink) == "number" and idOrLink or nil),
    }
end

local QUALITY_HEX = {
    [0] = "9d9d9d", [1] = "ffffff", [2] = "1eff00",
    [3] = "0070dd", [4] = "a335ee", [5] = "ff8000", [6] = "e6cc80",
}

function U:QualityColor(q)
    return "|cff" .. (QUALITY_HEX[q or 1] or "ffffff")
end

function U:ColorItemName(name, quality)
    return self:QualityColor(quality) .. (name or "?") .. "|r"
end

-- ---------- tables ----------
function U:Count(tbl)
    local n = 0
    for _ in pairs(tbl or {}) do n = n + 1 end
    return n
end

function U:Keys(tbl, sorter)
    local out = {}
    for k in pairs(tbl or {}) do out[#out+1] = k end
    table.sort(out, sorter)
    return out
end

-- Quantity-weighted median of {unit=, count=} entries.
function U:WeightedMedian(entries)
    if not entries or #entries == 0 then return 0 end
    local total = 0
    for _, e in ipairs(entries) do total = total + (e.count or 1) end
    if total == 0 then return 0 end

    local sorted = {}
    for i, e in ipairs(entries) do sorted[i] = e end
    table.sort(sorted, function(a, b) return (a.unit or 0) < (b.unit or 0) end)

    local half, run = total / 2, 0
    for _, e in ipairs(sorted) do
        run = run + (e.count or 1)
        if run >= half then return e.unit or 0 end
    end
    return sorted[#sorted].unit or 0
end

-- Plain median of a list of numbers. Used for price baselines, where the median
-- matters: a dump would drag a mean down and hide the very thing we are looking
-- for.
function U:Median(list)
    local n = #(list or {})
    if n == 0 then return 0 end
    local s = {}
    for i = 1, n do s[i] = list[i] end
    table.sort(s)
    if n % 2 == 1 then return s[(n + 1) / 2] end
    return (s[n / 2] + s[n / 2 + 1]) / 2
end

-- Population standard deviation.
function U:StdDev(list)
    local n = #(list or {})
    if n < 2 then return 0 end
    local sum = 0
    for i = 1, n do sum = sum + list[i] end
    local mean = sum / n
    local acc = 0
    for i = 1, n do
        local d = list[i] - mean
        acc = acc + d * d
    end
    return math.sqrt(acc / n)
end

function U:Mean(entries)
    local sum, n = 0, 0
    for _, e in ipairs(entries or {}) do
        sum = sum + (e.unit or 0) * (e.count or 1)
        n   = n + (e.count or 1)
    end
    if n == 0 then return 0 end
    return math.floor(sum / n)
end
