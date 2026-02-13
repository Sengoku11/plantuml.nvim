# plantuml.nvim

Lightweight Neovim plugin to render PlantUML as ASCII text, Unicode text, or image.

## Features

- Works with `.puml` files and with `.md` files (renders code block under cursor).
- Supported in any terminal: renders in ASCII and Unicode text (`utxt`).

## Requirements

- Neovim 0.11+
- `plantuml` command available in your PATH
  - On MacOS run `brew install plantuml`

## Installation

Via `lazy.nvim`:

```lua
{
  "Sengoku11/plantuml.nvim",
  keys = {
    { "<leader>pl", "<cmd>PlantumlRenderAscii<cr>", desc = "Render UML Ascii" },
    { "<leader>pu", "<cmd>PlantumlRenderUtxt<cr>", desc = "Render UML Unicode" },
    { "<leader>pi", "<cmd>PlantumlRenderImg<cr>", desc = "Render UML Image" },
  },
  opts = {},
}
```

## Configuration

```lua
-- Defaults
opts = {
  open = "fullscreen", -- right | bottom | fullscreen
  filetypes = { "puml" }, -- note that markdown will be supported anyways
  auto_wrap_markers = true, -- wraps block with @startuml/@enduml if missing
  auto_refresh_on_save = true, -- refresh open preview on write
  window = {
    right_width_pct = 0.0, -- ratio 0.0..1.0 (0.0 means no forced sizing)
    bottom_height_pct = 0.0, -- ratio 0.0..1.0 (0.0 means no forced sizing)
  },
}
```

## Commands

- `:PlantumlRenderAscii [right|bottom|fullscreen]`
- `:PlantumlRenderUtxt [right|bottom|fullscreen]`
- `:PlantumlRenderImg [right|bottom|fullscreen]`
