// @name        G站漫画
// @version     1.0.9
// @uuid        gzhanmanhua
// @author      Ai
// @url         https://m.g-mh.org/
// @logo        https://m.g-mh.org//favicon.ico
// @type        comic
// @enabled     true
// @tags        comic
// @description G社 v1.0.9 — 纯接口返回章节图片，prepareImage 注入 Referer/Origin

async function TEST(type) {
  if (type === "__list__") return ["search", "explore", "bookInfo", "chapterList", "chapterContent"];
  if (type === "search") {
    var r = await search("\u6597\u7834", 1);
    return { passed: r && r.length > 0, message: "search results=" + (r ? r.length : 0) };
  }
  if (type === "explore") {
    var e = await explore(1, "\u5168\u90e8\u6f2b\u753b");
    return { passed: e && e.length > 0, message: "explore results=" + (e ? e.length : 0) };
  }
  if (type === "bookInfo") {
    var b = await bookInfo(BASE + "/manga/wolaiziyouxi-mokf");
    return { passed: !!b.name && !!b.tocUrl, message: "book=" + b.name };
  }
  if (type === "chapterList") {
    var cs = await chapterList(BASE + "/manga/wolaiziyouxi-mokf");
    return { passed: cs && cs.length > 10, message: "chapters=" + (cs ? cs.length : 0) };
  }
  if (type === "chapterContent") {
    var text = await chapterContent("21|518784|wolaiziyouxi-mokf|0");
    var arr = [];
    try {
      arr = JSON.parse(text);
    } catch (e) {}
    return { passed: arr && arr.length > 10, message: "images=" + (arr ? arr.length : 0) };
  }
}

