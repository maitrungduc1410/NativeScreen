--!nonstrict
-- NativeScreen bar widget: mirrors the service's "status" and sends commands.
--   Left click   - start recording, or stop the running one
--   Right click  - start recording with the screen picker (choose another screen or window)
--   Middle click - open the recordings folder

noctalia.setUpdateInterval(1000)

local status = { state = "idle", available = false }

local function send(action, payload)
    noctalia.state.set("command", { action = action, payload = payload })
end

local function elapsed()
    local started = status.startedAtMs
    if type(started) ~= "number" then
        return nil
    end
    local seconds = math.max(0, os.time() - math.floor(started / 1000))
    return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local function render()
    local st = status.state or "idle"
    if not status.available then
        barWidget.setGlyph("video-off")
        barWidget.setGlyphColor("on_surface_variant")
        barWidget.setText("")
        barWidget.setTooltip(noctalia.tr("tooltip.missing"))
        barWidget.setVisible(not noctalia.getConfig("hide_inactive"))
        return
    end
    if st == "recording" then
        barWidget.setGlyph("player-stop-filled")
        barWidget.setGlyphColor("error")
        barWidget.setColor("error")
        barWidget.setText(elapsed() or "")
        barWidget.setTooltip(noctalia.tr("tooltip.recording"))
        barWidget.setVisible(true)
    elseif st == "picking" or st == "finishing" then
        barWidget.setGlyph("loader-2")
        barWidget.setGlyphColor("primary")
        barWidget.setColor("primary")
        barWidget.setText("")
        barWidget.setTooltip(noctalia.tr(if st == "picking" then "tooltip.picking" else "tooltip.finishing"))
        barWidget.setVisible(true)
    else
        barWidget.setGlyph("video")
        barWidget.setGlyphColor("on_surface")
        barWidget.setText("")
        barWidget.setTooltip(noctalia.tr("tooltip.idle"))
        barWidget.setVisible(not noctalia.getConfig("hide_inactive"))
    end
end

local function apply(value)
    if type(value) == "table" then
        status = value
    end
    render()
end

function update()
    if status.state == "recording" then
        render()
    end
end

function onClick()
    if not status.available then
        return
    end
    if status.state == "recording" or status.state == "picking" then
        send("stop")
    elseif status.state == "idle" then
        send("start")
    end
end

function onRightClick()
    if status.available and status.state == "idle" then
        send("start", "pick")
    end
end

function onMiddleClick()
    local dir = noctalia.getConfig("directory")
    if type(dir) ~= "string" or dir == "" then
        dir = "~/Videos/NativeScreen"
    end
    noctalia.runAsync({ "xdg-open", noctalia.expandPath(dir) })
end

apply(noctalia.state.get("status"))
noctalia.state.watch("status", apply)
