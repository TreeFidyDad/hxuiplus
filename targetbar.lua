require('common');
require('helpers');
local imgui = require('imgui');
local statusHandler = require('statushandler');
local debuffHandler = require('debuffhandler');
local progressbar = require('progressbar');
local fonts = require('fonts');
local ffi = require("ffi");

-- TODO: Calculate these instead of manually setting them

local bgAlpha = 0.4;
local bgRadius = 3;

local arrowTexture;
local percentText;
local nameText;
local totNameText;
local distText;
local targetbar = {
	interpolation = {}
};

local function UpdateTextVisibility(visible)
	percentText:SetVisible(visible);
	nameText:SetVisible(visible);
	totNameText:SetVisible(visible);
	distText:SetVisible(visible);
end

local _HXUI_DEV_DEBUG_INTERPOLATION = false;
local _HXUI_DEV_DEBUG_INTERPOLATION_DELAY = 1;
local _HXUI_DEV_DEBUG_HP_PERCENT_PERSISTENT = 100;
local _HXUI_DEV_DAMAGE_SET_TIMES = {};

targetbar.DrawWindow = function(settings)
    -- Obtain the player entity..
    local playerEnt = GetPlayerEntity();
	local player = AshitaCore:GetMemoryManager():GetPlayer();
    if (playerEnt == nil or player == nil) then
		UpdateTextVisibility(false);
        return;
    end

    -- Obtain the player target entity (account for subtarget)
	local playerTarget = AshitaCore:GetMemoryManager():GetTarget();
	local targetIndex;
	local targetEntity;
	if (playerTarget ~= nil) then
		targetIndex, _ = GetTargets();
		targetEntity = GetEntity(targetIndex);
	end
    if (targetEntity == nil or targetEntity.Name == nil) then
		UpdateTextVisibility(false);

		targetbar.interpolation.interpolationDamagePercent = 0;

        return;
    end

	local currentTime = os.clock();

	local hppPercent = targetEntity.HPPercent;

	-- Mimic damage taken
	if _HXUI_DEV_DEBUG_INTERPOLATION then
		if _HXUI_DEV_DAMAGE_SET_TIMES[1] and currentTime > _HXUI_DEV_DAMAGE_SET_TIMES[1][1] then
			_HXUI_DEV_DEBUG_HP_PERCENT_PERSISTENT = _HXUI_DEV_DAMAGE_SET_TIMES[1][2];

			table.remove(_HXUI_DEV_DAMAGE_SET_TIMES, 1);
		end

		if #_HXUI_DEV_DAMAGE_SET_TIMES == 0 then
			local previousHitTime = currentTime + 1;
			local previousHp = 100;

			local totalDamageInstances = 10;

			for i = 1, totalDamageInstances do
				local hitDelay = math.random(0.25 * 100, 1.25 * 100) / 100;
				local damageAmount = math.random(1, 20);

				if i > 1 and i < totalDamageInstances then
					previousHp = math.max(previousHp - damageAmount, 0);
				end

				if i < totalDamageInstances then
					previousHitTime = previousHitTime + hitDelay;
				else
					previousHitTime = previousHitTime + _HXUI_DEV_DEBUG_INTERPOLATION_DELAY;
				end

				_HXUI_DEV_DAMAGE_SET_TIMES[i] = {previousHitTime, previousHp};
			end
		end

		hppPercent = _HXUI_DEV_DEBUG_HP_PERCENT_PERSISTENT;
	end

	-- If we change targets, reset the interpolation
	if targetbar.interpolation.currentTargetId ~= targetIndex then
		targetbar.interpolation.currentTargetId = targetIndex;
		targetbar.interpolation.currentHpp = hppPercent;
		targetbar.interpolation.interpolationDamagePercent = 0;
	end

	-- If the target takes damage
	if hppPercent < targetbar.interpolation.currentHpp then
		local previousInterpolationDamagePercent = targetbar.interpolation.interpolationDamagePercent;

		local damageAmount = targetbar.interpolation.currentHpp - hppPercent;

		targetbar.interpolation.interpolationDamagePercent = targetbar.interpolation.interpolationDamagePercent + damageAmount;

		if previousInterpolationDamagePercent > 0 and targetbar.interpolation.lastHitAmount and damageAmount > targetbar.interpolation.lastHitAmount then
			targetbar.interpolation.lastHitTime = currentTime;
			targetbar.interpolation.lastHitAmount = damageAmount;
		elseif previousInterpolationDamagePercent == 0 then
			targetbar.interpolation.lastHitTime = currentTime;
			targetbar.interpolation.lastHitAmount = damageAmount;
		end

		if not targetbar.interpolation.lastHitTime or currentTime > targetbar.interpolation.lastHitTime + (settings.hitFlashDuration * 0.25) then
			targetbar.interpolation.lastHitTime = currentTime;
			targetbar.interpolation.lastHitAmount = damageAmount;
		end

		-- If we previously were interpolating with an empty bar, reset the hit delay effect
		if previousInterpolationDamagePercent == 0 then
			targetbar.interpolation.hitDelayStartTime = currentTime;
		end
	elseif hppPercent > targetbar.interpolation.currentHpp then
		-- If the target heals
		targetbar.interpolation.interpolationDamagePercent = 0;
		targetbar.interpolation.hitDelayStartTime = nil;
	end

	targetbar.interpolation.currentHpp = hppPercent;

	-- Reduce the HP amount to display based on the time passed since last frame
	if targetbar.interpolation.interpolationDamagePercent > 0 and targetbar.interpolation.hitDelayStartTime and currentTime > targetbar.interpolation.hitDelayStartTime + settings.hitDelayDuration then
		if targetbar.interpolation.lastFrameTime then
			local deltaTime = currentTime - targetbar.interpolation.lastFrameTime;

			local animSpeed = 0.1 + (0.9 * (targetbar.interpolation.interpolationDamagePercent / 100));

			-- animSpeed = math.max(settings.hitDelayMinAnimSpeed, animSpeed);

			targetbar.interpolation.interpolationDamagePercent = targetbar.interpolation.interpolationDamagePercent - (settings.hitInterpolationDecayPercentPerSecond * deltaTime * animSpeed);

			-- Clamp our percent to 0
			targetbar.interpolation.interpolationDamagePercent = math.max(0, targetbar.interpolation.interpolationDamagePercent);
		end
	end

	if gConfig.healthBarFlashEnabled then
		if targetbar.interpolation.lastHitTime and currentTime < targetbar.interpolation.lastHitTime + settings.hitFlashDuration then
			local hitFlashTime = currentTime - targetbar.interpolation.lastHitTime;
			local hitFlashTimePercent = hitFlashTime / settings.hitFlashDuration;

			local maxAlphaHitPercent = 20;
			local maxAlpha = math.min(targetbar.interpolation.lastHitAmount, maxAlphaHitPercent) / maxAlphaHitPercent;

			maxAlpha = math.max(maxAlpha * 0.6, 0.4);

			targetbar.interpolation.overlayAlpha = math.pow(1 - hitFlashTimePercent, 2) * maxAlpha;
		end
	end

	targetbar.interpolation.lastFrameTime = currentTime;

	local color = GetColorOfTarget(targetEntity, targetIndex);
	local isMonster = GetIsMob(targetEntity);

	-- Draw the main target window
	local windowFlags = bit.bor(ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav, ImGuiWindowFlags_NoBackground, ImGuiWindowFlags_NoBringToFrontOnFocus);
	if (gConfig.lockPositions) then
		windowFlags = bit.bor(windowFlags, ImGuiWindowFlags_NoMove);
	end
    if (imgui.Begin('TargetBar', true, windowFlags)) then
        
		-- Obtain and prepare target information..
        local dist  = ('%.1f'):fmt(math.sqrt(targetEntity.Distance));
		local targetNameText = targetEntity.Name;
		local targetHpPercent = targetEntity.HPPercent..'%';

		if (gConfig.showEnemyId and isMonster) then
			local targetServerId = AshitaCore:GetMemoryManager():GetEntity():GetServerId(targetIndex);
			local targetServerIdHex = string.format('0x%X', targetServerId);

			targetNameText = targetNameText .. " [".. string.sub(targetServerIdHex, -3) .."]";
		end

		local hpGradientStart = '#e26c6c';
		local hpGradientEnd = '#fb9494';

		local hpPercentData = {{targetEntity.HPPercent / 100, {hpGradientStart, hpGradientEnd}}};

		if _HXUI_DEV_DEBUG_INTERPOLATION then
			hpPercentData[1][1] = targetbar.interpolation.currentHpp / 100;
		end

		if targetbar.interpolation.interpolationDamagePercent > 0 then
			local interpolationOverlay;

			if gConfig.healthBarFlashEnabled then
				interpolationOverlay = {
					'#FFFFFF', -- overlay color,
					targetbar.interpolation.overlayAlpha -- overlay alpha,
				};
			end

			table.insert(
				hpPercentData,
				{
					targetbar.interpolation.interpolationDamagePercent / 100, -- interpolation percent
					{'#cf3437', '#c54d4d'},
					interpolationOverlay
				}
			);
		end
		
		local startX, startY = imgui.GetCursorScreenPos();
		progressbar.ProgressBar(hpPercentData, {settings.barWidth, settings.barHeight}, {decorate = gConfig.showTargetBarBookends});

		----------------------------------------------------------------
		-- WATNEY HATE DOT
		-- Top-left corner of target HP bar. Color encodes your hate rank:
		--   bright pink  = no hate data yet (idle/booting)
		--   green        = safe (rank 3+)
		--   amber        = close (rank 2)
		--   red, pulsing = you have hate (rank 1)
		-- Same pixel position as the original alive-marker that's been
		-- confirmed visible in-game. Reusing it eliminates the "is the pip
		-- being drawn where I can see it" question entirely.
		----------------------------------------------------------------
		do
			local am_dl
			pcall(function() am_dl = imgui.GetForegroundDrawList() end)
			if am_dl then
				local r, g, b = 1.00, 0.20, 0.80  -- default bright pink (no data)
				local pulse = 1.0
				local rank_text = 'init'

				-- File-based IPC: Ashita4 sandboxes _G per addon so cross-
				-- addon getters via _G.HuntPartner* return nil to other
				-- addons. We read huntpartner's hate-state.dat directly,
				-- cached for ~0.25s per addon-frame to avoid disk thrash.
				local ok_io, info = pcall(function()
					local now = os.clock()
					if not _watney_hate_cache or (now - _watney_hate_cache.t) > 0.25 then
						local path = AshitaCore:GetInstallPath() .. 'addons\\huntpartner\\hate-state.dat'
						local f = io.open(path, 'r')
						if not f then
							_watney_hate_cache = { t = now, info = nil }
						else
							local data = f:read('*a')
							f:close()
							local target = tonumber(data:match('TARGET=([%-%d]+)'))
							local mypos_str = data:match('MY_POS=([%w%-]+)')
							local total = tonumber(data:match('TOTAL=(%d+)'))
							local my_score = tonumber(data:match('MY_SCORE=([%d%.]+)'))
							local leader_score = tonumber(data:match('LEADER_SCORE=([%d%.]+)'))
							local ts = tonumber(data:match('TIMESTAMP=([%d%.]+)'))
							local my_pos = (mypos_str ~= 'nil') and tonumber(mypos_str) or nil
							_watney_hate_cache = { t = now, info = {
								target = target or 0,
								my_pos = my_pos,
								total = total or 0,
								my_score = my_score or 0,
								leader_score = leader_score or 0,
								next_nuke_est = tonumber(data:match('NEXT_NUKE_EST=(%d+)')) or 0,
								mob_claim_id = tonumber(data:match('MOB_CLAIM_ID=(%d+)')) or 0,
								mob_target_is_me = data:match('MOB_TARGET_IS_ME=true') ~= nil,
								calibrated_threshold = tonumber(data:match('CALIBRATED_THRESHOLD=([%d%.]+)')),
								calib_samples = tonumber(data:match('CALIB_SAMPLES=(%d+)')) or 0,
								ts = ts or 0,
							}}
						end
					end
					return _watney_hate_cache.info
				end)

				if not ok_io then
					rank_text = nil
				elseif not info then
					rank_text = nil
				elseif info.total == 0 then
					rank_text = nil
				elseif info.my_pos == nil then
					rank_text = nil
				else
					-- Ground-truth override: the mob's actual claim/target
					-- from game memory. If the mob is targeting us right now,
					-- we have hate -- no simulation involved, no questions.
					local has_hate_truth = info.mob_target_is_me
					local rank = (info.my_pos or 0) + 1
					local ratio = (info.leader_score > 0) and (info.my_score / info.leader_score) or 0
					local pct = math.floor(ratio * 100)
					local projected_score = info.my_score + info.next_nuke_est
					local proj_ratio = (info.leader_score > 0) and (projected_score / info.leader_score) or ratio
					local proj_pct = math.floor(proj_ratio * 100)

					_watney_hate_cache.prev_state = _watney_hate_cache.prev_state or 'init'
					_watney_hate_cache.last_safe_t = _watney_hate_cache.last_safe_t or 0

					local cur_state
					-- Use learned threshold if we have enough samples, else
					-- conservative 70% default. The learned value reflects the
					-- ratio at which Blake ACTUALLY pulls hate in this comp.
					local steal_thresh = info.calibrated_threshold or 0.70
					local climb_thresh = steal_thresh * 0.6   -- yellow zone starts at 60% of steal
					if has_hate_truth then cur_state = 'holding'  -- ground truth wins
					elseif rank == 1 then cur_state = 'holding'
					elseif ratio >= steal_thresh then cur_state = 'steal'
					elseif proj_ratio >= steal_thresh then cur_state = 'predict'
					elseif ratio >= climb_thresh then cur_state = 'climb'
					else cur_state = 'safe' end

					local was_dangerous = (_watney_hate_cache.prev_state == 'holding'
					                    or _watney_hate_cache.prev_state == 'steal'
					                    or _watney_hate_cache.prev_state == 'predict')
					local now_safer = (cur_state == 'climb' or cur_state == 'safe')
					if was_dangerous and now_safer then
						_watney_hate_cache.last_safe_t = currentTime
					end
					_watney_hate_cache.prev_state = cur_state
					local safe_flash_age = currentTime - _watney_hate_cache.last_safe_t
					local in_safe_flash = safe_flash_age < 1.5 and _watney_hate_cache.last_safe_t > 0

					if cur_state == 'holding' then
						-- Use a HATE! prefix when ground-truth confirms, else
						-- show simulator-derived #1 ranking text. The visual is
						-- the same red pulse either way; the text tells you
						-- whether it's confirmed or estimated.
						if has_hate_truth then
							rank_text = 'HATE! mob is on you'
						else
							rank_text = string.format('#1/%d HOLDING (100%%)', info.total)
						end
						r, g, b = 1.00, 0.20, 0.18
						pulse = 0.55 + 0.45 * (0.5 + 0.5 * math.sin(currentTime * 5.0))
					elseif cur_state == 'steal' then
						rank_text = string.format('#%d/%d STEAL (%d%%)', rank, info.total, pct)
						r, g, b = 1.00, 0.55, 0.20
						pulse = 0.60 + 0.40 * (0.5 + 0.5 * math.sin(currentTime * 3.5))
					elseif cur_state == 'predict' then
						rank_text = string.format('#%d/%d (%d%% next=%d%%)', rank, info.total, pct, proj_pct)
						r, g, b = 1.00, 0.70, 0.30
						pulse = 0.70 + 0.30 * (0.5 + 0.5 * math.sin(currentTime * 2.5))
					elseif in_safe_flash then
						local fade = 1.0 - (safe_flash_age / 1.5)
						rank_text = string.format('#%d/%d RESUME OK (%d%%)', rank, info.total, pct)
						r, g, b = 0.30, 1.00, 0.40
						pulse = 0.7 + 0.3 * fade
					elseif cur_state == 'climb' then
						rank_text = string.format('#%d/%d (%d%% next=%d%%)', rank, info.total, pct, proj_pct)
						r, g, b = 1.00, 0.85, 0.30
					else
						rank_text = string.format('#%d/%d (%d%%)', rank, info.total, pct)
						r, g, b = 0.45, 0.95, 0.55
					end
				end

				if rank_text then
					local size = 14
					local pad = 2
					am_dl:AddRectFilled(
						{ startX - size - pad, startY - size - pad },
						{ startX - pad,        startY - pad },
						imgui.GetColorU32({ r, g, b, pulse }), 2.0, 0)
				end
			end
		end
		----------------------------------------------------------------
		----------------------------------------------------------------
		-- BEGIN HUNTPARTNER HATE-PIP PATCH (target HP bar)
		-- Tiny rank badge on the top-right corner of the target HP bar
		-- showing your position on the mob's hate list (#1/4 style).
		-- Color-coded: green=safe, amber=close, red=you have hate.
		-- Reads _G.HuntPartnerGetHateData(); silently no-ops if huntpartner
		-- isn't loaded OR the server hasn't sent 0x076 yet.
		----------------------------------------------------------------
		if _G.HuntPartnerGetHateData then
			local hd = _G.HuntPartnerGetHateData();
			if hd and hd.total and hd.total > 0 and hd.my_position ~= nil then
				local rank      = hd.my_position + 1;  -- 0-indexed -> 1-indexed display
				local total     = hd.total;
				local pip_text  = string.format('#%d/%d', rank, total);
				local r, g, b
				if rank == 1 then       r, g, b = 1.00, 0.30, 0.25  -- red: you have hate
				elseif rank == 2 then   r, g, b = 1.00, 0.78, 0.20  -- amber: close
				else                    r, g, b = 0.45, 0.95, 0.55  -- green: safe
				end
				local pip_dl
				pcall(function() pip_dl = imgui.GetForegroundDrawList() end)
				if pip_dl then
					-- Small colored dot indicator (no text)
					local dot_size = 8
					local dx = startX - dot_size - 4
					local dy = startY + math.floor(settings.barHeight / 2) - math.floor(dot_size / 2)
					pip_dl:AddRectFilled({ dx, dy }, { dx + dot_size, dy + dot_size },
						imgui.GetColorU32({ r, g, b, 0.9 }), 2.0, 0)
				end
			end
		end
		----------------------------------------------------------------
		-- END HUNTPARTNER HATE-PIP PATCH
		----------------------------------------------------------------

		----------------------------------------------------------------
		-- BEGIN HUNTPARTNER SWING-TIMER PATCH (target HP bar)
		-- Reads per-mob swing prediction from huntpartner's persisted
		-- learning via _G.HuntPartnerGetSwingData(name, level). If
		-- huntpartner isn't loaded, this block silently no-ops.
		-- Renders a thin cyan->yellow->red marching strip immediately
		-- under the target HP bar, with white flash for ~0.18s after
		-- each landed swing (gives a rhythm tool at a glance).
		----------------------------------------------------------------
		if _G.HuntPartnerGetSwingData and isMonster then
			-- Target level isn't always known to hxuiplus; pass nil and
			-- let huntpartner's name-only fallback resolve it.
			local sd = _G.HuntPartnerGetSwingData(targetEntity.Name, nil);
			if sd and targetEntity.HPPercent > 0 then
				local sw_int  = sd.swing_interval;
				local elapsed = currentTime - sd.last_hit_c;
				if elapsed >= 0 and elapsed <= sw_int * 2.0 then
					local frac    = math.min(elapsed / sw_int, 1.0);
					local strip_h = math.max(3, math.floor(settings.barHeight * 0.18));
					local gap     = 1;
					local sw_x0   = startX;
					local sw_y0   = startY + settings.barHeight + gap;
					local sw_x1   = sw_x0 + settings.barWidth;
					local sw_y1   = sw_y0 + strip_h;
					local dl;
					pcall(function() dl = imgui.GetForegroundDrawList() end);
					if not dl then pcall(function() dl = imgui.GetWindowDrawList() end); end
					if dl then
						-- Backdrop.
						dl:AddRectFilled({ sw_x0, sw_y0 }, { sw_x1, sw_y1 },
							imgui.GetColorU32({ 0.05, 0.05, 0.08, 0.85 }), 1.0, 0);
						-- Fill: piecewise lerp cyan -> yellow -> red as frac
						-- approaches 1.0 (impact). Mirrors huntpartner's
						-- target-bar swing-strip color flow exactly so the
						-- visual reads identically across the two addons.
						local rC, gC, bC;
						if frac < 0.5 then
							local t = frac / 0.5;
							rC = 0.30 + (1.00 - 0.30) * t;
							gC = 0.80 + (0.90 - 0.80) * t;
							bC = 1.00 + (0.20 - 1.00) * t;
						else
							local t = (frac - 0.5) / 0.5;
							rC = 1.00;
							gC = 0.90 + (0.30 - 0.90) * t;
							bC = 0.20;
						end
						local fill_x = sw_x0 + settings.barWidth * frac;
						dl:AddRectFilled({ sw_x0, sw_y0 }, { fill_x, sw_y1 },
							imgui.GetColorU32({ rC, gC, bC, 0.95 }), 1.0, 0);
						-- White flash for ~0.18s after each landed swing
						-- (the "tick" beat — turns the strip into a real
						-- rhythm tool you can drum to).
						if elapsed < 0.18 then
							local fa = 0.7 * (1.0 - elapsed / 0.18);
							dl:AddRectFilled({ sw_x0, sw_y0 }, { sw_x1, sw_y1 },
								imgui.GetColorU32({ 1.0, 1.0, 1.0, fa }), 1.0, 0);
						end
					end
				end
			end
		end
		----------------------------------------------------------------
		-- END HUNTPARTNER SWING-TIMER PATCH
		----------------------------------------------------------------

		local nameSize = SIZE.new();
		nameText:GetTextSize(nameSize);

		nameText:SetPositionX(startX + settings.barHeight / 2 + settings.topTextXOffset);
		nameText:SetPositionY(startY - settings.topTextYOffset - nameSize.cy);
		nameText:SetColor(color);
		nameText:SetText(targetNameText);
		nameText:SetVisible(true);

		local distSize = SIZE.new();
		distText:GetTextSize(distSize);

		distText:SetPositionX(startX + settings.barWidth - settings.barHeight / 2 - settings.topTextXOffset);
		distText:SetPositionY(startY - settings.topTextYOffset - distSize.cy);
		distText:SetText(tostring(dist));
		distText:SetVisible(true);

		if (isMonster or gConfig.alwaysShowHealthPercent) then
			percentText:SetPositionX(startX + settings.barWidth - settings.barHeight / 2 - settings.bottomTextXOffset);
			percentText:SetPositionY(startY + settings.barHeight + settings.bottomTextYOffset);
			percentText:SetText(tostring(targetHpPercent));
			percentText:SetVisible(true);
			local hpColor, _ = GetHpColors(targetEntity.HPPercent / 100);
			percentText:SetColor(hpColor);
		else
			percentText:SetVisible(false);
		end

		-- Draw buffs and debuffs
		imgui.SameLine();
		local preBuffX, preBuffY = imgui.GetCursorScreenPos();
		local buffIds;
		if (targetEntity == playerEnt) then
			buffIds = player:GetBuffs();
		elseif (IsMemberOfParty(targetIndex)) then
			buffIds = statusHandler.get_member_status(playerTarget:GetServerId(0));
		else
			buffIds = debuffHandler.GetActiveDebuffs(playerTarget:GetServerId(0));
		end
		imgui.NewLine();
		imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {1, 3});
		DrawStatusIcons(buffIds, settings.iconSize, settings.maxIconColumns, 3, false, settings.barHeight/2);
		imgui.PopStyleVar(1);

		-- Obtain our target of target (not always accurate)
		local totEntity;
		local totIndex
		if (targetEntity == playerEnt) then
			totIndex = targetIndex
			totEntity = targetEntity;
		end
		if (totEntity == nil) then
			totIndex = targetEntity.TargetedIndex;
			if (totIndex ~= nil) then
				totEntity = GetEntity(totIndex);
			end
		end
		if (totEntity ~= nil and totEntity.Name ~= nil) then

			imgui.SetCursorScreenPos({preBuffX, preBuffY});
			local totX, totY = imgui.GetCursorScreenPos();
			local totColor = GetColorOfTarget(totEntity, totIndex);
			imgui.SetCursorScreenPos({totX, totY + settings.barHeight/2 - settings.arrowSize/2});
			imgui.Image(tonumber(ffi.cast("uint32_t", arrowTexture.image)), { settings.arrowSize, settings.arrowSize });
			imgui.SameLine();

			totX, _ = imgui.GetCursorScreenPos();
			imgui.SetCursorScreenPos({totX, totY - (settings.totBarHeight / 2) + (settings.barHeight/2) + settings.totBarOffset});

			local totStartX, totStartY = imgui.GetCursorScreenPos();
			progressbar.ProgressBar({{totEntity.HPPercent / 100, {'#e16c6c', '#fb9494'}}}, {settings.barWidth / 3, settings.totBarHeight}, {decorate = gConfig.showTargetBarBookends});

			local totNameSize = SIZE.new();
			totNameText:GetTextSize(totNameSize);

			totNameText:SetPositionX(totStartX + settings.barHeight / 2);
			totNameText:SetPositionY(totStartY - totNameSize.cy);
			totNameText:SetColor(totColor);
			totNameText:SetText(totEntity.Name);
			totNameText:SetVisible(true);
		else
			totNameText:SetVisible(false);
		end
    end
	local winPosX, winPosY = imgui.GetWindowPos();
    imgui.End();
end

targetbar.Initialize = function(settings)
    percentText = fonts.new(settings.percent_font_settings);
	nameText = fonts.new(settings.name_font_settings);
	totNameText = fonts.new(settings.totName_font_settings);
	distText = fonts.new(settings.distance_font_settings);
	arrowTexture = 	LoadTexture("arrow");
end

targetbar.UpdateFonts = function(settings)
    percentText:SetFontHeight(settings.percent_font_settings.font_height);
	nameText:SetFontHeight(settings.name_font_settings.font_height);
	distText:SetFontHeight(settings.distance_font_settings.font_height);
	totNameText:SetFontHeight(settings.totName_font_settings.font_height);
end

targetbar.SetHidden = function(hidden)
	if (hidden == true) then
		UpdateTextVisibility(false);
	end
end



return targetbar;