# Script to get Intune Group Tag and set environment variable based on CSV lookup
# Requires: $authtoken variable to be set with valid Microsoft Graph API token
# Requires: $URL variable to be set with CSV file location

# Function to get the current device's Azure AD Device ID


function Get-AuthToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [String] $TenantId,
        [Parameter(Mandatory=$true)] [String] $AppId,
        [Parameter(Mandatory=$true)] [String] $AppSecret
    )

    try {
        # Define auth body
        $body = @{
            grant_type    = "client_credentials"
            client_id     = $AppId
            client_secret = $AppSecret
            scope         = "https://graph.microsoft.com/.default"
        }

        # Get OAuth token
        $response = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body $body
        
        # Return the token
        return $response.access_token
    }
    catch {
        Write-Host "Error getting auth token: $_" -ForegroundColor Red
        if ($_.Exception.Response) {
            $errorResponse = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($errorResponse)
            $reader.BaseStream.Position = 0
            $reader.DiscardBufferedData()
            $responseBody = $reader.ReadToEnd()
            Write-Host $responseBody -ForegroundColor Red
        }
        throw
    }
}




function Get-AzureADDeviceID {
    try {
        $dsreg = dsregcmd /status
        $deviceId = ($dsreg | Select-String "DeviceId").ToString().Split(":")[1].Trim()
        return $deviceId
    }
    catch {
        Write-Error "Failed to get Azure AD Device ID: $_"
        return $null
    }
}

# Function to download and parse CSV
function Get-LocationFromCSV {
    param (
        [string]$URL,
        [string]$GroupTagPrefix
    )
    
    try {
        Write-Host "Downloading CSV from: $URL" -ForegroundColor Cyan
        $csvContent = Invoke-WebRequest -Uri $URL -UseBasicParsing
        $csvData = $csvContent.Content | ConvertFrom-Csv
        
        Write-Host "Searching for code: $GroupTagPrefix" -ForegroundColor Cyan
        
        # Find matching entry where code matches first 5 digits of group tag
        $match = $csvData | Where-Object { $_.code -eq $GroupTagPrefix }
        
        if ($match) {
            return $match.name
        }
        else {
            Write-Warning "No matching code found in CSV for: $GroupTagPrefix"
            return $null
        }
    }
    catch {
        Write-Error "Failed to download or parse CSV: $_"
        return $null
    }
}

# Function to query Graph API for device details
function Get-IntuneDeviceGroupTag {
    param (
        [string]$DeviceId,
        [string]$AuthToken
    )
    
    try {
        $headers = @{
            "Authorization" = "Bearer $AuthToken"
            "Content-Type" = "application/json"
        }
        
        # Query managed devices by Azure AD Device ID
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=azureADDeviceId eq '$DeviceId'"
        
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
        
        if ($response.value.Count -gt 0) {
            $groupTag = $response.value[0].groupTag
            return $groupTag
        }
        else {
            Write-Warning "Device not found in Intune"
            return $null
        }
    }
    catch {
        Write-Error "Failed to query Graph API: $_"
        return $null
    }
}


# Main script execution

$TenantId = "2a37880e-66f8-4414-bb9c-7582e06701b3"
$AppId = "d3d48857-7b35-4d5e-8786-45895bcf185c"
$AppSecret = "lVc8Q~9rrDfVLMUiO8ezYhrK-MNO3y1XnHIwNdnm"
$URL= "https://raw.githubusercontent.com/dgoldstein-wcpss/osd/refs/heads/main/SchoolList.csv"

$authToken = Get-AuthToken -TenantId $TenantId -AppId $AppId -AppSecret $AppSecret



Write-Host "Retrieving Azure AD Device ID..." -ForegroundColor Cyan
$deviceId = Get-AzureADDeviceID

if ($null -eq $deviceId) {
    Write-Error "Could not retrieve Device ID. Ensure device is Azure AD joined."
    exit 1
}

Write-Host "Device ID: $deviceId" -ForegroundColor Green

Write-Host "Querying Intune for Group Tag..." -ForegroundColor Cyan
$groupTag = Get-IntuneDeviceGroupTag -DeviceId $deviceId -AuthToken $authtoken

if ($null -ne $groupTag -and $groupTag -ne "") {
    Write-Host "Group Tag found: $groupTag" -ForegroundColor Green
    
    # Extract first 5 digits of group tag
    $groupTagPrefix = $groupTag.Substring(0, [Math]::Min(5, $groupTag.Length))
    Write-Host "Group Tag Prefix (first 5 chars): $groupTagPrefix" -ForegroundColor Yellow
    
    # Get location from CSV
    $location = Get-LocationFromCSV -URL $URL -GroupTagPrefix $groupTagPrefix
    
    if ($null -ne $location) {
        Write-Host "Location found: $location" -ForegroundColor Green
        
        # Set Location environment variable (Machine level - requires admin)
        try {
            [System.Environment]::SetEnvironmentVariable("Location", $location, "Machine")
            Write-Host "Environment variable 'Location' set to: $location" -ForegroundColor Green
            
            # Also set for current session
            $env:Location = $location
            Write-Host "Variable also set for current PowerShell session" -ForegroundColor Yellow
        }
        catch {
            Write-Warning "Failed to set Machine-level variable (requires admin). Setting User-level instead..."
            [System.Environment]::SetEnvironmentVariable("Location", $location, "User")
            $env:Location = $location
            Write-Host "Environment variable 'Location' set at User level to: $location" -ForegroundColor Green
        }
    }
    else {
        Write-Error "Could not determine location from CSV lookup"
        exit 1
    }
}
elseif ($groupTag -eq "") {
    Write-Warning "Group Tag is empty for this device"
    exit 1
}
else {
    Write-Error "Could not retrieve Group Tag from Intune"
    exit 1
}
