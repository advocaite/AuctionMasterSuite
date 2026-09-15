-- Auction Master Suite -- Skin
-- Same flat dark + gold accent style as Raid Master Suite. Widget factories:
-- backdrops, buttons, edit boxes, scroll lists, tabs, plus a few AH-specific
-- pieces (stat lines, meters, money boxes, item slots).

local AMS = AuctionMasterSuite
local Skin = {}
AMS.Skin = Skin

-- ---------- Palette ----------
local TEX_PATH = "Interface\\AddOns\\AuctionMasterSuite\\Skin\\"

Skin.PATH         = TEX_PATH
Skin.TEX_WHITE    = TEX_PATH.."white.tga"
Skin.TEX_BACK     = TEX_PATH.."backdrop-opaque-small.tga"
Skin.TEX_GLOW     = TEX_PATH.."glowborder.tga"
Skin.TEX_ARROWDN  = TEX_PATH.."arrowdown.tga"
Skin.TEX_ARROWUP  = TEX_PATH.."arrowup.tga"
Skin.TEX_SEP      = TEX_PATH.."separator.tga"
Skin.TEX_SEARCH   = TEX_PATH.."search.tga"
Skin.FONT         = TEX_PATH.."segoeui.ttf"
Skin.FONT_BOLD    = TEX_PATH.."segoeuib.ttf"

Skin.COLOR = {
    bgMain    = {0.08, 0.08, 0.10, 0.96},
    bgPanel   = {0.10, 0.10, 0.12, 0.95},
    bgHeader  = {0.14, 0.14, 0.16, 0.98},
    bgRow     = {0.12, 0.12, 0.14, 0.85},
    bgRowAlt  = {0.10, 0.10, 0.12, 0.85},
    bgHover   = {0.18, 0.18, 0.20, 1.00},
    bgActive  = {0.22, 0.22, 0.24, 1.00},
    border    = {0.22, 0.22, 0.25, 0.90},
    borderHi  = {0.40, 0.40, 0.45, 0.95},
    accent    = {0.90, 0.74, 0.40, 1.00},
    accentDim = {0.55, 0.45, 0.25, 0.80},
    text      = {0.92, 0.92, 0.94, 1.00},
    textDim   = {0.65, 0.65, 0.68, 1.00},
    textHead  = {1.00, 0.85, 0.50, 1.00},
    good      = {0.30, 0.85, 0.35, 1.00},
    bad       = {0.95, 0.30, 0.30, 1.00},
    warn      = {0.95, 0.75, 0.20, 1.00},
    info      = {0.45, 0.70, 0.95, 1.00},
}

local C   = Skin.COLOR
local SBD = {bgFile=Skin.TEX_WHITE, edgeFile=Skin.TEX_WHITE, tile=false, tileSize=0, edgeSize=1, insets={left=1,right=1,top=1,bottom=1}}

-- ---------- Helpers ----------
function Skin:SetBackdrop(frame, bgColor, borderColor)
    frame:SetBackdrop(SBD)
    frame:SetBackdropColor(unpack(bgColor or C.bgPanel))
    frame:SetBackdropBorderColor(unpack(borderColor or C.border))
end

function Skin:Font(fs, size, bold)
    fs:SetFont(bold and self.FONT_BOLD or self.FONT, size or 12, "")
end

function Skin:Hex(color)
    return ("|cff%02x%02x%02x"):format(color[1]*255, color[2]*255, color[3]*255)
end

-- ---------- Frame factories ----------
function Skin:Panel(parent, name)
    local f = CreateFrame("Frame", name, parent)
    self:SetBackdrop(f, C.bgPanel, C.border)
    return f
end

function Skin:Header(parent, text)
    local h = CreateFrame("Frame", nil, parent)
    self:SetBackdrop(h, C.bgHeader, C.border)
    h:SetHeight(28)
    local fs = h:CreateFontString(nil, "OVERLAY")
    self:Font(fs, 14, true)
    fs:SetTextColor(unpack(C.textHead))
    fs:SetPoint("LEFT", 10, 0)
    fs:SetText(text or "")
    h.text = fs

    -- optional right-aligned sub label
    local sub = h:CreateFontString(nil, "OVERLAY")
    self:Font(sub, 11, false)
    sub:SetTextColor(unpack(C.textDim))
    sub:SetPoint("RIGHT", -10, 0)
    h.sub = sub

    function h:SetText(t) self.text:SetText(t) end
    function h:SetSub(t)  self.sub:SetText(t or "") end
    return h
end

function Skin:Separator(parent)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetTexture(self.TEX_SEP)
    t:SetHeight(2)
    return t
end

function Skin:Label(parent, text, size, bold, color)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    self:Font(fs, size or 12, bold)
    fs:SetTextColor(unpack(color or C.text))
    fs:SetText(text or "")
    fs:SetJustifyH("LEFT")
    return fs
end

-- ---------- Buttons ----------
function Skin:Button(parent, label, w, h)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w or 100, h or 22)
    self:SetBackdrop(b, C.bgRow, C.border)

    local fs = b:CreateFontString(nil, "OVERLAY")
    self:Font(fs, 12, true)
    fs:SetTextColor(unpack(C.text))
    fs:SetPoint("CENTER")
    fs:SetText(label or "")
    b.text = fs

    b:SetScript("OnEnter", function(s)
        if s.disabled then return end
        s:SetBackdropColor(unpack(C.bgHover))
        s:SetBackdropBorderColor(unpack(s.accentColor or C.accent))
        s.text:SetTextColor(unpack(C.textHead))
    end)
    b:SetScript("OnLeave", function(s)
        if s.disabled then return end
        s:SetBackdropColor(unpack(s.baseColor or C.bgRow))
        s:SetBackdropBorderColor(unpack(C.border))
        s.text:SetTextColor(unpack(s.textColor or C.text))
    end)
    b:SetScript("OnMouseDown", function(s) if not s.disabled then s:SetBackdropColor(unpack(C.bgActive)) end end)
    b:SetScript("OnMouseUp",   function(s) if not s.disabled then s:SetBackdropColor(unpack(C.bgHover))  end end)

    function b:SetText(t) self.text:SetText(t) end
    function b:Disable()
        self:EnableMouse(false)
        self:SetBackdropColor(0.05,0.05,0.07,0.9)
        self:SetBackdropBorderColor(unpack(C.border))
        self.text:SetTextColor(unpack(C.textDim))
        self.disabled = true
    end
    function b:Enable()
        self:EnableMouse(true)
        self:SetBackdropColor(unpack(self.baseColor or C.bgRow))
        self.text:SetTextColor(unpack(self.textColor or C.text))
        self.disabled = false
    end
    function b:SetEnabled(on) if on then self:Enable() else self:Disable() end end
    return b