var BASE = "https://m.g-mh.org";
var API_BASE = "https://api-get-v3.mgsearcher.com";
var IMG_HOST_T = "https://t40-1-4.g-mh.online";
var IMG_HOST_F = "https://f40-1-4.g-mh.online";
var UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36";
var PAGE_HEADERS = { "User-Agent": UA, Referer: BASE + "/", Accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" };
var API_HEADERS = { "User-Agent": UA, Referer: BASE + "/", Origin: BASE, Accept: "application/json,text/plain,*/*" };
var CATS = {
  "\u8fd1\u671f\u66f4\u65b0": "/",
  "\u4eba\u6c14\u63a8\u8350": "/hots",
  "\u70ed\u95e8\u66f4\u65b0": "/dayup",
  "\u6700\u65b0\u4e0a\u67b6": "/newss",
  "\u5168\u90e8\u6f2b\u753b": "/manga",
  "\u97e9\u6f2b": "/manga-genre/kr",
  "\u56fd\u6f2b": "/manga-genre/cn",
  "\u65e5\u6f2b": "/manga-genre/jp",
  "\u7a7f\u8d8a": "/manga-tag/chuanyue",
  "\u70ed\u8840": "/manga-tag/rexue",
  "\u7384\u5e7b": "/manga-tag/xuanhuan",
  "\u604b\u7231": "/manga-tag/lianai",
};

function isCfBlocked(html) {
  if (!html || html.length < 200) return true;
  var markers = [
    "Just a moment",
    "cf-browser-verification",
    "Checking your browser",
    "cf-challenge-running",
    "managed_checking_msg",
    "cf-please-wait",
    "cf-turnstile-wrapper",
  ];
  for (var i = 0; i < markers.length; i++) {
    if (html.indexOf(markers[i]) >= 0) return true;
  }
  return false;
}

var COOKIE_READY = false;
async function ensureCookies() {
  if (COOKIE_READY) return;
  try {
    var fastHtml = await lime.http.get(BASE + "/", PAGE_HEADERS);
    if (!isCfBlocked("" + fastHtml)) {
      COOKIE_READY = true;
      return;
    }
    lime.log("[G] CF\u62e6\u622a");
    var sid = lime.browser.acquire("cf", { visible: false, userAgent: UA, muted: true });
    lime.browser.navigate(sid, BASE + "/", { waitFor: "load" });
    var passed = false,
      browserShown = false;
    for (var i = 0; i < 60; i++) {
      var pageHtml = lime.browser.html(sid);
      if (pageHtml && pageHtml.length > 500 && !isCfBlocked(pageHtml)) {
        passed = true;
        break;
      }
      if (!browserShown) {
        lime.toast("CF\u9a8c\u8bc1\u4e2d...");
        lime.browser.show(sid);
        browserShown = true;
      }
      lime.sleep(1000);
    }
    if (!passed) {
      lime.browser.hide(sid);
      COOKIE_READY = true;
      return;
    }
    lime.browser.cookies(BASE + "/");
    lime.browser.cookies();
    lime.browser.hide(sid);
    COOKIE_READY = true;
    lime.log("[G] CF ok");
  } catch (e) {
    COOKIE_READY = true;
  }
}

function abs(href) {
  if (!href) return "";
  if (href.indexOf("//") === 0) return "https:" + href;
  return href.indexOf("http") === 0 ? href : BASE + (href.charAt(0) === "/" ? href : "/" + href);
}
function clean(s) {
  return (s || "")
    .replace(/<[^>]+>/g, "")
    .replace(/&nbsp;/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}
function isBlockedText(s) {
  s = "" + (s || "");
  return (
    s.indexOf("\u8bf7\u5230\u7f51\u7ad9\u9605\u8bfb") >= 0 ||
    s.indexOf("\u8acb\u5230\u7db2\u7ad9\u95b1\u8b80") >= 0 ||
    s.indexOf("Just a moment") >= 0 ||
    s.indexOf("Enable JavaScript") >= 0 ||
    s.indexOf("\u53d1\u751f\u5f02\u5e38") >= 0 ||
    s.indexOf("\u7372\u53d6\u6578\u64da\u5931\u6557") >= 0
  );
}
async function getText(url, headers) {
  var last = null;
  for (var i = 0; i < 3; i++) {
    try {
      var text = await lime.http.get(url, headers || PAGE_HEADERS);
      if (!isBlockedText(text)) return "" + text;
      last = new Error("blocked");
    } catch (e) {
      last = e;
    }
  }
  throw last;
}
function parseCardList(html) {
  html = "" + html;
  if (!html) return [];
  var doc = lime.dom.parse(html),
    links = lime.dom.selectAll(doc, 'a[href^="/manga/"]'),
    out = [],
    seen = {};
  for (var i = 0; i < links.length; i++) {
    var href = lime.dom.attr(links[i], "href") || "",
      parts = href.split("/");
    if (parts.length > 3 && parts[3]) continue;
    var url = abs(href);
    if (seen[url]) continue;
    var name = lime.dom.selectText(links[i], "h3.cardtitle") || lime.dom.selectText(links[i], "h3") || lime.dom.attr(links[i], "title") || "";
    if (!name) continue;
    var img = lime.dom.select(links[i], "img"),
      cover = img ? lime.dom.attr(img, "src") || lime.dom.attr(img, "data-src") || "" : "";
    seen[url] = true;
    out.push({ name: clean(name), author: "", bookUrl: url, tocUrl: url, coverUrl: cover, kind: "\u6f2b\u753b", intro: "" });
  }
  lime.dom.free(doc);
  return out;
}
function extractMangaId(html) {
  html = "" + html;
  var m =
    html.match(/id="ChapterHistory"[^>]*data-manga-id="(\d+)"/) ||
    html.match(/id="chaplistlast"[^>]*data-mid="(\d+)"/) ||
    html.match(/id="mangachapters"[^>]*data-mid="(\d+)"/);
  return m ? m[1] : "";
}
function extractAuthor(html) {
  var m = ("" + html).match(/"@type":"Person","name":"([^"]+)"/);
  return m ? m[1] : "";
}

async function search(keyword, page) {
  if (page > 1 || !keyword) return [];
  return parseCardList(await getText(BASE + "/s/?q=" + encodeURIComponent(keyword), PAGE_HEADERS));
}

async function bookInfo(bookUrl) {
  bookUrl = abs(bookUrl);
  await ensureCookies();
  var html = await getText(bookUrl, PAGE_HEADERS),
    doc = lime.dom.parse(html);
  var ogTitle = lime.dom.selectAttr(doc, 'meta[property="og:title"]', "content") || lime.dom.selectText(doc, "title") || "";
  var name = clean(ogTitle.replace(/-G.*/, "").replace(/-G\u793e.*/, ""));
  var cover = lime.dom.selectAttr(doc, 'meta[property="og:image"]', "content") || lime.dom.selectAttr(doc, "#bookmarkData", "data-cover") || "";
  var intro = lime.dom.selectAttr(doc, 'meta[property="og:description"]', "content") || "";
  var mid = extractMangaId(html),
    author = extractAuthor(html);
  lime.dom.free(doc);
  return {
    name: name,
    author: author,
    bookUrl: bookUrl,
    tocUrl: mid ? bookUrl + "|" + mid : bookUrl,
    coverUrl: abs(cover),
    intro: clean(intro),
    kind: "\u6f2b\u753b",
    lastChapter: "",
  };
}

async function chapterList(tocUrl) {
  var bookUrl = tocUrl,
    mid = "",
    bar = tocUrl.indexOf("|");
  if (bar >= 0) {
    bookUrl = tocUrl.substring(0, bar);
    mid = tocUrl.substring(bar + 1);
  }
  bookUrl = abs(bookUrl);
  if (!mid) mid = extractMangaId(await getText(bookUrl, PAGE_HEADERS));
  if (!mid) return [];
  var slugMatch = bookUrl.match(/\/manga\/([^\/|]+)/),
    slug = slugMatch ? slugMatch[1] : "";
  var resp = await getText(API_BASE + "/api/manga/get?mid=" + mid, API_HEADERS);
  if (isBlockedText(resp) || resp.charAt(0) !== "{") return [];
  var obj = JSON.parse(resp),
    arr = obj && obj.data && obj.data.chapters ? obj.data.chapters : [];
  arr.sort(function (a, b) {
    return ((a.attributes || {}).order || 0) - ((b.attributes || {}).order || 0);
  });
  var out = [];
  for (var i = 0; i < arr.length; i++) {
    var ch = arr[i],
      at = ch.attributes || {};
    if (!ch.id) continue;
    out.push({ name: at.title || "\u7b2c" + (i + 1) + "\u8bdd", url: mid + "|" + ch.id + "|" + slug + "|" + (at.slug || i) });
  }
  return out;
}

// ── v1.0.8: 纯接口返回章节图片 ──
async function chapterContent(chapterUrl) {
  var parts = (chapterUrl || "").split("|");
  if (parts.length < 2) return "[]";
  lime.log("[G] chapterContent m=" + parts[0] + " c=" + parts[1]);

  var resp = await getText(API_BASE + "/api/chapter/getinfo?m=" + parts[0] + "&c=" + parts[1], API_HEADERS);
  if (isBlockedText(resp) || resp.charAt(0) !== "{") return "[]";
  var obj = JSON.parse(resp);
  if (obj.code !== 200) {
    lime.log("[G] API code=" + obj.code);
    return "[]";
  }

  var info = obj.data && obj.data.info ? obj.data.info : {};
  var imagesData = info.images || {};
  var apiArr = imagesData.images || [];
  if (!apiArr.length) return "[]";

  var host = imagesData.line === 2 ? IMG_HOST_F : IMG_HOST_T;
  apiArr.sort(function (a, b) {
    return (a.order || 0) - (b.order || 0);
  });
  var urls = [];
  for (var i = 0; i < apiArr.length; i++) {
    if (apiArr[i].url) urls.push(host + apiArr[i].url);
  }

  lime.log("[G] result: " + urls.length + " urls");
  return JSON.stringify(urls);
}

async function explore(page, category) {
  if (!category || category === "GETALL") return Object.keys(CATS);
  if (page > 1) return [];
  return parseCardList(await getText(BASE + (CATS[category] || "/"), PAGE_HEADERS));
}

// 每张图片下载前注入正确的 Referer / Origin，避免防盗链拦截
function prepareImage(url, pageIndex) {
  return {
    headers: {
      Referer: BASE + "/",
      // Origin: BASE,
    },
  };
}