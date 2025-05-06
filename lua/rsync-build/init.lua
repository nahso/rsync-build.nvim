local M = {}

M.opts = {}

local _config_file_name = ".nvim-rsync-build.lua"

M.defaults = {
  default_rsync_options = {
    "-vazr",
    "--exclude",
    ".git",
    "--exclude",
    ".idea",
    "--exclude",
    ".DS_Store",
    "--exclude",
    _config_file_name,
    "--exclude",
    "*.pyc",
    "--exclude",
    "*.o",
  },
  example_config = [[return {
    -- the none absolute paths are relative to the project root
    host = "fugaku",
    localPath = ".",
    remotePath = "<path>",
    excludedPaths = {
      "build",
    },
    terminals = {
      build = {
        initial_commands = {
          "cd <path>",
        },
        commands = {
          "make -j",
        },
      },
    },
    actions = {
      o = {
        "build",
      },
    },
  }]]
}

local term_bufs = {}

local function new_promise()
  local resolve, reject
  local promise = {
    resolve = function(value)
      if resolve then resolve(value) end
    end,
    reject = function(err)
      if reject then reject(err) end
    end,
    next = function(fn)
      local result = new_promise()
      resolve = function(value)
        local ok, val = pcall(fn, value)
        if ok then
          result.resolve(val)
        else
          result.reject(val)
        end
      end
      return result
    end,
    catch = function(fn)
      reject = fn
      return promise
    end,
  }
  return promise
end

local function execute_cmd(cmd, term)
  local promise = new_promise()
  local cmd_id = tostring(math.random(10000, 99999))
  local cmd_marker = "CMD_COMPLETE_" .. cmd_id
  vim.api.nvim_chan_send(term.chan, cmd .. "\r")
  vim.api.nvim_chan_send(term.chan, "echo $?; echo " .. cmd_marker .. "\r")

  local timer = vim.uv.new_timer()
  local max_wait = 3000 -- 3000 * 100 = 5 minutes
  local wait_cnt = 0
  
  timer:start(0, 100, vim.schedule_wrap(function()
    wait_cnt = wait_cnt + 1
    if wait_cnt > max_wait then
      timer:stop()
      timer:close()
      promise.reject("Command timed out: " .. cmd)
      return
    end

    local line_count = vim.api.nvim_buf_line_count(term.buf)
    for i = line_count, 1, -1 do
      local line = vim.api.nvim_buf_get_lines(term.buf, i - 1, i, false)[1]
      if line and line:match("[$#%%>]%s*$") then
        if i > 1 then
          i = i - 1
          local line_id = vim.api.nvim_buf_get_lines(term.buf, i - 1, i, false)[1]
          if line_id and line_id:match(cmd_marker) then
            if i > 1 then
              i = i - 1
              local line_res = vim.api.nvim_buf_get_lines(term.buf, i - 1, i, false)[1]
              if line_res and line_res == "0" then
                timer:stop()
                timer:close()
                promise.resolve(true)
                break
              else
                timer:stop()
                timer:close()
                promise.reject("Command exits with non-zero code: " .. cmd)
                break
              end
            else
              timer:stop()
              timer:close()
              promise.reject("FATAL ERROR: command execution out of order: expect=" .. cmd_marker .. ", got=" .. line_id)
            end
          end
        end
      end
    end
  end))
  return promise
end

local function execute_cmds(cmds, term)
  local promise = new_promise()
  local function execute_next(index)
    if index > #cmds then
      promise.resolve("All commands completed")
      return
    end

    execute_cmd(cmds[index], term).next(function()
      execute_next(index + 1)
    end)
    .catch(function(err)
      promise.reject("Error executing command " .. commands[index] .. ": " .. err)
    end)
  end
  execute_next(1)
  return promise
end

local function focus_terminal(term)
  local wins = vim.api.nvim_list_wins()
  for _, win in ipairs(wins) do
    local buf = vim.api.nvim_win_get_buf(win)
    if buf == term.buf then
      vim.api.nvim_set_current_win(win)
      return true
    end
  end
  return false
end

