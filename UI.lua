-- Auction Master Suite -- UI
-- Main window: title bar, vertical tab bar, content area. Hosts module panels.
-- Also owns "which market am I looking at", which every tab shares.

local AMS = AuctionMasterSuite
local UI = {}
AMS.UI = UI

local TAB_ORDER = { "market", "post", "auctions", "books", "insights", "craft", "history", "watchlist", "settings", "donate" }

-- =============================================================================
-- Current market (shared across tabs)
-- =============================================================================

function AMS:SetCurrentMarket(itemID)
    if self.currentID == itemID then return end
    self.currentID = itemID
    self:Fire("CURRENT_CHANGED", itemID)
end

function AMS:CurrentMarket()
    if not self.currentID then return nil end
    return self.DB:GetMarket(self.currentID)
end

-- =============================================================================
-- Window
-- =============================================================================

function UI:Build()
    if self.frame then return self.frame end
    local Skin = AMS.Skin
    local C = Skin.COLOR
    local U = AMS.Util

    local f = CreateFrame("Frame", "AuctionMasterSuiteFrame", UIParent)
    -- Wide enough that the Books panes both fit their columns at natural size;
    -- tables scale themselves down from here rather than spilling over. Capped
    -- to the screen so a large UI scale cannot push it off the edge.
    local maxW = math.max(700, math.floor(UIParent:GetWidth())  - 40)
    local maxH = math.max(480, math.floor(UIParent:GetHeight()) - 60)
    f:SetSize(math.min(1020, maxW), math.min(660, maxH))
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetMovable(true); f:EnableMouse(true)
    f:Hide()
    Skin:SetBackdrop(f, C.bgMain, C.borderHi)
    self.frame = Skin:ManagedWindow(f)

    -- Escape closes the window, the way every other panel in the game does.
    -- An edit box with keyboard focus swallows Escape first (its OnEscapePressed
    -- clears focus), so typing a price and pressing Escape backs out of the
    -- field rather than shutting the whole thing.
    local registered = false
    for _, name in ipairs(UISpecialFrames) do
        if name == "AuctionMasterSuiteFrame" then registered = true break end
    end
    if not registered then
        table.insert(UISpecialFrames, "AuctionMasterSuiteFrame")
    end

    -- ---------- title bar ----------
    local title = CreateFrame("Frame", nil, f)
    title:SetPoint("TOPLEFT", 0, 0); title:SetPoint("TOPRIGHT", 0, 0)
    title:SetHeight(32)
    Skin:SetBackdrop(title, C.bgHeader, C.border)
    title:EnableMouse(true)
    title:RegisterForDrag("LeftButton")
    title:SetScript("OnDragStart", function() if not AMS.db.ui.locked then f:StartMoving() end end)
    title:SetScript("OnDragStop",  function() f:StopMovingOrSizing() end)

    local logo = title:CreateFontString(nil, "OVERLAY")
    Skin:Font(logo, 16, true)
    logo:SetTextColor(unpack(C.accent))
    logo:SetPoint("LEFT", 12, 0)
    logo:SetText("AUCTION MASTER SUITE")

    local sub = title:CreateFontString(nil, "OVERLAY")
    Skin:Font(sub, 10, false)
    sub:SetTextColor(unpack(C.textDim))
    sub:SetPoint("LEFT", logo, "RIGHT", 8, -1)
    sub:SetText("v"..AMS.VERSION)

    local close = Skin:CloseButton(title)
    close:SetPoint("RIGHT", -6, 0)
    close:SetScript("OnClick", function() f:Hide() end)

    local lock = Skin:Button(title, "Lock", 50, 22)
    lock:SetPoint("RIGHT", close, "LEFT", -4, 0)
    local function refreshLock() lock.text:SetText(AMS.db.ui.locked and "Unlock" or "Lock") end
    lock:SetScript("OnMouseUp", function(s)
        s:SetBackdropColor(unpack(C.bgHover))
        AMS.db.ui.locked = not AMS.db.ui.locked
        refreshLock()
    end)

    -- gold on hand, always visible: every decision in here is about capital
    local gold = title:CreateFontString(nil, "OVERLAY")
    Skin:Font(gold, 12, true)
    gold:SetPoint("RIGHT", lock, "LEFT", -12, 0)
    self.goldText = gold

    -- auction house connection indicator
    local ah = title:CreateFontString(nil, "OVERLAY")
    Skin:Font(ah, 11, true)
    ah:SetPoint("RIGHT", gold, "LEFT", -14, 0)
    self.ahText = ah

    -- ---------- vertical tab bar ----------
    local tabbar = CreateFrame("Frame", nil, f)
    tabbar:SetPoint("TOPLEFT", 6, -38)
    tabbar:SetPoint("BOTTOMLEFT", 6, 6)
    tabbar:SetWidth(150)
    Skin:SetBackdrop(tabbar, C.bgPanel, C.border)
    self.tabbar = tabbar

    -- ---------- content ----------
    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", tabbar, "TOPRIGHT", 6, 0)
    content:SetPoint("BOTTOMRIGHT", -6, 6)
    Skin:SetBackdrop(content, C.bgPanel, C.border)
    self.content = content

    self.tabs   = {}
    self.panels = {}

    local y = -8
    for _, id in ipairs(TAB_ORDER) do
        local mod = AMS:GetModule(id)
        if mod then
            local b = Skin:TabButton(tabbar, mod.title, 138, 28)
            b:SetPoint("TOPLEFT", 6, y)
            b:SetScript("OnClick", function() UI:Show(id) end)
            self.tabs[id] = b
            y = y - 32
        end
    end

    -- ---------- footer status in the tab bar ----------
    local status = tabbar:CreateFontString(nil, "OVERLAY")
    Skin:Font(status, 10, false)
    status:SetTextColor(unpack(C.textDim))
    status:SetPoint("BOTTOMLEFT", 8, 8)
    status:SetPoint("BOTTOMRIGHT", -8, 8)
    status:SetJustifyH("LEFT")
    status:SetHeight(40)
    status:SetJustifyV("BOTTOM")
    self.status = status

    f:SetScript("OnShow", function()
        refreshLock()
        UI:UpdateStatus()
    end)

    self:_SelectTab(TAB_ORDER[1])
    self:UpdateStatus()

    -- keep the header live
    AMS:Subscribe("AH_STATE",       function() UI:UpdateStatus() end)
    AMS:Subscribe("SCAN_STATE",     function() UI:UpdateStatus() end)
    AMS:Subscribe("LEDGER_CHANGED", function() UI:UpdateStatus() end)
    AMS:RegisterEvent("PLAYER_MONEY", function() UI:UpdateStatus() end)

    return f
