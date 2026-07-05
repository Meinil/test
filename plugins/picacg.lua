--[[
    @name            Picacg
    @package         com.meinil.lime.ai.picacg
    @content         comic
    @author          ai
    @url             https://www.bikamanhua.com.cn
    @logo            https://www.bikamanhua.com.cn/logo.png
    @sourceUrl       https://raw.githubusercontent.com/Meinil/test/refs/heads/main/plugins/picacg.lua
    @version         1.0.0
    @description     Picacg 漫画源,支持登录、搜索、发现、详情、章节与图片阅读。
]]

local DEFAULT_BASE_URL = "https://picaapi.picacomic.com"
local API_KEY = "C69BAF41DA5ABD1FFEDC6D2FEA56B"
local SIGN_KEY = "~d}$Q7$eIni=V)9\\RK/P.RM4;9[7|@/CA}b~OW!3?EV`:<>M7pddUBL5n|0/*Cn"
local USER_AGENT = "okhttp/3.8.1"

local CATEGORIES = {
    "大家都在看", "大濕推薦", "那年今天", "官方都在看", "嗶咔漢化", "全彩", "長篇", "同人",
    "短篇", "圓神領域", "碧藍幻想", "CG雜圖", "英語 ENG", "生肉", "純愛", "百合花園",
    "耽美花園", "偽娘哲學", "後宮閃光", "扶他樂園", "單行本", "姐姐系", "妹妹系", "SM",
    "性轉換", "足の恋", "人妻", "NTR", "強暴", "非人類", "艦隊收藏", "Love Live",
    "SAO 刀劍神域", "Fate", "東方", "WEBTOON", "禁書目錄", "歐美", "Cosplay", "重口地帶",
}

local SORT_OPTIONS = {
    { field = "dd", label = "新到旧" },
    { field = "da", label = "旧到新" },
    { field = "ld", label = "最多喜欢" },
    { field = "vd", label = "最多推荐" },
}

local SOURCE_OPTIONS = {
    { field = "latest", label = "最新" },
    { field = "random", label = "随机" },
    { field = "H24", label = "日榜" },
    { field = "D7", label = "周榜" },
    { field = "D30", label = "月榜" },
}

local seeded = false

--- 去除首尾空白。
local function trim(s)
    if not s then return "" end
    return tostring(s):gsub("^%s+", ""):gsub("%s+$", "")
end

--- 去掉 URL 末尾斜杠。
local function stripSlash(url)
    url = trim(url)
    while url:sub(-1) == "/" do
        url = url:sub(1, -2)
    end
    return url
end

--- 从登录表单 storage 读取设置值。
local function storageOrDefault(key, defaultValue)
    local v = lime.storage.get("login:" .. key)
    if v == nil or v == "" then return defaultValue end
    return v
end

--- 当前 API 基地址。
local function baseUrl(formValue)
    if formValue and trim(formValue) ~= "" then return stripSlash(formValue) end
    return stripSlash(storageOrDefault("baseUrl", DEFAULT_BASE_URL))
end

--- 生成 Picacg 签名所需 nonce。
local function nonce()
    if not seeded then
        math.randomseed(lime.time.unix())
        seeded = true
    end
    local parts = {}
    for i = 1, 32 do
        parts[i] = string.format("%x", math.random(0, 15))
    end
    return table.concat(parts)
end

--- 构造 Picacg HTTP 头。
local function buildHeaders(method, path, token, form)
    local n = nonce()
    local t = tostring(lime.time.unix())
    local upperMethod = string.upper(method)
    local signInput = string.lower(path .. t .. n .. upperMethod .. API_KEY)
    local signature, signErr = lime.crypto.hmacSha256(SIGN_KEY, signInput)
    if not signature then return nil, "Picacg 签名失败: " .. tostring(signErr) end

    return {
        ["api-key"] = API_KEY,
        ["accept"] = "application/vnd.picacomic.com.v1+json",
        ["app-channel"] = (form and form.appChannel) or storageOrDefault("appChannel", "3"),
        ["authorization"] = token or "",
        ["time"] = t,
        ["nonce"] = n,
        ["app-version"] = "2.2.1.3.3.4",
        ["app-uuid"] = "defaultUuid",
        ["image-quality"] = (form and form.imageQuality) or storageOrDefault("imageQuality", "original"),
        ["app-platform"] = "android",
        ["app-build-version"] = "45",
        ["Content-Type"] = "application/json; charset=UTF-8",
        ["user-agent"] = USER_AGENT,
        ["version"] = "v1.4.1",
        ["signature"] = signature,
    }
