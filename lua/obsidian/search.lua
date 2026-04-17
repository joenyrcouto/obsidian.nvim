local Deque = require("plenary.async.structs").Deque
local scan = require "plenary.scandir"

local Path = require "obsidian.path"
local abc = require "obsidian.abc"
local util = require "obsidian.util"
local iter = require("obsidian.itertools").iter
local run_job_async = require("obsidian.async").run_job_async
local compat = require "obsidian.compat"

local M = {}

-- Comandos base limpos (sem --type=md fixo)
M._BASE_CMD = { "rg", "--no-config" }
M._SEARCH_CMD = compat.flatten { M._BASE_CMD, "--json" }
M._FIND_CMD = compat.flatten { M._BASE_CMD, "--files" }

---@enum obsidian.search.RefTypes
M.RefTypes = {
  WikiWithAlias = "WikiWithAlias",
  Wiki = "Wiki",
  Markdown = "Markdown",
  NakedUrl = "NakedUrl",
  FileUrl = "FileUrl",
  MailtoUrl = "MailtoUrl",
  Tag = "Tag",
  BlockID = "BlockID",
  Highlight = "Highlight",
}

---@enum obsidian.search.Patterns
M.Patterns = {
  TagCharsOptional = "[A-Za-z0-9_/-]*",
  TagCharsRequired = "[A-Za-z]+[A-Za-z0-9_/-]*[A-Za-z0-9]+",
  Tag = "#[A-Za-z]+[A-Za-z0-9_/-]*[A-Za-z0-9]+",
  Highlight = "==[^=]+==",
  WikiWithAlias = "%[%[[^][%|]+%|[^%]]+%]%]",
  Wiki = "%[%[[^][%|]+%]%]",
  Markdown = "%[[^][]+%]%([^%)]+%)",
  NakedUrl = "https?://[a-zA-Z0-9._-]+[a-zA-Z0-9._#/=&?:+%%-]+[a-zA-Z0-9/]",
  FileUrl = "file:/[/{2}]?.*",
  MailtoUrl = "mailto:.*",
  BlockID = util.BLOCK_PATTERN .. "$",
}

M.PatternConfig = {
  [M.RefTypes.Tag] = { ignore_if_escape_prefix = true },
}

