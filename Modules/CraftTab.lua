-- Auction Master Suite -- Craft tab
--
-- Is it worth buying this, converting it, and selling what comes out?
--
-- Yields are learned by watching you prospect, mill or disenchant - see
-- Core/Craft.lua. Nothing is hardcoded, so the numbers are yours rather than
-- someone else's averages off a different server.

local AMS = AuctionMasterSuite
local M = AMS:RegisterModule("craft", { title = "Craft", order = 45 })

local U, Skin, C

function M:OnInit()
    U, Skin = AMS.Util, AMS.Skin
    C = Skin.COLOR
    AMS:Subscribe("CRAFT_CHANGED",   function() M:Refresh() end)
    -- changing the market elsewhere drops the local pick, so the tab follows
    AMS:Subscribe("CURRENT_CHANGED", function() M.selected = nil; M:Refresh() end)
    AMS:Subscribe("HISTORY_CHANGED", function() M:Refresh() end)
    AMS:Subscribe("AH_STATE",        function() M:Refresh() end)
end

-- The deliberate way out of the tab: take this item to the Market.
function M:OpenInMarket(id)
    if not id then return end
    local info = U:ItemInfo(id)
    if not info then
        AMS:Print("that item is not in your client cache yet - try again in a moment.")
        return
    end
    AMS.DB:EnsureMarket(info)
    AMS:SetCurrentMarket(info.id)
    AMS.db.lastMarket = info.id
    AMS.UI:Show("market")
end

-- Put every item in the conversion on the watchlist. No auction house needed:
-- this is the "set it up now, price it next time I am there" path.
function M:WatchAll(id)
    local todo = AMS.Craft:ItemsFor(id)
    local added, already, uncached = 0, 0, 0
    for _, it in ipairs(todo) do
        if AMS.DB:GetMarket(it.id) then
            already = already + 1
        else
            local info = U:ItemInfo(it.id)
            if info then
                AMS.DB:EnsureMarket(info)
                added = added + 1
            else
                -- asking for the info is what makes the client fetch it
                uncached = uncached + 1
            end
        end
    end

    AMS:Print("watchlist: |cffffd070%d added|r, %d already there%s.",
        added, already,
        uncached > 0 and (", %d not in your item cache yet - reopen this tab in a moment"):format(uncached) or "")
    self:Refresh()
end

