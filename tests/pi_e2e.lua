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
for _, method in ipairs({ "send", "finish", "cancel" }) do
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
