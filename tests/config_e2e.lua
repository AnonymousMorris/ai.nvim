local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)

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

local config = Config.resolve({
    model = "test-model",
    custom_backend_option = "preserved",
    chat = { keys = false },
})

assert_equal(config.backend, "pi", "default backend")
assert_equal(config.binary, "pi", "default binary")
assert_equal(config.thinking, "off", "default thinking level")
assert_equal(config.extensions, true, "default extensions")
assert_equal(config.skills, false, "default skills")
assert_equal(config.auto_close, true, "default auto close")
assert_equal(config.model, "test-model", "overridden model")
assert_equal(config.chat.keys, false, "overridden chat keys")
assert_equal(config.chat.show_hints, true, "default chat hints visibility")
assert_equal(config.chat.hints, Config.defaults.chat.hints, "default chat hints")
assert_equal(
    Config.resolve({ chat = { show_hints = false } }).chat.show_hints,
    false,
    "disabled chat hints"
)
assert_equal(config.chat.hints.input[1].key, "⏎", "default chat hint key")
assert_equal(
    config.chat.hints.input[2].label,
    "newline",
    "default newline hint"
)
assert_equal(
    config.chat.hints.input[3].label,
    "clear/interrupt",
    "default clear or interrupt hint"
)
local custom_hints = Config.resolve({
    chat = {
        hints = {
            input = {
                { key = "x", label = "display" },
            },
        },
    },
}).chat.hints
assert_equal(#custom_hints.input, 1, "replaced input hint count")
assert_equal(custom_hints.input[1].key, "x", "custom chat hint key")
assert_equal(custom_hints.input[1].label, "display", "custom chat hint label")
assert_equal(custom_hints.display[1].key, "Tab", "preserved display hints")
for _, key in ipairs({ "<M-CR>", "<S-CR>" }) do
    assert_equal(
        Config.defaults.chat.keys.input[key][1],
        "insert_newline",
        "default input " .. key .. " key"
    )
    assert_equal(
        Config.defaults.chat.keys.input[key].mode,
        "i",
        "default input " .. key .. " mode"
    )
end
assert_equal(
    Config.defaults.chat.keys.input["<C-c>"][1],
    "clear_or_interrupt",
    "default input clear or interrupt key"
)
assert_equal(
    Config.defaults.chat.keys.input["<C-c>"].mode,
    { "i", "n" },
    "default input clear or interrupt modes"
)
assert_equal(
    Config.defaults.chat.keys.input["<C-n>"][1],
    "new_session",
    "default input new session key"
)
assert_equal(
    Config.defaults.chat.keys.input["<C-n>"].mode,
    { "i", "n" },
    "default input new session modes"
)
assert_equal(
    Config.defaults.chat.keys.input["<Tab>"][1],
    "focus_display",
    "default input Tab key"
)
assert_equal(
    Config.defaults.chat.keys.input["<Tab>"].mode,
    { "i", "n" },
    "default input Tab modes"
)
assert_equal(
    Config.defaults.chat.keys.display["<Tab>"][1],
    "focus_input",
    "default display Tab key"
)
assert_equal(
    Config.defaults.chat.keys.input["<C-k>"],
    nil,
    "removed input Control-K key"
)
assert_equal(
    Config.defaults.chat.keys.display["<C-j>"],
    nil,
    "removed display Control-J key"
)

local backend = Config.backend(config)
assert_equal(backend.backend, "pi", "backend name")
assert_equal(backend.model, "test-model", "backend model")
assert_equal(
    backend.custom_backend_option,
    "preserved",
    "custom backend option"
)
assert_equal(backend.chat, nil, "chat config excluded from backend")
assert_equal(backend.auto_close, nil, "UI config excluded from backend")

config.chat.keys = {}
assert_equal(
    vim.tbl_count(Config.defaults.chat.keys.input)
        + vim.tbl_count(Config.defaults.chat.keys.display),
    10,
    "resolved config does not mutate defaults"
)

print("Config E2E checks passed")
vim.cmd("qa!")
