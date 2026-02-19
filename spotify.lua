-- Spotify Web API Integration for Assetto Corsa
-- Displays currently playing track with album art

local Spotify = {}

-- Load INI configuration file from script directory
local scriptDir = ac.getFolder(ac.FolderID.ScriptOrigin)
local settingsPath = scriptDir .. '/settings.ini'

-- Constants
local SPOTIFY_AUTH_URL = 'https://accounts.spotify.com/authorize'
local SPOTIFY_TOKEN_URL = 'https://accounts.spotify.com/api/token'
local SPOTIFY_API_URL = 'https://api.spotify.com/v1'
local AUTH_SERVER = 'http://127.0.0.1:8888'
local REDIRECT_URI = AUTH_SERVER..'/callback'
local SCOPE = 'user-read-currently-playing user-read-playback-state user-modify-playback-state'
local IMAGE_CACHE_DIR = scriptDir..'/spotify_art'
local MAX_RETRIES = 5

Spotify.retries = 0

-- OAuth Configuration
local spotifyConfig = ac.storage{
  clientId = '',
  clientSecret = '',
  refreshToken = '',
  accessToken = '',
  tokenExpiry = 0,
  authServerRunning = false,
}

-- Playback state
local playbackState = {
  trackName = 'Not initialized',
  artistName = '',
  albumName = '',
  albumArtUrl = '',
  albumArtPath = '',
  isPlaying = false,
  duration = 0,
  progress = 0,
  error = '',
  loading = false,
  lastUpdate = 0,
  trackUrl = '',
  volume = 0,
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
  local refreshToken = iniConfig:get('SPOTIFY', 'REFRESH_TOKEN', '')
  
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
  
  if refreshToken then
    refreshToken = refreshToken:match('^%s*(.-)%s*$') or ''
  else
    refreshToken = ''
  end

  spotifyConfig.clientId = clientId
  spotifyConfig.clientSecret = clientSecret
  spotifyConfig.refreshToken = refreshToken
end

-- Save current config to INI file
function Spotify.saveConfigFile()
  local iniConfig = ac.INIConfig.load(settingsPath, ac.INIFormat.Default)
  
  if not iniConfig then
    ac.log('Spotify: Could not load settings.ini for saving')
    return
  end
  
  iniConfig:setAndSave('SPOTIFY', 'CLIENT_ID', spotifyConfig.clientId)
  iniConfig:setAndSave('SPOTIFY', 'CLIENT_SECRET', spotifyConfig.clientSecret)
  iniConfig:setAndSave('SPOTIFY', 'REFRESH_TOKEN', spotifyConfig.refreshToken)
  ac.log('Spotify: Config saved to settings.ini')
end

-- Create cache directory if it doesn't exist
local function ensureCacheDir()
  if not io.exists(IMAGE_CACHE_DIR) then
    io.createDir(IMAGE_CACHE_DIR)
  end
end

local function hashString(str)
  local hash = 5381
  for i = 1, #str do
    hash = ((hash * 33) + str:byte(i)) % 0x7FFFFFFF
  end
  return string.format('%08x', hash)
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

-- Download and cache album art
local function downloadAlbumArt(imageUrl, albumHash)
  if not imageUrl or imageUrl == '' then
    return nil
  end
  
  ensureCacheDir()
  
  -- Generate cache filename from URL hash
  local cacheFile = IMAGE_CACHE_DIR..'/'..albumHash..'.png'
  
  -- Check if already cached
  if io.exists(cacheFile) then
    return cacheFile
  end
  
  -- Download image
  web.get(imageUrl, function(err, response)
    if err then
      ac.log('Spotify: Failed to download album art: '..err)
      return
    end
    
    -- Save to cache
    local file = io.open(cacheFile, 'wb')
    if file then
      file:write(response.body)
      file:close()
    end
  end)
  
  return cacheFile
end

-- Add URL encoding helper function near the top with other helpers
local function urlEncode(str)
  return str:gsub('([^%w%-_.~])', function(c)
    return string.format('%%%02X', string.byte(c))
  end)
end

-- Generate auth URL for user to visit
function Spotify.generateAuthUrl()
  if spotifyConfig.clientId == '' then
    return nil
  end
  
  local params = {
    'client_id='..spotifyConfig.clientId,
    'response_type=code',
    'redirect_uri='..urlEncode(REDIRECT_URI),  -- URL encode the redirect URI
    'scope='..SCOPE:gsub(' ', '%%20'),
    'show_dialog=true'
  }
  
  return SPOTIFY_AUTH_URL..'?'..table.concat(params, '&')
end

-- Handle auth callback from server and exchange code for token
function Spotify.handleAuthCallback()
  web.get(AUTH_SERVER..'/token', function(auth_err, auth_resp)
    -- Handle errors from auth server
    if auth_err then
      ac.log('Spotify: Failed to get auth code from server: '..tostring(auth_err))
      return
    end
    
    local respBody = auth_resp.body
    local json = JSON.parse(respBody)
    local authCode = json.code
    if authCode and authCode ~= '' then
      ac.log('Spotify: Received auth code: '..authCode:sub(1, 5)..'...')
      Spotify.exchangeAuthCode(authCode, function(exchange_err, message)
        if exchange_err then
          ui.toast(ui.Icons.Error, 'Authentication failed: '..message)
        else
          ui.toast(ui.Icons.Success, 'Authentication successful')
          Spotify.getCurrentTrack()

          -- Kill server
          ac.log('Spotify: Sending exit command to auth server')
          web.get(AUTH_SERVER..'/exit', function(err,response) end)
        end
      end)
    else
    ac.log('Spotify: No auth code received in callback')
    end
  end)
end

-- Run built-in auth server process if compiled version is available
function Spotify.runAuthServer()
  ac.log('Spotify: Trying to start auth server process...')
  spotifyConfig.authServerRunning = false

  local server_path = scriptDir..'/external/auth_server.exe'
  if not io.exists(server_path) then 
    ac.log('Spotify: Auth server executable not found at '..server_path)
    return
  end

  os.runConsoleProcess(
    {
      filename = scriptDir..'/external/auth_server.exe',
      arguments = {},
      terminateWithScript = true,
      dataCallback = function (err, data)
        if err then
          ac.log('Spotify: Auth server error: ', tostring(err))
          spotifyConfig.authServerRunning = false
        else
          local datastr = tostring(data)
          if datastr:match('Listening') then
            spotifyConfig.authServerRunning = true
            ac.log('Spotify: Auth server is now running')
          end

          if datastr:match('Authorization code received') then
            ac.log('Spotify: Authorization code received, fetching token...')
            Spotify.handleAuthCallback()
          end
        end
      end
    }, function (err, data)
        spotifyConfig.authServerRunning = false
    end
  )
end

-- Exchange authorization code for refresh token
function Spotify.exchangeAuthCode(authCode, callback)

  if spotifyConfig.clientId == '' or spotifyConfig.clientSecret == '' then
    if callback then callback(true, 'Client ID or Secret not configured') end
    return
  end
  
  playbackState.loading = true
  playbackState.error = ''
  
  local auth = base64Encode(spotifyConfig.clientId..':'..spotifyConfig.clientSecret)
  
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
      playbackState.loading = false

      -- Handle failed request
      if err then
        playbackState.error = 'Token exchange failed: '..tostring(err)
        if callback then callback(true, 'Token exchange failed: '..tostring(err)) end
        ac.log('Spotify: Token exchange error: '..tostring(err))
        return
      end

      local responseBody = response["body"]
      if not responseBody or responseBody == '' then
        playbackState.error = 'Empty response from Spotify'
        if callback then callback(true, 'Empty response') end
        return
      end

      -- Extract tokens from response
      local json = JSON.parse(responseBody)
      local accessToken = json["access_token"]
      local refreshToken = json["refresh_token"]
      local expiresIn = tonumber(json["expires_in"]) or 3600

      if accessToken and refreshToken then
        spotifyConfig.accessToken = accessToken
        spotifyConfig.refreshToken = refreshToken
        spotifyConfig.tokenExpiry = os.clock() + expiresIn
        playbackState.error = ''
        -- Save tokens to INI file
        Spotify.saveConfigFile()
        if callback then callback(false, 'Authentication successful') end
        ac.log('Spotify: Successfully authenticated')
      else
        playbackState.error = 'Failed to extract tokens from response'
        if callback then callback(true, 'Token extraction failed') end
        ac.log('Spotify: Token extraction failed. Response: '..responseBody)
      end

    end
  )
