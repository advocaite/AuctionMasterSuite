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
    AMS:Subscribe("CURRENT_CHANGED", function()
        M.selected, M.selectedEnchant = nil, nil
        M:Refresh()
    end)
    AMS:Subscribe("HISTORY_CHANGED", function() M:Refresh() end)
    AMS:Subscribe("AH_STATE",        function() M:Refresh() end)
    -- Names arriving from the server: redraw so "item #37663" becomes the item.
    -- Only while the tab is actually up - this fires every third of a second
    -- while a queue drains and there is no reason to rebuild a hidden panel.
    AMS:Subscribe("ITEM_CACHED", function()
        local p = M._ui and M._ui.panel
        if p and not p:IsVisible() then return end
        M:Refresh()
    end)
end

-- What you would have to ask to clear your required margin over materials.
--
--   you receive   price * (1 - cut)
--   you want      price * (1 - cut) - cost = margin * cost
--   so            price = cost * (1 + margin) / (1 - cut)
--
-- Useful wherever there is a cost but no market price to compare it against -
-- which is every enchant nobody has put a scroll up for.
function M:AskingPrice(cost, margin)
    if not cost or cost <= 0 then return nil end
    local cut = AMS.Config:Cut()
    if cut >= 1 then return nil end
    margin = margin or AMS.Config:MinMargin()
    return math.floor(cost * (1 + margin) / (1 - cut))
end

-- The deliberate way out of the tab: take this item to the Market.
function M:InspectEnchant(enchName)
    self.selectedEnchant = enchName
    self.selected = nil
    self.view = "made"
    self:Refresh()
end

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

-- Whatever is under inspection, as a list of items to watch or price. An
-- enchant is described by its reagents rather than by an item id, so it needs
-- asking separately - and it is the case that has no id at all when no scroll
-- has ever been seen.
function M:CurrentItems()
    if self.selectedEnchant then
        return AMS.Craft:ItemsForEnchant(self.selectedEnchant)
    end
    local id = self:CurrentInput()
    return id and AMS.Craft:ItemsFor(id) or {}
end

-- Put every item in the conversion on the watchlist. No auction house needed:
-- this is the "set it up now, price it next time I am there" path.
function M:WatchAll(todo)
    if not todo or #todo == 0 then return end
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
function M:ScanAll(todo)
    if not AMS:AtAuctionHouse() then
        AMS:Print("open the auction house to price these.")
        return
    end
    if self.scanning then return end
    if not todo or #todo == 0 then return end

    self.scanning = true
    local i = 0
    local function next_()
        if not M.scanning then return end        -- Stop was pressed
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

-- Prices a whole profession's materials.
--
-- The per-item "Price it all" only knows about one conversion, which is no use
-- on the Professions tab where there is no single item - and that is exactly
-- where the "not priced" column is longest. This walks the profession's
-- reagents instead, most-used first, so every recipe that shares one becomes
-- costable at once.
--
-- Anything priced in the last half hour is left alone: a scan that recent is a
-- price, and re-reading it is minutes spent to learn nothing.
local FRESH_ENOUGH = 1800

