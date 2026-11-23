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

$repos = @(
  @{ name = "moonlight-common-c"; upstream = "moonlight-stream/moonlight-common-c"; patches = "common-c" },
  @{ name = "Sunshine";           upstream = "LizardByte/Sunshine";                 patches = "sunshine" },
  @{ name = "moonlight-qt";       upstream = "moonlight-stream/moonlight-qt";       patches = "moonlight-qt";
     sub = "moonlight-common-c/moonlight-common-c" },
  @{ name = "moonlight-android";  upstream = "moonlight-stream/moonlight-android";  patches = "moonlight-android";
     sub = "app/src/main/jni/moonlight-core/moonlight-common-c"; workflow = "android-ci.yml" }
)

New-Item -ItemType Directory -Force $Work | Out-Null
$commonSha = $null

foreach ($r in $repos) {
  Write-Host "== $($r.name)"
  Invoke-Gh repo fork $r.upstream --clone=false --default-branch-only | Out-Null  # no-op if it exists

  $dir  = Join-Path $Work $r.name
  $base = (Get-Content (Join-Path $root "patches\$($r.patches)\BASE_COMMIT")).Trim()
  if (-not (Test-Path $dir)) { Invoke-Git clone "https://github.com/$Owner/$($r.name).git" $dir }

  Push-Location $dir
  try {
    Invoke-Git fetch -q "https://github.com/$($r.upstream).git" $base
    Invoke-Git checkout -q -B rd $base
    Invoke-Git -c user.name=rd -c user.email=rd@users.noreply.github.com am -q (Get-ChildItem (Join-Path $root "patches\$($r.patches)\*.patch") | Sort-Object Name | ForEach-Object FullName)

    if ($r.sub) {
      # Point the common-c submodule at our fork's rd commit
      Invoke-Git submodule update --init -q $r.sub
      Invoke-Git -C $r.sub fetch -q "https://github.com/$Owner/moonlight-common-c.git" rd
      Invoke-Git -C $r.sub checkout -q $commonSha
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

    if ($r.name -eq "moonlight-common-c") { $commonSha = (git rev-parse HEAD).Trim() }

    # Forks have Actions off by default
    Invoke-Gh api -X PUT "repos/$Owner/$($r.name)/actions/permissions" -F enabled=true -f allowed_actions=all | Out-Null
    Invoke-Git push -q -f origin rd
  }
  finally { Pop-Location }
}

# Sunshine CI only runs on master pushes; start it by hand on rd.
Start-Sleep 5
Invoke-Gh workflow run ci.yml -R "$Owner/Sunshine" --ref rd
Write-Host ""
Write-Host "Done. Builds:"
foreach ($r in $repos | Where-Object name -ne "moonlight-common-c") {
  Write-Host "  https://github.com/$Owner/$($r.name)/actions"
}
