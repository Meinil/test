local SITES = {
    "https://www.alicesw.com",
    "https://www.alicesw5.homes",
    "https://www.alicesw6.homes",
    "https://www.alicesw7.homes",
}
local SITE_KEY = "site_origin"
local TZ_OFFSET = 8 * 60 * 60
-- 空 User-Agent 会被上游返回 HTTP 500；已有 WebView Profile 的 UA 仍由宿主优先使用。
local HTTP_HEADERS = { ["User-Agent"] = "Lime" }

local function siteOrigin()
    local saved = lime.storage.get(SITE_KEY)
    for _, site in ipairs(SITES) do
        if site == saved then return site end
    end
    return SITES[1]
end

local RANKS = {
    { field = "hits", label = "总排行" },
    { field = "hits_month", label = "月排行" },
    { field = "hits_week", label = "周排行" },
    { field = "hits_day", label = "日排行" },
}
local CATEGORIES = {
    { field = "71", label = "科幻" }, { field = "79", label = "经典" },
    { field = "75", label = "奇幻" }, { field = "69", label = "系统" },
    { field = "68", label = "武侠" }, { field = "65", label = "乱伦" },
    { field = "64", label = "都市" }, { field = "63", label = "乡村" },
    { field = "73", label = "同人" }, { field = "62", label = "玄幻" },
    { field = "61", label = "校园" }, { field = "70", label = "穿越" },
    { field = "22", label = "反差" }, { field = "46", label = "凌辱" },
    { field = "18", label = "堕落" }, { field = "19", label = "纯爱" },
    { field = "52", label = "伪娘" }, { field = "48", label = "萝莉" },
    { field = "56", label = "熟女" }, { field = "50", label = "正太" },
    { field = "72", label = "明星" }, { field = "54", label = "NTR" },
    { field = "53", label = "媚黑" }, { field = "58", label = "调教" },
    { field = "59", label = "言情" }, { field = "47", label = "百合" },
    { field = "82", label = "耽美" }, { field = "21", label = "重口" },
    { field = "57", label = "其他" },
}
local SECTIONS = {
    { field = "home", label = "首页", children = {{ field = "home", label = "首页" }} },
    { field = "shelf", label = "书架", children = {{ field = "shelf", label = "书架" }} },
    { field = "rank", label = "排行", children = RANKS },
    { field = "original", label = "原创", children = {{ field = "original", label = "原创" }} },
    { field = "category", label = "分类", children = CATEGORIES },
    { field = "latest", label = "最新", children = {{ field = "latest", label = "最新更新" }} },
}
local SORTS = {
    { field = "update_time", label = "按更新" },
    { field = "word", label = "按字数" },
    { field = "hits", label = "按人气" },
}

-- 只接受声明中存在的完整级联路径；不把用户输入直接拼接进 URL。
local function selection(filters)
    local path = filters.category
    if type(path) == "table" and #path == 2 then
        for _, section in ipairs(SECTIONS) do
            if section.field == path[1] then
                for _, child in ipairs(section.children) do
                    if child.field == path[2] then return section.field, child.field end
                end
            end
        end
    end
    return "home", "home"
end

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

