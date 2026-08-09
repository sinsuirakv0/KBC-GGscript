-- KBC-rakv0 status script (test build)
-- 変数名・関数名は英語、コメントは日本語で統一する。

local RECORD_COLUMN_COUNT = 117
local RECORD_SIZE = 0x1D4
local UNIT_SIZE = RECORD_SIZE * 4
local ANCHOR_VALUE = 5000
local ANCHOR_COLUMN = 6
local ANCHOR_OFFSET = ANCHOR_COLUMN * 4
local ANCHOR_PREFIX_COLUMNS = 12
local MAX_ANCHOR_CANDIDATES = 256

local state = {
  rootDirectory = nil,
  dataDirectory = nil,
  fields = {},
  names = {},
  characters = {},
  unitTableAddress = nil,
  anchorRows = nil
}

local function dirname(path)
  return path:match("^(.*)/[^/]+$")
end

local function trim(value)
  return (value:gsub("^%s*(.-)%s*$", "%1"))
end

local function readFile(path)
  local file, errorMessage = io.open(path, "r")
  if not file then
    return nil, errorMessage
  end
  local content = file:read("*a")
  file:close()
  return content
end

local function fileExists(path)
  local file = io.open(path, "r")
  if not file then
    return false
  end
  file:close()
  return true
end

local function hasDataFiles(directory)
  return fileExists(directory .. "/units/unit000.csv")
    and fileExists(directory .. "/status-fields.csv")
    and (fileExists(directory .. "/unit-index.csv")
      or fileExists(directory .. "/names/Unit_Explanation1_ja.csv"))
end

local function removeTrailingSlash(path)
  return (path:gsub("/+$", ""))
end

