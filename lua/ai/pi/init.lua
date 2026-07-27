---@class ai.Pi: ai.Backend
---@field process vim.SystemObj
---@field dispatch ai.Dispatcher
---@field stdout_tail string
---@field pending_prompts table<string, ai.UserEvent>
---@field request_id integer
---@field cancelled boolean
---@field stdin_closed boolean
---@field result? vim.SystemCompleted
local Pi = {}
Pi.__index = Pi

local Command = require("ai.pi.command")
local Events = require("ai.events")

local AIAction = Events.AIAction
local EventType = Events.Type

-- Decodes one JSON event line without raising parse errors.
local function decode_event(line)
    local ok, decoded = pcall(vim.json.decode, line)
    if not ok then
        return nil
    end
    return decoded
end

-- Converts a Pi RPC event into the backend-neutral event model.
---@param event table?
---@return ai.BackendEvent?
local function normalize(event)
    if type(event) ~= "table" or not event.type then
        return nil
    end

    if event.type == "agent_start" then
        return {
            type = EventType.AI,
            action = AIAction.THINKING,
        }
    end

    if event.type == "message_update" then
        local delta = event.assistantMessageEvent
        if delta and delta.type == "text_delta" then
            return {
                type = EventType.AI,
                action = AIAction.TEXT,
                content = delta.delta or "",
            }
        end
        if delta and delta.type == "thinking_delta" then
            return {
                type = EventType.AI,
                action = AIAction.THINKING,
            }
        end
        if delta and delta.type == "error" then
            return {
                type = EventType.ERROR,
                message = delta.reason or "unknown error",
                source = "agent",
            }
        end
        return nil
    end

    if event.type == "tool_execution_start" then
        return {
            type = EventType.AI,
            action = AIAction.TOOL_START,
            tool = event.toolName or "unknown",
        }
    end

    if event.type == "tool_execution_end" then
        return {
            type = EventType.AI,
            action = AIAction.TOOL_END,
            tool = event.toolName or "unknown",
        }
    end

    if event.type == "agent_settled" then
        return {
            type = EventType.AI,
            action = AIAction.DONE,
        }
    end

    if event.type == "response" and event.success == false then
        return {
            type = EventType.ERROR,
            message = event.error or "unknown error",
            source = "agent",
        }
    end

    return nil
end

---Dispatches the user event accepted by a correlated prompt response.
---@param response table
function Pi:handle_prompt_response(response)
    local id = response.id
    local event = type(id) == "string" and self.pending_prompts[id] or nil
    if not event then
        self.dispatch({
            type = EventType.ERROR,
            message = "unexpected prompt response id: " .. tostring(id),
            source = "protocol",
        })
        return
    end

    self.pending_prompts[id] = nil
    if response.success == true then
        self.dispatch(event)
        return
    end

    self.dispatch({
        type = EventType.ERROR,
        message = response.error or "prompt rejected",
        source = "agent",
    })
end

---Decodes and dispatches one complete Pi JSONL record.
---@param line string
function Pi:process_stdout_line(line)
    local event = decode_event(line)
    if not event then
        self.dispatch({
            type = EventType.ERROR,
            message = line,
            source = "protocol",
        })
        return
    end

    if event.type == "response" and event.command == "prompt" then
        self:handle_prompt_response(event)
        return
    end

    local normalized = normalize(event)
    if normalized then
        self.dispatch(normalized)
    end
end

---Adds a stdout chunk and dispatches every complete non-empty line.
---@param chunk? string
function Pi:feed_stdout(chunk)
    if not chunk or chunk == "" then
        return
    end

    self.stdout_tail = self.stdout_tail .. chunk

    local newline = self.stdout_tail:find("\n", 1, true)
    while newline do
        local line = self.stdout_tail:sub(1, newline - 1)
        self.stdout_tail = self.stdout_tail:sub(newline + 1)

        if line ~= "" then
            self:process_stdout_line(line)
        end

        newline = self.stdout_tail:find("\n", 1, true)
    end
end

---Dispatches and clears the final unterminated stdout line.
function Pi:flush_stdout()
    local tail = self.stdout_tail
    self.stdout_tail = ""
    if tail ~= "" then
        self:process_stdout_line(tail)
    end
end

---Writes a payload to Pi or closes its standard input.
---@param payload? string Passing nil closes stdin.
---@return boolean? success
---@return any? error
function Pi:write(payload)
    local ok, err = pcall(self.process.write, self.process, payload)
    if not ok then
        return nil, err
    end

    if payload == nil then
        self.stdin_closed = true
    end
    return true
end

---Encodes and sends one user event to Pi.
---@param event ai.UserEvent
---@return boolean? success
---@return any? error
function Pi:send(event)
    assert(type(event) == "table", "user event is required")
    assert(event.type == EventType.USER, "Pi only accepts user events")
    assert(
        type(event.content) == "string" and event.content ~= "",
        "user event content is required"
    )

    self.request_id = self.request_id + 1
    local id = "prompt_" .. self.request_id
    self.pending_prompts[id] = event

    local payload = vim.json.encode({
        id = id,
        type = "prompt",
        message = event.content,
    }) .. "\n"
    local ok, err = self:write(payload)
    if not ok then
        self.pending_prompts[id] = nil
    end
    return ok, err
end

---Closes Pi's input so the process can finish normally.
---@return boolean? success
---@return any? error
function Pi:finish()
    if self.stdin_closed then
        return true
    end

    local ok, err = self:write(nil)
    if not ok then
        pcall(self.process.kill, self.process, 15)
    end
    return ok, err
end

---Cancels Pi and discards any buffered process output.
function Pi:cancel()
    self.cancelled = true
    self.stdout_tail = ""
    self.pending_prompts = {}

    local ok, closing = pcall(self.process.is_closing, self.process)
    if not ok or not closing then
        pcall(self.process.kill, self.process, 15)
    end
end

---Builds the command used to launch the Pi RPC process.
Pi.get_cmd = Command.build

---Starts a Pi process and dispatches normalized backend events.
---@param opts ai.PiOpts
---@param dispatch ai.Dispatcher
---@return ai.Pi? pi
---@return any? error
function Pi.start(opts, dispatch)
    assert(type(opts) == "table", "Pi options are required")
    assert(type(dispatch) == "function", "Pi dispatcher is required")

    local pi = setmetatable({
        dispatch = dispatch,
        stdout_tail = "",
        pending_prompts = {},
        request_id = 0,
        cancelled = false,
        stdin_closed = false,
        result = nil,
    }, Pi)

    local ok, process = pcall(vim.system, Command.build(opts), {
        text = true,
        stdin = true,
        -- Feeds scheduled stdout chunks into the Pi line buffer.
        stdout = vim.schedule_wrap(function(err, data)
            if err then
                pi.dispatch({
                    type = EventType.ERROR,
                    message = tostring(err),
                    source = "stdout",
                })
                return
            end
            if not pi.cancelled then
                pi:feed_stdout(data)
            end
        end),
    }, vim.schedule_wrap(function(result)
        -- Flushes buffered output and reports process completion.
        pi:flush_stdout()
        pi.pending_prompts = {}
        pi.result = result
        pi.dispatch({
            type = EventType.EXIT,
            result = pi.result,
        })
    end))

    if not ok then
        return nil, process
    end

    pi.process = process
    return pi
end

return Pi
