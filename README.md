# Spotify Now Playing Lua App for Assetto Corsa CSP

Display current Spotify track information in Assetto Corsa.

https://github.com/user-attachments/assets/ced3df6f-4d0b-4505-b74e-303ea7de077d

## Setup

1. **Install Go** (optional, needed for auth server)
   - Download from https://golang.org/dl/
   - Add to your system PATH

2. **Get Spotify API Credentials**
   - Visit https://developer.spotify.com/dashboard
   - Create a new app
   - Copy your Client ID and Client Secret
   - Add `http://127.0.0.1:8888/callback` redirect URI under Basic Information

3. **Configure the app**
   - Open `settings.ini`
   - Enter your Client ID and Client Secret
   - Save the file

4. **Authenticate**
   - Open the app settings in Assetto Corsa
   - Click "Generate Auth URL"
   - Click "Open Auth URL in Browser"
   - Log in and authorize your app
   - If you have compiled the auth server you should be authenticated automatically
   - Otherwise you have to copy the auth code from the browser
        - Paste it into `Auth Code` field
        - Click `Exchange Code for Token` to authenticate

## Usage

- **Track Display**: Shows current track name, artist, album, and progress
- **Album Art**: Displays album artwork if available
- **Show Spotify Link**: Enable in settings to show clickable track URL
- **Manual Refresh**: Access token auto-refreshes when needed

## Building

To build the auth server:

```bash
cd external
.\build_auth_server.bat
```

## Troubleshooting

- **"Go compiler not found"**: Install Go and add it to your PATH
- **Auth fails**: Check your Client ID and Client Secret in `settings.ini`
- **No track info**: Make sure Spotify is playing and the API credentials are correct
