# MultiUSBSync - a WinForms GUI for pushing a folder's contents onto
# one or more removable USB drives at once. Plain PowerShell + WinForms,
# no external dependencies, no build step - just run the .ps1.
#
# Source folder is copied to each drive's root as-is, one path relative
# to another - <SourceRoot>\bin\launcher.exe -> <drive>:\bin\launcher.exe,
# <SourceRoot>\assets\logo.png -> <drive>:\assets\logo.png, and so on
# for whatever else lives under the source folder - no special-casing
# needed for any particular file or subfolder, since the source
# folder's own layout already mirrors what should end up on the drive.
#
# The picked source folder is remembered between runs (see
# $SettingsPath below) - saved right next to this script, not meant to
# be tracked in git (it's a local path specific to this machine).
#
# Files to remove: an explicit, hand-maintained list of relative paths
# (e.g. "old\stale-file.txt") that get deleted from a checked drive if
# present - for cleaning up specific known-stale/renamed files on
# drives that were already populated by an earlier run. Deliberately
# NOT a computed "delete anything not in the source folder" diff/mirror
# - that would silently depend on exactly which files happen to be
# checked in the tree this run, and risks deleting something never
# meant to be touched. Also remembered between runs, alongside the
# source folder. Always gets its own separate Yes/No confirmation
# naming every file before anything is deleted, regardless of "Confirm
# before copying".
#
# Drive list: every ready removable drive, full stop - not keyed on
# any particular folder existing, since the source folder can hold any
# set of folders/files. Covers both updating a drive that already has
# content and provisioning a completely blank one from scratch, as
# long as the source folder picked above actually has everything that
# drive needs - this tool only copies what's in that folder, it
# doesn't know what "complete" means on its own. No marker-based
# filtering also means no guardrail against picking an unrelated USB
# stick by mistake - the drive list is just "every removable drive
# plugged in right now".

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Native helper. SetProcessDPIAware: without it Windows renders this
# window at 96 DPI and bitmap-stretches it on a scaled display (125% /
# 150%), which is why everything looked blurry. It has to run before the
# first control is created, so it lives up here.
#
# FlatBar is a progress bar that always paints its own colours, with an
# outlined track. The stock one takes its colour from the Windows theme
# (green on Windows 10/11), ignores ForeColor and has no visible outline,
# so two stock bars can't be told apart and the empty part is nearly
# invisible on the window background.
#
# FlatButton paints itself so that its disabled text stays readable: the
# stock disabled button text is a pale grey (contrast ~2.5:1).
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class NativeMethods {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
}

public class FlatBar : ProgressBar {
    public Color BarColor = Color.FromArgb(0, 80, 160);
    public Color TrackColor = Color.FromArgb(250, 251, 253);
    public Color EdgeColor = Color.FromArgb(128, 134, 146);
    public FlatBar() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
    }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.Clear(TrackColor);
        double frac = (Maximum > Minimum) ? (double)(Value - Minimum) / (Maximum - Minimum) : 0.0;
        int w = (int)Math.Round(Width * Math.Max(0.0, Math.Min(1.0, frac)));
        using (SolidBrush b = new SolidBrush(BarColor)) g.FillRectangle(b, 0, 0, w, Height);
        using (Pen pen = new Pen(EdgeColor)) g.DrawRectangle(pen, 0, 0, Width - 1, Height - 1);
    }
}

public class FlatButton : Button {
    public Color Face = Color.FromArgb(250, 251, 253);
    public Color FaceHover = Color.FromArgb(226, 234, 248);
    public Color FacePress = Color.FromArgb(203, 218, 244);
    public Color FaceDisabled = Color.FromArgb(236, 238, 242);
    public Color Edge = Color.FromArgb(128, 134, 146);
    public Color EdgeDisabled = Color.FromArgb(188, 193, 203);
    public Color TextEnabled = Color.Black;
    public Color TextDisabled = Color.FromArgb(92, 97, 108);
    bool hot = false, down = false;

    public FlatButton() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
    }
    protected override void OnMouseEnter(EventArgs e) { hot = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hot = false; down = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { down = true; Invalidate(); base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        Color face = !Enabled ? FaceDisabled : (down ? FacePress : (hot ? FaceHover : Face));
        g.Clear(face);
        using (Pen pen = new Pen(Enabled ? Edge : EdgeDisabled)) g.DrawRectangle(pen, 0, 0, Width - 1, Height - 1);
        TextRenderer.DrawText(g, Text, Font, new Rectangle(0, 0, Width, Height), Enabled ? TextEnabled : TextDisabled,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix | TextFormatFlags.EndEllipsis);
        if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(g, new Rectangle(3, 3, Width - 6, Height - 6));
    }
}
"@
[void][NativeMethods]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()

# Display scale (1.0 = 96 DPI). The layout below is written in 96-DPI
# pixels and scaled by this just before the window is shown.
$script:dpiK = 1.0
$gfx = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$script:dpiK = $gfx.DpiX / 96.0
$gfx.Dispose()

# Bumped by hand on each real change - shown in the window title so
# it's obvious at a glance which build is actually running.
$Version = '1.7'

$SettingsPath = Join-Path $PSScriptRoot 'MultiUSBSync.settings.json'

function Get-Settings {
    if (-not (Test-Path $SettingsPath)) { return @{ SourceRoot = $null; RemoveList = @() } }
    try {
        $raw = Get-Content -Path $SettingsPath -Raw | ConvertFrom-Json
        $sourceRoot = if ($raw.SourceRoot -and (Test-Path -LiteralPath $raw.SourceRoot)) { $raw.SourceRoot } else { $null }
        $removeList = if ($raw.RemoveList) { @($raw.RemoveList) } else { @() }
        return @{ SourceRoot = $sourceRoot; RemoveList = $removeList }
    } catch {
        # Malformed/unreadable settings file - just fall back to
        # nothing saved rather than crash the whole tool over it.
        return @{ SourceRoot = $null; RemoveList = @() }
    }
}

