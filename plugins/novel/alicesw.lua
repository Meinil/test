local SITES = {
    "https://www.alicesw.com",
    "https://www.alicesw5.homes",
    "https://www.alicesw6.homes",
    "https://www.alicesw7.homes",
}
local SITE_KEY = "site_origin"
local TZ_OFFSET = 8 * 60 * 60

local function siteOrigin()
    local saved = lime.storage.get(SITE_KEY)
    for _, site in ipairs(SITES) do
        if site == saved then return site end
    end
    return SITES[1]
end

local CATEGORIES = {
    { field = "hits", label = "总排行" },
    { field = "hits_month", label = "月排行" },
    { field = "hits_week", label = "周排行" },
    { field = "hits_day", label = "日排行" },
    { field = "71", label = "科幻" },
    { field = "61", label = "校园" },
    { field = "62", label = "玄幻" },
    { field = "63", label = "乡村" },
    { field = "64", label = "都市" },
    { field = "65", label = "乱伦" },
    { field = "67", label = "历史" },
    { field = "68", label = "武侠" },
    { field = "69", label = "系统" },
    { field = "72", label = "明星" },
    { field = "73", label = "同人" },
    { field = "74", label = "强奸" },
    { field = "75", label = "奇幻" },
    { field = "79", label = "经典" },
    { field = "70", label = "穿越" },
    { field = "46", label = "凌辱" },
    { field = "22", label = "反差" },
    { field = "18", label = "堕落" },
    { field = "19", label = "纯爱" },
    { field = "52", label = "伪娘" },
    { field = "48", label = "萝莉" },
    { field = "56", label = "熟女" },
    { field = "51", label = "禁忌" },
    { field = "54", label = "NTR" },
    { field = "53", label = "媚黑" },
    { field = "55", label = "绿帽" },
    { field = "58", label = "调教" },
    { field = "59", label = "女主" },
    { field = "50", label = "正太" },
    { field = "43", label = "下克上" },
    { field = "47", label = "百合" },
    { field = "21", label = "重口" },
}

local function trim(s)
    if not s or s == "" then return "" end
    s = tostring(s):gsub("^%s+", ""):gsub("%s+$", "")
    s = s:gsub("^\227\128\128+", ""):gsub("\227\128\128+$", "")
    s = s:gsub("^\194\160+", ""):gsub("\194\160+$", "")
    return s
end

local function text(el)
    return el and trim(lime.dom.text(el) or "") or ""
end

local function attr(el, key)
    return el and lime.dom.attr(el, key) or nil
end

local function subdoc(el)
    return lime.dom.parse(lime.dom.html(el))
end

local function selectText(doc, selector)
    return text(lime.dom.select(doc, selector))
end

local function selectAttr(doc, selector, key)
    return attr(lime.dom.select(doc, selector), key)
end

-- 站内资源使用当前线路，站外封面等资源保留原地址。
local function absolutize(url, base)
    if not url or url == "" then return "" end
    if url:match("^https?://") then return url end
    if url:sub(1, 2) == "//" then return "https:" .. url end
    if url:sub(1, 1) == "/" then return base:match("^https?://[^/]+") .. url end
    return (base:match("^(https?://.+)/[^/]*$") or base) .. "/" .. url
end

-- 书籍和章节 URL 的路径在不同线路间相同。
local function resourcePath(url)
    return (url:gsub("^https?://[^/]+", ""))
end

-- 由站点页面完成协议确认；各镜像有独立的同源状态和 Profile。
local function confirmSite(origin)
    local host = origin:sub(9)
    lime.browser.open({
        profile = "consent-" .. host:gsub("%.", "-"), url = origin .. "/", reason = "consent",
        scopes = {{ scheme = "https", host = host, includeSubdomains = false }},
        captures = {{ origin = origin .. "/", keys = { "ageVerified" } }},
        completion = { localStorageValues = { ageVerified = "true" } },
    })
end

local function httpGet(url, retryRank)
    confirmSite(siteOrigin())
    local response = lime.http.get(url)
    -- 排行页偶发 HTTP 500 时，只在当前已确认的线路重试一次。
    if retryRank and response.status == 500 then
        response = lime.http.get(url)
        if response.status == 500 then
            error("排行榜返回 HTTP 500，请稍后重试，或在插件设置中手动切换线路 (" .. url .. ")")
        end
    end
    if response.status < 200 or response.status >= 300 then
        error("lime.http.get: HTTP " .. tostring(response.status) .. " (" .. url .. ")")
    end
    return response.body
