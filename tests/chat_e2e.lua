local repo = vim.fn.getcwd()
local snacks = vim.env.SNACKS_NVIM
    or (vim.fn.stdpath("data") .. "/lazy/snacks.nvim")

assert(vim.fn.isdirectory(snacks) == 1, "snacks.nvim is not installed")
vim.opt.runtimepath:prepend(snacks)
vim.opt.runtimepath:prepend(repo)

local AI = require("ai.ai")
local Chat = require("ai.ui.chat")
local Display = require("ai.ui.display")
local Session = require("ai.session")

local function assert_equal(actual, expected, message)
    assert(
        vim.deep_equal(actual, expected),
        ("%s: expected %s, got %s"):format(
            message,
            vim.inspect(expected),
            vim.inspect(actual)
        )
    )
end

local function find_keymap(buf, mode, lhs)
    for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
        if keymap.lhs == lhs then
            return keymap
        end
    end
end

local function virtual_text(buf)
    local text = {}
    for _, extmark in ipairs(vim.api.nvim_buf_get_extmarks(
        buf,
        -1,
        0,
        -1,
        { details = true }
    )) do
        for _, chunk in ipairs(extmark[4].virt_text or {}) do
            text[#text + 1] = chunk[1]
        end
    end
    return table.concat(text)
end

local function assert_contains(text, expected, message)
    assert(
        text:find(expected, 1, true),
        ("%s: expected %s in %s"):format(
            message,
            vim.inspect(expected),
            vim.inspect(text)
        )
    )
end

local function wait_for_close(chat)
    assert(
        vim.wait(1000, function()
            return not chat.layout:valid()
        end),
        "chat did not close"
    )
    vim.wait(10)
end

local function set_display_lines(buf)
    local lines = {}
    for index = 1, 100 do
        lines[index] = ("line %03d"):format(index)
    end

    Display.replace(buf, 0, table.concat(lines, "\n"))
end

local function append_display_line(buf, line)
    Display.append(buf, "\n" .. line)
end

---@class ai.ChatTestBackend: ai.Backend
local ChatTestBackend = {}
ChatTestBackend.__index = ChatTestBackend

function ChatTestBackend.start()
    return setmetatable({}, ChatTestBackend)
end

function ChatTestBackend:send(event, mode)
    self.sends = (self.sends or 0) + 1
    self.last_event = event
    self.delivery_modes = self.delivery_modes or {}
    self.delivery_modes[#self.delivery_modes + 1] = mode
    return true
end

function ChatTestBackend:interrupt()
    self.interrupted = true
    return true
end

function ChatTestBackend:finish()
    return true
end

function ChatTestBackend:cancel()
    self.cancelled = true
end

AI.register_backend("chat-test", ChatTestBackend)
Session.setup({})

local left_win = vim.api.nvim_get_current_win()
vim.cmd("botright vnew")
local source_win = vim.api.nvim_get_current_win()
assert(source_win ~= left_win, "chat focus test did not create a right split")

local chat = assert(Session.open_current({ backend = "chat-test" }))
local session = assert(Session.get_current())
assert(chat.hints, "default chat hints were not created")
assert(chat.hints:win_valid(), "chat hints window is invalid")
assert_equal(
    vim.api.nvim_win_get_height(chat.hints.win),
    1,
    "chat hints height"
)
assert_equal(
    vim.api.nvim_win_get_config(chat.hints.win).focusable,
    false,
    "chat hints focusable"
)
assert_equal(chat.display.opts.border, "rounded", "chat display border")
assert_equal(chat.display.opts.title, " chat-test ", "chat display title")
assert_equal(
    vim.api.nvim_win_get_config(chat.display.win).title[1][1],
    " chat-test ",
    "rendered chat display title"
)
assert_equal(chat.input.opts.border, "rounded", "chat input border")
assert_equal(chat.input.opts.title, " Prompt ", "chat input title")
assert_equal(
    vim.api.nvim_win_get_config(chat.input.win).title[1][1],
    " Prompt ",
    "rendered chat input title"
)
assert(
    not chat.layout.root:has_border(),
    "layout root visually enclosed the chat windows"
)
assert_equal(chat.layout.root.opts.backdrop, false, "layout root backdrop")
assert_equal(
    chat.layout.root.opts.wo.winhighlight,
    "Normal:Normal,NormalNC:Normal",
    "layout root background"
)
assert_equal(chat.layout.root.opts.wo.winblend, 100, "layout root blend")
assert_equal(vim.wo[chat.layout.root.win].winblend, 100, "layout root window blend")
assert_equal(
    chat.hints.opts.wo.winhighlight,
    "Normal:Normal,NormalNC:Normal",
    "chat hints background"
)
assert_equal(
    chat.layout.box_wins[2],
    nil,
    "chat windows retained a shared layout container"
)
local display_config = vim.api.nvim_win_get_config(chat.display.win)
local input_config = vim.api.nvim_win_get_config(chat.input.win)
local hints_config = vim.api.nvim_win_get_config(chat.hints.win)
assert_equal(
    input_config.row,
    display_config.row + vim.api.nvim_win_get_height(chat.display.win) + 2,
    "chat input position below the independent display window"
)
assert_equal(
    hints_config.row,
    input_config.row + vim.api.nvim_win_get_height(chat.input.win) + 2,
    "chat hints position below the independent input window"
)
local input_hints = virtual_text(chat.hints.buf)
assert_contains(input_hints, "⏎ send/steer", "input submit hint")
assert_contains(input_hints, "S-⏎ newline", "input newline hint")
assert_contains(
    input_hints,
    "C-c clear/interrupt",
    "input clear or interrupt hint"
)
assert_contains(input_hints, "C-n new", "new session hint")
assert_contains(input_hints, "Tab switch", "input focus hint")
assert_equal(chat.display.buf, session.display_buf, "display window buffer")
assert(
    chat.display.begin_turn == nil
        and chat.display.stream == nil
        and chat.display.end_turn == nil,
    "display window retained transcript state"
)
set_display_lines(session.display_buf)

assert(
    vim.wait(1000, function()
        return vim.api.nvim_win_get_cursor(chat.display.win)[1] == 100
    end),
    "unfocused display did not scroll to the bottom"
)
assert_equal(
    vim.api.nvim_get_current_win(),
    chat.input.win,
    "display auto-scroll stole input focus"
)

vim.cmd.stopinsert()
vim.api.nvim_set_current_win(chat.display.win)
local display_hints = virtual_text(chat.hints.buf)
assert_contains(display_hints, "Tab input", "display WinEnter hint")
assert(
    not display_hints:find("send", 1, true),
    "display hints retained input actions"
)
vim.api.nvim_win_set_cursor(chat.display.win, { 50, 0 })
vim.cmd("normal! zz")
append_display_line(session.display_buf, "line 101")
vim.wait(10)
assert_equal(
    vim.api.nvim_win_get_cursor(chat.display.win)[1],
    50,
    "focused display moved after output"
)

chat:focus_input()
append_display_line(session.display_buf, "line 102")
assert(
    vim.wait(1000, function()
        return vim.api.nvim_win_get_cursor(chat.display.win)[1] == 102
    end),
    "display did not resume scrolling after losing focus"
)
assert_equal(
    vim.api.nvim_get_current_win(),
    chat.input.win,
    "resumed display auto-scroll stole input focus"
)

local insert_tab = find_keymap(chat.input.buf, "i", "<Tab>")
assert_equal(
    insert_tab and insert_tab.desc,
    "Focus AI chat display",
    "insert mode focus display key"
)
for _, key in ipairs({ "<M-CR>", "<S-CR>" }) do
    local insert_newline = find_keymap(chat.input.buf, "i", key)
    assert_equal(
        insert_newline and insert_newline.desc,
        "Insert newline",
        "insert mode " .. key .. " key"
    )
end
for _, mode in ipairs({ "i", "n" }) do
    local new_session = find_keymap(chat.input.buf, mode, "<C-N>")
    assert_equal(
        new_session and new_session.desc,
        "Create a new AI session",
        mode .. " mode new session key"
    )
end

chat:focus_input()
vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "mx", false)
assert_equal(vim.api.nvim_get_current_win(), chat.display.win, "focus display key")
vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "mx", false)
assert_equal(vim.api.nvim_get_current_win(), chat.input.win, "focus input key")

