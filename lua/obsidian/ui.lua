local abc = require "obsidian.abc"
local util = require "obsidian.util"
local log = require "obsidian.log"
local search = require "obsidian.search"
local Path = require "obsidian.path"
local DefaultTbl = require("obsidian.collections").DefaultTbl
local iter = require("obsidian.itertools").iter
local strings = require "plenary.strings"

local M = {}

local NAMESPACE = "ObsidianUI"

-- Estado Global: Modo Edição e Cache de Performance
M._paused = false
M._link_existence_cache = {}
M._last_cache_clear = os.time()

--- Instala os grupos de destaque necessários
---@param ui_opts obsidian.config.UIOpts
local function install_hl_groups(ui_opts)
  for group_name, opts in pairs(ui_opts.hl_groups) do
    vim.api.nvim_set_hl(0, group_name, opts)
  end
  -- Cores exclusivas para links quebrados (Prioridade Máxima)
  vim.api.nvim_set_hl(0, "ObsidianOrange", { fg = "#f78c6c", bold = true })
  vim.api.nvim_set_hl(0, "ObsidianError", { fg = "#ff5370", bold = true, undercurl = true })
end

-- Cache local para evitar redesenho desnecessário
M._buf_mark_cache = DefaultTbl.new(DefaultTbl.with_tbl)

local function cache_get(bufnr, ns_id, mark_id)
  return M._buf_mark_cache[bufnr][ns_id][mark_id]
end

local function cache_set(bufnr, ns_id, mark)
  assert(mark.id ~= nil)
  M._buf_mark_cache[bufnr][ns_id][mark.id] = mark
end

local function cache_evict(bufnr, ns_id, mark_id)
  M._buf_mark_cache[bufnr][ns_id][mark_id] = nil
end

local function cache_clear(bufnr, ns_id)
  M._buf_mark_cache[bufnr][ns_id] = {}
end

---@class ExtMark : obsidian.ABC
---@field id integer|?
---@field row integer
---@field col integer
---@field opts ExtMarkOpts
local ExtMark = abc.new_class {
  __eq = function(a, b)
    return a.row == b.row and a.col == b.col and a.opts == b.opts
  end,
}

M.ExtMark = ExtMark

---@class ExtMarkOpts : obsidian.ABC
local ExtMarkOpts = abc.new_class()
M.ExtMarkOpts = ExtMarkOpts

ExtMarkOpts.from_tbl = function(data)
  local self = ExtMarkOpts.init()
  self.end_row = data.end_row
  self.end_col = data.end_col
  self.conceal = data.conceal
  self.hl_group = data.hl_group
  self.spell = data.spell
  self.priority = data.priority or 50
  return self
end

ExtMarkOpts.to_tbl = function(self)
  return {
    end_row = self.end_row,
    end_col = self.end_col,
    conceal = self.conceal,
    hl_group = self.hl_group,
    spell = self.spell,
    priority = self.priority,
  }
end

ExtMark.new = function(id, row, col, opts)
  local self = ExtMark.init()
  self.id = id
  self.row = row
  self.col = col
  self.opts = opts
  return self
end

ExtMark.materialize = function(self, bufnr, ns_id)
  if self.id == nil then
    self.id = vim.api.nvim_buf_set_extmark(bufnr, ns_id, self.row, self.col, self.opts:to_tbl())
  end
  cache_set(bufnr, ns_id, self)
  return self
end

ExtMark.clear = function(self, bufnr, ns_id)
  if self.id ~= nil then
    cache_evict(bufnr, ns_id, self.id)
    return vim.api.nvim_buf_del_extmark(bufnr, ns_id, self.id)
  else
    return false
  end
end

