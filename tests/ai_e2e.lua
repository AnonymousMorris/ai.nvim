local repo = vim.fn.getcwd()
local snacks = vim.env.SNACKS_NVIM
    or (vim.fn.stdpath("data") .. "/lazy/snacks.nvim")

assert(vim.fn.isdirectory(snacks) == 1, "snacks.nvim is not installed")
vim.opt.runtimepath:prepend(snacks)
vim.opt.runtimepath:prepend(repo)

local AI = require("ai.ai")
local Display = require("ai.ui.display")
local Events = require("ai.events")
local AIAction = Events.AIAction
local EventType = Events.Type
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

local script = [=[
IFS= read -r first
case "$first" in
    *'"id":"prompt_1"'*'"message":"first"'*'"type":"prompt"'* | \
    *'"id":"prompt_1"'*'"type":"prompt"'*'"message":"first"'* | \
    *'"message":"first"'*'"id":"prompt_1"'*'"type":"prompt"'* | \
    *'"message":"first"'*'"type":"prompt"'*'"id":"prompt_1"'* | \
    *'"type":"prompt"'*'"id":"prompt_1"'*'"message":"first"'* | \
    *'"type":"prompt"'*'"message":"first"'*'"id":"prompt_1"'*) ;;
    *)
        printf 'unexpected first prompt: %s\n' "$first" >&2
        exit 2
        ;;
esac
printf '%s\n' '{"id":"prompt_1","type":"response","command":"prompt","success":true}'
printf '%s\n' '{"type":"agent_start"}'
printf '%s\n' '{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta"}}'
printf '%s\n' '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"Hello world\n"}}'
printf '%s\n' '{"type":"agent_end"}'
printf '%s\n' '{"type":"agent_settled"}'

IFS= read -r second
case "$second" in
    *'"id":"prompt_2"'*'"message":"second"'*'"type":"prompt"'* | \
    *'"id":"prompt_2"'*'"type":"prompt"'*'"message":"second"'* | \
    *'"message":"second"'*'"id":"prompt_2"'*'"type":"prompt"'* | \
    *'"message":"second"'*'"type":"prompt"'*'"id":"prompt_2"'* | \
    *'"type":"prompt"'*'"id":"prompt_2"'*'"message":"second"'* | \
    *'"type":"prompt"'*'"message":"second"'*'"id":"prompt_2"'*) ;;
    *)
        printf 'unexpected second prompt: %s\n' "$second" >&2
        exit 3
        ;;
esac
printf '%s\n' '{"id":"prompt_2","type":"response","command":"prompt","success":true}'
printf '%s\n' '{"type":"agent_start"}'
printf '%s\n' '{"type":"tool_execution_start","toolName":"read"}'
printf '%s\n' '{"type":"tool_execution_end","toolName":"read"}'
printf '%s\n' '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"Second response"}}'
printf '%s\n' '{"type":"agent_end"}'
printf '%s\n' '{"type":"agent_settled"}'
IFS= read -r _ || true
]=]

local session = assert(Session.new({
    backend = "pi",
    cmd = { "/bin/sh", "-c", script },
}))
local display = Display.display({ buf = session.display_buf })
assert_equal(display.opts.buf, session.display_buf, "configured display buffer")
local ai = session.ai
assert_equal(session.ai, ai, "session AI")
assert_equal(ai.session, nil, "AI does not own its session")
assert_equal(ai.backend_name, "pi", "backend name")
assert(ai.backend.process, "AI backend does not own a process")

assert(ai:send("first"))
assert(
    vim.wait(2000, function()
        local lines = vim.api.nvim_buf_get_lines(
            session.display_buf,
            0,
            -1,
            false
        )
        return ai.status == "idle"
            and vim.tbl_contains(lines, "agent: Hello world")
    end),
    "first AI request did not finish"
)

assert(ai:send("second"))
assert(
    vim.wait(2000, function()
        local lines = vim.api.nvim_buf_get_lines(
            session.display_buf,
            0,
            -1,
            false
        )
        return ai.status == "idle"
            and vim.tbl_contains(lines, "agent: Second response")
    end),
    "second AI request did not finish"
)
assert(ai:finish())
assert(
    vim.wait(2000, function()
        return ai.result ~= nil
    end),
    "AI backend did not exit"
)

assert_equal(
    vim.api.nvim_buf_get_lines(session.display_buf, 0, -1, false),
    {
        "---",
        "user: first",
        "---",
        "agent: Hello world",
        "---",
        "user: second",
        "---",
        "✓ Tool complete: read",
        "agent: Second response",
        "---",
        "",
    },
    "AI display output"
)
assert_equal(vim.bo[session.display_buf].modifiable, false, "display modifiable")
assert_equal(ai.status, "exited", "final AI status")
assert_equal(ai.result.code, 0, "AI backend exit code")
assert_equal(session.ai, ai, "session retains its AI")

