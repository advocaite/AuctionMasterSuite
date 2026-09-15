-- Auction Master Suite -- Watchlist tab
-- Every market you run, ranked by the only thing that matters: how much gold
-- each one returns per day, per gold tied up.
--
-- Deliberately NOT ranked by ROI. 100% margin on something that sells twice a
-- week is a worse business than 20% on something that sells ninety times a
-- day, and a list sorted by ROI will talk you into the wrong one every time.

local AMS = AuctionMasterSuite
local M = AMS:RegisterModule("watchlist", { title = "Watchlist", order = 50 })

local U, Skin, C

function M:OnInit()
    U, Skin = AMS.Util, AMS.Skin
    C = Skin.COLOR
    AMS:Subscribe("MARKETS_CHANGED", function() M:Refresh() end)
    AMS:Subscribe("LEDGER_CHANGED",  function() M:Refresh() end)
    AMS:Subscribe("CURRENT_CHANGED", function() M:Refresh() end)
    AMS:Subscribe("AH_STATE",        function() M:Refresh() end)
    -- item names arriving from the server; only redraw while the tab is up
    AMS:Subscribe("ITEM_CACHED", function()
        local p = M._ui and M._ui.panel
        if p and not p:IsVisible() then return end
        M:Refresh()
    end)
end

-- =============================================================================
-- Item search
-- =============================================================================
--
-- The only way to look up an item you neither own nor have linked: ask the
-- auction house. A partial-name scan returns everything matching, which we
-- group by item so you can pick the one you meant. This is also how you find
-- new markets rather than only managing the ones you already know about.

