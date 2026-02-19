local spotify = require('spotify')
local spotifyRefreshTimer = 0
local spotifyVolumeTimer = 0
local spotifyAuthCodeInput = ''
local REFRESH_INTERVAL = 5 -- seconds between API calls
local VOLUME_UPDATE_INTERVAL = 1 -- seconds between checking if we should update volume

local settings_showSpotifyLink = false
local settings_showControls = false

local volumeChanged = false

-- Load config from INI file on startup
spotify.getConfig().authServerRunning = false
spotify.getCurrentTrack()

function script.windowMain(dt)

  local state = spotify.getState()
  ac.debug('trackName: ', state.trackName)
  ac.debug('artistName: ', state.artistName)
  ac.debug('albumName: ', state.albumName)
  ac.debug('isPlaying: ', state.isPlaying)
  ac.debug('duration: ', state.duration)
  ac.debug('progress: ', state.progress)
  ac.debug('error: ', state.error)
  ac.debug('volume: ', state.volume)

  spotifyRefreshTimer = spotifyRefreshTimer + dt
  spotifyVolumeTimer = spotifyVolumeTimer + dt
  
  -- Fetch current track every REFRESH_INTERVAL seconds
  if spotifyRefreshTimer > REFRESH_INTERVAL then
    spotify.getCurrentTrack()
    if not volumeChanged then
      spotify.getVolume()
    end
    spotifyRefreshTimer = 0
  end

  -- Update volume every VOLUME_UPDATE_INTERVAL seconds
  if spotifyVolumeTimer > VOLUME_UPDATE_INTERVAL then
    if volumeChanged then
      spotify.setVolume(state.volume)
      volumeChanged = false
    end
    spotifyVolumeTimer = 0
  end
  
  ui.beginOutline()
  
  -- Display error if any
  if state.error ~= '' then
    ui.pushStyleColor(ui.StyleColor.Text, rgbm(1, 0.2, 0.2, 1))
    ui.textWrapped(state.error)
    ui.popStyleColor()
  end

  if state.trackName and state.trackName ~= 'Nothing playing' then
    ui.beginGroup()
    -- Display album art if available
      if state.albumArtPath and state.albumArtPath ~= '' and io.exists(state.albumArtPath) then
        --ui.offsetCursorY(10)
        local availableHeight = ui.availableSpaceY()
        local imageSize = math.min(200, availableHeight - 20)
        ui.image(state.albumArtPath, vec2(imageSize, imageSize))
        --ui.drawImage(state.albumArtPath, ui.getCursor(), ui.getCursor() + vec2(imageSize, imageSize))
        --ui.offsetCursorY(imageSize + 5)
        ui.sameLine()
      end

      -- Metadata on right
      ui.beginGroup()
        ui.pushFont(ui.Font.Title)
        ui.textWrapped(state.trackName)
        ui.popFont()
        ui.offsetCursorY(5)

        ui.pushFont(ui.Font.Main)
        if state.artistName ~= '' then
          ui.textWrapped('Artist: '..state.artistName)
        end
        if state.albumName ~= '' then
          ui.textWrapped('Album: '..state.albumName)
        end
        ui.popFont()

        -- Display play progress
        if state.duration > 0 then
          if state.isPlaying then
            state.progress = state.progress + (dt * 1000)
          end
          local progressPercent = (state.progress / state.duration) * 100
          local durationMin = math.floor(state.duration / 1000 / 60)
          local durationSec = math.floor((state.duration / 1000) % 60)
          local progressMin = math.floor(state.progress / 1000 / 60)
          local progressSec = math.floor((state.progress / 1000) % 60)
          ui.text(string.format('Progress: %d:%02d / %d:%02d', 
            progressMin, progressSec, durationMin, durationSec))
          ui.progressBar(progressPercent / 100, vec2(ui.availableSpaceX(), 4))
        end

        -- Controls
        if settings_showControls or ac.windowFading() ~= 1 then
          ui.pushFont(ui.Font.Main)
          if ui.iconButton('controls/prev.png', vec2(24, 24)) then
            spotify.playerCommand("previous")
          end
          ui.sameLine()
          if state.isPlaying then
            if ui.iconButton('controls/pause.png', vec2(24, 24)) then
              spotify.playerCommand("pause")
            end
          else
            if ui.iconButton('controls/play.png', vec2(24, 24)) then
              spotify.playerCommand("play")
            end
          end
          ui.sameLine()
          if ui.iconButton('controls/next.png', vec2(24, 24)) then
            spotify.playerCommand("next")
          end
          ui.popFont()

          -- Volume control
          local value, changed = ui.slider('##VolumeSlider', state.volume, 0, 100, 'Volume: %.0f%%')
          if changed then
            state.volume = value
            volumeChanged = true
          end


        end

      ui.endGroup()
    ui.endGroup()

    -- Spotify track URL
    if settings_showSpotifyLink and state.trackUrl ~= '' then
      ui.copyable(state.trackUrl)
    end

  else
    ui.text(state.trackName)
    if state.isPlaying == false then
      ui.textWrapped('Status: Not playing')
    end
  end
  
  --ui.separator()
  
  --if ui.button('Refresh Now', vec2(ui.availableSpaceX(), 0)) then
  --  spotify.getCurrentTrack()
  --end
  
  ui.endOutline(rgbm(0, 0, 0, ac.windowFading()), 1)
