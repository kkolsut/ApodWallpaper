import QtQuick
import qs.Common

QtObject {
    function check(done) {
        Proc.runCommand("apodWallpaper.depCheck", ["which", "curl"], (stdout, exitCode) => {
            if (exitCode === 0) {
                done(null);
                return;
            }
            done({
                title: "curl is required",
                details: "APOD Wallpaper uses curl to download images. Install it with your package manager, then re-enable the plugin."
            });
        });
    }
}
