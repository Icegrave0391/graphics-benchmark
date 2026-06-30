<#
  tools.ps1 — graphics-benchmark Windows guest helpers (counterpart of tools.sh).

  Run inside the guest, or from the host over SSH:
    .\tools.ps1                       # Detect-Pipeline (default)
    .\tools.ps1 Detect-Pipeline
    powershell -ExecutionPolicy Bypass -File tools.ps1 -Help

  From the host:
    ./ssh-vm.sh -- "powershell -ExecutionPolicy Bypass -Command -" < tools.ps1
    (or copy it in and run locally)

  Detect-Pipeline inspects the display adapter(s) and Direct3D capability to
  report which GPU path is active:
    passthrough  — a real AMD Radeon adapter (native DX, hardware 3D)
    virtio-gpu   — Red Hat VirtIO GPU (display-only; 3D is SOFTWARE/WARP)
    basic        — Microsoft Basic Display Adapter (no GPU driver)
  On Windows under virtio-gpu there is NO hardware 3D (DX/GL/Vulkan run on the
  WARP software rasterizer); real graphics benchmarking needs passthrough.
  See docs/benchmark-design.md and the README in this directory.
#>

[CmdletBinding()]
param(
  [Parameter(Position = 0)] [string] $Function = 'Detect-Pipeline',
  [switch] $Help
)

function Show-Usage {
  @"
tools.ps1 — graphics-benchmark Windows guest helpers

USAGE
  tools.ps1 [-Help] [Function]

FUNCTIONS (default: Detect-Pipeline)
  Detect-Pipeline   classify the active GPU path (passthrough/virtio-gpu/basic)
  Get-Adapters      list display adapters (name, driver, status)
  Get-D3DInfo       dump dxdiag Direct3D / feature-level info

EXAMPLES
  .\tools.ps1
  .\tools.ps1 Get-Adapters
  # from host:
  ./ssh-vm.sh -- "powershell -ExecutionPolicy Bypass -Command -" < tools.ps1
"@ | Write-Output
}

function Get-Adapters {
  Get-CimInstance Win32_VideoController |
    Select-Object Name, DriverVersion, @{n='VRAM_MB';e={[int]($_.AdapterRAM/1MB)}}, Status
}

function Get-D3DInfo {
  $tmp = Join-Path $env:TEMP 'gb-dxdiag.txt'
  Start-Process dxdiag -ArgumentList "/t $tmp" -Wait
  # dxdiag /t returns before the file is flushed; wait briefly.
  for ($i=0; $i -lt 15 -and -not (Test-Path $tmp); $i++) { Start-Sleep 1 }
  if (Test-Path $tmp) {
    Get-Content $tmp |
      Select-String -Pattern 'Card name','Chip type','Display Memory','Direct3D','DDI Version','Feature Levels','Driver Model'
  } else {
    Write-Output '(dxdiag output not available)'
  }
}

function Detect-Pipeline {
  $adapters = @(Get-CimInstance Win32_VideoController)
  $names = $adapters | ForEach-Object { $_.Name }

  $verdict = 'unknown'
  if ($names -match 'AMD|Radeon|RADV') {
    $verdict = 'passthrough'      # real AMD GPU handed to the guest
  } elseif ($names -match 'VirtIO') {
    $verdict = 'virtio-gpu'       # Red Hat VirtIO GPU (display-only, no 3D)
  } elseif ($names -match 'Basic Display') {
    $verdict = 'basic'            # no GPU driver at all
  }

  Write-Output '== GPU pipeline detection (Windows) =='
  Write-Output '  Display adapters:'
  foreach ($a in $adapters) {
    Write-Output ('    - {0}  (drv {1}, {2})' -f $a.Name, $a.DriverVersion, $a.Status)
  }
  Write-Output -NoEnumerate ''
  switch ($verdict) {
    'passthrough' { Write-Output '  Verdict: PASSTHROUGH — real AMD GPU; native DirectX, hardware 3D.' }
    'virtio-gpu'  { Write-Output '  Verdict: VIRTIO-GPU — display-only (viogpudo). 3D is SOFTWARE (WARP); not a real-GPU benchmark.' }
    'basic'       { Write-Output '  Verdict: BASIC display adapter — no GPU driver; software rendering only.' }
    default       { Write-Output '  Verdict: unknown — see adapters above.' }
  }
  # machine-readable line for the harness
  Write-Output ("pipeline={0}" -f $verdict)
}

# --- dispatch ----------------------------------------------------------------
if ($Help) { Show-Usage; exit 0 }

switch ($Function) {
  'Detect-Pipeline' { Detect-Pipeline }
  'Get-Adapters'    { Get-Adapters }
  'Get-D3DInfo'     { Get-D3DInfo }
  default {
    Write-Error "unknown function: $Function"
    Show-Usage
    exit 1
  }
}
