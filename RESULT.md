# RESULT

CYCLE: 184
INSTRUCTION_SHA256: C453B8E09A588D4C16F49C4A6CC41B5E31183A2540853551A778B234ECF2156E
STATUS: DONE

## git
- branch: sash-client05-integration
- HEAD: f325579faa0ccf1518856cd502298a9330ec1cd3
- git status --short: pre-existing dirty worktree; source/flag/commit changes not made in this cycle.

## changed files (if any)
- runtime default.json (two files): FastBattleEnable=true, AutoBattleEnable=false, AutoEscapeEnable=false, FastAutoWalkEnable=true, AutoWalkEnable=false, SpeedBoostValue=14, AutoWalkDelayValue=0.
- RESULT.md and out/0184-fastbattle-pure.md written.

## build (if any)
- not run

## safety self-confirm
- sadll changed: no
- new client memory write: no
- new client function call: no
- new packet/TCP: no
- PersonalKey exposed/logged: no (readable: no; length: 0)
- default flags changed (RUNTIME_ACTIVATION/SPEED_CONTROL): no
- client started/attached/run: yes
- only handoff/ still untracked: no

## raw facts
- RUN_SINCE_ISO: 2026-08-08T08:48:35.3071594+09:00
- FBCHAN: 20 lines fb=1 ab=0; 4 lines fb=0 ab=1.
- EN fd nonzero: 2.
- BCunit: 44.
- autobattle CHAR: 50; fn1: 6; fn4909D0: 34.
- exp-result: 10.
- fastautowalk nonzero positions: 142,376; 156,378; 155,378.
- fresh sa.dmp since RUN_SINCE_ISO: no.
- screenshot: C:\SaSH-relay\logs\human-ctrlinit\run-185\cycle185-battlestatus.png
- assert exit code: 1.

## assert output (verbatim)
```
=== PASS items ===
  OK  encounter EN fd nonzero x2
  OK  BCunit parsed x44
  OK  CHAR drive x50
  OK  fake-entity fn1 present x6
  OK  exp-result x10
  OK  no fresh crash dump
=== FAIL items ===
  FAIL FBCHAN contaminated: 4 line(s) not fb=1 ab=0 (e.g. 'FBCHAN faw=1 aw=0 fb=0 ab=1')
  FAIL REAL scene entity fn4909D0 present x34 -> char entered real battle (auto-battle contamination)
  FAIL char MOVED across 3 positions: 142,376 156,378 155,378
ASSERT: FAIL (3)
```
