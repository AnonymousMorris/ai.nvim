local M = {}

local Config = require("ai.config")
local Events = require("ai.events")
local Pi = require("ai.pi")
local Transcript = require("ai.transcript")

local EventType = Events.Type

---@class ai.Backend
---Backend events must not be dispatched before start() returns.
---Accepted user events must be dispatched exactly once by the backend.
---@field start fun(opts: ai.StartOpts, dispatch: ai.Dispatcher): ai.Backend?, any?
---@field send fun(self: ai.Backend, event: ai.UserEvent): boolean?, any?
---@field interrupt fun(self: ai.Backend): boolean?, any?
---@field finish fun(self: ai.Backend): boolean?, any?
---@field cancel fun(self: ai.Backend)

---@type table<string, ai.Backend>
local backends = {}
local config = Config.backend()

---Registers a backend implementation under a selectable name.
---@param name string
---@param backend ai.Backend
function M.register_backend(name, backend)
    assert(type(name) == "string" and name ~= "", "backend name is required")
    assert(type(backend) == "table", "backend must be a table")
    for _, method in ipairs({ "start", "send", "interrupt", "finish", "cancel" }) do
        assert(
            type(backend[method]) == "function",
            ("backend must implement %s()"):format(method)
        )
    end
    backends[name] = backend
end

M.register_backend("pi", Pi)

---Stores the default configuration used for new AI instances.
---@param opts? table
---@return table
function M.setup(opts)
    config = Config.backend(opts)
    return vim.deepcopy(config)
end

---@class ai.AI
---@field backend_name string
---@field backend ai.Backend
---@field transcript ai.Transcript
---@field status "starting"|"idle"|"thinking"|"tool"|"error"|"exited"|"cancelled"
---@field error? any
---@field result? vim.SystemCompleted
local AI = {}
AI.__index = AI

---Moves the AI into an error state and reports it to the user.
---@param err any
function AI:handle_error(err)
    pcall(self.transcript.finish_turn, self.transcript)
    self.status = "error"
    self.error = err
    vim.notify("AI error: " .. tostring(err), vim.log.levels.ERROR)
end

---Applies an event accepted or emitted by the backend.
---@param event ai.Event
function AI:dispatch(event)
    if type(event) ~= "table" then
        self:handle_error("backend event must be a table")
        return
    end

    if event.type == EventType.USER or event.type == EventType.AI then
        local ok, status = pcall(
            self.transcript.apply,
            self.transcript,
            event
        )
        if not ok then
            self:handle_error(status)
        elseif status then
            self.status = status
        end
    elseif event.type == EventType.ERROR then
        self:handle_error(event.message)
    elseif event.type == EventType.EXIT then
        pcall(self.transcript.finish_turn, self.transcript)
        self.result = event.result
        if self.status ~= "cancelled" then
            self.status = "exited"
        end
    else
        self:handle_error(
            "unknown backend event type: " .. tostring(event.type)
        )
    end
end

---Submits one user message through the active backend.
---@param message string
---@return boolean? success
---@return any? error
function AI:send(message)
    assert(type(message) == "string" and message ~= "", "message is required")

    ---@type ai.UserEvent
    local event = {
        type = EventType.USER,
        content = message,
    }
    self.error = nil
    local called, ok, err = pcall(self.backend.send, self.backend, event)
    if not called then
        err = ok
        ok = nil
    end
    if not ok then
        self:handle_error(err)
    end
    return ok, err
end

---Interrupts the current backend turn without ending the AI session.
---@return boolean? success
---@return any? error
function AI:interrupt()
    local called, ok, err = pcall(self.backend.interrupt, self.backend)
    if not called then
        err = ok
        ok = nil
    end
    if not ok then
        self:handle_error(err)
    end
    return ok, err
end

---Signals that no more messages will be sent to the backend.
---@return boolean? success
---@return any? error
function AI:finish()
    return self.backend:finish()
end

---Cancels the AI instance and its active backend.
function AI:cancel()
    self.status = "cancelled"
    pcall(self.transcript.finish_turn, self.transcript)
    return self.backend:cancel()
end

---@class ai.SessionOpts
---@field backend? string
---@field cmd? string[] Backend-specific process command.

---@class ai.StartOpts: ai.SessionOpts
---@field agent_spawn_dir string Internal working directory for the agent.

---Creates an AI instance backed by the configured provider.
---@param buf integer Transcript buffer handle.
---@param opts ai.StartOpts
---@return ai.AI? ai
---@return any? error
function M.start(buf, opts)
    assert(
        type(buf) == "number" and vim.api.nvim_buf_is_valid(buf),
        "display buffer is required"
    )
    assert(type(opts) == "table", "AI start options are required")
    assert(
        type(opts.agent_spawn_dir) == "string"
            and opts.agent_spawn_dir ~= "",
        "agent spawn directory is required"
    )

    opts = vim.tbl_deep_extend("force", {}, config, opts)
    local backend_name = opts.backend or "pi"
    local backend = backends[backend_name]
    if not backend then
        return nil, ("unknown AI backend: %s"):format(backend_name)
    end

    local ai = setmetatable({
        backend_name = backend_name,
        status = "starting",
        transcript = Transcript.new(buf),
    }, AI)

    local ok, instance, err = pcall(
        backend.start,
        opts,
        function(event)
            ai:dispatch(event)
        end
    )
    if not ok then
        return nil, instance
    end
    if not instance then
        return nil, err
    end

    ai.backend = instance
    ai.status = "idle"
    return ai
end

return M
