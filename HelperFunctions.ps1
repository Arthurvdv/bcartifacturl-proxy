﻿$useTimeOutWebClient = $false
if ($PSVersionTable.PSVersion -lt "6.0.0" -or $useTimeOutWebClient) {
    $timeoutWebClientCode = @"
	using System.Net;
 
	public class TimeoutWebClient : WebClient
	{
        int theTimeout;

        public TimeoutWebClient(int timeout)
        {
            theTimeout = timeout;
        }

		protected override WebRequest GetWebRequest(System.Uri address)
		{
			WebRequest request = base.GetWebRequest(address);
			if (request != null)
			{
				request.Timeout = theTimeout;
			}
			return request;
		}
 	}
"@;
if (-not ([System.Management.Automation.PSTypeName]"TimeoutWebClient").Type) {
    Add-Type -TypeDefinition $timeoutWebClientCode -Language CSharp -WarningAction SilentlyContinue | Out-Null
    $useTimeOutWebClient = $true
}
}

<#$sslCallbackCode = @"
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;

public static class SslVerification
{
	public static bool DisabledServerCertificateValidationCallback(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors sslPolicyErrors) { return true; }
	public static void Disable() { System.Net.ServicePointManager.ServerCertificateValidationCallback = DisabledServerCertificateValidationCallback; }
	public static void Enable()  { System.Net.ServicePointManager.ServerCertificateValidationCallback = null; }
    public static void DisableSsl(System.Net.Http.HttpClientHandler handler) { handler.ServerCertificateCustomValidationCallback = DisabledServerCertificateValidationCallback; }
}
"@
if (-not ([System.Management.Automation.PSTypeName]"SslVerification").Type) {
    if ($isPsCore) {
        Add-Type -TypeDefinition $sslCallbackCode -Language CSharp -WarningAction SilentlyContinue | Out-Null
    }
    else {
        Add-Type -TypeDefinition $sslCallbackCode -Language CSharp -ReferencedAssemblies @('System.Net.Http') -WarningAction SilentlyContinue | Out-Null
    }
}#>

function Get-DefaultCredential {
    Param(
        [string]$Message,
        [string]$DefaultUserName,
        [switch]$doNotAskForCredential
    )

    if (Test-Path "$($bcContainerHelperConfig.hostHelperFolder)\settings.ps1") {
        . "$($bcContainerHelperConfig.hostHelperFolder)\settings.ps1"
        if (Test-Path "$($bcContainerHelperConfig.hostHelperFolder)\aes.key") {
            $key = Get-Content -Path "$($bcContainerHelperConfig.hostHelperFolder)\aes.key"
            New-Object System.Management.Automation.PSCredential ($DefaultUserName, (ConvertTo-SecureString -String $adminPassword -Key $key))
        }
        else {
            New-Object System.Management.Automation.PSCredential ($DefaultUserName, (ConvertTo-SecureString -String $adminPassword))
        }
    }
    else {
        if (!$doNotAskForCredential) {
            Get-Credential -username $DefaultUserName -Message $Message
        }
    }
}

function Get-DefaultSqlCredential {
    Param(
        [Parameter(Mandatory = $true)]
        [string]$containerName,
        [System.Management.Automation.PSCredential]$sqlCredential = $null,
        [switch]$doNotAskForCredential
    )

    if ($sqlCredential -eq $null) {
        $containerAuth = Get-NavContainerAuth -containerName $containerName
        if ($containerAuth -ne "Windows") {
            $sqlCredential = Get-DefaultCredential -DefaultUserName "" -Message "Please enter the SQL Server System Admin credentials for container $containerName" -doNotAskForCredential:$doNotAskForCredential
        }
    }
    $sqlCredential
}

function CmdDo {
    Param(
        [string] $command = "",
        [string] $arguments = "",
        [switch] $silent,
        [switch] $returnValue,
        [string] $inputStr = "",
        [string] $messageIfCmdNotFound = ""
    )

    $oldNoColor = "$env:NO_COLOR"
    $env:NO_COLOR = "Y"
    $oldEncoding = [Console]::OutputEncoding
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
    try {
        $pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName = $command
        $pinfo.RedirectStandardError = $true
        $pinfo.RedirectStandardOutput = $true
        if ($inputStr) {
            $pinfo.RedirectStandardInput = $true
        }
        $pinfo.WorkingDirectory = Get-Location
        $pinfo.UseShellExecute = $false
        $pinfo.Arguments = $arguments
        $pinfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Minimized

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $pinfo
        $p.Start() | Out-Null
        if ($inputStr) {
            $p.StandardInput.WriteLine($inputStr)
            $p.StandardInput.Close()
        }
        $outtask = $p.StandardOutput.ReadToEndAsync()
        $errtask = $p.StandardError.ReadToEndAsync()
        $p.WaitForExit();

        $message = $outtask.Result
        $err = $errtask.Result

        if ("$err" -ne "") {
            $message += "$err"
        }
        
        $message = $message.Trim()

        if ($p.ExitCode -eq 0) {
            if (!$silent) {
                Write-Host $message
            }
            if ($returnValue) {
                $message.Replace("`r", "").Split("`n")
            }
        }
        else {
            $message += "`n`nExitCode: " + $p.ExitCode + "`nCommandline: $command $arguments"
            throw $message
        }
    }
    catch [System.ComponentModel.Win32Exception] {
        if ($_.Exception.NativeErrorCode -eq 2) {
            if ($messageIfCmdNotFound) {
                throw $messageIfCmdNotFound
            }
            else {
                throw "Command $command not found, you might need to install that command."
            }
        }
        else {
            throw
        }
    }
    finally {
        try { [Console]::OutputEncoding = $oldEncoding } catch {}
        $env:NO_COLOR = $oldNoColor
    }
}

function DockerDo {
    Param(
        [Parameter(Mandatory = $true)]
        [string]$imageName,
        [ValidateSet('run', 'start', 'pull', 'restart', 'stop', 'rmi','build')]
        [string]$command = "run",
        [switch]$accept_eula,
        [switch]$accept_outdated,
        [switch]$detach,
        [switch]$silent,
        [string[]]$parameters = @()
    )

    if ($accept_eula) {
        $parameters += "--env accept_eula=Y"
    }
    if ($accept_outdated) {
        $parameters += "--env accept_outdated=Y"
    }
    if ($detach) {
        $parameters += "--detach"
    }

    $result = $true
    $arguments = ("$command " + [string]::Join(" ", $parameters) + " $imageName")
    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = "docker.exe"
    $pinfo.RedirectStandardError = $true
    $pinfo.RedirectStandardOutput = $true
    $pinfo.UseShellExecute = $false
    $pinfo.Arguments = $arguments
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $pinfo
    $p.Start() | Out-Null


    $outtask = $null
    $errtask = $p.StandardError.ReadToEndAsync()
    $out = ""
    $err = ""
    
    do {
        if ($outtask -eq $null) {
            $outtask = $p.StandardOutput.ReadLineAsync()
        }
        $outtask.Wait(100) | Out-Null
        if ($outtask.IsCompleted) {
            $outStr = $outtask.Result
            if ($outStr -eq $null) {
                break
            }
            if (!$silent) {
                Write-Host $outStr
            }
            $out += $outStr
            $outtask = $null
            if ($outStr.StartsWith("Please login")) {
                $registry = $imageName.Split("/")[0]
                if ($registry -eq "bcinsider.azurecr.io" -or $registry -eq "bcprivate.azurecr.io") {
                    throw "You need to login to $registry prior to pulling images. Get credentials through the ReadyToGo program on Microsoft Collaborate."
                }
                else {
                    throw "You need to login to $registry prior to pulling images."
                }
            }
        }
        elseif ($outtask.IsCanceled) {
            break
        }
        elseif ($outtask.IsFaulted) {
            break
        }
    } while (!($p.HasExited))
    
    $err = $errtask.Result
    $p.WaitForExit();

    if ($p.ExitCode -ne 0) {
        $result = $false
        if (!$silent) {
            $out = $out.Trim()
            $err = $err.Trim()
            if ($command -eq "run" -and "$out" -ne "") {
                Docker rm $out -f
            }
            $errorMessage = ""
            if ("$err" -ne "") {
                $errorMessage += "$err`r`n"
                if ($err.Contains("authentication required")) {
                    $registry = $imageName.Split("/")[0]
                    if ($registry -eq "bcinsider.azurecr.io" -or $registry -eq "bcprivate.azurecr.io") {
                        $errorMessage += "You need to login to $registry prior to pulling images. Get credentials through the ReadyToGo program on Microsoft Collaborate.`r`n"
                    }
                    else {
                        $errorMessage += "You need to login to $registry prior to pulling images.`r`n"
                    }
                }
            }
            $errorMessage += "ExitCode: " + $p.ExitCode + "`r`nCommandline: docker $arguments"
            Write-Error -Message $errorMessage
        }
    }
    $result
}

function Get-NavContainerAuth {
    Param
    (
        [string]$containerName
    )

    Invoke-ScriptInNavContainer -containerName $containerName -ScriptBlock { 
        $customConfigFile = Join-Path (Get-Item "C:\Program Files\Microsoft Dynamics NAV\*\Service").FullName "CustomSettings.config"
        [xml]$customConfig = [System.IO.File]::ReadAllText($customConfigFile)
        $customConfig.SelectSingleNode("//appSettings/add[@key='ClientServicesCredentialType']").Value
    }
}

function Check-BcContainerName {
    Param
    (
        [string]$containerName = ""
    )

    if ($containerName -eq "") {
        throw "Container name cannot be empty"
    }

    if ($containerName.Length -gt 15) {
        Write-Host "WARNING: Container name should not exceed 15 characters"
    }

    $first = $containerName.ToLowerInvariant()[0]
    if ($first -lt "a" -or $first -gt "z") {
        throw "Container name should start with a letter (a-z)"
    }

    $containerName.ToLowerInvariant().ToCharArray() | ForEach-Object {
        if (($_ -lt "a" -or $_ -gt "z") -and ($_ -lt "0" -or $_ -gt "9") -and ($_ -ne "-")) {
            throw "Container name contains invalid characters. Allowed characters are letters (a-z), numbers (0-9) and dashes (-)"
        }
    }
}

