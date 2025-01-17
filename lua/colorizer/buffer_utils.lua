---Helper functions to highlight buffer smartly
--@module colorizer.buffer_utils
local api = vim.api
local buf_set_virtual_text = api.nvim_buf_set_extmark
local buf_get_lines = api.nvim_buf_get_lines
local create_namespace = api.nvim_create_namespace
local clear_namespace = api.nvim_buf_clear_namespace
local set_highlight = api.nvim_set_hl

local color_utils = require "colorizer.color_utils"
local color_is_bright = color_utils.color_is_bright

local matcher_utils = require "colorizer.matcher_utils"
local make_matcher = matcher_utils.make_matcher

local highlight_buffer, rehighlight_buffer
local BUFFER_LINES = {}
--- Default namespace used in `highlight_buffer` and `colorizer.attach_to_buffer`.
-- @see highlight_buffer
-- @see colorizer.attach_to_buffer
local DEFAULT_NAMESPACE = create_namespace "colorizer"
-- use a different namespace for tailwind as will be cleared if kept in Default namespace
local DEFAULT_NAMESPACE_TAILWIND = create_namespace "colorizer_tailwind"
local HIGHLIGHT_NAME_PREFIX = "colorizer"
--- Highlight mode which will be use to render the colour
local HIGHLIGHT_MODE_NAMES = {
  background = "mb",
  foreground = "mf",
  virtualtext = "mv",
}
local HIGHLIGHT_CACHE = {}

--- Clean the highlight cache
local function clear_hl_cache()
  HIGHLIGHT_CACHE = {}
end

--- Make a deterministic name for a highlight given these attributes
local function make_highlight_name(rgb, mode)
  return table.concat({ HIGHLIGHT_NAME_PREFIX, HIGHLIGHT_MODE_NAMES[mode], rgb }, "_")
end

local function create_highlight(rgb_hex, options)
  local mode = options.mode or "background"
  -- TODO validate rgb format?
  rgb_hex = rgb_hex:lower()
  local cache_key = table.concat({ HIGHLIGHT_MODE_NAMES[mode], rgb_hex }, "_")
  local highlight_name = HIGHLIGHT_CACHE[cache_key]

  -- Look up in our cache.
  if highlight_name then
    return highlight_name
  end

  -- convert from #fff to #ffffff
  if #rgb_hex == 3 then
    rgb_hex = table.concat {
      rgb_hex:sub(1, 1):rep(2),
      rgb_hex:sub(2, 2):rep(2),
      rgb_hex:sub(3, 3):rep(2),
    }
  end

  -- Create the highlight
  highlight_name = make_highlight_name(rgb_hex, mode)
  if mode == "foreground" then
    set_highlight(0, highlight_name, { fg = "#" .. rgb_hex })
  else
    local rr, gg, bb = rgb_hex:sub(1, 2), rgb_hex:sub(3, 4), rgb_hex:sub(5, 6)
    local r, g, b = tonumber(rr, 16), tonumber(gg, 16), tonumber(bb, 16)
    local fg_color
    if color_is_bright(r, g, b) then
      fg_color = "Black"
    else
      fg_color = "White"
    end
    set_highlight(0, highlight_name, { fg = fg_color, bg = "#" .. rgb_hex })
  end
  HIGHLIGHT_CACHE[cache_key] = highlight_name
  return highlight_name
end

local function add_highlight(options, buf, ns, data, line_start, line_end)
  clear_namespace(buf, ns, line_start, line_end)

  if vim.tbl_contains({ "foreground", "background" }, options.mode) then
    for linenr, hls in pairs(data) do
      for _, hl in ipairs(hls) do
        api.nvim_buf_add_highlight(buf, ns, hl.name, linenr, hl.range[1], hl.range[2])
      end
    end
  elseif options.mode == "virtualtext" then
    for linenr, hls in pairs(data) do
      for _, hl in ipairs(hls) do
        buf_set_virtual_text(0, ns, linenr, hl.range[2], {
          end_col = hl.range[2],
          virt_text = { { options.virtualtext or "■", hl.name } },
        })
      end
    end
  end
end

