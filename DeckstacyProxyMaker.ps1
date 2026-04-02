Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ==============================
# CONFIG / THEME
# ==============================
$AppConfig = [ordered]@{
    AppName = 'Deckstacy Proxy Maker'
    Subtitle = 'Local MTG deck image workflow with persistent master cache'
    ScryfallSearchUrl = 'https://api.scryfall.com/cards/named?fuzzy='
    HttpTimeoutSeconds = 30
    RetryPasses = 3
    RetryBaseDelayMs = 500
    RetryMaxDelayMs = 8000
    RetryJitterMs = 350
    RetryBudgetMs = 20000
    LiveParseDebounceMs = 350
    MaxParallelDownloads = 4
    RunFolderFormat = 'yyyyMMdd_HHmmss'
}

$Theme = [ordered]@{
    Back = [System.Drawing.Color]::FromArgb(18, 22, 28)
    Panel = [System.Drawing.Color]::FromArgb(25, 31, 39)
    Panel2 = [System.Drawing.Color]::FromArgb(30, 37, 47)
    Fore = [System.Drawing.Color]::FromArgb(228, 235, 245)
    Muted = [System.Drawing.Color]::FromArgb(145, 157, 173)
    Accent = [System.Drawing.Color]::FromArgb(0, 210, 255)
    Accent2 = [System.Drawing.Color]::FromArgb(156, 107, 255)
    Success = [System.Drawing.Color]::FromArgb(69, 201, 120)
    Warn = [System.Drawing.Color]::FromArgb(240, 182, 72)
    Danger = [System.Drawing.Color]::FromArgb(240, 90, 90)
}

$Script:KnownHeaders = @('Commander','Creatures','Instants','Sorceries','Artifacts','Enchantments','Planeswalkers','Lands','Sideboard','Maybeboard')
$Script:Ui = @{}
$Script:RunState = @{}
$Script:UiScale = 1.0
$Script:UiPrefsPath = Join-Path $env:LOCALAPPDATA 'DeckstacyProxyMaker\ui_prefs.json'

function Get-UiScaleFactor {
    [CmdletBinding()]
    param(
        [System.Windows.Forms.Form]$Form
    )

    if ($null -ne $Form -and $Form -is [System.Windows.Forms.Form]) {
        try {
            if ($Form.DeviceDpi -gt 0) {
                return ([Math]::Max(1.0, [Math]::Min(2.0, $Form.DeviceDpi / 96.0)))
            }
        }
        catch {
            # fall through to graphics-based probe
        }
    }

    $graphics = $null
    try {
        $graphics = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
        if ($null -ne $graphics -and $graphics.DpiX -gt 0) {
            return ([Math]::Max(1.0, [Math]::Min(2.0, $graphics.DpiX / 96.0)))
        }
    }
    finally {
        if ($null -ne $graphics) {
            $graphics.Dispose()
        }
    }

    return 1.0
}

function Scale-UiValue {
    [CmdletBinding()]
    param(
        [double]$Value,
        [int]$Min = 0
    )
    $scaled = [int][Math]::Round($Value * $Script:UiScale)
    if ($scaled -lt $Min) {
        return $Min
    }
    return $scaled
}

function Get-UiPreferences {
    [CmdletBinding()]
    param()
    return (Load-JsonOrDefault -Path $Script:UiPrefsPath -Default @{})
}

function Save-UiPreferences {
    [CmdletBinding()]
    param([hashtable]$Values)
    Ensure-Directory -Path (Split-Path -Parent $Script:UiPrefsPath) | Out-Null
    Save-Json -InputObject $Values -Path $Script:UiPrefsPath
    return
}

function Get-IntPreference {
    [CmdletBinding()]
    param(
        [object]$Value,
        [int]$Fallback
    )
    $parsed = 0
    if ($null -ne $Value -and [int]::TryParse($Value.ToString(), [ref]$parsed)) {
        return $parsed
    }
    return $Fallback
}

function Set-SectionCollapsedState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$SectionPanel,
        [bool]$Collapsed
    )
    if ($null -ne $SectionPanel -and $null -ne $SectionPanel.Tag -and $SectionPanel.Tag.ContainsKey('SetCollapsed')) {
        & $SectionPanel.Tag.SetCollapsed $Collapsed
    }
$Script:UiState = 'idle'
$Script:RunState = @{
    CancelRequested = $false
    IsRunning = $false
}

# ==============================
# HELPERS (NO PIPELINE LEAKAGE)
# ==============================
function Get-NowText {
    [CmdletBinding()]
    param()
    return [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
}

function Write-UiLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Message,
        [string]$Level = 'INFO'
    )
    $line = "[$(Get-NowText)] [$Level] $Message"
    if ($Script:Ui.ContainsKey('txtActivity') -and $null -ne $Script:Ui.txtActivity) {
        Invoke-UiThread -Action {
            $tb = [System.Windows.Forms.TextBox]$Script:Ui.txtActivity
            if ($tb.IsHandleCreated) {
                $tb.AppendText($line + [Environment]::NewLine)
            }
        }
    }
    if ($Script:RunState.ContainsKey('DiagnosticPath') -and -not [string]::IsNullOrWhiteSpace($Script:RunState.DiagnosticPath)) {
        Add-Content -Path $Script:RunState.DiagnosticPath -Value $line -Encoding UTF8
    }
    if ($Script:RunState.ContainsKey('DownloadLogPath') -and -not [string]::IsNullOrWhiteSpace($Script:RunState.DownloadLogPath)) {
        # only write command/download level rows elsewhere
    }
    return
}

function Invoke-UiThread {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Action)

    $target = if ($Script:Ui.ContainsKey('form')) { $Script:Ui.form } else { $null }
    if ($null -ne $target -and $target.IsHandleCreated -and -not $target.IsDisposed) {
        if ($target.InvokeRequired) {
            [void]$target.BeginInvoke([System.Windows.Forms.MethodInvoker]{
                & $Action
            })
        }
        else {
            & $Action
        }
    }
    else {
        & $Action
    }
    return
}

function Set-StatusText {
    [CmdletBinding()]
    param([string]$Text)
    if ($Script:Ui.ContainsKey('lblBottomStatus')) {
        Invoke-UiThread -Action {
            $Script:Ui.lblBottomStatus.Text = $Text
        }
    }
    return
}

function Set-PhaseText {
    [CmdletBinding()]
    param([string]$Text)
    if ($Script:Ui.ContainsKey('lblPhase')) {
        Invoke-UiThread -Action {
            $Script:Ui.lblPhase.Text = "Phase: $Text"
        }
    }
    return
}

function Set-Progress {
    [CmdletBinding()]
    param([int]$Value)
    if ($Script:Ui.ContainsKey('pbPhase')) {
        $bounded = [Math]::Max(0, [Math]::Min(100, $Value))
        $Script:Ui.pbPhase.Value = $bounded
    }
    return
}

function Set-BottomProgress {
    [CmdletBinding()]
    param([int]$Value)
    if ($Script:Ui.ContainsKey('pbBottom')) {
        $bounded = [Math]::Max(0, [Math]::Min(100, $Value))
        $Script:Ui.pbBottom.Value = $bounded
    if ($Script:Ui.ContainsKey('pbRun')) {
        Invoke-UiThread -Action {
            $bounded = [Math]::Max(0, [Math]::Min(100, $Value))
            $Script:Ui.pbRun.Value = $bounded
        }
    }
    return
}

function Set-ExecutionControlsEnabled {
    [CmdletBinding()]
    param([bool]$Enabled)

    $keys = @(
        'txtDeckName','txtRootFolder','cbImageType','txtPreferredSet','chkOnlyMissing','chkRepairMode',
        'btnBrowse','btnLoad','btnAutoName','btnTestApi','btnRefreshIndex','txtDecklist'
    )
    Invoke-UiThread -Action {
        foreach ($key in $keys) {
            if ($Script:Ui.ContainsKey($key) -and $null -ne $Script:Ui[$key]) {
                $Script:Ui[$key].Enabled = $Enabled
            }
        }
    }
    return
}

function New-ProgressReporter {
    [CmdletBinding()]
    param()

    return {
        param(
            [string]$PhaseText,
            [Nullable[int]]$Percent,
            [string]$StatusMessage,
            [string]$LogMessage,
            [string]$LogLevel = 'INFO'
        )
        if (-not [string]::IsNullOrWhiteSpace($PhaseText)) { Set-PhaseText -Text $PhaseText }
        if ($Percent.HasValue) { Set-Progress -Value $Percent.Value }
        if (-not [string]::IsNullOrWhiteSpace($StatusMessage)) { Set-StatusText -Text $StatusMessage }
        if (-not [string]::IsNullOrWhiteSpace($LogMessage)) { Write-UiLog -Message $LogMessage -Level $LogLevel }
    }
}

function Report-ProgressUpdate {
    [CmdletBinding()]
    param(
        [scriptblock]$Reporter,
        [string]$PhaseText,
        [Nullable[int]]$Percent,
        [string]$StatusMessage,
        [string]$LogMessage,
        [string]$LogLevel = 'INFO'
    )
    if ($null -ne $Reporter) {
        & $Reporter -PhaseText $PhaseText -Percent $Percent -StatusMessage $StatusMessage -LogMessage $LogMessage -LogLevel $LogLevel
    }
    return
}

function Pump-UiEvents {
    [CmdletBinding()]
    param()
    [System.Windows.Forms.Application]::DoEvents()
    return
}

function Reset-RunCancellation {
    [CmdletBinding()]
    param()
    $Script:RunState.CancelRequested = $false
    return
}

function Request-RunCancellation {
    [CmdletBinding()]
    param()
    if (-not $Script:RunState.CancelRequested) {
        $Script:RunState.CancelRequested = $true
        Write-UiLog -Message 'Cancellation requested. Finishing current step and writing partial output.' -Level 'WARN'
    }
    return
}

function Get-StatePreflightText {
    [CmdletBinding()]
    param([string]$State)

    switch ($State) {
        'idle' {
            return @(
                'No preflight data yet.',
                '',
                'Next steps:',
                '  1) Paste or load a decklist.',
                '  2) Enter Deck Name and Root Folder.',
                '  3) Run validation (auto) or click Download Images.'
            ) -join [Environment]::NewLine
        }
        'validating' {
            return @(
                'Validating decklist and storage settings...',
                'Checking parsed lines, unique cards, and cache availability.'
            ) -join [Environment]::NewLine
        }
        'ready' {
            return @(
                'Preflight complete.',
                'Deck is ready to run.'
            ) -join [Environment]::NewLine
        }
        'running' {
            return @(
                'Run in progress...',
                'Resolving cache, downloading missing assets, and finalizing manifests.'
            ) -join [Environment]::NewLine
        }
        'error' {
            return @(
                'Action failed before completion.',
                'Review Activity Log, correct inputs, and try again.'
            ) -join [Environment]::NewLine
        }
        'completed' {
            return @(
                'Run completed.',
                'Review summary stats and output folder paths in the Activity Log.'
            ) -join [Environment]::NewLine
        }
        default {
            return 'Unknown state.'
        }
    }
}

function Set-UiState {
    [CmdletBinding()]
    param([string]$State)

    $stateKey = $State.ToLowerInvariant()
    $Script:UiState = $stateKey

    $phaseMap = @{
        idle = 'Idle'
        validating = 'Validating'
        ready = 'Ready'
        running = 'Running'
        error = 'Error'
        completed = 'Completed'
    }

    if ($phaseMap.ContainsKey($stateKey)) {
        Set-PhaseText -Text $phaseMap[$stateKey]
    }

    if ($Script:Ui.ContainsKey('txtPreflight')) {
        $current = [string]$Script:Ui.txtPreflight.Text
        $hasPreflightData = $current -match 'Parsed cards:\s*\d+'
        if (-not $hasPreflightData -or @('idle','validating','error','completed') -contains $stateKey) {
            $Script:Ui.txtPreflight.Text = Get-StatePreflightText -State $stateKey
        }
    }

    $labelMap = @{
        idle = @{
            Parsed = 'Parsed (pending)'
            Cached = 'Cached (pending)'
            Copied = 'Copied (pending)'
            Downloaded = 'Downloaded (pending)'
            Skipped = 'Skipped (pending)'
            Repaired = 'Repaired (pending)'
            Reviewed = 'Reviewed (pending)'
            Failed = 'Failed (pending)'
        }
        validating = @{
            Parsed = 'Parsed (check)'
            Cached = 'Cache Hits (check)'
            Copied = 'Copied (run)'
            Downloaded = 'Downloaded (run)'
            Skipped = 'Skipped (run)'
            Repaired = 'Repaired (run)'
            Reviewed = 'Reviewed (run)'
            Failed = 'Failed (check)'
        }
        ready = @{
            Parsed = 'Parsed'
            Cached = 'Cache Hits'
            Copied = 'Copied'
            Downloaded = 'Downloaded'
            Skipped = 'Skipped'
            Repaired = 'Repaired'
            Reviewed = 'Reviewed'
            Failed = 'Failed'
        }
        running = @{
            Parsed = 'Parsed (active)'
            Cached = 'Cached (active)'
            Copied = 'Copied (active)'
            Downloaded = 'Downloaded (active)'
            Skipped = 'Skipped (active)'
            Repaired = 'Repaired (active)'
            Reviewed = 'Reviewed (active)'
            Failed = 'Failed (active)'
        }
        error = @{
            Parsed = 'Parsed (last)'
            Cached = 'Cached (last)'
            Copied = 'Copied (last)'
            Downloaded = 'Downloaded (last)'
            Skipped = 'Skipped (last)'
            Repaired = 'Repaired (last)'
            Reviewed = 'Reviewed (last)'
            Failed = 'Failed (last)'
        }
        completed = @{
            Parsed = 'Parsed (final)'
            Cached = 'Cached (final)'
            Copied = 'Copied (final)'
            Downloaded = 'Downloaded (final)'
            Skipped = 'Skipped (final)'
            Repaired = 'Repaired (final)'
            Reviewed = 'Reviewed (final)'
            Failed = 'Failed (final)'
        }
    }

    if ($labelMap.ContainsKey($stateKey)) {
        foreach ($k in $labelMap[$stateKey].Keys) {
            $nameKey = "lblStatName$k"
            if ($Script:Ui.ContainsKey($nameKey)) {
                $Script:Ui[$nameKey].Text = $labelMap[$stateKey][$k]
            }
        }
    }
    return
function Test-RunCancellation {
    [CmdletBinding()]
    param()
    Pump-UiEvents
    return [bool]$Script:RunState.CancelRequested
}

function Ensure-Directory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        [void](New-Item -Path $Path -ItemType Directory -Force)
    }
    return $Path
}

