-- Spotify Backend
local authserver = require('auth')
local Spotify = {}

-- Load INI configuration file from script directory
local scriptDir = ac.getFolder(ac.FolderID.ScriptOrigin)
local settingsPath = scriptDir .. '/settings.ini'

-- Constants
local SPOTIFY_AUTH_URL = 'https://accounts.spotify.com/authorize'
local SPOTIFY_TOKEN_URL = 'https://accounts.spotify.com/api/token'
local SPOTIFY_API_URL = 'https://api.spotify.com/v1'
local AUTH_SERVER = 'http://127.0.0.1:9876'
local REDIRECT_URI = AUTH_SERVER..'/callback'
local SCOPE = 'user-read-currently-playing user-read-playback-state user-modify-playback-state user-library-read user-library-modify'
local MAX_RETRIES = 5

Spotify.retries = 0
Spotify.overrideAuthPort = 9876 -- Default port for auth server, can be overridden in INI
Spotify.authServerRunning = false

-- OAuth Configuration
local oauthConfig = ac.storage{
  clientId = '',
  clientSecret = '',
  refreshToken = '',
  accessToken = '',
  tokenExpiry = 0,
}

Spotify.appSettings = ac.storage{
  showControls = false,
  colorTheme = rgbm(1, 1, 1, 1),
  showOnHover = false,
  enableSharing = true,
  useAlbumColor = false,
}

Spotify.extraSettings = ac.storage{
  albumArtMode = 'square', -- or 'vinyl'
  showSongDetails = true,
  songDetailsFontSize = 16,
  progressBarBackground = true,
  progressBarBackgroundInvert = false,
  progressBarLabel = true,
  showAlbumArt = true,
  useGlobalColors = true,
  colorThemeExtra = rgbm(0, 0, 0, 1),
  colorThemeExtraBg = rgbm(0.1, 0.1, 0.1, 0.8)
}

-- Song history stack for quick-loading previous track metadata
Spotify.songHistory = {}
Spotify.maxHistorySize = 20

-- Playback state
Spotify.playbackState = {
  trackName = 'Nothing playing',
  artistName = '',
  albumName = '',
  albumArtUrl = '',
  isPlaying = false,
  duration = 0,
  progress = 0,
  error = '',
  lastUpdate = 0,
  trackUrl = '',
  trackId = '',
  isLiked = false,
  volume = 0,
  queue = {},
  type = 'track', -- or 'episode'
  dominantColor = rgbm(1, 1, 1, 1),
}

-- Load config from INI file to ac.storage
function Spotify.loadConfigFile()

  -- Load INI from script directory
  local iniConfig = ac.INIConfig.load(settingsPath, ac.INIFormat.Extended)
  
  if not iniConfig then
    ac.log('Spotify: ERROR - settings.ini not found at '..settingsPath)
    return
  end
  
  -- Try to read from settings.ini
  local clientId = iniConfig:get('SPOTIFY', 'CLIENT_ID', '')
  local clientSecret = iniConfig:get('SPOTIFY', 'CLIENT_SECRET', '')
  local overrideAuthPort = iniConfig:get('SPOTIFY', 'OVERRIDE_AUTH_PORT', '')

  if overrideAuthPort ~= '' then
    AUTH_SERVER = 'http://127.0.0.1:'..overrideAuthPort
    Spotify.overrideAuthPort = tonumber(overrideAuthPort)
  end
  REDIRECT_URI = AUTH_SERVER..'/callback'
  
  -- Trim whitespace
  if clientId then
    clientId = clientId:match('^%s*(.-)%s*$') or ''
  else
    clientId = ''
  end
  
  if clientSecret then
    clientSecret = clientSecret:match('^%s*(.-)%s*$') or ''
  else
    clientSecret = ''
  end
  
  oauthConfig.clientId = clientId
  oauthConfig.clientSecret = clientSecret
end

-- Save current config to INI file
function Spotify.saveConfigFile()
  local iniConfig = ac.INIConfig.load(settingsPath, ac.INIFormat.Default)
  
  if not iniConfig then
    ac.log('Spotify: Could not load settings.ini for saving')
    return
  end
  
  iniConfig:setAndSave('SPOTIFY', 'CLIENT_ID', oauthConfig.clientId)
  iniConfig:setAndSave('SPOTIFY', 'CLIENT_SECRET', oauthConfig.clientSecret)
  ac.log('Spotify: Config saved to settings.ini')
