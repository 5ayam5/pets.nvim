-- Direct kitty graphics protocol implementation
local M = { available = false }

if not (os.getenv("KITTY_WINDOW_ID") or (os.getenv("TERM") or ""):find("kitty")) then
    return M
end
M.available = true

local win_state = {} -- key -> { img_id }
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
        out[#out + 1] = b64:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
        out[#out + 1] = b64:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
        out[#out + 1] = i + 1 <= #data and b64:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or "="
        out[#out + 1] = i + 2 <= #data and b64:sub(n % 64 + 1, n % 64 + 1) or "="
    end
    return table.concat(out)
end

local function apc(fields, data)
    local parts = {}
    for k, v in pairs(fields) do
        parts[#parts + 1] = k .. "=" .. tostring(v)
    end
    local msg = "\27_G" .. table.concat(parts, ",") .. (data and (";" .. data) or "") .. "\27\\"
    write(msg)
end

local function upload(path, img_id)
    local f = io.open(path, "rb")
    if not f then
        return false
    end
    local raw = f:read("*a")
    f:close()
    local enc = b64encode(raw)
    local first = true
    for i = 1, #enc, 4096 do
        local chunk = enc:sub(i, i + 4095)
        local more = (i + 4095 < #enc) and 1 or 0
        if first then
            apc({ a = "t", f = 100, i = img_id, m = more, q = 2 }, chunk)
            first = false
        else
            apc({ m = more, q = 2 }, chunk)
        end
    end
    return true
end

local function display(img_id, row, col, h, w)
    write("\27[s\27[" .. row .. ";" .. (col + 1) .. "H")
    apc({ a = "p", i = img_id, p = 1, C = 1, c = w, r = h, q = 2 })
    write("\27[u")
end

local function png_dims(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local hdr = f:read(24)
    f:close()
    if not hdr or #hdr < 24 then
        return nil
    end
    local w = hdr:byte(17) * 16777216 + hdr:byte(18) * 65536 + hdr:byte(19) * 256 + hdr:byte(20)
    local h = hdr:byte(21) * 16777216 + hdr:byte(22) * 65536 + hdr:byte(23) * 256 + hdr:byte(24)
    return w, h
end

local cell_size = nil
local function get_cell_size()
    if cell_size then
        return cell_size
    end
    local ok, ffi = pcall(require, "ffi")
    if ok then
        pcall(function()
            ffi.cdef([[typedef struct { unsigned short row,col,xpixel,ypixel; } winsize; int ioctl(int,int,...);]])
            local TIOCGWINSZ = jit.os == "OSX" and 0x40087468 or 0x5413
            local sz = ffi.new("winsize")
            ---@diagnostic disable-next-line
            if ffi.C.ioctl(1, TIOCGWINSZ, sz) == 0 and sz.col > 0 then
                ---@diagnostic disable-next-line
                cell_size = { w = sz.xpixel / sz.col, h = sz.ypixel / sz.row }
            end
        end)
    end
    cell_size = cell_size or { w = 9, h = 18 }
    return cell_size
end

-- @param key identifies the owner of the image so the previous frame can be replaced
-- @param col absolute editor column to draw the image at
function M.show(path, key, col, row_offset, scale, avoid_statusline)
    if not path then
        return nil
    end

    local h = scale or 4
    local img_id = next_img_id
    next_img_id = next_img_id + 1
    if not upload(path, img_id) then
        return nil
    end
    local s = win_state[key]
    if s then
        M.clear_image(s.img_id)
    end
    win_state[key] = { img_id = img_id }
    local bottom = vim.o.lines - (avoid_statusline and 2 or 1)
    local row = bottom - h + 1 - (row_offset or 0)
    -- compute cell width from PNG aspect ratio and terminal cell pixel size
    local pw, ph = png_dims(path)
    local cs = get_cell_size()
    local w = pw and math.max(1, math.ceil(h * (pw / ph) * (cs.h / cs.w))) or h * 2
    display(img_id, row, col, h, w)
    return img_id
end

function M.clear_image(img_id)
    if not img_id then
        return
    end
    apc({ a = "d", d = "i", i = img_id, q = 2 })
end

function M.clear(key)
    local s = win_state[key]
    if s then
        M.clear_image(s.img_id)
        win_state[key] = nil
    end
end

function M.clear_all()
    for key in pairs(win_state) do
        M.clear(key)
    end
end

function M.image_size(path, scale)
    local h = scale or 4
    local pw, ph = png_dims(path)
    local cs = get_cell_size()
    local w = pw and math.max(1, math.ceil(h * (pw / ph) * (cs.h / cs.w))) or h * 2
    return { width = w, height = h }
end

return M
