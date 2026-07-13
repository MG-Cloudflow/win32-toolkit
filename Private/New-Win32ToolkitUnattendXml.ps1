function New-Win32ToolkitUnattendXml {
    <#
    .SYNOPSIS
        Builds the unattend.xml that makes an offline-applied Windows 11 image first-boot fully
        unattended (local admin + autologon + full OOBE skip + PS-Direct readiness).
    .DESCRIPTION
        Data-driven generator for the golden-image answer file. Machine settings go in the `specialize`
        pass; account / OOBE-skip / AutoLogon go in `oobeSystem` (windowsPE does NOT run for an
        offline-applied VHDX). The Windows 11 mandatory-MSA/network gate is skipped by the documented
        combination HideOnlineAccountScreens + a pre-created LocalAccount + AutoLogon (NOT the unreliable
        SkipMachineOOBE). All caller-supplied values are XML-encoded (ConvertTo-XmlEncoded), and the
        account name is reduced to its SAM part (a leading '.\' or 'COMPUTER\' is stripped).

        SECURITY: PlainText=true stores the password in cleartext inside the VHDX and it persists under
        %WINDIR%\Panther — the built base VHDX must be treated as a secret. See
        knowledge-base/designs/hyperv-golden-image-build.md (§2.3).
    .PARAMETER AdminCredential
        The local-admin account to create + auto-logon (the same credential PowerShell Direct will use).
    .PARAMETER ComputerName
        Guest computer name (specialize pass). Default 'GOLDENBASE'.
    .PARAMETER Locale
        BCP-47 locale for InputLocale/SystemLocale/UILanguage/UserLocale. Default 'en-US'.
    .PARAMETER LogonCount
        AutoLogon count. Windows adds 1 when >0, so a single auto-logon isn't achievable — the checkpoint
        freezes the post-first-boot state anyway. Default 999.
    .OUTPUTS
        [string] the unattend.xml document.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscredential]$AdminCredential,

        [ValidateNotNullOrEmpty()]
        [string]$ComputerName = 'GOLDENBASE',

        [ValidateNotNullOrEmpty()]
        [string]$Locale = 'en-US',

        [ValidateRange(1, 999)]
        [int]$LogonCount = 999
    )

    # SAM account name only — strip a leading '.\' or 'DOMAIN\' so AutoLogon/LocalAccount get 'w32admin'.
    $sam     = $AdminCredential.UserName.Split('\')[-1]
    $user    = ConvertTo-XmlEncoded $sam
    $pwPlain = [System.Net.NetworkCredential]::new('', $AdminCredential.Password).Password
    if ([string]::IsNullOrEmpty($pwPlain)) {
        throw 'AdminCredential password must not be empty — a blank password breaks AutoLogon and PowerShell Direct on the guest.'
    }
    $pw      = ConvertTo-XmlEncoded $pwPlain
    $cn      = ConvertTo-XmlEncoded $ComputerName
    $loc     = ConvertTo-XmlEncoded $Locale

    @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>$cn</ComputerName>
      <TimeZone>UTC</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>$loc</InputLocale>
      <SystemLocale>$loc</SystemLocale>
      <UILanguage>$loc</UILanguage>
      <UserLocale>$loc</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>$user</Name>
            <Group>Administrators</Group>
            <DisplayName>$user</DisplayName>
            <Password><Value>$pw</Value><PlainText>true</PlainText></Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Username>$user</Username>
        <Enabled>true</Enabled>
        <LogonCount>$LogonCount</LogonCount>
        <Password><Value>$pw</Value><PlainText>true</PlainText></Password>
      </AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy RemoteSigned -Force"</CommandLine>
          <Description>Prep Windows PowerShell 5.1 for device scripts (also enforced host-side before checkpoint)</Description>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
"@
}
