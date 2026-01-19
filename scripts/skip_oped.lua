--[[
片头片尾跳过（Lua脚本版）

设计目标
1) 逻辑符合 mpv：以“脚本绑定 + OSD/菜单”为主，默认不强行改动用户配置。
2) 两种来源确定片头/片尾区间：
   - OP/ED 章节优先：从章节标题识别 OP/ED，自动推导片头结束/片尾开始。
   - 手动时长：分别设置片头/片尾时长（默认限制 5 分钟）。
3) 可选 uosc 菜单：提供图形化开关/设置入口；无 uosc 时仍可用快捷键。

前置条件
- 无硬性前置条件；若启用 uosc 菜单，请确保 uosc 脚本已加载。

可用快捷键示例（在 input.conf / input_uosc.conf 中写入）

 Alt+o         script-binding skip_oped/menu           #! 视频 > 片头片尾设置
 Alt+Shift+o   script-binding skip_oped/toggle         #! 视频 > 启用/禁用 跳过片头片尾
 Alt+t         script-binding skip_oped/intro_set_pos  #! 视频 > 设置当前位置为片头
 Alt+w         script-binding skip_oped/outro_set_pos  #! 视频 > 设置当前位置为片尾
 t-=           script-binding skip_oped/intro_add      #! 视频 > t + =：片头 +5s
 t--           script-binding skip_oped/intro_sub      #! 视频 > t + -：片头 -5s
 w-=           script-binding skip_oped/outro_add      #! 视频 > w + =：片尾 +5s
 w--           script-binding skip_oped/outro_sub      #! 视频 > w + -：片尾 -5s

说明
- 本脚本与 input_plus.lua 的 “chap_skip_toggle（按章节标题跳过 OP/ED）” 功能重叠；
  建议只启用其一，避免重复跳章/跳转造成体验异常。
]]

local options = require('mp.options')
local utils = require('mp.utils')

local o = {
	enabled = false,
	prefer_chapters = true,
	intro_len = 0,
	outro_len = 0,
	manual_limit_sec = 300,
	step_sec = 5,
	opening_patterns = '^op%s,^op$, opening$,^opening$,^intro%s,^intro$, intro$,片头,片頭,序章,主题曲,主題曲,开场,開場,序幕',
	ending_patterns = '^ed%s,^ed$, ending$,^ending$,^outro%s,^outro$, outro$,片尾,片尾,尾声,尾聲,闭幕,閉幕,结束,結束,预告,預告',
	osd_duration = 2.0,
}

options.read_options(o, mp.get_script_name(), function() end)

local state = {
	uosc_available = false,
	menu_open = false,
	enabled = o.enabled,
	prefer_chapters = o.prefer_chapters,
	intro_len = math.max(0, tonumber(o.intro_len) or 0),
	outro_len = math.max(0, tonumber(o.outro_len) or 0),
	skipped_intro = false,
	skipped_outro = false,
	last_time_pos = nil,
	detected = {
		intro_start = nil,
		intro_end = nil,
		outro_start = nil,
	},
}

local MENU_TYPE = 'skip_oped'

local function clamp(v, lo, hi)
	if v == nil then return lo end
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

local function is_number(v)
	return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end

local function fmt_time(sec)
	if not is_number(sec) then return '—' end
	sec = math.max(0, math.floor(sec + 0.5))
	local m = math.floor(sec / 60)
	local s = sec % 60
	return string.format('%02d:%02d', m, s)
end

