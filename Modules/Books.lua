-- Auction Master Suite -- Books tab
-- What you actually made, from the mailbox rather than from optimism.
--
-- Covers EVERY item that has been through your hands, not just the watchlist.
-- The odds and ends you clear out of your bags belong here too: noticing that
-- some random thing sells briskly is how you find the next market worth
-- running, and that only happens if it is in front of you. Untracked items get
-- a "+ track" marker and become a market when you click them.
--
-- The character dropdown filters everything below it, so it doubles as a
-- per-character report: pick an alt to see exactly what that alt bought, sold
-- and made, item by item.

local AMS = AuctionMasterSuite
local M = AMS:RegisterModule("books", { title = "Books", order = 30 })

local U, Skin, C

function M:OnInit()
    U, Skin = AMS.Util, AMS.Skin
    C = Skin.COLOR
    AMS:Subscribe("LEDGER_CHANGED",  function() M:Refresh() end)
    AMS:Subscribe("MARKETS_CHANGED", function() M:Refresh() end)
    AMS:Subscribe("CURRENT_CHANGED", function() M:Refresh() end)
    -- item names arriving from the server; only redraw while the tab is up
    AMS:Subscribe("ITEM_CACHED", function()
        local p = M._ui and M._ui.panel
        if p and not p:IsVisible() then return end
        M:Refresh()
    end)
end