function Save-Json {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Path
    )
    $json = $InputObject | ConvertTo-Json -Depth 16
    Set-Content -Path $Path -Value $json -Encoding UTF8
    return
}

function Load-JsonOrDefault {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Default
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return $Default
    }
    try {
        $raw = Get-Content -Path $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $Default
        }
        return ($raw | ConvertFrom-Json)
    }
    catch {
        $msg = $_.Exception.Message
        if (-not $Script:RunState.ContainsKey('GlobalFailures')) {
            $Script:RunState.GlobalFailures = New-Object 'System.Collections.Generic.List[object]'
        }
        $Script:RunState.GlobalFailures.Add([pscustomobject]@{
            Name = 'GLOBAL: metadata'
            FailureType = 'json_corruption'
            Detail = ("{0} ({1})" -f $Path, $msg)
        })
        Write-UiLog -Message "Detected JSON corruption in $Path. Loading defaults. Suggested next action: restore or delete/rebuild the corrupted JSON file." -Level 'WARN'
        return $Default
    }
}

function New-StyledLabel {
    [CmdletBinding()]
    param(
        [string]$Text,
        [float]$Size = 9,
        [bool]$Bold = $false,
        [System.Drawing.Color]$Color = $Theme.Fore,
        [System.Windows.Forms.DockStyle]$Dock = [System.Windows.Forms.DockStyle]::Fill,
        [System.Drawing.ContentAlignment]$Align = [System.Drawing.ContentAlignment]::MiddleLeft
    )
    $lbl = [System.Windows.Forms.Label]::new()
    $lbl.Text = $Text
    $lbl.ForeColor = $Color
    $lbl.Dock = $Dock
    $lbl.TextAlign = $Align
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $lbl.Font = [System.Drawing.Font]::new('Segoe UI', ($Size * $Script:UiScale), $style)
    return $lbl
}

function New-StyledTextBox {
    [CmdletBinding()]
    param(
        [string]$Text = '',
        [bool]$Multiline = $false,
        [bool]$ReadOnly = $false
    )
    $tb = [System.Windows.Forms.TextBox]::new()
    $tb.Text = $Text
    $tb.Multiline = $Multiline
    $tb.ReadOnly = $ReadOnly
    $tb.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $tb.BackColor = [System.Drawing.Color]::FromArgb(21, 26, 33)
    $tb.ForeColor = $Theme.Fore
    $tb.Font = [System.Drawing.Font]::new('Segoe UI', (10 * $Script:UiScale))
    $tb.Dock = [System.Windows.Forms.DockStyle]::Fill
    if ($Multiline) {
        $tb.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
        $tb.AcceptsReturn = $true
        $tb.AcceptsTab = $true
        $tb.WordWrap = $false
    }
    return $tb
}

function New-StyledButton {
    [CmdletBinding()]
    param(
        [string]$Text,
        [bool]$Primary = $false,
        [int]$Width = 110
    )
    $btn = [System.Windows.Forms.Button]::new()
    $btn.Text = $Text
    $btn.Width = $Width
    $btn.Height = Scale-UiValue -Value 32 -Min 28
    $btn.Margin = [System.Windows.Forms.Padding]::new((Scale-UiValue -Value 4))
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize = 1
    $btn.Font = [System.Drawing.Font]::new('Segoe UI', (9 * $Script:UiScale), [System.Drawing.FontStyle]::Bold)
    if ($Primary) {
        $btn.BackColor = $Theme.Accent
        $btn.ForeColor = [System.Drawing.Color]::Black
        $btn.FlatAppearance.BorderColor = $Theme.Accent
    }
    else {
        $btn.BackColor = [System.Drawing.Color]::FromArgb(37, 45, 58)
        $btn.ForeColor = $Theme.Fore
        $btn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(65, 77, 95)
    }
    return $btn
}

function New-SectionPanel {
    [CmdletBinding()]
    param(
        [string]$Title,
        [bool]$Collapsible = $false,
        [bool]$StartCollapsed = $false
    )
    $panel = [System.Windows.Forms.Panel]::new()
    $panel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $panel.BackColor = $Theme.Panel
    $panel.Padding = [System.Windows.Forms.Padding]::new((Scale-UiValue -Value 10))

    $inner = [System.Windows.Forms.TableLayoutPanel]::new()
    $inner.Dock = [System.Windows.Forms.DockStyle]::Fill
    $inner.ColumnCount = 1
    $inner.RowCount = 2
    $inner.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
    $inner.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
    $titleRow = [System.Windows.Forms.TableLayoutPanel]::new()
    $titleRow.Dock = [System.Windows.Forms.DockStyle]::Fill
    $titleRow.AutoSize = $true
    $titleRow.ColumnCount = 2
    $titleRow.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
    $titleRow.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
    $titleLbl = New-StyledLabel -Text $Title -Size 10 -Bold $true -Color $Theme.Accent2
    $titleLbl.AutoSize = $true
    $titleLbl.Margin = [System.Windows.Forms.Padding]::new(0, 0, 0, (Scale-UiValue -Value 4))
    $toggleBtn = [System.Windows.Forms.Button]::new()
    $toggleBtn.Text = "▾"
    $toggleBtn.Visible = $Collapsible
    $toggleBtn.AutoSize = $true
    $toggleBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $toggleBtn.FlatAppearance.BorderSize = 0
    $toggleBtn.BackColor = $Theme.Panel
    $toggleBtn.ForeColor = $Theme.Accent2
    $toggleBtn.Margin = [System.Windows.Forms.Padding]::new(0)
    $toggleBtn.Padding = [System.Windows.Forms.Padding]::new((Scale-UiValue -Value 4), 0, (Scale-UiValue -Value 4), 0)
    $toggleBtn.Font = [System.Drawing.Font]::new('Segoe UI', (9.5 * $Script:UiScale), [System.Drawing.FontStyle]::Bold)
    $content = [System.Windows.Forms.Panel]::new()
    $content.Dock = [System.Windows.Forms.DockStyle]::Fill
    $content.BackColor = $Theme.Panel

    [void]$titleRow.Controls.Add($titleLbl, 0, 0)
    [void]$titleRow.Controls.Add($toggleBtn, 1, 0)
    [void]$inner.Controls.Add($titleRow, 0, 0)
    [void]$inner.Controls.Add($content, 0, 1)
    [void]$panel.Controls.Add($inner)

    $isCollapsed = $false
    $applyCollapsed = {
        param([bool]$collapsed)
        $isCollapsed = $collapsed
        $content.Visible = -not $collapsed
        $inner.RowStyles[1].Height = if ($collapsed) { 0 } else { 100 }
        $inner.RowStyles[1].SizeType = if ($collapsed) { [System.Windows.Forms.SizeType]::Absolute } else { [System.Windows.Forms.SizeType]::Percent }
        $toggleBtn.Text = if ($collapsed) { "▸" } else { "▾" }
    }

    if ($Collapsible) {
        $toggleBtn.Add_Click({
            & $applyCollapsed (-not $isCollapsed)
        })
    }
    & $applyCollapsed $StartCollapsed

    $panel.Tag = @{
        Content = $content
        Toggle = $toggleBtn
        SetCollapsed = $applyCollapsed
        GetCollapsed = { return $isCollapsed }
    }
    return $panel
}

# ==============================
# PARSING / NORMALIZATION
# ==============================
function Normalize-DeckLine {
    [CmdletBinding()]
    param([string]$Line)
    if ($null -eq $Line) { return '' }
    $n = $Line.Trim()
    $n = $n -replace '[“”]', '"'
    $n = $n -replace '[’‘]', "'"
    $n = $n -replace '\s+', ' '
    return $n
}

function Parse-Decklist {
    [CmdletBinding()]
    param([string]$DeckText)

    $items = New-Object 'System.Collections.Generic.List[object]'
    $suspicious = New-Object 'System.Collections.Generic.List[string]'
    $currentSection = 'Main'

    $lines = ($DeckText -split "`r?`n")
    foreach ($raw in $lines) {
        $line = Normalize-DeckLine -Line $raw
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        if ($Script:KnownHeaders -contains $line) {
            $currentSection = $line
            continue
        }

        if ($line -match '^(\d+)\s+(.+)$') {
            $qty = [int]$Matches[1]
            $name = $Matches[2].Trim()
            if ([string]::IsNullOrWhiteSpace($name)) {
                $suspicious.Add($line)
                continue
            }
            $items.Add([pscustomobject]@{ Quantity = $qty; Name = $name; Section = $currentSection; Raw = $line })
        }
        else {
            $suspicious.Add($line)
        }
    }

    $unique = ($items | Select-Object -ExpandProperty Name -Unique)
    return [pscustomobject]@{
        Cards = $items
        TotalCount = ($items | Measure-Object -Property Quantity -Sum).Sum
        UniqueCount = $unique.Count
        Suspicious = $suspicious
    }
}

function Get-CardSlug {
    [CmdletBinding()]
    param([string]$CardName)
    $slug = $CardName.ToLowerInvariant()
    $slug = $slug -replace '[^a-z0-9]+', '_'
    $slug = $slug.Trim('_')
    return $slug
}

# ==============================
# CACHE / DATABASE / FILE MODEL
# ==============================
function Get-StorageModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$DeckName
    )

    $safeDeck = ($DeckName -replace '[\\/:*?"<>|]', '_').Trim()
    if ([string]::IsNullOrWhiteSpace($safeDeck)) {
        throw 'Deck name cannot be empty.'
    }

    $masterRoot = Join-Path $Root 'MASTER_CARD_DATABASE'
    $masterImagesFront = Join-Path $masterRoot 'images\front'
    $masterImagesBack = Join-Path $masterRoot 'images\back'
    $masterMeta = Join-Path $masterRoot 'metadata'

    $deckRoot = Join-Path $Root $safeDeck
    $deckFront = Join-Path $deckRoot 'front'
    $deckBack = Join-Path $deckRoot 'back'
    $runRoot = Join-Path $deckRoot 'runs'
    $runFolder = Join-Path $runRoot ("run_{0}" -f ([DateTime]::Now.ToString($AppConfig.RunFolderFormat)))

    return [ordered]@{
        Root = $Root
        DeckName = $safeDeck
        MasterRoot = $masterRoot
        MasterFront = $masterImagesFront
        MasterBack = $masterImagesBack
        MasterMeta = $masterMeta
        CardIndexPath = (Join-Path $masterMeta 'card_index.json')
        AmbiguityPath = (Join-Path $masterMeta 'ambiguity_memory.json')
        CanonicalPath = (Join-Path $masterMeta 'canonical_memory.json')
        DeckRoot = $deckRoot
        DeckFront = $deckFront
        DeckBack = $deckBack
        DeckListPath = (Join-Path $deckRoot ("{0} - decklist.txt" -f $safeDeck))
        ManifestPath = (Join-Path $deckRoot ("{0} - manifest.json" -f $safeDeck))
        RunFolder = $runFolder
        DownloadLogPath = (Join-Path $runFolder 'download_log.csv')
        DiagnosticPath = (Join-Path $runFolder 'diagnostic_log.txt')
        UnresolvedPath = (Join-Path $runFolder 'unresolved_cards.txt')
        RunSummaryPath = (Join-Path $runFolder 'run_summary.txt')
    }
}

function Ensure-StorageModel {
    [CmdletBinding()]
    param([hashtable]$Model)

    $paths = @(
        $Model.Root,
        $Model.MasterRoot,
        $Model.MasterFront,
        $Model.MasterBack,
        $Model.MasterMeta,
        $Model.DeckRoot,
        $Model.DeckFront,
        $Model.DeckBack,
        $Model.RunFolder
    )
    foreach ($p in $paths) {
        [void](Ensure-Directory -Path $p)
    }

    if (-not (Test-Path $Model.CardIndexPath)) { Save-Json -InputObject @{} -Path $Model.CardIndexPath }
    if (-not (Test-Path $Model.AmbiguityPath)) { Save-Json -InputObject @{} -Path $Model.AmbiguityPath }
    if (-not (Test-Path $Model.CanonicalPath)) { Save-Json -InputObject @{} -Path $Model.CanonicalPath }

    if (-not (Test-Path $Model.DownloadLogPath)) {
        Set-Content -Path $Model.DownloadLogPath -Value 'timestamp,card_name,action,result,failure_type,detail' -Encoding UTF8
    }
    if (-not (Test-Path $Model.DiagnosticPath)) {
        Set-Content -Path $Model.DiagnosticPath -Value '' -Encoding UTF8
    }
    if (-not (Test-Path $Model.UnresolvedPath)) {
        Set-Content -Path $Model.UnresolvedPath -Value '' -Encoding UTF8
    }
    return
}

function Add-DownloadLogRow {
    [CmdletBinding()]
    param(
        [string]$Card,
        [string]$Action,
        [string]$Result,
        [string]$FailureType = '',
        [string]$Detail = ''
    )
    if (-not $Script:RunState.ContainsKey('DownloadLogPath')) { return }
    $safeDetail = ($Detail -replace ',', ';')
    $line = "{0},{1},{2},{3},{4},{5}" -f (Get-NowText), $Card, $Action, $Result, $FailureType, $safeDetail
    Add-Content -Path $Script:RunState.DownloadLogPath -Value $line -Encoding UTF8
    return
}

