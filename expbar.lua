require('common');
local imgui = require('imgui');
local fonts = require('fonts');
local progressbar = require('progressbar');

local jobText;
local expText;
local percentText;

----------------------------------------------------------------
-- BEGIN HUNTPARTNER EXP-STATS PATCH (re-apply after HXUI update)
-- Captures "You earn/gain N experience points" lines via text_in,
-- maintains a 15-minute rolling event log, and renders a stats strip
-- under the EXP bar showing: Lv | (cur/max) | % | EXP/hr | mobs-to-level
-- | ding ETA. Hidden in merit/JP/CP modes since the rate doesn't apply.
-- Block bounded by BEGIN/END markers for easy re-application.
----------------------------------------------------------------
local exp_state = {
    events     = {},   -- { { t = unix_ts, n = xp_gained }, ... }
    last_gain  = 0,    -- last single XP gain (fallback when target-diff unknown)
    session_total = 0, -- total XP gained this session
    session_start = nil,
    -- mob_levels[entity_idx] -> level. Populated from /check (packet 0x0029)
    -- and widescan (0x00F4). Stale across zone changes but harmless -- entity
    -- indices recycle, lookups just become inaccurate not crashy.
    mob_levels = {},
    -- observed_xp_for_diff[level_delta] = { sum, count } -- rolling average,
    -- caps at CAP samples so post-buff calibration converges within a handful
    -- of kills (Anniversary Ring / Empress Band scenarios).
    observed_by_diff = {},
    -- Last target index polled during render. When an XP-gain text arrives,
    -- this is "almost certainly" the mob that just died.
    last_seen_target = 0,
}

-- Base XP per kill by (mob_lvl - player_lvl). Solo, no chain/signet/conquest.
-- Directionally correct as a baseline; observed values override per-diff.
local XP_BY_DIFF = {
    [-10] = 0, [-9] = 6, [-8] = 7, [-7] = 8, [-6] = 10, [-5] = 15,
    [-4] = 20, [-3] = 30, [-2] = 50, [-1] = 80,
    [0]  = 100,
    [1]  = 110, [2]  = 120, [3]  = 130, [4]  = 140, [5]  = 150,
    [6]  = 160, [7]  = 170, [8]  = 180, [9]  = 190, [10] = 200,
}
local function estimate_xp_for_diff(diff)
    if diff <= -11 then return 0   end
    if diff >=  11 then return 240 end
    return XP_BY_DIFF[diff] or 0
end

local function record_observed_xp(diff, gained)
    if not diff or not gained or gained <= 0 then return end
    local CAP = 3
    local rec = exp_state.observed_by_diff[diff]
    if not rec then
        rec = { sum = 0, count = 0 }
        exp_state.observed_by_diff[diff] = rec
    end
    if rec.count >= CAP then
        local mean = rec.sum / rec.count
        rec.sum = mean * (CAP - 1); rec.count = CAP - 1
    end
    rec.sum = rec.sum + gained
    rec.count = rec.count + 1
end

local function observed_xp_for_diff(diff)
    local rec = exp_state.observed_by_diff[diff]
    if rec and rec.count > 0 then return rec.sum / rec.count end
    return nil
end

-- Returns predicted XP for currently-targeted mob using level diff, falling
-- back through: observed-at-this-diff -> last empirical gain -> retail table.
-- Returns nil when no target or target level unknown (run /check).
local function estimate_xp_for_current_target(player_lvl)
    if not player_lvl or player_lvl <= 0 then return nil end
    local idx
    pcall(function() idx = AshitaCore:GetMemoryManager():GetTarget():GetTargetIndex(0) end)
    if not idx or idx == 0 then return nil end
    local mlvl = exp_state.mob_levels[idx]
    if not mlvl or mlvl <= 0 then return nil end
    local diff = mlvl - player_lvl
    local obs = observed_xp_for_diff(diff)
    if obs then return math.floor(obs + 0.5) end
    if exp_state.last_gain > 0 then return exp_state.last_gain end
    return estimate_xp_for_diff(diff)
end

