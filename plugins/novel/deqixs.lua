--[[
    @name            得奇小说网
    @package         com.meinil.lime.ai.deqixs
    @content         novel
    @author          Ai
    @logo            https://www.deqixs.cc/favicon.ico
    @url             https://www.deqixs.cc
    @sourceUrl       https://raw.githubusercontent.com/Meinil/test/refs/heads/main/plugins/novel/deqixs.lua
    @version         0.0.1
    @description     得奇小说网
]]

-- =====================================================================
-- 配置
-- =====================================================================
local BASE = "https://www.deqixs.cc"
-- 东八区(秒),与 alicesw.lua 一致
local TZ_OFFSET = 8 * 60 * 60

-- 通用 HTTP 头(Edge 149 真实浏览器指纹,deq server 验证 UA ↔ sec-ch-ua 品牌一致性)。
-- 1.0.10 简化:只留必要字段(UA / sec-ch-ua / sec-ch-ua-platform / Accept-Language / Accept-Encoding),
-- 其它 per-step 头在各 step 的 headers 表里单独设置。
-- 之前的 jitter / 频率限制猜测全部作废(curl 实测 .cc 域名无任何反爬)。
local BROWSER_HEADERS = {
    ["User-Agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36 Edg/149.0.0.0",
    ["Accept-Language"] = "zh-CN,zh;q=0.9",
    ["Accept-Encoding"] = "gzip, deflate, br, zstd",
    ["sec-ch-ua"] = '"Microsoft Edge";v="149", "Chromium";v="149", "Not)A;Brand";v="24"',
    ["sec-ch-ua-platform"] = '"macOS"',
}

-- 探索页分类(同时是 explore() 的 options 数据源)
-- field = URL sortId,label = 显示文案
local CATEGORIES = {
    { field = "0",  label = "全部" },
    { field = "1",  label = "玄幻" },
    { field = "2",  label = "都市" },
    { field = "3",  label = "仙侠" },
    { field = "4",  label = "历史" },
    { field = "5",  label = "科幻" },
    { field = "6",  label = "诸天" },
    { field = "7",  label = "悬疑" },
    { field = "8",  label = "体育" },
    { field = "9",  label = "游戏" },
    { field = "10", label = "综合" },
}

-- 章节列表中需要过滤的"按钮式"链接名(非真实章节)
local CHAPTER_BLACKLIST = {
    ["开始阅读"] = true,
    ["加入书架"] = true,
    ["推荐本书"] = true,
    ["TXT下载"] = true,
}

-- =====================================================================
-- 工具:字符串处理
-- =====================================================================

--- 去除首尾空白(含全角空格 U+3000 / 不间断空格 U+00A0)
local function trim(s)
    if not s or s == "" then return "" end
    -- ASCII 空白(%s = space / tab / \n / \r / \v / \f)
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    -- U+3000 (3 字节 UTF-8: 0xE3 0x80 0x80)
    s = s:gsub("^\227\128\128+", ""):gsub("\227\128\128+$", "")
    -- U+00A0 (2 字节 UTF-8: 0xC2 0xA0)
    s = s:gsub("^\194\160+", ""):gsub("\194\160+$", "")
    return s
end

--- 把可能的相对 URL 拼成绝对 URL
local function absolutize(url, base)
    if not url or url == "" then return url end
    if url:sub(1, 4) == "http" then return url end
    return base .. url
end

--- 从绝对 URL 中取 origin,避免章节 URL 与 token/api 请求跨域。
local function originOf(url)
    if not url then return BASE end
    return url:match("^(https?://[^/]+)") or BASE
end

--- 章节 URL 末尾 /(\d+).html 提取数字 id
local function extractChapterId(url)
    if not url then return 0 end
    local id = url:match(".*/(%d+)%.html")
    return tonumber(id) or 0
end

-- =====================================================================
-- 工具:DOM 包装(我们的 lime.dom 只有 select/text/attr,没有 selectText/selectAttr)
-- =====================================================================

--- legado.dom.selectText 的等价物:取首个匹配元素的 text(无匹配空字符串)
local function selectText(doc, sel)
    local el = lime.dom.select(doc, sel)
    if not el then return "" end
    local t = lime.dom.text(el)
    return t or ""
end

--- legado.dom.selectAttr 的等价物:取首个匹配元素的 attr(无匹配 nil)
local function selectAttr(doc, sel, key)
    local el = lime.dom.select(doc, sel)
    if not el then return nil end
    return lime.dom.attr(el, key)
end

-- lime.dom.select / selectAll 只接受 DomDocument,不能从 element 子树内查询。
-- 把 element 的 outerHTML 重新 parse 成 sub-doc 再 select,即可在 element 子树内做后代选择器。
local function selectIn(itemEl, sel)
    return lime.dom.select(lime.dom.parse(lime.dom.html(itemEl)), sel)
end

local function selectAllIn(itemEl, sel)
    return lime.dom.selectAll(lime.dom.parse(lime.dom.html(itemEl)), sel)
end

-- =====================================================================
-- 工具:HTTP + JSON 容错
-- =====================================================================

--- GET 包装,失败 throw error;成功返 body
local function httpGet(url, headers)
    local response = lime.http.get(url, headers)
    if response.status < 200 or response.status >= 300 then
        error("lime.http.get: HTTP " .. tostring(response.status))
    end
    return response.body
end

--- POST 包装,失败 throw error;成功返 body
local function httpPost(url, body, headers)
    local response = lime.http.post(url, body, headers)
    if response.status < 200 or response.status >= 300 then
        error("lime.http.post: HTTP " .. tostring(response.status))
    end
    return response.body
end

--- JSON 解码,失败返 nil + err(JSON 解析失败用 pcall 兜)
local function safeJsonDecode(s)
    if not s or s == "" then return nil, "empty response" end
    local ok, data = pcall(lime.json.decode, s)
    if not ok then return nil, tostring(data) end
    if type(data) ~= "table" then return nil, "json decode result is not table" end
    return data, nil
end

-- =====================================================================
-- 工具:章节正文 HTML 清理
-- =====================================================================

--- 把服务端返回的 HTML 片段(包含 <br> + HTML 实体)清理为纯文本
local function cleanChapterContent(s)
    if not s or s == "" then return "" end
    -- Rust 的 String::from_utf8_lossy(在 value_to_json 中)会把非法 UTF-8
    -- 字节替换为 U+FFFD (UTF-8: \227\191\189)。
    -- 2 步清理(不能直接用 \227\191\189+ —— Lua 模式 + 限定符只对单字节生效):
    --   1) 全部替为单个空格(保词边界,优于直接删除)
    --   2) 折叠连续空格为 1 个(避免 "a   b")
    s = s:gsub("\227\191\189", " ")
    s = s:gsub(" +", " ")
    s = s
        :gsub("<br ?/?>", "\n")         -- <br> / <br/> / <br />
        :gsub("<[^>]+>", "")            -- 残留标签
        :gsub("&emsp;", "    ")
        :gsub("&nbsp;", " ")
        :gsub("&amp;", "&")
        :gsub("&lt;", "<")
        :gsub("&gt;", ">")
        :gsub("&quot;", '"')
        :gsub("&#39;", "'")
        :gsub("\n{3,}", "\n\n")        -- 折叠空行
    -- 零宽字符清除:每个多字节序列独立 gsub,**不能用字符类 [],
    -- 因为 Lua 字符类按字节匹配,会把"你"="E4 BD A0"中间的
    -- 0xBD 当成独立字节删掉(同一个坑 U+FFFD 也是)
    s = s:gsub("\226\128\139", "")    -- U+200B
        :gsub("\226\128\140", "")    -- U+200C
        :gsub("\226\128\141", "")    -- U+200D
        :gsub("\239\191\191", "")    -- U+FEFF
    return trim(s)
