--[[
    @name            奇书网
    @package         com.qishuwang.novel
    @content         novel
    @author          Ai
    @url             https://www.qishuxia.com
    @logo            https://www.qishuxia.com/favicon.ico
    @sourceUrl       https://raw.githubusercontent.com/Meinil/test/refs/heads/main/plugins/qishuxia.lua
    @version         1.1.2
    @description     奇书网 - 好看的小说大全免费在线阅读和 txt 下载
]]

-- =====================================================================
-- 配置
-- =====================================================================
local BASE = "https://www.qishuxia.com"

-- 通用 HTTP 头(模拟 Chrome 120 真实请求)
local BROWSER_HEADERS = {
    ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    ["Accept-Language"] = "zh-CN,zh;q=0.9",
    ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
    ["Accept-Encoding"] = "gzip, deflate, br",
    ["sec-ch-ua"] = '"Not_A Brand";v="8", "Chromium";v="120", "Google Chrome";v="120"',
    ["sec-ch-ua-mobile"] = "?0",
    ["sec-ch-ua-platform"] = '"Windows"',
    ["Upgrade-Insecure-Requests"] = "1",
}

-- 探索页分类(同时是 explore() 的 options 数据源)
-- field = URL 中分类目录 id,label = 显示文案
local CATEGORIES = {
    { field = "xuanhuanxiaoshuo",  label = "玄幻奇幻" },
    { field = "xiuzhenxiaoshuo",   label = "武侠仙侠" },
    { field = "dushixiaoshuo",     label = "都市言情" },
    { field = "lishixiaoshuo",     label = "历史军事" },
    { field = "kehuanxiaoshuo",    label = "科幻灵异" },
    { field = "wangyouxiaoshuo",   label = "网游竞技" },
    { field = "nvshengxiaoshuo",   label = "女生频道" },
}

-- 章节正文清理:服务端嵌入的固定格式噪声
-- (Lua 模式下 `[^%s]+` 表示非空白;`[^\n]*` 表示行内任意字符)
local CONTENT_NOISE_PATTERNS = {
    "记住网站域名www[^%s]+com",
    "天才一秒记住[^%s]+最快更新",
    "本章未开[^\n]*",
    "本章未完[^\n]*",
    "请收藏[^\n]*",
    "章节报错[^\n]*",
}

-- 章节列表过滤:跨域且非 /book/ 路径的链接视为非章节(参考 JS 原逻辑)
-- 例如外站广告链接:href 含 // 但不含 /book/ 子串的直接跳过
local function isChapterLink(href)
    if not href or href == "" then return false end
    if not href:find(".html", 1, true) then return false end
    if href:find("//", 1, true) and not href:find("/book/", 1, true) then
        return false
    end
    return true
end

-- =====================================================================
-- 工具:字符串处理
-- =====================================================================

--- 去除首尾空白(含全角空格 U+3000 / 不间断空格 U+00A0)
--- @param s any 输入字符串
--- @return string
local function trim(s)
    if not s or s == "" then return "" end
    s = tostring(s)
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    s = s:gsub("^\227\128\128+", ""):gsub("\227\128\128+$", "")
    s = s:gsub("^\194\160+", ""):gsub("\194\160+$", "")
    return s
end

--- 把可能的相对 URL 拼成绝对 URL
--- 规则:
---   1) 已是 http(s):// 开头 → 原样返回
---   2) 以 / 开头 → 拼 BASE
---   3) 其它相对路径 → 拼 base 的最后一段目录(参考 JS absUrl 语义)
--- @param url string?
--- @param base string?
--- @return string
local function absolutize(url, base)
    if not url or url == "" then return url or "" end
    if url:sub(1, 4) == "http" then return url end
    if url:sub(1, 1) == "/" then return BASE .. url end
    local b = base or BASE
    local lastSlash = b:find("/[^/]*$")
    if not lastSlash or lastSlash <= 8 then return b .. "/" .. url end
    return b:sub(1, lastSlash) .. url
end

-- =====================================================================
-- 工具:DOM 包装(我们的 lime.dom 只有 select/text/attr,没有 selectText/selectAttr/remove)
-- =====================================================================

