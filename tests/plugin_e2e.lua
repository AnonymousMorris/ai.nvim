local repo = vim.fn.getcwd()
local snacks = vim.env.SNACKS_NVIM
    or (vim.fn.stdpath("data") .. "/lazy/snacks.nvim")

assert(vim.fn.isdirectory(snacks) == 1, "snacks.nvim is not installed")
vim.opt.runtimepath:prepend(snacks)
vim.opt.runtimepath:prepend(repo)

assert(vim.fn.exists(":AI") == 0, "AI command existed before plugin load")
assert(
    vim.fn.exists(":AISelection") == 0,
    "AISelection command existed before plugin load"
)
assert(vim.fn.exists(":AIStop") == 0, "AIStop command existed before plugin load")

vim.cmd.runtime("plugin/ai.nvim.lua")
vim.cmd.runtime("plugin/ai.nvim.lua")

assert(vim.g.loaded_ai_nvim == true, "plugin load guard was not set")
assert(vim.fn.exists(":AI") == 2, "AI command was not registered")
assert(
    vim.fn.exists(":AISelection") == 2,
    "AISelection command was not registered"
)
assert(vim.fn.exists(":AIStop") == 2, "AIStop command was not registered")

local commands = vim.api.nvim_get_commands({ builtin = false })
assert(
    commands.AI.definition == "Open the current AI session",
    "AI command description was incorrect"
)
assert(
    commands.AISelection.definition
        == "Open the current AI session with visual selection",
    "AISelection command description was incorrect"
)
assert(
    commands.AIStop.definition == "Stop the current AI session",
    "AIStop command description was incorrect"
)

local AI = require("ai.ai")
local Plugin = require("ai")
local Session = require("ai.session")

---@class ai.CommandTestBackend: ai.Backend
local CommandTestBackend = {}
CommandTestBackend.__index = CommandTestBackend

local backend
function CommandTestBackend.start()
    backend = setmetatable({}, CommandTestBackend)
    return backend
end

function CommandTestBackend:send()
    return true
end

function CommandTestBackend:finish()
    return true
end

function CommandTestBackend:cancel()
    self.cancelled = true
end

AI.register_backend("command-test", CommandTestBackend)
Plugin.setup({ backend = "command-test" })

local normal_mapping
for _, mapping in ipairs(vim.api.nvim_get_keymap("n")) do
    if mapping.lhs == "\\ai" then
        normal_mapping = mapping
        break
    end
end
assert(normal_mapping, "normal AI keymap was not registered")
assert(
    normal_mapping.rhs == "<Cmd>AI<CR>",
    "normal AI keymap did not execute :AI"
)
assert(normal_mapping.callback == nil, "normal AI keymap retained a callback")

vim.cmd("AI")
local session = assert(Session.get_current(), "AI did not create a session")
local chat = assert(session.chat, "AI did not open the chat")
local display_buf = session.display_buf
local input_buf = session.input_buf
assert(Session.open_current() == chat, "AI command duplicated the open chat")

vim.cmd("AIStop")
assert(Session.get_current() == nil, "AIStop retained the current session")
assert(session.destroyed, "AIStop did not destroy the session")
assert(backend.cancelled, "AIStop did not cancel the backend")
assert(not vim.api.nvim_buf_is_valid(display_buf), "AIStop retained the display buffer")
assert(not vim.api.nvim_buf_is_valid(input_buf), "AIStop retained the input buffer")
assert(
    vim.wait(1000, function()
        return not chat.layout:valid()
    end),
    "AIStop did not close the chat"
)

vim.cmd("AIStop")

vim.cmd("AI")
local ctrl_c_session = assert(
    Session.get_current(),
    "AI did not create a session for Control-C"
)
local ctrl_c_chat = assert(
    ctrl_c_session.chat,
    "AI did not open the chat for Control-C"
)
local ctrl_c_backend = backend
local ctrl_c_display_buf = ctrl_c_session.display_buf
local ctrl_c_input_buf = ctrl_c_session.input_buf
vim.api.nvim_buf_set_lines(ctrl_c_input_buf, 0, -1, false, {
    "draft prompt",
})
ctrl_c_chat.input:focus()
vim.cmd("startinsert")
vim.api.nvim_feedkeys(vim.keycode("<C-c>"), "xt", false)

assert(
    vim.deep_equal(
        vim.api.nvim_buf_get_lines(ctrl_c_input_buf, 0, -1, false),
        { "" }
    ),
    "first Control-C did not clear the input"
)
assert(
    Session.get_current() == ctrl_c_session,
    "first Control-C stopped the session"
)
assert(not ctrl_c_backend.cancelled, "first Control-C cancelled the backend")
assert(ctrl_c_chat.layout:valid(), "first Control-C closed the chat")
assert(
    vim.api.nvim_get_current_win() == ctrl_c_chat.input.win,
    "first Control-C moved input focus"
)

vim.api.nvim_feedkeys(vim.keycode("<C-c>"), "xt", false)
assert(
    vim.wait(1000, function()
        return ctrl_c_session.destroyed
    end),
    "second Control-C did not stop the session"
)
assert(Session.get_current() == nil, "second Control-C retained the session")
assert(ctrl_c_backend.cancelled, "second Control-C did not cancel the backend")
assert(
    not vim.api.nvim_buf_is_valid(ctrl_c_display_buf),
    "second Control-C retained the display buffer"
)
assert(
    not vim.api.nvim_buf_is_valid(ctrl_c_input_buf),
    "second Control-C retained the input buffer"
)
assert(
    vim.wait(1000, function()
        return not ctrl_c_chat.layout:valid()
    end),
    "second Control-C did not close the chat"
)

print("Plugin command E2E checks passed")
vim.cmd("qa!")