M.find_matches = function(s, pattern_names)
  local inline_code_blocks = {}
  for m_start, m_end in util.gfind(s, "`[^`]*`") do
    inline_code_blocks[#inline_code_blocks + 1] = { m_start, m_end }
  end

  local matches = {}
  for pattern_name in iter(pattern_names) do
    local pattern = M.Patterns[pattern_name]
    local pattern_cfg = M.PatternConfig[pattern_name]
    local search_start = 1
    while search_start < #s do
      local m_start, m_end = string.find(s, pattern, search_start)
      if m_start ~= nil and m_end ~= nil then
        local inside_code_block = false
        for code_block_boundary in iter(inline_code_blocks) do
          if code_block_boundary[1] < m_start and m_end < code_block_boundary[2] then
            inside_code_block = true
            break
          end
        end

        if not inside_code_block then
          local overlap = false
          for match in iter(matches) do
            if (match[1] <= m_start and m_start <= match[2]) or (match[1] <= m_end and m_end <= match[2]) then
              overlap = true
              break
            end
          end

          local skip_due_to_escape = false
          if
            pattern_cfg
            and pattern_cfg.ignore_if_escape_prefix
            and string.sub(s, m_start - 1, m_start - 1) == [[\]]
          then
            skip_due_to_escape = true
          end

          if not overlap and not skip_due_to_escape then
            matches[#matches + 1] = { m_start, m_end, pattern_name }
          end
        end
        search_start = m_end
      else
        break
      end
    end
  end
  table.sort(matches, function(a, b)
    return a[1] < b[1]
  end)
  return matches
end

M.find_highlight = function(s)
  local matches = {}
  for match in iter(M.find_matches(s, { M.RefTypes.Highlight })) do
    local match_start, match_end, _ = unpack(match)
    local text = string.sub(s, match_start + 2, match_end - 2)
    if util.strip_whitespace(text) == text then
      matches[#matches + 1] = match
    end
  end
  return matches
end

M.find_refs = function(s, opts)
  opts = opts or {}
  local pattern_names = { M.RefTypes.WikiWithAlias, M.RefTypes.Wiki, M.RefTypes.Markdown }
  if opts.include_naked_urls then
    table.insert(pattern_names, M.RefTypes.NakedUrl)
  end
  if opts.include_tags then
    table.insert(pattern_names, M.RefTypes.Tag)
  end
  if opts.include_file_urls then
    table.insert(pattern_names, M.RefTypes.FileUrl)
  end
  if opts.include_block_ids then
    table.insert(pattern_names, M.RefTypes.BlockID)
  end
  return M.find_matches(s, pattern_names)
end

M.find_tags = function(s)
  local matches = {}
  for match in iter(M.find_refs(s, { include_naked_urls = true, include_tags = true })) do
    if match[3] == M.RefTypes.Tag then
      table.insert(matches, match)
    end
  end
  return matches
end

M.replace_refs = function(s)
  local out = string.gsub(s, "%[%[[^%|%]]+%|([^%]]+)%]%]", "%1")
  out = out:gsub("%[%[([^%]]+)%]%]", "%1")
  out = out:gsub("%[([^%]]+)%]%([^%)]+%)", "%1")
  return out
end

M.find_and_replace_refs = function(s)
  local pieces, refs, is_ref = {}, {}, {}
  local matches = M.find_refs(s)
  local last_end = 1
  for _, match in pairs(matches) do
    local m_start, m_end = match[1], match[2]
    if last_end < m_start then
      table.insert(pieces, string.sub(s, last_end, m_start - 1))
      table.insert(is_ref, false)
    end
    local ref_str = string.sub(s, m_start, m_end)
    table.insert(pieces, M.replace_refs(ref_str))
    table.insert(refs, ref_str)
    table.insert(is_ref, true)
    last_end = m_end + 1
  end
  local indices, length = {}, 0
  for i, piece in ipairs(pieces) do
    local i_end = length + string.len(piece)
    if is_ref[i] then
      table.insert(indices, { length + 1, i_end })
    end
    length = i_end
  end
  return table.concat(pieces, ""), indices, refs
end

M.find_code_blocks = function(lines)
  local blocks, start_idx = {}, nil
  for i, line in ipairs(lines) do
    if string.match(line, "^%s*```.*```%s*$") then
      table.insert(blocks, { i, i })
      start_idx = nil
    elseif string.match(line, "^%s*```") then
      if start_idx then
        table.insert(blocks, { start_idx, i })
        start_idx = nil
      else
        start_idx = i
      end
    end
  end
  return blocks
end

---@class obsidian.search.SearchOpts : obsidian.ABC
local SearchOpts = abc.new_class()
M.SearchOpts = SearchOpts

SearchOpts.from_tbl = function(opts)
  setmetatable(opts, SearchOpts.mt)
  return opts
end

SearchOpts.default = function()
  return SearchOpts.from_tbl {}
end

SearchOpts.merge = function(self, other)
  return SearchOpts.from_tbl(vim.tbl_extend("force", self:as_tbl(), SearchOpts.from_tbl(other):as_tbl()))
end

SearchOpts.add_exclude = function(self, path)
  if self.exclude == nil then
    self.exclude = {}
  end
  table.insert(self.exclude, path)
end

---@return string[]
SearchOpts.to_ripgrep_opts = function(self)
  local opts = {}
  if self.sort_by ~= nil then
    local sort = self.sort_reversed == false and "sort" or "sortr"
    table.insert(opts, "--" .. sort .. "=" .. self.sort_by)
  end

  -- Filtro de extensões permitidas para evitar ler arquivos binários
  if self.allowed_extensions then
    for _, ext in ipairs(self.allowed_extensions) do
      table.insert(opts, "-g")
      table.insert(opts, "*" .. ext)
    end
  end

  if self.fixed_strings then
    table.insert(opts, "--fixed-strings")
  end
  if self.ignore_case then
    table.insert(opts, "--ignore-case")
  end
  if self.smart_case then
    table.insert(opts, "--smart-case")
  end

  -- Exclusões de segurança para evitar travamentos
  table.insert(opts, "-g")
  table.insert(opts, "!.git/*")

  if self.exclude then
    for path in iter(self.exclude) do
      table.insert(opts, "-g!" .. path)
    end
  end

  if self.max_count_per_file then
    table.insert(opts, "-m=" .. self.max_count_per_file)
  end
  return opts
end

--- Build the 'rg' command for searching content.
M.build_search_cmd = function(dir, term, opts)
  opts = SearchOpts.from_tbl(opts or {})
  local search_terms = {}
  if type(term) == "string" then
    search_terms = { "-e", term }
  else
    for t in iter(term) do
      table.insert(search_terms, "-e")
      table.insert(search_terms, t)
    end
  end
  local path = tostring(Path.new(dir):resolve { strict = true })
  if opts.escape_path then
    path = assert(vim.fn.fnameescape(path))
  end
  return compat.flatten { M._SEARCH_CMD, opts:to_ripgrep_opts(), search_terms, path }
end

--- Build the 'rg' command for finding files (Quick Switch).
M.build_find_cmd = function(path, term, opts)
  opts = SearchOpts.from_tbl(opts or {})
  local additional_opts = {}

  if term ~= nil and string.len(term) > 0 then
    if opts.include_non_markdown then
      table.insert(additional_opts, "-g")
      table.insert(additional_opts, "*" .. term .. "*")
    else
      -- Filtra o termo para cada extensão permitida
      local exts = opts.allowed_extensions or { ".md" }
      for _, ext in ipairs(exts) do
        table.insert(additional_opts, "-g")
        table.insert(additional_opts, "*" .. term .. "*" .. ext)
      end
    end
  end

  if opts.ignore_case then
    table.insert(additional_opts, "--glob-case-insensitive")
  end

  if path ~= nil and path ~= "." then
    local p = opts.escape_path and assert(vim.fn.fnameescape(tostring(path))) or tostring(path)
    table.insert(additional_opts, p)
  end

  return compat.flatten { M._FIND_CMD, opts:to_ripgrep_opts(), additional_opts }
end

M.build_grep_cmd = function(opts)
  opts = SearchOpts.from_tbl(opts or {})
  return compat.flatten {
    M._BASE_CMD,
    opts:to_ripgrep_opts(),
    "--column",
    "--line-number",
    "--no-heading",
    "--with-filename",
    "--color=never",
  }
end

M.search_async = function(dir, term, opts, on_match, on_exit)
  local cmd = M.build_search_cmd(dir, term, opts)
  run_job_async(cmd[1], { unpack(cmd, 2) }, function(line)
    local data = vim.json.decode(line)
    if data["type"] == "match" then
      on_match(data.data)
    end
  end, on_exit)
end

M.find_async = function(dir, term, opts, on_match, on_exit)
  local norm_dir = Path.new(dir):resolve { strict = true }
  local cmd = M.build_find_cmd(tostring(norm_dir), term, opts)
  run_job_async(cmd[1], { unpack(cmd, 2) }, on_match, on_exit)
end

M.find_notes_async = function(dir, note_file_name, callback)
  if not vim.endswith(note_file_name, ".md") then
    note_file_name = note_file_name .. ".md"
  end
  local notes = {}
  local root_dir = Path.new(dir):resolve { strict = true }
  local visit_dir = function(entry)
    local note_path = Path:new(entry) / note_file_name
    if note_path:is_file() then
      table.insert(notes, note_path)
    end
  end
  visit_dir(root_dir)
  scan.scan_dir_async(root_dir.filename, {
    hidden = false,
    add_dirs = false,
    only_dirs = true,
    respect_gitignore = true,
    on_insert = visit_dir,
    on_exit = function(_)
      callback(notes)
    end,
  })
end

return M