function AssumeNavContainer {
    Param
    (
        [string]$containerOrImageName = "",
        [string]$functionName = ""
    )

    $inspect = docker inspect $containerOrImageName | ConvertFrom-Json
    if ($inspect.Config.Labels.psobject.Properties.Match('maintainer').Count -eq 0 -or $inspect.Config.Labels.maintainer -ne "Dynamics SMB") {
        throw "Container $containerOrImageName is not a Business Central container"
    }
    [System.Version]$version = $inspect.Config.Labels.version

    if ("$functionName" -eq "") {
        $functionName = (Get-Variable MyInvocation -Scope 1).Value.MyCommand.Name
    }
    if ($version.Major -ge 15) {
        throw "Container $containerOrImageName does not support the function $functionName"
    }
}

function TestSasToken {
    Param
    (
        [string] $url
    )

    $sasToken = "?$("$($url)?".Split('?')[1])"
    if ($sasToken -eq '?') {
        # No SAS token in URL
        return
    }

    try {
        $se = $sasToken.Split('?')[1].Split('&') | Where-Object { $_.StartsWith('se=') } | ForEach-Object { [Uri]::UnescapeDataString($_.Substring(3)) }
        $st = $sasToken.Split('?')[1].Split('&') | Where-Object { $_.StartsWith('st=') } | ForEach-Object { [Uri]::UnescapeDataString($_.Substring(3)) }
        $sv = $sasToken.Split('?')[1].Split('&') | Where-Object { $_.StartsWith('sv=') } | ForEach-Object { [Uri]::UnescapeDataString($_.Substring(3)) }
        $sig = $sasToken.Split('?')[1].Split('&') | Where-Object { $_.StartsWith('sig=') } | ForEach-Object { [Uri]::UnescapeDataString($_.Substring(4)) }
        if ($sv -ne '2021-10-04' -or $sig -eq '' -or $se -eq '' -or $st -eq '') {
            throw "Wrong format"
        }
        if ([DateTime]::Now -lt [DateTime]$st) {
            Write-Host "::ERROR::The sas token provided isn't valid before $(([DateTime]$st).ToString())"
        }
        if ([DateTime]::Now -gt [DateTime]$se) {
            Write-Host "::ERROR::The sas token provided expired on $(([DateTime]$se).ToString())"
        }
        elseif ([DateTime]::Now.AddDays(14) -gt [DateTime]$se) {
            Write-Host "::WARNING::The sas token provided will expire on $(([DateTime]$se).ToString())"
        }
    }
    catch {
        $message = $_.ToString()
        throw "The sas token provided is not valid, error message was: $message"
    }
}

function Expand-7zipArchive {
    Param (
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [string] $DestinationPath,
        [switch] $use7zipIfAvailable = $bcContainerHelperConfig.use7zipIfAvailable,
        [switch] $silent
    )

    $7zipPath = "$env:ProgramFiles\7-Zip\7z.exe"
    $use7zip = $false
    if ($use7zipIfAvailable -and (Test-Path -Path $7zipPath -PathType Leaf)) {
        try {
            $use7zip = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($7zipPath).FileMajorPart -ge 19
        }
        catch {
            $use7zip = $false
        }
    }

    if ($use7zip) {
        if (!$silent) { Write-Host "using 7zip" }
        Set-Alias -Name 7z -Value $7zipPath
        $command = '7z x "{0}" -o"{1}" -aoa -r' -f $Path, $DestinationPath
        $global:LASTEXITCODE = 0
        Invoke-Expression -Command $command | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Error $LASTEXITCODE extracting $path"
        }
    }
    else {
        if (!$silent) { Write-Host "using Expand-Archive" }
        if ([System.IO.Path]::GetExtension($path) -eq '.zip') {
            Expand-Archive -Path $Path -DestinationPath "$DestinationPath" -Force
        }
        else {
            $tempZip = Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid().ToString()).zip"
            Copy-Item -Path $Path -Destination $tempZip -Force
            try {
                Expand-Archive -Path $tempZip -DestinationPath "$DestinationPath" -Force
            }
            finally {
                Remove-Item -Path $tempZip -Force
            }
        }
    }
}

function GetTestToolkitApps {
    Param(
        [string] $containerName,
        [switch] $includeTestLibrariesOnly,
        [switch] $includeTestFrameworkOnly,
        [switch] $includeTestRunnerOnly,
        [switch] $includePerformanceToolkit
    )

    Invoke-ScriptInBCContainer -containerName $containerName -scriptblock { Param($includeTestLibrariesOnly, $includeTestFrameworkOnly, $includeTestRunnerOnly, $includePerformanceToolkit)
    
        $version = [Version](Get-Item "C:\Program Files\Microsoft Dynamics NAV\*\Service\Microsoft.Dynamics.Nav.Server.exe").VersionInfo.FileVersion

        # Add Test Framework
        $apps = @()
        if (($version -ge [Version]"19.0.0.0") -and (Test-Path 'C:\Applications\TestFramework\TestLibraries\permissions mock')) {
            $apps += @(get-childitem -Path "C:\Applications\TestFramework\TestLibraries\permissions mock\*.*" -recurse -filter "*.app")
        }
        $apps += @(get-childitem -Path "C:\Applications\TestFramework\TestRunner\*.*" -recurse -filter "*.app")

        if (!$includeTestRunnerOnly) {
            $apps += @(get-childitem -Path "C:\Applications\TestFramework\TestLibraries\*.*" -recurse -filter "*.app")

            if (!$includeTestFrameworkOnly) {
                # Add Test Libraries
                $apps += "Microsoft_System Application Test Library.app", "Microsoft_Business Foundation Test Libraries.app", "Microsoft_Tests-TestLibraries.app" | ForEach-Object {
                    @(get-childitem -Path "C:\Applications\*.*" -recurse -filter $_)
                }
    
                if (!$includeTestLibrariesOnly) {
                    # Add Tests
                    if ($version -ge [Version]"18.0.0.0") {
                        $apps += "Microsoft_System Application Test.app", "Microsoft_Business Foundation Tests.app" | ForEach-Object {
                            @(get-childitem -Path "C:\Applications\*.*" -recurse -filter $_)
                        }
                    }
                    $apps += @(get-childitem -Path "C:\Applications\*.*" -recurse -filter "Microsoft_Tests-*.app") | Where-Object { $_ -notlike "*\Microsoft_Tests-TestLibraries.app" -and ($version.Major -ge 17 -or ($_ -notlike "*\Microsoft_Tests-Marketing.app")) -and $_ -notlike "*\Microsoft_Tests-SINGLESERVER.app" }
                }
            }
        }

        if ($includePerformanceToolkit) {
            $apps += @(get-childitem -Path "C:\Applications\TestFramework\PerformanceToolkit\*.*" -recurse -filter "*Toolkit.app")
            if (!$includeTestFrameworkOnly) {
                $apps += @(get-childitem -Path "C:\Applications\TestFramework\PerformanceToolkit\*.*" -recurse -filter "*.app" -exclude "*Toolkit.app")
            }
        }

        $apps | ForEach-Object {
            $appFile = Get-ChildItem -path "c:\applications.*\*.*" -recurse -filter ($_.Name).Replace(".app", "_*.app")
            if (!($appFile)) {
                $appFile = $_
            }
            $appFile.FullName
        }
    } -argumentList $includeTestLibrariesOnly, $includeTestFrameworkOnly, $includeTestRunnerOnly, $includePerformanceToolkit
}

function GetExtendedErrorMessage {
    Param(
        $errorRecord
    )

    $exception = $errorRecord.Exception
    $message = $exception.Message

    try {
        if ($errorRecord.ErrorDetails) {
            $errorDetails = $errorRecord.ErrorDetails | ConvertFrom-Json
            $message += " $($errorDetails.error)`r`n$($errorDetails.error_description)"
        }
    }
    catch {}
    try {
        if ($exception -is [System.Management.Automation.MethodInvocationException]) {
            $exception = $exception.InnerException
        }
        if ($exception -is [System.Net.Http.HttpRequestException]) {
            $message += "`r`n$($exception.Message)"
            if ($exception.InnerException) {
                if ($exception.InnerException -and $exception.InnerException.Message) {
                    $message += "`r`n$($exception.InnerException.Message)"
                }
            }

        }
        else {
            $webException = [System.Net.WebException]$exception
            $webResponse = $webException.Response
            try {
                if ($webResponse.StatusDescription) {
                    $message += "`r`n$($webResponse.StatusDescription)"
                }
            }
            catch {}
            $reqstream = $webResponse.GetResponseStream()
            $sr = new-object System.IO.StreamReader $reqstream
            $result = $sr.ReadToEnd()
        }
        try {
            $json = $result | ConvertFrom-Json
            $message += "`r`n$($json.Message)"
        }
        catch {
            $message += "`r`n$result"
        }
        try {
            $correlationX = $webResponse.GetResponseHeader('ms-correlation-x')
            if ($correlationX) {
                $message += " (ms-correlation-x = $correlationX)"
            }
        }
        catch {}
    }
    catch {}
    $message
}

function CopyAppFilesToFolder {
    Param(
        $appFiles,
        [string] $folder
    )

    if ($appFiles -is [String]) {
        if (!(Test-Path $appFiles)) {
            $appFiles = @($appFiles.Split(',').Trim() | Where-Object { $_ })
        }
    }
    if (!(Test-Path $folder)) {
        New-Item -Path $folder -ItemType Directory | Out-Null
    }
    $appFiles | Where-Object { $_ } | ForEach-Object {
        $appFile = $_
        if ($appFile -like "http://*" -or $appFile -like "https://*") {
            $appUrl = $appFile
            $appFileFolder = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
            $appFile = Join-Path $appFileFolder ([Uri]::UnescapeDataString([System.IO.Path]::GetFileName($appUrl.Split('?')[0])))
            Download-File -sourceUrl $appUrl -destinationFile $appFile
            CopyAppFilesToFolder -appFile $appFile -folder $folder
            if (Test-Path $appFileFolder) {
                Remove-Item -Path $appFileFolder -Force -Recurse
            }
        }
        elseif (Test-Path $appFile -PathType Container) {
            get-childitem $appFile -Filter '*.app' -Recurse | ForEach-Object {
                $destFile = Join-Path $folder $_.Name
                if (Test-Path $destFile) {
                    Write-Host -ForegroundColor Yellow "::WARNING::$([System.IO.Path]::GetFileName($destFile)) already exists, it looks like you have multiple app files with the same name. App filenames must be unique."
                }
                Copy-Item -Path $_.FullName -Destination $destFile -Force
                $destFile
            }
        }
        elseif (Test-Path $appFile -PathType Leaf) {
            Get-ChildItem $appFile | ForEach-Object {
                $appFile = $_.FullName
                if ([string]::new([char[]](Get-Content $appFile @byteEncodingParam -TotalCount 2)) -eq "PK") {
                    $tmpFolder = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
                    $copied = $false
                    try {
                        if ($appFile -notlike "*.zip") {
                            $orgAppFile = $appFile
                            $appFile = Join-Path ([System.IO.Path]::GetTempPath()) "$([System.IO.Path]::GetFileName($orgAppFile)).zip"
                            Copy-Item $orgAppFile $appFile
                            $copied = $true
                        }
                        Expand-Archive $appfile -DestinationPath $tmpFolder -Force
                        Get-ChildItem -Path $tmpFolder -Recurse | Where-Object { $_.Name -like "*.app" -or $_.Name -like "*.zip" } | ForEach-Object {
                            CopyAppFilesToFolder -appFile $_.FullName -folder $folder
                        }
                    }
                    finally {
                        Remove-Item -Path $tmpFolder -Recurse -Force
                        if ($copied) { Remove-Item -Path $appFile -Force }
                    }
                }
                else {
                    $destFile = Join-Path $folder "$([System.IO.Path]::GetFileNameWithoutExtension($appFile)).app"
                    if (Test-Path $destFile) {
                        Write-Host -ForegroundColor Yellow "::WARNING::$([System.IO.Path]::GetFileName($destFile)) already exists, it looks like you have multiple app files with the same name. App filenames must be unique."
                    }
                    Copy-Item -Path $appFile -Destination $destFile -Force
                    $destFile
                }
            }
        }
        else {
            Write-Host -ForegroundColor Red "::WARNING::File not found: $appFile"
        }
    }
}

