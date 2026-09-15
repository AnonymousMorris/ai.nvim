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

-- Read prompt arguments once, matching Pi's file-input behavior.
local binary = root .. "/pi"
vim.fn.writefile(vim.split([=[#!/bin/sh
: > "$AI_PROMPTS_OUTPUT"
: > "$AI_PROMPTS_SYSTEM"
while [ "$#" -gt 0 ]; do
    if [ "$1" = --append-system-prompt ]; then
        cat "$2" >> "$AI_PROMPTS_OUTPUT" || exit 1
        shift
    elif [ "$1" = --system-prompt ]; then
        cat "$2" >> "$AI_PROMPTS_SYSTEM" || exit 1
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
vim.env.AI_PROMPTS_SYSTEM = root .. "/system"
vim.env.AI_PROMPTS_READY = root .. "/ready"

-- Observe paths while still using the real process launcher and filesystem.
local system = vim.system
local prompt_paths = {}
vim.system = function(command, ...)
    prompt_paths = {}
    for i, arg in ipairs(command) do
        if arg == "--append-system-prompt" or arg == "--system-prompt" then
            prompt_paths[#prompt_paths + 1] = command[i + 1]
        end
    end
    return system(command, ...)
end

local function assert_removed(paths)
    for _, path in ipairs(paths) do
        assert(not vim.uv.fs_stat(path), "temporary prompt file was not removed: " .. path)
    end
end

local function launch(opts, expected, expected_system)
    vim.fn.delete(vim.env.AI_PROMPTS_READY)
    Plugin.setup(vim.tbl_extend("force", { binary = binary }, opts))
    vim.cmd("AI")
    local session = assert(Session.get_current())
    assert(vim.wait(2000, function()
        return vim.fn.filereadable(vim.env.AI_PROMPTS_READY) == 1
    end), "backend did not read its prompt")
    assert(read(vim.env.AI_PROMPTS_OUTPUT) == expected, "backend received incorrect instructions")
    assert(read(vim.env.AI_PROMPTS_SYSTEM) == (expected_system or ""), "backend received incorrect system prompt")
    local owned_paths = {}
    for _, path in ipairs(prompt_paths) do
        if path ~= opts.system_prompt then
            local stat = assert(vim.uv.fs_stat(path), "prompt file vanished while the backend was alive")
            assert(bit.band(stat.mode, 511) == 384, "temporary prompt file was not owner-only")
            assert(path:sub(1, 1) == "/", "temporary prompt path was not absolute")
            owned_paths[#owned_paths + 1] = path
        end
    end
    session.ai:finish()
    assert(vim.wait(2000, function() return session.ai.result ~= nil end), "backend did not exit")
    assert_removed(owned_paths)
    assert(Session.stop_current())
end

local notifications = {}
local notify = vim.notify
local notification_levels = {}
local startup_prefix = "Failed to start AI backend: "
vim.notify = function(message, level)
    notifications[#notifications + 1] = message
    notification_levels[#notification_levels + 1] = level
end

-- Configuration is stored at setup; startup failures use the existing notification.
local function startup_error(opts, expected)
    Plugin.setup(vim.tbl_extend("force", { binary = binary }, opts))
    local before = #vim.api.nvim_list_bufs()
    local count = #notifications
    prompt_paths = {}
    vim.cmd("AI")
    assert(Session.get_current() == nil, "invalid prompt configuration opened a session")
    assert(#vim.api.nvim_list_bufs() == before, "failed startup leaked scratch buffers")
    assert(#notifications == count + 1, "startup did not report one error")
    assert(notification_levels[#notification_levels] == vim.log.levels.ERROR, "startup notification was not an error")
    local message = notifications[#notifications]
    assert(message:sub(1, #startup_prefix) == startup_prefix, "startup notification was bypassed")
    assert(message:find(expected, #startup_prefix + 1, true), "startup notification omitted the error")
    for _, path in ipairs(prompt_paths) do
        if path ~= opts.system_prompt then
            assert_removed({ path })
        end
    end
    return message:sub(#startup_prefix + 1)
end

-- Prompts larger than the real OS argument limit now start through :AI.
local large_prompt = string.rep("Keep responses concise.\n", 50000)
local large_file = root .. "/large.md"
vim.fn.writefile({ large_prompt }, large_file, "b")
launch({ append_system_prompt = { large_prompt, large_prompt } }, large_prompt .. "\n\n" .. large_prompt)
launch({ append_system_prompt_filepath = large_file }, large_prompt)
launch({ system_prompt = large_prompt }, "", large_prompt)

-- Preserve the original diagnostics for custom commands and unrelated failures.
local raw_e2big = startup_error({ model = large_prompt }, "E2BIG:")
startup_error({ cmd = { binary, large_prompt } }, raw_e2big)
startup_error({ model = large_prompt, append_system_prompt_filepath = empty }, raw_e2big)
startup_error({ model = large_prompt, append_system_prompt = "short" }, raw_e2big)
startup_error({ binary = missing }, "ENOENT:")
startup_error({ binary = missing, system_prompt = "Base instructions.", append_system_prompt = "Extra instructions." }, "ENOENT:")
startup_error({ binary = missing, system_prompt = instructions, append_system_prompt = "Extra instructions." }, "ENOENT:")
assert(vim.fn.filereadable(instructions) == 1, "failed startup deleted the user's prompt file")

-- Fail the second file operation after one prompt file has already been prepared.
for _, operation in ipairs({ "create", "write", "close" }) do
    local fs_open, fs_write, fs_close = vim.uv.fs_open, vim.uv.fs_write, vim.uv.fs_close
    local paths, second_fd = {}, nil
    local attempts = 0
    vim.uv.fs_open = function(path, flags, mode)
        if flags == "wx" then
            attempts = attempts + 1
            if attempts == 2 and operation == "create" then
                return nil, "EACCES: permission denied", "EACCES"
            end
        end
        local fd, err, code = fs_open(path, flags, mode)
        if flags == "wx" and fd then
            paths[#paths + 1] = path
            if attempts == 2 then second_fd = fd end
        end
        return fd, err, code
    end
    vim.uv.fs_write = function(fd, ...)
        if fd == second_fd and operation == "write" then
            return nil, "ENOSPC: no space left on device", "ENOSPC"
        end
        return fs_write(fd, ...)
    end
    vim.uv.fs_close = function(fd)
        if fd == second_fd and operation == "close" then
            second_fd = nil
            fs_close(fd)
            return nil, "EIO: input/output error", "EIO"
        end
        return fs_close(fd)
    end
    local ok, err = pcall(startup_error, {
        system_prompt = "Base instructions.",
        append_system_prompt = "Extra instructions.",
    }, "Could not " .. operation .. " temporary system prompt file")
    vim.uv.fs_open, vim.uv.fs_write, vim.uv.fs_close = fs_open, fs_write, fs_close
    assert(ok, err)
    assert_removed(paths)
end

-- Short writes must preserve every byte, including multibyte characters.
local fs_write = vim.uv.fs_write
vim.uv.fs_write = function(fd, text, offset)
    return fs_write(fd, text:sub(1, 7), offset)
end
local partial_text = "First line.\n台灣.\nFinal line."
local partial_ok, partial_err = pcall(launch, { append_system_prompt = partial_text }, partial_text)
vim.uv.fs_write = fs_write
assert(partial_ok, partial_err)

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
launch({ system_prompt = instructions }, "", read(instructions))
assert(vim.fn.filereadable(instructions) == 1, "the user's system prompt file was deleted")
launch({ cmd = { binary }, append_system_prompt = large_prompt }, "")

local other = root .. "/other.md"
vim.fn.writefile({ instructions }, other, "b")
launch({ append_system_prompt = instructions }, instructions)
launch({ append_system_prompt_filepath = other }, instructions)
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
local previous_prompt_paths = vim.deepcopy(prompt_paths)

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
assert(vim.fn.filereadable(previous_prompt_paths[1]) == 1, "failed replacement removed the active prompt file")

-- A subsequent Ctrl-N reads the updated file without another setup() call.
vim.fn.writefile({ "Updated instructions." }, instructions)
vim.fn.delete(vim.env.AI_PROMPTS_READY)
new_session_key()
assert(vim.wait(2000, function()
    return Session.get_current() ~= session and vim.fn.filereadable(vim.env.AI_PROMPTS_READY) == 1
end), "Ctrl-N did not start a new session")
assert(read(vim.env.AI_PROMPTS_OUTPUT) == read(instructions), "Ctrl-N did not reread the prompt file")
assert_removed(previous_prompt_paths)
local current_prompt_paths = vim.deepcopy(prompt_paths)
assert(Session.stop_current())
assert_removed(current_prompt_paths)

startup_error({ append_system_prompt_filepath = "missing.md" }, missing)
vim.notify = notify
vim.system = system

vim.api.nvim_set_current_dir(repo)
vim.fn.delete(root, "rf")
print("Prompt configuration E2E checks passed")
vim.cmd("qa!")
