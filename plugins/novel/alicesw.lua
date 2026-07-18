local BASE = "https://xn--vcsx64d.alicesw12.xyz"
local CONTENT = "novel"
local TZ_OFFSET = 8 * 60 * 60

local BROWSER_HEADERS = {
    ["User-Agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36 Edg/149.0.0.0",
    ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
    ["Accept-Language"] = "zh-CN,zh;q=0.9",
    ["Accept-Encoding"] = "gzip, deflate, br, zstd",
    ["sec-ch-ua"] = '"Microsoft Edge";v="149", "Chromium";v="149", "Not)A;Brand";v="24"',
    ["sec-ch-ua-mobile"] = "?0",
    ["sec-ch-ua-platform"] = '"macOS"',
    ["Sec-Fetch-Dest"] = "document",
    ["Sec-Fetch-Mode"] = "navigate",
    ["Sec-Fetch-Site"] = "none",
    ["Sec-Fetch-User"] = "?1",
    ["Upgrade-Insecure-Requests"] = "1",
}

local CATEGORIES = {
    { field = "hits", label = "总排行", url = BASE .. "/other/rank_hits/order/hits.html" },
    { field = "hits_month", label = "月排行", url = BASE .. "/other/rank_hits/order/hits_month.html" },
    { field = "hits_week", label = "周排行", url = BASE .. "/other/rank_hits/order/hits_week.html" },
    { field = "hits_day", label = "日排行", url = BASE .. "/other/rank_hits/order/hits_day.html" },
    { field = "71", label = "科幻", url = BASE .. "/all/id/71/order/hits+desc.html?page={{page}}" },
    { field = "61", label = "校园", url = BASE .. "/all/id/61/order/hits+desc.html?page={{page}}" },
    { field = "62", label = "玄幻", url = BASE .. "/all/id/62/order/hits+desc.html?page={{page}}" },
    { field = "63", label = "乡村", url = BASE .. "/all/id/63/order/hits+desc.html?page={{page}}" },
    { field = "64", label = "都市", url = BASE .. "/all/id/64/order/hits+desc.html?page={{page}}" },
    { field = "65", label = "乱伦", url = BASE .. "/all/id/65/order/hits+desc.html?page={{page}}" },
    { field = "67", label = "历史", url = BASE .. "/all/id/67/order/hits+desc.html?page={{page}}" },
    { field = "68", label = "武侠", url = BASE .. "/all/id/68/order/hits+desc.html?page={{page}}" },
    { field = "69", label = "系统", url = BASE .. "/all/id/69/order/hits+desc.html?page={{page}}" },
    { field = "72", label = "明星", url = BASE .. "/all/id/72/order/hits+desc.html?page={{page}}" },
    { field = "73", label = "同人", url = BASE .. "/all/id/73/order/hits+desc.html?page={{page}}" },
    { field = "74", label = "强奸", url = BASE .. "/all/id/74/order/hits+desc.html?page={{page}}" },
    { field = "75", label = "奇幻", url = BASE .. "/all/id/75/order/hits+desc.html?page={{page}}" },
    { field = "79", label = "经典", url = BASE .. "/all/id/79/order/hits+desc.html?page={{page}}" },
    { field = "70", label = "穿越", url = BASE .. "/all/id/70/order/hits+desc.html?page={{page}}" },
    { field = "46", label = "凌辱", url = BASE .. "/all/id/46/order/hits+desc.html?page={{page}}" },
    { field = "22", label = "反差", url = BASE .. "/all/id/22/order/hits+desc.html?page={{page}}" },
    { field = "18", label = "堕落", url = BASE .. "/all/id/18/order/hits+desc.html?page={{page}}" },
    { field = "19", label = "纯爱", url = BASE .. "/all/id/19/order/hits+desc.html?page={{page}}" },
    { field = "52", label = "伪娘", url = BASE .. "/all/id/52/order/hits+desc.html?page={{page}}" },
    { field = "48", label = "萝莉", url = BASE .. "/all/id/48/order/hits+desc.html?page={{page}}" },
    { field = "56", label = "熟女", url = BASE .. "/all/id/56/order/hits+desc.html?page={{page}}" },
    { field = "51", label = "禁忌", url = BASE .. "/all/id/51/order/hits+desc.html?page={{page}}" },
    { field = "54", label = "NTR", url = BASE .. "/all/id/54/order/hits+desc.html?page={{page}}" },
    { field = "53", label = "媚黑", url = BASE .. "/all/id/53/order/hits+desc.html?page={{page}}" },
    { field = "55", label = "绿帽", url = BASE .. "/all/id/55/order/hits+desc.html?page={{page}}" },
    { field = "58", label = "调教", url = BASE .. "/all/id/58/order/hits+desc.html?page={{page}}" },
    { field = "59", label = "女主", url = BASE .. "/all/id/59/order/hits+desc.html?page={{page}}" },
    { field = "50", label = "正太", url = BASE .. "/all/id/50/order/hits+desc.html?page={{page}}" },
    { field = "43", label = "下克上", url = BASE .. "/all/id/43/order/hits+desc.html?page={{page}}" },
    { field = "47", label = "百合", url = BASE .. "/all/id/47/order/hits+desc.html?page={{page}}" },
    { field = "21", label = "重口", url = BASE .. "/all/id/21/order/hits+desc.html?page={{page}}" },
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

local function originOf(url)
    return tostring(url or ""):match("^(https?://[^/]+)") or BASE
end

local function absolutize(url, base)
    if not url or url == "" then return "" end
    url = tostring(url)
    if url:match("^https?://") then return url end
    if url:sub(1, 2) == "//" then return "https:" .. url end
    local b = base or BASE
    if url:sub(1, 1) == "/" then return originOf(b) .. url end
    local prefix = b:match("^(.*)/[^/]*$") or b
    if not prefix:match("^https?://") then prefix = BASE end
    return prefix .. "/" .. url
end

local function documentHeaders(referer)
    local headers = {}
    for k, v in pairs(BROWSER_HEADERS) do headers[k] = v end
    if referer and referer ~= "" then
        headers["Referer"] = referer
        headers["Sec-Fetch-Site"] = "same-origin"
    end
    return headers
end

local function httpGet(url, referer)
    local response = lime.http.get(url, documentHeaders(referer or BASE .. "/"))
    if response.status < 200 or response.status >= 300 then
        error("lime.http.get: HTTP " .. tostring(response.status))
    end
    return response.body
end

local function encodeUrl(textValue)
    local out, err = lime.crypto.urlEncode(tostring(textValue or ""))
    if err then return tostring(textValue or "") end
    return out or tostring(textValue or "")
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

local function bookIdFromUrl(url)
    return tostring(url or ""):match("/novel/(%d+)%.html")
        or tostring(url or ""):match("/other/chapters/id/(%d+)%.html")
end

local function tocUrlFromBookUrl(url)
    local id = bookIdFromUrl(url)
    return id and (BASE .. "/other/chapters/id/" .. id .. ".html") or url
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

local function blocksFromText(raw)
    local blocks = {}
    for para in tostring(raw or ""):gmatch("[^\n]+") do
        para = trim(para)
        if para ~= "" then
            blocks[#blocks + 1] = { id = "text-" .. tostring(#blocks + 1), type = "text", text = para }
        end
    end
    return blocks
end

local function tagsFromKind(kind)
    local tags = {}
    kind = trim(kind)
    if kind ~= "" then tags[#tags + 1] = kind end
    return tags
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
        tags = tagsFromKind(kind),
        wordCount = parseCount(selectText(doc, "li.five")),
        chapterCount = 0,
        latestUpdateTime = latestTime,
    }
end

local function parseRankResources(html, baseUrl)
    local doc = lime.dom.parse(html or "")
    local items = lime.dom.selectAll(doc, ".rec_rullist > ul")
    local out = {}
    for _, item in ipairs(items or {}) do
        local resource = resourceFromRankItem(item, baseUrl)
        if resource.name ~= "" and resource.url ~= "" then out[#out + 1] = resource end
    end
    return out
end

local function parseSearchResources(html, baseUrl)
    local doc = lime.dom.parse(html or "")
    local items = lime.dom.selectAll(doc, ".list-group .list-group-item")
    if not items or #items == 0 then return parseRankResources(html, baseUrl) end
    local out = {}
    for _, item in ipairs(items) do
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
                tags = tagsFromKind(kind),
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
    if name == "" then name = selectText(doc, "meta[property='og:novel:book_name']") end
    local author = selectText(doc, "#detail-box .novel_info a[href*='f=author']")
    if author == "" then author = selectText(doc, "#detail-box .novel_info p:nth-child(2) a") end
    local cover = selectAttr(doc, "#detail-box img", "data-src") or selectAttr(doc, "#detail-box img", "src") or ""
    local intro = selectText(doc, ".jianjie > p")
    if intro == "" then intro = selectText(doc, "#detail-box .book_intro") end
    local kind = selectText(doc, "#detail-box .novel_info a[href*='/lists/']")
    local latestEl = lime.dom.select(doc, "#detail-box a.blue[href*='/book/']")
    if not latestEl then latestEl = lime.dom.select(doc, ".book_newchap a") end
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
        tags = tagsFromKind(kind),
        tocUrl = tocUrl,
        wordCount = wordCount,
        chapterCount = chapterCount,
        latestUpdateTime = latestUpdateTime,
    }
end

local function fetchUrl(urlTemplate, keyword, page)
    local url = tostring(urlTemplate or "")
    url = url:gsub("{{key}}", encodeUrl(keyword or ""))
    url = url:gsub("{{page}}", tostring(page or 1))
    url = absolutize(url, BASE)
    return httpGet(url, BASE .. "/"), url
end

local function search(keyword, page)
    local html, finalUrl = fetchUrl(BASE .. "/search.html?q={{key}}&f=_al", keyword, page or 1)
    return parseSearchResources(html, finalUrl)
end

local function resourceInfo(bookUrl)
    local fullUrl = absolutize(bookUrl, BASE)
    local html = httpGet(fullUrl, BASE .. "/")
    return parseDetail(html, fullUrl)
end

local function chapterList(bookUrl)
    local fullUrl = absolutize(bookUrl, BASE)
    if fullUrl:find("/novel/", 1, true) then fullUrl = tocUrlFromBookUrl(fullUrl) end
    local html = httpGet(fullUrl, BASE .. "/")
    local doc = lime.dom.parse(html)
    local links = lime.dom.selectAll(doc, "ul.mulu_list li a")
    local chapters = {}
    local seen = {}
    for _, link in ipairs(links or {}) do
        local url = absolutize(attr(link, "href"), fullUrl)
        local name = text(link)
        if name ~= "" and url ~= "" and not seen[url] then
            seen[url] = true
            chapters[#chapters + 1] = { id = url, name = name, url = url, index = #chapters + 1 }
        end
    end
    return { chapters = chapters }
end

local function chapterContent(request)
    local chapterUrl = request.chapter.url
    local fullUrl = absolutize(chapterUrl, BASE)
    local html = httpGet(fullUrl, BASE .. "/")
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
    local blocks = blocksFromText(table.concat(chunks, "\n"))
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

local function exploreSearch(keyword, payload)
    local selected = CATEGORIES[1]
    local wanted = payload and payload.filters and payload.filters.category
    for _, c in ipairs(CATEGORIES) do
        if tostring(c.field) == tostring(wanted) then selected = c end
    end
    local page = payload and tonumber(payload.current) or 1
    local html, finalUrl = fetchUrl(selected.url, keyword, page)
    return { records = parseRankResources(html, finalUrl) }
end

local function test(content)
    local results = search(content or "美母为妻", 1)
    local count = type(results) == "table" and #results or 0
    local message = "爱丽丝书屋 smoke path returned " .. tostring(count) .. " items"
    return { ok = true, message = message }
end

return {
    protocol = "lime-plugin", apiVersion = 1,
    manifest = { name = "爱丽丝书屋", package = "com.meinil.lime.ai.alicesw", version = "0.0.1", author = "ai", description = "国内发布页：https://www.asw2.cc/", homepage = "https://xn--vcsx64d.alicesw12.xyz" },
    requires = { "crypto", "dom", "http", "log", "time" },
    contract = { kind = "resource", content = "novel", search = search, resourceInfo = resourceInfo, chapterList = chapterList, chapterContent = chapterContent, explore = { filters = explore, search = exploreSearch } },
    hooks = { test = test },
}
