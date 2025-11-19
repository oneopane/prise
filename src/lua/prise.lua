local M = {}

function M.Surface(pty_id)
    return {
        type = "surface",
        pty = pty_id,
    }
end

return M
