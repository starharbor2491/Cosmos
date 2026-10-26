#!/bin/zsh
# Drives the app with a long random sequence of key presses, page loads, overlays, window sizes and Settings tabs
# through the automation harness, on a throwaway --demo profile, and reports whether it survived.
#
#   scripts/stress.sh [seed] [steps]       defaults: seed 1, 300 steps
#   STRESS_WINDOWS=1 scripts/stress.sh 7 # also opens, closes and incognito-es windows and Probes
#   STRESS_ONLINE=1 scripts/stress.sh 7  # lets the app use the network (favicons, filter lists); offline by default
#
# Builds the debug app first. The app window flickers while it runs; nothing is recorded.
set -euo pipefail
cd "${0:A:h}/.."
SEED=${1:-1}
STEPS=${2:-300}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cosmos-stress.XXXXXX")
swift build >/dev/null
python3 -I - "$SEED" "$STEPS" "$WORK/script.json" <<'PY'
import json, os, random, sys
seed, steps, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
r = random.Random(seed)
urls = ["about:blank?%d", "data:text/html,<h1>hi</h1><script>document.title='t'</script>", "https://example.com", "http://localhost:1/",
        "file:///etc/hosts", "javascript:alert(1)", "view-source:https://example.com", "https://xn--nxasmq6b.com/", "ftp://example.com/",
        "mailto:a@b.c", "tel:123", "https://[::1]/", "about:blank?" + "x" * 20000, "data:text/html,<script>for(;;){}</script>",
        "data:text/html,<script>location.reload()</script>", "data:text/html,<script>window.open('about:blank?pop')</script>",
        "data:text/html,<title>" + "T" * 5000 + "</title>", "https://example.com/%00%ff", "http://0.0.0.0:99999/"]
chords = ["cmd+t", "cmd+w", "cmd+shift+t", "cmd+d", "cmd+alt+d", "cmd+s", "ctrl+1", "ctrl+2", "ctrl+3", "cmd+alt+left", "cmd+alt+right",
          "cmd+alt+up", "cmd+alt+down", "ctrl+tab", "cmd+l", "cmd+f", "cmd+y", "cmd+shift+a", "cmd+shift+j", "cmd+alt+b", "cmd+/", "cmd+r",
          "cmd+shift+r", "cmd+.", "cmd+[", "cmd+]", "cmd+shift+k", "ctrl+shift+=", "ctrl+shift+-", "cmd+1", "cmd+2", "cmd+alt+shift+n",
          "cmd+g", "cmd+shift+g", "cmd+=", "cmd+-", "cmd+0", "cmd+shift+c", "cmd+alt+shift+c", "cmd+,", "esc", "ctrl+shift+tab", "cmd+alt+p"]
