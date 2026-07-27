local AI = require("ai.ai")
local Chat = require("ai.ui.chat")

local current

---@class ai.Session
---@field ai ai.AI
---@field display_buf integer
---@field input_buf integer
---@field chat? ai.ui.Chat Open disposable chat UI.
---@field destroyed boolean
local Session = {}
Session.__index = Session

---Creates a hidden scratch buffer for session-owned content.
---@return integer
local function create_scratch_buffer()
    local buf = vim.api.nvim_create_buf(false, true)

    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].undofile = false
    vim.bo[buf].undolevels = -1
    vim.bo[buf].modifiable = false

    return buf
end

---Deletes one session-owned buffer.
---@param buf? integer
---@return boolean success
---@return any? error
local function delete_buffer(buf)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return true
    end
    return pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

---Requires a session that has not reached its terminal state.
---@param session ai.Session
local function assert_active(session)
    assert(not session.destroyed, "AI session has been destroyed")
end

---Creates and selects a fully initialized AI session.
---@param opts? ai.StartOpts
---@return ai.Session? session
---@return any? error
function Session.new(opts)
    local ok, display_buf = pcall(create_scratch_buffer)
    if not ok then
        return nil, display_buf
    end

    local input_buf
    ok, input_buf = pcall(create_scratch_buffer)
    if not ok then
        delete_buffer(display_buf)
        return nil, input_buf
    end

    local started, ai, err = pcall(AI.start, display_buf, opts)
    if not started then
        err = ai
        ai = nil
    end
    if not ai then
        delete_buffer(input_buf)
        delete_buffer(display_buf)
        return nil, err
    end

    local session = setmetatable({
        ai = ai,
        display_buf = display_buf,
        input_buf = input_buf,
        destroyed = false,
    }, Session)

    local previous = current
    current = session
    if previous then
        local stopped, stop_err = previous:destroy()
        if not stopped then
            vim.notify(
                "Failed to destroy previous AI session: "
                    .. tostring(stop_err),
                vim.log.levels.ERROR
            )
        end
    end

    return session
end

---Returns the currently selected AI session.
---@return ai.Session?
function Session.get_current()
    return current
end

---Shows the current session, creating it when necessary.
---@param opts? ai.StartOpts
---@return ai.ui.Chat? chat
---@return any? error
function Session.open_current(opts)
    local session = current
    if not session then
        local err
        session, err = Session.new(opts)
        if not session then
            vim.notify(
                "Failed to start AI backend: " .. tostring(err),
                vim.log.levels.ERROR
            )
            return nil, err
        end
    end

    return session:show()
end

---Opens or returns this session's chat view.
---@return ai.ui.Chat
function Session:show()
    assert_active(self)
    if self.chat then
        return self.chat
    end

    self.chat = Chat.new(self.display_buf, self.input_buf, {
        on_submit = function(value)
            self:submit(value)
        end,
        on_stop = function()
            local ok, err = self:destroy()
            if not ok then
                vim.notify(
                    "Failed to stop AI session: " .. tostring(err),
                    vim.log.levels.ERROR
                )
            end
        end,
        on_close = function()
            self.chat = nil
        end,
    })
    return self.chat
end

---Submits one message through the session's required AI instance.
---@param value string
---@return boolean? success
---@return any? error
function Session:submit(value)
    assert_active(self)
    return self.ai:send(value)
end

---Closes the chat window without ending the AI session.
function Session:close_window()
    if self.chat then
        self.chat:close()
    end
end

---Cancels the AI and releases every resource owned by the session.
---@return boolean? success
---@return any? error
function Session:destroy()
    if self.destroyed then
        return true
    end

    self:close_window()
    local errors = {}
    local ok, err = pcall(self.ai.cancel, self.ai)
    if not ok then
        errors[#errors + 1] = tostring(err)
    end

    self.destroyed = true
    if current == self then
        current = nil
    end
    for _, buf in ipairs({ self.input_buf, self.display_buf }) do
        local deleted, delete_err = delete_buffer(buf)
        if not deleted then
            errors[#errors + 1] = tostring(delete_err)
        end
    end

    if #errors > 0 then
        return nil, table.concat(errors, "\n")
    end
    return true
end

---Destroys the currently selected session, when one exists.
---@return boolean? success
---@return any? error
function Session.stop_current()
    if not current then
        return true
    end
    return current:destroy()
end

---Configures the chat view used by new session windows.
---@param opts? table
---@return table
function Session.setup(opts)
    return Chat.setup(opts)
end

return Session