end

function UI:UpdateStatus()
    local U, C = AMS.Util, AMS.Skin.COLOR
    if self.goldText then
        self.goldText:SetText(U:Money(GetMoney()))
    end
    if self.ahText then
        if AMS:AtAuctionHouse() then
            self.ahText:SetText("AH CONNECTED")
            self.ahText:SetTextColor(unpack(C.good))
        else
            self.ahText:SetText("AH CLOSED")
            self.ahText:SetTextColor(unpack(C.textDim))
        end
    end
    if self.status then
        local n = AMS.DB and AMS.DB:MarketCount() or 0
        local t = AMS.DB and AMS.DB:Totals() or { profit = 0 }
        local col = t.profit >= 0 and "|cff4cd94c" or "|cfff24c4c"
        self.status:SetText(("%d market%s watched\nnet %s%s|r")
            :format(n, n == 1 and "" or "s", col, U:Money(t.profit, true)))
    end
end

function UI:_SelectTab(id)
    if id and self.tabs and self.tabs[id] then
        for tid, btn in pairs(self.tabs) do btn:SetSelected(tid == id) end
        for pid, panel in pairs(self.panels) do if pid ~= id then panel:Hide() end end
        local p = self:GetOrBuildPanel(id)
        if p then p:Show() end
        self.activeTab = id
    end
end

function UI:GetOrBuildPanel(id)
    if self.panels[id] then return self.panels[id] end
    local mod = AMS:GetModule(id)
    if not mod or not mod.BuildUI then return nil end
    local p = mod:BuildUI(self.content)
    p:SetAllPoints(self.content)
    p:Hide()
    self.panels[id] = p
    return p
end

function UI:Show(id)
    self:Build()
    self:_SelectTab(id or self.activeTab or TAB_ORDER[1])
    self:UpdateStatus()
    self.frame:Show()
end

function UI:Hide() if self.frame then self.frame:Hide() end end

function UI:Toggle()
    self:Build()
    if self.frame:IsShown() then self.frame:Hide() else self:Show(self.activeTab or TAB_ORDER[1]) end
end

function UI:IsShown() return self.frame and self.frame:IsShown() end
