-- Auction Master Suite -- Config
-- SavedVariables defaults + the Settings tab.

local AMS = AuctionMasterSuite
local Config = {}
AMS.Config = Config

Config.DEFAULTS = {
    debug   = false,
    minimap = { hide = false, angle = 215 },

    ui = {
        locked      = false,
        openOnLogin = false,
        openAtAH    = true,   -- pop the window when the auction house opens
        closeAtAH   = true,   -- and hide it again when the AH closes
    },
    style = { alpha = 1.0 },

    market = {
        ahCut         = 5,    -- % the auction house keeps on a buyout sale
        minMargin     = 20,   -- % margin you require over your buy price
        tolerance     = 5,    -- % under target that you leave alone (not worth clearing)
        defaultStack  = 1,    -- the single-unit strategy, by default
        defaultDuration = 3,  -- 1 = 12h, 2 = 24h, 3 = 48h
        ignoreBidOnly = true, -- auctions with no buyout cannot be cleared

        -- Stack-size strategy. Buying a 20-stack and reposting it as singles
        -- earns exactly the same margin per unit as buying twenty singles, so
        -- the only real difference is how much gold one click ties up and how
        -- long the stock takes to liquidate. These let you say so explicitly.
        buyMaxStack   = 0,          -- skip auctions bigger than this (0 = any size)
        buyOrder      = "cheapest", -- "cheapest" | "smallest"
        bigStacksCompete = true,    -- do oversized stacks count as competition?
    },

    scan = {
        pageDelay      = 0.5, -- seconds between auction queries
        maxPages       = 25,
        autoScanOnOpen = false,
    },

    -- Note: the client only honours PlaceAuctionBid from inside a real mouse
    -- click, so there is deliberately no "buy unattended" option here. The
    -- addon prepares batches; you click to buy them.
    buyer = {
        stepDelay      = 0.3,      -- seconds between auto-prepare attempts
        batchSize      = 10,       -- auctions bought per click (0 = a full page)
        settleAfterBuy = 2,        -- seconds to let the AH catch up after buying
        confirmAbove   = 5000000,  -- ask before any single purchase over 500g
    },

    poster = {
        postDelay = 0.4,          -- seconds between StartAuction calls
        minBidEqualsBuyout = true,

        -- Undercutting. Flat beats percent in practice: a percentage of a high
        -- unit price opens a gap far bigger than it needs to be, and the buyer
        -- only cares that you are cheapest, not by how much.
        undercutUsePct = false,   -- false = flat copper, true = percentage
        undercutFlat   = 1,       -- copper below the price you are undercutting
        undercutPct    = 1,       -- percent below, when using percentage
        neverBelowCost = true,    -- refuse to undercut into a loss
    },

    history = {
        maxScans     = 250,       -- snapshots kept per item
        refillWindow = 86400,     -- seconds of scan history used for refill rate
    },

    -- Spotting an item that is temporarily far below its own normal price.
    -- Measured in standard deviations rather than percent, because a 30% drop
    -- means nothing without knowing how jumpy the item usually is.
    dislocation = {
        window  = 21,    -- days of history the baseline is built from
        minDays = 4,     -- days of data before it will say anything at all
        zAlert  = -1.5,  -- sigma below baseline that counts as a dislocation
        alert   = true,  -- announce in chat when a scan turns one up
    },
}

local function deepMerge(target, defaults)
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            if type(target[k]) ~= "table" then target[k] = {} end
            deepMerge(target[k], v)
        elseif target[k] == nil then
            target[k] = v
        end
    end
end

function Config:ApplyDefaults()
    deepMerge(AMS.db, self.DEFAULTS)

    -- Buying used to be one auction per round trip, so the step delay was slow
    -- on purpose. Page-sweep buying made that pointless; nudge anyone still
    -- carrying the old default off it, once.
    if not AMS.db._fastBuyMigrated then
        if AMS.db.buyer.stepDelay == 1.0 then AMS.db.buyer.stepDelay = 0.3 end
        AMS.db._fastBuyMigrated = true
    end
end

function Config:Get(path)
    local node = AMS.db
    for seg in tostring(path):gmatch("[^.]+") do
        if type(node) ~= "table" then return nil end
        node = node[seg]
    end
    return node
end

