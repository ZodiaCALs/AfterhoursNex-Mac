# AfterhoursNex for Mac

*How many times do I have left to see you again in my life?*

A podcast player for the late hours, as a native Mac app. It's written in Swift with SwiftUI and the Mac's own frameworks, and it's designed in Liquid Glass as macOS 27 refines it.

## What it does

- **Listen:**
  - **Playback:** speeds from 0.5× to 3× that keep voices natural, a sleep timer, your place remembered in every episode, and the next one played after.
  - **System controls:** Now Playing in the menu bar and Control Center, and your keyboard's media keys.
  - **The player bar:** a floating glass bar at the bottom of the window, with the transport, a slim scrubber, speed, captions, sleep, and full-window Now Playing.
  - **Shortcuts:** the Controls menu has Space to play and pause, ⌘← and ⌘→ to skip back 15 and forward 30, ⌥⌘→ for the next episode, and ⌥⌘= and ⌥⌘− to change the speed. ⌘[ goes back.
- **Find:**
  - **The starter shelf:** thirty hand-picked shows on your shelf the first time you open the app.
  - **Discover:** the full catalogue by category.
  - **Search:** for shows, or for single episodes on any topic, with a preview before you add anything.
  - **Radio:** public FM and AM stations by region.
  - **Video podcasts:** YouTube and Bilibili, as audio.
- **Read along:**
  - **Captions:** from the show's transcript or a caption file, or made on your Mac. They roll as the episode plays.
  - **The speech model:** choose it in Settings › Captions. SpeechAnalyzer is Apple's newer model for long recordings, with language models macOS downloads once. Classic speech recognition knows the most languages. Automatic picks between them for each language.
  - **Translation:** on your Mac, with Apple's translation. macOS downloads and manages the languages.
- **Your library:**
  - **Arranging:** rename, pin, group and drag shows into order, with covers you choose or design. Edit › Undo (⌘Z) brings back a show you removed.
  - **Moving things in:** import audio files, or drop them on the window. File › Import and Export OPML moves your shows from another app, or to one.
- **On your phone:**
  - **In a browser:** phones on the same Wi-Fi can use AfterhoursNex in their browser, through a private link and a QR code.
  - **The AfterhoursNex Android app:** it can use this Mac's auto captions and video podcasts.
- **In your language:** English, 简体中文 and 日本語.

## Design

The layout follows AfterhoursNex 1.2.0, with its motion:
- **The sidebar:** the Auto captions switch at the bottom.
- **Playback:** the player bar at the bottom, and Now Playing over the whole window.
- **Motion:** pages rise into place on 1.2.0's Fluent curve, and shows and previews zoom in gently.

The pages are set like Apple Music's:
- **Pages and shelves:** large titles, and horizontal shelves that snap.
- **Artwork:** it lifts under the pointer and shows a play button.
- **Show pages:** headers tinted with the cover's own colour.

The design follows Apple's guidance for Liquid Glass, with macOS 27's refinements for readability:
- **Glass for controls only:** the floating sidebar, the player bar, and the controls in Now Playing are glass. Text never sits on glass.
- **Hero art:** a show's artwork extends softly under the sidebar.
- **Your choice of glass:** Regular or Clear, in Settings › General. Settings opens with ⌘,. With Reduce Transparency on in System Settings, every control is solid.

## Requirements

- **To run it:** macOS 26 Tahoe or later.
- **To build it:** Xcode 26 or later. Build with the newest Xcode to get macOS 27's refinements.