--- legado.dom.selectText 的等价物:取首个匹配元素的 text(无匹配空字符串)
--- @param doc userdata DomDocument
--- @param sel string CSS 选择器
--- @return string
local function selectText(doc, sel)
    local el = lime.dom.select(doc, sel)
    if not el then return "" end
    local t = lime.dom.text(el)
    return t or ""
end

--- lime.dom.select / selectAll 只接受 DomDocument,不能从 element 子树内查询。
--- 把 element 的 outerHTML 重新 parse 成 sub-doc 再 select,即可在 element 子树内做后代选择器。
local function selectIn(itemEl, sel)
    return lime.dom.select(lime.dom.parse(lime.dom.html(itemEl)), sel)
end

--- 子树内 selectAll:返回 itemEl 子树内所有匹配 sel 的元素
local function selectAllIn(itemEl, sel)
    return lime.dom.selectAll(lime.dom.parse(lime.dom.html(itemEl)), sel)
end

--- 子树内 selectText:取 itemEl 子树内首个匹配 sel 的元素的 text
local function selectInText(itemEl, sel)
    local el = selectIn(itemEl, sel)
    if not el then return "" end
    local t = lime.dom.text(el)
    return t or ""
end

--- 子树内 selectAttr
local function selectInAttr(itemEl, sel, key)
    local el = selectIn(itemEl, sel)
    if not el then return nil end
    return lime.dom.attr(el, key)
end

-- =====================================================================
-- 工具:HTTP 包装
-- =====================================================================

--- GET 包装,失败返 nil + err;成功返 body
local function httpGet(url, headers)
    local body, err = lime.http.get(url, headers)
    if err and tostring(err):find("HTTP 403", 1, true) and tostring(err):find("window.location.href", 1, true) then
        lime.log.info("httpGet: retry after 403 js redirect challenge")
        body, err = lime.http.get(url, headers)
    end
    if err then return nil, err end
    return body, nil
end

--- POST 包装,失败返 nil + err
local function httpPost(url, body, headers)
    local text, err = lime.http.post(url, body, headers)
    if err then return nil, err end
    return text, nil
end

-- =====================================================================
-- 工具:章节正文清理
-- =====================================================================

--- 清理章节正文里的固定格式噪声(6 类站点嵌入推广文案)
--- @param s string
--- @return string
local function stripContentNoise(s)
    if not s or s == "" then return s end
    for _, pat in ipairs(CONTENT_NOISE_PATTERNS) do
        s = s:gsub(pat, "")
    end
    return s
end

--- 把章节正文 HTML 片段清理为纯文本
--- 注:lime.dom.text(el) 走 scraper,天然不输出 script/style 的文本内容,
--- 所以不需要 legado.dom.remove(el, 'script, style') 这步
--- @param html string 原文 HTML 片段
--- @return string cleaned 纯文本(按段保留 \n)
local function cleanChapterContent(html)
    if not html or html == "" then return "" end
    local s = html
    s = s:gsub("<br ?/?>", "\n")
    s = s:gsub("<[^>]+>", "")
    s = s:gsub("&emsp;", "    ")
    s = s:gsub("&nbsp;", " ")
    s = s:gsub("&amp;", "&")
    s = s:gsub("&lt;", "<")
    s = s:gsub("&gt;", ">")
    s = s:gsub("&quot;", '"')
    s = s:gsub("&#39;", "'")
    s = stripContentNoise(s)
    -- 折叠 3 个以上连续换行为 2 个
    s = s:gsub("\n{3,}", "\n\n")
    return s
end

