local M = {}

local Config = require("ai.config")
local ai = require("ai.ai")
local Session = require("ai.session")

M.config = Config.resolve()

---Configures the plugin.
function M.setup(opts)
    M.config = Config.resolve(opts)
    ai.setup(Config.backend(M.config))
    M.config.chat = Session.setup(M.config.chat)
end

return M
