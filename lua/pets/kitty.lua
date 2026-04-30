-- Direct kitty graphics protocol implementation
local M = { available = false }

if not (os.getenv("KITTY_WINDOW_ID") or (os.getenv("TERM") or ""):find("kitty")) then
    return M
end
M.available = true

local win_state = {} -- win -> { img_id }
local next_img_id = 1

local function write(data)
    if vim.api.nvim_ui_send then
        vim.api.nvim_ui_send(data)
    else
        io.stdout:write(data)
        io.stdout:flush()
    end
end

local b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64encode(data)
    local out = {}
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        b, c = b or 0, c or 0
        local n = a * 65536 + b * 256 + c
        out[#out+1] = b64:sub(math.floor(n/262144)%64+1, math.floor(n/262144)%64+1)
        out[#out+1] = b64:sub(math.floor(n/4096)%64+1, math.floor(n/4096)%64+1)
        out[#out+1] = i+1 <= #data and b64:sub(math.floor(n/64)%64+1, math.floor(n/64)%64+1) or "="
        out[#out+1] = i+2 <= #data and b64:sub(n%64+1, n%64+1) or "="
    end
    return table.concat(out)
end

local function apc(fields, data)
    local parts = {}
    for k, v in pairs(fields) do parts[#parts+1] = k .. "=" .. tostring(v) end
    local msg = "\27_G" .. table.concat(parts, ",") .. (data and (";" .. data) or "") .. "\27\\"
    write(msg)
end

local function upload(path, img_id)
    local f = io.open(path, "rb")
    if not f then return false end
    local raw = f:read("*a"); f:close()
    local enc = b64encode(raw)
    local first = true
    for i = 1, #enc, 4096 do
        local chunk = enc:sub(i, i + 4095)
        local more = (i + 4095 < #enc) and 1 or 0
        if first then
            apc({ a="t", f=100, i=img_id, m=more, q=2 }, chunk)
            first = false
        else
            apc({ m=more, q=2 }, chunk)
        end
    end
    return true
end

local function display(img_id, row, col, h)
    write("\27[s\27[" .. row .. ";" .. (col+1) .. "H")
    apc({ a="p", i=img_id, p=1, C=1, r=h, q=2 })
    write("\27[u")
end

local function png_dims(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local hdr = f:read(24); f:close()
    if not hdr or #hdr < 24 then return nil end
    local w = hdr:byte(17)*16777216 + hdr:byte(18)*65536 + hdr:byte(19)*256 + hdr:byte(20)
    local h = hdr:byte(21)*16777216 + hdr:byte(22)*65536 + hdr:byte(23)*256 + hdr:byte(24)
    return w, h
end

function M.show(path, win, col, row_offset, scale)
    if not path then return end
    local h = scale or 4
    local img_id = next_img_id; next_img_id = next_img_id + 1
    if not upload(path, img_id) then return end
    local s = win_state[win]
    if s then apc({ a="d", d="i", i=s.img_id, q=2 }) end
    win_state[win] = { img_id = img_id }
    local pos = vim.api.nvim_win_get_position(win)
    local row = pos[1] + vim.api.nvim_win_get_height(win) - h - (row_offset or 0)
    display(img_id, row, pos[2] + col, h)
end

function M.clear(win)
    local s = win_state[win]
    if s then apc({ a="d", d="i", i=s.img_id, q=2 }); win_state[win] = nil end
end

function M.clear_all()
    for win in pairs(win_state) do M.clear(win) end
end

function M.image_size(path, scale)
    local h = scale or 4
    local pw, ph = png_dims(path)
    local w = pw and math.max(1, math.ceil(h * pw / ph * 2)) or h * 2
    return { width = w, height = h }
end

return M