end

--- 判断一行是否是"章节名行",即以 `第` 起头 + (汉字/阿拉伯数字) + `章` 开头。
--- 形如:
---   "第1章 楔子 一块黑布"
---   "第一章 楔子"
---   "第 1 章 楔子"
---   "第十章 楔子"
---
--- **仅在 chapterContent 切段落后的首段使用** — 避免误伤正文中的对话行
--- (如人物对话里说"第一章"作为台词),用调用方控制调用时机。
---
--- 长度上限 50 字符:章节名行通常较短(< 50),正文首段一般较长,
--- 双重保险避免把小说第一段误判。
local function isChapterTitleLine(s)
    if not s or s == "" then return false end
    -- 长度上限
    if #s > 50 then return false end
    -- 模式:可选空格 + "第" + 可选空格 + (一|二|三|四|五|六|七|八|九|十|百|千|两|半|\d+) + 可选空格 + "章"
    -- 注意 Lua 模式不支持 \d,显式列 0-9
    return s:match("^%s*第%s*[一二三四五六七八九十百千两半0-9]+%s*章") ~= nil
end

-- =====================================================================
-- 工具:数据映射(输出 ResourceDetailVO 字段)
-- =====================================================================

--- 封面 URL:从书籍 URL 提取 articleId 拼图床路径(无 articleId 返回空)
local function buildCoverUrl(bookUrl)
    local id = bookUrl and bookUrl:match("/books/(%d+)/")
    if id then
        return BASE .. "/files/article/image/0/" .. id .. "/" .. id .. "s.jpg"
    end
    return ""
