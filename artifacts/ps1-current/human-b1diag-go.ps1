<#
  human-b1diag-go.ps1  (v24)  --  HUMAN CHAIN cumulative build.
  v14 change: POS DIAGNOSTIC (character-slot). At the real Client05 auto-login
    call site (mainthread B1 loop, procNo==1), log the srv/sub/chr actually read
    from getValueHash(kServerValue/kSubServerValue/kPositionValue) right before
    requestClient05AutoLogin. Purpose: prove whether the launcher UI pos (left/right)
    reaches chr at login time, or whether chr is always 0 (UI->hash write missing).
    Writes C:\zmffk\pos-diag-NNN.log. Read by Claude; numbered (no overwrite).
  v15 change: LANDING SAMPLER. Proven via readonly log that our path writes+verifies
    kPcLandedCharacter=pos (character=1 for pos=right). Disasm shows selectCharacter
    (0x44CC33) uses gChar as the slot index WHEN gEnable(0xBCDD800)!=0, and selectServer/
    selectGroup do NOT clear gEnable. Yet the client still lands the last character. To
    catch the runtime divergence, the monitor thread now samples procNo + landed group/
    subserver/character + enable every change and logs C:\zmffk\landing-diag-NNN.log.
  v16 change: POS RE-ARM ON RECONNECT. Proven (landing-diag-013): fresh client launch
    honors pos (char=-1 reset -> our write), but a logout->reconnect WITHIN the same
    client session keeps the stale landed char because the launcher autologin gate did
    not re-fire. Block A now detects the rising edge into the login screen (procNo==1),
    re-arms the publish counters, and logs LOGINSCR edge (alEnabled + current pos) so the
    reconnect gate state is captured. Republishes the CURRENT pos on every login screen.
  v17 change: RECONNECT ROUTES THROUGH PASSWORD SCREEN. Proven (landing-diag-014):
    a same-session logout->reconnect goes procNo 9->7->2->6->9 and NEVER hits procNo==1,
    so the client self-progresses with the stale landed char (gEnable stayed 1). The
    owner's manual 'uncheck+recheck autologin' works because clearing gEnable forces the
    client to stop at procNo==1, where Block A re-publishes the CURRENT pos. Automate it:
    the monitor now clears gEnable once in-world (procNo==9) too (not only when want==0),
    so every subsequent logout lands on procNo==1 and picks up the current pos.
  v18 change: DISCONNECT PROBE. Reconnect groundwork. State::disconnected in the launcher
    == sockfd==0. To see what the client does on a real disconnect (does it return to
    procNo==1 on its own, or stick on an alarm dialog), the landing sampler now also logs
    sockfd, subProcNo, and the dialog globals windowType/buttonType. One disconnect test
    then reveals the full transition + the alarm-dialog signature to dismiss natively.
  v19 change: RECONNECT (auto-confirm disconnect dialog). Proven (landing-diag-017):
    a server drop shows the LOCAL client dialog at procNo==11 ('...연결이 종료...확인');
    once its OK button is clicked the client returns to procNo==1 and auto-login re-connects.
    sockfd stays non-zero at procNo==11 so getUnloginStatus reports Unknown (not Disconnect),
    hence login()'s legacy disconnect path never fires for B1. Port the legacy mechanism
    (leftDoubleClick 315,270, config-overridable) into the mainthread B1 loop, gated by
    kAutoReconnectEnable, triggered on procNo==11. Fully hands-free reconnect.
  v20 change: RESOLUTION-AWARE OK button. sa_8001 was 640x480 so the legacy disconnect
    OK-click was (315,270). Client05 runs 800x600 (or 1024x768), so the fixed coord misses.
    The StoneAge disconnect dialog is a fixed sprite CENTERED in the client area, so the OK
    button offset from window center is constant: (-5,+30) as calibrated from 640x480
    (315-320, 270-240). Read the live client size via GetClientRect and click
    (w/2-5, h/2+30) -> correct at any resolution. Logs the measured win size + coord.
  v21 change: RECONNECT proc=11 diagnostic (gate stays kAutoReconnectEnable ONLY, separate
    from AutoLogin). run-018 config had AutoReconnectEnable=False. Question to answer: while
    the alarm is up (procNo==11) and reconnect is checked LIVE, does getEnableHash(reconnect)
    flip to 1 in the mainthread B1 loop and fire the click? Log on procNo==11 ENTRY *and*
    whenever the reconnect hash CHANGES while at procNo==11 (so a live toggle is captured),
    with the measured window + computed OK coord. Click fires only on kAutoReconnectEnable.
  v22 change: RECONNECT OK-button coordinate. v21 proved the mechanism works (mainthread
    sees procNo==11, the reconnect hash flips live to rc=1, the click fires) but the coord
    (395,330 at 800x600) MISSED the OK button. Measured the actual Client05 dialog sprite
    (328x157 crop): '확인' centroid at (161,137), i.e. dialog-center + (~-3,+59). v20's +30
    was the wrong (legacy sa_8001) offset. Since dialog centering isn't 100% certain, click
    a vertical SWEEP x=w/2-3, y=h/2+20..+100 (OK-button band; stray clicks on the disconnect
    dialog are harmless) so it reliably lands. On success procNo leaves 11 -> auto-login reconnects.
  v23 change: RECONNECT click method = real OS mouse event. Full 800x600 screenshot pins
    the '확인' text centroid at (395,330) == client-center + (-5,+30); v20's coord was right
    all along. The failure was the CLICK METHOD: leftDoubleClick posts WM_LBUTTONDBLCLK
    (Client05 ignores it) and leftClick writes legacy mouse globals (0x45F1B98/9C/BC4) that
    the rebuilt SA93Client does NOT reference (0 xrefs) -> no effect. Manual clicks work, so
    the client honors REAL OS input. Fix: ClientToScreen(okx,oky) + SetCursorPos + mouse_event
    LEFTDOWN/UP, then restore the cursor. Coord (cw/2-5, ch/2+30): 800x600=(395,330),
    1024x768=(507,414). Gate = kAutoReconnectEnable only.
  v24 change: RECONNECT via the client's OWN native mechanism (no mouse sim). Client source
    (field.cpp disconnectServer + gamemain) shows the disconnect dialog auto-dismisses when
    the client global 自动登陆是否开启 != 0 -- and the map proves that global IS 0xBCDD800,
    the same kNewAutoLoginEnable we already drive (PcLanded==0xBCDD748 too). disconnectServer
    @0x42DD56 reads it. So: add a launcher AutoReconnect signal (channel reconnectRequested),
    and in the monitor set 0xBCDD800=1 at procNo==11 when reconnect is on -> the client closes
    the dialog and re-logs-in via PcLanded (current pos). All mouse-click code removed.
  v12 change: AUTO-LOGIN checkbox gating. The client has its OWN auto-login enable
    global (kNewAutoLoginEnableRva 0x0B8DD800); once a login sets it to 1 the client
    self-logs-in on the password screen regardless of the launcher checkbox. Fix: when
    launcher kAutoLoginEnable is OFF, the monitor thread clears that client global to 0
    on the password screen (guardedWriteLoginField). ON is left to processAutoLoginCommand.
    Writes C:\zmffk\autologin-diag.log (want + client enable before->after).
  v11 change: NATIVE BOOST (launcher SpeedBoost 0~14). Mirrors the mute path:
    channel field boostRequested -> gamedevice.setClient05BoostRequested(level) ->
    mainthread B1-loop reads util::kSpeedBoostValue -> monitor thread writes the two
    adjacent gamemain.obj globals SystemTime(RVA 0x171520) + NO_DRAW_MAX_CNT(RVA 0x171518).
    Mapping: boost 0 = normal (SystemTime 14, NO_DRAW_MAX_CNT 2); boost 1..14 =
    SystemTime 15-boost (down to 1) with NO_DRAW_MAX_CNT 14. Endpoints owner-verified.
    Writes C:\zmffk\boost-diag.log on every boost transition (level + before/after).
  v10 change: battle read roster-persist — when the client momentarily empties its
    BattleStatus "BC|" buffer (header-only, no unit tokens), keep the last non-empty
    roster and refresh only the live scalars, so battle units don't flicker away.
  Fixes: crash/window/control-init/resolveUiThread/transport-socket  +  auto-login trigger
         +  NATIVE FULL MUTE (BGM + SE)  +  per-step B1 diag.
  Native mute = the client's own WM_EnableSound path ported to Client05:
    zero t_music_se_volume(base+0x194108) + t_music_bgm_volume(base+0x19410C),
    re-apply via the client's bgm_volume_change(base+0xA9FA0). Addresses verified
    against the deployed SA93Client.exe (build 756a90d6, fixed base 0x400000).
  v9 change: mute is applied CONTINUOUSLY on the client-side read-only monitor
    thread (client_runtime_diagnostics.cpp), NOT via the play_se detour -- so it
    works even when no sound effect is playing. Writes C:\zmffk\mute-diag.log
    on every mute transition (want + volume before/after) for auditing.
  BOM-safe source writes. Numbered outputs under logs\human-ctrlinit\run-NNN\.
  You press Start, test (toggle the launcher 'mute/屏蔽聲音' checkbox: BGM+SE both go silent), close.
#>
$ErrorActionPreference = 'Stop'
function Say($m){ Write-Host $m -ForegroundColor Cyan }
function Warn($m){ Write-Host $m -ForegroundColor Yellow }
function Good($m){ Write-Host $m -ForegroundColor Green }
$utf8bom = New-Object System.Text.UTF8Encoding($true)

$repoSaSH = 'C:\src\etc-source-local\SaSH-master'
$repoRoot = 'C:\src\etc-source-local'
$hdr   = Join-Path $repoSaSH 'common\client05_readonly_protocol.h'
$sadll = Join-Path $repoSaSH 'sadll\sadll.cpp'
$mth   = Join-Path $repoSaSH 'SaSH\mainthread.cpp'
$tad   = Join-Path $repoSaSH 'sadll\client05_transport_adapter.cpp'
$gdh   = Join-Path $repoSaSH 'SaSH\gamedevice.h'
$gdc   = Join-Path $repoSaSH 'SaSH\gamedevice.cpp'
$diag  = Join-Path $repoSaSH 'sadll\client_runtime_diagnostics.cpp'
$afk   = Join-Path $repoSaSH 'SaSH\form\afkform.cpp'
$deploy = Join-Path $repoSaSH 'deploy'
$run    = 'C:\SaSH-relay\logs\cycle-49\runtime'
$exeDst = 'C:\SaSH-relay\logs\cycle-49\runtime\SaSH-client05-cleanup-validation.exe'
$props  = 'C:\SaSH-relay\activation-on.props'
$baseDir = 'C:\SaSH-relay\logs\human-ctrlinit'
$diagLog = 'C:\zmffk\b1-step-diag.log'
New-Item -ItemType Directory -Force -Path $baseDir | Out-Null
$nums = Get-ChildItem "$baseDir\run-*" -Directory -ErrorAction SilentlyContinue | ForEach-Object { if ($_.Name -match 'run-(\d+)$') { [int]$Matches[1] } }
$N = 1; if ($nums) { $N = [int](($nums | Measure-Object -Maximum).Maximum) + 1 }
$tag = '{0:000}' -f [int]$N
$runDir = Join-Path $baseDir "run-$tag"; New-Item -ItemType Directory -Force -Path $runDir | Out-Null
Good "=== RUN $tag -> $runDir ==="

# ---- kill any running launcher/client so the build+deploy can overwrite the exe/dll ----
Say 'stopping running SaSH-client05-cleanup-validation.exe / SA93Client.exe (if any)...'
Get-Process -Name 'SaSH-client05-cleanup-validation' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process -Name 'SA93Client' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 700

Say 'reverting target sources to clean HEAD...'
& git -C $repoRoot checkout -- 'SaSH-master/common/client05_readonly_protocol.h' 'SaSH-master/sadll/sadll.cpp' 'SaSH-master/SaSH/mainthread.cpp' 'SaSH-master/sadll/client05_transport_adapter.cpp' 'SaSH-master/SaSH/gamedevice.h' 'SaSH-master/SaSH/gamedevice.cpp' 'SaSH-master/sadll/client_runtime_diagnostics.cpp' 'SaSH-master/SaSH/form/afkform.cpp' 'SaSH-master/SaSH/util.h' 'SaSH-master/SaSH/form/afkform.ui' 2>&1 | Out-Null

