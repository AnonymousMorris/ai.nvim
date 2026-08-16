-- Prevent the plugin from being loaded more than once.
if vim.g.loaded_ai_nvim then
    return
end
vim.g.loaded_ai_nvim = true

-- Open the current AI session, creating it when necessary.
vim.api.nvim_create_user_command("AI", function()
    require("ai.session").open_current()
end, { desc = "Open the current AI session" })

-- Open the current AI session with the active or latest visual selection.
vim.api.nvim_create_user_command("AISelection", function()
    local Session = require("ai.session")
    local session = Session.get_current()
    local agent_spawn_dir = session and session.agent_spawn_dir
        or vim.fn.getcwd()
    local context = require("ai.context").get_visual_context(agent_spawn_dir)
    if context == nil then
        vim.notify("AISelection requires a visual selection", vim.log.levels.WARN)
        return
    end
    local chat = Session.open_current()
    if chat then
        chat:paste_input(context)
    end
end, {
    desc = "Open the current AI session with visual selection",
    range = true,
})

-- Stop the current AI session and release its resources.
vim.api.nvim_create_user_command("AIStop", function()
    local ok, err = require("ai.session").stop_current()
    if not ok then
        vim.notify(
            "Failed to stop AI session: " .. tostring(err),
            vim.log.levels.ERROR
        )
    end
end, { desc = "Stop the current AI session" })