local function do_terminal_sequence(terminal_sequence, terminals)
  local function execute_all(seqi)
    if seqi > #terminal_sequence then
      return
    end

    local name = terminal_sequence[seqi]
    local term = terminals[name]
    if term_bufs[name] then
      -- first: commands
      local windows = vim.api.nvim_list_wins()
      local target_win = nil
      for _, win in ipairs(windows) do
        local current_buf = vim.api.nvim_win_get_buf(win)
        if current_buf == term_bufs[name].buf then
          target_win = win
          break
        end
      end
      if target_win ~= nil then
        vim.api.nvim_set_current_win(target_win)
      else
        vim.cmd.split()
        vim.api.nvim_set_current_buf(term_bufs[name].buf)
      end
      vim.cmd("normal G")
      vim.cmd.wincmd("p")

      execute_cmds(term.commands, term_bufs[name])
      .next(function()
        if focus_terminal(term_bufs[name]) then
          vim.cmd.hide()
        end
        -- recursion: next terminal_sequence
        execute_all(seqi + 1)
      end)
      .catch(function(err)
        vim.notify("Error: " .. err, vim.log.levels.ERROR)
      end)
    else
      vim.cmd.split()
      vim.cmd.terminal()
      vim.cmd("normal G")

      term_bufs[name] = { chan = vim.bo.channel, buf = vim.api.nvim_get_current_buf(), name = "TERMINAL:" .. name }
      vim.api.nvim_buf_set_name(term_bufs[name].buf, term_bufs[name].name)
      vim.cmd.wincmd("p")
      -- first: initial_commands
      execute_cmds(term.initial_commands, term_bufs[name])
      .next(function()
        -- then: commands
        execute_cmds(term.commands, term_bufs[name])
        .next(function()
          if focus_terminal(term_bufs[name]) then
            vim.cmd.hide()
          end
          -- recursion: next terminal_sequence
          execute_all(seqi + 1)
        end)
        .catch(function(err)
          vim.notify("Error: " .. err, vim.log.levels.ERROR)
        end)
      end)
      .catch(function(err)
        vim.notify("Error: " .. err, vim.log.levels.ERROR)
      end)
    end
  end

  execute_all(1)
end

local job_id = 0

local function generate_config()
  local path = vim.loop.cwd() .. "/" .. _config_file_name
  if vim.fn.filereadable(path) ~= 0 then
    vim.cmd("edit " .. path)
  else
    local file = io.open(path, "w")
    if file then
      file:write(M.opts.example_config)
      file:close()
      vim.cmd("edit " .. path)
      vim.notify(
        "Config file created at " .. path,
        vim.log.levels.INFO, {}
      )
    else
      vim.notify(
        "Failed to create config file at " .. path,
        vim.log.levels.ERROR, {}
      )
    end
  end
end

local function find_config_file()
  local cwd = vim.loop.cwd()
  local config_file = cwd .. "/" .. _config_file_name
  if vim.fn.filereadable(config_file) ~= 0 then
    return config_file
  end

  local current_file_path = vim.fn.expand('%:p')
  if current_file_path == "" then
    return nil
  end
  local current_dir = vim.fn.fnamemodify(current_file_path, ":h")
  while true do
    local config_path = current_dir .. "/" .. _config_file_name
    if vim.fn.filereadable(config_path) ~= 0 then
      return config_path
    end
    local parent_dir = vim.fn.fnamemodify(current_dir, ":h")
    if parent_dir == current_dir or parent_dir == '' then
      return nil
    end
    current_dir = parent_dir
  end
end

local function parse_config()
  local config_file = find_config_file()
  if config_file == nil then
    vim.notify(
      "No deployment config found. Run `:TransferInit` to create it",
      vim.log.levels.WARN, {}
    )
    return nil
  end
  local config = dofile(config_file)
  local expected_keys = {
    "host",
    "remotePath",
  }
  for _, key in ipairs(expected_keys) do
    if config[key] == nil then
      vim.notify(
        "Invalid deployment config. Missing key: " .. key,
        vim.log.levels.ERROR, {}
      )
      return nil
    end
  end

  if config.terminals == nil and config.actions ~= nil then
    vim.notify(
      "Invalid deployment config. key terminals is required when actions are defined",
      vim.log.levels.ERROR, {}
    )
    return nil
  end

  if config.actions ~= nil then
    for keybinding, action in pairs(config.actions) do
      if #keybinding > 1 then
        vim.notify(
          "Invalid deployment config. keybinding should be a single character",
          vim.log.levels.ERROR, {}
        )
        return nil
      end

      for _, seq in ipairs(action) do
        if config.terminals[seq] == nil then
          vim.notify(
            "Invalid deployment config. sequence: " .. seq .. " not found in terminals",
            vim.log.levels.ERROR, {}
          )
          return nil
        end
      end
    end
  end
  return config
end

local function flip_status_line_color(status)
  local statusline_hl = vim.api.nvim_get_hl(0, { name = "StatusLine" })
  vim.api.nvim_set_hl(0, "StatusLine", { fg = statusline_hl.bg, bg = statusline_hl.fg })
end