function M:BuildUI(parent)
    U, Skin = AMS.Util, AMS.Skin
    C = Skin.COLOR

    local panel = CreateFrame("Frame", nil, parent)
    local ui = { panel = panel }
    self._ui = ui

    local header = Skin:Header(panel, "Books")
    header:SetPoint("TOPLEFT", 8, -8); header:SetPoint("TOPRIGHT", -8, -8)
    ui.header = header

    -- Whose books? Data is shared by every character on the realm, so the
    -- default is everyone; this splits it out when you want to know which alt
    -- is actually earning.
    local scopeDrop = Skin:Dropdown(header, 150, 20)
    scopeDrop:SetPoint("RIGHT", -8, 0)
    scopeDrop.OnValueChanged = function(_, v)
        AMS.DB:SetScope(v ~= "*" and v or nil)
        M:Refresh()
    end
    Skin:AddTooltip(scopeDrop, "Whose books",
        {"Markets, price history and the ledger are shared by every character on this realm -",
         "your bank alt's purchases are part of the same business as your main's.",
         "Picking one filters everything below into a report for that character alone.",
         " ",
         "Entries recorded before per-character tracking have no name and only show under",
         "All characters. /ams attribute <name> stamps them retrospectively."})
    ui.scopeDrop = scopeDrop

    header.sub:ClearAllPoints()
    header.sub:SetPoint("RIGHT", scopeDrop, "LEFT", -10, 0)

    -- ---------- totals strip ----------
    local strip = Skin:Panel(panel)
    strip:SetPoint("TOPLEFT",  header, "BOTTOMLEFT",  0, -6)
    strip:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -6)
    strip:SetHeight(56)

    ui.totals = {}
    local function bigStat(key, label, index)
        local box = CreateFrame("Frame", nil, strip)
        box:SetWidth(10)
        local l = Skin:Label(box, label, 10, false, C.textDim)
        l:SetPoint("TOPLEFT", 0, -10)
        local v = Skin:Label(box, "-", 17, true, C.text)
        v:SetPoint("TOPLEFT", 0, -26)
        ui.totals[key] = { box = box, label = l, value = v, index = index }
    end

    bigStat("spent",  "GOLD SPENT",       1)
    bigStat("earned", "GOLD RECEIVED",    2)
    bigStat("lost",   "DEPOSITS LOST",    3)
    bigStat("profit", "NET PROFIT",       4)
    bigStat("stock",  "CAPITAL IN STOCK", 5)

    local function layoutTotals()
        local w = (strip:GetWidth() - 20) / 5
        if w <= 0 then return end
        for _, t in pairs(ui.totals) do
            t.box:ClearAllPoints()
            t.box:SetPoint("TOPLEFT", 10 + (t.index - 1) * w, 0)
            t.box:SetPoint("BOTTOM", strip, "BOTTOM", 0, 0)
            t.box:SetWidth(w - 6)
        end
    end
    strip:SetScript("OnSizeChanged", layoutTotals)
    ui.layoutTotals = layoutTotals

    -- ---------- bottom bar ----------
    local bar = CreateFrame("Frame", nil, panel)
    bar:SetPoint("BOTTOMLEFT", 8, 8); bar:SetPoint("BOTTOMRIGHT", -8, 8)
    bar:SetHeight(24)

    local mailBtn = Skin:Button(bar, "Read mailbox", 120, 22)
    mailBtn:SetPoint("LEFT", 0, 0)
    mailBtn:SetScript("OnClick", function()
        AMS.Ledger:ScanInbox()
        AMS:Print("mailbox read.")
        M:Refresh()
    end)
    Skin:AddTooltip(mailBtn, "Read mailbox",
        {"Sales and expiries are recorded from auction house mail. This happens automatically",
         "whenever the mailbox is open; the button is here for when you want to force it."})

    local wipeBtn = Skin:Button(bar, "Clear ledger", 110, 22)
    wipeBtn:SetPoint("LEFT", mailBtn, "RIGHT", 6, 0)
    wipeBtn:SetScript("OnClick", function()
        StaticPopupDialogs["AMS_WIPE_LEDGER"] = {
            text = "Delete every recorded buy, sale, post and expiry?\nThis cannot be undone.",
            button1 = "Delete", button2 = "Cancel",
            OnAccept = function() AMS.DB:WipeLedger(); M:Refresh() end,
            timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
        }
        StaticPopup_Show("AMS_WIPE_LEDGER")
    end)

    local footnote = Skin:Label(bar,
        "Sales and expiries come from auction house mail. Purchases are recorded when this addon buys them - "..
        "buyouts through the default auction house UI are not counted. Click any row to open or start tracking it.",
        10, false, C.textDim)
    footnote:SetPoint("LEFT", wipeBtn, "RIGHT", 12, 0)
    footnote:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
    footnote:SetHeight(24)
    footnote:SetWordWrap(true)

    -- ---------- per-item table (full width, top half) ----------
    local ITEM_COLS = {
        { text = "ITEM",     width = 150, justify = "LEFT"  },
        { text = "STOCK",    width = 50,  justify = "RIGHT" },
        { text = "AVG BUY",  width = 70,  justify = "RIGHT" },
        { text = "AVG SALE", width = 70,  justify = "RIGHT" },
        { text = "MARGIN",   width = 58,  justify = "RIGHT" },
        { text = "BOUGHT",   width = 56,  justify = "RIGHT" },
        { text = "SOLD",     width = 50,  justify = "RIGHT" },
        { text = "/DAY",     width = 48,  justify = "RIGHT" },
        { text = "PROFIT",   width = 82,  justify = "RIGHT" },
        { text = "TRACKED",  width = 60,  min = 54, justify = "RIGHT" },
    }

    local itemHdr = Skin:ListHeader(panel, ITEM_COLS)
    itemHdr:SetPoint("TOPLEFT", strip, "BOTTOMLEFT", 0, -8)
    itemHdr:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    ui.itemHdr = itemHdr

    local itemCols
    local itemList = Skin:ScrollList(panel, 19,
        function(p)
            local r = Skin:Row(p, itemCols and itemCols() or ITEM_COLS)
            r:EnableIcon(1, 14)
            return r
        end,
        function(row, d, idx, alt)
            if not d then
                for i = 1, #ITEM_COLS do row:Set(i, "") end
                row:SetIcon(nil)
                row:SetScript("OnClick", nil)
                return
            end
            row:Set(1, U:ItemCell(row, d.id, d.name, d.quality))
            row:Set(2, tostring(d.stock))
            row:Set(3, d.avgBuy  > 0 and U:MoneyShort(d.avgBuy)  or "-")
            row:Set(4, d.avgSale > 0 and U:MoneyShort(d.avgSale) or "-")
            row:Set(5, d.margin and U:Percent(d.margin, 0) or "-",
                       d.margin and (d.margin > 0 and C.good or C.bad) or C.textDim)
            row:Set(6, tostring(d.bought))
            row:Set(7, tostring(d.sold))
            row:Set(8, d.velocity > 0 and ("%.1f"):format(d.velocity) or "-")
            row:Set(9, U:MoneyShort(d.profit), d.profit >= 0 and C.good or C.bad)
            row:Set(10, d.watched and "yes" or "+ track",
                        d.watched and C.textDim or C.accent)
            row:Tint(alt and C.bgRowAlt or C.bgRow)
            row:SetScript("OnClick", function()
                -- an untracked item becomes a market on the way through, which
                -- is the whole point of listing it here
                if not d.watched then
                    local info = U:ItemInfo(d.id)
                    if not info then
                        AMS:Print("that item is not in your client cache - open the auction house and search for it.")
                        return
                    end
                    AMS.DB:EnsureMarket(info)
                    AMS:Print("watching |cffffd070%s|r.", info.name)
                end
                AMS:SetCurrentMarket(d.id)
                AMS.db.lastMarket = d.id
                AMS.UI:Show("market")
            end)
        end)
    itemList:SetPoint("TOPLEFT", itemHdr, "BOTTOMLEFT", 0, -2)
    itemList:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    itemList:SetHeight(200)
    itemCols = Skin:AutoCols(itemHdr, itemList, ITEM_COLS)
    ui.itemList = itemList

    -- ---------- activity feed (full width, bottom half) ----------
    local FEED_COLS = {
        { text = "WHEN",      width = 92,  min = 76, justify = "LEFT"  },
        { text = "",          width = 56,  min = 44, justify = "LEFT"  },
        { text = "ITEM",      width = 170, min = 90, justify = "LEFT"  },
        { text = "QTY",       width = 40,  min = 32, justify = "RIGHT" },
        { text = "CHARACTER", width = 96,  min = 64, justify = "LEFT"  },
        { text = "AMOUNT",    width = 84,  min = 62, justify = "RIGHT" },
    }

    local feedHdr = Skin:ListHeader(panel, FEED_COLS)
    feedHdr:SetPoint("TOPLEFT", itemList, "BOTTOMLEFT", 0, -10)
    feedHdr:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    ui.feedHdr = feedHdr

    local KIND = {
        buy    = { text = "bought",  color = C.bad },
        sale   = { text = "sold",    color = C.good },
        post   = { text = "posted",  color = C.textDim },
        expire = { text = "expired", color = C.warn },
    }

    local feedCols
    local feedList = Skin:ScrollList(panel, 18,
        function(p)
            local r = Skin:Row(p, feedCols and feedCols() or FEED_COLS)
            r:EnableIcon(3, 12)
            return r
        end,
        function(row, d, idx, alt)
            if not d then
                for i = 1, #FEED_COLS do row:Set(i, "") end
                row:SetIcon(nil)
                return
            end
            local k = KIND[d.kind] or { text = d.kind, color = C.text }
            row:Set(1, U:DateShort(d.t), C.textDim)
            row:Set(2, k.text, k.color)
            row:Set(3, U:ItemCell(row, d.id, d.name), C.text)
            row:Set(4, tostring(d.count or d.stack or 0), C.text)
            row:Set(5, d.who or "-", d.who and C.accent or C.textDim)
            row:Set(6, d.amount > 0 and U:MoneyShort(d.amount) or "-", k.color)
            row:Tint(alt and C.bgRowAlt or C.bgRow)
        end)
    feedList:SetPoint("TOPLEFT", feedHdr, "BOTTOMLEFT", 0, -2)
    feedList:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    feedList:SetPoint("BOTTOM", bar, "TOP", 0, 6)
    feedCols = Skin:AutoCols(feedHdr, feedList, FEED_COLS)
    ui.feedList = feedList

    -- Full width each, stacked, so neither has to fight the other for columns.
    -- The split is by height, computed from where the frames actually are.
    local function layoutTables()
        local top, barTop = itemList:GetTop(), bar:GetTop()
        if not top or not barTop then return end
        local avail = top - barTop - 42          -- feed header plus the gaps
        if avail < 120 then avail = 120 end
        itemList:SetHeight(math.floor(avail * 0.45))
    end
    panel:SetScript("OnSizeChanged", layoutTables)
    ui.layoutTables = layoutTables

    panel:SetScript("OnShow", function() M:Refresh() end)
    self:Refresh()
    return panel
