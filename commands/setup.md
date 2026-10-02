---
description: Check this Mac and set up hey2agent (dependencies, speech model, panel, voice mode)
---
Set up the hey2agent plugin on this Mac. Work step by step, explain briefly in the user's language, and
**ask before installing anything or downloading large files**.

1. Locate the plugin directory: it is `${CLAUDE_PLUGIN_ROOT}` if that is set, otherwise find the folder
   that contains `voice_loop.py` under `~/.claude/plugins/`. Use that path below as PLUGIN.
2. Check requirements: macOS 15+ (`sw_vers`), Apple silicon (`uname -m` = arm64), `python3`, Homebrew,
   `whisper-cli` and `ffmpeg`. If `whisper-cli` or `ffmpeg` is missing, offer `brew install whisper-cpp ffmpeg`.
3. If hey2agent hooks were previously added manually to `~/.claude/settings.json` (commands containing
   `voice_loop.py`), offer to remove them with `python3 PLUGIN/voice_loop.py uninstall` — the plugin
   provides the hooks now, and duplicates would run twice.
4. Speech model: run `python3 PLUGIN/voice_loop.py models`. If none is marked ✓, show the list and let
   the user pick (turbo = best for mixed Russian/English, turbo-q5 = lighter, small/base/tiny = faster),
   then `python3 PLUGIN/voice_loop.py download-model <id>` (it resumes if interrupted).
5. Run `python3 PLUGIN/voice_loop.py setup` (records the script location for the panel) and
   `python3 PLUGIN/voice_loop.py on`.
6. Panel (optional but recommended): needs the Swift toolchain (`xcode-select -p`). Run `PLUGIN/HUD/build.sh`
   and `open ~/Applications/VoiceLoopHUD.app`.
7. Tell the user what to expect: when a turn ends they hear a short summary and a *tink*, then speak;
   a 2-second pause sends. macOS will ask for microphone access for the app that runs Claude Code (and for
   the panel the first time they dictate from it) — they must click Allow themselves.
   Mention `python3 PLUGIN/voice_loop.py off` / `mute` and the panel settings.
