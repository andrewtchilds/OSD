if ($env:SystemDrive -eq 'X:') {
    function Connect-WinREWiFi {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [string] $SSID
        )

        $network = Get-WinREWiFi | Where-Object { $_.SSID -eq $SSID }

        $password = ""
        $notWPA2 = ""
        if ($network.Authentication -ne "Open") {
            $cred = Get-Credential -Message "Enter password for WIFI network '$SSID'" -UserName $SSID
            $password = $cred.GetNetworkCredential().password

            #TODO it can be WEP or enterprise ...but I don't know how Authentication value look like for them
            $notWPA2 = $network | Where-Object { $_.Authentication -ne "WPA2-Personal" }
        }

        # just for sure
        $null = Netsh WLAN delete profile "$SSID"

        # create new network profile
        $param = @{
            WLanName = $SSID
        }
        if ($password) { $param.Passwd = $password }
        if ($notWPA2) { $param.WPA = $true }
        Set-WinREWiFi @param

        # connect to network
        $result = Netsh WLAN connect name="$SSID"
        if ($result -ne "Connection request was completed successfully.") {
            throw "Connection to WIFI wasn't successful. Error was $result"
        }
    }
    function Connect-WinREWiFiByXMLProfile {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [ValidateScript( {
                if (Test-Path -Path $_) {
                    $true
                } else {
                    throw "$_ doesn't exists"
                }
                if ($_ -notmatch "\.xml$") {
                    throw "$_ isn't xml file"
                }
                if (!(([xml](Get-Content $_ -Raw)).WLANProfile.Name) -or (([xml](Get-Content $_ -Raw)).WLANProfile.MSM.security.sharedKey.protected) -ne "false") {
                    throw "$_ isn't valid Wi-Fi XML profile (is the password correctly in plaintext?). Use command like this, to create it: netsh wlan export profile name=`"MyWifiSSID`" key=clear folder=C:\Wifi"
                }
            })]
            [string] $wifiProfile
        )
        
        $SSID = ([xml](Get-Content $wifiProfile)).WLANProfile.Name
        Write-Host -ForegroundColor Cyan "$((Get-Date).ToString('yyyy-MM-dd-HHmmss')) Connecting to $SSID"

        # just for sure
        $null = Netsh WLAN delete profile "$SSID"

        # import wifi profile
        $null = Netsh WLAN add profile filename="$wifiProfile"

        # connect to network
        $result = Netsh WLAN connect name="$SSID"
        if ($result -ne "Connection request was completed successfully.") {
            throw "Connection to WIFI wasn't successful. Error was $result"
        }
    }
    function Get-WinREWiFi {
        [CmdletBinding()]
        param (
            [Parameter(ValueFromPipeline = $true)]
            $SSID
        )
        $response = netsh wlan show networks mode=bssid
        $wLANs = $response | Where-Object { $_ -match "^SSID" } | ForEach-Object {
            $report = "" | Select-Object SSID, Index, NetworkType, Authentication, Encryption, Signal
            $i = $response.IndexOf($_)
            $report.SSID = $_ -replace "^SSID\s\d+\s:\s", ""
            $report.Index = $i
            $report.NetworkType = $response[$i + 1].Split(":")[1].Trim()
            $report.Authentication = $response[$i + 2].Split(":")[1].Trim()
            $report.Encryption = $response[$i + 3].Split(":")[1].Trim()
            $report.Signal = $response[$i + 5].Split(":")[1].Trim()
            $report
        }
        if ($SSID) {
            $wLANs | Where-Object { $_.SSID -eq $SSID }
        } else {
            $wLANs
        }
    }
    function Set-WinREWiFi() {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true, HelpMessage = "Please add Wireless network name")]
            [System.String]
            $WLanName,
            
            [System.String]
            $Passwd,
            
            [Parameter(Mandatory = $false, HelpMessage = "This switch will generate a WPA profile instead of WPA2")]
            [System.Management.Automation.SwitchParameter]
            $WPA = $false
        )

        if ($Passwd) {
            # escape XML special characters
            $Passwd = [System.Security.SecurityElement]::Escape($Passwd)
        }

        if ($WPA -eq $false) {
            $WpaState = "WPA2PSK"
            $EasState = "AES"
        } else {
            $WpaState = "WPAPSK"
            $EasState = "AES"
        }

$XMLProfile = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
      <name>$WlanName</name>
      <SSIDConfig>
         <SSID>
              <name>$WLanName</name>
          </SSID>
     </SSIDConfig>
     <connectionType>ESS</connectionType>
     <connectionMode>auto</connectionMode>
     <MSM>
         <security>
             <authEncryption>
                 <authentication>$WpaState</authentication>
                 <encryption>$EasState</encryption>
                 <useOneX>false</useOneX>
             </authEncryption>
             <sharedKey>
                 <keyType>passPhrase</keyType>
                 <protected>false</protected>
				<keyMaterial>$Passwd</keyMaterial>
			</sharedKey>
		</security>
	</MSM>
</WLANProfile>
"@

        if ($Passwd -eq "") {
$XMLProfile = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
	<name>$WLanName</name>
	<SSIDConfig>
		<SSID>
			<name>$WLanName</name>
		</SSID>
	</SSIDConfig>
	<connectionType>ESS</connectionType>
	<connectionMode>manual</connectionMode>
	<MSM>
		<security>
			<authEncryption>
				<authentication>open</authentication>
				<encryption>none</encryption>
				<useOneX>false</useOneX>
			</authEncryption>
		</security>
	</MSM>
	<MacRandomization xmlns="http://www.microsoft.com/networking/WLAN/profile/v3">
		<enableRandomization>false</enableRandomization>
	</MacRandomization>
</WLANProfile>
"@
        }

        $WLanName = $WLanName -replace "\s+"
        $WlanConfig = "$env:TEMP\$WLanName.xml"
        $XMLProfile | Set-Content $WlanConfig
        $result = Netsh WLAN add profile filename=$WlanConfig
        Remove-Item $WlanConfig -ErrorAction SilentlyContinue
        if ($result -notmatch "is added on interface") {
            throw "There was en error when setting up WIFI $WLanName connection profile. Error was $result"
        }
    }

    function Start-WinREWiFi {
        [CmdletBinding()]
        param (
            [string] $wifiProfile
        )
        #=================================================
        #	Block
        #=================================================
        #Block-WinOS
        Block-PowerShellVersionLt5
        #=================================================
        #	Header
        #=================================================
        Write-Host -ForegroundColor DarkGray "========================================================================="
        Write-Host -ForegroundColor Cyan "$((Get-Date).ToString('yyyy-MM-dd-HHmmss')) $($MyInvocation.MyCommand.Name) " -NoNewline
        Write-Host -ForegroundColor Green 'OK'
        #=================================================
        #	Test Internet Connection
        #=================================================
        Write-Host -ForegroundColor Cyan "$((Get-Date).ToString('yyyy-MM-dd-HHmmss')) Test-WebConnection google.com " -NoNewline

        if (Test-WebConnection -Uri 'google.com') {
            Write-Host -ForegroundColor Green 'OK'
            Write-Host -ForegroundColor DarkGray "You are already connected to the Internet"
            Write-Host -ForegroundColor DarkGray "Start-WinREWiFi will not continue"
            $StartWinREWiFi = $false
        }
        else {
            Write-Host -ForegroundColor Red 'FAIL'
            $StartWinREWiFi = $true
        }
        #=================================================
        #   Test WinRE
        #=================================================
        if ($StartWinREWiFi) {
            Write-Host -ForegroundColor Cyan "$((Get-Date).ToString('yyyy-MM-dd-HHmmss')) Testing required WinRE content " -NoNewline

            if (!(Test-Path "$ENV:SystemRoot\System32\dmcmnutils.dll")) {
                #Write-Warning "Missing required $ENV:SystemRoot\System32\dmcmnutils.dll"
                $StartWinREWiFi = $false
            }
            if (!(Test-Path "$ENV:SystemRoot\System32\mdmpostprocessevaluator.dll")) {
                #Write-Warning "Missing required $ENV:SystemRoot\System32\mdmpostprocessevaluator.dll"
                $StartWinREWiFi = $false
            }
            if (!(Test-Path "$ENV:SystemRoot\System32\mdmregistration.dll")) {
                #Write-Warning "Missing required $ENV:SystemRoot\System32\mdmregistration.dll"
                $StartWinREWiFi = $false
            }
            if (!(Test-Path "$ENV:SystemRoot\System32\raschap.dll")) {
                #Write-Warning "Missing required $ENV:SystemRoot\System32\raschap.dll"
                $StartWinREWiFi = $false
            }
            if (!(Test-Path "$ENV:SystemRoot\System32\raschapext.dll")) {
                #Write-Warning "Missing required $ENV:SystemRoot\System32\raschapext.dll"
                $StartWinREWiFi = $false
            }
            if (!(Test-Path "$ENV:SystemRoot\System32\rastls.dll")) {
                #Write-Warning "Missing required $ENV:SystemRoot\System32\rastls.dll"
                $StartWinREWiFi = $false
            }
            if (!(Test-Path "$ENV:SystemRoot\System32\rastlsext.dll")) {
                #Write-Warning "Missing required $ENV:SystemRoot\System32\rastlsext.dll"
                $StartWinREWiFi = $false
            }
            if ($StartWinREWiFi) {
                Write-Host -ForegroundColor Green 'OK'
            }
            else {
                Write-Host -ForegroundColor Red 'FAIL'
            }
        }
        #=================================================
        #	WlanSvc
        #=================================================
        if ($StartWinREWiFi) {
            Write-Host -ForegroundColor Cyan "$((Get-Date).ToString('yyyy-MM-dd-HHmmss')) Starting WlanSvc Service" -NoNewline
            if (Get-Service -Name WlanSvc) {
                if ((Get-Service -Name WlanSvc).Status -ne 'Running') {
                    Get-Service -Name WlanSvc | Start-Service
                    Start-Sleep -Seconds 10
        
                }
            }
            Write-Host -ForegroundColor Green 'OK'
        }
        #=================================================
        #	Test Wi-Fi Adapter
        #=================================================
        if ($StartWinREWiFi) {
            Write-Host -ForegroundColor Cyan "$((Get-Date).ToString('yyyy-MM-dd-HHmmss')) Testing Wi-Fi Network Adapter " -NoNewline
            #$WirelessNetworkAdapter = Get-CimInstance -ClassName CIM_NetworkAdapter | Where-Object {$_.NetConnectionID -eq 'Wi-Fi'}
            $WirelessNetworkAdapter = Get-WmiObject -ClassName Win32_NetworkAdapter | Where-Object {$_.NetConnectionID -eq 'Wi-Fi'}
            #$WirelessNetworkAdapter = Get-SmbClientNetworkInterface | Where-Object {$_.FriendlyName -eq 'Wi-Fi'}
            if ($WirelessNetworkAdapter) {
                $StartWinREWiFi = $true
                Write-Host -ForegroundColor Green 'OK'
                Write-Host -ForegroundColor Gray "  Name: $($WirelessNetworkAdapter.Name)"
                Write-Host -ForegroundColor Gray "  Description: $($WirelessNetworkAdapter.Description)"
                #Write-Host -ForegroundColor Gray "  Speed: $($WirelessNetworkAdapter.Speed)"
                Write-Host -ForegroundColor Gray "  AdapterType: $($WirelessNetworkAdapter.AdapterType)"
                #Write-Host -ForegroundColor Gray "  Installed: $($WirelessNetworkAdapter.Installed)"
                #Write-Host -ForegroundColor Gray "  InterfaceIndex: $($WirelessNetworkAdapter.InterfaceIndex)"
                Write-Host -ForegroundColor Gray "  MACAddress: $($WirelessNetworkAdapter.MACAddress)"
                #Write-Host -ForegroundColor Gray "  NetEnabled: $($WirelessNetworkAdapter.NetEnabled)"
                #Write-Host -ForegroundColor Gray "  PhysicalAdapter: $($WirelessNetworkAdapter.PhysicalAdapter)"
                Write-Host -ForegroundColor Gray "  PNPDeviceID: $($WirelessNetworkAdapter.PNPDeviceID)"
            }
            else {
                $PnPEntity = Get-WmiObject -ClassName Win32_PnPEntity | Where-Object {$_.Status -eq 'Error'} |  Where-Object {$_.Name -match 'Net'}

                Write-Host -ForegroundColor Red 'FAIL'
                Write-Warning "Could not find an installed Wi-Fi Network Adapter"
                if ($PnPEntity) {
                    Write-Warning "Drivers may need to be added to WinPE for the following hardware"
                    foreach ($Item in $PnPEntity) {
                        Write-Warning "$($Item.Name): $($Item.DeviceID)"
                    }
                    Start-Sleep -Seconds 10
                }
                else {
                    Write-Warning "Drivers may need to be added to WinPE"
                }
                $StartWinREWiFi = $false
            }
        }
        #=================================================
        #	Test Wi-Fi Connection
        #=================================================
        if ($StartWinREWiFi) {
            Write-Host -ForegroundColor Cyan "$((Get-Date).ToString('yyyy-MM-dd-HHmmss')) Testing Wi-Fi Network Connection " -NoNewline
            if ($WirelessNetworkAdapter.NetEnabled -eq $true) {
                Write-Host -ForegroundColor Green ''
                Write-Warning "Wireless is already connected ... Disconnecting"
                (Get-WmiObject -ClassName Win32_NetworkAdapter | Where-Object {$_.NetConnectionID -eq 'Wi-Fi'}).disable() | Out-Null
                Start-Sleep -Seconds 5
                (Get-WmiObject -ClassName Win32_NetworkAdapter | Where-Object {$_.NetConnectionID -eq 'Wi-Fi'}).enable() | Out-Null
                Start-Sleep -Seconds 5
                $StartWinREWiFi = $true
            }
            else {
                Write-Host -ForegroundColor Green 'OK'
            }
        }
        #=================================================
        #   Connect
        #=================================================
        if ($StartWinREWiFi) {
                if ($wifiProfile -and (Test-Path $wifiProfile)) {
                    Write-Host -ForegroundColor Cyan "$((Get-Date).ToString('yyyy-MM-dd-HHmmss')) Starting unattended Wi-Fi connection " -NoNewline
                } else {
                    Write-Host -ForegroundColor Cyan "$((Get-Date).ToString('yyyy-MM-dd-HHmmss')) Starting Wi-Fi Network Menu " -NoNewline
                }
                Write-Host -ForegroundColor Green 'OK'
                Write-Host -ForegroundColor DarkGray "========================================================================="

            while (((Get-CimInstance -ClassName Win32_NetworkAdapter | Where-Object {$_.NetConnectionID -eq 'Wi-Fi'}).NetEnabled) -eq $false) {
                Start-Sleep -Seconds 3

                $StartWinREWiFi = 0
                # make checks on start of evert cycle because in case of failure, profile will be deleted
                if ($wifiProfile -and (Test-Path $wifiProfile)) { ++$StartWinREWiFi }
        
                if ($StartWinREWiFi) {
                    # use saved wi-fi profile to make the unattended connection
                    try {
                        Write-Host -ForegroundColor Cyan "$((Get-Date).ToString('yyyy-MM-dd-HHmmss')) Establishing a connection using $wifiProfile"
                        Connect-WinREWiFiByXMLProfile $wifiProfile -ErrorAction Stop
                    } catch {
                        Write-Warning $_
                        # to avoid infinite loop of tries
                        Write-Host -ForegroundColor Cyan "$((Get-Date).ToString('yyyy-MM-dd-HHmmss')) Removing invalid Wi-Fi profile '$wifiProfile'"
                        Remove-Item $wifiProfile -Force
                        continue
                    }
                } else {
                    # show list of available SSID to make interactive connection
                    $SSIDList = Get-WinREWiFi
                    if ($SSIDList) {
                        #show list of available SSID
                        $SSIDList | Sort-Object Signal -Descending | Select-Object Signal, Index, SSID, Authentication, Encryption, NetworkType | Format-Table
            
                        $SSIDListIndex = $SSIDList.index
                        $SSIDIndex = ""
                        while ($SSIDIndex -notin $SSIDListIndex) {
                            $SSIDIndex = Read-Host "Select the Index of Wi-Fi Network to connect or CTRL+C to quit"
                        }
            
                        $SSID = $SSIDList | Where-Object { $_.index -eq $SSIDIndex } | Select-Object -exp SSID
            
                        # connect to selected Wi-Fi
                        Write-Host -ForegroundColor DarkGray "========================================================================="
                        Write-Host -ForegroundColor Cyan "$((Get-Date).ToString('yyyy-MM-dd-HHmmss')) Establishing a connection to SSID $SSID"
                        try {
                            Connect-WinREWiFi $SSID -ErrorAction Stop
                        } catch {
                            Write-Warning $_
                            continue
                        }
                    } else {
                        Write-Warning "No Wi-Fi network found. Move closer to AP or use ethernet cable instead."
                    }
                }

                if ($StartWinREWiFi) {
                    $text = "to Wi-Fi using $wifiProfile"
                } else {
                    $text = "to SSID $SSID"
                }
                Write-Host -ForegroundColor Cyan "$((Get-Date).ToString('yyyy-MM-dd-HHmmss')) Waiting for a connection $text"
                Start-Sleep -Seconds 15
            
                $i = 30
                while ((((Get-CimInstance -ClassName Win32_NetworkAdapter | Where-Object {$_.NetConnectionID -eq 'Wi-Fi'}).NetEnabled) -eq $false) -and $i -gt 0) {
                    --$i
                    Write-Host -ForegroundColor DarkGray "Waiting for Wi-Fi Connection ($i)"
                    Start-Sleep -Seconds 1
                }

                # connection to network can take a while
                #$i = 30
                #while (!(Test-WebConnection -Uri 'github.com') -and $i -gt 0) { --$i; "Waiting for Internet connection ($i)" ; Start-Sleep -Seconds 1 }
            }
            Get-SmbClientNetworkInterface | Where-Object {$_.FriendlyName -eq 'Wi-Fi'} | Format-List
        }
        Start-Sleep -Seconds 5
    }
}