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
function CommandTestBackend.start(_, dispatch)
    backend = setmetatable({ dispatch = dispatch }, CommandTestBackend)
    return backend
end

function CommandTestBackend:send(event, mode)
    self.delivery_modes = self.delivery_modes or {}
    self.delivery_modes[#self.delivery_modes + 1] = mode
    self.dispatch(event)
    self.dispatch({ type = "ai", action = "thinking" })
    return true
end

function CommandTestBackend:interrupt()
    self.interrupts = (self.interrupts or 0) + 1
    self.dispatch({ type = "ai", action = "done" })
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

local function find_global_mapping(mode, lhs)
    for _, mapping in ipairs(vim.api.nvim_get_keymap(mode)) do
        if mapping.lhs == lhs then
            return mapping
        end
    end
end

assert(
    find_global_mapping("n", "\\ai") == nil,
    "setup registered a default normal AI keymap"
)
assert(
    find_global_mapping("x", "\\ai") == nil,
    "setup registered a default visual AI keymap"
)

vim.cmd("AI")
local session = assert(Session.get_current(), "AI did not create a session")
local chat = assert(session.chat, "AI did not open the chat")
local display_buf = session.display_buf
local input_buf = session.input_buf
assert(Session.open_current() == chat, "AI command duplicated the open chat")
assert(session:submit("old session"))
assert(session.ai.status == "thinking", "Control-N test turn was not active")
assert(
    vim.deep_equal(backend.delivery_modes, { "prompt" }),
    "idle message was not sent as a prompt"
)
vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, {
    "steer the active turn",
})
chat.input:execute("confirm")
assert(
    vim.wait(1000, function()
        return #backend.delivery_modes == 2
    end),
    "active-turn chat submission did not reach the backend"
)
assert(
    vim.deep_equal(backend.delivery_modes, { "prompt", "steer" }),
    "active-turn chat submission was not sent as steering"
)
vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "discarded draft" })

local previous_backend = backend
chat.input:focus()
vim.cmd("startinsert")
vim.api.nvim_feedkeys(vim.keycode("<C-n>"), "xt", false)

assert(
    vim.wait(1000, function()
        return Session.get_current() ~= session
    end),
    "Control-N did not create a new session"
)
local new_session = assert(Session.get_current(), "Control-N removed the current session")
local new_chat = assert(new_session.chat, "Control-N did not open the new chat")
assert(session.destroyed, "Control-N did not destroy the previous session")
assert(previous_backend.cancelled, "Control-N did not cancel the previous backend")
assert(not vim.api.nvim_buf_is_valid(display_buf), "Control-N retained the old display buffer")
assert(not vim.api.nvim_buf_is_valid(input_buf), "Control-N retained the old input buffer")
assert(
    vim.wait(1000, function()
        return not chat.layout:valid()
    end),
    "Control-N did not close the previous chat"
)
assert(new_chat.layout:valid(), "Control-N did not show the new chat")
assert(
    vim.api.nvim_get_current_win() == new_chat.input.win,
    "Control-N did not focus the new input"
)
assert(
    vim.deep_equal(
        vim.api.nvim_buf_get_lines(new_session.display_buf, 0, -1, false),
        { "" }
    ),
    "Control-N retained the old transcript"
)
assert(
    vim.deep_equal(
        vim.api.nvim_buf_get_lines(new_session.input_buf, 0, -1, false),
        { "" }
    ),
    "Control-N retained the old input"
)

local new_backend = backend
local new_display_buf = new_session.display_buf
local new_input_buf = new_session.input_buf
vim.cmd("AIStop")
assert(Session.get_current() == nil, "AIStop retained the current session")
assert(new_session.destroyed, "AIStop did not destroy the session")
assert(new_backend.cancelled, "AIStop did not cancel the backend")
assert(not vim.api.nvim_buf_is_valid(new_display_buf), "AIStop retained the display buffer")
assert(not vim.api.nvim_buf_is_valid(new_input_buf), "AIStop retained the input buffer")
assert(
    vim.wait(1000, function()
        return not new_chat.layout:valid()
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
assert(ctrl_c_session:submit("active turn"))
assert(ctrl_c_session.ai.status == "thinking", "Control-C turn was not active")
vim.api.nvim_buf_set_lines(ctrl_c_input_buf, 0, -1, false, {
    "draft prompt",
})
ctrl_c_chat.input:focus()
vim.cmd("startinsert")
vim.api.nvim_feedkeys(vim.keycode("<C-c>"), "xt", false)

assert(ctrl_c_backend.interrupts == nil, "input clear interrupted the turn")
assert(
    vim.deep_equal(
        vim.api.nvim_buf_get_lines(ctrl_c_input_buf, 0, -1, false),
        { "" }
    ),
    "first Control-C did not clear the input draft"
)
assert(
    ctrl_c_session.ai.status == "thinking",
    "input clear settled the active turn"
)

vim.api.nvim_feedkeys(vim.keycode("<C-c>"), "xt", false)
assert(ctrl_c_backend.interrupts == 1, "second Control-C did not interrupt the turn")
assert(
    Session.get_current() == ctrl_c_session,
    "Control-C replaced the current session"
)
assert(not ctrl_c_session.destroyed, "Control-C destroyed the session")
assert(not ctrl_c_backend.cancelled, "Control-C cancelled the backend process")
assert(ctrl_c_session.ai.status == "idle", "interrupted turn did not settle")
assert(vim.api.nvim_buf_is_valid(ctrl_c_display_buf), "Control-C deleted display buffer")
assert(vim.api.nvim_buf_is_valid(ctrl_c_input_buf), "Control-C deleted input buffer")
assert(ctrl_c_chat.layout:valid(), "Control-C closed the chat")
assert(
    vim.api.nvim_get_current_win() == ctrl_c_chat.input.win,
    "Control-C moved input focus"
)

vim.cmd("AIStop")
assert(ctrl_c_session.destroyed, "AIStop did not clean up interrupted session")

print("Plugin command E2E checks passed")
vim.cmd("qa!")
