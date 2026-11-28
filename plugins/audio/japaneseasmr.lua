local BASE = "https://japaneseasmr.com"
local UA = "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36"
local DEFAULT_HEADERS = {
    ["User-Agent"] = UA,
    ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    ["Accept-Language"] = "ja,en;q=0.9,zh;q=0.8",
}
local PENDING_BROWSER_KEY = "japaneseasmr:pending"

-- ============================================================
-- 工具(全部 local,且定义顺序在调用方之前)
-- ============================================================

local function trim(value) return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "") end

local function coverSource(url)
    if not url or trim(url) == "" then return nil end
    return {
        url = url,
        headers = { ["Referer"] = BASE .. "/", ["User-Agent"] = UA },
    }
end

local function urlEncode(s)
    if s == nil then return "" end
    return (tostring(s):gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- Cloudflare Managed Challenge 不能由普通 HTTP 客户端执行，交给宿主认证 WebView。
local function requiresBrowserAuth(response)
    local status = tonumber(response and response.status) or 0
    if status ~= 401 and status ~= 403 and status ~= 503 then return false end
    local html = tostring(response and response.body or ""):lower()
    return html:find("cf%-challenge") ~= nil
        or html:find("cf%-chl%-") ~= nil
        or html:find("cloudflare", 1, true) ~= nil
        or html:find("just a moment", 1, true) ~= nil
end

local function browserChallengeOptions(url)
    return {
        profile = "default",
        url = url,
        reason = "challenge",
        scopes = {
            { scheme = "https", host = "japaneseasmr.com", includeSubdomains = true },
        },
        completion = {
            mode = "any",
            cookieNames = { "cf_clearance" },
        },
        request = {
            method = "GET",
            url = url,
            headers = {
                ["Accept"] = DEFAULT_HEADERS["Accept"],
                ["Accept-Language"] = DEFAULT_HEADERS["Accept-Language"],
            },
        },
    }
end

local function openBrowserChallenge(url)
    return lime.browser.open(browserChallengeOptions(url))
end

local function httpGet(path)
    local headers = {}; for k, v in pairs(DEFAULT_HEADERS) do headers[k] = v end
    headers["Referer"] = BASE .. "/"
    -- 允许传入绝对 URL(详情页 <a href>);否则按相对路径拼 BASE
    local target = (tostring(path or ""):match("^https?://")) and path or (BASE .. path)

    if trim(lime.storage.get(PENDING_BROWSER_KEY)) == target then
        local replay = openBrowserChallenge(target)
        lime.storage.remove(PENDING_BROWSER_KEY)
        if not replay or replay.status < 200 or replay.status >= 300 then
            return nil, { code = 2006, message = "JapaneseASMR 浏览器请求失败：HTTP " .. tostring(replay and replay.status or 0) }
        end
        if not replay.body or replay.body == "" then return nil, { code = 2007, message = "JapaneseASMR 响应正文为空" } end
        return replay.body
    end

    local response = lime.http.get(target, headers)
    if requiresBrowserAuth(response) then
        lime.storage.set(PENDING_BROWSER_KEY, target)
        response = openBrowserChallenge(target)
        lime.storage.remove(PENDING_BROWSER_KEY)
    end
    if not response or response.status < 200 or response.status >= 300 then
        return nil, { code = 2006, message = "JapaneseASMR 请求失败：HTTP " .. tostring(response and response.status or 0) }
    end
    if not response.body or response.body == "" then return nil, { code = 2007, message = "JapaneseASMR 响应正文为空" } end
    return response.body
end

-- "12分07秒" / "11分19秒" 等日文时长字符串 → 秒
local function parseJapaneseDuration(s)
    if not s or s == "" then return 0 end
    local m = tostring(s):match("(%d+)分")
    local sec = tostring(s):match("(%d+)秒")
    return (tonumber(m) or 0) * 60 + (tonumber(sec) or 0)
end

-- shortcode `cv = '豊川ゆき'` / `gallery='5'` 抽值
local function extractShortcodeAttr(html, name)
    if not html then return nil end
    local v = html:match(name .. "%s*=%s*'([^']*)'")
    if not v then v = html:match(name .. "%s*=%s*\"([^\"]*)\"") end
    return v
end

-- 同一作品拆分出的章节共享一个稳定物理媒体身份，避免按 chapter/block 重复缓存整份 HLS。
local function productAssetId(productUrl)
    local url = tostring(productUrl or "")
    local productId = url:match("/(%d+)/") or url:match("/(%d+)$")
    return productId and ("japaneseasmr-product-" .. productId) or nil
end

-- 详情页声优节点可能包含一个或多个 CV；只移除标签前缀，保留网站给出的姓名顺序。
local function parseVoiceActors(doc)
    local node = lime.dom.select(doc, "#voice_actors")
    local value = node and trim(lime.dom.text(node)) or ""
    value = value:gsub("^CV%s*:%s*", "")
    value = trim(value:gsub("^CV%s*：%s*", ""))
    return value ~= "" and value or nil
end

-- "2026-07-11" ISO date → unix seconds(简化到当天的 12:00 UTC,Lime 端不要求精度)
-- os 标准库在沙箱中不可用,改用 lime.time.parse_offset 拼成 12:00 UTC。
local function parseIsoTime(s)
    if not s or s == "" then return nil end
    local ts, err = lime.time.parse_offset("YYYY-MM-dd", tostring(s), 0)
    if not ts then return nil, err end
    return ts + 12 * 3600
end

-- 详情页 `Last update: YYYY/MM/dd` → Unix 秒；缺失时不伪造当前时间。
local function parseLastUpdate(html)
    local value = tostring(html or ""):match("Last%s+update:%s*(%d%d%d%d/%d%d/%d%d)")
    if not value then return nil end
    local ts, err = lime.time.parse_offset("YYYY/MM/dd", value, 0)
    if not ts then return nil, err end
    return ts + 12 * 3600
end

-- 从 archive card 的 `p.entry-excerpt p` 里抓 "CV: 名字" 一行(避免 :contains CSS 限制)
local function selectCvParagraph(card)
    for _, p in ipairs(lime.dom.selectAll(card, "p.entry-excerpt p")) do
        local t = lime.dom.text(p) or ""
        local cv = t:match("CV:%s*(.+)")
        if cv and trim(cv) ~= "" then return trim(cv) end
    end
    return nil
end

-- 详情页底部 WordPress 标签区，保留网站展示顺序及双语/日文的独立标签。
local function parseProductTags(doc)
    local tags = {}
    for _, link in ipairs(lime.dom.selectAll(doc, "p.post-meta.post-tags a[rel='tag']")) do
        local label = trim(lime.dom.text(link))
        if label ~= "" then tags[#tags + 1] = label end
    end
    return tags
end

-- 仅取日文作品介绍的第一个图文块，避免命中隐藏英文区或后续声优介绍。
local function parseProductIntro(doc)
    local node = lime.dom.select(
        doc,
        "#jp-desc .work_parts_container > .work_parts.type_image:first-child .work_parts_multitype_item.type_text p"
    )
    local intro = node and trim(lime.dom.text(node)) or ""
    return intro ~= "" and intro or nil
end

-- 章节标题按索引优先取日文作品区的真实 tracklist，播放器通用标题仅作兜底。
local function parseTrackTitles(doc, count)
    local workTitles = {}
    for _, node in ipairs(lime.dom.selectAll(doc, "#jp-desc .work_tracklist .work_tracklist_item .title")) do
        workTitles[#workTitles + 1] = trim(lime.dom.text(node))
    end

    local playerTitles = {}
    for _, link in ipairs(lime.dom.selectAll(doc, "#plyr-chapter-playlist td.chapter_list.chapter_title a")) do
        playerTitles[#playerTitles + 1] = trim(lime.dom.attr(link, "data-track-title") or lime.dom.text(link))
    end

    local titles = {}
    for index = 1, count do
        local title = workTitles[index]
        if not title or title == "" then title = playerTitles[index] end
        titles[index] = (title and title ~= "") and title or ("トラック " .. index)
    end
    return titles
end

-- archive card 单条记录 → ResourceDetailVO
local function resourceOf(post, cv, baseHref)
    local titleEl = lime.dom.select(post, "h2.entry-title a")
    local title = titleEl and lime.dom.text(titleEl) or ""
    local url = (titleEl and lime.dom.attr(titleEl, "href")) or baseHref
    local imgEl = lime.dom.select(post, "img.lazy")
    local cover = imgEl and lime.dom.attr(imgEl, "data-src") or nil
    local timeEl = lime.dom.select(post, "time")
    local ts = timeEl and lime.dom.attr(timeEl, "datetime") or nil
    return {
        name = trim(title),
        author = trim(cv or ""),
        url = url,
        cover = coverSource(cover),
        latestUpdateTime = ts and parseIsoTime(ts) or nil,
        chapterCount = 1,  -- resourceInfo 时补全
        tags = { "japanese", "asmr" },
        wordCount = 0,
        intro = nil,
    }
end

-- 抽一份 product 页的音频块配置(URL + headers + Track list + titles)
-- 缓存同一次 HTTP 调用结果,因为 chapterList 与 chapterContent 都用同一页
local function fetchProductData(productUrl)
    local html, err = httpGet(productUrl)
    if not html then return nil, err end
    local doc = lime.dom.parse(html)

    -- #audioplayer audio src(跳过 video,用户要求"只取音频不取视频")
    local audioEl = lime.dom.select(doc, "#audioplayer audio")
        or lime.dom.select(doc, "audio")
    local sourceEl = audioEl and lime.dom.select(audioEl, "source") or nil
    local m3u8 = audioEl and (
        lime.dom.attr(audioEl, "src")
        or lime.dom.attr(audioEl, "data-src")
        or (sourceEl and lime.dom.attr(sourceEl, "src"))
        or (sourceEl and lime.dom.attr(sourceEl, "data-src"))
    ) or nil

    -- Track startMs 秒数(优先 #plyr-chapter-playtable 的 data-value 精确秒)
    local starts = { 0 }
    for _, td in ipairs(lime.dom.selectAll(doc, "#plyr-chapter-playlist td.chapter_list.start_time a")) do
        local sec = tonumber(lime.dom.attr(td, "data-value"))
        if sec and sec > 0 then starts[#starts + 1] = sec end
    end
    -- 兜底:.work_tracklist 累加 duration
    if #starts <= 1 then
        local cumulative = 0
        starts = { 0 }
        for _, li in ipairs(lime.dom.selectAll(doc, "#jp-desc .work_tracklist .work_tracklist_item")) do
            local timeEl = lime.dom.select(li, "div.time")
            local durText = (timeEl and lime.dom.text(timeEl)) or ""
            cumulative = cumulative + parseJapaneseDuration(durText)
            starts[#starts + 1] = cumulative
        end
        if #starts > 1 then table.remove(starts) end
    end

    local titles = parseTrackTitles(doc, #starts)

    -- 元信息 shortcode
    local cv = parseVoiceActors(doc)
        or extractShortcodeAttr(html, "cv")
        or extractShortcodeAttr(html, "cv ")
    local gallery = tonumber(extractShortcodeAttr(html, "gallery") or "0") or 0

    -- 详情页文本
    local titleNode = lime.dom.select(doc, "#work_title_jp")
    local rawTitle = (titleNode and lime.dom.text(titleNode)) or ""
    local title = trim(rawTitle
        :gsub("^%s*%[%s*[%w%-_]+%s*%]%s*", "")
        :gsub("%s*%[RJ[%w%-_]+%]%s*$", ""))
    local coverEl = lime.dom.select(doc, "#img_cover")
    local cover = coverEl and lime.dom.attr(coverEl, "href") or nil
    local intro = parseProductIntro(doc)
    local tags = parseProductTags(doc)
    local latestUpdateTime = parseLastUpdate(html)

    return {
        doc = doc,
        m3u8 = m3u8,
        starts = starts,
        titles = titles,
        title = title,
        cover = coverSource(cover),
        intro = intro,
        tags = tags,
        latestUpdateTime = latestUpdateTime,
        cv = cv,
        gallery = gallery,
    }, nil
end

-- ============================================================
-- search (站内搜索,跨插件批量)
-- ============================================================
local function searchKeyword(keyword, page)
    page = page or 1
    local html, err = httpGet("/?s=" .. urlEncode(keyword) .. "&paged=" .. page)
    if not html then error(err) end
    local doc = lime.dom.parse(html)
    local out = {}
    for _, card in ipairs(lime.dom.selectAll(doc, "li.site-archive-post")) do
        local cv = selectCvParagraph(card)
        out[#out + 1] = resourceOf(card, cv, BASE .. "/")
    end
    return out, html
end

-- ============================================================
-- explore / unified search
-- ============================================================
local function baseExploreFilters()
    return {
        {
            field = "keyword",
            label = "Keyword",
            type = "text",
            placeholder = "搜索关键词",
        },
        {
            field = "rating",
            label = "Rating",
            type = "single",
            options = {
                { field = "rating/sfw",     label = "SFW" },
                { field = "rating/r-15",    label = "R-15" },
                { field = "rating/maniax",  label = "NSFW" },
                { field = "rating/extreme", label = "Extreme" },
            },
        },
        {
            field = "sort",
            label = "Sort",
            type = "single",
            default = "recent",
            reloadOnChange = true,
            options = {
                { field = "recent",        label = "Recent" },
                { field = "popular_month", label = "Popular month" },
                { field = "popular_year",  label = "Popular year" },
                { field = "popular_all",   label = "Popular all time" },
                { field = "random",        label = "Random" },
            },
        },
    }
end

-- `/tags/` 用 accordion 标题与同索引内容面板表达分组关系。
local function parseTagGroups(doc)
    local headings = lime.dom.selectAll(doc, ".tag-groups-cloud.ui-accordion > h3")
    local panels = lime.dom.selectAll(doc, ".tag-groups-cloud.ui-accordion > div.ui-accordion-content")
    local groups = {}
    for index, heading in ipairs(headings) do
        local panel = panels[index]
        local children = {}
        if panel then
            for _, a in ipairs(lime.dom.selectAll(panel, "span.tag-groups-tag a")) do
                local href = lime.dom.attr(a, "href") or ""
                local slug = href:match("/tag/([^/]+)/")
                if slug and slug ~= "" then
                    local labelEl = lime.dom.select(a, "span.tag-groups-label")
                    children[#children + 1] = {
                        field = slug,
                        label = trim((labelEl and lime.dom.text(labelEl)) or slug),
                    }
                end
            end
        end
        if #children > 0 then
            groups[#groups + 1] = {
                field = "group-" .. index,
                label = trim(lime.dom.text(heading)),
                children = children,
            }
        end
    end
    return groups
end

local SORT_QUERY = {
    recent = "order=desc",
    popular_month = "orderby=post_views&order=desc&date=month",
    popular_year = "orderby=post_views&order=desc&date=year",
    popular_all = "orderby=post_views&order=desc",
    random = "orderby=rand",
}

local function appendQuery(path, query)
    return path .. (path:find("?", 1, true) and "&" or "?") .. query
end

-- 先确定内容范围，再统一叠加页码和排序参数。
local function buildExplorePath(keyword, filters, page)
    local path
    if keyword and keyword ~= "" then
        path = "/?s=" .. urlEncode(keyword) .. "&paged=" .. page
    elseif filters.rating and filters.rating ~= "" then
        path = "/category/" .. filters.rating .. "/"
        if page > 1 then path = path .. "page/" .. page .. "/" end
    elseif type(filters.tags) == "table" and #filters.tags > 0 then
        local slug = tostring(filters.tags[#filters.tags])
        path = "/tag/" .. slug .. "/"
        if page > 1 then path = path .. "page/" .. page .. "/" end
    else
        path = page > 1 and ("/page/" .. page .. "/") or "/"
    end
    return appendQuery(path, SORT_QUERY[filters.sort or "recent"] or SORT_QUERY.recent)
end

local function exploreSchema(query)
    local reqFilters = query and query.filters or {}
    local sort = reqFilters.sort or "recent"
    local paginationMode = sort ~= "random" and "page" or "none"
    local html, err = httpGet("/tags/")

    local filters = baseExploreFilters()

    -- 标签页可能被 Cloudflare 单独拒绝;标签筛选是可选增强,不阻断整个发现入口。
    if not html then
        lime.log.warn("explore: tags unavailable: " .. err.message)
        return { paginationMode = paginationMode, filters = filters }
    end
    local doc = lime.dom.parse(html)
    local tag_options = parseTagGroups(doc)

    if #tag_options > 0 then
        filters[#filters + 1] = {
            field = "tags",
            label = "Tags",
            type = "cascade",
            options = tag_options,
        }
    end
    return { supportsPagination = supportsPagination, filters = filters }
end

local function search(query)
    query = query or {}
    local keyword = trim(query.keyword or "")
    local page = math.max(1, math.floor(tonumber(query.page) or 1))
    return { records = searchKeyword(keyword, page) }
end

local function browse(query)
    query = query or {}
    local page = math.max(1, math.floor(tonumber(query.page) or 1))
    local filters = query.filters or {}
    local keyword = trim(filters.keyword or "")
    local sort = filters.sort or "recent"

    -- Random 每次请求都会重排，只允许首屏并通过显式刷新获取下一批。
    if sort == "random" and page > 1 then
        return { records = {} }
    end

    local path = buildExplorePath(keyword, filters, page)
    local html, err = httpGet(path)
    if not html then error(err) end
    local doc = lime.dom.parse(html)
    local out = {}
    for _, card in ipairs(lime.dom.selectAll(doc, "li.site-archive-post")) do
        local cv = selectCvParagraph(card)
        out[#out + 1] = resourceOf(card, cv, BASE .. "/")
    end
    return { records = out }
end

-- ============================================================
-- resourceInfo(单个 post 详情)
-- ============================================================
local function resourceInfo(url)
    if not url or url == "" then error("无效的 URL") end
    local data, err = fetchProductData(url)
    if not data then error(err) end

    return {
        name = data.title,
        author = trim(data.cv or "japaneseasmr"),
        url = url,
        cover = data.cover,
        intro = data.intro,
        latestChapter = data.titles[#data.titles] or data.title,
        latestChapterUrl = url,
        latestUpdateTime = data.latestUpdateTime,
        chapterCount = #data.starts,
        tags = data.tags,
        wordCount = 0,
    }
end

-- ============================================================
-- chapterList — 协议核心改造点
-- 1 个 product(1 个 HLS m3u8 + N 段 track list)拆为 N 个章节共享同一 chapterUrl
-- ============================================================
local function chapterList(resourceUrl)
    if not resourceUrl or resourceUrl == "" then error("无效的 URL") end
    local data, err = fetchProductData(resourceUrl)
    if not data then error(err) end

    -- 兜底:整片 = 1 章
    local starts = data.starts
    if #starts == 0 then starts = { 0 } end

    local chapters = {}
    for i, startSec in ipairs(starts) do
        chapters[#chapters + 1] = {
            id = tostring(startSec),
            name = data.titles[i] or ("トラック " .. i),
            url = resourceUrl,                 -- 共享 chapterUrl
            index = i - 1,                      -- 0-based,与 request.chapter.index 约定一致
        }
    end
    return { chapters = chapters }
end

-- ============================================================
-- chapterContent — audio block 加 clip 表达"同 URL 多段"
-- ============================================================
local function chapterContent(request)
    if not request or not request.resource or not request.chapter then
        error("chapterContent: missing request fields")
    end
    local resourceUrl = request.resource.url
    local chapterIdx = request.chapter.index or 0

    local data, err = fetchProductData(resourceUrl)
    if not data then error(err) end
    if not data.m3u8 or data.m3u8 == "" then
        error({ code = 2007, message = "JapaneseASMR 没有返回可播放的音频源" })
    end

    local starts = #data.starts > 0 and data.starts or { 0 }
    local startMs = (starts[chapterIdx + 1] or 0) * 1000
    local endMs = nil
    if starts[chapterIdx + 2] then
        endMs = starts[chapterIdx + 2] * 1000
    end

    local audioBlock = {
        id = "track-" .. chapterIdx,
        type = "audio",
        title = request.chapter.name,
        artist = trim(data.cv or ""),
        sources = {
            {
                id = "v-main",
                assetId = productAssetId(resourceUrl),
                quality = "high",
                format = "hls",
                mimeType = "application/vnd.apple.mpegurl",
                url = data.m3u8,
                headers = { ["Referer"] = resourceUrl, ["User-Agent"] = UA },
            },
        },
    }
    -- 只有多段作品才声明 clip;单轨作品直接播放完整媒体。
    if #starts > 1 then
        audioBlock.clip = { startMs = startMs, endMs = endMs }
    end

    return {
        blocks = { audioBlock },
    }
end

local function test(request)
    local results, records, info, catalog = {}, nil, nil, nil
    local function run(entry, fn)
        local value = fn()
        results[#results + 1] = { entry = entry, status = "passed", message = "可用" }
        return value
    end
    records = run("search", function() local value = search({ keyword = "asmr", page = 1 }).records; if #value == 0 then error("搜索无结果") end; return value end)
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
        name = "japaneseasmr",
        package = "com.example.japaneseasmr.lime",
        version = "0.0.2",
        author = "ai",
        description = "japaneseasmr",
        homepage = "https://japaneseasmr.com",
        logo = "https://japaneseasmr.com/favicon.ico",
    },
    requires = { "browser", "dom", "http", "log", "storage", "time" },

    capabilities = {
        content = "audio",
        search = searchResources, resourceInfo = describeResource,
        chapterList = listResourceChapters, chapterContent = chapterContent,
        explore = browseResources,
        exploreSchema = exploreSchema,
    },
    hooks = {
        test = test,
    },
}
