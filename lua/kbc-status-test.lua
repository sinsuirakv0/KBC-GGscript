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

local FIELD_LABELS = {
  [0] = "体力", [1] = "KB", [2] = "速度", [3] = "攻撃頻度",
  [4] = "射程", [5] = "攻撃力", [6] = "生産コスト", [7] = "再生産",
  [8] = "攻撃対象", [9] = "攻撃範囲/幅"
}

local CSV_MULTIPLIERS = {
  [2] = 2, [4] = 2, [5] = 4, [6] = 100,
  [7] = 2, [9] = 4, [44] = 4, [45] = 4
}

local state = {
  rootDirectory = nil,
  dataDirectory = nil,
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

local function hasNameIndex(directory)
  local file = io.open(directory .. "/unit-names.csv", "r")
  if not file then
    return false
  end
  file:close()
  return true
end

local function removeTrailingSlash(path)
  return (path:gsub("/+$", ""))
end

local function splitCsv(line)
  local values = {}
  for value in (line .. ","):gmatch("(.-),") do
    values[#values + 1] = trim(value)
  end
  return values
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
    if hasNameIndex(directory) then
      state.dataDirectory = directory
      return true
    end
  end

  local selection = gg.prompt(
    { "unit-names.csv がある data フォルダのフルパス" },
    { "/storage/emulated/0/Download/KBC-rakv0-status-script/data" },
    { "text" }
  )
  if not selection then
    return nil, "data フォルダが指定されませんでした。"
  end
  local directory = removeTrailingSlash(trim(selection[1] or ""))
  if directory == "" or not hasNameIndex(directory) then
    return nil, "unit-names.csv を取得できません。data フォルダ全体をコピーして指定してください。"
  end
  state.dataDirectory = directory
  return true
end

local function loadNames()
  local content, errorMessage = readFile(state.dataDirectory .. "/unit-names.csv")
  if not content then
    return nil, "unit-names.csv を読めません: " .. tostring(errorMessage)
  end

  for line in content:gmatch("[^\r\n]+") do
    local columns = splitCsv(line)
    local unitId = tonumber(columns[1])
    local form = tonumber(columns[3])
    if unitId and form and columns[2] and columns[4] and columns[5] then
      local character = state.characters[unitId]
      if not character then
        character = { id = unitId, fileName = columns[2], name = columns[4], forms = {} }
        state.characters[unitId] = character
        state.names[#state.names + 1] = character
      end
      character.forms[form] = { index = form, label = columns[5] }
    end
  end

  table.sort(state.names, function(left, right) return left.id < right.id end)
  if #state.names == 0 then
    return nil, "unit-names.csv に有効なユニットがありません。"
  end
  return true
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
  local selectedBucket = gg.choice(bucketLabels, nil, "ユニット番号の範囲を選択")
  if not selectedBucket then
    return nil
  end

  local candidates = buckets[bucketStarts[selectedBucket]]
  local labels = {}
  for index, character in ipairs(candidates) do
    labels[index] = string.format("%03d  %s", character.id, character.name)
  end
  local selectedCharacter = gg.choice(labels, nil, "キャラを選択")
  return selectedCharacter and candidates[selectedCharacter] or nil
end

local function chooseByName(characters)
  local prompt = gg.prompt({ "キャラ名を入力" }, { "" }, { "text" })
  if not prompt then
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
  local selectedCharacter = gg.choice(labels, nil, "検索結果")
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
  local selectedForm = gg.choice(labels, nil, character.name .. " の形態を選択")
  return selectedForm and indices[selectedForm] or nil
end

local function getFieldLabel(column)
  return FIELD_LABELS[column] or string.format("CSV列 %03d", column)
end

local function chooseField()
  local pageLabels = {}
  for startColumn = 0, RECORD_COLUMN_COUNT - 1, 20 do
    pageLabels[#pageLabels + 1] = string.format("列 %03d〜%03d", startColumn, math.min(startColumn + 19, RECORD_COLUMN_COUNT - 1))
  end
  local selectedPage = gg.choice(pageLabels, nil, "変更する項目の範囲を選択")
  if not selectedPage then
    return nil
  end
  local startColumn = (selectedPage - 1) * 20
  local labels = {}
  for column = startColumn, math.min(startColumn + 19, RECORD_COLUMN_COUNT - 1) do
    labels[#labels + 1] = string.format("%03d  %s", column, getFieldLabel(column))
  end
  local selectedField = gg.choice(labels, nil, "変更する項目を選択")
  return selectedField and (startColumn + selectedField - 1) or nil
end

local function editField(character, formIndex, row, unitTableAddress)
  local column = chooseField()
  if column == nil then
    return
  end
  local address = unitTableAddress + character.id * UNIT_SIZE + formIndex * RECORD_SIZE + column * 4
  local currentValue = getAddressValue(address)
  local multiplier = CSV_MULTIPLIERS[column] or 1
  local displayValue = currentValue and currentValue / multiplier or row[column + 1] / multiplier
  local prompt = gg.prompt(
    { string.format("%s（CSV値）", getFieldLabel(column)) },
    { tostring(displayValue) },
    { "number" }
  )
  if not prompt then
    return
  end
  local inputValue = tonumber(prompt[1])
  if not inputValue or inputValue % 1 ~= 0 then
    gg.alert("整数を入力してください。")
    return
  end
  local memoryValue = inputValue * multiplier
  gg.setValues({ { address = address, flags = gg.TYPE_DWORD, value = memoryValue } })
  gg.toast(string.format("%s: %d", getFieldLabel(column), inputValue))
end

local function openCharacter(character)
  local formIndex = chooseForm(character)
  if formIndex == nil then
    return
  end
  local rows, errorMessage = loadUnitRows(character)
  local row = rows and rows[formIndex + 1]
  if not row then
    gg.alert(errorMessage or "選択形態のCSVデータがありません。")
    return
  end
  local unitTableAddress, addressError = findUnitTableAddress()
  if not unitTableAddress then
    gg.alert(addressError)
    return
  end

  while true do
    local action = gg.choice({ "ステータスを変更", "CSVの先頭値を確認", "戻る" }, nil,
      string.format("%03d %s / %s", character.id, character.name, character.forms[formIndex].label))
    if action == 1 then
      editField(character, formIndex, row, unitTableAddress)
    elseif action == 2 then
      gg.alert(string.format("体力: %d\n速度: %d\n攻撃力: %d\nコスト: %d",
        row[1], row[3], row[6], row[7]))
    else
      return
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

  while true do
    local action = gg.choice({ "一覧から選ぶ", "キャラ名で検索", "終了" }, nil, "KBC ステータス変更")
    if action == 1 then
      local character = chooseFromList(state.names)
      if character then openCharacter(character) end
    elseif action == 2 then
      local character = chooseByName(state.names)
      if character then openCharacter(character) end
    else
      return
    end
  end
end

main()
