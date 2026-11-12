// Spicetify extension for the Spotify wallpaper widget: links Spotify to the widget.
//  - volume: tells the widget the volume slider's position and takes the volume the widget asks for;
//  - heart: tells the widget whether the playing song is in Liked Songs and adds / removes it when asked.
// A few times a second it asks the widget on http://localhost:47123 (only on this computer);
// with no widget running it does nothing.
(function widgetLink() {
    if (!(window.Spicetify && Spicetify.Player && Spicetify.Player.getVolume)) {
        setTimeout(widgetLink, 500);
        return;
    }
    const url = "http://localhost:47123/spotify-volume";
    let busy = false, misses = 0;
    function liked() {
        try {
            const h = Spicetify.Player.getHeart ? Spicetify.Player.getHeart() : undefined;
            return h === true ? "1" : h === false ? "0" : "";
        } catch (e) { return ""; }
    }
    async function tick() {
        if (busy) return;
        busy = true;
        try {
            const cur = Spicetify.Player.getVolume();
            const r = await fetch(url + "?cur=" + cur.toFixed(3) + "&liked=" + liked(), { cache: "no-store" });
            const j = await r.json();
            if (typeof j.set === "number") Spicetify.Player.setVolume(Math.max(0, Math.min(1, j.set)));
            if (j.toggleHeart && Spicetify.Player.toggleHeart) Spicetify.Player.toggleHeart();
            misses = 0;
        } catch (e) {
            misses++;   // widget not running
        } finally {
            busy = false;
        }
    }
    // Fast while the widget answers, slow (every 3 s) while it does not.
    (function loop() { tick().finally(() => setTimeout(loop, misses > 3 ? 3000 : 120)); })();
})();
