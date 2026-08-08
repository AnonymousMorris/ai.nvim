local M = {}

local Snacks = require("snacks")
local Config = require("ai.config")
local Display = require("ai.ui.display")
local Hints = require("ai.ui.hints")
local Input = require("ai.ui.input")

local config = vim.deepcopy(Config.defaults.chat)

---@alias ai.ui.HintContext "input"|"display"

---@class ai.ui.Chat
---@field display ai.ui.Display
---@field hint_context ai.ui.HintContext
---@field hints? snacks.win
---@field input ai.ui.Input
---@field layout snacks.layout
---@field input_height? integer
---@field on_close? fun(chat: ai.ui.Chat)
local Chat = {}
Chat.__index = Chat

---Moves focus to the transcript window in normal mode.
function Chat:focus_display()
    vim.cmd.stopinsert()
    self.display:focus()
end

---Moves focus to the input window in insert mode.
function Chat:focus_input()
    self.input:focus()
    vim.cmd.startinsert()
end

---Renders the hint bar for the current chat context.
function Chat:render_hints()
    local hint_win = assert(self.hints, "chat hints are disabled")
    assert(hint_win:win_valid(), "chat hints window is invalid")
    Hints.update(hint_win, config.hints[self.hint_context])
end

---Changes the chat hint context and renders it.
---@param context ai.ui.HintContext
function Chat:set_hint_context(context)
    assert(
        context == "input" or context == "display",
        "invalid hint context: " .. tostring(context)
    )

    self.hint_context = context
    self:render_hints()
end

---Resizes the layout when the input's rendered height changes.
function Chat:update_input_layout()
    if not self.layout or self.layout.closed then
        return
    end

    local input_height = Input.height(self.input)
    if input_height ~= self.input_height then
        self.input_height = input_height
        self.layout:update()
    end
end

---Pastes text before the current input and prepares for instructions.
---@param text string
function Chat:paste_input(text)
    Input.prepend(self.input, text)
end

---Destroys the chat UI and reports its closure once.
function Chat:close()
    local on_close = self.on_close
    self.on_close = nil
    if not self.layout.closed then
        self.layout:close()
    end
    if on_close then
        on_close(self)
    end
end

---Merges and validates chat-specific configuration.
function M.setup(opts)
    config = Snacks.config.merge(
        vim.deepcopy(Config.defaults.chat),
        vim.deepcopy(opts or {})
    )
    if config.keys == false then
        config.keys = {}
    end
    assert(type(config.keys) == "table", "keys must be a table or false")
    assert(type(config.show_hints) == "boolean", "show_hints must be boolean")
    assert(type(config.hints) == "table", "hints must be a table")
    for _, name in ipairs({ "display", "input" }) do
        assert(type(config.hints[name]) == "table", name .. " hints must be a table")
        if config.keys[name] == false then
            config.keys[name] = {}
        end
        config.keys[name] = config.keys[name] or {}
        assert(type(config.keys[name]) == "table", name .. " keys must be a table or false")
    end
    return config
end

---@class ai.ui.ChatOpts
---@field backend_name string
---@field on_submit fun(value: string)
---@field on_interrupt fun()
---@field on_close? fun(chat: ai.ui.Chat)

---Creates and shows a chat layout around the supplied buffers.
---@param display_buf integer
---@param input_buf integer
---@param opts ai.ui.ChatOpts
---@return ai.ui.Chat
function M.new(display_buf, input_buf, opts)
    assert(
        type(opts.backend_name) == "string" and opts.backend_name ~= "",
        "AI backend name is required"
    )

    local chat = setmetatable({
        hint_context = "input",
        on_close = opts.on_close,
    }, Chat)
    -- Gives either child window a shared layout-close action.
    local function close_layout()
        chat:close()
    end
    local actions = {
        interrupt = function()
            opts.on_interrupt()
            return true
        end,
        -- Exposes display focus to configured window keymaps.
        focus_display = function()
            chat:focus_display()
        end,
        -- Exposes input focus to configured window keymaps.
        focus_input = function()
            chat:focus_input()
        end,
    }

    chat.display = Display.display({
        buf = display_buf,
        actions = actions,
        keys = config.keys.display,
        on_close = close_layout,
    })
    local input_keys = vim.deepcopy(config.keys.input)
    if input_keys["<Tab>"] and input_keys.i_tab == nil then
        -- Replaces Snacks.input's insert-mode completion mapping.
        input_keys.i_tab = false
    end
    chat.input = Input.input({
        win = {
            buf = input_buf,
            actions = actions,
            keys = input_keys,
            on_close = close_layout,
        },
    }, opts.on_submit)
    chat.input.on_height_change = function()
        chat:update_input_layout()
    end

    local wins = {
        display = chat.display,
        input = chat.input,
    }
    local layout = {
        box = "vertical",
        width = 0.8,
        height = 0.8,
        backdrop = false,
        wo = {
            winblend = 100,
            winhighlight = "Normal:Normal,NormalNC:Normal",
        },
        {
            win = "display",
            border = "rounded",
            title = " " .. opts.backend_name .. " ",
        },
        {
            win = "input",
            -- Recomputes layout height from the rendered input.
            height = function()
                return Input.height(chat.input)
            end,
            border = "rounded",
            title = " Prompt ",
        },
    }
    if config.show_hints then
        chat.hints = Hints.new()
        wins.hints = chat.hints
        layout[#layout + 1] = {
            win = "hints",
            height = 1,
            border = "none",
        }
    end

    chat.layout = Snacks.layout.new({
        show = false,
        wins = wins,
        layout = layout,
        on_update = chat.hints and function()
            chat:render_hints()
        end or nil,
    })

    chat.layout:show()
    chat.input_height = Input.height(chat.input)

    -- Follows transcript updates unless the user is reading it.
    chat.display:on("TextChanged", function()
        if vim.api.nvim_get_current_win() == chat.display.win then
            return
        end

        vim.api.nvim_win_set_cursor(chat.display.win, {
            vim.api.nvim_buf_line_count(chat.display.buf),
            0,
        })
    end, { buf = true })

    -- Updates the layout when edits, folds, or cursor placement change height.
    chat.input:on({
        "TextChangedI",
        "TextChanged",
        "CursorMovedI",
        "CursorMoved",
    }, function()
        chat:update_input_layout()
    end, { buf = true })

    if chat.hints then
        chat.display:on("WinEnter", function()
            if not chat.layout.closed then
                chat:set_hint_context("display")
            end
        end, { buf = true })
        chat.input:on("WinEnter", function()
            if not chat.layout.closed then
                chat:set_hint_context("input")
            end
        end, { buf = true })
    end

    -- Every fresh UI starts at the newest transcript output and input.
    vim.api.nvim_win_call(chat.display.win, function()
        vim.cmd("normal! G$zb")
    end)
    chat:focus_input()
    Input.cursor_end(chat.input)

    return chat
end

return M