ashita.events.register('text_in', 'hxuiplus_exp_capture_cb', function(e)
    local s = e.message_modified or e.message or ''
    if not s or s == '' then return end
    local low = s:lower()
    local gained = low:match('gain[s]? (%d+) experience point')
                or low:match('earn[s]? (%d+) experience point')
    if gained then
        local n = tonumber(gained)
        if n and n > 0 then
            local t = os.time()
            table.insert(exp_state.events, { t = t, n = n })
            exp_state.last_gain = n
            exp_state.session_total = exp_state.session_total + n
            if not exp_state.session_start then exp_state.session_start = t end
            -- Calibrate observed-xp-for-diff table from this kill, if we have
            -- both the dead mob's level and ours. Silently skips otherwise.
            local mlvl = exp_state.mob_levels[exp_state.last_seen_target]
            local plvl
            pcall(function() plvl = AshitaCore:GetMemoryManager():GetPlayer():GetMainJobLevel() end)
            if mlvl and plvl and mlvl > 0 and plvl > 0 then
                record_observed_xp(mlvl - plvl, n)
            end
        end
    end
end)

-- Mob-level capture: /check response (packet 0x0029) and widescan (0x00F4).
-- Cribbed from huntpartner's parser. The MessageNum at 0x18 disambiguates
-- 0x0029 -- skillups vs check responses. We only care about check responses.
ashita.events.register('packet_in', 'hxuiplus_mob_level_cb', function(e)
    if e.id == 0x0029 then
        local ok, msgnum = pcall(struct.unpack, 'H', e.data, 0x18 + 0x01)
        if not ok or msgnum == 38 or msgnum == 53 then return end  -- skip skillup ticks
        local ok2, lvl    = pcall(struct.unpack, 'l', e.data, 0x0C + 0x01)
        local ok3, target = pcall(struct.unpack, 'H', e.data, 0x16 + 0x01)
        if ok2 and ok3 and target and target > 0 and lvl and lvl > 0 then
            exp_state.mob_levels[target] = lvl
        end
    elseif e.id == 0x00F4 then  -- widescan
        local ok1, idx = pcall(struct.unpack, 'H', e.data, 0x04 + 0x01)
        local ok2, lvl = pcall(struct.unpack, 'b', e.data, 0x06 + 0x01)
        if ok1 and ok2 and idx and lvl and lvl > 0 then
            exp_state.mob_levels[idx] = lvl
        end
    end
end)

local function exp_prune(window_s)
    local cutoff = os.time() - window_s
    local kept = {}
    for _, ev in ipairs(exp_state.events) do
        if ev.t >= cutoff then kept[#kept + 1] = ev end
    end
    exp_state.events = kept
end

local function exp_per_hour(window_min)
    local window_s = (window_min or 15) * 60
    exp_prune(window_s)
    if #exp_state.events == 0 then return 0 end
    local total = 0
    for _, ev in ipairs(exp_state.events) do total = total + ev.n end
    local span = math.max(1, os.time() - exp_state.events[1].t)
    local denom = math.min(window_s, span)
    if denom < 1 then denom = 1 end
    return total * 3600.0 / denom
end

local function fmt_eta_short(secs)
    if secs < 60   then return ('%ds'):format(math.floor(secs)) end
    if secs < 3600 then return ('%dm'):format(math.floor(secs / 60 + 0.5)) end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60 + 0.5)
    return ('%dh%02dm'):format(h, m)
end
----------------------------------------------------------------
-- END HUNTPARTNER EXP-STATS PATCH (header section)
----------------------------------------------------------------

local expbar = {
    limitPoints = {},
    meritPoints = {},
    capacityPoints = {},
    jobPoints = {},
};

local function UpdateTextVisibility(visible)
	jobText:SetVisible(visible);
	expText:SetVisible(visible);
	percentText:SetVisible(visible);
end

