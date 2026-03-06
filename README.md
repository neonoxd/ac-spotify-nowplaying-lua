# Spotify Now Playing Lua App for Assetto Corsa CSP

Display current Spotify track information and control in Assetto Corsa.

https://github.com/user-attachments/assets/fad691bc-b005-4a79-ae81-aca7c9de8487

# Download

[![Download](https://img.shields.io/badge/Download-Latest-blue)](https://github.com/neonoxd/ac-spotify-nowplaying-lua/releases/latest/download/spotify_nowplaying-windows.zip)
[![Download](https://img.shields.io/badge/Download_Without_Auth_Server-Latest-green)](https://github.com/neonoxd/ac-spotify-nowplaying-lua/releases/latest/download/spotify_nowplaying-source.zip)

## Features

- **Track Display**: Shows current track information with album art
- **Show Spotify Link**: Enable in settings to show copyable track URL to share
- **Track Controls**: Change tracks, volume, seek, like/unlike songs
- **Easy authentication**: Using refresh token you'll only have to authenticate once and it will automatically be refreshed

## Setup

1. **Get Spotify API Credentials**
   - Visit https://developer.spotify.com/dashboard
   - Create a new app
   - When asked "Which API/SDKs are you planning to use?" Make sure to check **Web API**
   - Copy your Client ID and Client Secret
   - Add `http://127.0.0.1:9876/callback` redirect URI under Basic Information

2. **Configure the app**
   - Open `settings.ini`
   - Enter your Client ID and Client Secret
   - Save the file

3. **Authenticate**
   - Open the app settings in Assetto Corsa
   - Click "Generate Auth URL"
   - Click "Open Auth URL in Browser"
   - Log in and authorize your app
   - You should be authenticated automatically
   - Otherwise you have to copy the auth code from the browser (the part after `&code=` in the URL)
        - Paste it into `Auth Code` field
        - Click `Exchange Code for Token` to authenticate

## Troubleshooting

- **Auth fails**: Check your Client ID and Client Secret in `settings.ini`
- **Invalid Auth Code**: If you are doing manual authentication you need to enter the auth code quickly otherwise it expires
- **No track info**: Make sure Spotify is playing and the API credentials are correct

## Support
You can report issues over on overtake.gg https://www.overtake.gg/downloads/spotify-now-playing-lua-app.82575/

Or by opening Github [Issues](https://github.com/neonoxd/ac-spotify-nowplaying-lua/issues) 

## Special thanks
- Ligneel: Help with oauth/webserver simplification
- DaZD: Progress bar workaround for CSP 0.3.0-preview302
