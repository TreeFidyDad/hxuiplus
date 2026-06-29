require('common');
local imgui = require('imgui');
local fonts = require('fonts');
local primitives = require('primitives');
local statusHandler = require('statushandler');
local buffTable = require('bufftable');
local progressbar = require('progressbar');
local encoding = require('gdifonts.encoding');
local ashita_settings = require('settings');

local fullMenuWidth = {};
local fullMenuHeight = {};
local buffWindowX = {};
local debuffWindowX = {};

----------------------------------------------------------------
-- REGEN-GHOST STATE (party bars)
-- Per-member learning of HP restored by the Regen buff (status 42),
-- keyed by server id. Drives a green "ghost" preview on each party
-- HP bar so you can see incoming regen and avoid over-curing.
----------------------------------------------------------------
local REGEN_STATUS_ID   = 42;   -- FFXI status effect id for Regen
local REGEN_GHOST_TICKS = 3;    -- how many regen ticks to project ahead
local regenTrack = {};          -- [serverid] = { last_hp = n, deltas = {} }
local function MemberHasRegen(buffs)
    if buffs == nil or buffs == -1 then return false; end
    -- Self buffs are 0-indexed, party-member buffs are 1-indexed; scan both.
    for i = 0, 32 do
        if buffs[i] == REGEN_STATUS_ID then return true; end
    end
    return false;
end

----------------------------------------------------------------
-- SELF REGEN TIMER (memory-read, borrowed from statustimers)
-- Reads the real remaining duration of the player's own Regen buff
-- so the ghost can show the FULL HP regen will restore over its
-- remaining life (only available for self; party members expose
-- buff ids but not timers).
----------------------------------------------------------------
local REGEN_TICK_SECONDS = 3;          -- regen ticks every 3s
local INFINITE_DURATION  = 0x7FFFFFFF;
local regenUtcPtr        = nil;
local regenUtcInit       = false;
local function regenEnsureUtcPtr()
    if not regenUtcInit then
        regenUtcInit = true;
        pcall(function()
            regenUtcPtr = ashita.memory.find('FFXiMain.dll', 0,
                '8B0D????????8B410C8B49108D04808D04808D04808D04C1C3', 2, 0);
        end);
    end
    return regenUtcPtr;
end
-- Remaining seconds on the player's own Regen, or nil if unavailable.
local function GetSelfRegenSeconds()
    local ptr = regenEnsureUtcPtr();
    if ptr == nil or ptr == 0 then return nil; end
    local secs = nil;
    pcall(function()
        local player = AshitaCore:GetMemoryManager():GetPlayer();
        if player == nil then return; end
        local icons  = player:GetStatusIcons();
        local timers = player:GetStatusTimers();
        if icons == nil or timers == nil then return; end
        for j = 0, 31 do
            if icons[j + 1] == REGEN_STATUS_ID then
                local raw = timers[j + 1];
                if raw == INFINITE_DURATION then secs = -1; return; end
                local base = ashita.memory.read_uint32(ptr);
                base = ashita.memory.read_uint32(base);
                local nowStamp  = ashita.memory.read_uint32(base + 0x0C);
                local vanaBase  = 0x3C307D70;
                local comparand = (nowStamp - vanaBase) * 60;
                local real = raw - comparand;
                while real < -2147483648 do real = real + 0xFFFFFFFF; end
                if real < 1 then secs = 0; else secs = math.ceil(real / 60); end
                return;
            end
        end
    end);
    return secs;
end

-- local backgroundPrim = {};
local partyWindowPrim = {};
partyWindowPrim[1] = {
    background = {},
}
partyWindowPrim[2] = {
    background = {},
}
partyWindowPrim[3] = {
    background = {},
}

local selectionPrim;
local arrowPrim;
local partyTargeted;
local partySubTargeted;
local memberText = {};
local partyMaxSize = 6;
local memberTextCount = partyMaxSize * 3;

local borderConfig = nil;  -- no border for cleaner modern look

local bgImageKeys = { 'bg', 'tl', 'tr', 'br', 'bl' };
local bgTitleAtlasItemCount = 4;
local bgTitleItemHeight;
local loadedBg = nil;

local partyList = {};


local function getScale(partyIndex)
    if (partyIndex == 3) then
        return {
            x = gConfig.partyList3ScaleX,
            y = gConfig.partyList3ScaleY,
            icon = gConfig.partyList3JobIconScale,
        }
    elseif (partyIndex == 2) then
        return {
            x = gConfig.partyList2ScaleX,
            y = gConfig.partyList2ScaleY,
            icon = gConfig.partyList2JobIconScale,
        }
    else
        return {
            x = gConfig.partyListScaleX,
            y = gConfig.partyListScaleY,
            icon = gConfig.partyListJobIconScale,
        }
    end
end

local function showPartyTP(partyIndex)
    if (partyIndex == 3) then
        return gConfig.partyList3TP
    elseif (partyIndex == 2) then
        return gConfig.partyList2TP
    else
        return gConfig.partyListTP
    end
end

local function UpdateTextVisibilityByMember(memIdx, visible)

    memberText[memIdx].hp:SetVisible(visible);
    memberText[memIdx].mp:SetVisible(visible);
    memberText[memIdx].tp:SetVisible(visible);
    memberText[memIdx].name:SetVisible(visible);
end

local function UpdateTextVisibility(visible, partyIndex)
    if partyIndex == nil then
        for i = 0, memberTextCount - 1 do
            UpdateTextVisibilityByMember(i, visible);
        end
    else
        local firstPlayerIndex = (partyIndex - 1) * partyMaxSize;
        local lastPlayerIndex = firstPlayerIndex + partyMaxSize - 1;
        for i = firstPlayerIndex, lastPlayerIndex do
            UpdateTextVisibilityByMember(i, visible);
        end
    end

    for i = 1, 3 do
        if (partyIndex == nil or i == partyIndex) then
            partyWindowPrim[i].bgTitle.visible = visible and gConfig.showPartyListTitle;
            local backgroundPrim = partyWindowPrim[i].background;
            for _, k in ipairs(bgImageKeys) do
                backgroundPrim[k].visible = visible and backgroundPrim[k].exists;
            end
        end
    end
end

