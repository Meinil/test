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
            return nil, "browser request failed: HTTP " .. tostring(replay and replay.status or 0), replay and replay.status
        end
        return replay.body, nil, replay.status
    end

    local response = lime.http.get(target, headers)
    if requiresBrowserAuth(response) then
        lime.storage.set(PENDING_BROWSER_KEY, target)
        response = openBrowserChallenge(target)
        lime.storage.remove(PENDING_BROWSER_KEY)
    end
    if not response or response.status < 200 or response.status >= 300 then
        return nil, "HTTP " .. tostring(response and response.status or 0), response and response.status
    end
    if not response.body or response.body == "" then return nil, "empty body", response.status end
    return response.body, nil, response.status
end

-- "12分07秒" / "11分19秒" 等日文时长字符串 → 秒
local function parseJapaneseDuration(s)
    if not s or s == "" then return 0 end
    local m = tostring(s):match("(%d+)分")
    local sec = tostring(s):match("(%d+)秒")
    return (tonumber(m) or 0) * 60 + (tonumber(sec) or 0)
end

-- "00:12:07" 这种 H:M:S 形式 → 秒
local function parseHms(s)
    if not s or s == "" then return 0 end
    local h, m, sec = tostring(s):match("(%d+):(%d+):(%d+)")
    return (tonumber(h) or 0) * 3600 + (tonumber(m) or 0) * 60 + (tonumber(sec) or 0)
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
    if not html then return {} end
    local doc = lime.dom.parse(html)
    local out = {}
    for _, card in ipairs(lime.dom.selectAll(doc, "li.site-archive-post")) do
        local cv = selectCvParagraph(card)
        out[#out + 1] = resourceOf(card, cv, BASE .. "/")
    end
    return out
end

-- ============================================================
-- explore / unified search
-- ============================================================
local function baseExploreFilters()
    return {
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

local function explore()
    local html, err = httpGet("/tags/")

    local filters = baseExploreFilters()

    -- 标签页可能被 Cloudflare 单独拒绝;标签筛选是可选增强,不阻断整个发现入口。
    if not html then
        lime.log.warn("explore: tags unavailable: " .. tostring(err))
        return filters
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
    return filters
end

local function search(query)
    query = query or {}
    local keyword = query.keyword or ""
    if query.filters == nil then
        return { records = searchKeyword(keyword, 1) }
    end
    local page = math.max(1, math.floor(tonumber(query.current) or 1))
    local filters = query.filters
    local sort = filters.sort or "recent"

    -- Random 每次请求都会重排，只允许首屏并通过下拉刷新获取下一批。
    if sort == "random" and page > 1 then
        return { records = {} }
    end

    local path = buildExplorePath(keyword, filters, page)
    local html, err = httpGet(path)
    lime.log.info("search: path=" .. path .. " err=" .. tostring(err))
    if not html then return { records = {} } end
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
    if not data then error("fetch post failed: " .. tostring(err)) end

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
    if not data then error("chapterList: fetch failed: " .. tostring(err)) end

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
    if not data then error("chapterContent: fetch failed: " .. tostring(err)) end
    if not data.m3u8 or data.m3u8 == "" then
        error("chapterContent: no audio source found")
    end

    local starts = #data.starts > 0 and data.starts or { 0 }
    local startMs = (starts[chapterIdx + 1] or 0) * 1000
    local endMs
    if starts[chapterIdx + 2] then
        endMs = starts[chapterIdx + 2] * 1000
    else
        -- 最后一章用 starts 末值 + 上一段时长 × 1.1 作兜底 endMs;
        -- Player 端再用 `min(endMs, audio.duration * 1000)` 进一步兜底
        local lastStart = starts[#starts] or 0
        local prevGap = (#starts > 1) and ((starts[#starts] - starts[#starts - 1]) * 1000) or 600000
        endMs = lastStart * 1000 + math.floor(prevGap * 1.1)
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

-- ============================================================
-- test(冒烟;失败/成功都返 TestResultVO)
-- ============================================================
local function test(content)
    local html, err = httpGet("/tags/")
    if not html then
        return { ok = false, message = "无法连接 " .. BASE .. ": " .. tostring(err or "network") }
    end
    local doc = lime.dom.parse(html)
    local groups = parseTagGroups(doc)
    local count = 0
    for _, group in ipairs(groups) do
        count = count + #group.children
    end
    local filters = baseExploreFilters()
    local randomEnd = search({ keyword = "", current = 2, filters = { sort = "random" } })
    local productHtml, productErr = httpGet("/148155/")
    if not productHtml then
        return { ok = false, message = "详情页标签测试失败: " .. tostring(productErr or "network") }
    end
    local productDoc = lime.dom.parse(productHtml)
    local productTags = parseProductTags(productDoc)
    local productIntro = parseProductIntro(productDoc)
    local productTitles = parseTrackTitles(productDoc, 4)
    local productLastUpdate = parseLastUpdate(productHtml)
    local expectedTags = { ["18禁"] = false, ["Big Breasts 【巨乳/爆乳】"] = false, ["豊川ゆき"] = false }
    for _, tag in ipairs(productTags) do
        if expectedTags[tag] ~= nil then expectedTags[tag] = true end
    end
    local scopes = {
        { keyword = "", filters = { tags = { "group-1", "2022" } }, first = "/tag/2022/", second = "/tag/2022/page/2/", separator = "?" },
        { keyword = "", filters = { rating = "rating/maniax" }, first = "/category/rating/maniax/", second = "/category/rating/maniax/page/2/", separator = "?" },
        { keyword = "asmr", filters = {}, first = "/?s=asmr&paged=1", second = "/?s=asmr&paged=2", separator = "&" },
    }
    local sorts = {
        { value = "recent", query = "order=desc" },
        { value = "popular_month", query = "orderby=post_views&order=desc&date=month" },
        { value = "popular_year", query = "orderby=post_views&order=desc&date=year" },
        { value = "popular_all", query = "orderby=post_views&order=desc" },
    }
    for _, scope in ipairs(scopes) do
        for _, sortCase in ipairs(sorts) do
            scope.filters.sort = sortCase.value
            local first = buildExplorePath(scope.keyword, scope.filters, 1)
            local second = buildExplorePath(scope.keyword, scope.filters, 2)
            if first ~= scope.first .. scope.separator .. sortCase.query
                or second ~= scope.second .. scope.separator .. sortCase.query then
                return { ok = false, message = "search URL 组合异常: " .. sortCase.value }
            end
        end
    end
    if #groups == 0 or count < 5 then
        return { ok = false, message = "tag groups 异常(groups=" .. #groups .. ", tags=" .. count .. ")" }
    end
    if #filters[2].options ~= 5 or filters[2].default ~= "recent" then
        return { ok = false, message = "Sort 筛选声明异常" }
    end
    if #productTags < 10 or not expectedTags["18禁"]
        or not expectedTags["Big Breasts 【巨乳/爆乳】"] or not expectedTags["豊川ゆき"] then
        return { ok = false, message = "详情页标签解析异常(tags=" .. #productTags .. ")" }
    end
    if not productLastUpdate then
        return { ok = false, message = "详情页 Last update 解析异常" }
    end
    if not productIntro or not productIntro:find("ある夏の暑い日", 1, true)
        or productIntro:find("担当声優", 1, true) then
        return { ok = false, message = "详情页日文简介解析异常" }
    end
    if productTitles[1] ~= "苦くて白い日焼け止めオイル(オイルマッサージ、馬乗りパイズリ、顔射、精子舐め)"
        or productTitles[4] ~= "朝勃ちフェラは美味しい朝ごはん(お目覚めフェラ、正常位、中出し)" then
        return { ok = false, message = "详情页章节标题解析异常" }
    end
    if type(randomEnd) ~= "table" or type(randomEnd.records) ~= "table" or #randomEnd.records ~= 0 then
        return { ok = false, message = "search 分页对象异常" }
    end
    return { ok = true, message = "OK · groups=" .. #groups .. " · tags=" .. count .. " · productTags=" .. #productTags }
end

return {
    protocol = "lime-plugin",
    apiVersion = 1,
    manifest = {
        name = "japaneseasmr",
        package = "com.example.japaneseasmr.lime",
        version = "0.0.4",
        author = "ai",
        description = "japaneseasmr",
        homepage = "https://japaneseasmr.com",
        logo = "https://japaneseasmr.com/favicon.ico",
    },
    requires = { "browser", "dom", "http", "log", "storage", "time" },
    contract = {
        kind = "resource",
        content = "audio",
        search = search,
        resourceInfo = resourceInfo,
        chapterList = chapterList,
        chapterContent = chapterContent,
        explore = explore,
    },
    hooks = {
        test = test,
    },
}