function Save-Settings {
    param([string]$RootPath, [string[]]$RemoveList)
    @{ SourceRoot = $RootPath; RemoveList = @($RemoveList) } | ConvertTo-Json | Set-Content -Path $SettingsPath -Encoding UTF8
}

function Get-SourceFiles {
    if (-not ($script:sourceRoot -and (Test-Path -LiteralPath $script:sourceRoot))) { return @() }
    # -LiteralPath, not -Path: a folder or file name containing [ or ] is
    # a wildcard to -Path, and its files would silently vanish from the
    # list. Hidden files only when "Include hidden files" is ticked.
    $params = @{ LiteralPath = $script:sourceRoot; Recurse = $true; File = $true }
    if ($chkHidden -and $chkHidden.Checked) { $params['Force'] = $true }
    $root = $script:sourceRoot
    @(Get-ChildItem @params | ForEach-Object {
        $rel = $_.FullName.Substring($root.Length).TrimStart('\')
        [PSCustomObject]@{
            Label        = $rel
            Full         = $_.FullName
            DestRelative = $rel
        }
    })
}
function Get-FileHashChunked {
    # Hand-rolled instead of Get-FileHash so a large file (hundreds of
    # MB, possibly on a slow USB drive) reports progress and yields to
    # the UI thread via OnProgress, instead of one single blocking read
    # that makes the window look frozen.
    param([string]$Path, [ScriptBlock]$OnProgress)
    $bufferSize = 4MB
    $buffer = New-Object byte[] $bufferSize
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $total = $stream.Length
        $done = 0
        while ($true) {
            $read = $stream.Read($buffer, 0, $bufferSize)
            if ($read -le 0) { break }
            [void]$sha.TransformBlock($buffer, 0, $read, $null, 0)
            $done += $read
            if ($OnProgress -and $total -gt 0) { & $OnProgress ($done / $total) }
        }
        [void]$sha.TransformFinalBlock(@(), 0, 0)
        return ([BitConverter]::ToString($sha.Hash) -replace '-', '')
    } finally {
        $stream.Close()
        $sha.Dispose()
    }
}

function Copy-FileChunked {
    # Same reasoning as Get-FileHashChunked - Copy-Item on a large file
    # is one blocking call with no way to update the UI mid-copy.
    #
    # Writes to "<dest>.msync-part" first and only moves it onto the real
    # name once every byte is written and flushed to the drive, so an
    # interrupted copy (drive pulled, disk full, ...) can never leave a
    # truncated file under the real name - at worst a stray .msync-part
    # file, which the next run removes.
    param([string]$SourcePath, [string]$DestPath, [ScriptBlock]$OnProgress)
    $bufferSize = 4MB
    $buffer = New-Object byte[] $bufferSize
    $tempPath = "$DestPath.msync-part"
    $completed = $false
    $srcStream = [System.IO.File]::OpenRead($SourcePath)
    try {
        $total = $srcStream.Length
        $destStream = [System.IO.File]::Create($tempPath)
        try {
            $done = 0
            while ($true) {
                $read = $srcStream.Read($buffer, 0, $bufferSize)
                if ($read -le 0) { break }
                $destStream.Write($buffer, 0, $read)
                $done += $read
                if ($OnProgress -and $total -gt 0) { & $OnProgress ($done / $total) }
            }
            # Flush($true) also asks Windows to push its own write cache
            # out to the drive, not just .NET's buffer.
            $destStream.Flush($true)
        } finally {
            $destStream.Close()
        }
        if ((Get-Item -LiteralPath $tempPath).Length -ne $total) {
            throw "Short write: $tempPath is not the same size as the source file"
        }
        if ([System.IO.File]::Exists($DestPath)) { [System.IO.File]::Delete($DestPath) }
        [System.IO.File]::Move($tempPath, $DestPath)
        $completed = $true
    } finally {
        $srcStream.Close()
        if (-not $completed -and [System.IO.File]::Exists($tempPath)) {
            try { [System.IO.File]::Delete($tempPath) } catch { }
        }
    }
}
function Get-TargetDrives {
    # Every ready removable drive - not keyed on any particular folder
    # existing, since the source folder can hold any set of
    # folders/files. Covers both updating a drive that already has
    # content and provisioning a completely blank one from scratch.
    # No content-based filtering means no guardrail against picking an
    # unrelated USB stick by mistake - showing the volume label (where
    # one's set) is the one cheap thing that helps tell drives apart at
    # a glance, since DriveInfo already exposes it for free.
    [System.IO.DriveInfo]::GetDrives() | Where-Object {
        $_.DriveType -eq 'Removable' -and $_.IsReady
    } | ForEach-Object {
        $volumeLabel = if ($_.VolumeLabel) { $_.VolumeLabel } else { 'no label' }
        [PSCustomObject]@{
            Root  = $_.RootDirectory.FullName
            Label = "$($_.RootDirectory.FullName) ($volumeLabel)"
        }
    }
}

# ---------- UI ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = "MultiUSBSync v$Version"
# ClientSize, not Size: Size includes the window border, which used to
# leave ~16 px less room inside than the layout below assumed - the
# right-hand list and buttons ran into the edge. All controls end at x=545
# so there is an equal 15 px margin on both sides.
$form.ClientSize = New-Object System.Drawing.Size(560, 640)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

$lblSource = New-Object System.Windows.Forms.Label
$lblSource.Text = 'Source folder (copied to the drive root as-is):'
$lblSource.Location = New-Object System.Drawing.Point(15, 15)
$lblSource.AutoSize = $true
$form.Controls.Add($lblSource)

