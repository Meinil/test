local SITES = {
    "https://www.alicesw.com",
    "https://www.alicesw5.homes",
    "https://www.alicesw6.homes",
    "https://www.alicesw7.homes",
}
local SITE_KEY = "site_origin"
local LOCALE = "zh=hans"
local PAGE_SIZE = 12
local SHELF_PAGE_SIZE = 20
local AGE_RECEIPT_LIFETIME = 365 * 24 * 60 * 60
local HTTP_HEADERS = { ["User-Agent"] = "Lime" }

local SECTIONS = {
    { field = "home", label = "网站首页" },
    { field = "rank", label = "排行榜单" },
    { field = "latest", label = "最新连载" },
    { field = "shelf", label = "书架收藏" },
}
local RANKS = {
    { field = "18", label = "热度榜" },
    { field = "19", label = "新书榜" },
    { field = "20", label = "飙升榜" },
    { field = "21", label = "收藏榜" },
}
local PERIODS = {
    { field = "day", label = "日榜" },
    { field = "week", label = "周榜" },
    { field = "month", label = "月榜" },
}
local CATEGORIES = {
    { field = "all", label = "全部" },
    { field = "17", label = "校园" }, { field = "18", label = "玄幻" },
    { field = "19", label = "乡村" }, { field = "20", label = "都市" },
    { field = "21", label = "乱伦" }, { field = "22", label = "武侠" },
    { field = "23", label = "系统" }, { field = "24", label = "穿越" },
    { field = "25", label = "科幻" }, { field = "27", label = "同人" },
    { field = "28", label = "奇幻" }, { field = "26", label = "明星" },
    { field = "7", label = "百合" }, { field = "4", label = "重口" },
    { field = "5", label = "反差" }, { field = "3", label = "纯爱" },
    { field = "8", label = "萝莉" }, { field = "9", label = "正太" },
    { field = "10", label = "伪娘" }, { field = "6", label = "凌辱" },
    { field = "11", label = "媚黑" }, { field = "12", label = "NTR" },
    { field = "13", label = "熟女" }, { field = "16", label = "言情" },
    { field = "15", label = "调教" }, { field = "30", label = "耽美" },
    { field = "2", label = "堕落" }, { field = "29", label = "经典" },
    { field = "14", label = "其他" },
}
local STATUSES = {
    { field = "all", label = "全部" },
    { field = "published", label = "连载中" },
    { field = "completed", label = "已完结" },
}
local SOURCES = {
    { field = "all", label = "全部" },
    { field = "original", label = "原创" },
}
local PUBLICATION_STATUS = { published = 1, serializing = 1, completed = 2 }

local function siteOrigin()
    local saved = lime.storage.get(SITE_KEY)
    for _, site in ipairs(SITES) do
        if saved == site then return site end
    end
    return SITES[1]
end

local function trim(value)
    return type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
end

local function text(node)
    return node and trim(lime.dom.text(node)) or ""
end

local function attr(node, name)
    return node and lime.dom.attr(node, name) or nil
end

local function selectText(node, selector)
    return text(lime.dom.select(node, selector))
end

-- 站内资源跟随当前线路，站外图片保留公开 URL。
local function absoluteUrl(value, origin)
    value = trim(value)
    if value:match("^https?://") then return value end
    if value:sub(1, 2) == "//" then return "https:" .. value end
    if value:sub(1, 1) == "/" then return origin .. value end
end

local function routedNumber(url, route)
    local path = trim(url):gsub("^https?://[^/]+", ""):match("^[^?#]*")
    return path:match("^/" .. route .. "/(%d+)/?$")
end

local function positiveInteger(value)
    local number = tonumber(value)
    return number and number > 0 and math.tointeger(number) or nil
end

local function timestamp(value)
    -- 接口统一使用 UTC ISO 8601，忽略毫秒。
    if type(value) ~= "string" then return nil end
    local date, time = value:match("^(%d%d%d%d%-%d%d%-%d%d)T(%d%d:%d%d:%d%d)[%.%d]*Z$")
    if not date then return nil end
    return lime.time.parse_offset("YYYY-MM-dd HH:mm:ss", date .. " " .. time, 0)
end

