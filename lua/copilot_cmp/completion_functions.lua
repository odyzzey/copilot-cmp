local format = require("copilot_cmp.format")
local util = require("copilot.util")
local api = require("copilot.api")
local methods = { id = 0 }

local format_completions = function(completions, ctx, formatters)
  local format_item = function(item)
    -- local insert_text, fmt_info = formatters.insert_text(item, params.context)
    local preview = formatters.preview(item.text)
    local label_text = formatters.label(item)
    local insert_text = formatters.insert_text(item, ctx)
    return {
      copilot = true, -- for comparator, only availiable in panel, not cycling
      score = item.score or nil,
      label = label_text,
      filterText = label_text:sub(0, label_text:len()-1),
      kind = 1,
      cmp = {
        kind_hl_group = "CmpItemKindCopilot",
        kind_text = 'Copilot',
      },
      textEdit = {
        newText = insert_text,
        range = {
          start = item.range.start,
          ['end'] = ctx.cursor,
        }
      },
      documentation = {
        kind = "markdown",
        value = "```" .. vim.bo.filetype .. "\n" .. preview .. "\n```"
      },
      dup = 1,
    }
  end

  return {
    IsIncomplete = true,
    items = #completions > 0 and vim.tbl_map(function(item)
      return format_item(item)
    end, completions) or {}
  }
end

local add_results = function (completions, params)
  local results = {}
  -- normalize completion and use as key to avoid duplicates
  for _, completion in ipairs(completions) do
    results[format.deindent(completion.text)] = completion
  end
  return results
end

methods.getCompletionsCycling = function (self, params, callback)
  local respond_callback = function(err, response)
    if err then return err end
    if not response or vim.tbl_isempty(response.completions) then return end
    local completions = vim.tbl_values(add_results(response.completions, params))
    callback(format_completions(completions, params.context, self.formatters))
  end

  api.get_completions_cycling(self.client, util.get_doc_params(), respond_callback)
  -- Callback to cmp with empty completions so it doesn't freeze
  -- callback(format_completions({}, params.context, self.formatters))
end

---@param panelId string
local create_handlers = function (panelId, params, callback, formatters)
  local results = {}
  api.register_panel_handlers(panelId, {
    on_solution = function (solution)
      -- this standardizes the format of the response to be the same as cycling
      -- Cycling insertions have been empirically less buggy
      solution.range.start = {
        character = 0,
        line = solution.range.start.line,
      }
      solution.text = solution.displayText
      solution.displayText = solution.completionText
      results[format.deindent(solution.text)] = solution --ensure unique
      callback({
        IsIncomplete = true,
        items = format_completions(solution, params.context, formatters)
      })
    end,
    on_solutions_done = function()
      callback(format_completions(vim.tbl_values(results), params.context, formatters))
      vim.schedule(function()
        api.unregister_panel_handlers(panelId)
      end)
    end,
  })
end

local get_req_params = function (id)
  local req_params = util.get_doc_params()
  req_params.panelId = "copilot-cmp:" .. tostring(id)
  return req_params
end

methods.getPanelCompletions = function (self, params, callback)
  local req_params = get_req_params(methods.id)
  local respond_callback = function (err, _)
    methods.id = methods.id + 1
    if err then return end
    create_handlers(req_params.panelId, params, callback, self.formatters)
  end
  local sent, _ = api.get_panel_completions(self.client, req_params, respond_callback)
  if not sent then api.unregister_panel_handlers(req_params.panelId) end
  callback({ IsIncomplete = true, items = {}})
end

methods.init = function (completion_method)
  methods.existing_matches = {}
  methods.id = 0
  return methods[completion_method]
end

return methods