-- Prices for every item in the conversion, scanned one after another.
function M:ScanAll(inputID)
    if not AMS:AtAuctionHouse() then
        AMS:Print("open the auction house to price these.")
        return
    end
    if self.scanning then return end

    local todo = AMS.Craft:ItemsFor(inputID)
    if #todo == 0 then return end

    self.scanning = true
    local i = 0
    local function next_()
        i = i + 1
        if i > #todo then
            M.scanning = false
            AMS:Print("priced %d item%s in the conversion.", #todo, #todo == 1 and "" or "s")
            M:Refresh()
            return
        end
        local it = todo[i]
        local info = U:ItemInfo(it.id)
        if not info then
            AMS:Debug("craft: %s is not in the item cache, skipping", tostring(it.name))
            U:After(0.2, next_)
            return
        end
        local market = AMS.DB:EnsureMarket(info)
        if M._ui then M._ui.header:SetSub(("pricing %d/%d: %s"):format(i, #todo, info.name)) end

        AMS.Analysis:ScanAndEvaluate(market, function(_, _, err)
            if err then AMS:Print("%s: %s", info.name, err) end
            M:Refresh()
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
    local ui = {}
    self._ui = ui

    local header = Skin:Header(panel, "Craft")
    header:SetPoint("TOPLEFT", 8, -8); header:SetPoint("TOPRIGHT", -8, -8)
    ui.header = header

    -- Drag any item here to inspect it, without having to find it on the
    -- Market tab first.
    local slot = Skin:ItemSlot(header, 24)
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
        M.selected = info.id
        M:Refresh()
        return true
    end
    slot:SetScript("OnReceiveDrag", takeCursorItem)
    slot:SetScript("OnClick", function(_, button)
        if takeCursorItem() then return end
        if button == "RightButton" then M.selected = nil; M:Refresh() end
    end)

    header.text:ClearAllPoints()
    header.text:SetPoint("LEFT", slot, "RIGHT", 8, 0)

    local scanBtn = Skin:Button(header, "Price it all", 100, 22)
    scanBtn:SetPoint("RIGHT", -8, 0)
    scanBtn:SetScript("OnClick", function()
        local id = M:CurrentInput()
        if id then M:ScanAll(id) end
    end)
    Skin:AddTooltip(scanBtn, "Price every item in this conversion",
        {"Scans the input and each output in turn so the maths has real prices to work from.",
         "Anything not already watched gets added to your watchlist on the way through."})
    ui.scanBtn = scanBtn

    -- Works with the auction house closed: it only adds the items to the
    -- watchlist so a later "Scan all" picks them up.
    local watchBtn = Skin:Button(header, "Watch all", 92, 22)
    watchBtn:SetPoint("RIGHT", scanBtn, "LEFT", -4, 0)
    watchBtn:SetScript("OnClick", function()
        local id = M:CurrentInput()
        if id then M:WatchAll(id) end
    end)
    Skin:AddTooltip(watchBtn, "Watch every item in this conversion",
        {"Adds the crafted item and all of its reagents to your watchlist, so the next",
         "'Scan all' on the Watchlist tab prices the whole conversion for you.",
         " ",
         "Works away from the auction house - it only adds them, it does not scan."})
    ui.watchBtn = watchBtn

    local forgetBtn = Skin:Button(header, "Forget", 70, 22)
    forgetBtn:SetPoint("RIGHT", watchBtn, "LEFT", -4, 0)
    forgetBtn:SetScript("OnClick", function()
        local id = M:CurrentInput()
        if not id then return end
        StaticPopupDialogs["AMS_FORGET_CRAFT"] = {
            text = "Forget the learned yields for this conversion?\n\nIt starts relearning the next time you convert.",
            button1 = "Forget", button2 = "Keep",
            OnAccept = function() AMS.Craft:Forget(id); M:Refresh() end,
            timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
        }
        StaticPopup_Show("AMS_FORGET_CRAFT")
    end)
    ui.forgetBtn = forgetBtn

    header.sub:ClearAllPoints()
    header.sub:SetPoint("RIGHT", forgetBtn, "LEFT", -10, 0)

    -- ---------- verdict ----------
    local verdict = Skin:Verdict(panel)
    verdict:SetPoint("TOPLEFT",  header, "BOTTOMLEFT",  0, -6)
    verdict:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -6)
    verdict:SetHeight(58)
    ui.verdict = verdict

    -- ---------- known conversions ----------
    local KNOWN_COLS = {
        { text = "CONVERSION  (click to inspect)", width = 180, min = 90, justify = "LEFT"  },
        { text = "METHOD",     width = 86,  min = 60, justify = "LEFT"  },
        { text = "SEEN",       width = 54,  min = 44, justify = "RIGHT" },
        { text = "COST/OP",    width = 76,  min = 56, justify = "RIGHT" },
        { text = "VALUE/OP",   width = 76,  min = 56, justify = "RIGHT" },
        { text = "PROFIT/OP",  width = 80,  min = 58, justify = "RIGHT" },
        { text = "ROI",        width = 56,  min = 44, justify = "RIGHT" },
    }

    local knownHdr = Skin:ListHeader(panel, KNOWN_COLS)
    knownHdr:SetPoint("TOPLEFT",  verdict, "BOTTOMLEFT",  0, -8)
    knownHdr:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    ui.knownHdr = knownHdr

    local knownCols
    -- shrunk to make room for the two views below it
    local knownList = Skin:ScrollList(panel, 19,
        function(p) return Skin:Row(p, knownCols and knownCols() or KNOWN_COLS) end,
        function(row, d, idx, alt)
            if not d then
                for i = 1, #KNOWN_COLS do row:Set(i, "") end
                row:SetScript("OnClick", nil)
                return
            end
            row:Set(1, U:ColorItemName(d.name, d.quality))
            row:Set(2, d.method or "?", C.textDim)
            -- a recipe is exact; a learned conversion is only as good as its sample
            row:Set(3, d.ops and tostring(d.ops) or "exact",
                       d.ops and (d.ops >= 10 and C.text or C.warn) or C.good)
            row:Set(4, d.cost   and U:MoneyShort(d.cost)   or "-", d.cost and C.text or C.textDim)
            row:Set(5, d.value  and d.value > 0 and U:MoneyShort(d.value) or "-",
                       (d.value or 0) > 0 and C.text or C.textDim)
            row:Set(6, d.profit and U:MoneyShort(d.profit) or "-",
                       d.profit and (d.profit > 0 and C.good or C.bad) or C.textDim)
            row:Set(7, d.roi    and U:Percent(d.roi, 0)    or "-",
                       d.roi and (d.roi > 0 and C.good or C.bad) or C.textDim)
            row:Tint(d.id == M:CurrentInput() and C.bgActive or (alt and C.bgRowAlt or C.bgRow))
            -- left inspects here, right leaves for the Market tab
            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            row:SetScript("OnClick", function(_, button)
                if button == "RightButton" then M:OpenInMarket(d.id) else
                    M.selected = d.id
                    M:Refresh()
                end
            end)
        end)
    knownList:SetPoint("TOPLEFT", knownHdr, "BOTTOMLEFT", 0, -2)
    knownList:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    knownList:SetHeight(120)
    knownCols = Skin:AutoCols(knownHdr, knownList, KNOWN_COLS)
    ui.knownList = knownList

    -- ---------- what comes out ----------
    local OUT_COLS = {
        { text = "OUTPUT",     width = 160, min = 90, justify = "LEFT"  },
        { text = "PER OP",     width = 70,  min = 52, justify = "RIGHT" },
        { text = "SEEN",       width = 60,  min = 44, justify = "RIGHT" },
        { text = "SELLS FOR",  width = 84,  min = 60, justify = "RIGHT" },
        { text = "NET/OP",     width = 84,  min = 60, justify = "RIGHT" },
        { text = "SHARE",      width = 60,  min = 46, justify = "RIGHT" },
    }

    -- Two ways to read any item: what it is made from, and what it goes into.
    -- The second is the one that finds you markets you were not looking for.
    local madeBtn = Skin:TabButton(panel, "Made from", 110, 20)
    madeBtn:SetPoint("TOPLEFT", knownList, "BOTTOMLEFT", 0, -6)
    madeBtn:SetScript("OnClick", function() M.view = "made"; M:Refresh() end)
    ui.madeBtn = madeBtn

    local usedBtn = Skin:TabButton(panel, "Used in", 130, 20)
    usedBtn:SetPoint("LEFT", madeBtn, "RIGHT", 4, 0)
    usedBtn:SetScript("OnClick", function() M.view = "used"; M:Refresh() end)
    Skin:AddTooltip(usedBtn, "What this item is used in",
        {"Every recipe in the game that consumes this item, best profit first.",
         "Read straight out of the client's own recipe data, so it covers professions",
         "nobody here has and items you have never touched.",
         " ",
         "This is how a reagent leads you to a market you were not looking at."})
    ui.usedBtn = usedBtn

    local outHdr = Skin:ListHeader(panel, OUT_COLS)
    outHdr:SetPoint("TOPLEFT", madeBtn, "BOTTOMLEFT", 0, -6)
    outHdr:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    ui.outHdr = outHdr

    local outCols
    local outList = Skin:ScrollList(panel, 19,
        function(p) return Skin:Row(p, outCols and outCols() or OUT_COLS) end,
        function(row, d, idx, alt)
            if not d then
                for i = 1, #OUT_COLS do row:Set(i, "") end
                row:SetScript("OnClick", nil)
                return
            end
            row:Set(1, U:ColorItemName(d.name, d.quality))
            row:Set(2, d.perOp == math.floor(d.perOp)
                        and tostring(math.floor(d.perOp))
                        or ("%.2f"):format(d.perOp))
            row:Set(3, d.total and tostring(d.total) or "-", C.textDim)
            row:Set(4, d.price and U:MoneyShort(d.price) or "not priced",
                       d.price and C.text or C.warn)
            row:Set(5, d.net and d.net > 0 and U:MoneyShort(d.net) or "-",
                       d.net and d.net > 0 and C.good or C.textDim)
            -- last column carries profit in the "used in" view and share of
            -- the total in the others
            if d.profitVal ~= nil then
                row:Set(6, U:MoneyShort(d.profitVal), d.profitVal > 0 and C.good or C.bad)
            else
                row:Set(6, d.share and U:Percent(d.share, 0) or "-", C.textDim)
            end
            row:Tint(alt and C.bgRowAlt or C.bgRow)

            -- Left-click follows the chain: clicking a reagent inspects THAT
            -- item here, so you can walk from a gem to its ore to whatever the
            -- ore goes into without ever leaving the tab. Right-click is the
            -- deliberate exit to the Market tab.
            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            row:SetScript("OnClick", function(_, button)
                if button == "RightButton" then M:OpenInMarket(d.id) else
                    M.selected = d.id
                    M:Refresh()
                end
            end)
        end)
    outList:SetPoint("TOPLEFT", outHdr, "BOTTOMLEFT", 0, -2)
    outList:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    outList:SetPoint("BOTTOM", panel, "BOTTOM", 0, 34)
    outCols = Skin:AutoCols(outHdr, outList, OUT_COLS)
    ui.outList = outList

    local foot = Skin:Label(panel,
        "Left-click any row to inspect that item here - follow a gem to its ore and on to whatever the ore makes. "..
        "Right-click to open it on the Market tab. Drag an item onto the slot up top to jump straight to it.  |  "..
        "Yields are learned by watching you prospect, mill or disenchant - nothing is hardcoded, so these are "..
        "your numbers on your server. Inputs are costed at what you would pay (the cheapest ask) and outputs at "..
        "what you would realistically get (the median), because pricing both the same way flatters every conversion.",
        10, false, C.textDim)
    foot:SetPoint("BOTTOMLEFT", 10, 8)
    foot:SetPoint("BOTTOMRIGHT", -10, 8)
    foot:SetHeight(26)
    foot:SetJustifyV("BOTTOM")
    foot:SetWordWrap(true)

    panel:SetScript("OnShow", function() M:Refresh() end)
    self:Refresh()
    return panel
end

-- The conversion being looked at.
--
-- An explicit click outranks everything: picking a row and having the panel
-- ignore you because the Market tab happens to be on something else is
-- maddening, and now that the recipe data covers the whole game almost any
-- market item qualifies, so the market would always have won.
local function interesting(id)
    if not id then return false end
    return (AMS.Craft:Get(id) or AMS.Craft:GetRecipe(id)
            or AMS.Craft:UsedInCount(id) > 0) and true or false
end

function M:CurrentInput()
    -- an item that is only ever a reagent still belongs here: what it goes
    -- into is the whole point of the reverse lookup
    if self.selected and interesting(self.selected) then return self.selected end
    local cur = AMS.currentID
    if cur and interesting(cur) then return cur end
    local best
    for _, c in ipairs(AMS.Craft:AllConversions()) do
        if c.profit and (not best or c.profit > best.profit) then best = c end
    end
    if best then return best.id end
    local any = AMS.Craft:AllConversions()[1]
    return any and any.id or nil
end

-- =============================================================================
-- Refresh
-- =============================================================================

function M:Refresh()
    local ui = self._ui
    if not ui or not ui.header then return end

    -- ---------- everything we know how to convert ----------
    local known = AMS.Craft:AllConversions()
    table.sort(known, function(a, b)
        local pa, pb = a.profit or -math.huge, b.profit or -math.huge
        if pa ~= pb then return pa > pb end
        return (a.name or "") < (b.name or "")
    end)
    ui.knownList:SetData(known)

    local id = self:CurrentInput()
    local slotInfo = id and U:ItemInfo(id)
    ui.slot:SetItem(slotInfo and slotInfo.link, slotInfo and slotInfo.texture)
    ui.scanBtn:SetEnabled(id ~= nil and AMS:AtAuctionHouse() and not self.scanning)
    ui.watchBtn:SetEnabled(id ~= nil)
    ui.forgetBtn:SetEnabled(id ~= nil)

    if not id then
        ui.header:SetText("Craft")
        if not self.scanning then ui.header:SetSub("nothing learned yet") end
        ui.verdict:Set("NOTHING LEARNED YET",
            "Prospect, mill or disenchant something while the addon is loaded and it records what went in and what came out. A few operations is enough to start; the more you do, the closer the yields get.",
            C.textDim)
        ui.outList:SetData({})
        return
    end

    local e = AMS.Craft:EvaluateAny(id)
    local usedCount = AMS.Craft:UsedInCount(id)

    -- which views this item actually has, and which one to show
    local hasMade, hasUsed = e ~= nil, usedCount > 0
    local view = self.view
    if view == "made" and not hasMade then view = nil end
    if view == "used" and not hasUsed then view = nil end
    view = view or (hasMade and "made") or (hasUsed and "used") or nil

    ui.madeBtn:SetSelected(view == "made")
    ui.usedBtn:SetSelected(view == "used")
    ui.madeBtn:SetEnabled(hasMade)
    ui.usedBtn:SetEnabled(hasUsed)
    ui.usedBtn.text:SetText(hasUsed and ("Used in (%d)"):format(usedCount) or "Used in")

    -- ---------- what it goes into ----------
    if view == "used" then
        local uinfo = U:ItemInfo(id)
        ui.header:SetText("Craft - "..U:ColorItemName(
            (uinfo and uinfo.name) or ("item #"..id), uinfo and uinfo.quality))
        if not self.scanning then
            ui.header:SetSub(("used in %d recipe%s"):format(usedCount, usedCount == 1 and "" or "s"))
        end

        for i, text in ipairs({ "MAKES", "NEEDS", "", "COSTS", "SELLS FOR", "PROFIT" }) do
            if ui.outHdr.cells[i] then ui.outHdr.cells[i]:SetText(text) end
        end

        local rows = {}
        for _, r in ipairs(AMS.Craft:UsedIn(id)) do
            local ri = U:ItemInfo(r.id)
            rows[#rows+1] = {
                id = r.id, name = r.name, quality = ri and ri.quality,
                perOp = r.need, total = nil,
                price = r.cost, net = r.value, profitVal = r.profit,
                known = r.known, profession = r.profession,
            }
        end
        ui.outList:SetData(rows)

        local best, priced = nil, 0
        for _, r in ipairs(rows) do
            if r.profitVal then
                priced = priced + 1
                if not best or r.profitVal > best.profitVal then best = r end
            end
        end
        if best then
            ui.verdict:Set(("BEST USE: %s"):format(best.name),
                ("%d of the %d recipes using this can be priced. The best is %s (%s) at %s profit a craft, needing %d of these.%s"):format(
                    priced, usedCount, best.name, best.profession or "?",
                    U:Money(best.profitVal, true), best.perOp,
                    best.known and " You know that recipe." or " Nobody here knows that recipe yet."),
                best.profitVal > 0 and C.good or C.warn)
        else
            ui.verdict:Set(("USED IN %d RECIPE%s"):format(usedCount, usedCount == 1 and "" or "S"),
                "None of them can be priced yet. Press 'Watch all' to start tracking the ones you care about, or click a row to open it.",
                C.textDim)
        end
        return
    end

    if not e then
        ui.verdict:Set("NOTHING TO SHOW", "That conversion is no longer recorded.", C.textDim)
        ui.outList:SetData({})
        return
    end

    local info  = U:ItemInfo(id)
    local rec   = e.rec or e.recipe
    ui.header:SetText("Craft - "..U:ColorItemName(rec.name or (info and info.name), info and info.quality))
    if not self.scanning then
        if e.isRecipe then
            ui.header:SetSub(("%s%s, makes %s%s"):format(
                rec.profession or "?",
                rec.isScroll and " scroll" or " recipe",
                e.made == 1 and "1" or ("%.1f"):format(e.made),
                (e.routes or 1) > 1 and ("  |  %d ways to make it"):format(e.routes) or ""))
        else
            ui.header:SetSub(("%s, %d operation%s learned"):format(
                rec.method or "?", e.ops, e.ops == 1 and "" or "s"))
        end
    end

    -- The detail table means different things for the two kinds: what comes
    -- out of a prospect, versus what goes into a recipe.
    local labels = e.isRecipe
        and { "REAGENT", "NEEDED", "", "COSTS EACH", "TOTAL", "SHARE" }
        or  { "OUTPUT",  "PER OP", "SEEN", "SELLS FOR", "NET/OP", "SHARE" }
    for i, text in ipairs(labels) do
        if ui.outHdr.cells[i] then ui.outHdr.cells[i]:SetText(text) end
    end

    local basis = e.isRecipe and (e.cost or 0) or (e.value or 0)
    local rows = {}
    for _, r in ipairs(e.rows) do
        local oi = U:ItemInfo(r.id)
        rows[#rows+1] = {
            id = r.id, name = r.name, quality = oi and oi.quality,
            perOp = r.perOp, total = e.isRecipe and nil or r.total,
            price = r.price, net = r.net,
            share = (basis > 0 and (r.net or 0) > 0) and (r.net / basis) or nil,
        }
    end
    ui.outList:SetData(rows)

    -- ---------- the verdict ----------
    local missing = AMS.Craft:MissingPrices(id)
    if #missing > 0 then
        local names = {}
        for i = 1, math.min(3, #missing) do
            names[#names+1] = missing[i].name or (U:ItemInfo(missing[i].id) or {}).name or ("item #"..missing[i].id)
        end
        local howTo = AMS:AtAuctionHouse()
            and "Press 'Price it all' to scan them now"
            or  "Press 'Watch all' to add them to your watchlist, then 'Scan all' there next time you are at an auctioneer"
        ui.verdict:Set(("NEEDS %d MORE PRICE%s"):format(#missing, #missing == 1 and "" or "S"),
            ("Never scanned: %s%s. %s. You can also click any row below to open that item on its own."):format(
                table.concat(names, ", "), #missing > 3 and (" and %d more"):format(#missing - 3) or "",
                howTo),
            C.warn)
        return
    end

    local what = e.isRecipe
        and ("Making one %s"):format(rec.name or "of these")
        or  ("%.1f %s per operation"):format(e.inputPer or 0, rec.name or "input")

    -- a scroll needs a vellum the spell data does not list as a reagent
    local extra = ""
    if rec.isScroll then
        extra = rec.vellumMissing
            and " An Enchanting Vellum is also needed; it is not in your item cache yet so its cost is not counted."
            or  " The Enchanting Vellum is included in the materials."
    end
    if (e.routes or 1) > 1 then
        extra = extra .. (" Costed by the cheapest of %d ways to make it."):format(e.routes)
    end

    if not e.profit then
        ui.verdict:Set("NOT ENOUGH PRICES",
            e.isRecipe
                and "Scan the crafted item and its reagents so both sides of this can be worked out."
                or  "Scan the input item so the cost side of this can be worked out.",
            C.warn)
    elseif (not e.isRecipe) and e.ops < 5 then
        ui.verdict:Set(("EARLY - %s PER OPERATION"):format(U:Money(e.profit, true)),
            ("Only %d operation%s learned, so the yields are still noisy. %s costs %s and returns %s at market. Do a few more before trusting it."):format(
                e.ops, e.ops == 1 and "" or "s", what,
                U:Money(e.cost, true), U:Money(e.value, true)),
            C.warn)
    elseif e.profit > 0 then
        ui.verdict:Set(("WORTH IT - %s EACH TIME"):format(U:Money(e.profit, true)),
            ("%s costs %s in materials and sells for %s after the auction house cut. That is %s ROI%s."):format(
                what, U:Money(e.cost, true), U:Money(e.value, true), U:Percent(e.roi, 0),
                e.isRecipe and " - exact, straight from the recipe"
                            or (", learned over %d operations"):format(e.ops))
                .. extra,
            C.good)
    else
        ui.verdict:Set("NOT WORTH IT",
            ("%s costs %s but only returns %s after the cut - a loss of %s each time. %s"):format(
                what, U:Money(e.cost, true), U:Money(e.value, true), U:Money(-e.profit, true),
                e.isRecipe and "The reagents are worth more raw."
                            or "Sell the input raw instead.") .. extra,
            C.bad)
    end
end

function M:OnSlash() AMS.UI:Show("craft") end
