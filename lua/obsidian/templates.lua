local Path = require "obsidian.path"
local Note = require "obsidian.note"
local util = require "obsidian.util"

local M = {}

--- Resolve a template name to a path.
---
---@param template_name string|obsidian.Path
---@param client obsidian.Client
---
---@return obsidian.Path
local resolve_template = function(template_name, client)
  local templates_dir = client:templates_dir()
  if templates_dir == nil then
    error "Templates folder is not defined or does not exist"
  end

  ---@type obsidian.Path|?
  local template_path
  local paths_to_check = { templates_dir / tostring(template_name), Path:new(template_name) }
  for _, path in ipairs(paths_to_check) do
    if path:is_file() then
      template_path = path
      break
    elseif not vim.endswith(tostring(path), ".md") then
      local path_with_suffix = Path:new(tostring(path) .. ".md")
      if path_with_suffix:is_file() then
        template_path = path_with_suffix
        break
      end
    end
  end

  if template_path == nil then
    error(string.format("Template '%s' not found", template_name))
  end

  return template_path
end

--- Resolve qual template usar baseado na pasta de destino (Mapeamento por Diretório)
---@param client obsidian.Client
---@param path obsidian.Path
---@return string|?
M.get_template_for_path = function(client, path)
  local rel_path = client:vault_relative_path(path)
  if not rel_path then
    return nil
  end

  local mappings = client.opts.templates.template_mappings or {}
  local rel_path_str = tostring(rel_path)

  -- Ordena as chaves por comprimento (maior primeiro) para garantir que pastas
  -- mais profundas tenham prioridade sobre pastas raiz.
  local keys = vim.tbl_keys(mappings)
  table.sort(keys, function(a, b)
    return #a > #b
  end)

  for _, dir in ipairs(keys) do
    -- Remove leading slash para comparação
    local clean_dir = dir:gsub("^/", "")
    local clean_rel = rel_path_str:gsub("^/", "")

    if clean_rel == clean_dir or vim.startswith(clean_rel, clean_dir .. "/") then
      return mappings[dir]
    end
  end
  return nil
end

--- Substitute variables inside the given text (Enhanced with Templater support).
---
---@param text string
---@param client obsidian.Client
---@param note obsidian.Note
---
---@return string
M.substitute_template_variables = function(text, client, note)
  local methods = vim.deepcopy(client.opts.templates.substitutions or {})
  local title = note.title or note:display_name()

  -- 1. Definições de Variáveis Padrão
  if not methods["date"] then
    methods["date"] = function()
      local date_format = client.opts.templates.date_format or "%Y-%m-%d"
      return tostring(os.date(date_format))
    end
  end

  if not methods["time"] then
    methods["time"] = function()
      local time_format = client.opts.templates.time_format or "%H:%M"
      return tostring(os.date(time_format))
    end
  end

  if not methods["title"] then
    methods["title"] = title
  end

  if not methods["id"] then
    methods["id"] = tostring(note.id)
  end

  if not methods["path"] and note.path then
    methods["path"] = tostring(note.path)
  end

  -- 2. Processamento de Variáveis Estilo Obsidian {{variable}}
  for key, subst in pairs(methods) do
    for m_start, m_end in util.gfind(text, "{{" .. key .. "}}", nil, true) do
      local value = type(subst) == "string" and subst or subst()
      methods[key] = value -- cache
      text = string.sub(text, 1, m_start - 1) .. value .. string.sub(text, m_end + 1)
    end
  end

  -- 3. COMPATIBILIDADE TEMPLATER: <% tp... %> (Baseado na sua lógica antiga)
  if client.opts.templates.templater_compat then
    local now = os.date
    local d = now "%Y-%m-%d"
    local t = now "%H:%M"

    -- Mapeamento de padrões específicos do Templater
    local patterns = {
      { '<%% tp%.date%.now%("YYYY%-MM%-DD HH:mm"%) %%>', d .. " " .. t },
      { '<%% tp%.date%.now%("YYYY%-MM%-DDTHH:mm"%) %%>', d .. "T" .. t },
      { '<%% tp%.date%.now%("YYYY%-MM%-DD"%) %%>', d },
      { "<%% tp%.date%.now%(%) %%>", d },
      { "<%% tp%.file%.title %%>", title },
    }

    for _, pat in ipairs(patterns) do
      text = text:gsub(pat[1], pat[2])
    end

    -- Suporte genérico para <% tp.date.now("formato") %>
    text = text:gsub('<%% tp%.date%.now%("(.-)"%) %%>', function(fmt)
      local lua_fmt = fmt
        :gsub("YYYY", "%%Y")
        :gsub("MM", "%%m")
        :gsub("DD", "%%d")
        :gsub("HH", "%%H")
        :gsub("mm", "%%M")
        :gsub("ss", "%%S")
      return os.date(lua_fmt)
    end)
  end

  -- 4. Prompt para variáveis desconhecidas {{prompt}}
  for m_start, m_end in util.gfind(text, "{{[^}]+}}") do
    local key = util.strip_whitespace(string.sub(text, m_start + 2, m_end - 2))
    local value = util.input(string.format("Enter value for '%s' (<cr> to skip): ", key))
    if value and string.len(value) > 0 then
      text = string.sub(text, 1, m_start - 1) .. value .. string.sub(text, m_end + 1)
    end
  end

  return text
