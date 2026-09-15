local repo = vim.fn.getcwd()
local snacks = vim.env.SNACKS_NVIM
    or (vim.fn.stdpath("data") .. "/lazy/snacks.nvim")
vim.opt.runtimepath:prepend(snacks)
vim.opt.runtimepath:prepend(repo)
vim.cmd.runtime("plugin/ai.nvim.lua")

local Plugin = require("ai")
local Session = require("ai.session")
local root = vim.fn.tempname() .. " prompts"
vim.fn.mkdir(root, "p")
local missing = root .. "/missing.md"
local instructions = root .. "/instructions.md"
vim.fn.writefile({ "File instructions with $HOME, {{name}}, and Unicode: 台灣." }, instructions)
local empty = root .. "/empty.md"
vim.fn.writefile({}, empty)

local function read(path)
    return table.concat(vim.fn.readfile(path, "b"), "\n")
end

-- Capture the text passed directly to Pi.
local binary = root .. "/pi"
vim.fn.writefile(vim.split([=[#!/bin/sh
: > "$AI_PROMPTS_OUTPUT"
while [ "$#" -gt 0 ]; do
    if [ "$1" = --append-system-prompt ]; then
        printf '%s' "$2" >> "$AI_PROMPTS_OUTPUT"
        shift
    fi
    shift
done
printf ready > "$AI_PROMPTS_READY"
IFS= read -r release
exit 0
]=], "\n", { plain = true }), binary)
assert(vim.uv.fs_chmod(binary, 493))
vim.env.AI_PROMPTS_OUTPUT = root .. "/output"
vim.env.AI_PROMPTS_READY = root .. "/ready"

local function launch(opts, expected)
    vim.fn.delete(vim.env.AI_PROMPTS_READY)
    Plugin.setup(vim.tbl_extend("force", { binary = binary }, opts))
    local session = assert(Session.new())
    assert(vim.wait(2000, function()
        return vim.fn.filereadable(vim.env.AI_PROMPTS_READY) == 1
    end), "backend did not read its prompt")
    assert(read(vim.env.AI_PROMPTS_OUTPUT) == expected, "backend received incorrect instructions")
    session.ai:finish()
    assert(vim.wait(2000, function() return session.ai.result ~= nil end), "backend did not exit")
    assert(Session.stop_current())
end