function getCountryCode {
    Param(
        [string] $countryCode
    )

    $countryCodes = @{
        "Afghanistan"                                  = "AF"
        "Åland Islands"                                = "AX"
        "Albania"                                      = "AL"
        "Algeria"                                      = "DZ"
        "American Samoa"                               = "AS"
        "AndorrA"                                      = "AD"
        "Angola"                                       = "AO"
        "Anguilla"                                     = "AI"
        "Antarctica"                                   = "AQ"
        "Antigua and Barbuda"                          = "AG"
        "Argentina"                                    = "AR"
        "Armenia"                                      = "AM"
        "Aruba"                                        = "AW"
        "Australia"                                    = "AU"
        "Austria"                                      = "AT"
        "Azerbaijan"                                   = "AZ"
        "Bahamas"                                      = "BS"
        "Bahrain"                                      = "BH"
        "Bangladesh"                                   = "BD"
        "Barbados"                                     = "BB"
        "Belarus"                                      = "BY"
        "Belgium"                                      = "BE"
        "Belize"                                       = "BZ"
        "Benin"                                        = "BJ"
        "Bermuda"                                      = "BM"
        "Bhutan"                                       = "BT"
        "Bolivia"                                      = "BO"
        "Bosnia and Herzegovina"                       = "BA"
        "Botswana"                                     = "BW"
        "Bouvet Island"                                = "BV"
        "Brazil"                                       = "BR"
        "British Indian Ocean Territory"               = "IO"
        "Brunei Darussalam"                            = "BN"
        "Bulgaria"                                     = "BG"
        "Burkina Faso"                                 = "BF"
        "Burundi"                                      = "BI"
        "Cambodia"                                     = "KH"
        "Cameroon"                                     = "CM"
        "Canada"                                       = "CA"
        "Cape Verde"                                   = "CV"
        "Cayman Islands"                               = "KY"
        "Central African Republic"                     = "CF"
        "Chad"                                         = "TD"
        "Chile"                                        = "CL"
        "China"                                        = "CN"
        "Christmas Island"                             = "CX"
        "Cocos (Keeling) Islands"                      = "CC"
        "Colombia"                                     = "CO"
        "Comoros"                                      = "KM"
        "Congo"                                        = "CG"
        "Congo, The Democratic Republic of the"        = "CD"
        "Cook Islands"                                 = "CK"
        "Costa Rica"                                   = "CR"
        "Cote D'Ivoire"                                = "CI"
        "Croatia"                                      = "HR"
        "Cuba"                                         = "CU"
        "Cyprus"                                       = "CY"
        "Czech Republic"                               = "CZ"
        "Denmark"                                      = "DK"
        "Djibouti"                                     = "DJ"
        "Dominica"                                     = "DM"
        "Dominican Republic"                           = "DO"
        "Ecuador"                                      = "EC"
        "Egypt"                                        = "EG"
        "El Salvador"                                  = "SV"
        "Equatorial Guinea"                            = "GQ"
        "Eritrea"                                      = "ER"
        "Estonia"                                      = "EE"
        "Ethiopia"                                     = "ET"
        "Falkland Islands (Malvinas)"                  = "FK"
        "Faroe Islands"                                = "FO"
        "Fiji"                                         = "FJ"
        "Finland"                                      = "FI"
        "France"                                       = "FR"
        "French Guiana"                                = "GF"
        "French Polynesia"                             = "PF"
        "French Southern Territories"                  = "TF"
        "Gabon"                                        = "GA"
        "Gambia"                                       = "GM"
        "Georgia"                                      = "GE"
        "Germany"                                      = "DE"
        "Ghana"                                        = "GH"
        "Gibraltar"                                    = "GI"
        "Greece"                                       = "GR"
        "Greenland"                                    = "GL"
        "Grenada"                                      = "GD"
        "Guadeloupe"                                   = "GP"
        "Guam"                                         = "GU"
        "Guatemala"                                    = "GT"
        "Guernsey"                                     = "GG"
        "Guinea"                                       = "GN"
        "Guinea-Bissau"                                = "GW"
        "Guyana"                                       = "GY"
        "Haiti"                                        = "HT"
        "Heard Island and Mcdonald Islands"            = "HM"
        "Holy See (Vatican City State)"                = "VA"
        "Honduras"                                     = "HN"
        "Hong Kong"                                    = "HK"
        "Hungary"                                      = "HU"
        "Iceland"                                      = "IS"
        "India"                                        = "IN"
        "Indonesia"                                    = "ID"
        "Iran, Islamic Republic Of"                    = "IR"
        "Iraq"                                         = "IQ"
        "Ireland"                                      = "IE"
        "Isle of Man"                                  = "IM"
        "Israel"                                       = "IL"
        "Italy"                                        = "IT"
        "Jamaica"                                      = "JM"
        "Japan"                                        = "JP"
        "Jersey"                                       = "JE"
        "Jordan"                                       = "JO"
        "Kazakhstan"                                   = "KZ"
        "Kenya"                                        = "KE"
        "Kiribati"                                     = "KI"
        "Korea, Democratic People's Republic of"       = "KP"
        "Korea, Republic of"                           = "KR"
        "Kuwait"                                       = "KW"
        "Kyrgyzstan"                                   = "KG"
        "Lao People's Democratic Republic"             = "LA"
        "Latvia"                                       = "LV"
        "Lebanon"                                      = "LB"
        "Lesotho"                                      = "LS"
        "Liberia"                                      = "LR"
        "Libyan Arab Jamahiriya"                       = "LY"
        "Liechtenstein"                                = "LI"
        "Lithuania"                                    = "LT"
        "Luxembourg"                                   = "LU"
        "Macao"                                        = "MO"
        "Macedonia, The Former Yugoslav Republic of"   = "MK"
        "Madagascar"                                   = "MG"
        "Malawi"                                       = "MW"
        "Malaysia"                                     = "MY"
        "Maldives"                                     = "MV"
        "Mali"                                         = "ML"
        "Malta"                                        = "MT"
        "Marshall Islands"                             = "MH"
        "Martinique"                                   = "MQ"
        "Mauritania"                                   = "MR"
        "Mauritius"                                    = "MU"
        "Mayotte"                                      = "YT"
        "Mexico"                                       = "MX"
        "Micronesia, Federated States of"              = "FM"
        "Moldova, Republic of"                         = "MD"
        "Monaco"                                       = "MC"
        "Mongolia"                                     = "MN"
        "Montserrat"                                   = "MS"
        "Morocco"                                      = "MA"
        "Mozambique"                                   = "MZ"
        "Myanmar"                                      = "MM"
        "Namibia"                                      = "NA"
        "Nauru"                                        = "NR"
        "Nepal"                                        = "NP"
        "Netherlands"                                  = "NL"
        "Netherlands Antilles"                         = "AN"
        "New Caledonia"                                = "NC"
        "New Zealand"                                  = "NZ"
        "Nicaragua"                                    = "NI"
        "Niger"                                        = "NE"
        "Nigeria"                                      = "NG"
        "Niue"                                         = "NU"
        "Norfolk Island"                               = "NF"
        "Northern Mariana Islands"                     = "MP"
        "Norway"                                       = "NO"
        "Oman"                                         = "OM"
        "Pakistan"                                     = "PK"
        "Palau"                                        = "PW"
        "Palestinian Territory, Occupied"              = "PS"
        "Panama"                                       = "PA"
        "Papua New Guinea"                             = "PG"
        "Paraguay"                                     = "PY"
        "Peru"                                         = "PE"
        "Philippines"                                  = "PH"
        "Pitcairn"                                     = "PN"
        "Poland"                                       = "PL"
        "Portugal"                                     = "PT"
        "Puerto Rico"                                  = "PR"
        "Qatar"                                        = "QA"
        "Reunion"                                      = "RE"
        "Romania"                                      = "RO"
        "Russian Federation"                           = "RU"
        "RWANDA"                                       = "RW"
        "Saint Helena"                                 = "SH"
        "Saint Kitts and Nevis"                        = "KN"
        "Saint Lucia"                                  = "LC"
        "Saint Pierre and Miquelon"                    = "PM"
        "Saint Vincent and the Grenadines"             = "VC"
        "Samoa"                                        = "WS"
        "San Marino"                                   = "SM"
        "Sao Tome and Principe"                        = "ST"
        "Saudi Arabia"                                 = "SA"
        "Senegal"                                      = "SN"
        "Serbia and Montenegro"                        = "CS"
        "Seychelles"                                   = "SC"
        "Sierra Leone"                                 = "SL"
        "Singapore"                                    = "SG"
        "Slovakia"                                     = "SK"
        "Slovenia"                                     = "SI"
        "Solomon Islands"                              = "SB"
        "Somalia"                                      = "SO"
        "South Africa"                                 = "ZA"
        "South Georgia and the South Sandwich Islands" = "GS"
        "Spain"                                        = "ES"
        "Sri Lanka"                                    = "LK"
        "Sudan"                                        = "SD"
        "Suriname"                                     = "SR"
        "Svalbard and Jan Mayen"                       = "SJ"
        "Swaziland"                                    = "SZ"
        "Sweden"                                       = "SE"
        "Switzerland"                                  = "CH"
        "Syrian Arab Republic"                         = "SY"
        "Taiwan, Province of China"                    = "TW"
        "Tajikistan"                                   = "TJ"
        "Tanzania, United Republic of"                 = "TZ"
        "Thailand"                                     = "TH"
        "Timor-Leste"                                  = "TL"
        "Togo"                                         = "TG"
        "Tokelau"                                      = "TK"
        "Tonga"                                        = "TO"
        "Trinidad and Tobago"                          = "TT"
        "Tunisia"                                      = "TN"
        "Turkey"                                       = "TR"
        "Turkmenistan"                                 = "TM"
        "Turks and Caicos Islands"                     = "TC"
        "Tuvalu"                                       = "TV"
        "Uganda"                                       = "UG"
        "Ukraine"                                      = "UA"
        "United Arab Emirates"                         = "AE"
        "United Kingdom"                               = "GB"
        "United States"                                = "US"
        "United States Minor Outlying Islands"         = "UM"
        "Uruguay"                                      = "UY"
        "Uzbekistan"                                   = "UZ"
        "Vanuatu"                                      = "VU"
        "Venezuela"                                    = "VE"
        "Viet Nam"                                     = "VN"
        "Virgin Islands, British"                      = "VG"
        "Virgin Islands, U.S."                         = "VI"
        "Wallis and Futuna"                            = "WF"
        "Western Sahara"                               = "EH"
        "Yemen"                                        = "YE"
        "Zambia"                                       = "ZM"
        "Zimbabwe"                                     = "ZW"
        "Hong Kong SAR"                                = "HK"
        "Serbia"                                       = "RS"
        "Korea"                                        = "KR"
        "Taiwan"                                       = "TW"
        "Vietnam"                                      = "VN"
    }

    $countryCode = $countryCode.Trim()
    if ($countryCodes.ContainsValue($countryCode.ToUpperInvariant())) {
        return $countryCode.ToLowerInvariant()
    }
    elseif ($countryCodes.ContainsKey($countryCode)) {
        return ($countryCodes[$countryCode]).ToLowerInvariant()
    }
    else {
        throw "Country code $countryCode is illegal"
    }
}