--- 按段落拆分纯文本,trim 后过滤空段,产出段落数组
--- @param text string
--- @return string[] 每段一个非空段落
local function splitParagraphs(text)
    local out = {}
    if not text or text == "" then return out end
    for para in text:gmatch("[^\r\n]+") do
        para = trim(para)
        if para ~= "" then
            out[#out + 1] = para
        end
    end
    return out
end

-- =====================================================================
-- 工具:数据映射(输出 ResourceDetailVO)
-- =====================================================================

--- 通用 BookItem 构造器(对应 ResourceDetailVO,必填 name/author/url/chapterCount)
local function buildBookItem(name, author, bookUrl, coverUrl, lastChapter, opts)
    opts = opts or {}
    return {
        name          = trim(name),
        author        = trim(author or ""),
        url           = bookUrl,
        coverUrl      = coverUrl or "",
        intro         = opts.intro or "",
        latestChapter = trim(lastChapter or ""),
        chapterCount  = opts.chapterCount or 0,
        wordCount     = opts.wordCount or 0,
        latestChapterUrl = opts.latestChapterUrl or "",
        kind          = opts.kind or "",
    }
end

--- 从书籍详情页 HTML 中提取 og: meta 信息
--- @param html string
--- @return table 包含 name/author/coverUrl/intro/kind/lastChapter 字段
local function parseBookInfoHtml(html)
    local result = {
        name        = "",
        author      = "",
        coverUrl    = "",
        intro       = "",
        kind        = "",
        lastChapter = "",
    }
    if not html or html == "" then return result end

    local function tryMatch(pattern, target)
        local m = html:match(pattern)
        if m and m ~= "" then result[target] = m end
    end

    -- 每个字段有多个候选 og: 标签,按优先级尝试
    local function trySet(key, patterns)
        if result[key] ~= "" then return end
        for _, pat in ipairs(patterns) do
            tryMatch(pat, key)
            if result[key] ~= "" then break end
        end
    end

    trySet("name", {
        '<meta property="og:novel:book_name" content="([^"]+)"',
        '<meta property="og:title" content="([^"]+)"',
    })
    trySet("author", {
        '<meta property="og:novel:author" content="([^"]+)"',
    })
    trySet("coverUrl", {
        '<meta property="og:image" content="([^"]+)"',
    })
    trySet("intro", {
        '<meta property="og:description" content="([^"]+)"',
    })
    trySet("kind", {
        '<meta property="og:novel:category" content="([^"]+)"',
    })
    trySet("lastChapter", {
        '<meta property="og:novel:latest_chapter_name" content="([^"]+)"',
    })

    if result.name == "" then result.name = "未知书名" end
    if result.author == "" then result.author = "未知作者" end
    return result
end

--- 从 li 列表里解析书
--- @param doc userdata DomDocument
--- @param defaultKind string 当 span.s1 缺失时的默认 kind
--- @param isSearch boolean 搜索 vs 发现:作者 span 节点不同
---   搜索:span.s4 = 作者
---   发现:span.s5 = 作者,fallback span.s4
--- @return table[] ResourceDetailVO 数组
local function parseBooks(doc, defaultKind, isSearch)
    local items = lime.dom.selectAll(doc, "li")
    if not items or #items == 0 then return {} end

    local books = {}
    local seen = {}
    for _, liEl in ipairs(items) do
        local kind = selectInText(liEl, "span.s1") or defaultKind or ""
        kind = kind:gsub("^%[", ""):gsub("%]$", "")

        -- 书名 link:span.s2 a
        local titleEl = selectIn(liEl, "span.s2 a")
        if not titleEl then goto continue end

        local href = lime.dom.attr(titleEl, "href") or ""
        local name = lime.dom.text(titleEl) or ""
        if name == "" or href == "" then goto continue end

        local author = ""
        if isSearch then
            author = selectInText(liEl, "span.s4")
        else
            author = selectInText(liEl, "span.s5")
            if author == "" then
                author = selectInText(liEl, "span.s4")
            end
        end

        local bookUrl = absolutize(href)
        if not seen[bookUrl] then
            seen[bookUrl] = true
            books[#books + 1] = buildBookItem(
                name, author, bookUrl, "", "",
                { kind = kind ~= "" and kind or (defaultKind or "小说") }
            )
        end
        ::continue::
    end
    return books
end

-- =====================================================================
-- 工具:站点预热(见 §4.1 cookies.warm)
-- =====================================================================

--- 预热站点 cookie:首次访问必返 403 + Set-Cookie,reqwest 把 cookie 入 jar 后
--- 后续请求自动带上 Cookie 头,即可正常 200。预热调用是幂等的。
local function warmSite()
    local headers = {
        ["User-Agent"]               = BROWSER_HEADERS["User-Agent"],
        ["Accept-Language"]          = BROWSER_HEADERS["Accept-Language"],
        ["Accept"]                   = BROWSER_HEADERS["Accept"],
        ["Accept-Encoding"]          = BROWSER_HEADERS["Accept-Encoding"],
        ["sec-ch-ua"]                = BROWSER_HEADERS["sec-ch-ua"],
        ["sec-ch-ua-mobile"]         = BROWSER_HEADERS["sec-ch-ua-mobile"],
        ["sec-ch-ua-platform"]       = BROWSER_HEADERS["sec-ch-ua-platform"],
        ["Upgrade-Insecure-Requests"] = BROWSER_HEADERS["Upgrade-Insecure-Requests"],
        ["Sec-Fetch-Dest"]           = "document",
        ["Sec-Fetch-Mode"]           = "navigate",
        ["Sec-Fetch-Site"]           = "none",
        ["Sec-Fetch-User"]           = "?1",
    }
    pcall(lime.http.cookies.warm, BASE .. "/", headers)
end

-- =====================================================================
-- 搜索 search(keyword, page)
-- =====================================================================

function search(keyword, page)
    lime.log.info("search: keyword=" .. tostring(keyword))
    if not keyword or keyword == "" then return {} end

    warmSite()

    local headers = {
        ["User-Agent"]         = BROWSER_HEADERS["User-Agent"],
        ["Accept-Language"]    = BROWSER_HEADERS["Accept-Language"],
        ["Accept"]             = BROWSER_HEADERS["Accept"],
        ["Accept-Encoding"]    = BROWSER_HEADERS["Accept-Encoding"],
        ["sec-ch-ua"]          = BROWSER_HEADERS["sec-ch-ua"],
        ["sec-ch-ua-mobile"]   = BROWSER_HEADERS["sec-ch-ua-mobile"],
        ["sec-ch-ua-platform"] = BROWSER_HEADERS["sec-ch-ua-platform"],
        ["Content-Type"]       = "application/x-www-form-urlencoded",
        ["Origin"]             = BASE,
        ["Referer"]            = BASE .. "/",
        ["Sec-Fetch-Dest"]     = "empty",
        ["Sec-Fetch-Mode"]     = "cors",
        ["Sec-Fetch-Site"]     = "same-origin",
    }

    -- 服务端 search 接口用 GBK 编码 keyword(form 表单提交到 GBK 网站)
    local encodedKeyword, encErr = lime.crypto.urlEncodeWithCharset(tostring(keyword), "gbk")
    if not encodedKeyword then
        lime.log.warn("search: gbk encode failed: " .. tostring(encErr))
        return {}
    end

    local body = "searchkey=" .. encodedKeyword
    if page and tonumber(page) and tonumber(page) > 1 then
        body = body .. "&page=" .. tostring(page)
    end

    local html, err = httpPost(BASE .. "/modules/article/search.php", body, headers)
    if not html then
        lime.log.warn("search http failed: " .. tostring(err))
        return {}
    end

    local doc = lime.dom.parse(html)
    local books = parseBooks(doc, "", true)
    lime.log.info("search: keyword=" .. tostring(keyword) .. " count=" .. #books)
    return books
end

-- =====================================================================
-- 资源详情 resourceInfo(bookUrl)
-- =====================================================================

function resourceInfo(bookUrl)
    lime.log.info("resourceInfo: " .. tostring(bookUrl))
    warmSite()
    local headers = {
        ["User-Agent"]             = BROWSER_HEADERS["User-Agent"],
        ["Accept-Language"]        = BROWSER_HEADERS["Accept-Language"],
        ["Accept"]                 = BROWSER_HEADERS["Accept"],
        ["Accept-Encoding"]        = BROWSER_HEADERS["Accept-Encoding"],
        ["sec-ch-ua"]              = BROWSER_HEADERS["sec-ch-ua"],
        ["sec-ch-ua-mobile"]       = BROWSER_HEADERS["sec-ch-ua-mobile"],
        ["sec-ch-ua-platform"]     = BROWSER_HEADERS["sec-ch-ua-platform"],
        ["Upgrade-Insecure-Requests"] = BROWSER_HEADERS["Upgrade-Insecure-Requests"],
        ["Referer"]                = BASE .. "/",
        ["Sec-Fetch-Dest"]         = "document",
        ["Sec-Fetch-Mode"]         = "navigate",
        ["Sec-Fetch-Site"]         = "same-origin",
        ["Sec-Fetch-User"]         = "?1",
    }

    local fullUrl = absolutize(bookUrl)
    local html, err = httpGet(fullUrl, headers)
    if not html then
        lime.log.warn("resourceInfo http failed: " .. tostring(err))
        return nil
    end

    local info = parseBookInfoHtml(html)
    return buildBookItem(
        info.name, info.author, fullUrl,
        absolutize(info.coverUrl),
        info.lastChapter,
        {
            intro        = info.intro,
            kind         = info.kind ~= "" and info.kind or "小说",
            chapterCount = 0, -- 详情页无完整目录数,由 library.rs 入库时按 chapterList 实际数量回填
            wordCount    = 0,
        }
    )
end

-- =====================================================================
-- 章节列表 chapterList(bookUrl)
-- =====================================================================

function chapterList(bookUrl)
    lime.log.info("chapterList: " .. tostring(bookUrl))
    warmSite()
    local headers = {
        ["User-Agent"]               = BROWSER_HEADERS["User-Agent"],
        ["Accept-Language"]          = BROWSER_HEADERS["Accept-Language"],
        ["Accept"]                   = BROWSER_HEADERS["Accept"],
        ["Accept-Encoding"]          = BROWSER_HEADERS["Accept-Encoding"],
        ["sec-ch-ua"]                = BROWSER_HEADERS["sec-ch-ua"],
        ["sec-ch-ua-mobile"]         = BROWSER_HEADERS["sec-ch-ua-mobile"],
        ["sec-ch-ua-platform"]       = BROWSER_HEADERS["sec-ch-ua-platform"],
        ["Upgrade-Insecure-Requests"] = BROWSER_HEADERS["Upgrade-Insecure-Requests"],
        ["Referer"]                  = BASE .. "/",
        ["Sec-Fetch-Dest"]           = "document",
        ["Sec-Fetch-Mode"]           = "navigate",
        ["Sec-Fetch-Site"]           = "same-origin",
        ["Sec-Fetch-User"]           = "?1",
    }

    local fullUrl = absolutize(bookUrl)
    local html, err = httpGet(fullUrl, headers)
    if not html then
        lime.log.warn("chapterList http failed: " .. tostring(err))
        return {}
    end

    local doc = lime.dom.parse(html)
    local container = lime.dom.select(doc, "#section-list")
    local anchors = container and selectAllIn(container, "a") or lime.dom.selectAll(doc, "a")
    if not anchors or #anchors == 0 then
        lime.log.warn("chapterList: no anchors found")
        return {}
    end

    local chapters = {}
    local seen = {}
    for _, aEl in ipairs(anchors) do
        local href = lime.dom.attr(aEl, "href") or ""
        local name = lime.dom.text(aEl) or ""
        if not isChapterLink(href) then goto continue end
        local chUrl = absolutize(href, fullUrl)
        if not seen[chUrl] then
            seen[chUrl] = true
            chapters[#chapters + 1] = {
                name  = trim(name),
                url   = chUrl,
                index = #chapters + 1,
            }
        end
        ::continue::
    end
    lime.log.info("chapterList: count=" .. #chapters)
    return chapters
end

-- =====================================================================
-- 章节正文 chapterContent(chapterUrl)
-- 返回 ChapterBlock[]:每段一个 txt 块(前端 1 块 = 1 个 scroller item)
-- 错误处理:返回 { code = 500, message, data = nil },后端写入失败链路
-- =====================================================================

function chapterContent(chapterUrl)
    lime.log.info("chapterContent: " .. tostring(chapterUrl))
    warmSite()
    local headers = {
        ["User-Agent"]               = BROWSER_HEADERS["User-Agent"],
        ["Accept-Language"]          = BROWSER_HEADERS["Accept-Language"],
        ["Accept"]                   = BROWSER_HEADERS["Accept"],
        ["Accept-Encoding"]          = BROWSER_HEADERS["Accept-Encoding"],
        ["sec-ch-ua"]                = BROWSER_HEADERS["sec-ch-ua"],
        ["sec-ch-ua-mobile"]         = BROWSER_HEADERS["sec-ch-ua-mobile"],
        ["sec-ch-ua-platform"]       = BROWSER_HEADERS["sec-ch-ua-platform"],
        ["Upgrade-Insecure-Requests"] = BROWSER_HEADERS["Upgrade-Insecure-Requests"],
        ["Referer"]                  = BASE .. "/",
        ["Sec-Fetch-Dest"]           = "document",
        ["Sec-Fetch-Mode"]           = "navigate",
        ["Sec-Fetch-Site"]           = "same-origin",
        ["Sec-Fetch-User"]           = "?1",
    }

    local fullUrl = absolutize(chapterUrl)
    local html, err = httpGet(fullUrl, headers)
    if not html then
        lime.log.warn("chapterContent http failed: " .. tostring(err))
        return { code = 500, message = "获取章节页面失败", data = nil }
    end

    local doc = lime.dom.parse(html)
    -- 主内容容器优先 #content,fallback .content
    local contentEl = lime.dom.select(doc, "#content")
    if not contentEl then
        contentEl = lime.dom.select(doc, ".content")
    end
    if not contentEl then
        lime.log.warn("chapterContent: no content element found")
        return { code = 500, message = "正文节点不存在", data = nil }
    end

    -- scraper text() 不输出 script/style 文本,无需 legado.dom.remove
    local rawHtml = lime.dom.html(contentEl)
    local cleaned = cleanChapterContent(rawHtml)

    local paragraphs = splitParagraphs(cleaned)
    if #paragraphs == 0 then
        lime.log.warn("chapterContent: empty after clean")
        return { code = 500, message = "章节内容为空", data = nil }
    end

    local blocks = {}
    for _, para in ipairs(paragraphs) do
        blocks[#blocks + 1] = { type = "txt", content = para }
    end
    lime.log.info("chapterContent: url=" .. tostring(chapterUrl) .. " blocks=" .. #blocks)
    return blocks
end

-- =====================================================================
-- 探索页筛选声明 explore() — 可选
-- 返回 ExploreFilterVO[]:每个 filter 由前端按 type 渲染对应控件
-- =====================================================================

function explore()
    local options = {}
    for _, c in ipairs(CATEGORIES) do
        options[#options + 1] = { field = c.field, label = c.label }
    end
    return {
        {
            field   = "category",
            label   = "分类",
            type    = "single",
            options = options,
        },
    }
end

-- =====================================================================
-- 探索页搜索 exploreSearch(keyword, payload) — 可选
-- payload = { keyword, filters = { [field] = value }, current, size }
-- 返回 ResourceDetailVO[]:与 search() 同结构
-- 站点发现页是分类目录页(/<catId>[/N.html]),关键字不可用,直接忽略
-- =====================================================================

function exploreSearch(keyword, payload)
    warmSite()

    local sortId
    if payload and payload.filters and payload.filters.category then
        sortId = tostring(payload.filters.category)
    else
        sortId = CATEGORIES[1].field -- 默认"玄幻奇幻"
    end

    local page = 1
    if payload and payload.current then
        page = tonumber(payload.current) or 1
    end

    local url = BASE .. "/" .. sortId .. "/"
    if page > 1 then url = BASE .. "/" .. sortId .. "/" .. page .. ".html" end

    lime.log.info("exploreSearch: url=" .. url)

    local headers = {
        ["User-Agent"]               = BROWSER_HEADERS["User-Agent"],
        ["Accept-Language"]          = BROWSER_HEADERS["Accept-Language"],
        ["Accept"]                   = BROWSER_HEADERS["Accept"],
        ["Accept-Encoding"]          = BROWSER_HEADERS["Accept-Encoding"],
        ["sec-ch-ua"]                = BROWSER_HEADERS["sec-ch-ua"],
        ["sec-ch-ua-mobile"]         = BROWSER_HEADERS["sec-ch-ua-mobile"],
        ["sec-ch-ua-platform"]       = BROWSER_HEADERS["sec-ch-ua-platform"],
        ["Upgrade-Insecure-Requests"] = BROWSER_HEADERS["Upgrade-Insecure-Requests"],
        ["Referer"]                  = BASE .. "/",
        ["Sec-Fetch-Dest"]           = "document",
        ["Sec-Fetch-Mode"]           = "navigate",
        ["Sec-Fetch-Site"]           = "same-origin",
        ["Sec-Fetch-User"]           = "?1",
    }

    local html, err = httpGet(url, headers)
    if not html then
        lime.log.warn("exploreSearch http failed: " .. tostring(err))
        return {}
    end

    local doc = lime.dom.parse(html)
    return parseBooks(doc, "", false)
end

-- =====================================================================
-- 冒烟测试 test(content)
-- 取探索页首页验证可达性
-- =====================================================================

function test(content)
    lime.log.info("test: smoke check")
    warmSite()
    local ok, data = pcall(function()
        local headers = {
            ["User-Agent"]               = BROWSER_HEADERS["User-Agent"],
            ["Accept-Language"]          = BROWSER_HEADERS["Accept-Language"],
            ["Accept"]                   = BROWSER_HEADERS["Accept"],
            ["Accept-Encoding"]          = BROWSER_HEADERS["Accept-Encoding"],
            ["sec-ch-ua"]                = BROWSER_HEADERS["sec-ch-ua"],
            ["sec-ch-ua-mobile"]         = BROWSER_HEADERS["sec-ch-ua-mobile"],
            ["sec-ch-ua-platform"]       = BROWSER_HEADERS["sec-ch-ua-platform"],
            ["Upgrade-Insecure-Requests"] = BROWSER_HEADERS["Upgrade-Insecure-Requests"],
            ["Sec-Fetch-Dest"]           = "document",
            ["Sec-Fetch-Mode"]           = "navigate",
            ["Sec-Fetch-Site"]           = "none",
            ["Sec-Fetch-User"]           = "?1",
        }
        return httpGet(BASE .. "/" .. CATEGORIES[1].field .. "/", headers)
    end)

    if not ok then
        return { code = 500, message = "Test failed: " .. tostring(data), data = nil }
    end
    if not data or data == "" then
        return { code = 500, message = "Test failed: empty response", data = nil }
    end
    local message = "奇书网 reachable, " .. #data .. " bytes from explore page"
    return { code = 0, message = message, data = { ok = true, message = message } }
end

-- =====================================================================
-- 统一 Lua ApiResponse 包装:业务入口返回 `{ code, message, data }`。
-- 原实现保留;包装层捕获 Lua error,避免 runtime traceback 直接冒泡到前端。
-- =====================================================================

local function apiOk(data, message)
    return { code = 0, message = message or "ok", data = data }
end

local function apiFail(message, code)
    return { code = code or 500, message = tostring(message or "unknown error"), data = nil }
end

--- 包装任意入口函数:统一返 { code, message, data }
---   1) 原函数已返 { code, message, data } → 原样返回(deqixs.lua 模式)
---   2) 原函数返其它值(数组/字符串/nil) → 包成 success
---   3) pcall 捕获失败 → apiFail
local function safeApi(fn)
    local ok, result = pcall(fn)
    if ok and type(result) == "table" and result.code ~= nil then
        return result
    end
    if ok then return apiOk(result) end
    return apiFail(result, 500)
end

local rawSearch         = search
local rawResourceInfo   = resourceInfo
local rawChapterList    = chapterList
local rawChapterContent = chapterContent
local rawExplore        = explore
local rawExploreSearch  = exploreSearch
local rawTest           = test

function search(keyword, page)
    return safeApi(function() return rawSearch(keyword, page) end)
end

function resourceInfo(bookUrl)
    return safeApi(function() return rawResourceInfo(bookUrl) end)
end

function chapterList(bookUrl)
    return safeApi(function() return rawChapterList(bookUrl) end)
end

function chapterContent(chapterUrl)
    return safeApi(function() return rawChapterContent(chapterUrl) end)
end

function explore()
    return safeApi(function() return rawExplore() end)
end

function exploreSearch(keyword, payload)
    return safeApi(function() return rawExploreSearch(keyword, payload) end)
end

function test(content)
    return safeApi(function() return rawTest(content) end)
end
