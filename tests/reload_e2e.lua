local repo = vim.fn.getcwd()
local snacks = vim.env.SNACKS_NVIM
    or (vim.fn.stdpath("data") .. "/lazy/snacks.nvim")

assert(vim.fn.isdirectory(snacks) == 1, "snacks.nvim is not installed")
vim.opt.runtimepath:prepend(snacks)
vim.opt.runtimepath:prepend(repo)

local AI = require("ai.ai")
local Events = require("ai.events")
local Plugin = require("ai")
local Session = require("ai.session")

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

local function write_file(path, lines)
    assert(vim.fn.writefile(lines, path) == 0, "failed to write " .. path)
end

local function read_buffer(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---@class ai.ReloadTestBackend: ai.Backend
local ReloadTestBackend = {}
ReloadTestBackend.__index = ReloadTestBackend

local backend
function ReloadTestBackend.start(opts, dispatch)
    assert(opts.reload == nil, "AI-only reload option leaked to the backend")
    backend = setmetatable({
        dispatch = dispatch,
        modes = {},
    }, ReloadTestBackend)
    return backend
end

function ReloadTestBackend:send(event, mode)
    self.modes[#self.modes + 1] = mode
    self.dispatch(event)
    self.dispatch({
        type = EventType.AI,
        action = AIAction.THINKING,
    })
    return true
end

function ReloadTestBackend:settle()
    self.dispatch({
        type = EventType.AI,
        action = AIAction.DONE,
    })
end

function ReloadTestBackend:interrupt()
    self:settle()
    return true
end

function ReloadTestBackend:finish()
    return true
end

function ReloadTestBackend:cancel()
    self.cancelled = true
end

AI.register_backend("reload-test", ReloadTestBackend)
Plugin.setup({ backend = "reload-test" })
vim.o.hidden = true

local file_one = vim.fn.tempname() .. ".lua"
local file_two = vim.fn.tempname() .. ".lua"
local unchanged_file = vim.fn.tempname() .. ".lua"
write_file(file_one, { "one before", "keep view", "last" })
write_file(file_two, { "two before" })
write_file(unchanged_file, { "unchanged on disk" })

vim.cmd("edit " .. vim.fn.fnameescape(file_one))
local buf_one = vim.api.nvim_get_current_buf()
local buf_two = vim.fn.bufadd(file_two)
local unchanged_buf = vim.fn.bufadd(unchanged_file)
vim.fn.bufload(buf_two)
vim.fn.bufload(unchanged_buf)

vim.api.nvim_buf_set_lines(buf_one, 0, -1, false, {
    "one stale local edit",
    "keep view",
    "last",
})
vim.api.nvim_buf_set_lines(buf_two, 0, -1, false, { "two stale local edit" })
vim.api.nvim_buf_set_lines(unchanged_buf, 0, -1, false, {
    "unchanged local edit",
})
vim.bo[buf_one].modified = true
vim.bo[buf_two].modified = true
vim.bo[unchanged_buf].modified = true
vim.api.nvim_win_set_cursor(0, { 2, 0 })

local session = assert(Session.new())
assert(session:submit("edit the files"))
write_file(file_one, { "one after agent edit", "keep view", "last" })
write_file(file_two, { "two after agent edit" })

assert_equal(
    read_buffer(buf_one)[1],
    "one stale local edit",
    "buffer reloaded before the turn settled"
)
backend:settle()

assert_equal(
    read_buffer(buf_one),
    { "one after agent edit", "keep view", "last" },
    "current changed buffer"
)
assert_equal(
    read_buffer(buf_two),
    { "two after agent edit" },
    "hidden changed buffer"
)
assert_equal(vim.bo[buf_one].modified, false, "current buffer modified flag")
assert_equal(vim.bo[buf_two].modified, false, "hidden buffer modified flag")
assert_equal(
    read_buffer(unchanged_buf),
    { "unchanged local edit" },
    "unchanged buffer contents"
)
assert_equal(
    vim.bo[unchanged_buf].modified,
    true,
    "unchanged buffer modified flag"
)
assert_equal(
    vim.api.nvim_win_get_cursor(0),
    { 2, 0 },
    "current buffer cursor"
)

assert(session:submit("make another edit"))
write_file(file_one, { "one after second agent edit", "keep view", "last" })
assert(session:submit("steer without resetting the turn snapshot"))
backend:settle()
assert_equal(
    read_buffer(buf_one)[1],
    "one after second agent edit",
    "changed buffer after steering"
)
assert_equal(
    backend.modes,
    { "prompt", "prompt", "steer" },
    "message delivery modes"
)

vim.api.nvim_buf_set_lines(buf_one, 0, 1, false, {
    "one after local write",
})
local wrote, write_err = pcall(vim.api.nvim_buf_call, buf_one, function()
    vim.cmd("silent write")
end)
assert(wrote, "reloaded buffer could not be written: " .. tostring(write_err))

Plugin.setup({ backend = "reload-test", reload = false })
local disabled_file = vim.fn.tempname() .. ".lua"
write_file(disabled_file, { "disabled before" })
vim.cmd("edit " .. vim.fn.fnameescape(disabled_file))
local disabled_buf = vim.api.nvim_get_current_buf()
local disabled_session = assert(Session.new())
assert(disabled_session:submit("do not reload"))
write_file(disabled_file, { "disabled after agent edit" })
backend:settle()
assert_equal(
    read_buffer(disabled_buf),
    { "disabled before" },
    "buffer with reload disabled"
)

assert(Session.stop_current())
for _, path in ipairs({ file_one, file_two, unchanged_file, disabled_file }) do
    vim.fn.delete(path)
end

print("Buffer reload E2E checks passed")
vim.cmd("qa!")
