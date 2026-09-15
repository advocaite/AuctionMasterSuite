-- Auction Master Suite -- History tab
-- What the market has been doing, so you can tell "cheap" from "falling".

local AMS = AuctionMasterSuite
local M = AMS:RegisterModule("history", { title = "History", order = 40 })

local U, Skin, C

function M:OnInit()
    U, Skin = AMS.Util, AMS.Skin
    C = Skin.COLOR
    AMS:Subscribe("CURRENT_CHANGED", function() M:Refresh() end)
    AMS:Subscribe("HISTORY_CHANGED", function() M:Refresh() end)
end

function M:BuildUI(parent)
    U, Skin = AMS.Util, AMS.Skin
    C = Skin.COLOR

    local panel = CreateFrame("Frame", nil, parent)
    local ui = { panel = panel }
    self._ui = ui

    local header = Skin:Header(panel, "History")
    header:SetPoint("TOPLEFT", 8, -8); header:SetPoint("TOPRIGHT", -8, -8)
    ui.header = header

    -- Same slot as Market and Post: shows which item these numbers are of, and
    -- takes a drop so you can jump straight here from your bags.
    local slot = Skin:ItemSlot(header, 22)
    slot:SetPoint("LEFT", 8, 0)
    ui.slot = slot

    local function takeCursorItem()
        if not CursorHasItem() then return false end
        local kind, id, link = GetCursorInfo()
        ClearCursor()
        if kind ~= "item" then return false end
        local info = U:ItemInfo(link or id)
        if not info then
            AMS:Print("that item is not in your client cache yet.")
            return true
        end
        AMS.DB:EnsureMarket(info)
        AMS:SetCurrentMarket(info.id)
        AMS.db.lastMarket = info.id
        M:Refresh()
        return true
    end
    slot:SetScript("OnReceiveDrag", takeCursorItem)
    slot:SetScript("OnClick", takeCursorItem)

    header.text:ClearAllPoints()
    header.text:SetPoint("LEFT", slot, "RIGHT", 8, 0)

    local wipeBtn = Skin:Button(header, "Clear", 60, 20)
    wipeBtn:SetPoint("RIGHT", -8, 0)
    wipeBtn:SetScript("OnClick", function()
        local m = AMS:CurrentMarket()
        if m then AMS.DB:WipeHistory(m.id); M:Refresh() end
    end)
    Skin:AddTooltip(wipeBtn, "Clear history", {"Deletes the scan snapshots for this item only."})

    -- ---------- trend summary ----------
    local summary = Skin:Panel(panel)
    summary:SetPoint("TOPLEFT",  header, "BOTTOMLEFT",  0, -6)
    summary:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -6)
    summary:SetHeight(52)

    local trend = Skin:Label(summary, "", 13, true, C.text)
    trend:SetPoint("TOPLEFT", 10, -8)
    trend:SetPoint("RIGHT", -10, 0)
    ui.trend = trend

    local trendSub = Skin:Label(summary, "", 11, false, C.textDim)
    trendSub:SetPoint("TOPLEFT", 10, -28)
    trendSub:SetPoint("BOTTOMRIGHT", -10, 6)
    trendSub:SetJustifyV("TOP")
    trendSub:SetWordWrap(true)
    ui.trendSub = trendSub

    -- ---------- charts ----------
    local priceLbl = Skin:Label(panel, "MEDIAN PRICE PER UNIT  (line = your target)", 10, true, C.accentDim)
    priceLbl:SetPoint("TOPLEFT", summary, "BOTTOMLEFT", 2, -8)

    local priceChart = Skin:MiniChart(panel, 110)
    priceChart:SetPoint("TOPLEFT",  priceLbl, "BOTTOMLEFT", -2, -4)
    priceChart:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    priceChart:SetInfo("Median price per unit, per day",
        {"One bar per day, from every scan you ran that day. Bar height is the quantity-weighted",
         "median unit price - the price a typical unit was actually listed at, not the cheapest.",
         " ",
         "The horizontal line is your target. Green means the market sat at or above it, amber",
         "means it slipped, red means it fell well below.",
         " ",
         "Hover a bar for that day's numbers. Bars only appear for days you scanned."})
    ui.priceChart = priceChart

    local supplyLbl = Skin:Label(panel, "SUPPLY UNDER YOUR TARGET", 10, true, C.accentDim)
    supplyLbl:SetPoint("TOPLEFT", priceChart, "BOTTOMLEFT", 2, -8)

    local supplyChart = Skin:MiniChart(panel, 90)
    supplyChart:SetPoint("TOPLEFT", supplyLbl, "BOTTOMLEFT", -2, -4)
    supplyChart:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    supplyChart:SetInfo("How much stock was listed, per day",
        {"Total units on the auction house each day, yours included. Read it against the price",
         "chart above: supply climbing while price holds means demand is absorbing it, supply",
         "climbing while price falls means someone is dumping.",
         " ",
         "Hover a bar to see how much of it was yours."})
    ui.supplyChart = supplyChart

    -- ---------- table ----------
    local COLS = {
        { text = "DAY",      width = 56, justify = "LEFT"  },
        { text = "LOWEST",   width = 68, justify = "RIGHT" },
        { text = "MEDIAN",   width = 68, justify = "RIGHT" },
        { text = "SUPPLY",   width = 58, justify = "RIGHT" },
        { text = "YOURS",    width = 52, justify = "RIGHT" },
        { text = "SCANS",    width = 48, justify = "RIGHT" },
        { text = "VS TARGET",width = 78, justify = "RIGHT" },
    }

    local hdr = Skin:ListHeader(panel, COLS)
    hdr:SetPoint("TOPLEFT", supplyChart, "BOTTOMLEFT", 0, -8)
    hdr:SetPoint("RIGHT", panel, "RIGHT", -8, 0)

    local list = Skin:ScrollList(panel, 18,
        function(p) return Skin:Row(p, ui.cols and ui.cols() or COLS) end,
        function(row, d, idx, alt)
            if not d then for i = 1, #COLS do row:Set(i, "") end return end
            row:Set(1, d.day, C.textDim)
            row:Set(2, d.min > 0 and U:MoneyShort(d.min) or "-")
            row:Set(3, d.median > 0 and U:MoneyShort(d.median) or "-")
            row:Set(4, tostring(d.supply))
            row:Set(5, tostring(d.mine), C.accent)
            row:Set(6, tostring(d.n), C.textDim)
            local m = AMS:CurrentMarket()
            if m and (m.target or 0) > 0 and d.median > 0 then
                local pct = (d.median - m.target) / m.target
                row:Set(7, ("%+.0f%%"):format(pct * 100),
                    pct >= -0.02 and C.good or pct < -0.2 and C.bad or C.warn)
            else
                row:Set(7, "-", C.textDim)
            end
            row:Tint(alt and C.bgRowAlt or C.bgRow)
        end)
    list:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, -2)
    list:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    list:SetPoint("BOTTOM", panel, "BOTTOM", 0, 8)
    ui.cols = Skin:AutoCols(hdr, list, COLS)
    ui.list = list

    panel:SetScript("OnShow", function() M:Refresh() end)
    self:Refresh()
    return panel
