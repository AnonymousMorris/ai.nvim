local M = {}
local Snacks = require("snacks")

local displays = setmetatable({}, { __mode = "v" })

---Scrolls a display window to the end of its transcript.
---@param display ai.ui.Display
function M.scroll_to_bottom(display)
    if not display:win_valid() then
        return
    end

    pcall(vim.api.nvim_win_call, display.win, function()
        vim.cmd("normal! G$zb")
    end)
end

---Scrolls an unfocused display to its newest output.
---@param buf integer
local function follow_output(buf)
    local display = displays[buf]
    if not display
        or not display:win_valid()
        or vim.api.nvim_get_current_win() == display.win
    then
        return
    end

    -- Moves the cursor without changing the user's active window.
    M.scroll_to_bottom(display)
end

---@class ai.ui.Display: snacks.win

---Temporarily unlocks a display buffer while applying an edit.
---@param buf integer
---@param edit fun()
local function edit_buffer(buf, edit)
    local was_modifiable = vim.bo[buf].modifiable
    vim.bo[buf].modifiable = true
    local ok, err = pcall(edit)
    vim.bo[buf].modifiable = was_modifiable
    if not ok then
        error(err)
    end
    follow_output(buf)
end

---Returns one line from a display buffer.
---@param buf integer
---@param row integer Zero-based row.
---@return string
function M.line(buf, row)
    return vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
end

---Returns or creates the buffer's trailing empty row.
---@param buf integer
---@return integer row Zero-based trailing empty row.
function M.empty_row(buf)
    local row = vim.api.nvim_buf_line_count(buf) - 1
    if M.line(buf, row) ~= "" then
        M.append(buf, "\n")
        row = row + 1
    end
    return row
end

---Returns the last non-empty line in a display buffer.
---@param buf integer
---@return string
function M.last_nonempty_line(buf)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for index = #lines, 1, -1 do
        if lines[index] ~= "" then
            return lines[index]
        end
    end
    return ""
end

---Appends text to the end of a display buffer.
---@param buf integer
---@param text string
function M.append(buf, text)
    local row = vim.api.nvim_buf_line_count(buf) - 1
    local col = #M.line(buf, row)
    -- Applies the append through the display's guarded edit path.
    edit_buffer(buf, function()
        vim.api.nvim_buf_set_text(
            buf,
            row,
            col,
            row,
            col,
            vim.split(text, "\n", { plain = true })
        )
    end)
end

---Replaces one display row and returns the replacement's final row.
---@param buf integer
---@param row integer Zero-based row to replace.
---@param text string
---@return integer row Zero-based row containing the end of the replacement.
function M.replace(buf, row, text)
    local lines = vim.split(text, "\n", { plain = true })
    -- Applies the replacement through the display's guarded edit path.
    edit_buffer(buf, function()
        vim.api.nvim_buf_set_lines(buf, row, row + 1, false, lines)
    end)
    return row + #lines - 1
end

local spinner_labels = {
    thinking = "Thinking...",
}

---@alias ai.ui.SpinnerState "thinking"|"tool"

---@class ai.ui.Spinner
---@field state? ai.ui.SpinnerState
---@field detail? string
---@field row? integer Zero-based status row.
---@field timer? uv.uv_timer_t
---@field set fun(self: ai.ui.Spinner, state?: ai.ui.SpinnerState, text?: string): integer?

---Creates a status spinner that renders into a display buffer.
---@param buf integer
---@return ai.ui.Spinner
function M.spinner(buf)
    local spinner = {}

    -- Stops and releases the active animation timer.
    local function stop()
        if spinner.timer then
            spinner.timer:stop()
            spinner.timer:close()
            spinner.timer = nil
        end
    end

    -- Draws one spinner frame with its status label.
    local function render(row, label)
        M.replace(buf, row, Snacks.util.spinner() .. " " .. label)
    end

    ---Transitions to a spinner state, or stops with an optional replacement.
    ---@param state? ai.ui.SpinnerState
    ---@param text? string Tool detail when active; row replacement when stopped.
    ---@return integer? row
    function spinner:set(state, text)
        if state and self.state == state and self.detail == text then
            return self.row
        end

        stop()
        if not state then
            self.state = nil
            self.detail = nil
            if not self.row then
                return
            end

            local row = M.replace(buf, self.row, text or "")
            self.row = nil
            return row
        end

        local label = spinner_labels[state]
        if state == "tool" then
            label = "Calling tool: " .. (text or "unknown") .. "..."
        end
        assert(label, "invalid spinner state: " .. tostring(state))

        self.state = state
        self.detail = text
        self.row = self.row or M.empty_row(buf)
        local row = self.row
        render(row, label)

        local timer = assert((vim.uv or vim.loop).new_timer(), "failed to create spinner timer")
        self.timer = timer
        -- Advances the spinner while its row remains active.
        timer:start(100, 100, vim.schedule_wrap(function()
            if self.timer ~= timer or self.row ~= row then
                return
            end
            if not pcall(render, row, label) then
                stop()
            end
        end))
        return row
    end

    return spinner
end

---Creates a read-only transcript window for an existing buffer.
---@param config snacks.win.Config
---@return ai.ui.Display
function M.display(config)
    local opts = Snacks.config.merge({
        show = false,
        bo = {
            buftype = "nofile",
            bufhidden = "hide",
            filetype = "markdown",
            modifiable = false,
            swapfile = false,
            undofile = false,
            undolevels = -1,
        },
        wo = {
            wrap = true,
            linebreak = true,
        },
    }, vim.deepcopy(config or {}))
    assert(opts.buf, "AI display buffer is required")
    assert(vim.api.nvim_buf_is_valid(opts.buf), "AI display buffer is invalid")
    local display = Snacks.win(opts)
    displays[opts.buf] = display
    return display
end

return M