local function split_csv(s)
	local t = {}
	if type(s) ~= 'string' or s == '' then return t end
	for part in (s .. ','):gmatch('(.-),') do
		part = part:gsub('^%s+', ''):gsub('%s+$', '')
		if part ~= '' then t[#t + 1] = part end
	end
	return t
end

local opening_patterns = split_csv(o.opening_patterns)
local ending_patterns = split_csv(o.ending_patterns)

local function title_matches(title, patterns)
	if type(title) ~= 'string' or title == '' then return false end
	local t = title:lower()
	for _, p in ipairs(patterns) do
		local ok, found = pcall(function()
			return t:find(p) ~= nil
		end)
		if ok and found then return true end
	end
	return false
end

local function osd(msg)
	mp.osd_message(msg, o.osd_duration)
end


local function compute_detected_ranges()
	state.detected.intro_start = nil
	state.detected.intro_end = nil
	state.detected.outro_start = nil

	local chapters = mp.get_property_native('chapter-list', nil)
	if type(chapters) ~= 'table' or #chapters == 0 then return end

	local duration = mp.get_property_native('duration', nil)
	if not is_number(duration) then duration = nil end

	local intro_start, intro_end = nil, nil
	for i = 1, #chapters do
		local c = chapters[i]
		-- mp.msg.info(string.format("Checking chapter %d: '%s'", i, c.title or ''))
		if c and title_matches(c.title or '', opening_patterns) then
			-- mp.msg.info("  -> Matched opening pattern")
			local nextc = chapters[i + 1]
			if nextc and is_number(nextc.time) and nextc.time > 0 then
				intro_start = c.time -- 记录 OP 开始时间
				intro_end = nextc.time -- 记录 OP 结束时间（下一章开始）
				break
			end
		end
	end

	local outro_start = nil
	for i = #chapters, 1, -1 do
		local c = chapters[i]
		if c and title_matches(c.title or '', ending_patterns) and is_number(c.time) then
			-- mp.msg.info(string.format("  -> Matched ending pattern: '%s'", c.title or ''))
			outro_start = c.time
			break
		end
	end

	if is_number(intro_end) then
		state.detected.intro_start = is_number(intro_start) and intro_start or 0
		state.detected.intro_end = clamp(intro_end, 0, o.manual_limit_sec + state.detected.intro_start)
	end

	if duration and is_number(outro_start) and outro_start >= 0 and outro_start < duration then
		local tail = duration - outro_start
		state.detected.outro_start = clamp(outro_start, 0, duration)
		state.detected.outro_len = clamp(tail, 0, o.manual_limit_sec)
	else
		state.detected.outro_len = nil
	end
end

local function effective_intro_range()
	if state.prefer_chapters and is_number(state.detected.intro_end) and state.detected.intro_end > 0 then
		return state.detected.intro_start or 0, state.detected.intro_end
	end
	return 0, clamp(state.intro_len, 0, o.manual_limit_sec)
end

local function effective_intro_len() -- 兼容旧接口，主要用于 UI 显示时长
	local start_t, end_t = effective_intro_range()
	return end_t - start_t
end

local function effective_outro_len()
	if state.prefer_chapters and is_number(state.detected.outro_len) and state.detected.outro_len > 0 then
		return state.detected.outro_len
	end
	return clamp(state.outro_len, 0, o.manual_limit_sec)
end

local function set_enabled(v)
	state.enabled = not not v
	reset_skip_state()
	osd(string.format('跳过片头片尾：%s', state.enabled and '开' or '关'))
end

local function toggle_enabled()
	set_enabled(not state.enabled)
end

local function toggle_prefer_chapters()
	state.prefer_chapters = not state.prefer_chapters
	reset_skip_state()
	osd(string.format('OP/ED 章节优先：%s', state.prefer_chapters and '开' or '关'))
end

local function seek_absolute(sec)
	if not is_number(sec) then return end
	mp.commandv('seek', tostring(sec), 'absolute', 'exact')
end

local function skip_intro_now()
	local _, intro_end = effective_intro_range()
	if intro_end > 0 then
		seek_absolute(intro_end)
	end
end

local function skip_outro_now()
	local duration = mp.get_property_native('duration', nil)
	if not is_number(duration) then return end
	local outro = effective_outro_len()
	if outro <= 0 then return end
	local target = duration - 0.2
	if target < 0 then target = 0 end
	seek_absolute(target)
end

local function reset_skip_state()
	state.skipped_intro = false
	state.skipped_outro = false
end

local function apply_auto_skip(time_pos)
	if not state.enabled then return end
	if not is_number(time_pos) or time_pos < 0 then return end

	local intro_start, intro_end = effective_intro_range()
	-- 只要当前时间在片头范围内 [start, end)，且尚未跳过（或被重置），就执行跳过
	if intro_end > intro_start and time_pos >= intro_start and time_pos < intro_end then
		if not state.skipped_intro then
			state.skipped_intro = true
			seek_absolute(intro_end)
		end
		return
	end
	-- 如果时间已经超过片头，标记为已跳过，防止回退时重复跳
	if intro_end > intro_start and time_pos >= intro_end then
		state.skipped_intro = true
	end

	local duration = mp.get_property_native('duration', nil)
	if not is_number(duration) or duration <= 0 then return end

	local outro = effective_outro_len()
	if outro <= 0 then return end

	local last = state.last_time_pos
	state.last_time_pos = time_pos
	if is_number(last) and time_pos < last then return end

	if not state.skipped_outro and time_pos >= (duration - outro) then
		state.skipped_outro = true
		skip_outro_now()
	end
end

local function set_intro_len_from_time_pos()
	local pos = mp.get_property_native('time-pos', nil)
	if not is_number(pos) then return end
	state.intro_len = clamp(pos, 0, o.manual_limit_sec)
	reset_skip_state() -- 重置状态以允许再次跳过
	osd(string.format('片头时长：%s', fmt_time(state.intro_len)))
end

local function set_outro_len_from_time_pos()
	local pos = mp.get_property_native('time-pos', nil)
	local duration = mp.get_property_native('duration', nil)
	if not is_number(pos) or not is_number(duration) then return end
	local tail = clamp(duration - pos, 0, o.manual_limit_sec)
	state.outro_len = tail
	reset_skip_state()
	osd(string.format('片尾时长：%s', fmt_time(state.outro_len)))
end

local function add_intro(delta)
	state.intro_len = clamp(state.intro_len + delta, 0, o.manual_limit_sec)
	reset_skip_state()
	osd(string.format('片头时长：%s', fmt_time(state.intro_len)))
end

local function add_outro(delta)
	state.outro_len = clamp(state.outro_len + delta, 0, o.manual_limit_sec)
	reset_skip_state()
	osd(string.format('片尾时长：%s', fmt_time(state.outro_len)))
end

local function clear_intro()
	state.intro_len = 0
	reset_skip_state()
	osd('片头时长：已清空')
end

local function clear_outro()
	state.outro_len = 0
	reset_skip_state()
	osd('片尾时长：已清空')
end

local function build_menu()
	local intro_eff = effective_intro_len()
	local outro_eff = effective_outro_len()

	local detected_intro = is_number(state.detected.intro_end) and fmt_time(state.detected.intro_end) or '—'
	local detected_outro = is_number(state.detected.outro_len) and fmt_time(state.detected.outro_len) or '—'

	local footnote = string.format('章节识别：片头 %s / 片尾 %s    手动：片头 %s / 片尾 %s',
		detected_intro, detected_outro, fmt_time(state.intro_len), fmt_time(state.outro_len))

	local function toggle_item(title, enabled, action)
		return {
			title = title,
			hint = enabled and '开' or '关',
			value = { action = action },
			active = enabled,
			keep_open = true,
		}
	end

	local function action_item(title, hint, action)
		return {
			title = title,
			hint = hint,
			value = { action = action },
			keep_open = true,
		}
	end

	local function safe_call(fn)
		return function(...)
			local ok, err = pcall(fn, ...)
			if not ok then
				mp.msg.error('skip_oped error: ' .. tostring(err))
				osd('脚本发生错误，请查看控制台')
			end
		end
	end

	local intro_menu = {
		title = string.format('片头设置（当前生效 %s）', fmt_time(intro_eff)),
		items = {
			action_item('设为当前位置', nil, 'intro_set_pos'),
			action_item(string.format('-%ds', o.step_sec), nil, 'intro_sub'),
			action_item(string.format('+%ds', o.step_sec), nil, 'intro_add'),
			{
				title = '直接输入（秒）',
				hint = nil,
				id = 'skip_oped_intro_input',
				search_style = 'palette',
				search_debounce = 'submit',
				search_suggestion = '输入片头秒数后按 Enter',
				on_search = 'callback',
				items = {
					{ title = '按 Enter 确认，Esc 返回', value = 'ignore', selectable = false, muted = true },
				},
			},
			action_item('清空手动片头', nil, 'intro_clear'),
			action_item('立即跳过片头', nil, 'intro_skip_now'),
		},
	}

	local outro_menu = {
		title = string.format('片尾设置（当前生效 %s）', fmt_time(outro_eff)),
		items = {
			action_item('设为当前位置', nil, 'outro_set_pos'),
			action_item(string.format('-%ds', o.step_sec), nil, 'outro_sub'),
			action_item(string.format('+%ds', o.step_sec), nil, 'outro_add'),
			{
				title = '直接输入（秒）',
				hint = nil,
				id = 'skip_oped_outro_input',
				search_style = 'palette',
				search_debounce = 'submit',
				search_suggestion = '输入片尾秒数后按 Enter',
				on_search = 'callback',
				items = {
					{ title = '按 Enter 确认，Esc 返回', value = 'ignore', selectable = false, muted = true },
				},
			},
			action_item('清空手动片尾', nil, 'outro_clear'),
			action_item('立即跳过片尾', nil, 'outro_skip_now'),
		},
	}

	return {
		type = MENU_TYPE,
		title = '片头片尾设置',
		footnote = footnote,
		callback = { mp.get_script_name(), 'uosc-callback' },
		items = {
			toggle_item('启用跳过片头片尾', state.enabled, 'toggle_enabled'),
			toggle_item('OP/ED 章节优先', state.prefer_chapters, 'toggle_prefer_chapters'),
			{
				title = string.format('手动设置片头时长（范围 %d 分钟）', math.floor(o.manual_limit_sec / 60)),
				hint = fmt_time(state.intro_len),
				items = intro_menu.items,
			},
			{
				title = string.format('手动设置片尾时长（范围 %d 分钟）', math.floor(o.manual_limit_sec / 60)),
				hint = fmt_time(state.outro_len),
				items = outro_menu.items,
			},
		},
	}
end

local function open_menu()
	if not state.uosc_available then
		osd('未检测到 uosc：仅启用快捷键模式')
		return
	end
	local menu = build_menu()
	local json = utils.format_json(menu)
	mp.commandv('script-message-to', 'uosc', 'open-menu', json)
	state.menu_open = true
end

local function update_menu()
	if not state.uosc_available or not state.menu_open then return end
	local menu = build_menu()
	local json = utils.format_json(menu)
	mp.commandv('script-message-to', 'uosc', 'update-menu', json)
end

mp.register_script_message('uosc-version', function()
	state.uosc_available = true
end)

mp.register_script_message('uosc-callback', function(json)
	local ok, err = pcall(function()
		local ev = utils.parse_json(json)
		if type(ev) ~= 'table' then return end
		if ev.type == 'close' then
			state.menu_open = false
			return
		end
		if ev.type == 'search' then
			local which = nil
			if ev.menu_id == 'skip_oped_intro_input' then
				which = 'intro'
			elseif ev.menu_id == 'skip_oped_outro_input' then
				which = 'outro'
			end

			if which then
				local n = tonumber(ev.query)
				if not n then
					osd('请输入数字')
					return
				end
				if which == 'intro' then
					state.intro_len = clamp(n, 0, o.manual_limit_sec)
					osd(string.format('片头时长：%s', fmt_time(state.intro_len)))
				else
					state.outro_len = clamp(n, 0, o.manual_limit_sec)
					osd(string.format('片尾时长：%s', fmt_time(state.outro_len)))
				end
				update_menu()
			end
			return
		end

		if ev.type ~= 'activate' then return end

		local v = ev.value
		local action = type(v) == 'table' and v.action or nil
		if not action then return end

		if action == 'toggle_enabled' then
			toggle_enabled()
		elseif action == 'toggle_prefer_chapters' then
			toggle_prefer_chapters()
		elseif action == 'intro_set_pos' then
			set_intro_len_from_time_pos()
		elseif action == 'outro_set_pos' then
			set_outro_len_from_time_pos()
		elseif action == 'intro_add' then
			add_intro(o.step_sec)
		elseif action == 'intro_sub' then
			add_intro(-o.step_sec)
		elseif action == 'outro_add' then
			add_outro(o.step_sec)
		elseif action == 'outro_sub' then
			add_outro(-o.step_sec)
		elseif action == 'intro_clear' then
			clear_intro()
		elseif action == 'outro_clear' then
			clear_outro()
		elseif action == 'intro_skip_now' then
			skip_intro_now()
		elseif action == 'outro_skip_now' then
			skip_outro_now()
		end

		update_menu()
	end)

	if not ok then
		mp.msg.error('skip_oped menu callback error: ' .. tostring(err))
	end
end)

mp.add_key_binding(nil, 'menu', open_menu)
mp.add_key_binding(nil, 'toggle', toggle_enabled)
mp.add_key_binding(nil, 'intro_set_pos', function() set_intro_len_from_time_pos(); update_menu() end)
mp.add_key_binding(nil, 'outro_set_pos', function() set_outro_len_from_time_pos(); update_menu() end)
mp.add_key_binding(nil, 'intro_add', function() add_intro(o.step_sec); update_menu() end)
mp.add_key_binding(nil, 'intro_sub', function() add_intro(-o.step_sec); update_menu() end)
mp.add_key_binding(nil, 'outro_add', function() add_outro(o.step_sec); update_menu() end)
mp.add_key_binding(nil, 'outro_sub', function() add_outro(-o.step_sec); update_menu() end)

mp.register_event('file-loaded', function()
	state.skipped_intro = false
	state.skipped_outro = false
	state.last_time_pos = nil
	compute_detected_ranges()
	update_menu()
end)

mp.observe_property('chapter-list', 'native', function()
	compute_detected_ranges()
	update_menu()
end)

mp.observe_property('duration', 'native', function()
	compute_detected_ranges()
	update_menu()
end)

mp.observe_property('time-pos', 'native', function(_, v)
	apply_auto_skip(v)
end)