end

local authUrl = nil
local authUrlGenerated = false
function script.windowSettings(dt)
  local config = spotify.getConfig()
  ac.debug('clientId: ', config.clientId)
  --ac.debug('clientSecret: ', config.clientSecret)
  --ac.debug('refreshToken: ', config.refreshToken)
  --ac.debug('accessToken: ', config.accessToken)
  ac.debug('tokenExpiry: ', config.tokenExpiry)
  
  ui.text('Spotify API Configuration')
  ui.separator()
  
  ui.text('Setup Instructions')
  ui.textWrapped('1. Edit settings.ini and enter your Client ID and Client Secret from https://developer.spotify.com/dashboard')
  ui.textWrapped('2. Click "Generate Auth URL" visit the URL in your browser')
  ui.textWrapped('3. Login and authorize the app')
  ui.textWrapped('4.a If you are using the built-in auth server, you should be authenticated automatically now.')
  ui.textWrapped('4.b Otherwise paste the code from the url and click "Exchange Code for Token"')
  ui.separator()
  
  if config.clientId ~= '' and config.clientSecret ~= '' then
    if config.refreshToken == '' and ui.button('1. Generate Auth URL', vec2(ui.availableSpaceX(), 0)) then
      authUrlGenerated = false

      if not config.authServerRunning then
        spotify.runAuthServer()
      end

      authUrl = nil
      authUrl = spotify.generateAuthUrl()
      authUrlGenerated = true
      if authUrl then
        ac.log('---Spotify Auth URL---')
        ac.log(authUrl)
        ac.log('---Spotify Auth URL---')
        ac.console('Copy this URL and visit it in your browser to authorize:')
        ac.console(authUrl)
        ui.toast(ui.Icons.Info, 'Auth URL printed to console')
      end
    end

    if authUrl then
      if ui.button('Open Auth URL in Browser', vec2(ui.availableSpaceX(), 0)) then
        os.execute(string.format('start "" "%s"', authUrl))
        authUrl = nil
      end
      ui.textWrapped('Click the button above and authorize the app')      
    end

    if config.authServerRunning then
      authUrlGenerated = false
    end

    if not config.authServerRunning and authUrlGenerated then
      ui.setNextItemWidth(ui.availableSpaceX() * 0.7)
      spotifyAuthCodeInput = ui.inputText('##authCode', spotifyAuthCodeInput, vec2(128,128))
      ui.sameLine()
      ui.text('Auth Code')
      if ui.button('2. Exchange Code for Token', vec2(ui.availableSpaceX(), 0)) then
        if spotifyAuthCodeInput ~= '' then
          spotify.exchangeAuthCode(spotifyAuthCodeInput, function(err, msg)
            if err then
              ui.toast(ui.Icons.Warning, 'Auth failed: '..msg)
            else
              ui.toast(ui.Icons.Check, msg)
              spotifyAuthCodeInput = ''
              authUrlGenerated = false
            end
          end)
        else
          ui.toast(ui.Icons.Warning, 'Please enter an authorization code')
        end
      end
    end
    
  else
    ui.pushStyleColor(ui.StyleColor.Text, rgbm(1, 1, 0, 1))
    ui.textWrapped('Please configure your Client ID and Client Secret in settings.ini first')
    ui.popStyleColor()
  end
  
  ui.separator()
  
  if config.refreshToken ~= '' then
    ui.pushStyleColor(ui.StyleColor.Text, rgbm(0, 1, 0, 1))
    ui.text('Status: Authenticated ✅')
    ui.popStyleColor()
    
    if ui.button('Clear Authentication', vec2(ui.availableSpaceX(), 0)) then
      config.refreshToken = ''
      config.accessToken = ''
      spotify.setConfig(config)
      ui.toast(ui.Icons.Info, 'Authentication cleared')
    end
    
    if ui.button('Refresh Access Token', vec2(ui.availableSpaceX(), 0)) then
      ui.toast(ui.Icons.Info, 'Refreshing access token...')
      spotify.retries = 0
      spotify.refreshAccessToken(function(err, msg)
        if err then
          ui.toast(ui.Icons.Warning, 'Refresh failed: '..msg)
        else
          ui.toast(ui.Icons.Check, 'Token refreshed successfully')
        end
      end)
    end
  else
    ui.pushStyleColor(ui.StyleColor.Text, rgbm(1, 1, 0, 1))
    ui.text('Status: Not Authenticated')
    ui.popStyleColor()
    
    ui.separator()
    if config.authServerRunning then
      ui.pushStyleColor(ui.StyleColor.Text, rgbm(0, 1, 0, 1))
      ui.textWrapped('Auth server is running. Please complete the authentication steps above.')
      ui.popStyleColor()
    else
      ui.textWrapped('Auth server is not running. Click "Generate Auth URL" to start it and follow the steps above.')
    end
  end
  ui.separator()

  if ui.checkbox('Show Spotify Link', settings_showSpotifyLink) then
    settings_showSpotifyLink = not settings_showSpotifyLink
  end

  if ui.checkbox('Always Show Track Controls', settings_showControls) then
    settings_showControls = not settings_showControls
  end

end