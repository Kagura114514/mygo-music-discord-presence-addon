# Experimental Windows Media Session -> Discord Rich Presence bridge.
# This is launched by the MyGo plugin after its first played({id}) callback.
$ErrorActionPreference = 'Stop'
$clientId = [string]$args[0]
$logPath = Join-Path $env:LOCALAPPDATA 'MyGoMusic\DiscordPresence-addon.log'
$logDir = Split-Path -Parent $logPath
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
function Write-Log([string]$message) {
  Add-Content -LiteralPath $logPath -Value "$(Get-Date -Format o) $message" -Encoding UTF8
}
Write-Log "Helper started; client ID length=$($clientId.Length)."
if ($clientId -notmatch '^\d{17,20}$') { Write-Log 'Invalid Discord Application ID.'; exit 2 }

Add-Type -AssemblyName System.Runtime.WindowsRuntime
$managerType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows, ContentType=WindowsRuntime]
$propertiesType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows, ContentType=WindowsRuntime]
$script:coverCache = @{}

function Await-Operation($operation, [Type]$resultType) {
  $method = [System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object {
      $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and
      $_.GetParameters().Count -eq 1 -and
      $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    } |
    Select-Object -First 1
  if (-not $method) { throw 'Windows Runtime AsTask helper not found' }
  $task = $method.MakeGenericMethod(@($resultType)).Invoke($null, @($operation))
  return $task.GetAwaiter().GetResult()
}
function Read-Exact($stream, [int]$count) {
  $bytes = [byte[]]::new($count)
  $offset = 0
  while ($offset -lt $count) {
    $readTask = $stream.ReadAsync($bytes, $offset, $count - $offset)
    if (-not $readTask.Wait(1500)) { throw 'Discord IPC response timed out' }
    $read = $readTask.Result
    if ($read -le 0) { throw 'Discord IPC closed' }
    $offset += $read
  }
  return ,$bytes
}
function Read-Frame($stream) {
  $head = Read-Exact $stream 8
  $op = [BitConverter]::ToInt32($head, 0)
  $length = [BitConverter]::ToInt32($head, 4)
  if ($length -lt 0 -or $length -gt 1048576) { throw 'Invalid Discord RPC frame' }
  $payload = [Text.Encoding]::UTF8.GetString((Read-Exact $stream $length))
  return @{ Opcode = $op; Payload = ($payload | ConvertFrom-Json) }
}
function Send-Frame($stream, [int]$opcode, $value) {
  $json = ConvertTo-Json -InputObject $value -Depth 12 -Compress
  $body = [Text.Encoding]::UTF8.GetBytes($json)
  $header = [byte[]]::new(8)
  [BitConverter]::GetBytes([int]$opcode).CopyTo($header, 0)
  [BitConverter]::GetBytes([int]$body.Length).CopyTo($header, 4)
  $stream.Write($header, 0, $header.Length)
  $stream.Write($body, 0, $body.Length)
  $stream.Flush()
}
function Connect-Discord {
  $visible = @(Get-ChildItem -LiteralPath '\\.\pipe\' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'discord-ipc-*' } | ForEach-Object { $_.Name })
  $processCount = @(Get-Process -Name Discord -ErrorAction SilentlyContinue).Count
  $summary = "Discord.exe processes visible=$processCount; IPC pipes visible=$($visible -join ',')"
  if ($summary -ne $script:lastPipeSummary) {
    Write-Log $summary
    $script:lastPipeSummary = $summary
  }
  if (-not $visible.Count) { return $null }

  $lastError = $null
  foreach ($pipeName in $visible) {
    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
    try {
      $pipe.Connect(1200)
      Send-Frame $pipe 0 @{ v = 1; client_id = $clientId }
      $ready = Read-Frame $pipe
      Write-Log "IPC handshake response: opcode=$($ready.Opcode), event=$($ready.Payload.evt), message=$($ready.Payload.data.message)"
      return $pipe
    } catch {
      $lastError = $_.Exception.Message
      $pipe.Dispose()
    }
  }
  if ($lastError -ne $script:lastPipeError) {
    Write-Log "Discord IPC pipes were visible but connection failed: $lastError"
    $script:lastPipeError = $lastError
  }
  return $null
}
function Send-Activity($pipe, $activity) {
  Send-Frame $pipe 1 @{ cmd = 'SET_ACTIVITY'; args = @{ pid = $PID; activity = $activity }; nonce = [guid]::NewGuid().ToString() }
  # Read Discord's ACK so the IPC buffer stays clear. Answer ping frames if any.
  $reply = Read-Frame $pipe
  while ($reply.Opcode -eq 3) {
    Send-Frame $pipe 4 $reply.Payload
    $reply = Read-Frame $pipe
  }
  Write-Log "RPC response: opcode=$($reply.Opcode), event=$($reply.Payload.evt), command=$($reply.Payload.cmd), message=$($reply.Payload.data.message)"
  if ($reply.Payload.evt -eq 'ERROR') { throw "Discord RPC error $($reply.Payload.data.code): $($reply.Payload.data.message)" }
}
function Send-ActivityWithFallback($pipe, $activity) {
  try {
    Send-Activity $pipe $activity
  } catch {
    if ($null -eq $activity -or $null -eq $activity.assets -or -not $activity.assets.ContainsKey('small_image')) { throw }
    Write-Log "Discord rejected the activity with its small icon; retrying without small_image: $($_.Exception.Message)"
    $activity.assets.Remove('small_image')
    $activity.assets.Remove('small_text')
    Send-Activity $pipe $activity
  }
}
function Normalize-TrackText([string]$text) {
  if (-not $text) { return '' }
  return [regex]::Replace($text.Normalize([Text.NormalizationForm]::FormKC).ToLowerInvariant(), '[^\p{L}\p{N}]', '')
}
function Search-NeteaseCover($state, [string]$searchText, [bool]$allowArtistFallback) {
  try {
    $query = [Uri]::EscapeDataString($searchText)
    $uri = "https://music.163.com/api/cloudsearch/pc?s=$query&type=1&limit=10&offset=0"
    $result = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 6 -Headers @{
      'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36'
      'Referer' = 'https://music.163.com/'
    }
    $wantedTitle = Normalize-TrackText $state.Title
    $wantedArtists = @($state.Artist -split '[,;、/&]' | ForEach-Object { Normalize-TrackText $_ } | Where-Object { $_ })
    $songs = @($result.result.songs)
    Write-Log "NetEase cover search returned $($songs.Count) results."
    foreach ($song in $songs) {
      if ((Normalize-TrackText ([string]$song.name)) -ne $wantedTitle) { continue }
      $artists = if ($song.ar) { @($song.ar) } elseif ($song.artists) { @($song.artists) } else { @() }
      $album = if ($song.al) { $song.al } elseif ($song.album) { $song.album } else { $null }
      $actualArtists = @($artists | ForEach-Object { Normalize-TrackText ([string]$_.name) })
      $artistMatches = -not $wantedArtists.Count -or @($wantedArtists | Where-Object { $wanted = $_; $actualArtists | Where-Object { $_ -eq $wanted } }).Count -gt 0
      $albumMatches = $state.Album -and (Normalize-TrackText ([string]$album.name)) -eq (Normalize-TrackText $state.Album)
      if (-not $artistMatches -and -not $albumMatches -and -not $allowArtistFallback) { continue }
      $candidate = [string]$album.picUrl
      if (-not $candidate) { $candidate = [string]$album.coverImgUrl }
      $candidate = $candidate -replace '^http://', 'https://'
      if ($candidate -match '^https://(?:[a-z0-9-]+\.)*music\.126\.net/') { return $candidate }
    }
  } catch {
    Write-Log "NetEase cover lookup failed: $($_.Exception.Message)"
  }
  return $null
}
function Get-NeteaseCover($state) {
  $cacheKey = "$($state.Title)|$($state.Artist)|$($state.Album)"
  if ($script:coverCache.ContainsKey($cacheKey)) { return $script:coverCache[$cacheKey] }
  $cover = Search-NeteaseCover $state "$($state.Title) $($state.Artist)" $false
  if (-not $cover) { $cover = Search-NeteaseCover $state $state.Title $true }
  if ($script:coverCache.Count -ge 64) { $script:coverCache.Clear() }
  $script:coverCache[$cacheKey] = $cover
  if (-not $cover) { Write-Log "No exact NetEase cover match for: $($state.Title) / $($state.Artist)" }
  return $cover
}
function Get-MyGoState($manager) {
  $found = @()
  foreach ($session in $manager.GetSessions()) {
    $source = [string]$session.SourceAppUserModelId
    $playback = $session.GetPlaybackInfo()
    $found += "$source [$($playback.PlaybackStatus)]"
    if ($source -notmatch '(?i)mygo|egoist') { continue }
    $props = Await-Operation $session.TryGetMediaPropertiesAsync() $propertiesType
    $timeline = $session.GetTimelineProperties()
    if ([string]::IsNullOrWhiteSpace([string]$props.Title)) { continue }
    $matched = "$source | $($props.Title) | $($playback.PlaybackStatus)"
    if ($matched -ne $script:lastMatchedSummary) {
      Write-Log "Matched MyGo session: $matched"
      $script:lastMatchedSummary = $matched
    }
    return @{
      Title = [string]$props.Title
      Artist = [string]$props.Artist
      Album = [string]$props.AlbumTitle
      Status = [string]$playback.PlaybackStatus
      Position = [double]$timeline.Position.TotalSeconds
      Duration = [double]$timeline.EndTime.TotalSeconds
    }
  }
  $summary = if ($found.Count) { $found -join '; ' } else { '(no media sessions)' }
  if ($summary -ne $script:lastSessionSummary) {
    Write-Log "Windows media sessions: $summary"
    $script:lastSessionSummary = $summary
  }
  return $null
}

$managerOperation = $managerType.GetMethod('RequestAsync').Invoke($null, @())
$manager = Await-Operation $managerOperation $managerType
Write-Log 'Windows media session manager ready.'
$pipe = $null
$lastKey = ''
$missingSince = $null
while ($true) {
  try {
    $state = Get-MyGoState $manager
    if ($null -eq $state) {
      if ($null -eq $missingSince) { $missingSince = [DateTime]::UtcNow }
      if ($pipe -and $lastKey -ne '__cleared') { Send-Activity $pipe $null; $lastKey = '__cleared' }
      if (([DateTime]::UtcNow - $missingSince).TotalSeconds -gt 30) { break }
    } else {
      $missingSince = $null
      # Discord limits activity updates; the timestamp itself advances in Discord,
      # so position changes do not need an RPC update every second.
      $key = "$($state.Title)|$($state.Artist)|$($state.Album)|$($state.Status)"
      if ($key -ne $lastKey) {
        if (-not $pipe -or -not $pipe.IsConnected) { if ($pipe) { $pipe.Dispose() }; $pipe = Connect-Discord }
        if ($pipe) {
          $cover = Get-NeteaseCover $state
          $assets = @{ small_image = 'https://raw.githubusercontent.com/egoist/mygo-music/main/resources/icon.png'; small_text = 'MyGo Music' }
          if ($cover) {
            $assets.large_image = $cover
            if ($state.Album) { $assets.large_text = $state.Album }
          }
          if ($state.Status -eq 'Playing') {
            $activity = @{
              type = 2
              details = $state.Title
              state = if ($state.Artist) { $state.Artist } else { $state.Album }
              assets = $assets
            }
            if ($state.Position -ge 0) {
              $activity.timestamps = @{ start = [long]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $state.Position) }
            }
            Send-ActivityWithFallback $pipe $activity
          } elseif ($state.Status -eq 'Paused') {
            $activity = @{ type = 2; details = $state.Title; state = if ($state.Artist) { $state.Artist } else { $state.Album }; assets = $assets }
            Send-ActivityWithFallback $pipe $activity
          } else {
            Send-Activity $pipe $null
          }
          $lastKey = $key
        } else {
          Write-Log 'No Discord IPC pipe accepted a connection from the helper.'
        }
      }
    }
  } catch {
    Write-Log "Error: $($_.Exception.Message)"
    if ($pipe) { $pipe.Dispose(); $pipe = $null }
    $lastKey = ''
  }
  Start-Sleep -Milliseconds 1500
}
if ($pipe) { $pipe.Dispose() }




