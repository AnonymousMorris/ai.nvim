local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)

local Command = require("ai.pi.command")

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

assert_equal(Command.build({
    binary = "~/bin/pi",
    extensions = false,
    skills = false,
    provider = "test-provider",
    model = "test-model",
    thinking = "high",
    system_prompt = "system prompt",
    append_system_prompt = { "first append", "second append" },
}), {
    vim.fn.expand("~/bin/pi"),
    "--mode",
    "rpc",
    "--no-session",
    "--no-extensions",
    "--no-skills",
    "--provider",
    "test-provider",
    "--model",
    "test-model",
    "--thinking",
    "high",
    "--system-prompt",
    "system prompt",
    "--append-system-prompt",
    "first append",
    "--append-system-prompt",
    "second append",
}, "Pi command")

assert_equal(Command.build({
    binary = "pi",
    extensions = true,
    skills = true,
    append_system_prompt = "single append",
}), {
    "pi",
    "--mode",
    "rpc",
    "--no-session",
    "--append-system-prompt",
    "single append",
}, "Pi command with optional features")

local command_override = { "custom-pi", "--custom" }
local overridden_command = Command.build({ cmd = command_override })
assert_equal(overridden_command, command_override, "Pi command override")
assert(overridden_command ~= command_override, "Pi command override was not copied")

local missing_options_ok, missing_options_err = pcall(Command.build)
assert_equal(missing_options_ok, false, "missing Pi options validation")
assert(
    tostring(missing_options_err):find("Pi options are required", 1, true),
    "missing Pi options error"
)

local missing_binary_ok, missing_binary_err = pcall(Command.build, {})
assert_equal(missing_binary_ok, false, "missing Pi binary validation")
assert(
    tostring(missing_binary_err):find(
        "Pi binary must be a non-empty string",
        1,
        true
    ),
    "missing Pi binary error"
)

local list_binary_ok, list_binary_err = pcall(Command.build, {
    binary = { "pi", "--profile", "test" },
})
assert_equal(list_binary_ok, false, "list Pi binary validation")
assert(
    tostring(list_binary_err):find(
        "Pi binary must be a non-empty string",
        1,
        true
    ),
    "list Pi binary error"
)

print("Pi command E2E checks passed")
vim.cmd("qa!")
