local M = {}

M.state = {
  stack = {},
  input = "",
}

local state_file = vim.fn.stdpath("data") .. "/rpn_stack.json"
local state_dir  = vim.fn.fnamemodify(state_file, ":h")

local function ensure_state_dir()
  if vim.fn.isdirectory(state_dir) == 0 then
    vim.fn.mkdir(state_dir, "p")
  end
end

local function save_state()
  ensure_state_dir()
  local ok, json = pcall(vim.json.encode, { stack = M.state.stack, input = M.state.input })
  if not ok then return false end
  local ok2 = pcall(vim.fn.writefile, { json }, state_file)
  return ok2
end

local function load_state()
  ensure_state_dir()
  if vim.fn.filereadable(state_file) == 0 then
    return
  end

  local ok1, lines = pcall(vim.fn.readfile, state_file)
  if not ok1 or not lines or #lines == 0 then return end

  local ok2, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok2 or type(decoded) ~= "table" then return end

  if type(decoded.stack) == "table" then
    M.state.stack = decoded.stack
  end
  if type(decoded.input) == "string" then
    M.state.input = decoded.input
  end
end

local function contains(tbl, value)
  for _, v in ipairs(tbl) do
    if v == value then return true end
  end
  return false
end

-- ===== UI helpers =====
local function create_stack_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "rpnstack"

  local origin_win = vim.api.nvim_get_current_win()

  local ui = vim.api.nvim_list_uis()[1]
  local width  = math.max(30, math.floor(ui.width * 0.35))
  local height = 10
  local row = ui.height - height - 2
  local col = ui.width - width - 2

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    noautocmd = true,
  })

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].cursorline = false
  vim.wo[win].winfixheight = true
  vim.wo[win].winfixwidth = true

  return buf, win, origin_win
end

local function render_stack(buf, stack, input)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.bo[buf].modifiable = true

  local lines = {}
  lines[#lines + 1] = "RPN Stack"
  lines[#lines + 1] = string.rep("─", 30)
  lines[#lines + 1] = ("Input: %s"):format(input or "")
  lines[#lines + 1] = ""

  if #stack == 0 then
    lines[#lines + 1] = "(empty)"
  else
    for i = #stack, 1, -1 do
      local idx_from_top = (#stack - i)
      lines[#lines + 1] = ("%2d: %s"):format(idx_from_top, tostring(stack[i]))
    end
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function echo_cmd(msg)
  vim.api.nvim_echo({ { msg, "None" } }, false, {})
  vim.cmd("redraw")
end

-- ===== RPN core =====
local function push(stack, x) stack[#stack + 1] = x end
local function pop(stack)
  local v = stack[#stack]
  stack[#stack] = nil
  return v
end

local function apply_op(stack, op)
  if op == "+" or op == "-" or op == "*" or op == "/" then
    if #stack < 2 then return false, "need 2 args" end
    local b = pop(stack)
    local a = pop(stack)
    if op == "+" then push(stack, a + b)
    elseif op == "-" then push(stack, a - b)
    elseif op == "*" then push(stack, a * b)
    elseif op == "/" then push(stack, a / b)
    end
    return true

  elseif op == "dup" then
    if #stack < 1 then return false, "need 1 arg" end
    push(stack, stack[#stack])
    return true

  elseif op == "drop" then
    if #stack < 1 then return false, "need 1 arg" end
    pop(stack)
    return true

  elseif op == "swap" then
    if #stack < 2 then return false, "need 2 args" end
    local b = pop(stack)
    local a = pop(stack)
    push(stack, b); push(stack, a)
    return true
  end

  return false, "unknown op: " .. op
end

local function commit_token(stack, token)
  if token == "" then return true end

  local n = tonumber(token)
  if n ~= nil then
    push(stack, n)
    return true
  end

  local ok, err = apply_op(stack, token)
  if not ok then return false, err end
  return true
end

-- ===== Main entry =====
function M.start()
  load_state()

  local stack = M.state.stack
  local input = M.state.input or ""

  local stack_buf, stack_win, origin_win = create_stack_win()

  local function redraw()
    if vim.api.nvim_win_is_valid(origin_win) then
      vim.api.nvim_set_current_win(origin_win)
    end
    render_stack(stack_buf, stack, input)
    echo_cmd("RPN: " .. input)
  end

  local function persist()
    M.state.stack = stack
    M.state.input = input
    save_state()
  end

  redraw()

  while true do
    local ok, ch = pcall(vim.fn.getchar)
    if not ok then break end

    local c = type(ch) == "number" and vim.fn.nr2char(ch) or ch
    c = vim.fn.keytrans(c)

    -- exit
    if c == "q" or c == "<Esc>" then
      persist()
      break
    end

    -- backspace/delete: input char OR pop stack if input empty
    if c == "<BS>" or c == "<C-h>" or c == "<Del>" then
      if input ~= "" then
        input = input:sub(1, -2)
      else
        if #stack > 0 then
          pop(stack)
        else
          echo_cmd("ERR: stack empty")
        end
      end
      persist()
      redraw()
      goto continue
    end

    -- commit on enter/space
    if c == "<CR>" or c == "<Space>" then
      local token = vim.trim(input)
      local ok2, err = commit_token(stack, token)
      input = ""
      if not ok2 then echo_cmd("ERR: " .. err) end
      persist()
      redraw()
      goto continue
    end

    -- operators: commit immediately
    if contains({ "+", "-", "*", "/", "%", "&", "|" }, c) then
      local ok2, err = commit_token(stack, c)
      input = ""
      if not ok2 then echo_cmd("ERR: " .. err) end
      persist()
      redraw()
      goto continue
    end

    -- kill last word from input
    if c == "<C-w>" then
      input = input:gsub("%s*%S+$", "")
      persist()
      redraw()
      goto continue
    end

    -- normal char
    if #c == 1 then
      input = input .. c
      persist()
      redraw()
    end

    ::continue::
  end

  echo_cmd("")
  if vim.api.nvim_win_is_valid(stack_win) then
    vim.api.nvim_win_close(stack_win, true)
  end
end

M.setup = function()
  vim.api.nvim_create_user_command("Calc", M.start, {})

  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function() pcall(save_state) end,
  })
end

M.setup()

return M
