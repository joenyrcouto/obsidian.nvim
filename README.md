# obsidian.nvim (Enhanced Fork)

<div align="center">
<h1 align="center">obsidian.nvim</h1>
<div><h4 align="center"><a href="#setup">Setup</a> · <a href="#configuration-options">Configure</a> · <a href="#new-features-in-this-fork">New Features</a> · <a href="https://github.com/joenyrcouto/obsidian.nvim/discussions">Discuss</a></h4></div>
</div>

Este é um fork aprimorado do `obsidian.nvim`, focado em expandir as capacidades do plugin original para fluxos de trabalho profissionais, suporte a múltiplos formatos de arquivo e automação inteligente de templates.

## New Features (In this Fork)

🚀 **Suporte Multi-Extensão:** O plugin não está mais limitado a `.md`. Agora você pode gerenciar arquivos `.qmd`, `.base`, `.txt`, `.excalidraw` e outros como notas de primeira classe.
🎨 **Validação Visual de Links:** Links para arquivos que não existem no seu vault são destacados automaticamente com colchetes laranjas e texto em destaque de erro.
📂 **Mapeamento de Templates por Pasta:** Defina qual template deve ser aplicado automaticamente com base na pasta onde a nota está sendo criada.
📅 **Compatibilidade com Templater:** Suporte nativo para sintaxe do plugin Templater (ex: `<% tp.date.now() %>` e `<% tp.file.title %>`), traduzidos dinamicamente no Neovim.
🖼️ **Gestão de Anexos Pro:** Configuração flexível de pastas de imagens e suporte a links no formato WikiLink (`![[imagem.png]]`).
🔍 **Busca Inteligente:** O motor de busca (Ripgrep) agora filtra automaticamente apenas as extensões permitidas, evitando travamentos em arquivos binários.

---

## Features

▶️ **Completion:** Autocompletar ultra-rápido para referências e tags via [nvim-cmp](https://github.com/hrsh7th/nvim-cmp).
🏃 **Navigation:** Navegue pelo vault usando `gf` ou `<CR>` em qualquer link.
📷 **Images:** Cole imagens diretamente da área de transferência para o seu vault.
💅 **Syntax:** Destaque adicional para checkboxes, tags e agora **validação de links quebrados**.

### Commands

- `:ObsidianNew [TITLE]` - Cria uma nova nota. Se executado sem argumentos, abre um seletor interativo de pastas do seu vault antes de solicitar o nome.
- `:ObsidianQuickSwitch` - Alterna rapidamente entre notas, agora suportando todas as extensões configuradas (ex: `.base`, `.qmd`).
- `:ObsidianPasteImg [IMGNAME]` - Salva imagem do clipboard na sua pasta de anexos configurada e insere o link formatado.
- `:ObsidianTemplate [NAME]` - Insere um template manualmente.
- `:ObsidianToday / :ObsidianYesterday` - Cria/abre notas diárias na sua pasta de tracking com templates automáticos.
- `:ObsidianSearch [QUERY]` - Pesquisa global no vault respeitando os filtros de extensão.

---

## Setup

### Configuration options

Abaixo estão as novas opções de configuração disponíveis neste fork. Adicione-as ao seu `setup`:

```lua
require("obsidian").setup({
  workspaces = {
    {
      name = "brain",
      path = "~/documents/brain",
    },
  },

  -- 1. GESTÃO DE EXTENSÕES
  -- Extensões que o plugin pode ler e validar nos links
  allowed_extensions = { ".md", ".qmd", ".base", ".excalidraw", ".txt" },
  -- Extensões que o plugin tem permissão para criar/editar
  writable_extensions = { ".md", ".qmd", ".base", ".txt" },

  -- 2. MOTOR DE TEMPLATES APRIMORADO
  templates = {
    folder = "99-brutos/templates",
    date_format = "%Y-%m-%d",
    time_format = "%H:%M",
    
    -- MAPEAMENTO AUTOMÁTICO: Pasta -> Template
    template_mappings = {
      ['02-zettel'] = 'zettel-tlp.md',
      ['01-notelm'] = 'notelm-tlp.md',
      ['99-brutos/tracking'] = 'daily-tlp.md',
    },
    
    -- Ativa suporte a sintaxe <% tp.date.now() %>
    templater_compat = true,
  },

  -- 3. ANEXOS E IMAGENS
  attachments = {
    img_folder = "99-brutos/anexos", -- Pasta customizada
    -- Formata o link como ![[imagem.png]] (Padrão Obsidian)
    img_text_func = function(client, path)
      local name = vim.fs.basename(tostring(path))
      return string.format("![[%s]]", name)
    end,
  },

  -- 4. INTERFACE VISUAL (Validação de Links)
  ui = {
    enable = true,          -- Necessário para o destaque de links quebrados
    update_debounce = 200,
    max_file_length = 5000,
    hl_groups = {
      ObsidianOrange = { bold = true, fg = "#f78c6c" }, -- Cor dos colchetes de erro
      ObsidianError = { fg = "#ff5370", bold = true, undercurl = true }, -- Texto do link quebrado
    },
  },

  -- Outras opções originais...
  preferred_link_style = "wiki",
  disable_frontmatter = false,
})
```

---

## Notes on configuration

### Interactive Note Creation
Ao rodar `:ObsidianNew` sem argumentos, o plugin agora utiliza o seu Picker (Telescope/FZF) para listar todas as pastas do seu vault. Após selecionar a pasta, você digita o nome da nota. O plugin aplicará automaticamente o template correto baseado no `template_mappings`.

### Multi-format Links
Para manter a compatibilidade com o Obsidian App:
- Links para arquivos `.md` continuam sendo `[[Nome da Nota]]`.
- Links para outros formatos (ex: `.base`) são gerados automaticamente com a extensão: `[[books.base]]`.

### Templater Syntax
Este fork traduz os seguintes padrões do Templater durante a criação de arquivos:
- `<% tp.date.now("YYYY-MM-DD") %>` -> Data atual formatada.
- `<% tp.file.title %>` -> Título da nota.
- `{{date}}`, `{{time}}`, `{{title}}` -> Variáveis padrão do Obsidian.

### Broken Link Highlighting
O validador de links verifica em tempo real se o arquivo referenciado em um `[[link]]` existe no disco. Ele busca por:
1. O nome exato com extensão (se fornecida).
2. O nome + `.md` (comportamento padrão).
3. O nome + qualquer extensão na sua lista de `allowed_extensions`.

---

## Setup Requirements

- **Neovim >= 0.8.0**
- **Ripgrep (rg)** instalado no sistema.
- **Pickers:** [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) ou [fzf-lua](https://github.com/ibhagwan/fzf-lua).
- **Dependências de Imagem:** `xclip` (Linux X11), `wl-clipboard` (Wayland) ou `pngpaste` (MacOS).

## Contributing

Sinta-se à vontade para abrir Issues ou Pull Requests para melhorias neste fork.