function Find-CardInDeckFolders {
    [CmdletBinding()]
    param(
        [string]$Root,
        [string]$FrontFile,
        [string]$BackFile
    )
    $dirs = Get-ChildItem -Path $Root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'MASTER_CARD_DATABASE' }
    foreach ($d in $dirs) {
        $front = Join-Path $d.FullName ("front\$FrontFile")
        $back = Join-Path $d.FullName ("back\$BackFile")
        if (Test-Path $front) {
            return [pscustomobject]@{ Front = $front; Back = $(if (Test-Path $back) { $back } else { $null }) }
        }
    }
    return $null
}

# ==============================
# HTTP HELPER
# ==============================
$Script:Http = @{
    Session = $null
    Headers = @{
        'User-Agent' = 'DeckstacyProxyMaker/1.0 (+https://github.com/)'
        'Accept' = 'application/json, image/*;q=0.9, */*;q=0.8'
    }
}

function Get-SharedWebSession {
    [CmdletBinding()]
    param()

    if ($null -eq $Script:Http.Session) {
        $Script:Http.Session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    }

    return $Script:Http.Session
}

function Invoke-HttpJsonGet {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Uri)

    $session = Get-SharedWebSession
    return Invoke-RestMethod -Uri $Uri -Method Get -Headers $Script:Http.Headers -WebSession $session -TimeoutSec $AppConfig.HttpTimeoutSeconds
}

function Invoke-HttpFileDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Path
    )

    $session = Get-SharedWebSession
    Invoke-WebRequest -Uri $Uri -OutFile $Path -Headers $Script:Http.Headers -WebSession $session -TimeoutSec $AppConfig.HttpTimeoutSeconds
    return
}

# ==============================
# SCRYFALL API / FAILURE CLASSIFICATION
# ==============================
function Classify-Failure {
    [CmdletBinding()]
    param([System.Exception]$Ex)
    $m = $Ex.Message.ToLowerInvariant()
    if ($m -match '429|rate.?limit|too many requests|throttl') { return 'throttling' }
    if ($m -match 'timed out|timeout') { return 'timeout' }
    if ($m -match 'name or service not known|dns|remote name|connection.*(reset|closed|forcibly)|temporar|unreachable|no such host') { return 'dns/network' }
    if ($m -match 'not found|404') { return 'not_found' }
    if ($m -match 'path|access|denied|file') { return 'filesystem' }
    if ($m -match 'name or service not known|dns|remote name') { return 'dns/network' }
    if ($m -match 'not found|404') { return 'api_404_not_found' }
    if ($m -match 'preferred set| set=|set code|expansion') { return 'set_mismatch' }
    if ($m -match 'access to the path|access is denied|unauthorizedaccessexception|permission') { return 'filesystem_permissions' }
    if ($m -match 'path|file') { return 'filesystem' }
    if ($m -match 'unexpected character|invalid json|json') { return 'json_corruption' }
    if ($m -match 'invalid deck|invalid line|syntax|parse') { return 'invalid_card_syntax' }
    return 'generic'
}

function Get-FailureNextAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FailureType,
        [string]$PreferredSet = ''
    )
    switch ($FailureType) {
        'api_404_not_found' { return 'verify card spelling and try Preferred Set blank' }
        'set_mismatch' { return 'try Preferred Set blank or verify the set code exists for that card' }
        'throttling' { return 'wait briefly and rerun; reduce parallel activity hitting the API' }
        'timeout' { return 'check internet stability and rerun' }
        'dns/network' { return 'check network/DNS connectivity and rerun' }
        'filesystem_permissions' { return 'check root permissions and write access for the target folders' }
        'filesystem' { return 'check path validity and that required folders/files exist' }
        'invalid_card_syntax' { return 'fix decklist line format to "<quantity> <card name>"' }
        'json_corruption' { return 'restore or delete/rebuild corrupted JSON metadata files' }
        default { return 'review diagnostic_log.txt and rerun' }
    }
}

function Invoke-ScryfallLookup {
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$PreferredSet = ''
    )

    $encoded = [System.Uri]::EscapeDataString($Name)
    $uri = "{0}{1}" -f $AppConfig.ScryfallSearchUrl, $encoded
    if (-not [string]::IsNullOrWhiteSpace($PreferredSet)) {
        $uri = "$uri&set=$([System.Uri]::EscapeDataString($PreferredSet))"
    }

    $resp = Invoke-HttpJsonGet -Uri $uri
    return $resp
}

function Download-CardImage {
    [CmdletBinding()]
    param(
        [string]$Uri,
        [string]$Path
    )
    Invoke-HttpFileDownload -Uri $Uri -Path $Path
    return
}

function Get-BoundedRetryDelayMs {
    [CmdletBinding()]
    param(
        [int]$Attempt,
        [int]$BudgetRemainingMs
    )

    if ($Attempt -lt 1 -or $BudgetRemainingMs -le 0) { return 0 }

    $pow = [Math]::Pow(2, ($Attempt - 1))
    $expDelay = [int]([Math]::Round($AppConfig.RetryBaseDelayMs * $pow))
    $boundedExp = [Math]::Min($AppConfig.RetryMaxDelayMs, $expDelay)
    $jitter = Get-Random -Minimum 0 -Maximum ($AppConfig.RetryJitterMs + 1)
    $candidate = $boundedExp + $jitter
    return [Math]::Min($BudgetRemainingMs, $candidate)
}

# ==============================
# PREFLIGHT
# ==============================
function Get-Preflight {
    [CmdletBinding()]
    param(
        [pscustomobject]$Parsed,
        [hashtable]$Model
    )

    $index = Load-JsonOrDefault -Path $Model.CardIndexPath -Default @{}
    $cacheHits = 0
    foreach ($card in $Parsed.Cards) {
        $key = $card.Name.ToLowerInvariant()
        if ($index.PSObject.Properties.Name -contains $key) {
            $cacheHits++
        }
    }

    return [pscustomobject]@{
        Parsed = $Parsed.TotalCount
        Unique = $Parsed.UniqueCount
        CacheHits = $cacheHits
        Suspicious = $Parsed.Suspicious.Count
    }
}

function Update-PreflightUi {
    [CmdletBinding()]
    param([pscustomobject]$Preflight)

    $text = @(
        "Parsed cards: $($Preflight.Parsed)",
        "Unique cards: $($Preflight.Unique)",
        "Index cache hits: $($Preflight.CacheHits)",
        "Suspicious lines: $($Preflight.Suspicious)"
    ) -join [Environment]::NewLine

    $Script:Ui.txtPreflight.Text = $text
    Set-UiState -State 'ready'
    return
}

function Validate-RunInputs {
    [CmdletBinding()]
    param(
        [switch]$UpdateUi
    )

    $result = [ordered]@{
        IsValid = $true
        DeckText = ''
        Root = ''
        ImageType = ''
        PreferredSet = ''
    }

    $deckText = [string]$Script:Ui.txtDecklist.Text
    $root = [string]$Script:Ui.txtRootFolder.Text
    $preferredSet = [string]$Script:Ui.txtPreferredSet.Text
    $selectedImageType = $null
    if ($null -ne $Script:Ui.cbImageType.SelectedItem) {
        $selectedImageType = [string]$Script:Ui.cbImageType.SelectedItem
    }

    $parsed = Parse-Decklist -DeckText $deckText
    if ([string]::IsNullOrWhiteSpace($deckText)) {
        $result.IsValid = $false
        $result.DeckText = 'Decklist is required.'
    }
    elseif ($parsed.Cards.Count -eq 0) {
        $result.IsValid = $false
        $result.DeckText = 'No valid "QTY Card Name" lines found.'
    }
    elseif ($parsed.Suspicious.Count -gt 0) {
        $result.IsValid = $false
        $result.DeckText = "Fix $($parsed.Suspicious.Count) suspicious deck line(s)."
    }
    else {
        $result.DeckText = "OK ($($parsed.TotalCount) cards parsed)."
    }

    if ([string]::IsNullOrWhiteSpace($root)) {
        $result.IsValid = $false
        $result.Root = 'Root folder is required.'
    }
    else {
        try {
            [void](Ensure-Directory -Path $root)
            $probe = Join-Path $root ("deckstacy_write_probe_{0}.tmp" -f ([Guid]::NewGuid().ToString('N')))
            Set-Content -Path $probe -Value 'probe' -Encoding UTF8
            Remove-Item -Path $probe -Force -ErrorAction Stop
            $result.Root = 'OK (accessible + writable).'
        }
        catch {
            $result.IsValid = $false
            $result.Root = 'Root path is not writable/accessible.'
        }
    }

    $allowedImageTypes = @('normal','large','png')
    if ([string]::IsNullOrWhiteSpace($selectedImageType)) {
        $result.IsValid = $false
        $result.ImageType = 'Image type is required.'
    }
    elseif ($allowedImageTypes -notcontains $selectedImageType.ToLowerInvariant()) {
        $result.IsValid = $false
        $result.ImageType = "Invalid image type '$selectedImageType'."
    }
    else {
        $result.ImageType = 'OK.'
    }

    if ([string]::IsNullOrWhiteSpace($preferredSet)) {
        $result.PreferredSet = 'OK (blank = any set).'
    }
    elseif ($preferredSet.Trim() -notmatch '^[A-Za-z0-9]{2,6}$') {
        $result.IsValid = $false
        $result.PreferredSet = 'Use 2-6 alphanumeric set code.'
    }
    else {
        $result.PreferredSet = 'OK.'
    }

    if ($UpdateUi) {
        $Script:Ui.lblDeckValidation.Text = "Decklist: $($result.DeckText)"
        $Script:Ui.lblRootValidation.Text = "Root: $($result.Root)"
        $Script:Ui.lblImageValidation.Text = "Image: $($result.ImageType)"
        $Script:Ui.lblSetValidation.Text = "Set: $($result.PreferredSet)"

        $Script:Ui.lblDeckValidation.ForeColor = if ($result.DeckText -like 'OK*') { $Theme.Success } else { $Theme.Danger }
        $Script:Ui.lblRootValidation.ForeColor = if ($result.Root -like 'OK*') { $Theme.Success } else { $Theme.Danger }
        $Script:Ui.lblImageValidation.ForeColor = if ($result.ImageType -like 'OK*') { $Theme.Success } else { $Theme.Danger }
        $Script:Ui.lblSetValidation.ForeColor = if ($result.PreferredSet -like 'OK*') { $Theme.Success } else { $Theme.Danger }
    }

    return [pscustomobject]$result
}

# ==============================
# RUN / RETRY / MANIFEST / SUMMARY
# ==============================
function Resolve-CardWorkItem {
    [CmdletBinding()]
    param(
        [pscustomobject]$Card,
        [hashtable]$Model,
        [string]$ImageType,
        [string]$PreferredSet,
        [hashtable]$Ambiguity,
        [hashtable]$Canonical,
        [switch]$OnlyMissing
    )

    $name = $Card.Name
    $slug = Get-CardSlug -CardName $name
    $frontFile = "$slug.jpg"
    $backFile = "${slug}_back.jpg"

    $deckFrontPath = Join-Path $Model.DeckFront $frontFile
    $deckBackPath = Join-Path $Model.DeckBack $backFile
    $masterFrontPath = Join-Path $Model.MasterFront $frontFile
    $masterBackPath = Join-Path $Model.MasterBack $backFile

    $entry = [pscustomobject]@{
        Name = $name
        Quantity = $Card.Quantity
        Section = $Card.Section
        FrontPath = $deckFrontPath
        BackPath = $deckBackPath
        FrontRequired = $true
        BackRequired = $false
        Source = ''
        Status = 'pending'
        FailureType = ''
        Detail = ''
        LogRow = $null
        StatsDelta = [ordered]@{ Cached = 0; Copied = 0; Downloaded = 0; Skipped = 0 }
        IndexUpdate = $null
        CanonicalUpdate = $null
    }

    $deckFrontExists = Test-Path $deckFrontPath
    $deckBackExists = Test-Path $deckBackPath
    if ($OnlyMissing -and $deckFrontExists) {
        $entry.Status = 'skipped'
        $entry.Source = 'deck_existing'
        $entry.StatsDelta.Skipped = 1
        $entry.LogRow = [ordered]@{ Card = $name; Action = 'skip'; Result = 'ok'; FailureType = ''; Detail = 'only_missing deck has front' }
        return $entry
    }

    if (Test-Path $masterFrontPath) {
        Copy-Item -Path $masterFrontPath -Destination $deckFrontPath -Force
        if (Test-Path $masterBackPath) {
            Copy-Item -Path $masterBackPath -Destination $deckBackPath -Force
            $entry.BackRequired = $true
        }
        $entry.Status = 'ready'
        $entry.Source = 'master_database'
        $entry.StatsDelta.Cached = 1
        $entry.StatsDelta.Copied = 1
        $entry.LogRow = [ordered]@{ Card = $name; Action = 'copy_master'; Result = 'ok'; FailureType = ''; Detail = '' }
        return $entry
    }

    $reuse = Find-CardInDeckFolders -Root $Model.Root -FrontFile $frontFile -BackFile $backFile
    if ($null -ne $reuse) {
        Copy-Item -Path $reuse.Front -Destination $deckFrontPath -Force
        Copy-Item -Path $reuse.Front -Destination $masterFrontPath -Force
        if ($null -ne $reuse.Back) {
            Copy-Item -Path $reuse.Back -Destination $deckBackPath -Force
            Copy-Item -Path $reuse.Back -Destination $masterBackPath -Force
            $entry.BackRequired = $true
        }
        $entry.Status = 'ready'
        $entry.Source = 'other_deck'
        $entry.StatsDelta.Copied = 1
        $entry.LogRow = [ordered]@{ Card = $name; Action = 'copy_peer_deck'; Result = 'ok'; FailureType = ''; Detail = '' }
        return $entry
    }

    try {
        $lookupName = $name
        $ckey = $lookupName.ToLowerInvariant()
        if ($Canonical.ContainsKey($ckey)) {
            $lookupName = [string]$Canonical[$ckey]
        }

        $data = Invoke-ScryfallLookup -Name $lookupName -PreferredSet $PreferredSet
        if ($null -eq $data) {
            throw [System.Exception]::new('No response data')
        }

        $frontUrl = $null
        $backUrl = $null
        if ($null -ne $data.image_uris -and $null -ne $data.image_uris.normal) {
            $frontUrl = [string]$data.image_uris.normal
        }
        elseif ($null -ne $data.card_faces -and $data.card_faces.Count -gt 0) {
            $frontUrl = [string]$data.card_faces[0].image_uris.normal
            if ($data.card_faces.Count -gt 1 -and $null -ne $data.card_faces[1].image_uris.normal) {
                $backUrl = [string]$data.card_faces[1].image_uris.normal
            }
        }

        if ([string]::IsNullOrWhiteSpace($frontUrl)) {
            throw [System.Exception]::new('not_found: no front image URI')
        }

        Download-CardImage -Uri $frontUrl -Path $deckFrontPath
        Copy-Item -Path $deckFrontPath -Destination $masterFrontPath -Force

        if (-not [string]::IsNullOrWhiteSpace($backUrl)) {
            Download-CardImage -Uri $backUrl -Path $deckBackPath
            Copy-Item -Path $deckBackPath -Destination $masterBackPath -Force
            $entry.BackRequired = $true
        }

        $entry.IndexUpdate = [ordered]@{
            key = $name.ToLowerInvariant()
            canonical = $data.name
            id = $data.id
            slug = $slug
            updated = (Get-NowText)
            has_back = $entry.BackRequired
        }

        if ($data.name -ne $name) {
            $entry.CanonicalUpdate = [ordered]@{
                key = $name.ToLowerInvariant()
                value = $data.name
            }
        }

        $entry.Status = 'ready'
        $entry.Source = 'network'
        $entry.StatsDelta.Downloaded = 1
        $entry.LogRow = [ordered]@{ Card = $name; Action = 'download'; Result = 'ok'; FailureType = ''; Detail = '' }
        return $entry
    }
    catch {
        $ft = Classify-Failure -Ex $_.Exception
        if ($ft -eq 'api_404_not_found' -and -not [string]::IsNullOrWhiteSpace($PreferredSet)) {
            $ft = 'set_mismatch'
        }
        $nextAction = Get-FailureNextAction -FailureType $ft -PreferredSet $PreferredSet
        $entry.Status = 'failed'
        $entry.FailureType = $ft
        $entry.Detail = $_.Exception.Message
        Add-DownloadLogRow -Card $name -Action 'download' -Result 'failed' -FailureType $ft -Detail $_.Exception.Message
        Write-UiLog -Message "Failed: $name [$ft]. Suggested next action: $nextAction" -Level 'WARN'
        $entry.LogRow = [ordered]@{ Card = $name; Action = 'download'; Result = 'failed'; FailureType = $ft; Detail = $_.Exception.Message }
        return $entry
    }
}

