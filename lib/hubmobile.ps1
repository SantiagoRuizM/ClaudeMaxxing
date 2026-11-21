# Celular in the ClaudeMaxxing window: the switch for the phone app's server (lib\mobile.ps1), the QR to pair a
# phone and the paired phones, each with Revocar.

$script:HubMobileQr = @{ Text = ''; Modules = $null }

# The QR of $Text in $Rect: dark modules on white with a 4-module quiet zone, as large as whole pixels allow.
function Draw-HubQr($G, [System.Drawing.Rectangle]$Rect, [string]$Text) {
    Initialize-MobileNative
    if ($script:HubMobileQr.Text -ne $Text) { $script:HubMobileQr = @{ Text = $Text; Modules = [ClaudeTray.QrCode]::Encode($Text, 1) } }
    $m = $script:HubMobileQr.Modules
    $n = $m.GetLength(0)
    $cell = [Math]::Max(1, [int][Math]::Floor([Math]::Min($Rect.Width, $Rect.Height) / ($n + 8)))
    $side = $cell * ($n + 8)
    $ox = $Rect.X + [int](($Rect.Width - $side) / 2)
    $oy = $Rect.Y + [int](($Rect.Height - $side) / 2)
    $G.FillRectangle([System.Drawing.Brushes]::White, $ox, $oy, $side, $side)
    $smoothing = $G.SmoothingMode
    $G.SmoothingMode = 'None'
    for ($y = 0; $y -lt $n; $y++) {
        for ($x = 0; $x -lt $n; $x++) {
            if ($m[$y, $x]) { $G.FillRectangle([System.Drawing.Brushes]::Black, $ox + ($x + 4) * $cell, $oy + ($y + 4) * $cell, $cell, $cell) }
        }
    }
    $G.SmoothingMode = $smoothing
}

function Start-HubMobileFirewall {
    $settings = Get-MobileSettings
    if (-not $script:Mobile.FirewallProcess) { $script:Mobile.FirewallProcess = Start-Elevated (Get-MobileFirewallScript $settings.Port) }
    Set-HubMessage (Tx 'Acepta el aviso de administrador para permitir la app en el firewall.')
}

