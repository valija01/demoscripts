# ══════════════════════════════════════════════════════════════════
# RunOnUser.ps1
#
# Runs as SYSTEM and launches a chosen payload script in the active
# user's interactive session via a one-shot scheduled task.
#
# Supported remote execution methods (all run as SYSTEM):
#   - Azure Portal     : Virtual Machine > Run Command
#   - Azure CLI        : az vm run-command invoke ...
#   - Intune           : Devices > Scripts / Remediations
#   - Miradore         : Device scripts (triggered at device)
#
# Exit codes (relevant for Intune Remediation):
#   0 = success
#   1 = failure (check log for details)
#
# Log + temp files are written to:
#   C:\ProgramData\RunOnUser\
# ($PSScriptRoot is NOT used — it is unreliable in remote execution
#  contexts where scripts run from staging temp directories.)
#
# ── Avatar modes (DemoRebootUI) ───────────────────────────────────
#   $AvatarMode = "Auto"   → PNG if $AvatarImagePath is a valid file, else Orb
#   $AvatarMode = "Orb"    → animated pulsing blue orb  (default, no files needed)
#   $AvatarMode = "Retro"  → GDI+ drawn retro robot with blinking eyes
#   $AvatarMode = "Image"  → PNG from $AvatarImagePath  (falls back to Orb if missing)
#
# ── Progress bar timing (DemoRebootUI) ───────────────────────────
#   Each step fills the bar over N seconds, controlled two ways:
#
#   A) Global default — change the param default at the top of the
#      DemoRebootUI here-string:
#        [int]$StepDelaySeconds = 4    ← seconds per step (increase to slow down)
#
#   B) Per-step override — pass a number directly to Run-Step in the
#      main loop (overrides the default for that step only):
#        Run-Step "Checking issues..."    10
#        Run-Step "Found problem..."       5
#        Run-Step "Rebooting computer..."  15
#
# ── Adding more steps (DemoRebootUI) ─────────────────────────────
#   Add as many Run-Step calls as you like in the main loop — the
#   bar resets to 0% and refills for each step automatically:
#        Run-Step "Backing up data..."    8
#        Run-Step "Applying patches..."  12
#        Run-Step "Verifying changes..."  6
#        Run-Step "Rebooting computer..." 5
#   The percent readout and bar colour (grey → electric cyan) scale
#   dynamically per step regardless of how many steps there are.
# ══════════════════════════════════════════════════════════════════


# ── SECTION 1: CONFIG ─────────────────────────────────────────────
$EnableLogging   = $true
$SelectedAction  = "DemoRebootUI"  # ← change here to run a different action
$AvatarMode      = "Auto"          # Auto | Orb | Retro | Image
$AvatarImagePath = ""              # full path to a PNG, used when AvatarMode is Auto or Image
# ──────────────────────────────────────────────────────────────────


# ── SECTION 2: LOGGING ────────────────────────────────────────────
# Using a fixed ProgramData path — reliable across all remote execution
# methods (Azure Run Command, Intune, Miradore all use temp staging dirs
# where $PSScriptRoot is empty or unpredictable).
$WorkDir = Join-Path $env:ProgramData "RunOnUser"
if (-not (Test-Path $WorkDir)) {
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
}
$LogFile = Join-Path $WorkDir "RunOnUser.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Output $line
    if ($EnableLogging) {
        Add-Content -Path $LogFile -Value $line
    }
}
# ──────────────────────────────────────────────────────────────────


# ── SECTION 3: ACTION DEFINITIONS ─────────────────────────────────
# Each entry is the full script content that will run in the user's
# interactive session. The launcher engine below never changes.
# To add a new action: copy the pattern, give it a unique key, and
# change $SelectedAction at the top.
$Actions = @{}

$Actions["DemoRebootUI"] = @'
param(
    [int]$StepDelaySeconds = 4,
    [int]$LoopCount = 1
)

