local M = {}
M.Animation = {}
M.Animation.__index = M.Animation

local utils = require("pets.utils")
local listdir = utils.listdir
local kitty = require("pets.kitty")

function M.Animation.new(sourcedir, type, style, popup, user_opts, state)
    local instance = setmetatable({}, M.Animation)
    instance.type = type
    instance.style = style
    instance.frame_counter = 1
    instance.actions = listdir(sourcedir)
    instance.frames = {}
    instance.popup = popup
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
    local max_col = math.max(0, popup.win_config.width - frame_width)
    M.base_col = math.min(user_opts.col, max_col)
    instance.row, instance.col = user_opts.row, math.random(M.base_col, max_col)
    instance.max_frame_width = frame_width

    local pet = vim.tbl_deep_extend("keep", require("pets.pets." .. type), utils.default_pet_table)
    instance.next_actions = pet.next_actions
    instance.idle_actions = pet.idle_actions
    instance.movements = pet.movements
    instance.first_action = pet.first_action
    instance.get_death_animation = pet.get_death_animation

    return instance
end

function M.Animation:start_timer()
    if self.timer ~= nil then self:stop_timer() end
    self.timer = vim.loop.new_timer()
    self.timer:start(0, 1000 / (self.speed_multiplier * 8), function()
        vim.schedule(function() M.Animation.next_frame(self) end)
    end)
end

function M.Animation:stop_timer()
    if self.timer == nil then return end
    self.timer:stop(); self.timer:close(); self.timer = nil
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
        vim.schedule(function() M.Animation.next_frame(self) end)
    end
end

function M.Animation:stop()
    kitty.clear(self.popup.winid)
    self.current_image = nil
    self:stop_timer()
end

function M.Animation:next_frame()
    if not kitty.available then
        utils.warning("pets.nvim: kitty terminal not detected")
        self:stop_timer()
        return
    end
    if not vim.api.nvim_buf_is_valid(self.popup.bufnr) then return end

    if not self.current_image then self.frame_counter = 1 end
    if self.frame_counter > #self.frames[self.current_action] then
        self.repetitions = self.repetitions + 1
        if #self.frames[self.current_action] > 2 or self.repetitions * #self.frames[self.current_action] >= 8 then
            M.Animation.set_next_action(self)
            self.repetitions = 0
        end
        if self.dead then self:stop(); return end
        self.frame_counter = 1
    end

    local image = self.frames[self.current_action][self.frame_counter]
    local max_col = math.max(M.base_col, self.popup.win_config.width - self.max_frame_width)
    self.col = math.min(self.col, max_col)
    M.Animation.set_next_col(self)

    local row_offset = self.row - 1  -- row=1 means bottom, higher = further up
    local total = #self.frames[self.current_action]
    local jump_h = math.max(1, math.floor(self.scale / 2))
    if self.current_action == "jump" then
        row_offset = row_offset + math.floor((self.frame_counter - 1) / total * jump_h)
    elseif self.current_action == "fall" then
        row_offset = row_offset + math.floor((1 - (self.frame_counter - 1) / total) * jump_h)
    end

    kitty.show(image, self.popup.winid, self.col, row_offset, self.scale, self.avoid_statusline)
    self.current_image = image
    self.frame_counter = self.frame_counter + 1
end

function M.Animation:set_next_action()
    if self.dying then
        if vim.startswith(self.current_action, "die") or vim.endswith(self.current_action, "die") then
            self.dead = true
            M.Animation.stop(self)
            self.popup:unmount()
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
            self.current_action = self.next_actions[self.current_action][math.random(#self.next_actions[self.current_action])]
        else
            self.current_action = self.next_actions[self.current_action][1]
        end
    end
end

function M.Animation:set_next_col()
    local width = self.popup.win_config.width
    local right_limit = math.max(M.base_col, width - self.max_frame_width)
    if vim.tbl_contains(self.movements.right.normal, self.current_action) then
        self.col = self.col < right_limit and self.col + 1 or M.base_col
    elseif vim.tbl_contains(self.movements.right.fast, self.current_action) then
        self.col = self.col < right_limit and self.col + 2 or M.base_col
    elseif vim.tbl_contains(self.movements.right.slow, self.current_action) then
        if self.col < right_limit then
            local step = #self.frames[self.current_action] <= 2 and self.repetitions or self.frame_counter
            if step % 2 == 0 then self.col = self.col + 1 end
        else self.col = M.base_col end
    elseif vim.tbl_contains(self.movements.left.normal, self.current_action) then
        self.col = self.col > M.base_col and self.col - 1 or right_limit
    elseif vim.tbl_contains(self.movements.left.fast, self.current_action) then
        self.col = self.col > M.base_col and self.col - 2 or right_limit
    elseif vim.tbl_contains(self.movements.left.slow, self.current_action) then
        if self.col > M.base_col then
            local step = #self.frames[self.current_action] < 2 and self.repetitions or self.frame_counter
            if step % 2 == 0 then self.col = self.col - 1 end
        else self.col = right_limit end
    end
end

function M.Animation:set_state(new_state)
    for key, value in pairs(new_state) do self.state[key] = value end
    if new_state.hidden ~= nil then
        if self.state.hidden then
            self:stop_timer()
            kitty.clear(self.popup.winid)
            self.current_image = nil
            self.popup:unmount()
        else
            self.popup:mount()
            self:start()
        end
    elseif new_state.paused ~= nil then
        if self.state.paused then
            self:stop_timer()
        else
            kitty.clear(self.popup.winid)
            self.current_image = nil
            self:start()
        end
    end
end

return M
