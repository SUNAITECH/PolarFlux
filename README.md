# PolarFlux

A native macOS application to control your light strip and sync it with your screen.

## Features
- **Native Performance**: Written in Swift for maximum efficiency.
- **Screen Sync**: Real-time screen synchronization.
- **Manual Control**: Set static colors.
- **Configurable**: Customize LED count and zones.

## How to Run

1.  Open Terminal in this folder.
2.  Run the build script (if you haven't already):
    ```bash
    ./Scripts/run.sh
    ```
3.  Open the app:
    ```bash
    open PolarFlux.app
    ```

## Permissions
On first run, you might be prompted to allow **Screen Recording**. This is required for the sync feature to work.
If the lights stay black during sync, please check:
`System Settings` -> `Privacy & Security` -> `Screen Recording` -> Enable `PolarFlux`.

## Configuration
The app saves your settings automatically.
