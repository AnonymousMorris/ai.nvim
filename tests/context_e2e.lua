local repo = vim.fn.getcwd()
local snacks = vim.env.SNACKS_NVIM
    or (vim.fn.stdpath("data") .. "/lazy/snacks.nvim")

assert(vim.fn.isdirectory(snacks) == 1, "snacks.nvim is not installed")
vim.opt.runtimepath:prepend(snacks)
vim.opt.runtimepath:prepend(repo)
vim.cmd.runtime("plugin/ai.nvim.lua")

local AI = require("ai.ai")
local Context = require("ai.context")
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

---@class ai.ContextTestBackend: ai.Backend
local ContextTestBackend = {}
ContextTestBackend.__index = ContextTestBackend

local backend
function ContextTestBackend.start(_, dispatch)
    backend = setmetatable({
        dispatch = dispatch,
        events = {},
    }, ContextTestBackend)
    return backend
end

function ContextTestBackend:send(event)
    self.events[#self.events + 1] = vim.deepcopy(event)
    self.dispatch(event)
    self.dispatch({
        type = EventType.AI,
        action = AIAction.DONE,
    })
    return true
end

function ContextTestBackend:interrupt()
    self.interrupted = true
    return true
end

function ContextTestBackend:finish()
    return true
end

function ContextTestBackend:cancel()
    self.cancelled = true
end

AI.register_backend("context-test", ContextTestBackend)
Plugin.setup({ backend = "context-test" })
vim.keymap.set("x", "<leader>ai", "<Cmd>AISelection<CR>", {
    desc = "Open AI chat with selection",
})

local source_buf = vim.api.nvim_create_buf(true, false)
local source_path = "tests/fixtures/context_source.lua"
vim.api.nvim_buf_set_name(source_buf, repo .. "/" .. source_path)
vim.api.nvim_set_current_buf(source_buf)
vim.bo[source_buf].filetype = "lua"
vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
    "local alpha = one()",
    "local beta = two()",
})
vim.api.nvim_win_set_cursor(0, { 1, 6 })
vim.cmd("normal! v4l")
assert_equal(vim.fn.mode(), "v", "active visual mode")
local character_context = table.concat({
    "File: " .. source_path,
    "Line: 1",
    "",
    "```lua",
    "alpha",
    "```",
}, "\n")
assert_equal(
    Context.get_visual_context(repo),
    character_context,
    "characterwise selection context"
)

local visual_mapping
for _, mapping in ipairs(vim.api.nvim_get_keymap("x")) do
    if mapping.lhs == "\\ai" then
        visual_mapping = mapping
        break
    end
end
assert(visual_mapping, "user visual AI keymap was not registered")
assert_equal(
    visual_mapping.rhs,
    "<Cmd>AISelection<CR>",
    "visual AI command mapping"
)
assert_equal(visual_mapping.callback, nil, "visual AI mapping callback")
vim.api.nvim_feedkeys("\\ai", "mx", false)

