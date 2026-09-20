# ZXTouch Rootless

Rootless and roothide port of ZXTouch for iOS 15 to 17, maintained by [Epic0001](https://github.com/Epic0001/zxtouchrootless).

A system-wide touch simulation library for iOS. It simulates touches, plays back recordings, and runs automation scripts without injecting into any app process.

Forked from [IOS13-SimulateTouch](https://github.com/xuan32546/IOS13-SimulateTouch) by xuan32546.

Discord: https://discord.gg/acSXfyz

---

## Compatibility

| Jailbreak | iOS | Status |
|-----------|-----|--------|
| Roothide / Serotonin | 15.8, 16.6.1 | Working |
| Dopamine (rootless) | 16.4.1, 16.6.1 | Working |
| NathanLR (rootless, semi-untethered) | 16.5.1 to 16.6.1 | Working, install `_rootless.deb` |
| Dopamine 3 (rootless) | 17.0 to 17.7 | Working, tested on 17.6 |
| Dopamine 3 (rootless) | 18.x | Untested |

iOS 17 is tested on an iPad 7th generation running 17.6 with Dopamine 3 and ElleKit.

iOS 18 has not been tested. The same rootless build should install, since Dopamine 3 uses the same bootstrap layout, but nothing on 18 has been verified. Reports are welcome in Discord or the issue tracker.

---

## What this fork changes

Compared to the original ZXTouch:

- Runs on iOS 15 to 17 under rootless (Dopamine, Dopamine 3, NathanLR) and roothide (Serotonin)
- `image_match` rebuilt on `Accelerate.framework`, so OpenCV is gone and the package stays small
- Color picker, color searcher, OCR, and volume-down stop all work again
- Python scripts auto-detect Procursus Python 3.8 to 3.12, prefer versioned interpreters over the `python3` symlink, and report real tracebacks
- Adds a rebuilt panel and script browser, dark mode, a recording editor, a remote dashboard, iOS Shortcuts actions, and button-pattern automation triggers
- The "Script Finished" popup can be turned off in Settings, then Script

---

## Requirements

Python 3 from Procursus is required for `.py` scripts on every jailbreak. Install it from Sileo by searching for `python3`. ZXTouch no longer ships its own runtime: the bundled `python3.7` aborted at dyld load on rootless because its libpython dylib pointed at a `/usr/lib` path that does not exist there.

Dopamine and Dopamine 3 (rootless):

- iOS 15.0 to 17.7
- [Dopamine](https://ellekit.space/dopamine/), with Dopamine 3 for iOS 17

NathanLR (rootless, iOS 16.5.1 to 16.6.1):

- Semi-untethered, so reopen the [NathanLR](https://www.nathanlr.com/) app after each reboot to reactivate tweaks
- Install the `_rootless.deb`, because NathanLR uses the rootless bootstrap under `/var/jb` rather than roothide

Roothide and Serotonin:

- iOS 15.0 to 16.6.1
- [Serotonin](https://github.com/roothide/Serotonin) or another roothide-compatible jailbreak

---

## Installation

From GitHub releases:

1. Download the latest `.deb` from [Releases](https://github.com/Epic0001/zxtouchrootless/releases). Use `*_rootless.deb` for Dopamine and NathanLR, or `*_roothide.deb` for Roothide and Serotonin.
2. Install it with Filza, or over SSH:

```sh
dpkg -i <file>.deb && killall -9 SpringBoard
```

From GitHub Actions, for the latest build:

1. Open [Actions](https://github.com/Epic0001/zxtouchrootless/actions)
2. Open the most recent successful run
3. Download the `ZXTouch-rootless-deb` or `ZXTouch-roothide-deb` artifact

---

## Demo videos (original)

Remote controlling:
[![Watch the video](img/remote_control_demo.jpg)](https://youtu.be/gdSGO6rJIL4)

Instant controlling (PUBG Mobile):
[![Watch the video](img/pubg_mobile_demo.jpg)](https://youtu.be/XvvWHL6B3Tk)

Recording and playback:
[![Watch the video](img/record_playback.jpg)](https://youtu.be/WeYMx4z8N2M)

Demo #4: [OCR](https://youtu.be/xt4BvgsSGkc)

Demo #5: [Touch Indicator](https://youtu.be/AU7zG_-W2tM)

Demo #6: [Color Picker](https://youtu.be/tserB05_B9E)

---

## Usage

After installation the tweak listens on port 6000. Send commands in the defined format from any language. A Python client is included for convenience.

### Panel (volume button)

Double-click volume down to open or close the panel.

- Tap a script to run it immediately
- Open the settings popup first to set repeat count, speed, and interval before running
- REC starts a touch recording
- STOP ends whichever is running, a recording or a script
- Settings, then Dark Mode, toggles the dark theme for both the app and the panel

### Scripts and examples

Example scripts install with the `.deb` under `/var/mobile/Library/ZXTouch/scripts/examples/`.

The app keeps a script registry at `/var/mobile/Library/ZXTouch/config/tweak/script_registry.plist`, which it uses for script metadata, icons, README previews, and trigger script selection.

### Recording editor

Tap a `.bdl` bundle whose entry file is a raw recording to open its timeline editor. From there you can:

- Tap a step to edit its coordinates, delay, toast text, app identifier, or raw command
- Reorder steps in edit mode
- Swipe a step to duplicate it, or delete unwanted steps
- Insert a tap, swipe, wait, toast, or app launch
- Save the recording and play the edited result immediately

### Remote dashboard

Enable Settings, then Web Server, and tap the dashboard URL row to copy the private address. Open that address from a phone, tablet, or computer on the same Wi-Fi network.

Scripts searches and filters the library, runs or stops scripts, downloads entries, and controls recording. Assets uploads files such as image-matching templates into a selected script bundle. Logs follows, filters, copies, exports, or clears runtime output. Device shows live service state, display size, orientation, battery, foreground app, and server diagnostics.

The URL contains a private access token. Do not share it outside your local network. Dashboard hosting runs inside SpringBoard, so it remains available when the ZXTouch app is closed.

### Automation triggers

Open Settings, then Automation, in the app to assign actions to button click patterns. Volume Up, Volume Down, and the Home Button can each be set to 1-5 clicks and run Smart Toggle, Toggle Panel, Stop Script, Toggle Recording, or a selected `.bdl` script.

---

## Documentation (Python)

### Installation

On an iOS device, the ZXTouch Python module installs with the `.deb`.

On a computer, for remote control, copy the `zxtouch` folder from [`layout/usr/lib/python3.7/site-packages`](https://github.com/xuan32546/IOS13-SimulateTouch/tree/0.0.6/layout/usr/lib/python3.7/site-packages) to your Python `site-packages` directory.

### Create a ZXTouch instance

```python
from zxtouch.client import zxtouch
device = zxtouch("127.0.0.1")  # use device IP for remote control
```

---

## Instance methods

### API status

| Method | Status |
|--------|--------|
| `touch` / `touch_with_list` | Working |
| `switch_to_app` | Working |
| `show_alert_box` | Working |
| `prompt_input` | Working |
| `run_shell_command` | Working |
| `show_toast` | Working |
| `pick_color` | Working |
| `search_color` | Working |
| `accurate_usleep` | Working |
| `play_script` / `force_stop_script_play` | Working |
| `get_screen_size` / `get_screen_orientation` / `get_screen_scale` | Working |
| `get_device_info` / `get_battery_info` | Working |
| `start_touch_recording` / `stop_touch_recording` | Working |
| `ocr` / `get_supported_ocr_languages` | Working |
| `image_match` | Working (Accelerate.framework, no OpenCV) |
| `screenshot` | Working (direct in-memory JPEG over TCP) |
| `insert_text` / `show_keyboard` / `hide_keyboard` / `move_cursor` | Working (via appdelegate tweak) |

---

## Touch

Two methods for sending touch events.

```python
def touch(type, finger_index, x, y):
	"""Perform a touch event
	
	Args:
		type: touch event type. Import from zxtouch.touchtypes
		finger_index: finger index 1-19
		x: x coordinate
		y: y coordinate
	"""
```

```python
def touch_with_list(self, touch_list: list):
    """Perform multiple touch events simultaneously
    
    Args:
    	touch_list: [{"type": ?, "finger_index": ?, "x": ?, "y": ?}, ...]
    """
```

Code example:

```python
from zxtouch.client import zxtouch
from zxtouch.touchtypes import *
import time

device = zxtouch("127.0.0.1")

device.touch(TOUCH_DOWN, 5, 400, 400)
time.sleep(1)
device.touch(TOUCH_MOVE, 5, 400, 600)
time.sleep(1)
device.touch(TOUCH_UP, 5, 400, 600)
time.sleep(1)

# Multitouch
device.touch_with_list([
    {"type": TOUCH_DOWN, "finger_index": 1, "x": 300, "y": 300},
    {"type": TOUCH_DOWN, "finger_index": 2, "x": 500, "y": 500}
])
time.sleep(1)
device.touch_with_list([
    {"type": TOUCH_UP, "finger_index": 1, "x": 300, "y": 300},
    {"type": TOUCH_UP, "finger_index": 2, "x": 500, "y": 500}
])

device.disconnect()
```

---

## Bring application to foreground

```python
def switch_to_app(bundle_identifier):
	"""Bring an application to foreground
	
	Args:
		bundle_identifier: bundle ID of the app (e.g. "com.apple.springboard")
	
	Returns:
		Result tuple (success, error_or_empty)
	"""
```

---

## Show alert box

```python
def show_alert_box(title, content, duration):
    """Show a system-wide alert box

    Args:
        title: alert title
        content: alert message
        duration: seconds before auto-dismiss (0 = manual dismiss only)

    Returns:
        Result tuple (success, error_or_empty)
    """
```

---

## Prompt for user input

```python
def prompt_input(title, message="", placeholder="", default_value="", secure=False):
    """Show a native input dialog and return the entered text

    Args:
        title: dialog title
        message: optional message shown above the text field
        placeholder: optional text field placeholder
        default_value: optional starting value
        secure: True to hide typed text, useful for passwords

    Returns:
        Result tuple. On success, result[1] is the entered string.
        Cancel returns (False, error_or_empty).
    """
```

Code example:

```python
from zxtouch.client import zxtouch

device = zxtouch("127.0.0.1")
success, value = device.prompt_input(
    "Search",
    "What should the script look for?",
    placeholder="Type a keyword"
)

if success:
    device.show_toast(0, "You entered: " + value, 2)
```

---

## Run shell command as root

```python
def run_shell_command(command):
    """Run a shell command as root
	
    Args:
    	command: shell command string
        
    Returns:
        Result tuple (success, error_or_empty)
    """
```

---

## Image matching

```python
def image_match(template_path, acceptable_value=0.8, max_try_times=2, scaleRation=0.8):
    """Match screen against a template image using normalized cross-correlation
	
    Args:
    	template_path: absolute path to template image on device
    	acceptable_value: similarity threshold (0-1)
    	scaleRation: scale factor per retry attempt
    	max_try_times: max number of scale variants to try
        
    Returns:
        Result tuple. On success, result[1] is a dict: {"x", "y", "width", "height"}
        If no match found, returns (False, error_message)
    """
```

Implemented with `Accelerate.framework`, so OpenCV is not required.

---

## Toast

```python
def show_toast(toast_type, content, duration, position=0, fontSize=0):
	"""Show a toast notification
	
	Args:
        toast_type: TOAST_SUCCESS / TOAST_ERROR / TOAST_WARNING / TOAST_MESSAGE
        content: text to display
        duration: seconds to show
        position: TOAST_TOP (default) or TOAST_BOTTOM
	
	Returns:
        Result tuple (success, error_or_empty)
	"""
```

---

## Color picker

```python
def pick_color(x, y):
    """Get the RGB value of a pixel on screen
	
    Args:
   		x: x coordinate
   		y: y coordinate

    Returns:
        Result tuple. On success, result[1] is {"red", "green", "blue"} (values as strings)
    """
```

---

## Color searcher

```python
def search_color(region, red_min, red_max, green_min, green_max, blue_min, blue_max, pixel_to_skip=0):
    """Search for a color in a screen region

    Args:
        region: (x, y, width, height) tuple
        red_min/red_max: red channel range (0-255)
        green_min/green_max: green channel range (0-255)
        blue_min/blue_max: blue channel range (0-255)
        pixel_to_skip: pixels to skip between checks (0 = check every pixel)

    Returns:
        Result tuple. On success, result[1] is {"x", "y", "red", "green", "blue"}
    """
```

---

## Accurate sleep

```python
def accurate_usleep(microseconds):
    """Sleep for an accurate duration
	
    Args:
    	microseconds: time to sleep in microseconds
        
    Returns:
        Result tuple (success, error_or_empty)
    """
```

---

## Play a script

```python
def play_script(script_absolute_path):
    """Play a ZXTouch script (.bdl folder)
	
    Args:
    	script_absolute_path: absolute path to the .bdl script folder
    	        
    Returns:
        Result tuple (success, error_or_empty)
    """
```

---

## Force stop script playing

```python
def force_stop_script_play():
    """Force stop the currently running script
	
    Returns:
        Result tuple (success, error_or_empty)
    """
```

---

## Hide keyboard

If the keyboard is showing, hide it.

```python
def hide_keyboard():
    """Hide the keyboard

    Returns:
        Result tuple (success, error_or_empty)
    """
```

---

## Show keyboard

If the keyboard is hidden, show it.

```python
def show_keyboard():
    """Show the keyboard

    Returns:
        Result tuple (success, error_or_empty)
    """
```

---

## Text input

Insert text into the current text field. Use `"\b"` to delete a character.

```python
def insert_text(text):
    """Insert text into the focused text field

    Args:
        text: text to insert (\b = backspace/delete)

    Returns:
        Result tuple (success, error_or_empty)
    """
```

---

## Move cursor

```python
def move_cursor(offset):
    """Move the text cursor

    Args:
        offset: relative positions to move.
                Negative = move left, positive = move right.

    Returns:
        Result tuple (success, error_or_empty)
    """
```

---

## Get screen size

```python
def get_screen_size():
    """Get screen size in pixels
	
    Returns:
        Result tuple. On success, result[1] is {"width", "height"}
    """
```

---

## Screenshot

`screenshot()` returns the current display as raw JPEG bytes directly over the
existing ZXTouch TCP connection. No file is created on the iOS device and SSH
is not required. Pillow is optional and is only needed if your own code wants
to decode the returned JPEG.

```python
from io import BytesIO

from PIL import Image
from zxtouch.client import zxtouch

device = zxtouch("192.168.2.86")

data = device.screenshot()

image = Image.open(BytesIO(data))
image.load()
image.show()

device.disconnect()
```

The wire response is `0;;image/jpeg;;<CONTENT_LENGTH>\r\n` followed immediately
by exactly `CONTENT_LENGTH` raw JPEG bytes. Server errors remain text responses
in the form `-1;;<message>\r\n`.

---

## Get screen orientation

```python
def get_screen_orientation():
    """Get current screen orientation
	
    Returns:
        Result tuple. On success, result[1] is an orientation int as string.
        1 = Portrait, 2 = PortraitUpsideDown, 3 = LandscapeLeft, 4 = LandscapeRight
    """
```

---

## Get screen scale

```python
def get_screen_scale():
    """Get screen scale factor (e.g. 2.0 for Retina)
	
    Returns:
        Result tuple. On success, result[1] is a float as string.
    """
```

---

## Get device information

```python
def get_device_info():
    """Get device information
	
    Returns:
        Result tuple. On success, result[1] is:
        {"name", "system_name", "system_version", "model", "identifier_for_vendor"}
    """
```

---

## Get battery information

```python
def get_battery_info():
    """Get battery information
	
    Returns:
        Result tuple. On success, result[1] is:
        {"battery_state", "battery_level", "battery_state_string"}
    """
```

---

## Start touch recording

```python
def start_touch_recording():
    """Start recording touch events
    A green dot appears at the top of the screen while recording.
	
    Returns:
        Result tuple (success, error_or_empty)
    """
```

---

## Stop touch recording

```python
def stop_touch_recording():
    """Stop recording touch events
    You can also double-click volume down to stop.
	
    Returns:
        Result tuple (success, error_or_empty)
    """
```

---

## OCR

```python
def ocr(self, region, custom_words=[], minimum_height="", recognition_level=0, languages=[], auto_correct=0, debug_image_path=""):
    """Recognize text in a screen region

    Args:
        region: (x, y, width, height) tuple
        custom_words: extra words to supplement recognition
        minimum_height: min text height relative to image height (default 1/32)
        recognition_level: 0 = accurate, 1 = fast
        languages: list of language codes in priority order (default: English)
        auto_correct: 0 = off, 1 = on
        debug_image_path: path to save debug image (leave blank to skip)

    Returns:
        Result tuple. On success, result[1] is a list of recognized text strings.
    """
```

```python
def get_supported_ocr_languages(self, recognition_level):
    """Get list of languages supported by OCR

    Args:
        recognition_level: 0 = accurate, 1 = fast

    Returns:
        Result tuple. On success, result[1] is a list of language codes.
    """
```

---

## Building from source

Every push to `main` triggers a GitHub Actions build. Xcode compiles the app on a macOS runner, Theos builds the tweak, and both `.deb` files are uploaded as artifacts, so you do not need a Mac.

See [`.github/workflows/build.yml`](.github/workflows/build.yml).

---

## Credits

| | |
|--|--|
| iOS 15 to 17 rootless and roothide port | [Epic0001](https://github.com/Epic0001) |
| Original ZXTouch | [xuan32546](https://github.com/xuan32546) |