local function GetMemberInformation(memIdx)

    if (showConfig[1] and gConfig.partyListPreview) then
        local memInfo = {};
        memInfo.hpp = memIdx == 4 and 0.1 or memIdx == 2 and 0.5 or memIdx == 0 and 0.75 or 1;
        memInfo.maxhp = 1250;
        memInfo.hp = math.floor(memInfo.maxhp * memInfo.hpp);
        memInfo.mpp = memIdx == 1 and 0.1 or 0.75;
        memInfo.maxmp = 1000;
        memInfo.mp = math.floor(memInfo.maxmp * memInfo.mpp);
        memInfo.tp = 1500;
        memInfo.job = memIdx + 1;
        memInfo.level = 99;
        memInfo.targeted = memIdx == 4;
        memInfo.serverid = 0;
        memInfo.buffs = nil;
        memInfo.sync = false;
        memInfo.subTargeted = false;
        memInfo.zone = 100;
        memInfo.inzone = memIdx ~= 3;
        memInfo.name = 'Player ' .. (memIdx + 1);
        memInfo.leader = memIdx == 0 or memIdx == 6 or memIdx == 12;
        return memInfo
    end

    local party = AshitaCore:GetMemoryManager():GetParty();
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if (player == nil or party == nil or party:GetMemberIsActive(memIdx) == 0) then
        return nil;
    end

    local playerTarget = AshitaCore:GetMemoryManager():GetTarget();

    local partyIndex = math.ceil((memIdx + 1) / partyMaxSize);
    local partyLeaderId = nil
    if (partyIndex == 3) then
        partyLeaderId = party:GetAlliancePartyLeaderServerId3();
    elseif (partyIndex == 2) then
        partyLeaderId = party:GetAlliancePartyLeaderServerId2();
    else
        partyLeaderId = party:GetAlliancePartyLeaderServerId1();
    end

    local memberInfo = {};
    memberInfo.zone = party:GetMemberZone(memIdx);
    memberInfo.inzone = memberInfo.zone == party:GetMemberZone(0);
    memberInfo.name = party:GetMemberName(memIdx);
    memberInfo.leader = partyLeaderId == party:GetMemberServerId(memIdx);

    if (memberInfo.inzone == true) then
        memberInfo.hp = party:GetMemberHP(memIdx);
        memberInfo.hpp = party:GetMemberHPPercent(memIdx) / 100;
        memberInfo.maxhp = memberInfo.hp / memberInfo.hpp;
        memberInfo.mp = party:GetMemberMP(memIdx);
        memberInfo.mpp = party:GetMemberMPPercent(memIdx) / 100;
        memberInfo.maxmp = memberInfo.mp / memberInfo.mpp;
        memberInfo.tp = party:GetMemberTP(memIdx);
        memberInfo.job = party:GetMemberMainJob(memIdx);
        memberInfo.level = party:GetMemberMainJobLevel(memIdx);
        memberInfo.serverid = party:GetMemberServerId(memIdx);
        if (playerTarget ~= nil) then
            local t1, t2 = GetTargets();
            local sActive = GetSubTargetActive();
            local thisIdx = party:GetMemberTargetIndex(memIdx);
            memberInfo.targeted = (t1 == thisIdx and not sActive) or (t2 == thisIdx and sActive);
            memberInfo.subTargeted = (t1 == thisIdx and sActive);
            -- Distance for cure-range indicator
            if thisIdx and thisIdx > 0 and memIdx ~= 0 then
                pcall(function()
                    local ent = AshitaCore:GetMemoryManager():GetEntity()
                    local dist_sq = ent:GetDistance(thisIdx)
                    if dist_sq and dist_sq > 0 then
                        memberInfo.distance = math.sqrt(dist_sq)
                    end
                end)
            end
        else
            memberInfo.targeted = false;
            memberInfo.subTargeted = false;
        end
        if (memIdx == 0) then
            memberInfo.buffs = player:GetBuffs();
        else
            memberInfo.buffs = statusHandler.get_member_status(memberInfo.serverid);
        end
        memberInfo.sync = bit.band(party:GetMemberFlagMask(memIdx), 0x100) == 0x100;

    else
        memberInfo.hp = 0;
        memberInfo.hpp = 0;
        memberInfo.maxhp = 0;
        memberInfo.mp = 0;
        memberInfo.mpp = 0;
        memberInfo.maxmp = 0;
        memberInfo.tp = 0;
        memberInfo.job = '';
        memberInfo.level = '';
        memberInfo.targeted = false;
        memberInfo.serverid = 0;
        memberInfo.buffs = nil;
        memberInfo.sync = false;
        memberInfo.subTargeted = false;
    end

    return memberInfo;
end

