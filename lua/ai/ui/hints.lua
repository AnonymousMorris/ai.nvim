local M = {}

local Snacks = require("snacks")

local namespace = vim.api.nvim_create_namespace("ai.ui.hints")

---@class ai.ui.Hint
---@field key string
---@field label string

---@alias ai.ui.HintConfig ai.ui.Hint[]

---Updates a hint window with exactly the configured items.
---@param win snacks.win
---@param config ai.ui.HintConfig
function M.update(win, config)
    assert(win, "hint window is required")
    assert(win:buf_valid(), "hint buffer is invalid")
    assert(win:win_valid(), "hint window is invalid")
    assert(type(config) == "table", "hint config must be a table")

    local chunks = {}
    local text = {}
    for index, hint in ipairs(config) do
        assert(type(hint) == "table", ("hint %d must be a table"):format(index))
        assert(
            type(hint.key) == "string" and hint.key ~= "",
            ("hint %d key is required"):format(index)
        )
        assert(
            type(hint.label) == "string" and hint.label ~= "",
            ("hint %d label is required"):format(index)
        )

        chunks[#chunks + 1] = { hint.key, "SnacksFooterKey" }
        chunks[#chunks + 1] = { " " .. hint.label, "SnacksFooterDesc" }
        text[#text + 1] = hint.key .. " " .. hint.label
        if index < #config then
            chunks[#chunks + 1] = { " • ", "SnacksWinKeySep" }
            text[#text + 1] = " • "
        end
    end

    local available = vim.api.nvim_win_get_width(win.win)
    local padding = math.max(
        0,
        math.floor((available - vim.fn.strdisplaywidth(table.concat(text))) / 2)
    )
    if padding > 0 then
        table.insert(chunks, 1, { string.rep(" ", padding), "Normal" })
    end

    vim.api.nvim_buf_clear_namespace(win.buf, namespace, 0, -1)
    vim.api.nvim_buf_set_lines(win.buf, 0, -1, false, { "" })
    if #chunks > 0 then
        vim.api.nvim_buf_set_extmark(win.buf, namespace, 0, 0, {
            virt_text = chunks,
            virt_text_pos = "overlay",
        })
    end
end

---Creates an instance-owned, non-focusable hint window.
---@return snacks.win
function M.new()
    return Snacks.win({
        show = false,
        focusable = false,
        enter = false,
        text = { "" },
        keys = { q = false },
        bo = {
            buftype = "nofile",
            bufhidden = "wipe",
            modifiable = true,
            swapfile = false,
            undofile = false,
        },
        wo = {
            wrap = false,
            winhighlight = "Normal:Normal,NormalNC:Normal",
        },
    })
end

return M
