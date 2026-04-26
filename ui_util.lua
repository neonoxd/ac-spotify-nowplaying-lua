
local custom_ui = {}

--[[
  Progress bar workaround for CSP 0.3.0-preview302
]]
local bgGray = rgbm(0.25, 0.22, 0.22, 1)
local cursorPos = vec2(0, 0)
local progressVect2 = vec2(0, 0)
local progressSizeVect2 = vec2(0, 0)
function custom_ui.drawProgressBar(value, size, color, onClick)
  cursorPos:set(ui.getCursor())
  ui.drawRectFilled(cursorPos, cursorPos + size, bgGray, 3)
  local progress = 0
  if value > 0 then
    progress = size.x * value
    progressVect2:set(progress, size.y)
    cursorPos:add(progressVect2, progressSizeVect2)
    ui.drawRectFilled(cursorPos, progressSizeVect2, color, 3)
  end
  ui.offsetCursorY(size.y + 10)

  -- overlay clickable area
  ui.setCursor(cursorPos)
  ui.invisibleButton('progress_click', size)
  if ui.itemHovered() then
    ui.setMouseCursor(ui.MouseCursor.Hand)
    -- Draw circle on bar
    local mouseX = ui.mouseLocalPos().x
    local circleX = math.clamp(mouseX, cursorPos.x, cursorPos.x + size.x)
    ui.drawCircleFilled(vec2(circleX, cursorPos.y + size.y / 2), size.y * 0.8, color, 16)
  end
  if ui.itemClicked(ui.MouseButton.Left) and onClick then
    local mouseX = ui.mouseLocalPos().x
    local percent = math.clamp((mouseX - cursorPos.x) / size.x, 0, 1)
    onClick(percent)
  end
end

-- Callback-safe progress bar for UI callbacks (manual hit-test, no invisibleButton).
function custom_ui.drawProgressBarHitTest(value, size, color, onClick, options)
  options = options or {}

  local barPos = ui.getCursor()
  local barEnd = barPos + size

  ui.drawRectFilled(barPos, barEnd, bgGray, options.rounding or 3)

  local progress = math.clamp(value or 0, 0, 1)
  if progress > 0 then
    local fillEnd = vec2(barPos.x + size.x * progress, barPos.y + size.y)
    ui.drawRectFilled(barPos, fillEnd, color, options.rounding or 3)
  end

  local mouse = ui.mouseLocalPos()
  local hasMouse = mouse.x >= 0 and mouse.y >= 0
  local hovered = hasMouse
    and mouse.x >= barPos.x and mouse.x <= barEnd.x
    and mouse.y >= barPos.y and mouse.y <= barEnd.y

  if hovered then
    ui.setMouseCursor(ui.MouseCursor.Hand)

    if options.showHandle ~= false then
      local circleX = math.clamp(mouse.x, barPos.x, barEnd.x)
      ui.drawCircleFilled(vec2(circleX, barPos.y + size.y / 2), size.y * 0.8, color, 16)
    end

    if ui.mouseClicked(ui.MouseButton.Left) and onClick then
      local percent = math.clamp((mouse.x - barPos.x) / size.x, 0, 1)
      onClick(percent, hovered)
    end

    if ui.mouseDown(ui.MouseButton.Left) and options.onDrag then
      local percent = math.clamp((mouse.x - barPos.x) / size.x, 0, 1)
      options.onDrag(percent, hovered)
    end
  end

  ui.offsetCursorY(size.y + (options.spacingY or 10))
  return hovered
end

