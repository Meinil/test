--[[
    @name            小秋音乐
    @package         com.huibq.xiaoqiu.lime
    @content         audio
    @author          ai
    @source_url      https://raw.githubusercontent.com/Meinil/test/refs/heads/main/plugins/audio/xiaoqiu.lua
    @version         1.0.0
    @description     参考 MusicFree 小秋音源接口适配,单曲映射为单章节音频资源
    Upstream: https://fastly.jsdelivr.net/gh/Huibq/keep-alive/Music_Free/xiaoqiu.js
]]

local API = "https://u.y.qq.com/cgi-bin/musicu.fcg"
local PLAY_API = "https://lxmusicapi.onrender.com/url/tx/"
local PAGE_SIZE = 20
local HEADERS = {
    ["Referer"] = "https://y.qq.com/",
    ["User-Agent"] = "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36",
    ["Cookie"] = "uin=",
}

-- 歌词接口与 LRC 解析常量。
local LYRIC_API = "https://u.y.qq.com/cgi-bin/musicu.fcg"
local LYRIC_HEADERS = {
    ["Referer"] = "https://y.qq.com/",
    ["User-Agent"] = HEADERS["User-Agent"],
    ["Content-Type"] = "application/json",
}
-- QQ 音乐可能返回 "暂无歌词" 等占位,过滤掉避免污染空 cue。
local LRC_PLACEHOLDER_PATTERN = "^%s*[%[%(]?暂无歌词[%]%)]?%s*$"

local function trim(value) return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "") end
local function postJson(payload)
    local headers = {}; for key, value in pairs(HEADERS) do headers[key] = value end
    headers["Content-Type"] = "application/json"
    local response = lime.http.post(API, lime.json.encode(payload), headers)
    if response.status < 200 or response.status >= 300 then
        error("QQ 音乐请求失败: HTTP " .. tostring(response.status))
    end
    local data, decodeErr = lime.json.decode(response.body)
    if not data then error("QQ 音乐响应解析失败: " .. tostring(decodeErr)) end
    return data
