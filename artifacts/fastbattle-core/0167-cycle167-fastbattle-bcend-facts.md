# Cycle 167 fastbattle BC-end raw facts

INSTRUCTION_SHA256: 07B7E1ADA85DFE60B7EEAAF139122528C588F8FBE529077312F4BAEC37CAC668
STATUS=DONE

sadll SHA256: 38F0541A7F0C9FA7AA8618C9FB79371618EAC456FACDBCC09367980732513825
install ok=7
crash: no (client present at 35 s and 70 s; teardown completed)
screenshots:
- C:\SaSH-relay\bus\artifacts\fastbattle-core\cycle167-35s.png
- C:\SaSH-relay\bus\artifacts\fastbattle-core\cycle167-70s.png
safety self-confirm: SAFETY=0; PersonalKey readable: no; length: 0

FASTBATTLE159 stdout:
```text
FASTBATTLE159: log=C:\zmffk\fastbattle-diag.log mtimeUtc=2026-08-07T12:04:53.2228324Z
FASTBATTLE159: install_ok7=1 RSrecv=14 fastdrive=41 fbstate=94 procN==10=0 battlingSeen=0 SAFETY=0
FASTBATTLE159: exp-result(EXP gained)=0
--- last 20 fastbattle-diag lines ---
fbstate procN=9 battling=0 active=0 turn=3 anim=0 resultWnd=0
fbstate procN=9 battling=0 active=0 turn=3 anim=0 resultWnd=0
fbstate procN=9 battling=0 active=0 turn=3 anim=0 resultWnd=0
fbstate procN=9 battling=0 active=0 turn=3 anim=0 resultWnd=0
fbstate procN=9 battling=0 active=0 turn=3 anim=0 resultWnd=0
fbstate procN=9 battling=0 active=0 turn=3 anim=0 resultWnd=0
fbstate procN=9 battling=0 active=0 turn=3 anim=0 resultWnd=0
fbstate procN=9 battling=0 active=0 turn=3 anim=0 resultWnd=0
fbstate procN=9 battling=0 active=0 turn=3 anim=0 resultWnd=0
fbstate procN=9 battling=0 active=0 turn=3 anim=0 resultWnd=0
fbstate procN=9 battling=0 active=0 turn=3 anim=0 resultWnd=0
fbstate procN=9 battling=0 active=0 turn=3 anim=0 resultWnd=0
fbstate procN=9 battling=0 active=0 turn=3 anim=0 resultWnd=0
fbstate procN=9 battling=0 active=0 turn=3 anim=0 resultWnd=0
fbstate procN=9 battling=0 active=0 turn=3 anim=0 resultWnd=0
fbstate procN=9 battling=0 active=0 turn=3 anim=0 resultWnd=0
fbstate procN=9 battling=0 active=0 turn=3 anim=0 resultWnd=0
fbstate procN=9 battling=0 active=0 turn=3 anim=0 resultWnd=0
fbstate procN=9 battling=0 active=0 turn=3 anim=0 resultWnd=0
fbstate procN=9 battling=0 active=0 turn=3 anim=0 resultWnd=0
--- end ---
FASTBATTLE159: FAIL
REASON: EXP < 3 (battles not resolving / RS blocked / drive not killing enemies).
```

RS-recv lines (verbatim):
```text
RS-recv fd=2648 len=19 data=-2|0|6,1|0|6,,,,|||
RS-recv fd=2648 len=19 data=-2|0|4,1|0|4,,,,|||
RS-recv fd=2648 len=19 data=-2|0|8,1|0|8,,,,|||
RS-recv fd=2648 len=19 data=-2|0|a,1|0|a,,,,|||
RS-recv fd=2648 len=19 data=-2|0|4,1|0|4,,,,|||
RS-recv fd=2648 len=19 data=-2|0|4,1|0|4,,,,|||
RS-recv fd=2648 len=19 data=-2|0|6,1|0|6,,,,|||
RS-recv fd=2648 len=19 data=-2|0|4,1|0|4,,,,|||
RS-recv fd=2648 len=19 data=-2|0|8,1|0|8,,,,|||
RS-recv fd=2648 len=19 data=-2|0|8,1|0|8,,,,|||
RS-recv fd=2648 len=19 data=-2|0|4,1|0|4,,,,|||
RS-recv fd=2648 len=19 data=-2|0|2,1|0|2,,,,|||
RS-recv fd=2648 len=19 data=-2|0|8,1|0|8,,,,|||
RS-recv fd=2648 len=19 data=-2|0|6,1|0|6,,,,|||
```

fastbattle-end(bc) lines (verbatim):
```text
fastbattle-end(bc) enemyCount=0 myPos=0 -> EO bfd=A58
fastbattle-end(bc) enemyCount=0 myPos=0 -> EO bfd=A58
fastbattle-end(bc) enemyCount=0 myPos=0 -> EO bfd=A58
fastbattle-end(bc) enemyCount=0 myPos=0 -> EO bfd=A58
fastbattle-end(bc) enemyCount=0 myPos=0 -> EO bfd=A58
fastbattle-end(bc) enemyCount=0 myPos=0 -> EO bfd=A58
fastbattle-end(bc) enemyCount=0 myPos=0 -> EO bfd=A58
fastbattle-end(bc) enemyCount=0 myPos=0 -> EO bfd=A58
fastbattle-end(bc) enemyCount=0 myPos=0 -> EO bfd=A58
fastbattle-end(bc) enemyCount=0 myPos=0 -> EO bfd=A58
fastbattle-end(bc) enemyCount=0 myPos=0 -> EO bfd=A58
fastbattle-end(bc) enemyCount=0 myPos=0 -> EO bfd=A58
fastbattle-end(bc) enemyCount=0 myPos=0 -> EO bfd=A58
fastbattle-end(bc) enemyCount=0 myPos=0 -> EO bfd=A58
```

fastbattle-end(bc) count: 14
fastdrive(pkt) count: 41
fastdrive(pkt) turn values: 0,1,2,0,1,0,1,2,3,0,1,2,3,4,5,0,1,0,1,0,1,2,0,1,0,1,2,0,1,2,3,0,1,0,0,1,2,3,0,1,2
turn advances across battle: yes
procN==10: 0
SAFETY: 0
