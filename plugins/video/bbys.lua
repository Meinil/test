local API_BASE = "https://www.freeokk.pro"
local API = API_BASE .. "/api.php/provide/vod/"
local UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
local DEFAULT_ROUTE = "bfzym3u8"
local PENDING_BROWSER_REQUEST_KEY = "browser:pending_request"
local AVAILABLE_ROUTES_KEY = "playback:available_routes"
local CATEGORIES = {
    { field = "1", label = "电影" },
    { field = "2", label = "剧集" },
    { field = "3", label = "综艺" },
    { field = "4", label = "动漫" },
}
local ROUTES = {
    { value = "ffm3u8", label = "非凡" },
    { value = "rym3u8", label = "如意" },
    { value = "bfzym3u8", label = "暴风" },
    { value = "dyttm3u8", label = "电影天堂" },
    { value = "youku", label = "优酷" },
    { value = "qiyi", label = "爱奇艺" },
    { value = "1080zyk", label = "1080资源" },
}
local HEADERS = {
    ["User-Agent"] = UA,
    ["Accept"] = "application/json,text/plain,*/*",
    ["Referer"] = API_BASE .. "/",
}

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function urlEncode(value)
    local encoded = lime.crypto.urlEncode(tostring(value or ""))
    return encoded or ""
end

local function htmlDecode(value)
    return tostring(value or "")
        :gsub("&#x([%da-fA-F]+);", function(hex) return utf8.char(tonumber(hex, 16)) end)
        :gsub("&#(%d+);", function(decimal) return utf8.char(tonumber(decimal, 10)) end)
        :gsub("&nbsp;", " ")
        :gsub("&amp;", "&")
        :gsub("&quot;", '"')
        :gsub("&#39;", "'")
        :gsub("&lt;", "<")
        :gsub("&gt;", ">")
end

local function cleanText(value)
    local text = tostring(value or "")
        :gsub("<script.-</script>", " ")
        :gsub("<style.-</style>", " ")
        :gsub("<[^>]+>", " ")
        :gsub("%s+", " ")
    return trim(htmlDecode(text))
end

