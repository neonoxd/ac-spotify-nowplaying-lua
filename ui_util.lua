
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

return custom_ui