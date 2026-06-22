// @uuid        019e3dbd-8b98-7aef-a98f-f69849175be6
// ─── 元数据 ─────────────────────────────────────
// @name        布布影视
// @version     1.1.0
// @author      ChatGPT
// @url         https://bbys.app
// @url         https://www.freeokk.pro
// @logo        https://bbys.app/favicon.ico
// @type        video
// @enabled     true
// @minDelay    300
// @tags        免费,影视,在线播放
// @description 布布影视视频源；使用 FreeOK/MacCMS 接口作为数据入口，修复接口伪 JSON 换行导致解析为空的问题。

var BASE = 'https://bbys.app';
var API_BASE = 'https://www.freeokk.pro';
var API = API_BASE + '/api.php/provide/vod/';
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

var CATEGORIES = {
  '电影': 1,
  '剧集': 2,
  '综艺': 3,
  '动漫': 4
};

function log(msg) {
  try { lime.log('[布布影视] ' + msg); } catch (e) {}
}

function trimSlash(s) {
  return String(s || '').replace(/\/+$/, '');
}

function htmlDecode(s) {
  s = String(s || '');
  return s
    .replace(/&#x([0-9a-fA-F]+);/g, function(_, n) { return String.fromCharCode(parseInt(n, 16)); })
    .replace(/&#(\d+);/g, function(_, n) { return String.fromCharCode(parseInt(n, 10)); })
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>');
}

function cleanText(s) {
  return htmlDecode(String(s || '')
    .replace(/<script[\s\S]*?<\/script>/ig, ' ')
    .replace(/<style[\s\S]*?<\/style>/ig, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/\s+/g, ' ')
  ).trim();
}

function absUrl(base, url) {
  url = String(url || '').trim();
  if (!url) return '';
  if (/^https?:\/\//i.test(url)) return url;
  if (/^\/\//.test(url)) return 'https:' + url;
  base = trimSlash(base || API_BASE);
  if (url.charAt(0) === '/') return base + url;
  return base + '/' + url;
}

function apiUrl(params) {
  return API + '?' + params;
}

function headers(referer) {
  return {
    'User-Agent': UA,
    'Accept': 'application/json,text/plain,*/*',
    'Referer': referer || (API_BASE + '/')
  };
}

async function getText(url) {
  try {
    return await lime.http.get(url, headers(API_BASE + '/'));
  } catch (e) {
    log('GET失败 ' + url + ' -> ' + (e && e.message ? e.message : e));
    return '';
  }
}

// FreeOK 当前接口部分字段内含原始换行，严格 JSON.parse 会失败；这里做一次宽松修复。
function parseJsonLoose(text) {
  text = String(text || '').replace(/^\uFEFF/, '').trim();
  if (!text) return null;
  try { return JSON.parse(text); } catch (e) {}

  var out = '';
  var inStr = false;
  var esc = false;
  for (var i = 0; i < text.length; i++) {
    var ch = text.charAt(i);
    if (inStr) {
      if (esc) {
        out += ch;
        esc = false;
      } else if (ch === '\\') {
        out += ch;
        esc = true;
      } else if (ch === '"') {
        out += ch;
        inStr = false;
      } else if (ch === '\n') {
        out += '\\n';
      } else if (ch === '\r') {
        out += '\\r';
      } else if (ch === '\t') {
        out += '\\t';
      } else {
        out += ch;
      }
    } else {
      out += ch;
      if (ch === '"') inStr = true;
    }
  }
  try { return JSON.parse(out); } catch (e2) {
    log('JSON解析失败：' + (e2 && e2.message ? e2.message : e2));
    return null;
  }
}

async function getJson(url) {
  var text = await getText(url);
  return parseJsonLoose(text);
}

function pickIntro(v) {
  return cleanText(v.vod_blurb || v.vod_content || v.vod_sub || '');
}

function toBook(v) {
  v = v || {};
  var id = v.vod_id || v.id;
  var name = cleanText(v.vod_name || v.name || v.title || '');
  if (!id || !name) return null;
  var detailUrl = apiUrl('ac=detail&ids=' + encodeURIComponent(id));
  return {
    name: name,
    bookUrl: detailUrl,
    tocUrl: detailUrl,
    author: cleanText(v.vod_director || v.vod_actor || ''),
    coverUrl: absUrl(API_BASE, v.vod_pic || v.pic || v.cover || ''),
    intro: pickIntro(v),
    kind: cleanText(v.type_name || ''),
    latestChapter: cleanText(v.vod_remarks || v.note || v.remarks || ''),
    lastChapter: cleanText(v.vod_remarks || v.note || v.remarks || ''),
    updateTime: cleanText(v.vod_time || ''),
    status: cleanText(v.vod_remarks || v.note || v.remarks || ''),
    chapterCount: parseInt(v.vod_total || v.vod_serial || 0, 10) || 0
  };
}

function parseBooks(json) {
  var arr = [];
  if (json && Array.isArray(json.list)) arr = json.list;
  else if (json && json.data && Array.isArray(json.data)) arr = json.data;
  else if (json && json.data && Array.isArray(json.data.list)) arr = json.data.list;

  var list = [];
  for (var i = 0; i < arr.length; i++) {
    var item = toBook(arr[i]);
    if (item) list.push(item);
  }
  return list;
}

function firstVod(json) {
  if (json && json.list && json.list[0]) return json.list[0];
  if (json && json.data && json.data[0]) return json.data[0];
  if (json && json.data && json.data.list && json.data.list[0]) return json.data.list[0];
  return null;
}

async function search(keyword, page) {
  page = page || 1;
  log('search keyword=' + keyword + ' page=' + page);

  var url = apiUrl('ac=detail&wd=' + encodeURIComponent(keyword) + '&pg=' + page);
  var list = parseBooks(await getJson(url));
  if (list.length > 0) return list;

  // 备用：站内 suggest 接口。部分环境下可用。
  var suggest = await getJson(API_BASE + '/index.php/ajax/suggest?mid=1&wd=' + encodeURIComponent(keyword));
  var sList = [];
  var sArr = (suggest && (suggest.list || suggest.data || suggest.result)) || [];
  if (sArr && sArr.list) sArr = sArr.list;
  if (Array.isArray(sArr)) {
    for (var i = 0; i < sArr.length; i++) {
      var v = sArr[i] || {};
      var id = v.id || v.vod_id;
      var name = v.name || v.vod_name || v.title;
      if (!id || !name) continue;
      sList.push({
        name: cleanText(name),
        bookUrl: apiUrl('ac=detail&ids=' + encodeURIComponent(id)),
        tocUrl: apiUrl('ac=detail&ids=' + encodeURIComponent(id)),
        author: cleanText(v.actor || v.vod_actor || ''),
        coverUrl: absUrl(API_BASE, v.pic || v.vod_pic || ''),
        kind: cleanText(v.type_name || ''),
        latestChapter: cleanText(v.note || v.remarks || v.vod_remarks || ''),
        status: cleanText(v.note || v.remarks || v.vod_remarks || '')
      });
    }
  }
  return sList;
}

async function bookInfo(bookUrl) {
  log('bookInfo url=' + bookUrl);
  var json = await getJson(bookUrl);
  var v = firstVod(json);
  var info = toBook(v);
  if (info) return info;
  return { name: '', bookUrl: bookUrl, tocUrl: bookUrl, author: '', coverUrl: '', intro: '' };
}

function routeName(raw, index) {
  raw = String(raw || '').trim();
  if (!raw) return '线路' + (index + 1);
  var map = {
    ffm3u8: '非凡',
    rym3u8: '如意',
    bfzym3u8: '暴风',
    dyttm3u8: '电影天堂',
    youku: '优酷',
    '1080zyk': '1080资源'
  };
  return map[raw] || raw || ('线路' + (index + 1));
}

function fixPlayUrl(url) {
  url = String(url || '').trim();
  if (!url) return '';
  url = htmlDecode(url).replace(/\\\//g, '/');
  return url;
}

async function chapterList(tocUrl) {
  log('chapterList url=' + tocUrl);
  var json = await getJson(tocUrl);
  var v = firstVod(json);
  if (!v) return [];

  var froms = String(v.vod_play_from || '').split('$$$');
  var lines = String(v.vod_play_url || '').split('$$$');
  var chapters = [];

  for (var r = 0; r < lines.length; r++) {
    var line = lines[r] || '';
    if (!line) continue;
    var group = routeName(froms[r], r);
    var eps = line.split('#');
    for (var i = 0; i < eps.length; i++) {
      var ep = eps[i];
      if (!ep) continue;
      var p = ep.indexOf('$');
      if (p < 0) continue;
      var name = cleanText(ep.substring(0, p)) || ('第' + (i + 1) + '集');
      var url = fixPlayUrl(ep.substring(p + 1));
      if (!url) continue;
      chapters.push({ name: name, url: url, group: group });
    }
  }
  return chapters;
}

function detectType(url) {
  var u = String(url || '').split('?')[0].toLowerCase();
  if (/\.m3u8$/.test(u)) return 'hls';
  if (/\.mpd$/.test(u)) return 'dash';
  if (/\.flv$/.test(u)) return 'flv';
  return 'mp4';
}

async function chapterContent(chapterUrl) {
  log('chapterContent url=' + chapterUrl);
  chapterUrl = fixPlayUrl(chapterUrl);
  if (!chapterUrl) return '';

  return JSON.stringify({
    url: chapterUrl,
    type: detectType(chapterUrl),
    headers: {
      'User-Agent': UA,
      'Referer': API_BASE + '/'
    }
  });
}

async function explore(page, category) {
  page = page || 1;
  if (category === 'GETALL') return Object.keys(CATEGORIES);

  var typeId = CATEGORIES[category] || 1;
  log('explore category=' + category + ' page=' + page);
  var list = parseBooks(await getJson(apiUrl('ac=detail&t=' + typeId + '&pg=' + page)));
  return list;
}

function assertOk(cond, msg) {
  if (!cond) throw new Error('断言失败: ' + msg);
}

async function TEST(type) {
  if (type === '__list__') return ['search', 'explore', 'bookInfo', 'chapterList', 'chapterContent'];

  var results = await search('黑夜告白', 1);
  assertOk(results.length > 0, '搜索无结果');

  var exp = await explore(1, '电影');
  assertOk(exp.length > 0, '发现无结果');

  var info = await bookInfo(results[0].bookUrl);
  assertOk(info && info.tocUrl, '详情缺少 tocUrl');

  var chapters = await chapterList(info.tocUrl);
  assertOk(chapters.length > 0, '目录无结果');

  var play = await chapterContent(chapters[0].url);
  assertOk(play && play.length > 50, '播放地址为空');

  return {
    search: results.length,
    explore: exp.length,
    name: info.name,
    chapters: chapters.length,
    play: play
  };
}