function M.upload_dir(callback)
  local config = parse_config()
  if not config then
    return
  end

  local cmd = "rsync "
  for _, option in ipairs(M.opts.default_rsync_options) do
    -- if * is in option, then it should be quoted
    if string.find(option, "*") then
      cmd = cmd .. "'" .. option .. "' "
    else
      cmd = cmd .. option .. " "
    end
  end
  if config.excludedPaths then
    for _, path in ipairs(config.excludedPaths) do
      cmd = cmd .. "--exclude '" .. path .. "' "
    end
  end
  cmd = cmd .. config.localPath .. " "
  cmd = cmd .. config.host .. ":" .. config.remotePath

  local status = vim.fn.jobwait({job_id}, 0)
  if status[1] == -1 then
    vim.fn.jobstop(job_id)
  end

  local JOB_RUNNING = 0
  local JOB_SUCCESS = 1
  local JOB_FAILURE = 2
  local job_status = JOB_RUNNING
  local waiting_coroutine = nil

  flip_status_line_color()
  job_id = vim.fn.jobstart(cmd, {
      on_stdout = function(_, data)
        if data then
          vim.schedule(function()
            for _, line in ipairs(data) do
              print(line)
            end
          end)
        end
      end,
      on_stderr = function(_, data)
        if data then
          vim.schedule(function()
            for _, line in ipairs(data) do
              print(line)
            end
          end)
        end
      end,
      on_exit = function(_, code)
        flip_status_line_color()
        if code == 0 then
          job_status = JOB_SUCCESS
          vim.notify("Upload completed successfully", vim.log.levels.INFO, {})
          if waiting_coroutine then
            local co = waiting_coroutine
            waiting_coroutine = nil
            local ok, err = coroutine.resume(co)
            if not ok then
              vim.notify("Error in coroutine: " .. err, vim.log.levels.ERROR, {})
            end
          end
          if callback then
            callback()
          end
        else
          job_status = JOB_FAILURE
          vim.notify("Upload failed with code: " .. code, vim.log.levels.ERROR, {})
          if waiting_coroutine then
            local co = waiting_coroutine
            waiting_coroutine = nil
            local ok, err = coroutine.resume(co)
            if not ok then
              vim.notify("Error in coroutine: " .. err, vim.log.levels.ERROR, {})
            end
          end
        end
      end,
    }
  )

  if config.actions then
    local lines = {}
    table.insert(lines, "Defined keybindings:")
    
    local sorted_keys = {}
    for keybinding, _ in pairs(config.actions) do
      table.insert(sorted_keys, keybinding)
    end
    table.sort(sorted_keys)

    for _, item in ipairs(sorted_keys) do
      local keybinding = item
      local action = config.actions[keybinding]

      local desc = ""
      for i=1, #action do
        if i < #action then
          desc = desc .. action[i] .. " -> "
        else
          desc = desc .. action[i]
        end
      end
      table.insert(lines, string.format("  %s : %s", keybinding, desc))
    end

    local current_win = vim.api.nvim_get_current_win()
    local win_width = vim.api.nvim_win_get_width(current_win)
    local editor_height = vim.o.lines

    local content_height = #lines
    local float_height = math.min(content_height, editor_height - 2)

    -- 2 = 2 * top/bottom border(1)
    -- 1 = status line height
    local extra_rows = 2 + vim.o.cmdheight + 1
    local float_row = editor_height - float_height - extra_rows
    local float_col = win_width

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
    vim.api.nvim_buf_set_option(buf, 'swapfile', false)
    vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
    vim.api.nvim_buf_set_option(buf, 'modifiable', false)

    local win_opts = {
      relative = 'editor',
      -- size:
      width = win_width,
      height = float_height,
      -- position:
      row = float_row,
      col = win_width,

      style = 'minimal',
      border = 'single',
      focusable = true,
      noautocmd = true
    }
    local win = vim.api.nvim_open_win(buf, true, win_opts)
    vim.api.nvim_win_set_option(win, 'winhl', 'Normal:NormalFloat,FloatBorder:FloatBorder')
    vim.api.nvim_win_set_option(win, 'cursorline', false)
    vim.api.nvim_win_set_option(win, 'number', false)
    vim.api.nvim_win_set_option(win, 'relativenumber', false)
    vim.api.nvim_win_set_option(win, 'signcolumn', 'no')
    vim.api.nvim_win_set_option(win, 'foldcolumn', '0')

    -- Close window with <Esc>
    vim.keymap.set('n', '<Esc>', function()
      vim.api.nvim_win_close(win, true)
    end, { buffer = buf, nowait = true })
    -- Close window with 'q'
    vim.keymap.set('n', 'q', function()
      vim.api.nvim_win_close(win, true)
    end, { buffer = buf, nowait = true })

    for keybinding, action in pairs(config.actions) do
      local function handle_coroutine()
        vim.api.nvim_win_close(win, true)
        if job_status == JOB_RUNNING then
          waiting_coroutine = coroutine.running()
          coroutine.yield()
        end
        if job_status == JOB_SUCCESS then
          do_terminal_sequence(action, config.terminals)
        elseif job_status == JOB_FAILURE then
          -- vim.notify("Job failed. Cannot execute action.", vim.log.levels.ERROR, {})
        end
      end

      vim.keymap.set('n', keybinding, function()
        local co = coroutine.create(handle_coroutine)
        local ok, err = coroutine.resume(co)
        if not ok then
          vim.notify("Error in coroutine: " .. err, vim.log.levels.ERROR, {})
        end
      end, { buffer = buf, nowait = true })
    end
  end
end

function M.setup(opts)
  M.opts = setmetatable(opts or {}, {__index = M.defaults})
  vim.api.nvim_create_user_command("TransferInit", generate_config, {})
end

return M
