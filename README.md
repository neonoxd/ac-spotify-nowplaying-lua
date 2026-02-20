# Spotify Now Playing Lua App for Assetto Corsa CSP

Display current Spotify track information in Assetto Corsa.

https://github.com/user-attachments/assets/ced3df6f-4d0b-4505-b74e-303ea7de077d

# Download

[![Download](https://img.shields.io/badge/Download-Latest-blue)](https://github.com/neonoxd/ac-spotify-nowplaying-lua/releases/latest/download/spotify_nowplaying-windows.zip)
[![Download](https://img.shields.io/badge/Download_Without_Auth_Server-Latest-green)](https://github.com/neonoxd/ac-spotify-nowplaying-lua/releases/latest/download/spotify_nowplaying-source.zip)

## Features

- **Track Display**: Shows current track name, artist, album, and progress
- **Album Art**: Displays album artwork if available
- **Show Spotify Link**: Enable in settings to show copyable track URL to share
- **Track Controls**: Allows changing tracks and volume
- **Easy authentication**: Using refresh token you'll only have to authenticate once and it will automatically be refreshed

## Setup

1. **Get Spotify API Credentials**
   - Visit https://developer.spotify.com/dashboard
   - Create a new app
   - Copy your Client ID and Client Secret
   - Add `http://127.0.0.1:8888/callback` redirect URI under Basic Information

2. **Configure the app**
   - Open `settings.ini`
   - Enter your Client ID and Client Secret
   - Save the file

3. **Authenticate**
   - Open the app settings in Assetto Corsa
   - Click "Generate Auth URL"
   - Click "Open Auth URL in Browser"
   - Log in and authorize your app
   - If you have compiled or downloaded the auth server you should be authenticated automatically
   - Otherwise you have to copy the auth code from the browser
        - Paste it into `Auth Code` field
        - Click `Exchange Code for Token` to authenticate


## Building

1. Install Go
   - Download from https://golang.org/dl/
   - Add to your system PATH

2. Build the auth server:

```bash
cd external
.\build_auth_server.bat
```

## Troubleshooting

- **"Go compiler not found"**: Install Go and add it to your PATH
- **Auth fails**: Check your Client ID and Client Secret in `settings.ini`
- **Invalid Auth Code**: If you are doing manual authentication you need to enter the auth code quickly otherwise it expires
- **No track info**: Make sure Spotify is playing and the API credentials are correct
