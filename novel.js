// @name        笔趣阁CC
// @version     1.0.2
// @uuid        biqugelaile
// @author      Ai
// @url         https://www.bqgl.cc/
// @enabled     true
// @tags        novel,free
// @description bqgl.cc real parser

async function TEST(type) {
  if (type === '__list__') return ['search', 'explore', 'bookInfo', 'chapterList', 'chapterContent'];
  if (type === 'search') {
    var r = await search('\u673a\u6b66', 1);
    return { passed: r && r.length > 0, message: 'search results=' + (r ? r.length : 0) };
  }
  if (type === 'explore') {
    var e = await explore(1, '\u6392\u884c');
    return { passed: e && e.length > 0, message: 'explore results=' + (e ? e.length : 0) };
  }
  if (type === 'bookInfo') {
    var b = await bookInfo(BASE + '/look/104952/');
    return { passed: !!b.name, message: 'book=' + b.name + ' author=' + b.author };
  }
  if (type === 'chapterList') {
    var cs = await chapterList(BASE + '/look/104952/');
    return { passed: cs && cs.length > 20, message: 'chapters=' + (cs ? cs.length : 0) };
  }
  if (type === 'chapterContent') {
    var text = await chapterContent(BASE + '/look/104952/1.html');
    return { passed: text && text.length > 200 && text.indexOf('userverify') < 0, message: 'content len=' + (text ? text.length : 0) };
  }
}

var BASE = 'https://www.bqgl.cc';
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36';
var HEADERS = { 'User-Agent': UA, 'Referer': BASE + '/', 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' };
var CATS = { '玄幻': '/xuanhuan/', '武侠': '/wuxia/', '都市': '/dushi/', '历史': '/lishi/', '网游': '/wangyou/', '科幻': '/kehuan/', '女生': '/mm/', '排行': '/top/', '完本': '/finish/' };

function abs(href) {
  if (!href) return '';
  if (href.indexOf('//') === 0) return 'https:' + href;
  return href.indexOf('http') === 0 ? href : BASE + (href.charAt(0) === '/' ? href : '/' + href);
}

function clean(s) {
  return (s || '').replace(/<script[\s\S]*?<\/script>/gi, '').replace(/<style[\s\S]*?<\/style>/gi, '').replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' ').replace(/\s+/g, ' ').trim();
}

function cleanContentHtml(html) {
  var text = (html || '')
    .replace(/<p class="readinline"[\s\S]*?<\/p>/gi, '')
    .replace(/<script[\s\S]*?<\/script>/gi, '')
    .replace(/<style[\s\S]*?<\/style>/gi, '')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/p>\s*<p[^>]*>/gi, '\n')
    .replace(/<[^>]+>/g, '')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/（本章未完，请翻页）/g, '')
    .replace(/\(本章未完，请翻页\)/g, '')
    .replace(/请收藏本站：[\s\S]*$/g, '')
    .replace(/请收藏：https:\/\/m\.bqgl\.cc[\s\S]*$/g, '')
    .replace(/『点此报错』[\s\S]*$/g, '')
    .replace(/\n\s*\n+/g, '\n')
    .replace(/[ \t]+/g, ' ')
    .trim();
  if (text.indexOf('加载中') >= 0 || text.indexOf('userverify') >= 0) return '';
  return text;
}

function readableUrl(url) {
  url = abs(url);
  if (url.indexOf('?') >= 0) return url;
  return url + '?1';
}

async function getHtml(url) {
  return '' + await lime.http.get(url, HEADERS);
}

function parseBooks(html, kind) {
  var doc = lime.dom.parse('' + html);
  var out = [], seen = {};
  function pushFromLink(a, author, intro, cover, itemKind) {
    var href = lime.dom.attr(a, 'href') || '';
    if (href.indexOf('/look/') === -1) return;
    var url = abs(href);
    var name = clean(lime.dom.text(a));
    if (!name || seen[url]) return;
    seen[url] = true;
    out.push({ name: name, author: clean(author), bookUrl: url, tocUrl: url, intro: clean(intro), coverUrl: abs(cover || ''), kind: itemKind || kind || '' });
  }
  var items = lime.dom.selectAll(doc, '.item');
  for (var i = 0; i < items.length; i++) {
    var a = lime.dom.select(items[i], 'dt a[href*="/look/"]') || lime.dom.select(items[i], 'a[href*="/look/"]');
    if (!a) continue;
    var author = lime.dom.selectText(items[i], 'dt span') || '';
    var intro = lime.dom.selectText(items[i], 'dd') || '';
    var img = lime.dom.select(items[i], 'img');
    var cover = img ? (lime.dom.attr(img, 'src') || '') : '';
    pushFromLink(a, author, intro, cover, kind);
  }
  var rows = lime.dom.selectAll(doc, 'ul.lis li, .up li, .blocks li');
  for (var j = 0; j < rows.length; j++) {
    var a2 = lime.dom.select(rows[j], 'span.s2 a[href*="/look/"]') || lime.dom.select(rows[j], 'a[href*="/look/"]');
    var au = lime.dom.selectText(rows[j], 'span.s3') || lime.dom.selectText(rows[j], 'span.s5') || '';
    var kd = lime.dom.selectText(rows[j], 'span.s1') || kind || '';
    if (a2 && !au) {
      var rowText = clean(lime.dom.text(rows[j]));
      var linkText = clean(lime.dom.text(a2));
      if (rowText.indexOf(linkText + '/') === 0) au = rowText.substring(linkText.length + 1);
    }
    if (a2) pushFromLink(a2, au, '', '', kd);
  }
  lime.dom.free(doc);
  return out;
}