$txtSourceRoot = New-Object System.Windows.Forms.TextBox
$txtSourceRoot.Location = New-Object System.Drawing.Point(15, 37)
$txtSourceRoot.Size = New-Object System.Drawing.Size(435, 22)
$txtSourceRoot.ReadOnly = $true
$form.Controls.Add($txtSourceRoot)

$btnBrowseSource = New-Object FlatButton
$btnBrowseSource.Text = 'Browse...'
$btnBrowseSource.Location = New-Object System.Drawing.Point(460, 36)
$btnBrowseSource.Size = New-Object System.Drawing.Size(85, 24)
$form.Controls.Add($btnBrowseSource)

$lblFiles = New-Object System.Windows.Forms.Label
$lblFiles.Text = 'Files to push:'
$lblFiles.Location = New-Object System.Drawing.Point(15, 70)
$lblFiles.AutoSize = $true
$form.Controls.Add($lblFiles)

$tvFiles = New-Object System.Windows.Forms.TreeView
$tvFiles.Location = New-Object System.Drawing.Point(15, 95)
$tvFiles.Size = New-Object System.Drawing.Size(280, 220)
$tvFiles.CheckBoxes = $true
$form.Controls.Add($tvFiles)

$btnFilesAll = New-Object FlatButton
$btnFilesAll.Text = 'Select All'
$btnFilesAll.Location = New-Object System.Drawing.Point(15, 320)
$btnFilesAll.Size = New-Object System.Drawing.Size(135, 25)
$form.Controls.Add($btnFilesAll)

$btnFilesNone = New-Object FlatButton
$btnFilesNone.Text = 'Select None'
$btnFilesNone.Location = New-Object System.Drawing.Point(160, 320)
$btnFilesNone.Size = New-Object System.Drawing.Size(135, 25)
$form.Controls.Add($btnFilesNone)

# Same idea as "Refresh drives" (removable drives get plugged/unplugged
# live), but for the source folder - it's only re-scanned at startup
# and on Browse..., so re-picking the same folder here re-syncs the
# tree against whatever is really on disk right now without a full
# restart.
$btnRefreshFiles = New-Object FlatButton
$btnRefreshFiles.Text = 'Refresh files'
$btnRefreshFiles.Location = New-Object System.Drawing.Point(15, 350)
$btnRefreshFiles.Size = New-Object System.Drawing.Size(280, 25)
$form.Controls.Add($btnRefreshFiles)

$lblDrives = New-Object System.Windows.Forms.Label
$lblDrives.Text = 'Drives found:'
$lblDrives.Location = New-Object System.Drawing.Point(310, 70)
$lblDrives.AutoSize = $true
$form.Controls.Add($lblDrives)

$clbDrives = New-Object System.Windows.Forms.CheckedListBox
$clbDrives.Location = New-Object System.Drawing.Point(310, 95)
$clbDrives.Size = New-Object System.Drawing.Size(235, 160)
$clbDrives.CheckOnClick = $true
$clbDrives.HorizontalScrollbar = $true
$form.Controls.Add($clbDrives)


$btnDrivesAll = New-Object FlatButton
$btnDrivesAll.Text = 'Select All'
$btnDrivesAll.Location = New-Object System.Drawing.Point(310, 260)
$btnDrivesAll.Size = New-Object System.Drawing.Size(112, 25)
$form.Controls.Add($btnDrivesAll)

$btnDrivesNone = New-Object FlatButton
$btnDrivesNone.Text = 'Select None'
$btnDrivesNone.Location = New-Object System.Drawing.Point(433, 260)
$btnDrivesNone.Size = New-Object System.Drawing.Size(112, 25)
$form.Controls.Add($btnDrivesNone)

$btnRefresh = New-Object FlatButton
$btnRefresh.Text = 'Refresh drives'
$btnRefresh.Location = New-Object System.Drawing.Point(310, 290)
$btnRefresh.Size = New-Object System.Drawing.Size(235, 30)
$form.Controls.Add($btnRefresh)

$chkConfirm = New-Object System.Windows.Forms.CheckBox
$chkConfirm.Text = 'Confirm before copying'
$chkConfirm.Location = New-Object System.Drawing.Point(310, 325)
$chkConfirm.AutoSize = $true
$chkConfirm.Checked = $false
$form.Controls.Add($chkConfirm)

$chkForce = New-Object System.Windows.Forms.CheckBox
$chkForce.Text = 'Force overwrite even if identical'
$chkForce.Location = New-Object System.Drawing.Point(310, 347)
$chkForce.AutoSize = $true
$chkForce.Checked = $false
$form.Controls.Add($chkForce)

# On by default - a Test-Path per checked file costs microseconds
# (measured: ~0.01ms/file), nothing next to the actual copy that
# follows. Guards against a file that was checked in the tree earlier
# but got deleted/renamed on disk since then - the tree doesn't
# re-scan on its own, so without this the failure would only surface
# deep inside the copy loop below with a less clear error.
$chkVerifyExists = New-Object System.Windows.Forms.CheckBox
$chkVerifyExists.Text = 'Verify files still exist before copying'
$chkVerifyExists.Location = New-Object System.Drawing.Point(310, 369)
$chkVerifyExists.AutoSize = $true
$chkVerifyExists.Checked = $true
$form.Controls.Add($chkVerifyExists)

# Off by default: hidden files (desktop.ini, Thumbs.db, dot-folders...)
# used to be skipped silently; now that is a visible choice. Changing it
# re-scans the source folder.
$chkHidden = New-Object System.Windows.Forms.CheckBox
$chkHidden.Text = 'Include hidden files'
$chkHidden.Location = New-Object System.Drawing.Point(310, 391)
$chkHidden.AutoSize = $true
$chkHidden.Checked = $false
$form.Controls.Add($chkHidden)