local function DrawMember(memIdx, settings)

    local memInfo = GetMemberInformation(memIdx);
    if (memInfo == nil) then
        -- dummy data to render an empty space
        memInfo = {};
        memInfo.hp = 0;
        memInfo.hpp = 0;
        memInfo.maxhp = 0;
        memInfo.mp = 0;
        memInfo.mpp = 0;
        memInfo.maxmp = 0;
        memInfo.tp = 0;
        memInfo.job = '';
        memInfo.level = '';
        memInfo.targeted = false;
        memInfo.serverid = 0;
        memInfo.buffs = nil;
        memInfo.sync = false;
        memInfo.subTargeted = false;
        memInfo.zone = '';
        memInfo.inzone = false;
        memInfo.name = '';
        memInfo.leader = false;
    end

    local partyIndex = math.ceil((memIdx + 1) / partyMaxSize);
    local scale = getScale(partyIndex);
    local showTP = showPartyTP(partyIndex);

    local subTargetActive = GetSubTargetActive();
    local nameSize = SIZE.new();
    local hpSize = SIZE.new();
    memberText[memIdx].name:GetTextSize(nameSize);
    memberText[memIdx].hp:GetTextSize(hpSize);

    -- Get the hp color for bars and text
    local hpNameColor, hpGradient = GetHpColors(memInfo.hpp);

    local bgGradientOverride = {'#0a0f1a', '#101825'};

    local hpBarWidth = settings.hpBarWidth * scale.x;
    local mpBarWidth = settings.mpBarWidth * scale.x;
    local tpBarWidth = settings.tpBarWidth * scale.x;
    local barHeight = settings.barHeight * scale.y;

    local allBarsLengths = hpBarWidth + mpBarWidth + imgui.GetStyle().FramePadding.x + imgui.GetStyle().ItemSpacing.x;
    if (showTP) then
        allBarsLengths = allBarsLengths + tpBarWidth + imgui.GetStyle().FramePadding.x + imgui.GetStyle().ItemSpacing.x;
    end

    local hpStartX, hpStartY = imgui.GetCursorScreenPos();

    -- Draw the job icon before we draw anything else
    local namePosX = hpStartX;
    local jobIconSize = settings.iconSize * 1.1 * scale.icon;
    local offsetStartY = hpStartY - jobIconSize - settings.nameTextOffsetY;
    imgui.SetCursorScreenPos({namePosX, offsetStartY});
    local jobIcon = statusHandler.GetJobIcon(memInfo.job);
    if (jobIcon ~= nil) then
        namePosX = namePosX + jobIconSize + settings.nameTextOffsetX;
        imgui.Image(jobIcon, {jobIconSize, jobIconSize});
    end
    imgui.SetCursorScreenPos({hpStartX, hpStartY});

    -- Update the hp text
    memberText[memIdx].hp:SetColor(hpNameColor);
    memberText[memIdx].hp:SetPositionX(hpStartX + hpBarWidth + settings.hpTextOffsetX);
    memberText[memIdx].hp:SetPositionY(hpStartY + barHeight + settings.hpTextOffsetY);
    memberText[memIdx].hp:SetText(tostring(memInfo.hp));

    -- Draw the HP bar
    if (memInfo.inzone) then
        progressbar.ProgressBar({{memInfo.hpp, hpGradient}}, {hpBarWidth, barHeight}, {borderConfig=nil, backgroundGradientOverride=bgGradientOverride, decorate = false});

        ----------------------------------------------------------------
        -- BEGIN HUNTPARTNER CURE GHOST BAR PATCH (re-apply after HXUI update)
        -- Subtle gradient ghost fill showing projected cure amount.
        -- Fades from left to right for a soft look. Slightly brighter
        -- edge-line at the projected endpoint. No chunky rectangles.
        ----------------------------------------------------------------
        do
            local hp_cur = memInfo.hp or 0
            local hp_max = memInfo.maxhp or 0
            local is_mp_user = (memInfo.maxmp or 0) > 0

            -- Read file-based IPC from HuntPartner (cross-addon safe)
            local casting_on_me = false
            local casting_tier = nil
            local now = os.clock()
            pcall(function()
                local ipc_path = AshitaCore:GetInstallPath() .. 'addons\\huntpartner\\cast_ipc.txt'
                local f = io.open(ipc_path, 'r')
                if f then
                    local data = f:read('*a')
                    f:close()
                    if data and #data > 0 then
                        local tgt, tier_s, ts_s = data:match('^(.-)%|(%d+)%|(%d+)$')
                        if tgt and tgt == memInfo.name then
                            local ts = tonumber(ts_s) or 0
                            if (os.time() - ts) <= 8 then
                                casting_on_me = true
                                casting_tier = tonumber(tier_s)
                            end
                        end
                    end
                end
            end)

            -- Read learned heal amounts from file
            local heal1, heal2 = 30, 120
            pcall(function()
                local heals_path = AshitaCore:GetInstallPath() .. 'addons\\huntpartner\\heals_ipc.txt'
                local f = io.open(heals_path, 'r')
                if f then
                    for line in f:lines() do
                        local t, v = line:match('^(%d+)%|(%d+)$')
                        if t == '1' and tonumber(v) > 0 then heal1 = tonumber(v) end
                        if t == '2' and tonumber(v) > 0 then heal2 = tonumber(v) end
                    end
                    f:close()
                end
            end)

            -- Read skip config from file (fallback: no skips)
            local skip_name = false

            -- Show ghost bar if member is missing HP OR if we're casting on them
            if skip_name then
                -- no ghost bar for this member
            elseif hp_max > 0 and hp_cur > 0 and (memInfo.hpp < 1.0 or casting_on_me) then
                local missing = math.max(1, hp_max - hp_cur)
                local dl
                pcall(function() dl = imgui.GetWindowDrawList() end)
                if dl then

                    local rec_tier, alt_tier
                    if heal1 >= missing * 0.8 then
                        rec_tier = 1; alt_tier = 2
                    else
                        rec_tier = 2; alt_tier = 1
                    end
                    local rec_heal = (rec_tier == 1) and heal1 or heal2
                    local alt_heal = (alt_tier == 1) and heal1 or heal2

                    local cur_frac = hp_cur / hp_max
                    local rec_proj = math.min(1.0, (hp_cur + rec_heal) / hp_max)
                    local alt_proj = math.min(1.0, (hp_cur + alt_heal) / hp_max)
                    local start_x = hpStartX + hpBarWidth * cur_frac
                    local rec_end = hpStartX + hpBarWidth * rec_proj
                    local alt_end = hpStartX + hpBarWidth * alt_proj

                    -- Ghost fill: brighter + pulsing when actively casting on this target
                    local base_alpha = casting_on_me and (0.55 + 0.25 * math.abs(math.sin(now * 5.0))) or 0.40
                    local inset = 2

                    -- If actively casting on this target, override fill to show the ACTUAL
                    -- tier being cast (WoW-style incoming heal preview)
                    local show_heal = rec_heal
                    local show_tier = rec_tier
                    if casting_on_me and casting_tier then
                        show_heal = (casting_tier == 1) and heal1 or heal2
                        show_tier = casting_tier
                        -- Recalculate projection for the actual casting tier
                        rec_proj = math.min(1.0, (hp_cur + show_heal) / hp_max)
                        rec_end = hpStartX + hpBarWidth * rec_proj
                    end

                    -- Waste calculation for recommended tier
                    local rec_waste = math.max(0, rec_heal - missing)
                    local rec_waste_frac = (rec_heal > 0) and (rec_waste / rec_heal) or 0
                    -- Color: green if efficient, orange if some waste, red if mostly waste
                    local rec_col
                    if rec_waste_frac < 0.2 then
                        rec_col = { 0.3, 1.0, 0.5, 0.8 }   -- green = good
                    elseif rec_waste_frac < 0.5 then
                        rec_col = { 1.0, 0.8, 0.2, 0.8 }   -- orange = some waste
                    else
                        rec_col = { 1.0, 0.3, 0.2, 0.8 }   -- red = mostly waste
                    end

                    -- Fill color also shifts with waste
                    local fill_r = 0.85 * (1.0 - rec_waste_frac) + 1.0 * rec_waste_frac
                    local fill_g = 0.95 * (1.0 - rec_waste_frac) + 0.4 * rec_waste_frac
                    local fill_b = 1.0 * (1.0 - rec_waste_frac) + 0.3 * rec_waste_frac
                    dl:AddRectFilled(
                        { start_x, hpStartY + inset },
                        { rec_end, hpStartY + barHeight - inset },
                        imgui.GetColorU32({ fill_r, fill_g, fill_b, base_alpha }))

                    -- Endpoint line + colored label with heal amount
                    dl:AddLine(
                        { rec_end, hpStartY + inset },
                        { rec_end, hpStartY + barHeight - inset },
                        imgui.GetColorU32(rec_col), 2)
                    local rec_label = 'C' .. rec_tier .. ' ' .. rec_heal
                    dl:AddText({ rec_end + 2, hpStartY + inset - 1 },
                        imgui.GetColorU32(rec_col), rec_label)

                    -- Alt tier line + label (same waste logic)
                    if math.abs(alt_proj - rec_proj) > 0.01 then
                        local alt_waste = math.max(0, alt_heal - missing)
                        local alt_waste_frac = (alt_heal > 0) and (alt_waste / alt_heal) or 0
                        local alt_col
                        if alt_waste_frac < 0.2 then
                            alt_col = { 0.3, 0.9, 0.5, 0.6 }
                        elseif alt_waste_frac < 0.5 then
                            alt_col = { 1.0, 0.75, 0.2, 0.6 }
                        else
                            alt_col = { 1.0, 0.3, 0.2, 0.6 }
                        end
                        dl:AddLine(
                            { alt_end, hpStartY + inset },
                            { alt_end, hpStartY + barHeight - inset },
                            imgui.GetColorU32(alt_col), 2)
                        local alt_label = 'C' .. alt_tier .. ' ' .. alt_heal
                        dl:AddText({ alt_end + 2, hpStartY + inset - 1 },
                            imgui.GetColorU32(alt_col), alt_label)
                    end

                    -- CASTING GLOW: pulsing border around the HP bar when healing this target
                    if casting_on_me then
                        local glow_alpha = 0.4 + 0.4 * math.abs(math.sin(now * 4.0))
                        dl:AddRect(
                            { hpStartX - 1, hpStartY - 1 },
                            { hpStartX + hpBarWidth + 1, hpStartY + barHeight + 1 },
                            imgui.GetColorU32({ 0.3, 1.0, 0.6, glow_alpha }), 2, 15, 2)
                    end
                end
            end
        end
        ----------------------------------------------------------------
        -- END HUNTPARTNER CURE GHOST BAR PATCH
        ----------------------------------------------------------------

        ----------------------------------------------------------------
        -- BEGIN REGEN GHOST (party bars)
        -- Green forward preview of HP the Regen buff (status 42) will
        -- restore over the next few ticks. Per-member rate is learned
        -- from observed HP gains while Regen is up, so you can tell when
        -- regen alone will top someone off and skip the cure.
        ----------------------------------------------------------------
        do
            local hp_cur = memInfo.hp or 0
            local hp_max = memInfo.maxhp or 0
            local key    = memInfo.serverid
            if key and hp_max > 0 and hp_cur > 0 and MemberHasRegen(memInfo.buffs) then
                local st = regenTrack[key]
                if st == nil then
                    st = { last_hp = hp_cur, deltas = {} }
                    regenTrack[key] = st
                elseif hp_cur > st.last_hp then
                    -- HP went up: record the gain as a regen tick (ignore big
                    -- jumps, which are cures rather than regen ticks).
                    local d = hp_cur - st.last_hp
                    local tickCap = math.max(60, hp_max * 0.12)
                    if d <= tickCap then
                        table.insert(st.deltas, d)
                        while #st.deltas > 5 do table.remove(st.deltas, 1) end
                    end
                    st.last_hp = hp_cur
                elseif hp_cur < st.last_hp then
                    -- Took damage: reset baseline, keep the learned rate.
                    st.last_hp = hp_cur
                end

                local avg = nil
                if #st.deltas > 0 then
                    local s = 0
                    for _, v in ipairs(st.deltas) do s = s + v end
                    avg = s / #st.deltas
                end

                if avg and avg > 0 and memInfo.hpp < 1.0 then
                    local dl
                    pcall(function() dl = imgui.GetWindowDrawList() end)
                    if dl then
                        -- For self, project the FULL remaining regen based on
                        -- the buff's real time left (ticks shrink each tick).
                        -- For other members, fall back to a fixed look-ahead.
                        local ticks  = REGEN_GHOST_TICKS
                        local secs   = nil
                        if memIdx == 0 then
                            secs = GetSelfRegenSeconds()
                            if secs == -1 then
                                secs = nil -- infinite/unknown, keep fallback
                            elseif secs and secs > 0 then
                                ticks = math.max(1, math.floor(secs / REGEN_TICK_SECONDS + 0.5))
                            elseif secs == 0 then
                                ticks = 0
                            end
                        end

                        if ticks > 0 then
                            local projHeal = avg * ticks
                            local capped   = math.min(projHeal, hp_max - hp_cur)
                            local cur_frac = hp_cur / hp_max
                            local proj     = math.min(1.0, (hp_cur + projHeal) / hp_max)
                            local start_x  = hpStartX + hpBarWidth * cur_frac
                            local end_x    = hpStartX + hpBarWidth * proj
                            local inset    = 2
                            if end_x > start_x + 1 then
                                dl:AddRectFilled(
                                    { start_x, hpStartY + inset },
                                    { end_x, hpStartY + barHeight - inset },
                                    imgui.GetColorU32({ 0.40, 0.95, 0.45, 0.28 }))
                                dl:AddLine(
                                    { end_x, hpStartY + inset },
                                    { end_x, hpStartY + barHeight - inset },
                                    imgui.GetColorU32({ 0.55, 1.00, 0.60, 0.85 }), 1.5)
                                local label
                                if memIdx == 0 and secs and secs > 0 then
                                    label = ('R+%d  %ds'):format(math.floor(capped + 0.5), secs)
                                else
                                    label = ('R+%d'):format(math.floor(capped + 0.5))
                                end
                                dl:AddText({ end_x + 2, hpStartY + barHeight - 9 },
                                    imgui.GetColorU32({ 0.70, 1.00, 0.72, 0.90 }), label)
                            end
                        end
                    end
                end
            elseif key then
                -- Regen not present: forget learned rate so it recalibrates
                -- cleanly next time Regen is applied.
                regenTrack[key] = nil
            end
        end
        ----------------------------------------------------------------
        -- END REGEN GHOST (party bars)
        ----------------------------------------------------------------

        ----------------------------------------------------------------
        -- BEGIN HUNTPARTNER PREDICTED DAMAGE BAR
        -- Shows a red ghost region on the HP bar representing predicted
        -- incoming damage from the current mob (based on learned avg).
        -- Pulses red when the next swing is imminent.
        ----------------------------------------------------------------
        do
            local now_dmg = os.clock()
            pcall(function()
                local dmg_path = AshitaCore:GetInstallPath() .. 'addons\\huntpartner\\dmg_ipc.txt'
                local f = io.open(dmg_path, 'r')
                if f then
                    local data = f:read('*a')
                    f:close()
                    if data and #data > 0 then
                        local tgt, avg_s, max_s, swing_s, last_s, mob = data:match('^(.-)%|(%d+)%|(%d+)%|([%d%.]+)%|([%d%.]+)%|(.+)$')
                        if tgt and tgt == memInfo.name then
                            local avg_dmg = tonumber(avg_s) or 0
                            local max_dmg = tonumber(max_s) or 0
                            local swing_int = tonumber(swing_s) or 0
                            local last_hit = tonumber(last_s) or 0
                            local hp_cur = memInfo.hp or 0
                            local hp_max = memInfo.maxhp or 0
                            -- Expire if no hit for 3 swing cycles (or 15s if no swing data)
                            -- Also reject negative age (clock mismatch after addon reload)
                            local stale_limit = (swing_int > 0) and (swing_int * 3) or 15
                            local age = now_dmg - last_hit
                            if avg_dmg > 0 and hp_max > 0 and hp_cur > 0 and age >= 0 and age < stale_limit then
                                local dl_d
                                pcall(function() dl_d = imgui.GetWindowDrawList() end)
                                if dl_d then
                                    local cur_frac = hp_cur / hp_max
                                    local dmg_frac = avg_dmg / hp_max
                                    local proj_frac = math.max(0, cur_frac - dmg_frac)

                                    -- How close to next swing? (for pulse intensity)
                                    local urgency = 0
                                    if swing_int > 0 and last_hit > 0 then
                                        local elapsed = now_dmg - last_hit
                                        local cycle = elapsed / swing_int
                                        cycle = cycle - math.floor(cycle)
                                        urgency = cycle  -- 0=just hit, 1=about to hit
                                    end

                                    -- Red ghost from projected HP down to current HP edge
                                    local base_a = 0.15 + 0.30 * urgency
                                    local pulse_a = base_a + 0.15 * math.abs(math.sin(now_dmg * 3.0)) * urgency
                                    local ghost_start = hpStartX + hpBarWidth * proj_frac
                                    local ghost_end = hpStartX + hpBarWidth * cur_frac
                                    local inset_d = 2

                                    if ghost_end > ghost_start + 1 then
                                        dl_d:AddRectFilled(
                                            { ghost_start, hpStartY + inset_d },
                                            { ghost_end, hpStartY + barHeight - inset_d },
                                            imgui.GetColorU32({ 1.0, 0.2, 0.15, pulse_a }))
                                        -- Edge line at predicted post-hit HP
                                        dl_d:AddLine(
                                            { ghost_start, hpStartY + inset_d },
                                            { ghost_start, hpStartY + barHeight - inset_d },
                                            imgui.GetColorU32({ 1.0, 0.3, 0.2, 0.7 }), 2)
                                        -- Small damage label
                                        local dmg_label = '-' .. tostring(avg_dmg)
                                        dl_d:AddText({ ghost_start - 2, hpStartY - 10 },
                                            imgui.GetColorU32({ 1.0, 0.4, 0.3, 0.6 + 0.3 * urgency }), dmg_label)
                                    end
                                end
                            end
                        end
                    end
                end
            end)
        end
        ----------------------------------------------------------------
        -- END HUNTPARTNER PREDICTED DAMAGE BAR
        ----------------------------------------------------------------

        ----------------------------------------------------------------
        -- HUNTPARTNER CURE-RANGE INDICATOR
        -- Dims the HP bar and shows a range tag when party member is
        -- beyond cure range (21 yalms). Subtle fade at 18-21y warning.
        ----------------------------------------------------------------
        if memInfo.distance then
            local CURE_RANGE = 20.9
            local WARN_RANGE = 17.0
            if memInfo.distance > WARN_RANGE then
                local dl_r
                pcall(function() dl_r = imgui.GetWindowDrawList() end)
                if dl_r then
                    local out = memInfo.distance > CURE_RANGE
                    local alpha = out and 0.45 or (0.25 * ((memInfo.distance - WARN_RANGE) / (CURE_RANGE - WARN_RANGE)))
                    -- Dark overlay to dim the bar
                    dl_r:AddRectFilled(
                        { hpStartX, hpStartY },
                        { hpStartX + hpBarWidth, hpStartY + barHeight },
                        imgui.GetColorU32({ 0.0, 0.0, 0.0, alpha }))
                    -- Range text
                    if out then
                        local range_txt = string.format('%.0fy', memInfo.distance)
                        dl_r:AddText(
                            { hpStartX + hpBarWidth - 28, hpStartY + 1 },
                            imgui.GetColorU32({ 1.0, 0.4, 0.3, 0.8 }), range_txt)
                    end
                end
            end
        end
        ----------------------------------------------------------------

        ----------------------------------------------------------------
        -- HUNTPARTNER REST ETA OVERLAY (player only, memIdx == 0)
        -- Shows "Full in Xm XXs" below the HP bar when resting.
        ----------------------------------------------------------------
        if memIdx == 0 then
            pcall(function()
                local rest_path = AshitaCore:GetInstallPath() .. 'addons\\huntpartner\\rest_ipc.txt'
                local rf = io.open(rest_path, 'r')
                if rf then
                    local data = rf:read('*a')
                    rf:close()
                    if data and data:sub(1,1) == '1' then
                        local parts = {}
                        for p in data:gmatch('[^|]+') do parts[#parts+1] = p end
                        -- parts: 1=active, 2=hp_avg, 3=mp_avg, 4=hp_tick_eta, 5=mp_tick_eta, 6=hp_full_secs, 7=mp_full_secs, 8=ts
                        local hp_avg = tonumber(parts[2]) or 0
                        local mp_avg = tonumber(parts[3]) or 0
                        local hp_tick_eta = tonumber(parts[4]) or 0
                        local mp_tick_eta = tonumber(parts[5]) or 0
                        local hp_full = tonumber(parts[6]) or 0
                        local mp_full = tonumber(parts[7]) or 0
                        local ipc_ts = tonumber(parts[8]) or 0
                        -- Only show if IPC is fresh (within 2s)
                        local age = os.clock() - ipc_ts
                        if age < 2.0 then
                            local dl = imgui.GetForegroundDrawList()
                            local text_y = hpStartY + barHeight + 2
                            local text_x = hpStartX
                            -- Format HP full time
                            local function fmt_secs(s)
                                if s <= 0 then return 'FULL' end
                                local m = math.floor(s / 60)
                                local sec = s % 60
                                if m > 0 then return string.format('%dm%02ds', m, sec) end
                                return string.format('%ds', sec)
                            end
                            local label = ''
                            if hp_full > 0 then
                                label = string.format('+%d HP \xC2\xB7 Full %s \xC2\xB7 tick %.0fs', hp_avg, fmt_secs(hp_full), hp_tick_eta)
                            elseif hp_avg > 0 then
                                label = 'HP FULL'
                            end
                            if label ~= '' then
                                -- Draw with shadow
                                dl:AddText({ text_x + 1, text_y + 1 }, imgui.GetColorU32({ 0, 0, 0, 0.9 }), label)
                                dl:AddText({ text_x, text_y }, imgui.GetColorU32({ 0.6, 0.95, 0.6, 1.0 }), label)
                            end
                            -- MP line if applicable
                            if mp_avg > 0 then
                                local mp_label = ''
                                if mp_full > 0 then
                                    mp_label = string.format('+%d MP \xC2\xB7 Full %s \xC2\xB7 tick %.0fs', mp_avg, fmt_secs(mp_full), mp_tick_eta)
                                else
                                    mp_label = 'MP FULL'
                                end
                                local mp_y = text_y + 14
                                dl:AddText({ text_x + 1, mp_y + 1 }, imgui.GetColorU32({ 0, 0, 0, 0.9 }), mp_label)
                                dl:AddText({ text_x, mp_y }, imgui.GetColorU32({ 0.6, 0.85, 0.95, 1.0 }), mp_label)
                            end
                        end
                    end
                end
            end)
        end
        ----------------------------------------------------------------
        -- END HUNTPARTNER REST ETA
        ----------------------------------------------------------------

    elseif (memInfo.zone == '' or memInfo.zone == nil) then
        imgui.Dummy({allBarsLengths, barHeight});
    else
        imgui.ProgressBar(0, {allBarsLengths, barHeight}, encoding:ShiftJIS_To_UTF8(AshitaCore:GetResourceManager():GetString("zones.names", memInfo.zone), true));
    end

    -- Draw the leader icon
    if (memInfo.leader) then
        draw_circle({hpStartX + settings.dotRadius/2, hpStartY + settings.dotRadius/2}, settings.dotRadius, {1, 1, .5, 1}, settings.dotRadius * 3, true);
    end

    -- Update the name text
    memberText[memIdx].name:SetColor(0xFFFFFFFF);
    memberText[memIdx].name:SetPositionX(namePosX);
    memberText[memIdx].name:SetPositionY(hpStartY - nameSize.cy - settings.nameTextOffsetY);
    memberText[memIdx].name:SetText(tostring(memInfo.name));

    local nameSize = SIZE.new();
    memberText[memIdx].name:GetTextSize(nameSize);
    local offsetSize = nameSize.cy > settings.iconSize and nameSize.cy or settings.iconSize;

    if (memInfo.inzone) then
        imgui.SameLine();

        -- Draw the MP bar
        local mpStartX, mpStartY;
        imgui.SetCursorPosX(imgui.GetCursorPosX());
        mpStartX, mpStartY = imgui.GetCursorScreenPos();
        progressbar.ProgressBar({{memInfo.mpp, {'#2563eb', '#60a5fa'}}}, {mpBarWidth, barHeight}, {borderConfig=nil, backgroundGradientOverride=bgGradientOverride, decorate = false});

        -- Update the mp text
        memberText[memIdx].mp:SetColor(gAdjustedSettings.mpColor);
        memberText[memIdx].mp:SetPositionX(mpStartX + mpBarWidth + settings.mpTextOffsetX);
        memberText[memIdx].mp:SetPositionY(mpStartY + barHeight + settings.mpTextOffsetY);
        memberText[memIdx].mp:SetText(tostring(memInfo.mp));

        -- Draw the TP bar
        if (showTP) then
            imgui.SameLine();
            local tpStartX, tpStartY;
            imgui.SetCursorPosX(imgui.GetCursorPosX());
            tpStartX, tpStartY = imgui.GetCursorScreenPos();

            -- HUNTPARTNER COLOR PATCH: orange TP to match player bar
            local tpGradient = {'#d68a1e', '#f0b85a'};
            local tpOverlayGradient = {'#b86b00', '#b86b00'};
            local mainPercent;
            local tpOverlay;
            
            if (memInfo.tp >= 1000) then
                mainPercent = (memInfo.tp - 1000) / 2000;
                tpOverlay = {{1, tpOverlayGradient}, math.ceil(barHeight * 2/7), 1};
            else
                mainPercent = memInfo.tp / 1000;
            end
            
            progressbar.ProgressBar({{mainPercent, tpGradient}}, {tpBarWidth, barHeight}, {overlayBar=tpOverlay, borderConfig=nil, backgroundGradientOverride=bgGradientOverride, decorate = false});

            -- Update the tp text
            if (memInfo.tp >= 1000) then
                memberText[memIdx].tp:SetColor(gAdjustedSettings.tpFullColor);
            else
                memberText[memIdx].tp:SetColor(gAdjustedSettings.tpEmptyColor);
            end
            memberText[memIdx].tp:SetPositionX(tpStartX + tpBarWidth + settings.tpTextOffsetX);
            memberText[memIdx].tp:SetPositionY(tpStartY + barHeight + settings.tpTextOffsetY);
            memberText[memIdx].tp:SetText(tostring(memInfo.tp));
        end

        local entrySize = hpSize.cy + offsetSize + settings.hpTextOffsetY + barHeight + settings.cursorPaddingY1 + settings.cursorPaddingY2;
        if (memInfo.targeted == true) then
            selectionPrim.visible = true;
            selectionPrim.position_x = hpStartX - settings.cursorPaddingX1;
            selectionPrim.position_y = hpStartY - offsetSize - settings.cursorPaddingY1;
            selectionPrim.scale_x = (allBarsLengths + settings.cursorPaddingX1 + settings.cursorPaddingX2) / 346;
            selectionPrim.scale_y = entrySize / 108;
            partyTargeted = true;
        end

        -- Draw subtargeted
        if ((memInfo.targeted == true and not subTargetActive) or memInfo.subTargeted) then
            arrowPrim.visible = true;
            local newArrowX =  memberText[memIdx].name:GetPositionX() - arrowPrim:GetWidth();
            if (jobIcon ~= nil) then
                newArrowX = newArrowX - jobIconSize;
            end
            arrowPrim.position_x = newArrowX;
            arrowPrim.position_y = (hpStartY - offsetSize - settings.cursorPaddingY1) + (entrySize/2) - arrowPrim:GetHeight()/2;
            arrowPrim.scale_x = settings.arrowSize;
            arrowPrim.scale_y = settings.arrowSize;
            if (subTargetActive) then
                arrowPrim.color = settings.subtargetArrowTint;
            else
                arrowPrim.color = 0xFFFFFFFF;
            end
            partySubTargeted = true;
        end

        -- Draw the different party list buff / debuff themes
        if (partyIndex == 1 and memInfo.buffs ~= nil and #memInfo.buffs > 0) then
            if (gConfig.partyListStatusTheme == 0 or gConfig.partyListStatusTheme == 1) then
                local buffs = {};
                local debuffs = {};
                for i = 0, #memInfo.buffs do
                    if (buffTable.IsBuff(memInfo.buffs[i])) then
                        table.insert(buffs, memInfo.buffs[i]);
                    else
                        table.insert(debuffs, memInfo.buffs[i]);
                    end
                end

                if (buffs ~= nil and #buffs > 0) then
                    if (gConfig.partyListStatusTheme == 0 and buffWindowX[memIdx] ~= nil) then
                        imgui.SetNextWindowPos({hpStartX - buffWindowX[memIdx] - settings.buffOffset , hpStartY - settings.iconSize*1.2});
                    elseif (gConfig.partyListStatusTheme == 1 and fullMenuWidth[partyIndex] ~= nil) then
                        local thisPosX, _ = imgui.GetWindowPos();
                        imgui.SetNextWindowPos({ thisPosX + fullMenuWidth[partyIndex], hpStartY - settings.iconSize * 1.2 });
                    end
                    if (imgui.Begin('PlayerBuffs'..memIdx, true, bit.bor(ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav, ImGuiWindowFlags_NoBackground, ImGuiWindowFlags_NoSavedSettings))) then
                        imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {3, 1});
                        DrawStatusIcons(buffs, settings.iconSize, 32, 1, true);
                        imgui.PopStyleVar(1);
                    end
                    local buffWindowSizeX, _ = imgui.GetWindowSize();
                    buffWindowX[memIdx] = buffWindowSizeX;
    
                    imgui.End();
                end

                if (debuffs ~= nil and #debuffs > 0) then
                    if (gConfig.partyListStatusTheme == 0 and debuffWindowX[memIdx] ~= nil) then
                        imgui.SetNextWindowPos({hpStartX - debuffWindowX[memIdx] - settings.buffOffset , hpStartY});
                    elseif (gConfig.partyListStatusTheme == 1 and fullMenuWidth[partyIndex] ~= nil) then
                        local thisPosX, _ = imgui.GetWindowPos();
                        imgui.SetNextWindowPos({ thisPosX + fullMenuWidth[partyIndex], hpStartY });
                    end
                    if (imgui.Begin('PlayerDebuffs'..memIdx, true, bit.bor(ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav, ImGuiWindowFlags_NoBackground, ImGuiWindowFlags_NoSavedSettings))) then
                        imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {3, 1});
                        DrawStatusIcons(debuffs, settings.iconSize, 32, 1, true);
                        imgui.PopStyleVar(1);
                    end
                    local buffWindowSizeX, buffWindowSizeY = imgui.GetWindowSize();
                    debuffWindowX[memIdx] = buffWindowSizeX;
                    imgui.End();
                end
            elseif (gConfig.partyListStatusTheme == 2) then
                -- Draw FFXIV theme
                local resetX, resetY = imgui.GetCursorScreenPos();
                imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, {0, 0} );
                imgui.SetNextWindowPos({mpStartX, mpStartY - settings.iconSize - settings.xivBuffOffsetY})
                if (imgui.Begin('XIVStatus'..memIdx, true, bit.bor(ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav, ImGuiWindowFlags_NoBackground, ImGuiWindowFlags_NoSavedSettings))) then
                    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {0, 0});
                    DrawStatusIcons(memInfo.buffs, settings.iconSize, 32, 1);
                    imgui.PopStyleVar(1);
                end
                imgui.PopStyleVar(1);
                imgui.End();
                imgui.SetCursorScreenPos({resetX, resetY});
            elseif (gConfig.partyListStatusTheme == 3) then
                if (buffWindowX[memIdx] ~= nil) then
                    imgui.SetNextWindowPos({hpStartX - buffWindowX[memIdx] - settings.buffOffset , memberText[memIdx].name:GetPositionY() - settings.iconSize/2});
                end
                if (imgui.Begin('PlayerBuffs'..memIdx, true, bit.bor(ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav, ImGuiWindowFlags_NoBackground, ImGuiWindowFlags_NoSavedSettings))) then
                    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {0, 3});
                    DrawStatusIcons(memInfo.buffs, settings.iconSize, 7, 3);
                    imgui.PopStyleVar(1);
                end
                local buffWindowSizeX, _ = imgui.GetWindowSize();
                buffWindowX[memIdx] = buffWindowSizeX;

                imgui.End();
            end
        end
    end

    if (memInfo.sync) then
        draw_circle({hpStartX + settings.dotRadius/2, hpStartY + barHeight}, settings.dotRadius, {.5, .5, 1, 1}, settings.dotRadius * 3, true);
    end

    memberText[memIdx].hp:SetVisible(memInfo.inzone);
    memberText[memIdx].mp:SetVisible(memInfo.inzone);
    memberText[memIdx].tp:SetVisible(memInfo.inzone and showTP);

    if (memInfo.inzone) then
        imgui.Dummy({0, settings.entrySpacing[partyIndex] + hpSize.cy + settings.hpTextOffsetY + settings.nameTextOffsetY});
    else
        imgui.Dummy({0, settings.entrySpacing[partyIndex] + settings.nameTextOffsetY});
    end

    local lastPlayerIndex = (partyIndex * 6) - 1;
    if (memIdx + 1 <= lastPlayerIndex) then
        imgui.Dummy({0, offsetSize});
    end