end

--- Clone template to a new note.
---
---@param opts { template_name: string|obsidian.Path|?, path: obsidian.Path|string, client: obsidian.Client, note: obsidian.Note } Options.
---
---@return obsidian.Note
M.clone_template = function(opts)
  local note_path = Path.new(opts.path)
  assert(note_path:parent()):mkdir { parents = true, exist_ok = true }

  -- INVERSÃO DE CONTROLE: Se não houver template definido, tenta o mapeamento por pasta
  local template_name = opts.template_name
  if template_name == nil or template_name == "" then
    template_name = M.get_template_for_path(opts.client, note_path)
  end

  -- Se ainda assim não houver template, cria um arquivo com frontmatter básico (Fallback)
  if template_name == nil or template_name == "" then
    local note_file = io.open(tostring(note_path), "w")
    if note_file then
      local title = opts.note.title or note_path.stem
      local header =
        string.format("---\ntitle: %s\ndate: %s %s\n---\n\n# %s\n", title, os.date "%Y-%m-%d", os.date "%H:%M", title)
      note_file:write(header)
      note_file:close()
    end
    return Note.from_file(note_path)
  end

  -- Fluxo normal de template
  local template_path = resolve_template(template_name, opts.client)

  local template_file, read_err = io.open(tostring(template_path), "r")
  if not template_file then
    error(string.format("Unable to read template at '%s': %s", template_path, tostring(read_err)))
  end

  local note_file, write_err = io.open(tostring(note_path), "w")
  if not note_file then
    error(string.format("Unable to write note at '%s': %s", note_path, tostring(write_err)))
  end

  for line in template_file:lines "L" do
    line = M.substitute_template_variables(line, opts.client, opts.note)
    note_file:write(line)
  end

  assert(template_file:close())
  assert(note_file:close())

  local new_note = Note.from_file(note_path)

  -- Transfer fields from `opts.note`.
  new_note.id = opts.note.id
  if new_note.title == nil then
    new_note.title = opts.note.title
  end
  for _, alias in ipairs(opts.note.aliases) do
    new_note:add_alias(alias)
  end
  for _, tag in ipairs(opts.note.tags) do
    new_note:add_tag(tag)
  end

  return new_note
end

---Insert a template at the given location.
---
---@param opts { template_name: string|obsidian.Path, client: obsidian.Client, location: { [1]: integer, [2]: integer, [3]: integer, [4]: integer } } Options.
---
---@return obsidian.Note
M.insert_template = function(opts)
  local buf, win, row, _ = unpack(opts.location)
  local note = Note.from_buffer(buf)

  local template_path = resolve_template(opts.template_name, opts.client)

  local insert_lines = {}
  local template_file = io.open(tostring(template_path), "r")
  if template_file then
    local lines = template_file:lines()
    for line in lines do
      local new_lines = M.substitute_template_variables(line, opts.client, note)
      if string.find(new_lines, "[\r\n]") then
        local line_start = 1
        for line_end in util.gfind(new_lines, "[\r\n]") do
          local new_line = string.sub(new_lines, line_start, line_end - 1)
          table.insert(insert_lines, new_line)
          line_start = line_end + 1
        end
        local last_line = string.sub(new_lines, line_start)
        if string.len(last_line) > 0 then
          table.insert(insert_lines, last_line)
        end
      else
        table.insert(insert_lines, new_lines)
      end
    end
    template_file:close()
  else
    error(string.format("Template file '%s' not found", template_path))
  end

  vim.api.nvim_buf_set_lines(buf, row - 1, row - 1, false, insert_lines)
  local new_cursor_row, _ = unpack(vim.api.nvim_win_get_cursor(win))
  vim.api.nvim_win_set_cursor(0, { new_cursor_row, 0 })

  opts.client:update_ui(0)

  return Note.from_buffer(buf)
end

return M