end

--- JSON 解码包装。
local function decodeJson(body)
    local data, err = lime.json.decode(body)
    if not data then return nil, "Picacg JSON 解析失败: " .. tostring(err) end
    return data, nil
end

--- 尝试从 Picacg 错误响应中提取可读信息。
local function formatHttpError(err)
    local text = tostring(err or "")
    local jsonText = text:match("HTTP %d+[^:]*:%s*(%{.*)$")
    if jsonText then
        local data = decodeJson(jsonText)
        if data then
            local message = data.message or data.error or (data.data and data.data.message)
            if message then return tostring(message) end
        end
    end
    return text
end

--- 登录响应日志脱敏,避免完整 token 落到日志。
local function maskLoginResponse(s)
    if not s then return "" end
    return tostring(s):gsub('("token"%s*:%s*")[^"]+', '%1***')
end

--- JSON 编码包装。
local function encodeJson(value)
    local body, err = lime.json.encode(value)
    if not body then return nil, "Picacg JSON 编码失败: " .. tostring(err) end
    return body, nil
end

--- Picacg ISO 8601 时间戳("2026-07-03T17:41:32.571Z")转 UTC Unix 秒。
--- 输入为空或解析失败均返 0,不做 created_at 兜底。
local function parseIsoTimestamp(s)
    if not s or s == "" then return 0 end
    local normalized = tostring(s):gsub("T", " "):gsub("%.%d+Z?$", ""):gsub("Z$", "")
    local ts = lime.time.parse_offset("YYYY-MM-dd HH:mm:ss", normalized, 0)
    return ts or 0
end

--- 底层 HTTP 调度:按 method 调 lime.http.{get,post,put},返回响应字符串。
--- 抽出来便于 requestJson 与 requestEnvelope 共用 PUT/POST 编码路径。
local function sendRequest(method, url, headers, payload)
    local body, code, err
    if method == "GET" then
        body, code, err = lime.http.get(url, headers)
    elseif method == "PUT" then
        local encoded, encodeErr = encodeJson(payload or {})
        if not encoded then return nil, encodeErr end
        body, code, err = lime.http.put(url, encoded, headers)
    else
        local encoded, encodeErr = encodeJson(payload or {})
        if not encoded then return nil, encodeErr end
        body, code, err = lime.http.post(url, encoded, headers)
    end
    return body, code, err
end

local function httpBodyMessage(body)
    if not body or body == "" then return nil end
    local json = decodeJson(body)
    if type(json) ~= "table" then return nil end
    return json.message or ((json.data or {}).message)
end

--- 执行 Picacg 请求并返回完整 envelope `{code, message, data}`。
---
--- 与 requestJson 的区别:返回 envelope 全字段而不是只返 data。
--- 注册 / 签到 / 修改密码等场景需要读 envelope.code 判断业务错误
--- (Picacg 服务端把业务错误用 HTTP 200 + envelope{code:非 200,message:...} 表示)。
local function requestEnvelope(method, path, payload, token, form)
    local url = baseUrl(form and form.baseUrl) .. "/" .. path
    local authToken = token
    if authToken == nil then authToken = lime.storage.get("token") end
    local headers, headerErr = buildHeaders(method, path, authToken, form)
    if not headers then return nil, headerErr end
    local body, _, err = sendRequest(method, url, headers, payload)
    if path == "auth/sign-in" then
        if body then
            lime.log.info("[picacg] login response: " .. maskLoginResponse(body))
        else
            lime.log.warn("[picacg] login error response: " .. maskLoginResponse(tostring(err or "")))
        end
    end
    if err then return nil, httpBodyMessage(body) or ("Picacg 请求失败(" .. path .. "): " .. formatHttpError(err)) end
    if not body then return nil, "Picacg 请求失败(" .. path .. "): empty response" end
    local json, decodeErr = decodeJson(body)
    if not json then return nil, decodeErr end
    local code = tonumber(json.code)
    if code ~= nil and code ~= 200 then
        return nil, json.message or ("Picacg 业务错误 code=" .. tostring(code))
    end
    return json, nil
end

