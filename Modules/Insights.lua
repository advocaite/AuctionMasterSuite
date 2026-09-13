-- Auction Master Suite -- Insights tab
--
-- Two things that do not fit anywhere else:
--
--   Portfolio  slice the ledger by character, item, day, hour or weekday and
--              look at it. The hour and weekday views are the interesting ones:
--              they tell you when your market actually buys, which is when you
--              want your stock listed.
--
--   Appraise   score an item for the buy-bulk-sell-singles strategy off a live
--              scan, so you can judge something you have never traded.

local AMS = AuctionMasterSuite
local M = AMS:RegisterModule("insights", { title = "Insights", order = 35 })

local U, Skin, C

local DIMENSIONS = {
    { text = "By character", value = "character" },
    { text = "By item",      value = "item" },
    { text = "By day",       value = "day" },
    { text = "By hour",      value = "hour" },
    { text = "By weekday",   value = "weekday" },
}

local METRICS = {
    { text = "Profit",     value = "profit" },
    { text = "Revenue",    value = "earned" },
    { text = "Spend",      value = "spent" },
    { text = "Units sold", value = "units" },
}

local RANGES = {
    { text = "Last 7 days",  value = 7 },
    { text = "Last 14 days", value = 14 },
    { text = "Last 30 days", value = 30 },
    { text = "Everything",   value = 3650 },
}

function M:OnInit()
    U, Skin = AMS.Util, AMS.Skin
    C = Skin.COLOR
    self.mode = "portfolio"
    AMS:Subscribe("LEDGER_CHANGED",  function() M:Refresh() end)
    AMS:Subscribe("CURRENT_CHANGED", function() M:Refresh() end)
    AMS:Subscribe("MARKETS_CHANGED", function() M:Refresh() end)
    AMS:Subscribe("AH_STATE",        function() M:Refresh() end)
end

-- =============================================================================
-- UI
-- =============================================================================