local session = assert(Session.get_current(), "visual AI command did not create a session")
assert_equal(session.agent_spawn_dir, repo, "agent spawn directory")
local chat = assert(session.chat, "visual AI did not open the chat")
assert_equal(
    vim.api.nvim_buf_get_lines(session.input_buf, 0, -1, false),
    {
        "File: " .. source_path,
        "Line: 1",
        "",
        "```lua",
        "alpha",
        "```",
        "",
        "",
    },
    "selection context pasted into input"
)
assert_equal(vim.api.nvim_get_current_win(), chat.input.win, "selection input focus")
assert_equal(
    vim.api.nvim_win_get_cursor(chat.input.win),
    { 8, 0 },
    "selection input cursor"
)
assert_equal(
    vim.api.nvim_win_call(chat.input.win, function()
        return { vim.fn.foldclosed(1), vim.fn.foldclosedend(1) }
    end),
    { 1, 6 },
    "selection context fold"
)
assert_equal(
    vim.api.nvim_win_call(chat.input.win, function()
        return vim.fn.foldtextresult(1)
    end),
    "File: " .. source_path .. "  Line: 1",
    "selection context fold label"
)
assert_equal(
    vim.api.nvim_win_text_height(chat.input.win, {}).all,
    3,
    "folded selection input height"
)
assert_equal(
    vim.api.nvim_win_get_height(chat.input.win),
    3,
    "folded selection window height"
)
assert_equal(
    vim.api.nvim_win_call(chat.input.win, function()
        return vim.fn.winsaveview().topline
    end),
    1,
    "folded selection window top line"
)
vim.cmd("stopinsert")
vim.api.nvim_win_set_cursor(chat.input.win, { 1, 0 })
vim.api.nvim_feedkeys("za", "mx", false)
assert_equal(
    vim.api.nvim_win_call(chat.input.win, function()
        return vim.fn.foldclosed(1)
    end),
    -1,
    "opened selection context fold"
)
vim.api.nvim_feedkeys("za", "mx", false)
assert_equal(
    vim.api.nvim_win_call(chat.input.win, function()
        return vim.fn.foldclosed(1)
    end),
    1,
    "reclosed selection context fold"
)
vim.api.nvim_win_set_cursor(chat.input.win, { 8, 0 })
vim.cmd("startinsert")
assert_equal(
    vim.wo[chat.input.win].foldcolumn,
    "auto:1",
    "selection input fold column"
)
assert(
    vim.wo[chat.input.win].statuscolumn:find("%%C"),
    "selection input status column omitted fold controls"
)
vim.api.nvim_buf_set_lines(session.input_buf, 7, 8, false, { "explain this" })
chat.input:execute("confirm")
assert(
    vim.wait(1000, function()
        return #backend.events == 1
    end),
    "selection input was not submitted"
)
assert_equal(backend.events[1], {
    type = EventType.USER,
    content = character_context .. "\n\nexplain this",
}, "selection context and instruction message")
assert_equal(
    vim.api.nvim_buf_get_lines(session.display_buf, 0, -1, false),
    {
        "---",
        "user: File: " .. source_path,
        "Line: 1",
        "",
        "```lua",
        "alpha",
        "```",
        "",
        "explain this",
        "---",
        "",
    },
    "selection context and instruction transcript"
)

assert(session:submit("follow up"))
assert_equal(backend.events[2], {
    type = EventType.USER,
    content = "follow up",
}, "selection context sent only once")

session:close_window()
vim.api.nvim_set_current_buf(source_buf)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd("normal! Vk")
local line_context = table.concat({
    "File: " .. source_path,
    "Lines: 1-2",
    "",
    "```lua",
    "local alpha = one()",
    "local beta = two()",
    "```",
}, "\n")
assert_equal(
    Context.get_visual_context(repo),
    line_context,
    "linewise selection context"
)
vim.cmd("cd " .. vim.fn.fnameescape(repo .. "/lua"))
vim.api.nvim_feedkeys("\\ai", "mx", false)
vim.cmd("cd " .. vim.fn.fnameescape(repo))
assert_equal(Session.get_current(), session, "visual context replaced the session")
assert_equal(
    vim.api.nvim_buf_get_lines(session.input_buf, 0, -1, false),
    {
        "File: " .. source_path,
        "Lines: 1-2",
        "",
        "```lua",
        "local alpha = one()",
        "local beta = two()",
        "```",
        "",
        "",
    },
    "existing session selection context input"
)
local reopened_chat = assert(session.chat, "selection did not reopen chat")
assert_equal(
    vim.api.nvim_win_call(reopened_chat.input.win, function()
        return { vim.fn.foldclosed(1), vim.fn.foldclosedend(1) }
    end),
    { 1, 7 },
    "reopened selection context fold"
)
assert_equal(
    Context.get_visual_context(repo),
    nil,
    "selection unavailable outside visual mode"
)