# ── Final message config ───────────────────────────────────
$ShowFinal        = $false       # ← set to $true to show closing message
$ShowFinalText    = "Finished."  # text to display
$ShowFinalSeconds = 3            # seconds to hold before fade-out
# ─────────────────────────────────────────────────────

# ── Avatar config (injected by launcher) ──────────────────────────
$AvatarMode      = "__AVATAR_MODE__"        # Auto | Orb | Retro | Image
$AvatarImagePath = "__AVATAR_IMAGE_PATH__"  # full path to PNG
# ─────────────────────────────────────────────────────────────────

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── Resolve effective avatar mode ─────────────────────────────────
$script:effectiveAvatar = switch ($AvatarMode) {
    "Retro" { "Retro" }
    "Orb"   { "Orb"   }
    "Image" { if ($AvatarImagePath -and (Test-Path $AvatarImagePath)) { "Image" } else { "Orb" } }
    default { if ($AvatarImagePath -and (Test-Path $AvatarImagePath)) { "Image" } else { "Orb" } }
}

# ── Color palette ─────────────────────────────────────────────────
$bgColor     = [System.Drawing.Color]::FromArgb(26, 26, 34)
$accentColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$textColor   = [System.Drawing.Color]::FromArgb(240, 240, 245)
$mutedColor  = [System.Drawing.Color]::FromArgb(150, 150, 165)
$barBgColor  = [System.Drawing.Color]::FromArgb(55, 55, 68)

# ── Form ──────────────────────────────────────────────────────────
$form = New-Object System.Windows.Forms.Form
$form.Size            = New-Object System.Drawing.Size(520, 140)
$form.StartPosition   = "CenterScreen"
$form.TopMost         = $true
$form.FormBorderStyle = "None"
$form.BackColor       = $bgColor
$form.ShowInTaskbar   = $false
$form.Opacity         = 0

# ── Avatar panel (left column) ────────────────────────────────────
$avatarPanel           = New-Object System.Windows.Forms.Panel
$avatarPanel.Size      = New-Object System.Drawing.Size(88, 88)
$avatarPanel.Location  = New-Object System.Drawing.Point(18, 26)
$avatarPanel.BackColor = $bgColor

# ── Title label ───────────────────────────────────────────────────
$titleLabel           = New-Object System.Windows.Forms.Label
$titleLabel.Text      = "Workplace Agent"
$titleLabel.Font      = New-Object System.Drawing.Font("Segoe UI", 8)
$titleLabel.ForeColor = $mutedColor
$titleLabel.BackColor = $bgColor
$titleLabel.Size      = New-Object System.Drawing.Size(390, 18)
$titleLabel.Location  = New-Object System.Drawing.Point(120, 20)
$titleLabel.TextAlign = "MiddleLeft"

# ── Status label ──────────────────────────────────────────────────
$statusLabel           = New-Object System.Windows.Forms.Label
$statusLabel.Text      = ""
$statusLabel.Font      = New-Object System.Drawing.Font("Segoe UI", 11)
$statusLabel.ForeColor = $textColor
$statusLabel.BackColor = $bgColor
$statusLabel.Size      = New-Object System.Drawing.Size(300, 30)
$statusLabel.Location  = New-Object System.Drawing.Point(120, 42)
$statusLabel.TextAlign = "MiddleLeft"

# ── Percent readout ────────────────────────────────────────────────
$percentLabel           = New-Object System.Windows.Forms.Label
$percentLabel.Text      = "0%"
$percentLabel.Font      = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$percentLabel.ForeColor = $mutedColor
$percentLabel.BackColor = $bgColor
$percentLabel.Size      = New-Object System.Drawing.Size(88, 30)
$percentLabel.Location  = New-Object System.Drawing.Point(420, 42)
$percentLabel.TextAlign = "MiddleRight"

# ── Custom pill-shaped progress bar ───────────────────────────────
$barPanel           = New-Object System.Windows.Forms.Panel
$barPanel.Size      = New-Object System.Drawing.Size(388, 12)
$barPanel.Location  = New-Object System.Drawing.Point(120, 90)
$barPanel.BackColor = $bgColor