function Get-WWWRootPath {
    $inetstp = Get-Item "HKLM:\SOFTWARE\Microsoft\InetStp" -ErrorAction SilentlyContinue
    if ($inetstp) {
        [System.Environment]::ExpandEnvironmentVariables($inetstp.GetValue("PathWWWRoot"))
    }
    else {
        ""
    }
}

function Parse-JWTtoken([string]$token) {
    if ($token.Contains(".") -and $token.StartsWith("eyJ")) {
        $tokenPayload = $token.Split(".")[1].Replace('-', '+').Replace('_', '/')
        while ($tokenPayload.Length % 4) { $tokenPayload += "=" }
        return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($tokenPayload)) | ConvertFrom-Json
    }
    throw "Invalid token"
}

function Test-BcAuthContext {
    Param(
        $bcAuthContext
    )

    if (!(($bcAuthContext -is [Hashtable]) -and
          ($bcAuthContext.ContainsKey('ClientID')) -and
          ($bcAuthContext.ContainsKey('Credential')) -and
          ($bcAuthContext.ContainsKey('authority')) -and
          ($bcAuthContext.ContainsKey('RefreshToken')) -and
          ($bcAuthContext.ContainsKey('UtcExpiresOn')) -and
          ($bcAuthContext.ContainsKey('tenantID')) -and
          ($bcAuthContext.ContainsKey('AccessToken')) -and
          ($bcAuthContext.ContainsKey('includeDeviceLogin')) -and
          ($bcAuthContext.ContainsKey('deviceLoginTimeout')))) {
        throw 'BcAuthContext should be a HashTable created by New-BcAuthContext.'
    }
}

Function CreatePsTestToolFolder {
    Param(
        [string] $containerName,
        [string] $PsTestToolFolder
    )

    $PsTestFunctionsPath = Join-Path $PsTestToolFolder "PsTestFunctions.ps1"
    $ClientContextPath = Join-Path $PsTestToolFolder "ClientContext.ps1"
    $newtonSoftDllPath = Join-Path $PsTestToolFolder "NewtonSoft.json.dll"
    $clientDllPath = Join-Path $PsTestToolFolder "Microsoft.Dynamics.Framework.UI.Client.dll"

    if (!(Test-Path -Path $PsTestToolFolder -PathType Container)) {
        New-Item -Path $PsTestToolFolder -ItemType Directory | Out-Null
        Copy-Item -Path (Join-Path $PSScriptRoot "AppHandling\PsTestFunctions.ps1") -Destination $PsTestFunctionsPath -Force
        Copy-Item -Path (Join-Path $PSScriptRoot "AppHandling\ClientContext.ps1") -Destination $ClientContextPath -Force
    }

    Invoke-ScriptInBcContainer -containerName $containerName { Param([string] $myNewtonSoftDllPath, [string] $myClientDllPath)
        if (!(Test-Path $myNewtonSoftDllPath)) {
            $newtonSoftDllPath = "C:\Program Files\Microsoft Dynamics NAV\*\Service\Management\NewtonSoft.json.dll"
            if (!(Test-Path $newtonSoftDllPath)) {
                $newtonSoftDllPath = "C:\Program Files\Microsoft Dynamics NAV\*\Service\NewtonSoft.json.dll"
            }
            $newtonSoftDllPath = (Get-Item $newtonSoftDllPath).FullName
            Copy-Item -Path $newtonSoftDllPath -Destination $myNewtonSoftDllPath
        }
        if (!(Test-Path $myClientDllPath)) {
            $clientDllPath = "C:\Test Assemblies\Microsoft.Dynamics.Framework.UI.Client.dll"
            Copy-Item -Path $clientDllPath -Destination $myClientDllPath
        }
    } -argumentList (Get-BcContainerPath -containerName $containerName -Path $newtonSoftDllPath), (Get-BcContainerPath -containerName $containerName -Path $clientDllPath)
}

function RandomChar([string]$str) {
    $rnd = Get-Random -Maximum $str.length
    [string]$str[$rnd]
}