vim.api.nvim_buf_set_lines(session.input_buf, 0, -1, false, { "first" })
chat:focus_input()
vim.cmd.stopinsert()
vim.api.nvim_feedkeys(
    vim.keycode("A<M-CR>x<C-\\><C-n>"),
    "mx",
    false
)
vim.wait(10)
assert_equal(
    vim.api.nvim_buf_get_lines(session.input_buf, 0, -1, false),
    { "first", "x" },
    "Shift-Enter newline followed by input"
)
assert_equal(session.ai.backend.sends, nil, "Shift-Enter submitted the prompt")
assert(chat.layout:valid(), "Shift-Enter closed the chat")
assert_equal(
    vim.api.nvim_get_current_win(),
    chat.input.win,
    "Shift-Enter moved input focus"
)

chat:focus_display()
vim.api.nvim_win_set_cursor(chat.display.win, { 50, 0 })
vim.cmd("normal! zz")
vim.api.nvim_buf_set_lines(session.input_buf, 0, -1, false, { "submit" })
chat:focus_input()
chat.input:execute("confirm")
assert(
    vim.wait(1000, function()
        return vim.api.nvim_get_current_win() == chat.display.win
    end),
    "submission did not focus the display"
)
assert_equal(
    vim.api.nvim_win_get_cursor(chat.display.win)[1],
    102,
    "submission did not scroll the display to the bottom"
)
assert_equal(
    session.ai.backend.delivery_modes,
    { "prompt" },
    "idle submission delivery mode"
)

