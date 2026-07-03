--[[
    @name            Picacg
    @package         com.picacg.comic
    @content         comic
    @author          ai
    @url             https://www.bikamanhua.com.cn
    @logo            https://www.bikamanhua.com.cn/logo.png
    @source_url      https://raw.githubusercontent.com/Meinil/test/refs/heads/main/plugins/picacg.lua
    @enable_explore  true
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

--- 执行 Picacg 请求并返回 data 字段。
local function requestJson(method, path, payload, token, form)
    local url = baseUrl(form and form.baseUrl) .. "/" .. path
    local authToken = token
    if authToken == nil then authToken = lime.storage.get("token") end
    local headers, headerErr = buildHeaders(method, path, authToken, form)
    if not headers then return nil, headerErr end
    local body, err
    if method == "GET" then
        body, err = lime.http.get(url, headers)
    else
        local encoded, encodeErr = encodeJson(payload or {})
        if not encoded then return nil, encodeErr end
        body, err = lime.http.post(url, encoded, headers)
    end
    if path == "auth/sign-in" then
        if body then
            lime.log.info("[picacg] login response: " .. maskLoginResponse(body))
        else
            lime.log.warn("[picacg] login error response: " .. maskLoginResponse(tostring(err or "")))
        end
    end
    if not body then return nil, "Picacg 请求失败(" .. path .. "): " .. formatHttpError(err) end
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
    -- chineseTeam 放第一位,_creator.name 放第二位(都按"有值才加"原则)
    local chineseTeam = trim(comic.chineseTeam or "")
    if chineseTeam ~= "" then tags[#tags + 1] = chineseTeam end
    local uploaderName = trim((comic._creator or {}).name or "")
    if uploaderName ~= "" then tags[#tags + 1] = uploaderName end
    for _, tag in ipairs(comic.tags or {}) do tags[#tags + 1] = tostring(tag) end
    for _, category in ipairs(comic.categories or {}) do tags[#tags + 1] = tostring(category) end
    return {
        name = trim(comic.title),
        author = trim(comic.author),
        url = tostring(comic._id or ""),
        coverUrl = imageUrl(comic.thumb),
        intro = trim(comic.description),
        latestChapter = "",
        chapterCount = tonumber(comic.epsCount or 0) or 0,
        wordCount = tonumber(comic.pagesCount or 0) or 0,
        tags = tags,
        content = "comic",
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

--- 搜索漫画。
function search(keyword, page)
    local current = tonumber(page) or 1
    local path = "comics/advanced-search?page=" .. current
    local data, err = requestJson("POST", path, {
        keyword = tostring(keyword or ""),
        sort = "dd",
    })
    if not data then return { code = 400, message = err, data = nil } end
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
        { field = "sort", label = "排序", type = "single", options = SORT_OPTIONS },
    }
end

--- 发现页搜索。
function exploreSearch(keyword, payload)
    if not lime.storage.get("token") then
        return { code = 400, message = "请先登录", data = nil }
    end
    payload = payload or {}
    local filters = payload.filters or {}
    local current = tonumber(payload.current) or 1
    local sort = filters.sort or "dd"
    local kw = trim(keyword or payload.keyword)

    if kw ~= "" then
        local path = "comics/advanced-search?page=" .. current
        local data, err = requestJson("POST", path, { keyword = kw, sort = sort })
        if not data then return { code = 400, message = err, data = nil } end
        return docsToResources(data.comics and data.comics.docs or {})
    end

    if filters.category and filters.category ~= "" then
        local category, _ = lime.crypto.urlEncode(filters.category)
        local path = "comics?page=" .. current .. "&c=" .. category .. "&s=" .. sort
        local data, err = requestJson("GET", path)
        if not data then return { code = 400, message = err, data = nil } end
        return docsToResources(data.comics and data.comics.docs or {})
    end

    local source = filters.source or "latest"
    if source == "random" then
        local data, err = requestJson("GET", "comics/random")
        if not data then return { code = 400, message = err, data = nil } end
        return docsToResources(data.comics or {})
    end
    if source == "H24" or source == "D7" or source == "D30" then
        local path = "comics/leaderboard?tt=" .. source .. "&ct=VC"
        local data, err = requestJson("GET", path)
        if not data then return { code = 400, message = err, data = nil } end
        return docsToResources(data.comics or {})
    end

    local path = "comics?page=" .. current .. "&s=" .. sort
    local data, err = requestJson("GET", path)
    if not data then return { code = 400, message = err, data = nil } end
    return docsToResources(data.comics and data.comics.docs or {})
end

--- 拉取漫画详情。
function resourceInfo(url)
    local id = tostring(url or "")
    if id == "" then return { code = 400, message = "漫画 ID 为空", data = nil } end
    if not lime.storage.get("token") then
        return { code = 400, message = "请先登录", data = nil }
    end
    local data, err = requestJson("GET", "comics/" .. id)
    if not data then return { code = 400, message = err, data = nil } end
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
    if id == "" then return { code = 400, message = "漫画 ID 为空", data = nil } end
    if not lime.storage.get("token") then
        return { code = 400, message = "请先登录", data = nil }
    end
    local all = {}
    local page = 1
    while true do
        local path = "comics/" .. id .. "/eps?page=" .. page
        local data, err = requestJson("GET", path)
        if not data then return { code = 400, message = err, data = nil } end
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
    if not comicId or not epId then return { code = 400, message = "章节 URL 无效", data = nil } end

    local blocks = {}
    local page = 1
    while true do
        local path = "comics/" .. comicId .. "/order/" .. epId .. "/pages?page=" .. page
        local data, err = requestJson("GET", path)
        if not data then return { code = 400, message = err, data = nil } end
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

    if #blocks == 0 then return { code = 500, message = "章节内容为空", data = nil } end
    return blocks
end

--- 冒烟测试。
function test(content)
    if not lime.storage.get("token") then
        return { code = 400, message = "未登录: 请在插件更多功能中先登录 Picacg", data = nil }
    end
    local ok, result = pcall(function()
        local data, err = requestJson("GET", "comics/random")
        if not data then return { code = 400, message = err, data = nil } end
        local count = data.comics and #data.comics or 0
        return { code = 0, message = "Picacg 可用,随机漫画 " .. count .. " 本", data = { ok = true, message = "Picacg 可用,随机漫画 " .. count .. " 本" } }
    end)
    if ok then return result end
    return { code = 500, message = tostring(result), data = nil }
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
                { field = "baseUrl", label = "API 地址", required = false, type = "input", inputType = "text" },
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
                },
            },
            actions = {
                { field = "loginBtn", label = "登录", action = "loginBtn" },
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
            return { code = 400, message = "邮箱必填", data = nil }
        end
        if not data.password or data.password == "" then
            return { code = 400, message = "密码必填", data = nil }
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
        if err then return { code = 400, message = err, data = nil } end
        return { code = 0, message = "Picacg 登录成功", data = { ok = true, message = "Picacg 登录成功" } }
    elseif action == "logoutBtn" then
        lime.storage.remove("token")
        lime.storage.remove("account")
        return { code = 0, message = "已登出 Picacg", data = { ok = true, message = "已登出 Picacg" } }
    end
    return { code = 400, message = "settingsAction: unknown action '" .. tostring(action) .. "'", data = nil }
end

-- =====================================================================
-- 统一 Lua ApiResponse 包装:业务入口与 settingsAction 返回 `{ code, message, data }`。
-- settings() 是 schema 声明,保持原数组返回。
-- =====================================================================
local function apiOk(data, message)
    return { code = 0, message = message or "ok", data = data }
end

local function apiFail(message, code)
    return { code = code or 500, message = tostring(message or "unknown error"), data = nil }
end

local function classifyError(message)
    local text = tostring(message or "")
    if text:match("invalid email or password") then return 400 end
    if text:match("Picacg 请求失败") then return 400 end
    if text:match("未登录") then return 400 end
    if text:match("必填") then return 400 end
    if text:match("unknown action") then return 400 end
    return 500
end

local function safeApi(fn)
    local ok, result = pcall(fn)
    if ok and type(result) == "table" and result.code ~= nil then return result end
    if ok then return apiOk(result) end
    return apiFail(result, classifyError(result))
end

local rawSearch = search
function search(keyword, page)
    return safeApi(function() return rawSearch(keyword, page) end)
end

local rawExplore = explore
function explore()
    return safeApi(function() return rawExplore() end)
end

local rawSettings = settings
function settings()
    return safeApi(function() return rawSettings() end)
end

local rawExploreSearch = exploreSearch
function exploreSearch(keyword, payload)
    return safeApi(function() return rawExploreSearch(keyword, payload) end)
end

local rawResourceInfo = resourceInfo
function resourceInfo(url)
    return safeApi(function() return rawResourceInfo(url) end)
end

local rawChapterList = chapterList
function chapterList(url)
    return safeApi(function() return rawChapterList(url) end)
end

local rawChapterContent = chapterContent
function chapterContent(chapterUrl)
    return safeApi(function() return rawChapterContent(chapterUrl) end)
end

local rawTest = test
function test(content)
    return safeApi(function() return rawTest(content) end)
end

local rawSettingsAction = settingsAction
function settingsAction(data)
    return safeApi(function() return rawSettingsAction(data) end)
end