--[[
* event: d3d_present
* desc : Event called when the Direct3D device is presenting a scene.
--]]
expbar.DrawWindow = function(settings)
    -- Obtain the player entity..
    local player = AshitaCore:GetMemoryManager():GetPlayer();

	if (player == nil) then
		UpdateTextVisibility(false);
		return;
	end

	local mainJob = player:GetMainJob();

    if (player.isZoning or mainJob == 0) then
		UpdateTextVisibility(false);
        return;
	end

    -- v-plus: poll current target so XP capture can correlate "the mob you
    -- just killed" with its level for diff-calibration.
    pcall(function()
        local tidx = AshitaCore:GetMemoryManager():GetTarget():GetTargetIndex(0)
        if tidx and tidx ~= 0 then exp_state.last_seen_target = tidx end
    end)

    local jobLevel = player:GetMainJobLevel();
    local subJob = player:GetSubJob();
    local subJobLevel = player:GetSubJobLevel();
    local expPoints = { player:GetExpCurrent(), player:GetExpNeeded() };
    local expPointsProgress = expPoints[1] / expPoints[2];

    local limitPoints = expbar.limitPoints;
    local limitPointsProgress = limitPoints[1] / limitPoints[2];
    local meritPoints = expbar.meritPoints;

    -- expbar.capacityPoints[1] = player:GetCapacityPoints(mainJob);
    -- expbar.jobPoints[1] = player:GetJobPoints(mainJob);
    local capPoints = expbar.capacityPoints;
    local capPointsProgress = expbar.capacityPoints[1] / expbar.capacityPoints[2];
    local jobPoints = expbar.jobPoints;

    local meritMode = gConfig.expBarLimitPointsMode and (expPoints[1] == 55999 or ((player:GetIsLimitModeEnabled() or player:GetIsExperiencePointsLocked()) and jobLevel >= 75));
    -- If player is a max level then only enable meritMode in the xp bar if limit mode is specifically enabled
    -- this is so we display capacity points by default
    -- TODO: Tapping on Exp bar switches between merit mode and capacity points
    if jobLevel >= 99 and not player:GetIsLimitModeEnabled() then
        meritMode = false
    end
    local progressBarProgress = 0
    if meritMode then
        progressBarProgress = limitPointsProgress;
    elseif jobLevel >= 99 then
        progressBarProgress = capPointsProgress;
    else
        progressBarProgress = expPointsProgress
    end

    local inlineMode = gConfig.expBarInlineMode;
    local windowSize = inlineMode and settings.barWidth + settings.textWidth or math.max(settings.barWidth, settings.textWidth);

    imgui.SetNextWindowSize({ windowSize, -1 }, ImGuiCond_Always);
	local windowFlags = bit.bor(ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav, ImGuiWindowFlags_NoBackground, ImGuiWindowFlags_NoBringToFrontOnFocus);
	if (gConfig.lockPositions) then
		windowFlags = bit.bor(windowFlags, ImGuiWindowFlags_NoMove);
	end
    -- v-plus: hoist startX/startY so the EXP-STATS PATCH render block
    -- below can position the stats window relative to the bar's screen pos.
    local startX, startY = 0, 0
    if (imgui.Begin('ExpBar', true, windowFlags)) then

		-- Draw HP Bar
		startX, startY = imgui.GetCursorScreenPos();
        local col2X = startX + settings.textWidth - imgui.GetStyle().FramePadding.x * 2;

        local progressBarWidth = settings.barWidth - imgui.GetStyle().FramePadding.x * 2;
        if inlineMode then
            imgui.SetCursorScreenPos({col2X, startY});
        end
        -- v-plus: stack a "ghost" segment showing where the next kill would
        -- push the bar. Prefers currently-targeted mob's level-diff estimate
        -- (calibrated from prior kills at that diff), falls back to last
        -- empirical gain when no target or target level unknown.
        local barSegments = {{progressBarProgress, {'#c39040', '#e9c466'}}}
        local ghost_xp = 0
        if not meritMode and jobLevel < 99
           and expPoints[2] > 0 and expPoints[1] < expPoints[2] then
            local tgt = estimate_xp_for_current_target(jobLevel)
            if tgt and tgt > 0 then
                ghost_xp = tgt
            elseif exp_state.last_gain > 0 then
                ghost_xp = exp_state.last_gain
            end
            if ghost_xp > 0 then
                local headroom = math.max(0, 1.0 - progressBarProgress)
                local ghost = math.min(ghost_xp / expPoints[2], headroom)
                if ghost > 0 then
                    table.insert(barSegments, { ghost, { '#7a5a30', '#a08050' } })
                end
            end
        end
		progressbar.ProgressBar(barSegments, {progressBarWidth, settings.barHeight}, {decorate = gConfig.showExpBarBookends});

        -- EXP bar segment dividers (configurable: 5 or 20 segments)
        local expSegments = gConfig.expBarSegments or 5
        if expSegments > 1 then
            local dl_seg
            pcall(function() dl_seg = imgui.GetWindowDrawList() end)
            if dl_seg then
                local pad = imgui.GetStyle().FramePadding.x
                local segBarX = (inlineMode and col2X or startX) + pad
                local segBarY = startY
                local segBw = progressBarWidth
                local segBh = settings.barHeight
                -- Bookend offset
                if gConfig.showExpBarBookends then
                    local bookendW = segBh / 2
                    segBarX = segBarX + bookendW
                    segBw = segBw - bookendW * 2
                end
                for i = 1, expSegments - 1 do
                    local frac = i / expSegments
                    local lx = segBarX + segBw * frac
                    dl_seg:AddLine(
                        { lx, segBarY + 1 },
                        { lx, segBarY + segBh - 1 },
                        imgui.GetColorU32({ 0.0, 0.0, 0.0, 0.5 }), 1)
                end
            end
        end

        ----------------------------------------------------------------
        -- HUNTPARTNER EXP TIME PROJECTION TICKS
        -- Adaptive time ticks on EXP bar based on current rate.
        -- Shows where you'll be at future clock times + a DING marker.
        ----------------------------------------------------------------
        if not meritMode and jobLevel < 99 and expPoints[2] > 0 then
            local per_hour = exp_per_hour(15)
            if per_hour > 0 then
                local dl_e
                pcall(function() dl_e = imgui.GetForegroundDrawList() end)
                if dl_e then
                    local pad = imgui.GetStyle().FramePadding.x
                    local barX = (inlineMode and col2X or startX) + pad
                    local barY = startY
                    local bw = progressBarWidth
                    local bh = settings.barHeight
                    local cur_xp = expPoints[1]
                    local needed = expPoints[2]
                    local cur_frac = cur_xp / needed
                    local remaining = needed - cur_xp
                    local time_to_ding_min = remaining * 60.0 / per_hour

                    -- Draw ticks at 20/40/60/80/100% milestones (skip already passed)
                    local milestones = { 0.20, 0.40, 0.60, 0.80 }
                    for _, target_frac in ipairs(milestones) do
                        if target_frac > cur_frac + 0.02 then
                            local xp_needed_for_ms = needed * target_frac
                            local xp_to_go = xp_needed_for_ms - cur_xp
                            local mins_to_ms = xp_to_go * 60.0 / per_hour
                            local tx = barX + bw * target_frac
                            dl_e:AddLine(
                                { tx, barY },
                                { tx, barY + bh },
                                imgui.GetColorU32({ 1.0, 0.95, 0.4, 1.0 }), 2)
                            -- Clock time label with shadow for readability
                            local wall = os.date('%I:%M', os.time() + math.floor(mins_to_ms * 60))
                                            :gsub('^0', '')
                            dl_e:AddText({ tx - 7, barY - 11 },
                                imgui.GetColorU32({ 0, 0, 0, 1.0 }), wall)
                            dl_e:AddText({ tx - 8, barY - 12 },
                                imgui.GetColorU32({ 1.0, 0.95, 0.5, 1.0 }), wall)
                        end
                    end

                    -- DING marker at 100%
                    local ding_x = barX + bw
                    local ding_time = os.date('%I:%M', os.time() + math.floor(time_to_ding_min * 60))
                                        :gsub('^0', '')
                    local ding_str = ding_time .. '!'
                    dl_e:AddText({ ding_x - 23, barY - 11 },
                        imgui.GetColorU32({ 0, 0, 0, 1.0 }), ding_str)
                    dl_e:AddText({ ding_x - 24, barY - 12 },
                        imgui.GetColorU32({ 0.2, 1.0, 0.4, 1.0 }), ding_str)
                end
            end
        end
        ----------------------------------------------------------------
        -- END HUNTPARTNER EXP TIME PROJECTION TICKS
        ----------------------------------------------------------------

		imgui.SameLine();

        local textY = inlineMode and startY or startY + settings.barHeight + settings.textOffsetY;
        local textXRightAlign = startX + settings.textWidth - imgui.GetStyle().FramePadding.x * 4;

		-- Update our text objects

        if gConfig.expBarShowText then
            -- Job Text + huntpartner-style stats (rate, mobs-to-level)
            -- inlined to the right of the job string. Skipped in merit/JP/CP
            -- modes where the EXP rate doesn't apply.
            local mainJobString = AshitaCore:GetResourceManager():GetString('jobs.names_abbr', mainJob);
            local subJobString = AshitaCore:GetResourceManager():GetString('jobs.names_abbr', subJob);
            local jobString = mainJobString .. ' ' .. jobLevel .. ' / ' .. subJobString .. ' ' .. subJobLevel;
            if not meritMode and jobLevel < 99 then
                local cur, needed = expPoints[1], expPoints[2]
                if needed and needed > 0 then
                    local per_hour = exp_per_hour(15)
                    local rate_s = (per_hour > 0)
                        and ('%d/hr'):format(math.floor(per_hour + 0.5)) or '--/hr'
                    -- Use target-diff estimate for mobs-to-level when available
                    -- (more accurate than last_gain after camp/target changes).
                    local pred = estimate_xp_for_current_target(jobLevel) or exp_state.last_gain
                    local mobs_s = '-- mobs'
                    if pred and pred > 0 and cur < needed then
                        mobs_s = tostring(math.ceil((needed - cur) / pred)) .. ' mobs'
                    end
                    jobString = jobString .. '   ' .. rate_s .. '  ' .. mobs_s
                    if per_hour > 0 and cur < needed then
                        local secs = (needed - cur) * 3600.0 / per_hour
                        local hms  = fmt_eta_short(secs)
                        local wall = os.date('%I:%M%p', os.time() + math.floor(secs))
                                       :gsub('^0', ''):lower()
                        jobString = jobString .. '  ding ' .. hms .. ' @ ' .. wall
                    end
                    if exp_state.session_total > 0 then
                        jobString = jobString
                            .. ('  [%d XP]'):format(exp_state.session_total)
                    end
                end
            end
            jobText:SetText(jobString);
            local textW, textH = jobText:get_text_size();
            jobText:SetPositionX(startX);
            jobText:SetPositionY(inlineMode and textY + (settings.barHeight - textH) / 2 - 1 or textY); -- - jobText:GetFontHeight() / 2.5);

            -- Exp Text
            if meritMode then
                if jobLevel >= 99 then
                    local expString = 'JP (' .. jobPoints[1] .. ' / ' .. jobPoints[2] .. ')' .. ' MP (' .. meritPoints[1] .. ' / ' .. meritPoints[2] .. ')' .. ' LP (' .. limitPoints[1] .. ' / ' .. limitPoints[2] .. ')';
                    expText:SetText(expString);
                else
                    local expString = 'MP (' .. meritPoints[1] .. ' / ' .. meritPoints[2] .. ')' .. ' LP (' .. limitPoints[1] .. ' / ' .. limitPoints[2] .. ')';
                    expText:SetText(expString);
                end
            elseif jobLevel >= 99 then
                local expString = 'JP (' .. jobPoints[1] .. ' / ' .. jobPoints[2] .. ')' .. ' MP (' .. meritPoints[1] .. ' / ' .. meritPoints[2] .. ')' .. ' CP (' .. capPoints[1] .. ' / ' .. capPoints[2] .. ')';
                expText:SetText(expString);
            else
                local expString = 'EXP (' .. expPoints[1] .. ' / ' .. expPoints[2] .. ')';
                expText:SetText(expString);
            end
            local textW, textH = expText:get_text_size();
            expText:SetPositionX(textXRightAlign);
            expText:SetPositionY(inlineMode and textY + (settings.barHeight - textH) / 2 - 1 or textY); -- - expText:GetFontHeight() / 2.5);

            jobText:SetVisible(true);
            expText:SetVisible(true);
        else
            jobText:SetText('');
            jobText:SetVisible(false);
            expText:SetText('');
            expText:SetVisible(false);
        end

        -- Percent Text — positioned above the current EXP fill point
        if gConfig.expBarShowPercent then
            local expPercentString = ('%.f'):fmt(progressBarProgress * 100);
            local percentString = expPercentString .. '%';
            percentText:SetText(percentString); 
            local textW, textH = percentText:get_text_size();
            local pad = imgui.GetStyle().FramePadding.x
            local barX = (inlineMode and col2X or startX) + pad
            local fillX = barX + progressBarWidth * progressBarProgress
            percentText:SetAnchor(0);
            percentText:SetPositionX(fillX - textW / 2);
            percentText:SetPositionY(startY - 12);
            percentText:SetRightJustified(false);

            percentText:SetVisible(true);
        else
            percentText:SetText('');
            percentText:SetVisible(false);
        end

    end
	imgui.End();