end

-- Emphasised action button (the "BUY" / "POST" buttons).
function Skin:BigButton(parent, label, w, h, tone)
    local b = self:Button(parent, label, w or 200, h or 32)
    self:Font(b.text, 14, true)
    local col = tone or C.accent
    b.accentColor = col
    b.textColor   = col
    b.text:SetTextColor(unpack(col))
    b:SetBackdropBorderColor(unpack(col))
    local orig = b.Enable
    function b:Enable()
        orig(self)
        self:SetBackdropBorderColor(unpack(col))
    end
    return b
end

function Skin:CloseButton(parent)
    local b = self:Button(parent, "X", 22, 22)
    b.textColor = C.bad
    b.text:SetTextColor(unpack(C.bad))
    return b
end

function Skin:TabButton(parent, label, w, h)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w or 130, h or 28)
    self:SetBackdrop(b, C.bgRowAlt, C.border)

    local fs = b:CreateFontString(nil, "OVERLAY")
    self:Font(fs, 12, true)
    fs:SetTextColor(unpack(C.text))
    fs:SetPoint("LEFT", 10, 0)
    fs:SetText(label or "")
    b.text = fs

    function b:SetSelected(on)
        self.selected = on
        if on then
            self:SetBackdropColor(unpack(C.bgActive))
            self:SetBackdropBorderColor(unpack(C.accent))
            self.text:SetTextColor(unpack(C.textHead))
        else
            self:SetBackdropColor(unpack(C.bgRowAlt))
            self:SetBackdropBorderColor(unpack(C.border))
            self.text:SetTextColor(unpack(C.text))
        end
    end
    -- SetEnabled does not exist on this client, so provide it rather than
    -- calling into nil from anything that treats tabs like buttons.
    function b:SetEnabled(on)
        self.disabled = not on
        self:EnableMouse(on and true or false)
        if on then
            self:SetSelected(self.selected)
        else
            self:SetBackdropColor(0.05, 0.05, 0.07, 0.9)
            self:SetBackdropBorderColor(unpack(C.border))
            self.text:SetTextColor(unpack(C.textDim))
        end
    end

    b:SetScript("OnEnter", function(s)
        if not s.selected and not s.disabled then s:SetBackdropColor(unpack(C.bgHover)) end
    end)
    b:SetScript("OnLeave", function(s)
        if not s.selected and not s.disabled then s:SetBackdropColor(unpack(C.bgRowAlt)) end
    end)
    return b
end

-- ---------- EditBox ----------
function Skin:EditBox(parent, w, h)
    local e = CreateFrame("EditBox", nil, parent)
    e:SetSize(w or 140, h or 22)
    self:SetBackdrop(e, C.bgRow, C.border)
    e:SetAutoFocus(false)
    e:SetTextInsets(6, 6, 0, 0)
    e:SetFont(self.FONT, 12, "")
    e:SetTextColor(unpack(C.text))
    e:SetScript("OnEscapePressed", e.ClearFocus)
    e:SetScript("OnEnterPressed",  e.ClearFocus)
    e:SetScript("OnEditFocusGained", function(s) s:SetBackdropBorderColor(unpack(C.accent)) end)
    e:SetScript("OnEditFocusLost",   function(s) s:SetBackdropBorderColor(unpack(C.border)) end)

    function e:Disable()
        self:EnableMouse(false); self:EnableKeyboard(false); self:ClearFocus()
        self:SetBackdropColor(0.05,0.05,0.07,0.9)
        self:SetTextColor(unpack(C.textDim))
        self.disabled = true
    end
    function e:Enable()
        self:EnableMouse(true); self:EnableKeyboard(true)
        self:SetBackdropColor(unpack(C.bgRow))
        self:SetTextColor(unpack(C.text))
        self.disabled = false
    end
    return e
end

-- ---------- Three-field money input ----------
-- Separate gold / silver / copper boxes, because "5g 50s" is a format you have
-- to know and "0.26" meaning 26 silver is a trap. Same API as a single edit box
-- so call sites do not care which they got.
--
-- Over-typing is forgiving: 150 in the silver box becomes 1g 50s when you leave
-- the widget, rather than being rejected.
--
-- Sizing is a floor, not a request. A caller asking for 120 pixels gets
-- MONEY_MIN_WIDTH anyway, because a gold box too narrow to show the number you
-- typed is worse than a widget that pushes its neighbour along - the strips
-- that hold these wrap, so there is somewhere for the neighbour to go.
local MONEY_SUB   = 32      -- silver and copper: two digits normally, three while over-typing
local MONEY_LBL   = 11      -- the g / s / c letters
local MONEY_GAP   = 3
local MONEY_GOLD  = 68      -- six digits and a cursor, so 999999g reads cleanly
local MONEY_FIXED = (MONEY_SUB * 2) + (MONEY_LBL * 3) + (MONEY_GAP * 5)
Skin.MONEY_MIN_WIDTH = MONEY_GOLD + MONEY_FIXED

