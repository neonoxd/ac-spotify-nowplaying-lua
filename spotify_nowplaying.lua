local spotify = require('spotify')
local custom_ui = require('ui_util')

local REFRESH_INTERVAL = 5 -- seconds between API calls
local VOLUME_UPDATE_INTERVAL = 1 -- seconds between checking if we should update volume
local DWRITE_FONT = "Arial Unicode MS"
local COLOR_LERP_SPEED = 3 -- how fast color transitions (higher = faster)

-- Helper function to lerp between two RGBM colors
local function lerpColor(current, target, t)
  if not current or not target then return target or current end
  return rgbm(
    current.r + (target.r - current.r) * t,
    current.g + (target.g - current.g) * t,
    current.b + (target.b - current.b) * t,
    current.mult + (target.mult - current.mult) * t
  )
end

local spotifyRefreshTimer = REFRESH_INTERVAL + 1

local spotifyVolumeTimer = 0
local volumeChanged = false
local volumeTarget = -1

local spotifyAuthCodeInput = ''
local authUrl = nil
local authUrlGenerated = false

-- Color theme
local colorTheme = spotify.appSettings.colorTheme
local colorThemeTarget = spotify.appSettings.colorTheme

-- Sharing
local receivedTracks = {}
local SHARE_COOLDOWN = 2
local timeSinceShare = 0

-- Album name swapping
local albumSwapTimer = 0

local chatMessageEvent = nil
local sim = ac.getSim()
if sim.isOnlineRace then

  chatMessageEvent = ac.OnlineEvent({
    spotifySongId = ac.StructItem.string(),
    spotifySongTitle = ac.StructItem.string(128),
    spotifySongArtist = ac.StructItem.string(128),
    spotifyAlbumArtUrl = ac.StructItem.string(128),
  }, function (sender, data)
    ac.debug('Got message: from', sender and sender.index or -1)
    if sender.index == 0 or not spotify.appSettings.enableSharing then
      return
    end
    
    table.insert(receivedTracks, {
      id = data.spotifySongId,
      title = data.spotifySongTitle,
      artist = data.spotifySongArtist,
      albumArtUrl = data.spotifyAlbumArtUrl,
      senderName = sender and sender:driverName() or 'Unknown',
    })
  end)

end

local function updateState(dt)
  local state = spotify.playbackState
  -- DEBUG
  ac.debug('..trackName: ', state.trackName)
  ac.debug('..artistName: ', state.artistName)
  ac.debug('..albumName: ', state.albumName)
  ac.debug('..isPlaying: ', state.isPlaying)
  ac.debug('..duration: ', state.duration)
  ac.debug('..progress: ', state.progress)
  ac.debug('..error: ', state.error)
  ac.debug('..volume: ', state.volume)
  ac.debug('..dominantColor: ', state.dominantColor)
  ac.debug('..currently_playing_type: ', state.type)

  -- Fetch current track every REFRESH_INTERVAL seconds
  spotifyRefreshTimer = spotifyRefreshTimer + dt
  if spotifyRefreshTimer > REFRESH_INTERVAL then
    spotify.getPlaybackState()
    spotifyRefreshTimer = 0
  end

  albumSwapTimer = albumSwapTimer + dt
  if albumSwapTimer > 10 then
    albumSwapTimer = 0
  end

  -- Update progress locally for smoother UI
  if state.isPlaying then
    state.progress = state.progress + (dt * 1000)
    state.progress = math.min(state.progress, state.duration)
  end

  -- Reset share timer after 10 seconds to prevent overflow
  timeSinceShare = timeSinceShare + dt
  if timeSinceShare > 10 then
    timeSinceShare = SHARE_COOLDOWN
  end
end

local function updateVolume(dt)
  spotifyVolumeTimer = spotifyVolumeTimer + dt
  -- Update volume every VOLUME_UPDATE_INTERVAL seconds
  if spotifyVolumeTimer > VOLUME_UPDATE_INTERVAL then
    if volumeChanged then
      spotify.setVolume(volumeTarget)
      volumeChanged = false
    end
    spotifyVolumeTimer = 0
  end
