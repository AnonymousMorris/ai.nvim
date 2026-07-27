local M = {}

---Returns the active visual selection with its source location.
---@return string? context
function M.get_visual_context()
    local mode = vim.fn.mode()
    if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
        return nil
    end

    local start_pos = vim.fn.getpos("v")
    local end_pos = vim.fn.getpos(".")
    local lines = vim.fn.getregion(start_pos, end_pos, { type = mode })
    if vim.tbl_isempty(lines) then
        return nil
    end

    local name = vim.api.nvim_buf_get_name(0)
    if name == "" then
        name = "[No Name]"
    else
        name = vim.fn.fnamemodify(name, ":.")
    end

    local start_line = math.min(start_pos[2], end_pos[2])
    local end_line = math.max(start_pos[2], end_pos[2])
    local line_label
    if start_line == end_line then
        line_label = ("Line: %d"):format(start_line)
    else
        line_label = ("Lines: %d-%d"):format(start_line, end_line)
    end

    return table.concat({
        "File: " .. name,
        line_label,
        "",
        table.concat(lines, "\n"),
    }, "\n")
end

return M