$script:barValue = 0

$barPanel.Add_Paint({
    param($s, $e)
    $g  = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $bw = $s.Width
    $bh = $s.Height

    # Pill clip path (track shape)
    $pill = New-Object System.Drawing.Drawing2D.GraphicsPath
    $pill.AddArc(0, 0, $bh, $bh, 90, 180)
    $pill.AddArc(($bw - $bh), 0, $bh, $bh, 270, 180)
    $pill.CloseFigure()

    # Clip everything to pill shape from here on
    $g.SetClip($pill)

    # Track background
    $tBrush = New-Object System.Drawing.SolidBrush($barBgColor)
    $g.FillPath($tBrush, $pill)
    $tBrush.Dispose()

    # Filled portion — dark blue (0%) → electric cyan (100%)
    $fw = [int](($script:barValue / 100.0) * $bw)
    if ($fw -gt 0) {
        $t  = $script:barValue / 100.0

        # Leading-edge (right) colour: interpolates dark blue → electric cyan
        $rF = [int](0   * (1 - $t) + 20  * $t)
        $gF = [int](55  * (1 - $t) + 230 * $t)
        $bF = [int](180 * (1 - $t) + 255 * $t)

        # Trailing-edge (left) colour: ~45% dimmed
        $rD = [int]($rF * 0.45)
        $gD = [int]($gF * 0.45)
        $bD = [int]($bF * 0.60)

        $lgbFill = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            (New-Object System.Drawing.Rectangle(0, 0, [Math]::Max(1, $fw), $bh)),
            [System.Drawing.Color]::FromArgb($rD, $gD, $bD),
            [System.Drawing.Color]::FromArgb($rF, $gF, $bF),
            [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal
        )
        $g.FillRectangle($lgbFill, 0, 0, $fw, $bh)
        $lgbFill.Dispose()
    }

    $g.ResetClip()
    $pill.Dispose()
})

$form.Controls.Add($avatarPanel)
$form.Controls.Add($titleLabel)
$form.Controls.Add($statusLabel)
$form.Controls.Add($percentLabel)
$form.Controls.Add($barPanel)

# ── Animation state ───────────────────────────────────────────────
$script:orbPhase    = 0.0
$script:wispPhase   = 0.0
$script:blinkCount  = 0
$script:blinkOpen   = $true
$script:blinkTarget = (Get-Random -Minimum 30 -Maximum 70)
$script:img         = $null

if ($script:effectiveAvatar -eq "Image") {
    try   { $script:img = [System.Drawing.Image]::FromFile($AvatarImagePath) }
    catch { $script:effectiveAvatar = "Orb" }
}