end

-- Refresh access token using refresh token
function Spotify.refreshAccessToken(callback)
  if spotifyConfig.refreshToken == '' then
    if callback then callback(true, 'No refresh token available') end
    return
  end
  
  local auth = base64Encode(spotifyConfig.clientId..':'..spotifyConfig.clientSecret)

  local refresh_headers = {}
  refresh_headers['Authorization'] = 'Basic '..auth
  refresh_headers['Content-Type'] = 'application/x-www-form-urlencoded'
  local refresh_body = 'grant_type=refresh_token&refresh_token='..spotifyConfig.refreshToken

  web.post(
    SPOTIFY_TOKEN_URL,
    refresh_headers,
    refresh_body,
    function(err, response)
      if callback then callback(err, response) end

      -- Handle failed request
      if err then
        playbackState.error = 'Token refresh failed: '..tostring(err)
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
        ui.toast(ui.Icons.Info, 'Token refreshed successfully')
        spotifyConfig.accessToken = accessToken
        spotifyConfig.tokenExpiry = os.clock() + expiresIn
        Spotify.saveConfigFile()
        if callback then callback(false, 'Token refreshed') end
      else
        playbackState.error = 'Failed to extract access token'
        if callback then callback(true, 'Token extraction failed') end
      end

    end
  )