end

--- 从页面提取字数:优先 DOM(span.blue 内 script),回退到原始 HTML 正则
--- towan('数字') 返回单位为"个",直接转换为数字,不乘 10000
local function extractWordCount(doc, html)
    local blueSpans = lime.dom.selectAll(doc, "span.blue")
    for _, span in ipairs(blueSpans) do
        local spanText = lime.dom.text(span) or ""
        local numMatch = spanText:match("towan%('(%d+)'%)")
        if numMatch then
            return tonumber(numMatch) or 0
        end
    end
    local numMatch = html:match("towan%('(%d+)'%)")
    if numMatch then
        return tonumber(numMatch) or 0
    end
    return 0
end

--- 通用 BookItem 构造器(对应 ResourceDetailVO,必填 name/author/url)
local function buildBookItem(name, author, bookUrl, coverImageUrl, lastChapter, opts)
    opts = opts or {}
    return {
        name              = trim(name),
        author            = trim(author or ""),
        url               = bookUrl,
        cover             = coverImageUrl and coverImageUrl ~= "" and { url = coverImageUrl } or nil,
        intro             = "",
        wordCount         = opts.wordCount or 0,
        latestChapter     = trim(lastChapter or ""),
        chapterCount      = opts.chapterCount or 0,
        latestChapterUrl  = opts.latestChapterUrl or "",
        tags              = opts.tags or {},
    }
end