function M:BuildUI(parent)
    U, Skin = AMS.Util, AMS.Skin
    C = Skin.COLOR

    local panel = CreateFrame("Frame", nil, parent)
    local ui = {}
    self._ui = ui

    local header = Skin:Header(panel, "Insights")
    header:SetPoint("TOPLEFT", 8, -8); header:SetPoint("TOPRIGHT", -8, -8)
    ui.header = header

    -- ---------- mode switch ----------
    local portBtn = Skin:TabButton(header, "Portfolio", 90, 22)
    portBtn:SetPoint("RIGHT", -8, 0)
    portBtn:SetScript("OnClick", function() M.mode = "portfolio"; M:Refresh() end)
    ui.portBtn = portBtn

    local apprBtn = Skin:TabButton(header, "Appraise", 90, 22)
    apprBtn:SetPoint("RIGHT", portBtn, "LEFT", -4, 0)
    apprBtn:SetScript("OnClick", function() M.mode = "appraise"; M:Refresh() end)
    ui.apprBtn = apprBtn

    -- ---------- controls ----------
    local strip = Skin:Panel(panel)
    strip:SetPoint("TOPLEFT",  header, "BOTTOMLEFT",  0, -6)
    strip:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -6)
    strip:SetHeight(38)
    ui.strip = strip

    local x = 10
    local function drop(label, w, items, default, onChange)
        local l = Skin:Label(strip, label, 10, false, C.textDim)
        l:SetPoint("TOPLEFT", x, -4)
        local d = Skin:Dropdown(strip, w, 18)
        d:SetPoint("TOPLEFT", x, -16)
        d:SetItems(items)
        d:SetValue(default, nil, true)
        d.OnValueChanged = onChange
        x = x + w + 12
        return d, l
    end

    ui.dimDrop, ui.dimLbl = drop("SLICE BY", 120, DIMENSIONS, "character", function() M:Refresh() end)
    ui.metDrop, ui.metLbl = drop("SHOWING",  110, METRICS,    "profit",    function() M:Refresh() end)
    ui.rngDrop, ui.rngLbl = drop("PERIOD",   120, RANGES,     30,          function() M:Refresh() end)

    local apprScan = Skin:Button(strip, "Scan & appraise", 130, 20)
    apprScan:SetPoint("TOPLEFT", x, -16)
    apprScan:SetScript("OnClick", function()
        local mk = AMS:GetModule("market")
        if mk then mk:Rescan() end
    end)
    ui.apprScan = apprScan

    -- ---------- chart ----------
    local chart = Skin:MiniChart(panel, 150)
    chart:SetPoint("TOPLEFT",  strip, "BOTTOMLEFT",  0, -6)
    chart:SetPoint("TOPRIGHT", strip, "BOTTOMRIGHT", 0, -6)
    ui.chart = chart

    -- ---------- breakdown table ----------
    local COLS = {
        { text = "",        width = 150, justify = "LEFT"  },
        { text = "PROFIT",  width = 86,  justify = "RIGHT" },
        { text = "REVENUE", width = 86,  justify = "RIGHT" },
        { text = "SPEND",   width = 86,  justify = "RIGHT" },
        { text = "DEPOSITS",width = 76,  justify = "RIGHT" },
        { text = "UNITS",   width = 56,  justify = "RIGHT" },
        { text = "SALES",   width = 52,  justify = "RIGHT" },
        { text = "SHARE",   width = 60,  justify = "RIGHT" },
    }

    local hdr = Skin:ListHeader(panel, COLS)
    hdr:SetPoint("TOPLEFT", chart, "BOTTOMLEFT", 0, -8)
    hdr:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    ui.hdr = hdr

    local cols
    local list = Skin:ScrollList(panel, 19,
        function(p) return Skin:Row(p, cols and cols() or COLS) end,
        function(row, d, idx, alt)
            if not d then for i = 1, #COLS do row:Set(i, "") end return end
            row:Set(1, d.label or "?")
            row:Set(2, U:MoneyShort(d.profit), d.profit >= 0 and C.good or C.bad)
            row:Set(3, U:MoneyShort(d.earned))
            row:Set(4, U:MoneyShort(d.spent))
            row:Set(5, d.lost > 0 and U:MoneyShort(d.lost) or "-", d.lost > 0 and C.warn or C.textDim)
            row:Set(6, tostring(d.units))
            row:Set(7, tostring(d.sales))
            row:Set(8, d.share and U:Percent(d.share, 0) or "-", C.textDim)
            row:Tint(alt and C.bgRowAlt or C.bgRow)
        end)
    list:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, -2)
    list:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    list:SetPoint("BOTTOM", panel, "BOTTOM", 0, 8)
    cols = Skin:AutoCols(hdr, list, COLS)
    ui.list = list

    -- =========================================================================
    -- Appraise view
    -- =========================================================================
    local appr = CreateFrame("Frame", nil, panel)
    appr:SetPoint("TOPLEFT",  strip, "BOTTOMLEFT",  0, -6)
    appr:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -8, 8)
    appr:Hide()
    ui.appr = appr

    local verdict = Skin:Verdict(appr)
    verdict:SetPoint("TOPLEFT", 0, 0)
    verdict:SetPoint("TOPRIGHT", 0, 0)
    verdict:SetHeight(62)
    ui.verdict = verdict

    -- big letter grade
    local gradeBox = Skin:Panel(appr)
    gradeBox:SetPoint("TOPLEFT", verdict, "BOTTOMLEFT", 0, -6)
    gradeBox:SetSize(96, 96)
    local grade = Skin:Label(gradeBox, "?", 48, true, C.textDim)
    grade:SetPoint("CENTER", 0, 8)
    grade:SetJustifyH("CENTER")
    local gradeSub = Skin:Label(gradeBox, "", 10, false, C.textDim)
    gradeSub:SetPoint("BOTTOM", 0, 8)
    gradeSub:SetPoint("LEFT", 4, 0); gradeSub:SetPoint("RIGHT", -4, 0)
    gradeSub:SetJustifyH("CENTER")
    ui.grade, ui.gradeSub = grade, gradeSub

    local factors = Skin:Panel(appr)
    factors:SetPoint("TOPLEFT", gradeBox, "TOPRIGHT", 6, 0)
    factors:SetPoint("RIGHT", appr, "RIGHT", 0, 0)
    factors:SetHeight(96)
    ui.factors = factors

    ui.factorLines = {}
    for i = 1, 5 do
        local f = CreateFrame("Frame", nil, factors)
        f:SetHeight(17)
        f:SetPoint("TOPLEFT", 10, -6 - (i - 1) * 18)
        f:SetPoint("RIGHT", -10, 0)

        local lbl = Skin:Label(f, "", 11, false, C.textDim)
        lbl:SetPoint("LEFT", 0, 0); lbl:SetWidth(150)

        local val = Skin:Label(f, "", 11, true, C.text)
        val:SetPoint("LEFT", lbl, "RIGHT", 6, 0); val:SetWidth(120)

        local note = Skin:Label(f, "", 10, false, C.textDim)
        note:SetPoint("LEFT", val, "RIGHT", 6, 0); note:SetPoint("RIGHT", 0, 0)
        note:SetWordWrap(false)

        ui.factorLines[i] = { frame = f, label = lbl, value = val, note = note }
    end

    -- price ladder: what each stack size is actually fetching
    local ladderLbl = Skin:Label(appr, "WHAT EACH STACK SIZE FETCHES PER UNIT", 10, true, C.accentDim)
    ladderLbl:SetPoint("TOPLEFT", gradeBox, "BOTTOMLEFT", 2, -10)

    local ladder = Skin:MiniChart(appr, 110)
    ladder:SetPoint("TOPLEFT",  ladderLbl, "BOTTOMLEFT", -2, -4)
    ladder:SetPoint("RIGHT", appr, "RIGHT", 0, 0)
    ui.ladder = ladder

    local apprNote = Skin:Label(appr, "", 11, false, C.textDim)
    apprNote:SetPoint("TOPLEFT",  ladder, "BOTTOMLEFT",  2, -8)
    apprNote:SetPoint("BOTTOMRIGHT", appr, "BOTTOMRIGHT", -2, 4)
    apprNote:SetJustifyV("TOP")
    apprNote:SetWordWrap(true)
    ui.apprNote = apprNote

    panel:SetScript("OnShow", function() M:Refresh() end)
    self:Refresh()
    return panel