# ── Avatar paint ──────────────────────────────────────────────────
$avatarPanel.Add_Paint({
    param($s, $e)
    $g  = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $cx = [int]($s.Width  / 2)
    $cy = [int]($s.Height / 2)

    switch ($script:effectiveAvatar) {

        "Orb" {
            $pulse  = [Math]::Abs([Math]::Sin($script:orbPhase))
            $pulse2 = [Math]::Abs([Math]::Sin($script:orbPhase * 0.6 + 1.1))

            # ── Outer ethereal halos (alternating blue / purple) ──────────
            $outerR = [int](38 + $pulse * 7)
            foreach ($ring in @(5, 4, 3, 2, 1)) {
                $rr    = [int]($outerR * ($ring / 5.0))
                $alpha = [int](14 * $pulse * ($ring / 5.0))
                if ($alpha -lt 1) { $alpha = 1 }
                $rc = if ($ring % 2 -eq 0) {
                    [System.Drawing.Color]::FromArgb($alpha, 110, 50, 230)   # violet
                } else {
                    [System.Drawing.Color]::FromArgb($alpha, 0, 170, 255)    # cyan-blue
                }
                $rb = New-Object System.Drawing.SolidBrush($rc)
                $g.FillEllipse($rb, ($cx - $rr), ($cy - $rr), ($rr * 2), ($rr * 2))
                $rb.Dispose()
            }

            # ── Mid glow — radial gradient (blue rim → transparent) ───────
            $cr    = [int](20 + $pulse * 5)
            $glowR = $cr + 10
            $glowPath = New-Object System.Drawing.Drawing2D.GraphicsPath
            $glowPath.AddEllipse(($cx - $glowR), ($cy - $glowR), ($glowR * 2), ($glowR * 2))
            $pgb = New-Object System.Drawing.Drawing2D.PathGradientBrush($glowPath)
            $pgb.CenterColor    = [System.Drawing.Color]::FromArgb(180, 120, 180, 255)
            $pgb.SurroundColors = [System.Drawing.Color[]]@([System.Drawing.Color]::FromArgb(0, 0, 60, 180))
            $g.FillPath($pgb, $glowPath)
            $pgb.Dispose()
            $glowPath.Dispose()

            # ── Core — radial gradient (white hot centre → vivid blue) ────
            $corePath = New-Object System.Drawing.Drawing2D.GraphicsPath
            $corePath.AddEllipse(($cx - $cr), ($cy - $cr), ($cr * 2), ($cr * 2))
            $cgb = New-Object System.Drawing.Drawing2D.PathGradientBrush($corePath)
            $cgb.CenterColor    = [System.Drawing.Color]::FromArgb(255, 255, 255, 255)
            $cgb.SurroundColors = [System.Drawing.Color[]]@([System.Drawing.Color]::FromArgb(230, 0, 110, 220))
            $g.FillPath($cgb, $corePath)
            $cgb.Dispose()
            $corePath.Dispose()

            # ── Wisp particles orbiting the orb ───────────────────────────
            # Each entry: phase offset, orbital radii X/Y, particle size, max alpha
            $wisps = @(
                @(0.00; 31; 17; 5; 190)
                @(2.09; 25; 24; 4; 150)
                @(4.19; 33; 13; 3; 130)
                @(1.05; 19; 29; 3; 110)
                @(3.14; 27; 21; 4; 160)
                @(5.24; 22; 26; 3; 120)
            )
            foreach ($w in $wisps) {
                $wPhase = $script:wispPhase + $w[0]
                $wx = $cx + [int]([Math]::Cos($wPhase) * $w[1])
                $wy = $cy + [int]([Math]::Sin($wPhase) * $w[2])
                $ws = $w[3]

                # Outer wisp glow
                $wga = [int]($w[4] * 0.28 * $pulse2)
                if ($wga -gt 0) {
                    $wgb = New-Object System.Drawing.SolidBrush(
                        [System.Drawing.Color]::FromArgb($wga, 140, 200, 255))
                    $g.FillEllipse($wgb, ($wx - $ws - 3), ($wy - $ws - 3), (($ws + 3) * 2), (($ws + 3) * 2))
                    $wgb.Dispose()
                }
                # Inner wisp core
                $wca = [int]($w[4] * $pulse2)
                if ($wca -gt 255) { $wca = 255 }
                if ($wca -gt 0) {
                    $wcb = New-Object System.Drawing.SolidBrush(
                        [System.Drawing.Color]::FromArgb($wca, 210, 235, 255))
                    $g.FillEllipse($wcb, ($wx - $ws), ($wy - $ws), ($ws * 2), ($ws * 2))
                    $wcb.Dispose()
                }
            }
        }

        "Image" {
            if ($script:img) {
                $g.DrawImage($script:img, 4, 4, ($s.Width - 8), ($s.Height - 8))
            }
        }

        "Retro" {
            $gc = [System.Drawing.Color]::FromArgb(72, 199, 114)
            $dc = [System.Drawing.Color]::FromArgb(20, 20, 30)
            $gb = New-Object System.Drawing.SolidBrush($gc)
            $db = New-Object System.Drawing.SolidBrush($dc)
            $gp = New-Object System.Drawing.Pen($gc, 2)

            # Antenna
            $g.DrawLine($gp, $cx, 2, $cx, 16)
            $g.FillEllipse($gb, ($cx - 5), 0, 10, 10)

            # Head
            $g.FillRectangle($gb, ($cx - 28), 18, 56, 48)

            # Eyes
            if ($script:blinkOpen) {
                $g.FillEllipse($db, ($cx - 22), 28, 14, 14)
                $g.FillEllipse($db, ($cx + 8),  28, 14, 14)
                $wb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
                $g.FillEllipse($wb, ($cx - 18), 31, 5, 5)
                $g.FillEllipse($wb, ($cx + 12), 31, 5, 5)
                $wb.Dispose()
            } else {
                $g.DrawLine($gp, ($cx - 22), 35, ($cx - 8),  35)
                $g.DrawLine($gp, ($cx + 8),  35, ($cx + 22), 35)
            }

            # Mouth pixel grid
            for ($px = 0; $px -lt 5; $px++) {
                $g.FillRectangle($db, ($cx - 18 + ($px * 8)), 48, 6, 10)
            }

            # Side rivets
            $g.FillEllipse($db, ($cx - 34), 30, 7, 7)
            $g.FillEllipse($db, ($cx + 27), 30, 7, 7)

            # Neck stub
            $g.FillRectangle($gb, ($cx - 8), 66, 16, 8)

            $gb.Dispose()
            $db.Dispose()
            $gp.Dispose()
        }
    }
})

