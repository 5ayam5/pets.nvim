local M = {}
M.Animation = {}
M.Animation.__index = M.Animation

local utils = require("pets.utils")
local listdir = utils.listdir
local kitty = require("pets.kitty")

-- resolve a number or a percentage string ("30%") against total
local function resolve(value, total)
    if type(value) == "string" and value:sub(-1) == "%" then
        return math.floor(total * (tonumber(value:sub(1, -2)) or 0) / 100)
    end
    return tonumber(value) or 0
end

function M.Animation.new(sourcedir, type, style, user_opts, state)
    local instance = setmetatable({}, M.Animation)
    instance.type = type
    instance.style = style
    instance.frame_counter = 1
    instance.actions = listdir(sourcedir)
    instance.frames = {}
    instance.area_opts = user_opts.popup
    instance.state = state
    instance.speed_multiplier = user_opts.speed_multiplier
    instance.scale = user_opts.scale
    instance.avoid_statusline = user_opts.popup.avoid_statusline

    for _, action in pairs(instance.actions) do
        local current_frames = {}
        for _, file in pairs(listdir(sourcedir .. action)) do
            table.insert(current_frames, sourcedir .. action .. "/" .. file)
        end
        instance.frames[action] = current_frames
    end

    local frame_width = kitty.image_size(
        sourcedir .. instance.actions[1] .. "/" .. listdir(sourcedir .. instance.actions[1])[1],
        instance.scale
    ).width
    instance.max_frame_width = frame_width
    local max_col = math.max(0, instance:area().width - frame_width)
    instance.base_col = math.min(user_opts.col, max_col)
    instance.row, instance.col = user_opts.row, math.random(instance.base_col, max_col)

    local pet = vim.tbl_deep_extend("keep", require("pets.pets." .. type), utils.default_pet_table)
    instance.next_actions = pet.next_actions
    instance.idle_actions = pet.idle_actions
    instance.movements = pet.movements
    instance.first_action = pet.first_action
    instance.get_death_animation = pet.get_death_animation

    return instance
end

-- the editor columns the pet can walk in, recomputed so it follows resizes
function M.Animation:area()
    local columns = vim.o.columns
    local width = math.max(0, math.min(columns, resolve(self.area_opts.width, columns)))
    local col = math.max(0, math.min(columns - width, resolve(self.area_opts.col, columns - width)))
    return { col = col, width = width }
end

function M.Animation:start_timer()
    if self.timer ~= nil then
        self:stop_timer()
    end
    self.timer = vim.loop.new_timer()
    self.timer:start(0, 1000 / (self.speed_multiplier * 8), function()
        vim.schedule(function()
            M.Animation.next_frame(self)
        end)
    end)
end

function M.Animation:stop_timer()
    if self.timer == nil then
        return
    end
    self.timer:stop()
    self.timer:close()
    self.timer = nil
end

