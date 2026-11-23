<#
  Creates/updates the 4 forks on GitHub with the RD patches, then starts their CI builds.
  Needs: git, GitHub CLI (gh auth login done).
    .\forks\setup-forks.ps1                 # owner daviied
    .\forks\setup-forks.ps1 -Owner someone
  Result: branch "rd" in each fork. Build artifacts appear in each fork's Actions tab.
#>
param(
  [string]$Owner = "daviied",
  [string]$Work  = (Join-Path $env:TEMP "rd-forks")
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent

# Windows PowerShell 5.1 turns native stderr (git progress text) into errors; judge by exit code only.
function Invoke-Git {
  $ErrorActionPreference = "Continue"
  git @args 2>&1 | ForEach-Object { "$_" } | Write-Host
  if ($LASTEXITCODE -ne 0) { throw "git $args failed" }
}
function Invoke-Gh {
  $ErrorActionPreference = "Continue"
  gh @args 2>&1 | ForEach-Object { "$_" }
}

# moonlight-qt and moonlight-android pin different moonlight-common-c versions, so the
# common-c fork gets one RD branch per app: "rd" (moonlight-qt) and "rd-android".
$repos = @(
  @{ name = "moonlight-common-c"; upstream = "moonlight-stream/moonlight-common-c"; patches = "common-c"; branch = "rd" },
  @{ name = "moonlight-common-c"; upstream = "moonlight-stream/moonlight-common-c"; patches = "common-c-android"; branch = "rd-android" },
  @{ name = "Sunshine";           upstream = "LizardByte/Sunshine";                 patches = "sunshine"; ciOnRd = $true },
  @{ name = "moonlight-qt";       upstream = "moonlight-stream/moonlight-qt";       patches = "moonlight-qt";
     sub = "moonlight-common-c/moonlight-common-c"; common = "rd" },
  @{ name = "moonlight-android";  upstream = "moonlight-stream/moonlight-android";  patches = "moonlight-android";
     sub = "app/src/main/jni/moonlight-core/moonlight-common-c"; common = "rd-android"; workflow = "android-ci.yml" }
)

New-Item -ItemType Directory -Force $Work | Out-Null
$commonSha = @{}

foreach ($r in $repos) {
  $branch = if ($r.branch) { $r.branch } else { "rd" }
  Write-Host "== $($r.name) ($branch)"
  Invoke-Gh repo fork $r.upstream --clone=false --default-branch-only | Out-Null  # no-op if it exists

  $dir  = Join-Path $Work $r.name
  $base = (Get-Content (Join-Path $root "patches\$($r.patches)\BASE_COMMIT")).Trim()
  if (-not (Test-Path $dir)) { Invoke-Git clone "https://github.com/$Owner/$($r.name).git" $dir }

  Push-Location $dir
  try {
    Invoke-Git fetch -q "https://github.com/$($r.upstream).git" $base
    Invoke-Git checkout -q -f -B $branch $base
    Invoke-Git -c user.name=rd -c user.email=rd@users.noreply.github.com am -q (Get-ChildItem (Join-Path $root "patches\$($r.patches)\*.patch") | Sort-Object Name | ForEach-Object FullName)

    if ($r.sub) {
      # Point the common-c submodule at our fork's matching RD commit
      Invoke-Git submodule update --init -q $r.sub
      Invoke-Git -C $r.sub fetch -q "https://github.com/$Owner/moonlight-common-c.git" $r.common
      Invoke-Git -C $r.sub checkout -q $commonSha[$r.common]
      Invoke-Git config -f .gitmodules "submodule.$($r.sub).url" "https://github.com/$Owner/moonlight-common-c.git"
      Invoke-Git add .gitmodules $r.sub
      Invoke-Git -c user.name=rd -c user.email=rd@users.noreply.github.com commit -q -m "RD: use RD moonlight-common-c"
    }
    if ($r.workflow) {
      New-Item -ItemType Directory -Force ".github\workflows" | Out-Null
      Copy-Item (Join-Path $PSScriptRoot $r.workflow) ".github\workflows\rd-$($r.workflow)"
      Invoke-Git add .github/workflows
      Invoke-Git -c user.name=rd -c user.email=rd@users.noreply.github.com commit -q -m "RD: CI build"
    }

    if ($r.ciOnRd) {
      # Sunshine CI runs on pushes to master only (and its release step fails on manual runs): add rd
      $ci = ".github\workflows\ci.yml"
      $t = [IO.File]::ReadAllText((Resolve-Path $ci))
      $t = [regex]::new("(?m)^(\s+)- master(\r?)$").Replace($t, '$1- master$2' + "`n" + '$1- rd$2', 1)
      [IO.File]::WriteAllText((Resolve-Path $ci), $t)
      Invoke-Git add $ci
      Invoke-Git -c user.name=rd -c user.email=rd@users.noreply.github.com commit -q -m "RD: run CI on rd"
    }

    if ($r.name -eq "moonlight-qt") {
      # Qt Creator tools no longer download in a fresh (uncached) fork; only jom needs them and the build falls back to nmake
      $wf = ".github\workflows\build-win-mac.yml"
      $t = [IO.File]::ReadAllText((Resolve-Path $wf))
      $t = [regex]::Replace($t, "(?m)^\s+tools: .*tools_qtcreator_gui.*\r?\n", "")
      [IO.File]::WriteAllText((Resolve-Path $wf), $t)
      Invoke-Git add $wf
      Invoke-Git -c user.name=rd -c user.email=rd@users.noreply.github.com commit -q -m "RD: skip Qt Creator tools (package gone; build falls back to nmake)"
    }

    if ($r.name -eq "moonlight-common-c") { $commonSha[$branch] = (git rev-parse HEAD).Trim() }

    # Forks have Actions off by default
    Invoke-Gh api -X PUT "repos/$Owner/$($r.name)/actions/permissions" -F enabled=true -f allowed_actions=all | Out-Null
    Invoke-Git push -q -f origin $branch
  }
  finally { Pop-Location }
}

Write-Host ""
Write-Host "Done. Builds:"
foreach ($r in $repos | Where-Object { $_.name -ne "moonlight-common-c" }) {
  Write-Host "  https://github.com/$Owner/$($r.name)/actions"
}
