-- Auction Master Suite -- Core
-- Namespace, event router, module registry, slash command.

local ADDON_NAME, ns = ...

AuctionMasterSuite = ns
local AMS = ns

AMS.NAME    = "Auction Master Suite"
AMS.SHORT   = "AMS"
AMS.VERSION = "0.20.0"
AMS.AUTHOR  = "rodneywowwow"

-- Module registry. Modules call AMS:RegisterModule(id, tbl).
AMS.modules     = {}
AMS.moduleOrder = {}

function AMS:RegisterModule(id, mod)
    if self.modules[id] then return self.modules[id] end
    mod.id     = id
    mod.title  = mod.title or id
    mod.events = mod.events or {}
    self.modules[id] = mod
    table.insert(self.moduleOrder, id)
    return mod
end

function AMS:GetModule(id) return self.modules[id] end

-- ---------- Logging ----------
function AMS:Print(msg, ...)
    if select("#", ...) > 0 then msg = msg:format(...) end
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd070["..self.SHORT.."]|r "..tostring(msg))
end

function AMS:Debug(msg, ...)
    if not (self.db and self.db.debug) then return end
    if select("#", ...) > 0 then msg = msg:format(...) end
    DEFAULT_CHAT_FRAME:AddMessage("|cff7fa0ff["..self.SHORT..":dbg]|r "..tostring(msg))
end

function AMS:Error(msg, ...)
    if select("#", ...) > 0 then msg = msg:format(...) end
    DEFAULT_CHAT_FRAME:AddMessage("|cffff5050["..self.SHORT.."]|r "..tostring(msg))
end

-- ---------- Event router ----------
local frame = CreateFrame("Frame", "AuctionMasterSuiteEventFrame")
AMS.eventFrame = frame
local handlers = {}
AMS.handlers   = handlers