function Draw-HubMobileSection($G, $Map, $Hover, [int]$X0, [int]$Inner) {
    $P = $script:Palette
    $F = $script:Fonts
    $m = $script:Mobile
    $settings = Get-MobileSettings
    if ($script:Hub.Preview) {
        # The preview (tray.ps1 -RenderHubTo x.png -HubSection mobile): on, a QR showing and one paired phone.
        $settings = [pscustomobject]@{ Enabled = $true; Port = $MobileDefaultPort; Thumbprint = '' }
        $m = @{ Running = $true; Error = ''; Firewall = $true; Pairing = @{ Code = '0123456789abcdef'; Until = (Get-Date).AddSeconds(272) } }
        $hosts = @('192.168.1.23', '100.101.102.103')
        $uri = Format-MobilePairUri $hosts $settings.Port ('ab' * 32) $m.Pairing.Code 'DESKTOP-ANA'
        $devices = @([pscustomobject]@{ id = 'a1b2c3d4e5f6'; name = 'Pixel 8'; lastSeen = (Get-Date).AddMinutes(-3).ToString('o'); address = '192.168.1.40' })
    } else {
        if ($settings.Enabled) { Update-MobileFirewallState }
        $hosts = if ($m.Running) { @(Get-MobileHosts) } else { @() }
        $uri = if ($m.Pairing) { Get-MobilePairUri } else { '' }
        $devices = @(Get-MobileDevices)
    }

    # the switch and what the server is doing
    $card = New-Rect $X0 (Px 72) $Inner (Px 92)
    Draw-HubCard $G $card
    $tx = $card.X + (Px 16)
    $tw = $card.Width - (Px 84)
    Draw-HubSwitch $G $Map 'mobile-switch' ($card.Right - (Px 52)) ($card.Y + (Px 14)) $settings.Enabled ([scriptblock]::Create("Set-MobileEnabled `$$(-not $settings.Enabled)"))
    Draw-Text $G (L 'App del celular') $F.BodyStrong $P.Text $tx ($card.Y + (Px 12)) $tw (Px 22)
    $status, $color = if (-not $settings.Enabled) { (Tx 'Apagada. Enci\u00e9ndela para ver el panel y las sesiones de este PC en el celular, en tu wifi o desde fuera con Tailscale.'), $P.Muted }
        elseif ($m.Error) { ((Tx 'No se pudo abrir el puerto {0}: {1}') -f $settings.Port, $m.Error), $P.Error }
        elseif (-not $m.Firewall) { (Tx 'Falta permitirla en el firewall de Windows: sin eso el celular no llega a este PC.'), $P.Warn }
        elseif (-not $hosts.Count) { (Tx 'Encendida, pero este PC no est\u00e1 en una red privada: marca tu wifi como privada en Windows o usa Tailscale.'), $P.Warn }
        else { ((Tx '\u2713 Encendida en {0}, puerto {1}.') -f ($hosts -join ', '), $settings.Port), $P.Ok }
    Draw-Wrapped $G $status $F.Small $color $tx ($card.Y + (Px 38)) ($card.Width - (Px 32)) (Px 40)
    if ($settings.Enabled -and -not $m.Error -and -not $m.Firewall) {
        $label = L 'Permitir'
        $bw = Get-PillWidth $label
        Draw-PillButton $G $Map $Hover 'mobile-firewall' (New-Rect ($card.Right - (Px 16) - $bw) ($card.Y + (Px 12)) $bw (Px 26)) $label { Start-HubMobileFirewall } -Accent
    }

    $y = $card.Bottom + (Px 14)
    if ($m.Running) {
        $pairing = $m.Pairing
        $box = New-Rect $X0 $y $Inner $(if ($pairing) { Px 236 } else { Px 76 })
        Draw-HubCard $G $box
        if ($pairing) {
            $qr = New-Rect ($box.X + (Px 12)) ($box.Y + (Px 12)) (Px 212) (Px 212)
            if ($uri) { Draw-HubQr $G $qr $uri }
            $px = $qr.Right + (Px 20)
            $pw = $box.Right - $px - (Px 16)
            Draw-Text $G (Tx 'Escan\u00e9alo con la app ClaudeMaxxing') $F.BodyStrong $P.Text $px ($box.Y + (Px 20)) $pw (Px 22)
            Draw-Wrapped $G (Tx 'En la app: Agregar PC \u203a Escanear. El celular tiene que estar en la misma wifi que este PC, o los dos en Tailscale.') $F.Small $P.Muted $px ($box.Y + (Px 48)) $pw (Px 54)
            $left = [Math]::Max(0, [int]($pairing.Until - (Get-Date)).TotalSeconds)
            Draw-Text $G ((Tx 'El c\u00f3digo caduca en {0}:{1:00}') -f [int][Math]::Floor($left / 60), ($left % 60)) $F.Small $P.Faint $px ($box.Y + (Px 110)) $pw (Px 18)
            $label = L 'Cancelar'
            $bw = Get-PillWidth $label
            Draw-PillButton $G $Map $Hover 'mobile-pair-stop' (New-Rect $px ($box.Bottom - (Px 42)) $bw (Px 26)) $label { Stop-MobilePairing; Update-HubNow }
        } else {
            Draw-Text $G (L 'Emparejar un celular') $F.BodyStrong $P.Text ($box.X + (Px 16)) ($box.Y + (Px 12)) ($box.Width - (Px 200)) (Px 22)
            Draw-Text $G (Tx 'Instala la app (descarga del APK en GitHub) y escanea el c\u00f3digo que aparece aqu\u00ed.') $F.Small $P.Muted ($box.X + (Px 16)) ($box.Y + (Px 38)) ($box.Width - (Px 200)) (Px 30)
            $label = L 'Mostrar el QR'
            $bw = Get-PillWidth $label
            Draw-PillButton $G $Map $Hover 'mobile-pair' (New-Rect ($box.Right - (Px 16) - $bw) ($box.Y + (Px 12)) $bw (Px 26)) $label { Start-MobilePairing; Update-HubNow } -Accent
            $label = L 'Descargar la app'
            $dw = Get-PillWidth $label
            Draw-PillButton $G $Map $Hover 'mobile-download' (New-Rect ($box.Right - (Px 16) - $dw) ($box.Y + (Px 42)) $dw (Px 26)) $label { Start-Process $MobileReleasesUrl }
        }
        $y = $box.Bottom + (Px 14)
    }

    # the paired phones
    Draw-HubCaption $G 'CELULARES EMPAREJADOS' $X0 $y $Inner $(if ($devices.Count) { '' } else { Tx 'Ninguno todav\u00eda' })
    $y += Px 22
    if ($devices.Count) {
        $list = New-Rect $X0 $y $Inner ($devices.Count * (Px 46) + (Px 8))
        Draw-HubCard $G $list
        $ry = $list.Y + (Px 4)
        foreach ($d in $devices) {
            $row = New-Rect ($list.X + (Px 6)) $ry ($list.Width - (Px 12)) (Px 42)
            Draw-Text $G ([string]$d.name) $F.Body $P.Text ($row.X + (Px 10)) ($row.Y + (Px 3)) ($row.Width - (Px 120)) (Px 20)
            $seen = (L 'Visto ') + (Format-HubAgo ([string]$d.lastSeen)) + $(if ($d.address) { (Tx ' \u00b7 ') + [string]$d.address } else { '' })
            Draw-Text $G $seen $F.Small $P.Muted ($row.X + (Px 10)) ($row.Y + (Px 21)) ($row.Width - (Px 120)) (Px 18)
            $label = L 'Revocar'
            $bw = Get-PillWidth $label
            Draw-PillButton $G $Map $Hover "mobile-revoke-$($d.id)" (New-Rect ($row.Right - $bw - (Px 6)) ($row.Y + (Px 8)) $bw (Px 26)) $label ([scriptblock]::Create("Remove-MobileDevice '$($d.id)'; Update-HubNow"))
            $ry += Px 46
        }
        $y = $list.Bottom
    }

    $y += Px 14
    Draw-HubCaption $G (Tx 'C\u00d3MO FUNCIONA') $X0 $y $Inner ''
    Draw-Wrapped $G (Tx 'El celular ve el panel de ClaudeMaxxing y las sesiones abiertas (desliza para pasar de una a otra) y les escribe. Habla solo con este PC, cifrado y con el certificado que lleva el QR: sin servidores en medio.') $F.Small $P.Muted $X0 ($y + (Px 22)) $Inner (Px 54)
    Draw-Wrapped $G (Tx 'Lo que escribes llega a la sesi\u00f3n como un mensaje de otra sesi\u00f3n: Claude lo sigue, pero los permisos se aprueban en el PC.') $F.Small $P.Faint $X0 ($y + (Px 80)) $Inner (Px 36)
}
