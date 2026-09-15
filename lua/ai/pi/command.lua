local M = {}
local Prompt = require("ai.prompt")

---@class ai.PiCommandOpts
---@field cmd? string[]
---@field binary? string
---@field extensions? boolean
---@field skills? boolean Enable Pi's skill discovery.
---@field skill_paths? string[] Local skill files or directories, loaded regardless of discovery.
---@field provider? string
---@field model? string
---@field thinking? string
---@field system_prompt? string
---@field append_system_prompt? string|string[] Text to append.
---@field append_system_prompt_filepath? string|string[] Readable local files to append after text.

---@class ai.PiOpts: ai.PiCommandOpts
---@field agent_spawn_dir string

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
---@param opts ai.PiCommandOpts
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
    if opts.skill_paths ~= nil then
        assert(
            type(opts.skill_paths) == "table" and vim.islist(opts.skill_paths),
            "skill_paths must be a list of paths"
        )
        for _, path in ipairs(opts.skill_paths) do
            assert(
                type(path) == "string",
                "skill_paths entries must be strings"
            )
            assert(
                not path:match("^%a[%w+.-]*://"),
                "skill_paths entries must be local paths: " .. path
            )
            add_option(command, "--skill", vim.fn.expand(path))
        end
    end

    add_option(command, "--provider", opts.provider)
    add_option(command, "--model", opts.model)
    add_option(command, "--thinking", opts.thinking)
    add_option(command, "--system-prompt", opts.system_prompt)

    add_option(command, "--append-system-prompt", Prompt.build(opts))

    return command
end

return M
