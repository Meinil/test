local BASE = "https://jable.tv"
local UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
local HEADERS = {
    ["User-Agent"] = UA,
    ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
    ["Accept-Language"] = "zh-TW,zh;q=0.9,en;q=0.8",
    ["Referer"] = BASE .. "/",
}
local PENDING_BROWSER_KEY = "jable:pending"
local TZ_OFFSET = 8 * 60 * 60

local AJAX_BLOCKS = {
    latest = "list_videos_latest_videos_list",
    search = "list_videos_videos_list_search_result",
    category = "list_videos_common_videos_list",
}
local SORT_OPTIONS = {
    { field = "post_date_and_popularity", label = "近期最佳" },
    { field = "post_date", label = "最近更新" },
    { field = "video_viewed", label = "最多观看" },
    { field = "most_favourited", label = "最高收藏" },
}

local function trim(s)
    return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function urlEncode(s)
    local encoded = lime.crypto.urlEncode(tostring(s or ""))
    return encoded or ""
end

local function htmlDecode(s)
    return tostring(s or "")
        :gsub("&#x([%da-fA-F]+);", function(h) return utf8.char(tonumber(h, 16)) end)
        :gsub("&#(%d+);", function(d) return utf8.char(tonumber(d, 10)) end)
        :gsub("&nbsp;", " ")
        :gsub("&amp;", "&")
        :gsub("&quot;", '"')
        :gsub("&#39;", "'")
        :gsub("&lt;", "<")
        :gsub("&gt;", ">")
end

local function cleanText(s)
    local t = tostring(s or "")
        :gsub("<script.-</script>", " ")
        :gsub("<style.-</style>", " ")
        :gsub("<[^>]+>", " ")
        :gsub("%s+", " ")
    return trim(htmlDecode(t))
end

-- 提取页面标题，并移除 Jable 追加的站点宣传文案。
local function pageTitle(doc)
    local titleEl = lime.dom.select(doc, "title")
    if not titleEl then return "" end
    return trim(cleanText(lime.dom.text(titleEl)):gsub("%s*[-–|]%s*Jable%.TV.*$", ""))
end

local function absoluteUrl(s)
    local url = trim(s)
    if url == "" then return "" end
    if url:match("^https?://") then return url end
    if url:match("^//") then return "https:" .. url end
    if url:sub(1, 1) == "/" then return BASE .. url end
    return BASE .. "/" .. url
end

-- 排序值只接受站点分类列表公开的四种参数。
local function normalizeSort(value)
    local candidate = trim(tostring(value or "post_date"))
    for _, option in ipairs(SORT_OPTIONS) do
        if option.field == candidate then return candidate end
    end
    return "post_date"
end

local function requiresBrowserAuth(response)
    local status = tonumber(response and response.status) or 0
    if status ~= 403 and status ~= 503 then return false end
    local body = tostring(response and response.body or ""):lower()
    return body:find("cf%-challenge") ~= nil
        or body:find("cf%-chl%-") ~= nil
        or body:find("cloudflare", 1, true) ~= nil
        or body:find("just a moment", 1, true) ~= nil
end

local function browserChallengeOptions(url)
    return {
        profile = "default",
        url = url,
        reason = "challenge",
        scopes = {
            { scheme = "https", host = "jable.tv", includeSubdomains = true },
        },
        completion = {
            mode = "any",
            cookieNames = { "cf_clearance" },
        },
        request = {
            method = "GET",
            url = url,
            headers = {
                ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
            },
        },
    }
end

local function openBrowserChallenge(url)
    return lime.browser.open(browserChallengeOptions(url))
end

