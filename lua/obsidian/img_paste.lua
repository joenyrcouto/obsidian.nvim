local Path = require "obsidian.path"
local util = require "obsidian.util"
local log = require "obsidian.log"
local run_job = require("obsidian.async").run_job

local M = {}

---@return string
local function get_clip_check_command()
  local check_cmd
  local this_os = util.get_os()
  if this_os == util.OSType.Linux or this_os == util.OSType.FreeBSD then
    local display_server = os.getenv "XDG_SESSION_TYPE"
    if display_server == "x11" or display_server == "tty" then
      check_cmd = "xclip -selection clipboard -o -t TARGETS"
    elseif display_server == "wayland" then
      check_cmd = "wl-paste --list-types"
    end
  elseif this_os == util.OSType.Darwin then
    check_cmd = "pngpaste -b 2>&1"
  elseif this_os == util.OSType.Windows or this_os == util.OSType.Wsl then
    check_cmd = 'powershell.exe "Get-Clipboard -Format Image"'
  else
    error("image saving not implemented for OS '" .. this_os .. "'")
  end
  return check_cmd
end

--- Check if clipboard contains image data.
---@return boolean
local function clipboard_is_img()
  local check_cmd = get_clip_check_command()
  if not check_cmd then
    return false
  end

  local handle = io.popen(check_cmd)
  if not handle then
    return false
  end

  local content = {}
  for output in handle:lines() do
    content[#content + 1] = output
  end
  handle:close()

  local this_os = util.get_os()
  if this_os == util.OSType.Linux or this_os == util.OSType.FreeBSD then
    return vim.tbl_contains(content, "image/png")
  elseif this_os == util.OSType.Darwin then
    -- Magic number para PNG em base64
    return content[1] and string.sub(content[1], 1, 9) == "iVBORw0KG"
  elseif this_os == util.OSType.Windows or this_os == util.OSType.Wsl then
    return #content > 0
  end
  return false
end

--- Save image from clipboard to `path`.
---@param path string
---@return boolean|integer|? result
local function save_clipboard_image(path)
  local this_os = util.get_os()
  local escaped_path = vim.fn.shellescape(path)

  if this_os == util.OSType.Linux or this_os == util.OSType.FreeBSD then
    local cmd
    local display_server = os.getenv "XDG_SESSION_TYPE"
    if display_server == "wayland" then
      cmd = string.format("wl-paste --no-newline --type image/png > %s", escaped_path)
    else
      cmd = string.format("xclip -selection clipboard -t image/png -o > %s", escaped_path)
    end
    return os.execute(cmd) == 0
  elseif this_os == util.OSType.Windows or this_os == util.OSType.Wsl then
    local win_path = string.gsub(path, "/", "\\")
    local cmd = string.format("powershell.exe -c \"(get-clipboard -format image).save('%s', 'png')\"", win_path)
    return os.execute(cmd) == 0
  elseif this_os == util.OSType.Darwin then
    return run_job("pngpaste", { path })
  end
  return false
end

---@param opts { fname: string|?, default_dir: obsidian.Path|string|?, default_name: string|?, should_confirm: boolean|? }|? Options.
---@return obsidian.Path|? image_path The absolute path to the image file.
M.paste_img = function(opts)
  opts = opts or {}

  if not clipboard_is_img() then
    log.err "A área de transferência não contém uma imagem válida."
    return
  end

  local fname = opts.fname and util.strip_whitespace(opts.fname) or nil

  -- 1. Determina o nome do arquivo
  if fname == nil or fname == "" then
    if opts.default_name ~= nil and not opts.should_confirm then
      fname = opts.default_name
    else
      fname = util.input("Nome do arquivo: ", { default = opts.default_name or "imagem", completion = "file" })
      if not fname or fname == "" then
        log.warn "Colagem cancelada."
        return
      end
    end
  end

  -- 2. Garante a extensão .png
  local path = Path.new(fname)
  if path.suffix ~= ".png" then
    path = path:with_suffix ".png"
  end

  -- 3. Resolve o caminho final (Inversão de Controle)
  -- Se o usuário digitou um caminho absoluto, usa ele.
  -- Caso contrário, usa o default_dir configurado no setup.
  if not path:is_absolute() then
    if opts.default_dir ~= nil then
      path = (Path.new(opts.default_dir) / path):resolve()
    else
      log.err "Diretório de destino não configurado."
      return
    end
  end

  -- 4. Confirmação opcional
  if opts.should_confirm then
    if not util.confirm("Salvar imagem em '" .. tostring(path) .. "'?") then
      log.warn "Colagem cancelada."
      return
    end
  end

  -- 5. Cria a pasta se não existir e salva
  assert(path:parent()):mkdir { exist_ok = true, parents = true }

  if save_clipboard_image(tostring(path)) then
    return path
  else
    log.err "Erro ao salvar a imagem no disco."
    return nil
  end
end

return M
