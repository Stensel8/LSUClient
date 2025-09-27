function Get-PackagePathInfo {
    <#
        .DESCRIPTION
        Tests for the validity, existence and type of a location/path.
        Returns whether the path locator is valid, whether it points to a HTTP(S) or
        filesystem resource and can optionally test whether the resource is accessible.

        .PARAMETER Path
        The absolute or relative path to get.

        .PARAMETER BasePath
        If the Path is directory-relative, this BasePath will be used to try to resolve the absolute location of the Path.

        .PARAMETER ForceBasePathIfRelative
        If the Path is relative in any way (not fully qualified), always interpret it as relative to BasePath only even when that's technically wrong.

        .PARAMETER TestURLReachable
        In case the input Path is a HTTP(S) URL test connectivity with a HEAD request.
    #>
    [CmdletBinding()]
    Param (
        [Parameter( Mandatory = $true )]
        [string]$Path,
        [string]$BasePath,
        [switch]$ForceBasePathIfRelative,
        [switch]$TestURLReachable
    )

    $PathInfo = [PSCustomObject]@{
        'Valid'            = $false
        'Reachable'        = $false
        'Type'             = 'Unknown'
        'AbsoluteLocation' = ''
        'ErrorMessage'     = ''
    }

    Write-Debug "Resolving file path '$Path', possibly from '$BasePath'"

    # Testing for http URL
    [System.Uri]$Uri = $null
    [string]$UriToUse = $null

    # Test the path as an absolute and as a relative URL
    if ([System.Uri]::IsWellFormedUriString($Path, [System.UriKind]::Absolute)) {
        $UriToUse = $Path
    } elseif ($BasePath) {
        # When combining BasePath and Path to a URL, replace any backslashes in Path with forward-slashes as it is 99.9% likely
        # they are meant as path separators. This allows for repositories created with Update Retriever to be served as-is via HTTP.
        # Then escape the relative part of the URL as it can contain a filename that is not directly URL-compatible, see issue #39
        $JoinedUrl = $BasePath.TrimEnd('/', '\') + '/' + [System.Uri]::EscapeUriString($Path.TrimStart('/', '\').Replace('\', '/'))
        if ([System.Uri]::IsWellFormedUriString($JoinedUrl, [System.UriKind]::Absolute)) {
            $UriToUse = $JoinedUrl
        }
    }

    if ($UriToUse -and [System.Uri]::TryCreate($UriToUse, [System.UriKind]::Absolute, [ref]$Uri)) {
        if ($Uri.Scheme -in 'http', 'https') {
            $PathInfo.Type = 'HTTP'
            $PathInfo.AbsoluteLocation = $UriToUse
            $PathInfo.Valid = $true

            if ($TestURLReachable) {
                $Request = [System.Net.HttpWebRequest]::CreateHttp($UriToUse)
                $Request.Method = 'HEAD'
                $Request.Timeout = 8000
                $Request.KeepAlive = $false
                $Request.AllowAutoRedirect = $true

                if ((Test-Path -LiteralPath "Variable:\Proxy") -and $Proxy) {
                    $webProxy = [System.Net.WebProxy]::new($Proxy)
                    $webProxy.BypassProxyOnLocal = $false
                    if ((Test-Path -LiteralPath "Variable:\ProxyCredential") -and $ProxyCredential) {
                        $webProxy.Credentials = $ProxyCredential.GetNetworkCredential()
                    } elseif ((Test-Path -LiteralPath "Variable:\ProxyUseDefaultCredentials") -and $ProxyUseDefaultCredentials) {
                        # If both ProxyCredential and ProxyUseDefaultCredentials are passed,
                        # UseDefaultCredentials will overwrite the supplied credentials.
                        # This behaviour, comment and code are replicated from Invoke-WebRequest
                        $webproxy.UseDefaultCredentials = $true
                    }
                    $Request.Proxy = $webProxy
                }

                try {
                    $response = $Request.GetResponse()
                    if ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -le 299) {
                        $PathInfo.Reachable = $true
                    }
                    $response.Dispose()
                }
                # Catching the (most common) WebException separately just makes the error message nicer as
                # it won't have the extra 'Exception calling "GetResponse" with "0" argument(s)' text in it.
                catch [System.Net.WebException] {
                    $PathInfo.ErrorMessage = "URL ${UriToUse} is not reachable: $($_.FullyQualifiedErrorId): $_"
                }
                catch {
                    $PathInfo.ErrorMessage = "URL ${UriToUse} is not reachable: $($_.FullyQualifiedErrorId): $_"
                }
            }

            return $PathInfo
        }
    }

    Write-Debug "GPPI: Test for filesystem path" # Debug info for issue 122

    # Test for filesystem path
    # Test for relative ("partially qualified") filesystem path. Logic is based on .NET IsPathFullyQualified
    # method which is unfortunately not available in PowerShell 5.1:
    # https://learn.microsoft.com/en-us/dotnet/api/system.io.path.ispathfullyqualified
    # https://github.com/dotnet/runtime/blob/80fb00f580f5b2353ff3a8aa78c5b5fd3f275a34/src/libraries/Common/src/System/IO/PathInternal.Windows.cs#L250
    [bool]$PathIsRelative = if ($Path.Length -lt 2) {
        $true
    } elseif ($Path[0] -in '\', '/') {
        $Path[1] -notin '\', '/', '?'
    } else {
        -not ($Path.Length -ge 3 -and $Path[1] -eq [System.IO.Path]::VolumeSeparatorChar -and $Path[2] -in '\', '/' -and $Path[0] -match '[a-z]')
    }

    Write-Debug "GPPI: PathIsRelative: $PathIsRelative" # Debug info for issue 122

    $PathInfo.ErrorMessage = "'$Path' is not a supported URL and does not exist as a filesystem path"

    if (-not $PathIsRelative -or -not $ForceBasePathIfRelative) {
        Write-Debug "GPPI: Performing as-is Test-Path" # Debug info for issue 122
        # If either Path is not relative (is absolute) OR it is relative but we do not enforce
        # relativity to only the BasePath, test the path as-is to let PowerShell interpret it.
        # This will resolve absolute, current-drive-relative and current-directory-relative paths.
        #
        # We cannot Test-Path a provider-qualified path like "Microsoft.PowerShell.Core\FileSystem::${Path}"
        # because that syntax makes PowerShell resolve current-drive-relative paths wrong, see:
        # https://github.com/PowerShell/PowerShell/issues/26092
        if (Test-Path -LiteralPath $Path) {
            $GI = Get-Item -LiteralPath $Path
            if ($GI.PSProvider.ToString() -eq 'Microsoft.PowerShell.Core\FileSystem') {
                $PathInfo.Valid = $true
                $PathInfo.Reachable = $true
                $PathInfo.Type = 'FILE'
                $PathInfo.AbsoluteLocation = $GI.FullName
                $PathInfo.ErrorMessage = ''

                return $PathInfo
            }
        }
    }

    # If either:
    # - We skipped the previous Test-Path (because Path is relative AND we enforce relativity to BasePath only)
    # OR
    # - We did not skip the previous Test-Path (because Path is absolute OR it is relative but we do not enforce relativity to BasePath only) but it did not succeed
    # then test the result of a join of BasePath and Path.
    if ($BasePath) {
        $JoinedPath = Join-Path -Path $BasePath -ChildPath $Path -ErrorAction Ignore
        Write-Debug "GPPI: Testing JoinedPath '$JoinedPath'" # Debug info for issue 122
        if ($JoinedPath -and (Test-Path -LiteralPath $JoinedPath)) {
            $GI = Get-Item -LiteralPath $JoinedPath
            if ($GI.PSProvider.ToString() -eq 'Microsoft.PowerShell.Core\FileSystem') {
                $PathInfo.Valid = $true
                $PathInfo.Reachable = $true
                $PathInfo.Type = 'FILE'
                $PathInfo.AbsoluteLocation = $GI.FullName
                $PathInfo.ErrorMessage = ''
            }
        }
    } else {
        Write-Debug "GPPI: No BasePath, skipping JoinedPath test" # Debug info for issue 122
    }

    return $PathInfo
}
