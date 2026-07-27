local M = {}

M.defaults = {
    backend = "pi",
    binary = "pi",
    extensions = false,
    skills = false,
    thinking = "off",
    auto_close = true,
    show_status = true,
    close_delay = 1000,
    chat = {
        keys = {
            input = {
                ["<C-c>"] = {
                    "clear_or_stop",
                    mode = { "i", "n" },
                    desc = "Clear input or stop AI agent",
                },
                ["<C-w>k"] = { "focus_display", desc = "Focus AI chat display" },
                ["<C-w><C-k>"] = { "focus_display", desc = "Focus AI chat display" },
                ["<C-k>"] = { "focus_display", desc = "Focus AI chat display" },
            },
            display = {
                ["<C-w>j"] = { "focus_input", desc = "Focus AI chat input" },
                ["<C-w><C-j>"] = { "focus_input", desc = "Focus AI chat input" },
                ["<C-j>"] = { "focus_input", desc = "Focus AI chat input" },
            },
        },
    },
}

local ui_options = {
    auto_close = true,
    chat = true,
    close_delay = true,
    show_status = true,
}

---Merges user options with the plugin defaults.
---@param opts? table
---@return table
function M.resolve(opts)
    return vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
end

---Returns configuration intended for an AI backend.
---@param opts? table
---@return table
function M.backend(opts)
    local backend = M.resolve(opts)
    for option in pairs(ui_options) do
        backend[option] = nil
    end
    return backend
end

return M
