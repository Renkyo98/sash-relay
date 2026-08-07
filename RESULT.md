# RESULT

CYCLE: 152
INSTRUCTION_SHA256: 04129B5E2A27CBAA9A0B463C0796A9E5FB17C01DFD00D7F245E405F51B9FD8FC
STATUS: DONE (PASS)

## build / config

- deployed sadll SHA256: AA97A4857F3DA8D4EED55F80C1C4AF1E1F36700E65D3F3CB052895C9A4F52B4A
- `runtime/default.json`: SpeedBoostValue=14; AutoWalkEnable=False.
- `runtime/settings/default.json`: SpeedBoostValue=14; AutoWalkEnable=False.
- 두 파일 모두: AutoLoginEnable=True, FastAutoWalkEnable=False, AutoBattleEnable=True.

## BlackWatch v2

- blackwatch.log: `C:\zmffk\blackwatch.log`; 사본은 `C:\SaSH-relay\out\blackwatch.log` 및 `C:\SaSH-relay\bus\blackwatch.log`.
- HB count: 89.
- FIRST HB: `12:59:29.994 HB fps=14 frame=17 ndc=3 ndmax=14 sys=1 proc=5 gsf=0 floor=31501 rbl=0 wbl=0 snd=0 sock=2628 pos=(6,111)`
- LAST HB: `13:00:57.990 HB fps=65 frame=5717 ndc=1 ndmax=14 sys=1 proc=5 gsf=0 floor=31501 rbl=0 wbl=0 snd=0 sock=2628 pos=(6,111)`
- frame advance: yes (17 -> 5717).
- observed socket: 2628; observed floor: 31501. PASS 조건 충족.
- crash check: 관찰 중 응답 상태였고 크래시 없음.

## safety self-confirm

- PersonalKey exposed/logged: no (readable: no; length: 0).
- 소유 오프라인 로컬 launcher/client만 사용.
- 새 패킷 전송 없음; 지정된 기존 로그인·boost 동작만 사용.
- teardown: launcher WM_CLOSE, client PID 5664 종료, 대상 프로세스 부재 확인.
- deployed exe/dll 삭제 안 함.
