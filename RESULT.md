# RESULT (Codex writes this each turn)

CYCLE: 178
INSTRUCTION_SHA256: 14C9842766D0804E0E68417003A06BA26FF6B92B9C89A39A49DE2E51C84ABD3F
STATUS: DONE

## git
- branch: sash-client05-integration
- HEAD: f325579faa0ccf1518856cd502298a9330ec1cd3
- git status --short: existing modified and untracked files present; no commit made.

## changed files (if any)
- C:\SaSH-relay\logs\cycle-49\runtime\default.json SHA256=not-recorded
- C:\SaSH-relay\logs\cycle-49\runtime\settings\default.json SHA256=not-recorded
- C:\SaSH-relay\out\0178-cycle178-parserLive-facts.md
- C:\SaSH-relay\bus\logs\fastbattle-diag.log

## build (if any)
- toolchain: VS2022 v143 / Release Win32 / Qt 5.15.2 msvc2019 x86 / /MD
- SaSH SHA256: not-recorded (build skipped)   sadll SHA256: 104FB3B0FE834977429C60F8A7218BB2749F3EDD326475E9C4F385785FB42D9D
- warnings: not-recorded   errors: 0
- git diff --check: not-run

## static checks (if any)
- SKIP_LAUNCHER_BUILD.flag: True
- FastBattleBCParse marker: present
- BCunit pos= marker: present
- sadll build: PASS
- SaSH build: SKIPPED

## unified diff (if any)
```
not-recorded
```

## safety self-confirm
- sadll changed: yes (specified human-b1diag-go.ps1 run)
- new client memory write: no
- new client function call: no
- new packet/TCP: no
- PersonalKey exposed/logged: no (readable: no, length: 0)
- default flags changed (RUNTIME_ACTIVATION/SPEED_CONTROL): no
- client started/attached/run: yes
- only handoff/ still untracked: no

## notes / exact error or refusal text (verbatim if BLOCKED/HALTED)
- Configuration written to both default.json files: AutoLogin=true, AutoWalk=true, FastAutoWalk=false, AutoBattle=false, FastBattle=true, ShowExp=true, SpeedBoost=14, AutoWalkDistance=5, AutoWalkDelay=0.
- Start: explicit left click at (1443,674); SA93Client present (PID 1524) after 5 seconds.
- Observation: 120 seconds. fastbattle-hook install ok=3 enTr=0F240000 bTr=0F260000
- BCunit pos= count: 0
- BCunit first 8: none
- B fd= head=BC| first 3: none
- EN fd= count: 0
- Crash: N
- Screenshots: none; no encounter/battle occurred during the 120-second observation.
- Logs copied to C:\SaSH-relay\out and C:\SaSH-relay\bus\logs.
- Teardown: WM_CLOSE sent; no SA93Client or SaSH-client05-cleanup-validation process remained.