end

-- Helper: Encode string to base64 (for Authorization header)
local function base64Encode(str)
  local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  return ((str:gsub('.', function(x)
    local r, b = '', x:byte()
    for i = 8, 1, -1 do r = r..(b % 2 ^ i >= 2 ^ (i - 1) and '1' or '0') end
    return r
  end)..'0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
    if (#x < 6) then return '' end
    local c = 0
    for i = 1, 6 do c = c + (x:sub(i, i) == '1' and 2 ^ (6 - i) or 0) end
    return b:sub(c + 1, c + 1)
  end)..({ '', '==', '=' })[#str % 3 + 1])
end

-- Add URL encoding helper function near the top with other helpers
local function urlEncode(str)
  return str:gsub('([^%w%-_.~])', function(c)
    return string.format('%%%02X', string.byte(c))
  end)
end

-- Parse Song Metadata
local function parseTrackMetadata(json)
  local song = {}

  song.trackName = json.item.name or 'Unknown Track'
  song.duration = json.item.duration_ms or 0
  if json.item.artists and #json.item.artists > 0 then
    local names = {}
    for _, artist in ipairs(json.item.artists) do
      table.insert(names, artist.name)
    end
    song.artistName = table.concat(names, ', ')
  elseif json.currently_playing_type == 'episode' then
    song.artistName = (json.item.show and json.item.show.publisher) or 'Unknown Publisher'
  else
    song.artistName = 'Unknown Artist'
  end
  song.trackUrl = (json.item.external_urls and json.item.external_urls.spotify) or ''
  song.trackId = json.item.id or ''

  if json.item.album then
    song.albumArtUrl = (json.item.album.images and #json.item.album.images > 0 and json.item.album.images[1].url) or ''
    song.albumName = json.item.album.name or ''
  elseif json.item.images and json.currently_playing_type == 'episode' then
    song.albumArtUrl = (json.item.images and #json.item.images > 0 and json.item.images[1].url) or ''
    song.albumName = json.item.show and json.item.show.name or ''
  else
    song.albumArtUrl = ''
    song.albumName = ''
  end

  song.currently_playing_type = json.currently_playing_type or 'track'

  return song
end

-- Save current song metadata to history stack
local function pushCurrentSongToHistory()
  local state = Spotify.playbackState
  -- Only push if there's an actual track playing
  if state.trackName and state.trackName ~= 'Nothing playing' and state.trackName ~= '' then
    local snapshot = {
      trackName = state.trackName,
      artistName = state.artistName,
      albumName = state.albumName,
      albumArtUrl = state.albumArtUrl,
      duration = state.duration,
      trackUrl = state.trackUrl,
      dominantColor = state.dominantColor,
    }
    table.insert(Spotify.songHistory, snapshot)
    -- Trim history if it exceeds max size
    if #Spotify.songHistory > Spotify.maxHistorySize then
      table.remove(Spotify.songHistory, 1)
    end
  end
end

-- Generate auth URL for user to visit
function Spotify.generateAuthUrl()
  if oauthConfig.clientId == '' then
    return nil
  end
  
  local params = {
    'client_id='..oauthConfig.clientId,
    'response_type=code',
    'redirect_uri='..urlEncode(REDIRECT_URI),  -- URL encode the redirect URI
    'scope='..SCOPE:gsub(' ', '%%20'),
    'show_dialog=true'
  }
  
  return SPOTIFY_AUTH_URL..'?'..table.concat(params, '&')
end

-- Start the auth server to listen for Spotify's callback with the authorization code
function Spotify.runAuthServer()
  ac.log('Spotify: Trying to start auth server process on port '..Spotify.overrideAuthPort)
  Spotify.authServerRunning = false

  authserver.StartAuthServer(Spotify.overrideAuthPort, function(authCode)
    if authCode and authCode ~= '' then
      ac.log('Spotify: Received auth code from server: ' .. (authCode:sub(1, 5) .. '...'))
      Spotify.exchangeAuthCode(authCode, function(exchange_err, message)
        if exchange_err then
          ui.toast(ui.Icons.Error, 'Authentication failed: '..message)
        else
          ui.toast(ui.Icons.Success, 'Authentication successful')
          Spotify.getPlaybackState()
        end
      end)
    else
      ac.log('Spotify: Auth server callback received no code')
    end
  end)
end

-- Exchange authorization code for refresh token
function Spotify.exchangeAuthCode(authCode, callback)

  if oauthConfig.clientId == '' or oauthConfig.clientSecret == '' then
    if callback then callback(true, 'Client ID or Secret not configured') end
    return
  end
  
  Spotify.playbackState.error = ''
  
  Spotify._ExchangeAuthCode(authCode, function(err, response)
      if callback then callback(err, response) end
      
      -- Handle failed request
      if err then
        Spotify.playbackState.error = 'Token exchange failed: '..tostring(err)
        if callback then callback(true, 'Token exchange failed: '..tostring(err)) end
        ac.log('Spotify: Token exchange error: '..tostring(err))
        return
      end

      local responseBody = response["body"]
      if not responseBody or responseBody == '' then
        Spotify.playbackState.error = 'Empty response from Spotify'
        if callback then callback(true, 'Empty response') end
        return
      end

      -- Extract tokens from response
      local json = JSON.parse(responseBody)
      local accessToken = json["access_token"]
      local refreshToken = json["refresh_token"]
      local expiresIn = tonumber(json["expires_in"]) or 3600

      if accessToken and refreshToken then
        oauthConfig.accessToken = accessToken
        oauthConfig.refreshToken = refreshToken
        oauthConfig.tokenExpiry = os.time() + expiresIn
        Spotify.playbackState.error = ''
        -- Save tokens to INI file
        Spotify.saveConfigFile()
        if callback then callback(false, 'Authentication successful') end
        ac.log('Spotify: Successfully authenticated')
      else
        Spotify.playbackState.error = 'Failed to extract tokens from response'
        if callback then callback(true, 'Token extraction failed') end
        ac.log('Spotify: Token extraction failed. Response: '..responseBody)
      end

    end
  )
end

-- Refresh access token using refresh token
function Spotify.refreshAccessToken(callback)
  if oauthConfig.refreshToken == '' then
    ui.toast(ui.Icons.Warning, 'Refresh failed: No refresh token available')
    if callback then callback(true, 'No refresh token available') end
    return
  end
  
  Spotify._RefreshToken(
    function(err, response)
      if callback then callback(err, response) end

      -- Handle failed request
      if err then
        Spotify.playbackState.error = 'Token refresh failed: '..tostring(err)
        ui.toast(ui.Icons.Warning, 'Refresh failed: '..tostring(err))
        if callback then callback(true, tostring(err)) end
        return
      end

      --parse response
      local responseBody = response["body"]
      local json = JSON.parse(responseBody)
      ac.log('Spotify: Token refresh response: '..responseBody)

      local accessToken = json["access_token"]
      local expiresIn = tonumber(json["expires_in"]) or 3600

      if accessToken then
        ac.log("Token Refreshed")
        --ui.toast(ui.Icons.Info, 'Token refreshed successfully')
        oauthConfig.accessToken = accessToken
        oauthConfig.tokenExpiry = os.time() + expiresIn
        Spotify.saveConfigFile()
        if callback then callback(false, 'Token refreshed') end
      else
        Spotify.playbackState.error = 'Failed to extract access token'
        ui.toast(ui.Icons.Warning, 'Refresh failed: Could not extract access token from response')
        if callback then callback(true, 'Token extraction failed') end
      end

    end
  )
end

-- Check if token is expired and refresh if needed
function Spotify.ensureValidToken(callback)
  if oauthConfig.accessToken == '' then
    if callback then callback(true, 'Not authenticated') end
    Spotify.clearPlaybackState()
    Spotify.playbackState.error = 'Authentication required'
    return false
  end
  
  if os.time() > oauthConfig.tokenExpiry - 60 then
    Spotify.refreshAccessToken(callback)
    return false
  end
  
  if callback then callback(false, '') end
  return true
end

-- Set Volume
function Spotify.setVolume(volume, callback)
  Spotify.ensureValidToken(function(has_error, ensure_token_err)
    if has_error then
      if callback then callback(has_error, ensure_token_err) end
      return
    end

    Spotify._SetVolume(volume, function(err, response)
      if err then 
        if callback then callback(true, tostring(err)) end
        return
      end

      Spotify.playbackState.volume = volume
      if callback then callback(false, volume) end
    end)
    
  end)
end

-- Send Player Command
function Spotify.playerCommand(action, callback)
  Spotify.ensureValidToken(function(has_error, ensure_token_err)
    if has_error then
      if callback then callback(has_error, ensure_token_err) end
      return
    end

    Spotify._PlayerCommand(action, function(err, response)
      if err then 
        if callback then callback(true, tostring(err)) end
        return
      end

      if callback then callback(false, action) end
    end)

  end) 
end

-- Skip Track
function Spotify.nextTrack()
  pushCurrentSongToHistory()
  Spotify.playerCommand('next', function() 
    Spotify._GetQueue(function(err, response) 
      local json = JSON.parse(response["body"])
      local queueItems = json.queue or {}
      for i, item in ipairs(queueItems) do
        if (i == 1) then
          local js = {}
          js.item = item
          local song = parseTrackMetadata(js)

          Spotify.playbackState.progress = 0
          -- Track
          Spotify.playbackState.trackName = song.trackName
          Spotify.playbackState.duration = song.duration
          Spotify.playbackState.artistName = song.artistName
          Spotify.playbackState.trackUrl = song.trackUrl
          -- Album
          Spotify.playbackState.albumName = song.albumName
          Spotify.playbackState.albumArtUrl = song.albumArtUrl
          ui.onImageReady(song.albumArtUrl, function()
            Spotify.extractDominantColor(song.albumArtUrl)
          end)
        end
      end
    end)
  end)
end

-- Previous Track
function Spotify.prevTrack()
  Spotify.playerCommand('previous', function()
    -- Quick-load previous song metadata from history if available
    local historySize = #Spotify.songHistory
    if historySize > 0 then
      local prev = Spotify.songHistory[historySize]
      table.remove(Spotify.songHistory, historySize)

      Spotify.playbackState.progress = 0
      Spotify.playbackState.trackName = prev.trackName
      Spotify.playbackState.duration = prev.duration
      Spotify.playbackState.artistName = prev.artistName
      Spotify.playbackState.trackUrl = prev.trackUrl
      Spotify.playbackState.albumName = prev.albumName
      Spotify.playbackState.albumArtUrl = prev.albumArtUrl
      Spotify.playbackState.dominantColor = prev.dominantColor
      Spotify.playbackState.isPlaying = true

      ac.log('Spotify: Quick-loaded previous track from history: '..prev.trackName)
    end
  end)
end

-- Check if the current track is saved in the user's library
function Spotify.checkIsLiked(trackId, callback)
  if not trackId or trackId == '' then
    if callback then callback(true, 'No track ID') end
    return
  end

  Spotify.ensureValidToken(function(has_error, ensure_token_err)
    if has_error then
      if callback then callback(has_error, ensure_token_err) end
      return
    end

    Spotify._CheckLiked(trackId, function(err, response)
      if err then
        if callback then callback(true, tostring(err)) end
        return
      end

      local json = JSON.parse(response["body"])
      if json and type(json) == 'table' and json[1] ~= nil then
        Spotify.playbackState.isLiked = json[1] == true
      end
      if callback then callback(false, Spotify.playbackState.isLiked) end
    end)
  end)
end

-- Canvas for dominant color extraction (reused to avoid creating new ones)
local colorCanvas = nil
local colorCanvasSize = 64 -- Small size is sufficient for color sampling

-- Extract dominant color from album art URL
function Spotify.extractDominantColor(albumArtUrl, callback)
  if not albumArtUrl or albumArtUrl == '' then
    if callback then callback(true, 'No album art URL') end
    return
  end

  -- Create canvas if not exists
  if not colorCanvas then
    colorCanvas = ui.ExtraCanvas(vec2(colorCanvasSize, colorCanvasSize))
  end

  -- Draw the album art to the canvas (CSP will fetch from URL automatically)
  colorCanvas:clear(rgbm.colors.transparent)
  colorCanvas:update(function()
    ui.drawImage(albumArtUrl, vec2(0, 0), vec2(colorCanvasSize, colorCanvasSize))
  end)

  -- Access pixel data asynchronously
  colorCanvas:accessData(function(err, data)
    if err or not data then
      ac.log('Spotify: Failed to access album art data: '..(err or 'unknown error'))
      if callback then callback(true, err or 'Failed to access data') end
      return
    end

    -- Sample colors from a grid of points (avoiding edges which might have artifacts)
    local sampleColor = rgbm()
    local totalR, totalG, totalB = 0, 0, 0
    local totalWeight = 0
    local step = math.floor(colorCanvasSize / 8) -- 8x8 sample grid
    local margin = step -- Skip edge pixels

    for x = margin, colorCanvasSize - margin - 1, step do
      for y = margin, colorCanvasSize - margin - 1, step do
        data:colorTo(sampleColor, x, y)
        -- Only count pixels with some alpha (not transparent)
        if sampleColor.mult > 0.5 then
          local r, g, b = sampleColor.r, sampleColor.g, sampleColor.b
          local maxC = math.max(r, g, b)
          local minC = math.min(r, g, b)
          
          -- Calculate saturation (0-1)
          local sat = 0
          if maxC > 0 then
            sat = (maxC - minC) / maxC
          end
          
          -- Weight by saturation^2 - strongly favor vibrant colors
          -- Add small base weight so desaturated images still work
          local weight = 0.1 + sat * sat
          
          totalR = totalR + r * weight
          totalG = totalG + g * weight
          totalB = totalB + b * weight
          totalWeight = totalWeight + weight
        end
      end
    end

    data:dispose()

    if totalWeight > 0 then
      -- Calculate weighted average color
      local avgR = totalR / totalWeight
      local avgG = totalG / totalWeight
      local avgB = totalB / totalWeight

      -- Convert to HSV for saturation/brightness adjustment
      local maxC = math.max(avgR, avgG, avgB)
      local minC = math.min(avgR, avgG, avgB)
      local delta = maxC - minC

      -- Calculate hue
      local hue = 0
      if delta > 0 then
        if maxC == avgR then
          hue = 60 * (((avgG - avgB) / delta) % 6)
        elseif maxC == avgG then
          hue = 60 * (((avgB - avgR) / delta) + 2)
        else
          hue = 60 * (((avgR - avgG) / delta) + 4)
        end
      end

      -- Calculate saturation and value
      local sat = maxC > 0 and (delta / maxC) or 0
      local val = maxC

      -- Boost saturation for vibrancy (1.5x, capped at 1.0)
      sat = math.min(1.0, sat * 1.5)
      
      -- Ensure minimum brightness for text readability
      val = math.max(0.5, val)

      -- Convert back to RGB
      local c = val * sat
      local x = c * (1 - math.abs((hue / 60) % 2 - 1))
      local m = val - c

      local r1, g1, b1 = 0, 0, 0
      if hue < 60 then
        r1, g1, b1 = c, x, 0
      elseif hue < 120 then
        r1, g1, b1 = x, c, 0
      elseif hue < 180 then
        r1, g1, b1 = 0, c, x
      elseif hue < 240 then
        r1, g1, b1 = 0, x, c
      elseif hue < 300 then
        r1, g1, b1 = x, 0, c
      else
        r1, g1, b1 = c, 0, x
      end

      avgR = r1 + m
      avgG = g1 + m
      avgB = b1 + m

      Spotify.playbackState.dominantColor = rgbm(avgR, avgG, avgB, 1)
      --ac.log('Spotify: Dominant color extracted: R='..string.format('%.2f', avgR)..' G='..string.format('%.2f', avgG)..' B='..string.format('%.2f', avgB))
    else
      -- Fallback to default
      --Spotify.playbackState.dominantColor = rgbm(0.2, 0.2, 0.2, 1)
    end

    if callback then callback(false, Spotify.playbackState.dominantColor) end
  end)
end

-- Save (like) the current track
function Spotify.likeTrack(callback)
  local trackId = Spotify.playbackState.trackId
  if not trackId or trackId == '' then
    if callback then callback(true, 'No track ID') end
    return
  end

  Spotify.ensureValidToken(function(has_error, ensure_token_err)
    if has_error then
      if callback then callback(has_error, ensure_token_err) end
      return
    end

    Spotify._SaveTrack(trackId, function(err, response)
      if err then
        if callback then callback(true, tostring(err)) end
        return
      end

      Spotify.playbackState.isLiked = true
      ui.toast(ui.Icons.Heart, 'Added to Liked Songs')
      if callback then callback(false, true) end
    end)
  end)
end

-- Remove (unlike) the current track
function Spotify.unlikeTrack(callback)
  local trackId = Spotify.playbackState.trackId
  if not trackId or trackId == '' then
    if callback then callback(true, 'No track ID') end
    return
  end

  Spotify.ensureValidToken(function(has_error, ensure_token_err)
    if has_error then
      if callback then callback(has_error, ensure_token_err) end
      return
    end

    Spotify._RemoveTrack(trackId, function(err, response)
      if err then
        if callback then callback(true, tostring(err)) end
        return
      end

      Spotify.playbackState.isLiked = false
      ui.toast(ui.Icons.Heart, 'Removed from Liked Songs')
      if callback then callback(false, false) end
    end)
  end)
end

-- Play
function Spotify.play()
  Spotify.playerCommand('play')
  Spotify.playbackState.isPlaying = true
end

-- Pause
function Spotify.pause()
  Spotify.playerCommand('pause')
  Spotify.playbackState.isPlaying = false
end

-- Get Playback State and currently playing track info
function Spotify.getPlaybackState()

  -- Prevent infinite retry loops
  if Spotify.retries >= MAX_RETRIES then
    Spotify.playbackState.error = 'Maximum retries reached. Please check your authentication.'
    return
  end

  Spotify.ensureValidToken(function(has_error, ensure_token_err)
    if has_error then
      return
    end

    Spotify.playbackState.error = ''
    Spotify._GetPlayerState(function(err, response)

      -- Handle failed request
        if err then
          Spotify.playbackState.error = 'Failed to fetch track: '..tostring(err)
          ac.error('Spotify: Fetch error: '..tostring(err))
          return
        end

      -- Handle expired token
      if response["status"] == 401 then
        Spotify.refreshAccessToken(function (refresh_err, err_msg)
          if refresh_err then
            Spotify.playbackState.error = 'Token refresh failed: '..err_msg
            Spotify.retries = Spotify.retries + 1
          else
            -- Try again to fetch playback state after successful token refresh
            Spotify.getPlaybackState()
          end
        end)
      elseif response["status"] == 403 then
        Spotify.playbackState.error = 'Forbidden: '..response["body"]
        Spotify.retries = MAX_RETRIES
        ac.log('Spotify: Forbidden response: ', response)
      else
        Spotify.playbackState.error = ''
        -- Parse response and update playback state
        local responseBody = response["body"]

        -- Handle empty response / (no track playing)
        if not responseBody or responseBody == '' then
          Spotify.playbackState.trackName = 'Nothing playing'
          Spotify.playbackState.artistName = ''
          Spotify.playbackState.albumName = ''
          Spotify.playbackState.isPlaying = false
          return
        end

        local json = JSON.parse(responseBody)
      
        -- Extract data from parsed JSON
        Spotify.playbackState.isPlaying = json.is_playing or false
        Spotify.playbackState.progress = json.progress_ms or 0

        local song = parseTrackMetadata(json)
        local trackChanged = song.trackId ~= Spotify.playbackState.trackId
        -- Track
        Spotify.playbackState.trackName = song.trackName
        Spotify.playbackState.duration = song.duration
        Spotify.playbackState.artistName = song.artistName
        Spotify.playbackState.trackUrl = song.trackUrl
        Spotify.playbackState.trackId = song.trackId
        -- Album
        Spotify.playbackState.albumName = song.albumName
        Spotify.playbackState.albumArtUrl = song.albumArtUrl

        Spotify.playbackState.type = song.currently_playing_type or 'track'

        -- Check liked status and extract dominant color when track changes
        if trackChanged then
          Spotify.playbackState.isLiked = false
          Spotify.checkIsLiked(song.trackId)
          -- Extract dominant color from album art
          if song.albumArtUrl and song.albumArtUrl ~= '' then
            ui.onImageReady(song.albumArtUrl, function()
              Spotify.extractDominantColor(song.albumArtUrl)
            end)
          end
        end

        -- Get Volume Data
        local device = json.device
        if device and device.volume_percent then
          Spotify.playbackState.volume = device.volume_percent
        end
        
        Spotify.playbackState.lastUpdate = os.time()

      end
    end)

  end)
  
end

-- Clear playback state (used when auth fails or no track playing)
function Spotify.clearPlaybackState()
  Spotify.playbackState.trackName = 'Nothing playing'
  Spotify.playbackState.artistName = ''
  Spotify.playbackState.albumName = ''
  Spotify.playbackState.albumArtUrl = ''
  Spotify.playbackState.isPlaying = false
  Spotify.playbackState.duration = 0
  Spotify.playbackState.progress = 0
  Spotify.playbackState.dominantColor = rgbm(0, 0, 0, 1)
end

-- Get config (for settings UI)
function Spotify.getOauthConfig()
  return oauthConfig
end

-- Get Queue
function Spotify.GetQueue()
  Spotify._GetQueue(function (err, response)
      if response.status == 200 then
        local responseBody = response["body"]
        local json = JSON.parse(responseBody)
        local queueItems = json.queue or {}
        local parsedQueueItems = {}
        for i, item in ipairs(queueItems) do
          local trackName = item.name or 'Unknown Track'
          local artistName = (item.artists and #item.artists > 0 and item.artists[1].name) or 'Unknown Artist'
          local albumArtUrl = (item.album and item.album.images and #item.album.images > 0 and item.album.images[2].url) or ''
          local queueItem = {
            trackName = trackName,
            artistName = artistName,
            albumArtUrl = albumArtUrl
          }
          table.insert(parsedQueueItems, queueItem)
        end
        Spotify.playbackState.queue = parsedQueueItems
      else
        ac.log('Spotify: Failed to fetch queue. Status: '..response.status)
      end
  end)
end

-- Add track to queue by Track ID
function Spotify.AddToQueue(trackId)
  if not trackId or trackId == '' then
    return
  end

  Spotify.ensureValidToken(function(has_error, ensure_token_err)
    if has_error then
      ac.error('Spotify: Cannot add to queue - '..ensure_token_err)
      return
    end

    Spotify._AddToQueue(trackId, function(err, response)
      if err then
        ac.error('Spotify: Add to queue error: '..tostring(err))
        return
      end
    end)
  end)
end

-- Seek to position in current track
function Spotify.Seek(positionMs)
  positionMs = math.floor(positionMs)
  Spotify.ensureValidToken(function(has_error, ensure_token_err)

    if has_error then
      ac.error('Spotify: Cannot seek - '..ensure_token_err)
      return
    end

    Spotify._Seek(positionMs, function(err, response)
      if err then
        ac.error('Spotify: Seek error: '..tostring(err))
        return
      end
    end)
  end)
end

ac.onSharedEvent("AuthServer.Status", function(data)
    if data and data.status == "listening" then
        Spotify.authServerRunning = true
    else
        Spotify.authServerRunning = false
    end
end)

--[[ 
  API Request Functions - these are the low-level functions that make the actual HTTP requests to Spotify's API. 
  They are called by the higher-level functions above, which handle token management and response parsing.
]]

-- /api/token - refresh access token using refresh token
function Spotify._RefreshToken(callback)
  local auth = base64Encode(oauthConfig.clientId..':'..oauthConfig.clientSecret)

  local refresh_headers = {}
  refresh_headers['Authorization'] = 'Basic '..auth
  refresh_headers['Content-Type'] = 'application/x-www-form-urlencoded'
  local refresh_body = 'grant_type=refresh_token&refresh_token='..oauthConfig.refreshToken

  web.post(
    SPOTIFY_TOKEN_URL,
    refresh_headers,
    refresh_body,
    function(err, response)
      if callback then callback(err, response) end
    end
  )
end

-- /api/token - exchange auth code for access token
function Spotify._ExchangeAuthCode(authCode, callback)

  local auth = base64Encode(oauthConfig.clientId..':'..oauthConfig.clientSecret)
  
  local exchange_headers = {}
  exchange_headers['Authorization'] = 'Basic '..auth
  exchange_headers['Content-Type'] = 'application/x-www-form-urlencoded'
  local exchange_body = 'grant_type=authorization_code&code='..authCode..'&redirect_uri='..urlEncode(REDIRECT_URI)

  web.post(
    SPOTIFY_TOKEN_URL,
    exchange_headers,
    exchange_body,
    function(err, response)
      if callback then callback(err, response) end
    end)

end

-- /me/player - get current playback state and track info
function Spotify._GetPlayerState(callback)
  local headers = {}
  headers['Authorization'] = 'Bearer '..oauthConfig.accessToken
  headers['Content-Type'] = 'application/json; charset=utf-8'
  web.request('GET',
    SPOTIFY_API_URL..'/me/player?additional_types=track,episode',
    headers, '', function(err, response)
      if callback then callback(err, response) end
    end
  )
end

-- /me/player/currently-playing - get current track info and playback state
function Spotify._GetCurrentlyPlaying(callback)
  local headers = {}
  headers['Authorization'] = 'Bearer '..oauthConfig.accessToken
  headers['Content-Type'] = 'application/json; charset=utf-8'

  web.request('GET',
    SPOTIFY_API_URL..'/me/player/currently-playing?additional_types=track,episode',
    headers, '', function(err, response)
      if callback then callback(err, response) end
    end
  )
end

-- /me/player/volume?volume_percent={volume} - set volume (0-100)
function Spotify._SetVolume(volume, callback)
  local auth_headers = {}
  auth_headers['Authorization'] = 'Bearer '..oauthConfig.accessToken
  auth_headers['Content-Type'] = 'application/json'
  web.request('PUT',
      SPOTIFY_API_URL..'/me/player/volume?volume_percent='..math.floor(volume),
      auth_headers, '', function(err, response)
        if callback then callback(err, response) end
      end
    )
end

-- /me/player/play, /pause, /next, /previous - various player actions
function Spotify._PlayerCommand(action, callback)
  local auth_headers = {}
  auth_headers['Authorization'] = 'Bearer '..oauthConfig.accessToken
  local endpoint = SPOTIFY_API_URL..'/me/player/'..action
  local method = (action == 'pause' or action == 'play') and 'PUT' or 'POST'
  web.request(method,
    endpoint,
    auth_headers, '', function(err, response)
      if callback then callback(err, response) end
    end
  )
end

-- /me/tracks/contains?ids={id} - check if track is in user's library
function Spotify._CheckLiked(trackId, callback)
  local auth_headers = {}
  auth_headers['Authorization'] = 'Bearer '..oauthConfig.accessToken

  web.request('GET',
    SPOTIFY_API_URL..'/me/tracks/contains?ids='..trackId,
    auth_headers, '', function(err, response)
      if callback then callback(err, response) end
    end
  )
end

-- /me/tracks?ids={id} - save track to user's library
function Spotify._SaveTrack(trackId, callback)
  local auth_headers = {}
  auth_headers['Authorization'] = 'Bearer '..oauthConfig.accessToken
  auth_headers['Content-Type'] = 'application/json'

  web.request('PUT',
    SPOTIFY_API_URL..'/me/tracks?ids='..trackId,
    auth_headers, '', function(err, response)
      if callback then callback(err, response) end
    end
  )
end

-- /me/tracks?ids={id} - remove track from user's library
function Spotify._RemoveTrack(trackId, callback)
  local auth_headers = {}
  auth_headers['Authorization'] = 'Bearer '..oauthConfig.accessToken
  auth_headers['Content-Type'] = 'application/json'

  web.request('DELETE',
    SPOTIFY_API_URL..'/me/tracks?ids='..trackId,
    auth_headers, '', function(err, response)
      if callback then callback(err, response) end
    end
  )
end

-- /me/player/queue - get current queue
function Spotify._GetQueue(callback)
  local auth_headers = {}
  auth_headers['Authorization'] = 'Bearer '..oauthConfig.accessToken

  web.request('GET',
    SPOTIFY_API_URL..'/me/player/queue',
    auth_headers, '', function(err, response)
      if callback then callback(err, response) end
    end
  )
end

-- /me/player/seek?position_ms={position} - seek to position in current track
function Spotify._Seek(positionMs, callback)
  local auth_headers = {}
  auth_headers['Authorization'] = 'Bearer '..oauthConfig.accessToken
  auth_headers['Content-Type'] = 'application/json'

  web.request('PUT',
    SPOTIFY_API_URL..'/me/player/seek?position_ms='..positionMs,
    auth_headers, '', function(err, response)
      if callback then callback(err, response) end
    end
  )
end

-- /me/player/queue?uri={uri} - add track to queue
function Spotify._AddToQueue(trackId, callback)
  local auth_headers = {}
  auth_headers['Authorization'] = 'Bearer '..oauthConfig.accessToken
  auth_headers['Content-Type'] = 'application/json' 

  web.request('POST',
    SPOTIFY_API_URL..'/me/player/queue?uri='.."spotify:track:"..trackId,
    auth_headers, '', function(err, response)
      if callback then callback(err, response) end
    end
  )
end

-- Load config from INI file on startup
Spotify.loadConfigFile()

return Spotify
