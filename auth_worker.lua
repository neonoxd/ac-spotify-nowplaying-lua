-- Auth server worker - runs on a background thread.
-- Listens for "AuthServer.Start" shared event with {port = number},
-- broadcasts "AuthServer.Code" / "AuthServer.Error" back to the main script.
-- Exits after completing one job so old workers never accumulate.
local socket = require("shared/socket")

ac.log("AuthServer worker: loading...")

local running = false
local stopped = false
local pendingPort = nil
local server = nil

ac.onSharedEvent("AuthServer.Start", function(data)
    if not data or not data.port then return end
    -- Only accept one start; ignore stale broadcasts received by old workers
    if pendingPort or running then return end
    pendingPort = data.port
    ac.log("AuthServer worker: queued start on port " .. tostring(data.port))
end)

-- Main worker loop
while true do
    worker.sleep(0.1)

    if stopped then
        break
    end

    if pendingPort then
        local port = pendingPort
        pendingPort = nil

        local bindErr
        server, bindErr = socket.bind("127.0.0.1", port)
        if not server then
            ac.broadcastSharedEvent("AuthServer.Error", { error = "bind failed on port " .. tostring(port) .. ": " .. tostring(bindErr) })
            break
        end

        server:settimeout(5)
        running = true
        ac.broadcastSharedEvent("AuthServer.Status", { status = "listening", port = port })
        ac.log("AuthServer worker: listening on port " .. port)

        while running do
            local client = server:accept()
            if client then
                client:settimeout(1)
                local request = client:receive("*l")

                if request then
                    local method, path = request:match("^(%w+)%s+([^%s]+)")
                    if method == "GET" and path and path:match("^/callback") then
                        local query = path:match("%?(.*)")
                        local params = {}
                        if query then
                            for key, value in query:gmatch("([^&=]+)=([^&=]+)") do
                                params[key] = value
                            end
                        end

                        client:send(
                            "HTTP/1.1 200 OK\r\n" ..
                            "Content-Type: text/html\r\n" ..
                            "Connection: close\r\n\r\n" ..
                            [[<html><head><title>Spotify Authorization - Success</title></head>
                            <body style="font-family: Arial; text-align: center; padding: 40px;">
                            <h1>Authorization Successful!</h1>
                            <p style="font-size: 16px; color: green;">Authorization code has been captured</p>
                            <p>You can now return to Assetto Corsa</p>
                            <p style="font-size: 12px; color: gray;">This window can be closed.</p>
                            </body></html>]]
                        )
                        client:close()

                        ac.broadcastSharedEvent("AuthServer.Code", { code = params.code or "" })
                        running = false
                    else
                        client:close()
                    end
                else
                    client:close()
                end
            end
            worker.sleep(0.1)
        end

        if server then
            server:close()
            server = nil
        end
        
        break
    end
end