-- Auction Master Suite -- Donate / Support
-- Informational tab: how to send the author server coins or in-game gold, and
-- where to report bugs. Nothing here touches the auction house or your data.

local AMS = AuctionMasterSuite
local M = AMS:RegisterModule("donate", { title = "Donate", order = 98 })

-- The author's details. Forks should change these rather than delete the tab,
-- so users of a fork know who to talk to about it.
M.AUTHOR_CHARS = { "Mishlock", "Mishdk" }
M.AUTHOR_REALM = "Onyxia"
M.GITHUB_URL   = "https://github.com/advocaite/AuctionMasterSuite"
M.ISSUES_URL   = "https://github.com/advocaite/AuctionMasterSuite/issues"

local Skin, C

function M:OnInit()
    Skin = AMS.Skin
    C    = Skin.COLOR
    -- Whichever character the user picked last time stays picked.
    if not AMS.db.donateChar then AMS.db.donateChar = self.AUTHOR_CHARS[1] end
end

function M:Recipient()
    return AMS.db.donateChar or self.AUTHOR_CHARS[1]
end

-- ---------- chat output ----------
function M:PrintInfoToChat()
    AMS:Print("|cffffd070--- Support Auction Master Suite ---|r")
    AMS:Print("Coin gifts: |cffffff00%s|r on |cffffff00%s|r (Account Services -> Coins -> Coin Gifting)",
        self:Recipient(), self.AUTHOR_REALM)
    AMS:Print("Gold by in-game mail: |cffffff00%s|r (same realm: %s)",
        self:Recipient(), self.AUTHOR_REALM)
    AMS:Print("Bugs / ideas: |cff7fa0ff%s|r", self.ISSUES_URL)
end

-- ---------- mail auto-fill ----------
-- Filling the recipient is all we can do. Attaching gold and pressing Send are
-- protected actions, so the last two steps are always yours.
function M:OpenMailToAuthor()
    if not MailFrame or not MailFrame:IsShown() then
        AMS:Print("Open a mailbox first, then click again.")
        return false
    end
    if MailFrameTab_OnClick then MailFrameTab_OnClick(nil, 2) end   -- Send Mail tab
    if SendMailNameEditBox then
        SendMailNameEditBox:SetText(self:Recipient())
        SendMailNameEditBox:ClearFocus()
    end
    if SendMailSubjectEditBox then
        SendMailSubjectEditBox:SetText("AMS donation, ty <3")
    end
    AMS:Print("Mail filled in for %s. Attach the gold and hit Send.", self:Recipient())
    return true
end

-- ---------- slash ----------
function M:OnSlash(arg)
    arg = (arg or ""):lower()
    if arg == "chat" then return self:PrintInfoToChat() end
    if arg == "mail" then return self:OpenMailToAuthor() end
    if arg == "bug" or arg == "issue" or arg == "issues" then
        AMS:Print("Report bugs and request features at: |cff7fa0ff%s|r", self.ISSUES_URL)
        return
    end
    AMS.UI:Show("donate")
end

-- =============================================================================
-- UI
-- =============================================================================

-- A read-only, always-selectable URL box. WoW cannot open a browser, so the
-- only useful thing a link can do is sit there ready for Ctrl+C.
local function urlBox(parent, url, w, h)
    local e = Skin:EditBox(parent, w or 1, h or 22)
    e:SetText(url)
    e:SetTextColor(unpack(C.info))
    e:SetCursorPosition(0)
    e:SetScript("OnMouseUp",         function(s) s:HighlightText() end)
    e:SetScript("OnEditFocusGained", function(s) s:HighlightText() end)
    e:SetScript("OnTextChanged", function(s)
        if s:GetText() ~= url then s:SetText(url); s:HighlightText() end
    end)
    Skin:AddTooltip(e, "Copy this link",
        { "Click to select, then Ctrl+C.",
          "WoW cannot open a browser, so paste it into one yourself." })
    return e
end