$lblRemoveList = New-Object System.Windows.Forms.Label
$lblRemoveList.Text = 'Files to remove if present (relative path per line, e.g. old\stale-file.txt):'
$lblRemoveList.Location = New-Object System.Drawing.Point(15, 425)
$lblRemoveList.AutoSize = $true
$form.Controls.Add($lblRemoveList)

$txtRemoveList = New-Object System.Windows.Forms.TextBox
$txtRemoveList.Location = New-Object System.Drawing.Point(15, 445)
$txtRemoveList.Size = New-Object System.Drawing.Size(530, 50)
$txtRemoveList.Multiline = $true
$txtRemoveList.ScrollBars = 'Vertical'
$form.Controls.Add($txtRemoveList)

$btnCopy = New-Object FlatButton
$btnCopy.Text = 'Copy selected'
$btnCopy.Location = New-Object System.Drawing.Point(15, 505)
$btnCopy.Size = New-Object System.Drawing.Size(530, 35)
$form.Controls.Add($btnCopy)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = 'Status: ready'
$lblStatus.Location = New-Object System.Drawing.Point(15, 550)
$lblStatus.Size = New-Object System.Drawing.Size(410, 20)
$lblStatus.AutoEllipsis = $true
$form.Controls.Add($lblStatus)

$btnViewReport = New-Object FlatButton
$btnViewReport.Text = 'View report'
$btnViewReport.Location = New-Object System.Drawing.Point(435, 546)
$btnViewReport.Size = New-Object System.Drawing.Size(110, 24)
$btnViewReport.Enabled = $false
$form.Controls.Add($btnViewReport)


# Two progress bars, told apart by colour AND lightness (a dark blue and a
# mid green, so they also differ in greyscale / for colour-blind eyes).
# Their captions say what they show while a copy runs: the blue one
# "Total: 33 of 69" (files x drives), the green one the name of the file
# being copied right now (the full path is in the status line above).
# FlatBar (defined at the top of this file) paints the colours and an
# outlined track itself, whatever the Windows theme happens to be.
$lblOverall = New-Object System.Windows.Forms.Label
$lblOverall.Text = 'Total'
$lblOverall.Location = New-Object System.Drawing.Point(15, 575)
$lblOverall.AutoSize = $false
$lblOverall.Size = New-Object System.Drawing.Size(150, 20)
$lblOverall.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$lblOverall.AutoEllipsis = $true
$lblOverall.UseMnemonic = $false
$form.Controls.Add($lblOverall)

$progressBar = New-Object FlatBar
$progressBar.Location = New-Object System.Drawing.Point(170, 575)
$progressBar.Size = New-Object System.Drawing.Size(375, 20)
$progressBar.Minimum = 0
$progressBar.BarColor = [System.Drawing.Color]::FromArgb(0, 80, 160)
$form.Controls.Add($progressBar)

$lblThisFile = New-Object System.Windows.Forms.Label
$lblThisFile.Text = 'File'
$lblThisFile.Location = New-Object System.Drawing.Point(15, 603)
$lblThisFile.AutoSize = $false
$lblThisFile.Size = New-Object System.Drawing.Size(150, 20)
$lblThisFile.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$lblThisFile.AutoEllipsis = $true
$lblThisFile.UseMnemonic = $false
$form.Controls.Add($lblThisFile)

$fileProgressBar = New-Object FlatBar
$fileProgressBar.Location = New-Object System.Drawing.Point(170, 603)
$fileProgressBar.Size = New-Object System.Drawing.Size(375, 20)
$fileProgressBar.Minimum = 0
$fileProgressBar.Maximum = 1000
$fileProgressBar.BarColor = [System.Drawing.Color]::FromArgb(20, 150, 60)
$form.Controls.Add($fileProgressBar)
# ---------- populate ----------

# Folders are real TreeNodes, collapsed by default (this can get deep
# and wide once the source folder holds a whole drive's worth of
# content - most of the time the operator just wants to tick a
# top-level folder and move on, not scan every file up front). A file
# leaf's own source-file object is stashed on its Tag; folder nodes
# have no Tag, which is how Get-CheckedFilesFromTree tells the two
# apart.
function Build-FileTree {
    $tvFiles.Nodes.Clear()
    $folderNodes = @{}
    foreach ($f in $script:sourceFiles) {
        $parts = $f.Label -split '\\'
        $parentNodes = $tvFiles.Nodes
        $pathSoFar = ''
        for ($i = 0; $i -lt $parts.Count - 1; $i++) {
            $pathSoFar = if ($pathSoFar) { "$pathSoFar\$($parts[$i])" } else { $parts[$i] }
            if (-not $folderNodes.ContainsKey($pathSoFar)) {
                $folderNode = New-Object System.Windows.Forms.TreeNode($parts[$i])
                $folderNode.Checked = $true
                [void]$parentNodes.Add($folderNode)
                $folderNodes[$pathSoFar] = $folderNode
            }
            $parentNodes = $folderNodes[$pathSoFar].Nodes
        }
        $fileNode = New-Object System.Windows.Forms.TreeNode($parts[-1])
        $fileNode.Tag = $f
        $fileNode.Checked = $true
        [void]$parentNodes.Add($fileNode)
    }
}

function Set-DescendantsChecked {
    param($Nodes, [bool]$Checked)
    foreach ($node in $Nodes) {
        $node.Checked = $Checked
        if ($node.Nodes.Count -gt 0) { Set-DescendantsChecked -Nodes $node.Nodes -Checked $Checked }
    }
}

function Set-AllTreeChecked {
    param([bool]$Checked)
    Set-DescendantsChecked -Nodes $tvFiles.Nodes -Checked $Checked
}