# ── Animation timer ───────────────────────────────────────────────
$timer          = New-Object System.Windows.Forms.Timer
$timer.Interval = 50

$timer.Add_Tick({
    if ($script:effectiveAvatar -eq "Orb") {
        $script:orbPhase  += 0.09
        $script:wispPhase += 0.055
        if ($script:orbPhase  -gt [Math]::PI * 2) { $script:orbPhase  -= [Math]::PI * 2 }
        if ($script:wispPhase -gt [Math]::PI * 2) { $script:wispPhase -= [Math]::PI * 2 }
        $avatarPanel.Invalidate()
    } elseif ($script:effectiveAvatar -eq "Retro") {
        $script:blinkCount++
        if ($script:blinkCount -ge $script:blinkTarget) {
            $script:blinkOpen   = $false
            $script:blinkCount  = 0
            $script:blinkTarget = (Get-Random -Minimum 30 -Maximum 80)
        } elseif (-not $script:blinkOpen -and $script:blinkCount -gt 3) {
            $script:blinkOpen = $true
        }
        $avatarPanel.Invalidate()
    }
})
$timer.Start()

# ── Fade-in ───────────────────────────────────────────────────────
$form.Show()
for ($i = 0; $i -le 10; $i++) {
    $form.Opacity = $i / 10.0
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 20
}

# ── Step function ─────────────────────────────────────────────────
function Run-Step {
    param([string]$Text, [int]$Seconds)
    $statusLabel.Text       = $Text
    $script:barValue        = 0
    $percentLabel.Text      = "0%"
    $percentLabel.ForeColor = $mutedColor
    $barPanel.Invalidate()

    $steps = $Seconds * 20
    for ($i = 1; $i -le $steps; $i++) {
        $script:barValue = [int](($i / $steps) * 100)
        $barPanel.Invalidate()

        # Percent readout — colour tracks bar: muted grey (0%) → electric cyan (100%)
        $t  = $script:barValue / 100.0
        $pR = [int](150 * (1 - $t) + 20  * $t)
        $pG = [int](150 * (1 - $t) + 230 * $t)
        $pB = [int](165 * (1 - $t) + 255 * $t)
        $percentLabel.Text      = "$($script:barValue)%"
        $percentLabel.ForeColor = [System.Drawing.Color]::FromArgb($pR, $pG, $pB)

        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }
}

# ── Final-text display (no bar, no percent) ──────────────────────
function Show-Final {
    param([string]$Text, [int]$Seconds = 3)
    $barPanel.Visible     = $false
    $percentLabel.Visible = $false
    $statusLabel.Size     = New-Object System.Drawing.Size(388, 40)
    $statusLabel.Location = New-Object System.Drawing.Point(120, 52)
    $statusLabel.Text     = $Text
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Seconds $Seconds
}

