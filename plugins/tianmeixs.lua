--[[
    @name            天美小说
    @package         com.meinil.lime.ai.tianmeixs
    @content         novel
    @author          legado-to-lime
    @url             https://m.tianmeixs.com
    @sourceUrl       https://m.tianmeixs.com#🎃
    @version         0.1.0
    @description     Converted from Legado source 天美小说.
]]

local BASE = "https://m.tianmeixs.com"
local CONTENT = "novel"

local BROWSER_HEADERS = {
    ["User-Agent"] = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
    ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    ["Accept-Language"] = "zh-CN,zh;q=0.9",
}

local CATEGORIES = {
    { field = "1", label = "玄幻奇幻", url = "/sort/1_{{page}}/" },
    { field = "2", label = "武侠仙侠", url = "/sort/2_{{page}}/" },
    { field = "3", label = "都市言情", url = "/sort/3_{{page}}/" },
    { field = "4", label = "科幻网游", url = "/sort/4_{{page}}/" },
    { field = "5", label = "惊悚悬疑", url = "/sort/5_{{page}}/" },
    { field = "6", label = "耽美同人", url = "/sort/6_{{page}}/" },
    { field = "7", label = "穿越架空", url = "/sort/7_{{page}}/" },
    { field = "8", label = "高辣浓情", url = "/sort/8_{{page}}/" },
    { field = "9", label = "禁忌百合", url = "/sort/9_{{page}}/" },
    { field = "10", label = "精品文学", url = "/sort/10_{{page}}/" },
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
    if referer and referer ~= "" then headers["Referer"] = referer end
    return headers
end

local function httpGet(url, referer)
    local body, _, err = lime.http.get(url, documentHeaders(referer or BASE .. "/"))
    if err then error("lime.http.get: " .. tostring(err)) end
    return body
end

local function httpPost(url, body, referer)
    local headers = documentHeaders(referer or BASE .. "/")
    headers["Content-Type"] = "application/x-www-form-urlencoded"
    local text, _, err = lime.http.post(url, body, headers)
    if err then error("lime.http.post: " .. tostring(err)) end
    return text
end

local function encodeGbLike(value)
    local out, err = lime.crypto.urlEncodeWithCharset(tostring(value or ""), "GBK")
    if err then return tostring(value or "") end
    return out or tostring(value or "")
end

local function htmlToText(html)
    if not html then return "" end
    local s = tostring(html)
        :gsub("<script.->.-</script>", "")
        :gsub("<style.->.-</style>", "")
        :gsub("<br ?/?>", "\n")
        :gsub("</p>", "\n")
        :gsub("</div>", "\n")
        :gsub("<[^>]+>", "")
        :gsub("&emsp;", "    ")
        :gsub("&nbsp;", " ")
        :gsub("&amp;", "&")
        :gsub("&lt;", "<")
        :gsub("&gt;", ">")
        :gsub("&quot;", '"')
        :gsub("&#39;", "'")
        :gsub("\r", "")
        :gsub("\n%s+\n", "\n")
    return trim(s)
end

local function blocksFromText(raw)
    local blocks = {}
    for para in tostring(raw or ""):gmatch("[^\n]+") do
        para = trim(para)
        if para ~= "" then blocks[#blocks + 1] = { type = "txt", content = para } end
    end
    return blocks
end

local function cleanLabel(value, label)
    local s = trim(value)
    if label and label ~= "" then s = s:gsub("^" .. label, "") end
    return trim(s)
end

local function tagsFromKind(kind)
    local tags = {}
    kind = trim(kind):gsub("^%[", ""):gsub("%]$", "")
    if kind ~= "" then tags[#tags + 1] = kind end
    return tags
end

local function buildCoverUrl(bookUrl)
    local id, folder = tostring(bookUrl or ""):match("/book/((%d+)%d%d%d)%.html")
    if id and folder then return "http://img.tianmeixs.com/image/" .. folder .. "/" .. id .. "/" .. id .. "s.jpg" end
    return ""
end

local function anchorByText(doc, selector, needle)
    for _, el in ipairs(lime.dom.selectAll(doc, selector) or {}) do
        if text(el):find(needle, 1, true) then return el end
    end
    return nil
end

local function parseSearchResources(html, baseUrl)
    local doc = lime.dom.parse(html or "")
    local items = lime.dom.selectAll(doc, ".fk li")
    local out = {}
    for _, item in ipairs(items or {}) do
        local sub = subdoc(item)
        local links = lime.dom.selectAll(sub, "a")
        local kind = text(links[1])
        local titleEl = links[2]
        local authorEl = links[3]
        local url = absolutize(attr(titleEl, "href"), baseUrl)
        local name = text(titleEl)
        if name ~= "" and url ~= "" then
            out[#out + 1] = {
                name = name,
                author = text(authorEl),
                url = url,
                coverUrl = buildCoverUrl(url),
                intro = "",
                latestChapter = "",
                latestChapterUrl = "",
                kind = kind:gsub("%[", ""):gsub("%]", ""),
                tags = tagsFromKind(kind),
                wordCount = 0,
                chapterCount = 0,
                latestUpdateTime = nil,
                content = CONTENT,
            }
        end
    end
    return out
end

local function parseExploreResources(html, baseUrl)
    local doc = lime.dom.parse(html or "")
    local items = lime.dom.selectAll(doc, "section.list ul.xbk")
    local out = {}
    for _, item in ipairs(items or {}) do
        local sub = subdoc(item)
        local titleEl = lime.dom.select(sub, ".xsm a")
        if not titleEl then titleEl = lime.dom.select(sub, "li:first-child a") end
        local url = absolutize(attr(titleEl, "href"), baseUrl)
        local name = text(titleEl)
        local spans = lime.dom.selectAll(sub, "span")
        local author = cleanLabel(text(spans[2]), "作者：")
        local intro = text(spans[3])
        local kind = text(spans[#spans])
        local coverUrl = absolutize(selectAttr(sub, "img", "src"), baseUrl)
        if coverUrl:find("/explore_search_files/", 1, true) or coverUrl:find("/css/noimg.jpg", 1, true) then
            coverUrl = buildCoverUrl(url)
        end
        if name ~= "" and url ~= "" then
            out[#out + 1] = {
                name = name,
                author = author,
                url = url,
                coverUrl = coverUrl,
                intro = intro,
                latestChapter = "",
                latestChapterUrl = "",
                kind = kind,
                tags = tagsFromKind(kind),
                wordCount = 0,
                chapterCount = 0,
                latestUpdateTime = nil,
                content = CONTENT,
            }
        end
    end
    return out
end

local function rawSearch(keyword, page)
    local url = BASE .. "/s.php"
    local body = "type=articlename&s=" .. encodeGbLike(keyword or "")
    local html = httpPost(url, body, BASE .. "/")
    return parseSearchResources(html, url)
end

local function rawResourceInfo(bookUrl)
    local fullUrl = absolutize(bookUrl, BASE)
    local html = httpGet(fullUrl, BASE .. "/")
    local doc = lime.dom.parse(html)
    local name = cleanLabel(selectText(doc, ".xx ul li:nth-child(1)"), "")
    if name == "" then
        error("未找到资源详情")
    end
    local kind = cleanLabel(selectText(doc, ".xx ul li:nth-child(2)"), "分类：")
    local author = cleanLabel(selectText(doc, ".xx ul li:nth-child(3)"), "作者：")
    local latestChapter = cleanLabel(selectText(doc, ".xx ul li:nth-child(4)"), "更新：")
    local tocEl = anchorByText(doc, "a", "查看更多章节")
    local tocUrl = absolutize(attr(tocEl, "href"), fullUrl)
    if tocUrl == "" then tocUrl = fullUrl end
    return {
        name = name,
        author = author,
        url = fullUrl,
        coverUrl = absolutize(selectAttr(doc, "#xinxi .xsfm img", "src"), fullUrl),
        intro = selectText(doc, "#xinxi div:last-child"),
        latestChapter = latestChapter,
        latestChapterUrl = "",
        kind = kind,
        tags = tagsFromKind(kind),
        tocUrl = tocUrl,
        wordCount = nil,
        chapterCount = 0,
        latestUpdateTime = nil,
        content = CONTENT,
    }
end

local function parseChapterPage(html, pageUrl, chapters, seenChapter, pageQueue, seenPage)
    local doc = lime.dom.parse(html or "")
    for _, a in ipairs(lime.dom.selectAll(doc, "#zjlb .fk li a") or {}) do
        local name = text(a):gsub("本页章节列表结束！", "")
        local url = absolutize(attr(a, "href"), pageUrl)
        if name ~= "" and url ~= "" and not seenChapter[url] then
            seenChapter[url] = true
            chapters[#chapters + 1] = { name = name, url = url, index = #chapters + 1 }
        end
    end
    for _, a in ipairs(lime.dom.selectAll(doc, ".showpage ul li a") or {}) do
        local href = attr(a, "href")
        local url = absolutize(href, pageUrl)
        if url ~= "" and not seenPage[url] then
            seenPage[url] = true
            pageQueue[#pageQueue + 1] = url
        end
    end
end

local function rawChapterList(bookUrl)
    local firstUrl = absolutize(bookUrl, BASE)
    local info = rawResourceInfo(firstUrl)
    -- rawResourceInfo 失败时 throw,会自动冒泡到 backend
    if info.tocUrl and info.tocUrl ~= "" then firstUrl = info.tocUrl end

    local chapters = {}
    local seenChapter = {}
    local seenPage = { [firstUrl] = true }
    local pageQueue = { firstUrl }
    local cursor = 1
    while cursor <= #pageQueue and cursor <= 30 do
        local pageUrl = pageQueue[cursor]
        cursor = cursor + 1
        local html = httpGet(pageUrl, firstUrl)
        parseChapterPage(html, pageUrl, chapters, seenChapter, pageQueue, seenPage)
    end
    return chapters
end

local function rawChapterContent(chapterUrl)
    local fullUrl = absolutize(chapterUrl, BASE)
    local html = httpGet(fullUrl, BASE .. "/")
    local doc = lime.dom.parse(html)
    local contentEl = lime.dom.select(doc, "#nr")
    local raw = contentEl and lime.dom.html(contentEl) or ""
    local blocks = blocksFromText(htmlToText(raw))
    if #blocks == 0 then error("章节内容为空") end
    return blocks
end

local function rawExplore()
    local options = {}
    for _, c in ipairs(CATEGORIES) do
        options[#options + 1] = { field = c.field, label = c.label }
    end
    return {
        {
            field = "category",
            label = "分类",
            type = "single",
            options = options,
        },
    }
end

local function rawExploreSearch(keyword, payload)
    local selected = CATEGORIES[1]
    local wanted = payload and payload.filters and payload.filters.category
    for _, c in ipairs(CATEGORIES) do
        if tostring(c.field) == tostring(wanted) then selected = c end
    end
    local page = payload and tonumber(payload.current) or 1
    local url = absolutize(selected.url:gsub("{{page}}", tostring(page)), BASE)
    lime.log.info("url" .. url)
    local html = httpGet(url, BASE .. "/")
    return parseExploreResources(html, url)
end

local function rawTest(content)
    local html = httpGet(BASE .. "/sort/1_1/", BASE .. "/")
    local count = #parseExploreResources(html, BASE .. "/sort/1_1/")
    local message = "天美小说 explore smoke path returned " .. tostring(count) .. " items"
    return { ok = true, message = message }
end

-- 顶层入口函数已直接定义在 globals(每个 raw 函数即顶层入口)。
-- 成功:返回裸数据,失败:throw error。
function search(keyword, page)
    return rawSearch(keyword, page)
end

function resourceInfo(bookUrl)
    return rawResourceInfo(bookUrl)
end

function chapterList(bookUrl)
    return rawChapterList(bookUrl)
end

function chapterContent(chapterUrl)
    return rawChapterContent(chapterUrl)
end

function explore()
    return rawExplore()
end

function exploreSearch(keyword, payload)
    return rawExploreSearch(keyword, payload)
end

function test(content)
    return rawTest(content)
end