end


expbar.Initialize = function(settings)
    jobText = fonts.new(settings.job_font_settings);
	expText = fonts.new(settings.exp_font_settings);
	percentText = fonts.new(settings.percent_font_settings);

    local player = AshitaCore:GetMemoryManager():GetPlayer();
    expbar.limitPoints = { player:GetLimitPoints(), 10000 };
    expbar.meritPoints = { player:GetMeritPoints(), player:GetMeritPointsMax() };
    local currJob = player:GetMainJob();
    expbar.capacityPoints = { player:GetCapacityPoints(currJob), 30000 };
    expbar.jobPoints = { player:GetJobPoints(currJob), 500 };
    -- expbar.mastery = { player:GetMasteryExp(), player:GetMasteryExpNeeded() };
end

expbar.UpdateFonts = function(settings)
    jobText:SetFontHeight(settings.job_font_settings.font_height);
	expText:SetFontHeight(settings.exp_font_settings.font_height);
	percentText:SetFontHeight(settings.percent_font_settings.font_height);
end

expbar.SetHidden = function(hidden)
	if (hidden == true) then
		UpdateTextVisibility(false);
	end
end

expbar.HandlePacket = function(e)
    -- Kill Message
    if e.id == 0x02D then
        local pId = struct.unpack('I', e.data_modified, 0x04 + 1);
        if pId == GetPlayerEntity().ServerId then
            local val = struct.unpack('I', e.data_modified, 0x10 + 1);
            -- local val2 = struct.unpack('I', e.data_modified, 0x14 + 1);
            local msgId = struct.unpack('H', e.data_modified, 0x18 + 1) % 1024;

            if msgId == 371 or msgId == 372 then
                expbar.limitPoints[1] = expbar.limitPoints[1] + val;
                if (expbar.limitPoints[1] > expbar.limitPoints[2]) then
                    expbar.limitPoints[1] = expbar.limitPoints[1] - expbar.limitPoints[2];
                end
                -- print('Limit points A: ' .. expbar.limitPoints[1] .. ' / ' .. expbar.limitPoints[2] .. ' #' .. msgId);
            elseif msgId == 718 or msgId == 735 then
                expbar.capacityPoints[1] = expbar.capacityPoints[1] + val;
                if (expbar.capacityPoints[1] > expbar.capacityPoints[2]) then
                    expbar.capacityPoints[1] = expbar.capacityPoints[1] - expbar.capacityPoints[2];
                end
            elseif msgId == 50 or msgId == 368 then
                expbar.meritPoints[1] = val;
                -- print('Merit points: ' .. expbar.meritPoints[1] .. ' / ' .. expbar.meritPoints[2] .. ' #' .. msgId);
            elseif msgId == 719 then
                expbar.jobPoints[1] = val;
            end
        end
    elseif e.id == 0x063 then
        if e.data_modified:byte(5) == 2 then
            expbar.limitPoints[1] = struct.unpack('H', e.data_modified, 0x08 + 1);
            expbar.meritPoints[1] = e.data_modified:byte(0x0A + 1) % 128;
            expbar.meritPoints[2] = e.data_modified:byte(0x0C + 1) % 128;
            -- print('Limit points B: ' .. expbar.limitPoints[1] .. ' / ' .. expbar.limitPoints[2]);
        elseif e.data_modified:byte(5) == 5 then
            local player = AshitaCore:GetMemoryManager():GetPlayer();
            local jobOffset = player:GetMainJob() * 6 + 13;
            expbar.capacityPoints[1] = struct.unpack('H', e.data_modified, jobOffset);
            expbar.jobPoints[1] = struct.unpack('H', e.data_modified, jobOffset + 2);
        end
    end
end

return expbar;