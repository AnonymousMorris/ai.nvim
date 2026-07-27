local M = {}

---@enum ai.Role
M.Role = {
    USER = "user",
    AGENT = "agent",
}

---@enum ai.EventType
M.Type = {
    USER = "user",
    AI = "ai",
    ERROR = "error",
    EXIT = "exit",
}

---@enum ai.AIAction
M.AIAction = {
    TEXT = "text",
    THINKING = "thinking",
    TOOL_START = "tool_start",
    TOOL_END = "tool_end",
    DONE = "done",
}

---@class (exact) ai.UserEvent
---@field type "user"
---@field content string

---@class (exact) ai.AITextEvent
---@field type "ai"
---@field action "text"
---@field content string

---@class (exact) ai.AIThinkingEvent
---@field type "ai"
---@field action "thinking"

---@class (exact) ai.AIToolStartEvent
---@field type "ai"
---@field action "tool_start"
---@field tool string

---@class (exact) ai.AIToolEndEvent
---@field type "ai"
---@field action "tool_end"
---@field tool? string

---@class (exact) ai.AIDoneEvent
---@field type "ai"
---@field action "done"

---@class (exact) ai.ErrorEvent
---@field type "error"
---@field message string
---@field source? "agent"|"stdout"|"stderr"|"protocol"

---@class (exact) ai.ExitEvent
---@field type "exit"
---@field result vim.SystemCompleted

---@alias ai.AIEvent
---| ai.AITextEvent
---| ai.AIThinkingEvent
---| ai.AIToolStartEvent
---| ai.AIToolEndEvent
---| ai.AIDoneEvent

---@alias ai.BackendEvent ai.AIEvent|ai.ErrorEvent|ai.ExitEvent
---@alias ai.Event ai.UserEvent|ai.BackendEvent
---@alias ai.Dispatcher fun(event: ai.Event)

local roles = {
    [M.Type.USER] = M.Role.USER,
    [M.Type.AI] = M.Role.AGENT,
    [M.Type.ERROR] = M.Role.AGENT,
}

---Returns the transcript role encoded by an event type.
---@param event_type ai.EventType
---@return ai.Role
function M.role(event_type)
    return assert(
        roles[event_type],
        "event does not have a transcript role: " .. tostring(event_type)
    )
end

return M