function Skin:MoneyInput(parent, totalWidth, h)
    totalWidth = math.max(tonumber(totalWidth) or 0, Skin.MONEY_MIN_WIDTH)
    h = math.max(tonumber(h) or 0, 20)

    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(totalWidth, h)

    local goldW = totalWidth - MONEY_FIXED

    local function unitLabel(after, text, color)
        local l = f:CreateFontString(nil, "OVERLAY")
        Skin:Font(l, 11, true)
        l:SetTextColor(unpack(color))
        l:SetPoint("LEFT", after, "RIGHT", MONEY_GAP, 0)
        l:SetWidth(MONEY_LBL)
        l:SetJustifyH("LEFT")
        l:SetText(text)
        return l
    end

    local gold = Skin:NumberBox(f, goldW, h)
    gold:SetPoint("LEFT", 0, 0)
    local gl = unitLabel(gold, "g", { 1, 0.84, 0.20, 1 })

    local silver = Skin:NumberBox(f, MONEY_SUB, h)
    silver:SetPoint("LEFT", gl, "RIGHT", MONEY_GAP, 0)
    local sl = unitLabel(silver, "s", { 0.78, 0.78, 0.81, 1 })

    local copper = Skin:NumberBox(f, MONEY_SUB, h)
    copper:SetPoint("LEFT", sl, "RIGHT", MONEY_GAP, 0)
    unitLabel(copper, "c", { 0.93, 0.65, 0.37, 1 })

    -- Silver and copper never exceed two digits once the widget re-splits, so
    -- they can be capped. The gold box is left uncapped on purpose: there is no
    -- sensible ceiling on a price.
    silver:SetMaxLetters(3)
    copper:SetMaxLetters(3)

    f.gold, f.silver, f.copper = gold, silver, copper
    f.boxes = { gold, silver, copper }

    function f:GetMoney()
        return (self.gold:GetNumber()   * 10000)
             + (self.silver:GetNumber() * 100)
             + (self.copper:GetNumber())
    end

    function f:SetMoney(copperValue)
        local c = math.max(0, math.floor(tonumber(copperValue) or 0))
        self._value = c
        self.gold:SetNumber(math.floor(c / 10000))
        self.silver:SetNumber(math.floor((c % 10000) / 100))
        self.copper:SetNumber(c % 100)
    end

    function f:HasFocus()
        for _, b in ipairs(self.boxes) do if b:HasFocus() then return true end end
        return false
    end

    function f:Enable()  for _, b in ipairs(self.boxes) do b:Enable()  end end
    function f:Disable() for _, b in ipairs(self.boxes) do b:Disable() end end

    local function changed()
        local v = f:GetMoney()
        f._value = v
        if f.OnMoneyChanged then f:OnMoneyChanged(v) end
    end

    for _, b in ipairs(f.boxes) do
        b.OnNumberChanged = changed
        -- Re-split once focus has left the whole widget, so an over-typed
        -- silver or copper figure tidies itself up instead of being wrong.
        local prev = b:GetScript("OnEditFocusLost")
        b:SetScript("OnEditFocusLost", function(s, ...)
            if prev then prev(s, ...) end
            AMS.Util:After(0.05, function()
                if not f:HasFocus() then
                    local v = f:GetMoney()
                    f:SetMoney(v)
                    if f.OnMoneyChanged then f:OnMoneyChanged(v) end
                end
            end)
        end)
    end

    return f
end