end

partyList.DrawWindow = function(settings)

    -- Obtain the player entity..
    local party = AshitaCore:GetMemoryManager():GetParty();
    local player = AshitaCore:GetMemoryManager():GetPlayer();

	if (party == nil or player == nil or player.isZoning or player:GetMainJob() == 0) then
		UpdateTextVisibility(false);
		return;
	end

    partyTargeted = false;
    partySubTargeted = false;

    -- Main party window
    partyList.DrawPartyWindow(settings, party, 1);

    -- Alliance party windows
    if (gConfig.partyListAlliance) then
        partyList.DrawPartyWindow(settings, party, 2);
        partyList.DrawPartyWindow(settings, party, 3);
    else
        UpdateTextVisibility(false, 2);
        UpdateTextVisibility(false, 3);
    end

    selectionPrim.visible = partyTargeted;
    arrowPrim.visible = partySubTargeted;
end

partyList.DrawPartyWindow = function(settings, party, partyIndex)
    local firstPlayerIndex = (partyIndex - 1) * partyMaxSize;
    local lastPlayerIndex = firstPlayerIndex + partyMaxSize - 1;

    -- Get the party size by checking active members
    local partyMemberCount = 0;
    if (showConfig[1] and gConfig.partyListPreview) then
        partyMemberCount = partyMaxSize;
    else
        for i = firstPlayerIndex, lastPlayerIndex do
            if (party:GetMemberIsActive(i) ~= 0) then
                partyMemberCount = partyMemberCount + 1
            else
                break
            end
        end
    end

    if (partyIndex == 1 and not gConfig.showPartyListWhenSolo and partyMemberCount <= 1) then
		UpdateTextVisibility(false);
        return;
	end

    if(partyIndex > 1 and partyMemberCount == 0) then
        UpdateTextVisibility(false, partyIndex);
        return;
    end

    local bgTitlePrim = partyWindowPrim[partyIndex].bgTitle;
    local backgroundPrim = partyWindowPrim[partyIndex].background;

    -- Graphic has multiple titles
    -- 0 = Solo
    -- bgTitleItemHeight = Party
    -- bgTitleItemHeight*2 = Party B
    -- bgTitleItemHeight*3 = Party C
    if (partyIndex == 1) then
        bgTitlePrim.texture_offset_y = partyMemberCount == 1 and 0 or bgTitleItemHeight;
    else
        bgTitlePrim.texture_offset_y = bgTitleItemHeight * partyIndex
    end

    local imguiPosX, imguiPosY;

    local windowFlags = bit.bor(ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav, ImGuiWindowFlags_NoBackground, ImGuiWindowFlags_NoBringToFrontOnFocus);
    if (gConfig.lockPositions) then
        windowFlags = bit.bor(windowFlags, ImGuiWindowFlags_NoMove);
    end

    local windowName = 'PartyList';
    if (partyIndex > 1) then
        windowName = windowName .. partyIndex
    end

    local scale = getScale(partyIndex);
    local iconSize = 0; --settings.iconSize * scale.icon;

    -- Remove all padding and start our window
    imgui.PushStyleVar(ImGuiStyleVar_FramePadding, {0,0});
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { settings.barSpacing * scale.x, 0 });
    if (imgui.Begin(windowName, true, windowFlags)) then
        imguiPosX, imguiPosY = imgui.GetWindowPos();

        local nameSize = SIZE.new();
        memberText[(partyIndex - 1) * 6].name:GetTextSize(nameSize);
        local offsetSize = nameSize.cy > iconSize and nameSize.cy or iconSize;
        imgui.Dummy({0, settings.nameTextOffsetY + offsetSize});

        UpdateTextVisibility(true, partyIndex);

        for i = firstPlayerIndex, lastPlayerIndex do
            local relIndex = i - firstPlayerIndex
            if ((partyIndex == 1 and settings.expandHeight) or relIndex < partyMemberCount or relIndex < settings.minRows) then
                DrawMember(i, settings);
            else
                UpdateTextVisibilityByMember(i, false);
            end
        end
    end

    local menuWidth, menuHeight = imgui.GetWindowSize();

    fullMenuWidth[partyIndex] = menuWidth;
    fullMenuHeight[partyIndex] = menuHeight;

    -- if (fullMenuWidth[partyIndex] ~= nil and fullMenuHeight[partyIndex] ~= nil) then
        local bgWidth = fullMenuWidth[partyIndex] + (settings.bgPadding * 2);
        local bgHeight = fullMenuHeight[partyIndex] + (settings.bgPadding * 2);

        backgroundPrim.bg.visible = backgroundPrim.bg.exists;
        backgroundPrim.bg.position_x = imguiPosX - settings.bgPadding;
        backgroundPrim.bg.position_y = imguiPosY - settings.bgPadding;
        backgroundPrim.bg.width = math.ceil(bgWidth / gConfig.partyListBgScale);
        backgroundPrim.bg.height = math.ceil(bgHeight / gConfig.partyListBgScale);

        backgroundPrim.br.visible = backgroundPrim.br.exists;
        backgroundPrim.br.position_x = backgroundPrim.bg.position_x + bgWidth - math.floor((settings.borderSize * gConfig.partyListBgScale) - (settings.bgOffset * gConfig.partyListBgScale));
        backgroundPrim.br.position_y = backgroundPrim.bg.position_y + bgHeight - math.floor((settings.borderSize * gConfig.partyListBgScale) - (settings.bgOffset * gConfig.partyListBgScale));
        backgroundPrim.br.width = settings.borderSize;
        backgroundPrim.br.height = settings.borderSize;

        backgroundPrim.tr.visible = backgroundPrim.tr.exists;
        backgroundPrim.tr.position_x = backgroundPrim.br.position_x;
        backgroundPrim.tr.position_y = backgroundPrim.bg.position_y - settings.bgOffset * gConfig.partyListBgScale;
        backgroundPrim.tr.width = backgroundPrim.br.width;
        backgroundPrim.tr.height = math.ceil((backgroundPrim.br.position_y - backgroundPrim.tr.position_y) / gConfig.partyListBgScale);

        backgroundPrim.tl.visible = backgroundPrim.tl.exists;
        backgroundPrim.tl.position_x = backgroundPrim.bg.position_x - settings.bgOffset * gConfig.partyListBgScale;
        backgroundPrim.tl.position_y = backgroundPrim.tr.position_y
        backgroundPrim.tl.width = math.ceil((backgroundPrim.tr.position_x - backgroundPrim.tl.position_x) / gConfig.partyListBgScale);
        backgroundPrim.tl.height = backgroundPrim.tr.height;

        backgroundPrim.bl.visible = backgroundPrim.bl.exists;
        backgroundPrim.bl.position_x = backgroundPrim.tl.position_x;
        backgroundPrim.bl.position_y = backgroundPrim.br.position_y;
        backgroundPrim.bl.width = backgroundPrim.tl.width;
        backgroundPrim.bl.height = backgroundPrim.br.height;

        bgTitlePrim.visible = gConfig.showPartyListTitle;
        bgTitlePrim.position_x = imguiPosX + math.floor((bgWidth / 2) - (bgTitlePrim.width * bgTitlePrim.scale_x / 2));
        bgTitlePrim.position_y = imguiPosY - math.floor((bgTitlePrim.height * bgTitlePrim.scale_y / 2) + (2 / bgTitlePrim.scale_y));
    -- end

	imgui.End();
    imgui.PopStyleVar(2);

    if (settings.alignBottom and imguiPosX ~= nil) then
        -- Migrate old settings
        if (partyIndex == 1 and gConfig.partyListState ~= nil and gConfig.partyListState.x ~= nil) then
            local oldValues = gConfig.partyListState;
            gConfig.partyListState = {};
            gConfig.partyListState[partyIndex] = oldValues;
            ashita_settings.save();
        end

        if (gConfig.partyListState == nil) then
            gConfig.partyListState = {};
        end

        local partyListState = gConfig.partyListState[partyIndex];

        if (partyListState ~= nil) then
            -- Move window if size changed
            if (menuHeight ~= partyListState.height) then
                local newPosY = partyListState.y + partyListState.height - menuHeight;
                imguiPosY = newPosY; --imguiPosY + (partyListState.height - menuHeight]);
                imgui.SetWindowPos(windowName, { imguiPosX, imguiPosY });
            end
        end

        -- Update if the state changed
        if (partyListState == nil or
                imguiPosX ~= partyListState.x or imguiPosY ~= partyListState.y or
                menuWidth ~= partyListState.width or menuHeight ~= partyListState.height) then
            gConfig.partyListState[partyIndex] = {
                x = imguiPosX,
                y = imguiPosY,
                width = menuWidth,
                height = menuHeight,
            };
            ashita_settings.save();
        end
    end