function M:Search(term)
    if not term or term == "" then return end
    if not AMS:AtAuctionHouse() then
        AMS:Print("open the auction house to search - the item list lives on the server.")
        return
    end
    if self.searching then return end

    self.searching = true
    if self._ui then self._ui.header:SetSub(("searching for '%s'..."):format(term)) end

    AMS.Scanner:ScanItem(term, function(entries, err)
        M.searching = false
        if err then
            AMS:Print("search failed: %s", err)
            M:Refresh()
            return
        end

        local byItem, order = {}, {}
        for _, e in ipairs(entries or {}) do
            if e.id then
                local g = byItem[e.id]
                if not g then
                    g = { id = e.id, name = e.name, link = e.link, quality = e.quality,
                          texture = e.texture, auctions = 0, units = 0, min = nil, rows = {} }
                    byItem[e.id] = g
                    order[#order+1] = g
                end
                g.auctions = g.auctions + 1
                g.units    = g.units + (e.count or 0)
                if e.unit and (not g.min or e.unit < g.min) then g.min = e.unit end
                g.rows[#g.rows+1] = e
            end
        end
        for _, g in ipairs(order) do g.median = U:WeightedMedian(g.rows) end

        -- busiest first: that is usually the one you were looking for
        table.sort(order, function(a, b)
            if a.units ~= b.units then return a.units > b.units end
            return (a.name or "") < (b.name or "")
        end)

        M.results = order
        M.searchTerm = term
        if #order == 0 then
            AMS:Print("nothing on the auction house matches '%s'.", term)
        end
        M:Refresh()
    end, { exact = false })
end

function M:ClearSearch()
    self.results = nil
    self.searchTerm = nil
    self:Refresh()
end

-- =============================================================================
-- Scan every watched market, one after another
-- =============================================================================

function M:ScanAll()
    if self.scanningAll then
        self.cancelAll = true
        AMS:Print("stopping after the current item.")
        return
    end
    if not AMS:AtAuctionHouse() then AMS:Print("open the auction house first.") return end

    local markets = AMS.DB:AllMarkets()
    if #markets == 0 then AMS:Print("nothing on the watchlist yet.") return end

    self.scanningAll = true
    self.cancelAll   = false
    local i = 0

    local function next_()
        i = i + 1
        if self.cancelAll or i > #markets then
            self.scanningAll = false
            AMS:Print("watchlist scan finished (%d of %d).", math.min(i - 1, #markets), #markets)
            M:Refresh()
            return
        end
        local m = markets[i]
        if self._ui then self._ui.header:SetSub(("scanning %d/%d: %s"):format(i, #markets, m.name or "?")) end

        AMS.Analysis:ScanAndEvaluate(m, function(result, entries, err)
            if err then AMS:Print("%s: %s", m.name or "?", err) end
            M:Refresh()
            -- breathe between items; the client throttles queries anyway
            U:After((AMS.db.scan and AMS.db.scan.pageDelay or 0.5) + 0.3, next_)
        end)
    end

    next_()
    self:Refresh()
end

-- =============================================================================
-- UI
-- =============================================================================

function M:BuildUI(parent)
    U, Skin = AMS.Util, AMS.Skin
    C = Skin.COLOR

    local panel = CreateFrame("Frame", nil, parent)
    local ui = { panel = panel }
    self._ui = ui

    local header = Skin:Header(panel, "Watchlist")
    header:SetPoint("TOPLEFT", 8, -8); header:SetPoint("TOPRIGHT", -8, -8)
    ui.header = header

    -- ---------- add / scan strip ----------
    local strip = Skin:Panel(panel)
    strip:SetPoint("TOPLEFT",  header, "BOTTOMLEFT",  0, -6)
    strip:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -6)
    strip:SetHeight(38)

    local slot = Skin:ItemSlot(strip, 26)
    slot:SetPoint("LEFT", 8, 0)
    local function takeCursorItem()
        if not CursorHasItem() then return false end
        local kind, id, link = GetCursorInfo()
        ClearCursor()
        if kind == "item" then
            local info = U:ItemInfo(link or id)
            if info then
                AMS.DB:EnsureMarket(info)
                AMS:SetCurrentMarket(info.id)
                M:Refresh()
            end
            return true
        end
        return false
    end
    slot:SetScript("OnReceiveDrag", takeCursorItem)
    slot:SetScript("OnClick", takeCursorItem)
    Skin:AddTooltip(slot, "Add an item", {"Drag an item here to start watching it."})

    local nameBox = Skin:EditBox(strip, 200, 22)
    nameBox:SetPoint("LEFT", slot, "RIGHT", 8, 0)
    ui.nameBox = nameBox

    local hint = Skin:Label(strip, "click here, then shift-click an item - or type a name and Search", 9, false, C.textDim)
    hint:SetPoint("BOTTOMLEFT", nameBox, "TOPLEFT", 2, 1)

    -- adds an item we have full information for
    local function addLink(link)
        local info = U:ItemInfo(link)
        if not info then
            AMS:Print("could not read that item link.")
            return false
        end
        AMS.DB:EnsureMarket(info)
        AMS:Print("watching |cffffd070%s|r.", info.name)
        M:Refresh()
        return true
    end

    -- shift-clicking a bag item or a chat link lands here
    Skin:EnableLinks(nameBox, function(box, link)
        if not addLink(link) then box:SetText(link) end
        box:SetText("")
        box:ClearFocus()
    end)

    local function addTyped()
        local text = nameBox:GetText()
        if not text or text == "" then return end
        if text:match("|Hitem:") then
            addLink(text)
        else
            AMS.DB:AddMarketByName(text)
        end
        nameBox:SetText("")
        nameBox:ClearFocus()
        M:Refresh()
    end

    local function searchTyped()
        local text = nameBox:GetText()
        if not text or text == "" then return end
        if text:match("|Hitem:") then addTyped() return end
        nameBox:ClearFocus()
        M:Search(text)
    end

    -- Enter searches: looking an item up is the common case, and adding by
    -- exact name only works for things already in your client's cache.
    nameBox:SetScript("OnEnterPressed", searchTyped)

    local searchBtn = Skin:Button(strip, "Search", 66, 22)
    searchBtn:SetPoint("LEFT", nameBox, "RIGHT", 6, 0)
    searchBtn:SetScript("OnClick", searchTyped)
    Skin:AddTooltip(searchBtn, "Search the auction house",
        {"Finds every item on the auction house whose name contains what you typed, so you can",
         "watch things you have never owned or seen.",
         "Needs the auction house open - the item list lives on the server."})
    ui.searchBtn = searchBtn

    local addBtn = Skin:Button(strip, "Add", 52, 22)
    addBtn:SetPoint("LEFT", searchBtn, "RIGHT", 4, 0)
    addBtn:SetScript("OnClick", addTyped)
    Skin:AddTooltip(addBtn, "Add by exact name",
        {"Only works for items your client already knows about - anything you have owned, seen,",
         "or shift-clicked. Use Search for everything else."})

    -- Live filter over the rows already on screen. Nothing to press: the list
    -- narrows as you type, which is what you want once the watchlist is long.
    local filterBox = Skin:EditBox(strip, 150, 22)
    filterBox:SetPoint("LEFT", addBtn, "RIGHT", 12, 0)
    ui.filterBox = filterBox

    local fHint = Skin:Label(strip, "filter the list below", 9, false, C.textDim)
    fHint:SetPoint("BOTTOMLEFT", filterBox, "TOPLEFT", 2, 1)

    local fClear = Skin:Button(strip, "X", 20, 22)
    fClear:SetPoint("LEFT", filterBox, "RIGHT", 3, 0)
    fClear:SetScript("OnClick", function()
        filterBox:SetText("")
        filterBox:ClearFocus()
        M.filter = nil
        M:Refresh()
    end)
    ui.fClear = fClear

    filterBox:SetScript("OnTextChanged", function(s, userInput)
        if not userInput then return end
        local t = s:GetText()
        M.filter = (t ~= "" ) and t:lower() or nil
        M:Refresh()
    end)
    filterBox:SetScript("OnEscapePressed", function(s)
        s:SetText("")
        s:ClearFocus()
        M.filter = nil
        M:Refresh()
    end)

    local scanBtn = Skin:Button(strip, "Scan all", 90, 22)
    scanBtn:SetPoint("RIGHT", -8, 0)
    scanBtn:SetScript("OnClick", function() M:ScanAll() end)
    Skin:AddTooltip(scanBtn, "Scan every watched item",
        {"Walks the whole watchlist one item at a time and refreshes the numbers below.",
         "Takes a few seconds per item because the client throttles auction queries."})
    ui.scanBtn = scanBtn

    -- ---------- table ----------
    local COLS = {
        { text = "ITEM",     width = 128, justify = "LEFT"  },
        { text = "TARGET",   width = 62,  justify = "RIGHT" },
        { text = "LOWEST",   width = 62,  justify = "RIGHT" },
        { text = "TO CLEAR", width = 68,  justify = "RIGHT" },
        { text = "UNITS",    width = 46,  justify = "RIGHT" },
        { text = "PROFIT",   width = 66,  justify = "RIGHT" },
        { text = "ROI",      width = 46,  justify = "RIGHT" },
        { text = "/DAY",     width = 44,  justify = "RIGHT" },
        { text = "SCORE",    width = 46,  justify = "RIGHT" },
        { text = "VS NORM",  width = 62,  min = 54, justify = "RIGHT" },
        { text = "SCANNED",  width = 60,  justify = "RIGHT" },
    }

    local hdr = Skin:ListHeader(panel, COLS)
    hdr:SetPoint("TOPLEFT", strip, "BOTTOMLEFT", 0, -6)
    hdr:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    ui.hdr = hdr

    local cols          -- set just below; rows are born at the current widths
    local list = Skin:ScrollList(panel, 20,
        function(p)
            local r = Skin:Row(p, cols and cols() or COLS)
            r:EnableIcon(1, 14)
            return r
        end,
        function(row, d, idx, alt)
            if not d then
                for i = 1, #COLS do row:Set(i, "") end
                row:SetIcon(nil)
                row:SetScript("OnClick", nil)
                return
            end
            row:Set(1, U:ItemCell(row, d.id, d.name, d.quality))
            row:Set(2, d.target > 0 and U:MoneyShort(d.target) or "not set",
                       d.target > 0 and C.text or C.warn)

            if d.snap then
                local under = (d.snap.buyUnits or 0) > 0
                row:Set(3, (d.snap.min or 0) > 0 and U:MoneyShort(d.snap.min) or "-")
                row:Set(4, under and U:MoneyShort(d.snap.buyCost or 0) or "clear", under and C.text or C.good)
                row:Set(5, under and tostring(d.snap.buyUnits) or "-")
                row:Set(6, under and U:MoneyShort(d.snap.profit or 0) or "-",
                           (d.snap.profit or 0) > 0 and C.good or C.textDim)
                row:Set(7, under and ("%.0f%%"):format((d.snap.roi or 0) * 100) or "-")
                row:Set(8, (d.snap.velocity or 0) > 0 and ("%.1f"):format(d.snap.velocity) or "-")

                local score = d.snap.score or 0
                local scol = C.textDim
                if score >= 70 then scol = C.good elseif score >= 40 then scol = C.warn end
                row:Set(9, tostring(score), scol)

                -- how far from its own normal price, in sigma
                local z = d.snap.z
                if z then
                    local zAlert = (AMS.db.dislocation and AMS.db.dislocation.zAlert) or -1.5
                    row:Set(10, ("%.1f"):format(z),
                        z <= zAlert and C.info or z <= zAlert / 2 and C.warn or C.textDim)
                else
                    row:Set(10, "-", C.textDim)
                end
                row:Set(11, U:Ago(d.snap.t), C.textDim)
            else
                for i = 3, 10 do row:Set(i, "-", C.textDim) end
                row:Set(11, "never", C.textDim)
            end

            local isCurrent = (AMS.currentID == d.id)
            row:Tint(isCurrent and C.bgActive or (alt and C.bgRowAlt or C.bgRow))

            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            row:SetScript("OnClick", function(_, button)
                if button == "RightButton" then
                    M:ConfirmRemove(d)
                else
                    AMS:SetCurrentMarket(d.id)
                    AMS.db.lastMarket = d.id
                    AMS.UI:Show("market")
                end
            end)
        end)
    list:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, -2)
    list:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    list:SetPoint("BOTTOM", panel, "BOTTOM", 0, 34)
    cols = Skin:AutoCols(hdr, list, COLS)
    ui.list = list

    -- ---------- search results (shown instead of the watchlist) ----------
    local RES_COLS = {
        { text = "ITEM",     width = 190, justify = "LEFT"  },
        { text = "AUCTIONS", width = 66,  justify = "RIGHT" },
        { text = "UNITS",    width = 56,  justify = "RIGHT" },
        { text = "LOWEST",   width = 74,  justify = "RIGHT" },
        { text = "MEDIAN",   width = 74,  justify = "RIGHT" },
        { text = "",         width = 70,  min = 60, justify = "RIGHT" },
    }

    local resHdr = Skin:ListHeader(panel, RES_COLS)
    resHdr:SetPoint("TOPLEFT", strip, "BOTTOMLEFT", 0, -6)
    resHdr:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    resHdr:Hide()
    ui.resHdr = resHdr

    local resCols
    local resList = Skin:ScrollList(panel, 20,
        function(p)
            local r = Skin:Row(p, resCols and resCols() or RES_COLS)
            r:EnableIcon(1, 14)
            return r
        end,
        function(row, d, idx, alt)
            if not d then
                for i = 1, #RES_COLS do row:Set(i, "") end
                row:SetIcon(nil)
                row:SetScript("OnClick", nil)
                return
            end
            local watched = AMS.DB:GetMarket(d.id) ~= nil
            row:Set(1, U:ItemCell(row, d.id, d.name, d.quality))
            row:Set(2, tostring(d.auctions))
            row:Set(3, tostring(d.units))
            row:Set(4, d.min and U:MoneyShort(d.min) or "-")
            row:Set(5, (d.median or 0) > 0 and U:MoneyShort(d.median) or "-")
            row:Set(6, watched and "watching" or "click to add",
                    watched and C.good or C.accent)
            row:Tint(alt and C.bgRowAlt or C.bgRow)
            row:RegisterForClicks("LeftButtonUp")
            row:SetScript("OnClick", function()
                local info = U:ItemInfo(d.link or d.id)
                if not info then AMS:Print("could not read that item.") return end
                AMS.DB:EnsureMarket(info)
                AMS:SetCurrentMarket(info.id)
                AMS.db.lastMarket = info.id
                AMS:Print("watching |cffffd070%s|r.", info.name)
                M:Refresh()
            end)
        end)
    resList:SetPoint("TOPLEFT", resHdr, "BOTTOMLEFT", 0, -2)
    resList:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    resList:SetPoint("BOTTOM", panel, "BOTTOM", 0, 34)
    resList:Hide()
    resCols = Skin:AutoCols(resHdr, resList, RES_COLS)
    ui.resList = resList

    local backBtn = Skin:Button(panel, "Back to watchlist", 140, 20)
    backBtn:SetPoint("BOTTOMLEFT", 10, 8)
    backBtn:SetScript("OnClick", function() M:ClearSearch() end)
    backBtn:Hide()
    ui.backBtn = backBtn

    self._footText =
        "Left-click a row to open that market. Right-click to stop watching it.  |  "..
        "SCORE is return per day on the gold you would tie up, not raw ROI.  |  "..
        "VS NORM is how far the cheapest listing sits below that item's own normal price, in standard deviations - "..
        "anything at or under -1.5 is a genuine dislocation and sorts to the top."

    local foot = Skin:Label(panel, self._footText, 10, false, C.textDim)
    foot:SetPoint("BOTTOMLEFT", 10, 10)
    foot:SetPoint("BOTTOMRIGHT", -10, 10)
    foot:SetHeight(24)
    foot:SetJustifyV("BOTTOM")
    ui.foot = foot
    foot:SetWordWrap(true)

    panel:SetScript("OnShow", function() M:Refresh() end)
    self:Refresh()
    return panel
end

function M:ConfirmRemove(d)
    StaticPopupDialogs["AMS_REMOVE_MARKET"] = {
        text = "Stop watching %s?\nIts price history goes with it. Ledger entries are kept.",
        button1 = "Remove", button2 = "Cancel",
        OnAccept = function()
            AMS.DB:RemoveMarket(d.id)
            if AMS.currentID == d.id then AMS:SetCurrentMarket(nil) end
            M:Refresh()
        end,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }
    StaticPopup_Show("AMS_REMOVE_MARKET", d.name or "this item")
end

function M:Refresh()
    local ui = self._ui
    if not ui or not ui.header then return end

    ui.searchBtn:SetEnabled(AMS:AtAuctionHouse() and not self.searching)
    ui.scanBtn:SetText(self.scanningAll and "Stop" or "Scan all")
    ui.scanBtn:SetEnabled(AMS:AtAuctionHouse() or self.scanningAll)

    -- Narrows whatever list is on screen. Plain substring, case-insensitive -
    -- typing is meant to be faster than thinking about pattern syntax, so the
    -- text is escaped rather than treated as a Lua pattern.
    local function matches(name)
        if not self.filter then return true end
        return (name or ""):lower():find(self.filter, 1, true) ~= nil
    end

    -- ---------- search results mode ----------
    if self.results then
        ui.hdr:Hide(); ui.list:Hide(); ui.foot:Hide()
        ui.resHdr:Show(); ui.resList:Show(); ui.backBtn:Show()

        local shown = {}
        for _, r in ipairs(self.results) do
            if matches(r.name) then shown[#shown+1] = r end
        end

        ui.resList:SetData(shown)
        ui.header:SetText("Search results")
        ui.header:SetSub(self.filter
            and ("'%s' - showing %d of %d"):format(self.searchTerm or "", #shown, #self.results)
            or  ("'%s' - %d item%s found"):format(
                    self.searchTerm or "", #self.results, #self.results == 1 and "" or "s"))
        return
    end

    ui.resHdr:Hide(); ui.resList:Hide(); ui.backBtn:Hide()
    ui.hdr:Show(); ui.list:Show(); ui.foot:Show()
    ui.header:SetText("Watchlist")

    local rows, total = {}, 0
    for _, m in ipairs(AMS.DB:AllMarkets()) do
        total = total + 1
        if matches(m.name) then
            rows[#rows+1] = {
                id      = m.id,
                name    = m.name,
                quality = m.quality,
                target  = m.target or 0,
                snap    = AMS.DB:LastSnapshot(m.id),
            }
        end
    end

    -- A dislocation outranks everything: it is worth more and it will not wait.
    -- Otherwise best opportunity first, never-scanned last.
    local zAlert = (AMS.db.dislocation and AMS.db.dislocation.zAlert) or -1.5
    local function dumped(r)
        return (r.snap and r.snap.z and r.snap.z <= zAlert) and 1 or 0
    end
    table.sort(rows, function(a, b)
        local da, db = dumped(a), dumped(b)
        if da ~= db then return da > db end
        local sa = a.snap and a.snap.score or -1
        local sb = b.snap and b.snap.score or -1
        if sa ~= sb then return sa > sb end
        return (a.name or "") < (b.name or "")
    end)

    ui.list:SetData(rows)

    if not self.scanningAll then
        ui.header:SetSub(self.filter
            and ("showing %d of %d market%s"):format(#rows, total, total == 1 and "" or "s")
            or  ("%d market%s"):format(total, total == 1 and "" or "s"))
    end
    if #rows == 0 and self.filter then
        ui.foot:SetText(("Nothing on your watchlist matches '%s'. Clear the filter with the X, or use Search to look it up on the auction house."):format(self.filter))
    else
        ui.foot:SetText(self._footText)
    end
end

function M:OnSlash(arg)
    if arg and arg ~= "" then AMS.DB:AddMarketByName(arg) end
    AMS.UI:Show("watchlist")
end