function Config:Set(path, value)
    local node = AMS.db
    local segs = {}
    for seg in tostring(path):gmatch("[^.]+") do segs[#segs+1] = seg end
    for i = 1, #segs - 1 do
        if type(node[segs[i]]) ~= "table" then node[segs[i]] = {} end
        node = node[segs[i]]
    end
    node[segs[#segs]] = value
end

-- Convenience: the settings the maths layer asks for constantly.
function Config:Cut()       return (self:Get("market.ahCut") or 5) / 100 end
function Config:MinMargin() return (self:Get("market.minMargin") or 20) / 100 end
function Config:Tolerance() return (self:Get("market.tolerance") or 5) / 100 end

-- ---------- Settings tab ----------
function Config:BuildPanel(parent)
    local Skin = AMS.Skin
    local C = Skin.COLOR

    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()

    local header = Skin:Header(panel, "Settings")
    header:SetPoint("TOPLEFT", 8, -8)
    header:SetPoint("TOPRIGHT", -8, -8)
    header:SetSub("Auction Master Suite v"..AMS.VERSION)

    local intro = Skin:Label(panel,
        "Defaults for new markets. Each watched item keeps its own target price, margin and exposure cap - "..
        "change those on the Market tab.", 11, false, C.textDim)
    intro:SetPoint("TOPLEFT",  header, "BOTTOMLEFT",  4, -8)
    intro:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", -4, -8)
    intro:SetHeight(30)
    intro:SetJustifyV("TOP")
    intro:SetWordWrap(true)

    -- There are more settings than fit on a screen, so the body scrolls. The
    -- header and the issue link stay put above it.
    local scroll = Skin:ScrollFrame(panel)
    scroll:SetPoint("TOPLEFT",     intro, "BOTTOMLEFT",  -4, -8)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -8, 8)
    local body = scroll.content

    -- Second column sits at the halfway mark, with a floor so a narrow window
    -- degrades into something still readable rather than overlapping.
    local bodyW = panel:GetWidth()
    if not bodyW or bodyW <= 0 then bodyW = 836 end
    local col1 = { x = 12, y = -8 }
    local col2 = { x = math.max(330, math.floor(bodyW / 2) - 10), y = -8 }
    local refreshers = {}

    local function addSection(col, text)
        col.y = col.y - 8
        local fs = body:CreateFontString(nil, "OVERLAY")
        Skin:Font(fs, 13, true)
        fs:SetTextColor(unpack(C.accent))
        fs:SetPoint("TOPLEFT", col.x - 4, col.y)
        fs:SetText(text)
        col.y = col.y - 20
    end

    local function addCheck(col, label, path, tooltip)
        local cb = Skin:CheckBox(body, label)
        cb:SetPoint("TOPLEFT", col.x, col.y)
        cb:SetChecked(Config:Get(path))
        cb.OnValueChanged = function(_, v) Config:Set(path, v) end
        if tooltip then Skin:AttachTooltip(cb.box, label, {tooltip}) end
        refreshers[#refreshers+1] = function() cb:SetChecked(Config:Get(path)) end
        col.y = col.y - 22
        return cb
    end

    local function addNumber(col, label, path, tooltip, w)
        local fs = body:CreateFontString(nil, "OVERLAY")
        Skin:Font(fs, 12, false)
        fs:SetTextColor(unpack(C.text))
        fs:SetPoint("TOPLEFT", col.x, col.y - 4)
        fs:SetWidth(210); fs:SetJustifyH("LEFT")
        fs:SetText(label)

        local e = Skin:EditBox(body, w or 80, 20)
        e:SetPoint("TOPLEFT", col.x + 214, col.y)
        e:SetText(tostring(Config:Get(path) or 0))
        e:SetScript("OnEditFocusLost", function(s)
            local v = tonumber(s:GetText()) or 0
            Config:Set(path, v)
            s:SetText(tostring(v))
            s:SetBackdropBorderColor(unpack(C.border))
        end)
        if tooltip then Skin:AddTooltip(e, label, {tooltip}) end
        refreshers[#refreshers+1] = function()
            if not e:HasFocus() then e:SetText(tostring(Config:Get(path) or 0)) end
        end
        col.y = col.y - 24
        return e
    end

    local function addMoney(col, label, path, tooltip)
        local fs = body:CreateFontString(nil, "OVERLAY")
        Skin:Font(fs, 12, false)
        fs:SetTextColor(unpack(C.text))
        fs:SetPoint("TOPLEFT", col.x, col.y - 4)
        fs:SetWidth(210); fs:SetJustifyH("LEFT")
        fs:SetText(label)

        local e = Skin:MoneyInput(body, 150, 20)
        e:SetPoint("TOPLEFT", col.x + 214, col.y)
        e:SetMoney(Config:Get(path) or 0)
        e.OnMoneyChanged = function(_, v) Config:Set(path, v) end
        if tooltip then Skin:AddTooltip(e, label, {tooltip}) end
        refreshers[#refreshers+1] = function()
            if not e:HasFocus() then e:SetMoney(Config:Get(path) or 0) end
        end
        col.y = col.y - 24
        return e
    end

    -- ===== column 1 =====
    addSection(col1, "General")
    addCheck(col1, "Open window on login / reload", "ui.openOnLogin")
    addCheck(col1, "Open with the auction house", "ui.openAtAH",
        "Show the Auction Master window automatically when you talk to an auctioneer.")
    addCheck(col1, "Close with the auction house", "ui.closeAtAH")
    addCheck(col1, "Enable debug logging", "debug", "Print verbose scan/buy/post messages to chat.")
    local hideMm = addCheck(col1, "Hide minimap button", "minimap.hide")
    local hideMmOrig = hideMm.OnValueChanged
    hideMm.OnValueChanged = function(s, v)
        hideMmOrig(s, v)
        if AMS.MinimapButton then AMS.MinimapButton:UpdateShown() end
    end

    addSection(col1, "Style")
    do
        local sLbl = body:CreateFontString(nil, "OVERLAY")
        Skin:Font(sLbl, 12, false)
        sLbl:SetTextColor(unpack(C.text))
        sLbl:SetPoint("TOPLEFT", col1.x, col1.y - 2)
        local sl = Skin:Slider(body, 140, 0.3, 1.0, 0.05)
        sl:SetPoint("TOPLEFT", col1.x + 214, col1.y - 2)

        local function labelFor(v)
            sLbl:SetText(("Window opacity: %d%%"):format(math.floor(v * 100 + 0.5)))
        end
        sl:SetValue(Config:Get("style.alpha") or 1)
        labelFor(Config:Get("style.alpha") or 1)
        sl:SetScript("OnValueChanged", function(s)
            local v = math.floor(s:GetValue() * 20 + 0.5) / 20
            Config:Set("style.alpha", v)
            labelFor(v)
            Skin:ApplyWindowAlpha()
        end)
        refreshers[#refreshers+1] = function()
            local v = Config:Get("style.alpha") or 1
            sl:SetValue(v); labelFor(v)
        end
        col1.y = col1.y - 26
    end

    addSection(col1, "Scanning")
    addNumber(col1, "Delay between pages (sec)", "scan.pageDelay",
        "The client throttles auction queries. 0.5 is safe; lower risks 'you can't do that yet' spam.")
    addNumber(col1, "Max pages per scan", "scan.maxPages",
        "Safety stop. A single commodity rarely fills more than a couple of pages.")
    addCheck(col1, "Scan current market when AH opens", "scan.autoScanOnOpen")

    -- ===== column 2 =====
    addSection(col2, "Market defaults")
    addNumber(col2, "Auction house cut (%)", "market.ahCut",
        "Taken off every buyout. 5% on your own faction's AH. This is why buying at 4.9g to sell at 5g loses money.")
    addNumber(col2, "Required margin (%)", "market.minMargin",
        "Your buy ceiling is set so that reselling at target leaves at least this margin over what you paid.")
    addNumber(col2, "Leave-alone tolerance (%)", "market.tolerance",
        "Competitors within this much of your target are already at your price - clearing them wastes gold.")
    addNumber(col2, "Default stack size", "market.defaultStack",
        "1 is the single-unit strategy: buyers who need three will happily pay per-unit price for three singles.")
    addNumber(col2, "Default duration (1=12h 2=24h 3=48h)", "market.defaultDuration",
        "Longer durations cost more deposit but relist less often. The Post tab shows the deposit drag.")
    addCheck(col2, "Ignore bid-only auctions", "market.ignoreBidOnly",
        "Auctions without a buyout cannot be cleared instantly, so they are excluded from the cost-to-clear.")
    addNumber(col2, "Default max stack to buy", "market.buyMaxStack",
        "Skip auctions holding more units than this. 0 buys any size. "..
        "Note the margin per unit is identical either way - a big stack just ties up more gold in one click "..
        "and takes longer to liquidate as singles.")
    addCheck(col2, "Big stacks count as competition", "market.bigStacksCompete",
        "On: every auction under your target counts toward supply and cost-to-clear. "..
        "Off: auctions above your max buy stack are left out of both, on the theory that a 20-stack is not "..
        "competing for the buyer who wants three. They are still reported as a wall, because anyone can buy "..
        "one and relist it as singles against you.")

    addSection(col2, "Buying")
    addNumber(col2, "Auctions per click", "buyer.batchSize",
        "Auction indices stay valid for a whole loaded page, so one click can buy this many at once instead of one. "..
        "This is what makes clearing a market quick. 0 buys as much of the page as it can.")
    addNumber(col2, "Auto-prepare delay (sec)", "buyer.stepDelay",
        "Pause between attempts to line up the next batch. The auction house has its own query throttle, "..
        "so very low values do not help.")
    addNumber(col2, "Settle after buying (sec)", "buyer.settleAfterBuy",
        "The auction house will answer the next query with the pre-purchase page if you ask too soon. 2 is safe.")
    addMoney(col2, "Confirm purchases above", "buyer.confirmAbove",
        "Any single auction costing more than this pops a confirmation first.")

    addSection(col2, "Posting")
    addNumber(col2, "Delay between posts (sec)", "poster.postDelay",
        "Posting 200 singles back-to-back will get you disconnected. 0.4 is comfortable.")
    addCheck(col2, "Minimum bid = buyout", "poster.minBidEqualsBuyout",
        "Stops people winning your auction by bid for less than your buyout.")
    addNumber(col2, "Undercut by (copper)", "poster.undercutFlat",
        "How far under the price you are undercutting to post. 1 copper is enough - the buyer only "..
        "cares that you are cheapest, not by how much, and a bigger gap is gold you gave away.")
    addNumber(col2, "Undercut by (%)", "poster.undercutPct",
        "Used instead of the copper amount when the mode below is set to percent.")
    addCheck(col2, "Undercut by percent instead", "poster.undercutUsePct",
        "Off uses the flat copper amount, which is almost always what you want. "..
        "A percentage of a high unit price opens a far wider gap than it needs to.")
    addCheck(col2, "Never undercut into a loss", "poster.neverBelowCost",
        "Refuses to set a post price below what your stock cost you plus the auction house cut. "..
        "Turn this off only if you are deliberately dumping.")

    addSection(col2, "History")
    addNumber(col2, "Scan snapshots kept per item", "history.maxScans")

    addSection(col2, "Dislocation alerts")
    addNumber(col2, "Baseline window (days)", "dislocation.window",
        "How far back the 'normal' price is measured from. The baseline is a median of daily medians, "..
        "so a dump cannot drag it down and hide itself.")
    addNumber(col2, "Sigma to alert at", "dislocation.zAlert",
        "How far below normal counts as a dislocation, in standard deviations. -1.5 is a real drop; "..
        "-1 will fire on ordinary wobbles. Negative numbers only.")
    addNumber(col2, "Days of data required", "dislocation.minDays",
        "It says nothing until it has this many days of scans - a baseline from two scans is not a baseline.")
    addCheck(col2, "Announce dislocations in chat", "dislocation.alert",
        "Prints a line when a scan finds an item well below its normal price. You will not be looking "..
        "at the right tab when one turns up.")

    -- Whichever column ran longer decides how far this scrolls.
    scroll:SetContentHeight(math.max(-col1.y, -col2.y) + 16)

    panel:SetScript("OnShow", function()
        for _, fn in ipairs(refreshers) do fn() end
        scroll:UpdateScroll()
    end)

    return panel
end

AMS:RegisterModule("settings", {
    title = "Settings",
    order = 99,
    BuildUI = function(self, parent) return Config:BuildPanel(parent) end,
})