end

-- =============================================================================
-- Refresh
-- =============================================================================

function M:Refresh()
    local ui = self._ui
    if not ui or not ui.header then return end

    local portfolio = (self.mode ~= "appraise")
    ui.portBtn:SetSelected(portfolio)
    ui.apprBtn:SetSelected(not portfolio)

    -- SetShown does not exist on this client
    local function show(f, on) if on then f:Show() else f:Hide() end end
    show(ui.dimDrop,  portfolio)
    show(ui.metDrop,  portfolio)
    show(ui.rngDrop,  portfolio)
    show(ui.dimLbl,   portfolio)
    show(ui.metLbl,   portfolio)
    show(ui.rngLbl,   portfolio)
    show(ui.apprScan, not portfolio)

    if portfolio then
        ui.appr:Hide()
        ui.chart:Show(); ui.hdr:Show(); ui.list:Show()
        self:RefreshPortfolio()
    else
        ui.chart:Hide(); ui.hdr:Hide(); ui.list:Hide()
        ui.appr:Show()
        self:RefreshAppraisal()
    end
end

function M:RefreshPortfolio()
    local ui = self._ui
    local dim    = ui.dimDrop:GetValue() or "character"
    local metric = ui.metDrop:GetValue() or "profit"
    local range  = ui.rngDrop:GetValue() or 30

    local rows = AMS.Ledger:Breakdown(dim, range)

    -- share of the total, so a row means something on its own
    local total = 0
    for _, b in ipairs(rows) do total = total + math.abs(b[metric] or 0) end
    for _, b in ipairs(rows) do
        b.share = total > 0 and (math.abs(b[metric] or 0) / total) or nil
    end

    local metricName = "Profit"
    for _, mm in ipairs(METRICS) do if mm.value == metric then metricName = mm.text end end

    local data = {}
    for _, b in ipairs(rows) do
        local v = b[metric] or 0
        local money = (metric ~= "units")
        data[#data+1] = {
            value = math.abs(v),
            label = b.label,
            color = (metric == "profit" and v < 0) and C.bad
                 or (metric == "spent") and C.warn
                 or C.good,
            tipTitle = b.label,
            tip = {
                ("%s: %s%s"):format(metricName,
                    money and U:Money(v, true) or tostring(v),
                    (metric == "profit" and v < 0) and "  (a loss)" or ""),
                " ",
                ("Revenue:  %s"):format(U:Money(b.earned, true)),
                ("Spend:    %s"):format(U:Money(b.spent, true)),
                ("Deposits lost: %s"):format(U:Money(b.lost, true)),
                ("Profit:   %s"):format(U:Money(b.profit, true)),
                " ",
                ("%d units across %d sale%s, %d purchase%s"):format(
                    b.units, b.sales, b.sales == 1 and "" or "s",
                    b.buys, b.buys == 1 and "" or "s"),
                b.share and ("%s of the total"):format(U:Percent(b.share, 0)) or "",
            },
        }
    end
    ui.chart:SetData(data)

    local dimName = "character"
    for _, dd in ipairs(DIMENSIONS) do
        if dd.value == dim then dimName = dd.text:gsub("^By ", "") end
    end
    ui.chart:SetInfo(("%s by %s"):format(metricName, dimName),
        {("One bar per %s over the selected period. Bar height is the size of the number,"):format(dimName),
         "so a loss shows as a tall red bar rather than an invisible one - check the colour.",
         " ",
         "By hour and by weekday are the ones worth studying: they show when your market",
         "actually buys, which is when your stock wants to be listed.",
         " ",
         "Hover any bar for the full breakdown behind it."})
    ui.list:SetData(rows)

    local scope = AMS.DB:Scope()
    ui.hdr.cells[1]:SetText(dim == "character" and "CHARACTER"
                         or dim == "item"      and "ITEM"
                         or dim == "hour"      and "HOUR OF DAY"
                         or dim == "weekday"   and "WEEKDAY"
                         or "DAY")
    ui.header:SetText("Insights")
    ui.header:SetSub(("%d row%s%s"):format(#rows, #rows == 1 and "" or "s",
        scope and (" - "..scope) or ""))
