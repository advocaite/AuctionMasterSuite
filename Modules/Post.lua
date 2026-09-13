-- Auction Master Suite -- Post tab
-- Batch posting, and the record of which stack size actually sells.

local AMS = AuctionMasterSuite
local M = AMS:RegisterModule("post", { title = "Post", order = 20 })

local U, Skin, C

local DURATIONS = {
    { text = "12 hours", value = 1 },
    { text = "24 hours", value = 2 },
    { text = "48 hours", value = 3 },
}

function M:OnInit()
    U, Skin = AMS.Util, AMS.Skin
    C = Skin.COLOR

    AMS:Subscribe("CURRENT_CHANGED", function() M:Refresh() end)
    AMS:Subscribe("MARKETS_CHANGED", function() M:Refresh() end)
    AMS:Subscribe("LEDGER_CHANGED",  function() M:Refresh() end)
    AMS:Subscribe("BAGS_CHANGED",    function() M:Refresh() end)
    AMS:Subscribe("AH_STATE",        function() M:Refresh() end)
    AMS:Subscribe("POST_STATE",      function() M:Refresh() end)
    AMS:Subscribe("POST_PROGRESS",   function(done, total)
        if M._ui and M._ui.progress then
            M._ui.progress:SetProgress(total > 0 and done/total or 0, C.accent,
                ("posting %d/%d"):format(done, total))
        end
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
    local header = Skin:Header(panel, "Post")
    header:SetPoint("TOPLEFT", 8, -8); header:SetPoint("TOPRIGHT", -8, -8)
    header:SetHeight(36)
    ui.header = header

    -- Pick what to post from here rather than having to go to the Market tab
    -- first. It sets the shared current item, so the price ladder below and the
    -- Market tab stay describing the same thing.
    local slot = Skin:ItemSlot(header, 28)
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
        M:Refresh(true)
        return true
    end
    slot:SetScript("OnReceiveDrag", takeCursorItem)
    slot:SetScript("OnClick", takeCursorItem)
    Skin:AddTooltip(slot, "What to post",
        {"Drag an item here to post it, instead of picking it on the Market tab first.",
         "It becomes the shared current item, so the price ladder and the Market tab follow."})

    header.text:ClearAllPoints()
    header.text:SetPoint("LEFT", slot, "RIGHT", 8, 0)

    -- ---------- controls ----------
    local strip = Skin:Panel(panel)
    strip:SetPoint("TOPLEFT",  header, "BOTTOMLEFT",  0, -6)
    strip:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -6)
    strip:SetHeight(46)
    ui.strip = strip

    local x = 10
    local function field(label, width, builder, tip)
        local l = Skin:Label(strip, label, 10, false, C.textDim)
        l:SetPoint("TOPLEFT", x, -6)
        local w = builder(strip, width)
        w:SetPoint("TOPLEFT", x, -20)
        if tip then Skin:AddTooltip(w, label, tip) end
        x = x + width + 12
        return w
    end

    ui.priceBox = field("PRICE PER UNIT", 150, function(p, w) return Skin:MoneyInput(p, w, 20) end,
        {"What each unit sells for. Defaults to the market target."})
    ui.priceBox.OnMoneyChanged = function() M:Refresh() end

    ui.stackBox = field("STACK", 55, function(p, w) return Skin:NumberBox(p, w, 20) end,
        {"Units per auction.",
         "1 puts a single unit in front of the buyer who needs one - they compare the total, not the unit price."})
    ui.stackBox.OnNumberChanged = function(_, v)
        local m = AMS:CurrentMarket()
        if m then m.stack = math.max(1, v) end
        M:Refresh()
    end

    ui.countBox = field("AUCTIONS", 65, function(p, w) return Skin:NumberBox(p, w, 20) end,
        {"How many separate auctions to create."})
    ui.countBox.OnNumberChanged = function() M:Refresh() end

    local durLbl = Skin:Label(strip, "DURATION", 10, false, C.textDim)
    durLbl:SetPoint("TOPLEFT", x, -6)
    local dur = Skin:Dropdown(strip, 100, 20)
    dur:SetPoint("TOPLEFT", x, -20)
    dur:SetItems(DURATIONS)
    dur.OnValueChanged = function(_, v)
        local m = AMS:CurrentMarket()
        if m then m.duration = v end
        M:Refresh()
    end
    ui.durDrop = dur
    x = x + 112

    local ucBtn = Skin:Button(strip, "Undercut lowest", 116, 20)
    ucBtn:SetPoint("TOPLEFT", x, -20)
    ucBtn:SetScript("OnClick", function() M:UndercutLowest() end)
    Skin:AddTooltip(ucBtn, "Undercut the cheapest listing",
        {"Sets your price just under the cheapest auction that is not yours.",
         "Your own listings are ignored, so this cannot make you undercut yourself.",
         " ",
         "Worth thinking about before you use it: if the cheapest is already at the price",
         "you want to hold, matching it is usually better than going lower - undercutting",
         "your own target is how a price war starts."})
    x = x + 128
    ui.ucBtn = ucBtn

    local cancelAllBtn = Skin:Button(strip, "Cancel all mine", 116, 20)
    cancelAllBtn:SetPoint("TOPLEFT", x, -20)
    cancelAllBtn.textColor = C.bad
    cancelAllBtn.text:SetTextColor(unpack(C.bad))
    cancelAllBtn:SetScript("OnClick", function() M:CancelAll() end)
    Skin:AddTooltip(cancelAllBtn, "Cancel all your auctions of this item",
        {"Pulls back everything you have listed for the current item, at any price.",
         " ",
         "The deposits are forfeited, so this is for repricing a book that has gone stale",
         "rather than something to do casually.",
         " ",
         "Auctions that have already sold are left alone - that gold is on its way. Ones with",
         "a bid on them are skipped too, because cancelling those costs an extra fee."})
    x = x + 128
    ui.cancelAllBtn = cancelAllBtn

    local fillBtn = Skin:Button(strip, "Fill max", 70, 20)
    fillBtn:SetPoint("TOPLEFT", x, -20)
    fillBtn:SetScript("OnClick", function()
        local m = AMS:CurrentMarket(); if not m then return end
        local stack = math.max(1, ui.stackBox:GetNumber())
        ui.countBox:SetNumber(math.floor(AMS.Inventory:BagCount(m.id) / stack))
        M:Refresh()
    end)
    Skin:AddTooltip(fillBtn, "Fill max", {"Sets the auction count to everything you are carrying."})

    -- ---------- action bar ----------
    local bar = Skin:Panel(panel)
    bar:SetPoint("BOTTOMLEFT", 8, 8); bar:SetPoint("BOTTOMRIGHT", -8, 8)
    bar:SetHeight(40)

    local postBtn = Skin:BigButton(bar, "POST", 240, 28, C.accent)
    postBtn:SetPoint("LEFT", 8, 0)
    postBtn:SetScript("OnClick", function() M:DoPost() end)
    ui.postBtn = postBtn

    local abortBtn = Skin:Button(bar, "Abort", 70, 28)
    abortBtn:SetPoint("LEFT", postBtn, "RIGHT", 6, 0)
    abortBtn:SetScript("OnClick", function() AMS.Poster:Abort("you stopped it") end)
    ui.abortBtn = abortBtn

    local prog = Skin:Bar(bar, 200, 16)
    prog:SetPoint("LEFT", abortBtn, "RIGHT", 12, 0)
    prog:SetPoint("RIGHT", -8, 0)
    prog:EnableMouse(true)
    Skin:AddTooltip(prog, "Posting progress",
        {"Auctions created so far out of the number requested.",
         "With multi-sell the server creates them all from one call and reports back as it goes,",
         "so this fills in steadily rather than ticking one at a time."})
    ui.progress = prog

    -- ---------- note ----------
    local note = Skin:Panel(panel)
    note:SetPoint("BOTTOMLEFT",  bar, "TOPLEFT",  0, 6)
    note:SetPoint("BOTTOMRIGHT", bar, "TOPRIGHT", 0, 6)
    note:SetHeight(46)

    local noteText = Skin:Label(note, "", 11, false, C.textDim)
    noteText:SetPoint("TOPLEFT", 10, -8)
    noteText:SetPoint("BOTTOMRIGHT", -10, 6)
    noteText:SetJustifyV("TOP")
    noteText:SetWordWrap(true)
    ui.note = noteText

    -- ---------- left: the plan ----------
    local planScroll = Skin:ScrollFrame(panel)
    planScroll:SetPoint("TOPLEFT",    strip, "BOTTOMLEFT", 0, -6)
    planScroll:SetPoint("BOTTOMLEFT", note,  "TOPLEFT",    0, 6)
    planScroll:SetWidth(300)
    ui.planScroll = planScroll

    local plan = planScroll.content
    ui.plan = plan

    ui.lines = {}
    local y = -10
    local function statLine(key, label)
        local sl = Skin:StatLine(plan, label, 12)
        sl:SetPoint("TOPLEFT", 8, y)
        sl:SetPoint("RIGHT", -8, 0)
        ui.lines[key] = sl
        y = y - 19
        return sl
    end
    local function gap(title)
        y = y - 6
        local t = Skin:Label(plan, title, 10, true, C.accentDim)
        t:SetPoint("TOPLEFT", 8, y)
        y = y - 15
    end

    gap("THIS POSTING RUN")
    statLine("stock",    "In your bags")
    statLine("auctions", "Auctions")
    statLine("units",    "Units posted")
    statLine("each",     "Per auction")
    statLine("gross",    "Gross if all sell")
    statLine("net",      "Net after AH cut")
    statLine("deposit",  "Deposit up front")
    statLine("time",     "Estimated time")

    gap("AGAINST THE MARKET")
    statLine("target",   "Market target")
    statLine("breakeven","Break-even buy")
    statLine("listed",   "Already listed")
    statLine("singles",  "Single-unit auctions")
    statLine("cover",    "Days of stock")

    planScroll:SetContentHeight(-y + 8)

    -- ---------- right: what sells ----------
    local PERF_COLS = {
        { text = "STACK",  width = 46, justify = "RIGHT" },
        { text = "POSTED", width = 52, justify = "RIGHT" },
        { text = "SOLD",   width = 44, justify = "RIGHT" },
        { text = "EXPIRED",width = 56, justify = "RIGHT" },
        { text = "SELL-THROUGH", width = 86, justify = "RIGHT" },
        { text = "AVG TIME", width = 66, justify = "RIGHT" },
    }

    -- ---------- the price ladder ----------
    -- Every price on the board with how much sits at each, so you pick a price
    -- while looking at the shape of the competition rather than at one number.
    local LADDER_COLS = {
        { text = "PRICE",    width = 84, min = 62, justify = "RIGHT" },
        { text = "AUCTIONS", width = 66, min = 50, justify = "RIGHT" },
        { text = "UNITS",    width = 58, min = 44, justify = "RIGHT" },
        { text = "WHOSE",    width = 76, min = 56, justify = "LEFT"  },
        { text = "",         width = 96, min = 92, justify = "RIGHT" },
    }

    local ladderHdr = Skin:ListHeader(panel, LADDER_COLS)
    ladderHdr:SetPoint("TOPLEFT", planScroll, "TOPRIGHT", 6, 0)
    ladderHdr:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    ui.ladderHdr = ladderHdr

    local ladderCols
    local ladderList = Skin:ScrollList(panel, 19,
        function(p)
            local r = Skin:Row(p, ladderCols and ladderCols() or LADDER_COLS)
            local b = Skin:Button(r, "UC", 42, 15)
            Skin:Font(b.text, 10, true)
            b:ClearAllPoints()
            b:SetPoint("RIGHT", r.cells[#r.cells], "RIGHT", 0, 0)
            b:SetScript("OnClick", function()
                if r.rowData then M:UndercutTo(r.rowData.unit) end
            end)
            Skin:AddTooltip(b, "Undercut this price",
                {"Sets your posting price just under this one.",
                 "How far under is set by 'Undercut by' in Settings - one copper is plenty,",
                 "since the buyer only cares that you are cheapest.",
                 " ",
                 "Click the row itself instead to MATCH this price exactly."})
            r.ucBtn = b

            -- only appears on prices you are actually sitting at
            local cx = Skin:Button(r, "Cancel", 48, 15)
            Skin:Font(cx.text, 10, true)
            cx.textColor = C.bad
            cx.text:SetTextColor(unpack(C.bad))
            cx:ClearAllPoints()
            cx:SetPoint("RIGHT", b, "LEFT", -4, 0)
            cx:SetScript("OnClick", function()
                if r.rowData then M:CancelAtPrice(r.rowData.unit, r.rowData.mine) end
            end)
            Skin:AddTooltip(cx, "Cancel your auctions at this price",
                {"Pulls back every auction of yours sitting at this exact price.",
                 " ",
                 "Cancelling forfeits the deposit, so repricing has to earn that back before",
                 "it is worth doing. Auctions that have already sold are left alone, and ones",
                 "somebody has bid on are skipped because cancelling those costs an extra fee."})
            r.cancelBtn = cx
            return r
        end,
        function(row, d, idx, alt)
            row.rowData = d
            if not d then
                for i = 1, #LADDER_COLS do row:Set(i, "") end
                row.ucBtn:Hide()
                row.cancelBtn:Hide()
                row:SetScript("OnClick", nil)
                return
            end
            local whose, tone
            if d.mine > 0 and d.others > 0 then whose, tone = "you + others", C.warn
            elseif d.mine > 0 then whose, tone = "yours", C.accent
            else whose, tone = "others", C.text end

            row:Set(1, U:MoneyShort(d.unit), d.isLowestOther and C.good or tone)
            row:Set(2, tostring(d.auctions), tone)
            row:Set(3, tostring(d.units), tone)
            row:Set(4, whose, tone)
            row:Set(5, "")
            row:Tint(alt and C.bgRowAlt or C.bgRow)

            row.ucBtn:Show()
            if d.mine > 0 then row.cancelBtn:Show() else row.cancelBtn:Hide() end
            row:SetScript("OnClick", function() M:MatchTo(d.unit) end)
        end)
    ladderList:SetPoint("TOPLEFT", ladderHdr, "BOTTOMLEFT", 0, -2)
    ladderList:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    ladderList:SetHeight(150)
    ladderCols = Skin:AutoCols(ladderHdr, ladderList, LADDER_COLS)
    ui.ladderList = ladderList

    local perfHdr = Skin:ListHeader(panel, PERF_COLS)
    perfHdr:SetPoint("TOPLEFT", ladderList, "BOTTOMLEFT", 0, -8)
    perfHdr:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    ui.perfHdr = perfHdr

    local perfList = Skin:ScrollList(panel, 18,
        function(p) return Skin:Row(p, ui.perfCols and ui.perfCols() or PERF_COLS) end,
        function(row, d, idx, alt)
            if not d then for i = 1, #PERF_COLS do row:Set(i, "") end return end
            row:Set(1, tostring(d.stack))
            row:Set(2, tostring(d.posted))
            row:Set(3, tostring(d.sold), C.good)
            row:Set(4, tostring(d.expired), d.expired > 0 and C.bad or C.textDim)
            row:Set(5, d.sellThrough and U:Percent(d.sellThrough, 0) or "-",
                       d.sellThrough and (d.sellThrough > 0.8 and C.good or d.sellThrough < 0.4 and C.bad or C.warn))
            row:Set(6, d.avgTime and U:Duration(d.avgTime) or "-")
            row:Tint(alt and C.bgRowAlt or C.bgRow)
        end)
    perfList:SetPoint("TOPLEFT", perfHdr, "BOTTOMLEFT", 0, -2)
    perfList:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    perfList:SetHeight(110)
    ui.perfCols = Skin:AutoCols(perfHdr, perfList, PERF_COLS)
    ui.perfList = perfList

    -- ---------- advice ----------
    local advice = Skin:Panel(panel)
    advice:SetPoint("TOPLEFT", perfList, "BOTTOMLEFT", 0, -6)
    advice:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    advice:SetPoint("BOTTOM", note, "TOP", 0, 6)

    local adviceHdr = Skin:Label(advice, "STACK SIZE", 10, true, C.accentDim)
    adviceHdr:SetPoint("TOPLEFT", 10, -8)

    local adviceText = Skin:Label(advice, "", 11, false, C.text)
    adviceText:SetPoint("TOPLEFT", 10, -26)
    adviceText:SetPoint("BOTTOMRIGHT", -10, 8)
    adviceText:SetJustifyV("TOP")
    adviceText:SetWordWrap(true)
    ui.advice = adviceText

    panel:SetScript("OnShow", function() M:Refresh(true) end)
    self:Refresh(true)
    return panel
end

-- =============================================================================
-- Pricing actions
-- =============================================================================

-- Adopt a price exactly. Matching rather than undercutting is often the right
-- move: if you are already at the price you want to hold, going a copper lower
-- just starts the race downwards.
function M:MatchTo(unit)
    if not unit or unit <= 0 then return end
    local m = AMS:CurrentMarket()
    if not m then return end
    self._ui.priceBox:SetMoney(unit)
    m.postPrice = unit
    AMS:Print("posting price set to |cffffd070%s|r (matching).", AMS.Util:Money(unit, true))
    self:Refresh()
end

-- Sit just under a price. Refuses to go under what your stock cost unless you
-- have turned that guard off.
function M:UndercutTo(unit)
    if not unit or unit <= 0 then return end
    local m = AMS:CurrentMarket()
    if not m then return end

    local price, blocked = AMS.Analysis:UndercutPrice(unit, m)
    self._ui.priceBox:SetMoney(price)
    m.postPrice = price

    if blocked then
        AMS:Print("|cffff9040held at %s:|r %s.", AMS.Util:Money(price, true), blocked)
    else
        AMS:Print("posting price set to |cffffd070%s|r, undercutting %s.",
            AMS.Util:Money(price, true), AMS.Util:Money(unit, true))
    end
    self:Refresh()
end

-- Undercut whatever the cheapest competing listing is right now.
function M:UndercutLowest()
    local mk = AMS:GetModule("market")
    local ladder = AMS.Analysis:PriceLadder(mk and mk.entries)
    for _, r in ipairs(ladder) do
        if r.others > 0 then return self:UndercutTo(r.unit) end
    end
    AMS:Print("nothing to undercut - scan the item first, or nobody else is listing it.")
end

-- =============================================================================
-- Cancelling
-- =============================================================================
--
-- Wired straight to OnClick: like buying, the client only honours CancelAuction
-- from inside a real mouse click.

local function afterCancel(n, units)
    if n == 0 then
        AMS:Print("nothing cancelled.")
        return
    end
    local m = AMS:CurrentMarket()
    local dep = AMS.Canceller:DepositCost(m, units)
    AMS:Print("cancelled |cffffd070%d auction%s|r (%d units)%s.",
        n, n == 1 and "" or "s", units,
        dep and (", forfeiting about "..AMS.Util:Money(dep).." in deposits") or "")

    -- the owner list has shifted under us; read it again
    AMS.Util:After(1.0, function()
        local au = AMS:GetModule("auctions")
        if au then au:Rescan() end
    end)
end

function M:CancelAtPrice(unit, mineCount)
    local m = AMS:CurrentMarket()
    if not m then return end
    if not AMS:AtAuctionHouse() then AMS:Print("open the auction house first.") return end

    -- More than a couple is worth a second look: the deposits are gone either way.
    if (mineCount or 0) > 3 then
        StaticPopupDialogs["AMS_CANCEL_PRICE"] = {
            text = "%s",
            button1 = "Cancel them", button2 = "Keep them",
            OnAccept = function()
                afterCancel(AMS.Canceller:CancelAtPrice(m.name, unit))
            end,
            timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
        }
        StaticPopup_Show("AMS_CANCEL_PRICE",
            ("Cancel %d of your %s auctions at %s?\n\nThe deposits on them are forfeited."):format(
                mineCount, m.name or "?", AMS.Util:Money(unit, true)))
        return
    end
    afterCancel(AMS.Canceller:CancelAtPrice(m.name, unit))
end

function M:CancelAll()
    local m = AMS:CurrentMarket()
    if not m then AMS:Print("pick an item first.") return end
    if not AMS:AtAuctionHouse() then AMS:Print("open the auction house first.") return end

    local listed = AMS.Inventory:ListedCount(m.id)
    if listed == 0 then AMS:Print("you have nothing listed for %s.", m.name or "that item") return end

    StaticPopupDialogs["AMS_CANCEL_ALL"] = {
        text = "%s",
        button1 = "Cancel them", button2 = "Keep them",
        OnAccept = function()
            afterCancel(AMS.Canceller:CancelAllForItem(m.name))
        end,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }
    local dep = AMS.Canceller:DepositCost(m, listed)
    StaticPopup_Show("AMS_CANCEL_ALL",
        ("Cancel every %s auction you have listed?\n\n%d units come back and their deposits%s are forfeited.\n\nSold auctions are left alone, and any with bids on them are skipped."):format(
            m.name or "that item", listed,
            dep and (" - about "..AMS.Util:Money(dep, true).."") or ""))
end

-- =============================================================================
-- Posting
-- =============================================================================

function M:DoPost()
    local ui = self._ui
    local m = AMS:CurrentMarket()
    if not m then AMS:Print("pick an item on the Market tab first.") return end

    local price = ui.priceBox:GetMoney() or 0
    local stack = math.max(1, ui.stackBox:GetNumber())
    local count = ui.countBox:GetNumber()
    local dur   = ui.durDrop:GetValue() or m.duration or 3

    if price <= 0 then AMS:Print("set a price first.") return end

    -- Posting below your own break-even is almost always a slip of the keyboard.
    local L = AMS.Analysis:Levels(m)
    if m.target > 0 and price < L.breakEven * 0.9 then
        AMS:Print("|cffff9040warning:|r %s per unit is well below your break-even of %s.",
            U:Money(price, true), U:Money(L.breakEven, true))
    end

    AMS.Poster:Post(m, stack, price, count, dur)
end

-- =============================================================================
-- Refresh
-- =============================================================================

function M:Refresh(resetFields)
    local ui = self._ui
    if not ui or not ui.header then return end

    if ui.planScroll then ui.planScroll:UpdateScroll() end

    local m = AMS:CurrentMarket()
    local running = AMS.Poster:IsRunning()

    ui.slot:SetItem(m and m.link, m and m.texture)

    if not m then
        ui.header:SetText("Post")
        ui.header:SetSub("drag an item here, or pick one on the Market tab")
        for key, sl in pairs(ui.lines) do sl:SetValue("-", C.textDim) end
        ui.postBtn:SetText("NO ITEM")
        ui.postBtn:Disable()
        ui.perfList:SetData({})
        ui.ladderList:SetData({})
        ui.advice:SetText("Drag an item onto the slot above, or pick one on the Market tab.")
        ui.note:SetText("")
        return
    end

    ui.header:SetText(U:ColorItemName(m.name, m.quality))

    -- field defaults
    if resetFields or not ui.priceBox:HasFocus() then
        if resetFields or ui.priceBox:GetMoney() == 0 then
            ui.priceBox:SetMoney(m.postPrice or m.target or 0)
        end
    end

    -- the ladder, straight off the current scan
    local mk = AMS:GetModule("market")
    ui.ladderList:SetData(AMS.Analysis:PriceLadder(mk and mk.entries))
    ui.ladderHdr.cells[1]:SetText((mk and mk.entries) and "PRICE" or "PRICE (scan first)")
    if not ui.stackBox:HasFocus() then ui.stackBox:SetNumber(m.stack or 1) end
    -- silent: SetValue would otherwise fire OnValueChanged straight back into Refresh
    if resetFields or not ui.durDrop:GetValue() then ui.durDrop:SetValue(m.duration or 3, nil, true) end

    local price = ui.priceBox:GetMoney() or m.target or 0
    local stack = math.max(1, ui.stackBox:GetNumber())
    local bagCount = AMS.Inventory:BagCount(m.id)
    local maxAuctions = math.floor(bagCount / stack)

    if resetFields or ui.countBox:GetNumber() > maxAuctions then
        ui.countBox:SetNumber(maxAuctions)
    end
    local count = math.min(ui.countBox:GetNumber(), maxAuctions)

    local plan = AMS.Analysis:PostPlan(m, stack, price, count)
    local L    = AMS.Analysis:Levels(m)
    local held = AMS.Inventory:Holdings(m.id)

    local function set(key, text, color)
        local sl = ui.lines[key]
        if sl then sl:SetValue(text, color) end
    end

    set("stock",    ("%d units"):format(bagCount))
    set("auctions", tostring(plan.auctions))
    set("units",    tostring(plan.units))
    set("each",     ("%dx %s = %s"):format(stack, U:MoneyShort(price), U:MoneyShort(plan.perAuction)))
    set("gross",    U:Money(plan.gross))
    set("net",      U:Money(plan.netIfAllSell), C.good)
    set("deposit",  plan.depositKnown and U:Money(plan.deposit)
                    or "unmeasured - hit Deposit on the Market tab", plan.depositKnown and C.text or C.warn)
    set("time",     U:Duration(plan.estSeconds))

    set("target",   m.target > 0 and U:Money(m.target) or "not set")
    set("breakeven",L.breakEven > 0 and U:Money(L.breakEven) or "-", C.warn)
    set("listed",   ("%d units in %d auctions"):format(held.listed, held.auctions))

    local singlesListed = AMS.Inventory:ListedSingles(m.id)
    set("singles", ("%d posted"):format(singlesListed),
        singlesListed > 0 and C.accent or C.textDim)
    Skin:AddTooltip(ui.lines.singles, "Single-unit auctions",
        {("You currently have %d x1 auctions of this item posted."):format(singlesListed),
         "Counted from the last time your auctions were read - press Scan on the Market tab to refresh it."})

    local vel = AMS.DB:Velocity(m.id)
    if vel > 0 then
        set("cover", ("%.1f days"):format((held.total + plan.units) / vel))
    else
        set("cover", "no sales history")
    end

    -- action button
    ui.postBtn:SetEnabled(AMS:AtAuctionHouse() and plan.auctions > 0 and not running)
    if running then
        ui.postBtn:SetText("POSTING...")
    elseif not AMS:AtAuctionHouse() then
        ui.postBtn:SetText("AUCTION HOUSE CLOSED")
    elseif plan.auctions == 0 then
        ui.postBtn:SetText("NOTHING TO POST")
    else
        ui.postBtn:SetText(("POST %d x %dx @ %s"):format(plan.auctions, stack, U:MoneyShort(price)))
    end
    ui.abortBtn:SetEnabled(running)

    -- stack performance
    local perf, best = AMS.Analysis:StackAdvice(m)
    ui.perfList:SetData(perf or {})

    if best then
        ui.advice:SetText(("Your record says stacks of |cffffd070%d|r work best: %s sell-through%s. Posted %d, sold %d, expired %d.")
            :format(best.stack, U:Percent(best.sellThrough or 0, 0),
                    best.avgTime and (", average "..U:Duration(best.avgTime).." to sell") or "",
                    best.posted, best.sold, best.expired))
    elseif perf and #perf > 0 then
        ui.advice:SetText("Not enough closed auctions yet to say which stack size performs best. Keep posting - sell-through and time-to-sell fill in as mail arrives.")
    else
        ui.advice:SetText("Nothing posted through this addon yet. Once you post and the sale mail comes back, this table tells you which stack size actually moves.")
    end

    -- the two things everyone gets wrong about single-unit posting
    local depositNote =
        "The deposit is charged per |cffffd070item|r, not per auction: 200 singles cost exactly the same deposit as one stack of 200 - "..
        "and singles risk less, because only the unsold ones forfeit."
    if plan.multisell then
        ui.note:SetText(depositNote.." This server supports multi-sell, so the whole run posts in one go rather than one auction at a time.")
    else
        ui.note:SetText(depositNote.." This client posts one auction at a time, so a big run takes a while - leave the window open.")
    end
end

function M:OnSlash()
    AMS.UI:Show("post")
end
