-- Auction Master Suite -- Craft
--
-- Buy the inputs, convert, sell the outputs. Prospecting ore into gems is the
-- obvious case and it feeds the gem markets directly.
--
-- The hard part of this strategy is normally the yield data: how many of each
-- gem does a prospect actually give? Shipping a table of someone else's
-- averages would be guessing, and the numbers drift by server anyway.
--
-- So nothing is hardcoded. The addon WATCHES you convert and learns:
--
--   1. you cast Prospecting / Milling / Disenchant,
--   2. a census of your bags is taken,
--   3. a second census a moment later says what went in and what came out.
--
-- Bag diffing rather than chat parsing, because it needs no locale strings and
-- catches everything including the input that was consumed. Averaged over
-- enough operations it converges on YOUR yields on YOUR server.
--
-- Valuation is deliberately asymmetric: inputs are costed at what you would
-- PAY (the lowest ask) and outputs at what you would realistically GET (the
-- median). Costing both at the same price would make every conversion look
-- better than it is.

local AMS = AuctionMasterSuite
local Craft = {}
AMS.Craft = Craft

local U

-- Prospecting, Milling, Disenchant. Matched by localised name so this works on
-- any client language.
local SPELL_IDS = { 31252, 51005, 13262 }
local watched = {}

local SETTLE = 1.0    -- seconds to let the loot land before taking census two

function Craft:OnInit()
    U = AMS.Util

    for _, id in ipairs(SPELL_IDS) do
        local name = GetSpellInfo and GetSpellInfo(id)
        if name then watched[name] = id end
    end

    AMS:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, spellName)
        if unit ~= "player" or not spellName then return end
        if not watched[spellName] then return end
        Craft:_Observe(spellName)
    end)

    -- Opening a profession window is the moment its recipes become readable.
    AMS:RegisterEvent("TRADE_SKILL_SHOW", function()
        U:After(0.5, function() Craft:ScanTradeSkill() end)
    end)

    -- A new scan changes what every recipe costs, so the costed lists have to
    -- go. Cheap to rebuild, wrong to keep.
    AMS:Subscribe("HISTORY_CHANGED", function() Craft:InvalidateProfRows() end)
end

-- =============================================================================
-- Observation
-- =============================================================================

function Craft:_Observe(method)
    if self._pending then return end
    local before = AMS.Inventory:BagCensus()
    self._pending = true

    U:After(SETTLE, function()
        Craft._pending = nil
        local after = AMS.Inventory:BagCensus()

        local consumed, produced = {}, {}
        for id, n in pairs(before) do
            local now = after[id] or 0
            if now < n then consumed[id] = n - now end
        end
        for id, n in pairs(after) do
            local was = before[id] or 0
            if n > was then produced[id] = n - was end
        end

        -- exactly one thing should have been consumed; anything else means
        -- something unrelated happened at the same moment and the sample is junk
        local inputID, inputCount, inputs = nil, 0, 0
        for id, n in pairs(consumed) do inputs = inputs + 1; inputID, inputCount = id, n end
        if inputs ~= 1 or not inputID then
            AMS:Debug("craft: ignored a %s - %d items consumed, expected 1", method, inputs)
            return
        end
        if not next(produced) then
            AMS:Debug("craft: ignored a %s - nothing came out", method)
            return
        end

        Craft:Record(method, inputID, inputCount, produced)
    end)
end