local notifications = {}
local notify = vim.notify
local notification_levels = {}
vim.notify = function(message, level)
    notifications[#notifications + 1] = message
    notification_levels[#notification_levels + 1] = level
end

-- Configuration is stored at setup; startup failures use the existing notification.
local function startup_error(opts, expected)
    Plugin.setup(vim.tbl_extend("force", { binary = binary }, opts))
    local before = #vim.api.nvim_list_bufs()
    local count = #notifications
    vim.cmd("AI")
    assert(Session.get_current() == nil, "invalid prompt configuration opened a session")
    assert(#vim.api.nvim_list_bufs() == before, "failed startup leaked scratch buffers")
    assert(#notifications == count + 1, "startup did not report one error")
    assert(notification_levels[#notification_levels] == vim.log.levels.ERROR, "startup notification was not an error")
    assert(notifications[#notifications]:find("Failed to start AI backend:", 1, true), "startup notification was bypassed")
    assert(notifications[#notifications]:find(expected, 1, true), "startup notification omitted the error")
end

-- Exercise the real OS argument limit through :AI, for both text and files.
local large_prompt = string.rep("Keep responses concise.\n", 50000)
local large_file = root .. "/large.md"
vim.fn.writefile({ large_prompt }, large_file, "b")
local size_error = "The system prompt is too large to start Pi. "
    .. "Shorten your prompt text or prompt files, then try again."
startup_error({ append_system_prompt = { large_prompt, large_prompt } }, size_error)
startup_error({ append_system_prompt_filepath = large_file }, size_error)
startup_error({ system_prompt = large_prompt }, size_error)

-- Preserve the original diagnostics for custom commands and unrelated failures.
startup_error({ cmd = { binary, large_prompt } }, "E2BIG:")
startup_error({ model = large_prompt }, "E2BIG:")
startup_error({ model = large_prompt, append_system_prompt_filepath = empty }, "E2BIG:")
startup_error({ binary = missing }, "ENOENT:")

startup_error({ append_system_prompt_filepath = missing }, missing)
assert(notifications[#notifications]:find("append_system_prompt_filepath", 1, true), "error omitted the option name")

for _, value in ipairs({ root, "", false, 42, { instructions, false }, { named = instructions }, { [2] = instructions } }) do
    startup_error({ append_system_prompt_filepath = value }, "append_system_prompt_filepath")
end
for _, value in ipairs({ false, 42, { "valid", false }, { named = "invalid" } }) do
    startup_error({ append_system_prompt = value }, "append_system_prompt")
end

for _, url in ipairs({ "https://example.com/instructions.md", "http://example.com/instructions.md" }) do
    startup_error({ append_system_prompt_filepath = url }, "must be a local path")
end

if vim.uv.getuid and vim.uv.getuid() ~= 0 then
    assert(vim.uv.fs_chmod(instructions, 0))
    startup_error({ append_system_prompt_filepath = instructions }, instructions)
    assert(vim.uv.fs_chmod(instructions, 384))
end

launch({ append_system_prompt = "Keep responses concise." }, "Keep responses concise.")
launch({ append_system_prompt = "~/keep-this-literal.md" }, "~/keep-this-literal.md")
launch({ append_system_prompt = "https://example.com/literal.md" }, "https://example.com/literal.md")
launch({ append_system_prompt_filepath = instructions }, read(instructions))

local other = root .. "/other.md"
vim.fn.writefile({ instructions }, other, "b")
launch({
    append_system_prompt = { "First instruction.", "Second instruction." },
    append_system_prompt_filepath = { instructions, other },
}, "First instruction.\n\nSecond instruction.\n\n" .. read(instructions) .. "\n\n" .. instructions)

launch({ append_system_prompt = "", append_system_prompt_filepath = empty }, "")

-- Setup can precede a directory change; relative paths use the session directory.
Plugin.setup({ binary = binary, append_system_prompt_filepath = "instructions.md" })
vim.api.nvim_set_current_dir(root)
vim.fn.delete(vim.env.AI_PROMPTS_READY)
vim.cmd("AI")
local session = assert(Session.get_current())
assert(vim.wait(2000, function()
    return vim.fn.filereadable(vim.env.AI_PROMPTS_READY) == 1
end), "relative-path backend did not start")
assert(read(vim.env.AI_PROMPTS_OUTPUT) == read(instructions), "relative path used the setup directory")

local function new_session_key()
    Session.get_current().chat.input:focus()
    vim.cmd("startinsert")
    vim.api.nvim_feedkeys(vim.keycode("<C-n>"), "xt", false)
end

-- Ctrl-N reports missing files and preserves the current session on failure.
vim.fn.delete(instructions)
local before = #vim.api.nvim_list_bufs()
local count = #notifications
new_session_key()
assert(vim.wait(2000, function() return #notifications > count end), "Ctrl-N did not report the missing file")
assert(notifications[#notifications]:find(instructions, 1, true), "Ctrl-N notification omitted the missing file")
assert(Session.get_current() == session, "failed Ctrl-N replaced the current session")
assert(#vim.api.nvim_list_bufs() == before, "failed startup leaked scratch buffers")

-- A subsequent Ctrl-N reads the updated file without another setup() call.
vim.fn.writefile({ "Updated instructions." }, instructions)
vim.fn.delete(vim.env.AI_PROMPTS_READY)
new_session_key()
assert(vim.wait(2000, function()
    return Session.get_current() ~= session and vim.fn.filereadable(vim.env.AI_PROMPTS_READY) == 1
end), "Ctrl-N did not start a new session")
assert(read(vim.env.AI_PROMPTS_OUTPUT) == read(instructions), "Ctrl-N did not reread the prompt file")
assert(Session.stop_current())

startup_error({ append_system_prompt_filepath = "missing.md" }, missing)
vim.notify = notify

vim.api.nvim_set_current_dir(repo)
vim.fn.delete(root, "rf")
print("Prompt configuration E2E checks passed")
vim.cmd("qa!")
