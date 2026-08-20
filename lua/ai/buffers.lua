local M = {}

local uv = vim.uv or vim.loop

---Returns whether a loaded buffer is backed by a named file.
---@param buf integer
---@return boolean
local function is_file_backed(buf)
    return vim.api.nvim_buf_is_loaded(buf)
        and vim.bo[buf].buftype == ""
        and vim.api.nvim_buf_get_name(buf) ~= ""
end

---Returns a stable absolute path for a buffer name.
---@param path string
---@return string
local function normalize_path(path)
    return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

---Returns the disk metadata used to detect an external file edit.
---@param path string
---@return table?
local function file_signature(path)
    local stat = uv.fs_stat(path)
    if not stat or stat.type ~= "file" then
        return nil
    end

    return {
        size = stat.size,
        mtime_sec = stat.mtime and stat.mtime.sec or 0,
        mtime_nsec = stat.mtime and stat.mtime.nsec or 0,
    }
end

---Compares two optional file signatures.
---@param left table?
---@param right table?
---@return boolean
local function signatures_equal(left, right)
    if not left or not right then
        return left == right
    end

    return left.size == right.size
        and left.mtime_sec == right.mtime_sec
        and left.mtime_nsec == right.mtime_nsec
end

---Captures every loaded file-backed buffer's current disk signature.
---@return table<string, table> snapshots
function M.snapshot()
    local snapshots = {}

    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if is_file_backed(buf) then
            local path = normalize_path(vim.api.nvim_buf_get_name(buf))
            snapshots[path] = file_signature(path)
        end
    end

    return snapshots
end

---Saves the views of all windows displaying a buffer.
---@param buf integer
---@return table<integer, table>
local function save_views(buf)
    local views = {}

    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == buf then
            local ok, view = pcall(vim.api.nvim_win_call, win, function()
                return vim.fn.winsaveview()
            end)
            if ok then
                views[win] = view
            end
        end
    end

    return views
end

---Restores views that still display the reloaded buffer.
---@param buf integer
---@param views table<integer, table>
local function restore_views(buf, views)
    for win, view in pairs(views) do
        if
            vim.api.nvim_win_is_valid(win)
            and vim.api.nvim_win_get_buf(win) == buf
        then
            pcall(vim.api.nvim_win_call, win, function()
                vim.fn.winrestview(view)
            end)
        end
    end
end

---Forcibly reloads one buffer while preserving its visible views.
---@param buf integer
---@param path string
---@return boolean success
local function reload(buf, path)
    if vim.fn.filereadable(path) ~= 1 then
        return false
    end

    local views = save_views(buf)
    local ok = pcall(vim.api.nvim_buf_call, buf, function()
        vim.cmd("silent keepalt edit!")
    end)
    restore_views(buf, views)
    return ok
end

---Reloads loaded buffers whose files changed since a snapshot.
---@param snapshots table<string, table>?
---@return integer reloaded
function M.reload_changed(snapshots)
    snapshots = snapshots or {}
    local reloaded = 0

    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if is_file_backed(buf) then
            local path = normalize_path(vim.api.nvim_buf_get_name(buf))
            if
                not signatures_equal(
                    snapshots[path],
                    file_signature(path)
                )
                and reload(buf, path)
            then
                reloaded = reloaded + 1
            end
        end
    end

    return reloaded
end

return M
