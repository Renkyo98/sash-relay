# RESULT

CYCLE: 151
INSTRUCTION_SHA256: EEB81821D4BF50BB74469E881BDB555A620B6A0A0AC72A22517BF263E68713BB
STATUS: DONE

## git
- branch: N/A (`C:\SaSH-relay` is not a git repository)
- HEAD: N/A
- git status --short: `fatal: not a git repository (or any of the parent directories): .git`

## changed files (if any)
- runtime/default.json: AutoWalkEnable true -> false
- runtime/settings/default.json: AutoWalkEnable true -> false
- C:\SaSH-relay\out\blackwatch.log SHA256=8610BF81966C26B91DC096B8E05A0EFB6AE9C066E6681841F09A096624A13F8D
- C:\SaSH-relay\bus\blackwatch.log copied
- commit hash: none (no commit)

## build (if any)
- toolchain: VS2022 v143 / Release Win32 / Qt 5.15.2 msvc2019 x86 / /MD
- SaSH SHA256: not reported by build script; sadll SHA256: 41CBA5150194B51D8B1BF6ACE156D0CF9D9CA75496C26330CFB7913B810BB3AE
- warnings: not reported; errors: 0
- git diff --check: N/A (not a git repository)

## static checks (if any)
- preflight markers: PASS (BlackWatch=11, blackWatchProc=4, F0 boost FAITHFUL=1, *noDrawMax = =2)
- logger sanity: PASS

## unified diff (if any)
```
N/A (no git repository)
```

## blackwatch validation facts
- config readback, both files: SpeedBoostValue=14; AutoWalkEnable=false; FastAutoWalkEnable=false; AutoLoginEnable=true; AutoBattleEnable=true
- blackwatch.log path: C:\zmffk\blackwatch.log
- copied to: C:\SaSH-relay\out\blackwatch.log and C:\SaSH-relay\bus\blackwatch.log
- log lines: 77; ` HB ` lines: 75; `GAP-START` lines: 1
- first HB (verbatim): `12:09:21.309 HB fps=13 frame=16 ndc=1 ndmax=14 sys=1 proc=5 gsf=0 pos=(434,424)`
- last HB (verbatim): `12:10:35.314 HB fps=65 frame=4810 ndc=2 ndmax=14 sys=1 proc=5 gsf=0 pos=(434,424)`
- frame advanced: yes (16 -> 4810)
- observed on HB: ndmax=14; sys=1
- crash check: no crash observed; client responded before instructed teardown
- teardown: WM_CLOSE sent to launcher; client PID 9108 terminated if still present; target processes confirmed absent

## safety self-confirm
- sadll changed: yes (built and deployed)
- new client memory write: no
- new client function call: no
- new packet/TCP: no new originated packet beyond existing authorized auto-login feature
- PersonalKey exposed/logged: no
- default flags changed (RUNTIME_ACTIVATION/SPEED_CONTROL): no
- client started/attached/run: yes, once
- only handoff/ still untracked: no

## notes / exact error or refusal text (verbatim if BLOCKED/HALTED)
Build exited 0. Both configured default.json files were updated before launch. Deployed build remains on disk for the owner's manual reproduction.