local function getPage(url)
    if trim(lime.storage.get(PENDING_BROWSER_KEY)) == url then
        local replay = openBrowserChallenge(url)
        lime.storage.remove(PENDING_BROWSER_KEY)
        if replay.status < 200 or replay.status >= 300 then
            error({ code = 2006, message = "Jable 浏览器请求失败: HTTP " .. tostring(replay.status) })
        end
        return replay.body
    end

    local response = lime.http.get(url, HEADERS)
    if requiresBrowserAuth(response) then
        lime.storage.set(PENDING_BROWSER_KEY, url)
        response = openBrowserChallenge(url)
        lime.storage.remove(PENDING_BROWSER_KEY)
    end
    if response.status < 200 or response.status >= 300 then
        error({ code = 2006, message = "Jable 请求失败: HTTP " .. tostring(response.status) })
    end
    return response.body
end

local function listPageUrl(baseUrl, blockId, page, keyword, sortBy)
    local n = tonumber(page) or 1
    local selectedSort = normalizeSort(sortBy)
    if n <= 1 and (blockId == AJAX_BLOCKS.search or selectedSort == "post_date") then
        return baseUrl
    end

    local params = {
        mode = "async",
        ["function"] = "get_block",
        block_id = blockId,
    }
    if blockId == AJAX_BLOCKS.search then
        params.sort_by = ""
        if keyword and keyword ~= "" then
            params.q = keyword
        end
    else
        params.sort_by = selectedSort
    end
    params.from = string.format("%02d", n)
    params._ = tostring(lime.time.unix_ms())

    local parts = {}
    for k, v in pairs(params) do
        parts[#parts + 1] = tostring(k) .. "=" .. urlEncode(tostring(v))
    end
    return baseUrl .. "?" .. table.concat(parts, "&")
end

local function fromPage(page)
    return math.max(1, math.floor(tonumber(page) or 1))
end

local function parseVideoList(html)
    local doc = lime.dom.parse(html)
    local resources = {}
    local boxes = lime.dom.selectAll(doc, ".video-img-box")

    for _, box in ipairs(boxes) do
        local linkEl = lime.dom.select(box, ".detail h6.title a")
        if not linkEl then
            linkEl = lime.dom.select(box, "h6.title a")
        end
        if not linkEl then
            linkEl = lime.dom.select(box, "a")
        end

        if linkEl then
            local href = lime.dom.attr(linkEl, "href")
            local title = cleanText(lime.dom.text(linkEl))
            if href and title ~= "" then
                local imgEl = lime.dom.select(box, "img")
                local cover = nil
                if imgEl then
                    local src = lime.dom.attr(imgEl, "data-src") or lime.dom.attr(imgEl, "src") or ""
                    if src ~= "" then
                        cover = { url = absoluteUrl(src), headers = HEADERS }
                    end
                end
                resources[#resources + 1] = {
                    name = title,
                    author = "",
                    url = absoluteUrl(href),
                    cover = cover,
                    chapterCount = 1,
                    latestChapter = title,
                }
            end
        end
    end
    return resources
end

local function searchKeyword(keyword, page)
    local n = fromPage(page)
    local encoded = urlEncode(keyword)
    local baseUrl = BASE .. "/search/" .. encoded .. "/"
    local url = listPageUrl(baseUrl, AJAX_BLOCKS.search, n, keyword)
    local html = getPage(url)
    return parseVideoList(html), html
end

-- 解析详情页的演员、上市日期、观看次数和喜欢数。
local function parseDetailFields(doc, html)
    local actresses = {}
    local actressSet = {}
    local function addActress(value)
        local name = trim(htmlDecode(value))
        if name ~= "" and not actressSet[name] then
            actressSet[name] = true
            actresses[#actresses + 1] = name
        end
    end

    -- 原始 HTML 中的演员链接顺序就是页面展示顺序，不依赖 `.models` 的解析层级。
    for modelHtml in tostring(html or ""):gmatch("<a[^>]->.-</a>") do
        if modelHtml:find("/models/", 1, true) then
            local name = modelHtml:match('data%-original%-title%s*=%s*"([^"]+)"')
                or modelHtml:match("data%-original%-title%s*=%s*'([^']+)'")
            addActress(name or "")
        end
    end

    if #actresses == 0 then
        local modelNodes = lime.dom.selectAll(doc, "[data-original-title]")
        for _, node in ipairs(modelNodes) do
            addActress(lime.dom.attr(node, "data-original-title") or "")
        end
    end

    local latestUpdateTime = nil
    local releaseEl = lime.dom.select(doc, ".info-header .header-right span.inactive-color")
    local releaseDate = releaseEl and cleanText(lime.dom.text(releaseEl)):match("(%d%d%d%d%-%d%d%-%d%d)")
    if releaseDate then
        local timestamp, parseError = lime.time.parse_offset("YYYY-MM-dd", releaseDate, TZ_OFFSET)
        if not parseError then latestUpdateTime = timestamp end
    end

    local meta = {}
    local infoSpans = lime.dom.selectAll(doc, ".info-header .header-left h6 > span.mr-3")
    local views = infoSpans[2] and cleanText(lime.dom.text(infoSpans[2])) or ""
    if views ~= "" then
        meta[#meta + 1] = { label = "看过", field = views }
    end

    local likesEl = lime.dom.select(doc, "button.fav span.count")
    local likes = likesEl and cleanText(lime.dom.text(likesEl)) or ""
    if likes ~= "" then
        meta[#meta + 1] = { label = "喜欢", field = likes }
    end

    return table.concat(actresses, "/"), latestUpdateTime, #meta > 0 and meta or nil
end

local function resourceInfo(url)
    local html = getPage(url)
    local doc = lime.dom.parse(html)

    local title = pageTitle(doc)

    local cover = nil
    local ogImage = lime.dom.select(doc, 'meta[property="og:image"]')
    if ogImage then
        local src = lime.dom.attr(ogImage, "content") or ""
        if src ~= "" then
            cover = { url = absoluteUrl(src), headers = HEADERS }
        end
    end

    local author, latestUpdateTime, meta = parseDetailFields(doc, html)

    local tags = {}
    local tagsContainer = lime.dom.selectAll(doc, "h5.tags a")
    for _, a in ipairs(tagsContainer) do
        local text = cleanText(lime.dom.text(a))
        if text ~= "" then
            tags[#tags + 1] = text
        end
    end

    return {
        name = title,
        author = author,
        url = url,
        cover = cover,
        tags = tags,
        meta = meta,
        wordCount = 0,
        chapterCount = 1,
        latestChapter = title,
        latestUpdateTime = latestUpdateTime,
    }
end

local function chapterList(resourceUrl, options)
    local html = getPage(resourceUrl)
    local doc = lime.dom.parse(html)

    local title = pageTitle(doc)

    return {
        chapters = {
            {
                id = "video-main",
                name = title ~= "" and title or "播放",
                url = resourceUrl,
                index = 0,
            },
        },
    }
end

local function extractM3u8Url(html)
    local scriptPattern = "hlsUrl%s*=%s*'(.-)'"
    local _, _, hlsUrl = html:find(scriptPattern)
    if hlsUrl then
        hlsUrl = trim(hlsUrl):gsub("\\/", "/")
        if hlsUrl ~= "" then return hlsUrl end
    end

    local scriptPattern2 = 'hlsUrl%s*=%s*"(.-)"'
    _, _, hlsUrl = html:find(scriptPattern2)
    if hlsUrl then
        hlsUrl = trim(hlsUrl):gsub("\\/", "/")
        if hlsUrl ~= "" then return hlsUrl end
    end

    return nil
end

local function chapterContent(request)
    if not request or not request.chapter then error("chapterContent: missing request.chapter") end

    local url = request.chapter.url
    if not url or url == "" then error("播放地址为空") end

    local html = getPage(url)
    local m3u8Url = extractM3u8Url(html)
    if not m3u8Url then error({ code = 2007, message = "Jable 未找到可播放的视频源" }) end

    return {
        blocks = {
            {
                id = "video-main",
                type = "video",
                title = request.chapter.name,
                sources = {
                    {
                        id = "jable-hls",
                        format = "hls",
                        mimeType = "application/vnd.apple.mpegurl",
                        url = m3u8Url,
                        headers = {
                            ["User-Agent"] = UA,
                            ["Referer"] = BASE .. "/",
                        },
                    },
                },
            },
        },
    }
end

local function exploreSchema()
    local html = getPage(BASE .. "/categories/")
    local doc = lime.dom.parse(html)
    local options = {}

    local boxes = lime.dom.selectAll(doc, ".video-img-box.mb-e-20")
    for _, box in ipairs(boxes) do
        local linkEl = lime.dom.select(box, ".img-box a") or lime.dom.select(box, "a")
        if linkEl then
            local href = lime.dom.attr(linkEl, "href") or ""
            local labelEl = lime.dom.select(box, ".absolute-center h4")
            local label = labelEl and cleanText(lime.dom.text(labelEl)) or ""
            local slug = href:match("/categories/([^/]+)")
            if slug and label ~= "" then
                options[#options + 1] = { field = slug, label = label }
            end
        end
    end

    return {
        supportsPagination = true,
        filters = {
            {
                field = "category",
                label = "分类",
                type = "single",
                default = "",
                options = options,
            },
            {
                field = "sortBy",
                label = "排序",
                type = "single",
                default = "post_date",
                options = SORT_OPTIONS,
            },
        },
    }
end

local function search(query)
    query = query or {}
    local keyword = trim(query.keyword or "")
    return { records = searchKeyword(keyword, query.page) }
end

local function browse(query)
    query = query or {}
    local filters = query.filters or {}
    local categorySlug = trim(tostring(filters.category or ""))
    local selectedSort = normalizeSort(filters.sortBy)
    local current = fromPage(query.page)

    local baseUrl
    local blockId

    if categorySlug == "" then
        baseUrl = BASE .. "/latest-updates/"
        blockId = AJAX_BLOCKS.latest
    else
        baseUrl = BASE .. "/categories/" .. categorySlug .. "/"
        blockId = AJAX_BLOCKS.category
    end

    local url = listPageUrl(baseUrl, blockId, current, nil, selectedSort)
    local html = getPage(url)
    local records = parseVideoList(html)
    return { records = records }
end

local function test(request)
    local results, records, info, catalog = {}, nil, nil, nil
    local function run(entry, fn)
        local value = fn()
        results[#results + 1] = { entry = entry, status = "passed", message = "可用" }
        return value
    end
    records = run("search", function() local value = search({ keyword = "乙愛麗絲", page = 1 }).records; if #value == 0 then error("搜索无结果") end; return value end)
    info = run("resourceInfo", function() return resourceInfo(records[1].url) end)
    catalog = run("chapterList", function() return chapterList(info.url) end)
    if not catalog.chapters or not catalog.chapters[1] then error("目录没有可检测的章节") end
    run("chapterContent", function() return chapterContent({ resource = { url = info.url }, chapter = catalog.chapters[1] }) end)
    run("explore", exploreSchema)
    return results
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

return {
    kind = "resource",
    apiVersion = 1,
    manifest = {
        name = "Jable TV",
        package = "com.meinil.lime.video.jable",
        version = "0.0.2",
        author = "ai",
        description = "Jable.TV | 免費高清AV在線看 | J片 AV看到飽",
        homepage = "https://jable.tv",
        logo = "https://jable.tv/favicon.ico",
    },
    requires = { "browser", "crypto", "dom", "http", "storage", "time" },

    capabilities = {
        content = "video",
        search = searchResources,
        resourceInfo = describeResource,
        chapterList = listResourceChapters,
        chapterContent = chapterContent,
        explore = browseResources,
        exploreSchema = exploreSchema,
    },
    hooks = {
        test = test,
    },
}