end

function script.windowMain(dt)
  
  local state = spotify.playbackState
  local config = spotify.getOauthConfig()
  
  -- Update target color and lerp towards it
  colorThemeTarget = spotify.appSettings.useAlbumColor and state.dominantColor or spotify.appSettings.colorTheme
  colorTheme = lerpColor(colorTheme, colorThemeTarget, math.min(1, dt * COLOR_LERP_SPEED))

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

  updateState(dt)
  updateVolume(dt)
  
  -- Display error if any
  if state.error ~= '' then
    ui.pushStyleColor(ui.StyleColor.Text, rgbm(1, 0.2, 0.2, 1))
    ui.textWrapped(state.error)
    ui.popStyleColor()
    return
  end

  if ac.windowFading() > 0.5 and spotify.appSettings.showOnHover then
    return
  end

  ui.pushStyleColor(ui.StyleColor.Text, colorTheme)
  if state.trackName and state.trackName ~= 'Nothing playing' then
    ui.beginGroup()

      -- Display album art if available
      local availableHeight = ui.availableSpaceY()
      local imageSize = math.min(200, math.max(120, availableHeight - 20))

      -- Height approximation, TODO: measure
      local noControlsHeight = 40
      local withControlsHeight = 70
      custom_ui.drawVinylAlbumArt(state, dt, imageSize)
      
      if ac.windowFading() > 0.5 then
        if spotify.appSettings.showControls then
          ui.offsetCursorY(imageSize / 2 - withControlsHeight)
        else
          ui.offsetCursorY(imageSize / 2 - noControlsHeight)
        end
      else
        ui.offsetCursorY(imageSize / 2 - withControlsHeight)
      end

      -- Badge if not focused
      if #receivedTracks > 0 and ac.windowFading() > 0.5 then
          local cursorPos = ui.getCursor()
          local badgeCenter = vec2(cursorPos.x, cursorPos.y)
          custom_ui.drawNumberedBadge(badgeCenter, #receivedTracks, rgbm(1, 0, 0, 1), rgbm(1, 1, 1, 1))
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
            if albumSwapTimer < 5 and state.type == 'episode' then
              ui.dwriteDrawText(state.albumName, 16, ui.getCursor(), colorThemeDimmed)
            else
              ui.dwriteDrawText(state.artistName, 16, ui.getCursor(), colorThemeDimmed)
            end
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
        if ui.itemHovered() then
            ui.setTooltip(state.isLiked and 'Unlike this track' or 'Like this track')
          end
          ui.popFont()

          if spotify.appSettings.enableSharing and sim.isOnlineRace then
            -- Align Right
            -- Share button
            ui.sameLine()
            ui.setCursorX(ui.getCursorX() + ui.availableSpaceX() - (24 + 24))
            if ui.iconButton('controls/share.png', vec2(24, 24)) then
              if timeSinceShare > SHARE_COOLDOWN and chatMessageEvent then
                chatMessageEvent{
                  spotifySongId = spotify.playbackState.trackId or '',
                  spotifySongTitle = spotify.playbackState.trackName or '',
                  spotifySongArtist = spotify.playbackState.artistName or '',
                  spotifyAlbumArtUrl = spotify.playbackState.albumArtUrl or '',
                }
                ui.toast(ui.Icons.Info, 'Song shared!')
                timeSinceShare = 0
              else
                ui.toast(ui.Icons.Warning, 'Please wait before sharing again')
              end
            end

            if ui.itemHovered() then
              ui.setTooltip('Share this song with other drivers in your session!')
            end
  
            -- Inbox button with badge
            ui.sameLine()
            local inboxPos = ui.getCursor()
            if ui.iconButton('controls/inbox.png', vec2(24, 24)) then
              ui.openPopup('receivedSharesPopup')
            end

            if ui.itemHovered() then
              ui.setTooltip('Select a song shared by other drivers to add it to your queue!')
            end

            -- Draw badge if there are received tracks
            if #receivedTracks > 0 then
              local badgeCenter = vec2(inboxPos.x + 20, inboxPos.y + 2)
              custom_ui.drawNumberedBadge(badgeCenter, #receivedTracks, rgbm(1, 0, 0, 1), rgbm(1, 1, 1, 1))
            end
          end

          -- Volume control
          local value, changed = ui.slider('##VolumeSlider', state.volume, 0, 100, 'Volume: %.0f%%')
          if changed then
            state.volume = value
            volumeTarget = value
            volumeChanged = true
          end

        end

      ui.endGroup()

      -- Render received tracks popup
      if ui.beginPopup('receivedSharesPopup') then
        ui.text('Received Tracks from Drivers:')
        if #receivedTracks == 0 then
          ui.separator()
          ui.text('No tracks received yet.')
        else
          for i, track in ipairs(receivedTracks) do
            ui.separator()
            local rowHeight = 50
            local cursor = ui.getCursor()

            -- Draw album art
            ui.image(track.albumArtUrl, vec2(rowHeight, rowHeight))

            -- Draw text next to artwork
            ui.setCursor(vec2(cursor.x + rowHeight + 8, cursor.y + 4))
            ui.pushDWriteFont(DWRITE_FONT..';Weight=Bold;')
              ui.dwriteDrawText(track.title, 14, ui.getCursor(), colorTheme)
            ui.popDWriteFont()

            ui.setCursor(vec2(cursor.x + rowHeight + 8, cursor.y + 22))
            ui.pushDWriteFont(DWRITE_FONT)
              -- artist name
              ui.dwriteDrawText(track.artist, 12, ui.getCursor(), colorTheme * rgbm(0.7, 0.7, 0.7, 0.8))
              -- sender name
              ui.offsetCursorY(16)
              ui.dwriteDrawText('Shared by: '..track.senderName, 10, ui.getCursor(), colorTheme * rgbm(0.7, 0.7, 0.7, 0.6))
            ui.popDWriteFont()

            -- Overlay a selectable on the entire row for click handling
            ui.setCursor(cursor)
            if ui.selectable('##track_'..i, false, 0, vec2(ui.availableSpaceX(), rowHeight)) then
              spotify.AddToQueue(track.id)
              ui.toast(ui.Icons.Info, 'Added ['..track.title..']'..' to the queue!')
              table.remove(receivedTracks, i)
            end
            if ui.itemHovered() then
              ui.setTooltip('Click to add to queue')
            end
          end
          ui.separator()
          if ui.menuItem('Clear List') then
            receivedTracks = {}
          end
        end
        ui.endPopup()
      end

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

  if ui.checkbox('Enable Song Sharing', spotify.appSettings.enableSharing) then
    spotify.appSettings.enableSharing = not spotify.appSettings.enableSharing
  end

  if ui.checkbox('Always Show Track Controls', spotify.appSettings.showControls) then
    spotify.appSettings.showControls = not spotify.appSettings.showControls
  end

  if ui.checkbox('Only Show on Hover', spotify.appSettings.showOnHover) then
    spotify.appSettings.showOnHover = not spotify.appSettings.showOnHover
  end

  ui.text("App Color Theme")
  ui.separator()

  if ui.checkbox('Use Album Art as Color theme', spotify.appSettings.useAlbumColor) then
    spotify.appSettings.useAlbumColor = not spotify.appSettings.useAlbumColor
  end

  if not spotify.appSettings.useAlbumColor then
    if ui.colorButton("Color", colorTheme) then
      ui.openPopup("picker")
    end
    ui.sameLine()
    ui.text("Pick a color theme for the app")
  end

  if ui.beginPopup("picker") then
      ui.colorPicker("picker_color", spotify.appSettings.colorTheme)
      ui.endPopup()
  end

end

function script.windowAlbum(dt)
  local state = spotify.playbackState
  local imageSize = math.min(ui.availableSpaceY(), ui.availableSpaceX())
  if spotify.extraSettings.albumArtMode == 'vinyl' then
    custom_ui.drawVinylAlbumArt(state, dt, imageSize)
  else
    if state.albumArtUrl and state.albumArtUrl ~= '' then
      ui.image(state.albumArtUrl, vec2(imageSize, imageSize))
    else
      ui.image("icon.png", vec2(imageSize, imageSize))
    end
  end
end

function script.windowProgress(dt)
  local state = spotify.playbackState
  local margin = 10
  local _colorTheme = spotify.extraSettings.useGlobalColors and colorTheme or spotify.extraSettings.colorThemeExtra
  
  -- Draw a rounded square for background if enabled
  if spotify.extraSettings.progressBarBackground then
    local cursorPos = ui.getCursor()
    local size = vec2(ui.availableSpaceX(), ui.availableSpaceY())

    local luminance = _colorTheme.r * 0.299 + _colorTheme.g * 0.587 + _colorTheme.b * 0.114
    local invertedColor = luminance > 0.7
      and rgbm(0, 0, 0, 0.6)      -- dark background
      or rgbm(1, 1, 1, 0.15)      -- light background
    local bgColor = spotify.extraSettings.progressBarBackgroundInvert and invertedColor or spotify.extraSettings.colorThemeExtraBg

    ui.drawRectFilled(cursorPos, vec2(cursorPos.x + size.x, cursorPos.y + size.y), bgColor, 8)
  end

  ui.beginGroup()

  ui.beginGroup()
    if spotify.extraSettings.showAlbumArt then
      -- Album Art
      ui.offsetCursor(margin)
      local artSize = ui.availableSpaceY() - margin
      if state.albumArtUrl and state.albumArtUrl ~= '' then
        local cursor = ui.getCursor()
        ui.drawImageRounded(state.albumArtUrl, cursor, cursor + vec2(artSize, artSize), 4)
        ui.offsetCursorX(artSize)
        
      else
        ui.image("icon.png", vec2(artSize, artSize))
      end
    end
  ui.endGroup()
  ui.sameLine()
  ui.beginGroup()
    -- metadata and progress bar
    if spotify.extraSettings.showSongDetails then
      local fontSize = spotify.extraSettings.songDetailsFontSize
      ui.offsetCursorY(margin - 4)
      -- Title 
      ui.pushDWriteFont(DWRITE_FONT..';Weight=Bold;')
        ui.dwriteDrawText(state.trackName, fontSize, ui.getCursor(), _colorTheme)
      ui.popDWriteFont()
      -- Todo: measure text height instead of hardcoding offset
      ui.offsetCursorY(ui.measureDWriteText(state.trackName, fontSize).y - 4)

      -- Artist
      if state.artistName ~= '' then
        ui.pushDWriteFont(DWRITE_FONT)
          local colorThemeDimmed = _colorTheme * rgbm(0.7, 0.7, 0.7, 0.8)
          if albumSwapTimer < 5 and state.type == 'episode' then
            ui.dwriteDrawText(state.albumName, fontSize - 2, ui.getCursor(), colorThemeDimmed)
          else
            ui.dwriteDrawText(state.artistName, fontSize - 2, ui.getCursor(), colorThemeDimmed)
          end
        ui.popDWriteFont()
        ui.offsetCursorY(ui.measureDWriteText(state.artistName, fontSize - 2).y)
      end
    end
    local progressPercent = state.duration > 0 and (state.progress / state.duration) * 100 or 0
    local durationMin = math.floor(state.duration / 1000 / 60)
    local durationSec = math.floor((state.duration / 1000) % 60)
    local progressMin = math.floor(state.progress / 1000 / 60)
    local progressSec = math.floor((state.progress / 1000) % 60)

    if spotify.extraSettings.progressBarLabel then
      ui.pushStyleColor(ui.StyleColor.Text, _colorTheme)
        ui.text(string.format('%d:%02d / %d:%02d', 
          progressMin, progressSec, durationMin, durationSec))
      ui.popStyleColor()
    else
      ui.offsetCursorY(margin)
    end
    custom_ui.drawProgressBar(progressPercent / 100, vec2(ui.availableSpaceX() - margin, ui.availableSpaceY() - margin), _colorTheme, 
      function (percent)
        local newProgress = percent * state.duration
        spotify.Seek(newProgress)
        state.progress = newProgress
      end)

  ui.endGroup()

  ui.endGroup()
end

function script.windowProgressSettings(dt)

  ui.textWrapped('Use global color theme:')
  ui.sameLine()
  if ui.checkbox('##UseGlobalColor', spotify.extraSettings.useGlobalColors) then
    spotify.extraSettings.useGlobalColors = not spotify.extraSettings.useGlobalColors
  end

  if not spotify.extraSettings.useGlobalColors then
    if ui.colorButton("Widget Color Theme", spotify.extraSettings.colorThemeExtra) then
      ui.openPopup("picker_w")
    end
    ui.sameLine()
    ui.text("Pick a color theme for the widget")
  end

  if ui.beginPopup("picker_w") then
      ui.colorPicker("widget_color", spotify.extraSettings.colorThemeExtra)
      ui.endPopup()
  end

  ui.separator()

  ui.textWrapped('Show song details on progress tab:')
  ui.sameLine()
  if ui.checkbox('##ShowDetails', spotify.extraSettings.showSongDetails) then
    spotify.extraSettings.showSongDetails = not spotify.extraSettings.showSongDetails
  end

  ui.separator()
  ui.textWrapped('Show progress bar label')
  ui.sameLine()
  if ui.checkbox('##ShowProgressLabel', spotify.extraSettings.progressBarLabel) then
    spotify.extraSettings.progressBarLabel = not spotify.extraSettings.progressBarLabel
  end

  ui.separator()
  ui.textWrapped('Show progress bar background:')
  ui.sameLine()
  if ui.checkbox('##ProgressBarBackground', spotify.extraSettings.progressBarBackground) then
    spotify.extraSettings.progressBarBackground = not spotify.extraSettings.progressBarBackground
  end

  if spotify.extraSettings.progressBarBackground then
      ui.separator()
      ui.textWrapped('Higher contrast background:')
      ui.sameLine()
      if ui.checkbox('##ProgressBarBackgroundInvert', spotify.extraSettings.progressBarBackgroundInvert) then
        spotify.extraSettings.progressBarBackgroundInvert = not spotify.extraSettings.progressBarBackgroundInvert
      end
    
      
      if ui.beginPopup("picker_bg") then
          ui.colorPicker("widget_background", spotify.extraSettings.colorThemeExtraBg)
          ui.endPopup()
      end
      
      if not spotify.extraSettings.progressBarBackgroundInvert then
        ui.separator()
        if ui.colorButton("Widget Background", spotify.extraSettings.colorThemeExtraBg) then
          ui.openPopup("picker_bg")
        end
        ui.sameLine()
        ui.text("Pick a color theme for the widget background")
      end
  end

  ui.separator()
  ui.textWrapped('Song details font size:')
  local fontSize, f_changed = ui.slider('##SongDetailsFontSize', spotify.extraSettings.songDetailsFontSize, 10, 48, '%.0f')
  if f_changed then
    spotify.extraSettings.songDetailsFontSize = fontSize
  end
  ui.separator()
  ui.textWrapped('Show album art')
  ui.sameLine()
  if ui.checkbox('##ShowAlbumArt', spotify.extraSettings.showAlbumArt) then
    spotify.extraSettings.showAlbumArt = not spotify.extraSettings.showAlbumArt
  end
end

local currentAlbumIndex = 1
function script.windowAlbumSettings(dt)
  local options = {'square', 'vinyl'}
  
  -- Find current selection
  for i, option in ipairs(options) do
    if spotify.extraSettings.albumArtMode == option then
      currentAlbumIndex = i
      break
    end
  end

  ui.textWrapped('Album Art Style:')
  local newIndex, changed = ui.combo('##AlbumArtMode', currentAlbumIndex, options)
  if changed then
    currentAlbumIndex = newIndex
    spotify.extraSettings.albumArtMode = options[newIndex]
  end
end