end

local function parseCount(value)
    local s = tostring(value or "")
    local n = tonumber(s:match("([0-9]+%.?[0-9]*)"))
    if not n then return 0 end
    if s:find("万", 1, true) then return math.floor(n * 10000 + 0.5) end
    return math.floor(n)
end

local function parseTime(value, fmt)
    local s = trim(value)
    if s == "" then return 0 end
    fmt = fmt or "更新时间：YYYY-MM-dd HH:mm"
    local ts, err = lime.time.parse_offset(fmt, s, TZ_OFFSET)
    if ts then return ts end
    lime.log.warn("time parse failed: " .. s .. " " .. tostring(err))
    return 0
end

local function tocUrlFromBookUrl(url)
    return (url:gsub("/novel/(%d+)%.html$", "/other/chapters/id/%1.html"))
end

local function htmlToText(html)
    if not html then return "" end
    local s = tostring(html)
        :gsub("<br ?/?>", "\n")
        :gsub("<[^>]+>", "")
        :gsub("&emsp;", "    ")
        :gsub("&nbsp;", " ")
        :gsub("&amp;", "&")
        :gsub("&lt;", "<")
        :gsub("&gt;", ">")
        :gsub("&quot;", '"')
        :gsub("&#39;", "'")
        :gsub("\r", "")
    return trim(s)
end

local function resourceFromRankItem(item, baseUrl)
    local doc = subdoc(item)
    local titleEl = lime.dom.select(doc, "li.two a")
    local latestEl = lime.dom.select(doc, "li.three a")
    local kind = selectText(doc, "li.sev a")
    local url = absolutize(attr(titleEl, "href"), baseUrl)
    local latestUrl = absolutize(attr(latestEl, "href"), baseUrl)
    local latestTime = parseTime(selectText(doc, "li.six"))
    return {
        name = text(titleEl),
        author = selectText(doc, "li.four"),
        url = url,
        cover = nil,
        intro = "",
        latestChapter = text(latestEl),
        latestChapterUrl = latestUrl,
        kind = kind,
        tags = kind ~= "" and { kind } or {},
        wordCount = parseCount(selectText(doc, "li.five")),
        chapterCount = 0,
        latestUpdateTime = latestTime,
    }
end