function M:BuildUI(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()

    local header = Skin:Header(panel, "Donate / Support")
    header:SetPoint("TOPLEFT",  8, -8)
    header:SetPoint("TOPRIGHT", -8, -8)
    header:SetSub("Auction Master Suite v"..AMS.VERSION)

    -- Everything below the header scrolls, so a short window never buries the
    -- issue link the way the old settings tab used to.
    local scroll = Skin:ScrollFrame(panel)
    scroll:SetPoint("TOPLEFT",     header, "BOTTOMLEFT",  0, -6)
    scroll:SetPoint("BOTTOMRIGHT", panel,  "BOTTOMRIGHT", -8, 8)
    local body = scroll.content

    local y = -8
    local PAD = 10

    local function sectionHeader(text)
        local h = Skin:Header(body, text)
        h:SetPoint("TOPLEFT",  PAD, y)
        h:SetPoint("TOPRIGHT", body, "TOPRIGHT", -PAD, y)
        h:SetHeight(24)
        y = y - 26
        return h
    end

    local function sectionBody(height)
        local b = Skin:Panel(body)
        b:SetPoint("TOPLEFT",  PAD, y)
        b:SetPoint("TOPRIGHT", body, "TOPRIGHT", -PAD, y)
        b:SetHeight(height)
        y = y - (height + 12)
        return b
    end

    local function para(into, text, top, size, color, height)
        local fs = Skin:Label(into, text, size or 11, false, color or C.text)
        fs:SetPoint("TOPLEFT",  8, top)
        fs:SetPoint("TOPRIGHT", -8, top)
        fs:SetHeight(height or 30)
        fs:SetJustifyV("TOP")
        fs:SetWordWrap(true)
        fs:SetNonSpaceWrap(true)
        return fs
    end

    -- ===== intro =====
    local intro = Skin:Label(body,
        "Auction Master Suite is free and always will be. If it has made you gold, a tip is very welcome - "..
        "and so is a bug report, which is honestly worth more.", 12, false, C.text)
    intro:SetPoint("TOPLEFT",  PAD, y)
    intro:SetPoint("TOPRIGHT", body, "TOPRIGHT", -PAD, y)
    intro:SetHeight(34)
    intro:SetJustifyV("TOP")
    intro:SetWordWrap(true)
    y = y - 42

    -- ===== who =====
    sectionHeader("Send it to")
    local whoBody = sectionBody(76)

    para(whoBody, "Pick whichever of my characters you prefer. Both are on the same realm, "..
        "and this choice is used by everything below.", -8, 11, C.textDim, 28)

    local charLbl = Skin:Label(whoBody, "Character:", 11, false, C.textDim)
    charLbl:SetPoint("TOPLEFT", 8, -42)
    charLbl:SetWidth(70)

    local charBtns = {}
    local realmFS

    local function refreshChars()
        local pick = M:Recipient()
        for name, b in pairs(charBtns) do
            b:SetSelected(name == pick)
        end
        if realmFS then
            realmFS:SetText(("on |cffffd070%s|r"):format(M.AUTHOR_REALM))
        end
    end

    local bx = 84
    for _, name in ipairs(self.AUTHOR_CHARS) do
        local b = Skin:TabButton(whoBody, name, 92, 22)
        -- Tab buttons left-align for the sidebar; as a two-item picker they read
        -- better centred.
        b.text:ClearAllPoints()
        b.text:SetPoint("CENTER")
        b:SetPoint("TOPLEFT", bx, -40)
        b:SetScript("OnClick", function()
            AMS.db.donateChar = name
            refreshChars()
            if M._ui and M._ui.RefreshValues then M._ui.RefreshValues() end
        end)
        charBtns[name] = b
        bx = bx + 98
    end

    realmFS = Skin:Label(whoBody, "", 12, true, C.text)
    realmFS:SetPoint("TOPLEFT", bx + 6, -44)

    -- ===== coin gifting =====
    sectionHeader("Server Coin Gifting")
    local coinBody = sectionBody(112)

    para(coinBody, "On the server website: |cffffd070Account Services -> Coins -> Coin Gifting|r. "..
        "Enter the character and realm below as the receiver.", -8, 11, C.text, 30)

    local function bigField(into, label, top)
        local lbl = Skin:Label(into, label, 11, false, C.textDim)
        lbl:SetPoint("TOPLEFT", 8, top)
        lbl:SetWidth(150)
        local val = Skin:Label(into, "", 14, true, C.accent)
        val:SetPoint("LEFT",  lbl, "RIGHT", 4, 0)
        val:SetPoint("RIGHT", into, "RIGHT", -8, 0)
        return val
    end
    local coinCharVal  = bigField(coinBody, "Receiver Character:", -44)
    local coinRealmVal = bigField(coinBody, "Receiver Realm:",     -70)

    -- ===== gold mail =====
    sectionHeader("In-Game Gold Mail")
    local mailBody = sectionBody(112)

    para(mailBody, "Mail gold to me in-game. Any amount is appreciated - "..
        "if this addon cleared one market for you it has already paid for itself.", -8, 11, C.text, 30)

    local mailVal = bigField(mailBody, "Mail recipient:", -44)

    local fillBtn = Skin:Button(mailBody, "Auto-fill Send Mail", 190, 22)
    fillBtn:SetPoint("TOPLEFT", 8, -74)
    fillBtn:SetScript("OnMouseUp", function() M:OpenMailToAuthor() end)
    Skin:AddTooltip(fillBtn, "Auto-fill Send Mail",
        { "Stand at a mailbox with the mail window open, then click this.",
          "The recipient and subject get filled in for you.",
          " ",
          "Attaching the gold and pressing Send are protected actions -",
          "no addon is allowed to do those for you." })

    -- ===== github / bugs =====
    sectionHeader("Bugs, Ideas and Source")
    local ghBody = sectionBody(150)

    para(ghBody, "Found something broken? Want a feature? Open an issue. Include what you were doing, "..
        "the item, and any red error text - that is usually enough to fix it without a back-and-forth.",
        -8, 11, C.text, 30)

    local repoLbl = Skin:Label(ghBody, "Source and releases:", 11, false, C.textDim)
    repoLbl:SetPoint("TOPLEFT", 8, -44)
    local repoBox = urlBox(ghBody, self.GITHUB_URL, 1, 22)
    repoBox:SetPoint("TOPLEFT",  repoLbl, "BOTTOMLEFT", 0, -3)
    repoBox:SetPoint("RIGHT",    ghBody, "RIGHT", -8, 0)

    local issueLbl = Skin:Label(ghBody, "Report a bug / request a feature:", 11, false, C.textDim)
    issueLbl:SetPoint("TOPLEFT", repoBox, "BOTTOMLEFT", 0, -8)
    local issueBox = urlBox(ghBody, self.ISSUES_URL, 1, 22)
    issueBox:SetPoint("TOPLEFT", issueLbl, "BOTTOMLEFT", 0, -3)
    issueBox:SetPoint("RIGHT",   ghBody, "RIGHT", -8, 0)

    -- ===== chat button =====
    local printBtn = Skin:Button(body, "Print all of this to chat", 210, 22)
    printBtn:SetPoint("TOPLEFT", PAD, y)
    printBtn:SetScript("OnMouseUp", function() M:PrintInfoToChat() end)
    Skin:AddTooltip(printBtn, "Print to chat",
        { "Puts the character, realm and issue link in your chat frame,",
          "where you can copy them or link them to a friend." })
    y = y - 34

    local foot = Skin:Label(body,
        "Donations are entirely optional and unlock nothing - every feature is on for everyone. "..
        "Bug reports and feature ideas are just as valuable. <3", 10, false, C.textDim)
    foot:SetPoint("TOPLEFT",  PAD, y)
    foot:SetPoint("TOPRIGHT", body, "TOPRIGHT", -PAD, y)
    foot:SetHeight(30)
    foot:SetJustifyV("TOP")
    foot:SetWordWrap(true)
    y = y - 38

    scroll:SetContentHeight(-y)

    local function refreshValues()
        local who = M:Recipient()
        coinCharVal:SetText(who)
        coinRealmVal:SetText(M.AUTHOR_REALM)
        mailVal:SetText(("%s  -  %s"):format(who, M.AUTHOR_REALM))
    end

    self._ui = { panel = panel, scroll = scroll, RefreshValues = refreshValues }

    refreshChars()
    refreshValues()

    panel:SetScript("OnShow", function()
        refreshChars()
        refreshValues()
        scroll:UpdateScroll()
    end)

    return panel
end