function GetRandomPassword {
    $cons = 'bcdfghjklmnpqrstvwxz'
    $voc = 'aeiouy'
    $numbers = '0123456789'

    ((RandomChar $cons).ToUpper() + `
    (RandomChar $voc) + `
    (RandomChar $cons) + `
    (RandomChar $voc) + `
    (RandomChar $numbers) + `
    (RandomChar $numbers) + `
    (RandomChar $numbers) + `
    (RandomChar $numbers))
}

function getVolumeMountParameter($volumes, $hostPath, $containerPath) {
    $volume = $volumes | Where-Object { $_ -like "*|$hostPath" -or $_ -like "$hostPath|*" }
    if ($volume) {
        $volumeName = $volume.Split('|')[1]
        "--mount source=$($volumeName),target=$containerPath"
    }
    else {
        "--volume ""$($hostPath):$($containerPath)"""
    }
}

function testPfxCertificate([string] $pfxFile, [SecureString] $pfxPassword, [string] $certkind) {
    if (!(Test-Path $pfxFile)) {
        throw "$certkind certificate file does not exist"
    }
    try {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($pfxFile, $pfxPassword)
    }
    catch {
        throw "Unable to read $certkind certificate. Error was $($_.Exception.Message)"
    }
    if ([DateTime]::Now -gt $cert.NotAfter) {
        throw "$certkind certificate expired on $($cert.GetExpirationDateString())"
    }
    if ([DateTime]::Now -gt $cert.NotAfter.AddDays(-14)) {
        Write-Host -ForegroundColor Yellow "$certkind certificate will expire on $($cert.GetExpirationDateString())"
    }
}

function GetHash {
    param(
        [string] $str
    )

    $stream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($str))
    (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash
}

function Wait-Task {
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [System.Threading.Tasks.Task[]]$Task
    )

    Begin {
        $Tasks = @()
    }

    Process {
        $Tasks += $Task
    }

    End {
        While (-not [System.Threading.Tasks.Task]::WaitAll($Tasks, 200)) {}
        $Tasks.ForEach( { $_.GetAwaiter().GetResult() })
    }
}
Set-Alias -Name await -Value Wait-Task -Force

function DownloadFileLow {
    Param(
        [string] $sourceUrl,
        [string] $destinationFile,
        [switch] $dontOverwrite,
        [switch] $useDefaultCredentials,
        [switch] $skipCertificateCheck,
        [hashtable] $headers = @{"UserAgent" = "BcContainerHelper $bcContainerHelperVersion" },
        [int] $timeout = 100
    )

    if ($useTimeOutWebClient) {
        Write-Host "Downloading using WebClient"
        if ($skipCertificateCheck) {
            Write-Host "Disabling SSL Verification"
            [SslVerification]::Disable()
        }
        $webClient = New-Object TimeoutWebClient -ArgumentList (1000 * $timeout)
        $headers.Keys | ForEach-Object {
            $webClient.Headers.Add($_, $headers."$_")
        }
        $webClient.UseDefaultCredentials = $useDefaultCredentials
        if (Test-Path $destinationFile -PathType Leaf) {
            if ($dontOverwrite) { 
                return
            }
            Remove-Item -Path $destinationFile -Force
        }
        try {
            $webClient.DownloadFile($sourceUrl, $destinationFile)
        }
        finally {
            $webClient.Dispose()
            if ($skipCertificateCheck) {
                Write-Host "Restoring SSL Verification"
                [SslVerification]::Enable()
            }
        }
    }
    else {
        Write-Host "Downloading using HttpClient"
        
        $handler = New-Object System.Net.Http.HttpClientHandler
        if ($skipCertificateCheck) {
            Write-Host "Disabling SSL Verification on HttpClient"
            [SslVerification]::DisableSsl($handler)
        }
        if ($useDefaultCredentials) {
            $handler.UseDefaultCredentials = $true
        }
        $httpClient = New-Object System.Net.Http.HttpClient -ArgumentList $handler
        $httpClient.Timeout = [Timespan]::FromSeconds($timeout)
        $headers.Keys | ForEach-Object {
            $httpClient.DefaultRequestHeaders.Add($_, $headers."$_")
        }
        $stream = $null
        $fileStream = $null
        if ($dontOverwrite) {
            $fileMode = [System.IO.FileMode]::CreateNew
        }
        else {
            $fileMode = [System.IO.FileMode]::Create
        }
        try {
            $stream = $httpClient.GetStreamAsync($sourceUrl).GetAwaiter().GetResult()
            $fileStream = New-Object System.IO.Filestream($destinationFile, $fileMode)
            $stream.CopyToAsync($fileStream).GetAwaiter().GetResult() | Out-Null
            $fileStream.Close()
        }
        finally {
            if ($fileStream) {
                $fileStream.Dispose()
            }
            if ($stream) {
                $stream.Dispose()
            }
        }
    }
}

function LoadDLL {
    Param(
        [string] $path
    )
    $bytes = [System.IO.File]::ReadAllBytes($path)
    [System.Reflection.Assembly]::Load($bytes) | Out-Null
}

function GetAppInfo {
    Param(
        [string[]] $appFiles,
        [string] $compilerFolder,
        [string] $cacheAppInfoPath = ''
    )

    $appInfoCache = $null
    $cacheUpdated = $false
    if ($cacheAppInfoPath) {
        if (Test-Path $cacheAppInfoPath) {
            $appInfoCache = Get-Content -Path $cacheAppInfoPath -Encoding utf8 | ConvertFrom-Json
        }
        else {
            $appInfoCache = @{}
        }
    }
    Write-Host "::group::Getting .app info $cacheAppInfoPath"
    $binPath = Join-Path $compilerFolder 'compiler/extension/bin'
    if ($isLinux) {
        $alcPath = Join-Path $binPath 'linux'
        $alToolExe = Join-Path $alcPath 'altool'
        Write-Host "Setting execute permissions on altool"
        & /usr/bin/env sudo pwsh -command "& chmod +x $alToolExe"
    }
    else {
        $alcPath = Join-Path $binPath 'win32'
        $alToolExe = Join-Path $alcPath 'altool.exe'
    }
    if (-not (Test-Path $alcPath)) {
        $alcPath = $binPath
    }
    $alToolExists = Test-Path -Path $alToolExe -PathType Leaf
    $alcDllPath = $alcPath
    if (!$isLinux -and !$isPsCore) {
        $alcDllPath = $binPath
    }

    $ErrorActionPreference = "STOP"
    $assembliesAdded = $false
    $packageStream = $null
    $package = $null
    try {
        foreach($path in $appFiles) {
            Write-Host -NoNewline "- $([System.IO.Path]::GetFileName($path))"
            if ($appInfoCache -and $appInfoCache.PSObject.Properties.Name -eq $path) {
                $appInfo = $appInfoCache."$path"
                Write-Host " (cached)"
            }
            else {
                if ($alToolExists) {
                    $manifest = CmdDo -Command $alToolExe -arguments @('GetPackageManifest', """$path""") -returnValue -silent | ConvertFrom-Json
                    $appInfo = @{
                        "appId"                 = $manifest.id
                        "publisher"             = $manifest.publisher
                        "name"                  = $manifest.name
                        "version"               = $manifest.version
                        "application"           = "$(if($manifest.PSObject.Properties.Name -eq 'application'){$manifest.application})"
                        "platform"              = "$(if($manifest.PSObject.Properties.Name -eq 'platform'){$manifest.Platform})"
                        "propagateDependencies" = ($manifest.PSObject.Properties.Name -eq 'PropagateDependencies') -and $manifest.PropagateDependencies
                        "dependencies"          = @(if($manifest.PSObject.Properties.Name -eq 'dependencies'){$manifest.dependencies | ForEach-Object { @{ "id" = $_.id; "name" = $_.name; "publisher" = $_.publisher; "version" = $_.version }}})
                    }
                }
                else {
                    if (!$assembliesAdded) {
                        Add-Type -AssemblyName System.IO.Compression.FileSystem
                        Add-Type -AssemblyName System.Text.Encoding
                        LoadDLL -Path (Join-Path $alcDllPath Newtonsoft.Json.dll)
                        LoadDLL -Path (Join-Path $alcDllPath System.Collections.Immutable.dll)
                        if (Test-Path (Join-Path $alcDllPath System.IO.Packaging.dll)) {
        		            LoadDLL -Path (Join-Path $alcDllPath System.IO.Packaging.dll)
                        }
                        LoadDLL -Path (Join-Path $alcDllPath Microsoft.Dynamics.Nav.CodeAnalysis.dll)
                        $assembliesAdded = $true
                    }
                    $packageStream = [System.IO.File]::OpenRead($path)
                    $package = [Microsoft.Dynamics.Nav.CodeAnalysis.Packaging.NavAppPackageReader]::Create($PackageStream, $true)
                    $manifest = $package.ReadNavAppManifest()
                    $appInfo = @{
                        "appId"                 = $manifest.AppId
                        "publisher"             = $manifest.AppPublisher
                        "name"                  = $manifest.AppName
                        "version"               = "$($manifest.AppVersion)"
                        "dependencies"          = @($manifest.Dependencies | ForEach-Object { @{ "id" = $_.AppId; "name" = $_.Name; "publisher" = $_.Publisher; "version" = "$($_.Version)" } })
                        "application"           = "$($manifest.Application)"
                        "platform"              = "$($manifest.Platform)"
                        "propagateDependencies" = $manifest.PropagateDependencies
                    }
                }
                Write-Host " (succeeded)"
                if ($cacheAppInfoPath) {
                    $appInfoCache | Add-Member -MemberType NoteProperty -Name $path -Value $appInfo
                    $cacheUpdated = $true
                }
            }
            @{
                "Id"                    = $appInfo.appId
                "AppId"                 = $appInfo.appId
                "Publisher"             = $appInfo.publisher
                "Name"                  = $appInfo.name
                "Version"               = [System.Version]$appInfo.version
                "Dependencies"          = @($appInfo.dependencies)
                "Path"                  = $path
                "Application"           = $appInfo.application
                "Platform"              = $appInfo.platform
                "PropagateDependencies" = $appInfo.propagateDependencies
            }
        }
        if ($cacheUpdated) {
            $appInfoCache | ConvertTo-Json -Depth 99 | Set-Content -Path $cacheAppInfoPath -Encoding UTF8 -Force
        }
    }
    catch [System.Reflection.ReflectionTypeLoadException] {
        Write-Host " (failed)"
        if ($_.Exception.LoaderExceptions) {
            $_.Exception.LoaderExceptions | Select-Object -Property Message | Select-Object -Unique | ForEach-Object {
                Write-Host "LoaderException: $($_.Message)"
            }
        }
        throw
    }
    finally {
        if ($package) {
            $package.Dispose()
        }
        if ($packageStream) {
            $packageStream.Dispose()
        }
    }
    Write-Host "::endgroup::"
}

function GetLatestAlLanguageExtensionVersionAndUrl {
    Param(
        [switch] $allowPrerelease
    )

    $listing = Invoke-WebRequest -Method POST -UseBasicParsing `
                      -Uri https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery?api-version=3.0-preview.1 `
                      -Body '{"filters":[{"criteria":[{"filterType":8,"value":"Microsoft.VisualStudio.Code"},{"filterType":12,"value":"4096"},{"filterType":7,"value":"ms-dynamics-smb.al"}],"pageNumber":1,"pageSize":50,"sortBy":0,"sortOrder":0}],"assetTypes":[],"flags":0x192}' `
                      -ContentType application/json | ConvertFrom-Json
    
    $result =  $listing.results | Select-Object -First 1 -ExpandProperty extensions `
                         | Select-Object -ExpandProperty versions `
                         | Where-Object { ($allowPrerelease.IsPresent -or !(($_.properties.Key -eq 'Microsoft.VisualStudio.Code.PreRelease') -and ($_.properties | where-object { $_.Key -eq 'Microsoft.VisualStudio.Code.PreRelease' }).value -eq "true")) } `
                         | Select-Object -First 1

    if ($result) {
        $vsixUrl = $result.files | Where-Object { $_.assetType -eq "Microsoft.VisualStudio.Services.VSIXPackage"} | Select-Object -ExpandProperty source
        if ($vsixUrl) {
            return $result.version, $vsixUrl
        }
    }
    throw "Unable to locate latest AL Language Extension from the VS Code Marketplace"
}

function DetermineVsixFile {
    Param(
        [string] $vsixFile
    )

    if ($vsixFile -eq 'default') {
        return ''
    }
    elseif ($vsixFile -eq 'latest' -or $vsixFile -eq 'preview') {
        $version, $url = GetLatestAlLanguageExtensionVersionAndUrl -allowPrerelease:($vsixFile -eq 'preview')
        return $url
    }
    else {
        return $vsixFile
    }
}

# Cached Path for latest and preview versions of AL Language Extension
$AlLanguageExtenssionPath = @('','')

function DownloadLatestAlLanguageExtension {
    Param(
        [switch] $allowPrerelease
    )

    $mutexName = "DownloadAlLanguageExtension"
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    try {
        try {
            if (!$mutex.WaitOne(1000)) {
                Write-Host "Waiting for other process downloading AL Language Extension"
                $mutex.WaitOne() | Out-Null
                Write-Host "Other process completed downloading"
            }
        }
        catch [System.Threading.AbandonedMutexException] {
           Write-Host "Other process terminated abnormally"
        }

        # Check if we already have the latest version downloaded and located in this session
        if ($script:AlLanguageExtenssionPath[$allowPrerelease.IsPresent]) {
            $path = $script:AlLanguageExtenssionPath[$allowPrerelease.IsPresent]
            if (Test-Path $path -PathType Container) {
                return $path
            }
            else {
                $script:AlLanguageExtenssionPath[$allowPrerelease.IsPresent] = ''
            }
        }

        $version, $url = GetLatestAlLanguageExtensionVersionAndUrl -allowPrerelease:$allowPrerelease
        $path = Join-Path $bcContainerHelperConfig.hostHelperFolder "alLanguageExtension/$version"
        if (!(Test-Path $path -PathType Container)) {
            $AlLanguageExtensionsFolder = Join-Path $bcContainerHelperConfig.hostHelperFolder "alLanguageExtension"
            if (!(Test-Path $AlLanguageExtensionsFolder -PathType Container)) {
                New-Item -Path $AlLanguageExtensionsFolder -ItemType Directory | Out-Null
            }
            $description = "AL Language Extension"
            if ($allowPrerelease) {
                $description += " (Prerelease)"
            }
            $zipFile = "$path.zip"
            Download-File -sourceUrl $url -destinationFile $zipFile -Description $description
            Expand-7zipArchive -Path $zipFile -DestinationPath $path
            Remove-Item -Path $zipFile -Force
        }
        $script:AlLanguageExtenssionPath[$allowPrerelease.IsPresent] = $path
        return $path
    }
    finally {
        $mutex.ReleaseMutex()
    }
}

function RunAlTool {
    Param(
        [string[]] $arguments
    )
    # ALTOOL is at the moment only available in prerelease        
    $path = DownloadLatestAlLanguageExtension -allowPrerelease
    if ($isLinux) {
        $alToolExe = Join-Path $path 'extension/bin/linux/altool'
        Write-Host "Setting execute permissions on altool"
        & /usr/bin/env sudo pwsh -command "& chmod +x $alToolExe"
    }
    else {
        $alToolExe = Join-Path $path 'extension/bin/win32/altool.exe'
    }
    CmdDo -Command $alToolExe -arguments $arguments -returnValue -silent
}

function GetApplicationDependency( [string] $appFile, [string] $minVersion = "0.0" ) {
    try {
        $appJson = Get-AppJsonFromAppFile -appFile $appFile
    }
    catch {
        Write-Host -ForegroundColor Red "Unable to read app $([System.IO.Path]::GetFileName($appFile)), ignoring application dependency check"
        return $minVersion
    }
    $version = $minVersion
    if ($appJson.PSObject.Properties.Name -eq "Application") {
        $version = $appJson.application
    }
    elseif ($appJson.PSObject.Properties.Name -eq "dependencies") {
        $baseAppDependency = $appJson.dependencies | Where-Object { $_.Name -eq "Base Application" -and $_.Publisher -eq "Microsoft" }
        if ($baseAppDependency) {
            $version = $baseAppDependency.Version
        }
    }
    if ([System.Version]$version -lt [System.Version]$minVersion) {
        $version = $minVersion
    }
    return $version
}

# SIG # Begin signature block
# MIIr3wYJKoZIhvcNAQcCoIIr0DCCK8wCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBz7yAmYXUUUN9N
# uGD+CL5MCcPx5yJb+d2YgusHdgCXjqCCJPcwggVvMIIEV6ADAgECAhBI/JO0YFWU
# jTanyYqJ1pQWMA0GCSqGSIb3DQEBDAUAMHsxCzAJBgNVBAYTAkdCMRswGQYDVQQI
# DBJHcmVhdGVyIE1hbmNoZXN0ZXIxEDAOBgNVBAcMB1NhbGZvcmQxGjAYBgNVBAoM
# EUNvbW9kbyBDQSBMaW1pdGVkMSEwHwYDVQQDDBhBQUEgQ2VydGlmaWNhdGUgU2Vy
# dmljZXMwHhcNMjEwNTI1MDAwMDAwWhcNMjgxMjMxMjM1OTU5WjBWMQswCQYDVQQG
# EwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMS0wKwYDVQQDEyRTZWN0aWdv
# IFB1YmxpYyBDb2RlIFNpZ25pbmcgUm9vdCBSNDYwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQCN55QSIgQkdC7/FiMCkoq2rjaFrEfUI5ErPtx94jGgUW+s
# hJHjUoq14pbe0IdjJImK/+8Skzt9u7aKvb0Ffyeba2XTpQxpsbxJOZrxbW6q5KCD
# J9qaDStQ6Utbs7hkNqR+Sj2pcaths3OzPAsM79szV+W+NDfjlxtd/R8SPYIDdub7
# P2bSlDFp+m2zNKzBenjcklDyZMeqLQSrw2rq4C+np9xu1+j/2iGrQL+57g2extme
# me/G3h+pDHazJyCh1rr9gOcB0u/rgimVcI3/uxXP/tEPNqIuTzKQdEZrRzUTdwUz
# T2MuuC3hv2WnBGsY2HH6zAjybYmZELGt2z4s5KoYsMYHAXVn3m3pY2MeNn9pib6q
# RT5uWl+PoVvLnTCGMOgDs0DGDQ84zWeoU4j6uDBl+m/H5x2xg3RpPqzEaDux5mcz
# mrYI4IAFSEDu9oJkRqj1c7AGlfJsZZ+/VVscnFcax3hGfHCqlBuCF6yH6bbJDoEc
# QNYWFyn8XJwYK+pF9e+91WdPKF4F7pBMeufG9ND8+s0+MkYTIDaKBOq3qgdGnA2T
# OglmmVhcKaO5DKYwODzQRjY1fJy67sPV+Qp2+n4FG0DKkjXp1XrRtX8ArqmQqsV/
# AZwQsRb8zG4Y3G9i/qZQp7h7uJ0VP/4gDHXIIloTlRmQAOka1cKG8eOO7F/05QID
# AQABo4IBEjCCAQ4wHwYDVR0jBBgwFoAUoBEKIz6W8Qfs4q8p74Klf9AwpLQwHQYD
# VR0OBBYEFDLrkpr/NZZILyhAQnAgNpFcF4XmMA4GA1UdDwEB/wQEAwIBhjAPBgNV
# HRMBAf8EBTADAQH/MBMGA1UdJQQMMAoGCCsGAQUFBwMDMBsGA1UdIAQUMBIwBgYE
# VR0gADAIBgZngQwBBAEwQwYDVR0fBDwwOjA4oDagNIYyaHR0cDovL2NybC5jb21v
# ZG9jYS5jb20vQUFBQ2VydGlmaWNhdGVTZXJ2aWNlcy5jcmwwNAYIKwYBBQUHAQEE
# KDAmMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5jb21vZG9jYS5jb20wDQYJKoZI
# hvcNAQEMBQADggEBABK/oe+LdJqYRLhpRrWrJAoMpIpnuDqBv0WKfVIHqI0fTiGF
# OaNrXi0ghr8QuK55O1PNtPvYRL4G2VxjZ9RAFodEhnIq1jIV9RKDwvnhXRFAZ/ZC
# J3LFI+ICOBpMIOLbAffNRk8monxmwFE2tokCVMf8WPtsAO7+mKYulaEMUykfb9gZ
# pk+e96wJ6l2CxouvgKe9gUhShDHaMuwV5KZMPWw5c9QLhTkg4IUaaOGnSDip0TYl
# d8GNGRbFiExmfS9jzpjoad+sPKhdnckcW67Y8y90z7h+9teDnRGWYpquRRPaf9xH
# +9/DUp/mBlXpnYzyOmJRvOwkDynUWICE5EV7WtgwggWNMIIEdaADAgECAhAOmxiO
# +dAt5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYD
# VQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAi
# BgNVBAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAw
# MDBaFw0zMTExMDkyMzU5NTlaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdp
# Q2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERp
# Z2lDZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCC
# AgoCggIBAL/mkHNo3rvkXUo8MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsb
# hA3EMB/zG6Q4FutWxpdtHauyefLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iT
# cMKyunWZanMylNEQRBAu34LzB4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGb
# NOsFxl7sWxq868nPzaw0QF+xembud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclP
# XuU15zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCr
# VYJBMtfbBHMqbpEBfCFM1LyuGwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFP
# ObURWBf3JFxGj2T3wWmIdph2PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTv
# kpI6nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWM
# cCxBYKqxYxhElRp2Yn72gLD76GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls
# 5Q5SUUd0viastkF13nqsX40/ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBR
# a2+xq4aLT8LWRV+dIPyhHsXAj6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6
# MIIBNjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qY
# rhwPTzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8E
# BAMCAYYweQYIKwYBBQUHAQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5k
# aWdpY2VydC5jb20wQwYIKwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0
# LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDig
# NoY0aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9v
# dENBLmNybDARBgNVHSAECjAIMAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCg
# v0NcVec4X6CjdBs9thbX979XB72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQT
# SnovLbc47/T/gLn4offyct4kvFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh
# 65ZyoUi0mcudT6cGAxN3J0TU53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSw
# uKFWjuyk1T3osdz9HNj0d1pcVIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAO
# QGPFmCLBsln1VWvPJ6tsds5vIy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjD
# TZ9ztwGpn1eqXijiuZQwggYaMIIEAqADAgECAhBiHW0MUgGeO5B5FSCJIRwKMA0G
# CSqGSIb3DQEBDAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExp
# bWl0ZWQxLTArBgNVBAMTJFNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBSb290
# IFI0NjAeFw0yMTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMFQxCzAJBgNVBAYT
# AkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28g
# UHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwggGiMA0GCSqGSIb3DQEBAQUAA4IB
# jwAwggGKAoIBgQCbK51T+jU/jmAGQ2rAz/V/9shTUxjIztNsfvxYB5UXeWUzCxEe
# AEZGbEN4QMgCsJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NVDgFigOMYzB2OKhdqfWGV
# oYW3haT29PSTahYkwmMv0b/83nbeECbiMXhSOtbam+/36F09fy1tsB8je/RV0mIk
# 8XL/tfCK6cPuYHE215wzrK0h1SWHTxPbPuYkRdkP05ZwmRmTnAO5/arnY83jeNzh
# P06ShdnRqtZlV59+8yv+KIhE5ILMqgOZYAENHNX9SJDm+qxp4VqpB3MV/h53yl41
# aHU5pledi9lCBbH9JeIkNFICiVHNkRmq4TpxtwfvjsUedyz8rNyfQJy/aOs5b4s+
# ac7IH60B+Ja7TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz44MPZ1f9+YEQIQty/NQd/
# 2yGgW+ufflcZ/ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBMdlyh2n5HirY4jKnFH/9g
# Rvd+QOfdRrJZb1sCAwEAAaOCAWQwggFgMB8GA1UdIwQYMBaAFDLrkpr/NZZILyhA
# QnAgNpFcF4XmMB0GA1UdDgQWBBQPKssghyi47G9IritUpimqF6TNDDAOBgNVHQ8B
# Af8EBAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNVHSUEDDAKBggrBgEFBQcD
# AzAbBgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsGA1UdHwREMEIwQKA+oDyG
# Omh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5n
# Um9vdFI0Ni5jcmwwewYIKwYBBQUHAQEEbzBtMEYGCCsGAQUFBzAChjpodHRwOi8v
# Y3J0LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYu
# cDdjMCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG
# 9w0BAQwFAAOCAgEABv+C4XdjNm57oRUgmxP/BP6YdURhw1aVcdGRP4Wh60BAscjW
# 4HL9hcpkOTz5jUug2oeunbYAowbFC2AKK+cMcXIBD0ZdOaWTsyNyBBsMLHqafvIh
# rCymlaS98+QpoBCyKppP0OcxYEdU0hpsaqBBIZOtBajjcw5+w/KeFvPYfLF/ldYp
# mlG+vd0xqlqd099iChnyIMvY5HexjO2AmtsbpVn0OhNcWbWDRF/3sBp6fWXhz7Dc
# ML4iTAWS+MVXeNLj1lJziVKEoroGs9Mlizg0bUMbOalOhOfCipnx8CaLZeVme5yE
# Lg09Jlo8BMe80jO37PU8ejfkP9/uPak7VLwELKxAMcJszkyeiaerlphwoKx1uHRz
# NyE6bxuSKcutisqmKL5OTunAvtONEoteSiabkPVSZ2z76mKnzAfZxCl/3dq3dUNw
# 4rg3sTCggkHSRqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5JKdGvspbOrTfOXyXvmPL6
# E52z1NZJ6ctuMFBQZH3pwWvqURR8AgQdULUvrxjUYbHHj95Ejza63zdrEcxWLDX6
# xWls/GDnVNueKjWUH3fTv1Y8Wdho698YADR7TNx8X8z2Bev6SivBBOHY+uqiirZt
# g0y9ShQoPzmCcn63Syatatvx157YK9hlcPmVoa1oDE5/L9Uo2bC5a4CH2RwwggZZ
# MIIEwaADAgECAhANIM3qwHRbWKHw+Zq6JhzlMA0GCSqGSIb3DQEBDAUAMFQxCzAJ
# BgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNl
# Y3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwHhcNMjExMDIyMDAwMDAw
# WhcNMjQxMDIxMjM1OTU5WjBdMQswCQYDVQQGEwJESzEUMBIGA1UECAwLSG92ZWRz
# dGFkZW4xGzAZBgNVBAoMEkZyZWRkeSBLcmlzdGlhbnNlbjEbMBkGA1UEAwwSRnJl
# ZGR5IEtyaXN0aWFuc2VuMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA
# gYC5tlg+VRktRRkahxxaV8+DAd6vHoDpcO6w7yT24lnSoMuA6nR7kgy90Y/sHIwK
# E9Wwt/px/GAY8eBePWjJrFpG8fBtJbXadRTVd/470Hs/q9t+kh6A/0ELj7wYsKSN
# OyuFPoy4rtClOv9ZmrRpoDVnh8Epwg2DpklX2BNzykzBQxIbkpp+xVo2mhPNWDIe
# sntc4/BnSebLGw1Vkxmu2acKkIjYrne/7lsuyL9ue0vk8TGk9JBPNPbGKJvHu9sz
# P9oGoH36fU1sEZ+AacXrp+onsyPf/hkkpAMHAhzQHl+5Ikvcus/cDm06twm7Vywm
# Zcas2rFAV5MyE6WMEaYAolwAHiPz9WAs2GDhFtZZg1tzbRjJIIgPpR+doTIcpcDB
# cHnNdSdgWKrTkr2f339oT5bnJfo7oVzc/2HGWvb8Fom6LQAqSC11vWmznHYsCm72
# g+foTKqW8lLDfLF0+aFvToLosrtW9l6Z+l+RQ8MtJ9EHOm2Ny8cFLzZCDZYw32By
# dwcLV5rKdy4Ica9on5xZvyMOLiFwuL4v2V4pjEgKJaGSS/IVSMEGjrM9DHT6YS4/
# oq9q20rQUmMZZQmGmEyyKQ8t11si8VHtScN5m0Li8peoWfCU9mRFxSESwTWow8d4
# 62+o9/SzmDxCACdFwzvfKx4JqDMm55cL+beunIvc0NsCAwEAAaOCAZwwggGYMB8G
# A1UdIwQYMBaAFA8qyyCHKLjsb0iuK1SmKaoXpM0MMB0GA1UdDgQWBBTZD6uy9ZWI
# IqQh3srYu1FlUhdM0TAOBgNVHQ8BAf8EBAMCB4AwDAYDVR0TAQH/BAIwADATBgNV
# HSUEDDAKBggrBgEFBQcDAzARBglghkgBhvhCAQEEBAMCBBAwSgYDVR0gBEMwQTA1
# BgwrBgEEAbIxAQIBAwIwJTAjBggrBgEFBQcCARYXaHR0cHM6Ly9zZWN0aWdvLmNv
# bS9DUFMwCAYGZ4EMAQQBMEkGA1UdHwRCMEAwPqA8oDqGOGh0dHA6Ly9jcmwuc2Vj
# dGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nQ0FSMzYuY3JsMHkGCCsG
# AQUFBwEBBG0wazBEBggrBgEFBQcwAoY4aHR0cDovL2NydC5zZWN0aWdvLmNvbS9T
# ZWN0aWdvUHVibGljQ29kZVNpZ25pbmdDQVIzNi5jcnQwIwYIKwYBBQUHMAGGF2h0
# dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqGSIb3DQEBDAUAA4IBgQASEbZACurQ
# eQN8WDTR+YyNpoQ29YAbbdBRhhzHkT/1ao7LE0QIOgGR4GwKRzufCAwu8pCBiMOU
# TDHTezkh0rQrG6khxBX2nSTBL5i4LwKMR08HgZBsbECciABy15yexYWoB/D0H8Wu
# Ge63PhGWueR4IFPbIz+jEVxfW0Nyyr7bXTecpKd1iprm+TOmzc2E6ab95dkcXdJV
# x6Zys++QrrOfQ+a57qEXkS/wnjjbN9hukL0zg+g8L4DHLKTodzfiQOampvV8Qzbn
# B7Y8YjNcxR9s/nptnlQH3jorNFhktiBXvD62jc8pAIg6wyH6NxSMjtTsn7QhkIp2
# kuswIQwD8hN/fZ/m6gkXZhRJWFr2WRZOz+edZ62Jf25C/NYWscwfBwn2hzRZf1Hg
# yxkXAl88dvvUA3kw1T6uo8aAB9IcL6Owiy7q4T+RLRF7oqx0vcw0193Yhq/gPOaU
# FlqzExP6TQ5TR9XWVPQk+a1B1ATKMLi1JShO6KWTmNkFkgkgpkW69BEwggauMIIE
# lqADAgECAhAHNje3JFR82Ees/ShmKl5bMA0GCSqGSIb3DQEBCwUAMGIxCzAJBgNV
# BAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdp
# Y2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRydXN0ZWQgUm9vdCBHNDAeFw0y
# MjAzMjMwMDAwMDBaFw0zNzAzMjIyMzU5NTlaMGMxCzAJBgNVBAYTAlVTMRcwFQYD
# VQQKEw5EaWdpQ2VydCwgSW5jLjE7MDkGA1UEAxMyRGlnaUNlcnQgVHJ1c3RlZCBH
# NCBSU0E0MDk2IFNIQTI1NiBUaW1lU3RhbXBpbmcgQ0EwggIiMA0GCSqGSIb3DQEB
# AQUAA4ICDwAwggIKAoICAQDGhjUGSbPBPXJJUVXHJQPE8pE3qZdRodbSg9GeTKJt
# oLDMg/la9hGhRBVCX6SI82j6ffOciQt/nR+eDzMfUBMLJnOWbfhXqAJ9/UO0hNoR
# 8XOxs+4rgISKIhjf69o9xBd/qxkrPkLcZ47qUT3w1lbU5ygt69OxtXXnHwZljZQp
# 09nsad/ZkIdGAHvbREGJ3HxqV3rwN3mfXazL6IRktFLydkf3YYMZ3V+0VAshaG43
# IbtArF+y3kp9zvU5EmfvDqVjbOSmxR3NNg1c1eYbqMFkdECnwHLFuk4fsbVYTXn+
# 149zk6wsOeKlSNbwsDETqVcplicu9Yemj052FVUmcJgmf6AaRyBD40NjgHt1bicl
# kJg6OBGz9vae5jtb7IHeIhTZgirHkr+g3uM+onP65x9abJTyUpURK1h0QCirc0PO
# 30qhHGs4xSnzyqqWc0Jon7ZGs506o9UD4L/wojzKQtwYSH8UNM/STKvvmz3+Drhk
# Kvp1KCRB7UK/BZxmSVJQ9FHzNklNiyDSLFc1eSuo80VgvCONWPfcYd6T/jnA+bIw
# pUzX6ZhKWD7TA4j+s4/TXkt2ElGTyYwMO1uKIqjBJgj5FBASA31fI7tk42PgpuE+
# 9sJ0sj8eCXbsq11GdeJgo1gJASgADoRU7s7pXcheMBK9Rp6103a50g5rmQzSM7TN
# sQIDAQABo4IBXTCCAVkwEgYDVR0TAQH/BAgwBgEB/wIBADAdBgNVHQ4EFgQUuhbZ
# bU2FL3MpdpovdYxqII+eyG8wHwYDVR0jBBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4c
# D08wDgYDVR0PAQH/BAQDAgGGMBMGA1UdJQQMMAoGCCsGAQUFBwMIMHcGCCsGAQUF
# BwEBBGswaTAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEEG
# CCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRU
# cnVzdGVkUm9vdEc0LmNydDBDBgNVHR8EPDA6MDigNqA0hjJodHRwOi8vY3JsMy5k
# aWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNybDAgBgNVHSAEGTAX
# MAgGBmeBDAEEAjALBglghkgBhv1sBwEwDQYJKoZIhvcNAQELBQADggIBAH1ZjsCT
# tm+YqUQiAX5m1tghQuGwGC4QTRPPMFPOvxj7x1Bd4ksp+3CKDaopafxpwc8dB+k+
# YMjYC+VcW9dth/qEICU0MWfNthKWb8RQTGIdDAiCqBa9qVbPFXONASIlzpVpP0d3
# +3J0FNf/q0+KLHqrhc1DX+1gtqpPkWaeLJ7giqzl/Yy8ZCaHbJK9nXzQcAp876i8
# dU+6WvepELJd6f8oVInw1YpxdmXazPByoyP6wCeCRK6ZJxurJB4mwbfeKuv2nrF5
# mYGjVoarCkXJ38SNoOeY+/umnXKvxMfBwWpx2cYTgAnEtp/Nh4cku0+jSbl3ZpHx
# cpzpSwJSpzd+k1OsOx0ISQ+UzTl63f8lY5knLD0/a6fxZsNBzU+2QJshIUDQtxMk
# zdwdeDrknq3lNHGS1yZr5Dhzq6YBT70/O3itTK37xJV77QpfMzmHQXh6OOmc4d0j
# /R0o08f56PGYX/sr2H7yRp11LB4nLCbbbxV7HhmLNriT1ObyF5lZynDwN7+YAN8g
# Fk8n+2BnFqFmut1VwDophrCYoCvtlUG3OtUVmDG0YgkPCr2B2RP+v6TR81fZvAT6
# gt4y3wSJ8ADNXcL50CN/AAvkdgIm2fBldkKmKYcJRyvmfxqkhQ/8mJb2VVQrH4D6
# wPIOK+XW+6kvRBVK5xMOHds3OBqhK/bt1nz8MIIGwjCCBKqgAwIBAgIQBUSv85Sd
# CDmmv9s/X+VhFjANBgkqhkiG9w0BAQsFADBjMQswCQYDVQQGEwJVUzEXMBUGA1UE
# ChMORGlnaUNlcnQsIEluYy4xOzA5BgNVBAMTMkRpZ2lDZXJ0IFRydXN0ZWQgRzQg
# UlNBNDA5NiBTSEEyNTYgVGltZVN0YW1waW5nIENBMB4XDTIzMDcxNDAwMDAwMFoX
# DTM0MTAxMzIzNTk1OVowSDELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0
# LCBJbmMuMSAwHgYDVQQDExdEaWdpQ2VydCBUaW1lc3RhbXAgMjAyMzCCAiIwDQYJ
# KoZIhvcNAQEBBQADggIPADCCAgoCggIBAKNTRYcdg45brD5UsyPgz5/X5dLnXaEO
# CdwvSKOXejsqnGfcYhVYwamTEafNqrJq3RApih5iY2nTWJw1cb86l+uUUI8cIOrH
# mjsvlmbjaedp/lvD1isgHMGXlLSlUIHyz8sHpjBoyoNC2vx/CSSUpIIa2mq62DvK
# Xd4ZGIX7ReoNYWyd/nFexAaaPPDFLnkPG2ZS48jWPl/aQ9OE9dDH9kgtXkV1lnX+
# 3RChG4PBuOZSlbVH13gpOWvgeFmX40QrStWVzu8IF+qCZE3/I+PKhu60pCFkcOvV
# 5aDaY7Mu6QXuqvYk9R28mxyyt1/f8O52fTGZZUdVnUokL6wrl76f5P17cz4y7lI0
# +9S769SgLDSb495uZBkHNwGRDxy1Uc2qTGaDiGhiu7xBG3gZbeTZD+BYQfvYsSzh
# Ua+0rRUGFOpiCBPTaR58ZE2dD9/O0V6MqqtQFcmzyrzXxDtoRKOlO0L9c33u3Qr/
# eTQQfqZcClhMAD6FaXXHg2TWdc2PEnZWpST618RrIbroHzSYLzrqawGw9/sqhux7
# UjipmAmhcbJsca8+uG+W1eEQE/5hRwqM/vC2x9XH3mwk8L9CgsqgcT2ckpMEtGlw
# Jw1Pt7U20clfCKRwo+wK8REuZODLIivK8SgTIUlRfgZm0zu++uuRONhRB8qUt+JQ
# ofM604qDy0B7AgMBAAGjggGLMIIBhzAOBgNVHQ8BAf8EBAMCB4AwDAYDVR0TAQH/
# BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAgBgNVHSAEGTAXMAgGBmeBDAEE
# AjALBglghkgBhv1sBwEwHwYDVR0jBBgwFoAUuhbZbU2FL3MpdpovdYxqII+eyG8w
# HQYDVR0OBBYEFKW27xPn783QZKHVVqllMaPe1eNJMFoGA1UdHwRTMFEwT6BNoEuG
# SWh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFJTQTQw
# OTZTSEEyNTZUaW1lU3RhbXBpbmdDQS5jcmwwgZAGCCsGAQUFBwEBBIGDMIGAMCQG
# CCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20wWAYIKwYBBQUHMAKG
# TGh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFJT
# QTQwOTZTSEEyNTZUaW1lU3RhbXBpbmdDQS5jcnQwDQYJKoZIhvcNAQELBQADggIB
# AIEa1t6gqbWYF7xwjU+KPGic2CX/yyzkzepdIpLsjCICqbjPgKjZ5+PF7SaCinEv
# GN1Ott5s1+FgnCvt7T1IjrhrunxdvcJhN2hJd6PrkKoS1yeF844ektrCQDifXcig
# LiV4JZ0qBXqEKZi2V3mP2yZWK7Dzp703DNiYdk9WuVLCtp04qYHnbUFcjGnRuSvE
# xnvPnPp44pMadqJpddNQ5EQSviANnqlE0PjlSXcIWiHFtM+YlRpUurm8wWkZus8W
# 8oM3NG6wQSbd3lqXTzON1I13fXVFoaVYJmoDRd7ZULVQjK9WvUzF4UbFKNOt50MA
# cN7MmJ4ZiQPq1JE3701S88lgIcRWR+3aEUuMMsOI5ljitts++V+wQtaP4xeR0arA
# VeOGv6wnLEHQmjNKqDbUuXKWfpd5OEhfysLcPTLfddY2Z1qJ+Panx+VPNTwAvb6c
# Kmx5AdzaROY63jg7B145WPR8czFVoIARyxQMfq68/qTreWWqaNYiyjvrmoI1VygW
# y2nyMpqy0tg6uLFGhmu6F/3Ed2wVbK6rr3M66ElGt9V/zLY4wNjsHPW2obhDLN9O
# TH0eaHDAdwrUAuBcYLso/zjlUlrWrBciI0707NMX+1Br/wd3H3GXREHJuEbTbDJ8
# WC9nR2XlG3O2mflrLAZG70Ee8PBf4NvZrZCARK+AEEGKMYIGPjCCBjoCAQEwaDBU
# MQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMSswKQYDVQQD
# EyJTZWN0aWdvIFB1YmxpYyBDb2RlIFNpZ25pbmcgQ0EgUjM2AhANIM3qwHRbWKHw
# +Zq6JhzlMA0GCWCGSAFlAwQCAQUAoIGEMBgGCisGAQQBgjcCAQwxCjAIoAKAAKEC
# gAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwG
# CisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIGzauquhbAI2KUsY2hn1JJ4vkjeU
# 5ddlJsT7imztCH9EMA0GCSqGSIb3DQEBAQUABIICAERqcEwNzS6csvofpM+rcOeM
# /Qnz9K3zXkPWf0kAlezhUHGjLxV4lCx49xfDLf6IWQlYbQ9CHSMuWqvAdLLCVNRQ
# U2R2aMS9xDYf8ckUBGusrYogyyPrg//sHPUR7iq+7d48jVSNuvqL78Hp10ECzA/c
# COjq/TXTo2cpsMRUCm0Q1YGNrGCJzZvYJ3fglGj9B1A3FgBTnajrEsBSnTkw0Jv9
# CwNbD4Ms/ro5xR1ti2BFNCRF4iP2wM4H1dgiaYB7iPB9TX+UVVJc5CEoUxkxcP4r
# OsLnwobDORzPPTfb4/lMfa6T/uF8BWJy5kZbAUx1kszxpLWcxJOlbaYvr+wltBBG
# XXTOKSBhgCfKwWuzbZ9r1hOcDuHA+qdGYXW2TMtKjZmDHN8B9mpQT04zd/UdNnCQ
# Rx3MR/6xDB0hpn8EMnTt6CGHt9NMGVc8RugA81JottBlX5b66rtci7udKZcwUW4L
# rSoulWNTScmLEP90OjtEGDvhP8+cXO0qwJI1YZVRTuBA9C95+lNByBrRWfhG7GOX
# Zd5abCt415fLz8TPHgJ94IOhcJ7PWrbZggKbZDobDTyND2h2FY27LP9vOdOAVcvc
# d6s3y8J3uZAXm4+8mlvCAx7aIS5JK0Nhwv4Yaspv5lsCEUjhinNjIyoMGR80uhGz
# bViKz9J1TMGT6mtUKftCoYIDIDCCAxwGCSqGSIb3DQEJBjGCAw0wggMJAgEBMHcw
# YzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQD
# EzJEaWdpQ2VydCBUcnVzdGVkIEc0IFJTQTQwOTYgU0hBMjU2IFRpbWVTdGFtcGlu
# ZyBDQQIQBUSv85SdCDmmv9s/X+VhFjANBglghkgBZQMEAgEFAKBpMBgGCSqGSIb3
# DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI0MDMxNDIwNDY1MFow
# LwYJKoZIhvcNAQkEMSIEIJ+J7X2WOwTdL5mcmFUEyz9AIEGOPCIgxE7Yz8tCSzD3
# MA0GCSqGSIb3DQEBAQUABIICAFLRoLE5RtNLcgxcDeBmGTjmDQJQE9Vjrt0RX2dL
# a+3MhIFd8JsxayYKIof/ki4jjXa6mhFw9qzytpdD7Efb2Ld3BSQxrSHziIKrQctN
# P/9PV9MiA6PjX1VSF8o4wgbc9m8jHyI24qJ5bKoIM+S99/NSTTeae58lkO4yNgSq
# MdUvBDcZs7qBjRZPmA9aKILngb5axnsa89FYhJ6tbxUCh91DU8YHP2EQXOJ8bXwA
# oYjDC5ANHDxFi/gUKkzjBtFTWQwYAF2sxkJ0QltFNOR+P5DCDH2rZ8haaI0oGKf0
# 10txAn8VWpMI3uWASMqaT7lUmGDOAkIKrFJ50K4otH3E+ZKJ5tZO3sF6pfZlqvwE
# Ddm7N/GxW5C20GZPHMQn67/RcF0qx2sbPmxIUCYLKN61JaxH8G0Qde5CqWZ5vAVs
# mmA4tQM1IQeNzOwrrS7gvYLnYYNqVV8QMWI7vuf3GS7Gn8v2im+2EcFS6NBNsNZq
# 7MnMWyjaGHOuOLY0JoTdnRwYmW6JD4TsRd/0EfPw0a48Gch6bVa4mRouQAyIpK7/
# VeBUxm89qcovRmzLO6/KGxSjt20LS1xZM07Bkj43aW3RKLyeAcRc2pho2wB+WPB8
# kd3EHQ39qj++m2vk9Dl20v8hGmF8Vojfc6JJHXNG8HbBR72Bo58TJhjDyuplea26
# topi
# SIG # End signature block