end

function M:Refresh()
    local ui = self._ui
    if not ui or not ui.header then return end

    if ui.layoutTotals then ui.layoutTotals() end
    if ui.layoutTables then ui.layoutTables() end

    -- ---------- who to show ----------
    -- Each character's own net profit goes in the label, so the dropdown is a
    -- per-character breakdown in its own right.
    local scope = AMS.DB:Scope()
    local items = { { text = "All characters", value = "*" } }
    for _, name in ipairs(AMS.DB:Characters()) do
        AMS.DB:SetScope(name)
        local ct = AMS.DB:Totals()
        items[#items+1] = { text = ("%s   %s"):format(name, U:MoneyShort(ct.profit)), value = name }
    end
    AMS.DB:SetScope(scope)
    ui.scopeDrop:SetItems(items)
    ui.scopeDrop:SetValue(scope or "*", nil, true)

    local t = AMS.DB:Totals()

    -- ---------- every item the books know about ----------
    local capital, rows, untracked = 0, {}, 0
    for _, entry in ipairs(AMS.DB:LedgerItems()) do
        local m   = AMS.DB:GetMarket(entry.id)
        local s   = AMS.DB:Stats(entry.id)
        local h   = AMS.Inventory:Holdings(entry.id)
        local vel = AMS.DB:Velocity(entry.id)

        -- With a character filter on, drop untracked items that character never
        -- touched; a table of empty rows is not information.
        local active = s.sold > 0 or s.bought > 0 or s.posted > 0 or h.total > 0
        if m or active then
            local basis = s.avgBuy > 0 and s.avgBuy or 0
            capital = capital + h.total * basis
            if not m then untracked = untracked + 1 end

            local quality = m and m.quality
            if not quality then
                local info = U:ItemInfo(entry.id)
                quality = info and info.quality
            end

            rows[#rows+1] = {
                id      = entry.id,
                name    = (m and m.name) or entry.name or "?",
                quality = quality,
                watched = m ~= nil,
                stock   = h.total,
                bought  = s.bought,
                avgBuy  = s.avgBuy,
                avgSale = s.avgSale,
                margin  = (s.avgBuy > 0 and s.avgSale > 0) and ((s.avgSale - s.avgBuy) / s.avgBuy) or nil,
                sold    = s.sold,
                velocity= vel,
                profit  = s.profit,
            }
        end
    end
    table.sort(rows, function(a, b) return a.profit > b.profit end)

    local function setTotal(key, text, color)
        local tt = ui.totals[key]
        if tt then tt.value:SetText(text); tt.value:SetTextColor(unpack(color or C.text)) end
    end
    setTotal("spent",  U:MoneyShort(t.spent))
    setTotal("earned", U:MoneyShort(t.earned), C.good)
    setTotal("lost",   U:MoneyShort(t.depositLost), t.depositLost > 0 and C.warn or C.textDim)
    setTotal("profit", U:MoneyShort(t.profit), t.profit >= 0 and C.good or C.bad)
    setTotal("stock",  U:MoneyShort(capital), C.accent)

    ui.header:SetText(("Books - %s"):format(AMS.DB.realmName or "this realm"))
    ui.header:SetSub(("%d items%s  |  %d buys, %d sales%s"):format(
        #rows,
        untracked > 0 and (" (%d untracked)"):format(untracked) or "",
        t.buys, t.sales,
        scope and (" by "..scope) or ""))

    ui.itemList:SetData(rows)
    ui.feedList:SetData(AMS.Ledger:Feed(nil, 400))
end

function M:OnSlash() AMS.UI:Show("books") end
