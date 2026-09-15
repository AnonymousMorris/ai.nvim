local M = {}

local function strings(value, option, allow_empty)
    if value == nil then
        return {}
    end
    if type(value) == "string" then
        value = { value }
    end
    assert(
        type(value) == "table" and vim.islist(value),
        option .. " must be a string or a list of strings"
    )
    for _, entry in ipairs(value) do
        assert(
            type(entry) == "string" and (allow_empty or entry ~= ""),
            option .. " entries must be " .. (allow_empty and "strings" or "non-empty strings")
        )
    end
    return value
end

local function absolute_path(path, cwd)
    if not path:match("^/") and not path:match("^%a:[/\\]") then
        return cwd .. "/" .. path
    end
    return path
end

local function read_prompt(path, cwd)
    assert(
        not path:match("^%a[%w+.-]*://"),
        "append_system_prompt_filepath must be a local path: " .. path
    )
    if path:sub(1, 2) == "~/" then
        path = vim.fn.expand("~") .. path:sub(2)
    end
    path = absolute_path(path, cwd)
    local stat = vim.uv.fs_stat(path)
    assert(
        stat and stat.type == "file",
        "append_system_prompt_filepath: expected a file: " .. path
    )
    return table.concat(vim.fn.readfile(path, "b"), "\n")
end

---Checks the existing-path interpretation used by Pi's system_prompt option.
---@param text string
---@param cwd string
---@return boolean
function M.is_path(text, cwd)
    return vim.uv.fs_stat(absolute_path(text, cwd)) ~= nil
end

---Writes prompt text to an exclusively created, owner-only temporary file.
---@param text string
---@return string path The caller owns deletion of this file.
function M.write_temp(text)
    assert(type(text) == "string", "system prompt must be a string")
    local path = vim.fn.tempname()
    local fd, open_err = vim.uv.fs_open(path, "wx", 384)
    assert(fd, "Could not create temporary system prompt file: " .. tostring(open_err))

    local ok, err = pcall(function()
        local offset = 0
        while offset < #text do
            local written, write_err = vim.uv.fs_write(fd, text:sub(offset + 1), offset)
            assert(written and written > 0, "Could not write temporary system prompt file: " .. tostring(write_err))
            offset = offset + written
        end
        local closed, close_err = vim.uv.fs_close(fd)
        assert(closed, "Could not close temporary system prompt file: " .. tostring(close_err))
        fd = nil
    end)
    if not ok then
        if fd then
            pcall(vim.uv.fs_close, fd)
        end
        pcall(vim.uv.fs_unlink, path)
        error(err, 0)
    end
    return path
end

---Combines configured text and file contents when starting a session.
---@param opts table
---@return string
function M.build(opts)
    local parts = {}
    local function append(text)
        if text ~= "" then
            parts[#parts + 1] = text
        end
    end
    for _, text in ipairs(strings(opts.append_system_prompt, "append_system_prompt", true)) do
        append(text)
    end
    local paths = strings(opts.append_system_prompt_filepath, "append_system_prompt_filepath", false)
    for _, path in ipairs(paths) do
        append(read_prompt(path, opts.agent_spawn_dir or vim.fn.getcwd()))
    end
    return table.concat(parts, "\n\n")
end

return M
