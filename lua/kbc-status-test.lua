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
local SAVE_SEARCH_START_OFFSET = 0x2100
local SAVE_SEARCH_END_OFFSET = 0xFFFFF
local SAVE_ANALYSIS_WINDOW = 0x6400
local SAVE_RESULT_BATCH_SIZE = 6000
local MAX_SAVE_BASE_RESULTS = 4096
local MAX_SAVE_BASE_VERIFICATIONS = 8
local MAX_SAVE_TABLE_CANDIDATES = 8
local SIGN_EQUAL = gg.SIGN_EQUAL or 536870912

local state = {
  rootDirectory = nil,
  dataDirectory = nil,
  fields = {},
  names = {},
  characters = {},
  unitTableAddress = nil,
  anchorRows = nil,
  saveBaseAddress = nil,
  saveCharacterTables = nil
}

local kenkouUi = {
  choicePositions = {}
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
    and fileExists(directory .. "/unit-index.csv")
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

local function kenkouSuspendUntilVisible()
  -- kenkou: 画面外を押したときは終了せず、GGアイコンが再度押されるまで待機する。
  gg.setVisible(false)
  while not gg.isVisible() do
    gg.sleep(150)
  end
  gg.setVisible(false)
end

local function kenkouChooseMenu(items, title, includeBack, positionKey)
  local choices = {}
  local offset = 0
  if includeBack then
    choices[#choices + 1] = "戻る"
    offset = 1
  end
  for index, item in ipairs(items) do
    choices[#choices + 1] = item
  end
  if includeBack then
    choices[#choices + 1] = "戻る"
  end

  local key = positionKey or title
  while true do
    local selectedPosition = kenkouUi.choicePositions[key] or (offset + 1)
    selectedPosition = math.max(1, math.min(selectedPosition, #choices))
    local selected = gg.choice(choices, selectedPosition, title)
    if selected then
      if includeBack and (selected == 1 or selected == #choices) then
        return nil
      end
      kenkouUi.choicePositions[key] = selected
      return selected - offset
    end
    kenkouSuspendUntilVisible()
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

local function loadNames()
  return loadNamesFromIndex()
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

local function kenkouGetSortedResults(limit)
  local resultCount = gg.getResultsCount()
  if resultCount == 0 then
    return {}
  end
  local results = gg.getResults(math.min(resultCount, limit or resultCount))
  table.sort(results, function(left, right) return left.address < right.address end)
  return results
end

local function kenkouVerifySaveBaseCandidate(address)
  gg.clearResults()
  local pattern = ("-256~255;"):rep(2) .. ("-257~~256;"):rep(2) .. "-256~255;-256~255::21"
  gg.searchNumber(pattern, gg.TYPE_DWORD, false, SIGN_EQUAL, address, address + 0x120)
  local valid = gg.getResultsCount() == 6
  gg.clearResults()
  return valid
end

local function kenkouResolveSaveBaseAddress()
  if state.saveBaseAddress then
    return state.saveBaseAddress
  end

  -- kenkou: 元スクリプトのsetup.luaが取得していた時差値をローカルで組み立てる。
  local currentTime = os.time()
  local timezoneSeconds = math.floor(os.difftime(currentTime, os.time(os.date("!*t", currentTime))))
  local timezoneHex = string.format("%08x", timezoneSeconds % 4294967296)
  local bytes = {}
  for byte in timezoneHex:gmatch("%x%x") do
    table.insert(bytes, 1, byte)
  end
  local timezonePattern = "h " .. table.concat(bytes, " ")

  local splitRanges = gg.getRangesList("split_config.arm64_v8a.apk:bss") or {}
  local splitRange = splitRanges[1]
  local memoryFrom = splitRange and splitRange.start or 0
  local memoryTo = splitRange and (splitRange.start + 0xFFFF) or -1
  gg.clearResults()
  -- kenkou: 32-bit側の48は元setup.luaと同じ複合範囲。C_BSS単独へ狭めない。
  gg.setRanges(splitRange and -2080896 or 48)
  gg.toast("保存領域の基準を探索中")
  gg.searchNumber(timezonePattern, gg.TYPE_BYTE, false, SIGN_EQUAL, memoryFrom, memoryTo)
  if gg.getResultsCount() == 0 then
    gg.clearResults()
    return nil, "保存領域の基準値を取得できません。アプリを再起動してから再試行してください。"
  end

  local firstResult = gg.getResults(1)[1]
  if not firstResult then
    gg.clearResults()
    return nil, "保存領域の基準候補を取得できません。"
  end
  gg.refineNumber(firstResult.value, gg.TYPE_BYTE)
  local refinedCount = gg.getResultsCount()
  if refinedCount > MAX_SAVE_BASE_RESULTS then
    gg.clearResults()
    return nil, string.format("保存領域の基準候補が多すぎます（%d件）。アプリを再起動してください。", refinedCount)
  end
  local results = kenkouGetSortedResults(MAX_SAVE_BASE_RESULTS)
  gg.clearResults()

  local verificationCount = 0
  for index, result in ipairs(results) do
    if not results[index + 2] then
      state.saveBaseAddress = result.address
      return result.address
    end
    local gap = results[index + 2].address - results[index + 1].address
    if gap > 0x3000 and gap < 0x4FFF then
      verificationCount = verificationCount + 1
      if verificationCount > MAX_SAVE_BASE_VERIFICATIONS then
        break
      end
      if kenkouVerifySaveBaseCandidate(result.address) then
        state.saveBaseAddress = result.address
        return result.address
      end
    end
  end
  return nil, "保存領域の基準候補を検証できません。"
end

local function kenkouValidateSaveCharacterTables(tables)
  local ownershipCount = #tables.ownership
  local levelCount = #tables.level
  local formCount = #tables.form
  if tables.unitCount < 32 or tables.unitCount > 4096 then
    return false
  end
  if ownershipCount ~= tables.unitCount or levelCount ~= tables.unitCount * 2
    or formCount ~= tables.unitCount then
    return false
  end
  if tables.level[1].address <= tables.ownership[#tables.ownership].address then
    return false
  end
  if tables.form[1].address <= tables.level[#tables.level].address then
    return false
  end
  return true
end

local function kenkouBuildDwordRecords(startAddress, count)
  local records = {}
  for index = 0, count - 1 do
    records[#records + 1] = {
      address = startAddress + index * 4,
      flags = gg.TYPE_DWORD
    }
  end
  return records
end

local function kenkouFindSaveCharacterTables(anchorAddress, anchorValue)
  anchorValue = math.floor(anchorValue)
  gg.clearResults()
  gg.searchNumber(string.format("%d~%d", anchorValue - 1, anchorValue + 1), gg.TYPE_DWORD, false,
    SIGN_EQUAL, anchorAddress - 0x500, anchorAddress + SAVE_ANALYSIS_WINDOW)
  local startResults = gg.getResultsCount() > 0 and gg.getResults(1) or {}
  gg.clearResults()
  local startAddress = startResults[1] and startResults[1].address or nil
  if not startAddress then
    return nil
  end

  gg.searchNumber("0~10", gg.TYPE_DWORD, false, SIGN_EQUAL, anchorAddress,
    anchorAddress + SAVE_ANALYSIS_WINDOW)
  local endResults = gg.getResultsCount() > 0 and gg.getResults(1) or {}
  gg.clearResults()
  local levelEnd = endResults[1] and (endResults[1].address - 4) or nil
  if not levelEnd or levelEnd <= startAddress then
    return nil
  end

  -- kenkou: 所持N件とレベル2N件の合計バイト数からNを確定し、値0も含めて全件生成する。
  local combinedBytes = levelEnd - startAddress + 4
  if combinedBytes % 12 ~= 0 then
    return nil
  end
  local unitCount = math.floor(combinedBytes / 12)
  local levelStart = startAddress + unitCount * 4
  local formStart = levelStart + unitCount * 8
  if formStart ~= levelEnd + 4 then
    return nil
  end
  local tables = {
    ownership = kenkouBuildDwordRecords(startAddress, unitCount),
    level = kenkouBuildDwordRecords(levelStart, unitCount * 2),
    form = kenkouBuildDwordRecords(formStart, unitCount),
    unitCount = unitCount
  }
  if kenkouValidateSaveCharacterTables(tables) then
    return tables
  end
  return nil
end

local function kenkouResolveSaveCharacterTables()
  if state.saveCharacterTables then
    return state.saveCharacterTables
  end
  local baseAddress, baseError = kenkouResolveSaveBaseAddress()
  if not baseAddress then
    return nil, baseError
  end

  gg.clearResults()
  gg.toast("キャラ保存状態を探索中")
  local pattern = "-257~~256" .. (";-257~~256"):rep(63) .. ":253"
  gg.searchNumber(pattern, gg.TYPE_DWORD, false, SIGN_EQUAL,
    baseAddress + SAVE_SEARCH_START_OFFSET, baseAddress + SAVE_SEARCH_END_OFFSET)
  local resultCount = gg.getResultsCount()
  if resultCount < 16 then
    gg.clearResults()
    return nil, "キャラ保存状態の配列候補が見つかりません。"
  end

  -- kenkou: 大量結果を一括取得・ソートせず、元の120件間隔を保って分割処理する。
  local candidates = {}
  local cachedValue = nil
  local skip = 0
  while skip < resultCount - 15 and #candidates < MAX_SAVE_TABLE_CANDIDATES do
    local batchCount = math.min(SAVE_RESULT_BATCH_SIZE, resultCount - skip)
    local results = gg.getResults(batchCount, skip)
    if #results < 16 then
      break
    end
    for index = 1, #results - 15, 120 do
      local current = results[index]
      local comparable = cachedValue
        and math.abs((tonumber(current.value) or 0) - (tonumber(results[index + 3].value) or 0)) < 2
        and math.abs((tonumber(results[index + 10].value) or 0) - (tonumber(results[index + 15].value) or 0)) < 2
      if comparable then
        if cachedValue ~= results[index + 14].value then
          cachedValue = current.value
        else
          candidates[#candidates + 1] = {
            address = current.address,
            value = tonumber(current.value) or 0
          }
          cachedValue = -1
          if #candidates >= MAX_SAVE_TABLE_CANDIDATES then
            break
          end
        end
      else
        cachedValue = -1
      end
    end
    skip = skip + SAVE_RESULT_BATCH_SIZE
  end
  gg.clearResults()

  if #candidates == 0 then
    return nil, string.format("キャラ保存状態の構造候補が見つかりません（検索結果%d件）。", resultCount)
  end
  for index, candidate in ipairs(candidates) do
    gg.toast(string.format("保存配列を確認中 %d/%d", index, #candidates))
    local tables = kenkouFindSaveCharacterTables(candidate.address, candidate.value)
    if tables then
      state.saveCharacterTables = tables
      gg.toast(string.format("保存配列を確認しました（%d体）", tables.unitCount))
      return tables
    end
  end
  return nil, string.format("保存配列を確認できませんでした（候補%d件）。", #candidates)
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
    local selectedBucket = kenkouChooseMenu(bucketLabels, "ユニット番号の範囲を選択", true, "kenkou-bucket")
    if not selectedBucket then
      return nil
    end

    local candidates = buckets[bucketStarts[selectedBucket]]
    local labels = {}
    for index, character in ipairs(candidates) do
      labels[index] = string.format("%03d  %s", character.id, character.name)
    end
    local selectedCharacter = kenkouChooseMenu(labels, "キャラを選択", true,
      "kenkou-character-" .. bucketStarts[selectedBucket])
    if selectedCharacter then
      return candidates[selectedCharacter]
    end
  end
end

local function chooseByName(characters)
  local prompt = gg.prompt({ "キャラ名を入力" }, { "" }, { "text" })
  if not prompt then
    kenkouSuspendUntilVisible()
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
  local selectedCharacter = kenkouChooseMenu(labels, "検索結果", true, "kenkou-search-results")
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
    labels[index] = string.format("第%d　%s", formIndex + 1, character.forms[formIndex].label)
  end
  local selectedForm = kenkouChooseMenu(labels, character.name .. " の形態を選択", true,
    "kenkou-form-" .. character.id)
  return selectedForm and indices[selectedForm] or nil
end

local function kenkouFormatFieldLabel(field)
  if field.fieldType == "checkbox" then
    return field.name
  end
  if field.multiplier ~= 1 then
    return string.format("%s（CSV値・内部×%d）", field.name, field.multiplier)
  end
  return field.name .. "（CSV値）"
end

local function kenkouReadFormValues(character, formIndex, row)
  local unitTableAddress, addressError = findUnitTableAddress()
  if not unitTableAddress then
    return nil, addressError
  end
  local requests = {}
  for column = 0, RECORD_COLUMN_COUNT - 1 do
    requests[#requests + 1] = {
      address = unitTableAddress + character.id * UNIT_SIZE + formIndex * RECORD_SIZE + column * 4,
      flags = gg.TYPE_DWORD
    }
  end
  local values = gg.getValues(requests)
  for index, request in ipairs(requests) do
    if not values[index] then
      values[index] = {
        address = request.address,
        flags = request.flags,
        value = row[index] or 0
      }
    elseif values[index].value == nil then
      values[index].value = row[index] or 0
    end
  end
  return values
end

local function kenkouResetStatusValues(currentValues, row)
  local writes = {}
  for index = 1, RECORD_COLUMN_COUNT do
    local initialValue = tonumber(row[index]) or 0
    local currentValue = tonumber(currentValues[index] and currentValues[index].value) or initialValue
    if currentValue ~= initialValue then
      writes[#writes + 1] = {
        address = currentValues[index].address,
        flags = gg.TYPE_DWORD,
        value = initialValue
      }
    end
  end
  if #writes == 0 then
    gg.toast("すでに初期状態です")
    return
  end
  gg.setValues(writes)
  gg.toast(string.format("%d項目を初期状態に戻しました", #writes))
end

local function kenkouOpenStatusEditor(character, formIndex, row)
  local currentValues, errorMessage = kenkouReadFormValues(character, formIndex, row)
  if not currentValues then
    gg.alert(errorMessage)
    return
  end

  local fieldOffset = 2
  local prompts = { "戻る（変更せず戻る）", "全てリセット" }
  local defaults = { false, false }
  local types = { "checkbox", "checkbox" }
  for index, field in ipairs(state.fields) do
    local memoryValue = tonumber(currentValues[index] and currentValues[index].value) or row[index] or 0
    local csvValue = memoryValue / field.multiplier
    prompts[#prompts + 1] = kenkouFormatFieldLabel(field)
    if field.fieldType == "checkbox" then
      defaults[#defaults + 1] = csvValue ~= 0
    else
      defaults[#defaults + 1] = tostring(csvValue)
    end
    types[#types + 1] = field.fieldType == "checkbox" and "checkbox" or "number"
  end
  prompts[#prompts + 1] = "戻る（変更せず戻る）"
  defaults[#defaults + 1] = false
  types[#types + 1] = "checkbox"

  -- kenkou: 117項目を一度に表示し、入力中はスクロール位置を維持する。
  local prompt = gg.prompt(
    prompts,
    defaults,
    types
  )
  if not prompt then
    kenkouSuspendUntilVisible()
    return
  end
  if prompt[1] == true or prompt[#prompt] == true then
    return
  end
  if prompt[2] == true then
    local confirmation = gg.alert("ステータスを全てリセットしますか？", "はい", "いいえ")
    if confirmation == 1 then
      kenkouResetStatusValues(currentValues, row)
    end
    return
  end

  local writes = {}
  for index, field in ipairs(state.fields) do
    local inputValue
    if field.fieldType == "checkbox" then
      inputValue = prompt[index + fieldOffset] == true and 1 or 0
    else
      inputValue = tonumber(prompt[index + fieldOffset])
      if not inputValue or inputValue % 1 ~= 0 then
        gg.alert(field.name .. " は整数で入力してください。")
        return
      end
    end
    local memoryValue = inputValue * field.multiplier
    local currentValue = tonumber(currentValues[index] and currentValues[index].value) or row[index] or 0
    if memoryValue ~= currentValue then
      writes[#writes + 1] = {
        address = currentValues[index].address,
        flags = gg.TYPE_DWORD,
        value = memoryValue
      }
    end
  end

  if #writes == 0 then
    gg.toast("変更はありません")
    return
  end
  gg.setValues(writes)
  gg.toast(string.format("%d項目を変更しました", #writes))
end

local function kenkouSaveToList(character, formIndex, row)
  local currentValues, errorMessage = kenkouReadFormValues(character, formIndex, row)
  if not currentValues then
    gg.alert(errorMessage)
    return
  end

  local listItems = {}
  local formLabel = character.forms[formIndex].label
  for index, field in ipairs(state.fields) do
    listItems[#listItems + 1] = {
      address = currentValues[index].address,
      flags = gg.TYPE_DWORD,
      value = currentValues[index].value,
      name = string.format("%03d 第%d %s | %s", character.id, formIndex + 1, formLabel, field.name)
    }
  end
  gg.addListItems(listItems)
  gg.toast(string.format("保存リストへ%d項目を追加しました", #listItems))
end

local function kenkouGetSaveAddresses(character)
  local tables, errorMessage = kenkouResolveSaveCharacterTables()
  if not tables then
    return nil, errorMessage
  end
  local saveId = character.id + 1
  if saveId < 1 or saveId > tables.unitCount then
    return nil, string.format("%sの保存IDが配列範囲外です（保存ID %d / 配列 %d件）。",
      character.name, saveId, tables.unitCount)
  end
  local ownershipRecord = tables.ownership[saveId]
  local firstLevelRecord = tables.level[saveId * 2 - 1]
  local secondLevelRecord = tables.level[saveId * 2]
  local formRecord = tables.form[saveId]
  local catOwnershipRecord = tables.ownership[1]
  local deletedOwnershipRecord = tables.ownership[tables.unitCount]
  if not ownershipRecord or not firstLevelRecord or not secondLevelRecord or not formRecord
    or not catOwnershipRecord or not deletedOwnershipRecord then
    return nil, string.format("%sの保存レコードを取得できません。", character.name)
  end
  return {
    saveId = saveId,
    ownership = ownershipRecord.address,
    level = firstLevelRecord.address,
    levelMarker = secondLevelRecord.address,
    form = formRecord.address,
    catOwnership = catOwnershipRecord.address,
    deletedOwnership = deletedOwnershipRecord.address
  }
end

local function kenkouUnlockCharacter(character)
  local addresses, errorMessage = kenkouGetSaveAddresses(character)
  if not addresses then
    gg.alert(errorMessage)
    return
  end
  local values = gg.getValues({
    { address = addresses.catOwnership, flags = gg.TYPE_DWORD },
    { address = addresses.ownership, flags = gg.TYPE_DWORD }
  })
  if not values[1] or values[1].value == nil or not values[2] then
    gg.alert("キャラ解放値を読み取れません。")
    return
  end
  gg.setValues({
    {
      address = addresses.ownership,
      flags = gg.TYPE_DWORD,
      value = values[1].value
    }
  })
  gg.toast(character.name .. "を解放しました")
end

local function kenkouDeleteCharacter(character)
  local addresses, errorMessage = kenkouGetSaveAddresses(character)
  if not addresses then
    gg.alert(errorMessage)
    return
  end
  if addresses.saveId == 1 then
    gg.alert("ネコは削除できません。")
    return
  end
  if addresses.ownership == addresses.deletedOwnership then
    gg.alert("このキャラの削除用レコードを取得できません。")
    return
  end
  local confirmation = gg.alert(character.name .. "を削除しますか？", "はい", "いいえ")
  if confirmation ~= 1 then
    return
  end
  local values = gg.getValues({
    { address = addresses.deletedOwnership, flags = gg.TYPE_DWORD },
    { address = addresses.ownership, flags = gg.TYPE_DWORD }
  })
  if not values[1] or values[1].value == nil or not values[2] then
    gg.alert("キャラ削除値を読み取れません。")
    return
  end
  gg.setValues({
    {
      address = addresses.ownership,
      flags = gg.TYPE_DWORD,
      value = values[1].value
    }
  })
  gg.toast(character.name .. "を削除しました")
end

local function kenkouDecodeLevel(levelValue, markerValue)
  local adjustment
  if markerValue == 131072 then
    adjustment = 512
  elseif markerValue == 65536 then
    adjustment = 256
  else
    return nil, nil
  end
  local encoded = levelValue - adjustment
  if encoded < 0 then
    return nil, nil
  end
  return math.floor(encoded / 65536) + 1, encoded % 65536
end

local function kenkouRemoveLevelListItems(addresses)
  if type(gg.getListItems) ~= "function" or type(gg.removeListItems) ~= "function" then
    return
  end
  local targets = {
    [addresses.level] = true,
    [addresses.levelMarker] = true
  }
  local removals = {}
  for _, item in ipairs(gg.getListItems() or {}) do
    if targets[item.address] then
      removals[#removals + 1] = item
    end
  end
  if #removals > 0 then
    gg.removeListItems(removals)
  end
end

local function kenkouChangeLevel(character)
  local addresses, errorMessage = kenkouGetSaveAddresses(character)
  if not addresses then
    gg.alert(errorMessage)
    return
  end
  local currentValues = gg.getValues({
    { address = addresses.level, flags = gg.TYPE_DWORD },
    { address = addresses.levelMarker, flags = gg.TYPE_DWORD }
  })
  if not currentValues[1] or not currentValues[2] then
    gg.alert("現在のレベル値を読み取れません。")
    return
  end
  local currentLevel, currentPlus = kenkouDecodeLevel(
    tonumber(currentValues[1].value) or 0,
    tonumber(currentValues[2].value) or 0
  )
  if not currentLevel then
    gg.alert(string.format("現在のレベルを復号できません。\n値1: %s\n値2: %s\n初期入力をレベル1＋0で開きます。",
      tostring(currentValues[1].value), tostring(currentValues[2].value)))
  end
  currentLevel = currentLevel or 1
  currentPlus = currentPlus or 0

  local input = gg.prompt(
    { "レベル", "プラス値", "凍結" },
    { tostring(currentLevel), tostring(currentPlus), true },
    { "number", "number", "checkbox" }
  )
  if not input then
    kenkouSuspendUntilVisible()
    return
  end
  local level = tonumber(input[1])
  local plus = tonumber(input[2])
  if not level or level % 1 ~= 0 or level < 1 then
    gg.alert("レベルは1以上の整数で入力してください。")
    return
  end
  if not plus or plus % 1 ~= 0 or plus < 0 or plus > 65535 then
    gg.alert("プラス値は0〜65535の整数で入力してください。")
    return
  end

  local encoded = (level - 1) * 65536 + plus
  if encoded > 2147483647 then
    gg.alert("指定値がDWORDの範囲を超えています。")
    return
  end
  local oddByte = encoded / 256 % 2 == 1
  local writes = {
    {
      address = addresses.level,
      flags = gg.TYPE_DWORD,
      value = encoded + (oddByte and 512 or 256),
      name = string.format("%03d %s | レベル", character.id, character.name)
    },
    {
      address = addresses.levelMarker,
      flags = gg.TYPE_DWORD,
      value = oddByte and 131072 or 65536,
      name = string.format("%03d %s | レベル識別値", character.id, character.name)
    }
  }

  -- kenkou: 以前の凍結を解除してから値を書き、選択された場合だけ再登録する。
  kenkouRemoveLevelListItems(addresses)
  gg.setValues(writes)
  if input[3] == true then
    for _, write in ipairs(writes) do
      write.freeze = true
      write.freezeType = gg.FREEZE_NORMAL
    end
    gg.addListItems(writes)
  end
  gg.sleep(50)
  local verifiedValues = gg.getValues({
    { address = addresses.level, flags = gg.TYPE_DWORD },
    { address = addresses.levelMarker, flags = gg.TYPE_DWORD }
  })
  if not verifiedValues[1] or not verifiedValues[2]
    or tonumber(verifiedValues[1].value) ~= writes[1].value
    or tonumber(verifiedValues[2].value) ~= writes[2].value then
    gg.alert("レベル値を書き込みましたが、直後の確認で値が一致しませんでした。")
    return
  end
  gg.toast(string.format("%sをレベル%d＋%dに変更しました%s",
    character.name, level, plus, input[3] == true and "（凍結中）" or ""))
end

local function kenkouOpenSaveEditor(character)
  while true do
    local action = kenkouChooseMenu(
      { "キャラ解放", "キャラ削除", "レベル変更", "戻る" },
      character.name .. " / キャラ解放・レベル変更",
      false,
      "kenkou-save-action-" .. character.id
    )
    if action == 1 then
      kenkouUnlockCharacter(character)
    elseif action == 2 then
      kenkouDeleteCharacter(character)
    elseif action == 3 then
      kenkouChangeLevel(character)
    else
      return
    end
  end
end

local function kenkouOpenCharacter(character)
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

    local fieldTitle = string.format("%s / 第%d %s", character.name, formIndex + 1, character.forms[formIndex].label)
    while true do
      local action = kenkouChooseMenu(
        { "キャラ解放/レベル変更", "ステータス変更", "リストに保存", "戻る" },
        fieldTitle,
        false,
        "kenkou-action-" .. character.id .. "-" .. formIndex
      )
      if action == nil or action == 4 then
        break
      end
      if action == 1 then
        kenkouOpenSaveEditor(character)
      elseif action == 2 then
        kenkouOpenStatusEditor(character, formIndex, row)
      elseif action == 3 then
        kenkouSaveToList(character, formIndex, row)
      end
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
    local action = kenkouChooseMenu({ "一覧から選ぶ", "キャラ名で検索", "非表示", "終了" },
      "KBC ステータス変更", false, "kenkou-main")
    if action == 1 then
      local character = chooseFromList(state.names)
      if character then kenkouOpenCharacter(character) end
    elseif action == 2 then
      local character = chooseByName(state.names)
      if character then kenkouOpenCharacter(character) end
    elseif action == 3 then
      kenkouSuspendUntilVisible()
    else
      return
    end
  end
end

main()
