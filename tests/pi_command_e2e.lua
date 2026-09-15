local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)

local Command = require("ai.pi.command")
local Config = require("ai.config")

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

assert_equal(Command.build(Config.backend()), {
    "pi",
    "--mode",
    "rpc",
    "--no-session",
    "--no-skills",
    "--thinking",
    "off",
}, "defaults select no skills and append no custom prompt")

assert_equal(Command.build(Config.backend({
    binary = "~/bin/pi",
    extensions = false,
    skills = false,
    skill_paths = { "~/skills/writing/SKILL.md", "project skills" },
    provider = "test-provider",
    model = "test-model",
    thinking = "high",
    system_prompt = "system prompt",
    append_system_prompt = { "Keep $HOME and {{name}} literal", "~/prompts/style.md" },
})), {
    vim.fn.expand("~/bin/pi"),
    "--mode",
    "rpc",
    "--no-session",
    "--no-extensions",
    "--no-skills",
    "--skill",
    vim.fn.expand("~/skills/writing/SKILL.md"),
    "--skill",
    "project skills",
    "--provider",
    "test-provider",
    "--model",
    "test-model",
    "--thinking",
    "high",
    "--system-prompt",
    "system prompt",
    "--append-system-prompt",
    "Keep $HOME and {{name}} literal\n\n~/prompts/style.md",
}, "Pi command uses configured skills and prompts")

assert_equal(Command.build({
    binary = "pi",
    extensions = true,
    skills = true,
    skill_paths = { "extra-skills" },
    append_system_prompt = "/tmp/writing instructions.md",
}), {
    "pi",
    "--mode",
    "rpc",
    "--no-session",
    "--skill",
    "extra-skills",
    "--append-system-prompt",
    "/tmp/writing instructions.md",
}, "Pi command with optional features")

local literal_skill_paths = {
    "#notes/SKILL.md",
    "%notes/SKILL.md",
    "skills/$HOME/SKILL.md",
    "lua/ai/*.lua",
    "lua/ai/[cp]*.lua",
}
assert_equal(Command.build({
    binary = "pi",
    extensions = true,
    skills = true,
    skill_paths = literal_skill_paths,
}), {
    "pi",
    "--mode",
    "rpc",
    "--no-session",
    "--skill",
    literal_skill_paths[1],
    "--skill",
    literal_skill_paths[2],
    "--skill",
    literal_skill_paths[3],
    "--skill",
    literal_skill_paths[4],
    "--skill",
    literal_skill_paths[5],
}, "Pi command preserves literal skill paths")

for _, paths in ipairs({ "skills", false, { named = "skills" }, { [2] = "skills" } }) do
    local ok, err = pcall(Command.build, { binary = "pi", skill_paths = paths })
    assert_equal(ok, false, "invalid skill_paths validation")
    assert(
        tostring(err):find("skill_paths must be a list of paths", 1, true),
        "invalid skill_paths error"
    )
end

assert_equal(
    Command.build(Config.backend({ skill_paths = { "", "local-skills", "" } })),
    Command.build(Config.backend({ skill_paths = { "local-skills" } })),
    "empty skill paths are ignored"
)

for _, path in ipairs({ false, 42 }) do
    local ok, err = pcall(Command.build, { binary = "pi", skill_paths = { path } })
    assert_equal(ok, false, "invalid skill path validation")
    assert(
        tostring(err):find("skill_paths entries must be strings", 1, true),
        "invalid skill path error"
    )
end

local command_override = { "custom-pi", "--custom" }
for _, url in ipairs({ "https://example.com/SKILL.md", "http://example.com/SKILL.md" }) do
    local ok, err = pcall(Command.build, { binary = "pi", skill_paths = { url } })
    assert_equal(ok, false, "skill URL validation")
    assert(tostring(err):find("skill_paths entries must be local paths", 1, true), "skill URL error")
end

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