function M:ScanProfession(prof)
    if not prof then return end
    if not AMS:AtAuctionHouse() then
        AMS:Print("open the auction house to price these.")
        return
    end
    if self.scanning then return end


    local all  = AMS.Craft:ProfessionReagents(prof)
    local now  = U:Now()
    local todo, skipped = {}, 0
    for _, r in ipairs(all) do
        local snap = AMS.DB:LastSnapshot(r.id)
        if snap and (now - (snap.t or 0)) <= FRESH_ENOUGH then
            skipped = skipped + 1
        else
            todo[#todo+1] = r
            -- names are needed to search by, so ask for the uncached ones now
            U:RequestItem(r.id)
        end
    end

    if #todo == 0 then
        AMS:Print("%s: all %d materials already priced within the last %d minutes.",
            prof, skipped, math.floor(FRESH_ENOUGH / 60))
        return
    end

    AMS:Print("%s: pricing |cffffd070%d|r material%s%s. Press Stop to break off - "..
              "whatever has been read is kept.",
        prof, #todo, #todo == 1 and "" or "s",
        skipped > 0 and (", %d already fresh"):format(skipped) or "")

    self.scanning = true
    self.profScan = { prof = prof, list = todo, i = 0, done = 0, missed = 0, requeued = {} }

    local function step()
        local job = M.profScan
        if not job or not M.scanning then return end

        job.i = job.i + 1
        if job.i > #job.list then
            M.scanning = false
            M.profScan = nil
            AMS:Print("%s: priced |cffffd070%d|r material%s%s.",
                prof, job.done, job.done == 1 and "" or "s",
                job.missed > 0 and (", %d never turned up in the item cache"):format(job.missed) or "")
            M:Refresh()
            return
        end

        local entry = job.list[job.i]
        local info  = U:ItemInfo(entry.id)
        if not info then
            -- The name is what the auction house searches on, so an item the
            -- client has never heard of cannot be scanned. It was requested
            -- when the run started, so give it one more pass at the end before
            -- giving up on it.
            if not job.requeued[entry.id] then
                job.requeued[entry.id] = true
                job.list[#job.list+1] = entry
            else
                job.missed = job.missed + 1
            end
            U:After(0.05, step)
            return
        end

        if M._ui then
            M._ui.header:SetSub(("pricing %s: %d/%d - %s"):format(
                prof, job.i, #job.list, info.name))
        end

        -- Transient on purpose: this is a pricing sweep, not a decision to run
        -- two hundred markets. The snapshot is stored either way, which is the
        -- whole point - the watchlist just stays yours.
        local market = AMS.DB:TransientMarket(info)
        AMS.Analysis:ScanAndEvaluate(market, function(_, _, err)
            if err then AMS:Debug("%s: %s", info.name, err) else job.done = job.done + 1 end
            if not M.scanning then return end
            M:Refresh()
            U:After((AMS.db.scan and AMS.db.scan.pageDelay or 0.5) + 0.3, step)
        end)
    end

    self:Refresh()
    -- a beat for the item cache requests to land before the first search
    U:After(1.0, step)
end

function M:StopScan()
    if not self.scanning then return end
    self.scanning = false
    local job = self.profScan
    self.profScan = nil
    if AMS.Scanner and AMS.Scanner.Abort then AMS.Scanner:Abort("you stopped it") end
    AMS:Print("stopped.%s", job and (" %d material%s priced before you did."):format(
        job.done, job.done == 1 and "" or "s") or "")
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
        M.selectedEnchant = nil
        M:Refresh()
        return true
    end
    slot:SetScript("OnReceiveDrag", takeCursorItem)
    slot:SetScript("OnClick", function(_, button)
        if takeCursorItem() then return end
        if button == "RightButton" then
            M.selected, M.selectedEnchant = nil, nil
            M:Refresh()
        end
    end)

    header.text:ClearAllPoints()
    header.text:SetPoint("LEFT", slot, "RIGHT", 8, 0)

    local scanBtn = Skin:Button(header, "Price it all", 100, 22)
    scanBtn:SetPoint("RIGHT", -8, 0)
    scanBtn:SetScript("OnClick", function()
        if M.scanning then return M:StopScan() end
        -- What "all" means depends on what you are looking at: one conversion,
        -- or the whole profession's material list.
        if M.activeView == "prof" then
            M:ScanProfession(M.profession)
        else
            M:ScanAll(M:CurrentItems())
        end
    end)
    Skin:AddTooltip(scanBtn, "Price what you are looking at",
        {"On Made from / Used in: scans this conversion's item and each of its reagents.",
         " ",
         "On Professions: scans every material the profession uses, most-used first, so the",
         "recipes that share one all become costable together. Anything priced in the last",
         "half hour is skipped.",
         " ",
         "Every scan also records prices for everything else on the pages it reads, so a run",
         "fills in far more than it asks for. Press again to stop - what has been read is kept."})
    ui.scanBtn = scanBtn

    -- Works with the auction house closed: it only adds the items to the
    -- watchlist so a later "Scan all" picks them up.
    local watchBtn = Skin:Button(header, "Watch all", 92, 22)
    watchBtn:SetPoint("RIGHT", scanBtn, "LEFT", -4, 0)
    watchBtn:SetScript("OnClick", function() M:WatchAll(M:CurrentItems()) end)
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
        function(p)
            local r = Skin:Row(p, knownCols and knownCols() or KNOWN_COLS)
            r:EnableIcon(1, 14)
            return r
        end,
        function(row, d, idx, alt)
            if not d then
                for i = 1, #KNOWN_COLS do row:Set(i, "") end
                row:SetIcon(nil)
                row:SetScript("OnClick", nil)
                return
            end
            row:Set(1, U:ItemCell(row, d.id, d.name, d.quality))
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

    -- The third way in, and the only one that is not about the selected item:
    -- browse a whole profession and see what it can make.
    local profBtn = Skin:TabButton(panel, "Professions", 110, 20)
    profBtn:SetPoint("LEFT", usedBtn, "RIGHT", 4, 0)
    profBtn:SetScript("OnClick", function() M.view = "prof"; M:Refresh() end)
    Skin:AddTooltip(profBtn, "Browse by profession",
        {"Everything a profession can make and what each one needs, costed at today's prices.",
         " ",
         "It lists the whole profession, not only what you know - a profession you do not",
         "have still tells you whether its mats are worth posting.",
         " ",
         "Open the profession window once and the recipes you actually know get marked."})
    ui.profBtn = profBtn

    local profDrop = Skin:Dropdown(panel, 190, 20)
    profDrop:SetPoint("LEFT", profBtn, "RIGHT", 8, 0)
    profDrop.OnValueChanged = function(_, v)
        M.profession     = v
        AMS.db.craftProf = v      -- the one you browse is rarely the one you browsed by accident
        M.view = "prof"
        M:Refresh()
    end
    profDrop:Hide()
    ui.profDrop = profDrop

    -- Casting the profession is what opens its window, and that is the only way
    -- to learn which recipes are yours. Has to be a real click - the client
    -- refuses a cast that did not come from one.
    local openProfBtn = Skin:Button(panel, "Open it", 80, 20)
    openProfBtn:SetPoint("LEFT", profDrop, "RIGHT", 6, 0)
    openProfBtn:SetScript("OnClick", function()
        local p = M.profession
        if p and CastSpellByName then CastSpellByName(p) end
    end)
    Skin:AddTooltip(openProfBtn, "Open this profession",
        {"Opens your profession window, which is the moment the addon can read",
         "every recipe you know - exact reagents and all.",
         " ",
         "Only works for a profession this character actually has."})
    openProfBtn:Hide()
    ui.openProfBtn = openProfBtn

    -- Enchanting only. An enchant has no item id of its own, so the only way to
    -- learn what a Scroll of <enchant> is worth is to see one on the board.
    local scrollBtn = Skin:Button(panel, "Find scrolls", 96, 20)
    scrollBtn:SetPoint("LEFT", openProfBtn, "RIGHT", 6, 0)
    scrollBtn:SetScript("OnClick", function() M:FindScrolls() end)
    Skin:AddTooltip(scrollBtn, "Match scrolls to enchants",
        {"Searches the auction house once for 'Scroll of Enchant' and reads the item id",
         "off every scroll anyone has listed.",
         " ",
         "Each enchant is costed from its reagents already - what is missing is what the",
         "scroll SELLS for, and that needs the scroll's own id. This is how it gets one.",
         " ",
         "An enchant nobody has listed stays unpriced, which is honest: there is no market",
         "price for something with no scroll on the board."})
    scrollBtn:Hide()
    ui.scrollBtn = scrollBtn

    -- Turns "no price to compare against" into "here is what you would have to
    -- ask". Off by default: a suggested price is arithmetic, not a market, and
    -- it should never be mistaken for one.
    local askBtn = Skin:TabButton(panel, "Ask price", 90, 20)
    askBtn.text:ClearAllPoints()
    askBtn.text:SetPoint("CENTER")
    askBtn:SetPoint("LEFT", scrollBtn, "RIGHT", 6, 0)
    askBtn:SetScript("OnClick", function()
        AMS.db.craftAskPrice = not AMS.db.craftAskPrice
        M:Refresh()
    end)
    Skin:AddTooltip(askBtn, "Show what to ask",
        {"For anything with a materials cost but no market price, fills in the price that",
         "would clear your required margin once the auction house has taken its cut.",
         " ",
         "It is shown in blue, because it is worked out rather than observed - a real price",
         "only comes from a scan.",
         " ",
         "The margin comes from 'Required margin' in Settings."})
    askBtn:Hide()
    ui.askBtn = askBtn

    local outHdr = Skin:ListHeader(panel, OUT_COLS)
    outHdr:SetPoint("TOPLEFT", madeBtn, "BOTTOMLEFT", 0, -6)
    outHdr:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    ui.outHdr = outHdr

    local outCols
    local outList = Skin:ScrollList(panel, 19,
        function(p)
            local r = Skin:Row(p, outCols and outCols() or OUT_COLS)
            r:EnableIcon(1, 14)
            return r
        end,
        function(row, d, idx, alt)
            if not d then
                for i = 1, #OUT_COLS do row:Set(i, "") end
                row:SetIcon(nil)
                row:SetScript("OnClick", nil)
                return
            end
            -- Resolved here rather than when the list was built: only the rows
            -- on screen get asked for, so scrolling a five hundred row
            -- profession never queues more than a screenful at a time.
            --
            -- The icon is also the manual escape hatch - hovering it shows the
            -- real tooltip, which is the same request, only sooner.
            -- the suffix sits outside the quality colour on purpose: a colour
            -- code closed inside another one resets to white, not back to it
            row:Set(1, U:ItemCell(row, d.id, d.name, d.quality) .. (d.suffix or ""))
            row:Set(2, d.perOp == math.floor(d.perOp)
                        and tostring(math.floor(d.perOp))
                        or ("%.2f"):format(d.perOp))
            row:Set(3, d.total and tostring(d.total) or "-", C.textDim)
            row:Set(4, d.price and U:MoneyShort(d.price) or "not priced",
                       d.price and C.text or C.warn)
            if d.askPrice then
                -- blue and prefixed: this is arithmetic, not a price anyone
                -- has actually paid
                row:Set(5, "ask "..U:MoneyShort(d.askPrice), C.info)
            elseif d.netText then
                row:Set(5, d.netText, d.netColor or C.textDim)
            else
                row:Set(5, d.net and d.net > 0 and U:MoneyShort(d.net) or "-",
                           d.net and d.net > 0 and C.good or C.textDim)
            end
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
                -- An enchant with no scroll has no item to open on the
                -- Market, but its reagents are right there - so a left click
                -- still shows you what it is made from.
                if d.enchant then
                    if button == "RightButton" and d.id then
                        M:OpenInMarket(d.id)
                    else
                        M:InspectEnchant(d.enchant)
                    end
                    return
                end
                if not d.id then return end
                if button == "RightButton" then M:OpenInMarket(d.id) else
                    M.selected = d.id
                    M.selectedEnchant = nil
                    -- Picking a row out of the profession browser means "show
                    -- me this one", so drop back to the per-item views rather
                    -- than redrawing the list you just clicked out of.
                    if M.view == "prof" then M.view = nil end
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
        "Right-click to open it on the Market tab. Drag an item onto the slot up top to jump straight to it. "..
        "Professions lists a whole trade, yours or not, so you can see what its mats are worth making.  |  "..
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
-- Professions view
-- =============================================================================

-- One auction house search that matches listed scrolls back to their enchants,
-- so the sell side of every enchant stops being blank.
function M:FindScrolls()
    if self.scanning then return end
    if not AMS:AtAuctionHouse() then
        AMS:Print("open the auction house to look for scrolls.")
        return
    end
    self.scanning = true
    if self._ui then self._ui.header:SetSub("sweeping the auction house for enchant scrolls...") end

    AMS.Craft:ScanForScrolls(function(_, err)
        M.scanning = false
        if err then AMS:Print("scroll sweep failed: %s", err) end
        M:Refresh()
    end)
    self:Refresh()
end

function M:RefreshProfessions()
    local ui = self._ui
    local profs = AMS.Craft:Professions()

    if #profs == 0 then
        ui.header:SetText("Craft - Professions")
        ui.header:SetSub("no recipe data")
        ui.verdict:Set("NO RECIPE DATA",
            "Data/RecipeData.lua did not load. Reinstall the addon - that file is where every recipe in the game comes from.",
            C.bad)
        ui.outList:SetData({})
        ui.openProfBtn:SetEnabled(false)
        return
    end

    local items = {}
    for _, p in ipairs(profs) do
        items[#items+1] = {
            value = p.name,
            -- yours carry their skill level, which is the fastest way to see
            -- which of two similar lines is the one you can actually use
            text  = p.haveIt
                and ("%s  %d/%d"):format(p.name, p.rank or 0, p.max or 0)
                or  ("%s  (%d)"):format(p.name, p.total),
        }
    end
    ui.profDrop:SetItems(items)

    -- Default to the first profession this character has - the list is sorted
    -- with yours at the top - falling back to whatever is first when they have
    -- none of them.
    local pick, rec = self.profession or AMS.db.craftProf, nil
    for _, p in ipairs(profs) do if p.name == pick then rec = p end end
    if not rec then
        rec  = profs[1]
        pick = rec.name
    end
    self.profession = pick
    ui.profDrop:SetValue(pick, nil, true)
    ui.openProfBtn:SetEnabled(rec.haveIt)

    if pick == "Enchanting" then
        ui.scrollBtn:Show()
        ui.scrollBtn:SetEnabled(AMS:AtAuctionHouse() and not self.scanning)
        ui.askBtn:ClearAllPoints()
        ui.askBtn:SetPoint("LEFT", ui.scrollBtn, "RIGHT", 6, 0)
    else
        ui.scrollBtn:Hide()
        ui.askBtn:ClearAllPoints()
        ui.askBtn:SetPoint("LEFT", ui.openProfBtn, "RIGHT", 6, 0)
    end
    ui.askBtn:Show()
    ui.askBtn:SetSelected(AMS.db.craftAskPrice and true or false)
    ui.askBtn.text:SetText(AMS.db.craftAskPrice
        and ("Ask %d%%"):format(math.floor(AMS.Config:MinMargin() * 100))
        or  "Ask price")

    ui.header:SetText("Craft - "..pick)

    local rows   = AMS.Craft:RecipesForProfession(pick)
    local askOn  = AMS.db.craftAskPrice and true or false
    local priced, best, knownRows = 0, nil, 0
    local out = {}
    for _, r in ipairs(rows) do
        if r.profit then
            priced = priced + 1
            if not best or r.profit > best.profit then best = r end
        end
        if r.known then knownRows = knownRows + 1 end
        out[#out+1] = {
            id = r.id, name = r.name, quality = r.quality,
            texture = r.texture, link = r.link,
            -- An enchant sits next to wands and oils in this list, so it is
            -- tagged: the row is an enchant, and what you actually sell is the
            -- scroll it goes on.
            suffix    = (r.known and "  |cff4cd94cknown|r" or "")
                        .. (r.isEnchant and "  |cff8a8a8escroll|r" or ""),
            enchant   = r.enchant,
            netText   = r.noScroll and "no scroll" or nil,
            netColor  = r.noScroll and C.warn or nil,
            -- worked out, not observed, so it is coloured differently and only
            -- ever fills a cell that would otherwise be empty
            askPrice  = (askOn and not r.value) and M:AskingPrice(r.cost) or nil,
            perOp     = r.made or 1,
            noItem    = r.isEnchant and not r.id or nil,
            -- "2/3" reads as "one reagent short of being costable"; a bare
            -- count next to "not priced" tells you nothing you can act on
            total     = (r.matsOk and r.matsOk < r.mats)
                          and ("%d/%d"):format(r.matsOk, r.mats)
                          or r.mats,
            price     = r.cost,
            net       = r.value,
            profitVal = r.profit,
        }
    end

    if not self.scanning then
        local waiting = U:ItemsPending()
        ui.header:SetSub(("%d recipes  |  %d priced  |  %d you know%s"):format(
            #rows, priced, knownRows,
            waiting > 0 and ("  |  %d names loading"):format(waiting) or ""))
    end

    for i, text in ipairs({ "MAKES", "QTY", "MATS", "COSTS", "SELLS FOR", "PROFIT" }) do
        if ui.outHdr.cells[i] then ui.outHdr.cells[i]:SetText(text) end
    end
    ui.outList:SetData(out)

    -- ---------- the verdict ----------
    -- Three different situations, and conflating them is what makes a browser
    -- like this useless: a profession you have but never opened looks identical
    -- to one you do not have unless it says so.
    local extra = ""
    if pick == "Enchanting" then
        local missing, total = AMS.Craft:UnmatchedEnchants()
        if missing > 0 then
            extra = (" Every one of the %d enchants is listed and costed from its reagents plus a vellum, but %d have no scroll matched yet, so what they SELL for is unknown. Press 'Find scrolls' at an auctioneer to read the ids off the board."):format(total, missing)
        else
            extra = (" All %d enchants are matched to a scroll."):format(total)
        end
    end

    if rec.haveIt and rec.known == 0 then
        ui.verdict:Set(("OPEN YOUR %s WINDOW"):format(pick:upper()),
            ("You have %s at %d/%d but the addon has never read it. Press 'Open it' - the moment the window is up, every recipe you know is recorded with its exact reagents, and those rows get marked. Everything below is what the profession can make in general."):format(
                pick, rec.rank or 0, rec.max or 0) .. extra,
            C.warn)
    elseif best then
        -- the row list holds names lazily, so the one we single out gets asked
        -- for explicitly rather than reaching the verdict as a nil
        local bestName = best.isEnchant and best.name or U:ItemName(best.id, best.name)
        ui.verdict:Set(("BEST IN %s: %s"):format(pick:upper(), bestName),
            ("%d of %d recipes can be priced. The best is %s at %s profit a craft, needing %d material%s.%s%s"):format(
                priced, #rows, bestName, U:Money(best.profit, true), best.mats,
                best.mats == 1 and "" or "s",
                best.known and " You know it." or
                    (rec.haveIt and " You do not know that one yet." or (" Nobody here has %s."):format(pick)),
                extra),
            best.profit > 0 and C.good or C.warn)
    else
        ui.verdict:Set(("%s - %d RECIPES"):format(pick:upper(), #rows),
            ("Nothing here can be priced yet - none of these materials have been scanned. Press 'Price it all' at an auctioneer and it walks the whole profession's materials, most-used first, so the recipes that share one all become costable together.%s"):format(extra),
            C.textDim)
    end
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

    -- An enchant we have no scroll for has no item id at all, so it cannot be
    -- the "current item" - but it still has reagents, a cost, and every reason
    -- to be inspectable. It is tracked separately and takes priority while set.
    local ench = self.selectedEnchant
    local e, usedCount, id

    if ench then
        e  = AMS.Craft:EvaluateEnchant(ench)
        if not e then
            self.selectedEnchant, ench = nil, nil
        else
            id        = e.recipe.id                    -- the scroll, if we know it
            usedCount = id and AMS.Craft:UsedInCount(id) or 0
        end
    end
    if not ench then
        id        = self:CurrentInput()
        e         = id and AMS.Craft:EvaluateAny(id) or nil
        usedCount = id and AMS.Craft:UsedInCount(id) or 0
    end

    local slotInfo = id and U:ItemInfo(id)
    ui.slot:SetItem(slotInfo and slotInfo.link, slotInfo and slotInfo.texture)
    -- an enchant is watchable and priceable through its reagents even with no
    -- scroll to point at
    ui.watchBtn:SetEnabled(id ~= nil or ench ~= nil)
    ui.forgetBtn:SetEnabled(id ~= nil)

    -- Which views this item actually has, and which one to show. Professions is
    -- always available: it is the one view that is not about the selected item,
    -- so it is also the sensible landing place when nothing is selected.
    local hasMade, hasUsed = e ~= nil, usedCount > 0
    local view = self.view
    if view == "made" and not hasMade then view = nil end
    if view == "used" and not hasUsed then view = nil end
    view = view or (hasMade and "made") or (hasUsed and "used") or "prof"

    self.activeView = view

    -- Set after the view has settled: what "Price it all" means depends on it.
    if self.scanning then
        ui.scanBtn:SetText("Stop")
        ui.scanBtn:SetEnabled(true)
    else
        ui.scanBtn:SetText("Price it all")
        ui.scanBtn:SetEnabled(AMS:AtAuctionHouse()
            and (view == "prof" or id ~= nil or ench ~= nil))
    end

    ui.madeBtn:SetSelected(view == "made")
    ui.usedBtn:SetSelected(view == "used")
    ui.profBtn:SetSelected(view == "prof")
    ui.madeBtn:SetEnabled(hasMade)
    ui.usedBtn:SetEnabled(hasUsed)
    ui.usedBtn.text:SetText(hasUsed and ("Used in (%d)"):format(usedCount) or "Used in")

    if view == "prof" then
        ui.profDrop:Show()
        ui.openProfBtn:Show()
        return self:RefreshProfessions()
    end
    ui.profDrop:Hide()
    ui.openProfBtn:Hide()
    ui.scrollBtn:Hide()
    ui.askBtn:Hide()

    -- "Nothing selected" is not the same as "no item id". An enchant nobody has
    -- listed a scroll for has no item id by definition, and it was landing here
    -- - blank table, blank title - despite having reagents and a cost to show.
    if not id and not ench then
        ui.header:SetText("Craft")
        if not self.scanning then ui.header:SetSub("nothing learned yet") end
        ui.verdict:Set("NOTHING LEARNED YET",
            "Prospect, mill or disenchant something while the addon is loaded and it records what went in and what came out. A few operations is enough to start; the more you do, the closer the yields get.",
            C.textDim)
        ui.outList:SetData({})
        return
    end

    -- ---------- what it goes into ----------
    if view == "used" and id then
        local uname, uquality = U:ItemName(id)
        ui.header:SetText("Craft - "..U:ColorItemName(uname, uquality))
        if not self.scanning then
            ui.header:SetSub(("used in %d recipe%s"):format(usedCount, usedCount == 1 and "" or "s"))
        end

        for i, text in ipairs({ "MAKES", "NEEDS", "", "COSTS", "SELLS FOR", "PROFIT" }) do
            if ui.outHdr.cells[i] then ui.outHdr.cells[i]:SetText(text) end
        end

        local rows = {}
        for _, r in ipairs(AMS.Craft:UsedIn(id)) do
            rows[#rows+1] = {
                id = r.id, name = r.name, quality = r.quality,
                texture = r.texture, link = r.link,
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
            local bestName = U:ItemName(best.id, best.name)
            ui.verdict:Set(("BEST USE: %s"):format(bestName),
                ("%d of the %d recipes using this can be priced. The best is %s (%s) at %s profit a craft, needing %d of these.%s"):format(
                    priced, usedCount, bestName, best.profession or "?",
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

    local rec = e.rec or e.recipe
    local itemName, itemQuality = U:ItemName(id, rec.name)
    ui.header:SetText("Craft - "..U:ColorItemName(itemName, itemQuality))
    if not self.scanning then
        if e.isRecipe then
            ui.header:SetSub(("%s%s, makes %s%s%s"):format(
                rec.profession or "?",
                rec.isScroll and " scroll" or " recipe",
                e.made == 1 and "1" or ("%.1f"):format(e.made),
                (e.routes or 1) > 1 and ("  |  %d ways to make it"):format(e.routes) or "",
                rec.noScroll and "  |  no scroll seen yet" or ""))
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
        rows[#rows+1] = {
            id = r.id, name = r.name, quality = r.quality,
            texture = r.texture, link = r.link,
            perOp = r.perOp, total = e.isRecipe and nil or r.total,
            price = r.price, net = r.net,
            share = (basis > 0 and (r.net or 0) > 0) and (r.net / basis) or nil,
        }
    end
    ui.outList:SetData(rows)

    -- ---------- the verdict ----------
    -- An enchant with no scroll has no item id to look up, so its unpriced
    -- reagents are read straight off the evaluation instead.
    local missing
    if ench then
        missing = {}
        for _, r in ipairs(e.rows) do
            if not r.price then missing[#missing+1] = { id = r.id, name = r.name } end
        end
    else
        missing = AMS.Craft:MissingPrices(id)
    end
    if #missing > 0 then
        local names = {}
        for i = 1, math.min(3, #missing) do
            names[#names+1] = U:ItemName(missing[i].id, missing[i].name)
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

    -- An enchant nobody has a scroll for can still be fully costed, and the
    -- useful question then is not "what is the profit" but "what would it have
    -- to fetch". Answer that rather than showing a row of dashes.
    if ench and not e.value then
        local ask = e.cost and M:AskingPrice(e.cost) or nil
        ui.verdict:Set(("MATERIALS %s"):format(e.cost and U:Money(e.cost, true) or "?"),
            ask and ("No scroll for this enchant has been seen, so there is no market price to compare against. "..
                     "At %s%% over materials and after the %s%% cut you would have to ask %s for the scroll. "..
                     "Press 'Find scrolls' on the Professions view at an auctioneer to get a real price.")
                    :format(math.floor(AMS.Config:MinMargin() * 100),
                            math.floor(AMS.Config:Cut() * 100), U:Money(ask, true))
                or  "Some of its reagents have never been scanned, so even the materials cost is incomplete.",
            ask and C.info or C.warn)
        return
    end

    local what = e.isRecipe
        and ("Making one %s"):format(rec.name or "of these")
        or  ("%.1f %s per operation"):format(e.inputPer or 0, rec.name or "input")

    -- A scroll also needs a vellum, which is not costed here and says so:
    -- there are six of them on this client and which one an enchant takes is
    -- not in the spell data, so a guess would be wrong more often than right.
    local extra = ""
    if rec.needsVellum then
        extra = " A vellum is needed on top of these materials - Armor or Weapon, at the right grade - and its cost is not counted here."
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
