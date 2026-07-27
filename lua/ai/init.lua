local M = {}

local Config = require("ai.config")
local ai = require("ai.ai")
local Session = require("ai.session")

M.config = Config.resolve()

---Configures the plugin and its default keymap.
function M.setup(opts)
    M.config = Config.resolve(opts)
    ai.setup(Config.backend(M.config))
    M.config.chat = Session.setup(M.config.chat)

    vim.keymap.set("n", "<leader>ai", "<Cmd>AI<CR>", {
        desc = "open ai dialog box",
        silent = true,
    })
    vim.keymap.set("x", "<leader>ai", "<Cmd>AISelection<CR>", {
        desc = "open ai dialog box with selection",
        silent = true,
    })
end

return M