function Craft:Record(method, inputID, inputCount, produced)
    local data = AMS.data.crafts
    local rec = data[inputID]
    if not rec then
        rec = { id = inputID, ops = 0, inputUsed = 0, outputs = {}, method = method }
        data[inputID] = rec
    end
    rec.method   = method
    rec.name     = rec.name or (U:ItemInfo(inputID) or {}).name
    rec.ops      = rec.ops + 1
    rec.inputUsed = rec.inputUsed + inputCount
    rec.lastSeen = U:Now()

    local parts = {}
    for outID, n in pairs(produced) do
        local o = rec.outputs[outID]
        if not o then
            o = { id = outID, total = 0, name = (U:ItemInfo(outID) or {}).name }
            rec.outputs[outID] = o
        end
        o.total = o.total + n
        o.name  = o.name or (U:ItemInfo(outID) or {}).name
        parts[#parts+1] = ("%dx %s"):format(n, o.name or "?")
    end

    AMS:Print("%s recorded: %d %s -> %s  (%d operation%s learned)",
        method, inputCount, rec.name or "?", table.concat(parts, ", "),
        rec.ops, rec.ops == 1 and "" or "s")
    AMS:Fire("CRAFT_CHANGED", inputID)
end

-- =============================================================================
-- Real recipes, read from your own profession window
-- =============================================================================
--
-- Prospecting and milling are random, so they have to be learned by watching.
-- Crafting is not: armour, enchanting scrolls and glyphs have exact reagents,
-- and the client already knows them. GetTradeSkillReagentInfo hands them over
-- for free the moment you open the window.
--
-- So there is nothing to scrape off the web and no second addon needed. Open
-- Jewelcrafting, Enchanting, whatever you have, and every recipe you know is
-- recorded with exact quantities - only the recipes you can actually make.

function Craft:ScanTradeSkill()
    if not GetNumTradeSkills then return 0 end
    local n = GetNumTradeSkills()
    if not n or n == 0 then return 0 end

    local profession = GetTradeSkillLine and GetTradeSkillLine() or "Unknown"
    local learned = 0

    for i = 1, n do
        local skillName, skillType = GetTradeSkillInfo(i)
        if skillName and skillType ~= "header" then
            local link = GetTradeSkillItemLink(i)
            local id   = link and U:ItemIDFromLink(link)

            -- An enchant creates no item, so it has no item link and falls
            -- straight through the branch below. Its NAME is the handle,
            -- though, and it matches the enchant data exactly - so this is the
            -- one place we can learn which enchants are actually yours.
            if (AMS.EnchantData or {})[skillName] then
                if not AMS.data.enchants[skillName] then
                    AMS.data.enchants[skillName] = { learnedAt = U:Now() }
                    learned = learned + 1
                end
            end

            if id then
                local minMade, maxMade = GetTradeSkillNumMade(i)
                local reagents = {}
                for r = 1, (GetTradeSkillNumReagents(i) or 0) do
                    local rName, _, rCount = GetTradeSkillReagentInfo(i, r)
                    local rLink = GetTradeSkillReagentItemLink(i, r)
                    local rID   = rLink and U:ItemIDFromLink(rLink)
                    if rID then
                        reagents[#reagents+1] = { id = rID, name = rName, count = rCount or 1 }
                    end
                end

                if #reagents > 0 then
                    AMS.data.recipes[id] = {
                        id         = id,
                        name       = skillName,
                        profession = profession,
                        madeMin    = minMade or 1,
                        madeMax    = maxMade or minMade or 1,
                        reagents   = reagents,
                        learnedAt  = U:Now(),
                    }
                    learned = learned + 1
                end
            end
        end
    end

    if learned > 0 then
        self:InvalidateUsedIndex()
        AMS:Print("learned |cffffd070%d %s recipe%s|r - open the Craft tab to see which are worth making.",
            learned, profession, learned == 1 and "" or "s")
        AMS:Fire("CRAFT_CHANGED")
    end
    return learned
end

-- Data/RecipeData.lua carries every crafting recipe in the game, extracted from
-- the client's own Spell.dbc. Recipes read out of your profession window still
-- take priority: those are the ones you can actually make, and they carry that
-- fact with them.
local function reagentList(flat)
    local out = {}
    for i = 1, #flat, 2 do
        local rid = flat[i]
        out[#out+1] = { id = rid, count = flat[i+1], name = (U:ItemInfo(rid) or {}).name }
    end
    return out
end

local function routeToRecipe(id, d)
    return {
        id         = id,
        spell      = d.s,
        profession = d.p,
        skill      = d.k,
        madeMin    = d.n,
        madeMax    = d.x,
        reagents   = reagentList(d.r),
        name       = (U:ItemInfo(id) or {}).name,
        known      = false,     -- nobody here has shown they can make it
    }
end

-- An enchant creates no item, so it has no entry keyed by one. Applied to a
-- vellum it becomes "Scroll of <enchant name>", and that naming is systematic
-- enough to match on - which is the only handle the client gives us, since the
-- scroll's own item data lives server-side.
local VELLUM = "Enchanting Vellum"

function Craft:ScrollRecipe(itemID)
    if not U or not AMS.EnchantData or not itemID then return nil end
    local info = U:ItemInfo(itemID)
    if not info or not info.name then return nil end

    local enchName = info.name:match("^Scroll of (.+)$")
    if not enchName then return nil end
    local d = AMS.EnchantData[enchName]
    if not d then return nil end

    -- remember the id so the reverse lookup can find scrolls we have met
    if AMS.data.scrolls[enchName] ~= itemID then
        AMS.data.scrolls[enchName] = itemID
        self:InvalidateUsedIndex()
    end

    local reagents = reagentList(d.r)
    -- the vellum is not a spell reagent, so it is looked up by name rather
    -- than by an id hardcoded on a guess
    local vel = U:ItemInfo(VELLUM)
    if vel and vel.id then
        reagents[#reagents+1] = { id = vel.id, count = 1, name = vel.name }
    end

    return {
        id = itemID, spell = d.s, profession = "Enchanting", skill = d.k,
        madeMin = 1, madeMax = 1, reagents = reagents,
        name = info.name, known = false, isScroll = true,
        vellumMissing = not (vel and vel.id),
    }
end

-- Every way to make this item. Several spells often produce the same thing and
-- which is cheapest depends on today's prices, so they are all offered.
function Craft:RoutesFor(id)
    if not id then return {} end
    local out = {}
    local learned = AMS.data.recipes[id]
    if learned then
        learned.known = true
        out[#out+1] = learned
    end
    for _, d in ipairs((AMS.RecipeData or {})[id] or {}) do
        if not (learned and learned.spell == d.s) then
            out[#out+1] = routeToRecipe(id, d)
        end
    end
    local scroll = self:ScrollRecipe(id)
    if scroll then out[#out+1] = scroll end
    return out
end

function Craft:GetRecipe(id)
    return self:RoutesFor(id)[1]
end

-- Is this item craftable at all, by anyone?
function Craft:IsCraftable(id)
    if not id then return false end
    if AMS.data.recipes[id] then return true end
    if AMS.RecipeData and AMS.RecipeData[id] then return true end
    return self:ScrollRecipe(id) ~= nil
end

function Craft:DataCount()
    local n = 0
    for _ in pairs(AMS.RecipeData or {}) do n = n + 1 end
    return n
end

-- Recipes worth listing: ones you know, plus any whose crafted item you have
-- actually scanned. Listing all three thousand from the data file would be a
-- wall of dashes and slow to value.
function Craft:AllRecipes()
    local out, seen = {}, {}
    for id, r in pairs(AMS.data.recipes) do
        r.known = true
        seen[id] = true
        out[#out+1] = r
    end
    for id in pairs(AMS.RecipeData or {}) do
        if not seen[id] and AMS.DB:LastSnapshot(id) then
            local r = self:GetRecipe(id)
            if r then out[#out+1] = r end
        end
    end
    -- scrolls we have met, if they have been scanned
    for _, itemID in pairs(AMS.data.scrolls or {}) do
        if not seen[itemID] and AMS.DB:LastSnapshot(itemID) then
            local r = self:ScrollRecipe(itemID)
            if r then seen[itemID] = true; out[#out+1] = r end
        end
    end
    return out
end

function Craft:ForgetRecipes(profession)
    if not profession then
        AMS.data.recipes = {}
    else
        for id, r in pairs(AMS.data.recipes) do
            if r.profession == profession then AMS.data.recipes[id] = nil end
        end
    end
    self:InvalidateUsedIndex()
    AMS:Fire("CRAFT_CHANGED")
end

-- =============================================================================
-- Reading it back
-- =============================================================================

function Craft:Get(inputID) return AMS.data.crafts[inputID] end

function Craft:All()
    local out = {}
    for _, rec in pairs(AMS.data.crafts) do out[#out+1] = rec end
    table.sort(out, function(a, b) return (a.name or "") < (b.name or "") end)
    return out
end

function Craft:Forget(inputID)
    if inputID then AMS.data.crafts[inputID] = nil else AMS.data.crafts = {} end
    AMS:Fire("CRAFT_CHANGED", inputID)
end

-- Price we would PAY for a unit of this item: the cheapest ask we last saw.
local function buyPrice(itemID)
    local snap = AMS.DB:LastSnapshot(itemID)
    if snap and (snap.min or 0) > 0 then return snap.min, snap.t end
    return nil
end

-- Price we would realistically GET: the weighted median, not the top ask.
local function sellPrice(itemID)
    local snap = AMS.DB:LastSnapshot(itemID)
    if snap and (snap.median or 0) > 0 then return snap.median, snap.t end
    if snap and (snap.min or 0) > 0 then return snap.min, snap.t end
    return nil
end

-- Everything the Craft tab needs for one input item.
function Craft:Evaluate(inputID)
    if not U then return nil end
    local rec = self:Get(inputID)
    if not rec or rec.ops == 0 then return nil end

    local cut      = AMS.Config:Cut()
    local inputPer = rec.inputUsed / rec.ops

    local rows, value, unpriced = {}, 0, 0
    for _, o in pairs(rec.outputs) do
        local perOp = o.total / rec.ops
        local price, at = sellPrice(o.id)
        local net = price and math.floor(perOp * price * (1 - cut)) or 0
        if not price then unpriced = unpriced + 1 else value = value + net end
        local nm, quality, tex, link = U:ItemName(o.id, o.name)
        rows[#rows+1] = {
            id = o.id, name = nm, quality = quality, texture = tex, link = link,
            perOp = perOp, total = o.total,
            price = price, priceAt = at, net = net,
        }
    end
    table.sort(rows, function(a, b) return (b.net or 0) < (a.net or 0) end)

    local inPrice, inAt = buyPrice(inputID)
    local cost = inPrice and math.floor(inputPer * inPrice) or nil

    local r = {
        rec       = rec,
        inputPer  = inputPer,
        inputPrice= inPrice,
        inputAt   = inAt,
        cost      = cost,
        value     = value,
        unpriced  = unpriced,
        rows      = rows,
        ops       = rec.ops,
    }
    if cost and cost > 0 then
        r.profit = value - cost
        r.roi    = r.profit / cost
    end
    return r
end

-- Reagents cost what you would pay for them; the result sells at the median.
-- Costs one specific route.
function Craft:EvaluateRoute(craftedID, rec)
    if not U or not rec then return nil end

    local cut  = AMS.Config:Cut()
    local made = ((rec.madeMin or 1) + (rec.madeMax or 1)) / 2

    local rows, cost, unpriced = {}, 0, 0
    for _, g in ipairs(rec.reagents) do
        local price = buyPrice(g.id)
        local total = price and (price * g.count) or 0
        if not price then unpriced = unpriced + 1 else cost = cost + total end
        -- Reagents are the worst case for the item cache: half of them are
        -- things you have never owned. ItemName queues the ones the client has
        -- never seen and the list redraws itself when they land.
        local rName, rQuality, rTex, rLink = U:ItemName(g.id, g.name)
        rows[#rows+1] = {
            id = g.id, name = rName, quality = rQuality, texture = rTex, link = rLink,
            perOp = g.count, price = price, net = total,
        }
    end
    table.sort(rows, function(a, b) return (b.net or 0) < (a.net or 0) end)

    local outPrice = sellPrice(craftedID)
    local value = outPrice and math.floor(made * outPrice * (1 - cut)) or nil

    local r = {
        recipe   = rec,
        isRecipe = true,
        made     = made,
        outPrice = outPrice,
        cost     = (unpriced == 0) and cost or nil,
        value    = value,
        unpriced = unpriced,
        rows     = rows,
        ops      = nil,
    }
    if r.cost and r.value and r.cost > 0 then
        r.profit = r.value - r.cost
        r.roi    = r.profit / r.cost
    end
    return r
end

-- Costs every route and returns the cheapest one that can actually be priced.
-- A recipe you know wins ties, since that is the one you can make today.
function Craft:EvaluateRecipe(craftedID)
    if not U then return nil end
    local routes = self:RoutesFor(craftedID)
    if #routes == 0 then return nil end

    local best, fallback
    for _, rec in ipairs(routes) do
        local e = self:EvaluateRoute(craftedID, rec)
        if e then
            if e.cost then
                if not best or e.cost < best.cost
                   or (e.cost == best.cost and rec.known and not best.recipe.known) then
                    best = e
                end
            end
            fallback = fallback or e
        end
    end
    local chosen = best or fallback
    if chosen then chosen.routes = #routes end
    return chosen
end

-- Both kinds in one list, so the tab can rank a prospect against a recipe.
function Craft:AllConversions()
    local out = {}
    for _, rec in ipairs(self:All()) do
        local e = self:Evaluate(rec.id)
        local nm, quality, tex, link = U:ItemName(rec.id, rec.name)
        out[#out+1] = {
            id = rec.id, kind = "learned",
            name = nm, quality = quality, texture = tex, link = link,
            method = rec.method, ops = rec.ops,
            cost = e and e.cost, value = e and e.value,
            profit = e and e.profit, roi = e and e.roi,
        }
    end
    for _, rec in ipairs(self:AllRecipes()) do
        local e = self:EvaluateRecipe(rec.id)
        local nm, quality, tex, link = U:ItemName(rec.id, rec.name)
        out[#out+1] = {
            id = rec.id, kind = "recipe",
            name = nm, quality = quality, texture = tex, link = link,
            method = rec.profession, ops = nil,
            cost = e and e.cost, value = e and e.value,
            profit = e and e.profit, roi = e and e.roi,
        }
    end
    return out
end

-- =============================================================================
-- Professions
-- =============================================================================
--
-- The recipe data already carries a profession on every route, so the whole of
-- Blacksmithing can be listed without anyone here having Blacksmithing. That is
-- the point: what a profession you do not have can make, and what it needs, is
-- exactly the information that tells you whether the mats are worth posting.
--
-- Two separate questions get answered here and they should not be confused:
--   * what the profession can make at all   - from the client's Spell.dbc
--   * what YOU can make today               - only known after you have opened
--                                             that profession window once
--
-- "Other" is the extraction's bucket for crafting spells with no trade skill
-- line behind them. It is a real category - the elemental conversions live
-- there - not a parse failure.

-- Cached because inverting four thousand routes is not worth doing twice, and
-- because the Craft tab re-reads this on every refresh.
local profIndex

local function addToProf(prof, id, seen)
    prof = prof or "Other"
    local key = prof .. "|" .. id
    if seen[key] then return end
    seen[key] = true
    local l = profIndex[prof]
    if not l then l = {}; profIndex[prof] = l end
    l[#l+1] = id
end

local function buildProfIndex()
    profIndex = {}
    local seen = {}
    for id, routes in pairs(AMS.RecipeData or {}) do
        for _, d in ipairs(routes) do addToProf(d.p, id, seen) end
    end
    -- Enchants are deliberately NOT indexed here even when we know the scroll's
    -- item id. Every one of them is listed by EnchantRows(), which covers the
    -- ones we have no scroll for too, and indexing the met ones as well would
    -- show them twice.
    --
    -- anything read out of a real profession window, in case the extraction
    -- filed it under a different line than the client does
    for id, r in pairs(AMS.data.recipes or {}) do addToProf(r.profession, id, seen) end
end

-- Which professions this character actually has, and at what skill.
--
-- Collapsed headers hide their children from the skill-line API, so the headers
-- have to be opened to read anything. Whichever were closed are closed again
-- afterwards - nobody asked us to reorganise their skills window.
function Craft:MyProfessions()
    local mine = {}
    if not GetNumSkillLines or not GetSkillLineInfo then return mine end

    local wasCollapsed = {}
    for i = 1, GetNumSkillLines() do
        local name, isHeader, isExpanded = GetSkillLineInfo(i)
        if isHeader and not isExpanded and name then wasCollapsed[name] = true end
    end
    if next(wasCollapsed) and ExpandSkillHeader then ExpandSkillHeader(0) end

    for i = 1, GetNumSkillLines() do
        local name, isHeader, _, rank, _, _, maxRank = GetSkillLineInfo(i)
        if name and not isHeader then
            mine[name] = { rank = rank or 0, max = maxRank or 0 }
        end
    end

    if next(wasCollapsed) and CollapseSkillHeader then
        for i = GetNumSkillLines(), 1, -1 do
            local name, isHeader = GetSkillLineInfo(i)
            if isHeader and name and wasCollapsed[name] then CollapseSkillHeader(i) end
        end
    end
    return mine
end

-- Every profession the data knows about, with how much of it we can see.
function Craft:Professions()
    if not profIndex then buildProfIndex() end

    local mine = self:MyProfessions()
    local knownCount = {}
    for _, r in pairs(AMS.data.recipes or {}) do
        local p = r.profession or "Other"
        knownCount[p] = (knownCount[p] or 0) + 1
    end

    -- Enchanting's enchants are not in the index - they are not items - so its
    -- totals have to be added on rather than read off it.
    local enchTotal, enchKnown = 0, 0
    for ench in pairs(AMS.EnchantData or {}) do
        enchTotal = enchTotal + 1
        if (AMS.data.enchants or {})[ench] then enchKnown = enchKnown + 1 end
    end

    local out = {}
    for name, list in pairs(profIndex) do
        local skill  = mine[name]
        local isEnch = (name == "Enchanting")
        out[#out+1] = {
            name    = name,
            total   = #list + (isEnch and enchTotal or 0),
            known   = (knownCount[name] or 0) + (isEnch and enchKnown or 0),
            haveIt  = skill ~= nil,
            rank    = skill and skill.rank,
            max     = skill and skill.max,
        }
    end

    -- Yours first - those are the ones you can act on today - then the rest
    -- alphabetically, with the catch-all bucket last wherever it lands.
    table.sort(out, function(a, b)
        if a.haveIt ~= b.haveIt then return a.haveIt end
        local ao, bo = a.name == "Other", b.name == "Other"
        if ao ~= bo then return bo end
        return a.name < b.name
    end)
    return out
end

-- How many enchants we have not yet met a scroll for, so Enchanting can say so
-- rather than looking suspiciously short.
function Craft:UnmatchedEnchants()
    local total, met = 0, 0
    for name in pairs(AMS.EnchantData or {}) do
        total = total + 1
        if (AMS.data.scrolls or {})[name] then met = met + 1 end
    end
    return total - met, total
end

-- ---------- enchants as scrolls ----------
--
-- An enchant is not an item, which is why Enchanting used to list only the
-- things it makes that happen to be objects - wands, oils, rods. The 265
-- enchants themselves were invisible, and they are the entire reason anyone
-- levels the profession.
--
-- Put an enchant on an Enchanting Vellum and it becomes "Scroll of <name>",
-- which is a perfectly ordinary auction house item. So every enchant is costed
-- here as its scroll: the spell's reagents plus one vellum.
--
-- The cost side is exact and needs nothing from the server. The sell side needs
-- the scroll's own item id, and the client will not tell us one for an item it
-- has never seen - so that half fills in from scrolls you meet, or all at once
-- from Craft:ScanForScrolls().
function Craft:EnchantScrollName(enchantName)
    return "Scroll of "..enchantName
end

function Craft:EnchantRows()
    if not U then return {} end

    local cut      = AMS.Config:Cut()
    local vellum   = U:ItemInfo(VELLUM)
    local velPrice = vellum and buyPrice(vellum.id) or nil

    local out = {}
    for name, d in pairs(AMS.EnchantData or {}) do
        local cost, unpriced, mats = 0, 0, 0
        for i = 1, #d.r, 2 do
            mats = mats + 1
            local price = buyPrice(d.r[i])
            if price then cost = cost + price * d.r[i + 1] else unpriced = unpriced + 1 end
        end
        -- The vellum is not a spell reagent, but you cannot sell the enchant
        -- without one, so leaving it out would flatter every scroll.
        mats = mats + 1
        if velPrice then cost = cost + velPrice else unpriced = unpriced + 1 end

        local scrollID = (AMS.data.scrolls or {})[name]
        local outPrice = scrollID and sellPrice(scrollID) or nil
        local value    = outPrice and math.floor(outPrice * (1 - cut)) or nil
        local realCost = (unpriced == 0) and cost or nil

        local row = {
            id       = scrollID,
            enchant  = name,
            name     = self:EnchantScrollName(name),
            isEnchant= true,
            skill    = d.k,
            mats     = mats,
            made     = 1,
            known    = (AMS.data.enchants or {})[name] ~= nil,
            cost     = realCost,
            value    = value,
            unpriced = unpriced,
        }
        if realCost and value and realCost > 0 then
            row.profit = value - realCost
            row.roi    = row.profit / realCost
        end
        out[#out + 1] = row
    end
    return out
end

-- Harvest scroll item ids straight off the auction house. One partial-name
-- search for "Scroll of Enchant" returns every enchant scroll anyone has
-- listed, and each carries its item link - which is the id we could not
-- otherwise know. Anything nobody has listed stays unknown, which is honest:
-- an enchant with no scroll on the board has no market price either.
local SCROLL_PREFIX = "Scroll of "

function Craft:ScanForScrolls(onDone)
    if not AMS:AtAuctionHouse() then
        if onDone then onDone(nil, "open the auction house first") end
        return false
    end
    return AMS.Scanner:ScanItem("Scroll of Enchant", function(entries, err)
        if err then
            if onDone then onDone(nil, err) end
            return
        end
        local found, seen = 0, {}
        for _, e in ipairs(entries or {}) do
            if e.id and e.name and not seen[e.id] then
                seen[e.id] = true
                local enchName = e.name:match("^"..SCROLL_PREFIX.."(.+)$")
                if enchName and (AMS.EnchantData or {})[enchName]
                   and AMS.data.scrolls[enchName] ~= e.id then
                    AMS.data.scrolls[enchName] = e.id
                    found = found + 1
                end
            end
        end
        if found > 0 then
            Craft:InvalidateUsedIndex()
            AMS:Fire("CRAFT_CHANGED")
        end
        AMS:Print("scroll sweep: |cffffd070%d|r new scroll%s matched to an enchant.",
            found, found == 1 and "" or "s")
        if onDone then onDone(found) end
    end, { exact = false })
end

-- Everything one profession can make, costed. Best profit first, with anything
-- that cannot be priced sunk to the bottom rather than reading as a loss.
--
-- Cached: Blacksmithing alone is five hundred recipes and costing them all
-- means walking every route and every reagent. Doing that on each of the half
-- dozen events that redraw the tab is enough work to be felt. The cache is
-- dropped whenever recipes or prices change, which is the only time the answer
-- can differ.
local profRowCache = {}

function Craft:InvalidateProfRows() profRowCache = {} end

function Craft:RecipesForProfession(prof)
    if not U or not prof then return {} end
    if profRowCache[prof] then return profRowCache[prof] end
    if not profIndex then buildProfIndex() end

    local out = {}
    for _, id in ipairs(profIndex[prof] or {}) do
        local rp = self:GetRecipe(id)
        if rp then
            local e = self:EvaluateRecipe(id)
            -- Deliberately a plain lookup, not a request: a profession is five
            -- hundred rows and queueing all of them would ask the server for
            -- four hundred items nobody is looking at. The table resolves the
            -- twenty rows actually on screen as it draws them.
            local info = U:ItemInfo(id)
            out[#out+1] = {
                id      = id,
                name    = rp.name or (info and info.name),
                quality = info and info.quality,
                texture = info and info.texture,
                link    = info and info.link,
                skill   = rp.skill,
                mats    = #rp.reagents,
                made    = ((rp.madeMin or 1) + (rp.madeMax or 1)) / 2,
                known   = rp.known,
                cost    = e and e.cost,
                value   = e and e.value,
                profit  = e and e.profit,
                roi     = e and e.roi,
            }
        end
    end

    -- Enchanting's real inventory is its enchants, and none of them are items.
    -- Without this the profession lists wands and oils and nothing you would
    -- actually level it for.
    if prof == "Enchanting" then
        for _, row in ipairs(self:EnchantRows()) do out[#out + 1] = row end
    end

    table.sort(out, function(a, b)
        local pa, pb = a.profit or -math.huge, b.profit or -math.huge
        if pa ~= pb then return pa > pb end
        if a.known ~= b.known then return a.known end
        return (a.name or "") < (b.name or "")
    end)

    profRowCache[prof] = out
    return out
end

-- =============================================================================
-- Reverse lookup: what is this item used in?
-- =============================================================================
--
-- The recipe data read the other way round. Knowing that Nettlefish goes into
-- Fish Feast is easy; knowing the other six things it goes into, and which of
-- them is worth making today, is the part worth having. Any reagent can lead
-- you to a market you were not looking at.
--
-- Built once on first use - inverting three thousand recipes is cheap, but not
-- something to redo on every refresh.

local usedIndex

local function buildUsedIndex()
    usedIndex = {}
    local seen = {}
    local function add(reagentID, craftedID)
        local key = reagentID * 1000000 + craftedID
        if seen[key] then return end          -- two routes can share a reagent
        seen[key] = true
        local list = usedIndex[reagentID]
        if not list then list = {}; usedIndex[reagentID] = list end
        list[#list+1] = craftedID
    end

    for craftedID, routes in pairs(AMS.RecipeData or {}) do
        for _, d in ipairs(routes) do
            for i = 1, #d.r, 2 do add(d.r[i], craftedID) end
        end
    end

    -- Scrolls only have an item id once we have met one, so this half fills in
    -- as you look enchants up rather than being complete from the start.
    for enchName, itemID in pairs(AMS.data.scrolls or {}) do
        local d = (AMS.EnchantData or {})[enchName]
        if d then
            for i = 1, #d.r, 2 do add(d.r[i], itemID) end
        end
    end
end

-- a newly met scroll changes both indexes, so let them be rebuilt
function Craft:InvalidateUsedIndex()
    usedIndex = nil
    profIndex = nil
    self:InvalidateProfRows()
end

function Craft:UsedInCount(reagentID)
    if not usedIndex then buildUsedIndex() end
    local l = usedIndex[reagentID]
    return l and #l or 0
end

-- Every recipe that consumes this item, best first.
function Craft:UsedIn(reagentID)
    if not U or not reagentID then return {} end
    if not usedIndex then buildUsedIndex() end

    local out = {}
    for _, craftedID in ipairs(usedIndex[reagentID] or {}) do
        local rp = self:GetRecipe(craftedID)
        if rp then
            local need = 0
            for _, g in ipairs(rp.reagents) do
                if g.id == reagentID then need = g.count break end
            end
            local e = self:EvaluateRecipe(craftedID)
            -- lookup only; the table asks for the rows it actually draws
            local info = U:ItemInfo(craftedID)
            out[#out+1] = {
                id         = craftedID,
                name       = rp.name or (info and info.name),
                quality    = info and info.quality,
                texture    = info and info.texture,
                link       = info and info.link,
                profession = rp.profession,
                need       = need,
                known      = rp.known,
                cost       = e and e.cost,
                value      = e and e.value,
                profit     = e and e.profit,
                roi        = e and e.roi,
            }
        end
    end

    -- profitable first; unpriced sink to the bottom rather than looking bad
    table.sort(out, function(a, b)
        local pa, pb = a.profit or -math.huge, b.profit or -math.huge
        if pa ~= pb then return pa > pb end
        return (a.name or "") < (b.name or "")
    end)
    return out
end

-- Either kind, whichever this id is.
function Craft:EvaluateAny(id)
    if self:Get(id) then return self:Evaluate(id) end
    return self:EvaluateRecipe(id)
end

-- Everything that needs a price before the maths can be trusted.
function Craft:MissingPrices(id)
    local need = {}
    local rec = self:Get(id)
    if rec then
        if not buyPrice(id) then need[#need+1] = { id = id, name = rec.name } end
        for _, o in pairs(rec.outputs) do
            if not sellPrice(o.id) then need[#need+1] = { id = o.id, name = o.name } end
        end
        return need
    end

    local rp = self:GetRecipe(id)
    if rp then
        if not sellPrice(id) then need[#need+1] = { id = id, name = rp.name } end
        for _, g in ipairs(rp.reagents) do
            if not buyPrice(g.id) then need[#need+1] = { id = g.id, name = g.name } end
        end
    end
    return need
end

-- Every item involved in a conversion, for the "price it all" sweep.
function Craft:ItemsFor(id)
    local out = {}
    local rec = self:Get(id)
    if rec then
        out[#out+1] = { id = id, name = rec.name }
        for _, o in pairs(rec.outputs) do out[#out+1] = { id = o.id, name = o.name } end
        return out
    end
    local rp = self:GetRecipe(id)
    if rp then
        out[#out+1] = { id = id, name = rp.name }
        for _, g in ipairs(rp.reagents) do out[#out+1] = { id = g.id, name = g.name } end
    end
    return out
end
