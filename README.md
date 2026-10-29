# Minamp

A tiny always-on-top Spotify controller for macOS. Shrink it to any size; rest the mouse on it for half a second and it grows into a full player with your playlists, liked songs and search. Move the mouse away and it shrinks back.

- **Playback** (play/pause, skip, seek, volume, shuffle, repeat, play a song or playlist) drives the Spotify desktop app over AppleScript. No login is needed.
- **Browsing** uses the Spotify Web API (PKCE sign-in, loopback redirect `http://127.0.0.1:8973/callback`). It needs a Spotify developer app's Client ID; the app walks you through it the first time it opens. The refresh token is kept in the login keychain.

## Use
- Drag anywhere on the strip to move it; drag its edges to resize. Size and position are remembered.
- Click the strip to expand it right away.
- Right-click for Keep Expanded, Open at Login, Disconnect and Quit.

## Build
```bash
./build.sh --open
```
Builds with the Command Line Tools (no Xcode needed), signs ad hoc and installs to `~/Applications/Minamp.app`. After a rebuild macOS may ask again to let Minamp control Spotify and read its keychain item.