function M.Animation:start()
    self.timer = nil
    self.repetitions = 0
    if self.state.idle then
        self.current_action = self.idle_actions[math.random(#self.idle_actions)]
    else
        self.current_action = self.current_action or self.first_action
    end
    if not self.state.paused and not self.state.hidden then
        M.Animation.start_timer(self)
    elseif self.state.paused and not self.state.hidden then
        vim.schedule(function()
            M.Animation.next_frame(self)
        end)
    end
end

function M.Animation:stop()
    kitty.clear(self)
    kitty.clear_image(self.kitty_img_id)
    self.kitty_img_id = nil
    self.current_image = nil
    self:stop_timer()
end

local function rects_overlap(a, b)
    return a.row < b.row + b.height and b.row < a.row + a.height and a.col < b.col + b.width and b.col < a.col + a.width
end

-- check if any visible floating window in the current tab overlaps the pet
function M.Animation:pet_is_covered(col, row_offset)
    local height = self.scale or 4
    local pet_rect = {
        row = vim.o.lines - (self.avoid_statusline and 2 or 1) - height + 1 - (row_offset or 0),
        col = col,
        width = self.max_frame_width,
        height = height,
    }

    for _, other_winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_is_valid(other_winid) then
            local other_ok, other_config = pcall(vim.api.nvim_win_get_config, other_winid)
            if
                other_ok
                and other_config.relative
                and other_config.relative ~= ""
                and not other_config.hide
                and not other_config.external
            then
                local pos = vim.api.nvim_win_get_position(other_winid)
                if
                    rects_overlap(pet_rect, {
                        row = pos[1],
                        col = pos[2],
                        width = vim.api.nvim_win_get_width(other_winid),
                        height = vim.api.nvim_win_get_height(other_winid),
                    })
                then
                    return true
                end
            end
        end
    end

    return false
end

function M.Animation:hide_current_render()
    kitty.clear_image(self.kitty_img_id)
    self.kitty_img_id = nil
end

function M.Animation:next_frame()
    if not kitty.available then
        utils.warning("pets.nvim: kitty terminal not detected")
        self:stop_timer()
        return
    end
    if self.state.hidden or self.dead then
        return
    end
    if not self.current_image then
        self.frame_counter = 1
    end
    if self.frame_counter > #self.frames[self.current_action] then
        self.repetitions = self.repetitions + 1
        if #self.frames[self.current_action] > 2 or self.repetitions * #self.frames[self.current_action] >= 8 then
            M.Animation.set_next_action(self)
            self.repetitions = 0
        end
        if self.dead then
            self:stop()
            return
        end
        self.frame_counter = 1
    end

    local image = self.frames[self.current_action][self.frame_counter]
    local area = self:area()
    local max_col = math.max(self.base_col, area.width - self.max_frame_width)
    self.col = math.min(self.col, max_col)
    M.Animation.set_next_col(self, area.width)

    local row_offset = self.row - 1 -- row=1 means bottom, higher = further up
    local total = #self.frames[self.current_action]
    local jump_h = math.max(1, math.floor(self.scale / 2))
    if self.current_action == "jump" then
        row_offset = row_offset + math.floor((self.frame_counter - 1) / total * jump_h)
    elseif self.current_action == "fall" then
        row_offset = row_offset + math.floor((1 - (self.frame_counter - 1) / total) * jump_h)
    end

    local col = area.col + self.col
    if self:pet_is_covered(col, row_offset) then
        self:hide_current_render()
        return
    end

    local img_id = kitty.show(image, self, col, row_offset, self.scale, self.avoid_statusline)
    if not img_id then
        return
    end
    self.kitty_img_id = img_id
    self.current_image = image
    self.frame_counter = self.frame_counter + 1
end

function M.Animation:set_next_action()
    if self.dying then
        if vim.startswith(self.current_action, "die") or vim.endswith(self.current_action, "die") then
            self.dead = true
            M.Animation.stop(self)
        end
        self.current_action = self.get_death_animation(self.current_action)
        return
    end
    if self.state.idle then
        if not vim.tbl_contains(self.idle_actions, self.current_action) then
            self.current_action = self.idle_actions[math.random(#self.idle_actions)]
        end
    else
        if math.random() < 0.5 then
            self.current_action =
                self.next_actions[self.current_action][math.random(#self.next_actions[self.current_action])]
        else
            self.current_action = self.next_actions[self.current_action][1]
        end
    end
end

function M.Animation:set_next_col(width)
    local right_limit = math.max(self.base_col, width - self.max_frame_width)
    if vim.tbl_contains(self.movements.right.normal, self.current_action) then
        self.col = self.col < right_limit and self.col + 1 or self.base_col
    elseif vim.tbl_contains(self.movements.right.fast, self.current_action) then
        self.col = self.col < right_limit and self.col + 2 or self.base_col
    elseif vim.tbl_contains(self.movements.right.slow, self.current_action) then
        if self.col < right_limit then
            local step = #self.frames[self.current_action] <= 2 and self.repetitions or self.frame_counter
            if step % 2 == 0 then
                self.col = self.col + 1
            end
        else
            self.col = self.base_col
        end
    elseif vim.tbl_contains(self.movements.left.normal, self.current_action) then
        self.col = self.col > self.base_col and self.col - 1 or right_limit
    elseif vim.tbl_contains(self.movements.left.fast, self.current_action) then
        self.col = self.col > self.base_col and self.col - 2 or right_limit
    elseif vim.tbl_contains(self.movements.left.slow, self.current_action) then
        if self.col > self.base_col then
            local step = #self.frames[self.current_action] < 2 and self.repetitions or self.frame_counter
            if step % 2 == 0 then
                self.col = self.col - 1
            end
        else
            self.col = right_limit
        end
    end
end

function M.Animation:set_state(new_state)
    for key, value in pairs(new_state) do
        self.state[key] = value
    end
    if new_state.hidden ~= nil then
        if self.state.hidden then
            self:stop_timer()
            kitty.clear(self)
            self.kitty_img_id = nil
            self.current_image = nil
        else
            self:start()
        end
    elseif new_state.paused ~= nil then
        if self.state.paused then
            self:stop_timer()
        else
            kitty.clear(self)
            self.current_image = nil
            self:start()
        end
    end
end

-- redraw after the editor size changes
function M.Animation:refresh()
    kitty.clear(self)
    self.kitty_img_id = nil
    self.current_image = nil
    if self.state.paused and not self.state.hidden and not self.dead then
        vim.schedule(function()
            M.Animation.next_frame(self)
        end)
    end
end

return M
