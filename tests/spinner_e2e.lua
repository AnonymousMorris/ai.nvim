local repo = vim.fn.getcwd()
local snacks = vim.env.SNACKS_NVIM
    or (vim.fn.stdpath("data") .. "/lazy/snacks.nvim")

assert(vim.fn.isdirectory(snacks) == 1, "snacks.nvim is not installed")
vim.opt.runtimepath:prepend(snacks)
vim.opt.runtimepath:prepend(repo)

local AI = require("ai.ai")
local Events = require("ai.events")
local Session = require("ai.session")

local AIAction = Events.AIAction
local EventType = Events.Type
local Role = Events.Role

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

---@class ai.SpinnerTestBackend: ai.Backend
local SpinnerTestBackend = {}
SpinnerTestBackend.__index = SpinnerTestBackend

local fake_backend
function SpinnerTestBackend.start(_, dispatch)
    fake_backend = setmetatable({
        dispatch = dispatch,
        events = {},
    }, SpinnerTestBackend)
    return fake_backend
end

function SpinnerTestBackend:send(event)
    self.events[#self.events + 1] = event
    self.dispatch(event)
    self.dispatch({
        type = EventType.AI,
        action = AIAction.THINKING,
    })
    return true
end

function SpinnerTestBackend:interrupt()
    self.dispatch({
        type = EventType.AI,
        action = AIAction.DONE,
    })
    return true
end

function SpinnerTestBackend:finish()
    return true
end

function SpinnerTestBackend:cancel()
    self.dispatch({
        type = EventType.EXIT,
        result = { code = 0, signal = 15 },
    })
end

AI.register_backend("spinner-test", SpinnerTestBackend)

local session = assert(Session.new({ backend = "spinner-test" }))
local ai = session.ai
local transcript = ai.transcript
assert(ai:send("inspect this"))

local function line(row)
    return vim.api.nvim_buf_get_lines(
        session.display_buf,
        row,
        row + 1,
        false
    )[1]
end

local thinking_row = assert(
    transcript.spinner.row,
    "thinking status row was not created"
)
assert_equal(transcript.spinner.state, "thinking", "thinking spinner state")
local thinking_timer = transcript.spinner.timer
fake_backend.dispatch({
    type = EventType.AI,
    action = AIAction.THINKING,
})
assert(
    transcript.spinner.timer == thinking_timer,
    "repeated thinking restarted the spinner"
)
local first_thinking_frame = line(thinking_row)
assert(first_thinking_frame:find("Thinking...", 1, true), "thinking status was not rendered")
assert(
    vim.wait(500, function()
        return line(thinking_row) ~= first_thinking_frame
    end),
    "thinking spinner did not advance"
)

fake_backend.dispatch({
    type = EventType.AI,
    action = AIAction.TOOL_START,
    tool = "read",
})
local tool_row = assert(
    transcript.spinner.row,
    "tool status row was not created"
)
assert_equal(transcript.spinner.state, "tool", "tool spinner state")
assert_equal(transcript.spinner.detail, "read", "tool spinner detail")
local first_tool_frame = line(tool_row)
assert(first_tool_frame:find("Calling tool: read...", 1, true), "tool status was not rendered")
assert(
    vim.wait(500, function()
        return line(tool_row) ~= first_tool_frame
    end),
    "tool spinner did not advance"
)

fake_backend.dispatch({
    type = EventType.AI,
    action = AIAction.TOOL_END,
    tool = "read",
})
assert_equal(line(tool_row), "✓ Tool complete: read", "completed tool status")
assert_equal(transcript.spinner.state, "thinking", "resumed spinner state")
assert(
    transcript.spinner.row == tool_row + 1,
    "thinking status did not follow completed tool"
)
assert(
    line(transcript.spinner.row):find("Thinking...", 1, true),
    "thinking did not resume after tool"
)

fake_backend.dispatch({
    type = EventType.AI,
    action = AIAction.TEXT,
    content = "Finished",
})
assert_equal(transcript.spinner.state, nil, "spinner state after agent text")
assert_equal(transcript.spinner.row, nil, "status row after agent text")
assert_equal(transcript.spinner.timer, nil, "spinner timer after agent text")
assert_equal(transcript.role, Role.AGENT, "role during agent text")
assert_equal(line(tool_row + 1), "agent: Finished", "agent replaced thinking status")

fake_backend.dispatch({
    type = EventType.AI,
    action = AIAction.THINKING,
})
assert_equal(ai.status, "thinking", "thinking AI status after agent text")
assert_equal(transcript.spinner.state, "thinking", "thinking resumed after agent text")
assert(
    line(assert(transcript.spinner.row)):find("Thinking...", 1, true),
    "thinking status was not rendered after agent text"
)

assert(ai:interrupt())
assert_equal(transcript.role, nil, "role after interruption")
assert_equal(ai.status, "idle", "AI status after interruption")
assert_equal(session.destroyed, false, "interrupt destroyed the session")
assert_equal(fake_backend.cancelled, nil, "interrupt cancelled the backend")
assert_equal(
    vim.api.nvim_buf_get_lines(session.display_buf, 0, -1, false),
    {
        "---",
        "user: inspect this",
        "---",
        "✓ Tool complete: read",
        "agent: Finished",
        "---",
        "",
    },
    "spinner transcript"
)

print("Spinner E2E checks passed")
vim.cmd("qa!")