-- 站点在浏览器中动态插入年龄弹框，普通 HTTP 响应里只有 iframe 的初始化脚本。
local function hasAgeGate(html)
    local doc = lime.dom.parse(html)
    if lime.dom.select(doc, "iframe#age-gate-iframe[src='/jump/age_gate.html']") then return true end
    for _, script in ipairs(lime.dom.selectAll(doc, "script:not([src])")) do
        local source = lime.dom.html(script)
        if source:find([=[ageGateSrc%s*=%s*['"]/jump/age_gate%.html['"]]=])
            and source:find([=[iframe%.id%s*=%s*['"]age%-gate%-iframe['"]]=]) then
            return true
        end
    end
    return false
end

-- 只在检测到站点弹框后交给宿主；已完成的同源 Profile 不会重新开窗。
-- 不执行站点脚本、不写入年龄确认值，必须由用户在站点页面操作。
local function confirmSite(origin)
    local host = origin:sub(9)
    lime.browser.open({
        profile = "consent-" .. host:gsub("%.", "-"), url = origin .. "/", reason = "consent",
        scopes = {{ scheme = "https", host = host, includeSubdomains = false }},
        captures = {{ origin = origin .. "/", keys = { "ageVerified" } }},
        completion = { localStorageValues = { ageVerified = "true" } },
    })
end

local function checkedBody(response)
    if response.status < 200 or response.status >= 300 then
        error({ code = 2006, message = "lime.http.get: HTTP " .. tostring(response.status) })
    end
    if hasAgeGate(response.body) then confirmSite(siteOrigin()) end
    return response.body
end

local function httpGet(url, retryRank)
    local response = lime.http.get(url, HTTP_HEADERS)
    -- 排行页偶发 HTTP 500 时，只在当前线路重试一次。
    if retryRank and response.status == 500 then
        response = lime.http.get(url, HTTP_HEADERS)
        if response.status == 500 then
            error({ code = 2006, message = "排行榜返回 HTTP 500，请稍后重试，或在插件设置中手动切换线路" })
        end
    end
    return checkedBody(response)
end

local function parseCount(value)
    local s = tostring(value or ""):gsub(",", "")
    local n = tonumber(s:match("([0-9]+%.?[0-9]*)"))
    if not n then return 0 end
    if s:find("万", 1, true) then return math.floor(n * 10000 + 0.5) end
    return math.floor(n)
end

local function parseTime(value, fmt)
    local s = trim(value)
    if s == "" then return 0 end
    if not fmt then
        s = s:match("%d%d%d%d%-%d%d%-%d%d%s+%d%d:%d%d") or ""
        fmt = "YYYY-MM-dd HH:mm"
    end
    return lime.time.parse_offset(fmt, s, TZ_OFFSET) or 0
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
        hits = parseCount(selectText(doc, "li.diyhot")),
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

-- Android WebView 的 UA 会让同一网址返回移动版，而不是桌面排行表。
local function parseMobileResources(doc, baseUrl)
    local records = {}
    for _, item in ipairs(lime.dom.selectAll(doc, ".txt-list-row3 > li")) do
        local row = subdoc(item)
        local link = lime.dom.select(row, ".s2 > a[href*='/novel/']")
        local kindLabel = selectText(row, ".s2 > a > .fenleibt")
        local kind = trim((kindLabel:gsub("^%[(.-)%]$", "%1")))
        local name = text(link)
        if name:sub(1, #kindLabel) == kindLabel then name = trim(name:sub(#kindLabel + 1)) end
        if name ~= "" then
            records[#records + 1] = {
                name = name, url = absolutize(attr(link, "href"), baseUrl),
                author = selectText(row, ".s5"), kind = kind,
                tags = kind ~= "" and { kind } or {},
                wordCount = parseCount(selectText(row, ".five")),
                hits = parseCount(selectText(row, ".diyhot")),
                latestUpdateTime = parseTime(selectText(row, ".six")),
            }
        end
    end
    return records
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
    if name == "" then name = selectText(doc, ".detail-box .info h1") end
    if name == "" then name = selectText(doc, ".box_info > .novel_title") end
    if name == "" then name = selectAttr(doc, "meta[property='og:novel:book_name']", "content") or "" end
    local author = selectText(doc, "#detail-box .novel_info a[href*='f=author']")
    if author == "" then author = selectText(doc, "#detail-box .novel_info p:nth-child(2) a") end
    if author == "" then author = selectText(doc, ".detail-box .info a[href*='f=author']") end
    local cover = selectAttr(doc, "#detail-box img", "data-src") or selectAttr(doc, "#detail-box img", "src")
        or selectAttr(doc, ".detail-box .imgbox img", "src") or ""
    local intro = selectText(doc, ".jianjie > p")
    if intro == "" then intro = selectText(doc, "#detail-box .book_intro") end
    local kind = selectText(doc, "#detail-box .novel_info a[href*='/lists/'], .detail-box .info a[href*='/lists/']")
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
    local selector = "ul.mulu_list"
    if not lime.dom.select(doc, selector) then selector = ".section-box > ul.section-list" end
    if not lime.dom.select(doc, selector) then error("未找到章节目录") end
    local links = lime.dom.selectAll(doc, selector .. " li a[href*='/book/']")
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
    local contentSelector = ".read-content, #chapterContent .jsChapterWrapper .content_txt"
    local contentEl = lime.dom.select(doc, contentSelector)
    local paragraphs = contentEl and lime.dom.selectAll(subdoc(contentEl), "p") or {}
    local chunks = {}
    for _, p in ipairs(paragraphs or {}) do
        local value = text(p)
        if value ~= "" then chunks[#chunks + 1] = value end
    end
    if #chunks == 0 then
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

-- 首页更新榜只显示月日和时分，按站点时区补上最近一次出现的年份。
local function parseHomeTime(value, now)
    if not value:match("^%d%d%-%d%d %d%d:%d%d$") then
        local timestamp = parseTime(value)
        return timestamp > 0 and timestamp or nil
    end
    local year = 1970 + math.floor((now + TZ_OFFSET) / 31557600)
    local function timestamp(y, date)
        return lime.time.parse_offset("YYYY-MM-dd HH:mm", y .. "-" .. date, TZ_OFFSET)
    end
    -- 用实际元旦校正平均年长度在跨年时的偏差。
    if timestamp(year, "01-01 00:00") > now then
        year = year - 1
    elseif timestamp(year + 1, "01-01 00:00") <= now then
        year = year + 1
    end
    local updated = timestamp(year, value)
    if updated and updated > now then updated = timestamp(year - 1, value) end
    return updated
end

-- 首页按书籍卡片/行提取；重复书目用后续板块补齐缺失字段，但保留首次出现的位置。
local function parseHome(doc, url)
    local records, byPath = {}, {}
    local selector = ".class-img, .hot-img, .class-box li, .item-list li, .item-index li"
        .. ", .layout .title_author, .layout .listx .topred"
    local now = lime.time.unix()
    for _, row in ipairs(lime.dom.selectAll(doc, selector)) do
        local link = lime.dom.select(row, "h5 a, a.ellipsis, a.book-list-f, a.ititle, a.titles")
            or lime.dom.select(row, "a[href*='/novel/']:not(.jianjie)")
        local path = resourcePath(attr(link, "href") or "")
        local name = text(link)
        if path:match("^/novel/%d+%.html$") and name ~= "" then
            local record = byPath[path]
            if not record then
                record = { name = name, url = absolutize(path, url) }
                records[#records + 1], byPath[path] = record, record
            end
            if not record.author then
                local author = selectText(row, ".author, .s5")
                if author == "" then
                    -- 桌面推荐卡片把作者直接写在标题与简介之间，没有单独的元素。
                    local label = lime.dom.html(row):match("</h5>%s*([^<]+)")
                    if label and (label:match("^作者：") or label:match("^作者:")) then
                        author = selectText(lime.dom.parse("<span>" .. label .. "</span>"), "span")
                    end
                end
                author = trim((author:gsub("^作者：", ""):gsub("^作者:", "")))
                author = trim((author:gsub("^/", ""):gsub("^／", "")))
                if author ~= "" then record.author = author end
            end
            if not record.latestChapter then
                local chapter = lime.dom.select(row, "a.zjie")
                local title = text(chapter)
                if title ~= "" then
                    record.latestChapter = title
                    local href = attr(chapter, "href")
                    if href and href ~= "" then record.latestChapterUrl = absolutize(href, url) end
                end
            end
            if not record.latestUpdateTime then
                local date = selectText(row, ".time")
                if date ~= "" then record.latestUpdateTime = parseHomeTime(date, now) end
            end
        end
    end
    return records
end

-- 原创、书架和排行榜没有全站排序接口；对站点返回的当前列表稳定排序。
local function sortRecords(records, order)
    local field = ({ update_time = "latestUpdateTime", word = "wordCount", hits = "hits" })[order]
    local index = {}
    for i, record in ipairs(records) do index[record] = i end
    table.sort(records, function(a, b)
        local left, right = a[field] or 0, b[field] or 0
        if left ~= right then return left > right end
        return index[a] < index[b]
    end)
end

local function listRecords(doc, page, url)
    local desktop = lime.dom.select(doc, ".rec_rullist")
    if not desktop and not lime.dom.select(doc, ".txt-list-row3") then return nil end
    local current = tonumber(selectText(doc, ".pagination li.active span, .pages_bottom .pager li.active span"))
    if current and current < page then return {} end
    return desktop and parseRankResources(doc, url) or parseMobileResources(doc, url)
end

local function needsShelfLogin(response)
    if response.status == 401 or response.status == 403 then return true end
    return response.status == 200
        and lime.dom.select(lime.dom.parse(response.body), "form input[name='password']") ~= nil
end

-- 先探测真实书架；只在未登录时打开受控 WebView，在同源环境重试书架请求。
local function shelf(origin, url, page)
    local response = lime.http.get(url, HTTP_HEADERS)
    if needsShelfLogin(response) then
        local host = origin:sub(9)
        response = lime.browser.open({
            profile = "bookshelf-" .. host:gsub("%.", "-"),
            url = origin .. "/user/user/login.html", reason = "login",
            scopes = {{ scheme = "https", host = host, includeSubdomains = false }},
            completion = { urlPatterns = { "/user/(?:index|bookshelf)/" } },
            request = { method = "GET", url = url },
        })
        if needsShelfLogin(response) then error("尚未登录爱丽丝书屋，无法查看书架") end
    end
    local doc = lime.dom.parse(checkedBody(response))
    local records = listRecords(doc, page, url)
    if records then return records end
    -- 书架也可能用用户中心的表格/卡片模板；每本书只保留一个标题。
    local current = tonumber(selectText(doc, ".pagination li.active span, .pages_bottom .pager li.active span"))
    if current and current < page then return {} end
    local seen = {}
    records = {}
    local function add(link, row, container)
        local path = resourcePath(attr(link, "href") or "")
        local name = text(link)
        if not path:match("^/novel/%d+%.html$") or name == "" or seen[path] then return end
        seen[path] = true
        records[#records + 1] = {
            name = name, url = absolutize(path, url),
            latestUpdateTime = row and parseTime(attr(row, "data-update-time") or selectText(container, ".update-time, .six")) or nil,
            wordCount = row and parseCount(attr(row, "data-words") or selectText(container, ".word-count, .five")) or nil,
            hits = row and parseCount(attr(row, "data-hits") or selectText(container, ".hits, .diyhot")) or nil,
        }
    end
    for _, row in ipairs(lime.dom.selectAll(doc, "tr, .bookshelf-item")) do
        -- 单独解析 tr 会让 HTML 解析器丢弃 td，补上表格上下文。
        local container = lime.dom.tag(row) == "tr"
            and lime.dom.parse("<table>" .. lime.dom.html(row) .. "</table>") or row
        add(lime.dom.select(container, "a[href*='/novel/']"), row, container)
    end
    for _, link in ipairs(lime.dom.selectAll(doc, "a[href*='/novel/']")) do add(link) end
    return records
end

local function explore(query)
    local sections = { field = "category", label = "分类", type = "cascade",
        default = { "home", "home" }, options = SECTIONS, reloadOnChange = true }
    if selection(query and query.filters or {}) == "home" then return { sections } end
    return { sections, { field = "sort", label = "排序", type = "single", default = "update_time", options = SORTS } }
end

local function search(query)
    local keyword = trim(query.keyword)
    local filters = query.filters or {}
    local page = query.page or 1
    local origin = siteOrigin()
    local url, records
    if keyword ~= "" then
        local encoded = lime.crypto.urlEncode(keyword)
        if not encoded then error("搜索词编码失败") end
        url = origin .. "/search.html?q=" .. encoded .. "&f=_all&p=" .. page
        local doc = lime.dom.parse(httpGet(url))
        if not lime.dom.select(doc, ".list-group") then error("未找到搜索结果列表") end
        local current = tonumber(selectText(doc, ".layui-laypage-curr em:last-child"))
        if current and current < page then return { records = {} } end
        records = parseSearchResources(doc, url)
    else
        local section, child = selection(filters)
        local order = "update_time"
        for _, option in ipairs(SORTS) do
            if filters.sort == option.field then order = option.field break end
        end
        local suffix = page > 1 and "?page=" .. page or ""
        if section == "home" then
            if page > 1 then return { records = {} } end
            url = origin .. "/"
            records = parseHome(lime.dom.parse(httpGet(url)), url)
            if #records == 0 then error("未找到首页书籍") end
        elseif section == "shelf" then
            records = shelf(origin, origin .. "/user/bookshelf/index.html" .. suffix, page)
            sortRecords(records, order)
        else
            local isRank = section == "rank"
            if isRank then
                if page > 1 then return { records = {} } end
                url = origin .. "/other/rank_hits/order/" .. child .. ".html"
            elseif section == "original" then
                url = origin .. "/original.html" .. suffix
            else
                local group = section == "category" and "/id/" .. child or ""
                url = origin .. "/all" .. group .. "/order/" .. order .. "+desc.html" .. suffix
            end
            records = listRecords(lime.dom.parse(httpGet(url, isRank)), page, url)
            if not records then error("未找到发现列表") end
            if isRank or section == "original" then sortRecords(records, order) end
        end
    end
    -- 资源身份不随所选镜像变化；内部排序字段不透出。
    for _, record in ipairs(records) do
        record.id = SITES[1] .. resourcePath(record.url)
        record.hits = nil
    end
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
    local results, records, info, catalog = {}, nil, nil, nil
    local function run(entry, fn)
        local started = lime.time.unix_ms()
        local value = fn()
        results[#results + 1] = { entry = entry, status = "passed", message = "可用", durationMs = lime.time.unix_ms() - started }
        return value
    end
    records = run("search", function() local value = search({ keyword = "地铁", filters = {}, page = 1 }).records; if #value == 0 then error("搜索无结果") end; return value end)
    info = run("resourceInfo", function() return resourceInfo({ resource = records[1] }) end)
    catalog = run("chapterList", function() return chapterList({ resource = info }) end)
    if not catalog.chapters or not catalog.chapters[1] then error("目录没有可检测的章节") end
    run("chapterContent", function() return chapterContent({ resource = { url = info.url }, chapter = catalog.chapters[1] }) end)
    run("explore", function()
        if #search({ page = 1 }).records == 0 then error("发现首页无结果") end
        if #search({ page = 1, filters = { category = { "category", "71" } } }).records == 0 then error("发现科幻分类无结果") end
    end)
    return results
end

return {
    kind = "resource", apiVersion = 1,
    manifest = { name = "爱丽丝书屋", package = "com.meinil.lime.ai.alicesw", version = "0.0.9", author = "ai", description = "国内发布页：https://www.asw2.cc/", homepage = SITES[1] },
    requires = { "browser", "crypto", "dom", "http", "log", "storage", "time" },

    capabilities = {
        content = "novel",
        search = search, resourceInfo = resourceInfo,
        chapterList = chapterList, chapterContent = chapterContent,
        explore = explore,
    },
    hooks = { test = test, settings = { list = settings, action = saveSite } },
}