end

function M:RefreshAppraisal()
    local ui = self._ui
    local m  = AMS:CurrentMarket()
    local mk = AMS:GetModule("market")
    local entries = (mk and mk.entries) or nil

    ui.header:SetText(m and ("Appraise - "..U:ColorItemName(m.name, m.quality)) or "Appraise")
    ui.header:SetSub(entries and ("from a scan "..U:Ago(mk.scannedAt or 0)) or "not scanned")
    ui.apprScan:SetEnabled(m ~= nil and AMS:AtAuctionHouse())

    if not m then
        ui.verdict:Set("PICK AN ITEM", "Choose a market first - Watchlist has a Search for items you do not own.", C.textDim)
        ui.grade:SetText("?"); ui.grade:SetTextColor(unpack(C.textDim))
        ui.gradeSub:SetText("")
        for _, f in ipairs(ui.factorLines) do f.frame:Hide() end
        ui.ladder:SetData({})
        ui.apprNote:SetText("")
        return
    end

    local a = AMS.Analysis:Appraise(m, entries)

    ui.verdict:Set(a.verdict, a.detail, a.color)
    ui.grade:SetText(a.grade or "?")
    ui.grade:SetTextColor(unpack(a.color or C.textDim))
    ui.gradeSub:SetText(("score %d/100"):format(a.score or 0))

    for i, f in ipairs(ui.factorLines) do
        local d = a.lines[i]
        if d then
            f.frame:Show()
            f.label:SetText(d.label)
            f.value:SetText(d.value)
            f.value:SetTextColor(unpack(d.tone or C.text))
            f.note:SetText(d.note or "")
        else
            f.frame:Hide()
        end
    end

    -- price ladder by stack size, straight off the scan
    local ladder = {}
    if entries then
        local buckets, order = {}, {}
        for _, e in ipairs(entries) do
            if e.unit and not e.mine then
                local k = e.count <= 1 and 1
                       or e.count <= 4 and 2
                       or e.count <= 9 and 5
                       or e.count <= 19 and 10
                       or 20
                local b = buckets[k]
                if not b then
                    b = { k = k, rows = {},
                          label = k == 1 and "x1" or k == 2 and "x2-4" or k == 5 and "x5-9"
                               or k == 10 and "x10-19" or "x20+" }
                    buckets[k] = b; order[#order+1] = b
                end
                b.rows[#b.rows+1] = e
            end
        end
        table.sort(order, function(x, y) return x.k < y.k end)

        -- everything is compared against the bulk end of the ladder
        local bulkRef
        for _, b in ipairs(order) do
            if b.k >= 5 then bulkRef = bulkRef or U:WeightedMedian(b.rows) end
        end

        for _, b in ipairs(order) do
            local med   = U:WeightedMedian(b.rows)
            local units = 0
            for _, e in ipairs(b.rows) do units = units + (e.count or 0) end

            local vs = "nothing bulk listed to compare against"
            if bulkRef and bulkRef > 0 then
                local diff = (med - bulkRef) / bulkRef * 100
                vs = b.k >= 5 and ("this is the bulk baseline")
                    or ("%+.0f%% against bulk (%s per unit)"):format(diff, U:Money(bulkRef, true))
            end

            ladder[#ladder+1] = {
                value = med,
                label = ("%s  %s"):format(b.label, U:MoneyShort(med)),
                color = b.k == 1 and C.accent or C.info,
                tipTitle = ("Stacks of %s"):format(b.label:gsub("^x", "")),
                tip = {
                    ("Median unit price: %s"):format(U:Money(med, true)),
                    ("%d auction%s, %d units"):format(#b.rows, #b.rows == 1 and "" or "s", units),
                    " ",
                    vs,
                    " ",
                    b.k == 1
                        and "This is what you would be selling at."
                        or  "This is what you would be buying at.",
                },
            }
        end
    end
    ui.ladder:SetData(ladder)
    ui.ladder:SetInfo("What each stack size fetches per unit",
        {"Every listing on the auction house, grouped by how many units it holds, showing the",
         "median price PER UNIT in each group. Your own auctions are excluded, so this measures",
         "the market rather than your own pricing back at you.",
         " ",
         "Descending bars - x1 taller than x20 - mean singles carry a premium, and that gap is",
         "the entire trade: buy the stacks, sell the singles.",
         " ",
         "A flat ladder means there is nothing to harvest by splitting, however cheap the",
         "stacks look. You would just be paying the 5% cut twice."})

    if entries then
        ui.apprNote:SetText(
            "Taller bars on the left mean singles fetch more per unit than stacks - that gap is the whole trade. "..
            "A flat ladder means there is nothing to harvest by splitting stacks, however cheap they look. "..
            "Your own auctions are excluded so this measures the market rather than your own pricing.")
    else
        ui.apprNote:SetText("Scan the item to appraise it. The measurement needs live listings: it compares what other people's singles fetch against what their bulk stacks fetch.")
    end
end

function M:OnSlash(arg)
    if arg == "appraise" then self.mode = "appraise" end
    AMS.UI:Show("insights")
end