function AMS:RegisterEvent(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        frame:RegisterEvent(event)
    end
    table.insert(handlers[event], fn)
end

frame:SetScript("OnEvent", function(self, event, ...)
    local list = handlers[event]
    if not list then return end
    for i = 1, #list do
        local ok, err = pcall(list[i], event, ...)
        if not ok then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff5050[AMS error]|r "..tostring(err))
        end
    end
end)

-- ---------- Lightweight internal message bus ----------
-- Core modules fire these; UI panels subscribe so they redraw without polling.
local subs = {}
function AMS:Subscribe(topic, fn)
    subs[topic] = subs[topic] or {}
    table.insert(subs[topic], fn)
end

function AMS:Fire(topic, ...)
    local list = subs[topic]
    if not list then return end
    for i = 1, #list do
        local ok, err = pcall(list[i], ...)
        if not ok then self:Error("handler for %s failed: %s", topic, tostring(err)) end
    end
end

-- ---------- Player helpers ----------
function AMS:PlayerName() return UnitName("player") end
function AMS:Realm()      return GetRealmName() end

function AMS:AtAuctionHouse()
    return AuctionFrame and AuctionFrame:IsShown() and true or false
end

-- ---------- Boot ----------
local booted = false
local function Boot()
    if booted then return end
    booted = true

    AuctionMasterSuiteDB     = AuctionMasterSuiteDB     or {}
    AuctionMasterSuiteCharDB = AuctionMasterSuiteCharDB or {}
    AMS.db     = AuctionMasterSuiteDB
    AMS.charDB = AuctionMasterSuiteCharDB

    if AMS.Config and AMS.Config.ApplyDefaults then AMS.Config:ApplyDefaults() end
    if AMS.DB     and AMS.DB.OnInit            then AMS.DB:OnInit()            end

    for _, id in ipairs(AMS.moduleOrder) do
        local mod = AMS.modules[id]
        if mod.OnInit then
            local ok, err = pcall(mod.OnInit, mod)
            if not ok then AMS:Error("module %s init failed: %s", id, err) end
        end
        for ev, fn in pairs(mod.events) do
            AMS:RegisterEvent(ev, function(...) fn(mod, ...) end)
        end
    end

    for _, name in ipairs({ "Scanner", "Inventory", "Buyer", "Poster", "Canceller", "Craft", "Ledger" }) do
        local sys = AMS[name]
        if sys and sys.OnInit then
            local ok, err = pcall(sys.OnInit, sys)
            if not ok then AMS:Error("%s init failed: %s", name, err) end
        end
    end

    if AMS.UI and AMS.UI.Build then AMS.UI:Build() end

    if AMS.db.ui and AMS.db.ui.openOnLogin and AMS.UI and AMS.UI.Show then
        AMS.UI:Show()
    end

    AMS:Print("v%s loaded. /ams to open.", AMS.VERSION)
end

AMS:RegisterEvent("PLAYER_LOGIN", Boot)
AMS:RegisterEvent("ADDON_LOADED", function(_, name)
    if name == ADDON_NAME then Boot() end
end)

-- ---------- Auction House hooks ----------
AMS:RegisterEvent("AUCTION_HOUSE_SHOW", function()
    AMS.atAH = true
    AMS:Fire("AH_STATE", true)
    if AMS.db and AMS.db.ui and AMS.db.ui.openAtAH and AMS.UI then AMS.UI:Show() end
end)

AMS:RegisterEvent("AUCTION_HOUSE_CLOSED", function()
    AMS.atAH = false
    AMS:Fire("AH_STATE", false)
    if AMS.Scanner and AMS.Scanner.Abort then AMS.Scanner:Abort("auction house closed") end
    if AMS.Poster  and AMS.Poster.Abort  then AMS.Poster:Abort("auction house closed")  end
    if AMS.Buyer   and AMS.Buyer.Stop    then AMS.Buyer:Stop("auction house closed")    end
    if AMS.db and AMS.db.ui and AMS.db.ui.closeAtAH and AMS.UI then AMS.UI:Hide() end
end)

-- ---------- Slash command ----------
SLASH_AUCTIONMASTERSUITE1 = "/ams"
SLASH_AUCTIONMASTERSUITE2 = "/auctionmaster"
SlashCmdList["AUCTIONMASTERSUITE"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local lower = msg:lower()

    if lower == "" or lower == "show" or lower == "toggle" then
        if AMS.UI then AMS.UI:Toggle() end
        return
    end
    if lower == "config" or lower == "options" or lower == "settings" then
        if AMS.UI then AMS.UI:Show("settings") end
        return
    end
    if lower == "debug" then
        AMS.db.debug = not AMS.db.debug
        AMS:Print("debug = %s", tostring(AMS.db.debug))
        return
    end
    if lower == "scan" then
        local m = AMS:GetModule("market")
        if m and m.Rescan then m:Rescan() end
        return
    end
    if lower == "help" then
        AMS:Print("commands:")
        AMS:Print("  /ams              toggle the window")
        AMS:Print("  /ams <item name>  open that market")
        AMS:Print("  /ams add <name>   add an item to the watchlist")
        AMS:Print("  /ams scan         rescan the current market")
        AMS:Print("  /ams books        profit / velocity ledger")
        AMS:Print("  /ams settings     settings tab")
        AMS:Print("  /ams donate       support the addon / report a bug")
        AMS:Print("  /ams attribute <name>   stamp old ledger entries with a character")
        return
    end

    local cmd, arg = lower:match("^(%S+)%s*(.*)$")
    local _, rawArg = msg:match("^(%S+)%s*(.*)$")

    -- /ams attribute <name> [all]
    if cmd == "attribute" then
        local who, mode = rawArg:match("^(%S+)%s*(%S*)$")
        if not who or who == "" then
            AMS:Print("usage: /ams attribute <character> [all]")
            AMS:Print("  fills in the character on ledger entries recorded before per-character tracking.")
            AMS:Print("  add 'all' to re-stamp every entry, not just the untagged ones.")
            return
        end
        local force = (mode or ""):lower() == "all"
        local n = AMS.DB:AttributeUntagged(who, force)
        AMS:Print("attributed |cffffd070%d|r ledger entr%s to %s%s.",
            n, n == 1 and "y" or "ies", who, force and " (all entries re-stamped)" or "")
        return
    end

    if cmd == "add" and rawArg ~= "" then
        if AMS.DB then
            AMS.DB:AddMarketByName(rawArg)
            if AMS.UI then AMS.UI:Show("watchlist") end
        end
        return
    end

    -- a tab id opens that tab
    if AMS.modules[cmd] then
        local mod = AMS.modules[cmd]
        if mod.OnSlash then return mod:OnSlash(rawArg) end
        if AMS.UI then AMS.UI:Show(cmd) end
        return
    end

    -- anything else: treat the whole string as an item name
    local market = AMS:GetModule("market")
    if market and market.OpenItemByName then
        market:OpenItemByName(msg)
        if AMS.UI then AMS.UI:Show("market") end
        return
    end
    AMS:Print("unknown command. /ams help")
end
