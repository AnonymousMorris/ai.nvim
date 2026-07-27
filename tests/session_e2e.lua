local repo = vim.fn.getcwd()
local snacks = vim.env.SNACKS_NVIM
    or (vim.fn.stdpath("data") .. "/lazy/snacks.nvim")

assert(vim.fn.isdirectory(snacks) == 1, "snacks.nvim is not installed")
vim.opt.runtimepath:prepend(snacks)
vim.opt.runtimepath:prepend(repo)
vim.cmd.runtime("plugin/ai.nvim.lua")

local Plugin = require("ai")
local AI = require("ai.ai")
local Events = require("ai.events")
local AIAction = Events.AIAction
local EventType = Events.Type
local Session = require("ai.session")

local notifications = {}
local original_notify = vim.notify
vim.notify = function(message, level)
    notifications[#notifications + 1] = {
        message = message,
        level = level,
    }
end

---@class ai.SubmitTestBackend: ai.Backend
local SubmitTestBackend = {}
SubmitTestBackend.__index = SubmitTestBackend

local fake_backend
function SubmitTestBackend.start(_, dispatch)
    fake_backend = setmetatable({
        dispatch = dispatch,
        events = {},
    }, SubmitTestBackend)
    return fake_backend
end

function SubmitTestBackend:send(event)
    if self.exited then
        return nil, "backend exited"
    end
    self.events[#self.events + 1] = event
    self.dispatch(event)
    self.dispatch({
        type = EventType.AI,
        action = AIAction.TEXT,
        content = "Reply: ",
    })
    self.dispatch({
        type = EventType.AI,
        action = AIAction.TEXT,
        content = event.content,
    })
    self.dispatch({
        type = EventType.AI,
        action = AIAction.DONE,
    })
    return true
end

function SubmitTestBackend:finish()
    return true
end

function SubmitTestBackend:cancel()
    self.cancelled = true
end

AI.register_backend("submit-test", SubmitTestBackend)

Plugin.setup({ backend = "submit-test" })

local buffer_count = #vim.api.nvim_list_bufs()
local missing_chat, start_err = Session.open_current({ backend = "missing" })
assert(missing_chat == nil, "invalid backend opened a chat")
assert(start_err == "unknown AI backend: missing", "invalid startup error")
assert(Session.get_current() == nil, "failed session became current")
assert(
    #vim.api.nvim_list_bufs() == buffer_count,
    "failed session leaked scratch buffers"
)
assert(
    vim.deep_equal(notifications[#notifications], {
        message = "Failed to start AI backend: unknown AI backend: missing",
        level = vim.log.levels.ERROR,
    }),
    "invalid startup notification was incorrect"
)

vim.cmd("AI")
local session = assert(Session.get_current())
local chat = assert(session.chat)
vim.api.nvim_buf_set_lines(chat.input.buf, 0, -1, false, {
    "hello from chat",
})
chat.input:focus()
vim.cmd("startinsert")
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "xt", false)

assert(
    vim.wait(1000, function()
        return #fake_backend.events == 1
    end),
    "chat submission did not complete"
)

assert(chat.layout:valid(), "chat closed after submission")
assert(
    vim.api.nvim_get_current_win() == chat.input.win,
    "input did not retain focus after submission"
)
assert(session.ai, "submission did not create a session AI")
assert(session.ai.backend == fake_backend, "session stored the wrong backend")
assert(
    vim.deep_equal(fake_backend.events, {
        {
            type = EventType.USER,
            content = "hello from chat",
        },
    }),
    "submission did not reach the backend"
)
assert(
    vim.deep_equal(
        vim.api.nvim_buf_get_lines(session.display_buf, 0, -1, false),
        {
            "---",
            "user: hello from chat",
            "---",
            "agent: Reply: hello from chat",
            "---",
            "",
        }
    ),
    "backend output was not rendered"
)
assert(
    vim.bo[session.display_buf].modifiable == false,
    "display buffer was left modifiable"
)
assert(
    vim.deep_equal(
        vim.api.nvim_buf_get_lines(session.input_buf, 0, -1, false),
        { "" }
    ),
    "input was not cleared after submission"
)

fake_backend.dispatch({
    type = EventType.ERROR,
    message = "backend exploded",
    source = "agent",
})
local error_notification
assert(
    vim.wait(1000, function()
        for _, notification in ipairs(notifications) do
            if notification.message == "AI error: backend exploded" then
                error_notification = notification
                return true
            end
        end
        return false
    end),
    "AI error did not produce a notification"
)
assert(
    vim.deep_equal(error_notification, {
        message = "AI error: backend exploded",
        level = vim.log.levels.ERROR,
    }),
    "AI error notification was incorrect: " .. vim.inspect(error_notification)
)

local first_backend = fake_backend
first_backend.exited = true
first_backend.dispatch({
    type = EventType.EXIT,
    result = { code = 0, signal = 0 },
})
assert(session.ai.backend == first_backend, "session detached the exited backend")

vim.api.nvim_buf_set_lines(chat.input.buf, 0, -1, false, {
    "second request",
})
chat.input:focus()
vim.cmd("startinsert")
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "xt", false)

assert(
    vim.wait(1000, function()
        return session.ai.status == "error"
    end),
    "submission after backend exit did not report an error"
)
assert(
    vim.deep_equal(notifications[#notifications], {
        message = "AI error: backend exited",
        level = vim.log.levels.ERROR,
    }),
    "submission error notification was incorrect"
)
assert(fake_backend == first_backend, "submission replaced the exited backend")
assert(
    vim.deep_equal(fake_backend.events, {
        {
            type = EventType.USER,
            content = "hello from chat",
        },
    }),
    "exited backend accepted another message"
)
vim.notify = original_notify

chat:close()
assert(
    vim.wait(1000, function()
        return not chat.layout:valid()
    end),
    "chat did not close explicitly"
)
assert(session.chat == nil, "closed chat UI remained attached to the session")

print("Session submission E2E checks passed")
vim.cmd("qa!")