local function highlight_buffer_tailwind(buf, ns, mode, options)
  -- it can take some time to actually fetch the results
  -- on top of that, tailwindcss is quite slow in neovim
  vim.defer_fn(function()
    local opts = { textDocument = vim.lsp.util.make_text_document_params() }
    --@local
    ---@diagnostic disable-next-line: param-type-mismatch
    vim.lsp.buf_request(buf, "textDocument/documentColor", opts, function(err, results, _, _)
      if err == nil and results ~= nil then
        local datas, line_start, line_end = {}, nil, nil
        for _, color in pairs(results) do
          local cur_line = color.range.start.line
          if line_start then
            if cur_line < line_start then
              line_start = cur_line
            end
          else
            line_start = cur_line
          end

          local end_line = color.range["end"].line
          if line_end then
            if end_line > line_end then
              line_end = end_line
            end
          else
            line_end = end_line
          end

          local r, g, b, a = color.color.red or 0, color.color.green or 0, color.color.blue or 0, color.color.alpha or 0
          local rgb_hex = string.format("%02x%02x%02x", r * a * 255, g * a * 255, b * a * 255)
          local name = create_highlight(rgb_hex, mode)
          local first_col = color.range.start.character
          local end_col = color.range["end"].character

          local d = datas[cur_line] or {}
          table.insert(d, { name = name, range = { first_col, end_col } })
          datas[cur_line] = d
        end
        add_highlight(options, buf, ns, datas, line_start or 0, line_end and (line_end + 2) or -1)
      end
    end)
  end, 10)
end

local TW_LSP_AU_CREATED = {}
local TW_LSP_AU_ID = {}
local TW_LSP_CLIENT = {}
--- Highlight the buffer region.
-- Highlight starting from `line_start` (0-indexed) for each line described by `lines` in the
-- buffer `buf` and attach it to the namespace `ns`.
---@param buf number: buffer id
---@param ns number: The namespace id. Default is DEFAULT_NAMESPACE. Create it with `vim.api.create_namespace`
---@param lines table: the lines to highlight from the buffer.
---@param line_start number: line_start should be 0-indexed
---@param line_end number: Last line to highlight
---@param options table: Configuration options as described in `setup`
---@param options_local table: Buffer local variables
---@return nil|boolean|number,function|nil
function highlight_buffer(buf, ns, lines, line_start, line_end, options, options_local)
  if buf == 0 or buf == nil then
    buf = api.nvim_get_current_buf()
  end

  ns = ns or DEFAULT_NAMESPACE
  local loop_parse_fn = make_matcher(options)
  if not loop_parse_fn then
    return false
  end

  local data = {}
  local mode = options.mode == "background" and { mode = "background" } or { mode = "foreground" }
  for current_linenum, line in ipairs(lines) do
    current_linenum = current_linenum - 1 + line_start
    -- Upvalues are options and current_linenum
    local i = 1
    while i < #line do
      local length, rgb_hex = loop_parse_fn(line, i)
      if length and rgb_hex then
        local name = create_highlight(rgb_hex, mode)
        local d = data[current_linenum] or {}
        table.insert(d, { name = name, range = { i - 1, i + length - 1 } })
        data[current_linenum] = d
        i = i + length
      else
        i = i + 1
      end
    end
  end
  add_highlight(options, buf, ns, data, line_start, line_end)

  if not options.tailwind or (options.tailwind ~= "lsp" and options.tailwind ~= "both") then
    return
  end

  if not TW_LSP_CLIENT[buf] or TW_LSP_CLIENT[buf].is_stopped() then
    local function del_tailwind_stuff()
      TW_LSP_CLIENT[buf] = nil
    end
    if vim.version().minor >= 8 then
      -- create the autocmds so tailwind colours only activate when tailwindcss lsp is active
      function del_tailwind_stuff()
        pcall(api.nvim_del_autocmd, TW_LSP_AU_ID[buf][1])
        pcall(api.nvim_del_autocmd, TW_LSP_AU_ID[buf][2])
        TW_LSP_AU_CREATED[buf], TW_LSP_AU_ID[buf], TW_LSP_CLIENT[buf] = nil, nil, nil
      end

      if not TW_LSP_AU_CREATED[buf] then
        TW_LSP_AU_ID[buf], TW_LSP_AU_CREATED[buf], TW_LSP_CLIENT[buf] = {}, nil, nil
        TW_LSP_AU_ID[buf][1] = api.nvim_create_autocmd("LspAttach", {
          group = options_local.__augroup_id,
          buffer = buf,
          callback = function(args)
            local ok, client = pcall(vim.lsp.get_client_by_id, args.data.client_id)
            if ok then
              if client.name == "tailwindcss" and client.supports_method "textDocument/documentColor" then
                -- wait 100 ms for the first request
                TW_LSP_CLIENT[buf] = client
                vim.defer_fn(function()
                  highlight_buffer_tailwind(buf, DEFAULT_NAMESPACE_TAILWIND, mode, options)
                end, 100)
              end
            end
          end,
        })
        -- make sure the autocmds are deleted after lsp server is closed
        TW_LSP_AU_ID[buf][2] = api.nvim_create_autocmd("LspDetach", {
          group = options_local.__augroup_id,
          buffer = buf,
          callback = function()
            del_tailwind_stuff()
            clear_namespace(buf, DEFAULT_NAMESPACE_TAILWIND, 0, -1)
          end,
        })
        TW_LSP_AU_CREATED[buf] = true
      end
    end

    TW_LSP_CLIENT[buf] = nil

    local tailwind_client = vim.lsp.get_active_clients { bufnr = buf, name = "tailwindcss" }
    if vim.tbl_isempty(tailwind_client) then
      return DEFAULT_NAMESPACE_TAILWIND, del_tailwind_stuff
    end

    if not tailwind_client[1] or not tailwind_client[1].supports_method "textDocument/documentColor" then
      return DEFAULT_NAMESPACE_TAILWIND, del_tailwind_stuff
    end

    TW_LSP_CLIENT[buf] = tailwind_client[1]

    -- wait 100 ms for the first request
    vim.defer_fn(function()
      highlight_buffer_tailwind(buf, DEFAULT_NAMESPACE_TAILWIND, mode, options)
    end, 100)

    return DEFAULT_NAMESPACE_TAILWIND, del_tailwind_stuff
  end

  -- only try to do tailwindcss highlight if lsp is attached
  if TW_LSP_CLIENT[buf] then
    highlight_buffer_tailwind(buf, DEFAULT_NAMESPACE_TAILWIND, mode, options)
  end
