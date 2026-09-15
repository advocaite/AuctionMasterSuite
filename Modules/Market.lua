-- Auction Master Suite -- Market tab
-- The screen the whole addon exists for: pick an item, set the price you
-- intend to defend, and see exactly what it costs to own that price.

local AMS = AuctionMasterSuite
local M = AMS:RegisterModule("market", { title = "Market", order = 10 })

local U, Skin, C

function M:OnInit()
    U, Skin = AMS.Util, AMS.Skin
    C = Skin.COLOR

    -- Switching item from ANY tab must drop the old scan. Leaving it would show
    -- one item's auctions under another's name, and - far worse - leave the buy
    -- queue holding auctions for the item you just navigated away from.
    AMS:Subscribe("CURRENT_CHANGED", function()
        M.entries   = nil
        M.result    = nil
        M.scannedAt = nil
        AMS.Buyer:Clear()
        M:Refresh()
    end)
    AMS:Subscribe("MARKETS_CHANGED", function() M:Refresh() end)
    AMS:Subscribe("LEDGER_CHANGED",  function() M:Refresh() end)
    AMS:Subscribe("BAGS_CHANGED",    function() M:RefreshSoon() end)
    AMS:Subscribe("AH_STATE",        function() M:Refresh() end)

    AMS:Subscribe("SCAN_STATE", function(active, name)
        M.scanning = active
        M:Refresh()
    end)
    AMS:Subscribe("SCAN_PROGRESS", function(page, pages, found)
        if M._ui and M._ui.header then
            M._ui.header:SetSub(("scanning page %d/%s - %d found"):format(page, pages or "?", found))
        end
    end)

    -- A purchase removes that auction from the world; drop it locally rather
    -- than pretending the old scan is still true. Debounced, because a batch
    -- buy fires this once per auction.
    AMS:Subscribe("BOUGHT", function(entry)
        if not M.entries then return end
        for i, e in ipairs(M.entries) do
            if e == entry then table.remove(M.entries, i) break end
        end
        M:EvaluateSoon()
    end)
    AMS:Subscribe("QUEUE_CHANGED", function() M:RefreshBuyBar() end)
    AMS:Subscribe("BUY_STATE",     function() M:RefreshBuyBar() end)
    AMS:Subscribe("BUY_BUSY",      function() M:RefreshBuyBar() end)
    AMS:Subscribe("BUY_READY",     function() M:RefreshBuyBar() end)
    AMS:Subscribe("MANUAL_READY",  function() M:RefreshBuyBar() end)

    -- pick up where we left off
    if AMS.db.lastMarket and AMS.DB:GetMarket(AMS.db.lastMarket) then
        AMS:SetCurrentMarket(AMS.db.lastMarket)
    end
end

function M:RefreshSoon()
    if self._pending then return end
    self._pending = U:After(0.2, function() M._pending = nil; M:Refresh() end)
end

-- =============================================================================
-- Item selection
-- =============================================================================

function M:SelectItem(idOrLink)
    local info = U:ItemInfo(idOrLink)
    if not info then
        AMS:Print("that item is not in your client cache yet - try again after you have seen it once.")
        return
    end
    local m = AMS.DB:EnsureMarket(info)
    AMS.db.lastMarket = info.id
    AMS:SetCurrentMarket(info.id)
    self.entries = nil
    self.result  = nil
    AMS.Buyer:Clear()
    self:Refresh()
    return m
end

function M:OpenItemByName(name)
    local info = U:ItemInfo(name)
    if info then return self:SelectItem(info.id) end

    -- Not in the client's cache, so we cannot resolve it locally. Ask the
    -- auction house instead - that is the only place to look up an item you
    -- have never owned or seen.
    local wl = AMS:GetModule("watchlist")
    if wl and AMS:AtAuctionHouse() then
        AMS:Print("'%s' is not in your item cache - searching the auction house.", name)
        AMS.UI:Show("watchlist")
        wl:Search(name)
        return
    end
    AMS.DB:AddMarketByName(name)
end

-- =============================================================================
-- Scanning + evaluation
-- =============================================================================

function M:Rescan()
    local m = AMS:CurrentMarket()
    if not m then AMS:Print("pick an item first.") return end
    if not AMS:AtAuctionHouse() then AMS:Print("open the auction house first.") return end

    AMS.Buyer:Clear()
    AMS.Analysis:ScanAndEvaluate(m, function(result, entries, err)
        if err then
            AMS:Print("scan failed: %s", err)
            if M._ui then M._ui.header:SetSub("scan failed: "..err) end
            return
        end
        M.entries   = entries
        M.result    = result
        M.scannedAt = U:Now()
        AMS.Buyer:SetQueue(m, result.buyList, result.levels.buyCeiling, result.maxStack)
        M:Refresh()

        -- Keep your own listed stock in sync while we are here.
        AMS.Scanner:ScanOwned(function(owned)
            if owned then AMS.Inventory:SetListed(owned) end
            M:Refresh()
            -- line the first batch up so BUY is live the moment you look at it
            if AMS.Buyer:Count() > 0 then AMS.Buyer:Prepare() end
        end)
    end)
end