function Invoke-DeckRun {
    [CmdletBinding()]
    param(
        [string]$DeckText,
        [string]$DeckName,
        [string]$Root,
        [string]$ImageType,
        [string]$PreferredSet,
        [bool]$OnlyMissing,
        [bool]$RepairMode,
        [scriptblock]$ProgressReporter,
        [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None
    )

    Set-PhaseText -Text 'Preparing run'
    Set-Progress -Value 1
    Set-BottomProgress -Value 10
    Reset-RunCancellation
    $Script:RunState.IsRunning = $true
    Report-ProgressUpdate -Reporter $ProgressReporter -PhaseText 'Preparing run' -Percent 1 -StatusMessage 'Running...' -LogMessage 'Run started.'

    $model = Get-StorageModel -Root $Root -DeckName $DeckName
    Ensure-StorageModel -Model $model

    $Script:RunState.DownloadLogPath = $model.DownloadLogPath
    $Script:RunState.DiagnosticPath = $model.DiagnosticPath
    $Script:RunState.GlobalFailures = New-Object 'System.Collections.Generic.List[object]'

    $parsed = Parse-Decklist -DeckText $DeckText
    Set-Content -Path $model.DeckListPath -Value $DeckText -Encoding UTF8

    $cardIndexObj = Load-JsonOrDefault -Path $model.CardIndexPath -Default @{}
    $ambiguityObj = Load-JsonOrDefault -Path $model.AmbiguityPath -Default @{}
    $canonicalObj = Load-JsonOrDefault -Path $model.CanonicalPath -Default @{}

    $cardIndex = @{}
    foreach ($p in $cardIndexObj.PSObject.Properties) { $cardIndex[$p.Name] = $p.Value }
    $ambiguity = @{}
    foreach ($p in $ambiguityObj.PSObject.Properties) { $ambiguity[$p.Name] = $p.Value }
    $canonical = @{}
    foreach ($p in $canonicalObj.PSObject.Properties) { $canonical[$p.Name] = $p.Value }

    $stats = [ordered]@{ Parsed = $parsed.TotalCount; Cached = 0; Copied = 0; Downloaded = 0; Skipped = 0; Repaired = 0; Reviewed = 0; Failed = 0 }
    $failureByType = @{}
    $work = New-Object 'System.Collections.Generic.List[object]'
    $finalItems = New-Object 'System.Collections.Generic.List[object]'

    foreach ($badLine in $parsed.Suspicious) {
        $msg = "Deck line could not be parsed: $badLine"
        $synthetic = [pscustomobject]@{
            Name = $badLine
            Quantity = 0
            Section = 'Unknown'
            FrontPath = ''
            BackPath = ''
            FrontRequired = $false
            BackRequired = $false
            Source = 'parser'
            Status = 'failed'
            FailureType = 'invalid_card_syntax'
            Detail = $msg
        }
        $finalItems.Add($synthetic)
        $stats.Failed++
        if (-not $failureByType.ContainsKey('invalid_card_syntax')) { $failureByType['invalid_card_syntax'] = 0 }
        $failureByType['invalid_card_syntax']++
        Add-DownloadLogRow -Card $badLine -Action 'parse' -Result 'failed' -FailureType 'invalid_card_syntax' -Detail $msg
        Write-UiLog -Message "Invalid card syntax detected. Suggested next action: $(Get-FailureNextAction -FailureType 'invalid_card_syntax')" -Level 'WARN'
    }

    foreach ($card in $parsed.Cards) {
        $work.Add([pscustomobject]@{
            Card = $card
            Attempt = 0
            RetryBudgetRemainingMs = [int]$AppConfig.RetryBudgetMs
            BackoffSpentMs = 0
        })
    }

    $retryable = @('throttling','timeout','dns/network','generic')
    $finalItems = New-Object 'System.Collections.Generic.List[object]'
    $retryable = @('rate_limit','timeout','dns/network','generic')
    $maxParallel = 1
    if ($AppConfig.ContainsKey('MaxParallelDownloads')) {
        $maxParallel = [Math]::Min(12, [Math]::Max(1, [int]$AppConfig.MaxParallelDownloads))
    }
    $parallelSupported = ($PSVersionTable.PSVersion.Major -ge 7)
    if ($maxParallel -gt 1 -and -not $parallelSupported) {
        Write-UiLog -Message 'Parallel downloads requested but PowerShell 7+ is required. Falling back to single-threaded mode.' -Level 'WARN'
        $maxParallel = 1
    }
    $runStatus = 'completed'

    for ($pass = 1; $pass -le $AppConfig.RetryPasses; $pass++) {
        if (Test-RunCancellation) {
            $runStatus = 'cancelled'
            break
        }
        Set-PhaseText -Text "Processing (pass $pass/$($AppConfig.RetryPasses))"
        Write-UiLog -Message "Starting processing pass $pass"
        $CancellationToken.ThrowIfCancellationRequested()
        Report-ProgressUpdate -Reporter $ProgressReporter -PhaseText "Processing (pass $pass/$($AppConfig.RetryPasses))" -LogMessage "Starting processing pass $pass"
        $next = New-Object 'System.Collections.Generic.List[object]'
        $passResults = @()

        if ($maxParallel -gt 1) {
            $workerFunctions = @(
                'Get-NowText',
                'Get-CardSlug',
                'Find-CardInDeckFolders',
                'Invoke-ScryfallLookup',
                'Download-CardImage',
                'Classify-Failure',
                'Resolve-CardWorkItem'
            ) | ForEach-Object { "function $_ { $((Get-Command $_).ScriptBlock.ToString()) }" }
            $canonicalSnapshot = @{}
            foreach ($k in $canonical.Keys) { $canonicalSnapshot[$k] = $canonical[$k] }

            $passResults = $work | ForEach-Object -Parallel {
                foreach ($f in $using:workerFunctions) { Invoke-Expression $f }
                $localCanonical = @{}
                foreach ($k in $using:canonicalSnapshot.Keys) { $localCanonical[$k] = $using:canonicalSnapshot[$k] }
                $localAmbiguity = @{}
                $result = Resolve-CardWorkItem -Card $_.Card -Model $using:model -ImageType $using:ImageType -PreferredSet $using:PreferredSet -Ambiguity $localAmbiguity -Canonical $localCanonical -OnlyMissing:$using:OnlyMissing
                return [pscustomobject]@{ Item = $_; Result = $result }
            } -ThrottleLimit $maxParallel
        }
        else {
            foreach ($item in $work) {
                $result = Resolve-CardWorkItem -Card $item.Card -Model $model -ImageType $ImageType -PreferredSet $PreferredSet -Ambiguity $ambiguity -Canonical $canonical -OnlyMissing:$OnlyMissing
                $passResults += [pscustomobject]@{ Item = $item; Result = $result }
            }
        }

        $i = 0
        foreach ($row in $passResults) {
            $i++
            $progress = [int](5 + (($i / [Math]::Max(1, $passResults.Count)) * 85))
            Set-Progress -Value $progress

            $item = $row.Item
            $result = $row.Result
            if ($null -ne $result.LogRow) {
                Add-DownloadLogRow -Card $result.LogRow.Card -Action $result.LogRow.Action -Result $result.LogRow.Result -FailureType $result.LogRow.FailureType -Detail $result.LogRow.Detail
            }
            $stats.Cached += [int]$result.StatsDelta.Cached
            $stats.Copied += [int]$result.StatsDelta.Copied
            $stats.Downloaded += [int]$result.StatsDelta.Downloaded
            $stats.Skipped += [int]$result.StatsDelta.Skipped
            if ($null -ne $result.IndexUpdate) {
                $cardIndex[[string]$result.IndexUpdate.key] = [ordered]@{
                    canonical = $result.IndexUpdate.canonical
                    id = $result.IndexUpdate.id
                    slug = $result.IndexUpdate.slug
                    updated = $result.IndexUpdate.updated
                    has_back = $result.IndexUpdate.has_back
                }
            }
            if ($null -ne $result.CanonicalUpdate) {
                $canonical[[string]$result.CanonicalUpdate.key] = [string]$result.CanonicalUpdate.value
            }
            if ($result.Status -eq 'failed' -and ($retryable -contains $result.FailureType) -and $pass -lt $AppConfig.RetryPasses) {
        foreach ($item in $work) {
            if (Test-RunCancellation) {
                $runStatus = 'cancelled'
                break
            }
            $CancellationToken.ThrowIfCancellationRequested()
            $i++
            $progress = [int](5 + (($i / [Math]::Max(1, $work.Count)) * 85))
            Report-ProgressUpdate -Reporter $ProgressReporter -Percent $progress

            $result = Resolve-CardWorkItem -Card $item.Card -Model $model -ImageType $ImageType -PreferredSet $PreferredSet -Stats $stats -CardIndex $cardIndex -Ambiguity $ambiguity -Canonical $canonical -OnlyMissing:$OnlyMissing
            if ($result.Status -eq 'failed' -and ($retryable -contains $result.FailureType) -and $pass -lt $AppConfig.RetryPasses) {
                $nextAttempt = ($item.Attempt + 1)
                $delayMs = Get-BoundedRetryDelayMs -Attempt $nextAttempt -BudgetRemainingMs $item.RetryBudgetRemainingMs
                if ($delayMs -le 0) {
                    $result.Detail = ("{0}; retry budget exhausted at attempt {1}" -f $result.Detail, $nextAttempt)
                    $stats.Failed++
                    $finalItems.Add($result)
                    Write-UiLog -Message ("Retry budget exhausted for {0}; failureType={1}; attempts={2}; budgetRemainingMs={3}" -f $item.Card.Name, $result.FailureType, $nextAttempt, $item.RetryBudgetRemainingMs) -Level 'WARN'
                }
                else {
                    $remainingMs = [Math]::Max(0, ($item.RetryBudgetRemainingMs - $delayMs))
                    Write-UiLog -Message ("Retry backoff for {0}: failureType={1}; attempt={2}; delayMs={3}; budgetBeforeMs={4}; budgetAfterMs={5}" -f $item.Card.Name, $result.FailureType, $nextAttempt, $delayMs, $item.RetryBudgetRemainingMs, $remainingMs) -Level 'WARN'
                    Start-Sleep -Milliseconds $delayMs
                    $next.Add([pscustomobject]@{
                        Card = $item.Card
                        Attempt = $nextAttempt
                        RetryBudgetRemainingMs = $remainingMs
                        BackoffSpentMs = ($item.BackoffSpentMs + $delayMs)
                    })
                    Write-UiLog -Message ("Re-queued {0} after backoff; attempt={1}; cumulativeBackoffMs={2}" -f $item.Card.Name, $nextAttempt, ($item.BackoffSpentMs + $delayMs)) -Level 'WARN'
                }
            if (($runStatus -ne 'cancelled') -and $result.Status -eq 'failed' -and ($retryable -contains $result.FailureType) -and $pass -lt $AppConfig.RetryPasses) {
                $next.Add([pscustomobject]@{ Card = $item.Card; Attempt = ($item.Attempt + 1) })
                Report-ProgressUpdate -Reporter $ProgressReporter -LogMessage "Re-queued $($item.Card.Name) due to retryable failure: $($result.FailureType)" -LogLevel 'WARN'
            }
            else {
                if ($result.Status -eq 'failed') {
                    $stats.Failed++
                    if (-not $failureByType.ContainsKey($result.FailureType)) { $failureByType[$result.FailureType] = 0 }
                    $failureByType[$result.FailureType]++
                }
                $finalItems.Add($result)
            }
        }

        if ($runStatus -eq 'cancelled') {
            break
        }

        if ($next.Count -eq 0) {
            break
        }
        $work = $next
    }

    if ($RepairMode -and $runStatus -ne 'cancelled') {
        Set-PhaseText -Text 'Repair audit'
        foreach ($item in $finalItems) {
            if (Test-RunCancellation) {
                $runStatus = 'cancelled'
                break
            }
    if ($RepairMode) {
        Report-ProgressUpdate -Reporter $ProgressReporter -PhaseText 'Repair audit'
        foreach ($item in $finalItems) {
            $CancellationToken.ThrowIfCancellationRequested()
            if ($item.Status -eq 'ready' -or $item.Status -eq 'skipped') {
                $frontOk = (Test-Path $item.FrontPath)
                $backOk = $true
                if ($item.BackRequired) {
                    $backOk = (Test-Path $item.BackPath)
                }
                if (-not $frontOk -or -not $backOk) {
                    $stats.Reviewed++
                    try {
                        if (-not $frontOk) {
                            $src = Join-Path $model.MasterFront ([System.IO.Path]::GetFileName($item.FrontPath))
                            if (Test-Path $src) {
                                Copy-Item -Path $src -Destination $item.FrontPath -Force
                            }
                        }
                        if ($item.BackRequired -and -not $backOk) {
                            $srcb = Join-Path $model.MasterBack ([System.IO.Path]::GetFileName($item.BackPath))
                            if (Test-Path $srcb) {
                                Copy-Item -Path $srcb -Destination $item.BackPath -Force
                            }
                        }
                        $nowFront = (Test-Path $item.FrontPath)
                        $nowBack = $true
                        if ($item.BackRequired) { $nowBack = (Test-Path $item.BackPath) }
                        if ($nowFront -and $nowBack) {
                            $stats.Repaired++
                            Report-ProgressUpdate -Reporter $ProgressReporter -LogMessage "Repaired asset gap for $($item.Name)"
                        }
                    }
                    catch {
                        Report-ProgressUpdate -Reporter $ProgressReporter -LogMessage "Repair failed for $($item.Name): $($_.Exception.Message)" -LogLevel 'WARN'
                    }
                }
            }
        }
    }

    if ($Script:RunState.ContainsKey('GlobalFailures') -and $Script:RunState.GlobalFailures.Count -gt 0) {
        foreach ($gf in $Script:RunState.GlobalFailures) {
            $finalItems.Add([pscustomobject]@{
                Name = $gf.Name
                Quantity = 0
                Section = 'System'
                FrontPath = ''
                BackPath = ''
                FrontRequired = $false
                BackRequired = $false
                Source = 'system'
                Status = 'failed'
                FailureType = $gf.FailureType
                Detail = $gf.Detail
            })
            $stats.Failed++
            if (-not $failureByType.ContainsKey($gf.FailureType)) { $failureByType[$gf.FailureType] = 0 }
            $failureByType[$gf.FailureType]++
        }
    }

    $unresolved = $finalItems | Where-Object { $_.Status -eq 'failed' }
    if ($unresolved.Count -gt 0) {
        $lines = foreach ($u in $unresolved) {
            $nextAction = Get-FailureNextAction -FailureType $u.FailureType -PreferredSet $PreferredSet
            "{0} | {1} | {2} | next: {3}" -f $u.Name, $u.FailureType, $u.Detail, $nextAction
        }
        Set-Content -Path $model.UnresolvedPath -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
    }

    Save-Json -InputObject $cardIndex -Path $model.CardIndexPath
    Save-Json -InputObject $ambiguity -Path $model.AmbiguityPath
    Save-Json -InputObject $canonical -Path $model.CanonicalPath

    $manifest = [ordered]@{
        deck_name = $model.DeckName
        generated_at = (Get-NowText)
        status = $runStatus
        image_type = $ImageType
        preferred_set = $PreferredSet
        only_missing = $OnlyMissing
        repair_mode = $RepairMode
        parsed = $stats.Parsed
        pending_retries = $work.Count
        cards = $finalItems
    }
    Save-Json -InputObject $manifest -Path $model.ManifestPath

    $summary = @(
        "Deck: $($model.DeckName)",
        "Generated: $(Get-NowText)",
        "Status: $runStatus",
        "Parsed: $($stats.Parsed)",
        "Cached: $($stats.Cached)",
        "Copied: $($stats.Copied)",
        "Downloaded: $($stats.Downloaded)",
        "Skipped: $($stats.Skipped)",
        "Repaired: $($stats.Repaired)",
        "Reviewed: $($stats.Reviewed)",
        "Failed (final): $($stats.Failed)",
        "Pending retries: $($work.Count)",
        "Run folder: $($model.RunFolder)"
    )
    if ($failureByType.Count -gt 0) {
        $summary += 'Failures by type:'
        foreach ($k in ($failureByType.Keys | Sort-Object)) {
            $summary += ("  - {0}: {1}" -f $k, $failureByType[$k])
        }
    }
    Set-Content -Path $model.RunSummaryPath -Value ($summary -join [Environment]::NewLine) -Encoding UTF8

    $Script:Ui.lblStatParsed.Text = [string]$stats.Parsed
    $Script:Ui.lblStatCached.Text = [string]$stats.Cached
    $Script:Ui.lblStatCopied.Text = [string]$stats.Copied
    $Script:Ui.lblStatDownloaded.Text = [string]$stats.Downloaded
    $Script:Ui.lblStatSkipped.Text = [string]$stats.Skipped
    $Script:Ui.lblStatRepaired.Text = [string]$stats.Repaired
    $Script:Ui.lblStatReviewed.Text = [string]$stats.Reviewed
    $Script:Ui.lblStatFailed.Text = [string]$stats.Failed

    Set-PhaseText -Text 'Completed'
    Set-Progress -Value 100
    Set-BottomProgress -Value 100
    Set-StatusText -Text ("Completed. Final failures: {0}" -f $stats.Failed)
    Write-UiLog -Message 'Run complete.'

    return [pscustomobject]@{ Model = $model; Stats = $stats }
    Invoke-UiThread -Action {
        $Script:Ui.lblStatParsed.Text = [string]$stats.Parsed
        $Script:Ui.lblStatCached.Text = [string]$stats.Cached
        $Script:Ui.lblStatCopied.Text = [string]$stats.Copied
        $Script:Ui.lblStatDownloaded.Text = [string]$stats.Downloaded
        $Script:Ui.lblStatSkipped.Text = [string]$stats.Skipped
        $Script:Ui.lblStatRepaired.Text = [string]$stats.Repaired
        $Script:Ui.lblStatReviewed.Text = [string]$stats.Reviewed
        $Script:Ui.lblStatFailed.Text = [string]$stats.Failed
    }

    if ($runStatus -eq 'cancelled') {
        Set-PhaseText -Text 'Cancelled'
        Set-StatusText -Text ("Cancelled. Partial output saved. Processed: {0}/{1}" -f $finalItems.Count, $stats.Parsed)
        Write-UiLog -Message 'Run cancelled. Partial manifest and summary were written.' -Level 'WARN'
    }
    else {
        Set-PhaseText -Text 'Completed'
        Set-Progress -Value 100
        Set-StatusText -Text ("Completed. Final failures: {0}" -f $stats.Failed)
        Write-UiLog -Message 'Run complete.'
    }

    $Script:RunState.IsRunning = $false
    Report-ProgressUpdate -Reporter $ProgressReporter -PhaseText 'Completed' -Percent 100 -StatusMessage ("Completed. Final failures: {0}" -f $stats.Failed) -LogMessage 'Run complete.'

    return [pscustomobject]@{ Model = $model; Stats = $stats; Status = $runStatus }
}

# ==============================
# RECENT RUNS / RUN HISTORY UI
# ==============================
function Get-RunSummaryData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunFolderPath,
        [string]$DeckManifestPath = ''
    )

    $summaryPath = Join-Path $RunFolderPath 'run_summary.txt'
    $parsed = ''
    $downloaded = ''
    $failed = ''
    $timestamp = ''

    if (Test-Path -LiteralPath $summaryPath) {
        $raw = Get-Content -Path $summaryPath -Raw -Encoding UTF8
        if ($raw -match '(?im)^Generated:\s*(.+)$') { $timestamp = $Matches[1].Trim() }
        if ($raw -match '(?im)^Parsed:\s*(\d+)$') { $parsed = $Matches[1].Trim() }
        if ($raw -match '(?im)^Downloaded:\s*(\d+)$') { $downloaded = $Matches[1].Trim() }
        if ($raw -match '(?im)^Failed\s*\(final\):\s*(\d+)$') { $failed = $Matches[1].Trim() }
    }

    if (([string]::IsNullOrWhiteSpace($parsed) -or [string]::IsNullOrWhiteSpace($downloaded) -or [string]::IsNullOrWhiteSpace($failed) -or [string]::IsNullOrWhiteSpace($timestamp)) -and -not [string]::IsNullOrWhiteSpace($DeckManifestPath) -and (Test-Path -LiteralPath $DeckManifestPath)) {
        try {
            $manifest = Load-JsonOrDefault -Path $DeckManifestPath -Default @{}
            if ([string]::IsNullOrWhiteSpace($timestamp) -and $manifest.PSObject.Properties.Name -contains 'generated_at') { $timestamp = [string]$manifest.generated_at }
            if ([string]::IsNullOrWhiteSpace($parsed) -and $manifest.PSObject.Properties.Name -contains 'parsed') { $parsed = [string]$manifest.parsed }
            if (($manifest.PSObject.Properties.Name -contains 'cards') -and ($manifest.cards -is [System.Collections.IEnumerable])) {
                $cards = @($manifest.cards)
                if ([string]::IsNullOrWhiteSpace($downloaded)) { $downloaded = [string](($cards | Where-Object { $_.Status -eq 'ready' -and $_.Source -eq 'network' }).Count) }
                if ([string]::IsNullOrWhiteSpace($failed)) { $failed = [string](($cards | Where-Object { $_.Status -eq 'failed' }).Count) }
            }
        }
        catch { }
    }

    if ([string]::IsNullOrWhiteSpace($timestamp)) {
        $folderName = [System.IO.Path]::GetFileName($RunFolderPath)
        if ($folderName -match '^run_(\d{8})_(\d{6})$') {
            $d = $Matches[1]
            $t = $Matches[2]
            try {
                $dt = [DateTime]::ParseExact("$d$t", 'yyyyMMddHHmmss', $null)
                $timestamp = $dt.ToString('yyyy-MM-dd HH:mm:ss')
            }
            catch { }
        }
    }

    return [pscustomobject]@{
        Parsed = $(if ([string]::IsNullOrWhiteSpace($parsed)) { '-' } else { $parsed })
        Downloaded = $(if ([string]::IsNullOrWhiteSpace($downloaded)) { '-' } else { $downloaded })
        Failed = $(if ([string]::IsNullOrWhiteSpace($failed)) { '-' } else { $failed })
        Timestamp = $(if ([string]::IsNullOrWhiteSpace($timestamp)) { '-' } else { $timestamp })
        UnresolvedPath = (Join-Path $RunFolderPath 'unresolved_cards.txt')
        DiagnosticPath = (Join-Path $RunFolderPath 'diagnostic_log.txt')
    }
}

function Refresh-RecentRunsUi {
    [CmdletBinding()]
    param()

    if (-not $Script:Ui.ContainsKey('lvRecentRuns')) { return }
    $lv = [System.Windows.Forms.ListView]$Script:Ui.lvRecentRuns
    $lv.BeginUpdate()
    $lv.Items.Clear()
    try {
        $root = $Script:Ui.txtRootFolder.Text.Trim()
        $deckName = $Script:Ui.txtDeckName.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($root) -or [string]::IsNullOrWhiteSpace($deckName)) {
            $Script:Ui.lblRecentRunsHint.Text = 'Set root folder + deck name to load run history.'
            return
        }

        $model = Get-StorageModel -Root $root -DeckName $deckName
        $runRoot = Join-Path $model.DeckRoot 'runs'
        if (-not (Test-Path -LiteralPath $runRoot)) {
            $Script:Ui.lblRecentRunsHint.Text = 'No runs yet for this deck.'
            return
        }

        $folders = @(Get-ChildItem -Path $runRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 25)
        if ($folders.Count -eq 0) {
            $Script:Ui.lblRecentRunsHint.Text = 'No runs yet for this deck.'
            return
        }

        foreach ($folder in $folders) {
            $runData = Get-RunSummaryData -RunFolderPath $folder.FullName -DeckManifestPath $model.ManifestPath
            $item = [System.Windows.Forms.ListViewItem]::new($folder.Name)
            [void]$item.SubItems.Add($runData.Timestamp)
            [void]$item.SubItems.Add([string]$runData.Parsed)
            [void]$item.SubItems.Add([string]$runData.Downloaded)
            [void]$item.SubItems.Add([string]$runData.Failed)
            $item.Tag = [pscustomobject]@{
                RunFolder = $folder.FullName
                UnresolvedPath = $runData.UnresolvedPath
                DiagnosticPath = $runData.DiagnosticPath
            }
            [void]$lv.Items.Add($item)
        }
        $Script:Ui.lblRecentRunsHint.Text = ("Loaded {0} recent run(s)." -f $lv.Items.Count)
    }
    finally {
        $lv.EndUpdate()
    }
    return
}

function Get-SelectedRunRecord {
    [CmdletBinding()]
    param()

    if (-not $Script:Ui.ContainsKey('lvRecentRuns')) { return $null }
    $lv = [System.Windows.Forms.ListView]$Script:Ui.lvRecentRuns
    if ($lv.SelectedItems.Count -lt 1) { return $null }
    return $lv.SelectedItems[0].Tag
}

function Open-PathInShell {
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    Start-Process -FilePath $Path
    return $true
}

# ==============================
# UI CONSTRUCTION
# ==============================
function New-StatRow {
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$Key
    )
    $row = [System.Windows.Forms.TableLayoutPanel]::new()
    $row.Dock = [System.Windows.Forms.DockStyle]::Top
    $row.Height = Scale-UiValue -Value 26 -Min 22
    $row.ColumnCount = 2
    $row.RowCount = 1
    $row.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 70))
    $row.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 30))

    $lblName = New-StyledLabel -Text $Name -Size 9 -Color $Theme.Muted
    $lblVal = New-StyledLabel -Text '0' -Size 11 -Bold $true -Color $Theme.Fore -Align ([System.Drawing.ContentAlignment]::MiddleRight)
    $lblVal.Name = "lblStat$Key"

    [void]$row.Controls.Add($lblName, 0, 0)
    [void]$row.Controls.Add($lblVal, 1, 0)
    $row.Tag = [pscustomobject]@{
        NameLabel = $lblName
        ValueLabel = $lblVal
    }
    return $row
}

