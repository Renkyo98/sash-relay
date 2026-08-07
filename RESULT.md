# RESULT (Codex writes this each turn)

CYCLE: 162
INSTRUCTION_SHA256: 9CC814DC3A27A1E5FA182D042A6733F47E86399D57792970B50AD90F6C9E8EEE
STATUS: DONE

## git

- branch: main (C:\SaSH-relay\bus)
- HEAD: 247b234c30f61767af8175b26d67c2f54c916cb6
- git status --short (before reports):
```
 M artifacts/fastbattle-core/fastbattle-diag.log
?? artifacts/fastbattle-core/autobattle-diag-155.log
?? artifacts/fastbattle-core/fastbattle-core-01-30s.png
?? artifacts/fastbattle-core/fastbattle-core-02-60s.png
```

## changed files (if any)

- bus/artifacts/fastbattle-core/fastbattle-diag.log
- bus/artifacts/fastbattle-core/autobattle-diag-155.log
- bus/artifacts/fastbattle-core/fastbattle-core-01-30s.png
- bus/artifacts/fastbattle-core/fastbattle-core-02-60s.png
- RESULT.md; out/0162-cycle162-fastbattle-core4-facts.md
- commit hash if committed: none

## build (if any)

- SaSH: build SKIPPED (SKIP_LAUNCHER_BUILD.flag); sadll build: OK
- deployed sadll SHA256: 94F39A8984714EA2B1D1DBF0FC9C259888780548E3686A8D0BF17DB38A949E37
- warnings: not reported; errors: 0

## static checks (if any)

- preflight markers / SKIP flag: PASS
- FASTBATTLE159: FAIL

## FASTBATTLE159 stdout (verbatim)

```
FASTBATTLE159: log=C:\zmffk\fastbattle-diag.log mtimeUtc=2026-08-07T10:40:39.4219571Z
FASTBATTLE159: install_ok3=2 fastdrive=8 fbstate=181 procN==10=0 battlingSeen=0 SAFETY=2
FASTBATTLE159: exp-result(EXP gained)=0
--- last 20 fastbattle-diag lines ---
fbstate procN=9 battling=0 active=0 turn=4 anim=0
fbstate procN=9 battling=0 active=0 turn=4 anim=0
fbstate procN=9 battling=0 active=0 turn=4 anim=0
fbstate procN=9 battling=0 active=0 turn=4 anim=0
fbstate procN=9 battling=0 active=0 turn=4 anim=0
fbstate procN=9 battling=0 active=0 turn=4 anim=0
fbstate procN=9 battling=0 active=0 turn=4 anim=0
fbstate procN=9 battling=0 active=0 turn=4 anim=0
fbstate procN=9 battling=0 active=0 turn=4 anim=0
fbstate procN=9 battling=0 active=0 turn=4 anim=0
fbstate procN=9 battling=0 active=0 turn=4 anim=0
fbstate procN=9 battling=0 active=0 turn=4 anim=0
fbstate procN=9 battling=0 active=0 turn=4 anim=0
fbstate procN=9 battling=0 active=0 turn=4 anim=0
fbstate procN=9 battling=0 active=0 turn=4 anim=0
fbstate procN=9 battling=0 active=0 turn=4 anim=0
fbstate procN=9 battling=0 active=0 turn=4 anim=0
fbstate procN=9 battling=0 active=0 turn=4 anim=0
fbstate procN=9 battling=0 active=0 turn=4 anim=0
fbstate procN=9 battling=0 active=0 turn=4 anim=0
--- end ---
FASTBATTLE159: FAIL
REASON: EXP < 3 (battles not resolving / RS blocked / drive not killing enemies).
```

## notes

- config readback, both default.json: FastBattleEnable=true; FastAutoWalkEnable=true; AutoBattleEnable=false; AutoLoginEnable=true; AutoWalkEnable=false; ShowExpEnable=true; SpeedBoostValue=14; AutoWalkDelayValue=0.
- Start invoked once; client PID 6436 remained running through the 60-second observation. Crash: no observed.
- turn advanced beyond 1: yes (turn=4).
- screenshots: C:\SaSH-relay\bus\artifacts\fastbattle-core\fastbattle-core-01-30s.png; C:\SaSH-relay\bus\artifacts\fastbattle-core\fastbattle-core-02-60s.png.
- teardown: WM_CLOSE followed by scoped client/launcher termination; remaining scoped processes=0.

## safety self-confirm

- sadll changed: yes (built/deployed by instruction)
- new client memory write: no
- new client function call: no
- new packet/TCP: no
- PersonalKey exposed/logged: no (not inspected; readable=no; length=n/a)
- default flags changed (RUNTIME_ACTIVATION/SPEED_CONTROL): no; requested values were already present in both files
- client started/attached/run: yes
- only handoff/ still untracked: yes, bus artifacts listed above
