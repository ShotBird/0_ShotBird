# skills/* 를 ~/.claude/skills/ 에 junction으로 연결한다 (관리자 권한 불필요).
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$dest = Join-Path $env:USERPROFILE ".claude\skills"
New-Item -ItemType Directory -Force $dest | Out-Null
Get-ChildItem (Join-Path $root "skills") -Directory | ForEach-Object {
    $link = Join-Path $dest $_.Name
    if (Test-Path $link) {
        $item = Get-Item $link -Force
        if ($item.LinkType -eq "Junction") { Write-Output "이미 연결됨: $link"; return }
        Write-Output "건너뜀(같은 이름의 폴더가 있음): $link"; return
    }
    cmd /c mklink /J "$link" "$($_.FullName)" | Out-Null
    Write-Output "연결: $link -> $($_.FullName)"
}