# ── Main loop ─────────────────────────────────────────────────────
for ($loop = 1; $loop -le $LoopCount; $loop++) {
    Run-Step "Checking issues..."    $StepDelaySeconds
    Run-Step "Found problem..."      $StepDelaySeconds
    Run-Step "Fixing computer..." $StepDelaySeconds
}
if ($ShowFinal) { Show-Final $ShowFinalText $ShowFinalSeconds }

$timer.Stop()
Start-Sleep -Seconds 1

# Fade-out
for ($i = 10; $i -ge 0; $i--) {
    $form.Opacity = $i / 10.0
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 20
}

$form.Close()
if ($script:img) { $script:img.Dispose() }

# ── Reboot ────────────────────────────────────────────────────────
#Restart-Computer -Force
'@

# ── Add future actions below this line ────────────────────────────
# $Actions["SomeOtherAction"] = @'
# ... full script content here ...
# '@
# ──────────────────────────────────────────────────────────────────


# ── SECTION 4: LAUNCHER ENGINE (payload-agnostic) ─────────────────
Write-Log "RunOnUser started. Action='$SelectedAction'  EnableLogging=$EnableLogging"

# Validate selected action
if (-not $Actions.ContainsKey($SelectedAction)) {
    Write-Log "Action '$SelectedAction' is not defined in `$Actions. Valid actions: $($Actions.Keys -join ', ')" "ERROR"
    exit 1
}

# Write payload to temp file — inject avatar config via token replacement
$tempScript     = Join-Path $WorkDir ("${SelectedAction}_" + (Get-Random) + ".ps1")
$payloadContent = $Actions[$SelectedAction]
$payloadContent = $payloadContent.Replace('__AVATAR_MODE__', $AvatarMode)
$payloadContent = $payloadContent.Replace('__AVATAR_IMAGE_PATH__', $AvatarImagePath)
Set-Content -Path $tempScript -Value $payloadContent -Encoding UTF8
Write-Log "Payload written to: $tempScript"

# Detect active user session
$quserOutput = quser 2>&1
Write-Log "quser output: $quserOutput"

$session = ($quserOutput | Where-Object { $_ -match "Active" } | Select-Object -First 1)

if (-not $session) {
    Write-Log "No active user session found. Cannot launch UI in user context." "ERROR"
    Remove-Item -Path $tempScript -Force -ErrorAction SilentlyContinue
    exit 1
}

# Parse username — strip leading whitespace and > prefix
$username = ($session.Trim() -split '\s+')[0].TrimStart('>')

if (-not $username) {
    Write-Log "Failed to parse username from quser line: $session" "ERROR"
    Remove-Item -Path $tempScript -Force -ErrorAction SilentlyContinue
    exit 1
}

Write-Log "Targeting user: $username"

# Build and register scheduled task
$taskName   = "${SelectedAction}_" + (Get-Random)
$taskAction = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"$tempScript`""
$trigger    = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(5)
$principal  = New-ScheduledTaskPrincipal -UserId $username -LogonType Interactive -RunLevel Highest

$regResult = Register-ScheduledTask -TaskName $taskName `
    -Action $taskAction `
    -Trigger $trigger `
    -Principal $principal `
    -ErrorAction SilentlyContinue

if (-not $regResult) {
    Write-Log "Failed to register scheduled task for user '$username'." "ERROR"
    Remove-Item -Path $tempScript -Force -ErrorAction SilentlyContinue
    exit 1
}

Write-Log "Task '$taskName' registered. Starting..."
Start-ScheduledTask -TaskName $taskName

# Cleanup
# Note: if the payload reboots the machine, the lines below won't run —
# that's fine; the one-time task won't persist after reboot anyway.
Start-Sleep -Seconds 30
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item -Path $tempScript -Force -ErrorAction SilentlyContinue
Write-Log "Cleanup complete. Done."
# ──────────────────────────────────────────────────────────────────