function Build-MainForm {
    [CmdletBinding()]
    param()

    $form = [System.Windows.Forms.Form]::new()
    $form.Text = $AppConfig.AppName
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.Size = [System.Drawing.Size]::new(1440, 920)
    $form.MinimumSize = [System.Drawing.Size]::new(1220, 780)
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $Script:UiScale = Get-UiScaleFactor -Form $form
    $form.BackColor = $Theme.Back
    $form.ForeColor = $Theme.Fore

    $root = [System.Windows.Forms.TableLayoutPanel]::new()
    $root.Dock = [System.Windows.Forms.DockStyle]::Fill
    $root.Padding = [System.Windows.Forms.Padding]::new((Scale-UiValue -Value 10))
    $root.ColumnCount = 1
    $root.RowCount = 4
    $root.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
    $root.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
    $root.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 60))
    $root.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 148))
    $root.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
    $root.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))

    # A: Header strip
    $hdr = [System.Windows.Forms.TableLayoutPanel]::new()
    $hdr.Dock = 'Fill'
    $hdr.ColumnCount = 2
    $hdr.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 78))
    $hdr.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 22))

    $hdrLeft = [System.Windows.Forms.Panel]::new(); $hdrLeft.Dock = 'Fill'
    $lblTitle = New-StyledLabel -Text $AppConfig.AppName -Size 15 -Bold $true -Color $Theme.Accent
    $lblTitle.Dock = 'Top'; $lblTitle.Height = Scale-UiValue -Value 30 -Min 26
    $lblSub = New-StyledLabel -Text $AppConfig.Subtitle -Size 9 -Color $Theme.Muted
    $lblSub.Dock = 'Top'; $lblSub.Height = Scale-UiValue -Value 24 -Min 20
    [void]$hdrLeft.Controls.Add($lblSub)
    [void]$hdrLeft.Controls.Add($lblTitle)

    $hdrRight = [System.Windows.Forms.FlowLayoutPanel]::new()
    $hdrRight.Dock = 'Fill'
    $hdrRight.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
    $hdrRight.WrapContents = $false
    $hdrRight.Padding = [System.Windows.Forms.Padding]::new(0, (Scale-UiValue -Value 12), 0, 0)

    $chip = [System.Windows.Forms.Label]::new()
    $chip.Text = 'Mode: Ready'
    $chip.AutoSize = $true
    $chip.Padding = [System.Windows.Forms.Padding]::new((Scale-UiValue -Value 10), (Scale-UiValue -Value 6), (Scale-UiValue -Value 10), (Scale-UiValue -Value 6))
    $chip.BackColor = [System.Drawing.Color]::FromArgb(35, 44, 58)
    $chip.ForeColor = $Theme.Accent2
    $chip.Font = [System.Drawing.Font]::new('Segoe UI', (9 * $Script:UiScale), [System.Drawing.FontStyle]::Bold)

    [void]$hdrRight.Controls.Add($chip)
    [void]$hdr.Controls.Add($hdrLeft, 0, 0)
    [void]$hdr.Controls.Add($hdrRight, 1, 0)

    # B: control section (2-row)
    $controlsPanel = [System.Windows.Forms.Panel]::new()
    $controlsPanel.Dock = 'Fill'
    $controlsPanel.Padding = [System.Windows.Forms.Padding]::new((Scale-UiValue -Value 10))
    $controlsPanel.BackColor = $Theme.Panel

    $controlsGrid = [System.Windows.Forms.TableLayoutPanel]::new()
    $controlsGrid.Dock = 'Fill'
    $controlsGrid.ColumnCount = 7
    $controlsGrid.RowCount = 2
    $controlsGrid.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
    $controlsGrid.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
    $controlsGrid.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
    $controlsGrid.RowCount = 3
    $controlsGrid.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 42))
    $controlsGrid.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 42))
    $controlsGrid.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 30))
    $controlsGrid.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 90))
    $controlsGrid.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 28))
    $controlsGrid.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
    $controlsGrid.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 45))
    $controlsGrid.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
    $controlsGrid.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 17))
    $controlsGrid.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 10))

    $lblDeckName = New-StyledLabel -Text 'Deck Name'
    $txtDeckName = New-StyledTextBox
    $lblRoot = New-StyledLabel -Text 'Root Folder'
    $txtRoot = New-StyledTextBox
    $btnBrowse = New-StyledButton -Text 'Browse' -Width 88
    $lblImage = New-StyledLabel -Text 'Image Type'
    $cbImage = [System.Windows.Forms.ComboBox]::new(); $cbImage.Dock='Fill'; $cbImage.DropDownStyle='DropDownList'; $cbImage.BackColor=[System.Drawing.Color]::FromArgb(21,26,33); $cbImage.ForeColor=$Theme.Fore; $cbImage.Font=[System.Drawing.Font]::new('Segoe UI',(9 * $Script:UiScale))
    [void]$cbImage.Items.AddRange(@('normal','large','png'))
    $cbImage.SelectedIndex = 0
    $lblSet = New-StyledLabel -Text 'Preferred Set'
    $txtSet = New-StyledTextBox

    [void]$controlsGrid.Controls.Add($lblDeckName, 0, 0)
    [void]$controlsGrid.Controls.Add($txtDeckName, 1, 0)
    [void]$controlsGrid.Controls.Add($lblRoot, 2, 0)
    [void]$controlsGrid.Controls.Add($txtRoot, 3, 0)
    [void]$controlsGrid.Controls.Add($btnBrowse, 4, 0)
    [void]$controlsGrid.Controls.Add($lblImage, 5, 0)
    [void]$controlsGrid.Controls.Add($cbImage, 6, 0)

    # row 2 with label+set field then toggles/actions
    $lblSet.Dock = 'Fill'
    [void]$controlsGrid.Controls.Add($lblSet, 0, 1)
    [void]$controlsGrid.Controls.Add($txtSet, 1, 1)

    $toggleFlow = [System.Windows.Forms.FlowLayoutPanel]::new()
    $toggleFlow.Dock = 'Fill'
    $toggleFlow.FlowDirection = 'LeftToRight'
    $toggleFlow.WrapContents = $false
    $toggleFlow.AutoSize = $false

    $chkOnlyMissing = [System.Windows.Forms.CheckBox]::new(); $chkOnlyMissing.Text='Only Missing'; $chkOnlyMissing.ForeColor=$Theme.Fore; $chkOnlyMissing.Font=[System.Drawing.Font]::new('Segoe UI',(9 * $Script:UiScale)); $chkOnlyMissing.AutoSize=$true; $chkOnlyMissing.Margin=[System.Windows.Forms.Padding]::new((Scale-UiValue -Value 6),(Scale-UiValue -Value 8),(Scale-UiValue -Value 12),0)
    $chkRepair = [System.Windows.Forms.CheckBox]::new(); $chkRepair.Text='Repair Mode'; $chkRepair.ForeColor=$Theme.Fore; $chkRepair.Font=[System.Drawing.Font]::new('Segoe UI',(9 * $Script:UiScale)); $chkRepair.AutoSize=$true; $chkRepair.Margin=[System.Windows.Forms.Padding]::new((Scale-UiValue -Value 6),(Scale-UiValue -Value 8),(Scale-UiValue -Value 12),0)
    [void]$toggleFlow.Controls.Add($chkOnlyMissing)
    [void]$toggleFlow.Controls.Add($chkRepair)

    $actionsFlow = [System.Windows.Forms.FlowLayoutPanel]::new()
    $actionsFlow.Dock = 'Fill'
    $actionsFlow.FlowDirection = 'LeftToRight'
    $actionsFlow.WrapContents = $false

    $btnLoad = New-StyledButton -Text 'Load .txt' -Width 100
    $btnAuto = New-StyledButton -Text 'Auto Name' -Width 100
    $btnTestApi = New-StyledButton -Text 'Test API' -Width 100
    $btnRefresh = New-StyledButton -Text 'Refresh Index' -Width 110
    [void]$actionsFlow.Controls.Add($btnLoad)
    [void]$actionsFlow.Controls.Add($btnAuto)
    [void]$actionsFlow.Controls.Add($btnTestApi)
    [void]$actionsFlow.Controls.Add($btnRefresh)

    [void]$controlsGrid.Controls.Add($toggleFlow, 2, 1)
    $controlsGrid.SetColumnSpan($toggleFlow, 2)
    [void]$controlsGrid.Controls.Add($actionsFlow, 4, 1)
    $controlsGrid.SetColumnSpan($actionsFlow, 3)

    $lblRootValidation = New-StyledLabel -Text 'Root: pending' -Size 8.6 -Color $Theme.Muted
    $lblImageValidation = New-StyledLabel -Text 'Image: pending' -Size 8.6 -Color $Theme.Muted
    $lblSetValidation = New-StyledLabel -Text 'Set: pending' -Size 8.6 -Color $Theme.Muted
    $lblDeckValidation = New-StyledLabel -Text 'Decklist: pending' -Size 8.6 -Color $Theme.Muted
    [void]$controlsGrid.Controls.Add($lblRootValidation, 2, 2)
    $controlsGrid.SetColumnSpan($lblRootValidation, 2)
    [void]$controlsGrid.Controls.Add($lblImageValidation, 5, 2)
    [void]$controlsGrid.Controls.Add($lblSetValidation, 6, 2)
    [void]$controlsGrid.Controls.Add($lblDeckValidation, 0, 2)
    $controlsGrid.SetColumnSpan($lblDeckValidation, 2)

    [void]$controlsPanel.Controls.Add($controlsGrid)

    # C main two-column area
    $main = [System.Windows.Forms.TableLayoutPanel]::new()
    $main.Dock = 'Fill'
    $main.ColumnCount = 2
    $main.RowCount = 1
    $main.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 63))
    $main.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 37))

    # left column
    $left = [System.Windows.Forms.TableLayoutPanel]::new()
    $left.Dock = 'Fill'
    $left.RowCount = 2
    $left.ColumnCount = 1
    $left.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 32))
    $left.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 68))

    $preflightPanel = New-SectionPanel -Title 'Preflight Summary'
    $preflightContent = [System.Windows.Forms.Panel]$preflightPanel.Tag.Content
    $txtPreflight = New-StyledTextBox -Multiline $true -ReadOnly $true
    $txtPreflight.Font = [System.Drawing.Font]::new('Consolas', (10 * $Script:UiScale))
    [void]$preflightContent.Controls.Add($txtPreflight)

    $deckPanel = New-SectionPanel -Title 'Decklist Workspace'
    $deckContent = [System.Windows.Forms.Panel]$deckPanel.Tag.Content
    $deckLayout = [System.Windows.Forms.TableLayoutPanel]::new()
    $deckLayout.Dock = 'Fill'
    $deckLayout.RowCount = 2
    $deckLayout.ColumnCount = 1
    $deckLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
    $deckLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
    $helper = New-StyledLabel -Text 'Paste decklist here (supports section headers and quantity-prefixed lines).' -Size 9 -Color $Theme.Muted
    $txtDeck = New-StyledTextBox -Multiline $true
    $txtDeck.Font = [System.Drawing.Font]::new('Consolas', (10 * $Script:UiScale))
    [void]$deckLayout.Controls.Add($helper, 0, 0)
    [void]$deckLayout.Controls.Add($txtDeck, 0, 1)
    [void]$deckContent.Controls.Add($deckLayout)

    [void]$left.Controls.Add($preflightPanel, 0, 0)
    [void]$left.Controls.Add($deckPanel, 0, 1)

    # right column
    $rightSplit = [System.Windows.Forms.SplitContainer]::new()
    $rightSplit.Dock = 'Fill'
    $rightSplit.Orientation = [System.Windows.Forms.Orientation]::Horizontal
    $rightSplit.SplitterWidth = Scale-UiValue -Value 6 -Min 4
    $rightSplit.Panel1MinSize = Scale-UiValue -Value 180 -Min 140
    $rightSplit.Panel2MinSize = Scale-UiValue -Value 90 -Min 64
    $rightSplit.SplitterDistance = Scale-UiValue -Value 360 -Min 220

    $topRight = [System.Windows.Forms.SplitContainer]::new()
    $topRight.Dock = 'Fill'
    $topRight.Orientation = [System.Windows.Forms.Orientation]::Horizontal
    $topRight.SplitterWidth = Scale-UiValue -Value 6 -Min 4
    $topRight.Panel1MinSize = Scale-UiValue -Value 120 -Min 90
    $topRight.Panel2MinSize = Scale-UiValue -Value 92 -Min 70
    $topRight.SplitterDistance = Scale-UiValue -Value 245 -Min 150

    $summaryPanel = New-SectionPanel -Title 'Run Summary' -Collapsible $true
    $summaryContent = [System.Windows.Forms.Panel]$summaryPanel.Tag.Content
    $right = [System.Windows.Forms.TableLayoutPanel]::new()
    $right.Dock = 'Fill'
    $right.RowCount = 4
    $right.ColumnCount = 1
    $right.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 245))
    $right.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 110))
    $right.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 240))
    $right.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))

    $summaryPanel = New-SectionPanel -Title 'Run Summary'
    $summaryContent = [System.Windows.Forms.Panel]$summaryPanel.Tag
    $statsLayout = [System.Windows.Forms.TableLayoutPanel]::new()
    $statsLayout.Dock = 'Fill'
    $statsLayout.ColumnCount = 1
    $statsLayout.RowCount = 8
    for ($s = 0; $s -lt 8; $s++) {
        $statsLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 12.5))
    }
    $stats = @('Parsed','Cached','Copied','Downloaded','Skipped','Repaired','Reviewed','Failed')
    foreach ($s in $stats) {
        $row = New-StatRow -Name $s -Key $s
        [void]$statsLayout.Controls.Add($row)
        $Script:Ui["lblStat$s"] = $row.Tag.ValueLabel
        $Script:Ui["lblStatName$s"] = $row.Tag.NameLabel
    }
    [void]$summaryContent.Controls.Add($statsLayout)

    $statusPanel = New-SectionPanel -Title 'Status / Progress'
    $statusContent = [System.Windows.Forms.Panel]$statusPanel.Tag.Content
    $statusLayout = [System.Windows.Forms.TableLayoutPanel]::new()
    $statusLayout.Dock = 'Fill'
    $statusLayout.ColumnCount = 1
    $statusLayout.RowCount = 3
    $statusLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
    $statusLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
    $statusLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
    $lblPhase = New-StyledLabel -Text 'Phase: Idle' -Size 10 -Bold $true -Color $Theme.Fore
    $pbPhase = [System.Windows.Forms.ProgressBar]::new(); $pbPhase.Dock='Fill'; $pbPhase.Style='Continuous'; $pbPhase.Maximum=100
    $lblPhaseHint = New-StyledLabel -Text 'Preflight → Resolve cache → Download/Repair → Finalize' -Size 8.7 -Color $Theme.Muted
    [void]$statusLayout.Controls.Add($lblPhase,0,0)
    [void]$statusLayout.Controls.Add($pbPhase,0,1)
    [void]$statusLayout.Controls.Add($lblPhaseHint,0,2)
    [void]$statusContent.Controls.Add($statusLayout)

    $logPanel = New-SectionPanel -Title 'Activity Log' -Collapsible $true
    $logContent = [System.Windows.Forms.Panel]$logPanel.Tag.Content
    $runsPanel = New-SectionPanel -Title 'Recent Runs'
    $runsContent = [System.Windows.Forms.Panel]$runsPanel.Tag
    $runsLayout = [System.Windows.Forms.TableLayoutPanel]::new()
    $runsLayout.Dock = 'Fill'
    $runsLayout.ColumnCount = 1
    $runsLayout.RowCount = 3
    $runsLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 150))
    $runsLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 38))
    $runsLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))

    $lvRuns = [System.Windows.Forms.ListView]::new()
    $lvRuns.Dock = 'Fill'
    $lvRuns.View = [System.Windows.Forms.View]::Details
    $lvRuns.FullRowSelect = $true
    $lvRuns.HideSelection = $false
    $lvRuns.MultiSelect = $false
    $lvRuns.BackColor = [System.Drawing.Color]::FromArgb(21, 26, 33)
    $lvRuns.ForeColor = $Theme.Fore
    $lvRuns.Font = [System.Drawing.Font]::new('Segoe UI', 8.5)
    [void]$lvRuns.Columns.Add('Run', 124)
    [void]$lvRuns.Columns.Add('Timestamp', 145)
    [void]$lvRuns.Columns.Add('Parsed', 54)
    [void]$lvRuns.Columns.Add('Downloaded', 78)
    [void]$lvRuns.Columns.Add('Failed', 54)

    $runsButtons = [System.Windows.Forms.FlowLayoutPanel]::new()
    $runsButtons.Dock = 'Fill'
    $runsButtons.FlowDirection = 'LeftToRight'
    $runsButtons.WrapContents = $false

    $btnOpenRun = New-StyledButton -Text 'Open Run Folder' -Width 130
    $btnOpenUnresolved = New-StyledButton -Text 'Open Unresolved' -Width 130
    $btnOpenDiag = New-StyledButton -Text 'Open Diagnostics' -Width 130
    [void]$runsButtons.Controls.Add($btnOpenRun)
    [void]$runsButtons.Controls.Add($btnOpenUnresolved)
    [void]$runsButtons.Controls.Add($btnOpenDiag)

    $lblRunsHint = New-StyledLabel -Text 'Set root folder + deck name to load run history.' -Size 8.7 -Color $Theme.Muted

    [void]$runsLayout.Controls.Add($lvRuns, 0, 0)
    [void]$runsLayout.Controls.Add($runsButtons, 0, 1)
    [void]$runsLayout.Controls.Add($lblRunsHint, 0, 2)
    [void]$runsContent.Controls.Add($runsLayout)

    $logPanel = New-SectionPanel -Title 'Activity Log'
    $logContent = [System.Windows.Forms.Panel]$logPanel.Tag
    $txtLog = New-StyledTextBox -Multiline $true -ReadOnly $true
    $txtLog.Font = [System.Drawing.Font]::new('Consolas', (9 * $Script:UiScale))
    [void]$logContent.Controls.Add($txtLog)

    [void]$topRight.Panel1.Controls.Add($summaryPanel)
    [void]$topRight.Panel2.Controls.Add($statusPanel)
    [void]$rightSplit.Panel1.Controls.Add($topRight)
    [void]$rightSplit.Panel2.Controls.Add($logPanel)
    [void]$right.Controls.Add($summaryPanel, 0, 0)
    [void]$right.Controls.Add($statusPanel, 0, 1)
    [void]$right.Controls.Add($runsPanel, 0, 2)
    [void]$right.Controls.Add($logPanel, 0, 3)

    [void]$main.Controls.Add($left, 0, 0)
    [void]$main.Controls.Add($rightSplit, 1, 0)

    # D bottom bar
    $bottom = [System.Windows.Forms.TableLayoutPanel]::new()
    $bottom.Dock = 'Fill'
    $bottom.BackColor = $Theme.Panel2
    $bottom.Padding = [System.Windows.Forms.Padding]::new((Scale-UiValue -Value 8))
    $bottom.ColumnCount = 3
    $bottom.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 40))
    $bottom.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 37))
    $bottom.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 23))

    $lblBottomStatus = New-StyledLabel -Text 'Ready.' -Size 10 -Bold $true -Color $Theme.Fore
    $pbBottom = [System.Windows.Forms.ProgressBar]::new(); $pbBottom.Dock='Fill'; $pbBottom.Maximum=100; $pbBottom.Style='Continuous'
    $btnRun = New-StyledButton -Text 'Download Images' -Primary $true -Width 180
    $btnCancel = New-StyledButton -Text 'Cancel' -Width 110
    $btnCancel.Enabled = $false
    $actionBottomFlow = [System.Windows.Forms.FlowLayoutPanel]::new()
    $actionBottomFlow.Dock = [System.Windows.Forms.DockStyle]::Fill
    $actionBottomFlow.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
    $actionBottomFlow.WrapContents = $false
    [void]$actionBottomFlow.Controls.Add($btnCancel)
    [void]$actionBottomFlow.Controls.Add($btnRun)

    [void]$bottom.Controls.Add($lblBottomStatus, 0, 0)
    [void]$bottom.Controls.Add($pbBottom, 1, 0)
    [void]$bottom.Controls.Add($actionBottomFlow, 2, 0)

    [void]$root.Controls.Add($hdr, 0, 0)
    [void]$root.Controls.Add($controlsPanel, 0, 1)
    [void]$root.Controls.Add($main, 0, 2)
    [void]$root.Controls.Add($bottom, 0, 3)
    [void]$form.Controls.Add($root)

    # expose UI references
    $Script:Ui.form = $form
    $Script:Ui.lblHeaderChip = $chip
    $Script:Ui.txtDeckName = $txtDeckName
    $Script:Ui.txtRootFolder = $txtRoot
    $Script:Ui.cbImageType = $cbImage
    $Script:Ui.txtPreferredSet = $txtSet
    $Script:Ui.chkOnlyMissing = $chkOnlyMissing
    $Script:Ui.chkRepairMode = $chkRepair
    $Script:Ui.btnBrowse = $btnBrowse
    $Script:Ui.btnLoad = $btnLoad
    $Script:Ui.btnAutoName = $btnAuto
    $Script:Ui.btnTestApi = $btnTestApi
    $Script:Ui.btnRefreshIndex = $btnRefresh
    $Script:Ui.txtDecklist = $txtDeck
    $Script:Ui.txtPreflight = $txtPreflight
    $Script:Ui.lblDeckValidation = $lblDeckValidation
    $Script:Ui.lblRootValidation = $lblRootValidation
    $Script:Ui.lblImageValidation = $lblImageValidation
    $Script:Ui.lblSetValidation = $lblSetValidation
    $Script:Ui.txtActivity = $txtLog
    $Script:Ui.lblPhase = $lblPhase
    $Script:Ui.pbBottom = $pbBottom
    $Script:Ui.pbPhase = $pbPhase
    $Script:Ui.lblBottomStatus = $lblBottomStatus
    $Script:Ui.btnRun = $btnRun
    $Script:Ui.rightSplit = $rightSplit
    $Script:Ui.topRightSplit = $topRight
    $Script:Ui.summaryPanel = $summaryPanel
    $Script:Ui.logPanel = $logPanel
    $Script:Ui.lvRecentRuns = $lvRuns
    $Script:Ui.lblRecentRunsHint = $lblRunsHint
    $Script:Ui.btnOpenRunFolder = $btnOpenRun
    $Script:Ui.btnOpenUnresolved = $btnOpenUnresolved
    $Script:Ui.btnOpenDiagnostics = $btnOpenDiag
    $Script:Ui.btnCancel = $btnCancel

    return $form
}