-- ---------- Wrapping field strip ----------
-- A row of labelled controls above a table. The old version laid them out at
-- fixed offsets, which quietly ran off the right-hand edge as soon as the
-- window was narrower than the widest screen it was designed on - and stopped
-- any control being made bigger, because there was nowhere for the extra
-- pixels to come from.
--
-- This one wraps onto as many rows as it needs and reports its own height, so
-- everything anchored beneath it moves down instead of being covered.
function Skin:FieldStrip(parent, opts)
    opts = opts or {}
    local f = self:Panel(parent)
    f._items  = {}
    f._rowH   = opts.rowH   or 38
    f._padX   = opts.padX   or 8
    f._gap    = opts.gap    or 12
    f._labelY = opts.labelY or -4
    f._ctrlY  = opts.ctrlY  or -16
    f:SetHeight(f._rowH)

    -- labelText may be nil, for a bare button that explains itself.
    function f:AddItem(widget, width, labelText, tip)
        local l
        if labelText then l = Skin:Label(self, labelText, 10, false, C.textDim) end
        if tip then Skin:AddTooltip(widget, labelText or "", tip) end
        -- A widget is allowed to come out wider than it was asked for -
        -- MoneyInput enforces a floor - so reserve what it actually occupies.
        local real = widget:GetWidth()
        if not real or real < width then real = width end
        self._items[#self._items + 1] = { widget = widget, label = l, w = real }
        self:Relayout()
        return widget
    end

    -- builder(parent, width) keeps call sites reading top to bottom.
    function f:Add(labelText, width, builder, tip)
        return self:AddItem(builder(self, width), width, labelText, tip)
    end

    function f:Relayout()
        if self._laying then return end
        self._laying = true

        local avail = self:GetWidth() or 0
        -- Anchors have not resolved on the first pass; assume a typical window
        -- and lay out again for real the moment the size arrives.
        if avail <= 1 then avail = 820 end

        local x, row = self._padX, 1
        for _, it in ipairs(self._items) do
            if x > self._padX and (x + it.w) > (avail - self._padX) then
                x, row = self._padX, row + 1
            end
            local top = -((row - 1) * self._rowH)
            if it.label then
                it.label:ClearAllPoints()
                it.label:SetPoint("TOPLEFT", x, top + self._labelY)
            end
            it.widget:ClearAllPoints()
            it.widget:SetPoint("TOPLEFT", x, top + self._ctrlY)
            x = x + it.w + self._gap
        end

        local h = row * self._rowH
        if h ~= self._lastH then
            self._lastH = h
            self:SetHeight(h)
        end

        self._laying = nil
    end

    f:SetScript("OnSizeChanged", function(s) s:Relayout() end)
    return f
end

-- ---------- Item link capture ----------
-- Shift-clicking an item in your bags, or an item link in chat, routes through
-- ChatEdit_InsertLink. Blizzard's version only knows about chat edit boxes, the
-- auction house's own search field and the macro editor - which is exactly why
-- a shift-click lands in the auction house search box while ours sits empty,
-- and does nothing at all when the auction house is closed.
--
-- So we wrap it and give a focused Auction Master box first refusal. Focus is
-- required: hijacking every shift-click while our window happens to be open
-- would break linking items into chat.
Skin._linkBoxes = {}
local origInsertLink

local function amsInsertLink(text)
    if text then
        for _, box in ipairs(Skin._linkBoxes) do
            if box:IsVisible() and box:HasFocus() then
                if box.OnLink then box:OnLink(text) else box:SetText(text) end
                return true
            end
        end
    end
    if origInsertLink then return origInsertLink(text) end
    return false
end

-- onLink(box, link) is called with the raw item link.
function Skin:EnableLinks(box, onLink)
    box.OnLink = onLink
    table.insert(self._linkBoxes, box)
    if not origInsertLink and ChatEdit_InsertLink then
        origInsertLink   = ChatEdit_InsertLink
        ChatEdit_InsertLink = amsInsertLink
    end
    return box
end

-- Numeric edit box. Commits live on every keystroke: clicking a button in WoW
-- does not take focus off an edit box, so a value typed and then acted on would
-- otherwise never reach the addon.
function Skin:NumberBox(parent, w, h)
    local e = self:EditBox(parent, w or 60, h or 22)
    e:SetNumeric(true)
    e:SetJustifyH("RIGHT")
    -- Tighter than a text box. Six copper of padding either side of a
    -- right-aligned number is six pixels that could have been a digit, and on a
    -- narrow field it is the difference between reading the price and guessing.
    e:SetTextInsets(4, 4, 0, 0)

    function e:GetNumber() return tonumber(self:GetText()) or self._value or 0 end
    function e:SetNumber(v)
        self._writing = true
        self._value = math.floor(tonumber(v) or 0)
        self:SetText(tostring(self._value))
        self:SetCursorPosition(0)
        self._writing = nil
    end

    e:SetScript("OnTextChanged", function(s, userInput)
        if s._writing or not userInput then return end
        local v = tonumber(s:GetText())
        if v and math.floor(v) ~= s._value then
            s._value = math.floor(v)
            if s.OnNumberChanged then s:OnNumberChanged(s._value) end
        end
    end)
    e:SetScript("OnEditFocusLost", function(s)
        s:SetBackdropBorderColor(unpack(C.border))
        local v = math.floor(tonumber(s:GetText()) or s._value or 0)
        local changed = (v ~= s._value)
        s:SetNumber(v)
        if changed and s.OnNumberChanged then s:OnNumberChanged(v) end
    end)
    return e
end

-- ---------- CheckBox ----------
function Skin:CheckBox(parent, label)
    local cb = CreateFrame("Frame", nil, parent)
    cb:SetSize(180, 18)

    local box = CreateFrame("Button", nil, cb)
    box:SetSize(16, 16)
    box:SetPoint("LEFT", 0, 0)
    self:SetBackdrop(box, C.bgRow, C.border)

    local check = box:CreateTexture(nil, "OVERLAY")
    check:SetTexture(self.TEX_WHITE)
    check:SetVertexColor(unpack(C.accent))
    check:SetPoint("TOPLEFT", 3, -3)
    check:SetPoint("BOTTOMRIGHT", -3, 3)
    check:Hide()

    local fs = cb:CreateFontString(nil, "OVERLAY")
    self:Font(fs, 12, false)
    fs:SetTextColor(unpack(C.text))
    fs:SetPoint("LEFT", box, "RIGHT", 6, 0)
    fs:SetText(label or "")

    cb.box, cb.check, cb.text, cb.checked = box, check, fs, false
    function cb:GetChecked() return self.checked end
    function cb:SetChecked(v)
        self.checked = v and true or false
        if self.checked then self.check:Show() else self.check:Hide() end
        if self.OnValueChanged then self:OnValueChanged(self.checked) end
    end
    box:SetScript("OnClick", function() cb:SetChecked(not cb.checked) end)
    box:SetScript("OnEnter", function(s) s:SetBackdropBorderColor(unpack(C.accent)) end)
    box:SetScript("OnLeave", function(s) s:SetBackdropBorderColor(unpack(C.border)) end)
    return cb
end

-- ---------- Scroll list (simple virtual list) ----------
function Skin:ScrollList(parent, rowHeight, builder, updater)
    local f = CreateFrame("Frame", nil, parent)
    self:SetBackdrop(f, C.bgPanel, C.border)
    f.rowHeight = rowHeight or 20
    f.rows      = {}
    f.data      = {}
    f._builder  = builder
    f._updater  = updater

    local sb = CreateFrame("Slider", nil, f)
    sb:SetWidth(14); sb:SetOrientation("VERTICAL")
    sb:SetPoint("TOPRIGHT", -2, -2); sb:SetPoint("BOTTOMRIGHT", -2, 2)
    self:SetBackdrop(sb, C.bgRow, C.border)
    local thumb = sb:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture(self.TEX_WHITE)
    thumb:SetVertexColor(unpack(C.accent))
    thumb:SetSize(10, 30)
    sb:SetThumbTexture(thumb)
    sb:SetMinMaxValues(0, 0)
    sb:SetValueStep(1); sb:SetValue(0)
    f.scroll = sb

    f:EnableMouseWheel(true)
    f:SetScript("OnMouseWheel", function(self, dir)
        local v = sb:GetValue() - dir * 2
        local lo, hi = sb:GetMinMaxValues()
        if v < lo then v = lo end
        if v > hi then v = hi end
        sb:SetValue(v)
    end)

    function f:Refresh()
        local h = self:GetHeight() - 4
        if h <= 0 then
            -- Frame not laid out yet; retry next frame.
            local retry = self._retryFrame or CreateFrame("Frame")
            self._retryFrame = retry
            retry:Show()
            retry:SetScript("OnUpdate", function(s)
                s:SetScript("OnUpdate", nil); s:Hide()
                if self:GetHeight() > 0 then self:Refresh() end
            end)
            return
        end
        local visible = math.max(1, math.floor(h / self.rowHeight))
        local needed  = math.min(visible, #self.data)
        for i = #self.rows + 1, needed do
            local r = self._builder(self)
            r:SetParent(self)
            r:SetHeight(self.rowHeight)
            r:SetPoint("LEFT", 4, 0)
            r:SetPoint("RIGHT", -18, 0)
            self.rows[i] = r
        end
        for i = 1, #self.rows do
            local r = self.rows[i]
            if i <= needed then
                r:Show()
                r:ClearAllPoints()
                r:SetPoint("TOPLEFT", 4, -2 - (i-1)*self.rowHeight)
                r:SetPoint("RIGHT", -18, 0)
            else r:Hide() end
        end
        local maxOff = math.max(0, #self.data - visible)
        self.scroll:SetMinMaxValues(0, maxOff)
        if self.scroll:GetValue() > maxOff then self.scroll:SetValue(maxOff) end
        -- caller's chance to rescale columns to the width we ended up with
        if self.OnLayout then self.OnLayout(self) end
        self:Update()
    end
    function f:Update()
        local off = math.floor(self.scroll:GetValue() + 0.5)
        for i = 1, #self.rows do
            local r = self.rows[i]
            if r:IsShown() then
                local idx  = i + off
                local item = self.data[idx]
                self._updater(r, item, idx, idx % 2 == 0)
            end
        end
    end
    sb:SetScript("OnValueChanged", function() f:Update() end)
    f:SetScript("OnSizeChanged", function() f:Refresh() end)

    function f:SetData(data) self.data = data or {}; self:Refresh() end
    return f
end

-- ---------- Scrolling panel ----------
-- A Skin:Panel whose contents are clipped and scrollable. Anchor children to
-- `frame.content` (its width tracks the visible area), then tell it how tall
-- they came out with SetContentHeight. The scrollbar hides itself when
-- everything fits, and the content area widens to fill the space it leaves.
function Skin:ScrollFrame(parent, name)
    local outer = CreateFrame("Frame", name, parent)
    self:SetBackdrop(outer, C.bgPanel, C.border)

    local sb = CreateFrame("Slider", nil, outer)
    sb:SetWidth(14)
    sb:SetOrientation("VERTICAL")
    sb:SetPoint("TOPRIGHT", -2, -2)
    sb:SetPoint("BOTTOMRIGHT", -2, 2)
    self:SetBackdrop(sb, C.bgRow, C.border)
    local thumb = sb:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture(self.TEX_WHITE)
    thumb:SetVertexColor(unpack(C.accent))
    thumb:SetSize(10, 40)
    sb:SetThumbTexture(thumb)
    sb:SetMinMaxValues(0, 0)
    sb:SetValueStep(1)
    sb:SetValue(0)

    local scroll = CreateFrame("ScrollFrame", nil, outer)
    scroll:SetPoint("TOPLEFT", 3, -3)
    scroll:SetPoint("BOTTOMRIGHT", -19, 3)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(10, 10)
    scroll:SetScrollChild(content)

    outer.scroll, outer.content, outer.slider = scroll, content, sb
    outer._contentHeight = 0

    local function update()
        -- Sizes are derived from `outer` arithmetically rather than read back
        -- off `scroll`, whose width has not necessarily resolved yet in the
        -- same frame we just re-anchored it.
        local outerW, outerH = outer:GetWidth(), outer:GetHeight()
        if not outerW or outerW <= 0 or not outerH or outerH <= 0 then return end

        local h     = outer._contentHeight
        local range = math.max(0, h - (outerH - 6))

        if range > 0 then
            sb:Show()
            scroll:SetPoint("BOTTOMRIGHT", -19, 3)
            content:SetWidth(math.max(1, outerW - 22))
        else
            sb:Hide()
            scroll:SetPoint("BOTTOMRIGHT", -3, 3)
            scroll:SetVerticalScroll(0)
            content:SetWidth(math.max(1, outerW - 6))
        end
        content:SetHeight(math.max(1, h))

        sb:SetMinMaxValues(0, range)
        if sb:GetValue() > range then sb:SetValue(range) end
    end

    function outer:SetContentHeight(h)
        self._contentHeight = math.max(0, h or 0)
        update()
    end
    outer.UpdateScroll = update

    sb:SetScript("OnValueChanged", function(_, v) scroll:SetVerticalScroll(v) end)

    local function wheel(_, dir)
        local lo, hi = sb:GetMinMaxValues()
        if hi <= 0 then return end
        local v = sb:GetValue() - dir * 26
        if v < lo then v = lo elseif v > hi then v = hi end
        sb:SetValue(v)
    end
    outer:EnableMouseWheel(true)
    outer:SetScript("OnMouseWheel", wheel)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", wheel)

    outer:SetScript("OnSizeChanged", update)
    return outer
end

-- Scales a column spec so the whole set fits exactly into `avail` pixels.
-- Columns never shrink below col.min (default 24), so a very narrow pane
-- degrades by clipping the last column rather than by spilling all of them out
-- of the panel and over whatever is next to it.
function Skin:FitCols(cols, avail)
    local natural, gaps = 0, 0
    for i, c in ipairs(cols) do
        natural = natural + c.width
        if i < #cols then gaps = gaps + (c.gap or 6) end
    end
    local space = (avail or 0) - gaps
    if space <= 0 or natural <= 0 then return cols end

    local scale = space / natural
    local out = {}
    for i, c in ipairs(cols) do
        out[i] = {
            text    = c.text,
            width   = math.max(c.min or 24, math.floor(c.width * scale)),
            justify = c.justify,
            gap     = c.gap,
            size    = c.size,
            bold    = c.bold,
            min     = c.min,
        }
    end
    return out
end

-- Keeps a ScrollList and its header sharing one column spec that rescales to
-- whatever width the list actually gets. Call the returned accessor from the
-- list's row builder so new rows are born at the current widths.
function Skin:AutoCols(header, list, cols)
    local current = cols
    list.OnLayout = function(l)
        local w = l:GetWidth()
        if not w or w <= 0 then return end
        current = Skin:FitCols(cols, w - 26)   -- row inset + scrollbar gutter
        header:Relayout(current)
        for _, r in ipairs(l.rows) do r:Relayout(current) end
    end
    return function() return current end
end

local function layoutCells(frame, cols, startX)
    local x = startX
    frame._cellX = frame._cellX or {}
    for i, col in ipairs(cols) do
        frame._cellX[i] = x
        local fs = frame.cells[i]
        if fs then
            fs:ClearAllPoints()
            fs:SetPoint("LEFT", x, 0)
            fs:SetWidth(col.width)
            fs:SetJustifyH(col.justify or "LEFT")
        end
        x = x + col.width + (col.gap or 6)
    end
end

-- Column header strip to sit above a ScrollList.
-- cols = { {text="Unit", width=70, justify="RIGHT"}, ... }
function Skin:ListHeader(parent, cols)
    local h = CreateFrame("Frame", nil, parent)
    self:SetBackdrop(h, C.bgHeader, C.border)
    h:SetHeight(20)
    h.cells = {}
    h.cols  = cols
    for i, col in ipairs(cols) do
        local fs = h:CreateFontString(nil, "OVERLAY")
        self:Font(fs, 10, true)
        fs:SetTextColor(unpack(C.textDim))
        fs:SetWordWrap(false)
        fs:SetText(col.text)
        h.cells[i] = fs
    end
    -- 10, not 6: rows sit 4px inside the list and their cells another 6, so the
    -- header only lines up with the values underneath it at the same offset.
    layoutCells(h, cols, 10)

    function h:Relayout(newCols)
        self.cols = newCols or self.cols
        layoutCells(self, self.cols, 10)
    end
    return h
end

-- Row helper matching ListHeader columns.
function Skin:Row(parent, cols)
    local r = CreateFrame("Button", nil, parent)
    self:SetBackdrop(r, C.bgRow, {0,0,0,0})
    r.cells = {}
    r.cols  = cols
    for i, col in ipairs(cols) do
        local fs = r:CreateFontString(nil, "OVERLAY")
        self:Font(fs, col.size or 11, col.bold)
        fs:SetTextColor(unpack(C.text))
        fs:SetWordWrap(false)
        r.cells[i] = fs
    end
    layoutCells(r, cols, 6)

    function r:Relayout(newCols)
        self.cols = newCols or self.cols
        layoutCells(self, self.cols, 6)
        self:_LayoutIcon()
    end

    -- ---------- optional item icon in one column ----------
    -- Turned on per table. An icon is not decoration here: hovering it shows
    -- the real item tooltip, and asking for that tooltip is what makes the
    -- client fetch an item it has never seen - so it doubles as the manual way
    -- to resolve a row still showing "item #37663".
    function r:_LayoutIcon()
        local btn = self._iconBtn
        if not btn then return end
        local i   = self._iconCol
        local fs  = self.cells[i]
        local col = self.cols and self.cols[i]
        local x   = self._cellX and self._cellX[i]
        if not (fs and col and x) then return end

        local s = self._iconSize
        btn:ClearAllPoints()
        btn:SetPoint("LEFT", x, 0)
        fs:ClearAllPoints()
        if btn._on then
            fs:SetPoint("LEFT", x + s + 4, 0)
            fs:SetWidth(math.max(8, col.width - s - 4))
        else
            fs:SetPoint("LEFT", x, 0)
            fs:SetWidth(col.width)
        end
    end

    function r:EnableIcon(index, size)
        if self._iconBtn then return self._iconBtn end
        size = size or 14
        self._iconCol, self._iconSize = index or 1, size

        local btn = CreateFrame("Button", nil, self)
        btn:SetSize(size, size)
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        local tex = btn:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints()
        -- trim the stock icon border so a 14px icon is all art
        tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        btn.tex = tex

        btn:SetScript("OnEnter", function(s)
            if not (s._link or s._id) then return end
            GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
            -- SetHyperlink on an uncached item is also the request for it
            GameTooltip:SetHyperlink(s._link or ("item:"..s._id..":0:0:0:0:0:0:0"))
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        -- The icon sits on top of the row, so a click on it has to behave like
        -- a click on the row rather than swallowing it. Tables set their row
        -- action either way round, so both are honoured.
        btn:SetScript("OnClick", function(_, mouse)
            if r._rowClick then return r._rowClick(r, mouse) end
            local fn = r:GetScript("OnClick")
            if fn then return fn(r, mouse) end
        end)

        btn:Hide()
        self._iconBtn = btn
        self:_LayoutIcon()
        return btn
    end

    -- texture may be nil while the item is still being fetched; the slot stays
    -- there with a question mark so the row does not jump about when it lands.
    function r:SetIcon(texture, link, id)
        local btn = self._iconBtn
        if not btn then return end
        if not (texture or link or id) then
            btn._on, btn._link, btn._id = false, nil, nil
            btn:Hide()
        else
            btn._on, btn._link, btn._id = true, link, id
            btn.tex:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")
            btn:Show()
        end
        self:_LayoutIcon()
    end
    function r:Set(i, text, color)
        local fs = self.cells[i]
        if not fs then return end
        fs:SetText(text or "")
        if color then fs:SetTextColor(unpack(color)) end
    end
    -- Remember the tint so a hover can be undone without the caller telling us
    -- again which stripe this row was.
    function r:Tint(bg)
        self._tint = bg
        self:SetBackdropColor(unpack(bg))
    end

    -- Opt-in click target. Rows that do nothing stay flat on purpose - a row
    -- that lights up under the cursor is promising something, so only the ones
    -- that actually go somewhere get to do it.
    function r:SetRowClick(fn, clicks)
        self._rowClick = fn
        if not fn then
            self:SetScript("OnClick", nil)
            self:SetScript("OnEnter", nil)
            self:SetScript("OnLeave", nil)
            self:SetBackdropColor(unpack(self._tint or C.bgRow))
            return
        end
        self:RegisterForClicks(clicks or "LeftButtonUp")
        self:SetScript("OnClick", function(s, btn)
            if s._rowClick then s._rowClick(s, btn) end
        end)
        self:SetScript("OnEnter", function(s) s:SetBackdropColor(unpack(C.bgHover)) end)
        self:SetScript("OnLeave", function(s) s:SetBackdropColor(unpack(s._tint or C.bgRow)) end)
    end

    return r
end

-- ---------- Stat line: dim label on the left, bright value on the right ----------
-- The value sizes to its text and the label takes whatever is left, so a long
-- value shortens the label instead of the two overlapping in the middle.
function Skin:StatLine(parent, label, size)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight((size or 12) + 6)

    local v = f:CreateFontString(nil, "OVERLAY")
    self:Font(v, size or 12, true)
    v:SetTextColor(unpack(C.text))
    v:SetPoint("RIGHT", 0, 0)
    v:SetJustifyH("RIGHT")
    v:SetWordWrap(false)

    local l = f:CreateFontString(nil, "OVERLAY")
    self:Font(l, size or 12, false)
    l:SetTextColor(unpack(C.textDim))
    l:SetPoint("LEFT", 0, 0)
    l:SetPoint("RIGHT", v, "LEFT", -8, 0)
    l:SetJustifyH("LEFT")
    l:SetWordWrap(false)
    l:SetText(label or "")

    f.label, f.value = l, v
    function f:SetLabel(t) self.label:SetText(t or "") end
    function f:SetValue(t, color)
        self.value:SetText(t or "")
        self.value:SetTextColor(unpack(color or C.text))
    end
    return f
end

-- ---------- Meter / progress bar ----------
function Skin:Bar(parent, w, h)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w or 200, h or 14)
    self:SetBackdrop(f, C.bgRow, C.border)

    local fill = f:CreateTexture(nil, "ARTWORK")
    fill:SetTexture(self.TEX_WHITE)
    fill:SetVertexColor(unpack(C.accent))
    fill:SetPoint("TOPLEFT", 1, -1)
    fill:SetPoint("BOTTOMLEFT", 1, 1)
    fill:SetWidth(1)

    local fs = f:CreateFontString(nil, "OVERLAY")
    self:Font(fs, 10, true)
    fs:SetTextColor(unpack(C.text))
    fs:SetPoint("CENTER", 0, 0)

    f.fill, f.text = fill, fs
    f.pct = 0
    -- colour and label are remembered so a resize does not blank them
    function f:SetProgress(pct, color, label)
        pct = math.max(0, math.min(1, tonumber(pct) or 0))
        self.pct = pct
        if color then self._color = color end
        if label ~= nil then self._label = label end

        local w2 = math.max(1, (self:GetWidth() - 2) * pct)
        self.fill:SetWidth(w2)
        if self._color then self.fill:SetVertexColor(unpack(self._color)) end
        self.text:SetText(self._label or "")
    end
    f:SetScript("OnSizeChanged", function(s) s:SetProgress(s.pct) end)
    return f
end

-- ---------- Horizontal slider ----------
function Skin:Slider(parent, w, minV, maxV, step)
    local s = CreateFrame("Slider", nil, parent)
    s:SetOrientation("HORIZONTAL")
    s:SetSize(w or 160, 14)
    self:SetBackdrop(s, C.bgRow, C.border)
    local thumb = s:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture(self.TEX_WHITE)
    thumb:SetVertexColor(unpack(C.accent))
    thumb:SetSize(8, 12)
    s:SetThumbTexture(thumb)
    s:SetMinMaxValues(minV or 0, maxV or 1)
    s:SetValueStep(step or 0.05)
    return s
end

-- ---------- Item slot: drag an item on to it, or click with one on the cursor ----------
function Skin:ItemSlot(parent, size)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size or 36, size or 36)
    self:SetBackdrop(b, C.bgRow, C.border)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 2, -2)
    icon:SetPoint("BOTTOMRIGHT", -2, 2)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b.icon = icon

    local hint = b:CreateFontString(nil, "OVERLAY")
    self:Font(hint, 16, true)
    hint:SetTextColor(unpack(C.textDim))
    hint:SetPoint("CENTER")
    hint:SetText("+")
    b.hint = hint

    function b:SetItem(link, texture)
        self.link = link
        if texture then
            self.icon:SetTexture(texture)
            self.hint:Hide()
        else
            self.icon:SetTexture(nil)
            self.hint:Show()
        end
    end

    b:SetScript("OnEnter", function(s)
        s:SetBackdropBorderColor(unpack(C.accent))
        if s.link then
            GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(s.link)
            GameTooltip:Show()
        else
            GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Pick an item", C.textHead[1], C.textHead[2], C.textHead[3])
            GameTooltip:AddLine("Drag an item here, or shift-click one in your bags.", 0.9,0.9,0.9, true)
            GameTooltip:AddLine("Right-click to clear.", 0.65,0.65,0.68, true)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function(s)
        s:SetBackdropBorderColor(unpack(C.border))
        GameTooltip:Hide()
    end)
    return b
end

-- ---------- Verdict box: big coloured recommendation banner ----------
function Skin:Verdict(parent)
    local f = CreateFrame("Frame", nil, parent)
    self:SetBackdrop(f, C.bgRow, C.border)
    f:SetHeight(56)

    local title = f:CreateFontString(nil, "OVERLAY")
    self:Font(title, 15, true)
    title:SetPoint("TOPLEFT", 10, -7)
    title:SetPoint("RIGHT", -10, 0)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)

    -- two lines of room: the detail lines explain the refusals and they are
    -- long on purpose
    local sub = f:CreateFontString(nil, "OVERLAY")
    self:Font(sub, 11, false)
    sub:SetTextColor(unpack(C.textDim))
    sub:SetPoint("TOPLEFT", 10, -27)
    sub:SetPoint("BOTTOMRIGHT", -10, 5)
    sub:SetJustifyH("LEFT")
    sub:SetJustifyV("TOP")
    sub:SetWordWrap(true)
    sub:SetNonSpaceWrap(true)

    f.title, f.sub = title, sub
    function f:Set(text, detail, color)
        color = color or C.textDim
        self.title:SetText(text or "")
        self.title:SetTextColor(unpack(color))
        self.sub:SetText(detail or "")
        self:SetBackdropBorderColor(color[1], color[2], color[3], 0.85)
    end
    return f