async function search(keyword, page) {
  if (page > 1 || !keyword) return [];
  var paths = ['/', '/xuanhuan/', '/wuxia/', '/dushi/', '/lishi/', '/wangyou/', '/kehuan/', '/mm/', '/top/'];
  var lower = (keyword || '').toLowerCase();
  var pool = [];
  for (var p = 0; p < paths.length; p++) {
    try { pool = pool.concat(parseBooks(await getHtml(BASE + paths[p]), '')); } catch (e) {}
  }
  var seen = {}, matched = [];
  for (var k = 0; k < pool.length; k++) {
    var b = pool[k];
    if (seen[b.bookUrl]) continue;
    seen[b.bookUrl] = true;
    var hay = (b.name + ' ' + b.author + ' ' + b.intro).toLowerCase();
    if (hay.indexOf(lower) >= 0) matched.push(b);
  }
  return matched;
}

async function bookInfo(bookUrl) {
  bookUrl = abs(bookUrl);
  var html = await getHtml(bookUrl);
  var doc = lime.dom.parse(html);
  var name = lime.dom.selectAttr(doc, 'meta[property="og:novel:book_name"]', 'content') || lime.dom.selectText(doc, 'h1') || '';
  var author = lime.dom.selectAttr(doc, 'meta[property="og:novel:author"]', 'content') || '';
  var cover = lime.dom.selectAttr(doc, 'meta[property="og:image"]', 'content') || lime.dom.selectAttr(doc, '.image img', 'src') || '';
  var intro = lime.dom.selectAttr(doc, 'meta[name="description"]', 'content') || lime.dom.selectText(doc, '.intro dd') || '';
  var kind = lime.dom.selectAttr(doc, 'meta[property="og:novel:category"]', 'content') || '';
  var latest = lime.dom.selectAttr(doc, 'meta[property="og:novel:latest_chapter_name"]', 'content') || '';
  var latestUrl = lime.dom.selectAttr(doc, 'meta[property="og:novel:latest_chapter_url"]', 'content') || '';
  lime.dom.free(doc);
  return { name: clean(name), author: clean(author), bookUrl: bookUrl, tocUrl: bookUrl, coverUrl: abs(cover), intro: clean(intro), kind: clean(kind), lastChapter: clean(latest), latestChapter: clean(latest), latestChapterUrl: abs(latestUrl) };
}

async function chapterList(tocUrl) {
  tocUrl = abs(tocUrl);
  var html = await getHtml(tocUrl);
  var doc = lime.dom.parse(html);
  var links = lime.dom.selectAll(doc, '.listmain a[href*="/look/"], #list a[href*="/look/"]');
  var out = [], seen = {};
  for (var i = 0; i < links.length; i++) {
    var href = lime.dom.attr(links[i], 'href') || '';
    if (!/\/look\/\d+\/\d+\.html$/.test(href)) continue;
    var url = abs(href);
    var name = clean(lime.dom.text(links[i]));
    if (name && !seen[url]) {
      seen[url] = true;
      out.push({ name: name, url: url });
    }
  }
  lime.dom.free(doc);
  return out;
}

async function chapterContent(chapterUrl) {
  var html = await getHtml(readableUrl(chapterUrl));
  var doc = lime.dom.parse(html);
  var el = lime.dom.select(doc, '#chaptercontent') || lime.dom.select(doc, '#content') || lime.dom.select(doc, '.content');
  var content = el ? cleanContentHtml(lime.dom.html(el)) : '';
  lime.dom.free(doc);
  return content;
}

async function explore(page, category) {
  if (!category || category === 'GETALL') return Object.keys(CATS);
  if (page > 1) return [];
  var path = CATS[category] || CATS['玄幻'];
  return parseBooks(await getHtml(BASE + path), category);
}