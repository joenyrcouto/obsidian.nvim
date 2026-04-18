local Path = require "obsidian.path"
local util = require "obsidian.util"
local log = require "obsidian.log"
local paste_img = require("obsidian.img_paste").paste_img

---@param client obsidian.Client
return function(client, data)
  -- 1. Resolve o diretório de imagens baseado na configuração do usuário
  local img_folder_name = client.opts.attachments.img_folder or "assets/imgs"
  local img_folder = Path.new(img_folder_name)

  -- Se o caminho for relativo, concatena com a raiz do vault
  if not img_folder:is_absolute() then
    img_folder = client.dir / img_folder_name
  end

  -- Garante que o diretório de destino exista (Inversão de Controle)
  img_folder:mkdir { parents = true, exists_ok = true }

  -- 2. Determina o nome padrão se houver uma função configurada
  ---@type string|?
  local default_name
  if client.opts.attachments.img_name_func then
    default_name = client.opts.attachments.img_name_func()
  end

  -- 3. Executa a lógica de colagem (chamando o módulo core do plugin)
  -- Passamos o diretório resolvido para que o arquivo seja salvo no lugar certo
  local path = paste_img {
    fname = (data.args and string.len(data.args) > 0) and data.args or nil,
    default_dir = img_folder,
    default_name = default_name,
    should_confirm = client.opts.attachments.confirm_img_paste,
  }

  -- 4. Insere o link formatado no buffer atual
  if path ~= nil then
    -- Chama a função de formatação de texto definida no setup do usuário
    local link_text = client.opts.attachments.img_text_func(client, path)
    util.insert_text(link_text)
    log.info("Imagem colada com sucesso em: " .. tostring(client:vault_relative_path(path) or path))
  end
end
