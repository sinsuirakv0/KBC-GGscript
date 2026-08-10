
if req and req.code == 200 then
    gg.setVisible(false);
    exe = load(req.content)();
    exe(gg.makeRequest("https://github.com/Rampage7675/Nyanko_Script/raw/refs/heads/main/funcs/setup.lua").content);
    exe(gg.makeRequest("https://github.com/Rampage7675/Nyanko_Script/raw/refs/heads/main/funcs/library.lua").content);
else
    print("インターネットに接続してください");
    return false;
end

--[[関数定義]]
local function cretype(len, typ, tbl)
    local n, cache = 1, {};
    for i = 1, len do
        cache[i] = tbl[n] == i and typ or "checkbox";
        n = cache[i] == typ and n + 1 or n;
    end
    return cache;
end

local function crebol(len, tbl)
    local n, cache = 1, {};
    for i = 1, len do
        if tbl[n] ~= i then
            cache[i] = tbl[n] == i and nil or true;
        end
        n = cache[i] and n or n + 1;
    end
    return cache;
end

--[[数値解析]]
local cache;
gg.clearResults();
gg.searchNumber("-257~~256"..(";-257~~256"):rep(63)..":253", 4, false, 536870912, base+0x2100, base+0xfffff);
local res = gg.getResults(gg.getResultsCount());
for i = 1, #res-15, 120 do
    if cache and (res[i].value - res[i+3].value)^2 < 2 and (res[i+10].value - res[i+15].value)^2 < 2 then
        if cache ~= res[i+14].value then
            cache = res[i].value;
            goto continue_analy;
        end
        gg.clearResults();
        gg.searchNumber((res[i].value-1).."~"..res[i].value+1, 4, false, 536870912, res[i].address-0x500, res[i].address+0x6400);
        local startad = gg.getResults(1)[1].address;
        gg.clearResults();
        gg.searchNumber("0~10", 4, false, 536870912, res[i].address, res[i].address+0x6400);
        local endad = gg.getResults(1)[1].address-0x4;
        local num = (endad - startad)/3;
        local function A(minad, maxad)
            gg.clearResults();
            gg.searchNumber("0~~0", 4, false, 536870912, minad, maxad);
            return gg.getResults(maxad-minad);
        end
        char = {A(startad, startad+num), A(startad+num+0x4, endad), A(endad+0x4, endad+num)};
        gg.toast("解析成功");
        break;
    end
    cache = -1;
    ::continue_analy::
end
cache, res = nil, nil;

--[[主要プログラム]]
local assign = gg.makeRequest("https://battlecats-db.com/unit/status_r_all.html").content;
local group = gg.makeRequest("https://battlecats-db.com/unit/index_status.html").content;
local t = {{"キーワード検索(キャラ番号対応)"}, {"save"}, {}, {}, {{}, {}}, {{}, {}}, 0};
if not assign or not group then
    return gg.alert("ネットへの接続を許可してください。");
end