local function queryValue(value, options, default)
    for _, option in ipairs(options) do
        if value == option.field then return value end
    end
    return default
end

local function rankPeriods(rank)
    if rank ~= "21" then return PERIODS, "week" end
    return { PERIODS[1], PERIODS[2], PERIODS[3], { field = "total", label = "总榜" } }, "total"
end

local function addQuery(parts, key, value)
    if value ~= nil and value ~= "" then
        parts[#parts + 1] = key .. "=" .. lime.crypto.urlEncode(tostring(value))
    end
end

local function get(url)
    return lime.http.get(url, HTTP_HEADERS)
end

local function checkedBody(response)
    if response.status == 429 then
        error({ code = 2003, message = "爱丽丝书屋请求过于频繁，请稍后重试" })
    end
    if response.status < 200 or response.status >= 300 then
        error({ code = 2006, message = "爱丽丝书屋返回 HTTP " .. tostring(response.status) })
    end
    return response.body
end

local function checkedData(response)
    local payload = lime.json.decode(checkedBody(response))
    if type(payload) ~= "table" then
        error({ code = 2007, message = "爱丽丝书屋响应格式无效" })
    end
    if payload.code ~= nil and payload.code ~= 200 and payload.code ~= 0 then
        error({ code = 2001, message = "爱丽丝书屋未接受该请求" })
    end
    if type(payload.data) ~= "table" then
        error({ code = 2004, message = "爱丽丝书屋数据结构已变化" })
    end
    return payload.data
end

local function siteScope(origin)
    return { scheme = "https", host = origin:sub(9), includeSubdomains = false }
end

local function escapedOrigin(origin)
    return origin:gsub("%.", "\\.")
end

-- 阅读时展示站点的年龄提示，由用户在站点确认后点击窗口右上角的完成按钮。
-- Android 会把不存在的 localStorage 键采集为 null，使用键名自动完成会误关窗口。
local function confirmAge(origin, url)
    local scope = siteScope(origin)
    local profile = "consent-v3-" .. scope.host:gsub("%.", "-")
    local receiptKey = "age_consent_receipt:" .. scope.host
    local now = lime.time.unix()
    local confirmedAt = positiveInteger(lime.storage.get(receiptKey))
    if confirmedAt and confirmedAt <= now and now - confirmedAt < AGE_RECEIPT_LIFETIME then return end
    local result = lime.browser.open({
        profile = profile, url = url, reason = "consent",
        scopes = { scope },
    })
    if result.status ~= 204 then
        error({ code = 2001, message = "爱丽丝书屋尚未完成年龄确认" })
    end
    lime.storage.set(receiptKey, tostring(lime.time.unix()))
end

-- 宿主负责采集和注入 access token，Lua 只处理接口的登录要求。
local function login(origin)
    local scope = siteScope(origin)
    local profile = "bookshelf-v2-" .. scope.host:gsub("%.", "-")
    lime.browser.open({
        profile = profile, url = origin .. "/login?redirect=%2Fbookshelf", reason = "login",
        scopes = { scope },
        captures = { { origin = origin .. "/", keys = { "access_token" } } },
        completion = {
            mode = "all",
            urlPatterns = { "^" .. escapedOrigin(origin) .. "/bookshelf(?:[/?#]|$)" },
            localStorageKeys = { "access_token" },
        },
        injections = {{
            scope = scope, header = "Authorization",
            storageOrigin = origin .. "/", storageKey = "access_token", prefix = "Bearer ",
        }},
    })
end

local function shelfResponse(origin, url)
    local response = get(url)
    if response.status ~= 401 then return response end
    login(origin)
    response = get(url)
    if response.status == 401 then
        error({ code = 2002, message = "爱丽丝书屋会话已失效，请重新登录后再试" })
    end
    return response
end

local function shelfGroups(origin)
    local options = {{ field = "all", label = "全部" }}
    local response = get(origin .. "/api/v1/bookshelf/groups?" .. LOCALE)
    -- 用户应用书架筛选后才触发登录，登录后的书架结果会刷新筛选项。
    if response.status < 200 or response.status >= 300 then return options end
    for _, group in ipairs(checkedData(response)) do
        local id = positiveInteger(group.id)
        local name = trim(group.name)
        if id and name ~= "" then
            options[#options + 1] = { field = tostring(id), label = name }
        end
    end
    return options
end

local function recordUrl(origin, bookNo)
    local path = "/books/" .. bookNo
    return SITES[1] .. path, origin .. path
end

-- 首页展示条目与 API 书籍都使用公开书号作为跨线路的来源身份。
local function bookRecord(book, origin)
    if type(book) ~= "table" then return nil end
    local bookNo = positiveInteger(book.book_no) or positiveInteger(book.id)
    local name = trim(book.title)
    if not bookNo or name == "" then return nil end
    local id, url = recordUrl(origin, bookNo)
    local cover = absoluteUrl(book.cover_url, origin)
    local author = trim(type(book.author) == "table" and book.author.pen_name or book.author_name)
    -- Next.js 在作品详情的渲染数据里用 "$undefined" 表示未填写的原作者。
    local originalAuthor = trim(book.original_author)
    if originalAuthor ~= "" and originalAuthor ~= "$undefined" then author = originalAuthor end
    if author == "$undefined" then author = "" end
    local tags = {}
    for _, tag in ipairs(book.tags or {}) do
        local name = trim(type(tag) == "table" and tag.name or tag)
        if name ~= "" then tags[#tags + 1] = name end
    end
    return {
        id = id, url = url, name = name,
        author = author ~= "" and author or nil,
        cover = cover and { url = cover } or nil,
        intro = trim(book.synopsis or book.summary),
        tags = tags,
        wordCount = math.tointeger(book.word_count or book.total_words),
        chapterCount = math.tointeger(book.chapter_count or book.total_chapters),
        latestUpdateTime = timestamp(book.last_chapter_at or book.last_chapter_updated_at),
        publicationStatus = PUBLICATION_STATUS[book.status],
    }
end

local function home(origin)
    local doc = lime.dom.parse(checkedBody(get(origin .. "/")))
    local records, byId = {}, {}
    local selector = "a.book-card[href^='/books/'], a.book-feature__link[href^='/books/'], .rank-preview a[href^='/books/']"
    for _, card in ipairs(lime.dom.selectAll(doc, selector)) do
        local bookNo = routedNumber(attr(card, "href"), "books")
        local name = selectText(card, "h3")
        if bookNo and name ~= "" then
            local id, url = recordUrl(origin, bookNo)
            local record = byId[id]
            if not record then
                record = { id = id, url = url, name = name }
                byId[id] = record
                records[#records + 1] = record
            end
            local cover = absoluteUrl(attr(lime.dom.select(card, "img"), "src"), origin)
            if cover and not record.cover then record.cover = { url = cover } end
            if not record.author then
                local author = selectText(card, ".book-feature__author, p.text-text-muted")
                author = trim(author:gsub("^作者%s*：", ""):gsub("^作者%s*:", ""):gsub("%s*·.*$", ""))
                if author ~= "" then record.author = author end
            end
            if not record.intro then
                local intro = selectText(card, ".book-feature__summary")
                if intro ~= "" then record.intro = intro end
            end
        end
    end
    if #records == 0 then error({ code = 2004, message = "未找到爱丽丝书屋首页作品" }) end
    return { records = records }
end

local function booksPage(data, origin, page, shelf)
    local items = data[shelf and "items" or "books"]
    local totalPages = math.tointeger(data.total_pages)
    local total = math.tointeger(data.total)
    if shelf then
        -- 书架接口单独返回分页对象，空书架的 items 可能为 null。
        local pagination = data.pagination
        totalPages = type(pagination) == "table" and math.tointeger(pagination.total_pages)
        total = type(pagination) == "table" and math.tointeger(pagination.total_count)
        if items == nil then items = {} end
    end
    if type(items) ~= "table" or not totalPages or totalPages < 0 or not total or total < 0 then
        error({ code = 2004, message = "爱丽丝书屋分页结构已变化" })
    end
    if page > totalPages then return { records = {}, total = total } end
    local records = {}
    for _, item in ipairs(items) do
        local book = item
        if shelf and type(item) == "table" then
            book = {
                id = item.book_id, book_no = item.book_no, title = item.book_title,
                author_name = item.book_author, cover_url = item.book_cover_url,
                status = item.book_status, chapter_count = item.chapter_count,
            }
        end
        local record = bookRecord(book, origin)
        if record then records[#records + 1] = record end
    end
    if #items > 0 and #records == 0 then
        error({ code = 2004, message = "未找到有效的爱丽丝书屋作品记录" })
    end
    return { records = records, total = total }
end

local function latest(origin, page, keyword, filters)
    local parts = {
        "page=" .. page, "page_size=" .. PAGE_SIZE,
        "sort_by=last_chapter_at", "sort_order=desc", LOCALE,
    }
    addQuery(parts, "q", trim(keyword))
    local category = queryValue(filters.category, CATEGORIES, "all")
    local status = queryValue(filters.status, STATUSES, "all")
    if category ~= "all" then addQuery(parts, "category_id", category) end
    if status ~= "all" then addQuery(parts, "status", status) end
    if filters.source == "original" then parts[#parts + 1] = "is_original=true" end
    local url = origin .. "/api/v1/books?" .. table.concat(parts, "&")
    return booksPage(checkedData(get(url)), origin, page)
end

local function search(query)
    return latest(siteOrigin(), positiveInteger(query.page) or 1, query.keyword, {})
end

local function exploreSchema(query)
    local filters = query.filters or {}
    local section = queryValue(filters.section, SECTIONS, "home")
    local schema = {{
        field = "section", label = "栏目", type = "single",
        default = "home", options = SECTIONS, reloadOnChange = true,
    }}
    local resolved
    if section == "rank" then
        local rank = queryValue(filters.rank, RANKS, "18")
        local periods, default = rankPeriods(rank)
        schema[#schema + 1] = {
            field = "rank", label = "榜单", type = "single",
            default = "18", options = RANKS, reloadOnChange = true,
        }
        schema[#schema + 1] = {
            field = "period", label = "周期", type = "single",
            default = default, options = periods,
        }
        resolved = { rank = rank, period = queryValue(filters.period, periods, default) }
    elseif section == "latest" then
        schema[#schema + 1] = { field = "status", label = "状态", type = "single", default = "all", options = STATUSES }
        schema[#schema + 1] = { field = "source", label = "来源", type = "single", default = "all", options = SOURCES }
    elseif section == "shelf" then
        schema[#schema + 1] = {
            field = "group", label = "分组", type = "single", default = "all", options = shelfGroups(siteOrigin()),
        }
    end
    if section == "rank" or section == "latest" then
        schema[#schema + 1] = { field = "category", label = "分类", type = "single", default = "all", options = CATEGORIES }
    end
    if section == "latest" or section == "shelf" then
        schema[#schema + 1] = { field = "keyword", label = "搜索", type = "text", default = "" }
    end
    return { supportsPagination = section ~= "home", filters = schema, resolvedFilters = resolved }
end

local function browse(query)
    local origin = siteOrigin()
    local page = positiveInteger(query.page) or 1
    local filters = query.filters or {}
    local section = queryValue(filters.section, SECTIONS, "home")
    if section == "home" then
        if page > 1 then return { records = {} } end
        return home(origin)
    end
    if section == "latest" then return latest(origin, page, filters.keyword, filters) end
    if section == "rank" then
        local rank = queryValue(filters.rank, RANKS, "18")
        local periods, default = rankPeriods(rank)
        local period = queryValue(filters.period, periods, default)
        local parts = { "page=" .. page, "page_size=" .. PAGE_SIZE, "period=" .. period, LOCALE }
        local category = queryValue(filters.category, CATEGORIES, "all")
        if category ~= "all" then addQuery(parts, "category_id", category) end
        local url = origin .. "/api/v1/operations/blocks/" .. rank .. "/books?" .. table.concat(parts, "&")
        return booksPage(checkedData(get(url)), origin, page)
    end
    local parts = { "page=" .. page, "page_size=" .. SHELF_PAGE_SIZE, LOCALE }
    addQuery(parts, "q", trim(filters.keyword))
    addQuery(parts, "group_id", positiveInteger(filters.group))
    local url = origin .. "/api/v1/bookshelf?" .. table.concat(parts, "&")
    local result = booksPage(checkedData(shelfResponse(origin, url)), origin, page, true)
    result.schemaStale = page == 1
    return result
end

-- 从服务端渲染的 Next.js 数据中读取一段 JSON 对象，只解码数据。
local function jsonObjectAt(source, start)
    if source:sub(start, start) ~= "{" then return nil end
    local depth, quoted = 0, false
    local cursor = start
    while true do
        local at = source:find('[{}"\\]', cursor)
        if not at then return nil end
        local char = source:sub(at, at)
        cursor = at + 1
        if char == '"' then
            quoted = not quoted
        elseif quoted then
            if char == "\\" then cursor = cursor + 1 end
        else
            if char == "{" then depth = depth + 1 end
            if char == "}" then
                depth = depth - 1
                if depth == 0 then return lime.json.decode(source:sub(start, at)) end
            end
        end
    end
end

local function detailBook(html)
    local stream = {}
    for segment in html:gmatch("self%.__next_f%.push%((%[.-%])%)</script>") do
        if segment:match("^%[1,") then
            local data = lime.json.decode(segment)
            if type(data[2]) == "string" then stream[#stream + 1] = data[2] end
        end
    end
    local source = table.concat(stream)
    local start = source:match('"initialBook"%s*:%s*()')
    local book = start and jsonObjectAt(source, start)
    if not book or not positiveInteger(book.id) then
        error({ code = 2004, message = "未找到爱丽丝书屋作品数据" })
    end
    return book
end

local function resourceUrl(origin, resource)
    local bookNo = routedNumber(resource.url, "books")
    if not bookNo then error({ code = 2005, message = "爱丽丝书屋作品地址格式无效" }) end
    return origin .. "/books/" .. bookNo
end

local function catalogUrl(origin, book)
    -- 公开书号用于网页地址，章节接口要求内部作品 ID。
    return origin .. "/api/v1/books/" .. book.id .. "/chapters?" .. LOCALE
end

local function detailRecord(origin, resource, book)
    local record = bookRecord(book, origin)
    if not record then error({ code = 2004, message = "爱丽丝书屋作品详情缺少必要字段" }) end
    record.id = resource.id
    record.tocUrl = catalogUrl(origin, book)
    return record
end

local function resourceInfo(request)
    local origin = siteOrigin()
    local url = resourceUrl(origin, request.resource)
    return detailRecord(origin, request.resource, detailBook(checkedBody(get(url))))
end

local function catalog(origin, book)
    local data = checkedData(get(catalogUrl(origin, book)))
    local chapters, seen = {}, {}
    for _, item in ipairs(data) do
        local chapterNo = positiveInteger(item.chapter_no)
        local name = trim(item.display_title)
        if name == "" then name = trim(item.title) end
        if chapterNo and name ~= "" and not seen[chapterNo] then
            seen[chapterNo] = true
            local path = "/read/" .. chapterNo
            chapters[#chapters + 1] = {
                id = SITES[1] .. path, url = origin .. path, name = name,
                index = #chapters + 1, chapterUpdateTime = timestamp(item.published_at),
            }
        end
    end
    if #chapters == 0 and (book.total_chapters or 0) > 0 then
        error({ code = 2004, message = "未找到爱丽丝书屋章节目录" })
    end
    return { chapters = chapters }
end

local function chapterList(request)
    local origin = siteOrigin()
    local url = resourceUrl(origin, request.resource)
    return catalog(origin, detailBook(checkedBody(get(url))))
end

local function chapterBlocks(origin, chapterNo, allowLogin)
    local url = origin .. "/api/v1/chapters/" .. chapterNo .. "?" .. LOCALE
    local response = get(url)
    if allowLogin and response.status == 401 then
        local ok, payload = pcall(lime.json.decode, response.body)
        if ok and type(payload) == "table" and payload.code == "GUEST_LOGIN_REQUIRED" then
            login(origin)
            response = get(url)
        end
    end
    local data = checkedData(response)
    if data.can_read ~= true then
        error({ code = 2006, message = "爱丽丝书屋未开放该章的阅读权限，请在站点查看" })
    end
    local content = trim(data.content)
    local blocks = {}
    local function appendText(value)
        if value ~= "" then
            blocks[#blocks + 1] = { id = "text-" .. (#blocks + 1), type = "text", text = value }
        end
    end
    -- 接口正文为纯文本或 HTML。发给宿主的只有文本和图片块。
    local tag = content:lower():match("^<([%w]+)[%s/>]")
    local htmlTags = { p = true, div = true, blockquote = true, ul = true, ol = true,
        h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true,
        pre = true, figure = true, hr = true, img = true }
    if htmlTags[tag] then
        local doc = lime.dom.parse(content)
        local function appendImage(image)
            local imageUrl = absoluteUrl(attr(image, "src"), origin)
            if imageUrl then
                local id = "image-" .. (#blocks + 1)
                blocks[#blocks + 1] = { id = id, type = "image", source = { id = id, url = imageUrl } }
            end
        end
        for _, paragraph in ipairs(lime.dom.selectAll(doc, "body > :not(script, style)")) do
            if lime.dom.tag(paragraph) == "img" then
                appendImage(paragraph)
            else
                appendText(text(paragraph))
                for _, image in ipairs(lime.dom.selectAll(paragraph, "img")) do appendImage(image) end
            end
        end
    else
        for line in content:gmatch("[^\r\n]+") do appendText(trim(line)) end
    end
    if #blocks == 0 then error({ code = 2007, message = "爱丽丝书屋章节正文为空" }) end
    return { blocks = blocks }
end

local function chapterContent(request)
    local origin = siteOrigin()
    local chapterNo = routedNumber(request.chapter.url, "read")
    if not chapterNo then error({ code = 2005, message = "爱丽丝书屋章节地址格式无效" }) end
    local url = origin .. "/read/" .. chapterNo
    confirmAge(origin, url)
    return chapterBlocks(origin, chapterNo, true)
end

local function settings()
    local options = {}
    for _, site in ipairs(SITES) do options[#options + 1] = { value = site, label = site:sub(9) } end
    return {{
        key = "site", label = "书源线路", type = "dialog", icon = "Settings",
        fields = {{ field = "origin", label = "站点域名", type = "select", required = true, default = siteOrigin(), options = options }},
        actions = {{ field = "save", label = "保存", action = "saveSite" }},
    }}
end

local function saveSite(request)
    if request.action == "saveSite" then
        for _, site in ipairs(SITES) do
            if request.data.origin == site then
                lime.storage.set(SITE_KEY, site)
                return { ok = true, message = "线路已保存" }
            end
        end
    end
    error({ code = 2005, message = "无效的线路设置" })
end

-- 检测只校验公开样本的响应结构，不展示正文或启动 WebView。
local function test()
    local origin = siteOrigin()
    local results = {}
    local function run(entry, fn)
        local started = lime.time.unix_ms()
        local value = fn()
        results[#results + 1] = { entry = entry, status = "passed", message = "可用", durationMs = lime.time.unix_ms() - started }
        return value
    end
    local record = run("search", function()
        local item = search({ keyword = "玄幻", page = 1 }).records[1]
        if not item then error({ code = 2007, message = "爱丽丝书屋搜索没有返回样本" }) end
        return item
    end)
    local book = run("resourceInfo", function()
        return detailBook(checkedBody(get(record.url)))
    end)
    local firstChapter = run("chapterList", function()
        local chapter = catalog(origin, book).chapters[1]
        if not chapter then
            error({ code = 2007, message = "爱丽丝书屋检测样本没有章节" })
        end
        return chapter
    end)
    run("chapterContent", function() chapterBlocks(origin, routedNumber(firstChapter.url, "read")) end)
    run("explore", function() home(origin) end)
    return results
end

return {
    kind = "resource", apiVersion = 1,
    manifest = { name = "爱丽丝书屋", package = "com.meinil.lime.ai.alicesw", version = "0.1.3", author = "ai", description = "国内发布页：https://www.asw2.cc/", homepage = SITES[1] },
    requires = { "browser", "crypto", "dom", "http", "json", "storage", "time" },
    capabilities = {
        content = "novel",
        search = search, resourceInfo = resourceInfo,
        chapterList = chapterList, chapterContent = chapterContent,
        explore = browse, exploreSchema = exploreSchema,
    },
    hooks = { test = test, settings = { list = settings, action = saveSite } },
}