-- =====================================================================
-- 搜索 search(keyword, page)
-- =====================================================================
function search(keyword, page)
    lime.log.info("searching: " .. tostring(keyword))
    local headers = {
        ["User-Agent"] = BROWSER_HEADERS["User-Agent"],
        ["Accept-Language"] = BROWSER_HEADERS["Accept-Language"],
        ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
        ["Accept-Encoding"] = BROWSER_HEADERS["Accept-Encoding"],
        ["sec-ch-ua"] = BROWSER_HEADERS["sec-ch-ua"],
        ["sec-ch-ua-platform"] = BROWSER_HEADERS["sec-ch-ua-platform"],
        ["Content-Type"] = "application/x-www-form-urlencoded",
        ["Origin"] = BASE,
        ["Referer"] = BASE .. "/",
        ["Sec-Fetch-Dest"] = "empty",
        ["Sec-Fetch-Mode"] = "cors",
        ["Sec-Fetch-Site"] = "same-origin",
    }
    local body = "searchkey=" .. lime.crypto.urlEncode(tostring(keyword or ""))
        .. "&action=search&searchtype=articlename"
    local html = httpPost(BASE .. "/modules/article/search.php", body, headers)

    local doc = lime.dom.parse(html)

    -- 单本结果优先(og: meta)
    local ogTitle = selectAttr(doc, 'meta[property="og:novel:book_name"]', "content")
    local ogUrl = selectAttr(doc, 'meta[property="og:novel:read_url"]', "content")
    local ogAuthor = selectAttr(doc, 'meta[property="og:novel:author"]', "content")
    local ogCover = selectAttr(doc, 'meta[property="og:image"]', "content")
    local ogLatest = selectAttr(doc, 'meta[property="og:novel:latest_chapter_name"]', "content")
    local ogLatestUrl = selectAttr(doc, 'meta[property="og:novel:latest_chapter_url"]', "content")
    local ogCategory = selectAttr(doc, 'meta[property="og:novel:category"]', "content")

    -- 字数:从 span.blue 内的 script 标签提取 towan('数字')
    local wordCount = extractWordCount(doc, html)

    -- 章节数:数 dl.chapterlist a 数量(同 chapterList 的 selector)
    -- 详情页无完整目录时返 0,library.rs 入库时按 chapterList 实际数量回填
    local chapterLinks = lime.dom.selectAll(doc, "dl.chapterlist a")
    local chapterCount = chapterLinks and #chapterLinks or 0

    if ogTitle and ogUrl and ogUrl ~= "" then
        local item = buildBookItem(ogTitle, ogAuthor, ogUrl, ogCover, ogLatest, {
            wordCount = wordCount,
            chapterCount = chapterCount,
            latestChapterUrl = ogLatestUrl or "",
            tags = ogCategory and { ogCategory } or {},
        })
        return { item }
    end

    -- 列表结果
    local items = lime.dom.selectAll(doc, "div.bookbox")
    if not items or #items == 0 then
        return {}
    end

    local results = {}
    for _, itemEl in ipairs(items) do
        local titleEl = selectIn(itemEl, "h4.bookname a")
        local title = titleEl and lime.dom.text(titleEl) or ""
        local url = titleEl and lime.dom.attr(titleEl, "href") or ""
        if title == "" or url == "" then goto continue end
        url = absolutize(url, BASE)

        local authorEls = selectAllIn(itemEl, "div.author")
        local author = ""
        for _, ae in ipairs(authorEls) do
            local at = lime.dom.text(ae) or ""
            if at:sub(1, 4) == "作者：" then
                author = at:sub(5)
                break
            end
        end

        local lastChapterEl = selectIn(itemEl, "div.cat a")
        local lastChapter = lastChapterEl and lime.dom.text(lastChapterEl) or ""

        results[#results + 1] = buildBookItem(title, author, url, buildCoverUrl(url), lastChapter)
        ::continue::
    end
    return results
end

-- =====================================================================
-- 资源详情 resourceInfo(bookUrl)
-- =====================================================================
function resourceInfo(bookUrl)
    lime.log.info("bookInfo: " .. tostring(bookUrl))
    local headers = {
        ["User-Agent"] = BROWSER_HEADERS["User-Agent"],
        ["Accept-Language"] = BROWSER_HEADERS["Accept-Language"],
        ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
        ["Accept-Encoding"] = BROWSER_HEADERS["Accept-Encoding"],
        ["sec-ch-ua"] = BROWSER_HEADERS["sec-ch-ua"],
        ["sec-ch-ua-platform"] = BROWSER_HEADERS["sec-ch-ua-platform"],
        ["Upgrade-Insecure-Requests"] = "1",
        ["Referer"] = BASE .. "/",
        ["Sec-Fetch-Dest"] = "document",
        ["Sec-Fetch-Mode"] = "navigate",
        ["Sec-Fetch-Site"] = "same-origin",
        ["Sec-Fetch-User"] = "?1",
    }
    local html = httpGet(bookUrl, headers)

    local doc = lime.dom.parse(html)

    local title = selectText(doc, "h1.booktitle")
    local authorEl = lime.dom.select(doc, 'a.red[title^="作者"]')
    local authorRaw = authorEl and lime.dom.attr(authorEl, "title") or ""
    local author = authorRaw:gsub("作者：", "")
    local coverImageUrl = selectAttr(doc, "img.thumbnail", "src") or ""

    -- 简介(scraper text() 不含属性,无需 legado.dom.remove)
    local intro = selectText(doc, "p.bookintro")

    local kind = selectText(doc, "ol.breadcrumb li:nth-child(2) a")
    local statusEls = lime.dom.selectAll(doc, "span.red")
    local status = ""
    if statusEls and statusEls[1] then
        status = lime.dom.text(statusEls[1])
    end

    local lastChapterEl = lime.dom.select(doc, "a.bookchapter")
    local lastChapter = lastChapterEl and lime.dom.text(lastChapterEl) or ""
    local lastChapterUrl = lastChapterEl and lime.dom.attr(lastChapterEl, "href") or ""

    local latestUpdateTimeEl = lime.dom.select(doc, "p.booktime")
    local latestUpdateTime
    if latestUpdateTimeEl then
        local text = trim(lime.dom.text(latestUpdateTimeEl) or "")
        lime.log.info("text", text)
        if text ~= "" then
            local ts, err = lime.time.parse_offset("更新时间：YYYY-MM-dd HH:mm", text, TZ_OFFSET)
            if ts then
                latestUpdateTime = ts
            else
                lime.log.warn("deqixs time parse failed: " .. text .. " " .. tostring(err))
            end
        end
    end
    lime.log.info("latestUpdateTime", latestUpdateTime)

    -- 字数:从 span.blue 内的 script 标签提取 towan('数字')
    local wordCount = extractWordCount(doc, html)

    -- 章节数:数 dl.chapterlist a 数量(同 chapterList 的 selector)
    -- 详情页无完整目录时返 0,library.rs 入库时按 chapterList 实际数量回填
    local chapterLinks = lime.dom.selectAll(doc, "dl.chapterlist a")
    local chapterCount = chapterLinks and #chapterLinks or 0

    -- tags:kind 和 status 作为标签
    local tags = {}
    if trim(kind) ~= "" then
        tags[#tags + 1] = trim(kind)
    end
    if trim(status) ~= "" then
        tags[#tags + 1] = trim(status)
    end

    lime.log.info("chapterCount: " .. tostring(chapterCount))
    return {
        name              = trim(title),
        author            = trim(author),
        url               = bookUrl,
        cover             = coverImageUrl ~= "" and { url = coverImageUrl } or nil,
        intro             = trim(intro),
        wordCount         = wordCount,
        latestChapter     = trim(lastChapter),
        chapterCount      = chapterCount,
        latestChapterUrl  = lastChapterUrl,
        latestUpdateTime  = latestUpdateTime,
        tags              = tags,
        kind              = trim(kind) ~= "" and trim(kind) or (trim(status) ~= "" and trim(status) or "小说"),
        tocUrl            = bookUrl,
    }
end

-- =====================================================================
-- 章节列表 chapterList(bookUrl)
-- =====================================================================
function chapterList(bookUrl)
    lime.log.info("chapterList: " .. tostring(bookUrl))
    local headers = {
        ["User-Agent"] = BROWSER_HEADERS["User-Agent"],
        ["Accept-Language"] = BROWSER_HEADERS["Accept-Language"],
        ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
        ["Accept-Encoding"] = BROWSER_HEADERS["Accept-Encoding"],
        ["sec-ch-ua"] = BROWSER_HEADERS["sec-ch-ua"],
        ["sec-ch-ua-platform"] = BROWSER_HEADERS["sec-ch-ua-platform"],
        ["Upgrade-Insecure-Requests"] = "1",
        ["Referer"] = BASE .. "/",
        ["Sec-Fetch-Dest"] = "document",
        ["Sec-Fetch-Mode"] = "navigate",
        ["Sec-Fetch-Site"] = "same-origin",
        ["Sec-Fetch-User"] = "?1",
    }
    local html = httpGet(bookUrl, headers)

    local doc = lime.dom.parse(html)
    local links = lime.dom.selectAll(doc, "dl.chapterlist a")

    local chapters = {}
    local seen = {}
    for _, linkEl in ipairs(links) do
        local url = lime.dom.attr(linkEl, "href")
        local name = lime.dom.text(linkEl)
        if not url or url:sub(1, 10) == "javascript" then goto continue end
        url = absolutize(url, BASE)
        if seen[url] then goto continue end
        local nameTrim = trim(name)
        if CHAPTER_BLACKLIST[nameTrim] then goto continue end
        seen[url] = true
        chapters[#chapters + 1] = {
            name  = nameTrim,
            url   = url,
            index = extractChapterId(url),
        }
        ::continue::
    end

    table.sort(chapters, function(a, b)
        return a.index < b.index
    end)

    for i, c in ipairs(chapters) do
        c.index = i
    end

    return chapters
end

-- =====================================================================
-- 章节正文 chapterContent(chapterUrl)
-- 三步反爬流程:拉页 → 拿 token → 调 API
-- 返回值是 `ChapterBlock[]` 数组(见 Plugin.md §2 / chapterContent 契约):
--   { id = "text-1", type = "text", text = "正文..." }
--   { id = "image-1", type = "image", source = { id = "image-source-1", url = "https://...", headers = { ... } } }
-- 错误处理返回非 0 code,后端把 message 写入失败链路。
-- =====================================================================
function chapterContent(request)
    local chapterUrl = request.chapter.url
    local chapterBase = originOf(chapterUrl)

    -- 解析 URL 中的 articleId / chapterId
    local articleId, chapterId
    local parts = {}
    for part in chapterUrl:gmatch("[^/]+") do parts[#parts + 1] = part end
    for i, part in ipairs(parts) do
        if part == "books" and parts[i + 1] then
            articleId = parts[i + 1]
        end
    end
    local cidMatch = chapterUrl:match("/(%d+)%.html")
    if cidMatch then chapterId = cidMatch end

    if not articleId or not chapterId then
        error("解析章节ID失败")
    end

    local pageHeaders = {
        ["User-Agent"] = BROWSER_HEADERS["User-Agent"],
        ["Accept-Language"] = BROWSER_HEADERS["Accept-Language"],
        ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
        ["Accept-Encoding"] = BROWSER_HEADERS["Accept-Encoding"],
        ["sec-ch-ua"] = BROWSER_HEADERS["sec-ch-ua"],
        ["sec-ch-ua-platform"] = BROWSER_HEADERS["sec-ch-ua-platform"],
        ["Upgrade-Insecure-Requests"] = "1",
        ["Sec-Fetch-Dest"] = "document",
        ["Sec-Fetch-Mode"] = "navigate",
        ["Sec-Fetch-Site"] = "same-origin",
        ["Sec-Fetch-User"] = "?1",
        ["Referer"] = chapterBase .. "/",
    }
    httpGet(chapterUrl, pageHeaders)

    -- 第 2 步:取 token / timestamp / nonce
    local tokenUrl = chapterBase .. "/scripts/chapter.js.php?aid=" .. articleId
        .. "&cid=" .. chapterId
        .. "&referrer=" .. lime.crypto.urlEncode(chapterUrl)
    local tokenHeaders = {
        ["User-Agent"] = BROWSER_HEADERS["User-Agent"],
        ["Accept-Language"] = BROWSER_HEADERS["Accept-Language"],
        ["Accept"] = "*/*",
        ["Accept-Encoding"] = BROWSER_HEADERS["Accept-Encoding"],
        ["sec-ch-ua"] = BROWSER_HEADERS["sec-ch-ua"],
        ["sec-ch-ua-platform"] = BROWSER_HEADERS["sec-ch-ua-platform"],
        ["Sec-Fetch-Dest"] = "script",
        ["Sec-Fetch-Mode"] = "no-cors",
        ["Sec-Fetch-Site"] = "same-origin",
        ["Referer"] = chapterUrl,
    }
    local tokenHtml = httpGet(tokenUrl, tokenHeaders)

    local token = tokenHtml:match("var chapterToken = '([^']+)'")
    local timestamp = tokenHtml:match("var timestamp = (%d+)")
    local nonce = tokenHtml:match("var nonce = '([^']+)'")
    if not token or not timestamp or not nonce then
        error("获取章节Token失败")
    end

    -- 第 3 步:调 API
    local apiUrl = chapterBase .. "/modules/article/ajax2.php?aid=" .. articleId
        .. "&cid=" .. chapterId
        .. "&token=" .. token
        .. "&timestamp=" .. timestamp
        .. "&nonce=" .. nonce
    local apiHeaders = {
        ["User-Agent"] = BROWSER_HEADERS["User-Agent"],
        ["Accept-Language"] = BROWSER_HEADERS["Accept-Language"],
        ["Accept"] = "application/json, text/javascript, */*; q=0.01",
        ["Accept-Encoding"] = BROWSER_HEADERS["Accept-Encoding"],
        ["sec-ch-ua"] = BROWSER_HEADERS["sec-ch-ua"],
        ["sec-ch-ua-platform"] = BROWSER_HEADERS["sec-ch-ua-platform"],
        ["Origin"] = chapterBase,
        ["Referer"] = chapterUrl,
        ["X-Requested-With"] = "XMLHttpRequest",
        ["Sec-Fetch-Dest"] = "empty",
        ["Sec-Fetch-Mode"] = "cors",
        ["Sec-Fetch-Site"] = "same-origin",
    }
    local apiResponse = httpGet(apiUrl, apiHeaders)

    local data, err4 = safeJsonDecode(apiResponse)
    if not data then
        error("解析章节内容失败: " .. tostring(err4))
    end
    if data and data.status == 1 and data.data and data.data.content then
        -- 契约:返回 ChapterBlock[];txt 块按"段落"拆分,
        -- 前端每个 block 对应一个 scroller item(不再二次切分)。
        -- 空段过滤,避免空白占位。
        local cleaned = cleanChapterContent(data.data.content)
        local blocks = {}
        for para in cleaned:gmatch("[^\r\n]+") do
            para = trim(para)
            if para ~= "" then
                -- 过滤:服务端常把章节名作为正文第一段嵌入(例:"第1章 楔子 一块黑布"),
                -- 章节列表已有 name 字段,正文里再去一遍既冗余又占虚拟列表项。
                -- 仅在"首段"做一次检测,避免误伤正文里的对话行("第一章" 在引文里)
                if #blocks == 0 and isChapterTitleLine(para) then
                    goto continue
                end
                table.insert(blocks, {
                    id = "text-" .. tostring(#blocks + 1),
                    type = "text",
                    text = para,
                })
            end
            ::continue::
        end
        -- 整章无任何非空段落 → 抛错,由后端降级 status=2
        if #blocks == 0 then
            error("章节内容为空")
        end
        return { blocks = blocks }
    end

    local msg = "获取章节内容失败"
    if data and data.message then
        msg = msg .. ": " .. tostring(data.message)
    end
    lime.log.warn(msg)
    error(msg)
end

-- =====================================================================
-- 探索页筛选声明 explore() — 可选
-- 返回 ExploreFilterVO[]:每个 filter 由前端按 type 渲染对应控件
-- (single → shadcn Select / multiple → Checkbox / cascade → 树)
-- =====================================================================
function explore()
    -- 直接复用 CATEGORIES 列表展开成 options
    local options = {}
    for _, c in ipairs(CATEGORIES) do
        options[#options + 1] = { field = c.field, label = c.label }
    end
    return {
        {
            field = "category",
            label = "分类",
            type = "single",
            default = "0",
            options = options,
        },
    }
end

-- =====================================================================
-- 探索页搜索 exploreSearch(keyword, payload) — 可选
-- payload = { keyword, filters = { [field] = value }, current }
-- 返回 { records = ResourceDetailVO[], total? }
-- content 字段可选;前端 fallback 链:book.content ?? plugin.content ?? 'novel'
-- =====================================================================
function exploreSearch(keyword, payload)
    local sortId = "0"
    if payload and payload.filters and payload.filters.category then
        sortId = tostring(payload.filters.category)
    end

    local page = 1
    if payload and payload.current then
        page = tonumber(payload.current) or 1
    end

    -- keyword:本插件发现页不参与关键字过滤(网站 /sort/ 不支持),直接忽略

    local url = BASE .. "/sort/" .. sortId .. "/" .. page .. ".html"
    lime.log.info("exploreSearch: url=" .. url)

    local headers = {
        ["User-Agent"] = BROWSER_HEADERS["User-Agent"],
        ["Accept-Language"] = BROWSER_HEADERS["Accept-Language"],
        ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
        ["Accept-Encoding"] = BROWSER_HEADERS["Accept-Encoding"],
        ["sec-ch-ua"] = BROWSER_HEADERS["sec-ch-ua"],
        ["sec-ch-ua-platform"] = BROWSER_HEADERS["sec-ch-ua-platform"],
        ["Upgrade-Insecure-Requests"] = "1",
        ["Referer"] = BASE .. "/",
        ["Sec-Fetch-Dest"] = "document",
        ["Sec-Fetch-Mode"] = "navigate",
        ["Sec-Fetch-Site"] = "same-origin",
        ["Sec-Fetch-User"] = "?1",
    }
    local html = httpGet(url, headers)

    local doc = lime.dom.parse(html)
    local items = lime.dom.selectAll(doc, "div.bookbox")
    if not items or #items == 0 then
        return { records = {} }
    end

    local results = {}
    for _, itemEl in ipairs(items) do
        local titleEl = selectIn(itemEl, "h4.bookname a")
        local title = titleEl and lime.dom.text(titleEl) or ""
        local bUrl = titleEl and lime.dom.attr(titleEl, "href") or ""
        if title == "" or bUrl == "" then goto continue end
        bUrl = absolutize(bUrl, BASE)

        local author = ""
        local authorEls = selectAllIn(itemEl, "div.author")
        for _, ae in ipairs(authorEls) do
            local at = lime.dom.text(ae)
            if at:sub(1, 4) == "作者：" then
                author = at:sub(5)
                break
            end
        end

        local lastChapterEl = selectIn(itemEl, "div.cat a")
        local lastChapter = lastChapterEl and lime.dom.text(lastChapterEl) or ""

        results[#results + 1] = buildBookItem(title, author, bUrl, buildCoverUrl(bUrl), lastChapter)
        ::continue::
    end

    if #results == 0 then
        return { records = {} }
    end
    return { records = results }
end

-- =====================================================================
-- 冒烟测试 test(content)
-- 简单 connectivity check:取探索页第一页,验证站点可达
-- =====================================================================
function test(content)
    local headers = {
        ["User-Agent"] = BROWSER_HEADERS["User-Agent"],
        ["Accept-Language"] = BROWSER_HEADERS["Accept-Language"],
        ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
        ["Accept-Encoding"] = BROWSER_HEADERS["Accept-Encoding"],
        ["sec-ch-ua"] = BROWSER_HEADERS["sec-ch-ua"],
        ["sec-ch-ua-platform"] = BROWSER_HEADERS["sec-ch-ua-platform"],
        ["Upgrade-Insecure-Requests"] = "1",
        ["Sec-Fetch-Dest"] = "document",
        ["Sec-Fetch-Mode"] = "navigate",
        ["Sec-Fetch-Site"] = "none",
        ["Sec-Fetch-User"] = "?1",
    }
    local data = httpGet(BASE .. "/sort/0/1.html", headers)
    if not data or data == "" then
        error("Test failed: empty response")
    end
    local message = "得奇小说网 reachable, " .. #data .. " bytes from explore"
    return { ok = true, message = message }
end

-- 顶层入口函数已直接定义在 globals(每个 raw 函数即顶层入口)。
-- 成功:返回裸数据(array/object/string)
-- 失败:throw error 字符串
-- backend runner::invoke 接 mlua::Error → PluginRuntimeError → ApiResponse::error(1101, msg)
-- decode_lua_response 把裸数据视为 success data(原契约)
