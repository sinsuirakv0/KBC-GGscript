-- KBC-rakv0 status script (production build)
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
local MAX_SAVE_TABLE_CANDIDATES = 32
local MAX_OWNERSHIP_START_CANDIDATES = 256
local MAX_FORM_ANCHOR_CANDIDATES = 1024
-- arm64-v8a v15.5.1 の SAVE_DATA オブジェクト内オフセット。
-- FUN_0080f4bc のデシリアライザが、所有状態・レベル・現在形態を
-- それぞれこの順番で読み書きしていることを確認済み。
-- MyApplication の vtable は ELF の load bias からの相対位置。
-- 実行中の MyApplication は .bss に1個だけあり、この vtable ポインタを
-- 検索することで、ASLR 後も SAVE_DATA の実体を安全に取得できる。
local NATIVE_MY_APPLICATION_VTABLE_RVA = 0xAA9BE8
-- `SAVE_DATA` に直列化される実行中の所有状態配列とXOR鍵。復号値は0/1である。
-- `0x814F8` のID表は旧形式・互換用であり、実行中の編集には使用しない。
local NATIVE_SAVE_OWNERSHIP_OFFSET = 0x46A08
local NATIVE_SAVE_LEVEL_OFFSET = 0x477B0
local NATIVE_SAVE_FORM_OFFSET = 0x492F8
local NATIVE_SAVE_OWNERSHIP_KEY_OFFSET = 0x477AC
-- ID 872 の個別解放・削除で、通常 SAVE_DATA 側の0/1フラグだけを更新し、
-- 画面反映と安定動作を実機確認済み。旧ID表は一切更新しない。
local OWNERSHIP_EDITING_ENABLED = true
-- FUN_0080f4bc が SpecialSkills（施設強化）を読み込む配列。
-- 11枠のうち index=1 はにゃんこ砲攻撃力の内部ミラーで、画面上の
-- 10施設としては 0,2,3,4,5,6,7,8,9,10 を使用する。
local NATIVE_SAVE_FACILITY_OFFSET = 0x4A09C
local NATIVE_SAVE_FACILITY_STRIDE = 8
local NATIVE_SAVE_FACILITY_COUNT = 11
-- 施設配列の相対位置が移動した場合に使う探索範囲。まず固定候補を検証し、
-- 失敗したときだけ現在形態配列の近傍を走査する。
local FACILITY_RELATIVE_SCAN_RADIUS = 0x20000
local FACILITY_RELATIVE_SCAN_BATCH = 512
-- ランダムな保護値を誤採用しないための探索時上限。通常の施設上限を十分に含む。
local FACILITY_DISCOVERY_MAX_LEVEL = 100
local FACILITY_DISCOVERY_MAX_PLUS = 100
local FACILITY_SKILL_INDICES = { 0, 2, 3, 4, 5, 6, 7, 8, 9, 10 }
local FACILITY_NAMES = {
  [0] = "にゃんこ砲攻撃力",
  [2] = "にゃんこ砲射程",
  [3] = "にゃんこ砲チャージ",
  [4] = "働きネコ仕事効率",
  [5] = "働きネコお財布",
  [6] = "お城体力",
  [7] = "研究力",
  [8] = "会計力",
  [9] = "勉強力",
  [10] = "統率力"
}

-- SAVE_DATAの相対レイアウトはここに集約する。
-- アップデートで構造が維持され、オフセットだけ変わった場合は、
-- この表へ新しいプロファイルを追加すればよい。実行時には必ず値検証を行い、
-- 一致しないプロファイルではメモリを書き換えない。
local NATIVE_SAVE_LAYOUT_PROFILES = {
  {
    name = "v15.5.1-arm64",
    version = "15.5.1",
    ownershipOffset = NATIVE_SAVE_OWNERSHIP_OFFSET,
    levelOffset = NATIVE_SAVE_LEVEL_OFFSET,
    formOffset = NATIVE_SAVE_FORM_OFFSET,
    ownershipKeyOffset = NATIVE_SAVE_OWNERSHIP_KEY_OFFSET
  }
}

function kenkouGetNativeSaveLayoutProfile()
  local targetInfo = {}
  if type(gg.getTargetInfo) == "function" then
    targetInfo = gg.getTargetInfo() or {}
  end
  local versionName = tostring(targetInfo.versionName or targetInfo.version or "")
  for _, profile in ipairs(NATIVE_SAVE_LAYOUT_PROFILES) do
    if profile.version ~= "" and versionName:find(profile.version, 1, true) then
      return profile
    end
  end
  -- 未知バージョンは現行プロファイルを検証対象にするが、検証失敗時は停止する。
  return NATIVE_SAVE_LAYOUT_PROFILES[1]
end
-- kenkou: v15.5.1 native serializer のフィールド位置。現在形態配列を基準にし、
-- 実行時値の検証に通った場合だけ補助配列へアクセスする。
-- FUN_0066c2c8 の0x369件ループから得た相対位置を使用する。
local NATIVE_FORM_FIELD_OFFSET = 0x27964
-- kenkou: nativeBase はフォーム配列先頭から 0x27964 を戻したセーブ基準アドレス。
-- ここでは Ghidra のセーブ基準からの絶対オフセットをそのまま使う。
-- kenkou: v15.5.1では第3/第4形態の解放状態は個別のDWORDフラグ配列。
-- 最高解放形態を1つの値で持つ配列や、暗号化8バイト配列ではない。
local NATIVE_UNLOCKED_FORMS_OFFSET = 0x335150 -- 第3形態 (form code 2)
local NATIVE_MAX_UPGRADE_OFFSET = 0x335EF4 -- 第4形態 (form code 3)
local NATIVE_FOURTH_FORM_OFFSET = 0x335EF4 -- 互換用別名
local AUXILIARY_OFFSET_SCAN_RADIUS = 0x400
local AUXILIARY_OFFSET_SCAN_STEP = 4
-- kenkou: v15.5.0 / v15.5.1で共通。可変長のユニット領域より前の保存ヘッダー長。
local SAVE_CHARACTER_HEADER_SIZE = 0x219E4
local SAVE_CHARACTER_HEADER_SIZE = 0x219E4
local SAVE_CHARACTER_PER_UNIT_PREFIX_SIZE = 0x10
-- kenkou: v15.5.1保存配列。版変更時はこの設定だけを最初に確認する。
local SAVE_LAYOUT = {
  profile = "v15.5.1-runtime",
  ownershipStride = 4,
  levelStride = 8,
  formStride = 4,
  ownershipLevelGap = 4,
  levelFormGap = 0,
  formAnchorValue = 2,
  formAnchorLength = 20
}
local OWNERSHIP_STRIDE = SAVE_LAYOUT.ownershipStride
local LEVEL_STRIDE = SAVE_LAYOUT.levelStride
local FORM_STRIDE = SAVE_LAYOUT.formStride
-- kenkou: 所持配列の直後に4バイトの補助値があり、形態配列との間には空きがない。
local OWNERSHIP_LEVEL_GAP = 4
local OWNERSHIP_LEVEL_GAP = SAVE_LAYOUT.ownershipLevelGap
local LEVEL_FORM_GAP = SAVE_LAYOUT.levelFormGap
local MAX_LEVEL_COMPONENT = 50000
-- 全キャラ解放済みで未所持raw値を観測できない場合に、旧スクリプトと
-- 同じ固定値を使う。ユーザーが明示的に一括削除を選んだ場合のみ使用する。
-- SAVE_DATA の候補探索用。編集入力の上限とは分け、無関係なメモリを
-- 保存配列として誤採用しないため現実的な範囲で検証する。
local SAVE_DISCOVERY_MAX_LEVEL = 1000
local SAVE_DISCOVERY_MAX_PLUS = 1000
-- v15.5.1実機では3条件すべて一致する10点の候補だけを採用する。
-- 条件が減った版は誤採用を避け、安全に停止して再解析する。
local SAVE_HEADER_REQUIRED_SCORE = 10
local UINT32_MODULUS = 4294967296
local SIGN_EQUAL = gg.SIGN_EQUAL or 536870912
local SAVE_DIAGNOSTICS_FILE_NAME = "save-resolution-debug.txt"
local FORM_AUXILIARY_DIAGNOSTICS_FILE_NAME = "form-auxiliary-debug.txt"
local FORM_ANCHOR_PATTERN = tostring(SAVE_LAYOUT.formAnchorValue)
  .. (";" .. tostring(SAVE_LAYOUT.formAnchorValue)):rep(SAVE_LAYOUT.formAnchorLength - 1)

local state = {
  rootDirectory = nil,
  dataDirectory = nil,
  fields = {},
  names = {},
  characters = {},
  characterCount = nil,
  unitTableAddress = nil,
  anchorRows = nil,
  saveBaseAddress = nil,
  saveCharacterTables = nil,
  saveDirectory = nil,
  saveIndexPath = nil,
  statusBaselines = {},
  formAuxiliaryTables = nil,
  formAuxiliaryFormStart = nil,
  formAuxiliaryReadError = nil,
  nativeObjectAddress = nil
}

local kenkouUi = {
  choicePositions = {}
}

function dirname(path)
  return path:match("^(.*)/[^/]+$")
end

function trim(value)
  return (value:gsub("^%s*(.-)%s*$", "%1"))
end

function readFile(path)
  local file, errorMessage = io.open(path, "r")
  if not file then
    return nil, errorMessage
  end
  local content = file:read("*a")
  file:close()
  return content
end

function writeFile(path, content)
  local file, errorMessage = io.open(path, "w")
  if not file then
    return nil, errorMessage
  end
  file:write(content)
  file:close()
  return true
end

function csvEscape(value)
  value = tostring(value or "")
  if value:find('[,\"\r\n]') then
    return '"' .. value:gsub('"', '""') .. '"'
  end
  return value
end

function sanitizeFilePart(value)
  value = trim(tostring(value or ""))
  value = value:gsub('[\\/:*?"<>|%c]', "_")
  value = value:gsub("%s+", " ")
  value = value:gsub("^[%. ]+", "")
  value = value:gsub("[%. ]+$", "")
  if value == "" then
    return "save"
  end
  return value:sub(1, 80)
end

function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function fileExists(path)
  local file = io.open(path, "r")
  if not file then
    return false
  end
  file:close()
  return true
end

function hasDataFiles(directory)
  return fileExists(directory .. "/units/unit000.csv")
    and fileExists(directory .. "/status-fields.csv")
    and fileExists(directory .. "/unit-index.csv")
end

function removeTrailingSlash(path)
  return (path:gsub("/+$", ""))
end

function splitCsv(line)
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

function kenkouSuspendUntilVisible()
  -- kenkou: 画面外を押したときは終了せず、GGアイコンが再度押されるまで待機する。
  gg.setVisible(false)
  -- GGのオーバーレイが閉じられた直後にsleepがInterruptedExceptionを
  -- 投げる版がある。これはユーザーの操作によるキャンセルであり、
  -- スクリプト本体の異常ではないので、Lua例外として上位へ伝播させない。
  local resumed = pcall(function()
    while not gg.isVisible() do
      gg.sleep(150)
    end
  end)
  if resumed then
    gg.setVisible(false)
  end
  return resumed
end

function kenkouSafeSleep(milliseconds)
  -- 一括書き込み中にオーバーレイ操作でsleepが中断されても、
  -- GG全体をLua例外で終了させない。
  return pcall(gg.sleep, milliseconds)
end

function kenkouChooseMenu(items, title, includeBack, positionKey)
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
    if not kenkouSuspendUntilVisible() then
      return nil
    end
  end
end

function initializePaths()
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

function ensureSaveDirectory()
  if state.saveDirectory and state.saveIndexPath then
    return true
  end
  if not state.rootDirectory then
    return nil, "スクリプトフォルダを特定できません。"
  end
  -- GameGuardianではos.executeがセキュリティ理由で無効になるため、
  -- 追加フォルダを作らずスクリプトと同じフォルダへ保存する。
  local directory = state.rootDirectory
  state.saveDirectory = directory
  state.saveIndexPath = directory .. "/status-saves-index.csv"
  if not fileExists(state.saveIndexPath) then
    local ok, errorMessage = writeFile(state.saveIndexPath,
      "filename,character_id,character_name,form_index,form_name,save_name,created_at\n")
    if not ok then
      state.saveDirectory = nil
      state.saveIndexPath = nil
      return nil, "保存一覧を作成できません: " .. tostring(errorMessage)
    end
  end
  return true
end

function loadFields()
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

function loadNamesFromIndex()
  local content, errorMessage = readFile(state.dataDirectory .. "/unit-index.csv")
  if not content then
    return nil, errorMessage
  end

  local lineNumber = 0
  local maxUnitId = -1
  for line in content:gmatch("[^\r\n]+") do
    lineNumber = lineNumber + 1
    if lineNumber > 1 then
      local columns = splitCsv(line)
      local unitId = tonumber(columns[1])
      local formIndex = tonumber(columns[2])
      local formName = trim(columns[3] or "")
      if not unitId or unitId < 0 or unitId % 1 ~= 0
        or not formIndex or formIndex < 0 or formIndex % 1 ~= 0 or formName == "" then
        return nil, string.format("unit-index.csv の%d行目が不正です。", lineNumber)
      end
      maxUnitId = math.max(maxUnitId, unitId)

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
  -- CSVの並び順に依存せず、ID 0（ネコ）を含む全キャラを昇順で表示する。
  table.sort(state.names, function(left, right) return left.id < right.id end)
  for unitId = 0, maxUnitId do
    if not state.characters[unitId] then
      return nil, string.format("unit-index.csv にunit %dがありません。キャラIDを連続させてください。", unitId)
    end
  end
  -- kenkou: 保存配列の件数は索引の最大ID+1とし、アプデ時はデータ更新だけで追従する。
  state.characterCount = maxUnitId + 1
  return true
end

function loadNames()
  return loadNamesFromIndex()
end

function loadUnitRows(character)
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

function getAnchorRows()
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

function verifyAnchorCandidate(recordAddress, anchorRows)
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

function findUnitTableAddress()
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

function kenkouGetSortedResults(limit)
  local resultCount = gg.getResultsCount()
  if resultCount == 0 then
    return {}
  end
  local results = gg.getResults(math.min(resultCount, limit or resultCount))
  table.sort(results, function(left, right) return left.address < right.address end)
  return results
end

function kenkouFormatAddress(address)
  return string.format("0x%X", tonumber(address) or 0)
end

-- kenkou: addresses.form は選択キャラ1件のレコードであり、配列先頭ではない。
-- saveId（1始まり）から現在形態配列全体の先頭へ戻してからネイティブ基準を求める。
function kenkouGetFormArrayStart(addresses)
  if not addresses or not addresses.form or not addresses.saveId then
    return nil
  end
  return addresses.form - (addresses.saveId - 1) * FORM_STRIDE
end

function kenkouWriteSaveDiagnostics(lines)
  if not state.rootDirectory then
    return nil
  end
  local filePath = state.rootDirectory .. "/" .. SAVE_DIAGNOSTICS_FILE_NAME
  local file = io.open(filePath, "w")
  if not file then
    return nil
  end
  file:write(table.concat(lines, "\n"), "\n")
  file:close()
  return filePath
end