local vinylAngle = 0
local vinylDir = 1
local vinylSpeed = 25
local vinylSpeeds = {25, 50, 75, 100}
function custom_ui.drawVinylAlbumArt(state, dt, size)
  local artPath = state.albumArtUrl ~= '' and ui.isImageReady(state.albumArtUrl) and state.albumArtUrl or 'images/vinyl.png'

  local cursor = ui.getCursor()
  local radius = size / 2
  local center = vec2(cursor.x + radius, cursor.y + radius)

  if state.isPlaying then
    vinylAngle = (vinylAngle + dt * vinylSpeed * vinylDir) % 360
  end

  -- rotation captures all draw calls until endPivotRotation
  ui.beginRotation()

  -- rounding = radius makes it a circle
  ui.drawImageRounded(artPath,
    cursor, vec2(cursor.x + size, cursor.y + size),
    rgbm(1, 1, 1, 1), vec2(0, 0), vec2(1, 1), radius)

  -- center hole
  ui.drawCircleFilled(center, radius * 0.10, rgbm(0.08, 0.08, 0.08, 1), 32)
  ui.drawCircle(center, radius, rgbm(0, 0, 0, 0.35), 64, 1.5)

  ui.endPivotRotation(vinylAngle, center)

  -- Overlay an invisible button of the same size
  ui.setCursor(cursor)
  ui.invisibleButton('vinyl_click', vec2(size, size))
  if ui.itemClicked(ui.MouseButton.Left) then
    vinylDir = -vinylDir
  elseif ui.itemClicked(ui.MouseButton.Right) then
    local currentIndex = 0
    for i, speed in ipairs(vinylSpeeds) do
      if speed == vinylSpeed then
        currentIndex = i
        break
      end
    end
    vinylSpeed = vinylSpeeds[(currentIndex % #vinylSpeeds) + 1]
  end

  -- advance cursor so sameLine() works correctly
  ui.setCursor(vec2(cursor.x + size + 8, cursor.y))
end

function custom_ui.drawNumberedBadge(position, number, badgeColor, textColor)
  local badgeRadius = 7
  local badgeCenter = position
  ui.drawCircleFilled(badgeCenter, badgeRadius, badgeColor, 12)
  ui.pushFont(ui.Font.Small)
  local countStr = tostring(number)
  local textSize = ui.measureText(countStr)
  ui.drawText(countStr, badgeCenter - textSize * 0.5, textColor or rgbm(1, 1, 1, 1))
  ui.popFont()
end

local scrollStates = {}
--[[
  Scrolling text for text that exceeds available width
  
  Parameters:
  - id: unique string identifier for this text element (used to track scroll state)
  - text: the text to display
  - fontSize: font size for dwriteDrawText
  - maxWidth: maximum width before scrolling kicks in
  - color: text color (rgbm)
  - dt: delta time for animation
  - font: (optional) DWrite font string, defaults to nil (uses current font)
  - scrollSpeed: (optional) pixels per second, defaults to 30
  - pauseDuration: (optional) seconds to pause at start/end, defaults to 2
  
  Returns: measured text height
]]
function custom_ui.drawScrollingText(id, text, fontSize, maxWidth, color, dt, font, scrollSpeed, pauseDuration)
  scrollSpeed = scrollSpeed or 30
  pauseDuration = pauseDuration or 2
  
  -- Measure text
  local textSize
  if font then
    ui.pushDWriteFont(font)
    textSize = ui.measureDWriteText(text, fontSize)
    ui.popDWriteFont()
  else
    textSize = ui.measureDWriteText(text, fontSize)
  end
  
  local cursor = ui.getCursor()
  
  -- If text fits, just draw it normally
  if textSize.x <= maxWidth then
    if font then ui.pushDWriteFont(font) end
    ui.dwriteDrawText(text, fontSize, cursor, color)
    if font then ui.popDWriteFont() end
    return textSize.y
  end
  
  -- Initialize scroll state for this id
  if not scrollStates[id] then
    scrollStates[id] = {
      offset = 0,
      direction = 1, -- 1 = scrolling left, -1 = scrolling right
      pauseTimer = pauseDuration,
      lastText = text,
    }
  end
  
  local state = scrollStates[id]
  
  -- Reset if text changed
  if state.lastText ~= text then
    state.offset = 0
    state.direction = 1
    state.pauseTimer = pauseDuration
    state.lastText = text
  end
  
  -- Calculate max scroll offset (how far we need to scroll)
  local maxOffset = textSize.x - maxWidth
  
  -- Update scroll animation
  if state.pauseTimer > 0 then
    state.pauseTimer = state.pauseTimer - dt
  else
    state.offset = state.offset + scrollSpeed * dt * state.direction
    
    -- Reverse direction at boundaries
    if state.offset >= maxOffset then
      state.offset = maxOffset
      state.direction = -1
      state.pauseTimer = pauseDuration
    elseif state.offset <= 0 then
      state.offset = 0
      state.direction = 1
      state.pauseTimer = pauseDuration
    end
  end
  
  -- Draw with clipping
  ui.pushClipRect(cursor, vec2(cursor.x + maxWidth, cursor.y + textSize.y + 4))
  
  local drawPos = vec2(cursor.x - state.offset, cursor.y)
  if font then ui.pushDWriteFont(font) end
  ui.dwriteDrawText(text, fontSize, drawPos, color)
  if font then ui.popDWriteFont() end
  
  ui.popClipRect()
  
  return textSize.y
end

-- Manual hit-test button for draw callbacks where regular UI widgets might not receive clicks.
function custom_ui.drawHitTestButton(position, size, drawFn, onClick)
  
  local p1 = vec2(position.x + size.x, position.y + size.y)
  local mouse = ui.mouseLocalPos()
  local hasMouse = mouse.x >= 0 and mouse.y >= 0
  local hovered = hasMouse
    and mouse.x >= position.x and mouse.x <= p1.x
    and mouse.y >= position.y and mouse.y <= p1.y
  local pressed = hovered and ui.mouseDown(ui.MouseButton.Left)

  if drawFn then
    drawFn(position, p1, hovered, pressed)
  end

  if hovered then
    ui.setMouseCursor(ui.MouseCursor.Hand)
    if ui.mouseClicked(ui.MouseButton.Left) and onClick then
      onClick(position, p1, mouse)
    end
  end

  return hovered, pressed
end

return custom_ui