local function parseRankResources(doc, baseUrl)
    local items = lime.dom.selectAll(doc, ".rec_rullist > ul")
    local out = {}
    for _, item in ipairs(items or {}) do
        local resource = resourceFromRankItem(item, baseUrl)
        if resource.name ~= "" and resource.url ~= "" then out[#out + 1] = resource end
    end
    return out
end

local function parseSearchResources(doc, baseUrl)
    local items = lime.dom.selectAll(doc, ".list-group .list-group-item")
    local out = {}
    for _, item in ipairs(items or {}) do
        local sub = subdoc(item)
        local titleEl = lime.dom.select(sub, "h5 a")
        local name = text(titleEl):gsub("^%d+%.", "")
        local url = absolutize(attr(titleEl, "href"), baseUrl)
        local author = selectText(sub, "p.mb-1.text-muted a")
        local kind = selectText(sub, "p.text-muted a")
        local latestTime = parseTime(selectText(sub, "p.mb-1.text-muted"))
        if name ~= "" and url ~= "" then
            out[#out + 1] = {
                name = name,
                author = author,
                url = url,
                cover = nil,
                intro = selectText(sub, "p.content-txt"),
                latestChapter = "",
                latestChapterUrl = "",
                kind = kind,
                tags = kind ~= "" and { kind } or {},
                wordCount = parseCount(selectText(sub, "p.mb-1.text-muted")),
                chapterCount = 0,
                latestUpdateTime = latestTime,
            }
        end
    end
    return out
end

local function parseStats(doc)
    local textValue = selectText(doc, "#detail-box .novel_info p:nth-child(4)")
    if textValue == "" then textValue = selectText(doc, ".novel_info") end
    local wordText = textValue:match("字%s*数[：:]%s*([^·]+)") or textValue:match("([0-9%.]+%s*万?)%s*字") or ""
    local chapterText = textValue:match("章%s*节[：:]%s*(%d+)") or ""
    local chapterCount = tonumber(chapterText) or 0
    return parseCount(wordText), chapterCount
end

local function parseDetail(html, url)
    local doc = lime.dom.parse(html or "")
    local name = selectText(doc, "#detail-box .novel_info h1")
    if name == "" then name = selectText(doc, ".box_info > .novel_title") end
    if name == "" then name = selectAttr(doc, "meta[property='og:novel:book_name']", "content") or "" end
    local author = selectText(doc, "#detail-box .novel_info a[href*='f=author']")
    if author == "" then author = selectText(doc, "#detail-box .novel_info p:nth-child(2) a") end
    local cover = selectAttr(doc, "#detail-box img", "data-src") or selectAttr(doc, "#detail-box img", "src") or ""
    local intro = selectText(doc, ".jianjie > p")
    if intro == "" then intro = selectText(doc, "#detail-box .book_intro") end
    local kind = selectText(doc, "#detail-box .novel_info a[href*='/lists/']")
    -- 「最新」在书籍信息第六行；下方章节列表还包含「查看所有章节」。
    local latestEl = lime.dom.select(doc, "#detail-box .novel_info > p:nth-of-type(6) > a[href*='/book/']")
    local tags = {}
    for _, link in ipairs(lime.dom.selectAll(doc, "#detail-box .box_info > .tags_list a[href*='f=tag']")) do
        local tag = trim((text(link):gsub("^#", "")))
        if tag ~= "" then tags[#tags + 1] = tag end
    end
    local wordCount, chapterCount = parseStats(doc)
    local tocUrl = tocUrlFromBookUrl(url)
    if chapterCount == 0 then
        local links = lime.dom.selectAll(doc, "ul.mulu_list li a")
        chapterCount = links and #links or 0
    end
    local latestUpdateTime = 0
    local timeEl = lime.dom.select(doc, "#detail-box > div.book_newchap > div.con > li:nth-child(1) > em")
    if timeEl then
        latestUpdateTime = parseTime(lime.dom.text(timeEl), "更新时间：YYYY-MM-dd HH:mm")
    end
    return {
        name = name,
        author = author,
        url = url,
        cover = absolutize(cover, url) ~= "" and { url = absolutize(cover, url) } or nil,
        intro = intro,
        latestChapter = text(latestEl),
        latestChapterUrl = absolutize(attr(latestEl, "href"), url),
        kind = kind,
        tags = tags,
        tocUrl = tocUrl,
        wordCount = wordCount,
        chapterCount = chapterCount,
        latestUpdateTime = latestUpdateTime,
    }
end

local function resourceInfo(request)
    local url = absolutize(resourcePath(request.resource.url), siteOrigin())
    local record = parseDetail(httpGet(url), url)
    record.id = request.resource.id
    return record
end

local function chapterList(request)
    local fullUrl = tocUrlFromBookUrl(absolutize(resourcePath(request.resource.url), siteOrigin()))
    local html = httpGet(fullUrl)
    local doc = lime.dom.parse(html)
    if not lime.dom.select(doc, "ul.mulu_list") then error("未找到章节目录") end
    local links = lime.dom.selectAll(doc, "ul.mulu_list li a")
    local chapters = {}
    local seen = {}
    for _, link in ipairs(links or {}) do
        local url = absolutize(attr(link, "href"), fullUrl)
        local name = text(link)
        if name ~= "" and url ~= "" and not seen[url] then
            seen[url] = true
            chapters[#chapters + 1] = { id = SITES[1] .. resourcePath(url), name = name, url = url, index = #chapters + 1 }
        end
    end
    return { chapters = chapters }
end

local function chapterContent(request)
    local fullUrl = absolutize(resourcePath(request.chapter.url), siteOrigin())
    local html = httpGet(fullUrl)
    local doc = lime.dom.parse(html)
    local paragraphs = lime.dom.selectAll(doc, ".read-content p")
    local chunks = {}
    for _, p in ipairs(paragraphs or {}) do
        local value = text(p)
        if value ~= "" then chunks[#chunks + 1] = value end
    end
    if #chunks == 0 then
        local contentEl = lime.dom.select(doc, ".read-content")
        if contentEl then chunks[#chunks + 1] = htmlToText(lime.dom.html(contentEl)) end
    end
    local blocks = {}
    for para in table.concat(chunks, "\n"):gmatch("[^\n]+") do
        para = trim(para)
        if para ~= "" then
            blocks[#blocks + 1] = { id = "text-" .. (#blocks + 1), type = "text", text = para }
        end
    end
    if #blocks == 0 then error("章节内容为空") end
    return { blocks = blocks }
end

local function explore()
    local options = {}
    for _, c in ipairs(CATEGORIES) do options[#options + 1] = { field = c.field, label = c.label } end
    return {
        { field = "category", label = "分类", type = "single", options = options },
    }
end

local function search(query)
    local keyword = trim(query.keyword)
    local filters = query.filters or {}
    local page = query.page or 1
    local origin = siteOrigin()
    local url, doc, records
    if keyword ~= "" and next(filters) == nil then
        local encoded, err = lime.crypto.urlEncode(keyword)
        if not encoded then error("搜索词编码失败：" .. tostring(err)) end
        url = origin .. "/search.html?q=" .. encoded .. "&f=_all&p=" .. page
        doc = lime.dom.parse(httpGet(url))
        if not lime.dom.select(doc, ".list-group") then error("未找到搜索结果列表") end
        local current = tonumber(selectText(doc, ".layui-laypage-curr em:last-child"))
        if current and current < page then return { records = {} } end
        records = parseSearchResources(doc, url)
    else
        local category = CATEGORIES[1].field
        for _, option in ipairs(CATEGORIES) do
            if option.field == tostring(filters.category) then
                category = option.field
                break
            end
        end
        local isRank = not tonumber(category)
        if not isRank then
            url = origin .. "/all/id/" .. category .. "/order/hits+desc.html?page=" .. page
        else
            if page > 1 then return { records = {} } end
            url = origin .. "/other/rank_hits/order/" .. category .. ".html"
        end
        doc = lime.dom.parse(httpGet(url, isRank))
        if not lime.dom.select(doc, ".rec_rullist") then error("未找到排行列表") end
        local current = tonumber(selectText(doc, ".pagination li.active span"))
        if current and current < page then return { records = {} } end
        records = parseRankResources(doc, url)
    end
    -- 资源身份不随所选镜像变化。
    for _, record in ipairs(records) do record.id = SITES[1] .. resourcePath(record.url) end
    return { records = records }
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
    error("无效的线路设置")
end

local function test(request)
    confirmSite(siteOrigin()) -- 认证需在检测项的 pcall 外触发。
    local results, records, info, catalog = {}, nil, nil, nil
    local function run(entry, fn)
        local started = lime.time.unix_ms()
        local ok, value = pcall(fn)
        results[#results + 1] = { entry = entry, status = ok and "passed" or "failed", message = ok and "可用" or tostring(value), durationMs = lime.time.unix_ms() - started }
        return ok and value or nil
    end
    records = run("search", function() local value = search({ keyword = "地铁", filters = {}, page = 1 }).records; if #value == 0 then error("搜索无结果") end; return value end)
    if records then info = run("resourceInfo", function() return resourceInfo({ resource = records[1] }) end) else results[#results + 1] = { entry = "resourceInfo", status = "blocked", message = "search 失败" } end
    if info then catalog = run("chapterList", function() return chapterList({ resource = info }) end) else results[#results + 1] = { entry = "chapterList", status = "blocked", message = "resourceInfo 失败" } end
    if catalog and catalog.chapters and catalog.chapters[1] then run("chapterContent", function() return chapterContent({ resource = { url = info.url }, chapter = catalog.chapters[1] }) end) else results[#results + 1] = { entry = "chapterContent", status = "blocked", message = "chapterList 失败" } end
    run("explore", explore)
    return results
end

return {
    protocol = "lime-plugin", kind = "resource", apiVersion = 1,
    manifest = { name = "爱丽丝书屋", package = "com.meinil.lime.ai.alicesw", version = "0.0.5", author = "ai", description = "国内发布页：https://www.asw2.cc/", homepage = SITES[1] },
    requires = { "browser", "crypto", "dom", "http", "log", "storage", "time" },

    capabilities = { resource = {
        content = "novel",
        search = search, resourceInfo = resourceInfo,
        chapterList = chapterList, chapterContent = chapterContent,
        explore = explore,
    } },
    hooks = { test = test, settings = { list = settings, action = saveSite } },
}
