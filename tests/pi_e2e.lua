local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)

local Pi = require("ai.pi")
local Command = require("ai.pi.command")
local Events = require("ai.events")
local AIAction = Events.AIAction
local EventType = Events.Type

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

assert(Pi.get_cmd == Command.build, "Pi command builder compatibility alias")

local script = [=[
IFS= read -r request
case "$request" in
    *'"id":"prompt_1"'*'"type":"prompt"'* | \
    *'"type":"prompt"'*'"id":"prompt_1"'*) ;;
    *)
        printf 'unexpected payload envelope: %s\n' "$request" >&2
        exit 2
        ;;
esac
case "$request" in
    *'"message":"alpha\n\nhello"'*) ;;
    *)
        printf 'unexpected payload message: %s\n' "$request" >&2
        exit 2
        ;;
esac
IFS= read -r release
if [ "$release" != "release" ]; then
    printf 'unexpected release: %s\n' "$release" >&2
    exit 3
fi

printf '%s\n' '{"id":"prompt_1","type":"response","command":"prompt","success":true}'
printf '%s\n' '{"type":"agent_start"}'
printf '%s' '{"type":"message_update","assistantMessageEvent":'
sleep 0.02
printf '%s\n' '{"type":"thinking_delta"}}'
printf '%s\n' '{"type":"tool_execution_start","toolName":"read"}'
printf '%s\n' '{"type":"tool_execution_end","toolName":"read"}'
printf '%s\n' 'not json'
printf '%s\n' 'first warning' >&2
printf '%s\n' '{"warning":"json-shaped stderr"}' >&2
printf '%s' 'warning tail' >&2
printf '%s\n' '{"type":"agent_end"}'
printf '%s\n' '{"type":"agent_settled"}'
]=]

local events = {}
local errors = {}
local exits = {}
local pi
local start_err
pi, start_err = Pi.start(
    { cmd = { "/bin/sh", "-c", script } },
    function(event)
        if event.type == EventType.USER or event.type == EventType.AI then
            events[#events + 1] = event
            if event.type == EventType.AI and event.action == AIAction.DONE then
                pi:finish()
            end
        elseif event.type == EventType.ERROR then
            errors[#errors + 1] = event
        elseif event.type == EventType.EXIT then
            exits[#exits + 1] = event.result
        else
            error("unknown backend event: " .. vim.inspect(event))
        end
    end
)

assert(pi, start_err)
for _, method in ipairs({ "send", "interrupt", "finish", "cancel" }) do
    assert(
        type(pi[method]) == "function",
        ("Pi backend must implement %s()"):format(method)
    )
end
local user_event = {
    type = EventType.USER,
    content = "alpha\n\nhello",
}
assert(pi:send(user_event))
assert_equal(events, {}, "events before prompt acceptance")
assert_equal(pi.pending_prompts, {
    prompt_1 = user_event,
}, "pending prompt before acceptance")
assert(pi:write("release\n"))
assert(
    vim.wait(2000, function()
        return pi.result ~= nil
    end),
    "Pi process did not exit"
)

assert_equal(events, {
    user_event,
    { type = EventType.AI, action = AIAction.THINKING },
    { type = EventType.AI, action = AIAction.THINKING },
    {
        type = EventType.AI,
        action = AIAction.TOOL_START,
        tool = "read",
    },
    {
        type = EventType.AI,
        action = AIAction.TOOL_END,
        tool = "read",
    },
    { type = EventType.AI, action = AIAction.DONE },
}, "normalized events")
assert_equal(errors, {
    {
        type = EventType.ERROR,
        message = "not json",
        source = "protocol",
    },
}, "stdout errors")
assert_equal(
    exits[1].stderr,
    'first warning\n{"warning":"json-shaped stderr"}\nwarning tail',
    "captured stderr"
)
assert_equal(#exits, 1, "exit callback count")
assert_equal(exits[1].code, 0, "exit code")
assert(pi.process, "Pi object does not own its process")
assert_equal(pi.stdin_closed, true, "closed stdin")
assert_equal(pi.pending_prompts, {}, "pending prompts after acceptance")

local interrupt_script = [=[
IFS= read -r first
case "$first" in
    *'"id":"prompt_1"'*'"type":"prompt"'* | \
    *'"type":"prompt"'*'"id":"prompt_1"'*) ;;
    *)
        printf 'unexpected interrupt test prompt: %s\n' "$first" >&2
        exit 2
        ;;
esac
printf '%s\n' '{"id":"prompt_1","type":"response","command":"prompt","success":true}'
printf '%s\n' '{"type":"agent_start"}'

IFS= read -r interrupt
case "$interrupt" in
    *'"type":"abort"'*) ;;
    *)
        printf 'unexpected interrupt command: %s\n' "$interrupt" >&2
        exit 3
        ;;
esac
printf '%s\n' '{"type":"response","command":"abort","success":true}'
printf '%s\n' '{"type":"agent_end","messages":[],"willRetry":false}'
printf '%s\n' '{"type":"agent_settled"}'

IFS= read -r second
case "$second" in
    *'"id":"prompt_2"'*'"type":"prompt"'* | \
    *'"type":"prompt"'*'"id":"prompt_2"'*) ;;
    *)
        printf 'unexpected post-interrupt prompt: %s\n' "$second" >&2
        exit 4
        ;;
