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

---@param ui_opts obsidian.config.UIOpts
local function install_hl_groups(ui_opts)
  for group_name, opts in pairs(ui_opts.hl_groups) do
    vim.api.nvim_set_hl(0, group_name, opts)
  end
  -- Grupos de destaque para links quebrados (Alta Prioridade)
  vim.api.nvim_set_hl(0, "ObsidianOrange", { fg = "#f78c6c", bold = true })
  vim.api.nvim_set_hl(0, "ObsidianError", { fg = "#ff5370", bold = true, undercurl = true })
end

M._buf_mark_cache = DefaultTbl.new(DefaultTbl.with_tbl)

---@param bufnr integer
---@param ns_id integer
---@param mark_id integer
---@return ExtMark|?
local function cache_get(bufnr, ns_id, mark_id)
  local buf_ns_cache = M._buf_mark_cache[bufnr][ns_id]
  return buf_ns_cache[mark_id]
end

---@param bufnr integer
---@param ns_id integer
---@param mark ExtMark
---@return ExtMark|?
local function cache_set(bufnr, ns_id, mark)
  assert(mark.id ~= nil)
  M._buf_mark_cache[bufnr][ns_id][mark.id] = mark
end

---@param bufnr integer
---@param ns_id integer
---@param mark_id integer
local function cache_evict(bufnr, ns_id, mark_id)
  M._buf_mark_cache[bufnr][ns_id][mark_id] = nil
end

---@param bufnr integer
---@param ns_id integer
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
---@field end_row integer
---@field end_col integer
---@field conceal string|?
---@field hl_group string|?
---@field spell boolean|?
---@field priority integer|?
local ExtMarkOpts = abc.new_class()

M.ExtMarkOpts = ExtMarkOpts

---@param data table
---@return ExtMarkOpts
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

---@param self ExtMarkOpts
---@return table
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

---@param id integer|?
---@param row integer
---@param col integer
---@param opts ExtMarkOpts
---@return ExtMark
ExtMark.new = function(id, row, col, opts)
  local self = ExtMark.init()
  self.id = id
  self.row = row
  self.col = col
  self.opts = opts
  return self
end

---@param self ExtMark
---@param bufnr integer
---@param ns_id integer
---@return ExtMark
ExtMark.materialize = function(self, bufnr, ns_id)
  if self.id == nil then
    self.id = vim.api.nvim_buf_set_extmark(bufnr, ns_id, self.row, self.col, self.opts:to_tbl())
  end
  cache_set(bufnr, ns_id, self)
  return self
end

---@param self ExtMark
---@param bufnr integer
---@param ns_id integer
---@return boolean
ExtMark.clear = function(self, bufnr, ns_id)
  if self.id ~= nil then
    cache_evict(bufnr, ns_id, self.id)
    return vim.api.nvim_buf_del_extmark(bufnr, ns_id, self.id)
  else
    return false
  end
end

---@param bufnr integer
---@param ns_id integer
---@param region_start integer|integer[]|?
---@param region_end integer|integer[]|?
---@return ExtMark[]
ExtMark.collect = function(bufnr, ns_id, region_start, region_end)
  region_start = region_start and region_start or 0
  region_end = region_end and region_end or -1
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

---@param bufnr integer
---@param ns_id integer
---@param line_start integer
---@param line_end integer
ExtMark.clear_range = function(bufnr, ns_id, line_start, line_end)
  return vim.api.nvim_buf_clear_namespace(bufnr, ns_id, line_start, line_end)
end

---@param bufnr integer
---@param ns_id integer
---@param line integer
ExtMark.clear_line = function(bufnr, ns_id, line)
  return ExtMark.clear_range(bufnr, ns_id, line, line + 1)
end

--- NOVO: Validação de existência de arquivo (Inversão de Controle)
local function check_link_exists(client, link_content)
  local clean = link_content:match "([^#|]+)" or link_content
  clean = vim.trim(clean)
  if #clean == 0 then
    return true
  end

  local allowed_exts = client.opts.allowed_extensions or { ".md" }
  local vault_root = tostring(client.dir)

  local has_ext = false
  for _, ext in ipairs(allowed_exts) do
    if vim.endswith(clean, ext) then
      has_ext = true
      break
    end
  end

  if has_ext then
    return #vim.fn.globpath(vault_root, "**/" .. clean, false, true) > 0
  else
    for _, ext in ipairs(allowed_exts) do
      if #vim.fn.globpath(vault_root, "**/" .. clean .. ext, false, true) > 0 then
        return true
      end
    end
  end
  return false
end

---@param marks ExtMark[]
---@param lnum integer
---@param ui_opts obsidian.config.UIOpts
---@return ExtMark[]
local function get_line_check_extmarks(marks, line, lnum, ui_opts)
  for char, opts in pairs(ui_opts.checkboxes) do
    if string.match(line, "^%s*- %[" .. util.escape_magic_characters(char) .. "%]") then
      local indent = util.count_indent(line)
      marks[#marks + 1] = ExtMark.new(
        nil,
        lnum,
        indent,
        ExtMarkOpts.from_tbl {
          end_row = lnum,
          end_col = indent + 5,
          conceal = opts.char,
          hl_group = opts.hl_group,
        }
      )
      return marks
    end
  end

  if ui_opts.bullets ~= nil and string.match(line, "^%s*[-%*%+] ") then
    local indent = util.count_indent(line)
    marks[#marks + 1] = ExtMark.new(
      nil,
      lnum,
      indent,
      ExtMarkOpts.from_tbl {
        end_row = lnum,
        end_col = indent + 1,
        conceal = ui_opts.bullets.char,
        hl_group = ui_opts.bullets.hl_group,
      }
    )
  end

  return marks
