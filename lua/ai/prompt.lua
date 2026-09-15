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

local function read_prompt(path, cwd)
    assert(
        not path:match("^%a[%w+.-]*://"),
        "append_system_prompt_filepath must be a local path: " .. path
    )
    if path:sub(1, 2) == "~/" then
        path = vim.fn.expand("~") .. path:sub(2)
    end
    if not path:match("^/") and not path:match("^%a:[/\\]") then
        path = cwd .. "/" .. path
    end
    local stat = vim.uv.fs_stat(path)
    assert(
        stat and stat.type == "file",
        "append_system_prompt_filepath: expected a file: " .. path
    )
    return table.concat(vim.fn.readfile(path, "b"), "\n")
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
