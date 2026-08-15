local M = {}
local Snacks = require("snacks")

local context_ns = vim.api.nvim_create_namespace("ai.input.context")

---@class ai.ui.Input: snacks.win
---@field on_height_change? fun()

---Reports that the rendered input height may have changed.
---@param input ai.ui.Input
local function height_changed(input)
    if input.on_height_change then
        input.on_height_change()
    end
end

---Rebuilds closed manual folds for every tracked context block.
---@param input ai.ui.Input
local function restore_context_folds(input)
    if not input:buf_valid() or not input:win_valid() then
        return
    end

    local contexts = vim.api.nvim_buf_get_extmarks(
        input.buf,
        context_ns,
        0,
        -1,
        { details = true }
    )
    vim.api.nvim_win_call(input.win, function()
        vim.cmd("silent! normal! zE")
        for _, context in ipairs(contexts) do
            local start_row = context[2]
            local details = context[4]
            if
                not details.invalid
                and details.end_row
                and details.end_row > start_row
            then
                vim.cmd(
                    ("silent %d,%dfold"):format(
                        start_row + 1,
                        details.end_row + 1
                    )
                )
            end
        end
    end)
end

---Returns the rendered height of an input window.
---@param input snacks.win
---@return integer
function M.height(input)
    if input:win_valid() then
        return vim.api.nvim_win_text_height(input.win, {}).all
    end
    return vim.api.nvim_buf_line_count(input.buf)
end

---Moves an input cursor to the end of its buffer.
---@param input ai.ui.Input
function M.cursor_end(input)
    if not input:buf_valid() or not input:win_valid() then
        return
    end

    local row = vim.api.nvim_buf_line_count(input.buf)
    local line = vim.api.nvim_buf_get_lines(input.buf, row - 1, row, false)[1]
        or ""
    vim.api.nvim_win_set_cursor(input.win, { row, #line })
end

---Inserts a newline at the input cursor without invoking confirmation.
---@param input ai.ui.Input
function M.insert_newline(input)
    if not input:buf_valid() or not input:win_valid() then
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(input.win)
    vim.api.nvim_buf_set_text(
        input.buf,
        cursor[1] - 1,
        cursor[2],
        cursor[1] - 1,
        cursor[2],
        { "", "" }
    )
    vim.api.nvim_win_set_cursor(input.win, { cursor[1] + 1, 0 })
    height_changed(input)
end

---Clears an input and returns its cursor to the beginning.
---@param input ai.ui.Input
function M.clear(input)
    if not input:buf_valid() then
        return
    end

    vim.api.nvim_buf_clear_namespace(input.buf, context_ns, 0, -1)
    vim.api.nvim_buf_set_lines(input.buf, 0, -1, false, { "" })
    height_changed(input)
end

local statuscolumn = [[%C%#SnacksInputIcon#%{v:lnum == 1 && v:virtnum == 0 ? '   ' : ''}%*]]

local multiline_opts = {
    height = M.height,

    -- Applies the custom status column after the input buffer is created.
    on_buf = function(input)
        input.opts.wo.statuscolumn = statuscolumn
    end,

    wo = {
        wrap = true,
        linebreak = true,
        fillchars = "eob: ,fold: ,lastline:…",
        foldcolumn = "auto:1",
        foldenable = true,
        foldmethod = "manual",
        foldtext = [[getline(v:foldstart) . '  ' . getline(v:foldstart + 1)]],
    },
}

---Prepends text to an input and leaves the cursor ready for instructions.
---@param input ai.ui.Input
---@param text string
function M.prepend(input, text)
    assert(type(text) == "string" and text ~= "", "input text is required")

    local context_lines = vim.split(text, "\n", { plain = true })
    local inserted_lines = vim.split(text .. "\n\n", "\n", { plain = true })
    vim.api.nvim_buf_set_text(input.buf, 0, 0, 0, 0, inserted_lines)
    vim.api.nvim_buf_set_extmark(input.buf, context_ns, 0, 0, {
        end_row = #context_lines - 1,
        end_col = #context_lines[#context_lines],
        right_gravity = true,
        end_right_gravity = false,
        invalidate = true,
    })

    input:focus()
    M.cursor_end(input)
    restore_context_folds(input)
    height_changed(input)
    vim.api.nvim_win_call(input.win, function()
        vim.fn.winrestview({ topline = 1, leftcol = 0 })
    end)
    vim.cmd("startinsert")
end

---Creates a multiline input that forwards non-empty submissions.
---@param config? table
---@param on_submit fun(value: string)
---@return ai.ui.Input
function M.input(config, on_submit)
    -- Filters empty values before forwarding a submission.
    local function submit(value)
        if value and value ~= "" then
            on_submit(value)
        end
    end

    local opts = Snacks.config.merge({
        prompt = "Ask AI: ",
        icon_pos = false,
        win = vim.deepcopy(multiline_opts),
    }, vim.deepcopy(config or {}))
    local input = Snacks.input(opts, submit)
    restore_context_folds(input)
    local confirm_pending = false
    -- Clears and submits the input once per confirmation action.
    input.opts.actions.confirm = function(input)
        if confirm_pending then
            return true
        end

        confirm_pending = true
        local value = input:text()
        -- Defers buffer edits until the current input action completes.
        vim.schedule(function()
            confirm_pending = false
            M.clear(input)
            submit(value)
        end)
        return true
    end

    return input
end

return M
