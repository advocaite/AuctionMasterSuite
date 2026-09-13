-- Auction Master Suite -- Auctions tab
--
-- Everything you currently have listed, across every character, plus the gold
-- already earned and waiting to arrive.
--
-- That last part is the useful bit: the auction house marks an auction sold the
-- moment it goes, but holds the mail for an hour. Until that mail lands the
-- gold exists nowhere in your books - not in your bags, not in the ledger. This
-- is the only place the client will tell you about it, and on a busy day it can
-- be a large fraction of your working capital.
--
-- Auctions are stored per character but realm-wide, so an alt's listings stay
-- visible after you log off it. Only the character logged in can refresh their
-- own, so each row carries the age of the scan it came from.

local AMS = AuctionMasterSuite
local M = AMS:RegisterModule("auctions", { title = "My Auctions", order = 25 })

local U, Skin, C

local TIMELEFT = { [1] = "30m", [2] = "2h", [3] = "12h", [4] = "48h" }

function M:OnInit()
    U, Skin = AMS.Util, AMS.Skin
    C = Skin.COLOR
    AMS:Subscribe("LISTED_CHANGED",   function() M:Refresh() end)
    AMS:Subscribe("AUCTIONS_CHANGED", function() M:Refresh() end)
    AMS:Subscribe("AH_STATE",         function() M:Refresh() end)
    AMS:Subscribe("LEDGER_CHANGED",   function() M:Refresh() end)
end

function M:Rescan()
    if not AMS:AtAuctionHouse() then
        AMS:Print("open the auction house to refresh your auctions.")
        return
    end
    if self.scanning then return end
    self.scanning = true
    if self._ui then self._ui.header:SetSub("reading your auctions...") end

    -- Drop this character's stored list first, so a refresh that comes back
    -- short reads as "you have fewer auctions" rather than leaving the old
    -- ones on screen next to the new ones.
    AMS.DB:ClearOwnedAuctions(AMS:PlayerName())

    AMS.Scanner:ScanOwned(function(entries, err)
        M.scanning = false
        if err then
            AMS:Print("could not read your auctions: %s", err)
        end
        -- an empty result is still the answer: it means nothing is listed
        AMS.Inventory:SetListed(entries or {})
        M:Refresh()
    end)
end

-- =============================================================================
-- Cancelling
-- =============================================================================
--
-- Wired straight to OnClick: the client only honours CancelAuction from inside
-- a real mouse click.

local function afterCancel(n, units, name)
    if n == 0 then AMS:Print("nothing cancelled.") return end
    AMS:Print("cancelled |cffffd070%d auction%s|r of %s (%d units). Deposits on them are forfeited.",
        n, n == 1 and "" or "s", name or "that item", units)
    AMS.Util:After(1.0, function() M:Rescan() end)
end

function M:CancelOne(d)
    if not d or d.sold then return end
    if d.who ~= AMS:PlayerName() then
        AMS:Print("that auction belongs to %s - log in as them to cancel it.", d.who or "another character")
        return
    end
    local n, units = AMS.Canceller:CancelEntry(d)
    afterCancel(n, units, d.name)
end