function Get-CheckedFilesFromTree {
    param($Nodes)
    $result = @()
    foreach ($node in $Nodes) {
        if ($node.Tag -and $node.Checked) { $result += $node.Tag }
        if ($node.Nodes.Count -gt 0) { $result += Get-CheckedFilesFromTree -Nodes $node.Nodes }
    }
    return $result
}

# Checking/unchecking a folder node (by mouse/keyboard - not the
# programmatic sets above, which report Action=Unknown and are left
# alone here) cascades the same state to everything under it.
$tvFiles.Add_AfterCheck({
    param($s, $e)
    if ($e.Action -eq [System.Windows.Forms.TreeViewAction]::Unknown) { return }
    Set-DescendantsChecked -Nodes $e.Node.Nodes -Checked $e.Node.Checked
    # ...and keep every parent folder in step with what is inside it:
    # ticked while anything in it is ticked, unticked once nothing is.
    $parent = $e.Node.Parent
    while ($parent) {
        $anyChecked = $false
        foreach ($child in $parent.Nodes) { if ($child.Checked) { $anyChecked = $true; break } }
        $parent.Checked = $anyChecked
        $parent = $parent.Parent
    }
})

function Refresh-FileList {
    $script:sourceFiles = @(Get-SourceFiles)
    Build-FileTree
    if (-not $script:sourceRoot) {
        $lblStatus.Text = 'Status: pick a source folder to begin'
    } elseif ($script:sourceFiles.Count -eq 0) {
        $lblStatus.Text = "Status: no files found under $($script:sourceRoot)"
    } else {
        $lblStatus.Text = "Status: found $($script:sourceFiles.Count) file(s) in $($script:sourceRoot)"
    }
}

# One relative path per line, blank lines ignored - e.g. "old\stale-file.txt".
function Get-CurrentRemoveList {
    @($txtRemoveList.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

function Save-CurrentSettings {
    Save-Settings -RootPath $script:sourceRoot -RemoveList (Get-CurrentRemoveList)
}

# Restore the last-picked source folder and remove-list if they're
# still there; otherwise leave it blank (prompting via Browse...).
$script:loadedSettings = Get-Settings
$script:sourceRoot = $script:loadedSettings.SourceRoot
$txtSourceRoot.Text = $script:sourceRoot
$txtRemoveList.Text = ($script:loadedSettings.RemoveList -join "`r`n")
Refresh-FileList

$btnBrowseSource.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Pick the folder whose contents get copied to the drive root'
    if ($script:sourceRoot) { $dlg.SelectedPath = $script:sourceRoot }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:sourceRoot = $dlg.SelectedPath
        $txtSourceRoot.Text = $script:sourceRoot
        Save-CurrentSettings
        Refresh-FileList
    }
})

$txtRemoveList.Add_Leave({ Save-CurrentSettings })

function Refresh-Drives {
    $clbDrives.Items.Clear()
    $script:drives = @(Get-TargetDrives)
    if ($script:drives.Count -eq 0) {
        $lblStatus.Text = 'Status: no removable drives found'
        return
    }
    foreach ($d in $script:drives) {
        [void]$clbDrives.Items.Add($d.Label, $true)
    }
    $lblStatus.Text = "Status: found $($script:drives.Count) drive(s)"
}

$btnRefresh.Add_Click({ Refresh-Drives })
$btnRefreshFiles.Add_Click({ Refresh-FileList })
$chkHidden.Add_CheckedChanged({ Refresh-FileList })
Refresh-Drives

function Set-AllChecked {
    param($ListBox, [bool]$Checked)
    for ($i = 0; $i -lt $ListBox.Items.Count; $i++) {
        $ListBox.SetItemChecked($i, $Checked)
    }
}

$btnFilesAll.Add_Click({ Set-AllTreeChecked -Checked $true })
$btnFilesNone.Add_Click({ Set-AllTreeChecked -Checked $false })
$btnDrivesAll.Add_Click({ Set-AllChecked $clbDrives $true })
$btnDrivesNone.Add_Click({ Set-AllChecked $clbDrives $false })

# While a copy is running, the DoEvents calls that keep the window
# responsive would also let every other button work - Refresh drives in
# particular rebuilds the drive list mid-copy, so "drive #2" could
# suddenly mean a different stick. So everything except the Copy button
# (which turns into Stop) is disabled for the duration.
$script:busy = $false
$script:cancelRequested = $false
$script:closeWhenDone = $false
$script:lockedControls = @(
    $btnBrowseSource, $tvFiles, $btnFilesAll, $btnFilesNone, $btnRefreshFiles,
    $clbDrives, $btnDrivesAll, $btnDrivesNone, $btnRefresh,
    $chkConfirm, $chkForce, $chkVerifyExists, $chkHidden, $txtRemoveList
)
function Set-Busy {
    param([bool]$Busy)
    $script:busy = $Busy
    foreach ($c in $script:lockedControls) { $c.Enabled = -not $Busy }
    $btnCopy.Text = if ($Busy) { 'Stop' } else { 'Copy selected' }
    $btnCopy.Enabled = $true
}

# Closing the window mid-copy would leave the loop below running against
# disposed controls. Ask it to stop cleanly (after the current file) and
# close once it has.
$form.Add_FormClosing({
    param($s, $e)
    if ($script:busy) {
        $e.Cancel = $true
        $script:cancelRequested = $true
        $script:closeWhenDone = $true
        $lblStatus.Text = 'Status: stopping after the current file, then closing...'
    } else {
        # The remove-list box only saves when it loses focus, which doesn't
        # happen if the window is closed while still typing in it.
        Save-CurrentSettings
    }
})

