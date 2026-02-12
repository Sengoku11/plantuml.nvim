local M = {}
local ascii_renderer_command = { "plantuml", "-ttxt", "-pipe" }
local image_renderer_command = { "plantuml", "-tpng", "-pipe" }
local ascii_output_state = {
	buffer = nil,
	window = nil,
}
local image_output_state = {
	buffer = nil,
	window = nil,
}

local defaults = {
	open = "fullscreen", -- right | bottom | fullscreen
	filetypes = { "puml" },
	auto_wrap_markers = true,
	window = {
		right_width = 80,
		bottom_height = 18,
	},
}

local config = vim.deepcopy(defaults)
local command_created = false

local function notify(msg, level)
	vim.notify("[plantuml.nvim] " .. msg, level or vim.log.levels.INFO)
end

local function contains(list, value)
	for _, item in ipairs(list) do
		if item == value then
			return true
		end
	end
	return false
end

local function trim(value)
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalize_string_list(value, fallback)
	local normalized = {}
	if type(value) == "table" then
		for _, item in ipairs(value) do
			if type(item) == "string" then
				local text = trim(item):lower()
				if text ~= "" then
					normalized[#normalized + 1] = text
				end
			end
		end
	end

	if #normalized > 0 then
		return normalized
	end

	return vim.deepcopy(fallback)
end

local function render_error(code, stdout, stderr)
	local message = trim(stderr or "")
	if message == "" then
		message = trim(stdout or "")
	end
	if message == "" then
		message = "PlantUML command failed with exit code " .. tostring(code)
	end
	return message
end

local function valid_buffer(buffer)
	return type(buffer) == "number" and vim.api.nvim_buf_is_valid(buffer)
end

local function valid_window(window)
	return type(window) == "number" and vim.api.nvim_win_is_valid(window)
end

local function is_ascii_output_buffer(buffer)
	if not valid_buffer(buffer) then
		return false
	end

	local ok, value = pcall(vim.api.nvim_buf_get_var, buffer, "plantuml_output_buffer")
	return ok and value == true
end

local function is_image_output_buffer(buffer)
	if not valid_buffer(buffer) then
		return false
	end

	local ok, value = pcall(vim.api.nvim_buf_get_var, buffer, "plantuml_image_output_buffer")
	return ok and value == true
end

local function parse_open_fence(line)
	local ticks, info = line:match("^%s*(`+)%s*(.-)%s*$")
	if not ticks then
		return nil
	end

	info = trim(info or "")
	if info:find("`", 1, true) then
		return nil
	end

	return ticks
end

local function parse_close_fence(line)
	return line:match("^%s*(`+)%s*$")
end

local function locate_fenced_block(lines, cursor_line)
	local open_block = nil

	for i = 1, cursor_line do
		local line = lines[i]
		if open_block then
			local close_ticks = parse_close_fence(line)
			if close_ticks and #close_ticks >= open_block.tick_count then
				open_block = nil
			end
		else
			local open_ticks = parse_open_fence(line)
			if open_ticks then
				open_block = {
					start_line = i,
					tick_count = #open_ticks,
				}
			end
		end
	end

	if not open_block then
		return nil, "Cursor is not inside a fenced code block"
	end

	local finish_line = nil
	for i = cursor_line + 1, #lines do
		local close_ticks = parse_close_fence(lines[i])
		if close_ticks and #close_ticks >= open_block.tick_count then
			finish_line = i
			break
		end
	end

	if not finish_line then
		return nil, "Fenced code block under cursor is not closed"
	end

	return {
		start_line = open_block.start_line,
		finish_line = finish_line,
	}
end

local function normalize_mode(mode)
	local selected = mode or config.open

	if selected ~= "right" and selected ~= "bottom" and selected ~= "fullscreen" then
		return nil, ("Invalid open mode '%s' (expected: right | bottom | fullscreen)"):format(selected)
	end
	return selected
end

local function get_file_kind()
	local name = vim.api.nvim_buf_get_name(0)
	local ext = name:match("%.([^.]+)$")
	if ext then
		ext = ext:lower()
	end

	local ft = vim.bo.filetype

	if ext and contains(config.filetypes, ext) then
		return "puml"
	end

	if contains(config.filetypes, ft) then
		return "puml"
	end

	if ext == "md" or ft == "markdown" then
		return "markdown"
	end

	return nil
end

local function extract_markdown_source(lines)
	local cursor = vim.api.nvim_win_get_cursor(0)
	local cursor_line = cursor[1]
	local cursor_col = cursor[2] + 1
	local block, err = locate_fenced_block(lines, cursor_line)

	if block then
		local source_lines = {}
		for i = block.start_line + 1, block.finish_line - 1 do
			source_lines[#source_lines + 1] = lines[i]
		end

		return table.concat(source_lines, "\n")
	end

	local line = lines[cursor_line] or ""
	local line_len = #line
	local index = 1

	while index <= line_len do
		local open_start, open_end = line:find("`+", index)
		if not open_start then
			break
		end

		local tick_count = open_end - open_start + 1
		local delimiter = string.rep("`", tick_count)
		local search_from = open_end + 1
		local close_start, close_end = line:find(delimiter, search_from, true)

		while close_start do
			if cursor_col >= open_start and cursor_col <= close_end then
				return line:sub(open_end + 1, close_start - 1)
			end

			search_from = close_end + 1
			close_start, close_end = line:find(delimiter, search_from, true)
		end

		index = open_end + 1
	end

	return nil, err or "Cursor is not inside a markdown backtick block"
end

local function source_from_current_buffer()
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local kind = get_file_kind()

	if kind == "puml" then
		return table.concat(lines, "\n")
	end

	if kind == "markdown" then
		return extract_markdown_source(lines)
	end

	return nil, "Unsupported file. Use markdown or a filetype/extension listed in config.filetypes."
end

local function ensure_plantuml_markers(source)
	if not config.auto_wrap_markers then
		return source
	end

	if source:match("@startuml") then
		return source
	end

	return "@startuml\n" .. source .. "\n@enduml\n"
end

local function run_renderer(command, source, binary)
	if vim.system then
		local result = vim.system(command, { text = not binary, stdin = source }):wait()
		return result.code, result.stdout or "", result.stderr or ""
	end

	local escaped = vim.tbl_map(vim.fn.shellescape, command)
	local shell_command = table.concat(escaped, " ")
	local stdout = vim.fn.system(shell_command, source)
	return vim.v.shell_error, stdout or "", ""
end

local function write_binary_file(path, data)
	local file, err = io.open(path, "wb")
	if not file then
		return nil, err or "unknown error"
	end

	file:write(data)
	file:close()
	return true
end

local function set_close_mapping(buffer)
	vim.keymap.set("n", "q", function()
		local closed = pcall(function()
			vim.cmd("close")
		end)
		if not closed then
			pcall(function()
				vim.cmd("tabclose")
			end)
		end
	end, {
		buffer = buffer,
		silent = true,
		nowait = true,
		desc = "Close PlantUML output",
	})
end

local function set_output_content(buffer, output)
	if not valid_buffer(buffer) then
		return
	end

	local lines = vim.split(output, "\n", { plain = true, trimempty = false })
	vim.bo[buffer].modifiable = true
	vim.bo[buffer].readonly = false
	vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
	vim.bo[buffer].modifiable = false
	vim.bo[buffer].readonly = true
end

local function create_output_buffer(output)
	local buffer = vim.api.nvim_create_buf(false, true)
	vim.bo[buffer].buftype = "nofile"
	vim.bo[buffer].bufhidden = "wipe"
	vim.bo[buffer].swapfile = false
	vim.bo[buffer].filetype = "plantuml_ascii"
	vim.api.nvim_buf_set_var(buffer, "plantuml_output_buffer", true)

	set_output_content(buffer, output)
	set_close_mapping(buffer)

	return buffer
end

local function find_existing_output_window(state, matcher)
	if valid_window(state.window) then
		local buffer = vim.api.nvim_win_get_buf(state.window)
		if matcher(buffer) then
			state.buffer = buffer
			return state.window, buffer
		end
	end

	for _, window in ipairs(vim.api.nvim_list_wins()) do
		local buffer = vim.api.nvim_win_get_buf(window)
		if matcher(buffer) then
			state.window = window
			state.buffer = buffer
			return window, buffer
		end
	end

	if valid_buffer(state.buffer) and matcher(state.buffer) then
		return nil, state.buffer
	end

	state.window = nil
	state.buffer = nil
	return nil, nil
end

local function open_output_window(mode, buffer, state)
	if mode == "right" then
		vim.cmd("rightbelow vsplit")
	elseif mode == "bottom" then
		vim.cmd("rightbelow split")
	else
		vim.cmd("tabnew")
	end

	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buffer)
	state.window = win
	state.buffer = buffer

	if mode == "right" and type(config.window.right_width) == "number" then
		pcall(vim.api.nvim_win_set_width, win, config.window.right_width)
	elseif mode == "bottom" and type(config.window.bottom_height) == "number" then
		pcall(vim.api.nvim_win_set_height, win, config.window.bottom_height)
	end

	return win
end

local function derive_image_path()
	local source_path = vim.api.nvim_buf_get_name(0)
	local directory = vim.fn.getcwd()
	local basename = "plantuml"

	if source_path ~= "" then
		directory = vim.fn.fnamemodify(source_path, ":p:h")
		basename = vim.fn.fnamemodify(source_path, ":t:r")
		if basename == "" then
			basename = "plantuml"
		end
	end

	return directory .. "/" .. basename .. ".png"
end

local function ensure_image_buffer(path)
	local buffer = vim.fn.bufadd(path)
	if type(buffer) ~= "number" or buffer <= 0 then
		return nil, "Failed to create image buffer"
	end

	if vim.fn.bufloaded(buffer) == 0 then
		local loaded = pcall(vim.fn.bufload, buffer)
		if not loaded then
			return nil, "Failed to load rendered image buffer"
		end
	end

	pcall(vim.api.nvim_buf_call, buffer, function()
		vim.cmd("silent noautocmd edit!")
	end)

	vim.api.nvim_buf_set_var(buffer, "plantuml_image_output_buffer", true)
	vim.bo[buffer].modifiable = false
	vim.bo[buffer].readonly = true
	vim.bo[buffer].swapfile = false
	set_close_mapping(buffer)

	return buffer
end

function M.render_ascii(mode)
	local resolved_mode, mode_err = normalize_mode(mode)
	if not resolved_mode then
		notify(mode_err, vim.log.levels.ERROR)
		return
	end

	local source, source_err = source_from_current_buffer()
	if not source then
		notify(source_err, vim.log.levels.ERROR)
		return
	end

	local code, stdout, stderr = run_renderer(ascii_renderer_command, ensure_plantuml_markers(source), false)
	if code ~= 0 then
		notify(render_error(code, stdout, stderr), vim.log.levels.ERROR)
		return
	end

	local window, buffer = find_existing_output_window(ascii_output_state, is_ascii_output_buffer)
	if not valid_buffer(buffer) then
		buffer = create_output_buffer(stdout)
		open_output_window(resolved_mode, buffer, ascii_output_state)
		return
	end

	set_output_content(buffer, stdout)

	if valid_window(window) then
		ascii_output_state.window = window
		ascii_output_state.buffer = buffer
		return
	end

	open_output_window(resolved_mode, buffer, ascii_output_state)
end

function M.render_img(mode)
	local resolved_mode, mode_err = normalize_mode(mode)
	if not resolved_mode then
		notify(mode_err, vim.log.levels.ERROR)
		return
	end

	local source, source_err = source_from_current_buffer()
	if not source then
		notify(source_err, vim.log.levels.ERROR)
		return
	end

	local code, stdout, stderr = run_renderer(image_renderer_command, ensure_plantuml_markers(source), true)
	if code ~= 0 then
		notify(render_error(code, stdout, stderr), vim.log.levels.ERROR)
		return
	end

	if stdout == "" then
		notify("PlantUML returned empty image output", vim.log.levels.ERROR)
		return
	end

	local image_path = derive_image_path()
	local written, write_err = write_binary_file(image_path, stdout)
	if not written then
		notify("Failed to write rendered image: " .. tostring(write_err), vim.log.levels.ERROR)
		return
	end

	local buffer, buffer_err = ensure_image_buffer(image_path)
	if not buffer then
		notify(buffer_err, vim.log.levels.ERROR)
		return
	end

	local window = select(1, find_existing_output_window(image_output_state, is_image_output_buffer))
	if valid_window(window) then
		if vim.api.nvim_win_get_buf(window) ~= buffer then
			vim.api.nvim_win_set_buf(window, buffer)
		end
		image_output_state.window = window
		image_output_state.buffer = buffer
		return
	end

	open_output_window(resolved_mode, buffer, image_output_state)
end

local function create_command()
	if command_created then
		return
	end

	vim.api.nvim_create_user_command("PlantumlRenderAscii", function(opts)
		local mode = opts.args ~= "" and opts.args or nil
		M.render_ascii(mode)
	end, {
		desc = "Render PlantUML as ASCII text",
		nargs = "?",
		complete = function()
			return { "right", "bottom", "fullscreen" }
		end,
	})

	vim.api.nvim_create_user_command("PlantumlRenderImg", function(opts)
		local mode = opts.args ~= "" and opts.args or nil
		M.render_img(mode)
	end, {
		desc = "Render PlantUML as PNG image",
		nargs = "?",
		complete = function()
			return { "right", "bottom", "fullscreen" }
		end,
	})

	command_created = true
end

function M.setup(opts)
	config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
	config.filetypes = normalize_string_list(config.filetypes, defaults.filetypes)
	create_command()
end

function M.get_config()
	return config
end

return M