esac
printf '%s\n' '{"id":"prompt_2","type":"response","command":"prompt","success":true}'
printf '%s\n' '{"type":"agent_start"}'
printf '%s\n' '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"still alive"}}'
printf '%s\n' '{"type":"agent_end","messages":[],"willRetry":false}'
printf '%s\n' '{"type":"agent_settled"}'
IFS= read -r _ || true
]=]

local interrupt_events = {}
local interrupt_errors = {}
local interrupt_pi = assert(Pi.start(
    { cmd = { "/bin/sh", "-c", interrupt_script } },
    function(event)
        if event.type == EventType.USER or event.type == EventType.AI then
            interrupt_events[#interrupt_events + 1] = event
        elseif event.type == EventType.ERROR then
            interrupt_errors[#interrupt_errors + 1] = event
        end
    end
))
assert(interrupt_pi:send({ type = EventType.USER, content = "interrupt me" }))
assert(
    vim.wait(2000, function()
        return vim.deep_equal(interrupt_events[#interrupt_events], {
            type = EventType.AI,
            action = AIAction.THINKING,
        })
    end),
    "interrupt test turn did not start"
)
assert(interrupt_pi:interrupt())
assert(
    vim.wait(2000, function()
        return vim.deep_equal(interrupt_events[#interrupt_events], {
            type = EventType.AI,
            action = AIAction.DONE,
        })
    end),
    "interrupted Pi turn did not settle"
)
assert_equal(interrupt_pi.cancelled, false, "interrupt cancelled Pi process")
assert_equal(interrupt_pi.result, nil, "interrupt exited Pi process")
assert_equal(interrupt_pi.stdin_closed, false, "interrupt closed Pi stdin")
assert(interrupt_pi:send({ type = EventType.USER, content = "continue" }))
assert(
    vim.wait(2000, function()
        return #interrupt_events == 7
            and vim.deep_equal(interrupt_events[#interrupt_events], {
                type = EventType.AI,
                action = AIAction.DONE,
            })
    end),
    "Pi did not complete a prompt after interruption"
)
assert(interrupt_pi:finish())
assert(
    vim.wait(2000, function()
        return interrupt_pi.result ~= nil
    end),
    "interrupted Pi process did not finish normally"
)
assert_equal(interrupt_errors, {}, "Pi interrupt errors")
assert_equal(interrupt_pi.result.code, 0, "interrupted Pi exit code")
assert_equal(interrupt_events, {
    { type = EventType.USER, content = "interrupt me" },
    { type = EventType.AI, action = AIAction.THINKING },
    { type = EventType.AI, action = AIAction.DONE },
    { type = EventType.USER, content = "continue" },
    { type = EventType.AI, action = AIAction.THINKING },
    { type = EventType.AI, action = AIAction.TEXT, content = "still alive" },
    { type = EventType.AI, action = AIAction.DONE },
}, "Pi events across interruption")

local partial_line = '{"type":"agent_'
local cancelled_pi = assert(Pi.start(
    {
        cmd = {
            "/bin/sh",
            "-c",
            "printf '%s' '" .. partial_line .. "'; exec sleep 10",
        },
    },
    function() end
))
assert(
    vim.wait(1000, function()
        return cancelled_pi.stdout_tail == partial_line
    end),
    "partial stdout line was not stored on the Pi instance"
)
cancelled_pi:cancel()
assert_equal(cancelled_pi.stdout_tail, "", "stdout tail after cancellation")
assert(
    vim.wait(2000, function()
        return cancelled_pi.result ~= nil
    end),
    "cancelled Pi process did not exit"
)
assert_equal(cancelled_pi.cancelled, true, "cancelled state")
assert_equal(cancelled_pi.result.code, 0, "cancelled exit code")
assert_equal(cancelled_pi.result.signal, 15, "cancelled signal")

print("Pi E2E checks passed")
vim.cmd("qa!")