local function splitCsv(line)
  local values = {}
  local buffer = {}
  local quoted = false
  local index = 1
  while index <= #line do
    local character = line:sub(index, index)
    if character == '"' then
      if quoted and line:sub(index + 1, index + 1) == '"' then
        buffer[#buffer + 1] = '"'
        index = index + 1
      else
        quoted = not quoted
      end
    elseif character == "," and not quoted then
      values[#values + 1] = trim(table.concat(buffer))
      buffer = {}
    else
      buffer[#buffer + 1] = character
    end
    index = index + 1
  end
  values[#values + 1] = trim(table.concat(buffer))
  return values
end

local function suspendUntilVisible()
  -- 画面外を押したときは終了せず、GGアイコンが再度押されるまで待機する。
  gg.setVisible(false)
  while not gg.isVisible() do
    gg.sleep(150)
  end
  gg.setVisible(false)
end

local function chooseMenu(items, title, includeBack)
  local choices = {}
  for index, item in ipairs(items) do
    choices[index] = item
  end
  if includeBack then
    choices[#choices + 1] = "戻る"
  end

  while true do
    local selected = gg.choice(choices, nil, title)
    if selected then
      if includeBack and selected == #choices then
        return nil
      end
      return selected
    end
    suspendUntilVisible()
  end
end

local function initializePaths()
  local scriptPath = gg.getFile()
  local scriptDirectory = dirname(scriptPath)
  if not scriptDirectory then
    return nil, "Luaファイルの場所を取得できません。"
  end

  -- 標準の lua/kbc-status-test.lua と、単独コピーの両方に対応する。
  if scriptDirectory:match("/lua$") then
    state.rootDirectory = dirname(scriptDirectory)
  else
    state.rootDirectory = scriptDirectory
  end
  if not state.rootDirectory then
    return nil, "実行フォルダを取得できません。"
  end

  local candidates = {
    state.rootDirectory .. "/data",
    scriptDirectory .. "/data",
    "/storage/emulated/0/Download/KBC-rakv0-status-script/data",
    "/sdcard/Download/KBC-rakv0-status-script/data"
  }
  for _, directory in ipairs(candidates) do
    if hasDataFiles(directory) then
      state.dataDirectory = directory
      return true
    end
  end

  local selection = gg.prompt(
    { "units・unit-index.csv・status-fields.csv がある data フォルダのフルパス" },
    { "/storage/emulated/0/Download/KBC-rakv0-status-script/data" },
    { "text" }
  )
  if not selection then
    return nil, "data フォルダが指定されませんでした。"
  end
  local directory = removeTrailingSlash(trim(selection[1] or ""))
  if directory == "" or not hasDataFiles(directory) then
    return nil, "ユニットデータを取得できません。data フォルダ全体をコピーして指定してください。"
  end
  state.dataDirectory = directory
  return true
end

local function loadFields()
  local content, errorMessage = readFile(state.dataDirectory .. "/status-fields.csv")
  if not content then
    return nil, "ステータス定義を読めません: " .. tostring(errorMessage)
  end

  local fields = {}
  local lineNumber = 0
  for line in content:gmatch("[^\r\n]+") do
    lineNumber = lineNumber + 1
    if lineNumber > 1 then
      local columns = splitCsv(line)
      local index = tonumber(columns[1])
      local name = trim(columns[2] or "")
      local fieldType = trim(columns[3] or "number")
      local multiplier = tonumber(columns[4]) or 1
      if index ~= #fields or name == "" then
        return nil, string.format("status-fields.csv の%d行目が不正です。", lineNumber)
      end
      if fieldType ~= "number" and fieldType ~= "checkbox" then
        return nil, string.format("%s の入力形式が不正です。", name)
      end
      fields[#fields + 1] = {
        index = index,
        name = name,
        fieldType = fieldType,
        multiplier = multiplier
      }
    end
  end

  if #fields ~= RECORD_COLUMN_COUNT then
    return nil, string.format("ステータス定義は%d件必要です（現在%d件）。", RECORD_COLUMN_COUNT, #fields)
  end
  state.fields = fields
  return true
end

local function loadNamesFromIndex()
  local content, errorMessage = readFile(state.dataDirectory .. "/unit-index.csv")
  if not content then
    return nil, errorMessage
  end

  local lineNumber = 0
  for line in content:gmatch("[^\r\n]+") do
    lineNumber = lineNumber + 1
    if lineNumber > 1 then
      local columns = splitCsv(line)
      local unitId = tonumber(columns[1])
      local formIndex = tonumber(columns[2])
      local formName = trim(columns[3] or "")
      if not unitId or not formIndex or formName == "" then
        return nil, string.format("unit-index.csv の%d行目が不正です。", lineNumber)
      end

      local character = state.characters[unitId]
      if not character then
        if formIndex ~= 0 then
          return nil, string.format("unit %d の第1形態が索引にありません。", unitId)
        end
        character = {
          id = unitId,
          fileName = string.format("unit%03d.csv", unitId),
          name = formName,
          forms = {}
        }
        state.characters[unitId] = character
        state.names[#state.names + 1] = character
      end
      if character.forms[formIndex] then
        return nil, string.format("unit %d の形態%dが重複しています。", unitId, formIndex)
      end
      character.forms[formIndex] = { index = formIndex, label = formName }
    end
  end

  if #state.names == 0 then
    return nil, "unit-index.csv にキャラ名がありません。"
  end
  return true
end

local function loadNamesFromExplanations()
  local sourceId = 1
  while sourceId <= 4096 do
    local explanationPath = string.format("%s/names/Unit_Explanation%d_ja.csv", state.dataDirectory, sourceId)
    local content = readFile(explanationPath)
    if not content then
      break
    end

    local unitId = sourceId - 1
    local fileName = string.format("unit%03d.csv", unitId)
    if not fileExists(state.dataDirectory .. "/units/" .. fileName) then
      return nil, string.format("%s に対応するステータスCSVがありません。", fileName)
    end

    local formNames = {}
    local lastFormName = nil
    for line in content:gmatch("[^\r\n]+") do
      local columns = splitCsv(line)
      local formName = trim(columns[1] or "")
      local description = trim(columns[2] or "")
      if formName:match("^8%d%d[-_]%d+$") and description:match("^精霊[：:]") then
        formName = "精霊"
      end
      if formName ~= "" then
        -- 同じ名前で埋められた末尾形態は選択肢へ追加しない。
        if lastFormName and formName == lastFormName then
          break
        end
        formNames[#formNames + 1] = formName
        lastFormName = formName
      end
    end

    if #formNames == 0 then
      return nil, string.format("Unit_Explanation%d_ja.csv に形態名がありません。", sourceId)
    end

    local character = {
      id = unitId,
      fileName = fileName,
      name = formNames[1],
      forms = {}
    }
    for index, formName in ipairs(formNames) do
      local form = index - 1
      character.forms[form] = { index = form, label = formName }
    end
    state.characters[unitId] = character
    state.names[#state.names + 1] = character
    sourceId = sourceId + 1
  end

  if sourceId > 4096 then
    return nil, "名前ファイルが多すぎます。"
  end

  if #state.names == 0 then
    return nil, "形態名ファイルを読み込めません。"
  end
  return true
end

local function loadNames()
  if fileExists(state.dataDirectory .. "/unit-index.csv") then
    return loadNamesFromIndex()
  end
  -- 古い配布物は従来方式でも起動できるが、ファイル数が多いため遅い。
  return loadNamesFromExplanations()
end

local function loadUnitRows(character)
  local content, errorMessage = readFile(state.dataDirectory .. "/units/" .. character.fileName)
  if not content then
    return nil, "ユニットCSVを読めません: " .. tostring(errorMessage)
  end

  local rows = {}
  for line in content:gmatch("[^\r\n]+") do
    local sourceValues = splitCsv(line)
    local row = {}
    for column = 1, RECORD_COLUMN_COUNT do
      row[column] = tonumber(sourceValues[column]) or 0
    end
    rows[#rows + 1] = row
  end
  return rows
end

local function getAnchorRows()
  if state.anchorRows then
    return state.anchorRows
  end
  local anchorCharacter = state.characters[0]
  if not anchorCharacter then
    return nil, "基準CSVがありません。"
  end
  local rows, errorMessage = loadUnitRows(anchorCharacter)
  if not rows or not rows[1] then
    return nil, errorMessage or "基準CSVが空です。"
  end
  state.anchorRows = rows
  return rows
end

local function getAddressValue(address)
  local values = gg.getValues({ { address = address, flags = gg.TYPE_DWORD } })
  return values[1] and tonumber(values[1].value) or nil
end

local function verifyAnchorCandidate(recordAddress, anchorRows)
  -- 複数形態をまとめて読み、同じ先頭値を持つ別レコードを除外する。
  local requests = {}
  local expectedValues = {}
  local formCount = math.min(#anchorRows, 3)
  for formIndex = 1, formCount do
    local row = anchorRows[formIndex]
    for column = 1, ANCHOR_PREFIX_COLUMNS do
      requests[#requests + 1] = {
        address = recordAddress + (formIndex - 1) * RECORD_SIZE + (column - 1) * 4,
        flags = gg.TYPE_DWORD
      }
      expectedValues[#expectedValues + 1] = row[column]
    end
  end

  local actualValues = gg.getValues(requests)
  for index, expectedValue in ipairs(expectedValues) do
    if not actualValues[index] or tonumber(actualValues[index].value) ~= expectedValue then
      return false
    end
  end
  return true
end

local function findUnitTableAddress()
  if state.unitTableAddress then
    return state.unitTableAddress
  end

  local anchorRows, errorMessage = getAnchorRows()
  if not anchorRows then
    return nil, errorMessage
  end

  gg.clearResults()
  gg.setRanges(gg.REGION_C_BSS)
  gg.searchNumber(ANCHOR_VALUE, gg.TYPE_DWORD)
  local resultCount = gg.getResultsCount()
  if resultCount == 0 then
    gg.clearResults()
    return nil, "ステータスデータを取得できません。対象アプリとデータバージョンを確認してください。"
  end

  local results = gg.getResults(math.min(resultCount, MAX_ANCHOR_CANDIDATES))
  gg.clearResults()
  table.sort(results, function(left, right) return left.address < right.address end)

  for _, result in ipairs(results) do
    local recordAddress = result.address - ANCHOR_OFFSET
    if verifyAnchorCandidate(recordAddress, anchorRows) then
      state.unitTableAddress = recordAddress
      return recordAddress
    end
  end

  return nil, "ステータスデータの照合に失敗しました。ゲームとdataを同じバージョンにしてください。"
end

local function chooseFromList(characters)
  local bucketStarts = {}
  local buckets = {}
  for _, character in ipairs(characters) do
    local bucketStart = math.floor(character.id / 100) * 100
    if not buckets[bucketStart] then
      buckets[bucketStart] = {}
      bucketStarts[#bucketStarts + 1] = bucketStart
    end
    buckets[bucketStart][#buckets[bucketStart] + 1] = character
  end
  table.sort(bucketStarts)

  local bucketLabels = {}
  for index, bucketStart in ipairs(bucketStarts) do
    bucketLabels[index] = string.format("%d〜%d", bucketStart, bucketStart + 99)
  end
  while true do
    local selectedBucket = chooseMenu(bucketLabels, "ユニット番号の範囲を選択", true)
    if not selectedBucket then
      return nil
    end

    local candidates = buckets[bucketStarts[selectedBucket]]
    local labels = {}
    for index, character in ipairs(candidates) do
      labels[index] = string.format("%03d  %s", character.id, character.name)
    end
    local selectedCharacter = chooseMenu(labels, "キャラを選択", true)
    if selectedCharacter then
      return candidates[selectedCharacter]
    end
  end
end

local function chooseByName(characters)
  local prompt = gg.prompt({ "キャラ名を入力" }, { "" }, { "text" })
  if not prompt then
    suspendUntilVisible()
    return nil
  end
  local query = trim(prompt[1] or "")
  if query == "" then
    return nil
  end

  local candidates = {}
  local normalizedQuery = query:lower()
  for _, character in ipairs(characters) do
    if character.name:lower():find(normalizedQuery, 1, true) then
      candidates[#candidates + 1] = character
    end
  end
  if #candidates == 0 then
    gg.alert("該当するキャラがありません。")
    return nil
  end

  local labels = {}
  for index, character in ipairs(candidates) do
    labels[index] = string.format("%03d  %s", character.id, character.name)
  end
  local selectedCharacter = chooseMenu(labels, "検索結果", true)
  return selectedCharacter and candidates[selectedCharacter] or nil
end

local function chooseForm(character)
  local indices = {}
  for formIndex in pairs(character.forms) do
    indices[#indices + 1] = formIndex
  end
  table.sort(indices)
  local labels = {}
  for index, formIndex in ipairs(indices) do
    labels[index] = character.forms[formIndex].label
  end
  local selectedForm = chooseMenu(labels, character.name .. " の形態を選択", true)
  return selectedForm and indices[selectedForm] or nil
end

local function chooseField(title)
  local labels = {}
  for _, field in ipairs(state.fields) do
    labels[#labels + 1] = field.name
  end
  local selectedField = chooseMenu(labels, title, true)
  return selectedField and (selectedField - 1) or nil
end

local function editField(character, formIndex, row, column)
  local unitTableAddress, addressError = findUnitTableAddress()
  if not unitTableAddress then
    gg.alert(addressError)
    return
  end
  local address = unitTableAddress + character.id * UNIT_SIZE + formIndex * RECORD_SIZE + column * 4
  local currentValue = getAddressValue(address)
  local field = state.fields[column + 1]
  local multiplier = field.multiplier
  local displayValue = currentValue and currentValue / multiplier or row[column + 1] / multiplier

  if field.fieldType == "checkbox" then
    local prompt = gg.prompt(
      { field.name },
      { displayValue ~= 0 },
      { "checkbox" }
    )
    if not prompt then
      suspendUntilVisible()
      return
    end
    local inputValue = prompt[1] == true and 1 or 0
    gg.setValues({ { address = address, flags = gg.TYPE_DWORD, value = inputValue } })
    gg.toast(string.format("%s: %s", field.name, inputValue == 1 and "有効" or "無効"))
    return
  end

  local promptLabel = field.name .. "（CSV値）"
  if multiplier ~= 1 then
    promptLabel = string.format("%s（CSV値・内部×%d）", field.name, multiplier)
  end
  local prompt = gg.prompt(
    { promptLabel },
    { tostring(displayValue) },
    { "number" }
  )
  if not prompt then
    suspendUntilVisible()
    return
  end
  local inputValue = tonumber(prompt[1])
  if not inputValue or inputValue % 1 ~= 0 then
    gg.alert("整数を入力してください。")
    return
  end
  local memoryValue = inputValue * multiplier
  gg.setValues({ { address = address, flags = gg.TYPE_DWORD, value = memoryValue } })
  gg.toast(string.format("%s: %d", field.name, inputValue))
end

local function openCharacter(character)
  local rows, errorMessage = loadUnitRows(character)
  if not rows then
    gg.alert(errorMessage or "ステータスCSVを読めません。")
    return
  end

  while true do
    local formIndex = chooseForm(character)
    if formIndex == nil then
      return
    end
    local row = rows[formIndex + 1]
    if not row then
      gg.alert("選択形態のCSVデータがありません。")
      return
    end

    local fieldTitle = string.format("%s / %s", character.name, character.forms[formIndex].label)
    while true do
      local column = chooseField(fieldTitle)
      if column == nil then
        break
      end
      editField(character, formIndex, row, column)
    end
  end
end

local function main()
  local success, errorMessage = initializePaths()
  if not success then
    gg.alert(errorMessage)
    return
  end
  success, errorMessage = loadNames()
  if not success then
    gg.alert(errorMessage)
    return
  end
  success, errorMessage = loadFields()
  if not success then
    gg.alert(errorMessage)
    return
  end

  while true do
    local action = chooseMenu({ "一覧から選ぶ", "キャラ名で検索", "非表示", "終了" }, "KBC ステータス変更", false)
    if action == 1 then
      local character = chooseFromList(state.names)
      if character then openCharacter(character) end
    elseif action == 2 then
      local character = chooseByName(state.names)
      if character then openCharacter(character) end
    elseif action == 3 then
      suspendUntilVisible()
    else
      return
    end
  end
end

main()