# ==============================
# EVENT HANDLERS
# ==============================
function Wire-Events {
    [CmdletBinding()]
    param()

    $Script:Ui.btnBrowse.Add_Click({
        $dlg = [System.Windows.Forms.FolderBrowserDialog]::new()
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $Script:Ui.txtRootFolder.Text = $dlg.SelectedPath
            [void](Validate-RunInputs -UpdateUi)
        }
    })

    $Script:Ui.btnLoad.Add_Click({
        $dlg = [System.Windows.Forms.OpenFileDialog]::new()
        $dlg.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $Script:Ui.txtDecklist.Text = Get-Content -Path $dlg.FileName -Raw -Encoding UTF8
            Write-UiLog -Message "Loaded decklist file: $($dlg.FileName)"
            [void](Validate-RunInputs -UpdateUi)
        }
    })

    $Script:Ui.btnAutoName.Add_Click({
        $parsed = Parse-Decklist -DeckText $Script:Ui.txtDecklist.Text
        $first = $parsed.Cards | Select-Object -First 1
        if ($null -ne $first) {
            $Script:Ui.txtDeckName.Text = ("{0} Deck" -f ($first.Name -replace '[^a-zA-Z0-9 ]','').Trim())
        }
        [void](Validate-RunInputs -UpdateUi)
    })

    $Script:Ui.btnTestApi.Add_Click({
        try {
            Set-PhaseText -Text 'Testing API'
            $null = Invoke-ScryfallLookup -Name 'Sol Ring' -PreferredSet $Script:Ui.txtPreferredSet.Text
            Write-UiLog -Message 'Scryfall API test successful.'
            Set-StatusText -Text 'API test succeeded.'
        }
        catch {
            Write-UiLog -Message "API test failed: $($_.Exception.Message)" -Level 'WARN'
            Set-StatusText -Text 'API test failed.'
        }
    })

    $Script:Ui.btnRefreshIndex.Add_Click({
        try {
            $validation = Validate-RunInputs -UpdateUi
            if (-not $validation.IsValid) {
                throw 'Fix validation errors before refreshing index.'
            }
            $root = $Script:Ui.txtRootFolder.Text.Trim()
            $deckName = if ([string]::IsNullOrWhiteSpace($Script:Ui.txtDeckName.Text)) { 'Deck' } else { $Script:Ui.txtDeckName.Text.Trim() }
            $model = Get-StorageModel -Root $root -DeckName $deckName
            Ensure-StorageModel -Model $model
            $current = Load-JsonOrDefault -Path $model.CardIndexPath -Default @{}
            Save-Json -InputObject $current -Path $model.CardIndexPath
            Write-UiLog -Message 'Metadata index refresh completed.'
            Refresh-RecentRunsUi
        }
        catch {
            Write-UiLog -Message "Metadata refresh failed: $($_.Exception.Message)" -Level 'WARN'
        }
    })

    $livePreflightTimer = [System.Windows.Forms.Timer]::new()
    $livePreflightTimer.Interval = [Math]::Max(250, [Math]::Min(500, [int]$AppConfig.LiveParseDebounceMs))
    $Script:Ui.livePreflightTimer = $livePreflightTimer

    $livePreflightTimer.Add_Tick({
        $Script:Ui.livePreflightTimer.Stop()
        try {
            Set-UiState -State 'validating'
            $validation = Validate-RunInputs -UpdateUi
            if (-not $validation.IsValid) {
                return
            }
            $root = $Script:Ui.txtRootFolder.Text.Trim()
            $deck = $Script:Ui.txtDeckName.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($root) -or [string]::IsNullOrWhiteSpace($deck)) {
                Set-UiState -State 'idle'
                return
            }

            $scheduledRoot = [string]$Script:RunState.LivePreflightScheduledRoot
            $scheduledDeck = [string]$Script:RunState.LivePreflightScheduledDeck
            if ($root -ne $scheduledRoot -or $deck -ne $scheduledDeck) {
                return
            }

            $parsed = Parse-Decklist -DeckText $Script:Ui.txtDecklist.Text
            $model = Get-StorageModel -Root $root -DeckName $deck

            $storageModelKey = ('{0}|{1}' -f $root.ToLowerInvariant(), $deck.ToLowerInvariant())
            if ($Script:RunState.LivePreflightStorageKey -ne $storageModelKey) {
                Ensure-StorageModel -Model $model
                $Script:RunState.LivePreflightStorageKey = $storageModelKey
            }

            $pre = Get-Preflight -Parsed $parsed -Model $model
            Update-PreflightUi -Preflight $pre
        }
        catch {
            Set-UiState -State 'error'
            # intentionally quiet on live parse
        }
    })

    $Script:Ui.txtRootFolder.Add_TextChanged({
        $Script:RunState.LivePreflightStorageKey = ''
    })

    $Script:Ui.txtDeckName.Add_TextChanged({
        $Script:RunState.LivePreflightStorageKey = ''
    })

    $Script:Ui.txtDecklist.Add_TextChanged({
        try {
            $Script:RunState.LivePreflightScheduledRoot = $Script:Ui.txtRootFolder.Text.Trim()
            $Script:RunState.LivePreflightScheduledDeck = $Script:Ui.txtDeckName.Text.Trim()
            $Script:Ui.livePreflightTimer.Stop()
            $Script:Ui.livePreflightTimer.Start()
        }
        catch {
            # intentionally quiet on live parse
        }
    })

    $Script:Ui.txtDeckName.Add_TextChanged({
        try { Refresh-RecentRunsUi } catch { }
    })

    $Script:Ui.txtRootFolder.Add_TextChanged({
        try { Refresh-RecentRunsUi } catch { }
    })

    $Script:Ui.btnOpenRunFolder.Add_Click({
        $selected = Get-SelectedRunRecord
        if ($null -eq $selected) {
            Write-UiLog -Message 'Select a run row first to open its folder.' -Level 'WARN'
            return
        }
        if (Open-PathInShell -Path $selected.RunFolder) {
            Write-UiLog -Message "Opened run folder: $($selected.RunFolder)"
        }
        else {
            Write-UiLog -Message 'Run folder was not found.' -Level 'WARN'
        }
    })

    $Script:Ui.btnOpenUnresolved.Add_Click({
        $selected = Get-SelectedRunRecord
        if ($null -eq $selected) {
            Write-UiLog -Message 'Select a run row first to open unresolved list.' -Level 'WARN'
            return
        }
        if (Open-PathInShell -Path $selected.UnresolvedPath) {
            Write-UiLog -Message "Opened unresolved list: $($selected.UnresolvedPath)"
        }
        else {
            Write-UiLog -Message 'No unresolved file found for selected run.' -Level 'WARN'
        }
    })

    $Script:Ui.btnOpenDiagnostics.Add_Click({
        $selected = Get-SelectedRunRecord
        if ($null -eq $selected) {
            Write-UiLog -Message 'Select a run row first to open diagnostics log.' -Level 'WARN'
            return
        }
        if (Open-PathInShell -Path $selected.DiagnosticPath) {
            Write-UiLog -Message "Opened diagnostics log: $($selected.DiagnosticPath)"
        }
        else {
            Write-UiLog -Message 'No diagnostics log found for selected run.' -Level 'WARN'
        }
    })

    $Script:Ui.btnRun.Add_Click({
        try {
            $validation = Validate-RunInputs -UpdateUi
            if (-not $validation.IsValid) {
                throw 'Fix validation errors before running.'
            }
            if ($Script:RunState.ContainsKey('IsRunning') -and $Script:RunState.IsRunning) {
                if ($Script:RunState.ContainsKey('CancellationTokenSource') -and $null -ne $Script:RunState.CancellationTokenSource) {
                    Set-StatusText -Text 'Cancellation requested...'
                    Write-UiLog -Message 'Cancellation requested by user.' -Level 'WARN'
                    $Script:RunState.CancellationTokenSource.Cancel()
                }
                return
            }

            $deckText = $Script:Ui.txtDecklist.Text
            $deckName = $Script:Ui.txtDeckName.Text.Trim()
            $root = $Script:Ui.txtRootFolder.Text.Trim()

            if ([string]::IsNullOrWhiteSpace($deckText)) { throw 'Decklist is empty.' }
            if ([string]::IsNullOrWhiteSpace($deckName)) { throw 'Deck name is required.' }
            if ([string]::IsNullOrWhiteSpace($root)) { throw 'Root output folder is required.' }

            Set-UiState -State 'validating'
            Set-ExecutionControlsEnabled -Enabled $false
            $Script:Ui.btnRun.Enabled = $true
            $Script:Ui.btnRun.Text = 'Cancel Run'
            Set-StatusText -Text 'Running...'
            Set-Progress -Value 0
            Set-BottomProgress -Value 0
            Set-PhaseText -Text 'Preflight validation'
            $Script:Ui.btnRun.Enabled = $false
            $Script:Ui.btnCancel.Enabled = $true
            Reset-RunCancellation
            $Script:RunState.IsRunning = $true

            $parsed = Parse-Decklist -DeckText $deckText
            if ($parsed.Cards.Count -eq 0) {
                throw 'No valid quantity-prefixed card lines were detected.'
            }

            $model = Get-StorageModel -Root $root -DeckName $deckName
            Ensure-StorageModel -Model $model
            $pre = Get-Preflight -Parsed $parsed -Model $model
            Update-PreflightUi -Preflight $pre

            Set-UiState -State 'running'
            $result = Invoke-DeckRun -DeckText $deckText -DeckName $deckName -Root $root -ImageType $Script:Ui.cbImageType.SelectedItem.ToString() -PreferredSet $Script:Ui.txtPreferredSet.Text.Trim() -OnlyMissing:$Script:Ui.chkOnlyMissing.Checked -RepairMode:$Script:Ui.chkRepairMode.Checked
            Set-UiState -State 'completed'
            Write-UiLog -Message "Run output written to $($result.Model.RunFolder)"
            Refresh-RecentRunsUi
        }
        catch {
            Set-StatusText -Text 'Run failed.'
            Set-UiState -State 'error'
            Write-UiLog -Message "Run ($($result.Status)) output written to $($result.Model.RunFolder)"
            $runArgs = [pscustomobject]@{
                DeckText = $deckText
                DeckName = $deckName
                Root = $root
                ImageType = $Script:Ui.cbImageType.SelectedItem.ToString()
                PreferredSet = $Script:Ui.txtPreferredSet.Text.Trim()
                OnlyMissing = $Script:Ui.chkOnlyMissing.Checked
                RepairMode = $Script:Ui.chkRepairMode.Checked
            }

            $Script:RunState.PendingResult = $null
            $Script:RunState.CancellationTokenSource = [System.Threading.CancellationTokenSource]::new()
            $reporter = New-ProgressReporter
            $Script:RunState.ActiveTask = [System.Threading.Tasks.Task]::Run([Action]{
                $Script:RunState.PendingResult = Invoke-DeckRun -DeckText $runArgs.DeckText -DeckName $runArgs.DeckName -Root $runArgs.Root -ImageType $runArgs.ImageType -PreferredSet $runArgs.PreferredSet -OnlyMissing:$runArgs.OnlyMissing -RepairMode:$runArgs.RepairMode -ProgressReporter $reporter -CancellationToken $Script:RunState.CancellationTokenSource.Token
            }, $Script:RunState.CancellationTokenSource.Token)

            $timer = [System.Windows.Forms.Timer]::new()
            $timer.Interval = 200
            $timer.Add_Tick({
                if (-not $Script:RunState.ContainsKey('ActiveTask') -or $null -eq $Script:RunState.ActiveTask) {
                    $this.Stop()
                    $this.Dispose()
                    return
                }

                if (-not $Script:RunState.ActiveTask.IsCompleted) {
                    return
                }

                $this.Stop()
                $this.Dispose()

                try {
                    $Script:RunState.ActiveTask.GetAwaiter().GetResult()
                    if ($null -ne $Script:RunState.PendingResult) {
                        Write-UiLog -Message "Run output written to $($Script:RunState.PendingResult.Model.RunFolder)"
                    }
                }
                catch [System.OperationCanceledException] {
                    Set-PhaseText -Text 'Cancelled'
                    Set-StatusText -Text 'Run cancelled.'
                    Write-UiLog -Message 'Run cancelled.' -Level 'WARN'
                }
                catch {
                    Set-StatusText -Text 'Run failed.'
                    Set-PhaseText -Text 'Error'
                    $baseEx = $_.Exception
                    if ($baseEx -is [System.AggregateException]) {
                        $baseEx = $baseEx.GetBaseException()
                    }
                    Write-UiLog -Message $baseEx.Message -Level 'ERROR'
                }
                finally {
                    if ($Script:RunState.ContainsKey('CancellationTokenSource') -and $null -ne $Script:RunState.CancellationTokenSource) {
                        $Script:RunState.CancellationTokenSource.Dispose()
                    }
                    $Script:RunState.ActiveTask = $null
                    $Script:RunState.CancellationTokenSource = $null
                    $Script:RunState.PendingResult = $null
                    $Script:RunState.IsRunning = $false
                    Set-ExecutionControlsEnabled -Enabled $true
                    $Script:Ui.btnRun.Text = 'Download Images'
                }
            })
            $timer.Start()
        }
        catch {
            Set-StatusText -Text 'Run failed.'
            Set-PhaseText -Text 'Error'
            Set-BottomProgress -Value 0
            Write-UiLog -Message $_.Exception.Message -Level 'ERROR'
        }
        finally {
            $Script:RunState.IsRunning = $false
            $Script:Ui.btnRun.Enabled = $true
            $Script:Ui.btnCancel.Enabled = $false
        }
    })

    $Script:Ui.btnCancel.Add_Click({
        if ($Script:RunState.IsRunning) {
            Request-RunCancellation
            Set-PhaseText -Text 'Cancelling...'
            Set-StatusText -Text 'Cancellation requested...'
            $Script:Ui.btnCancel.Enabled = $false
            if (-not ($Script:RunState.ContainsKey('IsRunning') -and $Script:RunState.IsRunning)) {
                Set-ExecutionControlsEnabled -Enabled $true
                $Script:Ui.btnRun.Text = 'Download Images'
                $Script:Ui.btnRun.Enabled = $true
            }
        }
    })

    if ($Script:Ui.summaryPanel.Tag.ContainsKey('Toggle')) {
        $Script:Ui.summaryPanel.Tag.Toggle.Add_Click({
            if (& $Script:Ui.summaryPanel.Tag.GetCollapsed) {
                Write-UiLog -Message 'Run Summary collapsed.'
            }
            else {
                Write-UiLog -Message 'Run Summary expanded.'
            }
        })
    }
    if ($Script:Ui.logPanel.Tag.ContainsKey('Toggle')) {
        $Script:Ui.logPanel.Tag.Toggle.Add_Click({
            if (& $Script:Ui.logPanel.Tag.GetCollapsed) {
                Write-UiLog -Message 'Activity Log collapsed.'
            }
            else {
                Write-UiLog -Message 'Activity Log expanded.'
            }
        })
    }

    $Script:Ui.form.Add_Shown({
        $prefsObj = Get-UiPreferences
        $prefs = @{}
        if ($prefsObj -is [hashtable]) {
            $prefs = $prefsObj
        }
        else {
            foreach ($prop in $prefsObj.PSObject.Properties) {
                $prefs[$prop.Name] = $prop.Value
            }
        }

        $topRightDistance = Get-IntPreference -Value $prefs.top_right_splitter -Fallback $Script:Ui.topRightSplit.SplitterDistance
        $rightDistance = Get-IntPreference -Value $prefs.right_splitter -Fallback $Script:Ui.rightSplit.SplitterDistance
        $summaryCollapsed = [bool](if ($prefs.ContainsKey('summary_collapsed')) { $prefs.summary_collapsed } else { $false })
        $logCollapsed = [bool](if ($prefs.ContainsKey('log_collapsed')) { $prefs.log_collapsed } else { $false })

        $Script:Ui.topRightSplit.SplitterDistance = [Math]::Min([Math]::Max($Script:Ui.topRightSplit.Panel1MinSize, $topRightDistance), $Script:Ui.topRightSplit.Height - $Script:Ui.topRightSplit.Panel2MinSize)
        $Script:Ui.rightSplit.SplitterDistance = [Math]::Min([Math]::Max($Script:Ui.rightSplit.Panel1MinSize, $rightDistance), $Script:Ui.rightSplit.Height - $Script:Ui.rightSplit.Panel2MinSize)
        Set-SectionCollapsedState -SectionPanel $Script:Ui.summaryPanel -Collapsed $summaryCollapsed
        Set-SectionCollapsedState -SectionPanel $Script:Ui.logPanel -Collapsed $logCollapsed
    })

    $Script:Ui.form.Add_FormClosing({
        $prefs = @{
            top_right_splitter = $Script:Ui.topRightSplit.SplitterDistance
            right_splitter = $Script:Ui.rightSplit.SplitterDistance
            summary_collapsed = (& $Script:Ui.summaryPanel.Tag.GetCollapsed)
            log_collapsed = (& $Script:Ui.logPanel.Tag.GetCollapsed)
            ui_scale = [Math]::Round($Script:UiScale, 3)
        }
        Save-UiPreferences -Values $prefs
    })

    return
}

# ==============================
# APP BOOTSTRAP
# ==============================
$form = Build-MainForm
Wire-Events
Refresh-RecentRunsUi
Set-UiState -State 'idle'
[void](Validate-RunInputs -UpdateUi)
Set-StatusText -Text 'Ready. Paste a decklist, configure output, and run.'
Write-UiLog -Message 'Deckstacy initialized.'
[void]$form.ShowDialog()