end

partyList.Initialize = function(settings)
    -- Initialize all our font objects we need
    local name_font_settings = deep_copy_table(settings.name_font_settings);
    local hp_font_settings = deep_copy_table(settings.hp_font_settings);
    local mp_font_settings = deep_copy_table(settings.mp_font_settings);
    local tp_font_settings = deep_copy_table(settings.tp_font_settings);

    for i = 0, memberTextCount-1 do
        local partyIndex = math.ceil((i + 1) / partyMaxSize);

        local partyListFontOffset = gConfig.partyListFontOffset;
        if (partyIndex == 2) then
            partyListFontOffset = gConfig.partyList2FontOffset;
        elseif (partyIndex == 3) then
            partyListFontOffset = gConfig.partyList3FontOffset;
        end

        name_font_settings.font_height = math.max(settings.name_font_settings.font_height + partyListFontOffset, 1);
        hp_font_settings.font_height = math.max(settings.hp_font_settings.font_height + partyListFontOffset, 1);
        mp_font_settings.font_height = math.max(settings.mp_font_settings.font_height + partyListFontOffset, 1);
        tp_font_settings.font_height = math.max(settings.tp_font_settings.font_height + partyListFontOffset, 1);

        memberText[i] = {};
        memberText[i].name = fonts.new(name_font_settings);
        memberText[i].hp = fonts.new(hp_font_settings);
        memberText[i].mp = fonts.new(mp_font_settings);
        memberText[i].tp = fonts.new(tp_font_settings);
    end

    -- Initialize images
    loadedBg = nil;

    for i = 1, 3 do
        local backgroundPrim = {};

        for _, k in ipairs(bgImageKeys) do
            backgroundPrim[k] = primitives:new(settings.prim_data);
            backgroundPrim[k].visible = false;
            backgroundPrim[k].can_focus = false;
            backgroundPrim[k].exists = false;
        end

        partyWindowPrim[i].background = backgroundPrim;

        local bgTitlePrim = primitives.new(settings.prim_data);
        bgTitlePrim.color = 0xFFC5CFDC;
        bgTitlePrim.texture = string.format('%s/assets/PartyList-Titles.png', addon.path);
        bgTitlePrim.visible = false;
        bgTitlePrim.can_focus = false;
        bgTitleItemHeight = bgTitlePrim.height / bgTitleAtlasItemCount;
        bgTitlePrim.height = bgTitleItemHeight;

        partyWindowPrim[i].bgTitle = bgTitlePrim;
    end

    selectionPrim = primitives.new(settings.prim_data);
    selectionPrim.color = 0xFFFFFFFF;
    selectionPrim.texture = string.format('%s/assets/Selector.png', addon.path);
    selectionPrim.visible = false;
    selectionPrim.can_focus = false;

    arrowPrim = primitives.new(settings.prim_data);
    arrowPrim.color = 0xFFFFFFFF;
    arrowPrim.visible = false;
    arrowPrim.can_focus = false;

    partyList.UpdateFonts(settings);
