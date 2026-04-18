local abc = require "obsidian.abc"
local log = require "obsidian.log"
local util = require "obsidian.util"
local strings = require "plenary.strings"
local Note = require "obsidian.note"

---@class obsidian.Picker : obsidian.ABC
---
---@field client obsidian.Client
---@field calling_bufnr integer
local Picker = abc.new_class()

Picker.new = function(client)
  local self = Picker.init()
  self.client = client
  self.calling_bufnr = vim.api.nvim_get_current_buf()
  return self
end

-------------------------------------------------------------------
--- Abstract methods that need to be implemented by subclasses. ---
-------------------------------------------------------------------

---@class obsidian.PickerMappingOpts
---
---@field desc string
---@field callback fun(...)
---@field fallback_to_query boolean|?
---@field keep_open boolean|?
---@field allow_multiple boolean|?

---@alias obsidian.PickerMappingTable table<string, obsidian.PickerMappingOpts>

---@class obsidian.PickerFindOpts
---
---@field prompt_title string|?
---@field dir string|obsidian.Path|?
---@field callback fun(path: string)|?
---@field no_default_mappings boolean|?
---@field query_mappings obsidian.PickerMappingTable|?
---@field selection_mappings obsidian.PickerMappingTable|?

--- Find files in a directory.
---@diagnostic disable-next-line: unused-local
Picker.find_files = function(self, opts)
  error "not implemented"
end

---@class obsidian.PickerGrepOpts
---
---@field prompt_title string|?
---@field dir string|obsidian.Path|?
---@field query string|?
---@field callback fun(path: string)|?
---@field no_default_mappings boolean|?
---@field query_mappings obsidian.PickerMappingTable
---@field selection_mappings obsidian.PickerMappingTable

--- Grep for a string.
---@diagnostic disable-next-line: unused-local
Picker.grep = function(self, opts)
  error "not implemented"
end

---@class obsidian.PickerEntry
---
---@field value any
---@field ordinal string|?
---@field display string|?
---@field filename string|?
---@field valid boolean|?
---@field lnum integer|?
---@field col integer|?
---@field icon string|?
---@field icon_hl string|?

---@class obsidian.PickerPickOpts
---
---@field prompt_title string|?
---@field callback fun(value: any, ...: any)|?
---@field allow_multiple boolean|?
---@field query_mappings obsidian.PickerMappingTable|?
---@field selection_mappings obsidian.PickerMappingTable|?

--- Pick from a list of items.
---@diagnostic disable-next-line: unused-local
Picker.pick = function(self, values, opts)
  error "not implemented"
end

--- Pick a directory from the vault.
---@param callback fun(dir: string)
Picker.pick_directory = function(self, callback)
  local directories = self.client:get_vault_directories()
  local entries = {}
  for _, dir in ipairs(directories) do
    table.insert(entries, {
      display = dir == "" and "/" or dir,
      value = dir,
    })
  end

  self:pick(entries, {
    prompt_title = "Select Directory",
    callback = function(entry)
      callback(entry)
    end,
  })
end

--------------------------------
--- Concrete helper methods. ---
--------------------------------

local function key_is_set(key)
  return key ~= nil and string.len(key) > 0
end

--- Get query mappings to use for `find_notes()` or `grep_notes()`.
---@return obsidian.PickerMappingTable
Picker._note_query_mappings = function(self)
  local mappings = {}
  if self.client.opts.picker.note_mappings and key_is_set(self.client.opts.picker.note_mappings.new) then
    mappings[self.client.opts.picker.note_mappings.new] = {
      desc = "new",
      callback = function(query)
        self.client:command("ObsidianNew", { args = query })
      end,
    }
  end
  return mappings
end