session:close_window()
local unnamed_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(unnamed_buf)
vim.api.nvim_buf_set_lines(unnamed_buf, 0, -1, false, { "unnamed context" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd("normal! V")
assert_equal(
    Context.get_visual_context(repo),
    "File: [No Name]\nLine: 1\n\n```\nunnamed context\n```",
    "unnamed buffer selection context"
)
vim.api.nvim_feedkeys("\\ai", "mx", false)
local stacked_chat = assert(session.chat, "stacked context did not reopen chat")
assert_equal(
    vim.api.nvim_buf_get_lines(session.input_buf, 0, -1, false),
    {
        "File: [No Name]",
        "Line: 1",
        "",
        "```",
        "unnamed context",
        "```",
        "",
        "File: " .. source_path,
        "Lines: 1-2",
        "",
        "```lua",
        "local alpha = one()",
        "local beta = two()",
        "```",
        "",
        "",
    },
    "stacked selection context input"
)
assert_equal(
    vim.api.nvim_win_call(stacked_chat.input.win, function()
        return {
            vim.fn.foldclosed(1),
            vim.fn.foldclosedend(1),
            vim.fn.foldclosed(8),
            vim.fn.foldclosedend(8),
        }
    end),
    { 1, 6, 8, 14 },
    "stacked selection context folds"
)
assert_equal(
    vim.api.nvim_win_get_height(stacked_chat.input.win),
    5,
    "stacked selection window height"
)
vim.cmd("stopinsert")
vim.api.nvim_feedkeys("zR", "mx", false)
assert_equal(
    vim.api.nvim_win_call(stacked_chat.input.win, function()
        return { vim.fn.foldclosed(1), vim.fn.foldclosed(8) }
    end),
    { -1, -1 },
    "opened stacked selection folds"
)
vim.api.nvim_feedkeys("zM", "mx", false)
assert_equal(
    vim.api.nvim_win_call(stacked_chat.input.win, function()
        return { vim.fn.foldclosed(1), vim.fn.foldclosed(8) }
    end),
    { 1, 8 },
    "reclosed stacked selection folds"
)

stacked_chat:focus_input()
vim.api.nvim_feedkeys(vim.keycode("<C-c>"), "xt", false)
assert_equal(
    vim.api.nvim_buf_get_lines(session.input_buf, 0, -1, false),
    { "" },
    "Control-C did not clear selection context"
)
assert_equal(backend.interrupted, nil, "selection clear interrupted the backend")

session:close_window()
vim.api.nvim_set_current_buf(source_buf)
vim.bo[source_buf].filetype = ""
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd("normal! V")
assert_equal(
    Context.get_visual_context(repo),
    "File: " .. source_path .. "\nLine: 1\n\n```\nlocal alpha = one()\n```",
    "named buffer without a filetype uses an unlabeled fence"
)
vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
vim.bo[source_buf].filetype = "python"
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_feedkeys(vim.keycode("<C-v>j4l"), "nx", false)
assert_equal(vim.fn.mode(), "\22", "active blockwise visual mode")
local block_context = table.concat({
    "File: " .. source_path,
    "Lines: 1-2",
    "",
    "```python",
    "local",
    "local",
    "```",
}, "\n")
assert_equal(
    Context.get_visual_context(repo),
    block_context,
    "blockwise selection uses the buffer filetype rather than the extension"
)
vim.api.nvim_feedkeys("\\ai", "mx", false)
local block_chat = assert(session.chat, "blockwise selection did not reopen chat")
block_chat.input:execute("confirm")
assert(
    vim.wait(1000, function()
        return #backend.events == 3
    end),
    "blockwise selection was not submitted"
)
assert_equal(backend.events[3], {
    type = EventType.USER,
    content = block_context .. "\n\n",
}, "blockwise selection fence submitted unchanged")

session:close_window()
vim.api.nvim_set_current_buf(source_buf)
vim.bo[source_buf].filetype = "markdown"
vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
    "```lua",
    "print('example')",
    "```",
    "This is still selected source text with ```` backticks.",
})
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd("normal! V3j")
vim.api.nvim_feedkeys("\\ai", "mx", false)
local markdown_chat = assert(session.chat, "Markdown selection did not reopen chat")
local markdown_context = table.concat({
    "File: " .. source_path,
    "Lines: 1-4",
    "",
    "`````markdown",
    "```lua",
    "print('example')",
    "```",
    "This is still selected source text with ```` backticks.",
    "`````",
}, "\n")
assert_equal(
    vim.api.nvim_buf_get_lines(session.input_buf, 0, -1, false),
    vim.split(markdown_context .. "\n\n", "\n", { plain = true }),
    "Markdown selection fence is longer than every selected backtick run"
)
markdown_chat.input:execute("confirm")
assert(
    vim.wait(1000, function()
        return #backend.events == 4
    end),
    "Markdown selection was not submitted"
)
assert_equal(backend.events[4], {
    type = EventType.USER,
    content = markdown_context .. "\n\n",
}, "nested Markdown fences submitted unchanged")

print("Context E2E checks passed")
vim.cmd("qa!")
