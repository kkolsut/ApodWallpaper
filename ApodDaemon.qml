import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins

// Background service: fetches NASA's Astronomy Picture of the Day,
// downloads it and hands it to the shell's wallpaper manager.
PluginComponent {
    id: root

    readonly property string pid: pluginId || "apodWallpaper"

    // ---- Settings (edited in Settings → Plugins → APOD Wallpaper) ----
    readonly property string apiKey: ((pluginData.apiKey ?? "") + "").trim() || "DEMO_KEY"
    readonly property string saveDir: expandHome(((pluginData.saveDir ?? "") + "").trim() || "~/Pictures/APOD")
    readonly property int checkHours: Math.max(1, Number(pluginData.checkHours ?? 3))
    readonly property bool autoUpdate: pluginData.autoUpdate ?? true
    readonly property bool preferHd: pluginData.preferHd ?? true
    readonly property bool useVideoThumbs: pluginData.useVideoThumbs ?? false
    readonly property bool notify: pluginData.notify ?? true

    // ---- Runtime state ----
    property bool busy: false
    property var last: ({})          // { date, title, path, url, pageUrl, explanation, copyright }

    function expandHome(p) {
        return p.startsWith("~") ? Quickshell.env("HOME") + p.slice(1) : p;
    }

    function pageUrlFor(date) {
        // 2026-10-28 -> https://apod.nasa.gov/apod/ap261028.html
        const m = /^\d{2}(\d{2})-(\d{2})-(\d{2})$/.exec(date || "");
        return m ? "https://apod.nasa.gov/apod/ap" + m[1] + m[2] + m[3] + ".html" : "https://apod.nasa.gov/apod/astropix.html";
    }

    function publish(error) {
        PluginService.setGlobalVar(pid, "busy", busy);
        PluginService.setGlobalVar(pid, "info", last);
        PluginService.setGlobalVar(pid, "error", error || "");
    }

    function restore() {
        if (!pluginService)
            return;
        last = pluginService.loadPluginState(pid, "last", {}) || {};
        publish("");
    }

    function finish(error, force) {
        busy = false;
        publish(error);
        if (error) {
            console.warn("[apodWallpaper]", error);
            if (force || notify)
                ToastService.showError("APOD Wallpaper", error);
        }
    }

    readonly property var imageExt: /\.(jpe?g|png|gif|webp)(?:[?#]|$)/i
    readonly property var videoExt: /\.(mp4|webm|mov|m4v|ogv)(?:[?#]|$)/i
    readonly property var badImage: /logo|meatball|favicon|placeholder|default_?image/i
    readonly property string listingUrl: "https://science.nasa.gov/apod/"
    readonly property var months: ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]

    function log(msg) {
        console.info("[apodWallpaper]", msg);
    }

    function isGoodImage(url) {
        return !!url && imageExt.test(url) && !badImage.test(url);
    }

    function hashOf(str) {
        let h = 5381;
        for (let i = 0; i < str.length; i++)
            h = ((h << 5) + h + str.charCodeAt(i)) >>> 0;
        return h.toString(16);
    }

    // Reads <meta property|name="key" content="..."> in either attribute order.
    function meta(html, key) {
        const k = key.replace(/[.:]/g, "\\$&");
        const m = new RegExp('<meta[^>]+(?:property|name)\\s*=\\s*["\']' + k + '["\'][^>]*content\\s*=\\s*["\']([^"\']+)', "i").exec(html)
            || new RegExp('<meta[^>]+content\\s*=\\s*["\']([^"\']+)["\'][^>]*(?:property|name)\\s*=\\s*["\']' + k + '["\']', "i").exec(html);
        return m ? m[1].replace(/&amp;/g, "&").replace(/&#0?39;/g, "'").replace(/&quot;/g, '"') : "";
    }

    // science.nasa.gov serves resized renditions; strip the suffix to get the full-size original.
    function originalOf(url) {
        return (url || "").replace(/\/jcr:content\/renditions\/.*$/, "");
    }

    // "apod-2026-november-1-..." or "apod-29-october-2026-..." -> "2026-11-01"
    function dateFromSlug(url) {
        const pad = n => (n < 10 ? "0" : "") + n;
        let m = /apod-(\d{4})-([a-z]+)-(\d{1,2})(?:-|\/|$)/i.exec(url);
        let y, mon, d;
        if (m) {
            y = m[1]; mon = m[2]; d = m[3];
        } else {
            m = /apod-(\d{1,2})-([a-z]+)-(\d{4})(?:-|\/|$)/i.exec(url);
            if (!m)
                return "";
            d = m[1]; mon = m[2]; y = m[3];
        }
        const mi = months.indexOf(mon.toLowerCase());
        return mi < 0 ? "" : y + "-" + pad(mi + 1) + "-" + pad(Number(d));
    }

    // ---- Step 1: find the newest APOD from both the API and NASA's APOD page ----
    function check(force) {
        if (busy)
            return "busy";
        busy = true;
        publish("");

        const api = "https://api.nasa.gov/planetary/apod?thumbs=true&api_key=" + encodeURIComponent(apiKey);
        Proc.runCommand(pid + ".api", ["curl", "-fsSL", "--max-time", "30", api], (out, code) => {
            let apiInfo = null;
            if (code === 0) {
                try {
                    apiInfo = parseApi(JSON.parse(out));
                } catch (e) {
                    console.warn("[apodWallpaper] bad API response:", e);
                }
            }
            log(apiInfo ? "API says " + apiInfo.date : "API failed (exit " + code + "): " + (out || "").slice(0, 120));
            findLatestArticle((articleUrl, articleDate) => decide(apiInfo, articleUrl, articleDate, force));
        }, 0, 45000, root);
        return "checking";
    }

    // The NASA API sometimes lags behind by days, so the newest dated article on
    // science.nasa.gov/apod/ is the reference for "today".
    function findLatestArticle(done) {
        Proc.runCommand(pid + ".list", ["curl", "-fsSL", "--max-time", "30", listingUrl], (html, code) => {
            if (code !== 0) {
                log("APOD page unreachable (exit " + code + ")");
                return done("", "");
            }
            const re = /href\s*=\s*"((?:https:\/\/science\.nasa\.gov)?\/image-article\/(?:apod\/)?apod-[^"#?]+)"/gi;
            let best = "", bestDate = "", m;
            while ((m = re.exec(html)) !== null) {
                const url = m[1].startsWith("/") ? "https://science.nasa.gov" + m[1] : m[1];
                const date = dateFromSlug(url);
                if (date && date > bestDate) {
                    best = url;
                    bestDate = date;
                }
            }
            log("APOD page says " + (bestDate || "nothing") + (best ? " " + best : ""));
            done(best, bestDate);
        }, 0, 45000, root);
    }

    function decide(apiInfo, articleUrl, articleDate, force) {
        if (articleUrl && (!apiInfo || articleDate > apiInfo.date))
            return readArticle(articleUrl, articleDate, force);              // API missing or stale
        if (apiInfo && apiInfo.needsStill && articleUrl && articleDate === apiInfo.date)
            return readArticle(articleUrl, articleDate, force);              // video: the article has the still
        if (apiInfo && last.date && apiInfo.date < last.date) {
            log("API is behind (" + apiInfo.date + "), keeping " + last.date);
            return handleInfo({ skip: "NASA hasn't published anything newer than " + last.date + " yet" }, force);
        }
        if (apiInfo) {
            if (articleUrl && articleDate === apiInfo.date)
                apiInfo.pageUrl = articleUrl;
            if (apiInfo.needsStill)
                apiInfo.skip = "Today's APOD is a video with no still image, keeping the current wallpaper";
            return handleInfo(apiInfo, force);
        }
        finish("Couldn't reach NASA APOD (API and web page both failed)", force);
    }

    function parseApi(j) {
        if (!j || !j.date)
            return null;
        const base = {
            date: j.date,
            title: j.title || "Astronomy Picture of the Day",
            explanation: j.explanation || "",
            copyright: (j.copyright || "").trim(),
            pageUrl: pageUrlFor(j.date)
        };
        const img = (preferHd && j.hdurl) ? j.hdurl : j.url;
        if (j.media_type === "image" && isGoodImage(img))
            return Object.assign(base, { url: img });
        if (j.media_type === "image" && isGoodImage(j.url))
            return Object.assign(base, { url: j.url });
        if (!useVideoThumbs)
            return Object.assign(base, { skip: "Today's APOD is a video, keeping the current wallpaper" });
        // YouTube/Vimeo give a real frame; anything else from the API may be a placeholder.
        if (/^https:\/\/(img\.youtube\.com|i\.ytimg\.com|i\.vimeocdn\.com)\//i.test(j.thumbnail_url || ""))
            return Object.assign(base, { url: j.thumbnail_url });
        return Object.assign(base, { needsStill: true });
    }

    function readArticle(url, date, force) {
        Proc.runCommand(pid + ".article", ["curl", "-fsSL", "--max-time", "30", url], (html, code) => {
            if (code !== 0)
                return finish("Couldn't open " + url + " (curl exit " + code + ")", force);

            const isVideo = /<(video|iframe)\b/i.test(html);
            const preview = meta(html, "og:image") || meta(html, "twitter:image");
            const title = (meta(html, "og:title") || "Astronomy Picture of the Day")
                .replace(/\s*[-–]\s*NASA Science\s*$/i, "")
                .replace(/^APOD:\s*(?:\d{4}\s+\w+\s+\d{1,2}|\d{1,2}\s+\w+\s+\d{4})\s*[-–]\s*/i, "");
            const info = {
                date: date,
                title: title,
                explanation: meta(html, "og:description") || meta(html, "description"),
                copyright: "",
                pageUrl: url
            };
            log("article " + date + ": video=" + isVideo + " image=" + (preview || "none"));

            if (isVideo) {
                if (!useVideoThumbs)
                    info.skip = "Today's APOD is a video, keeping the current wallpaper";
                else
                    return findStill(info, force, html);
            } else if (preferHd && isGoodImage(originalOf(preview))) {
                info.url = originalOf(preview);
            } else if (isGoodImage(preview)) {
                info.url = preview;
            } else {
                info.skip = "Couldn't find today's picture on the APOD page";
            }
            handleInfo(info, force);
        }, 0, 45000, root);
    }

    // ---- Video days: find a still image NASA published for the video ----
    function findStill(info, force, html) {
        const origin = (/^https?:\/\/[^\/]+/.exec(info.pageUrl || "") || ["https://science.nasa.gov"])[0];
        const abs = u => /^https?:\/\//i.test(u) ? u : (u.startsWith("//") ? "https:" + u : origin + "/" + u.replace(/^\/+/, ""));
        const candidates = [];
        const poster = /<video\b[^>]*\bposter\s*=\s*"([^"]+)"/i.exec(html);
        if (poster)
            candidates.push(abs(poster[1]));
        for (const key of ["og:image", "twitter:image"]) {
            const u = meta(html, key);
            if (u) {
                if (preferHd)
                    candidates.push(abs(originalOf(u)));
                candidates.push(abs(u));
            }
        }
        const src = /<source\b[^>]*\bsrc\s*=\s*"([^"]+)"/i.exec(html) || /<video\b[^>]*\bsrc\s*=\s*"([^"]+)"/i.exec(html);
        if (src && videoExt.test(src[1]))
            for (const e of [".jpg", ".jpeg", ".png"])
                candidates.push(abs(src[1]).replace(videoExt, e));

        const good = candidates.filter((u, i) => isGoodImage(u) && candidates.indexOf(u) === i);
        log("still candidates: " + (good.length ? good.join(" ") : "none"));
        if (!good.length)
            return handleInfo(Object.assign(info, { skip: "Today's APOD is a video with no still image, keeping the current wallpaper" }), force);

        // Use the first candidate that actually exists.
        const probe = 'for u in "$@"; do curl -fsL --max-time 15 -r 0-0 -o /dev/null "$u" && { echo "$u"; exit 0; }; done; exit 1';
        Proc.runCommand(null, ["sh", "-c", probe, "probe"].concat(good), (out, code) => {
            const url = out.trim();
            if (code === 0 && url)
                handleInfo(Object.assign(info, { url: url }), force);
            else
                handleInfo(Object.assign(info, { skip: "Today's APOD is a video with no still image, keeping the current wallpaper" }), force);
        }, 0, 90000, root);
    }

    // ---- Step 2: download (once per day) and apply ----
    function handleInfo(info, force) {
        if (info.skip) {
            log(info.skip);
            if (force)
                ToastService.showInfo("APOD Wallpaper", info.skip);
            return finish("", force);
        }

        const extMatch = imageExt.exec(info.url);
        const ext = extMatch ? extMatch[1].toLowerCase() : "jpg";
        // Name includes a hash of the source URL so a bad earlier download is never reused.
        const file = saveDir + "/apod-" + info.date + "-" + hashOf(info.url) + "." + ext;

        // Already applied today's picture: don't override a wallpaper the user picked by hand.
        if (!force && last.date === info.date && last.path === file)
            return finish("", force);

        const script = 'mkdir -p "$1" && { [ -s "$2" ] || { curl -fsSL --max-time 180 -o "$2.part" "$3" && mv -f "$2.part" "$2"; }; }';
        Proc.runCommand(null, ["sh", "-c", script, "apod", saveDir, file, info.url], (out, code) => {
            if (code !== 0)
                return finish("Download failed for " + info.url + " (exit " + code + ")", force);

            log("applying " + file + " from " + info.url);
            applyWallpaper(file);
            last = Object.assign({}, info, { path: file });
            pluginService?.savePluginState(pid, "last", last);
            if (notify || force)
                ToastService.showInfo("APOD Wallpaper", info.title);
            finish("", force);
        }, 0, 200000, root);
    }

    function applyWallpaper(path) {
        if (typeof SessionData.setWallpaper === "function")
            SessionData.setWallpaper(path);
        else
            Quickshell.execDetached(["dms", "ipc", "call", "wallpaper", "set", path]);
    }

    // ---- Scheduling ----
    Timer {
        // Give the network a moment after login before the first check.
        interval: 15000
        running: root.autoUpdate
        onTriggered: root.check(false)
    }

    Timer {
        interval: root.checkHours * 3600 * 1000
        repeat: true
        running: root.autoUpdate
        onTriggered: root.check(false)
    }

    // ---- CLI / keybind control:  dms ipc call apodWallpaper <fn> ----
    IpcHandler {
        target: "apodWallpaper"

        function refresh(): string {
            return root.check(true);
        }

        function info(): string {
            return JSON.stringify(root.last);
        }

        function open(): string {
            const url = root.last.pageUrl || root.listingUrl;
            Qt.openUrlExternally(url);
            return url;
        }
    }

    onPluginServiceChanged: restore()
    Component.onCompleted: {
        restore();
        console.info("[apodWallpaper] daemon started, saving to", saveDir);
    }
}