chat:focus_display()
vim.api.nvim_win_set_cursor(chat.display.win, { 50, 0 })
vim.cmd("normal! zz")
vim.api.nvim_buf_set_lines(session.input_buf, 0, -1, false, {
    "first line",
    "second line",
    "third line",
})
chat:focus_input()
vim.api.nvim_win_set_cursor(chat.input.win, { 3, 0 })
chat.input:execute("cancel")
wait_for_close(chat)
assert_equal(session.chat, nil, "session chat after input close")
assert_equal(
    vim.api.nvim_get_current_win(),
    source_win,
    "input close source focus"
)

local reopened = assert(Session.open_current())
assert(reopened ~= chat, "closed chat UI was reused")
assert_equal(vim.api.nvim_get_current_win(), reopened.input.win, "fresh focus")
assert_equal(
    vim.api.nvim_win_get_cursor(reopened.display.win)[1],
    102,
    "fresh display cursor"
)
local reopened_input_cursor = vim.api.nvim_win_get_cursor(reopened.input.win)
assert(
    reopened_input_cursor[1] == 3 and reopened_input_cursor[2] == 10,
    "fresh input cursor: " .. vim.inspect(reopened_input_cursor)
)
assert_equal(Session.open_current(), reopened, "open chat was duplicated")

vim.api.nvim_win_set_cursor(reopened.input.win, { 1, 0 })
reopened:focus_display()
reopened:focus_input()
local refocused_input_cursor = vim.api.nvim_win_get_cursor(reopened.input.win)
assert(
    refocused_input_cursor[1] == 1 and refocused_input_cursor[2] == 0,
    "refocused input cursor changed: " .. vim.inspect(refocused_input_cursor)
)

reopened:focus_display()
vim.api.nvim_win_set_cursor(reopened.display.win, { 70, 0 })
vim.cmd("normal! zz")
vim.api.nvim_win_close(reopened.display.win, true)
wait_for_close(reopened)
assert_equal(session.chat, nil, "session chat after direct window close")
assert_equal(
    vim.api.nvim_get_current_win(),
    source_win,
    "direct display close source focus"
)

local final_chat = assert(Session.open_current())
assert(final_chat ~= reopened, "directly closed chat UI was reused")
assert_equal(
    vim.api.nvim_win_get_cursor(final_chat.display.win)[1],
    102,
    "display cursor after direct window close"
)
assert_equal(vim.api.nvim_get_current_win(), final_chat.input.win, "final focus")
local final_input_cursor = vim.api.nvim_win_get_cursor(final_chat.input.win)
assert(
    final_input_cursor[1] == 3 and final_input_cursor[2] == 10,
    "final input cursor: " .. vim.inspect(final_input_cursor)
)
final_chat:focus_display()
vim.api.nvim_feedkeys("q", "mx", false)
wait_for_close(final_chat)
assert_equal(session.chat, nil, "session chat after final close")
assert_equal(
    vim.api.nvim_get_current_win(),
    source_win,
    "display quit source focus"
)