--- Get selection mappings to use for `find_notes()` or `grep_notes()`.
---@return obsidian.PickerMappingTable
Picker._note_selection_mappings = function(self)
  local mappings = {}
  if self.client.opts.picker.note_mappings and key_is_set(self.client.opts.picker.note_mappings.insert_link) then
    mappings[self.client.opts.picker.note_mappings.insert_link] = {
      desc = "insert link",
      callback = function(note_or_path)
        local note = Note.is_note_obj(note_or_path) and note_or_path or Note.from_file(note_or_path)
        -- Usa o format_link refatorado para respeitar extensões
        local link = self.client:format_link(note, {})
        vim.api.nvim_put({ link }, "c", true, true)
        self.client:update_ui()
      end,
    }
  end
  return mappings
end

--- Get selection mappings to use for `pick_tag()`.
---@return obsidian.PickerMappingTable
Picker._tag_selection_mappings = function(self)
  local mappings = {}
  if self.client.opts.picker.tag_mappings then
    if key_is_set(self.client.opts.picker.tag_mappings.tag_note) then
      mappings[self.client.opts.picker.tag_mappings.tag_note] = {
        desc = "tag note",
        callback = function(...)
          local tags = { ... }
          local note = self.client:current_note(self.calling_bufnr)
          if not note then
            log.warn("'%s' is not a note in your workspace", vim.api.nvim_buf_get_name(self.calling_bufnr))
            return
          end
          local tags_added = {}
          for _, tag in ipairs(tags) do
            if note:add_tag(tag) then
              table.insert(tags_added, tag)
            end
          end
          if #tags_added > 0 then
            self.client:update_frontmatter(note, self.calling_bufnr)
            log.info("Added tags %s", tags_added)
          end
        end,
        fallback_to_query = true,
        keep_open = true,
        allow_multiple = true,
      }
    end
    if key_is_set(self.client.opts.picker.tag_mappings.insert_tag) then
      mappings[self.client.opts.picker.tag_mappings.insert_tag] = {
        desc = "insert tag",
        callback = function(tag)
          vim.api.nvim_put({ "#" .. tag }, "c", true, true)
        end,
        fallback_to_query = true,
      }
    end
  end
  return mappings
end

------------------------------------------------------------------
--- Concrete methods with a default implementation subclasses. ---
------------------------------------------------------------------

Picker.find_notes = function(self, opts)
  self.calling_bufnr = vim.api.nvim_get_current_buf()
  opts = opts or {}
  local query_mappings = not opts.no_default_mappings and self:_note_query_mappings() or nil
  local selection_mappings = not opts.no_default_mappings and self:_note_selection_mappings() or nil

  return self:find_files {
    prompt_title = opts.prompt_title or "Notes",
    dir = self.client.dir,
    callback = opts.callback,
    no_default_mappings = opts.no_default_mappings,
    query_mappings = query_mappings,
    selection_mappings = selection_mappings,
  }
end

Picker.find_templates = function(self, opts)
  self.calling_bufnr = vim.api.nvim_get_current_buf()
  opts = opts or {}
  local templates_dir = self.client:templates_dir()
  if templates_dir == nil then
    log.err "Templates folder is not defined"
    return
  end
  return self:find_files {
    prompt_title = opts.prompt_title or "Templates",
    callback = opts.callback,
    dir = templates_dir,
    no_default_mappings = true,
  }
end

Picker.grep_notes = function(self, opts)
  self.calling_bufnr = vim.api.nvim_get_current_buf()
  opts = opts or {}
  local query_mappings = not opts.no_default_mappings and self:_note_query_mappings() or nil
  local selection_mappings = not opts.no_default_mappings and self:_note_selection_mappings() or nil

  self:grep {
    prompt_title = opts.prompt_title or "Grep notes",
    dir = self.client.dir,
    query = opts.query,
    callback = opts.callback,
    no_default_mappings = opts.no_default_mappings,
    query_mappings = query_mappings,
    selection_mappings = selection_mappings,
  }
end

