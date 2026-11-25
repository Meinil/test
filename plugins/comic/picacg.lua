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
    local signature = lime.crypto.hmacSha256(SIGN_KEY, signInput)
    if not signature then return nil, "Picacg 签名失败" end

    return {
        ["api-key"] = API_KEY,
        ["accept"] = "application/vnd.picacomic.com.v1+json",
        ["app-channel"] = lime.storage.get("request:appChannel") or "3",
        ["authorization"] = token or "",
        ["time"] = t,
        ["nonce"] = n,
        ["app-version"] = "2.2.1.3.3.4",
        ["app-uuid"] = "defaultUuid",
        ["image-quality"] = lime.storage.get("request:imageQuality") or "original",
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
    return lime.json.decode(body)
end

--- JSON 编码包装。
local function encodeJson(value)
    local body = lime.json.encode(value)
    if not body then return nil, "Picacg JSON 编码失败" end
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
    local response
    if method == "GET" then
        response = lime.http.get(url, headers)
    elseif method == "PUT" then
        local encoded, encodeErr = encodeJson(payload or {})
        if not encoded then return nil, encodeErr end
        response = lime.http.put(url, encoded, headers)
    else
        local encoded, encodeErr = encodeJson(payload or {})
        if not encoded then return nil, encodeErr end
        response = lime.http.post(url, encoded, headers)
    end
    return response, nil
end

local function requireLogin()
    local token = lime.storage.get("token")
    if not token or token == "" then
        error({ code = 2002, message = "请在插件设置中登录 Picacg" })
    end
    return token
end

--- 校验 HTTP 状态与站点业务信封。公开文案不读取上游 message。
local function requestEnvelope(method, path, payload, token, form)
    local url = baseUrl(form and form.baseUrl) .. "/" .. path
    local authToken = token == nil and requireLogin() or token
    local headers, headerErr = buildHeaders(method, path, authToken, form)
    if not headers then return nil, headerErr end
    local response, requestError = sendRequest(method, url, headers, payload)
    if requestError then return nil, requestError end
    if response.status == 401 and authToken ~= "" then
        error({ code = 2002, message = "Picacg 登录已失效，请重新登录" })
    end
    if response.status < 200 or response.status >= 300 then
        error({ code = 2006, message = "Picacg 请求失败：HTTP " .. tostring(response.status) })
    end
    local json = decodeJson(response.body or "")
    local code = type(json) == "table" and tonumber(json.code)
    if not code then
        error({ code = 2007, message = "Picacg 响应缺少业务状态" })
    end
    if code == 401 and authToken ~= "" then
        error({ code = 2002, message = "Picacg 登录已失效，请重新登录" })
    end
    if code ~= 200 then
        error({ code = 2001, message = "Picacg 拒绝请求，业务状态码：" .. tostring(code) })
    end
    return json
end

--- 返回已验证信封中的业务数据。
local function requestJson(method, path, payload, token, form)
    local json, err = requestEnvelope(method, path, payload, token, form)
    if not json then return nil, err end
    if type(json.data) ~= "table" then
        error({ code = 2007, message = "Picacg 响应缺少业务数据" })
    end
    return json.data
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
        cover = trim(imageUrl(comic.thumb)) ~= "" and { url = imageUrl(comic.thumb) } or nil,
        intro = trim(comic.description),
        latestChapter = "",
        latestUpdateTime = parseIsoTimestamp(comic.updated_at),
        chapterCount = tonumber(comic.epsCount or 0) or 0,
        wordCount = tonumber(comic.pagesCount or 0) or 0,
        tags = tags,
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
--- POST users/punch-in(需 token,空 body)，成功时使用固定文案。
local function punchInAccount(form)
    local envelope, reqErr = requestEnvelope("POST", "users/punch-in", {}, nil, form)
    if not envelope then return nil, reqErr end
    return true, "打卡成功"
end

--- 搜索漫画。


--- 发现页筛选声明。
local function exploreSchema(query)
    local filters = query and query.filters or {}
    local source = filters.source or "latest"
    local hasCategory = filters.category and filters.category ~= ""
    local supportsPagination = hasCategory or source == "latest"
    local categoryOptions = {}
    for _, category in ipairs(CATEGORIES) do
        categoryOptions[#categoryOptions + 1] = { field = category, label = category }
    end
    return {
        supportsPagination = supportsPagination,
        filters = {
            { field = "source", label = "来源", type = "single", default = "latest", options = SOURCE_OPTIONS, reloadOnChange = true },
            { field = "category", label = "分类", type = "single", options = categoryOptions, reloadOnChange = true },
            { field = "sort", label = "排序", type = "single", options = SORT_OPTIONS, default = SORT_OPTIONS[1].field },
        },
    }
end

local function parseComicsPage(comics, current)
    if type(comics) ~= "table" then error("Picacg 搜索响应缺少漫画分页") end
    local pages = tonumber(comics.pages)
    local total = tonumber(comics.total)
    if not total or total < 0 or total ~= math.floor(total) then total = nil end
    if pages and current > pages then return { records = {}, total = total } end
    local actualPage = tonumber(comics.page)
    if actualPage and actualPage ~= current then error("Picacg 返回的页码与请求不一致") end
    if type(comics.docs) ~= "table" then error("Picacg 搜索缺少结果列表") end
    return { records = docsToResources(comics.docs), total = total }
end

--- 普通全局搜索。
local function search(query)
    requireLogin()
    query = query or {}
    local kw = trim(query.keyword or "")
    local current = tonumber(query.page) or 1
    local path = "comics/advanced-search?page=" .. current
    local data, err = requestJson("POST", path, { keyword = kw, sort = "dd" })
    if not data then error(err) end
    return parseComicsPage(data.comics, current)
end

--- 发现页分类/榜单浏览。
local function browse(query)
    requireLogin()
    query = query or {}
    local filters = query.filters or {}
    local current = tonumber(query.page) or 1
    local sort = filters.sort or "dd"

    if filters.category and filters.category ~= "" then
        local category, _ = lime.crypto.urlEncode(filters.category)
        local path = "comics?page=" .. current .. "&c=" .. category .. "&s=" .. sort
        local data, err = requestJson("GET", path)
        if not data then error(err) end
        return parseComicsPage(data.comics, current)
    end

    local source = filters.source or "latest"
    if source == "random" then
        if current > 1 then return { records = {} } end
        local data, err = requestJson("GET", "comics/random")
        if not data then error(err) end
        return { records = docsToResources(data.comics or {}) }
    end
    if source == "H24" or source == "D7" or source == "D30" then
        if current > 1 then return { records = {} } end
        local path = "comics/leaderboard?tt=" .. source .. "&ct=VC"
        local data, err = requestJson("GET", path)
        if not data then error(err) end
        return { records = docsToResources(data.comics or {}) }
    end

    local path = "comics?page=" .. current .. "&s=" .. sort
    local data, err = requestJson("GET", path)
    if not data then error(err) end
    return parseComicsPage(data.comics, current)
end

--- 拉取漫画详情。
local function resourceInfo(url)
    local id = tostring(url or "")
    if id == "" then error("漫画 ID 为空") end
    requireLogin()
    local data, err = requestJson("GET", "comics/" .. id)
    if not data then error(err) end
    local comic = data.comic or {}
    local item = comicToResource(comic)
    item.url = id
    item.intro = trim(comic.description)
    item.latestChapter = ""
    return item
end

--- 将 Picacg 章节对象映射为稳定 id 与数字 order 路由分离的章节描述符。
local function buildChapterDescriptors(comicId, eps)
    table.sort(eps, function(a, b)
        return (tonumber(a.order) or 0) < (tonumber(b.order) or 0)
    end)
    local chapters = {}
    for index, ep in ipairs(eps) do
        local sourceId = tostring(ep._id or ep.id or ep.order or index)
        chapters[#chapters + 1] = {
            id = sourceId,
            name = trim(ep.title) ~= "" and trim(ep.title) or ("第 " .. index .. " 章"),
            url = comicId .. "#" .. tostring(index),
            index = index - 1,
        }
    end
    return chapters
end

--- 拉取章节列表。
local function chapterList(url)
    local id = tostring(url or "")
    if id == "" then error("漫画 ID 为空") end
    requireLogin()
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

    local chapters = buildChapterDescriptors(id, all)
    return { chapters = chapters }
end

--- 拉取章节图片。
local function chapterContent(request)
    local chapterUrl = request.chapter.url
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
                    id = "image-" .. tostring(#blocks + 1),
                    type = "image",
                    source = {
                        id = "image-source-" .. tostring(#blocks + 1),
                        url = img,
                        headers = {
                            ["User-Agent"] = USER_AGENT,
                            ["Accept"] = "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
                        },
                    },
                }
            end
        end
        if not pages.pages or page >= tonumber(pages.pages) then break end
        page = page + 1
    end

    if #blocks == 0 then error("章节内容为空") end
    return { blocks = blocks }
end

local settings

local function test(request)
    local results, records, info, catalog = {}, nil, nil, nil
    local function run(entry, fn)
        local value = fn()
        results[#results + 1] = { entry = entry, status = "passed", message = "可用" }
        return value
    end
    records = run("search", function() local value = search({ keyword = "comic", page = 1 }).records; if #value == 0 then error("搜索无结果") end; return value end)
    info = run("resourceInfo", function() return resourceInfo(records[1].url) end)
    catalog = run("chapterList", function() return chapterList(info.url) end)
    if not catalog.chapters or not catalog.chapters[1] then error("目录没有可检测的章节") end
    run("chapterContent", function() return chapterContent({ resource = { url = info.url }, chapter = catalog.chapters[1] }) end)
    run("explore", exploreSchema)
    return results
end

--- 设置菜单。
settings = function()
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
                { field = "baseUrl", label = "API 地址", required = false, type = "input", inputType = "text", default = DEFAULT_BASE_URL },
            },
            actions = {
                { field = "loginBtn", label = "登录", action = "loginBtn" },
            },
        },
        {
            label = "请求设置",
            key = "request",
            type = "dialog",
            icon = "Settings2",
            fields = {
                {
                    field = "imageQuality",
                    label = "图片质量",
                    required = true,
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
                    required = true,
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
                { field = "saveRequestSettings", label = "保存", action = "saveRequestSettings" },
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
local function settingsAction(action, data)
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
        local _, err = login(data.username, data.password, data)
        if err then error(err) end
        return { ok = true, message = "Picacg 登录成功" }
    elseif action == "saveRequestSettings" then
        return { ok = true, message = "请求设置已保存" }
    elseif action == "registerBtn" then
        local _, err = registerAccount(data, data)
        if err then error(err) end
        return { ok = true, message = "注册成功,请用新账号登录" }
    elseif action == "changePasswordBtn" then
        if not lime.storage.get("token") then
            requireLogin()
        end
        local _, err = changeAccountPassword(data.oldPassword, data.newPassword, data)
        if err then error(err) end
        return { ok = true, message = "密码已修改" }
    elseif action == "punchInBtn" then
        if not lime.storage.get("token") then
            requireLogin()
        end
        local _, msg = punchInAccount(data)
        if not msg then error("打卡失败") end
        return { ok = true, message = msg }
    elseif action == "logoutBtn" then
        lime.storage.remove("token")
        lime.storage.remove("account")
        return { ok = true, message = "已登出 Picacg" }
    end
    error("Picacg 不支持该设置操作")
end

-- 资源身份由来源明确提供，此来源使用规范 URL 作为稳定 id。
local function resourceRecord(record)
    record.id = record.url

    return record
end

local function searchResources(query)
    local page = search(query)
    for _, record in ipairs(page.records) do resourceRecord(record) end
    return page
end

local function browseResources(query)
    local page = browse(query)
    for _, record in ipairs(page.records) do resourceRecord(record) end
    return page
end

local function describeResource(request)
    local record = resourceRecord(resourceInfo(request.resource.url))
    record.id = request.resource.id
    return record
end

local function listResourceChapters(request)
    return chapterList(request.resource.url, { routeId = request.routeId })
end

local function invokeSettings(request)
    return settingsAction(request.action, request.data)
end

return {
    kind = "resource",
    apiVersion = 1,
    manifest = {
        name = "Picacg",
        package = "com.meinil.lime.ai.picacg",
        version = "0.0.2",
        author = "ai",
        description = "Picacg 漫画源,支持登录、搜索、发现、详情、章节与图片阅读。",
        homepage = "https://www.bikamanhua.com.cn",
        logo = "https://www.bikamanhua.com.cn/logo.png",
    },
    requires = { "crypto", "http", "json", "log", "storage", "time" },

    capabilities = {
        content = "comic",
        search = searchResources, resourceInfo = describeResource,
        chapterList = listResourceChapters, chapterContent = chapterContent,
        explore = browseResources,
        exploreSchema = exploreSchema,
    },
    hooks = {
        settings = { list = settings, action = invokeSettings },
        test = test,
    },
}