end

-- get the amount lines to highlight
local function getrow(buf)
  if not BUFFER_LINES[buf] then
    BUFFER_LINES[buf] = {}
  end

  local a = api.nvim_buf_call(buf, function()
    return {
      vim.fn.line "w0",
      vim.fn.line "w$",
    }
  end)
  local min, max
  local new_min, new_max = a[1] - 1, a[2]
  local old_min, old_max = BUFFER_LINES[buf]["min"], BUFFER_LINES[buf]["max"]

  if old_min and old_max then
    -- Triggered for TextChanged autocmds
    -- TODO: Find a way to just apply highlight to changed text lines
    if old_max == new_max then
      min, max = new_min, new_max
    -- Triggered for WinScrolled autocmd - Scroll Down
    elseif old_max < new_max then
      min = old_max
      max = new_max
    -- Triggered for WinScrolled autocmd - Scroll Up
    elseif old_max > new_max then
      min = new_min
      max = new_min + (old_max - new_max)
    end
    -- just in case a long jump was made
    if max - min > new_max - new_min then
      min = new_min
      max = new_max
    end
  end
  min = min or new_min
  max = max or new_max
  -- store current window position to be used later to incremently highlight
  BUFFER_LINES[buf]["max"] = new_max
  BUFFER_LINES[buf]["min"] = new_min
  return min, max
end

--- Rehighlight the buffer if colorizer is active
---@param buf number: Buffer number
---@param options table: Buffer options
---@param options_local table|nil: Buffer local variables
---@param use_local_lines boolean|nil Whether to use lines num range from options_local
---@return nil|boolean|number,function|nil
function rehighlight_buffer(buf, options, options_local, use_local_lines)
  if buf == 0 or buf == nil then
    buf = api.nvim_get_current_buf()
  end

  local ns = DEFAULT_NAMESPACE

  local min, max
  if use_local_lines and options_local then
    min, max = options_local.__startline, options_local.__endline
  else
    min, max = getrow(buf)
  end

  local lines = buf_get_lines(buf, min, max, false)
  return highlight_buffer(buf, ns, lines, min, max, options, options_local or {})
end

--- @export
return {
  DEFAULT_NAMESPACE = DEFAULT_NAMESPACE,
  HIGHLIGHT_MODE_NAMES = HIGHLIGHT_MODE_NAMES,
  clear_hl_cache = clear_hl_cache,
  rehighlight_buffer = rehighlight_buffer,
  highlight_buffer = highlight_buffer,
}