$btnCopy.Add_Click({
    if ($script:busy) {
        # The button reads "Stop" while a copy is running.
        $script:cancelRequested = $true
        $btnCopy.Enabled = $false
        $lblStatus.Text = 'Status: stopping after the current file...'
        return
    }
    if (-not $script:sourceRoot -or -not (Test-Path -LiteralPath $script:sourceRoot)) {
        $lblStatus.Text = 'Status: ERROR - pick a valid source folder first'
        return
    }

    # @() forces an array even with zero or one matches - without it, a
    # single checked item at index 0 becomes the bare integer 0, and
    # "-not 0" is true in PowerShell, wrongly reading as "nothing
    # checked". Checking .Count instead of truthiness sidesteps that.
    $checkedFiles = @(Get-CheckedFilesFromTree -Nodes $tvFiles.Nodes)
    $checkedDriveIdx = @($clbDrives.CheckedIndices | ForEach-Object { $_ })

    if ($checkedFiles.Count -eq 0) {
        $lblStatus.Text = 'Status: nothing checked in the files list'
        return
    }
    if ($checkedDriveIdx.Count -eq 0) {
        $lblStatus.Text = 'Status: nothing checked in the drives list'
        return
    }

    # Catches a file that was checked earlier in this session but has
    # since been deleted/renamed on disk - the tree only re-scans on
    # startup, Browse..., or Refresh files, so without this the first
    # sign of trouble would otherwise be a failure deep inside the copy
    # loop below, for a less clear reason.
    if ($chkVerifyExists.Checked) {
        $missing = @($checkedFiles | Where-Object { -not (Test-Path -LiteralPath $_.Full) })
        if ($missing.Count -gt 0) {
            $missingList = ($missing | ForEach-Object { $_.Label }) -join "`n"
            [System.Windows.Forms.MessageBox]::Show(
                "$($missing.Count) checked file(s) no longer exist at the source:`n`n$missingList`n`nClick Refresh files, then re-check what you need.",
                'Missing file(s)', 'OK', 'Warning')
            $lblStatus.Text = "Status: $($missing.Count) checked file(s) missing - refresh and re-check"
            return
        }
    }

    # Scan every checked drive for the explicit remove-list entries
    # (relative paths, e.g. "old\stale-file.txt") that actually exist
    # there - only these exact, hand-listed files are ever candidates
    # for deletion, never a computed "anything not in source" diff.
    $removeList = Get-CurrentRemoveList
    $removalPlan = @()
    if ($removeList.Count -gt 0) {
        foreach ($idx in $checkedDriveIdx) {
            $drive = $script:drives[$idx]
            foreach ($relPath in $removeList) {
                $fullPath = Join-Path $drive.Root $relPath
                if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
                    $removalPlan += [PSCustomObject]@{ DriveIdx = $idx; Drive = $drive.Root; RelPath = $relPath; FullPath = $fullPath }
                }
            }
        }
    }

    # Deletion always gets its own explicit confirmation, regardless of
    # "Confirm before copying" - naming exactly what will be removed,
    # on which drive, before anything is touched. Declining this only
    # skips the removal step; the copy below still goes ahead.
    $script:doRemoval = $false
    if ($removalPlan.Count -gt 0) {
        $removalBlocks = $removalPlan | Group-Object Drive | ForEach-Object {
            "$($_.Name):`n  " + (($_.Group | ForEach-Object { $_.RelPath }) -join "`n  ")
        }
        $removalMsg = "The following file(s) will be permanently deleted:`n`n$($removalBlocks -join "`n`n")"
        $removalResult = [System.Windows.Forms.MessageBox]::Show($removalMsg, 'Confirm deletion', 'YesNo', 'Warning')
        $script:doRemoval = ($removalResult -eq 'Yes')
    }

    if ($chkConfirm.Checked) {
        $driveList = ($checkedDriveIdx | ForEach-Object { $script:drives[$_].Root }) -join "`n"
        $fileList = ($checkedFiles | ForEach-Object { $_.Label }) -join "`n"
        $msg = "Copy $($checkedFiles.Count) file(s):`n$fileList`n`nTo $($checkedDriveIdx.Count) drive(s):`n$driveList"
        $result = [System.Windows.Forms.MessageBox]::Show($msg, 'Confirm copy', 'YesNo', 'Question')
        if ($result -ne 'Yes') {
            $lblStatus.Text = 'Status: cancelled'
            return
        }
    }

    # Snapshot exactly which drives this run targets (root path + row in
    # the list), so nothing that happens later can change what "drive N"
    # means. With 'Stop', any error in a cmdlet below becomes a caught
    # exception for that drive instead of being silently swallowed.
    $ErrorActionPreference = 'Stop'
    $driveJobs = @($checkedDriveIdx | ForEach-Object { [PSCustomObject]@{ Idx = $_; Drive = $script:drives[$_] } })

    $script:cancelRequested = $false
    Set-Busy $true
    $report = @()
    $removeReport = @()
    $driveErrors = @()
    $totalOps = $checkedFiles.Count * $driveJobs.Count
    $doneOps = 0
    $progressBar.Value = 0
    $progressBar.Maximum = [Math]::Max($totalOps, 1)
    $lblOverall.Text = "Total: 0 of $totalOps"
    $lblThisFile.Text = 'File'

    # Reset every checked drive's list text back to its plain label -
    # in case this is a second run and some still say "[DONE]" from
    # before.
    foreach ($job in $driveJobs) {
        $clbDrives.Items[$job.Idx] = $job.Drive.Label
    }

    try {
        foreach ($job in $driveJobs) {
            if ($script:cancelRequested) { break }
            $idx = $job.Idx
            $drive = $job.Drive
            $destRoot = $drive.Root
            $driveBase = $doneOps
            $currentItem = ''
            $clbDrives.Items[$idx] = "$($drive.Label)  [copying]"

            # A failure on one drive (pulled out, full, file too big for
            # FAT32, locked file...) ends that drive only - it's marked
            # [FAILED], the reason goes into the report, and the next
            # drive carries on. The window never gets stuck.
            try {
                if ($script:doRemoval) {
                    foreach ($r in @($removalPlan | Where-Object { $_.DriveIdx -eq $idx })) {
                        $currentItem = "remove $($r.RelPath)"
                        $lblStatus.Text = "Status: removing $($r.RelPath) from $($drive.Root)"
                        [System.Windows.Forms.Application]::DoEvents()
                        Remove-Item -LiteralPath $r.FullPath -Force -ErrorAction Stop
                        $removeReport += [PSCustomObject]@{ Drive = $drive.Root; File = $r.RelPath }
                    }
                }
                foreach ($f in $checkedFiles) {
                    if ($script:cancelRequested) { break }
                    $currentItem = $f.Label
                    $doneOps++
                    $lblOverall.Text = "Total: $doneOps of $totalOps"
                    $lblThisFile.Text = [System.IO.Path]::GetFileName($f.Label)
                    $lblStatus.Text = "Status: copying $doneOps of $totalOps - $($drive.Root) - $($f.Label)"
                    [System.Windows.Forms.Application]::DoEvents()

                    $destPath = Join-Path $destRoot $f.DestRelative
                    $destDir = Split-Path $destPath -Parent
                    if (-not (Test-Path -LiteralPath $destDir)) { [void][System.IO.Directory]::CreateDirectory($destDir) }
                    # Leftover from an earlier interrupted run.
                    if ([System.IO.File]::Exists("$destPath.msync-part")) { [System.IO.File]::Delete("$destPath.msync-part") }

                    $onProgress = {
                        param($frac)
                        $fileProgressBar.Value = [Math]::Min([int]($frac * 1000), 1000)
                        [System.Windows.Forms.Application]::DoEvents()
                    }

                    $fileProgressBar.Value = 0
                    $action = 'copied (new file)'
                    if (Test-Path -LiteralPath $destPath) {
                        if ((Get-Item -LiteralPath $f.Full).Length -ne (Get-Item -LiteralPath $destPath).Length) {
                            # Different size - can't be identical, no need to read both files end to end.
                            $action = 'replaced (was different)'
                        } else {
                            $lblStatus.Text = "Status: hashing $doneOps of $totalOps (source) - $($f.Label)"
                            $srcHash = Get-FileHashChunked -Path $f.Full -OnProgress $onProgress
                            $fileProgressBar.Value = 0
                            $lblStatus.Text = "Status: hashing $doneOps of $totalOps (destination) - $($f.Label)"
                            $dstHash = Get-FileHashChunked -Path $destPath -OnProgress $onProgress
                            if ($srcHash -eq $dstHash) {
                                $action = if ($chkForce.Checked) { 'identical, re-copied anyway (forced)' } else { 'identical, skipped' }
                            } else {
                                $action = 'replaced (was different)'
                            }
                        }
                    }
                    if ($action -ne 'identical, skipped') {
                        $fileProgressBar.Value = 0
                        $lblStatus.Text = "Status: copying $doneOps of $totalOps - $($drive.Root) - $($f.Label)"
                        Copy-FileChunked -SourcePath $f.Full -DestPath $destPath -OnProgress $onProgress
                    }
                    $report += [PSCustomObject]@{ Drive = $drive.Root; File = $f.Label; Action = $action }

                    $fileProgressBar.Value = 1000
                    $progressBar.Value = $doneOps
                    [System.Windows.Forms.Application]::DoEvents()
                }
            } catch {
                $driveErrors += [PSCustomObject]@{ Drive = $drive.Root; File = $currentItem; Error = $_.Exception.Message }
                $clbDrives.Items[$idx] = "$($drive.Label)  [FAILED]"
                # Count this drive's remaining files as handled so the
                # overall bar still ends at 100% for the run.
                $doneOps = $driveBase + $checkedFiles.Count
                $progressBar.Value = [Math]::Min($doneOps, $progressBar.Maximum)
                $lblStatus.Text = "Status: $($drive.Root) FAILED - $($_.Exception.Message)"
                continue
            }

            if ($script:cancelRequested) {
                $lblStatus.Text = "Status: stopped at $($drive.Root)"
                $clbDrives.Items[$idx] = "$($drive.Label)  [stopped]"
                break
            }

            # Sequential drives, one at a time - once every checked file for
            # this drive is written, it's done. Each file is flushed to the
            # drive as it's finished, but that still isn't a claim it's safe
            # to unplug - that depends on this machine's write-caching policy
            # for removable media, which isn't checked here. Held on screen
            # briefly, with the UI still responsive, rather than flashing by
            # instantly before the next drive starts.
            $lblStatus.Text = "Status: $($drive.Root) done"
            $clbDrives.Items[$idx] = "$($drive.Label)  [DONE]"
            $waitUntil = (Get-Date).AddMilliseconds(500)
            while ((Get-Date) -lt $waitUntil) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 50
            }
        }
    } finally {
        Set-Busy $false
    }

    $copiedCount = @($report | Where-Object { $_.Action -ne 'identical, skipped' }).Count
    $skippedCount = @($report | Where-Object { $_.Action -eq 'identical, skipped' }).Count
    $removedNote = if ($removeReport.Count -gt 0) { ", $($removeReport.Count) removed" } else { '' }
    $failedNote = if ($driveErrors.Count -gt 0) { ", $($driveErrors.Count) drive(s) FAILED" } else { '' }
    $verb = if ($script:cancelRequested) { 'stopped before finishing' } else { 'done' }
    $lblStatus.Text = "Status: $verb - $copiedCount copied/re-copied, $skippedCount identical/skipped$removedNote$failedNote"

    # Grouped by drive, one block each - only names files that actually
    # changed; identical files collapse to a count instead of one line
    # per file, so a 9-files x 10-drives run stays a screenful, not 90
    # lines to scroll through.
    $reportLines = @()
    foreach ($job in $driveJobs) {
        $driveRoot = $job.Drive.Root
        $driveRows = @($report | Where-Object { $_.Drive -eq $driveRoot })
        $driveRemovals = @($removeReport | Where-Object { $_.Drive -eq $driveRoot })
        $driveFailure = @($driveErrors | Where-Object { $_.Drive -eq $driveRoot }) | Select-Object -First 1
        $reportLines += "=== $driveRoot ==="
        if ($driveFailure) {
            $where = if ($driveFailure.File) { " at $($driveFailure.File)" } else { '' }
            $reportLines += "  FAILED$where`: $($driveFailure.Error)"
            $reportLines += '  (the remaining files were not copied to this drive)'
        }
        if ($driveRemovals.Count -gt 0) { $reportLines += "  removed: $(($driveRemovals | ForEach-Object { $_.File }) -join ', ')" }

        $newFiles = @($driveRows | Where-Object { $_.Action -eq 'copied (new file)' })
        $replacedFiles = @($driveRows | Where-Object { $_.Action -eq 'replaced (was different)' })
        $forcedFiles = @($driveRows | Where-Object { $_.Action -eq 'identical, re-copied anyway (forced)' })
        $identicalCount = @($driveRows | Where-Object { $_.Action -eq 'identical, skipped' }).Count

        if ($newFiles.Count -gt 0) { $reportLines += "  new: $(($newFiles | ForEach-Object { $_.File }) -join ', ')" }
        if ($replacedFiles.Count -gt 0) { $reportLines += "  replaced: $(($replacedFiles | ForEach-Object { $_.File }) -join ', ')" }
        if ($forcedFiles.Count -gt 0) { $reportLines += "  re-copied (forced, was identical): $(($forcedFiles | ForEach-Object { $_.File }) -join ', ')" }
        if ($driveRows.Count -eq 0) {
            if (-not $driveFailure) { $reportLines += '  nothing done on this drive' }
        } elseif ($identicalCount -eq $driveRows.Count) {
            $reportLines += "  all $identicalCount file(s) already identical (unchanged)"
        } elseif ($identicalCount -gt 0) {
            $reportLines += "  $identicalCount file(s) already identical (unchanged)"
        }
        $reportLines += ''
    }
    $script:lastReportText = $reportLines -join "`r`n"

    # Nothing to look at if every file everywhere was already identical
    # and nothing was removed or failed either - leave the button
    # disabled rather than opening a window that would just say so in
    # different words than the status line already did.
    $btnViewReport.Enabled = ($copiedCount -gt 0) -or ($removeReport.Count -gt 0) -or ($driveErrors.Count -gt 0)

    if ($driveErrors.Count -gt 0) {
        $errLines = $driveErrors | ForEach-Object {
            $at = if ($_.File) { " ($($_.File))" } else { '' }
            "$($_.Drive)$at`n    $($_.Error)"
        }
        [System.Windows.Forms.MessageBox]::Show(
            "$($driveErrors.Count) drive(s) had a problem and were not finished:`n`n$($errLines -join "`n`n")`n`nThe other drives were not affected. See View report for details.",
            'Copy problems', 'OK', 'Warning') | Out-Null
    }
    if ($script:closeWhenDone) { $form.Close() }
})
$btnViewReport.Add_Click({
    $reportForm = New-Object System.Windows.Forms.Form
    $reportForm.Text = 'Copy report'
    $reportForm.Size = New-Object System.Drawing.Size([int](560 * $script:dpiK), [int](400 * $script:dpiK))
    $reportForm.StartPosition = 'CenterScreen'
    $reportBox = New-Object System.Windows.Forms.TextBox
    $reportBox.Multiline = $true
    $reportBox.ReadOnly = $true
    $reportBox.ScrollBars = 'Vertical'
    $reportBox.Dock = 'Fill'
    # A read-only multiline box selects all its text when it first gets
    # focus, so the report opened as one big blue block.
    $reportBox.TabStop = $false
    $reportBox.Font = New-Object System.Drawing.Font('Consolas', 10)
    $reportBox.Text = $script:lastReportText
    $reportForm.Controls.Add($reportBox)
    # Non-modal (.Show, not .ShowDialog) - stays open and readable
    # alongside the main window instead of blocking it.
    $reportForm.Show()
    $reportBox.Select(0, 0)
})

# Everything above is laid out in 96-DPI pixels. Text is already crisp and
# scaled (DPI-aware process), so scale the pixel geometry to match it.
function Set-ScaledLayout {
    param($Container, [double]$K)
    foreach ($c in $Container.Controls) {
        $c.Location = New-Object System.Drawing.Point([int][Math]::Round($c.Left * $K), [int][Math]::Round($c.Top * $K))
        # Labels and checkboxes size themselves from their text.
        if (-not ($c.AutoSize -and ($c -is [System.Windows.Forms.Label] -or $c -is [System.Windows.Forms.CheckBox]))) {
            $c.Size = New-Object System.Drawing.Size([int][Math]::Round($c.Width * $K), [int][Math]::Round($c.Height * $K))
        }
    }
}
if ($script:dpiK -gt 1.01) {
    Set-ScaledLayout $form $script:dpiK
    $form.ClientSize = New-Object System.Drawing.Size([int][Math]::Round($form.ClientSize.Width * $script:dpiK), [int][Math]::Round($form.ClientSize.Height * $script:dpiK))
}

[void]$form.ShowDialog()