function M:CancelGroup(d)
    if not d or d.cancellable == 0 then return end
    if not AMS:AtAuctionHouse() then AMS:Print("open the auction house first.") return end

    local function go()
        local n, units = AMS.Canceller:CancelAtPrice(d.name, d.unit)
        afterCancel(n, units, d.name)
    end

    if d.cancellable > 3 then
        StaticPopupDialogs["AMS_CANCEL_GROUP"] = {
            text = "%s",
            button1 = "Cancel them", button2 = "Keep them",
            OnAccept = go,
            timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
        }
        StaticPopup_Show("AMS_CANCEL_GROUP",
            ("Cancel %d %s auctions at %s?\n\nThe deposits on them are forfeited."):format(
                d.cancellable, d.name or "?", U:Money(d.unit, true)))
        return
    end
    go()
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

    local header = Skin:Header(panel, "My Auctions")
    header:SetPoint("TOPLEFT", 8, -8); header:SetPoint("TOPRIGHT", -8, -8)
    ui.header = header

    local refreshBtn = Skin:Button(header, "Refresh", 80, 22)
    refreshBtn:SetPoint("RIGHT", -8, 0)
    refreshBtn:SetScript("OnClick", function() M:Rescan() end)
    Skin:AddTooltip(refreshBtn, "Read your auctions",
        {"Re-reads the auction house's own list of what you have posted.",
         "Only this character's auctions can be refreshed - other characters show",
         "whatever they last saw, with the age on each row."})
    ui.refreshBtn = refreshBtn

    local forgetBtn = Skin:Button(header, "Forget all", 84, 22)
    forgetBtn:SetPoint("RIGHT", refreshBtn, "LEFT", -4, 0)
    forgetBtn:SetScript("OnClick", function()
        StaticPopupDialogs["AMS_FORGET_AUCTIONS"] = {
            text = "Forget the stored auction lists for every character?\n\n"..
                   "Nothing is cancelled - this only clears what the addon remembers. "..
                   "Each character repopulates the next time it refreshes at an auctioneer.",
            button1 = "Forget", button2 = "Cancel",
            OnAccept = function() AMS.DB:ClearOwnedAuctions(nil); M:Refresh() end,
            timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
        }
        StaticPopup_Show("AMS_FORGET_AUCTIONS")
    end)
    Skin:AddTooltip(forgetBtn, "Forget stored auctions",
        {"Clears the remembered auction lists for all characters.",
         "Useful when an alt's data is stale and you cannot log in to refresh it.",
         "This cancels nothing - it only forgets."})

    header.sub:ClearAllPoints()
    header.sub:SetPoint("RIGHT", forgetBtn, "LEFT", -10, 0)

    -- ---------- summary strip ----------
    local strip = Skin:Panel(panel)
    strip:SetPoint("TOPLEFT",  header, "BOTTOMLEFT",  0, -6)
    strip:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -6)
    strip:SetHeight(56)

    ui.totals = {}
    local function bigStat(key, label, index, tip)
        local box = CreateFrame("Frame", nil, strip)
        box:SetWidth(10)
        box:EnableMouse(true)
        local l = Skin:Label(box, label, 10, false, C.textDim)
        l:SetPoint("TOPLEFT", 0, -10)
        local v = Skin:Label(box, "-", 17, true, C.text)
        v:SetPoint("TOPLEFT", 0, -26)
        if tip then Skin:AddTooltip(box, label, tip) end
        ui.totals[key] = { box = box, label = l, value = v, index = index }
    end

    bigStat("incoming", "INCOMING GOLD", 1,
        {"Auctions that have already sold but whose mail has not arrived yet.",
         "The auction house holds sale mail for an hour, so this gold is real but",
         "invisible everywhere else - it is not in your bags and not yet in the books.",
         "Shown net of the auction house cut; your deposits come back on top."})
    bigStat("listed",   "LISTED VALUE",  2,
        {"What every active auction would bring in if it all sold at buyout, before the cut.",
         "This is stock, not money - treat it as inventory at your asking price."})
    bigStat("auctions", "ACTIVE",        3,
        {"Auctions currently up, and the number of units in them."})
    bigStat("bids",     "UNDER BID",     4,
        {"Active auctions somebody has bid on. These usually sell, but at the bid price",
         "rather than your buyout unless someone buys them out first."})
    bigStat("expiring", "EXPIRING SOON", 5,
        {"Auctions with under two hours left. Relist them before they lapse and forfeit",
         "the deposit."})

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

    -- ---------- footer ----------
    local foot = Skin:Label(panel, "", 10, false, C.textDim)
    foot:SetPoint("BOTTOMLEFT", 10, 10)
    foot:SetPoint("BOTTOMRIGHT", -10, 10)
    foot:SetHeight(24)
    foot:SetJustifyV("BOTTOM")
    foot:SetWordWrap(true)
    ui.foot = foot

    -- ---------- price ladder (your listings, grouped) ----------
    -- Grouped by item AND price, because prices are not comparable across
    -- items. Only this character's rows: you cannot cancel an alt's auctions
    -- without logging into them.
    local LADDER_COLS = {
        { text = "ITEM",      width = 170, min = 90, justify = "LEFT"  },
        { text = "PRICE",     width = 86,  min = 62, justify = "RIGHT" },
        { text = "AUCTIONS",  width = 70,  min = 52, justify = "RIGHT" },
        { text = "UNITS",     width = 60,  min = 44, justify = "RIGHT" },
        { text = "SOLD",      width = 52,  min = 42, justify = "RIGHT" },
        { text = "VALUE",     width = 84,  min = 60, justify = "RIGHT" },
        { text = "",          width = 60,  min = 56, justify = "RIGHT" },
    }

    local ladderHdr = Skin:ListHeader(panel, LADDER_COLS)
    ladderHdr:SetPoint("TOPLEFT", strip, "BOTTOMLEFT", 0, -8)
    ladderHdr:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    ui.ladderHdr = ladderHdr

    local ladderCols
    local ladderList = Skin:ScrollList(panel, 19,
        function(p)
            local r = Skin:Row(p, ladderCols and ladderCols() or LADDER_COLS)
            local b = Skin:Button(r, "Cancel", 56, 15)
            Skin:Font(b.text, 10, true)
            b.textColor = C.bad
            b.text:SetTextColor(unpack(C.bad))
            b:ClearAllPoints()
            b:SetPoint("RIGHT", r.cells[#r.cells], "RIGHT", 0, 0)
            b:SetScript("OnClick", function()
                if r.rowData then M:CancelGroup(r.rowData) end
            end)
            Skin:AddTooltip(b, "Cancel this whole price",
                {"Pulls back every auction of yours for this item at this exact price.",
                 " ",
                 "Deposits on them are forfeited. Anything already sold stays, and anything",
                 "with a bid on it is skipped - cancelling those costs an extra fee."})
            r.cancelBtn = b
            return r
        end,
        function(row, d, idx, alt)
            row.rowData = d
            if not d then
                for i = 1, #LADDER_COLS do row:Set(i, "") end
                row.cancelBtn:Hide()
                return
            end
            row:Set(1, U:ColorItemName(d.name, d.quality))
            row:Set(2, U:MoneyShort(d.unit))
            row:Set(3, tostring(d.auctions))
            row:Set(4, tostring(d.units))
            row:Set(5, d.sold > 0 and tostring(d.sold) or "-", d.sold > 0 and C.good or C.textDim)
            row:Set(6, U:MoneyShort(d.value), C.accent)
            row:Set(7, "")
            row:Tint(alt and C.bgRowAlt or C.bgRow)
            -- nothing to cancel if every auction in the group has already sold
            if d.cancellable > 0 then row.cancelBtn:Show() else row.cancelBtn:Hide() end
        end)
    ladderList:SetPoint("TOPLEFT", ladderHdr, "BOTTOMLEFT", 0, -2)
    ladderList:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    ladderList:SetHeight(150)
    ladderCols = Skin:AutoCols(ladderHdr, ladderList, LADDER_COLS)
    ui.ladderList = ladderList

    -- ---------- table ----------
    local COLS = {
        { text = "ITEM",      width = 160, min = 90, justify = "LEFT"  },
        { text = "QTY",       width = 44,  min = 34, justify = "RIGHT" },
        { text = "EACH",      width = 76,  min = 56, justify = "RIGHT" },
        { text = "TOTAL",     width = 86,  min = 62, justify = "RIGHT" },
        { text = "STATUS",    width = 78,  min = 60, justify = "LEFT"  },
        { text = "LEFT",      width = 48,  min = 38, justify = "LEFT"  },
        { text = "CHARACTER", width = 92,  min = 62, justify = "LEFT"  },
        { text = "SEEN",      width = 62,  min = 50, justify = "RIGHT" },
        { text = "",          width = 60,  min = 56, justify = "RIGHT" },
    }

    local hdr = Skin:ListHeader(panel, COLS)
    hdr:SetPoint("TOPLEFT", ladderList, "BOTTOMLEFT", 0, -8)
    hdr:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    ui.hdr = hdr

    local cols
    local list = Skin:ScrollList(panel, 19,
        function(p)
            local r = Skin:Row(p, cols and cols() or COLS)
            local b = Skin:Button(r, "Cancel", 56, 15)
            Skin:Font(b.text, 10, true)
            b.textColor = C.bad
            b.text:SetTextColor(unpack(C.bad))
            b:ClearAllPoints()
            b:SetPoint("RIGHT", r.cells[#r.cells], "RIGHT", 0, 0)
            b:SetScript("OnClick", function()
                if r.rowData then M:CancelOne(r.rowData) end
            end)
            Skin:AddTooltip(b, "Cancel this auction",
                {"Pulls this one auction back off the board. Its deposit is forfeited.",
                 " ",
                 "Only auctions belonging to the character you are logged in as can be",
                 "cancelled - an alt's have to be cancelled from that alt."})
            r.cancelBtn = b
            return r
        end,
        function(row, d, idx, alt)
            row.rowData = d
            if not d then
                for i = 1, #COLS do row:Set(i, "") end
                row:SetScript("OnClick", nil)
                row.cancelBtn:Hide()
                return
            end
            local status, tone
            if d.sold then
                status, tone = "SOLD", C.good
            elseif d.hasBidder then
                status, tone = "bid", C.warn
            elseif (d.timeLeft or 4) <= 2 then
                status, tone = "expiring", C.bad
            else
                status, tone = "listed", C.textDim
            end

            row:Set(1, U:ColorItemName(d.name, d.quality))
            row:Set(2, tostring(d.count or 0))
            row:Set(3, d.unit and U:MoneyShort(d.unit) or "-")
            row:Set(4, U:MoneyShort(d.sold and math.max(d.bid or 0, d.buyout or 0) or (d.buyout or 0)), tone)
            row:Set(5, status, tone)
            row:Set(6, TIMELEFT[d.timeLeft or 0] or "-", (d.timeLeft or 4) <= 2 and C.bad or C.textDim)
            row:Set(7, d.who or "-", C.accent)
            row:Set(8, U:Ago(d.scannedAt), C.textDim)
            row:Set(9, "")
            row:Tint(alt and C.bgRowAlt or C.bgRow)

            -- sold auctions cannot be cancelled, and neither can another
            -- character's without logging into them
            if d.sold or d.who ~= AMS:PlayerName() then
                row.cancelBtn:Hide()
            else
                row.cancelBtn:Show()
            end

            row:SetScript("OnClick", function()
                if not d.id then return end
                if not AMS.DB:GetMarket(d.id) then
                    local info = U:ItemInfo(d.id)
                    if info then AMS.DB:EnsureMarket(info) end
                end
                AMS:SetCurrentMarket(d.id)
                AMS.db.lastMarket = d.id
                AMS.UI:Show("market")
            end)
        end)
    list:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, -2)
    list:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    list:SetPoint("BOTTOM", foot, "TOP", 0, 6)
    cols = Skin:AutoCols(hdr, list, COLS)
    ui.list = list

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
    if ui.layoutTotals then ui.layoutTotals() end

    ui.refreshBtn:SetEnabled(AMS:AtAuctionHouse() and not self.scanning)

    local rows, sum = AMS.DB:AllOwnedAuctions()

    -- sold first (that is money), then expiring, then the rest by value
    local function rank(r)
        if r.sold then return 0 end
        if (r.timeLeft or 4) <= 2 then return 1 end
        if r.hasBidder then return 2 end
        return 3
    end
    table.sort(rows, function(a, b)
        local ra, rb = rank(a), rank(b)
        if ra ~= rb then return ra < rb end
        return (a.buyout or 0) > (b.buyout or 0)
    end)

    local function setTotal(key, text, color)
        local t = ui.totals[key]
        if t then t.value:SetText(text); t.value:SetTextColor(unpack(color or C.text)) end
    end

    setTotal("incoming", sum.sold > 0 and U:MoneyShort(sum.soldNet) or "-",
             sum.sold > 0 and C.good or C.textDim)
    setTotal("listed",   U:MoneyShort(sum.askValue), C.accent)
    setTotal("auctions", ("%d / %d"):format(sum.active, sum.activeUnits))
    setTotal("bids",     sum.bidOn > 0 and ("%d  %s"):format(sum.bidOn, U:MoneyShort(sum.bidValue)) or "-",
             sum.bidOn > 0 and C.warn or C.textDim)
    setTotal("expiring", sum.expiringSoon > 0 and tostring(sum.expiringSoon) or "-",
             sum.expiringSoon > 0 and C.bad or C.textDim)

    ui.totals.auctions.label:SetText("ACTIVE / UNITS")

    -- ---------- ladder: your own listings, by item and price ----------
    local me = AMS:PlayerName()
    local groups, order = {}, {}
    for _, r in ipairs(rows) do
        if r.who == me and r.unit then
            local key = (r.name or "?") .. "|" .. r.unit
            local g = groups[key]
            if not g then
                g = { name = r.name, quality = r.quality, unit = r.unit,
                      auctions = 0, units = 0, sold = 0, cancellable = 0, value = 0 }
                groups[key] = g
                order[#order+1] = g
            end
            g.auctions = g.auctions + 1
            g.units    = g.units + (r.count or 0)
            g.value    = g.value + (r.buyout or 0)
            if r.sold then g.sold = g.sold + 1 else g.cancellable = g.cancellable + 1 end
        end
    end
    table.sort(order, function(a, b)
        if a.name ~= b.name then return (a.name or "") < (b.name or "") end
        return a.unit < b.unit
    end)
    ui.ladderList:SetData(order)
    ui.ladderHdr.cells[1]:SetText(#order > 0 and ("ITEM  (%s)"):format(me) or "ITEM")

    ui.list:SetData(rows)

    if sum.characters == 0 then
        ui.header:SetSub("never read")
        ui.foot:SetText("Open the auction house and press Refresh. Your auctions are then remembered per character, so you can see every alt's listings from anywhere.")
    else
        ui.header:SetSub(("%d auctions across %d character%s"):format(
            #rows, sum.characters, sum.characters == 1 and "" or "s"))
        local bits = {}
        if sum.sold > 0 then
            bits[#bits+1] = ("%d sold and waiting on mail - %s net after the cut, deposits back on top")
                :format(sum.sold, U:Money(sum.soldNet, true))
        end
        if sum.expiringSoon > 0 then
            bits[#bits+1] = ("%d expiring within two hours"):format(sum.expiringSoon)
        end
        bits[#bits+1] = "Click a row to open that market."
        ui.foot:SetText(table.concat(bits, "  |  "))
    end
end

function M:OnSlash() AMS.UI:Show("auctions") end
