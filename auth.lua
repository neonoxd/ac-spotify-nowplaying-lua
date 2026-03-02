local AuthServer = {}

AuthServer._worker = nil
AuthServer._running = false
AuthServer._onCodeReceived = nil

ac.onSharedEvent("AuthServer.Status", function(data)
    if data and data.status == "listening" then
        ac.log("AuthServer: Listening on port " .. tostring(data.port))
        AuthServer._running = true
    end
end)

ac.onSharedEvent("AuthServer.Error", function(data)
    ac.error("AuthServer: Error: " .. tostring(data and data.error or "unknown"))
    AuthServer._running = false
    AuthServer._worker = nil
    AuthServer._onCodeReceived = nil
end)

ac.onSharedEvent("AuthServer.Code", function(data)
    if not data then return end
    ac.log("AuthServer: Received auth code: " .. (data.code ~= "" and (data.code:sub(1, 5) .. "...") or "(empty)"))
    AuthServer._running = false
    AuthServer._worker = nil
    local cb = AuthServer._onCodeReceived
    AuthServer._onCodeReceived = nil
    if cb and data.code ~= "" then
        cb(data.code)
    end
end)

function AuthServer.StartAuthServer(port, onCodeReceived)
    ac.log("AuthServer: Starting on port " .. tostring(port))
    if AuthServer._worker then
        ac.error("AuthServer: Already running, stop first")
        return
    end

    AuthServer._onCodeReceived = onCodeReceived

    -- Spin up the worker thread
    AuthServer._worker = ac.startBackgroundWorker("auth_worker")

    -- Delay the broadcast slightly to ensure the worker is ready to receive
    setTimeout(function()
        local l = ac.broadcastSharedEvent("AuthServer.Start", { port = port })
        ac.log("AuthServer: Broadcasted start event, listeners: " .. tostring(l))
    end, 1)
end

function AuthServer.isRunning()
    return AuthServer._running
end

return AuthServer