end

-- Check if token is expired and refresh if needed
function Spotify.ensureValidToken(callback)
  if spotifyConfig.accessToken == '' then
    if callback then callback(true, 'Not authenticated') end
    return false
  end
  
  if os.clock() > spotifyConfig.tokenExpiry - 60 then
    Spotify.refreshAccessToken(callback)
    return false
  end
  
  if callback then callback(false, '') end
  return true
end

-- Get Current Volume
function Spotify.getVolume(callback)
  Spotify.ensureValidToken(function(ensure_token_err)
    if ensure_token_err then
      if callback then callback(true, 'Not authenticated') end
      return
    end

    local auth_headers = {}
    auth_headers['Authorization'] = 'Bearer '..spotifyConfig.accessToken

    web.request('GET',
      SPOTIFY_API_URL..'/me/player/devices',
      auth_headers, '', function(err, response)
        if err then
          if callback then callback(true, tostring(err)) end
          return
        end

        local responseBody = response["body"]
        local json = JSON.parse(responseBody)
        local devices = json.devices or {}
        local volume = nil
        for _, device in ipairs(devices) do
          if device.is_active then
            volume = device.volume_percent
            playbackState.volume = volume
            break
          end
        end

        if callback then callback(false, volume) end
      end
    )
  end)
end

-- Set Volume
function Spotify.setVolume(volume, callback)
  Spotify.ensureValidToken(function(ensure_token_err)
    if ensure_token_err then
      if callback then callback(true, 'Not authenticated') end
      return
    end

    local auth_headers = {}
    auth_headers['Authorization'] = 'Bearer '..spotifyConfig.accessToken
    auth_headers['Content-Type'] = 'application/json'

    web.request('PUT',
      SPOTIFY_API_URL..'/me/player/volume?volume_percent='..math.floor(volume),
      auth_headers, '', function(err, response)
        if err then
          if callback then callback(true, tostring(err)) end
          return
        end

        playbackState.volume = volume
        if callback then callback(false, '') end
      end
    )
  end)
end

-- Skip Current Track
function Spotify.playerCommand(action, callback)
  Spotify.ensureValidToken(function(ensure_token_err)
    if ensure_token_err then
      playbackState.error = 'Authentication required'
      Spotify.clearPlaybackState()
      if callback then callback(true, 'Not authenticated') end
      return
    end

    local auth_headers = {}
    auth_headers['Authorization'] = 'Bearer '..spotifyConfig.accessToken

    local endpoint = SPOTIFY_API_URL..'/me/player/'..action
    local method = (action == 'pause' or action == 'play') and 'PUT' or 'POST'

    web.request(method,
      endpoint,
      auth_headers, '', function(err, response)
        if err then
          playbackState.error = 'Failed to execute player command: '..tostring(err)
          if callback then callback(true, tostring(err)) end
          return
        end

        if action == 'pause' then
          playbackState.isPlaying = false
        end

        if action == 'play' then
          playbackState.isPlaying = true
        end

        -- Refresh current track info after skipping
        Spotify.getCurrentTrack()

      end
    )
  end)
end

