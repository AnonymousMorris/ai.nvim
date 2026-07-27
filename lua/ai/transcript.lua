local M = {}

local Display = require("ai.ui.display")
local Events = require("ai.events")

local AIAction = Events.AIAction
local EventType = Events.Type

local separator = "---"

---@class ai.Transcript
---@field buf integer
---@field role? ai.Role
---@field current_tool? string
---@field spinner ai.ui.Spinner
local Transcript = {}
Transcript.__index = Transcript

---Creates a transcript renderer for an existing buffer.
---@param buf integer
---@return ai.Transcript
function M.new(buf)
    assert(
        type(buf) == "number" and vim.api.nvim_buf_is_valid(buf),
        "transcript buffer is required"
    )

    return setmetatable({
        buf = buf,
        spinner = Display.spinner(buf),
    }, Transcript)
end

---Transitions the transcript to a role, or closes it with nil.
---@param role? ai.Role
---@return boolean changed
function Transcript:set_role(role)
    if self.role == role then
        return false
    end

    self.spinner:set(nil)
    if Display.last_nonempty_line(self.buf) ~= separator then
        Display.empty_row(self.buf)
        Display.append(self.buf, separator .. "\n")
    end
    self.role = role
    return true
end

---Appends one user or AI text event under its transcript role.
---@param event ai.UserEvent|ai.AITextEvent
function Transcript:append(event)
    local role = Events.role(event.type)
    local role_changed = self:set_role(role)
    local label = role .. ": "
    if role_changed then
        Display.replace(self.buf, Display.empty_row(self.buf), label)
    else
        self.spinner:set(nil, label)
    end
    Display.append(self.buf, event.content)
end

---Finishes the active turn and clears presentation state.
function Transcript:finish_turn()
    local ok, err = pcall(self.set_role, self, nil)
    self.role = nil
    self.current_tool = nil
    if not ok then
        error(err)
    end
end

---Renders an event and returns its AI status transition.
---@param event ai.UserEvent|ai.AIEvent
---@return "idle"|"thinking"|"tool"|nil status
function Transcript:apply(event)
    if event.type == EventType.USER then
        if event.content ~= "" then
            self:append(event)
        end
        return
    end

    if event.type ~= EventType.AI then
        error("unsupported transcript event type: " .. tostring(event.type))
    end

    if event.action == AIAction.TEXT then
        if event.content ~= "" then
            self:append(event)
        end
        return
    end

    self:set_role(Events.role(event.type))
    if event.action == AIAction.THINKING then
        self.spinner:set("thinking")
        return "thinking"
    elseif event.action == AIAction.TOOL_START then
        self.current_tool = event.tool
        self.spinner:set("tool", event.tool)
        return "tool"
    elseif event.action == AIAction.TOOL_END then
        local tool = event.tool or self.current_tool or "unknown"
        self.current_tool = nil
        self.spinner:set(nil, "✓ Tool complete: " .. tool)
        self.spinner:set("thinking")
        return "thinking"
    elseif event.action == AIAction.DONE then
        self:finish_turn()
        return "idle"
    end

    error("unknown AI action: " .. tostring(event.action))
end

return M
