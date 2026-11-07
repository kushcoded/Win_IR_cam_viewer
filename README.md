# Windows IR Camera Viewer

A lightweight Windows utility built with PowerShell and WinForms that allows you to view and interact with your laptop's built-in infrared (Windows Hello) camera.

## App preview:
<img width="640" height="360" alt="image" src="https://github.com/user-attachments/assets/7503291c-4006-468f-b5da-57fe8af1b0bc" />

## Install and run
simply install and run IR-Camera-Viewer.exe (Likely to be blocked by Antivirus) or,
install the PowerShell script(.ps1) and command script(.cmd) in the same directory/folder and run the .cmd file

## Keyboard Shortcuts

| Key | Action |
| :--- | :--- |
| `P` | Take Snapshot (Save PNG to Desktop) |
| `R` | Toggle Video Recording |
| `M` | Toggle Mirror View |
| `F` | Toggle Anti-flicker Filter |
| `S` | Toggle Auto-brighten |
| `+` / `-` | Zoom In / Zoom Out |
| `F11` | Toggle Fullscreen Mode |
| `Esc` | Exit Fullscreen (or close app if windowed) |
| `T` | Toggle Dark / Light Theme |

---

## Requirements

1. **Operating System:** Windows 10 / 11 with an integrated IR camera (Windows Hello capable).
3. *(Optional)* **FFmpeg:** Required only for video recording (`winget install Gyan.FFmpeg`).

## Privacy
All data stored locally