-- Fetch currently playing track
function Spotify.getCurrentTrack(callback)

  -- Prevent infinite retry loops
  if Spotify.retries >= MAX_RETRIES then
    playbackState.error = 'Maximum retries reached. Please check your authentication.'
    if callback then callback(true, 'Max retries reached') end
    return
  end

  Spotify.ensureValidToken(function(ensure_token_err)
    if ensure_token_err then
      playbackState.error = 'Authentication required'
      Spotify.clearPlaybackState()
      if callback then callback(true, 'Not authenticated') end
      return
    end
    
    if not playbackState.is_playing then playbackState.loading = true end
    playbackState.error = ''

    local auth_headers = {}
    auth_headers['Authorization'] = 'Bearer '..spotifyConfig.accessToken

    web.request('GET',
      SPOTIFY_API_URL..'/me/player/currently-playing',
      auth_headers, '', function(err, response)

        playbackState.loading = false
        -- Handle failed request
        if err then
          playbackState.error = 'Failed to fetch track: '..tostring(err)
          if callback then callback(true, tostring(err)) end
          ac.log('Spotify: Fetch error: '..tostring(err))
          return
        end

        local responseBody = response["body"]        
        local json = JSON.parse(responseBody)
        if response["status"] == 401 and json and json.error and json.error.message == 'The access token expired' then
          playbackState.error = 'Unauthorized. Trying to automatically refresh token.'
          --if callback then callback(true, 'Unauthorized') end

          Spotify.refreshAccessToken(function(refresh_err, refresh_message)
            if refresh_err then
              playbackState.error = 'Token refresh failed: '..refresh_message
              Spotify.retries = Spotify.retries + 1
              if callback then callback(true, 'Token refresh failed') end
            end
          end)

          return
        end

        -- Handle empty response / (no track playing)
        if not responseBody or responseBody == '' then
          playbackState.trackName = 'Nothing playing'
          playbackState.artistName = ''
          playbackState.albumName = ''
          playbackState.isPlaying = false
          if callback then callback(false, '') end
          return
        end
        -- Parse
        local json = JSON.parse(responseBody)

        -- Extract data from parsed JSON
        playbackState.isPlaying = json.is_playing or false
        playbackState.progress = json.progress_ms or 0
        
        if json.item then
          playbackState.trackName = json.item.name or 'Unknown Track'
          playbackState.duration = json.item.duration_ms or 0
          
          if json.item.artists and #json.item.artists > 0 then
            playbackState.artistName = json.item.artists[1].name or 'Unknown Artist'
          end

          if json.item.external_urls and json.item.external_urls.spotify then
            playbackState.trackUrl = json.item.external_urls.spotify
          else
            playbackState.trackUrl = ''
          end
          
          if json.item.album then
            playbackState.albumName = json.item.album.name or ''
            
            if json.item.album.images and #json.item.album.images > 0 then
              local imageUrl = json.item.album.images[1].url
              playbackState.albumArtUrl = imageUrl
              
              -- Generate hash for filename
              local albumHash = hashString(imageUrl)
              playbackState.albumArtPath = downloadAlbumArt(imageUrl, albumHash)
            end
          end
        end
        
        playbackState.lastUpdate = os.clock()
        playbackState.error = ''
        if callback then callback(false, '') end

      end
    )
  end)
end

-- Clear playback state (used when auth fails or no track playing)
function Spotify.clearPlaybackState()
  playbackState.trackName = 'Not initialized'
  playbackState.artistName = ''
  playbackState.albumName = ''
  playbackState.albumArtUrl = ''
  playbackState.albumArtPath = ''
  playbackState.isPlaying = false
  playbackState.duration = 0
  playbackState.progress = 0
end

-- Get current playback state
function Spotify.getState()
  return playbackState
end

-- Get config (for settings UI)
function Spotify.getConfig()
  return spotifyConfig
end

-- Update config (from settings) and persist to INI
function Spotify.setConfig(newConfig)
  spotifyConfig.clientId = newConfig.clientId or spotifyConfig.clientId
  spotifyConfig.clientSecret = newConfig.clientSecret or spotifyConfig.clientSecret
  spotifyConfig.refreshToken = newConfig.refreshToken or spotifyConfig.refreshToken
  -- Save to INI file
  Spotify.saveConfigFile()
end

-- Initialize - ensure cache directory exists
ensureCacheDir()

-- Load config from INI file on startup
Spotify.loadConfigFile()

return Spotify
