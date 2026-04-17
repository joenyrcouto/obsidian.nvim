-- required in which-key plugin spec in plugins/ui.lua as `require 'config.keymap'`
local wk = require "which-key"

P = vim.print

vim.g["quarto_is_r_mode"] = nil
vim.g["reticulate_running"] = false

-- Substitua os mapeamentos avulsos do Obsidian pela estrutura nativa do which-key:
wk.add {
  -- Mapeamentos Globais (Modo Normal)
  {
    mode = { "n" },
    { "<CR>", "<cmd>ObsidianFollowLink<cr>", desc = "Seguir Link" },
  },

  -- Grupo Obsidian (Modo Normal)
  {
    mode = { "n" },
    { "<leader>o", group = "[o]bsidian" },
    { "<leader>oa", "<cmd>ObsidianOpen<cr>", desc = "Abrir no App (Obsidian)" },
    { "<leader>ob", "<cmd>ObsidianBacklinks<cr>", desc = "Backlinks" },
    { "<leader>od", "<cmd>ObsidianDailies<cr>", desc = "Lista de Notas Diárias" },
    { "<leader>of", "<cmd>ObsidianQuickSwitch<cr>", desc = "Quick Switch (Telescope/FZF)" },
    { "<leader>og", "<cmd>ObsidianTags<cr>", desc = "Pesquisar Tags" },
    { "<leader>oi", "<cmd>ObsidianPasteImg<cr>", desc = "Colar Imagem da Área de Transferência" },
    { "<leader>on", "<cmd>ObsidianNew<cr>", desc = "Nova Nota (com Template)" },
    { "<leader>oo", "<cmd>Obsidian<cr>", desc = "Menu de Comandos Obsidian" },
    { "<leader>op", "<cmd>ObsidianTemplate<cr>", desc = "Inserir Template" },
    { "<leader>or", "<cmd>ObsidianRename<cr>", desc = "Renomear Nota e Atualizar Links" },
    { "<leader>os", "<cmd>ObsidianSearch<cr>", desc = "Pesquisar Texto no Vault (Grep)" },
    { "<leader>ot", "<cmd>ObsidianToday<cr>", desc = "Nota de Hoje" },
    { "<leader>ow", "<cmd>ObsidianWorkspace<cr>", desc = "Trocar Workspace" },
    { "<leader>oy", "<cmd>ObsidianYesterday<cr>", desc = "Nota de Ontem" },
    {
      "<leader>ov",
      function()
        -- Obtém o cliente para pegar o caminho do vault configurado dinamicamente
        local client = require("obsidian").get_client()
        if client then
          vim.cmd("cd " .. tostring(client.dir))
          vim.notify("Diretório alterado para o Vault: " .. tostring(client.dir), vim.log.levels.INFO)
        end
      end,
      desc = "Abrir Vault no Terminal (CD)",
    },
  },

  -- Grupo Obsidian (Modo Visual)
  {
    mode = { "v" },
    { "<leader>o", group = "[o]bsidian" },
    { "<leader>ol", ":ObsidianLink<cr>", desc = "Transformar seleção em Link" },
    { "<leader>ox", ":ObsidianExtractNote<cr>", desc = "Extrair seleção para nova nota" },
  },
}
