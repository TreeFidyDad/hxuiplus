require('common');
require('helpers');
local imgui = require('imgui');
local fonts = require('fonts');
local progressbar = require('progressbar');
local buffTable = require('bufftable');

local hpText;
local mpText;
local tpText;
local resetPosNextFrame = false;

local playerbar = {};

----------------------------------------------------------------
-- HUNTPARTNER MP-TICK PATCH (state)
-- Tracks /heal rest status (player status == 33) and observed MP
-- ticks during rest. Used by the MP-bar tick countdown overlay.
-- Ticks fire every 10s during rest (first tick has a 20s window).
-- Module-level so state persists across frames; reset on rest exit.
----------------------------------------------------------------
local mpTick = {
    active   = false,  -- /heal currently active
    last_t   = 0,      -- timestamp of last tick (or rest start)
    last_mp  = -1,     -- last seen MP value (for delta detection)
    deltas   = {},     -- ring buffer of last 5 observed MP-tick deltas
    flash_t  = -1,     -- timestamp when last tick observed (drives flash)
}
local function mpTickAverageDelta()
    if #mpTick.deltas == 0 then return nil end
    local s = 0
    for _, v in ipairs(mpTick.deltas) do s = s + v end
    return s / #mpTick.deltas
end

----------------------------------------------------------------
-- HUNTPARTNER HP-TICK PATCH (state)
-- Same shape as mpTick but tracks HP deltas during rest. HP and MP
-- ticks fire on the same 10s rest cadence so they update together
-- when the player is /healing.
----------------------------------------------------------------
local hpTick = {
    active   = false,
    last_t   = 0,
    last_hp  = -1,
    deltas   = {},
    flash_t  = -1,
}
local function hpTickAverageDelta()
    if #hpTick.deltas == 0 then return nil end
    local s = 0
    for _, v in ipairs(hpTick.deltas) do s = s + v end
    return s / #hpTick.deltas
end

----------------------------------------------------------------
-- REGEN-GHOST PATCH (state)
-- Tracks HP restored by the Regen buff (status id 42) while standing
-- (i.e. NOT resting -- the hpTick tracker above owns the rest case).
-- Mirrors hpTick but is gated on the Regen buff instead of /heal
-- status, so it works in combat. Drives a green "ghost" preview on
-- the HP bar showing projected regen recovery so you can avoid over-
-- curing. Module-level so state persists across frames.
----------------------------------------------------------------
local REGEN_STATUS_ID  = 42;    -- FFXI status effect id for Regen
local REGEN_GHOST_TICKS = 3;    -- how many regen ticks to project ahead
local regenTick = {
    active   = false,
    last_hp  = -1,
    deltas   = {},   -- ring buffer of last 5 observed regen-tick HP deltas
}
local function regenTickAverageDelta()
    if #regenTick.deltas == 0 then return nil end
    local s = 0
    for _, v in ipairs(regenTick.deltas) do s = s + v end
    return s / #regenTick.deltas
end
local function playerHasRegen()
    local hasRegen = false;
    pcall(function()
        local p = AshitaCore:GetMemoryManager():GetPlayer();
        if p == nil then return; end
        local buffs = p:GetBuffs();
        if buffs == nil then return; end
        for i = 0, #buffs do
            if buffs[i] == REGEN_STATUS_ID then
                hasRegen = true;
                return;
            end
        end
    end);
    return hasRegen;
end

local _HXUI_DEV_DEBUG_INTERPOLATION = false;
local _HXUI_DEV_DEBUG_INTERPOLATION_DELAY, _HXUI_DEV_DEBUG_INTERPOLATION_NEXT_TIME;

----------------------------------------------------------------
-- HUNTPARTNER TP-THRESHOLD SPARKS (state)
-- Fires a brief radial spark burst on the TP bar each time the
-- player crosses a 1000/2000/3000 boundary upward. Persists across
-- frames; resets on zone change.
----------------------------------------------------------------
local tpTier = {
    last_tier  = 0,      -- 0..3, the last-seen TP tier
    burst_at   = -1,     -- os.clock() of last burst trigger (negative = none)
    burst_tier = 0,      -- which tier was just crossed (for coloring)
}
local TP_BURST_SECONDS = 0.65;

----------------------------------------------------------------
-- Zone change: reset TP tier burst state
ashita.events.register('packet_in', 'hxuiplus_zone_cb', function(e)
    if e.id == 0x000A or e.id == 0x000B then
        tpTier.last_tier  = 0
        tpTier.burst_at   = -1
        tpTier.burst_tier = 0
    end
end)

----------------------------------------------------------------
if _HXUI_DEV_DEBUG_INTERPOLATION then
	_HXUI_DEV_DEBUG_INTERPOLATION_DELAY = 2;
	_HXUI_DEV_DEBUG_INTERPOLATION_NEXT_TIME = os.time() + _HXUI_DEV_DEBUG_INTERPOLATION_DELAY;
end

local function UpdateTextVisibility(visible)
	hpText:SetVisible(visible);
	mpText:SetVisible(visible);
	tpText:SetVisible(visible);
end