end
local function songMidFromUrl(url) return tostring(url or ""):match("/songDetail/([%w%-_]+)") end
local function artistOf(song)
    local names = {}; for _, singer in ipairs(song.singer or {}) do local name = trim(singer.name); if name ~= "" then names[#names + 1] = name end end
    return table.concat(names, ", ")
end
local function resourceOf(song)
    local mid = trim(song.mid or song.songmid)
    local album = song.album or {}; local albumMid = trim(song.albummid or album.mid)
    local cover = albumMid ~= "" and ("https://y.gtimg.cn/music/photo_new/T002R800x800M000" .. albumMid .. ".jpg") or ""
    return {
        name = trim(song.title or song.songname), author = artistOf(song),
        url = "https://y.qq.com/n/ryqq/songDetail/" .. mid,
        cover = cover ~= "" and { url = cover, headers = { ["Referer"] = "https://y.qq.com/", ["User-Agent"] = HEADERS["User-Agent"] } } or nil,
        intro = trim(song.subtitle), latestChapter = trim(song.title or song.songname),
        latestChapterUrl = "https://y.qq.com/n/ryqq/songDetail/" .. mid,
        kind = "音乐", tags = { "QQ音乐" }, wordCount = 0, chapterCount = 1,
        latestUpdateTime = 0, content = "audio",
    }
end

function search(keyword, page)
    local data = postJson({ req_1 = { method = "DoSearchForQQMusicDesktop", module = "music.search.SearchCgiService", param = { num_per_page = PAGE_SIZE, page_num = tonumber(page) or 1, query = tostring(keyword or ""), search_type = 0 } } })
    local list = (((data.req_1 or {}).data or {}).body or {}).song or {}; local out = {}
    for _, song in ipairs(list.list or {}) do if trim(song.mid or song.songmid) ~= "" then out[#out + 1] = resourceOf(song) end end
    return out
end

function resourceInfo(url)
    local mid = songMidFromUrl(url); if not mid then error("无效的 QQ 单曲 URL") end
    local data = postJson({ req_0 = { module = "music.pf_song_detail_svr", method = "get_song_detail_yqq", param = { song_mid = mid } } })
    local song = ((data.req_0 or {}).data or {}).track_info; if not song then error("未找到单曲详情") end
    return resourceOf(song)
end

function chapterList(resourceUrl)
    if not songMidFromUrl(resourceUrl) then error("无效的 QQ 单曲 URL") end
    local resource = resourceInfo(resourceUrl)
    local name = trim(resource and resource.name)
    if name == "" then error("未取得单曲名称") end
    return { { name = name, url = resourceUrl, index = 0 } }
end

local function resolveUrl(mid, quality)
    local response = lime.http.get(PLAY_API .. mid .. "/" .. quality, { ["X-Request-Key"] = "share-v3" })
    if response.status < 200 or response.status >= 300 then return nil end
    local data = lime.json.decode(response.body); local url = data and trim(data.url) or ""
    return url ~= "" and url or nil
end

local function decodeBase64(value)
    if type(value) ~= "string" or value == "" then return "" end
    -- QQ 音乐 lyric/trans 字段返回的 base64 经常不带 "=" 填充。
    -- lime.crypto.base64Decode 用 STANDARD 解码严格校验填充,缺失时整体失败。
    -- 这里补齐填充再做一次重试,失败再返回空串。
    local raw = lime.crypto.base64Decode(value)
    if not raw then
        local pad = (4 - #value % 4) % 4
        if pad > 0 then raw = lime.crypto.base64Decode(value .. string.rep("=", pad)) end
    end
    if not raw then return "" end
    return raw
end

local function htmlDecodeEntities(value)
    if not value or value == "" then return "" end
    -- 仅解码 LRC 文本中最常见的 5 个 HTML 实体,顺序: 先解 &amp; 防止双重解码。
    local result = tostring(value)
        :gsub("&amp;", "&")
        :gsub("&lt;", "<")
        :gsub("&gt;", ">")
        :gsub("&quot;", '"')
        :gsub("&apos;", "'")
    return result
end

-- 解析 LRC 文本为 cue 列表。支持:
--   * 单时间戳: [00:12.34]text
--   * 多时间戳: [00:12.34][00:30.00]text → 同文本生成多条 cue
--   * 元信息行: [ti:...]/[ar:...]/[al:...]/[by:...]/[length:...] 跳过
--   * 缺 endMs 时退化为下一个 cue.startMs,最后一条 +1h
local function parseLrc(text)
    if not text or text == "" then return {} end
    local rawLines = {}
    for line in tostring(text):gmatch("[^\r\n]+") do rawLines[#rawLines + 1] = line end
    -- 先收集每行的 (timestamps[], text)
    local parsed = {}
    for _, line in ipairs(rawLines) do
        local timestamps = {}
        for mm, ss in line:gmatch("%[(%d+):(%d+%.?%d*)%]") do
            local mins = tonumber(mm)
            local secs = tonumber(ss)
            if mins and secs then timestamps[#timestamps + 1] = mins * 60000 + math.floor(secs * 1000) end
        end
        if #timestamps > 0 then
            -- 多时间戳一行形如 [00:20.00][00:30.00]text,以最后一个 ] 后面的部分作为文本。
            local text = line:match("%]([^%]]*)$")
            if text then
                text = text:gsub("^%s+", ""):gsub("%s+$", "")
                if text ~= "" then
                    for _, startMs in ipairs(timestamps) do
                        parsed[#parsed + 1] = { startMs = startMs, text = text }
                    end
                end
            end
        end
    end
    table.sort(parsed, function(a, b) return a.startMs < b.startMs end)
    -- 折叠到 {startMs, endMs, text}
    local cues = {}
    for index, entry in ipairs(parsed) do
        local endMs
        if index < #parsed then
            endMs = parsed[index + 1].startMs
        else
            endMs = entry.startMs + 3600000
        end
        if endMs <= entry.startMs then endMs = entry.startMs + 1 end
        cues[#cues + 1] = { startMs = entry.startMs, endMs = endMs, text = htmlDecodeEntities(entry.text) }
    end
    return cues
end

local function isPlaceholder(value)
    if not value or value == "" then return true end
    return tostring(value):match(LRC_PLACEHOLDER_PATTERN) ~= nil
end

-- 取一首歌曲的 lyric + trans(翻译),返回 { lyric = cues[], trans = cues[] }
-- 任一为空/占位时不返回对应数组。
local function fetchLrc(mid)
    if not mid or mid == "" then return nil end
    local payload = {
        songinfo = {
            method = "GetPlayLyricInfo",
            module = "music.musichallSong.PlayLyricInfo",
            param = { songMID = mid, qrc = 0, trans = 1, roma = 0, chn = 0 },
        },
    }
    local headers = {}
    for key, value in pairs(LYRIC_HEADERS) do headers[key] = value end
    local response = lime.http.post(LYRIC_API, lime.json.encode(payload), headers)
    lime.log.info("body: " .. tostring(lime.json.encode(response.body)))
    lime.log.info("mid: " .. mid)
    lime.log.info("status: " .. tostring(response.status))
    if response.status < 200 or response.status >= 300 then return nil end
    local data = lime.json.decode(response.body)
    lime.log.info("decode type=" .. type(data))
    if type(data) ~= "table" then return nil end

    lime.log.info("lyricInfo" .. lime.json.encode(lyricInfo))
    local lyricInfo = ((data.songinfo or {}).data or {}) or {}
    lime.log.info("lyricInfo" .. lime.json.encode(lyricInfo))
    local rawLyricField = lyricInfo.lyric or ""

    lime.log.info("lyricInfo lyric_field_len=" .. #rawLyricField .. " preview=" .. tostring(rawLyricField:sub(1, 40)))
    local lyricRaw = decodeBase64(rawLyricField)
    local transRaw = decodeBase64(lyricInfo.trans or "")
    lime.log.info("after decode: lyricRaw_len=" .. #lyricRaw .. " isPlaceholder=" .. tostring(isPlaceholder(lyricRaw)))
    if isPlaceholder(lyricRaw) and isPlaceholder(transRaw) then return nil end
    local result = {}
    if not isPlaceholder(lyricRaw) then result.lyric = parseLrc(lyricRaw) end
    if not isPlaceholder(transRaw) then result.trans = parseLrc(transRaw) end
    lime.log.info("parsed: lyric=" .. (result.lyric and #result.lyric or "nil") .. " trans=" .. (result.trans and #result.trans or "nil"))
    if (result.lyric == nil or #result.lyric == 0) and (result.trans == nil or #result.trans == 0) then
        return nil
    end
    return result
end

function chapterContent(request)
    local mid = songMidFromUrl(request.chapter.url); if not mid then error("无效的 QQ 单曲 URL") end
    local sources = {}; local low = resolveUrl(mid, "128k")
    if low then sources[#sources + 1] = { id = "qq-128k", quality = "low", url = low, headers = HEADERS, format = "file", mimeType = "audio/mpeg" } end
    local high = resolveUrl(mid, "320k")
    if high then sources[#sources + 1] = { id = "qq-320k", quality = "high", url = high, headers = HEADERS, format = "file", mimeType = "audio/mpeg" } end
    if #sources == 0 then error("未取得可播放地址") end

    -- 歌词轨道:有 lyric 时至少 1 条 default=true,有 trans 时追加 default=false。
    -- fetchLrc 不做 pcall,任何错误直接抛到 host(Rust)走统一错误处理。
    local subtitles = {}
    local lrcData = fetchLrc(mid)
    if lrcData then
        if lrcData.lyric and #lrcData.lyric > 0 then
            subtitles[#subtitles + 1] = {
                id = "lyric-zh", label = "原词", language = "zh", default = true,
                cues = lrcData.lyric,
            }
        end
        if lrcData.trans and #lrcData.trans > 0 then
            subtitles[#subtitles + 1] = {
                id = "lyric-trans", label = "翻译", language = "zh",
                -- 多条时第二条 default=false;只有翻译时仍 default=true 满足 1 条 default 约束。
                default = (#subtitles == 0), cues = lrcData.trans,
            }
        end
    end

    lime.log.info("subtitles" .. lime.json.encode(subtitles))
    return {
        blocks = {
            {
                id = "audio-main",
                type = "audio",
                title = request.chapter.name,
                sources = sources,
                subtitles = subtitles,
            },
        },
    }
end