local function splitTags(value)
    local tags = {}
    local normalized = tostring(value or ""):gsub("，", ",")
    for item in normalized:gmatch("[^,]+") do
        local tag = cleanText(item)
        if tag ~= "" then tags[#tags + 1] = tag end
    end
    return tags
end

local function parseVodTime(value)
    local raw = trim(value)
    if raw == "" then return nil end
    local numeric = tonumber(raw)
    if numeric then
        if numeric > 20000000000 then numeric = numeric / 1000 end
        return math.floor(numeric)
    end
    for _, format in ipairs({ "YYYY-MM-dd HH:mm:ss", "YYYY-MM-dd HH:mm", "YYYY-MM-dd" }) do
        local timestamp = lime.time.parse(format, raw)
        if timestamp then return timestamp end
    end
    return nil
end

local function absoluteUrl(value)
    local url = trim(value)
    if url == "" then return "" end
    if url:match("^https?://") then return url end
    if url:match("^//") then return "https:" .. url end
    if url:sub(1, 1) == "/" then return API_BASE .. url end
    return API_BASE .. "/" .. url
end

local function apiUrl(query)
    return API .. "?" .. query
end

-- MacCMS 偶尔在 JSON 字符串中返回原始控制字符，先按字节修复再解码。
local function parseJsonLoose(text)
    local raw = trim(tostring(text or ""):gsub("^\239\187\191", ""))

    local output, inString, escaped = {}, false, false
    for index = 1, #raw do
        local byte = raw:byte(index)
        local char = raw:sub(index, index)
        if inString then
            if escaped then
                output[#output + 1], escaped = char, false
            elseif char == "\\" then
                output[#output + 1], escaped = char, true
            elseif char == '"' then
                output[#output + 1], inString = char, false
            elseif byte == 10 then
                output[#output + 1] = "\\n"
            elseif byte == 13 then
                output[#output + 1] = "\\r"
            elseif byte == 9 then
                output[#output + 1] = "\\t"
            else
                output[#output + 1] = char
            end
        else
            output[#output + 1] = char
            if char == '"' then inString = true end
        end
    end
    local result = lime.json.decode(table.concat(output))
    if type(result) ~= "table" then
        error({ code = 2007, message = "布布影视响应格式无效" })
    end
    return result
end

-- Cloudflare Managed Challenge 不能由普通 HTTP 客户端执行，交给宿主认证 WebView。
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
            { scheme = "https", host = "freeokk.pro", includeSubdomains = true },
        },
        completion = {
            mode = "any",
            cookieNames = { "cf_clearance" },
        },
        request = {
            method = "GET",
            url = url,
            headers = {
                ["Accept"] = "application/json,text/plain,*/*",
            },
        },
    }
end

local function openBrowserChallenge(url)
    return lime.browser.open(browserChallengeOptions(url))
end

local function getJson(url)
    if trim(lime.storage.get(PENDING_BROWSER_REQUEST_KEY)) == url then
        local replay = openBrowserChallenge(url)
        lime.storage.remove(PENDING_BROWSER_REQUEST_KEY)
        if replay.status < 200 or replay.status >= 300 then
            error({ code = 2006, message = "布布影视浏览器请求失败: HTTP " .. tostring(replay.status) })
        end
        return parseJsonLoose(replay.body)
    end

    local response = lime.http.get(url, HEADERS)
    if requiresBrowserAuth(response) then
        lime.storage.set(PENDING_BROWSER_REQUEST_KEY, url)
        response = openBrowserChallenge(url)
        lime.storage.remove(PENDING_BROWSER_REQUEST_KEY)
    end
    if response.status < 200 or response.status >= 300 then
        error({ code = 2006, message = "布布影视请求失败: HTTP " .. tostring(response.status) })
    end
    return parseJsonLoose(response.body)
end

local function listOf(payload)
    if type(payload) ~= "table" then return {} end
    if type(payload.list) == "table" then return payload.list end
    if type(payload.data) == "table" and type(payload.data.list) == "table" then return payload.data.list end
    if type(payload.data) == "table" then return payload.data end
    return {}
end

local function firstVod(payload)
    return listOf(payload)[1]
end

local function resourceOf(vod)
    vod = vod or {}
    local id = vod.vod_id or vod.id
    local name = cleanText(vod.vod_name or vod.name or vod.title)
    if not id or name == "" then return nil end
    local detail = apiUrl("ac=detail&ids=" .. urlEncode(id))
    local coverUrl = absoluteUrl(vod.vod_pic or vod.pic or vod.cover)
    return {
        name = name,
        author = cleanText(vod.vod_director or vod.vod_author),
        url = detail,
        cover = coverUrl ~= "" and { url = coverUrl, headers = HEADERS } or nil,
        intro = cleanText(vod.vod_blurb or vod.vod_content or vod.vod_sub),
        latestChapter = cleanText(vod.vod_remarks or vod.note or vod.remarks),
        latestChapterUrl = detail,
        tags = splitTags(vod.vod_tag),
        meta = cleanText(vod.vod_actor) ~= "" and {
            { label = cleanText(vod.type_name) == "动漫" and "声优" or "演员", field = cleanText(vod.vod_actor) },
        } or nil,
        wordCount = 0,
        chapterCount = tonumber(vod.vod_total or vod.vod_serial) or 0,
        latestUpdateTime = parseVodTime(vod.vod_time),
    }
end

local function resourcesOf(payload)
    local resources = {}
    for _, vod in ipairs(listOf(payload)) do
        local resource = resourceOf(vod)
        if resource then resources[#resources + 1] = resource end
    end
    return resources
end

local function selectedRoute(resourceUrl, options)
    local requested = trim(options and options.routeId)
    if requested ~= "" then return requested end
    local value = trim(lime.storage.get("playback:route"))
    return value ~= "" and value or DEFAULT_ROUTE
end

local function routeLabel(route)
    for _, option in ipairs(ROUTES) do
        if option.value == route then return option.label end
    end
    return route
end

local function rememberAvailableRoutes(routes)
    local values, seen = {}, {}
    for _, route in ipairs(routes) do
        local value = trim(route)
        if value ~= "" and not seen[value] then
            seen[value] = true
            values[#values + 1] = value
        end
    end
    if #values > 0 then lime.storage.set(AVAILABLE_ROUTES_KEY, table.concat(values, "$$$")) end
    return values
end

local function routeOptions()
    local options, seen = {}, {}
    local function append(value, label)
        value = trim(value)
        if value == "" or seen[value] then return end
        seen[value] = true
        options[#options + 1] = { value = value, label = label or routeLabel(value) }
    end
    for _, option in ipairs(ROUTES) do append(option.value, option.label) end
    for value in tostring(lime.storage.get(AVAILABLE_ROUTES_KEY) or ""):gmatch("([^$]+)") do
        append(value, routeLabel(value))
    end
    return options
end

local function fixPlayUrl(value)
    return trim(htmlDecode(value)):gsub("\\/", "/")
end

local function detectFormat(url)
    local path = tostring(url or ""):match("^[^?]+") or ""
    path = path:lower()
    if path:match("%.m3u8$") then return "hls", "application/vnd.apple.mpegurl" end
    if path:match("%.mpd$") then return "dash", "application/dash+xml" end
    return "file", nil
end



local function resourceInfo(url)
    local vod = firstVod(getJson(url))
    local resource = resourceOf(vod)
    if not resource then error("布布影视详情为空") end
    return resource
end

local function exploreSchema()
    return {
        supportsPagination = true,
        filters = {
            {
                field = "category",
                label = "分类",
                type = "single",
                default = "1",
                options = CATEGORIES,
            },
        },
    }
end

local function fetchVodPage(request, current)
    local data = getJson(apiUrl(request))
    local pages = tonumber(data.pagecount)
    local total = tonumber(data.total)
    if not total or total < 0 or total ~= math.floor(total) then total = nil end
    if pages and current > pages then return { records = {}, total = total } end
    local actualPage = tonumber(data.page)
    if actualPage and actualPage ~= current then error("布布影视返回的页码与请求不一致") end
    if type(data.list) ~= "table" and type(data.data) ~= "table" then
        error("布布影视搜索缺少结果列表")
    end
    return { records = resourcesOf(data), total = total }
end

-- MacCMS 提供明确 pagecount；不从每页条数估算 total。
local function search(query)
    query = query or {}
    local current = math.max(1, math.floor(tonumber(query.page) or 1))
    local keyword = trim(query.keyword or "")
    local request = "ac=detail&pg=" .. current .. "&wd=" .. urlEncode(keyword)
    return fetchVodPage(request, current)
end

local function browse(query)
    query = query or {}
    local current = math.max(1, math.floor(tonumber(query.page) or 1))
    local filters = query.filters or {}
    local request = "ac=detail&pg=" .. current .. "&t=" .. tostring(filters.category or "1")
    return fetchVodPage(request, current)
end

local function chapterList(resourceUrl, options)
    local vod = firstVod(getJson(resourceUrl))
    if not vod then error("布布影视目录为空") end
    local route = selectedRoute(resourceUrl, options)
    local froms, groups = {}, {}
    for value in tostring(vod.vod_play_from or ""):gmatch("([^$]+)") do froms[#froms + 1] = value end
    for value in (tostring(vod.vod_play_url or "") .. "$$$"):gmatch("(.-)%$%$%$") do groups[#groups + 1] = value end
    froms = rememberAvailableRoutes(froms)

    local selected
    for index, value in ipairs(froms) do
        if trim(value) == route then selected = groups[index]; break end
    end
    if not selected or trim(selected) == "" then
        error({ code = 2007, message = "当前线路没有可用剧集，请在插件设置中切换线路后刷新目录" })
    end

    local chapters = {}
    for episode in selected:gmatch("[^#]+") do
        local separator = episode:find("$", 1, true)
        if separator then
            local name = cleanText(episode:sub(1, separator - 1))
            local url = fixPlayUrl(episode:sub(separator + 1))
            if url ~= "" then
                chapters[#chapters + 1] = {
                    id = route .. ":" .. url,
                    name = name ~= "" and name or ("第" .. tostring(#chapters + 1) .. "集"),
                    url = url,
                    index = #chapters,
                }
            end
        end
    end
    if #chapters == 0 then
        error({ code = 2007, message = "当前线路没有可用剧集，请在插件设置中切换线路后刷新目录" })
    end
    local routes = {}
    for _, value in ipairs(froms) do
        routes[#routes + 1] = { id = value, label = routeLabel(value) }
    end
    return {
        routes = routes,
        selectedRouteId = route,
        chapters = chapters,
    }
end

local function chapterContent(request)
    if not request or not request.chapter then error("chapterContent: missing request.chapter") end
    local url = fixPlayUrl(request.chapter.url)
    if url == "" then error({ code = 2007, message = "当前线路播放地址为空，请切换线路后刷新目录" }) end
    local format, mimeType = detectFormat(url)
    return {
        blocks = {
            {
                id = "video-main",
                type = "video",
                title = request.chapter.name,
                sources = {
                    {
                        id = "selected-route",
                        format = format,
                        mimeType = mimeType,
                        url = url,
                        headers = {
                            ["User-Agent"] = UA,
                            ["Referer"] = API_BASE .. "/",
                        },
                    },
                },
            },
        },
    }
end

local function settings()
    return {
        {
            label = "播放线路",
            key = "playback",
            type = "dialog",
            icon = "Route",
            fields = {
                {
                    field = "route",
                    label = "默认线路",
                    required = true,
                    type = "select",
                    options = routeOptions(),
                    default = DEFAULT_ROUTE,
                },
            },
            actions = {
                { field = "saveRoute", label = "保存", action = "saveRoute" },
            },
        },
    }
end

local function settingsAction(action, data)
    if action ~= "saveRoute" then
        error("布布影视不支持该设置操作")
    end
    local route = trim(data.route)
    for _, option in ipairs(routeOptions()) do
        if option.value == route then
            return { ok = true, message = "线路已保存，请刷新资源目录" }
        end
    end
    error("不支持的播放线路")
end

local function test(request)
    local results, records, info, catalog = {}, nil, nil, nil
    local function run(entry, fn)
        local value = fn()
        results[#results + 1] = { entry = entry, status = "passed", message = "可用" }
        return value
    end
    records = run("search", function() local value = search({ keyword = "黑夜告白", page = 1 }).records; if #value == 0 then error("搜索无结果") end; return value end)
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

local function invokeSettings(request)
    return settingsAction(request.action, request.data)
end

return {
    kind = "resource",
    apiVersion = 1,
    manifest = {
        name = "布布影视",
        package = "com.meinil.lime.video.bbys",
        version = "0.0.2",
        author = "ai",
        description = "FreeOK/MacCMS 视频源，目录严格使用插件设置中选定的线路",
        homepage = "https://bbys.app",
        logo = "https://bbys.app/favicon.ico",
    },
    requires = { "browser", "crypto", "http", "json", "storage", "time" },

    capabilities = {
        content = "video",
        search = searchResources, resourceInfo = describeResource,
        chapterList = listResourceChapters, chapterContent = chapterContent,
        explore = browseResources,
        exploreSchema = exploreSchema,
    },
    hooks = {
        settings = { list = settings, action = invokeSettings },
        test = test,
    },
}