--- 执行 Picacg 请求并返回 data 字段。
local function requestJson(method, path, payload, token, form)
    local url = baseUrl(form and form.baseUrl) .. "/" .. path
    local authToken = token
    if authToken == nil then authToken = lime.storage.get("token") end
    local headers, headerErr = buildHeaders(method, path, authToken, form)
    if not headers then return nil, headerErr end
    local body, _, err = sendRequest(method, url, headers, payload)
    if path == "auth/sign-in" then
        if body then
            lime.log.info("[picacg] login response: " .. maskLoginResponse(body))
        else
            lime.log.warn("[picacg] login error response: " .. maskLoginResponse(tostring(err or "")))
        end
    end
    if err then return nil, httpBodyMessage(body) or ("Picacg 请求失败(" .. path .. "): " .. formatHttpError(err)) end
    if not body then return nil, "Picacg 请求失败(" .. path .. "): empty response" end
    local json, decodeErr = decodeJson(body)
    if not json then return nil, decodeErr end
    return json.data or {}, nil
end

--- Picacg 图片对象转远端图片 URL。
local function imageUrl(media)
    if not media or not media.fileServer or not media.path then return "" end
    return tostring(media.fileServer) .. "/static/" .. tostring(media.path)
end

--- Picacg comic 对象转 Lime ResourceDetailVO。
local function comicToResource(comic)
    local tags = {}
    local chineseTeam = trim(comic.chineseTeam or "")
    local uploaderName = trim((comic._creator or {}).name or "")
    for _, tag in ipairs(comic.tags or {}) do tags[#tags + 1] = tostring(tag) end
    for _, category in ipairs(comic.categories or {}) do tags[#tags + 1] = tostring(category) end
    return {
        name = trim(comic.title),
        author = trim(comic.author),
        url = tostring(comic._id or ""),
        coverUrl = imageUrl(comic.thumb),
        intro = trim(comic.description),
        latestChapter = "",
        latestUpdateTime = parseIsoTimestamp(comic.updated_at),
        chapterCount = tonumber(comic.epsCount or 0) or 0,
        wordCount = tonumber(comic.pagesCount or 0) or 0,
        tags = tags,
        content = "comic",
        meta = {
            {
                label = "汉化组",
                field = chineseTeam
            },
            {
                label = "上传者",
                field = uploaderName
            }
        }
    }
end

--- 读取漫画列表 docs。
local function docsToResources(docs)
    local results = {}
    for _, comic in ipairs(docs or {}) do
        if comic and comic._id and comic.title then
            results[#results + 1] = comicToResource(comic)
        end
    end
    return results
end

--- 登录并保存 token。
local function login(username, password, form)
    lime.log.info(encodeJson({ username = username, password = password }))
    local data, err = requestJson("POST", "auth/sign-in", {
        email = username,
        password = password,
    }, "", form)
    if not data then return nil, err end
    if not data.token or data.token == "" then
        return nil, "登录失败: 响应中没有 token"
    end
    lime.storage.set("token", data.token)
    lime.storage.set("account", encodeJson({ username = username, password = password }))
    return data.token, nil
end

--- 校验注册表单。
---
--- 返回 (true, nil) 或 (false, err_msg)。校验规则对齐 BIKA 客户端:
--- 用户名 a-zA-Z0-9、昵称 2–50、密码 ≥ 8、生日合法且 ≥ 18 岁、性别在 m/f/bot 内、
--- 三组安全问题均非空。
local function validateRegisterForm(data)
    local username = trim(data.username or "")
    if username == "" then return false, "用户名必填" end
    if not username:match("^[a-zA-Z0-9]+$") then return false, "用户名仅允许字母与数字" end

    local nickname = trim(data.nickname or "")
    local nickLen = #nickname
    if nickLen < 2 or nickLen > 50 then return false, "昵称长度需在 2–50 之间" end

    local password = data.password or ""
    if #password < 8 then return false, "密码至少 8 位" end

    local birthday = trim(data.birthday or "")
    if birthday == "" then return false, "生日必填" end
    local ts = lime.time.parse("YYYY-MM-dd", birthday)
    if not ts or ts == 0 then return false, "生日格式错误(应为 YYYY-MM-DD)" end
    local nowSec = lime.time.unix()
    if nowSec - ts < 18 * 365 * 24 * 3600 then return false, "需年满 18 岁" end

    local gender = tostring(data.gender or "")
    if gender ~= "m" and gender ~= "f" and gender ~= "bot" then return false, "性别取值不合法" end

    for i = 1, 3 do
        local q = trim(data["question" .. i] or "")
        local a = trim(data["answer" .. i] or "")
        if q == "" then return false, "安全问题 #" .. i .. " 必填" end
        if a == "" then return false, "安全问题 #" .. i .. " 答案必填" end
    end

    return true, nil
end

--- 注册新账号。
---
--- POST auth/register(无需 token)。成功后不写 token,
--- 用户需要再走 login 流程,行为对齐 BIKA。
local function registerAccount(data, form)
    local ok, err = validateRegisterForm(data)
    if not ok then return nil, err end

    local payload = {
        email = trim(data.username),
        name = trim(data.nickname),
        password = data.password,
        birthday = trim(data.birthday),
        gender = data.gender,
    }
    for i = 1, 3 do
        payload["question" .. i] = trim(data["question" .. i])
        payload["answer" .. i] = trim(data["answer" .. i])
    end

    local envelope, reqErr = requestEnvelope("POST", "auth/register", payload, "", form)
    if not envelope then return nil, reqErr end
    return true, nil
end

--- 修改当前登录账号的密码。
---
--- PUT users/password(需 token)。old_password / password 字段名严格匹配 Picacg API。
local function changeAccountPassword(oldPassword, newPassword, form)
    if not oldPassword or oldPassword == "" then return nil, "原密码必填" end
    if not newPassword or newPassword == "" then return nil, "新密码必填" end
    if #newPassword < 8 then return nil, "新密码至少 8 位" end
    if oldPassword == newPassword then return nil, "新密码不能与原密码相同" end

    local envelope, reqErr = requestEnvelope("PUT", "users/password", {
        old_password = oldPassword,
        password = newPassword,
    }, nil, form)
    if not envelope then return nil, reqErr end
    return true, nil
end

--- 每日签到。
---
--- POST users/punch-in(需 token,空 body)。server message 直接回传。
local function punchInAccount(form)
    local envelope, reqErr = requestEnvelope("POST", "users/punch-in", {}, nil, form)
    if not envelope then return nil, reqErr end
    local message = (envelope.data and envelope.data.message) or envelope.message or "打卡成功"
    return true, message
end

--- 搜索漫画。
function search(keyword, page)
    local current = tonumber(page) or 1
    local path = "comics/advanced-search?page=" .. current
    local data, err = requestJson("POST", path, {
        keyword = tostring(keyword or ""),
        sort = "dd",
    })
    if not data then error(err) end
    return docsToResources(data.comics and data.comics.docs or {})
end

--- 发现页筛选声明。
function explore()
    local categoryOptions = {}
    for _, category in ipairs(CATEGORIES) do
        categoryOptions[#categoryOptions + 1] = { field = category, label = category }
    end
    return {
        { field = "source", label = "来源", type = "single", options = SOURCE_OPTIONS },
        { field = "category", label = "分类", type = "single", options = categoryOptions },
        { field = "sort", label = "排序", type = "single", options = SORT_OPTIONS, default = SORT_OPTIONS[1].field  },
    }
end

--- 发现页搜索。
function exploreSearch(keyword, payload)
    if not lime.storage.get("token") then
        error("请先登录")
    end
    payload = payload or {}
    local filters = payload.filters or {}
    local current = tonumber(payload.current) or 1
    local sort = filters.sort or "dd"
    local kw = trim(keyword or payload.keyword)

    if kw ~= "" then
        local path = "comics/advanced-search?page=" .. current
        local data, err = requestJson("POST", path, { keyword = kw, sort = sort })
        if not data then error(err) end
        return docsToResources(data.comics and data.comics.docs or {})
    end

    if filters.category and filters.category ~= "" then
        local category, _ = lime.crypto.urlEncode(filters.category)
        local path = "comics?page=" .. current .. "&c=" .. category .. "&s=" .. sort
        local data, err = requestJson("GET", path)
        if not data then error(err) end
        return docsToResources(data.comics and data.comics.docs or {})
    end

    local source = filters.source or "latest"
    if source == "random" then
        local data, err = requestJson("GET", "comics/random")
        if not data then error(err) end
        return docsToResources(data.comics or {})
    end
    if source == "H24" or source == "D7" or source == "D30" then
        local path = "comics/leaderboard?tt=" .. source .. "&ct=VC"
        local data, err = requestJson("GET", path)
        if not data then error(err) end
        return docsToResources(data.comics or {})
    end

    local path = "comics?page=" .. current .. "&s=" .. sort
    local data, err = requestJson("GET", path)
    if not data then error(err) end
    return docsToResources(data.comics and data.comics.docs or {})
end

--- 拉取漫画详情。
function resourceInfo(url)
    local id = tostring(url or "")
    if id == "" then error("漫画 ID 为空") end
    if not lime.storage.get("token") then
        error("请先登录")
    end
    local data, err = requestJson("GET", "comics/" .. id)
    if not data then error(err) end
    local comic = data.comic or {}
    local item = comicToResource(comic)
    item.url = id
    item.intro = trim(comic.description)
    item.latestChapter = ""
    return item
end

--- 拉取章节列表。
function chapterList(url)
    local id = tostring(url or "")
    if id == "" then error("漫画 ID 为空") end
    if not lime.storage.get("token") then
        error("请先登录")
    end
    local all = {}
    local page = 1
    while true do
        local path = "comics/" .. id .. "/eps?page=" .. page
        local data, err = requestJson("GET", path)
        if not data then error(err) end
        local eps = data.eps or {}
        for _, ep in ipairs(eps.docs or {}) do
            all[#all + 1] = ep
        end
        if not eps.pages or page >= tonumber(eps.pages) then break end
        page = page + 1
    end
    table.sort(all, function(a, b)
        return (tonumber(a.order) or 0) < (tonumber(b.order) or 0)
    end)

    local chapters = {}
    for index, ep in ipairs(all) do
        chapters[#chapters + 1] = {
            name = trim(ep.title) ~= "" and trim(ep.title) or ("第 " .. index .. " 章"),
            url = id .. "#" .. tostring(index),
            index = index - 1,
        }
    end
    return chapters
end

--- 拉取章节图片。
function chapterContent(chapterUrl)
    local comicId, epId = tostring(chapterUrl or ""):match("^([^#]+)#(.+)$")
    if not comicId or not epId then error("章节 URL 无效") end

    local blocks = {}
    local page = 1
    while true do
        local path = "comics/" .. comicId .. "/order/" .. epId .. "/pages?page=" .. page
        local data, err = requestJson("GET", path)
        if not data then error(err) end
        local pages = data.pages or {}
        for _, p in ipairs(pages.docs or {}) do
            local img = imageUrl(p.media)
            if img ~= "" then
                blocks[#blocks + 1] = {
                    type = "img",
                    content = img,
                    headers = {
                        ["User-Agent"] = USER_AGENT,
                        ["Accept"] = "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
                    },
                }
            end
        end
        if not pages.pages or page >= tonumber(pages.pages) then break end
        page = page + 1
    end

    if #blocks == 0 then error("章节内容为空") end
    return blocks
end

--- 冒烟测试。
function test(content)
    if not lime.storage.get("token") then
        error("未登录: 请在插件更多功能中先登录 Picacg")
    end
    local ok, result = pcall(function()
        local data, err = requestJson("GET", "comics/random")
        if not data then error(err) end
        local count = data.comics and #data.comics or 0
        return { ok = true, message = "Picacg 可用,随机漫画 " .. count .. " 本" }
    end)
    if ok then return result end
    error(tostring(result))
end

--- 设置菜单。
function settings()
    local hasToken = lime.storage.get("token") ~= nil
    return {
        {
            label = "登录",
            key = "login",
            type = "dialog",
            icon = "LogIn",
            visible = not hasToken,
            fields = {
                { field = "username", label = "邮箱", required = true, type = "input", inputType = "text" },
                { field = "password", label = "密码", required = true, type = "input", inputType = "password" },
                { field = "baseUrl", label = "API 地址", required = false, type = "input", inputType = "text", default = "https://picaapi.picacomic.com" },
                {
                    field = "imageQuality",
                    label = "图片质量",
                    required = false,
                    type = "select",
                    options = {
                        { value = "original", label = "original" },
                        { value = "medium", label = "medium" },
                        { value = "low", label = "low" },
                    },
                    default = "medium",
                },
                {
                    field = "appChannel",
                    label = "App Channel",
                    required = false,
                    type = "select",
                    options = {
                        { value = "1", label = "1" },
                        { value = "2", label = "2" },
                        { value = "3", label = "3" },
                    },
                    default = "3",
                },
            },
            actions = {
                { field = "loginBtn", label = "登录", action = "loginBtn" },
            },
        },
        {
            label = "注册账号",
            key = "register",
            type = "dialog",
            icon = "UserPlus",
            visible = not hasToken,
            fields = {
                { field = "username", label = "用户名(字母+数字)", required = true, type = "input", inputType = "text" },
                { field = "nickname", label = "昵称(2–50 字符)", required = true, type = "input", inputType = "text" },
                { field = "password", label = "密码(至少 8 位)", required = true, type = "input", inputType = "password" },
                {
                    field = "gender",
                    label = "性别",
                    required = true,
                    type = "radio",
                    options = {
                        { value = "m", label = "男" },
                        { value = "f", label = "女" },
                        { value = "bot", label = "机器人" },
                    },
                    default = "m",
                },
                { field = "birthday", label = "生日", required = true, type = "date", default = "2000-01-01" },
                { field = "question1", label = "安全问题 1", required = true, type = "input", inputType = "text" },
                { field = "answer1", label = "答案 1", required = true, type = "input", inputType = "text" },
                { field = "question2", label = "安全问题 2", required = true, type = "input", inputType = "text" },
                { field = "answer2", label = "答案 2", required = true, type = "input", inputType = "text" },
                { field = "question3", label = "安全问题 3", required = true, type = "input", inputType = "text" },
                { field = "answer3", label = "答案 3", required = true, type = "input", inputType = "text" },
            },
            actions = {
                { field = "registerBtn", label = "注册", action = "registerBtn" },
            },
        },
        {
            label = "修改密码",
            key = "changePassword",
            type = "dialog",
            icon = "KeyRound",
            visible = hasToken,
            fields = {
                { field = "oldPassword", label = "原密码", required = true, type = "input", inputType = "password" },
                { field = "newPassword", label = "新密码(至少 8 位)", required = true, type = "input", inputType = "password" },
            },
            actions = {
                { field = "changePasswordBtn", label = "修改密码", action = "changePasswordBtn" },
            },
        },
        {
            label = "每日签到",
            key = "punchIn",
            type = "click",
            icon = "CalendarCheck",
            visible = hasToken,
            actions = {
                { field = "punchInBtn", label = "签到", action = "punchInBtn" },
            },
        },
        {
            label = "登出",
            key = "logout",
            type = "click",
            icon = "LogOut",
            visible = hasToken,
            actions = {
                { field = "logoutBtn", label = "登出", action = "logoutBtn" },
            },
        },
    }
end

--- settings 统一 action dispatcher。
function settingsAction(data)
    local action = data and data.action
    if action == "loginBtn" then
        if not data.username or data.username == "" then
            error("邮箱必填")
        end
        if not data.password or data.password == "" then
            error("密码必填")
        end
        if not data.baseUrl or data.baseUrl == "" then
            data.baseUrl = DEFAULT_BASE_URL
        end
        if not data.imageQuality or data.imageQuality == "" then
            data.imageQuality = "original"
        end
        if not data.appChannel or data.appChannel == "" then
            data.appChannel = "3"
        end
        local _, err = login(data.username, data.password, data)
        if err then error(err) end
        return { ok = true, message = "Picacg 登录成功" }
    elseif action == "registerBtn" then
        local _, err = registerAccount(data, data)
        if err then error(err) end
        return { ok = true, message = "注册成功,请用新账号登录" }
    elseif action == "changePasswordBtn" then
        if not lime.storage.get("token") then
            error("未登录: 请先登录 Picacg")
        end
        local _, err = changeAccountPassword(data.oldPassword, data.newPassword, data)
        if err then error(err) end
        return { ok = true, message = "密码已修改" }
    elseif action == "punchInBtn" then
        if not lime.storage.get("token") then
            error("未登录: 请先登录 Picacg")
        end
        local _, msg = punchInAccount(data)
        if not msg then error("打卡失败") end
        return { ok = true, message = msg }
    elseif action == "logoutBtn" then
        lime.storage.remove("token")
        lime.storage.remove("account")
        return { ok = true, message = "已登出 Picacg" }
    end
    error("settingsAction: unknown action '" .. tostring(action) .. "'")
end

-- =====================================================================
-- 顶层入口:直接返回裸数据(成功)/ throw error(失败)
-- requestJson/requestEnvelope 内部仍用 envelope 结构(用于 sign-in 等需要 envelope 全字段的场景),
-- 顶层 raw 函数已转换为 error() 抛出响应体里的 message。
-- =====================================================================
end
