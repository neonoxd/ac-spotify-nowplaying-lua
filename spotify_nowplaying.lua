local spotify = require('spotify')
local custom_ui = require('ui_util')
local REFRESH_INTERVAL = 5 -- seconds between API calls
local VOLUME_UPDATE_INTERVAL = 1 -- seconds between checking if we should update volume
local DWRITE_FONT = "Arial Unicode MS"

local spotifyRefreshTimer = REFRESH_INTERVAL + 1
local spotifyVolumeTimer = 0
local spotifyAuthCodeInput = ''
local volumeChanged = false

local authUrl = nil
local authUrlGenerated = false

local colorTheme = spotify.appSettings.colorTheme
local colorThemeChanged = false

function script.windowMain(dt)
  
  local state = spotify.playbackState
  local config = spotify.getOauthConfig()

  -- DEBUG
  ac.debug('..trackName: ', state.trackName)
  ac.debug('..artistName: ', state.artistName)
  ac.debug('..albumName: ', state.albumName)
  ac.debug('..isPlaying: ', state.isPlaying)
  ac.debug('..duration: ', state.duration)
  ac.debug('..progress: ', state.progress)
  ac.debug('..error: ', state.error)
  ac.debug('..volume: ', state.volume)

  -- If not authenticated, show message and return early
  if config.refreshToken == '' or config.accessToken == '' then
    ui.beginOutline()
    ui.pushStyleColor(ui.StyleColor.Text, rgbm(1, 1, 0, 1))
    ui.pushFont(ui.Font.Title)
    ui.textWrapped('Please authenticate with Spotify in the settings tab (Top Right of the window) to display now playing information.')
    ui.popStyleColor()
    ui.popFont()
    ui.endOutline(rgbm(0, 0, 0, ac.windowFading()), 1)
    return
  end

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
  
  -- Display error if any
  if state.error ~= '' then
    ui.pushStyleColor(ui.StyleColor.Text, rgbm(1, 0.2, 0.2, 1))
    ui.textWrapped(state.error)
    ui.popStyleColor()
    return
  end

  -- Update progress locally for smoother UI
  if state.isPlaying then
    state.progress = state.progress + (dt * 1000)
    state.progress = math.min(state.progress, state.duration)
  end

  if ac.windowFading() > 0.5 and spotify.appSettings.showOnHover then
    return
  end

  ui.pushStyleColor(ui.StyleColor.Text, colorTheme)
  if state.trackName and state.trackName ~= 'Nothing playing' then
    ui.beginGroup()

      -- Display album art if available
      local availableHeight = ui.availableSpaceY()
      custom_ui.drawVinylAlbumArt(state, dt, math.min(200, availableHeight - 10))

      if ac.windowFading() > 0.5 then
        if spotify.appSettings.showControls then
          ui.offsetCursorY(availableHeight * 0.05)
        else
          ui.offsetCursorY(availableHeight * 0.20)
        end
      else
        ui.offsetCursorY(availableHeight * 0.05)
      end
      -- Metadata on right
      ui.beginGroup()

        -- Title 
        ui.pushDWriteFont(DWRITE_FONT..';Weight=Bold;')
          ui.dwriteDrawText(state.trackName, 18, ui.getCursor(), colorTheme)
        ui.popDWriteFont()
        ui.offsetCursorY(26)

        -- Artist
        if state.artistName ~= '' then
          ui.pushDWriteFont(DWRITE_FONT)
            local colorThemeDimmed = colorTheme * rgbm(0.7, 0.7, 0.7, 0.8)
            ui.dwriteDrawText(state.artistName, 16, ui.getCursor(), colorThemeDimmed)
          ui.popDWriteFont()
          ui.offsetCursorY(24)
        end

        -- Display play progress
        if state.duration > 0 then
          local progressPercent = (state.progress / state.duration) * 100
          local durationMin = math.floor(state.duration / 1000 / 60)
          local durationSec = math.floor((state.duration / 1000) % 60)
          local progressMin = math.floor(state.progress / 1000 / 60)
          local progressSec = math.floor((state.progress / 1000) % 60)
          ui.text(string.format('Progress: %d:%02d / %d:%02d', 
            progressMin, progressSec, durationMin, durationSec))
          custom_ui.drawProgressBar(progressPercent / 100, vec2(ui.availableSpaceX(), 5), colorTheme, 
          function (percent)
            local newProgress = percent * state.duration
            spotify.Seek(newProgress)
            state.progress = newProgress
          end)
        end

        -- Controls
        if spotify.appSettings.showControls or ac.windowFading() < 0.5 then
          ui.pushFont(ui.Font.Main)
          if ui.iconButton('controls/prev.png', vec2(24, 24)) then
            spotify.prevTrack()
          end
          ui.sameLine()
          if state.isPlaying then
            if ui.iconButton('controls/pause.png', vec2(32, 24)) then
              spotify.pause()
            end
          else
            if ui.iconButton('controls/play.png', vec2(32, 24)) then
              spotify.play()
            end
          end
          ui.sameLine()
          if ui.iconButton('controls/next.png', vec2(24, 24)) then
            spotify.nextTrack()
          end
          ui.sameLine()
          local likeLabel = state.isLiked and '♥' or '♡'
          if ui.button(likeLabel..'##Like', vec2(32, 24)) then
            if state.isLiked then
              spotify.unlikeTrack()
            else
              spotify.likeTrack()
            end
          end
          ui.popFont()

          -- Volume control
          local value, changed = ui.slider('##VolumeSlider', state.volume, 0, 100, 'Volume: %.0f%%')
          if changed then
            state.volume = value
            volumeChanged = true
          end

          -- Spotify track URL
          if spotify.appSettings.showLink and state.trackUrl ~= '' then
            ui.copyable(state.trackUrl)
          end

        end

      ui.endGroup()
    ui.endGroup()

  else
    -- No track playing, show placeholder
    ui.beginGroup()
      local availableHeight = ui.availableSpaceY()
      local imageSize = math.min(64, availableHeight - 20)
      ui.image("icon.png", vec2(imageSize, imageSize))
      ui.sameLine()
      ui.beginGroup()
        ui.pushFont(ui.Font.Title)
        ui.offsetCursorY(15)
        ui.offsetCursorX(10)
        ui.textWrapped(state.trackName)
        ui.popFont()
        ui.offsetCursorY(5)
      ui.endGroup()
    ui.endGroup()
  end
  ui.popStyleColor()