playerbar.DrawWindow = function(settings)
    -- Obtain the player entity..
    local party = AshitaCore:GetMemoryManager():GetParty();
    local player = AshitaCore:GetMemoryManager():GetPlayer();
	local playerEnt = GetPlayerEntity();
	
	if (party == nil or player == nil or playerEnt == nil) then
		UpdateTextVisibility(false);
		return;
	end

	local currJob = player:GetMainJob();

    if (player.isZoning or currJob == 0) then
		UpdateTextVisibility(false);	
        return;
	end
	
	if (party == nil or player == nil) then
		return;
	end

	local SelfHP = party:GetMemberHP(0);
	local SelfHPMax = player:GetHPMax();
	local SelfHPPercent = math.clamp(party:GetMemberHPPercent(0), 0, 100);
	local SelfMP = party:GetMemberMP(0);
	local SelfMPMax = player:GetMPMax();
	local SelfMPPercent = math.clamp(party:GetMemberMPPercent(0), 0, 100);
	local SelfTP = party:GetMemberTP(0);

	local currentTime = os.clock();

	----------------------------------------------------------------
	-- HUNTPARTNER MP-TICK PATCH (state update, every frame)
	-- Detect rest start/stop and accumulate observed tick deltas.
	-- FFXI rest status is 33. Read via IEntity:GetStatus(playerIdx)
	-- — IPlayer does NOT expose GetStatus directly.
	----------------------------------------------------------------
	do
		local pStatus = 0;
		pcall(function()
			local pIdx = party:GetMemberTargetIndex(0);
			pStatus = AshitaCore:GetMemoryManager():GetEntity():GetStatus(pIdx) or 0;
		end);
		if pStatus == 33 then
			if not mpTick.active then
				mpTick.active  = true;
				mpTick.last_t  = currentTime;
				mpTick.last_mp = SelfMP;
				mpTick.deltas  = {};
				mpTick.flash_t = -1;
			else
				if SelfMP > mpTick.last_mp then
					local d = SelfMP - mpTick.last_mp;
					table.insert(mpTick.deltas, d);
					while #mpTick.deltas > 5 do table.remove(mpTick.deltas, 1) end
					mpTick.last_mp  = SelfMP;
					mpTick.last_t   = currentTime;
					mpTick.flash_t  = currentTime;
				elseif SelfMP < mpTick.last_mp then
					-- spell/item cast - update baseline, don't count as tick.
					mpTick.last_mp = SelfMP;
				end
			end
			-- Parallel HP tick tracker.
			if not hpTick.active then
				hpTick.active  = true;
				hpTick.last_t  = currentTime;
				hpTick.last_hp = SelfHP;
				hpTick.deltas  = {};
				hpTick.flash_t = -1;
			else
				if SelfHP > hpTick.last_hp then
					local d = SelfHP - hpTick.last_hp;
					table.insert(hpTick.deltas, d);
					while #hpTick.deltas > 5 do table.remove(hpTick.deltas, 1) end
					hpTick.last_hp  = SelfHP;
					hpTick.last_t   = currentTime;
					hpTick.flash_t  = currentTime;
				elseif SelfHP < hpTick.last_hp then
					hpTick.last_hp = SelfHP;
				end
			end
		else
			mpTick.active  = false;
			mpTick.last_mp = SelfMP;
			hpTick.active  = false;
			hpTick.last_hp = SelfHP;
		end
	end

	----------------------------------------------------------------
	-- REGEN-GHOST PATCH (state update, every frame)
	-- Accumulate HP gained from Regen while NOT resting. Small periodic
	-- gains are treated as regen ticks; large jumps (cures) are ignored
	-- so the average reflects regen only. Damage just resets the
	-- baseline and keeps the observed rate.
	----------------------------------------------------------------
	do
		local regenActive = (not hpTick.active) and SelfHP > 0 and playerHasRegen();
		if regenActive then
			if not regenTick.active then
				regenTick.active  = true;
				regenTick.last_hp = SelfHP;
				regenTick.deltas  = {};
			elseif SelfHP > regenTick.last_hp then
				local d = SelfHP - regenTick.last_hp;
				-- Ignore cures / big jumps; regen ticks are small.
				local tickCap = math.max(60, SelfHPMax * 0.12);
				if d <= tickCap then
					table.insert(regenTick.deltas, d);
					while #regenTick.deltas > 5 do table.remove(regenTick.deltas, 1) end
				end
				regenTick.last_hp = SelfHP;
			elseif SelfHP < regenTick.last_hp then
				regenTick.last_hp = SelfHP;
			end
		else
			regenTick.active  = false;
			regenTick.last_hp = SelfHP;
		end
	end

    if playerbar.previousHPP then
    	if SelfHPPercent < playerbar.currentHPP then
    		playerbar.previousHPP = playerbar.currentHPP;
    		playerbar.currentHPP = SelfHPPercent;
    		playerbar.lastHitTime = currentTime;
    	end
    else
    	playerbar.currentHPP = SelfHPPercent;
    	playerbar.previousHPP = SelfHPPercent;
    end

    if _HXUI_DEV_DEBUG_INTERPOLATION then
	    if os.time() > _HXUI_DEV_DEBUG_INTERPOLATION_NEXT_TIME then
	    	playerbar.previousHPP = 75;
	    	playerbar.currentHPP = 50;
			playerbar.lastHitTime = currentTime;

			_HXUI_DEV_DEBUG_INTERPOLATION_NEXT_TIME = os.time() + 2;
	    end
	end

    local interpolationPercent;
    local interpolationOverlayAlpha = 0;

    if playerbar.currentHPP < playerbar.previousHPP then
    	local hppDelta = playerbar.previousHPP - playerbar.currentHPP;

    	if currentTime > playerbar.lastHitTime + settings.hitDelayLength then
    		-- local interpolationTimeTotal = settings.hitInterpolationMaxTime * (hppDelta / 100);
    		local interpolationTimeTotal = settings.hitInterpolationMaxTime;
    		local interpolationTimeElapsed = currentTime - playerbar.lastHitTime - settings.hitDelayLength;

    		if interpolationTimeElapsed <= interpolationTimeTotal then
    			local interpolationTimeElapsedPercent = easeOutPercent(interpolationTimeElapsed / interpolationTimeTotal);

    			interpolationPercent = hppDelta * (1 - interpolationTimeElapsedPercent);
    		end
    	elseif currentTime - playerbar.lastHitTime <= settings.hitDelayLength then
    		interpolationPercent = hppDelta;

			if gConfig.healthBarFlashEnabled then
				local hitDelayTime = currentTime - playerbar.lastHitTime;
				local hitDelayHalfDuration = settings.hitDelayLength / 2;

				if hitDelayTime > hitDelayHalfDuration then
					interpolationOverlayAlpha = 1 - ((hitDelayTime - hitDelayHalfDuration) / hitDelayHalfDuration);
				else
					interpolationOverlayAlpha = hitDelayTime / hitDelayHalfDuration;
				end
			end
    	end
    end

	-- Draw the player window
	if (resetPosNextFrame) then
		imgui.SetNextWindowPos({0,0});
		resetPosNextFrame = false;
	end
	
		
	local windowFlags = bit.bor(ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav, ImGuiWindowFlags_NoBackground, ImGuiWindowFlags_NoBringToFrontOnFocus);
	if (gConfig.lockPositions) then
		windowFlags = bit.bor(windowFlags, ImGuiWindowFlags_NoMove);
	end
    if (imgui.Begin('PlayerBar', true, windowFlags)) then

		-- Globe mode from config (persisted)
		local globeMode = gConfig.playerBarGlobeMode or false

		if globeMode then
			-- POE2-style globe rendering: HP orb left, MP orb right, TP bar between
			local dl_globe
			pcall(function() dl_globe = imgui.GetWindowDrawList() end)
			if dl_globe then
				local winX, winY = imgui.GetCursorScreenPos()
				local globeScale = gConfig.playerBarGlobeScale or 1.0
				local globeSpacing = gConfig.playerBarGlobeSpacing or 0
				local totalWidth = settings.barWidth + globeSpacing * 2
				local radius = math.floor(math.min(settings.barWidth * 0.18, 50) * globeScale)
				-- Extra margin for TP arcs that extend beyond the MP orb
				local arc_thick = math.max(3, math.floor(radius * 0.10))
				local arc_gap = 2
				local arc_margin = 5 + (arc_thick + arc_gap) * 3
				local cy = winY + radius + 8 + arc_margin
				local hp_cx = winX + radius + 6
				local mp_cx = winX + totalWidth - radius - 6
				local t_now = os.clock()

				-- Draw a POE2-style orb
				local function draw_orb(cx, cy, r, fill_pct, base_color, glow_color)
					local segments = 48

					-- Outer dark void (the empty part of the globe)
					dl_globe:AddCircleFilled({cx, cy}, r, imgui.GetColorU32({0.02, 0.02, 0.04, 0.95}), segments)

					-- Liquid fill with animated surface
					if fill_pct > 0 then
						local fill_h = r * 2 * math.min(1.0, fill_pct)
						local surface_y = cy + r - fill_h
						-- Animated wave on surface
						local wave_amp = math.min(3, r * 0.06)
						local wave_freq = 2.5

						-- Fill rows (bottom to top within circle)
						local step_size = math.max(1, math.floor(r / 24))
						local py = cy + r
						while py >= surface_y - wave_amp do
							-- Wave distortion at surface
							local is_surface = math.abs(py - surface_y) < (wave_amp + step_size)
							local wave_offset = 0
							if is_surface then
								wave_offset = wave_amp * math.sin(t_now * wave_freq + (py - cy) * 0.3)
							end

							local effective_y = py
							if is_surface then
								effective_y = py - wave_offset
							end

							local dy = effective_y - cy
							if math.abs(dy) <= r then
								local half_w = math.sqrt(math.max(0, r*r - dy*dy)) - 1
								if half_w > 0 and py >= surface_y + wave_offset then
									-- Depth gradient: brighter near surface, darker at bottom
									local depth = (py - surface_y) / (r * 2)
									local bright = 1.0 - depth * 0.5
									-- Subtle horizontal caustic shimmer
									local shimmer = 1.0 + 0.08 * math.sin(t_now * 3.0 + py * 0.15)
									local cr = base_color[1] * bright * shimmer
									local cg = base_color[2] * bright * shimmer
									local cb = base_color[3] * bright * shimmer
									dl_globe:AddRectFilled(
										{cx - half_w, py},
										{cx + half_w, py + step_size},
										imgui.GetColorU32({cr, cg, cb, 0.92}), 0, 0)
								end
							end
							py = py - step_size
						end

						-- Inner glow at liquid surface
						if fill_pct > 0.05 then
							local glow_y = surface_y
							local gdy = glow_y - cy
							if math.abs(gdy) < r then
								local glow_hw = math.sqrt(math.max(0, r*r - gdy*gdy)) * 0.7
								dl_globe:AddRectFilled(
									{cx - glow_hw, glow_y - 2},
									{cx + glow_hw, glow_y + 3},
									imgui.GetColorU32({glow_color[1], glow_color[2], glow_color[3], 0.4}), 0, 0)
							end
						end
					end

					-- Glass specular highlight (top-left)
					dl_globe:AddCircleFilled({cx - r*0.3, cy - r*0.35}, r*0.18,
						imgui.GetColorU32({1.0, 1.0, 1.0, 0.10}), 16)
					dl_globe:AddCircleFilled({cx - r*0.22, cy - r*0.28}, r*0.08,
						imgui.GetColorU32({1.0, 1.0, 1.0, 0.18}), 12)

					-- Multi-layer rim for metallic frame look
					-- Outer dark edge
					dl_globe:AddCircle({cx, cy}, r + 2, imgui.GetColorU32({0.01, 0.01, 0.02, 0.9}), segments, 3)
					-- Main ornate rim (bronze/gold tint)
					dl_globe:AddCircle({cx, cy}, r, imgui.GetColorU32({0.45, 0.35, 0.20, 0.9}), segments, 3.5)
					-- Inner highlight ring
					dl_globe:AddCircle({cx, cy}, r - 2, imgui.GetColorU32({0.6, 0.5, 0.3, 0.4}), segments, 1.5)
					-- Innermost shadow
					dl_globe:AddCircle({cx, cy}, r - 4, imgui.GetColorU32({0.0, 0.0, 0.0, 0.3}), segments, 1)

					-- Corner rivets (decorative dots at cardinal points)
					local rivet_col = imgui.GetColorU32({0.55, 0.45, 0.25, 0.7})
					local rivet_r = math.max(2, r * 0.06)
					for angle = 0, 3 do
						local a = angle * math.pi * 0.5 + math.pi * 0.25
						local rx = cx + math.cos(a) * (r - 1)
						local ry = cy + math.sin(a) * (r - 1)
						dl_globe:AddCircleFilled({rx, ry}, rivet_r, rivet_col, 8)
					end
				end

				-- HP Orb (deep crimson/blood red)
				draw_orb(hp_cx, cy, radius,
					SelfHPPercent / 100,
					{0.65, 0.08, 0.06},
					{1.0, 0.3, 0.2})

				-- MP Orb (deep sapphire blue)
				draw_orb(mp_cx, cy, radius,
					SelfMPPercent / 100,
					{0.06, 0.12, 0.65},
					{0.3, 0.5, 1.0})

				-- TP arcs wrapping around the MP orb (3 tiers: 0-1k, 1k-2k, 2k-3k)
				-- arc_thick and arc_gap already defined above for margin calc
				local arc_segs = 36
				local arc_start = math.rad(150)   -- bottom-left
				local arc_sweep = math.rad(300)   -- 300° sweep

				-- Tier definitions: radius offset, fill fraction, color
				local tp_tiers = {
					{ r_off = 5,                          tp_min = 0,    tp_max = 1000,
					  color = {0.70, 0.55, 0.10},  bright = {1.0, 0.85, 0.25} },
					{ r_off = 5 + arc_thick + arc_gap,    tp_min = 1000, tp_max = 2000,
					  color = {0.80, 0.50, 0.10},  bright = {1.0, 0.70, 0.20} },
					{ r_off = 5 + (arc_thick + arc_gap)*2, tp_min = 2000, tp_max = 3000,
					  color = {0.85, 0.35, 0.10},  bright = {1.0, 0.50, 0.15} },
				}

				for _, tier in ipairs(tp_tiers) do
					local arc_r = radius + tier.r_off
					local tp_in_tier = math.max(0, math.min(1000, SelfTP - tier.tp_min))
					local fill = tp_in_tier / 1000
					local is_full = (tp_in_tier >= 1000)

					-- Background track (only show if we've reached this tier or it's tier 1)
					if tier.tp_min == 0 or SelfTP >= tier.tp_min then
						for i = 0, arc_segs - 1 do
							local a1 = arc_start - (arc_sweep * i / arc_segs)
							local a2 = arc_start - (arc_sweep * (i + 1) / arc_segs)
							dl_globe:AddLine(
								{mp_cx + math.cos(a1) * arc_r, cy + math.sin(a1) * arc_r},
								{mp_cx + math.cos(a2) * arc_r, cy + math.sin(a2) * arc_r},
								imgui.GetColorU32({0.08, 0.06, 0.02, 0.6}), arc_thick)
						end
					end

					-- Filled portion
					if fill > 0 then
						local fill_segs = math.floor(arc_segs * fill)
						for i = 0, fill_segs - 1 do
							local a1 = arc_start - (arc_sweep * i / arc_segs)
							local a2 = arc_start - (arc_sweep * (i + 1) / arc_segs)
							local t = i / arc_segs
							local base = is_full and tier.bright or tier.color
							local bright = 0.85 + 0.15 * t
							dl_globe:AddLine(
								{mp_cx + math.cos(a1) * arc_r, cy + math.sin(a1) * arc_r},
								{mp_cx + math.cos(a2) * arc_r, cy + math.sin(a2) * arc_r},
								imgui.GetColorU32({base[1]*bright, base[2]*bright, base[3]*bright, 0.92}), arc_thick)
						end
						-- Glow tip
						if not is_full and fill_segs > 0 then
							local tip_a = arc_start - (arc_sweep * fill_segs / arc_segs)
							local tip_x = mp_cx + math.cos(tip_a) * arc_r
							local tip_y = cy + math.sin(tip_a) * arc_r
							local glow_a = 0.4 + 0.3 * math.abs(math.sin(t_now * 3.0))
							dl_globe:AddCircleFilled({tip_x, tip_y}, arc_thick * 0.7,
								imgui.GetColorU32({1.0, 0.9, 0.4, glow_a}), 10)
						end
					end
				end
				-- Keep arc_r defined for TP flash QOL below
				local arc_r = radius + 5 + (arc_thick + arc_gap) * 2

				-- HP/MP/TP text labels inside the orbs (no overlap with other windows)
				local hp_label = tostring(SelfHP)
				local mp_label = tostring(SelfMP)
				local tp_label = tostring(SelfTP)
				local hp_tw = imgui.CalcTextSize(hp_label)
				local mp_tw = imgui.CalcTextSize(mp_label)
				local tp_tw = imgui.CalcTextSize(tp_label)
				-- HP number centered in HP orb
				dl_globe:AddText({hp_cx - hp_tw / 2 + 1, cy - 5},
					imgui.GetColorU32({0, 0, 0, 0.8}), hp_label)
				dl_globe:AddText({hp_cx - hp_tw / 2, cy - 6},
					imgui.GetColorU32({1.0, 1.0, 1.0, 0.95}), hp_label)
				-- MP number centered in MP orb
				dl_globe:AddText({mp_cx - mp_tw / 2 + 1, cy - 5},
					imgui.GetColorU32({0, 0, 0, 0.8}), mp_label)
				dl_globe:AddText({mp_cx - mp_tw / 2, cy - 6},
					imgui.GetColorU32({1.0, 1.0, 1.0, 0.95}), mp_label)
				-- TP number below MP number inside MP orb
				dl_globe:AddText({mp_cx - tp_tw / 2 + 1, cy + 9},
					imgui.GetColorU32({0, 0, 0, 0.8}), tp_label)
				dl_globe:AddText({mp_cx - tp_tw / 2, cy + 8},
					imgui.GetColorU32({1.0, 0.9, 0.4, 0.95}), tp_label)

				----------------------------------------------------------------
				-- QOL: LOW-HP HEARTBEAT (pulse red glow around HP orb)
				----------------------------------------------------------------
				if SelfHPPercent > 0 and SelfHPPercent <= 25 then
					local critical = SelfHPPercent <= 10
					local hz       = critical and 2.4 or 1.2
					local peak     = critical and 0.85 or 0.55
					local base_a   = critical and 0.25 or 0.15
					local s        = 0.5 + 0.5 * math.sin(t_now * hz * 2 * math.pi)
					s              = s * s
					local a        = base_a + (peak - base_a) * s
					local ring_w   = critical and 5 or 4
					local col      = critical
						and imgui.GetColorU32({ 1.00, 0.20, 0.18, a })
						or  imgui.GetColorU32({ 1.00, 0.40, 0.30, a })
					dl_globe:AddCircle({hp_cx, cy}, radius + 4, col, 48, ring_w)
					dl_globe:AddCircle({hp_cx, cy}, radius + 8, 
						imgui.GetColorU32({ 1.00, 0.25, 0.20, a * 0.5 }), 48, 2)
				end

				----------------------------------------------------------------
				-- QOL: TP-FLASH IPC (next hit crosses WS tier - pulse on TP arc)
				----------------------------------------------------------------
				do
					local tp_flash_file = AshitaCore:GetInstallPath() .. 'addons\\huntpartner\\tp_flash_ipc.txt'
					local ok_tf, fh_tf = pcall(io.open, tp_flash_file, 'r')
					if ok_tf and fh_tf then
						local content = fh_tf:read('*a')
						fh_tf:close()
						if content and content:match('^1') then
							local phase = (t_now * 5.5) % (2 * math.pi)
							local alpha = 0.45 + 0.40 * math.abs(math.sin(phase))
							dl_globe:AddCircle({mp_cx, cy}, arc_r + 3,
								imgui.GetColorU32({1.0, 1.0, 0.35, alpha}), 48, 4)
						end
					end
				end

				----------------------------------------------------------------
				-- QOL: TP-THRESHOLD SPARKS (burst when crossing 1k/2k/3k)
				----------------------------------------------------------------
				do
					local cur_tier
					if SelfTP >= 3000 then cur_tier = 3
					elseif SelfTP >= 2000 then cur_tier = 2
					elseif SelfTP >= 1000 then cur_tier = 1
					else cur_tier = 0 end
					if cur_tier > tpTier.last_tier then
						tpTier.burst_at   = t_now
						tpTier.burst_tier = cur_tier
					end
					tpTier.last_tier = cur_tier

					if tpTier.burst_at > 0 then
						local since = t_now - tpTier.burst_at
						if since >= 0 and since <= TP_BURST_SECONDS then
							local t_b     = since / TP_BURST_SECONDS
							local ease    = 1.0 - (1.0 - t_b) * (1.0 - t_b)
							local fade    = 1.0 - ease
							local big     = tpTier.burst_tier == 3
							local spark_n = big and 14 or 10
							local sp_radius = (radius + 10) * (0.6 + 0.5 * ease)
							local r_c, g_c, b_c
							if big then r_c, g_c, b_c = 1.00, 0.85, 0.25
							else        r_c, g_c, b_c = 1.00, 0.95, 0.55 end
							for i = 1, spark_n do
								local ang = (i / spark_n) * 2 * math.pi + (tpTier.burst_at * 1.7)
								local len = sp_radius * (0.6 + 0.4 * math.sin(i * 1.3))
								local x1 = mp_cx + math.cos(ang) * (arc_r * 0.5)
								local y1 = cy + math.sin(ang) * (arc_r * 0.5)
								local x2 = mp_cx + math.cos(ang) * len
								local y2 = cy + math.sin(ang) * len
								dl_globe:AddLine({x1, y1}, {x2, y2},
									imgui.GetColorU32({r_c, g_c, b_c, 0.85 * fade}), 2)
							end
							-- Flash ring
							if since < 0.18 then
								local fa = 0.5 * (1.0 - since / 0.18)
								dl_globe:AddCircle({mp_cx, cy}, arc_r,
									imgui.GetColorU32({1.0, 1.0, 1.0, fa}), 48, 3)
							end
						else
							tpTier.burst_at = -1
						end
					end
				end

				----------------------------------------------------------------
				-- QOL: REST ETA (text overlay when resting)
				----------------------------------------------------------------
				do
					local rest_file = AshitaCore:GetInstallPath() .. 'addons\\huntpartner\\rest_ipc.txt'
					local ok_r, fh_r = pcall(io.open, rest_file, 'r')
					if ok_r and fh_r then
						local rdata = fh_r:read('*a')
						fh_r:close()
						if rdata and rdata:sub(1,1) == '1' then
							local parts = {}
							for p in rdata:gmatch('[^|]+') do parts[#parts+1] = p end
							if #parts >= 7 then
								local hp_full = tonumber(parts[6]) or 0
								local mp_full = tonumber(parts[7]) or 0
								local rest_label = ''
								if hp_full > 0 then
									local m = math.floor(hp_full / 60)
									local s = math.floor(hp_full % 60)
									rest_label = string.format('Full %dm%02ds', m, s)
								elseif mp_full > 0 then
									local m = math.floor(mp_full / 60)
									local s = math.floor(mp_full % 60)
									rest_label = string.format('Full %dm%02ds', m, s)
								end
								if #rest_label > 0 then
									local rtw = imgui.CalcTextSize(rest_label)
									-- Show between the orbs
									local rx = (hp_cx + mp_cx) / 2 - rtw / 2
									local ry = cy - 6
									dl_globe:AddText({rx, ry},
										imgui.GetColorU32({0.5, 1.0, 0.5, 0.9}), rest_label)
								end
							end
						end
					end
				end

				----------------------------------------------------------------
				-- QOL: HP-TICK GHOST (cyan preview in HP orb while resting)
				----------------------------------------------------------------
				if hpTick.active and SelfHPMax and SelfHPMax > 0 and SelfHP < SelfHPMax then
					local avg_hp = hpTickAverageDelta()
					if avg_hp and avg_hp > 0 then
						-- Draw a cyan arc inside HP orb showing predicted post-tick fill
						local cur_pct = SelfHP / SelfHPMax
						local pred_pct = math.min(1.0, (SelfHP + avg_hp) / SelfHPMax)
						-- Fill from cur_pct to pred_pct as cyan rows inside the orb
						local cur_y = cy + radius - (radius * 2 * cur_pct)
						local pred_y = cy + radius - (radius * 2 * pred_pct)
						local step_s = math.max(1, math.floor(radius / 20))
						local py = cur_y
						while py >= pred_y do
							local dy = py - cy
							if math.abs(dy) <= radius then
								local hw = math.sqrt(math.max(0, radius*radius - dy*dy)) - 2
								if hw > 0 then
									dl_globe:AddRectFilled(
										{hp_cx - hw, py},
										{hp_cx + hw, py + step_s},
										imgui.GetColorU32({0.4, 0.85, 1.0, 0.25}), 0, 0)
								end
							end
							py = py - step_s
						end
					end
					-- Tick countdown: arc on left side of HP orb
					local window = (#hpTick.deltas == 0) and 20.0 or 10.0
					local elapsed_hp = math.max(0, t_now - hpTick.last_t)
					local tick_frac = math.min(elapsed_hp / window, 1.0)
					local tick_arc_r = radius - 6
					local tick_segs = 16
					local tick_fill = math.floor(tick_segs * tick_frac)
					-- Draw from top going clockwise on the left side
					local tick_start = math.rad(-90)
					local tick_sweep = math.rad(-180)  -- left half
					for i = 0, tick_fill - 1 do
						local a1 = tick_start + (tick_sweep * i / tick_segs)
						local a2 = tick_start + (tick_sweep * (i + 1) / tick_segs)
						local t_c = i / tick_segs
						local cr = 0.3 + 0.7 * t_c
						local cg = 0.8 - 0.5 * t_c
						dl_globe:AddLine(
							{hp_cx + math.cos(a1) * tick_arc_r, cy + math.sin(a1) * tick_arc_r},
							{hp_cx + math.cos(a2) * tick_arc_r, cy + math.sin(a2) * tick_arc_r},
							imgui.GetColorU32({cr, cg, 0.9, 0.7}), 2)
					end
					-- Ticks-to-full count + time displayed inside the orb
					if avg_hp and avg_hp > 0 then
						local missing_hp = SelfHPMax - SelfHP
						local ticks_needed = math.ceil(missing_hp / avg_hp)
						local waste_last = (ticks_needed * avg_hp) - missing_hp
						local waste_frac = (avg_hp > 0) and (waste_last / avg_hp) or 0
						local eta = math.max(0, window - elapsed_hp)
						local total_secs = math.floor(eta + (ticks_needed - 1) * 10)
						local time_str
						if total_secs >= 60 then
							time_str = string.format('%dm%02ds', math.floor(total_secs/60), total_secs%60)
						else
							time_str = string.format('%ds', total_secs)
						end
						local tick_label = tostring(ticks_needed) .. ' ticks · ' .. time_str
						local tlw = imgui.CalcTextSize(tick_label)
						-- Color: green=clean, amber=partial waste, red=heavy waste on last tick
						local label_col
						if ticks_needed <= 1 and waste_frac <= 0.10 then
							label_col = {0.45, 0.95, 0.55, 0.9}  -- green = READY / clean
							tick_label = 'READY'
							tlw = imgui.CalcTextSize(tick_label)
						elseif waste_frac > 0.50 then
							label_col = {1.0, 0.45, 0.35, 0.9}   -- red = wasteful
							tick_label = tick_label .. ' !'
							tlw = imgui.CalcTextSize(tick_label)
						elseif waste_frac > 0.20 then
							label_col = {1.0, 0.82, 0.35, 0.9}   -- amber = partial waste
						else
							label_col = {0.5, 0.9, 1.0, 0.85}    -- cyan = clean
						end
						dl_globe:AddText({hp_cx - tlw / 2, cy + radius * 0.4},
							imgui.GetColorU32(label_col), tick_label)
					end
				end
				if mpTick.active and SelfMPMax and SelfMPMax > 0 and SelfMP < SelfMPMax then
					local avg_mp = mpTickAverageDelta()
					if avg_mp and avg_mp > 0 then
						local cur_pct = SelfMP / SelfMPMax
						local pred_pct = math.min(1.0, (SelfMP + avg_mp) / SelfMPMax)
						local cur_y = cy + radius - (radius * 2 * cur_pct)
						local pred_y = cy + radius - (radius * 2 * pred_pct)
						local step_s = math.max(1, math.floor(radius / 20))
						local py = cur_y
						while py >= pred_y do
							local dy = py - cy
							if math.abs(dy) <= radius then
								local hw = math.sqrt(math.max(0, radius*radius - dy*dy)) - 2
								if hw > 0 then
									dl_globe:AddRectFilled(
										{mp_cx - hw, py},
										{mp_cx + hw, py + step_s},
										imgui.GetColorU32({0.3, 0.5, 1.0, 0.30}), 0, 0)
								end
							end
							py = py - step_s
						end
					end
					-- Tick countdown arc on right side of MP orb
					local window = (#mpTick.deltas == 0) and 20.0 or 10.0
					local elapsed_mp = math.max(0, t_now - mpTick.last_t)
					local tick_frac = math.min(elapsed_mp / window, 1.0)
					local tick_arc_r = radius - 6
					local tick_segs = 16
					local tick_fill = math.floor(tick_segs * tick_frac)
					local tick_start = math.rad(-90)
					local tick_sweep = math.rad(180)  -- right half
					for i = 0, tick_fill - 1 do
						local a1 = tick_start + (tick_sweep * i / tick_segs)
						local a2 = tick_start + (tick_sweep * (i + 1) / tick_segs)
						local t_c = i / tick_segs
						local cr = 0.2 + 0.6 * t_c
						local cg = 0.4 + 0.3 * t_c
						dl_globe:AddLine(
							{mp_cx + math.cos(a1) * tick_arc_r, cy + math.sin(a1) * tick_arc_r},
							{mp_cx + math.cos(a2) * tick_arc_r, cy + math.sin(a2) * tick_arc_r},
							imgui.GetColorU32({cr, cg, 1.0, 0.7}), 2)
					end
					-- Ticks-to-full count + time displayed inside the orb
					if avg_mp and avg_mp > 0 then
						local missing_mp = SelfMPMax - SelfMP
						local ticks_needed = math.ceil(missing_mp / avg_mp)
						local waste_last = (ticks_needed * avg_mp) - missing_mp
						local waste_frac = (avg_mp > 0) and (waste_last / avg_mp) or 0
						local eta = math.max(0, window - elapsed_mp)
						local total_secs = math.floor(eta + (ticks_needed - 1) * 10)
						local time_str
						if total_secs >= 60 then
							time_str = string.format('%dm%02ds', math.floor(total_secs/60), total_secs%60)
						else
							time_str = string.format('%ds', total_secs)
						end
						local tick_label = tostring(ticks_needed) .. ' ticks · ' .. time_str
						local tlw = imgui.CalcTextSize(tick_label)
						-- Color: green=clean, amber=partial waste, red=heavy waste on last tick
						local label_col
						if ticks_needed <= 1 and waste_frac <= 0.10 then
							label_col = {0.45, 0.95, 0.55, 0.9}  -- green = READY / clean
							tick_label = 'READY'
							tlw = imgui.CalcTextSize(tick_label)
						elseif waste_frac > 0.50 then
							label_col = {1.0, 0.45, 0.35, 0.9}   -- red = wasteful
							tick_label = tick_label .. ' !'
							tlw = imgui.CalcTextSize(tick_label)
						elseif waste_frac > 0.20 then
							label_col = {1.0, 0.82, 0.35, 0.9}   -- amber = partial waste
						else
							label_col = {0.5, 0.7, 1.0, 0.85}    -- blue = clean
						end
						dl_globe:AddText({mp_cx - tlw / 2, cy + radius * 0.4},
							imgui.GetColorU32(label_col), tick_label)
					end
				end

				-- PRE-REST ETA: "If /heal now" projection when standing with HP/MP < max
				if not hpTick.active and SelfHPMax and SelfHPMax > 0 then
					local pre_parts = {}
					local avg_hp = hpTickAverageDelta()
					local avg_mp = mpTickAverageDelta()
					-- Fallback: read historical averages from HuntPartner IPC
					if not avg_hp or not avg_mp then
						pcall(function()
							local avg_f = io.open(AshitaCore:GetInstallPath() .. 'addons\\huntpartner\\rest_avg_ipc.txt', 'r')
							if avg_f then
								local data = avg_f:read('*a')
								avg_f:close()
								if data and #data > 0 then
									local hp_s, mp_s = data:match('([%d%.]+)|([%d%.]+)')
									if not avg_hp and hp_s then avg_hp = tonumber(hp_s) end
									if not avg_mp and mp_s then avg_mp = tonumber(mp_s) end
								end
							end
						end)
					end
					if SelfHP < SelfHPMax and avg_hp and avg_hp > 0 then
						local ticks = math.ceil((SelfHPMax - SelfHP) / avg_hp)
						local secs = 10 + ticks * 10  -- 10s sit delay + ticks*10s
						if secs >= 60 then
							pre_parts[#pre_parts+1] = string.format('HP ~%dm%02ds', math.floor(secs/60), secs%60)
						else
							pre_parts[#pre_parts+1] = string.format('HP ~%ds', secs)
						end
					end
					if SelfMPMax and SelfMPMax > 0 and SelfMP < SelfMPMax and avg_mp and avg_mp > 0 then
						local ticks = math.ceil((SelfMPMax - SelfMP) / avg_mp)
						local secs = 10 + ticks * 10
						if secs >= 60 then
							pre_parts[#pre_parts+1] = string.format('MP ~%dm%02ds', math.floor(secs/60), secs%60)
						else
							pre_parts[#pre_parts+1] = string.format('MP ~%ds', secs)
						end
					end
					if #pre_parts > 0 then
						local pre_label = '/heal: ' .. table.concat(pre_parts, ' · ')
						local plw = imgui.CalcTextSize(pre_label)
						local px = (hp_cx + mp_cx) / 2 - plw / 2
						local py = cy + radius + 4
						dl_globe:AddText({px + 1, py + 1},
							imgui.GetColorU32({0.0, 0.0, 0.0, 0.7}), pre_label)
						dl_globe:AddText({px, py},
							imgui.GetColorU32({0.55, 0.85, 0.55, 0.9}), pre_label)
					end
				end

				-- Reserve layout space (account for TP arcs extending beyond orb)
				imgui.Dummy({totalWidth + arc_margin * 2, radius * 2 + 30 + arc_margin * 2})
			end

			-- Hide the font-object texts in globe mode
			hpText:SetVisible(false)
			mpText:SetVisible(false)
			tpText:SetVisible(false)
		else

		local hpNameColor, hpGradient = GetHpColors(SelfHPPercent/100);

		local SelfJob = GetJobStr(party:GetMemberMainJob(0));
		local SelfSubJob = GetJobStr(party:GetMemberSubJob(0));
		local bShowMp = buffTable.IsSpellcaster(SelfJob) or buffTable.IsSpellcaster(SelfSubJob) or gConfig.alwaysShowMpBar;

		-- Draw HP Bar (two bars to fake animation
		local hpX = imgui.GetCursorPosX();
		local barSize = (settings.barWidth / 3) - settings.barSpacing;

		local hpPercentData = {{SelfHPPercent / 100, hpGradient}};

		if _HXUI_DEV_DEBUG_INTERPOLATION then
			hpPercentData[1][1] = 0.5;
		end

		if interpolationPercent then
			local interpolationOverlay;

			if gConfig.healthBarFlashEnabled then
				interpolationOverlay = {
					'#ffacae', -- overlay color,
					interpolationOverlayAlpha -- overlay alpha
				};
			end

			table.insert(
				hpPercentData,
				{
					interpolationPercent / 100, -- interpolation percent
					{'#cf3437', '#c54d4d'}, -- interpolation gradient
					interpolationOverlay
				}
			);
		end

		if (bShowMp == false) then
			imgui.Dummy({(barSize + settings.barSpacing) / 2, 0});

			imgui.SameLine();
		end
		
		----------------------------------------------------------------
		-- BEGIN HUNTPARTNER CURE-WASTE PATCH (player HP bar)
		-- Cure I (thin) + Cure II (thick) tick marks on the self HP bar
		-- at projected post-heal positions. Green = clean, amber = some
		-- waste, red = mostly wasted. Uses baseline heal values.
		----------------------------------------------------------------
		local hpBarScreenX, hpBarScreenY = imgui.GetCursorScreenPos();
		progressbar.ProgressBar(hpPercentData, {barSize, settings.barHeight}, {decorate = gConfig.showPlayerBarBookends});

		----------------------------------------------------------------
		-- BEGIN HUNTPARTNER LOW-HP HEARTBEAT
		-- Pulses a red glow around the HP bar when HP gets dangerous.
		-- <=25% : slow heartbeat (~1.2 Hz, gentle alpha)
		-- <=10% : fast heartbeat (~2.4 Hz, brighter alpha)
		-- Drawn on ForegroundDrawList so it's not clipped by the window.
		----------------------------------------------------------------
		if SelfHPPercent > 0 and SelfHPPercent <= 25 then
			local dl_hb
			pcall(function() dl_hb = imgui.GetForegroundDrawList() end)
			if dl_hb then
				local critical = SelfHPPercent <= 10
				local hz       = critical and 2.4 or 1.2
				local peak     = critical and 0.85 or 0.55
				local base     = critical and 0.25 or 0.15
				-- 0..1 sine, biased so it spends more time bright -> "throb"
				local s        = 0.5 + 0.5 * math.sin(currentTime * hz * 2 * math.pi)
				s              = s * s
				local a        = base + (peak - base) * s
				local ring     = critical and 4 or 3
				local color    = critical
					and imgui.GetColorU32({ 1.00, 0.20, 0.18, a })
					or  imgui.GetColorU32({ 1.00, 0.40, 0.30, a })
				-- two concentric outlines for a bloom-y feel
				dl_hb:AddRect(
					{ hpBarScreenX - ring,           hpBarScreenY - ring },
					{ hpBarScreenX + barSize + ring, hpBarScreenY + settings.barHeight + ring },
					color, 3.0, 0, 2.0)
				dl_hb:AddRect(
					{ hpBarScreenX - 1,              hpBarScreenY - 1 },
					{ hpBarScreenX + barSize + 1,    hpBarScreenY + settings.barHeight + 1 },
					imgui.GetColorU32({ 1.00, 0.30, 0.25, a * 0.7 }), 2.0, 0, 1.0)
			end
		end
		----------------------------------------------------------------
		-- END HUNTPARTNER LOW-HP HEARTBEAT
		----------------------------------------------------------------

		----------------------------------------------------------------
		-- BEGIN HUNTPARTNER HATE-HOLD HEARTBEAT
		-- Pulses a red-violet ring around the HP bar when you currently
		-- hold top hate (rank #1) on the engaged target. Distinct color
		-- from the low-HP heartbeat (which is pure red) so the two can
		-- coexist visually if you're both #1 AND low-HP at the same time.
		-- Silently no-ops when hate data is unavailable or you're not #1.
		----------------------------------------------------------------
		if _G.HuntPartnerGetHateData then
			local hd_hh = _G.HuntPartnerGetHateData();
			if hd_hh and hd_hh.my_position == 0 and hd_hh.total and hd_hh.total > 1 then
				local dl_hh
				pcall(function() dl_hh = imgui.GetForegroundDrawList() end)
				if dl_hh then
					local hz   = 1.6
					local s    = 0.5 + 0.5 * math.sin(currentTime * hz * 2 * math.pi)
					s          = s * s
					local a    = 0.20 + (0.65 - 0.20) * s
					local ring = 3
					-- red-violet so it doesn't collide with low-HP red
					dl_hh:AddRect(
						{ hpBarScreenX - ring,           hpBarScreenY - ring },
						{ hpBarScreenX + barSize + ring, hpBarScreenY + settings.barHeight + ring },
						imgui.GetColorU32({ 1.00, 0.30, 0.85, a }), 3.0, 0, 2.0)
					dl_hh:AddRect(
						{ hpBarScreenX - 1,              hpBarScreenY - 1 },
						{ hpBarScreenX + barSize + 1,    hpBarScreenY + settings.barHeight + 1 },
						imgui.GetColorU32({ 1.00, 0.55, 0.95, a * 0.7 }), 2.0, 0, 1.0)
				end
			end
		end
		----------------------------------------------------------------
		-- END HUNTPARTNER HATE-HOLD HEARTBEAT
		----------------------------------------------------------------
		do
			-- Era-baseline heal amounts (assumes ~WHM-main healing-magic skill).
			-- Used as a fallback when huntpartner has no observed cure data yet.
			local HP_CURE_HEAL = { [1]=40, [2]=135, [3]=270, [4]=500, [5]=800, [6]=1100 }
			-- Prefer observed values from huntpartner: lets sub-WHM (BLM/WHM etc.)
			-- show accurate ticks once a real cast has been observed. Falls back
			-- to the era table per-tier if no observation exists yet.
			local function effective_heal(tier)
				local obs
				if _G.HuntPartnerGetCureEstimate then
					obs = _G.HuntPartnerGetCureEstimate(tier)
				end
				return obs or HP_CURE_HEAL[tier]
			end
			if SelfHPMax and SelfHPMax > 0 and SelfHP > 0 and SelfHPPercent < 100 then
				local missing = SelfHPMax - SelfHP
				local dl
				pcall(function() dl = imgui.GetWindowDrawList() end)
				if dl then
					local function tick_color(raw)
						local waste = math.max(0, raw - missing)
						local frac_waste = (raw > 0) and (waste / raw) or 0
						if frac_waste >= 0.5 then return { 1.00, 0.45, 0.45, 0.95 } end
						if waste >= 30        then return { 1.00, 0.82, 0.35, 0.95 } end
						return { 0.55, 0.95, 0.55, 0.95 }
					end
					local function draw_cure_tick(tier, thickness)
						local raw = effective_heal(tier)
						if not raw then return end
						local projected = math.min(1.0, (SelfHP + raw) / SelfHPMax)
						local tx = hpBarScreenX + barSize * projected
						local col = imgui.GetColorU32(tick_color(raw))
						dl:AddLine({ tx, hpBarScreenY + 1 },
						           { tx, hpBarScreenY + settings.barHeight - 1 },
						           col, thickness)
					end
					draw_cure_tick(1, 2)
					draw_cure_tick(2, 3)
				end
			end
		end
		----------------------------------------------------------------
		-- END HUNTPARTNER CURE-WASTE PATCH (player HP bar)
		----------------------------------------------------------------

		----------------------------------------------------------------
		-- BEGIN HUNTPARTNER HP-TICK PATCH (overlay on HP bar)
		-- Mirrors the MP-tick overlay below: gradient countdown strip,
		-- tick-land flash + particle burst, glow halo near tick, ghost
		-- preview of next-tick HP fill, prediction label, ticks-to-cap
		-- dots with overshoot warning. Only renders while resting
		-- (status 33) AND HP < HPMax. Reuses currentTime / cyan palette
		-- for visual consistency with the MP bar.
		----------------------------------------------------------------
		if hpTick.active and SelfHPMax and SelfHPMax > 0 and SelfHP < SelfHPMax then
			local dl;
			pcall(function() dl = imgui.GetWindowDrawList() end);
			if dl then
				-- 0. Predicted-HP ghost overlay (cyan preview from current
				-- HP fill to projected post-tick fill).
				local avg_for_ghost = hpTickAverageDelta();
				if avg_for_ghost and avg_for_ghost > 0 then
					local cur_frac  = SelfHP / SelfHPMax;
					local pred_frac = math.min(1.0, (SelfHP + avg_for_ghost) / SelfHPMax);
					local cur_x  = hpBarScreenX + 1 + (barSize - 2) * cur_frac;
					local pred_x = hpBarScreenX + 1 + (barSize - 2) * pred_frac;
					if pred_x > cur_x + 1 then
						dl:AddRectFilled(
							{ cur_x, hpBarScreenY + 1 },
							{ pred_x, hpBarScreenY + settings.barHeight - 1 },
							imgui.GetColorU32({ 0.55, 0.85, 1.00, 0.30 }),
							1.0, 0);
					end
				end

				local window  = (#hpTick.deltas == 0) and 20.0 or 10.0;
				local elapsed = math.max(0, currentTime - hpTick.last_t);
				local frac    = math.min(elapsed / window, 1.0);
				local eta     = math.max(0, window - elapsed);

				local bar_h   = settings.barHeight;
				local strip_h = math.max(4, math.floor(bar_h * 0.22));
				local mx0 = hpBarScreenX + 1;
				local mx1 = hpBarScreenX + barSize - 1;
				local my1 = hpBarScreenY + bar_h - 1;
				local my0 = my1 - strip_h;

				local function lerp_rgb(a, b, t)
					return {
						a[1] + (b[1] - a[1]) * t,
						a[2] + (b[2] - a[2]) * t,
						a[3] + (b[3] - a[3]) * t,
					};
				end
				local C_DIM    = { 0.20, 0.55, 0.80 };
				local C_BRIGHT = { 0.45, 0.85, 1.00 };
				local C_AMBER  = { 1.00, 0.90, 0.55 };
				local C_WHITE  = { 1.00, 1.00, 1.00 };
				local rgb;
				if frac < 0.5 then
					rgb = lerp_rgb(C_DIM, C_BRIGHT, frac / 0.5);
				elseif frac < 0.85 then
					rgb = lerp_rgb(C_BRIGHT, C_AMBER, (frac - 0.5) / 0.35);
				else
					rgb = lerp_rgb(C_AMBER, C_WHITE, (frac - 0.85) / 0.15);
				end
				local pulse = 1.0;
				if frac >= 0.75 then
					pulse = 0.78 + 0.22 * (0.5 + 0.5 * math.sin(currentTime * 10.0));
				end

				dl:AddRectFilled({ mx0, my0 }, { mx1, my1 },
					imgui.GetColorU32({ 0.04, 0.06, 0.10, 0.85 }), 1.0, 0);
				local fx = mx0 + (mx1 - mx0) * frac;
				dl:AddRectFilled({ mx0, my0 }, { fx, my1 },
					imgui.GetColorU32({ rgb[1] * pulse, rgb[2] * pulse, rgb[3] * pulse, 0.95 }), 1.0, 0);
				if frac > 0.02 then
					local gloss_h = math.max(1, math.floor(strip_h * 0.42));
					dl:AddRectFilled({ mx0, my0 }, { fx, my0 + gloss_h },
						imgui.GetColorU32({
							math.min(rgb[1] + 0.18, 1.0),
							math.min(rgb[2] + 0.18, 1.0),
							math.min(rgb[3] + 0.18, 1.0),
							0.45,
						}), 1.0, 0);
				end
				if hpTick.flash_t > 0 then
					local since = currentTime - hpTick.flash_t;
					if since >= 0 and since < 0.30 then
						local fa = 0.85 * (1.0 - since / 0.30);
						dl:AddRectFilled(
							{ hpBarScreenX, hpBarScreenY },
							{ hpBarScreenX + barSize, hpBarScreenY + bar_h },
							imgui.GetColorU32({ 1.0, 1.0, 1.0, fa }), 1.5, 0);
					end
				end
				if hpTick.flash_t > 0 then
					local since = currentTime - hpTick.flash_t;
					if since >= 0 and since < 0.50 then
						local p = since / 0.50;
						local pa = 0.85 * (1.0 - p);
						local pr = math.max(2, math.floor(bar_h * 0.30 * (0.5 + p * 1.5)));
						local pdist = bar_h * (0.5 + p * 1.5);
						local cx = hpBarScreenX + barSize;
						local cy = hpBarScreenY + bar_h * 0.5;
						for i = 0, 7 do
							local theta = (i / 8) * math.pi * 2;
							local px = cx + math.cos(theta) * pdist;
							local py = cy + math.sin(theta) * pdist;
							dl:AddCircleFilled({ px, py }, math.max(1, pr * 0.4),
								imgui.GetColorU32({ 0.65, 0.92, 1.00, pa }), 8);
						end
					end
				end
				if eta <= 1.5 and eta > 0 then
					local intensity = 1.0 - (eta / 1.5);
					for ring = 1, 3 do
						local a = (0.22 / ring) * intensity;
						dl:AddRect(
							{ hpBarScreenX - ring,           hpBarScreenY - ring },
							{ hpBarScreenX + barSize + ring, hpBarScreenY + bar_h + ring },
							imgui.GetColorU32({ 0.55, 0.85, 1.00, a }),
							2.0 + ring, 0, 1.0);
					end
				end
				local avg = hpTickAverageDelta();
				local label;
				if avg then
					label = ('+%d HP  %.1fs'):format(math.floor(avg + 0.5), eta);
				else
					label = ('learning...  %.1fs'):format(eta);
				end
				local tw, th = imgui.CalcTextSize(label);
				local lx = hpBarScreenX + (barSize - tw) * 0.5;
				local ly = hpBarScreenY + (bar_h - th) * 0.5;
				dl:AddText({ lx + 1, ly + 1 },
					imgui.GetColorU32({ 0.0, 0.0, 0.0, 0.80 }), label);
				dl:AddText({ lx, ly },
					imgui.GetColorU32({ 1.0, 1.0, 1.0, 1.0 }), label);

				local avg_for_dots = avg;
				local dot_r        = math.max(2, math.floor(bar_h * 0.10));
				local dot_y        = hpBarScreenY - dot_r - 2;
				local dot_gap      = dot_r * 2 + 2;
				local DOT_MAX      = 8;
				if avg_for_dots and avg_for_dots > 0 then
					local hp_missing   = SelfHPMax - SelfHP;
					local ticks_to_cap = math.max(0, math.ceil(hp_missing / avg_for_dots));
					local waste_last   = (ticks_to_cap * avg_for_dots) - hp_missing;
					local waste_frac   = (avg_for_dots > 0) and (waste_last / avg_for_dots) or 0;
					local effective_ticks  = ticks_to_cap;
					local last_dot_state   = 'clean';
					if ticks_to_cap >= 1 then
						if waste_frac > 0.50 then
							effective_ticks = ticks_to_cap - 1;
							if effective_ticks >= 1 then
								last_dot_state = 'warning_next';
							end
						elseif waste_frac > 0.10 then
							last_dot_state = 'partial_waste';
						end
					end
					local shown        = math.min(effective_ticks, DOT_MAX);
					local dot_x0       = hpBarScreenX + barSize - (dot_gap * math.max(shown, 1));
					local amber_pulse = 0.55 + 0.45 * (0.5 + 0.5 * math.sin(currentTime * 8.0));
					for i = 1, shown do
						local cx = dot_x0 + (i - 1) * dot_gap + dot_r;
						local col = { 0.50, 0.90, 1.00, 0.95 };
						if i == shown then
							if last_dot_state == 'warning_next' or last_dot_state == 'partial_waste' then
								col = { 1.00, 0.82, 0.35, 0.95 * amber_pulse };
							end
						end
						dl:AddCircleFilled({ cx, dot_y + dot_r },
							dot_r, imgui.GetColorU32(col), 12);
					end
					if effective_ticks > DOT_MAX then
						local plus_x = dot_x0 - dot_gap;
						dl:AddText({ plus_x, dot_y - 2 },
							imgui.GetColorU32({ 0.50, 0.90, 1.00, 0.95 }), '+');
					end
					local show_ready = (effective_ticks == 0)
						or (ticks_to_cap <= 1 and waste_frac <= 0.10);
					if show_ready then
						local ready = 'READY';
						local rw, rh = imgui.CalcTextSize(ready);
						local rx = hpBarScreenX + barSize - rw - 2;
						local ry = hpBarScreenY - rh - dot_r * 2 - 4;
						dl:AddText({ rx + 1, ry + 1 },
							imgui.GetColorU32({ 0.0, 0.0, 0.0, 0.85 }), ready);
						dl:AddText({ rx, ry },
							imgui.GetColorU32({ 0.45, 0.95, 0.55, 1.0 }), ready);
					end
				else
					local dot_x0 = hpBarScreenX + barSize - (dot_gap * 3);
					for i = 1, 3 do
						local cx = dot_x0 + (i - 1) * dot_gap + dot_r;
						dl:AddCircleFilled({ cx, dot_y + dot_r },
							dot_r, imgui.GetColorU32({ 0.30, 0.35, 0.45, 0.60 }), 12);
					end
				end
			end
		end
		----------------------------------------------------------------
		-- END HUNTPARTNER HP-TICK PATCH
		----------------------------------------------------------------

		----------------------------------------------------------------
		-- BEGIN REGEN-GHOST PATCH (overlay on HP bar)
		-- Green translucent preview showing how much HP the Regen buff
		-- will restore over the next few ticks, so you can decide whether
		-- a cure is needed (and avoid over-healing). Only renders while
		-- Regen is active, you're NOT resting (the cyan rest ghost owns
		-- that case), and HP < HPMax. Pairs with the cure-waste tick
		-- marks above: if the green ghost already reaches a cure tick,
		-- regen alone will get you there.
		----------------------------------------------------------------
		if regenTick.active and SelfHPMax and SelfHPMax > 0 and SelfHP < SelfHPMax then
			local avg = regenTickAverageDelta();
			if avg and avg > 0 then
				local dl;
				pcall(function() dl = imgui.GetWindowDrawList() end);
				if dl then
					local projHeal  = avg * REGEN_GHOST_TICKS;
					local capped    = math.min(projHeal, SelfHPMax - SelfHP);
					local cur_frac  = SelfHP / SelfHPMax;
					local pred_frac = math.min(1.0, (SelfHP + projHeal) / SelfHPMax);
					local cur_x  = hpBarScreenX + 1 + (barSize - 2) * cur_frac;
					local pred_x = hpBarScreenX + 1 + (barSize - 2) * pred_frac;
					if pred_x > cur_x + 1 then
						-- Green regen ghost (distinct from the cyan rest ghost).
						dl:AddRectFilled(
							{ cur_x, hpBarScreenY + 1 },
							{ pred_x, hpBarScreenY + settings.barHeight - 1 },
							imgui.GetColorU32({ 0.40, 0.95, 0.45, 0.30 }),
							1.0, 0);
						-- Bright leading edge at the projected fill point.
						dl:AddLine(
							{ pred_x, hpBarScreenY + 1 },
							{ pred_x, hpBarScreenY + settings.barHeight - 1 },
							imgui.GetColorU32({ 0.55, 1.00, 0.60, 0.85 }), 1.5);
						-- Compact "+N" amount above the projected edge.
						local label  = ('+%d'):format(math.floor(capped + 0.5));
						local tw, th = imgui.CalcTextSize(label);
						local lx = math.min(pred_x - tw * 0.5, hpBarScreenX + barSize - tw);
						lx = math.max(lx, hpBarScreenX);
						local ly = hpBarScreenY - th - 1;
						dl:AddText({ lx + 1, ly + 1 },
							imgui.GetColorU32({ 0.0, 0.0, 0.0, 0.80 }), label);
						dl:AddText({ lx, ly },
							imgui.GetColorU32({ 0.70, 1.00, 0.72, 1.0 }), label);
					end
				end
			end
		end
		----------------------------------------------------------------
		-- END REGEN-GHOST PATCH
		----------------------------------------------------------------

		imgui.SameLine();
		local hpEndX = imgui.GetCursorPosX();
		local hpLocX, hpLocY = imgui.GetCursorScreenPos();	
		if (SelfHPPercent > 0) then
			imgui.SetCursorPosX(hpX);

			imgui.SameLine();
		end

		local mpLocX
		local mpLocY;
		
		if (bShowMp) then
			-- Draw MP Bar (huntpartner color: blue instead of HXUI's green)
			imgui.SetCursorPosX(hpEndX + settings.barSpacing);
			local mpBarScreenX, mpBarScreenY = imgui.GetCursorScreenPos();
			progressbar.ProgressBar({{SelfMPPercent / 100, {'#3a7fc4', '#6ba8e0'}}}, {barSize, settings.barHeight}, {decorate = gConfig.showPlayerBarBookends});

			----------------------------------------------------------------
			-- BEGIN HUNTPARTNER MP-TICK PATCH (overlay on MP bar)
			-- AAA loadout on top of the basic huntpartner countdown strip:
			--   1. Bottom countdown strip with cyan->amber->white gradient
			--   2. White flash overlay on tick land (0.30s fade)
			--   3. Outer glow halo (3 rings, mp-blue) in last 1.5s before tick
			--   4. Centered "+N MP / next Xs" prediction text (drop-shadow)
			--   5. Pulse on the gradient fill in the final ~25% of window
			--   6. Sample confidence dots above the bar (fill as we observe)
			-- All draws use the MP bar's window draw list; ~10 calls per
			-- frame while resting, zero when not. No per-frame allocation.
			----------------------------------------------------------------
			if mpTick.active and SelfMPMax and SelfMPMax > 0 and SelfMP < SelfMPMax then
				local dl;
				pcall(function() dl = imgui.GetWindowDrawList() end);
				if dl then
					-- 0. PREDICTED-MP GHOST: a translucent preview segment on
					-- the MP bar from current-MP-fill to predicted-after-tick
					-- position. Mirrors the cure-ghost pattern on the HP bar.
					-- Tells you exactly where the bar will jump to on the
					-- next tick (and whether it'll cap).
					local avg_for_ghost = mpTickAverageDelta();
					if avg_for_ghost and avg_for_ghost > 0 then
						local cur_frac     = SelfMP / SelfMPMax;
						local pred_frac    = math.min(1.0, (SelfMP + avg_for_ghost) / SelfMPMax);
						local cur_x        = mpBarScreenX + (settings.barHeight > 0 and 1 or 0)
							+ (barSize - 2) * cur_frac;
						local pred_x       = mpBarScreenX + 1 + (barSize - 2) * pred_frac;
						if pred_x > cur_x + 1 then
							dl:AddRectFilled(
								{ cur_x, mpBarScreenY + 1 },
								{ pred_x, mpBarScreenY + settings.barHeight - 1 },
								imgui.GetColorU32({ 0.55, 0.85, 1.00, 0.30 }),
								1.0, 0);
						end
					end

					-- Tick window: 20s for first tick after rest start (no
					-- samples yet), 10s once we've observed at least one.
					local window  = (#mpTick.deltas == 0) and 20.0 or 10.0;
					local elapsed = math.max(0, currentTime - mpTick.last_t);
					local frac    = math.min(elapsed / window, 1.0);
					local eta     = math.max(0, window - elapsed);

					local bar_h   = settings.barHeight;
					local strip_h = math.max(4, math.floor(bar_h * 0.22));
					local mx0 = mpBarScreenX + 1;
					local mx1 = mpBarScreenX + barSize - 1;
					local my1 = mpBarScreenY + bar_h - 1;
					local my0 = my1 - strip_h;

					-- 1. Gradient strip. Three-stop ramp:
					--    frac 0.0 -> dim cyan, 0.5 -> bright cyan,
					--    1.0 -> near-white (the "ready" glow).
					local function lerp_rgb(a, b, t)
						return {
							a[1] + (b[1] - a[1]) * t,
							a[2] + (b[2] - a[2]) * t,
							a[3] + (b[3] - a[3]) * t,
						};
					end
					local C_DIM    = { 0.20, 0.55, 0.80 };
					local C_BRIGHT = { 0.45, 0.85, 1.00 };
					local C_AMBER  = { 1.00, 0.90, 0.55 };
					local C_WHITE  = { 1.00, 1.00, 1.00 };
					local rgb;
					if frac < 0.5 then
						rgb = lerp_rgb(C_DIM, C_BRIGHT, frac / 0.5);
					elseif frac < 0.85 then
						rgb = lerp_rgb(C_BRIGHT, C_AMBER, (frac - 0.5) / 0.35);
					else
						rgb = lerp_rgb(C_AMBER, C_WHITE, (frac - 0.85) / 0.15);
					end

					-- 5. Pulse in final 25% of window: 5 Hz on alpha 0.78..1.00.
					local pulse = 1.0;
					if frac >= 0.75 then
						pulse = 0.78 + 0.22 * (0.5 + 0.5 * math.sin(currentTime * 10.0));
					end

					-- Backdrop for the strip so the fill reads even at low frac.
					dl:AddRectFilled({ mx0, my0 }, { mx1, my1 },
						imgui.GetColorU32({ 0.04, 0.06, 0.10, 0.85 }), 1.0, 0);
					-- Fill
					local fx = mx0 + (mx1 - mx0) * frac;
					dl:AddRectFilled({ mx0, my0 }, { fx, my1 },
						imgui.GetColorU32({ rgb[1] * pulse, rgb[2] * pulse, rgb[3] * pulse, 0.95 }), 1.0, 0);
					-- Gloss strip on top half of the fill.
					if frac > 0.02 then
						local gloss_h = math.max(1, math.floor(strip_h * 0.42));
						dl:AddRectFilled({ mx0, my0 }, { fx, my0 + gloss_h },
							imgui.GetColorU32({
								math.min(rgb[1] + 0.18, 1.0),
								math.min(rgb[2] + 0.18, 1.0),
								math.min(rgb[3] + 0.18, 1.0),
								0.45,
							}), 1.0, 0);
					end

					-- 2. White flash on tick land (fades over 0.30s).
					if mpTick.flash_t > 0 then
						local since = currentTime - mpTick.flash_t;
						if since >= 0 and since < 0.30 then
							local fa = 0.85 * (1.0 - since / 0.30);
							dl:AddRectFilled(
								{ mpBarScreenX, mpBarScreenY },
								{ mpBarScreenX + barSize, mpBarScreenY + bar_h },
								imgui.GetColorU32({ 1.0, 1.0, 1.0, fa }), 1.5, 0);
						end
					end

					-- 2b. TICK-BURST PARTICLES: 8 small circles radiating
					-- outward from the bar's right edge on tick land. Radius
					-- grows, alpha falls. ~0.5s lifespan. The "satisfying"
					-- feedback beat — MP gain feels rewarded.
					if mpTick.flash_t > 0 then
						local since = currentTime - mpTick.flash_t;
						if since >= 0 and since < 0.50 then
							local p = since / 0.50;       -- 0..1 progress
							local pa = 0.85 * (1.0 - p);  -- alpha fades
							local pr = math.max(2, math.floor(bar_h * 0.30 * (0.5 + p * 1.5)));
							local pdist = bar_h * (0.5 + p * 1.5);
							local cx = mpBarScreenX + barSize;
							local cy = mpBarScreenY + bar_h * 0.5;
							for i = 0, 7 do
								local theta = (i / 8) * math.pi * 2;
								local px = cx + math.cos(theta) * pdist;
								local py = cy + math.sin(theta) * pdist;
								dl:AddCircleFilled({ px, py }, math.max(1, pr * 0.4),
									imgui.GetColorU32({ 0.65, 0.92, 1.00, pa }), 8);
							end
						end
					end

					-- 3. Outer glow halo: 3 rings of mp-blue in last 1.5s.
					if eta <= 1.5 and eta > 0 then
						local intensity = 1.0 - (eta / 1.5);  -- 0..1 ramp
						for ring = 1, 3 do
							local a = (0.22 / ring) * intensity;
							dl:AddRect(
								{ mpBarScreenX - ring,           mpBarScreenY - ring },
								{ mpBarScreenX + barSize + ring, mpBarScreenY + bar_h + ring },
								imgui.GetColorU32({ 0.55, 0.85, 1.00, a }),
								2.0 + ring, 0, 1.0);
						end
					end

					-- 4. Centered prediction text. Drop-shadow for legibility
					-- across the gradient. Shows +N MP and seconds remaining.
					local avg = mpTickAverageDelta();
					local label;
					if avg then
						label = ('+%d MP  %.1fs'):format(math.floor(avg + 0.5), eta);
					else
						label = ('learning...  %.1fs'):format(eta);
					end
					local tw, th = imgui.CalcTextSize(label);
					local lx = mpBarScreenX + (barSize - tw) * 0.5;
					local ly = mpBarScreenY + (bar_h - th) * 0.5;
					dl:AddText({ lx + 1, ly + 1 },
						imgui.GetColorU32({ 0.0, 0.0, 0.0, 0.80 }), label);
					dl:AddText({ lx, ly },
						imgui.GetColorU32({ 1.0, 1.0, 1.0, 1.0 }), label);

					-- 6. Ticks-to-cap dots above the bar. Each filled dot = one
					-- more MP tick needed to hit your cap, based on observed
					-- average delta. The LAST dot is colored by overshoot:
					-- cyan = clean (last tick lands at-or-just-under cap),
					-- amber = some waste (last tick partially overflows),
					-- red   = mostly wasted (>50% of last tick overflows).
					-- Mirrors the cure-waste tick logic on the HP bar.
					local avg_for_dots = mpTickAverageDelta();
					local dot_r        = math.max(2, math.floor(bar_h * 0.10));
					local dot_y        = mpBarScreenY - dot_r - 2;
					local dot_gap      = dot_r * 2 + 2;
					local DOT_MAX      = 8;
					if avg_for_dots and avg_for_dots > 0 then
						local mp_missing   = SelfMPMax - SelfMP;
						local ticks_to_cap = math.max(0, math.ceil(mp_missing / avg_for_dots));
						-- If the LAST tick of the literal count would mostly
						-- overshoot (>50%), don't count it as a tick you
						-- "need." Drop it and amber the new last dot to mean
						-- "next tick after this would waste a lot — stand if
						-- you don't need every drop of MP." Avoids the
						-- 'blue+red = need 2 ticks' confusion.
						local waste_last   = (ticks_to_cap * avg_for_dots) - mp_missing;
						local waste_frac   = (avg_for_dots > 0) and (waste_last / avg_for_dots) or 0;
						-- Three-tier last-dot semantics:
						--   waste > 50%: drop the dot (next tick mostly
						--     overshoots). If a previous dot remains, amber
						--     it to mean "stand up after this." If we drop
						--     to 0 dots, READY hint fires instead.
						--   waste 10-50%: keep the dot, color it amber and
						--     pulse — "this tick lands but partially wastes."
						--   waste <= 10%: clean cyan.
						local effective_ticks  = ticks_to_cap;
						local last_dot_state   = 'clean';
						if ticks_to_cap >= 1 then
							if waste_frac > 0.50 then
								effective_ticks = ticks_to_cap - 1;
								if effective_ticks >= 1 then
									last_dot_state = 'warning_next';
								end
							elseif waste_frac > 0.10 then
								last_dot_state = 'partial_waste';
							end
						end
						local shown        = math.min(effective_ticks, DOT_MAX);
						local dot_x0       = mpBarScreenX + barSize - (dot_gap * math.max(shown, 1));
						local amber_pulse = 0.55 + 0.45 * (0.5 + 0.5 * math.sin(currentTime * 8.0));
						for i = 1, shown do
							local cx = dot_x0 + (i - 1) * dot_gap + dot_r;
							local col = { 0.50, 0.90, 1.00, 0.95 };  -- clean cyan
							if i == shown then
								if last_dot_state == 'warning_next' or last_dot_state == 'partial_waste' then
									col = { 1.00, 0.82, 0.35, 0.95 * amber_pulse };  -- amber+pulse
								end
							end
							dl:AddCircleFilled({ cx, dot_y + dot_r },
								dot_r, imgui.GetColorU32(col), 12);
						end
						if effective_ticks > DOT_MAX then
							local plus_x = dot_x0 - dot_gap;
							dl:AddText({ plus_x, dot_y - 2 },
								imgui.GetColorU32({ 0.50, 0.90, 1.00, 0.95 }), '+');
						end
						-- READY hint: stand up now is the right call when
						-- either (a) the only remaining tick would mostly
						-- overshoot (effective_ticks == 0), or (b) we're one
						-- clean tick from cap (ticks_to_cap == 1 and waste low).
						local show_ready = (effective_ticks == 0)
							or (ticks_to_cap <= 1 and waste_frac <= 0.10);
						if show_ready then
							local ready = 'READY';
							local rw, rh = imgui.CalcTextSize(ready);
							local rx = mpBarScreenX + barSize - rw - 2;
							local ry = mpBarScreenY - rh - dot_r * 2 - 4;
							dl:AddText({ rx + 1, ry + 1 },
								imgui.GetColorU32({ 0.0, 0.0, 0.0, 0.85 }), ready);
							dl:AddText({ rx, ry },
								imgui.GetColorU32({ 0.45, 0.95, 0.55, 1.0 }), ready);
						end
					else
						-- No samples yet -> 3 dim dots as a "learning" placeholder.
						local dot_x0 = mpBarScreenX + barSize - (dot_gap * 3);
						for i = 1, 3 do
							local cx = dot_x0 + (i - 1) * dot_gap + dot_r;
							dl:AddCircleFilled({ cx, dot_y + dot_r },
								dot_r, imgui.GetColorU32({ 0.30, 0.35, 0.45, 0.60 }), 12);
						end
					end
				end
			end
			----------------------------------------------------------------
			-- END HUNTPARTNER MP-TICK PATCH
			----------------------------------------------------------------

			imgui.SameLine();
			mpLocX, mpLocY  = imgui.GetCursorScreenPos()
		end
		
		-- Draw TP Bars
		imgui.SetCursorPosX(imgui.GetCursorPosX() + settings.barSpacing);
		
		-- HUNTPARTNER COLOR PATCH: orange TP to match player bar convention
		local tpGradient = {'#d68a1e', '#f0b85a'};
		local mainPercent;
		local tpOverlay;
		
		if (SelfTP >= 1000) then
			mainPercent = (SelfTP - 1000) / 2000;

			local tpOverlayGradient = {'#b86b00', '#b86b00'};

			tpOverlay = {
				{
					1, -- overlay percent
					tpOverlayGradient -- overlay gradient
				},
				math.ceil(settings.barHeight * 2/7), -- overlay height
				1, -- overlay vertical padding
				{
					'#ffd966', -- overlay pulse color
					1 -- overlay pulse seconds
				}
			};
		else
			mainPercent = SelfTP / 1000;
		end
		
		local tpBarScreenX, tpBarScreenY = imgui.GetCursorScreenPos();
		progressbar.ProgressBar({{mainPercent, tpGradient}}, {barSize, settings.barHeight}, {overlayBar=tpOverlay, decorate = gConfig.showPlayerBarBookends});

		----------------------------------------------------------------
		-- BEGIN HUNTPARTNER TP-THRESHOLD SPARKS
		-- Detects an upward crossing of 1000/2000/3000 TP and fires a
		-- ~0.65s spark burst from the matching tier line. Tier 3 (3000)
		-- gets the brightest/largest burst since it's the max TP cap.
		----------------------------------------------------------------
		do
			local cur_tier
			if SelfTP >= 3000 then cur_tier = 3
			elseif SelfTP >= 2000 then cur_tier = 2
			elseif SelfTP >= 1000 then cur_tier = 1
			else cur_tier = 0 end
			if cur_tier > tpTier.last_tier then
				tpTier.burst_at   = currentTime
				tpTier.burst_tier = cur_tier
			end
			tpTier.last_tier = cur_tier

			if tpTier.burst_at > 0 then
				local since = currentTime - tpTier.burst_at
				if since >= 0 and since <= TP_BURST_SECONDS then
					local dl_sp
					pcall(function() dl_sp = imgui.GetForegroundDrawList() end)
					if dl_sp then
						local t       = since / TP_BURST_SECONDS  -- 0..1
						local ease    = 1.0 - (1.0 - t) * (1.0 - t)  -- ease-out
						local fade    = 1.0 - ease
						local big     = tpTier.burst_tier == 3
						local spark_n = big and 12 or 8
						local radius  = (big and 22 or 14) * (0.4 + 0.6 * ease)
						-- Anchor at the threshold line of the burst tier.
						local x_anchor = tpBarScreenX + math.floor(barSize * tpTier.burst_tier / 3)
						if tpTier.burst_tier == 3 then x_anchor = tpBarScreenX + barSize - 2 end
						local y_anchor = tpBarScreenY + settings.barHeight * 0.5
						-- Tier color: gold for 3000 (max), warm yellow otherwise.
						local r,g,b
						if big then r,g,b = 1.00, 0.85, 0.25
						else        r,g,b = 1.00, 0.95, 0.55 end
						-- Radial spark lines
						for i = 1, spark_n do
							local ang = (i / spark_n) * 2 * math.pi + (tpTier.burst_at * 1.7)
							local len = radius * (0.7 + 0.3 * math.sin(i * 1.3))
							local x1  = x_anchor + math.cos(ang) * (radius * 0.25)
							local y1  = y_anchor + math.sin(ang) * (radius * 0.25)
							local x2  = x_anchor + math.cos(ang) * len
							local y2  = y_anchor + math.sin(ang) * len
							dl_sp:AddLine({ x1, y1 }, { x2, y2 },
								imgui.GetColorU32({ r, g, b, 0.85 * fade }), 1.5)
						end
						-- Central flash dot
						local cflash = imgui.GetColorU32({ 1.0, 1.0, 0.9, 0.85 * fade })
						dl_sp:AddRectFilled(
							{ x_anchor - 3, y_anchor - 3 },
							{ x_anchor + 3, y_anchor + 3 },
							cflash, 2.0, 0)
						-- Brief white edge-flash across the TP bar
						if since < 0.18 then
							local fa = 0.50 * (1.0 - since / 0.18)
							dl_sp:AddRectFilled(
								{ tpBarScreenX, tpBarScreenY },
								{ tpBarScreenX + barSize, tpBarScreenY + settings.barHeight },
								imgui.GetColorU32({ 1.0, 1.0, 1.0, fa }), 2.0, 0)
						end
					end
				else
					tpTier.burst_at = -1
				end
			end
		end
		----------------------------------------------------------------
		-- END HUNTPARTNER TP-THRESHOLD SPARKS
		----------------------------------------------------------------

		----------------------------------------------------------------
		-- BEGIN HUNTPARTNER TP-SLASH PATCH (player TP bar)
		-- Diagonal slash marks at each 1k/2k/3k threshold so you can read
		-- TP tier at a glance without doing math on the fill width.
		----------------------------------------------------------------
		do
			local dl
			pcall(function() dl = imgui.GetWindowDrawList() end)
			if dl then
				local slash_col = imgui.GetColorU32({ 1.0, 1.0, 1.0, 0.85 })
				local lean = math.max(2, math.floor(settings.barHeight * 0.18))
				local y_top = tpBarScreenY + 2
				local y_bot = tpBarScreenY + settings.barHeight - 2
				for tier = 1, 3 do
					if SelfTP >= tier * 1000 then
						local x_center = tpBarScreenX + math.floor(barSize * tier / 3)
						if tier == 3 then x_center = x_center - lean end
						dl:AddLine(
							{ x_center + lean, y_top },
							{ x_center - lean, y_bot },
							slash_col, 2)
					end
				end
			end
		end
		----------------------------------------------------------------
		-- END HUNTPARTNER TP-SLASH PATCH
		----------------------------------------------------------------

		----------------------------------------------------------------
		-- BEGIN HUNTPARTNER TP-FLASH IPC (next hit crosses WS tier)
		-- Reads tp_flash_ipc.txt from huntpartner; pulses the TP bar
		-- yellow when the next melee swing will cross 1k/2k/3k TP.
		----------------------------------------------------------------
		do
			local tp_flash_file = AshitaCore:GetInstallPath() .. 'addons\\huntpartner\\tp_flash_ipc.txt'
			local ok, fh = pcall(io.open, tp_flash_file, 'r')
			if ok and fh then
				local content = fh:read('*a')
				fh:close()
				if content and content:match('^1') then
					local dl_tf
					pcall(function() dl_tf = imgui.GetForegroundDrawList() end)
					if dl_tf then
						local phase = (os.clock() * 5.5) % (2 * math.pi)
						local alpha = 0.45 + 0.40 * math.abs(math.sin(phase))
						local col = imgui.GetColorU32({ 1.0, 1.0, 0.35, alpha })
						dl_tf:AddRectFilled(
							{ tpBarScreenX, tpBarScreenY },
							{ tpBarScreenX + barSize, tpBarScreenY + settings.barHeight },
							col, 2.0, 0)
					end
				end
			end
		end
		----------------------------------------------------------------
		-- END HUNTPARTNER TP-FLASH IPC
		----------------------------------------------------------------

		imgui.SameLine();

		local tpLocX, tpLocY  = imgui.GetCursorScreenPos();
		
		-- Update our HP Text
		hpText:SetPositionX(hpLocX - settings.barSpacing - settings.barHeight / 2);
		hpText:SetPositionY(hpLocY + settings.barHeight + settings.textYOffset);
		hpText:SetText((SelfHPPercent > 0 and SelfHPPercent < 100) and (tostring(SelfHP) .. ' (' .. tostring(SelfHPPercent) .. '%)') or tostring(SelfHP));
		hpText:SetColor(hpNameColor);
		
		hpText:SetVisible(true);

		if (bShowMp) then
			-- Update our MP Text
			mpText:SetPositionX(mpLocX - settings.barSpacing - settings.barHeight / 2);
			mpText:SetPositionY(mpLocY + settings.barHeight + settings.textYOffset);
			mpText:SetText((SelfMPPercent > 0 and SelfMPPercent < 100) and (tostring(SelfMP) .. ' (' .. tostring(SelfMPPercent) .. '%)') or tostring(SelfMP));
			mpText:SetColor(gAdjustedSettings.mpColor);
		end

		mpText:SetVisible(bShowMp);
			
		-- Update our TP Text
		tpText:SetPositionX(tpLocX - settings.barSpacing - settings.barHeight / 2);
		tpText:SetPositionY(tpLocY + settings.barHeight + settings.textYOffset);
		tpText:SetText(tostring(SelfTP));

		if (SelfTP >= 1000) then 
			tpText:SetColor(gAdjustedSettings.tpFullColor);
		else
			tpText:SetColor(gAdjustedSettings.tpEmptyColor);
	    end

		tpText:SetVisible(true);
		end -- end of else (bar mode)
    end
	imgui.End();

	----------------------------------------------------------------
end


playerbar.Initialize = function(settings)
    hpText = fonts.new(settings.font_settings);
	mpText = fonts.new(settings.font_settings);
	tpText = fonts.new(settings.font_settings);
end

playerbar.UpdateFonts = function(settings)
    hpText:SetFontHeight(settings.font_settings.font_height);
	mpText:SetFontHeight(settings.font_settings.font_height);
	tpText:SetFontHeight(settings.font_settings.font_height);
end

playerbar.SetHidden = function(hidden)
	if (hidden == true) then
		UpdateTextVisibility(false);
	end
end

return playerbar;