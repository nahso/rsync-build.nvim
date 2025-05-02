# rsync-build.nvim
## Description
`rsync-build.nvim` is a Neovim plugin that provides a convenient way to upload local project to a remote server then build it in the remote.

It uses `rsync` to synchronize files and support flexible build commands.

# Basic Idea
This plugin is inspired from my daily workflow. I always open 3 tmux windows, they are:
1. the Neovim window, for editing the source code and uploading it to the remote server with `vim-arsync` plugin;
2. the build window, since the source code needs to be built in the login node with the cross compiler;
3. the run window, for running the executable in the compute node with interactive job.

This plugin is designed to simplify this workflow by providing a single command to upload the source code, build it, and run it.

# Installation
## Lazy.nvim
```
{ "nahso/rsync-build.nvim" }
```

Then initialize the plugin with:
```lua
require("rsync-build").setup()

local rb = require("rsync-build")
vim.keymap.set("n", "<leader>l", function()
  rb.upload_dir()
end, { desc = "Send file rsync-build" })
```

# Example
Execute `:TransferInit` to create a template configuration file in the current directory. The template file is named `.rsync-build.lua`.

Here is an example of a `.rsync-build.lua` file:
```lua
return {
  -- the none absolute paths are relative to the project root
  host = "host1",
  localPath = ".",
  remotePath = "<path>",
  excludedPaths = {
    "build",
  },
  terminals = {
    build = {
      initial_commands = {
        "ssh host1",
        "cd <path>/build",
      },
      commands = {
        "make -j",
      },
    },
    run = {
      initial_commands = {
        "ssh host1",
        "cd <path>/build",
        "srun gpu --pty /bin/bash",
      },
      commands = {
        "./<executable>",
      },
    }
  },
  actions = {
    o = {
      "build",
    },
    i = {
      "build",
      "run",
    },
    j = {
      "run"
    }
  },
}
```

Required fields are:
- `host`: the remote server name, only the host configured in `~/.ssh/config` with public key authentication is supported
- `localPath`: the local path to upload
- `remotePath`: the remote path to upload the files

Optional fields are:
- `excludedPaths`: a list of paths to exclude from the upload
- `terminals`: a list of terminals to open after the upload
  - `initial_commands`: the initial commands, only executed once
  - `commands`: the main command to run in the terminal
- `actions`: a list of actions to perform after the upload, the key is the keybinding and the value is a list of terminal name defined in `terminals`

Once the `upload_dir()` is bind to `<leader>l`, the `build` action can be triggered by `<leader>lo`, the `run` action can be triggered by `<leader>lj`, and the `build` then `run` action can be triggered by `<leader>li`.

If there is no `actions` defined, the `<leader>l` will only upload the local files to the remote server.

**NOTE**:
This plugin is under early development, only basic features are implemented.

# Related Works
- [vim-arsync](https://github.com/KenN7/vim-arsync)
- [transfer.nvim](https://github.com/coffebar/transfer.nvim)