if os.environ.get("STRESS_WINDOWS"): chords += ["cmd+n", "cmd+shift+n", "cmd+alt+n", "cmd+shift+w"]
overlays = ["commandBar", "archive", "history", "downloads", "boosts", "welcome", "shortcuts", "siteControls", "find", "theme", "none"]
words = ["", "a", "github", "new space", "mute", "1+1", "((((((", "%%%", "日本語", "🙂", "x" * 3000, "yt cats", "boosts", "javascript:alert(1)", "   "]
keys = ["return", "tab", "escape", "down", "up", "backspace"]
tabs = ["general", "sidebar", "blocking", "extensions", "privacy", "links", "radialMenu", "menuBar", "about"]
sizes = [(320, 240), (200, 120), (800, 600), (1400, 900), (1000, 1000), (2400, 1400), (600, 2000)]
url = lambda: r.choice(urls).replace("%d", str(r.randrange(100000)))
s = [{"do": "wait", "seconds": 1.5}]
for i in range(steps):
    k = r.random()
    if k < 0.18: s.append({"do": "open", "url": url()})
    elif k < 0.24: s.append({"do": "navigate", "url": url()})
    elif k < 0.58: s.append({"do": "chord", "combo": r.choice(chords)})
    elif k < 0.66: s.append({"do": "overlay", "name": r.choice(overlays)})
    elif k < 0.72: s.append({"do": "type", "text": r.choice(words)})
    elif k < 0.78: s.append({"do": "key", "name": r.choice(keys)})
    elif k < 0.82: s.append({"do": "space", "index": r.randrange(1, 5)})
    elif k < 0.84: s.append({"do": "sidebar", "visible": r.random() < 0.5})
    elif k < 0.87: s.append({"do": "peek", "url": url()})
    elif k < 0.88: s.append({"do": "closePeek"})
    elif k < 0.91: s.append({"do": "split"})
    elif k < 0.94: s.append({"do": "select", "tab": r.randrange(0, 8)})
    elif k < 0.96:
        w, h = r.choice(sizes); s.append({"do": "resize", "width": w, "height": h})
    elif k < 0.975: s.append({"do": "settings", "tab": r.choice(tabs)})
    elif k < 0.98: s.append({"do": "closeSettings"})
    elif k < 0.985:
        # a right click anywhere on the page, sometimes with ⌥ (the system menu) or the left button, then the ring is poked at
        s.append({"do": "rightClick", "x": r.randrange(-50, 1500), "y": r.randrange(-50, 1000), "flags": r.choice([0, 0, 0, 524288, 131072]),
                  "hold": r.choice([0, 0.05]), "left": r.random() < 0.15})
        s.append({"do": "radial", "dump": True, "hover": r.randrange(-1, 10)})
        s.append({"do": "radial", r.choice(["choose", "back"]): r.randrange(-1, 10) if r.random() < 0.5 else True})
    elif k < 0.992:
        a = r.choice(["enable", "open", "open", "close", "pin", "go", "go", "configure", "configure", "disable", "state"])
        step = {"do": "menuBar", "action": a}
        if a == "go": step["text"] = r.choice(words + ["github.com", "http://127.0.0.1:1/", "data:text/html,<h1>x</h1>"])
        if a == "configure":
            step["layout"] = r.choice(["phone", "desktop", "bogus"]); step["home"] = r.choice(["", "example.com", "two words", "javascript:alert(1)", "x" * 3000])
            step["remember"] = r.random() < 0.5
        s.append(step)
    elif k < 0.997: s.append({"do": "dropdown", "index": r.randrange(-1, 4)})
    else: s.append({"do": "setTheme", "name": r.choice(["Nebula", "Aurora", "Supernova", "Deep Field", "Pulsar", "Eclipse", "Moondust", "Solstice", "Nope"])})
    s.append({"do": "wait", "seconds": r.choice([0, 0.05, 0.1, 0.2])})
    if i % 25 == 24: s.append({"do": "state"})
s += [{"do": "closeSettings"}, {"do": "state"}, {"do": "wait", "seconds": 2}, {"do": "state"}, {"do": "quit"}]
json.dump(s, open(out, "w"))
PY
NETWORK=(--offline)
[[ -n ${STRESS_ONLINE:-} ]] && NETWORK=()
set +e
perl -e 'alarm 600; exec @ARGV' .build/debug/Cosmos --demo "${NETWORK[@]}" --data-dir "$WORK/data" --automation "$WORK/script.json" >"$WORK/stderr.txt" 2>&1
rc=$?
if (( rc == 0 )); then
  echo "seed $SEED, $STEPS steps: survived ($(grep -c . "$WORK/script.json.log") log lines)"
else
  echo "seed $SEED, $STEPS steps: FAILED with exit code $rc. Last step:"; tail -2 "$WORK/script.json.log"; grep -m1 -E "Terminating|Fatal error|exception" "$WORK/stderr.txt" || tail -3 "$WORK/stderr.txt"
  echo "Everything is in $WORK"; exit 1
fi
rm -rf "$WORK"
