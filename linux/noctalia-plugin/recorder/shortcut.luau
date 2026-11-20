--!nonstrict
-- NativeScreen control-center tile: mirrors "status", sends "command".
-- Left click toggles recording; right click starts with the screen picker.

local status = { state = "idle", available = false }

local function apply(value)
    if type(value) == "table" then
        status = value
    end
    local active = status.state == "recording" or status.state == "picking" or status.state == "finishing"
    shortcut.setLabel(noctalia.tr(if status.state == "recording" then "shortcut.recording" else "shortcut.record"))
    shortcut.setIcon("video", "video-off")
    shortcut.setActive(active)
    shortcut.setEnabled(status.available == true)
end

function onClick()
    noctalia.state.set("command", { action = "toggle" })
end

function onRightClick()
    if status.state == "idle" then
        noctalia.state.set("command", { action = "start", payload = "pick" })
    end
end

apply(noctalia.state.get("status"))
noctalia.state.watch("status", apply)
