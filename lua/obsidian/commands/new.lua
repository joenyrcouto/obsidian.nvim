local util = require "obsidian.util"
local log = require "obsidian.log"

---@param client obsidian.Client
return function(client, data)
  local function create_note(title, dir)
    -- Se o título contiver uma extensão permitida, o client.lua já trata.
    -- Caso contrário, o client:create_note usará o fallback .md que configuramos.
    local note = client:create_note {
      title = title,
      dir = dir,
      -- O motor de templates que refatoramos no templates.lua
      -- será chamado automaticamente dentro de create_note -> write_note
    }
    client:open_note(note)
  end

  -- Se o usuário passou um argumento (ex: :ObsidianNew MinhaNota)
  if data.args and string.len(data.args) > 0 then
    create_note(data.args)
  else
    -- Fluxo Interativo: Escolher Pasta -> Nome
    local picker = client:picker()
    if not picker then
      -- Fallback se não houver picker (Telescope/FZF) configurado
      vim.ui.input({ prompt = "Note title: " }, function(title)
        if title then
          create_note(title)
        end
      end)
      return
    end

    picker:pick_directory(function(selected_dir)
      vim.schedule(function()
        vim.ui.input({ prompt = "Note title: " }, function(title)
          if title and string.len(title) > 0 then
            create_note(title, selected_dir)
          end
        end)
      end)
    end)
  end
end
