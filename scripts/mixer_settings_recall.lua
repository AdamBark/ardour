ardour {
	["type"]    = "EditorAction",
	name        = "Recall Mixer Settings",
	author      = "Mixbus Team",
	description = [[

	Recalls mixer settings outined by files
	created by Store Mixer Settings.

	Allows for some room to change Source
	and Destination.

	]]
}

function factory () return function ()

	local user_cfg = ARDOUR.user_config_directory(-1)
	local local_path = ARDOUR.LuaAPI.build_filename(Session:path(), 'mixer_settings')
	local global_path = ARDOUR.LuaAPI.build_filename(user_cfg, 'mixer_settings')

	local invalidate = {}

	function exists(file)
		local ok, err, code = os.rename(file, file)
		if not ok then
			if code == 13 then -- Permission denied, but it exists
				return true
			end
		end return ok, err
	end

	function whoami()
		if not pcall(function() local first_check = Session:get_mixbus(0) end) then
			return "Ardour"
		else
			local second_check = Session:get_mixbus(11)
			if second_check:isnil() then
				return "Mixbus"
			else
				return "32C"
			end
		end
	end

	function isdir(path)
		return exists(path.."/")
	end

	function fetch_valid_settings_file(directory, fallback)
		local i, t, popen = 0, {}, io.popen
		local pfile = popen('ls "'..directory..'"')
		for filename in pfile:lines() do
			i = i + 1
			if string.find(filename, ".lua") then
				return filename
			end
		end
		pfile:close()
		return fallback
	end

	function get_processor_by_name(track, name)
		local i = 0
		local proc = track:nth_processor(i)
			repeat
				if(proc:display_name() == name) then
					return proc
				else
					i = i + 1
				end
				proc = track:nth_processor(i)
			until proc:isnil()
		end

	function new_plugin(name)
		for x = 0, 6 do
			local plugin = ARDOUR.LuaAPI.new_plugin(Session, name, x, "")
			if not(plugin:isnil()) then return plugin end
		end
	end

	function group_by_id(id)
		local id  = tonumber(id)
		for g in Session:route_groups():iter() do
			local group_id = tonumber(g:to_stateful():id():to_s())
			if group_id == id then return g end
		end
	end

	function group_by_name(name)
		for g in Session:route_groups():iter() do
			if g:name() == name then return g end
		end
	end

	function route_groupid_interrogate(t)
		local group = false
		for g in Session:route_groups():iter() do
			for r in g:route_list():iter() do
				if r:name() == t:name() then group = g:to_stateful():id():to_s() end
			end
		end return group
	end

	function route_group_interrogate(t)
		for g in Session:route_groups():iter() do
			for r in g:route_list():iter() do
				if r:name() == t:name() then return g end
			end
		end
	end

	function recall(debug, path, dry_run)
		local file = io.open(path, "r")
		assert(file, "File not found!")
		local bypass_routes = {}

		local i = 0
		for l in file:lines() do
			--print(i, l)

			local exec_line = dry_run["dothis-"..i]
			local skip_line = false
			if not(exec_line == nil) and not(exec_line) then
				skip_line = true
			end

			local plugin, route, group = false, false, false
			local f = load(l)

			if debug then
				print(i, string.sub(l, 0, 29), f)
			end

			if f then f() end

			if instance["route_id"]  then route = true end
			if instance["plugin_id"] then plugin = true end
			if instance["group_id"]  then group = true end

			if group then
				if skip_line then goto nextline end

				local g_id   = instance["group_id"]
				local routes = instance["routes"]
				local name   = instance["name"]
				local group  = group_by_id(g_id)
				if not(group) then
					local group = Session:new_route_group(name)
					for _, v in pairs(routes) do
						local rt = Session:route_by_id(PBD.ID(v))
						if rt:isnil() then rt = Session:route_by_name(name) end
						if not(rt:isnil()) then group:add(rt) end
					end
				end
			end

			if route then
				local substitution = tonumber(dry_run["destination-"..i])
				if skip_line or (substitution == 0) then
					bypass_routes[#bypass_routes + 1] = instance["route_id"]
					goto nextline
				end

				local old_order = ARDOUR.ProcessorList()
				local route_id = instance["route_id"]
				local r_id = PBD.ID(instance["route_id"])
				local muted, soloed = instance["muted"], instance["soloed"]
				local order = instance["order"]
				local cache = instance["cache"]
				local group = instance["group"]
				local group_name = instance["group_name"]
				local name  = instance["route_name"]
				local gc, tc, pc = instance["gain_control"], instance["trim_control"], instance["pan_control"]

				if not(substitution == instance["route_id"]) then
					print('SUBSTITUTION FOR: ', name, substitution, Session:route_by_id(PBD.ID(substitution)):name())
					--bypass_routes[#bypass_routes + 1] = route_id
					was_subbed = true
					r_id = PBD.ID(substitution)
				end

				local rt = Session:route_by_id(r_id)
				if rt:isnil() then rt = Session:route_by_name(name) end
				if rt:isnil() then goto nextline end

				local cur_group_id = route_groupid_interrogate(rt)
				if not(group) and (cur_group_id) then
					local g = group_by_id(cur_group_id)
					if g then g:remove(rt) end
				end

				local rt_group = group_by_name(group_name)
				if rt_group then rt_group:add(rt) end

				well_known = {'PRE', 'Trim', 'EQ', 'Comp', 'Fader', 'POST'}

				for k, v in pairs(order) do
					local proc = Session:processor_by_id(PBD.ID(1))
					if not(was_subbed) then
						proc = Session:processor_by_id(PBD.ID(v))
					end
					if proc:isnil() then
						for id, name in pairs(cache) do
							if v == id then
								proc = new_plugin(name)
								for _, control in pairs(well_known) do
									if name == control then
										proc = get_processor_by_name(rt, control)
										invalidate[v] = proc:to_stateful():id():to_s()
										goto nextproc
									end
								end
								if not(proc) then goto nextproc end
								if not(proc:isnil()) then
									rt:add_processor_by_index(proc, 0, nil, true)
									invalidate[v] = proc:to_stateful():id():to_s()
								end
							end
						end
					end
					::nextproc::
					if proc and not(proc:isnil()) then old_order:push_back(proc) end
				end
				rt:reorder_processors(old_order, nil)
				if muted  then rt:mute_control():set_value(1, 1) else rt:mute_control():set_value(0, 1) end
				if soloed then rt:solo_control():set_value(1, 1) else rt:solo_control():set_value(0, 1) end
				rt:gain_control():set_value(gc, 1)
				rt:trim_control():set_value(tc, 1)
				if pc ~= false then rt:pan_azimuth_control():set_value(pc, 1) end
			end

			if plugin then
				if skip_line then goto nextline end

				--if the plugin is owned by a route
				--we decided not to use, skip it
				for _, v in pairs(bypass_routes) do
					if instance["owned_by_route_id"] == v then
						goto nextline
					end
				end

				local enable = {}
				local params = instance["parameters"]
				local p_id   = instance["plugin_id"]
				local act    = instance["active"]

				for k, v in pairs(invalidate) do --invalidate any deleted plugin's id
					if p_id == k then
						p_id = v
					end
				end

				local proc = Session:processor_by_id(PBD.ID(p_id))
				if proc:isnil() then goto nextline end
				local plug = proc:to_insert():plugin(0)

				for k, v in pairs(params) do
					local label = plug:parameter_label(k)
					if string.find(label, "Assign") or string.find(label, "Enable") then --@ToDo: Check Plugin type == LADSPA or VST?
						enable[k] = v --queue any assignments/enables for after the initial parameter recalling to duck the 'in-on-change' feature
					end
					ARDOUR.LuaAPI.set_processor_param(proc, k, v)
				end

				for k, v in pairs(enable) do
					ARDOUR.LuaAPI.set_processor_param(proc, k, v)
				end
				if act then proc:activate() else proc:deactivate() end
			end

			::nextline::
			i = i + 1

		end
	end

	function dry_run(debug, path)
		--returns a dialog-able table of
		--everything we do (logically)
		--in the recall function
		local route_values = {['----'] = "0"}
		for r in Session:get_routes():iter() do
			route_values[r:name()] =  r:to_stateful():id():to_s()
		end

		local i = 0
		local dry_table = {
			{type = "label", align="right", key="col-1-title", col=0, colspan=1, title = 'Source:'},
			{type = "label", align="left", key="col-2-title", col=1, colspan=1, title = 'Destination:'},
		}
		local file = io.open(path, "r")
		assert(file, "File not found!")

		for l in file:lines() do
			local do_plugin, do_route, do_group = false, false, false
			local f = load(l)

			if debug then
				print(i, string.sub(l, 0, 29), f)
			end

			if f then f() end

			if instance["route_id"]  then do_route = true end
			if instance["plugin_id"] then do_plugin = true end
			if instance["group_id"]  then do_group = true end

			if do_group then
				local group_id   = instance["group_id"]
				local group_name = instance["name"]
				local dlg_title, action_title  = "", ""

				local group_ptr  = group_by_id(group_id)

				if not(group_ptr) then
					new_group = Session:new_route_group(group_name)
					dlg_title = string.format("(Group) %s.", group_name, new_group:name())
					--action_title = "will create and use settings"
				else
					dlg_title = string.format("(Group) %s.", group_ptr:name())
					--action_title = "will use group settings"
				end
				table.insert(dry_table, {
					type = "label", align="right", key =  "type-"..i , col = 0, colspan = 1, title = ""
				})
				table.insert(dry_table, {
					type = "label", align="right", key =  "group-"..i , col = 1, colspan = 1, title = dlg_title
				})
			end

			if do_route then
				local route_id   = instance["route_id"]
				local route_name = instance["route_name"]
				local dlg_title = ""

				local route_ptr = Session:route_by_id(PBD.ID(route_id))

				if route_ptr:isnil() then
					route_ptr = Session:route_by_name(route_name)
					if not(route_ptr:isnil()) then
						dlg_title = string.format("%s", route_ptr:name())
						--action_title = "will use route settings"
					else
						dlg_title = string.format("%s", route_name)
						--action_title = "will be ignored"
					end
				else
					dlg_title = string.format("%s", route_ptr:name())
					--action_title = "will use route settings"
				end
				if route_ptr:isnil() then name = route_name else name = route_ptr:name() end

				table.insert(dry_table, {
					type = "label",    align="right", key = "route-"..i , col = 1, colspan = 1, title = dlg_title
				})
				table.insert(dry_table, {
					type = "dropdown", align="left", key = "destination-"..i, col = 2, colspan = 1, title = "", values = route_values, default = name or "----"
				})
			end
			i = i + 1
		end
		return dry_table
	end

	local global_vs_local_dlg = {
		{ type = "label", col=0, colspan=20, align="left", title = "" },
		{
			type = "radio", col=0, colspan=20, align="left", key = "recall-dir", title = "", values =
			{
				['Pick from Global Settings'] = 1, ['Pick from Local Settings'] = 2
			},
			default = 'Pick from Local Settings'
		},
		{ type = "label", col=0, colspan=20, align="left", title = ""},
	}

	local recall_options = {
		{ type = "label", col=0, colspan=10, align="left", title = "" },
		{ type = "file",  col=0, colspan=15, align="left", key = "file", title = "Select a Settings File:",  path = ARDOUR.LuaAPI.build_filename(Session:path(), "export", "params.lua") },
		{ type = "label", col=0, colspan=10, align="left", title = "" },
	}

	local gvld = LuaDialog.Dialog("Recall Mixer Settings:", global_vs_local_dlg):run()

	if not(gvld) then
		return
	else
		if gvld['recall-dir'] == 1 then
			local global_ok = isdir(global_path)
			local global_default_path = ARDOUR.LuaAPI.build_filename(global_path, fetch_valid_settings_file(global_path, string.format("FactoryDefault-%s.lua", whoami())))
			print(global_default_path)
			if global_ok then
				recall_options[2]['path'] = global_default_path
				local rv = LuaDialog.Dialog("Recall Mixer Settings:", recall_options):run()
				if not(rv) then return end
				local dry_return = LuaDialog.Dialog("Mixer Store:", dry_run(false, rv['file'])):run()
				if dry_return then
					recall(false, rv['file'], dry_return)
				else
					return
				end
			else
				LuaDialog.Message ("Recall Mixer Settings:",
					global_path .. ' does not exist!\nPlease run Store Mixer Settings first.',
					LuaDialog.MessageType.Info, LuaDialog.ButtonType.Close):run()
			end
		end

		if gvld['recall-dir'] == 2 then
			local local_ok = isdir(local_path)
			local local_default_path = ARDOUR.LuaAPI.build_filename(local_path, fetch_valid_settings_file(local_path))
			print(local_default_path)
			if local_ok then
				recall_options[2]['path'] = local_default_path
				local rv = LuaDialog.Dialog("Recall Mixer Settings:", recall_options):run()
				if not(rv) then return end
				local dry_return = LuaDialog.Dialog("Mixer Store:", dry_run(false, rv['file'])):run()
				if dry_return then
					recall(false, rv['file'], dry_return)
				else
					return
				end
			else
				LuaDialog.Message ("Recall Mixer Settings:",
					local_path .. 'does not exist!\nPlease run Store Mixer Settings first.',
					LuaDialog.MessageType.Info, LuaDialog.ButtonType.Close):run()
			end
		end
	end

end end