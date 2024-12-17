local lib = require("neotest.lib")
local sep = require("plenary.path").path.sep
local util = require("neotest-rust.util")

local M = {}

local has_quantified_captures = vim.fn.has("nvim-0.11.0") == 1

local src_path_cache = {}
local cargo_compiled_changedtick = -1

--
--{
--  "target": {
--    "src_path": "/home/mark/workspace/Lua/neotest-rust/tests/data/src/lib.rs",
--  },
--  "executable": "/home/mark/workspace/Lua/neotest-rust/tests/data/target/debug/deps/data-<>",
--}
--
-- Return a table containing each 'src_path' => 'executable' listed by
-- 'cargo test --message-format=JSON' (see sample output above).
local function get_src_paths(root)
    if cargo_compiled_changedtick == vim.g.rust_changedtick and src_path_cache[root] ~= nil then
        return src_path_cache[root]
    end

    local src_paths = {}
    local src_filter = '"src_path":"(.+' .. sep .. '.+.rs)",'
    local exe_filter = '"executable":"(.+' .. sep .. "deps" .. sep .. '.+)",'

    local cmd = {
        "cargo",
        "test",
        "--manifest-path=" .. root .. sep .. "Cargo.toml",
        "--message-format=JSON",
        "--no-run",
        -- "--quiet",
    }

    local compiler_msg_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = compiler_msg_buf })
    local window_width = 100
    local window_height = 12
    local compiler_msg_window = vim.api.nvim_open_win(compiler_msg_buf, false, {
        relative = "editor",
        width = window_width,
        height = window_height,
        col = vim.api.nvim_get_option_value("columns", {}) - window_width - 1,
        row = vim.api.nvim_get_option_value("lines", {}) - window_height - 1,
        border = vim.g.floating_window_border_dark,
        style = "minimal",
        title = "Cargo test",
    })

    local compiler_metadata = {}
    local cargo_job = vim.fn.jobstart(cmd, {
        clear_env = false,

        stdout_buffered = true,
        on_stdout = function(_, data)
            compiler_metadata = data
        end,

        on_stderr = function(_, data)
            local complete_line = ""

            for _, partial_line in ipairs(data) do
                if string.len(partial_line) ~= 0 then
                    complete_line = complete_line .. partial_line
                end
            end

            if vim.api.nvim_buf_is_valid(compiler_msg_buf) then
                vim.fn.appendbufline(compiler_msg_buf, "$", complete_line)
                vim.api.nvim_win_set_cursor(compiler_msg_window, { vim.api.nvim_buf_line_count(compiler_msg_buf), 1 })
                vim.cmd("redraw")
            end
        end,

        on_exit = function(_, exit_code)
            if exit_code ~= 0 then
                vim.notify("Cargo failed to compile test", vim.log.levels.ERROR)
            end
            if vim.api.nvim_win_is_valid(compiler_msg_window) then
                vim.api.nvim_win_close(compiler_msg_window, true)
            end

            if vim.api.nvim_buf_is_valid(compiler_msg_buf) then
                vim.api.nvim_buf_delete(compiler_msg_buf, { force = true })
            end
        end,
    })

    vim.fn.jobwait({ cargo_job })

    for _, line in ipairs(compiler_metadata) do
        if string.find(line, src_filter) and string.find(line, exe_filter) then
            local src_path = string.match(line, src_filter)
            local executable = string.match(line, exe_filter)
            src_paths[src_path] = executable
        end
    end

    src_path_cache[root] = src_paths
    cargo_compiled_changedtick = vim.g.rust_changedtick

    return src_paths
end

local function collect(query, source, root)
    local mods = {}

    for _, match in query:iter_matches(root, source) do
        local captured_nodes = {}
        for i, capture in ipairs(query.captures) do
            captured_nodes[capture] = match[i]
        end

        if captured_nodes["mod_name"] then
            local node = captured_nodes["mod_name"]
            if has_quantified_captures then
                node = node[#node]
            end
            local mod_name = vim.treesitter.get_node_text(node, source)
            table.insert(mods, mod_name)
        end
    end

    return mods
end

-- Get the list of <mod_name>s imported via '(pub) mod <mod_name>;'
local function get_mods(path)
    local content = lib.files.read(path)
    local query = [[
(mod_item
	name: (identifier) @mod_name
	.
)
    ]]

    local root, lang = lib.treesitter.get_parse_root(path, content, {})
    local parsed_query = lib.treesitter.normalise_query(lang, query)

    return collect(parsed_query, content, root)
end

-- Determine if mod is in <mod_name>.rs or <mod_name>/mod.rs
local function construct_mod_path(src_path, mod_name)
    local match_str = "(.-)[^\\/]-%.?([%w_]+)%.?[^\\/]*$"
    local abs_path, parent_mod = string.match(src_path, match_str)

    local mod_file = abs_path .. mod_name .. ".rs"
    local mod_dir = abs_path .. mod_name .. sep .. "mod.rs"
    local child_mod = abs_path .. parent_mod .. sep .. mod_name .. ".rs"

    if util.file_exists(mod_file) then
        return mod_file
    elseif util.file_exists(mod_dir) then
        return mod_dir
    elseif util.file_exists(child_mod) then
        return child_mod
    end

    return nil
end

-- Recursive search for 'path' amongst all modules declared in 'src_path'
local function search_modules(src_path, path)
    local mods = get_mods(src_path)

    for _, mod in ipairs(mods) do
        local mod_path = construct_mod_path(src_path, mod)
        if path == mod_path then
            return true
        elseif search_modules(mod_path, path) then
            return true
        end
    end

    return false
end

-- Debugging is only possible from the generated test binary
-- See: https://github.com/rust-lang/cargo/issues/1924#issuecomment-289764090
-- Identify the binary containing the tests defined in 'path'
M.get_test_binary = function(root, path)
    local src_paths = get_src_paths(root)

    -- If 'path' is the source of the binary we are done
    for src_path, executable in pairs(src_paths) do
        if path == src_path then
            return executable
        end
    end

    -- Otherwise we need to figure out which 'src_path' it is loaded from
    for src_path, executable in pairs(src_paths) do
        local mod_match = search_modules(src_path, path)
        if mod_match then
            return executable
        end
    end

    return nil
end

-- Translate plain test output to a neotest results object
M.translate_results = function(output_path)
    local result_map = {
        ok = "passed",
        FAILED = "failed",
        ignored = "skipped",
    }

    local results = {}

    local handle = assert(io.open(output_path))
    local line = handle:read("l")

    while line do
        if string.find(line, "^test result:") then
            --
        elseif string.find(line, "^test .+ %.%.%. %w+") then
            local test_name, cargo_result = string.match(line, "^test (.+) %.%.%. (%w+)")

            results[test_name] = { status = assert(result_map[cargo_result]) }
        end

        line = handle:read("l")
    end

    if handle then
        handle:close()
    end

    return results
end

return M