end

partyList.UpdateFonts = function(settings)
    -- Update fonts
    for i = 0, memberTextCount-1 do
        local partyIndex = math.ceil((i + 1) / partyMaxSize);

        local partyListFontOffset = gConfig.partyListFontOffset;
        if (partyIndex == 2) then
            partyListFontOffset = gConfig.partyList2FontOffset;
        elseif (partyIndex == 3) then
            partyListFontOffset = gConfig.partyList3FontOffset;
        end

        local name_font_settings_font_height = math.max(settings.name_font_settings.font_height + partyListFontOffset, 1);
        local hp_font_settings_font_height = math.max(settings.hp_font_settings.font_height + partyListFontOffset, 1);
        local mp_font_settings_font_height = math.max(settings.mp_font_settings.font_height + partyListFontOffset, 1);
        local tp_font_settings_font_height = math.max(settings.tp_font_settings.font_height + partyListFontOffset, 1);

        memberText[i].name:SetFontHeight(name_font_settings_font_height);
        memberText[i].hp:SetFontHeight(hp_font_settings_font_height);
        memberText[i].mp:SetFontHeight(mp_font_settings_font_height);
        memberText[i].tp:SetFontHeight(tp_font_settings_font_height);
    end

    -- Update images
    local bgChanged = gConfig.partyListBackgroundName ~= loadedBg;
    loadedBg = gConfig.partyListBackgroundName;

    local bgColor = tonumber(string.format('%02x%02x%02x%02x', gConfig.partyListBgColor[4], gConfig.partyListBgColor[1], gConfig.partyListBgColor[2], gConfig.partyListBgColor[3]), 16);
    local borderColor = tonumber(string.format('%02x%02x%02x%02x', gConfig.partyListBorderColor[4], gConfig.partyListBorderColor[1], gConfig.partyListBorderColor[2], gConfig.partyListBorderColor[3]), 16);

    for i = 1, 3 do
        partyWindowPrim[i].bgTitle.scale_x = gConfig.partyListBgScale / 2.30;
        partyWindowPrim[i].bgTitle.scale_y = gConfig.partyListBgScale / 2.30;

        local backgroundPrim = partyWindowPrim[i].background;

        for _, k in ipairs(bgImageKeys) do
            local file_name = string.format('%s-%s.png', gConfig.partyListBackgroundName, k);
            backgroundPrim[k].color = k == 'bg' and bgColor or borderColor;
            if (bgChanged) then
                -- Keep width/height to prevent flicker when switching to new texture
                local width, height = backgroundPrim[k].width, backgroundPrim[k].height;
                local filepath = string.format('%s/assets/backgrounds/%s', addon.path, file_name);
                backgroundPrim[k].texture = filepath;
                backgroundPrim[k].width, backgroundPrim[k].height = width, height;

                backgroundPrim[k].exists = ashita.fs.exists(filepath);
            end
            backgroundPrim[k].scale_x = gConfig.partyListBgScale;
            backgroundPrim[k].scale_y = gConfig.partyListBgScale;
        end
    end

    arrowPrim.texture = string.format('%s/assets/cursors/%s', addon.path, gConfig.partyListCursor);
end

partyList.SetHidden = function(hidden)
	if (hidden == true) then
        UpdateTextVisibility(false);
        selectionPrim.visible = false;
        arrowPrim.visible = false;
	end
end

partyList.HandleZonePacket = function(e)
    statusHandler.clear_cache();
end

return partyList;