end

-- ---------- Dropdown (flat, no Blizzard template) ----------
function Skin:Dropdown(parent, w, h)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w or 140, h or 22)
    self:SetBackdrop(b, C.bgRow, C.border)

    local fs = b:CreateFontString(nil, "OVERLAY")
    self:Font(fs, 12, false)
    fs:SetTextColor(unpack(C.text))
    fs:SetPoint("LEFT", 6, 0)
    fs:SetPoint("RIGHT", -18, 0)
    fs:SetJustifyH("LEFT")
    b.text = fs

    local arrow = b:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture(self.TEX_ARROWDN)
    arrow:SetVertexColor(unpack(C.accent))
    arrow:SetSize(10, 10)
    arrow:SetPoint("RIGHT", -6, 0)

    local menu = CreateFrame("Frame", nil, b)
    menu:SetFrameStrata("DIALOG")
    menu:SetPoint("TOPLEFT", b, "BOTTOMLEFT", 0, -2)
    menu:SetPoint("TOPRIGHT", b, "BOTTOMRIGHT", 0, -2)
    self:SetBackdrop(menu, C.bgHeader, C.accent)
    menu:Hide()
    b.menu    = menu
    b.entries = {}

    -- items = { {text=, value=}, ... }
    function b:SetItems(items)
        self.items = items or {}
        for _, e in ipairs(self.entries) do e:Hide() end
        local y = -4
        for i, item in ipairs(self.items) do
            local e = self.entries[i]
            if not e then
                e = Skin:Button(menu, "", 10, 20)
                e.text:ClearAllPoints()
                e.text:SetPoint("LEFT", 6, 0)
                Skin:Font(e.text, 11, false)
                self.entries[i] = e
            end
            e:SetPoint("TOPLEFT", 4, y)
            e:SetPoint("TOPRIGHT", -4, y)
            e:SetText(item.text)
            e:Show()
            e:SetScript("OnClick", function()
                b:SetValue(item.value, item.text)
                menu:Hide()
            end)
            y = y - 20
        end
        menu:SetHeight(math.max(8, -y + 4))
    end

    -- silent = true skips OnValueChanged, so a panel refresh that syncs the
    -- dropdown back to stored state cannot recurse into itself.
    function b:SetValue(value, text, silent)
        self.value = value
        if not text then
            for _, item in ipairs(self.items or {}) do
                if item.value == value then text = item.text break end
            end
        end
        self.text:SetText(text or tostring(value))
        if not silent and self.OnValueChanged then self:OnValueChanged(value) end
    end
    function b:GetValue() return self.value end

    b:SetScript("OnClick", function(s)
        if menu:IsShown() then menu:Hide() else menu:Show() end
    end)
    b:SetScript("OnEnter", function(s) s:SetBackdropBorderColor(unpack(C.accent)) end)
    b:SetScript("OnLeave", function(s) s:SetBackdropBorderColor(unpack(C.border)) end)
    return b