end

function M:Refresh()
    local ui = self._ui
    if not ui or not ui.header then return end

    local m = AMS:CurrentMarket()
    if not m then
        ui.slot:SetItem(nil, nil)
        ui.header:SetText("History")
        ui.header:SetSub("no item selected")
        ui.trend:SetText("")
        ui.trendSub:SetText("Pick an item on the Market tab.")
        ui.priceChart:SetData({})
        ui.supplyChart:SetData({})
        ui.list:SetData({})
        return
    end

    local hName, hQuality, hTexture, hLink = U:ItemName(m.id, m.name)
    ui.slot:SetItem(hLink, hTexture)
    ui.header:SetText("History - "..U:ColorItemName(hName, hQuality or m.quality))

    local days = AMS.DB:DailyHistory(m.id, 21)
    local snaps = AMS.DB:GetSnapshots(m.id)
    ui.header:SetSub(("%d snapshots over %d days"):format(#snaps, #days))

    -- charts
    local priceData, supplyData = {}, {}
    for _, d in ipairs(days) do
        local col = C.accent
        if (m.target or 0) > 0 then
            if d.median >= m.target * 0.98 then col = C.good
            elseif d.median < m.target * 0.8 then col = C.bad
            else col = C.warn end
        end

        local vsTarget = "no target set"
        if (m.target or 0) > 0 and d.median > 0 then
            vsTarget = ("%+.0f%% against your target of %s")
                :format((d.median - m.target) / m.target * 100, U:Money(m.target, true))
        end

        priceData[#priceData+1] = {
            value = d.median, label = d.day, color = col,
            tipTitle = ("%s - %s"):format(m.name or "?", d.day),
            tip = {
                ("Median unit price: %s"):format(U:Money(d.median, true)),
                ("Cheapest seen:     %s"):format(d.min > 0 and U:Money(d.min, true) or "-"),
                vsTarget,
                ("Built from %d scan%s that day"):format(d.n, d.n == 1 and "" or "s"),
            },
        }
        supplyData[#supplyData+1] = {
            value = d.supply, label = d.day, color = C.info,
            tipTitle = ("Supply - %s"):format(d.day),
            tip = {
                ("%d units on the auction house"):format(d.supply),
                ("%d of them yours"):format(d.mine),
                d.supply > d.mine
                    and ("%d units of competition"):format(d.supply - d.mine)
                    or "no competition that day",
            },
        }
    end
    ui.priceChart:SetBaseline(m.target or 0)
    ui.priceChart:SetData(priceData)
    ui.supplyChart:SetData(supplyData)
    ui.list:SetData(days)

    -- trend summary: compare the first and last thirds of the window
    if #days < 2 then
        ui.trend:SetText("NOT ENOUGH HISTORY")
        ui.trend:SetTextColor(unpack(C.textDim))
        ui.trendSub:SetText("Scan this item a few times over a few days and the trend, the supply pressure and the refill rate all appear here.")
        return
    end

    local third = math.max(1, math.floor(#days / 3))
    local function avgMedian(from, to)
        local sum, n = 0, 0
        for i = from, to do
            if days[i] and days[i].median > 0 then sum = sum + days[i].median; n = n + 1 end
        end
        return n > 0 and (sum / n) or 0
    end
    local early = avgMedian(1, third)
    local late  = avgMedian(#days - third + 1, #days)

    local change = (early > 0) and ((late - early) / early) or 0
    local dir, col
    if change > 0.05 then dir, col = "RISING", C.good
    elseif change < -0.05 then dir, col = "FALLING", C.bad
    else dir, col = "FLAT", C.textDim end

    ui.trend:SetText(("%s  %+.0f%%"):format(dir, change * 100))
    ui.trend:SetTextColor(unpack(col))

    local refill, hours = AMS.DB:RefillRate(m.id)
    local last = AMS.DB:LastSnapshot(m.id)
    local bits = {}
    bits[#bits+1] = ("median %s -> %s over %d days")
        :format(U:MoneyShort(early), U:MoneyShort(late), #days)
    if refill then
        bits[#bits+1] = ("competitors add about %.1f units/hr under your target (measured over %.1fh)")
            :format(refill, hours or 0)
    end
    if last and (m.target or 0) > 0 then
        bits[#bits+1] = ("last scan: %d units under target costing %s to clear")
            :format(last.underUnits or 0, U:MoneyShort(last.underCost or 0))
    end
    ui.trendSub:SetText(table.concat(bits, "  |  "))
end

function M:OnSlash() AMS.UI:Show("history") end
