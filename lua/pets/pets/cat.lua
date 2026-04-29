return {
    next_actions = {
        idle = { "idle", "jump", "run", "run_left" },
        jump = { "fall" },
        fall = { "idle", "run", "run_left" },
        run = { "run", "run_left", "idle" },
        run_left = { "run_left", "run", "idle" },
    },
    idle_actions = { "idle", "jump" },
    first_action = "idle",
    movements = {
        right = {
            normal = { "run" },
        },
        left = {
            normal = { "run_left" },
        },
    },
}