local missing, err = AI.start(session.display_buf, { backend = "missing" })
assert_equal(missing, nil, "unknown backend result")
assert_equal(err, "unknown AI backend: missing", "unknown backend error")

local rejected_script = [=[
IFS= read -r request
printf '%s\n' '{"id":"prompt_1","type":"response","command":"prompt","success":false,"error":"prompt rejected"}'
IFS= read -r _ || true
]=]
local rejected_session = assert(Session.new({
    backend = "pi",
    cmd = { "/bin/sh", "-c", rejected_script },
}))
local rejected_ai = rejected_session.ai
assert_equal(session.destroyed, true, "replaced session state")
assert_equal(Session.get_current(), rejected_session, "selected rejected session")
local rejected_notification
local rejected_original_notify = vim.notify
vim.notify = function(message, level)
    rejected_notification = { message = message, level = level }
end
assert(rejected_ai:send("do not record this"))
assert(
    vim.wait(2000, function()
        return rejected_ai.status == "error"
    end),
    "rejected prompt did not report an error"
)
vim.notify = rejected_original_notify
assert_equal(
    vim.api.nvim_buf_get_lines(rejected_session.display_buf, 0, -1, false),
    { "" },
    "rejected prompt transcript"
)
assert_equal(rejected_ai.error, "prompt rejected", "rejected prompt error")
assert_equal(
    rejected_ai.backend.pending_prompts,
    {},
    "pending prompts after rejection"
)
assert_equal(rejected_notification, {
    message = "AI error: prompt rejected",
    level = vim.log.levels.ERROR,
}, "rejected prompt notification")
assert(rejected_ai:finish())
assert(
    vim.wait(2000, function()
        return rejected_ai.result ~= nil
    end),
    "rejected prompt backend did not exit"
)

---@class ai.FakeBackend: ai.Backend
local FakeBackend = {}
FakeBackend.__index = FakeBackend

local fake_backend
function FakeBackend.start(_, dispatch)
    fake_backend = setmetatable({
        dispatch = dispatch,
        events = {},
    }, FakeBackend)
    return fake_backend
end

function FakeBackend:send(event)
    self.events[#self.events + 1] = event
    self.dispatch(event)
    self.dispatch({
        type = EventType.AI,
        action = AIAction.DONE,
    })
    return true
end

function FakeBackend:interrupt()
    self.interrupted = true
    self.dispatch({
        type = EventType.AI,
        action = AIAction.DONE,
    })
    return true
end

function FakeBackend:finish()
    self.finished = true
    return true
end

function FakeBackend:cancel()
    self.dispatch({
        type = EventType.EXIT,
        result = { code = 143, signal = 15 },
    })
end

AI.register_backend("fake", FakeBackend)

local fake_session = assert(Session.new({
    backend = "fake",
}))
local fake_ai = fake_session.ai
local fake_display_buf = fake_session.display_buf
local fake_input_buf = fake_session.input_buf
assert_equal(rejected_session.destroyed, true, "replaced rejected session state")
assert_equal(Session.get_current(), fake_session, "selected fake session")
assert_equal(fake_ai.backend, fake_backend, "custom backend instance")
assert(fake_ai:send("backend-neutral message"))
assert_equal(fake_backend.events, {
    {
        type = EventType.USER,
        content = "backend-neutral message",
    },
}, "custom backend user event")
assert(fake_ai:interrupt())
assert_equal(fake_backend.interrupted, true, "backend-neutral interrupt")
assert_equal(fake_ai.status, "idle", "status after backend-neutral interrupt")
local backend_notification
local original_notify = vim.notify
vim.notify = function(message, level)
    backend_notification = { message = message, level = level }
end
fake_backend.dispatch({
    type = EventType.ERROR,
    message = "backend exploded",
    source = "protocol",
})
vim.notify = original_notify
assert_equal(fake_ai.status, "error", "backend error status")
assert_equal(fake_ai.error, "backend exploded", "backend error state")
assert_equal(backend_notification, {
    message = "AI error: backend exploded",
    level = vim.log.levels.ERROR,
}, "backend error notification")
assert(fake_ai:finish())
assert_equal(fake_backend.finished, true, "custom backend finish")
assert(fake_session:destroy())
assert_equal(fake_ai.status, "cancelled", "backend-neutral cancelled status")
assert_equal(
    fake_ai.result,
    { code = 143, signal = 15 },
    "backend-neutral cancelled result"
)
assert_equal(fake_session.ai, fake_ai, "destroyed session AI invariant")
assert_equal(fake_session.destroyed, true, "destroyed session state")
assert_equal(Session.get_current(), nil, "current session after shutdown")
assert(
    not vim.api.nvim_buf_is_valid(fake_display_buf)
        and not vim.api.nvim_buf_is_valid(fake_input_buf),
    "destroyed session retained its buffers"
)

print("AI E2E checks passed")
vim.cmd("qa!")
