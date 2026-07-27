local M = {}

---@class ai.PiOpts
---@field cmd? string[]
---@field binary? string
---@field extensions? boolean
---@field skills? boolean
---@field provider? string
---@field model? string
---@field thinking? string
---@field system_prompt? string
---@field append_system_prompt? string|string[]

---Adds a valued option when its value is present.
---@param command string[]
---@param flag string
---@param value? string
local function add_option(command, flag, value)
    if value ~= nil and value ~= "" then
        command[#command + 1] = flag
        command[#command + 1] = value
    end
end

---Builds the command used to launch the Pi RPC process.
---@param opts ai.PiOpts
---@return string[]
function M.build(opts)
    assert(type(opts) == "table", "Pi options are required")

    if opts.cmd then
        return vim.deepcopy(opts.cmd)
    end

    assert(
        type(opts.binary) == "string" and opts.binary ~= "",
        "Pi binary must be a non-empty string"
    )

    local command = {
        vim.fn.expand(opts.binary),
        "--mode",
        "rpc",
        "--no-session",
    }
    if not opts.extensions then
        command[#command + 1] = "--no-extensions"
    end
    if not opts.skills then
        command[#command + 1] = "--no-skills"
    end

    add_option(command, "--provider", opts.provider)
    add_option(command, "--model", opts.model)
    add_option(command, "--thinking", opts.thinking)
    add_option(command, "--system-prompt", opts.system_prompt)

    local prompts = opts.append_system_prompt
    if type(prompts) == "string" then
        prompts = { prompts }
    end
    for _, prompt in ipairs(prompts or {}) do
        add_option(command, "--append-system-prompt", prompt)
    end

    return command
end

return M
