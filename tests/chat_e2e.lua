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
        actual == expected,
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

function ChatTestBackend:send()
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

local chat = assert(Session.open_current({ backend = "chat-test" }))
local session = assert(Session.get_current())
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

chat:focus_display()
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

chat:focus_input()
vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "mx", false)
assert_equal(vim.api.nvim_get_current_win(), chat.display.win, "focus display key")
vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "mx", false)
assert_equal(vim.api.nvim_get_current_win(), chat.input.win, "focus input key")

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
final_chat:close()
wait_for_close(final_chat)
assert_equal(session.chat, nil, "session chat after final close")

Chat.setup({ keys = false })

local submissions = {}
local function create_chat()
    return Chat.new(
        vim.api.nvim_create_buf(false, true),
        vim.api.nvim_create_buf(false, true),
        {
            on_submit = function(value)
                submissions[#submissions + 1] = value
            end,
        }
    )
end

local empty_chat = create_chat()
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