end

function script.windowSettings(dt)
  local config = spotify.getOauthConfig()
  ac.debug('__clientId: ', config.clientId)
  ac.debug('__clientSecret: ', config.clientSecret)
  ac.debug('__refreshToken: ', config.refreshToken)
  ac.debug('__accessToken: ', config.accessToken)
  ac.debug('___tokenExpiry: ', config.tokenExpiry)
  ac.debug('___currentTime', os.time())
  ac.debug('___diff', config.tokenExpiry - os.time())
  
  ui.text('Spotify API')
  ui.separator()
  if config.refreshToken == '' then
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

        if not spotify.authServerRunning then
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
          os.openURL(authUrl, false)
          authUrl = nil
        end
        ui.textWrapped('Click the button above and authorize the app')      
      end

      if spotify.authServerRunning then
        authUrlGenerated = false
      end

      if not spotify.authServerRunning and authUrlGenerated then
        ui.setNextItemWidth(ui.availableSpaceX() * 0.7)
        spotifyAuthCodeInput = ui.inputText('##authCode', spotifyAuthCodeInput)
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
  end
  
  if config.refreshToken ~= '' then
    ui.pushStyleColor(ui.StyleColor.Text, rgbm(0, 1, 0, 1))
    ui.text('Status: Authenticated ✅')
    ui.text('Refreshing Token in '..math.floor((config.tokenExpiry - os.time()) / 60)..' minutes')
    ui.popStyleColor()
    
    if ui.button('Clear Authentication', vec2(ui.availableSpaceX(), 0)) then
      config.refreshToken = ''
      config.accessToken = ''
      ui.toast(ui.Icons.Info, 'Authentication cleared')
    end
    
    if ui.button('Refresh Access Token', vec2(ui.availableSpaceX(), 0)) then
      ui.toast(ui.Icons.Info, 'Refreshing access token...')
      spotify.retries = 0
      spotify.refreshAccessToken()
    end
  else
    ui.pushStyleColor(ui.StyleColor.Text, rgbm(1, 1, 0, 1))
    ui.text('Status: Not Authenticated')
    ui.popStyleColor()
    
    ui.separator()
    if spotify.authServerRunning then
      ui.pushStyleColor(ui.StyleColor.Text, rgbm(0, 1, 0, 1))
      ui.textWrapped('Auth server is running. Please complete the authentication steps above.')
      ui.popStyleColor()
    else
      ui.textWrapped('Auth server is not running. Click "Generate Auth URL" to start it and follow the steps above.')
    end
  end

  ui.text('Settings')
  ui.separator()

  ac.debug('_showLink: ', spotify.appSettings.showLink)
  ac.debug('_showControls: ', spotify.appSettings.showControls)

  if ui.checkbox('Show Spotify Link', spotify.appSettings.showLink) then
    spotify.appSettings.showLink = not spotify.appSettings.showLink
  end

  if ui.checkbox('Always Show Track Controls', spotify.appSettings.showControls) then
    spotify.appSettings.showControls = not spotify.appSettings.showControls
  end

  if ui.checkbox('Only Show on Hover', spotify.appSettings.showOnHover) then
    spotify.appSettings.showOnHover = not spotify.appSettings.showOnHover
  end

  ui.text("App Color Theme")
  ui.separator()

  if ui.colorButton("Color", colorTheme) then
    ui.openPopup("picker")
  end
  ui.sameLine()
  ui.text("Pick a color theme for the app")

  if ui.beginPopup("picker") then
      colorThemeChanged = ui.colorPicker("picker_color", colorTheme)
      ui.endPopup()
  end

  if colorThemeChanged then
    spotify.appSettings.colorTheme = colorTheme
    colorThemeChanged = false
  end

end

function script.windowQueue(dt)
  ui.text('Queue')
  ui.separator()
  if ui.button('Refresh Queue', vec2(ui.availableSpaceX(), 0)) then
    spotify.GetQueue()
  end

  ui.beginGroup()
  if spotify.playbackState.queue and #spotify.playbackState.queue > 0 then
    for i, item in ipairs(spotify.playbackState.queue) do
      ui.image(item.albumArtUrl or 'icon.png', vec2(32, 32))
      ui.sameLine()
      --ui.text(string.format('%d. %s - %s', i, item.trackName, item.artistName))
      ui.beginGroup()
        ui.text(item.trackName)
        ui.text(item.artistName)
      ui.endGroup()
      ui.separator()
    end
  else
    ui.text('Queue is empty or not available.')
  end
  ui.endGroup()
end