end

-- ---------- Mini bar chart ----------
-- data = { {value=, label=, color=, tipTitle=, tip={"line", ...}}, ... } left to
-- right. Bars scale to the largest value; a baseline value can be pinned with
-- SetBaseline.
--
-- Bars are textures and textures cannot take mouse input, so each column gets an
-- invisible button over it. Hovering anywhere in the column - not just on the
-- bar itself - lights it up and shows that entry's tooltip. SetInfo() adds a
-- tooltip for the chart as a whole, for explaining what is being plotted.
function Skin:MiniChart(parent, h)
    local f = CreateFrame("Frame", nil, parent)
    self:SetBackdrop(f, C.bgRow, C.border)
    f:SetHeight(h or 90)
    f.bars   = {}
    f.labels = {}
    f.hits   = {}

    f:EnableMouse(true)
    function f:SetInfo(title, lines) self._infoTitle, self._infoLines = title, lines end
    f:SetScript("OnEnter", function(s)
        if not s._infoTitle then return end
        GameTooltip:SetOwner(s, "ANCHOR_TOPRIGHT")
        GameTooltip:AddLine(s._infoTitle, C.textHead[1], C.textHead[2], C.textHead[3])
        for _, ln in ipairs(s._infoLines or {}) do
            GameTooltip:AddLine(ln, C.text[1], C.text[2], C.text[3], true)
        end
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local base = f:CreateTexture(nil, "ARTWORK")
    base:SetTexture(self.TEX_WHITE)
    base:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 0.35)
    base:SetHeight(1)
    base:Hide()
    f.baseline = base

    local empty = f:CreateFontString(nil, "OVERLAY")
    self:Font(empty, 11, false)
    empty:SetTextColor(unpack(C.textDim))
    empty:SetPoint("CENTER")
    f.empty = empty

    function f:SetBaseline(v) self._base = v; self:Redraw() end
    function f:SetData(data) self.data = data or {}; self:Redraw() end

    function f:Redraw()
        local data = self.data or {}
        for _, b in ipairs(self.bars)   do b:Hide() end
        for _, l in ipairs(self.labels) do l:Hide() end
        for _, hh in ipairs(self.hits)  do hh:Hide() end
        self.baseline:Hide()

        if #data == 0 then
            self.empty:SetText("no history yet")
            self.empty:Show()
            return
        end
        self.empty:Hide()

        local maxV = 0
        for _, d in ipairs(data) do if (d.value or 0) > maxV then maxV = d.value end end
        if self._base and self._base > maxV then maxV = self._base end
        if maxV <= 0 then maxV = 1 end

        local w      = self:GetWidth() - 12
        local plotH  = self:GetHeight() - 22
        local slot   = w / #data
        local barW   = math.max(2, math.floor(slot) - 2)

        for i, d in ipairs(data) do
            local bar = self.bars[i]
            if not bar then
                bar = self:CreateTexture(nil, "ARTWORK")
                bar:SetTexture(Skin.TEX_WHITE)
                self.bars[i] = bar
            end
            local pct = (d.value or 0) / maxV
            bar:ClearAllPoints()
            bar:SetPoint("BOTTOMLEFT", 6 + (i-1) * slot, 18)
            bar:SetWidth(barW)
            bar:SetHeight(math.max(1, plotH * pct))
            bar:SetVertexColor(unpack(d.color or C.accent))
            bar:Show()

            -- invisible hover target spanning the whole column
            local hit = self.hits[i]
            if not hit then
                hit = CreateFrame("Button", nil, self)
                hit:EnableMouse(true)
                hit:SetScript("OnEnter", function(s)
                    local dd = s.data
                    if not dd then return end
                    GameTooltip:SetOwner(s, "ANCHOR_TOPRIGHT")
                    GameTooltip:AddLine(dd.tipTitle or dd.label or "",
                        C.textHead[1], C.textHead[2], C.textHead[3])
                    for _, ln in ipairs(dd.tip or {}) do
                        GameTooltip:AddLine(ln, C.text[1], C.text[2], C.text[3], true)
                    end
                    GameTooltip:Show()
                    local bb = f.bars[s.barIndex]
                    if bb then bb:SetVertexColor(1, 1, 1, 0.95) end
                end)
                hit:SetScript("OnLeave", function(s)
                    GameTooltip:Hide()
                    local bb = f.bars[s.barIndex]
                    if bb and s.data then bb:SetVertexColor(unpack(s.data.color or C.accent)) end
                end)
                self.hits[i] = hit
            end
            hit.data, hit.barIndex = d, i
            hit:ClearAllPoints()
            hit:SetPoint("BOTTOMLEFT", 6 + (i-1) * slot, 18)
            hit:SetWidth(math.max(4, slot))
            hit:SetHeight(math.max(4, plotH))
            hit:Show()

            -- label every few bars so they stay readable
            local step = math.max(1, math.ceil(#data / 8))
            if d.label and (i == #data or (i - 1) % step == 0) then
                local l = self.labels[i]
                if not l then
                    l = self:CreateFontString(nil, "OVERLAY")
                    Skin:Font(l, 9, false)
                    l:SetTextColor(unpack(C.textDim))
                    self.labels[i] = l
                end
                l:ClearAllPoints()
                l:SetPoint("BOTTOM", bar, "BOTTOM", 0, -14)
                l:SetText(d.label)
                l:Show()
            end
        end

        if self._base and self._base > 0 then
            self.baseline:ClearAllPoints()
            self.baseline:SetPoint("LEFT", 6, 0)
            self.baseline:SetPoint("RIGHT", -6, 0)
            self.baseline:SetPoint("BOTTOM", self, "BOTTOM", 0, 18 + plotH * (self._base / maxV))
            self.baseline:Show()
        end
    end

    f:SetScript("OnSizeChanged", function(s) s:Redraw() end)
    return f
end

-- ---------- Managed windows (Style: global opacity etc.) ----------
Skin._windows = {}

local function styleAlpha()
    local a = AMS.db and AMS.db.style and tonumber(AMS.db.style.alpha)
    if not a then return 1 end
    if a < 0.3 then a = 0.3 elseif a > 1 then a = 1 end
    return a
end

function Skin:ManagedWindow(f)
    table.insert(self._windows, f)
    f:SetAlpha(styleAlpha())
    return f
end

function Skin:ApplyWindowAlpha()
    local a = styleAlpha()
    for _, f in ipairs(self._windows) do f:SetAlpha(a) end
end

-- ---------- Tooltip helper ----------
function Skin:AttachTooltip(widget, title, lines)
    widget:SetScript("OnEnter", function(s)
        GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
        if title then GameTooltip:AddLine(title, C.textHead[1], C.textHead[2], C.textHead[3]) end
        if lines then
            for _, ln in ipairs(lines) do
                GameTooltip:AddLine(ln, C.text[1], C.text[2], C.text[3], true)
            end
        end
        GameTooltip:Show()
    end)
    widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- Adds a tooltip without clobbering an existing OnEnter/OnLeave (buttons and
-- item slots already use theirs). Safe to call again on the same widget to
-- change the text - the handler is only wrapped once, so refreshes that call
-- this every frame do not stack handlers.
function Skin:AddTooltip(widget, title, lines)
    widget._amsTipTitle = title
    widget._amsTipLines = lines

    if widget._amsTipWrapped then return end
    widget._amsTipWrapped = true

    local oldEnter = widget:GetScript("OnEnter")
    local oldLeave = widget:GetScript("OnLeave")
    widget:SetScript("OnEnter", function(s, ...)
        if oldEnter then oldEnter(s, ...) end
        GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
        if s._amsTipTitle then
            GameTooltip:AddLine(s._amsTipTitle, C.textHead[1], C.textHead[2], C.textHead[3])
        end
        for _, ln in ipairs(s._amsTipLines or {}) do
            GameTooltip:AddLine(ln, C.text[1], C.text[2], C.text[3], true)
        end
        GameTooltip:Show()
    end)
    widget:SetScript("OnLeave", function(s, ...)
        if oldLeave then oldLeave(s, ...) end
        GameTooltip:Hide()
    end)
end