-- With no live scan, fall back to what we saw last time rather than showing an
-- item you have scanned before as though it were a blank. Marked as stored so
-- it is never mistaken for current prices.
function M:OverlaySnapshot(m, r)
    local snap = AMS.DB:LastSnapshot(m.id)
    if not snap then return end

    r.fromSnapshot   = snap
    r.lowest         = (snap.min or 0) > 0 and snap.min or nil
    r.median         = snap.median or 0
    r.mean           = snap.mean or 0
    r.totalSupply    = snap.supply or 0
    r.mySupply       = snap.mine or 0
    r.underTargetUnits = snap.underUnits or 0
    r.underTargetCost  = snap.underCost or 0
    r.allUnderUnits  = snap.underUnits or 0
    r.buyUnits       = snap.buyUnits or 0
    r.buyCost        = snap.buyCost or 0
    r.buyAvg         = (snap.buyUnits or 0) > 0 and math.floor(snap.buyCost / snap.buyUnits) or 0
    r.profit         = snap.profit or 0
    r.roi            = snap.roi or 0
    if snap.health then r.health = snap.health end
end

-- Re-runs the maths on the scan we already have (after a settings change or a
-- purchase). Does not write a history snapshot - nothing new was observed.
function M:Evaluate()
    local m = AMS:CurrentMarket()
    if not m then return end
    self.result = AMS.Analysis:Evaluate(m, self.entries)
    if not self.entries then self:OverlaySnapshot(m, self.result) end

    -- Never rebuild the queue while the buyer is working through it: SetQueue
    -- begins by stopping the run, which is exactly what made auto-advance buy
    -- one auction and quietly give up. The buyer already removes what it buys.
    if self.entries and not (AMS.Buyer.running or AMS.Buyer.busy) then
        AMS.Buyer:SetQueue(m, self.result.buyList, self.result.levels.buyCeiling, self.result.maxStack)
    end
    self:Refresh()
end