function kenkouWriteFormAuxiliaryDiagnostics(addresses, reason)
  if not state.rootDirectory or not addresses or not addresses.form then
    return
  end
  local formArrayStart = kenkouGetFormArrayStart(addresses)
  if not formArrayStart then
    return
  end
  local nativeBase = formArrayStart - NATIVE_FORM_FIELD_OFFSET
  local lines = {
    "version=form-auxiliary-debug-v2-raw-flags",
    "reason=" .. tostring(reason or ""),
    "unit-count=" .. tostring(state.characterCount or "nil"),
    "read-error=" .. tostring(state.formAuxiliaryReadError or "nil"),
    "form-selected=" .. kenkouFormatAddress(addresses.form),
    "form-array-start=" .. kenkouFormatAddress(formArrayStart),
    "native-base=" .. kenkouFormatAddress(nativeBase),
    "unlocked-expected=" .. kenkouFormatAddress(nativeBase + NATIVE_UNLOCKED_FORMS_OFFSET),
    "fourth-expected=" .. kenkouFormatAddress(nativeBase + NATIVE_FOURTH_FORM_OFFSET)
  }
  local requests = {}
  for index = 0, 11 do
    requests[#requests + 1] = { address = nativeBase + NATIVE_UNLOCKED_FORMS_OFFSET + index * 4, flags = gg.TYPE_DWORD }
  end
  for index = 0, 5 do
    requests[#requests + 1] = { address = nativeBase + NATIVE_FOURTH_FORM_OFFSET + index * 8, flags = gg.TYPE_DWORD }
    requests[#requests + 1] = { address = nativeBase + NATIVE_FOURTH_FORM_OFFSET + index * 8 + 4, flags = gg.TYPE_DWORD }
  end
  local values = gg.getValues(requests)
  -- kenkou: この診断関数は復号関数より前に定義されるため、後段の
  -- kenkouDecodeProtectedValue（ローカル関数）を直接参照しない。
  -- ネイティブの8バイト保護値を診断用に同じ並びで復号する。
  local function kenkouDecodeAuxiliaryDiagnosticValue(encodedValue, markerValue)
    local encoded = tonumber(encodedValue)
    local marker = tonumber(markerValue)
    if not encoded or not marker then
      return nil
    end
    encoded = math.floor(encoded) % UINT32_MODULUS
    marker = math.floor(marker) % UINT32_MODULUS
    local function getByte(value, index)
      return math.floor(value / (256 ^ index)) % 256
    end
    local function xorByte(left, right)
      local result = 0
      local place = 1
      for _ = 1, 8 do
        if left % 2 ~= right % 2 then
          result = result + place
        end
        left = math.floor(left / 2)
        right = math.floor(right / 2)
        place = place * 2
      end
      return result
    end
    return xorByte(getByte(encoded, 0), getByte(marker, 3))
      + xorByte(getByte(encoded, 1), getByte(marker, 2)) * 256
      + xorByte(getByte(encoded, 2), getByte(marker, 1)) * 65536
      + xorByte(getByte(encoded, 3), getByte(marker, 0)) * 16777216
  end
  local unlocked = {}
  for index = 1, 12 do
    unlocked[#unlocked + 1] = tostring(values[index] and values[index].value or "nil")
  end
  lines[#lines + 1] = "unlocked-sample=" .. table.concat(unlocked, ",")
  local sparseIndexes = { 1, 2, 3, 4, 8, 16, 32, 64,
    math.floor((state.characterCount or 1) / 2),
    (state.characterCount or 1) - 1, state.characterCount or 1 }
  local sparseRequests = {}
  for _, index in ipairs(sparseIndexes) do
    if index >= 1 and index <= (state.characterCount or 1) then
      sparseRequests[#sparseRequests + 1] = {
        address = nativeBase + NATIVE_UNLOCKED_FORMS_OFFSET + (index - 1) * 4,
        flags = gg.TYPE_DWORD
      }
    end
  end
  local sparseValues = gg.getValues(sparseRequests)
  local sparse = {}
  for index, value in ipairs(sparseValues) do
    sparse[#sparse + 1] = string.format("%d:%s", sparseIndexes[index], tostring(value.value))
  end
  lines[#lines + 1] = "unlocked-sparse=" .. table.concat(sparse, ",")
  -- kenkou: 873要素配列の候補を比較する。静的オフセットだけでは
  -- 形態配列と別の同長配列を取り違えるため、読み取り専用で値の分布を残す。
  local candidateArrays = {
    { name = "candidate-335150", offset = 0x335150 },
    { name = "candidate-335ef4", offset = 0x335EF4 },
    { name = "candidate-336c98", offset = 0x336C98 },
    { name = "candidate-33438c", offset = 0x33438C },
    { name = "candidate-3335e8", offset = 0x3335E8 }
  }
  local candidateIndexes = { 1, 2, 3, 4, 8, 16, 32, 64,
    math.floor((state.characterCount or 1) / 2),
    (state.characterCount or 1) - 1, state.characterCount or 1 }
  for _, candidate in ipairs(candidateArrays) do
    local candidateRequests = {}
    for _, index in ipairs(candidateIndexes) do
      if index >= 1 and index <= (state.characterCount or 1) then
        candidateRequests[#candidateRequests + 1] = {
          address = nativeBase + candidate.offset + (index - 1) * 4,
          flags = gg.TYPE_DWORD
        }
      end
    end
    local candidateValues = gg.getValues(candidateRequests)
    local candidateSample = {}
    for index, value in ipairs(candidateValues) do
      candidateSample[#candidateSample + 1] = string.format(
        "%d:%s", candidateIndexes[index], tostring(value.value))
    end
    lines[#lines + 1] = candidate.name .. "=" .. table.concat(candidateSample, ",")
  end
  -- kenkou: 検索式は使わず、候補配列の全件分布を記録する。
  local function writeCandidateStats(name, valuesToSummarize)
    local zeroCount, oneCount, twoCount, threeCount = 0, 0, 0, 0
    local minValue, maxValue, uniqueCount = nil, nil, 0
    local seenValues = {}
    for _, value in ipairs(valuesToSummarize) do
      local number = tonumber(value.value)
      if number then
        if number == 0 then zeroCount = zeroCount + 1 end
        if number == 1 then oneCount = oneCount + 1 end
        if number == 2 then twoCount = twoCount + 1 end
        if number == 3 then threeCount = threeCount + 1 end
        if minValue == nil or number < minValue then minValue = number end
        if maxValue == nil or number > maxValue then maxValue = number end
        if not seenValues[number] then
          seenValues[number] = true
          uniqueCount = uniqueCount + 1
        end
      end
    end
    lines[#lines + 1] = string.format(
      "%s-stats=count=%d,zero=%d,one=%d,two=%d,three=%d,min=%s,max=%s,unique=%d",
      name, #valuesToSummarize, zeroCount, oneCount, twoCount, threeCount,
      tostring(minValue), tostring(maxValue), uniqueCount
    )
  end
  for _, candidate in ipairs(candidateArrays) do
    local candidateRequests = {}
    for index = 0, (state.characterCount or 0) - 1 do
      candidateRequests[#candidateRequests + 1] = {
        address = nativeBase + candidate.offset + index * 4,
        flags = gg.TYPE_DWORD
      }
    end
    writeCandidateStats(candidate.name, gg.getValues(candidateRequests))
  end
  local fourthRequests = {}
  for index = 0, (state.characterCount or 0) - 1 do
    fourthRequests[#fourthRequests + 1] = {
      address = nativeBase + NATIVE_FOURTH_FORM_OFFSET + index * 8,
      flags = gg.TYPE_DWORD
    }
    fourthRequests[#fourthRequests + 1] = {
      address = nativeBase + NATIVE_FOURTH_FORM_OFFSET + index * 8 + 4,
      flags = gg.TYPE_DWORD
    }
  end
  local fourthAllValues = gg.getValues(fourthRequests)
  local fourthDecodedValues = {}
  for index = 1, math.floor(#fourthAllValues / 2) do
    local encoded = fourthAllValues[index * 2 - 1]
    local marker = fourthAllValues[index * 2]
    local decoded = encoded and marker
      and kenkouDecodeAuxiliaryDiagnosticValue(encoded.value, marker.value)
    if decoded ~= nil then
      fourthDecodedValues[#fourthDecodedValues + 1] = { value = decoded }
    end
  end
  writeCandidateStats("fourth-encoded-dword", fourthAllValues)
  writeCandidateStats("fourth-decoded", fourthDecodedValues)
  local fourthDwordRequests = {}
  for index = 0, 7 do
    fourthDwordRequests[#fourthDwordRequests + 1] = {
      address = nativeBase + NATIVE_FOURTH_FORM_OFFSET + index * 4,
      flags = gg.TYPE_DWORD
    }
  end
  local fourthDwordValues = gg.getValues(fourthDwordRequests)
  local fourthDwordSample = {}
  for index, value in ipairs(fourthDwordValues) do
    fourthDwordSample[#fourthDwordSample + 1] = tostring(value.value)
  end
  lines[#lines + 1] = "fourth-dword-sample=" .. table.concat(fourthDwordSample, ",")
  -- kenkou: 静的候補が別の配列を指す場合に備え、保存オブジェクト全体を
  -- 64要素の状態列として読み取り専用で探索する。
  local function writeAuxiliaryPatternDiagnostics(name, pattern)
    gg.clearResults()
    -- kenkou: 検索式の解釈はGGの版によって例外になることがあるため、
    -- ここでは診断を止めず、エラー内容もログに残す。
    lines[#lines + 1] = name .. "-pattern-length=" .. tostring(#pattern)
    local ok, searchError = pcall(function()
      gg.searchNumber(pattern, gg.TYPE_DWORD, false, SIGN_EQUAL,
        nativeBase + 0x20000, nativeBase + 0x400000)
    end)
    if not ok then
      lines[#lines + 1] = name .. "-error=" .. tostring(searchError)
      gg.clearResults()
      return
    end
    local count = 0
    local countOk, countError = pcall(function()
      count = gg.getResultsCount()
    end)
    if not countOk then
      lines[#lines + 1] = name .. "-error=" .. tostring(countError)
      gg.clearResults()
      return
    end
    local entries = {}
    if count > 0 then
      local results = gg.getResults(math.min(count, 16))
      for _, result in ipairs(results) do
        entries[#entries + 1] = kenkouFormatAddress(result.address)
          .. "(offset=0x" .. string.format("%X", result.address - nativeBase) .. ")"
      end
    end
    lines[#lines + 1] = name .. "-count=" .. tostring(count)
    lines[#lines + 1] = name .. "-addresses=" .. table.concat(entries, ",")
    gg.clearResults()
  end
  -- GGの範囲指定は min~~max。単純な0～3/0～2の連続配列を探す。
  -- kenkou: パターン検索は巨大な誤検出を生むため、統計診断に置き換える。
  local fourth = {}
  for index = 1, 6 do
    local encoded = values[12 + index * 2 - 1]
    local marker = values[12 + index * 2]
    fourth[#fourth + 1] = tostring(encoded and marker
      and kenkouDecodeAuxiliaryDiagnosticValue(encoded.value, marker.value) or "nil")
  end
  lines[#lines + 1] = "fourth-decoded-sample=" .. table.concat(fourth, ",")
  local file = io.open(state.rootDirectory .. "/" .. FORM_AUXILIARY_DIAGNOSTICS_FILE_NAME, "w")
  if file then
    file:write(table.concat(lines, "\n"), "\n")
    file:close()
  end
end

function kenkouWriteFormOperationDiagnostics(lines)
  if not state.rootDirectory then
    return
  end
  local file = io.open(state.rootDirectory .. "/form-operation-debug.txt", "w")
  if file then
    file:write(table.concat(lines, "\n"), "\n")
    file:close()
  end
end

function kenkouVerifySaveBaseCandidate(address)
  gg.clearResults()
  local pattern = ("-256~255;"):rep(2) .. ("-257~~256;"):rep(2) .. "-256~255;-256~255::21"
  gg.searchNumber(pattern, gg.TYPE_DWORD, false, SIGN_EQUAL, address, address + 0x120)
  local valid = gg.getResultsCount() == 6
  gg.clearResults()
  return valid
end

function kenkouResolveSaveBaseAddress()
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
  -- kenkou: split がない端末でも C_BSS だけを対象にする。匿名領域全体を
  -- 検索すると timezone アンカーの初期探索が不必要に遅くなる。
  gg.setRanges(splitRange and -2080896 or gg.REGION_C_BSS)
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

function kenkouBuildDwordRecords(startAddress, count, stride)
  stride = stride or 4
  local records = {}
  for index = 0, count - 1 do
    records[#records + 1] = {
      address = startAddress + index * stride,
      flags = gg.TYPE_DWORD
    }
  end
  return records
end

function kenkouBuildSaveCharacterTables(ownershipStart, unitCount)
  local levelStart = ownershipStart + unitCount * OWNERSHIP_STRIDE + OWNERSHIP_LEVEL_GAP
  local formStart = levelStart + unitCount * LEVEL_STRIDE + LEVEL_FORM_GAP
  return {
    ownership = kenkouBuildDwordRecords(ownershipStart, unitCount, OWNERSHIP_STRIDE),
    level = kenkouBuildDwordRecords(levelStart, unitCount * 2, LEVEL_STRIDE / 2),
    form = kenkouBuildDwordRecords(formStart, unitCount, FORM_STRIDE),
    unitCount = unitCount
  }
end

function kenkouGetExpectedOwnershipStart(saveBaseAddress, unitCount)
  -- kenkou: 配列先頭 = 保存基準 + 固定ヘッダー + 1ユニットにつき16バイトの可変領域。
  return saveBaseAddress + SAVE_CHARACTER_HEADER_SIZE + unitCount * SAVE_CHARACTER_PER_UNIT_PREFIX_SIZE
end

function kenkouToUnsignedDword(value)
  value = tonumber(value)
  if not value then
    return nil
  end
  value = math.floor(value) % UINT32_MODULUS
  if value < 0 then
    value = value + UINT32_MODULUS
  end
  return value
end

function kenkouToSignedDword(value)
  value = kenkouToUnsignedDword(value)
  if not value then
    return nil
  end
  if value >= 2147483648 then
    return value - UINT32_MODULUS
  end
  return value
end

function kenkouGetDwordByte(value, byteIndex)
  return math.floor(value / (256 ^ byteIndex)) % 256
end

function kenkouXorByte(left, right)
  local result = 0
  local place = 1
  for _ = 1, 8 do
    if left % 2 ~= right % 2 then
      result = result + place
    end
    left = math.floor(left / 2)
    right = math.floor(right / 2)
    place = place * 2
  end
  return result
end

-- kenkou: LuaJ のビット演算依存を避け、DWORD をバイト単位で XOR する。
-- 所有状態は `raw XOR ownershipKey` で復号されるため、符号付き値のまま
-- 比較・書き込みをするとキャラIDごとの値を取り違える。
function kenkouXorDword(left, right)
  local leftValue = kenkouToUnsignedDword(left)
  local rightValue = kenkouToUnsignedDword(right)
  if leftValue == nil or rightValue == nil then
    return nil
  end
  local result = 0
  for byteIndex = 0, 3 do
    result = result + kenkouXorByte(
      kenkouGetDwordByte(leftValue, byteIndex),
      kenkouGetDwordByte(rightValue, byteIndex)
    ) * (256 ^ byteIndex)
  end
  return result
end

function kenkouGetOwnedOwnershipValue(ownershipKey, characterId)
  -- kenkou: 現行 SAVE_DATA の所有状態はID表ではなく、復号値0/1のフラグ。
  -- characterId は旧呼出元との互換のため受け取るが、エンコードには使わない。
  local encoded = kenkouXorDword(ownershipKey, 1)
  return kenkouToSignedDword(encoded)
end

function kenkouGetUnownedOwnershipValue(ownershipKey)
  local encoded = kenkouXorDword(ownershipKey, 0)
  return kenkouToSignedDword(encoded)
end

function kenkouIsCharacterOwned(rawValue, ownershipKey, characterId)
  local decoded = kenkouXorDword(rawValue, ownershipKey)
  return decoded ~= nil and decoded == 1
end

function kenkouDecodeLevel(levelValue, markerValue)
  local encoded = kenkouToUnsignedDword(levelValue)
  local marker = kenkouToUnsignedDword(markerValue)
  if not encoded or not marker then
    return nil, nil
  end

  -- kenkou: 8バイト保護値をネイティブFUN_007ae66cと同じ並びで復号する。
  local packed = kenkouXorByte(kenkouGetDwordByte(encoded, 0), kenkouGetDwordByte(marker, 3))
    + kenkouXorByte(kenkouGetDwordByte(encoded, 1), kenkouGetDwordByte(marker, 2)) * 256
    + kenkouXorByte(kenkouGetDwordByte(encoded, 2), kenkouGetDwordByte(marker, 1)) * 65536
    + kenkouXorByte(kenkouGetDwordByte(encoded, 3), kenkouGetDwordByte(marker, 0)) * 16777216
  return math.floor(packed / 65536) + 1, packed % 65536
end

function kenkouDecodeProtectedValue(encodedValue, markerValue)
  local encoded = kenkouToUnsignedDword(encodedValue)
  local marker = kenkouToUnsignedDword(markerValue)
  if not encoded or not marker then
    return nil
  end
  return kenkouXorByte(kenkouGetDwordByte(encoded, 0), kenkouGetDwordByte(marker, 3))
    + kenkouXorByte(kenkouGetDwordByte(encoded, 1), kenkouGetDwordByte(marker, 2)) * 256
    + kenkouXorByte(kenkouGetDwordByte(encoded, 2), kenkouGetDwordByte(marker, 1)) * 65536
    + kenkouXorByte(kenkouGetDwordByte(encoded, 3), kenkouGetDwordByte(marker, 0)) * 16777216
end

function kenkouEncodeProtectedValue(value, markerValue)
  local marker = kenkouToUnsignedDword(markerValue)
  local packed = kenkouToUnsignedDword(value)
  if not marker or not packed then
    return nil
  end
  local byte0 = kenkouXorByte(kenkouGetDwordByte(packed, 0), kenkouGetDwordByte(marker, 3))
  local byte1 = kenkouXorByte(kenkouGetDwordByte(packed, 1), kenkouGetDwordByte(marker, 2))
  local byte2 = kenkouXorByte(kenkouGetDwordByte(packed, 2), kenkouGetDwordByte(marker, 1))
  local byte3 = kenkouXorByte(kenkouGetDwordByte(packed, 3), kenkouGetDwordByte(marker, 0))
  return kenkouToSignedDword(byte0 + byte1 * 256 + byte2 * 65536 + byte3 * 16777216)
end

function kenkouEncodeLevel(level, plus, markerValue)
  local marker = kenkouToUnsignedDword(markerValue)
  if not marker then
    return nil, nil
  end
  local packed = (level - 1) * 65536 + plus
  local byte0 = kenkouXorByte(kenkouGetDwordByte(packed, 0), kenkouGetDwordByte(marker, 3))
  local byte1 = kenkouXorByte(kenkouGetDwordByte(packed, 1), kenkouGetDwordByte(marker, 2))
  local byte2 = kenkouXorByte(kenkouGetDwordByte(packed, 2), kenkouGetDwordByte(marker, 1))
  local byte3 = kenkouXorByte(kenkouGetDwordByte(packed, 3), kenkouGetDwordByte(marker, 0))
  local encoded = byte0 + byte1 * 256 + byte2 * 65536 + byte3 * 16777216
  return kenkouToSignedDword(encoded), kenkouToSignedDword(marker)
end

-- 後段で定義するSAVE_DATA解決関数の前方宣言。診断メニューから先に参照する。
local kenkouResolveSaveCharacterTables

function kenkouGetNativeObjectAddress(tables)
  if tables and tables.nativeObject then
    return tables.nativeObject
  end
  if state.nativeObjectAddress then
    return state.nativeObjectAddress
  end
  return nil
end

function kenkouBuildFacilityRecordsAtStart(startAddress)
  if not startAddress then
    return nil
  end
  local records = {}
  for _, skillIndex in ipairs(FACILITY_SKILL_INDICES) do
    local address = startAddress + skillIndex * NATIVE_SAVE_FACILITY_STRIDE
    records[#records + 1] = {
      index = skillIndex,
      name = FACILITY_NAMES[skillIndex] or ("施設スキル" .. tostring(skillIndex)),
      value = { address = address, flags = gg.TYPE_DWORD },
      marker = { address = address + 4, flags = gg.TYPE_DWORD }
    }
  end
  return records
end

function kenkouReadFacilityBlock(startAddress, maxLevel, maxPlus, requireDenseMasks)
  local requests = {}
  for index = 0, NATIVE_SAVE_FACILITY_COUNT - 1 do
    local address = startAddress + index * NATIVE_SAVE_FACILITY_STRIDE
    requests[#requests + 1] = { address = address, flags = gg.TYPE_DWORD }
    requests[#requests + 1] = { address = address + 4, flags = gg.TYPE_DWORD }
  end
  local values = gg.getValues(requests)
  if #values ~= #requests then
    return nil, string.format("読み取り件数=%d/%d", #values, #requests)
  end
  local decoded = {}
  local nonZeroMasks = 0
  for index = 0, NATIVE_SAVE_FACILITY_COUNT - 1 do
    local value = values[index * 2 + 1] and values[index * 2 + 1].value
    local marker = values[index * 2 + 2] and values[index * 2 + 2].value
    local level, plus = kenkouDecodeLevel(value, marker)
    if not level or level < 1 or level > (maxLevel or MAX_LEVEL_COMPONENT + 1)
      or plus == nil or plus < 0 or plus > (maxPlus or MAX_LEVEL_COMPONENT) then
      return nil, string.format("index=%d,level=%s,plus=%s", index, tostring(level), tostring(plus))
    end
    if tonumber(marker) ~= 0 then
      nonZeroMasks = nonZeroMasks + 1
    end
    decoded[index] = {
      index = index,
      value = value,
      marker = marker,
      level = level,
      plus = plus
    }
  end
  -- 探索候補では保護値のマスクがほぼ全て0の領域を除外する。
  -- 既知のSAVE_DATA固定位置を読む場合は、マスク0も有効値になり得るため
  -- 呼び出し側が明示的に緩和できるようにする。
  if requireDenseMasks ~= false and nonZeroMasks < NATIVE_SAVE_FACILITY_COUNT - 2 then
    return nil, "mask-sparse"
  end
  local facilities = {}
  for _, skillIndex in ipairs(FACILITY_SKILL_INDICES) do
    local item = decoded[skillIndex]
    local address = startAddress + skillIndex * NATIVE_SAVE_FACILITY_STRIDE
    facilities[#facilities + 1] = {
      index = skillIndex,
      name = FACILITY_NAMES[skillIndex] or ("施設スキル" .. tostring(skillIndex)),
      address = address,
      markerAddress = address + 4,
      level = item.level,
      plus = item.plus,
      encoded = item.value,
      marker = item.marker
    }
  end
  return { facilities = facilities, decoded = decoded }
end

function kenkouFindFacilityStart(formStart, expectedStart)
  if not formStart then
    return nil, "form-start-missing"
  end
  local expectedRelative = (expectedStart or (formStart + 0xDA4)) - formStart
  local firstRelative = expectedRelative - FACILITY_RELATIVE_SCAN_RADIUS
  local lastRelative = expectedRelative + FACILITY_RELATIVE_SCAN_RADIUS
  local batch = FACILITY_RELATIVE_SCAN_BATCH
  local relative = firstRelative
  local foundAddress = nil
  local foundCount = 0
  while relative <= lastRelative do
    local count = math.min(batch, math.floor((lastRelative - relative) / 4) + 1)
    local requests = {}
    for candidateIndex = 0, count - 1 do
      local startAddress = formStart + relative + candidateIndex * 4
      for valueIndex = 0, NATIVE_SAVE_FACILITY_COUNT - 1 do
        local address = startAddress + valueIndex * NATIVE_SAVE_FACILITY_STRIDE
        requests[#requests + 1] = { address = address, flags = gg.TYPE_DWORD }
        requests[#requests + 1] = { address = address + 4, flags = gg.TYPE_DWORD }
      end
    end
    local values = gg.getValues(requests)
    if #values == #requests then
      for candidateIndex = 0, count - 1 do
        local decoded = {}
        local valid = true
        local nonZeroMasks = 0
        for valueIndex = 0, NATIVE_SAVE_FACILITY_COUNT - 1 do
          local offset = candidateIndex * NATIVE_SAVE_FACILITY_COUNT * 2 + valueIndex * 2
          local value = values[offset + 1] and values[offset + 1].value
          local marker = values[offset + 2] and values[offset + 2].value
          local level, plus = kenkouDecodeLevel(value, marker)
          if not level or level < 1 or level > FACILITY_DISCOVERY_MAX_LEVEL
            or plus == nil or plus < 0 or plus > FACILITY_DISCOVERY_MAX_PLUS then
            valid = false
            break
          end
          if tonumber(marker) ~= 0 then
            nonZeroMasks = nonZeroMasks + 1
          end
          decoded[valueIndex] = { value = value, marker = marker, level = level, plus = plus }
        end
        if valid and nonZeroMasks >= NATIVE_SAVE_FACILITY_COUNT - 2 then
          foundAddress = formStart + relative + candidateIndex * 4
          foundCount = foundCount + 1
          if foundCount > 1 then
            return nil, "relative-scan-ambiguous"
          end
        end
      end
    end
    relative = relative + count * 4
  end
  if foundAddress then
    return foundAddress, "relative-scan"
  end
  return nil, "relative-scan-not-found"
end

local kenkouWriteFacilityFailureDiagnostics

function kenkouReadFacilities(tables)
  local nativeObject = kenkouGetNativeObjectAddress(tables)
  local formStart = tables and tables.form and tables.form[1] and tables.form[1].address
  if not formStart then
    return nil, "SAVE_DATAの形態配列を取得できません。"
  end
  local expectedStart = nativeObject and (nativeObject + NATIVE_SAVE_FACILITY_OFFSET)
    or (formStart + (NATIVE_SAVE_FACILITY_OFFSET - NATIVE_SAVE_FORM_OFFSET))
  -- 現行版の固定候補をまず検証する。通常はこちらで高速に完了する。
  -- 固定候補も探索時と同じ現実的な上限で検証し、誤ったヒープ領域を
  -- 「復号できた」と誤採用しない。
  local block, fixedError = kenkouReadFacilityBlock(
    expectedStart, FACILITY_DISCOVERY_MAX_LEVEL, FACILITY_DISCOVERY_MAX_PLUS
  )
  local startAddress = expectedStart
  local method = "fixed-relative"
  local relaxedError = nil
  if not block then
    -- 固定相対位置はネイティブ解析で確認済み。実際の上限が探索用上限を
    -- 超えた場合やマスクが0の枠がある場合は、位置を変えずに編集上限で
    -- 再確認する。ここでも復号不能・非整数値は拒否する。
    block = kenkouReadFacilityBlock(
      expectedStart, MAX_LEVEL_COMPONENT + 1, MAX_LEVEL_COMPONENT, false
    )
    if block then
      method = "fixed-relative-relaxed"
    else
      relaxedError = "fixed-relaxed-read-failed"
    end
  end
  if not block then
    startAddress, method = kenkouFindFacilityStart(formStart, expectedStart)
    if not startAddress then
      kenkouWriteFacilityFailureDiagnostics(nativeObject, formStart, expectedStart,
        fixedError, relaxedError, method)
      return nil, string.format("施設配列を特定できません（固定候補:%s、緩和候補:%s、探索:%s）。",
        tostring(fixedError), tostring(relaxedError), tostring(method))
    end
    block = kenkouReadFacilityBlock(startAddress, MAX_LEVEL_COMPONENT + 1, MAX_LEVEL_COMPONENT)
    if not block then
      return nil, "施設配列の再確認に失敗しました。"
    end
  end
  return {
    nativeObject = nativeObject,
    startAddress = startAddress,
    method = method,
    facilities = block.facilities
  }
end

function kenkouWriteFacilityDiagnostics(result)
  if not state.rootDirectory or not result then
    return
  end
  local lines = {
    "version=facility-resolution-v2",
    "method=" .. tostring(result.method or "unknown"),
    "native-object=" .. kenkouFormatAddress(result.nativeObject),
    "facility-start=" .. kenkouFormatAddress(result.startAddress),
    "stride=" .. tostring(NATIVE_SAVE_FACILITY_STRIDE),
    "internal-count=" .. tostring(NATIVE_SAVE_FACILITY_COUNT),
    "valid-skill-indices=" .. table.concat(FACILITY_SKILL_INDICES, ",")
  }
  for _, facility in ipairs(result.facilities) do
    lines[#lines + 1] = string.format(
      "index=%d,name=%s,address=%s,marker=%s,level=%d,plus=%d,encoded=%s,mask=%s",
      facility.index, facility.name, kenkouFormatAddress(facility.address),
      kenkouFormatAddress(facility.markerAddress), facility.level, facility.plus,
      tostring(facility.encoded), tostring(facility.marker))
  end
  writeFile(state.rootDirectory .. "/facility-resolution-debug.txt", table.concat(lines, "\n") .. "\n")
end

kenkouWriteFacilityFailureDiagnostics = function(nativeObject, formStart, expectedStart,
  fixedError, relaxedError, scanError)
  if not state.rootDirectory then
    return
  end
  local lines = {
    "version=facility-resolution-failure-v1",
    "native-object=" .. kenkouFormatAddress(nativeObject),
    "form-start=" .. kenkouFormatAddress(formStart),
    "expected-start=" .. kenkouFormatAddress(expectedStart),
    "fixed-strict=" .. tostring(fixedError or "nil"),
    "fixed-relaxed=" .. tostring(relaxedError or "nil"),
    "relative-scan=" .. tostring(scanError or "nil")
  }
  writeFile(state.rootDirectory .. "/facility-resolution-debug.txt", table.concat(lines, "\n") .. "\n")
end

function kenkouInspectFacilities()
  local tables, errorMessage = kenkouResolveSaveCharacterTables()
  if not tables then
    gg.alert(errorMessage or "キャラ保存配列を先に確認できません。")
    return
  end
  local result, facilityError = kenkouReadFacilities(tables)
  if not result then
    gg.alert(facilityError or "施設配列を確認できません。")
    return
  end
  kenkouWriteFacilityDiagnostics(result)
  local lines = { "施設レベル診断", "開始: " .. kenkouFormatAddress(result.startAddress) }
  for _, facility in ipairs(result.facilities) do
    lines[#lines + 1] = string.format("%s: Lv%d +%d", facility.name, facility.level, facility.plus)
  end
  gg.alert(table.concat(lines, "\n"))
end

function kenkouSelectFacilities(result)
  local prompts, defaults, types = {}, {}, {}
  for _, facility in ipairs(result.facilities) do
    prompts[#prompts + 1] = string.format(
      "%s（Lv%d＋%d）",
      facility.name,
      math.floor(tonumber(facility.level) or 0),
      math.floor(tonumber(facility.plus) or 0)
    )
    defaults[#defaults + 1] = false
    types[#types + 1] = "checkbox"
  end
  prompts[#prompts + 1] = "全て"
  defaults[#defaults + 1] = false
  types[#types + 1] = "checkbox"

  local input = gg.prompt(prompts, defaults, types)
  if not input then
    kenkouSuspendUntilVisible()
    return nil
  end

  local selected = {}
  local selectAll = input[#result.facilities + 1] == true
  for index, facility in ipairs(result.facilities) do
    if selectAll or input[index] == true then
      selected[#selected + 1] = facility
    end
  end
  if #selected == 0 then
    gg.alert("変更する施設を1つ以上選択してください。")
    return nil
  end
  return selected
end

function kenkouPromptFacilityUpgrade(selected)
  local first = selected[1]
  local input = gg.prompt(
    { "レベル（選択した施設へ一括適用）", "プラス値（選択した施設へ一括適用）" },
    {
      string.format("%d", math.floor(tonumber(first.level) or 1)),
      string.format("%d", math.floor(tonumber(first.plus) or 0))
    },
    { "number", "number" }
  )
  if not input then
    kenkouSuspendUntilVisible()
    return nil
  end
  local level = tonumber(input[1])
  local plus = tonumber(input[2])
  if not level or level % 1 ~= 0 or level < 1 or level - 1 > MAX_LEVEL_COMPONENT then
    gg.alert(string.format("レベルは1〜%dの整数で入力してください。", MAX_LEVEL_COMPONENT + 1))
    return nil
  end
  if not plus or plus % 1 ~= 0 or plus < 0 or plus > MAX_LEVEL_COMPONENT then
    gg.alert(string.format("プラス値は0〜%dの整数で入力してください。", MAX_LEVEL_COMPONENT))
    return nil
  end
  return level, plus
end

function kenkouWriteFacilities(result, selected, level, plus)
  local selectedIndexes = {}
  for _, facility in ipairs(selected) do
    selectedIndexes[facility.index] = true
  end
  -- index=0（にゃんこ砲攻撃力）は、ネイティブ側の内部ミラー index=1 も同期する。
  if selectedIndexes[0] then
    selectedIndexes[1] = true
  end

  local writes, targets = {}, {}
  local facilityStart = result.startAddress
  if not facilityStart then
    return nil, "施設配列の開始アドレスがありません。"
  end
  for index = 0, NATIVE_SAVE_FACILITY_COUNT - 1 do
    if selectedIndexes[index] then
      local address = facilityStart + index * NATIVE_SAVE_FACILITY_STRIDE
      local current = gg.getValues({
        { address = address, flags = gg.TYPE_DWORD },
        { address = address + 4, flags = gg.TYPE_DWORD }
      })
      if not current[1] or not current[2] then
        return nil, string.format("施設内部index=%dの現在値を読み取れません。", index)
      end
      local encodedValue, markerValue = kenkouEncodeLevel(level, plus, current[2].value)
      if encodedValue == nil or markerValue == nil then
        return nil, string.format("施設内部index=%dをエンコードできません。", index)
      end
      writes[#writes + 1] = {
        address = address,
        flags = gg.TYPE_DWORD,
        value = encodedValue,
        name = string.format("施設内部index=%d レベル", index)
      }
      writes[#writes + 1] = {
        address = address + 4,
        flags = gg.TYPE_DWORD,
        value = markerValue,
        name = string.format("施設内部index=%d マスク", index)
      }
      targets[#targets + 1] = {
        index = index,
        address = address,
        encoded = encodedValue,
        marker = markerValue
      }
    end
  end

  if #writes == 0 then
    return nil, "変更対象がありません。"
  end
  gg.setValues(writes)
  kenkouSafeSleep(80)
  local requests = {}
  for _, target in ipairs(targets) do
    requests[#requests + 1] = { address = target.address, flags = gg.TYPE_DWORD }
    requests[#requests + 1] = { address = target.address + 4, flags = gg.TYPE_DWORD }
  end
  local verified = gg.getValues(requests)
  if #verified ~= #requests then
    return nil, string.format("施設変更後の確認件数が不一致です（%d/%d）。", #verified, #requests)
  end
  for index, target in ipairs(targets) do
    local encoded = verified[index * 2 - 1] and verified[index * 2 - 1].value
    local marker = verified[index * 2] and verified[index * 2].value
    local verifiedLevel, verifiedPlus = kenkouDecodeLevel(encoded, marker)
    if verifiedLevel ~= level or verifiedPlus ~= plus then
      return nil, string.format(
        "施設内部index=%dの確認値が一致しません（Lv%s＋%s）。",
        target.index, tostring(verifiedLevel), tostring(verifiedPlus)
      )
    end
  end
  return true
end

function kenkouOpenFacilityEditor()
  local tables, errorMessage = kenkouResolveSaveCharacterTables()
  if not tables then
    gg.alert(errorMessage or "キャラ保存配列を先に確認できません。")
    return
  end
  local result, facilityError = kenkouReadFacilities(tables)
  if not result then
    gg.alert(facilityError or "施設配列を確認できません。")
    return
  end
  kenkouWriteFacilityDiagnostics(result)
  local selected = kenkouSelectFacilities(result)
  if not selected then
    return
  end
  local level, plus = kenkouPromptFacilityUpgrade(selected)
  if not level then
    return
  end
  local names = {}
  for _, facility in ipairs(selected) do
    names[#names + 1] = facility.name
  end
  local confirmation = gg.alert(
    table.concat(names, "、") .. string.format("\nをレベル%d＋%dへ変更しますか？", level, plus),
    "はい", "いいえ"
  )
  if confirmation ~= 1 then
    return
  end
  local success, writeError = kenkouWriteFacilities(result, selected, level, plus)
  if not success then
    gg.alert(writeError or "施設レベルの書き換えに失敗しました。")
    return
  end
  gg.toast(string.format("施設%d件をレベル%d＋%dへ変更しました。", #selected, level, plus))
end

function kenkouGetValidationIndexes(unitCount)
  local indexes = {}
  local seen = {}
  local candidates = {
    1, 2, 3, 4, 8, 16, 32, 64, 128,
    math.floor(unitCount / 3), math.floor(unitCount / 2), math.floor(unitCount * 2 / 3),
    unitCount - 2, unitCount - 1, unitCount
  }
  for _, index in ipairs(candidates) do
    index = math.max(1, math.min(unitCount, index))
    if not seen[index] then
      seen[index] = true
      indexes[#indexes + 1] = index
    end
  end
  return indexes
end

function kenkouValidateSaveCharacterTables(tables)
  local unitCount = tables.unitCount
  if unitCount < 32 or unitCount > 4096 then
    return false, "unit-count"
  end
  if #tables.ownership ~= unitCount or #tables.level ~= unitCount * 2
    or #tables.form ~= unitCount then
    return false, "record-count"
  end

  local ownershipStart = tables.ownership[1].address
  local expectedLevelStart = ownershipStart + unitCount * OWNERSHIP_STRIDE + OWNERSHIP_LEVEL_GAP
  local expectedFormStart = expectedLevelStart + unitCount * LEVEL_STRIDE + LEVEL_FORM_GAP
  if tables.level[1].address ~= expectedLevelStart or tables.form[1].address ~= expectedFormStart then
    return false, "array-layout"
  end

  -- kenkou: 離れたIDを読み、保護レベル・形態が同時に妥当な候補だけを採用する。
  -- 所持値は実行時に保護され、平文0/1の範囲チェックを適用できない。
  local requests = {}
  local validationIndexes = kenkouGetValidationIndexes(unitCount)
  for _, saveId in ipairs(validationIndexes) do
    requests[#requests + 1] = tables.ownership[saveId]
    requests[#requests + 1] = tables.level[saveId * 2 - 1]
    requests[#requests + 1] = tables.level[saveId * 2]
    requests[#requests + 1] = tables.form[saveId]
  end
  local values = gg.getValues(requests)
  local nonZeroOwnership = 0
  for index = 1, #validationIndexes do
    local offset = (index - 1) * 4
    local ownership = values[offset + 1] and tonumber(values[offset + 1].value)
    local levelValue = values[offset + 2] and values[offset + 2].value
    local markerValue = values[offset + 3] and values[offset + 3].value
    local form = values[offset + 4] and tonumber(values[offset + 4].value)
    -- current-form は native の保存配列で 0..3 の整数。-1 や 10 を許すと
    -- 無関係なメモリ領域を保存配列として採用してしまう。
    if ownership == nil or not form or form < 0 or form > 3 or form % 1 ~= 0 then
      return false, string.format("value-range:id=%d,owner=%s,form=%s", validationIndexes[index],
        tostring(ownership), tostring(form))
    end
    if ownership ~= 0 then
      nonZeroOwnership = nonZeroOwnership + 1
    end
    local level, plus = kenkouDecodeLevel(levelValue, markerValue)
    if not level or level < 1 or level > SAVE_DISCOVERY_MAX_LEVEL
      or not plus or plus < 0 or plus > SAVE_DISCOVERY_MAX_PLUS then
      return false, string.format("level-decode:id=%d,level=%s,plus=%s", validationIndexes[index],
        tostring(level), tostring(plus))
    end
  end
  -- 無関係なメモリでは所有状態もゼロ列になりやすい。基本キャラの保存列を
  -- 採用するため、検証点に少なくとも1つの所有値が必要。
  if nonZeroOwnership == 0 then
    return false, "ownership-all-zero"
  end
  return true, "ok"
end

function kenkouValidateSaveCharacterInitialRows(tables)
  -- kenkou: フォームの連続値から見つけた候補は、配列末尾側の予約領域を含む完全検証では
  -- 判定不能な場合がある。初期キャラ群の実行時レコードで位置を確認する。
  local requests = {}
  for saveId = 1, 9 do
    requests[#requests + 1] = tables.ownership[saveId]
    requests[#requests + 1] = tables.level[saveId * 2 - 1]
    requests[#requests + 1] = tables.level[saveId * 2]
    requests[#requests + 1] = tables.form[saveId]
  end
  local values = gg.getValues(requests)
  local firstOwnership = values[1] and tonumber(values[1].value)
  if firstOwnership == nil or firstOwnership == 0 then
    return false, "initial-owner"
  end
  for index = 0, 8 do
    local offset = index * 4
    local ownership = values[offset + 1] and tonumber(values[offset + 1].value)
    local levelValue = values[offset + 2] and values[offset + 2].value
    local markerValue = values[offset + 3] and values[offset + 3].value
    local form = values[offset + 4] and tonumber(values[offset + 4].value)
    if ownership == nil or ownership ~= firstOwnership or not form or form < 0 or form > 3
      or form % 1 ~= 0 then
      return false, string.format("initial-value:id=%d", index + 1)
    end
    local level, plus = kenkouDecodeLevel(levelValue, markerValue)
    if not level or level < 1 or level > SAVE_DISCOVERY_MAX_LEVEL
      or not plus or plus < 0 or plus > SAVE_DISCOVERY_MAX_PLUS then
      return false, string.format("initial-level:id=%d", index + 1)
    end
  end
  return true, "initial-ok"
end

function kenkouScoreSaveArrayHeaders(tables)
  if not tables or not tables.ownership or not tables.level or not tables.form
    or not tables.ownership[1] or not tables.level[1] or not tables.form[1] then
    return -1, "header-record-missing"
  end
  local firstOwner = gg.getValues({ tables.ownership[1] })[1]
  local headers = gg.getValues({
    { address = tables.ownership[1].address - OWNERSHIP_STRIDE, flags = gg.TYPE_DWORD },
    -- レベル配列の直前ヘッダーは1 DWORD（4バイト）で、レベル要素の
    -- 8バイトstrideとは異なる。
    { address = tables.level[1].address - OWNERSHIP_STRIDE, flags = gg.TYPE_DWORD },
    { address = tables.form[1].address - FORM_STRIDE, flags = gg.TYPE_DWORD }
  })
  local owner = firstOwner and tonumber(firstOwner.value)
  local ownerHeader = headers[1] and tonumber(headers[1].value)
  local levelHeader = headers[2] and tonumber(headers[2].value)
  local formHeader = headers[3] and tonumber(headers[3].value)
  if owner == nil or ownerHeader == nil or levelHeader == nil or formHeader == nil then
    return -1, "header-read-failed"
  end
  local score = 0
  -- v15.5.1実機で確認したヘッダー関係。版が変わって一部が変化しても、
  -- 複数条件の合計で候補を比較し、単一条件だけでは採用しない。
  if ownerHeader == owner then
    score = score + 4
  end
  if levelHeader == owner + 1 then
    score = score + 3
  end
  if formHeader == 0 then
    score = score + 3
  end
  return score, string.format("owner=%s,owner-header=%s,level-header=%s,form-header=%s",
    tostring(owner), tostring(ownerHeader), tostring(levelHeader), tostring(formHeader))
end

function kenkouDescribeSaveCharacterTables(method, baseAddress, tables, diagnostic)
  local ownershipStart = tables.ownership[1].address
  local levelStart = tables.level[1].address
  local formStart = tables.form[1].address
  local requests = {}
  for saveId = 1, 3 do
    requests[#requests + 1] = tables.ownership[saveId]
    requests[#requests + 1] = tables.level[saveId * 2 - 1]
    requests[#requests + 1] = tables.level[saveId * 2]
    requests[#requests + 1] = tables.form[saveId]
  end
  local values = gg.getValues(requests)
  local headerScore, headerDiagnostic = kenkouScoreSaveArrayHeaders(tables)
  local lines = {
    "version=save-resolution-success-v1",
    "method=" .. tostring(method),
    "base=" .. kenkouFormatAddress(baseAddress),
    "ownership-start=" .. kenkouFormatAddress(ownershipStart),
    "level-start=" .. kenkouFormatAddress(levelStart),
    "form-start=" .. kenkouFormatAddress(formStart),
    "header-score=" .. tostring(headerScore),
    "header-diagnostic=" .. tostring(headerDiagnostic or ""),
    "diagnostic=" .. tostring(diagnostic or "")
  }
  for saveId = 1, 3 do
    local offset = (saveId - 1) * 4
    local level, plus = kenkouDecodeLevel(
      values[offset + 2] and values[offset + 2].value,
      values[offset + 3] and values[offset + 3].value
    )
    lines[#lines + 1] = string.format("id=%d,owner=%s,level=%s,plus=%s,form=%s", saveId - 1,
      tostring(values[offset + 1] and values[offset + 1].value), tostring(level), tostring(plus),
      tostring(values[offset + 4] and values[offset + 4].value))
  end
  kenkouWriteSaveDiagnostics(lines)
end

function kenkouFindSaveCharacterTables(anchorAddress, anchorValue)
  local unitCount = state.characterCount
  if not unitCount then
    return nil
  end
  anchorValue = math.floor(anchorValue)
  gg.clearResults()
  gg.searchNumber(string.format("%d~%d", anchorValue - 1, anchorValue + 1), gg.TYPE_DWORD, false,
    SIGN_EQUAL, anchorAddress - unitCount * OWNERSHIP_STRIDE - 0x100,
    anchorAddress + math.max(0x500, SAVE_ANALYSIS_WINDOW))
  local startResultCount = gg.getResultsCount()
  local startResults = startResultCount > 0
    and gg.getResults(math.min(startResultCount, MAX_OWNERSHIP_START_CANDIDATES)) or {}
  gg.clearResults()
  table.sort(startResults, function(left, right) return left.address < right.address end)

  local rejectionCounts = {}
  for _, startResult in ipairs(startResults) do
    local startAddress = startResult.address
    local tables = kenkouBuildSaveCharacterTables(startAddress, unitCount)
    local valid, reason = kenkouValidateSaveCharacterTables(tables)
    if valid then
      return tables
    end
    rejectionCounts[reason or "unknown"] = (rejectionCounts[reason or "unknown"] or 0) + 1
  end
  local rejectionSummary = {}
  for reason, count in pairs(rejectionCounts) do
    rejectionSummary[#rejectionSummary + 1] = string.format("%s=%d", reason, count)
  end
  table.sort(rejectionSummary)
  return nil, string.format("start-results=%d, inspected=%d, rejections=%s", startResultCount,
    #startResults, table.concat(rejectionSummary, ","))
end

function kenkouLooksLikeSaveCharacterOwnershipStart(startAddress, unitCount)
  local levelStart = startAddress + unitCount * OWNERSHIP_STRIDE + OWNERSHIP_LEVEL_GAP
  local formStart = levelStart + unitCount * LEVEL_STRIDE + LEVEL_FORM_GAP
  local values = gg.getValues({
    { address = startAddress, flags = gg.TYPE_DWORD },
    { address = startAddress + OWNERSHIP_STRIDE, flags = gg.TYPE_DWORD },
    { address = startAddress + OWNERSHIP_STRIDE * 2, flags = gg.TYPE_DWORD },
    { address = formStart, flags = gg.TYPE_DWORD },
    { address = formStart + FORM_STRIDE, flags = gg.TYPE_DWORD },
    { address = formStart + FORM_STRIDE * 2, flags = gg.TYPE_DWORD }
  })
  for index = 1, 3 do
    local ownership = values[index] and tonumber(values[index].value)
    local form = values[index + 3] and tonumber(values[index + 3].value)
    if ownership == nil or not form or form < -1 or form > 10 then
      return false
    end
  end
  -- kenkou: 所持状態は実行時にも保護済みDWORDで、0/1としては検証しない。
  local firstOwnership = tonumber(values[1].value)
  return firstOwnership ~= nil
    and firstOwnership == tonumber(values[2].value)
    and firstOwnership == tonumber(values[3].value)
end

function kenkouFindSaveCharacterTablesByOwnershipPattern(baseAddress)
  local unitCount = state.characterCount
  if not unitCount then
    return nil, "unit-count"
  end

  -- kenkou: ネコ・タンクネコ・バトルネコは初期所持。連続する平文所持値から探索する。
  -- 5件一致を優先し、古い／最小構成のセーブ向けに3件一致もフォールバックとする。
  local patterns = {
    "1;1;1;1;1::17",
    "1;1;1::9"
  }
  local diagnostics = {}
  for _, pattern in ipairs(patterns) do
    gg.clearResults()
    gg.searchNumber(pattern, gg.TYPE_DWORD, false, SIGN_EQUAL,
      baseAddress + SAVE_SEARCH_START_OFFSET, baseAddress + SAVE_SEARCH_END_OFFSET)
    local resultCount = gg.getResultsCount()
    diagnostics[#diagnostics + 1] = string.format("ownership-pattern=%s,results=%d", pattern, resultCount)
    local checked = 0
    local prefilterPassed = 0
    local seen = {}
    local skip = 0
    while skip < resultCount do
      local batchCount = math.min(SAVE_RESULT_BATCH_SIZE, resultCount - skip)
      local results = gg.getResults(batchCount, skip)
      if #results == 0 then
        break
      end
      for _, result in ipairs(results) do
        -- kenkou: GGが連続検索の先頭以外を返す版にも対応する。
        for shift = 0, 4 do
          local startAddress = result.address - shift * OWNERSHIP_STRIDE
          if not seen[startAddress] then
            seen[startAddress] = true
            checked = checked + 1
            if kenkouLooksLikeSaveCharacterOwnershipStart(startAddress, unitCount) then
              prefilterPassed = prefilterPassed + 1
              local tables = kenkouBuildSaveCharacterTables(startAddress, unitCount)
              local valid = kenkouValidateSaveCharacterTables(tables)
              if valid then
                gg.clearResults()
                return tables, string.format("ownership-pattern=%s,results=%d,checked=%d,prefilter=%d", pattern,
                  resultCount, checked, prefilterPassed)
              end
            end
          end
        end
      end
      skip = skip + batchCount
    end
    gg.clearResults()
    diagnostics[#diagnostics + 1] = string.format("ownership-checked=%d,prefilter=%d", checked, prefilterPassed)
  end
  return nil, table.concat(diagnostics, ";")
end

function kenkouGetLegacyCandidateBoundary(candidate)
  local value = math.floor(tonumber(candidate.value) or 0)
  gg.clearResults()
  gg.searchNumber(string.format("%d~%d", value - 1, value + 1), gg.TYPE_DWORD, false, SIGN_EQUAL,
    candidate.address - 0x500, candidate.address + SAVE_ANALYSIS_WINDOW)
  local startResult = gg.getResults(1)[1]
  gg.clearResults()
  gg.searchNumber("0~10", gg.TYPE_DWORD, false, SIGN_EQUAL,
    candidate.address, candidate.address + SAVE_ANALYSIS_WINDOW)
  local endResult = gg.getResults(1)[1]
  gg.clearResults()
  if not startResult or not endResult then
    return nil, "legacy-boundary=missing"
  end

  local startAddress = startResult.address
  local endAddress = endResult.address - OWNERSHIP_STRIDE
  local blockSize = (endAddress - startAddress) / 3
  if blockSize <= 0 or blockSize % OWNERSHIP_STRIDE ~= 0 then
    return nil, string.format("legacy-boundary=start=%s,end=%s,block=invalid:%s", kenkouFormatAddress(startAddress),
      kenkouFormatAddress(endAddress), tostring(blockSize))
  end

  local zeroCounts = {}
  local ranges = {
    { startAddress, startAddress + blockSize },
    { startAddress + blockSize + OWNERSHIP_STRIDE, endAddress },
    { endAddress + OWNERSHIP_STRIDE, endAddress + blockSize }
  }
  for _, range in ipairs(ranges) do
    gg.clearResults()
    gg.searchNumber("0~~0", gg.TYPE_DWORD, false, SIGN_EQUAL, range[1], range[2])
    zeroCounts[#zeroCounts + 1] = gg.getResultsCount()
  end
  gg.clearResults()
  local unitCount = blockSize / OWNERSHIP_STRIDE
  local diagnostic = string.format("legacy-boundary=start=%s,end=%s,block=0x%X,units=%d,zero-counts=%d/%d/%d",
    kenkouFormatAddress(startAddress), kenkouFormatAddress(endAddress), blockSize,
    unitCount, zeroCounts[1], zeroCounts[2], zeroCounts[3])
  return {
    ownershipStart = startAddress,
    unitCount = unitCount
  }, diagnostic
end

function kenkouFindSaveCharacterTablesByFormAnchorLegacy()
  local unitCount = state.characterCount
  if not unitCount then
    return nil, "unit-count"
  end

  -- kenkou: 現行セーブでは基礎キャラ群の保存フォームが連続して2になる。
  -- ここから静的解析で確定した相対配置を逆算し、保護レベルを復号して検証する。
  gg.clearResults()
  gg.setRanges(48)
  gg.searchNumber(FORM_ANCHOR_PATTERN, gg.TYPE_DWORD, false, SIGN_EQUAL, 0, -1)
  local resultCount = gg.getResultsCount()
  local results = resultCount > 0
    and gg.getResults(math.min(resultCount, MAX_FORM_ANCHOR_CANDIDATES)) or {}
  gg.clearResults()
  if #results == 0 then
    return nil, "form-anchor=not-found"
  end

  local inspected = 0
  local rejections = {}
  table.sort(results, function(left, right) return left.address < right.address end)
  for _, result in ipairs(results) do
    local previous = gg.getValues({ { address = result.address - FORM_STRIDE, flags = gg.TYPE_DWORD } })[1]
    -- kenkou: 連続値の途中も結果になる。直前が2ではない候補だけを配列先頭として扱う。
    if not previous or tonumber(previous.value) ~= 2 then
      inspected = inspected + 1
      -- kenkou: 20件連続する値2は、ネコ(ID 000)の次である
      -- タンクネコ(ID 001)から始まる。直前の1件を含めて本当の配列先頭に戻す。
      local formStart = result.address - FORM_STRIDE
      local ownershipStart = formStart - unitCount * LEVEL_STRIDE - LEVEL_FORM_GAP
        - unitCount * OWNERSHIP_STRIDE - OWNERSHIP_LEVEL_GAP
      local tables = kenkouBuildSaveCharacterTables(ownershipStart, unitCount)
      local valid, reason = kenkouValidateSaveCharacterTables(tables)
      if valid then
        return tables, string.format("form-anchor=%s,results=%d,inspected=%d,full-validation",
          kenkouFormatAddress(formStart), resultCount, inspected)
      end
      local initialValid, initialReason = kenkouValidateSaveCharacterInitialRows(tables)
      if initialValid then
        return tables, string.format("form-anchor=%s,results=%d,inspected=%d,initial-validation",
          kenkouFormatAddress(formStart), resultCount, inspected)
      end
      rejections[string.format("%s/%s", reason or "unknown", initialReason or "unknown")]
        = (rejections[string.format("%s/%s", reason or "unknown", initialReason or "unknown")] or 0) + 1
    end
  end
  local details = {}
  for reason, count in pairs(rejections) do
    details[#details + 1] = string.format("%s=%d", reason, count)
  end
  table.sort(details)
  return nil, string.format("form-anchor-results=%d,inspected=%d,rejections=%s", resultCount, inspected,
    table.concat(details, ","))
end

-- kenkou: 旧アンカーは現在形態配列ではなく、レベル配列先頭を拾うことがある。
-- 候補をレベル配列先頭として扱い、固定レイアウトから所有・レベル・現在形態を組み立てる。
function kenkouFindSaveCharacterTablesByFormAnchor()
  local unitCount = state.characterCount
  if not unitCount then
    return nil, "unit-count"
  end
  gg.clearResults()
  gg.setRanges(48)
  -- ネコ(ID 0)・タンクネコ(ID 1)を基準にするため、形態2だけでなく
  -- 第1形態の0連続も候補にする。全キャラの現在形態が第1形態の場合は
  -- 2連続アンカーが存在しないため、0だけを探す必要がある。
  local anchorPatterns = {
    { value = SAVE_LAYOUT.formAnchorValue, pattern = FORM_ANCHOR_PATTERN },
    { value = 0, pattern = "0" .. (";0"):rep(SAVE_LAYOUT.formAnchorLength - 1) }
  }
  local inspected = 0
  local rejections = {}
  local bestTables = nil
  local bestScore = -1
  local bestDiagnostic = nil
  local tiedBest = false
  local totalResultCount = 0
  for _, anchorPattern in ipairs(anchorPatterns) do
    gg.clearResults()
    gg.searchNumber(anchorPattern.pattern, gg.TYPE_DWORD, false, SIGN_EQUAL, 0, -1)
    local resultCount = gg.getResultsCount()
    totalResultCount = totalResultCount + resultCount
    local results = resultCount > 0
      and gg.getResults(math.min(resultCount, MAX_FORM_ANCHOR_CANDIDATES)) or {}
    gg.clearResults()
    table.sort(results, function(left, right) return left.address < right.address end)
    for _, result in ipairs(results) do
    -- 通常はネコ(ID 0)が第1形態で、タンクネコ(ID 1)以降が2になるため、
    -- 20件連続検索の先頭はID 1を指す。ただし、既に形態変更済みのセーブでは
    -- ネコ自身も2になり、検索結果がID 0から始まることがある。両方を候補にして
    -- 三配列の検証で決定することで、特定キャラの状態に依存しない。
    local formStarts = { result.address - FORM_STRIDE, result.address }
    local seenFormStarts = {}
    for _, formStart in ipairs(formStarts) do
      if not seenFormStarts[formStart] then
        seenFormStarts[formStart] = true
        inspected = inspected + 1
        local previous = gg.getValues({
          { address = formStart - FORM_STRIDE, flags = gg.TYPE_DWORD }
        })[1]
        -- ID 1始まり候補で前も2なら連続列の途中。ID 0始まり候補は
        -- 現在の検索結果そのものなので、この条件で除外しない。
        local isIdOneCandidate = formStart == result.address - FORM_STRIDE
        if not isIdOneCandidate or not previous
          or tonumber(previous.value) ~= anchorPattern.value then
      local ownershipStart = formStart - unitCount * LEVEL_STRIDE - LEVEL_FORM_GAP
        - unitCount * OWNERSHIP_STRIDE - OWNERSHIP_LEVEL_GAP
      local tables = kenkouBuildSaveCharacterTables(ownershipStart, unitCount)
      -- ヘッダー3条件を先に読む。ここで候補の大半を落とし、873体分の
      -- レベル復号を候補ごとに実行しないことで起動時間を抑える。
      local headerScore, headerDiagnostic = kenkouScoreSaveArrayHeaders(tables)
      if headerScore >= SAVE_HEADER_REQUIRED_SCORE then
        local valid, reason = kenkouValidateSaveCharacterTables(tables)
        if valid then
          if headerScore > bestScore then
            bestTables = tables
            bestScore = headerScore
            bestDiagnostic = string.format(
              "form-anchor=%s,results=%d,inspected=%d,full-validation,header-score=%d,%s",
              kenkouFormatAddress(formStart), resultCount, inspected, headerScore, headerDiagnostic)
            tiedBest = false
          elseif headerScore == bestScore then
            tiedBest = true
          end
        else
          local initialValid, initialReason = kenkouValidateSaveCharacterInitialRows(tables)
          if initialValid then
            if headerScore > bestScore then
              bestTables = tables
              bestScore = headerScore
              bestDiagnostic = string.format(
                "form-anchor=%s,results=%d,inspected=%d,initial-validation,header-score=%d,%s",
                kenkouFormatAddress(formStart), resultCount, inspected, headerScore, headerDiagnostic)
              tiedBest = false
            elseif headerScore == bestScore then
              tiedBest = true
            end
          else
            local rejection = string.format("%s/%s", reason or "unknown", initialReason or "unknown")
            rejections[rejection] = (rejections[rejection] or 0) + 1
          end
        end
      else
        rejections[string.format("header-score=%d/%s", headerScore, headerDiagnostic or "unknown")]
          = (rejections[string.format("header-score=%d/%s", headerScore, headerDiagnostic or "unknown")] or 0) + 1
      end
        end
      end
    end
  end
  end
  if bestTables and not tiedBest then
    return bestTables, bestDiagnostic
  end
  if tiedBest then
    rejections["header-score-ambiguous"] = (rejections["header-score-ambiguous"] or 0) + 1
  end
  local details = {}
  for reason, count in pairs(rejections) do
    details[#details + 1] = string.format("%s=%d", reason, count)
  end
  table.sort(details)
  return nil, string.format("form-anchor-results=%d,inspected=%d,rejections=%s", totalResultCount, inspected,
    table.concat(details, ","))
end

-- 個別キャラ編集で使っていた安定経路。基礎キャラの第2形態連続列を
-- タンクネコ(ID 1)の先頭として扱い、直前のネコ(ID 0)へ戻して配列を作る。
-- 全キャラ用の候補比較やヘッダー点数判定はここでは行わず、従来と同じ
-- 三配列・レベル復号検証だけを使う。
function kenkouFindSaveCharacterTablesStableAnchor()
  local unitCount = state.characterCount
  if not unitCount then
    return nil, "unit-count"
  end
  gg.clearResults()
  gg.setRanges(48)
  gg.searchNumber(FORM_ANCHOR_PATTERN, gg.TYPE_DWORD, false, SIGN_EQUAL, 0, -1)
  local resultCount = gg.getResultsCount()
  local results = resultCount > 0
    and gg.getResults(math.min(resultCount, MAX_FORM_ANCHOR_CANDIDATES)) or {}
  gg.clearResults()
  if #results == 0 then
    return nil, "form-anchor=not-found"
  end
  table.sort(results, function(left, right) return left.address < right.address end)
  local inspected = 0
  local rejections = {}
  for _, result in ipairs(results) do
    local previous = gg.getValues({
      { address = result.address - FORM_STRIDE, flags = gg.TYPE_DWORD }
    })[1]
    if not previous or tonumber(previous.value) ~= SAVE_LAYOUT.formAnchorValue then
      inspected = inspected + 1
      local formStart = result.address - FORM_STRIDE
      local ownershipStart = formStart - unitCount * LEVEL_STRIDE - LEVEL_FORM_GAP
        - unitCount * OWNERSHIP_STRIDE - OWNERSHIP_LEVEL_GAP
      local tables = kenkouBuildSaveCharacterTables(ownershipStart, unitCount)
      local valid, reason = kenkouValidateSaveCharacterTables(tables)
      if valid then
        return tables, string.format("stable-form-anchor=%s,results=%d,inspected=%d",
          kenkouFormatAddress(formStart), resultCount, inspected)
      end
      local initialValid, initialReason = kenkouValidateSaveCharacterInitialRows(tables)
      if initialValid then
        return tables, string.format("stable-form-anchor=%s,results=%d,inspected=%d,initial",
          kenkouFormatAddress(formStart), resultCount, inspected)
      end
      local key = string.format("%s/%s", reason or "unknown", initialReason or "unknown")
      rejections[key] = (rejections[key] or 0) + 1
    end
  end
  return nil, string.format("stable-form-anchor-results=%d,inspected=%d", resultCount, inspected)
end

-- 旧版互換の保存配列探索。個別キャラ編集で実績のある探索順をそのまま使い、
-- ネコ(ID 0)・タンクネコ(ID 1)を含む連続レコードから三配列を組み立てる。
-- 新しい固定レイアウト探索が版差分で停止した場合でも、まずこの経路を試す。
function kenkouResolveSaveCharacterTablesLegacy()
  if not state.characterCount then
    return nil, "unit-count"
  end
  local baseAddress, baseError = kenkouResolveSaveBaseAddress()
  if not baseAddress then
    return nil, baseError
  end

  gg.clearResults()
  gg.toast("キャラ保存状態を探索中（旧方式）")
  local pattern = "-257~~256" .. (";-257~~256"):rep(63) .. ":253"
  gg.searchNumber(pattern, gg.TYPE_DWORD, false, SIGN_EQUAL,
    baseAddress + SAVE_SEARCH_START_OFFSET, baseAddress + SAVE_SEARCH_END_OFFSET)
  local resultCount = gg.getResultsCount()
  if resultCount < 16 then
    gg.clearResults()
    return nil, "キャラ保存状態の配列候補が見つかりません。"
  end

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
        and math.abs((tonumber(results[index + 10].value) or 0)
          - (tonumber(results[index + 15].value) or 0)) < 2
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

  for index, candidate in ipairs(candidates) do
    gg.toast(string.format("保存配列を確認中（旧方式） %d/%d", index, #candidates))
    local tables = kenkouFindSaveCharacterTables(candidate.address, candidate.value)
    if tables then
      kenkouDescribeSaveCharacterTables("legacy-compatible", baseAddress, tables,
        string.format("candidate=%d/%d,results=%d", index, #candidates, resultCount))
      return tables
    end
  end
  return nil, string.format("旧方式でも保存配列を確認できませんでした（候補%d件）。", #candidates)
end

-- kenkou: ARM64版の実行中 MyApplication を vtable から求める。
-- `SAVE_DATA` はこのオブジェクトの固定オフセットに直列化される。値の検索や
-- 保存ファイル由来の候補ではないので、同じ値を持つ別配列を誤採用しない。
function kenkouResolveNativeSaveCharacterTables()
  local unitCount = tonumber(state.characterCount)
  if not unitCount or unitCount < 1 then
    return nil, "キャラ数を読み込んだ後に保存配列を確認してください。"
  end

  local imageBase = nil
  for _, range in ipairs(gg.getRangesList("libnative-lib.so") or {}) do
    local startAddress = tonumber(range.start)
    if startAddress and (not imageBase or startAddress < imageBase) then
      imageBase = startAddress
    end
  end
  if not imageBase then
    return nil, "libnative-lib.so の load bias を取得できません。"
  end

  local runtimeVtable = imageBase + NATIVE_MY_APPLICATION_VTABLE_RVA
  gg.clearResults()
  gg.setRanges(gg.REGION_C_BSS)
  gg.searchNumber(string.format("%.0f", runtimeVtable), gg.TYPE_QWORD, false, SIGN_EQUAL, 0, -1)
  local candidates = gg.getResults(16)
  gg.clearResults()
  if #candidates == 0 then
    return nil, "MyApplication の実行中インスタンスを .bss から確認できません。"
  end

  local layout = kenkouGetNativeSaveLayoutProfile()
  local validationIndexes = kenkouGetValidationIndexes(unitCount)
  for _, candidate in ipairs(candidates) do
    local nativeObject = tonumber(candidate.address)
    if nativeObject then
      local tables = {
        ownership = kenkouBuildDwordRecords(nativeObject + layout.ownershipOffset, unitCount, 4),
        level = kenkouBuildDwordRecords(nativeObject + layout.levelOffset, unitCount * 2, 4),
        form = kenkouBuildDwordRecords(nativeObject + layout.formOffset, unitCount, 4),
        unitCount = unitCount,
        nativeObject = nativeObject,
        ownershipKey = {
          address = nativeObject + layout.ownershipKeyOffset,
          flags = gg.TYPE_DWORD
        }
      }
      local requests = {
        { address = nativeObject, flags = gg.TYPE_QWORD },
        tables.ownershipKey
      }
      for _, saveId in ipairs(validationIndexes) do
        requests[#requests + 1] = tables.ownership[saveId]
        requests[#requests + 1] = tables.level[saveId * 2 - 1]
        requests[#requests + 1] = tables.level[saveId * 2]
        requests[#requests + 1] = tables.form[saveId]
      end
      local values = gg.getValues(requests)
      local valid = #values == #requests and tonumber(values[1] and values[1].value) == runtimeVtable
      local ownershipKey = valid and values[2] and values[2].value or nil
      if valid and ownershipKey == nil then
        valid = false
      end
      if valid then
        local valueIndex = 3
        for _, saveId in ipairs(validationIndexes) do
          local rawOwnership = values[valueIndex] and values[valueIndex].value
          local levelValue = values[valueIndex + 1] and values[valueIndex + 1].value
          local markerValue = values[valueIndex + 2] and values[valueIndex + 2].value
          local formValue = tonumber(values[valueIndex + 3] and values[valueIndex + 3].value)
          local decodedOwnership = kenkouXorDword(rawOwnership, ownershipKey)
          local level, plus = kenkouDecodeLevel(levelValue, markerValue)
          if (decodedOwnership ~= 0 and decodedOwnership ~= 1)
            or not level or level < 1 or level > SAVE_DISCOVERY_MAX_LEVEL
            or plus == nil or plus < 0 or plus > SAVE_DISCOVERY_MAX_PLUS
            or not formValue or formValue < 0 or formValue > 3 or formValue % 1 ~= 0 then
            valid = false
            break
          end
          valueIndex = valueIndex + 4
        end
      end
      if valid then
        return tables, string.format(
          "method=myapplication-vtable,profile=%s,image-base=%s,vtable=%s,native-object=%s",
          tostring(layout.name), kenkouFormatAddress(imageBase), kenkouFormatAddress(runtimeVtable),
          kenkouFormatAddress(nativeObject)
        )
      end
    end
  end
  return nil, string.format("MyApplication候補%d件の保存配列検証に失敗しました。", #candidates)
end

kenkouResolveSaveCharacterTables = function()
  if state.saveCharacterTables then
    return state.saveCharacterTables
  end

  -- v15.5.1実機で確認済みの唯一の正規経路。ここで失敗した場合に旧来の
  -- 値検索へ落ちると、別の配列を書き換える危険があるため安全に停止する。
  local nativeTables, nativeDiagnostic = kenkouResolveNativeSaveCharacterTables()
  if nativeTables then
    state.nativeObjectAddress = nativeTables.nativeObject
    state.saveBaseAddress = nativeTables.nativeObject
    state.saveCharacterTables = nativeTables
    kenkouDescribeSaveCharacterTables("myapplication-vtable", nativeTables.nativeObject,
      nativeTables, nativeDiagnostic)
    kenkouWriteSaveDiagnostics({
      "version=save-resolution-v15.5.1-myapplication",
      tostring(nativeDiagnostic),
      "ownership-start=" .. kenkouFormatAddress(nativeTables.ownership[1].address),
      "level-start=" .. kenkouFormatAddress(nativeTables.level[1].address),
      "form-start=" .. kenkouFormatAddress(nativeTables.form[1].address),
      "ownership-key=" .. kenkouFormatAddress(nativeTables.ownershipKey.address),
      "unit-count=" .. tostring(nativeTables.unitCount)
    })
    gg.toast(string.format("保存配列を確認しました（%d体・MyApplication）", nativeTables.unitCount))
    return nativeTables
  end

  -- 旧探索コードは検証用として残すが、誤配列を採用するため本番実行はしない。
  if false then
  -- 個別キャラ編集で実績のあるフォームアンカー経路を最初に使う。
  -- これが成功すれば広い保存構造検索を実行しないため、起動も速い。
  local stableTables, stableDiagnostic = kenkouFindSaveCharacterTablesStableAnchor()
  if stableTables then
    state.saveCharacterTables = stableTables
    kenkouDescribeSaveCharacterTables("stable-form-anchor", stableTables.form[1].address,
      stableTables, stableDiagnostic)
    gg.toast(string.format("保存配列を確認しました（%d体）", stableTables.unitCount))
    return stableTables
  end

  -- arm64-v8a v15.5.1 の SAVE_DATA 固定レイアウトを最優先する。
  -- 値検索だけでは初期値テーブルを誤検出するため、ELF の最低マッピングから
  -- C++ グローバルオブジェクトを求め、デシリアライザの配列位置を直接検証する。
  local ranges = gg.getRangesList("libnative-lib.so") or {}
  local imageBase = nil
  for _, range in ipairs(ranges) do
    local startAddress = tonumber(range.start)
    if startAddress and (not imageBase or startAddress < imageBase) then
      imageBase = startAddress
    end
  end
  if imageBase and state.characterCount then
    local nativeLayout = kenkouGetNativeSaveLayoutProfile()
    local nativeObject = imageBase + nativeLayout.objectOffset
    local unitCount = state.characterCount
    local staticTables = {
      ownership = kenkouBuildDwordRecords(nativeObject + nativeLayout.ownershipOffset, unitCount, 4),
      level = kenkouBuildDwordRecords(nativeObject + nativeLayout.levelOffset, unitCount * 2, 4),
      form = kenkouBuildDwordRecords(nativeObject + nativeLayout.formOffset, unitCount, 4),
      unitCount = unitCount,
      nativeObject = nativeObject,
      ownershipKey = nativeObject + nativeLayout.ownershipKeyOffset
    }
    local sampleRequests = {}
    for _, saveId in ipairs(kenkouGetValidationIndexes(unitCount)) do
      sampleRequests[#sampleRequests + 1] = staticTables.level[saveId * 2 - 1]
      sampleRequests[#sampleRequests + 1] = staticTables.level[saveId * 2]
      sampleRequests[#sampleRequests + 1] = staticTables.form[saveId]
    end
    local sampleValues = gg.getValues(sampleRequests)
    local staticFailureReason = nil
    local staticValid = #sampleValues == #sampleRequests
    if not staticValid then
      staticFailureReason = string.format("sample-count:%d/%d", #sampleValues, #sampleRequests)
    end
    if staticValid then
      for index = 1, #sampleValues, 3 do
        local level, plus = kenkouDecodeLevel(sampleValues[index].value, sampleValues[index + 1].value)
        local form = tonumber(sampleValues[index + 2].value)
        if not level or level < 1 or level > SAVE_DISCOVERY_MAX_LEVEL
          or plus == nil or plus < 0 or plus > SAVE_DISCOVERY_MAX_PLUS
          or not form or form < -1 or form > 3 or form % 1 ~= 0 then
          staticValid = false
          staticFailureReason = string.format("sample:%d,level=%s,plus=%s,form=%s",
            math.floor((index + 2) / 3), tostring(level), tostring(plus), tostring(form))
          break
        end
      end
    end
    if staticValid then
      local headerScore, headerDiagnostic = kenkouScoreSaveArrayHeaders(staticTables)
      if headerScore < SAVE_HEADER_REQUIRED_SCORE then
        staticValid = false
        staticFailureReason = string.format("header-score=%d,%s", headerScore, headerDiagnostic or "unknown")
      end
    end
    if staticValid then
      state.nativeObjectAddress = nativeObject
      state.saveBaseAddress = nativeObject
      state.saveCharacterTables = staticTables
      kenkouWriteSaveDiagnostics({
        "version=save-resolution-static-v2",
        "method=arm64-native-object",
        "profile=" .. tostring(nativeLayout.name),
        "image-base=" .. kenkouFormatAddress(imageBase),
        "native-object=" .. kenkouFormatAddress(nativeObject),
        "ownership-start=" .. kenkouFormatAddress(staticTables.ownership[1].address),
        "level-start=" .. kenkouFormatAddress(staticTables.level[1].address),
        "form-start=" .. kenkouFormatAddress(staticTables.form[1].address),
        "unit-count=" .. tostring(unitCount)
      })
      gg.toast(string.format("保存配列を確認しました（%d体・arm64固定レイアウト）", unitCount))
      return staticTables
    end

    -- 固定オブジェクトが実行中のSAVE_DATAインスタンスでない場合があるため、
    -- 検証に失敗したときは、従来のフォーム配列アンカーを検証付きで試す。
    -- アンカー側も三配列とレベル復号を検証し、失敗した候補は採用しない。
    kenkouWriteSaveDiagnostics({
      "version=save-resolution-static-failed-v2",
      "method=arm64-native-object",
      "profile=" .. tostring(nativeLayout.name),
      "image-base=" .. kenkouFormatAddress(imageBase),
      "native-object=" .. kenkouFormatAddress(nativeObject),
      "ownership-start=" .. kenkouFormatAddress(staticTables.ownership[1].address),
      "level-start=" .. kenkouFormatAddress(staticTables.level[1].address),
      "form-start=" .. kenkouFormatAddress(staticTables.form[1].address),
      "unit-count=" .. tostring(unitCount),
      "reason=" .. tostring(staticFailureReason or "unknown")
    })
    -- 続くフォームアンカー探索へ進む。
  end

  -- kenkou: 連続した「2」だけではレベル暗号化配列にも一致するため、
  -- 形態アンカーを保存基準の決定に使わない。固定オフセット経路を優先する。
  -- kenkou: timezone アンカーで保存オブジェクトを先に求める。v15.5.1 の
  -- 配列は同じ基準アドレスから固定配置されるため、直接検証できれば
  -- 全匿名メモリの長い形態アンカー検索を省略できる。
  local fastBaseAddress = kenkouResolveSaveBaseAddress()
  if fastBaseAddress then
    local fastOwnershipStart = kenkouGetExpectedOwnershipStart(fastBaseAddress, state.characterCount)
    local fastTables = kenkouBuildSaveCharacterTables(fastOwnershipStart, state.characterCount)
    local fastValid = kenkouValidateSaveCharacterTables(fastTables)
    if fastValid then
      local headerScore = kenkouScoreSaveArrayHeaders(fastTables)
      fastValid = headerScore >= SAVE_HEADER_REQUIRED_SCORE
    end
    if fastValid then
      state.saveCharacterTables = fastTables
      kenkouDescribeSaveCharacterTables("native-relative", fastBaseAddress, fastTables, "fast-direct")
      gg.toast(string.format("save tables verified (%d)", fastTables.unitCount))
      return fastTables
    end
  end

  local formAnchoredTables, formAnchorDiagnostic = kenkouFindSaveCharacterTablesByFormAnchor()
  if formAnchoredTables then
    state.saveCharacterTables = formAnchoredTables
    kenkouDescribeSaveCharacterTables("form-anchor", formAnchoredTables.form[1].address,
      formAnchoredTables, formAnchorDiagnostic)
    gg.toast(string.format("保存配列を確認しました（%d体）", formAnchoredTables.unitCount))
    return formAnchoredTables
  end

  local baseAddress, baseError = kenkouResolveSaveBaseAddress()
  if not baseAddress then
    return nil, baseError
  end

  -- kenkou: ネイティブのロード／保存処理から確定した位置を最初に直接検証する。
  -- 低値の連続検索は別用途の配列にも多数一致するため、ここを優先する。
  local directOwnershipStart = kenkouGetExpectedOwnershipStart(baseAddress, state.characterCount)
  local directTables = kenkouBuildSaveCharacterTables(directOwnershipStart, state.characterCount)
  local directValid, directReason = kenkouValidateSaveCharacterTables(directTables)
  if directValid then
    local headerScore = kenkouScoreSaveArrayHeaders(directTables)
    directValid = headerScore >= SAVE_HEADER_REQUIRED_SCORE
  end
  if directValid then
    state.saveCharacterTables = directTables
    kenkouDescribeSaveCharacterTables("native-relative", baseAddress, directTables, "direct")
    gg.toast(string.format("保存配列を確認しました（%d体）", directTables.unitCount))
    return directTables
  end

  -- kenkou: 所持値だけで一致する初期値テーブルが存在するため、形状検索は採用しない。
  local ownershipCandidateDiagnostic = "skipped: ownership-only pattern can match an initial-value table"

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
  local diagnostics = {
    "version=save-resolution-diagnostics-v1",
    "unit-count=" .. tostring(state.characterCount),
    "base=" .. kenkouFormatAddress(baseAddress),
    "direct-ownership=" .. kenkouFormatAddress(directOwnershipStart),
    "direct-validation=" .. tostring(directReason),
    "ownership-validation=" .. tostring(ownershipCandidateDiagnostic),
    "pattern-results=" .. tostring(resultCount)
  }
  local candidates = {}
  local candidateDiagnostics = {}
  local candidateCount = 0
  local cachedValue = nil
  local skip = 0
  while skip < resultCount - 15 do
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
          candidateCount = candidateCount + 1
          if #candidateDiagnostics < 512 then
            candidateDiagnostics[#candidateDiagnostics + 1] = string.format(
              "raw-candidate=%d,address=%s,offset=0x%X,value=%s", candidateCount,
              kenkouFormatAddress(current.address), current.address - baseAddress,
              tostring(tonumber(current.value) or 0))
          end
          if #candidates < MAX_SAVE_TABLE_CANDIDATES then
            candidates[#candidates + 1] = {
              address = current.address,
              value = tonumber(current.value) or 0
            }
          end
          cachedValue = -1
        end
      else
        cachedValue = -1
      end
    end
    skip = skip + SAVE_RESULT_BATCH_SIZE
  end
  gg.clearResults()

  diagnostics[#diagnostics + 1] = "structure-candidates=" .. tostring(candidateCount)
  for _, diagnostic in ipairs(candidateDiagnostics) do
    diagnostics[#diagnostics + 1] = diagnostic
  end

  if #candidates == 0 then
    return nil, string.format("キャラ保存状態の構造候補が見つかりません（検索結果%d件）。", resultCount)
  end
  for index, candidate in ipairs(candidates) do
    gg.toast(string.format("保存配列を確認中 %d/%d", index, #candidates))
    local boundary, boundaryDiagnostic = kenkouGetLegacyCandidateBoundary(candidate)
    diagnostics[#diagnostics + 1] = string.format("candidate=%d,address=%s,value=%s,%s", index,
      kenkouFormatAddress(candidate.address), tostring(candidate.value),
      boundaryDiagnostic)
    if boundary then
      local boundaryTables = kenkouBuildSaveCharacterTables(boundary.ownershipStart, boundary.unitCount)
      local boundaryValid, boundaryReason = kenkouValidateSaveCharacterTables(boundaryTables)
      diagnostics[#diagnostics + 1] = string.format("candidate-boundary-validation=%d,units=%d,result=%s", index,
        boundary.unitCount, tostring(boundaryReason))
      if boundaryValid then
        -- 形状だけでは初期値テーブルを採用してしまうため、三配列のヘッダーも必ず確認する。
        local headerScore, headerDiagnostic = kenkouScoreSaveArrayHeaders(boundaryTables)
        diagnostics[#diagnostics + 1] = string.format(
          "candidate-boundary-header=%d,score=%d,%s", index, headerScore, headerDiagnostic or "unknown")
        if headerScore >= SAVE_HEADER_REQUIRED_SCORE then
          state.saveCharacterTables = boundaryTables
          kenkouDescribeSaveCharacterTables("legacy-boundary", baseAddress, boundaryTables,
            boundaryDiagnostic .. ",header-score=" .. tostring(headerScore))
          gg.toast(string.format("保存配列を確認しました（%d体）", boundaryTables.unitCount))
          return boundaryTables
        end
      end
    end
    local tables, diagnostic = kenkouFindSaveCharacterTables(candidate.address, candidate.value)
    diagnostics[#diagnostics + 1] = string.format("candidate-validation=%d,address=%s,value=%s,%s", index,
      kenkouFormatAddress(candidate.address), tostring(candidate.value), diagnostic or "resolved")
    if tables then
      -- kenkouFindSaveCharacterTables はレベル値の妥当性も見るが、誤ったメモリ領域が
      -- 同じ範囲に収まることがある。ヘッダー三点が揃わない候補は絶対に書き換えない。
      local headerScore, headerDiagnostic = kenkouScoreSaveArrayHeaders(tables)
      diagnostics[#diagnostics + 1] = string.format(
        "candidate-low-value-header=%d,score=%d,%s", index, headerScore, headerDiagnostic or "unknown")
      if headerScore >= SAVE_HEADER_REQUIRED_SCORE then
        state.saveCharacterTables = tables
        kenkouDescribeSaveCharacterTables("legacy-low-value", baseAddress, tables,
          tostring(diagnostic or "resolved") .. ",header-score=" .. tostring(headerScore))
        gg.toast(string.format("保存配列を確認しました（%d体）", tables.unitCount))
        return tables
      end
    end
  end
  kenkouWriteSaveDiagnostics(diagnostics)
  return nil, string.format("保存配列を確認できませんでした（候補%d件）。", #candidates)
  end
  return nil, nativeDiagnostic
end

function chooseFromList(characters)
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
      labels[index] = string.format("%03d  %s", character.id, tostring(character.name or "(名前未登録)"))
    end
    local selectedCharacter = kenkouChooseMenu(labels, "キャラを選択", true,
      "kenkou-character-" .. bucketStarts[selectedBucket])
    if selectedCharacter then
      return candidates[selectedCharacter]
    end
  end
end

function kenkouGetCharacterName(character)
  return tostring(character and character.name or "(名前未登録)")
end

function chooseByName(characters)
  local prompt = gg.prompt({ "キャラ名またはIDを入力" }, { "" }, { "text" })
  if not prompt then
    kenkouSuspendUntilVisible()
    return nil
  end
  local query = trim(tostring(prompt[1] or ""))
  if query == "" then
    return nil
  end

  local candidates = {}
  local normalizedQuery = query:lower()
  -- Android/GG の数値入力欄では数字間に空白が入ることがあるため、
  -- ID検索用の数値だけ空白を除去してから変換する。
  -- gsub は置換後文字列と置換回数の2値を返すため、直接 tonumber へ渡さない。
  local compactQuery = query:gsub("%s+", "")
  local numericQuery = tonumber(compactQuery)
  for _, character in ipairs(characters) do
    local characterName = tostring(character.name or "")
    if (numericQuery and character.id == numericQuery)
      or characterName:lower():find(normalizedQuery, 1, true) then
      candidates[#candidates + 1] = character
    end
  end
  if #candidates == 0 then
    gg.alert("該当するキャラがありません。")
    return nil
  end

  local labels = {}
  for index, character in ipairs(candidates) do
    labels[index] = string.format("%03d  %s", character.id, tostring(character.name or "(名前未登録)"))
  end
  local selectedCharacter = kenkouChooseMenu(labels, "検索結果", true, "kenkou-search-results")
  return selectedCharacter and candidates[selectedCharacter] or nil
end

function chooseForm(character)
  local indices = {}
  for formIndex in pairs(character.forms) do
    indices[#indices + 1] = formIndex
  end
  table.sort(indices)
  local labels = {}
  for index, formIndex in ipairs(indices) do
    labels[index] = string.format("第%d　%s", formIndex + 1, character.forms[formIndex].label)
  end
  local selectedForm = kenkouChooseMenu(labels, kenkouGetCharacterName(character) .. " の形態を選択", true,
    "kenkou-form-" .. character.id)
  return selectedForm and indices[selectedForm] or nil
end

function kenkouFormatFieldLabel(field)
  if field.fieldType == "checkbox" then
    return field.name
  end
  if field.multiplier ~= 1 then
    return string.format("%s（CSV値・内部×%d）", field.name, field.multiplier)
  end
  return field.name .. "（CSV値）"
end

function kenkouReadFormValues(character, formIndex, row)
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
  local baselineKey = tostring(character.id) .. ":" .. tostring(formIndex)
  if not state.statusBaselines[baselineKey] then
    local baseline = {}
    for index = 1, RECORD_COLUMN_COUNT do
      baseline[index] = tonumber(values[index] and values[index].value) or tonumber(row[index]) or 0
    end
    state.statusBaselines[baselineKey] = baseline
  end
  return values
end

function kenkouResetStatusValues(currentValues, row)
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

function kenkouOpenStatusEditor(character, formIndex, row)
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

function kenkouSaveToList(character, formIndex, row)
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

function kenkouGetChangedStatusFields(character, formIndex, row)
  local currentValues, errorMessage = kenkouReadFormValues(character, formIndex, row)
  if not currentValues then
    return nil, errorMessage
  end
  local baselineKey = tostring(character.id) .. ":" .. tostring(formIndex)
  local baseline = state.statusBaselines[baselineKey] or {}
  local changed = {}
  for index, field in ipairs(state.fields) do
    local memoryValue = tonumber(currentValues[index] and currentValues[index].value)
    local csvValue = memoryValue and memoryValue / field.multiplier or (row[index] or 0)
    local initialMemoryValue = tonumber(baseline[index])
      or ((tonumber(row[index]) or 0) * field.multiplier)
    if memoryValue ~= initialMemoryValue then
      changed[#changed + 1] = {
        index = field.index,
        name = field.name,
        fieldType = field.fieldType,
        multiplier = field.multiplier,
        value = csvValue
      }
    end
  end
  return changed
end

function kenkouLoadSaveIndex(character, formIndex)
  local ok, errorMessage = ensureSaveDirectory()
  if not ok then
    return nil, errorMessage
  end
  local content, readError = readFile(state.saveIndexPath)
  if not content then
    return nil, readError
  end
  local records = {}
  local lineNumber = 0
  for line in content:gmatch("[^\r\n]+") do
    lineNumber = lineNumber + 1
    if lineNumber > 1 then
      local columns = splitCsv(line)
      local unitId = tonumber(columns[2])
      local savedForm = tonumber(columns[4])
      local filename = trim(columns[1] or "")
      if filename ~= "" and unitId == character.id and savedForm == formIndex
        and not filename:find("%.%.", 1, true)
        and not filename:find("[/\\]") then
        records[#records + 1] = {
          filename = filename,
          characterId = unitId,
          characterName = columns[3] or character.name,
          formIndex = savedForm,
          formName = columns[5] or "",
          saveName = columns[6] or "",
          createdAt = columns[7] or ""
        }
      end
    end
  end
  return records
end

function kenkouReadStatusSnapshot(record)
  local path = state.saveDirectory .. "/" .. record.filename
  local content, errorMessage = readFile(path)
  if not content then
    return nil, errorMessage
  end
  local meta = {}
  local fields = {}
  for line in content:gmatch("[^\r\n]+") do
    local columns = splitCsv(line)
    if columns[1] == "META" then
      meta[columns[2]] = columns[3] or ""
    elseif columns[1] == "FIELD" then
      local index = tonumber(columns[2])
      local value = tonumber(columns[6])
      if index and value then
        fields[#fields + 1] = {
          index = index,
          name = columns[3] or "",
          fieldType = columns[4] or "number",
          multiplier = tonumber(columns[5]) or 1,
          value = value
        }
      end
    end
  end
  if meta.version ~= "KBC_STATUS_SAVE_V1" then
    return nil, "未対応のステータス保存形式です。"
  end
  return { meta = meta, fields = fields }
end

function kenkouApplyStatusSnapshot(character, formIndex, row, snapshot)
  local currentValues, errorMessage = kenkouReadFormValues(character, formIndex, row)
  if not currentValues then
    return nil, errorMessage
  end
  local writes = {}
  local seen = {}
  for _, savedField in ipairs(snapshot.fields) do
    local field = state.fields[savedField.index + 1]
    local current = currentValues[savedField.index + 1]
    if field and current and not seen[savedField.index]
      and savedField.value == savedField.value then
      local memoryValue = savedField.value * field.multiplier
      if field.fieldType == "checkbox" then
        memoryValue = savedField.value ~= 0 and field.multiplier or 0
      end
      if memoryValue ~= tonumber(current.value) then
        writes[#writes + 1] = {
          address = current.address,
          flags = gg.TYPE_DWORD,
          value = memoryValue
        }
      end
      seen[savedField.index] = true
    end
  end
  if #writes == 0 then
    return 0
  end
  gg.setValues(writes)
  return #writes
end

function kenkouSaveStatusSnapshot(character, formIndex, row)
  local directoryOk, directoryError = ensureSaveDirectory()
  if not directoryOk then
    gg.alert("保存フォルダを準備できません: " .. tostring(directoryError))
    return
  end
  local changed, errorMessage = kenkouGetChangedStatusFields(character, formIndex, row)
  if not changed then
    gg.alert(errorMessage or "現在のステータスを読み取れません。")
    return
  end
  if #changed == 0 then
    gg.alert("初期値から変更されたステータスがありません。")
    return
  end
  local input = gg.prompt({ "保存名（空欄なら保存日時）" }, { "" }, { "text" })
  if not input then
    kenkouSuspendUntilVisible()
    return
  end
  local saveName = trim(input[1] or "")
  local createdAt = os.date("%Y-%m-%d %H:%M:%S")
  local timestamp = os.date("%Y%m%d-%H%M%S")
  local formLabel = character.forms[formIndex] and character.forms[formIndex].label or ("第" .. (formIndex + 1) .. "形態")
  local suffix = saveName ~= "" and saveName or timestamp
  local filenameBase = string.format("%03d_%s(%s)__%s", character.id, character.name, formLabel, suffix)
  local filename = sanitizeFilePart(filenameBase) .. ".kbcstatus"
  local attempt = 1
  while fileExists(state.saveDirectory .. "/" .. filename) do
    attempt = attempt + 1
    filename = sanitizeFilePart(filenameBase .. "-" .. attempt) .. ".kbcstatus"
  end

  local lines = {
    "KBC_STATUS_SAVE_V1",
    table.concat({ "META", csvEscape("version"), csvEscape("KBC_STATUS_SAVE_V1") }, ","),
    table.concat({ "META", csvEscape("character_id"), csvEscape(character.id) }, ","),
    table.concat({ "META", csvEscape("character_name"), csvEscape(character.name) }, ","),
    table.concat({ "META", csvEscape("form_index"), csvEscape(formIndex) }, ","),
    table.concat({ "META", csvEscape("form_name"), csvEscape(formLabel) }, ","),
    table.concat({ "META", csvEscape("save_name"), csvEscape(saveName) }, ","),
    table.concat({ "META", csvEscape("created_at"), csvEscape(createdAt) }, ",")
  }
  for _, field in ipairs(changed) do
    lines[#lines + 1] = table.concat({ "FIELD", csvEscape(field.index), csvEscape(field.name),
      csvEscape(field.fieldType), csvEscape(field.multiplier), csvEscape(field.value) }, ",")
  end
  local ok, writeError = writeFile(state.saveDirectory .. "/" .. filename, table.concat(lines, "\n") .. "\n")
  if not ok then
    gg.alert("ステータス保存に失敗しました: " .. tostring(writeError))
    return
  end
  local indexContent = readFile(state.saveIndexPath) or "filename,character_id,character_name,form_index,form_name,save_name,created_at\n"
  indexContent = indexContent .. table.concat({ csvEscape(filename), csvEscape(character.id), csvEscape(character.name),
    csvEscape(formIndex), csvEscape(formLabel), csvEscape(saveName), csvEscape(createdAt) }, ",") .. "\n"
  local indexOk, indexError = writeFile(state.saveIndexPath, indexContent)
  if not indexOk then
    gg.alert("保存本体は作成されましたが、一覧の更新に失敗しました: " .. tostring(indexError))
    return
  end
  gg.toast("変更済みステータスを保存しました")
end

function kenkouLoadSavedStatus(character, formIndex, row)
  local records, errorMessage = kenkouLoadSaveIndex(character, formIndex)
  if not records then
    gg.alert("保存一覧を読み取れません: " .. tostring(errorMessage))
    return
  end
  if #records == 0 then
    gg.alert("このキャラ・形態の保存データはありません。")
    return
  end
  local labels = {}
  for index, record in ipairs(records) do
    local displayName = record.saveName ~= "" and record.saveName or record.createdAt
    labels[index] = displayName .. "\n" .. record.filename
  end
  local selected = kenkouChooseMenu(labels, "保存したステータスを選択", true, "kenkou-status-load")
  if not selected then
    return
  end
  local record = records[selected]
  local snapshot, readError = kenkouReadStatusSnapshot(record)
  if not snapshot then
    gg.alert("保存データを読み取れません: " .. tostring(readError))
    return
  end
  local summary = { "ステータス内容", "" }
  for _, field in ipairs(snapshot.fields) do
    summary[#summary + 1] = string.format("%s: %s", field.name, tostring(field.value))
  end
  local confirmation = gg.alert(table.concat(summary, "\n"), "はい", "いいえ")
  if confirmation ~= 1 then
    return
  end
  local applied, applyError = kenkouApplyStatusSnapshot(character, formIndex, row, snapshot)
  if applied == nil then
    gg.alert("保存データの適用に失敗しました: " .. tostring(applyError))
    return
  end
  gg.toast(string.format("保存データを読み込みました（%d項目）", applied))
end

function kenkouOpenStatusTools(character)
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
    while true do
      local action = kenkouChooseMenu(
        { "ステータス変更", "保存したステータスを読み込む", "保存", "戻る" },
        string.format("%s / 第%d形態", character.name, formIndex + 1),
        false,
        "kenkou-status-tools-" .. character.id .. "-" .. formIndex
      )
      if action == nil or action == 4 then
        break
      elseif action == 1 then
        kenkouOpenStatusEditor(character, formIndex, row)
      elseif action == 2 then
        kenkouLoadSavedStatus(character, formIndex, row)
      elseif action == 3 then
        kenkouSaveStatusSnapshot(character, formIndex, row)
      end
    end
  end
end

function kenkouGetSaveAddresses(character)
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
  if not ownershipRecord or not firstLevelRecord or not secondLevelRecord or not formRecord
    or not tables.ownershipKey or not tables.ownershipKey.address then
    return nil, string.format("%sの保存レコードを取得できません。", character.name)
  end
  return {
    saveId = saveId,
    ownership = ownershipRecord.address,
    ownershipKey = tables.ownershipKey.address,
    level = firstLevelRecord.address,
    levelMarker = secondLevelRecord.address,
    form = formRecord.address
  }
end

-- kenkou: 削除時にレベル値へ登録されている凍結を残すと、GGが直後に
-- 古い値を書き戻してしまう。個別・一括の初期化で共通利用する。
function kenkouRemoveFrozenAddresses(addressSet)
  if type(gg.getListItems) ~= "function" or type(gg.removeListItems) ~= "function" then
    return
  end
  local removals = {}
  for _, item in ipairs(gg.getListItems() or {}) do
    if addressSet[item.address] then
      removals[#removals + 1] = item
    end
  end
  if #removals > 0 then
    gg.removeListItems(removals)
  end
end

function kenkouBuildAuxiliaryOffsetCandidates(expectedOffset, stride)
  local offsets = { expectedOffset }
  local seen = { [expectedOffset] = true }
  for distance = AUXILIARY_OFFSET_SCAN_STEP, AUXILIARY_OFFSET_SCAN_RADIUS, AUXILIARY_OFFSET_SCAN_STEP do
    for _, sign in ipairs({ -1, 1 }) do
      local offset = expectedOffset + distance * sign
      if offset % stride == 0 and not seen[offset] then
        seen[offset] = true
        offsets[#offsets + 1] = offset
      end
    end
  end
  return offsets
end

function kenkouGetAuxiliarySampleIndexes(unitCount)
  local indexes = {}
  local seen = {}
  for _, index in ipairs({ 1, 2, 3, 4, 8, 16, 32, 64, math.floor(unitCount / 2), unitCount - 1, unitCount }) do
    if index >= 1 and index <= unitCount and not seen[index] then
      seen[index] = true
      indexes[#indexes + 1] = index
    end
  end
  return indexes
end

function kenkouReadUnlockedFormArray(startAddress, unitCount)
  local requests = kenkouBuildDwordRecords(startAddress, unitCount, 4)
  local values = gg.getValues(requests)
  if #values ~= unitCount then
    if not state.formAuxiliaryReadError then
      state.formAuxiliaryReadError = "unlocked-count:" .. tostring(#values)
    end
    return nil, "unlocked-count"
  end
  local result = {}
  for index, value in ipairs(values) do
    local decoded = tonumber(value.value)
    -- kenkou: ネイティブ側は0を未解放、0以外を解放済みとして判定する。
    if not decoded or decoded % 1 ~= 0 then
      if not state.formAuxiliaryReadError then
        state.formAuxiliaryReadError = string.format("unlocked-range:%d=%s", index, tostring(value.value))
      end
      return nil, string.format("unlocked-range:%d=%s", index, tostring(value.value))
    end
    result[index] = { address = startAddress + (index - 1) * 4, value = decoded }
  end
  return result
end

function kenkouReadFourthFormArray(startAddress, unitCount)
  -- kenkou: 第4形態配列も1要素4バイトの生DWORDフラグ。
  local requests = kenkouBuildDwordRecords(startAddress, unitCount, 4)
  local values = gg.getValues(requests)
  if #values ~= unitCount then
    return nil, "fourth-count"
  end
  local result = {}
  for index, value in ipairs(values) do
    local decoded = tonumber(value.value)
    if not decoded or decoded % 1 ~= 0 then
      return nil, string.format("fourth-range:%d=%s", index, tostring(decoded))
    end
    result[index] = {
      address = startAddress + (index - 1) * 4,
      value = decoded
    }
  end
  return result
end

function kenkouProbeUnlockedFormArray(startAddress, indexes)
  local requests = {}
  for _, index in ipairs(indexes) do
    requests[#requests + 1] = { address = startAddress + (index - 1) * 4, flags = gg.TYPE_DWORD }
  end
  local values = gg.getValues(requests)
  if #values ~= #indexes then
    return false
  end
  for _, value in ipairs(values) do
    local decoded = tonumber(value.value)
    if not decoded or decoded % 1 ~= 0 or decoded < 0 or decoded > 3 then
      return false
    end
  end
  return true
end

function kenkouProbeFourthFormArray(startAddress, indexes)
  local requests = {}
  for _, index in ipairs(indexes) do
    requests[#requests + 1] = { address = startAddress + (index - 1) * 4, flags = gg.TYPE_DWORD }
  end
  local values = gg.getValues(requests)
  if #values ~= #indexes then
    return false
  end
  for _, value in ipairs(values) do
    local decoded = tonumber(value.value)
    if not decoded or decoded % 1 ~= 0 then
      return false
    end
  end
  return true
end

function kenkouResolveAuxiliaryArray(startAddress, expectedOffset, unitCount, kind)
  state.formAuxiliaryReadError = nil
  local stride = kind == "fourth" and 8 or 4
  local indexes = kenkouGetAuxiliarySampleIndexes(unitCount)
  local candidates = kenkouBuildAuxiliaryOffsetCandidates(expectedOffset, stride)
  local valid = {}
  local function inspect(offset)
    local candidateAddress = startAddress + offset
    -- kenkou: 第4形態配列の検証失敗時に、通常の解放配列へ誤フォールバックしない。
    local validSample
    if kind == "fourth" then
      validSample = kenkouProbeFourthFormArray(candidateAddress, indexes)
    else
      validSample = kenkouProbeUnlockedFormArray(candidateAddress, indexes)
    end
    if validSample then
      local values, readError
      if kind == "fourth" then
        values, readError = kenkouReadFourthFormArray(candidateAddress, unitCount)
      else
        values, readError = kenkouReadUnlockedFormArray(candidateAddress, unitCount)
      end
      if values then
        return { offset = offset, address = candidateAddress, values = values }
      end
      if readError and not state.formAuxiliaryReadError then
        state.formAuxiliaryReadError = tostring(readError)
      end
    end
    return nil
  end

  -- kenkou: まず静的解析で得た位置だけを確認し、通常起動時の速度を維持する。
  local exact = inspect(expectedOffset)
  if exact then
    return exact
  end
  for _, offset in ipairs(candidates) do
    if offset ~= expectedOffset then
      local candidate = inspect(offset)
      if candidate then
        valid[#valid + 1] = candidate
      end
    end
  end
  if #valid == 0 then
    return nil, kind .. "-not-found"
  end
  table.sort(valid, function(left, right)
    return math.abs(left.offset - expectedOffset) < math.abs(right.offset - expectedOffset)
  end)
  local best = valid[1]
  if #valid > 1 and math.abs(valid[2].offset - expectedOffset) == math.abs(best.offset - expectedOffset) then
    return nil, kind .. "-ambiguous"
  end
  return best
end

function kenkouResolveFormAuxiliaryTables(addresses)
  local formArrayStart = kenkouGetFormArrayStart(addresses)
  if not formArrayStart then
    return nil, "form-array-start-unavailable"
  end
  if state.formAuxiliaryTables and state.formAuxiliaryFormStart == formArrayStart then
    return state.formAuxiliaryTables
  end
  local nativeBase = formArrayStart - NATIVE_FORM_FIELD_OFFSET
  -- kenkou: 形態解放配列は固定オフセットにある。周辺オフセットの総当たりは
  -- 無関係な整数配列を誤採用し、確認失敗と長時間検索を引き起こすため行わない。
  local unlockedAddress = nativeBase + NATIVE_UNLOCKED_FORMS_OFFSET
  local unlocked, unlockedError = kenkouReadUnlockedFormArray(
    unlockedAddress, state.characterCount
  )
  if not unlocked then
    kenkouWriteFormAuxiliaryDiagnostics(addresses, unlockedError)
    return nil, "形態解放配列を確認できません: " .. tostring(unlockedError)
  end
  local fourthAddress = nativeBase + NATIVE_FOURTH_FORM_OFFSET
  local fourth, fourthError = kenkouReadFourthFormArray(
    fourthAddress, state.characterCount
  )
  if not fourth then
    kenkouWriteFormAuxiliaryDiagnostics(addresses, fourthError)
    return nil, "第4形態配列を確認できません: " .. tostring(fourthError)
  end
  local tables = {
    unlocked = unlocked,
    fourth = fourth,
    nativeBase = nativeBase,
    unlockedOffset = NATIVE_UNLOCKED_FORMS_OFFSET,
    fourthOffset = NATIVE_FOURTH_FORM_OFFSET
  }
  state.formAuxiliaryTables = tables
  state.formAuxiliaryFormStart = formArrayStart
  return tables
end

function kenkouUnlockCharacter(character)
  if not OWNERSHIP_EDITING_ENABLED then
    gg.alert("キャラ解放は現在の保存レイアウトで無効化されています。")
    return
  end
  local addresses, errorMessage = kenkouGetSaveAddresses(character)
  if not addresses then
    gg.alert(errorMessage)
    return
  end
  local values = gg.getValues({
    { address = addresses.ownershipKey, flags = gg.TYPE_DWORD },
    { address = addresses.ownership, flags = gg.TYPE_DWORD }
  })
  if not values[1] or values[1].value == nil or not values[2] then
    gg.alert("キャラ解放値を読み取れません。")
    return
  end
  local currentValue = kenkouXorDword(values[2].value, values[1].value)
  if currentValue ~= 0 and currentValue ~= 1 then
    gg.alert("キャラ解放の所持フラグを検証できません。")
    return
  end
  if currentValue == 1 then
    gg.toast(character.name .. "は既に解放済みです")
    return
  end
  local confirmation = gg.alert(character.name .. "を解放しますか？", "はい", "いいえ")
  if confirmation ~= 1 then
    return
  end
  local ownedValue = kenkouGetOwnedOwnershipValue(values[1].value, character.id)
  if ownedValue == nil then
    gg.alert("キャラ解放値をエンコードできません。")
    return
  end
  gg.setValues({
    {
      address = addresses.ownership,
      flags = gg.TYPE_DWORD,
      value = ownedValue
    }
  })
  local verified = gg.getValues({
    { address = addresses.ownership, flags = gg.TYPE_DWORD },
    { address = addresses.ownershipKey, flags = gg.TYPE_DWORD }
  })
  if not verified[1] or not verified[2]
    or not kenkouIsCharacterOwned(verified[1].value, verified[2].value, character.id) then
    gg.alert(character.name .. "の解放後の確認値が一致しませんでした。")
    return
  end
  gg.toast(character.name .. "を解放しました")
end

function kenkouDeleteCharacter(character)
  if not OWNERSHIP_EDITING_ENABLED then
    gg.alert("キャラ削除は現在の保存レイアウトで無効化されています。")
    return
  end
  local addresses, errorMessage = kenkouGetSaveAddresses(character)
  if not addresses then
    gg.alert(errorMessage)
    return
  end
  if addresses.saveId == 1 then
    gg.alert("ネコは削除できません。")
    return
  end
  local values = gg.getValues({
    { address = addresses.ownershipKey, flags = gg.TYPE_DWORD },
    { address = addresses.ownership, flags = gg.TYPE_DWORD }
  })
  if not values[1] or values[1].value == nil or not values[2] then
    gg.alert("キャラ削除値を読み取れません。")
    return
  end
  local ownershipKey = values[1].value
  local currentValue = tonumber(values[2].value)
  if ownershipKey == nil or currentValue == nil then
    gg.alert("キャラ所持値を判定できません。")
    return
  end
  local decodedOwnership = kenkouXorDword(currentValue, ownershipKey)
  if decodedOwnership ~= 0 and decodedOwnership ~= 1 then
    gg.alert("キャラ削除の所持フラグを検証できません。")
    return
  end
  if decodedOwnership == 0 then
    gg.toast(character.name .. "は既に未開放です")
    return
  end
  local unownedValue = kenkouGetUnownedOwnershipValue(ownershipKey)
  if unownedValue == nil then
    gg.alert("キャラ削除値をエンコードできません。")
    return
  end
  local confirmation = gg.alert(
    character.name .. "を削除しますか？\n所持フラグのみを変更します。レベル・形態は変更しません。",
    "はい", "いいえ"
  )
  if confirmation ~= 1 then
    return
  end

  gg.setValues({
    {
      address = addresses.ownership,
      flags = gg.TYPE_DWORD,
      value = unownedValue,
      name = string.format("%03d %s | 所有（削除）", character.id, character.name)
    }
  })
  kenkouSafeSleep(50)
  local verified = gg.getValues({
    { address = addresses.ownership, flags = gg.TYPE_DWORD },
    { address = addresses.ownershipKey, flags = gg.TYPE_DWORD }
  })
  if not verified[1] or tonumber(verified[1].value) ~= unownedValue
    or not verified[2]
    or kenkouXorDword(verified[1].value, verified[2].value) ~= 0 then
    gg.alert(character.name .. "の削除後の確認値が一致しませんでした。")
    return
  end
  gg.toast(character.name .. "を削除しました")
end

function kenkouRemoveLevelListItems(addresses)
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

function kenkouChangeLevel(character, preset)
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

  local input
  if preset then
    input = {
      string.format("%d", math.floor(tonumber(preset.level) or currentLevel)),
      string.format("%d", math.floor(tonumber(preset.plus) or currentPlus)),
      preset.freeze == true
    }
  else
    input = gg.prompt(
    { "レベル", "プラス値", "凍結" },
    { string.format("%d", math.floor(currentLevel)), string.format("%d", math.floor(currentPlus)), true },
      { "number", "number", "checkbox" }
    )
  end
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
  if level - 1 > MAX_LEVEL_COMPONENT then
    gg.alert(string.format("レベルは%d以下で入力してください。", MAX_LEVEL_COMPONENT + 1))
    return
  end
  if not plus or plus % 1 ~= 0 or plus < 0 or plus > MAX_LEVEL_COMPONENT then
    gg.alert(string.format("プラス値は0〜%dの整数で入力してください。", MAX_LEVEL_COMPONENT))
    return
  end

  -- kenkou: 現在のランダムマスクを保持し、先頭DWORDだけを新しいpacked値へ合わせる。
  local encodedValue, markerValue = kenkouEncodeLevel(level, plus, currentValues[2].value)
  if encodedValue == nil or markerValue == nil then
    gg.alert("レベル値をエンコードできません。")
    return
  end
  local writes = {
    {
      address = addresses.level,
      flags = gg.TYPE_DWORD,
      value = encodedValue,
      name = string.format("%03d %s | レベル", character.id, character.name)
    },
    {
      address = addresses.levelMarker,
      flags = gg.TYPE_DWORD,
      value = markerValue,
      name = string.format("%03d %s | レベルマスク", character.id, character.name)
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
  kenkouSafeSleep(50)
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

function kenkouReadCharacterState(character)
  local addresses, errorMessage = kenkouGetSaveAddresses(character)
  if not addresses then
    return nil, errorMessage
  end
  local values = gg.getValues({
    { address = addresses.ownership, flags = gg.TYPE_DWORD },
    { address = addresses.ownershipKey, flags = gg.TYPE_DWORD },
    { address = addresses.level, flags = gg.TYPE_DWORD },
    { address = addresses.levelMarker, flags = gg.TYPE_DWORD },
    { address = addresses.form, flags = gg.TYPE_DWORD }
  })
  if not values[1] or not values[2] or not values[3] or not values[4] or not values[5] then
    return nil, "キャラ保存状態を読み取れません。"
  end
  local currentLevel, currentPlus = kenkouDecodeLevel(values[3].value, values[4].value)
  local currentForm = tonumber(values[5].value) or 0
  currentForm = math.max(0, math.min(3, math.floor(currentForm)))
  local currentOwnership = tonumber(values[1].value)
  local ownershipKey = tonumber(values[2].value)
  if currentOwnership == nil or ownershipKey == nil then
    return nil, "キャラ所有状態を復号できません。"
  end
  return {
    addresses = addresses,
    currentOwnership = currentOwnership,
    ownershipKey = ownershipKey,
    unlocked = kenkouIsCharacterOwned(currentOwnership, ownershipKey, character.id),
    level = currentLevel or 1,
    plus = currentPlus or 0,
    form = currentForm
  }
end

function kenkouGetFormCount(character)
  local maxIndex = -1
  for formIndex in pairs(character.forms) do
    maxIndex = math.max(maxIndex, formIndex)
  end
  return math.min(4, maxIndex + 1)
end

function kenkouOpenUnlockControl(character)
  local characterState, errorMessage = kenkouReadCharacterState(character)
  if not characterState then
    gg.alert(errorMessage or "キャラ保存状態を読み取れません。")
    return
  end
  local statusLabel = characterState.unlocked and "解放" or "未開放"
  local action = kenkouChooseMenu(
    { "〇 解放", "〇 削除", "戻る" },
    "現在の状態: " .. statusLabel,
    false,
    "kenkou-unlock-control-" .. character.id
  )
  if action == 1 then
    kenkouUnlockCharacter(character)
  elseif action == 2 then
    kenkouDeleteCharacter(character)
  end
end

function kenkouChangeCurrentFormV2(character, selectedForm)
  local addresses, errorMessage = kenkouGetSaveAddresses(character)
  if not addresses then
    gg.alert(errorMessage or "形態の保存アドレスを取得できません。")
    return
  end
  selectedForm = tonumber(selectedForm)
  if not selectedForm or selectedForm < 0 or selectedForm > 3 or selectedForm % 1 ~= 0 then
    gg.alert("形態番号が不正です。")
    return
  end
  local currentValues = gg.getValues({
    { address = addresses.form, flags = gg.TYPE_DWORD }
  })
  local currentForm = currentValues[1] and tonumber(currentValues[1].value) or 0
  currentForm = math.max(0, math.min(3, math.floor(currentForm)))
  if selectedForm == currentForm then
    gg.toast(string.format("現在の形態は第%d形態です。", selectedForm + 1))
    return
  end
  local confirmation = gg.alert(
    string.format("%sを第%d形態へ変更しますか？\n※解放状態は変更しません。", character.name, selectedForm + 1),
    "はい", "いいえ"
  )
  if confirmation ~= 1 then
    return
  end
  gg.setValues({
    { address = addresses.form, flags = gg.TYPE_DWORD, value = selectedForm }
  })
  kenkouSafeSleep(50)
  local verified = gg.getValues({
    { address = addresses.form, flags = gg.TYPE_DWORD }
  })
  if not verified[1] or tonumber(verified[1].value) ~= selectedForm then
    gg.alert("現在形態の変更を確認できませんでした。")
    return
  end
  gg.toast(string.format("%sを第%d形態へ変更しました。解放状態は変更していません。",
    character.name, selectedForm + 1))
end

function kenkouFormUnlockPlaceholderV2(character, actionName)
  -- kenkou: 解放形態配列は現在形態配列とは別の保存フィールドであり、未確認のアドレスへ書き込まない。
  gg.alert(string.format("形態%sは、解放形態配列を確認後に実装します。\n現在形態の変更は解放状態を変更しません。", actionName))
end

-- kenkou: 形態解放・削除は現在形態とは別配列を更新する。既存の旧関数名を残し、
-- UIとの互換性を保ったまま検証済みの補助配列へ書き込む。
-- 実機検証用に残す旧候補。UIからは呼び出さない。
function kenkouFormUnlockExperimentalProtectedV1(character, actionName)
  local addresses, errorMessage = kenkouGetSaveAddresses(character)
  if not addresses then
    gg.alert(errorMessage or "form address is unavailable")
    return
  end
  local selectedForm = tonumber(rawget(_G, "kenkouSelectedFormV2"))
  if not selectedForm or selectedForm < 0 or selectedForm > 3 or selectedForm % 1 ~= 0 then
    gg.alert("Select a form first")
    return
  end
  local auxiliary, auxiliaryError = kenkouResolveFormAuxiliaryTables(addresses)
  if not auxiliary then
    gg.alert(auxiliaryError)
    return
  end
  -- kenkou: 固定オフセット版の補助配列は、配列本体を直接返す。
  -- 旧探索版の `.values` を参照すると nil を添字にして落ちる。
  local unlockedRecord = auxiliary.unlocked[addresses.saveId]
  local fourthRecord = auxiliary.fourth[addresses.saveId]
  if not unlockedRecord or not fourthRecord then
    gg.alert("Form records are unavailable")
    return
  end
  local fourthMarkerAddress = fourthRecord.markerAddress
  if type(fourthMarkerAddress) ~= "number" and type(fourthRecord.address) == "number" then
    fourthMarkerAddress = fourthRecord.address + 4
  end
  if type(unlockedRecord.address) ~= "number"
    or type(fourthRecord.address) ~= "number"
    or type(fourthMarkerAddress) ~= "number"
    or type(addresses.form) ~= "number" then
    gg.alert(string.format(
      "形態レコードのアドレスが不正です。\nunlocked=%s\nfourth=%s\nmarker=%s\ncurrent=%s",
      tostring(unlockedRecord.address), tostring(fourthRecord.address),
      tostring(fourthMarkerAddress), tostring(addresses.form)))
    return
  end
  local currentValues = gg.getValues({
    { address = unlockedRecord.address, flags = gg.TYPE_DWORD },
    { address = fourthRecord.address, flags = gg.TYPE_DWORD },
    { address = fourthMarkerAddress, flags = gg.TYPE_DWORD },
    { address = addresses.form, flags = gg.TYPE_DWORD }
  })
  local currentUnlocked = tonumber(currentValues[1] and currentValues[1].value)
  local currentFourth = currentValues[2] and currentValues[3]
    and kenkouDecodeProtectedValue(currentValues[2].value, currentValues[3].value)
  local currentForm = tonumber(currentValues[4] and currentValues[4].value) or 0
  if not currentUnlocked or currentUnlocked < 0 or currentUnlocked > 3
    or currentFourth == nil or (currentFourth ~= 0 and currentFourth ~= 2) then
    gg.alert("Form auxiliary values failed validation; no memory was changed")
    return
  end

  local newUnlocked = currentUnlocked
  local newFourth = currentFourth
  local newCurrentForm = currentForm
  if actionName == "解放" then
    if selectedForm == 3 then
      -- kenkou: 第4形態は第1〜第3形態も累積解放する。現在形態は変更しない。
      newUnlocked = 3
      newFourth = 2
    else
      newUnlocked = math.max(currentUnlocked, selectedForm + 1)
    end
  elseif actionName == "削除" then
    if selectedForm == 3 then
      newFourth = 0
      newCurrentForm = math.min(newCurrentForm, 2)
    else
      -- kenkou: 第3形態以下の削除は真形態全体を戻す。
      newUnlocked = 0
      newFourth = 0
      newCurrentForm = math.min(newCurrentForm, 1)
    end
  else
    gg.alert("Unknown form action")
    return
  end

  local question = actionName == "解放"
    and string.format("%sの第%d形態を解放しますか？", character.name, selectedForm + 1)
    or string.format("%sの第%d形態を削除しますか？", character.name, selectedForm + 1)
  if gg.alert(question, "はい", "いいえ") ~= 1 then
    return
  end

  local writes = {}
  if newUnlocked ~= currentUnlocked then
    writes[#writes + 1] = {
      address = unlockedRecord.address,
      flags = gg.TYPE_DWORD,
      value = newUnlocked,
      name = string.format("%03d %s | unlocked_forms", character.id, character.name)
    }
  end
  if newFourth ~= currentFourth then
    local encodedFourth = kenkouEncodeProtectedValue(newFourth, currentValues[3].value)
    if encodedFourth == nil then
      gg.alert("第4形態値のエンコードに失敗しました。")
      return
    end
    writes[#writes + 1] = {
      address = fourthRecord.address,
      flags = gg.TYPE_DWORD,
      value = encodedFourth,
      name = string.format("%03d %s | fourth_form", character.id, character.name)
    }
  end
  if newCurrentForm ~= currentForm then
    writes[#writes + 1] = {
      address = addresses.form,
      flags = gg.TYPE_DWORD,
      value = newCurrentForm,
      name = string.format("%03d %s | current_form", character.id, character.name)
    }
  end
  if #writes == 0 then
    gg.toast("指定した形態は既にその状態です。")
    return
  end
  gg.setValues(writes)
  kenkouSafeSleep(50)
  local verified = gg.getValues({
    { address = unlockedRecord.address, flags = gg.TYPE_DWORD },
    { address = fourthRecord.address, flags = gg.TYPE_DWORD },
    { address = fourthMarkerAddress, flags = gg.TYPE_DWORD },
    { address = addresses.form, flags = gg.TYPE_DWORD }
  })
  local verifiedFourth = verified[2] and verified[3]
    and kenkouDecodeProtectedValue(verified[2].value, verified[3].value)
  if not verified[1] or tonumber(verified[1].value) ~= newUnlocked
    or verifiedFourth ~= newFourth
    or not verified[4] or tonumber(verified[4].value) ~= newCurrentForm then
    gg.alert("形態の解放・削除を書き込みましたが、確認値が一致しませんでした。")
    return
  end
  gg.toast(string.format("%s form %d: %s", character.name, selectedForm + 1, actionName))
end

-- kenkou: v15.5.1の形態解放処理。第3/第4形態フラグを生DWORDとして扱う。
-- 既存の暗号化補助配列版を残しつつ、実行時はこちらを使用する。
-- 実機検証用に残す別候補。UIからは呼び出さない。
function kenkouFormUnlockExperimentalFlagsV2(character, actionName)
  local addresses, errorMessage = kenkouGetSaveAddresses(character)
  if not addresses then
    gg.alert(errorMessage or "form address is unavailable")
    return
  end
  local selectedForm = tonumber(rawget(_G, "kenkouSelectedFormV2"))
  if not selectedForm or selectedForm < 0 or selectedForm > 3 or selectedForm % 1 ~= 0 then
    gg.alert("Select a form first")
    return
  end
  if selectedForm < 2 then
    gg.alert("第1・第2形態には個別の解放フラグはありません。")
    return
  end

  local auxiliary, auxiliaryError = kenkouResolveFormAuxiliaryTables(addresses)
  if not auxiliary then
    gg.alert(auxiliaryError)
    return
  end
  -- kenkou: 固定オフセット版の補助配列は、配列本体を直接返す。
  local unlockedRecord = auxiliary.unlocked[addresses.saveId]
  local fourthRecord = auxiliary.fourth[addresses.saveId]
  if not unlockedRecord or not fourthRecord then
    gg.alert("Form records are unavailable")
    return
  end

  local currentValues = gg.getValues({
    { address = unlockedRecord.address, flags = gg.TYPE_DWORD },
    { address = fourthRecord.address, flags = gg.TYPE_DWORD },
    { address = addresses.form, flags = gg.TYPE_DWORD }
  })
  local currentThirdRaw = tonumber(currentValues[1] and currentValues[1].value)
  local currentFourthRaw = tonumber(currentValues[2] and currentValues[2].value)
  local currentForm = tonumber(currentValues[3] and currentValues[3].value) or 0
  local operationLog = {
    "version=form-operation-debug-v1",
    "action=" .. tostring(actionName),
    "character-id=" .. tostring(character.id),
    "save-id=" .. tostring(addresses.saveId),
    "selected-form=" .. tostring(selectedForm),
    "third-address=" .. kenkouFormatAddress(unlockedRecord.address),
    "fourth-address=" .. kenkouFormatAddress(fourthRecord.address),
    "current-form-address=" .. kenkouFormatAddress(addresses.form),
    "current-third=" .. tostring(currentThirdRaw),
    "current-fourth=" .. tostring(currentFourthRaw),
    "current-form=" .. tostring(currentForm)
  }
  kenkouWriteFormOperationDiagnostics(operationLog)
  if currentThirdRaw == nil or currentFourthRaw == nil then
    gg.alert("形態解放フラグを読み込めませんでした。")
    return
  end
  currentForm = math.max(0, math.min(3, math.floor(currentForm)))

  local currentThird = currentThirdRaw ~= 0 and 1 or 0
  local currentFourth = currentFourthRaw ~= 0 and 1 or 0
  local newThird, newFourth = currentThird, currentFourth
  local newCurrentForm = currentForm
  if actionName == "解放" then
    if selectedForm == 2 then
      newThird = 1
    else
      -- 第4形態を解放する場合は、第3形態も自動的に解放する。
      newThird, newFourth = 1, 1
    end
  elseif actionName == "削除" then
    if selectedForm == 2 then
      -- 第3形態を削除すると、第4形態も無効にする。
      newThird, newFourth = 0, 0
      newCurrentForm = math.min(newCurrentForm, 1)
    else
      newFourth = 0
      newCurrentForm = math.min(newCurrentForm, 2)
    end
  else
    gg.alert("Unknown form action")
    return
  end

  local question = actionName == "解放"
    and string.format("%sの第%d形態を解放しますか？", character.name, selectedForm + 1)
    or string.format("%sの第%d形態を削除しますか？", character.name, selectedForm + 1)
  if gg.alert(question, "はい", "いいえ") ~= 1 then
    return
  end

  local writes = {}
  if newThird ~= currentThird then
    writes[#writes + 1] = {
      address = unlockedRecord.address,
      flags = gg.TYPE_DWORD,
      value = newThird,
      name = string.format("%03d %s | form3_unlocked", character.id, character.name)
    }
  end
  if newFourth ~= currentFourth then
    writes[#writes + 1] = {
      address = fourthRecord.address,
      flags = gg.TYPE_DWORD,
      value = newFourth,
      name = string.format("%03d %s | form4_unlocked", character.id, character.name)
    }
  end
  if newCurrentForm ~= currentForm then
    writes[#writes + 1] = {
      address = addresses.form,
      flags = gg.TYPE_DWORD,
      value = newCurrentForm,
      name = string.format("%03d %s | current_form", character.id, character.name)
    }
  end
  if #writes == 0 then
    gg.toast("指定した形態は既にその状態です。")
    return
  end

  gg.setValues(writes)
  kenkouSafeSleep(50)
  local verified = gg.getValues({
    { address = unlockedRecord.address, flags = gg.TYPE_DWORD },
    { address = fourthRecord.address, flags = gg.TYPE_DWORD },
    { address = addresses.form, flags = gg.TYPE_DWORD }
  })
  local verifiedThird = tonumber(verified[1] and verified[1].value)
  local verifiedFourth = tonumber(verified[2] and verified[2].value)
  local verifiedForm = tonumber(verified[3] and verified[3].value)
  operationLog[#operationLog + 1] = "new-third=" .. tostring(newThird)
  operationLog[#operationLog + 1] = "new-fourth=" .. tostring(newFourth)
  operationLog[#operationLog + 1] = "new-form=" .. tostring(newCurrentForm)
  operationLog[#operationLog + 1] = "verified-third=" .. tostring(verifiedThird)
  operationLog[#operationLog + 1] = "verified-fourth=" .. tostring(verifiedFourth)
  operationLog[#operationLog + 1] = "verified-form=" .. tostring(verifiedForm)
  kenkouWriteFormOperationDiagnostics(operationLog)
  if verifiedThird == nil or (verifiedThird ~= newThird and (verifiedThird ~= 0) ~= (newThird ~= 0))
    or verifiedFourth == nil or (verifiedFourth ~= newFourth and (verifiedFourth ~= 0) ~= (newFourth ~= 0))
    or verifiedForm ~= newCurrentForm then
    gg.alert("形態解放状態を書き換えましたが、確認値が一致しませんでした。")
    return
  end
  gg.toast(string.format("%s 第%d形態: %s", character.name, selectedForm + 1, actionName))
end

-- arm64 v15.5.1 では第三・第四形態の解放情報は SAVE_DATA の
-- 所有/レベル/現在形態の3配列とは別の管理領域にあります。従来の推定
-- オフセットへ書き込むとゲームを落とすため、確定するまで解放操作は
-- メモリを変更せず安全に停止する。現在形態の切替は別処理で利用できる。
function kenkouFormUnlockNotReadyV2(character, actionName)
  gg.alert("形態解放の保存領域はこのバージョンで未確定です。\n安全のためメモリは変更しません。\n「形態変更」は現在形態の切替として利用できます。")
end

function kenkouSelectForcedForm(character, characterState)
  local formCount = kenkouGetFormCount(character)
  local prompts, defaults, types = {}, {}, {}
  for formIndex = 0, formCount - 1 do
    prompts[#prompts + 1] = string.format("第%d %s", formIndex + 1, character.forms[formIndex].label)
    defaults[#defaults + 1] = formIndex == characterState.form
    types[#types + 1] = "checkbox"
  end
  local input = gg.prompt(
    prompts,
    defaults,
    types,
    string.format("%s / 形態を強制\n現在: 第%d形態", kenkouGetCharacterName(character), characterState.form + 1)
  )
  if not input then
    kenkouSuspendUntilVisible()
    return nil
  end

  -- 複数チェック時は、従来どおり最大の形態番号を採用する。
  local selectedForm = nil
  for formIndex = 0, formCount - 1 do
    if input[formIndex + 1] == true then
      selectedForm = formIndex
    end
  end
  if selectedForm == nil then
    gg.alert("形態を1つ以上選択してください。")
    return nil
  end
  return selectedForm
end

function kenkouOpenFormControlMenuV2(character)
  local characterState, errorMessage = kenkouReadCharacterState(character)
  if not characterState then
    gg.alert(errorMessage or "キャラ保存状態を読み込めません。")
    return
  end
  local formCount = kenkouGetFormCount(character)
  if formCount < 1 then
    gg.alert("選択可能な形態がありません。")
    return
  end

  local action = kenkouChooseMenu(
    { "形態を強制", "そのキャラの最大", "戻る" },
    string.format("%s / 形態指定\n現在: 第%d形態", kenkouGetCharacterName(character), characterState.form + 1),
    false,
    "kenkou-form-mode-" .. character.id
  )
  if action == 1 then
    local selectedForm = kenkouSelectForcedForm(character, characterState)
    if selectedForm ~= nil then
      kenkouChangeCurrentFormV2(character, selectedForm)
    end
  elseif action == 2 then
    -- 「最大」はunit-index.csvに存在する最終形態を指す。解放状態は変更しない。
    kenkouChangeCurrentFormV2(character, formCount - 1)
  end
end

function kenkouConfirmAllTarget()
  return gg.alert(
    "全キャラを対象にします。\n操作には危険があります。\n注意してください。\n\n続行すると複数の保存値を一括変更します。",
    "続行", "キャンセル"
  ) == 1
end

function kenkouSetValuesInChunks(writes, chunkSize)
  chunkSize = chunkSize or 256
  local startIndex = 1
  while startIndex <= #writes do
    local batch = {}
    local endIndex = math.min(#writes, startIndex + chunkSize - 1)
    for index = startIndex, endIndex do
      batch[#batch + 1] = writes[index]
    end
    gg.setValues(batch)
      kenkouSafeSleep(25)
    startIndex = endIndex + 1
  end
end

function kenkouGetValuesInChunks(records, chunkSize)
  chunkSize = chunkSize or 256
  local values = {}
  local startIndex = 1
  while startIndex <= #records do
    local endIndex = math.min(#records, startIndex + chunkSize - 1)
    local batch = {}
    for index = startIndex, endIndex do
      batch[#batch + 1] = records[index]
    end
    local batchValues = gg.getValues(batch)
    if #batchValues ~= #batch then
      return nil, #values + #batchValues, #records
    end
    for _, value in ipairs(batchValues) do
      values[#values + 1] = value
    end
    startIndex = endIndex + 1
  end
  return values, #values, #records
end

function kenkouAddListItemsInChunks(items, chunkSize)
  if type(gg.addListItems) ~= "function" then
    return
  end
  chunkSize = chunkSize or 256
  local startIndex = 1
  while startIndex <= #items do
    local endIndex = math.min(#items, startIndex + chunkSize - 1)
    local batch = {}
    for index = startIndex, endIndex do
      batch[#batch + 1] = items[index]
    end
    gg.addListItems(batch)
    startIndex = endIndex + 1
  end
end

function kenkouReadAllOwnershipValues(tables)
  -- kenkou: 現行 SAVE_DATA の所有状態は `raw XOR key` で0/1になる。
  -- 旧ID表（IDまたは0xffffffff）をここへ混ぜると誤って別配列を更新する。
  local values, readCount, expectedCount = kenkouGetValuesInChunks(tables.ownership)
  if not values then
    return nil, string.format("所有配列の読み取り件数が不一致です（%d/%d）。",
      readCount or 0, expectedCount or tables.unitCount)
  end
  local keyValues = gg.getValues({ tables.ownershipKey })
  local ownershipKey = keyValues[1] and keyValues[1].value
  if ownershipKey == nil then
    return nil, "所有配列のXORキーを読み取れません。"
  end
  for saveId, value in ipairs(values) do
    local decoded = kenkouXorDword(value.value, ownershipKey)
    if decoded ~= 0 and decoded ~= 1 then
      return nil, string.format("所有配列の復号値が不正です（ID %d: %s）。", saveId - 1, tostring(decoded))
    end
  end
  return values, ownershipKey
end

-- kenkou: 一括削除で使うレベル・現在形態配列を、GameGuardianの件数制限を
-- 避けながら先に読み取る。処理本体から分離してLuaJのローカル上限を抑える。
function kenkouReadAllDeleteArrays(tables)
  local levelValues, levelReadCount, levelExpected = kenkouGetValuesInChunks(tables.level)
  if not levelValues then
    return nil, string.format("一括削除用のレベル配列を読み取れません（%d/%d）。",
      levelReadCount or 0, levelExpected or #tables.level)
  end
  local formValues, formReadCount, formExpected = kenkouGetValuesInChunks(tables.form)
  if not formValues then
    return nil, string.format("一括削除用の形態配列を読み取れません（%d/%d）。",
      formReadCount or 0, formExpected or #tables.form)
  end
  return { level = levelValues, form = formValues }
end

-- kenkou: 一括削除用の書き込み計画を作る。計画作成だけを別関数にして、
-- 実際の確認ダイアログ・書き込み・検証の関数を小さく保つ。
function kenkouBuildAllDeletePlan(tables, ownershipValues, ownershipKey)
  local formValues, formReadCount, formExpected = kenkouGetValuesInChunks(tables.form)
  if not formValues then
    return nil, string.format("一括削除用の形態配列を読み取れません（%d/%d）。",
      formReadCount or 0, formExpected or #tables.form)
  end
  local writes, verification = {}, {}
  local ownershipWriteCount, formWriteCount = 0, 0
  local targetValue = kenkouGetUnownedOwnershipValue(ownershipKey)
  if targetValue == nil then
    return nil, "一括削除用の所有値をエンコードできません。"
  end
  for saveId = 2, tables.unitCount do
    local ownershipRecord = tables.ownership[saveId]
    local ownershipValue = ownershipValues[saveId] and tonumber(ownershipValues[saveId].value)
    if ownershipRecord and ownershipValue ~= tonumber(targetValue) then
      writes[#writes + 1] = {
        address = ownershipRecord.address,
        flags = gg.TYPE_DWORD,
        value = targetValue,
        name = "全キャラ 削除 | 所有"
      }
      verification[#verification + 1] = { record = ownershipRecord, expected = targetValue }
      ownershipWriteCount = ownershipWriteCount + 1
    end
    local formRecord = tables.form[saveId]
    local currentForm = formValues[saveId] and tonumber(formValues[saveId].value)
    if not formRecord or currentForm == nil or currentForm < 0 or currentForm > 3 or currentForm % 1 ~= 0 then
      return nil, string.format("保存ID %d の現在形態を検証できません。", saveId)
    end
    if currentForm ~= 0 then
      writes[#writes + 1] = {
        address = formRecord.address,
        flags = gg.TYPE_DWORD,
        value = 0,
        name = "全キャラ 削除 | 現在形態を第1形態へ変更"
      }
      verification[#verification + 1] = { record = formRecord, expected = 0 }
      formWriteCount = formWriteCount + 1
    end
  end
  return {
    writes = writes,
    verification = verification,
    ownershipWriteCount = ownershipWriteCount,
    formWriteCount = formWriteCount
  }
end

function kenkouWriteAllOwnershipDiagnostics(tables, actionName, values, ownershipKey, writes)
  if not state.rootDirectory or not tables or not values then
    return
  end
  local path = state.rootDirectory .. "/all-ownership-debug.txt"
  local file = io.open(path, "w")
  if not file then
    return
  end
  local firstValue = values[1] and values[1].value
  local lastValue = values[tables.unitCount] and values[tables.unitCount].value
  local lines = {
    "version=all-ownership-debug-v3-xor-key",
    "action=" .. tostring(actionName),
    "unit-count=" .. tostring(tables.unitCount),
    "ownership-key=" .. tostring(ownershipKey),
    "first-value=" .. tostring(firstValue),
    "last-value=" .. tostring(lastValue),
    "write-count=" .. tostring(#writes),
    "first-address=" .. kenkouFormatAddress(tables.ownership[1].address),
    "last-address=" .. kenkouFormatAddress(tables.ownership[tables.unitCount].address)
  }
  local sampleIndexes = { 1, 2, 3, 4, 5, tables.unitCount - 2, tables.unitCount - 1, tables.unitCount }
  local seen = {}
  for _, saveId in ipairs(sampleIndexes) do
    if saveId >= 1 and saveId <= tables.unitCount and not seen[saveId] then
      seen[saveId] = true
      lines[#lines + 1] = string.format("id=%d,value=%s", saveId - 1, tostring(values[saveId].value))
    end
  end
  file:write(table.concat(lines, "\n"), "\n")
  file:close()
end

function kenkouApplyAllOwnership(actionName)
  if not OWNERSHIP_EDITING_ENABLED then
    gg.alert("全キャラの解放・削除は現在の保存レイアウトで無効化されています。")
    return
  end
  local tables, errorMessage = kenkouResolveSaveCharacterTables()
  if not tables then
    gg.alert(errorMessage or "保存配列を確認できません。")
    return
  end
  local values, ownershipKey = kenkouReadAllOwnershipValues(tables)
  if not values then
    gg.alert(ownershipKey or "所有配列を読み取れません。")
    return
  end
  local writes, verification = {}, {}
  local ownershipWriteCount, formWriteCount = 0, 0

  if actionName == "削除" then
    local plan, planError = kenkouBuildAllDeletePlan(tables, values, ownershipKey)
    if not plan then
      gg.alert(planError or "一括削除の計画を作成できません。")
      return
    end
    writes = plan.writes
    verification = plan.verification
    ownershipWriteCount = plan.ownershipWriteCount
    formWriteCount = plan.formWriteCount
  else
    for saveId = 2, tables.unitCount do
      local record = tables.ownership[saveId]
      local currentValue = values[saveId] and tonumber(values[saveId].value)
      local targetValue = kenkouGetOwnedOwnershipValue(ownershipKey, saveId - 1)
      if record and currentValue ~= tonumber(targetValue) then
        writes[#writes + 1] = {
          address = record.address,
          flags = gg.TYPE_DWORD,
          value = targetValue,
          name = "全キャラ 解放 | 所有"
        }
        verification[#verification + 1] = { record = record, expected = targetValue }
        ownershipWriteCount = ownershipWriteCount + 1
      end
    end
  end
  kenkouWriteAllOwnershipDiagnostics(tables, actionName, values, ownershipKey, writes)
  if #writes == 0 then
    gg.toast("対象キャラは既に指定状態です。")
    return
  end
  local question = actionName == "解放"
    and string.format("全キャラ（%d件）を解放しますか？", ownershipWriteCount)
    or string.format("全キャラ（%d件）を削除しますか？\nネコは保護します。\n現在形態 %d件を第1形態へ戻します。\nレベル・プラス値は保持します。", ownershipWriteCount, formWriteCount)
  if gg.alert(question, "はい", "いいえ") ~= 1 then
    return
  end
  kenkouSetValuesInChunks(writes)
  kenkouSafeSleep(80)
  local recordsToVerify = {}
  for _, item in ipairs(verification) do
    recordsToVerify[#recordsToVerify + 1] = item.record
  end
  local verified, verifiedCount, verifiedExpected = kenkouGetValuesInChunks(recordsToVerify)
  if not verified then
    gg.alert(string.format("一括%s後の確認件数が不一致です（%d/%d）。", actionName, verifiedCount, verifiedExpected))
    return
  end
  for index, value in ipairs(verified) do
    local expected = verification[index] and verification[index].expected
    if expected == nil or tonumber(value.value) ~= tonumber(expected) then
      gg.alert(string.format("一括%s後の確認値が一致しません（%d件目）。", actionName, index))
      return
    end
  end
  if actionName == "削除" then
    gg.toast(string.format("%d体を削除し、%d体を第1形態へ戻しました。", ownershipWriteCount, formWriteCount))
  else
    gg.toast(string.format("%d体を解放しました。", ownershipWriteCount))
  end
end

function kenkouGetAllLevelInput(tables)
  local firstValue = gg.getValues({ tables.level[1], tables.level[2] })
  local level, plus = kenkouDecodeLevel(
    firstValue[1] and firstValue[1].value,
    firstValue[2] and firstValue[2].value
  )
  level = math.floor(tonumber(level) or 1)
  plus = math.floor(tonumber(plus) or 0)
  local input = gg.prompt(
    { "全キャラのレベル", "全キャラのプラス値", "凍結（初期オフ）" },
    { string.format("%d", level), string.format("%d", plus), false },
    { "number", "number", "checkbox" }
  )
  if not input then
    kenkouSuspendUntilVisible()
    return nil
  end
  local newLevel, newPlus = tonumber(input[1]), tonumber(input[2])
  if not newLevel or newLevel % 1 ~= 0 or newLevel < 1 or newLevel - 1 > MAX_LEVEL_COMPONENT then
    gg.alert(string.format("レベルは1〜%dの整数で入力してください。", MAX_LEVEL_COMPONENT + 1))
    return nil
  end
  if not newPlus or newPlus % 1 ~= 0 or newPlus < 0 or newPlus > MAX_LEVEL_COMPONENT then
    gg.alert(string.format("プラス値は0〜%dの整数で入力してください。", MAX_LEVEL_COMPONENT))
    return nil
  end
  return newLevel, newPlus, input[3] == true
end

function kenkouApplyAllLevel()
  local tables, errorMessage = kenkouResolveSaveCharacterTables()
  if not tables then
    gg.alert(errorMessage or "保存配列を確認できません。")
    return
  end
  local level, plus, freeze = kenkouGetAllLevelInput(tables)
  if not level then
    return
  end
  if gg.alert(string.format("全キャラをレベル%d＋%dへ変更しますか？", level, plus), "はい", "いいえ") ~= 1 then
    return
  end
  local writes, targets = {}, {}
  local markerRequests = {}
  for saveId = 1, tables.unitCount do
    local markerRecord = tables.level[saveId * 2]
    if not markerRecord then
      gg.alert(string.format("保存ID %d のレベルマスク配列を取得できません。", saveId))
      return
    end
    markerRequests[#markerRequests + 1] = markerRecord
  end
  local currentMarkers, markerCount, markerExpected = kenkouGetValuesInChunks(markerRequests)
  if not currentMarkers then
    gg.alert(string.format("レベルマスクの読み取り件数が不一致です（%d/%d）。", markerCount, markerExpected))
    return
  end
  for saveId = 1, tables.unitCount do
    local valueRecord = tables.level[saveId * 2 - 1]
    local markerRecord = tables.level[saveId * 2]
    if not valueRecord or not markerRecord then
      gg.alert(string.format("保存ID %d のレベル配列を取得できません。", saveId))
      return
    end
    local current = currentMarkers[saveId]
    local encoded, marker = kenkouEncodeLevel(level, plus, current and current.value)
    if encoded == nil or marker == nil then
      gg.alert(string.format("保存ID %d のレベルをエンコードできません。", saveId))
      return
    end
    writes[#writes + 1] = { address = valueRecord.address, flags = gg.TYPE_DWORD, value = encoded,
      name = "全キャラ | レベル" }
    writes[#writes + 1] = { address = markerRecord.address, flags = gg.TYPE_DWORD, value = marker,
      name = "全キャラ | レベルマスク" }
    targets[#targets + 1] = { value = valueRecord, marker = markerRecord }
  end
  if type(gg.getListItems) == "function" and type(gg.removeListItems) == "function" then
    local targetAddresses = {}
    for _, record in ipairs(tables.level) do
      targetAddresses[record.address] = true
    end
    local removals = {}
    for _, item in ipairs(gg.getListItems() or {}) do
      if targetAddresses[item.address] then
        removals[#removals + 1] = item
      end
    end
    if #removals > 0 then
      gg.removeListItems(removals)
    end
  end
  kenkouSetValuesInChunks(writes)
  if freeze then
    for _, write in ipairs(writes) do
      write.freeze = true
      write.freezeType = gg.FREEZE_NORMAL
    end
    kenkouAddListItemsInChunks(writes)
  end
  kenkouSafeSleep(80)
  local requests = {}
  for _, target in ipairs(targets) do
    requests[#requests + 1] = target.value
    requests[#requests + 1] = target.marker
  end
  local verified, verifiedCount, verifiedExpected = kenkouGetValuesInChunks(requests)
  if not verified then
    gg.alert(string.format("一括レベル変更後の確認件数が不一致です（%d/%d）。", verifiedCount, verifiedExpected))
    return
  end
  for index = 1, #targets do
    local verifiedLevel, verifiedPlus = kenkouDecodeLevel(
      verified[index * 2 - 1].value, verified[index * 2].value
    )
    if verifiedLevel ~= level or verifiedPlus ~= plus then
      gg.alert(string.format("一括レベル変更後の確認値が一致しません（保存ID %d）。", index))
      return
    end
  end
  gg.toast(string.format("%d体をレベル%d＋%dへ変更しました。", tables.unitCount, level, plus))
end

function kenkouSelectAllFormMode()
  local action = kenkouChooseMenu(
    { "形態を強制", "そのキャラの最大" },
    "全キャラ / 形態指定",
    true,
    "kenkou-all-form-mode"
  )
  if not action then
    return nil
  end
  if action == 2 then
    return { mode = "max" }
  end
  local labels = { "第1形態", "第2形態", "第3形態", "第4形態" }
  local selected = kenkouChooseMenu(labels, "全キャラ / 形態を強制", true, "kenkou-all-forced-form")
  if not selected then
    return nil
  end
  return { mode = "force", form = selected - 1 }
end

function kenkouApplyAllForm()
  local tables, errorMessage = kenkouResolveSaveCharacterTables()
  if not tables then
    gg.alert(errorMessage or "保存配列を確認できません。")
    return
  end
  local selection = kenkouSelectAllFormMode()
  if not selection then
    return
  end
  local writes, targets, skipped = {}, {}, 0
  for saveId = 1, tables.unitCount do
    local character = state.characters[saveId - 1]
    local formRecord = tables.form[saveId]
    if character and formRecord then
      local formCount = kenkouGetFormCount(character)
      local targetForm = selection.mode == "max" and formCount - 1 or selection.form
      if targetForm >= 0 and targetForm < formCount then
        writes[#writes + 1] = { address = formRecord.address, flags = gg.TYPE_DWORD, value = targetForm,
          name = "全キャラ | 現在形態" }
        targets[#targets + 1] = { address = formRecord.address, flags = gg.TYPE_DWORD, value = targetForm }
      else
        skipped = skipped + 1
      end
    end
  end
  if #writes == 0 then
    gg.alert("変更可能な形態がありません。")
    return
  end
  local description = selection.mode == "max"
    and "各キャラの最大形態"
    or string.format("第%d形態", selection.form + 1)
  if gg.alert(string.format("%d体を%sへ変更しますか？\n解放状態は変更しません。", #writes, description),
    "はい", "いいえ") ~= 1 then
    return
  end
  kenkouSetValuesInChunks(writes)
  kenkouSafeSleep(80)
  local verified, verifiedCount, verifiedExpected = kenkouGetValuesInChunks(targets)
  if not verified then
    gg.alert(string.format("一括形態変更後の確認件数が不一致です（%d/%d）。", verifiedCount, verifiedExpected))
    return
  end
  for index, value in ipairs(verified) do
    if tonumber(value.value) ~= targets[index].value then
      gg.alert(string.format("一括形態変更後の確認値が一致しません（%d件目）。", index))
      return
    end
  end
  local suffix = skipped > 0 and string.format("（対象外%d体）", skipped) or ""
  gg.toast(string.format("%d体を%sへ変更しました%s。", #writes, description, suffix))
end

function kenkouOpenAllCharacterActions()
  while true do
    local action = kenkouChooseMenu(
      { "キャラ解放/削除", "Lv変更", "形態変更", "戻る" },
      "全キャラ対象",
      false,
      "kenkou-all-character-actions"
    )
    if action == nil or action == 4 then
      return
    elseif action == 1 then
      local unlockAction = kenkouChooseMenu(
        { "解放", "削除", "戻る" },
        "全キャラ / 解放・削除",
        false,
        "kenkou-all-unlock-actions"
      )
      if unlockAction == 1 then
        kenkouApplyAllOwnership("解放")
      elseif unlockAction == 2 then
        kenkouApplyAllOwnership("削除")
      end
    elseif action == 2 then
      kenkouApplyAllLevel()
    elseif action == 3 then
      kenkouApplyAllForm()
    end
  end
end

function kenkouOpenCharacterActions(character, includeStatus)
  if includeStatus == nil then
    includeStatus = true
  end
  local actions = { "キャラ解放/削除", "Lv変更", "形態変更" }
  if includeStatus then
    actions[#actions + 1] = "ステータス変更"
  end
  actions[#actions + 1] = "戻る"
  local backAction = #actions
  while true do
    local action = kenkouChooseMenu(
      actions,
      string.format("%03d %s", character.id, kenkouGetCharacterName(character)),
      false,
      "kenkou-character-actions-" .. character.id
    )
    if action == nil or action == backAction then
      return
    elseif action == 1 then
      kenkouOpenUnlockControl(character)
    elseif action == 2 then
      kenkouChangeLevel(character)
    elseif action == 3 then
      kenkouOpenFormControlMenuV2(character)
    elseif includeStatus and action == 4 then
      kenkouOpenStatusTools(character)
    end
  end
end

function kenkouChooseCharacterForOperations()
  local action = kenkouChooseMenu(
    { "全キャラ", "一覧から選ぶ", "キャラ名/IDで検索" },
    "キャラ解放/Lv変更/形態変更",
    true,
    "kenkou-character-operations"
  )
  if not action then
    return nil
  end
  if action == 1 then
    if not kenkouConfirmAllTarget() then
      return nil
    end
    kenkouOpenAllCharacterActions()
    return nil
  elseif action == 2 then
    return chooseFromList(state.names)
  end
  return chooseByName(state.names)
end

function kenkouChooseCharacterForStatus()
  local action = kenkouChooseMenu(
    { "一覧から選ぶ", "キャラ名/IDで検索" },
    "ステータス変更",
    true,
    "kenkou-status-character-selection"
  )
  if not action then
    return nil
  end
  if action == 1 then
    return chooseFromList(state.names)
  end
  return chooseByName(state.names)
end

function kenkouOpenCharacter(character)
  return kenkouOpenCharacterActions(character)
end

function main()
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

function mainProduction()
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
    local action = kenkouChooseMenu(
      { "キャラ解放/Lv変更/形態変更", "ステータス変更", "施設レベル変更", "スクリプトを終了" },
      "KBC ステータス変更",
      false,
      "kenkou-main-production"
    )
    if action == 1 then
      local character = kenkouChooseCharacterForOperations()
      if character then
        kenkouOpenCharacterActions(character, false)
      end
    elseif action == 2 then
      local character = kenkouChooseCharacterForStatus()
      if character then
        kenkouOpenStatusTools(character)
      end
    elseif action == 3 then
      kenkouOpenFacilityEditor()
    else
      return
    end
  end
end

-- 検索画面などの入力経路でLua例外が発生しても、GGごと終了させず内容を表示する。
local ok, runtimeError = xpcall(mainProduction, function(message)
  if debug and debug.traceback then
    return debug.traceback(tostring(message), 2)
  end
  return tostring(message)
end)
if not ok then
  gg.alert("スクリプトエラー（処理は停止しました）:\n" .. tostring(runtimeError))
end
