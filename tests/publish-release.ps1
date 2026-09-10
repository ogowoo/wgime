# publish-release.ps1 -- create a GitHub release and upload its zip assets.
#
# ASCII only (PS 5.1 reads scripts as ANSI; the release body comes from an external
# UTF-8 file -- never build it inline, and never use Invoke-RestMethod + ConvertTo-Json:
# PowerShell 5.1 encodes the body as '?' and turns every Chinese character into a question
# mark. The body is sent as explicit UTF-8 bytes through HttpWebRequest.)
#
# Token: $env:GITHUB_TOKEN / $env:GH_TOKEN, otherwise the credential git already stores
# for github.com (git credential fill). The token is never printed.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\publish-release.ps1 `
#       -Version 1.2.7 -BodyFile C:\path\body.md -AssetsDir C:\path\to\zips
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$BodyFile,
    [Parameter(Mandatory = $true)][string]$AssetsDir,
    [string]$Repo = 'ogowoo/wgime',
    [string]$Name = '',
    [string]$Token = '',
    [switch]$Draft
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.WebRequest]::DefaultWebProxy = $null      # the machine-wide WinINET proxy is dead; go direct

# Token source order: -Token, GITHUB_TOKEN, GH_TOKEN, Windows Credential Manager
# (target "git:https://github.com", where Git Credential Manager keeps the PAT), and only
# then `git credential fill` -- GCM can block on a UI prompt, which wedges a release run.
function Get-CredManagerToken {
    if (-not ('CredMan' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class CredMan {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL {
        public uint Flags; public uint Type; public string TargetName; public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize; public IntPtr CredentialBlob;
        public uint Persist; public uint AttributeCount; public IntPtr Attributes;
        public string TargetAlias; public string UserName;
    }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CredRead(string target, uint type, uint reservedFlag, out IntPtr credentialPtr);
    [DllImport("advapi32.dll")] public static extern void CredFree(IntPtr cred);
    public static string Read(string target) {
        IntPtr p;
        if (!CredRead(target, 1, 0, out p)) return null;
        try {
            CREDENTIAL c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
            if (c.CredentialBlobSize == 0) return null;
            return Marshal.PtrToStringUni(c.CredentialBlob, (int)c.CredentialBlobSize / 2);
        } finally { CredFree(p); }
    }
}
'@ -Language CSharp
    }
    foreach ($t in @('git:https://github.com', 'git:https://oauth2@github.com')) {
        $v = [CredMan]::Read($t)
        if ($v) { return $v }
    }
    return $null
}

function Get-GitHubToken {
    if ($Token) { return $Token }
    if ($env:GITHUB_TOKEN) { return $env:GITHUB_TOKEN }
    if ($env:GH_TOKEN) { return $env:GH_TOKEN }
    $v = Get-CredManagerToken
    if ($v) { return $v }
    $c = "protocol=https`nhost=github.com`n`n" | git credential fill 2>$null
    $pw = ($c | Where-Object { $_ -like 'password=*' }) -replace '^password=', ''
    if (-not $pw) { throw 'no GitHub token: pass -Token, set GITHUB_TOKEN, or store a git credential for github.com' }
    return $pw
}

$token = Get-GitHubToken
$tag = "v$Version"
if (-not $Name) { $Name = "WgIme v$Version" }
if (-not (Test-Path $BodyFile)) { throw "body file not found: $BodyFile" }
$body = [IO.File]::ReadAllText($BodyFile, [Text.UTF8Encoding]::new($false))

function Invoke-GH([string]$Method, [string]$Url, [byte[]]$Bytes, [string]$ContentType) {
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Method = $Method
    $req.UserAgent = 'wgime-release'
    $req.Accept = 'application/vnd.github+json'
    $req.Headers.Add('Authorization', "Bearer $token")
    # 20-26 MB uploads need far more than the 120 s default; a finite cap still surfaces a
    # dead connection as an error instead of hanging forever.
    $req.Timeout = if ($Bytes) { 900000 } else { 60000 }
    $req.ReadWriteTimeout = 900000
    if ($Bytes) {
        $req.ContentType = $ContentType
        $req.ContentLength = $Bytes.Length
        $s = $req.GetRequestStream()
        $s.Write($Bytes, 0, $Bytes.Length)
        $s.Dispose()
    }
    try {
        $resp = $req.GetResponse()
    } catch [Net.WebException] {
        $e = $_.Exception.Response
        if ($e) {
            $r = New-Object IO.StreamReader($e.GetResponseStream())
            throw "GitHub $Method $Url failed: $([int]$e.StatusCode) $($r.ReadToEnd())"
        }
        throw
    }
    $r = New-Object IO.StreamReader($resp.GetResponseStream())
    $text = $r.ReadToEnd()
    $r.Dispose(); $resp.Dispose()
    if ($text) { return $text | ConvertFrom-Json }
    return $null
}

# 1) create (or reuse) the release
$payload = @{ tag_name = $tag; target_commitish = 'master'; name = $Name; body = $body; draft = [bool]$Draft }
$json = $payload | ConvertTo-Json -Depth 4 -Compress
$rel = $null
try {
    $rel = Invoke-GH 'POST' "https://api.github.com/repos/$Repo/releases" ([Text.Encoding]::UTF8.GetBytes($json)) 'application/json; charset=utf-8'
    "created release $($rel.tag_name) (id $($rel.id))"
} catch {
    if ($_.Exception.Message -notmatch 'already_exists') { throw }
    $rel = Invoke-GH 'GET' "https://api.github.com/repos/$Repo/releases/tags/$tag" $null $null
    "release $tag already exists (id $($rel.id)) - updating body"
    $rel = Invoke-GH 'PATCH' "https://api.github.com/repos/$Repo/releases/$($rel.id)" ([Text.Encoding]::UTF8.GetBytes($json)) 'application/json; charset=utf-8'
}

# 2) upload every zip in AssetsDir (replace an asset that already exists)
$existing = @{}
if ($rel.assets) { foreach ($a in $rel.assets) { $existing[$a.name] = $a.id } }
foreach ($f in (Get-ChildItem $AssetsDir -Filter '*.zip' | Sort-Object Name)) {
    if ($existing.ContainsKey($f.Name)) {
        Invoke-GH 'DELETE' "https://api.github.com/repos/$Repo/releases/assets/$($existing[$f.Name])" $null $null | Out-Null
        "  replaced existing $($f.Name)"
    }
    $url = "https://uploads.github.com/repos/$Repo/releases/$($rel.id)/assets?name=$($f.Name)"
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $up = Invoke-GH 'POST' $url $bytes 'application/zip'
    "  uploaded $($up.name) ($([math]::Round($up.size / 1MB, 2)) MB)"
}
"release url: $($rel.html_url)"
