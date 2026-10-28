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

    // ---- Step 1: ask the APOD API what today's picture is ----
    function check(force) {
        if (busy)
            return "busy";
        busy = true;
        publish("");

        const api = "https://api.nasa.gov/planetary/apod?thumbs=true&api_key=" + encodeURIComponent(apiKey);
        Proc.runCommand(pid + ".api", ["curl", "-fsSL", "--max-time", "30", api], (out, code) => {
            let info = null;
            if (code === 0) {
                try {
                    info = parseApi(JSON.parse(out));
                } catch (e) {
                    console.warn("[apodWallpaper] bad API response:", e);
                }
            }
            if (info)
                handleInfo(info, force);
            else
                scrapeFallback(force);   // API down or rate-limited: read the APOD web page instead
        }, 0, 45000, root);
        return "checking";
    }

    readonly property var imageExt: /\.(jpe?g|png|gif|webp)(?:[?#]|$)/i
    readonly property var videoExt: /\.(mp4|webm|mov|m4v|ogv)(?:[?#]|$)/i
    readonly property var badImage: /logo|meatball|favicon|placeholder|default_?image/i

    function isGoodImage(url) {
        return !!url && imageExt.test(url) && !badImage.test(url);
    }

    function hashOf(str) {
        let h = 5381;
        for (let i = 0; i < str.length; i++)
            h = ((h << 5) + h + str.charCodeAt(i)) >>> 0;
        return h.toString(16);
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
        // Self-hosted video: look for NASA's own still image for it.
        return Object.assign(base, { findStill: true, videoUrl: j.url || "" });
    }

    function scrapeFallback(force) {
        Proc.runCommand(pid + ".html", ["curl", "-fsSL", "--max-time", "30", "https://apod.nasa.gov/apod/astropix.html"], (html, code) => {
            if (code !== 0)
                return finish("Couldn't reach NASA APOD (curl exit " + code + ")", force);

            const today = Qt.formatDate(new Date(), "yyyy-MM-dd");
            // The day's picture is the link that wraps an <img>; other image/ links are not the APOD.
            const isVideo = /<(video|iframe)\b/i.test(html);
            const img = isVideo ? null : /<a\s+href="(image\/[^"]+\.(?:jpe?g|png|gif|webp))"\s*>\s*<img\s/i.exec(html);
            const title = /<center>\s*<b>\s*([^<]+?)\s*<\/b>/i.exec(html);
            const info = {
                date: today,
                title: title ? title[1] : "Astronomy Picture of the Day",
                explanation: "",
                copyright: "",
                pageUrl: "https://apod.nasa.gov/apod/astropix.html"
            };
            if (img)
                info.url = "https://apod.nasa.gov/apod/" + img[1];
            else if (useVideoThumbs)
                return findStill(Object.assign(info, { videoUrl: "" }), force, html);
            else
                info.skip = "Today's APOD is a video, keeping the current wallpaper";
            handleInfo(info, force);
        }, 0, 45000, root);
    }

    // ---- Video days: find a still image NASA published for the video ----
    function findStill(info, force, html) {
        if (html === undefined) {
            return Proc.runCommand(pid + ".still", ["curl", "-fsSL", "--max-time", "30", "https://apod.nasa.gov/apod/astropix.html"], (page, code) => findStill(info, force, code === 0 ? page : ""), 0, 45000, root);
        }
        const abs = u => /^https?:\/\//i.test(u) ? u : (u.startsWith("//") ? "https:" + u : "https://apod.nasa.gov/apod/" + u.replace(/^\/+/, ""));
        const candidates = [];
        const poster = /<video\b[^>]*\bposter\s*=\s*"([^"]+)"/i.exec(html);
        if (poster)
            candidates.push(abs(poster[1]));
        const og = /<meta[^>]+property\s*=\s*"og:image"[^>]+content\s*=\s*"([^"]+)"/i.exec(html);
        if (og)
            candidates.push(abs(og[1]));
        const vids = [info.videoUrl];
        const src = /<source\b[^>]*\bsrc\s*=\s*"([^"]+)"/i.exec(html) || /<video\b[^>]*\bsrc\s*=\s*"([^"]+)"/i.exec(html);
        if (src)
            vids.push(abs(src[1]));
        for (const v of vids) {
            if (v && videoExt.test(v))
                for (const e of [".jpg", ".jpeg", ".png"])
                    candidates.push(v.replace(videoExt, e));
        }
        const good = candidates.filter((u, i) => isGoodImage(u) && candidates.indexOf(u) === i);
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
        if (info.findStill) {
            delete info.findStill;
            return findStill(info, force);
        }
        if (info.skip) {
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
            const url = root.last.pageUrl || "https://apod.nasa.gov/apod/astropix.html";
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