end

---@param marks ExtMark[]
---@param lnum integer
---@param ui_opts obsidian.config.UIOpts
---@param client obsidian.Client|?
---@return ExtMark[]
local function get_line_ref_extmarks(marks, line, lnum, ui_opts, client)
  local matches = search.find_refs(line, { include_naked_urls = true, include_tags = true, include_block_ids = true })
  for match in iter(matches) do
    local m_start, m_end, m_type = unpack(match)

    -- Lógica de Link Quebrado
    local is_broken = false
    if m_type == search.RefTypes.Wiki or m_type == search.RefTypes.WikiWithAlias then
      local content = line:sub(m_start + 2, m_end - 2)
      if client and not check_link_exists(client, content) then
        is_broken = true
      end
    end

    if is_broken then
      -- 1. Colchete Interior Esquerdo (Laranja)
      marks[#marks + 1] = ExtMark.new(
        nil,
        lnum,
        m_start,
        ExtMarkOpts.from_tbl {
          end_row = lnum,
          end_col = m_start + 1,
          hl_group = "ObsidianOrange",
          priority = 200,
        }
      )
      -- 2. Nome Central (Vermelho)
      marks[#marks + 1] = ExtMark.new(
        nil,
        lnum,
        m_start + 1,
        ExtMarkOpts.from_tbl {
          end_row = lnum,
          end_col = m_end - 2,
          hl_group = "ObsidianError",
          priority = 200,
          spell = false,
        }
      )
      -- 3. Colchete Interior Direito (Laranja)
      marks[#marks + 1] = ExtMark.new(
        nil,
        lnum,
        m_end - 2,
        ExtMarkOpts.from_tbl {
          end_row = lnum,
          end_col = m_end - 1,
          hl_group = "ObsidianOrange",
          priority = 200,
        }
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
    elseif m_type == search.RefTypes.NakedUrl then
      local domain_start = string.find(line, "://", m_start, true)
      if domain_start then
        domain_start = domain_start + 3
        marks[#marks + 1] = ExtMark.new(
          nil,
          lnum,
          m_start - 1,
          ExtMarkOpts.from_tbl { end_row = lnum, end_col = domain_start - 1, conceal = "" }
        )
        marks[#marks + 1] = ExtMark.new(
          nil,
          lnum,
          m_start - 1,
          ExtMarkOpts.from_tbl {
            end_row = lnum,
            end_col = m_end,
            hl_group = ui_opts.reference_text.hl_group,
            spell = false,
          }
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

---@param marks ExtMark[]
---@param lnum integer
---@param ui_opts obsidian.config.UIOpts
---@return ExtMark[]
local function get_line_highlight_extmarks(marks, line, lnum, ui_opts)
  local matches = search.find_highlight(line)
  for match in iter(matches) do
    local m_start, m_end = match[1], match[2]
    marks[#marks + 1] =
      ExtMark.new(nil, lnum, m_start - 1, ExtMarkOpts.from_tbl { end_row = lnum, end_col = m_start + 1, conceal = "" })
    marks[#marks + 1] = ExtMark.new(
      nil,
      lnum,
      m_start + 1,
      ExtMarkOpts.from_tbl {
        end_row = lnum,
        end_col = m_end - 2,
        hl_group = ui_opts.highlight_text.hl_group,
        spell = false,
      }
    )
    marks[#marks + 1] =
      ExtMark.new(nil, lnum, m_end - 2, ExtMarkOpts.from_tbl { end_row = lnum, end_col = m_end, conceal = "" })
  end
  return marks
end

---@param bufnr integer
---@param ns_id integer
---@param ui_opts obsidian.config.UIOpts
local function update_extmarks(bufnr, ns_id, ui_opts)
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
      get_line_check_extmarks(new_line_marks, line, lnum, ui_opts)
      get_line_ref_extmarks(new_line_marks, line, lnum, ui_opts, client)
      get_line_highlight_extmarks(new_line_marks, line, lnum, ui_opts)

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

---@param ui_opts obsidian.config.UIOpts
---@param bufnr integer|?
---@return boolean
local function should_update(ui_opts, bufnr)
  if ui_opts.enable == false then
    return false
  end
  bufnr = bufnr or 0
  local name = vim.api.nvim_buf_get_name(bufnr)
  local client = require("obsidian").get_client()
  if client and not client:path_is_note(name) then
    return false
  end
  if ui_opts.max_file_length and vim.fn.line "$" > ui_opts.max_file_length then
    return false
  end
  return true
end

---@param ui_opts obsidian.config.UIOpts
---@param throttle boolean
---@return function
local function get_extmarks_autocmd_callback(ui_opts, throttle)
  local ns_id = vim.api.nvim_create_namespace(NAMESPACE)
  local callback = function(ev)
    if should_update(ui_opts, ev.buf) then
      update_extmarks(ev.buf, ns_id, ui_opts)
    end
  end
  return throttle and require("obsidian.async").throttle(callback, ui_opts.update_debounce) or callback
end

---Manually update extmarks.
M.update = function(ui_opts, bufnr)
  bufnr = bufnr or 0
  if should_update(ui_opts, bufnr) then
    update_extmarks(bufnr, vim.api.nvim_create_namespace(NAMESPACE), ui_opts)
  end
end

---@param workspace obsidian.Workspace
---@param ui_opts obsidian.config.UIOpts
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