# ---- [BuildProvenance] snapshot the exact clean-HEAD sources being patched+compiled this build ----
# Lets Claude stage the SAME bytes the script builds from (eliminates working-tree-vs-HEAD analysis drift).
$snapDir = 'C:\SaSH-relay\srcsnapshot'
New-Item -ItemType Directory -Force -Path $snapDir | Out-Null
$provOut = @("build=run-$tag", ("when=" + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
foreach ($pf in @($hdr,$sadll,$mth,$tad,$gdh,$gdc,$diag,$afk)) {
  $bn = Split-Path $pf -Leaf
  Copy-Item $pf (Join-Path $snapDir $bn) -Force
  $provOut += ('{0} size={1} sha={2}' -f $bn, (Get-Item $pf).Length, (Get-FileHash $pf -Algorithm SHA256).Hash.Substring(0,16))
}
Set-Content -Path (Join-Path $snapDir 'build-info.txt') -Value $provOut -Encoding UTF8
Good "build provenance (clean-HEAD snapshot) written to $snapDir  [run-$tag]"

# ---- protocol.h : control-init + mute channel field ----
$txt = [IO.File]::ReadAllText($hdr)
if ($txt -notmatch 'control\.magic\s*=\s*client05_control::kMagic') {
  $rep = "channel->context = context;`r`n`tchannel->control.magic = client05_control::kMagic;`r`n`tchannel->control.version = client05_control::kVersion;`r`n`tchannel->control.size = static_cast<std::uint16_t>(sizeof(client05_control::ControlBlock));`r`n`treturn true;"
  $txt = [regex]::Replace($txt, 'channel->context = context;\s+return true;', $rep, [System.Text.RegularExpressions.RegexOptions]::Singleline)
  if ($txt -notmatch 'control\.magic\s*=\s*client05_control::kMagic') { throw "control-init patch failed." }
  Good 'applied control-init'
}
if ($txt -notmatch 'muteRequested') {
  $txt = $txt.Replace("client05_control::ControlBlock control{};", "client05_control::ControlBlock control{};`r`n`tvolatile LONG muteRequested = FALSE;")
  $txt = $txt.Replace("static_assert(sizeof(Channel) == 947776u);", "static_assert(sizeof(Channel) >= 947776u);")
  if ($txt -notmatch 'muteRequested') { throw "mute channel-field patch failed." }
  Good 'applied mute channel field'
}
if ($txt -notmatch 'boostRequested') {
  $txt = $txt.Replace("volatile LONG muteRequested = FALSE;", "volatile LONG muteRequested = FALSE;`r`n`tvolatile LONG boostRequested = 0;")
  if ($txt -notmatch 'boostRequested') { throw "boost channel-field patch failed." }
  Good 'applied boost channel field'
}
if ($txt -notmatch 'autoLoginRequested') {
  $txt = $txt.Replace("volatile LONG boostRequested = 0;", "volatile LONG boostRequested = 0;`r`n`tvolatile LONG autoLoginRequested = -1;`r`n`tvolatile LONG reconnectRequested = -1;")
  if ($txt -notmatch 'autoLoginRequested') { throw "autologin channel-field patch failed." }
  Good 'applied autologin channel field'
}
if ($txt -notmatch 'fastWalkRequested') {
  $txt = $txt.Replace("volatile LONG reconnectRequested = -1;", "volatile LONG reconnectRequested = -1;`r`n`tvolatile LONG fastWalkRequested = -1;")
  if ($txt -notmatch 'fastWalkRequested') { throw "fastwalk channel-field patch failed." }
  Good 'applied fastwalk channel field'
}
if ($txt -notmatch 'timeLockRequested') {
  $txt = $txt.Replace("volatile LONG fastWalkRequested = -1;", "volatile LONG fastWalkRequested = -1;`r`n`tvolatile LONG timeLockRequested = -1;")
  if ($txt -notmatch 'timeLockRequested') { throw "timelock channel-field patch failed." }
  Good 'applied timelock channel field'
}
if ($txt -notmatch 'lockMoveRequested') {
  $txt = $txt.Replace("volatile LONG timeLockRequested = -1;", "volatile LONG timeLockRequested = -1;`r`n`tvolatile LONG lockMoveRequested = -1;")
  if ($txt -notmatch 'lockMoveRequested') { throw "lockmove channel-field patch failed." }
  Good 'applied lockmove channel field'
}
if ($txt -notmatch 'passWallRequested') {
  $txt = $txt.Replace("volatile LONG lockMoveRequested = -1;", "volatile LONG lockMoveRequested = -1;`r`n`tvolatile LONG passWallRequested = -1;")
  if ($txt -notmatch 'passWallRequested') { throw "passwall channel-field patch failed." }
  Good 'applied passwall channel field'
}
if ($txt -notmatch 'autoWalkRequested') {
  $txt = $txt.Replace("volatile LONG passWallRequested = -1;", "volatile LONG passWallRequested = -1;`r`n`tvolatile LONG autoWalkRequested = -1;")
  if ($txt -notmatch 'autoWalkRequested') { throw "autowalk channel-field patch failed." }
  Good 'applied autowalk channel field (single enable flag, boost-style)'
}
if ($txt -notmatch 'fastAutoWalkRequested') {
  $txt = $txt.Replace("volatile LONG autoWalkRequested = -1;", "volatile LONG autoWalkRequested = -1;`r`n`tvolatile LONG fastAutoWalkRequested = -1;")
  if ($txt -notmatch 'fastAutoWalkRequested') { throw "fastautowalk channel-field patch failed." }
  Good 'applied fastautowalk channel field (single enable flag)'
}
if ($txt -notmatch 'autoEscapeRequested') {
  $txt = $txt.Replace("volatile LONG fastAutoWalkRequested = -1;", "volatile LONG fastAutoWalkRequested = -1;`r`n`tvolatile LONG autoEscapeRequested = -1;")
  if ($txt -notmatch 'autoEscapeRequested') { throw "autoescape channel-field patch failed." }
  Good 'applied autoescape channel field'
}
if ($txt -notmatch 'autoBattleRequested') {
  $txt = $txt.Replace("volatile LONG autoEscapeRequested = -1;", "volatile LONG autoEscapeRequested = -1;`r`n`tvolatile LONG autoBattleRequested = -1;`r`n`tvolatile LONG battleCharActionType = -1;`r`n`tvolatile LONG battleCharActionTarget = 0;`r`n`tvolatile LONG battlePetActionType = -1;`r`n`tvolatile LONG battlePetActionTarget = 0;`r`n`tvolatile LONG battleCharNormalEnemy = 0;`r`n`tvolatile LONG battleCharNormalLevel = 0;")
  if ($txt -notmatch 'autoBattleRequested') { throw "autobattle channel-field patch failed." }
  Good 'applied autobattle channel fields (enable + char/pet action type/target)'
}
if ($txt -notmatch 'battleCharRoundRound') {
  # Battle-tab char ROUND row (selectRoundFun) + CROSS row (intervalRoundFun) + action delay.
  $txt = $txt.Replace("volatile LONG battleCharNormalLevel = 0;", "volatile LONG battleCharNormalLevel = 0;`r`n`tvolatile LONG battleCharRoundRound = 0;`r`n`tvolatile LONG battleCharRoundEnemy = 0;`r`n`tvolatile LONG battleCharRoundLevel = 0;`r`n`tvolatile LONG battleCharRoundType = 0;`r`n`tvolatile LONG battleCharRoundTarget = 0;`r`n`tvolatile LONG battleCharCrossEnable = 0;`r`n`tvolatile LONG battleCharCrossRound = 0;`r`n`tvolatile LONG battleCharCrossType = 0;`r`n`tvolatile LONG battleCharCrossTarget = 0;`r`n`tvolatile LONG battleActionDelay = 0;")
  if ($txt -notmatch 'battleCharRoundRound') { throw "battle round/cross/delay channel-field patch failed." }
  Good 'applied battle round/cross/delay channel fields (char)'
}
if ($txt -notmatch 'battlePetRoundRound') {
  $txt = $txt.Replace("volatile LONG battleActionDelay = 0;", "volatile LONG battleActionDelay = 0;`r`n`tvolatile LONG battlePetRoundRound = 0;`r`n`tvolatile LONG battlePetRoundEnemy = 0;`r`n`tvolatile LONG battlePetRoundLevel = 0;`r`n`tvolatile LONG battlePetRoundType = 0;`r`n`tvolatile LONG battlePetRoundTarget = 0;`r`n`tvolatile LONG battlePetCrossEnable = 0;`r`n`tvolatile LONG battlePetCrossRound = 0;`r`n`tvolatile LONG battlePetCrossType = 0;`r`n`tvolatile LONG battlePetCrossTarget = 0;")
  if ($txt -notmatch 'battlePetRoundRound') { throw "battle pet round/cross channel-field patch failed." }
  Good 'applied battle pet round/cross channel fields'
}
if ($txt -notmatch 'battleMagicHealEnable') {
  $txt = $txt.Replace("volatile LONG battlePetCrossTarget = 0;", "volatile LONG battlePetCrossTarget = 0;`r`n`tvolatile LONG battleMagicHealEnable = 0;`r`n`tvolatile LONG battleMagicHealTarget = 0;`r`n`tvolatile LONG battleMagicHealChar = 0;`r`n`tvolatile LONG battleMagicHealPet = 0;`r`n`tvolatile LONG battleMagicHealAllie = 0;`r`n`tvolatile LONG battleMagicHealMagic = 0;`r`n`tvolatile LONG battleSkillMpEnable = 0;`r`n`tvolatile LONG battleSkillMpValue = 0;`r`n`tvolatile LONG battleItemHealMpEnable = 0;`r`n`tvolatile LONG battleItemHealMpValue = 0;`r`n`tvolatile LONG battleFallEscapeRequested = -1;")
  if ($txt -notmatch 'battleMagicHealEnable') { throw "battle magic-heal channel-field patch failed." }
  Good 'applied battle magic-heal channel fields'
}
if ($txt -notmatch 'normalMagicHealEnable') {
  # [NormalHeal] field (non-battle) magic-heal channel: char-self minimum (enable/char%/magicSel). F0: autoHeal() 2439-2500.
  $txt = $txt.Replace("volatile LONG battleFallEscapeRequested = -1;", "volatile LONG battleFallEscapeRequested = -1;`r`n`tvolatile LONG normalMagicHealEnable = 0;`r`n`tvolatile LONG normalMagicHealChar = 0;`r`n`tvolatile LONG normalMagicHealMagic = 0;`r`n`tvolatile LONG normalMagicHealPet = 0;`r`n`tvolatile LONG normalMagicHealAllie = 0;`r`n`tvolatile LONG normalItemHealMpEnable = 0;`r`n`tvolatile LONG normalItemHealMpValue = 0;")
  if ($txt -notmatch 'normalMagicHealEnable') { throw "normal magic-heal channel-field patch failed." }
  Good 'applied normal magic-heal channel fields'
}
if ($txt -notmatch 'autoWalkDistance') {
  $txt = $txt.Replace("volatile LONG autoWalkRequested = -1;", "volatile LONG autoWalkRequested = -1;`r`n`tvolatile LONG autoWalkDistance = 1;`r`n`tvolatile LONG autoWalkDirection = 0;`r`n`tvolatile LONG autoWalkDelay = 0;")
  if ($txt -notmatch 'autoWalkDistance') { throw "autowalk dist/dir channel-field patch failed." }
  Good 'applied autowalk distance/direction channel fields (W2 re-port)'
}
if ($txt -notmatch 'showExpRequested') {
  $txt = $txt.Replace("volatile LONG boostRequested = 0;", "volatile LONG boostRequested = 0;`r`n`tvolatile LONG showExpRequested = 1;")
  if ($txt -notmatch 'showExpRequested') { throw "showexp channel-field patch failed." }
  Good 'applied showexp channel field (default on)'
}
if ($txt -notmatch 'fastBattleRequested') {
  $txt = $txt.Replace("volatile LONG autoWalkDelay = 0;", "volatile LONG autoWalkDelay = 0;`r`n`tvolatile LONG fastBattleRequested = -1;")
  if ($txt -notmatch 'fastBattleRequested') { throw "channel fastBattleRequested inject failed." }
  Good 'applied channel field fastBattleRequested'
}
[IO.File]::WriteAllText($hdr, $txt, $utf8bom)

# ---- sadll.cpp : resolveUiThread fix + B1 per-step diag ----
$s = [IO.File]::ReadAllText($sadll)
$uiPat = 'if \(EnumWindows\(findClient05UiThread, reinterpret_cast<LPARAM>\(&search\)\) == FALSE \|\|'
$uiRep = "EnumWindows(findClient05UiThread, reinterpret_cast<LPARAM>(&search));`r`n`tif ("
if ($s -match [regex]::Escape('EnumWindows(findClient05UiThread, reinterpret_cast<LPARAM>(&search)) == FALSE')) {
  $s = [regex]::Replace($s, $uiPat, $uiRep); Good 'applied resolveUiThread fix'
}
# (v9) New_PlaySe is left as clean HEAD. Mute is applied continuously on the client-side
# monitor thread (client_runtime_diagnostics.cpp) instead of only on SE playback.
if ($s -notmatch 'sashB1Diag') {
  $b1rep = @'
auto sashB1Diag = [](const char* m) noexcept { HANDLE f = CreateFileW(L"D:\\SA\\zmffk\\b1-step-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr); if (f != INVALID_HANDLE_VALUE) { DWORD w = 0; WriteFile(f, m, (DWORD)lstrlenA(m), &w, nullptr); WriteFile(f, "\r\n", 2, &w, nullptr); CloseHandle(f); } };
	sashB1Diag("enter B1-steps");
	if (client05B1Adapter_ == nullptr || client05B1SyncClient_ == nullptr || client05ControlDispatcher_ == nullptr) { sashB1Diag("FAIL objects-null"); uninitializeClient05B1(); return FALSE; }
	sashB1Diag("ok objects");
	if (!resolveClient05MainUiThread()) { sashB1Diag("FAIL resolveClient05MainUiThread"); uninitializeClient05B1(); return FALSE; }
	sashB1Diag("ok resolveMainUiThread");
	if (!client05ControlDispatcher_->configure(*client05ReadOnlyChannel_, g_MainThreadId, g_hDllModule, client05ValidatedSendBindings_)) { sashB1Diag("FAIL configure"); uninitializeClient05B1(); return FALSE; }
	sashB1Diag("ok configure");
	if (!client05B1Adapter_->startHandshake(*client05B1SyncClient_)) { sashB1Diag("FAIL startHandshake"); uninitializeClient05B1(); return FALSE; }
	sashB1Diag("ok startHandshake");
	if (!client05B1Adapter_->installReceiveHook(client05B1RecvIatSlot_, client05B1GameSocketAddress_)) { sashB1Diag("FAIL installReceiveHook"); uninitializeClient05B1(); return FALSE; }
	sashB1Diag("ok installReceiveHook SUCCESS");
	return TRUE;
'@
  $rx = [regex]'(?s)if \(client05B1Adapter_ == nullptr.*?return TRUE;'
  if (-not $rx.IsMatch($s)) { throw "could not locate B1 compound-if block." }
  $s = $rx.Replace($s, $b1rep, 1)
  Good 'applied B1 diag (per-step logging)'
}
$s = $s.Replace("zmffk\\b1-step-diag.log", "zmffk\\b1-step-diag-$tag.log")
$s = $s.Replace('D:\\SA\\zmffk', 'C:\\zmffk')  # newpc: client diag-log dir moved D:\SA\zmffk -> C:\zmffk
[IO.File]::WriteAllText($sadll, $s, $utf8bom)

# ---- client_runtime_diagnostics.cpp : continuous NATIVE FULL MUTE on the monitor thread ----
$d = [IO.File]::ReadAllText($diag)
if ($d -notmatch 'mute-diag\.log') {
  $muteRep = @'
processAutoLoginCommand(*context);
			// (v9) Native full mute (BGM + SE): the client's own WM_EnableSound path.
			// Zero t_music_se_volume / t_music_bgm_volume and re-apply via bgm_volume_change().
			// Applied here (monitor thread) so mute works even when no SE is currently playing.
			// RVAs from SA93Client.map; base = validated client module (fixed 0x00400000).
			if (context->channel != nullptr && context->module != nullptr)
			{
				static LONG s_muteApplied = 0;
				const LONG want = (client05_readonly::readLong(context->channel->muteRequested) != FALSE) ? 1 : 0;
				if (want != s_muteApplied)
				{
					const std::uintptr_t mbase = reinterpret_cast<std::uintptr_t>(context->module);
					int* const seVol = reinterpret_cast<int*>(mbase + 0x00194108u);
					int* const bgmVol = reinterpret_cast<int*>(mbase + 0x0019410Cu);
					const auto bgmApply = reinterpret_cast<void(__cdecl*)()>(mbase + 0x000A9FA0u);
					static int s_savedSe = 15;
					static int s_savedBgm = 15;
					const int beforeSe = *seVol;
					const int beforeBgm = *bgmVol;
					if (want == 1) { s_savedSe = beforeSe; s_savedBgm = beforeBgm; *seVol = 0; *bgmVol = 0; }
					else { *seVol = s_savedSe; *bgmVol = s_savedBgm; }
					bgmApply();
					s_muteApplied = want;
					HANDLE mfh = CreateFileW(L"D:\\SA\\zmffk\\mute-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
					if (mfh != INVALID_HANDLE_VALUE) { char mbuf[192]; int mn = wsprintfA(mbuf, "mute want=%d se %d->%d bgm %d->%d base=%p\r\n", (int)want, beforeSe, *seVol, beforeBgm, *bgmVol, (void*)mbase); DWORD mw = 0; WriteFile(mfh, mbuf, (DWORD)mn, &mw, nullptr); CloseHandle(mfh); }
				}
			}
'@
  if ($d.IndexOf("processAutoLoginCommand(*context);") -lt 0) { throw "could not locate monitor-loop anchor (processAutoLoginCommand)." }
  $d = $d.Replace("processAutoLoginCommand(*context);", $muteRep)
  if ($d -notmatch 'mute-diag\.log') { throw "monitor mute-apply patch failed." }
  Good 'applied monitor-thread native full mute + mute-diag log'
}
# ---- battle roster persist: keep last non-empty units when the client momentarily
#      empties its BC buffer (header-only "BC|field|"); refresh live scalars only. ----
if ($d -notmatch 'previous->count > 0u') {
  $battleRep = @'
if (parsed.count == 0u && previous != nullptr && previous->count > 0u)
		{
			block = *previous;
			block.myPos = parsed.myPos; block.myMp = parsed.myMp; block.bpFlags = parsed.bpFlags;
			block.actedMask = parsed.actedMask; block.clientTurn = parsed.clientTurn;
			block.serverTurn = parsed.serverTurn; block.round = parsed.round;
			block.field = parsed.field; block.active = parsed.active;
			failedField = nullptr;
			return true;
		}
		block = parsed;
'@
  if ($d.IndexOf("block = parsed;") -lt 0) { throw "could not locate battle parse block." }
  $d = $d.Replace("block = parsed;", $battleRep)
  if ($d -notmatch 'previous->count > 0u') { throw "battle roster-persist patch failed." }
  Good 'applied battle roster-persist fix'
}
if ($d -notmatch 'boost-diag\.log') {
  $boostRep = @'
processAutoLoginCommand(*context);
			// Native launcher-boost 0~14: drive SystemTime + NO_DRAW_MAX_CNT (adjacent
			// gamemain.obj globals). boost 0 = normal (SystemTime 14, NO_DRAW_MAX_CNT 2);
			// boost 1..14 = SystemTime 15-boost (down to 1), NO_DRAW_MAX_CNT 14. In-process
			// writes on the monitor thread; sticky writes verified externally (owner).
			if (context->channel != nullptr && context->module != nullptr)
			{
				static LONG s_boostApplied = -1;
				LONG level = client05_readonly::readLong(context->channel->boostRequested);
				if (level < 0) { level = 0; }
				if (level > 14) { level = 14; }
				if (level != s_boostApplied)
				{
					const std::uintptr_t bbase = reinterpret_cast<std::uintptr_t>(context->module);
					int* const sysTime = reinterpret_cast<int*>(bbase + 0x00171520u);
					int* const noDrawMax = reinterpret_cast<int*>(bbase + 0x00171518u);
					static int s_origSys = 0; static int s_origNoDraw = 0; static bool s_origCaptured = false;
					if (!s_origCaptured) { s_origSys = *sysTime; s_origNoDraw = *noDrawMax; s_origCaptured = true; }
					const int beforeSys = *sysTime; const int beforeNoDraw = *noDrawMax;
					// [F0 boost FAITHFUL] Disasm of GameMain draw loop (SA93Client 0x43393d) proves the draw-skip
					// decision is `cmp NoDrawCnt(0x571524), NO_DRAW_MAX_CNT(0x571518)` -> this IS the faithful
					// Client05 translation of sa_8001's `cmp ecx,0Eh` (launcher patched the immediate; here the
					// max-skip moved into a data global, so WRITING the global is exactly the launcher's patch).
					// It is also the SPEED knob: speed ~ steps-per-draw = NO_DRAW_MAX_CNT. Removing it (prior
					// attempt) dropped boost to ~2 -> slow. Restore launcher fidelity: SystemTime(=pSpeed 15-level)
					// AND NO_DRAW_MAX_CNT (off=orig 2, on 1..14 => 14). Black at 14 is the launcher's inherent
					// speed/draw-skip tradeoff, NOT this write; treat separately (see GameSpeedFlag resync path).
					if (level <= 0) { *sysTime = s_origSys; *noDrawMax = s_origNoDraw; }
					else { *sysTime = 15 - level; *noDrawMax = 14; }
					s_boostApplied = level;
					HANDLE bfh = CreateFileW(L"D:\\SA\\zmffk\\boost-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
					if (bfh != INVALID_HANDLE_VALUE) { char bbuf[224]; int bn = wsprintfA(bbuf, "boost level=%d sysTime %d->%d noDrawMax %d->%d orig(%d,%d) base=%p\r\n", (int)level, beforeSys, *sysTime, beforeNoDraw, *noDrawMax, s_origSys, s_origNoDraw, (void*)bbase); DWORD bw = 0; WriteFile(bfh, bbuf, (DWORD)bn, &bw, nullptr); CloseHandle(bfh); }
				}
			}
'@
  if ($d.IndexOf("processAutoLoginCommand(*context);") -lt 0) { throw "could not locate monitor-loop anchor for boost." }
  $d = $d.Replace("processAutoLoginCommand(*context);", $boostRep)
  if ($d -notmatch 'boost-diag\.log') { throw "monitor boost-apply patch failed." }
  Good 'applied monitor-thread native boost (SystemTime + NO_DRAW_MAX_CNT)'
}
if ($d -notmatch 'autologin-diag\.log') {
  $alGateRep = @'
processAutoLoginCommand(*context);
			// Auto-login gating (v13): when launcher kAutoLoginEnable is OFF, keep the client's
			// self-auto-login enable global (kNewAutoLoginEnableRva = 0xBCDD800) cleared AT ALL TIMES,
			// so a logout->password-screen transition cannot self-login before we clear it.
			if (context->channel != nullptr && context->module != nullptr)
			{
				const LONG alWant = client05_readonly::readLong(context->channel->autoLoginRequested);
				const LONG rcWant = client05_readonly::readLong(context->channel->reconnectRequested);
				DWORD alProc = 0xFFFFFFFFu;
				readClientDword(context->module, context->addresses.procNo, alProc);
				std::uintptr_t alAddr = 0u;
				DWORD alBefore = 0xFFFFFFFFu;
				if (loginTargetAddress(*context, kNewAutoLoginEnableRva, sizeof(DWORD), alAddr))
					readClientDword(context->module, alAddr, alBefore);
				static LONG s_alWantLogged = -99;
				if (((alProc == 9u) || (alWant == 0 && rcWant != 1)) && alBefore != 0u && alBefore != 0xFFFFFFFFu)
				{
					const DWORD alZero = 0u;
					const bool alOk = guardedWriteLoginField(*context, kNewAutoLoginEnableRva, &alZero, sizeof(alZero));
					DWORD alAfter = 0xFFFFFFFFu;
					if (alAddr != 0u) { readClientDword(context->module, alAddr, alAfter); }
					HANDLE afc = CreateFileW(L"D:\\SA\\zmffk\\autologin-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
					if (afc != INVALID_HANDLE_VALUE) { char cb[192]; int cn = wsprintfA(cb, "CLEAR want=%d proc=%lu enable %lu->%lu ok=%d\r\n", (int)alWant, (unsigned long)alProc, (unsigned long)alBefore, (unsigned long)alAfter, (int)alOk); DWORD cw = 0; WriteFile(afc, cb, (DWORD)cn, &cw, nullptr); CloseHandle(afc); }
				}
				if (rcWant == 1 && alProc == 11u && alBefore == 0u)
				{
					const DWORD alOne = 1u;
					const bool rcOk = guardedWriteLoginField(*context, kNewAutoLoginEnableRva, &alOne, sizeof(alOne));
					HANDLE rfc = CreateFileW(L"D:\\SA\\zmffk\\autologin-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
					if (rfc != INVALID_HANDLE_VALUE) { char rb[160]; int rn = wsprintfA(rb, "RECONNECT proc=11 enable 0->1 ok=%d\r\n", (int)rcOk); DWORD rw = 0; WriteFile(rfc, rb, (DWORD)rn, &rw, nullptr); CloseHandle(rfc); }
				}
				if (alWant != s_alWantLogged)
				{
					s_alWantLogged = alWant;
					HANDLE afh = CreateFileW(L"D:\\SA\\zmffk\\autologin-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
					if (afh != INVALID_HANDLE_VALUE) { char wb[160]; int wn = wsprintfA(wb, "want=%d proc=%lu enable=%lu\r\n", (int)alWant, (unsigned long)alProc, (unsigned long)alBefore); DWORD ww = 0; WriteFile(afh, wb, (DWORD)wn, &ww, nullptr); CloseHandle(afh); }
				}
			}
'@
  if ($d.IndexOf("processAutoLoginCommand(*context);") -lt 0) { throw "could not locate monitor anchor for autologin gating." }
  $d = $d.Replace("processAutoLoginCommand(*context);", $alGateRep)
  if ($d -notmatch 'autologin-diag\.log') { throw "autologin gating patch failed." }
  Good 'applied monitor-thread autologin gating + autologin-diag log'
}
if ($d -notmatch 'landing-diag') {
  $landRep = @'
processAutoLoginCommand(*context);
			// Landing sampler (v15): from login screen through in-world, log procNo plus the
			// client's landed group/subserver/character globals and the auto-login enable
			// global, whenever any of them changes. Reveals whether our written landed
			// character (pos) survives until the client's selectCharacter reads gChar, and
			// whether gEnable stays set through server/group/character auto-progress.
			if (context->channel != nullptr && context->module != nullptr)
			{
				DWORD lpProc = 0xFFFFFFFFu, lg = 0xFFFFFFFFu, ls = 0xFFFFFFFFu, lc = 0xFFFFFFFFu, le = 0xFFFFFFFFu;
				readClientDword(context->module, context->addresses.procNo, lpProc);
				std::uintptr_t ag = 0u, asub = 0u, ac = 0u, ae = 0u;
				if (loginTargetAddress(*context, kPcLandedGroupRva, sizeof(DWORD), ag)) readClientDword(context->module, ag, lg);
				if (loginTargetAddress(*context, kPcLandedSubserverRva, sizeof(DWORD), asub)) readClientDword(context->module, asub, ls);
				if (loginTargetAddress(*context, kPcLandedCharacterRva, sizeof(DWORD), ac)) readClientDword(context->module, ac, lc);
				if (loginTargetAddress(*context, kNewAutoLoginEnableRva, sizeof(DWORD), ae)) readClientDword(context->module, ae, le);
				DWORD lsock = 0xFFFFFFFFu, lsub = 0xFFFFFFFFu, lwt = 0xFFFFFFFFu, lbt = 0xFFFFFFFFu;
				readClientDword(context->module, context->addresses.sockfd, lsock);
				readClientDword(context->module, context->addresses.subProcNo, lsub);
				readClientDword(context->module, context->addresses.windowTypeWN, lwt);
				readClientDword(context->module, context->addresses.buttonTypeWN, lbt);
				static DWORD s_lp = 0xDEADBEEFu, s_lg = 0xDEADBEEFu, s_ls = 0xDEADBEEFu, s_lc = 0xDEADBEEFu, s_le = 0xDEADBEEFu; static DWORD s_lsock = 0xDEADBEEFu, s_lsub = 0xDEADBEEFu, s_lwt = 0xDEADBEEFu, s_lbt = 0xDEADBEEFu;
				if (lpProc != s_lp || lg != s_lg || ls != s_ls || lc != s_lc || le != s_le || lsock != s_lsock || lsub != s_lsub || lwt != s_lwt || lbt != s_lbt)
				{
					s_lp = lpProc; s_lg = lg; s_ls = ls; s_lc = lc; s_le = le; s_lsock = lsock; s_lsub = lsub; s_lwt = lwt; s_lbt = lbt;
					HANDLE lfh = CreateFileW(L"D:\\SA\\zmffk\\landing-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
					if (lfh != INVALID_HANDLE_VALUE) { char lb[256]; int ln = wsprintfA(lb, "proc=%lu sub=%lu sock=%lu win=%lu btn=%lu group=%ld subsrv=%ld char=%ld enable=%ld\r\n", (unsigned long)lpProc, (unsigned long)lsub, (unsigned long)lsock, (unsigned long)lwt, (unsigned long)lbt, (long)lg, (long)ls, (long)lc, (long)le); DWORD lw = 0; WriteFile(lfh, lb, (DWORD)ln, &lw, nullptr); CloseHandle(lfh); }
				}
			}
'@
  if ($d.IndexOf("processAutoLoginCommand(*context);") -lt 0) { throw "could not locate monitor anchor for landing sampler." }
  $d = $d.Replace("processAutoLoginCommand(*context);", $landRep)
  if ($d -notmatch 'landing-diag') { throw "landing sampler patch failed." }
  Good 'applied monitor-thread landing sampler + landing-diag log'
}
if ($d -notmatch 'fastwalk-diag\.log') {
  $fwRep = @'
processAutoLoginCommand(*context);
			// Native launcher fast-walk (快速走路) ported to Client05. sa_8001 launcher
			// (sadll WM_EnableFastWalk) writes the client MOVE_SPEED float 4.0<->32.0.
			// Client05 equivalent = the dedicated MOVE_SPEED constant at RVA 0x0014BDB4
			// (VA 0x0054BDB4, =4.0f), referenced by 10 mulss across the 5 movement
			// functions (ptAct->vx = dx * MOVE_SPEED * rate). Unlike boost/mute globals
			// this constant lives in .rdata (read-only), so the write is guarded by
			// VirtualProtect and only performed once VirtualProtect succeeds; the page
			// protection is restored immediately afterwards. (No SEH here: this monitor
			// function has C++ objects requiring unwinding, which forbids __try/C2712;
			// the VirtualProtect gate makes a naked write safe, like the boost block.)
			if (context->channel != nullptr && context->module != nullptr)
			{
				const LONG fwWant = client05_readonly::readLong(context->channel->fastWalkRequested);
				static LONG s_fwApplied = -2;
				static float s_fwOrig = 4.0f;
				static bool s_fwOrigCaptured = false;
				if (fwWant >= 0 && fwWant != s_fwApplied)
				{
					const std::uintptr_t fwBase = reinterpret_cast<std::uintptr_t>(context->module);
					float* const fwSpeed = reinterpret_cast<float*>(fwBase + 0x0014BDB4u);
					if (!s_fwOrigCaptured) { s_fwOrig = *fwSpeed; s_fwOrigCaptured = true; }
					const float fwBefore = *fwSpeed;
					const float fwTarget = (fwWant >= 1) ? 32.0f : s_fwOrig;
					int fwOk = 0;
					DWORD fwOldProt = 0;
					if (VirtualProtect(reinterpret_cast<LPVOID>(fwSpeed), sizeof(float), PAGE_EXECUTE_READWRITE, &fwOldProt))
					{
						*fwSpeed = fwTarget;
						DWORD fwTmp = 0; VirtualProtect(reinterpret_cast<LPVOID>(fwSpeed), sizeof(float), fwOldProt, &fwTmp);
						fwOk = 1;
					}
					const float fwAfter = *fwSpeed;
					s_fwApplied = fwWant;
					HANDLE fwh = CreateFileW(L"D:\\SA\\zmffk\\fastwalk-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
					if (fwh != INVALID_HANDLE_VALUE) { char fwb[224]; int fwn = wsprintfA(fwb, "fastwalk want=%d speed %d->%d ok=%d orig=%d base=%p\r\n", (int)fwWant, (int)fwBefore, (int)fwAfter, fwOk, (int)s_fwOrig, (void*)fwBase); DWORD fww = 0; WriteFile(fwh, fwb, (DWORD)fwn, &fww, nullptr); CloseHandle(fwh); }
				}
			}
'@
  if ($d.IndexOf("processAutoLoginCommand(*context);") -lt 0) { throw "could not locate monitor anchor for fastwalk." }
  $d = $d.Replace("processAutoLoginCommand(*context);", $fwRep)
  if ($d -notmatch 'fastwalk-diag\.log') { throw "monitor fastwalk-apply patch failed." }
  Good 'applied monitor-thread native fast-walk (MOVE_SPEED 4.0<->32.0 via VirtualProtect)'
}
if ($d -notmatch 'timelock-diag\.log') {
  $tlRep = @'
processAutoLoginCommand(*context);
			// Native launcher time-lock (鎖定時間) — FAITHFUL R0 port of WM_SetTimeLock.
			// Launcher mechanism (sadll.cpp:971 WM_SetTimeLock + New_RealTimeToSATime/New_TimeZoneProc):
			//   (1) write 5 day/night globals to the chosen period, AND
			//   (2) SKIP the two time-advance functions while locked so nothing re-advances:
			//       pRealTimeToSATime (writes SaTime) and pTimeZoneProc (zone/palette refresh).
			// Client05 .map-verified equivalents (base 0x400000):
			//   pcurrentTime->amPmAnimeTime 0x666F0C, pa->amPmAnimeGraNoIndex0 0x666F14,
			//   pb->amPmAnimeGraNoIndex1 0x666F18, pc(source)->SaTime.hour 0x6AE99C,
			//   pd(zone)->SaTimeZoneNo 0x6AE9A8; RealTimeToSATime 0x434430, TimeZoneProc 0x4344D0.
			// Freeze = ret-patch each function entry (byte[0]->0xC3). The existing per-frame
			// amPmAnimeTime recompute (0x42F82A) then reads the frozen SaTime.hour and reproduces
			// amPmAnimeTime every frame with no race (verified: (hour+832)%1024 => the 5 values).
			// state 0..4 = 下午/黃昏/午夜/早晨/中午; -1 = unlock (restore both entries).
			// Replaces the earlier single mid-computation code patch: this is the launcher's own
			// 5-global write + 2-function skip, ported identically (R0), no invention.
			if (context->channel != nullptr && context->module != nullptr)
			{
				const LONG tlWant = client05_readonly::readLong(context->channel->timeLockRequested);
				static const int s_tlAmPm[5] = { 832, 64, 320, 576, 832 };   // amPmAnimeTime
				static const int s_tlIdx0[5] = { 3, 0, 1, 2, 3 };            // amPmAnimeGraNoIndex0 = amPm/256
				static const int s_tlIdx1[5] = { 0, 1, 2, 3, 0 };            // amPmAnimeGraNoIndex1 = (idx0+1)%4
				static const int s_tlHour[5] = { 0, 256, 512, 768, 1024 };   // SaTime.hour (source counter, launcher pc)
				static const int s_tlZone[5] = { 0, 1, 2, 3, 0 };            // SaTimeZoneNo (launcher pd)
				static LONG s_tlApplied = -2;
				static BYTE s_tlOrigRt = 0x55;   // RealTimeToSATime entry (push ebp)
				static BYTE s_tlOrigTz = 0x68;   // TimeZoneProc entry (push 0x6AE994)
				static bool s_tlCap = false;
				if (tlWant >= -1 && tlWant <= 4 && tlWant != s_tlApplied)
				{
					const std::uintptr_t tlBase = reinterpret_cast<std::uintptr_t>(context->module);
					BYTE* const tlRt = reinterpret_cast<BYTE*>(tlBase + 0x00034430u); // RealTimeToSATime
					BYTE* const tlTz = reinterpret_cast<BYTE*>(tlBase + 0x000344D0u); // TimeZoneProc
					if (!s_tlCap) { s_tlOrigRt = tlRt[0]; s_tlOrigTz = tlTz[0]; s_tlCap = true; }
					int tlOk = 0;
					if (tlWant >= 0 && tlWant <= 4)
					{
						const int ti = (int)tlWant;
						// (1) FIRST skip the two advance functions (ret-patch entry) so the game
						//     thread cannot re-advance SaTime between our write and the freeze.
						DWORD tlOp = 0;
						if (VirtualProtect(tlRt, 1u, PAGE_EXECUTE_READWRITE, &tlOp)) { if (tlRt[0] != 0xC3) tlRt[0] = 0xC3; DWORD tlt = 0; VirtualProtect(tlRt, 1u, tlOp, &tlt); FlushInstructionCache(GetCurrentProcess(), tlRt, 1u); tlOk |= 1; }
						if (VirtualProtect(tlTz, 1u, PAGE_EXECUTE_READWRITE, &tlOp)) { if (tlTz[0] != 0xC3) tlTz[0] = 0xC3; DWORD tlt = 0; VirtualProtect(tlTz, 1u, tlOp, &tlt); FlushInstructionCache(GetCurrentProcess(), tlTz, 1u); tlOk |= 2; }
						// (2) THEN write the 5 period globals (launcher's data-write; now race-free).
						//     amPmAnimeTime/Index0/Index1 are also reproduced every frame by the
						//     existing 0x42F82A recompute from the frozen SaTime.hour (belt+braces).
						*reinterpret_cast<volatile int*>(tlBase + 0x002AE99Cu) = s_tlHour[ti]; // SaTime.hour (source; launcher pc)
						*reinterpret_cast<volatile int*>(tlBase + 0x002AE9A8u) = s_tlZone[ti]; // SaTimeZoneNo (launcher pd)
						*reinterpret_cast<volatile int*>(tlBase + 0x00266F0Cu) = s_tlAmPm[ti]; // amPmAnimeTime (launcher pcurrentTime)
						*reinterpret_cast<volatile int*>(tlBase + 0x00266F14u) = s_tlIdx0[ti]; // amPmAnimeGraNoIndex0 (launcher pa)
						*reinterpret_cast<volatile int*>(tlBase + 0x00266F18u) = s_tlIdx1[ti]; // amPmAnimeGraNoIndex1 (launcher pb)
					}
					else
					{
						// unlock (-1): restore both entries; client resumes real-time advance next frame
						DWORD tlOp = 0;
						if (VirtualProtect(tlRt, 1u, PAGE_EXECUTE_READWRITE, &tlOp)) { tlRt[0] = s_tlOrigRt; DWORD tlt = 0; VirtualProtect(tlRt, 1u, tlOp, &tlt); FlushInstructionCache(GetCurrentProcess(), tlRt, 1u); tlOk |= 1; }
						if (VirtualProtect(tlTz, 1u, PAGE_EXECUTE_READWRITE, &tlOp)) { tlTz[0] = s_tlOrigTz; DWORD tlt = 0; VirtualProtect(tlTz, 1u, tlOp, &tlt); FlushInstructionCache(GetCurrentProcess(), tlTz, 1u); tlOk |= 2; }
					}
					s_tlApplied = tlWant;
					HANDLE tfh = CreateFileW(L"D:\\SA\\zmffk\\timelock-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
					if (tfh != INVALID_HANDLE_VALUE) { char tlb[256]; int tln = wsprintfA(tlb, "timelock want=%d rt=%02X tz=%02X ok=%d base=%p\r\n", (int)tlWant, (int)tlRt[0], (int)tlTz[0], tlOk, (void*)tlBase); DWORD tlw = 0; WriteFile(tfh, tlb, (DWORD)tln, &tlw, nullptr); CloseHandle(tfh); }
				}
			}
'@
  if ($d.IndexOf("processAutoLoginCommand(*context);") -lt 0) { throw "could not locate monitor anchor for timelock." }
  $d = $d.Replace("processAutoLoginCommand(*context);", $tlRep)
  if ($d -notmatch 'timelock-diag\.log') { throw "monitor timelock-apply patch failed." }
  Good 'applied monitor-thread native time-lock (amPmAnimeTime read-site code patch)'
}
if ($d -notmatch 'AIManualLogin') {
  if ($d.IndexOf("processAutoLoginCommand(*context);") -lt 0) { throw "could not locate AIManualLogin anchor." }
  $aiRep = @'
processAutoLoginCommand(*context);
			// [AIManualLogin] Force MANUAL battle mode on world-entry, the R0-correct way: neutralize ONLY the
			// client's relogin-AI auto-restore in gamemain.cpp GameMain (src line 312-313), leaving the PgUp
			// toggle (separate stores @0x4339FB / 0x433A99) fully free so the user can switch AI<->manual.
			//   (a) relogin AI-store `mov [AI(0x59DDE8)],3` @0x433459 -> imm byte @0x43345F (RVA 0x3345F) 03->00
			//       so relogin keeps AI = AI_NONE (manual) instead of AI_SELECT (AI).
			//   (b) the relogin AI-mode chat-notice call @0x433463 (RVA 0x33463, E8 rel32 -> StockChatBufferLine)
			//       NOP x5 so the AI-mode notice line no longer prints on entry.
			// One-time code patch. No continuous AI write, no AI_CheckSetting patch (those fought PgUp and the AI
			// settings window). ai-diag.log records the one-time apply result.
			if (context->module != nullptr)
			{
				const std::uintptr_t aiBase = reinterpret_cast<std::uintptr_t>(context->module);
				static bool s_aiPatched = false;
				if (!s_aiPatched)
				{
					int aiOk = 0;
					BYTE* const aiImm = reinterpret_cast<BYTE*>(aiBase + 0x0003345Fu);
					DWORD aiP1 = 0;
					if (VirtualProtect(aiImm, 1u, PAGE_EXECUTE_READWRITE, &aiP1))
					{
						if (aiImm[0] == 0x03) { aiImm[0] = 0x00; ++aiOk; }
						DWORD aiT1 = 0; VirtualProtect(aiImm, 1u, aiP1, &aiT1);
						FlushInstructionCache(GetCurrentProcess(), aiImm, 1u);
					}
					BYTE* const aiMsg = reinterpret_cast<BYTE*>(aiBase + 0x00033463u);
					DWORD aiP2 = 0;
					if (VirtualProtect(aiMsg, 5u, PAGE_EXECUTE_READWRITE, &aiP2))
					{
						if (aiMsg[0] == 0xE8) { aiMsg[0] = 0x90; aiMsg[1] = 0x90; aiMsg[2] = 0x90; aiMsg[3] = 0x90; aiMsg[4] = 0x90; ++aiOk; }
						DWORD aiT2 = 0; VirtualProtect(aiMsg, 5u, aiP2, &aiT2);
						FlushInstructionCache(GetCurrentProcess(), aiMsg, 5u);
					}
					s_aiPatched = true;
					HANDLE aif = CreateFileW(L"D:\\SA\\zmffk\\ai-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
					if (aif != INVALID_HANDLE_VALUE) { char aib[160]; int ain = wsprintfA(aib, "AImanual one-time patch ok=%d (relogin 03->00 @+3345F, msg NOPx5 @+33463); PgUp free\r\n", aiOk); DWORD aiw = 0; WriteFile(aif, aib, (DWORD)ain, &aiw, nullptr); CloseHandle(aif); }
				}
			}
'@
  $d = $d.Replace("processAutoLoginCommand(*context);", $aiRep)
  if ($d -notmatch 'AIManualLogin') { throw "monitor AI-manual patch failed." }
  Good 'applied monitor AI-manual (continuous force + ai-diag)'
}
if ($d -notmatch 'lockmove-diag\.log') {
  $lmRep = @'
processAutoLoginCommand(*context);
			// Native launcher position-lock (鎖定原地) ported to Client05. The launcher's
			// settled/safe mechanism patches the immediate of the "queue a move" store from
			// 1 to 0 (NOT the finicky jump-patch its author warned about). Client05 site:
			// moveProc (map.obj) @ 0x00463544 `mov dword ptr [0x0BCE0CE8], 1` queues a move
			// step; consumed at 0x00463616 `cmp [0x0BCE0CE8], 0`. Only the low byte of the
			// imm (01 00 00 00) changes 01<->00, so patch a single byte at VA 0x0046354A
			// (RVA 0x0006354A, .text) — atomic, no alignment/tearing concern. Lock=0x00,
			// unlock=0x01(orig). On unlock also clear the trigger global (0x0BCE0CE8, RVA
			// 0x0B8E0CE8, .data) to drop any pending step, matching the launcher's reset.
			if (context->channel != nullptr && context->module != nullptr)
			{
				const LONG lmWant = client05_readonly::readLong(context->channel->lockMoveRequested);
				static LONG s_lmApplied = -2;
				static BYTE s_lmOrigImm = 0x01;
				static bool s_lmOrigCaptured = false;
				if (lmWant >= 0 && lmWant != s_lmApplied)
				{
					const std::uintptr_t lmBase = reinterpret_cast<std::uintptr_t>(context->module);
					BYTE* const lmImm = reinterpret_cast<BYTE*>(lmBase + 0x0006354Au);
					DWORD* const lmTrig = reinterpret_cast<DWORD*>(lmBase + 0x0B8E0CE8u);
					if (!s_lmOrigCaptured) { s_lmOrigImm = *lmImm; s_lmOrigCaptured = true; }
					const BYTE lmBefore = *lmImm;
					const BYTE lmTarget = (lmWant >= 1) ? (BYTE)0x00 : s_lmOrigImm;
					int lmOk = 0;
					DWORD lmOldProt = 0;
					if (VirtualProtect(reinterpret_cast<LPVOID>(lmImm), 1u, PAGE_EXECUTE_READWRITE, &lmOldProt))
					{
						*lmImm = lmTarget;
						DWORD lmTmp = 0; VirtualProtect(reinterpret_cast<LPVOID>(lmImm), 1u, lmOldProt, &lmTmp);
						FlushInstructionCache(GetCurrentProcess(), reinterpret_cast<LPCVOID>(lmImm), 1u);
						lmOk = 1;
					}
					const BYTE lmAfter = *lmImm;
					if (lmWant == 0) { *lmTrig = 0u; }
					s_lmApplied = lmWant;
					HANDLE lmh = CreateFileW(L"D:\\SA\\zmffk\\lockmove-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
					if (lmh != INVALID_HANDLE_VALUE) { char lmb[224]; int lmn = wsprintfA(lmb, "lockmove want=%d imm %02X->%02X ok=%d orig=%02X base=%p\r\n", (int)lmWant, (int)lmBefore, (int)lmAfter, lmOk, (int)s_lmOrigImm, (void*)lmBase); DWORD lmw = 0; WriteFile(lmh, lmb, (DWORD)lmn, &lmw, nullptr); CloseHandle(lmh); }
				}
			}
'@
  if ($d.IndexOf("processAutoLoginCommand(*context);") -lt 0) { throw "could not locate monitor anchor for lockmove." }
  $d = $d.Replace("processAutoLoginCommand(*context);", $lmRep)
  if ($d -notmatch 'lockmove-diag\.log') { throw "monitor lockmove-apply patch failed." }
  Good 'applied monitor-thread native position-lock (moveProc imm 01<->00)'
}
if ($d -notmatch 'passwall-diag\.log') {
  $pwRep = @'
processAutoLoginCommand(*context);
			// Native launcher pass-wall (橫衝直撞) ported to Client05. v1 patched
			// correctCharMovePoint's checkHitMap call-site (0x00421A05 je->jmp) but that
			// routine is NOT the player's walk path (verified: patch applied 74->EB per diag,
			// yet walls still blocked). The real wall test is INSIDE checkHitMap (0x0045EAE0):
			// the launcher-pattern tile check `cmp word ptr [eax*2+0xBCE0210], 1` @ 0x0045EB34
			// followed by 0x0045EB3D `jne 0x45EB2B` (tile!=1 -> return 0 = passable; tile==1
			// falls through to 0x45EB3F `mov eax,1; ret` = blocked). Forcing that jne to jmp
			// makes tile==1 also return 0 => every IN-BOUNDS tile passable = walk through
			// walls, for EVERY caller of checkHitMap (whatever the player-walk path is).
			// Out-of-bounds still blocks (separate branch). This mirrors the launcher
			// disabling its inline tile cmp. 1-byte patch (75 'jne' <-> EB 'jmp') at VA
			// 0x0045EB3D (RVA 0x0005EB3D, .text): atomic single-byte write. ON=EB, OFF=orig
			// (75). Code patch => VirtualProtect + FlushInstructionCache. -1 = untouched.
			if (context->channel != nullptr && context->module != nullptr)
			{
				const LONG pwWant = client05_readonly::readLong(context->channel->passWallRequested);
				static LONG s_pwApplied = -2;
				static BYTE s_pwOrig = 0x75;
				static bool s_pwCaptured = false;
				if (pwWant >= 0 && pwWant != s_pwApplied)
				{
					const std::uintptr_t pwBase = reinterpret_cast<std::uintptr_t>(context->module);
					BYTE* const pwp = reinterpret_cast<BYTE*>(pwBase + 0x0005EB3Du);
					if (!s_pwCaptured) { s_pwOrig = *pwp; s_pwCaptured = true; }
					const BYTE pwBefore = *pwp;
					const BYTE pwTarget = (pwWant >= 1) ? (BYTE)0xEB : s_pwOrig;
					int pwOk = 0;
					DWORD pwOldProt = 0;
					if (VirtualProtect(reinterpret_cast<LPVOID>(pwp), 1u, PAGE_EXECUTE_READWRITE, &pwOldProt))
					{
						*pwp = pwTarget;
						DWORD pwTmp = 0; VirtualProtect(reinterpret_cast<LPVOID>(pwp), 1u, pwOldProt, &pwTmp);
						FlushInstructionCache(GetCurrentProcess(), reinterpret_cast<LPCVOID>(pwp), 1u);
						pwOk = 1;
					}
					const BYTE pwAfter = *pwp;
					s_pwApplied = pwWant;
					HANDLE pwh = CreateFileW(L"D:\\SA\\zmffk\\passwall-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
					if (pwh != INVALID_HANDLE_VALUE) { char pwb[224]; int pwn = wsprintfA(pwb, "passwall want=%d byte %02X->%02X ok=%d orig=%02X base=%p\r\n", (int)pwWant, (int)pwBefore, (int)pwAfter, pwOk, (int)s_pwOrig, (void*)pwBase); DWORD pww = 0; WriteFile(pwh, pwb, (DWORD)pwn, &pww, nullptr); CloseHandle(pwh); }
				}
			}
'@
  if ($d.IndexOf("processAutoLoginCommand(*context);") -lt 0) { throw "could not locate monitor anchor for passwall." }
  $d = $d.Replace("processAutoLoginCommand(*context);", $pwRep)
  if ($d -notmatch 'passwall-diag\.log') { throw "monitor passwall-apply patch failed." }
  Good 'applied monitor-thread native pass-wall (checkHitMap jne->jmp @0x45EB3D)'
}
if ($d -notmatch 'AutoWalkMemMove') {
  $wkRep = @'
processAutoLoginCommand(*context);
			// [AutoWalkMemMove] Native auto-walk (走路遇敵) — launcher WM_Move (sadll.cpp:1223) memory port.
			// Launcher moves the char by writing goalX/goalY + moveStart=1 into the CLIENT'S OWN move vars; the
			// client's game loop then pathfinds and walks there tile-by-tile (VISIBLE). No W2 packet, no server-side
			// step execution -> the W2 base-coordinate drift cannot occur. Verified 2026-08: W2 (even fixed-origin)
			// still drifts SW on this server because the base is NOT the lever; WM_Move (client walks itself) is the
			// launcher-native move that works and was the original passing version. moveProc @0x463535..0x46354E:
			// goalX=0xBCE0CEC, goalY=0xBCE0CF0, moveStart=0xBCE0CE8; nowGx=0xBCDE0D8, nowGy=0xBCDE0DC (all .data).
			// RVAs (base 0x400000): goalX 0xB8E0CEC / goalY 0xB8E0CF0 / moveStart 0xB8E0CE8 / nowGx 0xB8DE0D8 /
			// nowGy 0xB8DE0DC. Monitor owns the back-and-forth: capture origin on enable, walk to origX+span, flip to
			// origX-span on arrival, re-assert only when idle (moveStart==0) so the client never re-pathfinds mid-walk.
			if (context->channel != nullptr && context->module != nullptr)
			{
				static LONG s_awLast = -2;
				static int s_awOrigX = 0, s_awOrigY = 0, s_awSide = 0, s_awHaveOrig = 0, s_awNeed = 0;
				const LONG awWant = client05_readonly::readLong(context->channel->autoWalkRequested);
				const std::uintptr_t awbase = reinterpret_cast<std::uintptr_t>(context->module);
				volatile int* const awNowGx = reinterpret_cast<volatile int*>(awbase + 0x00B8DE0D8u);
				volatile int* const awNowGy = reinterpret_cast<volatile int*>(awbase + 0x00B8DE0DCu);
				volatile int* const awGoalX = reinterpret_cast<volatile int*>(awbase + 0x00B8E0CECu);
				volatile int* const awGoalY = reinterpret_cast<volatile int*>(awbase + 0x00B8E0CF0u);
				volatile int* const awMoveStart = reinterpret_cast<volatile int*>(awbase + 0x00B8E0CE8u);
				// [AutoWalkOscillate] pre-blackscreen original restored: black-repro random-walk removed + config-span removed; fixed-origin oscillation origX +/- 3.
				const int awSpan = 3;
				const int awNowX = *awNowGx;
				const int awNowY = *awNowGy;
				int awWrote = 0, awTarget = 0, awMs = 0;
				if (awWant == 1)
				{
					if (!s_awHaveOrig) { s_awOrigX = awNowX; s_awOrigY = awNowY; s_awHaveOrig = 1; s_awSide = 0; s_awNeed = 1; }
					if (s_awSide == 0 && awNowX >= s_awOrigX + awSpan) { s_awSide = 1; s_awNeed = 1; }
					else if (s_awSide == 1 && awNowX <= s_awOrigX - awSpan) { s_awSide = 0; s_awNeed = 1; }
					awTarget = (s_awSide == 0) ? (s_awOrigX + awSpan) : (s_awOrigX - awSpan);
					awMs = *awMoveStart;
					if (s_awNeed || awMs == 0)
					{
						*awGoalX = awTarget;
						*awGoalY = s_awOrigY;
						*awMoveStart = 1;
						s_awNeed = 0;
						awWrote = 1;
					}
				}
				else { s_awHaveOrig = 0; s_awSide = 0; s_awNeed = 0; }
				if (awWant != s_awLast || awWrote)
				{
					s_awLast = awWant;
					HANDLE wfh = CreateFileW(L"D:\\SA\\zmffk\\autowalk-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
					if (wfh != INVALID_HANDLE_VALUE) { char wkb[256]; int wkn = wsprintfA(wkb, "autowalk want=%d now=(%d,%d) orig=(%d,%d) side=%d target=%d ms=%d wrote=%d\r\n", (int)awWant, awNowX, awNowY, s_awOrigX, s_awOrigY, s_awSide, awTarget, awMs, awWrote); DWORD wkw = 0; WriteFile(wfh, wkb, (DWORD)wkn, &wkw, nullptr); CloseHandle(wfh); }
				}
			}
'@
  if ($d.IndexOf("processAutoLoginCommand(*context);") -lt 0) { throw "could not locate monitor anchor for auto-walk." }
  $d = $d.Replace("processAutoLoginCommand(*context);", $wkRep)
  if ($d -notmatch 'AutoWalkMemMove') { throw "monitor auto-walk memory-move patch failed." }
  Good 'applied monitor auto-walk WM_Move memory port (走路遇敵 = goalX/goalY/moveStart write, client self-walks)'
}
if ($d -notmatch 'blackWatchProc') {
  $bwFunc = @'
// [BlackWatch] dedicated 5ms sampler thread: SurfaceDate(0x593EE8) increments once per REAL drawn frame
// (client draw path 0x433C65). When it stalls, the field shows black/frozen. Log every no-draw GAP (>=70ms)
// and a 1s heartbeat with WALL-CLOCK time + full draw+net state, so a black flash at a noted clock time is
// matched to loop state. Fields: floor=nowFloor(map id; changes=map transition/disk load), rbl/wbl=net read/
// write buf len, snd=netproc_sending, sock=sockfd (server-wait shows here). Independent of the 50ms monitor loop.
static DWORD WINAPI blackWatchProc(LPVOID)
{
	const std::uintptr_t b = reinterpret_cast<std::uintptr_t>(GetModuleHandleW(nullptr));
	if (b == 0) { return 0; }
	volatile unsigned int* const bwFrame = reinterpret_cast<volatile unsigned int*>(b + 0x00193EE8u);
	volatile int* const bwNdc   = reinterpret_cast<volatile int*>(b + 0x00171524u);
	volatile int* const bwNdMax = reinterpret_cast<volatile int*>(b + 0x00171518u);
	volatile int* const bwSys   = reinterpret_cast<volatile int*>(b + 0x00171520u);
	volatile int* const bwProc  = reinterpret_cast<volatile int*>(b + 0x0017151Cu);
	volatile int* const bwGsf   = reinterpret_cast<volatile int*>(b + 0x002AE6F8u);
	volatile int* const bwPx    = reinterpret_cast<volatile int*>(b + 0x00B8DE0D8u);
	volatile int* const bwPy    = reinterpret_cast<volatile int*>(b + 0x00B8DE0DCu);
	volatile int* const bwFloor = reinterpret_cast<volatile int*>(b + 0x00B8DE0CCu);
	volatile int* const bwRbl   = reinterpret_cast<volatile int*>(b + 0x00B971B88u);
	volatile int* const bwWbl   = reinterpret_cast<volatile int*>(b + 0x00B971B8Cu);
	volatile int* const bwSnd   = reinterpret_cast<volatile int*>(b + 0x00B97615Cu);
	volatile int* const bwSock  = reinterpret_cast<volatile int*>(b + 0x00B971B90u);
	unsigned int lastFrame = *bwFrame;
	DWORD lastChange = GetTickCount();
	DWORD lastBeat = lastChange;
	unsigned int beatBaseFrame = lastFrame;
	int gapOpen = 0;
	for (;;)
	{
		Sleep(5);
		const DWORD nowT = GetTickCount();
		const unsigned int f = *bwFrame;
		SYSTEMTIME st; GetLocalTime(&st);
		char wc[16]; wsprintfA(wc, "%02d:%02d:%02d.%03d", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);
		if (f != lastFrame)
		{
			if (gapOpen)
			{
				const DWORD gap = nowT - lastChange;
				HANDLE h = CreateFileW(L"D:\\SA\\zmffk\\blackwatch.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
				if (h != INVALID_HANDLE_VALUE) { char bb[384]; int n = wsprintfA(bb, "%s GAP-END dur=%ums frame=%u ndc=%d ndmax=%d sys=%d proc=%d gsf=%d floor=%d rbl=%d wbl=%d snd=%d sock=%d pos=(%d,%d)\r\n", wc, gap, f, *bwNdc, *bwNdMax, *bwSys, *bwProc, *bwGsf, *bwFloor, *bwRbl, *bwWbl, *bwSnd, *bwSock, *bwPx, *bwPy); DWORD w = 0; WriteFile(h, bb, (DWORD)n, &w, nullptr); CloseHandle(h); }
				gapOpen = 0;
			}
			lastFrame = f; lastChange = nowT;
		}
		else
		{
			const DWORD gap = nowT - lastChange;
			if (gap >= 70u && !gapOpen)
			{
				gapOpen = 1;
				HANDLE h = CreateFileW(L"D:\\SA\\zmffk\\blackwatch.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
				if (h != INVALID_HANDLE_VALUE) { char bb[384]; int n = wsprintfA(bb, "%s GAP-START gap=%ums frame=%u ndc=%d ndmax=%d sys=%d proc=%d gsf=%d floor=%d rbl=%d wbl=%d snd=%d sock=%d pos=(%d,%d)\r\n", wc, gap, f, *bwNdc, *bwNdMax, *bwSys, *bwProc, *bwGsf, *bwFloor, *bwRbl, *bwWbl, *bwSnd, *bwSock, *bwPx, *bwPy); DWORD w = 0; WriteFile(h, bb, (DWORD)n, &w, nullptr); CloseHandle(h); }
			}
		}
		if (nowT - lastBeat >= 1000u)
		{
			const unsigned int fps = (f >= beatBaseFrame) ? (f - beatBaseFrame) : 0u;
			beatBaseFrame = f; lastBeat = nowT;
			HANDLE h = CreateFileW(L"D:\\SA\\zmffk\\blackwatch.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
			if (h != INVALID_HANDLE_VALUE) { char bb[384]; int n = wsprintfA(bb, "%s HB fps=%u frame=%u ndc=%d ndmax=%d sys=%d proc=%d gsf=%d floor=%d rbl=%d wbl=%d snd=%d sock=%d pos=(%d,%d)\r\n", wc, fps, f, *bwNdc, *bwNdMax, *bwSys, *bwProc, *bwGsf, *bwFloor, *bwRbl, *bwWbl, *bwSnd, *bwSock, *bwPx, *bwPy); DWORD w = 0; WriteFile(h, bb, (DWORD)n, &w, nullptr); CloseHandle(h); }
		}
	}
}
'@
  if ($d.IndexOf("void processAutoLoginCommand(MonitorContext& context) noexcept") -lt 0) { throw "blackwatch func anchor missing." }
  $d = $d.Replace("void processAutoLoginCommand(MonitorContext& context) noexcept", $bwFunc + "`r`n`r`nvoid processAutoLoginCommand(MonitorContext& context) noexcept")
  if ($d -notmatch 'blackWatchProc') { throw "blackwatch func inject failed." }
  $d = $d.Replace("Sleep((client05_readonly::kSpeedControlCompiled ||", "{ static int s_bwStarted = 0; if (!s_bwStarted) { s_bwStarted = 1; HANDLE bwth = CreateThread(nullptr, 0, blackWatchProc, nullptr, 0, nullptr); if (bwth != nullptr) { CloseHandle(bwth); } } }`r`n`t`tSleep((client05_readonly::kSpeedControlCompiled ||")
  if ($d -notmatch 's_bwStarted') { throw "blackwatch spawn inject failed." }
  Good 'applied BlackWatch 5ms frame-stall sampler (SurfaceDate 0x593EE8) -> D:\SA\zmffk\blackwatch.log'
}
if ($d -notmatch 'FastEncWndProc') {
  $feWpRep = @'
// [FastEncWndProc] sa_8001-IDENTICAL fast-encounter (快速遇敵). The launcher's autoWalk FAST branch
// is worker->move(QPoint(0,0),"gcgc") = a WALK packet (lssproto_W2_send) carrying the in-place "gcgc"
// step string. Client05-native equivalent: call lssproto_W2_send(sockfd,gx,gy,"gcgc") on the MAIN
// thread. W2 is the ORDINARY walk packet the client sends constantly, so the server accepts it (no
// disconnect, unlike the EN_send experiment) and the in-place steps accrue encounters. Client05 has
// no legacy WndProc, so the monitor installs a MINIMAL subclass that ONLY intercepts kFeSendMsg
// (SendMessage-marshaled to the client MAIN thread) and chains everything else to the original.
// ASLR off => fixed client VAs: lssproto_W2_send@0x4B72E0 void __cdecl(int,int,int,char*);
// sockfd@0xBD71B90; BattlingFlag@0x64F83C; nowGx@0xBCDE0D8 nowGy@0xBCDE0DC.
static const UINT kFeSendMsg = WM_APP + 0x1ECu;
static const UINT kEscapeMsg = WM_APP + 0x1EDu;
static const UINT kAutoWalkMsg = WM_APP + 0x1EFu;
static const UINT kFastBattleActMsg = WM_APP + 0x1F2u; // [FastBattleMsgFix] was 0x1F0u = collided with the exp-result window message (0x1F0). Moved to 0x1F2 so the RS-triggered exp message reaches the exp handler, not the fast-battle act handler.
static WNDPROC g_feOldWndProc = nullptr;
static HWND g_feHwnd = nullptr;
static DWORD g_fePid = 0u;
static int g_feOrigX = 0;
static int g_feOrigY = 0;
static int g_feOrigSet = 0;
static int g_awOrigX = 0;
static int g_awOrigY = 0;
static int g_awOrigSet = 0;
static LRESULT CALLBACK feWndProc(HWND fh, UINT fm, WPARAM fw, LPARAM fl)
{
	if (fm == kFeSendMsg)
	{
		const int fb = *(volatile int*)0x0064F83Cu;
		const unsigned int fs = *(volatile unsigned int*)0x0BD71B90u;
		if (fb == 0 && fs != 0u && fs != 0xFFFFFFFFu)
		{
			// fast-encounter (快速遇敵) — 런처 기전 = lssproto_W2_send in-place walk. [방향문자 확정: cnvServDir@0x45EC20
			// 디스어셈] a=北 b=東北 c=東 d=東南 e=南 f=西南 g=西 h=西北. 즉 런처의 "gcgc"=W,E,W,E 순수 카디널(상쇄).
			// 이 서버는 좌표를 (0,0) 대신 **현재타일(nowGx/nowGy)**로 보내야 걸음을 수락·상쇄한다(정상인 걷기조우 ③와 동일).
			// 지형(벽) 때문에 완전 상쇄가 안 되는 잔여 드리프트는 origin 방향으로 되돌리는 걸음으로 보정(같은 W2 걸음).
			const int cx = *(volatile int*)0x0BCDE0D8u;
			const int cy = *(volatile int*)0x0BCDE0DCu;
			// [FastEncFix 2026-08-07] pure in-place gcgc = launcher move(0,0,"gcgc") faithful. origin-capture + drift-correction
			// were an invention (not in launcher); a wrong origin (captured pre-login / mid-transition) made it walk-to-correct
			// forever -> drift + wall-jam + no encounter. gcgc (W,E,W,E) is net-zero in place so it CANNOT jam on a wall.
			// coords = current tile (this server requires it, see RULES). NO g_feOrig* used.
			char feDir[8]; feDir[0] = 'g'; feDir[1] = 'c'; feDir[2] = 'g'; feDir[3] = 'c'; feDir[4] = 0;
			// [FastEncFix2 2026-08-07] OPEN-TERRAIN test (cycle157) proved current-tile gcgc leaks on X (last-60 X span=11,
			// no walls) -> switch to launcher-faithful (0,0): lssproto_W2_send(p=(0,0),"gcgc") = move(QPoint(0,0),"gcgc") tcpserver 7133.
			// (0,0) = true in-place encounter roll (no coord walk -> no leak/drift). Gate on in-world (cx||cy != 0).
			if (cx != 0 || cy != 0) { ((void(__cdecl*)(int, int, int, char*))0x004B72E0u)((int)fs, 0, 0, feDir); }
		}
		return 0;
	}
	if (fm == kEscapeMsg)
	{
		// auto-escape (自動逃跑) — R0: 런처의 자동도주는 배틀 자동화 프레임워크(asyncBattleAction) 안에서만 돈다.
		// asyncBattleAction은 자동전투/빠른전투가 켜져야 진입하며 메뉴를 억제하고, playerDoBattleWork이
		// kAutoEscapeEnable을 제일 먼저 검사해 sendBattleCharEscapeAct("E")를 보낸다 — 게이트는 checkFlagState
		// (=내 차례, 아직 미행동). 이식: BattleMenuSuppressPatch를 autoEscape로 확장(메뉴 없는 진행) + "E"는
		// 반드시 **내 명령 차례**(BattleAnimFlag의 BattleMyNo 비트 clear)에만 송신 = 자동전투와 동일 게이트.
		const int eb = *(volatile int*)0x0064F83Cu;   // BattlingFlag
		const int ene = *(volatile int*)0x005A8080u;  // NoEscFlag
		const unsigned int es = *(volatile unsigned int*)0x0BD71B90u;  // sockfd
		const int emyNo = *(volatile int*)0x005A7E04u;   // BattleMyNo
		const int eanim = *(volatile int*)0x005A7E18u;   // BattleAnimFlag (acted bitmask)
		static DWORD s_aeSentTick = 0;
		const DWORD aeTick = GetTickCount();
		if (eb != 0 && ene == 0 && es != 0u && es != 0xFFFFFFFFu && emyNo >= 0 && emyNo < 20 && !(eanim & (1 << emyNo)) && (aeTick - s_aeSentTick) >= 700u)
		{
			*(volatile int*)0x0059DDE8u = 0;  // AI = AI_NONE (defensive)
			char eEsc[4] = { 'E', 0, 0, 0 };
			((void(__cdecl*)(int, char*))0x004B4BA0u)((int)es, eEsc);
			s_aeSentTick = aeTick;
		}
		return 0;
	}
	if (fm == kAutoWalkMsg)
	{
		// Native auto-walk (走路遇敵) — R0 re-port. Launcher mainthread.cpp:1922 = worker->move(current_pos, steps)
		// = lssproto_W2_send(sockfd, nowGx, nowGy, stepString) ("移動(封包)"). The step string is 4 side-flipping
		// groups of walk_len direction chars, so the char oscillates out-and-back (net-zero) accruing encounters.
		// Unlike fast-encounter's in-place (0,0)"gcgc", 走路遇敵 sends the REAL tile so the char physically walks.
		// wParam = walk_dir (0=E/W,1=N/S,2=random->E/W here), lParam = walk_len (clamped 1..6). W2@0x4B72E0.
		const int wb = *(volatile int*)0x0064F83Cu;
		const unsigned int ws = *(volatile unsigned int*)0x0BD71B90u;
		if (wb == 0 && ws != 0u && ws != 0xFFFFFFFFu)
		{
			// [F0] 런처 move(current_pos, steps): current_pos = autoWalk 진입 시 1회 캡처한 고정 원점(mainthread.cpp:1874).
			//   실시간 nowGx/nowGy를 매 전송 base로 넣던 것이 서남 드리프트 원인(잔여오차 누적) → 고정 원점(g_awOrig*)으로 복원.
			//   g_awOrigSet==0(캡처 전) 방어: 라이브 폴백. 정상 경로에선 모니터가 캡처 후에만 전송.
			const int wnx = g_awOrigSet ? g_awOrigX : *(volatile int*)0x0BCDE0D8u;
			const int wny = g_awOrigSet ? g_awOrigY : *(volatile int*)0x0BCDE0DCu;
			int wdir = (int)fw; int wlen = (int)fl;
			if (wlen < 1) wlen = 1; if (wlen > 6) wlen = 6;
			// [F0] 런처 走路遇敵 무변형 이식 (mainthread.cpp:1933-1986). 4그룹 × walk_len, 매 그룹 방향 토글,
			//   walk_dir==0: 'b'(東)/'f'(西), walk_dir==1: 'e'(南)/'a'(北); move(current_pos, steps) = W2(nowGx,nowGy).
			//   문자는 런처가 쓰는 그대로('b'/'f'/'a'/'e') — cnvServDir 근거로 'c'/'g'로 바꿨던 건 F0 위반(발명)이라 폐기.
			//   이동 거리는 오너의 走路距離 설정(walk_len)이 제어. 육안 이동은 이 구조에서 나옴.
			static int s_awSide = 0;
			char wsteps[32]; int wp = 0;
			for (int gi = 0; gi < 4; ++gi)
			{
				char dc;
				if (wdir == 1) dc = s_awSide ? 'e' : 'a';   // 南 : 北
				else           dc = s_awSide ? 'b' : 'f';   // 東 : 西
				s_awSide = s_awSide ? 0 : 1;                // 每次循環切換方向
				for (int j = 0; j < wlen && wp < 28; ++j) wsteps[wp++] = dc;
			}
			wsteps[wp] = 0;
			((void(__cdecl*)(int, int, int, char*))0x004B72E0u)((int)ws, wnx, wny, wsteps);
		}
		return 0;
	}
	return g_feOldWndProc != nullptr ? CallWindowProcW(g_feOldWndProc, fh, fm, fw, fl) : DefWindowProcW(fh, fm, fw, fl);
}
static BOOL CALLBACK feFindWnd(HWND fh, LPARAM)
{
	DWORD wpid = 0u; GetWindowThreadProcessId(fh, &wpid);
	if (wpid == g_fePid && GetWindow(fh, GW_OWNER) == nullptr && IsWindowVisible(fh) != FALSE) { g_feHwnd = fh; return FALSE; }
	return TRUE;
}
void processAutoLoginCommand(MonitorContext& context) noexcept
'@
  if ($d.IndexOf("void processAutoLoginCommand(MonitorContext& context) noexcept") -lt 0) { throw "could not locate processAutoLoginCommand definition for WndProc inject." }
  $d = $d.Replace("void processAutoLoginCommand(MonitorContext& context) noexcept", $feWpRep)
  if ($d -notmatch 'FastEncWndProc') { throw "WndProc file-scope inject failed." }
  Good 'applied FastEnc WndProc subclass infra (main-thread lssproto_W2_send gcgc = sa_8001 快速遇敵)'
}
if ($d -notmatch 'kBattleActMsg') {
  $d = $d.Replace("static const UINT kEscapeMsg = WM_APP + 0x1EDu;", "static const UINT kEscapeMsg = WM_APP + 0x1EDu;`r`n`tstatic const UINT kBattleActMsg = WM_APP + 0x1EEu;`r`n`tstatic volatile LONG g_baCharType = -1;`r`n`tstatic volatile LONG g_baCharTarget = 0;`r`n`tstatic volatile LONG g_baPetType = -1;`r`n`tstatic volatile LONG g_baPetTarget = 0;`r`n`tstatic DWORD g_baCharSentTick = 0;`r`n`tstatic DWORD g_baPetSentTick = 0;`r`n`tstatic volatile LONG g_baCharEnemy = 0;`r`n`tstatic volatile LONG g_baCharLevel = 0;`r`n`tstatic volatile LONG g_baAutoEscape = 0;`r`n`tstatic volatile LONG g_baFallEscape = 0;`r`n`tstatic int feBattleAlive(int pos) { if (pos < 0 || pos >= 20) return 0; const unsigned int ent = *(volatile unsigned int*)(0x0D6AEAA0u + (unsigned int)pos * 4u); if (ent == 0u) return 0; if (*(volatile unsigned int*)(ent + 8u) == 0u) return 0; if (*(volatile int*)(ent + 36u) != 0) return 0; if (*(volatile int*)(ent + 120u) <= 0) return 0; return 1; }")
  if ($d -notmatch 'kBattleActMsg') { throw "battle-act msg const patch failed." }
  Good 'applied battle-act message const + setting globals'
}
if ($d -notmatch 'feSelectableEnemy') {
  # Faithful port of tcpserver.cpp battle-target selection helpers (R0). action struct (client _PET_ITEM build):
  #   func@8, deathFlag@0x24, hp@0x78, maxHp@0x80, mp@0x84, level@0x8C. p_party@0xD6AEAA0 (action*[]).
  #   magic@0xBD812E0 stride0x70 {mp@4,target@0xA}; profession_skill@0xBD88168 stride0xC0 {target@4,costmp@0xB8}.
  $baHelpers = @'
	static unsigned int feBObj(int pos) { if (pos < 0 || pos >= 20) return 0u; return *(volatile unsigned int*)(0x0D6AEAA0u + (unsigned int)pos * 4u); }
	static int feBCRideFlag(int myPos) {
		// [BC-rideFlag] launcher fallDownEscapeFun reads bt.objects[myPos].rideFlag from the BC packet (NOT client memory).
		// BC status buf @0x005A2DF8 (char[]): "BC|field|pos|name|free|model|lv|hp|max|status|rideFlag|rideName|rideLv|rideHp|rideMax|pos|...".
		// tokens: 0=BC,1=field; unit i pos@(i*13+2), rideFlag@(i*13+10)=pos+8. F0: tcpserver BC parse i*13+10. return 1=ride,0=fell,-1=unknown.
		const volatile char* bc = (const volatile char*)0x005A2DF8u;
		if (bc[0] != 'B' || bc[1] != 'C' || bc[2] != '|') return -1;
		int idx = 3, tokNum = 1, rideTok = -1;
		while (bc[idx] != '\0' && idx < 4096) {
			long v = 0; int any = 0, hexok = 1;
			while (bc[idx] != '\0' && bc[idx] != '|' && idx < 4096) {
				const char c = bc[idx++]; int dgt;
				if (c >= '0' && c <= '9') dgt = c - '0';
				else if (c >= 'A' && c <= 'F') dgt = c - 'A' + 10;
				else if (c >= 'a' && c <= 'f') dgt = c - 'a' + 10;
				else { hexok = 0; dgt = 0; }
				v = v * 16 + dgt; any = 1;
			}
			if (rideTok == tokNum) return (hexok && any) ? (int)v : -1;
			if (tokNum >= 2 && ((tokNum - 2) % 13) == 0 && hexok && any && v == (long)myPos) rideTok = tokNum + 8;
			if (bc[idx] == '|') ++idx;
			++tokNum;
		}
		return -1;
	}
	// valid battle unit = launcher bt.enemies criteria (modelid>0 && maxHp>0 && level>0 && !DEAD), client-native.
	static int feBValid(int pos) { unsigned int e = feBObj(pos); if (e == 0u) return 0; if (*(volatile unsigned int*)(e + 8u) == 0u) return 0; if (*(volatile int*)(e + 0x24u) != 0) return 0; if (*(volatile int*)(e + 0x78u) <= 0) return 0; if (*(volatile int*)(e + 0x80u) <= 0) return 0; if (*(volatile int*)(e + 0x8Cu) <= 0) return 0; return 1; }
	// compareBattleObjects (tcpserver 10151): hp asc, maxHp asc, level asc, then order table. returns 1 if a<b.
	static int feCmpBattle(int pa, int pb) {
		unsigned int ea = feBObj(pa), eb = feBObj(pb);
		int ha = *(volatile int*)(ea + 0x78u), hb = *(volatile int*)(eb + 0x78u); if (ha != hb) return ha < hb ? 1 : 0;
		int ma = *(volatile int*)(ea + 0x80u), mb = *(volatile int*)(eb + 0x80u); if (ma != mb) return ma < mb ? 1 : 0;
		int la = *(volatile int*)(ea + 0x8Cu), lb = *(volatile int*)(eb + 0x8Cu); if (la != lb) return la < lb ? 1 : 0;
		static const int order[20] = { 19,17,15,16,18,14,12,10,11,13,8,6,5,7,9,3,1,0,2,4 };
		int ia = 0, ib = 0; for (int k = 0; k < 20; ++k) { if (order[k] == pa) ia = k; if (order[k] == pb) ib = k; } return ia < ib ? 1 : 0;
	}
	// isTouchable (tcpserver 10231): a back-row pos is unreachable while its front-row counterpart is alive.
	static int feIsTouchable(int pos) {
		static const int bk[10] = { 13,11,10,12,14,3,1,0,2,4 };
		static const int fr[10] = { 18,16,15,17,19,8,6,5,7,9 };
		for (int k = 0; k < 10; ++k) { if (bk[k] == pos) { return feBValid(fr[k]) ? 0 : 1; } } return 1;
	}
	// feAiValid = GetBattelTarget per-slot predicate (battleMenu.cpp 3192): func!=NULL, hp>0, not self/own-pet.
	static int feAiValid(int index, int myNo) {
		unsigned int e = feBObj(index); if (e == 0u) return 0;
		if (*(volatile unsigned int*)(e + 8u) == 0u) return 0;   // p_party[index]->func == NULL
		if (*(volatile int*)(e + 0x78u) <= 0) return 0;          // p_party[index]->hp <= 0
		if (index == myNo || index == myNo + 5) return 0;        // skip self / own pet
		return 1;
	}
	// Client-native attack order (battleMenu.cpp Ordinal): enemy FRONT row top->bottom, then BACK row top->bottom.
	//   front(myNo<10) = 19,17,15,16,18 ; back = 14,12,10,11,13. This equals the F5 battle-situation display order
	//   the owner annotated (front 1..5, back R6..R10). Front entirely before back.
	static const int feOrdinal[20] = { 19,17,15,16,18, 14,12,10,11,13, 9,7,5,6,8, 4,2,0,1,3 };
	// getBattleSelectableEnemyTarget: first live enemy in the native display order (front-first, top->bottom).
	static int feSelectableEnemy(int myNo) {
		int i, end; if (myNo < 10) { i = 0; end = 10; } else { i = 10; end = 20; }
		for (; i < end; ++i) { int index = feOrdinal[i]; if (feAiValid(index, myNo)) return index; }
		return (myNo < 10) ? 19 : 5;
	}
	// EB (owner spec): enemy BACK row first (top->bottom), then FRONT row; same native predicate.
	static int feSelectableBackFirst(int myNo) {
		int bi, bend, fi, fend;
		if (myNo < 10) { bi = 5; bend = 10; fi = 0; fend = 5; }     // enemy back = Ordinal[5..9](10-14), front = Ordinal[0..4](15-19)
		else           { bi = 15; bend = 20; fi = 10; fend = 15; }  // enemy back = Ordinal[15..19](0-4), front = Ordinal[10..14](5-9)
		for (int i = bi; i < bend; ++i) { int index = feOrdinal[i]; if (feAiValid(index, myNo)) return index; }
		for (int i = fi; i < fend; ++i) { int index = feOrdinal[i]; if (feAiValid(index, myNo)) return index; }
		return (myNo < 10) ? 19 : 5;
	}
	// getBattleSelectableAllieTarget (tcpserver 10380): first valid ally after front-first sort.
	static int feSelectableAllie(int myNo) {
		int aMin, aMax; if (myNo < 10) { aMin = 0; aMax = 9; } else { aMin = 10; aMax = 19; }
		int def = (myNo < 10) ? 5 : 15;
		int fro[10], frn = 0, bac[10], bacn = 0;
		for (int i = aMin; i <= aMax; ++i) { if (!feBValid(i)) continue; if ((i >= 15 && i <= 19) || (i >= 5 && i <= 9)) fro[frn++] = i; else bac[bacn++] = i; }
		if (frn == 0 && bacn == 0) return def;
		for (int a = 1; a < frn; ++a) { int v = fro[a], b = a - 1; while (b >= 0 && !feCmpBattle(fro[b], v)) { fro[b + 1] = fro[b]; --b; } fro[b + 1] = v; }
		for (int a = 1; a < bacn; ++a) { int v = bac[a], b = a - 1; while (b >= 0 && !feCmpBattle(bac[b], v)) { bac[b + 1] = bac[b]; --b; } bac[b + 1] = v; }
		if (frn > 0) return fro[0]; return bac[0];
	}
	// ONE_ROW -> client wire row code (battleMenu.cpp): 0-4:26, 5-9:25, 10-14:23, 15-19:24; default enemy front row.
	static int feRowCode(int seed, int myNo) {
		if (seed >= 0 && seed <= 4) return 26; if (seed >= 5 && seed <= 9) return 25;
		if (seed >= 10 && seed <= 14) return 23; if (seed >= 15 && seed <= 19) return 24;
		return (myNo < 10) ? 24 : 25;
	}
	// fixCharTargetByMagicIndex (tcpserver 10506) -> client-native wire codes (battleMenu.cpp switch(magic.target)).
	static int feMagicFix(int mi, int seed, int myNo) {
		short mt = *(volatile short*)(0x0BD812E0u + (unsigned int)mi * 0x70u + 0x0Au);
		switch (mt) {
		case 0: return myNo;                                                        // MYSELF
		case 1: return (seed >= 0 && seed < 20) ? seed : feSelectableEnemy(myNo);    // OTHER (any single)
		case 2: return (myNo < 10) ? 20 : 21;                                       // ALLMYSIDE
		case 3: return (myNo < 10) ? 21 : 20;                                       // ALLOTHERSIDE
		case 4: return 22;                                                          // ALL
		case 5: return -1;                                                          // NONE
		case 6: return (seed == myNo) ? -1 : seed;                                  // OTHERWITHOUTMYSELF
		case 7: if (seed == myNo || seed == myNo + 5) return -1; return seed;        // WITHOUTMYSELFANDPET
		case 8: return (seed >= 0 && seed < 10) ? 20 : 21;                          // WHOLEOTHERSIDE (side of target)
		case 9: return (seed >= 0 && seed < 20) ? seed : feSelectableEnemy(myNo);    // SINGLE
		case 10: return feRowCode((seed >= 0 && seed < 20) ? seed : feSelectableEnemy(myNo), myNo); // ONE_ROW
		case 11: return (myNo < 10) ? 21 : 20;                                      // ALL_ROWS (all enemies)
		default: return (seed >= 0 && seed < 20) ? seed : feSelectableEnemy(myNo);
		}
	}
	// fixCharTargetBySkillIndex (tcpserver 10679) -> client-native (battleMenu.cpp BATTLE_PROWAZA switch(skill.target)).
	static int feSkillFix(int si, int seed, int myNo) {
		short st = *(volatile short*)(0x0BD88168u + (unsigned int)si * 0xC0u + 0x04u);
		switch (st) {
		case 0: return myNo;                                                        // MYSELF
		case 2: return (myNo < 10) ? 20 : 21;                                       // ALLMYSIDE
		case 3: return (myNo < 10) ? 21 : 20;                                       // ALLOTHERSIDE
		case 4: return 22;                                                          // ALL
		case 5: return -1;                                                          // NONE
		case 8: return feRowCode((seed >= 0 && seed < 20) ? seed : feSelectableEnemy(myNo), myNo); // ONE_ROW
		default: return (seed >= 0 && seed < 20) ? seed : feSelectableEnemy(myNo);   // OTHER/single/line/death
		}
	}
	// Shared char-action decode for round/cross/normal rows. Faithful to selectRoundFun/intervalRoundFun
	// decode tail (tcpserver 8215-8304 / 8704-8793): tagetHash seed -> attack/magic/skill + MP gate.
	// Returns 1 = cmd written (fire this row); 0 = row does NOT fire (fall through to next priority).
	//   round/cross semantics: magic fix-fail or MP-fail => 0; skill fix-fail => 0; skill MP-fail => attack(1);
	//   attack invalid-seed => attack selectableEnemy(1); defense/escape => 1; seed unresolved => 0.
	static int feCharDecodeRC(int actionType, unsigned int tflags, int myNo, char* cmd, int* pjt) {
		*pjt = -2;
		if (actionType == 1) { cmd[0] = 'G'; cmd[1] = 0; return 1; }   // defense (sendBattleCharDefenseAct)
		if (actionType == 2) { cmd[0] = 'E'; cmd[1] = 0; return 1; }   // escape  (sendBattleCharEscapeAct)
		int seed = -1;
		if (tflags == 0x1u) seed = myNo;                          // kSelectSelf
		else if (tflags == 0x2u) seed = myNo + 5;                 // kSelectPet
		else if (tflags == 0x4u) seed = feSelectableAllie(myNo);  // kSelectAllieAny
		else if (tflags == 0x8u) seed = (myNo < 10) ? 20 : 21;    // kSelectAllieAll -> my side code
		else if (tflags == 0x10u) seed = feSelectableEnemy(myNo); // kSelectEnemyAny
		else if (tflags == 0x20u) seed = (myNo < 10) ? 21 : 20;   // kSelectEnemyAll -> enemy side code
		else if (tflags == 0x40u) seed = (myNo < 10) ? 24 : 25;   // kSelectEnemyFront -> enemy front-row code
		else if (tflags == 0x80u) seed = feSelectableBackFirst(myNo); // kSelectEnemyBack (owner EB) -> back-row-first single target
		else { for (int i = 10; i < 20; ++i) { if (tflags & (1u << i)) { seed = i - 10; break; } } }
		if (seed == -1) return 0;                                 // -1==tempTarget && no individual bit => break
		if (actionType == 0) {                                    // basic attack (sendBattleCharAttackAct)
			int at = (seed >= 0 && seed < 20) ? seed : feSelectableEnemy(myNo);
			wsprintfA(cmd, "H|%X", at); return 1;
		}
		const int mi = actionType - 3;
		const int charMp = *(volatile int*)(feBObj(myNo) + 0x84u);
		if (mi > 8) {                                             // profession/job skill (sendBattleCharJobSkillAct "P")
			const int si = mi - 9;
			const int t = feSkillFix(si, seed, myNo); *pjt = t;
			if (t < 0) return 0;                                  // fix-fail => fall through
			const int cost = *(volatile int*)(0x0BD88168u + (unsigned int)si * 0xC0u + 0xB8u);
			if (cost > charMp) { wsprintfA(cmd, "H|%X", feSelectableEnemy(myNo)); return 1; } // MP-fail => attack
			wsprintfA(cmd, "P|%X|%X", si, t); return 1;
		}
		const int t = feMagicFix(mi, seed, myNo); *pjt = t;       // magic (sendBattleCharMagicAct "J")
		if (t < 0) return 0;                                      // fix-fail => fall through
		const int cost = *(volatile int*)(0x0BD812E0u + (unsigned int)mi * 0x70u + 0x04u);
		if (cost > charMp) return 0;                              // MP-fail => fall through (round/cross break)
		wsprintfA(cmd, "J|%X|%X", mi, t); return 1;
	}
	// ==== battle-tab char ROUND row (selectRoundFun 8177) + CROSS row (intervalRoundFun 8685) + delay(7235) ====
	static volatile LONG g_baCRRound = 0;   // kBattleCharRoundActionRoundValue (0=not use, else 1-based round)
	static volatile LONG g_baCREnemy = 0;   // kBattleCharRoundActionEnemyValue (0=not use, else enemies.size()>N)
	static volatile LONG g_baCRLevel = 0;   // kBattleCharRoundActionLevelValue (0=not use, else minLv>N*10)
	static volatile LONG g_baCRType = 0;    // kBattleCharRoundActionTypeValue (0 atk/1 def/2 esc/3+ magic/skill)
	static volatile LONG g_baCRTarget = 0;  // kBattleCharRoundActionTargetValue (kSelect* flags)
	static volatile LONG g_baCCEnable = 0;  // kBattleCrossActionCharEnable
	static volatile LONG g_baCCRound = 0;   // kBattleCharCrossActionRoundValue (interval = value+1)
	static volatile LONG g_baCCType = 0;    // kBattleCharCrossActionTypeValue
	static volatile LONG g_baCCTarget = 0;  // kBattleCharCrossActionTargetValue
	static volatile LONG g_baDelay = 0;     // kBattleActionDelayValue (ms; per-turn pre-action delay)
	static int g_baCrossCnt = 0;            // client-side battleCrossActionCounter_ (reset at battle start)
	static int g_baCrossFireLatch = 0;      // 1 on the round the cross counter matched (consumed this round)
	static int g_baCrossLastTurn = -1;      // svTurn of last cross-counter advance (advance once per round)
	static int g_baBatTurn = -1;            // svTurn tracker for battle-start (turn-backwards) counter reset
	static int g_baDelayTurn = -1;          // svTurn the per-turn delay timer was armed for
	static DWORD g_baDelayTick = 0;         // GetTickCount when delay timer armed
	// ==== battle-tab PET round (selectRound, BUG-FIXED keys) + cross (intervalRound, modulo) ====
	static volatile LONG g_baPRRound = 0; static volatile LONG g_baPREnemy = 0; static volatile LONG g_baPRLevel = 0;
	static volatile LONG g_baPRType = 0; static volatile LONG g_baPRTarget = 0;
	static volatile LONG g_baPCEnable = 0; static volatile LONG g_baPCRound = 0; static volatile LONG g_baPCType = 0; static volatile LONG g_baPCTarget = 0;
	// fePetSeed: launcher pet tagetHash (tcpserver 9505-9586), incl extended Leader/Teammate(+pet) via alliemin.
	static int fePetSeed(unsigned int tflags, int myNo, int alliemin) {
		if (tflags & 0x10u) return feSelectableEnemy(myNo);           // EnemyAny
		if (tflags & 0x20u) return 21;                                // EnemyAll (round literal 21 == TARGET_SIDE_LEFT)
		if (tflags & 0x40u) return (myNo < 10) ? 24 : 25;             // EnemyFront one-row
		if (tflags & 0x80u) return feSelectableBackFirst(myNo);      // EnemyBack (owner EB) -> back-row-first single target
		if (tflags & 0x1u)  return myNo;                              // Self
		if (tflags & 0x2u)  return myNo + 5;                          // Pet
		if (tflags & 0x4u)  return feSelectableAllie(myNo);           // AllieAny
		if (tflags & 0x8u)  return 20;                                // AllieAll (TARGET_SIDE_RIGHT)
		if (tflags & (1u<<10)) return alliemin + 0;                   // Leader
		if (tflags & (1u<<13)) return alliemin + 0 + 5;               // LeaderPet
		if (tflags & (1u<<11)) return alliemin + 1;                   // Teammate1
		if (tflags & (1u<<16)) return alliemin + 1 + 5;               // Teammate1Pet
		if (tflags & (1u<<12)) return alliemin + 2;                   // Teammate2
		if (tflags & (1u<<17)) return alliemin + 2 + 5;               // Teammate2Pet
		if (tflags & (1u<<14)) return alliemin + 3;                   // Teammate3
		if (tflags & (1u<<18)) return alliemin + 3 + 5;               // Teammate3Pet
		if (tflags & (1u<<15)) return alliemin + 4;                   // Teammate4
		if (tflags & (1u<<19)) return alliemin + 4 + 5;               // Teammate4Pet
		return -1;
	}
	// fePetFix: fixPetTargetBySkillIndex (tcpserver 10875) via petSkill[battlePetNoBak][si]@0xBD87220 (stride 742/106, target@+6).
	//   returns fixed target (>=0 send) or <0 (reject: OOB skill/pet, invalid skill, or type-7 exclusion).
	static int fePetFix(int skillIdx, int oldtarget, int myNo) {
		if (skillIdx < 0 || skillIdx >= 7) return -1;                 // >= MAX_PET_SKILL
		const int petNo = *(volatile int*)0x0056B8B0u;                // battlePetNoBak (acting pet)
		if (petNo < 0 || petNo >= 5) return -1;                       // MAX_PET
		const unsigned int ps = 0x0BD87220u + (unsigned int)petNo * 742u + (unsigned int)skillIdx * 106u;
		if (*(volatile short*)(ps + 0u) == 0) return -1;              // useFlag==0 (invalid)
		const short st = *(volatile short*)(ps + 6u);                 // PET_SKILL.target
		int t = oldtarget;
		switch (st) {
		case 0: t = myNo + 5; break;                                  // MYSELF
		case 2: t = (myNo < 10) ? 20 : 21; break;                     // ALLMYSIDE
		case 3: t = (oldtarget < 10) ? 20 : 21; break;                // ALLOTHERSIDE
		case 4: t = 22; break;                                        // ALL
		case 5: t = myNo + 5; break;                                  // NONE
		case 1: case 6: if (oldtarget < 0 || oldtarget >= 20) t = (myNo < 10) ? 19 : 9; break;   // OTHER/OTHERWITHOUTMYSELF
		case 8: case 11:                                              // ONE_ROW/ONE_ROW_ALL
			if (oldtarget >= 0 && oldtarget <= 4) t = 26; else if (oldtarget >= 5 && oldtarget <= 9) t = 25;
			else if (oldtarget >= 10 && oldtarget <= 14) t = 23; else if (oldtarget >= 15 && oldtarget <= 19) t = 24;
			else t = (myNo < 10) ? 24 : 25; break;
		case 7: { int mn, mx, row; if (myNo < 10) { mn = 0; mx = 19; row = 24; } else { mn = 10; mx = 19; row = 25; }   // WITHOUTMYSELFANDPET
			if (oldtarget < mn || oldtarget > mx) t = -1; else if (oldtarget == myNo + 5 || oldtarget == myNo) t = -1; else t = row; } break;
		default: break;                                               // ONE_LINE/DEATH/WHOLEOTHERSIDE: keep oldtarget
		}
		return t;
	}
	static volatile LONG g_baMHEnable = 0; static volatile LONG g_baMHTarget = 0; static volatile LONG g_baMHChar = 0; static volatile LONG g_baMHPet = 0; static volatile LONG g_baMHAllie = 0; static volatile LONG g_baMHMagic = 0; static volatile LONG g_baSkillMpEn = 0; static volatile LONG g_baSkillMpVal = 0; static volatile LONG g_baItemMpEn = 0; static volatile LONG g_baItemMpVal = 0; static volatile LONG g_walkDelay = 0;
	// battle-tab MAGIC HEAL (magicHealFun tcpserver 8313-8425). Client05 memory substrate (feBObj); issued via existing "J"/"P".
	//   launcher order self(checkCharHp useequal=false '<') -> pet(inline '<=' +alive) -> allie(checkAllieHp false '<').
	//   hp% = util::percent (floor, but >=1 if hp>0). status@0x90 DEAD=0x2 HIDE=0x200. MP gate = feCharDecodeRC cost tables.
	//   ride(mount)-heal branch (tcpserver 8334) omitted: this server/owner has no mount. magicIndex = g_baMHMagic-3 (same enc).
	static int feHpPct(int hp, int mx) { if (hp <= 0 || mx <= 0) return 0; int d = (int)((long long)hp * 100 / mx); if (d == 0) d = 1; return d; }
	static int feHealAlive(int pos) { unsigned int e = feBObj(pos); if (e == 0u) return 0; if (*(volatile int*)(e + 0x78u) <= 0) return 0; if (*(volatile int*)(e + 0x80u) <= 0) return 0; int st = *(volatile int*)(e + 0x90u); if (st & 0x2) return 0; if (st & 0x200) return 0; return 1; }
	static int feMagicHealRC(int myNo, char* cmd) {
		const unsigned int tf = (unsigned int)g_baMHTarget;
		const int charP = (int)g_baMHChar, petP = (int)g_baMHPet, allieP = (int)g_baMHAllie;
		int tgt = -1;
		if (tf & 0x1u) { unsigned int e = feBObj(myNo); if (e != 0u) { int hp = *(volatile int*)(e + 0x78u), mx = *(volatile int*)(e + 0x80u); if (mx > 0 && feHpPct(hp, mx) < charP) tgt = myNo; } }
		if (tgt < 0 && (tf & 0x2u)) { int pp = myNo + 5; if (feHealAlive(pp)) { unsigned int e = feBObj(pp); int hp = *(volatile int*)(e + 0x78u), mx = *(volatile int*)(e + 0x80u); if (feHpPct(hp, mx) <= petP) tgt = pp; } }
		if (tgt < 0 && (tf & 0xCu)) { int aMin, aMax; if (myNo < 10) { aMin = 0; aMax = 9; } else { aMin = 10; aMax = 19; } for (int i = aMin; i <= aMax; ++i) { if (!feHealAlive(i)) continue; unsigned int e = feBObj(i); int hp = *(volatile int*)(e + 0x78u), mx = *(volatile int*)(e + 0x80u); if (feHpPct(hp, mx) < allieP) { tgt = i; break; } } }
		if (tgt < 0) return 0;
		const int mi = (int)g_baMHMagic - 3;
		if (mi < 0) return 0;
		const int charMp = *(volatile int*)(feBObj(myNo) + 0x84u);
		if (mi > 8) { const int si = mi - 9; const int t = feSkillFix(si, tgt, myNo); if (t < 0) return 0; const int cost = *(volatile int*)(0x0BD88168u + (unsigned int)si * 0xC0u + 0xB8u); if (cost > charMp) return 0; wsprintfA(cmd, "P|%X|%X", si, t); return 1; }
		const int t = feMagicFix(mi, tgt, myNo); if (t < 0) return 0;
		const int cost = *(volatile int*)(0x0BD812E0u + (unsigned int)mi * 0x70u + 0x04u);
		if (cost > charMp) return 0;
		wsprintfA(cmd, "J|%X|%X", mi, t); return 1;
	}
	static const UINT kNormalHealMsg = WM_APP + 0x1F1u;
	static volatile LONG g_nmhEnable = 0; static volatile LONG g_nmhChar = 0; static volatile LONG g_nmhMagic = 0; static volatile LONG g_nmhPet = 0; static volatile LONG g_nmhAllie = 0; static volatile LONG g_nmhIMpEn = 0; static volatile LONG g_nmhIMpVal = 0;
	// [NormalHeal] field magic-heal RC (F0 autoHeal 2439-2500 "平時精靈補血"): self->pet->ride->teammate.
	//   pc@0xBD770F8 hp+0x10/mx+0x14/mp+0x18/battlePetNo(short)+0xAA/ridePetNo(int)+0x5118/status+0xA4(PARTY0x200|LEADER0x100).
	//   pet[]@0xBD816D0 stride0xB78 hp+0x08/mx+0x0C/lv+0x20 ; party[]@0xBD85028 stride0x30 useFlag+0/lv+0x08/mx+0x0C/hp+0x10.
	//   magic[]@0xBD812E0 stride0x70 cost+0x04/target+0x0A. target self=0/pet=battlePetNo+1/ride=ridePetNo+1/teammate=idx+MAX_PET(5).
	static int feNMHPct(int hp, int mx) { if (mx <= 0) return -1; int p = (hp <= 0) ? 0 : (int)((long long)hp * 100 / mx); if (p == 0 && hp > 0) p = 1; return p; }
	static int feNormalMagicHealRC(int* pMi, int* pTarget) {
		const int charP = (int)g_nmhChar, petP = (int)g_nmhPet, allieP = (int)g_nmhAllie;
		if (charP <= 0 && petP <= 0 && allieP <= 0) return 0;
		int target = -1;
		if (charP > 0) { const int p = feNMHPct(*(volatile int*)0x0BD77108u, *(volatile int*)0x0BD7710Cu); if (p >= 0 && p < charP) target = 0; }
		if (target < 0 && petP > 0) { const int bpn = (int)*(volatile short*)(0x0BD770F8u + 0xAAu); if (bpn >= 0 && bpn < 5) { const unsigned int pb = 0x0BD816D0u + (unsigned int)bpn * 0xB78u; const int lv = *(volatile int*)(pb + 0x20u); const int p = feNMHPct(*(volatile int*)(pb + 0x08u), *(volatile int*)(pb + 0x0Cu)); if (lv > 0 && p >= 0 && p < petP) target = bpn + 1; } }
		if (target < 0 && petP > 0) { const int rpn = *(volatile int*)0x0BD7C210u; if (rpn >= 0 && rpn < 5) { const unsigned int pb = 0x0BD816D0u + (unsigned int)rpn * 0xB78u; const int lv = *(volatile int*)(pb + 0x20u); const int p = feNMHPct(*(volatile int*)(pb + 0x08u), *(volatile int*)(pb + 0x0Cu)); if (lv > 0 && p >= 0 && p < petP) target = rpn + 1; } }
		if (target < 0 && allieP > 0) { const unsigned int st = *(volatile unsigned int*)(0x0BD770F8u + 0xA4u); if ((st & 0x300u) != 0u) { for (int i = 0; i < 5; ++i) { const unsigned int qb = 0x0BD85028u + (unsigned int)i * 0x30u; if (*(volatile short*)(qb + 0x00u) == 0) continue; const int lv = *(volatile int*)(qb + 0x08u); const int p = feNMHPct(*(volatile int*)(qb + 0x10u), *(volatile int*)(qb + 0x0Cu)); if (lv > 0 && p >= 0 && p < allieP) { target = i + 5; break; } } } }
		if (target < 0) return 0;
		const int mi = (int)g_nmhMagic - 3; if (mi < 0 || mi > 8) return 0;
		const short mt = *(volatile short*)(0x0BD812E0u + (unsigned int)mi * 0x70u + 0x0Au);
		if (mt != 0 && mt != 1) return 0;
		if (mt == 0 && target != 0) return 0;
		const int cost = *(volatile int*)(0x0BD812E0u + (unsigned int)mi * 0x70u + 0x04u);
		if (cost > *(volatile int*)0x0BD77110u) return 0;
		*pMi = mi; *pTarget = target; return 1;
	}
	// [ItemMp] MP회복 아이템 = 메모에 "기력"(CP949 B1E2B7C2) AND "회복"(C8B8BAB9) 둘 다 포함. pc.item[]@0xBD771BC stride0x17C useFlag@+0xDC memo@+0x114.
	static int feMemHas(const char* hay, const unsigned char* ndl, int nlen) {
		int hl = 0; while (hl < 84 && hay[hl] != '\0') ++hl;
		for (int i = 0; i + nlen <= hl; ++i) { int k = 0; for (; k < nlen; ++k) { if ((unsigned char)hay[i + k] != ndl[k]) break; } if (k == nlen) return 1; }
		return 0;
	}
	static int feFindMpItem() {
		static const unsigned char kwG[4] = { 0xB1u, 0xE2u, 0xB7u, 0xC2u };
		static const unsigned char kwH[4] = { 0xC8u, 0xB8u, 0xBAu, 0xB9u };
		for (int i = 0; i < 20; ++i) {
			const unsigned int ib = 0x0BD771BCu + (unsigned int)i * 0x17Cu;
			if (*(volatile short*)(ib + 0xDCu) == 0) continue;
			const char* mm = (const char*)(ib + 0x114u);
			if (feMemHas(mm, kwG, 4) && feMemHas(mm, kwH, 4)) return i;
		}
		return -1;
	}
	// [Battle SkillMp/ItemMp] F0 tcpserver actions 7/8. skill "成性"(CP949 E0F7E0F5) / item(memo 기력+회복). battle MP=feBObj+0x84, pc.maxMp@0xBD77114.
	static int feBattleSkillMpRC(int myNo, char* cmd) {
		const unsigned int e = feBObj(myNo); if (e == 0u) return 0;
		const int cur = *(volatile int*)(e + 0x84u);
		if (cur > (int)g_baSkillMpVal && cur > 0) return 0;
		static const unsigned char kwS[4] = { 0xE0u, 0xF7u, 0xE0u, 0xF5u };
		int si = -1;
		for (int i = 0; i < 30; ++i) { const unsigned int sb = 0x0BD88168u + (unsigned int)i * 0xC0u; if (*(volatile short*)(sb + 0x00u) == 0) continue; if (feMemHas((const char*)(sb + 0x08u), kwS, 4)) { si = i; break; } }
		if (si < 0) return 0;
		const int hp = *(volatile int*)0x0BD77108u, mx = *(volatile int*)0x0BD7710Cu; if (mx <= 0) return 0;
		if ((int)((long long)hp * 100 / mx) < 30) return 0;
		wsprintfA(cmd, "P|%X|%X", si, myNo); return 1;
	}
	static int feBattleItemMpRC(int myNo, char* cmd) {
		const unsigned int e = feBObj(myNo); if (e == 0u) return 0;
		const int cur = *(volatile int*)(e + 0x84u), mx = *(volatile int*)0x0BD77114u;
		if (mx <= 0) return 0; const int mpp = (cur <= 0) ? 0 : (int)((long long)cur * 100 / mx);
		if (mpp > (int)g_baItemMpVal) return 0;
		const int it = feFindMpItem(); if (it < 0) return 0;
		wsprintfA(cmd, "I|%X|%X", it, myNo); return 1;
	}
	// [MP-DUMP diag] one-shot: profession_skill[]@0xBD88168 stride0xC0 name@+8; pc.item[]@0xBD771BC stride0x17C name@+0xE6 memo@+0x114. CP949. offset/내용 확인용(읽기전용).
	static void feMpDump() {
		static DWORD s_mpd = 0u; const DWORD mpnow = GetTickCount(); if (s_mpd != 0u && (mpnow - s_mpd) < 3000u) return;
		const unsigned int sock = *(volatile unsigned int*)0x0BD71B90u;
		if (sock == 0u || sock == 0xFFFFFFFFu) return;
		s_mpd = mpnow;
		HANDLE h = CreateFileW(L"D:\\SA\\zmffk\\mpdump-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
		if (h == INVALID_HANDLE_VALUE) return;
		char b[600]; int n; DWORD w;
		n = wsprintfA(b, "==== MP-DUMP hp=%d/%d mp=%d/%d gold=%d bpn=%d (item=0BD771BC stride17C name+E6 memo+114) ====\r\n", *(volatile int*)0x0BD77108u, *(volatile int*)0x0BD7710Cu, *(volatile int*)0x0BD77110u, *(volatile int*)0x0BD77114u, *(volatile int*)0x0BD77158u, (int)*(volatile short*)0x0BD771A2u); WriteFile(h, b, (DWORD)n, &w, nullptr);
		for (int i = 0; i < 30; ++i) { const unsigned int sb = 0x0BD88168u + (unsigned int)i * 0xC0u; const short uf = *(volatile short*)(sb + 0x00u); const char* nm = (const char*)(sb + 0x08u); n = wsprintfA(b, "skill[%d] uf=%d name=%.40s\r\n", i, (int)uf, nm); WriteFile(h, b, (DWORD)n, &w, nullptr); }
		for (int i = 0; i < 20; ++i) { const unsigned int ib = 0x0BD771BCu + (unsigned int)i * 0x17Cu; const short uf = *(volatile short*)(ib + 0xDCu); const short tg = *(volatile short*)(ib + 0xE0u); const char* nm = (const char*)(ib + 0xE6u); const char* mm = (const char*)(ib + 0x114u); n = wsprintfA(b, "item[%d] uf=%d tgt=%d name=%.30s memo=%.84s\r\n", i, (int)uf, (int)tg, nm, mm); WriteFile(h, b, (DWORD)n, &w, nullptr); }
		CloseHandle(h);
	}
'@
  $d = $d.Replace("`tstatic int feBattleAlive(int pos) { if (pos < 0 || pos >= 20) return 0; const unsigned int ent = *(volatile unsigned int*)(0x0D6AEAA0u + (unsigned int)pos * 4u); if (ent == 0u) return 0; if (*(volatile unsigned int*)(ent + 8u) == 0u) return 0; if (*(volatile int*)(ent + 36u) != 0) return 0; if (*(volatile int*)(ent + 120u) <= 0) return 0; return 1; }", "`tstatic int feBattleAlive(int pos) { if (pos < 0 || pos >= 20) return 0; const unsigned int ent = *(volatile unsigned int*)(0x0D6AEAA0u + (unsigned int)pos * 4u); if (ent == 0u) return 0; if (*(volatile unsigned int*)(ent + 8u) == 0u) return 0; if (*(volatile int*)(ent + 36u) != 0) return 0; if (*(volatile int*)(ent + 120u) <= 0) return 0; return 1; }`r`n" + $baHelpers)
  if ($d -notmatch 'feSelectableEnemy') { throw "battle helpers injection failed." }
  Good 'injected faithful battle-target helpers (sortBattleUnit/isTouchable/selectable/fix)'
}
if ($d -notmatch 'BattleActHandler') {
  $baCaseRep = @'
    if (fm == kBattleActMsg)
    {
        // BattleActHandler: 自動戰鬥. Faithful re-port of Worker::handleCharBattleLogics NormalAction
        // (tcpserver.cpp 9190-9296) + helpers, driven by the launcher battle-tab channel fields, encoded
        // with the client's own battleMenu.cpp wire convention and sent via lssproto_B_send@0x4B4BA0.
        // Menu panel is code-patched away by BattleMenuSuppressPatch. See docs/battle-tab-spec.md.
        const int bbat = *(volatile int*)0x0064F83Cu;
        const unsigned int bfd = *(volatile unsigned int*)0x0BD71B90u;
        if (bbat == 0 || bfd == 0u || bfd == 0xFFFFFFFFu) return 0;
        const int myNo = *(volatile int*)0x005A7E04u;
        if (myNo < 0 || myNo >= 20) return 0;
        *(volatile int*)0x0059DDE8u = 0; // AI = AI_NONE (defensive; menu handler code-patched away separately).
        const int animFlag = *(volatile int*)0x005A7E18u;
        const int svTurn = *(volatile int*)0x005A7E24u;
        typedef void(__cdecl* BattleSendFn)(int, char*);
        BattleSendFn baSend = (BattleSendFn)0x004B4BA0u;
        const int charBit = 1 << myNo;
        const int petPos = myNo + 5;
        const int petBit = (petPos < 31) ? (1 << petPos) : 0;
        int eMin, eMax; if (myNo < 10) { eMin = 10; eMax = 19; } else { eMin = 0; eMax = 9; }
        const DWORD baTick = GetTickCount();
        // [BC-CAPTURE / fast-fight groundwork] BattleStatus is a char[] at 0x5A2DF8 (verified in set_bc:
        //   cmp byte[idx+0x5a2df8]). Dump the raw BC packet text once per svTurn (normal mode, zero client impact)
        //   to lock the exact per-server BC format before writing the native (8001-style) BC parser.
        {
            static int s_bcTurn = -999;
            if (svTurn != s_bcTurn) {
                s_bcTurn = svTurn;
                const char* bs = (const char*)0x005A2DF8u;
                if (bs[0] != 0) {
                    HANDLE ch = CreateFileW(L"D:\\SA\\zmffk\\bc-capture.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
                    if (ch != INVALID_HANDLE_VALUE) {
                        char hdr[48]; int hn = wsprintfA(hdr, "== turn=%d ==\r\n", svTurn); DWORD w = 0;
                        WriteFile(ch, hdr, (DWORD)hn, &w, nullptr);
                        int bl = lstrlenA(bs); if (bl > 700) bl = 700;
                        WriteFile(ch, bs, (DWORD)bl, &w, nullptr);
                        WriteFile(ch, "\r\n", 2, &w, nullptr);
                        CloseHandle(ch);
                    }
                }
            }
        }
        // ===== client/server turn resync (recovery only; NO send-gating). Keep cli aligned to the authoritative
        //   server turn so CheckBattleAnimFlag never deadlocks, WITHOUT delaying our sends:
        //     cli>sv  = battle-start overshoot -> snap to sv now
        //     gap>=2  = large desync (the original stall) -> snap now
        //     cli<sv & afl==0 = no animation for the client to self-advance on -> snap now
        //   cli<sv & afl!=0 is the NORMAL 1-turn animation lag (client will cli++ itself) -> leave it, do NOT gate. =====
        int cliTurn = *(volatile int*)0x005A7E20u;
        if (cliTurn != svTurn && (cliTurn > svTurn || (svTurn - cliTurn) >= 2 || animFlag == 0)) {
            *(volatile int*)0x005A7E20u = svTurn; cliTurn = svTurn;
        }
        // ===== character action. Gate on cli==sv: only send when the client has settled at the turn's input point.
        //   Sending while cli!=sv (mid animation/transition) over-drives the client and stalls it at SubProcNo=2.
        //   The cli>sv battle-start overshoot is snapped to sv above, so this gate does NOT cause a first-turn wait. =====
        if (!(animFlag & charBit) && cliTurn == svTurn && (baTick - g_baCharSentTick) >= 700u)
        {
            char bcmd[24];
            const int fallback = feSelectableEnemy(myNo); // tcpserver 9296 final fallback (sendBattleCharAttackAct).
            // [자동도주] playerDoBattleWork(tcpserver 7379)처럼 자동도주가 켜졌으면 배틀탭 액션보다 먼저 도주.
            //   내턴 게이트(위)+700ms 디바운스는 자동전투와 공유. NoEscFlag!=0(도주불가)면 기본공격으로 턴 진행.
            // [낙마도주 fallDownEscapeFun tcpserver 7998, 최우선] onRide(p_party[myNo]+0x194): >0 라이딩, <=0 난마. 난마 시 도주.
            const int bcRide0 = feBCRideFlag(myNo);   // BC packet rideFlag: 1=riding, 0=fell(=난마), -1=unknown. (launcher fallDownEscapeFun)
            const int fellOff0 = (g_baFallEscape && bcRide0 == 0) ? 1 : 0;   // escape ONLY when definitively fell (rideFlag==0), like launcher
            if (g_baAutoEscape || fellOff0) {
                if (*(volatile int*)0x005A8080u == 0) { // NoEscFlag==0 (escape allowed)
                    bcmd[0] = 'E'; bcmd[1] = 0; baSend((int)bfd, bcmd);
                    // belt-and-suspenders: if the manual command menu is showing (battleMenuFlag!=0),
                    // replicate the client-native escape-button state so the menu dismisses & the turn advances,
                    // even if BattleMenuSuppressPatch didn't take. (battleMenu.cpp:2010 BattleButtonEscape)
                    if (*(volatile int*)0x005A7E48u != 0) { ((void(__cdecl*)(void))0x00418900u)(); *(volatile int*)(0x005A7E58u + 28u) = 1; *(volatile int*)0x005A7E38u = 1; *(volatile int*)0x005A7F18u = 1; }
                } else { wsprintfA(bcmd, "H|%X", fallback); baSend((int)bfd, bcmd); }
                g_baCharSentTick = baTick; { HANDLE eh = CreateFileW(L"D:\\SA\\zmffk\\autobattle-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr); if (eh != INVALID_HANDLE_VALUE) { char ebf[160]; int ebn = wsprintfA(ebf, "autobattle ESCAPE turn=%d myNo=%d ride=%d fell=%d ae=%d noEsc=%d\r\n", svTurn, myNo, bcRide0, fellOff0, (int)g_baAutoEscape, *(volatile int*)0x005A8080u); DWORD ebw = 0; WriteFile(eh, ebf, (DWORD)ebn, &ebw, nullptr); CloseHandle(eh); } } return 0; }
            // [S1] valid-enemy count + min level over enemy side (launcher bt.enemies valid criteria).
            int validCnt = 0; int minLv = 0x7fffffff;
            for (int i = eMin; i <= eMax; ++i) { if (!feBValid(i)) continue; ++validCnt; int lv = *(volatile int*)(feBObj(i) + 0x8Cu); if (lv < minLv) minLv = lv; }
            if (validCnt == 0) return 0; // turn-0 race: enemy actors not loaded yet -> defer to next tick.
            // [S-reset] battle-start reset (launcher battleCrossActionCounter_.reset() at lssproto_EN_recv 13513):
            //   svTurn going backwards = a new battle -> reset cross-action counter + per-turn delay arming.
            if (svTurn < g_baBatTurn) { g_baCrossCnt = 0; g_baCrossFireLatch = 0; g_baCrossLastTurn = -1; g_baDelayTurn = -1; }
            g_baBatTurn = svTurn;
            // [S0] battle delay (kBattleActionDelayValue, tcpserver playerDoBattleWork 7232): launcher msleeps
            //   `delay` ms before handleCharBattleLogics each round. We can't block the client main thread, so
            //   gate the send on elapsed time since this turn became actionable (armed once per svTurn).
            const unsigned int delayMs = (unsigned int)g_baDelay;
            if (delayMs > 0)
            {
                if (g_baDelayTurn != svTurn) { g_baDelayTurn = svTurn; g_baDelayTick = baTick; return 0; }
                if ((baTick - g_baDelayTick) < delayMs) return 0;
            }
            // ===== priority chain (handleCharBattleLogics 9144-9296): selectRound(4) > intervalRound(10) > normal > fallback =====
            int rowFired = 0; int usedRow = 9; int usedType = -1; unsigned int usedTflags = 0u; int jt = -2;
            // --- [Row 4] selectRoundFun (tcpserver 8177-8308): fire on the configured round if gates pass ---
            do {
                const int rr = (int)g_baCRRound;                 // 0=not use, else 1-based "at round N"
                if (rr <= 0) break;
                if (rr != svTurn + 1) break;                     // battleCurrentRound == serverRound+1 == svTurn+1
                const int re = (int)g_baCREnemy; if (re != 0 && validCnt <= re) break;   // enemies.size() must be > re
                const int rl = (int)g_baCRLevel; if (rl != 0 && minLv <= rl * 10) break; // minLevel must be > rl*10
                if (feCharDecodeRC((int)g_baCRType, (unsigned int)g_baCRTarget, myNo, bcmd, &jt) == 1)
                { usedRow = 4; usedType = (int)g_baCRType; usedTflags = (unsigned int)g_baCRTarget; baSend((int)bfd, bcmd); rowFired = 1; }
            } while (0);
            // --- [Row 5] magicHealFun (tcpserver 8313-8425): heal self->pet->allie by hp%% threshold BEFORE attack ---
            if (!rowFired && g_baMHEnable != 0 && feMagicHealRC(myNo, bcmd) == 1)
            { usedRow = 5; usedType = (int)g_baMHMagic; usedTflags = (unsigned int)g_baMHTarget; baSend((int)bfd, bcmd); rowFired = 1; }
            // [Row 7] skillMp (嗜血補氣 tcpserver actions.insert 7): battle MP <= threshold -> job skill "成性" self
            if (!rowFired && g_baSkillMpEn != 0 && feBattleSkillMpRC(myNo, bcmd) == 1)
            { usedRow = 7; baSend((int)bfd, bcmd); rowFired = 1; }
            // [Row 8] itemMp (道具補氣 tcpserver actions.insert 8): battle MP% <= threshold -> item(memo 기력+회복) self
            if (!rowFired && g_baItemMpEn != 0 && feBattleItemMpRC(myNo, bcmd) == 1)
            { usedRow = 8; baSend((int)bfd, bcmd); rowFired = 1; }
            // --- [Row 10] intervalRoundFun (tcpserver 8685-8797): reached only if round did not fire ---
            if (!rowFired && g_baCCEnable != 0)
            {
                const int crRound = (int)g_baCCRound + 1;        // interval = kBattleCharCrossActionRoundValue + 1
                if (svTurn != g_baCrossLastTurn)                 // advance the counter once per round
                {
                    g_baCrossLastTurn = svTurn;
                    if (g_baCrossCnt < crRound) { g_baCrossCnt++; g_baCrossFireLatch = 0; }
                    else { g_baCrossCnt = 0; g_baCrossFireLatch = 1; }
                }
                if (g_baCrossFireLatch && feCharDecodeRC((int)g_baCCType, (unsigned int)g_baCCTarget, myNo, bcmd, &jt) == 1)
                { usedRow = 10; usedType = (int)g_baCCType; usedTflags = (unsigned int)g_baCCTarget; baSend((int)bfd, bcmd); rowFired = 1; }
            }
            // --- [Normal row] (tcpserver 9190-9296): reached if neither round nor cross fired ---
            if (!rowFired)
            {
                const int enemyVal = (int)g_baCharEnemy;
                const int levelVal = (int)g_baCharLevel;
                int condMet = 1;
                if (enemyVal > 0 && validCnt <= enemyVal) condMet = 0;   // enemies.size() <= enemy => fallback attack
                if (levelVal > 0 && minLv <= levelVal * 10) condMet = 0; // minLevel <= level*10 => fallback attack
                if (condMet && feCharDecodeRC((int)g_baCharType, (unsigned int)g_baCharTarget, myNo, bcmd, &jt) == 1)
                { usedRow = 0; usedType = (int)g_baCharType; usedTflags = (unsigned int)g_baCharTarget; }
                else { usedRow = -1; wsprintfA(bcmd, "H|%X", fallback); } // final fallback: sendBattleCharAttackAct(getBattleSelectableEnemyTarget)
                baSend((int)bfd, bcmd);
                rowFired = 1;
            }
            g_baCharSentTick = baTick;
            // [StallDiag] 각 적 pos의 사망판정 후보 필드 전부 덤프 — 멈춤 시 죽은 적이 어느 필드로 표시되는지 실측.
            //   st=status@0x90, hp=@0x78, mx=maxHp@0x80, df=deathFlag@0x24, fn=func@0x8, lv=level@0x8C, v=feBValid.
            char estr[480]; int esn = 0; estr[0] = 0;
            for (int es = eMin; es <= eMax; ++es) { unsigned int eo = feBObj(es); if (eo == 0u) continue; int est = *(volatile int*)(eo + 0x90u); int eh = *(volatile int*)(eo + 0x78u); int emx = *(volatile int*)(eo + 0x80u); int edf = *(volatile int*)(eo + 0x24u); unsigned int efn = *(volatile unsigned int*)(eo + 0x8u); int elv = *(volatile int*)(eo + 0x8Cu); int ev = feBValid(es); if (esn < 430) esn += wsprintfA(estr + esn, "%d:st%X/hp%d/mx%d/df%d/fn%X/lv%d/v%d ", es, est, eh, emx, edf, efn, elv, ev); }
            // [StallDiag2] 원시 배틀상태 + 상태머신 위치(SubProcNo/action_inf/ProcNo/menuFlag/targetSel) — turn 진행 정지 지점 실측.
            const int resWnd = *(volatile int*)0x005A7E28u;
            const unsigned int subP = *(volatile unsigned int*)0x0BD8954Cu; const unsigned int procN = *(volatile unsigned int*)0x0BD89548u;
            const int actInf = *(volatile int*)0x0D6AEAF0u; const int menuF = *(volatile int*)0x005A7E48u; const int tgtSel = *(volatile int*)0x005A7F24u;
            const unsigned int selfObj = feBObj(myNo); const unsigned int petObj = feBObj(myNo + 5);
            const int selfHp = selfObj ? *(volatile int*)(selfObj + 0x78u) : -1; const int selfSt = selfObj ? *(volatile int*)(selfObj + 0x90u) : -1;
            const int petHp = petObj ? *(volatile int*)(petObj + 0x78u) : -1; const int petSt = petObj ? *(volatile int*)(petObj + 0x90u) : -1;
            const int selfMx = selfObj ? *(volatile int*)(selfObj + 0x80u) : 0; const int petMx = petObj ? *(volatile int*)(petObj + 0x80u) : 0;
            const int selfPct = feHpPct(selfHp, selfMx); const int petPct = feHpPct(petHp, petMx);
            HANDLE bh = CreateFileW(L"D:\\SA\\zmffk\\autobattle-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (bh != INVALID_HANDLE_VALUE) { char bb[900]; int bn = wsprintfA(bb, "autobattle CHAR t=%u turn=%d cliT=%d myNo=%d afl=%X cb=%d pb=%d subP=%u procN=%u actInf=%d menuF=%X tgtSel=%d resW=%d self=hp%d/st%X pet=hp%d/st%X validEnemy=%d fallback=%d delay=%u cmd=%s heal[en=%d tf=%X c=%d p=%d a=%d mag=%d selfP=%d/mx%d petP=%d/mx%d] | enemies=%s\r\n", baTick, svTurn, cliTurn, myNo, animFlag, (animFlag & charBit) ? 1 : 0, (animFlag & petBit) ? 1 : 0, subP, procN, actInf, menuF, tgtSel, resWnd, selfHp, selfSt, petHp, petSt, validCnt, fallback, delayMs, bcmd, (int)g_baMHEnable, (unsigned int)g_baMHTarget, (int)g_baMHChar, (int)g_baMHPet, (int)g_baMHAllie, (int)g_baMHMagic, selfPct, selfMx, petPct, petMx, estr); DWORD bw = 0; WriteFile(bh, bb, (DWORD)bn, &bw, nullptr); CloseHandle(bh); }
            return 0;
        }
        // ===== pet action (char acted + my pet BattleAnimFlag bit clear) =====
        // handlePetBattleLogics(tcpserver 9300-9718) priority: SelectedRound(4) > CrossRound(10) > Normal.
        // NOTE(의도적 편차): 런처 원본 SelectedRound(9471/9481/9490)에는 복붙 버그 3개가 있다 -
        //   (1) 라운드 지정값을 Enemy 해시에서, (2) 적수 게이트를 Level 해시에서, (3) 레벨 게이트를 Char 해시에서
        //   읽는다. 오너 지시("버그 수정 후 빌드")에 따라 아래 매핑은 Round/Enemy/Level 해시로 바로잡아 포팅했다.
        //   (매핑 교정은 mainthread baPetReapply/baPetEdge 단계에서 이미 반영됨.)
        //   미포팅 편차: sendBattlePetSkillAct의 補血(회복스킬 적 대상금지) 가드는 petSkill.memo 문자열 매칭이 필요해 생략.
        if ((animFlag & charBit) && petBit != 0 && !(animFlag & petBit) && cliTurn == svTurn && (baTick - g_baPetSentTick) >= 700u)
        {
            char pcmd[24];
            // 자동도주 시 펫은 별도 도주명령이 없으므로 아무것도 안 함(W|FF|FF)으로 턴만 진행.
            if (g_baAutoEscape) { pcmd[0]='W'; pcmd[1]='|'; pcmd[2]='F'; pcmd[3]='F'; pcmd[4]='|'; pcmd[5]='F'; pcmd[6]='F'; pcmd[7]=0; baSend((int)bfd, pcmd); g_baPetSentTick = baTick; return 0; }
            const int petUi = svTurn + 1;              // battleCurrentRound == serverRound+1
            const int alliemin = (myNo < 10) ? 0 : 10; // bt.alliemin
            int pValid = 0; int pMinLv = 0x7fffffff;
            for (int i = eMin; i <= eMax; ++i) { if (!feBValid(i)) continue; ++pValid; int lv = *(volatile int*)(feBObj(i) + 0x8Cu); if (lv < pMinLv) pMinLv = lv; }
            int petRow = 0; int petSkillIdx = -1; int petTarget = -2; int petSeed = -2;
            // --- [Pet Row 4] SelectedRound (9467-9598): 버그수정 매핑 (Round/Enemy/Level) ---
            do {
                const int rr = (int)g_baPRRound;                                   // 지정 라운드 (1-based)
                if (rr <= 0) break;
                if (rr != petUi) break;
                const int re = (int)g_baPREnemy; if (re != 0 && pValid <= re) break;                    // enemies.size() > re
                const int rl = (int)g_baPRLevel; if (rl != 0 && pMinLv != 0x7fffffff && pMinLv <= rl * 10) break; // minLevel > rl*10
                const int si = (int)g_baPRType; if (si < 0 || si >= 7) break;      // skillIndex < MAX_PET_SKILL
                petSeed = fePetSeed((unsigned int)g_baPRTarget, myNo, alliemin);
                const int t = fePetFix(si, petSeed, myNo);
                if (t >= 0) { petRow = 4; petSkillIdx = si; petTarget = t; wsprintfA(pcmd, "W|%X|%X", si, t); baSend((int)bfd, pcmd); }
            } while (0);
            // --- [Pet Row 10] CrossRound (9603-9718): enable + (battleCurrentRound % (round+1))==0, 폴백 포함 ---
            if (petRow == 0 && g_baPCEnable != 0)
            {
                do {
                    const int crR = (int)g_baPCRound + 1; if (crR <= 0) break;
                    if ((petUi % crR) != 0) break;
                    const int si = (int)g_baPCType; if (si < 0 || si >= 7) break;
                    petSeed = fePetSeed((unsigned int)g_baPCTarget, myNo, alliemin);
                    int t = fePetFix(si, petSeed, myNo);
                    if (t < 0) { petSeed = feSelectableEnemy(myNo); t = fePetFix(si, petSeed, myNo); } // 9710-9716 폴백
                    if (t >= 0) { petRow = 10; petSkillIdx = si; petTarget = t; wsprintfA(pcmd, "W|%X|%X", si, t); baSend((int)bfd, pcmd); }
                } while (0);
            }
            // --- [Pet Row 0] Normal (기존 동작 유지): g_baPetType>=0 -> W|type|selectableEnemy, else W|FF|FF ---
            if (petRow == 0)
            {
                const int ptype = (int)g_baPetType;
                if (ptype >= 0) { int pt = feSelectableEnemy(myNo); petSkillIdx = ptype; petTarget = pt; wsprintfA(pcmd, "W|%X|%X", ptype, pt); }
                else { pcmd[0]='W'; pcmd[1]='|'; pcmd[2]='F'; pcmd[3]='F'; pcmd[4]='|'; pcmd[5]='F'; pcmd[6]='F'; pcmd[7]=0; petSkillIdx = -1; petTarget = -1; }
                baSend((int)bfd, pcmd);
            }
            g_baPetSentTick = baTick;
            HANDLE ph = CreateFileW(L"D:\\SA\\zmffk\\autobattle-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (ph != INVALID_HANDLE_VALUE) { char pb[240]; int pn = wsprintfA(pb, "autobattle PET turn=%d myNo=%d row=%d si=%d seed=%d target=%d validEnemy=%d minLv=%d pcEnable=%d cmd=%s\r\n", svTurn, myNo, petRow, petSkillIdx, petSeed, petTarget, pValid, (pMinLv == 0x7fffffff ? -1 : pMinLv), (int)g_baPCEnable, pcmd); DWORD pw = 0; WriteFile(ph, pb, (DWORD)pn, &pw, nullptr); CloseHandle(ph); }
            return 0;
        }
        return 0;
    }
    return g_feOldWndProc != nullptr ? CallWindowProcW(g_feOldWndProc, fh, fm, fw, fl) : DefWindowProcW(fh, fm, fw, fl);
'@
  $d = $d.Replace("`treturn g_feOldWndProc != nullptr ? CallWindowProcW(g_feOldWndProc, fh, fm, fw, fl) : DefWindowProcW(fh, fm, fw, fl);", $baCaseRep)
  if ($d -notmatch 'BattleActHandler') { throw "battle-act feWndProc case patch failed." }
  Good 'applied battle-act feWndProc case (H|target / G / E / W)'
}
if ($d -notmatch 'FastEncSendMsgTrigger') {
  $feTrRep = @'
// [FastEncSendMsgTrigger] monitor drives timing; SendMessage hands off to the MAIN thread (feWndProc).
			{
			static int s_feCnt = 0; static DWORD s_feLastLog = 0u; static int s_feWasOn = 0;
			if (context->channel != nullptr && context->channel->fastAutoWalkRequested == 1)
			{
				if (g_feHwnd == nullptr)
				{
					g_fePid = GetCurrentProcessId();
					EnumWindows(feFindWnd, 0);
					if (g_feHwnd != nullptr) { g_feOldWndProc = (WNDPROC)SetWindowLongW(g_feHwnd, GWL_WNDPROC, (LONG)feWndProc); }
				}
				if (!s_feWasOn) { s_feWasOn = 1; HANDLE h0 = CreateFileW(L"D:\\SA\\zmffk\\fastautowalk-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr); if (h0 != INVALID_HANDLE_VALUE) { char b0[128]; int n0 = wsprintfA(b0, "fastenc(sendmsg) ENABLED hwnd=%p (pure in-place gcgc, no origin)\r\n", (void*)g_feHwnd); DWORD w0 = 0; WriteFile(h0, b0, (DWORD)n0, &w0, nullptr); CloseHandle(h0); } }
				const int feBat = *(volatile int*)0x0064F83Cu;
				if (g_feHwnd != nullptr && feBat == 0)
				{
					// fire EVERY monitor tick (~50ms); feWndProc sends ONE "gcgc" per tick (~20/s), no burst (drift fix)
					DWORD_PTR feRes = 0u; LRESULT feOk = 1; { static DWORD s_feWt = 0u; const DWORD feWtNow = GetTickCount(); if (s_feWt == 0u || (feWtNow - s_feWt) >= ((DWORD)g_walkDelay + 1u)) { s_feWt = feWtNow; feOk = SendMessageTimeoutW(g_feHwnd, kFeSendMsg, 0, 0, SMTO_ABORTIFHUNG, 300u, &feRes); } }
					++s_feCnt;
					const DWORD feNow = GetTickCount();
					if (s_feLastLog == 0u || (feNow - s_feLastLog) >= 1000u) { s_feLastLog = feNow; HANDLE feh = CreateFileW(L"D:\\SA\\zmffk\\fastautowalk-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr); if (feh != INVALID_HANDLE_VALUE) { const int fecx = *(volatile int*)0x0BCDE0D8u; const int fecy = *(volatile int*)0x0BCDE0DCu; char feb[220]; int fen = wsprintfA(feb, "fastenc(sendmsg) sent cnt=%d smto=%d res=%d battling=%d pos=(%d,%d) (1/tick)\r\n", s_feCnt, (int)(feOk != 0), (int)feRes, feBat, fecx, fecy); DWORD few = 0; WriteFile(feh, feb, (DWORD)fen, &few, nullptr); CloseHandle(feh); } }
				}
			}
			else { s_feWasOn = 0; }
			}
			processAutoLoginCommand(*context);
'@
  if ($d.IndexOf("processAutoLoginCommand(*context);") -lt 0) { throw "could not locate monitor-loop anchor for fast-encounter trigger." }
  $d = $d.Replace("processAutoLoginCommand(*context);", $feTrRep)
  if ($d -notmatch 'FastEncSendMsgTrigger') { throw "fast-encounter SendMessage trigger patch failed." }
  Good 'applied FastEnc monitor SendMessage trigger (drives main-thread EN_send)'
}
if ($d -notmatch 'AutoEscapeSendMsgTrigger') {
  $aeTrRep = @'
// [AutoEscapeSendMsgTrigger] auto-escape (自動逃跑) — monitor drives; SendMessage -> MAIN thread feWndProc -> lssproto_B_send("E").
			if (context->channel != nullptr && context->channel->autoEscapeRequested == 1)
			{
				static int s_aeCnt = 0; static DWORD s_aeLastLog = 0u; static DWORD s_aeLastSend = 0u; static int s_aeWasOn = 0;
				if (g_feHwnd == nullptr)
				{
					g_fePid = GetCurrentProcessId();
					EnumWindows(feFindWnd, 0);
					if (g_feHwnd != nullptr) { g_feOldWndProc = (WNDPROC)SetWindowLongW(g_feHwnd, GWL_WNDPROC, (LONG)feWndProc); }
				}
				if (!s_aeWasOn) { s_aeWasOn = 1; HANDLE h0 = CreateFileW(L"D:\\SA\\zmffk\\autoescape-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr); if (h0 != INVALID_HANDLE_VALUE) { char b0[160]; int n0 = wsprintfA(b0, "autoescape ENABLED hwnd=%p old=%p pid=%u\r\n", (void*)g_feHwnd, (void*)g_feOldWndProc, g_fePid); DWORD w0 = 0; WriteFile(h0, b0, (DWORD)n0, &w0, nullptr); CloseHandle(h0); } }
				const int aeBat = *(volatile int*)0x0064F83Cu;
				const int aeNoEsc = *(volatile int*)0x005A8080u;
				const DWORD aeNow = GetTickCount();
				// fire EVERY monitor tick (~50ms) like auto-battle — feWndProc kEscapeMsg gates on my turn (BattleAnimFlag)+debounce.
					// old 600ms cadence missed the brief my-turn window once the menu is code-patched away (fast advance).
					if (0 && g_feHwnd != nullptr && aeBat != 0 && aeNoEsc == 0) /* disabled: autoescape routed via kBattleActMsg (char+pet) */
				{
					DWORD_PTR aeRes = 0u; LRESULT aeOk = SendMessageTimeoutW(g_feHwnd, kEscapeMsg, 0, 0, SMTO_ABORTIFHUNG, 300u, &aeRes);
					s_aeLastSend = aeNow; ++s_aeCnt;
					if (s_aeLastLog == 0u || (aeNow - s_aeLastLog) >= 1000u) { s_aeLastLog = aeNow; HANDLE aeh = CreateFileW(L"D:\\SA\\zmffk\\autoescape-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr); if (aeh != INVALID_HANDLE_VALUE) { char aeb[200]; int aen = wsprintfA(aeb, "autoescape sent cnt=%d smto=%d res=%d battling=%d noesc=%d\r\n", s_aeCnt, (int)(aeOk != 0), (int)aeRes, aeBat, aeNoEsc); DWORD aew = 0; WriteFile(aeh, aeb, (DWORD)aen, &aew, nullptr); CloseHandle(aeh); } }
				}
			}
			processAutoLoginCommand(*context);
'@
  if ($d.IndexOf("processAutoLoginCommand(*context);") -lt 0) { throw "could not locate monitor-loop anchor for auto-escape trigger." }
  $d = $d.Replace("processAutoLoginCommand(*context);", $aeTrRep)
  if ($d -notmatch 'AutoEscapeSendMsgTrigger') { throw "auto-escape SendMessage trigger patch failed." }
  Good 'applied AutoEscape monitor trigger (main-thread lssproto_B_send E)'
}
if ($d -notmatch 'BattleActSendMsgTrigger') {
  $baTrRep = @'
// [BattleActSendMsgTrigger] auto-battle (自動戰鬥) — monitor copies channel settings into file-scope globals
// then SendMessage hands off to the MAIN thread (feWndProc kBattleActMsg) which runs lssproto_B_send.
            // [BattleMenuSuppressPatch] sa_8001-style code patch (toggled with auto-battle on/off):
            //   0x41D56E jne(75 0C)->NOP(90 90): skip BattleMenuProc entirely (no menu, no menu-state
            //     machine delay = sa_8001 fast). Client falls into the AI branch (CloseInfoWnd+AI_ChooseAction).
            //   AI_ChooseAction 3 B-send sites (0x41258B/0x412F1D/0x4130D4) E8..->90x5: neutralize the
            //     client AI's own sends (avoid double-send). Its `inc SubProcNo`(0x413190) advance is KEPT,
            //     so the turn still advances instantly. WE send per battle tab from feWndProc.
            {
                static int s_bmpApplied = -1;
                // [수동모드 자동도주 수정] 런처는 배틀 자동화(자동전투 OR 자동도주) 시 WM_EnableBattleDialog로
                // 메뉴 패널을 억제한다. 자동도주 단독일 때도 메뉴를 억제해야 수동모드에서 BattleMenuProc 대기에
                // 갇히지 않고 no-menu(AI 분기) 경로로 진행 -> "E" 송신이 명령창에 정확히 먹는다. (AI 모드와 동일 동작.)
                const int bmpWant = (context->channel != nullptr && (context->channel->autoBattleRequested == 1 || context->channel->autoEscapeRequested == 1 || context->channel->battleFallEscapeRequested == 1)) ? 1 : 0;
                if (bmpWant != s_bmpApplied)
                {
                    const DWORD bmpAddr[4] = { 0x0041D56Eu, 0x0041258Bu, 0x00412F1Du, 0x004130D4u };
                    const SIZE_T bmpLen[4] = { 2u, 5u, 5u, 5u };
                    const BYTE bmpOrig[4][5] = { {0x75,0x0C,0,0,0}, {0xE8,0x10,0x26,0x0A,0x00}, {0xE8,0x7E,0x1C,0x0A,0x00}, {0xE8,0xC7,0x1A,0x0A,0x00} };
                    const BYTE bmpNop[4][5]  = { {0x90,0x90,0,0,0}, {0x90,0x90,0x90,0x90,0x90}, {0x90,0x90,0x90,0x90,0x90}, {0x90,0x90,0x90,0x90,0x90} };
                    int bmpOk = 0;
                    for (int bpi = 0; bpi < 4; ++bpi)
                    {
                        DWORD bmpProt = 0;
                        if (VirtualProtect(reinterpret_cast<LPVOID>(bmpAddr[bpi]), bmpLen[bpi], PAGE_EXECUTE_READWRITE, &bmpProt))
                        {
                            const BYTE* bmpSrc = bmpWant ? bmpNop[bpi] : bmpOrig[bpi];
                            for (SIZE_T bpj = 0; bpj < bmpLen[bpi]; ++bpj) reinterpret_cast<volatile BYTE*>(bmpAddr[bpi])[bpj] = bmpSrc[bpj];
                            DWORD bmpTmp = 0; VirtualProtect(reinterpret_cast<LPVOID>(bmpAddr[bpi]), bmpLen[bpi], bmpProt, &bmpTmp);
                            FlushInstructionCache(GetCurrentProcess(), reinterpret_cast<LPCVOID>(bmpAddr[bpi]), bmpLen[bpi]);
                            ++bmpOk;
                        }
                    }
                    s_bmpApplied = bmpWant;
                    HANDLE bmph = CreateFileW(L"D:\\SA\\zmffk\\autobattle-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
                    if (bmph != INVALID_HANDLE_VALUE) { char bmpb[200]; int bmpn = wsprintfA(bmpb, "battlemenu-suppress want=%d patched=%d/4 (ab=%d ae=%d)\r\n", bmpWant, bmpOk, (context->channel != nullptr ? (int)context->channel->autoBattleRequested : -9), (context->channel != nullptr ? (int)context->channel->autoEscapeRequested : -9)); DWORD bmpw = 0; WriteFile(bmph, bmpb, (DWORD)bmpn, &bmpw, nullptr); CloseHandle(bmph); }
                }
            }
            if (context->channel != nullptr && (context->channel->autoBattleRequested == 1 || context->channel->autoEscapeRequested == 1 || context->channel->battleFallEscapeRequested == 1))
            {
                static int s_baCnt = 0; static DWORD s_baLastLog = 0u; static DWORD s_baLastSend = 0u; static int s_baWasOn = 0;
                if (g_feHwnd == nullptr)
                {
                    g_fePid = GetCurrentProcessId();
                    EnumWindows(feFindWnd, 0);
                    if (g_feHwnd != nullptr) { g_feOldWndProc = (WNDPROC)SetWindowLongW(g_feHwnd, GWL_WNDPROC, (LONG)feWndProc); }
                }
                InterlockedExchange(&g_baCharType, context->channel->battleCharActionType);
                InterlockedExchange(&g_baCharTarget, context->channel->battleCharActionTarget);
                InterlockedExchange(&g_baPetType, context->channel->battlePetActionType);
                InterlockedExchange(&g_baPetTarget, context->channel->battlePetActionTarget);
                InterlockedExchange(&g_baCharEnemy, context->channel->battleCharNormalEnemy);
                InterlockedExchange(&g_baCharLevel, context->channel->battleCharNormalLevel);
                InterlockedExchange(&g_baCRRound, context->channel->battleCharRoundRound);
                InterlockedExchange(&g_baCREnemy, context->channel->battleCharRoundEnemy);
                InterlockedExchange(&g_baCRLevel, context->channel->battleCharRoundLevel);
                InterlockedExchange(&g_baCRType, context->channel->battleCharRoundType);
                InterlockedExchange(&g_baCRTarget, context->channel->battleCharRoundTarget);
                InterlockedExchange(&g_baCCEnable, context->channel->battleCharCrossEnable);
                InterlockedExchange(&g_baCCRound, context->channel->battleCharCrossRound);
                InterlockedExchange(&g_baCCType, context->channel->battleCharCrossType);
                InterlockedExchange(&g_baCCTarget, context->channel->battleCharCrossTarget);
                InterlockedExchange(&g_baDelay, context->channel->battleActionDelay);
                InterlockedExchange(&g_baPRRound, context->channel->battlePetRoundRound);
                InterlockedExchange(&g_baPREnemy, context->channel->battlePetRoundEnemy);
                InterlockedExchange(&g_baPRLevel, context->channel->battlePetRoundLevel);
                InterlockedExchange(&g_baPRType, context->channel->battlePetRoundType);
                InterlockedExchange(&g_baPRTarget, context->channel->battlePetRoundTarget);
                InterlockedExchange(&g_baPCEnable, context->channel->battlePetCrossEnable);
                InterlockedExchange(&g_baPCRound, context->channel->battlePetCrossRound);
                InterlockedExchange(&g_baPCType, context->channel->battlePetCrossType);
                InterlockedExchange(&g_baPCTarget, context->channel->battlePetCrossTarget);
                InterlockedExchange(&g_baMHEnable, context->channel->battleMagicHealEnable);
                InterlockedExchange(&g_baMHTarget, context->channel->battleMagicHealTarget);
                InterlockedExchange(&g_baMHChar, context->channel->battleMagicHealChar);
                InterlockedExchange(&g_baMHPet, context->channel->battleMagicHealPet);
                InterlockedExchange(&g_baMHAllie, context->channel->battleMagicHealAllie);
                InterlockedExchange(&g_baMHMagic, context->channel->battleMagicHealMagic);
                InterlockedExchange(&g_baSkillMpEn, context->channel->battleSkillMpEnable);
                InterlockedExchange(&g_baSkillMpVal, context->channel->battleSkillMpValue);
                InterlockedExchange(&g_baItemMpEn, context->channel->battleItemHealMpEnable);
                InterlockedExchange(&g_baItemMpVal, context->channel->battleItemHealMpValue);
                InterlockedExchange(&g_walkDelay, context->channel->autoWalkDelay);
                InterlockedExchange(&g_baAutoEscape, context->channel->autoEscapeRequested == 1 ? 1 : 0);
                InterlockedExchange(&g_baFallEscape, context->channel->battleFallEscapeRequested == 1 ? 1 : 0);
                if (!s_baWasOn) { s_baWasOn = 1; HANDLE h0 = CreateFileW(L"D:\\SA\\zmffk\\autobattle-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr); if (h0 != INVALID_HANDLE_VALUE) { char b0[160]; int n0 = wsprintfA(b0, "autobattle ENABLED hwnd=%p old=%p pid=%u\r\n", (void*)g_feHwnd, (void*)g_feOldWndProc, g_fePid); DWORD w0 = 0; WriteFile(h0, b0, (DWORD)n0, &w0, nullptr); CloseHandle(h0); } }
                const int baBat = *(volatile int*)0x0064F83Cu;
                if (g_feHwnd != nullptr && baBat != 0)
                {
                    const DWORD baNow = GetTickCount();
                    if (s_baLastSend == 0u || (baNow - s_baLastSend) >= 30u)
                    {
                        s_baLastSend = baNow;
                        DWORD_PTR baRes = 0u; LRESULT baOk = SendMessageTimeoutW(g_feHwnd, kBattleActMsg, 0, 0, SMTO_ABORTIFHUNG, 300u, &baRes);
                        ++s_baCnt;
                        if (s_baLastLog == 0u || (baNow - s_baLastLog) >= 1000u) { s_baLastLog = baNow; HANDLE bah = CreateFileW(L"D:\\SA\\zmffk\\autobattle-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr); if (bah != INVALID_HANDLE_VALUE) { char bab[200]; int ban = wsprintfA(bab, "autobattle tick cnt=%d smto=%d res=%d battling=%d ctype=%d ptype=%d\r\n", s_baCnt, (int)(baOk != 0), (int)baRes, baBat, (int)g_baCharType, (int)g_baPetType); DWORD baw = 0; WriteFile(bah, bab, (DWORD)ban, &baw, nullptr); CloseHandle(bah); } }
                    }
                }
            }
            processAutoLoginCommand(*context);
'@
  if ($d.IndexOf("processAutoLoginCommand(*context);") -lt 0) { throw "could not locate monitor-loop anchor for battle-act trigger." }
  $d = $d.Replace("processAutoLoginCommand(*context);", $baTrRep)
  if ($d -notmatch 'BattleActSendMsgTrigger') { throw "battle-act SendMessage trigger patch failed." }
  Good 'applied BattleAct monitor trigger (main-thread lssproto_B_send H|target)'
}
if ($d -notmatch 'NormalHealTrigger') {
  $nmhTr = @'
                // [NormalHealTrigger] field (non-battle) magic-heal: mirrors launcher autoHeal() MissionThread.
                // monitor copies channel -> g_nmh*, then on (field state + enable) SendMessages MAIN thread feWndProc.
                InterlockedExchange(&g_nmhEnable, context->channel->normalMagicHealEnable);
                InterlockedExchange(&g_nmhChar, context->channel->normalMagicHealChar);
                InterlockedExchange(&g_nmhMagic, context->channel->normalMagicHealMagic);
                InterlockedExchange(&g_nmhPet, context->channel->normalMagicHealPet);
                InterlockedExchange(&g_nmhAllie, context->channel->normalMagicHealAllie);
                InterlockedExchange(&g_nmhIMpEn, context->channel->normalItemHealMpEnable);
                InterlockedExchange(&g_nmhIMpVal, context->channel->normalItemHealMpValue);
                feMpDump();
                { static DWORD s_nmhMon = 0u; const DWORD mnow = GetTickCount(); if (s_nmhMon == 0u || (mnow - s_nmhMon) >= 3000u) { s_nmhMon = mnow; HANDLE mh = CreateFileW(L"D:\\SA\\zmffk\\normalheal-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr); if (mh != INVALID_HANDLE_VALUE) { char mbf[220]; int mn = wsprintfA(mbf, "nmh-monitor en=%d hwnd=%d bat=%d chan(en=%d ch=%d mg=%d)\r\n", (int)g_nmhEnable, (int)(g_feHwnd != nullptr), *(volatile int*)0x0064F83Cu, (int)context->channel->normalMagicHealEnable, (int)context->channel->normalMagicHealChar, (int)context->channel->normalMagicHealMagic); DWORD mw = 0; WriteFile(mh, mbf, (DWORD)mn, &mw, nullptr); CloseHandle(mh); } } }
                if (g_nmhEnable != 0)
                {
                    if (g_feHwnd == nullptr) { g_fePid = GetCurrentProcessId(); EnumWindows(feFindWnd, 0); if (g_feHwnd != nullptr) { g_feOldWndProc = (WNDPROC)SetWindowLongW(g_feHwnd, GWL_WNDPROC, (LONG)feWndProc); } }
                    const int nmhBat = *(volatile int*)0x0064F83Cu;   // BattlingFlag (0 = field / non-battle)
                    if (g_feHwnd != nullptr && nmhBat == 0)
                    {
                        static DWORD s_nmhLast = 0u;
                        const DWORD nmhNow = GetTickCount();
                        if (s_nmhLast == 0u || (nmhNow - s_nmhLast) >= 500u)   // autoHeal 500ms cadence
                        {
                            s_nmhLast = nmhNow;
                            DWORD_PTR nmhRes = 0u; SendMessageTimeoutW(g_feHwnd, kNormalHealMsg, 0, 0, SMTO_ABORTIFHUNG, 300u, &nmhRes);
                        }
                    }
                }
                processAutoLoginCommand(*context);
'@
  if ($d.IndexOf("processAutoLoginCommand(*context);") -lt 0) { throw "could not locate monitor anchor for normal-heal trigger." }
  $d = $d.Replace("processAutoLoginCommand(*context);", $nmhTr)
  if ($d -notmatch 'NormalHealTrigger') { throw "monitor normal-heal trigger patch failed." }
  Good 'applied monitor normal-heal trigger (field self-heal SendMessage)'
}
$d = $d.Replace("zmffk\\autobattle-diag.log", "zmffk\\autobattle-diag-$tag.log")
$d = $d.Replace("zmffk\\autologin-diag.log", "zmffk\\autologin-diag-$tag.log")
$d = $d.Replace("zmffk\\landing-diag.log", "zmffk\\landing-diag-$tag.log")
$d = $d.Replace("zmffk\\mute-diag.log", "zmffk\\mute-diag-$tag.log")
$d = $d.Replace("zmffk\\boost-diag.log", "zmffk\\boost-diag-$tag.log")
$d = $d.Replace("zmffk\\fastwalk-diag.log", "zmffk\\fastwalk-diag-$tag.log")
$d = $d.Replace("zmffk\\timelock-diag.log", "zmffk\\timelock-diag-$tag.log")
$d = $d.Replace("zmffk\\lockmove-diag.log", "zmffk\\lockmove-diag-$tag.log")
$d = $d.Replace("zmffk\\passwall-diag.log", "zmffk\\passwall-diag-$tag.log")
$d = $d.Replace("zmffk\\autowalk-diag.log", "zmffk\\autowalk-diag-$tag.log")
$d = $d.Replace("zmffk\\fastautowalk-diag.log", "zmffk\\fastautowalk-diag-$tag.log")
$d = $d.Replace("zmffk\\autoescape-diag.log", "zmffk\\autoescape-diag-$tag.log")
# ---- [EXP] 전투종료 획득경험치 채팅표시 (런처 lssproto_RS_recv texts[] 이식, 클라 내부 자족) ----
if ($d -notmatch 'kExpResultMsg') {
  $d = $d.Replace("static const UINT kBattleActMsg = WM_APP + 0x1EEu;", "static const UINT kBattleActMsg = WM_APP + 0x1EEu;`r`n`tstatic const UINT kExpResultMsg = WM_APP + 0x1F0u;")
  if ($d -notmatch 'kExpResultMsg') { throw "exp msg const patch failed." }
  Good 'applied exp-result msg const (WM_APP+0x1F0)'
}
if ($d -notmatch 'ExpResultHandler') {
  $expCase = @'
    if (fm == kExpResultMsg)
    {
        // [ExpResultHandler] 런처 Worker::lssproto_RS_recv(tcpserver 11802-11932) texts[] 이식:
        //   클라 battleResultMsg.resChr[]의 획득 exp를 "player exp:X ride exp:Y pet exp:Z"로 조합해
        //   클라 네이티브 채팅(StockChatBufferLine@0x00425490)에 출력. petNo -2=player / ridePetNo=ride / battlePetNo=pet.
        typedef void(__cdecl* ExpChatFn)(char*, unsigned char, int);
        ExpChatFn expChat = (ExpChatFn)0x00425490u;                 // StockChatBufferLine(str, pal, 0)
        const unsigned int brm = 0x0BD871A8u;                       // battleResultMsg (useFlag@0, resChr[i]@4+i*8)
        const int expRide = *(volatile int*)0x0BD7C210u;            // pc.ridePetNo (off 0x5118)
        const int expBattle = (int)*(volatile short*)0x0BD771A2u;   // pc.battlePetNo (off 0xAA)
        int exPlayer = 0, exRide = 0, exPet = 0;
        int lvPlayer = 0, lvRide = 0, lvPet = 0;                    // resChr[i].levelUp (>0 = 레벨업), petNo/ride/pet 별
        for (int ei = 0; ei < 5; ++ei)                              // RESULT_CHR_EXP = 5
        {
            const int ePetNo = (int)*(volatile short*)(brm + 4u + (unsigned int)ei * 8u);
            const int eLvUp = (int)*(volatile short*)(brm + 6u + (unsigned int)ei * 8u);  // levelUp @+6 (런처 token '|' idx2 >0)
            const int eExp = *(volatile int*)(brm + 8u + (unsigned int)ei * 8u);
            if (eExp <= 0) continue;                                // 런처: if (exp <= 0) continue
            if (ePetNo == -2) { exPlayer = eExp; lvPlayer = (eLvUp > 0) ? 1 : 0; }
            else if (ePetNo == expRide) { exRide = eExp; lvRide = (eLvUp > 0) ? 1 : 0; }
            else if (ePetNo == expBattle) { exPet = eExp; lvPet = (eLvUp > 0) ? 1 : 0; }
        }
        char eMsg[128];
        wsprintfA(eMsg, "player exp:%d%s ride exp:%d%s pet exp:%d%s", exPlayer, lvPlayer ? " [Lv UP]" : "", exRide, lvRide ? " [Lv UP]" : "", exPet, lvPet ? " [Lv UP]" : "");
        expChat(eMsg, (unsigned char)0u, 0);                        // FONT_PAL_WHITE = 0
        HANDLE eh = CreateFileW(L"D:\\SA\\zmffk\\autobattle-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (eh != INVALID_HANDLE_VALUE) { char eb[180]; int ebn = wsprintfA(eb, "exp-result %s (ride=%d battle=%d)\r\n", eMsg, expRide, expBattle); DWORD ebw = 0; WriteFile(eh, eb, (DWORD)ebn, &ebw, nullptr); CloseHandle(eh); }
        return 0;
    }
'@
  $d = $d.Replace("    if (fm == kBattleActMsg)", $expCase + "`r`n`r`n    if (fm == kBattleActMsg)")
  if ($d -notmatch 'ExpResultHandler') { throw "exp handler patch failed." }
  Good 'applied exp-result feWndProc handler (StockChatBufferLine)'
}
if ($d -notmatch 'NormalHealHandler') {
  $nmhCase = @'
    if (fm == kNormalHealMsg)
    {
        // [NormalHealHandler+DIAG] field self-heal. F0: autoHeal magicHeal branch -> lssproto_MU_send(fd,x,y,magic,target).
        // Logs EVERY entry (not only on fire) so we can see WHY it didn't fire: en/bat/sock/hp%/mi/mt/cost/mp.
        const int nb = *(volatile int*)0x0064F83Cu;                     // BattlingFlag (0 = field / non-battle)
        const unsigned int ns = *(volatile unsigned int*)0x0BD71B90u;   // sockfd
        const int dhp = *(volatile int*)0x0BD77108u, dmx = *(volatile int*)0x0BD7710Cu;   // pc.hp / pc.maxHp
        int dpct = (dhp <= 0 || dmx <= 0) ? 0 : (int)((long long)dhp * 100 / dmx); if (dpct == 0 && dhp > 0) dpct = 1;
        const int dmi = (int)g_nmhMagic - 3;
        const short dmt = (dmi >= 0 && dmi <= 8) ? *(volatile short*)(0x0BD812E0u + (unsigned int)dmi * 0x70u + 0x0Au) : (short)-99;
        const int dcost = (dmi >= 0 && dmi <= 8) ? *(volatile int*)(0x0BD812E0u + (unsigned int)dmi * 0x70u + 0x04u) : -1;
        const int dmp = *(volatile int*)0x0BD77110u;                    // pc.mp
        int imp = -1, fImp = 0;
        if (g_nmhIMpEn != 0 && nb == 0 && ns != 0u && ns != 0xFFFFFFFFu)
        {
            const int cmp = *(volatile int*)0x0BD77110u, cmx = *(volatile int*)0x0BD77114u;   // pc.mp / pc.maxMp
            int mpp = (cmp <= 0 || cmx <= 0) ? 0 : (int)((long long)cmp * 100 / cmx); if (mpp == 0 && cmp > 0) mpp = 1;
            if (mpp < (int)g_nmhIMpVal)
            {
                imp = feFindMpItem();
                if (imp >= 0)
                {
                    const int ix = *(volatile int*)0x0BCDE0D8u, iy = *(volatile int*)0x0BCDE0DCu;
                    ((void(__cdecl*)(int,int,int,int,int))0x004B5C60u)((int)ns, ix, iy, imp, 0);   // lssproto_ID_send(fd,x,y,itemIndex,target=0) F0 autoHeal useItem
                    fImp = 1;
                }
            }
        }
        int mi = -1, tgt = -1, fired = 0;
        if (g_nmhEnable != 0 && nb == 0 && ns != 0u && ns != 0xFFFFFFFFu)
        {
            if (feNormalMagicHealRC(&mi, &tgt) == 1)
            {
                const int nx = *(volatile int*)0x0BCDE0D8u;             // nowGx
                const int ny = *(volatile int*)0x0BCDE0DCu;             // nowGy
                ((void(__cdecl*)(int,int,int,int,int))0x004B63A0u)((int)ns, nx, ny, mi, tgt);  // lssproto_MU_send(fd,x,y,magicIndex,target) F0 autoHeal useMagic
                fired = 1;
            }
        }
        HANDLE nhh = CreateFileW(L"D:\\SA\\zmffk\\normalheal-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (nhh != INVALID_HANDLE_VALUE) { char nbf[320]; int nn = wsprintfA(nbf, "nmh-handler en=%d bat=%d sock=%d hp=%d/mx%d pct=%d thr=%d petP=%d alP=%d mag=%d mi=%d mt=%d cost=%d mp=%d tgt=%d fired=%d impEn=%d impV=%d imp=%d fImp=%d\r\n", (int)g_nmhEnable, nb, (int)(ns != 0u && ns != 0xFFFFFFFFu), dhp, dmx, dpct, (int)g_nmhChar, (int)g_nmhPet, (int)g_nmhAllie, (int)g_nmhMagic, dmi, (int)dmt, dcost, dmp, tgt, fired, (int)g_nmhIMpEn, (int)g_nmhIMpVal, imp, fImp); DWORD nw = 0; WriteFile(nhh, nbf, (DWORD)nn, &nw, nullptr); CloseHandle(nhh); }
        return 0;
    }
'@
  $d = $d.Replace("    if (fm == kBattleActMsg)", $nmhCase + "`r`n`r`n    if (fm == kBattleActMsg)")
  if ($d -notmatch 'NormalHealHandler') { throw "normal-heal feWndProc patch failed." }
  Good 'applied normal-heal feWndProc handler (MU_send self)'
}
if ($d -notmatch 'ExpResultTrigger') {
  $expTrig = @'
{
                // [ExpResultTrigger] 전투결과창(BattleResultWndFlag@0x005A7E28) 0->비0 엣지에 exp 채팅출력 트리거.
                //   autoBattle 무관 항상 동작(수동 전투 포함). g_feHwnd 미설정 시 여기서 subclass.
                static int s_lastResWnd = 0;
                const int resWnd = *(volatile int*)0x005A7E28u;
                if (resWnd != 0 && s_lastResWnd == 0 && context->channel != nullptr && context->channel->showExpRequested != 0)
                {
                    if (g_feHwnd == nullptr) { g_fePid = GetCurrentProcessId(); EnumWindows(feFindWnd, 0); if (g_feHwnd != nullptr) { g_feOldWndProc = (WNDPROC)SetWindowLongW(g_feHwnd, GWL_WNDPROC, (LONG)feWndProc); } }
                    if (g_feHwnd != nullptr) { DWORD_PTR exRes = 0u; SendMessageTimeoutW(g_feHwnd, kExpResultMsg, 0, 0, SMTO_ABORTIFHUNG, 300u, &exRes); }
                }
                s_lastResWnd = resWnd;
            }
            processAutoLoginCommand(*context);
'@
  $d = $d.Replace("processAutoLoginCommand(*context);", $expTrig)
  if ($d -notmatch 'ExpResultTrigger') { throw "exp trigger patch failed." }
  Good 'applied exp-result monitor trigger (BattleResultWndFlag edge)'
}
$d = $d.Replace("zmffk\\normalheal-diag.log", "zmffk\\normalheal-diag-$tag.log")  # moved: after BOTH monitor+handler inserted so both get numbered
$d = $d.Replace('D:\\SA\\zmffk', 'C:\\zmffk')  # newpc: client diag-log dir moved D:\SA\zmffk -> C:\zmffk
if ($d -notmatch 'FastBattleHook stage1') {
  $fbHookFn = @'
// [FastBattleHook stage1] inline-hook lssproto_EN_recv(0x485200)/lssproto_B_recv(0x483BF0) to LOG raw
// packet args (call-through, NO block/drive yet) so the real BP/BA/BC wire format is captured before we
// port the launcher's parser+driver. Prologue of both = 10 bytes (55 8bec + cmp[abs],0) with NO relative
// operand, so a 10-byte copy trampoline + 5-byte E9 detour is safe. void __cdecl -> args on stack as-is.
typedef void (__cdecl* t_fbEN)(int fd, int result, int field);
typedef void (__cdecl* t_fbB)(int fd, char* command);
static t_fbEN g_fbTrampEN = nullptr;
static t_fbB  g_fbTrampB  = nullptr;
static volatile LONG g_fbLogEn = 0;
// [FoundationAShadow] wire-parse battle state (launcher Worker::lssproto_B_recv port) and VERIFY it against
// the client SCENE memory the existing auto-battle driver reads. SHADOW ONLY: parse + compare-log, no block, no send.
// BC wire (from Stage1 capture): BC|attr|<unit0..>; unit i fields at full-token base 2+i*13: pos+0 level+4 hp+5 maxhp+6 status+7.
struct FbState { volatile LONG active; int myPos; int myMp; int turn; int animFlag; int hp[20]; int maxhp[20]; int status[20]; int level[20]; int present[20]; int modelid[20]; int rideFlag[20]; int rideLevel[20]; int rideHp[20]; int rideMaxHp[20]; char name[20][32]; char rideName[20][32]; }; // [FastBattleBCParse cycle172] fields ported 1:1 from launcher tcpserver.cpp lssproto_B_recv case 'C' battle_object_t (name/modelid/rideFlag/ride*)
static FbState g_fb = {};
static volatile LONG g_fbHadEnemy = 0; // [FastBattleHadEnemy] set once we've parsed a live enemy this battle; reset on EN. Guards conclusion so a battle-start/partial BC (no enemies yet) is not mistaken for "all dead".
static void fbHookLog(const char* s);  // fwd-decl: fbParseBC (conclusion) + fbShadowB log before fbHookLog's definition below
static int fbTok(const char* s, int n, char* out, int cap) {
	int idx = 0; const char* p = s;
	while (*p && idx < n) { if (*p == '|') idx++; p++; }
	int oi = 0; if (idx < n) { if (cap > 0) out[0] = 0; return 0; }
	while (*p && *p != '|' && oi < cap - 1) { out[oi++] = *p++; }
	out[oi] = 0; return oi;
}
static int fbHex(const char* s) {
	int v = 0, neg = 0; const char* p = s; if (*p == '-') { neg = 1; p++; }
	while (*p) { char c = *p++; int d; if (c >= '0' && c <= '9') d = c - '0'; else if (c >= 'a' && c <= 'f') d = c - 'a' + 10; else if (c >= 'A' && c <= 'F') d = c - 'A' + 10; else break; v = v * 16 + d; }
	return neg ? -v : v;
}
static void fbParseBC(const char* cmd) {
	// [FastBattleBCParse cycle172] launcher-faithful port of Worker::lssproto_B_recv case 'C' (tcpserver.cpp 13957~14024).
	// Per-unit block = 13 tokens; launcher reads at i*13+2..i*13+14. Our token base = 2 + i*13 (== i*13+2), so:
	//   base+0 pos | base+1 name | base+2 freeName(skip) | base+3 modelid | base+4 level | base+5 hp | base+6 maxHp |
	//   base+7 status | base+8 rideFlag | base+9 rideName | base+10 rideLevel | base+11 rideHp | base+12 rideMaxHp.
	// Note: DEAD-zeroing + valid() (needs sa::BC_FLG_DEAD/HIDE) are launcher CONSUMER-side steps -> ported in cycle C (data-source swap). Here we capture raw fields only.
	for (int i = 0; i < 20; ++i) g_fb.present[i] = 0;
	char tk[64];
	for (int i = 0; i < 20; ++i) {
		int base = 2 + i * 13;
		if (fbTok(cmd, base, tk, sizeof(tk)) == 0) break;
		int pos = fbHex(tk); if (pos < 0 || pos >= 20) break;
		fbTok(cmd, base + 1, g_fb.name[pos], 32);                    // +3 name (raw token; makeStringFromEscaped deferred to consumer)
		fbTok(cmd, base + 3, tk, sizeof(tk)); int mid = fbHex(tk);   // +5 modelid
		fbTok(cmd, base + 4, tk, sizeof(tk)); int lv = fbHex(tk);    // +6 level
		fbTok(cmd, base + 5, tk, sizeof(tk)); int hp = fbHex(tk);    // +7 hp
		fbTok(cmd, base + 6, tk, sizeof(tk)); int mx = fbHex(tk);    // +8 maxHp
		fbTok(cmd, base + 7, tk, sizeof(tk)); int st = fbHex(tk);    // +9 status
		fbTok(cmd, base + 8, tk, sizeof(tk)); int rf = fbHex(tk);    // +10 rideFlag
		fbTok(cmd, base + 9, g_fb.rideName[pos], 32);                // +11 rideName
		fbTok(cmd, base + 10, tk, sizeof(tk)); int rlv = fbHex(tk);  // +12 rideLevel
		fbTok(cmd, base + 11, tk, sizeof(tk)); int rhp = fbHex(tk);  // +13 rideHp
		fbTok(cmd, base + 12, tk, sizeof(tk)); int rmx = fbHex(tk);  // +14 rideMaxHp
		g_fb.present[pos] = 1; g_fb.level[pos] = lv; g_fb.hp[pos] = hp; g_fb.maxhp[pos] = mx; g_fb.status[pos] = st;
		g_fb.modelid[pos] = mid; g_fb.rideFlag[pos] = rf; g_fb.rideLevel[pos] = rlv; g_fb.rideHp[pos] = rhp; g_fb.rideMaxHp[pos] = rmx;
	}
}
static volatile LONG g_fbActedTurn = -999;
static void fbShadowEN(int result, int field) { (void)field; g_fb.active = (result > 0) ? 1 : 0; if (result > 0) { g_fbActedTurn = -999; g_fbHadEnemy = 0; for (int i = 0; i < 20; ++i) { g_fb.present[i] = 0; g_fb.hp[i] = 0; } } }
static void fbShadowB(char* command) {
	if (command == nullptr || command[0] == 0 || command[1] == 0) return;
	char tk[32];
	switch (command[1]) {
	case 'C': fbParseBC(command); if (g_fbLogEn) { for (int p = 0; p < 20; ++p) { if (g_fb.present[p]) { char lb[192]; wsprintfA(lb, "BCunit pos=%d model=%X lv=%d hp=%d/%d st=%X rf=%d rlv=%d rhp=%d/%d name=%s ride=%s\r\n", p, g_fb.modelid[p], g_fb.level[p], g_fb.hp[p], g_fb.maxhp[p], g_fb.status[p], g_fb.rideFlag[p], g_fb.rideLevel[p], g_fb.rideHp[p], g_fb.rideMaxHp[p], g_fb.name[p], g_fb.rideName[p]); fbHookLog(lb); } } } break; // [FastBattleBCParse cycle172] deterministic parse-log: verify g_fb captured every case 'C' field vs the raw "B ... head=" wire dump
	case 'A': fbTok(command, 1, tk, sizeof(tk)); g_fb.animFlag = fbHex(tk); fbTok(command, 2, tk, sizeof(tk)); g_fb.turn = fbHex(tk); break;
	case 'P': fbTok(command, 1, tk, sizeof(tk)); g_fb.myPos = fbHex(tk); fbTok(command, 3, tk, sizeof(tk)); g_fb.myMp = fbHex(tk); break;
	case 'U': g_fb.active = 0; break;
	default: break;
	}
}
static void fbHookLog(const char* s) {
	HANDLE h = CreateFileW(L"D:\\SA\\zmffk\\fastbattle-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
	if (h != INVALID_HANDLE_VALUE) { DWORD w = 0; WriteFile(h, s, (DWORD)lstrlenA(s), &w, nullptr); CloseHandle(h); }
}
static void __cdecl fbHookEN(int fd, int result, int field) {
	if (g_fbLogEn) { char b[128]; wsprintfA(b, "EN fd=%d result=%d field=%d\r\n", fd, result, field); fbHookLog(b); }
	fbShadowEN(result, field);
	if (g_fbLogEn) return; // [FastBattleBlock] fast-battle ON: drop client EN handler -> no scene/anim, char on field
	if (g_fbTrampEN) g_fbTrampEN(fd, result, field);
}
static void __cdecl fbHookB(int fd, char* command) {
	if (g_fbLogEn && command != nullptr) {
		const int c1 = command[0] ? (unsigned char)command[0] : (int)'?'; const int c2 = command[1] ? (unsigned char)command[1] : (int)'?';
		int len = lstrlenA(command); int hl = len > 240 ? 240 : len; char head[241]; for (int i = 0; i < hl; ++i) { char c = command[i]; head[i] = (c >= 32 && c < 127) ? c : '.'; } head[hl] = 0; // [FastBattleDiag165] widen BC head to read enemy HP
		char b2[320]; wsprintfA(b2, "B fd=%d sub=%c%c len=%d head=%s\r\n", fd, c1, c2, len, head); fbHookLog(b2);
	}
	fbShadowB(command);
	if (g_fbLogEn) return; // [FastBattleBlock] fast-battle ON: drop client B handler -> no battle anim
	if (g_fbTrampB) g_fbTrampB(fd, command);
}

static BYTE* fbMakeTramp(BYTE* func, int prologLen, BYTE* backTarget) {
	BYTE* tr = reinterpret_cast<BYTE*>(VirtualAlloc(nullptr, 64u, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE));
	if (tr == nullptr) return nullptr;
	for (int i = 0; i < prologLen; ++i) tr[i] = func[i];
	tr[prologLen] = 0xE9;
	*reinterpret_cast<int*>(tr + prologLen + 1) = static_cast<int>(backTarget - (tr + prologLen + 5));
	FlushInstructionCache(GetCurrentProcess(), tr, static_cast<unsigned>(prologLen) + 5u);
	return tr;
}
static bool fbPatchJmp(BYTE* func, void* hook) {
	DWORD op = 0;
	if (!VirtualProtect(func, 5u, PAGE_EXECUTE_READWRITE, &op)) return false;
	func[0] = 0xE9;
	*reinterpret_cast<int*>(func + 1) = static_cast<int>(reinterpret_cast<BYTE*>(hook) - (func + 5));
	DWORD t = 0; VirtualProtect(func, 5u, op, &t);
	FlushInstructionCache(GetCurrentProcess(), func, 5u);
	return true;
}
static void fbInstallHook(std::uintptr_t base) {
	static int s_done = 0; if (s_done) return; s_done = 1;
	{ char m[64]; wsprintfA(m, "fbInstall STEP0 enter base=%p\r\n", (void*)base); fbHookLog(m); } // [FbCrashDiag174] pinpoint early crash on fast-battle install
	BYTE* enF = reinterpret_cast<BYTE*>(base + 0x00085200u);
	BYTE* bF  = reinterpret_cast<BYTE*>(base + 0x00083BF0u);
	g_fbTrampEN = reinterpret_cast<t_fbEN>(fbMakeTramp(enF, 10, reinterpret_cast<BYTE*>(base + 0x0008520Au)));
	{ char m[64]; wsprintfA(m, "fbInstall STEP1 trampEN=%p\r\n", (void*)g_fbTrampEN); fbHookLog(m); }
	g_fbTrampB  = reinterpret_cast<t_fbB>(fbMakeTramp(bF, 10, reinterpret_cast<BYTE*>(base + 0x00083BFAu)));
	{ char m[64]; wsprintfA(m, "fbInstall STEP2 trampB=%p\r\n", (void*)g_fbTrampB); fbHookLog(m); }
	int ok = 0;
	if (g_fbTrampEN && fbPatchJmp(enF, reinterpret_cast<void*>(&fbHookEN))) ok |= 1;
	{ char m[48]; wsprintfA(m, "fbInstall STEP3 patchEN ok=%d\r\n", ok); fbHookLog(m); }
	if (g_fbTrampB  && fbPatchJmp(bF,  reinterpret_cast<void*>(&fbHookB)))  ok |= 2;
	{ char m[48]; wsprintfA(m, "fbInstall STEP4 patchB ok=%d\r\n", ok); fbHookLog(m); }
	char b[96]; wsprintfA(b, "fastbattle-hook install ok=%d enTr=%p bTr=%p\r\n", ok, (void*)g_fbTrampEN, (void*)g_fbTrampB); fbHookLog(b);
}
'@
  if ($d.IndexOf("void processAutoLoginCommand(MonitorContext& context) noexcept") -lt 0) { throw "fbhook func anchor missing." }
  $d = $d.Replace("void processAutoLoginCommand(MonitorContext& context) noexcept", $fbHookFn + "`r`n`r`nvoid processAutoLoginCommand(MonitorContext& context) noexcept")
  if ($d -notmatch 'fbInstallHook') { throw "fbhook func inject failed." }
  Good 'applied FastBattleHook stage1 functions (EN/B inline hook + log)'
}
if ($d -notmatch 'FastBattleHook drive') {
  $fbMon = @'
processAutoLoginCommand(*context);
			// [FastBattleHook drive] install the EN/B log-hook once (needs the module base), and gate logging by
			// the launcher kFastBattleEnable flag (fastBattleRequested). Stage1 = observe packets only.
			if (context->module != nullptr)
			{
				{ static int s_fbmon = 0; if (!s_fbmon) { s_fbmon = 1; char mm[80]; wsprintfA(mm, "FBMON first-tick module=%p chan=%p\r\n", (void*)context->module, (void*)context->channel); fbHookLog(mm); } } /* [FbCrashDiag174] monitor reached fast-battle block (once) */ if (context->channel != nullptr) { InterlockedExchange(&g_fbLogEn, client05_readonly::readLong(context->channel->fastBattleRequested) == 1 ? 1 : 0); }
				if (g_fbLogEn) { static int s_fbgate = 0; if (!s_fbgate) { s_fbgate = 1; char mg[64]; wsprintfA(mg, "FBGATE install-call g_fbLogEn=1\r\n"); fbHookLog(mg); } fbInstallHook(reinterpret_cast<std::uintptr_t>(context->module)); } // [FbCrashDiag174] FBGATE marker before install. [CycleA-Gate171] install EN/B hook ONLY when fast-battle ON. Launcher's New_lssproto_EN/B_recv is a no-op passthrough when block-flag is off, so NOT installing while off is behaviorally identical to the launcher-when-off. Isolates the cycle-A crash: fast-battle OFF -> client EN/B untouched -> pure-vanilla auto-battle.
				}
'@
  if ($d.IndexOf("processAutoLoginCommand(*context);") -lt 0) { throw "fbhook mon anchor missing." }
  $d = $d.Replace("processAutoLoginCommand(*context);", $fbMon)
  if ($d -notmatch 'FastBattleHook drive') { throw "fbhook mon inject failed." }
  if ($d -notmatch 'CycleA-Gate171') { throw "fbhook install-gate (CycleA-Gate171) missing." }
  Good 'applied FastBattleHook drive (install GATED on fast-battle enable + log gate)'
}
# [newpc path fix] FastBattleHook block is injected AFTER the earlier D->C replace (line ~1925), so its
# fastbattle-diag.log path stayed as the OLD D:\SA\zmffk (absent on newpc -> log silently lost). Catch-all
# re-map right before write so ALL injected diag paths land in the connected C:\zmffk dir.
$d = $d.Replace('D:\\SA\\zmffk', 'C:\\zmffk')
[IO.File]::WriteAllText($diag, $d, $utf8bom)

# ---- client05_transport_adapter.cpp : dynamic game socket ----
$t = [IO.File]::ReadAllText($tad)
if ($t -notmatch 'currentGameSocket') {
  $tadRep = @'
const SOCKET currentGameSocket = (gameSocketAddress_ != nullptr) ? *gameSocketAddress_ : INVALID_SOCKET;
	if (!ready() || data == nullptr || size == 0u || gameSocketAddress_ == nullptr ||
		currentGameSocket == INVALID_SOCKET || socket != currentGameSocket)
	{
		disableTransport(DisableReason::socketIdentity);
		return false;
	}
	gameSocket_ = currentGameSocket;
'@
  $trx = [regex]'(?s)if \(!ready\(\) \|\| data == nullptr.*?disableTransport\(DisableReason::socketIdentity\);\s*return false;\s*\}'
  if (-not $trx.IsMatch($t)) { throw "could not locate enqueueAndForward block." }
  $t = $trx.Replace($t, $tadRep, 1); Good 'applied transport dynamic-socket fix'
}
[IO.File]::WriteAllText($tad, $t, $utf8bom)

# ---- gamedevice.h / .cpp : setClient05MuteRequested ----
$gh = [IO.File]::ReadAllText($gdh)
if ($gh -notmatch 'setClient05MuteRequested') {
  $gh = $gh.Replace("int character) noexcept;", "int character) noexcept;`r`n`tvoid setClient05MuteRequested(bool enable) noexcept;")
  if ($gh -notmatch 'setClient05MuteRequested') { throw "gamedevice.h mute decl failed." }
  Good 'applied gamedevice.h mute decl'
}
if ($gh -notmatch 'setClient05BoostRequested') {
  $gh = $gh.Replace("void setClient05MuteRequested(bool enable) noexcept;", "void setClient05MuteRequested(bool enable) noexcept;`r`n`tvoid setClient05BoostRequested(int level) noexcept;")
  if ($gh -notmatch 'setClient05BoostRequested') { throw "gamedevice.h boost decl failed." }
  Good 'applied gamedevice.h boost decl'
}
if ($gh -notmatch 'setClient05AutoLoginRequested') {
  $gh = $gh.Replace("void setClient05BoostRequested(int level) noexcept;", "void setClient05BoostRequested(int level) noexcept;`r`n`tvoid setClient05AutoLoginRequested(int state) noexcept;`r`n`tvoid setClient05ReconnectRequested(int state) noexcept;")
  if ($gh -notmatch 'setClient05AutoLoginRequested') { throw "gamedevice.h autologin decl failed." }
  Good 'applied gamedevice.h autologin decl'
}
if ($gh -notmatch 'setClient05FastWalkRequested') {
  $gh = $gh.Replace("void setClient05ReconnectRequested(int state) noexcept;", "void setClient05ReconnectRequested(int state) noexcept;`r`n`tvoid setClient05FastWalkRequested(bool enable) noexcept;")
  if ($gh -notmatch 'setClient05FastWalkRequested') { throw "gamedevice.h fastwalk decl failed." }
  Good 'applied gamedevice.h fastwalk decl'
}
if ($gh -notmatch 'setClient05TimeLockRequested') {
  $gh = $gh.Replace("void setClient05FastWalkRequested(bool enable) noexcept;", "void setClient05FastWalkRequested(bool enable) noexcept;`r`n`tvoid setClient05TimeLockRequested(int state) noexcept;")
  if ($gh -notmatch 'setClient05TimeLockRequested') { throw "gamedevice.h timelock decl failed." }
  Good 'applied gamedevice.h timelock decl'
}
if ($gh -notmatch 'setClient05LockMoveRequested') {
  $gh = $gh.Replace("void setClient05TimeLockRequested(int state) noexcept;", "void setClient05TimeLockRequested(int state) noexcept;`r`n`tvoid setClient05LockMoveRequested(int state) noexcept;")
  if ($gh -notmatch 'setClient05LockMoveRequested') { throw "gamedevice.h lockmove decl failed." }
  Good 'applied gamedevice.h lockmove decl'
}
if ($gh -notmatch 'setClient05PassWallRequested') {
  $gh = $gh.Replace("void setClient05LockMoveRequested(int state) noexcept;", "void setClient05LockMoveRequested(int state) noexcept;`r`n`tvoid setClient05PassWallRequested(bool enable) noexcept;")
  if ($gh -notmatch 'setClient05PassWallRequested') { throw "gamedevice.h passwall decl failed." }
  Good 'applied gamedevice.h passwall decl'
}
if ($gh -notmatch 'setClient05AutoWalkRequested') {
  $gh = $gh.Replace("void setClient05PassWallRequested(bool enable) noexcept;", "void setClient05PassWallRequested(bool enable) noexcept;`r`n`tvoid setClient05AutoWalkRequested(bool enable) noexcept;")
  if ($gh -notmatch 'setClient05AutoWalkRequested') { throw "gamedevice.h autowalk decl failed." }
  Good 'applied gamedevice.h autowalk decl'
}
if ($gh -notmatch 'setClient05AutoWalkDistance') {
  $gh = $gh.Replace("void setClient05AutoWalkRequested(bool enable) noexcept;", "void setClient05AutoWalkRequested(bool enable) noexcept;`r`n`tvoid setClient05AutoWalkDistance(int value) noexcept;`r`n`tvoid setClient05AutoWalkDirection(int value) noexcept;`r`n`tvoid setClient05AutoWalkDelay(int value) noexcept;")
  if ($gh -notmatch 'setClient05AutoWalkDistance') { throw "gamedevice.h autowalk dist/dir decl failed." }
  Good 'applied gamedevice.h autowalk distance/direction decls'
}
if ($gh -notmatch 'setClient05FastAutoWalkRequested') {
  $gh = $gh.Replace("void setClient05AutoWalkRequested(bool enable) noexcept;", "void setClient05AutoWalkRequested(bool enable) noexcept;`r`n`tvoid setClient05FastAutoWalkRequested(bool enable) noexcept;")
  if ($gh -notmatch 'setClient05FastAutoWalkRequested') { throw "gamedevice.h fastautowalk decl failed." }
  Good 'applied gamedevice.h fastautowalk decl'
}
if ($gh -notmatch 'setClient05AutoEscapeRequested') {
  $gh = $gh.Replace("void setClient05FastAutoWalkRequested(bool enable) noexcept;", "void setClient05FastAutoWalkRequested(bool enable) noexcept;`r`n`tvoid setClient05AutoEscapeRequested(bool enable) noexcept;")
  if ($gh -notmatch 'setClient05AutoEscapeRequested') { throw "gamedevice.h autoescape decl failed." }
  Good 'applied gamedevice.h autoescape decl'
}
if ($gh -notmatch 'setClient05AutoBattleRequested') {
  $gh = $gh.Replace("void setClient05AutoEscapeRequested(bool enable) noexcept;", "void setClient05AutoEscapeRequested(bool enable) noexcept;`r`n`tvoid setClient05AutoBattleRequested(bool enable) noexcept;`r`n`tvoid setClient05BattleCharActionType(int value) noexcept;`r`n`tvoid setClient05BattleCharActionTarget(int value) noexcept;`r`n`tvoid setClient05BattlePetActionType(int value) noexcept;`r`n`tvoid setClient05BattlePetActionTarget(int value) noexcept;`r`n`tvoid setClient05BattleCharActionEnemy(int value) noexcept;`r`n`tvoid setClient05BattleCharActionLevel(int value) noexcept;")
  if ($gh -notmatch 'setClient05AutoBattleRequested') { throw "gamedevice.h autobattle decls failed." }
  Good 'applied gamedevice.h autobattle decls'
}
if ($gh -notmatch 'setClient05BattleCharRoundRound') {
  $gh = $gh.Replace("void setClient05BattleCharActionLevel(int value) noexcept;", "void setClient05BattleCharActionLevel(int value) noexcept;`r`n`tvoid setClient05BattleCharRoundRound(int value) noexcept;`r`n`tvoid setClient05BattleCharRoundEnemy(int value) noexcept;`r`n`tvoid setClient05BattleCharRoundLevel(int value) noexcept;`r`n`tvoid setClient05BattleCharRoundType(int value) noexcept;`r`n`tvoid setClient05BattleCharRoundTarget(int value) noexcept;`r`n`tvoid setClient05BattleCharCrossEnable(int value) noexcept;`r`n`tvoid setClient05BattleCharCrossRound(int value) noexcept;`r`n`tvoid setClient05BattleCharCrossType(int value) noexcept;`r`n`tvoid setClient05BattleCharCrossTarget(int value) noexcept;`r`n`tvoid setClient05BattleActionDelay(int value) noexcept;")
  if ($gh -notmatch 'setClient05BattleCharRoundRound') { throw "gamedevice.h round/cross decls failed." }
  Good 'applied gamedevice.h battle round/cross/delay decls'
}
if ($gh -notmatch 'setClient05BattlePetRoundRound') {
  $gh = $gh.Replace("void setClient05BattleActionDelay(int value) noexcept;", "void setClient05BattleActionDelay(int value) noexcept;`r`n`tvoid setClient05BattlePetRoundRound(int value) noexcept;`r`n`tvoid setClient05BattlePetRoundEnemy(int value) noexcept;`r`n`tvoid setClient05BattlePetRoundLevel(int value) noexcept;`r`n`tvoid setClient05BattlePetRoundType(int value) noexcept;`r`n`tvoid setClient05BattlePetRoundTarget(int value) noexcept;`r`n`tvoid setClient05BattlePetCrossEnable(int value) noexcept;`r`n`tvoid setClient05BattlePetCrossRound(int value) noexcept;`r`n`tvoid setClient05BattlePetCrossType(int value) noexcept;`r`n`tvoid setClient05BattlePetCrossTarget(int value) noexcept;")
  if ($gh -notmatch 'setClient05BattlePetRoundRound') { throw "gamedevice.h pet decls failed." }
  Good 'applied gamedevice.h battle pet round/cross decls'
}
if ($gh -notmatch 'setClient05BattleMagicHealEnable') {
  $gh = $gh.Replace("void setClient05BattlePetCrossTarget(int value) noexcept;", "void setClient05BattlePetCrossTarget(int value) noexcept;`r`n`tvoid setClient05BattleMagicHealEnable(int value) noexcept;`r`n`tvoid setClient05BattleMagicHealTarget(int value) noexcept;`r`n`tvoid setClient05BattleMagicHealChar(int value) noexcept;`r`n`tvoid setClient05BattleMagicHealPet(int value) noexcept;`r`n`tvoid setClient05BattleMagicHealAllie(int value) noexcept;`r`n`tvoid setClient05BattleMagicHealMagic(int value) noexcept;`r`n`tvoid setClient05BattleSkillMpEnable(int value) noexcept;`r`n`tvoid setClient05BattleSkillMpValue(int value) noexcept;`r`n`tvoid setClient05BattleItemHealMpEnable(int value) noexcept;`r`n`tvoid setClient05BattleItemHealMpValue(int value) noexcept;`r`n`tvoid setClient05BattleFallEscape(bool enable) noexcept;")
  if ($gh -notmatch 'setClient05BattleMagicHealEnable') { throw "gamedevice.h magic-heal decls failed." }
  Good 'applied gamedevice.h magic-heal decls'
}
if ($gh -notmatch 'setClient05NormalMagicHealEnable') {
  $gh = $gh.Replace("void setClient05BattleFallEscape(bool enable) noexcept;", "void setClient05BattleFallEscape(bool enable) noexcept;`r`n`tvoid setClient05NormalMagicHealEnable(int value) noexcept;`r`n`tvoid setClient05NormalMagicHealChar(int value) noexcept;`r`n`tvoid setClient05NormalMagicHealMagic(int value) noexcept;`r`n`tvoid setClient05NormalMagicHealPet(int value) noexcept;`r`n`tvoid setClient05NormalMagicHealAllie(int value) noexcept;`r`n`tvoid setClient05NormalItemHealMpEnable(int value) noexcept;`r`n`tvoid setClient05NormalItemHealMpValue(int value) noexcept;")
  if ($gh -notmatch 'setClient05NormalMagicHealEnable') { throw "gamedevice.h normal magic-heal decls failed." }
  Good 'applied gamedevice.h normal magic-heal decls'
}
if ($gh -notmatch 'setClient05ShowExpRequested') {
  $gh = $gh.Replace("void setClient05BoostRequested(int level) noexcept;", "void setClient05BoostRequested(int level) noexcept;`r`n`tvoid setClient05ShowExpRequested(bool enable) noexcept;")
  if ($gh -notmatch 'setClient05ShowExpRequested') { throw "showexp decl patch failed." }
  Good 'applied showexp setter decl'
}
if ($gh -notmatch 'setClient05FastBattleRequested') {
  $gh = $gh.Replace("void setClient05AutoWalkDelay(int value) noexcept;", "void setClient05AutoWalkDelay(int value) noexcept;`r`n`tvoid setClient05FastBattleRequested(int value) noexcept;")
  if ($gh -notmatch 'setClient05FastBattleRequested') { throw "gamedevice.h fastBattle decl failed." }
  Good 'applied gamedevice.h fastBattle decl'
}
[IO.File]::WriteAllText($gdh, $gh, $utf8bom)
$gc = [IO.File]::ReadAllText($gdc)
if ($gc -notmatch 'setClient05MuteRequested') {
  $muteDef = @'
void GameDevice::setClient05MuteRequested(bool enable) noexcept
{
	if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
		return;
	InterlockedExchange(&client05ReadOnlyChannel_->muteRequested, enable ? TRUE : FALSE);
}

bool GameDevice::publishClient05B1BattleDefendEcho(const std::uint32_t deadlineMilliseconds) noexcept
'@
  $gc = $gc.Replace("bool GameDevice::publishClient05B1BattleDefendEcho(const std::uint32_t deadlineMilliseconds) noexcept", $muteDef)
  if ($gc -notmatch 'setClient05MuteRequested') { throw "gamedevice.cpp mute def failed." }
  Good 'applied gamedevice.cpp mute def'
}
if ($gc -notmatch 'setClient05BoostRequested') {
  $boostDef = @'
void GameDevice::setClient05BoostRequested(int level) noexcept
{
	if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
		return;
	if (level < 0) level = 0;
	if (level > 14) level = 14;
	InterlockedExchange(&client05ReadOnlyChannel_->boostRequested, static_cast<LONG>(level));
}

bool GameDevice::publishClient05B1BattleDefendEcho(const std::uint32_t deadlineMilliseconds) noexcept
'@
  $gc = $gc.Replace("bool GameDevice::publishClient05B1BattleDefendEcho(const std::uint32_t deadlineMilliseconds) noexcept", $boostDef)
  if ($gc -notmatch 'setClient05BoostRequested') { throw "gamedevice.cpp boost def failed." }
  Good 'applied gamedevice.cpp boost def'
}
if ($gc -notmatch 'setClient05AutoLoginRequested') {
  $alDef = @'
void GameDevice::setClient05AutoLoginRequested(int state) noexcept
{
	if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
		return;
	InterlockedExchange(&client05ReadOnlyChannel_->autoLoginRequested, static_cast<LONG>(state));
}

void GameDevice::setClient05ReconnectRequested(int state) noexcept
{
	if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
		return;
	InterlockedExchange(&client05ReadOnlyChannel_->reconnectRequested, static_cast<LONG>(state));
}

bool GameDevice::publishClient05B1BattleDefendEcho(const std::uint32_t deadlineMilliseconds) noexcept
'@
  $gc = $gc.Replace("bool GameDevice::publishClient05B1BattleDefendEcho(const std::uint32_t deadlineMilliseconds) noexcept", $alDef)
  if ($gc -notmatch 'setClient05AutoLoginRequested') { throw "gamedevice.cpp autologin def failed." }
  Good 'applied gamedevice.cpp autologin def'
}
if ($gc -notmatch 'setClient05FastWalkRequested') {
  $fwDef = @'
void GameDevice::setClient05FastWalkRequested(bool enable) noexcept
{
	if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
		return;
	InterlockedExchange(&client05ReadOnlyChannel_->fastWalkRequested, enable ? TRUE : FALSE);
}

bool GameDevice::publishClient05B1BattleDefendEcho(const std::uint32_t deadlineMilliseconds) noexcept
'@
  $gc = $gc.Replace("bool GameDevice::publishClient05B1BattleDefendEcho(const std::uint32_t deadlineMilliseconds) noexcept", $fwDef)
  if ($gc -notmatch 'setClient05FastWalkRequested') { throw "gamedevice.cpp fastwalk def failed." }
  Good 'applied gamedevice.cpp fastwalk def'
}
if ($gc -notmatch 'setClient05TimeLockRequested') {
  $tlDef = @'
void GameDevice::setClient05TimeLockRequested(int state) noexcept
{
	if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
		return;
	InterlockedExchange(&client05ReadOnlyChannel_->timeLockRequested, static_cast<LONG>(state));
}

bool GameDevice::publishClient05B1BattleDefendEcho(const std::uint32_t deadlineMilliseconds) noexcept
'@
  $gc = $gc.Replace("bool GameDevice::publishClient05B1BattleDefendEcho(const std::uint32_t deadlineMilliseconds) noexcept", $tlDef)
  if ($gc -notmatch 'setClient05TimeLockRequested') { throw "gamedevice.cpp timelock def failed." }
  Good 'applied gamedevice.cpp timelock def'
}
if ($gc -notmatch 'setClient05LockMoveRequested') {
  $lmDef = @'
void GameDevice::setClient05LockMoveRequested(int state) noexcept
{
	if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
		return;
	InterlockedExchange(&client05ReadOnlyChannel_->lockMoveRequested, static_cast<LONG>(state));
}

bool GameDevice::publishClient05B1BattleDefendEcho(const std::uint32_t deadlineMilliseconds) noexcept
'@
  $gc = $gc.Replace("bool GameDevice::publishClient05B1BattleDefendEcho(const std::uint32_t deadlineMilliseconds) noexcept", $lmDef)
  if ($gc -notmatch 'setClient05LockMoveRequested') { throw "gamedevice.cpp lockmove def failed." }
  Good 'applied gamedevice.cpp lockmove def'
}
if ($gc -notmatch 'setClient05PassWallRequested') {
  $pwDef = @'
void GameDevice::setClient05PassWallRequested(bool enable) noexcept
{
	if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
		return;
	InterlockedExchange(&client05ReadOnlyChannel_->passWallRequested, enable ? TRUE : FALSE);
}

bool GameDevice::publishClient05B1BattleDefendEcho(const std::uint32_t deadlineMilliseconds) noexcept
'@
  $gc = $gc.Replace("bool GameDevice::publishClient05B1BattleDefendEcho(const std::uint32_t deadlineMilliseconds) noexcept", $pwDef)
  if ($gc -notmatch 'setClient05PassWallRequested') { throw "gamedevice.cpp passwall def failed." }
  Good 'applied gamedevice.cpp passwall def'
}
if ($gc -notmatch 'setClient05AutoWalkRequested') {
  $wkDef = @'
void GameDevice::setClient05AutoWalkRequested(bool enable) noexcept
{
	if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
		return;
	InterlockedExchange(&client05ReadOnlyChannel_->autoWalkRequested, enable ? TRUE : FALSE);
}

bool GameDevice::publishClient05B1BattleDefendEcho(const std::uint32_t deadlineMilliseconds) noexcept
'@
  $gc = $gc.Replace("bool GameDevice::publishClient05B1BattleDefendEcho(const std::uint32_t deadlineMilliseconds) noexcept", $wkDef)
  if ($gc -notmatch 'setClient05AutoWalkRequested') { throw "gamedevice.cpp autowalk def failed." }
  Good 'applied gamedevice.cpp autowalk def'
}
if ($gc -notmatch 'setClient05AutoWalkDistance') {
  $wkvDef = @'
void GameDevice::setClient05AutoWalkDistance(int value) noexcept
{
	if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
		return;
	InterlockedExchange(&client05ReadOnlyChannel_->autoWalkDistance, static_cast<LONG>(value));
}

void GameDevice::setClient05AutoWalkDirection(int value) noexcept
{
	if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
		return;
	InterlockedExchange(&client05ReadOnlyChannel_->autoWalkDirection, static_cast<LONG>(value));
}

void GameDevice::setClient05AutoWalkDelay(int value) noexcept
{
	if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
		return;
	InterlockedExchange(&client05ReadOnlyChannel_->autoWalkDelay, static_cast<LONG>(value));
}

void GameDevice::setClient05AutoWalkRequested(bool enable) noexcept
'@
  $gc = $gc.Replace("void GameDevice::setClient05AutoWalkRequested(bool enable) noexcept", $wkvDef)
  if ($gc -notmatch 'setClient05AutoWalkDistance') { throw "gamedevice.cpp autowalk dist/dir def failed." }
  Good 'applied gamedevice.cpp autowalk distance/direction defs'
}
if ($gc -notmatch 'setClient05FastAutoWalkRequested') {
  $faDef = @'
void GameDevice::setClient05FastAutoWalkRequested(bool enable) noexcept
{
	if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
		return;
	InterlockedExchange(&client05ReadOnlyChannel_->fastAutoWalkRequested, enable ? TRUE : FALSE);
}

void GameDevice::setClient05AutoWalkRequested(bool enable) noexcept
'@
  $gc = $gc.Replace("void GameDevice::setClient05AutoWalkRequested(bool enable) noexcept", $faDef)
  if ($gc -notmatch 'setClient05FastAutoWalkRequested') { throw "gamedevice.cpp fastautowalk def failed." }
  Good 'applied gamedevice.cpp fastautowalk def'
}
if ($gc -notmatch 'setClient05AutoEscapeRequested') {
  $aeDef = @'
void GameDevice::setClient05AutoEscapeRequested(bool enable) noexcept
{
	if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
		return;
	InterlockedExchange(&client05ReadOnlyChannel_->autoEscapeRequested, enable ? TRUE : FALSE);
}

void GameDevice::setClient05FastAutoWalkRequested(bool enable) noexcept
'@
  $gc = $gc.Replace("void GameDevice::setClient05FastAutoWalkRequested(bool enable) noexcept", $aeDef)
  if ($gc -notmatch 'setClient05AutoEscapeRequested') { throw "gamedevice.cpp autoescape def failed." }
  Good 'applied gamedevice.cpp autoescape def'
}
if ($gc -notmatch 'setClient05AutoBattleRequested') {
  $abDef = @'
void GameDevice::setClient05AutoBattleRequested(bool enable) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->autoBattleRequested, enable ? TRUE : FALSE);
}

void GameDevice::setClient05BattleCharActionType(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battleCharActionType, static_cast<LONG>(value));
}

void GameDevice::setClient05BattleCharActionTarget(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battleCharActionTarget, static_cast<LONG>(value));
}

void GameDevice::setClient05BattlePetActionType(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battlePetActionType, static_cast<LONG>(value));
}

void GameDevice::setClient05BattlePetActionTarget(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battlePetActionTarget, static_cast<LONG>(value));
}

void GameDevice::setClient05BattleCharActionEnemy(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battleCharNormalEnemy, static_cast<LONG>(value));
}

void GameDevice::setClient05BattleCharActionLevel(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battleCharNormalLevel, static_cast<LONG>(value));
}

void GameDevice::setClient05BattleCharRoundRound(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battleCharRoundRound, static_cast<LONG>(value));
}

void GameDevice::setClient05BattleCharRoundEnemy(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battleCharRoundEnemy, static_cast<LONG>(value));
}

void GameDevice::setClient05BattleCharRoundLevel(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battleCharRoundLevel, static_cast<LONG>(value));
}

void GameDevice::setClient05BattleCharRoundType(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battleCharRoundType, static_cast<LONG>(value));
}

void GameDevice::setClient05BattleCharRoundTarget(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battleCharRoundTarget, static_cast<LONG>(value));
}

void GameDevice::setClient05BattleCharCrossEnable(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battleCharCrossEnable, static_cast<LONG>(value));
}

void GameDevice::setClient05BattleCharCrossRound(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battleCharCrossRound, static_cast<LONG>(value));
}

void GameDevice::setClient05BattleCharCrossType(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battleCharCrossType, static_cast<LONG>(value));
}

void GameDevice::setClient05BattleCharCrossTarget(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battleCharCrossTarget, static_cast<LONG>(value));
}

void GameDevice::setClient05BattleActionDelay(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battleActionDelay, static_cast<LONG>(value));
}

void GameDevice::setClient05BattlePetRoundRound(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battlePetRoundRound, static_cast<LONG>(value));
}

void GameDevice::setClient05BattlePetRoundEnemy(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battlePetRoundEnemy, static_cast<LONG>(value));
}

void GameDevice::setClient05BattlePetRoundLevel(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battlePetRoundLevel, static_cast<LONG>(value));
}

void GameDevice::setClient05BattlePetRoundType(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battlePetRoundType, static_cast<LONG>(value));
}

void GameDevice::setClient05BattlePetRoundTarget(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battlePetRoundTarget, static_cast<LONG>(value));
}

void GameDevice::setClient05BattlePetCrossEnable(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battlePetCrossEnable, static_cast<LONG>(value));
}

void GameDevice::setClient05BattlePetCrossRound(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battlePetCrossRound, static_cast<LONG>(value));
}

void GameDevice::setClient05BattlePetCrossType(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battlePetCrossType, static_cast<LONG>(value));
}

void GameDevice::setClient05BattlePetCrossTarget(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battlePetCrossTarget, static_cast<LONG>(value));
}

void GameDevice::setClient05BattleMagicHealEnable(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battleMagicHealEnable, static_cast<LONG>(value));
}

void GameDevice::setClient05BattleMagicHealTarget(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battleMagicHealTarget, static_cast<LONG>(value));
}

void GameDevice::setClient05BattleMagicHealChar(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battleMagicHealChar, static_cast<LONG>(value));
}

void GameDevice::setClient05BattleMagicHealPet(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battleMagicHealPet, static_cast<LONG>(value));
}

void GameDevice::setClient05BattleMagicHealAllie(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battleMagicHealAllie, static_cast<LONG>(value));
}

void GameDevice::setClient05BattleMagicHealMagic(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battleMagicHealMagic, static_cast<LONG>(value));
}

void GameDevice::setClient05BattleSkillMpEnable(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battleSkillMpEnable, static_cast<LONG>(value));
}

void GameDevice::setClient05BattleSkillMpValue(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battleSkillMpValue, static_cast<LONG>(value));
}

void GameDevice::setClient05BattleItemHealMpEnable(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battleItemHealMpEnable, static_cast<LONG>(value));
}

void GameDevice::setClient05BattleItemHealMpValue(int value) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battleItemHealMpValue, static_cast<LONG>(value));
}

void GameDevice::setClient05BattleFallEscape(bool enable) noexcept
{
    if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
        return;
    InterlockedExchange(&client05ReadOnlyChannel_->battleFallEscapeRequested, enable ? TRUE : FALSE);
}

void GameDevice::setClient05AutoEscapeRequested(bool enable) noexcept
'@
  $gc = $gc.Replace("void GameDevice::setClient05AutoEscapeRequested(bool enable) noexcept", $abDef)
  if ($gc -notmatch 'setClient05AutoBattleRequested') { throw "gamedevice.cpp autobattle defs failed." }
  Good 'applied gamedevice.cpp autobattle defs'
}
if ($gc -notmatch 'SashInjectRetry') {
  if ($gc.IndexOf("`t`t`t`tif (!mem::injectBy64(currentIndex, pi.dwProcessId, processHandle_, dllPath,") -lt 0) { throw "could not locate injectBy64 anchor." }
  $gc = $gc.Replace("#if QT_VERSION < QT_VERSION_CHECK(6, 0, 0)`r`n`t`t`t`tif (!mem::injectByWin7(currentIndex, pi.dwProcessId, processHandle_, dllPath,`r`n`t`t`t`t`t&hookdllModule_, &hGameModule_, pi.hWnd))`r`n#else`r`n`t`t`t`tif (!mem::injectBy64(currentIndex, pi.dwProcessId, processHandle_, dllPath,`r`n`t`t`t`t`t&hookdllModule_, &hGameModule_, pi.hWnd))`r`n#endif`r`n`t`t`t`t{`r`n`t`t`t`t`t*pReason = util::REASON_INJECT_LIBRARY_FAIL;`r`n`t`t`t`t`treturn false;`r`n`t`t`t`t}", "`t`t`t`t// [SashInjectRetry] injectBy64 into a freshly created client can intermittently fail`r`n`t`t`t`t// (REASON_INJECT_LIBRARY_FAIL) due to a loader race: the remote LoadLibrary runs while the`r`n`t`t`t`t// just-CreateProcessW'd client is still initializing its loader/dependencies and returns NULL.`r`n`t`t`t`t// Retry a few times with a short backoff while the process is alive (fixes intermittent not-opened).`r`n`t`t`t`t{`r`n`t`t`t`t`tbool sashInjOk = false;`r`n`t`t`t`t`tfor (int sashInjTry = 0; sashInjTry < 8; ++sashInjTry)`r`n`t`t`t`t`t{`r`n#if QT_VERSION < QT_VERSION_CHECK(6, 0, 0)`r`n`t`t`t`t`t`tif (mem::injectByWin7(currentIndex, pi.dwProcessId, processHandle_, dllPath, &hookdllModule_, &hGameModule_, pi.hWnd)) { sashInjOk = true; break; }`r`n#else`r`n`t`t`t`t`t`tif (mem::injectBy64(currentIndex, pi.dwProcessId, processHandle_, dllPath, &hookdllModule_, &hGameModule_, pi.hWnd)) { sashInjOk = true; break; }`r`n#endif`r`n`t`t`t`t`t`tif (!mem::isProcessExist(pi.dwProcessId)) break;`r`n`t`t`t`t`t`tQThread::msleep(150);`r`n`t`t`t`t`t}`r`n`t`t`t`t`tif (!sashInjOk)`r`n`t`t`t`t`t{`r`n`t`t`t`t`t`t*pReason = util::REASON_INJECT_LIBRARY_FAIL;`r`n`t`t`t`t`t`treturn false;`r`n`t`t`t`t`t}`r`n`t`t`t`t}")
  if ($gc -notmatch 'SashInjectRetry') { throw "gamedevice.cpp inject-retry patch failed." }
  Good 'applied gamedevice.cpp inject retry (intermittent not-opened fix)'
}
if ($gc -notmatch 'SashValidateRetry') {
  if ($gc.IndexOf("`t`t`tif (!processValidation.allowed())") -lt 0) { throw "could not locate validate anchor." }
  $gc = $gc.Replace("`t`t`tconst auto processValidation = sash::client_executable::validateRunningProcess(`r`n`t`t`t`tsash::client_executable::client05(), currentGameExePath,`r`n`t`t`t`tstatic_cast<DWORD>(pi.dwProcessId));`r`n`t`t`tif (!processValidation.allowed())`r`n`t`t`t{`r`n`t`t`t`t*pReason = util::REASON_INJECT_LIBRARY_FAIL;`r`n`t`t`t`treturn false;`r`n`t`t`t}", "`t`t`t// [SashValidateRetry] validateRunningProcess snapshots the fresh client's module list via`r`n`t`t`t// CreateToolhelp32Snapshot(TH32CS_SNAPMODULE), which intermittently fails (ERROR_BAD_LENGTH)`r`n`t`t`t// while the just-created process is still loading its modules -> REASON_INJECT_LIBRARY_FAIL`r`n`t`t`t// BEFORE injection even starts (no inject-OK logged). Retry with backoff while alive.`r`n`t`t`t{`r`n`t`t`t`tbool sashValOk = false;`r`n`t`t`t`tfor (int sashValTry = 0; sashValTry < 10; ++sashValTry)`r`n`t`t`t`t{`r`n`t`t`t`t`tconst auto processValidation = sash::client_executable::validateRunningProcess(`r`n`t`t`t`t`t`tsash::client_executable::client05(), currentGameExePath,`r`n`t`t`t`t`t`tstatic_cast<DWORD>(pi.dwProcessId));`r`n`t`t`t`t`tif (processValidation.allowed()) { sashValOk = true; break; }`r`n`t`t`t`t`tif (!mem::isProcessExist(pi.dwProcessId)) break;`r`n`t`t`t`t`tQThread::msleep(100);`r`n`t`t`t`t}`r`n`t`t`t`tif (!sashValOk)`r`n`t`t`t`t{`r`n`t`t`t`t`t*pReason = util::REASON_INJECT_LIBRARY_FAIL;`r`n`t`t`t`t`treturn false;`r`n`t`t`t`t}`r`n`t`t`t}")
  if ($gc -notmatch 'SashValidateRetry') { throw "gamedevice.cpp validate-retry patch failed." }
  Good 'applied gamedevice.cpp validateRunningProcess retry (module-snapshot race fix)'
}
if ($gc -notmatch 'SashInitReasonReset') {
  if ($gc.IndexOf("`t`t`t`tif (remoteInitializeClient05B1(pi, port, pReason))") -lt 0) { throw "could not locate init-retry success anchor." }
  $gc = $gc.Replace("`t`t`t`tif (remoteInitializeClient05B1(pi, port, pReason))`r`n`t`t`t`t`treturn true;`r`n#else`r`n`t`t`t`tif (remoteInitializeClient05ReadOnly(pi, port, pReason))`r`n`t`t`t`t`treturn true;", "`t`t`t`tif (remoteInitializeClient05B1(pi, port, pReason))`r`n`t`t`t`t{`r`n`t`t`t`t`t// [SashInitReasonReset] the 3x init retry loop leaks a prior attempt's error: remoteInitialize*`r`n`t`t`t`t`t// sets *pReason=REASON_INJECT_LIBRARY_FAIL on failure but does NOT clear it on success. So if`r`n`t`t`t`t`t// attempt 0 failed (cold-start race) and a later attempt SUCCEEDS, *pReason is still 26, and`r`n`t`t`t`t`t// mainthread's (remove_thread_reason != NO_ERROR) check then DISCARDS the successfully-opened`r`n`t`t`t`t`t// client (intermittent not-opened: log shows 'B1 bootstrap delivered' then 'reason 26'). Clear it.`r`n`t`t`t`t`t*pReason = util::REASON_NO_ERROR;`r`n`t`t`t`t`treturn true;`r`n`t`t`t`t}`r`n#else`r`n`t`t`t`tif (remoteInitializeClient05ReadOnly(pi, port, pReason))`r`n`t`t`t`t{`r`n`t`t`t`t`t*pReason = util::REASON_NO_ERROR;`r`n`t`t`t`t`treturn true;`r`n`t`t`t`t}")
  if ($gc -notmatch 'SashInitReasonReset') { throw "gamedevice.cpp init reason-reset patch failed." }
  Good 'applied init-retry reason reset (intermittent not-opened false-fail fix)'
}
if ($gc -notmatch 'setClient05ShowExpRequested') {
  $showExpDef = @'
void GameDevice::setClient05ShowExpRequested(bool enable) noexcept
{
	if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
		return;
	InterlockedExchange(&client05ReadOnlyChannel_->showExpRequested, enable ? TRUE : FALSE);
}

bool GameDevice::publishClient05B1BattleDefendEcho(const std::uint32_t deadlineMilliseconds) noexcept
'@
  $gc = $gc.Replace("bool GameDevice::publishClient05B1BattleDefendEcho(const std::uint32_t deadlineMilliseconds) noexcept", $showExpDef)
  if ($gc -notmatch 'setClient05ShowExpRequested') { throw "showexp def patch failed." }
  Good 'applied showexp setter def'
}
if ($gc -notmatch 'setClient05NormalMagicHealEnable') {
  $nmhDef = @'
void GameDevice::setClient05NormalMagicHealEnable(int value) noexcept
{
	if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
		return;
	InterlockedExchange(&client05ReadOnlyChannel_->normalMagicHealEnable, static_cast<LONG>(value));
}

void GameDevice::setClient05NormalMagicHealChar(int value) noexcept
{
	if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
		return;
	InterlockedExchange(&client05ReadOnlyChannel_->normalMagicHealChar, static_cast<LONG>(value));
}

void GameDevice::setClient05NormalMagicHealMagic(int value) noexcept
{
	if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
		return;
	InterlockedExchange(&client05ReadOnlyChannel_->normalMagicHealMagic, static_cast<LONG>(value));
}

void GameDevice::setClient05NormalMagicHealPet(int value) noexcept
{
	if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
		return;
	InterlockedExchange(&client05ReadOnlyChannel_->normalMagicHealPet, static_cast<LONG>(value));
}

void GameDevice::setClient05NormalMagicHealAllie(int value) noexcept
{
	if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
		return;
	InterlockedExchange(&client05ReadOnlyChannel_->normalMagicHealAllie, static_cast<LONG>(value));
}

void GameDevice::setClient05NormalItemHealMpEnable(int value) noexcept
{
	if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
		return;
	InterlockedExchange(&client05ReadOnlyChannel_->normalItemHealMpEnable, static_cast<LONG>(value));
}

void GameDevice::setClient05NormalItemHealMpValue(int value) noexcept
{
	if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
		return;
	InterlockedExchange(&client05ReadOnlyChannel_->normalItemHealMpValue, static_cast<LONG>(value));
}

void GameDevice::setClient05BattleFallEscape(bool enable) noexcept
'@
  $gc = $gc.Replace("void GameDevice::setClient05BattleFallEscape(bool enable) noexcept", $nmhDef)
  if ($gc -notmatch 'setClient05NormalMagicHealEnable') { throw "normal magic-heal setter def patch failed." }
  Good 'applied normal magic-heal setter defs'
}
if ($gc -notmatch 'setClient05FastBattleRequested') {
  $fbDef = @'
void GameDevice::setClient05FastBattleRequested(int value) noexcept
{
	if (currentClientProfileKind_ != sash::client_executable::Kind::client05 || client05ReadOnlyChannel_ == nullptr)
		return;
	InterlockedExchange(&client05ReadOnlyChannel_->fastBattleRequested, static_cast<LONG>(value));
}

void GameDevice::setClient05AutoWalkDelay(int value) noexcept
'@
  $gc = $gc.Replace("void GameDevice::setClient05AutoWalkDelay(int value) noexcept", $fbDef)
  if ($gc -notmatch 'setClient05FastBattleRequested') { throw "gamedevice.cpp fastBattle def failed." }
  Good 'applied gamedevice.cpp fastBattle def'
}
[IO.File]::WriteAllText($gdc, $gc, $utf8bom)

# ---- mainthread.cpp : auto-login trigger + mute trigger (Client05 B1 loop) ----
$m = [IO.File]::ReadAllText($mth)
if ($m -notmatch 'requestClient05AutoLogin') {
  $alRep = @'
{
			static int s_alIter = 0; static int s_alCount = 0; static unsigned s_prevProc = 0xFFFFu;
			const unsigned curProc = static_cast<unsigned>(snapshot->procNo);
			const bool atLogin = (curProc == 1u);
			if (atLogin && s_prevProc != 1u) { s_alCount = 0; s_alIter = 0; const bool alEdge = gamedevice.getEnableHash(util::kAutoLoginEnable); QFile pef("D:/SA/zmffk/pos-diag.log"); if (pef.open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text)) { pef.write(QByteArray("LOGINSCR edge proc=1 alEnabled=") + QByteArray::number(alEdge ? 1 : 0) + " pos=" + QByteArray::number(static_cast<int>(gamedevice.getValueHash(util::kPositionValue))) + "\r\n"); pef.close(); } }
			if (gamedevice.getEnableHash(util::kAutoLoginEnable) && atLogin) {
				if (s_alCount < 20 && (s_alIter % 8) == 0) {
					const QByteArray acc = gamedevice.getStringHash(util::kGameAccountString).toUtf8();
					const QByteArray pwd = gamedevice.getStringHash(util::kGamePasswordString).toUtf8();
					if (!acc.isEmpty()) {
						const int srv = static_cast<int>(gamedevice.getValueHash(util::kServerValue));
						const int sub = static_cast<int>(gamedevice.getValueHash(util::kSubServerValue));
						const int chr = static_cast<int>(gamedevice.getValueHash(util::kPositionValue));
						{ QFile pdf("D:/SA/zmffk/pos-diag.log"); if (pdf.open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text)) { pdf.write(QByteArray("AUTOLOGIN srv=") + QByteArray::number(srv) + " sub=" + QByteArray::number(sub) + " chr=" + QByteArray::number(chr) + " proc=" + QByteArray::number(static_cast<int>(snapshot->procNo)) + " iter=" + QByteArray::number(s_alIter) + " cnt=" + QByteArray::number(s_alCount) + "\r\n"); pdf.close(); } }
						gamedevice.requestClient05AutoLogin(acc, pwd, srv, sub, chr);
						++s_alCount;
					}
				}
				++s_alIter;
			} else if (!atLogin) { s_alCount = 0; s_alIter = 0; }
			s_prevProc = curProc;
		}
		{ static int s_lastMute = -1; const bool muteOn = gamedevice.getEnableHash(util::kMuteEnable); if (static_cast<int>(muteOn) != s_lastMute) { s_lastMute = static_cast<int>(muteOn); gamedevice.setClient05MuteRequested(muteOn); } }
		QThread::msleep(200u);
'@
  $mrx = [regex]'(?s)// C8 stops at ordered inbound parsing.*?QThread::msleep\(200u\);'
  if (-not $mrx.IsMatch($m)) { throw "could not locate B1 adapter loop anchor." }
  $m = $mrx.Replace($m, $alRep, 1)
  if ($m -notmatch 'setClient05MuteRequested') { throw "mainthread mute-trigger patch failed." }
  Good 'applied auto-login + mute triggers'
}
if ($m -notmatch 'Client05SessionReapply') {
  if ($m.IndexOf("long lastSnapshotSequence = -1L;`r`n`tauto snapshot = std::make_unique<sash::client05_readonly::Snapshot>();") -lt 0) { throw "could not locate reapply anchor." }
  $m = $m.Replace("long lastSnapshotSequence = -1L;`r`n`tauto snapshot = std::make_unique<sash::client05_readonly::Snapshot>();", "long lastSnapshotSequence = -1L;`r`n`tauto snapshot = std::make_unique<sash::client05_readonly::Snapshot>();`r`n`t// [Client05SessionReapply] auto-restart fix: a restarted client is a NEW process, so`r`n`t// GameDevice::createChannel() rebuilds a FRESH channel with default values. The loop's`r`n`t// function-local static edge-detectors persist for the whole launcher process and would`r`n`t// NOT re-push (they still hold last session values), leaving the new client with no`r`n`t// settings applied. Re-apply ALL current settings ONCE per session entry so the fresh`r`n`t// channel is populated; the in-loop edge-detectors then handle mid-session toggles as before.`r`n`t{`r`n`t`tgamedevice.setClient05MuteRequested(gamedevice.getEnableHash(util::kMuteEnable));`r`n`t`tgamedevice.setClient05BoostRequested(static_cast<int>(gamedevice.getValueHash(util::kSpeedBoostValue)));`r`n`t`tgamedevice.setClient05AutoLoginRequested(gamedevice.getEnableHash(util::kAutoLoginEnable) ? 1 : 0);`r`n`t`tgamedevice.setClient05ReconnectRequested(gamedevice.getEnableHash(util::kAutoReconnectEnable) ? 1 : 0);`r`n`t`tgamedevice.setClient05FastWalkRequested(gamedevice.getEnableHash(util::kFastWalkEnable));`r`n`t`tgamedevice.setClient05TimeLockRequested(gamedevice.getEnableHash(util::kLockTimeEnable) ? static_cast<int>(gamedevice.getValueHash(util::kLockTimeValue)) : -1);`r`n`t`tgamedevice.setClient05LockMoveRequested(gamedevice.getEnableHash(util::kLockMoveEnable) ? 1 : 0);`r`n`t`tgamedevice.setClient05PassWallRequested(gamedevice.getEnableHash(util::kPassWallEnable));`r`n`t`tgamedevice.setClient05AutoWalkRequested(gamedevice.getEnableHash(util::kAutoWalkEnable));`r`n`t`tgamedevice.setClient05AutoWalkDistance(static_cast<int>(gamedevice.getValueHash(util::kAutoWalkDistanceValue)));`r`n`t`tgamedevice.setClient05AutoWalkDirection(static_cast<int>(gamedevice.getValueHash(util::kAutoWalkDirectionValue)));`r`n`t`tgamedevice.setClient05AutoWalkDelay(static_cast<int>(gamedevice.getValueHash(util::kAutoWalkDelayValue)));`r`n`t`tgamedevice.setClient05FastAutoWalkRequested(gamedevice.getEnableHash(util::kFastAutoWalkEnable));`r`n`t`tgamedevice.setClient05AutoEscapeRequested(gamedevice.getEnableHash(util::kAutoEscapeEnable));`r`n`t`tgamedevice.setClient05AutoBattleRequested(gamedevice.getEnableHash(util::kAutoBattleEnable));`r`n`t`tgamedevice.setClient05BattleCharActionType(static_cast<int>(gamedevice.getValueHash(util::kBattleCharNormalActionTypeValue)));`r`n`t`tgamedevice.setClient05BattleCharActionTarget(static_cast<int>(gamedevice.getValueHash(util::kBattleCharNormalActionTargetValue)));`r`n`t`tgamedevice.setClient05BattlePetActionType(static_cast<int>(gamedevice.getValueHash(util::kBattlePetNormalActionTypeValue)));`r`n`t`tgamedevice.setClient05BattlePetActionTarget(static_cast<int>(gamedevice.getValueHash(util::kBattlePetNormalActionTargetValue)));`r`n`t`tgamedevice.setClient05BattleCharActionEnemy(static_cast<int>(gamedevice.getValueHash(util::kBattleCharNormalActionEnemyValue)));`r`n`t`tgamedevice.setClient05BattleCharActionLevel(static_cast<int>(gamedevice.getValueHash(util::kBattleCharNormalActionLevelValue)));`r`n`t}")
  if ($m -notmatch 'Client05SessionReapply') { throw "mainthread session-reapply patch failed." }
  Good 'applied mainthread session re-apply (auto-restart fix)'
}
if ($m -notmatch 's_lastBoost') {
  $m = $m.Replace("gamedevice.setClient05MuteRequested(muteOn); } }", "gamedevice.setClient05MuteRequested(muteOn); } }`r`n`t`t`t{ static long long s_lastBoost = -1; const long long boostVal = gamedevice.getValueHash(util::kSpeedBoostValue); if (boostVal != s_lastBoost) { s_lastBoost = boostVal; gamedevice.setClient05BoostRequested(static_cast<int>(boostVal)); } }")
  if ($m -notmatch 's_lastBoost') { throw "mainthread boost-trigger patch failed." }
  Good 'applied mainthread boost trigger'
}
if ($m -notmatch 's_lastAl') {
  $m = $m.Replace("gamedevice.setClient05BoostRequested(static_cast<int>(boostVal)); } }", "gamedevice.setClient05BoostRequested(static_cast<int>(boostVal)); } }`r`n`t`t`t{ static int s_lastAl = -2; const int alOn = gamedevice.getEnableHash(util::kAutoLoginEnable) ? 1 : 0; if (alOn != s_lastAl) { s_lastAl = alOn; gamedevice.setClient05AutoLoginRequested(alOn); } }`r`n`t`t`t{ static int s_lastRc = -2; const int rcOn = gamedevice.getEnableHash(util::kAutoReconnectEnable) ? 1 : 0; if (rcOn != s_lastRc) { s_lastRc = rcOn; gamedevice.setClient05ReconnectRequested(rcOn); } }")
  if ($m -notmatch 's_lastAl') { throw "mainthread autologin-trigger patch failed." }
  Good 'applied mainthread autologin trigger'
}
if ($m -notmatch 's_lastFw') {
  $m = $m.Replace("gamedevice.setClient05ReconnectRequested(rcOn); } }", "gamedevice.setClient05ReconnectRequested(rcOn); } }`r`n`t`t`t{ static int s_lastFw = -2; const int fwOn = gamedevice.getEnableHash(util::kFastWalkEnable) ? 1 : 0; if (fwOn != s_lastFw) { s_lastFw = fwOn; gamedevice.setClient05FastWalkRequested(fwOn != 0); } }")
  if ($m -notmatch 's_lastFw') { throw "mainthread fastwalk-trigger patch failed." }
  Good 'applied mainthread fastwalk trigger'
}
if ($m -notmatch 's_lastTl') {
  $m = $m.Replace("gamedevice.setClient05FastWalkRequested(fwOn != 0); } }", "gamedevice.setClient05FastWalkRequested(fwOn != 0); } }`r`n`t`t`t{ static int s_lastTl = -99; const int tlOn = gamedevice.getEnableHash(util::kLockTimeEnable) ? static_cast<int>(gamedevice.getValueHash(util::kLockTimeValue)) : -1; if (tlOn != s_lastTl) { s_lastTl = tlOn; gamedevice.setClient05TimeLockRequested(tlOn); } }")
  if ($m -notmatch 's_lastTl') { throw "mainthread timelock-trigger patch failed." }
  Good 'applied mainthread timelock trigger'
}
if ($m -notmatch 's_lastLm') {
  $m = $m.Replace("gamedevice.setClient05TimeLockRequested(tlOn); } }", "gamedevice.setClient05TimeLockRequested(tlOn); } }`r`n`t`t`t{ static int s_lastLm = -2; const int lmOn = gamedevice.getEnableHash(util::kLockMoveEnable) ? 1 : 0; if (lmOn != s_lastLm) { s_lastLm = lmOn; gamedevice.setClient05LockMoveRequested(lmOn); } }")
  if ($m -notmatch 's_lastLm') { throw "mainthread lockmove-trigger patch failed." }
  Good 'applied mainthread lockmove trigger'
}
if ($m -notmatch 's_lastPw') {
  $m = $m.Replace("gamedevice.setClient05LockMoveRequested(lmOn); } }", "gamedevice.setClient05LockMoveRequested(lmOn); } }`r`n`t`t`t{ static int s_lastPw = -2; const int pwOn = gamedevice.getEnableHash(util::kPassWallEnable) ? 1 : 0; if (pwOn != s_lastPw) { s_lastPw = pwOn; gamedevice.setClient05PassWallRequested(pwOn != 0); } }")
  if ($m -notmatch 's_lastPw') { throw "mainthread passwall-trigger patch failed." }
  Good 'applied mainthread passwall trigger'
}
if ($m -notmatch 's_lastAw') {
  $m = $m.Replace("gamedevice.setClient05PassWallRequested(pwOn != 0); } }", "gamedevice.setClient05PassWallRequested(pwOn != 0); } }`r`n`t`t`t{ static int s_lastAw = -2; const int awOn = gamedevice.getEnableHash(util::kAutoWalkEnable) ? 1 : 0; if (awOn != s_lastAw) { s_lastAw = awOn; gamedevice.setClient05AutoWalkRequested(awOn != 0); } }`r`n`t`t`t{ static long long s_lastAwd = -999; const long long v = gamedevice.getValueHash(util::kAutoWalkDistanceValue); if (v != s_lastAwd) { s_lastAwd = v; gamedevice.setClient05AutoWalkDistance(static_cast<int>(v)); } }`r`n`t`t`t{ static long long s_lastAwdir = -999; const long long v = gamedevice.getValueHash(util::kAutoWalkDirectionValue); if (v != s_lastAwdir) { s_lastAwdir = v; gamedevice.setClient05AutoWalkDirection(static_cast<int>(v)); } }`r`n`t`t`t{ static long long s_lastAwdl = -999; const long long v = gamedevice.getValueHash(util::kAutoWalkDelayValue); if (v != s_lastAwdl) { s_lastAwdl = v; gamedevice.setClient05AutoWalkDelay(static_cast<int>(v)); } }")
  if ($m -notmatch 's_lastAw') { throw "mainthread autowalk-trigger patch failed." }
  Good 'applied mainthread autowalk trigger (走路遇敵 enable + distance/direction for W2 re-port)'
}
if ($m -notmatch 's_lastFa') {
  $m = $m.Replace("gamedevice.setClient05AutoWalkRequested(awOn != 0); } }", "gamedevice.setClient05AutoWalkRequested(awOn != 0); } }`r`n`t`t`t{ static int s_lastFa = -2; const int faOn = gamedevice.getEnableHash(util::kFastAutoWalkEnable) ? 1 : 0; if (faOn != s_lastFa) { s_lastFa = faOn; gamedevice.setClient05FastAutoWalkRequested(faOn != 0); } }")
  if ($m -notmatch 's_lastFa') { throw "mainthread fastautowalk-trigger patch failed." }
  Good 'applied mainthread fastautowalk trigger (快速遇敵 enable flag, boost-style)'
}
if ($m -notmatch 's_lastAe') {
  $m = $m.Replace("gamedevice.setClient05FastAutoWalkRequested(faOn != 0); } }", "gamedevice.setClient05FastAutoWalkRequested(faOn != 0); } }`r`n`t`t`t{ static int s_lastAe = -2; const int aeOn = gamedevice.getEnableHash(util::kAutoEscapeEnable) ? 1 : 0; if (aeOn != s_lastAe) { s_lastAe = aeOn; gamedevice.setClient05AutoEscapeRequested(aeOn != 0); } }")
  if ($m -notmatch 's_lastAe') { throw "mainthread autoescape-trigger patch failed." }
  Good 'applied mainthread autoescape trigger (自動逃跑 enable flag)'
}
if ($m -notmatch 's_lastAb') {
  $m = $m.Replace("gamedevice.setClient05AutoEscapeRequested(aeOn != 0); } }", "gamedevice.setClient05AutoEscapeRequested(aeOn != 0); } }`r`n`t`t`t{ static int s_lastAb = -2; const int abOn = gamedevice.getEnableHash(util::kAutoBattleEnable) ? 1 : 0; if (abOn != s_lastAb) { s_lastAb = abOn; gamedevice.setClient05AutoBattleRequested(abOn != 0); } }`r`n`t`t`t{ static long long s_lastBct = -999; const long long v = gamedevice.getValueHash(util::kBattleCharNormalActionTypeValue); if (v != s_lastBct) { s_lastBct = v; gamedevice.setClient05BattleCharActionType(static_cast<int>(v)); } }`r`n`t`t`t{ static long long s_lastBctg = -999; const long long v = gamedevice.getValueHash(util::kBattleCharNormalActionTargetValue); if (v != s_lastBctg) { s_lastBctg = v; gamedevice.setClient05BattleCharActionTarget(static_cast<int>(v)); } }`r`n`t`t`t{ static long long s_lastBpt = -999; const long long v = gamedevice.getValueHash(util::kBattlePetNormalActionTypeValue); if (v != s_lastBpt) { s_lastBpt = v; gamedevice.setClient05BattlePetActionType(static_cast<int>(v)); } }`r`n`t`t`t{ static long long s_lastBptg = -999; const long long v = gamedevice.getValueHash(util::kBattlePetNormalActionTargetValue); if (v != s_lastBptg) { s_lastBptg = v; gamedevice.setClient05BattlePetActionTarget(static_cast<int>(v)); } }`r`n`t`t`t{ static long long s_lastBce = -999; const long long v = gamedevice.getValueHash(util::kBattleCharNormalActionEnemyValue); if (v != s_lastBce) { s_lastBce = v; gamedevice.setClient05BattleCharActionEnemy(static_cast<int>(v)); } }`r`n`t`t`t{ static long long s_lastBcl = -999; const long long v = gamedevice.getValueHash(util::kBattleCharNormalActionLevelValue); if (v != s_lastBcl) { s_lastBcl = v; gamedevice.setClient05BattleCharActionLevel(static_cast<int>(v)); } }")
  if ($m -notmatch 's_lastAb') { throw "mainthread autobattle-trigger patch failed." }
  Good 'applied mainthread autobattle triggers (enable + char/pet action type/target)'
}
if ($m -notmatch 'baRoundReapply') {
  $m = $m.Replace("gamedevice.setClient05BattleCharActionLevel(static_cast<int>(gamedevice.getValueHash(util::kBattleCharNormalActionLevelValue)));`r`n`t}", "gamedevice.setClient05BattleCharActionLevel(static_cast<int>(gamedevice.getValueHash(util::kBattleCharNormalActionLevelValue)));`r`n`t`t/* baRoundReapply: char round/cross/delay rows re-applied once per session entry */`r`n`t`tgamedevice.setClient05BattleCharRoundRound(static_cast<int>(gamedevice.getValueHash(util::kBattleCharRoundActionRoundValue)));`r`n`t`tgamedevice.setClient05BattleCharRoundEnemy(static_cast<int>(gamedevice.getValueHash(util::kBattleCharRoundActionEnemyValue)));`r`n`t`tgamedevice.setClient05BattleCharRoundLevel(static_cast<int>(gamedevice.getValueHash(util::kBattleCharRoundActionLevelValue)));`r`n`t`tgamedevice.setClient05BattleCharRoundType(static_cast<int>(gamedevice.getValueHash(util::kBattleCharRoundActionTypeValue)));`r`n`t`tgamedevice.setClient05BattleCharRoundTarget(static_cast<int>(gamedevice.getValueHash(util::kBattleCharRoundActionTargetValue)));`r`n`t`tgamedevice.setClient05BattleCharCrossEnable(gamedevice.getEnableHash(util::kBattleCrossActionCharEnable) ? 1 : 0);`r`n`t`tgamedevice.setClient05BattleCharCrossRound(static_cast<int>(gamedevice.getValueHash(util::kBattleCharCrossActionRoundValue)));`r`n`t`tgamedevice.setClient05BattleCharCrossType(static_cast<int>(gamedevice.getValueHash(util::kBattleCharCrossActionTypeValue)));`r`n`t`tgamedevice.setClient05BattleCharCrossTarget(static_cast<int>(gamedevice.getValueHash(util::kBattleCharCrossActionTargetValue)));`r`n`t`tgamedevice.setClient05BattleActionDelay(static_cast<int>(gamedevice.getValueHash(util::kBattleActionDelayValue)));`r`n`t}")
  if ($m -notmatch 'baRoundReapply') { throw "mainthread round/cross reapply patch failed." }
  Good 'applied mainthread round/cross/delay session-reapply'
}
if ($m -notmatch 'baPetReapply') {
  $m = $m.Replace("gamedevice.setClient05BattleActionDelay(static_cast<int>(gamedevice.getValueHash(util::kBattleActionDelayValue)));`r`n`t}", "gamedevice.setClient05BattleActionDelay(static_cast<int>(gamedevice.getValueHash(util::kBattleActionDelayValue)));`r`n`t`t/* baPetReapply: pet round/cross rows re-applied once per session entry */`r`n`t`tgamedevice.setClient05BattlePetRoundRound(static_cast<int>(gamedevice.getValueHash(util::kBattlePetRoundActionRoundValue)));`r`n`t`tgamedevice.setClient05BattlePetRoundEnemy(static_cast<int>(gamedevice.getValueHash(util::kBattlePetRoundActionEnemyValue)));`r`n`t`tgamedevice.setClient05BattlePetRoundLevel(static_cast<int>(gamedevice.getValueHash(util::kBattlePetRoundActionLevelValue)));`r`n`t`tgamedevice.setClient05BattlePetRoundType(static_cast<int>(gamedevice.getValueHash(util::kBattlePetRoundActionTypeValue)));`r`n`t`tgamedevice.setClient05BattlePetRoundTarget(static_cast<int>(gamedevice.getValueHash(util::kBattlePetRoundActionTargetValue)));`r`n`t`tgamedevice.setClient05BattlePetCrossEnable(gamedevice.getEnableHash(util::kBattleCrossActionPetEnable) ? 1 : 0);`r`n`t`tgamedevice.setClient05BattlePetCrossRound(static_cast<int>(gamedevice.getValueHash(util::kBattlePetCrossActionRoundValue)));`r`n`t`tgamedevice.setClient05BattlePetCrossType(static_cast<int>(gamedevice.getValueHash(util::kBattlePetCrossActionTypeValue)));`r`n`t`tgamedevice.setClient05BattlePetCrossTarget(static_cast<int>(gamedevice.getValueHash(util::kBattlePetCrossActionTargetValue)));`r`n`t}")
  if ($m -notmatch 'baPetReapply') { throw "mainthread pet reapply patch failed." }
  Good 'applied mainthread pet round/cross session-reapply'
}
if ($m -notmatch 'baRoundEdge') {
  $m = $m.Replace("{ static long long s_lastBcl = -999; const long long v = gamedevice.getValueHash(util::kBattleCharNormalActionLevelValue); if (v != s_lastBcl) { s_lastBcl = v; gamedevice.setClient05BattleCharActionLevel(static_cast<int>(v)); } }", "{ static long long s_lastBcl = -999; const long long v = gamedevice.getValueHash(util::kBattleCharNormalActionLevelValue); if (v != s_lastBcl) { s_lastBcl = v; gamedevice.setClient05BattleCharActionLevel(static_cast<int>(v)); } }`r`n`t`t`t/* baRoundEdge: char round/cross/delay mid-session change detectors */`r`n`t`t`t{ static long long s_lastCrr = -999; const long long v = gamedevice.getValueHash(util::kBattleCharRoundActionRoundValue); if (v != s_lastCrr) { s_lastCrr = v; gamedevice.setClient05BattleCharRoundRound(static_cast<int>(v)); } }`r`n`t`t`t{ static long long s_lastCre = -999; const long long v = gamedevice.getValueHash(util::kBattleCharRoundActionEnemyValue); if (v != s_lastCre) { s_lastCre = v; gamedevice.setClient05BattleCharRoundEnemy(static_cast<int>(v)); } }`r`n`t`t`t{ static long long s_lastCrl = -999; const long long v = gamedevice.getValueHash(util::kBattleCharRoundActionLevelValue); if (v != s_lastCrl) { s_lastCrl = v; gamedevice.setClient05BattleCharRoundLevel(static_cast<int>(v)); } }`r`n`t`t`t{ static long long s_lastCrt = -999; const long long v = gamedevice.getValueHash(util::kBattleCharRoundActionTypeValue); if (v != s_lastCrt) { s_lastCrt = v; gamedevice.setClient05BattleCharRoundType(static_cast<int>(v)); } }`r`n`t`t`t{ static long long s_lastCrtg = -999; const long long v = gamedevice.getValueHash(util::kBattleCharRoundActionTargetValue); if (v != s_lastCrtg) { s_lastCrtg = v; gamedevice.setClient05BattleCharRoundTarget(static_cast<int>(v)); } }`r`n`t`t`t{ static int s_lastCce = -2; const int cceOn = gamedevice.getEnableHash(util::kBattleCrossActionCharEnable) ? 1 : 0; if (cceOn != s_lastCce) { s_lastCce = cceOn; gamedevice.setClient05BattleCharCrossEnable(cceOn); } }`r`n`t`t`t{ static long long s_lastCcr = -999; const long long v = gamedevice.getValueHash(util::kBattleCharCrossActionRoundValue); if (v != s_lastCcr) { s_lastCcr = v; gamedevice.setClient05BattleCharCrossRound(static_cast<int>(v)); } }`r`n`t`t`t{ static long long s_lastCct = -999; const long long v = gamedevice.getValueHash(util::kBattleCharCrossActionTypeValue); if (v != s_lastCct) { s_lastCct = v; gamedevice.setClient05BattleCharCrossType(static_cast<int>(v)); } }`r`n`t`t`t{ static long long s_lastCctg = -999; const long long v = gamedevice.getValueHash(util::kBattleCharCrossActionTargetValue); if (v != s_lastCctg) { s_lastCctg = v; gamedevice.setClient05BattleCharCrossTarget(static_cast<int>(v)); } }`r`n`t`t`t{ static long long s_lastDly = -999; const long long v = gamedevice.getValueHash(util::kBattleActionDelayValue); if (v != s_lastDly) { s_lastDly = v; gamedevice.setClient05BattleActionDelay(static_cast<int>(v)); } }")
  if ($m -notmatch 'baRoundEdge') { throw "mainthread round/cross edge-detect patch failed." }
  Good 'applied mainthread round/cross/delay edge detectors'
}
if ($m -notmatch 'baPetEdge') {
  $m = $m.Replace("{ static long long s_lastDly = -999; const long long v = gamedevice.getValueHash(util::kBattleActionDelayValue); if (v != s_lastDly) { s_lastDly = v; gamedevice.setClient05BattleActionDelay(static_cast<int>(v)); } }", "{ static long long s_lastDly = -999; const long long v = gamedevice.getValueHash(util::kBattleActionDelayValue); if (v != s_lastDly) { s_lastDly = v; gamedevice.setClient05BattleActionDelay(static_cast<int>(v)); } }`r`n`t`t`t/* baPetEdge: pet round/cross mid-session change detectors */`r`n`t`t`t{ static long long s_lastPrr = -999; const long long v = gamedevice.getValueHash(util::kBattlePetRoundActionRoundValue); if (v != s_lastPrr) { s_lastPrr = v; gamedevice.setClient05BattlePetRoundRound(static_cast<int>(v)); } }`r`n`t`t`t{ static long long s_lastPre = -999; const long long v = gamedevice.getValueHash(util::kBattlePetRoundActionEnemyValue); if (v != s_lastPre) { s_lastPre = v; gamedevice.setClient05BattlePetRoundEnemy(static_cast<int>(v)); } }`r`n`t`t`t{ static long long s_lastPrl = -999; const long long v = gamedevice.getValueHash(util::kBattlePetRoundActionLevelValue); if (v != s_lastPrl) { s_lastPrl = v; gamedevice.setClient05BattlePetRoundLevel(static_cast<int>(v)); } }`r`n`t`t`t{ static long long s_lastPrt = -999; const long long v = gamedevice.getValueHash(util::kBattlePetRoundActionTypeValue); if (v != s_lastPrt) { s_lastPrt = v; gamedevice.setClient05BattlePetRoundType(static_cast<int>(v)); } }`r`n`t`t`t{ static long long s_lastPrtg = -999; const long long v = gamedevice.getValueHash(util::kBattlePetRoundActionTargetValue); if (v != s_lastPrtg) { s_lastPrtg = v; gamedevice.setClient05BattlePetRoundTarget(static_cast<int>(v)); } }`r`n`t`t`t{ static int s_lastPce = -2; const int on = gamedevice.getEnableHash(util::kBattleCrossActionPetEnable) ? 1 : 0; if (on != s_lastPce) { s_lastPce = on; gamedevice.setClient05BattlePetCrossEnable(on); } }`r`n`t`t`t{ static long long s_lastPcr = -999; const long long v = gamedevice.getValueHash(util::kBattlePetCrossActionRoundValue); if (v != s_lastPcr) { s_lastPcr = v; gamedevice.setClient05BattlePetCrossRound(static_cast<int>(v)); } }`r`n`t`t`t{ static long long s_lastPct = -999; const long long v = gamedevice.getValueHash(util::kBattlePetCrossActionTypeValue); if (v != s_lastPct) { s_lastPct = v; gamedevice.setClient05BattlePetCrossType(static_cast<int>(v)); } }`r`n`t`t`t{ static long long s_lastPctg = -999; const long long v = gamedevice.getValueHash(util::kBattlePetCrossActionTargetValue); if (v != s_lastPctg) { s_lastPctg = v; gamedevice.setClient05BattlePetCrossTarget(static_cast<int>(v)); } }")
  if ($m -notmatch 'baPetEdge') { throw "mainthread pet edge-detect patch failed." }
  Good 'applied mainthread pet round/cross edge detectors'
}
if ($m -notmatch 'KillClientOnLauncherExit') {
  $m = $m.Replace("if (gamedevice.currentClientProfileKind() == sash::client_executable::Kind::client05)`r`n`t`t{`r`n`t`t`tif (CLIENT05_B1 && gamedevice.isClient05B1RequestedAndReady())", "{ /* KillClientOnLauncherExit: assign client to a Job Object with KILL_ON_JOB_CLOSE so the client dies when the launcher process exits (any way), while a Stop button does not kill it. */ static HANDLE s_killJob = nullptr; if (s_killJob == nullptr) { s_killJob = CreateJobObjectW(nullptr, nullptr); if (s_killJob != nullptr) { JOBOBJECT_EXTENDED_LIMIT_INFORMATION jeli = {}; jeli.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE; SetInformationJobObject(s_killJob, static_cast<JOBOBJECTINFOCLASS>(JobObjectExtendedLimitInformation), &jeli, sizeof(jeli)); } } if (s_killJob != nullptr) { HANDLE hCliProc = gamedevice.getProcess(); if (hCliProc != nullptr && hCliProc != INVALID_HANDLE_VALUE) { AssignProcessToJobObject(s_killJob, hCliProc); } } }`r`n`r`n`t`tif (gamedevice.currentClientProfileKind() == sash::client_executable::Kind::client05)`r`n`t`t{`r`n`t`t`tif (CLIENT05_B1 && gamedevice.isClient05B1RequestedAndReady())")
  if ($m -notmatch 'KillClientOnLauncherExit') { throw "kill-client-on-launcher-exit patch failed." }
  Good 'applied kill-client-on-launcher-exit (Job Object)'
}
# NOTE: 走路遇敵 auto-walk is now a PURE MEMORY port driven entirely by the sadll monitor
# (autoWalkRequested flag -> monitor writes goalX/goalY/moveStart). The SaSH MissionThread
# never runs on Client05 B1, so no mission-thread route/diag patches are needed here.
$m = $m.Replace("zmffk/pos-diag.log", "zmffk/pos-diag-$tag.log")
$m = $m.Replace('D:/SA/zmffk', 'C:/zmffk')  # bugC: Qt forward-slash pos-diag/pef path (backslash migration missed it)
if ($m -notmatch 'setClient05ShowExpRequested') {
  $m = $m.Replace("gamedevice.setClient05MuteRequested(gamedevice.getEnableHash(util::kMuteEnable));", "gamedevice.setClient05MuteRequested(gamedevice.getEnableHash(util::kMuteEnable));`r`n`t`tgamedevice.setClient05ShowExpRequested(gamedevice.getEnableHash(util::kShowExpEnable));")
  $m = $m.Replace("{ static long long s_lastBoost = -1; const long long boostVal = gamedevice.getValueHash(util::kSpeedBoostValue); if (boostVal != s_lastBoost) { s_lastBoost = boostVal; gamedevice.setClient05BoostRequested(static_cast<int>(boostVal)); } }", "{ static long long s_lastBoost = -1; const long long boostVal = gamedevice.getValueHash(util::kSpeedBoostValue); if (boostVal != s_lastBoost) { s_lastBoost = boostVal; gamedevice.setClient05BoostRequested(static_cast<int>(boostVal)); } }`r`n`t`t`t{ static int s_lastShowExp = -1; const bool showExpOn = gamedevice.getEnableHash(util::kShowExpEnable); if (static_cast<int>(showExpOn) != s_lastShowExp) { s_lastShowExp = static_cast<int>(showExpOn); gamedevice.setClient05ShowExpRequested(showExpOn); } }")
  if ($m -notmatch 'setClient05ShowExpRequested') { throw "showexp mainthread reapply/edge patch failed." }
  Good 'applied showexp mainthread reapply + edge'
}
if ($m -notmatch 'baMagicHealEdge') {
  $m = $m.Replace("gamedevice.setClient05BattleCharActionLevel(static_cast<int>(gamedevice.getValueHash(util::kBattleCharNormalActionLevelValue)));", "gamedevice.setClient05BattleCharActionLevel(static_cast<int>(gamedevice.getValueHash(util::kBattleCharNormalActionLevelValue)));`r`n`t`tgamedevice.setClient05BattleMagicHealEnable(gamedevice.getEnableHash(util::kBattleMagicHealEnable) ? 1 : 0);`r`n`t`tgamedevice.setClient05BattleMagicHealTarget(static_cast<int>(gamedevice.getValueHash(util::kBattleMagicHealTargetValue)));`r`n`t`tgamedevice.setClient05BattleMagicHealChar(static_cast<int>(gamedevice.getValueHash(util::kBattleMagicHealCharValue)));`r`n`t`tgamedevice.setClient05BattleMagicHealPet(static_cast<int>(gamedevice.getValueHash(util::kBattleMagicHealPetValue)));`r`n`t`tgamedevice.setClient05BattleMagicHealAllie(static_cast<int>(gamedevice.getValueHash(util::kBattleMagicHealAllieValue)));`r`n`t`tgamedevice.setClient05BattleMagicHealMagic(static_cast<int>(gamedevice.getValueHash(util::kBattleMagicHealMagicValue)));`r`n`t`tgamedevice.setClient05BattleSkillMpEnable(gamedevice.getEnableHash(util::kBattleSkillMpEnable) ? 1 : 0);`r`n`t`tgamedevice.setClient05BattleSkillMpValue(static_cast<int>(gamedevice.getValueHash(util::kBattleSkillMpValue)));`r`n`t`tgamedevice.setClient05BattleItemHealMpEnable(gamedevice.getEnableHash(util::kBattleItemHealMpEnable) ? 1 : 0);`r`n`t`tgamedevice.setClient05BattleItemHealMpValue(static_cast<int>(gamedevice.getValueHash(util::kBattleItemHealMpValue)));`r`n`t`tgamedevice.setClient05BattleFallEscape(gamedevice.getEnableHash(util::kFallDownEscapeEnable));")
  $m = $m.Replace("gamedevice.setClient05BattlePetCrossTarget(static_cast<int>(v)); } }", "gamedevice.setClient05BattlePetCrossTarget(static_cast<int>(v)); } }`r`n`t`t`t/* baMagicHealEdge: 마법 회복 설정 mid-session 변경 감지 */`r`n`t`t`t{ static int s_lastMhe = -2; const int on = gamedevice.getEnableHash(util::kBattleMagicHealEnable) ? 1 : 0; if (on != s_lastMhe) { s_lastMhe = on; gamedevice.setClient05BattleMagicHealEnable(on); } }`r`n`t`t`t{ static long long s_lastMht = -999; const long long v = gamedevice.getValueHash(util::kBattleMagicHealTargetValue); if (v != s_lastMht) { s_lastMht = v; gamedevice.setClient05BattleMagicHealTarget(static_cast<int>(v)); } }`r`n`t`t`t{ static long long s_lastMhc = -999; const long long v = gamedevice.getValueHash(util::kBattleMagicHealCharValue); if (v != s_lastMhc) { s_lastMhc = v; gamedevice.setClient05BattleMagicHealChar(static_cast<int>(v)); } }`r`n`t`t`t{ static long long s_lastMhp = -999; const long long v = gamedevice.getValueHash(util::kBattleMagicHealPetValue); if (v != s_lastMhp) { s_lastMhp = v; gamedevice.setClient05BattleMagicHealPet(static_cast<int>(v)); } }`r`n`t`t`t{ static long long s_lastMha = -999; const long long v = gamedevice.getValueHash(util::kBattleMagicHealAllieValue); if (v != s_lastMha) { s_lastMha = v; gamedevice.setClient05BattleMagicHealAllie(static_cast<int>(v)); } }`r`n`t`t`t{ static long long s_lastMhm = -999; const long long v = gamedevice.getValueHash(util::kBattleMagicHealMagicValue); if (v != s_lastMhm) { s_lastMhm = v; gamedevice.setClient05BattleMagicHealMagic(static_cast<int>(v)); } }`r`n`t`t`t{ static int s_lastBsme = -2; const int on = gamedevice.getEnableHash(util::kBattleSkillMpEnable) ? 1 : 0; if (on != s_lastBsme) { s_lastBsme = on; gamedevice.setClient05BattleSkillMpEnable(on); } }`r`n`t`t`t{ static long long s_lastBsmv = -999; const long long v = gamedevice.getValueHash(util::kBattleSkillMpValue); if (v != s_lastBsmv) { s_lastBsmv = v; gamedevice.setClient05BattleSkillMpValue(static_cast<int>(v)); } }`r`n`t`t`t{ static int s_lastBime = -2; const int on = gamedevice.getEnableHash(util::kBattleItemHealMpEnable) ? 1 : 0; if (on != s_lastBime) { s_lastBime = on; gamedevice.setClient05BattleItemHealMpEnable(on); } }`r`n`t`t`t{ static long long s_lastBimv = -999; const long long v = gamedevice.getValueHash(util::kBattleItemHealMpValue); if (v != s_lastBimv) { s_lastBimv = v; gamedevice.setClient05BattleItemHealMpValue(static_cast<int>(v)); } }`r`n`t`t`t{ static int s_lastFe = -2; const int on = gamedevice.getEnableHash(util::kFallDownEscapeEnable) ? 1 : 0; if (on != s_lastFe) { s_lastFe = on; gamedevice.setClient05BattleFallEscape(on != 0); } }")
  if ($m -notmatch 'baMagicHealEdge') { throw "battle magic-heal reapply/edge patch failed." }
  Good 'applied battle magic-heal reapply + edge detectors'
}
if ($m -notmatch 'nmhEdge') {
  # [NormalHeal] mainthread: push kNormalMagicHeal* hashes to client05 channel (init + edge), mirroring battle magic-heal.
  $m = $m.Replace("gamedevice.setClient05BattleMagicHealMagic(static_cast<int>(gamedevice.getValueHash(util::kBattleMagicHealMagicValue)));", "gamedevice.setClient05BattleMagicHealMagic(static_cast<int>(gamedevice.getValueHash(util::kBattleMagicHealMagicValue)));`r`n`t`tgamedevice.setClient05NormalMagicHealEnable(gamedevice.getEnableHash(util::kNormalMagicHealEnable) ? 1 : 0);`r`n`t`tgamedevice.setClient05NormalMagicHealChar(static_cast<int>(gamedevice.getValueHash(util::kNormalMagicHealCharValue)));`r`n`t`tgamedevice.setClient05NormalMagicHealMagic(static_cast<int>(gamedevice.getValueHash(util::kNormalMagicHealMagicValue)));`r`n`t`tgamedevice.setClient05NormalMagicHealPet(static_cast<int>(gamedevice.getValueHash(util::kNormalMagicHealPetValue)));`r`n`t`tgamedevice.setClient05NormalMagicHealAllie(static_cast<int>(gamedevice.getValueHash(util::kNormalMagicHealAllieValue)));`r`n`t`tgamedevice.setClient05NormalItemHealMpEnable(gamedevice.getEnableHash(util::kNormalItemHealMpEnable) ? 1 : 0);`r`n`t`tgamedevice.setClient05NormalItemHealMpValue(static_cast<int>(gamedevice.getValueHash(util::kNormalItemHealMpValue)));")
  $m = $m.Replace("{ static int s_lastFe = -2; const int on = gamedevice.getEnableHash(util::kFallDownEscapeEnable) ? 1 : 0; if (on != s_lastFe) { s_lastFe = on; gamedevice.setClient05BattleFallEscape(on != 0); } }", "{ static int s_lastFe = -2; const int on = gamedevice.getEnableHash(util::kFallDownEscapeEnable) ? 1 : 0; if (on != s_lastFe) { s_lastFe = on; gamedevice.setClient05BattleFallEscape(on != 0); } }`r`n`t`t`t/* nmhEdge: field magic-heal 설정 변경 감지 */`r`n`t`t`t{ static int s_lastNmhe = -2; const int on = gamedevice.getEnableHash(util::kNormalMagicHealEnable) ? 1 : 0; if (on != s_lastNmhe) { s_lastNmhe = on; gamedevice.setClient05NormalMagicHealEnable(on); } }`r`n`t`t`t{ static long long s_lastNmhc = -999; const long long v = gamedevice.getValueHash(util::kNormalMagicHealCharValue); if (v != s_lastNmhc) { s_lastNmhc = v; gamedevice.setClient05NormalMagicHealChar(static_cast<int>(v)); } }`r`n`t`t`t{ static long long s_lastNmhm = -999; const long long v = gamedevice.getValueHash(util::kNormalMagicHealMagicValue); if (v != s_lastNmhm) { s_lastNmhm = v; gamedevice.setClient05NormalMagicHealMagic(static_cast<int>(v)); } }`r`n`t`t`t{ static long long s_lastNmhp = -999; const long long v = gamedevice.getValueHash(util::kNormalMagicHealPetValue); if (v != s_lastNmhp) { s_lastNmhp = v; gamedevice.setClient05NormalMagicHealPet(static_cast<int>(v)); } }`r`n`t`t`t{ static long long s_lastNmha = -999; const long long v = gamedevice.getValueHash(util::kNormalMagicHealAllieValue); if (v != s_lastNmha) { s_lastNmha = v; gamedevice.setClient05NormalMagicHealAllie(static_cast<int>(v)); } }`r`n`t`t`t{ static int s_lastImpE = -2; const int on = gamedevice.getEnableHash(util::kNormalItemHealMpEnable) ? 1 : 0; if (on != s_lastImpE) { s_lastImpE = on; gamedevice.setClient05NormalItemHealMpEnable(on); } }`r`n`t`t`t{ static long long s_lastImpV = -999; const long long v = gamedevice.getValueHash(util::kNormalItemHealMpValue); if (v != s_lastImpV) { s_lastImpV = v; gamedevice.setClient05NormalItemHealMpValue(static_cast<int>(v)); } }")
  if ($m -notmatch 'nmhEdge') { throw "normal magic-heal mainthread patch failed." }
  Good 'applied normal magic-heal mainthread reapply + edge'
}
if ($m -notmatch 'setClient05FastBattleRequested') {
  $m = $m.Replace("gamedevice.setClient05AutoWalkDelay(static_cast<int>(gamedevice.getValueHash(util::kAutoWalkDelayValue)));", "gamedevice.setClient05AutoWalkDelay(static_cast<int>(gamedevice.getValueHash(util::kAutoWalkDelayValue)));`r`n`t`tgamedevice.setClient05FastBattleRequested(gamedevice.getEnableHash(util::kFastBattleEnable) ? 1 : 0);")
  $m = $m.Replace("{ static long long s_lastAwdl = -999; const long long v = gamedevice.getValueHash(util::kAutoWalkDelayValue); if (v != s_lastAwdl) { s_lastAwdl = v; gamedevice.setClient05AutoWalkDelay(static_cast<int>(v)); } }", "{ static long long s_lastAwdl = -999; const long long v = gamedevice.getValueHash(util::kAutoWalkDelayValue); if (v != s_lastAwdl) { s_lastAwdl = v; gamedevice.setClient05AutoWalkDelay(static_cast<int>(v)); } }`r`n`t`t`t{ static int s_lastFb = -2; const int fbOn = gamedevice.getEnableHash(util::kFastBattleEnable) ? 1 : 0; if (fbOn != s_lastFb) { s_lastFb = fbOn; gamedevice.setClient05FastBattleRequested(fbOn); } }")
  if ($m -notmatch 'setClient05FastBattleRequested') { throw "mainthread fastBattle wiring failed." }
  Good 'applied mainthread fastBattle wiring (reapply + edge)'
}
[IO.File]::WriteAllText($mth, $m, $utf8bom)

Remove-Item $diagLog -ErrorAction SilentlyContinue
Remove-Item 'C:\zmffk\mute-diag.log' -ErrorAction SilentlyContinue
Remove-Item 'C:\zmffk\boost-diag.log' -ErrorAction SilentlyContinue
Remove-Item 'C:\zmffk\autologin-diag.log' -ErrorAction SilentlyContinue
Remove-Item 'C:\zmffk\pos-diag.log' -ErrorAction SilentlyContinue
Remove-Item 'C:\zmffk\landing-diag.log' -ErrorAction SilentlyContinue
Remove-Item 'C:\zmffk\fastwalk-diag.log' -ErrorAction SilentlyContinue
Remove-Item 'C:\zmffk\timelock-diag.log' -ErrorAction SilentlyContinue
Remove-Item 'C:\zmffk\lockmove-diag.log' -ErrorAction SilentlyContinue
Remove-Item 'C:\zmffk\passwall-diag.log' -ErrorAction SilentlyContinue
Remove-Item 'C:\zmffk\autowalk-diag.log' -ErrorAction SilentlyContinue
Remove-Item 'C:\zmffk\fastautowalk-diag.log' -ErrorAction SilentlyContinue
Remove-Item 'C:\zmffk\autoescape-diag.log' -ErrorAction SilentlyContinue
Remove-Item 'C:\zmffk\autobattle-diag.log' -ErrorAction SilentlyContinue
Remove-Item 'C:\zmffk\missiondbg.log' -ErrorAction SilentlyContinue

# ---- afkform.cpp : remove demo tab (owner: 다음 빌드에서 demo 탭 버린다) ----
$afkTxt = [IO.File]::ReadAllText($afk)
if ($afkTxt -match 'addTab\(pBattleSettingFrom, tr\("demo"\)\)') {
  $afkTxt = $afkTxt.Replace('ui.tabWidget->addTab(pBattleSettingFrom, tr("demo"));', '/* demo tab removed (owner request) */')
  $afkTxt = $afkTxt.Replace('BattleSettingFrom* pBattleSettingFrom = new BattleSettingFrom(index, this);', '/* BattleSettingFrom(demo) instance removed (owner request) */')
  if ($afkTxt -match 'addTab\(pBattleSettingFrom') { throw "afkform demo-tab removal failed." }
  [IO.File]::WriteAllText($afk, $afkTxt, $utf8bom)
  Good 'removed afksetting demo tab (BattleSettingFrom)'
} else { Say 'afkform demo tab already absent (skipped)' }
# ---- afkform.cpp : hide heal item-name select+input (owner: 조건기반이라 아이템지정 불필요) + walk tab ----
$afkTxt = [IO.File]::ReadAllText($afk)
if ($afkTxt -notmatch 'owner UI cleanup') {
  $afkCleanAnchor = 'util::setTab(ui.tabWidget);'
  if ($afkTxt.IndexOf($afkCleanAnchor) -lt 0) { throw "afkform setTab anchor not found (UI cleanup)." }
  $afkCleanInject = $afkCleanAnchor + "`r`n`t// [owner UI cleanup] heal 행 아이템이름 select+입력 숨김(조건기반) + walk 탭 숨김`r`n" +
    "`tui.lineEdit_magicheal_normal->setVisible(false); ui.pushButton_magicheal_normal_select->setVisible(false);`r`n" +
    "`tui.lineEdit_itemheal_normal->setVisible(false); ui.pushButton_itemheal_normal_select->setVisible(false);`r`n" +
    "`tui.lineEdit_itemhealmp_normal->setVisible(false); ui.pushButton_itemhealmp_normal_select->setVisible(false);`r`n" +
    "`tui.lineEdit_itemheal->setVisible(false); ui.pushButton_itemheal_select->setVisible(false);`r`n" +
    "`tui.lineEdit_itemhealmp->setVisible(false); ui.pushButton_itemhealmp_select->setVisible(false);`r`n" +
    "`tui.lineEdit_itemrevive->setVisible(false); ui.pushButton_itemrevive_select->setVisible(false);`r`n" +
    "`t// battle target buttons stretch into the freed space -> big 'SP' eyesore. Port targets by fixed`r`n" +
    "`t// client-side priority (self->pet->ride->team), not this UI, so hide them (item heal + item revive).`r`n" +
    "`tui.pushButton_itemheal->setVisible(false); ui.pushButton_itemrevive->setVisible(false);`r`n" +
    "`t// left-align the now-sparse item rows (no expanding widget left) so they look tidy, not gappy.`r`n" +
    "`tui.horizontalLayout_62->addStretch(1); ui.horizontalLayout_3->addStretch(1); ui.horizontalLayout_5->addStretch(1);`r`n" +
    "`tui.tabWidget->removeTab(ui.tabWidget->indexOf(ui.tab_4));"
  $afkTxt = $afkTxt.Replace($afkCleanAnchor, $afkCleanInject)
  if ($afkTxt -notmatch 'owner UI cleanup') { throw "afkform UI cleanup patch failed." }
  [IO.File]::WriteAllText($afk, $afkTxt, $utf8bom)
  Good 'applied afkform UI cleanup (hide heal item select+input, hide walk tab)'
} else { Say 'afkform UI cleanup already applied (skipped)' }

# ---- props + build ----
@'
<Project xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <ItemDefinitionGroup>
    <ClCompile>
      <PreprocessorDefinitions>CLIENT05_RUNTIME_ACTIVATION=1;CLIENT05_B1=1;CLIENT05_CONTROL=1;CLIENT05_AUTO_LOGIN=1;%(PreprocessorDefinitions)</PreprocessorDefinitions>
    </ClCompile>
  </ItemDefinitionGroup>
</Project>
'@ | Set-Content -LiteralPath $props -Encoding ASCII
$msb = 'C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe'
if (-not (Test-Path $msb)) { $msb = 'D:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe' }
if (-not (Test-Path $msb)) { throw "MSBuild not found." }
# [NoSubstFix] subst removed: build tree moved to short path C:\src\etc-source-local (real paths < MAX_PATH).
# Removing subst also kills the virtual-drive stale-cache bug that made post-build Get-ChildItem miss 3NZCX*.exe.
if (-not (Test-Path "$repoSaSH\SaSH\SaSH.vcxproj")) { throw "repo not found at $repoSaSH (did the tree move to C:\src\etc-source-local?)." }
try {
  Say "building sadll..."
  & $msb "$repoSaSH\sadll\sadll.vcxproj" /m:1 /t:Rebuild /p:Configuration=Release /p:Platform=Win32 /p:PlatformToolset=v143 /p:WindowsTargetPlatformVersion=10.0.26100.0 "/p:SolutionDir=$repoSaSH\" "/p:ForceImportBeforeCppTargets=$props" /nologo 2>&1 | Tee-Object -FilePath (Join-Path $runDir 'sadll.log') | Out-Null
  if ($LASTEXITCODE -ne 0) { Warn "sadll build FAILED:"; Select-String -Path (Join-Path $runDir 'sadll.log') -Pattern 'error C' | Select-Object -First 15 | ForEach-Object { $_.Line }; throw "sadll build failed." }
  Good "sadll OK"
  Say "building SaSH..."
  # [StaleLauncherFix] SaSH launcher was built with /t:Build (INCREMENTAL). Because the ps1 rewrites
  # launcher sources (gamedevice.cpp/mainthread.cpp) each run via git-revert+WriteAllText, MSBuild's
  # incremental dependency tracking could miss the change (subst S: paths / .tlog / same-second mtime),
  # leaving the launcher .obj STALE -> launcher-side edits (session-reapply, inject/validate retry, the
  # injectLibrary path) silently absent from the running binary while the sadll DLL (/t:Rebuild) was
  # always fresh. Force a full Rebuild so launcher edits are ALWAYS compiled in (matches sadll above).
  # [LauncherBuildSkip 2026-08-07] Skip the ~48s Qt launcher /t:Rebuild when C:\SaSH-relay\SKIP_LAUNCHER_BUILD.flag
  # exists AND a prior launcher exe is present -> reuse it. SAFE ONLY when launcher sources
  # (mainthread/gamedevice/afkform) are UNCHANGED this cycle (sadll-only fast-battle iterations). DELETE the flag
  # whenever a launcher-side edit is made so the next build recompiles the launcher.
  $sashExeDirChk = "$deploy\bin\SaSH\Release"
  $sashPrevExe = (cmd /c "dir /b `"$sashExeDirChk\3NZCX*.exe`"" 2>$null | Where-Object { $_ } | Select-Object -First 1)
  if ((Test-Path 'C:\SaSH-relay\SKIP_LAUNCHER_BUILD.flag') -and $sashPrevExe) {
    Good ("SaSH build SKIPPED (SKIP_LAUNCHER_BUILD.flag + reuse " + $sashPrevExe + ") - launcher unchanged this cycle")
  } else {
    & $msb "$repoSaSH\SaSH\SaSH.vcxproj" /m:1 /t:Rebuild /p:Configuration=Release /p:Platform=Win32 /p:PlatformToolset=v143 /p:WindowsTargetPlatformVersion=10.0.26100.0 "/p:SolutionDir=$repoSaSH\" /p:QtInstall="C:\Qt\5.15.2\msvc2019" /p:QtMsBuild="$repoSaSH\SaSH\QtMsBuild" "/p:ForceImportBeforeCppTargets=$props" /nologo 2>&1 | Tee-Object -FilePath (Join-Path $runDir 'sash.log') | Out-Null
    if ($LASTEXITCODE -ne 0) { Warn "SaSH build FAILED:"; Select-String -Path (Join-Path $runDir 'sash.log') -Pattern 'error C' | Select-Object -First 15 | ForEach-Object { $_.Line }; throw "SaSH build failed." }
    Good "SaSH OK"
  }
}
finally { <# subst removed - nothing to clean up #> }

# ---- deploy ----
# [BuildOutputWaitFix2] The build produces the outputs via the 'subst S:' virtual drive. After
# 'subst S: /D', THIS PowerShell process keeps a STALE real-path directory cache: a fresh out-of-process
# listing sees 3NZCX*.exe (mtime proves it exists), but in-process Get-ChildItem returns empty no matter
# how long we poll. Query through a fresh cmd.exe child process (its own view) to bypass the stale cache.
$exeDir = "$deploy\bin\SaSH\Release"; $dllDir = "$deploy\bin\sadll\Release"
$exeSrc = $null; $dllSrc = $null
for ($i = 0; $i -lt 20; $i++) {
  if (-not $exeSrc) { $n = (cmd /c "dir /b `"$exeDir\3NZCX*.exe`"" 2>$null | Where-Object { $_ } | Select-Object -First 1); if ($n) { $exeSrc = Join-Path $exeDir $n } }
  if (-not $dllSrc) { $n = (cmd /c "dir /b `"$dllDir\xfYahed*.dll`"" 2>$null | Where-Object { $_ } | Select-Object -First 1); if ($n) { $dllSrc = Join-Path $dllDir $n } }
  if ($exeSrc -and $dllSrc) { break }
  Start-Sleep -Milliseconds 500
}
if (-not $exeSrc) { throw "SaSH exe (3NZCX*.exe) not found under $exeDir after build (waited 10s)." }
if (-not $dllSrc) { throw "sadll dll (xfYahed*.dll) not found under $dllDir after build (waited 10s)." }
Get-Process -Name 'SaSH-client05-cleanup-validation' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 400
$dllDst = (Get-ChildItem "$run\bin\xfYahed*.dll" | Where-Object { $_.Name -notlike '*.bak' }).FullName
Copy-Item $exeDst "$exeDst.PREMUTE.bak" -Force
Copy-Item $dllDst "$dllDst.PREMUTE.bak" -Force
Copy-Item $exeSrc $exeDst -Force
Copy-Item $dllSrc $dllDst -Force
Good ("deployed injected sadll SHA: " + (Get-FileHash $dllDst -Algorithm SHA256).Hash)

# ---- launch ----
Start-Process -FilePath $exeDst -WorkingDirectory $run
Good "== launcher started (run $tag) =="
Warn ">>> Start -> auto-login -> in world. Then TOGGLE 'mute/屏蔽聲音' (no need to move now). <<<"
Warn "    mute ON  = BOTH background music AND sound effects go silent."
Warn "    mute OFF = both return. Toggle a few times, then close client+launcher."
Warn ">>> BOOST TEST: set the launcher SpeedBoost value to 14 (fastest), then 7, then 0 (normal). <<<"
Warn "    Expect boost-diag.log lines: level=14 sysTime ->1 noDrawMax ->14 ; level=0 restores orig."
Warn ">>> AUTOLOGIN TEST: uncheck the launcher autologin box, logout, return to password screen. <<<"
Warn "    Expect NO self-login; autologin-diag.log shows want=0 + cleared enable 1->0."
Warn ">>> POS TEST: set the launcher pos (character-slot left/right), check autologin, then Start to login. <<<"
Warn "    pos-diag.log logs srv/sub/chr read at the auto-login call. Try BOTH pos values; compare chr."
Warn ">>> LANDING SAMPLE (v15): just autologin ONCE with pos=right. landing-diag.log traces char/enable per procNo. <<<"
Warn ">>> RECONNECT TEST (v16): fresh login pos=right; then IN-CLIENT logout, set pos=left, let it re-login. Watch left char + pos-diag LOGINSCR lines. <<<"
Warn ">>> RECONNECT TEST (v17): fresh login pos=right; then IN-CLIENT logout, set pos=left, let it re-login. It should now pass procNo==1 and enter LEFT. NO checkbox toggle needed. <<<"
Warn ">>> DISCONNECT PROBE (v18): log in, then FORCE A DISCONNECT (stop/kill the local server, or pull the client offline) and WAIT ~30s. landing-diag logs proc/sub/sock/win/btn through the disconnect. <<<"
Warn ">>> RECONNECT TEST (v20): check AutoReconnect + AutoLogin, log in, then REBOOT THE SERVER. Do NOT click OK - the launcher should auto-confirm and re-enter the world by itself. <<<"
Warn "     v22 sweeps the OK-button band; on success procNo leaves 11 and auto-login reconnects."
Start-Sleep -Milliseconds 1500
if (Test-Path $diagLog) { Copy-Item $diagLog (Join-Path $runDir 'b1-step-diag.log') -Force }
if (Test-Path 'C:\zmffk\mute-diag.log') { Copy-Item 'C:\zmffk\mute-diag.log' (Join-Path $runDir 'mute-diag.log') -Force }
if (Test-Path 'C:\zmffk\boost-diag.log') { Copy-Item 'C:\zmffk\boost-diag.log' (Join-Path $runDir 'boost-diag.log') -Force }
if (Test-Path 'C:\zmffk\autologin-diag.log') { Copy-Item 'C:\zmffk\autologin-diag.log' (Join-Path $runDir 'autologin-diag.log') -Force }
if (Test-Path 'C:\zmffk\pos-diag.log') { Copy-Item 'C:\zmffk\pos-diag.log' (Join-Path $runDir 'pos-diag.log') -Force }
if (Test-Path 'C:\zmffk\landing-diag.log') { Copy-Item 'C:\zmffk\landing-diag.log' (Join-Path $runDir 'landing-diag.log') -Force }
Good "signal Claude when done; run dir: logs\human-ctrlinit\run-$tag"