Chat.setup({
    hints = {
        input = {
            { key = "X", label = "switch" },
        },
        display = {
            { key = "Y", label = "input" },
        },
    },
    keys = {
        input = {
            ["<Tab>"] = false,
            ["<C-w>k"] = false,
            ["<C-w><C-k>"] = false,
            x = {
                "focus_display",
                mode = { "i", "n" },
                desc = "Focus AI chat display",
            },
        },
        display = {
            ["<Tab>"] = false,
            ["<C-w>j"] = false,
            ["<C-w><C-j>"] = false,
            y = { "focus_input", desc = "Focus AI chat input" },
        },
    },
})

local remapped_chat = Chat.new(
    vim.api.nvim_create_buf(false, true),
    vim.api.nvim_create_buf(false, true),
    {
        backend_name = "remapped-test",
        on_submit = function() end,
        on_interrupt = function() end,
        on_new_session = function() end,
    }
)
assert_equal(
    remapped_chat.display.opts.title,
    " remapped-test ",
    "explicit backend display title"
)
local remapped_input_hints = virtual_text(remapped_chat.hints.buf)
assert_contains(remapped_input_hints, "X switch", "configured input hint")
assert(
    not remapped_input_hints:find("Tab switch", 1, true),
    "configured input hint retained the default key"
)
assert(
    not remapped_input_hints:find("clear/interrupt", 1, true),
    "disabled input hint was rendered"
)
remapped_chat:set_hint_context("display")
assert_contains(
    virtual_text(remapped_chat.hints.buf),
    "Y input",
    "explicit display hint context"
)
local updated_invalid_context, invalid_context_error = pcall(
    remapped_chat.set_hint_context,
    remapped_chat,
    "invalid"
)
assert(not updated_invalid_context, "invalid hint context was accepted")
assert_contains(
    invalid_context_error,
    "invalid hint context",
    "invalid hint context error"
)
remapped_chat:focus_display()
assert_contains(
    virtual_text(remapped_chat.hints.buf),
    "Y input",
    "configured display hint"
)
remapped_chat:close()
wait_for_close(remapped_chat)

Chat.setup({ keys = false, show_hints = false })

local submissions = {}
local function create_chat()
    return Chat.new(
        vim.api.nvim_create_buf(false, true),
        vim.api.nvim_create_buf(false, true),
        {
            backend_name = "empty-test",
            on_submit = function(value)
                submissions[#submissions + 1] = value
            end,
            on_interrupt = function() end,
            on_new_session = function() end,
        }
    )
end

local empty_chat = create_chat()
assert_equal(empty_chat.hints, nil, "disabled chat hints")
local updated_disabled_hints, disabled_hints_error = pcall(
    empty_chat.render_hints,
    empty_chat
)
assert(not updated_disabled_hints, "disabled chat hints accepted an update")
assert_contains(
    disabled_hints_error,
    "chat hints are disabled",
    "disabled chat hints update error"
)
for _, win in ipairs({ empty_chat.display, empty_chat.input }) do
    for _, mode in ipairs({ "i", "n" }) do
        for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(win.buf, mode)) do
            assert(
                not (keymap.desc or ""):find("Focus AI", 1, true),
                "disabled chat keymap was applied"
            )
        end
    end
end
empty_chat.input:execute("confirm")
vim.wait(10)
assert(empty_chat.layout:valid(), "empty submission closed the chat")
assert_equal(#submissions, 0, "empty submission count")
empty_chat:close()
wait_for_close(empty_chat)

local submitted_chat = create_chat()
vim.api.nvim_buf_set_lines(submitted_chat.input.buf, 0, -1, false, {
    "hello",
})
submitted_chat.input:execute("confirm")
vim.wait(10)
assert(submitted_chat.layout:valid(), "submission closed the chat")
assert_equal(submissions[1], "hello", "submitted value")
assert_equal(
    vim.api.nvim_buf_get_lines(submitted_chat.input.buf, 0, -1, false)[1],
    "",
    "input after submission"
)
submitted_chat:close()
wait_for_close(submitted_chat)

print("chat E2E checks passed")
vim.cmd("qa!")