Picker.pick_note = function(self, notes, opts)
  self.calling_bufnr = vim.api.nvim_get_current_buf()
  opts = opts or {}
  local query_mappings = not opts.no_default_mappings and self:_note_query_mappings() or nil
  local selection_mappings = not opts.no_default_mappings and self:_note_selection_mappings() or nil

  local entries = {}
  for _, note in ipairs(notes) do
    local rel_path = tostring(assert(self.client:vault_relative_path(note.path, { strict = true })))
    local display_name = note:display_name()
    entries[#entries + 1] = {
      value = note,
      display = display_name,
      -- Ordinal inclui o caminho para permitir busca por extensão (.base, .qmd)
      ordinal = rel_path .. " " .. display_name,
      filename = tostring(note.path),
    }
  end

  self:pick(entries, {
    prompt_title = opts.prompt_title or "Notes",
    callback = opts.callback,
    allow_multiple = opts.allow_multiple,
    no_default_mappings = opts.no_default_mappings,
    query_mappings = query_mappings,
    selection_mappings = selection_mappings,
  })
end

Picker.pick_tag = function(self, tags, opts)
  self.calling_bufnr = vim.api.nvim_get_current_buf()
  opts = opts or {}
  local selection_mappings = not opts.no_default_mappings and self:_tag_selection_mappings() or nil
  self:pick(tags, {
    prompt_title = opts.prompt_title or "Tags",
    callback = opts.callback,
    allow_multiple = opts.allow_multiple,
    no_default_mappings = opts.no_default_mappings,
    selection_mappings = selection_mappings,
  })
end

--------------------------------
--- UI and Command Builders. ---
--------------------------------

Picker._build_prompt = function(self, opts)
  opts = opts or {}
  local prompt = opts.prompt_title or "Find"
  if string.len(prompt) > 50 then
    prompt = string.sub(prompt, 1, 50) .. "…"
  end
  prompt = prompt .. " | <CR> confirm"

  local function add_mappings(mappings)
    if mappings then
      local keys = vim.tbl_keys(mappings)
      table.sort(keys)
      for _, key in ipairs(keys) do
        prompt = prompt .. " | " .. key .. " " .. mappings[key].desc
      end
    end
  end

  add_mappings(opts.query_mappings)
  add_mappings(opts.selection_mappings)
  return prompt
end

Picker._make_display = function(self, entry)
  local display = ""
  local highlights = {}
  if entry.filename ~= nil then
    local icon, icon_hl = util.get_icon(entry.filename)
    if icon ~= nil then
      display = display .. icon .. " "
      if icon_hl ~= nil then
        highlights[#highlights + 1] = { { 0, strings.strdisplaywidth(icon) }, icon_hl }
      end
    end
    display = display .. tostring(self.client:vault_relative_path(entry.filename, { strict = true }))
    if entry.lnum ~= nil then
      display = display .. ":" .. entry.lnum
      if entry.col ~= nil then
        display = display .. ":" .. entry.col
      end
    end
    if entry.display ~= nil then
      display = display .. ":" .. entry.display
    end
  elseif entry.display ~= nil then
    display = (entry.icon and entry.icon .. " " or "") .. entry.display
  else
    display = (entry.icon and entry.icon .. " " or "") .. tostring(entry.value)
  end
  return assert(display), highlights
end

Picker._build_find_cmd = function(self)
  local search = require "obsidian.search"
  local search_opts = search.SearchOpts.from_tbl {
    sort_by = self.client.opts.sort_by,
    sort_reversed = self.client.opts.sort_reversed,
    allowed_extensions = self.client.opts.allowed_extensions, -- Respeita extensões do usuário
  }
  return search.build_find_cmd(".", nil, search_opts)
end

Picker._build_grep_cmd = function(self)
  local search = require "obsidian.search"
  local search_opts = search.SearchOpts.from_tbl {
    sort_by = self.client.opts.sort_by,
    sort_reversed = self.client.opts.sort_reversed,
    smart_case = true,
    fixed_strings = true,
  }
  return search.build_grep_cmd(search_opts)
end

return Picker
