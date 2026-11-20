--!nonstrict
-- NativeScreen recorder service (headless, one per session).
--
-- Owns nothing but a detached `nativescreen record` process. The process publishes its state in
-- $XDG_RUNTIME_DIR/nativescreen/status.json; this service polls that file and mirrors it into the
-- shared "status" state for the widget and the shortcut. Commands arrive on the "command" state
-- channel or over IPC:
--
--   noctalia msg plugin nativescreen/recorder:service all toggle
--   noctalia msg plugin nativescreen/recorder:service all start [pick]
--   noctalia msg plugin nativescreen/recorder:service all stop

noctalia.setUpdateInterval(500)

local function log(msg)
    noctalia.log("nativescreen: " .. msg)
end

local function binary()
    local configured = noctalia.getConfig("binary")
    if type(configured) == "string" and configured ~= "" then
        return noctalia.expandPath(configured)
    end
    return "nativescreen"
end

local function statusPath()
    local runtime = noctalia.getenv("XDG_RUNTIME_DIR") or "/tmp"
    return runtime .. "/nativescreen/status.json"
end

local available = false
local current = { state = "idle" }
-- Set between our start request and the recorder writing its first status.
local launching = false
local launchedAt = 0

local function publish()
    local status = table.clone(current)
    status.available = available
    if launching and status.state == "idle" then
        status.state = "picking"
    end
    noctalia.state.set("status", status)
end

local function checkAvailable()
    local bin = binary()
    available = if string.find(bin, "/", 1, true) then noctalia.fileExists(bin) else noctalia.commandExists(bin)
end

local function readStatus()
    local text = noctalia.readFile(statusPath())
    if not text or text == "" then
        return { state = "idle" }
    end
    local ok, value = pcall(noctalia.json.decode, text)
    if not ok or type(value) ~= "table" then
        return current
    end
    return value
end

local function onTransition(old, new)
    if old.state == new.state then
        return
    end
    log(`state {old.state} -> {new.state}`)
    if new.state == "recording" then
        launching = false
        if (new.inputDevices or 0) == 0 then
            noctalia.notify(noctalia.tr("notify.recording"), noctalia.tr("notify.no-input"))
        end
    elseif new.state == "idle" and (old.state == "recording" or old.state == "finishing") then
        if new.package and (new.frames or 0) > 0 then
            noctalia.notify(noctalia.tr("notify.saved"), new.package)
        else
            noctalia.notifyError(noctalia.tr("notify.failed"), new.message or "")
        end
    elseif new.state == "idle" and old.state == "picking" then
        launching = false
        if new.message and new.message ~= "" then
            noctalia.notifyError(noctalia.tr("notify.failed"), new.message)
        end
    end
end

local function start(pick)
    if not available then
        noctalia.notifyError(noctalia.tr("notify.failed"), noctalia.tr("notify.missing", { bin = binary() }))
        return
    end
    if current.state ~= "idle" or launching then
        return
    end
    local argv = { binary(), "record" }
    local dir = noctalia.getConfig("directory")
    if type(dir) == "string" and dir ~= "" then
        table.insert(argv, "--dir")
        table.insert(argv, noctalia.expandPath(dir))
    end
    if pick then table.insert(argv, "--pick") end
    if noctalia.getConfig("allow_window") then table.insert(argv, "--window") end
    if noctalia.getConfig("microphone") then table.insert(argv, "--mic") end
    if noctalia.getConfig("system_audio") == false then table.insert(argv, "--no-system-audio") end
    if noctalia.getConfig("typed_keys") then table.insert(argv, "--typed-keys") end
    if noctalia.getConfig("auto_zoom") == false then table.insert(argv, "--no-auto-zoom") end
    local quality = noctalia.getConfig("quality")
    if type(quality) == "number" then
        table.insert(argv, "--quality")
        table.insert(argv, tostring(math.floor(quality)))
    end
    log("start: " .. table.concat(argv, " "))
    if noctalia.runAsync(argv) then
        launching = true
        launchedAt = os.time()
        publish()
    else
        noctalia.notifyError(noctalia.tr("notify.failed"), noctalia.tr("notify.missing", { bin = binary() }))
    end
end

local function stop()
    log("stop")
    noctalia.runAsync({ binary(), "stop" })
end

function onIpc(event, payload)
    if event == "start" then
        start(payload == "pick")
    elseif event == "stop" then
        stop()
    elseif event == "toggle" then
        if current.state == "recording" or current.state == "picking" or launching then
            stop()
        else
            start(payload == "pick")
        end
    end
end

function update()
    local new = readStatus()
    -- A recorder that died without writing "idle" (killed -9) still has a pid in the file.
    if new.state ~= "idle" and new.pid then
        local info = noctalia.fileInfo("/proc/" .. tostring(new.pid))
        if not info then
            new = { state = "idle" }
        end
    end
    -- The portal dialog can take a while; give up waiting for the process after 2 minutes.
    if launching and new.state == "idle" and os.time() - launchedAt > 120 then
        launching = false
    end
    local old = current
    current = new
    onTransition(old, new)
    publish()
end

function onConfigChanged()
    checkAvailable()
    publish()
end

function onExit()
    if current.state == "recording" then
        stop()
    end
end

noctalia.state.watch("command", function(cmd)
    if type(cmd) == "table" and cmd.action then
        onIpc(cmd.action, cmd.payload)
        -- Clear it so the same command can be sent again.
        noctalia.state.set("command", nil)
    end
end)

checkAvailable()
current = readStatus()
publish()