-- Coalesces the re-evaluation that follows a burst of purchases.
function M:EvaluateSoon()
    if self._evalPending then return end
    self._evalPending = U:After(0.3, function()
        M._evalPending = nil
        M:Evaluate()
    end)
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

    -- ---------- header ----------
    local header = Skin:Header(panel, "Market")
    header:SetPoint("TOPLEFT", 8, -8); header:SetPoint("TOPRIGHT", -8, -8)
    header:SetHeight(44)
    ui.header = header

    local slot = Skin:ItemSlot(header, 32)
    slot:SetPoint("LEFT", 8, 0)
    ui.slot = slot

    local function takeCursorItem()
        if not CursorHasItem() then return false end
        local kind, id, link = GetCursorInfo()
        ClearCursor()
        if kind == "item" then
            M:SelectItem(link or id)
            return true
        end
        return false
    end
    slot:SetScript("OnReceiveDrag", takeCursorItem)
    slot:SetScript("OnClick", function(_, button)
        if takeCursorItem() then return end
        if button == "RightButton" then
            AMS:SetCurrentMarket(nil)
            M.entries, M.result = nil, nil
            AMS.Buyer:Clear()
            M:Refresh()
        end
    end)

    header.text:ClearAllPoints()
    header.text:SetPoint("LEFT", slot, "RIGHT", 8, 6)
    Skin:Font(header.text, 15, true)

    local sub2 = header:CreateFontString(nil, "OVERLAY")
    Skin:Font(sub2, 10, false)
    sub2:SetTextColor(unpack(C.textDim))
    sub2:SetPoint("LEFT", slot, "RIGHT", 8, -8)
    ui.itemSub = sub2

    header.sub:ClearAllPoints()
    header.sub:SetPoint("RIGHT", -10, 12)

    local scanBtn = Skin:Button(header, "Scan", 70, 22)
    scanBtn:SetPoint("RIGHT", -8, -8)
    scanBtn:SetScript("OnClick", function() M:Rescan() end)
    Skin:AddTooltip(scanBtn, "Scan this item",
        {"Reads every page of the auction house for this item name and works out what it costs to clear."})
    ui.scanBtn = scanBtn

    local depBtn = Skin:Button(header, "Deposit", 70, 22)
    depBtn:SetPoint("RIGHT", scanBtn, "LEFT", -4, 0)
    depBtn:SetScript("OnClick", function()
        local m = AMS:CurrentMarket()
        if not m then return end
        AMS.Poster:ProbeDeposit(m, m.stack or 1, m.duration or 3, function() M:Refresh() end)
    end)
    Skin:AddTooltip(depBtn, "Measure the deposit",
        {"The 3.3.5 API will not tell you an item's deposit unless it is sitting in the auction slot.",
         "This puts one stack in, reads the number, and takes it straight back out.",
         "Needed for accurate break-even maths on items you relist a lot."})
    ui.depBtn = depBtn

    -- ---------- settings strip ----------
    local strip = Skin:FieldStrip(panel, { rowH = 38, padX = 8, gap = 12, labelY = -4, ctrlY = -16 })
    strip:SetPoint("TOPLEFT",  header, "BOTTOMLEFT",  0, -6)
    strip:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -6)
    ui.strip = strip

    local function field(label, width, builder, tip)
        return strip:Add(label, width, builder, tip)
    end

    ui.targetBox = field("TARGET PRICE", 180, function(p, w) return Skin:MoneyInput(p, w, 20) end,
        {"The price you intend to defend, per unit.",
         "Everything else - break-even, buy ceiling, profit - is derived from this."})
    ui.targetBox.OnMoneyChanged = function(_, v)
        local m = AMS:CurrentMarket(); if not m then return end
        m.target = v
        M:Evaluate()
    end

    ui.marginBox = field("MARGIN %", 50, function(p, w) return Skin:NumberBox(p, w, 20) end,
        {"Minimum margin you require over what you pay.",
         "Your buy ceiling is set so reselling at target leaves at least this much."})
    ui.marginBox.OnNumberChanged = function(_, v)
        local m = AMS:CurrentMarket(); if not m then return end
        m.minMargin = v
        M:Evaluate()
    end

    ui.tolBox = field("LEAVE %", 50, function(p, w) return Skin:NumberBox(p, w, 20) end,
        {"Competitors within this much of your target are effectively already at your price.",
         "Buying them out is gold spent for nothing."})
    ui.tolBox.OnNumberChanged = function(_, v)
        local m = AMS:CurrentMarket(); if not m then return end
        m.tolerance = v
        M:Evaluate()
    end

    ui.investBox = field("MAX INVESTED", 180, function(p, w) return Skin:MoneyInput(p, w, 20) end,
        {"Hard cap on gold tied up in this one item. 0 = no cap.",
         "This is the line between running a market and betting your fortune on one commodity.",
         "If clearing would cross it, the verdict turns red and says so."})
    ui.investBox.OnMoneyChanged = function(_, v)
        local m = AMS:CurrentMarket(); if not m then return end
        m.maxInvest = v
        M:Evaluate()
    end

    ui.stockBox = field("MAX STOCK", 60, function(p, w) return Skin:NumberBox(p, w, 20) end,
        {"Hard cap on units held. 0 = no cap."})
    ui.stockBox.OnNumberChanged = function(_, v)
        local m = AMS:CurrentMarket(); if not m then return end
        m.maxStock = v
        M:Evaluate()
    end

    ui.stackBox = field("POST STACK", 56, function(p, w) return Skin:NumberBox(p, w, 20) end,
        {"Units per auction when you post.",
         "1 is the single-unit strategy: someone who needs three buys three singles happily,",
         "but balks at a stack of twenty at the same price per unit."})
    ui.stackBox.OnNumberChanged = function(_, v)
        local m = AMS:CurrentMarket(); if not m then return end
        m.stack = math.max(1, v)
        M:Refresh()
    end

    ui.buyStackBox = field("MAX BUY STACK", 68, function(p, w) return Skin:NumberBox(p, w, 20) end,
        {"Never queue an auction holding more units than this. 0 buys any size.",
         " ",
         "Worth knowing before you set it: buying a 20-stack and reposting it as twenty singles",
         "earns exactly the same margin per unit as buying twenty singles would. What a big stack",
         "really costs you is gold tied up in one click, and longer to liquidate.",
         " ",
         "Where it genuinely pays off is competition - see 'Big stacks count as competition' in Settings."})
    ui.buyStackBox.OnNumberChanged = function(_, v)
        local m = AMS:CurrentMarket(); if not m then return end
        m.buyMaxStack = math.max(0, v)
        M:Evaluate()
    end

    do
        local dd = field("BUY ORDER", 116, function(p, w) return Skin:Dropdown(p, w, 20) end,
            {"Cheapest first: best price per unit leads the queue.",
             "Small stacks first: singles and small lots lead, so stopping half way through",
             "leaves you holding the flexible stock rather than one huge lot."})
        dd:SetItems({
            { text = "Cheapest first",  value = "cheapest" },
            { text = "Small stacks 1st", value = "smallest" },
        })
        dd.OnValueChanged = function(_, v)
            local m = AMS:CurrentMarket(); if not m then return end
            m.buyOrder = v
            M:Evaluate()
        end
        ui.orderDrop = dd
    end

    -- ---------- bottom: buy bar ----------
    local buyBar = Skin:Panel(panel)
    buyBar:SetPoint("BOTTOMLEFT", 8, 8); buyBar:SetPoint("BOTTOMRIGHT", -8, 8)
    buyBar:SetHeight(40)
    ui.buyBar = buyBar

    local buyBtn = Skin:BigButton(buyBar, "BUY", 230, 28, C.good)
    buyBtn:SetPoint("LEFT", 8, 0)
    -- Wired straight to OnClick on purpose: PlaceAuctionBid only works inside a
    -- hardware event, so the purchase has to happen in this call stack.
    buyBtn:SetScript("OnClick", function() AMS.Buyer:Click() end)
    Skin:AddTooltip(buyBtn, "Buy the prepared batch",
        {"Buys every auction listed on the button in one click.",
         "Each row is re-checked against the live listing before any gold moves, and matched by",
         "name, stack size and price rather than by index, so it cannot buy you the wrong thing.",
         " ",
         "WoW only lets an addon buy inside a real mouse click, so the addon cannot do this",
         "for you unattended. Auto keeps the next batch ready so you just keep clicking."})
    ui.buyBtn = buyBtn

    local autoBtn = Skin:Button(buyBar, "Auto", 60, 28)
    autoBtn:SetPoint("LEFT", buyBtn, "RIGHT", 6, 0)
    autoBtn:SetScript("OnClick", function() AMS.Buyer:Toggle() end)
    Skin:AddTooltip(autoBtn, "Auto-prepare",
        {"Keeps the next batch found and resolved so the BUY button is ready the moment you",
         "finish the last one - clearing a market becomes one click per batch with no waiting.",
         " ",
         "It cannot press BUY for you: the client rejects purchases that do not come from a",
         "real click. Auctionator works the same way, which is why it asks you to Continue."})
    ui.autoBtn = autoBtn

    local clearBtn = Skin:Button(buyBar, "Clear", 60, 28)
    clearBtn:SetPoint("LEFT", autoBtn, "RIGHT", 6, 0)
    clearBtn:SetScript("OnClick", function() AMS.Buyer:Clear() end)

    local prog = Skin:Bar(buyBar, 200, 16)
    prog:SetPoint("LEFT", clearBtn, "RIGHT", 12, 0)
    prog:SetPoint("RIGHT", -8, 0)
    prog:EnableMouse(true)
    Skin:AddTooltip(prog, "Buy queue progress",
        {"How far through the queue this scan's purchases have got.",
         "The queue holds every auction at or under your buy ceiling, in the order set by BUY ORDER.",
         "It shrinks as you buy, and is rebuilt whenever you scan."})
    ui.progress = prog

    -- ---------- verdict ----------
    local verdict = Skin:Verdict(panel)
    verdict:SetPoint("BOTTOMLEFT",  buyBar, "TOPLEFT",  0, 6)
    verdict:SetPoint("BOTTOMRIGHT", buyBar, "TOPRIGHT", 0, 6)
    ui.verdict = verdict

    -- ---------- right column: the numbers ----------
    -- Scrolls: there are more numbers here than fit at any sane window height,
    -- and letting them spill over the verdict banner is worse than a scrollbar.
    local statsScroll = Skin:ScrollFrame(panel)
    statsScroll:SetPoint("TOPRIGHT",    strip,   "BOTTOMRIGHT", 0, -6)
    statsScroll:SetPoint("BOTTOMRIGHT", verdict, "TOPRIGHT",    0, 6)
    statsScroll:SetWidth(324)
    ui.statsScroll = statsScroll

    local stats = statsScroll.content
    ui.stats = stats

    ui.lines = {}
    local y = -8
    local function statLine(key, label)
        local sl = Skin:StatLine(stats, label, 12)
        sl:SetPoint("TOPLEFT", 8, y)
        sl:SetPoint("RIGHT", -8, 0)
        ui.lines[key] = sl
        y = y - 18
        return sl
    end
    local function gap(title)
        y = y - 7
        if title then
            local t = Skin:Label(stats, title, 10, true, C.accentDim)
            t:SetPoint("TOPLEFT", 8, y)
            y = y - 15
        end
    end

    gap("PRICE")
    statLine("lowest",    "Lowest competitor")
    statLine("median",    "Median (weighted)")
    statLine("yours",     "Your lowest listing")
    statLine("breakeven", "Break-even buy")
    statLine("ceiling",   "Buy ceiling")

    gap("AGAINST ITS OWN NORMAL")
    statLine("baseline",  "Baseline price")
    statLine("deviation", "Now vs baseline")
    statLine("recovery",  "Past dips recovered in")

    gap("SUPPLY")
    statLine("supply",    "On the auction house")
    statLine("under",     "Under your target")
    statLine("bigstacks", "Skipped as too big")
    statLine("clear",     "Cost to clear")
    statLine("avgcost",   "Average acquisition")
    statLine("wall",      "Largest wall")

    gap("RETURN")
    statLine("resale",    "Resale net")
    statLine("profit",    "Projected profit")
    statLine("roi",       "ROI")
    statLine("perday",    "Profit per day")

    gap("POSITION")
    statLine("stock",     "Stock (bags/bank/listed)")
    statLine("invested",  "Capital invested")
    statLine("velocity",  "Sales per day")
    statLine("days",      "Days to clear stock")
    statLine("refill",    "Refill under target")

    gap("CRAFTING")
    statLine("craftcost", "Cost to craft")
    statLine("craftedge", "Craft vs buy")
    statLine("converts",  "Converts into")

    gap("HEALTH")
    local bar = Skin:Bar(stats, 200, 16)
    bar:SetPoint("TOPLEFT", 8, y)
    bar:SetPoint("RIGHT", -8, 0)
    ui.health = bar
    y = y - 16

    statsScroll:SetContentHeight(-y + 8)

    -- ---------- left column: the auctions ----------
    local COLS = {
        { text = "EACH",   width = 72,  justify = "RIGHT" },
        { text = "QTY",    width = 38,  justify = "RIGHT" },
        { text = "TOTAL",  width = 82,  justify = "RIGHT" },
        { text = "SELLER", width = 108, justify = "LEFT"  },
        { text = "LEFT",   width = 34,  justify = "LEFT"  },
        -- room for the per-row buy and undercut buttons; they anchor to this
        -- cell so they follow when the columns rescale
        { text = "",       width = 88,  min = 84, justify = "RIGHT" },
    }

    local listHdr = Skin:ListHeader(panel, COLS)
    listHdr:SetPoint("TOPLEFT", strip, "BOTTOMLEFT", 0, -6)
    listHdr:SetPoint("RIGHT", statsScroll, "LEFT", -6, 0)
    ui.listHdr = listHdr

    local TIMELEFT = { [1] = "30m", [2] = "2h", [3] = "12h", [4] = "48h" }

    local list = Skin:ScrollList(panel, 18,
        function(parentList)
            local r = Skin:Row(parentList, ui.cols and ui.cols() or COLS)

            -- "just buy this one" - a row click is a hardware event, so this
            -- can put the purchase through there and then
            local b = Skin:Button(r, "Buy", 42, 15)
            Skin:Font(b.text, 10, true)
            b:ClearAllPoints()
            b:SetPoint("RIGHT", r.cells[#r.cells], "RIGHT", 0, 0)
            b:SetScript("OnClick", function()
                if r.entry then AMS.Buyer:BuyOne(r.entry) end
            end)
            Skin:AddTooltip(b, "Buy just this auction",
                {"Buys this one listing, ignoring the queue.",
                 " ",
                 "If the auction house happens to be holding the page it lives on, it is bought",
                 "immediately. Otherwise that page is fetched and you click once more - the client",
                 "only accepts a purchase from a real click, so it cannot be done in one step.",
                 " ",
                 "A dim Buy means it is above your break-even; you will be asked to confirm."})
            r.buyBtn = b

            -- "price mine just under this one"
            local uc = Skin:Button(r, "UC", 38, 15)
            Skin:Font(uc.text, 10, true)
            uc:ClearAllPoints()
            uc:SetPoint("RIGHT", b, "LEFT", -4, 0)
            uc:SetScript("OnClick", function()
                if not r.entry or not r.entry.unit then return end
                local post = AMS:GetModule("post")
                if post then
                    post:UndercutTo(r.entry.unit)
                    AMS.UI:Show("post")
                end
            end)
            Skin:AddTooltip(uc, "Undercut this listing",
                {"Sets your posting price just under this one and opens the Post tab.",
                 "How far under is set by 'Undercut by' in Settings.",
                 " ",
                 "It will not price you below what your stock cost you unless you turn",
                 "that guard off in Settings."})
            r.ucBtn = uc
            return r
        end,
        function(row, e, idx, alt)
            row.entry = e
            if not e then
                for i = 1, #COLS do row:Set(i, "") end
                row:Tint({0, 0, 0, 0})
                row.buyBtn:Hide()
                row.ucBtn:Hide()
                return
            end
            local res = M.result
            local ceiling = res and res.levels.buyCeiling or 0
            local target  = res and res.target or 0

            -- gold  = yours
            -- green = queued to buy
            -- blue  = right price, but the stack is bigger than you buy
            -- amber = under target, above your ceiling (too dear to clear)
            local col, qtyCol = C.textDim, nil
            if e.mine then col = C.accent
            elseif e.unit and target > 0 and e.unit <= ceiling then
                if e.tooBig then col, qtyCol = C.info, C.info
                else col = C.good end
            elseif e.unit and target > 0 and e.unit < target then col = C.warn
            else col = C.text end

            row:Set(1, e.unit and U:MoneyShort(e.unit) or "bid only", col)
            row:Set(2, tostring(e.count or 0), qtyCol or col)
            row:Set(3, e.buyout > 0 and U:MoneyShort(e.buyout) or "-", col)
            -- the client only knows seller names it has cached; blank is common
            row:Set(4, e.mine and "you" or e.owner or "-", e.owner and col or C.textDim)
            row:Set(5, TIMELEFT[e.timeLeft or 0] or "", C.textDim)
            row:Set(6, "")
            row:Tint(alt and C.bgRowAlt or C.bgRow)

            -- undercutting your own listing is the one thing UC must never do
            if e.unit and not e.mine then row.ucBtn:Show() else row.ucBtn:Hide() end

            -- your own auctions and bid-only listings cannot be bought
            if e.mine or not e.unit or (e.buyout or 0) <= 0 then
                row.buyBtn:Hide()
            else
                row.buyBtn:Show()
                -- green when it is inside your ceiling, dim when buying it by
                -- hand would be a deliberate exception
                local good = target > 0 and e.unit <= ceiling
                row.buyBtn.textColor = good and C.good or C.textDim
                row.buyBtn.text:SetTextColor(unpack(row.buyBtn.textColor))
            end
        end)
    list:SetPoint("TOPLEFT", listHdr,     "BOTTOMLEFT", 0, -2)
    list:SetPoint("RIGHT",   statsScroll, "LEFT",       -6, 0)
    list:SetPoint("BOTTOM",  verdict,     "TOP",         0, 6)
    ui.cols = Skin:AutoCols(listHdr, list, COLS)
    ui.list = list

    panel:SetScript("OnShow", function() M:Refresh() end)
    self:Refresh()
    return panel
end

-- =============================================================================
-- Refresh
-- =============================================================================

local function setLine(ui, key, text, color)
    local sl = ui.lines[key]
    if sl then sl:SetValue(text or "-", color) end
end

function M:RefreshBuyBar()
    local ui = self._ui
    if not ui or not ui.buyBtn then return end

    local B = AMS.Buyer
    local n = B:Count()
    local head = B.queue[1]
    local ready = B.ready

    if n == 0 then
        ui.buyBtn:SetText("NOTHING QUEUED")
        ui.buyBtn:Disable()
    elseif B.busy then
        -- finding the auctions takes a moment: the page they were on during the
        -- scan is not necessarily where they are now
        ui.buyBtn:SetText("FINDING AUCTIONS...")
        ui.buyBtn:Disable()
    elseif ready and #ready.rows > 0 then
        if ready.confirm then
            ui.buyBtn:SetText(("CONFIRM %s"):format(U:MoneyShort(ready.cost)))
        elseif #ready.rows == 1 then
            ui.buyBtn:SetText(("BUY %dx @ %s"):format(
                ready.rows[1].entry.count or 0, U:MoneyShort(ready.rows[1].entry.unit or 0)))
        else
            ui.buyBtn:SetText(("BUY %d AUCTIONS - %d units for %s")
                :format(#ready.rows, ready.units, U:MoneyShort(ready.cost)))
        end
        ui.buyBtn:Enable()
    else
        ui.buyBtn:SetText(("FIND %dx @ %s"):format(head.count or 0, U:MoneyShort(head.unit or 0)))
        ui.buyBtn:Enable()
    end

    ui.autoBtn:SetText(B.running and "Stop" or "Auto")

    local done, total = B:Progress()
    local units, cost = B:Remaining()
    if total > 0 then
        ui.progress:SetProgress(done / total, C.accent,
            ("%d/%d bought - %d units left, %s"):format(done, total, units, U:MoneyShort(cost)))
    else
        ui.progress:SetProgress(0, C.accent, "")
    end
end

function M:Refresh()
    local ui = self._ui
    if not ui or not ui.header then return end

    -- the stats column only knows its real height once the panel is laid out
    if ui.statsScroll then ui.statsScroll:UpdateScroll() end

    local m = AMS:CurrentMarket()

    -- ---------- header ----------
    if not m then
        ui.slot:SetItem(nil, nil)
        ui.header:SetText("No item selected")
        ui.itemSub:SetText("Drag an item onto the slot, or add one from the Watchlist tab.")
        ui.header:SetSub("")
    else
        ui.slot:SetItem(m.link, m.texture)
        ui.header:SetText(U:ColorItemName(m.name, m.quality))
        local held = AMS.Inventory:Holdings(m.id)
        ui.itemSub:SetText(("%d in bags, %d banked, %d listed  |  %s")
            :format(held.bags, held.bank, held.listed,
                    m.deposit and ("deposit "..U:Money(m.deposit, true).." per unit")
                               or "deposit not measured"))
        if self.scanning then
            ui.header:SetSub("scanning...")
        elseif self.scannedAt then
            ui.header:SetSub("scanned "..U:Ago(self.scannedAt))
        else
            local snap = AMS.DB:LastSnapshot(m.id)
            if snap then
                -- stored, not live: say so plainly so it is never mistaken for now
                ui.header:SetSub(("|cffd0a040stored from "..U:Ago(snap.t).."|r - rescan for live prices"))
            else
                ui.header:SetSub(AMS:AtAuctionHouse() and "not scanned yet" or "auction house closed")
            end
        end
    end

    ui.scanBtn:SetEnabled(m ~= nil and AMS:AtAuctionHouse() and not self.scanning)
    ui.depBtn:SetEnabled(m ~= nil and AMS:AtAuctionHouse())

    -- ---------- settings strip ----------
    local boxes = { ui.targetBox, ui.marginBox, ui.tolBox, ui.investBox,
                    ui.stockBox, ui.stackBox, ui.buyStackBox }
    for _, b in ipairs(boxes) do if m then b:Enable() else b:Disable() end end
    if m then
        if not ui.targetBox:HasFocus() then ui.targetBox:SetMoney(m.target or 0) end
        if not ui.marginBox:HasFocus() then ui.marginBox:SetNumber(m.minMargin or AMS.db.market.minMargin) end
        if not ui.tolBox:HasFocus()    then ui.tolBox:SetNumber(m.tolerance or AMS.db.market.tolerance) end
        if not ui.investBox:HasFocus() then ui.investBox:SetMoney(m.maxInvest or 0) end
        if not ui.stockBox:HasFocus()  then ui.stockBox:SetNumber(m.maxStock or 0) end
        if not ui.stackBox:HasFocus()  then ui.stackBox:SetNumber(m.stack or 1) end
        if not ui.buyStackBox:HasFocus() then ui.buyStackBox:SetNumber(AMS.DB:MaxBuyStackOf(m)) end
        -- silent: SetValue would fire OnValueChanged back into Refresh
        ui.orderDrop:SetValue(AMS.DB:BuyOrderOf(m), nil, true)
    end

    -- ---------- numbers ----------
    local r = self.result
    if not r and m then
        r = AMS.Analysis:Evaluate(m, nil)
        self:OverlaySnapshot(m, r)
        self.result = r
    end

    if not r then
        for key in pairs(ui.lines) do setLine(ui, key, "-", C.textDim) end
        ui.health:SetProgress(0, C.textDim, "")
        ui.verdict:Set("PICK AN ITEM", "Drag an item onto the slot to start a market.", C.textDim)
        ui.list:SetData({})
        self:RefreshBuyBar()
        return
    end

    local L = r.levels

    setLine(ui, "lowest",    r.lowest and U:Money(r.lowest) or "nothing listed",
                             r.lowest and r.lowest < L.buyCeiling and C.good or C.text)
    setLine(ui, "median",    r.median > 0 and U:Money(r.median) or "-")
    setLine(ui, "yours",     r.myLowest and U:Money(r.myLowest) or "not listed", C.accent)
    setLine(ui, "breakeven", L.breakEven > 0 and U:Money(L.breakEven) or "-", C.warn)
    setLine(ui, "ceiling",   L.buyCeiling > 0 and U:Money(L.buyCeiling) or "-", C.textHead)

    local d = r.dislocation
    if d then
        setLine(ui, "baseline", U:Money(d.baseline).."  +/- "..U:MoneyShort(d.sd))
        local tone = d.isDump and C.info
                  or d.level == "soft" and C.warn
                  or d.level == "rich" and C.good or C.text
        setLine(ui, "deviation", ("%+.0f%%  (%.1f sigma)"):format(d.pct * 100, d.z), tone)
        setLine(ui, "recovery", d.recoveryDays
            and ("%.1f days  (%d seen)"):format(d.recoveryDays, d.episodes)
            or "no past dip on record", d.recoveryDays and C.text or C.textDim)
        Skin:AddTooltip(ui.lines.deviation, "How far from normal",
            {("Baseline %s, built from %d days of your scans as a median of daily medians -"):format(
                U:Money(d.baseline, true), d.samples),
             "a median so a dump cannot drag the baseline down and hide itself.",
             " ",
             ("Typical swing is %s, so right now is %.1f standard deviations out."):format(
                U:MoneyShort(d.sd), d.z),
             "Sigma matters more than percent: on a placid item 15% off is enormous,",
             "on a jumpy one it is an ordinary Tuesday."})
    else
        local _, why = AMS.Analysis:Baseline(m)
        setLine(ui, "baseline",  why or "no baseline yet", C.textDim)
        setLine(ui, "deviation", "-", C.textDim)
        setLine(ui, "recovery",  "-", C.textDim)
    end

    setLine(ui, "supply",    ("%d in %d auction%s (%d yours)")
        :format(r.totalSupply, r.totalAuctions, r.totalAuctions == 1 and "" or "s", r.mySupply))
    setLine(ui, "under",     ("%d units%s"):format(r.underTargetUnits,
        r.skippedUnits > 0 and (", %d too dear"):format(r.skippedUnits) or ""))

    if (r.maxStack or 0) > 0 and r.bigUnits > 0 then
        setLine(ui, "bigstacks", ("%d units, %s of profit"):format(r.bigUnits, U:MoneyShort(r.bigForegone)), C.info)
        Skin:AddTooltip(ui.lines.bigstacks, "Skipped as too big",
            {("%d units are priced under your ceiling but sit in stacks larger than %d, so the queue leaves them.")
                :format(r.bigUnits, r.maxStack),
             ("Taking them would cost %s and return about %s of profit - the same margin per unit as the singles.")
                :format(U:Money(r.bigCost, true), U:Money(r.bigForegone, true)),
             "Raise MAX BUY STACK to include them."})
    elseif (r.maxStack or 0) > 0 then
        setLine(ui, "bigstacks", ("none over %d"):format(r.maxStack), C.textDim)
    else
        setLine(ui, "bigstacks", "buying any size", C.textDim)
    end
    setLine(ui, "clear",     r.buyUnits > 0 and U:Money(r.buyCost) or "nothing to clear",
                             r.buyUnits > 0 and C.text or C.good)
    setLine(ui, "avgcost",   r.buyUnits > 0 and U:Money(r.buyAvg) or "-")
    if r.biggestWall then
        setLine(ui, "wall", ("%d @ %s"):format(r.biggestWall.units, U:MoneyShort(r.biggestWall.unit)),
            r.wallIsSignificant and C.warn or C.text)
    else
        setLine(ui, "wall", "none")
    end

    setLine(ui, "resale",  r.buyUnits > 0 and U:Money(r.net) or "-")
    setLine(ui, "profit",  r.buyUnits > 0 and U:Money(r.profit) or "-",
                           r.profit > 0 and C.good or C.bad)
    setLine(ui, "roi",     r.buyUnits > 0 and ("%.1f%%"):format(r.roi * 100) or "-")
    setLine(ui, "perday",  r.dailyProfit and (U:Money(r.dailyProfit).."  ("..U:Percent(r.dailyReturn or 0)..")")
                           or "needs sales history", r.dailyProfit and C.good or C.textDim)

    local h = r.holdings
    setLine(ui, "stock",    ("%d  (%d / %d / %d)"):format(h.total, h.bags, h.bank, h.listed))
    setLine(ui, "invested", U:Money(r.invested))
    setLine(ui, "velocity", r.velocity > 0 and ("%.1f/day (%s)"):format(r.velocity, r.velocityConf)
                            or "no sales recorded", r.velocity > 0 and C.text or C.textDim)
    setLine(ui, "days",     r.daysToSell and ("%.1f days"):format(r.daysToSell) or "-",
                            (r.daysToSell or 0) > 14 and C.warn or C.text)
    setLine(ui, "refill",   r.refillRate and ("%.1f units/hr"):format(r.refillRate)
                            or "needs repeat scans", r.refillRate and C.text or C.textDim)

    -- ---------- crafting, both directions ----------
    -- Can this item be made cheaper than it sells for, and is it worth more
    -- converted than raw? Only ever from recipes read out of your own
    -- profession windows or yields learned by watching you convert.
    local recipe = AMS.Craft:EvaluateRecipe(m.id)
    if recipe and recipe.cost then
        setLine(ui, "craftcost", U:Money(recipe.cost).."  in reagents")
        if r.lowest then
            local edge = r.lowest - recipe.cost
            setLine(ui, "craftedge",
                edge > 0 and ("%s cheaper to craft"):format(U:MoneyShort(edge))
                          or ("%s cheaper to buy"):format(U:MoneyShort(-edge)),
                edge > 0 and C.good or C.warn)
        else
            setLine(ui, "craftedge", "scan to compare", C.textDim)
        end
        Skin:AddTooltip(ui.lines.craftcost, "Cost to craft",
            {("%s reagents, priced at the cheapest ask last seen for each."):format(
                recipe.recipe.profession or "?"),
             "Read straight out of your own profession window - no guesswork, and only",
             "recipes somebody on this realm actually knows.",
             " ",
             "The Craft tab shows the full reagent breakdown."})
    else
        local why = AMS.Craft:GetRecipe(m.id) and "reagents not priced yet" or "no recipe known"
        setLine(ui, "craftcost", why, C.textDim)
        setLine(ui, "craftedge", "-", C.textDim)
    end

    local conv = AMS.Craft:Evaluate(m.id)
    if conv and conv.value and conv.value > 0 then
        local per = conv.cost
            and ("%s per op, costs %s"):format(U:MoneyShort(conv.value), U:MoneyShort(conv.cost))
            or  ("%s per op"):format(U:MoneyShort(conv.value))
        setLine(ui, "converts", per, (conv.profit or 0) > 0 and C.good or C.warn)
        Skin:AddTooltip(ui.lines.converts, "Converting this",
            {("%s %.1f of these at a time, learned over %d operation%s."):format(
                conv.rec.method or "Converting", conv.inputPer, conv.ops,
                conv.ops == 1 and "" or "s"),
             conv.profit and ("Worth %s more converted than sold raw."):format(U:Money(conv.profit, true))
                          or "Scan the outputs to value it.",
             "The Craft tab shows what comes out."})
    else
        setLine(ui, "converts", "not a known conversion", C.textDim)
    end

    local healthColor = C.good
    if r.health < 40 then healthColor = C.bad elseif r.health < 70 then healthColor = C.warn end
    ui.health:SetProgress(r.health / 100, healthColor, ("MARKET HEALTH  %d"):format(r.health))
    Skin:AddTooltip(ui.health, "Market health",
        {("Control %.0f/40 - how little competitor supply sits under your target."):format(r.healthParts.control),
         ("Margin %.0f/25 - headroom between the cheapest competitor and your break-even."):format(r.healthParts.margin),
         ("Velocity %.0f/25 - how fast the stock you would hold actually clears."):format(r.healthParts.velocity),
         ("Exposure %.0f/10 - how much of your cap this would consume."):format(r.healthParts.exposure)})

    if r.fromSnapshot then
        -- The numbers above are real but old. Saying "scan the market" while
        -- showing figures would invite reading them as current.
        local s = r.fromSnapshot
        ui.verdict:Set("STORED NUMBERS - " .. U:Ago(s.t):upper(),
            ("These are from the last scan, not live. Then: %s lowest, %d units under target costing %s. Scan to see where it stands now."):format(
                (s.min or 0) > 0 and U:Money(s.min, true) or "nothing listed",
                s.underUnits or 0, U:Money(s.underCost or 0, true)),
            C.info)
    else
        ui.verdict:Set(r.verdict.title, r.verdict.detail, r.verdict.color)
    end

    ui.list:SetData(self.entries or {})
    if not self.entries then
        -- no live rows to list; the summary above still has the stored figures
        ui.listHdr.cells[1]:SetText(r.fromSnapshot and "EACH  (scan to list auctions)" or "EACH")
    else
        ui.listHdr.cells[1]:SetText(L.buyCeiling > 0 and ("EACH <= "..U:MoneyShort(L.buyCeiling)) or "EACH")
    end

    self:RefreshBuyBar()
end

-- =============================================================================
-- Slash
-- =============================================================================

function M:OnSlash(arg)
    if arg and arg ~= "" then
        self:OpenItemByName(arg)
    end
    AMS.UI:Show("market")
end