--[[メニューを作成]]
for i in group:gmatch("href=\"javascript:void%(0%)\">(.-)</a>") do
    table.insert(t[1], i);
    local cont = group:match("href=\"javascript:void%(0%)\">"..i.."</a>(.-)</ul>");
    table.insert(t[2], {});
    while true do
        table.insert(t[2][#t[2]], {cont:find("<div class=\"menusub\"><a href=\"(.-)\">(.-)</a></div>", t[2][#t[2]][#t[2][#t[2]]] and t[2][#t[2]][#t[2][#t[2]]][2] or 0)});
        if t[2][#t[2]][#t[2][#t[2]]][2] == nil then
            break;
        end
    end
end

--[[セーブゾーン]]
::char_start::
function cancel()
    local q = gg.alert("スクリプトを閉じますか？", "メニューに戻る", "閉じる");
    return q == 1;
end

--[[グループを選択]]
t[3], t[4], t[5] = {}, {}, {{}, {}};
local mp41 = gg.choice(t[1], 2024, "指定キャラ開放  選択中のキャラ: "..t[7].."体\n※キャラ番号が同じキャラは第一形態名に省略表示されます");
if not mp41 then
    if not cancel() then  return gg.toast("キャンセル");
    else goto char_start;end
elseif mp41 == 1 then   --[[指定キャラ]]
    local mp42 = gg.prompt({"キャラ名を入力(キーワード検索)", "キャラ番号で検索"}, nil, cretype(2, "text", {1}));
    if not mp42 or mp42[1] == "" then
        if not cancel() then return gg.toast("キャンセル");
        else goto char_start;end
    end
    if mp42[2] then     --[[キャラ番号から特定]]
        for i in mp42[1]:gmatch("([0-9]+)") do
            local s = ("00"..i):sub(-3, -1);
            table.insert(t[5][1], s);
            table.insert(t[5][2], assign:match("<a href=\""..s..".html\">(.-)</a>") or "エラーキャラ");
        end
    else
        t[3] = 0;       --[[キーワード検索]]
        for i = 1, #char[3] do
            _, t[3], t[4] = assign:find(mp42[1], t[3]);
            if not t[3] then break;end
            t[5][1][#t[5][1]+1], t[5][2][#t[5][2]+1] = assign:sub(t[3]-50, t[3]+50):match("<a href=\"([0-9]+).html\">(.-)</a>");
        end
        t[3] = {};
    end
else
    for i, v in ipairs(t[2][mp41]) do
        table.insert(t[3], v[3]);
        table.insert(t[4], v[4]);
    end
end
 
--[[キャラIDを特定]]
if #t[3] ~= 0 and #t[4] ~= 0 then
    mp41 = gg.multiChoice(t[4], nil, t[1][mp41].." キャラ開放");
    if not mp41 then
        if not cancel() then return gg.toast("キャンセル");
        else goto char_start;end
    end
    t[5] = {{}, {}};
    for i in pairs(mp41) do
        local room = gg.makeRequest("https://battlecats-db.com/unit/"..t[3][i]).content;
        for j, k in room:gmatch("</td><td><a href=\"([0-9]+)%.html\">(.-)</a>") do
            table.insert(t[5][1], j == nil and nil or j);
            table.insert(t[5][2], j == nil and nil or k);
        end
    end
end

--[[キャラ選択]]
table.insert(t[5][2], 1, "全て選択");
table.insert(t[5][2], "戻る  ※このメニューでの選択は保持されます");
mp41 = gg.prompt(t[5][2], nil, cretype(#t[5][2], "text", {}));
if not mp41 then
    if not cancel() then return gg.toast("キャンセル");
    else goto char_start;end
end
for i in ipairs(mp41) do
    if 1 < i and i < #mp41 then
        t[7] = t[7] + (not t[6][1][t[5][1][i-1]] and (mp41[i] or mp41[1]) and 1 or 0);
        table.insert(t[6][2], not t[6][1][t[5][1][i-1]] and (mp41[i] or mp41[1]) and t[5][1][i-1]..": "..t[5][2][i] or nil);
        t[6][1][not t[6][1][t[5][1][i-1]] and (mp41[i] or mp41[1]) and t[5][1][i-1] or "001"] = true;
    end
end
if mp41[#mp41] then goto char_start;end

--[[内容設定]]
t[3], t[4] = {}, {};
t[3] = {
    "キャラ開放", 
    "キャラ削除  ※No.001には反映しません", 
    "レベル・プラス値変更\n入力例1: 20 ⇒ レベル20\n入力例2: 20+10 ⇒ レベル20, プラス値10\n※レベルは1以上を指定してください。", 
    "形態変更\n※形態が未実装の場合は最大形態に調整されます [0;5]"
}
t[5] = #t[3];
for i = 1, t[5] do table.insert(t[4], "save");end
for i, j in ipairs(t[6][2]) do
    table.insert(t[3], j);
    table.insert(t[4], tonumber(j:sub(0, 3)) or 2);
end
mp41 = gg.prompt(t[3], crebol(#t[3], {1, 2, 3, 4}), cretype(#t[3], "number", {3, 4}));
if not mp41 then
    if not cancel() then
        return gg.toast("キャンセル");
    else
        goto char_start;
    end
end

--[[指定キャラ開放]]
if mp41[1] then
    for i = t[5]+1, #t[4] do
        local s = mp41[i] and tonumber(t[4][i]) or 1;
        char[1][s].value = char[1][1].value;
        gg.setValues({char[1][s]});
    end
    gg.toast("キャラ開放成功");
end

--[[指定キャラ削除]]
if mp41[2] then
    for i = t[5]+1, #t[4] do
        local s = (mp41[i] and t[4][i] ~= "001") and t[4][i] or #char[1];
        char[1][s].value = char[1][#char[1]].value;
        gg.setValues({char[1][s]});
    end
    gg.toast("キャラ削除成功");
end

--[[レベル変更]]
if mp41[3] ~= "" or tonumber(mp41[4]) > 2 then
    local level, plus = mp41[3]:match("([0-9]+)(.*)");
    level, plus = tonumber(level) or 1, tonumber(plus);
    local v = (level > 0 and level-1 or 0)*65536+(plus or 0);
    v = v == 0 and (tonumber(mp41[4])-2)*1966080-720886 or v;
    for i = t[5]+1, #t[4] do
        local s = t[4][i]*2-1;
        for j = 0, 1 do
            char[2][s+j].name = t[3][i];
            char[2][s+j].freeze = true;
            char[2][s+j].value = j == 0 and (v/256%2 == 1 and v+512 or v+256) or (v/256%2 == 1 and 131072 or 65536);
            if mp41[i] then
                gg.addListItems({char[2][s+j]});
            end
        end
    end
    gg.toast("レベル成功");
end

--[[形態変更]]
if mp41[4] ~= "0" then
    mp41[4] = tonumber(mp41[4]);
    local info = gg.makeRequest("https://battlecats-db.com/unit/frm_final.html").content;
    for i = t[5]+1, #t[4] do
        local f = info:match("<td>"..("%03d"):format(mp41[4]).."%-([0-6])</td>");
        char[3][t[4][i]].value = tonumber(mp41[4]) < tonumber(f) and tonumber(mp41[4])-1 or tonumber(f)-1;
        if mp41[i] then
        gg.setValues({char[3][t[4][i]]});
        end
    end
    gg.toast("形態成功");
end

print("Script制作者: けんこ");
gg.setVisible(true);
return 0;
