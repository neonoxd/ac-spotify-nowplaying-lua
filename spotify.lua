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
  showLink = false,
  colorTheme = rgbm(1, 1, 1, 1)
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
  else
    song.artistName = 'Unknown Artist'
  end
  song.trackUrl = (json.item.external_urls and json.item.external_urls.spotify) or ''
  song.trackId = json.item.id or ''

  if json.item.album then
    song.albumArtUrl = (json.item.album.images and #json.item.album.images > 0 and json.item.album.images[1].url) or ''
    song.albumName = json.item.album.name or ''
  else
    song.albumArtUrl = ''
    song.albumName = ''
  end

  return song
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
          Spotify.getCurrentTrack()
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

-- Get Current Volume
function Spotify.getVolume(callback)
  Spotify.ensureValidToken(function(has_error, ensure_token_err)
    if has_error then
      if callback then callback(has_error, ensure_token_err) end
      return
    end

    Spotify._GetVolume(function(err, response)
      if err then 
        if callback then callback(true, tostring(err)) end
        return
      end

      if response["status"] ~= 200 then
        return
      end

      local responseBody = response["body"]
      local json = JSON.parse(responseBody)
      local devices = json.devices or {}
      local volume = nil
      for _, device in ipairs(devices) do
        if device.is_active then
          volume = device.volume_percent
          Spotify.playbackState.volume = volume
          break
        end
      end

    end)
  end)
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
    }
    table.insert(Spotify.songHistory, snapshot)
    -- Trim history if it exceeds max size
    if #Spotify.songHistory > Spotify.maxHistorySize then
      table.remove(Spotify.songHistory, 1)
    end
    ac.log('Spotify: Pushed to history: '..snapshot.trackName..' (history size: '..#Spotify.songHistory..')')
  end
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

-- Fetch currently playing track
function Spotify.getCurrentTrack(callback)

  -- Prevent infinite retry loops
  if Spotify.retries >= MAX_RETRIES then
    Spotify.playbackState.error = 'Maximum retries reached. Please check your authentication.'
    if callback then callback(true, 'Max retries reached') end
    return
  end

  Spotify.ensureValidToken(function(has_error, ensure_token_err)
    if has_error then
      if callback then callback(has_error, ensure_token_err) end
      return
    end
    
    Spotify.playbackState.error = ''

    Spotify._GetCurrentlyPlaying(function(err, response)

        -- Handle failed request
        if err then
          Spotify.playbackState.error = 'Failed to fetch track: '..tostring(err)
          if callback then callback(true, tostring(err)) end
          ac.log('Spotify: Fetch error: '..tostring(err))
          return
        end
        
        local responseBody = response["body"]
        local json = JSON.parse(responseBody)
        if response["status"] == 401 and json and json.error and json.error.message == 'The access token expired' then
          Spotify.playbackState.error = 'Unauthorized. Trying to automatically refresh token.'
          --if callback then callback(true, 'Unauthorized') end

          Spotify.refreshAccessToken(function(refresh_err, refresh_message)
            if refresh_err then
              Spotify.playbackState.error = 'Token refresh failed: '..refresh_message
              Spotify.retries = Spotify.retries + 1
              if callback then callback(true, 'Token refresh failed') end
            end
          end)

          return
        end

        if response["status"] == 403 then
          Spotify.playbackState.error = 'Forbidden: '..response["body"]
          Spotify.retries = MAX_RETRIES
          ac.log('Spotify: Forbidden response: ', response)
          if callback then callback(true, 'Forbidden') end
          return
        end

        -- Handle empty response / (no track playing)
        if not responseBody or responseBody == '' then
          Spotify.playbackState.trackName = 'Nothing playing'
          Spotify.playbackState.artistName = ''
          Spotify.playbackState.albumName = ''
          Spotify.playbackState.isPlaying = false
          if callback then callback(false, '') end
          return
        end

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

        -- Check liked status when track changes
        if trackChanged then
          Spotify.playbackState.isLiked = false
          Spotify.checkIsLiked(song.trackId)
        end
        
        Spotify.playbackState.lastUpdate = os.time()
        Spotify.playbackState.error = ''

        if callback then callback(false, '') end

      end
    )
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

-- /me/player/currently-playing - get current track info and playback state
function Spotify._GetCurrentlyPlaying(callback)
  local auth_headers = {}
  auth_headers['Authorization'] = 'Bearer '..oauthConfig.accessToken
  auth_headers['Content-Type'] = 'application/json; charset=utf-8'

  web.request('GET',
    SPOTIFY_API_URL..'/me/player/currently-playing',
    auth_headers, '', function(err, response)
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

-- /me/player/devices returns list of user devices with volume info, find active device and return volume
function Spotify._GetVolume(callback)
  local auth_headers = {}
  auth_headers['Authorization'] = 'Bearer '..oauthConfig.accessToken

  web.request('GET',
      SPOTIFY_API_URL..'/me/player/devices',
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

-- Load config from INI file on startup
Spotify.loadConfigFile()

return Spotify
