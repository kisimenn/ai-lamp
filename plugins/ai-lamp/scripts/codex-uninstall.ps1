# Codex からランプのフックを外す（ほかのフックは残す）
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web.Extensions
$json = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$utf8 = New-Object System.Text.UTF8Encoding $false

$hooksFile = Join-Path $env:USERPROFILE '.codex\hooks.json'
if (Test-Path $hooksFile) {
    $doc = $json.DeserializeObject([System.IO.File]::ReadAllText($hooksFile, $utf8))
    if ($doc.ContainsKey('hooks') -and $doc['hooks']) {
        $hooks = $doc['hooks']
        foreach ($ev in @($hooks.Keys)) {
            # パイプラインは使わない（中身が PSObject に包まれて保存で失敗する）
            $groups = [System.Collections.ArrayList]::new()
            foreach ($g in $hooks[$ev]) { if ($json.Serialize($g) -notmatch 'ai-lamp') { [void]$groups.Add($g) } }
            if ($groups.Count) { $hooks[$ev] = $groups.ToArray() } else { [void]$hooks.Remove($ev) }
        }
    }
    [System.IO.File]::WriteAllText($hooksFile, $json.Serialize($doc), $utf8)
}
Remove-Item -Recurse -Force (Join-Path $env:USERPROFILE '.cache\ai-lamp\bin') -ErrorAction SilentlyContinue
"Codex からランプのフックを外しました"