ExtMark.collect = function(bufnr, ns_id, region_start, region_end)
  region_start = region_start or 0
  region_end = region_end or -1
  local marks = {}
  for data in iter(vim.api.nvim_buf_get_extmarks(bufnr, ns_id, region_start, region_end, { details = true })) do
    local mark = ExtMark.new(data[1], data[2], data[3], ExtMarkOpts.from_tbl(data[4]))
    local cached_mark = cache_get(bufnr, ns_id, mark.id)
    if cached_mark ~= nil then
      mark.opts.conceal = cached_mark.opts.conceal
    end
    cache_set(bufnr, ns_id, mark)
    marks[#marks + 1] = mark
  end
  return marks
end

ExtMark.clear_range = function(bufnr, ns_id, line_start, line_end)
  return vim.api.nvim_buf_clear_namespace(bufnr, ns_id, line_start, line_end)
end

ExtMark.clear_line = function(bufnr, ns_id, line)
  return ExtMark.clear_range(bufnr, ns_id, line, line + 1)
end

--- Validação de Link com Cache e suporte a .md oculto (Excalidraw)
local function check_link_exists(client, link_content)
  local now = os.time()
  if now - M._last_cache_clear > 5 then
    M._link_existence_cache = {}
    M._last_cache_clear = now
  end
  if M._link_existence_cache[link_content] ~= nil then
    return M._link_existence_cache[link_content]
  end

  local clean = link_content:match "([^#|]+)" or link_content
  clean = vim.trim(clean)
  if #clean == 0 then
    return true
  end

  local vault_root = tostring(client.dir)
  local search_path = vault_root .. "/**"
  local found = false

  -- 1. Tenta o nome exato
  if vim.fn.findfile(clean, search_path) ~= "" then
    found = true
  -- 2. Caso Excalidraw/Plugins (.md oculto no disco)
  elseif vim.fn.findfile(clean .. ".md", search_path) ~= "" then
    found = true
  else
    -- 3. Tenta as extensões permitidas
    local allowed_exts = client.opts.allowed_extensions or { ".md" }
    for _, ext in ipairs(allowed_exts) do
      local dot_ext = vim.startswith(ext, ".") and ext or "." .. ext
      if vim.fn.findfile(clean .. dot_ext, search_path) ~= "" then
        found = true
        break
      end
    end
  end

  if not found and vim.fn.isdirectory(vault_root .. "/" .. clean) == 1 then
    found = true
  end
  M._link_existence_cache[link_content] = found
  return found
end

--- Processa Referências (Links, Tags, BlockIDs)
local function get_line_ref_extmarks(marks, line, lnum, ui_opts, client)
  local matches = search.find_refs(line, { include_naked_urls = true, include_tags = true, include_block_ids = true })
  for match in iter(matches) do
    local m_start, m_end, m_type = unpack(match)

    local is_broken = false
    if m_type == search.RefTypes.Wiki or m_type == search.RefTypes.WikiWithAlias then
      local content = line:sub(m_start + 2, m_end - 2)
      if client and not check_link_exists(client, content) then
        is_broken = true
      end
    end

    if is_broken then
      local col_0 = m_start - 1
      -- Destaque de Link Quebrado (Prioridade 250 para vencer outros plugins)
      marks[#marks + 1] = ExtMark.new(
        nil,
        lnum,
        col_0 + 1,
        ExtMarkOpts.from_tbl { end_row = lnum, end_col = col_0 + 2, hl_group = "ObsidianOrange", priority = 250 }
      )
      marks[#marks + 1] = ExtMark.new(
        nil,
        lnum,
        col_0 + 2,
        ExtMarkOpts.from_tbl {
          end_row = lnum,
          end_col = m_end - 2,
          hl_group = "ObsidianError",
          priority = 250,
          spell = false,
        }
      )
      marks[#marks + 1] = ExtMark.new(
        nil,
        lnum,
        m_end - 2,
        ExtMarkOpts.from_tbl { end_row = lnum, end_col = m_end - 1, hl_group = "ObsidianOrange", priority = 250 }
      )
    elseif m_type == search.RefTypes.WikiWithAlias then
      local pipe_loc = string.find(line, "|", m_start, true)
      if pipe_loc then
        marks[#marks + 1] =
          ExtMark.new(nil, lnum, m_start - 1, ExtMarkOpts.from_tbl { end_row = lnum, end_col = pipe_loc, conceal = "" })
        marks[#marks + 1] = ExtMark.new(
          nil,
          lnum,
          pipe_loc,
          ExtMarkOpts.from_tbl {
            end_row = lnum,
            end_col = m_end - 2,
            hl_group = ui_opts.reference_text.hl_group,
            spell = false,
          }
        )
        marks[#marks + 1] =
          ExtMark.new(nil, lnum, m_end - 2, ExtMarkOpts.from_tbl { end_row = lnum, end_col = m_end, conceal = "" })
      end
    elseif m_type == search.RefTypes.Wiki then
      marks[#marks + 1] = ExtMark.new(
        nil,
        lnum,
        m_start - 1,
        ExtMarkOpts.from_tbl { end_row = lnum, end_col = m_start + 1, conceal = "" }
      )
      marks[#marks + 1] = ExtMark.new(
        nil,
        lnum,
        m_start + 1,
        ExtMarkOpts.from_tbl {
          end_row = lnum,
          end_col = m_end - 2,
          hl_group = ui_opts.reference_text.hl_group,
          spell = false,
        }
      )
      marks[#marks + 1] =
        ExtMark.new(nil, lnum, m_end - 2, ExtMarkOpts.from_tbl { end_row = lnum, end_col = m_end, conceal = "" })
    elseif m_type == search.RefTypes.Markdown then
      local closing = string.find(line, "]", m_start, true)
      if closing then
        local is_url = util.is_url(string.sub(line, closing + 2, m_end - 1))
        marks[#marks + 1] =
          ExtMark.new(nil, lnum, m_start - 1, ExtMarkOpts.from_tbl { end_row = lnum, end_col = m_start, conceal = "" })
        marks[#marks + 1] = ExtMark.new(
          nil,
          lnum,
          m_start,
          ExtMarkOpts.from_tbl {
            end_row = lnum,
            end_col = closing - 1,
            hl_group = ui_opts.reference_text.hl_group,
            spell = false,
          }
        )
        marks[#marks + 1] = ExtMark.new(
          nil,
          lnum,
          closing - 1,
          ExtMarkOpts.from_tbl { end_row = lnum, end_col = closing + 1, conceal = is_url and " " or "" }
        )
        marks[#marks + 1] = ExtMark.new(
          nil,
          lnum,
          closing + 1,
          ExtMarkOpts.from_tbl {
            end_row = lnum,
            end_col = m_end - 1,
            conceal = is_url and ui_opts.external_link_icon.char or "",
            hl_group = ui_opts.external_link_icon.hl_group,
          }
        )
        marks[#marks + 1] = ExtMark.new(
          nil,
          lnum,
          m_end - 1,
          ExtMarkOpts.from_tbl { end_row = lnum, end_col = m_end, conceal = is_url and " " or "" }
        )
      end
    elseif m_type == search.RefTypes.Tag then
      marks[#marks + 1] = ExtMark.new(
        nil,
        lnum,
        m_start - 1,
        ExtMarkOpts.from_tbl { end_row = lnum, end_col = m_end, hl_group = ui_opts.tags.hl_group, spell = false }
      )
    elseif m_type == search.RefTypes.BlockID then
      marks[#marks + 1] = ExtMark.new(
        nil,
        lnum,
        m_start - 1,
        ExtMarkOpts.from_tbl { end_row = lnum, end_col = m_end, hl_group = ui_opts.block_ids.hl_group, spell = false }
      )
    end
  end
  return marks
end

--- Atualiza as marcações visuais no buffer
local function update_extmarks(bufnr, ns_id, ui_opts)
  if M._paused then
    return
  end
  local client = require("obsidian").get_client()
  local cur_marks_by_line = DefaultTbl.with_tbl()
  for mark in iter(ExtMark.collect(bufnr, ns_id)) do
    table.insert(cur_marks_by_line[mark.row], mark)
  end

  local inside_code_block = false
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
  for i, line in ipairs(lines) do
    local lnum = i - 1
    local cur_line_marks = cur_marks_by_line[lnum]

    if string.match(line, "^%s*```[^`]*$") then
      inside_code_block = not inside_code_block
      ExtMark.clear_line(bufnr, ns_id, lnum)
    elseif not inside_code_block then
      local new_line_marks = {}
      get_line_ref_extmarks(new_line_marks, line, lnum, ui_opts, client)

      if #new_line_marks > 0 then
        for mark in iter(new_line_marks) do
          if not util.tbl_contains(cur_line_marks, mark) then
            mark:materialize(bufnr, ns_id)
          end
        end
        for mark in iter(cur_line_marks) do
          if not util.tbl_contains(new_line_marks, mark) then
            mark:clear(bufnr, ns_id)
          end
        end
      else
        ExtMark.clear_line(bufnr, ns_id, lnum)
      end
    else
      ExtMark.clear_line(bufnr, ns_id, lnum)
    end
  end
end

--- Verifica se o buffer deve receber atualizações de UI
local function should_update(ui_opts, bufnr)
  if ui_opts.enable == false or M._paused then
    return false
  end
  bufnr = bufnr or 0
  local name = vim.api.nvim_buf_get_name(bufnr)
  local client = require("obsidian").get_client()
  -- Restrição rigorosa ao Vault
  if client and not client:path_is_note(name) then
    return false
  end
  if ui_opts.max_file_length and vim.fn.line "$" > ui_opts.max_file_length then
    return false
  end
  return true
end

--- Alterna entre Modo Visual e Modo Edição (Toggle)
M.toggle_ui = function(client)
  M._paused = not M._paused
  local ns_id = vim.api.nvim_create_namespace(NAMESPACE)
  if M._paused then
    vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)
    vim.opt_local.conceallevel = 0
    log.info "Obsidian UI: Desativado (Modo Edição)"
  else
    vim.opt_local.conceallevel = 2
    M.update(client.opts.ui, 0)
    log.info "Obsidian UI: Ativado"
  end
end

local function get_extmarks_autocmd_callback(ui_opts, throttle)
  local ns_id = vim.api.nvim_create_namespace(NAMESPACE)
  local callback = function(ev)
    if should_update(ui_opts, ev.buf) then
      update_extmarks(ev.buf, ns_id, ui_opts)
    end
  end
  return throttle and require("obsidian.async").throttle(callback, ui_opts.update_debounce) or callback
end

M.update = function(ui_opts, bufnr)
  bufnr = bufnr or 0
  if should_update(ui_opts, bufnr) then
    update_extmarks(bufnr, vim.api.nvim_create_namespace(NAMESPACE), ui_opts)
  end
end

M.setup = function(workspace, ui_opts)
  if ui_opts.enable == false then
    return
  end
  local group = vim.api.nvim_create_augroup("ObsidianUI" .. workspace.name, { clear = true })
  install_hl_groups(ui_opts)

  local pattern = tostring(workspace.root) .. "/*"

  vim.api.nvim_create_autocmd({ "BufEnter" }, {
    group = group,
    pattern = pattern,
    callback = function()
      if M._paused then
        return
      end
      local cl = vim.opt_local.conceallevel:get()
      if cl < 1 or cl > 2 then
        log.warn_once("Obsidian UI requires conceallevel 1 or 2", cl)
      end
      return true
    end,
  })

  vim.api.nvim_create_autocmd({ "BufEnter" }, {
    group = group,
    pattern = pattern,
    callback = get_extmarks_autocmd_callback(ui_opts, false),
  })

  vim.api.nvim_create_autocmd({ "BufEnter", "TextChanged", "TextChangedI" }, {
    group = group,
    pattern = pattern,
    callback = get_extmarks_autocmd_callback(ui_opts, true),
  })

  vim.api.nvim_create_autocmd({ "BufUnload" }, {
    group = group,
    pattern = pattern,
    callback = function(ev)
      cache_clear(ev.buf, vim.api.nvim_create_namespace(NAMESPACE))
    end,
  })
end

return M
